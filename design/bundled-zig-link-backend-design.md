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
  That is what the "zig found (B)" column of §3.5 means: **B = bundled**.
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

## 1. What `zig cc` supplies

`zig cc` is a clang-compatible driver over the two things a link step would
otherwise take from the host:

1. **In-process lld.** Zig embeds LLVM's lld (ELF/COFF/Mach-O/wasm) and links
   without spawning an external linker.
2. **libc as data.** Zig ships musl *source* (builds `libc.a` + `crt*.o` on
   demand, cached → static, no dynamic linker → portable output) and glibc
   stubs generated from `.abilist` per version. For Windows it ships mingw
   `.def` files and synthesizes import libraries.

So `zig cc -target x86_64-linux-musl -static foo.o -o foo` yields a portable
binary on any host with nothing installed. Vendoring the `zig` binary brings
all of that along; sx carries no linker internals of its own.

---

## 2. Backend selection

`sx build` has two link backends:

- `system_cc` — shell `cc`, host libc.
- `bundled_zig` — shell `<zig> cc -target <triple> [-static] …`.

Selection is automatic (§3.5): a discovered bundled zig with no explicit
`--linker` selects `bundled_zig`; otherwise `system_cc`. The backend plugs
into the Unix link branch of `src/target.zig` — it contributes the leading
`zig cc` tokens and the `-target`/`-static` flags, and the rest of the argv
assembly is shared, because `zig cc` is clang-compatible.

When `bundled_zig` is active, the triple handed to LLVM in
`src/ir/emit_llvm.zig` is aligned to the link target (`x86_64-linux`) so the
emitted object links cleanly against the selected musl CRT.

---

## 3. The configuration surface

### 3.1 zig discovery — resolution order

`discoverZig()` (`src/zig_backend.zig`) returns the first hit:

1. `$SX_ZIG` — explicit override.
2. `<exe_dir>/../libexec/zig/zig` — **install layout** (§4).
3. `<exe_dir>/../../zig-bundle/zig` — **dev vendored layout** (§4).
4. `zig` on `PATH` — **dev fallback**, active only under `--self-contained`.

`<exe_dir>` is resolved exactly as `src/imports.zig` resolves the stdlib.
If none resolve, behavior depends on activation (§3.5): auto-mode silently
falls back to `system_cc`; `--self-contained` errors.

### 3.2 Environment variables

| Var | Effect | Default |
|-----|--------|---------|
| `SX_ZIG` | Absolute path to the `zig` used as the link backend. Highest-priority discovery source. | unset |
| `ZIG_LIB_DIR` | Path to the bundled zig's `lib/`. Needed **only** if `zig` was relocated away from its `lib/`. In the supported layout (§4) they ship together and zig self-locates — leave unset. | unset |
| `SX_DEBUG_ZIG` | Trace discovery: each candidate path and the chosen one (or "none → cc"). Mirrors `SX_DEBUG_STDLIB`. | unset |
| `SX_DEBUG_LINK` | Prints the full link argv — shows the exact `zig cc …` invocation. | unset |
| `SX_STDLIB_PATH` | Stdlib override; unrelated to linking but noted because a full distribution sets neither and relies on exe-relative discovery for both. | unset |

### 3.3 CLI flags (`sx build`)

| Flag | Effect |
|------|--------|
| `--self-contained` | Force `bundled_zig` ON. If no usable zig is found, **error** — do not silently fall back. |
| `--no-self-contained` | Force `system_cc`. |
| `--linker <cmd>` | Explicit linker; supplying it **disables** auto-activation (user's choice wins). To pin a specific zig, prefer `SX_ZIG` + `--self-contained`. |
| `--target <triple\|shorthand>` | Selects target + ABI (§3.4). With `bundled_zig` active and target unspecified on a Linux host → `x86_64-linux-musl` static. |
| `--sysroot <path>` | Forwarded to the linker; rarely needed with `bundled_zig` (zig brings its own sysroot). |

### 3.4 Target → ABI mapping

The default (no `--target`) differs from the `linux` shorthand, because
portable static output is the entire point.

| `sx` invocation | zig `-target` | Link mode | Portable? |
|-----------------|---------------|-----------|-----------|
| *(no `--target`, Linux host)* | `x86_64-linux-musl` | `-static` | ✅ any Linux |
| `--target linux-musl` | `x86_64-linux-musl` | `-static` | ✅ |
| `--target linux` / `linux-x86` | `x86_64-linux-gnu` | dynamic | ❌ host glibc, versioned |
| `--target linux-arm` | `aarch64-linux-gnu` | dynamic | ❌ host glibc, versioned |
| `--target linux-musl-arm` | `aarch64-linux-musl` | `-static` | ✅ |
| `--target windows-gnu` | `x86_64-windows-gnu` | per zig | ✅ |
| `--target macos` / `macos-arm` | `aarch64-macos` | per zig | ✅ |

- `linux-musl` and `linux-musl-arm` select static musl; the `linux` and
  `linux-arm` shorthands stay gnu/dynamic.
- The LLVM emit triple is aligned to the link target so the `.o` links
  cleanly against the selected libc/CRT (§2).

### 3.5 Activation truth table

`B` = a usable zig was discovered (§3.1). Subcommand = `sx build`.

| `--self-contained` | `--no-self-contained` | `--linker` | zig found (B) | Result |
|:---:|:---:|:---:|:---:|--------|
| — | — | no | yes | **bundled_zig** (auto) |
| — | — | no | no | system `cc` (silent fallback) |
| — | — | yes | * | user's `--linker` |
| yes | — | * | yes | **bundled_zig** (forced) |
| yes | — | * | no | **error**: `--self-contained` but no zig |
| — | yes | * | * | system `cc` (forced off) |

- `--self-contained` wins over `--linker`: the forced backend is selected
  before the explicit-linker check, so the `--linker` command is not used.
- `sx run` / `sx ir` / `sx asm` never link → backend not consulted.

### 3.6 Emit-triple alignment

`src/ir/emit_llvm.zig` (`LLVMSetTarget`) uses the host default triple when
`--target` is unspecified (on Linux, `x86_64-unknown-linux-gnu`). When
`bundled_zig` is active, the module triple is set to match the link target
(`x86_64-linux`) so codegen and the musl CRT agree. Pure codegen objects are
ABI-compatible across gnu/musl; aligning the triple removes the edge-case risk
(TLS model, stack protector).

---

## 4. Distribution layout (packaging)

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
- Pinned zig version: **0.16.0** (matches the build toolchain). The release
  manifest records the exact version — the `zig cc` CLI is not interchangeable
  across versions.
- Vendor the matching zig release per host os/arch from ziglang.org at
  package time.

---

## 5. Scope

- The backend covers `sx build` for macOS, Linux and Windows targets.
- `src/c_import.zig` shells the system `cc` for C imports in JIT mode; it does
  not go through the backend.
- sx consumes the `zig cc` driver: it neither embeds lld nor builds libc from
  source, and it pins no glibc floor (`…-gnu.2.28`).
- System `cc` stays the fallback linker, and in auto mode an explicit
  `--linker` wins.

---

## 6. Constraints

- The distribution carries ~50–60 MB of vendored zig (binary + `lib/`).
- The no-`--target` default (static musl) differs from the `linux` shorthand
  (dynamic gnu); `linux-musl` names the static path explicitly.

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
