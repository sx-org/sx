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
const ParamImplEntry = Lowering.ParamImplEntry;

/// Lower the `xx` operator (type coercion).
/// Uses self.target_type for context when available. Handles:
/// - Any → concrete type: unbox_any
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
    // and would always spill a copy. A PROTOCOL source is exempt: an
    // explicit `xx p : any` is the CONCRETE view (protocol_to_any — the
    // {ctx, type_id} prefix), not a box of the protocol value; implicit
    // boxing (`av : any = s`) routes through boxAnyOf directly at its
    // sites and stays a box.
    if (dst_ty == .any and src_ty != .any and src_ty != .unresolved and
        self.getProtocolInfo(src_ty) == null)
    {
        return boxAnyOf(self, operand, src_ty, operand_node);
    }

    // PLANNING: the `xx`-head decision (conversions.zig). `.coerce` falls
    // through to the built-in ladder + the user-`Into` fallback below.
    switch (self.coercionResolver().classifyXX(src_ty, dst_ty)) {
        // Any → concrete type: unbox.
        .unbox_any => {
            // Inside an int-category match arm (`case int:`), the tag set
            // spans several widths — an unbox is an exact-width load, so a
            // widening `xx val` needs a per-tag dispatch (load own width,
            // extend per signedness).
            if (dst_ty == .i64 or dst_ty == .u64 or dst_ty == .isize or dst_ty == .usize) {
                if (self.current_match_tags) |tags| {
                    return lowerAnyToIntDispatch(self, operand, dst_ty, tags);
                }
            }
            // When inside a float match arm covering both f32 and f64,
            // and target is f64, we need a mini-dispatch to unbox correctly:
            // an f32 view holds 4 bytes — load f32, then fpext.
            if (dst_ty == .f64) {
                if (self.current_match_tags) |tags| {
                    var has_f32 = false;
                    var has_f64 = false;
                    for (tags) |t| {
                        const tid = TypeId.fromIndex(@intCast(t));
                        if (tid == .f32) has_f32 = true;
                        if (tid == .f64) has_f64 = true;
                    }
                    if (has_f32 and has_f64) {
                        return self.lowerAnyToF64Dispatch(operand);
                    }
                    if (has_f32 and !has_f64) {
                        // Only f32 values: unbox as f32, then widen
                        const f32_val = self.builder.emit(.{ .unbox_any = .{
                            .operand = operand,
                        } }, .f32);
                        return self.builder.emit(.{ .widen = .{ .operand = f32_val, .from = .f32, .to = .f64 } }, .f64);
                    }
                }
            }
            return self.builder.emit(.{ .unbox_any = .{
                .operand = operand,
            } }, dst_ty);
        },
        // Same type: no-op.
        .no_op => return operand,
        // Concrete → Protocol: build protocol value.
        .erase_protocol => return self.buildProtocolErasure(operand, operand_node, src_ty, dst_ty),
        // Concrete → ?Protocol: erase to the protocol CHILD first — node-aware,
        // so an lvalue source BORROWS its storage exactly like the plain
        // `xx s : P` path — then wrap inline. Routing through `.coerce` instead
        // reaches the node-less value-erasure arm below (`.optional_wrap` →
        // `.erase_protocol`), which heap-boxes the receiver through
        // context.allocator with no owner to ever free it (issue 0213).
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
        // Protocol → pointer: recover the typed ctx pointer (field 0).
        // The protocol value is `{ ctx, fn1, fn2, ... }` (inline) or
        // `{ ctx, vtable_ptr }` — either way, ctx lives at field 0.
        .protocol_to_pointer => {
            // A pointer-to-PROTOCOL target is a type lie, not a recovery:
            // ctx addresses the CONCRETE value, so `s.(*Sizable)` would
            // return concrete bytes typed as a protocol-value pointer —
            // and `*P` dispatch would load them as {ctx, type_id, vtable}
            // (issue 0306). Refuse with the two honest spellings.
            if (!dst_ty.isBuiltin()) {
                const dinfo = self.module.types.get(dst_ty);
                if (dinfo == .pointer and self.getProtocolInfo(dinfo.pointer.pointee) != null) {
                    if (self.diagnostics) |d| {
                        const cs = self.builder.current_span;
                        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "the ctx recovery yields a pointer to the CONCRETE value, so its target must be the concrete pointee type (e.g. `p.(*YourConcrete)` or `p.(*void)`); to point at the protocol value itself, take its address with `@`", .{});
                    }
                    return self.builder.emit(.{ .placeholder = self.module.types.internString("protocol-ptr-recovery") }, dst_ty);
                }
            }
            const void_ptr_ty = self.module.types.ptrTo(.void);
            const ctx_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
            if (dst_ty == void_ptr_ty) return ctx_ref;
            return self.builder.emit(.{ .bitcast = .{ .operand = ctx_ref, .from = void_ptr_ty, .to = dst_ty } }, dst_ty);
        },
        // Protocol → ProtocolRaw: the modeled raw-view retrieval. Built
        // FIELD-WISE — {ctx, __type_id} is the prefix of BOTH protocol
        // layouts, so the view can never carry a wrong word and the result
        // is a real value that works in any position (a bit reinterpret
        // would width-mismatch on #inline values, which are wider).
        .protocol_to_raw => {
            const void_ptr_ty = self.module.types.ptrTo(.void);
            const ctx_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
            const tid_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 1 } }, .type_value);
            var fields = [2]Ref{ ctx_ref, tid_ref };
            return self.builder.structInit(&fields, dst_ty);
        },
        // Protocol → any: the concrete view. The value's {ctx, __type_id}
        // prefix IS an any {data, type_id} — read the two words and
        // assemble the view (the downcast / protocol type switch base).
        .protocol_to_any => {
            const void_ptr_ty = self.module.types.ptrTo(.void);
            const ctx_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 0 } }, void_ptr_ty);
            const tid_ref = self.builder.emit(.{ .struct_get = .{ .base = operand, .field_index = 1 } }, .type_value);
            return self.builder.makeAny(tid_ref, ctx_ref);
        },
        .coerce => {},
    }

    const result = self.coerceExplicit(operand, src_ty, dst_ty);

    // User-space fallback via `impl Into(Target) for Source`. Only fires
    // when the target was explicitly named (not the .i64 default), src and
    // dst differ, and the built-in ladder made no progress. Built-ins
    // always win.
    if (target_explicit and src_ty != dst_ty and result == operand) {
        if (self.tryUserConversion(operand, operand_node, src_ty, dst_ty)) |converted| {
            return converted;
        }
        // Pointer-target fallback: `xx <expr>` whose surrounding context
        // expects `*T` (a fn arg slot, a var typed as a pointer-to-aggregate)
        // can be satisfied by `impl Into(T) for src` plus an implicit
        // alloca+store on the result. Lets users write
        // `fn(xx () => { ... })` instead of materialising a named Block local
        // just to take its address.
        if (!dst_ty.isBuiltin()) {
            const dst_info = self.module.types.get(dst_ty);
            if (dst_info == .pointer) {
                const pointee = dst_info.pointer.pointee;
                if (pointee != src_ty) {
                    if (self.tryUserConversion(operand, operand_node, src_ty, pointee)) |converted| {
                        const slot = self.builder.alloca(pointee);
                        self.builder.store(slot, converted);
                        return slot;
                    }
                }
            }
        }
    }
    // Explicit aggregate↔scalar reinterpret, AFTER every conversion declined
    // (`result == operand` — the builtin ladder made no progress and no user
    // `Into` applied; the ORDER matters: a spill here must never pre-empt
    // Into or its visibility diagnostics). The raw SSA passthrough would
    // hand codegen a value whose IR type contradicts its sx type — fine in
    // store positions (memory is untyped; the historic escape-hatch uses),
    // but the first VALUE-context use (icmp, call arg, arithmetic) aborts
    // the LLVM verifier (issue 0305). Deliver the promised reinterpretation
    // for real: spill through a zero-initialized slot typed as the larger
    // side, load back as the target — a genuine dst-typed value in every
    // context, byte-identical to the store-mediated semantics ("width be
    // damned" included: the smaller side partially covers/reads).
    if (src_ty != dst_ty and result == operand and
        isAggregateValueKind(self, src_ty) != isAggregateValueKind(self, dst_ty))
    {
        const src_sz = self.module.types.typeSizeBytes(src_ty);
        const dst_sz = self.module.types.typeSizeBytes(dst_ty);
        const slot_ty = if (dst_sz >= src_sz) dst_ty else src_ty;
        const slot = self.builder.alloca(slot_ty);
        self.builder.store(slot, self.buildDefaultValue(slot_ty));
        self.builder.store(slot, operand);
        return self.builder.load(slot, dst_ty);
    }
    return result;
}

