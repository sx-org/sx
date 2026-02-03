# 0214 — protocol erasure of a side-effectful lvalue operand evaluates it twice

> **RESOLVED (2026-07-03).** Root cause: `buildProtocolErasure`'s lvalue
> borrow branch re-lowered the operand AST via `lowerExprAsPtr` AFTER the
> operand had already been lowered as a value, so any side effect in the
> expression ran twice and the borrowed address could denote a different
> element than the value evaluation. Fix: the borrow now derives its
> address from the value's own defining instruction
> (`Lowering.refStorageAddress` in `src/ir/lower/coerce.zig`, backed by
> `Builder.getRefOp` in `src/ir/module.zig`) — `.load`/`.deref` reuse the
> already-evaluated pointer, `.global_get` re-emits `global_addr`,
> `.struct_get`/`.index_get` re-emit only address arithmetic over the same
> refs, and an `index_get` whose base is an aggregate ARRAY VALUE (module
> globals, struct-field arrays value-lower as `index_get` over the loaded
> aggregate) recurses to the aggregate's storage and GEPs that. Both the
> plain `P = xx lv` and optional `?P = xx lv` (issue-0213) destinations
> funnel through the one fixed site.
>
> Two semantics points settled alongside:
> - **By-value captures stay copies.** A `for arr (x)` / match / catch
>   capture is a by-value SSA binding; deriving the borrow through its
>   defining load would alias the CONTAINER element, making `xx x`
>   indistinguishable from the by-ref `(*x)` form. Such operands are
>   MATERIALIZED instead (`isByValueBindingIdent`): the erasure copies the
>   value into a fresh stack slot and borrows that, so mutations through
>   the protocol land in the per-iteration copy. By-ref `(*x)` captures
>   are pointer-typed and still write through to the container.
> - **A field of a call result is an rvalue.** `isLvalueExpr` now recurses
>   into the field-access base, so `xx make_pair().b` routes to the
>   self-contained copy path (previously it re-lowered the AST — calling
>   `make_pair()` twice and borrowing a garbage address).
>
> Regression test:
> `examples/protocols/1635-protocols-erasure-lvalue-single-eval.sx`.

## Symptom

Erasing an lvalue expression with side effects — e.g. `xx arr[next()]`
where `next()` advances a counter — evaluates the operand TWICE: once by
the value lowering and once by `buildProtocolErasure`'s
`lowerExprAsPtr` re-lowering (`src/ir/lower/coerce.zig`, the lvalue
borrow path). Observed: `next()` runs twice per erasure; expected: once.
Worse than a wasted call: the two evaluations can disagree, so the
borrowed protocol value can point at a DIFFERENT element than the one
the value evaluation touched.

Pre-existing on the PLAIN path (`p : P = xx arr[next()]`); the issue-0213
fix extends the same borrow path (and therefore the same double-eval) to
`?P` destinations — parity, not a regression. Found by the 0213 fix's
adversarial review (2026-07-02).

## Reproduction

```sx
#import "modules/std.sx";

P :: protocol { ping :: (self: *Self) -> i64; }
S :: struct { v: i64 = 0; }
impl P for S { ping :: (self: *S) -> i64 { return self.v; } }

g_calls : i64 = 0;   // module-global for the repro only

next :: () -> i64 {
    g_calls += 1;
    return 0;
}

main :: () -> i32 {
    arr : [2]S = ---;
    arr[0] = S.{ v = 10 };
    arr[1] = S.{ v = 20 };
    p : P = xx arr[next()];
    if p.ping() != 10 { print("wrong element\n"); return 1; }
    print("evals {}\n", g_calls);   // expected 1, observed 2
    if g_calls != 1 { return 1; }
    return 0;
}
```

## Investigation prompt

In the sx compiler at /Users/agra/projects/sx: `buildProtocolErasure`
(reached from `src/ir/lower/coerce.zig`'s erasure paths, implemented in
`src/ir/lower/protocol.zig`) handles an LVALUE operand by re-lowering the
operand expression as a pointer (`lowerExprAsPtr`) AFTER the operand was
already lowered as a value — so any side effect in the expression (a
call-indexed `arr[next()]`, a dereference chain with effects) runs twice,
and the borrowed address may denote a different element than the value
evaluation observed. What the fix likely needs: lower the operand ONCE —
either lower-as-pointer first and derive the value from the pointer when
one is needed, or cache the lowered address for the borrow instead of
re-lowering the AST node. Both the plain (`P = xx lv`) and the optional
(`?P = xx lv`, issue-0213 path) destinations funnel through the same
site, so one fix covers both. Verification: the repro above prints
`evals 1` and exits 0 (today `evals 2`, exit 1); then `zig build test` —
full corpus green, with special attention to examples/protocols/ (0421,
0422) and every erasure form in issues/0213's matrix staying
zero-alloc/borrow-correct.
