const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const lower_closure = @import("closure.zig");

/// The one compiler-formed `@` type name. `parseCompilerFormedType` is its only
/// producer, so this spelling can never collide with a user declaration.
pub const type_name = "@Init";

/// The destination parameter of a formed recipe. It names a synthesized lambda
/// parameter the user never writes, so it only has to be unspellable.
const dest_param = "__init_dest";

/// The one operation an `@Init(T)` exposes.
pub const write_method = "write";

/// The `T` of an `@Init(T)`, else null. Delegates to the type table's single
/// classifier so the frontend and the type model cannot disagree.
pub fn initTargetOf(self: *Lowering, ty: TypeId) ?TypeId {
    return self.module.types.initTarget(ty);
}

/// Form the nonescaping `@Init(V)` recipe for `arg` (spec §5.2). The argument is
/// NOT evaluated here: it becomes the body of a thunk `(dest: *V) { dest.* =
/// <arg>; }`, so it runs when — and only when — the receiver calls `write`.
///
/// The closure lowerer does the work: capture collection, env layout, and body
/// lowering are the ordinary lambda paths. Two things differ, both carried by
/// `lowerLambdaTyped`: the environment stays on the caller's stack (a recipe is
/// nonescaping, and §12.1 forbids the compiler from choosing heap storage), and
/// the result is typed `@Init(V)` rather than the structurally identical
/// `Closure(*V)`.
pub fn formInitPlan(self: *Lowering, arg: *const Node, init_ty: TypeId) Ref {
    // Already a recipe for this target: the argument is a synchronous FORWARD
    // to another `@Init(T)` parameter (spec §5.1), which hands over the single
    // write rather than wrapping the recipe in a second one.
    if (self.inferExprType(arg) == init_ty) {
        consumeInit(self, arg, arg.span);
        return self.lowerExpr(arg);
    }
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
        // The destination's `*V` comes from the target signature, exactly as an
        // unannotated lambda parameter takes its type from a `Closure(T0, …)`
        // slot — `@Init(V)`'s parameter list IS `[*V]`.
        .type_expr = self.synthNode(.{ .inferred_type = {} }, span, src),
    }}) catch unreachable;
    const lam = ast.Lambda{ .params = params, .return_type = null, .body = body };

    const saved_target = self.target_type;
    self.target_type = init_ty;
    defer self.target_type = saved_target;
    return lower_closure.lowerLambdaTyped(self, &lam, .stack, init_ty);
}

/// `value.write(dest)` — the recipe's one operation (spec §5.1.3): run the thunk
/// against the receiver's storage, so the argument expression evaluates exactly
/// once, directly into `dest`.
pub fn lowerInitWrite(self: *Lowering, target: TypeId, recv: *const Node, args: []const *const Node, span: ast.Span) Ref {
    consumeInit(self, recv, span);
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

// ── Ephemerality (spec §5.1) ────────────────────────────────────────────
// An `@Init(T)` may be received as a parameter, forwarded to another `@Init(T)`
// parameter, and written at most once. The type grammar already keeps it out of
// every storage position — `parseCompilerFormedType` accepts it as a parameter
// annotation and nowhere else, so no field, return type, element type, or global
// can name it. That leaves the ways to outlive or re-run the recipe from inside a
// body, rejected here: consuming it twice, consuming it where a loop can re-run
// the consumption, rebinding it to a local, and capturing it in a closure.

/// Mark a recipe consumed — by its `write`, or by a forward that hands the
/// write to another `@Init` parameter — and refuse a second consumption. The
/// record lives on the binding because a parameter name is the only thing that
/// can hold a recipe, and a binding lives exactly as long as its function body.
/// A consumption a loop can re-run is refused for the same reason: `write`
/// constructs its destination at most once.
fn consumeInit(self: *Lowering, recv: *const Node, span: ast.Span) void {
    if (recv.data != .identifier) return;
    const scope = self.scope orelse return;
    const binding = scope.lookupPtr(recv.data.identifier.name) orelse return;
    const name = recv.data.identifier.name;
    if (self.diagnostics) |d| {
        if (binding.init_written) |first| {
            const id = d.addFmtId(.err, span, "'{s}' is used again after it was consumed — an @Init value is written or forwarded once", .{name});
            d.addHelpFmt(id, first, null, "it was consumed here", .{});
        } else if (self.continue_target != null) {
            d.addFmt(.err, span, "'{s}' is consumed inside a loop — an @Init value is written or forwarded once", .{name});
        }
    }
    binding.init_written = span;
}

/// Refuse a local rebinding of an `@Init` value (`y := value`). An alias would
/// both escape the write-once record kept on the parameter binding and give the
/// recipe a second name outliving the call that formed it. Nothing but a bare
/// parameter reference can produce one, so an identifier initializer is the
/// whole surface.
pub fn rejectInitBinding(self: *Lowering, value: ?*const Node, name: []const u8) bool {
    const val = value orelse return false;
    if (val.data != .identifier) return false;
    const scope = self.scope orelse return false;
    const binding = scope.lookup(val.data.identifier.name) orelse return false;
    if (initTargetOf(self, binding.ty) == null) return false;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, val.span, "'{s}' cannot bind an {s} value — it is a nonescaping recipe, not storage", .{ name, self.formatTypeName(binding.ty) });
        d.addHelpFmt(id, val.span, null, "call '.write(dest)' to construct into storage, or forward it to another @Init parameter", .{});
    }
    // Bind the name to the same recipe so the refusal is the only diagnostic
    // this statement produces — the error already halts before codegen.
    scope.put(name, binding);
    return true;
}

/// Refuse capturing an `@Init` value into a closure: the closure may outlive the
/// forming call, and its env would then hold a recipe whose own env is gone.
pub fn rejectInitCapture(self: *Lowering, ty: TypeId, name: []const u8, span: ast.Span) void {
    if (initTargetOf(self, ty) == null) return;
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "'{s}' is an {s} value and cannot be captured by a closure — write it into storage the closure can reach instead", .{ name, self.formatTypeName(ty) });
    }
}
