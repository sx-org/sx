# issue 0158 — a union struct-literal `.{ member = v }` silently miscompiles (wrong value / segfault) instead of being rejected

> **RESOLVED.** Root cause: a plain `union` literal fell through the generic
> struct-literal path (`getStructFields` returns empty for a union →
> `lowerStructLiteral` built a malformed `structInit` whose overlapping
> zero-fill clobbered the named member). Fix: chose to MAKE IT WORK (vs reject) —
> `lowerStructLiteral` now detects a plain-union target and dispatches to a new
> `lowerUnionLiteral` (`src/ir/lower/stmt.zig`) that writes each named member
> into a union-sized slot via the same lvalue resolver the `u.member = v`
> assignment path uses, then loads the union value back. Validity: the named
> members must share ONE arm (a single direct member, or several promoted
> members of the same anonymous-struct variant) — naming overlapping members, or
> members from different arms, is rejected with a diagnostic (no silent
> last-wins); a positional union literal is rejected as ambiguous; `.{}` yields
> an undefined union. specs.md §Union/Initialization updated. Regression:
> `examples/types/0194-types-union-literal-init.sx` (valid forms) +
> `examples/diagnostics/1191-diagnostics-union-literal-overlap.sx` (rejection).

## Symptom

A union initialized with a **struct literal** is silently accepted by the
compiler and produces the **wrong value** — with no diagnostic.

specs.md (§Union Types → Initialization) is explicit:

> Unions must be initialized with `---` (undefined) and then assigned per-field.

So a `.{ member = v }` literal is not a valid union initializer. But instead of
rejecting it, the compiler miscompiles it:

```
uninit form (correct): 3.140000      ← a : Overlay = ---; a.f = 3.14;
literal form (wrong):  0.000000      ← b : Overlay = .{ f = 3.14 };   (should be 3.14, or an error)
```

Observed: the named member's value is dropped (reads back `0.0`). A
type-punning read after the literal (`print("{}", b.i)`) additionally
**segfaults**, indicating the literal store corrupts/zeroes the slot rather than
writing the named member — the same silent-frame-corruption class as issue 0154.

Expected: either (preferred) a clean compile-time diagnostic — "a union must be
initialized with `--- ` then assigned per-field (see specs.md); struct-literal
init is not supported for unions" — or correct lowering that stores `v` into the
named member. A silently-wrong value (and a conditional segfault) is the
forbidden silent-corruption outcome.

## Reproduction

```sx
#import "modules/std.sx";
Overlay :: union { f: f32; i: i32; }
main :: () -> i64 {
    a : Overlay = ---;            // spec-mandated form — correct
    a.f = 3.14;
    print("correct: {}\n", a.f);  // 3.140000

    b : Overlay = .{ f = 3.14 };  // union struct-literal — silently MISCOMPILES
    print("wrong:   {}\n", b.f);  // 0.000000  ← bug
    return 0;
}
```

(repro: `issues/0158-union-struct-literal-silently-miscompiles.sx`)

## Investigation prompt

> The sx compiler silently miscompiles a union initialized with a struct literal
> (`b : Overlay = .{ f = 3.14 }` reads back `0.0` instead of `3.14`; a
> type-punning read afterwards segfaults). Per specs.md (§Union Types →
> Initialization) unions MUST be initialized with `--- ` then assigned per-field,
> so a struct literal is not a valid union initializer — but it is currently
> accepted and miscompiled rather than diagnosed. Repro:
> `issues/0158-union-struct-literal-silently-miscompiles.sx`.
>
> Trace the struct-literal lowering path (`src/ir/lower/` — the `.struct_literal`
> arm in expr/stmt lowering, and `lowerAssignment` in `src/ir/lower/stmt.zig`
> where a `name : T = .{...}` decl is lowered). At the point the literal's target
> type is known, check whether it resolves to a **union** TypeId
> (`module.types.get(ty) == .union_type` or equivalent). Decide the intended
> behavior:
>   - **Preferred (matches the spec):** emit a diagnostic via
>     `self.diagnostics.addFmt(.err, span, "a union must be initialized with `--- `
>     then assigned per-field; struct-literal init is not supported for unions
>     (see specs.md)", .{})` and do not lower the bad store. This makes the spec
>     rule enforced instead of silently violated.
>   - **Alternative (if union literals are wanted later):** lower a single-member
>     union literal correctly — store the one named member at offset 0 with the
>     member's type/size (NOT a whole-union-sized zero/aggregate store, which is
>     what currently drops the value and corrupts the slot — cf. issue 0154's
>     oversized-store class). Reject a literal naming ≥2 overlapping members.
>
> Verify: `sx run` the repro — expect either a clean compile error (preferred) or
> `wrong: 3.140000`, never a silent `0.0` and never a segfault. If diagnosing,
> add a `1xxx-diagnostics-union-struct-literal-rejected` example; if lowering,
> promote the repro to a regression under `examples/types/`.
