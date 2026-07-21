# 0332 — error tags do not contextually wrap optional error sets

> **RESOLVED (2026-07-21).** Root cause: `lowerErrorTagLiteral`
> (src/ir/lower/expr.zig) only recognized a direct error-set `target_type`;
> an optional context fell through to the raw `u32` tag id, which the
> optional wrapper then rejected. Fix: the tag context now unwraps an
> optional whose child is an error set — the tag is typed as that set
> (named-set membership still validated) and wrapped into the optional.
> Regressions: `examples/errors/1074-errors-optional-error-set-context.sx`
> and `examples/diagnostics/1266-diagnostics-optional-error-set-membership.sx`.

## Symptom

Assigning an `error.Tag` value to `?NamedErrorSet` is rejected even though
`specs.md` says every `T` implicitly converts to `?T`. The compiler lowers the
tag as its raw `u32` representation instead of using the optional payload's
error-set type.

Observed:

```text
error: cannot wrap a value of type 'u32' into optional '?error_set': its payload type is 'error_set'
```

Expected: the tag is contextually typed as `Failure` and wrapped into
`?Failure`.

## Reproduction

```sx
Failure :: error { Broken };

main :: () -> i32 {
    failure : ?Failure = null;
    failure = error.Broken;
    if failure == null { return 1; }
    0
}
```

Run:

```sh
./zig-out/bin/sx run issues/0332-error-tag-does-not-contextually-wrap-optional-error-set.sx
```

The program should compile, run, and return zero.

## Investigation prompt

Fix issue 0332 without changing SX syntax or its public API. In
`src/ir/lower/expr.zig`, error-tag lowering currently sees the outer optional
expected type and falls back to raw `u32`; teach contextual lowering/coercion
to use the optional child when that child is an error set. Preserve named-set
membership diagnostics and never reinterpret an error tag as an arbitrary
integer when an error-set context exists. Verify the standalone repro at opt
0/3, add focused positive and wrong-set negative regressions, then run
`zig build`, `zig build test`, and the full corpus.
