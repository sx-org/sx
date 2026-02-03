# Resolver-target corpus — enumerated manifest

**Status:** INACTIVE / xfail from S0 through S3.8. **Flips to active + green at S3.9.**
**Not part of the baseline gate** (`zig build test`'s corpus runner does not run
these — no active `examples/<category>/expected/` marker). The harness runner
`run_resolver_target.sh` asserts every case below currently FAILS to match its
TARGET, so the set is never silently dropped between S0 and S3.9.

## Reclassified out of this set

Eight cases were harvested as OWN-WINS-FAILS (base `exit 1`, target `exit 0`) but
the base now matches their E6b target byte-for-byte — the resolver reaches the
own-author without the Fork C work. `run_resolver_target.sh` reported each as
LEAKED, which is exactly the reclassification signal it exists to raise; their
goldens moved to `examples/<category>/expected/` and they are now baseline-green:

`0812` `0816` `0817` `0818` `0819` `0820` `0822` `0824`

All eight are own-wins surfaces. Every remaining `-ambiguous` case still xfails:
the base still under-diagnoses or silently last-wins-resolves them, so the
diagnostic half of the E6b contract is untouched.

These cases encode **known-wrong old behavior** on `wt-stdlib-base` (E6b unmerged):
the old name-selector silently resolves a global last-wins author (exit 0) where the
TARGET is a loud ambiguity (exit 1), OR fails to resolve an own-author where the
TARGET is success (exit 0), OR resolves the wrong author (right exit, wrong bytes).
On this base the old selector is **not a valid oracle** for them — so they are NOT
baseline-green and the S2 mirror must NEVER assert `resolver == old-selector` over
this corpus (see `../../docs/fork-c/S0.2-e6b-disposition-and-two-corpus-partition.md`).

The `08xx` TARGET goldens here are the **exact bytes** the E6b branch
(`flow/stdlib/E6b @ af737b0`) produced; copied verbatim, never the transitional src.
`e6br5-…` has a spec target only (`*.target.md`) — its exact bytes are produced by
the Fork C resolver at S3.9.

## Failure classes

- **SILENT-RESOLVE (ambiguous):** base exits 0 (silently picks last-wins) where
  TARGET is exit 1 (loud ambiguity). The resolver must error.
- **UNDER-DIAGNOSE (ambiguous):** base exits 1 but emits FEWER ambiguity
  diagnostics than the TARGET (catches one site, silently resolves the rest).
- **WRONG-AUTHOR (own-wins):** base exits 0 but resolves the wrong author →
  garbage runtime bytes vs the TARGET stdout.
- **OWN-WINS-FAILS (own-wins):** base exits 1 (fails to resolve the own-author)
  where TARGET is exit 0 (own-author wins and the program runs).

## Manifest (10 cases)

| # | case (source tree under `examples/<category>/<name>.sx`) | surface | class | base-now | target | note |
|---|---|---|---|---|---|---|
| 1 | `0811-modules-same-name-error-set-ambiguous` | bare error-set ref (size_of / annotation / type-as-value / match-arm / `!E` channel) | SILENT-RESOLVE | exit 0, silent | exit 1, **5** ambiguity diags | **old selector is wrong here on the E6b-unmerged base** — pre-E6b the `type_bridge.resolveInlineErrorSet` `findByName` short-circuit interned one global last-wins `IoErr` and exited 0 |
| 2 | `0813-modules-same-name-error-set-lambda-own-wins` | own error-set in lambda return channel | OWN-WINS-FAILS | exit 1 | exit 0 | lambda `-> !E` own-author not resolved by old path |
| 3 | `0814-modules-same-name-error-set-lambda-ambiguous` | ambiguous error-set in lambda return channel | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | old path silently resolves the `!E` channel |
| 4 | `0815-route-all-new-surfaces-ambiguous` | `*Box` / `union{Box}` / `enum{Box}` / inline-union ambiguous | UNDER-DIAGNOSE | exit 1, **<5** diags | exit 1, **5** diags | old path catches one site, silently resolves the rest |
| 5 | `0821-protocols-same-name-method-ambiguous` | ambiguous protocol-method | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | old path silently resolves the protocol head |
| 6 | `0825-protocols-same-name-method-wrapped-ambiguous` | wrapped protocol-method, ambiguous | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | — |
| 7 | `0826-protocols-param-impl-source-wrapped-own-wins` | wrapped param-impl source, own wins | WRONG-AUTHOR | exit 0, `v=<garbage>` | exit 0, `v=7 dep=9` | base resolves the wrong author → garbage field value |
| 8 | `0827-protocols-param-impl-source-wrapped-ambiguous` | wrapped param-impl source, ambiguous | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | — |
| 9 | `0829-packs-param-impl-mixed-pack-source-ambiguous` | mixed pack-closure param-impl, concrete `*Box` prefix ambiguous | SILENT-RESOLVE | exit 0, silent | exit 1, 1 diag | **old selector is wrong here on the E6b-unmerged base** — pre-E6BR-4 the `*Box` collision fell to the no-author `resolveTemplateSignatureType` wrapper (global last-wins) and registered silently |
| 10 | `e6br5-nested-pack-source-ambiguous` (tree under `tests/resolver-target/cases/`) | NESTED concrete `*Box` leaf inside `Closure(Closure(*Box,..)->.., ..)->..` | SILENT-RESOLVE | exit 0, silent | exit 1, ≥1 diag (spec, S3.9) | **re-filed E6BR-5** — the open nested-pattern hole that paused E6b (`walkConcreteSigArgs` lower.zig:14686 skipped nested args); subsumed by the whole-AST resolver, **NOT an E6b attempt-6** |

## Provenance

- Cases 1–9: source trees harvested from `flow/stdlib/E6b @ af737b0` into
  `examples/<category>/<name>.sx` (+ sibling module dir), goldens copied verbatim from
  `flow/stdlib/E6b:examples/expected/<name>.*` into `expected/<name>.*` here. The
  transitional E6b src was NOT harvested.
- Case 10 (E6BR-5): authored reproducer (no E6b tree ever existed); lives entirely
  under `cases/` with a spec target in `expected/…target.md`.

## Flip at S3.9

Each row maps to an active `examples/<category>/expected/<name>.{exit,stdout,stderr}`
marker when it flips (the `08xx` trees are already in `examples/<category>/`; only
the goldens move from `expected/` here to that category's `expected/`). After S3.9 this harness is empty and
every entry above is an active, green baseline test validated against its TARGET.
