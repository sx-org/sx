# Resolver-target corpus (Fork C)

The second of the two Fork C resolver-acceptance corpora. See the full contract in
`../../docs/fork-c/S0.2-e6b-disposition-and-two-corpus-partition.md`.

- **What it is:** harvested E6b semantics goldens (+ the re-filed E6BR-5 regression)
  that encode the **TARGET** behavior of the Fork C resolver for cases where the
  **old name-selector is known-wrong on `wt-stdlib-base`** (E6b unmerged) — it
  silently resolves a global last-wins author / under-diagnoses / picks the wrong
  author. On this base the old selector is **not a valid oracle**, so these are NOT
  baseline-green.
- **Why separate:** the S2 assert-only mirror proves `resolver == old-selector` over
  the **baseline-green corpus ONLY**. Asserting that over these cases would force the
  new resolver to reproduce the old bug. So they live here, inactive, with NO active
  `examples/<category>/expected/` marker — `zig build test`'s corpus runner does not run them.
- **Never silently dropped:** every case is enumerated in `manifest.md`, its TARGET
  golden is recorded in `expected/`, and `run_resolver_target.sh` asserts each case
  currently FAILS to match its target (xfail). If any case unexpectedly MATCHES on
  the base, the runner flags it `LEAKED` — it is actually baseline-green and must be
  re-classified (moved to `examples/<category>/expected/`), never left here.
- **Flip at S3.9:** the Fork C resolver makes these pass; each golden moves to
  `examples/<category>/expected/<name>.{exit,stdout,stderr}` and this harness goes empty.

## Layout

```
manifest.md                 enumerated list of all 10 cases (class / base-now / target / note)
expected/<name>.exit        TARGET exit (08xx: exact E6b bytes; e6br5: spec)
expected/<name>.stdout      TARGET stdout (08xx only — exact E6b bytes)
expected/<name>.stderr      TARGET stderr (08xx only — exact E6b bytes)
expected/e6br5-*.target.md  E6BR-5 spec target (exact bytes finalized at S3.9)
cases/e6br5-*.sx + dir/     E6BR-5 authored reproducer (self-contained)
run_resolver_target.sh      xfail runner (NOT part of the baseline gate)
```

The 08xx **source trees** live under `examples/` (harvested as authored, so their
`#import` paths resolve exactly as their baseline-green siblings do) but carry **no**
`examples/<category>/expected/` marker, so they are inert to the corpus runner. Only their
goldens live here. The E6BR-5 reproducer lives entirely under `cases/` (it is
self-contained — `modules/std.sx` resolves via the `library/` search path).

## Run

```
zig build                                 # build the compiler first
bash tests/resolver-target/run_resolver_target.sh
```

Expected today (S0): all 10 cases print `xfail`, `0 leaked`, exit 0.
