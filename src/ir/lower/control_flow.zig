const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const errors = @import("../../errors.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;
const ComptimeValue = Lowering.ComptimeValue;
const isTypeCategoryMatch = Lowering.isTypeCategoryMatch;

// ── Flow-sensitive narrowing (issue 0179) ───────────────────────
//
// `?T` only converts to a concrete `T` when the value is PROVEN present —
// otherwise the implicit unwrap silently yields the zero payload of a null
// optional (the bug). These helpers recognize the `!= null` / `== null`
// guard shapes and record which local names a branch / guard proves present;
// `lowerIdentifier` tags the loaded `Ref` of a narrowed name into
// `narrowed_refs`, and `coerceMode`'s `.optional_unwrap` arm only unwraps a
// tagged (proven-present) value.

/// The local-variable name if `node` is a bare identifier currently bound to
/// an OPTIONAL local/param in scope (the only thing flow-narrowing applies
/// to). Null for field paths, indexes, non-optionals, etc. — those keep the
/// explicit `!`/`??`/binding requirement.
pub fn narrowableLocal(self: *Lowering, node: *const Node) ?[]const u8 {
    if (node.data != .identifier) return null;
    const name = node.data.identifier.name;
    const scope = self.scope orelse return null;
    const b = scope.lookup(name) orelse return null;
    if (b.ty.isBuiltin()) return null;
    if (self.module.types.get(b.ty) != .optional) return null;
    return name;
}

/// If `bop` compares an optional local against the `null` literal (either
/// operand order), the narrowable local's name; else null.
pub fn nullCmpName(self: *Lowering, bop: ast.BinaryOp) ?[]const u8 {
    const lhs_null = bop.lhs.data == .null_literal;
    const rhs_null = bop.rhs.data == .null_literal;
    if (lhs_null == rhs_null) return null; // need exactly one `null` side
    return self.narrowableLocal(if (lhs_null) bop.rhs else bop.lhs);
}

/// Names proven present when `cond` is TRUE: `x != null`, and the `and` of
/// such tests (`a != null and b != null`).
pub fn collectPresentIfTrue(self: *Lowering, cond: *const Node, out: *std.ArrayList([]const u8)) void {
    if (cond.data != .binary_op) return;
    const bop = cond.data.binary_op;
    switch (bop.op) {
        .neq => if (self.nullCmpName(bop)) |n| out.append(self.alloc, n) catch {},
        .and_op => {
            self.collectPresentIfTrue(bop.lhs, out);
            self.collectPresentIfTrue(bop.rhs, out);
        },
        else => {},
    }
}

/// Names proven present when `cond` is FALSE: `x == null` (false ⇒ present),
/// and the `or` of such tests (`a == null or b == null` — false ⇒ both
/// present). This is the guard-narrowing case (`if a == null or b == null
/// { return }` proves both present afterwards).
pub fn collectPresentIfFalse(self: *Lowering, cond: *const Node, out: *std.ArrayList([]const u8)) void {
    if (cond.data != .binary_op) return;
    const bop = cond.data.binary_op;
    switch (bop.op) {
        .eq => if (self.nullCmpName(bop)) |n| out.append(self.alloc, n) catch {},
        .or_op => {
            self.collectPresentIfFalse(bop.lhs, out);
            self.collectPresentIfFalse(bop.rhs, out);
        },
        else => {},
    }
}

/// Snapshot the currently-narrowed names so a region (block / branch) can
/// restore them on exit. Returns a list the caller must `deinit`.
pub fn narrowSnapshot(self: *Lowering) std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).empty;
    var it = self.narrowed.keyIterator();
    while (it.next()) |k| list.append(self.alloc, k.*) catch {};
    return list;
}

/// Restore the narrowed-name set to a prior snapshot (drops anything added
/// since, re-adds anything killed since).
pub fn narrowRestore(self: *Lowering, saved: *std.ArrayList([]const u8)) void {
    self.narrowed.clearRetainingCapacity();
    for (saved.items) |n| self.narrowed.put(n, {}) catch {};
    saved.deinit(self.alloc);
}

/// Mark every name in `names` as narrowed (proven present) in the current set.
pub fn applyNarrowing(self: *Lowering, names: []const []const u8) void {
    for (names) |n| self.narrowed.put(n, {}) catch {};
}

/// Peel trivial single-block wrappers: a `match`-arm body is a block whose sole
/// statement is the braced `{ ... }` block, so divergence/void analysis must
/// look one level in. A no-op for the single-level blocks of an `if`/`else` arm.
fn unwrapArmBlock(node: *const Node) *const Node {
    var cur = node;
    while (cur.data == .block and cur.data.block.stmts.len == 1 and cur.data.block.stmts[0].data == .block) {
        cur = cur.data.block.stmts[0];
    }
    return cur;
}

/// Does this `if`/`match` arm statically DIVERGE — transfer control out of the
/// arm rather than yield a value? True when the arm is a block whose last
/// statement is a `return`/`raise`/`break`/`continue`, or when the arm
/// expression itself types `noreturn` (a diverging call like `process.exit()`).
/// A diverging arm never reaches the merge, so it must NOT decide a value-`if`'s
/// result type — the LIVE arm's type does (issue 0269): a diverging arm used to
/// drag `result_type` down to void/noreturn, demoting a live value-`if` into a
/// statement that returned 0 (Bug A) or `alloca void`'d (Bug B).
pub fn armStaticallyDiverges(self: *Lowering, node: *const Node) bool {
    const body = unwrapArmBlock(node);
    if (body.data == .block) {
        const stmts = body.data.block.stmts;
        if (stmts.len > 0) {
            switch (stmts[stmts.len - 1].data) {
                .return_stmt, .raise_stmt, .break_expr, .continue_expr => return true,
                else => {},
            }
        }
    }
    return self.inferExprType(body) == .noreturn;
}

/// An `if`/`match` arm body that yields NO value: a block with a `;`-discarded
/// tail (`produces_value == false`), an empty block, or a tail that is a
/// no-`else` `if` / statically types `void`. A DIVERGING arm (returns / breaks /
/// raises) is NOT "valueless" — it legitimately never reaches the merge — so
/// callers exclude it via `armStaticallyDiverges` first. Used to reject a
/// value-position `match` with a mix of value and void arms (issue 0271).
pub fn armYieldsVoid(self: *Lowering, node: *const Node) bool {
    const body = unwrapArmBlock(node);
    const tail = if (body.data == .block) blk: {
        // An empty block yields nothing.
        if (body.data.block.stmts.len == 0) return true;
        break :blk body.data.block.stmts[body.data.block.stmts.len - 1];
    } else body;
    // `null` contributes optionality (`?T`) — a real value in a value-`match`,
    // never void. (A trailing `;` on a `match` arm does NOT discard, so the arm
    // value is its tail EXPRESSION's type, not the block's `produces_value`.)
    if (tail.data == .null_literal) return false;
    // A no-`else` `if` tail yields no value.
    if (tail.data == .if_expr and tail.data.if_expr.else_branch == null and !tail.data.if_expr.is_inline) return true;
    return self.inferExprType(tail) == .void;
}

/// Does this value-`if`/ternary arm CONTRIBUTE a `null` — i.e. its yielded
/// value is the bare `null` literal (`{ null }` / `then null`), so the whole
/// `if` must produce an OPTIONAL (`?T`) with this arm lowered to `none` and the
/// other lowered to `some T` (issue 0272). A `null` tail types `.void` and so
/// never wins `result_type` on its own — this structural check is what forces
/// the optional. Recurses into a nested value-`if` tail so a chained
/// `if a { 1 } else if b { 2 } else { null }` is detected at the outer level.
/// A DIVERGING arm is excluded by the caller (it never reaches the merge).
pub fn armContributesNull(self: *Lowering, node: *const Node) bool {
    const body = unwrapArmBlock(node);
    const tail = if (body.data == .block) blk: {
        if (body.data.block.stmts.len == 0) return false;
        break :blk body.data.block.stmts[body.data.block.stmts.len - 1];
    } else body;
    if (tail.data == .null_literal) return true;
    // Nested value-`if` (chained `else if … else null`): a `null` deeper in the
    // chain still makes the outer expression optional.
    if (tail.data == .if_expr) {
        const nie = tail.data.if_expr;
        if (nie.else_branch) |eb| {
            if (self.armContributesNull(nie.then_branch)) return true;
            if (self.armContributesNull(eb)) return true;
        }
    }
    return false;
}

/// Does any NON-diverging arm of this `match` yield a bare `null` literal —
/// the match analog of `armContributesNull` (issue 0272). When TRUE and no
/// concrete arm decided the payload, the value-`match` must still lift to the
/// contextual optional `?T` (each `null` arm → `none`) rather than collapse to
/// a void statement-match that fabricates a PRESENT `{0,true}` at the `?T`
/// destination. A diverging arm (`return`/`raise`/…) never reaches the merge,
/// so it is excluded (mirrors `inferMatchResultType`).
pub fn matchContributesNull(self: *Lowering, me: *const ast.MatchExpr) bool {
    for (me.arms) |arm| {
        if (self.armStaticallyDiverges(arm.body)) continue;
        if (self.armContributesNull(arm.body)) return true;
    }
    return false;
}

/// Patch an already-created merge block's phi parameter type. Used when a live
/// value-`if`/`match` arm's type could not be inferred statically (a block whose
/// tail reads a block-local) — the arm's ACTUAL lowered value type resolves the
/// merge, so both the block's declared param (printed IR) and the phi
/// instruction must adopt it. The params slice is arena-owned (dup'd on create),
/// so patching in place is safe.
pub fn setMergeParamType(self: *Lowering, block: BlockId, ty: TypeId) void {
    const func = self.builder.module.getFunctionMut(self.builder.func.?);
    const params = func.blocks.items[block.index()].params;
    if (params.len > 0) {
        const mut: []TypeId = @constCast(params);
        mut[0] = ty;
    }
}

