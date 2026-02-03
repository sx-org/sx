# 0242 — `*[]T` (pointer-to-slice) indexing is rejected, contradicting specs.md

> **RESOLVED (2026-07-10).** `*[]T` now auto-dereferences for element typing and read/write/address paths, matching the specification; `.len` continues through the existing pointer auto-deref path.

## Symptom

One-line: specs.md:1080's Pointer Types table lists `*[]T` as indexable
(`[i]` = yes, `.len` = yes), but the compiler rejects `psl[i]` in every
position (read/write/address-of) with the issue-0155 family diagnostic
("dereference first" hint).

- Observed: "cannot index a value of type '*[]i64' — ... dereference
  first" (clean diagnostic since the 0155 fix; the pre-0155 write/addr
  positions panicked).
- Expected per spec: `psl[i]` ≡ `psl.*[i]` (auto-deref through the
  pointer to the slice), and `psl.len` ≡ `psl.*.len`.

Either the spec table is aspirational (then specs.md:1080 must be
corrected) or the auto-deref is unimplemented (then implement it — the
sibling `*[N]T` pointer-to-array indexing DOES work, so the machinery
pattern exists in `ptrToArrayElem`).

## Reproduction

```sx
#import "modules/std.sx";
main :: () -> i32 {
    a : [3]i64 = .[ 10, 20, 30 ];
    sl : []i64 = a[0..3];
    psl := @sl;
    print("{}\n", psl[1]);    // spec: 20; observed: "cannot index" diagnostic
    psl[1] = 99;              // spec: writes through; observed: diagnostic
    print("{}\n", psl.len);   // check .len too per the spec row
    0
}
```

## Investigation prompt

Decide spec-vs-implementation first (specs.md:1080 row `*[]T`). If
implementing: in the index-lowering element-type resolution
(`ptrToArrayElem` / `getElementType`, src/ir/lower/), add a
pointer-to-slice arm that derefs to the slice and indexes its data
pointer (mirror the `*[N]T` arm; all FOUR index paths — read
lowerIndexExpr, write lowerAssignment .index_expr, address-of, and
lowerExprAsPtr .index_expr — must get it; the 0155 fix + fold
centralized the rejection in diagNonIndexable, so the new arm slots in
BEFORE the guard). Also wire `.len` member access on `*[]T` if missing.
If NOT implementing: fix specs.md:1080 to `[i]` = no for `*[]T` and
keep the diagnostic. Either way, correct the `diagNonIndexable`
doc-comment and the issues/0155 writeup wording (they currently call
`*[]T` "non-indexable" as if by design). Regression: positive example
under examples/types/ (0804 free) or a diagnostics pin per the
decision; corpus green.

Found by the adversarial review of the issue-0155 fix (2026-07-04).
