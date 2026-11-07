---
status: accepted
---

# The helper releases the Confinement from a separate process

Workers & Resources: Soviet Republic always runs in its own windowed mode and
binds the pointer to its window; its Windowed option is checked and greyed
out, and turning off edge scrolling stops map scrolling but not the
Confinement. WR FreeMouse is a separate background process that calls
`ClipCursor(NULL)` every few milliseconds while the game has focus, so each
Confinement the game sets is lifted again. It injects nothing into the game
process and changes no game file.

## Considered options

- **DXWnd with its "Release mouse outside window" option:** a general
  window-wrapping tool configured around the game executable, far heavier than
  lifting one Confinement.
