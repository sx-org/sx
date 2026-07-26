//! The `tagged` protocol runtime core.
//!
//! A tagged value is `{ctx: *void, __tag: i64}` — 16 bytes, always a borrow.
//! Membership is whole-program: the conformer set of a tagged protocol is
//! collected by a fixpoint over the monomorphized program, then numbered in a
//! deterministic canonical order. Because a conformer admitted late can
//! renumber the whole space, no erasure or downcast site may bake a literal:
//! they emit `tagged_tag_of`, and `convergeTaggedSets` rewrites every
//! occurrence once the fixpoint has converged.
//!
//! Emission at convergence produces, per reached protocol:
//!   - `__sx_tags_<P>_type_ids` — the tag → concrete `Type` table, which the
//!     `ProtocolRaw` view and the `any` bridge read;
//!   - `__sx_tags_<P>_<method>` — one outlined dispatch routine per
//!     dispatchable method, a total switch over the tag whose arms are direct
//!     calls. A single-member set folds to the direct call with no switch.

const std = @import("std");
const ast = @import("../../ast.zig");
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const lower = @import("../lower.zig");
const program_index_mod = @import("../program_index.zig");

const Lowering = lower.Lowering;
const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const GlobalId = inst_mod.GlobalId;
const ProtocolDeclInfo = program_index_mod.ProtocolDeclInfo;
const ProtocolMethodInfo = program_index_mod.ProtocolMethodInfo;

pub const PairKey = struct {
    proto: TypeId,
    concrete: TypeId,
};

pub const MethodKey = struct {
    proto: TypeId,
    method: types.StringId,
};

pub const ImplSite = struct {
    span: ast.Span,
    source: ?[]const u8,
};

/// Record one declared `impl P for T` site of a tagged pair. Every site is
/// kept, including ones ordinary import-scoped coherence would let stand:
/// tagged sets are whole-program, so two impls of one pair leave the switch
/// arm ambiguous no matter who can see what.
pub fn recordImplSite(self: *Lowering, proto: TypeId, concrete: TypeId, span: ast.Span, source: ?[]const u8) void {
    if (!isTagged(self, proto)) return;
    const gop = self.tagged_impl_sites.getOrPut(.{ .proto = proto, .concrete = concrete }) catch @panic("out of memory");
    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(ImplSite).empty;
    for (gop.value_ptr.items) |s| if (s.span.start == span.start and s.span.end == span.end) return;
    gop.value_ptr.append(self.alloc, .{ .span = span, .source = source }) catch @panic("out of memory");
}

/// Global coherence (spec §3, §6.6): a duplicate `(tagged P, T)` pair is an
/// error, diagnosed once the instantiation is reached and naming both impl
/// sites. An unreached collision is not diagnosed — nothing exists to collide
/// at.
fn checkCoherence(self: *Lowering) void {
    checkParamCoherence(self);
    const d = self.diagnostics orelse return;
    var it = self.tagged_impl_sites.iterator();
    while (it.next()) |entry| {
        const sites = entry.value_ptr.items;
        if (sites.len < 2) continue;
        if (!self.tagged_reached.contains(entry.key_ptr.proto)) continue;
        const saved = d.current_source_file;
        defer d.current_source_file = saved;
        if (sites[0].source) |src| d.current_source_file = src;
        const id = d.addFmtId(.err, sites[0].span, "duplicate impl of tagged protocol '{s}' for '{s}' — a tagged conformer set is whole-program, so its coherence is global: exactly one impl of a pair may exist, whatever the import visibility", .{ self.formatTypeName(entry.key_ptr.proto), self.formatTypeName(entry.key_ptr.concrete) });
        for (sites[1..]) |s| {
            if (s.source) |src| d.current_source_file = src;
            d.addNoteFmt(id, s.span, "also implemented here", .{});
        }
    }
}

/// The same global coherence, per instantiation: two impls of one
/// `(instantiation, conformer)` pair leave the switch arm ambiguous however
/// visibility is arranged. Registration already refuses a same-module
/// duplicate; this is the cross-module half, and it fires only for a reached
/// instantiation.
fn checkParamCoherence(self: *Lowering) void {
    const d = self.diagnostics orelse return;
    var rit = self.tagged_reached.keyIterator();
    while (rit.next()) |p| {
        const inst = self.param_protocol_instances.get(p.*) orelse continue;
        var it = self.param_impl_map.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (key.len <= inst.base.len) continue;
            if (!std.mem.startsWith(u8, key, inst.base) or key[inst.base.len] != 0) continue;
            const entries = e.value_ptr.items;
            if (entries.len < 2) continue;
            var found = std.ArrayList(TypeId).empty;
            defer found.deinit(self.alloc);
            collectFromImpl(self, inst, entries[0], &found);
            if (found.items.len == 0) continue;
            const Ctx = struct {
                l: *Lowering,
                fn lt(ctx: @This(), a: TypeId, b: TypeId) bool {
                    return std.mem.order(u8, ctx.l.mangleTypeName(a), ctx.l.mangleTypeName(b)) == .lt;
                }
            };
            std.mem.sort(TypeId, found.items, Ctx{ .l = self }, Ctx.lt);
            const saved = d.current_source_file;
            defer d.current_source_file = saved;
            d.current_source_file = entries[0].defining_module;
            const id = d.addFmtId(.err, entries[0].span, "duplicate impl of tagged protocol '{s}' for '{s}' — a tagged conformer set is whole-program, so its coherence is global: exactly one impl of a pair may exist, whatever the import visibility", .{ self.formatTypeName(p.*), self.formatTypeName(found.items[0]) });
            for (entries[1..]) |other| {
                d.current_source_file = other.defining_module;
                d.addNoteFmt(id, other.span, "also implemented here", .{});
            }
        }
    }
}

/// Is `ty` a tagged protocol type?
pub fn isTagged(self: *Lowering, ty: TypeId) bool {
    const pd = self.getProtocolInfo(ty) orelse return false;
    return pd.kind == .tagged;
}

