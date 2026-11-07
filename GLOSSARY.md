# WR FreeMouse

WR FreeMouse lets the pointer move freely across several monitors while Workers & Resources: Soviet Republic runs, and keeps a usable cursor when the pointer returns to the game.

## Language

### The game and the pointer

**Confinement**:
The game binding the pointer to its own window.
_Avoid_: Clip, mouse capture

**Cursor Warp**:
The game moving the pointer back to the edge of its own monitor at the moment it loses focus, even while a mouse button is still held down.
_Avoid_: Jump, cursor pull

**Exposed Game Surface**:
The part of the game window that no other window covers.
_Avoid_: Visible game, game area

### What the helper does

**Outgoing Click**:
A left click, while the game has focus, on a window other than the game that can be activated, or on a Windows taskbar.
_Avoid_: External click, desktop click

**Click Guard**:
The brief pinning of the pointer to the position of an Outgoing Click, so that the Cursor Warp cannot drag the clicked window.
_Avoid_: ClickGuard, warp guard

**Focus Sink**:
An invisible window of the helper that can hold focus in place of the game without any visible window being activated.
_Avoid_: Focus window

**Helper Cursor**:
The arrow the helper shows over the Exposed Game Surface while another window has focus and the system cursor is hidden there.
_Avoid_: Fake cursor
