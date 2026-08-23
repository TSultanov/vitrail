## A task switcher for Windows that displays opened windows in a colorful grid

This app is heavily inspired by [XWinMosaic](https://github.com/soulthreads/xwinmosaic) and implemented entirely in [Zig](https://ziglang.org/).

## Features
- [x] Displaying opened windows in a grid and allowing switching between them
- [x] Showing virtual desktop number in the background of a tile
- ~[ ] Support for showing windows only from current virtual desktop~
- [x] Incremental search in the list of windows
- [x] Closing a window from its tile's context menu
- [x] Refreshing the visible grid automatically as windows change

## Known issues
- Icons and windows visibility states aren't resolved correctly for all applications

## Building
- Clone this repository
- Download latest nightly build of Zig from https://ziglang.org/download/ and extract it (last tested with 0.9.1).
- Open PowerShell in the directory with this repository
- Run `path\to\zig.exe build`

## Installing

Build and install for the current platform with GNU Make:

- `make install-user` installs for the current user.
- `make install` installs system-wide. Linux requests elevation for the copy
  step; a standard macOS admin account can install directly into `/Applications`.
- On Windows, run `make install` from an elevated terminal for a system-wide installation.

The default destinations are `~/Applications` or `/Applications` on macOS,
`~/.local/bin` or `/usr/local/bin` on Linux, and LocalAppData or Program Files
on Windows. Destination variables in the Makefile can be overridden when
staging packages or using a nonstandard location.
On a managed or non-admin Mac, use `make install MACOS_SUDO=sudo` if writing to
`/Applications` requires elevation.

On macOS, installation signs the bundle with the first valid code-signing
identity in the user's keychain. This stable identity is necessary for macOS
to retain Accessibility permission across rebuilds. Override the selection
with `MACOS_CODESIGN_IDENTITY="identity name or SHA-1"`. The first transition
from an older unsigned installation may require removing and granting its
existing Accessibility entry once; subsequent signed updates retain the permission.
Vitrail detects a first-run Accessibility grant while it is open and retries a
pending switcher request, so granting access does not require another restart.
The macOS install targets stop a running Vitrail instance before replacing the
bundle, ensuring the next launch uses the newly installed build.

## Downloading
You can download recent build from the [releases page](https://github.com/TSultanov/vitrail/releases).

## Running
Execute `.\zig-out\bin\vitrail.exe`. Pressing `Alt-Space` opens the window grid.
