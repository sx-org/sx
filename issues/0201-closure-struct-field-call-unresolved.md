> **RESOLVED** (2026-06-28). Root cause: `CallResolver.plan`'s `.field_access`
> branch had no arm for a struct field whose type is a `.closure` / `.function`
> value, so the call typed as `.unresolved` (the lowering side already dispatched
> it via `call_closure`/`call_indirect`, but the type used for arg-boxing /
> `try`/`catch` came from `plan`). Fix: added a closure/fn-pointer field arm in
> `src/ir/calls.zig` (`plan`), placed before the instance-method check to mirror
> lowering's precedence (a closure-typed field shadows a same-named method), and
> extended the lowering closure-field arm in `src/ir/lower/call.zig` to also
> handle bare `.function` fields (`call_indirect`, ctx-prepend gated on the
> fn-ptr ABI). Regression test:
> `examples/closures/0315-closures-struct-field-call.sx` (closure field with
> args, failable field via `*self` receiver — success + error, and a bare
> fn-pointer field). Suite 852/0.

# 0201 — calling a closure stored in a struct field types as `unresolved`

**Symptom** — Calling a closure value held in a **struct data field**
(`box.run()` where `run: Closure(...) -> R`) does not resolve the call's
return type: the result types as `unresolved`. For a value-returning closure
this silently produces garbage (the result is never marshaled); for a failable
closure (`Closure() -> (T, !)`) `try`/`catch` reject the call with "`catch`
requires a failable expression; operand has type 'unresolved'".

Observed vs expected:
- `b.run()` where `run: Closure() -> i64` prints a garbage pointer-ish integer
  (e.g. `4313325408`) instead of the closure's actual return value `7`.
- The IDENTICAL closure bound to a **local variable** (`f := () => {7}; f()`)
  works and prints `7`.
- A **void**-returning closure field (`run: Closure() -> void; b.run()`) works
  for its side effects (no result to marshal), which is why `std/io.sx`'s
  `ThunkBox { run: Closure() -> void }` is unaffected.

**Scope / impact** — Pre-existing, independent of the PLAN-IO-UNIFY Phase 3
capture-typing fix (it reproduces at top level with no closures-capturing-
closures and no nesting). Does **NOT** block Phase 3: the async layer routes all
generic-ness through a captured worker + a void completion closure field, both of
which work. Worth fixing because the value-return case is silent corruption.

**Reproduction** (standalone, only needs the prelude):

```sx
#import "modules/std.sx";
Box :: struct { run: Closure() -> i64; }
main :: () -> i64 {
    b : Box = ---;
    b.run = () => { 7 };
    print("{}\n", b.run());   // prints garbage; expected 7
    return 0;
}
```

Failable variant (the shape that surfaced it):

```sx
#import "modules/std.sx";
Box :: struct { run: Closure() -> (i64, !); }
main :: () -> i64 {
    b : Box = ---;
    b.run = () -> (i64, !) => { 7 };
    r := b.run() catch { return -1; };   // error: catch requires a failable
    print("{}\n", r);                     //        expression; operand 'unresolved'
    return 0;
}
```

**Investigation prompt** — The call-type resolver `CallResolver.plan` in
[src/ir/calls.zig](../src/ir/calls.zig) has a `field_access` callee branch
(~line 230 onward) that handles protocol dispatch, runtime-class instance
methods, `StructName.method` instance methods, and free-fn UFCS — but has **no
arm for a struct field whose type is a `.closure` (or `.function`) value**. When
none of those match it falls through to `.unresolved` (e.g. line ~315 / the tail
return). Compare the BARE-identifier path (~lines 211–227) which already handles
`ti == .closure → ti.closure.ret` / `ti == .function → ti.function.ret` for a
local binding — the field-access path needs the equivalent: resolve the
receiver's struct type, look up the named field, and if the field's type is a
closure/function, return its `.ret` with the right call kind (an indirect/closure
call on the loaded field value).

The fix likely needs a new `CallPlan.kind` (or reuse of the closure-call kind)
for "call a closure loaded from a struct field", and the lowering side
(`lowerCall` field-access path in [src/ir/lower/expr.zig](../src/ir/lower/expr.zig))
must load the field then perform an indirect closure call (env + fn-ptr), the
same machinery a local closure-variable call uses. Mind the failable case: once
the return type resolves to a `(T, !)` tuple, `errorChannelOf` and the
`try`/`catch` paths work automatically (verified: a local failable closure call
already does).

**Verification** — run both repros above; expect `7` from the first and `7`
(success) / `-1` (error) from the failable variant, with no `unresolved`
diagnostic. Add a regression example under `examples/closures/` (value + failable
field-call) once fixed.
