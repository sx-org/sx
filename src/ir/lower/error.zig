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

/// A member named at a `raise`, over every spelling of it.
pub const RaisedMember = struct {
    /// The set a qualified spelling names; null when the member resolves in
    /// the channel in hand.
    set: ?TypeId,
    /// The `.X` spelling, which resolves ONLY against a channel in hand.
    shorthand: bool,
    member: []const u8,
    /// The spelling carries a brace group, so it builds the member's payload.
    constructed: bool,
};

/// The head a brace group is written against, or null when `node` carries no
/// brace group. A `raise` operand reaches error analysis before its statement
/// settles, so both readings of the juxtaposition answer.
fn bracedHead(node: *const Node) ?*const Node {
    return switch (node.data) {
        .struct_literal => |sl| sl.type_expr,
        .juxtaposition => |jx| jx.expr,
        else => null,
    };
}

/// The member a `raise` operand names — `.X`, `Set.X`, or either with a
/// payload brace group — or null when the operand is a live error value.
pub fn raisedMember(self: *Lowering, node: *const Node) ?RaisedMember {
    const braced = bracedHead(node);
    const head = braced orelse node;
    if (qualifiedErrorMember(self, head)) |qm|
        return .{ .set = qm.set, .shorthand = false, .member = qm.member, .constructed = braced != null };
    const name = if (braced == null)
        literalTagName(head) orelse return null
    else if (head.data == .enum_literal)
        head.data.enum_literal.name
    else
        return null;
    return .{ .set = null, .shorthand = head.data == .enum_literal, .member = name, .constructed = braced != null };
}

