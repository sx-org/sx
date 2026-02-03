# 0295 — abi(.c) fn-pointer calls mismatch the callee's C-ABI signature (params, return, sret)

> **RESOLVED** (2026-07-17). All three parts fixed in
> `emitCallIndirect` (src/backend/llvm/ops.zig): params run through
> `abiCoerceParamTypeEx(ty, raw, false)` — the sx-internal abi(.c)
> convention (block-trampoline precedent: fat string/slice preserved,
> ≤8 B non-HFA → i64, 9–16 B → [2 x i64]; the >16 B byval branch stays
> first); the return type is coerced the same way with the existing
> result-side `coerceArg` restoring the aggregate; and >16 B non-HFA
> returns mirror `emitCall`'s sret path (prepended slot + call-site
> `sret(<T>)` attribute + load). Fixing sret exposed a FOURTH,
> pre-existing definition-side bug: `emitFunction` mapped IR param refs
> to LLVM params without the sret offset, so ANY sx-defined abi(.c)
> function returning a >16 B struct read its first argument as the
> hidden out-pointer — even via direct calls (probe: `direct: <addr>,
> 2*<addr>, 3*<addr>`). The param pre-map and the byval reload loop now
> shift by the sret slot, mirroring `declareFunction`'s classification.
> Regression test: `examples/cfnptr/1637-cfnptr-cabi-struct-abi.sx`
> (param matrix packed/[2 x i64]/byval/HFA/string + coerced small-struct
> return + sret return, fn-pointer and direct; JIT + AOT verified).
> The open design question (a fn pointer holding a REAL extern C
> function whose decl collapses string→ptr) remains a documented
> convention choice, not a defect: fn-pointer call sites use the
> `false` convention, matching sx-defined abi(.c) callees.

## Symptom

Calling an sx `abi(.c)` function through a fn pointer: a small by-value
struct arg (≤8 bytes, non-HFA) loses its second field — observed `1`,
expected `3` in the repro below. The callee's definition coerces such
params to `i64` (`abiCoerceParamTypeEx`), but `emitCallIndirect` builds
the call-site fn type from the raw LLVM param types for C-conv fn
pointers, so the aggregate is split across two registers the callee
never reads. (The default-conv/closure variant of this mismatch was
issue 0292, fixed 2026-07-17; the C-conv branch was deliberately left
as-is — see the `fp_is_c_abi` comment in
`src/backend/llvm/ops.zig` `emitCallIndirect`.)

Two structurally-suspect siblings, same root cause:

- **Small-struct RETURN**: an `abi(.c)` definition coerces a ≤8-byte
  struct return to `i64`, but the indirect call site expects the raw
  aggregate (e.g. `{i32, i32}` in w0+w1 vs packed x0). A probe
  "passes" today only by register-allocation luck (the leftover arg
  register happens to hold the right value) — it is not actually
  correct.
- **>16-byte struct RETURN (sret)**: `abi(.c)` definitions use the
  indirect sret convention (hidden out-pointer, x8 on AArch64);
  `emitCallIndirect` has no sret support at all, so such a call reads
  garbage from the return registers.

## Reproduction

```sx
#import "modules/std.sx";
Point :: struct { x: i32; y: i32; }
add_pt_c :: (p: Point) -> i32 abi(.c) { return p.x + p.y; }
main :: () {
    fp : (Point) -> i32 abi(.c) = add_pt_c;
    print("cabi fnptr: {}\n", fp(Point.{ x = 1, y = 2 }));
}
```

Expected: `cabi fnptr: 3`. Actual: `cabi fnptr: 1` (second field lost).

## Investigation prompt

Area: `src/backend/llvm/ops.zig` `emitCallIndirect` (the
`fp_is_c_abi` branch) vs the definition-side signature classification
in `src/ir/emit_llvm.zig` `declareFunction` (~line 1380: `needs_c_abi`
ret/param coercion + `uses_sret`).

The fix likely needs to make the C-conv fn-pointer call site mirror
the definition exactly:

1. Params: run declared param types through
   `abiCoerceParamTypeEx(ty, raw, false)` — `is_extern_c_api=false` is
   the sx-internal `abi(.c)` convention (the block-trampoline
   precedent documented in `src/backend/llvm/abi.zig`); the existing
   `needsByval` >16-byte branch stays first (it materializes the
   arg). Note `abiCoerceParamTypeEx` can return `[2 x i64]` for
   9–16-byte structs — the array-decay-to-ptr rewrite in that loop
   must only apply to RAW array params, not to the coerced type.
   `coerceArg` already handles struct→int and struct→array spills.
2. Return: coerce `f.ret` the same way and let the existing
   result-side `coerceArg` (int→struct spill) restore the aggregate.
3. sret: mirror `emitCall`'s `callee_uses_sret` path (prepended
   alloca + `sret(<T>)` call-site attribute + load).

Open design question to verify while fixing: a C-conv fn pointer can
also hold a REAL extern C function (`is_extern_c_api=true` convention:
string/slice params collapse to a single `ptr`). The call site cannot
know which convention the target was declared with — check whether
extern fn-pointer assignments need their own thunk or whether the
`false` convention is the documented contract for fn-pointer calls
(as it already is for block trampolines).

Verification: the repro prints `3`; add a pinned regression example
(e.g. `examples/cfnptr/`) covering the param matrix ({i32,i32},
{u8,u8}, 9–16-byte, >16-byte byval), small-struct return, and a
>16-byte sret return through an `abi(.c)` fn pointer; `zig build test`
stays green.