/// Detect the `xx closure : Block` cast pattern so `tryUserConversion`
/// can emit a focused diagnostic when no `Into(Block) for Closure(...)`
/// impl is reachable. Replaces what was briefly a compiler-synthesised
/// trampoline path with a "declare an impl" requirement — the stdlib
/// covers common signatures (see modules/ffi/objc_block.sx), users
/// add their own for unusual ones.
pub fn isClosureToBlockCast(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) bool {
    if (src_ty.isBuiltin()) return false;
    const src_info = self.module.types.get(src_ty);
    if (src_info != .closure) return false;
    if (dst_ty.isBuiltin()) return false;
    const dst_info = self.module.types.get(dst_ty);
    if (dst_info != .@"struct") return false;
    const block_name = self.module.types.internString("Block");
    return dst_info.@"struct".name == block_name;
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
) ?Ref {
    _ = operand_node;
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
    const pd = self.program_index.protocol_ast_map.get(proto_name) orelse return null;
    bindings.put(pd.type_params[0].name, dst_ty) catch return null;
    if (entry.ret_var_name) |rv| bindings.put(rv, src_ret) catch return null;

    var pack_bindings = std.StringHashMap([]const TypeId).init(self.alloc);
    defer pack_bindings.deinit();
    pack_bindings.put(entry.pack_var_name, tail_owned) catch return null;

    // Mangled name keyed on the CONCRETE source so distinct shapes
    // monomorphise separately. Same scheme as the concrete path:
    // "<src>.convert__<dst>".
    const mangled = std.fmt.allocPrint(self.alloc, "{s}.convert__{s}", .{
        self.mangleTypeName(src_ty), self.mangleTypeName(dst_ty),
    }) catch return null;

    self.xx_reentrancy.put(guard_key, {}) catch {};
    defer _ = self.xx_reentrancy.remove(guard_key);

    if (!self.lowered_functions.contains(mangled)) {
        const saved_pack = self.pack_bindings;
        self.pack_bindings = pack_bindings;
        defer self.pack_bindings = saved_pack;
        self.monomorphizeFunction(fd, mangled, &bindings);
    }

    const fid = self.resolveFuncByName(mangled) orelse return null;
    const func = &self.module.functions.items[@intFromEnum(fid)];
    const ret_ty = func.ret;
    const params = func.params;
    var single = [_]Ref{operand};
    const final_args = self.prependCtxIfNeeded(func, single[0..]);
    self.coerceCallArgs(final_args, params);
    return self.builder.call(fid, final_args, ret_ty);
}

/// Look up `Into(dst_ty)` impl for `src_ty` and, if found, monomorphise
/// the impl's `convert` method and emit a direct call. Returns null when
/// no impl matches (caller falls back to the built-in result, which is
/// the unchanged operand — Phase 3 emits no diagnostic for v0).
pub fn tryUserConversion(self: *Lowering, operand: Ref, operand_node: *const Node, src_ty: TypeId, dst_ty: TypeId) ?Ref {
    // Reentrancy guard — pack (src, dst) into a u64.
    const guard_key: u64 = (@as(u64, src_ty.index()) << 32) | @as(u64, dst_ty.index());
    if (self.xx_reentrancy.contains(guard_key)) {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, operand_node.span, "recursive xx conversion from '{s}' to '{s}'", .{
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
    const pd = self.program_index.protocol_ast_map.get(proto_name) orelse return null;
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
        if (self.tryPackImplMatch(operand, operand_node, src_ty, dst_ty, proto_name, pack_key, guard_key)) |result| {
            return result;
        }
        if (self.isClosureToBlockCast(src_ty, dst_ty)) {
            if (self.diagnostics) |diags| {
                const saved = diags.current_source_file;
                diags.current_source_file = operand_node.source_file orelse self.current_source_file;
                defer diags.current_source_file = saved;
                diags.addFmt(.err, operand_node.span, "no `Into(Block) for {s}` impl — add a per-signature `__block_invoke_<sig>` trampoline + Into impl alongside the existing ones in modules/ffi/objc_block.sx, or declare it in your own code", .{self.mangleTypeName(src_ty)});
            }
            return operand;
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

    self.xx_reentrancy.put(guard_key, {}) catch {};
    defer _ = self.xx_reentrancy.remove(guard_key);

    if (!self.lowered_functions.contains(mangled)) {
        self.monomorphizeFunction(fd, mangled, &bindings);
    }

    const fid = self.resolveFuncByName(mangled) orelse return null;
    const func = &self.module.functions.items[@intFromEnum(fid)];
    const ret_ty = func.ret;
    const params = func.params;
    var single = [_]Ref{operand};
    const final_args = self.prependCtxIfNeeded(func, single[0..]);
    self.coerceCallArgs(final_args, params);
    return self.builder.call(fid, final_args, ret_ty);
}

/// True for expression shapes that name an addressable storage location
/// (variables, fields, array elements, dereferenced pointers). Used by
/// `xx <struct-typed expr>` to decide between borrow (lvalue → take the
/// address) and heap-copy (rvalue → allocate a fresh copy).
pub fn isLvalueExpr(self: *Lowering, node: *const Node) bool {
    return switch (node.data) {
        .identifier, .deref_expr => true,
        // A field access denotes storage only if its BASE does: `obj.b` and
        // `arr[i].b` name a slot, but `make_pair().b` reads a field of a
        // TEMPORARY. Classifying a call-result base as lvalue re-lowered the
        // AST for the borrow — double-calling `make_pair()` and handing the
        // erasure a garbage address (the value fallback of lowerExprAsPtr).
        // A rvalue base routes to the self-contained copy path instead.
        .field_access => |fa| self.isLvalueExpr(fa.object),
        // A comptime pack index (`pack[i]`) is NOT an lvalue: a pack is
        // comptime-only with no runtime storage — `pack[i]` resolves to the
        // call-site arg node, which only acquires storage when lowered as a
        // value. Taking its address via `lowerExprAsPtr` would lower the bare
        // pack as a value and trip the pack-as-value error (issue 0135).
        // Reporting it as an rvalue routes `buildProtocolErasure` into its
        // heap-copy branch, which copies the already-materialized element.
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
/// scope entry with no alloca of its own that is NOT a by-ref `(*x)`
/// capture and NOT an `inline for` pack alias. These are the loop /
/// match / catch captures and local `::` consts: each is semantically a
/// COPY, so a protocol erasure must not see through its defining load to
/// the storage the value was read FROM (the container element / the
/// matched payload). The erasure materializes such operands instead of
/// borrowing (issue 0214 fold F2).
pub fn isByValueBindingIdent(self: *Lowering, node: *const Node) bool {
    if (node.data != .identifier) return false;
    const scope = self.scope orelse return false;
    const binding = scope.lookup(node.data.identifier.name) orelse return false;
    return !binding.is_alloca and !binding.is_ref_capture and binding.pack_elem == null;
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
/// for the borrow, and the two evaluations could denote DIFFERENT elements
/// (issue 0214). Instead, walk the value's defining instruction:
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
            if (base_ty.isBuiltin()) {
                if (base_ty != .string) return null;
            } else switch (self.module.types.get(base_ty)) {
                .slice, .pointer, .many_pointer => {},
                .array => base = self.refStorageAddress(b.lhs) orelse return null,
                else => return null,
            }
            return self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = b.rhs } }, self.module.types.ptrTo(elem_ty));
        },
        else => return null,
    }
}

