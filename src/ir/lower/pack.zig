const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;

/// Lower each pack element to a Ref: `pack_name[i]` when `method` is null,
/// or `pack_name[i].method()` when given. Synthesizes the index/field/call
/// AST per element and lowers it (substitution turns `xs[i]` into the
/// concrete arg; UFCS dispatches the method). Caller owns the returned slice.
pub fn lowerPackElems(self: *Lowering, pack_name: []const u8, method: ?[]const u8, span: ast.Span) []Ref {
    const n: u32 = if (self.pack_param_count) |ppc| (ppc.get(pack_name) orelse 0) else 0;
    var refs = std.ArrayList(Ref).empty;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const id_node = self.alloc.create(Node) catch break;
        id_node.* = .{ .span = span, .data = .{ .identifier = .{ .name = pack_name } } };
        const idx_node = self.alloc.create(Node) catch break;
        idx_node.* = .{ .span = span, .data = .{ .int_literal = .{ .value = @intCast(i) } } };
        const index_node = self.alloc.create(Node) catch break;
        index_node.* = .{ .span = span, .data = .{ .index_expr = .{ .object = id_node, .index = idx_node } } };
        var elem_node = index_node;
        if (method) |m| {
            const fa_node = self.alloc.create(Node) catch break;
            fa_node.* = .{ .span = span, .data = .{ .field_access = .{ .object = index_node, .field = m } } };
            const call_node = self.alloc.create(Node) catch break;
            call_node.* = .{ .span = span, .data = .{ .call = .{ .callee = fa_node, .args = &.{} } } };
            elem_node = call_node;
        }
        refs.append(self.alloc, self.lowerExpr(elem_node)) catch break;
    }
    return refs.toOwnedSlice(self.alloc) catch &.{};
}

/// Value-position pack projection `xs.<method>`: call the (zero-arg)
/// protocol method on each element and collect the results into a tuple
/// `(xs[0].<method>(), …, xs[N-1].<method>())`. N=0 yields the empty tuple.
pub fn lowerPackValueProjection(self: *Lowering, pack_name: []const u8, method: []const u8, span: ast.Span) Ref {
    const refs = self.lowerPackElems(pack_name, method, span);
    defer self.alloc.free(refs);
    var tys = std.ArrayList(TypeId).empty;
    defer tys.deinit(self.alloc);
    for (refs) |r| tys.append(self.alloc, self.builder.getRefType(r)) catch {};
    const tuple_ty = self.module.types.intern(.{ .tuple = .{
        .fields = self.alloc.dupe(TypeId, tys.items) catch return self.builder.constInt(0, .void),
        .names = null,
    } });
    const owned = self.alloc.dupe(Ref, refs) catch return self.builder.constInt(0, .void);
    return self.builder.emit(.{ .tuple_init = .{ .fields = owned } }, tuple_ty);
}

/// If `operand` is a pack spread — `..xs` (bare pack) or `..xs.method`
/// (per-element projection) — return the per-element Refs to splice into a
/// call's positional args. Null when it's not a pack spread (e.g. a runtime
/// slice `..arr`, handled by the slice-variadic path). Caller owns the slice.
pub fn packSpreadRefs(self: *Lowering, operand: *const Node, span: ast.Span) ?[]Ref {
    const ppc = self.pack_param_count orelse return null;
    switch (operand.data) {
        .identifier => |id| {
            if (ppc.contains(id.name)) return self.lowerPackElems(id.name, null, span);
        },
        .field_access => |fa| {
            if (fa.object.data == .identifier and ppc.contains(fa.object.data.identifier.name)) {
                return self.lowerPackElems(fa.object.data.identifier.name, fa.field, span);
            }
        },
        else => {},
    }
    return null;
}

/// Value spread (specs.md §"Tuple parallels"): `..t` where `t` is a concrete
/// TUPLE or fixed-length ARRAY value spreads its elements into a call's
/// positional args — this is how a materialized pack `.(..xs)` is later
/// re-spread (`f(..stored)`). Lowers the operand ONCE and returns one Ref per
/// element. Null when the operand is not a tuple/array value: a runtime slice
/// has no comptime-known length and stays on the slice-variadic path
/// (`packVariadicCallArgs`). Caller owns the returned slice.
pub fn valueSpreadRefs(self: *Lowering, operand: *const Node, span: ast.Span) ?[]Ref {
    _ = span;
    const ty = self.inferExprType(operand);
    if (ty.isBuiltin()) return null;
    switch (self.module.types.get(ty)) {
        .tuple => |t| {
            const obj = self.lowerExpr(operand);
            var refs = std.ArrayList(Ref).empty;
            for (t.fields, 0..) |fty, i| {
                refs.append(self.alloc, self.builder.structGet(obj, @intCast(i), fty)) catch break;
            }
            return refs.toOwnedSlice(self.alloc) catch &.{};
        },
        // A struct value spreads field-wise, same as a tuple — this is what
        // lets a materialized pack (`stored := .{ ..xs };`, an anonymous
        // positional struct) re-spread with `f(..stored)`.
        .@"struct" => |s| {
            const obj = self.lowerExpr(operand);
            var refs = std.ArrayList(Ref).empty;
            for (s.fields, 0..) |f, i| {
                refs.append(self.alloc, self.builder.structGet(obj, @intCast(i), f.ty)) catch break;
            }
            return refs.toOwnedSlice(self.alloc) catch &.{};
        },
        .array => |a| {
            // GEP + load each element from the array's storage; a
            // non-addressable array value is spilled to a temp slot first
            // (never `index_get` on the loaded VALUE — the 0124 lesson).
            const storage = self.getExprAlloca(operand) orelse blk: {
                const v = self.lowerExpr(operand);
                const slot = self.builder.alloca(ty);
                self.builder.store(slot, v);
                break :blk slot;
            };
            const elem_ptr_ty = self.module.types.ptrTo(a.element);
            var refs = std.ArrayList(Ref).empty;
            var i: u32 = 0;
            while (i < a.length) : (i += 1) {
                const idx = self.builder.constInt(@intCast(i), .i64);
                const gep = self.builder.emit(.{ .index_gep = .{ .lhs = storage, .rhs = idx } }, elem_ptr_ty);
                refs.append(self.alloc, self.builder.load(gep, a.element)) catch break;
            }
            return refs.toOwnedSlice(self.alloc) catch &.{};
        },
        else => return null,
    }
}

/// Materialize a pack's monomorphized element VALUES into a tuple —
/// `.(xs[0], …, xs[N-1])`. Used when a closure captures a pack: the pack is
/// comptime state of the enclosing mono (arg AST + `__pack_*` params) and
/// cannot be re-expanded inside the deferred body, whose frame is a different
/// function — so the capture stores this tuple BY VALUE in the closure env,
/// and the body spreads/indexes it as an ordinary tuple.
pub fn materializePackTuple(self: *Lowering, pack_name: []const u8, span: ast.Span) struct { ref: Ref, ty: TypeId } {
    const refs = self.lowerPackElems(pack_name, null, span);
    defer self.alloc.free(refs);
    var tys = std.ArrayList(TypeId).empty;
    defer tys.deinit(self.alloc);
    for (refs) |r| tys.append(self.alloc, self.builder.getRefType(r)) catch {};
    const tuple_ty = self.module.types.intern(.{ .tuple = .{
        .fields = self.alloc.dupe(TypeId, tys.items) catch &.{},
        .names = null,
    } });
    const owned = self.alloc.dupe(Ref, refs) catch &.{};
    return .{ .ref = self.builder.emit(.{ .tuple_init = .{ .fields = owned } }, tuple_ty), .ty = tuple_ty };
}

/// Detect `<pack_name>[<int_literal>]` where the literal exceeds
/// the pack arity (or is negative). Emits a diagnostic and
/// returns true; caller skips the standard indexing path and
/// returns a placeholder Ref. Returns false for non-pack bases,
/// non-literal indices, or in-range indices.
pub fn diagPackIndexOOB(self: *Lowering, ie: *const ast.IndexExpr) bool {
    const ppc = self.pack_param_count orelse return false;
    if (ie.object.data != .identifier) return false;
    const pack_name = ie.object.data.identifier.name;
    const n = ppc.get(pack_name) orelse return false;
    // Any comptime index (int literal or a comptime-constant cursor) that's
    // out of range — runtime indices are handled by the caller's
    // must-be-comptime check.
    const raw: i64 = self.comptimeIndexOf(ie.index) orelse return false;
    if (raw >= 0 and @as(u32, @intCast(raw)) < n) return false;
    if (self.diagnostics) |diags| {
        diags.addFmt(.err, ie.index.span, "pack index {} out of bounds: '{s}' has {} element{s}", .{
            raw, pack_name, n, if (n == 1) @as([]const u8, "") else @as([]const u8, "s"),
        });
    }
    return true;
}

/// Returns the call-site arg AST node when `ie` matches
/// `<pack_name>[<comptime_int_literal>]` with the pack name bound
/// in the active `pack_arg_nodes` map and the index in range.
/// Otherwise null — caller falls back to standard slice indexing.
pub fn packArgNodeAt(self: *Lowering, ie: *const ast.IndexExpr) ?*const Node {
    const pan = self.pack_arg_nodes orelse return null;
    if (ie.object.data != .identifier) return null;
    const arg_nodes = pan.get(ie.object.data.identifier.name) orelse return null;
    const raw: i64 = self.comptimeIndexOf(ie.index) orelse return null;
    if (raw < 0) return null;
    const i: usize = @intCast(raw);
    if (i >= arg_nodes.len) return null;
    return arg_nodes[i];
}

