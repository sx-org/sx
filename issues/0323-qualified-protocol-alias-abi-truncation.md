# 0323 — a qualified protocol alias is ABI-lowered as one `i64`

> **NULLARY PATH GREEN; PARAMETERIZED IDENTITY OPEN (2026-07-21).** Pending identifier/qualified alias chains are now
> canonicalized from raw source/import facts before any ABI consumer interns
> its type, independent of declaration/import order. A terminal nullary
> protocol is materialized exactly once and every alias binds its exact nominal
> TypeId. Runtime protocol metadata, impls, thunks and vtables are keyed by that
> identity, so distinct namespace protocols with the same display name cannot
> overwrite or share method sets. No SX syntax or public API changed.
>
> This proof covers nullary protocols. Parameterized templates are still
> selected through global spelling maps and their instance/impl/thunk keys omit
> exact template identity. That adjacent blocker is filed as issue 0329.

## Symptom

Given a protocol authored in another module:

```sx
P :: protocol #identity {
    value :: (self: *Self) -> i64;
}
```

this qualified alias compiles but crashes:

```sx
foreign :: #import ".../protocol.sx";
Alias :: foreign.P;

S :: struct { n: i64; }
impl Alias for S { value :: (self: *S) -> i64 { self.n } }

forward :: (item: Alias) -> i64 { item.value() }

main :: () -> i32 {
    item := S.{ n = 37 };
    if forward(xx item) == 37 then 0 else 1
}
```

Run:

```sh
./zig-out/bin/sx run issues/0323-qualified-protocol-alias-abi-truncation.sx --opt 0
./zig-out/bin/sx run issues/0323-qualified-protocol-alias-abi-truncation.sx --opt 3
```

Before the fix on arm64 macOS, opt 0 exited 134 with a garbage indirect-call
target and opt 3 exited 133. Both now exit 0. The focused corpus also places
parameters, returns, fields, optionals, pointers, views, nested aliases and the
namespace import before/after one another adversarially at both opt levels.

## IR evidence

For a three-word default protocol layout `{ctx, type_id, vtable}`, the broken
function is declared with a single scalar argument:

```llvm
define internal i64 @forward(ptr %context, i64 %item)
```

Its entry block stores that `i64` into an 8-byte temporary and then loads a
24-byte `{ptr, i64, ptr}` protocol aggregate from it. The caller likewise
stores the concrete source object into an 8-byte ABI temporary instead of
building/passing the protocol value. The missing context/type/vtable words are
therefore arbitrary stack contents.

The stdlib ZIP public test exposed this through the ordinary pattern
`ZipSource :: zip.Source`: a helper taking `ZipSource` crashed at opt 0 and
returned `InvalidData` at opt 3 without calling its source. Spelling the same
parameter directly as `zip.Source` emits the correct aggregate ABI and works.

## Required behavior

- A local alias to a qualified protocol must preserve the target protocol's
  exact nominal TypeId, layout, ownership mode, method set, and ABI class.
- Parameters, returns, struct fields, optionals, pointers/views, and nested
  aliases must agree on that canonical type.
- `impl Alias for T` and erasure to `Alias` must use the qualified protocol's
  implementation and diagnostics, including `#identity` borrowing semantics.
- Direct aliases and direct qualified protocol annotations must remain green.
- Verify opt 0 and opt 3, add focused module/protocol regressions, and run the
  compiler unit plus full example corpus.

The likely fault is a source-aware alias resolution split: semantic method
dispatch reaches the target protocol, while function ABI classification and
call coercion retain a scalar/stale alias type. Canonicalize the alias before
both declaration ABI lowering and call planning rather than patching one
backend shape.
