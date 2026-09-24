const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const errors = @import("../../errors.zig");
const program_index_mod = @import("../program_index.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;
const ParamImplEntry = Lowering.ParamImplEntry;

/// Lower the `xx` operator (type coercion).
/// Uses self.target_type for context when available. Handles:
/// - Any → concrete type: compile error naming `@as` / `av.(T)` / `@unbox`
/// - int → int: widen/narrow
/// - int ↔ float: int_to_float/float_to_int
pub fn lowerXX(self: *Lowering, operand: Ref, operand_node: *const Node) Ref {
    // Use the operand's *actual* lowered Ref type rather than reaching
    // back through inferExprType — the latter doesn't cover every
    // expression shape (notably lambdas), and a wrong src_ty here can
    // route the cast through coerceToType (e.g. a bogus i64→ptr bitcast)
    // and silently skip the user-space Into fallback.
    const src_ty = self.builder.getRefType(operand);
    const target_explicit = self.target_type != null;
    const dst_ty = self.target_type orelse .unresolved;

    // Concrete → any: node-aware boxing (an lvalue operand borrows its
    // storage, mirroring protocol erasure's borrow mode). Handled ahead
    // of the plan switch — the `.coerce` ladder's box arm is node-less
    // and would always spill a copy. A PROTOCOL source is exempt: it has
    // no storage to borrow, and `xx p : any` is the CONCRETE view
    // (protocol_to_any — the {ctx, typeId} prefix) rather than a box.
    if (dst_ty == .any and src_ty != .any and src_ty != .unresolved and
        self.getProtocolInfo(src_ty) == null)
    {
        return boxAnyOf(self, operand, src_ty, operand_node);
    }

    // A set destination is reached from a MEMBER and from nothing else: the
    // formation arm lifts the member into the slot, and no other source has a tag
    // to write. An explicit cast asks for that same conversion, so what cannot
    // form a set is refused here rather than reaching an arm that would type
    // foreign bytes as one (spec: Open Sets — formation).
    if (target_explicit and self.isOpenSet(dst_ty)) {
        const cs = self.builder.current_span;
        const span = ast.Span{ .start = cs.start, .end = cs.end };
        if (src_ty == .any) {
            if (self.refuseSetFromAny(dst_ty, span)) return self.builder.constUndef(dst_ty);
        }
        if (self.refuseOpenSetNonMember(src_ty, dst_ty, span)) return self.builder.constUndef(dst_ty);
    }

    // Out of a set: the only conversion is to the member the slot carries, and it
    // can fail. `xx` states no temperament, so it cannot spell that question —
    // and a type that is not a member is not an answer to it at all.
    if (target_explicit and self.isOpenSet(src_ty) and dst_ty != src_ty and dst_ty != .any and dst_ty != .unresolved) {
        const cs = self.builder.current_span;
        const span = ast.Span{ .start = cs.start, .end = cs.end };
        if (self.openSetDeclaresMembership(dst_ty, self.openSetOf(src_ty).?.decl)) {
            if (self.refuseUntemperedDowncast(src_ty, dst_ty, span)) return self.builder.constUndef(dst_ty);
        }
        if (self.refuseOpenSetNonMemberTarget(src_ty, dst_ty, span)) return self.builder.constUndef(dst_ty);
    }

    // PLANNING: the `xx`-head decision (conversions.zig). `.coerce` falls
    // through to the built-in ladder + the user-`Into` fallback below.
    switch (self.coercionResolver().classifyXX(src_ty, dst_ty)) {
        // A boxed value has three spelled readings; `xx` is none of them.
        .unbox_any => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "'xx' does not read a boxed value: '@as({s}, av)' converts it, 'av.({s})' asserts it, '@unbox({s}, av)' reads it unchecked", .{ self.formatTypeName(dst_ty), self.formatTypeName(dst_ty), self.formatTypeName(dst_ty) });
            }
            return self.builder.constUndef(dst_ty);
        },
        // Same type: postfix `.(T)` is a no-op. Dest-inferred `xx` is an
        // error when the operand's own type is already dest; a literal
        // that adopted dest is truncation, not this case.
        .no_op => {
            if (!self.xx_is_postfix and target_explicit) {
                const natural = self.inferExprType(operand_node);
                if (self.module.types.sameType(natural, src_ty) or natural == .unresolved) {
                    if (self.diagnostics) |d| {
                        const cs = self.builder.current_span;
                        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "already '{s}'", .{self.formatTypeName(src_ty)});
                    }
                }
            }
            return self.coerceToType(operand, src_ty, dst_ty);
        },
        // Concrete → Protocol: build protocol value.
        .erase_protocol => return self.buildProtocolErasure(operand, operand_node, src_ty, dst_ty),
        // Interface → interface: one row of the target's conformance table
        // supplies the new dispatch word; ctx and typeId ride across unchanged.
        // An absent row panics here — the soft form reads it as a value
        // instead. Re-erasure is the assertion regime, spelled `p.(Q)`.
        .reerase_protocol => {
            if (!self.xx_is_postfix) return refuseInferredReerase(self, dst_ty);
            return reeraseHandle(self, operand, src_ty, dst_ty, .panic);
        },
        .reerase_protocol_wrap => {
            if (!self.xx_is_postfix) return refuseInferredReerase(self, dst_ty);
            const child = self.module.types.get(dst_ty).optional.child;
            return self.builder.optionalWrap(reeraseHandle(self, operand, src_ty, child, .absent), dst_ty);
        },
        // Concrete → ?Protocol: erase to the protocol CHILD first — node-aware,
        // so the operand's shape classifies from the AST exactly like the
        // plain `s : P` position (borrow-class targets borrow lvalues; the
        // demands name the operand) — then wrap inline. Routing through
        // `.coerce` instead reaches the node-less value-erasure arm below
        // (`.optional_wrap` → `.erase_protocol`), which cannot see the
        // operand's shape.
        .erase_protocol_wrap => {
            const child = self.module.types.get(dst_ty).optional.child;
            const erased = self.buildProtocolErasure(operand, operand_node, src_ty, child);
            if (self.builder.getRefType(erased) == child) {
                return self.builder.optionalWrap(erased, dst_ty);
            }
            // Erasure made no progress (e.g. a builtin source whose concrete
            // type name is not node-inferable) — fall through to the generic
            // ladder below, whose value arm erases via a self-contained copy.
        },
        // Protocol → pointer: recover the typed ctx pointer (field 0) of the
        // `{ ctx, typeId, vtable_ptr }` value.
        .protocol_to_pointer => {
            // A pointer-to-PROTOCOL target is a type lie, not a recovery:
            // ctx addresses the CONCRETE value, so `s.(*Sizable)` would
            // return concrete bytes typed as a protocol-value pointer —
            // and `*P` dispatch would load them as {ctx, typeId, vtable}.
            // Refuse with the two honest spellings.
            if (!dst_ty.isBuiltin()) {
                const dinfo = self.module.types.get(dst_ty);
                if (dinfo == .pointer and self.getProtocolInfo(dinfo.pointer.pointee) != null) {
                    if (self.diagnostics) |d| {
                        const cs = self.builder.current_span;
                        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "the ctx recovery yields a pointer to the CONCRETE value, so its target must be the concrete pointee type (e.g. `p.(*YourConcrete)` or `p.(*void)`); to point at the handle itself, take its address with prefix `*`", .{});
                    }
                    return self.builder.emit(.{ .placeholder = self.module.types.internString("protocol-ptr-recovery") }, dst_ty);
                }
            }
            const void_ptr_ty = self.module.types.ptrTo(.void);
            const ctx_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
            if (dst_ty == void_ptr_ty) return ctx_ref;
            return self.builder.emit(.{ .bitcast = .{ .operand = ctx_ref, .from = void_ptr_ty, .to = dst_ty } }, dst_ty);
        },
        // Protocol → @Protocol: the modeled raw-view retrieval. Built
        // FIELD-WISE — {ctx, typeId} is the prefix of BOTH protocol
        // layouts, so the view can never carry a wrong word and the result
        // is a real value that works in any position (a bit reinterpret
        // would width-mismatch on `inline`-kind values, which are wider).
        .protocol_to_raw => {
            const void_ptr_ty = self.module.types.ptrTo(.void);
            const ctx_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
            const tid_ref = self.protocolTypeIdWord(operand);
            var fields = [2]Ref{ ctx_ref, tid_ref };
            return self.builder.structInit(&fields, dst_ty);
        },
        // Protocol → any: the concrete view (the downcast / protocol type
        // switch base).
        .protocol_to_any => return protocolToAnyView(self, operand),
        .coerce => {},
    }

    // Dest-inferred `xx` is an error when implicit conversion already applies.
    if (!self.xx_is_postfix and target_explicit and src_ty != dst_ty) {
        const plan = self.coercionResolver().classify(src_ty, dst_ty);
        if (isGlyphFreeImplicit(plan) and (implicitIntegerConversion(self, src_ty, dst_ty) orelse true)) {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "already converts to '{s}'", .{self.formatTypeName(dst_ty)});
            }
            return self.builder.constUndef(dst_ty);
        }
    }

    if (!target_explicit) return self.coerceExplicit(operand, src_ty, dst_ty);
    return self.lowerCoerce(operand, operand_node, src_ty, dst_ty);
}

fn refuseInferredReerase(self: *Lowering, dst_ty: TypeId) Ref {
    if (self.diagnostics) |d| {
        const cs = self.builder.current_span;
        const target = if (!dst_ty.isBuiltin() and self.module.types.get(dst_ty) == .optional) self.module.types.get(dst_ty).optional.child else dst_ty;
        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "an interface handle re-erases through the assertion 'p.({s})', not 'xx'", .{self.formatTypeName(target)});
    }
    return self.builder.constUndef(dst_ty);
}

/// `@coerce(T, v)`, the ladder `xx` and `.(T)` enter: the compiler's
/// conversions, then `@convert` funded from the context allocator when they
/// make no progress. A pair neither rung takes is a diagnostic.
pub fn lowerCoerce(self: *Lowering, operand: Ref, operand_node: *const Node, src_ty: TypeId, dst_ty: TypeId) Ref {
    if (self.coercionResolver().classify(src_ty, dst_ty) != .none)
        return self.coerceExplicit(operand, src_ty, dst_ty);
    if (self.lowerConvert(operand, operand_node, src_ty, dst_ty, null)) |converted| return converted;
    diagnoseUnmodeledCoercion(self, src_ty, dst_ty, .explicit);
    return self.builder.constUndef(dst_ty);
}

fn implicitIntegerConversion(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) ?bool {
    const src = self.module.types.integerLayout(src_ty) orelse return null;
    const dst = self.module.types.integerLayout(dst_ty) orelse return null;
    return if (src.signed == dst.signed)
        dst.width >= src.width
    else
        !src.signed and dst.width > src.width;
}

pub fn coerceConstant(self: *Lowering, value: inst_mod.ConstantValue, src: TypeId, dst: TypeId) ?inst_mod.ConstantValue {
    if (src == dst) return value;
    if (!(implicitIntegerConversion(self, src, dst) orelse true)) return null;
    if (self.coercionResolver().classify(src, dst).implicitPointer()) return value;
    return switch (self.coercionResolver().classify(src, dst)) {
        .no_op, .integer_retype => value,
        .widen => if (src == .f32 and value == .float)
            .{ .float = @as(f32, @floatCast(value.float)) }
        else
            value,
        .int_to_float => if (value == .int)
            .{ .float = if (self.module.types.integerLayout(src).?.signed)
                @floatFromInt(value.int)
            else
                @floatFromInt(@as(u64, @bitCast(value.int))) }
        else if (value == .zeroinit)
            .{ .float = 0 }
        else
            null,
        else => null,
    };
}

/// `value`, a constant of type `src`, converted to `dst` as the explicit cast
/// converts it at run time. Null when the conversion has no constant result.
pub fn castConstant(self: *Lowering, value: inst_mod.ConstantValue, src: TypeId, dst: TypeId) ?inst_mod.ConstantValue {
    const tt = &self.module.types;
    if (value == .zeroinit) if (scalarZero(self, src)) |zero| return castConstant(self, zero, src, dst);
    switch (self.coercionResolver().classify(src, dst)) {
        .no_op => return value,
        .integer_retype, .widen, .narrow => {
            if (value == .float and Lowering.isFloat(src) and Lowering.isFloat(dst))
                return .{ .float = if (src == .f32 or dst == .f32) @as(f32, @floatCast(value.float)) else value.float };
            const from = tt.integerLayout(src) orelse return null;
            const to = tt.integerLayout(dst) orelse return null;
            if (value != .int) return null;
            return .{ .int = @bitCast(to.normalize(from.normalize(@bitCast(value.int)))) };
        },
        .int_to_float => {
            if (value != .int) return null;
            const from = tt.integerLayout(src).?;
            const raw = from.normalize(@bitCast(value.int));
            return .{ .float = if (dst == .f32) intToFloat(f32, raw, from.signed) else intToFloat(f64, raw, from.signed) };
        },
        .float_to_int => {
            if (value != .float or !std.math.isFinite(value.float)) return null;
            const to = tt.integerLayout(dst).?;
            const t = @trunc(value.float);
            const raw: u64 = if (to.signed) signed: {
                if (t < -9223372036854775808.0 or t >= 9223372036854775808.0) return null;
                break :signed @bitCast(@as(i64, @intFromFloat(t)));
            } else unsigned: {
                if (t < 0 or t >= 18446744073709551616.0) return null;
                break :unsigned @intFromFloat(t);
            };
            return .{ .int = @bitCast(to.normalize(raw)) };
        },
        .bool_to_number => {
            if (value != .boolean) return null;
            return castConstant(self, .{ .int = @intFromBool(value.boolean) }, .u8, dst);
        },
        .number_to_bool => return switch (value) {
            .int => |n| .{ .boolean = n != 0 },
            .float => |f| .{ .boolean = f != 0 },
            else => null,
        },
        .int_to_enum => return castConstant(self, value, src, self.enumBackingType(dst).?),
        .enum_to_int => return castConstant(self, value, self.enumBackingType(src).?, dst),
        .optional_wrap => {
            const child = tt.get(dst).optional.child;
            return self.someConstant(child, castConstant(self, value, src, child) orelse return null);
        },
        else => return null,
    }
}

