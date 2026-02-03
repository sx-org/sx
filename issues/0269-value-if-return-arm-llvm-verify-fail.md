> **RESOLVED.** Two distinct root causes drove Bug A and Bug B (the reopened
> defects); both are fixed, plus the `match` analog.
>
> **Bug A — SILENT WRONG VALUE (`return if c { 7 } else { return -1; }` → 0).**
> Root cause was NOT `result_type` inference — it was `force_block_value` being
> CLEAR in return position. `lowerReturn` never forced value-mode, so the return
> value's `if` was lowered with `is_value == false` and demoted to a void
> statement-`if` (`ret i64 0`). Why the mirror `{return -1} else {7}` "worked":
> the parser's `last_stmt_produces_value` leaks from the trailing arm — a live
> `{7}` else-arm (no `;`) sets it TRUE, so the body block became `produces_value`
> and `lowerBlockValue` happened to force value-mode; a diverging `{return -1;}`
> arm left it false. A coincidence, not correctness. **Fix:** `lowerReturn`
> (`src/ir/lower/stmt.zig`) now sets `force_block_value = true` when lowering a
> value for a non-void return — return-of-a-value IS value position, exactly like
> a `:=`/`=` RHS or a call arg. (A void return / `-> !` guard stays a statement.)
>
> **Bug B — CRASH (`x := if c { a := 1; a + 6 } else { return -1; }` → `alloca
> void`).** Here `force_block_value` was already true, but `result_type`
> inference fell back from the LIVE arm (whose tail `a + 6` reads a block-local
> `a`, so it types `.unresolved` without a scope) to the DIVERGING void `else`,
> collapsing to a void statement-`if`. **Fix** (`lowerIfExpr` in
> `src/ir/lower/control_flow.zig`): detect per-arm divergence up front
> (`armStaticallyDiverges` — a block ending in `return`/`raise`/`break`/
> `continue`, or a `noreturn` value) and infer `result_type` from a LIVE arm
> ONLY, never a diverging one. A live arm that can't be typed statically leaves
> `result_type == .unresolved`; it is then resolved from the arm's ACTUAL lowered
> value type and the merge phi param patched to match (`setMergeParamType`).
> Demote to a statement-`if` only when BOTH arms diverge or the live arm is
> genuinely void.
>
> **`match` analog.** A diverging FIRST arm made `inferMatchResultType`
> (`src/ir/lower/generic.zig`) return `.void` early (the arm's inner block typed
> void), collapsing a real value-`match` (`z := if e == { case .A: { return -9; }
> case .B: { 20 } }`) to a void statement → `alloca void`. Fixed by skipping a
> diverging arm (`armStaticallyDiverges`) so a live arm decides the type. The
> sibling issue 0271 (a value-`match` with a genuinely-void arm) is now a located
> error.
>
> **Regression test:** `examples/basic/0064-basic-value-if-return-arm.sx` — Bug A
> (return position, both arms symmetric), Bug B (multi-statement live arm, both
> symmetric), `:=`/`=`/call-arg positions, and `break`/`continue` diverging arms
> in a loop.
>
> --- original (partial) fix follows ---
>
> Root cause: a block used as an expression (`lowerExpr`'s
> `.block` arm) always appended a `const_int(0, .void)` placeholder as its
> value — *even when the block's statements had already terminated it* with a
> trailing `return`/`break`/`continue`. That placed a non-terminator
> instruction AFTER the `ret`/`br`, so `currentBlockHasTerminator()` (which
> only inspects the LAST instruction) reported the arm as *not* diverged; the
> value `if` lowering then emitted a second `br merge` → "terminator in the
> middle of a basic block". Fix: in `src/ir/lower/expr.zig` the `.block` arm now
> returns `Ref.none` (never read — the caller detects termination) instead of a
> `const_int` placeholder when `currentBlockHasTerminator()` is already true, for
> both the produces-value tail and the statement-loop tail. With the block no
> longer polluted past its terminator, the existing `else_diverged`/`then_diverged`
> guard in `lowerIfExpr` correctly suppresses the merge branch. Regression test:
> `examples/basic/0064-basic-value-if-return-arm.sx` (covers `:=`, call-arg, and
> a `break` arm).