/// Box a concrete value into an `any` view `{tag, data}`. `any` is a
/// type-erased BORROW: the data slot holds the value's ADDRESS.
/// - An addressable lvalue operand (same discipline as protocol erasure:
///   lvalue node, not a by-value SSA binding) borrows its storage via
///   `refStorageAddress` — zero copy, and mutations of the source stay
///   visible through a live view.
/// - Anything else (rvalues, node-less coercion sites) spills to a frame
///   temp and points at it — the temp lives for the enclosing frame.
/// Arbitrary-width ints are widened into their tag-normalized builtin
/// (`anyTag` maps e.g. u24 → u32), so `data` ALWAYS points at exactly
/// `size_of(tag)` valid bytes — the invariant every consumer (typed
/// unbox loads, the raw layer's shallow copies) relies on.
pub fn boxAnyOf(self: *Lowering, val: Ref, src_ty: TypeId, node: ?*const Node) Ref {
    if (src_ty == .void) {
        // A void has no storage; the view is `{void, null}` (matches the
        // fieldless arm of field_value_get).
        return self.builder.boxAnyAt(self.builder.constNull(self.module.types.ptrTo(.void)), .void);
    }
    // Tag-normalize arbitrary-width ints (the tag space only has the
    // builtin widths; a borrow of a 3-byte value under a 4-byte tag
    // would overread).
    var box_ty = src_ty;
    var v = val;
    if (!src_ty.isBuiltin()) {
        const info = self.module.types.get(src_ty);
        const norm: ?TypeId = switch (info) {
            .signed => |w| switch (w) {
                8 => .i8,
                16 => .i16,
                32 => .i32,
                64 => .i64,
                else => if (w <= 32) TypeId.i32 else TypeId.i64,
            },
            .unsigned => |w| switch (w) {
                8 => .u8,
                16 => .u16,
                32 => .u32,
                64 => .u64,
                else => if (w <= 32) TypeId.u32 else TypeId.u64,
            },
            else => null,
        };
        if (norm) |n| {
            if (n != src_ty) {
                box_ty = n;
                v = self.builder.widen(val, src_ty, n);
            }
        }
    }
    if (box_ty == src_ty) {
        if (node) |n| {
            if (self.isLvalueExpr(n) and !self.isByValueBindingIdent(n)) {
                if (self.refStorageAddress(val)) |addr| {
                    return self.builder.boxAnyAt(addr, box_ty);
                }
            }
        }
    }
    const slot = self.builder.alloca(box_ty);
    self.builder.store(slot, v);
    return self.builder.boxAnyAt(slot, box_ty);
}

/// Coerce an already-lowered ARRAY value `val` (of array type `src_ty`) into a
/// slice `dst_ty` as a ZERO-COPY VIEW when the array is addressable, mirroring
/// the issue-0225 subslice fix on the implicit array→slice COERCION path
/// (issue 0264). An ADDRESSABLE array (local, global, struct field, `*[N]T`
/// deref) has its storage address recovered via the issue-0214
/// `refStorageAddress` walk (re-emits only address arithmetic, never re-runs a
/// side-effecting index) and a `subslice [0..len]` built over that pointer with
/// `base_ty = [*]elem` — so both backends take their many-pointer subslice arm
/// (a genuine view, no alloca+store). The explicit `arr[0..N]` syntax already
/// aliases (0225); without this the IMPLICIT `fill(arr)` coercion silently
/// COPIED via `array_to_slice`, so `arr` vs `arr[0..]` differed (silent-wrong).
///
/// Returns null when the array is a NON-ADDRESSABLE rvalue (a call result, a
/// literal, a by-value binding — `refStorageAddress` yields null). The caller
/// decides the fallback by CONTEXT: for a call ARGUMENT the temp lives for the
/// call's duration, so the copying `array_to_slice` op is SOUND; for a STORED
/// slice (`s : []T = makeArr()`) the copy would be a dangling view and must be
/// rejected like 0225.
pub fn arrayToSliceView(self: *Lowering, val: Ref, src_ty: TypeId) ?Ref {
    if (src_ty.isBuiltin() or self.module.types.get(src_ty) != .array) return null;
    const addr = self.refStorageAddress(val) orelse return null;
    const info = self.module.types.get(src_ty).array;
    const elem_ty = info.element;
    const slice_ty = self.module.types.sliceOf(elem_ty);
    const lo = self.builder.constInt(0, .i64);
    const hi = self.builder.constInt(@intCast(info.length), .i64);
    return self.builder.emit(.{ .subslice = .{
        .base = addr,
        .lo = lo,
        .hi = hi,
        .base_ty = self.module.types.manyPtrTo(elem_ty),
    } }, slice_ty);
}

pub fn buildProtocolErasure(self: *Lowering, operand: Ref, operand_node: *const Node, src_ty: TypeId, dst_ty: TypeId) Ref {
    const dst_info = self.module.types.get(dst_ty);
    if (dst_info != .@"struct") return operand;
    const proto_name = self.module.types.getString(dst_info.@"struct".name);

    // Determine concrete type name and type — resolve through pointer if needed
    var concrete_ptr = operand;
    var concrete_type_name: ?[]const u8 = null;
    var concrete_ty: TypeId = src_ty;
    var heap_copy = false;

    // Ownership classes split the conversion-mode arms: an #identity
    // target BORROWS lvalues/pointers (E2); a value/own target OWNS its
    // ctx, so the old borrow arms are the DEMAND error — only the rvalue
    // owning copy remains implicit. (The explicit owning spelling is the
    // postfix `.(P)` / `.(P, alloc)` — lowerOwningErasure.)
    const dst_identity = self.protocolIsIdentity(dst_ty);

    if (!src_ty.isBuiltin()) {
        const src_info = self.module.types.get(src_ty);
        if (src_info == .pointer) {
            // Pointer operand (`xx @acc`): identity borrows the pointee;
            // value/own demands the snapshot or a view.
            if (!dst_identity) return self.demandOwnedErasure(dst_ty, proto_name, operand_node, true);
            const pointee = src_info.pointer.pointee;
            concrete_type_name = self.resolveConcreteTypeName(pointee);
            concrete_ty = pointee;
            heap_copy = false;
        } else if (src_info == .@"struct") {
            // Struct-typed operand. Split on lvalue-ness:
            //   - lvalue (identifier, field, index, deref): identity
            //     borrows the storage the operand names; value/own
            //     DEMANDS the explicit owning spelling.
            //   - rvalue (struct literal, call result, etc.): heap-copy
            //     into a fresh allocation so the protocol value is
            //     self-contained and outlives this expression (the
            //     value/own invariant; identity refuses — no name).
            concrete_type_name = self.module.types.getString(src_info.@"struct".name);
            concrete_ty = src_ty;
            if (self.isLvalueExpr(operand_node)) {
                // Compiler-materialized pack temps (`__pack_*`) are exempt
                // from the demand: the binding is a fresh COPY with
                // call-duration lifetime — the erasure borrows the pack's
                // own materialization, no user storage is aliased, and no
                // user spelling exists to respell it.
                const is_pack_temp = operand_node.data == .identifier and
                    std.mem.startsWith(u8, operand_node.data.identifier.name, "__pack_");
                if (!dst_identity and !is_pack_temp) return self.demandOwnedErasure(dst_ty, proto_name, operand_node, false);
                if (self.isByValueBindingIdent(operand_node)) {
                    // A by-VALUE SSA binding (`for arr (x)`, a match/catch
                    // capture, a `::` const) is semantically a COPY of the
                    // element it was read from. Deriving the borrow address
                    // through `refStorageAddress` would see through the
                    // binding's defining load to the CONTAINER's storage —
                    // making `xx x` alias the original element and mutate it
                    // through the protocol, indistinguishable from the
                    // by-ref `(*x)` form. Materialize the copy instead: a
                    // fresh stack slot holds the already-lowered value and
                    // the protocol borrows THAT, so mutations land in the
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
                    // calls could pick different elements — issue 0214).
                    // `lowerExprAsPtr` remains as the fallback when no
                    // address is derivable from the defining instruction
                    // (e.g. a struct param bound directly to its SSA ref) —
                    // NOTE that fallback still re-lowers the AST, so it is
                    // only safe for shapes whose re-lowering has no side
                    // effects; every effectful lvalue shape (loads, global
                    // reads, field/index chains over them) is covered by
                    // refStorageAddress above.
                    concrete_ptr = self.refStorageAddress(operand) orelse self.lowerExprAsPtr(operand_node);
                }
                heap_copy = false;
            } else {
                heap_copy = true;
                const slot = self.builder.alloca(src_ty);
                self.builder.store(slot, operand);
                concrete_ptr = slot;
            }
        }
    }

    // Also try from the operand node for struct literals: xx Accumulator.{ total = 0 }
    if (concrete_type_name == null) {
        concrete_type_name = self.inferConcreteTypeName(operand_node);
        if (concrete_type_name != null) heap_copy = true;
    }

    if (concrete_type_name) |ctn| {
        // #identity protocols only ever BORROW: an rvalue has no durable
        // storage to borrow and an owning heap-copy is exactly what the
        // class forbids — refuse instead.
        if (heap_copy and self.refuseIdentityRvalueErasure(dst_ty, operand_node.span)) {
            return self.builder.emit(.{ .placeholder = self.module.types.internString("identity-erasure") }, dst_ty);
        }
        return self.buildProtocolValue(concrete_ptr, proto_name, ctn, dst_ty, concrete_ty, heap_copy);
    }
    return operand;
}