/// `raw` rounded once to `F`, as the run-time conversion rounds it.
fn intToFloat(comptime F: type, raw: u64, signed: bool) F {
    return if (signed) @floatFromInt(@as(i64, @bitCast(raw))) else @floatFromInt(raw);
}

/// The zero of the scalar `ty` in the constant form its other values take.
fn scalarZero(self: *Lowering, ty: TypeId) ?inst_mod.ConstantValue {
    if (ty == .bool) return .{ .boolean = false };
    if (Lowering.isFloat(ty)) return .{ .float = 0 };
    if (self.module.types.integerLayout(ty) != null) return .{ .int = 0 };
    return null;
}

fn isGlyphFreeImplicit(plan: @import("../conversions.zig").CoercionResolver.CoercionPlan) bool {
    if (plan.implicitPointer()) return true;
    return switch (plan) {
        .integer_retype, .widen, .int_to_float, .array_to_slice, .array_drop_terminator, .array_to_many_ptr, .slice_to_many_ptr, .optional_wrap, .void_to_optional, .member_to_open_set, .optional_to_optional, .struct_elementwise, .slice_len_convert => true,
        else => false,
    };
}

/// Pack-variadic impl matching. Walks `param_impl_pack_map[pack_key]`
/// and returns a call ref when a single pack impl matches `src_ty`'s
/// shape (concrete src closure / fn with the same fixed prefix as
/// the impl's source pack closure). Binds the pack-var to the source's
/// tail param types and the return-var (when generic) to the source's
/// return type, then monomorphises the convert method.
/// Returns null if no pack impls registered for this (proto, dst) or
/// none of them match `src_ty`'s shape.
pub fn tryPackImplMatch(
    self: *Lowering,
    operand: Ref,
    operand_node: *const Node,
    src_ty: TypeId,
    dst_ty: TypeId,
    proto_name: []const u8,
    pack_key: []const u8,
    guard_key: u64,
    alloc: ?Ref,
) ?Ref {
    // PLANNING: select the matching pack impl + its `convert` (registry).
    const match = self.protocolResolver().matchPackImpl(src_ty, pack_key) orelse return null;
    const entry = match.entry;
    const fd = match.convert_fd;
    const src_params = match.src_params;
    const src_ret = match.src_ret;
    const table = &self.module.types;
    // EMISSION: bind the pack tail + ret-var, monomorphise, call (Lowering).

    // Build bindings. Target → dst_ty (already in the protocol's type
    // params), pack-var → src tail TypeIds, ret-var (when generic) →
    // src ret.
    const ent_pack_start = table.get(entry.source_pack_ty).closure.pack_start.?;
    const tail = src_params[ent_pack_start..];
    const tail_owned = self.alloc.dupe(TypeId, tail) catch return null;

    var bindings = std.StringHashMap(TypeId).init(self.alloc);
    defer bindings.deinit();
    const pd = self.program_index.lookup(.protocol_ast, proto_name) orelse return null;
    bindings.put(pd.type_params[0].name, dst_ty) catch return null;
    if (entry.ret_var_name) |rv| bindings.put(rv, src_ret) catch return null;

    bindings.put(entry.pack_var_name, table.intern(.{ .pack = .{ .elements = tail_owned } })) catch return null;

    // Mangled name keyed on the CONCRETE source so distinct shapes
    // monomorphise separately. Same scheme as the concrete path:
    // "<src>.convert__<dst>".
    const mangled = std.fmt.allocPrint(self.alloc, "{s}.convert__{s}", .{
        self.mangleTypeName(src_ty), self.mangleTypeName(dst_ty),
    }) catch return null;

    self.convert_reentrancy.put(guard_key, {}) catch {};
    defer _ = self.convert_reentrancy.remove(guard_key);

    const fid = self.monomorphizeFunction(fd, mangled, &bindings) orelse return null;
    const func = &self.module.functions.items[@intFromEnum(fid)];
    const ret_ty = func.ret;
    const params = func.params;
    const final_args = intoConvertArgs(self, operand, operand_node, func, alloc) orelse return operand;
    self.coerceCallArgs(final_args, params);
    return self.builder.call(fid, final_args, ret_ty);
}

/// `@convert(T, v, alloc)`: the `impl Into(T) for S` call, `convert`
/// monomorphized for the pair and funded from `alloc` (the context allocator
/// when null). Null when no impl exists; a visibility or duplicate fault is a
/// diagnostic.
pub fn lowerConvert(self: *Lowering, operand: Ref, operand_node: *const Node, src_ty: TypeId, dst_ty: TypeId, alloc: ?Ref) ?Ref {
    // Reentrancy guard — pack (src, dst) into a u64.
    const guard_key: u64 = (@as(u64, src_ty.index()) << 32) | @as(u64, dst_ty.index());
    if (self.convert_reentrancy.contains(guard_key)) {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, operand_node.span, "recursive conversion from '{s}' to '{s}'", .{
                self.mangleTypeName(src_ty), self.mangleTypeName(dst_ty),
            });
        }
        return operand;
    }

    // Build lookup key: "Into\x00<dst_mangled>\x00<src_mangled>".
    // Hardcoded to the "Into" protocol for v1. Generalising to other
    // parameterised protocols would walk protocol_decl_map looking for
    // protocols that take a single type-param and have a `convert` method.
    const proto_name = "Into";
    const pd = self.program_index.lookup(.protocol_ast, proto_name) orelse return null;
    if (pd.type_params.len != 1) return null;

    var key_buf = std.ArrayList(u8).empty;
    key_buf.appendSlice(self.alloc, proto_name) catch return null;
    key_buf.append(self.alloc, 0) catch return null;
    key_buf.appendSlice(self.alloc, self.mangleTypeName(dst_ty)) catch return null;
    key_buf.append(self.alloc, 0) catch return null;
    key_buf.appendSlice(self.alloc, self.mangleTypeName(src_ty)) catch return null;
    const key = key_buf.items;

    // Pack-only key (proto + dst) — used if the concrete lookup misses.
    // Same prefix as the concrete key, minus the `\x00<src_mangled>` tail.
    const dst_mangled_len = self.mangleTypeName(dst_ty).len;
    const pack_key = key_buf.items[0 .. proto_name.len + 1 + dst_mangled_len];

    const entries_opt = self.param_impl_map.get(key);
    const has_concrete = entries_opt != null and entries_opt.?.items.len > 0;
    if (!has_concrete) {
        // Concrete miss — try the pack map before emitting a diagnostic.
        if (self.tryPackImplMatch(operand, operand_node, src_ty, dst_ty, proto_name, pack_key, guard_key, alloc)) |result| {
            return result;
        }
        return null;
    }
    const entries = entries_opt.?;

    // Filter by import visibility: only impls in modules that the current
    // file transitively imports (or the current file itself) are reachable.
    // Falls open when import_graph isn't wired (e.g. comptime callers).
    var visible_impls = std.ArrayList(ParamImplEntry).empty;
    defer visible_impls.deinit(self.alloc);
    self.protocolResolver().findVisibleImpls(entries.items, &visible_impls);

    if (visible_impls.items.len == 0) {
        if (self.diagnostics) |diags| {
            const saved = diags.current_source_file;
            diags.current_source_file = operand_node.source_file orelse self.current_source_file;
            defer diags.current_source_file = saved;
            diags.addFmt(.err, operand_node.span, "no visible xx conversion from '{s}' to '{s}' — impl exists in another module but is not imported", .{
                self.mangleTypeName(src_ty), self.mangleTypeName(dst_ty),
            });
        }
        return operand;
    }
    if (visible_impls.items.len > 1) {
        if (self.diagnostics) |diags| {
            const saved = diags.current_source_file;
            diags.current_source_file = operand_node.source_file orelse self.current_source_file;
            defer diags.current_source_file = saved;
            diags.addFmt(.err, operand_node.span, "duplicate xx conversion from '{s}' to '{s}': impls in {s} and {s}", .{
                self.mangleTypeName(src_ty),            self.mangleTypeName(dst_ty),
                visible_impls.items[0].defining_module, visible_impls.items[1].defining_module,
            });
        }
        return operand;
    }
    const entry = visible_impls.items[0];

    // Find the `convert` method on this impl.
    var convert_fd: ?*const ast.FnDecl = null;
    for (entry.methods) |m| {
        if (std.mem.eql(u8, m.name, "convert")) {
            convert_fd = m;
            break;
        }
    }
    const fd = convert_fd orelse return null;

    // Bind Target → dst_ty.
    var bindings = std.StringHashMap(TypeId).init(self.alloc);
    defer bindings.deinit();
    bindings.put(pd.type_params[0].name, dst_ty) catch return null;

    // Mangled name: "<src>.convert__<dst>".
    const mangled = std.fmt.allocPrint(self.alloc, "{s}.convert__{s}", .{
        self.mangleTypeName(src_ty), self.mangleTypeName(dst_ty),
    }) catch return null;

    self.convert_reentrancy.put(guard_key, {}) catch {};
    defer _ = self.convert_reentrancy.remove(guard_key);

    const fid = self.monomorphizeFunction(fd, mangled, &bindings) orelse return null;
    const func = &self.module.functions.items[@intFromEnum(fid)];
    const ret_ty = func.ret;
    const params = func.params;
    const final_args = intoConvertArgs(self, operand, operand_node, func, alloc) orelse return operand;
    self.coerceCallArgs(final_args, params);
    return self.builder.call(fid, final_args, ret_ty);
}

/// `convert(self, alloc)` — `alloc` or `context.allocator`.
fn intoConvertArgs(self: *Lowering, operand: Ref, operand_node: *const Node, func: *const Function, alloc: ?Ref) ?[]Ref {
    const alloc_ty = self.module.types.findByName(self.module.types.internString("Allocator"));
    const alloc_ref = if (alloc) |r| r else self.ambientAllocator() orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, operand_node.span, "this conversion funds from context.allocator — import std or write '@convert(T, v, <alloc>)'", .{});
        }
        return null;
    };
    var alloc_val = alloc_ref;
    if (alloc_ty) |aty| {
        const got = self.builder.getRefType(alloc_val);
        if (!self.module.types.sameType(got, aty)) {
            alloc_val = self.coerceOrErase(alloc_val, got, aty, operand_node);
        }
    }
    const pair = self.alloc.alloc(Ref, 2) catch return null;
    pair[0] = operand;
    pair[1] = alloc_val;
    return self.prependCtxIfNeeded(func, pair);
}

/// True for expression shapes that name an addressable storage location
/// (variables, fields, array elements, dereferenced pointers). Used by
/// `xx <struct-typed expr>` to decide between the borrow arms (lvalue →
/// take the address) and a concrete rvalue, which an I-typed target refuses.
pub fn isLvalueExpr(self: *Lowering, node: *const Node) bool {
    return switch (node.data) {
        .identifier, .deref_expr => true,
        // A field access denotes storage only if its BASE does: `obj.b` and
        // `arr[i].b` name a slot, but `make_pair().b` reads a field of a
        // TEMPORARY. Classifying a call-result base as lvalue re-lowered the
        // AST for the borrow — double-calling `make_pair()` and handing the
        // erasure a garbage address (the value fallback of lowerExprAsPtr).
        // A rvalue base routes to the self-contained copy path instead.
        .call => if (self.fieldCall(node)) |c|
            (if (self.fieldProjection(c)) |field| self.isLvalueExpr(field.object) else false)
        else
            false,
        .field_access => |fa| self.isLvalueExpr(fa.object),
        // A comptime pack index (`pack[i]`) is not an lvalue: a pack has no
        // runtime storage — `pack[i]` resolves to the call-site arg node.
        // Taking its address via `lowerExprAsPtr` would lower the bare pack as
        // a value and trip the pack-as-value error. An I-typed target then
        // refuses the materialized rvalue.
        // A non-pack index (array/slice element) is a genuine lvalue.
        //
        // Decide pack-ness with the SAME predicate the value path uses —
        // `packArgNodeAt` (the `pack_arg_nodes` substitution map) — NOT
        // `isPackName` (the `pack_param_count` map). The two maps are set
        // together in the pack-fn path but the comptime-call path
        // (comptime.zig) installs only `pack_arg_nodes`; using `isPackName`
        // there would disagree with the value substitution and mis-route the
        // erasure. Sharing one predicate keeps the value/lvalue paths from
        // diverging on what counts as a pack element.
        .index_expr => |ie| self.packArgNodeAt(&ie) == null and self.isLvalueExpr(ie.object),
        else => false,
    };
}

