# 0286 — default-ABI small byte-struct params corrupt when a second one spills

> **RESOLVED** (fix landed). Root cause: default (sx-internal) call convention
> left ≤8-byte non-HFA structs as raw LLVM struct types. AArch64 LLVM expands
> `{i8,i8,i8,i8}` (e.g. UI `Color`) into four separate `i8` arguments. When a
> second such param overflows the integer arg registers (after the implicit
> context pointer, a user pointer, and a `string` fat pointer), the caller
> spills each byte as a 4-byte stack slot (`stp wN, wM`) while the callee
> reloads four consecutive packed bytes — only the first field survives,
> alpha becomes 0. Fix: apply the same ≤8-byte → `i64` param coercion used for
> C ABI to the default ABI as well (`declareFunction`), so `Color` rides in a
> single integer register / word. Call-site `coerceArg` + param-slot
> store rematerialize the struct. Regression:
> `examples/types/0851-types-default-abi-small-byte-struct-param.sx`.

## Symptom

A free function with the shape:

```sx
draw :: (ctx: *T, label: string, bg: Color, fg: Color) { ... }
```

(or the same with a `Frame` / several `f32`s between `ctx` and the colors)
silently receives a corrupted second `Color`: only `r` is correct; `g`, `b`,
`a` are 0. Manifests as fully transparent UI text (labels drawn but invisible)
while the first `Color` (background) is fine. One-`Color` helpers
(`add_text`, header labels) work. `abi(.c)` with the same shape works.

## Reproduction

```sx
#import "modules/std.sx";

Color :: struct { r, g, b, a: u8; }

// Implicit context + user pointer + string consume x0–x3 on AArch64;
// first Color fits in w4–w7; second Color spills → corruption.
probe :: (ctx: *i32, label: string, bg: Color, fg: Color) {
    print("fg=({},{},{},{}) label={}\n", fg.r, fg.g, fg.b, fg.a, label);
}

main :: () -> i64 {
    n : i32 = 0;
    bg := Color.{ r = 55, g = 55, b = 70, a = 255 };
    fg := Color.{ r = 230, g = 230, b = 240, a = 255 };
    probe(@n, "New Game", bg, fg);
    // expected: fg=(230,230,240,255)
    // actual:   fg=(230,0,0,0)
    0
}
```

Trigger matrix (aarch64-macos):

| signature | `fg` OK? |
|-----------|----------|
| `*T, string, Color, Color` | **No** |
| `*T, Frame, string, f32, Color, Color, f32` | **No** |
| `*T, string, f32, Color` (one color) | Yes |
| `Frame, string, f32, Color, Color` (no user pointer) | Yes |
| `*T, Color, Color, string` (colors before string) | Yes |
| same as broken + `abi(.c)` | Yes |

## Root cause

`declareFunction` only applied `abiCoerceParamType` for `extern` / `abi(.c)`.
Default ABI kept `{i8×4}` as a struct. LLVM AArch64 then expanded it to four
`i8` args; stack spill used word slots, callee expected packed bytes.

## Fix

Coerce ≤8-byte non-HFA struct params to `i64` for the default ABI as well
(same bucket as C ABI small-struct register packing). Leave HFAs, mid-size
(9–16), and large structs unchanged for default ABI so string fat pointers
and by-value aggregates stay on the existing path.
