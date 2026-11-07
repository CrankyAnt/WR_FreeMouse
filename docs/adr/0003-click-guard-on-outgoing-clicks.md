---
status: accepted
---

# An Outgoing Click is protected by a Click Guard

When a click lands on another window while the game has focus, the game loses
focus and its Cursor Warp moves the pointer to the edge of the game's monitor
while the button is still down; Windows takes that as dragging the clicked
window by its title bar, drags it onto the game's monitor and snaps it at the
edge, after which Snap Assist opens. Diagnostic logs showed the pointer and the
clicked window moving by the same distance, 988 pixels within about 9 ms of the
button down, and 473 pixels in a repeat. From the button down of every Outgoing
Click, before any Cursor Warp, the helper pins the pointer to within a few
pixels of the click position until about 35 ms after the game lost focus, and
at most 120 ms, and then releases it. The button down and up pass unchanged;
movement beyond those few pixels is undone while the Click Guard holds, so a
deliberate drag continues once it ends.

## Considered options

- **Replaying one clean click after intercepting the original:** Snap Assist
  also appeared when the original click passed unchanged, so the cause was not
  a double click.
- **Correcting a Cursor Warp after it was detected:** Snap Assist also appeared
  without a detected warp, so a correction after the fact did not cover the
  cause.