/// Resolve an index expression to a comptime-known integer: a literal,
/// or an identifier bound to an `int_val` in `comptime_constants` (e.g.
/// the cursor of an `inline for 0..N (i)` unroll). Otherwise null.
pub fn comptimeIndexOf(self: *Lowering, index: *const Node) ?i64 {
    switch (index.data) {
        .int_literal => |lit| return lit.value,
        .char_literal => |lit| return lit.value,
        .identifier => |id| {
            if (self.comptime_constants.get(id.name)) |cv| {
                switch (cv) {
                    .int_val => |iv| return iv,
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
    }
}

const PackValueKind = enum { storage, call_arg, return_value, runtime_iter, generic };

/// `xs` is a pack name used where a runtime value is required. A pack is
/// comptime-only (Decision 1), so this is an error — with a context-tailored
/// suggestion for how to express the intent instead.
pub fn diagPackAsValue(self: *Lowering, name: []const u8, span: ast.Span, kind: PackValueKind) Ref {
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "pack '{s}' has no runtime value — a pack is comptime-only and can't be used as a value here", .{name});
        switch (kind) {
            .storage => d.addHelpFmt(id, span, null, "to store it, materialize a tuple: `(..{s})`", .{name}),
            .call_arg => d.addHelpFmt(id, span, null, "to pass it to a `[]any`/`[]P` parameter, materialize it with `xx {s}`", .{name}),
            .return_value => d.addHelpFmt(id, span, null, "to return it, return a tuple `(..{s})` and make the return type that tuple", .{name}),
            .runtime_iter => d.addHelpFmt(id, span, null, "to iterate at comptime use `inline for {s} (x)` (or `inline for 0..{s}.len (i)` for the index); for a runtime loop declare it as `..{s}: []P` (a protocol slice) instead of a pack", .{ name, name, name }),
            .generic => d.addHelpFmt(id, span, null, "materialize a tuple `(..{s})` to store it, or `xx {s}` to convert it to an expected `[]any`/`[]P` slice", .{ name, name }),
        }
    }
    return self.emitPlaceholder(name);
}

/// True when `name` is a pack parameter bound in the current mono body.
pub fn isPackName(self: *Lowering, name: []const u8) bool {
    const ppc = self.pack_param_count orelse return false;
    return ppc.contains(name);
}

/// `xx <pack>` with a slice target: materialize the comptime pack into a
/// runtime `[]elem` by lowering each element node and boxing (`[]Any`) or
/// `xx`-erasing (`[]P`) it into a stack `[N]elem`, then return the slice.
/// This is the explicit pack→slice bridge (issue 0053).
pub fn lowerPackToSlice(self: *Lowering, pack_name: []const u8, slice_ty: TypeId) Ref {
    const arg_nodes = (self.pack_arg_nodes orelse return self.builder.constInt(0, .unresolved)).get(pack_name) orelse
        return self.builder.constInt(0, .unresolved);
    const elem_ty = self.module.types.get(slice_ty).slice.element;
    const is_any = elem_ty == .any;
    const elem_is_protocol = blk: {
        if (elem_ty.isBuiltin()) break :blk false;
        const ei = self.module.types.get(elem_ty);
        break :blk ei == .@"struct" and ei.@"struct".is_protocol;
    };
    const slice_slot = self.builder.alloca(slice_ty);
    const ptr_gep = self.builder.structGepTyped(slice_slot, 0, self.module.types.ptrTo(elem_ty), slice_ty);
    const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, slice_ty);
    if (arg_nodes.len == 0) {
        self.builder.store(ptr_gep, self.builder.constNull(self.module.types.ptrTo(elem_ty)));
        self.builder.store(len_gep, self.builder.constInt(0, .i64));
        return self.builder.load(slice_slot, slice_ty);
    }
    const array_ty = self.module.types.arrayOf(elem_ty, @intCast(arg_nodes.len));
    const array_slot = self.builder.alloca(array_ty);
    for (arg_nodes, 0..) |arg, i| {
        var val = self.lowerExpr(arg);
        var source_ty = self.inferExprType(arg);
        if (source_ty == .unresolved) source_ty = self.builder.getRefType(val);
        if (is_any) {
            if (source_ty != .any) val = self.boxAnyOf(val, source_ty, arg);
        } else if (elem_is_protocol) {
            if (source_ty != elem_ty) val = self.buildProtocolErasure(val, arg, source_ty, elem_ty);
        }
        const ep = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = self.builder.constInt(@intCast(i), .i64) } }, self.module.types.ptrTo(elem_ty));
        self.builder.store(ep, val);
    }
    const data_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = self.builder.constInt(0, .i64) } }, self.module.types.ptrTo(elem_ty));
    self.builder.store(ptr_gep, data_ptr);
    self.builder.store(len_gep, self.builder.constInt(@intCast(arg_nodes.len), .i64));
    return self.builder.load(slice_slot, slice_ty);
}

/// Pack variadic arguments into a []Any slice. Each arg is boxed as Any {tag, value},
/// stored into a stack-allocated array, and the slice {ptr, len} is bound to param_name.
pub fn lowerVariadicArgs(self: *Lowering, param_name: []const u8, call_args: []const *const Node, start_idx: usize) void {
    const any_slice_ty = self.module.types.sliceOf(.any);
    const n = if (call_args.len > start_idx) call_args.len - start_idx else 0;

    if (n == 0) {
        // Empty slice: {null, 0}
        const null_ptr = self.builder.constNull(self.module.types.ptrTo(.any));
        const zero_len = self.builder.constInt(0, .i64);
        const slice_slot = self.builder.alloca(any_slice_ty);
        // Store ptr (field 0) and len (field 1) into the slice alloca
        const ptr_gep = self.builder.structGepTyped(slice_slot, 0, self.module.types.ptrTo(.any), any_slice_ty);
        self.builder.store(ptr_gep, null_ptr);
        const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, any_slice_ty);
        self.builder.store(len_gep, zero_len);
        if (self.scope) |scope| {
            scope.put(param_name, .{ .ref = slice_slot, .ty = any_slice_ty, .is_alloca = true });
        }
        return;
    }

    // Allocate stack array [N x Any]
    const array_ty = self.module.types.arrayOf(.any, @intCast(n));
    const array_slot = self.builder.alloca(array_ty);

    // Box each arg and store into array
    for (call_args[start_idx..], 0..) |arg, i| {
        var val = self.lowerExpr(arg);
        var source_ty = self.inferExprType(arg);
        // If AST-based inference falls back to .i64 but the lowered ref is a string/struct, use that
        if (source_ty == .unresolved) {
            const ref_ty = self.builder.getRefType(val);
            if (ref_ty == .string or ref_ty == .f32 or ref_ty == .f64 or ref_ty == .bool) {
                source_ty = ref_ty;
            } else if (!ref_ty.isBuiltin()) {
                const ri = self.module.types.get(ref_ty);
                if (ri == .@"struct" or ri == .slice or ri == .optional or ri == .closure or ri == .tuple) {
                    source_ty = ref_ty;
                }
            }
        }
        // Auto-unwrap optionals: box inner value if present, else box string "null"
        if (!source_ty.isBuiltin()) {
            const opt_info = self.module.types.get(source_ty);
            if (opt_info == .optional) {
                const child_ty = opt_info.optional.child;
                const has_val = self.builder.emit(.{ .optional_has_value = .{ .operand = val } }, .bool);
                const some_bb = self.freshBlock("opt.some");
                const none_bb = self.freshBlock("opt.none");
                const merge_bb = self.freshBlockWithParams("opt.merge", &.{TypeId.any});
                self.builder.condBr(has_val, some_bb, &.{}, none_bb, &.{});
                self.builder.switchToBlock(some_bb);
                const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = val } }, child_ty);
                const boxed_inner = self.boxAnyOf(unwrapped, child_ty, null);
                self.builder.br(merge_bb, &.{boxed_inner});
                self.builder.switchToBlock(none_bb);
                const null_str_id = self.module.types.internString("null");
                const null_str = self.builder.constString(null_str_id);
                const boxed_null = self.boxAnyOf(null_str, .string, null);
                self.builder.br(merge_bb, &.{boxed_null});
                self.builder.switchToBlock(merge_bb);
                val = self.builder.blockParam(merge_bb, 0, TypeId.any);
                source_ty = .any;
            }
        }
        const boxed = if (source_ty == .any) val else self.boxAnyOf(val, source_ty, arg);
        // GEP to array[i] and store
        const idx_ref = self.builder.constInt(@intCast(i), .i64);
        const elem_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = idx_ref } }, self.module.types.ptrTo(.any));
        self.builder.store(elem_ptr, boxed);
    }

    // Build slice {ptr_to_first_element, len}
    const slice_slot = self.builder.alloca(any_slice_ty);
    // Get pointer to first element (array_slot is *[N x Any], GEP to element 0 gives *Any)
    const zero = self.builder.constInt(0, .i64);
    const data_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = zero } }, self.module.types.ptrTo(.any));
    const len_ref = self.builder.constInt(@intCast(n), .i64);
    // Store into slice fields
    const ptr_gep = self.builder.structGepTyped(slice_slot, 0, self.module.types.ptrTo(.any), any_slice_ty);
    self.builder.store(ptr_gep, data_ptr);
    const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, any_slice_ty);
    self.builder.store(len_gep, len_ref);

    if (self.scope) |scope| {
        scope.put(param_name, .{ .ref = slice_slot, .ty = any_slice_ty, .is_alloca = true });
    }
}