/// The member name a `match` arm's pattern names on an error-set subject, in
/// any spelling — `.X`, `X`, `Set.X`. Null for an `else:` arm or a pattern no
/// member spelling reaches.
pub fn errorArmMemberName(pattern: ?*const Node) ?[]const u8 {
    const pat = pattern orelse return null;
    return switch (pat.data) {
        .enum_literal => |el| el.name,
        .identifier => |id| id.name,
        .field_access => |fa| fa.field,
        else => null,
    };
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

/// How the message names `channel`. A member-less channel has only its
/// identity to name. Owned by the caller.
fn channelPhrase(self: *Lowering, channel: ?TypeId) []const u8 {
    const c = channel orelse return self.alloc.dupe(u8, "no error channel") catch unreachable;
    if (channelIsPlaceholder(self, c)) return self.alloc.dupe(u8, "an inferred error channel") catch unreachable;
    if (channelIsDyn(self, c)) return self.alloc.dupe(u8, "a dynamic error channel") catch unreachable;
    const members = channelMembers(self, c);
    if (members.len == 0) return self.alloc.dupe(u8, "an empty error channel") catch unreachable;
    // A merge over one owner's members renders as that owner's spelling, which
    // is another channel's name; the member list tells the two apart.
    const name = self.module.types.get(c).error_set.name;
    if (self.module.types.findByName(name)) |other| {
        if (other != c) {
            const list = memberList(self, members);
            defer self.alloc.free(list);
            return std.fmt.allocPrint(self.alloc, "the error channel '{s}' ({s})", .{ self.module.types.getString(name), list }) catch unreachable;
        }
    }
    return std.fmt.allocPrint(self.alloc, "the error channel '{s}'", .{self.formatTypeName(c)}) catch unreachable;
}

/// The members `set` carries, empty when `set` is not an error channel.
fn channelMembers(self: *Lowering, set: TypeId) []const u32 {
    if (set.isBuiltin()) return &.{};
    const info = self.module.types.get(set);
    return if (info == .error_set) info.error_set.tags else &.{};
}

/// The `Owner.Member` spellings of `members`, comma-joined. Owned by the caller.
fn memberList(self: *Lowering, members: []const u32) []const u8 {
    var buf = std.ArrayList(u8).empty;
    for (members, 0..) |m, i| {
        if (i > 0) buf.appendSlice(self.alloc, ", ") catch unreachable;
        const owner = self.module.types.tags.ownerName(self.module.types.tags.ownerOf(m));
        if (owner != .empty) {
            buf.appendSlice(self.alloc, self.module.types.getString(owner)) catch unreachable;
            buf.append(self.alloc, '.') catch unreachable;
        }
        buf.appendSlice(self.alloc, self.module.types.getTagName(m)) catch unreachable;
    }
    return buf.toOwnedSlice(self.alloc) catch unreachable;
}

/// True when the enclosing signature's channel is written bare `!` — an open
/// channel, or a merge materialised from the raises of a declaration whose
/// return type is written `!`.
fn channelIsWrittenInferred(self: *Lowering, err_set: TypeId) bool {
    if (self.channelIsOpen(err_set)) return true;
    // A `try { … }` boundary's channel is what its raises converge to.
    if (self.error_boundary != null) return true;
    const fd = self.current_fn_decl orelse return false;
    return astChannelIsInferred(fd.return_type);
}

/// The reserved spelling a MEMBER-LESS channel is identified by, or null when
/// `set` is not one.
fn channelSpelling(self: *Lowering, set: TypeId) ?[]const u8 {
    if (set.isBuiltin()) return null;
    const info = self.module.types.get(set);
    if (info != .error_set or info.error_set.tags.len > 0) return null;
    return self.module.types.getString(info.error_set.name);
}

/// True for the bare-`!` placeholder a WRITTEN fn-type spelling carries
/// (reserved name "!").
pub fn channelIsPlaceholder(self: *Lowering, set: TypeId) bool {
    const spelling = channelSpelling(self, set) orelse return false;
    return std.mem.eql(u8, spelling, "!");
}

/// True for the channel of a declaration whose body escapes through a channel
/// that cannot be named.
pub fn channelIsDyn(self: *Lowering, set: TypeId) bool {
    const spelling = channelSpelling(self, set) orelse return false;
    return std.mem.eql(u8, spelling, types.TypeTable.dyn_channel_spelling);
}

/// True for a channel with NO STATIC MEMBER SET. It absorbs any tag as a
/// destination, and cannot be shown ⊆ a named set as a source.
pub fn channelIsOpen(self: *Lowering, set: TypeId) bool {
    return channelIsPlaceholder(self, set) or channelIsDyn(self, set);
}

/// Diagnose every tag of `src` that is not also a member of `dst` (the
/// enclosing function's named error set). Both must be `.error_set` types.
pub fn checkErrorSetSubset(self: *Lowering, src: TypeId, dst: TypeId, span: ast.Span) void {
    if (src.isBuiltin()) return;
    const src_info = self.module.types.get(src);
    if (src_info != .error_set) return;
    self.diagTagsNotInSet(src_info.error_set.tags, dst, span);
}

/// Whether an error-set value of `src` is a legal retype to `dst`: every
/// source tag id is in `dst`, or an inferred bare-`!` on either side absorbs
/// any tag.
pub fn errorSetValueRetypeIsLegal(self: *Lowering, src: TypeId, dst: TypeId) bool {
    if (src == dst) return true;
    if (src.isBuiltin() or dst.isBuiltin()) return false;
    const src_info = self.module.types.get(src);
    const dst_info = self.module.types.get(dst);
    if (src_info != .error_set or dst_info != .error_set) return false;
    if (self.channelIsOpen(src) or self.channelIsOpen(dst)) return true;
    for (src_info.error_set.tags) |tag| {
        var found = false;
        for (dst_info.error_set.tags) |d| {
            if (d == tag) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Diagnose every tag of `src` that the destination set `dst` cannot name.
/// Membership is the implicit gate on an error-set value coercion; a pair it
/// refuses is unmodeled, so no `error.X` literal of `dst` could name the tag
/// that lands in the slot.
pub fn checkErrorSetValueCoercion(self: *Lowering, src: TypeId, dst: TypeId, span: ast.Span) void {
    if (src == dst) return;
    if (src.isBuiltin() or dst.isBuiltin()) return;
    const src_info = self.module.types.get(src);
    const dst_info = self.module.types.get(dst);
    if (src_info != .error_set or dst_info != .error_set) return;
    if (self.channelIsOpen(src) or self.channelIsOpen(dst)) return;
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

/// The channel value `Set.Member{ … }` / `.Member{ … }` builds: `member`'s tag
/// over a copy of its declared payload, typed as `set_ty`.
pub fn lowerErrorMemberConstruction(self: *Lowering, sl: *const ast.StructLiteral, set_ty: TypeId, member_name: []const u8, span: ast.Span) Ref {
    const table = &self.module.types;
    const member = table.errorSetMemberId(set_ty, member_name) orelse {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "error set '{s}' has no member '{s}'", .{ table.getString(table.get(set_ty).error_set.name), member_name });
        }
        return self.builder.constUndef(set_ty);
    };
    const tag = self.builder.constInt(@intCast(member), set_ty);
    const payload_ty = table.memberPayload(member);
    if (payload_ty == .void) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, span, "'{s}' carries no payload, and a brace group holds one", .{member_name});
            d.addHelpFmt(id, span, null, "write '.{s}'", .{member_name});
        }
        return tag;
    }
    const payload = memberPayloadValue(self, sl, payload_ty, member_name, span) orelse return tag;
    return self.builder.enumInit(member, payload, set_ty);
}

