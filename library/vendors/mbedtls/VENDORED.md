# vendors/mbedtls — vendored Mbed-TLS

- **Upstream:** https://github.com/Mbed-TLS/mbedtls
- **Tag:** `v3.6.6` (LTS branch, TLS 1.3 capable)
- **License:** Apache-2.0 (see `LICENSE`, copied verbatim from upstream).

## Layout (sqlite-vendor convention)

```
mbedtls.sx                          # sx bindings + the `@import c` compile unit
c/library/*.c                       # 109 upstream library sources
c/library/*.h                       # upstream INTERNAL headers (common.h, ssl_misc.h, …)
c/library/sx_mbedtls_lib_anchor.h   # sx-added: anchors -Ic/library (see below)
c/include/mbedtls/*.h               # public API headers (74)
c/include/mbedtls/mbedtls_config.h  # sx-OWNED trimmed config (NOT upstream's stock)
c/include/psa/*.h                   # PSA crypto headers (23)
c/include/sx_mbedtls_anchor.h       # sx-added: anchors -Ic/include (see below)
```

`@import "vendors/mbedtls/mbedtls.sx"` compiles `c/library/*.c` through sx's
content-addressed C-object cache and binds every `extern mbedtls` decl against
it — no system mbedTLS, no `zig cc`. A program that never imports it compiles
none of it. The import supplies the `mbedtls` scope: the bindings are reached as
`mbedtls.mbedtls_ssl_init`, `mbedtls.SslContext`, `mbedtls.MBEDTLS_SSL_IS_SERVER`,
and the C unit itself as `mbedtls.mbedtls`.

## The `@import c` wiring (mbedtls.sx)

```
mbedtls :: scope {
    mbedtls :: @import c {
        @include "c/include/sx_mbedtls_anchor.h";       // -> -Ic/include
        @include "c/library/sx_mbedtls_lib_anchor.h";   // -> -Ic/library
        @flags  "-Os";
        @source "c/library/<each>.c";                   // x109
    };
    ...
}
```

The two **anchor headers** are an sx idiom: a `@import c` `@include "x"` adds
`dirName(x)` to `-I` (and parses `x` for FFI decls — the anchors are empty, so
no decls). We need `-Ic/include` (so the sources find `<mbedtls/*.h>` and the
default `mbedtls/mbedtls_config.h`) and `-Ic/library` (so they find their
sibling private headers like `common.h`). There is no header directly in
`c/include` / `c/library`, so we add an empty anchor in each.

**Config:** we do NOT use `MBEDTLS_CONFIG_FILE` (the `#define` value would reach
clang with literal backslash-quotes — `@import c` doesn't unescape — and
`#include MBEDTLS_CONFIG_FILE` fails). Instead the sx-owned trimmed config simply
REPLACES the stock `c/include/mbedtls/mbedtls_config.h`; mbedTLS includes that by
default (`build_info.h`: `#if !defined(MBEDTLS_CONFIG_FILE) #include
"mbedtls/mbedtls_config.h"`).

## The config trim (`c/include/mbedtls/mbedtls_config.h`)

Derived from upstream's stock `mbedtls_config.h` (TLS 1.3 in 3.6 is hard-gated on
PSA crypto, which the stock file wires correctly — don't hand-roll). 12 options
disabled vs stock: `MBEDTLS_FS_IO`, `MBEDTLS_NET_C`, the `MBEDTLS_SSL_PROTO_DTLS`
family (+ DTLS anti-replay / hello-verify / client-port-reuse / connection-id),
`MBEDTLS_SELF_TEST`, `MBEDTLS_TIMING_C`, `MBEDTLS_PSA_ITS_FILE_C`,
`MBEDTLS_PSA_CRYPTO_STORAGE_C`, `MBEDTLS_DEBUG_C`.

`MBEDTLS_SSL_CLI_C` is **enabled**: the client `.c` sources are already in
the `@import c` `@source` list, so this only ACTIVATES them — a server-only
deployment never references the client code and the linker strips it. Enabling
lets the in-process loopback TLS test run a self-contained client (no
external openssl, corpus/sandbox-friendly).

`MBEDTLS_THREADING_PTHREAD` and `MBEDTLS_THREADING_C` are **enabled** wherever
the build has threads (all but an Emscripten build without `-pthread`): std's
TLS runs on several threads, and the shared CTR-DRBG, entropy, RSA blinding and
PSA state take their mutexes. The pthread layer needs no setup or teardown
call: its global mutexes are static `PTHREAD_MUTEX_INITIALIZER`s, and each
context's own mutex is created and destroyed by that context's
`_init`/`_seed` and `_free`.

## Status

- **Host (macOS) compiles + links + runs** — `bench/tls-probe.sx` prints `3.6.6`.
- **`--self-contained` Linux cross-targets compile + link + run** — `sx build
  --target aarch64-linux --self-contained bench/tls-probe.sx` produces a static
  aarch64 ELF that prints `3.6.6` under Apple `container` (musl, exit 0); same
  for `--target x86_64-linux`. The embedded clang is pointed at the bundled-zig
  libc include dirs for the target (see `src/target.zig` `linuxLibcIncludeDirs`
  + `src/c_import.zig`). That wiring is general — sqlite/stb cross-compile the
  same way.

## Updating

Re-clone the tag, copy `library/*.{c,h}` → `c/library/`, `include/{mbedtls,psa}`
→ `c/include/`, re-apply the config trim (every option marked `sx:`) onto the
new stock `mbedtls_config.h` (keep it at `c/include/mbedtls/mbedtls_config.h`),
keep the two anchor headers, refresh the `@source` list in `mbedtls.sx`.
