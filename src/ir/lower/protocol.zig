const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const program_index_mod = @import("../program_index.zig");
const ProtocolDeclInfo = program_index_mod.ProtocolDeclInfo;
const ProtocolMethodInfo = program_index_mod.ProtocolMethodInfo;
const ProtocolResolver = @import("../protocols.zig").ProtocolResolver;

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const GlobalId = inst_mod.GlobalId;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const ProtocolImplMethod = lower.ProtocolImplMethod;
const ProtocolDefaultDispatchDomain = lower.ProtocolDefaultDispatchDomain;

/// Shared implementation for the `has_impl(P, T)` builtin and its
/// `tryConstBoolCondition` arm. The protocol expression is either:
/// - Plain `Hash` (identifier / type_expr) → `protocol_thunk_map["Hash\x00<T>"]`.
/// - Parameterised `Into(Block)` (call) → `param_impl_map` keyed by
///   `"<P>\x00<arg_mangled>\x00<T_mangled>"`.
/// Returns false on any malformed protocol-arg shape (caller
/// reports a diagnostic if it wants).
pub fn computeHasImpl(self: *Lowering, proto_node: *const Node, ty: TypeId) bool {
    const answer = plainHasImpl(self, proto_node, ty);
    if (spelledProtocolName(proto_node)) |name|
        _ = implFactWaits(self, protocolTypeOf(self, proto_node), name, ty, answer);
    return answer;
}

/// The impl-visibility answer itself, ahead of the discipline's wait. It is
/// the same static fact that decides whether the site could ERASE (§7.9) —
/// every protocol method reached by an impl — read off the declarations for a
/// plain protocol and off the keyed entry for a parameterized one.
fn plainHasImpl(self: *Lowering, proto_node: *const Node, ty: TypeId) bool {
    switch (proto_node.data) {
        .identifier, .type_expr => {
            const name: []const u8 = switch (proto_node.data) {
                .identifier => |id| id.name,
                else => proto_node.data.type_expr.name,
            };
            const p = self.protocolResolver().resolveProtocol(name, self.current_source_file) orelse return false;
            const pty = p.ty orelse return false;
            const cname = self.resolveConcreteTypeName(ty) orelse return false;
            return firstUnimplementedMethod(self, pty, cname, ty) == null;
        },
        .call, .parameterized_type_expr => {
            const p_name: []const u8 = switch (proto_node.data) {
                .parameterized_type_expr => |pte| pte.name,
                .call => |c| switch (c.callee.data) {
                    .identifier => |id| id.name,
                    .type_expr => |te| te.name,
                    else => return false,
                },
                else => return false,
            };
            const args: []const *Node = switch (proto_node.data) {
                .parameterized_type_expr => |pte| pte.args,
                .call => |c| c.args,
                else => return false,
            };
            // Resolve protocol type args. Each goes through `resolveTypeArg` so
            // type aliases / generics / pack-indexed types all work as args.
            var arg_tys = std.ArrayList(TypeId).empty;
            defer arg_tys.deinit(self.alloc);
            for (args) |a| arg_tys.append(self.alloc, self.resolveTypeArg(a)) catch return false;
            return self.protocolResolver().paramImplExists(p_name, arg_tys.items, ty);
        },
        else => return false,
    }
}

/// The name of the first protocol method `concrete_ty` fails to provide, or null
/// when it satisfies the protocol. The bound checker wants the name only.
pub fn firstUnimplementedProtocolMethod(self: *Lowering, proto_ty: TypeId, concrete_type_name: []const u8, concrete_ty: TypeId) ?[]const u8 {
    const nc = firstUnimplementedMethod(self, proto_ty, concrete_type_name, concrete_ty) orelse return null;
    return nc.method;
}

/// The name an `impl` head would spell to reach the protocol `proto_node`
/// names — the key the contribution ledger counts undecided drivers under.
fn spelledProtocolName(proto_node: *const Node) ?[]const u8 {
    return switch (proto_node.data) {
        .identifier => |id| id.name,
        .type_expr => |te| te.name,
        .call => |c| switch (c.callee.data) {
            .identifier => |id| id.name,
            .type_expr => |te| te.name,
            else => null,
        },
        else => null,
    };
}

/// What the discipline owes a `constraint`/erased-kind impl read, and in which
/// polarity. Impls are DECLARATIONS, so what an undecided driver could still
/// write is the whole question — but the two kinds owe it differently. A
/// `constraint` partition only ever grows, so a positive stands and only a
/// negative waits. An erased target reads impl MULTIPLICITY (§7.4), which is
/// monotone in NEITHER direction — a later impl repairs a miss exactly as
/// readily as it destroys a program-unique success — so BOTH polarities wait,
/// whether the count is zero, one, or already duplicated.
fn implFactWaits(self: *Lowering, proto_ty: ?TypeId, proto_name: []const u8, ty: TypeId, answer: bool) bool {
    if (!self.expansion.scheduled()) return false;
    if (answer and !erasedKind(self, proto_ty)) return false;
    if (!self.expansion.mayImpl(proto_name)) return false;
    const fact = if (answer)
        std.fmt.allocPrint(self.alloc, "'{s}' impls to be final before '{s}' is judged its unique conformer", .{ proto_name, self.formatTypeName(ty) })
    else
        std.fmt.allocPrint(self.alloc, "'{s}' impls to be final before '{s}' is judged a non-conformer", .{ proto_name, self.formatTypeName(ty) });
    self.expansion.awaitFact(fact catch "an impl set to be final");
    return true;
}

/// Does `proto_ty` carry a VALUE that stamps the impl it was erased with —
/// the kind whose conversion facts depend on multiplicity?
fn erasedKind(self: *Lowering, proto_ty: ?TypeId) bool {
    const pty = proto_ty orelse return false;
    const kind = protocolKindOf(self, pty) orelse return false;
    return kind == .vtable;
}

/// The protocol a `has_impl`-shaped spelling names, whatever its kind.
fn protocolTypeOf(self: *Lowering, proto_node: *const Node) ?TypeId {
    const name = spelledProtocolName(proto_node) orelse return null;
    const p = self.protocolResolver().resolveProtocol(name, self.current_source_file) orelse return null;
    return p.ty;
}

/// Register a protocol declaration. Thin delegation to the canonical owner
/// (`ProtocolResolver`, `protocols.zig`); kept on `Lowering` as a `pub`
/// entry point because the scan pass + several unit tests reach it here.
pub fn registerProtocolDecl(self: *Lowering, pd: *const ast.ProtocolDecl) void {
    return self.protocolResolver().registerProtocolDecl(pd);
}

/// Instantiate a parameterized protocol as a runtime VALUE type:
/// `VL(i64)` → a 16-byte `{ctx, __vtable}` protocol value (`is_protocol`),
/// with method infos resolved under the type-arg binding (so `get -> T`
/// becomes `get -> i64`) and the binding recorded for projection. Cached by
/// the mangled name `VL__i64`. Mirrors the non-parameterized path in
/// `registerProtocolDecl`.
pub fn instantiateParamProtocol(self: *Lowering, pd: *const ast.ProtocolDecl, args: []const *const Node) TypeId {
    const table = &self.module.types;
    const void_ptr_ty = table.ptrTo(.void);

    var tb = std.StringHashMap(TypeId).init(self.alloc);
    var arg_tys = std.ArrayList(TypeId).empty;
    for (pd.type_params, 0..) |tp, i| {
        if (i >= args.len) break;
        const ty = self.resolveTypeWithBindings(args[i]);
        tb.put(tp.name, ty) catch {};
        arg_tys.append(self.alloc, ty) catch @panic("out of memory");
    }
    const mangled = self.protocolResolver().paramProtocolInstanceName(self.protocolResolver().protocolIdentityName(pd), arg_tys.items);
    const name_id = table.internString(mangled);
    if (table.findByName(name_id)) |existing| {
        const info = table.get(existing);
        if (info == .@"struct" and info.@"struct".is_protocol) return existing;
    }

    // Value struct: {ctx, __type_id, __vtable} — the type_id word mirrors
    // registerProtocolDecl's layout.
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    fields.append(self.alloc, .{ .name = table.internString("ctx"), .ty = void_ptr_ty }) catch unreachable;
    fields.append(self.alloc, .{
        .name = table.internString("__type_id"),
        .ty = .type_value,
    }) catch unreachable;
    fields.append(self.alloc, .{ .name = table.internString("__vtable"), .ty = void_ptr_ty }) catch unreachable;
    const struct_info: types.TypeInfo = .{ .@"struct" = .{ .name = name_id, .fields = fields.items, .is_protocol = true } };
    const id = if (table.findByName(name_id)) |existing| existing else table.intern(struct_info);
    table.updatePreservingKey(id, struct_info);

    // Method infos resolved with the type-arg binding (T → i64), pinned to
    // the protocol's OWN module so a method-signature type visible only
    // there resolves correctly when instantiated cross-module. `Self` and the
    // bound type-args short-circuit before the leaf; a concrete library type
    // in a signature is the case this pin protects.
    const saved_tb = self.type_bindings;
    self.type_bindings = tb;
    const saved_pp_src = self.current_source_file;
    defer self.setCurrentSourceFile(saved_pp_src);
    if (pd.source_file) |src| self.setCurrentSourceFile(src);
    var method_infos = std.ArrayList(ProtocolMethodInfo).empty;
    for (pd.methods) |method| {
        var ptypes = std.ArrayList(TypeId).empty;
        for (method.params) |p| {
            const pty = blk: {
                if (p.data == .type_expr and std.mem.eql(u8, p.data.type_expr.name, "Self")) break :blk void_ptr_ty;
                break :blk self.resolveTypeWithBindings(p);
            };
            ptypes.append(self.alloc, pty) catch unreachable;
        }
        const ret = if (method.return_type) |rt| blk: {
            if (rt.data == .type_expr and std.mem.eql(u8, rt.data.type_expr.name, "Self")) {
                break :blk void_ptr_ty;
            }
            break :blk self.resolveTypeWithBindings(rt);
        } else .void;
        // A method is an sx call, so the instantiated signature meets the
        // C-variadic cursor rules as non-C — the bindings can introduce cursor
        // leaves the template's declaration preflight cannot see.
        for (method.params, ptypes.items) |p, pty| {
            if (!self.refuseCursorMethodParam(pty, p.span)) _ = self.refuseCursorSignature(pty, p.span);
        }
        if (method.return_type) |rt| {
            if (!self.refuseCursorEscape(ret, rt.span, "declare a return of type")) _ = self.refuseCursorSignature(ret, rt.span);
        }
        const self_occ = program_index_mod.protocolMethodSelfOccurrence(method);
        const info: ProtocolMethodInfo = .{
            .name = method.name,
            .param_types = self.alloc.dupe(TypeId, ptypes.items) catch unreachable,
            .ret_type = ret,
            .dispatchable = self_occ == null,
            .self_param = if (self_occ) |occ| occ.param_name else null,
        };
        method_infos.append(self.alloc, info) catch unreachable;
    }
    self.type_bindings = saved_tb;

    const owned = self.alloc.dupe(u8, mangled) catch return id;
    const protocol_info: ProtocolDeclInfo = .{
        .name = owned,
        .kind = pd.kind,
        .ownership = if (pd.is_identity) .identity else .value_own,
        .methods = self.alloc.dupe(ProtocolMethodInfo, method_infos.items) catch unreachable,
    };
    self.program_index.protocol_decl_map.put(owned, protocol_info) catch {};
    self.protocol_info_by_type.put(id, protocol_info) catch @panic("out of memory");
    // The canonical argument tuple, kept alongside the family's declaration
    // identity: impl lookup and coherence key on this pair rather than on the
    // instance's display name.
    self.param_protocol_instances.put(id, .{
        .base = self.protocolResolver().protocolIdentityName(pd),
        .args = self.alloc.dupe(TypeId, arg_tys.items) catch unreachable,
        .decl = pd,
    }) catch @panic("out of memory");
    // Record the type-arg binding so projection (`xs.T`, `.value`) and
    // method-arg resolution on this instance can recover it.
    self.struct_instance_bindings.put(owned, tb) catch {};

    var vtable_fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    for (pd.methods) |m| {
        if (program_index_mod.protocolMethodSelfOccurrence(m) != null) continue;
        vtable_fields.append(self.alloc, .{ .name = table.internString(m.name), .ty = void_ptr_ty }) catch unreachable;
    }
    const vtable_name = std.fmt.allocPrint(self.alloc, "__{s}__Vtable", .{mangled}) catch @panic("out of memory");
    const vtable_ty = table.intern(.{ .@"struct" = .{ .name = table.internString(vtable_name), .fields = vtable_fields.items } });
    self.protocol_vtable_type_map.put(owned, vtable_ty) catch {};
    self.protocol_vtable_type_by_type.put(id, vtable_ty) catch @panic("out of memory");
    return id;
}

