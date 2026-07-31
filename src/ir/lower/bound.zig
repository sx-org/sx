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
//!     declaration to check: the binder holds what formation produced at the
//!     argument, and the check is that it did.
//!   - an OPEN SET. The deliberate narrow exception to the scheme above: a set is
//!     not a protocol and carries no impls, so `$V/View` asks a different
//!     question — is the binding a MEMBER of that set? Membership is the member's
//!     own declaration, so the answer is read off the declarations and never
//!     depends on when it is asked.
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
    /// lives in the keyed parameterized-impl index instead. `params` is how many
    /// type parameters the declaration takes, so a head spelled with the wrong
    /// number of arguments is caught rather than silently constraining nothing.
    protocol: struct { ty: ?TypeId, name: []const u8, params: usize },
    /// An enclosing type parameter: the conformance question defers to the call
    /// that binds it.
    type_param: []const u8,
    /// A compiler-formed contract (`@Init`, `@BuildBlock`). It has no
    /// declaration to check against — satisfaction is decided by formation at
    /// the argument, not by an impl.
    formed: []const u8,
    /// A declared open set. The bound asks for MEMBERSHIP, not conformance.
    open_set: struct { ty: TypeId, name: []const u8 },
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
        return .{ .protocol = .{ .ty = p.ty, .name = name, .params = p.decl.type_params.len } };
    }
    if (self.open_set_by_name.get(name)) |decl| {
        if (self.open_sets.getPtr(decl)) |set| return .{ .open_set = .{ .ty = set.ty, .name = name } };
    }
    // A QUALIFIED head names what a module reached by name owns. Membership and
    // conformance are keyed by the declaration, so the path resolves to the
    // declaration's own name — the one its members and impls were written against.
    if (std.mem.indexOfScalar(u8, name, '.') != null) {
        const from = source orelse self.current_source_file orelse self.main_file orelse "";
        switch (self.qualifiedMemberVerdictFrom(name, from)) {
            .selected => |sel| switch (sel.author.raw) {
                .open_set_decl => |osd| {
                    if (self.open_sets.getPtr(osd)) |set| return .{ .open_set = .{ .ty = set.ty, .name = osd.name } };
                },
                .protocol_decl => |pd| {
                    if (self.protocolResolver().resolveProtocol(pd.name, sel.target.target_module_path)) |p| {
                        return .{ .protocol = .{ .ty = p.ty, .name = pd.name, .params = p.decl.type_params.len } };
                    }
                },
                else => {},
            },
            else => {},
        }
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
                .formed => |name| checkFormed(self, bound, name, tp.name, bound_ty),
                // The named parameter may be bound by this very
                // monomorphization; when it is, the deferral has arrived and the
                // question is asked here against that binding.
                .type_param => |sibling| checkAgainstSibling(self, bound, sibling, tp.name, bound_ty, bindings),
                .unknown => |name| reportUnknownHead(self, bound, name, tp.name),
                .open_set => |set| checkMember(self, bound, set, tp.name, bound_ty),
                .protocol => |p| checkOne(self, bound, p, tp.name, bound_ty),
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
    d.addHelpFmt(id, bound.span, null, "a bound names a protocol in scope, an open set, or one of this declaration's own type parameters", .{});
}

