# 0182 — a body-local `#run` of an unbridged-shape return silently miscompiles (no abort, exit 0 garbage)

> **RESOLVED.** Root cause was deeper than "doesn't set comptime_failed": the
> body-local `#run` fold in `emitCall` (`src/backend/llvm/ops.zig`) was effectively
> DEAD — gated on `args.len==0`, but the `__ct` comptime wrapper always carries
> the implicit `*Context` arg — so EVERY body-local `#run` fell through to a
> RUNTIME call (bridgeable shapes lucked into the right value; unbridgeable ones
> ran over `---` storage → garbage). Fix: fold any `is_comptime` callee (gated
> `!enclosing.is_comptime` so nested metatype calls in a comptime wrapper's dead
> body aren't folded). On a `tryEval` bail, distinguish a BRIDGE bail (body ran,
> result shape can't `regToValue`-materialize → `error: comptime init of '<name>'
> failed: <reason>` + `comptime_failed`, build fails — symmetric with the global
> `#run` path) from an EXECUTION bail (VM can't run the body, e.g. NaN/extern →
> runtime fallthrough, preserving `examples/types/0150`), via a new
> `comptime_vm.last_bail_was_bridge` flag (reset at `tryEval` entry, set only at
> the `regToValue` step). The binding const's name is threaded onto the wrapper
> (`comptime_display_name`) so the diagnostic reads `'L'` not `__ct_N`.
> Regressions: `examples/diagnostics/1204-diagnostics-comptime-run-unbridged-shape.sx`
> (negative), `examples/comptime/0645-comptime-body-local-run-bridgeable.sx`
> (positive). Verified by 3 adversarial reviews; suite 801/0. (Note: a BARE
> inline `#run` of an unbridgeable shape correctly fails but names the internal
> `__ct_N` — a cosmetic diagnostic-name follow-up, build behavior is correct.)

## Symptom

A `#run` const declared INSIDE a function body, whose comptime function returns a
shape the comptime VM cannot bridge to a host `Value` (e.g. `[2][]i64` — array of
slices, or a struct containing a slice that can't be const-materialized), does
NOT fail the build. Unlike a GLOBAL `#run` const (which sets `comptime_failed`
and aborts cleanly with `error: comptime init of 'X' failed: ...` — see issue
0167's recovery guard), the body-local form leaves a RUNTIME call to the comptime
function in place, executing it at runtime over uninitialized (`---`) storage →
garbage, exit 0, NO diagnostic. Silent miscompile (no-silent-fallback violation).

Found during adversarial review of issue 0167.

## Reproduction

```sx
#import "modules/std.sx";
mk :: () -> [2][]i64 { a : []i64 = ---; r : [2][]i64 = ---; r[0] = a; r[1] = a; return r; }
main :: () {
  L :: #run mk();        // body-local #run of an unbridgeable shape
  print("{}\n", L[0][0]);  // prints garbage, exit 0 — should be a clean comptime error
}
```

Expected: a clean `error: comptime init of 'L' failed: ...` (exit 1), the same as
the equivalent GLOBAL `#run` const. Observed: garbage output, exit 0, no
diagnostic. (Even an UNUSED body-local `L :: #run mk()` silently "succeeds"
instead of reporting the bridge failure.)

## Investigation prompt

`src/ir/lower/comptime.zig` `lowerInlineComptime` (~line 337) emits a RUNTIME
`call` to the comptime function and relies on the interpreter to const-fold it.
When the fold/`regToValue` bridge cannot materialize the result, the runtime call
is left in place rather than failing — so the comptime fn runs at runtime over
`---` storage. The fix: when a body-local `#run` const-fold fails to materialize
(the same `regToValue` bail that a global `#run` reports), it must set
`comptime_failed` / emit the `comptime init of 'X' failed: <reason>` diagnostic
and abort, exactly like the global-init path (`failGlobalInit` in
`src/ir/emit_llvm.zig`), NOT silently fall back to a runtime call. Mirror the
global path's loud failure. Verify: the repro exits 1 with the comptime
diagnostic; a body-local `#run` of a BRIDGEABLE shape (scalar, struct, array,
`?Arr`) still works (don't regress the common case); an unused failing body-local
`#run` also aborts. Add an `examples/comptime/06xx-...` (or a diagnostics) test.
