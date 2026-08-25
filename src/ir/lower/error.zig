const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const type_bridge = @import("../type_bridge.zig");
const inst_mod = @import("../inst.zig");
const mod_mod = @import("../module.zig");
const errors = @import("../../errors.zig");
const contracts = @import("../../contracts.zig");
const source_site = @import("../../source_site.zig");
const ErrorAnalysis = @import("../error_analysis.zig").ErrorAnalysis;

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Builder = mod_mod.Builder;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;

/// Lazily declare the `sx_trace_push(u64)` / `sx_trace_clear()` runtime
/// externs. Storage is a `_Thread_local` ring buffer in
/// `library/vendors/sx_trace_runtime/sx_trace.c` — kept OUT of the user's IR
/// module (same JIT-TLS reason as the JNI env slot). Setting
/// `needs_trace_runtime` signals Compilation to auto-link the .c for AOT.
/// Wired into the `raise` / `try` push sites and the absorbing clear sites.
pub fn getTraceFids(self: *Lowering) struct { push: FuncId, clear: FuncId } {
    self.needs_trace_runtime = true;
    if (self.trace_push_fid == null) {
        const name = self.module.types.internString("sx_trace_push");
        const frame_param = self.module.types.internString("frame");
        var params = std.ArrayList(inst_mod.Function.Param).empty;
        params.append(self.alloc, .{ .name = frame_param, .ty = .u64 }) catch unreachable;
        const fid = self.builder.declareExtern(name, params.toOwnedSlice(self.alloc) catch unreachable, .void);
        self.module.getFunctionMut(fid).call_conv = .c;
        self.trace_push_fid = fid;
    }
    if (self.trace_clear_fid == null) {
        const name = self.module.types.internString("sx_trace_clear");
        const fid = self.builder.declareExtern(name, &.{}, .void);
        self.module.getFunctionMut(fid).call_conv = .c;
        self.trace_clear_fid = fid;
    }
    return .{ .push = self.trace_push_fid.?, .clear = self.trace_clear_fid.? };
}

/// Error return-traces are emitted in debug-ish builds and skipped in
/// release. `sx run` defaults to `-O0`
/// (`.none`), the common dev path; `.default`/`.aggressive` are release.
/// The opt level is the gate.
pub fn tracesEnabled(self: *Lowering) bool {
    const tc = self.target_config orelse return true; // no target → treat as debug
    return tc.opt_level == .none or tc.opt_level == .less;
}

/// Emit a trace-buffer push of `frame` (an opaque u64) at a failure site.
/// No-op when traces are disabled (release). `frame` is a placeholder; real
/// return-address PCs require DWARF.
pub fn emitTracePush(self: *Lowering, frame: Ref) void {
    if (!self.tracesEnabled()) return;
    const fids = self.getTraceFids();
    const coerced = self.coerceToType(frame, self.builder.getRefType(frame), .u64);
    const args = self.alloc.dupe(Ref, &.{coerced}) catch return;
    _ = self.builder.emit(.{ .call = .{ .callee = fids.push, .args = args } }, .void);
}

/// Emit a trace-buffer clear at an absorbing site (`catch` / `?? value` /
/// destructure). No-op when traces are disabled.
pub fn emitTraceClear(self: *Lowering) void {
    if (!self.tracesEnabled()) return;
    const fids = self.getTraceFids();
    _ = self.builder.emit(.{ .call = .{ .callee = fids.clear, .args = &.{} } }, .void);
}

/// The trace frame value for a failure site. Emits the
/// niladic `.trace_frame` op (span-stamped via `Builder.current_span`); each
/// backend resolves it to a real frame — `emit_llvm` to a `Frame*`, `interp`
/// to a packed `(func_id, offset)`. The result feeds `sx_trace_push`.
pub fn placeholderTraceFrame(self: *Lowering) Ref {
    return self.builder.emit(.{ .trace_frame = {} }, .u64);
}

/// The named error-set TypeId of `node`'s type, or null if not an
/// error-set-typed expression.
pub fn errorSetTypeOf(self: *Lowering, node: *const Node) ?TypeId {
    const t = self.inferExprType(node);
    if (t.isBuiltin()) return null;
    return if (self.module.types.get(t) == .error_set) t else null;
}

/// True when `node` is an `error.X` tag literal (`field_access` whose
/// object is the `error` keyword, parsed as identifier "error").
pub fn isErrorTagLiteralNode(node: *const Node) bool {
    if (node.data != .field_access) return false;
    const obj = node.data.field_access.object;
    return obj.data == .identifier and std.mem.eql(u8, obj.data.identifier.name, "error");
}

/// The tag NAME a `raise` operand names literally, in either spelling — the
/// anonymous `error.X` or the contextual `.X` shorthand — or null for a
/// variable / computed tag. In `raise` position a `.X` is unambiguously a tag,
/// so the two spellings are interchangeable to every caller of this.
pub fn literalTagName(node: *const Node) ?[]const u8 {
    if (isErrorTagLiteralNode(node)) return node.data.field_access.field;
    if (node.data == .enum_literal) return node.data.enum_literal.name;
    return null;
}

/// The error set a qualified member spelling `Set.Member` names, read from its
/// OBJECT node: a type name resolving to an error set, not shadowed by a value
/// binding or a global value.
pub fn qualifiedErrorSet(self: *Lowering, object: *const Node) ?TypeId {
    if (object.data != .identifier) return null;
    const name = object.data.identifier.name;
    if (self.scope) |s| {
        if (s.lookup(name) != null) return null;
    }
    if (self.program_index.global_names.contains(name)) return null;
    const from = self.current_source_file orelse self.main_file orelse return null;
    const ty = switch (self.selectNominalLeaf(name, from, false)) {
        .resolved => |tid| tid,
        else => return null,
    };
    if (ty.isBuiltin()) return null;
    return if (self.module.types.get(ty) == .error_set) ty else null;
}

pub const QualifiedErrorMember = struct { set: TypeId, member: []const u8 };

/// `Set.Member` read as a whole node, or null when `node` is not one.
pub fn qualifiedErrorMember(self: *Lowering, node: *const Node) ?QualifiedErrorMember {
    if (node.data != .field_access) return null;
    const fa = node.data.field_access;
    const set = self.qualifiedErrorSet(fa.object) orelse return null;
    return .{ .set = set, .member = fa.field };
}

/// The channel a `|` composition in type position denotes, or null when an
/// operand names no error set.
pub fn composedChannel(self: *Lowering, node: *const Node) ?TypeId {
    const table = &self.module.types;
    var members = std.ArrayList(u32).empty;
    defer members.deinit(table.alloc);
    if (!collectChannelMembers(self, node, &members)) return null;
    return table.errorSetType(.empty, members.items);
}

/// Append what each operand of a `|` composition contributes: a named set,
/// a qualified member, or an inline `error { … }` whose members this
/// declaration owns.
fn collectChannelMembers(self: *Lowering, node: *const Node, out: *std.ArrayList(u32)) bool {
    const table = &self.module.types;
    switch (node.data) {
        .binary_op => |b| {
            if (b.op != .bit_or) return false;
            if (!collectChannelMembers(self, b.lhs, out)) return false;
            return collectChannelMembers(self, b.rhs, out);
        },
        .error_set_decl => {
            const info = type_bridge.errorSetDeclInfo(&node.data.error_set_decl, table, self);
            out.appendSlice(table.alloc, info.error_set.tags) catch unreachable;
            return true;
        },
        .identifier => |id| return type_bridge.channelOperandMembers(id.name, table, self, out),
        .field_access => {
            const path = self.qualifiedTypeName(node) orelse return false;
            defer self.alloc.free(path);
            return type_bridge.channelOperandMembers(path, table, self, out);
        },
        else => return false,
    }
}

/// Lower `==` / `!=` when an error-set value or `error.X` tag is involved.
/// Returns null when neither operand is error-related (general path runs).
/// Both operands must be a tag (an `error.X` literal or an error-set value);
/// otherwise it's a type error (e.g. comparing a tag to a raw integer).
pub fn tryLowerErrorSetEquality(self: *Lowering, bop: *const ast.BinaryOp) ?Ref {
    const l_set = self.errorSetTypeOf(bop.lhs);
    const r_set = self.errorSetTypeOf(bop.rhs);
    const l_tag = isErrorTagLiteralNode(bop.lhs);
    const r_tag = isErrorTagLiteralNode(bop.rhs);
    if (l_set == null and r_set == null and !l_tag and !r_tag) return null;

    // A contextual `.Name` shorthand is a tag when the OTHER operand supplies
    // the set to type it from; with no set on either side there is nothing to
    // resolve against and it stays an ordinary enum literal.
    const l_dot = bop.lhs.data == .enum_literal and r_set != null;
    const r_dot = bop.rhs.data == .enum_literal and l_set != null;

    const l_ok = l_set != null or l_tag or l_dot;
    const r_ok = r_set != null or r_tag or r_dot;
    if (!l_ok or !r_ok) {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, bop.lhs.span, "an error-set value compares only with an `error.X` tag, a `.X` shorthand, or another error-set value; coerce with `xx` to compare the raw id", .{});
        }
        return self.builder.constBool(false);
    }

    // Lower both sides with the set type as context so an `error.X` literal
    // resolves to it (and validates membership). Two bare tag literals with
    // no set context lower to global u32 ids (cross-set comparison is OK).
    const set_ty = l_set orelse r_set;
    const saved = self.target_type;
    if (set_ty) |st| self.target_type = st;
    const lv = self.lowerExpr(bop.lhs);
    const rv = self.lowerExpr(bop.rhs);
    self.target_type = saved;
    return if (bop.op == .eq)
        self.builder.cmpEq(lv, rv)
    else
        self.builder.emit(.{ .cmp_ne = .{ .lhs = lv, .rhs = rv } }, .bool);
}