/// True when `node` is an identifier bound to a by-VALUE SSA binding — a
/// scope entry with no alloca of its own that is NOT a by-ref `*x`
/// capture and NOT an `inline for` pack alias. These are the loop /
/// match / catch captures and local `::` consts: each is semantically a
/// COPY, so a protocol erasure must not see through its defining load to
/// the storage the value was read FROM (the container element / the
/// matched payload). The erasure materializes such operands instead of
/// borrowing.
pub fn isByValueBindingIdent(self: *Lowering, node: *const Node) bool {
    if (node.data != .identifier) return false;
    const scope = self.scope orelse return false;
    const binding = scope.lookup(node.data.identifier.name) orelse return false;
    return !binding.is_alloca and !binding.is_ref_capture and binding.alias_node == null;
}

/// Build a protocol value from a concrete value via xx conversion.
/// Coerce `val` (type `src`) to `dst`: if `dst` is a protocol, `xx`-erase
/// the concrete value into it; otherwise fall back to numeric/struct
/// coercion. Used to materialize a pack into a protocol-typed tuple field.
pub fn coerceOrErase(self: *Lowering, val: Ref, src: TypeId, dst: TypeId, node: *const Node) Ref {
    if (src == dst) return val;
    if (!dst.isBuiltin()) {
        const di = self.module.types.get(dst);
        if (di == .@"struct" and di.@"struct".is_protocol) {
            return self.buildProtocolErasure(val, node, src, dst);
        }
    }
    return self.coerceToType(val, src, dst);
}

/// Derive the storage ADDRESS the already-lowered `operand` value was read
/// from, WITHOUT re-lowering the operand's AST node. Re-lowering an lvalue
/// expression evaluates any side effect it carries a second time — for
/// `xx arr[next()]` the index call `next()` ran once for the value and once
/// for the borrow, and the two evaluations could denote DIFFERENT elements.
/// Instead, walk the value's defining instruction:
///   - `.load` / `.deref`  → the pointer it read through (already evaluated)
///   - `.global_get`       → a re-emitted `global_addr` of the same global
///   - `.struct_get`       → recurse on the base, then GEP the same field
///   - `.index_get`        → `index_gep` reusing the SAME base/index refs
/// Only address arithmetic is re-emitted — never user code. Returns null
/// when the value did not come through named storage (function params,
/// block params, call results, …); the caller decides the fallback.
pub fn refStorageAddress(self: *Lowering, ref: Ref) ?Ref {
    const op = self.builder.getRefOp(ref) orelse return null;
    switch (op) {
        .load => |u| return u.operand,
        .deref => |u| return u.operand,
        .global_get => |gid| {
            const val_ty = self.builder.getRefType(ref);
            if (val_ty == .unresolved) return null;
            return self.builder.emit(.{ .global_addr = gid }, self.module.types.ptrTo(val_ty));
        },
        .struct_get => |fa| {
            const base_addr = self.refStorageAddress(fa.base) orelse return null;
            const field_ty = self.builder.getRefType(ref);
            if (field_ty == .unresolved) return null;
            const base_ty = fa.base_type orelse self.builder.getRefType(fa.base);
            return self.builder.structGepTyped(base_addr, fa.field_index, self.module.types.ptrTo(field_ty), base_ty);
        },
        .index_get => |b| {
            // `index_gep` re-uses the SAME already-evaluated base/index refs.
            // A pointer-shaped base (slice / many-pointer / `*[N]T` / string)
            // is GEPed directly. An aggregate ARRAY VALUE base — a module
            // global or a struct-field array value-lowers as `index_get`
            // over the loaded aggregate — has no address of its own, so
            // RECURSE on the base ref to recover the storage the aggregate
            // was loaded from (`global_get` → `global_addr`, `struct_get` →
            // GEP chain) and index THAT. emitIndexGep's pointer branch GEPs
            // by element type, so the array's start address indexes
            // correctly. Without the recursion these shapes fell back to
            // re-lowering the AST — re-running the index's side effects and
            // possibly borrowing a different element than the value read.
            const elem_ty = self.builder.getRefType(ref);
            if (elem_ty == .unresolved) return null;
            const base_ty = self.builder.getRefType(b.lhs);
            var base = b.lhs;
            switch (self.module.types.get(base_ty)) {
                .string, .slice, .pointer, .many_pointer => {},
                .array => base = self.refStorageAddress(b.lhs) orelse return null,
                else => return null,
            }
            return self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = b.rhs } }, self.module.types.ptrTo(elem_ty));
        },
        else => return null,
    }
}

/// The `any` view of a protocol value (§7.3): its `{ctx, typeId}` prefix
/// IS an any `{data, typeId}`, so the view names the CONCRETE receiver.
pub fn protocolToAnyView(self: *Lowering, operand: Ref) Ref {
    const void_ptr_ty = self.module.types.ptrTo(.void);
    const ctx_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
    const tid_ref = self.protocolTypeIdWord(operand);
    return self.builder.makeAny(tid_ref, ctx_ref);
}

/// An any view borrows exact typed storage. Addressable lvalues retain their
/// address; other values spill to storage that lives for the enclosing frame.
pub fn boxAnyOf(self: *Lowering, val: Ref, src_ty: TypeId, node: ?*const Node) Ref {
    // Protocol and open-set views retain the concrete referent identity (§7.3).
    if (self.getProtocolInfo(src_ty) != null) return protocolToAnyView(self, val);
    if (self.isOpenSet(src_ty)) return self.openSetAnyView(src_ty, val, node);
    if (src_ty == .void) {
        // A void has no storage; the view is `{void, null}`.
        return self.builder.boxAnyAt(self.builder.constNull(self.module.types.ptrTo(.void)), .void);
    }
    if (node) |n| {
        if (self.isLvalueExpr(n) and !self.isByValueBindingIdent(n)) {
            if (self.refStorageAddress(val)) |addr| {
                return self.builder.boxAnyAt(addr, src_ty);
            }
        }
    }
    const slot = self.builder.alloca(src_ty);
    self.builder.store(slot, val);
    return self.builder.boxAnyAt(slot, src_ty);
}

/// Integer constant expressions retain each IR operation's width and signedness.
pub fn foldedInt(self: *Lowering, ref: Ref) ?i64 {
    const layout = self.module.types.integerLayout(self.builder.getRefType(ref)) orelse return null;
    const op = self.builder.getRefOp(ref) orelse return null;
    const raw: i64 = switch (op) {
        .const_int => |v| v,
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .shl, .shr => |b| blk: {
            const l = self.foldedInt(b.lhs) orelse return null;
            const r = self.foldedInt(b.rhs) orelse return null;
            const lu: u64 = @bitCast(l);
            const ru: u64 = @bitCast(r);
            break :blk switch (op) {
                .add => l +% r,
                .sub => l -% r,
                .mul => l *% r,
                .div => if (layout.signed)
                    std.math.divTrunc(i64, l, r) catch return null
                else
                    @bitCast(std.math.divTrunc(u64, lu, ru) catch return null),
                .mod => if (layout.signed)
                    std.math.rem(i64, l, r) catch return null
                else
                    @bitCast(std.math.rem(u64, lu, ru) catch return null),
                .bit_and => l & r,
                .bit_or => l | r,
                .bit_xor => l ^ r,
                .shl, .shr => shifted: {
                    if (r < 0 or r >= layout.width) return null;
                    const shift: u6 = @intCast(r);
                    break :shifted if (op == .shl) l << shift else if (layout.signed) l >> shift else @bitCast(lu >> shift);
                },
                else => unreachable,
            };
        },
        .neg => |u| 0 -% (self.foldedInt(u.operand) orelse return null),
        .bit_not => |u| ~(self.foldedInt(u.operand) orelse return null),
        .widen, .narrow, .bitcast => |c| self.foldedInt(c.operand) orelse return null,
        .length => |u| blk: {
            const oty = self.builder.getRefType(u.operand);
            if (oty.isBuiltin() or self.module.types.get(oty) != .array) return null;
            break :blk @intCast(self.module.types.get(oty).array.length);
        },
        else => return null,
    };
    return @bitCast(layout.normalize(@bitCast(raw)));
}

/// Folded element count of an already-lowered slice value, when the IR
/// still carries it as a constant (`subslice` hi-lo or `array_to_slice`).
fn foldedSliceLen(self: *Lowering, val: Ref) ?u64 {
    const op = self.builder.getRefOp(val) orelse return null;
    switch (op) {
        .subslice => |ss| {
            const lo = self.foldedInt(ss.lo) orelse return null;
            const hi = self.foldedInt(ss.hi) orelse return null;
            if (hi < lo) return 0;
            return @intCast(hi - lo);
        },
        .array_to_slice => |u| {
            const aty = self.builder.getRefType(u.operand);
            if (aty.isBuiltin() or self.module.types.get(aty) != .array) return null;
            return self.module.types.get(aty).array.length;
        },
        else => return null,
    }
}

fn diagnoseLenWord(self: *Lowering, n: u64, dst_ty: TypeId, kind: []const u8) void {
    const d = self.diagnostics orelse return;
    const cs = self.builder.current_span;
    const len_ty = self.module.types.lenTypeOf(dst_ty);
    d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "{s} {} does not fit the {s} length word of '{s}'", .{
        kind, n, self.formatTypeName(len_ty), self.formatTypeName(dst_ty),
    });
}

pub fn refuseImplicitLenNarrow(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) bool {
    const src_len = self.module.types.lenTypeOf(src_ty);
    const dst_len = self.module.types.lenTypeOf(dst_ty);
    if (self.module.types.lenWordContains(dst_len, src_len)) return false;
    if (self.diagnostics) |d| {
        const cs = self.builder.current_span;
        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot implicitly convert '{s}' to '{s}': a non-constant length does not fit a narrower length word", .{
            self.formatTypeName(src_ty), self.formatTypeName(dst_ty),
        });
    }
    return true;
}

pub fn refuseLenWord(self: *Lowering, n: u64, dst_ty: TypeId) bool {
    if (self.module.types.lenFitsWord(self.module.types.lenTypeOf(dst_ty), n)) return false;
    diagnoseLenWord(self, n, dst_ty, "length");
    return true;
}

/// Refuse `[N]T → @Slice(T, Len)` when `N` overflows the destination's length
/// word: the header would carry a truncated length and every read through the
/// slice would stop short.
pub fn refuseArrayLenWord(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) bool {
    const n: u64 = self.module.types.get(src_ty).array.length;
    if (self.module.types.lenFitsWord(self.module.types.lenTypeOf(dst_ty), n)) return false;
    diagnoseLenWord(self, n, dst_ty, "array length");
    return true;
}

/// Coerce an already-lowered ARRAY value `val` (of array type `src_ty`) into a
/// slice `dst_ty` as a ZERO-COPY VIEW when the array is addressable, mirroring
/// the explicit-subslice path. An ADDRESSABLE array (local, global, struct
/// field, `*[N]T` deref) has its storage address recovered via the
/// `refStorageAddress` walk (re-emits only address arithmetic, never re-runs a
/// side-effecting index) and a `subslice [0..len]` built over that pointer with
/// `base_ty = [*]elem` — so both backends take their many-pointer subslice arm
/// (a genuine view, no alloca+store). The explicit `arr[0..N]` syntax already
/// aliases; without this the IMPLICIT `fill(arr)` coercion would silently COPY
/// via `array_to_slice`, making `arr` and `arr[0..]` differ.
///
/// Returns null when the array is a NON-ADDRESSABLE rvalue (a call result, a
/// literal, a by-value binding — `refStorageAddress` yields null). The caller
/// decides the fallback by CONTEXT: for a call ARGUMENT the temp lives for the
/// call's duration, so the copying `array_to_slice` op is SOUND; for a STORED
/// slice (`s : []T = makeArr()`) the copy would be a dangling view and must be
/// rejected like 0225.
pub fn arrayToSliceView(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId) ?Ref {
    if (src_ty.isBuiltin() or self.module.types.get(src_ty) != .array) return null;
    if (self.refuseArrayLenWord(src_ty, dst_ty)) return self.builder.constUndef(dst_ty);
    const addr = self.refStorageAddress(val) orelse return null;
    const info = self.module.types.get(src_ty).array;
    const elem_ty = info.element;
    // The view keeps the destination's terminator when the array holds it.
    const keeps_terminator = if (self.module.types.sliceInfoOf(dst_ty)) |ds|
        ds.sentinel != null and ds.sentinel == info.sentinel
    else
        false;
    const slice_ty = if (keeps_terminator) dst_ty else self.module.types.sliceOfLen(elem_ty, self.module.types.lenTypeOf(dst_ty));
    const lo = self.builder.constInt(0, .i64);
    const hi = self.builder.constInt(@intCast(info.length), .i64);
    return self.builder.emit(.{ .subslice = .{
        .base = addr,
        .lo = lo,
        .hi = hi,
        .base_ty = self.module.types.manyPtrTo(elem_ty),
    } }, slice_ty);
}