// ── Protocol namespace lookups (pack projection) ─────────────────────
// (The position-driven orchestrator `resolvePackProjection` lives in
// lower/pack.zig; these two lookups are its per-namespace halves.)
//
// A `..pack.<name>` projection can target two protocol namespaces:
//   - type-arg namespace: the `protocol($T, ...)` params.
//   - runtime-accessor namespace: the protocol's methods (protocols have
//     no fields; a zero-arg method like `value` is the accessor).
// Resolution is POSITION-driven, not precedence-driven: type position
// consults type-args, value position consults methods, with NO
// cross-namespace fallback.

/// Find `name` in `protocol_name`'s type-arg namespace (`protocol($T,...)`).
/// Returns the `type_params` index, or null (also for unknown protocols).
pub fn lookupProtocolArg(self: *Lowering, protocol_name: []const u8, name: []const u8) ?u32 {
    const pd = self.program_index.protocol_ast_map.get(protocol_name) orelse return null;
    for (pd.type_params, 0..) |tp, i| {
        if (std.mem.eql(u8, tp.name, name)) return @intCast(i);
    }
    return null;
}

/// Find `name` in `protocol_name`'s runtime-accessor namespace (its methods
/// — protocols have no fields). Returns the `methods` index, or null.
pub fn lookupProtocolField(self: *Lowering, protocol_name: []const u8, name: []const u8) ?u32 {
    const pd = self.program_index.protocol_ast_map.get(protocol_name) orelse return null;
    for (pd.methods, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return @intCast(i);
    }
    return null;
}

/// Check if a type name is a registered protocol.
pub fn isProtocolType(self: *Lowering, type_name: []const u8) bool {
    return self.program_index.protocol_decl_map.contains(type_name);
}

/// Get protocol info for a TypeId (if it's a protocol type).
/// Protocol lookup. Thin delegation to the canonical owner
/// (`ProtocolResolver`, `protocols.zig`); kept on `Lowering` because ~9
/// callers (dispatch sites here + `calls.zig`) reach it.
pub fn getProtocolInfo(self: *Lowering, ty: TypeId) ?ProtocolDeclInfo {
    return self.protocolResolver().getProtocolInfo(ty);
}

/// Source-aware classification for `$T: Protocol` generic constraints.
pub fn isProtocolConstraint(self: *Lowering, written: []const u8, source: ?[]const u8) bool {
    return self.protocolResolver().isProtocolConstraint(written, source);
}

/// The declared kind of the protocol `ty` names, or null when `ty` is not a
/// protocol type.
pub fn protocolKindOf(self: *Lowering, ty: TypeId) ?ast.ProtocolKind {
    if (ty.isBuiltin() or ty == .unresolved) return null;
    const info = self.module.types.get(ty);
    if (info != .@"struct" or !info.@"struct".is_protocol) return null;
    const pd = self.getProtocolInfo(ty) orelse return null;
    return pd.kind;
}

/// One declared `impl P for T` site, for the coherence checks that name every
/// place a pair was implemented.
pub const ImplSite = struct {
    span: ast.Span,
    source: ?[]const u8,
};

/// The concrete `Type` word of a protocol value: the stamped slot 1 (§7.2,
/// §7.3). Everything that reads a protocol value's RTTI — `type_of`, the
/// downcast, the type switch, `@Protocol`, the `any` bridge — goes through
/// here.
pub fn protocolTypeIdWord(self: *Lowering, value: Ref) Ref {
    return self.builder.structGet(value, 1, .type_value);
}

/// The concrete type a `?*T` postfix target tests, when `child` is a plain
/// pointer whose pointee names one. A protocol pointee is the type lie the
/// hard ctx recovery refuses; `void` and `any` name no concrete type, so
/// neither can be a membership question.
pub fn softRecoveryPointee(self: *Lowering, child: TypeId) ?TypeId {
    if (child.isBuiltin()) return null;
    const info = self.module.types.get(child);
    if (info != .pointer) return null;
    const pointee = info.pointer.pointee;
    if (pointee == .void or pointee == .any or pointee == .unresolved) return null;
    if (self.getProtocolInfo(pointee) != null) return null;
    return pointee;
}

/// `p.(?*T)` — the SOFT ctx recovery (§6.8). It asks the downcast's membership
/// question and differs from `p.(?T)` only in the answer it hands back: the
/// receiver's own ctx typed as `*T`, so the concrete value is BORROWED in place
/// instead of copied out. The target is `T`, never `*T`, which is what the
/// any-view helpers could not answer. Returns null when the written target is
/// not `?*T`.
pub fn lowerSoftPointerRecovery(
    self: *Lowering,
    pc: *const ast.PostfixCast,
    full_dst: TypeId,
) ?Ref {
    if (pc.type_expr.data != .optional_type_expr) return null;
    if (full_dst.isBuiltin() or self.module.types.get(full_dst) != .optional) return null;
    const ptr_ty = self.module.types.get(full_dst).optional.child;
    if (ptr_ty.isBuiltin() or self.module.types.get(ptr_ty) != .pointer) return null;

    const pointee = softRecoveryPointee(self, ptr_ty) orelse {
        const written = self.module.types.get(ptr_ty).pointer.pointee;
        if (self.diagnostics) |d| {
            if (self.getProtocolInfo(written) != null) {
                d.addFmt(.err, pc.type_expr.span, "the ctx recovery yields a pointer to the CONCRETE value, so its target must be the concrete pointee type ('p.(?*YourConcrete)'); to point at the protocol value itself, take its address with prefix '*'", .{});
            } else {
                d.addFmt(.err, pc.type_expr.span, "the soft ctx recovery tests the pointee type, and '{s}' names no concrete type — name the conformer ('p.(?*YourConcrete)'), or take the unchecked raw ctx with 'p.(*void)'", .{self.formatTypeName(written)});
            }
        }
        return self.builder.constUndef(full_dst);
    };
    const operand = self.lowerExpr(pc.operand);

    const got = protocolTypeIdWord(self, operand);
    const want = self.builder.constType(pointee);
    const matches = self.builder.emit(.{ .cmp_eq = .{ .lhs = got, .rhs = want } }, .bool);

    const ok_bb = self.freshBlock("ptrcast.ok");
    const fail_bb = self.freshBlock("ptrcast.fail");
    const merge_bb = self.freshBlockWithParams("ptrcast.merge", &.{full_dst});
    self.builder.condBr(matches, ok_bb, &.{}, fail_bb, &.{});

    self.builder.switchToBlock(ok_bb);
    const void_ptr_ty = self.module.types.ptrTo(.void);
    const ctx = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
    const typed = self.builder.emit(.{ .bitcast = .{ .operand = ctx, .from = void_ptr_ty, .to = ptr_ty } }, ptr_ty);
    self.builder.br(merge_bb, &.{self.builder.optionalWrap(typed, full_dst)});

    self.builder.switchToBlock(fail_bb);
    self.builder.br(merge_bb, &.{self.builder.constNull(full_dst)});

    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, full_dst);
}

/// The protocol reached through `ty`'s composite spine (`*P`, `?P`, `[]P`,
/// `[N]P`, `[*]P`) whose values do not exist — `constraint` alone. Struct
/// FIELDS are not walked: each was checked at its own declaration.
fn valuelessProtocolIn(self: *Lowering, ty: TypeId) ?TypeId {
    if (ty.isBuiltin() or ty == .unresolved) return null;
    const info = self.module.types.get(ty);
    return switch (info) {
        .pointer => |p| valuelessProtocolIn(self, p.pointee),
        .many_pointer => |p| valuelessProtocolIn(self, p.element),
        .optional => |o| valuelessProtocolIn(self, o.child),
        .slice => |sl| valuelessProtocolIn(self, sl.element),
        .array => |a| valuelessProtocolIn(self, a.element),
        .@"struct" => |s| blk: {
            if (!s.is_protocol) break :blk null;
            const pd = self.getProtocolInfo(ty) orelse break :blk null;
            break :blk if (pd.kind == .constraint) ty else null;
        },
        else => null,
    };
}

/// Refuse a protocol whose kind has no runtime values at a position that
/// would make or store one. `what` completes "cannot …" — "make a value of",
/// "declare a field of type". Returns true when a diagnostic was emitted.
pub fn refuseValuelessProtocol(self: *Lowering, ty: TypeId, span: ast.Span, what: []const u8) bool {
    const offender = valuelessProtocolIn(self, ty) orelse return false;
    const name = self.formatTypeName(offender);
    const d = self.diagnostics orelse return true;
    // The guidance is use-site only: stay concrete, or bind through a
    // constraint. Whether the protocol should have runtime values is its
    // author's decision, made at the declaration.
    d.addFmt(.err, span, "cannot {s} '{s}' — a constraint protocol has no runtime values; use the concrete type, or a generic bound ('$T/{s}') where polymorphism is needed", .{ what, name, name });
    return true;
}