/// The declared return type of the function currently being lowered (the
/// inlined body's type wins while inlining a comptime call), or null when
/// there is no enclosing function.
pub fn effectiveReturnType(self: *Lowering) ?TypeId {
    if (self.inline_return_target) |exit| return exit.ret_ty;
    if (self.builder.func) |fid| return self.module.functions.items[@intFromEnum(fid)].ret;
    return null;
}

/// If `ret_ty` belongs to a failable function, the TypeId of its error
/// channel; else null. `-> !Named` / `-> !` resolve the error set directly;
/// `-> (T..., !)` is a `.failable` whose `err` is the channel.
pub fn errorChannelOf(self: *Lowering, ret_ty: TypeId) ?TypeId {
    if (ret_ty.isBuiltin()) return null;
    switch (self.module.types.get(ret_ty)) {
        .error_set => return ret_ty,
        .failable => |f| return f.err,
        else => return null,
    }
}

/// The return type a `Closure` or function-pointer slot calls through, seen
/// past an optional wrapper, or null when `slot` is neither.
pub fn slotReturnType(self: *Lowering, slot: TypeId) ?TypeId {
    if (slot.isBuiltin()) return null;
    return switch (self.module.types.get(slot)) {
        .closure => |c| c.ret,
        .function => |f| f.ret,
        .optional => |o| slotReturnType(self, o.child),
        else => null,
    };
}

/// Refuse a callable whose error channel is not the slot's own: a `Closure` or
/// function-pointer slot calls through exactly the channel it names, so a
/// merely-narrower channel — or none at all — cannot fill it.
pub fn checkSlotChannel(self: *Lowering, value_ret: TypeId, slot_ret: TypeId, span: ast.Span) bool {
    const have = self.errorChannelOf(value_ret);
    const want = self.errorChannelOf(slot_ret);
    if (have == want) return true;
    if (self.diagnostics) |diags| {
        const have_phrase = channelPhrase(self, have);
        defer self.alloc.free(have_phrase);
        const want_phrase = channelPhrase(self, want);
        defer self.alloc.free(want_phrase);
        diags.addFmt(.err, span, "a callable with {s} does not fill a slot with {s} — a `Closure` or function-pointer slot takes exactly its own channel", .{ have_phrase, want_phrase });
    }
    return false;
}

/// How the message names `channel`. The bare-`!` placeholder carries no member
/// set to name, so it reads as inferred. Owned by the caller.
fn channelPhrase(self: *Lowering, channel: ?TypeId) []const u8 {
    const c = channel orelse return self.alloc.dupe(u8, "no error channel") catch unreachable;
    if (self.isInferredErrorSet(c)) return self.alloc.dupe(u8, "an inferred error channel") catch unreachable;
    return std.fmt.allocPrint(self.alloc, "the error channel '{s}'", .{self.formatTypeName(c)}) catch unreachable;
}

/// True for the bare-`!` inferred placeholder error set (reserved name "!").
pub fn isInferredErrorSet(self: *Lowering, set: TypeId) bool {
    if (set.isBuiltin()) return false;
    const info = self.module.types.get(set);
    if (info != .error_set) return false;
    return std.mem.eql(u8, self.module.types.getString(info.error_set.name), "!");
}

/// Diagnose every tag of `src` that is not also a member of `dst` (the
/// enclosing function's named error set). Both must be `.error_set` types.
pub fn checkErrorSetSubset(self: *Lowering, src: TypeId, dst: TypeId, span: ast.Span) void {
    if (src.isBuiltin()) return;
    const src_info = self.module.types.get(src);
    if (src_info != .error_set) return;
    self.diagTagsNotInSet(src_info.error_set.tags, dst, span);
}

/// An error-set VALUE crossing between two named sets is legal only when
/// every tag of `src` is a member of `dst` — the same subset rule the error
/// channel applies to `raise` and to a forwarded failable. Both sets are
/// u32-backed, so the width-based reinterpret guard in `coerce.zig` classifies
/// the pair as a legitimate same-width passthrough and lets a foreign tag land
/// in the destination slot, where no `error.X` literal of that set can ever
/// name it. The inferred bare-`!` placeholder absorbs any tag on either side.
pub fn checkErrorSetValueCoercion(self: *Lowering, src: TypeId, dst: TypeId, span: ast.Span) void {
    if (src == dst) return;
    if (src.isBuiltin() or dst.isBuiltin()) return;
    const src_info = self.module.types.get(src);
    const dst_info = self.module.types.get(dst);
    if (src_info != .error_set or dst_info != .error_set) return;
    if (self.isInferredErrorSet(src) or self.isInferredErrorSet(dst)) return;
    const src_name = self.module.types.getString(src_info.error_set.name);
    const dst_name = self.module.types.getString(dst_info.error_set.name);
    for (src_info.error_set.tags) |tag| {
        var found = false;
        for (dst_info.error_set.tags) |d| {
            if (d == tag) {
                found = true;
                break;
            }
        }
        if (found) continue;
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, span, "cannot coerce error set '{s}' to '{s}': tag 'error.{s}' is not a member of '{s}'", .{ src_name, dst_name, self.module.types.getTagName(tag), dst_name });
        }
    }
}

/// Diagnose a qualified member `qm` that the named destination set `dst` does
/// not carry.
fn checkMemberInSet(self: *Lowering, qm: QualifiedErrorMember, dst: TypeId, span: ast.Span) void {
    if (dst.isBuiltin()) return;
    const dst_info = self.module.types.get(dst);
    if (dst_info != .error_set) return;
    const src_info = self.module.types.get(qm.set).error_set;
    // Non-membership in Set is diagnosed at the member read.
    const tag = self.module.types.errorSetMemberId(qm.set, qm.member) orelse return;
    if (containsTag(dst_info.error_set.tags, tag)) return;
    if (self.diagnostics) |diags| {
        diags.addFmt(.err, span, "error member '{s}.{s}' is not in caller's error set '{s}'", .{ self.module.types.getString(src_info.name), qm.member, self.module.types.getString(dst_info.error_set.name) });
    }
}

/// Diagnose every tag id in `src_tags` that is not a member of the named
/// error set `dst`. Shared by the named-set subset check and the inferred-set
/// inferred-callee widening (where the callee's tags come from the SCC,
/// not a `.error_set` TypeId).
pub fn diagTagsNotInSet(self: *Lowering, src_tags: []const u32, dst: TypeId, span: ast.Span) void {
    if (dst.isBuiltin()) return;
    const dst_info = self.module.types.get(dst);
    if (dst_info != .error_set) return;
    for (src_tags) |tag| {
        var found = false;
        for (dst_info.error_set.tags) |d| {
            if (d == tag) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, span, "error tag 'error.{s}' is not in caller's error set '{s}'", .{ self.module.types.getTagName(tag), self.module.types.getString(dst_info.error_set.name) });
            }
        }
    }
}

/// `raise EXPR;` — terminate the enclosing failable function via the error
/// channel. A pure-failable return (`-> !` / `-> !Named`, whose return type
/// IS the error set) emits `ret(EXPR)`; a value-carrying one
/// (`-> (T..., !)`) returns the tuple `{undef value slots..., EXPR}`.
pub fn lowerRaise(self: *Lowering, rs: *const ast.RaiseStmt, span: ast.Span) void {
    // (1) `raise` is legal only inside a failable function.
    const ret_ty = self.effectiveReturnType() orelse {
        self.diagRaiseNotFailable(span);
        return;
    };
    const err_set = self.errorChannelOf(ret_ty) orelse {
        self.diagRaiseNotFailable(span);
        return;
    };
    const inferred = self.isInferredErrorSet(err_set);

    // (2) Set check. Lowering EXPR with the function's error set as the
    //     target type makes a literal `raise error.X` validate `X ∈ set`
    //     inside lowerErrorTagLiteral (the inferred placeholder accepts any
    //     tag). The variable form `raise e` is subset-checked below.
    const saved_target = self.target_type;
    self.target_type = err_set;
    const tag_ref = self.lowerExpr(rs.tag);
    self.target_type = saved_target;

    if (!inferred) {
        if (qualifiedErrorMember(self, rs.tag)) |qm| {
            // A qualified member carries its whole set as its static type, but
            // only the member itself lands in the channel.
            checkMemberInSet(self, qm, err_set, span);
        } else if (literalTagName(rs.tag) == null) {
            if (self.errorSetTypeOf(rs.tag)) |src_set| {
                self.checkErrorSetSubset(src_set, err_set, span);
            }
        }
    }

    // (3) Push a trace frame: `raise` always escapes the function.
    //     Before cleanup, so the frame records the raise site itself.
    self.emitTracePush(self.placeholderTraceFrame());

    // (4) Emit the failure return. Pure-failable: the return type IS the
    //     error set, so return the tag value directly. Step (2)'s subset rule
    //     owns the set relationship here, so the tag move into the channel
    //     bypasses the implicit value-coercion membership guard.
    if (ret_ty == err_set) {
        const tag_ty = self.builder.getRefType(tag_ref);
        const coerced = if (tag_ty != err_set) self.coerceExplicit(tag_ref, tag_ty, err_set) else tag_ref;
        self.emitErrorCleanup(self.func_defer_base, coerced);
        self.emitBodyExit(coerced, err_set, .return_like);
    } else {
        // Value-carrying `-> (T..., !)`: the error path leaves the value
        // slots undefined and carries the tag in the error slot.
        const tag_ty = self.builder.getRefType(tag_ref);
        const coerced_tag = if (tag_ty != err_set) self.coerceExplicit(tag_ref, tag_ty, err_set) else tag_ref;
        self.emitErrorCleanup(self.func_defer_base, coerced_tag);
        const f = self.module.types.get(ret_ty).failable;
        const n = self.module.types.failableValueSlotCount(f);
        var slots = std.ArrayList(Ref).empty;
        defer slots.deinit(self.alloc);
        for (0..n) |i| {
            slots.append(self.alloc, self.builder.constUndef(self.module.types.failableValueSlotType(f, i))) catch unreachable;
        }
        const tup = self.buildFailableTuple(ret_ty, slots.items, coerced_tag);
        self.emitTupleRet(ret_ty, tup);
    }
}