/// Pack variadic args into a slice for regular function calls.
/// Detects variadic params in the function decl, packs remaining args into a typed slice,
/// and replaces the args list with [fixed_args..., slice_ref].
pub fn packVariadicCallArgs(self: *Lowering, fd: *const ast.FnDecl, c: *const ast.Call, args: *std.ArrayList(Ref)) void {
    // A lib-less C-import variadic via the `extern` keyword (or `#import c`
    // `extern` keyword — uses the C calling convention's `...` tail: extras are
    // passed through directly with default argument promotion (handled at the
    // call site), not packed into an sx slice. Mirrors the `is_variadic` drop
    // in `declareFunction`.
    if ((fd.extern_export == .extern_) and
        fd.params.len > 0 and fd.params[fd.params.len - 1].is_variadic)
    {
        return;
    }
    // Find variadic param index. The two surface forms differ in
    // what `p.type_expr` resolves to: legacy `name: ..T` declares T
    // (element type), new `..name: []T` declares []T (already a
    // slice). Unwrap the latter so the per-element packing below
    // sees T in both cases.
    var variadic_idx: ?usize = null;
    var elem_ty: TypeId = .any;
    for (fd.params, 0..) |p, i| {
        if (p.is_variadic) {
            variadic_idx = i;
            const declared = self.resolveTypeWithBindings(p.type_expr);
            elem_ty = declared;
            if (!declared.isBuiltin()) {
                const info = self.module.types.get(declared);
                if (info == .slice) elem_ty = info.slice.element;
            }
            break;
        }
    }
    const vi = variadic_idx orelse return; // no variadic param

    // Number of non-variadic args
    const fixed_count = vi;
    const variadic_count = if (args.items.len > fixed_count) args.items.len - fixed_count else 0;
    const slice_ty = self.module.types.sliceOf(elem_ty);

    // Check for spread operator: sum(..arr) — single spread arg becomes the slice directly.
    // Only a SLICE/ARRAY operand passes through whole: a tuple operand was
    // already expanded element-wise at the call's arg loop (value spread) and
    // repacks via the generic path below — passing a tuple through as-is was
    // a call-signature mismatch that failed LLVM verification (issue 0156p2).
    if (variadic_count == 1 and fixed_count < c.args.len) {
        const arg_node = c.args[fixed_count];
        if (arg_node.data == .spread_expr) {
            const spread = arg_node.data.spread_expr;
            const arr_ty = self.inferExprType(spread.operand);
            const arr_info: ?types.TypeInfo = if (arr_ty.isBuiltin()) null else self.module.types.get(arr_ty);
            if (arr_info != null and (arr_info.? == .array or arr_info.? == .slice)) {
                const arr_val = self.lowerExpr(spread.operand);
                // Convert array to slice. For an ADDRESSABLE array build a
                // zero-copy VIEW over its storage (issue 0264 — consistent
                // with the direct-arg array→slice coercion and 0225's aliasing
                // subslice), so `sum(..arr)` sees the same backing as `arr`. A
                // NON-addressable rvalue array (`sum(..makeArr())`) keeps the
                // copying `array_to_slice` op: this is a call ARGUMENT, so the
                // temp lives for the call's duration — a copy is SOUND.
                const slice_val = switch (arr_info.?) {
                    .array => self.arrayToSliceView(arr_val, arr_ty) orelse
                        self.builder.emit(.{ .array_to_slice = .{ .operand = arr_val } }, slice_ty),
                    else => arr_val,
                };
                args.shrinkRetainingCapacity(fixed_count);
                args.append(self.alloc, slice_val) catch unreachable;
                return;
            }
            if (arr_info == null or arr_info.? != .tuple) {
                // Not spreadable at all (scalar / struct / …): the arg loop
                // left a `Ref.none` placeholder that must never reach the
                // backend — diagnose, drop it, and pack zero variadic args
                // (diagnostics abort before codegen; the shape just has to
                // stay type-correct).
                if (self.diagnostics) |d| {
                    d.addFmt(.err, arg_node.span, "cannot spread a value of type '{s}' — '..' expects a comptime pack, a tuple, an array, or a slice", .{self.formatTypeName(arr_ty)});
                }
                const null_ptr = self.builder.constNull(self.module.types.ptrTo(elem_ty));
                const zero_len = self.builder.constInt(0, .i64);
                const slice_slot = self.builder.alloca(slice_ty);
                const ptr_gep = self.builder.structGepTyped(slice_slot, 0, self.module.types.ptrTo(elem_ty), slice_ty);
                self.builder.store(ptr_gep, null_ptr);
                const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, slice_ty);
                self.builder.store(len_gep, zero_len);
                args.shrinkRetainingCapacity(fixed_count);
                args.append(self.alloc, self.builder.load(slice_slot, slice_ty)) catch unreachable;
                return;
            }
            // A tuple operand: elements were spliced into `args` by the call's
            // arg loop — fall through to the generic per-element packing.
        }
    }

    if (variadic_count == 0) {
        // Empty slice
        const null_ptr = self.builder.constNull(self.module.types.ptrTo(elem_ty));
        const zero_len = self.builder.constInt(0, .i64);
        const slice_slot = self.builder.alloca(slice_ty);
        const ptr_gep = self.builder.structGepTyped(slice_slot, 0, self.module.types.ptrTo(elem_ty), slice_ty);
        self.builder.store(ptr_gep, null_ptr);
        const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, slice_ty);
        self.builder.store(len_gep, zero_len);
        const slice_val = self.builder.load(slice_slot, slice_ty);
        // Replace args: keep fixed args, append slice
        args.shrinkRetainingCapacity(fixed_count);
        args.append(self.alloc, slice_val) catch unreachable;
        return;
    }

    // Determine if we need to box as Any (for ..Any params) or use raw type
    const is_any = (elem_ty == .any);
    // `..xs: []P` (slice of a protocol): each concrete arg must be erased to
    // a protocol value {ctx, vtable}, not stored raw (which would be a
    // size/type mismatch — a heap of garbage vtables → crash on dispatch).
    const elem_is_protocol = blk: {
        if (elem_ty.isBuiltin()) break :blk false;
        const ei = self.module.types.get(elem_ty);
        break :blk ei == .@"struct" and ei.@"struct".is_protocol;
    };

    // Allocate stack array [N x ElemType]
    const array_elem = if (is_any) TypeId.any else elem_ty;
    const array_ty = self.module.types.arrayOf(array_elem, @intCast(variadic_count));
    const array_slot = self.builder.alloca(array_ty);

    // Store each variadic arg into array
    for (0..variadic_count) |i| {
        var val = args.items[fixed_count + i];
        // A value-spread arg (`..t` on a tuple) was expanded ELEMENT-WISE at
        // the call's arg loop, so `c.args` (holding the single spread node)
        // can be SHORTER than the lowered variadic args. Index it defensively;
        // an expanded element has no 1:1 AST node — its type comes from the
        // lowered ref (the existing `.unresolved` fallback below).
        const src_node: ?*const Node = if (fixed_count + i < c.args.len and c.args[fixed_count + i].data != .spread_expr)
            c.args[fixed_count + i]
        else
            null;
        if (is_any) {
            var source_ty: TypeId = if (src_node) |n| self.inferExprType(n) else .unresolved;
            // If AST-based inference falls back to .i64 but the lowered ref has a richer type, use that
            if (source_ty == .unresolved) {
                const ref_ty = self.builder.getRefType(val);
                if (ref_ty != .unresolved and ref_ty != .void) source_ty = ref_ty;
            }
            // Auto-unwrap optionals: box inner value if present, else box string "null"
            if (!source_ty.isBuiltin()) {
                const opt_info = self.module.types.get(source_ty);
                if (opt_info == .optional) {
                    const child_ty = opt_info.optional.child;
                    // Branch: has_value? → box inner : box "null"
                    const has_val = self.builder.emit(.{ .optional_has_value = .{ .operand = val } }, .bool);
                    const some_bb = self.freshBlock("opt.some");
                    const none_bb = self.freshBlock("opt.none");
                    const merge_bb = self.freshBlockWithParams("opt.merge", &.{TypeId.any});
                    self.builder.condBr(has_val, some_bb, &.{}, none_bb, &.{});
                    // Some: unwrap and box inner value
                    self.builder.switchToBlock(some_bb);
                    const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = val } }, child_ty);
                    const boxed_inner = self.boxAnyOf(unwrapped, child_ty, null);
                    self.builder.br(merge_bb, &.{boxed_inner});
                    // None: box the string "null"
                    self.builder.switchToBlock(none_bb);
                    const null_str_id = self.module.types.internString("null");
                    const null_str = self.builder.constString(null_str_id);
                    const boxed_null = self.boxAnyOf(null_str, .string, null);
                    self.builder.br(merge_bb, &.{boxed_null});
                    // Merge
                    self.builder.switchToBlock(merge_bb);
                    val = self.builder.blockParam(merge_bb, 0, TypeId.any);
                    source_ty = .any; // already boxed
                }
            }
            if (source_ty != .any) {
                val = self.boxAnyOf(val, source_ty, src_node);
            }
        } else if (elem_is_protocol) {
            // Erase each concrete arg to the protocol value via the same
            // impl-driven `xx` machinery, so the runtime `[]P` holds real
            // {ctx, vtable} values and `xs[i].method()` dispatches. A
            // spread-expanded element has no per-element AST node — use the
            // spread node itself (diagnostic span / lvalue detection only).
            const arg_node = src_node orelse c.args[c.args.len - 1];
            var source_ty: TypeId = if (src_node) |n| self.inferExprType(n) else .unresolved;
            if (source_ty == .unresolved) source_ty = self.builder.getRefType(val);
            if (source_ty != elem_ty) {
                val = self.buildProtocolErasure(val, arg_node, source_ty, elem_ty);
            }
        }
        const idx_ref = self.builder.constInt(@intCast(i), .i64);
        const elem_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = idx_ref } }, self.module.types.ptrTo(array_elem));
        self.builder.store(elem_ptr, val);
    }

    // Build slice {ptr, len}
    const slice_slot = self.builder.alloca(slice_ty);
    const zero = self.builder.constInt(0, .i64);
    const data_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = zero } }, self.module.types.ptrTo(array_elem));
    const len_ref = self.builder.constInt(@intCast(variadic_count), .i64);
    const ptr_gep = self.builder.structGepTyped(slice_slot, 0, self.module.types.ptrTo(array_elem), slice_ty);
    self.builder.store(ptr_gep, data_ptr);
    const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, slice_ty);
    self.builder.store(len_gep, len_ref);
    const slice_val = self.builder.load(slice_slot, slice_ty);

    // Replace args: keep fixed args, append slice
    args.shrinkRetainingCapacity(fixed_count);
    args.append(self.alloc, slice_val) catch unreachable;
}

