# 0285 — http client pool: redial after server-side eviction races (~8% flake)

## ✅ RESOLVED

**Root cause.** `recv_on` classified the two ways a stale keep-alive conn reports
itself into two different classes:

```sx
n := conn_read_step(c, @buf[total], cap - total);
if n < 0 { raise error.Recv; }            // ECONNRESET landed here → NOT retryable
if n == 0 {
    if total == 0 { raise error.Closed; } // clean EOF → retryable
```

`ClientPool.hop` only retries `error.Closed` (plus a send fault). Both outcomes
mean the identical thing — the peer had already closed, the request never
executed — and **which one the kernel reports is a race**: the request we write
into the dead conn provokes an RST, and that RST discards the FIN's queued EOF.
Win the race and it is a clean 0 (`Closed`, redial, pass); lose it and it is
ECONNRESET (`Recv`, no redial, `FAIL: case rc=98`).

**Fix.** `conn_read_step` reports a reset distinctly (`READ_RESET`) instead of
folding it into a generic `-1`, and `recv_on` raises `Closed` for a reset *before
any response byte* — the same "never executed" fact, so the pool's retry no
longer depends on timing. Once a byte has arrived the response is in flight and a
reset stays a genuine `Recv` failure. `socket.is_conn_reset` keeps the errno
detail in socket.sx, alongside `is_wouldblock`.

**Evidence.** Instrumenting the new branch showed it firing on **2 of 20** runs of
1706 (~10%) — matching the observed ~8% failure rate — with 0 failures. 30/30
clean afterwards, against ~2-4 expected failures pre-fix.

**Regression test.** `examples/http/1707-http-client-reset-is-stale-keepalive.sx`
pins the classification *deterministically* rather than statistically: closing a
socket with unread data in its receive queue sends RST instead of FIN (POSIX), so
the test connects, sends a request the server never reads, closes the server side,
and asserts `recv_on` raises `Closed`. It fails on the pre-fix tree with
`reset classified as Recv, not Closed`. Single-threaded, no sleep-based race.

## Symptom

`examples/http/1706-http-client-fetch.sx` fails intermittently — roughly 1 run in
8-12 — with:

```
FAIL: case rc=98
```

Case 98 is the pool's redial-after-eviction assertion
(`examples/http/1706-http-client-fetch.sx:191`):

```sx
// let the server evict the idle pooled conn (keepalive 1200ms)...
sleep_ms(2000);
// ...then the pool must transparently redial.
rp3, ep3 := pool.fetch("GET", "http://127.0.0.1:19027/hello", "", @buf[0], 8192);
if ep3 { pool.close(); return teardown(98, ...); }
```

The contract under test: once the server has evicted an idle keep-alive
connection, the next `pool.fetch` must notice the dead conn and **transparently
redial**. Most of the time it does. Sometimes it surfaces the error to the caller
instead.

## Reproduction

```sh
zig build
for i in $(seq 1 12); do
    ./zig-out/bin/sx run examples/http/1706-http-client-fetch.sx 2>&1 | head -1
done
```

Observed: 1/12 and 1/6 in two separate batches; every other run prints the
expected `fetch ok: …` line. It reproduces standalone — no parallel load needed —
so it is not a timeout or a port conflict:

- The ports are unique per example (1706 owns 19027-19029; no other example binds
  them), so it is not a cross-example collision.
- `library/modules/std/http/server.sx:1427` already sets `SO_REUSEADDR`, so it is
  not a TIME_WAIT rebind failure.
- It fails on the *fetch*, not the bind.

## Diagnosis as first filed (superseded by the banner)

The test sleeps 2000ms against a 1200ms server keepalive, so the eviction has
~800ms of slack — the sleep was never the tight part. The race is between the
server closing the idle conn and the pool deciding whether its cached conn is
still usable.

The pool logic turned out to be correct; the misclassification was one level
down, in how `recv_on` reported the dead conn. See the banner.

## Impact

- **CI/flake:** `zig build test` runs the whole corpus, so the suite is not
  reliably green — ~8% of full runs fail on this one example.
- **Product:** if the redial genuinely is racy, every consumer of the client pool
  can see a spurious error after an idle period, which is precisely the case
  pooling exists to hide.

## Notes

Found while stress-testing the baseline ahead of the Odin port. Distinct from the
corpus-timeout flake fixed in `bee52a7c` — that one was `sx run` exceeding the
10s cap because compilation ate the budget. This one is a genuine race inside the
client pool and survives any timeout.

## Status

RESOLVED — see the banner above.
