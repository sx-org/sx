//! Generic bounds: resolving a bound head, and checking that a monomorphized
//! binding satisfies it.
//!
//! A bound is one of the node shapes `parseBoundExpr` produces — a bare head
//! (`type_expr`) or a head with type arguments (`parameterized_type_expr`). What
//! the head names decides who answers the conformance question:
//!
//!   - a PROTOCOL, declared or `@`-declared. The binding must implement it, and
//!     this file is where that is checked.
//!   - an ENCLOSING TYPE PARAMETER (`$V/P` inside `@BuildSink(P)`). Nothing is
//!     known about `P` while the template is generic, so the question defers to
//!     whichever call fixes that parameter — and is asked again there, against
//!     the concrete binding.
//!   - a COMPILER-FORMED contract (`@Init`, `@BuildBlock`). There is no
//!     declaration to check: the argument satisfies the bound by being formable
//!     into an implementor, which formation decides at the call.
//!
//! An unresolved head is an ordinary unknown-name error. There is no tolerated
//! middle state: a bound that names nothing constrains nothing, which is the one
//! reading the grammar does not have.

const std = @import("std");
const ast = @import("../../ast.zig");
const contracts = @import("../../contracts.zig");
const types = @import("../types.zig");

const Node = ast.Node;
const TypeId = types.TypeId;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;

/// What a bound head names.
pub const Head = union(enum) {
    /// A declared protocol. `ty` is null for a PARAMETERIZED protocol
    /// (`@BuildSink(P)`, `Into(T)`), which has no base TypeId — its conformance
    /// lives in the keyed parameterized-impl index instead.
    protocol: struct { ty: ?TypeId, name: []const u8 },
    /// An enclosing type parameter: the conformance question defers to the call
    /// that binds it.
    type_param: []const u8,
    /// A compiler-formed contract (`@Init`, `@BuildBlock`). It has no
    /// declaration to check against — satisfaction is decided by formation at
    /// the argument, not by an impl.
    formed: []const u8,
    /// Names nothing in scope.
    unknown: []const u8,
};

/// The head's written name, whatever it resolved to.
pub fn headName(node: *const Node) ?[]const u8 {
    return switch (node.data) {
        .type_expr => |te| te.name,
        .parameterized_type_expr => |pte| pte.name,
        else => null,
    };
}

/// Resolve one bound's head. `in_scope` are the type-parameter names the
/// enclosing declaration introduces — the scope that makes `$V/P` meaningful.
pub fn resolveHead(
    self: *Lowering,
    node: *const Node,
    source: ?[]const u8,
    in_scope: []const []const u8,
) Head {
    const name = headName(node) orelse return .{ .unknown = "" };
    for (in_scope) |tp| {
        if (std.mem.eql(u8, tp, name)) return .{ .type_param = name };
    }
    if (contracts.isCompilerFormed(name)) return .{ .formed = name };
    if (self.protocolResolver().resolveProtocol(name, source)) |p| {
        return .{ .protocol = .{ .ty = p.ty, .name = name } };
    }
    return .{ .unknown = name };
}

/// Check every bound on `type_params` against the bindings a monomorphization
/// installed. Only bounds whose head is a protocol are answered here; a
/// type-parameter head defers, and an unknown head is reported once per bound.
pub fn checkBindings(
    self: *Lowering,
    type_params: []const ast.StructTypeParam,
    bindings: *const std.StringHashMap(TypeId),
    source: ?[]const u8,
) void {
    if (self.diagnostics == null) return;
    // Every parameter of this declaration is in scope for every bound on it, so
    // a bound may name a sibling parameter (`$I/@Init($T)` beside `$T`).
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(self.alloc);
    for (type_params) |tp| names.append(self.alloc, tp.name) catch return;

    for (type_params) |tp| {
        if (tp.protocol_constraints.len == 0) continue;
        const bound_ty = bindings.get(tp.name) orelse continue;
        if (bound_ty == .unresolved) continue;
        for (tp.protocol_constraints) |bound| {
            switch (resolveHead(self, bound, source, names.items)) {
                .type_param, .formed => {},
                .unknown => |name| reportUnknownHead(self, bound, name, tp.name),
                .protocol => |p| checkOne(self, bound, p.ty, p.name, tp.name, bound_ty),
            }
        }
    }
}

/// The head as it would be WRITTEN in an impl — `Into(i32)`, not `Into` — so the
/// fixit names a spelling that exists.
fn spelledHead(self: *Lowering, bound: *const Node, proto_name: []const u8) []const u8 {
    const args = switch (bound.data) {
        .parameterized_type_expr => |pte| pte.args,
        else => return proto_name,
    };
    var out = std.ArrayList(u8).empty;
    out.appendSlice(self.alloc, proto_name) catch return proto_name;
    out.append(self.alloc, '(') catch return proto_name;
    for (args, 0..) |a, i| {
        if (i > 0) out.appendSlice(self.alloc, ", ") catch return proto_name;
        out.appendSlice(self.alloc, self.formatTypeName(self.resolveTypeArg(a))) catch return proto_name;
    }
    out.append(self.alloc, ')') catch return proto_name;
    return out.items;
}

fn reportUnknownHead(self: *Lowering, bound: *const Node, name: []const u8, param: []const u8) void {
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, bound.span, "unknown protocol '{s}' in the bound on '${s}'", .{ name, param });
    d.addHelpFmt(id, bound.span, null, "a bound names a protocol in scope, or one of this declaration's own type parameters", .{});
}

fn checkOne(
    self: *Lowering,
    bound: *const Node,
    proto_ty: ?TypeId,
    proto_name: []const u8,
    param: []const u8,
    bound_ty: TypeId,
) void {
    const d = self.diagnostics orelse return;
    // A parameterized head names an instantiation, whose conformance is the
    // keyed impl question `has_impl` already answers.
    if (bound.data == .parameterized_type_expr) {
        if (self.computeHasImpl(bound, bound_ty)) return;
        const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
            self.formatTypeName(bound_ty), proto_name, param,
        });
        d.addHelpFmt(id, bound.span, null, "no 'impl {s} for {s}' is visible here", .{ spelledHead(self, bound, proto_name), self.formatTypeName(bound_ty) });
        return;
    }
    const pty = proto_ty orelse return;
    // A protocol satisfies its own bound: `$V/View` bound to `View` is the
    // identity case, and asking whether `View` implements `View` would ask the
    // protocol to impl itself.
    if (bound_ty == pty) return;
    const concrete_name = self.resolveConcreteTypeName(bound_ty) orelse return;
    const missing = self.firstUnimplementedProtocolMethod(pty, concrete_name, bound_ty) orelse return;
    const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
        self.formatTypeName(bound_ty), proto_name, param,
    });
    d.addHelpFmt(id, bound.span, null, "'{s}' has no '{s}' for '{s}'", .{ concrete_name, missing, proto_name });
}