// ── Pack-fn calls & monomorphization ──────────────────────────

/// Build an `[]Any` slice value from the mono's pack params and
/// bind it to the pack name in scope. Each pack-param slot is
/// loaded, boxed via `boxAny`, and stored into a stack [N x Any]
/// array; the slice {data_ptr, len} is then bound. Used by
/// `monomorphizePackFn` so bodies that reference `args` bare or
/// index it with a runtime int resolve through the slice (with
/// element type `Any`). Literal-indexed accesses keep the
/// concrete per-position types via `packArgNodeAt`.
/// Build a `[]Type` slice VALUE for a bare `$<pack>` reference.
/// Differs from `materialisePackSlice` (which boxes each pack
/// element as Any so the body's `args[i]` reads an Any) — this
/// helper stores raw `.type_tag` Values via `const_type`, so the
/// slice is a list-of-Types that builder fns walk at interp time.
/// Slice IR type is `[]Any` (since `Type → .any`); the interp
/// stores whichever Value the elements actually carry.
pub fn buildPackSliceValue(self: *Lowering, arg_types: []const TypeId) Ref {
    // A bare `$<pack>` is a `[]Type` value. Since the dedicated `Type` builtin
    // (`.type_value`, 8 bytes) replaced the old `Type → .any` (16-byte) mapping,
    // the slice element is `type_value` — building it as `[]Any` here stored 8-byte
    // `const_type` words into 16-byte slots, so a `[]Type` reader (8-byte stride)
    // read `[t0, pad, t1, …]` instead of `[t0, t1, …]` (issue 0143).
    const ty_slice_ty = self.module.types.sliceOf(.type_value);
    const ty_ptr_ty = self.module.types.ptrTo(.type_value);

    if (arg_types.len == 0) {
        const null_ptr = self.builder.constNull(ty_ptr_ty);
        const zero_len = self.builder.constInt(0, .i64);
        const slice_slot = self.builder.alloca(ty_slice_ty);
        const ptr_gep = self.builder.structGepTyped(slice_slot, 0, ty_ptr_ty, ty_slice_ty);
        self.builder.store(ptr_gep, null_ptr);
        const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, ty_slice_ty);
        self.builder.store(len_gep, zero_len);
        return self.builder.load(slice_slot, ty_slice_ty);
    }

    const array_ty = self.module.types.arrayOf(.type_value, @intCast(arg_types.len));
    const array_slot = self.builder.alloca(array_ty);

    for (arg_types, 0..) |ty, i| {
        const type_val = self.builder.constType(ty); // an 8-byte `.type_value` word
        const idx_ref = self.builder.constInt(@intCast(i), .i64);
        const elem_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = idx_ref } }, ty_ptr_ty);
        self.builder.store(elem_ptr, type_val);
    }

    const slice_slot = self.builder.alloca(ty_slice_ty);
    const zero = self.builder.constInt(0, .i64);
    const data_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = zero } }, ty_ptr_ty);
    const len_ref = self.builder.constInt(@intCast(arg_types.len), .i64);
    const ptr_gep = self.builder.structGepTyped(slice_slot, 0, ty_ptr_ty, ty_slice_ty);
    self.builder.store(ptr_gep, data_ptr);
    const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, ty_slice_ty);
    self.builder.store(len_gep, len_ref);
    return self.builder.load(slice_slot, ty_slice_ty);
}

pub fn materialisePackSlice(
    self: *Lowering,
    scope: *Scope,
    pack_name: []const u8,
    slot_refs: []const Ref,
    arg_types: []const TypeId,
) void {
    const any_slice_ty = self.module.types.sliceOf(.any);
    const any_ptr_ty = self.module.types.ptrTo(.any);

    if (arg_types.len == 0) {
        const null_ptr = self.builder.constNull(any_ptr_ty);
        const zero_len = self.builder.constInt(0, .i64);
        const slice_slot = self.builder.alloca(any_slice_ty);
        const ptr_gep = self.builder.structGepTyped(slice_slot, 0, any_ptr_ty, any_slice_ty);
        self.builder.store(ptr_gep, null_ptr);
        const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, any_slice_ty);
        self.builder.store(len_gep, zero_len);
        scope.put(pack_name, .{ .ref = slice_slot, .ty = any_slice_ty, .is_alloca = true });
        return;
    }

    const array_ty = self.module.types.arrayOf(.any, @intCast(arg_types.len));
    const array_slot = self.builder.alloca(array_ty);

    for (slot_refs, arg_types, 0..) |slot, ty, i| {
        const val = self.builder.load(slot, ty);
        const boxed = if (ty == .any) val else self.boxAnyOf(val, ty, null);
        const idx_ref = self.builder.constInt(@intCast(i), .i64);
        const elem_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = idx_ref } }, any_ptr_ty);
        self.builder.store(elem_ptr, boxed);
    }

    const slice_slot = self.builder.alloca(any_slice_ty);
    const zero = self.builder.constInt(0, .i64);
    const data_ptr = self.builder.emit(.{ .index_gep = .{ .lhs = array_slot, .rhs = zero } }, any_ptr_ty);
    const len_ref = self.builder.constInt(@intCast(arg_types.len), .i64);
    const ptr_gep = self.builder.structGepTyped(slice_slot, 0, any_ptr_ty, any_slice_ty);
    self.builder.store(ptr_gep, data_ptr);
    const len_gep = self.builder.structGepTyped(slice_slot, 1, .i64, any_slice_ty);
    self.builder.store(len_gep, len_ref);
    scope.put(pack_name, .{ .ref = slice_slot, .ty = any_slice_ty, .is_alloca = true });
}

/// Infer the return type of a pack-fn body for the generic-`$R`
/// case. Walks the body looking for the first concrete return
/// type: a `return X;` statement's value type, or — failing that —
/// the tail expression of an arrow-form body. Caller must have
/// `pack_arg_nodes` installed so `args[<lit>]` substitutes during
/// inference. Falls back to `.i64` if nothing concrete is found
/// (matches the broader "default to .i64" convention elsewhere).
pub fn inferPackBodyReturnType(self: *Lowering, body: *const Node) TypeId {
    // First try explicit `return X;` — walks past structured
    // control flow but stops at nested fn / lambda bodies.
    if (self.findReturnValueType(body)) |ty| return ty;
    // Arrow-form / tail-expression body: the body IS the value.
    // For block bodies whose last stmt is an expression, walk down.
    if (body.data == .block) {
        const stmts = body.data.block.stmts;
        if (stmts.len == 0) return .void;
        return self.inferExprType(stmts[stmts.len - 1]);
    }
    return self.inferExprType(body);
}

/// AST-level spread expansion for a pack-fn call's arg list: each `..x`
/// spread arg is replaced by per-element ACCESS NODES, so the pack machinery
/// (per-arg typing, `pack_arg_nodes` substitution, the mangle) sees N
/// ordinary args:
///   - a comptime pack `..xs` / `..xs.m`  → `xs[0]` / `xs[0].m()`, …   (pack forwarding)
///   - a tuple-typed value `..t`          → `t.0`, …, `t.<N-1>`
///   - a fixed-array value `..t`          → `t[0]`, …, `t[N-1]`
/// Only NAME-shaped value operands (identifier / field access) expand — an
/// element node re-lowers the operand per element, which must not repeat side
/// effects. Returns the expanded arg list, or null when nothing was expanded
/// (no spread, or an unsupported operand — the latter keeps its spread node
/// and surfaces the existing spread_expr diagnostic downstream).
pub fn expandSpreadArgNodes(self: *Lowering, call_args: []const *Node) ?[]const *Node {
    var any_expanded = false;
    var out = std.ArrayList(*Node).empty;
    for (call_args) |arg| {
        if (arg.data != .spread_expr) {
            out.append(self.alloc, arg) catch return null;
            continue;
        }
        if (spreadElemNodes(self, arg.data.spread_expr.operand, arg.span)) |elems| {
            defer self.alloc.free(elems);
            for (elems) |e| out.append(self.alloc, e) catch return null;
            any_expanded = true;
            continue;
        }
        out.append(self.alloc, arg) catch return null;
    }
    if (!any_expanded) {
        out.deinit(self.alloc);
        return null;
    }
    return out.toOwnedSlice(self.alloc) catch null;
}