/// The escape rules for a comptime result that lands in the runtime image
/// (specs.md §6.9), applied to the type it escapes AS.
///
/// An OWNING erased value cannot make the trip at all — no runtime allocator
/// owns a compile-time copy — while a borrow (a view, an `#identity` handle) is
/// only ever a pointer to storage the image already has.
pub fn checkComptimeEscape(self: *Lowering, ty: TypeId, span: ast.Span) void {
    var seen = std.ArrayList(TypeId).empty;
    defer seen.deinit(self.alloc);
    walkEscape(self, ty, span, true, &seen);
}

fn walkEscape(self: *Lowering, ty: TypeId, span: ast.Span, by_value: bool, seen: *std.ArrayList(TypeId)) void {
    if (ty.isBuiltin() or ty == .unresolved) return;
    for (seen.items) |s| if (s == ty) return;
    seen.append(self.alloc, ty) catch @panic("out of memory");
    switch (self.module.types.get(ty)) {
        .pointer => |p| walkEscape(self, p.pointee, span, false, seen),
        .many_pointer => |p| walkEscape(self, p.element, span, false, seen),
        .optional => |o| walkEscape(self, o.child, span, by_value, seen),
        .slice => |sl| walkEscape(self, sl.element, span, false, seen),
        .array => |a| walkEscape(self, a.element, span, by_value, seen),
        .tuple => |t| for (t.fields) |f| walkEscape(self, f, span, by_value, seen),
        .@"struct" => |s| {
            if (!s.is_protocol) {
                for (s.fields) |f| walkEscape(self, f.ty, span, by_value, seen);
                return;
            }
            const pd = self.getProtocolInfo(ty) orelse return;
            if (!by_value or pd.kind == .constraint or pd.ownership == .identity) return;
            if (self.diagnostics) |d| {
                d.addFmt(.err, span, "a '{s}' value owns its storage and cannot escape a `@run` — no runtime allocator owns a compile-time copy; bind the concrete value, and let the owning erasure happen at runtime", .{self.formatTypeName(ty)});
            }
        },
        else => {},
    }
}

/// Get or create thunks for a (protocol, concrete_type) pair.
/// Returns a slice of FuncIds, one per protocol method.
pub fn getOrCreateThunks(self: *Lowering, proto_ty: TypeId, concrete_type_name: []const u8, concrete_ty: TypeId) []const FuncId {
    const pd = self.getProtocolInfo(proto_ty) orelse return &.{};
    const identity_ty: ?TypeId = if (self.protocol_ast_by_type.contains(proto_ty)) proto_ty else null;
    const key = self.protocolResolver().protocolConcreteKey(identity_ty, pd.name, concrete_ty);
    if (self.protocol_thunk_map.get(key)) |thunks| return thunks;

    // PLANNING: which methods need a thunk (owned by the registry).
    const methods = pd.methods;
    var thunk_ids = std.ArrayList(FuncId).empty;
    defer thunk_ids.deinit(self.alloc);

    // EMISSION: materialize one thunk per DISPATCHABLE method (stays in
    // Lowering). Excluded methods (Era-2: `Self` past the receiver) have no
    // slot anywhere — the thunk list must align with the filtered vtable
    // field list built at protocol registration.
    for (methods) |method| {
        if (!method.dispatchable) continue;
        const thunk_id = self.createProtocolThunk(proto_ty, pd.name, concrete_type_name, concrete_ty, method);
        thunk_ids.append(self.alloc, thunk_id) catch unreachable;
    }

    const owned = self.alloc.dupe(FuncId, thunk_ids.items) catch unreachable;
    self.protocol_thunk_map.put(key, owned) catch @panic("out of memory");
    return owned;
}

/// Get or create the vtable global for a (protocol, concrete_type) pair: one
/// constant of thunk function pointers, shared by every erasure of that pair —
/// the runtime `struct_init` form and the static fold alike. Null = the
/// protocol registered no vtable type (not a vtable kind).
pub fn getOrCreateVtableGlobal(
    self: *Lowering,
    proto_ty: TypeId,
    proto_name: []const u8,
    concrete_type_name: []const u8,
    concrete_ty: TypeId,
    thunks: []const FuncId,
) ?GlobalId {
    const vtable_ty = self.protocol_vtable_type_by_type.get(proto_ty) orelse return null;
    const identity_ty: ?TypeId = if (self.protocol_ast_by_type.contains(proto_ty)) proto_ty else null;
    const key = self.protocolResolver().protocolConcreteKey(identity_ty, proto_name, concrete_ty);
    if (self.protocol_vtable_global_map.get(key)) |gid| return gid;

    const concrete_dispatch_name = protocolConcreteDispatchName(self, concrete_type_name, concrete_ty);
    const protocol_dispatch_name = protocolRuntimeDispatchName(self, proto_name, proto_ty);
    const global_name = std.fmt.allocPrint(self.alloc, "__{s}__{s}__vtable", .{ protocol_dispatch_name, concrete_dispatch_name }) catch @panic("out of memory");
    const global_name_id = self.module.types.strings.intern(self.alloc, global_name);
    const gid = self.module.addGlobal(.{
        .name = global_name_id,
        .ty = vtable_ty,
        .init_val = .{ .vtable = self.alloc.dupe(FuncId, thunks) catch @panic("out of memory") },
        .is_const = true,
    });
    self.protocol_vtable_global_map.put(key, gid) catch @panic("out of memory");
    return gid;
}

/// Fold `<global>` / `xx <global>` at a `vtable` protocol-typed static
/// initializer into the constant `{ ctx, __type_id, &vtable }`. Only an
/// IDENTIFIER naming a registered top-level global qualifies: the erasure
/// BORROWS the global's stable storage (identity semantics), so ctx is the
/// global's address — ALWAYS, stateless impls included: there is no
/// null-receiver shortcut,
/// because a null ctx is the `?Protocol` "absent" sentinel and must never
/// appear in a live protocol value. Null result = not this shape / not
/// resolvable; the caller falls through to its non-const diagnostic.
pub fn protocolErasureConst(self: *Lowering, operand: *const Node, proto_ty: TypeId) ?inst_mod.ConstantValue {
    const tbl = &self.module.types;
    if (proto_ty.isBuiltin()) return null;
    const proto_ti = tbl.get(proto_ty);
    if (proto_ti != .@"struct" or !proto_ti.@"struct".is_protocol) return null;
    const pd = self.getProtocolInfo(proto_ty) orelse return null;
    if (pd.kind == .constraint) return null;
    if (operand.data != .identifier) return null;
    const gname = operand.data.identifier.name;
    const g: program_index_mod.GlobalInfo = switch (self.selectGlobalAuthor(gname)) {
        .resolved => |sel| sel,
        .untracked => self.program_index.global_names.get(gname) orelse return null,
        else => return null,
    };
    const concrete_name = self.formatTypeName(g.ty);
    const thunks = self.getOrCreateThunks(proto_ty, concrete_name, g.ty);
    const want = dispatchableCount(pd.methods);
    if (want == 0 or thunks.len != want) return null;
    const vt = getOrCreateVtableGlobal(self, proto_ty, pd.name, concrete_name, g.ty, thunks) orelse return null;
    const fields = self.alloc.alloc(inst_mod.ConstantValue, 3) catch return null;
    fields[0] = .{ .global_ref = g.id };
    fields[1] = .{ .int = @intCast(g.ty.index()) };
    fields[2] = .{ .global_ref = vt };
    return .{ .aggregate = fields };
}

/// What the protocol-typed arm of the global-initializer serializer decided.
pub const ProtocolGlobalInit = union(enum) {
    /// Not a borrow-kind protocol-typed global — the ordinary serializer owns it.
    not_applicable,
    folded: inst_mod.ConstantValue,
    /// Refused; the diagnostic is already out.
    refused,
};

/// The static initializer of a borrow-kind protocol-typed global (§7.6): the
/// identity erasure of a NAMED global instance, written `g` or `xx g`. A
/// protocol value in static data is a borrow, and only a global has an
/// address to borrow — so every other initializer shape is refused HERE,
/// before the shape dispatch serializes it field-wise against the handle's
/// layout and builds a value whose ctx word is a payload byte. `null` / `---`
/// keep their own meaning and never reach this arm.
pub fn protocolGlobalInit(self: *Lowering, vd: *const ast.VarDecl, v: *const Node, proto_ty: TypeId) ProtocolGlobalInit {
    if (proto_ty.isBuiltin()) return .not_applicable;
    const proto_ti = self.module.types.get(proto_ty);
    if (proto_ti != .@"struct" or !proto_ti.@"struct".is_protocol) return .not_applicable;
    const pd = self.getProtocolInfo(proto_ty) orelse return .not_applicable;
    if (pd.kind == .constraint) return .not_applicable;

    const named: ?*const Node = switch (v.data) {
        .identifier => v,
        .unary_op => |u| if (u.op == .xx and u.operand.data == .identifier) u.operand else null,
        else => null,
    };
    const operand = named orelse {
        if (self.diagnostics) |d| {
            const pname = self.formatTypeName(proto_ty);
            d.addFmt(.err, v.span, "'{s}' is a '{s}' value, which borrows its receiver — its initializer must NAME a global instance to borrow ('{s} : {s} = the_instance;'), and this expression has no address to point at", .{ vd.name, pname, vd.name, pname });
        }
        return .refused;
    };
    const gname = operand.data.identifier.name;
    const g: program_index_mod.GlobalInfo = switch (self.selectGlobalAuthor(gname)) {
        .resolved => |sel| sel,
        .untracked => self.program_index.global_names.get(gname) orelse return .not_applicable,
        else => return .not_applicable,
    };
    if (refuseNonConformer(self, proto_ty, self.formatTypeName(g.ty), g.ty, v.span)) return .refused;
    if (protocolErasureConst(self, operand, proto_ty)) |cv| return .{ .folded = cv };
    return .not_applicable;
}

/// Emit the process-wide default Context as an LLVM static constant.
///
///   @__sx_default_context = internal constant %Context {
///     %Allocator { ptr null, i64 <CAllocator type_id>,      (each field in
///                  ptr @__thunk_CAllocator_Allocator_alloc_bytes,
///                  ptr @__thunk_CAllocator_Allocator_dealloc_bytes },
///     %Io { … },                                     its protocol's own
///     <each #context_extend field's evaluated default>   declared layout)
///   }
///
/// The initializer is built by walking the ASSEMBLED Context's fields BY
/// NAME (`allocator`/`io` get their bespoke thunk-table values; every other
/// field is a `#context_extend` declaration whose default folds through the
/// global-initializer serializer in its declaring module's context), so the
/// constant can never drift positionally from the layout `assembleContext`
/// produced.
///
/// Used by FFI inbound wrappers and the interp's default-context call entry.
/// Only emitted when the program imports `std.sx` — without that, Context /
/// Allocator / CAllocator aren't registered and the global has no purpose.
pub fn emitDefaultContextGlobal(self: *Lowering) void {
    emitDefaultContextGlobalImpl(self, .final);
}

