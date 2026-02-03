# 0167 — comptime `#run` returning an aggregate that contains an array fails the reg→value bridge (+ unclean recovery)

> **RESOLVED.** (C) Added an `.array` arm to `regToValue` in
> `src/ir/comptime_vm.zig`: reads N elements at stride `typeSizeBytes(elem)` from
> the array's address and recursively bridges each via `regToValue(elem_ty)` →
> an `.aggregate` Value (`serializeAggregateValue` already handles arrays).
> Composes with struct-field walks, nested arrays, array-of-structs, and the
> `?Arr` optional payload; unbridgeable element types bail loudly. (E) Added
> `if (self.comptime_failed) return;` in `emit()` (`src/ir/emit_llvm.zig`) after
> Pass 0, so a GLOBAL failing `#run` aborts cleanly (exit 1, the `comptime init
> of 'X' failed: …` diagnostic) instead of panicking `unresolved type reached
> LLVM emission` — verified across `sx run`/`ir`/`build`. Regression:
> `examples/comptime/0644-comptime-run-array-aggregate.sx`. Verified by 3
> adversarial reviews; suite 793/0. The issue's (E) repro `A?.xs[0]` now routes
> to two SEPARATE pre-existing bugs filed during review: **0181** (optional-chain
> `?.` to an array field then `[idx]` → unresolved panic, pure-runtime) and
> **0182** (body-local `#run` of an unbridged shape silently miscompiles —
> `lowerInlineComptime` doesn't set `comptime_failed`). Both are out of 0167's
> reg→value-bridge scope.
## Symptom

Two related defects:

**(C)** A `#run` (comptime const init) whose function returns a struct/aggregate
**containing an array field** fails comptime evaluation with a LOUD bail:

`error: comptime init of 'G' failed: reg→value: aggregate shape not bridged yet`

This is the general array-in-aggregate gap in the comptime VM's `regToValue`
bridge — it handles scalar/struct/slice/tuple/optional payloads but not an array
nested inside the aggregate. (The `?Arr` form noted while fixing issue 0162 is
the SAME root cause, not optional-specific.) This is a loud limitation, not a
silent miscompile.

**(E)** When such a comptime init has already failed, downstream codegen does not
hard-abort: a later use of the now-`unresolved`-typed const (e.g.
`A?.xs[0]`) panics `unresolved type reached LLVM emission` (exit 134) instead of
the clean exit-1 the compiler should produce after a comptime-init failure.

## Reproduction

C (loud bail — the primary feature to implement):
```sx
#import "modules/std.sx";
Arr3 :: struct { xs: [3]i64; }
mk :: () -> Arr3 { r : Arr3 = ---; r.xs[0]=1; r.xs[1]=2; r.xs[2]=3; return r; }
G :: #run mk();
main :: () { print("{} {} {}\n", G.xs[0], G.xs[1], G.xs[2]); }
```
Expected: `1 2 3`. Observed: `error: ... reg→value: aggregate shape not bridged yet`, exit 1.

E (recovery should be clean, not a panic):
```sx
#import "modules/std.sx";
Arr3 :: struct { xs: [3]i64; }
mk :: () -> ?Arr3 { r : Arr3 = ---; r.xs[0]=1; r.xs[1]=2; r.xs[2]=3; return r; }
A :: #run mk();
main :: () { print("{}\n", A?.xs[0]); }
```
Observed: `panic: unresolved type reached LLVM emission`, exit 134. Expected:
once (C) is implemented this evaluates; independently, a failed comptime init
must abort cleanly (exit 1) rather than reach LLVM emission.

## Investigation prompt

**C:** `src/ir/comptime_vm.zig` `regToValue` (the `failMsg("reg→value: aggregate
shape not bridged yet")` bail, ~line 2270). Add an array arm: read `len` elements
of the element type from the aggregate memory at the array field's offset,
bridging each via `regToValue(elem_ty)` recursively, producing a `Value` array.
This must compose with the struct-field walk so an array nested inside a struct
(and the `?Arr` optional payload from 0162) both work. Follow the no-silent-
fallback rule — any element type you can't bridge bails loudly with a specific
message.

**E:** after a `#run`/comptime-init failure sets `comptime_failed = true` (see
the `#run` call sites in `src/ir/emit_llvm.zig`), the pipeline should stop before
LLVM emission rather than proceeding with an `unresolved` const type. Find where
`comptime_failed` is checked (or should be) before codegen in `src/main.zig` /
the emit driver, and make a failed comptime init a hard, clean abort.

Verify: repro C prints `1 2 3`; an array-of-struct and struct-with-array both
bridge; repro E either evaluates (after C) or exits 1 cleanly with the comptime
error and no panic. Add `examples/comptime/06xx-comptime-run-array-aggregate.sx`.