/// Per-element access nodes for one spread operand (see
/// `expandSpreadArgNodes`). Null when the operand is not expandable.
fn spreadElemNodes(self: *Lowering, operand: *const Node, span: ast.Span) ?[]*Node {
    // Comptime pack (`..xs` / `..xs.m`): synthesize `xs[i]` / `xs[i].m()`
    // exactly as `lowerPackElems` does for ref-level expansion.
    var pack_name: ?[]const u8 = null;
    var pack_method: ?[]const u8 = null;
    switch (operand.data) {
        .identifier => |id| {
            if (self.isPackName(id.name)) pack_name = id.name;
        },
        .field_access => |fa| {
            if (fa.object.data == .identifier and self.isPackName(fa.object.data.identifier.name)) {
                pack_name = fa.object.data.identifier.name;
                pack_method = fa.field;
            }
        },
        else => {},
    }
    if (pack_name) |pn| {
        const n: u32 = if (self.pack_param_count) |ppc| (ppc.get(pn) orelse 0) else 0;
        var nodes = std.ArrayList(*Node).empty;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const id_node = self.alloc.create(Node) catch return null;
            id_node.* = .{ .span = span, .data = .{ .identifier = .{ .name = pn } } };
            const idx_node = self.alloc.create(Node) catch return null;
            idx_node.* = .{ .span = span, .data = .{ .int_literal = .{ .value = @intCast(i) } } };
            const index_node = self.alloc.create(Node) catch return null;
            index_node.* = .{ .span = span, .data = .{ .index_expr = .{ .object = id_node, .index = idx_node } } };
            var elem_node: *Node = index_node;
            if (pack_method) |m| {
                const fa_node = self.alloc.create(Node) catch return null;
                fa_node.* = .{ .span = span, .data = .{ .field_access = .{ .object = index_node, .field = m } } };
                const call_n = self.alloc.create(Node) catch return null;
                call_n.* = .{ .span = span, .data = .{ .call = .{ .callee = fa_node, .args = &.{} } } };
                elem_node = call_n;
            }
            nodes.append(self.alloc, elem_node) catch return null;
        }
        return nodes.toOwnedSlice(self.alloc) catch null;
    }
    // Concrete value spread (specs.md §"Tuple parallels"): only name-shaped
    // operands — re-lowering must not repeat side effects.
    switch (operand.data) {
        .identifier, .field_access => {},
        else => return null,
    }
    const ty = self.inferExprType(operand);
    if (ty.isBuiltin()) return null;
    switch (self.module.types.get(ty)) {
        .tuple => |t| {
            var nodes = std.ArrayList(*Node).empty;
            for (0..t.fields.len) |i| {
                const fname = std.fmt.allocPrint(self.alloc, "{d}", .{i}) catch return null;
                const fa_node = self.alloc.create(Node) catch return null;
                fa_node.* = .{ .span = span, .data = .{ .field_access = .{ .object = @constCast(operand), .field = fname } } };
                nodes.append(self.alloc, fa_node) catch return null;
            }
            return nodes.toOwnedSlice(self.alloc) catch null;
        },
        // A struct value spreads field-wise like a tuple (the materialized
        // pack carrier is an anonymous positional struct with fields
        // "0"/"1"/…) — synthesize `.field` access nodes in declaration order.
        .@"struct" => |st| {
            var nodes = std.ArrayList(*Node).empty;
            for (st.fields) |f| {
                const fa_node = self.alloc.create(Node) catch return null;
                fa_node.* = .{ .span = span, .data = .{ .field_access = .{ .object = @constCast(operand), .field = self.module.types.getString(f.name) } } };
                nodes.append(self.alloc, fa_node) catch return null;
            }
            return nodes.toOwnedSlice(self.alloc) catch null;
        },
        .array => |a| {
            var nodes = std.ArrayList(*Node).empty;
            var i: u32 = 0;
            while (i < a.length) : (i += 1) {
                const idx_node = self.alloc.create(Node) catch return null;
                idx_node.* = .{ .span = span, .data = .{ .int_literal = .{ .value = @intCast(i) } } };
                const index_node = self.alloc.create(Node) catch return null;
                index_node.* = .{ .span = span, .data = .{ .index_expr = .{ .object = @constCast(operand), .index = idx_node } } };
                nodes.append(self.alloc, index_node) catch return null;
            }
            return nodes.toOwnedSlice(self.alloc) catch null;
        },
        else => return null,
    }
}

/// Node-aware lowering for a pack function's fixed runtime prefix. Pack calls
/// lower their own AST (the pack element types must be known before contextual
/// prefix types such as `Closure(..xs.T)` can resolve), so they cannot use the
/// ordinary call loop. Keep the same important parameter semantics here:
/// contextual typing, implicit address-of, protocol erasure/borrowing, and
/// value-position lowering. Each successful branch lowers `arg` exactly once.
fn lowerPackPrefixArg(self: *Lowering, arg: *const Node, param_ty: TypeId, is_receiver: bool) Ref {
    if (self.foldComptimeFloatInit(arg, param_ty)) |folded| return folded;

    // Concrete lvalue T -> *T: borrow the caller's storage. Leaving this to
    // node-less `coerceCallArgs` would alloca+store the already-loaded value,
    // so mutations in the callee would affect only that temporary copy.
    if (!param_ty.isBuiltin()) {
        const param_info = self.module.types.get(param_ty);
        if (param_info == .pointer) {
            const pointee = param_info.pointer.pointee;
            if (arg.data == .identifier) {
                const name = arg.data.identifier.name;
                const local = if (self.scope) |scope| scope.lookup(name) else null;
                if (local) |binding| {
                    if (binding.is_alloca and binding.ty == pointee)
                        return self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, param_ty);
                } else if (self.resolveGlobalRef(name, null)) |global| {
                    if (global.ty == pointee and !self.rootIsConstant(name)) {
                        const place = self.lowerExprAsPtr(arg);
                        const place_ty = self.builder.getRefType(place);
                        return if (place_ty == param_ty)
                            place
                        else
                            self.builder.emit(.{ .addr_of = .{ .operand = place } }, param_ty);
                    }
                }
            }

            if ((arg.data == .field_access or arg.data == .index_expr or arg.data == .deref_expr) and
                self.inferExprType(arg) == pointee)
            {
                const place = self.lowerExprAsPtr(arg);
                const place_ty = self.builder.getRefType(place);
                if (place_ty == param_ty) return place;
                if (place_ty == pointee)
                    return self.builder.emit(.{ .addr_of = .{ .operand = place } }, param_ty);
            }
        }
    }

    // Concrete -> protocol value: preserve the AST so #identity parameters
    // borrow lvalues while value/own parameters keep owning semantics.
    if (self.getProtocolInfo(param_ty) != null) {
        const concrete_ty = self.inferExprType(arg);
        if (concrete_ty != .unresolved and concrete_ty != param_ty and concrete_ty != .any and
            !concrete_ty.isBuiltin() and self.getProtocolInfo(concrete_ty) == null)
        {
            const concrete_info = self.module.types.get(concrete_ty);
            if (concrete_info == .@"struct" or concrete_info == .pointer) {
                const value = self.lowerExpr(arg);
                return self.buildProtocolErasure(value, arg, concrete_ty, param_ty);
            }
        }
    }

    // Concrete lvalue -> *Protocol: construct a borrowed view around the real
    // concrete address, then pass the spilled protocol value by pointer.
    if (!param_ty.isBuiltin() and
        (arg.data == .identifier or arg.data == .field_access or arg.data == .index_expr or arg.data == .deref_expr))
    {
        const param_info = self.module.types.get(param_ty);
        if (param_info == .pointer and self.getProtocolInfo(param_info.pointer.pointee) != null) {
            const concrete_ty = self.inferExprType(arg);
            if (concrete_ty != .unresolved and !concrete_ty.isBuiltin() and concrete_ty != param_info.pointer.pointee and
                self.getProtocolInfo(concrete_ty) == null and self.module.types.get(concrete_ty) == .@"struct")
            {
                const place = self.lowerExprAsPtr(arg);
                const place_ty = self.builder.getRefType(place);
                const address = if (place_ty == concrete_ty)
                    self.builder.emit(.{ .addr_of = .{ .operand = place } }, self.module.types.ptrTo(concrete_ty))
                else
                    place;
                if (self.viewOfConcreteAddr(address, concrete_ty, param_ty)) |view| return view;
            }
        }
    }

    const saved_force_block_value = self.force_block_value;
    self.force_block_value = true;
    const value = self.lowerExpr(arg);
    self.force_block_value = saved_force_block_value;

    // Method receivers keep the ordinary method adaptation: calling a
    // value-receiver method through `*T` passes the pointee. Explicit fixed
    // params retain the normal pointer-to-value diagnostic below.
    const value_ty = self.builder.getRefType(value);
    if (is_receiver and !value_ty.isBuiltin()) {
        const value_info = self.module.types.get(value_ty);
        if (value_info == .pointer and value_info.pointer.pointee == param_ty)
            return self.builder.load(value, param_ty);
    }

    if (!is_receiver and !value_ty.isBuiltin()) {
        const value_info = self.module.types.get(value_ty);
        if (value_info == .pointer and value_info.pointer.pointee == param_ty) {
            if (self.diagnostics) |diagnostics| {
                const type_name = self.formatTypeName(param_ty);
                if (arg.data == .identifier) {
                    const name = arg.data.identifier.name;
                    const lead: []const u8 = if (self.refCapturePointee(arg) != null) "by-reference loop capture" else "argument";
                    const fix = std.fmt.allocPrint(self.alloc, "{s}.*", .{name}) catch name;
                    const id = diagnostics.addFmtId(.err, arg.span, "{s} '{s}' has type '*{s}', but '{s}' is expected here", .{ lead, name, type_name, type_name });
                    diagnostics.addHelpFmt(id, arg.span, fix, "dereference it to pass the value: `{s}`", .{fix});
                } else {
                    const id = diagnostics.addFmtId(.err, arg.span, "this argument has type '*{s}', but '{s}' is expected here", .{ type_name, type_name });
                    diagnostics.addHelpFmt(id, arg.span, null, "dereference it with `.*` to pass the value", .{});
                }
            }
        }
    }
    return value;
}