/// Early, ALL-OR-NOTHING emission for comptime evaluation that runs during
/// `scanDecls` (a type-fn const): once the Context is assembled, the same
/// constant pass 1c would emit is emitted now, so the VM's one materializer —
/// laying out `__sx_default_context` — serves scan time too (no hand-built
/// shadow context, no hardcoded thunk tables). Quiet by construction:
/// diagnostics are suspended, and if ANY field's default fails to serialize
/// (e.g. its backing global isn't registered yet) nothing is emitted — the
/// authoritative pass-1c call re-runs with diagnostics live.
pub fn emitDefaultContextGlobalEarly(self: *Lowering) void {
    if (!self.context_assembled) return;
    const saved_diags = self.diagnostics;
    self.diagnostics = null;
    defer self.diagnostics = saved_diags;
    emitDefaultContextGlobalImpl(self, .early);
}

fn emitDefaultContextGlobalImpl(self: *Lowering, mode: enum { early, final }) void {
    // Already emitted (possibly early) — never emit twice.
    if (self.program_index.global_names.contains("__sx_default_context")) return;
    const saved_edc = self.emitting_default_context;
    self.emitting_default_context = true;
    defer self.emitting_default_context = saved_edc;
    const tbl = &self.module.types;
    const ctx_name_id = tbl.internString("Context");
    const ctx_ty = tbl.findByName(ctx_name_id) orelse return;

    // One ConstantValue per ASSEMBLED field, in field order. EVERY field is a
    // `#context_extend` declaration (the struct decl itself is empty —
    // allocator/io are declared in std/mem.sx and std/io.sx like any user
    // field), so the whole initializer flows through the declaration-default
    // serializer; the stateless thunk tables come from the `xx c_allocator` /
    // `xx c_blocking_io` erasure folds. A field with NO matching declaration
    // (a hand-declared Context struct with its own fields, outside std) has
    // no constructible default — emit no global at all rather than a
    // silently zero-filled one; consumers of the default context diagnose at
    // their use sites, exactly as a non-std program does. A field whose
    // declared default FAILED to serialize is zero-filled to keep the
    // aggregate shaped — its error is already out and the build halts before
    // codegen.
    const ctx_info = tbl.get(ctx_ty);
    if (ctx_info != .@"struct") return;
    const ctx_struct_fields = ctx_info.@"struct".fields;
    const ctx_fields = self.alloc.alloc(inst_mod.ConstantValue, ctx_struct_fields.len) catch return;
    for (ctx_struct_fields, 0..) |f, i| {
        const fname = tbl.getString(f.name);
        if (!self.hasContextExtension(fname)) return;
        ctx_fields[i] = self.contextExtensionDefault(fname, f.ty) orelse switch (mode) {
            // Early: something isn't ready — emit nothing, pass 1c decides.
            .early => return,
            // Final: the serializer already diagnosed; zero-fill to keep the
            // aggregate shaped while the build halts before codegen.
            .final => .zeroinit,
        };
    }

    const global_name = "__sx_default_context";
    const global_name_id = tbl.internString(global_name);
    const gid = self.module.addGlobal(.{
        .name = global_name_id,
        .ty = ctx_ty,
        .init_val = .{ .aggregate = ctx_fields },
        .is_const = true,
    });
    self.putGlobal(self.current_source_file, global_name, .{ .id = gid, .ty = ctx_ty });
}

/// Create a thunk function: __thunk_ConcreteType_Protocol_method(ctx: *void, args...) -> ret
/// The thunk calls ConcreteType.method(ctx, args...).
pub fn createProtocolThunk(self: *Lowering, proto_ty: TypeId, proto_name: []const u8, concrete_type_name: []const u8, concrete_ty: TypeId, method: ProtocolMethodInfo) FuncId {
    // Build params: [__sx_ctx]? + ctx: *void + method params.
    // Thunks are sx-side functions, so they get the implicit __sx_ctx
    // at slot 0 when it's enabled program-wide. The concrete protocol
    // receiver (ctx) follows at slot 1; user method args at slot 2+.
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    defer params.deinit(self.alloc);
    const void_ptr = self.module.types.ptrTo(.void);
    const thunk_has_ctx = self.implicit_ctx_enabled;
    if (thunk_has_ctx) {
        params.append(self.alloc, .{ .name = self.module.types.internString("__sx_ctx"), .ty = void_ptr }) catch unreachable;
    }
    params.append(self.alloc, .{ .name = self.module.types.internString("ctx"), .ty = void_ptr }) catch unreachable;
    for (method.param_types, 0..) |pty, i| {
        var buf: [32]u8 = undefined;
        const pname = std.fmt.bufPrint(&buf, "a{d}", .{i}) catch "arg";
        params.append(self.alloc, .{ .name = self.module.types.internString(pname), .ty = pty }) catch unreachable;
    }

    // Generate a unique internal name. Same-display-name nominal structs need
    // distinct LLVM symbols just as they need distinct FuncIds and cache keys.
    const concrete_dispatch_name = protocolConcreteDispatchName(self, concrete_type_name, concrete_ty);
    const protocol_dispatch_name = protocolRuntimeDispatchName(self, proto_name, proto_ty);
    const thunk_name = std.fmt.allocPrint(self.alloc, "__thunk_{s}_{s}_{s}", .{ concrete_dispatch_name, protocol_dispatch_name, method.name }) catch @panic("out of memory");
    const thunk_name_id = self.module.types.internString(thunk_name);

    // Save builder state
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    const saved_ctx_ref_thunk = self.current_ctx_ref;
    defer self.current_ctx_ref = saved_ctx_ref_thunk;

    const owned_params = self.alloc.dupe(inst_mod.Function.Param, params.items) catch unreachable;
    var func = inst_mod.Function.init(thunk_name_id, owned_params, method.ret_type);
    func.has_implicit_ctx = thunk_has_ctx;
    const func_id = self.module.addFunction(func);
    self.builder.func = func_id;
    self.builder.inst_counter = @intCast(owned_params.len);
    if (thunk_has_ctx) self.current_ctx_ref = Ref.fromIndex(0);
    const entry_block = self.builder.appendBlock(self.module.types.internString("entry"), &.{});
    self.builder.switchToBlock(entry_block);

    // Ensure the exact protocol impl method is lowered. The explicit impl
    // registry is keyed by nominal TypeId; the display-name path remains only
    // for generic-struct instances, whose mangled names are already unique.
    const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ concrete_type_name, method.name }) catch @panic("out of memory");
    const identity_ty: ?TypeId = if (self.protocol_ast_by_type.contains(proto_ty)) proto_ty else null;
    const selected_impl = self.protocolResolver().protocolDispatchMethod(identity_ty, proto_name, concrete_ty, method.name);
    const selected_fid: ?FuncId = if (selected_impl) |impl_method|
        ensureProtocolImplMethodLowered(self, proto_ty, proto_name, concrete_type_name, impl_method)
    else if (self.genericInstanceMethod(concrete_type_name, method.name)) |gm| blk: {
        // A stamped generic-struct instance is the sole binding-aware textual
        // route: its author stamp and instance bindings prove which template
        // owns the method. Concrete parameterized-protocol impls must already
        // have matched `protocolDispatchMethod` by protocol-instance + TypeId;
        // consulting a flat `Type.method` name here would let a distinct
        // same-display-name nominal type borrow another type's impl.
        self.monomorphizeFunction(gm.fd, qualified, gm.bindings);
        break :blk self.resolveFuncByName(qualified);
    } else null;

    // Call the concrete method: ConcreteType.method(__sx_ctx?, ctx, args...).
    // The concrete method is itself an sx function that takes the
    // implicit __sx_ctx at slot 0 (when implicit_ctx is enabled); we
    // forward the thunk's own __sx_ctx.
    if (selected_fid) |concrete_fid| {
        const concrete_func = &self.module.functions.items[@intFromEnum(concrete_fid)];
        var call_args = std.ArrayList(Ref).empty;
        defer call_args.deinit(self.alloc);

        // Slot offsets inside the thunk: __sx_ctx at 0 (if present),
        // protocol receiver (ctx) at slot user_base, user args at +1, +2...
        const user_base: u32 = if (thunk_has_ctx) 1 else 0;

        // Forward our __sx_ctx to the concrete method's __sx_ctx slot.
        if (concrete_func.has_implicit_ctx) {
            call_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
        }

        // Pass ctx as the next arg (it's the concrete *Type disguised as *void).
        // If the concrete method expects a value (e.g., f32) not a pointer, load from ctx.
        const ctx_ref = Ref.fromIndex(user_base);
        const concrete_receiver_idx: usize = if (concrete_func.has_implicit_ctx) 1 else 0;
        if (concrete_receiver_idx < concrete_func.params.len) {
            const first_concrete_ty = concrete_func.params[concrete_receiver_idx].ty;
            const first_info = self.module.types.get(first_concrete_ty);
            if (first_info != .pointer) {
                // Concrete expects value — load from ctx pointer
                call_args.append(self.alloc, self.builder.load(ctx_ref, first_concrete_ty)) catch unreachable;
            } else {
                call_args.append(self.alloc, ctx_ref) catch unreachable;
            }
        } else {
            call_args.append(self.alloc, ctx_ref) catch unreachable;
        }
        for (method.param_types, 0..) |proto_pty, i| {
            var arg_ref = Ref.fromIndex(@intCast(user_base + 1 + i));
            // If protocol param is a pointer (Self→*void) but concrete method
            // expects a value type, load the value from the pointer.
            const concrete_idx = concrete_receiver_idx + 1 + i;
            if (concrete_idx < concrete_func.params.len) {
                const concrete_pty = concrete_func.params[concrete_idx].ty;
                const proto_info = self.module.types.get(proto_pty);
                const concrete_info = self.module.types.get(concrete_pty);
                if (proto_info == .pointer and concrete_info != .pointer) {
                    arg_ref = self.builder.load(arg_ref, concrete_pty);
                }
            }
            call_args.append(self.alloc, arg_ref) catch unreachable;
        }
        const owned_args = self.alloc.dupe(Ref, call_args.items) catch unreachable;
        const concrete_ret = concrete_func.ret;
        const result = self.builder.call(concrete_fid, owned_args, concrete_ret);
        if (method.ret_type != .void) {
            // If protocol returns *void (Self) but concrete returns a value type,
            // box the value: alloca+store and return the pointer
            const ret_info = self.module.types.get(method.ret_type);
            const concrete_ret_info = self.module.types.get(concrete_ret);
            if (ret_info == .pointer and concrete_ret_info != .pointer) {
                const slot = self.builder.alloca(concrete_ret);
                self.builder.store(slot, result);
                self.builder.ret(slot, method.ret_type);
            } else {
                self.builder.ret(result, method.ret_type);
            }
        } else {
            self.builder.retVoid();
        }
    } else {
        // Can't resolve concrete method — emit unreachable
        _ = self.builder.emit(.{ .@"unreachable" = {} }, .void);
    }
    self.builder.finalize();

    // Restore builder state
    self.builder.func = saved_func;
    self.builder.current_block = saved_block;
    self.builder.inst_counter = saved_counter;

    return func_id;
}

