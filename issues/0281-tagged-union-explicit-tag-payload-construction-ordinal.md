# 0281 — Call-constructing a payloadful variant of an explicit-tag tagged union stores the ordinal, not the explicit tag

> **RESOLVED** (regression test:
> `examples/types/0225-types-tagged-union-explicit-tag-payload-construct.sx`).
>
> **Defect 1 (mis-dispatch).** The three CALL-shaped tagged-union construction
> sites in `src/ir/lower/call.zig` (~1091 `Type.variant(p)` via type-fn
> instantiation, ~1227 qualified `Type.variant(p)`, ~1695 inferred
> `.Variant(p)`) used `resolveVariantIndex` (the ORDINAL) as the `enumInit` tag,
> while `match`/struct-literal/C-interop use the EXPLICIT tag value. Fix: keep
> the ordinal ONLY to index `fields[ord].ty` for the payload-type coercion
> lookup, and pass `resolveVariantValue` (the explicit value) as the stored tag.
> Now all four paths agree on the explicit on-the-wire encoding.
>
> **Defect 2 (panic).** Struct-literal construction of a SCALAR-payload variant
> panicked at LLVM emission. Two holes, both fixed in
> `src/ir/lower/expr.zig` + `src/ir/expr_typer.zig`:
> (a) the qualified `Ev.key.{ … }` form (a `field_access` type_expr, not an
> `enum_literal`) wasn't routed to `lowerTaggedEnumLiteral` — added a
> field_access branch in `lowerStructLiteral` (and the mirror in
> `ExprTyper.inferType` so inference no longer hits the type_bridge
> "field_access in type position" warning); (b) `lowerTaggedEnumLiteral` wrapped
> a scalar payload in a `structInit` (invalid `insertvalue i64`) — added a
> non-aggregate-payload branch that emits the single value directly as the
> enum_init payload. Both `Ev.key.{ 42 }` and `.key.{ 42 }` now construct with
> payload 42.

## Symptom

For a tagged union whose variants carry EXPLICIT tag values, CALL-shaped
construction of a PAYLOAD-CARRYING variant (`Ev.key(payload)` /
`Type.variant(payload)`) stores the variant's ORDINAL as the runtime tag
instead of its explicit tag value. Every other site of the feature uses the
explicit value:

- payload-LESS construction (`Ev.quit`) stores the explicit value (0x100),
- struct-literal construction (`Ev.key.{ … }`) uses `resolveVariantValue`
  (explicit),
- `match` computes its switch cases from `explicit_tag_values` (explicit),
- a C-populated event (e.g. SDL, the motivating use case) carries the explicit
  ABI value.

Because construction stores the ordinal but `match` switches on the explicit
value, a `match` over a call-constructed payloadful value matches NO case and
falls through to the (unreachable) default — silently doing nothing / UB.

Observed: the repro below prints nothing (exit 0). Expected: `key 42`.

## Reproduction

```sx
#import "modules/std.sx";
Ev :: enum { quit :: 0x100; key :: 0x300: i64; mouse :: 0x400: i64; }
main :: () {
    k := Ev.key(42);            // stored tag = 1 (ORDINAL), should be 0x300
    if k == {
        case .quit:      { print("quit\n"); }
        case .key:  (v)  { print("key {}\n", v); }   // never taken
        case .mouse: (v) { print("mouse {}\n", v); }
    }
}
```

`sx run` → (no output). `xx k` reads `1` (the ordinal); a `match` whose arms
are ordered so the intended arm is NOT physically adjacent to the switch's
unreachable-default block prints nothing. (With a different arm order the
UB may accidentally fall into the right block, masking the bug.)

Ground truth from `sx ir` on `Ev.mouse(9)` + a 2-arm match:

```
store i64 2, ptr %ei.tagp        ; construction stores the ORDINAL (2)
switch i64 %etag, label %match.unr [ i64 256 -> quit ; i64 1024 -> mouse ]
```

`2` hits neither `256` nor `1024` → `match.unr`.

## Suspected area / fix

`src/ir/lower/call.zig` — the three CALL-shaped tagged-union construction sites
resolve the tag with `resolveVariantIndex` (returns the ORDINAL,
`src/ir/lower/expr.zig:1740`) instead of `resolveVariantValue` (returns the
explicit tag value, `expr.zig:1687`, which the struct-literal path
`lowerTaggedEnumLiteral` already uses at `expr.zig:1600`):

- `call.zig` ~1091 — `Type.variant(payload)` via type-function instantiation.
- `call.zig` ~1227 — `Type.variant(payload)` qualified construction.
- `call.zig` ~1695 — `.Variant(payload)` inferred-target construction.

Fix: at each site, use the ORDINAL only for the `fields[ord].ty` payload-type
lookup (the `tag < fields.len` coercion guard), and pass the EXPLICIT value
(`resolveVariantValue`) as the `enumInit` tag. Keep the two values separate —
do NOT feed the explicit value (e.g. 0x300) into `fields[...]` indexing, which
would silently skip payload coercion.

After the fix, `field_index`'s reverse-map (issue 0280) resolves these values
by their explicit tag with no need for the identity fallback, and a payloadful
`match` reaches the right arm.

### Related second defect (verify while here)

Struct-literal construction of a payloadful variant with a SCALAR payload
(`Ev.key.{ 42 }`, or a struct payload `Ev.key.{ K.{…} }`) panics at LLVM
emission: `type_bridge: unhandled node type field_access in type position —
returning .unresolved` → `unresolved type reached LLVM emission`. The
payload-LESS and the struct-payload paths that work go through
`lowerTaggedEnumLiteral`; the scalar-payload `.variant.{ scalar }` shape trips
a type-position resolution hole. Confirm whether this is the same root cause or
a separate parse/type-inference bug and split if needed.

## Verification step

Run the repro; expect `key 42`. Add a regression example (a payloadful
explicit-tag `match` that reaches its arm, and — once the tag is the explicit
value — a payloadful print `Ev.key(42)` -> `.key(42)`). Full `zig build test`.
