# 0293 — typed-prefix array literal `T.[…]` silently drops the element type

> **RESOLVED** (2026-07-17), per the decided disposition: `lowerArrayLiteral`
> (src/ir/lower/expr.zig) now refuses any literal type prefix that resolves
> to a non-array/vector/slice type — scalars (`i32.[…]`) AND named
> non-aggregates (`Pt.[…]`, previously ignored the same way) — with a
> diagnostic pointing at the annotated form. `Vector(N,T).[…]`, structural
> heads (`([2]?i64).[…]`), and array-type aliases (`Nums.[…]`) keep working;
> an unresolvable prefix keeps its existing fall-through (0767 ambiguity
> path). Corpus migrated: 0037/0830/1223/1214/0316/1230 dropped the `i64.`
> prefix, 1206 annotates (`arr : [3]i32 = …` — its golden now reports the
> true `i32` element type), and the four comptime `EnumVariant.[…]` uses
> (0620/0621/0624/0632) went bare (elements are self-typed). specs.md §Array
> Types documents the prefix rule. Regression test:
> `examples/diagnostics/1248-diagnostics-array-literal-scalar-prefix.sx`.

> **DISPOSITION DECIDED (Agra, 2026-07-16): REFUSE the form.** A scalar
> element-type prefix on an array literal (`i16.[…]`, `f32.[…]`) becomes a
> COMPILE ERROR with a diagnostic pointing at the annotated form
> (`a : [4]i16 = .[1, 2, 3, 4];`). Rationale: the prefix slot on a `.[ ]`
> literal means "the aggregate type" (`Vector(3, f32).[…]` — which types
> its lanes correctly today), while `i16.[…]` reads as "the element type" —
> two different prefix meanings on one spelling, and the second was never
> implemented (it silently produced default-typed elements). Do NOT
> implement element-type prefixing; reject it. The investigation prompt
> below is amended accordingly.

**Symptom** — The typed-prefix array-literal form ignores its element-type
prefix: every element falls back to the literal default (`i64` for ints,
`f64` for floats), and the array types accordingly.

- Observed: `a := i32.[1, 2, 3];` → `type_of(a)` is `[3]i64` (32 bytes);
  `f32.[1.5, 2.5]` → `[2]f64`; `u8.[1, 2]` → `[2]i64`.
- Expected: `[3]i32` / `[2]f32` / `[2]u8` — the prefix IS the element type,
  exactly like the annotated form `a : [3]i32 = .[1, 2, 3];` (which works).

Silent-wrong-type class: the program compiles and runs, storage and type
agree with each other, but both are 4–8× wider than the user asked for.
Every corpus use except one is `i64.[…]`, where the bug is invisible
(prefix == default) — which is how it survived. Found during 1b while
walking an `i16` array through `any_element` stride views (stride math was
correct for `[4]i16`; the actual value was `[4]i64`).

**Reproduction** (standalone):

```sx
#import "modules/std.sx";

main :: () -> i64 {
    a := i32.[1, 2, 3];
    print("{}\n", type_name(type_of(a)));   // observed: [3]i64 — expected: [3]i32
    b := f32.[1.5, 2.5];
    print("{}\n", type_name(type_of(b)));   // observed: [2]f64 — expected: [2]f32
    c := u8.[1, 2];
    print("{}\n", type_name(type_of(c)));   // observed: [2]i64 — expected: [2]u8
    ok : [3]i32 = .[1, 2, 3];
    print("{}\n", type_name(type_of(ok)));  // [3]i32 — the annotated form is correct
    return 0;
}
```

**Investigation prompt** — ready to paste into a fresh session:

> Fix issue 0293 per its DECIDED disposition (Agra): REFUSE the
> scalar-element-type prefix on array literals. `i16.[…]` / `f32.[…]` /
> any prefix that resolves to a NON-aggregate type in front of a `.[ ]`
> literal must be a compile error, e.g.: "a '.[ ]' literal's type prefix
> names the aggregate type, not the element type — annotate instead:
> `a : [3]i16 = .[…]` (or use a full aggregate prefix like
> `Vector(3, f32).[…]`)". Do NOT implement element-type prefixing.
> Repro: `issues/0293-typed-prefix-array-literal-drops-element-type.sx`
> (today the first three lines print silently-wrong type names; after the
> fix the file becomes a diagnostics example). Suspected area: the
> typed-prefix literal path in `src/ir/lower/expr.zig` (however the parser
> encodes `T.[…]` — find where `Vector(N,T).[…]` resolves its prefix and
> add the aggregate-kind gate there). Keep `Vector(N,T).[…]` and future
> whole-aggregate prefixes working. Migration: corpus uses
> 0037/0830/1223/1214/0316 are `i64.[…]` — drop the prefix (bare `.[…]`
> infers [N]i64 identically); 1206 uses `i32.[…]` — annotate it. Add a
> diagnostics example pinning the new error (11xx/12xx block). Verify:
> `zig build test` green (only the migrated examples' goldens change —
> review per the snapshot-integrity rule); specs.md + readme.md updated if
> either shows the scalar-prefix spelling. Mark this .md RESOLVED with the
> regression-example path when done.