/// Per-call-shape monomorphisation entry for pack-fns
/// (`isPackFn(fd) == true`). Computes a mangled name from the
/// call-site arg types, builds the mono if it's not cached, and
/// emits a direct call. Pack params expand into N positional IR
/// params with concrete types; the body's `args[<lit>]` and
/// `args.len` resolve to those params via the pack bindings.
pub fn lowerPackFnCall(self: *Lowering, fd: *const ast.FnDecl, call_node: *const ast.Call) Ref {
    return self.lowerPackFnCallNamed(fd, fd.name, call_node, null);
}

/// Pack-call lowering with an identity-bearing compiler-internal base name.
/// Ordinary free functions pass `fd.name`; nominally selected struct methods
/// pass their author-specific dispatch key so two same-named methods with the
/// same call shape cannot share a monomorphized body. `receiver_node` marks a
/// receiver AST prepended by instance-method dispatch; it occupies fixed-prefix
/// index zero. Free/static pack calls pass null.
pub fn lowerPackFnCallNamed(
    self: *Lowering,
    fd: *const ast.FnDecl,
    dispatch_name: []const u8,
    call_node: *const ast.Call,
    receiver_node: ?*const Node,
) Ref {
    // Spread args expand at AST level FIRST (element access nodes) so each
    // element is an independent pack arg: pack forwarding `g(..xs)`, tuple
    // spread `print(fmt, ..t)`, array spread. An unsupported operand keeps
    // its spread node and diagnoses downstream. Single recursion: the
    // expanded list contains no expandable spreads.
    if (self.expandSpreadArgNodes(call_node.args)) |expanded| {
        const syn_call = ast.Call{ .callee = call_node.callee, .args = expanded };
        return self.lowerPackFnCallNamed(fd, dispatch_name, &syn_call, receiver_node);
    }
    // A spread that could not be expanded at AST level has already lost the
    // static element shape required by a pack call (notably `..make_tuple()`).
    // Diagnose that one operand and stop before monomorphizing a one-element
    // pack whose body then emits a misleading secondary index-OOB error
    // (issue 0252.2).
    for (call_node.args) |arg| {
        if (arg.data != .spread_expr) continue;
        if (spreadElemNodes(self, arg.data.spread_expr.operand, arg.span) != null) continue;
        _ = self.lowerExpr(arg);
        return self.builder.constInt(0, .void);
    }
    // Split call args along the fd.params boundary:
    // - non-comptime non-pack params → consume one call arg as a
    //   runtime IR param.
    // - comptime non-pack params → consume one call arg, fold its
    //   value into the mangle (NOT a runtime IR param).
    // - pack param (always last) → consume the remaining call args
    //   as the pack expansion.
    var pack_arg_types = std.ArrayList(TypeId).empty;
    defer pack_arg_types.deinit(self.alloc);
    var pack_start: usize = call_node.args.len;
    // Constraint protocol of the pack param (`..xs: P`), if any. The
    // comptime type-pack `..$args` has no constraint to check.
    var pack_protocol: ?[]const u8 = null;
    var pack_is_comptime = false;
    var pack_name: []const u8 = "";
    {
        var fi: usize = 0;
        for (fd.params) |p| {
            if (isPackParam(p)) {
                pack_start = fi;
                pack_is_comptime = p.is_comptime;
                pack_name = p.name;
                if (p.is_pack and p.type_expr.data == .type_expr) {
                    pack_protocol = p.type_expr.data.type_expr.name;
                }
                break;
            }
            if (fi >= call_node.args.len) break;
            fi += 1;
        }
    }

    // Lower the PACK args first, taking each type from the lowered value
    // (`getRefType`) — never a pre-lowering `inferExprType` guess. Knowing
    // the pack element types up front lets the prefix args (e.g.
    // `mapper: Closure(..sources.T) -> $R`) resolve against them, so a
    // lambda arg types its params from the projected closure signature.
    // (A comptime `..$args` pack keeps `inferExprType` — its args may be
    // type-position.)
    // A pack arg is independently typed — it takes its natural type and
    // (for a comptime `..$args` pack) auto-boxes to `Any` at the call
    // boundary. It is NEVER coerced to a leftover outer `target_type`, so
    // clear it: otherwise an `xx <expr>` pack arg (whose result type IS
    // `target_type`) would cast to the stale target — e.g. `format("…", xx i)`
    // inside a `-> string` fn mis-typed the arg as `string`, monomorphizing
    // `__pack_string` and ABI-coercing the 4-byte int as a 16-byte fat
    // pointer → memory corruption.
    const saved_pack_tt = self.target_type;
    self.target_type = null;
    // A pack arg is a VALUE position: a block-form `if C { A } else { B }`
    // / `match` passed directly (e.g. `print("{}", if b { x } else { y })`)
    // must yield its branch value, not lower as a statement-if that returns a
    // bare void 0 (or overruns for a wider branch type → segfault, issue 0268).
    const saved_pack_fbv = self.force_block_value;
    self.force_block_value = true;
    var pack_refs = std.ArrayList(Ref).empty;
    defer pack_refs.deinit(self.alloc);
    for (call_node.args[pack_start..]) |a| {
        const r = self.lowerExpr(a);
        pack_refs.append(self.alloc, r) catch return self.builder.constInt(0, .void);
        if (pack_is_comptime) {
            const it = self.inferExprType(a);
            pack_arg_types.append(self.alloc, if (it == .unresolved) self.builder.getRefType(r) else it) catch return self.builder.constInt(0, .void);
        } else {
            pack_arg_types.append(self.alloc, self.builder.getRefType(r)) catch return self.builder.constInt(0, .void);
        }
    }
    self.target_type = saved_pack_tt;
    self.force_block_value = saved_pack_fbv;

    // Install the pack's element types + constraint so prefix-arg param
    // types like `Closure(..sources.T)` resolve while lowering the prefix.
    var pat_map = std.StringHashMap([]const TypeId).init(self.alloc);
    defer pat_map.deinit();
    pat_map.put(pack_name, pack_arg_types.items) catch {};
    var pcon_map = std.StringHashMap([]const u8).init(self.alloc);
    defer pcon_map.deinit();
    if (pack_protocol) |proto| pcon_map.put(pack_name, proto) catch {};
    const saved_pat = self.pack_arg_types;
    const saved_pcon = self.pack_constraint;
    self.pack_arg_types = pat_map;
    if (pack_protocol != null) self.pack_constraint = pcon_map;

    var args = std.ArrayList(Ref).empty;
    defer args.deinit(self.alloc);
    {
        var ri: usize = 0;
        for (fd.params, 0..) |p, param_idx| {
            if (isPackParam(p)) break;
            if (ri >= call_node.args.len) break;
            if (!p.is_comptime) {
                // Contextually type the arg from the param (so a lambda arg
                // `(x) => …` takes its param types from a `Closure(...)` param).
                // The param type is resolved under the pack fn's OWN source
                // (E4): a fixed-prefix type bare-visible only in the defining
                // module must resolve there, not the caller's. The arg itself
                // is lowered AFTER, in the caller's context.
                const saved_tt = self.target_type;
                const pty = self.resolveDeclParamType(fd, param_idx);
                if (pty != .unresolved) self.target_type = pty;
                // Prefix arg is a value position (issue 0268 — see the pack-arg
                // loop above): force block-form if/match to yield its value.
                const saved_prefix_fbv = self.force_block_value;
                self.force_block_value = true;
                const arg_node = call_node.args[ri];
                const arg_ref = lowerPackPrefixArg(self, arg_node, pty, receiver_node != null and param_idx == 0);
                args.append(self.alloc, arg_ref) catch return self.builder.constInt(0, .void);
                self.force_block_value = saved_prefix_fbv;
                self.target_type = saved_tt;
            }
            ri += 1;
        }
    }
    self.pack_arg_types = saved_pat;
    self.pack_constraint = saved_pcon;

    // Infer type-param bindings (e.g. `$R` in `mapper: Closure(..) -> $R`)
    // from the lowered prefix args. `args.items` holds the non-comptime
    // prefix refs in declaration order; match each prefix param's declared
    // type against its arg's concrete type to bind the function's
    // type-params. These flow into the mangle and the mono's
    // `self.type_bindings` so `-> VL($R)` / `Combined($R, ..)` resolve.
    var tparam_bindings = std.StringHashMap(TypeId).init(self.alloc);
    defer tparam_bindings.deinit();
    if (fd.type_params.len > 0) {
        var pref_ref_idx: usize = 0;
        for (fd.params) |p| {
            if (isPackParam(p)) break;
            if (p.is_comptime) continue;
            if (pref_ref_idx >= args.items.len) break;
            const arg_ty = self.builder.getRefType(args.items[pref_ref_idx]);
            for (fd.type_params) |tp| {
                if (tparam_bindings.contains(tp.name)) continue;
                if (self.extractTypeParam(p.type_expr, arg_ty, tp.name)) |ety| {
                    if (ety != .unresolved) tparam_bindings.put(tp.name, ety) catch {};
                }
            }
            pref_ref_idx += 1;
        }
    }

    // Append the (already-lowered) pack args after the prefix args.
    for (pack_refs.items) |r| args.append(self.alloc, r) catch return self.builder.constInt(0, .void);

    // Per-position conformance: each pack arg must impl the constraint
    // protocol. Only enforced for a known protocol constraint — an unknown
    // name (e.g. a plain type used as a pack constraint) is left alone.
    if (pack_protocol) |proto| {
        if (self.program_index.protocol_ast_map.contains(proto)) {
            for (call_node.args[pack_start..], pack_arg_types.items) |arg_node, arg_ty| {
                if (!self.protocolResolver().packArgConformsTo(proto, arg_ty)) {
                    if (self.diagnostics) |diags| {
                        diags.addFmt(.err, arg_node.span, "pack argument of type '{s}' does not conform to protocol '{s}'", .{ self.formatTypeName(arg_ty), proto });
                    }
                }
            }
        }
    }

    // Mangle: `<fn_name>__pack__<arg_types>` with comptime values
    // (if any) folded into a `__ct_<value>` segment per non-pack
    // comptime param. Distinct call shapes — including different
    // comptime VALUES — get distinct symbols.
    var name_buf = std.ArrayList(u8).empty;
    defer name_buf.deinit(self.alloc);
    name_buf.appendSlice(self.alloc, dispatch_name) catch @panic("out of memory while mangling pack function");
    // Comptime values first (deterministic by fd.params order).
    var ct_fi: usize = 0;
    for (fd.params) |p| {
        if (isPackParam(p)) break;
        if (ct_fi >= call_node.args.len) break;
        if (p.is_comptime) {
            name_buf.appendSlice(self.alloc, "__ct_") catch @panic("out of memory while mangling pack function");
            self.genericResolver().appendComptimeValueMangle(&name_buf, call_node.args[ct_fi]);
        }
        ct_fi += 1;
    }
    // Inferred type-param bindings (deterministic by fd.type_params order).
    for (fd.type_params) |tp| {
        if (tparam_bindings.get(tp.name)) |ty| {
            name_buf.appendSlice(self.alloc, "__tp_") catch @panic("out of memory while mangling pack function");
            name_buf.appendSlice(self.alloc, self.mangleTypeName(ty)) catch @panic("out of memory while mangling pack function");
        }
    }
    name_buf.appendSlice(self.alloc, "__pack") catch @panic("out of memory while mangling pack function");
    for (pack_arg_types.items) |t| {
        name_buf.append(self.alloc, '_') catch @panic("out of memory while mangling pack function");
        name_buf.appendSlice(self.alloc, self.mangleTypeName(t)) catch @panic("out of memory while mangling pack function");
    }
    const mangled = name_buf.items;

    if (!self.lowered_functions.contains(mangled)) {
        self.monomorphizePackFn(fd, mangled, pack_arg_types.items, call_node, &tparam_bindings);
    }

    const fid = self.resolveFuncByName(mangled) orelse return self.builder.constInt(0, .void);
    const func = &self.module.functions.items[@intFromEnum(fid)];
    const ret_ty = func.ret;
    const params = func.params;
    const final_args = self.prependCtxIfNeeded(func, args.items);
    self.coerceCallArgs(final_args, params);
    return self.builder.call(fid, final_args, ret_ty);
}