/// Return the exact protocol/concrete lookup domain owned by a synthesized
/// default declaration. Every concrete impl gets its own synthesized FnDecl,
/// so one declaration mapping to two domains would be an internal identity
/// violation rather than an ambiguity to resolve by name.
pub fn protocolDefaultDispatchDomain(self: *Lowering, fd: *const ast.FnDecl) ?ProtocolDefaultDispatchDomain {
    var selected: ?ProtocolDefaultDispatchDomain = null;
    var it = self.protocol_impl_methods.iterator();
    while (it.next()) |entry| {
        const impl_method = entry.value_ptr.*;
        if (impl_method.fd != fd or !impl_method.is_synthesized_default) continue;
        const candidate: ProtocolDefaultDispatchDomain = .{
            .protocol = entry.key_ptr.protocol,
            .protocol_name = entry.key_ptr.protocol_name,
            .concrete = entry.key_ptr.concrete,
        };
        if (selected) |prior| {
            if (prior.protocol != candidate.protocol or prior.protocol_name != candidate.protocol_name or prior.concrete != candidate.concrete)
                std.debug.panic("synthesized protocol default '{s}' belongs to multiple dispatch domains", .{fd.name});
        } else {
            selected = candidate;
        }
    }
    return selected;
}

fn protocolConcreteDispatchName(self: *Lowering, display_name: []const u8, concrete_ty: TypeId) []const u8 {
    if (concrete_ty.isBuiltin()) return display_name;
    const ti = self.module.types.get(concrete_ty);
    const nominal_id: u32 = switch (ti) {
        .@"struct" => |s| s.nominal_id,
        .@"enum" => |e| e.nominal_id,
        .@"union" => |u| u.nominal_id,
        .tagged_union => |u| u.nominal_id,
        .error_set => |e| e.nominal_id,
        else => 0,
    };
    if (nominal_id == 0) return display_name;
    return std.fmt.allocPrint(self.alloc, "{s}$nominal{d}", .{ display_name, nominal_id }) catch @panic("out of memory");
}

fn protocolRuntimeDispatchName(self: *Lowering, display_name: []const u8, proto_ty: TypeId) []const u8 {
    if (!self.protocol_ast_by_type.contains(proto_ty)) return display_name;
    const nominal_id = Lowering.nominalIdOf(self.module.types.get(proto_ty));
    if (nominal_id == 0) return display_name;
    return std.fmt.allocPrint(self.alloc, "{s}$nominal{d}", .{ display_name, nominal_id }) catch @panic("out of memory");
}

fn ensureProtocolImplMethodLowered(self: *Lowering, proto_ty: TypeId, proto_name: []const u8, concrete_type_name: []const u8, method: ProtocolImplMethod) FuncId {
    const fid = self.fn_decl_fids.get(method.fd) orelse
        std.debug.panic("protocol impl method '{s}.{s}' has no decl-identity function slot", .{ concrete_type_name, method.fd.name });
    if (!self.lowered_fids.contains(fid)) {
        self.lowered_fids.put(fid, {}) catch @panic("out of memory");
        const owner = protocolConcreteDispatchName(self, concrete_type_name, method.concrete);
        const protocol_owner = protocolRuntimeDispatchName(self, proto_name, proto_ty);
        const internal_name = std.fmt.allocPrint(self.alloc, "{s}$impl${s}.{s}", .{ owner, protocol_owner, self.accessorEffName(method.fd) }) catch @panic("out of memory");
        self.impl_method_names.put(internal_name, {}) catch @panic("out of memory");
        self.lowerFunctionBodyInto(method.fd, fid, internal_name);
    }
    return fid;
}

/// Why a concrete type fails to conform to a protocol method, named at the
/// specific method that fails. `kind` drives the diagnostic wording.
const NonConformance = struct {
    method: []const u8,
    kind: enum {
        /// No `impl`/struct-method body resolves for `<Type>.<method>` at all.
        missing,
        /// A body exists, but it introduces its OWN type params
        /// (`speak :: (self: *Dog, $T: Type)`). A protocol-method impl must
        /// match the protocol's signature exactly — it may not be generic over
        /// extra params. The thunk would call `lazyLowerFunction`, which bails
        /// on `fd.type_params.len > 0` (decl.zig: "generics handled by
        /// monomorphization"), leaving `resolveFuncByName` null → the thunk's
        /// `else => unreachable` arm fires at the first dispatch.
        signature_mismatch,
        /// A body exists with the right arity (after self), but a PARAMETER or
        /// the RETURN type differs from the protocol method's declared type
        /// (e.g. impl returns `bool` where the protocol method returns `i64`).
        /// The thunk would call the impl with the wrong ABI and silently
        /// miscompile. `detail` names the mismatching position.
        type_mismatch,
        /// A body exists but its arity (after self) differs from the protocol
        /// method's parameter count. `detail` carries the "expected N, got M"
        /// phrasing.
        arity_mismatch,
    },
    /// Populated for `.type_mismatch` / `.arity_mismatch`: a human-readable
    /// description of WHICH part mismatched (e.g. "return type: protocol
    /// declares 'i64', impl declares 'bool'"). Empty for the other kinds.
    detail: []const u8 = "",
};

/// First protocol method of `proto_name` for which `concrete_type_name` does
/// NOT conform, or null if the type fully conforms. Conformance is IMPL-DRIVEN
/// (specs.md §"Storage and protocol conformance": protocol erasure requires an
/// explicit `impl P for T { ... }`, not structural / free-function matching).
///
/// This gate is primarily about DIAGNOSTIC QUALITY: turn a no-impl erasure
/// (which would otherwise SIGABRT) into a clean, located error. (Note: every
/// non-parameterized impl method is also eagerly `declareFunction`-stubbed by
/// `ProtocolResolver.registerImplBlock`, so `resolveFuncByName` rarely returns
/// null in practice — but the gate must still reject pairs that don't truly
/// conform.) It rejects a method when:
///   1. `fn_ast_map["<Type>.<method>"]` is absent (no impl/struct-method body).
///   2. The matched FnDecl has `type_params.len > 0` — a protocol-method impl
///      may NOT introduce its own type parameters (`$T: Type`); that is a
///      SIGNATURE MISMATCH against the protocol method, AND such a method bails
///      out of `lazyLowerFunction` (decl.zig: `type_params.len > 0` → return),
///      so the thunk would resolve to the `.unreachable` arm.
/// A generic-STRUCT instance method (`impl P for Box($T)`) is fine: the struct's
/// type params are bound by the instance, not introduced by the method, and
/// `monomorphizeFunction` always registers it. Conformance is IMPL-DRIVEN, so a
/// type satisfying the method only via a free / `ufcs` function does NOT conform.
fn firstUnimplementedMethod(self: *Lowering, proto_ty: TypeId, concrete_type_name: []const u8, concrete_ty: TypeId) ?NonConformance {
    const pd = self.getProtocolInfo(proto_ty) orelse return null;
    const proto_name = pd.name;
    // AST of the protocol (carries each method's raw param/return type nodes +
    // the protocol's defining module). Absent for a materialized parameterized
    // instance, where its concrete impl identity is still mandatory but the
    // base declaration's raw signature is not available under this name.
    const pd_ast = self.protocol_ast_by_type.get(proto_ty);
    const identity_ty: ?TypeId = if (pd_ast != null) proto_ty else null;
    for (pd.methods) |m| {
        if (self.protocolResolver().protocolDispatchMethod(identity_ty, proto_name, concrete_ty, m.name)) |impl_method| {
            const fd = impl_method.fd;
            // A direct impl/struct-method body exists. It only conforms if the
            // thunk's `lazyLowerFunction(qualified)` would actually register it.
            // A method with its own type params bails there → unreachable thunk.
            if (fd.type_params.len > 0) return .{ .method = m.name, .kind = .signature_mismatch };
            // Validate the impl method's SIGNATURE against the protocol method
            // — a right-NAME but wrong-TYPE impl otherwise builds a wrong-ABI
            // thunk and silently miscompiles.
            if (pd_ast) |pda| {
                if (methodAst(pda, m.name)) |mast| {
                    if (signatureMismatch(self, mast, m, fd, concrete_ty, pda.source_file)) |nc| return nc;
                }
            }
            continue;
        }
        // Concrete parameterized-protocol impls are identity-registered and
        // must have matched above. The only valid lazy route is a generic
        // instance carrying a stamped template author plus concrete bindings;
        // a flat `<display-name>.<method>` lookup is never proof of conformance.
        if (self.genericInstanceMethod(concrete_type_name, m.name) != null) continue;
        return .{ .method = m.name, .kind = .missing };
    }
    return null;
}

