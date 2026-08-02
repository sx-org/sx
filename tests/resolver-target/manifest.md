# Resolver-target corpus — enumerated manifest

**Status:** xfail. **Not part of the baseline gate** — `zig build test`'s corpus
runner does not run these, because they carry no active
`examples/<category>/expected/` marker. `run_resolver_target.sh` asserts every case
below FAILS to match its target, so the set is never silently dropped.

These cases encode behavior the current name-selector gets wrong: it silently
resolves a global last-wins author (exit 0) where the target is a loud ambiguity
(exit 1), fails to resolve an own-author where the target is success (exit 0), or
resolves the wrong author (right exit, wrong bytes). The selector is not a valid
oracle for them, so they are not baseline-green and the assert-only mirror must
never assert `resolver == name-selector` over this corpus.

`e6br5-…` states its target as a spec (`*.target.md`) rather than as bytes; the
resolver produces its exact bytes.

## Failure classes

- **SILENT-RESOLVE (ambiguous):** exits 0, silently picking last-wins, where the
  target is exit 1 (loud ambiguity). The resolver must error.
- **UNDER-DIAGNOSE (ambiguous):** exits 1 but emits FEWER ambiguity diagnostics than
  the target: it catches one site and silently resolves the rest.
- **WRONG-AUTHOR (own-wins):** exits 0 but resolves the wrong author → garbage
  runtime bytes against the target stdout.
- **OWN-WINS-FAILS (own-wins):** exits 1, failing to resolve the own-author, where
  the target is exit 0 and the program runs.

## Manifest (10 cases)

| # | case (source tree under `examples/<category>/<name>.sx`) | surface | class | current | target | note |
|---|---|---|---|---|---|---|
| 1 | `0811-modules-same-name-error-set-ambiguous` | bare error-set ref (size_of / annotation / type-as-value / match-arm / `!E` channel) | SILENT-RESOLVE | exit 0, silent | exit 1, **5** ambiguity diags | the `type_bridge.resolveInlineErrorSet` `findByName` short-circuit interns one global last-wins `IoErr` and exits 0 |
| 2 | `0813-modules-same-name-error-set-lambda-own-wins` | own error-set in lambda return channel | OWN-WINS-FAILS | exit 1 | exit 0 | the lambda `-> !E` own-author does not resolve |
| 3 | `0814-modules-same-name-error-set-lambda-ambiguous` | ambiguous error-set in lambda return channel | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | the `!E` channel resolves silently |
| 4 | `0815-route-all-new-surfaces-ambiguous` | `*Box` / `union{Box}` / `enum{Box}` / inline-union ambiguous | UNDER-DIAGNOSE | exit 1, **<5** diags | exit 1, **5** diags | one site is caught, the rest resolve silently |
| 5 | `0821-protocols-same-name-method-ambiguous` | ambiguous protocol-method | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | the protocol head resolves silently |
| 6 | `0825-protocols-same-name-method-wrapped-ambiguous` | wrapped protocol-method, ambiguous | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | — |
| 7 | `0826-protocols-param-impl-source-wrapped-own-wins` | wrapped param-impl source, own wins | WRONG-AUTHOR | exit 0, `v=<garbage>` | exit 0, `v=7 dep=9` | the wrong author resolves → garbage field value |
| 8 | `0827-protocols-param-impl-source-wrapped-ambiguous` | wrapped param-impl source, ambiguous | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | — |
| 9 | `0829-packs-param-impl-mixed-pack-source-ambiguous` | mixed pack-closure param-impl, concrete `*Box` prefix ambiguous | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | the `*Box` collision falls to the no-author `resolveTemplateSignatureType` wrapper (global last-wins) and registers silently |
| 10 | `e6br5-nested-pack-source-ambiguous` (tree under `tests/resolver-target/cases/`) | NESTED concrete `*Box` leaf inside `Closure(Closure(*Box,..)->.., ..)->..` | SILENT-RESOLVE | exit 0, silent | exit 1, ≥1 diag (spec) | `walkConcreteSigArgs` skips nested args; the whole-AST resolver subsumes the hole |