pub fn lowerIfExpr(self: *Lowering, ie: *const ast.IfExpr) Ref {
    // 0270: an `if` used in VALUE position (a value context — `:=`/`=` RHS,
    // call arg, `return`, operand, struct-literal field, array element, index)
    // MUST have an `else` branch. Without one the expression has no value: the
    // downstream lowering used to either silently pass `0` (const-folded
    // condition path) or `alloca void` in the backend. Reject it here with a
    // located diagnostic BEFORE lowering. Value position is signalled by
    // `force_block_value`; a no-`else` `if` used purely as a STATEMENT (incl. an
    // inline `if c then continue;` guard) is lowered with `force_block_value`
    // clear, so this guard never fires for it. A no-`else` `if` that is the
    // implicit valueless tail of a void/failable body is likewise exempt —
    // `lowerBlockValue` does not force value-mode for it (see `isNoElseValuelessIf`).
    if (self.force_block_value and ie.else_branch == null) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, ie.condition.span, "an `if` used as a value must have an `else` branch", .{});
        }
        // Placeholder so the caller has a Ref; the build aborts via hasErrors
        // before this value is ever consumed.
        return self.builder.constInt(0, .void);
    }

    // inline if: evaluate condition at compile time, only lower taken branch
    if (ie.is_comptime) {
        if (self.evalComptimeCondition(ie.condition)) |is_true| {
            if (is_true) {
                return self.lowerInlineBranch(ie.then_branch);
            } else if (ie.else_branch) |eb| {
                return self.lowerInlineBranch(eb);
            }
            return self.builder.constInt(0, .void);
        }
        // Condition couldn't be evaluated — fall through to runtime
    }

    // Check for constant-bool conditions (e.g., is_flags(T) → false) to avoid dead-code LLVM errors
    if (self.tryConstBoolCondition(ie.condition)) |is_true| {
        if (is_true) {
            // Condition always true: only lower then-branch
            if ((ie.is_inline or self.force_block_value) and ie.else_branch != null) {
                return self.lowerExpr(ie.then_branch);
            }
            self.lowerBlock(ie.then_branch);
            // If then-branch terminated (return/break), mark block as dead
            if (self.currentBlockHasTerminator()) {
                self.block_terminated = true;
                return .none;
            }
            return self.builder.constInt(0, .void);
        } else {
            // Condition always false: only lower else-branch (if any)
            if (ie.else_branch) |eb| {
                if (ie.is_inline or self.force_block_value) {
                    return self.lowerExpr(eb);
                }
                self.lowerBlock(eb);
                if (self.currentBlockHasTerminator()) {
                    self.block_terminated = true;
                    return .none;
                }
            }
            return self.builder.constInt(0, .void);
        }
    }

    // Optional binding: `if val := expr { ... }`
    // Clear target_type so the ternary's result type doesn't leak into the condition
    // (e.g., `if x != 0 then 1.0 else 2.0` — the `0` must be i64, not f32)
    const saved_cond_target = self.target_type;
    self.target_type = null;
    const opt_val = self.lowerExpr(ie.condition);
    self.target_type = saved_cond_target;
    // Whenever the condition is an optional we must test its has_value flag,
    // not the optional aggregate itself. This holds with OR without a binding:
    // a bare `if opt { }` must read has_value too (else the `{T,i1}` struct
    // reaches condBr and gets folded truthy — issue 0164). `optional_has_value`
    // handles every optional repr (struct `{T,i1}`, `?Closure` {fn,env},
    // pointer-sentinel `?*T`/`?cstring`), so this is uniform across all of them.
    const cond_ty = self.inferExprType(ie.condition);
    const cond_is_optional = blk: {
        if (ie.binding_name != null) break :blk true;
        if (cond_ty.isBuiltin()) break :blk false;
        break :blk self.module.types.get(cond_ty) == .optional;
    };
    // A bare `if <expr> { }` (no binding) must have a condition type that can
    // be tested as an i1 (bool/integer/pointer/optional). Anything else — a
    // struct, float, etc. — used to be folded truthy then `@panic` in the
    // backend (issue 0164); reject it here with a located type error. With a
    // binding (`if v := opt`) the condition is required to be an optional, so
    // the optional reduction below applies and we skip the bare-cond check.
    const cond = if (cond_is_optional)
        self.builder.emit(.{ .optional_has_value = .{ .operand = opt_val } }, .bool)
    else if (self.checkConditionType(cond_ty, ie.condition.span))
        opt_val
    else
        self.builder.constBool(false);
    const has_else = ie.else_branch != null;
    // If-else produces a value when inline OR when in value position (force_block_value)
    var is_value = (ie.is_inline or self.force_block_value) and has_else;

    // Which arms statically DIVERGE (never reach the merge). A diverging arm
    // contributes no value, so it must not decide `result_type` — the LIVE arm's
    // type does. When BOTH diverge the `if` yields nothing (merge unreachable).
    const then_div = is_value and self.armStaticallyDiverges(ie.then_branch);
    const else_div = is_value and has_else and self.armStaticallyDiverges(ie.else_branch.?);

    // Infer the result type from a LIVE (non-diverging) arm — NEVER fall back to
    // a diverging arm (that pulls the type to void/noreturn and collapses the
    // whole value-`if`; issue 0269). A live arm whose type isn't statically
    // inferable (e.g. a block whose tail reads a block-local — `if c { a := 1;
    // a + 6 }`) leaves `result_type == .unresolved` here; it is resolved from the
    // arm's ACTUAL lowered value below (Bug B) and the merge phi patched to match.
    var result_type: TypeId = if (is_value) blk: {
        var t: TypeId = .unresolved;
        if (!then_div) t = self.inferExprType(ie.then_branch);
        if ((t == .void or t == .unresolved or t == .noreturn) and has_else and !else_div) {
            const et = self.inferExprType(ie.else_branch.?);
            if (et != .void and et != .noreturn) t = et;
        } else if (has_else and !else_div and t != .void and t != .unresolved and t != .noreturn) {
            const et = self.inferExprType(ie.else_branch.?);
            if (et != .void and et != .unresolved and et != .noreturn) {
                if (self.unifyValueArmTypes(t, et)) |joined| t = joined;
            }
        }
        // Live arm not statically inferable AND not a plain `.unresolved`
        // literal we can pin from context (`null`/bare enum): use the
        // contextually expected type. Genuine `.unresolved` (block-local tail)
        // stays unresolved and is resolved post-lowering.
        if (t == .unresolved) {
            if (self.target_type) |tt| t = tt;
        }

        // Optional lift (issue 0272): a value `if` must produce an OPTIONAL
        // when the arms demand it — otherwise a `null` arm is coerced in a
        // concrete `T` context (a bogus present optional / 0) instead of a
        // proper `none`. Two triggers:
        //   (a) the context expects `?U` and the live arm typed the inner `U`
        //       (or `.unresolved`) — adopt `?U` so `U`→`some U`, `null`→`none`.
        //   (b) one arm structurally yields `null` and the other a concrete
        //       `T` — synthesize `?T`. No annotation needed; the arm→merge
        //       coercion below lifts each side (`void→?T`=none, `T→?T`=some).
        const then_null = !then_div and self.armContributesNull(ie.then_branch);
        const else_null = has_else and !else_div and self.armContributesNull(ie.else_branch.?);
        const t_is_optional = !t.isBuiltin() and t != .unresolved and self.module.types.get(t) == .optional;
        if (self.target_type) |tt| {
            if (!tt.isBuiltin() and self.module.types.get(tt) == .optional) {
                const inner = self.module.types.get(tt).optional.child;
                // Adopt the contextual `?U` when the live arm typed the inner
                // `U`, is unresolved, already IS `?U`, or is `void` because the
                // ONLY value-bearing arm was `null` (both arms `null` under a
                // `?U` target — both become `none`).
                if (t == inner or t == .unresolved or t == tt or
                    (t == .void and (then_null or else_null))) t = tt;
            }
        }
        // Re-check optionality after the contextual lift may have set `t = ?U`.
        const lifted_optional = t_is_optional or (!t.isBuiltin() and t != .unresolved and self.module.types.get(t) == .optional);
        if ((then_null or else_null) and !lifted_optional and
            t != .unresolved and t != .void and t != .noreturn)
        {
            // The non-`null` arm typed a concrete `T`; wrap to `?T`.
            t = self.module.types.optionalOf(t);
        } else if ((then_null and else_null) and !lifted_optional and (t == .void or t == .unresolved)) {
            // BOTH arms are `null` and no optional context pins the payload —
            // the result type is genuinely undeterminable. Reject loudly
            // rather than demote to a void statement-`if` that silently drops
            // the binding (mirrors the 0270 no-value diagnostic).
            if (self.diagnostics) |d| {
                d.addFmt(.err, ie.condition.span, "cannot infer the type of this `if` — both arms are `null`; annotate the destination with an optional type (e.g. `: ?T`)", .{});
            }
        }
        break :blk t;
    } else .void;

    // Demote to a statement-`if` only when the arms genuinely yield no value:
    // BOTH arms diverge (merge unreachable), or the live arm(s) are void blocks
    // (`;`-terminated → `result_type == .void`). An `.unresolved` result is NOT
    // valueless — it is a live arm we simply couldn't type statically (resolved
    // after lowering); demoting it would `alloca void` a real value (Bug B).
    if (is_value and ((then_div and else_div) or result_type == .void or result_type == .noreturn)) {
        is_value = false;
        result_type = .void;
    }

    const then_bb = self.freshBlock("if.then");
    const else_bb: ?BlockId = if (has_else) self.freshBlock("if.else") else null;
    const merge_params: []const TypeId = if (is_value) &.{result_type} else &.{};
    const merge_bb = self.freshBlockWithParams("if.merge", merge_params);

    // Conditional branch
    self.builder.condBr(
        cond,
        then_bb,
        &.{},
        if (else_bb) |eb| eb else merge_bb,
        &.{},
    );

    // Then branch
    self.builder.switchToBlock(then_bb);
    // If binding: unwrap the optional and bind to the name
    if (ie.binding_name) |bind_name| {
        const opt_ty = self.inferExprType(ie.condition);
        const inner_ty = if (!opt_ty.isBuiltin()) blk: {
            const info = self.module.types.get(opt_ty);
            break :blk if (info == .optional) info.optional.child else opt_ty;
        } else opt_ty;
        const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = opt_val } }, inner_ty);
        const slot = self.builder.alloca(inner_ty);
        self.builder.store(slot, unwrapped);
        if (self.scope) |scope| {
            scope.put(bind_name, .{ .ref = slot, .ty = inner_ty, .is_alloca = true });
        }
    }
    // Flow narrowing (issue 0179): which local names this condition proves
    // present in each arm. A binding `if v := opt` already unwraps `v`, so it
    // contributes nothing here.
    var present_true = std.ArrayList([]const u8).empty;
    defer present_true.deinit(self.alloc);
    var present_false = std.ArrayList([]const u8).empty;
    defer present_false.deinit(self.alloc);
    if (ie.binding_name == null) {
        self.collectPresentIfTrue(ie.condition, &present_true);
        self.collectPresentIfFalse(ie.condition, &present_false);
    }

    // Set target_type so null/undef in branches get the right type. A merge type
    // not yet resolved (`.unresolved` — block-local live-arm tail) provides no
    // hint; leave the ambient target so we don't stamp `.unresolved` onto arm
    // literals (it is filled from the live arm's actual type below).
    const saved_target = self.target_type;
    if (is_value and result_type != .void and result_type != .unresolved) self.target_type = result_type;
    var then_diverged = false;
    var else_diverged = false;
    var then_snap = self.narrowSnapshot();
    self.applyNarrowing(present_true.items);
    if (is_value) {
        var v = self.lowerExpr(ie.then_branch);
        // A value-position arm that DIVERGES (its value is `noreturn`, e.g. a
        // trailing `proc.exit(...)`) must terminate its block, NOT branch a
        // coerced-noreturn `<badref>` into the merge phi (LLVM verify failure).
        if (!self.currentBlockHasTerminator() and self.builder.getRefType(v) == .noreturn) {
            self.builder.emitUnreachable();
        }
        then_diverged = self.currentBlockHasTerminator();
        if (!then_diverged) {
            const v_ty = self.builder.getRefType(v);
            // A live arm whose type we could NOT infer statically RESOLVES the
            // merge type: adopt its actual value type and patch the phi (Bug B).
            // Otherwise coerce the value into the already-known merge type.
            if (result_type == .unresolved and v_ty != .void and v_ty != .unresolved) {
                result_type = v_ty;
                self.setMergeParamType(merge_bb, result_type);
                self.target_type = result_type; // hint the (later) else arm
            } else if (v_ty != result_type and v_ty != .void and result_type != .void and result_type != .unresolved) {
                v = self.coerceToType(v, v_ty, result_type);
            }
            self.builder.br(merge_bb, &.{v});
        }
    } else {
        self.lowerBlock(ie.then_branch);
        then_diverged = self.currentBlockHasTerminator();
        if (!self.currentBlockHasTerminator()) {
            self.builder.br(merge_bb, &.{});
        }
    }
    self.narrowRestore(&then_snap);

    // Else branch
    if (has_else) {
        self.builder.switchToBlock(else_bb.?);
        var else_snap = self.narrowSnapshot();
        self.applyNarrowing(present_false.items);
        if (is_value) {
            var v = self.lowerExpr(ie.else_branch.?);
            // Diverging value-position arm terminates rather than feeding a
            // `<badref>` to the merge phi (see the then-arm note above).
            if (!self.currentBlockHasTerminator() and self.builder.getRefType(v) == .noreturn) {
                self.builder.emitUnreachable();
            }
            else_diverged = self.currentBlockHasTerminator();
            if (!else_diverged) {
                const v_ty = self.builder.getRefType(v);
                // Symmetric to the then-arm: an unresolved merge (then-arm
                // diverged, this live else-arm has a block-local tail) is
                // resolved from this arm's actual value type.
                if (result_type == .unresolved and v_ty != .void and v_ty != .unresolved) {
                    result_type = v_ty;
                    self.setMergeParamType(merge_bb, result_type);
                } else if (v_ty != result_type and v_ty != .void and result_type != .void and result_type != .unresolved) {
                    v = self.coerceToType(v, v_ty, result_type);
                }
                self.builder.br(merge_bb, &.{v});
            }
        } else {
            self.lowerBlock(ie.else_branch.?);
            else_diverged = self.currentBlockHasTerminator();
            if (!self.currentBlockHasTerminator()) {
                self.builder.br(merge_bb, &.{});
            }
        }
        self.narrowRestore(&else_snap);
    }
    self.target_type = saved_target;

    // Guard form: `if <x == null ...> { <diverges> }` with no else proves the
    // tested names present for the remainder of the enclosing block. The
    // enclosing `lowerBlock` snapshot drops this narrowing at block end.
    if (!has_else and then_diverged) self.applyNarrowing(present_false.items);

    // Continue at merge
    self.builder.switchToBlock(merge_bb);
    // The merge block is REACHABLE (control falls through this `if`) unless BOTH
    // arms diverged with an explicit `else` covering the cond-false edge. Reset
    // `block_terminated` to that reachability so the flag — which an inline-if in
    // either arm may have set (control_flow.zig / stmt.zig `lowerInlineBranch`)
    // when its taken branch returned — does NOT leak past this merge and wrongly
    // drop the enclosing block's trailing statements. Mirrors the bare-`return`-
    // statement rule documented in `lowerBlock` (a return terminates its block but
    // never sets the flag).
    self.block_terminated = then_diverged and has_else and else_diverged;
    if (is_value) {
        return self.builder.blockParam(merge_bb, 0, result_type);
    }
    return self.builder.constInt(0, .void);
}

