# Bundled `zig` link backend

> The design-of-record for how a distributed sx links native binaries
> hermetically. User-facing surface is documented in `readme.md`
> (Cross-Compilation §).

---

## The backend at a glance

| Target | Result | Link invocation |
|--------|--------|-----------------|
| `--target linux-musl` | static ELF | `zig cc -target x86_64-linux-musl -static` |
| `--target windows-gnu` | PE32+ | `zig cc -target x86_64-windows-gnu` |
| `--target macos` | Mach-O | `zig cc -target <arch>-macos`, no `-static` |

- **Scope = macOS + Linux + Windows** (`TargetConfig.zigBackendInScope`).
  iOS/Android/wasm keep their specialized toolchains.
- **Auto-activation needs a *bundled* zig** — a real distribution, or a pinned
  `$SX_ZIG`. A `PATH`-only zig engages **only** under `--self-contained`, so
  native dev/CI builds are never silently rerouted on any of the three OSes.
  That is what the "zig found (B)" column of §5.5 means: **B = bundled**.
- **No translation table:** sx triples are passed straight to `zig cc`, and
  `emit_llvm` runs them through `LLVMNormalizeTargetTriple` so vendor-less zig
  triples (e.g. `x86_64-windows-gnu`) land their OS/env in LLVM's canonical
  positions — otherwise "windows" sits in the vendor slot and the object
  silently falls back to ELF. **macOS** is the one exception: the object must
  be emitted from Apple's `apple-darwin` triple (LLVM needs it for Mach-O),
  which zig's `-target` parser rejects, so the *linker* triple alone is the
  vendor-less `<arch>-macos`. One OS-specific line, not a table.

Files: `src/zig_backend.zig` (discovery), `src/target.zig`
(`selectZigLinker` / `emitZigLinkArgv` / `zigTargetTriple` / dispatch in
`link`), `src/ir/emit_llvm.zig` (triple normalization), `src/main.zig`
(`--self-contained` / `--no-self-contained` + shorthands).

---

## 0. The gap this closes

**The gap.** A distributed `sx` compiler runs on a Linux box (static-LLVM
binary + relocatable `library/`), but without a link backend it cannot
*finish a build*: the final link step shells out to the host's `cc`, and
relies on the host's libc + CRT objects. No `cc`/glibc/SDK on the box → no
binary. That is the distance between "sx runs here" and "sx is a toolchain
here."

**The approach.** Bundle a pinned `zig` binary inside the sx distribution and
use `zig cc` as the link backend for `sx build`. `zig cc` brings its own lld,
CRT objects, and libc (musl or glibc) for the chosen target. Default Linux
output is **statically-linked musl**, which runs on any Linux with zero
dependencies — the property that makes Zig's own output portable.

The seam is narrow:
- The linker is selected through a single hook, `TargetConfig.getLinker()`,
  and the final link argv is built in one place, the Unix `cc`-style branch
  of `src/target.zig`.
- `zig cc` is a clang-compatible driver, so `-o` / `-L` / `-l` / extra
  objects pass through that branch unchanged. The backend only prepends
  `zig cc` and adds `-target …` / `-static`.
- Exe-relative resolution (for finding the bundled zig) mirrors how
  `src/imports.zig` resolves the stdlib.
- `sx run` is JIT and never links, so it is unaffected.

The cost is a ~50–60 MB vendored `zig` (binary + its `lib/`) in the
distribution, and version-pinning discipline.

---

## 1. Motivation & background

### 1.1 What the host still supplies

| Concern | Where it comes from | File |
|---------|-------|------|
| Compiler binary | Self-containable via `-Dstatic-llvm` (no system LLVM) | `build.zig:9-10,156-162` |
| Stdlib | Relocatable, found relative to the exe | `src/imports.zig:204-227` |
| **Linking** | **Shells to system `cc`** | `src/target.zig:524-564` |
| **libc / CRT** | **Provided by the host `cc` driver implicitly** | (no `-lc`/crt passed) |