/// Return a value-carrying failable function's success tuple
/// `{value(s)..., 0}` from `ref` (the user-returned value part). Forwarding
/// a full failable tuple (`return other_failable()` / explicit `return
/// (v, e)`) returns it as-is. Single-value `-> (T, !)` takes `ref` as the
/// lone value; multi-value `-> (T1, ..., !)` takes `ref` as a value-tuple
/// `(T1, ...)` and re-assembles its slots alongside the success error slot.
pub fn lowerFailableSuccessReturn(self: *Lowering, ref: Ref, ret_ty: TypeId, span: ast.Span) void {
    const f = self.module.types.get(ret_ty).failable;
    const n_vals = self.module.types.failableValueSlotCount(f);
    const err_ty = f.err;
    const val_ty = self.builder.getRefType(ref);
    if (val_ty == ret_ty) {
        self.emitTupleRet(ret_ty, ref);
        return;
    }
    if (!val_ty.isBuiltin()) {
        switch (self.module.types.get(val_ty)) {
            .failable => |vf| {
                lowerFailableForwardReturn(self, ref, ret_ty, val_ty, vf.err, span);
                return;
            },
            .error_set => {
                if (self.diagnostics) |d| d.addFmt(.err, span, "cannot forward this failable result: it carries 0 value slots, but the function returns {d}", .{n_vals});
                return;
            },
            else => {},
        }
    }
    if (n_vals == 1) {
        const slot = self.module.types.failableValueSlotType(f, 0);
        const cv = if (self.checkReturnable(ref, val_ty, slot, span))
            self.coerceToType(ref, val_ty, slot)
        else
            ref;
        const tup = self.buildFailableTuple(ret_ty, &.{cv}, self.builder.constInt(0, err_ty));
        self.emitTupleRet(ret_ty, tup);
        return;
    }
    const prod = if (val_ty.isBuiltin()) null else switch (self.module.types.get(val_ty)) {
        .@"struct" => |s| s.fields,
        else => null,
    };
    if (prod == null or prod.?.len != n_vals) {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, span, "a multi-value failable function (`-> (T1, ..., !)`) must `return` a {d}-tuple of its value types", .{n_vals});
        }
        return;
    }
    var vals = std.ArrayList(Ref).empty;
    defer vals.deinit(self.alloc);
    for (0..n_vals) |i| {
        const vty = prod.?[i].ty;
        const slot = self.module.types.failableValueSlotType(f, i);
        const fv = emitProductGet(self, ref, val_ty, i, vty);
        const cf = if (self.checkReturnable(fv, vty, slot, span))
            self.coerceToType(fv, vty, slot)
        else
            fv;
        vals.append(self.alloc, cf) catch unreachable;
    }
    const tup = self.buildFailableTuple(ret_ty, vals.items, self.builder.constInt(0, err_ty));
    self.emitTupleRet(ret_ty, tup);
}

/// `return callee(...)` forwarding a failable tuple whose ERROR SET differs
/// from the enclosing function's (`(T, !Concrete)` → `(T, !)`, or concrete →
/// concrete). Error members are ids in one pool (TypeTable.TagRegistry; 0 = "no
/// error"), so every error set shares one runtime repr — a u32 member id — and
/// a legal forward re-packs the value slots plus the raw id, no translation.
/// Legality mirrors `raise`'s subset rule (specs.md "Error sets"): the open
/// bare `!` absorbs any concrete set; a NAMED caller set requires the
/// callee's set ⊆ caller's (each escapee diagnosed); a bare-`!` CALLEE has no
/// statically-known tag set (its placeholder TypeId carries no tags), so it
/// cannot be proven ⊆ a named set — rejected, destructure + re-raise instead.
fn lowerFailableForwardReturn(self: *Lowering, ref: Ref, ret_ty: TypeId, val_ty: TypeId, src_err: TypeId, span: ast.Span) void {
    const dst = self.module.types.get(ret_ty).failable;
    const src = self.module.types.get(val_ty).failable;
    const err_ty = dst.err;
    const dn = self.module.types.failableValueSlotCount(dst);
    const sn = self.module.types.failableValueSlotCount(src);
    if (sn != dn) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "cannot forward this failable result: it carries {d} value slot{s}, but the function returns {d}", .{ sn, if (sn == 1) @as([]const u8, "") else @as([]const u8, "s"), dn });
        return;
    }
    if (!checkForwardSetCompat(self, src_err, err_ty, span)) return;
    var vals = std.ArrayList(Ref).empty;
    defer vals.deinit(self.alloc);
    for (0..dn) |i| {
        const vty = self.module.types.failableValueSlotType(src, i);
        const slot = self.module.types.failableValueSlotType(dst, i);
        const fv = self.builder.emit(.{ .struct_get = .{ .base = ref, .field_index = @intCast(i), .base_type = val_ty } }, vty);
        const cf = if (self.checkReturnable(fv, vty, slot, span))
            self.coerceToType(fv, vty, slot)
        else
            fv;
        vals.append(self.alloc, cf) catch unreachable;
    }
    const tag = self.builder.emit(.{ .struct_get = .{ .base = ref, .field_index = @intCast(dn), .base_type = val_ty } }, err_ty);
    const tup = self.buildFailableTuple(ret_ty, vals.items, tag);
    self.emitTupleRet(ret_ty, tup);
}

/// The shared error-set compatibility rule for a failable FORWARD (`return
/// callee()` across sets), mirroring `raise`'s subset rule (specs.md "Error
/// sets"): the open bare `!` absorbs any concrete set; a NAMED caller set
/// requires the callee's set ⊆ caller's (each escapee diagnosed, but the
/// shape-correct lowering continues — the build aborts via hasErrors); a
/// bare-`!` CALLEE has no statically-known tag set (its placeholder TypeId
/// carries no tags), so it cannot be proven ⊆ a named set — rejected
/// (returns false), destructure + re-raise instead.
fn checkForwardSetCompat(self: *Lowering, src_err: TypeId, dst_err: TypeId, span: ast.Span) bool {
    if (src_err == dst_err) return true;
    if (self.isInferredErrorSet(dst_err)) return true;
    if (self.isInferredErrorSet(src_err)) {
        const dst_info = self.module.types.get(dst_err);
        if (self.diagnostics) |d| d.addFmt(.err, span, "cannot forward a bare-`!` failable result through the named error set '{s}' — its inferred error set is not statically known here; destructure and re-raise instead (`v, e := …; if e {{ raise error.X; }} return v;`)", .{self.module.types.getString(dst_info.error_set.name)});
        return false;
    }
    self.checkErrorSetSubset(src_err, dst_err, span);
    return true;
}

/// The returned value of a PURE failable's `return EXPR;` (`-> !` /
/// `-> !Named`, whose return type IS the error set), coerced for the ret.
/// A pure→pure forward (`return check();`, EXPR's type is another error
/// set) applies the shared set-compat rule — every channel is one shared u32
/// repr, so the re-type IS the whole coercion. A value-carrying
/// failable result (`return inner();` where inner is `-> (T, !E)`) is
/// REJECTED per the arity rule (its value slots have nowhere to go — the
/// old coerce path silently truncated the tuple, returning the VALUE bits
/// as the error tag). Anything else keeps the plain coerce.
pub fn coercePureFailableReturn(self: *Lowering, ref: Ref, ret_ty: TypeId, span: ast.Span) Ref {
    const val_ty = self.builder.getRefType(ref);
    if (val_ty == ret_ty) return ref;
    if (!val_ty.isBuiltin()) {
        switch (self.module.types.get(val_ty)) {
            .error_set => {
                if (!checkForwardSetCompat(self, val_ty, ret_ty, span)) {
                    // Rejected (diagnosed): a typed placeholder keeps the ret
                    // well-formed; the build aborts via hasErrors.
                    return self.builder.constInt(0, ret_ty);
                }
                return self.coerceToType(ref, val_ty, ret_ty);
            },
            .failable => |vf| {
                const n = self.module.types.failableValueSlotCount(vf);
                if (self.diagnostics) |d| d.addFmt(.err, span, "cannot forward this failable result: it carries {d} value slot{s}, but the function returns 0", .{ n, if (n == 1) @as([]const u8, "") else @as([]const u8, "s") });
                return self.builder.constInt(0, ret_ty);
            },
            else => {},
        }
    }
    // A non-error-set value returned from a pure failable
    // (`return "str";` in `-> !E`) has no modeled coercion to the error set —
    // diagnose instead of welding the value's bits into the tag.
    if (!self.checkReturnable(ref, val_ty, ret_ty, span)) {
        return self.builder.constInt(0, ret_ty);
    }
    return self.coerceToType(ref, val_ty, ret_ty);
}

fn emitProductGet(self: *Lowering, base: Ref, ty: TypeId, i: usize, fty: TypeId) Ref {
    return self.builder.emit(.{ .struct_get = .{ .base = base, .field_index = @intCast(i), .base_type = ty } }, fty);
}

/// Build a failable return `{value_refs..., tag}` typed `ret_ty`.
pub fn buildFailableTuple(self: *Lowering, ret_ty: TypeId, value_refs: []const Ref, tag: Ref) Ref {
    var fields = std.ArrayList(Ref).empty;
    defer fields.deinit(self.alloc);
    fields.appendSlice(self.alloc, value_refs) catch unreachable;
    fields.append(self.alloc, tag) catch unreachable;
    return self.builder.emit(.{ .struct_init = .{ .fields = self.alloc.dupe(Ref, fields.items) catch unreachable } }, ret_ty);
}

