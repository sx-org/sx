# Bundled `zig` Link Backend for sx — Design Doc & Proposal

> Status: **core landed (macOS / Linux / Windows).** This is the
> design-of-record for how a distributed sx links native binaries
> hermetically. The phased plan lives in
> [../current/PLAN-DIST.md](../current/PLAN-DIST.md); keep the two in sync.
> User-facing surface is documented in `readme.md` (Cross-Compilation §).

---

## Implementation status (landed)

The core backend is implemented and verified on a macOS host:

| Target | Result | Notes |
|--------|--------|-------|
| `--target linux-musl` | static ELF | `zig cc -target x86_64-linux-musl -static` |
| `--target windows-gnu` | PE32+ | `zig cc -target x86_64-windows-gnu` |
| `--target macos` | Mach-O (runs) | `zig cc -target <arch>-macos`, no `-static` |

What shipped, and where it **refined** the original locked decisions:

- **Scope = macOS + Linux + Windows** (not Linux-first). iOS/Android/wasm keep
  their specialized toolchains. (`TargetConfig.zigBackendInScope`.)
- **Auto-activation = a *bundled* zig is found** (a real distribution, or a
  pinned `$SX_ZIG`). A `PATH`-only zig is the dev fallback and engages **only**
  under `--self-contained` — so native dev/CI builds are never silently
  rerouted, across all three OSes. This is the precise meaning of the §5.5
  "zig found (B)" column: **B = bundled**. *(Refinement of "auto when zig
  found": PATH-zig does not auto-engage; the musl-only auto gating considered
  mid-design was dropped in favor of bundled-vs-PATH, which is OS-agnostic.)*
- **No translation table** (per the triple-scheme decision): sx triples are
  passed straight to `zig cc`, and `emit_llvm` runs them through
  `LLVMNormalizeTargetTriple` so vendor-less zig triples (e.g.
  `x86_64-windows-gnu`) land their OS/env in LLVM's canonical positions —
  otherwise "windows" sits in the vendor slot and the object silently falls
  back to ELF. The one unavoidable exception is **macOS**: the object must be
  emitted from Apple's `apple-darwin` triple (LLVM needs it for Mach-O), but
  zig's `-target` parser rejects that scheme, so the *linker* triple alone is
  the vendor-less `<arch>-macos`. One OS-specific line, not a table.
