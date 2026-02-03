# 0164 — `if <optional>` with no binding silently folds the has_value test to `true`

> **RESOLVED.** Two colluding sites: `lowerIfExpr` emitted `optional_has_value`
> only for the binding form, and `emitCondBr`'s catch-all struct arm silently
> folded any non-i1 condition to `i1 true` ("structs always truthy"). Fix: reduce
> a bindingless optional condition to `optional_has_value` in `lowerIfExpr`/
> `lowerWhile`, add a shared `lowerBoolCondition` helper for `and`/`or` operands
> (the same defect affected `while`/`and`/`or`), and add a lowering-time
> diagnostic (`checkConditionType`/`isValidConditionType` in `lower/expr.zig`)
> rejecting conditions whose type isn't bool/integer/pointer/optional — turning
> the `emitCondBr` silent-true into a real type error and leaving the backend
> `@panic` as an unreachable tripwire. Regressions:
> `examples/optionals/0908-if-optional-no-binding.sx`,
> `0909-optionals-while-no-binding.sx`,
> `0910-optionals-and-or-optional-operands.sx`,
> `examples/diagnostics/1194-diagnostics-condition-non-bool-type.sx` (negative).
> Verified by 3 + 3 adversarial reviews. (Adjacent bugs found during review and
> filed separately: 0168 array-of-optionals element load, 0169 optional→bool
> coercion, 0170 closure-optional layout.)

## Symptom

Branching on an optional **without a binding** (`if opt { ... }`) takes the
present-branch unconditionally for any optional whose LLVM representation is a
struct (`?i64`, `?T`, `?f64`, …). The has_value flag is never read — the IR
emits `br i1 true`. SILENT MISCOMPILE (no diagnostic, wrong runtime result).

Pointer-sentinel optionals (`?cstring`, `?*T`, `?Closure`) are unaffected — they
lower to a bare `ptr` and hit the correct `icmp` path. The `if opt |x| { ... }`
*binding* form is also correct (it emits `optional_has_value`).

Observed vs expected: the repro prints `present` for a null optional; expected
`absent`.

## Reproduction

```sx
#import "modules/std.sx";
check :: (n: ?i64) { if n { print("present\n"); } else { print("absent\n"); } }
main :: () {
  a : ?i64 = null;
  b : ?i64 = 42;
  check(a);   // prints "present"  — WRONG, expected "absent"
  check(b);   // prints "present"  — correct
}
```

Reproduces identically for function-return init, literal-`null` init,
literal-value init, and param-passed optionals — universal, not init-path
specific.

## Investigation prompt

Two sites collude:

- `src/ir/lower/control_flow.zig` (`lowerIfExpr`, ~lines 69–72) emits
  `optional_has_value` **only when `ie.binding_name != null`**. For a bindingless
  `if opt`, it passes `cond = opt_val` (the raw `{T,i1}` aggregate) straight to
  `condBr`. Fix: emit `optional_has_value` whenever the condition's resolved type
  is an optional, binding or not.
- `src/backend/llvm/ops.zig` (`emitCondBr`, ~lines 2378–2383) has a catch-all
  `else`/struct arm that does `cond = LLVMConstInt(i1, 1, 0)` with the comment
  "Struct values are always truthy". This is exactly the REJECTED
  silent-fallback pattern (see CLAUDE.md). After the lowering fix, make this arm
  a LOUD bail (a non-i1, non-pointer condition reaching condBr is a compiler
  bug) rather than a silent `true`.

Verify: the repro prints `absent` / `present`; check the IR no longer contains
`br i1 true` for the optional condition. Add an
`examples/optionals/09xx-if-optional-no-binding.sx` regression covering null
and present `?i64`/`?T` without a binding, both branches.
