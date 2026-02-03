# 0259 — comptime nested if-as-expression returns the wrong value

> **RESOLVED** (2026-07-06). Root cause: the `.block` arm of `lowerExpr`
> (`src/ir/lower/expr.zig`) lowered a value-position block's LAST statement
> WITHOUT setting `force_block_value`, so a trailing nested if-else was demoted
> to a statement (`is_value = (is_inline or force_block_value) and has_else` →
> false) and its phi'd value was dropped — the merge blocks re-materialized a
> fresh `const_int 0` instead of threading the inner branch value. This only bit
> the **block-form** `#run { …; if … }` (the fn-call form `#run pick()` lowers
> the body through `lowerValueBody`/`lowerBlockValue`, which DO set the flag; by
> the time the 0236/0255 unification landed, the fn-call form of the original
> repro already passed — the bug survived in the block form). Runtime block-expr
> forms (`x := { …; if … }`) shared the same path and were equally wrong.
> Fix: `lowerExpr`'s `.block` arm now forces value-position lowering for the tail
> statement (and keeps it off for the preceding ones), mirroring `lowerBlockValue`.
> Regression test: `examples/comptime/0657-comptime-nested-if-value.sx` (block
> form + 3-level nesting + fn-call form) and a VM-level nested-value-merge unit
> test in `src/ir/comptime_vm.test.zig`. The VM itself was correct all along — it
> faithfully interpreted the malformed IR lowering handed it.
>
> NOTE: a **separate, pre-existing** bug was found while probing (NOT fixed here):
> a block-form `#run` whose tail is a value-position match with an if-expr arm
> (`#run { …; if b == { case 1: 100; else: if c {42} else {0}; } }`) panics with
> "unresolved type reached LLVM emission". The runtime-fn and `#run pick()` forms
> of the same code work. Reported for a separate session.

## Symptom

One-line: inside `#run`, a nested if-else EXPRESSION —
`if a { 100 } else { if b { 42 } else { 0 } }` with plain bool locals —
returns 0 instead of 42; no struct/aggregate involvement.

- Observed: the inner if's taken-branch value is lost (0 returned) —
  SILENT wrong value at comptime.
- Expected: 42.

Pre-existing (byte-identical on pre-0245 master, verified by the 0245
review's isolation, 2026-07-05). Runtime nested if-expressions work;
only the comptime evaluation path drops the inner value.

## Reproduction

```sx
#import "modules/std.sx";

pick :: () -> i64 {
    a := false;
    b := true;
    return if a { 100 } else { if b { 42 } else { 0 } };
}

K :: #run pick();

main :: () -> i32 {
    print("{}\n", K);   // observed: 0 — expected: 42
    0
}
```

(The 0245 review hit it via a #run block form; probe both the block and
the fn-call-#run forms, and `inline if` comptime forms for contrast.)

## Investigation prompt

The comptime VM / interpreter's if-expression evaluation
(src/ir/comptime_vm.zig or the interp — grep the cond-br/phi handling)
mis-merges nested value-position branches — likely the inner if's merge
result register is clobbered or the outer else-branch reads the wrong
slot. Trace the repro's IR (`sx ir`) and step the VM's block-arg/phi
handling for nested merges. Mind the issue-0236/0255 unification
landings (arm typing) — the IR shape may have changed recently; verify
the bug still repros on current master first. Verify: the repro prints
42; nested-deeper (3 levels) and mixed match-in-if comptime forms;
runtime forms unchanged; corpus comptime examples green.

Found by the adversarial review of the issue-0245 fix (2026-07-05);
pre-existing.
