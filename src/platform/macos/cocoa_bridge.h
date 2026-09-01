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

// kind: 0 = move, 1 = left button down, 2 = left button up,
//       3 = right button down.
typedef void (*vt_mouse_cb)(void *ctx, int kind, double x, double y);

typedef void (*vt_resize_cb)(void *ctx,
                             uint32_t physical_w,
                             uint32_t physical_h,
                             uint32_t logical_w,
                             uint32_t logical_h,
                             double backing_scale);

typedef void (*vt_close_cb)(void *ctx);
typedef void (*vt_simple_cb)(void *ctx);

vt_window *vt_window_create(void *ctx,
                            vt_key_cb on_key,
                            vt_mouse_cb on_mouse,
                            vt_resize_cb on_resize,
                            vt_close_cb on_close);

void vt_window_show(vt_window *w);
void vt_window_hide(vt_window *w);
void vt_window_destroy(vt_window *w);

// Shows the native window context menu at the view-local point. Returns 1 for
// "Close window", 2 for "Quit application", and 0 when dismissed. Menu
// tracking is synchronous.
int vt_window_show_context_menu(vt_window *w,
                                double x,
                                double y,
                                int close_enabled);

// Return the current system pointer in content-view coordinates. Unlike an
// NSEvent's location, this is not a historical point from AppKit's queue.
// Returns 1 while the pointer is inside the content view.
int vt_window_mouse_position(vt_window *w, double *out_x, double *out_y);

// Debounced-refresh timer owned by the window. Scheduling replaces any
// existing timer. The callback runs on the AppKit main thread.
void vt_window_schedule_refresh(vt_window *w,
                                double delay_seconds,
                                vt_simple_cb callback);
void vt_window_cancel_refresh(vt_window *w);

// Independent timer used to observe a first-run Accessibility grant while the
// overlay is hidden. It must not contend with the live-window refresh timer.
void vt_window_schedule_accessibility_poll(vt_window *w,
                                           double delay_seconds,
                                           vt_simple_cb callback);
void vt_window_cancel_accessibility_poll(vt_window *w);

// Test hook: posts one of the real NSWorkspace notifications observed by the
// production window-change path.
void vt_test_post_window_change_notification(void);

// Reposition the overlay to the main display (keyboard-activation path).
void vt_window_move_to_main_screen(vt_window *w);

// Reposition the overlay to the display under the mouse pointer and return the
// pointer in the content view's logical coordinates (top-left origin, points).
// Returns 1 on success, 0 if no screen/owner.
int vt_window_move_to_cursor_screen(vt_window *w, double *out_x, double *out_y);

// ─── Settings window ─────────────────────────────────────────────────────────

// Press-to-bind capture: fired for right- and other-mouse button-downs inside
// the settings window. is_right==1 for the right button; button_number is the
// NSEvent buttonNumber otherwise.
typedef void (*vt_capture_cb)(void *ctx, int is_right, long button_number);

// Creates a normal *titled* window (not the borderless overlay) sized to
// width x height points, centered on screen. Unlike the overlay it does not
// dismiss on resign-key — on_close fires only when the window is actually
// closed. Reuses vt_window_show/hide/destroy/set_image and the resize/key/mouse
// callbacks; on_capture additionally delivers right/other button presses for
// press-to-bind.
vt_window *vt_settings_create(void *ctx,
                              int width,
                              int height,
                              vt_key_cb on_key,
                              vt_mouse_cb on_mouse,
                              vt_resize_cb on_resize,
                              vt_close_cb on_close,
                              vt_capture_cb on_capture);

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

// Asks a running application to terminate normally, allowing it to present
// save-confirmation UI. Returns 1 when the request was delivered.
int vt_quit_pid(int pid);

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

// Returns a monotonically increasing counter associated with the given pid.
// Higher = more recently activated. Returns 0 for pids never seen by the
// activation observer (which is installed during vt_app_init).
int64_t vt_app_activation_ordinal(int pid);

// Reports workspace-level changes that can affect the visible grid: app
// lifecycle/activation and active-Space changes. Passing NULL clears the
// current receiver; observer installation itself is process-wide/idempotent.
void vt_install_window_change_observer(void *ctx, vt_simple_cb on_change);

// Subscribes the given callbacks to NSWorkspaceDidLaunchApplicationNotification
// and NSWorkspaceDidTerminateApplicationNotification. The callbacks fire on
// the main thread. Both pointers may be NULL to skip a side. Idempotent if
// called more than once: the most recent callbacks win.
typedef void (*vt_pid_cb)(int pid);
void vt_install_app_lifecycle_observers(vt_pid_cb on_launch, vt_pid_cb on_terminate);

#ifdef __cplusplus
}
#endif

#endif
