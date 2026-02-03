# 0222 — variant-style match on an untagged union (no payload binding) emits invalid LLVM IR

> **RESOLVED (2026-07-03).** Root cause: `lowerMatch`
> (`src/ir/lower/control_flow.zig`) had no subject-type validation — an
> untagged-union subject fell through to the enum path, switching on the raw
> `[8 x i8]` union storage against `i0` case constants (arm-index fallback).
> Fix: a subject-type gate at the top of `lowerMatch` (after the pointer
> deref, before any block is built) rejects the whole variant-style match on
> an untagged-union subject — directly or through a pointer — with "cannot
> match on untagged union '<T>' — it has no discriminant; use a tagged union
> (enum with payloads) instead", and bails without lowering the arms. This
> SUBSUMES the issue-0163 arm-level union rejection (that branch is removed;
> the arm-level guard still covers payload-less enums / unknown variants);
> example 1211 regenerated to the folded subject-level wording. Non-case
> `==` on union VALUES was probed and does NOT work today either (invalid
> `icmp` on `[8 x i8]` — a separate pre-existing bug in the binary-`==`
> lowering, surfaced in this fix session's report for separate filing, not
> touched here). Regression test:
> `examples/diagnostics/1220-diagnostics-untagged-union-match.sx` (+ unit
> tests in `src/ir/lower.test.zig`).
>
> **Review fold.** Type-category patterns no longer bypass the gate: the
> exemption is a property of the SUBJECT (a Type value — `type_of(...)` /
> `$T`, which types `.type_value` and passes the allowlist on its own),
> never of the patterns — `case Shape:` / `case i64:` over a union VALUE is
> the same rejection (previously one pattern token re-opened the `[8 x i8]`
> switch). Also folded: a direct `Any` subject is rejected — the baseline
> dispatched on the unboxed VALUE, not the type tag, and silently picked
> the wrong arm (`Any = 6` matched `case 5:`, exit 0); match the
> `type_of(...)` result instead.

## Symptom

One-line: `if s == { case .circle: { 1 } case .rect: { 2 } }` on a plain
UNTAGGED `union` fails LLVM verification — `Switch constants must all be
same type as switch value!` — the switch scrutinee is the raw `[8 x i8]`
union storage while the case values are `i0 0`.

- Observed: `LLVM verification failed: Switch constants must all be same
  type as switch value!`, no diagnostic.
- Expected: a clean diagnostic — an untagged union has no discriminant,
  so a variant-style match cannot be evaluated at all (payload binding OR
  not). Likely correct behavior: reject the match at typecheck ("cannot
  match on untagged union 'Shape' — it has no discriminant; use a tagged
  union"), same family as the issue-0163 fix which rejected only the
  payload-BINDING form.

Pre-existing on master `e91df844` (reproduced there by the 0163 fix
worker); the 0163 writeup's claim that "removing the `(v)` binding works"
was wrong.

## Reproduction

```sx
#import "modules/std.sx";
Shape :: union { circle: i64; rect: i64; }
main :: () {
    s : Shape = .{ circle = 5 };
    r := if s == { case .circle: { 1 } case .rect: { 2 } };  // LLVM verify failure
    print("{}\n", r);
}
```

## Investigation prompt

In `lowerMatch` (`src/ir/lower/control_flow.zig`): the tag computation at
~line 1004 calls `enumTag(subject, .i32)` on a subject that is NOT a
tagged union — for a plain `.@"union"` the scrutinee stays the raw union
storage — and the case-value fallback `break :blk @intCast(i)` emits `i0`
constants for `.@"union"` subjects. The right fix is almost certainly to
REJECT the whole variant-style match on an untagged-union subject at the
top of the match lowering (before tag computation), with a diagnostic
mirroring the 0163 one ("cannot match on untagged union '<T>' — it has no
discriminant; use a tagged union (enum with payloads)"). This SUBSUMES
the 0163 binding-specific rejection — keep 0163's diagnostic (or fold the
two into one guard) and its regression example green. Check what an
untagged union in an `==` comparison against a VALUE (not case-style)
does today — don't break byte-comparison forms if they exist. Verify: the
repro exits 1 with the diagnostic; examples/diagnostics/1211 (0163's
regression) stays green; new diagnostics example pins this shape; full
corpus green.

Found by the issue-0163 fix worker (2026-07-03); reproduced on baseline
master e91df844.
