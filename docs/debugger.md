# Debugging sx: traces, debug info, and stepping

This is the architecture spec for sx's debugging story — error return
traces, DWARF debug info, and source-level stepping. It records *what*
each piece does, *how* it works, and *why* it's built this way.

For the user-facing guide to writing fallible code (and what a trace
looks like in practice), see [error-handling.md](error-handling.md).
This document is the implementer/architect reference.

---

## The guiding principle

Debugging splits into two jobs, and conflating them is the trap:

1. **"My program errored — where, and along what path?"** (≈99% of the time)
2. **"I want to single-step in a real debugger."** (rare, deep)

sx solves #1 **itself, in-process, with zero OS dependencies** — the
source location is baked in at compile time, so a trace needs no DWARF
reader, no symbolizer, no `/proc`, no `atos`. sx solves #2 by **emitting
standard DWARF and handing it to an external debugger** (`lldb`/`gdb`),
which already knows every platform's symbolization rules. We ship no
symbolizer of our own.

The payoff: error traces work identically and deterministically on every
target — desktop JIT, AOT binary, comptime interpreter, even a
locked-down iOS device with no debugger attached — while real
single-stepping is available for free wherever a debugger exists.

---

## The three execution contexts

sx code runs in three different machines, and the trace/debug design has
to satisfy all three. "JIT" and "comptime" are **not** the same thing.

| Context | What runs the code | Trace frame representation |
|---|---|---|
| **AOT** (`sx build`) | native machine code in an on-disk binary | pointer to an interned `Frame` |
| **JIT** (`sx run`) | ORC-JIT'd machine code in anonymous memory | pointer to an interned `Frame` |
| **Comptime** (`#run`) | the IR interpreter (`interp.zig`) — no machine code | packed `(func_id, span.start)` |

The crucial constraint: **the same lowered IR runs in the compiled
backend *and* the interpreter.** So a value the IR produces (like a trace
frame) must mean the right thing in both — which is why the trace-push is
a context-sensitive op (below), not a plain constant.

A second fact shaped the design: **iOS devices forbid JIT** (no
`mmap(PROT_EXEC|PROT_WRITE)` for third-party apps). On-device sx is
therefore AOT-only, and the trace must be readable on a device with no
debugger attached — which the in-process embedded-`Frame` design delivers
and a PC-symbolization design could not.

---

## Error return traces

A return trace is the path an error took from its `raise` site up through
every `try` that propagated it. It is recorded as the error travels and
formatted where it's caught (a `catch` handler, or the failable-`main`
wrapper).

### The buffer

A thread-local fixed-cap ring of opaque `u64` frames lives in a vendored
C runtime, [`library/vendors/sx_trace_runtime/sx_trace.c`](../library/vendors/sx_trace_runtime/sx_trace.c):

- `sx_trace_push(u64)` / `sx_trace_clear()` / `sx_trace_len()` /
  `sx_trace_truncated()` / `sx_trace_frame_at(u32)`.
- Capacity 32; overflow keeps the **newest** frames (Zig-style) and
  latches a `truncated` flag so the formatter can note "N frames omitted."

It lives in a separately-linked C file (not an emitted `thread_local` IR
global) for the same reason as the JNI env slot: LLVM's ORC JIT doesn't
initialize TLS for objects added via `AddObjectFile`. The compiler links
the `.c` so the JIT resolves `sx_trace_*` via `dlsym`; AOT targets pick it
up as an auto-injected `#source` (gated on `Lowering.needs_trace_runtime`).

The buffer neither knows nor cares what a frame *means* — it just stores
`u64`s. The producer and the formatter agree on the interpretation per
context (next section).

### The frame: an embedded `Frame`, not a PC

**A runtime frame is a pointer to a compile-time-interned
`Frame {file, line, col, func, line_text}`.** The lowerer already knows the push
site's source location (the instruction's span + the enclosing function),
so the location — *and the offending source line itself* (`line_text`, for the
`^` caret snippet) — is baked into read-only data at compile time and the
formatter reads it directly. No PC capture, no DWARF, no symbolizer, no runtime
file read.

A comptime frame is instead a packed `(func_id: u32, span.start: u32)` —
where `span.start` is the op's source byte offset — resolved through the
interpreter's in-memory IR/source tables. The interpreter **never
dereferences the compiled `Frame` pointer** — it uses its own
representation — so the compiled and interpreted memory models never
collide.

### The niladic trace-push op

