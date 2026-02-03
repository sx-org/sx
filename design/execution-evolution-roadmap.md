# Execution-Model Evolution — Roadmap (comptime JIT · async · concurrency · hot-reload)

> Status: **exploratory design-of-record.** Captures the forward plan for sx's
> execution model across five interlocking threads. Not yet an active
> `PLAN-*`/`CHECKPOINT-*` stream — this is the shared design the streams would be
> carved from. Cross-platform shipping (the bundled-zig backend + the sx bundler)
> is **already landed**; see [bundled-zig-link-backend-design.md](bundled-zig-link-backend-design.md)
> and [../current/PLAN-DIST.md](../current/PLAN-DIST.md).

---

## 0. The thesis

sx's compiler stays small by pushing capability into **library sx + three general
primitives** (`inline asm`, `extern`/`export`, `atomics`) rather than baking
features into codegen. Concretely:

- **Async is a library, not a language feature** — colorblind, stackful fibers
  behind an `Io` interface (Zig-inspired). No function coloring, no
  async→state-machine transform. The implementation is pure sx down to a per-arch
  inline-asm context switch.
- **Comptime gains a JIT escape hatch** — the interpreter stays the default
  (debuggable, portable), but drops to a host-JIT for the one thing it can't
  walk (inline asm) and, later, for whole fragments (the bundler).
- **One shared substrate** — a persistent ORC LLJIT + host-target emitter — serves
  comptime-asm, the bundler, and JIT-resident hot-reload.

The honest trade is **small *surface*, but each primitive is *deep*** — not "small
compiler." The net-new **compiler** obligations this plan adds (all verified absent
today): **atomics lowering** (N1), **generic enums** `enum($T)`, **`declare` +
`define` + `type_info` + `field_type`** (comptime type metaprogramming), **`callconv(.naked)`**,
**repointable-`context` codegen** (+ per-fiber stack-limit), the **S1 persistent JIT
spine**, **C1 thunk synthesis**, **comptime-asm lifting** (C3), and (later) the **S2
ORC C++ shim**. Async itself is genuinely a library; the *enabling primitives* are a
major codegen/runtime investment. Already landed: `inline asm` (in flight),
`extern`/`export`, the `!`/`try`/`catch`/`onfail`/`raise` ERR stream, value-level
reflection, the `sx run` ORC LLJIT, and the host-FFI trampolines.

---

## 1. The spine (shared substrate)

| ID | Piece | What | Size |
|----|-------|------|------|
| **S1** | Persistent JIT executor | A long-lived ORC LLJIT + a host-triple `LLVMEmitter` + a compiled-fragment cache, plumbed into the interpreter. Today the LLJIT exists only for `sx run`'s `main` ([target.zig:319](../src/target.zig#L319)); the emitter carries one target machine ([emit_llvm.zig:274](../src/ir/emit_llvm.zig#L274)). | L |
| **S2** | ORC C++ shim | `MachOPlatform::Create` + redirectable/lazy-reexport symbols. The bare `LLVMOrcCreateLLJIT` can't do thread-locals, C constructors, or symbol redefinition — the wall the C-with-sx JIT spike hit (`_Thread_local` SIGABRT; `errors-*` examples crashed). Required by any non-trivial JIT or symbol repoint. | M |

S1/S2 are the spine: built once, consumed by **C1** (the FFI thunks — the main
near-term consumer), **C3**, and (later) **R2**. S1 alone suffices for C1/C3 (bare
calling/asm thunks — no TLS/ctors); S2 is only needed for R2 and JIT-ing C-with-sx.

---

## 2. Comptime / build layer

