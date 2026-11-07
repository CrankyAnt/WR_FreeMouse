---
status: accepted
---

# Only a click activates the game, and a Helper Cursor shows the pointer until then

With several monitors the pointer keeps crossing the game window on its way to
other windows, and its movement says nothing reliable about whether the user
wants the game. The helper never gives the game focus: a click on the Exposed
Game Surface activates the game through Windows' own click activation, and the
original button down and up reach the game unchanged. While another window has
focus and the system cursor is hidden over the Exposed Game Surface, the Helper
Cursor shows where the pointer is, so the user sees which window a click will
reach before anything is activated.

## Considered options

- **Focus that follows the monitor or the window under the pointer:** windows
  behind the game became unusable and the cursor flickered.
- **An intent model from movement and timing:** a timer measures time, not
  intent, and an armed state after a pause stayed valid for every later
  movement; direction alone says nothing without knowing where windows are.
- **Synthesised button releases:** they opened context menus.
- **Forcing foreground with `AttachThreadInput`:** it shares keyboard and focus
  state between threads, resets keyboard state and disturbed Task View.
- **Showing the real Windows cursor with `SetCursor`:** a negative cursor
  display count keeps it hidden, and the window under the pointer can replace
  it on the next movement.
