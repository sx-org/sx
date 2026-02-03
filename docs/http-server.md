# `std/http` — running an HTTP server in production

`std/http` is a low-level HTTP/1.1 server: an event-loop core that multiplexes
the listener and every connection on one thread, with an optional handler thread
pool. It aims to survive malformed clients, slow clients, overload, and restarts
without each application rediscovering the same failure modes. It is **not** a
web framework. See [SECURITY.md](../SECURITY.md) for the security posture.

```sx
#import "modules/std.sx";

handler :: (req: *http.Request, resp: *http.Response, ctx: usize) {
    if req.path == "/healthz" { resp.body = "ok"; return; }
    resp.status = 404; resp.body = "not found";
}

main :: () -> i32 {
    s, e := http.Server.init(http.Config.{ port = 8080 }, handler, 0);
    if e { return 1; }
    s.run();          // serve until s.stop()
    s.close();
    return 0;
}
```

`Server.run()` loops until `Server.stop()` is requested, then drains and returns;
`Server.close()` frees everything. `Server.tick(max_wait_ms)` runs one bounded
loop iteration — useful for driving the server and its clients in one thread
(every `examples/http/*` test does this).

---

## Concurrency model

This is the contract you are programming against. Get it wrong and you get data
races or use-after-free; get it right and the server is simple to reason about.

### One loop thread

The event loop — accept, read, request parsing, response writing, timeout
eviction, the `Stats` counters, and the `on_event` hook — all run on a **single
thread**. Nothing in that path needs locking because nothing else touches it.

### Handler execution: inline, pool, or fibers

Three dispatch models, chosen by `Config`:

- **Inline** (default): handlers run on the loop thread, run-to-completion.
- **Pool** (`thread_pool_count > 0`): handlers run on worker threads; slow
  handlers stop stalling the loop; hard `handler_timeout_ms` enforcement.
- **Fibers** (`Config.fibers`, Q3.3): handlers run as M:1 fibers ON the
  loop thread. A fiber handler may block-style `req.read_body` — the fiber
  suspends and the loop wakes it when body bytes arrive — so
  `stream_request_body` works WITHOUT a pool, while everything stays
  single-threaded (no locks in handler code, no thread-safe-allocator
  requirement). COOPERATIVE: a compute-bound handler stalls the whole
  server exactly like inline mode (no preemption; `handler_timeout_ms`
  stays advisory). Setup:

  ```sx
  fs :: #import "modules/std/http/fiber_sched.sx";   // opt-in: compiles the fiber runtime
  …
  runner := fs.SchedRunner.init();                   // must outlive the Server
  cfg : http.Config = .{ …, stream_request_body = true, fibers = xx runner };
  srv, e := http.Server.init(cfg, handler, ctx);
  … srv.run(); srv.close();
  runner.deinit();                                   // caller owns the runner
  ```

  The provider (`fiber_sched.sx`) wraps `std/sched` — aarch64-only (the
  context-switch asm); it is a direct import, never re-exported, so
  non-fiber programs stay portable. Fibers and a pool together are
  rejected (`error.Config`). Handlers must not call the scheduler's own
  `sleep`/`block_on_fd`; `resp.stream` producers follow the INLINE
  lifetime contract (the fiber's stack is gone when the producer is
  pulled — `ctx` must be caller-owned). Fiber handlers run on a **128 KB
  guard-paged stack** — keep large buffers on the heap or the per-request
  arena, not in locals (an overflow faults loudly, it never corrupts).
  There is no 503 shed in fiber mode: concurrency is bounded by
  `max_conn` (one fiber per occupied slot).

### Handler execution details: inline vs pool

- **Inline** (`thread_pool_count == 0`, the default): the handler runs **on the
  loop thread**, synchronously, during request dispatch. Fastest for quick
  handlers (no hand-off), but a slow handler stalls every other connection, and
  a hung handler hangs the whole server. There is **no hard handler timeout** in
  inline mode — the loop can't preempt itself. Use inline only for handlers you
  trust to return quickly.
- **Pool** (`thread_pool_count = N > 0`): each parsed request is dispatched to a
  worker thread. The loop keeps serving other connections while a handler runs;
  a per-request `handler_timeout_ms` is enforced (a worker that overruns loses
  its connection — 504 to the client — while the server stays responsive). A
  full backlog sheds with **503** (backpressure) rather than growing unbounded.
  **Use pool mode for any handler that can be slow or is untrusted.**