/// The payload a member's brace group holds. A struct payload takes the struct
/// literal's own rules, empty braces included; every other payload is the one
/// value in the braces, so empty braces name nothing to carry.
fn memberPayloadValue(self: *Lowering, sl: *const ast.StructLiteral, payload_ty: TypeId, member_name: []const u8, span: ast.Span) ?Ref {
    const table = &self.module.types;
    if (!payload_ty.isBuiltin() and table.get(payload_ty) == .@"struct") {
        const inner: ast.StructLiteral = .{ .struct_name = null, .type_expr = null, .field_inits = sl.field_inits };
        const saved = self.target_type;
        self.target_type = payload_ty;
        defer self.target_type = saved;
        return self.lowerStructLiteral(&inner, span);
    }
    if (sl.field_inits.len != 1 or (sl.field_inits[0].name != null and !sl.field_inits[0].was_shorthand)) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "'{s}' carries a payload of type '{s}' — write the one value in the braces ('.{s}{{ … }}')", .{ member_name, self.formatTypeName(payload_ty), member_name });
        }
        return null;
    }
    const value_node = sl.field_inits[0].value;
    const saved = self.target_type;
    self.target_type = payload_ty;
    const val = self.lowerExpr(value_node);
    self.target_type = saved;
    const src_ty = self.builder.getRefType(val);
    if (self.refuseVoidElement(src_ty, payload_ty, null, 0, value_node.span)) return self.zeroValue(payload_ty);
    return self.coerceToType(val, src_ty, payload_ty);
}

/// Diagnose a member spelled bare where it declares a payload: the channel
/// value carries that payload, and only a brace group supplies one.
fn checkMemberPayloadConstructed(self: *Lowering, rm: RaisedMember, channel: TypeId, span: ast.Span) bool {
    if (rm.constructed) return true;
    const set = rm.set orelse channel;
    if (set.isBuiltin() or self.module.types.get(set) != .error_set) return true;
    const member = self.module.types.errorSetMemberId(set, rm.member) orelse return true;
    const payload_ty = self.module.types.memberPayload(member);
    if (payload_ty == .void) return true;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'{s}' carries a payload of type '{s}', and this names it bare", .{ rm.member, self.formatTypeName(payload_ty) });
        d.addHelpFmt(id, span, null, "construct it — '.{s}{{ … }}'", .{rm.member});
    }
    return false;
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

