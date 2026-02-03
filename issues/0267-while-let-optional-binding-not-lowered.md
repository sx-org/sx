> **RESOLVED.** Root cause: `lowerWhile` (`src/ir/lower/control_flow.zig`)
> evaluated the condition but never consumed `we.binding_name`, so no
> unwrap/bind was emitted for the loop body. Fix: after `switchToBlock(body_bb)`
> and before `lowerBlock(we.body)`, mirror the `if val := opt` path — infer the
> optional's inner type, `optional_unwrap` the header's `cond_val`, `alloca` a
> slot (hoisted to entry, so it stays a single frame slot), `store` the
> unwrapped value, and `scope.put` the binding. Re-running the store each
> iteration binds the fresh payload; the header dominates the body so
> referencing `cond_val` there is valid SSA. Regression test:
> `examples/basic/0062-basic-while-let-optional-binding.sx`.

# 0267 — `while x := opt { }` optional binding is never lowered

## Symptom

The **while-optional binding** form documented in `specs.md`
(§ "While-Optional Binding") parses and type-checks, but the bound name is
**unresolved inside the loop body**.

- **Observed:** `error: unresolved 'v'` at the use site in the body.
- **Expected:** `v` bound to the unwrapped payload each iteration; loop runs
  while `expr` is non-null (exactly like the working `if v := opt { }` form).

## Reproduction

```sx
#import "modules/std.sx";

next3 :: (n: *i64) -> ?i64 {
    if n.* >= 3 { return null; }
    v := n.*; n.* += 1; return v;
}

main :: () {
    n := 0;
    while v := next3(@n) { print("v={}\n", v); }
}
```

Run:

```sh
./zig-out/bin/sx run repro.sx
```

Current output:

```
error: unresolved 'v' (in repro.sx fn main)
  --> repro.sx:9:44
   |
 9 |     while v := next3(@n) { print("v={}\n", v); }
   |                                            ^
```

Expected output:

```
v=0
v=1
v=2
```

The equivalent `if` form works today:

```sx
if v := next3(@n) { print("{}\n", v); }   // OK — binds v
```

## Root cause (located)

`WhileExpr` carries `binding_name` / `binding_span` in the AST
(`src/ast.zig:771-772`), the parser sets them (`src/parser.zig:3504-3514`),
sema is aware of them (`src/sema.zig:1176`), and `error_flow.zig` /
`semantic_diagnostics.zig` both handle `we.binding_name`.

**Only the lowering ignores it.** `lowerWhile`
(`src/ir/lower/control_flow.zig:375`) evaluates the condition but never
references `we.binding_name` — so no `optional_unwrap` + `alloca` + `scope.put`
is emitted for the body, and the name resolves to nothing. Compare the working
`if` path in the same file (`lowerIf`, lines ~230-242), which does exactly that
unwrap-and-bind.

## Investigation prompt (paste into a fresh session)

> Fix issue 0267: `while x := opt { }` optional binding is parsed and
> type-checked but never lowered, so the bound name is unresolved in the loop
> body (`error: unresolved 'x'`). The `if x := opt { }` form works.
>
> The gap is in `src/ir/lower/control_flow.zig`, function `lowerWhile` (~line
> 375). It never consumes `we.binding_name`. Mirror what `lowerIf` already does
> for `ie.binding_name` (~lines 230-242 in the same file): after
> `switchToBlock(body_bb)` and BEFORE `self.lowerBlock(we.body)`, if
> `we.binding_name` is set, infer the optional's inner type from
> `self.inferExprType(we.condition)`, emit `optional_unwrap` on the header's
> `cond_val`, `alloca` a slot of the inner type, `store` the unwrapped value,
> and `scope.put(bind_name, .{ .ref = slot, .ty = inner_ty, .is_alloca = true })`.
> Because the header dominates the body, referencing the header's `cond_val`
> Ref from the body block is valid SSA. The unwrap lives in the body so it
> re-runs each iteration (the condition is re-evaluated in the header each
> time).
>
> One nuance vs. `if`: `lowerWhile`'s condition handling only emits
> `optional_has_value` when the condition type is an optional (lines ~392-401).
> With a binding present the condition is ALWAYS an optional, so that branch
> already fires — no change needed there; just add the body-side unwrap+bind.
>
> Verify: move the repro `issues/0267-while-let-optional-binding-not-lowered.sx`
> to `examples/<category>/…` as a regression test (it currently fails to
> compile; after the fix it should print `v=0 / v=1 / v=2`). Seed the marker and
> capture goldens scoped with `-Dname=<path>`; run `zig build && zig build test`.

## Impact on other work

Discovered while adding an `iterator()` / `next() -> ?HashKV` API to the std
hash maps (`library/modules/std/map.sx`). The hash-map port itself does **not**
depend on this — iteration is fully usable via the working bare-optional loop
(`kv := it.next(); while kv { … kv = it.next(); }`) or the `next_used` /
`key_at` index-walk. This issue is an orthogonal, pre-existing language bug in
the `while`-binding sugar.