/// Try to evaluate an AST condition as a compile-time constant bool.
/// Returns true/false if the condition is known at compile time, null otherwise.
pub fn tryConstBoolCondition(self: *Lowering, node: *const Node) ?bool {
    switch (node.data) {
        .bool_literal => |bl| return bl.value,
        .call => |c| {
            if (c.callee.data == .identifier) {
                const cname = c.callee.data.identifier.name;
                // A RUNTIME Type argument (`t := type_of(av); if is_flags(t)`)
                // cannot const-fold — bail to the normal runtime lowering
                // (the rt table read). Folding through resolveTypeArg here
                // both emitted a spurious "unresolved type" diagnostic and
                // silently decided the branch.
                if (std.mem.eql(u8, cname, "is_flags")) {
                    if (c.args.len > 0) {
                        if (!self.isStaticTypeArg(c.args[0])) return null;
                        const ty = self.resolveTypeArg(c.args[0]);
                        if (!ty.isBuiltin()) {
                            const info = self.module.types.get(ty);
                            if (info == .@"enum") return info.@"enum".is_flags;
                        }
                    }
                    return false;
                }
                if (std.mem.eql(u8, cname, "is_identity") and c.args.len >= 1) {
                    // is_identity($T) → is T an `#identity` protocol? Folds so
                    // `inline if is_identity(T)` drops the dead branch whole
                    // (free's compile_error refusal lives in the taken one).
                    // Non-static arg → null; the lowering arm then reports the
                    // static-only requirement.
                    if (!self.isStaticTypeArg(c.args[0])) return null;
                    const ty = self.resolveTypeArg(c.args[0]);
                    if (self.getProtocolInfo(ty)) |pi| return pi.ownership == .identity;
                    return false;
                }
                if (std.mem.eql(u8, cname, "is_struct") and c.args.len >= 1) {
                    // is_struct($T) → is T a nominal `struct`? A comptime
                    // type-kind gate for field-wise reflection: folds here so
                    // `inline if is_struct(T)` elides the whole reflection branch
                    // (incl. `field_type(T,i)`) when T is an enum/scalar (issue 0274).
                    if (!self.isStaticTypeArg(c.args[0])) return null;
                    const ty = self.resolveTypeArg(c.args[0]);
                    if (ty.isBuiltin() or ty == .unresolved) return false;
                    return self.module.types.get(ty) == .@"struct";
                }
                if (std.mem.eql(u8, cname, "type_eq") and c.args.len >= 2) {
                    if (!self.isStaticTypeArg(c.args[0]) or !self.isStaticTypeArg(c.args[1])) return null;
                    const a = self.resolveTypeArg(c.args[0]);
                    const b = self.resolveTypeArg(c.args[1]);
                    return a == b;
                }
                if (std.mem.eql(u8, cname, "has_impl") and c.args.len >= 2) {
                    const ty = self.resolveTypeArg(c.args[1]);
                    return self.computeHasImpl(c.args[0], ty);
                }
            }
        },
        else => {},
    }
    return null;
}

pub fn lowerWhile(self: *Lowering, we: *const ast.WhileExpr) Ref {
    const header_bb = self.freshBlock("while.hdr");
    const body_bb = self.freshBlock("while.body");
    const exit_bb = self.freshBlock("while.exit");

    // Branch to header
    self.builder.br(header_bb, &.{});

    // Header: evaluate condition
    self.builder.switchToBlock(header_bb);
    const cond_val = self.lowerExpr(we.condition);
    // A bare optional loop condition (`while opt { }`) must test has_value,
    // exactly like `if opt { }` — otherwise the `{T,i1}` aggregate reaches
    // condBr and folds truthy (issue 0164). `optional_has_value` covers every
    // optional repr (struct / `?Closure` / pointer-sentinel). A non-condition
    // type (struct/float/...) is a located type error (same as `if`), not a
    // backend `@panic`.
    const cond = blk: {
        const cond_ty = self.inferExprType(we.condition);
        if (!cond_ty.isBuiltin() and self.module.types.get(cond_ty) == .optional) {
            break :blk self.builder.emit(.{ .optional_has_value = .{ .operand = cond_val } }, .bool);
        }
        if (!self.checkConditionType(cond_ty, we.condition.span)) {
            break :blk self.builder.constBool(false);
        }
        break :blk cond_val;
    };
    self.builder.condBr(cond, body_bb, &.{}, exit_bb, &.{});

    // Body
    self.builder.switchToBlock(body_bb);

    // Optional binding: `while val := expr { ... }` — bind the unwrapped
    // payload for the body (issue 0267). Mirrors the `if val := opt` path in
    // `lowerIfExpr`. The header (which dominates the body) already re-evaluated
    // the optional into `cond_val` this iteration, so unwrapping it here is
    // valid SSA and re-runs the store each iteration with the fresh value; the
    // `alloca` is hoisted to the entry block, so it stays a single frame slot.
    // With a binding the condition is always an optional, so the
    // `optional_has_value` test above already drove the loop exit.
    if (we.binding_name) |bind_name| {
        const opt_ty = self.inferExprType(we.condition);
        const inner_ty = if (!opt_ty.isBuiltin()) blk: {
            const info = self.module.types.get(opt_ty);
            break :blk if (info == .optional) info.optional.child else opt_ty;
        } else opt_ty;
        const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = cond_val } }, inner_ty);
        const slot = self.builder.alloca(inner_ty);
        self.builder.store(slot, unwrapped);
        if (self.scope) |scope| {
            scope.put(bind_name, .{ .ref = slot, .ty = inner_ty, .is_alloca = true });
        }
    }

    // Save and set loop targets
    const old_break = self.break_target;
    const old_continue = self.continue_target;
    const old_defer_base = self.loop_defer_base;
    self.break_target = exit_bb;
    self.continue_target = header_bb;
    self.loop_defer_base = self.defer_stack.items.len;
    defer {
        self.break_target = old_break;
        self.continue_target = old_continue;
        self.loop_defer_base = old_defer_base;
    }

    self.lowerBlock(we.body);
    if (!self.currentBlockHasTerminator()) {
        self.builder.br(header_bb, &.{});
    }

    // Continue at exit
    self.builder.switchToBlock(exit_bb);
    return self.builder.constInt(0, .void);
}