/// The tagged protocol reached through `ty`'s composite spine (`*P`, `?P`,
/// `[]P`, `[N]P`), or null.
pub fn taggedIn(self: *Lowering, ty: TypeId) ?TypeId {
    if (ty.isBuiltin() or ty == .unresolved) return null;
    return switch (self.module.types.get(ty)) {
        .pointer => |p| taggedIn(self, p.pointee),
        .many_pointer => |p| taggedIn(self, p.element),
        .optional => |o| taggedIn(self, o.child),
        .slice => |s| taggedIn(self, s.element),
        .array => |a| taggedIn(self, a.element),
        .@"struct" => |s| if (s.is_protocol and isTagged(self, ty)) ty else null,
        else => null,
    };
}

// ── Membership ──────────────────────────────────────────────────────────

/// Record that `proto` is VALUE-USED — an erasure site, a protocol-typed
/// field / parameter / return / element declaration, a dispatch, a downcast.
/// Only reached instantiations materialize tables (spec §6.6).
pub fn reachTagged(self: *Lowering, proto: TypeId) void {
    if (!isTagged(self, proto)) return;
    self.tagged_reached.put(proto, {}) catch @panic("out of memory");
}

/// Admit `concrete` into `proto`'s conformer set. Returns true when this call
/// grew the set.
fn admit(self: *Lowering, proto: TypeId, concrete: TypeId) bool {
    const gop = self.tagged_members.getOrPut(proto) catch @panic("out of memory");
    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(TypeId).empty;
    for (gop.value_ptr.items) |m| if (m == concrete) return false;
    gop.value_ptr.append(self.alloc, concrete) catch @panic("out of memory");
    reachMentionedInstantiations(self, concrete);
    return true;
}

/// A conformer's fields may hold values of other instantiations — the
/// `Scaled(T)` shape holds a `Series(T)` handle. Admitting it reaches those
/// instantiations, so their sets and tables materialize too (spec §6.5).
fn reachMentionedInstantiations(self: *Lowering, concrete: TypeId) void {
    if (concrete.isBuiltin() or concrete == .unresolved) return;
    const info = self.module.types.get(concrete);
    if (info != .@"struct") return;
    for (info.@"struct".fields) |f| {
        if (taggedIn(self, f.ty)) |p| reachTagged(self, p);
    }
}

/// The declared conformers of tagged `proto`: every concrete type with an
/// `impl P for T` anywhere in the program's import closure. Presence-based,
/// not path-based (spec §6) — no import path from a use site to the impl is
/// required.
fn admitDeclaredImpls(self: *Lowering, proto: TypeId) bool {
    var changed = false;
    if (isInstantiation(self, proto)) {
        var found = std.ArrayList(TypeId).empty;
        defer found.deinit(self.alloc);
        collectParamConformers(self, proto, &found);
        for (found.items) |c| {
            if (admit(self, proto, c)) changed = true;
        }
        return changed;
    }
    var it = self.protocol_impl_decls.keyIterator();
    while (it.next()) |key| {
        if (key.protocol != proto) continue;
        if (admit(self, proto, key.concrete)) changed = true;
    }
    return changed;
}

/// Whether `concrete` is a member of tagged `proto`'s set. Membership only
/// grows, so a positive answer is stable the moment it exists; the declared
/// impls are all registered before any body lowers, which is what makes the
/// sema-time membership diagnostics exact.
fn conforms(self: *Lowering, proto: TypeId, concrete: TypeId) bool {
    if (self.tagged_members.get(proto)) |list| {
        for (list.items) |m| if (m == concrete) return true;
    }
    if (isInstantiation(self, proto)) {
        var found = std.ArrayList(TypeId).empty;
        defer found.deinit(self.alloc);
        collectParamConformers(self, proto, &found);
        for (found.items) |c| if (c == concrete) return true;
        return false;
    }
    var it = self.protocol_impl_decls.keyIterator();
    while (it.next()) |key| {
        if (key.protocol == proto and key.concrete == concrete) return true;
    }
    return false;
}

/// Does anything at all implement `proto`? For a parameterized family this is
/// asked of ONE instantiation: another tuple's impls are another set (§6.7).
fn hasAnyConformer(self: *Lowering, proto: TypeId) bool {
    if (self.tagged_members.get(proto)) |list| {
        if (list.items.len != 0) return true;
    }
    if (isInstantiation(self, proto)) return countParamConformers(self, proto) != 0;
    var it = self.protocol_impl_decls.keyIterator();
    while (it.next()) |key| if (key.protocol == proto) return true;
    return false;
}

// ── Per-instantiation membership ────────────────────────────────────────

/// Is `proto` one instantiation of a parameterized family?
fn isInstantiation(self: *Lowering, proto: TypeId) bool {
    return self.param_protocol_instances.contains(proto);
}

fn countParamConformers(self: *Lowering, proto: TypeId) usize {
    var found = std.ArrayList(TypeId).empty;
    defer found.deinit(self.alloc);
    collectParamConformers(self, proto, &found);
    return found.items.len;
}

fn appendUnique(self: *Lowering, out: *std.ArrayList(TypeId), ty: TypeId) void {
    if (ty == .unresolved) return;
    for (out.items) |t| if (t == ty) return;
    out.append(self.alloc, ty) catch @panic("out of memory");
}

/// Every conformer of instantiation `proto`. A concrete impl contributes its
/// source when the canonical argument tuples match; a blanket impl contributes
/// one member per INSTANTIATED type its source shape unifies with — never an
/// open-ended family (spec §6.5).
fn collectParamConformers(self: *Lowering, proto: TypeId, out: *std.ArrayList(TypeId)) void {
    const inst = self.param_protocol_instances.get(proto) orelse return;
    var it = self.param_impl_map.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (key.len <= inst.base.len) continue;
        if (!std.mem.startsWith(u8, key, inst.base) or key[inst.base.len] != 0) continue;
        for (e.value_ptr.items) |entry| collectFromImpl(self, inst, entry, out);
    }
}

