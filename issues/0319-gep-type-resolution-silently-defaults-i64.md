# Issue 0319 — GEP aggregate type resolution silently defaults to `i64`

> **RESOLVED.** Both aggregate recovery helpers now return `null` when no
> real LLVM aggregate type can be proven. `emitStructGep` and `emitUnionGep`
> report an operation-specific backend diagnostic, set the dedicated
> `emission_failed` gate, and stop function/module emission before LLVM
> verification, optimization, or object generation. Scalar `i64` (and every
> other real type) is no longer used as a sentinel. IR regressions cover both
> failing operations; the existing typed struct-GEP test remains the valid-path
> control. `zig build test`: 584/584 passed.

## Symptom

One-line: when LLVM emission cannot recover the aggregate type for a
`struct_gep` / `union_gep`, it silently substitutes `i64`; observed behavior is
an integer-shaped GEP fallback, while the expected behavior is a loud compiler
diagnostic or an unmistakable failure sentinel before emitting invalid IR.

## Reproduction

This is the minimal source shape whose field access lowers through the affected
GEP machinery; the latent failure is exposed whenever the base ref loses both
its `base_type` and recoverable producer type (for example after a new pointer
producer is introduced):

```sx
S :: struct { p: *void; }

read :: (s: *S) -> *void {
    return s.p;
}

main :: () -> i64 {
    s := S.{ p = null };
    return if read(@s) == null then 0 else 1;
}
```

`src/ir/emit_llvm.zig:getStructTypeForGep` and
`LLVMEmitter.resolveGepStructType` currently end their failed lookup paths with
`return self.cached_i64`. Instrument either failed-resolution path (or construct
the equivalent `struct_gep` without `base_type` in an IR unit test) and the
source reaches the silent `i64` substitution rather than reporting the missing
aggregate metadata.

## Investigation prompt

Fix issue 0319 in the sx compiler. In `src/ir/emit_llvm.zig`, both
`getStructTypeForGep` and `LLVMEmitter.resolveGepStructType` silently return
`self.cached_i64` when aggregate type recovery fails. This violates the
compiler's no-silent-fallback invariant and can make a missing pointer/aggregate
type look like a legitimate 64-bit scalar, especially hiding target-width bugs
on wasm32. Change the helpers to return an optional/error or otherwise force
their callers in `src/backend/llvm/ops.zig` (`emitStructGep` and `emitUnionGep`)
to emit a specific diagnostic and abort emission for that instruction. Do not
use `.void`, `.i64`, or another real type as a sentinel. Add an IR-level unit
test that constructs a GEP whose base metadata cannot be recovered and asserts
the loud failure, plus retain the sx snippet above as the ordinary valid-path
control. Verify with `zig build`, `zig build test`, and
`bash tests/run_examples.sh`; the control must still return 0.
