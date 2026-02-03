# Fork C — setup contract (S0)

Zero-legacy name-resolution redesign (S0→S6), replacing E6c–K. This directory is the
**committed S0 contract** the remaining 26 steps (S1→S6) execute against. It is pure
setup/documentation — **S0 introduces no production code change and no behavior
change**; single-author output is byte-identical to `wt-stdlib-base` by construction.

**Authority:** `runs/stdlib/design/fork-c-deepdive/reconciled.md` (§5 by-construction
audit, §6 staged roadmap + deletion lists, §8 fold-in) and
`runs/stdlib/design/fork-c-plan/planspec-r3.json` (the S0.1/S0.2/S0.3 intent +
acceptance, Adi-confirmed — they govern).

## Doc-area decision

Deliverables live under **`docs/fork-c/`**, NOT `current/fork-c/`. Reason: `current/`
is **gitignored** in this repo (`.gitignore` → `current/`), so a new `current/fork-c/`
tree would not be committed; the S0 contract must be committed. `docs/` is tracked.

## Baseline

- **Base:** `wt-stdlib-base @ 1f755284d98c6e8ebba953045c06e35d8cbe6278` (A–E6a merged).
- **E6b:** `flow/stdlib/E6b @ af737b0` — PAUSED, **unmerged**, all transitional, destined
  for S3/S6 deletion. Its semantics goldens are harvested; its src is never merged.
- **This branch:** `flow/stdlib/S0` (branched from the base). **Production/compiler
  behavior is base-equivalent** — zero `src/` changes, single-author output
  byte-identical to base by construction — but S0 HEAD is a distinct commit carrying
  the docs/examples/tests diff (it does **not** equal base).

## Contents

| file | sub-step | what |
|---|---|---|
| `S0.1-byte-baseline-and-commit-discipline.md` | S0.1 | the byte-identity reference + the zero-diff reproduction command + resolver-target exclusion + the `mirror \| consumer-cutover \| deletion` commit-classification discipline |
| `S0.2-e6b-disposition-and-two-corpus-partition.md` | S0.2 | E6b src not merged (grep-clean) + the harvested corpus partitioned baseline-green vs resolver-target + 0811/0829 placement + the E6BR-5 re-file + the mirror/flip statement |
| `S0.3-reuse-delete-ledger.md` | S0.3 | every load-bearing A–E6 artifact mapped REUSED (Fork C home) or DELETED/TRANSITIONAL (S3/S6 phase); E6c/d/e dropped, F/H/I/K absorbed/superseded |
| `../../tests/resolver-target/` | S0.2 | the listed resolver-target harness: `manifest.md` (10 cases), `expected/` TARGET goldens, the E6BR-5 reproducer under `cases/`, and `run_resolver_target.sh` (xfail runner — NOT part of the gate) |

## The two-corpus law (the one thing the next 26 steps must never conflate)

1. **BASELINE-GREEN / mirror-equivalence corpus** — tests where the old selector is
   already correct today (A–E6a merged + the 6 harvested baseline-green cases + FFI
   12xx–14xx + the LSP smoke). Stays **green and single-author byte-identical at every
   step S0→S6**, and is the S2 assert-only Debug mirror's **only** oracle.
2. **RESOLVER-TARGET corpus** — harvested goldens that encode **known-wrong old
   behavior** (silent resolve / under-diagnose / wrong author / own-wins-fails) + the
   E6BR-5 regression. Held **inactive/xfail** (listed, never silently dropped) from S0
   through S3.8, then **flips to active + green at S3.9** against its TARGET output —
   never against the old selectors (a wrong oracle for it on the E6b-unmerged base).

## Gate (this branch)

```sh
export PATH="$HOME/.zvm/bin:$PATH"
zig build && zig build test && bash tests/run_examples.sh   # exit 0 over the baseline-green corpus
```

Since S0 changes no production code, single-author output is byte-identical by
construction. The resolver-target xfail diagnostic
(`bash tests/resolver-target/run_resolver_target.sh`) is separate and not part of the
gate.
