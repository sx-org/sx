const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;

/// The compiler-formed `@` type name for a trailing build block.
/// `parseCompilerFormedType` is its only producer.
pub const type_name = "@BuildBlock";

/// The one operation a `@BuildBlock(P)` exposes (spec §9).
pub const run_method = "run";

/// The method a sink answers a reached expression with (spec §6.3). Resolved on
/// the CONCRETE sink type, so `V` monomorphizes per reached expression and the
/// value stays concrete until the sink itself erases it.
pub const sink_method = "expression";

/// A `@BuildBlock(P)` parameter bound to the trailing block written at a call
/// site. A build block has no runtime value: what the parameter carries is the
/// block's BODY, as the AST the caller wrote. `run` replays that body into the
/// receiving function, so the block's free names stay the caller's ordinary
/// locals and nothing is captured into compiler-chosen storage (spec §7.6).
pub const Binding = struct {
    /// The zero-param lambda the trailing block parsed to.
    lambda: *const Node,
    protocol: TypeId,
    /// Where the block was WRITTEN — the file a `BuildSite` reports, which is
    /// the caller's, not the accepting function's.
    source_file: ?[]const u8,
};

/// One active replay: pushed by `run`, popped when the block body is done. The
/// stack models §7.2's "nearest active build scope" — a nested block's `run`
/// pushes its own, so its expressions go to its own sink.
pub const Scope = struct {
    protocol: TypeId,
    protocol_name: []const u8,
    /// The synthesized local holding the sink pointer. `run`'s argument is
    /// evaluated ONCE, into this binding; every handshake re-reads it.
    sink_name: []const u8,
    /// The block's own lexical identity — the file it was written in and the
    /// byte offset of its `{`. A `BuildSite.id` derives from this plus the
    /// expression's ordinal, so replaying the same block twice, running under
    /// `-O2`, or instantiating the enclosing generic again all report the same
    /// site.
    file: ?[]const u8,
    block_offset: u32,
    /// Reached-expression counter, restarted per `run` so two replays of one
    /// block agree site for site.
    ordinal: i32 = 0,
};

/// Register a `@BuildBlock(P)` parameter's binding for the accepting call being
/// inlined. Returns false when `param` is not a build block, so the ordinary
/// comptime-parameter path keeps it.
pub fn bindParam(
    self: *Lowering,
    fd: *const ast.FnDecl,
    param: *const ast.Param,
    param_idx: usize,
    arg_node: *const Node,
    out: *std.StringHashMap(Binding),
) bool {
    if (!isBuildBlockParam(param)) return false;
    const pty = self.resolveDeclParamType(fd, param_idx);
    const protocol = self.module.types.buildProtocol(pty) orelse return false;
    // The trailing-block mapping hands over the lambda; an explicitly written
    // argument (`f(spacing, some_value)`) is not a block at all.
    if (arg_node.data != .lambda) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, arg_node.span, "'{s}' takes a build block for '{s}' — pass it as a trailing block", .{ fd.name, param.name });
            d.addHelpFmt(id, arg_node.span, null, "write `{s}(…) {{ … }}`; a {s} is formed from the block body, not from a value", .{ fd.name, self.formatTypeName(pty) });
        }
        return true;
    }
    out.put(param.name, .{
        .lambda = arg_node,
        .protocol = protocol,
        .source_file = arg_node.source_file orelse self.current_source_file,
    }) catch {};
    return true;
}

/// True for a `content: @BuildBlock(P)` parameter declaration.
pub fn isBuildBlockParam(param: *const ast.Param) bool {
    return param.type_expr.data == .parameterized_type_expr and
        std.mem.eql(u8, param.type_expr.data.parameterized_type_expr.name, type_name);
}

/// The binding a name refers to, if it names a build block in the accepting
/// call currently being inlined.
pub fn lookup(self: *Lowering, name: []const u8) ?Binding {
    const m = self.build_block_bindings orelse return null;
    return m.get(name);
}

/// `content.run(*sink)` — replay the block body once, with each reached
/// expression handed to `sink.expression` (spec §9). The body lowers HERE, in
/// the accepting function's instruction stream: control flow is ordinary sx
/// control flow, and the block's captures are the caller's own locals.
pub fn lowerRun(self: *Lowering, binding: Binding, args: []const *const Node, span: ast.Span) Ref {
    if (args.len != 1) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'run' takes exactly one argument — a pointer to the sink that receives this block's expressions", .{});
        return Ref.none;
    }
    const sink_ref = self.lowerExpr(args[0]);
    const sink_ty = self.builder.getRefType(sink_ref);
    // §9.1: the sink is a pointer the sink methods mutate through. Binding a
    // VALUE here would hand every handshake a private copy and silently drop
    // everything the sink recorded.
    if (sink_ty.isBuiltin() or self.module.types.get(sink_ty) != .pointer) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, args[0].span, "'run' needs a pointer to the sink, but this is '{s}'", .{self.formatTypeName(sink_ty)});
            d.addHelpFmt(id, args[0].span, null, "take its address with `*` so the sink records into your storage", .{});
        }
        return Ref.none;
    }

    const scope = self.scope orelse return Ref.none;
    const sink_name = std.fmt.allocPrint(self.alloc, "__build_sink{d}", .{self.build_scopes.items.len}) catch return Ref.none;
    const slot = self.builder.alloca(sink_ty);
    self.builder.store(slot, sink_ref);
    scope.put(sink_name, .{ .ref = slot, .ty = sink_ty, .is_alloca = true });

    const proto_name = if (self.getProtocolInfo(binding.protocol)) |pi| pi.name else self.formatTypeName(binding.protocol);
    // A sink that cannot answer a handshake is a static error at `run`, not a
    // per-expression cascade later.
    if (self.plainStructMethod(sink_ty, sink_method) == null) {
        const sink_name_str = self.formatTypeName(self.module.types.get(sink_ty).pointer.pointee);
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, args[0].span, "'{s}' cannot receive this block: it has no '{s}' method, so it does not implement 'BuildSink({s})'", .{ sink_name_str, sink_method, proto_name });
            d.addHelpFmt(id, args[0].span, null, "declare `{s} :: (self: *{s}, site: BuildSite, value: @Init($V/{s}))`", .{ sink_method, sink_name_str, proto_name });
        }
        return Ref.none;
    }

    self.build_scopes.append(self.alloc, .{
        .protocol = binding.protocol,
        .protocol_name = proto_name,
        .sink_name = sink_name,
        .file = binding.source_file,
        .block_offset = binding.lambda.span.start,
    }) catch return Ref.none;
    defer _ = self.build_scopes.pop();

    self.lowerBlock(binding.lambda.data.lambda.body);
    return self.builder.constInt(0, .void);
}