/// The protocol method declaration node named `name`, or null.
fn methodAst(pd: *const ast.ProtocolDecl, name: []const u8) ?ast.ProtocolMethodDecl {
    for (pd.methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

/// True when `node` (a type-expr AST) names `Self` ANYWHERE — at the leaf or
/// nested inside any compound (`*Self`, `[]Self`, `[2]*Self`, `?[]Self`,
/// `Box(Self)`, fn/closure types, …). Used to decide whether a node needs
/// structural `Self`-substitution or can be resolved wholesale. Shared with
/// the erasability classifier.
const containsSelf = program_index_mod.typeNodeContainsSelf;

/// Resolve a protocol-method type node to a TypeId, substituting any `Self`
/// reference (at the leaf, or nested under ANY compound — pointer / many-pointer
/// / optional / slice / array, or a generic type-arg) with `concrete_ty` — the
/// type the protocol is being erased FOR. `proto_src` is the protocol's defining
/// module, so a type bare-visible only there still resolves (mirrors how
/// `registerProtocolDecl` builds `param_types`).
///
/// Recurses structurally so a nested `Self` (e.g. `[]Self`, `[2]*Self`,
/// `?[]Self`) is replaced at EVERY level before the type is rebuilt — without
/// this, `[]Self` would resolve to a real `.slice` named `[]Self` ≠ `[]T` and
/// the conformance gate would FALSELY reject a correct `[]T` impl.
pub fn resolveProtoTypeSubSelf(self: *Lowering, node: *const Node, concrete_ty: TypeId, proto_src: ?[]const u8) TypeId {
    switch (node.data) {
        .type_expr => |te| {
            if (std.mem.eql(u8, te.name, "Self")) return concrete_ty;
            return self.resolveTypeInSource(proto_src, node);
        },
        .pointer_type_expr => |pt| return self.module.types.ptrTo(resolveProtoTypeSubSelf(self, pt.pointee_type, concrete_ty, proto_src)),
        .many_pointer_type_expr => |mp| return self.module.types.manyPtrTo(resolveProtoTypeSubSelf(self, mp.element_type, concrete_ty, proto_src)),
        .optional_type_expr => |opt| return self.module.types.optionalOf(resolveProtoTypeSubSelf(self, opt.inner_type, concrete_ty, proto_src)),
        .slice_type_expr => |st| return self.module.types.sliceOf(resolveProtoTypeSubSelf(self, st.element_type, concrete_ty, proto_src)),
        .array_type_expr => |at| {
            const elem = resolveProtoTypeSubSelf(self, at.element_type, concrete_ty, proto_src);
            // Fold the dimension WITHOUT emitting a diagnostic on failure (unlike
            // `resolveArrayLen`, which is a hard error): a non-foldable dim here
            // just means we can't build the array type for the gate, so yield the
            // `.unresolved` sentinel — `typesClearlyDiffer` then treats it as
            // not-clearly-different (conservative, never a false positive).
            const dim = program_index_mod.foldDimU32(at.length, self, 0);
            if (dim != .ok) return .unresolved;
            return self.module.types.arrayOf(elem, dim.ok);
        },
        else => {
            // Generic type-arg nodes (`Box(Self)`) and any other compound: if it
            // mentions `Self` we can't rebuild the instance from substituted
            // TypeIds without re-running the template machinery, so resolve it
            // ONLY when it does NOT contain `Self` (the common case — a fully
            // concrete `Box(i64)` protocol type). When it DOES contain `Self`,
            // yield `.unresolved` so the gate stays conservative (a correct
            // `Box(T)` impl is NOT falsely flagged). A genuine generic-arg
            // mismatch through `Self` is then simply not caught here — acceptable:
            // the gate's job is to never produce a FALSE positive, and the
            // miscompiles it guards are leaf / pointer / slice / array shaped.
            if (containsSelf(node)) return .unresolved;
            return self.resolveTypeInSource(proto_src, node);
        },
    }
}

/// Compare the impl method's signature (params after the `self` receiver, plus
/// the return type) against the protocol method's declaration. Returns a
/// `NonConformance` on a CLEAR mismatch, else null.
///
/// Self-substitution: the protocol writes `*Self` / `Self`; the REQUIRED impl
/// form is `*T` / `T`. `resolveProtoTypeSubSelf` substitutes `Self → concrete`
/// before resolving, so a correct impl matches and is NOT flagged.
///
/// Comparison is by canonical TypeId. Structurally identical compound types are
/// interned to the same TypeId, while distinct nominal declarations deliberately
/// remain distinct even when they have the same display name. We only flag when
/// BOTH sides resolve to concrete, fully-known types and their identities differ
/// — conservative against false positives on any shape we cannot resolve.
///
/// Each side is source-pinned to its OWN defining module: the protocol side via
/// `resolveProtoTypeSubSelf(..., proto_src)`, the impl side via
/// `resolveTypeInSource(fd.body.source_file, ...)`. Pinning the impl side matters
/// because the impl's param/return type may name a module-local type that is
/// bare-visible only inside the impl's module (namespaced-only from the erasure
/// site). Resolving it in the erasure-site context would hit the `.not_visible`
/// arm of `resolveNominalLeaf` and emit a hard diagnostic instead of
/// resolving-and-comparing structurally.
fn signatureMismatch(self: *Lowering, mast: ast.ProtocolMethodDecl, m: ProtocolMethodInfo, fd: *const ast.FnDecl, concrete_ty: TypeId, proto_src: ?[]const u8) ?NonConformance {
    // The concrete VALUE type (strip a single pointer): `*Self` substitutes to
    // `*T`, so `Self` itself must substitute to the value `T`.
    const value_ty: TypeId = blk: {
        if (!concrete_ty.isBuiltin()) {
            const info = self.module.types.get(concrete_ty);
            if (info == .pointer) break :blk info.pointer.pointee;
        }
        break :blk concrete_ty;
    };

    // Impl params after the `self` receiver (params[0]).
    if (fd.params.len == 0) return null; // no receiver at all — leave other gates to handle.
    const impl_extra = fd.params[1..];

    // Arity (after self) must equal the protocol method's param count.
    if (impl_extra.len != m.param_types.len) {
        const detail = std.fmt.allocPrint(self.alloc, "expects {d} parameter{s} (after self), but the impl declares {d}", .{
            m.param_types.len, if (m.param_types.len == 1) "" else "s", impl_extra.len,
        }) catch "";
        return .{ .method = m.name, .kind = .arity_mismatch, .detail = detail };
    }

    // Per-parameter type check. Protocol types resolve in the protocol's own
    // module (`proto_src`) with `Self → value_ty`; impl types resolve in the
    // IMPL's own module (`fd.body.source_file`), so a module-local impl type
    // resolves where it's visible rather than at the erasure site.
    // Canonical TypeIds remain equal when the same type resolves through either
    // source, and remain distinct for separate same-display-name nominals.
    for (mast.params, impl_extra) |proto_pnode, impl_param| {
        const proto_pty = resolveProtoTypeSubSelf(self, proto_pnode, value_ty, proto_src);
        const impl_pty = self.resolveTypeInSource(fd.body.source_file, impl_param.type_expr);
        if (typesClearlyDiffer(self, proto_pty, impl_pty)) {
            const proto_name = self.formatTypeName(proto_pty);
            const impl_name = self.formatTypeName(impl_pty);
            const detail = std.fmt.allocPrint(self.alloc, "parameter '{s}': protocol declares '{s}', impl declares '{s}'{s}", .{
                impl_param.name,
                proto_name,
                impl_name,
                if (std.mem.eql(u8, proto_name, impl_name)) " (same spelling, distinct nominal declarations)" else "",
            }) catch "";
            return .{ .method = m.name, .kind = .type_mismatch, .detail = detail };
        }
    }

    // Return type check.
    const proto_ret: TypeId = if (mast.return_type) |rt| resolveProtoTypeSubSelf(self, rt, value_ty, proto_src) else .void;
    const impl_ret: TypeId = if (fd.return_type) |rt| self.resolveTypeInSource(fd.body.source_file, rt) else .void;
    if (typesClearlyDiffer(self, proto_ret, impl_ret)) {
        const proto_name = self.formatTypeName(proto_ret);
        const impl_name = self.formatTypeName(impl_ret);
        const detail = std.fmt.allocPrint(self.alloc, "return type: protocol declares '{s}', impl declares '{s}'{s}", .{
            proto_name,
            impl_name,
            if (std.mem.eql(u8, proto_name, impl_name)) " (same spelling, distinct nominal declarations)" else "",
        }) catch "";
        return .{ .method = m.name, .kind = .type_mismatch, .detail = detail };
    }

    return null;
}

/// True when `ty` is `.unresolved` OR wraps an `.unresolved` leaf at ANY depth
/// (`[]unresolved`, `?*unresolved`, `[2]unresolved`, …). The outer TypeId of a
/// compound built over an unresolved element is itself a real `.slice` /
/// `.array` / `.pointer`, so the bare `== .unresolved` check at the top level
/// would MISS it — this recursion is the belt-and-suspenders that keeps a
/// `Self`-derived nesting we couldn't fully substitute from ever producing a
/// false positive in the conformance gate.
fn typeContainsUnresolved(self: *Lowering, ty: TypeId) bool {
    if (ty == .unresolved) return true;
    if (ty.isBuiltin()) return false;
    return switch (self.module.types.get(ty)) {
        .pointer => |p| typeContainsUnresolved(self, p.pointee),
        .many_pointer => |p| typeContainsUnresolved(self, p.element),
        .slice => |s| typeContainsUnresolved(self, s.element),
        .array => |a| typeContainsUnresolved(self, a.element),
        .optional => |o| typeContainsUnresolved(self, o.child),
        else => false,
    };
}

/// True when both `a` and `b` resolve to concrete, fully-known types whose
/// canonical identities differ. Conservative: if EITHER side contains an unresolved
/// leaf at any depth (a type — or a nesting — we couldn't resolve / fully
/// substitute), returns false, so we never flag a shape outside our resolver's
/// reach. A REAL mismatch between two fully-resolved compounds (e.g. `[]i64` vs
/// `[]i32`) still has a distinct interned TypeId and IS caught.
pub fn typesClearlyDiffer(self: *Lowering, a: TypeId, b: TypeId) bool {
    if (typeContainsUnresolved(self, a) or typeContainsUnresolved(self, b)) return false;
    return a != b;
}

/// Refusal for a postfix ASSERTION with a PROTOCOL target on an `any`
/// receiver: an any's type tag is always the CONCRETE type of the boxed
/// value — never an erased protocol — so `av.(Sizable)` (and its soft /
/// failable forms) can never succeed. Diagnose at compile time instead of
/// shipping a defined-but-always-failing runtime check. `type_node` is the
/// assertion's target (an optional target's INNER type is checked too);
/// returns true when a diagnostic was emitted.
pub fn refuseProtocolAssertTargetOnAny(self: *Lowering, type_node: *const Node, span: ast.Span) bool {
    const inner = if (type_node.data == .optional_type_expr) type_node.data.optional_type_expr.inner_type else type_node;
    const tname: []const u8 = switch (inner.data) {
        .identifier => |id| id.name,
        .type_expr => |te| te.name,
        .call => |c| switch (c.callee.data) {
            .identifier => |id| id.name,
            .type_expr => |te| te.name,
            else => return false,
        },
        else => return false,
    };
    if (!self.program_index.protocol_decl_map.contains(tname) and
        !self.program_index.protocol_ast_map.contains(tname)) return false;
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "an 'any' value's type tag is always a concrete type — it never holds an erased '{s}', so this assertion can never succeed; assert the concrete type instead ('av.(T)') or switch on the tag ('match av {{ case T: … }}')", .{tname});
    }
    return true;
}

/// Allocate `size_ref` bytes through an ALLOCATOR VALUE — the `.(P, alloc)`
/// owning erasure's allocation. Goes through the ordinary method dispatch,
/// so the allocator protocol's kind stays a property of its declaration.
pub fn allocViaAllocatorValue(self: *Lowering, allocator: Ref, size_ref: Ref) Ref {
    const alloc_ty = self.builder.getRefType(allocator);
    const pd = self.getProtocolInfo(alloc_ty) orelse return self.emitError("allocator", null);
    const cs = self.builder.current_span;
    return emitProtocolDispatch(self, allocator, pd, "alloc_bytes", &.{size_ref}, .{ .start = cs.start, .end = cs.end });
}

