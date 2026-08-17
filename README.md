# WR FreeMouse

WR FreeMouse is a small Windows helper for **Workers & Resources: Soviet Republic**.
It lets your mouse move freely across multiple monitors without Alt+Tab, and gives you a usable
cursor back in the game the moment you click into it.

> Version 1.0.0 — first public release.

## Overview

On a multi-monitor setup, Workers & Resources keeps your mouse locked to the game window, so
reaching another screen or app means Alt+Tabbing out every time.

WR FreeMouse removes that limitation. While the game is running you can:

- move the mouse straight to another monitor and back — no Alt+Tab;
- click other apps and the taskbar like normal;
- click outside the game without it accidentally doing something in-game or shuffling your
  windows around;
- get back into the game with a single click;
- see where your pointer is over the game, even when another window is in front.

It doesn't change or modify the game in any way, and it starts and stops together with the game
through Steam.

## Requirements

- Windows, with more than one monitor
- Workers & Resources: Soviet Republic
- Windows PowerShell 5.1 (already part of Windows)

No extra downloads, drivers, or game mods are needed.

## Installation

Download the release, extract it, and run:

```text
WR FreeMouse Setup.cmd
```

WR FreeMouse installs to your user profile (`%LOCALAPPDATA%\Programs\WRFreeMouse`). It is not
installed into the game folder and it does not add anything to Windows startup.

On a fresh install Setup offers two choices:

```text
[1] Install (recommended)
    Runtime + optional observation-only debugger

[2] Install without debug tools
    Runtime only
```

The debugger is an optional diagnostic tool that never runs during normal play. Option [2]
leaves it out entirely.

## Usage

Once installed, start Workers & Resources through Steam as usual. WR FreeMouse starts alongside
it — you won't see a separate window. The game opens its own settings/DirectX launcher first, and
WR FreeMouse simply waits for the actual game to appear.

Setup handles the Steam side for you:

- it keeps any launch options you already had (such as `-windowed`);
- it backs up your Steam configuration and asks before restarting Steam;
- if your launch options are too unusual for Setup to wrap safely, it leaves them untouched and
  tells you, instead of risking a broken launch.

**Updating or repairing.** Setup saves the installed version and build in the app folder and
compares them with the package you run — offering an update for a newer package, or a
repair/reinstall for the same version. Your debug-tools choice and existing launch options are
kept, and a newer install is never downgraded.

**Uninstalling.** Run Setup again and choose **Uninstall**. It removes only WR FreeMouse's part
of your Steam launch options — anything else you had stays — and then removes the install folder.

## Optional debugger

The optional debugger records mouse and window activity so you can attach a report to a bug. It
never runs on its own.

**Starting it.** In Setup, choose **Start observation-only debug session** — or run
`WR FreeMouse Debug.cmd` from the install folder directly (you don't need the downloaded ZIP for
that). You can start it before the game to catch startup problems. A session runs for up to
30 minutes and then stops by itself.

**Stopping it.** Click the debugger window and press any key. It stops, shows where the report
was saved (`WR FreeMouse debug.txt` on your Desktop), and leaves the game running.

**What it records.** To help debug input and focus, it can log:

- window and app titles, mouse movement, clicks, and the mouse wheel;
- a limited set of **non-text** keys — modifiers, arrows, and F-keys.

It does **not** record letters or numbers you type, and it does not read what's inside your apps.
Window titles can still reveal things like a website or document name, so **look at
`WR FreeMouse debug.txt` before you share it.**

**Removing it.** The debugger is the only part that watches your keys and mouse. In Setup,
**Remove debug tools** deletes it; the runtime that stays behind records nothing. You can also
delete the debugger files yourself. Setup keeps working for repair, update, and uninstall without
it — to add it back later, download the release again and run Setup.

## Troubleshooting

**Setup stops before installing.** Setup checks itself before making changes and stops if
something isn't right, rather than installing a broken version.

**F24 can't be registered.** WR FreeMouse reserves the F24 key while it runs. Most keyboards
don't have an F24 key, but another program can still claim it. Close that program and start
again — WR FreeMouse stops on purpose rather than run without this protection.

**The game cursor looks like a normal Windows arrow.** WR FreeMouse couldn't load the game's own
cursor. In Steam, verify the game files (right-click the game → **Properties → Installed Files →
Verify integrity**) to restore it, then start the game again.

**Startup or the helper fails.** If an error file appears in the install folder, keep it — copy
its exact message into your bug report. For input or focus problems, start the optional debugger
and attach `WR FreeMouse debug.txt`.

## Reporting Issues

Found a bug? Please open a GitHub issue:

<https://github.com/CrankyAnt/WR_FreeMouse/issues/new/choose>

Helpful things to include:

- your monitor layout;
- the exact error message, if you saw one;
- for input or focus problems, a `WR FreeMouse debug.txt` from the optional debugger.

## Verifying your download

Every official release is tied to three things, so you can be sure a download is genuine:

- **A signed release tag** — the `v1.0.0` tag is signed with CrankyAnt's personal key, and
  GitHub marks it **Verified**.
- **Build provenance** — GitHub builds the ZIP from the tagged source and records signed
  provenance for it. You can check the exact file you downloaded with the GitHub CLI:

  ```bash
  gh attestation verify "WR-FreeMouse.zip" --repo CrankyAnt/WR_FreeMouse
  ```

- **An immutable release** — once published, the release and its files can't be changed or
  swapped.

Together these confirm the file came from this repository's own build, unchanged. It is not a
scan that says the software is safe.

## Notes

### Installed files

A normal install has the helper and its launch files plus a small state file. With debug tools,
it also has the debugger:

```text
WR FreeMouse state.json
WR FreeMouse Launch.ps1
WR FreeMouse Launch.vbs
WR FreeMouse Runtime.ps1
WR FreeMouse Debug.cmd        (optional)
WR FreeMouse Observer.ps1     (optional)
Backup\
  Steam localconfig before last change.vdf
```

`WR FreeMouse state.json` holds the details Setup needs to update, repair, and uninstall safely.
`Backup\` keeps a copy of your Steam configuration in case it needs restoring.

**Game cursor.** WR FreeMouse doesn't include any game files. It shows the game's own cursor by
reading it from your installed copy of Workers & Resources. If it can't, it falls back to the
normal Windows arrow.

**Known game behaviour.** When Workers & Resources starts the actual game from its
settings/DirectX launcher, the game itself can jump the cursor to the top-left corner. This also
happens without WR FreeMouse, so it isn't something WR FreeMouse changes.

**Known limitation.** If you Alt+Tab while the game's cursor is showing in the middle of the
screen, the game may leave that cursor drawn in its frozen picture. You might briefly see two
cursors — the extra one is just part of the paused image and doesn't affect your clicks. Normal
use doesn't need Alt+Tab.

**Disclaimer.** WR FreeMouse is an independent, unofficial tool. It is not affiliated with or
endorsed by the makers of Workers & Resources: Soviet Republic.

## License

WR FreeMouse is released under the [MIT License](LICENSE.md). You are free to use, change, and
build on it — including in your own or closed-source projects — as long as the original copyright
and license notice stays with the parts you take.

Per-file license details follow the REUSE specification; see [REUSE.toml](REUSE.toml) for the
authoritative record.

## Changelog

### 1.0.0

Initial public release: free mouse movement across monitors, clean handoff to and from the game,
a single-click return, an in-game cursor over exposed parts of the game, silent start through
Steam, and an optional observation-only debugger.
