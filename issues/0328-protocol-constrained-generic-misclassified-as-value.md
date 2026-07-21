# 0328 — protocol-constrained generic is misclassified as a value parameter

> **RESOLVED (2026-07-21).** Root cause: `UnknownTypeChecker.isTypeParam`
> classified `$T: Protocol` constraints (and attributed their spans) against
> the diagnostic renderer's mutable current file, so a previously visited
> facade (`modules/std.sx`) decided the classification for main-file and
> imported generic declarations. Fix: declaration-author source is kept
> separate from the renderer's current file (unstamped main-file nodes fall
> back to `main_file` for both authorities), and
> `buildGenericStructTemplate` stores normalized author provenance so
> monomorphization cannot inherit an unrelated caller/facade context. No
> syntax or public language API changed.
> Evidence (verified on the committed tree, 2026-07-21): the pinned repro
> `issues/0328-…​.sx` prints `5` at opt 0+3; example 0204 passes at opt 0+3;
> negatives 0172/0760/1111/1115 keep byte-exact value-parameter diagnostics
> at opt 0+3; four full `zig build test` corpus runs green today (the repro
> stays pinned in the issues corpus as the regression).

## Symptom

A generic type parameter constrained by an in-scope protocol (`$T: Combines`)
is diagnosed as a compile-time value parameter when its generic struct is
instantiated after importing `modules/std.sx`. The compiler emits repeated
`'T' is a value parameter, not a type` errors with spans rendered against
unrelated text in `library/modules/std.sx`; it should compile and print `5`.
The established corpus case
`examples/generics/0204-generics-generic-protocol-constraint.sx` fails in the
same way with nine spurious diagnostics.

## Reproduction

```sx
#import "modules/std.sx";

Combines :: protocol #inline {
    combine :: (self: *Self, other: Self) -> Self;
}

Value :: struct { n: i64; }

impl Combines for Value {
    combine :: (self: Value, other: Value) -> Value {
        Value.{ n = self.n + other.n }
    }
}

Box :: struct ($T: Combines) {
    value: T;
    init :: (value: T) -> Box(T) { Box(T).{ value = value } }
    merge :: (self: *Box(T), other: T) {
        self.value = self.value.combine(other);
    }
}

main :: () -> i64 {
    box := Box(Value).init(.{ n = 2 });
    box.merge(.{ n = 3 });
    print("{}\n", box.value.n);
    0
}
```

The checked-in standalone copy is
`issues/0328-protocol-constrained-generic-misclassified-as-value.sx`.

## Investigation prompt

Fix issue 0328 without changing SX syntax or its public language API. Start in
`src/ir/semantic_diagnostics.zig`, especially
`UnknownTypeChecker.isTypeParam`, which classifies a protocol constraint with
`Lowering.isProtocolConstraint(cname, diagnostics.current_source_file)`.
Audit the source-file save/restore boundary used while walking and
instantiating imported generic declarations in `src/ir/lower/generic.zig` and
`src/ir/lower.zig`: both protocol lookup and diagnostic spans must use the
generic declaration's author source, never the currently visited facade
(`modules/std.sx`). Do not weaken the real `$N: u32` value-in-type-position
diagnostic and do not add a fallback that treats every unknown constraint as a
type.

Add the standalone issue repro to the corpus with expected exit/stdout/stderr,
retain negative coverage for value parameters, and verify:

1. issue 0328 prints `5` at `--opt 0` and `--opt 3`;
2. example 0204 passes at `--opt 0` and `--opt 3`;
3. the existing value-parameter diagnostics remain exact;
4. `zig build`, `zig build test`, and the full corpus pass.

## Focused result

`UnknownTypeChecker` now keeps declaration-author source separate from the
diagnostic renderer's mutable current file. For an unstamped main-file node,
both authorities explicitly fall back to `main_file`; a previously visited
facade can no longer decide whether `$T: Protocol` is a type parameter or
misattribute its spans.

`buildGenericStructTemplate` likewise normalizes its author source from the
explicit declaration source, current source, or main file, in that order. The
template stores that provenance and uses it to classify protocol constraints,
so later monomorphization cannot inherit an unrelated caller/facade context.

Focused evidence after a clean `zig build`:

- issue 0328 prints exactly `5` at opt 0/3;
- example 0204 prints its three expected animation lines at opt 0/3;
- examples 0172, 0760, 1111, and 1115 retain byte-exact value-parameter
  diagnostics at opt 0/3.

The full combined `zig build test`/corpus gate has since passed repeatedly
on the committed tree (see the RESOLVED banner).
