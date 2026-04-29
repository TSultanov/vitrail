// C-callable bridge between Zig and Cocoa. Every entry point is plain C so
// the Zig side never sees Objective-C types directly.
#ifndef VITRAIL_COCOA_BRIDGE_H
#define VITRAIL_COCOA_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Lifecycle ───────────────────────────────────────────────────────────────

void vt_app_init(void);
// Pumps a single event from the run loop. blocking=1 waits, blocking=0 returns
// immediately if no event is queued. Returns 0 normally; nonzero if the app
// was asked to terminate.
int  vt_app_pump_one(int blocking);
void vt_app_stop(void);

// ─── Window ──────────────────────────────────────────────────────────────────

typedef struct vt_window vt_window;

typedef void (*vt_key_cb)(void *ctx,
                          int virtual_keycode,
                          uint32_t modifiers,
                          const char *utf8,
                          int utf8_len);

// kind: 0 = move, 1 = left button down, 2 = left button up.
typedef void (*vt_mouse_cb)(void *ctx, int kind, double x, double y);

typedef void (*vt_resize_cb)(void *ctx,
                             uint32_t physical_w,
                             uint32_t physical_h,
                             uint32_t logical_w,
                             uint32_t logical_h,
                             double backing_scale);

typedef void (*vt_close_cb)(void *ctx);

vt_window *vt_window_create(void *ctx,
                            vt_key_cb on_key,
                            vt_mouse_cb on_mouse,
                            vt_resize_cb on_resize,
                            vt_close_cb on_close);

void vt_window_show(vt_window *w);
void vt_window_hide(vt_window *w);
void vt_window_destroy(vt_window *w);

// Sets the displayed image. cg_image must be a CGImageRef; the bridge retains
// it for the duration of the assignment.
void vt_window_set_image(vt_window *w, const void *cg_image);

// Logical (point) size of the content view.
void vt_window_logical_size(vt_window *w, uint32_t *out_w, uint32_t *out_h);
// Backing scale (1.0 or 2.0 typically; can be fractional on external monitors).
double vt_window_backing_scale(vt_window *w);

// ─── Activation ──────────────────────────────────────────────────────────────

// Brings the app with the given pid to the foreground. Returns 1 on success.
int vt_activate_pid(int pid);

// ─── Icons ───────────────────────────────────────────────────────────────────

// Fetches an RGBA bitmap (top-down, width*height*4 bytes) for the app
// associated with `pid`. The caller owns the buffer and must free() it.
// Returns 0 on success, nonzero on failure.
int vt_icon_for_pid(int pid,
                    int target_size,
                    uint8_t **out_rgba,
                    uint32_t *out_w,
                    uint32_t *out_h);

// Returns the localized application name for `pid`, copied into a malloc'd
// NUL-terminated buffer the caller free()s. Returns NULL on failure.
char *vt_app_name_for_pid(int pid);

// ─── Process enumeration ─────────────────────────────────────────────────────

// Returns a malloc'd array of pids for currently-running apps with
// activationPolicy == NSApplicationActivationPolicyRegular (skips daemons,
// menubar-only agents) and excludes our own pid. *out_count receives the
// number of pids written. Caller frees the returned buffer with vt_free.
// Returns NULL on allocation failure.
int *vt_running_pids(int *out_count);

// Frees a pointer returned by vt_running_pids (or any malloc'd buffer the
// bridge hands back).
void vt_free(void *p);

#ifdef __cplusplus
}
#endif

#endif
