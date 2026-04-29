// Minimal Accessibility (AX) externs. Used to enumerate apps' windows
// (kAXWindowsAttribute), filter on subrole (kAXStandardWindow / kAXDialog),
// and raise an individual window (kAXRaiseAction). The private
// _AXUIElementGetWindow gives us the CGWindowID for an AX window — needed
// to look up Space membership via CGSCopySpacesForWindows for the desktop
// badge.

const cf = @import("cf.zig");

pub const Error = c_int;
pub const UIElementRef = ?*anyopaque;
pub const ObserverRef = ?*anyopaque;
pub const ValueRef = ?*anyopaque;
pub const ValueType = u32;

pub const ObserverCallback = *const fn (
    observer: ObserverRef,
    element: UIElementRef,
    notification: cf.c.CFStringRef,
    refcon: ?*anyopaque,
) callconv(.c) void;

// Common AXError codes (subset).
pub const kAXErrorSuccess: Error = 0;
pub const kAXErrorAttributeUnsupported: Error = -25205;
pub const kAXErrorAPIDisabled: Error = -25211;
pub const kAXErrorNoValue: Error = -25212;

// AXValue payload type tags (from AXValue.h).
pub const kAXValueTypeCGPoint: ValueType = 1;
pub const kAXValueTypeCGSize: ValueType = 2;
pub const kAXValueTypeCGRect: ValueType = 3;
pub const kAXValueTypeCFRange: ValueType = 4;
pub const kAXValueTypeAXError: ValueType = 5;

pub extern "c" fn AXUIElementCreateApplication(pid: c_int) UIElementRef;
pub extern "c" fn AXUIElementCopyAttributeValue(
    element: UIElementRef,
    attribute: cf.c.CFStringRef,
    value: *cf.c.CFTypeRef,
) Error;
pub extern "c" fn AXUIElementSetAttributeValue(
    element: UIElementRef,
    attribute: cf.c.CFStringRef,
    value: cf.c.CFTypeRef,
) Error;
pub extern "c" fn AXUIElementPerformAction(
    element: UIElementRef,
    action: cf.c.CFStringRef,
) Error;

pub extern "c" fn AXValueGetType(value: ValueRef) ValueType;
pub extern "c" fn AXValueGetValue(value: ValueRef, the_type: ValueType, value_ptr: *anyopaque) u8;

pub extern "c" fn AXIsProcessTrusted() u8;
pub extern "c" fn AXIsProcessTrustedWithOptions(options: cf.c.CFDictionaryRef) u8;

// Bounds the per-message timeout for AX calls on `element` (or system-wide
// if the system-wide element is passed). Without this, AX calls can block
// indefinitely on unresponsive apps. Pass seconds (e.g. 1.0).
pub extern "c" fn AXUIElementSetMessagingTimeout(element: UIElementRef, timeoutInSeconds: f32) Error;
pub extern "c" fn AXUIElementCreateSystemWide() UIElementRef;

// AXObserver — receives AX notifications for an application. Each observer
// is bound to a single pid at create time. Add the runloop source from
// `AXObserverGetRunLoopSource` to a CFRunLoop for callbacks to fire.
pub extern "c" fn AXObserverCreate(
    application: c_int, // pid
    callback: ObserverCallback,
    out_observer: *ObserverRef,
) Error;
pub extern "c" fn AXObserverAddNotification(
    observer: ObserverRef,
    element: UIElementRef,
    notification: cf.c.CFStringRef,
    refcon: ?*anyopaque,
) Error;
pub extern "c" fn AXObserverRemoveNotification(
    observer: ObserverRef,
    element: UIElementRef,
    notification: cf.c.CFStringRef,
) Error;
pub extern "c" fn AXObserverGetRunLoopSource(observer: ObserverRef) cf.c.CFRunLoopSourceRef;

// Private. Stable across releases. Returns the CGWindowID for an
// AXUIElement that wraps a window. Errors signal "not a window" or
// "AX permission revoked".
pub extern "c" fn _AXUIElementGetWindow(elem: UIElementRef, out_wid: *u32) Error;

// Private. Constructs an AXUIElement from a 20-byte "remote token":
// bytes 0..4 = pid (i32), bytes 4..8 = 0, bytes 8..12 = magic 0x636f636f
// ("cooo"), bytes 12..20 = AX UI element ID (u64). The element-ID
// counter starts at 0 per process and increments as new UI elements
// are created. Iterating IDs 0..1000 per pid surfaces windows AX hides
// from kAXWindowsAttribute (e.g. windows on other Spaces). Returned
// element is retained (+1); caller must CFRelease.
pub extern "c" fn _AXUIElementCreateWithRemoteToken(data: cf.c.CFDataRef) UIElementRef;

/// Calls AXIsProcessTrustedWithOptions with the prompt option set, which
/// surfaces the macOS Accessibility dialog the very first time and no-ops
/// on subsequent launches once the user has decided. Returns the current
/// trust state (1 = granted, 0 = denied/not yet decided).
pub fn promptTrust() u8 {
    const k = cf.c.CFStringCreateWithCString(null, "AXTrustedCheckOptionPrompt", cf.c.kCFStringEncodingUTF8) orelse
        return AXIsProcessTrusted();
    defer cf.c.CFRelease(k);
    var keys = [_]?*const anyopaque{k};
    var values = [_]?*const anyopaque{cf.c.kCFBooleanTrue};
    const opts = cf.c.CFDictionaryCreate(
        null,
        &keys,
        &values,
        1,
        &cf.c.kCFTypeDictionaryKeyCallBacks,
        &cf.c.kCFTypeDictionaryValueCallBacks,
    ) orelse return AXIsProcessTrusted();
    defer cf.c.CFRelease(opts);
    return AXIsProcessTrustedWithOptions(opts);
}