A worker is a C-ABI thread entry that fabricates its own `Context` with its own
`GPA` (malloc-backed). So a handler in pool mode allocates through a per-worker
allocator and **never shares allocator state across threads**.

### Per-request lifetime — what is valid, what you may keep

- The `Request` views (`method`, `path`, headers, `body`) point **into the
  connection's read buffer** and are valid **only during the handler call**.
  Copy anything you need to retain beyond the handler return.
- The `Response` body and headers you set are serialized when the handler
  returns (or streamed — see below). After that the per-request scratch is
  reclaimed. Don't hand the framework a pointer into memory that dies before the
  response is sent.
- In inline mode the handler runs under a **per-request arena**: everything it
  allocates through the implicit context dies with the request. Response bytes
  survive because serialization copies them into the server's allocator.

### Allocator and thread-safety rules

- **The Server's constructing allocator must be thread-safe in pool mode**
  (`GPA`/malloc — never an `Arena`). The pool worker hand-off and the
  completion path touch it from multiple threads.
- **`GPA` is thread-safe** (malloc/free, atomic counters). **`Arena` and every
  other context-flowing allocator is not** — never share one across threads.
- Connection read buffers live across ticks and are **reused** connection-to-
  connection (a buffer pool); they're freed at `Server.close()`.
- Streamed-response scratch is a single bounded buffer reused per chunk and
  freed at stream end (or on abort).

### Scaling across cores: the SO_REUSEPORT multi-loop pattern

One event loop is one core. To use more, do NOT try to share a `Server`
across threads — run **one complete `Server` per thread**, all bound to the
same port with `Config.reuse_port = true`:

```sx
// per worker thread:
cfg : http.Config = .{ port = 8080, reuse_port = true };
srv, err := http.Server.init(cfg, handler, ctx);
if err { /* a refused SO_REUSEPORT or bind is a hard Bind fault */ return; }
srv.run();   // each instance owns its loop, slots, buffers, stats
```

- The **kernel** distributes incoming connections across the listeners —
  no shared accept lock, no cross-thread hand-off. On **linux** the
  4-tuple is hashed across listeners (even spread under load); **darwin**
  makes no distribution promise for TCP (it tends to favor recently-bound
  sockets) — fine for development, measure before relying on it in
  production there.
- Each instance is fully independent: its own event loop, connection
  slots, read/write buffers, Date cache, and `Stats`. Aggregate stats by
  summing `stats()` across instances; `stop()`/`close()` each instance
  from its own controller.
- Sharing is **opt-in and all-or-nothing**: every listener on the port
  must set `reuse_port`; a plain bind against a shared port still fails
  with `Bind` (no accidental sharing), and a refused `SO_REUSEPORT`
  setsockopt is a hard `Bind` fault, never a silent solo bind.
- Handlers follow the same rules as always, per instance. If handlers
  share app state ACROSS instances, that state needs its own
  synchronization — the server gives you none across loops.

### Misuse cases to avoid

- Returning a pointer into the `Request`/read-buffer from a handler and using it
  later — the buffer is reused by the next request.
- Sharing an `Arena` (or any non-GPA allocator) across pool workers.
- Running a slow/untrusted handler inline — use pool mode.
- Assuming a hung pooled handler is reclaimed — it 504s the client but
  permanently consumes its one worker (no thread cancellation). Size the pool
  for your worst-case handler latency.

---

## Streaming

- **Response streaming** (`resp.stream(producer, ctx)`): emit a large body via
  `Transfer-Encoding: chunked` without buffering it whole. The producer is a
  resumable pull `(ctx, offset, dst, dst_cap) -> count` (0 = end); the server
  pulls one bounded piece at a time, backpressure-aware. See
  `examples/http/1674-http-streaming.sx`.
  - **Pool mode**: the producer is pumped **by the worker that ran the
    handler**, inside the request's scope — `ctx` may reference `req.*` views
    and per-request-arena allocations (they outlive every pull), and a slow
    producer never stalls the loop. The worker is **pinned for the stream's
    lifetime**, and that lifetime is controlled by the **client's read
    pace**: a client that keeps draining slowly keeps refreshing the
    stall-based delivery deadline and holds the worker for as long as it
    reads (a client that stops reading entirely is evicted at the fixed
    deadline). Size `thread_pool_count` for the number of concurrent
    streamed responses you are willing to serve; N slow readers pin N
    workers. A total-stream-duration bound is a possible future knob.
  - **Inline mode**: the producer runs on the loop thread after the handler
    returned — `ctx` must be caller-owned memory that outlives the response
    (never `req.*` views or arena allocations), and a slow producer stalls
    the loop (the inline contract).