/// The conformers one `impl` contributes to `inst`.
fn collectFromImpl(self: *Lowering, inst: lower.Lowering.ParamProtocolInstance, entry: lower.Lowering.ParamImplEntry, out: *std.ArrayList(TypeId)) void {
    const ib = entry.block;
    if (ib.protocol_type_args.len != inst.args.len) return;
    const blanket = if (ib.target_type_expr) |te| patternHasBinder(te) else false;
    if (!blanket) {
        // The source is one concrete type; only the head has to agree.
        var closed = std.StringHashMap(TypeId).init(self.alloc);
        defer closed.deinit();
        if (headArgsMatch(self, inst, entry, &closed)) appendUnique(self, out, entry.source_ty);
        return;
    }
    const pattern = ib.target_type_expr.?;
    // Blanket: the candidates are the generic instances the monomorphized
    // program actually spells. Unification never invents one.
    var cit = self.struct_instance_author.keyIterator();
    while (cit.next()) |name| {
        const cty = self.module.types.findByName(self.module.types.internString(name.*)) orelse continue;
        var binds = std.StringHashMap(TypeId).init(self.alloc);
        defer binds.deinit();
        if (!matchPattern(self, pattern, cty, entry.defining_module, &binds)) continue;
        if (!headArgsMatch(self, inst, entry, &binds)) continue;
        appendUnique(self, out, cty);
    }
}