/// The §7.2 interception rule, applied to one statement. Returns true when the
/// statement WAS a reached build expression and has been handed to the sink;
/// false leaves it to ordinary statement lowering.
///
/// `lowerStmt` has already routed every other statement form to its own arm, so
/// what arrives here is exactly a standalone expression statement — declaration,
/// assignment (`_ = e` included), `return`, and an argument inside a call all
/// belong to their own construct and never reach this path.
pub fn interceptExpression(self: *Lowering, node: *const Node) bool {
    if (self.build_scopes.items.len == 0) return false;
    const scope = &self.build_scopes.items[self.build_scopes.items.len - 1];
    const v = self.inferExprType(node);
    if (v == .unresolved or v == .void or v == .noreturn) return false;
    if (!self.protocolResolver().packArgConformsTo(scope.protocol_name, v)) return false;

    const src = node.source_file orelse self.current_source_file;
    const site = siteLiteral(self, scope, node.span, src);
    const recv = self.synthNode(.{ .identifier = .{ .name = scope.sink_name } }, node.span, src);
    const callee = self.synthNode(.{ .field_access = .{ .object = recv, .field = sink_method } }, node.span, src);
    const call_args = self.alloc.dupe(*Node, &.{ site, @constCast(node) }) catch return false;
    scope.ordinal += 1;
    const call = ast.Call{ .callee = callee, .args = call_args };
    _ = self.lowerCall(&call);
    return true;
}

/// One named `int` field of a synthesized struct literal.
pub fn appendIntField(self: *Lowering, list: *std.ArrayList(ast.StructFieldInit), name: []const u8, value: i64, span: ast.Span, src: ?[]const u8) void {
    list.append(self.alloc, .{
        .name = name,
        .value = self.synthNode(.{ .int_literal = .{ .value = value } }, span, src),
    }) catch {};
}

/// The `BuildSite` for one reached expression (spec §8), written as an untyped
/// `.{ … }` so it types against the sink's own declared `site` parameter — the
/// compiler never has to know the library type by name.
fn siteLiteral(self: *Lowering, scope: *const Scope, span: ast.Span, src: ?[]const u8) *Node {
    var file: []const u8 = src orelse "";
    var line: i64 = 0;
    var column: i64 = 0;
    if (self.diagnostics) |d| {
        const loc = d.locate(src, span.start);
        file = loc.file;
        line = loc.line;
        column = loc.col;
    }
    var fields = std.ArrayList(ast.StructFieldInit).empty;
    self.appendIntField(&fields, "id", siteId(scope), span, src);
    fields.append(self.alloc, .{
        .name = "file",
        .value = self.synthNode(.{ .string_literal = .{ .raw = file, .is_raw = true } }, span, src),
    }) catch {};
    self.appendIntField(&fields, "line", line, span, src);
    self.appendIntField(&fields, "column", column, span, src);
    self.appendIntField(&fields, "ordinal", scope.ordinal, span, src);
    return self.synthNode(.{ .struct_literal = .{
        .struct_name = null,
        .field_inits = fields.toOwnedSlice(self.alloc) catch &.{},
    } }, span, src);
}

/// The stable machine key of a lexical build site (spec §8.1): the block's own
/// identity (file + the offset of its `{`) plus the expression's ordinal within
/// it. It does not vary with replay count, loop iteration, optimization level,
/// or how many times the enclosing generic was instantiated. Masked to 63 bits
/// so the value survives the `i64` literal it is emitted as.
fn siteId(scope: *const Scope) i64 {
    var h = std.hash.Wyhash.init(0);
    h.update(scope.file orelse "");
    h.update(std.mem.asBytes(&scope.block_offset));
    h.update(std.mem.asBytes(&scope.ordinal));
    return @intCast(h.final() & 0x7FFF_FFFF_FFFF_FFFF);
}

/// Refuse every use of a build block other than `run`. A block is a compile-time
/// value with no representation, so there is nothing for a binding, an argument,
/// or a field to hold — and a stored one would replay a body whose locals are
/// gone (spec §7.6).
pub fn rejectValueUse(self: *Lowering, name: []const u8, span: ast.Span) void {
    const binding = lookup(self, name) orelse return;
    if (self.diagnostics) |d| {
        const proto = if (self.getProtocolInfo(binding.protocol)) |pi| pi.name else self.formatTypeName(binding.protocol);
        const id = d.addFmtId(.err, span, "'{s}' is a @BuildBlock({s}) — its only operation is '.{s}(sink)'", .{ name, proto, run_method });
        d.addHelpFmt(id, span, null, "a build block is a compile-time value: it cannot be bound, stored, passed on, or returned", .{});
    }
}
