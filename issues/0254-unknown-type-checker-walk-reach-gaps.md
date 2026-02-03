# 0254 — UnknownTypeChecker never visits struct-body methods, impl methods, global initializers, or default values

> **RESOLVED (2026-07-10).** The unknown-type pass now visits struct and impl methods, module initializers, struct field defaults, and parameter defaults, preserving enclosing generic parameters while it walks.

## Symptom

One-line: the unknown-type walk (`UnknownTypeChecker.run`,
src/ir/semantic_diagnostics.zig) dispatches only top-level
`fn_decl`/`struct_decl` FIELD TYPES — five whole position classes are
never checked, so unknown types there (annotations AND `NoSuch.{}`
literal heads alike) compile silently:

1. **Struct-body method bodies** (`Thing :: struct { poke :: (self) {...} }`)
   — the project's canonical idiom; `z := BadInMethod.{};` and
   `x : NoSuchAnnot = ---;` both silent (run(): lines ~94-103).
2. **`impl ... for ...` method bodies** — same (.impl_block only feeds
   checkBindingNames, ~240-248).
3. **Module-scope initializers** — `g := BadGlobal.{a=1};` and
   `G :: BadGlobalConst.{a=1};` silent (no arm for global var_decl /
   value const_decl).
4. **Struct field DEFAULT VALUES** — `f: Inner = BadFieldDef.{a=1}`
   silent (checkStructFieldTypes walks field_types only, ~549).
5. **Param default values** — `(x: Real = BadDefParam.{a=1})` escapes
   to a raw LLVM verifier abort (the stub reaching codegen) instead of
   a diagnostic (checkScope checks p.type_expr, never p.default_expr,
   ~590-599).

All pre-existing-by-construction (the issue-0220 fix added the literal-
head check to walkBodyTypes; these positions never REACH walkBodyTypes).

## Reproduction

Each shape above is a 5-line probe; the five are listed with observed
behavior in the issue-0220 fix review (2026-07-04). Primary:

```sx
#import "modules/std.sx";
Thing :: struct {
    a: i64 = 0;
    poke :: (self: *Thing) -> i64 {
        z := BadInMethod.{};   // silent — expected: unknown type
        _ := z;
        return self.a;
    }
}
main :: () { t := Thing.{}; _ := t.poke(); }
```

## Investigation prompt

Extend `UnknownTypeChecker.run`'s dispatch: struct-body method decls
and impl-block method decls route into the same checkScope/walkBodyTypes
the top-level fns get (F1/F2 likely share one dispatch arm); module-
scope var/const initializer expressions get a walkBodyTypes-equivalent
pass; checkStructFieldTypes additionally walks field_defaults; checkScope
walks p.default_expr. Watch false positives: Self inside struct
methods, `$T` params in generic struct methods, forward refs (the
checker's `declared` set should already cover — probe), and the
harvestScopeDecls over-collection tradeoff (keep parity with fn bodies).
Verify: all five probes diagnose; the 0220 false-positive matrix stays
clean (its review lists it); corpus green — expect possible NEW
diagnoses in library/ or examples/ if any latent unknown types exist
(fix them or report, do not weaken the checker); diagnostics regression
example covering the five shapes.

Found by the adversarial review of the issue-0220 fix (2026-07-04).