/// The success (value-part) type of a value-carrying failable
/// `op_ty` (`-> (T..., !)`): the lone value type for a single-value
/// failable, or the anonymous product of the value slots for a multi-value
/// one. A pure `-> !`'s success type is `void`, handled separately.
pub fn failableSuccessType(self: *Lowering, op_ty: TypeId) TypeId {
    return self.module.types.get(op_ty).failable.value;
}

/// The `target_type` to lower a returned expression against. For a
/// value-carrying failable (`-> (T..., !)`) a BARE returned value resolves
/// against the success value type (so a bare enum literal gets its real
/// ordinal); an EXPLICIT full failable tuple literal (`return (v..., e)`,
/// arity == full-tuple field count) keeps the failable-tuple target so its
/// trailing error element resolves against the error set and is forwarded
/// as-is. Every other return type passes through unchanged.
pub fn failableReturnTarget(self: *Lowering, ret_ty: TypeId, value_node: ?*const Node) TypeId {
    if (ret_ty.isBuiltin()) return ret_ty;
    if (self.module.types.get(ret_ty) != .failable) return ret_ty;
    const f = self.module.types.get(ret_ty).failable;
    const n = self.module.types.failableValueSlotCount(f);
    if (value_node) |vn| {
        if (vn.data == .tuple_literal and
            vn.data.tuple_literal.elements.len == n + 1)
            return ret_ty;
    }
    return self.failableSuccessType(ret_ty);
}

/// Extract the success value from an evaluated value-carrying failable
/// tuple `result` (type `op_ty`): the lone value slot for single-value,
/// or an assembled value-tuple (typed `succ_ty`) for multi-value.
pub fn extractSuccessValue(self: *Lowering, result: Ref, op_ty: TypeId, succ_ty: TypeId) Ref {
    const f = self.module.types.get(op_ty).failable;
    const n_vals = self.module.types.failableValueSlotCount(f);
    if (n_vals == 1) {
        return self.builder.emit(.{ .struct_get = .{ .base = result, .field_index = 0, .base_type = op_ty } }, self.module.types.failableValueSlotType(f, 0));
    }
    var vals = std.ArrayList(Ref).empty;
    defer vals.deinit(self.alloc);
    for (0..n_vals) |i| {
        vals.append(self.alloc, self.builder.emit(.{ .struct_get = .{ .base = result, .field_index = @intCast(i), .base_type = op_ty } }, self.module.types.failableValueSlotType(f, i))) catch unreachable;
    }
    return self.builder.structInit(self.alloc.dupe(Ref, vals.items) catch unreachable, succ_ty);
}

/// Extract the error slot (always the last field) of an evaluated
/// value-carrying failable tuple `result`, typed as `err_set`.
pub fn extractErrorSlot(self: *Lowering, result: Ref, op_ty: TypeId, err_set: TypeId) Ref {
    const f = self.module.types.get(op_ty).failable;
    const n = self.module.types.failableValueSlotCount(f);
    return self.builder.emit(.{ .struct_get = .{ .base = result, .field_index = @intCast(n), .base_type = op_ty } }, err_set);
}

/// Emit a return of an already-assembled failable tuple.
pub fn emitTupleRet(self: *Lowering, ret_ty: TypeId, tup: Ref) void {
    self.emitBodyExit(tup, ret_ty, .return_like);
}

pub fn diagRaiseNotFailable(self: *Lowering, span: ast.Span) void {
    if (self.diagnostics) |diags| {
        if (self.in_lambda_body) {
            diags.addFmt(.err, span, "lambda body raises; declare its return type explicitly with `-> (T, !)` or `-> (T, !Named)`", .{});
        } else {
            diags.addFmt(.err, span, "`raise` is only valid inside a failable function (a return type with `!` or `!Named`)", .{});
        }
    }
}

/// True if `node`'s value is failable — a `try` (the result is its
/// operand's success value, but the expression itself routes an error) or
/// any expression whose type carries an error channel (a bare failable
/// call). Used to detect failable `??` chains.
pub fn exprIsFailable(self: *Lowering, node: *const Node) bool {
    if (node.data == .try_expr) return true;
    return self.errorChannelOf(self.inferExprType(node)) != null;
}

/// Build the `@SourceSite` a `@caller` marker stands for.
///
/// `file` / `declaration` / `ordinal` / `id` come from the source-site index,
/// which keyed them off the CALL expression — so a generic specialization
/// reports its template's path, and a loop reports one site however many times
/// it runs. `line` / `column` are the call span resolved against the source
/// text, one-based, and are the only fields that are position-dependent.
pub fn lowerCallerSite(self: *Lowering, node: *const Node) Ref {
    const tid = self.sourceSiteType() orelse {
        if (self.diagnostics) |d| {
            const contract = contracts.find(source_site.contract_name).?;
            d.addFmt(.err, node.span, "'@caller' needs '{s}' in scope — @import \"{s}\"", .{ source_site.contract_name, contract.module });
        }
        return self.builder.constInt(0, .void);
    };
    // The marker may sit inside a larger declared default, whose root evaluates
    // under the callee's lexical source; the retained provenance is the only
    // place the caller's identity survives that. A marker that IS the whole
    // default was re-authored onto the call site and reads the same way.
    const call_site = if (self.active_default_call_site) |site|
        if (site.caller_func == self.builder.func) site else null
    else
        null;
    const file = if (call_site) |site|
        site.source orelse node.source_file orelse self.current_source_file orelse (self.main_file orelse "")
    else
        node.source_file orelse self.current_source_file orelse (self.main_file orelse "");
    const location_span = if (call_site) |site| site.span else node.span;
    const src = self.sourceForFile(file);
    const loc = errors.SourceLoc.compute(src, location_span.start);

    const site = callerSiteIdentity(self, file, if (call_site) |cs| cs.node else null);
    return sourceSiteValue(self, tid, site, @intCast(loc.line), @intCast(loc.col));
}

/// The indexed identity of the call `node`, or — for a call the site pass never
/// saw (a synthesized one) — the enclosing declaration at ordinal 0, so the
/// site still names where it came from.
fn callerSiteIdentity(self: *Lowering, file: []const u8, node: ?*const Node) source_site.Site {
    if (node) |n| {
        if (self.site_index) |idx| {
            if (idx.get(n)) |site| return site;
        }
    }
    const module_path = source_site.normalizeModulePath(file, self.stdlib_paths, self.mainDir());
    const prefix = source_site.modulePrefix(self.alloc, module_path) catch module_path;
    const func = self.currentFunctionName();
    const declaration = if (func.len == 0)
        prefix
    else
        std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ prefix, func }) catch prefix;
    return .{
        .file = module_path,
        .declaration = declaration,
        .ordinal = 0,
        .id = source_site.computeId(module_path, declaration, 0),
    };
}

/// The source text for `file`, via the diagnostics' file→source map (which
/// The registered `@SourceSite` type. Looked up by the registry's contract
/// name, not a bare spelling, so the type a `@caller` builds is the one the
/// canonical declaration registered.
pub fn sourceSiteType(self: *Lowering) ?TypeId {
    return self.module.types.findByName(self.module.types.internString(source_site.contract_name));
}

/// Build a `@SourceSite` value of type `tid` from an indexed site plus the
/// one-based `line` / `column` that only the source text can answer. THE single
/// place the contract's field order is written down, so every producer
/// (`@caller`, a build block's `site()`, an initializer's `site()`) emits the
/// same shape.
pub fn sourceSiteValue(self: *Lowering, tid: TypeId, site: source_site.Site, line: i32, column: i32) Ref {
    var fields = [_]Ref{
        self.builder.constString(self.module.types.internString(site.file)),
        self.builder.constString(self.module.types.internString(site.declaration)),
        self.builder.constInt(line, .i32),
        self.builder.constInt(column, .i32),
        self.builder.constInt(@bitCast(site.ordinal), .u64),
        self.builder.constInt(@bitCast(site.id), .u64),
    };
    return self.builder.emit(.{ .struct_init = .{ .fields = self.alloc.dupe(Ref, &fields) catch unreachable } }, tid);
}

/// The compilation root: the main file's directory. `main_file` already came
/// through `imports.canonicalizePath`, so this is spelled the way resolved
/// module paths are.
pub fn mainDir(self: *Lowering) ?[]const u8 {
    const mf = self.main_file orelse return null;
    const idx = std.mem.lastIndexOfScalar(u8, mf, '/') orelse return null;
    return mf[0..idx];
}

/// includes the main file). Empty if unavailable — line:col then degrade to
/// 1:1 rather than crash.
pub fn sourceForFile(self: *Lowering, file: []const u8) []const u8 {
    const diags = self.diagnostics orelse return "";
    if (diags.import_sources) |is| {
        if (is.get(file)) |s| return s;
    }
    return diags.source;
}

/// Name of the function currently being lowered (the caller, at a
/// `@caller` site), or "" outside any function.
pub fn currentFunctionName(self: *Lowering) []const u8 {
    const fid = self.builder.func orelse return "";
    return self.module.types.getString(self.module.functions.items[@intFromEnum(fid)].name);
}

