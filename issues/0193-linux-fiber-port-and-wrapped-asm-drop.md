# Issue 0193 — linux fiber-runtime port (sched.sx) + a wrapped top-level `asm` drop

> **RESOLVED — port landed on aarch64-linux.**
>
> **Bug A (register-indirect trampoline bus-errors on 1817): FIXED.** Root cause found via lldb on an
> AOT macOS build (the bug reproduced on macOS too, so no container needed): the WIP port had left
> `fib_dispatch` with no explicit ABI annotation (the original pinned the C-ABI via `export
> "fib_dispatch"`, which the redesign dropped). Without a C-ABI pin the fn uses sx's INTERNAL calling
> convention, which reserves x0 for the implicit `context` pointer and shifts the first real arg `self`
> to x1 — but the trampoline (`mov x0, x19; br x20`) hands the fiber over in x0, C-ABI style. On first
> entry x1 coincidentally aliases `&fiber.ctx == self` (left there by the scheduler's prior
> `swap_context(from, to)`, x1 = to), so the body runs once; but inside it the closure loads
> `[Fiber+8] == ctx.regs[1] == &fib_dispatch` as its "first capture" and re-invokes `fib_dispatch`
> forever → stack overflow → bus error. **Fix:** annotate `fib_dispatch` `abi(.c)` so it keeps the
> C-ABI (`self` in x0), matching what the trampoline supplies — a one-line library change, no compiler
> change. `abi(.c)` is used rather than `export "fib_dispatch"` because the fn is reached only by
> address through the trampoline (`xx fib_dispatch`), never by an external name, so it needs the
> convention, not a public symbol (it stays a local symbol). The register-indirect naked-fn trampoline
> design is kept (it sidesteps Bug B's hand-written per-OS global-asm symbol). Adversarially reviewed
> against the compiler source (`src/ir/lower/decl.zig` `funcWantsImplicitCtx`/`wants_ctx`/
> `CallingConvention.c`); root cause + fix confirmed CORRECT.
>
> **Validation:** 1811 / 1814 / 1816 / 1817 (the go/wait/sleep capstone) all run **byte-identical** on
> the aarch64-macOS host AND in an aarch64-linux Apple `container` (`sum: 123`, completion order
> `2@10 3@20 1@30`, etc.). Full `zig build test` macOS suite GREEN (817/0).
>
> **Bug B (wrapped top-level `asm` dropped): carved out to `issues/0194-wrapped-toplevel-asm-dropped.md`
> as an OPEN compiler bug.** It is no longer triggered anywhere in the tree (the port no longer uses a
> wrapped global-asm block), so it does not block anything — but it is a real defect and stays filed.
>
> Original writeup below for history.

---

Status: **(historical — see RESOLVED banner above).** Two intertwined items uncovered while porting
`library/modules/std/sched.sx` (the M:1 fiber runtime) to aarch64-linux.

The epoll *bindings* + `std.event.Loop` epoll backend are already committed (`cc137002`) and
**runtime-validated on real Linux** via Apple `container` (see the event.sx VALIDATION note / the
[[apple-container-linux-testing]] memory). This issue is only about the **fiber scheduler** port.

## What WORKS (validated on aarch64-linux in an Apple `container`)

With the stashed sched.sx port, built `--target aarch64-linux --self-contained` and run in an
alpine container:
- **1811** (scheduler round-robin via `yield_now`): `sequence: 0 1 2 0 1 2 0 1 2`, all done. ✓
- **1816** (`block_on_fd` over a pipe — the **epoll** fd path): `log: wrote read 3 [97 98 99]`,
  `n_suspended: 0` — identical to macOS kqueue. ✓
- macOS (kqueue) stays green for both.

The port (all in sched.sx) is: `MAP_AP` 0x1002→0x22; an `inline if OS == .linux { ep :: #import
"modules/std/net/epoll.sx" }`; and `inline if OS == { case .linux: <epoll> case .macos: <kqueue> }`
branches in `block_on_fd` (open + `EPOLLIN|EPOLLONESHOT` register), the run-loop Mode-2
(`epoll_wait` + `EPOLL_CTL_DEL`-on-fire for one-shot parity), and `cancel_io_waiter_for`
(`EPOLL_CTL_DEL`-on-early-wake). Those epoll branches are correct (1816 proves it).

## Bug A — register-indirect trampoline bus-errors on the go/wait/sleep capstone (1817)

To get the fiber trampoline onto linux without a per-OS hand-written global-asm symbol
(`_fib_tramp` vs `fib_tramp`), the stash replaces the global `asm` trampoline with a **naked sx fn
+ register-indirect branch**: `spawn` presets `regs[1]` (x20) = `xx fib_dispatch`, and
`fib_tramp :: () abi(.naked) { asm { mov x0, x19 ; br x20 } }` tail-branches to dispatch. Its own
symbol is auto-emitted per-OS, so no `.global`/`bl <name>` literal.

This **works for 1811 + 1816** (both run on linux AND macOS) but **bus-errors immediately on 1817**
(`go`/`wait`/`sleep`) on BOTH macOS and linux — `Bus error`, no output, a short recursive-looking
stack trace. HEAD's 1817 (committed global-asm trampoline) works (`sum: 123`), so the redesign is
the regression. Root cause not yet found: 1811/1816 use the same `spawn`/tramp path; the only thing
1817 adds is timer `sleep` + `Task` `go`/`wait` (suspend/resume). Suspect something about the
naked-fn tramp or x20 liveness specific to the Task-closure / resume path — needs a debugger on the
container build.

## Bug B — a top-level `asm` block wrapped in an `inline if` is DROPPED (in sched.sx's context)

The redesign in Bug A was forced by this: wrapping the **original** global `asm` trampoline in
`inline if OS == { case .linux: asm{…fib_tramp…} case .macos: asm{…_fib_tramp…} }` (or the plain
`inline if OS == .linux { asm } else { asm }` form) makes the asm **not emit at all** — `nm` shows
`fib_tramp` as `U` (undefined), both platforms fail to link. A PLAIN unwrapped `asm{}` emits fine.

NOT reproducible in isolation: minimal/medium repros (top-level asm in a case; two case blocks;
case asm in an imported module; naked fn + case asm with `bl` to an exported fn; a one-sided
`inline if .linux { #import }` before it) ALL emit + link correctly. Only sched.sx (the full module)
drops it. So there's a real flatten/lowering interaction in `src/imports.zig`
`flattenComptimeConditionals` / `appendBranchDecls` (the comptime-conditional pre-pass that surfaces
top-level decls from a taken `if_expr`/`match_expr` arm) with a top-level `asm` node, triggered by
something else in sched.sx — not yet isolated.

## Two paths to resolve (either suffices)

- **Path A (compiler):** fix Bug B — make a top-level `asm` block survive `inline if`/`case`
  flattening in all module contexts. Then the original global-asm trampoline can be OS-branched with
  the `case` form directly (no tramp redesign), sidestepping Bug A entirely. This is what the user
  asked for ("case form to emit top-level asm block"). Start: instrument
  `flattenComptimeConditionals` to dump the surfaced top-level decls for sched.sx and see where the
  `asm` node is lost.
- **Path B (library):** fix Bug A — debug the register-indirect tramp's 1817 bus error (gdb/lldb in
  the container on the aarch64-linux build, or a reduced go/wait/sleep repro). No compiler change.

## Verification

`git stash pop`; then per-example: `sx build --target aarch64-linux --self-contained -o /tmp/x
examples/concurrency/<ex>.sx` and `container run --rm -v "$PWD/.sx-tmp:/work" alpine /work/x`
(see [[apple-container-linux-testing]]). Target: 1811/1814/1816/1817 all green on linux AND macOS,
plus the full `zig build test` macOS suite.