Two of three legs of a portable toolchain stand on their own. The third — the
linker and the libc/CRT it pulls in — is the host dependency this design
removes.

### 1.2 Why this matters for distribution

The goal is to hand someone a tarball and have `sx build app.sx` produce a
working binary on a stock Linux machine — a fresh container, a minimal CI
image, a box without `build-essential`. A host `cc` link step cannot do that.
Zig solves exactly this problem for its own users; since sx is *built with*
Zig, standing on Zig's hermetic toolchain is cheaper than re-implementing it.

---

## 2. Goals & non-goals

### Goals
- `sx build` produces a native Linux binary with **no host `cc`/ld/libc/SDK**.
- Default Linux output is **portable** (static musl): runs on any Linux.
- **Zero-config in the common case**: a bundled or PATH `zig` is detected and
  used automatically; the operator sets nothing.
- A fully-specified, documented configuration surface (this document) for the
  cases that *do* need tuning.
- No regression for existing users: system `cc` remains a fallback, and any
  explicit `--linker` still wins.

### Non-goals
- Reimplementing lld in-process or building libc from source (see §7 — Zig
  does both, and the backend reuses it).
- Routing C-import compilation (`src/c_import.zig`, which also shells `cc`)
  through the backend.
- Glibc-floor version pinning (`…-gnu.2.28`).

---

## 3. How Zig achieves hermetic builds

Zig's turnkey cross-compilation rests on bundling the two things sx borrows
from the host:

1. **In-process lld.** Zig embeds LLVM's lld (ELF/COFF/Mach-O/wasm) and links
   without spawning an external linker.
2. **libc as data.** Zig ships musl *source* (builds `libc.a` + `crt*.o` on
   demand, cached → static, no dynamic linker → portable output) and glibc
   stubs generated from `.abilist` per version. For Windows it ships mingw
   `.def` files and synthesizes import libraries.

`zig cc` exposes all of this behind a clang-compatible driver: `zig cc
-target x86_64-linux-musl -static foo.o -o foo` yields a portable binary on
any host, with nothing installed. **This design consumes that driver rather
than rebuilding its internals** — vendoring the `zig` binary brings the whole
second column with it.

---

## 4. Design overview

`sx build` has a **link backend** abstraction with two implementations:

- `system_cc` — shell `cc`, host libc.
- `bundled_zig` — shell `<zig> cc -target <triple> [-static] …`.

Selection is automatic (§5.5): if a usable `zig` is discovered and the user
gave no explicit `--linker`, `bundled_zig` is used; otherwise `system_cc`.
The backend plugs into the existing Unix link branch — it contributes the
leading `zig cc` tokens and the `-target`/`-static` flags; the rest of the
argv assembly is unchanged because `zig cc` is clang-compatible.

When `bundled_zig` is active, the triple handed to LLVM in
`src/ir/emit_llvm.zig` is aligned to the link target (`x86_64-linux`) so the
emitted object links cleanly against the selected musl CRT.

---

## 5. Detailed design (the configuration surface)

### 5.1 zig discovery — resolution order

`discoverZig()` (`src/zig_backend.zig`) returns the first hit:

1. `$SX_ZIG` — explicit override.
2. `<exe_dir>/../libexec/zig/zig` — **install layout** (§6).
3. `<exe_dir>/../../zig-bundle/zig` — **dev vendored layout** (§6).
4. `zig` on `PATH` — **dev fallback**, active only under `--self-contained`.

`<exe_dir>` is resolved exactly as `src/imports.zig` resolves the stdlib.
If none resolve, behavior depends on activation (§5.5): auto-mode silently
falls back to `system_cc`; `--self-contained` errors.

### 5.2 Environment variables