/// `p.(Q)` between interfaces (§6.4). The conformance check and the result's
/// dispatch word are one runtime read: the result reuses `p`'s ctx and typeId
/// and takes the table's vtable-or-null. `on_absent` is what a null row means
/// here — the unconsumed form panics, the soft form answers the null handle,
/// whose ctx is the `?Q` absent sentinel.
fn reeraseHandle(self: *Lowering, operand: Ref, src_ty: TypeId, dst_ty: TypeId, on_absent: enum { panic, absent }) Ref {
    const void_ptr = self.module.types.ptrTo(.void);
    const ctx = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr);
    const tid = self.protocolTypeIdWord(operand);
    const table = self.conformanceTable(dst_ty) orelse return self.builder.constUndef(dst_ty);
    const vt = self.builder.emit(.{ .conformance_lookup = .{
        .contract = dst_ty,
        .tag = tid,
        .table = table,
        .row = .vtable,
    } }, void_ptr);
    const present = self.builder.emit(.{ .cmp_ne = .{ .lhs = vt, .rhs = self.builder.constNull(void_ptr) } }, .bool);
    const eff_ctx = switch (on_absent) {
        .panic => blk: {
            refuseAbsentReerasure(self, present, dst_ty);
            break :blk ctx;
        },
        .absent => blk: {
            const some_bb = self.freshBlock("reerase.some");
            const none_bb = self.freshBlock("reerase.none");
            const merge_bb = self.freshBlockWithParams("reerase.merge", &.{void_ptr});
            self.builder.condBr(present, some_bb, &.{}, none_bb, &.{});
            self.builder.switchToBlock(some_bb);
            self.builder.br(merge_bb, &.{ctx});
            self.builder.switchToBlock(none_bb);
            self.builder.br(merge_bb, &.{self.builder.constNull(void_ptr)});
            self.builder.switchToBlock(merge_bb);
            break :blk self.builder.blockParam(merge_bb, 0, void_ptr);
        },
    };
    _ = src_ty;
    var fields = [3]Ref{ eff_ctx, tid, vt };
    return self.builder.structInit(&fields, dst_ty);
}

/// Stop the program when a re-erasure finds no row: the spelled
/// `@assert(<row present>, "<literal naming the target>")`, synthesized as an
/// identifier call so the assertion carries the site.
fn refuseAbsentReerasure(self: *Lowering, present: Ref, dst_ty: TypeId) void {
    const cs = self.builder.current_span;
    const span = ast.Span{ .start = cs.start, .end = cs.end };
    const src = self.current_source_file;
    // A declared default lowers with no scope; the bound bool lives on a
    // child scope installed for the synthesized call.
    var tmp = Scope.init(self.alloc, self.scope, &self.next_binding_id);
    defer tmp.deinit();
    const saved = self.scope;
    self.scope = &tmp;
    defer self.scope = saved;
    var buf: [48]u8 = undefined;
    const nm = std.fmt.bufPrint(&buf, "$conforms_{d}", .{self.block_counter}) catch "$conforms";
    self.block_counter += 1;
    const owned = self.alloc.dupe(u8, nm) catch return;
    tmp.put(owned, .{ .ref = present, .ty = .bool, .is_alloca = false });
    const ok = self.synthNode(.{ .identifier = .{ .name = owned } }, span, src);
    const text = std.fmt.allocPrint(self.alloc, "re-erasure to '{s}' failed", .{self.formatTypeName(dst_ty)}) catch return;
    const msg = self.synthNode(.{ .string_literal = .{ .raw = text } }, span, src);
    const callee = self.synthNode(.{ .identifier = .{ .name = "@assert" } }, span, src);
    const args = self.alloc.dupe(*Node, &.{ ok, msg }) catch return;
    _ = self.lowerCall(&.{ .callee = callee, .args = args });
}

pub fn buildProtocolErasure(self: *Lowering, operand: Ref, operand_node: *const Node, src_ty: TypeId, dst_ty: TypeId) Ref {
    const dst_info = self.module.types.get(dst_ty);
    if (dst_info != .@"struct") return operand;
    if (self.refuseValuelessProtocol(dst_ty, operand_node.span, "make a value of")) return self.builder.constUndef(dst_ty);
    const proto_name = self.module.types.getString(dst_info.@"struct".name);

    // An interface handle IS the target already; copy it.
    if (src_ty == dst_ty) return operand;

    var concrete_ptr = operand;
    var concrete_type_name: ?[]const u8 = null;
    var concrete_ty: TypeId = src_ty;
    var is_rvalue = false;

    if (!src_ty.isBuiltin()) {
        const src_info = self.module.types.get(src_ty);
        if (src_info == .pointer and self.module.types.sameType(src_info.pointer.pointee, dst_ty)) {
            // `*I` at an `I` target: the handle is the pointee, so LOAD it.
            // This arm stands ahead of the pointer-erasure arm, which would
            // otherwise erase the handle's own storage as a concrete value.
            return self.builder.load(operand, dst_ty);
        }
        if (src_info == .pointer) {
            const pointee = src_info.pointer.pointee;
            concrete_type_name = self.resolveConcreteTypeName(pointee);
            concrete_ty = pointee;
        } else if (src_info == .@"struct") {
            concrete_type_name = self.module.types.getString(src_info.@"struct".name);
            concrete_ty = src_ty;
            if (self.isLvalueExpr(operand_node)) {
                if (self.isByValueBindingIdent(operand_node)) {
                    // A by-VALUE SSA binding (`for x in arr`, a match/catch
                    // capture, a `::` const) is semantically a COPY of the
                    // element it was read from. Deriving the borrow address
                    // through `refStorageAddress` would see through the
                    // binding's defining load to the CONTAINER's storage —
                    // making the handle alias the original element and mutate
                    // it, indistinguishable from the by-ref `*x` form.
                    // Materialize the copy instead so mutations land in the
                    // per-iteration copy. By-ref captures never reach here —
                    // their binding is pointer-typed, handled by the pointer
                    // arm above.
                    const slot = self.builder.alloca(src_ty);
                    self.builder.store(slot, operand);
                    concrete_ptr = slot;
                } else {
                    // Borrow the address the VALUE lowering already read
                    // through — never re-lower the AST node, which would
                    // re-run any side effect in the expression
                    // (`xx arr[next()]` called `next()` twice, and the two
                    // calls could pick different elements).
                    // `lowerExprAsPtr` remains as the fallback when no
                    // address is derivable from the defining instruction
                    // (e.g. a struct param bound directly to its SSA ref) —
                    // that fallback re-lowers the AST, so it is only safe for
                    // shapes whose re-lowering has no side effects; every
                    // effectful lvalue shape (loads, global reads, field/index
                    // chains over them) is covered by refStorageAddress above.
                    concrete_ptr = self.refStorageAddress(operand) orelse self.lowerExprAsPtr(operand_node);
                }
            } else {
                is_rvalue = true;
            }
        }
    }

    if (concrete_type_name == null) {
        concrete_type_name = self.inferConcreteTypeName(operand_node);
        if (concrete_type_name != null) is_rvalue = true;
    }

    if (concrete_type_name) |ctn| {
        if (is_rvalue) {
            self.refuseRvalueInterfaceErasure(proto_name, operand_node.span);
            return self.builder.emit(.{ .placeholder = self.module.types.internString("protocol-erasure") }, dst_ty);
        }
        return self.buildProtocolValue(concrete_ptr, proto_name, ctn, dst_ty, concrete_ty);
    }
    return operand;
}

/// An interface-typed target never invents a temp: a concrete rvalue has no
/// storage of its own to borrow.
pub fn refuseRvalueInterfaceErasure(self: *Lowering, proto_name: []const u8, span: ast.Span) void {
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "cannot borrow a temporary into a '{s}' handle — bind the value where it lives, or write it through 'mem.make' and use the handle over that", .{proto_name});
    }
}

/// `null` is the absence of `?T` and the null pointer. It does not type at a
/// non-optional value slot. Pointer-shaped slots (`*T`, `[*]T`, a function
/// type) take `null` as the null address.
pub fn refuseNullAtNonOptional(self: *Lowering, dst_ty: TypeId, span: ast.Span) bool {
    if (dst_ty == .void or dst_ty == .unresolved) return false;
    if (!dst_ty.isBuiltin()) {
        switch (self.module.types.get(dst_ty)) {
            .optional, .pointer, .many_pointer, .function => return false,
            else => {},
        }
    }
    if (self.diagnostics) |d| {
        const shown = self.formatTypeName(dst_ty);
        const id = d.addFmtId(.err, span, "cannot assign 'null' to '{s}'", .{shown});
        d.addHelpFmt(id, span, null, "'null' is the absence of '?{s}'", .{shown});
    }
    return true;
}

/// Concrete storage address → borrowed protocol VIEW `*P` (the erasure
/// model's view coercion). Builds the borrow-mode protocol
/// value with `ctx = concrete_addr`, spills it to a frame slot, and returns
/// the slot's address. The pointee protocol value ALIASES the concrete
/// storage — mutations through the view are visible to the original; the
/// slot itself is a frame temp whose lifetime covers the call/statement.
/// Returns null when `view_ptr_ty` is not pointer-to-protocol, the source is
/// untyped raw storage, or the concrete type name is not resolvable (caller
/// falls through to its default path). Non-conformance is diagnosed inside
/// buildProtocolValue.
pub fn viewOfConcreteAddr(self: *Lowering, concrete_addr: Ref, concrete_ty: TypeId, view_ptr_ty: TypeId) ?Ref {
    if (view_ptr_ty.isBuiltin()) return null;
    const vinfo = self.module.types.get(view_ptr_ty);
    if (vinfo != .pointer) return null;
    const proto_ty = vinfo.pointer.pointee;
    const proto_info = self.getProtocolInfo(proto_ty) orelse return null;
    // `*void` is untyped raw storage — the allocator's bytes-level result, not
    // an object of some conformer type. A view is BUILT over a value; storage
    // is merely reinterpreted, so `*void → *P` is a pointer cast to room for a
    // protocol handle (an ordinary copyable value, §5.3a).
    if (concrete_ty == .void) return null;
    const ctn = self.resolveConcreteTypeName(concrete_ty) orelse return null;
    const pv = self.buildProtocolValue(concrete_addr, proto_info.name, ctn, proto_ty, concrete_ty);
    const slot = self.builder.alloca(proto_ty);
    self.builder.store(slot, pv);
    const slot_ty = self.builder.getRefType(slot);
    if (slot_ty == view_ptr_ty) return slot;
    return self.builder.emit(.{ .bitcast = .{ .operand = slot, .from = slot_ty, .to = view_ptr_ty } }, view_ptr_ty);
}

/// Try to infer the concrete type name from an AST node (for struct literals etc.)
pub fn inferConcreteTypeName(self: *Lowering, node: *const Node) ?[]const u8 {
    return switch (node.data) {
        .struct_literal => |sl| if (sl.struct_name) |n| n else null,
        .unary_op => |uop| if (uop.op == .address_of) self.inferConcreteTypeName(uop.operand) else null,
        .identifier => |id| blk: {
            // Check if identifier's type resolves to a struct
            if (self.scope) |scope| {
                if (scope.lookup(id.name)) |binding| {
                    if (!binding.ty.isBuiltin()) {
                        const bi = self.module.types.get(binding.ty);
                        if (bi == .@"struct") break :blk self.module.types.getString(bi.@"struct".name);
                        if (bi == .pointer) {
                            const pointee = bi.pointer.pointee;
                            if (!pointee.isBuiltin()) {
                                const pi = self.module.types.get(pointee);
                                if (pi == .@"struct") break :blk self.module.types.getString(pi.@"struct".name);
                            }
                        }
                    }
                }
            }
            break :blk null;
        },
        else => null,
    };
}

/// Generate a mini-dispatch for unboxing Any to f64 when the value might be f32 or f64.
/// Uses alloca-based merge: create result slot, branch, store in each arm, load after merge.
pub fn lowerAnyToF64Dispatch(self: *Lowering, any_val: Ref) Ref {
    // Create result alloca BEFORE the branch
    const result_slot = self.builder.alloca(.f64);

    // Extract type tag from Any
    const tag = self.builder.structGet(any_val, 1, .i64);

    const f32_bb = self.freshBlock("f32.unbox");
    const f64_bb = self.freshBlock("f64.unbox");
    const merge_bb = self.freshBlock("float.merge");

    // Branch: tag == f32_tag ? f32_bb : f64_bb
    const f32_tag = self.builder.constInt(TypeId.f32.index(), .i64);
    const cond = self.builder.emit(.{ .cmp_eq = .{ .lhs = tag, .rhs = f32_tag } }, .bool);
    self.builder.condBr(cond, f32_bb, &.{}, f64_bb, &.{});

    // f32 block: unbox as f32, fpext to f64, store
    self.builder.switchToBlock(f32_bb);
    const f32_val = self.builder.emit(.{ .unbox_any = .{
        .operand = any_val,
    } }, .f32);
    const f64_from_f32 = self.builder.emit(.{ .widen = .{ .operand = f32_val, .from = .f32, .to = .f64 } }, .f64);
    self.builder.store(result_slot, f64_from_f32);
    self.builder.br(merge_bb, &.{});

    // f64 block: unbox as f64 directly, store
    self.builder.switchToBlock(f64_bb);
    const f64_val = self.builder.emit(.{ .unbox_any = .{
        .operand = any_val,
    } }, .f64);
    self.builder.store(result_slot, f64_val);
    self.builder.br(merge_bb, &.{});

    // Merge block: load result
    self.builder.switchToBlock(merge_bb);
    return self.builder.load(result_slot, .f64);
}