/// View a `List(T)`-like struct as its backing `items` pointer + element type
/// + live length, so `for list (x)` iterates the elements. Two shapes:
///   - CURRENT `List`: `{ items: []T, cap }` — `items` is a `[]T` slice whose
///     own `.ptr`/`.len` ARE the backing pointer and live count.
///   - LEGACY: `{ items: [*]T, len, … }` — a many-pointer `items` paired with a
///     sibling `len` field (kept so a user struct of that shape still iterates).
/// Null for anything that isn't such a struct.
pub fn listView(self: *Lowering, value: Ref, ty: TypeId) ?struct { data: Ref, data_ty: TypeId, len: Ref } {
    if (ty.isBuiltin()) return null;
    const info = self.module.types.get(ty);
    if (info != .@"struct") return null;
    const items_id = self.module.types.internString("items");

    // Current shape: an `items: []T` slice — view via its `.ptr`/`.len`.
    for (info.@"struct".fields, 0..) |f, i| {
        if (f.name == items_id and !f.ty.isBuiltin() and self.module.types.get(f.ty) == .slice) {
            const slice_val = self.builder.emit(.{ .struct_get = .{ .base = value, .field_index = @intCast(i) } }, f.ty);
            const elem = self.module.types.get(f.ty).slice.element;
            const mp_ty = self.module.types.manyPtrTo(elem);
            return .{
                .data = self.builder.emit(.{ .data_ptr = .{ .operand = slice_val } }, mp_ty),
                .data_ty = mp_ty,
                .len = self.builder.emit(.{ .length = .{ .operand = slice_val } }, .i64),
            };
        }
    }

    // Legacy shape: `items: [*]T` + a sibling `len` field.
    const len_id = self.module.types.internString("len");
    var items_idx: ?u32 = null;
    var items_ty: TypeId = .unresolved;
    var len_idx: ?u32 = null;
    for (info.@"struct".fields, 0..) |f, i| {
        if (f.name == items_id and !f.ty.isBuiltin() and self.module.types.get(f.ty) == .many_pointer) {
            items_idx = @intCast(i);
            items_ty = f.ty;
        } else if (f.name == len_id) {
            len_idx = @intCast(i);
        }
    }
    if (items_idx == null or len_idx == null) return null;
    return .{
        .data = self.builder.emit(.{ .struct_get = .{ .base = value, .field_index = items_idx.? } }, items_ty),
        .data_ty = items_ty,
        .len = self.builder.emit(.{ .struct_get = .{ .base = value, .field_index = len_idx.? } }, .i64),
    };
}

/// Lowered prep for one position of a multi-iterable `for` header. Every
/// position gets its own i64 cursor slot (ranges start at their `start`,
/// collections at 0); all cursors advance by 1 per iteration, and ONLY the
/// first position's bound terminates the loop (first-iterable-wins).
const IterPrep = struct {
    is_range: bool,
    slot: Ref,
    // Collection-only fields:
    data: Ref = Ref.none,
    data_ty: TypeId = .unresolved,
    elem_ty: TypeId = .unresolved,
    is_array: bool = false,
    storage: ?Ref = null, // array's own alloca when addressable (not deref'd)
};

/// `for it1, it2, ... (c1, c2, ...) { }` — parallel iteration. The first
/// iterable's length/bound drives the loop; the others follow by position.
/// Consequences of first-iterable-wins: a non-first range's end is never
/// lowered (its side effects do not run), and a shorter non-first collection
/// is read past its length on mismatch — the first iterable is the
/// authoritative one.
pub fn lowerFor(self: *Lowering, fe: *const ast.ForExpr) Ref {
    if (fe.is_inline) return self.lowerInlineRangeFor(fe);

    // A pack has no runtime value to iterate (Decision 1) — point the user
    // at `inline for`.
    for (fe.iterables) |it| {
        if (!it.is_range and it.expr.data == .identifier and self.isPackName(it.expr.data.identifier.name)) {
            return self.diagPackAsValue(it.expr.data.identifier.name, it.expr.span, .runtime_iter);
        }
    }

    var preps = std.ArrayList(IterPrep).empty;
    defer preps.deinit(self.alloc);
    var limit: Ref = Ref.none; // exclusive bound of position 0

    for (fe.iterables, 0..) |it, i| {
        if (it.is_range) {
            var start_ref = self.lowerExpr(it.expr);
            if (it.start_exclusive) start_ref = self.builder.add(start_ref, self.builder.constInt(1, .i64), .i64);
            const slot = self.builder.alloca(.i64);
            self.builder.store(slot, start_ref);
            if (i == 0) {
                // Parser guarantees the first iterable is bounded.
                var end_ref = self.lowerExpr(it.range_end.?);
                if (it.end_inclusive) end_ref = self.builder.add(end_ref, self.builder.constInt(1, .i64), .i64);
                limit = end_ref;
            }
            preps.append(self.alloc, .{ .is_range = true, .slot = slot }) catch unreachable;
        } else {
            var data = self.lowerExpr(it.expr);
            var data_ty = self.inferExprType(it.expr);

            // `*List` / `*[]T` etc. — deref to the collection value. Tracked
            // because a deref'd iterable's identifier binding holds the
            // POINTER, so its alloca is not the collection's storage.
            var was_deref = false;
            const ptr_info = if (data_ty.isBuiltin()) null else self.module.types.get(data_ty);
            if (ptr_info != null and ptr_info.? == .pointer) {
                data = self.builder.load(data, ptr_info.?.pointer.pointee);
                data_ty = ptr_info.?.pointer.pointee;
                was_deref = true;
            }

            // A `List(T)`-like struct iterates its `items[0..len]`;
            // arrays/slices use their intrinsic length.
            var len: Ref = Ref.none;
            if (self.listView(data, data_ty)) |lv| {
                data = lv.data;
                data_ty = lv.data_ty;
                len = lv.len;
            } else if (i == 0) {
                len = self.builder.emit(.{ .length = .{ .operand = data } }, .i64);
            }

            const elem_ty = self.getElementType(data_ty);
            if (elem_ty == .unresolved) {
                // Not a collection. The common trip: `for f(n) { }` — the
                // trailing parens are the CAPTURE, so the iterable is `f`.
                if (self.diagnostics) |d| {
                    if (data_ty == .unresolved) {
                        d.addFmt(.err, it.expr.span, "cannot iterate this expression — if the parens were call arguments, a call iterable also needs a capture (`for f(n) (x) {{ }}`) or parentheses (`for (f(n)) {{ }}`)", .{});
                    } else {
                        d.addFmt(.err, it.expr.span, "cannot iterate a value of type '{s}' — if the parens were call arguments, a call iterable also needs a capture (`for f(n) (x) {{ }}`) or parentheses (`for (f(n)) {{ }}`)", .{self.module.types.typeName(data_ty)});
                    }
                }
                return self.builder.constInt(0, .void);
            }
            const is_array = !data_ty.isBuiltin() and self.module.types.get(data_ty) == .array;
            const storage = if (is_array and !was_deref) self.getExprAlloca(it.expr) else null;
            const slot = self.builder.alloca(.i64);
            self.builder.store(slot, self.builder.constInt(0, .i64));
            if (i == 0) limit = len;
            preps.append(self.alloc, .{
                .is_range = false,
                .slot = slot,
                .data = data,
                .data_ty = data_ty,
                .elem_ty = elem_ty,
                .is_array = is_array,
                .storage = storage,
            }) catch unreachable;
        }
    }

    const header_bb = self.freshBlock("for.hdr");
    const body_bb = self.freshBlock("for.body");
    const inc_bb = self.freshBlock("for.inc");
    const exit_bb = self.freshBlock("for.exit");

    self.builder.br(header_bb, &.{});

    // Header: first cursor against the first bound.
    self.builder.switchToBlock(header_bb);
    const cur0 = self.builder.load(preps.items[0].slot, .i64);
    const cmp = self.builder.cmpLt(cur0, limit);
    self.builder.condBr(cmp, body_bb, &.{}, exit_bb, &.{});

    // Body: bind one capture per position (when captures are present).
    self.builder.switchToBlock(body_bb);

    var body_scope = Scope.init(self.alloc, self.scope);
    const old_scope = self.scope;
    self.scope = &body_scope;

    for (fe.captures, 0..) |cap, i| {
        const prep = preps.items[i];
        const cur = if (i == 0) cur0 else self.builder.load(prep.slot, .i64);
        if (prep.is_range) {
            body_scope.put(cap.name, .{ .ref = cur, .ty = .i64, .is_alloca = false, .origin = .range_index });
            continue;
        }
        const bind_ty = if (cap.by_ref) self.module.types.ptrTo(prep.elem_ty) else prep.elem_ty;
        const elem = if (cap.by_ref) blk: {
            // A slice value carries its backing pointer, so GEP on it writes
            // through. An array is a value — GEP needs its storage (alloca)
            // or mutations would hit a copy.
            const base = if (prep.is_array) (prep.storage orelse prep.data) else prep.data;
            break :blk self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = cur } }, bind_ty);
        } else blk: {
            // By-value over an array with addressable storage: GEP + load ONE
            // element. `index_get` on the array VALUE spills the whole array
            // to a temp on every iteration — O(N²) bytes copied per loop.
            if (prep.storage) |storage| {
                const elem_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = storage, .rhs = cur } }, self.module.types.ptrTo(prep.elem_ty));
                break :blk self.builder.load(elem_ptr, prep.elem_ty);
            }
            break :blk self.builder.emit(.{ .index_get = .{ .lhs = prep.data, .rhs = cur } }, bind_ty);
        };
        body_scope.put(cap.name, .{ .ref = elem, .ty = bind_ty, .is_alloca = false, .is_ref_capture = cap.by_ref, .origin = .for_element });
    }

    // Save and set loop targets
    const old_break = self.break_target;
    const old_continue = self.continue_target;
    const old_defer_base = self.loop_defer_base;
    self.break_target = exit_bb;
    self.continue_target = inc_bb; // continue → increment, not header
    self.loop_defer_base = self.defer_stack.items.len;

    self.lowerBlock(fe.body);

    self.break_target = old_break;
    self.continue_target = old_continue;
    self.loop_defer_base = old_defer_base;
    self.scope = old_scope;
    body_scope.deinit();

    // Fall through to increment block
    if (!self.currentBlockHasTerminator()) {
        self.builder.br(inc_bb, &.{});
    }

    // Increment block: advance every cursor and jump back to header.
    self.builder.switchToBlock(inc_bb);
    {
        const one = self.builder.constInt(1, .i64);
        for (preps.items) |prep| {
            const cur = self.builder.load(prep.slot, .i64);
            const next = self.builder.add(cur, one, .i64);
            self.builder.store(prep.slot, next);
        }
        self.builder.br(header_bb, &.{});
    }

    // Continue at exit
    self.builder.switchToBlock(exit_bb);
    return self.builder.constInt(0, .void);
}