- **Request bodies (accumulated, the default)**: a `Content-Length` or
  `Transfer-Encoding: chunked` body is decoded into `Request.body`, bounded by
  `Config.max_body` with early **413** rejection. See
  `examples/http/1675-http-request-body.sx`.
- **Request-body streaming** (`Config.stream_request_body`, **pool mode
  only**): every body-carrying request is dispatched at HEADERS-COMPLETE with
  `Request.body == ""`; the handler pulls the decoded body incrementally —

  ```sx
  n := req.read_body(@scratch[0], scratch_cap);   // > 0 bytes; 0 end; -1 fault
  ```

  `read_body` BLOCKS the pool worker until the loop thread feeds more bytes
  through a bounded per-request channel (64 KB), so a body of any size streams
  through bounded memory. It also works on accumulated requests (serves
  `Request.body` through a cursor), so handler code can be mode-agnostic.
  Semantics to know:
  - **`max_body` does not apply** to streamed requests — the reading handler
    is the bound. Refuse an oversized upload by responding (e.g. 413) without
    draining; the server then closes the connection after the response.
  - An **early response** (before `read_body` returned 0) always closes the
    connection — the unfinished inbound stream can never pipeline — and the
    response carries `Connection: close`.
  - `read_body` returning **-1** means the connection died (peer reset, bad
    chunk framing, eviction): respond-and-return; the response is discarded
    if the socket is already gone.
  - The delivery deadline (`timeout_request_ms`) becomes a **stall** bound,
    refreshed on every piece of body progress; `handler_timeout_ms` starts
    once the body completes.
  - Inline mode (`thread_pool_count == 0`) cannot stream (the reader would
    block the loop thread that feeds it) — `Server.init` raises
    `error.Config`.

  See `examples/http/1698-http-stream-request-body.sx`.

---

## Protocol conformance policy (RFC 9110/9112)

Deliberate, load-bearing choices — each is locked by a regression example and
changing any of them is a behavior break:

- **Strict CRLF only — bare LF is not a line terminator.** The parser
  recognizes headers ending in `\r\n\r\n` and chunk framing delimited by
  `\r\n`; a bare `\n` never terminates a request line, header line, or chunk.
  RFC 9112 §2.2 *allows* a recipient to accept bare LF, but the two-peer
  disagreement that leniency creates is a classic request-smuggling vector
  (a lenient front sees two requests where a strict back sees one), so this
  server stays strict: a request using bare LF simply never completes and is
  evicted at the request deadline (408 once partial). This is the same
  posture as the WS-before-colon and duplicate-CL rejections.
- **Trailers are consumed and DISCARDED.** After a chunked body's zero chunk,
  trailer lines are scanned to the terminating empty line and ignored — they
  are never merged into `Request.headers_raw` (`find_header` cannot see
  them), so a trailer can never smuggle a header past the pre-body guards
  (RFC 9112 §7.1.2 allows dropping trailers; the disallowed-field merge
  hazard is the reason).
- **Request-target forms** (RFC 9112 §3.2): origin-form routes as-is;
  absolute-form is accepted with the authority exposed on
  `Request.authority` and the embedded path routed; `OPTIONS *` is accepted;
  asterisk-form with any other method → 400; authority-form (and CONNECT in
  any form) → 501/400 — no tunneling.
- **Path canonicalization** (RFC 3986): the routable path is percent-decoded
  and dot-segment-normalized before routing (`%2e%2e` cannot smuggle a
  `..`); the query string is never decoded at this layer. Rejected with
  **400**: malformed escapes, decoded control bytes (`%00`, `%0D%0A`),
  `%2F` (a decoded `/` would change segmentation — the encoded-slash
  bypass), `%3F`, and `..` climbing above the root.
- **Host** (RFC 9112 §3.2): exactly one `Host` required on HTTP/1.1
  (missing or duplicated → 400); HTTP/1.0 exempt.
