# 0170 — closure optional `?(() -> ...)` alloca is sized one word, truncating the `{fn,env}` closure value

> **RESOLVED** (root cause differs from the title's hypothesis). Two findings:
> (1) the filed repro's `?(() -> void)` spelling is a TUPLE-optional (the `(T)`
> 1-tuple rule), now correctly diagnosed by the issue-0165 fix — not a closure
> bug. (2) The REAL closure-optional `?Closure(args) -> R` layout was already
> correct (sentinel form: the value IS the closure `{fn,env}`, has_value =
> `fn_ptr != null`); `if g` / `== null` / `!= null` already worked. The genuine
> bug was calling through an unwrapped optional closure `g!()` — the indirect-call
> catch-all `else` arm (`src/ir/lower/call.zig`) emitted `call_indirect` on the
> whole `{fn,env}` struct (LLVM "Called function must be a pointer!") with a
> hardcoded `.i64` return. Fix: the `else` arm inspects `inferExprType(callee)` —
> `.closure` → `call_closure` (threads env+ctx, returns `closure.ret`); else →
> `call_indirect` with the callee's real `function.ret`. Verified load-bearing
> (HEAD crashes) by 3 adversarial reviews; suite 785/0. Regression:
> `examples/closures/0311-closures-optional-closure.sx`. (Adjacent pre-existing
> bug found + filed: 0177 — array-element closure direct call `fns[i](args)`
> crashes.)
>
> **UPDATE (grouping):** with parenthesized-type grouping now in place,
> `?(() -> void)` parses as optional-of-(bare function pointer) `() -> void`,
> not a tuple-optional; assigning a closure literal to it correctly diagnoses the
> closure-vs-bare-fnptr mismatch (use `?Closure() -> void`). The `g!()`
> call-through fix here is unchanged and still correct for `?Closure(...)`.

## Symptom

An optional of a closure (`?(() -> void)`, `?Fn`) is mis-laid-out: the optional
alloca is typed `{ {ptr}, i1 }` (one pointer word + flag) but a closure value is
two words `{ {ptr, ptr}, i1 }` = `{ {fn, env}, has }`. Storing the two-word
closure constant into the one-word-typed alloca truncates it; reading the
has_value flag (`extractvalue …, 1`) then returns the closure's `env` word
(commonly null → 0 → `i1 false`) instead of the real flag. A PRESENT closure
optional therefore tests as ABSENT. Silent miscompile.

Independent of issue 0164 (the condition-reduction fix): `g != null` is also
wrong, so it's a layout/representation bug, not a truthiness bug.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  g : ?(() -> void) = () { print("called\n"); };
  if g       { print("present\n"); } else { print("absent\n"); }   // prints "absent" — WRONG
  if g != null { print("nn-present\n"); } else { print("nn-absent\n"); } // "nn-absent" — WRONG
}
```

Expected: `present` / `nn-present` (a freshly-assigned closure is present).
Observed: `absent` / `nn-absent`, exit 0.

## Investigation prompt

The optional-of-closure type lowering uses the wrong child layout — it sizes the
optional payload as a single pointer rather than the closure's `{fn, env}` fat
value. Suspect the optional type lowering / `toLLVMType` for `?Closure`
(`src/ir/types.zig` optional lowering + `src/backend/llvm/types.zig`), and the
`optional_wrap` / has_value codegen (`src/backend/llvm/ops.zig`
`emitOptionalWrap` / `emitOptionalHasValue`) — the payload offset/size and the
has_value flag offset must use the closure's full 2-word size. Compare against
the `?Closure` handling the comptime VM already documents (issue 0162's fix
notes a `?Closure` sentinel/`{fn,env}` layout). Decide the canonical runtime
repr (sentinel fn-ptr-null vs discriminated `{ {fn,env}, i1 }`) and make alloca
size, store, and has_value read all agree.

Verify: the repro prints `present` / `nn-present`; calling through the unwrapped
closure (`g!()`) prints `called`; a null `?Fn` tests absent. Add an
`examples/optionals/09xx-closure-optional.sx` regression (present + null +
call-through).