/// Build a single mono fn for the given pack-fn + concrete arg types.
/// The mono carries N positional pack-params (synthesised names
/// `__pack_<name>_<i>`) plus any fixed-prefix non-pack params from
/// the original declaration. The body lowers normally — real
/// `return X;` emits real `ret X`; `args[<lit>]` substitutes via
/// `pack_arg_nodes`; `args.len` resolves via `pack_param_count`.
pub fn monomorphizePackFn(
    self: *Lowering,
    fd: *const ast.FnDecl,
    mangled_name: []const u8,
    arg_types: []const TypeId,
    call_node: *const ast.Call,
    type_bindings: *const std.StringHashMap(TypeId),
) void {
    const owned_name = self.alloc.dupe(u8, mangled_name) catch return;
    self.lowered_functions.put(owned_name, {}) catch {};

    // Flow narrowing (issue 0179) is per-function: this monomorphized pack body
    // has its own `Ref` space (overlapping the caller's), so isolate it from the
    // caller's `narrowed`/`narrowed_refs` to avoid a false-positive unwrap gate.
    var narrow_guard = Lowering.NarrowGuard.enter(self);
    defer narrow_guard.restore();

    // Find the pack param's name and position in fd.params, plus its
    // constraint protocol (`..xs: Box` ⇒ "Box"; comptime `..$args` has none).
    var pack_name: []const u8 = "";
    var pack_param_idx: usize = std.math.maxInt(usize);
    var pack_proto: ?[]const u8 = null;
    for (fd.params, 0..) |p, i| {
        if (isPackParam(p)) {
            pack_name = p.name;
            pack_param_idx = i;
            if (p.is_pack and p.type_expr.data == .type_expr) {
                pack_proto = p.type_expr.data.type_expr.name;
            }
            break;
        }
    }
    if (pack_param_idx == std.math.maxInt(usize)) return;

    // Save state — mirrors monomorphizeFunction but also captures
    // pack/inline-return state since the mono body must NOT route
    // returns through any caller's inline slot.
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    const saved_scope = self.scope;
    const saved_defer_base = self.func_defer_base;
    const saved_block_terminated = self.block_terminated;
    const saved_target = self.target_type;
    const saved_pan = self.pack_arg_nodes;
    const saved_ppc = self.pack_param_count;
    const saved_pat = self.pack_arg_types;
    const saved_pcon = self.pack_constraint;
    const saved_iri = self.inline_return_target;
    const saved_ctx_ref = self.current_ctx_ref;
    const saved_type_bindings = self.type_bindings;
    self.func_defer_base = self.defer_stack.items.len;
    self.block_terminated = false;
    self.inline_return_target = null;
    // Generic type-params inferred at the call site (e.g. `$R` from the
    // mapper's closure return). Installed for the whole mono so
    // return-type resolution and body lowering substitute them.
    self.type_bindings = type_bindings.*;
    defer {
        self.type_bindings = saved_type_bindings;
        self.scope = saved_scope;
        self.func_defer_base = saved_defer_base;
        self.block_terminated = saved_block_terminated;
        self.target_type = saved_target;
        self.pack_arg_nodes = saved_pan;
        self.pack_param_count = saved_ppc;
        self.pack_arg_types = saved_pat;
        self.pack_constraint = saved_pcon;
        self.inline_return_target = saved_iri;
        self.current_ctx_ref = saved_ctx_ref;
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
    }

    const wants_ctx = self.funcWantsImplicitCtx(fd);

    // Synthesise pack-param names + AST ident nodes used to bind
    // `args[<lit>]` substitutions during body lowering. Built
    // BEFORE return-type resolution so the generic-`$R` path can
    // pre-install the binding for type inference.
    var pack_synth_names = std.ArrayList([]const u8).empty;
    defer pack_synth_names.deinit(self.alloc);
    var pack_arg_idents = std.ArrayList(*const Node).empty;
    defer pack_arg_idents.deinit(self.alloc);
    for (arg_types, 0..) |_, i| {
        const synth_name = std.fmt.allocPrint(self.alloc, "__pack_{s}_{d}", .{ pack_name, i }) catch return;
        pack_synth_names.append(self.alloc, synth_name) catch return;
        const ident_node = self.alloc.create(Node) catch return;
        ident_node.* = .{
            .span = fd.body.span,
            .data = .{ .identifier = .{ .name = synth_name } },
        };
        pack_arg_idents.append(self.alloc, ident_node) catch return;
    }

    // Resolve return type. When the declared type is a generic
    // name (e.g. `(..$args) -> $R`), `resolveReturnType` would
    // return an opaque struct TypeId and the mono's signature
    // would be wrong. Pre-install the pack bindings + infer the
    // ret type from the body's tail expression / first explicit
    // `return X;` instead.
    var pre_pan = std.StringHashMap([]const *const Node).init(self.alloc);
    defer pre_pan.deinit();
    pre_pan.put(pack_name, pack_arg_idents.items) catch return;
    var pre_ppc = std.StringHashMap(u32).init(self.alloc);
    defer pre_ppc.deinit();
    pre_ppc.put(pack_name, @intCast(arg_types.len)) catch return;
    var pre_pat = std.StringHashMap([]const TypeId).init(self.alloc);
    defer pre_pat.deinit();
    pre_pat.put(pack_name, arg_types) catch return;
    var pre_pcon = std.StringHashMap([]const u8).init(self.alloc);
    defer pre_pcon.deinit();
    if (pack_proto) |proto| pre_pcon.put(pack_name, proto) catch return;
    self.pack_arg_nodes = pre_pan;
    self.pack_param_count = pre_ppc;
    self.pack_arg_types = pre_pat;
    self.pack_constraint = if (pack_proto != null) pre_pcon else null;

    // Resolve the declared return + fixed-prefix param types in the pack fn's
    // OWN module (E4), so a 2-flat-hop library type named in the signature is
    // bare-visible — mirrors the body pin further down and the
    // `monomorphizeFunction` pin. The comptime call-site args below are
    // lowered AFTER this restore, in the caller's context.
    const saved_sig_src = self.current_source_file;
    if (fd.body.source_file) |src| self.setCurrentSourceFile(src);

    const declared_is_generic_ret = blk: {
        const rt = fd.return_type orelse break :blk false;
        if (rt.data != .type_expr) break :blk false;
        break :blk rt.data.type_expr.is_generic;
    };
    const ret_ty: TypeId = if (declared_is_generic_ret)
        self.inferPackBodyReturnType(fd.body)
    else
        self.resolveReturnType(fd);
    self.target_type = ret_ty;

    // Param list: ctx (if needed) + fixed prefix + N pack params.
    // Comptime non-pack params are NOT in the runtime signature —
    // their values are folded into the mangle and substituted via
    // `comptime_param_nodes` / bound as runtime locals in scope.
    // NOT deinit'd — `params.items` is stored by reference in
    // `Function.init` and read back later via `func.params`.
    var params = std.ArrayList(Function.Param).empty;
    if (wants_ctx) {
        params.append(self.alloc, .{
            .name = self.module.types.internString("__sx_ctx"),
            .ty = self.module.types.ptrTo(.void),
        }) catch return;
    }
    for (fd.params, 0..) |p, i| {
        if (i == pack_param_idx) continue;
        if (p.is_comptime) continue; // folded into mangle, not in IR
        const pty = self.resolveDeclParamType(fd, i);
        params.append(self.alloc, .{
            .name = self.module.types.internString(p.name),
            .ty = pty,
        }) catch return;
    }
    for (arg_types, 0..) |ty, i| {
        params.append(self.alloc, .{
            .name = self.module.types.internString(pack_synth_names.items[i]),
            .ty = ty,
        }) catch return;
    }
    self.setCurrentSourceFile(saved_sig_src);

    const name_id = self.module.types.internString(owned_name);
    _ = self.builder.beginFunction(name_id, params.items, ret_ty);
    self.builder.currentFunc().has_implicit_ctx = wants_ctx;
    self.builder.currentFunc().is_naked = (fd.abi == .naked);
    self.builder.currentFunc().is_get = fd.is_get;
    self.builder.currentFunc().is_set = fd.is_set;

    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);
    if (wants_ctx) self.current_ctx_ref = Ref.fromIndex(0);

    var scope = Scope.init(self.alloc, null);
    defer scope.deinit();
    self.scope = &scope;

    // Bind non-pack params. Walk fd.params + call_node.args
    // together; comptime non-pack params bind both as runtime
    // locals (so bare-name body access works) AND as
    // comptime_param_nodes entries (so `#insert` substitution
    // works). Non-comptime non-pack params consume IR param
    // slots in order.
    var cpn = std.StringHashMap(*const Node).init(self.alloc);
    defer cpn.deinit();
    var param_idx: u32 = if (wants_ctx) 1 else 0;
    var ct_arg_idx: usize = 0;
    for (fd.params, 0..) |p, i| {
        if (i == pack_param_idx) break;
        if (p.is_comptime) {
            if (ct_arg_idx < call_node.args.len) {
                const call_arg = call_node.args[ct_arg_idx];
                self.stampCallerSource(call_arg);
                cpn.put(p.name, call_arg) catch return;
                // Bind as a runtime local for bare-name access.
                // Lower the call arg as a value, then alloca + store.
                const val = self.lowerExpr(call_arg);
                const val_ty = self.builder.getRefType(val);
                const slot = self.builder.alloca(val_ty);
                self.builder.store(slot, val);
                scope.put(p.name, .{ .ref = slot, .ty = val_ty, .is_alloca = true });
            }
            ct_arg_idx += 1;
            continue;
        }
        // Pin to the pack fn's OWN module (E4): a fixed-prefix param whose
        // type is bare-visible only in the defining module must resolve
        // there, not in the caller's restored context. Mirrors the
        // signature build above and `resolveParamTypeInSource` at the
        // cross-module call-arg typing sites.
        const pty = self.resolveDeclParamType(fd, i);
        const slot = self.builder.alloca(pty);
        self.builder.store(slot, Ref.fromIndex(param_idx));
        scope.put(p.name, .{ .ref = slot, .ty = pty, .is_alloca = true });
        param_idx += 1;
        ct_arg_idx += 1;
    }
    // Install comptime_param_nodes for the body lowering.
    const saved_cpn = self.comptime_param_nodes;
    self.comptime_param_nodes = cpn;
    defer self.comptime_param_nodes = saved_cpn;
    var pack_param_slots = std.ArrayList(Ref).empty;
    defer pack_param_slots.deinit(self.alloc);
    for (arg_types, 0..) |ty, i| {
        const synth_name = pack_synth_names.items[i];
        const slot = self.builder.alloca(ty);
        self.builder.store(slot, Ref.fromIndex(param_idx));
        scope.put(synth_name, .{ .ref = slot, .ty = ty, .is_alloca = true });
        pack_param_slots.append(self.alloc, slot) catch return;
        param_idx += 1;
    }

    // Pack bindings remain installed from the pre-resolution
    // (generic-`$R`) inference step above. No need to reinstall.

    // Materialise an `[]Any` slice value for the pack name so
    // bare `args` (forwarding) and `args[<runtime_int>]` (loops)
    // resolve at runtime. Per-position type info is lost via
    // Any boxing — that's the inherent cost of treating a
    // heterogeneous pack as a uniform value. Literal-indexed
    // access still goes through `packArgNodeAt` and keeps the
    // concrete per-position types.
    self.materialisePackSlice(&scope, pack_name, pack_param_slots.items, arg_types);

    // Pin to the metaprogram's OWN module for the BODY lowering only, so its
    // bare names (and anything it `#insert`s — e.g. `build_format` / `out` /
    // `emit` inside `std.print`) resolve in the defining module's visibility
    // context, not the call site's. The comptime-param call-site
    // args above were deliberately lowered FIRST, in the caller's context.
    // Mirrors `lowerFunctionBodyInto`, which switches to `func.source_file`;
    // the defining path is stamped on the body node by `resolveImports`. A
    // synthesized/sourceless body keeps the caller's context.
    const saved_source = self.current_source_file;
    defer self.setCurrentSourceFile(saved_source);
    if (fd.body.source_file) |src| self.setCurrentSourceFile(src);

    if (self.builder.currentFunc().is_naked) {
        // `abi(.naked)`: asm-only body that rets itself — no sx value return.
        // Lower statements + cap with `unreachable` (mirrors the decl path).
        // emit_llvm bails on `is_naked` until B1.0b implements `naked` emission.
        self.lowerBlock(fd.body);
        if (!self.currentBlockHasTerminator()) self.builder.emitUnreachable();
    } else if (ret_ty != .void) {
        // Delegate the trailing-value return to the shared `lowerValueBody`
        // (mirrors the decl + generic paths) so this pack-fn instance can't
        // drift — it routes the value-failable success through
        // `lowerFailableSuccessReturn` (appending the success error slot)
        // instead of a bare coerce+ret that leaves the error-tag slot
        // uninitialized (issue 0190).
        self.lowerValueBody(fd.body, ret_ty);
    } else {
        self.lowerBlock(fd.body);
        self.ensureTerminator(ret_ty);
    }
    self.builder.finalize();
}

