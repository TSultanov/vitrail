// libpng simplified-API shim. Reads `path` and produces a malloc'd RGBA8
// buffer (width*height*4 bytes). Caller frees via free(). Returns 0 on
// success, negative on failure.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <png.h>

int vitrail_decode_png(const char *path,
                       uint8_t **out_pixels,
                       uint32_t *out_w,
                       uint32_t *out_h) {
    if (!path || !out_pixels || !out_w || !out_h) return -1;

    png_image img;
    memset(&img, 0, sizeof(img));
    img.version = PNG_IMAGE_VERSION;

    if (png_image_begin_read_from_file(&img, path) == 0) return -2;
    img.format = PNG_FORMAT_RGBA;

    size_t size = PNG_IMAGE_SIZE(img);
    uint8_t *buf = (uint8_t *)malloc(size);
    if (!buf) {
        png_image_free(&img);
        return -3;
    }

    if (png_image_finish_read(&img, NULL, buf, 0, NULL) == 0) {
        free(buf);
        return -4;
    }

    *out_pixels = buf;
    *out_w = img.width;
    *out_h = img.height;
    return 0;
}
