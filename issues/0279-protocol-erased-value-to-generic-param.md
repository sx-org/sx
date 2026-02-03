# 0279 — erasing a builtin VALUE to a protocol produces invalid LLVM

> **RESOLVED** (2026-07-09). Root cause: the `.erase_protocol` coercion arm
> in `src/ir/lower/coerce.zig` (`coerceMode`) only materialized a ctx pointer
> for a NON-builtin value (`if (!src_ty.isBuiltin())`). A builtin scalar
> (`f32`, `i64`, …) fell through with `concrete_ptr = val` — the raw scalar —
> which `buildProtocolValue` then stuffed into field 0 of the protocol
> fat-pointer `struct_init {ptr, thunk…}`, emitting a malformed
> `insertvalue {ptr,ptr} undef, float, 0` and an LLVM verification failure.
> Fix: a VALUE (builtin scalar OR struct rvalue) is now always `alloca`+`store`d
> and heap-copied so the erased value's ctx pointer is a real pointer that
> outlives the frame; the fast path (`heap_copy=false`, borrow directly) is
> reserved for an operand that is ALREADY a pointer (`xx @obj`).
> Regression test: `examples/protocols/0423-protocols-erased-to-generic.sx`.

## Symptom

Passing a builtin-typed value (`f32`) to a protocol-typed parameter — either
directly, or when that erased value later reaches a generic `$T` — produced
invalid LLVM instead of working or a clean diagnostic:

```
LLVM verification failed: Invalid InsertValueInst operands!
  %si = insertvalue { ptr, ptr } undef, float %load, 0
```

Observed: a `float` inserted into the protocol fat-pointer aggregate `{ptr, ptr}`.
Expected: the erased protocol value is built correctly (ctx pointer + thunk
pointers) and the call runs.

## Semantics decision

Passing an already-erased protocol value `a: Lerpable` to a generic `check($T)`
binds `T = Lerpable` (the erased fat-pointer type) and forwards the value
unchanged — no re-erase, no unwrap. That part already worked; the actual defect
was one layer down, in the erasure of the ORIGINAL builtin value to the protocol
param (both the direct `use(x)` call and the `xx x` explicit form).

## Reproduction

```sx
#import "modules/std.sx";
Lerpable :: protocol { lerp :: (self: Self, b: f32, t: f32) -> f32; }
impl Lerpable for f32 { lerp :: (self: f32, b: f32, t: f32) -> f32 { self + (b - self) * t } }
check :: (v: $T) { print("got\n"); }
use :: (a: Lerpable) { check(a); }   // pass an ERASED protocol value to a generic $T
main :: () { x : f32 = 1.0; use(x); }
```

Even the generic hop is not required — `use :: (a: Lerpable) { }` with a plain
`main` calling `use(x)` (x: f32) reproduced it on its own, since the failure is
in erasing the builtin value at the `use(x)` call boundary.

## Investigation prompt (for the fix session — now applied)

Suspected area: `src/ir/lower/coerce.zig`, `coerceMode`, the `.erase_protocol`
arm. It computed `concrete_ptr = val` and only replaced it with a real pointer
(`alloca`+`store`) when `!src_ty.isBuiltin()`. For a builtin scalar the raw
value flowed into `buildProtocolValue` (`src/ir/lower/protocol.zig`) as the ctx
"pointer". The fix makes a value of ANY kind (builtin or aggregate) get a stack
slot + heap copy; only an operand that is already a pointer takes the
borrow-directly fast path. Verify with the repro (expect it to print `got` /
`used`, exit 0, no LLVM verification failure).
