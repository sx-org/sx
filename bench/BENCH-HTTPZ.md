# BENCH-HTTPZ — std/http server benchmark record

Methodology: `bash bench/run.sh` (ApacheBench, 50,000 requests @
concurrency 50, 1,000-request warmup, loopback). Three sx scenarios
(inline plain-close, inline keep-alive, pool(4) keep-alive) plus the
naive `bench/http-server.zig` baseline (ReleaseFast, thread-per-conn
blocking). Numbers are requests/second (mean) — comparable ONLY within
one host/session; re-baseline before drawing deltas. **Never bench
while another compiler build runs on the machine** — a concurrent
`zig build` (e.g. a worktree worker) depressed one Q2 reading by 30%.

## 2026-07-02 — Phase Q2 (perf pass), Apple M5 Max, macOS 25.4.0

| scenario | Q2 baseline | after Q2.1 | after Q2.2 | after Q2.3 | after Q2.5 (final) |
|---|---|---|---|---|---|
| sx inline — plain (close/req) | 39,951 | 37,548 | 40,089 | 39,503 | 38,118 |
| sx inline — keep-alive | 157,355 | 207,182 | 211,366 | 216,699 | **213,993 (+36%)** |
| sx pool(4) — keep-alive | 125,521 | 120,450 | 126,790 | 124,494 | 123,191 |
| zig baseline — keep-alive | 39,029 | 37,170 | 38,385 | 37,848 | 40,440 |

Reading the table:
- **Inline keep-alive +36%** is the phase's real win, and it landed at
  Q2.1 (TCP_NODELAY — Nagle + delayed-ACK cliffs on request/response
  traffic). Q2.2 (O(1) slot/deadline structures) and Q2.3 (single-pass
  serialization, zero per-response allocations inline) add a few
  percent each at this small `max_conn`; their structural value is
  that tick cost no longer scales with `max_conn` and the serializer
  no longer scales with header-piece count.
- Plain-close and pool numbers move within the ambient ±5% band — the
  UNCHANGED zig baseline itself swings 37.2k–40.4k across runs, which
  bounds the noise floor. Q2.4 (memmove compaction) is invisible here
  by construction: `ab` never pipelines, so the compactions don't run.
- The historical "~6x faster inline for fast handlers" note in
  server.sx's Config predates this record; the current spread on this
  host is inline ≈ 1.7× pool for a trivial handler (the pool pays one
  hand-off + completion drain per request).

## 2026-07-02 — Q3.1 sanity (streaming request-body reader), same host

Q3.1 restructures try_serve_one (hoisted CL parse + smuggling checks, a
per-request `streaming` bool, canon_path extraction) but adds no work to
the accumulate path. Post-change: inline plain 37,982 / inline keep-alive
**218,213** / pool(4) 126,735 / zig baseline 37,668 rps — all within the
ambient band of the Q2 finals (keep-alive +2%). No regression.

## 2026-07-02 — Q3.2 sanity (producers off the loop thread), same host

Q3.2 reroutes pool-mode STREAM producers onto workers (fixed-body pool
responses only gain the queue_completion refactor). Post-change: inline
plain 37,865 / inline keep-alive **217,828** / pool(4) 125,766 / zig
baseline 36,183 rps — all within the ambient band. No regression.

## 2026-07-02 — Q3.3 sanity (fiber handler model), same host

Q3.3 adds per-tick `cfg.fibers != null` checks and dispatch branches;
fiber mode itself is opt-in. Post-change (non-fiber scenarios): inline
plain 38,695 / inline keep-alive **218,253** / pool(4) 129,323 / zig
baseline 37,834 rps — all within the ambient band. No regression.

Earlier baselines (different host states, not comparable): none
recorded — this file starts with Phase Q2.