Because the same IR runs in both machines, the frame value comes from a
**dedicated, niladic, span-stamped IR op** (`.trace_frame`) — the same
pattern as `is_comptime` / `interp_print_frames`. It carries **no operands
and no global reference**; each backend derives the frame from its own
context:

- **`emit_llvm` (the `.trace_frame` arm):** resolves the op's `span` +
  current function → `{file, line, col, func}` (reusing the source map
  wired in for DWARF), **interns and builds the `Frame` global** in
  [`src/backend/llvm/reflection.zig`](../src/backend/llvm/reflection.zig)
  (the same mechanism, in the same file, as the tag-name table), and yields
  its address as the op's value. The lowerer feeds that value to a separate
  `sx_trace_push` call emitted through the normal call lowering.
- **`interp`:** yields the packed `(func_id, span.start)` from its own
  execution context as the op's value. The separate `sx_trace_push` call
  op consuming it is executed by the interp as an extern call (via
  `host_ffi`/dlsym, the same path as any extern), storing the packed value
  in the buffer; the comptime `.trace_resolve` resolver later recovers
  `file:line:col` from it.

The op stays niladic by design: it carries no operand and no `GlobalId`,
so no IR-level `Frame` global is ever visible to the interpreter. The
rejected alternative — an op carrying a `GlobalId` to an IR-level `Frame`
global — would make the global visible to the interpreter (forcing
comptime onto the pointer-deref path) and fatten the lowerer; **do not do
this.**

`Frame` is defined **once** in sx (`trace.sx`/std), and its runtime layout —
`{ string file, i32 line, i32 col, string func, string line_text }` — is
mirrored by the cached LLVM **literal (anonymous) struct type** `getFrameStructType()`
(`src/ir/emit_llvm.zig`). The reflection builder
(`src/backend/llvm/reflection.zig`) assembles each push site's global as an
LLVM **named-struct constant** over that cached type via
`LLVMConstNamedStruct` — a type-safe LLVM struct, not hand-packed bytes
(which would risk the "8-bytes-assumed" clobber class of bug). It does
**not** derive the layout from the sx `Frame` `TypeId`, nor route through
the normal struct-emission path. `file`/`func`/`line_text` strings are
interned into a shared pool so a path shared by N push sites is stored once
— the table stays tiny. The `file` field is the source basename (full paths
live in DWARF), so trace output is machine-independent and snapshot-testable.

### Push and clear sites

Push (one frame each):

- `raise EXPR` — at the raise site.
- `try X` — on X's failure path, wherever that failure routes next.
- a bare failable in its legal positions (LHS of `catch`, LHS of an
  `or value` terminator, RHS of a destructure) — at the failure point.

Clear (every absorbing site — the error stops here):

- `catch e { ... }` runs (cleared so the handler still sees the chain;
  the buffer is empty after the handler exits).
- an attempt succeeds inside an `or` chain.
- an `or value` terminator absorbs the failure.
- a destructure binds the error slot (the user now owns the error).

So at format time the buffer holds exactly the frames of failures that
actually escaped to where you're formatting. Absorbed failures are
push-then-clear and leave no residue — the steady state mirrors Zig's.

`process.exit(code)` discards the buffer (immediate syscall, no flush).

### Output format

```
error return trace (most recent call last):
  parse at parse.sx:12:5
     if !is_digit(s[0]) raise error.BadDigit;
                        ^
  run   at main.sx:20:9
     v := try parse(s);
          ^
```