/// `try X` — a fallible attempt whose failure target is function
/// propagation. Evaluates X, then branches on its error tag: the failure
/// path runs the function's cleanups and returns the caller's failure
/// carrying that tag; the success path continues with X's value — the value
/// part for a value-carrying callee, `void` for a pure-failable one.
pub fn lowerTry(self: *Lowering, operand_in: *const Node, span: ast.Span) Ref {
    // A direct assertion operand (`try av.(T)`) desugars to the failable
    // runtime call and consumes through the ordinary machinery below.
    const operand = self.desugarErasedAssert(operand_in) orelse operand_in;
    // (1) `try` is legal only inside a failable function.
    const caller_ret = self.effectiveReturnType() orelse {
        self.diagTryNotFailable(span);
        return self.builder.constInt(0, .void);
    };
    const caller_set = self.errorChannelOf(caller_ret) orelse {
        self.diagTryNotFailable(span);
        return self.builder.constInt(0, .void);
    };

    // (2) The operand must be failable. This is the sole failable-operand
    //     check (the parser imposes none).
    const op_ty = self.inferExprType(operand);
    const callee_set = self.errorChannelOf(op_ty) orelse {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, span, "`try` requires a failable expression; operand has type '{s}'", .{self.formatTypeName(op_ty)});
        }
        return self.builder.constInt(0, .void);
    };

    // A value-carrying callee (`-> (T..., !)`) returns a tuple
    // `{v..., err}`; a pure-failable callee (`-> !`) returns the bare
    // error tag.
    const callee_value_carrying = op_ty != callee_set;

    // (3) Widening: the callee's escape set must be ⊆ the caller's named
    //     set. For an inferred caller (`!`) the absorption happens in the
    //     whole-program SCC — no check here.
    self.checkEscapeWidening(operand, callee_set, caller_set, span);

    // (4) Lower: evaluate the operand, then branch on its error tag (which
    //     is the bare result for a pure callee, or the last tuple slot for
    //     a value-carrying one).
    const result = self.lowerExpr(operand);
    const err_val = if (callee_value_carrying)
        self.extractErrorSlot(result, op_ty, callee_set)
    else
        result;
    const err_ty = self.builder.getRefType(err_val);
    const is_err = self.builder.emit(.{ .cmp_ne = .{ .lhs = err_val, .rhs = self.builder.constInt(0, err_ty) } }, .bool);

    const prop_bb = self.freshBlock("try.prop");
    const ok_bb = self.freshBlock("try.ok");
    self.builder.condBr(is_err, prop_bb, &.{}, ok_bb, &.{});

    // Propagation: push a trace frame (this `try` failure escapes to the
    // caller), run the function's cleanups (defers + onfails,
    // since this is an error exit), then return the caller's failure
    // carrying this tag (pure caller → `ret(tag)`; value-carrying →
    // `ret {undef…, tag}`).
    self.builder.switchToBlock(prop_bb);
    self.emitTracePush(self.placeholderTraceFrame());
    self.emitErrorCleanup(self.func_defer_base, err_val);
    self.emitErrorReturn(caller_ret, caller_set, err_val);

    // Success: a value-carrying callee yields its value part (the lone
    // value, or a value-tuple); a pure-failable callee has no value (void).
    self.builder.switchToBlock(ok_bb);
    if (callee_value_carrying) {
        const succ_ty = self.failableSuccessType(op_ty);
        return self.extractSuccessValue(result, op_ty, succ_ty);
    }
    return self.builder.constInt(0, .void);
}

/// Return the enclosing function's failure carrying error tag `err`. A
/// pure-failable caller (`-> !`) returns the tag directly; a value-carrying
/// caller (`-> (T..., !)`) returns `{undef value slots..., tag}`. Honors
/// inline-comptime return targets. The caller emits defers first.
pub fn emitErrorReturn(self: *Lowering, caller_ret: TypeId, caller_set: TypeId, err: Ref) void {
    const ety = self.builder.getRefType(err);
    // The channel's own subset rule (`checkEscapeWidening` / `checkErrorSetSubset`
    // at the raise / propagate / forward site) owns this move, so it bypasses the
    // implicit value-coercion membership guard rather than being reported twice.
    const coerced = if (ety != caller_set) self.coerceExplicit(err, ety, caller_set) else err;
    if (caller_ret == caller_set) {
        self.emitBodyExit(coerced, caller_set, .return_like);
    } else {
        const f = self.module.types.get(caller_ret).failable;
        const n = self.module.types.failableValueSlotCount(f);
        var undefs = std.ArrayList(Ref).empty;
        defer undefs.deinit(self.alloc);
        for (0..n) |i| {
            undefs.append(self.alloc, self.builder.constUndef(self.module.types.failableValueSlotType(f, i))) catch unreachable;
        }
        const tup = self.buildFailableTuple(caller_ret, undefs.items, coerced);
        self.emitTupleRet(caller_ret, tup);
    }
}

pub fn diagTryNotFailable(self: *Lowering, span: ast.Span) void {
    if (self.diagnostics) |diags| {
        diags.addFmt(.err, span, "`try` is only valid inside a failable function (a return type with `!` or `!Named`)", .{});
    }
}

/// `expr catch [e] BODY` — inline failure handler. Evaluates `expr`; on
/// failure binds the tag to `e` (if present) and runs BODY, which either
/// diverges or falls through. A pure-failable LHS has no success value, so
/// both paths merge at `void`; a value-carrying LHS yields its value part on
/// success and BODY's value on failure, merged through a block parameter.
/// `catch` consumes the error locally, so — unlike `try` / `raise` — it needs
/// no failable *enclosing* function.
pub fn lowerCatch(self: *Lowering, ce_in: *const ast.CatchExpr, span: ast.Span) Ref {
    // A direct assertion operand (`av.(T) catch …`) desugars to the
    // failable runtime call; the ordinary paths below consume it.
    var ce_rewritten: ast.CatchExpr = undefined;
    const ce: *const ast.CatchExpr = if (self.desugarErasedAssert(ce_in.operand)) |dsg| blk: {
        ce_rewritten = ce_in.*;
        ce_rewritten.operand = @constCast(dsg);
        break :blk &ce_rewritten;
    } else ce_in;
    // A failable `??` chain operand (`(try a ?? try b) catch |e| …`) routes
    // its total failure to the catch handler — not the function — via the
    // chain-fail target. A chain's value type is non-failable
    // `T`, so it wouldn't pass the `errorChannelOf` check below.
    if (ce.operand.data == .null_coalesce and
        self.coalesceIsFailable(&ce.operand.data.null_coalesce))
    {
        return self.lowerCatchOverChain(ce, span);
    }

    const op_ty = self.inferExprType(ce.operand);
    const err_set = self.errorChannelOf(op_ty) orelse {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, span, "`catch` requires a failable expression; operand has type '{s}'", .{self.formatTypeName(op_ty)});
        }
        return self.builder.constInt(0, .void);
    };
    // Pure-failable LHS (`-> !`): no success value. Run the body on the
    // error path; both paths fall through to a value-less merge.
    if (op_ty == err_set) {
        const err_val = self.lowerExpr(ce.operand);
        const err_ty = self.builder.getRefType(err_val);
        const is_err = self.builder.emit(.{ .cmp_ne = .{ .lhs = err_val, .rhs = self.builder.constInt(0, err_ty) } }, .bool);
        const handle_bb = self.freshBlock("catch.handle");
        const merge_bb = self.freshBlock("catch.merge");
        self.builder.condBr(is_err, handle_bb, &.{}, merge_bb, &.{});
        self.builder.switchToBlock(handle_bb);
        _ = self.runCatchBody(ce, err_val, err_set, null);
        // The handler can inspect the trace (`trace.print_current()`); the
        // absorption clear fires once it completes WITHOUT re-raising (a
        // fall-through). A diverging body (`raise` / `return`) keeps /
        // discards the buffer on its own path (reconciles
        // §clear-points "cleared before body" with §catch-over-or
        // "frames still in the buffer when the body runs").
        if (!self.currentBlockHasTerminator()) {
            self.emitTraceClear();
            self.builder.br(merge_bb, &.{});
        }
        self.builder.switchToBlock(merge_bb);
        return self.builder.constInt(0, .void);
    }

    // Value-carrying LHS (`-> (T..., !)`): on success the catch yields the
    // value part (the lone value, or a value-tuple); on error it yields
    // the handler body's value. The paths merge through a block-parameter
    // (phi).
    const succ_ty = self.failableSuccessType(op_ty);
    const result = self.lowerExpr(ce.operand);
    const err_val = self.extractErrorSlot(result, op_ty, err_set);
    const succ_val = self.extractSuccessValue(result, op_ty, succ_ty);
    const is_err = self.builder.emit(.{ .cmp_ne = .{ .lhs = err_val, .rhs = self.builder.constInt(0, err_set) } }, .bool);

    const handle_bb = self.freshBlock("catch.handle");
    const merge_bb = self.freshBlockWithParams("catch.merge", &.{succ_ty});
    // Success → merge with the value slot; error → run the handler.
    self.builder.condBr(is_err, handle_bb, &.{}, merge_bb, &.{succ_val});

    self.builder.switchToBlock(handle_bb);
    const body_val = self.runCatchBody(ce, err_val, err_set, succ_ty);
    if (!self.currentBlockHasTerminator()) {
        self.finishCatchHandler(body_val, succ_ty, merge_bb, span);
    }

    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, succ_ty);
}

