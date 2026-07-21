# 0331 — alias resolution depth caps silently reject valid chains

> **OPEN (2026-07-21).** Independent adversarial review found fixed traversal
> limits in compiler-internal alias resolution. No language API change is
> needed; valid acyclic aliases must not depend on an arbitrary small depth.

## Symptom

Generic template aliases stop at depth 8, function aliases at 9,
protocol/pending type aliases at 16, and reverse-order module-constant aliases
receive only 16 fixpoint rounds. A longer valid chain is treated as unresolved
and some consumers can then fall back to a same-spelled global winner.

## Reproduction

```sx
A00 :: A01; A01 :: A02; A02 :: A03; A03 :: A04;
A04 :: A05; A05 :: A06; A06 :: A07; A07 :: A08;
A08 :: A09; A09 :: A10; A10 :: 37;

main :: () -> i32 { if A00 == 37 then 0 else 1 }
```

Add equivalent 10+ function/generic aliases and 17+ type/protocol/constant
aliases, plus direct and indirect cycles. Acyclic chains must resolve; cycles
must produce an explicit diagnostic.

## Investigation prompt

Replace hard-coded depth/fixpoint limits in `lower/nominal.zig`,
`lower/decl.zig`, and `protocols.zig` with visited declaration-identity cycle
detection and progress-to-fixpoint traversal bounded by the finite declaration
set. Emit a clear cycle diagnostic rather than returning a plausible fallback.
Add boundary+1 acyclic cases and cycles for function, generic, type, protocol,
and module-constant aliases; verify opt 0/3, `zig build`, `zig build test`, and
the full corpus.