/// True when `ty` is an `#identity` protocol (borrow-only ownership class).
pub fn protocolIsIdentity(self: *Lowering, ty: TypeId) bool {
    const pi = self.getProtocolInfo(ty) orelse return false;
    return pi.ownership == .identity;
}

/// The ownership-cutover DEMAND diagnostic: a value/own protocol value
/// always OWNS its ctx, so erasing an lvalue (or a pointer to concrete
/// storage) implicitly — or with `xx`, the conversion operator — would
/// silently heap-copy it. Demand the explicit spelling instead.
/// `subject` is the operand's source name when known (identifier), else a
/// generic subject. Emits and returns a protocol-typed placeholder.
pub fn demandOwnedErasure(self: *Lowering, dst_ty: TypeId, proto_name: []const u8, operand_node: ?*const Node, src_is_pointer: bool) Ref {
    if (self.diagnostics) |d| {
        const span: ?ast.Span = if (operand_node) |n| n.span else blk: {
            const cs = self.builder.current_span;
            break :blk ast.Span{ .start = cs.start, .end = cs.end };
        };
        const named: ?[]const u8 = if (operand_node) |n| (if (n.data == .identifier) n.data.identifier.name else null) else null;
        if (src_is_pointer) {
            if (named) |nm| {
                d.addFmt(.err, span, "'{s}' is a pointer and '{s}' values own their storage — an implicit erasure here would silently alias or copy the pointee; write the snapshot ('{s}.({s})' copies the pointee, '{s}.({s}, <alloc>)' through a named allocator) or pass a view ('*{s}' parameter) for transient use", .{ nm, proto_name, nm, proto_name, nm, proto_name, proto_name });
            } else {
                d.addFmt(.err, span, "the operand is a pointer and '{s}' values own their storage — an implicit erasure here would silently alias or copy the pointee; write the snapshot (postfix '.({s})' copies the pointee, '.({s}, <alloc>)' through a named allocator) or pass a view ('*{s}' parameter) for transient use", .{ proto_name, proto_name, proto_name, proto_name });
            }
        } else {
            if (named) |nm| {
                d.addFmt(.err, span, "'{s}' is an lvalue and '{s}' values own their storage — an implicit erasure here would silently heap-copy it; write the copy ('{s}.({s})' or '{s}.({s}, <alloc>)') or pass a view ('*{s}' parameter) for transient use", .{ nm, proto_name, nm, proto_name, nm, proto_name, proto_name });
            } else {
                d.addFmt(.err, span, "the operand is an lvalue and '{s}' values own their storage — an implicit erasure here would silently heap-copy it; write the copy (postfix '.({s})' or '.({s}, <alloc>)') or pass a view ('*{s}' parameter) for transient use", .{ proto_name, proto_name, proto_name, proto_name });
            }
        }
    }
    return self.builder.emit(.{ .placeholder = self.module.types.internString("protocol-erasure") }, dst_ty);
}

/// The #identity rvalue-erasure refusal: returns true (diagnostic emitted)
/// when `dst_ty` is an `#identity` protocol — such values only ever borrow
/// a named object's storage, so an owning (heap-copying) erasure of an
/// rvalue is a compile error.
pub fn refuseIdentityRvalueErasure(self: *Lowering, dst_ty: TypeId, span: ?ast.Span) bool {
    const pi = self.getProtocolInfo(dst_ty) orelse return false;
    if (pi.ownership != .identity) return false;
    if (self.diagnostics) |d| {
        const s = span orelse blk: {
            const cs = self.builder.current_span;
            break :blk ast.Span{ .start = cs.start, .end = cs.end };
        };
        d.addFmt(.err, s, "cannot erase an rvalue to '#identity' protocol '{s}' — identity objects need a name; bind it first (`x := …;` then `xx x` / `x.({s})` borrows the local)", .{ pi.name, pi.name });
    }
    return true;
}