/// Does the impl's source shape introduce a binder (`$T`)?
fn patternHasBinder(node: *const ast.Node) bool {
    return switch (node.data) {
        .type_expr => |te| te.is_generic,
        .pointer_type_expr => |p| patternHasBinder(p.pointee_type),
        .many_pointer_type_expr => |p| patternHasBinder(p.element_type),
        .optional_type_expr => |o| patternHasBinder(o.inner_type),
        .slice_type_expr => |s| patternHasBinder(s.element_type),
        .array_type_expr => |a| patternHasBinder(a.element_type),
        .parameterized_type_expr => |pt| blk: {
            for (pt.args) |a| if (patternHasBinder(a)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Unify the impl's written source shape against a candidate conformer,
/// binding each `$T` to the type standing at its position.
fn matchPattern(self: *Lowering, node: *const ast.Node, ty: TypeId, source: []const u8, binds: *std.StringHashMap(TypeId)) bool {
    switch (node.data) {
        .type_expr => |te| {
            if (te.is_generic) {
                const gop = binds.getOrPut(te.name) catch @panic("out of memory");
                if (gop.found_existing) return gop.value_ptr.* == ty;
                gop.value_ptr.* = ty;
                return true;
            }
            const written = resolveInImplSource(self, node, source, binds);
            return written != .unresolved and written == ty;
        },
        .pointer_type_expr => |p| {
            if (ty.isBuiltin()) return false;
            const info = self.module.types.get(ty);
            if (info != .pointer) return false;
            return matchPattern(self, p.pointee_type, info.pointer.pointee, source, binds);
        },
        .many_pointer_type_expr => |p| {
            if (ty.isBuiltin()) return false;
            const info = self.module.types.get(ty);
            if (info != .many_pointer) return false;
            return matchPattern(self, p.element_type, info.many_pointer.element, source, binds);
        },
        .optional_type_expr => |o| {
            if (ty.isBuiltin()) return false;
            const info = self.module.types.get(ty);
            if (info != .optional) return false;
            return matchPattern(self, o.inner_type, info.optional.child, source, binds);
        },
        .slice_type_expr => |s| {
            if (ty.isBuiltin()) return false;
            const info = self.module.types.get(ty);
            if (info != .slice) return false;
            return matchPattern(self, s.element_type, info.slice.element, source, binds);
        },
        .parameterized_type_expr => |pt| {
            const cname = self.resolveConcreteTypeName(ty) orelse return false;
            const author = self.struct_instance_author.get(cname) orelse return false;
            const template = self.struct_instance_template.get(cname) orelse return false;
            if (!std.mem.eql(u8, template, pt.name)) return false;
            const instance_binds = self.struct_instance_bindings.getPtr(cname) orelse return false;
            if (author.type_params.len != pt.args.len) return false;
            for (author.type_params, pt.args) |tp, arg| {
                if (tp.is_variadic) return false;
                const aty = instance_binds.get(tp.name) orelse return false;
                if (!matchPattern(self, arg, aty, source, binds)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Resolve a type written in an impl, in that impl's own module and under the
/// binder assignment unification produced.
fn resolveInImplSource(self: *Lowering, node: *const ast.Node, source: []const u8, binds: *std.StringHashMap(TypeId)) TypeId {
    const saved_bindings = self.type_bindings;
    const saved_source = self.current_source_file;
    defer {
        self.type_bindings = saved_bindings;
        self.setCurrentSourceFile(saved_source);
    }
    var tb = std.StringHashMap(TypeId).init(self.alloc);
    var it = binds.iterator();
    while (it.next()) |b| tb.put(b.key_ptr.*, b.value_ptr.*) catch @panic("out of memory");
    self.type_bindings = tb;
    if (source.len != 0) self.setCurrentSourceFile(source);
    return self.resolveTypeWithBindings(node);
}

/// Does the impl's protocol head, read under `binds`, name exactly this
/// instantiation's canonical argument tuple? Aliases resolve on the way in, so
/// `impl Series(Sample)` and `impl Series(f32)` land on one entry.
fn headArgsMatch(self: *Lowering, inst: lower.Lowering.ParamProtocolInstance, entry: lower.Lowering.ParamImplEntry, binds: *std.StringHashMap(TypeId)) bool {
    const ib = entry.block;
    if (ib.protocol_type_args.len != inst.args.len) return false;
    for (ib.protocol_type_args, inst.args) |arg_node, want| {
        const got = resolveInImplSource(self, arg_node, entry.defining_module, binds);
        if (got != want) return false;
    }
    return true;
}

/// The empty-set gate (spec §6.8): any value-CONSUMING operation — erasure,
/// method call, downcast — at a tagged protocol with no conformer anywhere in
/// the program is a compile error at that site. A merely reaching use (a
/// field, a parameter never erased into) stays legal.
pub fn refuseEmptySet(self: *Lowering, proto: TypeId, span: ?ast.Span) bool {
    const pd = self.getProtocolInfo(proto) orelse return false;
    if (pd.kind != .tagged) return false;
    if (hasAnyConformer(self, proto)) return false;
    if (self.diagnostics) |d| {
        if (isInstantiation(self, proto)) {
            d.addFmt(.err, span, "no impl of '{s}' exists in this program — a tagged conformer set is per instantiation and whole-program, and {s}, so no value of this instantiation can exist", .{ self.formatTypeName(proto), siblingInstantiations(self, proto) });
        } else {
            d.addFmt(.err, span, "no impl of '{s}' exists in this program — a tagged protocol's conformer set is whole-program, and nothing implements this one, so no value of it can exist", .{self.formatTypeName(proto)});
        }
    }
    return true;
}

/// The other instantiations of `proto`'s family that DO have conformers,
/// rendered for the empty-set diagnostic: an empty `Series(bool)` is almost
/// always a wrong argument, and the tuples that do exist are the fix.
fn siblingInstantiations(self: *Lowering, proto: TypeId) []const u8 {
    const inst = self.param_protocol_instances.get(proto).?;
    const own = self.protocolResolver().paramProtocolInstanceName(inst.base, inst.args);
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(self.alloc);
    var counts = std.ArrayList(usize).empty;
    defer counts.deinit(self.alloc);
    var it = self.param_impl_map.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (key.len <= inst.base.len) continue;
        if (!std.mem.startsWith(u8, key, inst.base) or key[inst.base.len] != 0) continue;
        for (e.value_ptr.items) |entry| {
            var head_open = false;
            for (entry.block.protocol_type_args) |a| {
                if (patternHasBinder(a)) head_open = true;
            }
            if (head_open) continue;
            const name = self.protocolResolver().paramProtocolInstanceName(inst.base, entry.target_args);
            if (std.mem.eql(u8, name, own)) continue;
            var seen = false;
            for (names.items, 0..) |n, i| {
                if (!std.mem.eql(u8, n, name)) continue;
                counts.items[i] += 1;
                seen = true;
            }
            if (seen) continue;
            names.append(self.alloc, name) catch @panic("out of memory");
            counts.append(self.alloc, 1) catch @panic("out of memory");
        }
    }
    var rendered = std.ArrayList([]const u8).empty;
    defer rendered.deinit(self.alloc);
    for (names.items, counts.items) |n, c| {
        const plural: []const u8 = if (c == 1) "" else "s";
        rendered.append(self.alloc, std.fmt.allocPrint(self.alloc, "'{s}' ({d} impl{s})", .{ n, c, plural }) catch @panic("out of memory")) catch @panic("out of memory");
    }
    if (rendered.items.len == 0)
        return std.fmt.allocPrint(self.alloc, "nothing implements '{s}' at any instantiation", .{inst.base}) catch @panic("out of memory");
    std.mem.sort([]const u8, rendered.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var buf = std.ArrayList(u8).empty;
    buf.appendSlice(self.alloc, "'") catch @panic("out of memory");
    buf.appendSlice(self.alloc, inst.base) catch @panic("out of memory");
    buf.appendSlice(self.alloc, "' is implemented at ") catch @panic("out of memory");
    for (rendered.items, 0..) |n, i| {
        if (i > 0) buf.appendSlice(self.alloc, if (i + 1 == rendered.items.len) " and " else ", ") catch @panic("out of memory");
        buf.appendSlice(self.alloc, n) catch @panic("out of memory");
    }
    return buf.items;
}

/// The erasure gate for an INSTANTIATION: membership is the tuple's own, so
/// `Buffer(bool)` is no member of `Series(f32)` however well its methods line
/// up by name. The per-method conformance check that follows works off the
/// impl registries, which are keyed per family — only the set knows which
/// tuple a blanket admitted this type at.
pub fn refuseNonMember(self: *Lowering, proto: TypeId, concrete: TypeId, span: ast.Span) bool {
    if (!isTagged(self, proto) or !isInstantiation(self, proto)) return false;
    if (conforms(self, proto, concrete)) return false;
    if (self.diagnostics) |d| {
        if (otherInstantiationOf(self, proto, concrete)) |other| {
            d.addFmt(.err, span, "'{s}' implements '{s}', not '{s}' — each instantiation of a tagged protocol family owns its conformer set, so a conformer of another instantiation cannot erase into this one", .{ self.formatTypeName(concrete), other, self.formatTypeName(proto) });
        } else {
            d.addFmt(.err, span, "'{s}' does not implement '{s}' — a tagged conformer set is whole-program and per instantiation, and no impl admits this type at this argument tuple", .{ self.formatTypeName(concrete), self.formatTypeName(proto) });
        }
    }
    return true;
}

/// A downcast off a tagged value names a conformer or nothing: the set is
/// whole-program, so `v.(Timer)` where `Timer` implements nothing is a
/// compile error rather than a compare that can never succeed (spec §6.8).
/// Protocol, `ProtocolRaw`, `any` and pointer targets are conversions, not
/// downcasts, and pass through untouched.
pub fn refuseOutOfSetDowncast(self: *Lowering, recv_ty: TypeId, written: TypeId, span: ast.Span) bool {
    if (!isTagged(self, recv_ty)) return false;
    if (written == .unresolved) return false;
    // `.(?T)` is the soft temperament of the same assertion — the asserted
    // type is the inner one.
    const target = if (!written.isBuiltin() and self.module.types.get(written) == .optional)
        self.module.types.get(written).optional.child
    else
        written;
    if (target == .unresolved or target == recv_ty or target == .any) return false;
    if (self.getProtocolInfo(target) != null) return false;
    if (!target.isBuiltin()) {
        switch (self.module.types.get(target)) {
            .pointer, .many_pointer => return false,
            .@"struct" => |s| if (std.mem.eql(u8, self.module.types.getString(s.name), "ProtocolRaw")) return false,
            else => {},
        }
    }
    reachTagged(self, recv_ty);
    if (refuseEmptySet(self, recv_ty, span)) return true;
    if (conforms(self, recv_ty, target)) return false;
    if (self.diagnostics) |d| {
        if (otherInstantiationOf(self, recv_ty, target)) |other| {
            d.addFmt(.err, span, "'{s}' implements '{s}', not '{s}' — each instantiation of a tagged protocol family owns its conformer set and tag space, so a conformer of another instantiation can never match here", .{ self.formatTypeName(target), other, self.formatTypeName(recv_ty) });
        } else {
            d.addFmt(.err, span, "'{s}' does not implement '{s}' — a tagged protocol's conformer set is whole-program, so this downcast can never match; implement it, or name a conformer", .{ self.formatTypeName(target), self.formatTypeName(recv_ty) });
        }
    }
    return true;
}

/// The instantiation of `proto`'s own family that `target` DOES conform to,
/// when there is one. A conformer of a sibling tuple is the common mistake the
/// per-instantiation rule catches, and naming the tuple it belongs to is the
/// whole fix.
fn otherInstantiationOf(self: *Lowering, proto: TypeId, target: TypeId) ?[]const u8 {
    const inst = self.param_protocol_instances.get(proto) orelse return null;
    var it = self.param_impl_map.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (key.len <= inst.base.len) continue;
        if (!std.mem.startsWith(u8, key, inst.base) or key[inst.base.len] != 0) continue;
        for (e.value_ptr.items) |entry| {
            var head_open = false;
            for (entry.block.protocol_type_args) |a| {
                if (patternHasBinder(a)) head_open = true;
            }
            if (head_open) continue;
            const cand: lower.Lowering.ParamProtocolInstance = .{ .base = inst.base, .args = entry.target_args, .decl = inst.decl };
            var found = std.ArrayList(TypeId).empty;
            defer found.deinit(self.alloc);
            collectFromImpl(self, cand, entry, &found);
            for (found.items) |c| {
                if (c != target) continue;
                const name = self.protocolResolver().paramProtocolInstanceName(inst.base, entry.target_args);
                if (std.mem.eql(u8, name, self.formatTypeName(proto))) continue;
                return name;
            }
        }
    }
    return null;
}

/// A type-switch arm on a tagged subject that names a non-conformer never
/// matches. Warned dead rather than refused — user code cannot spell "all
/// conformers", so an arm kept for a type another build implements is a
/// legitimate shape (spec §6.8).
pub fn warnDeadTypeSwitchArm(self: *Lowering, subject_ty: TypeId, arm_ty: TypeId, span: ?ast.Span) void {
    if (!isTagged(self, subject_ty)) return;
    if (arm_ty == .unresolved or conforms(self, subject_ty, arm_ty)) return;
    if (self.diagnostics) |d| {
        d.addFmt(.warn, span, "arm '{s}' is dead — it does not implement '{s}', whose conformer set is whole-program, so this arm never matches", .{ self.formatTypeName(arm_ty), self.formatTypeName(subject_ty) });
    }
}

// ── Erasure ─────────────────────────────────────────────────────────────

/// Comptime protocol values are symbolic — `{ctx, concrete type}` — and a
/// tagged value's numeric word is a link-stage artifact that does not exist
/// during compilation. The staged capability lands with the scheduled
/// comptime discipline; until then every comptime tagged value refuses
/// through the ordinary error path.
pub fn refuseComptimeTagged(self: *Lowering, proto_ty: TypeId, span: ?ast.Span) bool {
    if (self.comptime_body_depth == 0) return false;
    if (!isTagged(self, proto_ty)) return false;
    if (self.diagnostics) |d| {
        const at = span orelse blk: {
            const cs = self.builder.current_span;
            break :blk ast.Span{ .start = cs.start, .end = cs.end };
        };
        d.addFmt(.err, at, "'{s}' is a tagged protocol and its values are not available in compile-time execution — a tag is assigned when the whole-program conformer set is numbered, which happens after every comptime evaluation; use the concrete type here, or a generic bound ('$T/{s}')", .{ self.formatTypeName(proto_ty), self.formatTypeName(proto_ty) });
    }
    return true;
}

/// Build the tagged borrow `{ctx, tag}` over already-resolved storage.
pub fn buildTaggedValue(self: *Lowering, ctx_ptr: Ref, proto_ty: TypeId, concrete_ty: TypeId) Ref {
    if (refuseComptimeTagged(self, proto_ty, null))
        return self.builder.constUndef(proto_ty);
    if (self.refuseValuelessProtocol(proto_ty, .{ .start = self.builder.current_span.start, .end = self.builder.current_span.end }, "make a value of"))
        return self.builder.constUndef(proto_ty);
    reachTagged(self, proto_ty);
    _ = admit(self, proto_ty, concrete_ty);
    const void_ptr_ty = self.module.types.ptrTo(.void);
    const ctx = if (self.builder.getRefType(ctx_ptr) == void_ptr_ty)
        ctx_ptr
    else
        self.builder.emit(.{ .bitcast = .{
            .operand = ctx_ptr,
            .from = self.builder.getRefType(ctx_ptr),
            .to = void_ptr_ty,
        } }, void_ptr_ty);
    const tag = self.builder.emit(.{ .tagged_tag_of = .{ .proto = proto_ty, .concrete = concrete_ty } }, .i64);
    var fields = [2]Ref{ ctx, tag };
    return self.builder.structInit(&fields, proto_ty);
}

// ── The tag → type_id table ─────────────────────────────────────────────

/// The concrete `Type` word of a protocol value, whatever its kind: the
/// stamped slot 1 on the erased kinds, `table[v.tag]` on tagged (§7.2, §7.3).
/// Everything that reads a protocol value's RTTI — `type_of`, the downcast,
/// the type switch, `ProtocolRaw`, the `any` bridge — goes through here.
pub fn protocolTypeIdWord(self: *Lowering, proto_ty: TypeId, value: Ref) Ref {
    if (!isTagged(self, proto_ty)) return self.builder.structGet(value, 1, .type_value);
    return typeIdWord(self, proto_ty, value);
}

/// The `Type` word of a tagged value: `table[v.tag]`, one indexed load.
fn typeIdWord(self: *Lowering, proto_ty: TypeId, value: Ref) Ref {
    const table_gid = typeIdTable(self, proto_ty);
    const tag = self.builder.emit(.{ .struct_get = .{ .base = value, .field_index = 1 } }, .i64);
    const many_ty = self.module.types.manyPtrTo(.type_value);
    const base = self.builder.emit(.{ .global_addr = table_gid }, many_ty);
    const slot = self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = tag } }, self.module.types.ptrTo(.type_value));
    return self.builder.load(slot, .type_value);
}

/// The protocol's tag table global. Created empty at first use and filled in
/// by `convergeTaggedSets` once the set is final.
fn typeIdTable(self: *Lowering, proto_ty: TypeId) GlobalId {
    if (self.tagged_type_id_tables.get(proto_ty)) |gid| return gid;
    reachTagged(self, proto_ty);
    const name = std.fmt.allocPrint(self.alloc, "__sx_tags_{s}_type_ids", .{tableName(self, proto_ty)}) catch @panic("out of memory");
    const gid = self.module.addGlobal(.{
        .name = self.module.types.internString(name),
        .ty = self.module.types.arrayOf(.type_value, 1),
        .init_val = .{ .zeroinit = {} },
        .is_const = true,
    });
    self.tagged_type_id_tables.put(proto_ty, gid) catch @panic("out of memory");
    return gid;
}

/// The protocol's canonical identity, sanitized for a symbol. Instantiation
/// arguments are already spelled out in the mangled protocol name, so two
/// instantiations can never truncate into one symbol.
fn tableName(self: *Lowering, proto_ty: TypeId) []const u8 {
    const raw = self.getProtocolInfo(proto_ty).?.name;
    const out = self.alloc.dupe(u8, raw) catch @panic("out of memory");
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_') c.* = '_';
    }
    return out;
}

// ── Dispatch ────────────────────────────────────────────────────────────

/// The outlined dispatch routine for one dispatchable method:
/// `__sx_tags_<P>_<m>(v: P, args…) -> ret`. Declared on first call site,
/// bodied at whole-program emission — its arms are the converged set.
fn dispatchRoutine(self: *Lowering, proto_ty: TypeId, pd: ProtocolDeclInfo, method: ProtocolMethodInfo) FuncId {
    const key = MethodKey{ .proto = proto_ty, .method = self.module.types.internString(method.name) };
    if (self.tagged_dispatch_fns.get(key)) |fid| return fid;

    var params = std.ArrayList(inst_mod.Function.Param).empty;
    defer params.deinit(self.alloc);
    const void_ptr = self.module.types.ptrTo(.void);
    const has_ctx = self.implicit_ctx_enabled;
    if (has_ctx) params.append(self.alloc, .{ .name = self.module.types.internString("__sx_ctx"), .ty = void_ptr }) catch unreachable;
    params.append(self.alloc, .{ .name = self.module.types.internString("v"), .ty = proto_ty }) catch unreachable;
    for (method.param_types, 0..) |pty, i| {
        var buf: [32]u8 = undefined;
        const pname = std.fmt.bufPrint(&buf, "a{d}", .{i}) catch "arg";
        params.append(self.alloc, .{ .name = self.module.types.internString(pname), .ty = pty }) catch unreachable;
    }
    const fname = std.fmt.allocPrint(self.alloc, "__sx_tags_{s}_{s}", .{ tableName(self, proto_ty), method.name }) catch @panic("out of memory");
    var func = inst_mod.Function.init(self.module.types.internString(fname), self.alloc.dupe(inst_mod.Function.Param, params.items) catch unreachable, method.ret_type);
    func.has_implicit_ctx = has_ctx;
    const fid = self.module.addFunction(func);
    self.tagged_dispatch_fns.put(key, fid) catch @panic("out of memory");
    self.tagged_pending.append(self.alloc, .{ .proto = proto_ty, .pd = pd, .method = method, .fid = fid }) catch @panic("out of memory");
    return fid;
}

/// Emit a tagged method call: the value plus the user args, straight into the
/// outlined routine. The switch (and its single-conformer fold) lives inside
/// the routine, so ordinary callers stay set-independent.
pub fn emitTaggedDispatch(self: *Lowering, receiver: Ref, pd: ProtocolDeclInfo, proto_ty: TypeId, method: ProtocolMethodInfo, args: []const Ref) Ref {
    const fid = dispatchRoutine(self, proto_ty, pd, method);
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (self.implicit_ctx_enabled) call_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
    call_args.append(self.alloc, receiver) catch unreachable;
    for (args, 0..) |a, i| {
        const want = method.param_types[i];
        call_args.append(self.alloc, self.coerceToType(a, self.builder.getRefType(a), want)) catch unreachable;
    }
    const owned = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    return self.builder.call(fid, owned, method.ret_type);
}

// ── The collection fixpoint + whole-program emission ────────────────────

/// Run the conformer fixpoint and emit every reached protocol's tables and
/// dispatch routines, then number the tags and relocate every deferred
/// `tagged_tag_of`. Called once, after all bodies are lowered.
///
/// The loop is a fixpoint because materializing a member's thunks
/// monomorphizes its impl bodies, which may erase into further protocols or
/// instantiate further conformers (spec §6.5).
pub fn convergeTaggedSets(self: *Lowering) void {
    while (true) {
        var changed = false;

        var reached = std.ArrayList(TypeId).empty;
        defer reached.deinit(self.alloc);
        var rit = self.tagged_reached.keyIterator();
        while (rit.next()) |p| reached.append(self.alloc, p.*) catch @panic("out of memory");

        for (reached.items) |proto| {
            if (admitDeclaredImpls(self, proto)) changed = true;
        }

        // Materializing an arm lowers the conformer's impl methods, which is
        // exactly what can enlarge another set.
        var pending = self.tagged_pending.items;
        var i: usize = 0;
        while (i < pending.len) : (i += 1) {
            const job = pending[i];
            if (materializeArms(self, job.proto, job.pd, job.method)) changed = true;
            pending = self.tagged_pending.items;
        }
        if (!changed) break;
    }

    checkCoherence(self);
    numberTags(self);
    emitTypeIdTables(self);
    for (self.tagged_pending.items) |job| emitDispatchBody(self, job);
    relocateTags(self);
}

/// Ensure each member of `proto`'s set has its thunk for `method` lowered.
/// Returns true when doing so grew any set.
fn materializeArms(self: *Lowering, proto: TypeId, pd: ProtocolDeclInfo, method: ProtocolMethodInfo) bool {
    const list = self.tagged_members.get(proto) orelse return false;
    var changed = false;
    var idx: usize = 0;
    while (idx < list.items.len) : (idx += 1) {
        const members = self.tagged_members.get(proto).?;
        if (idx >= members.items.len) break;
        const concrete = members.items[idx];
        const key = ArmKey{ .proto = proto, .concrete = concrete, .method = self.module.types.internString(method.name) };
        if (self.tagged_arms.contains(key)) continue;
        const cname = self.resolveConcreteTypeName(concrete) orelse continue;
        const before = countMembers(self);
        const thunk = self.createProtocolThunk(proto, pd.name, cname, concrete, method);
        self.tagged_arms.put(key, thunk) catch @panic("out of memory");
        if (countMembers(self) != before) changed = true;
    }
    return changed;
}

fn countMembers(self: *Lowering) usize {
    var n: usize = 0;
    var it = self.tagged_members.valueIterator();
    while (it.next()) |list| n += list.items.len;
    return n;
}

pub const ArmKey = struct {
    proto: TypeId,
    concrete: TypeId,
    method: types.StringId,
};

pub const PendingRoutine = struct {
    proto: TypeId,
    pd: ProtocolDeclInfo,
    method: ProtocolMethodInfo,
    fid: FuncId,
};

/// Assign the dense tags. Canonical order is the conformer's canonical
/// identity — its nominal-aware mangle, not its display name, so two
/// same-spelled conformers from different modules order deterministically.
fn numberTags(self: *Lowering) void {
    var it = self.tagged_members.iterator();
    while (it.next()) |entry| {
        const list = entry.value_ptr;
        const Ctx = struct {
            l: *Lowering,
            fn lt(ctx: @This(), a: TypeId, b: TypeId) bool {
                return std.mem.order(u8, ctx.l.mangleTypeName(a), ctx.l.mangleTypeName(b)) == .lt;
            }
        };
        std.mem.sort(TypeId, list.items, Ctx{ .l = self }, Ctx.lt);
        for (list.items, 0..) |concrete, tag| {
            self.tagged_tags.put(.{ .proto = entry.key_ptr.*, .concrete = concrete }, @intCast(tag)) catch @panic("out of memory");
        }
    }
}

fn emitTypeIdTables(self: *Lowering) void {
    var it = self.tagged_type_id_tables.iterator();
    while (it.next()) |entry| {
        const proto = entry.key_ptr.*;
        const members = if (self.tagged_members.get(proto)) |m| m.items else &[_]TypeId{};
        const rows = self.alloc.alloc(inst_mod.ConstantValue, @max(members.len, 1)) catch @panic("out of memory");
        rows[0] = .{ .int = 0 };
        for (members, 0..) |concrete, i| rows[i] = .{ .int = @intCast(concrete.index()) };
        const g = &self.module.globals.items[@intFromEnum(entry.value_ptr.*)];
        g.ty = self.module.types.arrayOf(.type_value, @intCast(@max(members.len, 1)));
        g.init_val = .{ .aggregate = rows };
    }
}

/// The routine body: a total switch over the tag, every arm a direct call to
/// the member's thunk. A one-member set folds to the call with no switch at
/// all — a single-conformer tagged protocol devirtualizes completely.
fn emitDispatchBody(self: *Lowering, job: PendingRoutine) void {
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    const saved_ctx = self.current_ctx_ref;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
        self.current_ctx_ref = saved_ctx;
    }

    const nparams = self.module.functions.items[@intFromEnum(job.fid)].params.len;
    self.builder.func = job.fid;
    self.builder.inst_counter = @intCast(nparams);
    const has_ctx = self.implicit_ctx_enabled;
    if (has_ctx) self.current_ctx_ref = Ref.fromIndex(0);
    const entry = self.builder.appendBlock(self.module.types.internString("entry"), &.{});
    self.builder.switchToBlock(entry);

    const void_ptr = self.module.types.ptrTo(.void);
    const value_ref = Ref.fromIndex(if (has_ctx) 1 else 0);
    const user_base: u32 = (if (has_ctx) @as(u32, 2) else 1);
    const members = if (self.tagged_members.get(job.proto)) |m| m.items else &[_]TypeId{};

    if (members.len == 0) {
        _ = self.builder.emit(.{ .@"unreachable" = {} }, .void);
        self.builder.finalize();
        return;
    }

    const ctx_ref = self.builder.emit(.{ .struct_get = .{ .base = value_ref, .field_index = 0 } }, void_ptr);

    if (members.len == 1) {
        emitArmCall(self, job, members[0], ctx_ref, user_base);
        self.builder.finalize();
        return;
    }

    const tag_ref = self.builder.emit(.{ .struct_get = .{ .base = value_ref, .field_index = 1 } }, .i64);
    var cases = std.ArrayList(inst_mod.SwitchBranch.Case).empty;
    defer cases.deinit(self.alloc);
    var arm_blocks = std.ArrayList(inst_mod.BlockId).empty;
    defer arm_blocks.deinit(self.alloc);
    for (members, 0..) |_, i| {
        const b = self.freshBlock("tags.arm");
        arm_blocks.append(self.alloc, b) catch unreachable;
        cases.append(self.alloc, .{ .value = @intCast(i), .target = b, .args = &.{} }) catch unreachable;
    }
    // Total over the set by construction — the default is reached only by a
    // tag the program cannot produce.
    const unr = self.freshBlock("tags.unr");
    self.builder.switchBr(tag_ref, cases.items, unr, &.{});
    for (members, 0..) |concrete, i| {
        self.builder.switchToBlock(arm_blocks.items[i]);
        emitArmCall(self, job, concrete, ctx_ref, user_base);
    }
    self.builder.switchToBlock(unr);
    _ = self.builder.emit(.{ .@"unreachable" = {} }, .void);
    self.builder.finalize();
}

fn emitArmCall(self: *Lowering, job: PendingRoutine, concrete: TypeId, ctx_ref: Ref, user_base: u32) void {
    const key = ArmKey{ .proto = job.proto, .concrete = concrete, .method = self.module.types.internString(job.method.name) };
    const thunk = self.tagged_arms.get(key) orelse {
        _ = self.builder.emit(.{ .@"unreachable" = {} }, .void);
        return;
    };
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (self.implicit_ctx_enabled) call_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
    call_args.append(self.alloc, ctx_ref) catch unreachable;
    for (job.method.param_types, 0..) |_, i| {
        call_args.append(self.alloc, Ref.fromIndex(@intCast(user_base + i))) catch unreachable;
    }
    const owned = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    const result = self.builder.call(thunk, owned, job.method.ret_type);
    if (job.method.ret_type == .void) self.builder.retVoid() else self.builder.ret(result, job.method.ret_type);
}

/// Relocate every deferred tag into its numbered constant. The set is final
/// here, so this is the one place a literal tag exists.
fn relocateTags(self: *Lowering) void {
    for (self.module.functions.items) |*func| {
        for (func.blocks.items) |*block| {
            for (block.insts.items) |*ins| {
                switch (ins.op) {
                    .tagged_tag_of => |t| {
                        const tag = self.tagged_tags.get(.{ .proto = t.proto, .concrete = t.concrete }) orelse 0;
                        ins.op = .{ .const_int = tag };
                    },
                    else => {},
                }
            }
        }
    }
}

/// The tagged downcast (§6.8): the check is one immediate compare of the
/// value's tag word against the target's constant tag — no table load on
/// the hot path. The failure arm is cold: the soft form yields `null`
/// outright; the panic form materializes the `any` view there (the only
/// table read) and re-enters `__sx_cast_or_panic`, so the message, the
/// `#caller_location`, and the exit path stay byte-identical to the other
/// kinds. The receiver is lowered exactly once; the cold call sees it
/// through a synthetic scope binding, never a re-evaluation. The graceful
/// (`try`) temperament still routes through `__sx_cast_assert`'s any view
/// (desugared before lowering, where no IR blocks exist to split).
pub fn lowerTaggedDowncast(
    self: *Lowering,
    pc: *const ast.PostfixCast,
    node: *const ast.Node,
    proto_ty: TypeId,
    full_dst: TypeId,
) Ref {
    const soft = pc.type_expr.data == .optional_type_expr;
    const concrete = if (soft) self.module.types.get(full_dst).optional.child else full_dst;
    const operand = self.lowerExpr(pc.operand);

    const tag = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 1 } }, .i64);
    const want = self.builder.emit(.{ .tagged_tag_of = .{ .proto = proto_ty, .concrete = concrete } }, .i64);
    const matches = self.builder.emit(.{ .cmp_eq = .{ .lhs = tag, .rhs = want } }, .bool);

    const ok_bb = self.freshBlock("tagcast.ok");
    const fail_bb = self.freshBlock("tagcast.fail");
    const merge_bb = self.freshBlockWithParams("tagcast.merge", &.{full_dst});
    self.builder.condBr(matches, ok_bb, &.{}, fail_bb, &.{});

    // Match: the tag proved the concrete type, so the `any` view carries a
    // CONSTANT type word — the unbox reads straight through ctx.
    self.builder.switchToBlock(ok_bb);
    const void_ptr_ty = self.module.types.ptrTo(.void);
    const ctx = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
    const av_ok = self.builder.makeAny(self.builder.constType(concrete), ctx);
    const unboxed = self.builder.emit(.{ .unbox_any = .{ .operand = av_ok } }, concrete);
    const ok_val = if (soft) self.builder.optionalWrap(unboxed, full_dst) else unboxed;
    self.builder.br(merge_bb, &.{ok_val});

    self.builder.switchToBlock(fail_bb);
    if (soft) {
        self.builder.br(merge_bb, &.{self.builder.constNull(full_dst)});
    } else {
        var buf: [40]u8 = undefined;
        const nm = std.fmt.bufPrint(&buf, "$tagcast_{d}", .{self.block_counter}) catch "$tagcast";
        self.block_counter += 1;
        const owned = self.alloc.dupe(u8, nm) catch @panic("out of memory");
        self.scope.?.put(owned, .{ .ref = operand, .ty = proto_ty, .is_alloca = false });
        const recv_id = self.alloc.create(ast.Node) catch @panic("out of memory");
        recv_id.* = .{ .data = .{ .identifier = .{ .name = owned } }, .span = pc.operand.span, .source_file = pc.operand.source_file };
        const xx_node = self.alloc.create(ast.Node) catch @panic("out of memory");
        xx_node.* = .{ .data = .{ .unary_op = .{ .op = .xx, .operand = recv_id } }, .span = pc.operand.span, .source_file = pc.operand.source_file };
        const callee = self.alloc.create(ast.Node) catch @panic("out of memory");
        callee.* = .{ .data = .{ .identifier = .{ .name = "__sx_cast_or_panic" } }, .span = node.span, .source_file = node.source_file };
        const args = self.alloc.dupe(*ast.Node, &.{ xx_node, pc.type_expr }) catch @panic("out of memory");
        const syn_call = ast.Call{ .callee = callee, .args = args };
        const res = self.lowerCall(&syn_call);
        self.builder.br(merge_bb, &.{res});
    }

    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, full_dst);
}