- **`Expect: 100-continue`**: a 1.1 request with a declared, not-yet-arrived
  body gets one interim `100 Continue`; up-front rejects send the final
  status directly; any other expectation → 417.
- **Automatic HEAD**: handlers run as for GET; the response keeps the GET's
  headers (including `Content-Length`) with no body bytes; the `Router`
  dispatches HEAD to GET routes when no HEAD route exists. `204`/`304`
  never carry a body (204 omits `Content-Length` entirely).
- **`Date`** on every response (cached per second); optional `Server:` via
  `Config.server_name`.
- **`Connection`** is parsed as a comma-separated token list (`close, TE`
  reads as close); if both `close` and `keep-alive` appear, close wins.

---

## Deployment

### Listener addresses (IPv6, bind address, Unix sockets)

The listener is configured entirely from `Config`:

- **`bind_addr`** — a NUMERIC address literal; the family follows it.
  `""` (default) binds IPv4 `INADDR_ANY`; `"127.0.0.1"` restricts to v4
  loopback; `"::"` makes an IPv6 listener that ALSO serves v4 by default
  (see `ipv6_only`); `"::1"` is v6 loopback only. A value that parses as
  neither family is `error.Bind` — never a fallback bind. Hostnames are
  not resolved here (a bind address is infrastructure, not DNS); use
  `socket.resolve` yourself if you must.
- **`ipv6_only`** — every v6 listener sets `IPV6_V6ONLY` explicitly from
  this (default `false` = deterministic dual-stack, v4 connections arrive
  as mapped addresses), never the OS's sysctl-dependent default.
- **`unix_path`** — non-empty makes an AF_UNIX listener on that path
  (`port`, `bind_addr`, `reuse_port` do not apply; combining with
  `bind_addr`/`reuse_port` is `error.Config`). **The path belongs to the
  server, exclusively**: whatever file is there is unlinked before bind
  (a regular file included), and `close()`/`stop()` remove it — so never
  point two servers at the same path (they unlink each other's live
  socket), and never point it at a file you value. Typical use: a local
  reverse proxy (`proxy_pass http://unix:/run/app.sock:` in nginx) with
  no TCP port exposed at all.
- A v4-mapped literal (`"::ffff:127.0.0.1"`) makes an AF_INET6 listener
  that plain v4 clients reach (OS mapping semantics); with
  `ipv6_only = true` it fails loudly at bind.
- Client-side, `std/socket` grew the matching primitives: a generic
  `Addr` with `parse_addr` (numeric), `addr_unix`, and `resolve`
  (getaddrinfo — the DNS-capable one), plus `connect_to`/`bind_to`/
  `addr_family`. End-to-end example:
  `examples/http/1704-http-bind-ipv6-unix.sx`.

### Native TLS (HTTPS)

Serve HTTPS in-process — no reverse proxy required — by handing `Config.tls` an
mbedTLS-backed acceptor. Only a program that imports the provider compiles the
crypto; plaintext servers link none of it.

```sx
http :: #import "modules/std/http.sx";
tls  :: #import "modules/std/http/tls_mbedtls.sx";

main :: () -> i32 {
    server : tls.TlsServer = .{};
    if !server.setup_files("cert.pem", "key.pem", context.allocator) {
        print("TLS setup failed\n"); return 1;
    }
    cfg : http.Config = .{ port = 443 };
    cfg.tls = xx @server;                       // null (the default) = plaintext
    srv, e := http.Server.init(cfg, handler, 0);
    if e { return 1; }
    srv.run();
    server.deinit();
    0
}
```

- The provider (`std/http/tls_mbedtls.sx`) implements the `TlsConn` / `TlsAcceptor`
  seam over vendored mbedTLS v3.6.6 (TLS 1.2 + 1.3). A connection is negotiated
  through a `CONN_TLS_HANDSHAKE` state before its first request; a per-session
  setup failure drops the connection — **it is never served in the clear**.
- `setup_files(cert, key, alloc)` loads a PEM cert chain + private key from disk;
  `setup(cert_bytes, key_bytes, alloc)` takes the bytes directly. A bad cert/key
  makes the server accept **no** TLS (loud `false`), never plaintext.
- The minimum version defaults to TLS 1.2 (preferring 1.3). The crypto is
  vendored + cross-compiled (no system mbedTLS); a `--self-contained` build
  links it statically into the binary — no per-target archive to ship.
