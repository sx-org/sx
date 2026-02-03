# 0310 — `?*P` (optional view) method dispatch unresolved: `opt_view.method()` does not compile

> **RESOLVED (2026-07-18).** Fix: the optional-receiver dispatch arm now looks through a pointer child (the ?*P word IS the *P — load + dispatch, sentinel-null undefined like ?P).
> Regression test: `examples/protocols/0880-protocols-optional-view-dispatch.sx`.

## Symptom

A method call directly on an optional-of-view field fails to resolve:

```sx
h := Holder.{ gpu = v };        // gpu: ?*P
if h.gpu != null {
    h.gpu.n();                  // error: unresolved 'n'
}
```

`error: unresolved 'n' (in … fn main)`. The same shape with an OWNED
optional protocol (`?P`) compiles and dispatches fine — that is exactly
what `library/modules/ui/renderer.sx` did until today (`self.gpu:
?GPU`, `self.gpu.create_shader(...)`), so `?*P` refusing the same
spelling is a coverage gap in the new view receiver classification, not
a designed difference. Unwrap-bind works and is the temporary spelling
used on the app side meanwhile:

```sx
if g := h.gpu { g.n(); }        // OK — dispatches
```

Observed vs expected: `opt_view.method()` should unwrap-and-dispatch
like `opt_owned.method()` (or, if the language deliberately wants the
explicit bind, `?P` should refuse the shorthand too — consistency one
way or the other).

Found migrating m3te's GPU plumbing to the ownership regime: the
pipeline/renderer/glyph-cache `gpu: ?GPU` fields (which alias one
shared, frame-controlled backend — a borrow, not an ownership) become
`?*GPU`, and every `self.gpu.<method>()` site stops compiling.

## Reproduction

```sx
#import "modules/std.sx";

P :: protocol {
    n :: (self: *Self) -> i32;
}

C :: struct { v: i32 = 42; }
impl P for C { n :: (self: *C) -> i32 { self.v } }

Holder :: struct { gpu: ?*P = null; }

main :: () {
    c := C.{};
    v : *P = c;
    h := Holder.{ gpu = v };    // wrap of a view: OK
    if h.gpu != null {
        print("{}\n", h.gpu.n());   // error: unresolved 'n'
    }
}
```

Run: `sx run repro.sx` → `error: unresolved 'n'` (HEAD c8235e32,
2026-07-18). Expected: prints 42, matching the `?P` behaviour.

## Investigation prompt

Suspected area: method-call resolution for optional receivers —
`src/ir/lower/expr.zig` / `protocol.zig` (E1-era code). The optional
unwrap-then-dispatch path presumably handles `?P` (owned layout) but
not `?*P`: after unwrapping, the payload is a VIEW (borrowed `{ctx,
vtable}` pair), and the dispatch machinery either doesn't classify it
as a protocol receiver or looks the method up in the wrong namespace
(hence "unresolved" rather than a wrong-body error).

What the fix likely needs:

1. Teach the optional-receiver method path that a `?*P` payload is a
   protocol view: unwrap → dispatch through the view vtable, same as
   the explicit `if g := opt { g.m() }` form already does.
2. Add corpus coverage mirroring the owned-optional call sites in
   `library/modules/ui/renderer.sx` / `glyph_cache.sx` (those are the
   real-world shapes, and they should flip back from `*GPU = null`
   nullable-view fields to `?*GPU` once this lands).

Verification: the repro prints 42; then
`cd /Users/agra/projects/m3te && sx build --target ios-sim main.sx`
compiles with the library's gpu fields spelled `?*GPU` (currently
blocked on this issue).
