const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;

/// Canonical owner of pack-aware TYPE-position resolution (architecture phase
/// A2.3). Resolves the shapes whose meaning depends on active pack state —
/// pack-variadic `Closure(..p)` / `(Params...) -> R` / `(..xs)` tuples and the
/// pack projections (`..xs.T`) that back them — in one place instead of inline
/// in `Lowering`.
///
/// A `*Lowering` facade (Principle 5): pack projection reads the live pack
/// state (`pack_arg_types` / `pack_constraint` / `pack_bindings` /
/// `type_bindings` / `param_impl_map`) and recurses through the full stateful
/// type resolver, so it borrows `Lowering` rather than re-threading every
/// field. The dependency shrinks as later phases lift pack state into an
/// explicit context object.
pub const PackResolver = struct {
    l: *Lowering,

    /// Resolve a `Closure(...)` type expression with the active type/pack
    /// bindings applied. Pack-shaped closure exprs (`Closure(Prefix..., ..$pack)`)
    /// substitute `pack` from `pack_bindings`, producing a concrete closure
    /// type — used when monomorphising a pack-variadic impl body against a
    /// concrete source signature.
    pub fn resolveClosureTypeWithBindings(self: PackResolver, ct: *const ast.ClosureTypeExpr) TypeId {
        var param_ids = std.ArrayList(TypeId).empty;
        defer param_ids.deinit(self.l.alloc);
        for (ct.param_types) |pt| {
            param_ids.append(self.l.alloc, self.l.resolveTypeWithBindings(pt)) catch return .unresolved;
        }
        if (ct.pack_name) |pn| {
            // Protocol pack (`Closure(..sources.T)` / `Closure(..sources)`):
            // expand the bound pack's per-element type-args.
            if (self.packTypeArgs(pn, ct.pack_projection)) |elems| {
                defer self.l.alloc.free(elems);
                for (elems) |t| param_ids.append(self.l.alloc, t) catch return .unresolved;
                const ret_ty = if (ct.return_type) |rt| self.l.resolveTypeWithBindings(rt) else .void;
                return self.l.module.types.closureType(param_ids.items, ret_ty);
            }
            if (self.l.pack_bindings) |pb| {
                if (pb.get(pn)) |pack_tys| {
                    for (pack_tys) |t| param_ids.append(self.l.alloc, t) catch return .unresolved;
                    // Fully bound — emit a concrete closure type, no pack_start.
                    const ret_ty = if (ct.return_type) |rt| self.l.resolveTypeWithBindings(rt) else .void;
                    return self.l.module.types.closureType(param_ids.items, ret_ty);
                }
            }
            // Pack name in scope but no binding — preserve the pack-shape
            // so downstream code can still see it's variadic. (Hit during
            // impl-block parsing before any concrete monomorphisation.)
            const ret_ty = if (ct.return_type) |rt| self.l.resolveTypeWithBindings(rt) else .void;
            return self.l.module.types.closureTypePack(param_ids.items, ret_ty, @intCast(param_ids.items.len));
        }
        const ret_ty = if (ct.return_type) |rt| self.l.resolveTypeWithBindings(rt) else .void;
        return self.l.module.types.closureType(param_ids.items, ret_ty);
    }

    /// Resolve a tuple type expression with active pack bindings: a spread field
    /// `(..xs)` / `(..xs.T)` expands to the pack's per-element types via
    /// `packTypeElems`. Non-spread fields resolve normally.
    pub fn resolveTupleTypeWithBindings(self: PackResolver, tt: *const ast.TupleTypeExpr) TypeId {
        var field_ids = std.ArrayList(TypeId).empty;
        defer field_ids.deinit(self.l.alloc);
        var had_spread = false;
        for (tt.field_types) |ft| {
            if (ft.data == .spread_expr) {
                if (self.packTypeElems(ft.data.spread_expr.operand)) |elems| {
                    defer self.l.alloc.free(elems);
                    for (elems) |e| field_ids.append(self.l.alloc, e) catch return .unresolved;
                    had_spread = true;
                    continue;
                }
            }
            field_ids.append(self.l.alloc, self.l.resolveTypeWithBindings(ft)) catch return .unresolved;
        }
        // Preserve field names for a named tuple `(x: T, y: U)` so `t.x` resolves
        // (matches type_bridge.resolveTupleType). A spread expands to unnamed
        // pack elements, so names only apply when there was no spread.
        var name_ids: ?[]const types.StringId = null;
        if (!had_spread) {
            if (tt.field_names) |names| {
                if (names.len == field_ids.items.len) {
                    var ids = std.ArrayList(types.StringId).empty;
                    for (names) |n| ids.append(self.l.alloc, self.l.module.types.internString(n)) catch return .unresolved;
                    name_ids = ids.toOwnedSlice(self.l.alloc) catch null;
                }
            }
        }
        return self.l.module.types.intern(.{ .tuple = .{
            .fields = self.l.alloc.dupe(TypeId, field_ids.items) catch return .unresolved,
            .names = name_ids,
        } });
    }

    /// Resolve a tuple LITERAL used in a type position whose elements include a
    /// pack spread (`(..$Ts)` / `(..xs.T)` — these parse as a tuple literal, not
    /// a `tuple_type_expr`). Returns null when no element is a spread, so the
    /// caller falls through to ordinary name/type resolution. A failed
    /// allocation yields `.unresolved` (never a real `.void`).
    pub fn resolveTupleLiteralType(self: PackResolver, tl: *const ast.TupleLiteral) ?TypeId {
        var any_spread = false;
        for (tl.elements) |el| {
            if (el.value.data == .spread_expr) {
                any_spread = true;
                break;
            }
        }
        if (!any_spread) return null;
        var field_ids = std.ArrayList(TypeId).empty;
        defer field_ids.deinit(self.l.alloc);
        for (tl.elements) |el| {
            if (el.value.data == .spread_expr) {
                if (self.packTypeElems(el.value.data.spread_expr.operand)) |elems| {
                    defer self.l.alloc.free(elems);
                    for (elems) |e| field_ids.append(self.l.alloc, e) catch return .unresolved;
                    continue;
                }
            }
            field_ids.append(self.l.alloc, self.l.resolveTypeWithBindings(el.value)) catch return .unresolved;
        }
        return self.l.module.types.intern(.{ .tuple = .{
            .fields = self.l.alloc.dupe(TypeId, field_ids.items) catch return .unresolved,
            .names = null,
        } });
    }

    /// TYPE-position pack expansion: given a spread operand, return the
    /// per-element types. `..xs` → the pack's element types (`pack_arg_types`).
    /// `..xs.T` → each element's protocol type-arg `T` (from its
    /// `impl P(args) for elem` in `param_impl_map`). Null when not a pack spread.
    /// Caller owns the returned slice.
    pub fn packTypeElems(self: PackResolver, operand: *const Node) ?[]TypeId {
        const pat = self.l.pack_arg_types orelse return null;
        // `..F(Ts)` — apply a parameterized type `F` to each pack element:
        // `(..VL(Ts))` → `(VL(T0), VL(T1), …)`. Per element, temporarily bind
        // the pack name to that single element type and resolve `F(elem)`.
        if (operand.data == .parameterized_type_expr) {
            const pt = operand.data.parameterized_type_expr;
            var pack_name_p: []const u8 = "";
            for (pt.args) |a| {
                const nm = switch (a.data) {
                    .identifier => |id| id.name,
                    .type_expr => |te| te.name,
                    else => continue,
                };
                if (pat.contains(nm)) {
                    pack_name_p = nm;
                    break;
                }
            }
            if (pack_name_p.len == 0) return null;
            const elems = pat.get(pack_name_p) orelse return null;
            if (self.l.type_bindings == null) return null;
            var out = std.ArrayList(TypeId).empty;
            for (elems) |ti| {
                const had = self.l.type_bindings.?.get(pack_name_p);
                self.l.type_bindings.?.put(pack_name_p, ti) catch {};
                out.append(self.l.alloc, self.l.resolveTypeWithBindings(operand)) catch return null;
                if (had) |h| self.l.type_bindings.?.put(pack_name_p, h) catch {} else _ = self.l.type_bindings.?.remove(pack_name_p);
            }
            return out.toOwnedSlice(self.l.alloc) catch null;
        }
        // In type position `xs` / `xs.T` parse to a (possibly dotted) type_expr
        // name; `field_access` covers any value-shaped form.
        var pack_name: []const u8 = "";
        var projection: ?[]const u8 = null;
        switch (operand.data) {
            .type_expr, .identifier => {
                const full = if (operand.data == .type_expr) operand.data.type_expr.name else operand.data.identifier.name;
                if (std.mem.indexOfScalar(u8, full, '.')) |dot| {
                    pack_name = full[0..dot];
                    projection = full[dot + 1 ..];
                } else {
                    pack_name = full;
                }
            },
            .field_access => |fa| {
                pack_name = switch (fa.object.data) {
                    .identifier => |id| id.name,
                    .type_expr => |te| te.name,
                    else => return null,
                };
                projection = fa.field;
            },
            else => return null,
        }
        return self.packTypeArgs(pack_name, projection);
    }

    /// Per-element types for a bound protocol pack: `pack_name` alone → the
    /// element types; with `projection` (`xs.T`) → each element's protocol
    /// type-arg. Null when `pack_name` isn't a bound pack. Caller owns the slice.
    pub fn packTypeArgs(self: PackResolver, pack_name: []const u8, projection: ?[]const u8) ?[]TypeId {
        const pat = self.l.pack_arg_types orelse return null;
        const elems = pat.get(pack_name) orelse return null;
        if (projection == null) return self.l.alloc.dupe(TypeId, elems) catch null;
        const proto = if (self.l.pack_constraint) |pc| (pc.get(pack_name) orelse return null) else return null;
        const arg_idx = self.l.lookupProtocolArg(proto, projection.?) orelse return null;
        var out = std.ArrayList(TypeId).empty;
        for (elems) |elem| {
            const proj_ty = self.elementProtocolTypeArg(proto, elem, arg_idx) orelse blk: {
                // The projection named a protocol type-arg this element's impl
                // does not provide — there is no type for the slot. Surface it
                // loudly: a diagnostic plus the `.unresolved` sentinel (a real
                // `.void` here would read as a legitimate type downstream and
                // silently corrupt the pack).
                if (self.l.diagnostics) |diags| {
                    diags.addFmt(.err, null, "pack projection '{s}.{s}' has no type for a pack element: no matching `impl {s}(...) for {s}`", .{
                        pack_name, projection.?, proto, self.l.mangleTypeName(elem),
                    });
                }
                break :blk .unresolved;
            };
            out.append(self.l.alloc, proj_ty) catch return null;
        }
        return out.toOwnedSlice(self.l.alloc) catch null;
    }

    /// For a concrete `elem` conforming to parameterised `proto`, return the
    /// `arg_idx`-th protocol type-arg from its `impl proto(args) for elem`
    /// (scans `param_impl_map` for `proto\x00…\x00mangle(elem)`).
    pub fn elementProtocolTypeArg(self: PackResolver, proto: []const u8, elem: TypeId, arg_idx: u32) ?TypeId {
        const prefix = std.fmt.allocPrint(self.l.alloc, "{s}\x00", .{proto}) catch return null;
        const suffix = std.fmt.allocPrint(self.l.alloc, "\x00{s}", .{self.l.mangleTypeName(elem)}) catch return null;
        var it = self.l.param_impl_map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (std.mem.startsWith(u8, k, prefix) and std.mem.endsWith(u8, k, suffix)) {
                for (entry.value_ptr.items) |impl| {
                    if (arg_idx < impl.target_args.len) return impl.target_args[arg_idx];
                }
            }
        }
        return null;
    }
};