/// Pack-fn: has a trailing heterogeneous pack param (`is_variadic
/// AND is_comptime`). Mixed shapes — non-pack comptime params
/// before the pack — are also accepted; the mono folds those
/// comptime VALUES into the mangled name and binds them as both
/// comptime substitutions (for #insert) and runtime locals (for
/// bare-name body references).
pub fn isPackFn(fd: *const ast.FnDecl) bool {
    for (fd.params) |p| {
        if (isPackParam(p)) return true;
    }
    return false;
}

/// A trailing pack parameter: the comptime type-pack `..$args`
/// (`is_comptime`) or the protocol-constrained pack `..xs: P` (`is_pack`).
/// Both monomorphize per call shape via `lowerPackFnCall`; the slice
/// variadic (`..xs: []T`) is neither and stays a runtime slice.
pub fn isPackParam(p: ast.Param) bool {
    return p.is_variadic and (p.is_comptime or p.is_pack);
}

/// Resolve `..pack.<name>` against `protocol_name` by position (Decision 4).
/// No cross-namespace fallback: a value-position name that exists only as a
/// type-arg (or vice versa) is `.not_found`, letting the caller emit a
/// position-specific diagnostic (G3, Step 2.7).
pub fn resolvePackProjection(
    self: *Lowering,
    protocol_name: []const u8,
    name: []const u8,
    pos: ProjectionPosition,
) PackProjection {
    return switch (pos) {
        .type_position => if (self.lookupProtocolArg(protocol_name, name)) |i|
            .{ .type_arg = i }
        else
            .not_found,
        .value_position => if (self.lookupProtocolField(protocol_name, name)) |i|
            .{ .method = i }
        else
            .not_found,
    };
}

pub const ProjectionPosition = enum { type_position, value_position };
pub const PackProjection = union(enum) {
    type_arg: u32, // index into the protocol's `type_params`
    method: u32, // index into the protocol's `methods`
    not_found, // `name` absent from the position-selected namespace
};
