# WR FreeMouse

WR FreeMouse is a lightweight Windows helper for **Workers & Resources: Soviet Republic**.
It frees the mouse cursor so it can move across multiple monitors without Alt-Tab, and gives
you a usable cursor again the moment you return to the game.

> **Status:** early development. The helper is still being built and tested; expect rough
> edges and changing internals.

## Overview

Workers & Resources runs in its own windowed/borderless mode that confines the mouse cursor
to the game window. On a multi-monitor setup that makes it awkward to reach a browser, a chat
app, or a second screen without Alt-Tabbing out, and the game has no built-in "release cursor
at window edge" option. WR FreeMouse solves this from the outside, without modifying game
files or injecting code.

- Frees the cursor so it can leave the game window and travel across all your monitors while
  W&R keeps running.
- Prevents the Windows 11 "Snap Assist" glitch that otherwise appears when you click another
  window while the game is focused.
- Shows where your pointer is over the game with a lightweight, click-through cursor overlay,
  so you always know which screen and app your input will land on.
- Touches no game files. It runs as a small background helper and can be started automatically
  through Steam's launch options.

How each of these is implemented is documented in the source.

## Requirements

- Windows, with a multi-monitor setup
- Workers & Resources: Soviet Republic

## Installation

There is no released build yet. Once one is available it will be published on the repository's
[Releases](https://github.com/CrankyAnt/WR_FreeMouse/releases) page, and the setup steps will
land here together with it.

## Usage

Detailed instructions will land together with the first released build. In short, the helper is
designed to start alongside the game (optionally via Steam **Properties → General → Launch
Options**) and to be stopped again with a hotkey or a stop script.

## Reporting Issues

Found a bug? Please open a GitHub issue:

<https://github.com/CrankyAnt/WR_FreeMouse/issues/new/choose>

Including your monitor layout and a log from the helper is especially helpful.

## Notes

WR FreeMouse is an independent, unofficial tool. It is not affiliated with or endorsed by the
developers or publishers of Workers & Resources: Soviet Republic.

## License

This repository uses per-file license assignment according to the REUSE specification. See
[REUSE.toml](REUSE.toml) for the authoritative machine-readable record.

Every file is licensed under the [MIT License](LICENSE.md) — free to use, modify, and
redistribute. If you copy or build on this project, please keep the original copyright and
attribution to CrankyAnt; the MIT license requires it.
