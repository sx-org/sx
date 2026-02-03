# 0233 — binary `==` between two untagged-union VALUES emits invalid LLVM IR

> **RESOLVED** (2026-07-03). Root cause: the binary-op equality lowering
> (`lowerBinaryOp` in `src/ir/lower/expr.zig`) had no guard for
> non-comparable aggregate operands — an untagged `union` (raw `[N x i8]`
> storage) and a fixed `[N]T` array both fell through to a scalar `icmp` on
> the aggregate, which LLVM's verifier rejects, with no diagnostic.
> Fix: a located `.eq`/`.neq` guard added just before the tuple-op path
> (~line 3474) — if the resolved operand type is `.@"union"` or `.array`,
> emit `error: cannot compare '<T>' values with '=='/'!='` + a `note:`
> hint (compare a specific variant field / compare elements individually)
> and recover with a placeholder, never invalid IR. Regression test:
> `examples/diagnostics/1225-diagnostics-union-equality.sx` (exit 1).
>
> **Aggregate-`==` policy matrix probed** (both `==` and `!=`):
> | shape | before | after |
> |---|---|---|
> | untagged `union` | invalid IR (icmp `[8 x i8]`) | **rejected** (diagnostic) |
> | fixed `[N]T` array | invalid IR (icmp `[N x T]`) | **rejected** (diagnostic) |
> | tagged union / enum-with-payload | works (tag compare) | unchanged, works |
> | payload-less enum | works | unchanged, works |
> | `Tuple(...)` tuple | works (field-wise) | unchanged, works |
> | string | works (`str_eq`) | unchanged, works |
> | slice `[]T` | works (`{ptr,len}` identity) | unchanged, works |
> | optional `== null` / `!= null` | works | unchanged, works (NOT touched) |
> | two optionals (`?T == ?T`) | already diagnosed | unchanged |
> | protocol value | works (fat-ptr identity) | unchanged, works |
> | **struct value** | **broken** — see below | **still broken** (out of scope) |
>
> **Struct `==` probe result — a SEPARATE, broader bug (filed as
> issue 0245, not fixed here).** The struct-compare arm in
> `src/ir/emit_llvm.zig` only handles a 2-field all-scalar struct: a
> 1-field struct emits invalid IR, a 3+-field struct **silently compares
> only the first two fields** (`S{1,2,3} == S{1,2,999}` returns true), and
> a 2-field struct with a non-scalar field 1 emits invalid IR. The working
> 2-scalar-field shape is what string/slice/tagged-union rely on, so
> struct `==` was left as-is and the broader emit_llvm rework is tracked in
> 0245. This 0233 fix does NOT touch struct `==`.

## Symptom

One-line: `a == b` where both operands are a plain untagged
`union { ... }` type emits `icmp eq [8 x i8]` — LLVM verification
failure, no diagnostic.

- Observed: LLVM verification failure at compile/JIT time.
- Expected: either defined byte-equality semantics for untagged unions
  (probably wrong — padding/inactive-variant bytes are unspecified) or a
  located diagnostic ("cannot compare untagged union values with '==' —
  compare a specific variant field").

Distinct from issues 0222/0224 (match-subject gating, fixed): this is
the BINARY-OP equality lowering, reached without any `case` syntax.

## Reproduction

```sx
#import "modules/std.sx";
Shape :: union { circle: i64; rect: i64; }
main :: () -> i32 {
    a : Shape = .{ circle = 5 };
    b : Shape = .{ circle = 5 };
    if a == b { print("eq\n"); }   // LLVM verification failure today
    0
}
```

## Investigation prompt

The binary-op equality lowering (grep the `.eq`/binary compare arm in
src/ir/lower/expr.zig or ops emission for how aggregate operands are
handled) receives the raw union storage type and emits a scalar `icmp`
over `[8 x i8]`. Decide per specs.md §Operators whether aggregate `==`
is defined for unions at all (struct `==`? — check what structs do
today for comparison and mirror the policy). Most likely fix: a located
diagnostic rejecting `==` on untagged-union operands (and any other
aggregate the lowering can't compare), never invalid IR. Check tagged
unions and enums with payloads while there — what does `==` do on
those? Verification: the repro diagnoses cleanly (or compares, if specs
defines it); diagnostics regression example; corpus green.

Found by the issues-0222/0224/0226 fix worker (2026-07-03).
