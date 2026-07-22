# 0340 — a real struct field named `ptr`/`len` is hijacked by the container pseudo-field typing

> **RESOLVED (2026-07-22).** Both inference sites restructured: real
> members win. `resolveFieldType` (src/ir/lower/expr.zig) — container
> pseudo-fields guarded on string/slice/array/vector, then real
> union/tuple/struct members, then the legacy pseudo fallback for
> non-containers with no matching member (`#get len` accessors keep typing
> through it). `expr_typer.zig`'s field arm — same guard; `#get`
> resolution already lived below it. Regression:
> `examples/types/0890-types-struct-field-named-ptr.sx` (plain + generic
> structs, method-interior reads, declared `len: f64`, container
> pseudo-fields untouched).

> **Symptom.** A struct with its own `ptr` field cannot be used through a
> method: `self.ptr.*` fails with
> `error: cannot dereference with '.*': '[*]unresolved' is not a pointer`.
> A real `len` field silently types as `i64` regardless of its declared
> type (same bug class, wrong-type instead of hard error).

## Reproduction

```sx
#import "modules/std.sx";

Box :: struct {
    ptr: *i64;
    get :: (self: Box) -> i64 { self.ptr.* }
}

main :: () {
    x := 5;
    d := Box.{ ptr = @x };
    print("{}\n", d.get());
}
```

Generic structs identically (`Box :: struct ($T: Type) { ptr: *T; ... }`).
Renaming the field compiles and runs.

## Expected

A declared member shadows the `.len`/`.ptr` pseudo-fields — those belong to
the special containers (string/slice/array/vector) only.

## Actual

`resolveFieldType` (src/ir/lower/expr.zig) returned the pseudo-field type
UNCONDITIONALLY for every receiver type: `.ptr` typed as
`manyPtrTo(getElementType(ty))` — `[*]unresolved` for a struct — before
real member resolution ever ran. The LOWERING path had the container guard;
the INFERENCE path did not, so the two disagreed.

## Fix

`resolveFieldType` orders: container pseudo-fields (guarded on
string/slice/array/vector) → real union/tuple/struct members → legacy
pseudo fallback for non-containers with no matching member (`#get len`
accessors, e.g. `List.len`, type through the fallback as before).

## Impact

Blocked the G4 StateStore's `State(T) { ptr: *T }` handle (the v1
`state.sx` stub had the identical shape but was dead code, which is why
this never surfaced).