/// Postfix OWNING erasure `expr.(P, alloc)` — the ownership model's only
/// allocating spelling (P values own their ctx). Receiver shapes:
///   - concrete VALUE (lvalue or rvalue — both copy): heap-copy the data;
///   - `*Concrete`: SNAPSHOT — heap-copy the pointee;
///   - `P` (same protocol, value): CLONE — an independent copy of the
///     receiver's ctx (rt_size_of(type_id) bytes; vtable / fn words
///     reused — well-typed by construction);
///   - `*P` (same protocol): PROMOTION — the same, over the pointee;
///   - `#identity` target: `.(P)` is the borrow; `.(P, alloc)` refuses
///     (a borrow allocates nothing).
/// `.(P)` funds from `context.allocator`; `.(P, alloc)` names another.
/// The named allocator must be an LVALUE. `#identity` is a borrow and
/// refuses an allocator argument.
pub fn lowerOwningErasure(self: *Lowering, pc: *const ast.PostfixCast, dst_ty: TypeId, span: ast.Span) Ref {
    if (self.refuseValuelessProtocol(dst_ty, span, "make a value of")) return self.builder.constUndef(dst_ty);
    const dst_pi = self.getProtocolInfo(dst_ty) orelse return self.builder.constUndef(dst_ty);
    const void_ptr_ty = self.module.types.ptrTo(.void);

    if (dst_pi.ownership == .identity) {
        if (pc.alloc_arg != null) {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "'.({s}, alloc)' on an '#identity' protocol — identity erasure is a borrow and allocates nothing; write '.({s})'", .{ dst_pi.name, dst_pi.name });
            return self.builder.constUndef(dst_ty);
        }
        const operand = self.lowerExpr(pc.operand);
        return self.buildProtocolErasure(operand, pc.operand, self.builder.getRefType(operand), dst_ty);
    }

    const alloc_ty = self.module.types.findByName(self.module.types.internString("Allocator")) orelse {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'.(P)' needs the 'Allocator' protocol in scope — #import \"modules/std.sx\"", .{});
        return self.builder.constUndef(dst_ty);
    };
    const alloc_val = if (pc.alloc_arg) |an| blk: {
        if (!self.isLvalueExpr(an)) {
            if (self.diagnostics) |d|
                d.addFmt(.err, an.span, "the allocator argument of an owning erasure must be an LVALUE naming an allocator — bind it first (the value must outlive the erasure so `free(p, a)` can pair with it)", .{});
            return self.builder.constUndef(dst_ty);
        }
        const av = self.lowerExpr(an);
        const avt = self.builder.getRefType(av);
        break :blk if (avt == alloc_ty) av else self.coerceOrErase(av, avt, alloc_ty, an);
    } else self.ambientAllocator() orelse {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'.({s})' funds from context.allocator — import std or write '.({s}, <alloc>)'", .{ dst_pi.name, dst_pi.name });
        return self.builder.constUndef(dst_ty);
    };

    const operand = self.lowerExpr(pc.operand);
    const src_ty = self.builder.getRefType(operand);

    if (!src_ty.isBuiltin()) {
        const si = self.module.types.get(src_ty);
        // CLONE (`p.(P, alloc)`, same-protocol value) and PROMOTION
        // (`pv.(P, alloc)`, `*P`) share one body: the receiver protocol
        // value with its ctx replaced by a fresh heap copy of
        // rt_size_of(type_id) bytes; vtable / fn words reused.
        const proto_recv: ?Ref = if (src_ty == dst_ty)
            operand
        else if (si == .pointer and si.pointer.pointee == dst_ty)
            self.builder.load(operand, dst_ty)
        else
            null;
        if (proto_recv) |pv| {
            const old_ctx = self.builder.structGet(pv, 0, void_ptr_ty);
            const tid = self.builder.structGet(pv, 1, .type_value);
            const sz_args = self.alloc.dupe(Ref, &.{tid}) catch unreachable;
            const size_ref = self.builder.callBuiltin(.rt_size_of, sz_args, .i64);
            const heap = allocViaAllocatorValue(self, alloc_val, size_ref);
            _ = self.callExtern("memcpy", &.{ heap, old_ctx, size_ref }, void_ptr_ty);
            const dfields = self.module.types.get(dst_ty).@"struct".fields;
            var out = std.ArrayList(Ref).empty;
            defer out.deinit(self.alloc);
            out.append(self.alloc, heap) catch unreachable;
            for (dfields[1..], 1..) |f, i| {
                out.append(self.alloc, self.builder.structGet(pv, @intCast(i), f.ty)) catch unreachable;
            }
            const owned = self.alloc.dupe(Ref, out.items) catch unreachable;
            return self.builder.emit(.{ .struct_init = .{ .fields = owned } }, dst_ty);
        }
        if (si == .pointer) {
            const pointee = si.pointer.pointee;
            if (self.getProtocolInfo(pointee) != null) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, span, "cannot promote a '*{s}' view to owned '{s}' — promotion requires the same protocol", .{ self.formatTypeName(pointee), dst_pi.name });
                return self.builder.constUndef(dst_ty);
            }
            // SNAPSHOT: *Concrete → owned P (heap-copy the pointee).
            const ctn = self.resolveConcreteTypeName(pointee) orelse {
                if (self.diagnostics) |d|
                    d.addFmt(.err, span, "cannot erase a value of type '{s}' to protocol '{s}'", .{ self.formatTypeName(src_ty), dst_pi.name });
                return self.builder.constUndef(dst_ty);
            };
            const psize: i64 = @intCast(self.module.types.typeSizeBytes(pointee));
            const size_ref = self.builder.constInt(psize, .i64);
            const heap = allocViaAllocatorValue(self, alloc_val, size_ref);
            _ = self.callExtern("memcpy", &.{ heap, operand, size_ref }, void_ptr_ty);
            return self.buildProtocolValue(heap, dst_pi.name, ctn, dst_ty, pointee);
        }
    }

    // Concrete VALUE receiver — lvalue and rvalue alike OWN-COPY.
    const ctn = self.resolveConcreteTypeName(src_ty) orelse {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "cannot erase a value of type '{s}' to protocol '{s}'", .{ self.formatTypeName(src_ty), dst_pi.name });
        return self.builder.constUndef(dst_ty);
    };
    const slot = self.builder.alloca(src_ty);
    self.builder.store(slot, operand);
    const vsize: i64 = @intCast(self.module.types.typeSizeBytes(src_ty));
    const size_ref = self.builder.constInt(vsize, .i64);
    const heap = allocViaAllocatorValue(self, alloc_val, size_ref);
    _ = self.callExtern("memcpy", &.{ heap, slot, size_ref }, void_ptr_ty);
    return self.buildProtocolValue(heap, dst_pi.name, ctn, dst_ty, src_ty);
}

/// Number of Era-2 dispatchable methods — the slot count of the protocol's
/// vtable fn-ptr fields and of its thunk list.
pub fn dispatchableCount(methods: []const ProtocolMethodInfo) usize {
    var n: usize = 0;
    for (methods) |m| {
        if (m.dispatchable) n += 1;
    }
    return n;
}

/// Build a protocol value over `concrete_ptr` as its ctx:
/// struct_init { ctx, __type_id, &vtable }.
/// The pointer is used directly — the caller owns the pointee's lifetime;
/// any owning heap copy is made BEFORE this call (`lowerOwningErasure`).
pub fn buildProtocolValue(self: *Lowering, concrete_ptr: Ref, proto_name: []const u8, concrete_type_name: []const u8, proto_ty: TypeId, concrete_ty: TypeId) Ref {
    const pd = self.getProtocolInfo(proto_ty) orelse return concrete_ptr;

    // Neither polarity of the multiplicity read is publishable while an
    // undecided driver could still write another `impl` into this protocol.
    if (implFactWaits(self, proto_ty, pd.name, concrete_ty, true))
        return self.builder.emit(.{ .placeholder = self.module.types.internString("erasure-await") }, proto_ty);

    if (refuseNonConformer(self, proto_ty, concrete_type_name, concrete_ty, null)) {
        // Return a placeholder TYPED AS THE PROTOCOL so a downstream coercion
        // doesn't re-attempt erasure (and re-report) on a mistyped result. The
        // build already has `hasErrors()`, so the placeholder never ships.
        return self.builder.emit(.{ .placeholder = self.module.types.internString("protocol-erasure") }, proto_ty);
    }

    const thunks = self.getOrCreateThunks(proto_ty, concrete_type_name, concrete_ty);
    if (thunks.len != dispatchableCount(pd.methods)) return concrete_ptr;

    return buildErasedValue(self, concrete_ptr, proto_name, concrete_type_name, proto_ty, concrete_ty, thunks);
}

/// The soft probe `x.(?P)` on a CONCRETE receiver (§7.9): under `?`, a
/// protocol target on a concrete value asks site-local impl visibility instead
/// of converting, so a non-conformer answers `null` where the erasure would
/// error. Returns null when the site is not a probe ANSWER: the pair conforms,
/// and the ordinary soft erasure lowers it.
pub fn lowerProtocolProbe(self: *Lowering, pc: *const ast.PostfixCast, proto_ty: TypeId, dst_ty: TypeId) ?Ref {
    // A constraint protocol has no values at all, which is a different fact
    // from this type not conforming — leave it to the valueless refusal.
    if (valuelessProtocolIn(self, proto_ty) != null) return null;
    const recv_ty = self.inferExprType(pc.operand);
    if (recv_ty == .unresolved or recv_ty == .void) return null;
    const concrete_ty = if (recv_ty.isBuiltin()) recv_ty else switch (self.module.types.get(recv_ty)) {
        .pointer => |p| p.pointee,
        else => recv_ty,
    };
    const cname = self.resolveConcreteTypeName(concrete_ty) orelse return null;
    if (firstUnimplementedMethod(self, proto_ty, cname, concrete_ty) == null) return null;
    if (self.getProtocolInfo(proto_ty)) |pi| _ = implFactWaits(self, proto_ty, pi.name, concrete_ty, false);
    return self.builder.constNull(dst_ty);
}

/// The storage the probe's answer would borrow. A pointer receiver IS the
/// address; an lvalue borrows the storage its value was read through; an
/// rvalue gets a frame temporary.
fn probeReceiverAddress(self: *Lowering, node: *const ast.Node, recv_ty: TypeId) ?Ref {
    if (recv_ty == .void) return null;
    if (!recv_ty.isBuiltin() and self.module.types.get(recv_ty) == .pointer) return self.lowerExpr(node);
    const val = self.lowerExpr(node);
    if (self.isLvalueExpr(node)) {
        if (self.refStorageAddress(val)) |addr| return addr;
    }
    const slot = self.builder.alloca(recv_ty);
    self.builder.store(slot, val);
    return slot;
}

