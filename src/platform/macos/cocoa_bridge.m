// Cocoa bridge — the only Objective-C in the port. Exposes a small C API the
// Zig side calls. The intent is to keep this file as thin as possible: it
// owns NSApp + NSWindow lifetime and forwards keyboard/mouse events into Zig
// callbacks; everything else (rendering, layout, hotkey, window enumeration)
// stays in Zig using pure-C Apple frameworks.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include "cocoa_bridge.h"

// ─── Borderless window subclass — must override canBecomeKeyWindow so that
// keyDown: events are dispatched to the content view (the default NO blocks
// all keyboard input on borderless windows).

@interface VTWindow : NSWindow
@end

@implementation VTWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

// ─── Custom content view: forwards events to the Zig callbacks ──────────────

@interface VTContentView : NSView
@property (nonatomic, assign) void *zig_ctx;
@property (nonatomic, assign) vt_key_cb on_key;
@property (nonatomic, assign) vt_mouse_cb on_mouse;
@end

@implementation VTContentView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)isFlipped { return YES; } // top-left origin, matching our renderer

- (void)keyDown:(NSEvent *)event {
    if (!self.on_key) return;
    NSString *chars = event.charactersIgnoringModifiers ?: @"";
    NSString *typed = event.characters ?: @"";
    const char *utf8 = [typed UTF8String];
    int utf8_len = (int)[typed lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    self.on_key(self.zig_ctx,
                (int)event.keyCode,
                (uint32_t)event.modifierFlags,
                utf8,
                utf8_len);
    (void)chars;
}

- (void)mouseMoved:(NSEvent *)event {
    if (!self.on_mouse) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    self.on_mouse(self.zig_ctx, 0, p.x, p.y);
}

- (void)mouseDragged:(NSEvent *)event {
    [self mouseMoved:event];
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.on_mouse) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    self.on_mouse(self.zig_ctx, 1, p.x, p.y);
}

- (void)mouseUp:(NSEvent *)event {
    if (!self.on_mouse) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    self.on_mouse(self.zig_ctx, 2, p.x, p.y);
}

@end

// ─── Window wrapper with delegate for resize/close ──────────────────────────

@interface VTWindowOwner : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) VTContentView *view;
@property (nonatomic, assign) void *zig_ctx;
@property (nonatomic, assign) vt_resize_cb on_resize;
@property (nonatomic, assign) vt_close_cb on_close;
@end

@implementation VTWindowOwner

- (void)reportSize {
    if (!self.on_resize) return;
    NSSize logical = self.view.bounds.size;
    NSSize physical = [self.view convertSizeToBacking:logical];
    double scale = self.window.backingScaleFactor;
    self.on_resize(self.zig_ctx,
                   (uint32_t)physical.width,
                   (uint32_t)physical.height,
                   (uint32_t)logical.width,
                   (uint32_t)logical.height,
                   scale);
}

- (void)windowDidResize:(NSNotification *)note {
    [self reportSize];
}

- (void)windowDidChangeBackingProperties:(NSNotification *)note {
    [self reportSize];
}

- (void)windowDidResignKey:(NSNotification *)note {
    if (self.on_close) self.on_close(self.zig_ctx);
}

@end

struct vt_window {
    void *owner; // VTWindowOwner *, retained
};

// ─── Lifecycle ──────────────────────────────────────────────────────────────

static BOOL g_should_stop = NO;

// App-activation MRU table. Higher counter = more recently activated. Seeded
// at install time from runningApplications order so cold-start ordering is
// stable; the frontmost app gets the freshest counter so it sorts first
// immediately. Subsequent activations bump the counter via the
// NSWorkspaceDidActivateApplicationNotification observer below.
static int64_t g_activation_counter = 0;
static NSMutableDictionary<NSNumber*, NSNumber*> *g_pid_ordinals = nil;

static void install_app_activation_observer(void) {
    g_pid_ordinals = [NSMutableDictionary new];

    NSArray<NSRunningApplication *> *apps =
        [NSWorkspace sharedWorkspace].runningApplications;
    for (NSRunningApplication *app in apps) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        g_pid_ordinals[@(app.processIdentifier)] = @(g_activation_counter++);
    }
    NSRunningApplication *front =
        [NSWorkspace sharedWorkspace].frontmostApplication;
    if (front) {
        g_pid_ordinals[@(front.processIdentifier)] = @(g_activation_counter++);
    }

    [[NSWorkspace sharedWorkspace].notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            NSRunningApplication *app =
                note.userInfo[NSWorkspaceApplicationKey];
            if (app) {
                g_pid_ordinals[@(app.processIdentifier)] =
                    @(g_activation_counter++);
            }
        }];
}

void vt_app_init(void) {
    [NSApplication sharedApplication];
    // Accessory: no Dock icon, no menu bar — matches LSUIElement in Info.plist
    // for builds run from within the .app bundle, and gives the right
    // behaviour for raw-binary runs too.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    install_app_activation_observer();
}

