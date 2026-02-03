# 0232 — erasure of an index over a CALL-RESULT array still double-evaluates

> **RESOLVED (2026-07-10).** Index lvalue classification now follows the base expression, so an index over a call-result array is an rvalue and protocol erasure copies the already-evaluated value exactly once.

## Symptom

One-line: `p : P = xx make_arr()[next()]` — indexing an rvalue array
returned by a call, then erasing the element — still takes the
AST-re-lowering fallback in `buildProtocolErasure`, so `make_arr()` (and
`next()`) run twice.

- Observed: both calls evaluated twice (value pass + borrow re-lowering);
  the borrow may also point at a different temp than the value read.
- Expected: single evaluation — either materialize the call-result array
  once and borrow into that temp (rvalue-erasure copy semantics, mirroring
  the issue-0214 F2/F3 folds), or classify the whole expression as an
  rvalue (index over an rvalue base is an rvalue) and take the existing
  copy path.

This is the residual edge of the issue-0214 family after its review
folds: `refStorageAddress` covers storage-backed index bases
(local/global/field arrays) and the F3 fold made FIELD access recurse
into its base for rvalue classification, but INDEX expressions over a
call-result base still classify as lvalue and fall to `lowerExprAsPtr`.

## Reproduction

```sx
#import "modules/std.sx";

P :: protocol { get :: (self: *Self) -> i64; }
S :: struct { v: i64 = 0; }
impl P for S { get :: (self: *S) -> i64 { return self.v; } }

g_mk : i64 = 0;
g_ix : i64 = 0;

make_arr :: () -> [2]S { g_mk += 1; a : [2]S = ---; a[0] = S.{ v = 10 }; a[1] = S.{ v = 20 }; return a; }
next :: () -> i64 { g_ix += 1; return 0; }

main :: () -> i32 {
    p : P = xx make_arr()[next()];
    if p.get() != 10 { return 1; }
    print("mk={} ix={}\n", g_mk, g_ix);   // expected 1 1 — observed 2 2
    if g_mk != 1 { return 1; }
    if g_ix != 1 { return 1; }
    0
}
```

## Investigation prompt

In the erasure classification (src/ir/lower/coerce.zig — `isLvalueExpr`
after the 0214 F3 fold recurses into field-access bases): make
`.index_expr` recurse into ITS base the same way (an index over an
rvalue base is an rvalue → copy path, single evaluation), or extend
`refStorageAddress` to materialize a call-result aggregate base into a
temp once and index that. The F2 materialization helper from the 0214
fold (`isByValueBindingIdent` + alloca-temp borrow) is the pattern to
reuse. Verify with the repro (mk=1 ix=1, exit 0); re-run the 0214
matrix (examples/protocols/1635) and 0421/0422; corpus green.

Found by the issue-0214 fold worker (2026-07-03), out of the reviewed
scope; pre-existing on master.