| ID | Piece | Unblocks | Depends | Size |
|----|-------|----------|---------|------|
| **C1** | **Real comptime FFI — JIT calling-thunks (LLVM = single ABI authority).** Trivial calls (scalar/ptr/string args, single-reg return) keep the existing `host_ffi.zig` trampoline fast-path; everything else (floats, structs-by-value, aggregate returns, >8 args, varargs) synthesizes a per-signature thunk, JIT-compiles it via **S1**, and calls it with an args buffer the interpreter fills by known layout (`type_info`). **LLVM emits the ABI-correct call — the same lowering as runtime codegen — so comptime and runtime FFI share ONE ABI implementation.** Rejected: libffi (foreign 2nd ABI impl), hand-rolled sx+asm (3rd impl + drift risk + needs C3 to run its own asm leaf anyway). | struct/string/slice/float signatures at comptime; full C interop in `#run`; lifts the bundler's API straightjacket; unifies comptime+runtime FFI | S1 (fast-path: none) | L |
| **C2** | **`#compiler` → `extern` collapse** — BuildOptions hooks become real exported C symbols resolved through C1; `*BuildConfig` threaded via global/handle; delete `.compiler_expr`/`compiler_call`/Registry. | one FFI mechanism, not two | C1 (`extern`/`export` already shipped) | M |
| **C3** | **Comptime asm via host-JIT** — stop bailing on `inline_asm` ([interp.zig:1019](../src/ir/interp.zig#L1019)); lift the block (operand model at [inst.zig:354](../src/ir/inst.zig#L354): inputs/`out_value`/`out_place`/`out_ty`/clobbers) to a host-arch thunk via `LLVMGetInlineAsm`, JIT, call through C1, cache by template+sig. | running asm-containing code at comptime | S1, C1 (+S2 non-trivial) | M |
| **C4** *(DROPPED)* | **JIT-the-bundler** — **not built** (Decision 6). Interp+C1 is the shipping bundler (I/O-bound, so native speed is moot; C1 closes the only capability gap). Remains an always-available S1 optimization if profiling ever shows the bundler's *own logic* is a hotspot. | — | — | — |

**Residue:** cross-arch comptime asm (C3) can't run on the host — narrows the bail
to the cross-compile case; needs a sharp diagnostic ("asm targets `<arch>`, host
is `<host>`").

---

## 3. Concurrency primitives (atomics + threads)

> **Why this is its own section:** we are doing **multiple OS threads**, so the
> async runtime and any lock-free structure need real atomics. OS threads already
> exist; atomics do not.

| ID | Piece | State | Size |
|----|-------|-------|------|
| **N1** | **Atomics — NET-NEW compiler feature.** Atomic load/store/RMW (`add/sub/and/or/xor/swap` + `fetch_min`/`fetch_max`; no `nand`), `compare_exchange`/`_weak` (→ `?T`, **null = success**), and fences, with orderings (relaxed/acquire/release/acq_rel/seq_cst). LLVM provides all — an **emit** feature, not a runtime library. **Surface LOCKED = `Atomic($T)` wrapper + `Ordering` enum** (not `@atomic_*` — `@` is address-of in sx). | **fully net-new** — zero LLVM `atomicrmw`/`cmpxchg`/`fence` emission **and no atomics scaffolding**: `Atomic`/`Ordering` exist nowhere in `library/`, and the only "ordering" in `lower.zig:1400` is *comparison* ordering (`< <= >=`), unrelated to memory ordering | M |
| **N2** | **OS threads + pthread Mutex/Cond + worker Pool** | **landed** — [std/thread.sx](../library/modules/std/thread.sx) (`pthread_create`/`join`/`detach`, in-place `Mutex`/`Cond`, bounded `Pool`). NOTE: pthread mutex **blocks the OS thread** — it is *not* fiber-aware (it would park every fiber on that thread); fiber-aware sync is N3, built on N1. | — |
| **N3** | **Fiber-aware sync** — mutex / channel / waitgroup that **suspend the fiber**, not the OS thread. Hybrid: atomic fast-path (N1) + fiber-suspend slow-path (A2/A5). Distinct from the pthread primitives in N2. | new library | M |

**Compiler obligation for N1:** the emit must map sx orderings to LLVM's and **not
reorder across atomics/fences**. Comptime is single-threaded, so the interpreter
can treat atomic ops as ordinary ops (seq_cst is trivially satisfied with one
thread) — no interp atomics machinery needed.

**N1 is a prerequisite for M:N scheduling (A5) and N3, and is broadly useful**
(lock-free queues, refcounts, the allocator). It is the load-bearing new primitive
this revision adds.

---

## 4. Async — colorblind, stackful, pure-sx

**Commitment:** no function coloring, no async→state-machine transform. Async is a
capability carried in `context` (like `context.allocator`), not a property of a
function's signature. A function does I/O through `context.io`; whether the call
suspends is decided by the `Io` *implementation*, transparently.

| ID | Piece | Notes | Size |
|----|-------|-------|------|
| **A1** | **`Io` interface + `context.io`** — a protocol/vtable threaded like `Allocator`. `io.async(fn,args) → Future`, `future.await`, cancellation. | leverages protocols + context | M |
| **A2** | **Stackful coroutine runtime — in sx lib, NOT a compiler builtin.** The context-switch is a `callconv(.naked)` sx fn with an inline-asm body (save callee-saved + SP/LR into `*from`, load from `*to`, `ret`); fiber bootstrap + stack alloc (`mmap`+guard via `extern`) also sx. The **compiler's** job is only (a) the general primitives — inline asm, `abi(.naked)`, atomics — and (b) **fiber-safe codegen**: `context` is **already an implicit `*Context` param** (not TLS — see §7 step 5), so the switch repoints it for free by swapping the per-fiber root; the open work is the per-fiber root + push-stack storage, and stack-limit guards (**mandatory, not optional** — fixed mmap stacks without a guard corrupt neighbors silently) reading from a swappable per-fiber location. Most arch-delicate sx in the tree (must match the platform callee-saved set + the compiler ABI), but it's inspectable sx, not a black box. | per-arch, arch-gated; co-validate vs codegen | M |
| **A3** | **Event-loop `Io` impls** — kqueue / epoll / io_uring drive readiness, then the (now-ready) syscall via C1. Plus a trivial **blocking `Io`**. | pure sx around syscall `extern`s | L |
| **A4** | **Stdlib I/O rework** — fs/socket/process take/use `context.io` instead of raw blocking syscalls, so existing calls participate in async. | mirrors the allocator-threading rule | M |
| **A5** | **Schedulers — M:1 → N×(M:1) → M:N, all sx std-lib `Io` vtables (committed; M:N last, not deferred).** M:1 first (minimal vehicle to validate the colorblind stack; covers I/O-bound). N×(M:1) = first parallel step (per-thread M:1 loops + `std/thread.sx` spawn; shared state uses N1 atomics — expected under parallelism, not a wart). M:N work-stealing last (most machinery: thread-safe steal queues + migration + errno/TLS discipline). All over N1 atomics + the A2 asm context-switch + `extern` syscalls. **pinning** API for thread-affine work (UI main thread, GL context). | see §4.3 | M (M:1) / M (N×M:1) / L (M:N) |

### 4.1 How control enters sx (the colorblind model)

- **sx→sx is ordinary.** The whole call chain lives on the fiber stack; a suspend
  at a leaf `io.*` freezes the native stack verbatim. No frame knows it suspended.
  **Zero special handling at call boundaries** — that's the point.
- **Three inbound boundaries** where the runtime enters sx:
  1. **Task entry** (`io.async(fn)`) — a trampoline starts `fn` on a fresh fiber
     stack via the normal calling convention.
  2. **Resumption** — a context-switch (asm), *not* a call; sx continues mid-stack.
  3. **C callback → sx** — must be `export`/`callconv(.c)`; runs on the event-loop
     stack (not a fiber) so it **cannot itself suspend** — it may resume/enqueue a
     fiber or run a non-suspending sx fn to completion (leaf-only).

### 4.2 `context` is fiber-local (the key obligation)

`context.io`/`context.allocator`/the `push Context` stack are dynamically scoped.
Fibers time-share OS threads (and **migrate** under M:N), so `context` must travel
**with the fiber** — saved/restored on every context-switch — **never a raw TLS
read.** A spawned task snapshots the spawner's context, then evolves its own
`push Context` stack. This is the CLAUDE.md "capture your owning allocator" rule one
level up: ambient state that outlives a suspension point must be carried by the
fiber.

### 4.3 Threads & the two hazard classes (why atomics)

| Model | Parallelism | Migration | Hazards |
|-------|-------------|-----------|---------|
| **M:1** (1 OS thread) | none | none | cooperative, race-free — simplest |
| **N×(M:1)** (per-thread schedulers, no migration) | yes | none | **data races** on shared state → atomics/locks |
| **M:N** (work-stealing) | yes | yes | data races **+** TLS-migration hazards |

- **Parallelism hazard** (any N>1): shared mutable state races → needs **N1
  atomics** + N3 fiber-aware sync. The M:1 "no locks" simplicity is gone.
- **Migration hazard** (M:N only): a fiber that moves threads across a suspend
  reads the *wrong* thread's TLS. **`errno` must be captured immediately** after
  each syscall; **`context` must be fiber-local** (§4.2) — non-negotiable under M:N.
- **Pinning** (`io.pinToThread()`): some work must stay put — the **UI main
  thread** (UIKit/macOS/Android — directly the app targets in §6), OpenGL
  current-context, TLS-using FFI. M:N needs a "don't migrate / main-thread-only"
  fiber attribute (Go's `LockOSThread`).

### 4.4 Pure-sx boundary

Everything is sx except the irreducible FFI floor: the **asm context-switch**
(per-arch, in `.sx`), **syscall `extern`s** (kernel-implemented, like any libc
binding), and **raw stack memory** (`mmap`). The schedulers, event loops, futures,
cancellation, and sync primitives are ordinary sx. Payoff: **swappable `Io`
vtables** — blocking, io_uring, kqueue, a **mock `Io`** for tests, a
**deterministic-simulation `Io`** (fake clock, scripted readiness) for reproducible
concurrency tests — all libraries.

### 4.5 Comptime async = blocking `Io`

At comptime install the **blocking `Io`**: `io.*` just blocks; no fibers, no
scheduler, no suspend. Same source, different vtable. The interpreter never needs
suspend/resume, and the FFI (C1) needs no async awareness. This is *why* the
colorblind model resolves comptime async for free.

### 4.6 Syntax surface (grounded against the grammar)

All of the concurrency/atomics surface lands on **existing** sx grammar — `enum`
tagged unions + `if x == { case … }` match ([specs.md:364,408](../specs.md#L408)),
first-class **tuples** with named fields ([specs.md:815-852](../specs.md#L815)),
`=>` closures, `struct($T)` generics, `callconv(...)`, and the ERR keywords
(`try`/`catch`/`onfail`/`raise`/`error`). `race`/`async`/`await`/`atomic` are **not
reserved words** ([specs.md:168](../specs.md#L168)), so they stay library
types/methods — no keyword additions. One genuinely-new compiler capability is
required (see end).

**Atomics (N1) — generic wrapper type.**
```sx
Ordering :: enum { relaxed; acquire; release; acq_rel; seq_cst; }
Atomic   :: ($T: Type) -> Type #builtin;   // atomicity carried by the type

counter : Atomic(i64) = .init(0);
counter.store(0, .relaxed);
n    := counter.load(.acquire);
prev := counter.fetch_add(1, .seq_cst);            // + fetch_sub/and/or/xor (min/max: open)
old  := counter.swap(42, .acq_rel);
got  := counter.compare_exchange(old, new, .acq_rel, .acquire);        // strong → ?T (null = success)
got2 := counter.compare_exchange_weak(old, new, .acq_rel, .acquire);   // may fail spuriously; for retry loops
fence(.seq_cst);
```
- CAS takes **two orderings** (success, failure); failure ordering may not be
  `release`/`acq_rel` nor stronger than success — enforce in the compiler.
- Weak vs strong matters on **aarch64** (LL/SC) — weak in a loop is the idiom;
  both compile identically on x86.

**Channels (N3) — methods only (no `<-`); `recv` returns a tagged union (not `(v, ok)`).**
```sx
RecvResult :: enum($T: Type) { value: T; closed; }        // ordinary generic enum (not the race-synthesized union)
TryResult  :: enum($T: Type) { value: T; empty; closed; } // non-blocking: 3 states a bool can't express

ch := Channel(i64).make(16);     // capacity; .make() unbuffered
ch.send(v);
if ch.recv() == { case .value: (v) { use(v); }  case .closed: { /* drained */ } }
ch.close();
// ergonomic layer: `for ch (v) { … }` consumes until closed, hiding RecvResult
```

**Fiber-aware locks (N3) — explicit lock + `defer` (no guard sugar).**
```sx
m : Mutex;
m.lock();  defer m.unlock();
```

**Futures & spawn (A1).**
```sx
f := context.io.async(worker, arg);     // Future(R)
r := f.await();                         // suspends this fiber
f.cancel();
d := context.io.timeout(5000);          // a Future too — raceable like any other
```

**Pinning (A5) — spawn attribute, accepts a thread handle.**
```sx
PinTarget :: enum { any; main; on: Thread; }            // default = .any (may migrate)
f := context.io.async(render, pin = .main);
f := context.io.async(worker, pin = .on(some_thread));
```

**`race` (Zig model — over futures, named tuple in → synthesized tagged-union out).**
The input is a **named tuple** (positional also allowed → `.0`/`.1` tags); the
result is an anonymous tagged union whose variants mirror the tuple's labels, each
payload = that field's `Future(T)` projected to `T`. Losers are **cancelled and
joined** before `race` returns (structured).
```sx
fa := context.io.async(read_a, conn);     // Future(A)
fb := context.io.async(read_b, conn);     // Future(B)

winner := context.io.race((a: fa, b: fb));   // RaceResult = enum { a: A; b: B }
if winner == {
    case .a: (v) { handle_a(v); }            // v : A
    case .b: (v) { handle_b(v); }            // v : B
}
// positional form: race((fa, fb)) → tags .0 / .1
```
The Go-style handler-map and the map literal that propped it up are **dropped** —
`race` over futures subsumes select, and cancellation handles the losers.

**Cancellation rides ERR.** A cancelled `io.*` **raises**; the fiber unwinds
through `defer`/`onfail` (`try`/`catch`/`raise` are real keywords). Cancellation is
**cooperative** (observed only at suspend points — every `io.*` is a cancellation
point) and **structured** (`race` joins losers' teardown before returning). No
parallel unwind path — it reuses the error channel.

**Context switch (A2).**
```sx
swap_context :: (from: *Fiber, to: *Fiber) callconv(.naked) {
    asm { /* save callee-saved + SP into *from; load from *to; ret */ };
}
```
`callconv(.naked)` ≠ `callconv(.c)`: **no prologue/epilogue/frame** — required
because a context switch deliberately makes SP-in ≠ SP-out (a `.c` epilogue would
restore from the wrong stack). Body is a single `asm` block; you emit your own
`ret`. Args arrive in ABI registers, read directly from asm.

**One new compiler capability (gates `race`):** *comptime tuple→tagged-union
synthesis.* Reflection today only **reads** types (`field_count`/`field_name`/
`type_of`); `RaceResult(T)` must **construct** an anonymous `enum` from a tuple's
`(label, payload-type)` pairs. Supporting pieces: a `field_type($T, i) -> Type`
reflection accessor (we have value-level `field_value` + `type_of`, but type-only
field projection is missing) and `Future(T) → T` projection (falls out of
generics). This is the generic "derive a sum from a product" — useful beyond
`race`.

---

## 5. Dev loop / hot-reload

| ID | Piece | Notes | Depends | Size |
|----|-------|-------|---------|------|
| **R1** | **Hot-reload (dylib swap)** — host owns `State`+allocator; reloadable module is a `.dylib` with a fixed `export` interface; watch→rebuild→`dlopen`→rebind→`dlclose`. State survives (host-owned). | leans on `export` (shipped); sidesteps S2; native | — | M |
| **R2** | **Hot-reload (JIT-resident)** — program runs under S1's LLJIT; reloadable calls route through ORC indirection stubs, repointed on change. Finer granularity; same spine. | | S1, S2 | L |
| **R3** | **Incremental compilation** — dependency tracking + recompile-only-changed. Perf enabler; coarse per-file v1 suffices first. | | — | L |

**Core rule:** the data that must survive a reload cannot be owned by the code that
reloads. Code/state separation — the CLAUDE.md owning-allocator discipline, one
level up.

**Residue — state migration on layout change:** body-only changes hot-swap;
layout/signature/global-type changes are **detected** (compare new vs running
`State` layout via `types.zig`) and trigger **rebuild+restart**. Migration hooks
(`on_reload(old)→new`) are a hard later item. Design against *silent* corruption.

---

## 6. Cross-platform (mostly landed) — from a macOS laptop

### 6.1 Landed

| Capability | State | Reach from a mac |
|---|---|---|
| `extern`/`export` C linkage | done (replaced `#foreign`) | all targets |
| Bundled-`zig cc` cross-link backend | Phases 0–2 done; packaging pending | **macOS, Linux(-musl/static), Windows(-gnu)** verified |
| sx-side bundler (`.app`/`.apk`) | done | macOS, iOS sim/device, Android |
| JIT `sx run` (ORC LLJIT) | done | host |
| Target shorthands | done | `macos[-arm]`, `linux[-musl[-arm]]`, `windows[-gnu]`, `ios[-arm]`, `ios-sim[-arm/-x86]`, `android[-arm64/-x86_64]`, `wasm` |

### 6.2 Workflows

```sh
# macOS (native): inner loop is JIT; ship is Mach-O / .app
sx run app.sx
sx build app.sx -o app
sx build app.sx --bundle MyApp.app

# Linux (cross, landed killer feature): static, zero-dep ELF
sx build app.sx --target linux-musl -o app      # scp anywhere, runs

# Windows (cross, landed, MinGW path): PE32+
sx build app.sx --target windows-gnu -o app.exe # cf. example 1660 (win32)

# iOS simulator (mac-only host)
sx build app.sx --target ios-sim --bundle App.app

# iOS device — signing threaded via the build program (BuildOptions setters)
#   #run { o := build_options(); o.set_bundle_id(...); o.set_codesign_identity(...);
#          o.set_provisioning_profile(...); }
sx build build.sx --target ios --bundle App.app

# Android (cross + bundle): javac → d8 → aapt2 → zipalign → apksigner, then adb
sx build app.sx --target android --apk app.apk
```

### 6.3 Where the roadmap lights up cross-platform

- **C1 + C4** → the iOS/Android **bundlers** (orchestrate ~a dozen host tools at
  comptime; biggest win; always host-arch so no cross-arch risk).
- **R1/R2 + A1–A5** → the **inner dev loop for non-host targets**: push-a-dylib +
  remote-trigger-reload over an async laptop↔device channel — a capability that
  *doesn't exist today* short of full rebuild+reinstall.
- **A1/A2 colorblind `Io`** → the dev tooling is itself async, and the **same
  networking code runs blocking inside the bundler** (`adb push`) and async in the
  live session — no coloring.
- **Pinning (A5)** → the UI render fiber pins to the main OS thread on every app
  target.

**The single hard constraint the matrix exposes:** cross builds mean target arch ≠
host arch, so **C3's residue bites** — comptime/`#run` code reaching *target-arch*
inline asm can't execute on the mac. Native macOS dev never hits it; every cross
target must gate comptime asm to host-arch (`when host_arch == …`) or get a loud
diagnostic.

---

## 7. Linear build sequence (async-first — no parallel streams)

Single ordered list; deps satisfied at every step. **Async-first** (user-chosen): the
async story needs no JIT spine (syscalls use the existing trampoline FFI; comptime
async = blocking `Io`), so the FFI/JIT cluster comes *after*. C4 is omitted (dropped —
an S1 optimization if ever profiled). Net-new compiler prereqs (per the codebase
grounding) are explicit steps, not buried.

**Foundations — compiler primitives the async story needs (all net-new):**
1. **N1 — Atomics lowering.** IR/inference scaffolding exists; add LLVM
   `atomicrmw`/`cmpxchg`/`fence` emission + orderings. Surface = `Atomic($T)` wrapper.
   Gates channels/N3 + parallel schedulers.
2. ~~**Generic enums** `enum($T)`~~ **DROPPED.** `RecvResult($T)`/`TryResult($T)` are
   **type-fns over `declare`/`define`** (step 3), not a new `enum($T)` language
   feature — and type-fns (user `($T)->Type` in type position) **already work** (e.g.
   [`Make`](../examples/0208-generics-value-param-type-function.sx),
   [`Complex`](../examples/0201-generics-generic-struct.sx)). A declarative `enum($T)`
   surface, if ever wanted, is later *sugar* desugaring to a type-fn over the primitives.
3. **`declare`/`define` (construction) + `type_info`/`field_type` (reflection)** —
   comptime metaprogramming floor. Gates `race` synthesis **and** channel
   `RecvResult`/`TryResult` (all sx type-fns over `declare`/`define`; **generic-enum
   syntax dropped**). **Validated against the codebase (3 reviewers): a small
   extension reusing existing machinery throughout — not net-new architecture.**
   Contracts:
   1. **Nominal identity via type-fn memoization** — type-fns dedup by mangled
      `(fn,args)` name (generic.zig) + `findByName`, so `RecvResult(i64)` is one
      `TypeId` and the body runs once. (NOT structural dedup — enums are nominal via
      `nominal_id`, types.zig.)
   2. **Functional through codegen** — layout / construct / match+exhaustiveness /
      `toLLVMType` / `type_name`+format are **all type-table-driven, zero AST
      coupling**, so a backing-decl-less minted enum flows through unmodified.
   3. **Validate loudly** at the single `intern`/`internNominal` choke point
      (types.zig): reject dup variants / bad backing / unresolved payloads.
   4. **Comptime-only, JIT-free** — a type-table op in the interp; no S1 dependency
      (keeps construction, hence channels + `race`, off the JIT critical path).
   5. **Reference-based self-reference** — `*Self`/`[]Self` payloads via the
      explicit `declare()` → `define(handle, …)` split (the handle predates its
      body, so it can be referenced inside it); **by-value recursion rejected**
      (loud, infinite size). Reuses the reserve-placeholder→complete path recursive
      *source* types already use (nominal.zig, types.zig).
   - **Type-minting precedents (7):** monomorphization, protocol vtables, tuples,
     vector/array, ptr/slice ctors, FFI stubs, **type-fn instantiation** — all
     construct `TypeInfo` programmatically + `intern()`. **Residual = plumbing, not
     capability:** name minted results by the instantiation's mangled name + input
     validation.
4. **`abi(.naked)`** — *correction:* `CallConv` was renamed `ABI` and **already carries
   `.naked`** (ast.zig:142, "naked, no prologue/epilogue") during the compiler-API
   stream — so this is NOT "extend the enum." `.naked` is an **inert label today**:
   `type_resolver.zig:237` maps it to `.default` CC and emit_llvm emits **no** naked
   attribute. The net-new work is making `.naked` actually emit LLVM `naked` + skip
   prologue/epilogue lowering. Gates A2.
5. **Per-fiber `context` root + push-stack storage** — *correction:* `context` is
   **already an implicit `*Context` parameter** (comptime_vm.zig:392, lower.zig:257
   "Implicit Context parameter machinery"), **not raw TLS** — so the "lower as swappable
   indirection, never raw TLS" framing guards a non-problem; it already rides the fiber
   stack. The real, **currently-unsized** obligation is (a) where a freshly-spawned
   fiber's *root* `Context` comes from and (b) where `push Context` frames live (caller
   stack ⇒ fiber-local for free; a global root ⇒ must become per-fiber) + per-fiber
   stack-limit. **Ground the current mechanism before sizing this.** Prerequisite of
   A2, not a successor.

**Async runtime — sx lib over the primitives:**
6. **A1 — `Io` interface + `context.io` + `Future` + `cancel()` API.**
7. **A2 — fiber runtime** (naked context-switch asm, bootstrap, `mmap` stacks).
8. **A3 — blocking `Io` → deterministic-sim `Io` (keystone, calibrated) → event-loop `Io`.**
9. **A5·M:1 — single-thread scheduler.**
10. **N3 — fiber-aware sync** (channels/mutex/waitgroup; `recv → RecvResult`).
11. **A6 — Cancellation.** `.canceled` in the `!` channel (model a); per-fiber atomic
    flag (N1); every `io.*` a cancellation point; structured cancel-and-join; **masked
    during cleanup**.
12. **A4 — stdlib I/O rework** (fs/socket/process onto `context.io`).
13. **A5·N×(M:1)** — first parallel (errno-capture + `context`-fiber-local discipline).
14. **A5·M:N** — work-stealing (steal queues + migration + pinning).

**Then comptime / FFI / JIT cluster:**
15. **S1 — persistent JIT spine** → 16. **C1 — real FFI (LLVM = ABI authority, on S1)**
    → 17. **C2 — `#compiler`→`extern`** → 18. **C3 — comptime asm** (S1 + C1; +S2 if
    TLS/ctors).

**Deferred tail:**
19. **S2 — ORC C++ shim** (highest-risk — see §8; macOS `MachOPlatform`; ELF/COFF
    unplanned) → 20. **R1 — dylib reload** (shipped `export`) → 21. **R2 —
    JIT-resident reload** (S1 + S2; **↔ async live-fiber coupling**, §8) → 22. **R3 —
    incremental compilation**.

Hard edges to remember: **C1 depends on S1** (the non-trivial FFI cases); **C3 depends
on C1** (calls through its thunk path); **R1/R2 couple to the async runtime** (can't
hot-swap code with live suspended fibers — runtime + long-lived fibers stay
persistent, only leaf logic reloads).

---

## 8. Irreducible hard problems (detect-and-degrade, don't pretend)

1. **State migration across layout change** (R1/R2) → v1 detects + rebuild/restart;
   migration hooks later.
2. **Cross-arch comptime asm** (C3) → can't run on host; narrows the bail + loud
   diagnostic; gate to host-arch.
3. **M:N migration hazards** (A5) → errno-capture discipline + fiber-local context
   (mandatory), pinning for thread-affine work.

### 8.1 Highest technical risks (from review — ranked, async-first lens)

1. **A2 context-switch correctness** (in the async critical path). Silent stack
   corruption, per-arch, **untestable by the deterministic-`Io` harness** (it tests
   *scheduling*, not the *switch*); a one-register slip is invisible until it crashes
   on the right arch. Couples *library asm* to the *compiler ABI* — ABI drift breaks
   it silently later. → needs a dedicated **switch-stress test** (§10).
2. **`define` → tagged-union → match-codegen** (gates `race` + channels).
   **DE-RISKED by review** (§7 step 3): all enum stages are type-table-driven with
   zero AST coupling, identity is handled by existing type-fn mangled-name memoization,
   and forward-declaration for self-ref already exists. Residual is *plumbing*
   (name minted results by mangled name + input validation), not new architecture.
3. **Deterministic-`Io` is the test keystone yet itself uncalibrated** — a buggy
   deterministic scheduler yields deterministic-*wrong* stdout that snapshots lock in.
   → calibrate against the blocking `Io` / property-test fixed order (§10).
4. **`context`-fiber-local + errno discipline** (A5 M:N). "Non-negotiable" but
   enforced by manual rule, not the compiler; M:1 can't even exercise migration.
5. **S2 ORC shim** (deferred, but highest-risk when reached): only C++ in the tree,
   **already failed a spike** (`_Thread_local` SIGABRT), `MachOPlatform` is
   macOS-specific — **Linux/Windows JIT-resident reload + non-Mac TLS/ctor JIT have no
   named plan**. One "M" box hides a per-OS effort.
6. **C1 args-buffer layout-vs-ABI** — "LLVM emits the call" covers the *call*, not the
   interpreter's *buffer pack* from `type_info`. Disagreement on edge layouts
   (over-aligned/empty structs, aarch64 small-struct register splitting, `bool`) =
   silent comptime corruption. → adversarial layout cases (§10).

---

## 9. Decisions log (all resolved)

**Sequencing — locked:** **async-first** (§7). The async cluster (steps 1–14)
precedes the FFI/JIT cluster (15–18) because async needs no JIT spine. **Cancellation
(A6) = model (a)** — a `.canceled` variant in the **existing `!` error channel** that
`io.*` already returns (I/O is inherently fallible, so `io.*` is already `!`-typed —
the "keep calls clean" argument for the non-local-`raise` model is moot). Reuses
`!`/`try`/`catch`/`onfail`; no new unwind primitive. **Net-new prereq surfaced by
grounding:** `callconv(.naked)` (only `.default`/`.c` today). **Generic enums dropped**
— `RecvResult($T)`/`TryResult($T)` are **type-fns over `declare`/`define`** (type-fns
already work in type position, e.g. `Make`/`Complex`), so no `enum($T)` feature is
needed; construction carries two contracts (deterministic identity + functional-enum
output, §7 step 3).

**Locked (see §4.6 for the grounded surface):**
- **N1 atomics surface = generic wrapper `Atomic($T)`** + `Ordering` enum, `.init`,
  `compare_exchange`/`_weak` returning `?T` (**null = success** — pinned, opposite of
  most priors). (Not `@atomic_*` builtins — `@` is address-of in sx.) **RMW set** =
  `add/sub/and/or/xor/swap` + `fetch_min`/`fetch_max` (free from LLVM); **no `nand`**.
- **`race` = over futures** (Zig model), **single named-tuple in** (`race((a: fa, b:
  fb))`) → synthesized tagged-union out; Go-style handler-map + map literal
  **dropped**. **No `async` spawn-sugar** — always `context.io.async(...)`.
- **Channels** = `send`/`recv` methods (no `<-`); **`recv` returns a tagged union**
  `RecvResult($T){ value; closed }` (not `(v, ok)`), `try_recv` → `{ value; empty;
  closed }`; optional `for ch (v) {…}` iteration sugar. **locks** = `lock()` + `defer
  unlock()` (no guard sugar). `race`/`async`/`await` stay library, not keywords.
- **Comptime type metaprogramming = `declare`/`define` (construct) + `type_info`
  (reflect) builtins only** (Zig `@Type`/`@typeInfo` model). **Everything else is sx
  lib** — `make_enum`, the channel result types, `field_type`, `RaceResult`.
  Construction coverage starts at **enum**, grows to struct/tuple later. `Future($T)`
  exposes `Value :: T` so `Future(X)→X` is plain member access
  (no `type_arg` builtin).
- **C1 FFI engine = LLVM as single ABI authority** — per-signature JIT calling-thunks
  via S1 (LLVM emits the ABI-correct call, same as runtime codegen); trampoline
  fast-path for trivial calls. **libffi/dyncall + hand-rolled-sx rejected** (2nd/3rd
  ABI impl; hand-rolled needs C3 for its own asm leaf anyway). Promotes **S1 to
  foundational** (shared by C1, C3).

**Scheduler (Decision 5) — locked:** **M:1 → N×(M:1) → M:N**, all **sx std-lib `Io`
vtables** (compiler only provides N1 atomics + the A2 asm context-switch + `extern`
syscalls). M:1 ships first (validates the colorblind stack, covers I/O-bound);
N×(M:1) is the first parallel step; **M:N is last in sequence but committed — not
deferred.** Data races under parallelism are expected and handled with atomics +
fiber-aware sync — that *is* parallelism, not a wart; M:1's lock-freedom is just a
property of the single-threaded case.

**Deferred, orthogonal additions (Decisions 6–7) — both addable later without
revisiting anything locked:**
- **C4 (Decision 6) — fully orthogonal; not built now.** Pure deferred optimization
  riding S1 (already present for C1/C3): JIT the bundler subgraph instead of
  interpreting it. Zero coupling — same bundler sx, same C1 FFI. Apply only if
  profiling ever shows the bundler's *own logic* is a hotspot (it's I/O-bound, so
  unlikely). Interp+C1 is the shipping bundler.
- **Hot-reload (Decision 7) — deferred; mechanism additive.** Substrate ready: R1
  (dylib-swap) needs only shipped `export`; R2 (JIT-resident) needs S1 + the S2 ORC
  shim. **R1-vs-R2 chosen at pickup.** One coupling (a design constraint, not a
  decision change): you can't hot-swap code with **live suspended fibers** pointing
  into the old module — so the async runtime + long-lived fibers stay on the
  *persistent* side, only transient **leaf logic** is reloadable (or quiesce fibers
  before swap).

---

## 10. Testing & gates

Inherits the project cadence (CLAUDE.md): `zig build && zig build test` after every
step; **xfail-then-green or behavior-lock — no commit both adds a test AND makes it
pass**; never regenerate snapshots while red; corpus = `examples/` + `issues/` with
`.exit`/`.stdout`/`.stderr`/`.ir` snapshots. Per-*step* gates live in the eventual
`PLAN-*` streams; this section is the design-level verification strategy that those
streams must implement.

### 10.1 The async test harness = the deterministic-simulation `Io` (the keystone)

Concurrency is nondeterministic (scheduling/readiness order), which **breaks snapshot
testing** outright. So the **deterministic-sim `Io`** (fixed clock, scripted
readiness, deterministic single-stepping scheduler) is not merely a feature — it is
**the test harness for everything async**. Every concurrency example runs under it →
reproducible stdout → snapshottable. Consequence for sequencing: **build the
deterministic `Io` right after the blocking `Io`** (it's the simplest scheduler after
blocking and it *gates the ability to test* fibers/channels/race/schedulers at all).
The 10 patterns in §4.6-adjacent examples become corpus tests only because they run
under it.

### 10.2 What is NOT snapshot-testable

True parallel **data races** (N×M:1 / M:N) are nondeterministic by construction. They
run under the deterministic `Io` for *correctness* repro, but race-detection needs a
separate **stress harness** (run-N-times / TSan-style), **not** the corpus. Any such
coverage bound must be stated loudly (a `log()`-style note in the harness), never
silently skipped — per the REJECTED-PATTERNS rule against silent gaps.

### 10.3 Arch-sensitive lowering — atomics + context-switch

Atomic orderings lower differently per arch (x86 `lock`-prefix / plain MOV vs aarch64
LL/SC / `ldar`/`stlr`), and the A2 context-switch is per-arch asm. Lock both with the
**existing inline-asm cross-arch sibling pattern**: a `.build` `{"target": "…"}`
sidecar runs **ir-only** on a non-matching host (asserts `.ir` + `.exit` + `.stderr`
from `sx ir --target`) and **end-to-end** on a matching CI runner. So `Atomic`
lowering carries **x86_64 + aarch64 `.ir`** snapshots; the context-switch gets
per-arch run tests on matching runners.

### 10.4 New corpus categories

`17xx` atomics · `18xx` concurrency (fibers/channels/race/async, all under the
deterministic `Io`). Comptime metaprogramming (`declare`/`define`/`type_info`) +
comptime-asm extend `06xx`; C1 FFI extends `12xx`; the cross-arch comptime-asm **loud bail** and
the cancellation diagnostics are `11xx`.

### 10.5 Per-piece gates (design level)

| Piece | Locks via |
|---|---|
| **N1 atomics** | unit `emit_llvm.test.zig` (LLVM `atomicrmw`/`cmpxchg`/`fence` + ordering emission); corpus `17xx` single-thread (deterministic); arch-gated `.ir` (x86_64 + aarch64) |
| **declare / define / type_info** | unit (reflect round-trips; a minted enum has correct layout/match codegen); corpus `06xx` comptime (deterministic) |
| **C1 FFI** | **behavior-lock** existing trampoline cases first; then xfail→green `12xx` comptime extern with floats / structs-by-value / aggregate (`{ptr,len}`) returns; unit for thunk-synth + args-buffer marshal |
| **S1 spine** | infra — exercised transitively via C1/C3 examples; unit for LLJIT lifecycle + thunk cache |
| **C3 comptime asm** | corpus `06xx` host-arch `#run` asm computes a value; `11xx` diagnostic asserts the cross-arch loud bail |
| **A1/A2 fibers** | unit (scheduler step, fiber bootstrap); context-switch arch-gated run tests; corpus `18xx` under deterministic `Io` |
| **A3/A5 schedulers, channels, race, cancel** | corpus `18xx` (the 10 patterns) under deterministic `Io` → deterministic snapshots; cancellation cleanup (`onfail`/`defer`) asserted via stdout ordering |

### 10.6 Cadence example (atomics, N1)

1. **xfail** — add `examples/17xx-atomics-fetch-add.sx` using `Atomic(i64).fetch_add`; seed the `.exit` marker → **red** (codegen missing). *(test added, not yet passing)*
2. **green** — emit LLVM `atomicrmw add` + ordering; example passes; capture `.stdout` + x86_64/aarch64 `.ir` snapshots; review the diff. *(makes it pass, no new test)*

This satisfies "no commit both adds a test and makes it pass," and every other piece
follows the same xfail→green (or behavior-lock→extend) shape.

### 10.7 Review-surfaced gaps (the high-corruption-risk pieces need *correctness*, not existence, tests)

The §10.5 gates prove things *run*; the §8.1 risks are silent-corruption modes a
run/snapshot test won't catch. Each needs an explicit adversarial gate:

- **A2 context-switch — switch-stress test.** Scribble *every* callee-saved register
  + a stack-canary before suspend; deep/recursive fiber chains; verify all survive
  post-resume. Run/snapshot tests don't prove register preservation. (The single
  highest-corruption-risk piece, §8.1.1.)
- **Deterministic-`Io` — calibrate the oracle.** Cross-check a handful of cases
  against the blocking `Io` and property-test that scheduling order is actually fixed,
  *before* trusting it to gate everything async (a deterministic-but-wrong scheduler
  snapshots garbage).
- **`context`-fiber-local invariant — named test at the N×M:1/M:N step.** M:1 can't
  exercise migration; add a test that forces a fiber to migrate and asserts it reads
  *its* `context`/`errno`, not the new thread's.
- **N1 ordering *semantics* are out of snapshot scope — state it loudly.** `.ir`
  snapshots prove the *keyword emitted*, not weak-memory correctness (e.g. `relaxed`
  where `acquire` was needed ships green). Declare this out-of-scope parallel to
  §10.2's race carve-out; lock-free structures need the stress harness.
- **C1 args-buffer — adversarial layout cases.** Over-aligned structs, empty structs,
  aarch64 small-struct register splitting, `bool` — a wrong layout that happens to
  print right passes a stdout test. Call these out explicitly, not just
  "structs-by-value."
- **S2 — has no gate today despite a prior spike failure.** When reached, add a TLS +
  C-constructor JIT test (the exact `_Thread_local` SIGABRT case), per host OS.
- **Hot-reload — no row today.** When picked up: state-survival test + the
  live-suspended-fiber-into-stale-module hazard (R1/R2).