int64_t vt_app_activation_ordinal(int pid) {
    NSNumber *n = g_pid_ordinals[@(pid)];
    return n ? n.longLongValue : 0;
}

static vt_pid_cb g_on_app_launch = NULL;
static vt_pid_cb g_on_app_terminate = NULL;
static BOOL g_lifecycle_observers_installed = NO;

void vt_install_app_lifecycle_observers(vt_pid_cb on_launch, vt_pid_cb on_terminate) {
    g_on_app_launch = on_launch;
    g_on_app_terminate = on_terminate;
    if (g_lifecycle_observers_installed) return;
    g_lifecycle_observers_installed = YES;
    NSNotificationCenter *nc = [NSWorkspace sharedWorkspace].notificationCenter;
    [nc addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        if (!app) return;
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) return;
        if (g_on_app_launch) g_on_app_launch((int)app.processIdentifier);
    }];
    [nc addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        if (!app) return;
        if (g_on_app_terminate) g_on_app_terminate((int)app.processIdentifier);
    }];
}

int vt_app_pump_one(int blocking) {
    if (g_should_stop) return 1;
    NSDate *until = blocking ? [NSDate distantFuture] : [NSDate distantPast];
    NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                    untilDate:until
                                       inMode:NSDefaultRunLoopMode
                                      dequeue:YES];
    if (e) [NSApp sendEvent:e];
    return g_should_stop ? 1 : 0;
}

void vt_app_stop(void) {
    g_should_stop = YES;
    // Post a no-op event so a blocking pump returns promptly.
    NSEvent *wakeup = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                         location:NSZeroPoint
                                    modifierFlags:0
                                        timestamp:0
                                     windowNumber:0
                                          context:nil
                                          subtype:0
                                            data1:0
                                            data2:0];
    [NSApp postEvent:wakeup atStart:YES];
}

// ─── Window ─────────────────────────────────────────────────────────────────

vt_window *vt_window_create(void *ctx,
                            vt_key_cb on_key,
                            vt_mouse_cb on_mouse,
                            vt_resize_cb on_resize,
                            vt_close_cb on_close) {
    NSScreen *screen = [NSScreen mainScreen];
    NSRect frame = screen.frame;

    NSWindow *window = [[VTWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO
                     screen:screen];
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];
    window.hasShadow = NO;
    window.level = NSScreenSaverWindowLevel;
    // MoveToActiveSpace, NOT CanJoinAllSpaces. CanJoinAllSpaces is supposed
    // to keep the window present on every Space, but for accessory-policy
    // apps AppKit silently binds the window to its home Space after
    // orderOut: — diagnostic dumps showed window.spaces=(home) and
    // onActiveSpace=0 on every other Space, which is why the overlay
    // sometimes failed to appear. MoveToActiveSpace is the clean opposite:
    // the window migrates to whichever Space is active when we order it
    // front, which matches the on-hotkey usage pattern exactly.
    window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorIgnoresCycle;
    [window setAcceptsMouseMovedEvents:YES];
    [window setIgnoresMouseEvents:NO];
    [window setReleasedWhenClosed:NO];

    VTContentView *view = [[VTContentView alloc] initWithFrame:frame];
    view.zig_ctx = ctx;
    view.on_key = on_key;
    view.on_mouse = on_mouse;
    view.wantsLayer = YES;
    view.layer.contentsGravity = kCAGravityResize;
    view.layer.contentsScale = window.backingScaleFactor;
    window.contentView = view;
    [window makeFirstResponder:view];

    VTWindowOwner *owner = [[VTWindowOwner alloc] init];
    owner.window = window;
    owner.view = view;
    owner.zig_ctx = ctx;
    owner.on_resize = on_resize;
    owner.on_close = on_close;
    window.delegate = owner;

    vt_window *out = (vt_window *)calloc(1, sizeof(vt_window));
    out->owner = (__bridge_retained void *)owner;
    // Fire the resize callback now so the Zig side knows the viewport size
    // even before the window is shown — the test driver allocates its
    // snapshot buffer based on viewportSize() returned by the platform layer.
    [owner reportSize];
    return out;
}

void vt_window_show(vt_window *w) {
    if (!w) return;
    VTWindowOwner *owner = (__bridge VTWindowOwner *)w->owner;
    // Re-assert MoveToActiveSpace every show. AppKit can otherwise lose the
    // intent across orderOut/orderFront cycles, leaving the window stuck on
    // its home Space.
    owner.window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                      NSWindowCollectionBehaviorFullScreenAuxiliary |
                                      NSWindowCollectionBehaviorIgnoresCycle;
    [NSApp activateIgnoringOtherApps:YES];
    [owner.window makeKeyAndOrderFront:nil];
    [owner reportSize];
}

void vt_window_hide(vt_window *w) {
    if (!w) return;
    VTWindowOwner *owner = (__bridge VTWindowOwner *)w->owner;
    [owner.window orderOut:nil];
}