/// `raise EXPR;` — terminate the enclosing failable body via the error
/// channel: the innermost `try { … }` boundary, else the function itself.
pub fn lowerRaise(self: *Lowering, rs: *const ast.RaiseStmt, span: ast.Span) void {
    // (1) `raise` is legal only inside a failable body — a function, or a
    //     `try { … }` boundary.
    const exit = errorExit(self) orelse {
        self.diagRaiseNotFailable(span);
        return;
    };
    const err_set = exit.set;
    const inferred = self.channelIsOpen(err_set);
    const named = raisedMember(self, rs.tag);

    // A `.X` shorthand resolves only against a channel already in hand. A
    // signature written bare `!` is not one: the channel is what its raises
    // converge to, so `.X` has nothing to name a member in.
    if (named) |rm| {
        if (rm.shorthand and channelIsWrittenInferred(self, err_set)) {
            if (self.diagnostics) |d| {
                d.addFmt(.err, span, "`.{s}` needs an error channel in hand, and the enclosing `!` is inferred — qualify the member (`Set.{s}`)", .{ rm.member, rm.member });
            }
            return;
        }
        if (!checkMemberPayloadConstructed(self, rm, err_set, span)) return;
    }

    // (2) Set check. Lowering EXPR with the function's error set as the
    //     target type makes a literal `raise error.X` validate `X ∈ set`
    //     inside lowerErrorTagLiteral (the inferred placeholder accepts any
    //     tag). The variable form `raise e` is subset-checked below.
    const saved_target = self.target_type;
    self.target_type = err_set;
    const tag_ref = self.lowerExpr(rs.tag);
    self.target_type = saved_target;

    if (!inferred) {
        if (named) |rm| {
            // A qualified member carries its whole set as its static type, but
            // only the member itself lands in the channel.
            if (rm.set) |set| checkMemberInSet(self, .{ .set = set, .member = rm.member }, err_set, span);
        } else if (self.errorSetTypeOf(rs.tag)) |src_set| {
            self.checkErrorSetSubset(src_set, err_set, span);
        }
    }

    // (3) Push a trace frame: `raise` always escapes the function.
    //     Before cleanup, so the frame records the raise site itself.
    self.emitTracePush(self.placeholderTraceFrame());

    // (4) Take the failure exit. Step (2)'s subset rule owns the set
    //     relationship here, so the tag move into the channel bypasses the
    //     implicit value-coercion membership guard.
    const tag_ty = self.builder.getRefType(tag_ref);
    const coerced = if (tag_ty != err_set) self.coerceExplicit(tag_ref, tag_ty, err_set) else tag_ref;
    emitErrorExit(self, exit, coerced);
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
/// error"), so a legal forward re-packs the value slots and carries the source
/// tag word into the destination channel's shape.
/// Legality mirrors `raise`'s subset rule (specs.md "Error sets"): the open
/// bare `!` absorbs any concrete set; a NAMED caller set requires the callee's
/// set ⊆ caller's, each escapee diagnosed.
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
    const tag = self.builder.emit(.{ .struct_get = .{ .base = ref, .field_index = @intCast(dn), .base_type = val_ty } }, src.err);
    const coerced_tag = if (src.err != err_ty) self.coerceExplicit(tag, src.err, err_ty) else tag;
    const tup = self.buildFailableTuple(ret_ty, vals.items, coerced_tag);
    self.emitTupleRet(ret_ty, tup);
}

/// Diagnose a source whose channel is open: it has no static member set, so it
/// cannot be shown ⊆ a named destination.
fn diagNoStaticMemberSet(self: *Lowering, dst_err: TypeId, span: ast.Span) void {
    if (self.diagnostics) |d| {
        const dst_info = self.module.types.get(dst_err);
        d.addFmt(.err, span, "cannot forward a bare-`!` result through the named error set '{s}' — the source channel has no static member set", .{self.module.types.getString(dst_info.error_set.name)});
    }
}