/// `(failable ??-chain) catch [e] BODY`. The chain's operands
/// route per the chain rules; its TOTAL failure (the final operand failing)
/// is redirected to the catch handler via `chain_fail_target` rather than
/// propagating to the function. `e` binds the final error tag; the handler's
/// value (or divergence) joins the chain's success value at the merge.
pub fn lowerCatchOverChain(self: *Lowering, ce: *const ast.CatchExpr, span: ast.Span) Ref {
    const chain = &ce.operand.data.null_coalesce;

    var operands = std.ArrayList(*const Node).empty;
    defer operands.deinit(self.alloc);
    self.flattenCoalesceChain(chain, &operands);

    // The error tag reaching the handler is the final operand's. A
    // value-terminator last operand means the chain can't fail — nothing for
    // `catch` to absorb.
    const last = unwrapTryNode(operands.items[operands.items.len - 1]);
    const last_ty = self.inferExprType(last);
    const err_set = self.errorChannelOf(last_ty) orelse {
        if (self.diagnostics) |d| d.addFmt(.err, span, "`catch` here is redundant — the `??` chain already absorbs every failure via its value terminator", .{});
        return self.builder.constInt(0, .void);
    };

    const succ_ty = self.coalesceChainSuccessType(chain);
    const has_value = succ_ty != .void;

    const handle_bb = self.freshBlockWithParams("catch.handle", &.{err_set});
    const merge_bb = if (has_value)
        self.freshBlockWithParams("catch.merge", &.{succ_ty})
    else
        self.freshBlock("catch.merge");

    // Lower the chain with its total failure routed to the handler.
    const saved = self.chain_fail_target;
    self.chain_fail_target = .{ .bb = handle_bb, .set = err_set };
    const chain_val = self.lowerExpr(ce.operand);
    self.chain_fail_target = saved;
    // Chain success → merge with its value (the buffer was already cleared
    // at the succeeding operand inside the chain).
    if (has_value) {
        const cv = self.coerceToType(chain_val, self.builder.getRefType(chain_val), succ_ty);
        self.builder.br(merge_bb, &.{cv});
    } else {
        self.builder.br(merge_bb, &.{});
    }

    // Handler: bind the final tag, run the body. The buffer still holds the
    // chain's frames (handler may inspect them); absorb on non-diverging exit.
    self.builder.switchToBlock(handle_bb);
    const tag = self.builder.blockParam(handle_bb, 0, err_set);
    const body_val = self.runCatchBody(ce, tag, err_set, if (has_value) succ_ty else null);
    if (!self.currentBlockHasTerminator()) {
        self.finishCatchHandler(body_val, succ_ty, merge_bb, span);
    }

    self.builder.switchToBlock(merge_bb);
    return if (has_value) self.builder.blockParam(merge_bb, 0, succ_ty) else self.builder.constInt(0, .void);
}

/// Close a non-terminated `catch` handler block. `succ_ty` is the catch's
/// result type (`.void` for a pure-failable / void-chain catch — the merge
/// block then has no parameter). A `body_val` typed `noreturn` (e.g. a
/// `process.exit` / other noreturn call, which is NOT an IR terminator)
/// diverges: close with `unreachable` and skip the merge edge so its
/// "value" never reaches a phi. Otherwise clear the absorbed trace and
/// branch to the merge (coercing the body value, or diagnosing a missing /
/// void value for a value-carrying catch).
pub fn finishCatchHandler(self: *Lowering, body_val: ?Ref, succ_ty: TypeId, merge_bb: BlockId, span: ast.Span) void {
    if (body_val) |v| {
        if (self.builder.getRefType(v) == .noreturn) {
            self.builder.emitUnreachable();
            return;
        }
    }
    self.emitTraceClear();
    if (succ_ty == .void) {
        self.builder.br(merge_bb, &.{});
        return;
    }
    const bv: Ref = blk: {
        if (body_val) |v| {
            const vty = self.builder.getRefType(v);
            if (vty != .void) break :blk self.coerceToType(v, vty, succ_ty);
        }
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, span, "`catch` body must produce a value of type '{s}' (or diverge with `return` / `raise`)", .{self.formatTypeName(succ_ty)});
        }
        break :blk self.builder.constUndef(succ_ty);
    };
    self.builder.br(merge_bb, &.{bv});
}

/// Lower a `catch` body in a child scope that binds the error tag to the
/// catch binding (if any). When `want_ty` is non-null (value-carrying
/// catch), returns the body's value (or null if the body diverged); when
/// null (pure-failable catch), runs the body for effect and returns null.
pub fn runCatchBody(self: *Lowering, ce: *const ast.CatchExpr, err_val: Ref, err_set: TypeId, want_ty: ?TypeId) ?Ref {
    var handle_scope = Scope.init(self.alloc, self.scope);
    const saved_scope = self.scope;
    self.scope = &handle_scope;
    defer {
        self.scope = saved_scope;
        handle_scope.deinit();
    }
    if (ce.binding) |name| {
        handle_scope.put(name, .{ .ref = err_val, .ty = err_set, .is_alloca = false, .origin = .catch_err });
    }
    if (want_ty == null) {
        if (ce.body.data == .block) self.lowerBlock(ce.body) else _ = self.lowerExpr(ce.body);
        return null;
    }
    const saved_fbv = self.force_block_value;
    self.force_block_value = true;
    defer self.force_block_value = saved_fbv;
    return if (ce.body.data == .block) self.lowerBlockValue(ce.body) else self.lowerExpr(ce.body);
}

/// Widening at an escape (function-propagation) site: the escaping set must
/// be ⊆ the caller's named set. An inferred caller (`!`) absorbs everything
/// via the whole-program SCC — no check. A bare-`!` callee carries
/// no tags on its placeholder TypeId, so check its SCC-converged set.
/// Shared by `try` propagation and a failable `??` chain's final operand.
pub fn checkEscapeWidening(self: *Lowering, callee_node: *const Node, callee_set: TypeId, caller_set: TypeId, span: ast.Span) void {
    if (self.isInferredErrorSet(caller_set)) return;
    if (!self.isInferredErrorSet(callee_set)) {
        self.checkErrorSetSubset(callee_set, caller_set, span);
        return;
    }
    // Bare-`!` callee: either a named top-level function (its converged set
    // is name-keyed) or a closure/fn-type SLOT (its set is shape-keyed,
    // shared program-wide by value-signature).
    if (callTargetName(callee_node)) |nm| {
        if (self.inferred_error_sets.get(nm)) |tags| {
            self.diagTagsNotInSet(tags, caller_set, span);
            return;
        }
    }
    if (self.shapeKeyOfCallee(callee_node)) |key| {
        if (self.shape_inferred_sets.get(key)) |tags| {
            self.diagTagsNotInSet(tags, caller_set, span);
        }
        // Empty union (no closure of this shape ever raises) → silently
        // allowed: the slot's `!` resolves to ∅.
    }
}

/// Structural test: does this `??` default a FAILABLE left operand (a value
/// terminator or a chain), rather than an optional? True when the left
/// operand is failable-like — a `try`, an error-channel-typed expression, or
/// itself a nested failable `??` chain. Kept separate from `inferExprType`:
/// a `try`-chain's *value* type is its success type `T` (non-failable), so
/// the chain-ness is structural, not type-derived.
pub fn coalesceIsFailable(self: *Lowering, nc: *const ast.NullCoalesce) bool {
    return self.operandIsFailableLike(nc.lhs);
}

pub fn operandIsFailableLike(self: *Lowering, node: *const Node) bool {
    if (node.data == .try_expr) return true;
    if (node.data == .null_coalesce) {
        return self.coalesceIsFailable(&node.data.null_coalesce);
    }
    // A postfix assertion on a type-erased receiver is failable BY SHAPE
    // (its inferred type is the asserted T; the failable form exists only
    // for the consumers, which desugar it — see desugarErasedAssert).
    if (self.isErasedAssertNode(node)) return true;
    return self.errorChannelOf(self.inferExprType(node)) != null;
}

/// True iff `node` is `expr.(T)` in the checked-assertion shape: an `any`
/// receiver, or a protocol receiver whose target is a concrete downcast
/// (the type_id word makes it the any assertion over the
/// value's {ctx, type_id} prefix view).
pub fn isErasedAssertNode(self: *Lowering, node: *const Node) bool {
    if (node.data != .postfix_cast) return false;
    const pc = &node.data.postfix_cast;
    // `.(?T)` is the SOFT assertion — a plain `?T` VALUE (null on
    // mismatch), not a failable; it lowers in the postfix_cast arm and
    // is never claimed by try/or/catch.
    if (pc.type_expr.data == .optional_type_expr) return false;
    // Chained form `o?.(T)`: the failable shape when the receiver is
    // `?any` (chain-null is a value; a present mismatch is the error).
    if (pc.is_optional_chain) {
        const rt = self.inferExprType(pc.operand);
        if (rt.isBuiltin()) return false;
        const ri = self.module.types.get(rt);
        return ri == .optional and ri.optional.child == .any;
    }
    const rt = self.inferExprType(pc.operand);
    if (rt == .any) {
        // `.(@Any)` on an `any` is the raw-view retrieval — never
        // fails, so it is not claimable by try/or/catch. Name-based like
        // the @Protocol exemption below (this predicate runs
        // speculatively and must not resolve or diagnose).
        const tname: []const u8 = switch (pc.type_expr.data) {
            .identifier => |id| id.name,
            .type_expr => |te| te.name,
            else => return true,
        };
        return !std.mem.eql(u8, tname, "@Any");
    }
    // A PROTOCOL receiver is the downcast — failable exactly like the any
    // assertion — unless the target is a recovery/conversion (a pointer,
    // @Protocol, `any`, or another protocol), which never fails. The
    // gate is SHAPE-based (no resolveTypeArg here — this predicate runs
    // speculatively and must not emit diagnostics).
    if (self.getProtocolInfo(rt) != null) {
        {
            const tname: []const u8 = switch (pc.type_expr.data) {
                .pointer_type_expr, .many_pointer_type_expr => return false, // ctx recovery
                .identifier => |id| id.name,
                .type_expr => |te| te.name,
                else => return true, // composite targets: assertion by tag
            };
            if (std.mem.eql(u8, tname, "@Protocol")) return false;
            if (std.mem.eql(u8, tname, "any")) return false; // prefix view
            if (self.program_index.protocol_decl_map.contains(tname)) return false; // re-erasure
            return true;
        }
    }
    return false;
}