/// Concrete storage address → borrowed protocol VIEW `*P` (the erasure
/// model's view coercion, issues 0303/0304). Builds the borrow-mode protocol
/// value with `ctx = concrete_addr`, spills it to a frame slot, and returns
/// the slot's address. The pointee protocol value ALIASES the concrete
/// storage — mutations through the view are visible to the original; the
/// slot itself is a frame temp whose lifetime covers the call/statement.
/// Returns null when `view_ptr_ty` is not pointer-to-protocol or the
/// concrete type name is not resolvable (caller falls through to its
/// default path). Non-conformance is diagnosed inside buildProtocolValue.
pub fn viewOfConcreteAddr(self: *Lowering, concrete_addr: Ref, concrete_ty: TypeId, view_ptr_ty: TypeId) ?Ref {
    if (view_ptr_ty.isBuiltin()) return null;
    const vinfo = self.module.types.get(view_ptr_ty);
    if (vinfo != .pointer) return null;
    const proto_ty = vinfo.pointer.pointee;
    const proto_info = self.getProtocolInfo(proto_ty) orelse return null;
    const ctn = self.resolveConcreteTypeName(concrete_ty) orelse return null;
    const pv = self.buildProtocolValue(concrete_addr, proto_info.name, ctn, proto_ty, concrete_ty, false);
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

/// Generate a mini-dispatch for unboxing an `any` to a 64-bit int inside a
/// `case int:`-style match arm whose tag set spans several widths (the int
/// analog of `lowerAnyToF64Dispatch`). Under the borrow representation an
/// unbox is an EXACT-width load through the view — a bare 8-byte load with
/// a narrower tag would overread — so switch on the tag: each sub-8-byte
/// int tag loads its own width and sign/zero-extends per its signedness;
/// the default arm (8-byte tags) loads the target directly.
pub fn lowerAnyToIntDispatch(self: *Lowering, any_val: Ref, dst_ty: TypeId, tags: []const u64) Ref {
    const result_slot = self.builder.alloca(dst_ty);
    const tag = self.builder.structGet(any_val, 1, .i64);

    const default_bb = self.freshBlock("int.unbox.wide");
    const merge_bb = self.freshBlock("int.merge");

    var cases = std.ArrayList(inst_mod.SwitchBranch.Case).empty;
    defer cases.deinit(self.alloc);
    var case_tids = std.ArrayList(TypeId).empty;
    defer case_tids.deinit(self.alloc);
    var case_blocks = std.ArrayList(inst_mod.BlockId).empty;
    defer case_blocks.deinit(self.alloc);

    for (tags) |t| {
        const tid = TypeId.fromIndex(@intCast(t));
        if (!isNarrowIntTag(self, tid)) continue;
        const bb = self.freshBlock("int.unbox.narrow");
        cases.append(self.alloc, .{ .value = @intCast(t), .target = bb, .args = &.{} }) catch unreachable;
        case_tids.append(self.alloc, tid) catch unreachable;
        case_blocks.append(self.alloc, bb) catch unreachable;
    }
    if (cases.items.len == 0) {
        // No narrow tags in the set — a plain exact-width load suffices.
        return self.builder.emit(.{ .unbox_any = .{ .operand = any_val } }, dst_ty);
    }

    self.builder.switchBr(tag, cases.items, default_bb, &.{});

    for (case_tids.items, case_blocks.items) |tid, bb| {
        self.builder.switchToBlock(bb);
        const narrow = self.builder.emit(.{ .unbox_any = .{ .operand = any_val } }, tid);
        const wide = self.builder.widen(narrow, tid, dst_ty);
        self.builder.store(result_slot, wide);
        self.builder.br(merge_bb, &.{});
    }

    self.builder.switchToBlock(default_bb);
    const direct = self.builder.emit(.{ .unbox_any = .{ .operand = any_val } }, dst_ty);
    self.builder.store(result_slot, direct);
    self.builder.br(merge_bb, &.{});

    self.builder.switchToBlock(merge_bb);
    return self.builder.load(result_slot, dst_ty);
}

/// The sub-8-byte int tags an int-category match can carry: the narrow
/// builtins, plus arbitrary-width ints (a VIEW of a u2/i5/… struct field
/// carries its true tag) whose ABI size is under a word.
fn isNarrowIntTag(self: *Lowering, tid: TypeId) bool {
    switch (tid) {
        .i8, .u8, .i16, .u16, .i32, .u32 => return true,
        else => {},
    }
    if (!tid.isBuiltin()) {
        switch (self.module.types.get(tid)) {
            .signed, .unsigned => return self.module.types.typeSizeBytes(tid) < 8,
            else => {},
        }
    }
    return false;
}

/// Produce a default value for a type, applying struct field defaults.
/// For structs with defaults (e.g., `b: i32 = 99`), creates a struct_literal with defaults applied.
/// For other types, returns a zero value.
pub fn buildDefaultValue(self: *Lowering, ty: TypeId) Ref {
    if (ty.isBuiltin()) return self.builder.constInt(0, ty);
    const info = self.module.types.get(ty);
    if (info != .@"struct" and info != .tuple) return self.zeroValue(ty);
    // For tuples, build a zero-initialized tuple
    if (info == .tuple) {
        var field_vals = std.ArrayList(Ref).empty;
        defer field_vals.deinit(self.alloc);
        for (info.tuple.fields) |f| {
            field_vals.append(self.alloc, self.zeroValue(f)) catch unreachable;
        }
        return self.builder.emit(.{
            .tuple_init = .{ .fields = self.alloc.dupe(Ref, field_vals.items) catch unreachable },
        }, ty);
    }
    // Check for struct defaults — TypeId identity first; for an
    // author-tracked type a tid-map miss means "no defaults" (issue 0320).
    const struct_name_str = self.module.types.getString(info.@"struct".name);
    const field_defaults = self.struct_defaults_by_tid.get(ty) orelse blk: {
        if (self.plain_struct_authors.contains(ty)) return self.builder.constUndef(ty);
        break :blk self.struct_defaults_map.get(struct_name_str) orelse
            return self.builder.constUndef(ty);
    };
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

/// Produce a zero/default value for any type — constInt(0) for integers,
/// constNull for pointers, constUndef for structs/complex types.
pub fn zeroValue(self: *Lowering, ty: TypeId) Ref {
    if (ty.isBuiltin()) return self.builder.constInt(0, ty);
    const info = self.module.types.get(ty);
    return switch (info) {
        // Arbitrary-width integer types (u1, u2, i4, ...) interned as
        // `.signed`/`.unsigned` variants — fall through `isBuiltin()`.
        .signed, .unsigned => self.builder.constInt(0, ty),
        .pointer, .tuple, .optional => self.builder.constNull(ty),
        .@"struct", .array, .slice, .many_pointer => self.builder.constNull(ty),
        else => self.builder.constUndef(ty),
    };
}

/// Emit the unified non-integral float→int narrowing diagnostic (F0.11).
/// ONE wording, ONE place: every site that rejects an implicit
/// narrowing of a non-integral compile-time float to an integer type calls
/// this, so the message + fix-it stay identical across the typed-binding
/// coerce arm, the field/param-default sites, the typed-const path, and the
/// global-initializer path.
pub fn diagNonIntegralNarrow(self: *Lowering, span: ast.Span, value: f64, dst_ty: TypeId) void {
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "cannot implicitly narrow non-integral float '{d}' to '{s}'; use an explicit cast (`xx`/`.(T)`)", .{ value, self.formatTypeName(dst_ty) });
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
/// type-binding context installed (issue 0221). When `bindings` is non-null
/// (the field belongs to a generic struct instance), `self.type_bindings` is
/// temporarily set to it so a default that references a type param — e.g.
/// `sz: i64 = size_of(T)` — monomorphizes to THIS instantiation's concrete
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

/// How a float→int conversion is treated. An IMPLICIT coercion (a typed
/// binding initializer) folds an integral compile-time float to its int and
/// REJECTS a non-integral one; an EXPLICIT `xx` / `.(T)` always truncates.
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

/// Is `node` an explicit cast — `xx expr` or a postfix `expr.(T)`? Such a
/// value is the user's deliberate opt-in to a reinterpretation that has no
/// standard coercion (e.g. pointer↔int, function↔fn-pointer): the `.none`
/// passthrough in `coerceMode` is the intended escape hatch there, so the
/// assignability guard must NOT fire for it.
fn initIsExplicitCast(node: *const Node) bool {
    return switch (node.data) {
        .unary_op => |u| u.op == .xx,
        .postfix_cast => true,
        else => false,
    };
}

/// Guard a store into an explicitly-annotated slot against a silent bit-mangle.
/// When the initializer/RHS type `src_ty` has NO modeled coercion to the
/// destination slot type `dst_ty`, the classifier yields `.none` and
/// `coerceMode`'s `.no_op, .none => return val` arm passes the value through
/// UNCHANGED — a raw reinterpreting store. That is only DANGEROUS when the
/// value's byte width differs from the slot's: a 16-byte `string` written into
/// a 4-byte `i32` slot overruns it, corrupting memory and segfaulting at run
/// time (issue 0197). A SAME-width `.none` is a bit-compatible reinterpretation
/// sx's passthrough has always performed for legitimate pairs that the
/// classifier doesn't model — `*T → [*]T`, `i64 → isize`, `*void ← *T`, a bare
/// fn-ref into a function slot — so it must stay allowed.
///
/// Reject ONLY a width mismatch: emit a diagnostic and return false so the
/// caller stores a safe default instead of the overrunning value. Returns true
/// when the store is sound (a no-op, a modeled conversion, a same-width
/// reinterpretation, or a deliberate `xx`/`.(T)`). `init_node` is the
/// initializer expression (null when none); `verb`/`name` shape the message.
pub fn checkAssignable(self: *Lowering, src_ty: TypeId, dst_ty: TypeId, span: ast.Span, verb: []const u8, name: []const u8, init_node: ?*const Node) bool {
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
    if (src_ty == .void or dst_ty == .void) return true;
    // An explicit `xx`/`.(T)` is the user opting into a reinterpretation that
    // has no standard coercion — leave the escape hatch intact, width be damned.
    if (init_node) |n| if (initIsExplicitCast(n)) return true;
    if (!self.noneReinterpretIsUnsafe(src_ty, dst_ty)) return true;
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "cannot {s} '{s}' of type '{s}' with a value of type '{s}'", .{ verb, name, self.formatTypeName(dst_ty), self.formatTypeName(src_ty) });
        self.assignability_error_count += 1;
    }
    return false;
}

/// The shared "this implicit passthrough is exempt" gate for the unmodeled-
/// coercion guards (`diagnoseUnmodeledCoercion` / `checkReturnable`), mirroring
/// `checkAssignable`'s rules with the REF-based explicit-cast exemption:
///   - an unresolved/void operand was already diagnosed at its origin;
///   - a diverging value (`noreturn`) never materializes — nothing to weld;
///   - the value is an explicit `xx`/`.(T)` passthrough (the user's opt-in);
///   - the reinterpretation is same-width (`noneReinterpretIsUnsafe` false) —
///     the legitimate bit-compatible family;
///   - an external error already fired (suppress the cascade; the build
///     aborts before the weld could run anyway).
fn implicitNoneMismatchExempt(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId) bool {
    if (src_ty == dst_ty) return true;
    if (src_ty == .unresolved or dst_ty == .unresolved) return true;
    if (src_ty == .void or dst_ty == .void) return true;
    if (src_ty == .noreturn) return true;
    if (self.xx_passthrough_refs.contains(val)) return true;
    if (!self.noneReinterpretIsUnsafe(src_ty, dst_ty)) return true;
    if (self.externalErrorsExist()) return true;
    return false;
}

