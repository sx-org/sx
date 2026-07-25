# 0359 — a `#get` accessor on a call result silently reads garbage

Status: FIXED 2026-07-25 — the field-chain auto-deref applies only to
slot-producing objects. Regression:
examples/types/0893-types-accessor-on-call-result.sx.

## Symptom

Reaching a `#get` accessor through a call result answered a WRONG value,
with no diagnostic:

    Snap :: struct { xs: List(i64) = .{}; }
    Box  :: struct { a: Snap = .{}; ptr :: (self: *Box) -> *Snap { *self.a } }

    g.a.xs.append(1); g.a.xs.append(2);

    s := g.ptr(); s.xs.len     // 2   — correct
    g.ptr().xs.len             // 1   — WRONG
    g.opt()!.xs.len            // 1   — WRONG
    g.a.xs.len                 // 2   — correct
    g.ptr().xs.cap             // 4   — correct (plain field, not an accessor)

The returned garbage tracked the element type: `List(i64)` gave 0,
`List(Plain)` gave 1, `List(WithClosure)` gave 8961, and in the sudoku
game — `g_loop.snapshot()!.hit_list.len` — it segfaulted. A wrong count
that is sometimes plausible and sometimes fatal is the worst shape this
can take: the game's test read 1 region where there were 94, and only
crashed later.

Reported by Agra: the sudoku UI test crashed on a one-line helper,
`regions :: () -> i64 { g_loop.snapshot()!.hit_list.len }`, while the
identical two-line form worked.

## Cause

`lowerExprAsPtr` (src/ir/lower/stmt.zig) has arms for `identifier`,
`field_access`, `index_expr` and `deref_expr`, and a value FALLBACK for
everything else:

    // Fallback: lower as expression (may produce a value, not pointer)
    return self.lowerExpr(node);

A call — and a force-unwrap around one — takes that fallback and comes
back as the pointer VALUE. But the field_access arm then auto-dereffed
on the basis of "not an identifier":

    if (fa.object.data != .identifier and !obj_ty.isBuiltin()) {
        const info = self.module.types.get(obj_ty);
        if (info == .pointer) {
            obj_ptr = self.builder.load(obj_ptr, obj_ty);   // one level too far
            obj_ty = info.pointer.pointee;
        }
    }

That load is correct for `field_access` / `index_expr`, whose arms return
a GEP to a SLOT that may hold a pointer. For a call result there is no
slot: the value already IS the pointer, so the load read the pointee's
first bytes and used them as the base address of the accessor's receiver.

Plain fields escaped because they resolve through `fieldLvaluePtr` on the
same (already wrong) base and then load a scalar from it; a `#get` builds
a `*List(T)` receiver and calls through it, which is where the corrupt
base becomes visible — and where it can fault.

## Fix

Gate the auto-deref on the object shapes that actually produce a slot:

    const obj_is_slot = fa.object.data == .field_access or
        fa.object.data == .index_expr or
        fa.object.data == .deref_expr;

`deref_expr` is kept on the deref side deliberately — its arm returns
`lowerExpr(operand)` and its existing behavior is load-then-GEP; excluding
it would change a working path for no reason.

## Note

This is the same family as issue 0352's closing note — "`s.xs.cap` (plain
field) worked while `s.xs.len` (accessor) failed, because the synthesized
getter call materializes its receiver through the address path". That fix
made narrowing reach the address path; this one makes the address path
agree with itself about what a slot is. The `else => {}` value fallback in
`lowerExprAsPtr` is the standing hazard: every caller has to know which
arms return an address and which return a value, and here one did not.
