# 0287 — `Button.pressed` is lost when UI is rebuilt from `set_body` each frame

## Symptom

`modules/ui/button.sx` activates on `mouse_up` only if `self.pressed` is true
from a prior `mouse_down`. With `UIPipeline.set_body` (immediate-mode body
rebuild every frame), the `Button` value is recreated each tick with
`pressed = false`, so the up never fires. Apps either switch to `mouse_down`
activation or keep press state outside the view tree (as `Dock` does with
`DockInteraction.header_pressed`).

## Reproduction

```sx
#import "modules/std.sx";
#import "modules/ui";

// Minimal sketch: any app that uses set_body + Button with on_tap.
// Each frame: body() returns a fresh Button.{ pressed = false, ... }.
// mouse_down sets pressed on that frame's instance; the next frame's
// instance never sees it → mouse_up is a no-op.
```

Observed: taps on framework `Button` do nothing under `set_body`.
Expected: click = down on control + up on same control activates `on_tap`.

## Investigation prompt

Press state for interactive controls cannot live on view values when the
pipeline rebuilds the body every frame (`tick_with_body` dual arena). Fix
options:

1. Document that interactive state must be external (pattern used by
   `DockInteraction`); change `Button` to take `*bool` / press-state pointer
   for `pressed`/`hovered`.
2. Or teach the pipeline to retain identity for stateful widgets across
   rebuilds (harder).

Verify with a tiny `set_body` app that logs `on_tap` for a `Button` —
should fire once per full click after the fix.

## Context

Sudoku control pad hit the same issue and stores `ControlPressState` outside
the view tree (`g_ctrl_press`), activating on `mouse_up` only when the up
is still over the same control.