`func at file:line:col` per frame, oldest-first ("most recent call
last"), with a best-effort source snippet + `^` caret. The snippet reads
the source file if available (always true under `sx run`); it degrades to
the bare `file:line:col` line when the source isn't present. The
formatter lives in [`library/modules/trace.sx`](../library/modules/trace.sx)
(`to_string` / `print_current`); the failable-`main` reporter is
`sx_trace_report_unhandled` in `sx_trace.c`.

### Build-mode gating

Traces follow the optimization level (mirrors `Lowering.tracesEnabled`):

- **Debug (`-O0`/`-O1`, the `sx run` default):** push/clear emitted; the
  `Frame` table is emitted.
- **Release (`-O2`/`-O3`):** push/clear are no-ops, no `Frame` table — a
  future `--release-traces` flag flips them back on.
- **Comptime (`#run`):** always on, regardless of build mode — a `#run`
  failure must produce a useful diagnostic even in a release build.

The success path costs nothing; the failure path costs one pointer push.

---

## DWARF debug info — a debugger-only artifact

sx emits standard DWARF so external debuggers can step sx code. **DWARF is
not used by the trace formatter** — it exists solely for `lldb`/`gdb` (and
on-device iOS debugging). It is independent debugger sugar that can be
stripped without affecting traces.

### What's emitted

In [`src/backend/llvm/debug.zig`](../src/backend/llvm/debug.zig) (the
`DebugInfo` helper, driven from `emit_llvm`'s `emit()` pipeline), gated on
the same debug opt levels + a wired source map (`setDebugContext`):

- one `DICompileUnit` + `DIFile` on the main file,
- a `DISubprogram` per emitted function (`LLVMSetSubprogram`),
- a `DILocation` per instruction, resolved from `Inst.span` via
  `errors.SourceLoc.compute`, scoped to the function's subprogram,
- the `"Debug Info Version"` / `"Dwarf Version"` module flags, finalized
  with `LLVMDIBuilderFinalize`.

The `llvm-c/DebugInfo.h` DIBuilder API is bound in
[`src/llvm_api.zig`](../src/llvm_api.zig).

### What it enables (and what it doesn't, yet)

- ✅ **breakpoints, `step`, `stepi`, backtrace, source-line mapping** —
  enabled by the line table + subprograms.
- ⚠️ **variable inspection (`p x`)** — needs `DILocalVariable` + `DIType` +
  location expressions per IR slot, which are **not emitted yet**. lldb
  can step and show the right source line, but `p x` reports no variable.
  This is an optional future slice; it's not required for stepping.

### macOS / iOS note

A linked Mach-O contains **no DWARF** — `ld` leaves a debug map (`OSO`
stabs) pointing at the `.o` files. So `llvm-dwarfdump` on the executable
shows nothing; you run `dsymutil` to collect a `.dSYM`, which lldb (and
`atos`) consume. This is a standard build-time step, **not** something sx
parses at runtime.

---

## Wiring: exactly how it's connected

This section is the file-and-function map — the concrete data flow for
both the trace path and the DWARF path. Items marked ✅ exist today;
⏳ are the planned slice-3 shape.

### Where the pieces live

| File | Responsibility |
|---|---|
| [`src/core.zig`](../src/core.zig) | `Compilation`: owns `import_sources` (file→source map), constructs the emitter, calls `setDebugContext` + `emit`; re-enters the interpreter for `#run`/post-link |
| [`src/ir/lower.zig`](../src/ir/lower.zig) | AST→IR. Stamps `Inst.span`; emits push/clear at failure/absorb sites; `tracesEnabled` gate; declares the `sx_trace_*` externs |
| [`src/ir/emit_llvm.zig`](../src/ir/emit_llvm.zig) | IR→LLVM orchestrator. Owns `LLVMEmitter` + the source map (`setDebugContext`); dispatches the `.trace_frame` op and the DWARF passes to the helpers below |
| [`src/backend/llvm/reflection.zig`](../src/backend/llvm/reflection.zig) | `Reflection`: builds the interned `Frame` table + the tag-name / type-name tables; yields the `.trace_frame` op's value (the `Frame` global's address) — the `sx_trace_push` call itself is emitted by `lower.zig` |
| [`src/backend/llvm/debug.zig`](../src/backend/llvm/debug.zig) | `DebugInfo`: builds all DWARF metadata (compile unit, per-function subprograms, per-instruction `DILocation`) |
| [`src/ir/interp.zig`](../src/ir/interp.zig) | Comptime IR interpreter. The `.trace_frame` op yields a packed `(func_id, span.start)`; the separate `sx_trace_push` call op runs as an extern call (dlsym); `.trace_resolve` recovers comptime frames |
| [`src/errors.zig`](../src/errors.zig) | `SourceLoc.compute(source, offset) → {line, col}`; the `import_sources` map type |
| [`src/ir/inst.zig`](../src/ir/inst.zig) | `Inst.span`, `Function.source_file`, the `Op` union (home of the `.trace_frame` op) |
| [`library/vendors/sx_trace_runtime/sx_trace.c`](../library/vendors/sx_trace_runtime/sx_trace.c) | the thread-local ring buffer + `sx_trace_report_unhandled` |
| [`library/modules/trace.sx`](../library/modules/trace.sx) | the formatter (`to_string` / `print_current`) |
| [`src/llvm_api.zig`](../src/llvm_api.zig) | binds `llvm-c/Core.h` + `llvm-c/DebugInfo.h` |
| [`src/target.zig`](../src/target.zig) | `TargetConfig.opt_level` (the gate) + `is_aot` |

### The shared spine: one source-location resolver

Both paths resolve a byte offset to `file:line:col` the same way, so
traces and DWARF can never disagree:

- ✅ `import_sources : StringHashMap([:0]const u8)` (file path → source
  text) is built in `core.zig` during `resolveImports` (main file +
  every import), and shared with both the diagnostics renderer and the
  emitter (via `setDebugContext`).
- ✅ `Inst.span` (a `{start, end}` byte range) is threaded onto every
  instruction by `Builder.current_span`, which `lower.zig` sets as it
  walks each expr/stmt (E3.0 slice 1). `Function.source_file` records
  which file a function's spans index.
- ✅ `errors.SourceLoc.compute(source, span.start)` turns an offset into
  `{line, col}`. Used by the diagnostics renderer, `#caller_location`,
  the DWARF emitter, and the trace formatter — one function,
  every consumer.

### Trace path: compile → run → format

**Producer (compile time) ✅ (3a)**

1. `lower.zig` reaches a failure site — `lowerRaise`, `lowerTry`'s
   propagation branch, `lowerFailableOr`, or `lowerDestructureDecl` — and
   (when `tracesEnabled()`) emits the niladic `.trace_frame` op via
   `placeholderTraceFrame()`, whose result feeds a separate `sx_trace_push`
   call via `emitTracePush()`. Absorbing sites emit `emitTraceClear()` →
   `call sx_trace_clear()`.
2. **Compiled backend** (`emit_llvm.emitInst`, `.trace_frame` arm):
   resolve the op's `span` + current function → `{file,line,col,func}`,
   intern into the `Frame` table (built alongside `tag_name_array`), and
   yield the `Frame` global's address as the op's value, which the separate
   `sx_trace_push` call (step 1) consumes. The `sx_trace_push` extern is
   declared lazily by `getTraceFids()` (which sets `needs_trace_runtime`).
3. **Interpreter** (`interp.zig`, same op): pack `(current_func_id,
   span.start)` into a `u64` and return it as the op's value. The separate
   `sx_trace_push` call op is then executed by the interp as an extern call
   (`callExtern` → `host_ffi.lookupSymbol`/dlsym, the same path as any
   extern), storing the packed value in the buffer. The comptime
   `.trace_resolve` resolver later turns each packed value back into
   `file:line:col` via the IR/source tables.

**Buffer (run time) ✅** — `sx_trace.c` stores the `u64`s. Linked into the
compiler so the JIT resolves `sx_trace_*` via `dlsym`; auto-injected as a
`#source` for AOT when `needs_trace_runtime` is set.

**Formatter (run time) ✅ (compiled 3a, comptime 3b)** — `trace.sx` `to_string()` loops
`sx_trace_len()` / `sx_trace_frame_at(i)` and resolves each `u64` through
a **read-side context-split primitive** (the mirror of the `.trace_frame` op):

- compiled: cast the `u64` → `*Frame`, load the fields.
- comptime: unpack `(func_id, span.start)`, resolve via the interpreter's
  IR/source tables → a `Frame`.

The same `trace.sx` source works in both because it runs in the matching
machine — a compiled program formats compiled frames, a `#run` formats
comptime frames. It then prints `func at file:line:col` + a best-effort
source snippet.

**Consumers ✅** — a `catch` handler calling `trace.print_current()`, and
the failable-`main` wrapper, whose `ret` path in `emit_llvm`
(`emitFailableMainRet`) calls `sx_trace_report_unhandled` in `sx_trace.c`.

### DWARF path: compile → debugger ✅

1. `core.zig` `generateCode`: `LLVMEmitter.init(...)` →
   `emitter.setDebugContext(&self.import_sources, self.file_path)` →
   `emitter.emit()`.
2. `emit()` **Pass -1** `initDebugInfo()`: gated by `debugEnabled()`
   (source map present + opt none/less). Creates the `DIBuilder`, adds the
   `"Debug Info Version"`/`"Dwarf Version"` module flags, and one
   `DICompileUnit` on `diFileFor(main_file)`.
3. **Pass 2** `emitFunction` → `beginFunctionDebug(func, llvm_func, name)`:
   `diFileFor(func.source_file)` → `LLVMDIBuilderCreateFunction` →
   `LLVMSetSubprogram`; stores it as `di_scope`.
4. `emitInst` (top, every instruction): `setInstDebugLocation(inst.span)`
   → `SourceLoc.compute` over `sourceForFile(current_func_file)` →
   `LLVMDIBuilderCreateDebugLocation(scope = di_scope)` →
   `LLVMSetCurrentDebugLocation2`. So every LLVM instruction the op emits
   carries the right `!dbg`.
5. `endFunctionDebug` clears `di_scope` + the builder location, so the
   synthetic Obj-C / global-ctor functions (no subprogram) inherit none.
6. **Pass 4** `finalizeDebugInfo()` → `LLVMDIBuilderFinalize`;
   `LLVMDisposeDIBuilder` in `deinit`.
7. Backend emits the object / JIT module. AOT Mach-O carries a debug map
   → `dsymutil` collects a `.dSYM` → `lldb`/`gdb` symbolize. In release
   `debugEnabled()` is false → no `DIBuilder` runs → strippable to nothing.

### The gate: one switch, two consumers

`Lowering.tracesEnabled()` (lower.zig) and `DebugInfo.debugEnabled()`
(backend/llvm/debug.zig) both reduce to `opt_level == .none or .less`. The `Frame`
table + push/clear ride `tracesEnabled`; DWARF rides `debugEnabled`.
Release (`-O2`/`-O3`) emits neither. `sx run` defaults to `-O0` (both on);
`sx ir`/`sx asm` default to `-O2` (both off) — which is why the `.ir`
snapshots don't drift when this machinery is present.

---

## Why not return-address PCs + DWARF (decision, 2026-06-01)

The original design captured return-address PCs and symbolized them via
DWARF, Zig-style. We changed course. The full rationale lives in
`implementation_plan.md` §Decisions Log; in brief:

- **The dual-execution split is unavoidable regardless.** Compiled code
  and the interpreter run the same IR, so a frame must be context-split
  whether it's a PC or a `Frame` pointer — PCs buy no simplification here.
- **JIT code has no on-disk DWARF.** `sx run` (the primary dev path, and
  what the test suite exercises) JITs into anonymous memory; symbolizing
  those PCs needs GDB-JIT registration + an in-process DWARF reader — the
  single largest chunk of the Zig-faithful approach.
- **iOS forbids JIT and prints best with no debugger.** Device builds are
  AOT; the embedded-`Frame` trace prints source-mapped to stderr/`os_log`
  with nothing attached — the biggest DX win on a locked-down platform,
  and impossible with PC symbolization there.
- **macOS keeps no DWARF in the linked binary** (debug-map → `.o`/`.dSYM`),
  so even AOT self-symbolization means porting a Mach-O debug-map +
  `.debug_line` reader.
- **Determinism.** Interned `Frame`s have no ASLR addresses, so trace
  output is snapshot-testable; raw PCs are not.

DWARF is still emitted (it's how Zig's own `std.debug` reads program debug
info), but **demoted to the debugger-only role above**. All OS-specific
symbolization is delegated to the platform debugger — sx ships none.

---

## Runtime artifacts

| Artifact | Lookup | Size | Shipped in release? |
|---|---|---|---|
| **Tag-name table** | tag id → name string | tiny (per distinct tag) | **yes, always** — `{}` interpolation and the failable-`main` reporter's `error: unhandled error reached main: error.X` line need names even in release |
| **`Frame` location table** | push site → `{file,line,col,func}` | small (interned strings; per push site) | **debug / `--release-traces` only** — rides the trace-mode gate |
| **DWARF (`.debug_line` / `DISubprogram`)** | PC → file:line:col, for *debuggers* | larger (per source position) | **debug / `--release-traces` only**, strippable; consumed by `lldb`/`gdb`, never by the trace formatter |

The tag-name table is always linked (it's how a tag renders as `BadDigit`
in any build). The `Frame` table powers traces. DWARF is independent
debugger sugar.

---

## Stepping and deep debugging

Stepping is delegated entirely to the platform debugger via the DWARF we
emit; sx provides the artifacts and a launch convenience, nothing more.

### Artifacts

`sx build --emit-obj` keeps the DWARF-bearing object at its link-time path
(`.sx-tmp/main.o`) instead of deleting it, and implies `-O0` (DWARF only emits
at opt none/less). On **macOS** the linked binary's debug map resolves to that
`.o`, so `lldb`/`gdb` run from the project root can step the binary directly; on
**Linux** the DWARF is in the binary, so the `.o` isn't even needed. A portable
`.dSYM` (via `dsymutil`) is only required for the on-device iOS rung (below).

### The verification ladder

Source-level stepping is verified manually/interactively (it needs
`dsymutil`/`lldb`, and on device a signing identity + a `get-task-allow`
provisioning profile — not a `run_examples.sh` test). Climb cheapest-first;
the device run is the final sign-off:

1. **macOS native ✅ verified** — `sx build --emit-obj` → drive `lldb --batch`
   (the debug map resolves to the kept `.o`; no `dsymutil` needed locally).
   Checked in as `tests/debug_stepping_smoke.sh`: file:line breakpoint resolves
   to `.sx:line` + a source-mapped `bt`. The automatable rung.
2. **iOS simulator ✅ verified** — `sx build --target ios-sim --emit-obj`
   produces an `arm64-ios-simulator` Mach-O that runs under `simctl spawn` and
   steps in `lldb` (the backtrace shows a `dyld_sim` frame — proof it's the sim
   runtime). The `tests/debug_stepping_smoke.sh` rung-2 exercises this *against
   an already-booted sim* (it never boots one itself — use a single simulator);
   it also collects a `.dSYM` via `dsymutil`, removes the `.o`, and confirms
   lldb still resolves via the `.dSYM` — proving the device-applicable artifact
   path. Skipped when no sim is booted.
3. **iOS device (capstone) — manual, needs hardware + Apple signing.** Every
   *technical* piece is already verified above (DWARF, the `.dSYM` workflow,
   stepping under the sim runtime); the device rung adds only Apple-toolchain
   steps that require a phone + a development identity, so it's a checklist, not
   a compiler deliverable:
   1. `sx build --target ios --emit-obj …` (DWARF in the kept `.o`).
   2. `dsymutil <binary> -o <App>.app.dSYM` (the `.app` ships no `.o`).
   3. bundle the `.app` (existing `--bundle` path) + debug-sign with a
      provisioning profile carrying **`get-task-allow`**.
   4. `xcrun devicectl device install app …` then launch under `debugserver`.
   5. attach `lldb` (it finds the adjacent `.dSYM`) and single-step sx source.

   No new compiler code is required — `--emit-obj` + standard Apple tools
   suffice. (A `--debug` convenience flag that chains 1–4 could be added later,
   but should be built with a device in hand to verify it.)

Independently, **Tier-0 always works with no debugger**: a plain on-device
run still prints the embedded-`Frame` trace to stderr/`os_log`.

### Dependencies

Everything OS-specific is a **build-/run-time tool on the host** (the same
ones any iOS app needs): `dsymutil`, `codesign` + provisioning,
`devicectl`/`simctl`, `lldb`/`debugserver`. At **runtime, on the target,
sx's dependency is zero** — the trace is `write(2, ...)` of pre-baked
strings. We never call `atos`/`addr2line`, never read `/proc`, never parse
a Mach-O debug map, never register JIT DWARF.

---

## Implementation status

| Piece | Status |
|---|---|
| Tag-name table + `{}` interpolation | ✅ done (`a3ff503`) |
| Trace buffer (`sx_trace.c`) + push/clear wiring | ✅ done (`51f5277` / `ea40724`) |
| `trace.sx` formatting (placeholder locations) | ✅ done (`bb20339`) |
| IR instructions carry source spans | ✅ done — E3.0 slice 1 (`b44a5d0`) |
| DWARF emission (compile unit / subprogram / line table) | ✅ done — E3.0 slice 2 (`c32d694`) |
| Niladic trace-push op + interned `Frame` table (runtime) | ✅ done — E3.3 slice 3a (`1b6cbc1`) |
| Comptime resolver (`func_id, span.start` → location) | ✅ done — slice 3b |
| Source snippet + `^` caret | ✅ done — slice 3c (line embedded in `Frame`) |
| `--emit-obj` artifact plumbing | ✅ done — slice 3d |
| Stepping verification: macOS lldb | ✅ done — 3e rung 1 (`tests/debug_stepping_smoke.sh`) |
| Stepping verification: iOS simulator + `.dSYM` path | ✅ done — 3e rung 2 (verified; smoke skips if no booted sim) |
| Stepping verification: iOS device | 📋 manual checklist — needs hardware + signing (no compiler gap) |
| DWARF variable info (`DILocalVariable`, for `p x`) | ⏳ optional follow-on |

The active plan and step breakdown live in `current/PLAN-ERR.md`
(§"Why not PCs + DWARF" + Step E3.0/E3.3) and `current/CHECKPOINT-ERR.md`;
the design decisions are logged in `implementation_plan.md` §Decisions Log.