void vt_window_destroy(vt_window *w) {
    if (!w) return;
    VTWindowOwner *owner = (__bridge_transfer VTWindowOwner *)w->owner;
    owner.window.delegate = nil;
    [owner.window close];
    (void)owner;
    free(w);
}

void vt_window_set_image(vt_window *w, const void *cg_image) {
    if (!w) return;
    VTWindowOwner *owner = (__bridge VTWindowOwner *)w->owner;
    owner.view.layer.contents = (__bridge id)cg_image;
}

void vt_window_logical_size(vt_window *w, uint32_t *out_w, uint32_t *out_h) {
    if (!w) { *out_w = 0; *out_h = 0; return; }
    VTWindowOwner *owner = (__bridge VTWindowOwner *)w->owner;
    NSSize s = owner.view.bounds.size;
    *out_w = (uint32_t)s.width;
    *out_h = (uint32_t)s.height;
}

double vt_window_backing_scale(vt_window *w) {
    if (!w) return 1.0;
    VTWindowOwner *owner = (__bridge VTWindowOwner *)w->owner;
    return owner.window.backingScaleFactor;
}

// ─── Activation ─────────────────────────────────────────────────────────────

int vt_activate_pid(int pid) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
    if (!app) return 0;
    // On macOS 14+ activateWithOptions: is deprecated and silently fails
    // when the caller is still the active app — which is exactly our case
    // (vitrail hides its window only *after* this returns). For windowed
    // tiles AXRaise on the AX window papers over this, but windowless apps
    // have no AX window to raise, so they wouldn't come forward.
    // activateFromApplication:options: is the supported replacement and
    // explicitly transfers activation from a known caller, so it works
    // regardless of the caller's active state.
    BOOL ok;
    if (@available(macOS 14.0, *)) {
        ok = [app activateFromApplication:[NSRunningApplication currentApplication]
                                  options:NSApplicationActivateAllWindows];
    } else {
        ok = [app activateWithOptions:NSApplicationActivateAllWindows |
                                      NSApplicationActivateIgnoringOtherApps];
    }
    return ok ? 1 : 0;
}

int vt_reopen_pid(int pid) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
    if (!app) return 0;
    NSURL *bundleURL = app.bundleURL;
    if (!bundleURL) return 0;
    // openApplicationAtURL on a running app routes through Launch Services
    // exactly like a Dock-icon click, so the app's
    // applicationShouldHandleReopen:hasVisibleWindows: delegate fires —
    // which is what makes Mail / Calendar / Preview spawn a new window.
    // Plain activate* APIs don't trigger reopen.
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:bundleURL
                                          configuration:cfg
                                      completionHandler:nil];
    return 1;
}

// ─── Icons & names ──────────────────────────────────────────────────────────

int vt_icon_for_pid(int pid,
                    int target_size,
                    uint8_t **out_rgba,
                    uint32_t *out_w,
                    uint32_t *out_h) {
    *out_rgba = NULL;
    *out_w = 0;
    *out_h = 0;
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
    if (!app) return -1;
    NSImage *img = app.icon;
    if (!img) return -2;

    NSSize sz = NSMakeSize((CGFloat)target_size, (CGFloat)target_size);
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return -3;

    size_t w = (size_t)target_size;
    size_t h = (size_t)target_size;
    size_t stride = w * 4;
    uint8_t *buf = (uint8_t *)calloc(stride * h, 1);
    if (!buf) return -4;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmp = CGBitmapContextCreate(
        buf, w, h, 8, stride, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!bmp) { free(buf); return -5; }

    CGContextSetBlendMode(bmp, kCGBlendModeCopy);
    CGContextDrawImage(bmp, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(bmp);

    *out_rgba = buf;
    *out_w = (uint32_t)w;
    *out_h = (uint32_t)h;
    (void)sz;
    return 0;
}

char *vt_app_name_for_pid(int pid) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
    if (!app) return NULL;
    NSString *name = app.localizedName;
    if (!name) return NULL;
    const char *utf8 = [name UTF8String];
    if (!utf8) return NULL;
    size_t len = strlen(utf8);
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, utf8, len + 1);
    return out;
}

// ─── Process enumeration ────────────────────────────────────────────────────

int *vt_running_pids(int *out_count) {
    *out_count = 0;
    NSArray<NSRunningApplication *> *apps =
        [NSWorkspace sharedWorkspace].runningApplications;
    if (apps.count == 0) return NULL;
    pid_t self_pid = [NSProcessInfo processInfo].processIdentifier;
    int *buf = (int *)malloc(sizeof(int) * apps.count);
    if (!buf) return NULL;
    int n = 0;
    for (NSRunningApplication *app in apps) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        if (app.processIdentifier == self_pid) continue;
        buf[n++] = (int)app.processIdentifier;
    }
    *out_count = n;
    return buf;
}

void vt_free(void *p) {
    free(p);
}