| Var | Effect | Default |
|-----|--------|---------|
| `SX_ZIG` | Absolute path to the `zig` used as the link backend. Highest-priority discovery source. | unset |
| `ZIG_LIB_DIR` | Path to the bundled zig's `lib/`. Needed **only** if `zig` was relocated away from its `lib/`. In the supported layout (§6) they ship together and zig self-locates — leave unset. | unset |
| `SX_DEBUG_ZIG` | Trace discovery: each candidate path and the chosen one (or "none → cc"). Mirrors `SX_DEBUG_STDLIB`. | unset |
| `SX_DEBUG_LINK` | **Existing.** Prints the full link argv — shows the exact `zig cc …` invocation. | unset |
| `SX_STDLIB_PATH` | **Existing.** Stdlib override; unrelated to linking but noted because a full distribution sets neither and relies on exe-relative discovery for both. | unset |

### 5.3 CLI flags (`sx build`)

| Flag | Effect |
|------|--------|
| `--self-contained` | Force `bundled_zig` ON. If no usable zig is found, **error** — do not silently fall back. |
| `--no-self-contained` | Force `system_cc`. |
| `--linker <cmd>` | **Existing.** Explicit linker; supplying it **disables** auto-activation (user's choice wins). To pin a specific zig, prefer `SX_ZIG` + `--self-contained`. |
| `--target <triple\|shorthand>` | **Existing.** Selects target + ABI (§5.4). With `bundled_zig` active and target unspecified on a Linux host → `x86_64-linux-musl` static. |
| `--sysroot <path>` | **Existing.** Forwarded to the linker; rarely needed with `bundled_zig` (zig brings its own sysroot). |

### 5.4 Target → ABI mapping

The default (no `--target`) differs from the `linux` shorthand, because
portable static output is the entire point.

| `sx` invocation | zig `-target` | Link mode | Portable? |
|-----------------|---------------|-----------|-----------|
| *(no `--target`, Linux host)* | `x86_64-linux-musl` | `-static` | ✅ any Linux |
| `--target linux-musl` *(new)* | `x86_64-linux-musl` | `-static` | ✅ |
| `--target linux` / `linux-x86` | `x86_64-linux-gnu` | dynamic | ❌ host glibc, versioned |
| `--target linux-arm` | `aarch64-linux-gnu` | dynamic | ❌ host glibc, versioned |
| `--target linux-musl-arm` | `aarch64-linux-musl` | `-static` | ✅ |
| `--target windows-gnu` | `x86_64-windows-gnu` | per zig | ✅ |
| `--target macos` / `macos-arm` | `aarch64-macos` | per zig | ✅ |

- `linux-musl` and `linux-musl-arm` select static musl; the `linux` and
  `linux-arm` shorthands stay gnu/dynamic.
- The LLVM emit triple is aligned to the link target so the `.o` links
  cleanly against the selected libc/CRT (§4).

### 5.5 Activation truth table

`B` = a usable zig was discovered (§5.1). Subcommand = `sx build`.

| `--self-contained` | `--no-self-contained` | `--linker` | zig found (B) | Result |
|:---:|:---:|:---:|:---:|--------|
| — | — | no | yes | **bundled_zig** (auto) |
| — | — | no | no | system `cc` (silent fallback) |
| — | — | yes | * | user's `--linker` |
| yes | — | * | yes | **bundled_zig** (forced) |
| yes | — | * | no | **error**: `--self-contained` but no zig |
| — | yes | * | * | system `cc` (forced off) |

- `--self-contained` + `--linker` together: backend choice goes to
  `--self-contained`; treat the literal combination as a usage error
  (document, don't guess).
- `sx run` / `sx ir` / `sx asm` never link → backend not consulted.

### 5.6 Emit-triple alignment

`src/ir/emit_llvm.zig` (`LLVMSetTarget`) uses the host default triple when
`--target` is unspecified (on Linux, `x86_64-unknown-linux-gnu`). When
`bundled_zig` is active, the module triple is set to match the link target
(`x86_64-linux`) so codegen and the musl CRT agree. Pure codegen objects are
ABI-compatible across gnu/musl; aligning the triple removes the edge-case risk
(TLS model, stack protector).

---

## 6. Distribution layout (packaging)

A relocatable tree; everything resolves relative to `bin/sx`, so the whole
directory moves/untars anywhere with no env vars set:

```
sx-<os>-<arch>/
├── bin/
│   └── sx                 # built -Dstatic-llvm (no system LLVM dep)
├── libexec/
│   └── zig/
│       ├── zig            # pinned zig binary
│       └── lib/           # zig's lib/ (musl/glibc sources, lld data, …)
└── library/               # sx stdlib (existing discovery)
    └── modules/…
```

Rules:
- `zig` and its `lib/` **must** ship together under `libexec/zig/` so zig
  self-locates `lib/`; splitting them forces `ZIG_LIB_DIR`.
- Pinned zig version: **0.16.0** (matches the build toolchain). Record the
  exact version in the release manifest — a mismatched `zig cc` CLI is the
  likeliest future breakage.
- Vendor the matching zig release per host os/arch from ziglang.org at
  package time.

---

## 7. Why not the alternatives

| Alternative | Why not |
|-------------|---------------|
| **In-process lld + bundled musl sysroot** (sx owns the pipeline; no zig) | Requires a custom LLVM build *with* lld — the Homebrew `llvm@22` here ships none (`liblld*.a`, headers, `ld.lld` all absent) — plus a C++ lld shim and per-arch prebuilt musl. Strictly more work for the same user-visible result. |
| **Full Zig-style: build libc from source on demand** | Most flexible (any arch/libc version, no prebuilt blobs) and the most work. |
| **Document a hard dependency on system `cc`** | Zero engineering, but defeats the goal — the box still needs `build-essential`. It is the fallback, not the distribution story. |
| **Bundle just `ld.lld` + a musl sysroot (no full zig)** | Smaller than a whole zig, but it hand-manages crt object selection, dynamic-linker paths, and import libs — re-deriving what `zig cc` already encapsulates. The bundle-size saving does not justify the fragility. |

Vendoring `zig` wins on effort-to-result because sx already builds with Zig:
it is a first-party dependency, not a foreign toolchain, and the same driver
covers the Windows and macOS targets.

---

## 8. Risks

- **Bundle size** ≈ 50–60 MB (zig + `lib/`). Acceptable for a toolchain;
  call it out in release notes.
- **zig CLI drift** across versions — pin hard, record in the manifest;
  the most likely future breakage.
- **gnu vs musl ABI** for the emitted object — covered by the emit-triple
  alignment (§5.6); TLS/stack-protector are the only realistic friction.
- **Operator confusion**: default-no-target (musl) diverging from the
  `linux` shorthand (gnu). Mitigated by the new `linux-musl` shorthand and
  explicit documentation (§5.4).

---

## 9. Not covered

- **`src/c_import.zig`** shells system `cc` for C imports in JIT mode; it does
  not go through the backend.
- **In-process lld** (the first alternative in §7) — the zero-foreign-binary
  shape, which this design does not take.

---

## Appendix — quick recipes

```sh
# Portable static Linux binary (default when a bundled zig is present):
sx build app.sx -o app
file app        # → "ELF 64-bit … statically linked"

# Force the backend; fail loudly if no zig is bundled:
sx build app.sx --self-contained

# Use a specific zig:
SX_ZIG=/opt/zig-0.16.0/zig sx build app.sx --self-contained

# Opt out, use the system toolchain:
sx build app.sx --no-self-contained

# Dynamic glibc instead of static musl:
sx build app.sx --target linux

# Debug discovery + the exact link invocation:
SX_DEBUG_ZIG=1 SX_DEBUG_LINK=1 sx build app.sx
```
