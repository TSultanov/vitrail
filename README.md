## A task switcher for Windows that displays opened windows in a colorful grid

This app is heavily inspired by [XWinMosaic](https://github.com/soulthreads/xwinmosaic) and implemented entirely in [Zig](https://ziglang.org/).

## Features
- [x] Displaying opened windows in a grid and allowing switching between them
- [x] Showing virtual desktop number in the background of a tile
- [ ] Support for showing windows only from current virtual desktop
- [ ] Incremental search in the list of windows

## Known issues
- Icons and windows visibility states aren't resolved correctly for all applications

## Building
- Clone this repository
- Download latest nightly build of Zig from https://ziglang.org/download/ and extract it (last tested with 0.8.0-dev.1561).
- Open PowerShell in the directory with this repository
- Run `.\path\to\zig.exe build`

## Downloading
You can download recent build from the [releases page](https://github.com/ArtifTh/vitrail/releases).

## Running
Execute `.\zig-cache\bin\vitrail.exe`. Pressing `Alt-Space` opens the window grid.

## Screenshot
![Screenshot of the application](/docs/screenshot.png?raw=true)