/// The conformance gate shared by every erasure spelling: a concrete type may
/// only become a protocol value of a protocol it actually `impl`-ements.
/// Without it, thunk synthesis falls through to `unreachable` — a silent
/// SIGABRT at the first dispatch with no diagnostic. `at`
/// defaults to the builder's current span.
pub fn refuseNonConformer(self: *Lowering, proto_ty: TypeId, concrete_type_name: []const u8, concrete_ty: TypeId, at: ?ast.Span) bool {
    const proto_name = self.getProtocolInfo(proto_ty).?.name;
    const span = at orelse blk: {
        const cs = self.builder.current_span;
        break :blk ast.Span{ .start = cs.start, .end = cs.end };
    };
    if (firstUnimplementedMethod(self, proto_ty, concrete_type_name, concrete_ty)) |nc| {
        if (self.diagnostics) |d| {
            switch (nc.kind) {
                .missing => d.addFmt(.err, span, "'{s}' does not implement protocol '{s}': no `impl {s} for {s}` provides method '{s}' (protocol erasure is impl-driven — a plain or `ufcs` free function with a matching receiver does not satisfy a protocol)", .{ concrete_type_name, proto_name, proto_name, concrete_type_name, nc.method }),
                .signature_mismatch => d.addFmt(.err, span, "'{s}' does not implement protocol '{s}': method '{s}' has a mismatched signature — a protocol-method impl must not introduce its own type parameters (e.g. `$T: Type`); it must match the protocol's signature exactly", .{ concrete_type_name, proto_name, nc.method }),
                .type_mismatch => d.addFmt(.err, span, "'{s}' does not implement protocol '{s}': method '{s}' has a mismatched signature — {s} (a protocol-method impl must match the protocol's declared types exactly, with `Self` written as `{s}`)", .{ concrete_type_name, proto_name, nc.method, nc.detail, concrete_type_name }),
                .arity_mismatch => d.addFmt(.err, span, "'{s}' does not implement protocol '{s}': method '{s}' {s}", .{ concrete_type_name, proto_name, nc.method, nc.detail }),
            }
        } else {
            // Gap 2 — no diagnostics channel (e.g. a comptime sub-lowering that
            // never set `self.diagnostics`). Emitting the placeholder here would
            // ship LLVM `undef` with `hasErrors() == false`: a non-conforming
            // erasure reaching codegen silently. That is a compiler-invariant
            // violation, so trip loudly per the hard tripwire rule
            // rather than fall through to the placeholder. The normal
            // compilation path always sets `diagnostics`, so this never fires
            // there — it only catches a future caller that forgets to plumb one.
            std.debug.panic("protocol-erasure conformance failure with no diagnostics channel: '{s}' does not implement '{s}' (method '{s}'); cannot surface to the user — refusing to ship undef", .{ concrete_type_name, proto_name, nc.method });
        }
        return true;
    }
    return false;
}

fn buildErasedValue(self: *Lowering, ctx_ptr: Ref, proto_name: []const u8, concrete_type_name: []const u8, proto_ty: TypeId, concrete_ty: TypeId, thunks: []const FuncId) Ref {
    // RTTI: the concrete type's id, stamped at erasure (slot 1). This is what
    // the downcast / protocol type switch read.
    const type_id_ref = self.builder.constType(concrete_ty);

    const vtable_ty = self.protocol_vtable_type_by_type.get(proto_ty) orelse return ctx_ptr;
    const vtable_global_id = getOrCreateVtableGlobal(self, proto_ty, proto_name, concrete_type_name, concrete_ty, thunks) orelse return ctx_ptr;

    // Reference the vtable global's address
    const vtable_ptr_ty = self.module.types.ptrTo(vtable_ty);
    const vtable_addr = self.builder.emit(.{ .global_addr = vtable_global_id }, vtable_ptr_ty);

    // Build protocol struct: { ctx, __type_id, &vtable }
    var proto_fields = std.ArrayList(Ref).empty;
    defer proto_fields.deinit(self.alloc);
    proto_fields.append(self.alloc, ctx_ptr) catch unreachable;
    proto_fields.append(self.alloc, type_id_ref) catch unreachable;
    proto_fields.append(self.alloc, vtable_addr) catch unreachable;
    const proto_owned = self.alloc.dupe(Ref, proto_fields.items) catch unreachable;
    return self.builder.emit(.{ .struct_init = .{ .fields = proto_owned } }, proto_ty);
}

/// Emit protocol method dispatch for a protocol-typed receiver.
/// Returns the call result ref.
pub fn emitProtocolDispatch(self: *Lowering, receiver: Ref, proto_info: ProtocolDeclInfo, method_name: []const u8, args: []const Ref, span: ast.Span) Ref {
    // Find the method and its slot among the DISPATCHABLE methods only — the
    // vtable carries no slot for an excluded method (Era-2), so the slot index
    // counts dispatchable predecessors, not decl order.
    var method_info: ?ProtocolMethodInfo = null;
    var midx: usize = 0;
    for (proto_info.methods) |m| {
        if (std.mem.eql(u8, m.name, method_name)) {
            method_info = m;
            break;
        }
        if (m.dispatchable) midx += 1;
    }
    const mi = method_info orelse return self.emitError(method_name, null);

    // Era-2 availability: a method whose signature mentions `Self` past the
    // receiver has no expressible type at an erased call site — it has no
    // slot, and calling it through P / *P is a compile error pointing at
    // the generic-bound path (where Self IS known, as the bound `T`).
    if (!mi.dispatchable) {
        if (self.diagnostics) |d| {
            if (mi.self_param) |pname| {
                d.addFmt(.err, span, "'{s}' is unavailable on an erased '{s}' value — its parameter '{s}: Self' has no expressible type here ('Self' denotes no type through erasure); call it through a generic bound instead: `f :: (a: $T/{s}, b: T) {{ a.{s}(b); }}`", .{ method_name, proto_info.name, pname, proto_info.name, method_name });
            } else {
                d.addFmt(.err, span, "'{s}' is unavailable on an erased '{s}' value — its return type mentions 'Self', which has no expressible type here ('Self' denotes no type through erasure); call it through a generic bound instead: `f :: (a: $T/{s}) -> T {{ a.{s}() }}`", .{ method_name, proto_info.name, proto_info.name, method_name });
            }
        }
        return Ref.none;
    }

    // Arity is exact: a protocol signature has no defaults, packs, or
    // variadics, so the user-arg count must equal its parameter list
    // — an extra arg would be dropped and a missing one would leave the
    // thunk reading garbage.
    if (args.len != mi.param_types.len) {
        if (self.diagnostics) |d| {
            const s: []const u8 = if (mi.param_types.len == 1) "" else "s";
            const got_verb: []const u8 = if (args.len == 1) "was" else "were";
            d.addFmt(.err, span, "'{s}' expects {d} argument{s}, but {d} {s} given", .{ method_name, mi.param_types.len, s, args.len, got_verb });
        }
        return Ref.none;
    }

    // Extract ctx from protocol struct (field 0)
    const void_ptr = self.module.types.ptrTo(.void);
    const ctx = self.builder.structGet(receiver, 0, void_ptr);

    // Extract fn_ptr: load the vtable struct, take the slot at method_idx
    const vtable_ptr = self.builder.structGet(receiver, 2, void_ptr);
    const vtable_ty = self.protocol_vtable_type_map.get(proto_info.name) orelse return self.emitError("vtable", null);
    const vtable = self.builder.emit(.{ .deref = .{ .operand = vtable_ptr } }, vtable_ty);
    const fn_ptr = self.builder.structGet(vtable, @intCast(midx), void_ptr);

    // Build call args: [__sx_ctx]? + receiver_ctx + user args.
    // Protocol thunks are sx-side, so they carry the implicit __sx_ctx
    // at slot 0 when the program uses Context — forward our caller's
    // ctx so the thunk's body (and the concrete method it forwards to)
    // sees the same Context as the dispatching code.
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (self.implicit_ctx_enabled) {
        call_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
    }
    call_args.append(self.alloc, ctx) catch unreachable;
    for (args, 0..) |a, i| {
        const expected_ty = if (i < mi.param_types.len) mi.param_types[i] else void_ptr;
        const arg_ty = self.builder.getRefType(a);

        // Untargeted `null` lowers as const_null with type .void. Re-emit it
        // as a null of the expected pointer type instead of alloca'ing void.
        if (arg_ty == .void and expected_ty == void_ptr) {
            call_args.append(self.alloc, self.builder.constNull(void_ptr)) catch unreachable;
            continue;
        }
        // A protocol method that expects `*void` accepts any single-pointer
        // value directly (`*T`, `[*]T`, `cstring`). Only wrap non-pointer
        // values in an alloca-slot — wrapping a pointer would pass the stack
        // slot's address instead of the actual pointer, and the callee would
        // read 8 bytes of pointer plus garbage from beyond the stack.
        const is_pointer_ty = switch (self.module.types.get(arg_ty)) {
            .pointer, .many_pointer, .cstring => true,
            else => false,
        };
        if (expected_ty == void_ptr and arg_ty != void_ptr and !is_pointer_ty) {
            const slot = self.builder.alloca(arg_ty);
            self.builder.store(slot, a);
            call_args.append(self.alloc, slot) catch unreachable;
        } else {
            // Coerce to match declared parameter type (critical for WASM strict signatures)
            const coerced = self.coerceToType(a, arg_ty, expected_ty);
            call_args.append(self.alloc, coerced) catch unreachable;
        }
    }
    const owned = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    return self.builder.emit(.{ .call_indirect = .{ .callee = fn_ptr, .args = owned } }, mi.ret_type);
}

/// Resolve the concrete type name for protocol erasure.
/// Handles both direct types and pointer-to-types.
pub fn resolveConcreteTypeName(self: *Lowering, ty: TypeId) ?[]const u8 {
    if (ty.isBuiltin()) {
        // Primitive types like i64 — check if they have toName()
        return self.module.types.typeName(ty);
    }
    const info = self.module.types.get(ty);
    if (info == .pointer) {
        // *ConcreteType → resolve pointee
        const pointee = info.pointer.pointee;
        if (pointee.isBuiltin()) return self.module.types.typeName(pointee);
        const pi = self.module.types.get(pointee);
        if (pi == .@"struct") return self.module.types.getString(pi.@"struct".name);
        return null;
    }
    if (info == .@"struct") return self.module.types.getString(info.@"struct".name);
    return null;
}
