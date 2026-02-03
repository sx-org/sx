# Fuzzing std.http (PLAN-HTTPZ S3)

The HTTP/1.1 request parser (`library/modules/std/http.sx` —
`try_serve_one`, the H1 hardening block, the S2 `decode_chunked`
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
  final `alloc_count != 0` fails the test.

It is **deterministic** (fixed `SEED`, no time/`Math.random`) so its
golden output is stable, and **bounded** (`ITERATIONS = 1200`, ~3s wall)
so it fits the corpus 10s/example timeout.

Run it directly:

```sh
./zig-out/bin/sx run examples/http/1677-http-fuzz-smoke.sx
```

## Longer fuzz (CI job, NOT the corpus)

The corpus runner (10s/example, no network sandbox) cannot host a
long-running fuzzer. To fuzz harder, OUTSIDE the corpus:

1. **Bump iterations / sweep seeds.** Raise `ITERATIONS` in
   `1677-http-fuzz-smoke.sx` (e.g. 200_000) and/or run it repeatedly with
   different `SEED` values. Each `SEED` is a fresh deterministic stream;
   a crash is reproducible by pinning the failing `SEED` + iteration
   index (the example prints both on failure). This is a drop-in CI job —
   build the example with a larger constant and run it under a watchdog.

2. **A future libFuzzer / AFL target.** The strongest harness feeds raw
   bytes straight into a parser entry point (`decode_chunked`,
   `try_serve_one`) with NO socket, so the fuzzer drives the state machine
   directly at millions of execs/sec. sx has **no libFuzzer integration
   today**, so this lives as a separate CI job (a small C/Zig driver that
   dlopen's an `extern "c"`-exported sx parser shim, or a native rewrite
   of the decode loop), never in `examples/`. When built, wire it into CI
   alongside the load/stress suite (S4).

**If any fuzz run finds a crash / hang / leak, that is a REAL parser
bug.** The failing `SEED` + iteration + the exact triggering bytes are
the repro. Fix the parser — never weaken the assertions.