/// A bare-function VALUE is carried in the legacy integer-word IR type
/// (`func_ref` typed `i64`/`isize` — issue 0237), which must never leak into
/// a user-facing message as the value's type (issue 0338: "cannot coerce a
/// value of type 'i64'" for a fn name). When `val` is a `func_ref`, recover
/// the function's real signature type (implicit ctx param excluded — it is
/// not part of the source-level signature); otherwise return `src_ty`.
fn diagnosedSrcType(self: *Lowering, val: Ref, src_ty: TypeId) TypeId {
    if (src_ty != .i64 and src_ty != .isize) return src_ty;
    const op = self.builder.getRefOp(val) orelse return src_ty;
    if (op != .func_ref) return src_ty;
    const f = &self.module.functions.items[op.func_ref.index()];
    var param_ids = std.ArrayList(TypeId).empty;
    defer param_ids.deinit(self.alloc);
    const skip: usize = if (f.has_implicit_ctx) 1 else 0;
    for (f.params[skip..]) |p| param_ids.append(self.alloc, p.ty) catch return src_ty;
    return self.module.types.functionType(param_ids.items, f.ret);
}

/// The central issue-0191 guard: an IMPLICIT coercion classified `.none` with
/// a byte-width mismatch is a silent weld — the passthrough value would be
/// bit-reinterpreted into a differently-sized slot (return slot, call arg,
/// field/element init, merge phi), corrupting data with no diagnostic. Emit
/// the type-mismatch error; the caller still passes the value through (the
/// build aborts via hasErrors before the IR could reach codegen).
fn diagnoseUnmodeledCoercion(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId) void {
    if (implicitNoneMismatchExempt(self, val, src_ty, dst_ty)) return;
    if (self.diagnostics) |d| {
        const cs = self.builder.current_span;
        d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot coerce a value of type '{s}' to '{s}': no implicit conversion applies", .{ self.formatTypeName(diagnosedSrcType(self, val, src_ty)), self.formatTypeName(dst_ty) });
        self.assignability_error_count += 1;
    }
}

/// Return-path variant of the guard, with a return-specific message and the
/// return VALUE's span (the central `coerceMode` guard only has the builder's
/// current span). Callers must SKIP the plain `coerceToType` when this returns
/// false — otherwise `diagnoseUnmodeledCoercion` would fire a second, redundant
/// diagnostic for the same weld. Shares `assignability_error_count` so the
/// external-error suppression keeps working across both guards.
pub fn checkReturnable(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId, span: ast.Span) bool {
    if (implicitNoneMismatchExempt(self, val, src_ty, dst_ty)) return true;
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "cannot return a value of type '{s}' where '{s}' is expected", .{ self.formatTypeName(diagnosedSrcType(self, val, src_ty)), self.formatTypeName(dst_ty) });
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

/// The core unsafe-store predicate shared by `checkAssignable` and the
/// named-return-default guard: a store of `src_ty` into a `dst_ty` slot has NO
/// modeled coercion (`coerceMode` would pass it through UNCHANGED) AND the two
/// differ in byte width — so the raw store overruns / under-fills the slot,
/// corrupting memory (issue 0197). A same-width `.none` is a legitimate
/// bit-compatible reinterpretation (`*T → [*]T`, `i64 → isize`, `*void ← *T`),
/// which stays allowed. Callers should have already cleared the cheap
/// cascade/escape-hatch cases (unresolved operands, explicit `xx`/`cast`).
pub fn noneReinterpretIsUnsafe(self: *Lowering, src_ty: TypeId, dst_ty: TypeId) bool {
    if (src_ty == dst_ty) return false;
    if (self.coercionResolver().classify(src_ty, dst_ty) != .none) return false;
    // An unmodeled pair where exactly ONE side is an aggregate value
    // (struct/union/tagged union/array/tuple) is NEVER a legitimate
    // bit-reinterpretation, width match or not: the aggregate's bytes pun
    // into a scalar/pointer slot (issue 0303's crash class — a same-width
    // `struct{i64}` passed where a pointer is expected). The same-width
    // exemption below is for the scalar family only (`*T → [*]T`,
    // `i64 → isize`, fn-ref → fn slot).
    if (isAggregateValueKind(self, src_ty) != isAggregateValueKind(self, dst_ty)) return true;
    return !sameStoreWidth(self, src_ty, dst_ty);
}

/// A type whose values are AGGREGATE-shaped at the IR level, for the pun
/// test above — the classification is by representation, not by kind
/// nominality: `string` ({ptr,len}), `any` ({data,type_id}), slices, and
/// closures ({fn,env}) are aggregate-IR even though string/any are
/// builtins. Aggregate↔aggregate same-width reinterprets are the
/// legitimate raw-view family (string→SliceRaw, closure→ClosureRaw);
/// only an aggregate↔scalar pair is unrepresentable. Vectors and
/// optionals are deliberately in NEITHER set (their repr varies /
/// predates this guard) — they never pun-flag.
fn isAggregateValueKind(self: *Lowering, ty: TypeId) bool {
    if (ty == .string or ty == .any) return true;
    if (ty.isBuiltin()) return false;
    return switch (self.module.types.get(ty)) {
        .@"struct", .@"union", .tagged_union, .array, .tuple, .slice, .closure => true,
        else => false,
    };
}

/// ABI/store width of `a` and `b` are equal — the safety test for an unmodeled
/// (`.none`) reinterpreting store (see `noneReinterpretIsUnsafe`). Uses
/// `typeSizeBytes` (the LLVM-accurate ABI size, with natural field alignment),
/// NOT `sizeOf` (which pads every aggregate field to ≥8 and would report
/// `struct{i32,i32}` as 16 — coincidentally matching a 16-byte `string` and
/// letting the raw store overrun the real 8-byte slot). Comptime-only `pack`
/// types have no runtime layout; a pack reaching a store site is a separate,
/// already-diagnosed misuse, so treat it as "same width" to avoid a spurious
/// second error.
fn sameStoreWidth(self: *Lowering, a: TypeId, b: TypeId) bool {
    if (self.module.types.get(a) == .pack or self.module.types.get(b) == .pack) return true;
    return self.module.types.typeSizeBytes(a) == self.module.types.typeSizeBytes(b);
}

