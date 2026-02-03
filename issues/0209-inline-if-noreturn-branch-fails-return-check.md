# issue 0209 — `inline if` with a diverging (noreturn) live branch fails the function return-value check

> **RESOLVED** (2026-06-30). **Root cause:** a statement-position expression that
> diverges — a call to a `-> noreturn` fn such as `proc.exit` — emits only a
> `.call` op, which is NOT a block terminator (`currentBlockHasTerminator` counts
> only ret/ret_void/br/cond_br/switch_br/unreachable). So the basic block stayed
> "open"; when that diverging statement was the comptime-LIVE branch of an
> `inline if` (folded by `evalComptimeMatch` → `lowerInlineBranch`), the enclosing
> function looked value-less and the implicit-return check
> (`src/ir/lower/stmt.zig` `lowerValueBody`) wrongly fired "produces no value".
> This is what blocked `std/cli.sx`'s `os_args`/`os_argc` on Linux (the live
> branch there is the diverging `else`). **Fix:** in `lowerStmt`'s
> expression-statement arm (`src/ir/lower/stmt.zig`), when the statement's value
> type is `noreturn` and the block isn't already terminated, emit `unreachable`
> so the block is recognized as terminated. **Adversarially reviewed SAFE +
> CORRECT** (two independent reviewers): guard is precise (`Ref.none`→`.unresolved`,
> never `.noreturn`; only a `-> noreturn` callee yields a `.noreturn` Ref — no
> false positives); every `lowerStmt` caller re-checks termination
> (`lowerBlock`/`lowerBlockValue`/`lowerInlineBranch`); defer epilogue, loops,
> if-arms unaffected; dead code after the noreturn is correctly elided. Full suite
> **498/498, 876 examples 0 failed** (macOS); `cli.sx` compiles on aarch64-linux.
> **Regression test:** `examples/comptime/0655-comptime-inline-if-noreturn-branch.sx`.
> **Out of scope (separate sibling defects, NOT regressions — file individually if
> they bite):** (a) a *runtime* match (literal subject, not comptime-folded, e.g.
> `inline if 1 == { …all arms diverge… }`) leaves an unterminated `merge_bb` in
> `lowerMatch` and re-trips the same diagnostic; (b) a diverging call in
> *value-position* if/else arm (`x := if b { 10 } else { proc.exit(2) }`) fails
> LLVM PHI verification; (c) a comptime-folded block arm that yields a *value*
> (`inline if OS == { case .macos: { 7 } … }`) returns `0:void` instead of the
> block value (`lowerInlineBranch` at stmt.zig:63).

## Symptom

A function whose body is an `inline if` (comptime switch) where the
**comptime-selected (live) branch diverges** — ends in a `-> noreturn` call
such as `proc.exit(...)` — is wrongly rejected:

```
error: function returns 'i64' but its body produces no value — end it with a
trailing expression (no `;`) or an explicit `return`
  --> ...:8:12
   |
 8 |     inline if 1 == {
   |            ^^^^^^^^^
```

- **Observed:** the implicit-return check ([src/ir/lower/stmt.zig:202](../src/ir/lower/stmt.zig#L202)) fires even though the live branch is `noreturn` and control never falls through past the `inline if`.
- **Expected:** the function compiles. A comptime `inline if` whose live branch diverges makes the whole construct diverge, satisfying any return type (same as a bare trailing `proc.exit(0);`, which IS accepted).

Host-agnostic (reproduces on macOS and Linux): the bug depends on whether the
*live* branch diverges, not on the OS. It was **discovered via Linux CI** (C4)
because `library/modules/std/cli.sx`'s `os_args` / `os_argc` are written as
`inline if OS == { case .macos: { ... return ... } else: { proc.exit(...) } }`
— on Linux the live branch is the diverging `else`, so cli.sx fails to compile
(`examples/modules/0716-modules-cli-argv` → exit 1). On macOS the `.macos`
branch (which returns) is live, so the bug is invisible there.

## Reproduction

Minimal, standalone (only `modules/std.sx` + `modules/std/process.sx`):

```sx
#import "modules/std.sx";
proc :: #import "modules/std/process.sx";

f :: () -> i64 {
    inline if 1 == {
        case 1: { proc.exit(0); }   // comptime-live branch, diverges (noreturn)
        else:   { return 0; }
    }
}

main :: () { x := f(); print("{}\n", x); }
```

`./zig-out/bin/sx run issues/0209-inline-if-noreturn-branch-fails-return-check.sx`
→ `error: function returns 'i64' but its body produces no value`.

Control: replacing the body with a bare `proc.exit(0);` (no `inline if`) compiles
fine — so the divergence detection works for a plain noreturn tail but NOT when
the noreturn tail is the live branch of an `inline if`.

## Investigation prompt

The implicit-return diagnostic lives at
[src/ir/lower/stmt.zig:186-206](../src/ir/lower/stmt.zig#L186): after lowering a
function body that produced no explicit `return`, if the return type is non-void
and no prior error fired, it emits "produces no value" and then calls
`self.ensureTerminator(ret_ty)`. It does **not** check whether the current basic
block is already terminated / unreachable.

Hypothesis: `inline if` lowering (comptime switch — see `src/ir/lower/control_flow.zig`
and the comptime-`if`/switch path in `src/ir/lower/`) selects and lowers the live
branch, but then positions a fall-through *continuation/merge block* that is left
unterminated. Because the live branch diverged (`proc.exit` → `unreachable`/`ret`),
that merge block is dead, but the implicit-return code runs against it and sees
"no value." A plain trailing `proc.exit(0);` doesn't create a merge block, which
is why it's accepted.

Likely fix, in order of preference:
1. In the comptime `inline if`/switch lowering: when the live branch diverges
   (the builder's current block is already terminated after lowering it), do NOT
   emit/seal an unterminated fall-through block — mark the continuation
   unreachable so the function is correctly seen as diverging.
2. Or, defensively, in `stmt.zig` before line 191: if the current block is already
   terminated (query the builder for a current terminator / unreachable state),
   skip the "produces no value" diagnostic and just `return` (let
   `ensureTerminator` no-op). Confirm this doesn't mask genuine missing-value
   cases (it should only short-circuit when a real terminator exists).

Prefer (1) — it fixes the root (dead merge block) rather than suppressing the
symptom. Whatever the fix, the `inline if` must still error correctly when the
live branch does NOT diverge and produces no value.

Verification:
- `./zig-out/bin/sx run issues/0209-inline-if-noreturn-branch-fails-return-check.sx`
  must print nothing and exit 0 (the program calls `proc.exit(0)`).
- Negative test: an `inline if` whose live branch neither returns nor diverges
  must still error "produces no value".
- Then `library/modules/std/cli.sx` compiles on Linux and
  `examples/modules/0716-modules-cli-argv` passes — move the repro into the
  feature suite per the "Resolving an open issue" steps.

> Discovered during HTTPZ C4 (Linux CI bring-up). One of several Linux corpus
> failures; this one is a genuine compiler bug (not a host-divergent snapshot or
> a platform-only example), so it is filed rather than worked around.