/// Float views load their tagged width before extending to f64.
pub fn widenAnyToF64(self: *Lowering, any_val: Ref, tags: []const u64) Ref {
    var has_f32 = false;
    var has_f64 = false;
    for (tags) |t| {
        const tid = TypeId.fromIndex(@intCast(t));
        if (tid == .f32) has_f32 = true;
        if (tid == .f64) has_f64 = true;
    }
    if (has_f32 and has_f64) return lowerAnyToF64Dispatch(self, any_val);
    if (has_f32) {
        const f32_val = self.builder.emit(.{ .unbox_any = .{ .operand = any_val } }, .f32);
        return self.builder.widen(f32_val, .f32, .f64);
    }
    return self.builder.emit(.{ .unbox_any = .{ .operand = any_val } }, .f64);
}

/// Produce a default value for a type, applying struct field defaults.
/// For structs with defaults (e.g., `b: i32 = 99`), creates a struct_literal with defaults applied.
/// For other types, returns a zero value.
pub fn buildDefaultValue(self: *Lowering, ty: TypeId) Ref {
    if (ty.isBuiltin()) return self.zeroValue(ty);
    const info = self.module.types.get(ty);
    if (info != .@"struct") return self.zeroValue(ty);
    const field_defaults = self.struct_defaults_by_tid.get(ty) orelse return self.zeroValue(ty);
    const fields = info.@"struct".fields;
    var field_vals = std.ArrayList(Ref).empty;
    defer field_vals.deinit(self.alloc);
    for (fields, 0..) |f, i| {
        if (i < field_defaults.len) {
            if (field_defaults[i]) |default_expr| {
                field_vals.append(self.alloc, self.lowerCoercedDefault(default_expr, f.ty)) catch unreachable;
            } else {
                field_vals.append(self.alloc, self.zeroValue(f.ty)) catch unreachable;
            }
        } else {
            field_vals.append(self.alloc, self.zeroValue(f.ty)) catch unreachable;
        }
    }
    return self.builder.emit(.{
        .struct_init = .{ .fields = self.alloc.dupe(Ref, field_vals.items) catch unreachable },
    }, ty);
}

/// Wrap ty in ?ty, but flatten: if ty is already ?U, return ?U (not ??U)
pub fn optionalOfFlattened(self: *Lowering, ty: TypeId) TypeId {
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        if (info == .optional) return ty;
    }
    return self.module.types.optionalOf(ty);
}

/// A type's default value: zeroed storage, plus the terminator of every
/// `[N:X]T` it holds.
pub fn zeroValue(self: *Lowering, ty: TypeId) Ref {
    if (!self.module.types.writesTerminator(ty)) return self.builder.constNull(ty);
    return switch (self.module.types.get(ty)) {
        .array => |a| terminatedArray(self, ty, a),
        .@"struct" => |st| terminatedStruct(self, ty, st),
        else => unreachable,
    };
}

fn terminatedArray(self: *Lowering, ty: TypeId, info: types.TypeInfo.ArrayInfo) Ref {
    var elems = std.ArrayList(Ref).empty;
    defer elems.deinit(self.alloc);
    elems.ensureTotalCapacity(self.alloc, info.storageLen()) catch unreachable;
    for (0..info.length) |_| elems.appendAssumeCapacity(self.zeroValue(info.element));
    if (info.sentinel) |x| elems.appendAssumeCapacity(self.sentinelValue(x, info.element));
    return self.builder.structInit(elems.items, ty);
}

fn terminatedStruct(self: *Lowering, ty: TypeId, info: types.TypeInfo.StructInfo) Ref {
    var vals = std.ArrayList(Ref).empty;
    defer vals.deinit(self.alloc);
    vals.ensureTotalCapacity(self.alloc, info.fields.len) catch unreachable;
    for (info.fields) |f| vals.appendAssumeCapacity(self.zeroValue(f.ty));
    return self.builder.structInit(vals.items, ty);
}

/// Emit the unified non-integral float→int narrowing diagnostic.
/// ONE wording, ONE place: every site that rejects an implicit
/// narrowing of a non-integral compile-time float to an integer type calls
/// this, so the message + fix-it stay identical across the typed-binding
/// coerce arm, the field/param-default sites, the typed-const path, and the
/// global-initializer path.
pub fn diagNonIntegralNarrow(self: *Lowering, span: ast.Span, value: f64, dst_ty: TypeId) void {
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "cannot implicitly narrow non-integral float '{d}' to '{s}'; use an explicit cast (`.({s})`)", .{ value, self.formatTypeName(dst_ty), self.formatTypeName(dst_ty) });
}

/// Lower a struct field default `default_expr`, coerced to the field type
/// `field_ty`. A compile-time float default narrowing into an integer field
/// follows the unified rule via `foldComptimeFloatInit`; everything else
/// lowers under the field type as target and coerces at the IR level.
pub fn lowerCoercedDefault(self: *Lowering, default_expr: *const Node, field_ty: TypeId) Ref {
    if (self.foldComptimeFloatInit(default_expr, field_ty)) |folded| return folded;
    const saved_tt = self.target_type;
    self.target_type = field_ty;
    const raw = self.lowerExpr(default_expr);
    self.target_type = saved_tt;
    return self.coerceToType(raw, self.builder.getRefType(raw), field_ty);
}

/// Lower a struct field's default expression with an OPTIONAL generic-instance
/// type-binding context installed. When `bindings` is non-null
/// (the field belongs to a generic struct instance), `self.type_bindings` is
/// temporarily set to it so a default that references a type param — e.g.
/// `sz: i64 = @sizeOf(T)` — monomorphizes to THIS instantiation's concrete
/// arg before delegating to `lowerCoercedDefault`. `bindings` is non-null for
/// any generic instance — spelled directly (`Box(i64)`) or through an alias
/// (`BI :: Box(i64)`; the alias name carries mirrored bindings) — whether or
/// not its defaults actually reference a param. It is null exactly for a
/// non-generic struct, where this is `lowerCoercedDefault` verbatim — no
/// ambient binding change.
pub fn lowerDefaultWithBindings(
    self: *Lowering,
    default_expr: *const Node,
    field_ty: TypeId,
    bindings: ?std.StringHashMap(TypeId),
) Ref {
    const b = bindings orelse return self.lowerCoercedDefault(default_expr, field_ty);
    const saved_tb = self.type_bindings;
    self.type_bindings = b;
    defer self.type_bindings = saved_tb;
    return self.lowerCoercedDefault(default_expr, field_ty);
}

const CoerceMode = enum { implicit, explicit };

/// Insert a conversion if src_ty and dst_ty differ.
/// Handles int widening/narrowing, float widening/narrowing, and int↔float.
/// IMPLICIT coercion — the typed-binding initializer path. A compile-time
/// float narrowing to an integer folds when integral, errors when not.
pub fn coerceToType(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId) Ref {
    return self.coerceMode(val, src_ty, dst_ty, .implicit);
}

/// EXPLICIT coercion — the `xx` / postfix-`.(T)` escape hatch. A float→int
/// here always truncates, bypassing the integral-fold / non-integral-error rule.
pub fn coerceExplicit(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId) Ref {
    return self.coerceMode(val, src_ty, dst_ty, .explicit);
}

/// What an implicit coercion produced, and whether the rules applied.
pub const CheckedCoercion = struct {
    /// The value the destination slot receives. Meaningful only when the
    /// coercion landed — a refusal leaves whatever the ladder passed through.
    ref: Ref,
    /// A diagnostic already named this source and destination.
    refused: bool,
};

/// `coerceToType`, plus whether the conversion landed. A refusal is exactly what
/// a typed parameter refuses, including the pairs that turn on the VALUE — a
/// non-literal `string` reaching a `[*:0]u8`, an un-narrowed optional — so a
/// caller that must react to one reads a single answer rather than re-deriving
/// the ladder's arms.
pub fn coerceChecked(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId) CheckedCoercion {
    return coerceModeChecked(self, val, src_ty, dst_ty, .implicit);
}

fn coerceModeChecked(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId, mode: CoerceMode) CheckedCoercion {
    const before: usize = if (self.diagnostics) |d| d.errorCount() else 0;
    const converted = self.coerceMode(val, src_ty, dst_ty, mode);
    const after: usize = if (self.diagnostics) |d| d.errorCount() else 0;
    return .{ .ref = converted, .refused = after != before };
}

/// Is this weld into a set slot one that membership refuses? A set destination is
/// decided by the source's DECLARATION: `any` holds a member rather than a set, a
/// non-member is not what the slot carries, and a member never fails — whatever the
/// two widths are. Width decides bit-compatibility, and no number of matching bytes
/// makes a non-member a slot (spec: Open Sets — formation).
fn setWeldRefused(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) bool {
    if (!self.isOpenSet(dst_ty)) return false;
    if (src_ty == dst_ty or src_ty == .unresolved or src_ty == .void or src_ty == .noreturn) return false;
    if (src_ty == .any) return true;
    return !self.openSetDeclaresMembership(src_ty, self.openSetOf(dst_ty).?.decl);
}

/// The membership fact at an implicit weld — a field initializer, an argument, a
/// return. True when refused, and the caller stops before the value is welded.
fn refuseSetWeld(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) bool {
    if (!setWeldRefused(self, src_ty, dst_ty)) return false;
    const refused = if (src_ty == .any)
        self.refuseSetFromAny(dst_ty, span)
    else
        self.refuseOpenSetNonMember(src_ty, dst_ty, span);
    if (refused) self.assignability_error_count += 1;
    return refused;
}

/// Which store the guard is speaking about, and so how a refusal reads.
const AssignDiag = union(enum) {
    /// A store the program wrote, named by the destination it spells.
    ordinary: struct { verb: []const u8, name: []const u8 },
    /// The write an `@Init` formation performs: the refusal names the expression,
    /// since the destination is a slot the program never spelled.
    formation,
};

/// Guard a store into an explicitly-annotated slot against a silent bit-mangle.
pub fn checkAssignable(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span, verb: []const u8, name: []const u8) bool {
    return checkAssignableWith(self, src_ty, dst_ty, span, .{ .ordinary = .{ .verb = verb, .name = name } });
}

/// `checkAssignable` for the write an `@Init(dst_ty)` formation performs.
pub fn checkFormationWritable(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) bool {
    return checkAssignableWith(self, src_ty, dst_ty, span, .formation);
}

fn checkAssignableWith(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span, diag: AssignDiag) bool {
    if (src_ty == dst_ty) return true;
    // Suppress a cascade onto an error that is NOT this guard's own: a
    // pre-lowering "unknown type" (the annotation resolved to a poison stub) or
    // a failed initializer leaves an unreliable type here. `errorCount()` minus
    // the guard's own tally is >0 exactly when some other diagnostic fired — an
    // errored build never runs, so the bit-mangle can't reach run time anyway.
    // Independent mismatches in a clean file are each the guard's OWN error, so
    // they are NOT suppressed (the tally cancels them out).
    if (self.externalErrorsExist()) return true;
    // An unresolved operand was already diagnosed at its origin.
    if (src_ty == .unresolved or dst_ty == .unresolved) return true;
    if (setWeldRefused(self, src_ty, dst_ty)) {
        if (src_ty == .any) {
            if (self.refuseSetFromAny(dst_ty, span)) self.assignability_error_count += 1;
            return false;
        }
        if (self.diagnostics) |d| {
            // The value is named the way the program spells it, and the fact reads
            // as it does at every other set refusal (spec: Open Sets).
            const id = switch (diag) {
                .formation => d.addFmtId(.err, span, "'{s}' cannot form an initializer for '{s}': it is not a member of the set", .{ self.formatSourceTypeName(src_ty), self.formatSourceTypeName(dst_ty) }),
                .ordinary => |o| d.addFmtId(.err, span, "cannot {s} '{s}' of type '{s}' with a value of type '{s}'", .{ o.verb, o.name, self.formatSourceTypeName(dst_ty), self.formatSourceTypeName(src_ty) }),
            };
            self.openSetMembershipHelp(d, id, src_ty, dst_ty, span);
            self.noteOpenSetInstantiation(d, id);
            self.assignability_error_count += 1;
        }
        return false;
    }
    if (self.slotReturnType(src_ty)) |src_ret| {
        if (self.slotReturnType(dst_ty)) |dst_ret| {
            if (!self.checkSlotChannel(src_ret, dst_ret, span)) {
                self.assignability_error_count += 1;
                return false;
            }
        }
    }
    if (self.conversionAvailable(src_ty, dst_ty, .implicit)) return true;
    // Lowering owns the specific refusal diagnostics for these pairs.
    const plan = self.coercionResolver().classify(src_ty, dst_ty);
    if (plan.refuses() or plan == .unbox_any) return true;
    if (refuseBoolNumber(self, src_ty, dst_ty, span)) return false;
    if (!src_ty.isBuiltin() and !dst_ty.isBuiltin() and
        self.module.types.get(src_ty) == .@"error" and self.module.types.get(dst_ty) == .@"error") return true;
    if (self.diagnostics) |d| {
        switch (diag) {
            .formation => d.addFmt(.err, span, "'{s}' cannot form an initializer for '{s}': no conversion applies", .{ self.formatSourceTypeName(src_ty), self.formatSourceTypeName(dst_ty) }),
            .ordinary => |o| d.addFmt(.err, span, "cannot {s} '{s}' of type '{s}' with a value of type '{s}'", .{ o.verb, o.name, self.formatSourceTypeName(dst_ty), self.formatSourceTypeName(src_ty) }),
        }
        self.assignability_error_count += 1;
    }
    return false;
}

