# 0212 — forward ref to a shadowed name binds the imported author; struct == error.Tag silently type-checks

> **RESOLVED (2026-07-02).** Both sub-defects fixed; repro now prints `r=1`
> (the LOCAL author wins — grounded in specs.md "Collision rules": *own wins*,
> matching the declared-above behavior).
>
> **(1) Wrong-author binding** — root cause: `scanDecls` pass 0b (the
> issue-0134 up-front shadow reservation, `src/ir/lower/decl.zig`) grouped
> genuine shadows by **(kind, name)**, so the CROSS-KIND pair (imported
> `E :: struct {}` + local `E :: error { Fault }`) was not a "genuine shadow"
> and reserved nothing. The fn signature, resolved before the local decl
> registered, then hit `namedRefTid`'s `orelse findByName` fallback and bound
> the FIRST-INTERNED author (the imported struct) — while the body, resolved
> source-aware AFTER registration, bound the local error set. The same param
> was `{}` in the LLVM signature and `i32` in the body slot; the ABI coercion
> zeroed the value and `e == error.Fault` was silently false. Note the
> per-decl DISTINCT nominal ids already existed at registration time
> (`shadowNominalId` is kind-agnostic) — only the reservation was gated by
> kind. Fix: group pass 0b by **name only**; each author still reserves via
> its own kind's reserver, so the reserved slot's kind matches registration
> (`updatePreservingKey` key-stability holds). Verified symmetric (local
> struct + imported error set → local struct wins).
>
> **(2) Missing type-check** — `<struct value> == error.Tag` was ALREADY
> rejected (`tryLowerErrorSetEquality`); the silent path was the raw-u32
> fallback in `lowerErrorTagLiteral` (`src/ir/lower/expr.zig`): a tag literal
> flowing into a NOMINAL non-error destination (struct/enum/union/tagged
> union) fell back to the raw u32 global id and reinterpreted it as the
> aggregate's bytes (`f(error.Fault)` into `(s: S)` read back `s.x == 5`, the
> tag id, standalone — no shadow needed). Now a loud compile error; the
> spec-blessed integer context (`id : u32 = error.X`) is unchanged.
>
> **Enum-sibling finding:** `E.B` VALUE-position access on a cross-kind
> shadowed name (imported struct `E` + local enum `E`) errors loudly with
> "field 'B' not found on type 'Type'" **regardless of declaration order**
> (declared-above fails identically) — a pre-existing rough edge in the
> value-expression resolution path, not the forward-binding defect (loud, no
> silent miscompile; message could be better). Out of scope here.
>
> Regression tests: `examples/errors/1065-errors-shadowed-error-set-forward-ref.sx`
> (+ companion `1065-.../a.sx`) pins (1);
> `examples/diagnostics/1208-diagnostics-error-tag-non-error-destination.sx`
> pins (2). The 0211-review INFO item also landed:
> `src/ir/lower/nominal.test.zig` covers `adoptsForwardStructStub`'s
> adopting-kind list (barrel: `src/ir/ir.zig`).

## Symptom

**One line:** when a fn signature forward-references a name that is BOTH
imported (as a struct) and declared locally below (as an error set), the
signature silently binds the IMPORTED author — and the resulting
struct-typed value then compares against `error.Fault` without any
diagnostic, evaluating false.

Observed: `r=0`, exit 0, no diagnostic (the `e == error.Fault` arm is
silently never taken; even the call `f(error.Fault)` passing an error tag
where a struct is expected type-checks). Expected: the local `E` wins the
reference (r=1), or — if shadow-resolution order is by design — a loud
diagnostic on the cross-kind comparison / argument mismatch.

Two distinguishable sub-defects:
1. **Wrong-author binding:** a forward reference from a fn signature to a
   shadowed name resolves to the imported decl instead of the same-file
   decl below (a same-file decl otherwise wins shadow resolution — the
   issue-0134 machinery handles declared-before-use shadows correctly).
2. **Missing type-check:** `<struct value> == error.Tag` (and passing
   `error.Tag` where a struct param is expected) compiles silently.

Pre-existing — found by the issue-0211 adversarial review, verified
byte-identical behavior before and after the 0211 fix (it is NOT a
regression from 0211's stub-adoption change).

## Reproduction

`issues/0212-shadowed-error-set-forward-ref-binding.sx` (+ sibling
`0212-shadowed-error-set-forward-ref-binding/a.sx`), self-contained:

```sx
// a.sx
E :: struct {}
```

```sx
// main
#import "modules/std.sx";
#import "0212-shadowed-error-set-forward-ref-binding/a.sx";
f :: (e: E) -> i32 {
    if e == error.Fault { return 1; }
    return 0;
}
E :: error { Fault }
main :: () -> i32 {
    r := f(error.Fault);
    print("r={}\n", r);   // observed r=0; expected r=1 or a diagnostic
    return 0;
}
```

Unpinned (it runs, with wrong semantics); pin as a regression example
once fixed.

## Investigation prompt

> Two related defects in the sx compiler, found via issue 0211's review
> (see that .md for the stub-adoption background):
>
> (1) In `src/ir/lower/decl.zig` `scanDecls` / the issue-0134 shadow
> machinery (`src/ir/lower/nominal.zig`: `shadowNominalId`,
> `reserveShadow*Slot`), a fn signature resolved BEFORE the local decl is
> scanned looks the name up via `type_resolver.resolveNamed` →
> `findByName`, which returns the imported author's type. The local
> same-file decl should win for references within its file (as it does
> when declared above the fn). Likely fix direction: scanDecls should
> reserve/register nominal type decls (or at least their names, as
> forward stubs keyed to the local file) BEFORE resolving fn signatures
> in the same scope pass, so a same-file forward reference binds the
> local author. Check how struct/enum forward refs behave with the same
> shadow shape (imported `E :: struct{}` + local `E :: enum{...}` below
> a fn using E) — the review found the enum sibling surfaces a compile
> error instead of silently mis-binding; understand why error sets
> differ and whether the enum error is itself the intended behavior.
>
> (2) Independently, `<struct value> == error.Tag` and passing
> `error.Tag` to a struct-typed param pass the type checker silently
> (evaluating false / garbage). Comparing or coercing an error tag
> against a non-error type should be a compile-time type error — find
> the comparison/coercion check (likely `src/ir/lower/expr.zig` or the
> binary-op type rules) and reject cross-kind error comparisons loudly.
>
> Also fold in the issue-0211 review's INFO item: add a Zig unit test
> covering `adoptsForwardStructStub`'s adopting-kind list (enum, union,
> tagged_union, error_set → true; struct/scalar → false) in the
> `.test.zig` file that covers `src/ir/lower/nominal.zig` (create
> `src/ir/lower/nominal.test.zig` + barrel import if none exists, per
> the unit-test convention in CLAUDE.md).
>
> Verify: the repro prints r=1 (or errors loudly — document which),
> the enum-sibling probe behaves consistently, full `zig build test`
> green, and pin the repro per "Resolving an open issue".
