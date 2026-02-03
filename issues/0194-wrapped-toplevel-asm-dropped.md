# Issue 0194 — a top-level global `asm` block wrapped in `inline if` / `case` is DROPPED

> **RESOLVED (2026-07-03).**
>
> **Root cause:** parse-context node-kind mismatch, unconditional — no sched.sx-specific
> interaction. A true top-level `asm { … };` is parsed by `parseTopLevel` into an
> `.asm_global` node, but an `inline if` branch body is a *block*, so the same source inside
> a taken arm is parsed by the STATEMENT parser into the in-function `.asm_expr` form
> (`src/parser.zig` `parsePrimary` → `parseAsmExpr`). `flattenComptimeConditionals`
> faithfully surfaced that `.asm_expr` node to module scope, where
> `lowerMainAndComptime`'s decl switch (`src/ir/lower/decl.zig`) has an `.asm_global` arm
> but no `.asm_expr` arm — the node fell into `else => {}` and the template never reached
> `module.global_asm`, so the symbol was never emitted.
>
> **The "only in full sched.sx" observation did not survive re-testing:** on current
> master (pre-fix) a 10-line isolation case — `inline if OS == { case …: asm {…}; }` in a
> bare main file — reproduces the drop deterministically (no `module asm` in `sx ir`, the
> symbol `U`/absent in the object). There was no hidden trigger to bisect; `asm_global`
> handling has been unchanged since it landed (4d75b932, Phase F).
>
> **Fix:** `src/imports.zig` `appendBranchDecls` — when the flatten pass surfaces a taken
> arm's decls to module scope, a statement-form `.asm_expr` node is retagged in place to
> `.asm_global` (it IS module-scope global asm once surfaced), so lowering emits it exactly
> like an unwrapped block. The top-level restrictions from `parseAsmGlobal` are enforced
> with the same wording: a surfaced `asm volatile` or an operand/clobber-carrying block is
> diagnosed loudly (never silently dropped). Diagnostics are threaded into
> `flattenComptimeConditionals` for this.
>
> **Regression tests:** `examples/platform/1667-platform-wrapped-global-asm.sx`
> (`{ "aot": true, "target": "macos" }` — aarch64 asm behind `inline if OS ==` per-OS
> symbol-spelling arms; symbol DEFINED, linked, runs, exit 42; ir-only with pinned `.ir`
> on a non-matching host) + unit tests in `src/imports.test.zig` ("flatten: wrapped
> module-level asm surfaces as asm_global", "flatten: wrapped volatile/operand asm at
> module scope is diagnosed").

Status: **RESOLVED.** Carved out of issue 0193 (the linux fiber-runtime port). The port itself is
RESOLVED — it sidesteps this bug entirely by using a naked-sx-fn trampoline (`fib_tramp`) plus a
register-indirect `br x20` instead of a hand-written global-asm symbol, so there is **no live trigger
for this bug in the tree today.** It is filed standalone so the compiler defect is not lost.

## Symptom

A top-level global `asm { … }` block that defines a symbol (e.g. `.global _foo` / `_foo: …`) is
**not emitted** when it is wrapped in a comptime `inline if OS == { case … }` (or
`inline if OS == .linux { asm } else { asm }`). `nm main.o` shows the symbol as `U` (undefined) and
the link fails on both platforms. A PLAIN, unwrapped top-level `asm { … }` emits fine.

- **Observed:** symbol undefined, link error.
- **Expected:** the `asm` block in the taken comptime arm emits its template into the module's global
  asm exactly as an unwrapped block would (the comptime-conditional pre-pass already surfaces the
  taken arm's *other* top-level decls — fns, consts, imports — correctly; only the `asm_global` node
  is lost).

## Reproduction

**Not yet reproducible in isolation.** During the 0193 port, minimal/medium repros ALL emitted +
linked correctly: a top-level `asm` in a single `case`; two `case` blocks; a `case` asm in an
imported module; a naked fn + `case` asm with `bl` to an exported fn; a one-sided
`inline if .linux { #import }` before the asm. **Only the full `library/modules/std/sched.sx`
dropped it** — so the trigger is an interaction with something else in that module, not the wrapped
`asm` alone.

The exact form that triggered it (now replaced on the branch, recoverable from history): the original
global trampoline

```sx
asm {
    #string T
.global _fib_tramp
_fib_tramp:
    mov x0, x19
    bl _fib_dispatch
    brk #0
T,
};
fib_tramp :: () extern;
```

wrapped as

```sx
inline if OS == {
    case .linux: asm { #string T
fib_tramp:
    mov x0, x19
    bl fib_dispatch
    br x30
T, };
    case .macos: asm { #string T
.global _fib_tramp
_fib_tramp:
    mov x0, x19
    bl _fib_dispatch
    brk #0
T, };
}
```

dropped the asm in BOTH arms (whichever was taken). See `issues/0193-linux-fiber-port.patch` for the
full module context that triggers it, and the 0193 writeup for the larger investigation history.

## Investigation prompt (ready to paste)

> A top-level global `asm` block defining a symbol is dropped when wrapped in a comptime
> `inline if OS == { case … }` — but only inside the full `library/modules/std/sched.sx`; it can't be
> reproduced in isolation. Find where the surfaced `asm_global` node is lost between the
> comptime-conditional flatten and IR lowering.
>
> Key files:
> - `src/imports.zig` — `flattenComptimeConditionals` (line ~38) + `appendBranchDecls` (line ~72): the
>   pre-pass that surfaces a taken comptime arm's top-level decls. It *appears* correct — it appends
>   every node of the taken branch's block, `asm_global` included — so confirm the flattened slice
>   actually carries the `asm_global` node (dump `flat_decls` at `src/imports.zig:932`).
> - `src/ir/lower/decl.zig` — `lowerMainAndComptime` (line ~1494), whose `.asm_global` arm (line ~1503)
>   appends the verbatim template to `self.module.global_asm`. **Prime suspect:** does the lowering
>   entry point feed `lowerMainAndComptime` the *flattened* decl list, or a pre-flatten `root.decls`
>   that never contains the surfaced (formerly-nested) `asm_global`? If the asm-emission pass walks a
>   different decl list than the one flattening wrote to, a surfaced `asm_global` is silently skipped.
> - `src/ir/emit_llvm.zig:384` — where `module.global_asm` is concatenated into the LLVM module. If the
>   node never reached `global_asm`, it never emits.
>
> Steps: (1) build sched.sx's wrapped-asm variant (recover from `issues/0193-linux-fiber-port.patch`
> or git history of branch `fix/0192-qualified-import-const-comptime`), (2) instrument
> `flattenComptimeConditionals` to log whether the `asm_global` node survives into `flat_decls`,
> (3) instrument `lowerMainAndComptime` to log whether it ever *sees* an `asm_global`, (4) bisect what
> else in sched.sx must be present for the drop to occur (the isolation repros lacked it).
> Verification: `nm` the object shows the wrapped-asm symbol DEFINED (not `U`); the wrapped form links
> and runs identically to a plain unwrapped `asm`.
>
> **Verify it isn't a syntax issue first:** it reproduces with both the `case` and `if/else` forms,
> and plain unwrapped asm emits fine — so the wrapping, not the asm itself, is the trigger. That points
> to the flatten/lowering interaction, not user error.
