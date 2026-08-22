# Resolver-target corpus

Goldens that encode the **target** resolver behavior for cases the current
name-selector gets wrong: it silently resolves a global last-wins author,
under-diagnoses, or picks the wrong author. The selector is not a valid oracle for
them, so they are not baseline-green and do not belong in the baseline corpus.

- **Why separate:** the assert-only mirror proves `resolver == name-selector` over
  the baseline-green corpus. Asserting that over these cases would require the
  resolver to reproduce the selector's bug. They live here with no active
  `examples/<category>/expected/` marker, so `zig build test`'s corpus runner does
  not run them.
- **Never silently dropped:** every case is enumerated in `manifest.md`, its target
  golden is recorded in `expected/`, and `run_resolver_target.sh` asserts each case
  currently FAILS to match its target (xfail). A case that MATCHES is flagged
  `LEAKED`: it is baseline-green and moves to `examples/<category>/expected/`,
  never left here.

## Layout

```
manifest.md                 enumerated list of all 9 cases (class / current / target / note)
expected/<name>.exit        target exit
expected/<name>.stdout      target stdout (08xx only)
expected/<name>.stderr      target stderr (08xx only)
expected/e6br5-*.target.md  the nested-pack case's target, stated as a spec
cases/e6br5-*.sx + dir/     the nested-pack reproducer (self-contained)
run_resolver_target.sh      xfail runner (NOT part of the baseline gate)
```

The 08xx **source trees** live under `examples/` so their `@import` paths resolve
exactly as their baseline-green siblings do, but carry **no**
`examples/<category>/expected/` marker, so they are inert to the corpus runner. Only
their goldens live here. The nested-pack reproducer lives entirely under `cases/`;
`modules/std.sx` resolves for it via the `library/` search path.

## Run

```
zig build                                 # build the compiler first
bash tests/resolver-target/run_resolver_target.sh
```

All 9 cases print `xfail`, `0 leaked`, exit 0.