- **ALPN**: `server.set_alpn(protos)` advertises protocols in preference order
  (e.g. `.["http/1.1"]`). A client whose ALPN offer has no overlap is refused
  at the handshake; a client that sends no ALPN extension still connects.
- **SNI / multi-cert**: `server.add_sni_cert_files(name, cert, key)` (or
  `add_sni_cert` for bytes) serves an extra identity when the client's SNI
  names `name` (exact, case-insensitive). No match falls back to the `setup`
  cert — unknown/IP connections get the default identity, never a refusal.
- **Client-cert auth (mTLS)**: `server.require_client_cert_files(ca)` makes
  every handshake require a client certificate verifying against the CA chain
  (a self-signed client cert can BE the anchor). A cert-less or untrusted
  client fails the handshake and is dropped — never served.
- DATA-phase cross-direction TLS wants (a read needing writability, a write
  needing readability — renegotiation/ticket-shaped flows) are tracked on the
  connection and retried on the correct readiness; they neither stall to the
  deadline nor spin the loop.
- TLS just terminates the transport: the handler, routing, streaming, keep-alive,
  and all limits work identically over the encrypted connection. End-to-end
  examples: `examples/http/1679-http-tls-https.sx` (basics),
  `…/1703-http-tls-alpn-sni-mtls.sx` (ALPN + SNI + mTLS),
  `…/1702-http-tls-cross-direction-want.sx` (cross-direction wants at the seam).

Native TLS and a terminating reverse proxy are **both** supported — pick one.

### Reverse proxy (alternative)

Run behind nginx / Caddy / HAProxy / a cloud LB for any internet-facing service.
The proxy terminates **TLS** (or terminate it in-process — see *Native TLS*
above) and adds defense-in-depth.

nginx sketch:

```nginx
upstream sx_app { server 127.0.0.1:8080; keepalive 32; }
server {
    listen 443 ssl http2;
    server_name example.com;
    ssl_certificate     /etc/ssl/example.crt;
    ssl_certificate_key /etc/ssl/example.key;
    location / {
        proxy_pass http://sx_app;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
        client_max_body_size 10m;        # mirror Config.max_body
    }
}
```

- **Client IP / scheme**: read `X-Forwarded-For` / `X-Forwarded-Proto` from the
  request headers (the proxy sets them; the server does not).
- **Size / timeouts**: set the proxy's `client_max_body_size` and read/keepalive
  timeouts to match the server's `max_body`, `timeout_request_ms`,
  `timeout_keepalive_ms`.

### Health check

Add a cheap route and point the proxy / orchestrator at it:

```sx
if req.path == "/healthz" { resp.body = "ok"; return; }   // 200
```

### Graceful shutdown (systemd / orchestrators)

`Server.stop()` is safe to call from a signal relay or another thread (it wakes
the loop). `run()` then stops accepting, closes idle keep-alives, drains
in-flight requests up to `shutdown_timeout_ms`, and returns; the caller calls
`close()`. Wire your `SIGTERM` handler to `stop()` so deploys drain cleanly.

```ini
# /etc/systemd/system/sx-app.service
[Unit]
Description=sx http app
After=network.target

[Service]
ExecStart=/usr/local/bin/sx-app
Restart=on-failure
# Let in-flight requests drain (>= shutdown_timeout_ms):
TimeoutStopSec=10
# Hardening:
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
```

### Docker

Build a static Linux binary (`--self-contained` links musl) and ship it in a
minimal image — no runtime libc needed:

```sh
sx build --target aarch64-linux --self-contained -o sx-app app.sx   # or x86_64-linux
```

```dockerfile
FROM scratch
COPY sx-app /sx-app
EXPOSE 8080
ENTRYPOINT ["/sx-app"]
```

(Use `FROM alpine` instead of `scratch` if you want a shell / CA certs.)

### Build / linking notes

- **Static** (`--self-contained`): musl-linked, portable across Linux distros,
  ideal for containers. **Dynamic** (default on the host): links the system
  libc.
- **Cross-compile**: `sx build --target <triple>` (e.g. `x86_64-linux`,
  `aarch64-linux`). See [readme.md](../readme.md) for the cross-compilation
  details.
