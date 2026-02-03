const std = @import("std");
const ast = @import("../ast.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const Lowering = lower.Lowering;

// ── ERR E1.7 / E1.8 — error-flow analysis ───────────────────────────────────
//
// One structured, path-sensitive walk over each MAIN-file function body
// (imported modules are trusted) drives two checks:
//
//  • E1.8 (value-slot liveness): a `v, err := failable()` destructure binds
//    `v` "live only where `err` is proven absent". A read of `v` is legal
//    iff `err` is proven null on the current path — established by
//    `if !err { … }` (proven inside) or `if err { return/raise }` (proven on
//    the fall-through). Error-set `==`/tag-compares do NOT prove absence.
//
//  • E1.7 (cleanup absorption): a bare failable call in a `defer`/`onfail`
//    body (with no `catch` / `or value`) is rejected — its error has nowhere
//    to propagate (the block is already exiting). See `checkCleanupBody`.
//
// This is the diagnostic-only Pass 1e (architecture phase A5.2), extracted from
// `Lowering`. A `*Lowering` facade (Principle 5, like `ErrorAnalysis`/
// `CoercionResolver`): it reads AST decls + `ProgramIndex` and emits diagnostics
// via `self.l.diagnostics`; lowering proceeds only if the diagnostics are clean
// (`core.zig` halts before codegen on any error). External `Lowering` helpers it
// consumes: `inferExprType`, `errorChannelOf`, `exprIsFailable`.

/// The proven-null set: error-variable names known to be absent on the
/// current path. Threaded by value-clone across branches; the join after an
/// `if` is the intersection of the reachable branches' sets.
const ProvenSet = std.ArrayList([]const u8);

fn provenHas(set: ProvenSet, name: []const u8) bool {
    for (set.items) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn provenRemove(set: *ProvenSet, name: []const u8) void {
    var i: usize = 0;
    while (i < set.items.len) {
        if (std.mem.eql(u8, set.items[i], name)) {
            _ = set.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

/// Per-function registration state for the flow walk. `bindings` maps each
/// failable value-slot variable to its partner error variable; `err_vars`
/// is the set of those error variables (so conditions over them refine the
/// proven-null set). Both are keyed by NAME, so they are scoped via
/// `shadow_undo`: every declaration statement records the prior state of
/// its name (see `declareName`) and `scopeExit` restores it when the
/// enclosing lexical scope ends — a record never outlives its variable
/// (issue 0210: a stale record used to poison a later same-name `:=` in a
/// sibling scope).
const FlowCtx = struct {
    bindings: std.StringHashMap([]const u8),
    err_vars: std.StringHashMap(void),
    shadow_undo: std.ArrayList(ShadowSave),
};

/// Saved prior state of one declared name, pushed by `declareName` and
/// popped/restored by `scopeExit` when the declaring scope ends.
const ShadowSave = struct {
    name: []const u8,
    prev_binding: ?[]const u8,
    was_err_var: bool,
    was_proven: bool,
};

pub const ErrorFlow = struct {
    l: *Lowering,

    fn provenAdd(self: ErrorFlow, set: *ProvenSet, name: []const u8) void {
        if (!provenHas(set.*, name)) set.append(self.l.alloc, name) catch {};
    }

    fn provenClone(self: ErrorFlow, set: ProvenSet) ProvenSet {
        var out = ProvenSet.empty;
        out.appendSlice(self.l.alloc, set.items) catch {};
        return out;
    }

    fn provenIntersect(self: ErrorFlow, a: ProvenSet, b: ProvenSet) ProvenSet {
        var out = ProvenSet.empty;
        for (a.items) |n| if (provenHas(b, n)) (out.append(self.l.alloc, n) catch {});
        return out;
    }

    /// A `:=` declaration introduces a NEW variable: it must not inherit a
    /// stale failable-guard record (value taint, err-var role, or
    /// proven-absent fact) left by a same-named variable from an earlier or
    /// enclosing scope (issue 0210). Save the prior records on the
    /// shadow-undo stack — so `scopeExit` can restore an outer variable's
    /// state when this scope ends — then clear all three.
    fn declareName(self: ErrorFlow, ctx: *FlowCtx, proven: *ProvenSet, name: []const u8) void {
        if (std.mem.eql(u8, name, "_")) return;
        ctx.shadow_undo.append(self.l.alloc, .{
            .name = name,
            .prev_binding = ctx.bindings.get(name),
            .was_err_var = ctx.err_vars.contains(name),
            .was_proven = provenHas(proven.*, name),
        }) catch {};
        _ = ctx.bindings.remove(name);
        _ = ctx.err_vars.remove(name);
        provenRemove(proven, name);
    }

    /// Unwind the shadow-undo stack to `mark`, restoring each declared
    /// name's pre-scope records. This both revives an outer shadowed
    /// variable's taint/proof and removes records registered by the scope's
    /// own declarations (an out-of-scope variable must not keep a live
    /// record — any later read of the name is a fresh declaration's).
    fn scopeExit(self: ErrorFlow, ctx: *FlowCtx, proven: *ProvenSet, mark: usize) void {
        while (ctx.shadow_undo.items.len > mark) {
            const save = ctx.shadow_undo.pop().?;
            if (save.prev_binding) |pb| {
                ctx.bindings.put(save.name, pb) catch {};
            } else {
                _ = ctx.bindings.remove(save.name);
            }
            if (save.was_err_var) {
                ctx.err_vars.put(save.name, {}) catch {};
            } else {
                _ = ctx.err_vars.remove(save.name);
            }
            if (save.was_proven) {
                self.provenAdd(proven, save.name);
            } else {
                provenRemove(proven, save.name);
            }
        }
    }

    /// Pass 1e: run the error-flow checks over every function defined in the
    /// main file. Library modules are assumed well-formed (and may use patterns
    /// this conservative check would over-reject), so they are skipped.
    pub fn checkErrorFlow(self: ErrorFlow, decls: []const *const Node) void {
        if (self.l.diagnostics == null) return;
        const saved_file = self.l.current_source_file;
        defer self.l.setCurrentSourceFile(saved_file);
        for (decls) |decl| {
            if (self.l.main_file) |mf| {
                if (decl.source_file) |sf| {
                    if (!std.mem.eql(u8, sf, mf)) continue;
                }
            }
            // Pin the visibility context (and diagnostic rendering) to the
            // decl's own module — the flow walk resolves types via
            // inferExprType, and the ambient file the previous phase left
            // behind is arbitrary (issue 0122).
            if (decl.source_file) |sf| self.l.setCurrentSourceFile(sf);
            switch (decl.data) {
                .fn_decl => |fd| self.analyzeFnBody(fd.body),
                .const_decl => |cd| {
                    if (cd.value.data == .fn_decl) self.analyzeFnBody(cd.value.data.fn_decl.body);
                },
                else => {},
            }
        }
    }

    /// Analyze one function (or lambda) body as its own boundary — a fresh
    /// binding context and an empty proven set.
    fn analyzeFnBody(self: ErrorFlow, body: *const Node) void {
        var ctx = FlowCtx{
            .bindings = std.StringHashMap([]const u8).init(self.l.alloc),
            .err_vars = std.StringHashMap(void).init(self.l.alloc),
            .shadow_undo = .empty,
        };
        var proven = ProvenSet.empty;
        _ = self.flowWalk(body, &ctx, &proven);
    }

    /// Walk a block or single statement. Returns whether control always
    /// diverges (every path ends in return/raise/break/continue) — used by the
    /// caller to mark code after a branch unreachable. The walked node is a
    /// lexical scope: declarations inside it are unwound on the way out.
    fn flowWalk(self: ErrorFlow, node: *const Node, ctx: *FlowCtx, proven: *ProvenSet) bool {
        const mark = ctx.shadow_undo.items.len;
        defer self.scopeExit(ctx, proven, mark);
        switch (node.data) {
            .block => |b| {
                for (b.stmts) |s| if (self.flowStmt(s, ctx, proven)) return true;
                return false;
            },
            else => return self.flowStmt(node, ctx, proven),
        }
    }

    fn flowStmt(self: ErrorFlow, node: *const Node, ctx: *FlowCtx, proven: *ProvenSet) bool {
        switch (node.data) {
            .destructure_decl => |dd| {
                self.flowExpr(dd.value, ctx, proven.*);
                for (dd.names) |n| self.declareName(ctx, proven, n);
                self.registerFailableDestructure(&dd, ctx);
                return false;
            },
            .var_decl => |vd| {
                if (vd.value) |v| self.flowExpr(v, ctx, proven.*);
                self.declareName(ctx, proven, vd.name);
                return false;
            },
            .const_decl => |cd| {
                self.flowExpr(cd.value, ctx, proven.*);
                self.declareName(ctx, proven, cd.name);
                return false;
            },
            .assignment => |a| {
                self.flowExpr(a.value, ctx, proven.*);
                self.flowExpr(a.target, ctx, proven.*);
                return false;
            },
            .multi_assign => |ma| {
                for (ma.values) |v| self.flowExpr(v, ctx, proven.*);
                return false;
            },
            .return_stmt => |r| {
                if (r.value) |v| self.flowExpr(v, ctx, proven.*);
                return true;
            },
            .raise_stmt => |rs| {
                self.flowExpr(rs.tag, ctx, proven.*);
                return true;
            },
            .break_expr, .continue_expr => return true,
            .if_expr => |ie| return self.flowIf(&ie, ctx, proven),
            .while_expr => |we| {
                self.flowExpr(we.condition, ctx, proven.*);
                var loop_proven = self.provenClone(proven.*);
                // `while name := expr { … }` — the optional binding is a
                // fresh declaration scoped to the loop body.
                const mark = ctx.shadow_undo.items.len;
                if (we.binding_name) |bn| self.declareName(ctx, &loop_proven, bn);
                _ = self.flowWalk(we.body, ctx, &loop_proven);
                self.scopeExit(ctx, &loop_proven, mark);
                return false;
            },
            .for_expr => |fe| {
                for (fe.iterables) |it| {
                    self.flowExpr(it.expr, ctx, proven.*);
                    if (it.range_end) |re| self.flowExpr(re, ctx, proven.*);
                }
                var loop_proven = self.provenClone(proven.*);
                // Loop captures are fresh declarations scoped to the body.
                const mark = ctx.shadow_undo.items.len;
                for (fe.captures) |cap| self.declareName(ctx, &loop_proven, cap.name);
                _ = self.flowWalk(fe.body, ctx, &loop_proven);
                self.scopeExit(ctx, &loop_proven, mark);
                return false;
            },
            .match_expr => |me| return self.flowMatch(&me, ctx, proven),
            .push_stmt => |ps| {
                self.flowExpr(ps.context_expr, ctx, proven.*);
                var inner = self.provenClone(proven.*);
                _ = self.flowWalk(ps.body, ctx, &inner);
                return false;
            },
            .defer_stmt => |ds| {
                self.checkCleanupBody(ds.expr, "defer");
                self.flowExpr(ds.expr, ctx, proven.*);
                return false;
            },
            .onfail_stmt => |os| {
                self.checkCleanupBody(os.body, "onfail");
                // `onfail (name) { … }` — the error binding is a fresh
                // declaration scoped to the cleanup body.
                var body_proven = self.provenClone(proven.*);
                const mark = ctx.shadow_undo.items.len;
                if (os.binding) |bn| self.declareName(ctx, &body_proven, bn);
                self.flowExpr(os.body, ctx, body_proven);
                self.scopeExit(ctx, &body_proven, mark);
                return false;
            },
            else => {
                self.flowExpr(node, ctx, proven.*);
                return false;
            },
        }
    }

    /// Path-sensitive `if`: refine the proven set on each branch, recurse, and
    /// join the reachable fall-through states by intersection.
    fn flowIf(self: ErrorFlow, ie: *const ast.IfExpr, ctx: *FlowCtx, proven: *ProvenSet) bool {
        self.flowExpr(ie.condition, ctx, proven.*);
        var then_proven = self.provenClone(proven.*);
        var else_proven = self.provenClone(proven.*);
        self.applyRefinement(ie.condition, true, ctx, &then_proven);
        self.applyRefinement(ie.condition, false, ctx, &else_proven);

        // `if name := expr { … }` — the optional binding is a fresh
        // declaration scoped to the then-branch only.
        const then_mark = ctx.shadow_undo.items.len;
        if (ie.binding_name) |bn| self.declareName(ctx, &then_proven, bn);
        const then_div = self.flowWalk(ie.then_branch, ctx, &then_proven);
        self.scopeExit(ctx, &then_proven, then_mark);
        var else_div = false;
        if (ie.else_branch) |eb| else_div = self.flowWalk(eb, ctx, &else_proven);

        // Reachable fall-through contributors: a branch that doesn't diverge,
        // plus the implicit (empty) else when there is no `else`.
        var contributors = std.ArrayList(ProvenSet).empty;
        if (!then_div) contributors.append(self.l.alloc, then_proven) catch {};
        if (ie.else_branch != null) {
            if (!else_div) contributors.append(self.l.alloc, else_proven) catch {};
        } else {
            contributors.append(self.l.alloc, else_proven) catch {};
        }
        if (contributors.items.len == 0) return true; // both branches diverge

        var result = self.provenClone(contributors.items[0]);
        for (contributors.items[1..]) |c| result = self.provenIntersect(result, c);
        proven.* = result;
        return false;
    }

    /// Refine the proven-null set for a branch taken when `cond` is `want_true`.
    /// A bare error-variable is truthy when it HOLDS an error, so its falsy edge
    /// proves absence; `!`, `&&`, `||` compose. Tag/equality compares prove
    /// nothing (error-set `==` compares tags, not presence).
    fn applyRefinement(self: ErrorFlow, cond: *const Node, want_true: bool, ctx: *FlowCtx, set: *ProvenSet) void {
        switch (cond.data) {
            .identifier => |id| {
                if (ctx.err_vars.contains(id.name) and !want_true) self.provenAdd(set, id.name);
            },
            .unary_op => |uop| {
                if (uop.op == .not) self.applyRefinement(uop.operand, !want_true, ctx, set);
            },
            .binary_op => |bop| {
                if (bop.op == .and_op and want_true) {
                    self.applyRefinement(bop.lhs, true, ctx, set);
                    self.applyRefinement(bop.rhs, true, ctx, set);
                } else if (bop.op == .or_op and !want_true) {
                    self.applyRefinement(bop.lhs, false, ctx, set);
                    self.applyRefinement(bop.rhs, false, ctx, set);
                }
            },
            else => {},
        }
    }

    fn flowMatch(self: ErrorFlow, me: *const ast.MatchExpr, ctx: *FlowCtx, proven: *ProvenSet) bool {
        self.flowExpr(me.subject, ctx, proven.*);
        for (me.arms) |arm| {
            var arm_proven = self.provenClone(proven.*);
            // An arm's payload capture is a fresh declaration scoped to it.
            const mark = ctx.shadow_undo.items.len;
            if (arm.capture) |cap| self.declareName(ctx, &arm_proven, cap);
            _ = self.flowWalk(arm.body, ctx, &arm_proven);
            self.scopeExit(ctx, &arm_proven, mark);
        }
        return false;
    }

    /// Check an expression for reads of a still-tainted value-slot variable and
    /// recurse into nested lambdas as their own boundaries. `proven` is by value
    /// — sub-expressions never publish proven-null facts back to the statement.
    fn flowExpr(self: ErrorFlow, node: *const Node, ctx: *FlowCtx, proven: ProvenSet) void {
        switch (node.data) {
            .identifier => |id| {
                if (ctx.bindings.get(id.name)) |err_var| {
                    if (!provenHas(proven, err_var)) {
                        if (self.l.diagnostics) |d| d.addFmt(.err, node.span, "value `{s}` from a failable can be used only where its error `{s}` is proven absent — guard the use with `if !{s} {{ … }}`, or return early with `if {s} {{ return; }}` before reading `{s}`", .{ id.name, err_var, err_var, err_var, id.name });
                    }
                }
            },
            .lambda => |lam| self.analyzeFnBody(lam.body),
            .binary_op => |b| {
                self.flowExpr(b.lhs, ctx, proven);
                // Short-circuit: the rhs of `&&` runs only when the lhs is true
                // (and `||`'s rhs only when the lhs is false), so refine the
                // proven-null set accordingly before checking it. This is what
                // makes `if !err && use(v)` legal.
                if (b.op == .and_op or b.op == .or_op) {
                    var rp = self.provenClone(proven);
                    self.applyRefinement(b.lhs, b.op == .and_op, ctx, &rp);
                    self.flowExpr(b.rhs, ctx, rp);
                } else {
                    self.flowExpr(b.rhs, ctx, proven);
                }
            },
            .chained_comparison => |cc| {
                for (cc.operands) |op| self.flowExpr(op, ctx, proven);
            },
            .unary_op => |u| self.flowExpr(u.operand, ctx, proven),
            .call => |c| {
                self.flowExpr(c.callee, ctx, proven);
                for (c.args) |a| self.flowExpr(a, ctx, proven);
            },
            .field_access => |fa| self.flowExpr(fa.object, ctx, proven),
            .index_expr => |ix| {
                self.flowExpr(ix.object, ctx, proven);
                self.flowExpr(ix.index, ctx, proven);
            },
            .slice_expr => |se| {
                self.flowExpr(se.object, ctx, proven);
                if (se.start) |s| self.flowExpr(s, ctx, proven);
                if (se.end) |e| self.flowExpr(e, ctx, proven);
            },
            .try_expr => |te| self.flowExpr(te.operand, ctx, proven),
            .catch_expr => |ce| {
                self.flowExpr(ce.operand, ctx, proven);
                if (ce.binding) |bn| {
                    // `x catch (name) { … }` — the error binding is a fresh
                    // declaration scoped to the handler body.
                    var body_proven = self.provenClone(proven);
                    const mark = ctx.shadow_undo.items.len;
                    self.declareName(ctx, &body_proven, bn);
                    self.flowExpr(ce.body, ctx, body_proven);
                    self.scopeExit(ctx, &body_proven, mark);
                } else {
                    self.flowExpr(ce.body, ctx, proven);
                }
            },
            .force_unwrap => |fu| self.flowExpr(fu.operand, ctx, proven),
            .null_coalesce => |nc| {
                self.flowExpr(nc.lhs, ctx, proven);
                self.flowExpr(nc.rhs, ctx, proven);
            },
            .deref_expr => |de| self.flowExpr(de.operand, ctx, proven),
            .postfix_cast => |pc| self.flowExpr(pc.operand, ctx, proven),
            .comptime_expr => |ce| self.flowExpr(ce.expr, ctx, proven),
            .insert_expr => |ie| self.flowExpr(ie.expr, ctx, proven),
            .spread_expr => |se| self.flowExpr(se.operand, ctx, proven),
            .struct_literal => |sl| {
                for (sl.field_inits) |fi| self.flowExpr(fi.value, ctx, proven);
            },
            .array_literal => |al| {
                for (al.elements) |el| self.flowExpr(el, ctx, proven);
            },
            .tuple_literal => |tl| {
                for (tl.elements) |el| self.flowExpr(el.value, ctx, proven);
            },
            .if_expr => |ie| {
                var tmp = self.provenClone(proven);
                _ = self.flowIf(&ie, ctx, &tmp);
            },
            .match_expr => |me| {
                var tmp = self.provenClone(proven);
                _ = self.flowMatch(&me, ctx, &tmp);
            },
            .block => |b| {
                var tmp = self.provenClone(proven);
                const mark = ctx.shadow_undo.items.len;
                for (b.stmts) |s| if (self.flowStmt(s, ctx, &tmp)) break;
                self.scopeExit(ctx, &tmp, mark);
            },
            else => {},
        }
    }

    /// Register a `v…, err := failable()` destructure. Only a complete bare
    /// destructure (every slot bound, error slot a real name) creates taint —
    /// an omitted or `_`-bound error slot is already rejected by the discard
    /// check in `lowerDestructureDecl`, so it produces no proof obligation here.
    fn registerFailableDestructure(self: ErrorFlow, dd: *const ast.DestructureDecl, ctx: *FlowCtx) void {
        const ty = self.l.inferExprType(dd.value);
        if (self.l.errorChannelOf(ty) == null) return;
        if (ty.isBuiltin()) return;
        const ti = self.l.module.types.get(ty);
        if (ti != .tuple) return;
        const fields = ti.tuple.fields;
        if (dd.names.len != fields.len) return;
        const err_name = dd.names[fields.len - 1];
        if (std.mem.eql(u8, err_name, "_")) return;
        ctx.err_vars.put(err_name, {}) catch {};
        var i: usize = 0;
        while (i + 1 < dd.names.len) : (i += 1) {
            const vn = dd.names[i];
            if (std.mem.eql(u8, vn, "_")) continue;
            ctx.bindings.put(vn, err_name) catch {};
        }
    }

    /// E1.7: a `defer`/`onfail` body runs while the block is already exiting, so
    /// a bare failable call has nowhere to send its error. Reject any failable
    /// expression-statement that isn't absorbed locally by `catch` / `or value`
    /// / a destructure binding. (Parser already bans `try`/`raise`/`return`/
    /// `break`/`continue` here, so the only escape route left for a failable is
    /// local absorption.) The check is transitive through nested blocks, `if`,
    /// loops, match arms, and `catch` handlers, but stops at a nested closure
    /// (its own function boundary).
    fn checkCleanupBody(self: ErrorFlow, body: *const Node, kind: []const u8) void {
        self.checkCleanupNode(body, kind);
    }

    fn checkCleanupNode(self: ErrorFlow, node: *const Node, kind: []const u8) void {
        switch (node.data) {
            .block => |b| for (b.stmts) |s| self.checkCleanupNode(s, kind),
            .if_expr => |ie| {
                self.cleanupReject(ie.condition, kind);
                self.checkCleanupNode(ie.then_branch, kind);
                if (ie.else_branch) |eb| self.checkCleanupNode(eb, kind);
            },
            .while_expr => |we| {
                self.cleanupReject(we.condition, kind);
                self.checkCleanupNode(we.body, kind);
            },
            .for_expr => |fe| self.checkCleanupNode(fe.body, kind),
            .match_expr => |me| for (me.arms) |arm| self.checkCleanupNode(arm.body, kind),
            .push_stmt => |ps| self.checkCleanupNode(ps.body, kind),
            // A destructure binds the error slot → absorbed (explicit ownership).
            .destructure_decl => {},
            .var_decl => |vd| if (vd.value) |v| self.cleanupReject(v, kind),
            .const_decl => |cd| self.cleanupReject(cd.value, kind),
            .assignment => |a| self.cleanupReject(a.value, kind),
            // Closures are their own boundary; the parser-banned control-flow
            // exits are handled elsewhere; nested cleanup is independent.
            .lambda, .return_stmt, .raise_stmt, .break_expr, .continue_expr, .defer_stmt, .onfail_stmt => {},
            else => self.cleanupReject(node, kind),
        }
    }

    /// Reject `expr` if it is a bare (un-absorbed) failable in cleanup position.
    /// `catch` / `or value` strip the error channel (so `exprIsFailable` is
    /// false for them); only a still-failable expression has an unhandled error.
    fn cleanupReject(self: ErrorFlow, expr: *const Node, kind: []const u8) void {
        if (expr.data == .catch_expr) {
            // The operand is absorbed; the handler body still runs in cleanup.
            self.checkCleanupNode(expr.data.catch_expr.body, kind);
            return;
        }
        if (!self.l.exprIsFailable(expr)) return;
        if (self.l.diagnostics) |d| d.addFmt(.err, expr.span, "a bare failable call in a `{s}` body has nowhere to send its error — the block is already exiting; absorb it locally with `catch` or `or <value>`", .{kind});
    }
};
