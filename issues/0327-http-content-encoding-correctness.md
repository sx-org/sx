# 0327 — HTTP content encoding violates message framing and negotiation invariants

> **RESOLVED (2026-07-21).** All five blocking defects and every additional
> review finding are fixed in the bounded client/server content-encoding
> integration (`std/http/*` + `std/http/content_encoding.sx`): framing is
> decided from method + parsed status (HEAD/1xx/204/304 safe, informational
> responses drained), producer faults reach the event loop and close the
> connection without a terminator or reuse, identity refusal (`identity;q=0`)
> is tracked independently of floors/policy exits with 406 when nothing is
> acceptable, Range/Content-Range responses are never transformed and
> automatic ranged requests send no Accept-Encoding, strong validators are
> never reused for coded bytes, all Cache-Control lines are scanned,
> unknown/stacked codings are preserved when transparent decoding is off,
> `EncodedProducer.next` yields after bounded forward progress, the internal
> `content_encoding` namespace is hidden from public modules (typed
> content-coding metadata replaced the bool + magic string), media types
> match exactly, handler-supplied framing headers are reserved, and all new
> stream/channel/encoder allocations prove cleanup on failure.
> Evidence — corpus: 1719-http-content-encoding (opt 0+3),
> 1727-http-client-content-framing (opt 0+3), 1728-http-content-encoding-modes
> (host-gated `compile_only` cross-target), 1730-http-content-encoding-
> internals-hidden (compile-negative, opt 0+3 exact diagnostics);
> manual (corpus-excluded per Agra, ≤1s budget): 1729-http-content-encoding-
> allocation opt 0+3, failing-allocator matrix cleanly unwinding. All runtime
> evidence inside net-zero GPA gates. Docs: `docs/http-server.md` swept for
> the final API spellings.

## Blocking defects

1. `recv_on` decides body framing before it knows the request method or parsed
   response status. Responses to `HEAD` and 1xx/204/304 responses can therefore
   block on an advertised body, consume a following response as body bytes, or
   desynchronize a reusable connection. Informational responses also need to
   be consumed until the final response.
2. A pool-worker encoder/source failure breaks the producer loop and then calls
   `OutChan.finish_eof`. The event loop emits a clean zero chunk and can reuse
   the connection even though the advertised gzip/zlib representation is
   truncated. Producer faults must reach the loop, close without a terminator,
   and make the connection non-reusable.
3. Policy exits and the minimum-size floor can emit identity despite
   `identity;q=0`. Identity acceptability must be tracked independently from
   the preferred supported coding; a floor may not override an explicit
   refusal, and an ineligible representation must produce 406 when no
   acceptable representation is available.
4. Automatic transformation is unsafe for ranges. Any `Content-Range`
   response must remain untransformed; an automatic client request containing
   `Range` must not add `Accept-Encoding`, and coded 206/416 responses must not
   be transparently rewritten into bytes whose offsets/validators describe a
   different representation.
5. Automatic coding currently preserves strong identity validators/digests.
   A coded representation must not reuse a strong validator for different
   bytes; skip transformation, weaken/remove the validator, or generate a
   coding-specific value under a documented policy.

## Additional review findings

- Scan all `Cache-Control` field lines for `no-transform`, not just the first.
- With transparent decoding disabled, preserve arbitrary/stacked
  `Content-Encoding` values instead of rejecting them.
- Bound cooperative work in `EncodedProducer.next`; yield after forward
  progress instead of consuming an arbitrarily large compressible source while
  trying to fill one encoded output window.
- Do not expose the internal `content_encoding` namespace through public
  client/server modules. Replace redundant `decoded: bool` plus magic-string
  `decoded_from` metadata with one optional typed content-coding value.
- Match complete media types (`application/json`, etc.), not prefixes such as
  `application/jsonp`.
- Reserve or reject handler-supplied `Content-Length`/`Transfer-Encoding` when
  the server owns framing.
- Check newly introduced stream/channel/encoder allocations and prove cleanup
  on failure.
- Explain or remove unrelated changes to HTTP examples 1674, 1678, and 1697.

## Required evidence

- Same-connection `HEAD`, 1xx, 204, and 304 followed by a normal response,
  covering fixed and streamed handlers in inline, pool, and fiber modes.
- Pool and inline source/codec failure injection before and after encoded
  output; clients observe truncation, no zero chunk, no reuse, and zero leaks.
- Accept-Encoding qvalue/wildcard/identity-refusal matrices across floors,
  disabled/ineligible/no-transform/range/existing-coding cases, including 406.
- Range/Content-Range/416 and strong-validator behavior for identity, gzip, and
  deflate.
- Repeated Cache-Control fields, unknown/stacked raw codings, exact/one-short
  caps for every framing/coding, gzip concatenation, close-delimited zlib,
  payloads above 16 KiB, malformed trailers/checksums/coding lists, and
  concurrent ping progress during large highly-compressible streams.
- Negative namespace tests for implementation aliases and full existing HTTP
  regression coverage at `--opt 0` and `--opt 3` with net-zero allocations.
