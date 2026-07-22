# 0341 — `xx` over a cross-module generic-struct method chain silently produces a wrong value

> **Symptom.** `xx b.get().data[0]` where `b`'s generic struct (`Box($T)`
> with method `get`) is declared in an IMPORTED module evaluates to 0
> instead of the stored 42 — no diagnostic, silent wrong value. The same
> code single-file prints 42. Removing the `xx` (plain chain, coercion via
> return/decl target) or binding `b.get()` to a local first is correct in
> both arrangements.

## Reproduction

`boxmod.sx`:
```sx
#import "modules/std.sx";
Box :: struct ($T: Type) {
    p: *T;
    get :: (self: Box(T)) -> T { self.p.* }
}
mk :: ($T: Type, p: *T) -> Box(T) { Box(T).{ p = p } }
```

main file:
```sx
#import "modules/std.sx";
#import "boxmod.sx";
Buf :: struct { data: []u8; }
f1 :: (v: *Buf) -> i64 {
    b := mk(Buf, v);
    xx b.get().data[0]      // prints 0; single-file prints 42
}
main :: () {
    d : []u8 = context.allocator.alloc(u8, 3);
    d[0] = 42;
    v := Buf.{ data = d };
    print("{}\n", f1(@v));
}
```

## Evidence from reduction

- `type_of(b.get())` infers `.unresolved` in BOTH arrangements (the plan's
  instance-method arm finds no author: `plainStructMethod` misses generic
  instances — they register `struct_instance_author`, not
  `plain_struct_authors` — and the `Box__Buf.get` global fallback is not
  lowered at plan time). Single-file the LOWERING recovers (the emitted
  call ref carries the real return type and `xx` reads it); cross-module
  the lowering also mis-resolves, and `xx` consumes the wrong-typed value.
- Correct in both arrangements: `v := b.get(); xx v.data[0]`, and the
  chain WITHOUT `xx` coerced via a typed target.

## Expected

Method-call result inference resolves through the generic instance's
template author (`struct_instance_template`/`_bindings`/`_author` maps) in
the plan exactly as the lowering dispatch does, regardless of which module
authored the template; `xx` then classifies against the real type. At
minimum, an `.unresolved` xx operand must be a loud diagnostic, never a
silent passthrough of reinterpreted bytes.

## Impact

Any consumer of a generic-providing module (List, Map, the UI
StateStore's `State(T)`) that writes `xx <method-chain>` gets silent
garbage. Found during G4 Step 2 (StateStore examples); the store itself is
unaffected — filed for an independent fix.

## Suspected area

`CallResolver.plan` instance-method arm (src/ir/calls.zig ~380-425): no
generic-instance arm parallel to `plainStructMethod`; and the divergence
between plan-time and dispatch-time resolution cross-module. Second
defect: `lowerXX` accepting an `.unresolved`-typed operand silently.