/// An OPEN SET bound: the binding must be a MEMBER of the set. Nothing here asks
/// about impls — a set has none. Membership is the member's own declaration
/// (`V :: @OpenVariant(P)`), so the question has one answer whenever it is asked,
/// and a generic member's instantiation carries its template's declaration.
///
/// A set binds its own bound: `$V/View` bound to `View` is the identity case,
/// which is how a body that takes the whole set writes the same signature.
fn checkMember(
    self: *Lowering,
    bound: *const Node,
    head: @FieldType(Head, "open_set"),
    param: []const u8,
    bound_ty: TypeId,
) void {
    const set_name = head.name;
    const spelled_args: usize = switch (bound.data) {
        .parameterized_type_expr => |pte| pte.args.len,
        else => 0,
    };
    if (spelled_args != 0) {
        const d = self.diagnostics orelse return;
        const id = d.addFmtId(.err, bound.span, "the bound '{s}' on '${s}' takes no type arguments, but {d} {s} written", .{
            set_name, param, spelled_args, if (spelled_args == 1) "is" else "are",
        });
        d.addHelpFmt(id, bound.span, null, "an open set is not parameterized — write '${s}/{s}'", .{ param, set_name });
        return;
    }
    if (bound_ty == head.ty) return;
    if (self.openSetOf(head.ty)) |set| {
        if (self.openSetDeclaresMembership(bound_ty, set.decl)) return;
    }
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
        self.formatTypeName(bound_ty), set_name, param,
    });
    if (self.openSetOfMember(bound_ty)) |other| {
        d.addHelpFmt(id, bound.span, null, "'{s}' is a member of '{s}', and a type belongs to one set", .{ self.formatTypeName(bound_ty), other.decl.name });
    } else {
        d.addHelpFmt(id, bound.span, null, "a type joins '{s}' by declaring itself into it: '{s} :: @OpenVariant({s}) {{ … }}'", .{ set_name, self.formatTypeName(bound_ty), set_name });
    }
}

fn checkOne(
    self: *Lowering,
    bound: *const Node,
    p: @FieldType(Head, "protocol"),
    param: []const u8,
    bound_ty: TypeId,
) void {
    const spelled_args: usize = switch (bound.data) {
        .parameterized_type_expr => |pte| pte.args.len,
        else => 0,
    };
    // A head spelled with the wrong number of type arguments names no
    // instantiation, so there is nothing it could constrain.
    if (spelled_args != p.params) {
        reportArity(self, bound, p, param, spelled_args);
        return;
    }
    // A parameterized head names an instantiation, whose conformance is the
    // keyed impl question `has_impl` already answers.
    if (p.params > 0) {
        if (self.computeHasImpl(bound, bound_ty)) return;
        reportViolation(self, bound, spelledHead(self, bound, p.name), param, bound_ty,
            "no 'impl {s} for {s}' is visible here", .{ spelledHead(self, bound, p.name), self.formatTypeName(bound_ty) });
        return;
    }
    const pty = p.ty orelse return;
    // A protocol satisfies its own bound: `$V/View` bound to `View` is the
    // identity case, and asking whether `View` implements `View` would ask the
    // protocol to impl itself.
    if (bound_ty == pty) return;
    // Only a NOMINAL type can carry an impl. A structural binding — slice,
    // closure, tuple, function — has nowhere to hang one, so it fails the bound
    // rather than escaping the check for want of a name to look up.
    const concrete_name = self.resolveConcreteTypeName(bound_ty) orelse {
        reportViolation(self, bound, p.name, param, bound_ty,
            "'{s}' is a structural type and can carry no 'impl'", .{self.formatTypeName(bound_ty)});
        return;
    };
    const missing = self.firstUnimplementedProtocolMethod(pty, concrete_name, bound_ty) orelse return;
    reportViolation(self, bound, p.name, param, bound_ty,
        "'{s}' has no '{s}' for '{s}'", .{ self.formatTypeName(bound_ty), missing, p.name });
}