- **TLS**: native TLS is vendored (mbedTLS, compiled via `#import c`), so a
  `--self-contained` build links the crypto statically with no per-target
  archive to ship. See *Native TLS (HTTPS)* above; or terminate TLS at a proxy.

### Observability

Install `Config.on_event` to log faults (it's called from the loop thread with
the event kind + slot + a status/detail; no format is forced) and poll
`Server.stats()` for counters — accepted/closed/active connections, requests
served, 4xx/5xx, timeouts, 503 sheds, bytes in/out, pool queue depth. Watch the
rejected/timeout/5xx counters for abuse or saturation.

### Tuning knobs (`Config`)

| field | purpose |
|-------|---------|
| `port`, `backlog`, `max_conn` | listener + connection ceiling (excess → shed) |
| `read_buf_cap`, `max_body` | hard raw ceiling / max decoded request body (→ 413) |
| `max_headers`, `max_header_line` | header-count / line-size caps (→ 431) |
| `timeout_request_ms`, `timeout_keepalive_ms` | slow-client eviction |
| `request_count` | requests per connection, then close |
| `thread_pool_count`, `thread_pool_backlog` | pool size / queue (full → 503) |
| `handler_timeout_ms` | per-request deadline (hard in pool mode) |
| `shutdown_timeout_ms` | graceful-drain bound |
| `on_event`, `on_event_ctx` | observability hook |

---

## Stability

Every feature below has corpus coverage (`examples/http/*`) run on each build,
subprocess-isolated, on macOS and validated end-to-end on aarch64-Linux.

**Supported (stable API):**

- `Server.init` / `run` / `tick` / `stop` / `close`; `Config`; the
  `(*Request, *Response, usize)` handler convention.
- HTTP/1.1 request parsing with the hardening guards (smuggling, overflow,
  resource caps), keep-alive + pipelining, inline and pooled handlers.
- Response: fixed body (`Content-Length`) and chunked streaming
  (`resp.stream`); the `set_status` / `set_content_type` / `add_header` helpers.
- Request bodies: `Content-Length` and inbound chunked decode, bounded by
  `max_body`.
- Graceful shutdown (`stop`), the `Stats` counters + `on_event` hook, and the
  per-request handler timeout (hard in pool mode).
- `std/http_router`: method+path routing, path params, query/urlencoded-form
  parsing, JSON request/response helpers (over `std/json`, integers only).
- Underlying `std/socket`, `std/event`, `std/thread`, `std/mem` — the stable
  subset this server stands on; per-OS-correct on macOS + Linux.

**Stable subset (cont.):**

- **Native TLS (HTTPS)** — `Config.tls` over vendored mbedTLS (TLS 1.2 + 1.3),
  with ALPN, SNI / multi-cert, and client-cert auth (mTLS); see *Native TLS
  (HTTPS)* above. An explicit min-version pin is future work (needs a small C
  shim — the mbedTLS setter is `static inline`).
- **Blocking HTTP/1.1 client** (`http.Client`) — sessions
  (`open`/`open_addr`/`send_on`/`recv_on`/`close_conn` under `ClientOpts`):
  resolver or `Addr` dialing (unix included), connect + per-op I/O
  timeouts, HTTPS through the `TlsDialer` seam
  (`tls_mbedtls.TlsClientConfig` — explicit trust anchor with hostname
  verification, or the loudly-named `insecure()`; TLS 1.3 session tickets
  handled), chunked response decoding via the server's own decoder, and
  truncated responses surfaced as errors — never a padded body.
  `Client.fetch(method, url, …)` adds URL parsing and redirect following
  (301/302/303 → GET, 307/308 preserve, capped by
  `ClientOpts.max_redirects`; https targets require a configured dialer);
  `ClientPool` adds single-threaded keep-alive reuse with a one-shot
  fresh-dial retry for the stale-keep-alive race. System trust roots are
  not discovered — pass a CA explicitly.

**Experimental / not yet present:**

- **Inline handler timeout** — cooperative only; no hard preemption (use pool
  mode).
- **`std/json` floats** — integers/strings/bools/null only.
- **multipart/form-data** — out of scope in `std/http_router` (urlencoded only).
- **Long-running fuzz / load / stress harnesses** — a bounded fuzz *smoke* runs
  in the corpus; exhaustive fuzzing and load testing belong in CI (see
  `tests/`), not the per-build suite.

Treat anything not listed under "Supported" as subject to change.
