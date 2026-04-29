// librsvg + cairo shim. Rasterises `path` into a malloc'd straight-alpha
// RGBA8 buffer fitting `target_size`. Returns 0 on success, negative on
// failure. Caller frees via free().
//
// Cairo's CAIRO_FORMAT_ARGB32 is BGRA byte order on little-endian with
// premultiplied alpha. We undo the premultiplication and reorder bytes to
// straight RGBA so the buffer matches the layout common.RgbaIcon expects.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <cairo.h>
#include <librsvg/rsvg.h>

int vitrail_decode_svg(const char *path,
                       uint32_t target_size,
                       uint8_t **out_pixels,
                       uint32_t *out_w,
                       uint32_t *out_h) {
    if (!path || !out_pixels || !out_w || !out_h || target_size == 0) return -1;

    GError *err = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_file(path, &err);
    if (!handle) {
        if (err) g_error_free(err);
        return -2;
    }

    gdouble nat_w = 0, nat_h = 0;
    gboolean has_w = FALSE, has_h = FALSE;
    RsvgRectangle viewbox;
    gboolean has_vb = FALSE;
    rsvg_handle_get_intrinsic_dimensions(
        handle, &has_w, NULL, &has_h, NULL, &has_vb, &viewbox);
    // Prefer viewBox; fall back to a square at target_size.
    if (has_vb && viewbox.width > 0 && viewbox.height > 0) {
        nat_w = viewbox.width;
        nat_h = viewbox.height;
    } else {
        nat_w = (gdouble)target_size;
        nat_h = (gdouble)target_size;
    }

    gdouble scale = (gdouble)target_size / (nat_w > nat_h ? nat_w : nat_h);
    int out_pixel_w = (int)ceil(nat_w * scale);
    int out_pixel_h = (int)ceil(nat_h * scale);
    if (out_pixel_w <= 0) out_pixel_w = 1;
    if (out_pixel_h <= 0) out_pixel_h = 1;

    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, out_pixel_w, out_pixel_h);
    if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surf);
        g_object_unref(handle);
        return -3;
    }
    cairo_t *cr = cairo_create(surf);
    cairo_scale(cr, scale, scale);

    RsvgRectangle viewport = { .x = 0, .y = 0, .width = nat_w, .height = nat_h };
    if (!rsvg_handle_render_document(handle, cr, &viewport, &err)) {
        if (err) g_error_free(err);
        cairo_destroy(cr);
        cairo_surface_destroy(surf);
        g_object_unref(handle);
        return -4;
    }
    cairo_destroy(cr);
    cairo_surface_flush(surf);

    int stride = cairo_image_surface_get_stride(surf);
    const uint8_t *src = cairo_image_surface_get_data(surf);

    size_t out_size = (size_t)out_pixel_w * (size_t)out_pixel_h * 4;
    uint8_t *dst = (uint8_t *)malloc(out_size);
    if (!dst) {
        cairo_surface_destroy(surf);
        g_object_unref(handle);
        return -5;
    }

    for (int y = 0; y < out_pixel_h; y++) {
        const uint8_t *srow = src + (size_t)y * (size_t)stride;
        uint8_t *drow = dst + (size_t)y * (size_t)out_pixel_w * 4;
        for (int x = 0; x < out_pixel_w; x++) {
            // Cairo little-endian ARGB32 byte order is B,G,R,A — premultiplied.
            uint8_t b = srow[x * 4 + 0];
            uint8_t g = srow[x * 4 + 1];
            uint8_t r = srow[x * 4 + 2];
            uint8_t a = srow[x * 4 + 3];
            if (a != 0 && a != 255) {
                // Un-premultiply: c = (c_pm * 255 + a/2) / a
                r = (uint8_t)((r * 255 + a / 2) / a);
                g = (uint8_t)((g * 255 + a / 2) / a);
                b = (uint8_t)((b * 255 + a / 2) / a);
            }
            drow[x * 4 + 0] = r;
            drow[x * 4 + 1] = g;
            drow[x * 4 + 2] = b;
            drow[x * 4 + 3] = a;
        }
    }

    cairo_surface_destroy(surf);
    g_object_unref(handle);

    *out_pixels = dst;
    *out_w = (uint32_t)out_pixel_w;
    *out_h = (uint32_t)out_pixel_h;
    return 0;
}