# 0269 — value-position block `if` with a `return`-statement arm fails LLVM verification

## Symptom

A value-position block-form `if` whose one arm **diverges via a `return`
statement** (rather than a diverging *expression* like `process.exit(...)`)
produces invalid IR: the arm's block gets both the `return`'s terminator AND a
branch to the merge block.

- **Observed:** `LLVM verification failed: Terminator found in the middle of a
  basic block! label %if.else.1`.
- **Expected:** the diverging arm terminates its block (no branch to merge); the
  merge phi takes only the live arm — clean IR, compiles and runs.

## Reproduction

```sx
#import "modules/std.sx";

pick :: (c: bool) -> i64 {
    y := if c { 7 } else { return -1; };   // else arm diverges via `return`
    return y;
}

main :: () {
    print("{}\n", pick(true));    // want 7
    print("{}\n", pick(false));   // want -1
}
```

Run:

```sh
./zig-out/bin/sx run repro.sx
```

Current output:

```
LLVM verification failed: Terminator found in the middle of a basic block!
label %if.else.1
```

## Notes on scope

- Reproduces on the `:=` declaration path (as above) AND as a call argument
  (`take(if c { 7 } else { return -1; })`) — it is a general value-position
  `if`-lowering defect, not specific to any one consumer.
- The analogous case with a diverging **expression** works:
  `if c { 7 } else { process.exit(1) }` is handled — see the `noreturn`-arm
  branch in `lowerIfExpr` (`src/ir/lower/control_flow.zig`, ~lines 264-269 for
  the then-arm and ~294-298 for the else-arm). Those check
  `getRefType(v) == .noreturn` and emit `unreachable`. A `return` *statement*
  inside a block arm terminates the current block directly (via the return
  lowering) without producing a `noreturn` value for the arm, so the
  `currentBlockHasTerminator()` guard should catch it — verify why it doesn't in
  the value path (the arm is lowered as a value with `lowerExpr` on a block whose
  tail is a `return` statement; the terminator-already-present check may be
  bypassed before the `br merge` is emitted).

## Suspected area

`src/ir/lower/control_flow.zig`, `lowerIfExpr`, the `is_value == true` arms.
After lowering each arm's value, the code emits `br merge_bb` guarded by
`!currentBlockHasTerminator()`. When the arm is a block whose tail statement is
`return`, the block IS already terminated, so the guard should suppress the
branch — but the observed "terminator in the middle" says a branch (or the
return) landed after a terminator. Confirm the guard runs in the value path for
a block arm ending in a control-flow statement, mirroring what the statement
path (`is_value == false`) already does correctly.

## Investigation prompt (paste into a fresh session)

> Fix issue 0269: a value-position block `if` whose arm diverges via a `return`
> statement (`y := if c { 7 } else { return -1; };`) emits invalid IR — "Terminator
> found in the middle of a basic block". The diverging-*expression* case
> (`else { process.exit(1) }`) already works via the `noreturn`-value check in
> `lowerIfExpr` (`src/ir/lower/control_flow.zig`, ~264-298). A `return`
> *statement* terminates the arm's block without yielding a `noreturn` value, so
> the `!currentBlockHasTerminator()` guard before `br merge_bb` must be the thing
> that suppresses the extra branch — determine why it isn't suppressing it in the
> value path and fix so a block arm ending in `return`/`break`/`continue`
> terminates cleanly and only the live arm feeds the merge phi. Verify `pick(true)==7`,
> `pick(false)==-1`, both `:=` and call-argument positions, and that a
> both-arms-diverge `if` still lowers. Add a regression example under
> `examples/basic/…`, seed the marker, capture goldens scoped with `-Dname`.
