# 0307 — `[N]T` → pointer via `xx` / `.(T)` yields the array's VALUE bits, not its address

> **RESOLVED (2026-07-18) — not a compiler bug; call-site spelling.**
> Owner ruling: `array.(*void)` / `xx array` is NOT the array-decay
> spelling. Arrays decay via `array.ptr` or `@array[0]`; the explicit
> `xx` / `.(T)` engine is under no obligation to treat a whole-array
> value as an address. The fault was the one library call site that used
> the coercion spelling: `library/modules/ui/renderer.sx:133` now reads
> `self.gpu.set_vertex_constants(1, xx @proj.data[0], 64)` (matching the
> GL path at :138). Verified end-to-end below: m3te boots on the Android
> emulator and renders. The value-bits behaviour of `xx <array>` is
> therefore by design; this file stays as the record.

## Symptom

Coercing an array lvalue to a pointer type with the explicit engine
(`xx arr` or `arr.(*void)`) produces a "pointer" whose bits are the
array's first 8 bytes reinterpreted — i.e. `a[0]` and `a[1]` packed as a
u64 — instead of the address of the array's storage. `@a[0]` coerced the
same way yields the correct address, so the two spellings of "address of
the array" disagree.

Observed vs expected: all three spellings below should print the SAME
address; the `xx a` / `a.(*void)` forms print
`*void@0x400000003f800000` — exactly the f32 bits of `a[0]` (1.0 =
`0x3f800000`) and `a[1]` (2.0 = `0x40000000`).

Blast radius (found migrating m3te to Android):
`library/modules/ui/renderer.sx:133` does
`self.gpu.set_vertex_constants(1, xx proj.data, 64)` with a local
`Mat4` (`data: [16]f32`). Every GPU-bound target therefore hands the
backend a garbage matrix pointer:

- Android (Gles3Gpu): SIGSEGV on the FIRST frame —
  `glUniformMatrix4fv` memcpy reads from `0x3b9e4cad`, which is the f32
  bits of `proj.data[0]` = 2/414 ≈ 0.00483 (ortho matrix element).
  100% reproducible: build m3te `sx build --target android main.sx`,
  install, launch on any emulator → instant crash at
  `Gles3Gpu.set_vertex_constants+144`.
- iOS (MetalGPU) uses the same renderer call site; same miscompile
  (not runtime-verified this session).

Sibling of fixed issue 0297 (`[N]T` → `[*]T` implicit call-site decay
passed a spilled copy). This one is the EXPLICIT path (`xx` / postfix
`.(T)`) to a plain pointer, and it is worse than a copy: the callee gets
value bits, not a pointer to anything.

## Reproduction

```sx
#import "modules/std.sx";

main :: () {
    a : [4]f32 = .[1.0, 2.0, 3.0, 4.0];
    via_xx   : *void = xx a;
    via_post : *void = a.(*void);
    via_at   : *void = xx @a[0];
    print("xx a        = {}\n", xx via_xx);
    print("a.(*void)   = {}\n", xx via_post);
    print("xx @a[0]    = {}\n", xx via_at);
}
```

Run: `sx run repro.sx`

Expected: three identical addresses.
Actual (HEAD 0096235b, 2026-07-18):

```
xx a        = *void@0x400000003f800000   // value bits — WRONG
a.(*void)   = *void@0x400000003f800000   // value bits — WRONG
xx @a[0]    = *void@0x16d539e80          // real address — correct
```

The struct-field form (`xx w.data` for `data: [N]f32`) fails identically
(this is the renderer.sx shape).

## Investigation prompt

Suspected area: `src/ir/lower/coerce.zig` — the shared `xx` / `.(T)`
coercion engine. Commit 0096235b ("explicit aggregate<->scalar
reinterprets are spill-mediated") just reworked explicit aggregate
reinterprets there; the array → pointer case appears to fall into the
"explicit reinterpret = copy the value bits" path, when it should be
array DECAY: an array lvalue coerced to a pointer borrows the array's
storage, same contract as `[N]T` → `[]T` / `[N]T` → `[*]T` (specs.md
§Pointer Types, and issue 0297's settled semantics).

What the fix likely needs:

1. In the `xx` / `.(T)` lowering, detect source type `[N]T` with a
   pointer target (`*void`, `*U`, presumably also `[*]U`): lower as
   address-of-array-storage (borrow of the lvalue), NOT as a by-value
   load + bitcast.
2. Keep the rvalue-refusal discipline from e8fd6f74/0096235b: an array
   rvalue (e.g. `Mat4.identity().data`) has no storage to borrow —
   either materialize a scoped temporary or refuse, matching whatever
   the protocol-erasure work settled for other rvalue borrows.
3. Audit the existing callers that currently "work" only because reads
   from a copy are faithful: `library/modules/ui/renderer.sx:133`
   (`xx proj.data`) and any other `xx <array>` / `.(<ptr>)` sites in
   the library (grep `xx [a-z_.]*data` in `library/modules`).

Verification:

1. The repro above prints three identical addresses.
2. The struct-field variant: add `Wrap :: struct { data: [4]f32; }`,
   `w := Wrap.{ data = .[...] }`, assert `xx w.data == xx @w.data[0]`.
3. End-to-end: `cd /Users/agra/projects/m3te && sx build --target
   android main.sx`, install the APK on an emulator, launch — the board
   renders (previously: SIGSEGV in `Gles3Gpu.set_vertex_constants` on
   frame 1). The iOS-sim app likewise exercises the same renderer path
   through MetalGPU.