/// A compiler-formed bound. There is no impl to look up: the binding satisfies
/// `@Init(T)` by BEING an implementor the compiler minted for `T` at a formation
/// site, which is what this checks. A binder that took the argument's own type
/// instead — a parameter whose argument was never formed — fails here rather
/// than compiling into a lost deferral.
///
/// `@BuildBlock` binds a block body rather than a value; its conformance
/// question is answered where the block is bound, not here.
fn checkFormed(
    self: *Lowering,
    bound: *const Node,
    name: []const u8,
    param: []const u8,
    bound_ty: TypeId,
) void {
    const is_init = std.mem.eql(u8, name, contracts.init_bound);
    const is_block = std.mem.eql(u8, name, contracts.build_block_bound);
    if (!is_init and !is_block) return;
    const spelled_args: usize = switch (bound.data) {
        .parameterized_type_expr => |pte| pte.args.len,
        else => 0,
    };
    // An `@Init` bound names what a `write` fills, so exactly one type argument
    // says what that is. Any other spelling names no initializer, and formation
    // has nothing to target.
    if (spelled_args != 1) {
        const d0 = self.diagnostics orelse return;
        const id0 = d0.addFmtId(.err, bound.span, "the bound '{s}' on '${s}' takes one type argument, but {d} {s} written", .{
            name, param, spelled_args, if (spelled_args == 1) "is" else "are",
        });
        if (is_init) {
            d0.addHelpFmt(id0, bound.span, null, "write '${s}/{s}(T)' with the type a 'write' fills", .{ param, name });
        } else {
            d0.addHelpFmt(id0, bound.span, null, "write '${s}/{s}(P)' with the type its expressions are intercepted at", .{ param, name });
        }
        return;
    }
    const target_node = bound.data.parameterized_type_expr.args[0];
    const want = self.resolveTypeWithBindings(target_node);
    const spelled = if (want == .unresolved) name else spelledHead(self, bound, name);
    if (is_block) {
        checkFormedBlock(self, bound, spelled, param, bound_ty, want);
        return;
    }
    const actual = self.module.types.initTarget(bound_ty) orelse {
        const d = self.diagnostics orelse return;
        const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
            self.formatTypeName(bound_ty), spelled, param,
        });
        d.addHelpFmt(id, bound.span, null, "an initializer is formed at the argument of a value parameter — '${s}' can only bind what formation produced", .{param});
        return;
    };
    if (want == .unresolved or actual == want) return;
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
        self.formatTypeName(bound_ty), spelled, param,
    });
    d.addHelpFmt(id, bound.span, null, "this initializer writes '{s}', and the bound asks for '{s}'", .{ self.formatTypeName(actual), self.formatTypeName(want) });
}

/// The `@BuildBlock` half: the binding must be a block the compiler formed, for
/// the same interception type the bound names.
fn checkFormedBlock(
    self: *Lowering,
    bound: *const Node,
    spelled: []const u8,
    param: []const u8,
    bound_ty: TypeId,
    want: TypeId,
) void {
    const protocol = self.blockProtocolOf(bound_ty) orelse {
        const d = self.diagnostics orelse return;
        const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
            self.formatTypeName(bound_ty), spelled, param,
        });
        d.addHelpFmt(id, bound.span, null, "a build block is formed from a trailing block at the call — '${s}' can only bind one of those", .{param});
        return;
    };
    if (want == .unresolved or protocol == want) return;
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
        self.formatTypeName(bound_ty), spelled, param,
    });
    d.addHelpFmt(id, bound.span, null, "this block is intercepted at '{s}', and the bound asks for '{s}'", .{ self.formatTypeName(protocol), self.formatTypeName(want) });
}

