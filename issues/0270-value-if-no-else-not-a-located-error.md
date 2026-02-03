> **RESOLVED.** A no-`else` `if` used in VALUE position is now a located
> compile-time error emitted BEFORE lowering downstream. Fix (in
> `src/ir/lower/control_flow.zig`, `lowerIfExpr`): at the top of the function,
> when `self.force_block_value` is set (the flag that marks value position —
> `:=`/`=` RHS, call arg, `return`, operand, struct-literal field, array element,
> index) and the `if` has no `else`, emit
> `diagnostics.addFmt(.err, ie.condition.span, "an \`if\` used as a value must
> have an \`else\` branch")` and return a placeholder (the build aborts via
> `hasErrors`). Two supporting fixes stop `force_block_value` from leaking into
> genuine STATEMENT positions and producing false positives:
> (1) `lowerBlock` (statement mode) now clears `force_block_value` for the
> duration of the block — a leaked value flag (e.g. a void closure body lowered
> inside `f := closure((..) { if c {..} })`) no longer flags an inner guard-`if`;
> (2) `lowerBlockValue`'s implicit body tail does NOT force value-mode for a
> no-`else` guard-`if` (`isNoElseValuelessIf`), so a `-> !Err { if x<0 { raise } }`
> failable body still falls through as a success — the value-returning case is
> still caught by `lowerValueBody`'s existing "body produces no value" error.
> The `is_inline` clause was dropped from the check because an inline
> `if c then continue;` is a valid statement. Regression test:
> `examples/diagnostics/1200-diagnostics-value-if-no-else.sx`.

# 0270 — no-else block `if` in value position: no located error (silent `0` / LLVM crash)

## Symptom

A block-form `if` with **no `else`** has no value, but using it in value
position is not rejected with a clean located diagnostic. Instead:

- **As a call argument** — `take(if true { 1 })` silently passes `0` (exit 0, no
  diagnostic). **Observed:** `got 0`. **Expected:** a located type error like
  "if-expression used as a value must have an else branch".
- **As a declaration RHS** — `y := if true { 1 };` crashes in the backend.
  **Observed:** `LLVM verification failed: Cannot allocate unsized type` (`alloca
  void`) + "Call parameter type does not match … i64 undef". **Expected:** the
  same clean located type error, at compile time.

## Reproduction

```sx
#import "modules/std.sx";

take :: (x: i64) { print("got {}\n", x); }

main :: () {
    take(if true { 1 });   // silently "got 0" — should be a located error
}
```

```sx
#import "modules/std.sx";
main :: () {
    y := if true { 1 };    // LLVM: "Cannot allocate unsized type" — should be a located error
    print("{}\n", y);
}
```

Run:

```sh
./zig-out/bin/sx run repro.sx
```

## Notes on scope

- This is the "no value in value position" sibling of issues 0268 (block-`if`
  arg miscompiled) and 0269 (diverging arm). Here the `if` genuinely has no
  value (missing `else`); the correct behavior is a **compile-time located
  error**, not a silent `0` and not a backend crash.
- `is_value` in `lowerIfExpr` requires `has_else`
  (`src/ir/lower/control_flow.zig:182`), so a no-else `if` is always lowered as a
  statement (yielding `void`/`0`). When something consumes that as a value, no
  layer currently objects — the call site takes the `void`/`0`, and the `:=`
  path tries to `alloca void`.

## Suspected area / fix direction

Sema (type-checking) should flag a no-`else` `if` used in value position
(argument, `:=`/`=` RHS, `return`, operand, struct-literal field, array element,
index) as a located error, BEFORE lowering. Grep for where the value-vs-statement
context of an `if` is determined during sema (`src/sema.zig`) and where
expression-position is known; emit `diagnostics.addFmt(.err, span, "...")` when an
`if` in value position lacks an `else`. That converts both the silent-`0` arg
case and the `alloca void` decl crash into one clear diagnostic.

## Investigation prompt (paste into a fresh session)

> Fix issue 0270: a no-`else` block `if` used in value position is not a located
> error. `take(if true { 1 })` silently passes `0`; `y := if true { 1 };` crashes
> the backend with "Cannot allocate unsized type" (`alloca void`). Both should be
> a clean compile-time located diagnostic ("an `if` used as a value must have an
> `else` branch"). The lowering already gates value-ness on `has_else`
> (`src/ir/lower/control_flow.zig:182`), so the fix belongs in sema: detect an
> `if`/`match` in value position (call arg, `:=`/`=` RHS, `return`, operand,
> struct-literal field, array element, index) whose `else` is missing (or whose
> arms don't all yield a value) and emit a located error via
> `self.diagnostics.addFmt(.err, span, ...)`. Verify the two repros now produce a
> located error (not `got 0`, not an LLVM crash), that a well-formed `if…else` in
> value position still works, and that a no-else `if` used purely as a STATEMENT
> is still fine. Add a diagnostics regression example under
> `examples/diagnostics/…`, seed the marker, capture goldens scoped with `-Dname`.
