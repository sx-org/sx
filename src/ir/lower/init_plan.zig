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

/// Form the `@Init(V)` recipe for `arg` (spec §5.2). The argument is NOT
/// evaluated here: it becomes the body of a thunk `(dest: *V) { dest.* =
/// <arg>; }`, so it runs when — and each time — the receiver calls `write`.
///
/// The closure lowerer does the work: capture collection, env layout, and body
/// lowering are the ordinary lambda paths. Two things differ, both carried by
/// `lowerLambdaTyped`: the environment stays on the caller's stack (§12.1
/// forbids the compiler from choosing heap storage for it), and the result is
/// typed `@Init(V)` rather than the structurally identical `Closure(*V)`.
pub fn formInitPlan(self: *Lowering, arg: *const Node, init_ty: TypeId) Ref {
    // Already a recipe for this target: the argument is a synchronous FORWARD
    // to another `@Init(T)` parameter (spec §5.1), which hands over the single
    // write rather than wrapping the recipe in a second one.
    if (self.inferExprType(arg) == init_ty) {
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

/// `value.write(dest)` — run the thunk against the receiver's storage, so the
/// argument expression evaluates into `dest` at WRITE time (spec §5.2). Each
/// call re-evaluates it: a second write re-runs the expression, side effects
/// included, which is legal language and the library's protocol to document.
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
