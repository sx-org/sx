# 0245 — struct-value `==` / `!=` is broken for most field shapes (invalid IR OR silently wrong)

> **RESOLVED** (2026-07-05). Root cause: `emit_llvm`'s struct-compare arm
> (`LLVMEmitter.emitCmp`) only ever handled a 2-scalar-field shape — a 1-field
> struct emitted invalid `icmp { i64 }`, a 3+-field struct SILENTLY compared only
> fields 0/1 (`S{1,2,3} == S{1,2,999}` → true), and any non-scalar field (f64 /
> nested struct / string / optional / tagged-union) crashed the LLVM verifier or
> was misread as a tagged-union payload (array field silently ignored).
>
> Fix: struct `==` / `!=` is now lowered **field-wise at LOWER time**
> (`src/ir/lower/expr.zig` — `lowerStructEquality` + `lowerFieldEquality`, gated
> in `lowerBinaryOp` just before the tuple/tuple-membership handling). Every field
> is compared against its OWN type — float→fcmp, string→str_eq, nested
> struct/tuple→recurse, tagged-union field→tag-only, slice/pointer/cstring→
> identity — and AND-reduced (`==`) / negated (`!=`). Non-comparable fields
> (untagged `union`, fixed `[N]T` array, `?T` optional) are rejected with a
> located diagnostic, matching how those shapes are rejected as bare `==`
> operands. `emit_llvm`'s narrow struct arm is now reached ONLY by the string /
> slice / tagged-union `{ptr,len}` / `{tag,payload}` reductions it was written
> for — its behavior is unchanged. Semantics recorded in `specs.md`
> (§Struct Types → "Struct Value Equality").
>
> Regression test: `examples/types/0804-types-struct-equality.sx` (full positive
> matrix — 1/3/5-field, nested, string, f64, padding, tagged-union field, `!=`).
> The 0233 bare-union/array rejection (`examples/diagnostics/1225`) is unchanged.

## Symptom

One-line: `emitCmp` in `src/ir/emit_llvm.zig` (the struct-compare arm)
only handles a 2-field struct whose both fields are scalars; every other
struct shape either emits invalid LLVM IR or silently compares the wrong
fields. No diagnostic in any case.

Observed (each `x == y` on two equal struct values):

- **1-field struct** `S{a:i64}` → `icmp eq { i64 }` → LLVM verification
  failure ("Invalid operand types for ICmp instruction"). The
  `n_fields >= 2` guard is false, so it falls through to a raw aggregate
  `icmp`.
- **3+-field struct** `S{a,b,c:i64}` → **SILENTLY WRONG**: only fields 0
  and 1 are compared; field 2+ is ignored. `S{1,2,3} == S{1,2,999}`
  returns `true`. No diagnostic. (This is exactly the REJECTED-PATTERNS
  "silent wrong result" the project forbids.)
- **2-field struct with a non-scalar field 1** (e.g. `S{a:i64, b:Inner}`
  where `Inner` is a struct, or `S{a:i64, b:[2]i64}`) → `icmp eq` on the
  aggregate sub-field → LLVM verification failure.
- **struct containing a union field** → `icmp eq [N x i8]` on the union
  storage → LLVM verification failure (this is the struct-recursion side
  of issue 0233; the top-level untagged-union `==` was fixed in 0233).

Expected: either a full field-wise recursive compare (that descends into
nested structs, rejects non-comparable sub-aggregates like unions/arrays
with a located diagnostic), or a located diagnostic rejecting struct `==`
for the shapes it cannot compare. Never invalid IR, never a silent
partial compare.

What DOES work today (keep working): 2-field struct with two scalar
fields — this is the shape strings (`{ptr,len}`), slices (`{ptr,len}`),
and tagged unions (`{tag,[N x i8]}` → tag-only) rely on. String `==` is
routed to `str_eq` before reaching this path; slice/tagged-union `==`
depend on this 2-scalar-field arm.

## Reproduction

```sx
#import "modules/std.sx";
S3 :: struct { a: i64; b: i64; c: i64; }
main :: () -> i32 {
    x : S3 = .{ a = 1, b = 2, c = 3 };
    y : S3 = .{ a = 1, b = 2, c = 999 };
    // BUG: prints "eq" — field `c` is silently ignored.
    if x == y { print("eq (WRONG: c ignored)\n"); } else { print("neq\n"); }
    0
}
```

```sx
#import "modules/std.sx";
S1 :: struct { a: i64; }
main :: () -> i32 {
    x : S1 = .{ a = 1 };
    y : S1 = .{ a = 1 };
    // BUG: LLVM verification failure — `icmp eq { i64 }`.
    if x == y { print("eq\n"); }
    0
}
```

## Investigation prompt

The struct-compare arm is `LLVMEmitter.emitCmp` in
`src/ir/emit_llvm.zig` (~line 1864, the `kind == LLVMStructTypeKind`
branch). It currently: (a) gates on `n_fields >= 2`, dropping 1-field
structs to a raw aggregate `icmp`; (b) compares ONLY fields 0 and 1,
ignoring fields 2+; (c) assumes fields 0/1 are scalar-`icmp`-able,
failing on nested struct/array/union sub-fields.

The correct fix is a **recursive field-wise compare** built at LOWER
time (in `src/ir/lower/expr.zig`, near the issue-0233 guard around line
3474) where TypeId/span are available — emit per-field `cmp_eq`/`cmp_ne`
against each field's own type, AND-reduce (for `==`) / OR-reduce (for
`!=`), recursing into nested structs/tuples, and reusing the 0233 guard
to reject union/array sub-fields with a located diagnostic. The
emit_llvm struct arm should then only ever see the reduced scalar/pointer
comparisons (or be deleted in favour of the lowered form). Keep string
(`str_eq`), slice (`{ptr,len}` identity), and tagged-union (tag-only)
comparisons working — either special-case them in the lowering or ensure
the recursive walk produces the same result.

Verification: the two repros above must diagnose-or-compare-correctly
(3-field must print "neq"; 1-field must not crash the verifier); add
regression examples under `examples/types/` or `examples/diagnostics/`;
existing string/slice/tagged-union `==` examples stay green.

Found by the issue-0233 fix worker (2026-07-03) while probing the
aggregate-`==` policy matrix. NOT fixed alongside 0233 (0233 scoped to
untagged-union/array top-level operands; struct `==` is a broader
emit_llvm rework).