/// The error-set rule for a failable FORWARD (`return callee()` across sets),
/// mirroring `raise`'s: the open bare `!` absorbs any concrete set; a NAMED
/// caller set requires the callee's set ⊆ caller's, each escapee diagnosed
/// while the shape-correct lowering continues (the build aborts via hasErrors).
/// An open source has no static member set, so the pack is aborted.
fn checkForwardSetCompat(self: *Lowering, src_err: TypeId, dst_err: TypeId, span: ast.Span) bool {
    if (src_err == dst_err) return true;
    if (self.channelIsOpen(dst_err)) return true;
    if (self.channelIsOpen(src_err)) {
        diagNoStaticMemberSet(self, dst_err, span);
        return false;
    }
    self.checkErrorSetSubset(src_err, dst_err, span);
    return true;
}

/// The returned value of a PURE failable's `return EXPR;` (`-> !` /
/// `-> !Named`, whose return type IS the error set), coerced for the ret.
/// A pure→pure forward (`return check();`, EXPR's type is another error
/// set) applies the shared set-compat rule, then retypes the tag word into the
/// destination channel. A value-carrying
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
                    return self.builder.constInt(0, ret_ty);
                }
                // `checkForwardSetCompat` is the membership gate, so the
                // coercion skips the implicit preamble's.
                return self.coerceExplicit(ref, val_ty, ret_ty);
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

/// What an attempt (`try`) or an inline fallback (`catch`) consumes. `node` is
/// the failable expression itself, except at a `try { … }`, where it is the
/// boundary block and `boundary` is set.
pub const Attempted = struct { node: *const Node, boundary: bool };

/// The failable a `catch` handles. The nearest fallback wins, so a `try`
/// directly under the handler routes there rather than to the enclosing
/// boundary: `try foo() catch { 0 }` is `foo() catch { 0 }`.
pub fn catchAttempted(ce: *const ast.CatchExpr) Attempted {
    if (ce.operand.data != .try_expr) return .{ .node = ce.operand, .boundary = false };
    const inner = ce.operand.data.try_expr.operand;
    return .{ .node = inner, .boundary = inner.data == .block };
}

/// The channel a `try { … }` block converges to: the flatten-merge of the
/// static channel types of the `try`s and `raise`s that reach it.
fn tryBoundaryChannel(self: *Lowering, block: *const Node) TypeId {
    var tags = std.ArrayList(u32).empty;
    defer tags.deinit(self.alloc);
    var edges = std.ArrayList([]const u8).empty;
    defer edges.deinit(self.alloc);
    var dyn = false;
    self.errorAnalysis().collectBoundaryEscapes(block, &tags, &edges, &dyn, self.current_fn_decl);
    for (edges.items) |callee| {
        for (self.calleeEscapeTags(callee)) |t| {
            if (!containsTag(tags.items, t)) tags.append(self.alloc, t) catch {};
        }
    }
    if (dyn) return self.module.types.dynErrorChannel();
    std.mem.sort(u32, tags.items, {}, std.sort.asc(u32));
    return self.module.types.errorSetType(.empty, tags.items);
}

