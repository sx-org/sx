const std = @import("std");
const ast = @import("../../ast.zig");
const contracts = @import("../../contracts.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const source_site = @import("../../source_site.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const lower_closure = @import("closure.zig");

/// The `@` contract name. It is a BOUND head only: `value: $I/@Init(T)`.
pub const type_name = contracts.init_bound;

/// The destination parameter of a formed recipe. It names a synthesized lambda
/// parameter the user never writes, so it only has to be unspellable.
const dest_param = "__init_dest";

/// The operations an `@Init(T)` implementor exposes.
pub const write_method = "write";
pub const site_method = "site";

/// One formation site: the source identity a per-site implementor bakes into
/// `site()`. `indexed` is null when the walk never reached the expression
/// (a synthesized node), which is the `?@SourceSite` null the contract allows.
pub const Site = struct {
    indexed: ?source_site.Site,
    line: i32,
    column: i32,
};

/// The `T` of an `@Init(T)`, else null. Delegates to the type table's single
/// classifier so the frontend and the type model cannot disagree.
pub fn initTargetOf(self: *Lowering, ty: TypeId) ?TypeId {
    return self.module.types.initTarget(ty);
}

/// The `@Init(X)` bound written on a binder parameter, as the `X` node — the
/// init's type argument, which may itself be a binder (`$T`, `$V/View`). Null
/// for any parameter that is not `name: $I/@Init(X)`.
///
/// This is THE formation trigger: a parameter accepts an initializer by
/// carrying this bound, never by annotating a type (§5.2, §19.3).
pub fn boundTargetNode(param_type: *const Node) ?*const Node {
    if (param_type.data != .type_expr) return null;
    const te = param_type.data.type_expr;
    if (!te.is_generic) return null;
    for (te.protocol_constraints) |bound| {
        if (bound.data != .parameterized_type_expr) continue;
        const pte = bound.data.parameterized_type_expr;
        if (!std.mem.eql(u8, pte.name, type_name)) continue;
        if (pte.args.len != 1) continue;
        return pte.args[0];
    }
    return null;
}

/// The formation request a `$I/@Init(X)` parameter resolves to while `$I` is
/// still unbound: `@Init(T)` with the target resolved against the active
/// bindings, or null when `X` is not yet known. Argument lowering keys on it.
pub fn formationRequest(self: *Lowering, p: *const ast.Param) ?TypeId {
    const target_node = boundTargetNode(p.type_expr) orelse return null;
    const target = self.resolveTypeWithBindings(target_node);
    if (target == .unresolved) return null;
    return self.module.types.initPlanType(target);
}

/// Does `arg_ty` already CONFORM to the bound — is it an `@Init` implementor
/// this parameter accepts as it stands (§5.2 forwarding)? `target` is the
/// request's type argument; an open one accepts any implementor and takes its
/// target as the binding.
pub fn conforms(self: *Lowering, target: ?TypeId, arg_ty: TypeId) bool {
    const arg_target = self.module.types.initTarget(arg_ty) orelse return false;
    // Site 0 is the request itself, never a value's type.
    if ((self.module.types.initSiteOf(arg_ty) orelse 0) == 0) return false;
    const want = target orelse return true;
    return arg_target == want;
}

/// What an `@Init`-bounded binder binds to at this argument: the implementor the
/// argument passes through as, or the one formation mints for it. Null when
/// `param_type` is not `tp_name` carrying an `@Init` bound.
///
/// Binder inference and formation compute this from the same inputs — the
/// bound's target and the argument's site — so the parameter's type and the
/// argument's type are the same TypeId however the two are ordered.
pub fn binderType(
    self: *Lowering,
    param_type: *const Node,
    tp_name: []const u8,
    arg: *const Node,
    arg_ty: TypeId,
) ?TypeId {
    if (param_type.data != .type_expr) return null;
    if (!std.mem.eql(u8, param_type.data.type_expr.name, tp_name)) return null;
    const target_node = boundTargetNode(param_type) orelse return null;
    if (conforms(self, null, arg_ty)) return arg_ty;
    const fixed = self.resolveTypeWithBindings(target_node);
    // An open type argument (`$T`, `$V/View`) takes the argument's own type;
    // a fixed one is the target whatever the argument's type is (§5.2).
    const target = if (fixed == .unresolved) arg_ty else fixed;
    if (target == .unresolved) return null;
    return self.module.types.initImplementorType(target, siteFor(self, arg));
}

/// The formation site for `arg`, minted once per source expression: two
/// monomorphizations of one enclosing generic function report the same site
/// (§4.2 — a specialization reads the template's path).
fn siteFor(self: *Lowering, arg: *const Node) u32 {
    if (self.init_site_ids.get(arg)) |id| return id;
    const src = arg.source_file orelse self.current_source_file;
    const loc = if (self.diagnostics) |d| d.locate(src, arg.span.start) else null;
    const indexed = if (self.site_index) |idx| idx.get(arg) else null;
    self.init_sites.append(self.alloc, .{
        .indexed = indexed,
        .line = if (loc) |l| @intCast(l.line) else 0,
        .column = if (loc) |l| @intCast(l.col) else 0,
    }) catch unreachable;
    // Site ids are one-based: 0 is the formation request.
    const id: u32 = @intCast(self.init_sites.items.len);
    self.init_site_ids.put(self.alloc, arg, id) catch unreachable;
    return id;
}

/// A protocol value is a handle to its conformer, not the conformer's value.
/// Forming an `@Init(target)` from one has no concrete `target` to write, so the
/// expression is refused with the downcast that reads the conformer out. True
/// when refused.
///
/// A modeled conversion already says what the bytes become (`any` takes the
/// concrete view, an optional target answers in its own terms), and keeps that
/// answer.
fn refuseProtocolSource(self: *Lowering, arg: *const Node, arg_ty: TypeId, target: TypeId) bool {
    if (arg_ty == target or arg_ty == .unresolved or target == .unresolved) return false;
    if (self.isOpenSet(target)) return false;
    if (self.coercionResolver().classify(arg_ty, target) != .none) return false;
    if (self.protocolKindOf(arg_ty) == null) return false;
    const d = self.diagnostics orelse return true;
    const src_name = self.formatSourceTypeName(arg_ty);
    const dst_name = self.formatSourceTypeName(target);
    const id = d.addFmtId(.err, arg.span, "'{s}' cannot form an initializer for '{s}': a protocol value is a handle to its conformer, not the conformer", .{ src_name, dst_name });
    d.addHelpFmt(id, arg.span, null, "read the conformer out with a downcast first: '.({s})' panics on another type, '.(?{s})' answers null", .{ dst_name, dst_name });
    return true;
}

/// Form the `@Init(target)` implementor for `arg` (spec §5.2). The argument is
/// NOT evaluated here: it becomes the body of a thunk
/// `(dest: *target) { dest.* = <arg>; }`, so it runs when — and each time — the
/// receiver calls `write`.
///
/// CONFORM-OR-FORM: an argument that is already an implementor of the same
/// target passes through by identity (the forwarding path — one write, handed
/// over, provenance preserved). Anything else forms a fresh per-site
/// implementor.
///
/// The closure lowerer does the work: capture collection, env layout, and body
/// lowering are the ordinary lambda paths. Two things differ, both carried by
/// `lowerLambdaTyped`: the environment stays on the caller's stack (§12.1
/// forbids the compiler from choosing heap storage for it), and the result is
/// typed as this site's implementor rather than the structurally identical
/// `Closure(*T)`.
pub fn formInitPlan(self: *Lowering, arg: *const Node, target: TypeId) Ref {
    const arg_ty = self.inferExprType(arg);
    if (conforms(self, target, arg_ty)) return self.lowerExpr(arg);

    const impl_ty = self.module.types.initImplementorType(target, siteFor(self, arg));
    if (refuseProtocolSource(self, arg, arg_ty, target))
        return self.builder.emit(.{ .placeholder = self.module.types.internString("init-formation") }, impl_ty);

    const span = arg.span;
    const src = self.current_source_file;
    const dest_ident = self.synthNode(.{ .identifier = .{ .name = dest_param } }, span, src);
    const dest_deref = self.synthNode(.{ .deref_expr = .{ .operand = dest_ident } }, span, src);
    const write_stmt = self.synthNode(.{ .assignment = .{
        .target = dest_deref,
        .op = .assign,
        .value = @constCast(arg),
    } }, span, src);
    const stmts = self.alloc.dupe(*Node, &.{write_stmt}) catch unreachable;
    const body = self.synthNode(.{ .block = .{ .stmts = stmts } }, span, src);

    const params = self.alloc.dupe(ast.Param, &.{.{
        .name = dest_param,
        .name_span = span,
        // The destination's `*T` comes from the implementor's own signature,
        // exactly as an unannotated lambda parameter takes its type from a
        // `Closure(T0, …)` slot — an `@Init(T)`'s parameter list IS `[*T]`.
        .type_expr = self.synthNode(.{ .inferred_type = {} }, span, src),
    }}) catch unreachable;
    const lam = ast.Lambda{ .params = params, .return_type = null, .body = body };

    const saved_target = self.target_type;
    self.target_type = impl_ty;
    defer self.target_type = saved_target;
    // The write the thunk performs is FORMATION, not a store the program wrote:
    // what cannot become the target is refused in those terms (spec §5.2).
    const saved_forming = self.forming_init_target;
    self.forming_init_target = target;
    defer self.forming_init_target = saved_forming;
    return lower_closure.lowerLambdaTyped(self, &lam, .stack, impl_ty);
}

/// `value.write(dest)` — run the thunk against the receiver's storage, so the
/// argument expression evaluates into `dest` at WRITE time (spec §5.2). Each
/// call re-evaluates it: a second write re-runs the expression, side effects
/// included, which is legal language and the library's protocol to document.
///
/// The destination is EXACTLY `*T` for the init's type argument (§5.4): there
/// is no concrete-variant → `*P` widening arm.
pub fn lowerInitWrite(self: *Lowering, target: TypeId, recv: *const Node, args: []const *const Node, span: ast.Span) Ref {
    const dest_ty = self.module.types.ptrTo(target);
    if (args.len != 1) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "'write' takes exactly one argument — the '{s}' destination", .{self.formatTypeName(dest_ty)});
        }
        return Ref.none;
    }
    const saved_target = self.target_type;
    self.target_type = dest_ty;
    const dest = self.lowerExpr(args[0]);
    self.target_type = saved_target;
    const dest_actual = self.builder.getRefType(dest);
    if (dest_actual != dest_ty) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, args[0].span, "'write' needs a '{s}' destination, but this is '{s}'", .{ self.formatTypeName(dest_ty), self.formatTypeName(dest_actual) });
            if (dest_actual == target) d.addHelpFmt(id, args[0].span, null, "take its address with `*` to write into it", .{});
            // An open set has no widening arm (§5.4): a member's initializer writes
            // that member, and a set slot is written through the set's own.
            if (!dest_actual.isBuiltin()) {
                const pointee = self.module.types.get(dest_actual);
                if (pointee == .pointer and self.isOpenSet(pointee.pointer.pointee)) {
                    const set = self.openSetOf(pointee.pointer.pointee).?;
                    if (self.openSetDeclaresMembership(target, set.decl)) {
                        d.addHelpFmt(id, args[0].span, null, "'{s}' is a member of '{s}', and an initializer writes exactly its own type — take the set's initializer ('$I/@Init({s})') to write a set slot", .{ self.formatTypeName(target), set.decl.name, set.decl.name });
                    }
                }
            }
        }
        return Ref.none;
    }
    const plan = self.lowerExpr(recv);
    const call_args = if (self.implicit_ctx_enabled)
        self.alloc.dupe(Ref, &.{ self.current_ctx_ref, dest }) catch unreachable
    else
        self.alloc.dupe(Ref, &.{dest}) catch unreachable;
    return self.builder.emit(.{ .call_closure = .{ .callee = plan, .args = call_args } }, .void);
}

