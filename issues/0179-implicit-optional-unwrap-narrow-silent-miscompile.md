# 0179 — implicit `?T → <concrete>` unwrap silently miscompiles a NULL optional to garbage (whole family)

> **RESOLVED.** Root cause: `coerceMode`'s `.optional_unwrap` arm
> (`src/ir/lower/coerce.zig`) unwrapped any `?T → concrete` UNCONDITIONALLY,
> never reading the has_value flag — a null optional yielded its zero payload
> with no diagnostic. Fix took path (a) from the investigation prompt: **real
> flow-sensitive narrowing**. `?T → concrete` is now REJECTED at the coercion
> site (loud diagnostic listing `!` / `??` / binding / `!= null`) UNLESS the
> source is a local proven present by flow narrowing. Narrowing is tracked by
> name (`Lowering.narrowed`, region-scoped by `lowerBlock` / the if-then arm /
> a divergent `== null` guard / the `else` arm, killed on reassignment) and
> bridged to `coerceMode` via `narrowed_refs` (the loaded `Ref` of a narrowed
> identifier, tagged in `lowerIdentifier`). Closes the `?bool → bool` hole too
> (issue 0169's carve-out). specs.md §Optional Types + readme updated.
> Regressions: `examples/optionals/0919-optionals-flow-narrowing.sx` (narrowing
> works) + `examples/optionals/0920-optionals-no-implicit-unwrap.sx` (rejection);
> `0900-optionals-optionals.sx` now exercises genuine narrowing.
>
> **Out of scope / follow-up:** the binary-op operand auto-unwrap
> (`src/ir/lower/expr.zig` ~line 3211) is a SEPARATE silent-unwrap path that
> does NOT route through `classify`/`coerceMode` — `a + b` with a null `?T`
> still yields garbage with no diagnostic. Filed separately as issue 0185.

## Symptom

Passing an optional `?T` where a concrete `T`/other builtin is expected (function
arg, field initializer, `-> T` return) — WITHOUT any explicit `!`/`??`/binding —
compiles silently and unconditionally unwraps the payload. For a PRESENT optional
it yields the value; for a NULL optional it yields the zero/garbage payload with
NO diagnostic. Silent miscompile across the whole `?T → concrete` family. (Issue
0169 fixed only the `?T → bool` cell where `child != bool`; the rest of the
family — and the `?bool → bool` cell — remain.)

Per specs.md §Optional Types, the ONLY legal ways to extract `T` from `?T` are
`!` (force unwrap), `??` (coalesce), `if v := opt` / while-binding, pattern
match, and flow-sensitive narrowing after a `!= null` guard. There is NO implicit
unwrap-at-a-value-position. The `T → ?T` direction is the only implicit optional
conversion sanctioned.

## Reproduction

```sx
#import "modules/std.sx";
takes_i32 :: (x: i32) { print("got {}\n", x); }
main :: () {
  n : ?i64 = null;
  takes_i32(n);    // prints "got 0", exit 0 — silent miscompile (no diagnostic)
}
```

Confirmed silently wrong for the NULL case across: `?i64 → i32`, `?i64 → f64`,
`?f64 → i64`, `?i64 → u8`, `?i32 → i64` (widen), `?i64 → i64` (same type), and
`?bool → bool` (yields `false`). Present optionals unwrap the payload; null
optionals yield `0`/garbage. (Found during adversarial review of issue 0169.)

## Root cause

`src/ir/conversions.zig` (`CoercionResolver.classify`, the "Optional → Concrete
unwrap" rule, ~line 114): `if (child_ty == dst_ty or (dst_ty.isBuiltin() and
child_ty.isBuiltin()))` classifies any `?builtin → builtin` (and `?T → T`) as
`.optional_unwrap`. The emitter `emitOptionalUnwrap`
(`src/backend/llvm/ops.zig` ~2212) does an UNCONDITIONAL `ExtractValue` of the
payload field — it never reads the has_value flag — so a null optional yields its
zero payload. (The comptime VM's `optHas` path traps, so runtime and comptime
diverge.)

## Investigation prompt — NOTE: this is design-touching, resolve the semantics first

Per spec, implicit `?T → concrete` should be REJECTED entirely (require explicit
`!`/`??`/binding). Broadening issue 0169's `optional_to_bool_reject` to all
`?T → concrete` is the mechanical change (in `classify`), BUT it interacts with
flow-sensitive narrowing:

1. **Flow narrowing is not actually implemented as type refinement.** The
   non-binding `if x != null { use(x) }` spec example (specs.md §Flow-Sensitive
   Narrowing) currently "works" only because the broken unconditional unwrap
   fires everywhere, guard or not — there is no real narrowed type. The genuine
   narrowing mechanism is the BINDING form `if v := opt {}`
   (`src/ir/lower/control_flow.zig`), which emits an explicit `optional_unwrap`
   into a fresh `inner_ty` scope binding and does NOT route through `classify`.
   So a broad reject would reject the non-binding `if x != null { use(x) }`
   pattern. Decide: (a) implement real flow-sensitive type refinement so `x` is
   genuinely `T` inside the guarded branch (then the broad reject is safe), or
   (b) require the binding form / `!` / `??` and update specs.md §Flow-Sensitive
   Narrowing accordingly.
2. **Close the `?bool → bool` hole** — issue 0169's `child_ty != .bool` carve-out
   still silently unwraps a null `?bool` to `false`; per spec there's no implicit
   `?bool → bool` either.

Whichever path, the NULL case must never silently yield garbage. Verify the
present cases still work via the legal explicit forms; add regressions. This
likely warrants its own focused session given the flow-narrowing decision.