/// Comptime-unrolled `inline for`. Iterables are comptime ranges and/or
/// PACKS, mirroring the runtime multi-iterable contract: position 0 drives
/// the iteration count (a pack's arity, or a bounded range's span) and
/// trailing range bounds are ignored. Per iteration the body is lowered
/// once; a range capture binds as an `int_val` comptime constant (so
/// `xs[i]` substitutes the concrete per-position argument), and a pack
/// capture binds as an AST alias for the synthesized `xs[<i>]`
/// (`Binding.pack_elem`), inheriting full pack-element semantics —
/// substitution, typing, and the interface-only constraint check.
///
///   inline for 0..xs.len (i) { xs[i].show(); }      // index form
///   inline for xs (x) { x.show(); }                 // element form
///   inline for xs, 0.. (x, i) { ... }               // element + index
pub fn lowerInlineRangeFor(self: *Lowering, fe: *const ast.ForExpr) Ref {
    const IterClass = union(enum) {
        range: i64, // comptime start value
        pack: []const u8, // pack name
    };
    var classes = std.ArrayList(IterClass).empty;
    defer classes.deinit(self.alloc);
    var count: i64 = 0;

    for (fe.iterables, 0..) |it, idx| {
        if (it.is_range) {
            var start = self.evalComptimeInt(it.expr) orelse {
                if (self.diagnostics) |d| d.addFmt(.err, it.expr.span, "inline for: range start is not a compile-time integer", .{});
                return self.builder.constInt(0, .void);
            };
            if (it.start_exclusive) start += 1;
            if (idx == 0) {
                const end_node = it.range_end orelse {
                    if (self.diagnostics) |d| d.addFmt(.err, it.expr.span, "inline for: the first range must be bounded — `inline for 0..N (i) {{ }}`", .{});
                    return self.builder.constInt(0, .void);
                };
                var end = self.evalComptimeInt(end_node) orelse {
                    if (self.diagnostics) |d| d.addFmt(.err, end_node.span, "inline for: range end is not a compile-time integer", .{});
                    return self.builder.constInt(0, .void);
                };
                if (it.end_inclusive) end += 1;
                count = end - start;
            }
            classes.append(self.alloc, .{ .range = start }) catch unreachable;
        } else if (it.expr.data == .identifier and self.isPackName(it.expr.data.identifier.name)) {
            const name = it.expr.data.identifier.name;
            const len: i64 = if (self.pack_param_count) |ppc| @intCast(ppc.get(name) orelse 0) else 0;
            if (idx == 0) {
                count = len;
            } else if (len < count) {
                if (self.diagnostics) |d| d.addFmt(.err, it.expr.span, "inline for: pack '{s}' has {} element{s} but the unroll is {} iterations", .{
                    name, len, if (len == 1) @as([]const u8, "") else @as([]const u8, "s"), count,
                });
                return self.builder.constInt(0, .void);
            }
            classes.append(self.alloc, .{ .pack = name }) catch unreachable;
        } else {
            if (self.diagnostics) |d| d.addFmt(.err, it.expr.span, "inline for: each iterable must be a comptime range or a pack — `inline for 0..N (i) {{ }}` / `inline for xs (x) {{ }}`", .{});
            return self.builder.constInt(0, .void);
        }
    }

    // `(*x)` on a pack element: there is no storage to borrow — an element
    // is an AST-substituted call argument.
    for (fe.captures, 0..) |cap, ci| {
        if (cap.by_ref and ci < classes.items.len and classes.items[ci] == .pack) {
            const sp = cap.span orelse fe.iterables[ci].expr.span;
            if (self.diagnostics) |d| d.addFmt(.err, sp, "a pack element cannot be captured by reference", .{});
            return self.builder.constInt(0, .void);
        }
    }

    const CursorSave = struct { name: []const u8, had_prev: bool, prev: ComptimeValue };

    var i: i64 = 0;
    while (i < count) : (i += 1) {
        var body_scope = Scope.init(self.alloc, self.scope);
        const old_scope = self.scope;
        self.scope = &body_scope;

        var saves = std.ArrayList(CursorSave).empty;
        defer saves.deinit(self.alloc);

        for (fe.captures, 0..) |cap, ci| {
            if (cap.name.len == 0) continue;
            switch (classes.items[ci]) {
                .range => |start| {
                    // Bind the cursor both as a runtime value (constInt, for
                    // uses like `print(i)`) and as a comptime constant (for
                    // `xs[i]` substitution).
                    const v = start + i;
                    body_scope.put(cap.name, .{ .ref = self.builder.constInt(v, .i64), .ty = .i64, .is_alloca = false, .origin = .range_index });
                    var save = CursorSave{ .name = cap.name, .had_prev = false, .prev = undefined };
                    if (self.comptime_constants.get(cap.name)) |p| {
                        save.had_prev = true;
                        save.prev = p;
                    }
                    saves.append(self.alloc, save) catch {};
                    self.comptime_constants.put(cap.name, .{ .int_val = v }) catch {};
                },
                .pack => |pack_name| {
                    const span = fe.iterables[ci].expr.span;
                    const id_node = self.alloc.create(Node) catch break;
                    id_node.* = .{ .span = span, .data = .{ .identifier = .{ .name = pack_name } } };
                    const idx_node = self.alloc.create(Node) catch break;
                    idx_node.* = .{ .span = span, .data = .{ .int_literal = .{ .value = i } } };
                    const elem_node = self.alloc.create(Node) catch break;
                    elem_node.* = .{ .span = span, .data = .{ .index_expr = .{ .object = id_node, .index = idx_node } } };
                    const elem_ty = self.inferExprType(elem_node);
                    body_scope.put(cap.name, .{ .ref = Ref.none, .ty = elem_ty, .is_alloca = false, .pack_elem = elem_node, .origin = .pack_elem_alias });
                },
            }
        }

        self.lowerBlock(fe.body);

        for (saves.items) |save| {
            if (save.had_prev) {
                self.comptime_constants.put(save.name, save.prev) catch {};
            } else {
                _ = self.comptime_constants.remove(save.name);
            }
        }

        self.scope = old_scope;
        body_scope.deinit();

        if (self.currentBlockHasTerminator()) break;
    }

    return self.builder.constInt(0, .void);
}