/// `value.site()` — the `@SourceSite` of the expression this initializer was
/// formed from (spec §5.1), or null when no site was recorded. The site is
/// baked per implementor type, so it is a constant in the monomorphized method:
/// two formation sites answer differently, and both instantiations of a generic
/// function report the template's path.
pub fn lowerInitSite(self: *Lowering, recv_ty: TypeId, args: []const *const Node, span: ast.Span) Ref {
    if (args.len != 0) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'{s}' takes no arguments", .{site_method});
        return Ref.none;
    }
    const tid = self.sourceSiteType() orelse {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'{s}' needs '{s}' in scope", .{ site_method, source_site.contract_name });
        return Ref.none;
    };
    const opt_ty = self.module.types.optionalOf(tid);
    // A formation request never reaches a receiver position, so id 0 means the
    // receiver is not an implementor at all.
    const site_id = self.module.types.initSiteOf(recv_ty) orelse 0;
    if (site_id == 0) return self.builder.constNull(opt_ty);
    const site = self.init_sites.items[site_id - 1];
    const indexed = site.indexed orelse return self.builder.constNull(opt_ty);
    const value = self.sourceSiteValue(tid, indexed, site.line, site.column);
    return self.builder.emit(.{ .optional_wrap = .{ .operand = value } }, opt_ty);
}
