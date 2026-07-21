# 0336 — `--cache` reuses object files across compiler rebuilds (stale codegen)

> **RESOLVED (2026-07-21).** `computeCacheKey` now seeds from a
> lazily-computed content hash of the running compiler executable (null →
> cache disabled for the process: slower, never stale); cache writes stage
> through a pid-unique temp inside `.sx-cache/` and land by atomic rename.
> The corpus runner passes `--cache` on JIT runs: warm suite ~50s vs ~2:20
> cold (a representative http example drops 6.4s → 0.19s). Regression: the
> corpus unit test "object cache: second identical run hits, source edit
> invalidates" (pid-unique fixture; asserts codegen → cache → codegen via
> the `--time` stage table). Known conservative behavior: test-file edits
> relink the sx binary (the barrel imports *.test.zig into the exe module)
> and therefore cold the suite — decoupling tests from the exe module is a
> follow-up improvement, not a correctness issue.

> **Symptom.** The JIT object cache key (`computeCacheKey`, src/main.zig)
> hashes the source, import sources, and target config — but NOT the
> compiler itself. An object cached by an older `sx` build is silently
> reused by a newer one whose codegen differs, executing stale machine
> code with no diagnostic. The cache staging path is also a fixed
> `.sx-cache-tmp` in cwd, so two concurrent `--cache` runs corrupt each
> other's staged object.

## Reproduction

```sh
./zig-out/bin/sx run some.sx --cache        # caches object under key K
# ...modify the compiler's codegen, zig build...
./zig-out/bin/sx run some.sx --cache        # SAME key K → stale object runs
```

`.sx-cache/` in this repo currently holds objects from older compiler
builds that would satisfy today's keys.

## Expected

The cache key must incorporate the compiler's own identity (content hash
of the running executable) so a rebuilt compiler never satisfies an old
key. Concurrent cache writes must stage through a unique temp path and
land atomically.

## Impact

Correctness (silent stale codegen) for any `--cache` user; blocks
enabling the cache for the corpus runner (the suite-wall-time lever:
warm-suite runs currently pay full codegen for all ~1165 examples).

## Fix (this session, filed-then-fixed per session authorization)

- Mix a lazily-computed self-exe content hash into `computeCacheKey`.
- Stage cache writes through a pid-unique temp + rename.
- Corpus runner passes `--cache` on JIT runs; unit regression drives a
  fixture twice and asserts run 1 records `codegen` and run 2 records
  `cache` in the `--time` stage table, then invalidates by source edit.