/// `try { … }` — the block is an error boundary of its own: the `try`s and
/// `raise`s inside exit HERE, not through the enclosing function, and the
/// block's tail is the success value. Yields the block's failable, which the
/// surrounding attempt or fallback then consumes.
fn lowerTryBoundary(self: *Lowering, block: *const Node, span: ast.Span) Ref {
    const chan = tryBoundaryChannel(self, block);
    if (!self.channelIsOpen(chan) and self.module.types.get(chan).error_set.tags.len == 0) {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, span, "`try` on a block needs a body that can fail; this one has no `try` or `raise`", .{});
        }
    }

    const fail_bb = self.freshBlockWithParams("tryblk.fail", &.{chan});
    const saved_boundary = self.error_boundary;
    self.error_boundary = .{ .chan = chan, .fail_bb = fail_bb, .defer_base = self.defer_stack.items.len };
    const saved_terminated = self.block_terminated;
    const tail = self.lowerBlockValue(block);
    self.error_boundary = saved_boundary;
    // Control resumes at the join whatever the block did, so a `raise` at its
    // tail must not make the enclosing body's later statements look dead.
    self.block_terminated = saved_terminated;

    const succ_ty: TypeId = if (self.currentBlockHasTerminator()) .void else if (tail) |t| self.builder.getRefType(t) else .void;
    const ret_ty = if (succ_ty == .void or succ_ty == .noreturn) chan else self.module.types.internFailable(succ_ty, chan);
    const done_bb = self.freshBlockWithParams("tryblk.done", &.{ret_ty});

    if (!self.currentBlockHasTerminator()) {
        const ok = self.builder.constInt(0, chan);
        self.builder.br(done_bb, &.{if (ret_ty == chan) ok else self.buildFailableTuple(ret_ty, &.{tail.?}, ok)});
    }

    self.builder.switchToBlock(fail_bb);
    const tag = self.builder.blockParam(fail_bb, 0, chan);
    const failed = if (ret_ty == chan) tag else self.buildFailableTuple(ret_ty, &.{self.builder.constUndef(succ_ty)}, tag);
    self.builder.br(done_bb, &.{failed});

    self.builder.switchToBlock(done_bb);
    return self.builder.blockParam(done_bb, 0, ret_ty);
}

/// The failable an attempt consumes, evaluated. A `try { … }` boundary is
/// lowered here rather than typed first: its success type is the block's tail,
/// which only the block's own lowering settles. `.none` marks a non-failable
/// operand — the caller diagnoses it and nothing was lowered.
fn lowerAttempt(self: *Lowering, a: Attempted, span: ast.Span) struct { ty: TypeId, ref: Ref } {
    if (a.boundary) {
        const ref = lowerTryBoundary(self, a.node, span);
        return .{ .ty = self.builder.getRefType(ref), .ref = ref };
    }
    const ty = self.inferExprType(a.node);
    if (self.errorChannelOf(ty) == null) return .{ .ty = ty, .ref = .none };
    return .{ .ty = ty, .ref = self.lowerExpr(a.node) };
}

/// Where an error leaving the current position goes: the innermost
/// `try { … }` boundary, else the enclosing function's own channel.
const ErrorExit = struct { set: TypeId, ret_ty: TypeId, boundary: ?Lowering.ErrorBoundary };

/// The current error exit, or null when neither a boundary nor a failable
/// function is in scope.
fn errorExit(self: *Lowering) ?ErrorExit {
    if (self.error_boundary) |b| return .{ .set = b.chan, .ret_ty = b.chan, .boundary = b };
    const ret_ty = self.effectiveReturnType() orelse return null;
    const set = self.errorChannelOf(ret_ty) orelse return null;
    return .{ .set = set, .ret_ty = ret_ty, .boundary = null };
}

/// Leave the current failable body carrying `err`: cleanups, then the
/// boundary's fail edge or the function's failure return.
fn emitErrorExit(self: *Lowering, exit: ErrorExit, err: Ref) void {
    const b = exit.boundary orelse {
        self.emitErrorCleanup(self.func_defer_base, err);
        self.emitErrorReturn(exit.ret_ty, exit.set, err);
        return;
    };
    const ety = self.builder.getRefType(err);
    const coerced = if (ety != b.chan) self.coerceExplicit(err, ety, b.chan) else err;
    self.emitErrorCleanup(b.defer_base, coerced);
    self.builder.br(b.fail_bb, &.{coerced});
}

