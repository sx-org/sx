> **RESOLVED (2026-07-03).** Root cause: `globalInitValue`
> (`src/ir/lower/decl.zig`) serialized a present optional global's
> initializer as the RAW payload `ConstantValue` (`.int 5`), then the
> LLVM emitter wrote that scalar into the optional's `{ payload, i1 }`
> global type — an initializer/type mismatch. It was optional-specific:
> non-optional scalars/structs/pointers already emitted correctly.
> Fix: `globalInitValue` now detects an optional destination, serializes
> the initializer against the CHILD type (`globalInitValuePayload`), and
> wraps the result in the 2-field aggregate `{ <payload>, true }`. The
> absent forms (`= null` / `= ---`) already zero the whole `{T,i1}`
> struct via `.null_val` / `.zeroinit` (`{ zeroinit, false }`), so they
> flow through unwrapped and unchanged. Recursing on the child type also
> covers nested optionals (`?(?i64)`) and optional aggregates
> (`?S = S.{...}`), both previously broken. JIT + AOT verified. Regression
> test: `examples/optionals/0924-optionals-global-initializers.sx`.
>
> Out of scope (separate pre-existing gaps, NOT introduced here, filed
> nowhere yet): (1) `#run`-reading ANY aggregate global at comptime
> (optional or plain struct) bails in the comptime VM
> (`constToReg` in `src/ir/comptime_vm.zig` only materializes scalars);
> identical failure on master for a `struct` global. (2) A global
> initialized from `@some_global` (address-of) is rejected as non-const
> for both optional and non-optional pointer globals alike.

# 0234 — an optional GLOBAL with a non-null initializer emits a mismatched LLVM global

## Symptom

One-line: `go : ?i64 = 5;` at module scope, plus any USE of `go`, fails
LLVM verification — "Global variable initializer type does not match
global variable type!".

- Observed: LLVM verification failure (no diagnostic, nothing runs).
- Expected: the global carries `{ i64 5, i1 true }` (present optional),
  same as the local form `lo : ?i64 = 5;` which works.

Pre-existing on master (verified identical on parent and the issue-0218
fix branch by the 0218 review, 2026-07-03); 4-line repro, no multi-assign
involved.

## Reproduction

```sx
#import "modules/std.sx";
go : ?i64 = 5;
main :: () -> i32 {
    if go != null { print("some\n"); }
    0
}
```

## Investigation prompt

The global-emission path (src/ir/emit_llvm.zig, where module globals get
their initializers) emits the initializer for an optional-typed global
as the RAW payload constant (i64 5) while the global's LLVM type is the
optional struct `{ i64, i1 }` — the initializer never goes through the
optional-wrap the local path applies. Find where global initializer
constants are built (grep the global emission for initializer handling)
and wrap a non-null initializer into `{ payload, true }` (and `null`
into `{ zeroinitializer, false }` — the null form apparently works
today; confirm). Check nested optionals (`??i64`), optional structs
(`?S = S.{...}`), optional pointers, and `--- ` uninitialized optional
globals. Verification: the repro prints "some", exit 0; regression
example under examples/optionals/ (09xx block); corpus green.

Found by the adversarial review of the issue-0218 fix (2026-07-03).