/// Rewrite a DIRECT assertion operand of a graceful consumer (`try` /
/// failable-`??` operand / `catch`) into the failable runtime call
/// `__sx_cast_assert(av, T)` (std/fmt.sx) so the ordinary error-channel
/// machinery consumes it. Looks through a `try` marker. Returns null for
/// every other shape — including assertions NESTED inside the operand
/// expression, which stay in the unconsumed (panic) form by design.
pub fn desugarErasedAssert(self: *Lowering, node: *const Node) ?*const Node {
    if (node.data == .try_expr) {
        const inner = self.desugarErasedAssert(node.data.try_expr.operand) orelse return null;
        const wrapped = self.alloc.create(Node) catch unreachable;
        wrapped.* = node.*;
        wrapped.data.try_expr.operand = @constCast(inner);
        return wrapped;
    }
    if (!self.isErasedAssertNode(node)) return null;
    const pc = &node.data.postfix_cast;
    // A PROTOCOL target on an `any`(-chained) receiver can never succeed
    // (an any's tag is always concrete) — refuse instead of desugaring to
    // an always-failing runtime check. Protocol RECEIVERS are exempt (their
    // protocol-target form is re-erasure, not an assertion).
    {
        const recv_t = self.inferExprType(pc.operand);
        const any_recv = recv_t == .any or (!recv_t.isBuiltin() and blk: {
            const ri = self.module.types.get(recv_t);
            break :blk ri == .optional and ri.optional.child == .any;
        });
        if (any_recv and self.refuseProtocolAssertTargetOnAny(pc.type_expr, node.span)) return null;
        // A bare open set as the target is the same shape of impossible: an
        // `any` never holds a set value. The assertion is answered where it is
        // written rather than desugared, so the helper is never asked for a
        // conversion no box can supply.
        if (any_recv and pc.type_expr.data != .optional_type_expr) {
            const target = self.resolveTypeArg(pc.type_expr);
            if (target != .unresolved and self.isOpenSet(target) and
                self.refuseSetFromAny(target, node.span)) return null;
        }
    }
    const helper: []const u8 = if (pc.is_optional_chain) "__sx_chain_cast_assert" else "__sx_cast_assert";
    const callee = self.alloc.create(Node) catch unreachable;
    callee.* = .{ .data = .{ .identifier = .{ .name = helper } }, .span = node.span, .source_file = node.source_file };
    // A protocol receiver reaches the helper as its {ctx, type_id} prefix
    // VIEW — wrap in `xx …` so the arg lowers through the modeled
    // protocol_to_any conversion under the helper's `av: any` param.
    const operand_node: *Node = blk_w: {
        const rt = self.inferExprType(pc.operand);
        if (self.getProtocolInfo(rt) == null) break :blk_w pc.operand;
        const xx_node = self.alloc.create(Node) catch unreachable;
        xx_node.* = .{ .data = .{ .unary_op = .{ .op = .xx, .operand = pc.operand } }, .span = pc.operand.span, .source_file = pc.operand.source_file };
        break :blk_w xx_node;
    };
    const args = self.alloc.dupe(*Node, &.{ operand_node, pc.type_expr }) catch unreachable;
    const call = self.alloc.create(Node) catch unreachable;
    call.* = .{ .data = .{ .call = .{ .callee = callee, .args = args } }, .span = node.span, .source_file = node.source_file };
    return call;
}

/// The success (value) type of a failable `??` chain: descend to the
/// leftmost operand, unwrap any `try`, and take its failable success type
/// (`void` for a pure-`-> !` chain). All operands share this type.
pub fn coalesceChainSuccessType(self: *Lowering, nc: *const ast.NullCoalesce) TypeId {
    var lhs = nc.lhs;
    while (lhs.data == .null_coalesce and self.coalesceIsFailable(&lhs.data.null_coalesce)) {
        lhs = lhs.data.null_coalesce.lhs;
    }
    const ft = self.inferExprType(unwrapTryNode(lhs));
    const fset = self.errorChannelOf(ft) orelse return .unresolved;
    return if (ft == fset) .void else self.failableSuccessType(ft);
}

/// `try X` → `X` (the underlying failable); any other node unchanged. In a
/// `??` chain the `try` marker's routing IS the chain, so the chain lowers
/// the underlying failable directly rather than re-entering `lowerTry`.
pub fn unwrapTryNode(node: *const Node) *const Node {
    return if (node.data == .try_expr) node.data.try_expr.operand else node;
}

/// Flatten a failable `??` chain into its operands, left-to-right. `??` is
/// right-associative, so `a ?? b ?? c` nests as `a ?? (b ?? c)`; both spines
/// are walked, so an explicitly parenthesized `(a ?? b) ?? c` collects the
/// same `[a, b, c]`. A nested `??` that is not itself failable stops the walk
/// and stands as one operand.
pub fn flattenCoalesceChain(self: *Lowering, nc: *const ast.NullCoalesce, list: *std.ArrayList(*const Node)) void {
    flattenCoalesceOperand(self, nc.lhs, list);
    flattenCoalesceOperand(self, nc.rhs, list);
}

fn flattenCoalesceOperand(self: *Lowering, node: *const Node, list: *std.ArrayList(*const Node)) void {
    if (node.data == .null_coalesce and self.coalesceIsFailable(&node.data.null_coalesce)) {
        self.flattenCoalesceChain(&node.data.null_coalesce, list);
        return;
    }
    // Chain operands that are direct assertions (`av.(T) ?? d`)
    // desugar to the failable runtime call here, so every consumer
    // of the flattened list sees an ordinary failable.
    list.append(self.alloc, self.desugarErasedAssert(node) orelse node) catch unreachable;
}

/// Lower a failable `??`: a value-terminator (`lhs ?? value`) or
/// a chain (`try a ?? try b ?? …`, possibly with a trailing value
/// terminator). Left-to-right, short-circuit: each failable operand's
/// failure routes to the next operand; the final operand either absorbs
/// (value terminator) or propagates to the enclosing function. Each failed
/// attempt pushes a trace frame; an absorbing resolution (any operand
/// succeeding, or the value terminator) clears the buffer; total failure
/// preserves the frames for the caller.
pub fn lowerFailableCoalesce(self: *Lowering, nc: *const ast.NullCoalesce) Ref {
    const span = nc.lhs.span;

    var operands = std.ArrayList(*const Node).empty;
    defer operands.deinit(self.alloc);
    self.flattenCoalesceChain(nc, &operands);
    const last_idx = operands.items.len - 1;
    const last_is_value = !self.operandIsFailableLike(operands.items[last_idx]);

    // The chain's total-failure routing. An absorbing consumer (`catch`)
    // sets this so the final operand's failure reaches the handler; cleared
    // while lowering operands so a nested operand doesn't inherit it.
    const fail_target = self.chain_fail_target;
    self.chain_fail_target = null;
    defer self.chain_fail_target = fail_target;

    // Success type from the first operand (a failable; unwrap any `try`).
    const first_ty = self.inferExprType(unwrapTryNode(operands.items[0]));
    const first_set = self.errorChannelOf(first_ty) orelse {
        if (self.diagnostics) |d| d.addFmt(.err, span, "the left operand of a failable `??` must be failable; got '{s}'", .{self.formatTypeName(first_ty)});
        return self.builder.constInt(0, .void);
    };
    const has_value = first_ty != first_set;
    const succ_ty = if (has_value) self.failableSuccessType(first_ty) else TypeId.void;

    // Pure-failable LHS (`-> !`) with a value terminator: nothing to fall
    // back to.
    if (!has_value and last_is_value) {
        if (self.diagnostics) |d| d.addFmt(.err, span, "`?? value` requires a value-carrying failable (`-> (T, !)`) — a `-> !` has no success value to fall back to; use `catch` to absorb the error", .{});
        return self.builder.constInt(0, .void);
    }

    // Caller failability — only needed when the chain can propagate to the
    // function (final operand is failable AND no absorbing consumer target).
    var caller_ret: TypeId = .void;
    var caller_set: TypeId = .void;
    if (!last_is_value and fail_target == null) {
        const cret = self.effectiveReturnType();
        const cset = if (cret) |r| self.errorChannelOf(r) else null;
        if (cset == null) {
            if (self.diagnostics) |d| d.addFmt(.err, span, "a failable `??` chain propagates on total failure, so it is only valid inside a failable function — add a value terminator (`… ?? value`) or wrap with `catch`", .{});
            return self.builder.constInt(0, .void);
        }
        caller_ret = cret.?;
        caller_set = cset.?;
    }

    const merge_bb = if (has_value)
        self.freshBlockWithParams("orc.merge", &.{succ_ty})
    else
        self.freshBlock("orc.merge");

    for (operands.items, 0..) |operand, i| {
        const is_last = i == last_idx;

        if (is_last and last_is_value) {
            // Value terminator: absorbs every prior failure.
            self.emitTraceClear();
            const saved = self.target_type;
            self.target_type = succ_ty;
            const v = self.lowerExpr(operand);
            self.target_type = saved;
            const vc = self.coerceToType(v, self.builder.getRefType(v), succ_ty);
            self.builder.br(merge_bb, &.{vc});
            break;
        }

        // Failable operand (`try X` marker or a bare failable). Lower the
        // underlying failable; the `try` marker's routing IS the chain.
        const underlying = unwrapTryNode(operand);
        const op_ty = self.inferExprType(underlying);
        const op_set = self.errorChannelOf(op_ty) orelse {
            if (self.diagnostics) |d| d.addFmt(.err, operand.span, "operand of a failable `??` chain must be failable; got '{s}'", .{self.formatTypeName(op_ty)});
            return self.builder.constInt(0, .void);
        };
        const op_value_carrying = op_ty != op_set;

        // Widening applies only when the final failure escapes to the
        // function (no absorbing consumer); a `catch` target absorbs it.
        if (is_last and fail_target == null) self.checkEscapeWidening(underlying, op_set, caller_set, operand.span);

        const result = self.lowerExpr(underlying);
        const err_val = if (op_value_carrying) self.extractErrorSlot(result, op_ty, op_set) else result;
        const err_ty = self.builder.getRefType(err_val);
        const is_err = self.builder.emit(.{ .cmp_ne = .{ .lhs = err_val, .rhs = self.builder.constInt(0, err_ty) } }, .bool);

        const ok_bb = self.freshBlock("orc.ok");
        const fail_bb = self.freshBlock(if (is_last) "orc.prop" else "orc.next");
        self.builder.condBr(is_err, fail_bb, &.{}, ok_bb, &.{});

        // Success: the chain resolved here — clear the buffer, merge value.
        self.builder.switchToBlock(ok_bb);
        self.emitTraceClear();
        if (has_value) {
            const sv = self.extractSuccessValue(result, op_ty, succ_ty);
            const svc = self.coerceToType(sv, self.builder.getRefType(sv), succ_ty);
            self.builder.br(merge_bb, &.{svc});
        } else {
            self.builder.br(merge_bb, &.{});
        }

        // Failure: push a trace frame, then either route to the next
        // operand (same block — no function exit, so `onfail` does not
        // fire) or, for the final operand, resolve the total failure: to an
        // absorbing consumer (`catch`) if one set a target, else propagate
        // to the caller.
        self.builder.switchToBlock(fail_bb);
        self.emitTracePush(self.placeholderTraceFrame());
        if (is_last) {
            if (fail_target) |t| {
                const ec = self.coerceToType(err_val, self.builder.getRefType(err_val), t.set);
                self.builder.br(t.bb, &.{ec});
            } else {
                self.emitErrorCleanup(self.func_defer_base, err_val);
                self.emitErrorReturn(caller_ret, caller_set, err_val);
            }
        }
        // else: fall through — the next operand is lowered in fail_bb.
    }

    self.builder.switchToBlock(merge_bb);
    return if (has_value) self.builder.blockParam(merge_bb, 0, succ_ty) else self.builder.constInt(0, .void);
}

