# 0313 — enum-literal args through a `*P` view dispatch lose their param target

> **RESOLVED (2026-07-18, same session as filed).** Fix:
> `resolveCallParamTypes`' protocol-receiver arm uses the same
> `*P` / `?P` / `?*P` look-through as the plan and dispatch arms, so
> args lower under the protocol method's declared param types for every
> receiver shape. Regression test:
> `examples/protocols/0883-protocols-view-dispatch-arg-targets.sx`.

## Symptom

Found running issue 0310/0311/0312's end-to-end verification (`sx build`
of m3te): after flipping `gpu: GPU` fields to `*GPU` views, every enum
literal argument in a view-dispatched call stopped typing:

```
error: enum literal '.rgba8' cannot type itself from non-enum destination 'u32'
    tex = gpu.create_texture(w, h, .rgba8, xx pixels);
```

The same call typed fine through an owned `GPU` receiver. Root cause:
`resolveCallParamTypes` only recognized a BARE protocol receiver when
fetching the method's declared param types — for a `*P` (or `?P`/`?*P`)
receiver it fell through, the args lowered under the ambient destination
type, and an enum-literal arg tried to type itself from whatever the
surrounding expression wanted (here a `u32`).

## Reproduction

```sx
#import "modules/std.sx";
Fmt :: enum { rgba8; bgra8; }
P :: protocol { make :: (self: *Self, w: i64, fmt: Fmt) -> i64; }
C :: struct { last: i64 = 0; }
impl P for C { make :: (self: *C, w: i64, fmt: Fmt) -> i64 { w + fmt.(i64) } }
main :: () {
    c := C.{};
    v : *P = c;
    print("{}\n", v.make(10, .bgra8));   // was: enum literal cannot type itself
}
```

Expected/actual after fix: prints 11. Verification: m3te
`sx build main.sx` compiles + bundles (previously failed on every
`.rgba8`-style argument in renderer/board_fx).
