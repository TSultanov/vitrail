// Private CoreGraphicsServices APIs for Space (virtual desktop) discovery.
// These symbols are not in the public Apple SDK headers but ship inside the
// already-linked CoreGraphics framework binary. The same surface is used by
// Rectangle, AltTab, and Hammerspoon and has been stable across macOS
// releases — they survive code signing.

const cf = @import("cf.zig");

pub const ConnectionID = c_int;

// Mask values for CGSCopySpacesForWindows. 7 = current(1) | other(2) | fullscreen(4).
pub const SPACE_MASK_ALL: c_int = 7;

pub extern "c" fn CGSMainConnectionID() ConnectionID;

/// Returns a retained CFArray of CFDictionaries — one per managed display.
/// Each display dict has a "Spaces" CFArray of CFDicts; each Space dict has
/// an "id64" CFNumber.
pub extern "c" fn CGSCopyManagedDisplaySpaces(cid: ConnectionID) cf.c.CFArrayRef;

/// Returns a retained CFArray of CFNumbers — the Space IDs the given window
/// IDs belong to. windowIds is a CFArray of CFNumbers (window IDs as int).
pub extern "c" fn CGSCopySpacesForWindows(
    cid: ConnectionID,
    mask: c_int,
    windowIds: cf.c.CFArrayRef,
) cf.c.CFArrayRef;
