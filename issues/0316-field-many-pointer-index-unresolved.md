# 0316 — indexing a `[*]T` struct field through the fused `r.ptr[0]` chain types the base as `[*]unresolved`

## Symptom

Indexing a many-pointer STRUCT FIELD directly through member access —
`r.ptr[0]` where `ptr: [*]u8` — is rejected with:

```
error: cannot index a value of type '[*]unresolved'
```

Expected: the element type is the field's declared `[*]u8` element (`u8`),
and the index lowers exactly like the two-step spelling.

Three data points isolate the shape:
- a LOCAL `[*]u8` indexes fine (`p[0]` → works),
- the TWO-STEP extraction works (`p := r.ptr; p[0]` → works),
- only the FUSED `r.ptr[0]` postfix chain fails.

So the field's many-pointer ELEMENT type is lost precisely on the
index-on-field-access expression path — some lookup there returns the
`.unresolved` sentinel (the no-silent-fallback discipline surfacing it
loudly instead of guessing).

Blast radius: every `*Raw` view in `std/core.sx` (`SliceRaw.ptr[i]`,
`ClosureRaw` is `*void` so unaffected, the new `StringRaw.ptr[i]`), and any
user struct carrying a `[*]T` field. Hit while adding `StringRaw` (whose
whole point includes `raw.ptr[raw.len] == 0`).

## Reproduction

Standalone, no std:

```sx
Raw :: struct {
    ptr: [*]u8;
}

main :: () -> i32 abi(.c) {
    buf : [4]u8 = .[7, 8, 9, 10];
    r := Raw.{ ptr = xx @buf };
    x := r.ptr[0];      // error: cannot index a value of type '[*]unresolved'
    return xx x;
}
```

Expected: exit code 7. Actual: the diagnostic above, exit 1.

Control (both work today):

```sx
    p : [*]u8 = xx @buf;  return xx p[0];      // local many-pointer: OK
    p := r.ptr;           return xx p[0];      // two-step through a local: OK
```

## Investigation prompt

In `~/projects/sx`: `src/ir/lower/expr.zig`'s index lowering has a fast path
for indexed reads that computes the ELEMENT type from the indexed OPERAND.
For an `index_expr` whose object is a `.field_access`, that path resolves
the field's type through a helper that evidently does not thread a struct
field's `many_pointer` element (returns the `.unresolved` sentinel), while
the plain-identifier operand path does. Candidates: the indexed-read fast
path itself (see the issue-0250 fold comments around `getExprAlloca` /
the indexed-read helpers), or the expression typer's field-type resolution
(`src/ir/expr_typer.zig`) that the index arm consults for the base type.
Find where the base type of `r.ptr` is computed for the INDEX arm, make it
resolve the struct field's declared type (the same result the two-step
spelling gets), and verify:

1. `./zig-out/bin/sx run issues/0316-field-many-pointer-index-unresolved.sx`
   exits 7.
2. Then resolve per the standard procedure (move the repro to
   `examples/types/` as a regression test, seed + regen its goldens).
3. The pending StringRaw work (uncommitted in the tree when this was filed:
   `StringRaw` in `library/modules/std/core.sx` + the `std.sx` facade alias)
   has its acceptance example blocked on this — it reads bytes through
   `raw.ptr[i]`. NOTE (verified 2026-07-19): string bytes are NOT always
   NUL-terminated (slice views `s[a..b]` aren't; literals and
   `alloc_string`-backed strings are) — the example may check
   `raw.ptr[raw.len] == 0` for a LITERAL-backed string only, never as a
   type-level invariant.
