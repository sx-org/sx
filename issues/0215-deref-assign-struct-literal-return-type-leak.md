# 0215 — deref-assign struct literal is typed from the FUNCTION RETURN TYPE, not the assignment target

> **RESOLVED (2026-07-03).** Root cause: `src/ir/lower/stmt.zig`
> `lowerAssignment`'s target-type seeding chain had arms for identifier /
> index / field-access LHS shapes but none for `.deref_expr`, so the RHS
> literal lowered against the ambient `target_type` — the function return
> type while lowering a body. Fix (`12dbc5d4`, worker-implemented in a
> worktree, cherry-picked): a `.deref_expr` arm seeds the POINTEE type of
> the LHS operand, gated on the same RHS-shape switch as the field arm
> (extracted into a shared `rhsNeedsTargetType` helper so the arms can't
> drift); a non-pointer operand leaves the type alone and the store arm
> diagnoses it. Index/member assign checked — no gap there. Regression:
> `examples/types/0191-types-deref-assign-struct-literal.sx` (all four
> return-type variants + field-default filling) + a `lower.test.zig` unit
> test, both verified failing pre-fix.

## Symptom

One-line: `p.* = .{ ... };` infers the anonymous struct literal's type from
the **enclosing function's return type** instead of the deref target's type
(`T` for `p: *T`), so the assignment is either mis-diagnosed or crashes the
backend depending on what the function happens to return.

Observed (matrix over the enclosing function's return type; the assignment
itself is identical in all four):

| fn returns | observed |
|---|---|
| *(void)* | panic: `unresolved type reached LLVM emission` (types.zig:196 tripwire) |
| `i64` | `error: cannot assign 'target' of type 'T' with a value of type 'i64'` |
| `U` (another struct) | `error: field 'x' not found on type 'U'` |
| `?i64` | `LLVM verification failed: Invalid InsertValueInst operands! %si = insertvalue i64 undef, i64 5, 0` |

Expected: the literal in `p.* = .{ x = 5 };` is typed as `T` (the pointee of
the assignment target) in every case — same as `t = .{ x = 5 };` on a plain
`t: T` local, which works.

## Reproduction

```sx
#import "modules/std.sx";

T :: struct { x: i64 = 1; y: i64 = 2; }

// The fn return type is what leaks; `-> ?i64` picked here because it is the
// LLVM-verifier-crash variant. Swap the return type per the matrix above to
// see the other three manifestations.
mk :: (p: *T) -> ?i64 {
    p.* = .{ x = 5 };
    return null;
}

main :: () -> i32 {
    t : T = .{};
    _ := mk(@t);
    print("{} {}\n", t.x, t.y);   // expected: 5 2
    0
}
```

Observed: `LLVM verification failed: Invalid InsertValueInst operands!`
Expected: prints `5 2`, exit 0.

## Investigation prompt

The compiler types an anonymous struct literal on the RHS of a
**deref-assignment** (`p.* = .{...}`) from the enclosing function's return
type instead of from the assignment target's type. Plain local assignment
(`t = .{...}` with `t: T`) and typed-decl init (`t : T = .{...}`) are fine —
only the `p.*` LHS shape is broken, which suggests the assignment-lowering
path that computes the *expected type* for the RHS literal has no arm for a
deref LHS (falls through to whatever expected-type context is ambient — the
function return type).

Where to look:
- `src/ir/lower/` — the assignment-statement lowering (grep for the deref
  lvalue arm / `.deref` in the assign path, and for how the LHS type is
  resolved to seed the RHS literal's expected type; the struct-literal
  lowering takes an expected `TypeId` from context).
- Compare with the working shapes: how plain-ident assignment and
  member-assignment (`a.b = .{...}`) thread the LHS type into
  the literal, then mirror that for the `p.*` arm (pointee type of the
  LHS expression's type).

What the fix likely needs to do: when lowering `lhs = rhs` where `lhs` is a
deref expression, resolve the pointee type of `lhs` and pass it as the
expected type for lowering `rhs` (exactly as the ident/member arms do), so
the literal is typed `T` regardless of the function's return type.

Verification:
1. Run the repro above — expect `5 2`, exit 0.
2. Re-run with the fn returning nothing, `i64`, and a different struct `U` —
   all must compile and print `5 2`.
3. `zig build && zig build test` — full suite stays green.
4. Pin the repro as a regression example (`examples/types/01xx-...` per the
   resolution procedure).

Discovered during HTTPZ Q3.4 (examples/http/1702's fake TLS provider wanted
`s.* = .{ fd = fd, mode = mode, acc = self, a = self.a };` inside
`accept :: (...) -> ?TlsConn` — diagnosed there as
`cannot assign 'target' of type 'FakeConn' with a value of type '?TlsConn'`).