pub fn lowerMatch(self: *Lowering, me: *const ast.MatchExpr) Ref {
    // inline if match: evaluate at compile time, only lower the matching arm
    if (me.is_comptime) {
        if (self.evalComptimeMatch(me)) |arm_body| {
            return self.lowerInlineBranch(arm_body);
        }
        // `inline if T == { case <category|Type>: … }` over a BOUND generic
        // type param: select the arm by T's kind at lower time, siblings
        // dropped whole (each kind arm only type-checks for its own kind).
        if (self.evalStaticTypeMatch(me)) |sel| {
            switch (sel) {
                .body => |arm_body| return self.lowerInlineBranch(arm_body),
                // No arm matched, no `else:` — the runtime form's
                // skip-to-merge, statically: nothing to lower.
                .none_matched => return self.builder.constInt(0, .void),
            }
        }
        // Couldn't evaluate — fall through to runtime
    }

    var is_type_match = isTypeCategoryMatch(me);
    var subject = self.lowerExpr(me.subject);
    var subject_ty = self.inferExprType(me.subject);
    // A pointer subject (e.g. a `for xs: (*x)` element capture) matches
    // through the deref (specs §for, by-reference capture): deref to the
    // pointed-to tagged union/enum so tag/payload extraction works, and to
    // an integer/bool pointee so the value drives the switch directly.
    if (!subject_ty.isBuiltin()) {
        const sinfo = self.module.types.get(subject_ty);
        if (sinfo == .pointer) {
            const pointee = sinfo.pointer.pointee;
            const deref_ok = blk: {
                if (pointee.isBuiltin()) break :blk switch (pointee) {
                    .bool, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .isize, .usize => true,
                    else => false,
                };
                break :blk switch (self.module.types.get(pointee)) {
                    .signed, .unsigned, .tagged_union, .@"enum" => true,
                    else => false,
                };
            };
            if (deref_ok) {
                subject = self.builder.load(subject, pointee);
                subject_ty = pointee;
            }
        }
    }
    // TYPE SWITCH (Step-4 phase 2): an `any` subject dispatches on its
    // runtime type TAG — `if av == { case i64: (v) {…} case Point: (p) {…}
    // case struct: {…} else: {…} }`. Concrete arms (named, builtin, and
    // composite types) may bind the typed value; category arms are tag
    // SETS and bind nothing; arms overlap first-wins with a loud
    // unreachable-arm diagnostic. Protocol values as SUBJECTS stay refused
    // (no tag — the phase-2 RTTI story).
    // A PROTOCOL subject type-switches through its {ctx, type_id} prefix
    // view (RTTI Option B) — the scrutinee/captures are exactly the any
    // switch's, over the concrete value the protocol erases.
    if (self.getProtocolInfo(subject_ty) != null) {
        const void_ptr_ty = self.module.types.ptrTo(.void);
        const ctx_ref = self.builder.structGet(subject, 0, void_ptr_ty);
        const tid_ref = self.builder.structGet(subject, 1, .type_value);
        subject = self.builder.makeAny(tid_ref, ctx_ref);
        subject_ty = .any;
    }
    const is_any_switch = subject_ty == .any;
    if (is_any_switch) is_type_match = true;
    const is_optional_match = blk: {
        if (!subject_ty.isBuiltin()) {
            const info = self.module.types.get(subject_ty);
            break :blk info == .optional;
        }
        break :blk false;
    };
    // An error-set subject (`catch e == { case .X: ... }` / `if e == { ... }`):
    // the value IS its u32 tag id, and `case .X` matches the global tag id
    // of `X`. Used by ERR E1.5's catch match-body form.
    const is_error_set_match = blk: {
        if (!subject_ty.isBuiltin()) {
            break :blk self.module.types.get(subject_ty) == .error_set;
        }
        break :blk false;
    };

    // Subject-type gate (issues 0222 / 0224): a case-style match dispatches on
    // a discriminant — an enum / tagged-union tag, an error tag, an optional's
    // has_value bit, an integer/bool value, or a type id. Any other subject has
    // no valid switch scrutinee, and letting it through hands the backend
    // invalid IR (a raw `[8 x i8]` union scrutinee, `switch ptr`, or
    // `switch double` against integer case constants). Reject up front with a
    // located diagnostic and bail — the arms are never lowered.
    //
    // Type-category matches get NO exemption here (review fold): a genuine
    // type match's subject is a Type VALUE — a `type_of(...)` result or a
    // `$T` binding — which types `.type_value` and passes the allowlist below
    // on its own. Exempting on `is_type_match` (a property of the PATTERNS,
    // not the subject) let a single `case U:` / `case string:` pattern token
    // over a runtime union/string VALUE re-open the exact invalid-IR hole
    // this gate closes; and a direct `Any` subject dispatched on its unboxed
    // VALUE instead of its type tag — the silently-wrong arm, exit 0. Both
    // now diagnose: match on the `type_of(...)` result, not the value.
    if (!is_optional_match and !is_error_set_match) {
        const dispatchable = blk: {
            if (subject_ty.isBuiltin()) break :blk switch (subject_ty) {
                .bool, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .isize, .usize, .type_value => true,
                // `any` is the TYPE SWITCH: it dispatches on the value's
                // runtime type tag (word 0 of the view), never on the
                // unboxed payload.
                .any => true,
                else => false,
            };
            break :blk switch (self.module.types.get(subject_ty)) {
                .signed, .unsigned, .@"enum", .tagged_union => true,
                else => false,
            };
        };
        if (!dispatchable) {
            // An untagged union (directly, or through a pointer — the deref
            // above never fires for untagged unions) gets its own wording:
            // the type EXISTS but carries no discriminant to match on. Same
            // family as the arm-level payload-binding rejection (issue 0163),
            // which this subject-level gate subsumes for union subjects.
            const union_ty: ?TypeId = blk: {
                if (subject_ty.isBuiltin()) break :blk null;
                const ti = self.module.types.get(subject_ty);
                if (ti == .@"union") break :blk subject_ty;
                if (ti == .pointer and !ti.pointer.pointee.isBuiltin()) {
                    if (self.module.types.get(ti.pointer.pointee) == .@"union") break :blk ti.pointer.pointee;
                }
                break :blk null;
            };
            if (self.diagnostics) |diags| {
                if (union_ty) |uty| {
                    diags.addFmt(.err, me.subject.span, "cannot match on untagged union '{s}' — it has no discriminant; use a tagged union (enum with payloads) instead", .{self.formatTypeName(uty)});
                } else if (subject_ty == .unresolved) {
                    // The subject's own lowering usually diagnosed already
                    // (undefined identifier, failed lookup, …) — don't stack a
                    // second error on it. If nothing fired, still refuse loudly:
                    // bailing silently here would swallow the failure.
                    if (diags.errorCount() == 0) {
                        diags.addFmt(.err, me.subject.span, "cannot determine the type of this match subject", .{});
                    }
                } else {
                    diags.addFmt(.err, me.subject.span, "cannot match on '{s}' — match subjects must be enums, tagged unions, error sets, optionals, integers, bools, or Type values", .{self.formatTypeName(subject_ty)});
                }
            }
            // Bail with an inert placeholder — compilation aborts on the
            // diagnostic(s) above before any code is emitted.
            return self.builder.constUndef(.i64);
        }
    }

    // Determine if the match produces a value (has non-void arms)
    // For type-category matches (inside any_to_string), only produce value when force_block_value
    // For regular enum/optional matches, always produce value if arms are non-void
    var inferred_result = self.inferMatchResultType(me);
    // Arms not statically inferable (bare enum literals etc.): only a
    // value-position match (`force_block_value`) needs a concrete result —
    // use the contextually expected type. A statement match with non-value
    // arms is a side-effect (void); don't let a leaked `target_type` turn
    // it into a value match.
    if (inferred_result == .unresolved) {
        inferred_result = if (self.force_block_value) (self.target_type orelse .unresolved) else .void;
    }
    // Optional lift (issue 0272, match analog): a value-position `match` whose
    // only value-bearing arms are `null` — all arms `null`, or `null` + arms
    // that don't decide (diverging / unresolved) — must still produce an
    // OPTIONAL. `inferMatchResultType` only lifts to `?T` when a CONCRETE arm
    // decided the payload (its `has_null → optionalOf(r)` tail); when NO arm
    // decided, it returns `.void`/`.noreturn`/`.unresolved`, so `has_value_merge`
    // is false, the match lowers as a void statement, and the `y : ?T = <void>`
    // assignment fabricates a PRESENT `{0,true}` instead of `none`. Mirror the
    // both-null / null+diverging `if` fix: adopt the contextual optional target
    // so each `null` arm lowers to `none`; with no target to pin the payload,
    // reject loudly rather than silently lower to void.
    if (self.force_block_value and !is_type_match and
        (inferred_result == .void or inferred_result == .noreturn or inferred_result == .unresolved) and
        self.matchContributesNull(me))
    {
        if (self.target_type) |tt| {
            if (!tt.isBuiltin() and self.module.types.get(tt) == .optional) inferred_result = tt;
        }
        if (inferred_result == .void or inferred_result == .noreturn or inferred_result == .unresolved) {
            if (self.diagnostics) |d| {
                d.addFmt(.err, me.subject.span, "cannot infer the type of this `match` — its value arms are all `null`; annotate the destination with an optional type (e.g. `: ?T`)", .{});
            }
        }
    }
    // 0271: a value-position `match` (`force_block_value`) whose arms are MIXED —
    // some yield a real value, some yield void (a bare-statement tail or a
    // no-`else` `if`) — cannot build a well-typed merge phi: the void arm used to
    // reach the backend as `alloca void` / `i64 undef`. Reject the offending
    // arm(s) with a located error, mirroring the 0270 value-`if`-without-`else`
    // diagnostic. All-void arms = a statement `match` (fine); all-value arms =
    // fine; only the MIX is an error. A diverging arm (`return`/`break`/…) is
    // exempt — it legitimately never reaches the merge. Type-category matches are
    // exempt too (their void arms are intentional skip-to-merge branches).
    if (self.force_block_value and !is_type_match) {
        var any_value = false;
        var any_void = false;
        for (me.arms) |arm| {
            if (self.armStaticallyDiverges(arm.body)) continue;
            if (self.armYieldsVoid(arm.body)) any_void = true else any_value = true;
        }
        if (any_value and any_void) {
            if (self.diagnostics) |diags| {
                for (me.arms) |arm| {
                    if (self.armStaticallyDiverges(arm.body)) continue;
                    if (self.armYieldsVoid(arm.body)) {
                        diags.addFmt(.err, arm.body.span, "this `match` arm is used as a value but yields no value — every arm of a value `match` must produce a value", .{});
                    }
                }
            }
        }
    }
    const is_value = if (is_type_match) self.force_block_value else (self.force_block_value or (inferred_result != .void and inferred_result != .unresolved));
    const result_type: TypeId = if (is_value) inferred_result else .void;
    // A fully-diverging match (`result_type == .noreturn` — every arm
    // `return`s / `raise`s / etc.) produces no value, so it builds no
    // merge phi; its arms terminate and the merge block is unreachable.
    const has_value_merge = is_value and result_type != .void and result_type != .noreturn;
    const merge_params: []const TypeId = if (has_value_merge) &.{result_type} else &.{};
    const merge_bb = self.freshBlockWithParams("match.merge", merge_params);

    // Build arm blocks
    var default_bb: ?BlockId = null;
    var arm_blocks = std.ArrayList(BlockId).empty;
    defer arm_blocks.deinit(self.alloc);
    for (me.arms) |_| {
        arm_blocks.append(self.alloc, self.freshBlock("match.arm")) catch unreachable;
    }

    // Build case list and pre-collect type tags per arm
    var cases = std.ArrayList(inst_mod.SwitchBranch.Case).empty;
    defer cases.deinit(self.alloc);
    var arm_tag_values = std.ArrayList([]const u64).empty;
    defer arm_tag_values.deinit(self.alloc);
    // Type switch: the CONCRETE type an arm names (null for category arms /
    // the default) — the capture phase binds `(v)` as this type; and the
    // first-wins claim set — a tag belongs to the first arm that names it,
    // and an arm left with no tags is a LOUD unreachable-arm error (the
    // overlap `case int:` / `case i64:` would otherwise resolve silently
    // by order).
    var arm_concrete = std.ArrayList(?TypeId).empty;
    defer arm_concrete.deinit(self.alloc);
    for (me.arms) |_| arm_concrete.append(self.alloc, null) catch unreachable;
    var claimed = std.AutoHashMap(u64, void).init(self.alloc);
    defer claimed.deinit();

    for (me.arms, 0..) |arm, i| {
        if (arm.pattern == null) {
            default_bb = arm_blocks.items[i];
            arm_tag_values.append(self.alloc, &.{}) catch unreachable;
            continue;
        }
        const pat = arm.pattern.?;

        if (is_any_switch) {
            // TYPE SWITCH arm: a category keyword names a tag SET; anything
            // else is a type expression — named, builtin, or composite
            // (`case []u8:` / `case *Point:` / `case ?i64:`) — resolved by
            // the same resolver every type position uses, to ONE tag.
            const cat_name: []const u8 = switch (pat.data) {
                .identifier => |id| id.name,
                .type_expr => |te| te.name,
                else => "",
            };
            if (std.mem.eql(u8, cat_name, "protocol")) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, pat.span, "'case protocol:' needs a compile-time subject — use `inline if` over a generic type param (a protocol value carries no runtime type tag)", .{});
                arm_tag_values.append(self.alloc, &.{}) catch unreachable;
                continue;
            }
            const raw_tags: []const u64 = blk_rt: {
                if (cat_name.len > 0 and Lowering.isRuntimeCategoryName(cat_name)) {
                    break :blk_rt self.resolveTypeCategoryTags(cat_name);
                }
                switch (pat.data) {
                    .identifier, .type_expr, .pointer_type_expr, .many_pointer_type_expr, .slice_type_expr, .optional_type_expr, .array_type_expr, .call => {},
                    else => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, pat.span, "a type switch arm names a type or a category — value patterns don't apply to an `any` subject", .{});
                        break :blk_rt &.{};
                    },
                }
                const ty = self.resolveTypeArg(pat);
                if (ty == .unresolved) break :blk_rt &.{}; // resolveTypeArg diagnosed
                arm_concrete.items[i] = ty;
                const one = self.alloc.alloc(u64, 1) catch break :blk_rt &.{};
                one[0] = ty.index();
                break :blk_rt one;
            };
            // First-wins: an earlier arm's claim removes the tag here; an
            // arm whose every tag is already claimed can never run.
            var eff = std.ArrayList(u64).empty;
            for (raw_tags) |t| {
                if (claimed.contains(t)) continue;
                claimed.put(t, {}) catch unreachable;
                eff.append(self.alloc, t) catch unreachable;
            }
            if (raw_tags.len > 0 and eff.items.len == 0) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, pat.span, "this arm is unreachable — earlier arms already claim every type it names (a concrete arm must come BEFORE the category that contains it)", .{});
            }
            arm_tag_values.append(self.alloc, eff.items) catch unreachable;
            for (eff.items) |tag| {
                cases.append(self.alloc, .{
                    .value = @intCast(tag),
                    .target = arm_blocks.items[i],
                    .args = &.{},
                }) catch unreachable;
            }
            continue;
        }

        if (is_type_match) {
            // Type-category match: resolve category name to tag values
            const name = switch (pat.data) {
                .identifier => |id| id.name,
                .type_expr => |te| te.name,
                else => "",
            };
            // The `protocol` category exists only in the STATIC fold (an
            // `inline if` over a bound generic type param) — a protocol
            // value carries no runtime tag to switch on until the phase-2
            // RTTI story, so a runtime arm would be silently dead.
            if (std.mem.eql(u8, name, "protocol")) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, pat.span, "'case protocol:' needs a compile-time subject — use `inline if` over a generic type param (a protocol value carries no runtime type tag)", .{});
                arm_tag_values.append(self.alloc, &.{}) catch unreachable;
                continue;
            }
            // E4 single-hop visibility + ambiguity gate: a SPECIFIC 2-flat-hop
            // type name in a type-match arm (`case COnly:`) is not bare-visible
            // (consistent with annotations / 0763); ≥2 direct flat same-name
            // authors are ambiguous (loud diagnostic, 0755/0767). A category
            // keyword (`int`, `struct`, …) is not a type author anywhere → the
            // gate is a no-op (`.proceed`) and `resolveTypeCategoryTags` expands
            // it. A source-keyed specific TYPE author — including the querying
            // source's OWN author over a same-name flat import (own-wins, 0754) —
            // matches on ITS TypeId, NOT whichever same-name author a global
            // `findByName` (inside `resolveTypeCategoryTags`) would pick.
            const raw_tv: []const u64 = blk_tv: {
                // A pattern that cannot name a type is a value pattern —
                // refuse pointedly (mirrors the any switch), never a
                // silently dead arm.
                switch (pat.data) {
                    .identifier, .type_expr, .pointer_type_expr, .many_pointer_type_expr, .slice_type_expr, .optional_type_expr, .array_type_expr, .call => {},
                    else => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, pat.span, "a type-category match arm names a type or a category — value patterns don't apply to a 'Type' subject", .{});
                        arm_tag_values.append(self.alloc, &.{}) catch unreachable;
                        continue;
                    },
                }
                if (name.len > 0) {
                    switch (self.headTypeGate(name, pat.span)) {
                        .ambiguous, .not_visible => {
                            arm_tag_values.append(self.alloc, &.{}) catch unreachable;
                            continue;
                        },
                        .resolved => |tid| {
                            const tv = self.alloc.alloc(u64, 1) catch unreachable;
                            tv[0] = tid.index();
                            break :blk_tv tv;
                        },
                        // Category keywords are not type authors anywhere,
                        // so the gate proceeds for them; a category may
                        // legitimately resolve to an EMPTY set (no such
                        // types registered), which must not fall through
                        // to the type resolver's unknown-name error.
                        .proceed => {
                            if (Lowering.isRuntimeCategoryName(name))
                                break :blk_tv self.resolveTypeCategoryTags(name);
                        },
                    }
                }
                // A specific type — builtin (`case i64:`), user-named, or
                // a composite type expression — through the full resolver,
                // which diagnoses unknown names. (Issue 0315: builtins
                // resolved through findByName's user-type map here, got
                // zero tags, and the arm was silently dead.)
                const ty = self.resolveTypeArg(pat);
                if (ty == .unresolved) break :blk_tv &.{}; // resolveTypeArg diagnosed
                const tv = self.alloc.alloc(u64, 1) catch unreachable;
                tv[0] = ty.index();
                break :blk_tv tv;
            };
            // First-wins, mirroring the any-subject type switch: a tag
            // belongs to the first arm that names it. Categories overlap
            // (`enum`/`union` share tagged unions, `int` contains `i64`),
            // and a duplicate switch case is invalid IR — before the
            // claim set, an overlap was an LLVM verifier crash.
            var eff_tv = std.ArrayList(u64).empty;
            for (raw_tv) |t| {
                if (claimed.contains(t)) continue;
                claimed.put(t, {}) catch unreachable;
                eff_tv.append(self.alloc, t) catch unreachable;
            }
            if (raw_tv.len > 0 and eff_tv.items.len == 0) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, pat.span, "this arm is unreachable — earlier arms already claim every type it names (a concrete arm must come BEFORE the category that contains it)", .{});
            }
            arm_tag_values.append(self.alloc, eff_tv.items) catch unreachable;
            for (eff_tv.items) |tag| {
                cases.append(self.alloc, .{
                    .value = @intCast(tag),
                    .target = arm_blocks.items[i],
                    .args = &.{},
                }) catch unreachable;
            }
        } else if (is_optional_match) {
            // Optional match: .some → 1 (has_value=true), .none → 0
            arm_tag_values.append(self.alloc, &.{}) catch unreachable;
            const pat_name = switch (pat.data) {
                .enum_literal => |el| el.name,
                .identifier => |id| id.name,
                else => "",
            };
            const case_val: u64 = if (std.mem.eql(u8, pat_name, "some")) 1 else 0;
            cases.append(self.alloc, .{
                .value = @intCast(case_val),
                .target = arm_blocks.items[i],
                .args = &.{},
            }) catch unreachable;
        } else {
            // Enum/value match: resolve variant name to actual tag value
            arm_tag_values.append(self.alloc, &.{}) catch unreachable;
            const case_val: u64 = blk: {
                const pat_name = switch (pat.data) {
                    .enum_literal => |el| el.name,
                    .identifier => |id| id.name,
                    .int_literal => |il| break :blk @intCast(il.value),
                    .char_literal => |cl| break :blk @intCast(cl.value),
                    .bool_literal => |bl| break :blk @as(u64, if (bl.value) 1 else 0),
                    else => break :blk @as(u64, @intCast(i)),
                };
                // Look up variant value in the subject's type
                if (!subject_ty.isBuiltin()) {
                    const ty_info = self.module.types.get(subject_ty);
                    if (ty_info == .tagged_union) {
                        for (ty_info.tagged_union.fields, 0..) |f, vi| {
                            const vname = self.module.types.strings.get(f.name);
                            if (std.mem.eql(u8, vname, pat_name)) {
                                if (ty_info.tagged_union.explicit_tag_values) |vals| {
                                    if (vi < vals.len) break :blk @intCast(@as(u64, @bitCast(vals[vi])));
                                }
                                break :blk @intCast(vi);
                            }
                        }
                        if (self.diagnostics) |diags| {
                            const ty_name = self.formatTypeName(subject_ty);
                            diags.addFmt(.err, pat.span, "no variant '{s}' on type '{s}'", .{ pat_name, ty_name });
                        }
                    } else if (ty_info == .@"enum") {
                        for (ty_info.@"enum".variants, 0..) |v, vi| {
                            const vname = self.module.types.strings.get(v);
                            if (std.mem.eql(u8, vname, pat_name)) {
                                if (ty_info.@"enum".explicit_values) |vals| {
                                    if (vi < vals.len) break :blk @intCast(@as(u64, @bitCast(vals[vi])));
                                }
                                break :blk @intCast(vi);
                            }
                        }
                        if (self.diagnostics) |diags| {
                            const ty_name = self.formatTypeName(subject_ty);
                            diags.addFmt(.err, pat.span, "no variant '{s}' on type '{s}'", .{ pat_name, ty_name });
                        }
                    } else if (ty_info == .error_set) {
                        // `case .X` matches the global tag id of `X`.
                        break :blk @intCast(self.module.types.internTag(pat_name));
                    }
                }
                break :blk @intCast(i);
            };
            cases.append(self.alloc, .{
                .value = @intCast(case_val),
                .target = arm_blocks.items[i],
                .args = &.{},
            }) catch unreachable;
        }
    }

    // If no default arm, create an unreachable default
    if (default_bb == null) {
        default_bb = self.freshBlock("match.unr");
    }

    // Switch on the subject. For a type match the subject IS the type-id word
    // (`.type_value` / an integer handle — the subject gate above rejects
    // anything else, incl. `.any`: a boxed Any's unboxed VALUE is not its type
    // tag, so dispatching on it picked the silently-wrong arm; `type_of(a)`
    // is the correct spelling and yields `.type_value` directly).
    const tag = if (is_any_switch)
        // The type switch dispatches on the view's type_id word (field 1,
        // the {data, type_id} layout) — exactly what `type_of(av)` reads —
        // never on the payload.
        self.builder.structGet(subject, 1, .type_value)
    else if (is_type_match) subject else if (is_optional_match) self.builder.emit(.{ .optional_has_value = .{ .operand = subject } }, .bool) else if (is_error_set_match) subject else blk: {
        // Determine actual tag type from union info (e.g. u32 for SDL_Event)
        const tag_ty: TypeId = tt: {
            if (!subject_ty.isBuiltin()) {
                const ty_info = self.module.types.get(subject_ty);
                if (ty_info == .tagged_union) break :tt ty_info.tagged_union.tag_type;
            }
            break :tt .i32;
        };
        break :blk self.builder.enumTag(subject, tag_ty);
    };
    self.builder.switchBr(tag, cases.items, default_bb.?, &.{});

    // Lower each arm's body
    for (me.arms, 0..) |arm, i| {
        self.builder.switchToBlock(arm_blocks.items[i]);

        // For type-match arms with empty tag lists, the arm is unreachable
        // (no switch case targets it). Skip lowering to avoid invalid IR
        // from runtime cast/dispatch with no matching types.
        if (is_type_match and arm.pattern != null and arm_tag_values.items[i].len == 0) {
            self.builder.emitUnreachable();
            continue;
        }

        var arm_scope = Scope.init(self.alloc, self.scope);
        const old_scope = self.scope;
        self.scope = &arm_scope;

        if (arm.capture) |capture_name| {
            if (is_any_switch) {
                // A concrete arm binds the typed value — exactly what
                // `v := av.(T)` produces, with the tag pre-proven by the
                // switch (no panic path). Category arms name a KIND (many
                // types), so there is nothing single-typed to bind; the
                // default arm keeps the subject as `any`.
                if (arm_concrete.items[i]) |cty| {
                    const bound = self.builder.emit(.{ .unbox_any = .{ .operand = subject } }, cty);
                    arm_scope.put(capture_name, .{ .ref = bound, .ty = cty, .is_alloca = false, .origin = .match_payload });
                } else {
                    if (self.diagnostics) |diags| {
                        if (arm.pattern == null) {
                            diags.addFmt(.err, me.subject.span, "an `else:` arm cannot bind — the subject keeps its `any` type there", .{});
                        } else {
                            diags.addFmt(.err, arm.pattern.?.span, "a category arm cannot bind a value — it names a kind, not one type; read the value through the reflection views instead", .{});
                        }
                    }
                    const undef = self.builder.constUndef(.i64);
                    arm_scope.put(capture_name, .{ .ref = undef, .ty = .i64, .is_alloca = false, .origin = .match_payload });
                }
            } else if (is_optional_match) {
                // For optional match, unwrap the optional value
                const opt_info = self.module.types.get(subject_ty);
                const child_ty = if (opt_info == .optional) opt_info.optional.child else .i64;
                const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = subject } }, child_ty);
                arm_scope.put(capture_name, .{ .ref = unwrapped, .ty = child_ty, .is_alloca = false, .origin = .match_payload });
            } else {
                // Resolve actual variant index and payload type from the subject's type
                var variant_idx: u32 = @intCast(i);
                var payload_ty: TypeId = .unresolved;
                const pat_name: []const u8 = if (arm.pattern) |arm_pat| switch (arm_pat.data) {
                    .enum_literal => |el| el.name,
                    .identifier => |id| id.name,
                    else => "",
                } else "";
                if (!subject_ty.isBuiltin()) {
                    const ty_info = self.module.types.get(subject_ty);
                    if (ty_info == .tagged_union) {
                        for (ty_info.tagged_union.fields, 0..) |f, vi| {
                            const vname = self.module.types.strings.get(f.name);
                            if (std.mem.eql(u8, vname, pat_name)) {
                                variant_idx = @intCast(vi);
                                payload_ty = f.ty;
                                break;
                            }
                        }
                    }
                }
                if (payload_ty == .unresolved) {
                    // Non-bindable subject: only a tagged-union (enum with
                    // payloads) variant can supply a case payload binding
                    // `(v)`. Reject everything else — payload-less enum,
                    // unknown tagged-union variant, integer/bool subjects —
                    // with a diagnostic instead of letting the binding's type
                    // leak out as .unresolved and panic at LLVM emission
                    // (issue 0163). Untagged-union subjects (with or without
                    // a binding) never reach the arms: the subject-type gate
                    // above rejects the whole match up front (issue 0222).
                    const bind_span = if (arm.pattern) |arm_pat| arm_pat.span else me.subject.span;
                    const is_tagged_union_subject = !subject_ty.isBuiltin() and self.module.types.get(subject_ty) == .tagged_union;
                    if (self.diagnostics) |diags| {
                        if (is_tagged_union_subject) {
                            // Unknown variant on a tagged union — the case-value
                            // pass already emitted "no variant '<name>' on type
                            // '<T>'"; don't stack a second diagnostic.
                        } else {
                            const ty_name = self.formatTypeName(subject_ty);
                            diags.addFmt(.err, bind_span, "this case pattern cannot bind a payload from subject type '{s}' — only tagged union (enum with payload) variants are bindable", .{ty_name});
                        }
                    }
                    // Bind the capture to an inert undef so the arm body
                    // lowers without cascading "undefined identifier" errors —
                    // compilation aborts on the diagnostic(s) above before any
                    // code is emitted.
                    const undef = self.builder.constUndef(.i64);
                    arm_scope.put(capture_name, .{ .ref = undef, .ty = .i64, .is_alloca = false, .origin = .match_payload });
                } else {
                    const payload = self.builder.emit(.{ .enum_payload = .{
                        .base = subject,
                        .field_index = variant_idx,
                    } }, payload_ty);
                    arm_scope.put(capture_name, .{ .ref = payload, .ty = payload_ty, .is_alloca = false, .origin = .match_payload });
                }
            }
        }

        // Set match arm context for runtime type dispatch
        const saved_match_tags = self.current_match_tags;
        if (is_type_match) {
            self.current_match_tags = arm_tag_values.items[i];
        }

        if (has_value_merge) {
            // Lower the arm body against the merge's result type so literals
            // (and negated literals) in the arm pick the right width — the
            // phi operands must all match `result_type`.
            const saved_arm_target = self.target_type;
            self.target_type = result_type;
            const maybe_v = self.lowerBlockValue(arm.body);
            self.target_type = saved_arm_target;
            self.current_match_tags = saved_match_tags;
            self.scope = old_scope;
            arm_scope.deinit();
            // Only materialize a value + branch to the merge when the arm
            // body did NOT diverge. A diverging arm (e.g. `return x`) has
            // already terminated its block; emitting the fallback const
            // here would land AFTER the terminator .
            if (!self.currentBlockHasTerminator()) {
                var v = maybe_v orelse if (result_type == .string or !result_type.isBuiltin())
                    self.builder.constUndef(result_type)
                else
                    self.builder.constInt(0, result_type);
                const v_ty = self.builder.getRefType(v);
                v = self.coerceToType(v, v_ty, result_type);
                // Backstop for inference-blind arms (issue 0236): when the
                // coercion ladder had nothing (`.none` passthrough) and the
                // arm value can't occupy the merge phi's slot, feeding it
                // through builds a mixed-type phi — an LLVM verifier failure
                // with NO diagnostic. The unification pass in
                // `inferMatchResultType` diagnoses every statically-visible
                // mismatch; this catches an arm it couldn't type (`.unresolved`
                // at inference, concrete after lowering). Diagnose (unless an
                // error already fired — the unification's own, or a cascade
                // source) and substitute an inert undef so the IR stays
                // well-formed while compilation aborts on the diagnostic.
                const coerced_ty = self.builder.getRefType(v);
                if (coerced_ty != result_type and self.noneReinterpretIsUnsafe(coerced_ty, result_type)) {
                    if (self.diagnostics) |diags| {
                        if (diags.errorCount() == 0) {
                            diags.addFmt(.err, arm.body.span, "match arms have incompatible types: '{s}' vs '{s}'", .{
                                self.formatTypeName(result_type),
                                self.formatTypeName(coerced_ty),
                            });
                        }
                    }
                    v = self.builder.constUndef(result_type);
                }
                self.builder.br(merge_bb, &.{v});
            }
        } else {
            self.lowerBlock(arm.body);
            self.current_match_tags = saved_match_tags;
            self.scope = old_scope;
            arm_scope.deinit();
            if (!self.currentBlockHasTerminator()) {
                self.builder.br(merge_bb, &.{});
            }
        }
    }

    // Emit default block if no explicit else arm
    if (default_bb != null) {
        var found_default = false;
        for (me.arms) |arm| {
            if (arm.pattern == null) {
                found_default = true;
                break;
            }
        }
        if (!found_default) {
            self.builder.switchToBlock(default_bb.?);
            if (is_type_match) {
                // For type-category matches, unrecognized tags should skip to merge
                // (e.g., optional types not covered by any_to_string categories)
                if (has_value_merge) {
                    const default_val = self.builder.constUndef(result_type);
                    self.builder.br(merge_bb, &.{default_val});
                } else {
                    self.builder.br(merge_bb, &.{});
                }
            } else {
                // For non-exhaustive matches (union/enum with unhandled variants),
                // fall through to merge instead of unreachable
                const is_exhaustive = blk: {
                    if (!subject_ty.isBuiltin()) {
                        const ty_info = self.module.types.get(subject_ty);
                        if (ty_info == .tagged_union) {
                            break :blk cases.items.len >= ty_info.tagged_union.fields.len;
                        } else if (ty_info == .@"enum") {
                            break :blk cases.items.len >= ty_info.@"enum".variants.len;
                        }
                    }
                    break :blk false;
                };
                if (is_exhaustive) {
                    self.builder.emitUnreachable();
                } else if (has_value_merge) {
                    const default_val = self.builder.constUndef(result_type);
                    self.builder.br(merge_bb, &.{default_val});
                } else {
                    self.builder.br(merge_bb, &.{});
                }
            }
        }
    }

    self.builder.switchToBlock(merge_bb);
    if (has_value_merge) {
        return self.builder.blockParam(merge_bb, 0, result_type);
    }
    return self.builder.constInt(0, .void);
}