/// `try X` — a fallible attempt. Evaluates X, then branches on its error tag:
/// the failure path takes the enclosing error exit carrying that tag; the
/// success path continues with X's value — the value part for a value-carrying
/// callee, `void` for a pure-failable one.
pub fn lowerTry(self: *Lowering, operand_in: *const Node, span: ast.Span) Ref {
    // A direct assertion operand (`try av.(T)`) desugars to the failable
    // runtime call and consumes through the ordinary machinery below.
    const operand = self.desugarErasedAssert(operand_in) orelse operand_in;
    const attempted: Attempted = .{ .node = operand, .boundary = operand.data == .block };
    // (1) `try` is legal only where a failure has somewhere to go — a failable
    //     function, or a `try { … }` boundary.
    const exit = errorExit(self) orelse {
        self.diagTryNotFailable(span);
        return self.builder.constInt(0, .void);
    };
    const caller_set = exit.set;

    // (2) The operand must be failable. This is the sole failable-operand
    //     check (the parser imposes none).
    const attempt = lowerAttempt(self, attempted, span);
    const op_ty = attempt.ty;
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

    // (4) Branch on the operand's error tag — the bare result for a pure
    //     callee, the last tuple slot for a value-carrying one.
    const result = attempt.ref;
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
    emitErrorExit(self, exit, err_val);

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
    var attempted = catchAttempted(ce_in);
    // A direct assertion operand (`av.(T) catch …`) desugars to the
    // failable runtime call; the ordinary paths below consume it.
    if (self.desugarErasedAssert(attempted.node)) |dsg| attempted.node = dsg;
    var ce_rewritten = ce_in.*;
    ce_rewritten.operand = @constCast(attempted.node);
    const ce: *const ast.CatchExpr = &ce_rewritten;
    // A failable `??` chain operand (`(try a ?? try b) catch |e| …`) routes
    // its total failure to the catch handler — not the function — via the
    // chain-fail target. A chain's value type is non-failable
    // `T`, so it wouldn't pass the `errorChannelOf` check below.
    if (ce.operand.data == .null_coalesce and
        self.coalesceIsFailable(&ce.operand.data.null_coalesce))
    {
        return self.lowerCatchOverChain(ce, span);
    }

    const attempt = lowerAttempt(self, attempted, span);
    const op_ty = attempt.ty;
    const err_set = self.errorChannelOf(op_ty) orelse {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, span, "`catch` requires a failable expression; operand has type '{s}'", .{self.formatTypeName(op_ty)});
        }
        return self.builder.constInt(0, .void);
    };
    // Pure-failable LHS (`-> !`): no success value. Run the body on the
    // error path; both paths fall through to a value-less merge.
    if (op_ty == err_set) {
        const err_val = attempt.ref;
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
    const result = attempt.ref;
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
/// be ⊆ the caller's named set. An open caller absorbs everything — no check.
/// A dynamic callee has no static member set. A closure/fn-type SLOT widens
/// against the shape-keyed union.
/// Shared by `try` propagation and a failable `??` chain's final operand.
pub fn checkEscapeWidening(self: *Lowering, callee_node: *const Node, callee_set: TypeId, caller_set: TypeId, span: ast.Span) void {
    if (self.channelIsOpen(caller_set)) return;
    if (!self.channelIsOpen(callee_set)) {
        self.checkErrorSetSubset(callee_set, caller_set, span);
        return;
    }
    if (self.channelIsDyn(callee_set)) {
        diagNoStaticMemberSet(self, caller_set, span);
        return;
    }
    // Placeholder callee: a closure/fn-type SLOT, whose set is shape-keyed,
    // shared program-wide by value-signature.
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

/// The `!` node of a return type's error channel: the return type itself
/// (`-> !Set`), or the trailing slot of a failable result list
/// (`-> (T, !Set)`, `-> (A, B, !Set)`). Null for a non-failable return.
pub fn astChannelNode(rt: ?*const Node) ?*const Node {
    const n = rt orelse return null;
    const slots: []const *Node = switch (n.data) {
        .error_type_expr => return n,
        .tuple_type_expr => |t| t.field_types,
        .return_type_expr => |r| r.field_types,
        else => return null,
    };
    if (slots.len == 0) return null;
    const last = slots[slots.len - 1];
    return if (last.data == .error_type_expr) last else null;
}

/// True when a signature's error channel is written bare `!`.
pub fn astChannelIsInferred(rt: ?*const Node) bool {
    const n = astChannelNode(rt) orelse return false;
    return n.data.error_type_expr.operands.len == 0;
}

/// The members a declaration's WRITTEN channel carries. Empty for a bare `!`,
/// whose members are the convergence's result rather than its input. The
/// channel spelling resolves in the declaring module, which is not the ambient
/// one during a whole-program pass.
pub fn declaredChannelTags(self: *Lowering, fd: *const ast.FnDecl) []const u32 {
    const node = astChannelNode(fd.return_type) orelse return &.{};
    const saved = self.current_source_file;
    defer self.setCurrentSourceFile(saved);
    self.setCurrentSourceFile(fd.body.source_file orelse saved);
    const ty = self.resolveType(node);
    if (ty.isBuiltin()) return &.{};
    const info = self.module.types.get(ty);
    return if (info == .error_set) info.error_set.tags else &.{};
}

/// `ret` with its error channel replaced by `chan`.
pub fn withErrorChannel(self: *Lowering, ret: TypeId, chan: TypeId) TypeId {
    if (ret.isBuiltin()) return ret;
    return switch (self.module.types.get(ret)) {
        .error_set => chan,
        .failable => |f| self.module.types.internFailable(f.value, chan),
        else => ret,
    };
}

/// Give a bare-`!` declaration the channel its body converged to: the interned
/// flatten-merge of `members` becomes the declaration's channel TypeId, on the
/// already-declared signature and on every later re-resolution of it.
pub fn materialiseInferredChannel(self: *Lowering, fd: *const ast.FnDecl, name: []const u8, members: []const u32) void {
    installChannel(self, fd, name, self.module.types.errorSetType(.empty, members));
}

/// Give a bare-`!` declaration whose escapes name no static member set the
/// DYNAMIC channel.
pub fn materialiseDynChannel(self: *Lowering, fd: *const ast.FnDecl, name: []const u8) void {
    installChannel(self, fd, name, self.module.types.dynErrorChannel());
}

fn installChannel(self: *Lowering, fd: *const ast.FnDecl, name: []const u8, chan: TypeId) void {
    self.inferred_channels.put(fd, chan) catch return;
    const fid = self.resolveFuncByName(name) orelse return;
    const func = self.module.getFunctionMut(fid);
    func.ret = withErrorChannel(self, func.ret, chan);
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
    if (!self.channelIsPlaceholder(es)) return; // `!Named` → its own set, not the inferred union

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
    // `dyn` is irrelevant to closure-shape widening: a shape node unions tags.
    var dyn_unused = false;
    self.errorAnalysis().collectEscapes(lam.body, &tags, &edges, &dyn_unused, null);
    for (edges.items) |callee| {
        for (self.calleeEscapeTags(callee)) |t| {
            if (!containsTag(tags.items, t)) tags.append(self.alloc, t) catch {};
        }
    }
    self.unionShapeTags(key, tags.items);
}

/// The declaration a `try g()` / `return g()` edge names, seen from the module
/// the edge is WRITTEN in — two imported modules may each author `g`, and the
/// name-keyed winner is not what the spelling means at every site. Null when no
/// single author is visible there.
pub fn edgeCalleeDecl(self: *Lowering, name: []const u8, from: ?[]const u8) ?*const ast.FnDecl {
    if (from) |file| {
        switch (self.selectCallableAuthor(name, file, .any_body)) {
            .func => |f| return f.decl,
            .ambiguous, .not_callable => return null,
            .none => {},
        }
    }
    return self.program_index.fn_ast_map.get(name);
}

/// The escape tags of a callee referenced by name from a `try g()` edge:
/// a bare-`!` callee's converged set, or a named callee's written one.
pub fn calleeEscapeTags(self: *Lowering, callee: []const u8) []const u32 {
    if (self.inferred_error_sets.get(callee)) |t| return t;
    if (edgeCalleeDecl(self, callee, self.current_source_file)) |cfd| return declaredChannelTags(self, cfd);
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
