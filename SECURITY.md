# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities privately to **alex@swipelab.co** with:

- a description of the issue and its impact,
- a minimal reproduction (sx source + the command that triggers it), and
- the affected component (compiler, a stdlib module such as `std/http`, etc.).

Please do **not** open a public issue for a security report. We aim to
acknowledge within a few business days and to coordinate a fix and disclosure
timeline with you. There is no bug-bounty program; credit is given in the fix
commit / release notes unless you prefer otherwise.

---

## `std/http` server — security posture

`std/http` is a low-level HTTP/1.1 server intended to provide the guarantees
needed to run a long-lived service without each application rediscovering the
same failure modes. It is **not** a web framework, and it makes deliberate
trade-offs you should understand before exposing it.

### TLS / deployment

`std/http` supports **native TLS** (`Config.tls` over vendored mbedTLS 1.2/1.3 —
see `docs/http-server.md` *Native TLS (HTTPS)*) **or** plaintext behind a
TLS-terminating reverse proxy. Either way, **a hardened reverse proxy (nginx,
Caddy, HAProxy, a cloud load balancer) is still recommended for any
internet-facing service**: it adds defense-in-depth — connection limits, request
buffering, and its own battle-tested parser in front of ours — independent of
where TLS terminates. If you expose the server directly, enable native TLS;
running plaintext on the open internet is **not** recommended.

Note on TLS scope: the provider defaults to TLS 1.2+ (preferring 1.3) and
supports ALPN (`set_alpn`), SNI / multi-cert (`add_sni_cert_files`), and
client-cert auth (`require_client_cert_files`). An explicit min-version pin is
not yet implemented (needs a small C shim) — front with a proxy if you must
REQUIRE 1.3.

### What the server defends against (implemented + tested)

Request parsing is hardened against the common malformed/malicious inputs
(corpus: `examples/http/1669-http-parser-hardening`, `…1675-http-request-body`):

- **Request smuggling** — `Content-Length` + `Transfer-Encoding` together → 400;
  duplicate `Content-Length` → 400; duplicate `Transfer-Encoding` → 400;
  whitespace before a header field-name's colon (RFC 7230 §3.2.4) → 400;
  a non-`chunked` `Transfer-Encoding` is never treated as bodyless (→ 501).
- **Integer overflow** — `Content-Length` and chunk-size parsing reject values
  that would wrap i64 or exceed the configured caps, before they can be used to
  under-allocate or over-read.
- **Resource exhaustion** — per-request header-count and header-line-size caps
  (→ 431); a maximum request-body size with **early** rejection (→ 413) that
  refuses an oversized body *before* buffering it (including a chunked body that
  grows past the limit mid-stream); a per-connection request cap; a maximum
  concurrent-connection cap (excess → shed).
- **Slow clients** — request-delivery and keep-alive idle deadlines evict a
  connection that stalls; the loop never blocks on a single peer.
- **Control-character / request-splitting** — control bytes in the method or
  path → 400; only `HTTP/1.0` and `HTTP/1.1` are accepted.
- **Chunked decoding** is parsed strictly: bad hex, junk after the size, missing
  CRLFs → 400; extensions are ignored; trailers are consumed, never merged into
  the request headers.
- **Memory safety** — start/stop/serve cycles are leak-free under an
  allocation-counting gate (`examples/http/1670`), including pooled mode and
  connections closed mid-stream or mid-handler.
- **Backpressure** — a full handler pool sheds with 503 rather than growing
  unboundedly; streamed responses are bounded-memory.

### Known limitations (by design, at this stage)

- **No explicit TLS min-version pin.** Native TLS (mbedTLS 1.2/1.3,
  `Config.tls`) supports ALPN, SNI / multi-cert, and client-cert auth, and the
  default already floors at TLS 1.2 preferring 1.3 — but REQUIRING 1.3 needs a
  small C shim (the mbedTLS setter is `static inline`) and is not implemented;
  front with a proxy if you need that pin.
- **Inline handler mode has no hard timeout.** With `thread_pool_count == 0` the
  handler runs on the event-loop thread and cannot be preempted — a hung inline
  handler hangs the whole server. The request deadline is exposed as
  `Request.deadline_ms` for *cooperative* self-limiting only. **Run untrusted or
  potentially-slow handlers in pool mode** (`thread_pool_count > 0`), where the
  loop enforces a hard per-request deadline (504) and stays responsive.
- **A hung pooled handler costs one worker.** Pool mode 504s the client and frees
  the connection, but there is no thread cancellation (cancelling a thread
  mid-allocation is unsafe), so a never-returning handler permanently consumes
  the one worker that ran it. Size the pool accordingly; a watchdog/replacement
  strategy is out of scope.
- **Not audited for direct internet exposure.** The hardening above is tested,
  not formally audited. Treat the server as suitable for a trusted network or
  behind a proxy.
- **The handler is responsible for its own output safety** — header/response
  injection via handler-supplied header values, body content types, etc. are the
  application's concern.

### Reducing exposure

- Enable native TLS (`Config.tls`) or put it behind a reverse proxy that
  terminates TLS.
- Use pool mode for any handler that can be slow, and set `handler_timeout_ms`.
- Set `max_body`, `max_conn`, `max_headers`, `max_header_line`,
  `request_count`, and the delivery/keep-alive timeouts to match your workload.
- Install the `on_event` hook to log faults and watch the `Server.stats()`
  counters (rejected/timeouts/4xx/5xx) for abuse.
