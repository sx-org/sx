# 0321 — no module-private or opaque struct state

> **OPEN (2026-07-21).** SX has no field-visibility or opaque-state feature.
> A public wrapper can hide the module that declares its implementation type,
> but callers may still read and mutate the field and may contextually
> construct the wrapper with an unnameable implementation value. Fixing this
> requires a public language-design decision, so no compiler change is proposed
> without direction.

## Symptom

An idiomatic stdlib abstraction cannot expose a by-value state type while
keeping its representation and invariants private. Flat imports successfully
keep internal declarations out of a facade's namespace, but every struct field
remains externally accessible and every struct remains externally
constructible.

This blocks complete encapsulation of types such as `std.deflate.Encoder` and
`std.zip.Reader`: their implementation state must be stored by value for
predictable ownership and performance, but a public `state` field exposes the
internal engine and lets callers bypass initialization and teardown invariants.

Prefixing the field with `_` or `__` is only a naming convention; the compiler
does not restrict it.

## Reproduction

`issues/0321-no-module-private-struct-state/internal.sx`:

```sx
Secret :: struct { value: i64; }

make_secret :: (value: i64) -> Secret {
    Secret.{ value = value }
}
```

`issues/0321-no-module-private-struct-state/facade.sx`:

```sx
#import "internal.sx";

Wrapper :: struct {
    state: Secret;

    init :: (value: i64) -> Wrapper {
        Wrapper.{ state = make_secret(value) }
    }

    get :: (self: *Wrapper) -> i64 { self.state.value }
}
```

`issues/0321-no-module-private-struct-state.sx`:

```sx
facade :: #import "0321-no-module-private-struct-state/facade.sx";

main :: () -> i32 {
    wrapped := facade.Wrapper.init(1);

    // Both operations compile despite Secret not being a facade member.
    wrapped.state.value = 2;
    forged : facade.Wrapper = .{ state = .{ value = 3 } };

    if wrapped.get() != 2 { return 1; }
    if forged.get() != 3 { return 2; }
    0
}
```

Run:

```sh
./zig-out/bin/sx run issues/0321-no-module-private-struct-state.sx
```

Current result: exit 0.

Expected: the language must provide an explicit way for the facade to make the
field and contextual construction inaccessible outside its authoring module,
while retaining a concrete by-value layout internally.

## Design decision required

Possible designs include field visibility (`private state: Secret`), a
module-private declaration/field modifier, or an opaque public type whose
layout is available only to its authoring module. The choice affects SX source
syntax, reflection, struct literals, field promotion, namespace imports,
generic instantiation, ABI/layout queries, and diagnostics. It is therefore a
public language API change rather than an internal compiler repair.

Until that decision is made, stdlib wrappers can hide named engine imports but
cannot enforce state encapsulation. They should keep the representation field
provisional and document that callers must use the constructor and `deinit`.