// ── whole-program inferred-error-set convergence ──────────

/// The bare callee name of a call expression (`g(...)` → "g"), or null if
/// the node isn't a direct call to a named function. Convergence resolves only
/// the bare identifier (top-level functions); UFCS / mangled-local callees
/// aren't tracked by the SCC.
pub fn callTargetName(node: *const Node) ?[]const u8 {
    if (node.data != .call) return null;
    const callee = node.data.call.callee;
    return if (callee.data == .identifier) callee.data.identifier.name else null;
}

/// True when `rt` is a pure bare-`!` failable return (`-> !`, the inferred
/// set) — NOT `!Named` and NOT a value-carrying `-> (T..., !)` tuple.
pub fn astIsPureBareInferred(rt: ?*const Node) bool {
    const n = rt orelse return false;
    return n.data == .error_type_expr and n.data.error_type_expr.operands.len == 0;
}

/// The named-set name of a pure `-> !Named` return (`"Named"`), or null for
/// bare-`!`, value-carrying, or non-failable returns.
pub fn astPureNamedSet(rt: ?*const Node) ?[]const u8 {
    const n = rt orelse return null;
    if (n.data != .error_type_expr) return null;
    return n.data.error_type_expr.namedSet();
}

/// The declared tags of a named error set, by name; null if not a
/// registered error set.
pub fn namedSetTags(self: *Lowering, name: []const u8) ?[]const u32 {
    const sid = self.module.types.internString(name);
    const tid = self.module.types.findByName(sid) orelse return null;
    if (tid.isBuiltin()) return null;
    const info = self.module.types.get(tid);
    return if (info == .error_set) info.error_set.tags else null;
}

/// Whole-program inferred-error-set convergence. Thin delegation to the
/// canonical owner (`ErrorAnalysis`, `error_analysis.zig`); kept on
/// `Lowering` as a `pub` entry point because the lowering pipeline and the
/// convergence unit test call it.
pub fn convergeInferredErrorSets(self: *Lowering) void {
    self.errorAnalysis().convergeInferredErrorSets();
}

pub fn containsTag(tags: []const u32, t: u32) bool {
    for (tags) |x| if (x == t) return true;
    return false;
}

/// Whole-program closure-shape error-set convergence. Thin delegation to the
/// canonical owner (`ErrorAnalysis`, `error_analysis.zig`); kept on
/// `Lowering` as a `pub` entry point because the lowering pipeline calls it.
pub fn convergeClosureShapeSets(self: *Lowering) void {
    self.errorAnalysis().convergeClosureShapeSets();
}

/// Record one closure literal's contribution to its value-signature shape's
/// inferred-`!` union. No-op unless the literal is a CONCRETE (non-generic)
/// bare-`!` failable closure; named-set / non-failable literals add no tags.
pub fn recordClosureShape(self: *Lowering, lam: *const ast.Lambda) void {
    if (lam.type_params.len > 0) return; // generic shapes out of scope (sub-feature 8)
    const rt_node = lam.return_type orelse return; // no annotation → non-failable infer
    const ret = self.resolveType(rt_node);
    const es = self.errorChannelOf(ret) orelse return; // not failable
    if (!self.isInferredErrorSet(es)) return; // `!Named` → its own set, not the inferred union

    var ptys = std.ArrayList(TypeId).empty;
    defer ptys.deinit(self.alloc);
    for (lam.params) |p| {
        if (p.is_variadic or p.is_pack or p.is_comptime) return; // not a plain fn-type slot
        ptys.append(self.alloc, self.resolveType(p.type_expr)) catch return;
    }
    const key = self.closureShapeKey(ptys.items, self.returnValuePart(ret));

    var tags = std.ArrayList(u32).empty;
    defer tags.deinit(self.alloc);
    var edges = std.ArrayList([]const u8).empty;
    defer edges.deinit(self.alloc);
    // `dyn` (opaque-error-channel `try`) is irrelevant to closure-shape set
    // widening — that signal only gates the top-level "drop the `!`" warning.
    var dyn_unused = false;
    self.errorAnalysis().collectErrorSites(lam.body, &tags, &edges, &dyn_unused);
    for (edges.items) |callee| {
        for (self.calleeEscapeTags(callee)) |t| {
            if (!containsTag(tags.items, t)) tags.append(self.alloc, t) catch {};
        }
    }
    self.unionShapeTags(key, tags.items);
}

/// The escape tags of a callee referenced by name from a `try g()` edge:
/// a bare-`!` callee's converged set, or a `-> !Named` callee's declared set.
pub fn calleeEscapeTags(self: *Lowering, callee: []const u8) []const u32 {
    if (self.inferred_error_sets.get(callee)) |t| return t;
    if (self.program_index.fn_ast_map.get(callee)) |cfd| {
        if (astPureNamedSet(cfd.return_type)) |nm| return self.namedSetTags(nm) orelse &.{};
    }
    return &.{};
}

/// Merge `new_tags` into the shape node `key` (sorted, deduped). The map is
/// content-keyed (StringHashMap), so re-`put` with a fresh equal key string
/// overwrites the existing node's value in place.
pub fn unionShapeTags(self: *Lowering, key: []const u8, new_tags: []const u32) void {
    var list = std.ArrayList(u32).empty;
    defer list.deinit(self.alloc);
    if (self.shape_inferred_sets.get(key)) |existing| list.appendSlice(self.alloc, existing) catch {};
    for (new_tags) |t| {
        if (!containsTag(list.items, t)) list.append(self.alloc, t) catch {};
    }
    const sorted = self.alloc.dupe(u32, list.items) catch return;
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
    self.shape_inferred_sets.put(key, sorted) catch {};
}

/// Canonical key for a callable VALUE-signature: param types + the value
/// part of the return (error slot excluded). Bare-`!` and non-failable
/// shapes of the same value-sig — and `.function` vs `.closure` of that
/// sig — collapse to one key, so all occurrences share one inferred node.
pub fn closureShapeKey(self: *Lowering, params: []const TypeId, value_ret: TypeId) []const u8 {
    var buf = std.ArrayList(u8).empty;
    buf.appendSlice(self.alloc, "shape") catch return "shape";
    for (params) |p| {
        buf.append(self.alloc, '_') catch return "shape";
        buf.appendSlice(self.alloc, self.mangleTypeName(p)) catch return "shape";
    }
    buf.appendSlice(self.alloc, "__") catch return "shape";
    buf.appendSlice(self.alloc, self.mangleTypeName(value_ret)) catch return "shape";
    return buf.items;
}

/// The value part of a (possibly failable) return type, error slot dropped:
/// `(T, !)` → T (or a value-tuple); pure `-> !` → void; non-failable → self.
pub fn returnValuePart(self: *Lowering, ret: TypeId) TypeId {
    const es = self.errorChannelOf(ret) orelse return ret;
    if (ret == es) return .void;
    return self.failableSuccessType(ret);
}

/// Shape key of a call's callee expression when it's a closure/fn-type slot
/// (variable, field, index — anything with a `.closure`/`.function` type),
/// for the program-wide shape-union widening lookup. Null for non-callables.
pub fn shapeKeyOfCallee(self: *Lowering, node: *const Node) ?[]const u8 {
    if (node.data != .call) return null;
    const fty = self.inferExprType(node.data.call.callee);
    if (fty.isBuiltin()) return null;
    const info = self.module.types.get(fty);
    const params: []const TypeId = switch (info) {
        .closure => |c| c.params,
        .function => |f| f.params,
        else => return null,
    };
    const ret: TypeId = switch (info) {
        .closure => |c| c.ret,
        .function => |f| f.ret,
        else => return null,
    };
    return self.closureShapeKey(params, self.returnValuePart(ret));
}