fn recoveringConversion(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) bool {
    return src_ty == .unresolved or dst_ty == .unresolved or
        src_ty == .noreturn or self.externalErrorsExist();
}

/// The SOURCE-LEVEL signature type of the lowered function `fid`: the implicit
/// `__sx_ctx` parameter dropped and the declared calling convention and C tail
/// kept, so it interns to the same `TypeId` as the equivalent written annotation
/// (`(i64) -> i64`, `(i64) -> i64 abi(.c)`, `(i64, ..) -> i64 abi(.c)`). A
/// parameter with a default is an ordinary parameter here — a default is a
/// call-site convenience, not part of the value's signature.
pub fn functionSignatureType(self: *Lowering, fid: inst_mod.FuncId) ?TypeId {
    const f = &self.module.functions.items[fid.index()];
    var param_ids = std.ArrayList(TypeId).empty;
    defer param_ids.deinit(self.alloc);
    const skip: usize = if (f.has_implicit_ctx) 1 else 0;
    for (f.params[skip..]) |p| param_ids.append(self.alloc, p.ty) catch return null;
    return self.module.types.functionTypeVariadic(param_ids.items, f.ret, f.call_conv, f.is_c_variadic);
}

/// The SOURCE-LEVEL signature type an `ast.FnDecl` states — the shaping
/// `declareFunction` performs: an extern named `..name: []T` tail strips to the
/// fixed prefix and marks the C tail, and the convention follows the
/// effective-C signature. Every consumer of a bare function's declared type —
/// an inferred binding, the Type reflection value, the `any` rendering — reads
/// this one shape.
pub fn declSignatureType(self: *Lowering, fd: *const ast.FnDecl) TypeId {
    var is_c_variadic = fd.is_c_variadic;
    var effective = fd.params;
    if (fd.extern_export == .extern_ and fd.params.len > 0 and fd.params[fd.params.len - 1].is_variadic) {
        is_c_variadic = true;
        effective = fd.params[0..ast.fixedParamCount(fd.params)];
    }
    var param_ids = std.ArrayList(TypeId).empty;
    defer param_ids.deinit(self.alloc);
    for (effective) |*param| param_ids.append(self.alloc, self.resolveParamType(param)) catch {};
    const cc: types.TypeInfo.CallConv = if (ast.isEffectiveCSignature(fd)) .c else .default;
    return self.module.types.functionTypeVariadic(param_ids.items, self.resolveReturnType(fd), cc, is_c_variadic);
}

/// A non-generic bare function's signature, available before argument lowering.
pub fn bareFnNameSignature(self: *Lowering, node: *const Node) ?TypeId {
    if (node.data != .identifier) return null;
    const name = node.data.identifier.name;
    if (self.scope) |scope| if (scope.lookup(name) != null) return null;
    if (self.ufcsAliasTarget(name) != null) return null;
    const fd: *const ast.FnDecl = switch (self.selectCallableAuthor(name, self.environmentForSource(self.current_source_file orelse return null).?, .non_generic)) {
        .func => |sf| sf.decl,
        .none => self.program_index.lookup(.function, name) orelse return null,
        .ambiguous, .not_callable => return null,
    };
    if (fd.type_params.len > 0) return null;
    for (fd.params) |p| if (p.is_pack or p.is_comptime) return null;
    const fid = self.declFuncId(fd) orelse return null;
    return functionSignatureType(self, fid);
}

pub const LiteralLocalHelp = struct {
    primary: usize,
    source_file: ?[]const u8,
    local: lower.LiteralLocal,
};

/// `src_ty` reaching the terminated `dst_ty`, which no conversion fills. `local`
/// is the literal-bound local the value was read from.
pub fn refuseAddedTerminator(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span, local: ?lower.LiteralLocal) void {
    const d = self.diagnostics orelse return;
    const fix = if (src_ty == .string and !self.coercionResolver().classify(.cstring, dst_ty).refuses())
        " — materialize one with toCstring(s)"
    else
        "";
    const id = d.addFmtId(.err, span, "a value of type '{s}' does not coerce to '{s}': no conversion adds a terminator{s}", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty), fix });
    self.assignability_error_count += 1;
    if (local) |l| self.literal_local_helps.append(self.alloc, .{ .primary = id, .source_file = d.current_source_file, .local = l }) catch @panic("out of memory");
}

/// The `::` fix-it holds only for a local nothing writes.
pub fn emitLiteralLocalHelps(self: *Lowering) void {
    const d = self.diagnostics orelse return;
    const saved = d.current_source_file;
    defer d.current_source_file = saved;
    for (self.literal_local_helps.items) |h| {
        if (self.written_bindings.contains(h.local.binding)) continue;
        d.current_source_file = h.source_file;
        d.addHelpFmt(h.primary, h.local.init.span, null, "declare '{s}' with '::': a constant keeps the literal's terminator", .{h.local.name});
    }
}

fn diagnoseUnmodeledCoercion(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, mode: CoerceMode) void {
    const cs = self.builder.current_span;
    const span: ast.Span = .{ .start = cs.start, .end = cs.end };
    if (refuseSetWeld(self, src_ty, dst_ty, span)) return;
    if (recoveringConversion(self, src_ty, dst_ty)) return;
    refuseConversion(self, src_ty, dst_ty, mode, span);
}

fn refuseConversion(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, mode: CoerceMode, span: ast.Span) void {
    const d = self.diagnostics orelse return;
    switch (mode) {
        .implicit => d.addFmt(.err, span, "cannot coerce a value of type '{s}' to '{s}': no implicit conversion applies", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty) }),
        .explicit => d.addFmt(.err, span, "no conversion from '{s}' to '{s}'", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty) }),
    }
    self.assignability_error_count += 1;
}

/// A literal of type `src_ty` at the constant leaf `dst_ty`: true when an implicit
/// conversion reaches it, else refused at `span` as the lowered leaf's coercion is.
pub fn checkConstantLeaf(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) bool {
    if (src_ty == dst_ty or dst_ty == .unresolved) return true;
    if (refuseSetWeld(self, src_ty, dst_ty, span)) return false;
    if (self.conversionAvailable(src_ty, dst_ty, .implicit)) return true;
    if (refuseBoolNumber(self, src_ty, dst_ty, span)) return false;
    switch (self.coercionResolver().classify(src_ty, dst_ty)) {
        .optional_wrap => return checkConstantLeaf(self, src_ty, self.module.types.get(dst_ty).optional.child, span),
        .adds_terminator_reject => self.refuseAddedTerminator(src_ty, dst_ty, span, null),
        else => refuseConversion(self, src_ty, dst_ty, .implicit, span),
    }
    return false;
}

/// Refuses an implicit bool/number pair at `span` with the explicit-cast fix-it; false for any other pair.
fn refuseBoolNumber(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) bool {
    switch (self.coercionResolver().classify(src_ty, dst_ty)) {
        .bool_to_number, .number_to_bool => {},
        .optional_wrap => return refuseBoolNumber(self, src_ty, self.module.types.get(dst_ty).optional.child, span),
        else => return false,
    }
    diagImplicitNumericConversion(self, src_ty, dst_ty, span);
    return true;
}

/// Return-path variant of the guard, with a return-specific message and the
/// return VALUE's span (the central `coerceMode` guard only has the builder's
/// current span). Callers must SKIP the plain `coerceToType` when this returns
/// false — otherwise `diagnoseUnmodeledCoercion` would fire a second, redundant
/// diagnostic for the same weld. Shares `assignability_error_count` so the
/// external-error suppression keeps working across both guards.
pub fn checkReturnable(self: *Lowering, _: Ref, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) bool {
    if (refuseSetWeld(self, src_ty, dst_ty, span)) return false;
    if (recoveringConversion(self, src_ty, dst_ty) or self.conversionAvailable(src_ty, dst_ty, .implicit)) return true;
    if (refuseBoolNumber(self, src_ty, dst_ty, span)) return false;
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "cannot return a value of type '{s}' where '{s}' is expected", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty) });
        self.assignability_error_count += 1;
    }
    return false;
}

/// True when a diagnostic OTHER than this guard's own assignability errors has
/// already been emitted — the signal to suppress a cascade (see
/// `checkAssignable`). The guard tracks its own emissions in
/// `assignability_error_count`, so `errorCount() > that` means "an external
/// error exists", independent of how many mismatches the guard itself reported.
pub fn externalErrorsExist(self: *Lowering) bool {
    const d = self.diagnostics orelse return false;
    return d.errorCount() > self.assignability_error_count;
}

/// Value-dependent checks (literal narrowing and optional presence) run in lowering.
pub fn conversionAvailable(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, mode: CoerceMode) bool {
    const plan = self.coercionResolver().classify(src_ty, dst_ty);
    if (plan == .none or plan.refuses()) return false;
    return switch (plan) {
        .error_to_int, .single_to_many, .void_to_c_function, .unbox_any, .bool_to_number, .number_to_bool => mode == .explicit,
        .optional_wrap => self.conversionAvailable(src_ty, self.module.types.get(dst_ty).optional.child, mode),
        .optional_to_optional => self.conversionAvailable(self.module.types.get(src_ty).optional.child, self.module.types.get(dst_ty).optional.child, mode),
        else => true,
    };
}

fn isFunctionType(self: *Lowering, ty: TypeId) bool {
    if (ty.isBuiltin()) return false;
    return self.module.types.get(ty) == .function;
}

/// A type whose values are a raw ADDRESS at the IR level, for the pointer-pun
/// test above. Optional and erased values use separate representation checks.
pub fn isPointerValueKind(self: *Lowering, ty: TypeId) bool {
    if (ty.isBuiltin()) return false;
    return switch (self.module.types.get(ty)) {
        .pointer, .many_pointer => true,
        else => false,
    };
}

fn refuseImplicitNumericConversion(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) Ref {
    if (!self.externalErrorsExist()) {
        const cs = self.builder.current_span;
        diagImplicitNumericConversion(self, src_ty, dst_ty, .{ .start = cs.start, .end = cs.end });
    }
    return self.builder.constUndef(dst_ty);
}

fn diagImplicitNumericConversion(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) void {
    const d = self.diagnostics orelse return;
    d.addFmt(.err, span, "cannot implicitly convert '{s}' to '{s}'; use an explicit cast (`.({s})`)", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty), self.formatTypeName(dst_ty) });
    self.assignability_error_count += 1;
}

/// A typed numeric read of `src_ty` at the constant leaf `dst_ty`: true when
/// `src_ty` widens to `dst_ty`, else refused at `span` as a local's read is.
pub fn checkConstantWidens(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) bool {
    if (implicitNumericConversion(self, src_ty, dst_ty) orelse true) return true;
    diagImplicitNumericConversion(self, src_ty, dst_ty, span);
    return false;
}

fn implicitNumericConversion(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) ?bool {
    if (implicitIntegerConversion(self, src_ty, dst_ty)) |widens| return widens;
    return switch (self.coercionResolver().classify(src_ty, dst_ty)) {
        .float_to_int, .bool_to_number, .number_to_bool => false,
        .narrow => if (Lowering.isFloat(src_ty) and Lowering.isFloat(dst_ty)) false else null,
        else => null,
    };
}

