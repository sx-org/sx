# 0331 — alias resolution depth caps silently reject valid chains

> **RESOLVED (2026-07-21).** `followAliasChain` (src/ir/lower/nominal.zig)
> now walks iteratively with a visited declaration-identity set — any
> acyclic chain resolves (bounded by the finite alias-decl set), a revisit
> is an alias cycle diagnosed exactly once per cycle
> ("alias cycle 'A -> B -> A' can never resolve — point one of these at a
> real declaration"). The 8/9/16 depth arguments are gone from all callers
> (generic template, fn alias, protocol head, pending type alias), and the
> module-const alias fixpoint in src/ir/lower/decl.zig dropped its 16-round
> cap (each productive round registers ≥1 new name, so it terminates by
> decl count). Regression: this file's `.sx` (all four families past the
> old caps, opt 0/3), examples/basic/0068-basic-alias-chain-depth.sx,
> examples/generics/0222-generics-alias-chain-depth.sx,
> examples/protocols/1636-protocols-alias-chain-depth.sx, and
> examples/diagnostics/1269-diagnostics-alias-cycle.sx (direct + indirect
> cycles, one diagnostic each, detected even without a use site).

> Original report follows.

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
