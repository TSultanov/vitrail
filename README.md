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
- `sudo make install` installs system-wide on macOS and Linux.
- On Windows, run `make install` from an elevated terminal for a system-wide installation.

The default destinations are `~/Applications` or `/Applications` on macOS,
`~/.local/bin` or `/usr/local/bin` on Linux, and LocalAppData or Program Files
on Windows. Destination variables in the Makefile can be overridden when
staging packages or using a nonstandard location.

## Downloading
You can download recent build from the [releases page](https://github.com/TSultanov/vitrail/releases).

## Running
Execute `.\zig-out\bin\vitrail.exe`. Pressing `Alt-Space` opens the window grid.