/// The deferred question, arriving: `$V/P` where `P` is bound by this same
/// monomorphization. An unbound sibling still defers — it is answered wherever
/// that parameter is fixed.
fn checkAgainstSibling(
    self: *Lowering,
    bound: *const Node,
    sibling: []const u8,
    param: []const u8,
    bound_ty: TypeId,
    bindings: *const std.StringHashMap(TypeId),
) void {
    const sib_ty = bindings.get(sibling) orelse return;
    if (sib_ty == .unresolved) return;
    // The SPELLING is checked before the binding: a bound whose type-argument
    // list cannot be right is malformed whether or not this particular binding
    // would have satisfied it.
    const proto = self.getProtocolInfo(sib_ty);
    const spelled_args: usize = switch (bound.data) {
        .parameterized_type_expr => |pte| pte.args.len,
        else => 0,
    };
    // The sibling landed on a NON-PROTOCOL type, so the bound is not a
    // conformance question: `$V/P` with `P = i64` collapses the family to its one
    // member, and the binding has to be exactly that type.
    if (proto == null) {
        // A sibling bound to an open SET asks the set's own question wherever the
        // head is spelled: membership, not identity. A binder that reached the set
        // itself satisfies it too (spec: Open Sets — the membership bound).
        if (self.openSetOf(sib_ty)) |set| {
            checkMember(self, bound, .{ .ty = sib_ty, .name = set.decl.name }, param, bound_ty);
            return;
        }
        if (spelled_args > 0) {
            const d0 = self.diagnostics orelse return;
            const id = d0.addFmtId(.err, bound.span, "the bound on '${s}' spells type arguments, but '${s}' is bound to '{s}', which takes none", .{ param, sibling, self.formatTypeName(sib_ty) });
            d0.addHelpFmt(id, bound.span, null, "a bound on a concrete type is an identity, not an instantiation — write '${s}/{s}'", .{ param, sibling });
            return;
        }
        if (bound_ty == sib_ty) return;
        const d0 = self.diagnostics orelse return;
        const id = d0.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound on '${s}'", .{ self.formatTypeName(bound_ty), param });
        d0.addHelpFmt(id, bound.span, null, "'${s}' is bound to '{s}', so '${s}' must be '{s}'", .{ sibling, self.formatTypeName(sib_ty), param, self.formatTypeName(sib_ty) });
        return;
    }
    // The sibling landed on a protocol: its own arity decides whether the
    // spelling was well formed.
    if (self.protocol_ast_by_type.get(sib_ty)) |pd| {
        if (spelled_args != pd.type_params.len) {
            const d0 = self.diagnostics orelse return;
            const id = d0.addFmtId(.err, bound.span, "the bound on '${s}' writes {d} type argument{s}, but '${s}' is bound to '{s}', which takes {d}", .{
                param, spelled_args, if (spelled_args == 1) "" else "s", sibling, self.formatTypeName(sib_ty), pd.type_params.len,
            });
            d0.addHelpFmt(id, bound.span, null, "the arity is the bound protocol's, and '${s}' is only known at the call that binds it", .{sibling});
            return;
        }
    }
    if (bound_ty == sib_ty) return;
    const proto_name = self.formatTypeName(sib_ty);
    const concrete_name = self.resolveConcreteTypeName(bound_ty) orelse {
        reportViolation(self, bound, proto_name, param, bound_ty,
            "'{s}' is a structural type and can carry no 'impl'", .{self.formatTypeName(bound_ty)});
        return;
    };
    const missing = self.firstUnimplementedProtocolMethod(sib_ty, concrete_name, bound_ty) orelse return;
    reportViolation(self, bound, proto_name, param, bound_ty,
        "'{s}' has no '{s}' for '{s}'", .{ self.formatTypeName(bound_ty), missing, proto_name });
}

fn reportViolation(
    self: *Lowering,
    bound: *const Node,
    proto_name: []const u8,
    param: []const u8,
    bound_ty: TypeId,
    comptime help_fmt: []const u8,
    help_args: anytype,
) void {
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, bound.span, "'{s}' does not satisfy the bound '{s}' on '${s}'", .{
        self.formatTypeName(bound_ty), proto_name, param,
    });
    d.addHelpFmt(id, bound.span, null, help_fmt, help_args);
}

fn reportArity(
    self: *Lowering,
    bound: *const Node,
    p: @FieldType(Head, "protocol"),
    param: []const u8,
    spelled: usize,
) void {
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, bound.span, "the bound '{s}' on '${s}' takes {d} type argument{s}, but {d} {s} written", .{
        p.name, param, p.params, if (p.params == 1) "" else "s", spelled, if (spelled == 1) "is" else "are",
    });
    if (p.params > 0) {
        d.addHelpFmt(id, bound.span, null, "'{s}' is parameterized — write '{s}(…)' with its type argument{s}", .{
            p.name, p.name, if (p.params == 1) "" else "s",
        });
    } else {
        d.addHelpFmt(id, bound.span, null, "'{s}' takes no type arguments — write it bare", .{p.name});
    }
}
