# WR FreeMouse

WR FreeMouse is a small Windows helper for the Steam version of Workers & Resources: Soviet Republic. It lets the mouse pointer leave the game window and move to other monitors without Alt+Tab, and one click on the game makes it usable again.

## Overview

Workers & Resources locks the mouse pointer to the game window. With more than one monitor, reaching another screen or app then means pressing Alt+Tab every time.

While the game runs, WR FreeMouse lets you:

- move the pointer to another monitor and back without Alt+Tab;
- click other apps and the Windows taskbar as usual;
- click outside the game without the game pulling the pointer back and dragging the window you clicked;
- return to the game with a single click on it;
- see a pointer over the visible parts of the game while another window is active.

WR FreeMouse does not modify the game or its files. Setup adds it to the game's Steam launch options, so it starts and stops with the game. It has no window or tray icon.

## Requirements

- Windows with Windows PowerShell 5.1, which is part of Windows.
- Workers & Resources: Soviet Republic, installed and started through Steam. Setup works only with Steam.

WR FreeMouse also runs with one monitor, but it is made for setups with more than one. It needs no drivers, game mods or other downloads.

## Installation

1. Download `WR-FreeMouse.zip` from the [latest release](https://github.com/CrankyAnt/WR_FreeMouse/releases/latest). To check that the file is genuine, see [Verifying your download](#verifying-your-download).
2. Extract the whole ZIP to a folder. Setup does not run from inside the ZIP.
3. Close Workers & Resources.
4. Run `WR FreeMouse Setup.cmd` from the extracted folder.

On a fresh install, Setup shows this menu:

```text
Status: WR FreeMouse is not installed.

  [1] Install (recommended)
      Installs the runtime plus the optional observation-only debugger.
      The debugger never runs during normal play.

  [2] Install without debug tools
      Installs only the runtime. No diagnostic keyboard/mouse logging
      code is copied to the local WR FreeMouse installation.

Privacy: the optional debugger can log mouse buttons/positions and
selected NON-TEXT keys only when you explicitly start a debug session.

Choose [1]:
```

Press Enter to install with the optional debugger, or type `2` to leave it out. The debugger is described under [Debug report](#debug-report).

### What Setup changes

- Setup installs WR FreeMouse to `%LOCALAPPDATA%\Programs\WRFreeMouse`. It puts nothing in the game folder and adds nothing to Windows startup.
- Setup puts WR FreeMouse in front of the game's Steam launch options and keeps the options you already had, such as `-windowed`. It shows the new launch options before it writes them.
- Before it changes the launch options, Setup saves a copy of your Steam configuration as `Backup\Steam localconfig before last change.vdf` in the install folder.
- If Steam is running, Setup must restart it once and asks first. Any answer other than `Y` stops Setup without changes.
- If more than one Steam account has used this PC, Setup may ask which account to change.
- If your launch options contain `&`, `|`, `<`, `>`, `^`, a line break or more than one `%command%`, Setup stops and changes nothing.

Setup checks its own files before it changes anything. If a check fails, it shows `SETUP STOPPED` with the reason and makes no further changes.

### Verifying your download

Each official release is tied to three things:

- **A signed release tag.** The tag of each release, such as `v1.0.1`, is signed with CrankyAnt's SSH key, and GitHub marks it **Verified**.
- **Build provenance.** GitHub Actions builds the ZIP from the tagged source and records a signed attestation for it. Check the file you downloaded with the GitHub CLI:

  ```bash
  gh attestation verify "WR-FreeMouse.zip" --repo CrankyAnt/WR_FreeMouse
  ```

- **An immutable release.** After publication, nobody can change or replace the release or its files.

Together these confirm that the file came unchanged from this repository's own build. They do not show that the software is safe.

## Usage

Start Workers & Resources from Steam as usual. WR FreeMouse starts with it in the background, without a window. The game first opens its own settings/DirectX launcher, and WR FreeMouse becomes active when the actual game window appears. When you close the game, WR FreeMouse stops.

WR FreeMouse runs only when you start the game from Steam.

### Updating and repairing

Close the game, extract the new release and run `WR FreeMouse Setup.cmd`. Setup compares the installed version and build with the package:

- If the package is newer, Setup offers `Update`. It keeps your debug-tools choice and your launch options.
- If the package is the same, Setup offers `Repair / reinstall`, and can add or remove the debug tools.
- If the installed version is newer, Setup does not downgrade. It offers only `Cancel` or `Uninstall WR FreeMouse`.

### Uninstalling

Close the game, run `WR FreeMouse Setup.cmd` from an extracted release and choose `Uninstall WR FreeMouse`. Setup removes only WR FreeMouse's part of the Steam launch options and keeps the rest. It then deletes the install folder, including the Steam configuration backup. A `WR FreeMouse debug.txt` on your Desktop stays.

Do not delete the install folder yourself. The Steam launch options would still point to WR FreeMouse, and Steam could then fail to start the game.

## Troubleshooting

### Error files

WR FreeMouse shows no messages while you play. If it fails, look in `%LOCALAPPDATA%\Programs\WRFreeMouse` for:

- `WR FreeMouse error.txt`, written when the helper fails or cannot start;
- `WR FreeMouse launch error.txt`, written when the start through Steam fails.

Copy the text into your bug report before you start the game or run Setup again, because both delete these files.

### Setup stops before installing

Read the reason under `SETUP STOPPED`. Setup made no further changes. Common reasons are a running game, a declined Steam restart, and launch options that Setup cannot wrap safely.

### F24 cannot be registered

WR FreeMouse uses the F24 key internally while it runs. It registers F24, and it sends F24 presses itself while the game is active and the pointer is over another window. Most keyboards have no F24 key, but another program, such as a macro tool, can claim it. WR FreeMouse then does not start, and `WR FreeMouse error.txt` says that it could not register its internal F24 hotkey. Close that program and start the game again. A program bound to F24 can also react to the presses WR FreeMouse sends.

### The game cursor looks like a normal Windows arrow

WR FreeMouse reads the game's own cursor image from your installed game. If that fails, it uses the normal Windows arrow. In Steam, verify the game files (right-click the game, then **Properties > Installed Files > Verify integrity of game files**) and start the game again.

### The pointer jumps to the top-left corner when the game starts

When the game starts from its settings/DirectX launcher, the game itself can move the pointer to the top-left corner. This also happens without WR FreeMouse.

### Two pointers after Alt+Tab

If you press Alt+Tab while the game's cursor shows in the middle of the screen, the game can leave that cursor drawn in its paused picture. The extra cursor is part of the picture and does not affect your clicks. With WR FreeMouse you do not need Alt+Tab.

### Debug report

For input or focus problems, a report from the optional debugger helps. It needs the debug tools: install with option 1, or choose `Add optional debug tools` in Setup from the extracted release.

**Starting it.** In Setup, choose `Start observation-only debug session`, or run `WR FreeMouse Debug.cmd` from the install folder. You can start it before the game to capture startup problems. If the game runs without WR FreeMouse, the debugger starts WR FreeMouse and leaves it running afterwards.

**Stopping it.** Click the debugger window and press any key. It also stops by itself after 30 minutes of recording, or a few seconds after the game closes. It never stops the game or WR FreeMouse. At the end it shows where it saved the report: `WR FreeMouse debug.txt` on your Desktop. Each session overwrites that file.

**What it records.** The report contains:

- window and app titles, focus changes and window moves;
- mouse clicks and the mouse wheel, each with the pointer position;
- your screen layout;
- a fixed set of non-text keys: Shift, Ctrl, Alt, the Windows and Menu keys, arrows, Home, End, Page Up, Page Down, Insert, Delete, Backspace, Tab, Enter, Space, Esc, Caps Lock, Pause, Print Screen and F1 to F24;
- WR FreeMouse's installation state, including the Steam configuration path and launch options.

It does not record letter or number keys, and it does not read what is inside your apps. Window titles can still show a website or document name, and the Steam path can contain your Windows user name. **Read `WR FreeMouse debug.txt` before you share it.**

**Removing it.** In Setup, `Remove debug tools from the local installation` deletes the debugger from the install folder. The WR FreeMouse runtime contains no keyboard or mouse logger. The extracted release still contains the debugger files until you delete it.

## Reporting issues

Report a bug by [opening an issue](https://github.com/CrankyAnt/WR_FreeMouse/issues/new). Issues are public. Include:

- the WR FreeMouse version and build, shown in Setup's title line;
- your monitor layout;
- the text of any error file or `SETUP STOPPED` message;
- for input or focus problems, a `WR FreeMouse debug.txt` that you have read through.

## License and distribution

WR FreeMouse is released under the [MIT License](LICENSE.md). Per-file license details follow the REUSE specification in [REUSE.toml](REUSE.toml).

WR FreeMouse contains no game files. It reads the cursor image from your installed copy of the game. It is an independent, unofficial tool and is not affiliated with or endorsed by the makers of Workers & Resources: Soviet Republic.

## [Changelog](CHANGELOG.md)