pub fn lowerBreak(self: *Lowering, span: ast.Span) Ref {
    if (self.break_target) |target| {
        // Leaving the loop body's scope: run the defers registered since the
        // loop began (LIFO) before the jump — same as the fall-through exit.
        self.emitLoopExitDefers();
        self.builder.br(target, &.{});
    } else if (self.diagnostics) |d| {
        d.addFmt(.err, span, "`break` outside a loop", .{});
    }
    return Ref.none;
}

pub fn lowerContinue(self: *Lowering, span: ast.Span) Ref {
    if (self.continue_target) |target| {
        self.emitLoopExitDefers();
        self.builder.br(target, &.{});
    } else if (self.diagnostics) |d| {
        d.addFmt(.err, span, "`continue` outside a loop", .{});
    }
    return Ref.none;
}

// ── Block plumbing ──────────────────────────────────────────────

pub fn freshBlock(self: *Lowering, prefix: []const u8) BlockId {
    return self.freshBlockWithParams(prefix, &.{});
}

pub fn freshBlockWithParams(self: *Lowering, prefix: []const u8, params: []const TypeId) BlockId {
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}.{d}", .{ prefix, self.block_counter }) catch prefix;
    self.block_counter += 1;
    const name_id = self.module.types.internString(name);
    return self.builder.appendBlock(name_id, params);
}