- **New shorthands:** `linux-musl`, `linux-musl-arm`, `windows-gnu` (zig
  scheme). The existing `linux`/`linux-arm` shorthands were also de-vendored
  (`x86_64-linux-gnu`, matching the corpus runner's own expander).

Files: `src/zig_backend.zig` (discovery), `src/target.zig`
(`selectZigLinker` / `emitZigLinkArgv` / `zigTargetTriple` / dispatch in
`link`), `src/ir/emit_llvm.zig` (triple normalization), `src/main.zig`
(`--self-contained` / `--no-self-contained` + shorthands).

Not yet done: distribution packaging (Phase 3 — vendoring `zig` into
`libexec/`), and a corpus regression test (needs the runner to thread
`--self-contained`; manual verification only so far).

The sections below are the original proposal; where they say "Linux-first" or
"follow-up" for macOS/Windows, the table above supersedes them.

---

## 0. TL;DR + feasibility

**Problem.** A distributed `sx` compiler can run on a Linux box (static-LLVM
binary + relocatable `library/`), but it cannot *finish a build*: the final
link step shells out to the host's `cc`, and relies on the host's libc + CRT
objects. No `cc`/glibc/SDK on the box → no binary. That is the gap between
"sx runs here" and "sx is a toolchain here."

**Proposal.** Bundle a pinned `zig` binary inside the sx distribution and use
`zig cc` as the link backend for `sx build`. `zig cc` brings its own lld,
CRT objects, and libc (musl or glibc) for the chosen target. Default Linux
output is **statically-linked musl**, which runs on any Linux with zero
dependencies — the property that makes Zig's own output portable.

**Feasibility: high.** The change is contained:
- The linker is selected through a single hook —
  `TargetConfig.getLinker()` at `src/target.zig:194-196` — and the final
  link argv is built in one place, the Unix `cc`-style branch at
  `src/target.zig:524-564`.
- `zig cc` is a clang-compatible driver, so `-o` / `-L` / `-l` / extra
  objects pass through that branch unchanged. The backend only has to
  prepend `zig cc` and add `-target …` / `-static`.
- Exe-relative resolution (for finding the bundled zig) is already solved
  for the stdlib in `src/imports.zig:204-227` and can be mirrored.
- `sx run` is JIT and never links, so it is wholly unaffected.

The cost is a ~50–60 MB vendored `zig` (binary + its `lib/`) in the
distribution, and version-pinning discipline.

---

## 1. Motivation & background

### 1.1 Current state

| Concern | Today | File |
|---------|-------|------|
| Compiler binary | Self-containable via `-Dstatic-llvm` (no system LLVM) | `build.zig:9-10,156-162` |
| Stdlib | Relocatable, found relative to the exe | `src/imports.zig:204-227` |
| **Linking** | **Shells to system `cc`** | `src/target.zig:524-564` |
| **libc / CRT** | **Provided by the host `cc` driver implicitly** | (no `-lc`/crt passed) |

So two of three legs of a portable toolchain already stand. The third — the
linker and the libc/CRT it pulls in — is the host dependency this design
removes.

### 1.2 Why this matters for distribution

The goal is to hand someone a tarball and have `sx build app.sx` produce a
working binary on a stock Linux machine — a fresh container, a minimal CI
image, a box without `build-essential`. Today that fails at the link step.
Zig solved exactly this problem for its own users; since sx is *built with*
Zig, the cleanest fix is to stand on Zig's hermetic toolchain rather than
re-implement it.

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

### Non-goals (this iteration)
- Reimplementing lld in-process or building libc from source (see §7 —
  Zig already does both; we reuse it).
- First-class Windows/macOS cross-compilation (nearly free as a follow-up,
  but unverified — §11).
- Routing C-import compilation (`src/c_import.zig`, which also shells `cc`)
  through the backend.
- Glibc-floor version pinning (`…-gnu.2.28`); exposed only if needed.

---

## 3. How Zig achieves hermetic builds (the model we're borrowing)

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
than rebuilding its internals** — the whole second column above arrives for
free by vendoring the `zig` binary.

---

## 4. Design overview

`sx build` gains a **link backend** abstraction with two implementations:

- `system_cc` — today's behavior (shell `cc`, host libc).
- `bundled_zig` — shell `<zig> cc -target <triple> [-static] …`.

Selection is automatic (§5.5): if a usable `zig` is discovered and the user
gave no explicit `--linker`, `bundled_zig` is used; otherwise `system_cc`.
The backend plugs into the existing Unix link branch — it contributes the
leading `zig cc` tokens and the `-target`/`-static` flags; the rest of the
argv assembly is unchanged because `zig cc` is clang-compatible.

One supporting change: when `bundled_zig` is active, the triple handed to
LLVM in `src/ir/emit_llvm.zig` is aligned to the link target (`x86_64-linux`)
so the emitted object links cleanly against the selected musl CRT.

---

## 5. Detailed design (the configuration surface)

### 5.1 zig discovery — resolution order

`discoverZig()` (new `src/zig_backend.zig`) returns the first hit:

1. `$SX_ZIG` — explicit override.
2. `<exe_dir>/../libexec/zig/zig` — **install layout** (§6).
3. `<exe_dir>/../../zig-bundle/zig` — **dev vendored layout** (§6).
4. `zig` on `PATH` — **dev fallback** (the only one active today).

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

The default (no `--target`) deliberately differs from the legacy `linux`
shorthand, because portable static output is the entire point.

| `sx` invocation | zig `-target` | Link mode | Portable? |
|-----------------|---------------|-----------|-----------|
| *(no `--target`, Linux host)* | `x86_64-linux-musl` | `-static` | ✅ any Linux |
| `--target linux-musl` *(new)* | `x86_64-linux-musl` | `-static` | ✅ |
| `--target linux` / `linux-x86` | `x86_64-linux-gnu` | dynamic | ❌ host glibc, versioned |
| `--target linux-arm` | `aarch64-linux-musl` | `-static` | ✅ |
| `--target windows` | `x86_64-windows-gnu` | per zig | follow-up (§11) |
| `--target macos` / `macos-arm` | `aarch64-macos` | per zig | follow-up (§11) |

- A **new** `linux-musl` shorthand is added; the existing `linux` shorthand
  keeps its current gnu/dynamic meaning for back-compat.
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

`src/ir/emit_llvm.zig` (`LLVMSetTarget`, ~L246-284) currently uses the host
default triple when `--target` is unspecified (on Linux,
`x86_64-unknown-linux-gnu`). When `bundled_zig` is active, set the module
triple to match the link target (`x86_64-linux`) so codegen and the musl CRT
agree. Pure codegen objects are ABI-compatible across gnu/musl; aligning the
triple removes the edge-case risk (TLS model, stack protector) up front.

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

## 7. Alternatives considered

| Alternative | Why not (now) |
|-------------|---------------|
| **In-process lld + bundled musl sysroot** (sx owns the pipeline; no zig) | Requires a custom LLVM build *with* lld — the Homebrew `llvm@22` here ships none (`liblld*.a`, headers, `ld.lld` all absent) — plus a C++ lld shim and per-arch prebuilt musl. Strictly more work for the same user-visible result. The right *eventual* target if we want zero foreign binaries; tracked as a follow-up. |
| **Full Zig-style: build libc from source on demand** | Most flexible (any arch/libc version, no prebuilt blobs) but the most work; only worth it after the in-process-lld path exists. |
| **Document a hard dependency on system `cc`** | Zero engineering, but defeats the goal — the box still needs `build-essential`. Acceptable only as the current fallback, not the distribution story. |
| **Bundle just `ld.lld` + a musl sysroot (no full zig)** | Smaller than a whole zig, but we'd hand-manage crt object selection, dynamic-linker paths, and import libs — i.e. re-derive what `zig cc` already encapsulates. Bundle-size saving doesn't justify the fragility. |

Vendoring `zig` wins on effort-to-result because sx already builds with Zig:
it's a first-party dependency, not a foreign toolchain, and it unlocks
Windows/macOS targets later for nearly free.

---

## 8. Phasing

Detail in [../current/PLAN-DIST.md](../current/PLAN-DIST.md). Summary:

0. **Resolve zig** — `discoverZig()` + `SX_DEBUG_ZIG`; PATH fallback only.
1. **Link backend** — generalize the linker to a driver argv; emit
   `zig cc -target … -static`; align the emit triple.
2. **Auto activation** — wire the §5.5 truth table; `cc` fallback intact.
3. **Packaging** — `build.zig` `dist` step assembling the §6 tree.
4. **Verify & lock** — `file`/`ldd` shows "statically linked"; host/arch-gated
   corpus test honoring the snapshot-integrity + FFI-cadence rules.

The minimum end-to-end proof is Phases 0+1 against PATH zig.

---

## 9. Open decisions

**Locked:**
- Default Linux ABI = **static musl** (portable output).
- Activation = **auto** when a usable zig is found and no `--linker`.
- Dev uses **PATH zig**; vendoring deferred to Phase 3.

**Still open:**
- Exact spelling of the force flags (`--self-contained` vs e.g.
  `--bundled-linker`); name chosen here pending review.
- Whether auto-mode should *warn* on silent `cc` fallback or stay quiet
  (leaning quiet, with `SX_DEBUG_ZIG` for diagnosis).
- Whether to gate the Phase-4 corpus test behind a `.build` `target`
  sidecar or keep it manual until a Linux CI runner exists.

---

## 10. Risks

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

## 11. Out of scope / follow-ups

- **Windows / macOS targets** via the same `zig cc -target`: nearly free
  after the Linux path, but Apple-SDK and Windows specifics need their own
  verification — not documented as supported until tested.
- **`src/c_import.zig`** still shells system `cc` for C imports in JIT mode;
  route through the backend later.
- **In-process lld** (alternative in §7) as the eventual zero-foreign-binary
  endgame.

---

## Appendix — quick recipes (once implemented)

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
