# 0190 — void failable (`-> !`) implicit fall-through leaves the error slot uninitialized

**Status:** RESOLVED

> **Root cause:** `ensureTerminator` (the unified implicit fall-through /
> epilogue synthesis in `src/ir/lower/control_flow.zig`) handled `void` and
> `noreturn`, but for a pure-failable return type (an `.error_set`) it fell
> through to the generic `else` arm and emitted `ret const_undef(ret_ty)`,
> leaving the error-channel slot undefined. The bare-`return;` path in
> `lowerReturn` (`src/ir/lower/stmt.zig`) already wrote `constInt(0, ret_ty)`
> ("no error") for the same case, so adding an explicit `return;` masked the
> bug.
>
> **Fix:** `src/ir/lower/control_flow.zig` `ensureTerminator` — added an arm
> that, for a pure-failable (`!ret_ty.isBuiltin() and types.get(ret_ty) ==
> .error_set`) end-of-body fall-through, emits `ret constInt(0, ret_ty)`,
> matching the explicit-`return;` success path. This covers ALL failable
> functions that fall through, not just `main`.
>
> **Sibling fix (value-failable trailing success expression):** adversarial
> review found the SAME uninitialized-error-slot bug on a value-carrying
> failable (`-> T !E` / `-> Tuple(A,B) !E`) whose body ends in a trailing
> success EXPRESSION (no explicit `return`). `lowerValueBody`
> (`src/ir/lower/stmt.zig`) blindly `coerceToType`+`ret`'d the bare success
> value to the full failable tuple type, leaving the success error-tag slot
> uninitialized → phantom `catch`/`or` on SUCCESS (and a dropped value /
> `ret { ... } undef` for string + multi-value returns). **Fix:** before the
> generic `coerceToType`+`ret`, mirror the explicit-`return EXPR;` branch — when
> `ret_ty` is a value-failable tuple (`!ret_ty.isBuiltin() and
> types.get(ret_ty) == .tuple and self.errorChannelOf(ret_ty) != null`) call
> `self.lowerFailableSuccessReturn(val, ret_ty, span)` so the success error slot
> is set to 0. The pure-failable fall-through (above) and the missing-value
> error case (`-> i64 !E { }`) are untouched.
>
> **Generic + pack-instance fix (unification):** the same trailing-value
> body-return was hand-rolled (`coerceToType`+`ret`, no failable-success
> routing) in TWO more places — `monomorphizeFunction`
> (`src/ir/lower/generic.zig`) and `monomorphizePackFn`
> (`src/ir/lower/pack.zig`). A generic value-failable `($T) -> T !E { v }`
> instantiated at i64 / string / struct shipped an uninitialized error slot →
> phantom `catch` on success and `or` silently yielding the fallback (value
> corruption). **Fix:** both sites now DELEGATE the trailing-value return to the
> shared `lowerValueBody` (the same helper the decl path uses) instead of
> re-implementing it, so the value-failable success routing, the pure-failable
> fall-through, and the missing-value diagnostic are all handled in one place
> and can't drift again. With this, every body-return path that can carry a
> failable channel (decl, generic, pack-instance, closure/lambda) routes the
> trailing-success value through `lowerFailableSuccessReturn`. (The JNI
> native-method entry wrapper in `ffi.zig` still hand-rolls its body-return,
> but a JNI export crosses the C-ABI boundary where the error channel is
> forbidden by the ERR E5.1 FFI-boundary rule, so it can never be value-failable.)
>
> **Regression tests:**
> - `examples/errors/1061-errors-void-failable-fallthrough.sx` — a `-> !` callee
>   that succeeds by fall-through (its `catch` must not fire) called from a
>   `main :: () -> !` that also falls through (exit 0).
> - `examples/errors/1062-errors-value-failable-trailing-expr.sx` — value-failable
>   trailing-expression successes (`-> i64 !E { 99 }`, `-> string !E { "hi" }`,
>   `-> Tuple(i64,i64) !E { .(1,2) }`) each `catch`-handled (catch must not fire,
>   value correct), plus a real `raise` still firing the caller's catch.
> - `examples/errors/1063-errors-generic-value-failable-trailing-expr.sx` — a
>   generic value-failable `($T) -> T !E { v }` instantiated at i64 / string /
>   struct (each `catch`-handled, catch must not fire, value correct), the
>   `or`-form yielding the real value not the fallback, plus a generic that
>   `raise`s still firing the caller's catch.
>
> Full suite green (examples: 813 ran, 0 failed).

## Symptom

A `-> !` (void failable) function that exits by **implicit fall-through**
(no explicit `return;`) does not initialize its error-channel slot, so a
caller (or `main`) reads a non-zero garbage tag and reports a phantom
unhandled error.

- Observed: `main :: () -> ! { print("ok\n"); }` prints `ok` then
  `error: unhandled error reached main: error.` and exits **1**.
- Expected: exit **0** (specs.md §11: "the exit code is `0` for void /
  `-> !` success"). Adding an explicit trailing `return;` makes it exit 0.

This is the silent-uninitialized-slot failure mode: the success path
should write "no error" into the channel just like an explicit `return;`
does, but the fall-through path skips it.

## Reproduction

```sx
#import "modules/std.sx";

main :: () -> ! {
    print("ok\n");
}
```

Run: `./zig-out/bin/sx run repro.sx` → prints `ok`, then
`error: unhandled error reached main: error.`, exit 1 (should be 0).

A non-`main` void failable shows the same uninitialized slot downstream:

```sx
#import "modules/std.sx";

noop :: () -> ! { }                 // falls through, no `return;`
main :: () {
    noop() catch (e) { print("phantom: {}\n", e); }   // fires spuriously
}
```

Workaround (confirms root cause): an explicit `return;` at the end of the
`-> !` body initializes the slot and the phantom error disappears.

## Investigation prompt

The error channel for a `-> !` function is the last slot of the return
aggregate (specs.md §12 ABI). An explicit `return;` lowers to a write of
the "no error" sentinel into that slot; the **implicit fall-through** exit
path (end of body with no `return`) apparently omits that write, leaving
the slot whatever was on the stack.

Likely area: the function-epilogue / failable-return lowering in
`src/ir/lower/` (the path that synthesizes the implicit return for a
body that falls off the end — search for where a void/`-> !` function's
trailing fall-through is lowered, and where the error slot's "no error"
sentinel is written on the explicit-`return;` path). The fix: the
implicit fall-through of a failable function must initialize the error
slot to "no error" exactly like `return;` does.

Verification: the two repros above must exit 0 / not fire the catch;
`examples/errors/1026-errors-failable-main.sx` (which currently passes
only because it ends in `return;`) must keep passing. Add a regression
example: a `-> !` function (and a `main :: () -> !`) that succeeds by
fall-through with no explicit `return;`.

(Found by adversarial review during the tuple-syntax-cutover docs pass,
commit `989e18b7`. Pre-existing — independent of the tuple change.)
