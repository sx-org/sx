# 0301 — narrow-backed tagged union (`enum u16 { …: T }`) trips verifySizes

## Symptom

Declaring a tagged union with a NARROW explicit backing type and at least
one payload variant crashes the compiler: `verifySizes` asserts
(`llvm_size == ir_size` fails) before any code runs. Payload-less narrow
enums (`enum u16 { a; b; }`) are fine; layout-struct unions (`enum struct
{ tag: u32; … }`) are fine; the plain narrow-backed + payload combination
is the broken shape. Pre-existing on master (reproduced at 29b1657d,
before the S4.3b table work).

## Reproduction

```sx
#import "modules/std.sx";
Wire :: enum u16 { ping :: 0x10; pong :: 0x20; data :: 0x100: i64; }
main :: () { w : Wire = .data(42); print("{}\n", w); }
```

Observed: `panic: reached unreachable code` at
`src/ir/emit_llvm.zig:825` (`std.debug.assert(llvm_size == ir_size)`).
Expected: compiles and prints `.data(42)` — or a clean diagnostic if the
shape is unsupported.

## Investigation prompt

Suspected area: the two layout computations disagree for
`tagged_union` with `tag_type` narrower than the payload alignment.
`TypeTable.typeSizeBytes` (src/ir/types.zig, `.tagged_union` arm) computes
`max_payload + tag_size` rounded to 8 (10 → 16 for u16 tag + i64
payload), while the LLVM struct built in `src/backend/llvm/types.zig`
(`{ i16, [N x i8] }`) sizes/aligns by LLVM rules — the two diverge.
The fix likely needs the sx-side walk to mirror the LLVM layout exactly
(tag slot padded to the payload area's alignment, or the LLVM type
adjusted to the documented `{ tag, [max_payload_size x i8] }` packed
contract). Verify with the repro above (JIT + AOT), then add a pinned
example covering `enum u8/u16/u32 { …: i64 }` tagged unions (values,
prints, variant_index/variant_payload) and run `zig build test`.
