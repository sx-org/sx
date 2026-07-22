# 0352 — guard-narrowing honored at coercion sites but not member access

Status: FIXED 2026-07-23 — narrowing parity across every use position:
plain field reads (scalar, aggregate, nested chains), field WRITES
through a narrowed `?*T`, method-call receivers, and the inference
resolver (two-resolver lockstep). Regression:
examples/optionals/0929-optionals-narrowing-member-access.sx.

## Symptom

Issue 0179's flow narrowing proved a local present after a
`if x == null { return; }` guard, but only COERCION sites honored the
proof (call arguments, returns, arithmetic). Member positions did not:

    f :: (p: ?*T) -> i64 {
        if p == null { return 0; }
        return p.n;          // FAILED: field 'n' not found on '?*T'
    }
    p.n = 42;                // FAILED (write path)
    p.bump();                // FAILED: unresolved 'bump' (receiver path)

forcing the `snap := snap_opt!` dance everywhere (reported by Agra —
"narrowing is not working or this code is using `!` redundantly": the
call-argument `!`s were indeed redundant; the member-access ones were
required only because of this gap).

## Fix

The narrowed unwrap mirrors the coercion arm at each object-resolution
site, BEFORE the pointer auto-deref so `?*T` takes the ordinary
load-through route:
- `lowerFieldAccess` (reads) — src/ir/lower/expr.zig;
- the assignment field-target arm (writes; `?*T` children — an
  in-place payload write through a narrowed `?Struct` VALUE keeps the
  explicit spelling, it is a different lvalue) — src/ir/lower/stmt.zig;
- the method-call receiver — src/ir/lower/call.zig;
- the inference resolver's field_access arm (two-resolver lockstep) —
  src/ir/expr_typer.zig;
- `lowerExprAsPtr`'s field arm (lvalue/receiver chains: `#get`
  accessor receivers like `List.len`, address-of chains) —
  src/ir/lower/stmt.zig. This one surfaced last: `s.xs.cap` (plain
  field) worked while `s.xs.len` (accessor) failed, because the
  synthesized getter call materializes its receiver through the
  address path.

`?.` chains keep the optional; a NEW local from a narrowed value
(`q := p`) keeps the static optional type (spell `q := p!`) — only
guarded locals narrow, per the 0179 doctrine.

## Note

The first fix placement (after the auto-deref, dispatching the
unwrapped pointer straight to lowerFieldAccessOnType) MISCOMPILED
aggregate fields — the address flowed as the value. The regression
example pins the nested-aggregate read against that.
