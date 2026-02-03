# issue 0154 — `null` / `---` assigned to a struct field over-stores when an enclosing `target_type` leaks

> **RESOLVED** (fix landed). Root cause: `null_literal` / `undef_literal` were
> absent from the `needs_target` switch in `lowerAssignment`
> (`src/ir/lower/stmt.zig`), so `obj.field = null` (or `= ---`) did NOT set
> `target_type` to the field's type. While lowering a function body,
> `target_type` is set to the function's RETURN type (`decl.zig:2691`) for the
> whole body, so that leaked type reached `constNull`/`constUndef`
> (`expr.zig:1788`) and built a WHOLE-STRUCT-typed null. Emit then stored a
> struct-sized `zeroinitializer` through a GEP at the field's offset — an
> oversized store that overran the field's slot and clobbered the saved
> x29/x30, so the function `ret`'d to `0x0`. Field order mattered only because
> a pointer field *after* an array field sits at a non-zero offset, pushing the
> over-store off the end of the alloca (pointer-first kept it in-bounds → silent
> but harmless). Manifested at `-O0` (`sx run` JIT + `sx build --opt 0`);
> `-O2` optimized the redundant stores away, masking it.
>
> **Fix:** add `.null_literal, .undef_literal` to the `needs_target` switch
> (`src/ir/lower/stmt.zig`), so the field's type is resolved via
> `fieldLvalueResolve` and `target_type` is set to the field type — `null`
> builds an `*i64`-typed null (correct 8-byte `store ptr null`), not a struct.
>
> **Regression test:** `examples/types/0193-types-sret-array-before-pointer.sx`.

## Symptom

Returning a struct by value segfaults (read at `0x0`) when a fixed-array field
precedes a pointer field. Observed: `Segmentation fault at address 0x0`;
expected: the struct's fields read back correctly.

## Reproduction

```sx
#import "modules/std.sx";
S :: struct {
    arr: [2]u64;   // fixed-array field FIRST
    p:   *i64;     // pointer field AFTER the array
    n:   i64;
}
mk :: () -> S {
    s : S = ---;
    s.p = null;    // ← leaked return-type target_type → whole-struct null → over-store
    s.n = 0;
    return s;
}
main :: () -> i64 {
    s := mk();
    print("n {}\n", s.n);   // expected: n 0 ; actual: Segmentation fault at 0x0
    return 0;
}
```

Trigger matrix (aarch64-macos, `-O0`): array-before-pointer + by-value return →
segfault; pointer-before-array → OK; array with no pointer → OK; by-value param
pass → OK; local copy → OK. ⇒ the `null`/`---` field-store value type, not the
sret ABI.