pub fn coerceMode(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId, mode: CoerceMode) Ref {
    if (mode == .implicit) {
        const cs = self.builder.current_span;
        const span = ast.Span{ .start = cs.start, .end = cs.end };
        if (implicitIntegerConversion(self, src_ty, dst_ty)) |widens| {
            if (!widens) {
                if (self.externalErrorsExist()) return self.builder.constUndef(dst_ty);
                if (self.builder.getRefOp(val)) |op| {
                    if (op == .const_int) {
                        self.checkIntLiteralFits(self.intConstantValue(op.const_int, src_ty), dst_ty, span);
                        return self.builder.constInt(op.const_int, dst_ty);
                    }
                }
                return refuseImplicitNumericConversion(self, src_ty, dst_ty);
            }
        }
        self.checkErrorSetValueCoercion(src_ty, dst_ty, span);
        if (self.slotReturnType(src_ty)) |src_ret| {
            if (self.slotReturnType(dst_ty)) |dst_ret| {
                if (!self.checkSlotChannel(src_ret, dst_ret, span)) {
                    self.assignability_error_count += 1;
                }
            }
        }
    }
    switch (self.coercionResolver().classify(src_ty, dst_ty)) {
        .borrow_protocol => {
            const src = self.module.types.get(src_ty);
            if (src == .pointer) {
                if (self.viewOfConcreteAddr(val, src.pointer.pointee, dst_ty)) |view| return view;
            } else if (self.refStorageAddress(val)) |addr| {
                if (self.viewOfConcreteAddr(addr, src_ty, dst_ty)) |view| return view;
            } else if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                const pointee = self.module.types.get(dst_ty).pointer.pointee;
                d.addFmt(.err, .{ .start = cs.start, .end = cs.end }, "cannot store a '{s}' rvalue into '{s}' — an rvalue has no durable storage to view; bind it to a local first, or erase to an owned '{s}' value", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty), self.formatTypeName(pointee) });
            }
            return self.builder.constUndef(dst_ty);
        },
        .no_op => return if (src_ty == dst_ty) val else self.builder.emit(.{
            .bitcast = .{ .operand = val, .from = src_ty, .to = dst_ty },
        }, dst_ty),
        .integer_retype, .error_set_retype => return self.builder.emit(.{ .bitcast = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .none => {
            diagnoseUnmodeledCoercion(self, src_ty, dst_ty, mode);
            return val;
        },
        .failable_retype => {
            const src = self.module.types.get(src_ty).failable;
            const dst = self.module.types.get(dst_ty).failable;
            var values = std.ArrayList(Ref).empty;
            defer values.deinit(self.alloc);
            const count = self.module.types.failableValueSlotCount(src);
            for (0..count) |i| {
                const ty = self.module.types.failableValueSlotType(src, i);
                values.append(self.alloc, self.builder.emit(.{ .struct_get = .{ .base = val, .field_index = @intCast(i), .base_type = src_ty } }, ty)) catch unreachable;
            }
            const tag = self.builder.emit(.{ .struct_get = .{ .base = val, .field_index = @intCast(count), .base_type = src_ty } }, src.err);
            return self.buildFailableTuple(dst_ty, values.items, self.coerceMode(tag, src.err, dst.err, mode));
        },
        // Unbox Any → concrete type. An IMPLICIT unbox (`s : S = some_any`) is
        // rejected: the unbox blindly reinterprets the boxed payload
        // word as `dst_ty` with NO runtime tag check, so a wrong target silently
        // yields garbage (`f64 = any_holding_i64` → 0.0) or — for an aggregate
        // target — dereferences the payload word as a pointer and segfaults. sx
        // prevents this class at compile time (like the no-implicit-optional-unwrap
        // rule) rather than with a runtime trap: dispatch on the value's type
        // (`match` / `type_name`), or force it with an explicit `xx` if the boxed
        // type is known. An EXPLICIT `xx` (mode == .explicit, and `lowerXX`'s own
        // unbox arm) stays the acknowledged escape hatch; compiler-generated
        // type-dispatch / pack-extraction unboxes emit `.unbox_any` DIRECTLY (not
        // through this arm), so they are unaffected.
        .unbox_any => {
            if (mode == .implicit) {
                if (self.diagnostics) |d| {
                    const cs = self.builder.current_span;
                    d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "an 'any' does not implicitly unbox to '{s}': the boxed type is not checked, so a wrong target reinterprets the payload (a wrong scalar silently yields garbage; an aggregate dereferences it and crashes). Dispatch on the value's type with `match`, or assert the boxed type with `.({s})`.", .{ self.formatTypeName(dst_ty), self.formatTypeName(dst_ty) });
                }
                // Diagnosed — `hasErrors()` aborts the build before run time; the
                // emitted op is never executed.
            }
            return self.builder.emit(.{ .unbox_any = .{ .operand = val } }, dst_ty);
        },
        // A member value into its set's slot: the tag the freeze numbers plus a
        // COPY of the member's bytes. An independent slot — the set is an inline
        // value, so nothing is shared with the source afterwards.
        .member_to_open_set => return self.coerceMemberToSet(val, src_ty, dst_ty),
        // Box concrete → any. Node-less coercion site: always a spill
        // (the node-aware borrow path is `boxAnyOf` at lowerXX / the
        // variadic pack / the decl-init hooks).
        .box_any => return boxAnyOf(self, val, src_ty, null),
        // Closure VALUE → bare function-pointer slot: not soundly representable.
        // A bare `(T) -> U` slot is called as `fnPtr(ctx, args)` with NO env
        // arg, but a closure's underlying fn takes an env slot — so passing a
        // closure value's fnPtr drops the env and shifts the args (UB for a
        // matching ABI, a wrong-tuple read for ∅-widening, a segfault when the
        // closure captures). Only a closure LITERAL can cross this boundary,
        // via the static adapter `lowerLambda` emits (so a literal arrives here
        // already typed `.function`). Reject the variable case loudly.
        .closure_to_fn_reject => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "a closure value cannot be passed as a bare function-pointer `(...) -> ...` — its environment can't be carried across the bare ABI; pass the closure literal directly at the call site, or declare the parameter type as `Closure(...)`", .{});
            }
            return val;
        },
        .closure_signature_reject, .function_signature_reject => {
            if (self.externalErrorsExist()) return val;
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                const span = ast.Span{ .start = cs.start, .end = cs.end };
                d.addFmt(.err, span, "cannot convert '{s}' to '{s}': {s} signatures differ", .{ self.formatSourceTypeName(src_ty), self.formatSourceTypeName(dst_ty), if (isFunctionType(self, src_ty)) @as([]const u8, "function") else "closure" });
                self.assignability_error_count += 1;
            }
            return val;
        },
        // An empty-env unique erases like a bare function does: the lowered
        // function already takes the env slot, so the pair is {fn, null}.
        .unique_to_closure => {
            const u = self.uniqueLambdaOf(src_ty).?;
            return self.builder.closureCreate(u.func.lowered, Ref.none, dst_ty);
        },
        .unique_to_closure_reject => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                const span = ast.Span{ .start = cs.start, .end = cs.end };
                const id = d.addFmtId(.err, span, "a capturing lambda does not erase to '{s}' — its environment has no home here", .{self.module.types.formatTypeName(self.alloc, dst_ty, null)});
                d.addHelpFmt(id, span, null, "persist it with 'mem.closure(f)', or 'mem.closure(f, alloc)' to choose the allocator; a pointer to it ('*f') erases by borrowing", .{});
            }
            return val;
        },
        // The pointer IS the env word: the pair is {fn, ptr}, and the env lives
        // where the pointer says, for as long as it does.
        .lambda_ptr_to_closure => {
            const u = self.uniqueLambdaThrough(src_ty).?;
            return self.builder.closureCreate(u.func.lowered, val, dst_ty);
        },
        .lambda_ptr_to_closure_reject => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                const span = ast.Span{ .start = cs.start, .end = cs.end };
                d.addFmt(.err, span, "a pointer to this lambda does not erase to '{s}': the signatures differ", .{self.module.types.formatTypeName(self.alloc, dst_ty, null)});
            }
            return val;
        },
        .struct_elementwise => {
            const si = self.module.types.get(src_ty);
            const di = self.module.types.get(dst_ty);
            var elems = std.ArrayList(Ref).empty;
            defer elems.deinit(self.alloc);
            for (si.@"struct".fields, di.@"struct".fields, 0..) |sf, df, i| {
                const fv = self.builder.structGet(val, @intCast(i), sf.ty);
                elems.append(self.alloc, self.coerceMode(fv, sf.ty, df.ty, mode)) catch unreachable;
            }
            return self.builder.structInit(self.alloc.dupe(Ref, elems.items) catch unreachable, dst_ty);
        },
        // Optional → Concrete unwrapping — ONLY when the value is PROVEN
        // present by flow narrowing. Unwrapping an un-narrowed
        // `?T` unconditionally would yield the zero payload of a null optional
        // with no diagnostic — a silent miscompile across the whole
        // `?T → concrete` family. Per spec the
        // only legal extractions are `?!` / `??` / binding / match / a `!= null`
        // guard; reject everything else loudly. `lowerIdentifier` tags the
        // loaded `Ref` of a guard-narrowed local into `narrowed_refs`.
        .optional_unwrap => {
            if (!self.narrowed_refs.contains(val)) {
                if (self.diagnostics) |d| {
                    const cs = self.builder.current_span;
                    d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot use a value of type '{s}' where '{s}' is expected: an optional does not implicitly unwrap; force-unwrap with '?!', supply a fallback with '?? <default>', bind it (`if v := ...`), or guard with '!= null'", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty) });
                }
                return val; // hasErrors() aborts before codegen
            }
            const child_ty = self.module.types.get(src_ty).optional.child;
            const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = val } }, child_ty);
            return self.coerceMode(unwrapped, child_ty, dst_ty, mode);
        },
        // Optional → bool: there is no implicit presence-test coercion. An
        // unwrap-then-narrow ladder silently produces `false` for every
        // optional. Reject with a fix-it pointing at `!= null`.
        .optional_to_bool_reject => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot use a value of type '{s}' where 'bool' is expected; test presence explicitly with '!= null'", .{self.formatTypeName(src_ty)});
            }
            return val;
        },
        .adds_terminator_reject => {
            const cs = self.builder.current_span;
            self.refuseAddedTerminator(src_ty, dst_ty, .{ .start = cs.start, .end = cs.end }, self.literal_local_refs.get(val));
            return val;
        },
        // void → Optional: produce null (void is the type of null_literal)
        .void_to_optional => return self.builder.constNull(dst_ty),
        // ?A → ?B: presence-preserving payload coercion. The naive route
        // (fall through to `.optional_wrap`) unwrapped the SOURCE optional
        // unconditionally and re-wrapped as always-present, dropping the
        // has-bit — a null `?i32` became a present `?i64` carrying zero
        // (generic `??` returning the wrong fallback). Branch on
        // the source's presence so the payload is only unwrapped when it is
        // actually present (the interp errors on unwrapping a null optional,
        // so a branchless select is not an option):
        //   present → unwrap src child, coerce to dst child, wrap as present
        //   absent  → null of the destination optional
        .optional_to_optional => {
            const src_child = self.module.types.get(src_ty).optional.child;
            const dst_child = self.module.types.get(dst_ty).optional.child;

            const has_val = self.builder.optionalHasValue(val);
            const present_bb = self.freshBlock("opt2opt.present");
            const absent_bb = self.freshBlock("opt2opt.absent");
            const merge_bb = self.freshBlockWithParams("opt2opt.merge", &.{dst_ty});
            self.builder.condBr(has_val, present_bb, &.{}, absent_bb, &.{});

            self.builder.switchToBlock(present_bb);
            const unwrapped = self.builder.optionalUnwrap(val, src_child);
            const coerced_child = self.coerceMode(unwrapped, src_child, dst_child, mode);
            const wrapped = self.builder.optionalWrap(coerced_child, dst_ty);
            self.builder.br(merge_bb, &.{wrapped});

            self.builder.switchToBlock(absent_bb);
            const null_dst = self.builder.constNull(dst_ty);
            self.builder.br(merge_bb, &.{null_dst});

            self.builder.switchToBlock(merge_bb);
            return self.builder.blockParam(merge_bb, 0, dst_ty);
        },
        // Concrete → Optional wrapping (coerce to the inner type first)
        .optional_wrap => {
            const child_ty = self.module.types.get(dst_ty).optional.child;
            const coerced = coerceModeChecked(self, val, src_ty, child_ty, mode);
            // The inner coercion may classify as `.none` (no built-in applies)
            // and pass `val` through UNCHANGED — e.g. wrapping a `?i64` value
            // into a `?(?i64)` whose payload is the 1-tuple `(?i64)`. Building
            // the optional then inserts a `{i64,i1}` into a `{{i64,i1}}` slot,
            // producing malformed IR that aborts the LLVM verifier.
            // If the coerced operand's type does not match the optional's child
            // type, the wrap is invalid — diagnose loudly instead of emitting a
            // corrupt InsertValue. (`hasErrors()` then aborts the build.)
            const coerced_ty = self.builder.getRefType(coerced.ref);
            if (coerced_ty != child_ty) {
                if (self.diagnostics) |d| {
                    if (!coerced.refused) {
                        const cs = self.builder.current_span;
                        // Only mention the `(T)`-is-a-1-tuple gotcha when the payload
                        // actually IS a tuple (the `?(?T)` typo); for any other
                        // mismatch the parens note would be misleading.
                        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot wrap a value of type '{s}' into optional '{s}': its payload type is '{s}'", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty), self.formatTypeName(child_ty) });
                    }
                }
                return val;
            }
            return self.builder.emit(.{ .optional_wrap = .{ .operand = coerced.ref } }, dst_ty);
        },
        // Concrete → Protocol (auto type erasure)
        .erase_protocol => {
            const proto_name = self.module.types.getString(self.module.types.get(dst_ty).@"struct".name);
            const ctn = self.resolveConcreteTypeName(src_ty).?;
            var concrete_ptr = val;
            var concrete_ty = src_ty;
            if (!src_ty.isBuiltin() and self.module.types.get(src_ty) == .pointer) {
                concrete_ty = self.module.types.get(src_ty).pointer.pointee;
            } else if (self.refStorageAddress(val)) |addr| {
                // This node-less layer serves call paths that lowered the arg
                // before its param target was known (UFCS/generic routes), so
                // lvalue-ness is proved from the defining instruction rather
                // than the AST: a READ of named storage borrows that storage.
                concrete_ptr = addr;
            } else {
                self.refuseRvalueInterfaceErasure(proto_name, .{ .start = self.builder.current_span.start, .end = self.builder.current_span.end });
                return self.builder.emit(.{ .placeholder = self.module.types.internString("protocol-erasure") }, dst_ty);
            }
            return self.buildProtocolValue(concrete_ptr, proto_name, ctn, dst_ty, concrete_ty);
        },
        .int_to_float => return self.builder.emit(.{ .int_to_float = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .float_to_int => {
            if (mode == .implicit) {
                if (self.builder.constFloatInfo(val)) |info| {
                    if (program_index_mod.floatToIntExact(info.value)) |iv| {
                        return self.builder.constInt(iv, dst_ty);
                    }
                    self.diagNonIntegralNarrow(.{ .start = info.span.start, .end = info.span.end }, info.value, dst_ty);
                    return self.builder.constUndef(dst_ty);
                }
                return refuseImplicitNumericConversion(self, src_ty, dst_ty);
            }
            return self.builder.emit(.{ .float_to_int = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty);
        },
        .bool_to_number => {
            if (mode == .implicit) return refuseImplicitNumericConversion(self, src_ty, dst_ty);
            const bit = self.builder.emit(.{ .widen = .{ .operand = val, .from = .bool, .to = .u8 } }, .u8);
            return self.coerceMode(bit, .u8, dst_ty, mode);
        },
        .number_to_bool => {
            if (mode == .implicit) return refuseImplicitNumericConversion(self, src_ty, dst_ty);
            const zero = if (Lowering.isFloat(src_ty)) self.builder.constFloat(0, src_ty) else self.builder.constInt(0, src_ty);
            return self.builder.emit(.{ .cmp_ne = .{ .lhs = val, .rhs = zero } }, .bool);
        },
        // Int ↔ payload-less enum: run the integer ladder to/from the enum's
        // backing type, then retype the word to the other side. The retype is
        // a `bitcast` between two identically-shaped scalars (the enum lowers
        // to its backing integer), so the result is a genuinely enum-/int-
        // typed value in every position — optional wrap, argument, `switch`
        // subject, comparison.
        .int_to_enum => {
            const backing = self.enumBackingType(dst_ty).?;
            const as_backing = self.coerceMode(val, src_ty, backing, mode);
            return self.builder.emit(.{ .bitcast = .{ .operand = as_backing, .from = backing, .to = dst_ty } }, dst_ty);
        },
        .error_to_int => {
            if (mode == .implicit) {
                diagnoseUnmodeledCoercion(self, src_ty, dst_ty, mode);
                return val;
            }
            const tag = self.builder.enumTag(val, .i32);
            return self.coerceMode(tag, .i32, dst_ty, mode);
        },
        .enum_to_int => {
            const backing = self.enumBackingType(src_ty).?;
            const as_backing = self.builder.emit(.{ .bitcast = .{ .operand = val, .from = src_ty, .to = backing } }, backing);
            return self.coerceMode(as_backing, backing, dst_ty, mode);
        },
        .single_to_many, .void_to_c_function => {
            if (mode == .implicit) {
                diagnoseUnmodeledCoercion(self, src_ty, dst_ty, mode);
                return val;
            }
            return self.builder.emit(.{ .bitcast = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty);
        },
        .ptr_to_void, .void_to_ptr, .many_to_single, .array_ptr_to_many_ptr, .many_drop_terminator, .objc_upcast => return self.builder.emit(.{ .bitcast = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .narrow => {
            if (mode == .implicit and Lowering.isFloat(src_ty) and Lowering.isFloat(dst_ty)) {
                return refuseImplicitNumericConversion(self, src_ty, dst_ty);
            }
            return self.builder.emit(.{ .narrow = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty);
        },
        .widen => return self.builder.emit(.{ .widen = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .array_to_slice => {
            // Implicit array→slice coercion (`fill(arr)` where `fill :: (s:
            // []T)`). The explicit `arr[0..N]` syntax aliases the array's
            // storage; this implicit path MUST match, or passing
            // `arr` vs `arr[0..]` silently differs. For an
            // ADDRESSABLE array, build a zero-copy VIEW over its storage.
            if (self.arrayToSliceView(val, src_ty, dst_ty)) |view| return view;
            // NON-addressable rvalue array (`fill(makeArr())`): keep the
            // COPYING `array_to_slice` op (alloca+store). This is the general
            // coercion arm, reached for CALL ARGUMENTS — the temporary lives
            // for the call's duration, so a copy the callee mutates in place
            // is SOUND (the callee cannot outlive the argument). The
            // slice-typed BINDING form (`s : []T = makeArr()`, handled in
            // stmt.zig) likewise copies into a function-entry slot that
            // outlives the binding — sound, never dangling. Both differ from
            // a SUBSLICE of a temporary, which aliases the temp directly
            // (dangling) and IS rejected. Recorded in specs.md §Subslicing.
            return self.builder.emit(.{ .array_to_slice = .{ .operand = val } }, dst_ty);
        },
        // `[N:X]T` → `[N]T`: the N elements, read through the array's own
        // element accessor; the terminator's slot is not part of the value.
        .array_drop_terminator => {
            const a = self.module.types.get(src_ty).array;
            var elems = std.ArrayList(Ref).empty;
            defer elems.deinit(self.alloc);
            elems.ensureTotalCapacity(self.alloc, a.length) catch unreachable;
            for (0..a.length) |i| {
                const idx = self.builder.constInt(@intCast(i), .i64);
                elems.appendAssumeCapacity(self.builder.emit(.{ .index_get = .{ .lhs = val, .rhs = idx } }, a.element));
            }
            return self.builder.structInit(self.alloc.dupe(Ref, elems.items) catch unreachable, dst_ty);
        },
        // `[N:X]T` → `[*:X]T`: the array's own storage, so a write through the
        // pointer is a write to the array. An array value with no storage of
        // its own — a constant, a temporary — gets one at emission.
        .array_to_many_ptr => {
            if (self.refStorageAddress(val)) |addr| {
                return self.builder.emit(.{ .bitcast = .{ .operand = addr, .from = self.builder.getRefType(addr), .to = dst_ty } }, dst_ty);
            }
            return self.builder.emit(.{ .data_ptr = .{ .operand = val } }, dst_ty);
        },
        // `[:X]T` → `[*:X]T`: the fat pointer's data word.
        .slice_to_many_ptr => return self.builder.emit(.{ .data_ptr = .{ .operand = val } }, dst_ty),
        // `@Slice(T,A) → @Slice(T,B)`: same view, a length word of a different
        // width. Rebuild the header from the source's `.ptr` and `.len`. A
        // folded source length that does not fit `B` is refused; implicit
        // narrowing of a non-constant length is refused; widening is implicit.
        .slice_len_convert => {
            if (foldedSliceLen(self, val)) |n| {
                if (self.refuseLenWord(n, dst_ty)) return self.builder.constUndef(dst_ty);
            } else if (mode == .implicit and self.refuseImplicitLenNarrow(src_ty, dst_ty)) {
                return self.builder.constUndef(dst_ty);
            }
            const elem_ty = self.module.types.sliceInfoOf(dst_ty).?.element;
            const mp_ty = self.module.types.manyPtrTo(elem_ty);
            const data = self.builder.emit(.{ .data_ptr = .{ .operand = val } }, mp_ty);
            const len = self.emitLengthI64(val, src_ty);
            return self.builder.emit(.{ .subslice = .{
                .base = data,
                .lo = self.builder.constInt(0, .i64),
                .hi = len,
                .base_ty = mp_ty,
            } }, dst_ty);
        },
        // `[*]T → []T`: a many-pointer has no length, so it can't form a slice
        // header implicitly. Diagnose and tell the user to slice with a length.
        .many_to_slice_reject => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "a many-pointer '[*]T' does not coerce to a slice '[]T' implicitly (it carries no length) — slice it with a length: ptr[0..len]", .{});
            }
            return val;
        },
    }
}

/// The bit width of an integer type, or null when `ty` is not an integer.
/// `isize`/`usize` carry the target's address width, which the C tail rules
/// must read from the target rather than assume.
pub fn tailIntegerWidth(self: *Lowering, ty: TypeId) ?u32 {
    return switch (ty) {
        .bool => 1,
        .i8, .u8 => 8,
        .i16, .u16 => 16,
        .i32, .u32 => 32,
        .i64, .u64 => 64,
        .isize, .usize => self.typeBitsEx(ty),
        else => if (ty.isBuiltin()) null else switch (self.module.types.get(ty)) {
            .signed, .unsigned => |bits| bits,
            else => null,
        },
    };
}

/// The type an argument takes under the C default argument promotions, or null
/// when it crosses unchanged. Every integer narrower than 32 bits widens to
/// `i32` and `f32` widens to `f64`; wider C ABI integers, `f64`, the pointer
/// family, and `abi(.c)` function values are already tail-width.
pub fn promotedTailType(self: *Lowering, ty: TypeId) ?TypeId {
    if (ty == .f32) return .f64;
    if (tailIntegerWidth(self, ty)) |bits| {
        if (bits < 32) return .i32;
    }
    return null;
}

/// Whether a POST-PROMOTION type may cross a C-variadic tail. The tail carries
/// neither a count nor types, so only what a C ABI can pass through `va_arg`
/// belongs there: the 32- and 64-bit integers, `f64`, the pointer family and
/// its nullable forms, and function values that carry the C convention.
pub fn tailAdmissible(self: *Lowering, ty: TypeId) bool {
    if (ty == .f64) return true;
    if (tailIntegerWidth(self, ty)) |bits| return bits == 32 or bits == 64;
    if (ty.isBuiltin()) return false;
    return switch (self.module.types.get(ty)) {
        .pointer, .many_pointer => true,
        // A nullable pointer is one word with null as its absent value; any
        // other optional carries a separate presence flag.
        .optional => |o| !o.child.isBuiltin() and switch (self.module.types.get(o.child)) {
            .pointer, .many_pointer => true,
            else => false,
        },
        .function => |f| f.call_conv == .c,
        else => false,
    };
}

/// Promote and check every argument at or past the fixed count. One
/// implementation serves each C-variadic call site, so a tail argument is
/// promoted and admitted identically wherever it is written.
pub fn promoteCVariadicArgs(self: *Lowering, args: []Ref, fixed_count: usize) void {
    if (args.len <= fixed_count) return;
    for (args[fixed_count..], fixed_count..) |*arg, i| {
        const src_ty = self.builder.getRefType(arg.*);
        if (promotedTailType(self, src_ty)) |promoted| {
            arg.* = self.coerceToType(arg.*, src_ty, promoted);
        }
        const crossed = self.builder.getRefType(arg.*);
        const cs = self.builder.current_span;
        const span = ast.Span{ .start = cs.start, .end = cs.end };
        // A cursor borrow is admissible as a pointer, but the callee has no
        // typed slot to read it back from — and the tail it names belongs to a
        // frame the callee cannot bound.
        if (self.refuseCursorEscape(crossed, span, "cross a C-variadic tail as")) continue;
        if (tailAdmissible(self, crossed)) continue;
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "argument {d}: '{s}' cannot cross a C-variadic tail; use a C ABI integer, 'f64', a pointer, or an 'abi(.c)' function value", .{ i + 1, self.formatTypeName(src_ty) });
        }
    }
}

/// Coerce call arguments in-place to match function parameter types.
pub fn coerceCallArgs(self: *Lowering, args: []Ref, params: []const Function.Param) void {
    for (0..@min(args.len, params.len)) |i| {
        const src_ty = self.builder.getRefType(args[i]);
        const dst_ty = params[i].ty;
        if (!src_ty.isBuiltin() and !dst_ty.isBuiltin()) {
            const src_info = self.module.types.get(src_ty);
            const dst_info = self.module.types.get(dst_ty);
            if (src_info == .array and dst_info == .many_pointer and
                self.coercionResolver().classify(self.module.types.ptrTo(src_ty), dst_ty) == .array_ptr_to_many_ptr)
            {
                const slot = self.builder.alloca(src_ty);
                self.builder.store(slot, args[i]);
                args[i] = self.coerceToType(slot, self.builder.getRefType(slot), dst_ty);
                continue;
            }
            // Implicit address-of: passing T value where *T is expected → alloca + store
            // Only when the pointee type matches the source type.
            if (dst_info == .pointer and src_info != .pointer and self.module.types.sameType(dst_info.pointer.pointee, src_ty)) {
                const slot = self.builder.alloca(src_ty);
                self.builder.store(slot, args[i]);
                args[i] = slot;
                continue;
            }
            // Concrete → `*Protocol`: the borrowed-VIEW coercion. A
            // pointer-to-concrete arg makes the view directly (ctx = the
            // pointer; the view aliases the pointee). A bare concrete VALUE
            // reaching this node-less layer is rvalue-shaped — it has no
            // durable storage to borrow; diagnose instead of passing the
            // struct's bytes where a pointer is expected (a silent
            // LLVM-verifier crash).
            if (dst_info == .pointer and src_ty != dst_ty and
                self.getProtocolInfo(dst_info.pointer.pointee) != null and
                self.getProtocolInfo(src_ty) == null)
            {
                if (src_info == .pointer and
                    self.getProtocolInfo(src_info.pointer.pointee) == null and
                    !src_info.pointer.pointee.isBuiltin())
                {
                    if (self.viewOfConcreteAddr(args[i], src_info.pointer.pointee, dst_ty)) |v| {
                        args[i] = v;
                        continue;
                    }
                } else if (src_info == .@"struct") {
                    if (self.diagnostics) |d| {
                        const cs = self.builder.current_span;
                        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot pass a '{s}' value where '{s}' is expected — a value has no durable storage to borrow; pass an addressable lvalue (or a pointer to one)", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty) });
                        self.assignability_error_count += 1;
                    }
                    continue;
                }
            }
        }
        args[i] = self.coerceToType(args[i], src_ty, dst_ty);
    }
}
