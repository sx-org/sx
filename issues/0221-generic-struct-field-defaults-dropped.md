# 0221 — generic-struct field DEFAULTS are dropped in struct literals

> **RESOLVED** (2026-07-03). Root cause: `struct_defaults_map` was keyed by the
> struct's PLAIN decl name, but a generic instance is registered under its
> MANGLED name (`Box__Inner`), so the struct-literal defaults lookup
> (`lower/expr.zig`) never matched and unset defaulted fields zero-filled.
>
> Fix: `instantiateGenericStruct` (`src/ir/lower/generic.zig`) now registers the
> template's `decl.field_defaults` under the mangled instance name (the defaults
> are index-aligned with `field_names`, both copied from the same decl). The
> struct-literal path (`src/ir/lower/expr.zig`) additionally captures the
> instance's stored `type_bindings` (from `struct_instance_bindings`) and, via a
> new `lowerDefaultWithBindings` helper (`src/ir/lower/coerce.zig`), installs
> them while lowering each missing field's default — so a DEPENDENT default that
> references a type param monomorphizes per instantiation.
>
> **Dependent-defaults decision: monomorphize per instance (the principled
> answer).** A default like `sz: i64 = size_of(T)` is now lowered with the
> instance's bindings active — `Dep(i64).sz == 8`, `Dep(i16).sz == 2` — proven
> by the regression test. NOTE: this works for the bare-`T` spelling. The
> `$T`-SIGIL spelling in a reflection builtin (`size_of($T)`) is rejected with a
> LOCATED diagnostic (`size_of expects a type, got 'unresolved'`) — but that is a
> PRE-EXISTING, SEPARATE bug independent of struct defaults: `size_of($T)` fails
> identically inside an ordinary generic function body (`sz :: ($T: Type) -> i64
> { return size_of($T); }`), while `size_of(T)` works there too. It is NOT
> fixed here (out of scope; a distinct compiler bug to be filed separately). The
> located diagnostic — never a silent zero — is the acceptable fallback either
> way.
>
> Regression test: `examples/generics/0219-generics-struct-field-defaults.sx`
> (base case, two instantiations, override+default mix, positional form,
> generic-in-generic, per-instance dependent default).

## Symptom

One-line: a struct literal for an instantiated GENERIC struct loses the
declared field defaults — `b : Box(Inner) = .{ item = .{} }` leaves
`b.tag == 0` even though `Box` declares `tag: i64 = 1`. Non-generic
struct literals apply defaults correctly (probed).

- Observed: unset defaulted fields of a generic instantiation read 0.
- Expected: the declared default (`tag == 1`), as for non-generic structs.

Suspected: the struct-defaults lookup is keyed by the PLAIN declaration
name and misses instantiated generic type names (`Box(Inner)` /
mangled instantiation key), so the literal lowering finds no defaults
map entry and zero-fills.

## Reproduction

```sx
#import "modules/std.sx";

Inner :: struct { v: i64 = 11; }
Box :: struct($T: Type) { item: T; tag: i64 = 1; }

main :: () {
    b : Box(Inner) = .{ item = .{} };
    print("{}\n", b.tag);      // observed: 0 — expected: 1
    print("{}\n", b.item.v);   // also check the nested default (expected 11)
}
```

## Investigation prompt

In `src/ir/lower/expr.zig` (~183-190) the struct-literal lowering consults
`struct_defaults_map` keyed by decl name; an instantiated generic's type
name (or TypeId) never matches, so defaults are silently skipped —
zero-fill instead. Fix: key defaults by the generic DECL + apply them
during instantiation (the instantiated struct's field list should carry
the default exprs, monomorphized — check `instantiateGenericStruct` in
src/ir/lower.zig for where fields are copied and whether default
expressions survive), or make the literal lowering resolve the
instantiation back to its generic decl for the defaults lookup. Watch
dependent defaults (a default referencing `$T`, e.g. `count: i64 =
size_of($T)` — decide + test what happens). Verification: the repro
prints 1 then 11; non-generic defaults still work; nested
generic-in-generic defaults probed; full corpus green; regression
example under examples/generics/.

Found by the adversarial review of the 0161+0184 fix (2026-07-03).