pub fn coerceMode(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId, mode: CoerceMode) Ref {
    // Pointer-to-concrete (or concrete-storage value) → `*P`: materialize
    // the borrowed VIEW here, at the node-less layer, so EVERY store site
    // agrees with the node-aware decl/arg arms (issue 0311: an assignment
    // `g = p` classified *C → *P as a plain pointer passthrough — the raw
    // pointer word was stored as if it were a *P and the first dispatch
    // read a garbage vtable out of the concrete struct's bytes).
    if (src_ty != dst_ty and !dst_ty.isBuiltin() and !src_ty.isBuiltin()) {
        const di = self.module.types.get(dst_ty);
        if (di == .pointer and self.getProtocolInfo(di.pointer.pointee) != null and
            self.getProtocolInfo(src_ty) == null)
        {
            const si = self.module.types.get(src_ty);
            if (si == .pointer and self.getProtocolInfo(si.pointer.pointee) == null) {
                if (self.viewOfConcreteAddr(val, si.pointer.pointee, dst_ty)) |v| return v;
            } else if (si == .@"struct") {
                if (self.refStorageAddress(val)) |addr| {
                    if (self.viewOfConcreteAddr(addr, src_ty, dst_ty)) |v| return v;
                }
                if (self.diagnostics) |d| {
                    const cs = self.builder.current_span;
                    d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot store a '{s}' rvalue into '{s}' — an rvalue has no durable storage to view; bind it to a local first, or erase to an owned '{s}' value", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty), self.formatTypeName(di.pointer.pointee) });
                }
                return self.builder.constNull(dst_ty);
            }
        }
    }
    // PLANNING: classify the built-in coercion (conversions.zig).
    // EMISSION: each arm below reproduces the original lowering.
    switch (self.coercionResolver().classify(src_ty, dst_ty)) {
        .no_op => return val,
        // No modeled coercion — the value passes through UNCHANGED. For an
        // EXPLICIT `xx`/`cast(T)` that is the intended escape hatch: record
        // the ref so downstream IMPLICIT sites (a return, a call arg, a field
        // init consuming the cast's result) honour the opt-in. For an IMPLICIT
        // coercion a same-width passthrough is the long-standing legitimate
        // bit-reinterpretation (`*T → [*]T`, `i64 → isize`, fn-ref → fn slot);
        // a WIDTH-MISMATCHED one is the issue-0191 silent weld (a 16-byte
        // string "returned" as i64, a struct passed where a scalar is
        // expected) — diagnose it instead of fabricating garbage.
        .none => {
            switch (mode) {
                .explicit => self.xx_passthrough_refs.put(val, {}) catch {},
                .implicit => diagnoseUnmodeledCoercion(self, val, src_ty, dst_ty),
            }
            return val;
        },
        // Unbox Any → concrete type. An IMPLICIT unbox (`s : S = some_any`) is
        // rejected (issue 0198): the unbox blindly reinterprets the boxed payload
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
                    d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "an 'any' does not implicitly unbox to '{s}': the boxed type is not checked, so a wrong target reinterprets the payload (a wrong scalar silently yields garbage; an aggregate dereferences it and crashes). Dispatch on the value's type with `match`, or force it with `xx` if you know the boxed type.", .{self.formatTypeName(dst_ty)});
                }
                // Diagnosed — `hasErrors()` aborts the build before run time; the
                // emitted op is never executed.
            }
            return self.builder.emit(.{ .unbox_any = .{ .operand = val } }, dst_ty);
        },
        // Box concrete → any. Node-less coercion site: always a spill
        // (the node-aware borrow path is `boxAnyOf` at lowerXX / the
        // variadic pack / the decl-init hooks).
        .box_any => return boxAnyOf(self, val, src_ty, null),
        // Closure VALUE → bare function-pointer slot: not soundly representable.
        // A bare `(T) -> U` slot is called as `fn_ptr(ctx, args)` with NO env
        // arg, but a closure's underlying fn takes an env slot — so passing a
        // closure value's fn_ptr drops the env and shifts the args (UB for a
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
        // Tuple → Tuple element-wise coercion (e.g. a `(i64, i64)` literal
        // flowing into a `(i32, i32)` slot — the multi-value failable success
        // tuple). Same arity: extract each slot, coerce it, rebuild.
        .tuple_elementwise => {
            const si = self.module.types.get(src_ty);
            const di = self.module.types.get(dst_ty);
            var elems = std.ArrayList(Ref).empty;
            defer elems.deinit(self.alloc);
            for (si.tuple.fields, di.tuple.fields, 0..) |sf, df, i| {
                const fv = self.builder.emit(.{ .tuple_get = .{ .base = val, .field_index = @intCast(i), .base_type = src_ty } }, sf);
                elems.append(self.alloc, self.coerceMode(fv, sf, df, mode)) catch unreachable;
            }
            return self.builder.emit(.{ .tuple_init = .{ .fields = self.alloc.dupe(Ref, elems.items) catch unreachable } }, dst_ty);
        },
        // Anonymous/positional STRUCT → tuple of the same arity, element-wise
        // (the untyped `.{ }` literal is an anon struct; its values flow into
        // tuple slots exactly as the old `.( )` tuple literal did).
        .struct_to_tuple => {
            const si = self.module.types.get(src_ty);
            const di = self.module.types.get(dst_ty);
            var elems = std.ArrayList(Ref).empty;
            defer elems.deinit(self.alloc);
            for (si.@"struct".fields, di.tuple.fields, 0..) |sf, df, i| {
                const fv = self.builder.structGet(val, @intCast(i), sf.ty);
                elems.append(self.alloc, self.coerceMode(fv, sf.ty, df, mode)) catch unreachable;
            }
            return self.builder.emit(.{ .tuple_init = .{ .fields = self.alloc.dupe(Ref, elems.items) catch unreachable } }, dst_ty);
        },
        // Optional → Concrete unwrapping — ONLY when the value is PROVEN
        // present by flow narrowing (issue 0179). An un-narrowed `?T` flowing
        // into a concrete slot used to unwrap UNCONDITIONALLY, yielding the
        // zero payload of a null optional with no diagnostic (silent
        // miscompile across the whole `?T → concrete` family). Per spec the
        // only legal extractions are `!` / `??` / binding / match / a `!= null`
        // guard; reject everything else loudly. `lowerIdentifier` tags the
        // loaded `Ref` of a guard-narrowed local into `narrowed_refs`.
        .optional_unwrap => {
            if (!self.narrowed_refs.contains(val)) {
                if (self.diagnostics) |d| {
                    const cs = self.builder.current_span;
                    d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot use a value of type '{s}' where '{s}' is expected: an optional does not implicitly unwrap; force-unwrap with '!', supply a fallback with '?? <default>', bind it (`if v := ...`), or guard with '!= null'", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty) });
                }
                return val; // hasErrors() aborts before codegen
            }
            const child_ty = self.module.types.get(src_ty).optional.child;
            const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = val } }, child_ty);
            return self.coerceMode(unwrapped, child_ty, dst_ty, mode);
        },
        // Optional → bool: there is no implicit presence-test coercion. The
        // old unwrap-then-narrow ladder silently produced `false` for every
        // optional (issue 0169). Reject with a fix-it pointing at `!= null`.
        .optional_to_bool_reject => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot use a value of type '{s}' where 'bool' is expected; test presence explicitly with '!= null'", .{self.formatTypeName(src_ty)});
            }
            return val;
        },
        // string → cstring: ONLY a string LITERAL coerces implicitly — its
        // bytes are a terminated constant (Odin's literal blessing). Any
        // other string may be an unterminated view, so it must materialize
        // through `to_cstring`.
        // The destination is `.cstring` OR a `[*]u8`/`[*]i8` C byte pointer
        // (the C-import synthesis of `char const *`) — the emitted value is
        // the data pointer, typed as the DESTINATION.
        .string_to_cstring => {
            if (self.builder.isConstString(val)) {
                return self.builder.emit(.{ .data_ptr = .{ .operand = val } }, dst_ty);
            }
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "only a string LITERAL coerces to '{s}' implicitly; an arbitrary string may be an unterminated view — materialize it with to_cstring(s)", .{self.formatTypeName(dst_ty)});
            }
            return val;
        },
        // cstring → string: the length is implicit (strlen), so the
        // conversion is never silent — `from_cstring(c)` is the zero-copy
        // view, `substr(from_cstring(c), 0, ...)` the owned copy.
        .cstring_to_string_reject => {
            if (self.diagnostics) |d| {
                const cs = self.builder.current_span;
                d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "'cstring' does not coerce to 'string' implicitly (the length is implicit); convert with from_cstring(c)", .{});
            }
            return val;
        },
        // void → Optional: produce null (void is the type of null_literal)
        .void_to_optional => return self.builder.constNull(dst_ty),
        // ?A → ?B: presence-preserving payload coercion. The naive route
        // (fall through to `.optional_wrap`) unwrapped the SOURCE optional
        // unconditionally and re-wrapped as always-present, dropping the
        // has-bit — a null `?i32` became a present `?i64` carrying zero
        // (issue 0180: generic `??` returning the wrong fallback). Branch on
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
            const coerced = self.coerceMode(val, src_ty, child_ty, mode);
            // The inner coercion may classify as `.none` (no built-in applies)
            // and pass `val` through UNCHANGED — e.g. wrapping a `?i64` value
            // into a `?(?i64)` whose payload is the 1-tuple `(?i64)`. Building
            // the optional then inserts a `{i64,i1}` into a `{{i64,i1}}` slot,
            // producing malformed IR that aborts the LLVM verifier (issue 0165).
            // If the coerced operand's type does not match the optional's child
            // type, the wrap is invalid — diagnose loudly instead of emitting a
            // corrupt InsertValue. (`hasErrors()` then aborts the build.)
            const coerced_ty = self.builder.getRefType(coerced);
            if (coerced_ty != child_ty) {
                if (self.diagnostics) |d| {
                    const cs = self.builder.current_span;
                    // Only mention the `(T)`-is-a-1-tuple gotcha when the payload
                    // actually IS a tuple (the `?(?T)` typo); for any other
                    // mismatch the parens note would be misleading.
                    const note: []const u8 = if (self.module.types.get(child_ty) == .tuple)
                        " (note: '(T,)' with a trailing comma is a 1-tuple; '(T)' without a comma groups to the inner type)"
                    else
                        "";
                    d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot wrap a value of type '{s}' into optional '{s}': its payload type is '{s}'{s}", .{ self.formatTypeName(src_ty), self.formatTypeName(dst_ty), self.formatTypeName(child_ty), note });
                }
                return val;
            }
            return self.builder.emit(.{ .optional_wrap = .{ .operand = coerced } }, dst_ty);
        },
        // Concrete → Protocol (auto type erasure)
        .erase_protocol => {
            const proto_name = self.module.types.getString(self.module.types.get(dst_ty).@"struct".name);
            const ctn = self.resolveConcreteTypeName(src_ty).?;
            const node_less_identity = self.protocolIsIdentity(dst_ty);
            // If src is a pointer, use directly; otherwise alloca+store + heap-copy
            var concrete_ptr = val;
            var concrete_ty = src_ty;
            var heap_copy = false;
            if (!src_ty.isBuiltin() and self.module.types.get(src_ty) == .pointer) {
                // Pointer operand: identity borrows the pointee (the user
                // owns its lifetime); value/own demands the explicit
                // snapshot/view spelling.
                if (!node_less_identity) return self.demandOwnedErasure(dst_ty, proto_name, null, true);
                concrete_ty = self.module.types.get(src_ty).pointer.pointee;
                heap_copy = false;
            } else {
                // A VALUE — a builtin scalar (`f32`, `i64`, …) OR a struct /
                // aggregate rvalue. A value has no address of its own, so
                // materialize a stack slot and heap-copy it: the erased
                // protocol value's ctx pointer must outlive this frame.
                //
                // Builtins previously skipped this branch entirely (the guard
                // was `if (!src_ty.isBuiltin())`), leaving `concrete_ptr = val`
                // — the raw SCALAR — passed to `buildProtocolValue` as the ctx
                // "pointer". That produced a malformed `insertvalue {ptr,ptr}
                // undef, <scalar>, 0` and an LLVM verification failure when a
                // builtin value was erased to a protocol (issue 0279).
                //
                // This node-less layer serves call paths that lowered the
                // arg before its param target was known (UFCS/generic
                // routes). `refStorageAddress` proves from the defining
                // instruction whether the value is a READ of named storage:
                //   - identity target: storage → borrow it; genuine rvalue
                //     → refusal (identity objects need a name).
                //   - value/own target: storage → the DEMAND error (an
                //     implicit lvalue erasure would silently heap-copy);
                //     genuine rvalue → the owning copy (the invariant).
                if (node_less_identity) {
                    if (self.refStorageAddress(val)) |addr| {
                        concrete_ptr = addr;
                        heap_copy = false;
                    } else if (self.refuseIdentityRvalueErasure(dst_ty, null)) {
                        return self.builder.emit(.{ .placeholder = self.module.types.internString("identity-erasure") }, dst_ty);
                    } else {
                        const slot = self.builder.alloca(src_ty);
                        self.builder.store(slot, val);
                        concrete_ptr = slot;
                        heap_copy = true;
                    }
                } else {
                    if (self.refStorageAddress(val) != null)
                        return self.demandOwnedErasure(dst_ty, proto_name, null, false);
                    const slot = self.builder.alloca(src_ty);
                    self.builder.store(slot, val);
                    concrete_ptr = slot;
                    heap_copy = true;
                }
            }
            return self.buildProtocolValue(concrete_ptr, proto_name, ctn, dst_ty, concrete_ty, heap_copy);
        },
        .int_to_float => return self.builder.emit(.{ .int_to_float = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .float_to_int => {
            // Implicit float→int narrowing follows the unified rule (the
            // same `floatToIntExact` the array-dim / `$K: Count` paths use):
            // a compile-time INTEGRAL float folds to its int, a NON-integral
            // one is a compile error. Explicit `xx` / `cast` (mode
            // `.explicit`) skips this and truncates. A runtime float has no
            // compile-time value to fold — it truncates as before.
            if (mode == .implicit) {
                if (self.builder.constFloatInfo(val)) |info| {
                    if (program_index_mod.floatToIntExact(info.value)) |iv| {
                        return self.builder.constInt(iv, dst_ty);
                    }
                    // Non-integral: diagnose, then fall through to the
                    // truncating op below so lowering finishes and
                    // `hasErrors()` aborts the build.
                    self.diagNonIntegralNarrow(.{ .start = info.span.start, .end = info.span.end }, info.value, dst_ty);
                }
            }
            return self.builder.emit(.{ .float_to_int = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty);
        },
        // Ptr ↔ Int — explicit `xx ptr` to/from an integer-typed slot.
        // Emits a `bitcast` IR op; emit_llvm.zig's bitcast arm dispatches
        // to LLVMBuildPtrToInt / LLVMBuildIntToPtr at the LLVM level
        // since LLVMBuildBitCast itself doesn't accept ptr↔int.
        .ptr_int_bitcast => return self.builder.emit(.{ .bitcast = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .narrow => return self.builder.emit(.{ .narrow = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .widen => return self.builder.emit(.{ .widen = .{ .operand = val, .from = src_ty, .to = dst_ty } }, dst_ty),
        .array_to_slice => {
            // Implicit array→slice coercion (`fill(arr)` where `fill :: (s:
            // []T)`). The explicit `arr[0..N]` syntax aliases the array's
            // storage (issue 0225); this implicit path MUST match, or passing
            // `arr` vs `arr[0..]` silently differs (issue 0264). For an
            // ADDRESSABLE array, build a zero-copy VIEW over its storage.
            if (self.arrayToSliceView(val, src_ty)) |view| return view;
            // NON-addressable rvalue array (`fill(makeArr())`): keep the
            // COPYING `array_to_slice` op (alloca+store). This is the general
            // coercion arm, reached for CALL ARGUMENTS — the temporary lives
            // for the call's duration, so a copy the callee mutates in place
            // is SOUND (the callee cannot outlive the argument). The
            // slice-typed BINDING form (`s : []T = makeArr()`, handled in
            // stmt.zig) likewise copies into a function-entry slot that
            // outlives the binding — sound, never dangling. Both differ from
            // 0225's SUBSLICE of a temporary, which aliases the temp directly
            // (dangling) and IS rejected. Recorded in specs.md §Subslicing.
            return self.builder.emit(.{ .array_to_slice = .{ .operand = val } }, dst_ty);
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

/// Apply C default argument promotion to variadic-tail args. These rules
/// (bool/i8/i16/u8/u16 → i32, f32 → f64) match the C calling convention's
/// implicit promotions when an argument is passed through `...`.
pub fn promoteCVariadicArgs(self: *Lowering, args: []Ref, fixed_count: usize) void {
    if (args.len <= fixed_count) return;
    for (args[fixed_count..]) |*arg| {
        const src_ty = self.builder.getRefType(arg.*);
        const promoted: TypeId = switch (src_ty) {
            .bool, .i8, .i16, .u8, .u16 => .i32,
            .f32 => .f64,
            else => continue,
        };
        arg.* = self.coerceToType(arg.*, src_ty, promoted);
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
            // Array → many_pointer decay: alloca the array, GEP to first element
            if (src_info == .array and dst_info == .many_pointer) {
                const slot = self.builder.alloca(src_ty);
                self.builder.store(slot, args[i]);
                const zero = self.builder.constInt(0, .i64);
                args[i] = self.builder.emit(.{ .index_gep = .{ .lhs = slot, .rhs = zero } }, dst_ty);
                continue;
            }
            // Implicit address-of: passing T value where *T is expected → alloca + store
            // Only when the pointee type matches the source type.
            if (dst_info == .pointer and src_info != .pointer and dst_info.pointer.pointee == src_ty) {
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
            // struct's bytes where a pointer is expected (issue 0303's
            // silent LLVM-verifier crash).
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
