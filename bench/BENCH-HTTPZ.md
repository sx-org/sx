# BENCH-HTTPZ — std/http server benchmark record

Methodology: `bash bench/run.sh` (ApacheBench, 50,000 requests @
concurrency 50, 1,000-request warmup, loopback). Three sx scenarios
(inline plain-close, inline keep-alive, pool(4) keep-alive) plus the
naive `bench/http-server.zig` baseline (ReleaseFast, thread-per-conn
blocking). Numbers are requests/second (mean) — comparable ONLY within
one host/session; re-baseline before drawing deltas. **Never bench
while another compiler build runs on the machine** — a concurrent
`zig build` depresses a reading by up to 30%.

## 2026-07-02 — perf pass, Apple M5 Max, macOS 25.4.0

| scenario | baseline | + TCP_NODELAY | + O(1) slot/deadline | + single-pass serialization | final |
|---|---|---|---|---|---|
| sx inline — plain (close/req) | 39,951 | 37,548 | 40,089 | 39,503 | 38,118 |
| sx inline — keep-alive | 157,355 | 207,182 | 211,366 | 216,699 | **213,993 (+36%)** |
| sx pool(4) — keep-alive | 125,521 | 120,450 | 126,790 | 124,494 | 123,191 |
| zig baseline — keep-alive | 39,029 | 37,170 | 38,385 | 37,848 | 40,440 |

Reading the table:
- **Inline keep-alive +36%** comes from TCP_NODELAY — Nagle and
  delayed-ACK cliffs on request/response traffic. O(1) slot/deadline
  structures and single-pass serialization (zero per-response
  allocations inline) add a few percent each at this small `max_conn`;
  their structural value is that tick cost does not scale with
  `max_conn` and the serializer does not scale with header-piece
  count.
- Plain-close and pool numbers move within the ambient ±5% band — the
  zig baseline itself swings 37.2k–40.4k across runs, which bounds the
  noise floor. Memmove compaction is invisible here by construction:
  `ab` never pipelines, so the compactions do not run.
- The spread on this host is inline ≈ 1.7× pool for a trivial handler:
  the pool pays one hand-off plus a completion drain per request.

## 2026-07-02 — streaming request-body reader, same host

This change restructures try_serve_one (hoisted CL parse + smuggling checks, a
per-request `streaming` bool, canon_path extraction) and adds no work to
the accumulate path. Measured: inline plain 37,982 / inline keep-alive
**218,213** / pool(4) 126,735 / zig baseline 37,668 rps — all within the
ambient band of the perf-pass finals (keep-alive +2%).

## 2026-07-02 — producers off the loop thread, same host

Pool-mode STREAM producers run on workers; fixed-body pool responses go
through queue_completion. Measured: inline plain 37,865 / inline
keep-alive **217,828** / pool(4) 125,766 / zig baseline 36,183 rps — all
within the ambient band.

## 2026-07-02 — fiber handler model, same host

The fiber model adds per-tick `cfg.fibers != null` checks and dispatch
branches; fiber mode itself is opt-in. Measured (non-fiber scenarios):
inline plain 38,695 / inline keep-alive **218,253** / pool(4) 129,323 /
zig baseline 37,834 rps — all within the ambient band.