pub fn currentBlockHasTerminator(self: *Lowering) bool {
    const func = self.builder.module.getFunctionMut(self.builder.func.?);
    const block_idx = self.builder.current_block orelse return true;
    const block = &func.blocks.items[block_idx.index()];
    if (block.insts.items.len > 0) {
        const last_op = block.insts.items[block.insts.items.len - 1].op;
        return switch (last_op) {
            .ret, .ret_void, .br, .cond_br, .switch_br, .@"unreachable" => true,
            else => false,
        };
    }
    return false;
}

pub fn ensureTerminator(self: *Lowering, ret_ty: TypeId) void {
    if (self.currentBlockHasTerminator()) return;
    if (ret_ty == .noreturn) {
        // A `-> noreturn` function never returns; if control reaches the
        // end of the body it's genuinely unreachable (the body is expected
        // to diverge — call another noreturn, loop forever, etc.).
        self.builder.emitUnreachable();
    } else if (ret_ty == .void) {
        self.builder.retVoid();
    } else if (!ret_ty.isBuiltin() and self.module.types.get(ret_ty) == .error_set) {
        // A pure-failable function (`-> !` / `-> !Named`, whose return type IS
        // the error set) that falls off the end with no explicit `return;` is
        // a SUCCESS exit — the error slot must carry 0 ("no error"), exactly
        // like the bare-`return;` path in lowerReturn. Without this the slot is
        // left undefined and the caller (or main) reads a garbage tag and
        // reports a phantom unhandled error (issue 0190).
        self.builder.ret(self.builder.constInt(0, ret_ty), ret_ty);
    } else {
        // Use const_undef for complex types (string, struct, etc.)
        const default_val = if (ret_ty == .string or !ret_ty.isBuiltin())
            self.builder.constUndef(ret_ty)
        else
            self.builder.constInt(0, ret_ty);
        self.builder.ret(default_val, ret_ty);
    }
}
