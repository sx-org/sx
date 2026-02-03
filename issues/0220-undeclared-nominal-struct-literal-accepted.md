# 0220 — a struct literal naming an UNDECLARED type is silently accepted

> **RESOLVED** (2026-07-03). **Root cause:** the `UnknownTypeChecker` — the
> main-file diagnostic authority (`src/ir/semantic_diagnostics.zig`) — never
> validated a NAMED struct-literal head (`sl.struct_name`). So `NoSuchType.{…}`
> in the main file bypassed the checker and reached `resolveNominalLeaf`'s
> `.undeclared` **main-file** arm, which (by documented design) keeps the legacy
> empty-struct forward-ref stub and DEFERS the diagnostic to that very checker.
> Nothing diagnosed it; the literal compiled to a 0-field struct and dropped
> every field. The `.undeclared` main-file stub itself is correct and
> load-bearing (the `-> T` unbound-generic leaf and forward-declared struct
> refs legitimately land nearby / rely on stub-adoption); the gap was purely
> the missing checker coverage. **Fix:** in `walkBodyTypes`'s `.struct_literal`
> case, route `sl.struct_name` through `reportIfUnknownType` (and `sl.type_expr`
> through `checkTypeNodeForUnknown`), exactly mirroring the typed-array-literal
> head guard (`al.type_expr`, issues 0173–0175). `reportIfUnknownType` skips
> forward-refs, in-scope generics, value params, builtins and aliases, so only
> genuinely-undeclared names fire. `resolveNominalLeaf` was NOT changed —
> auditing its other callers (type annotations, generic args, `!E` error sets,
> namespaced `alias.X` heads) confirmed each is already covered by the checker
> or diagnoses at a non-main pinned source, so the main-file stub was the sole
> guard ONLY for the struct-literal head. **Regression test:**
> `examples/diagnostics/1219-diagnostics-undeclared-nominal-literal.sx` (both
> named-field and empty forms, exit 1). Note: sibling issue 0230 (unknown types
> in a top-level type-alias RHS, `Bad :: [3]NoSuchType;`) is a DISTINCT checker
> gap in `run` / the `const_decl` alias-RHS walk — NOT subsumed by this fix and
> still open.

> **Banner scope note (2026-07-04, from the adversarial review):** resolved
> in CHECKER-WALKED positions (top-level fn bodies incl. closures, generic
> bodies, #run-reached fns — the review's position battery). The symptom
> survives in the five position classes the UnknownTypeChecker never visits
> at all (struct-body methods, impl methods, module-scope initializers,
> field defaults, param defaults) — tracked as issue 0254 (walk-reach, not
> this fix's arm). Namespaced unknown heads diagnose but at a poor span
> (the non-main source pinning).

## Symptom

One-line: `s := NoSuchType.{ a = 1 };` where `NoSuchType` exists nowhere
compiles and runs with zero diagnostics — the undeclared nominal resolves
to an interned EMPTY-STRUCT STUB ("legacy parity" behavior), the literal's
fields are dropped, and execution proceeds on garbage-free but meaningless
data.

- Observed: compiles, runs, exit 0, no diagnostic.
- Expected: "type 'NoSuchType' is not declared / not visible" diagnostic,
  exit 1.

This is the silent-fallback pattern the project forbids: a failed nominal
lookup fabricating an empty struct type instead of diagnosing. Note the
`.ambiguous` / `.not_visible` outcomes of the same resolution DO diagnose —
only `.undeclared` falls into the stub.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
    s := NoSuchType.{ a = 1 };   // expected: compile error; observed: accepted
    _ := s;
    print("ok\n");               // prints ok, exit 0
}
```

## Investigation prompt

`resolveNominalLeaf`'s `.undeclared` arm (reached from the struct-literal
path behind `src/ir/lower/expr.zig:83`) interns an empty-struct stub for an
undeclared type name instead of diagnosing (documented as "legacy parity").
Replace the stub with a located diagnostic via
`self.diagnostics.addFmt(.err, span, ...)` + a poison/`.unresolved` return
that downstream guards already handle (the 0161/0184 guard block). Audit
the OTHER callers of `resolveNominalLeaf` (type annotations, generic args,
UFCS receivers, impl targets) — decide per call site whether `.undeclared`
was load-bearing anywhere (some parse-order/forward-ref path may rely on
the stub; if so, that caller needs a forward-resolution pass instead of a
stub). Grep for what "legacy parity" referred to before removing it.
Verification: the repro errors cleanly; `NoSuchType.{}` (empty) too; a new
examples/diagnostics/12xx pins it; full corpus green (watch forward-ref
examples in examples/types/ + examples/modules/).

Found by the adversarial review of the 0161+0184 fix (2026-07-03).
