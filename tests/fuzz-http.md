# Fuzzing std.http

The HTTP/1.1 request parser (`library/modules/std/http.sx` —
`try_serve_one`, the H1 hardening block, the `decode_chunked`
decoder) must NEVER crash, panic, abort, hang, double-free, or leak on
hostile input. It may only ever respond (400/413/431/501/504/…) or
cleanly close the connection.

## In-corpus smoke (runs on every `zig build test`)

`examples/http/1677-http-fuzz-smoke.sx` is a **bounded, deterministic,
in-process** fuzz smoke. A seeded xorshift PRNG mutates a set of valid +
known-nasty request templates and feeds each (in random-sized split
sends) to one live server driven single-thread via `Server.tick`. It
asserts, per iteration:

- **no crash / panic / hang** — a hang is caught by a bounded wall-clock
  tick budget per request,
- **plausible-response-or-clean-close** — any reply must start
  `HTTP/1.1 ` + a 3-digit status; otherwise the connection must close,
- **liveness** — a clean GET is interleaved through the noise and must
  still round-trip `200 OK`,
- **net-zero leak** — the whole run sits under a `GPA`; one server is
  reused across all iterations, so a per-request leak accumulates and the
  final `allocCount != 0` fails the test.

It is **deterministic** (fixed `SEED`, no time/`Math.random`) so its
golden output is stable, and **bounded** (`ITERATIONS = 400`) so it fits
the corpus 1s run budget.

Run it directly:

```sh
./zig-out/bin/sx run examples/http/1677-http-fuzz-smoke.sx
```

## Longer fuzz, outside the corpus

The corpus runner flags an example whose post-compile run phase exceeds
the 1s budget as `OVER` in its timing report, caps compile + run at 30s
wall-clock, and gives it no network sandbox, so it cannot host a
long-running fuzzer.
Raise `ITERATIONS` in `1677-http-fuzz-smoke.sx` and/or run it repeatedly
with different `SEED` values. Each `SEED` is a fresh deterministic
stream; a crash is reproducible by pinning the failing `SEED` +
iteration index, which the example prints on failure.

**If any fuzz run finds a crash / hang / leak, that is a REAL parser
bug.** The failing `SEED` + iteration + the exact triggering bytes are
the repro. Fix the parser — never weaken the assertions.
