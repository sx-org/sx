const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;

const lower = @import("../lower.zig");
const source_site = @import("../../source_site.zig");
const Lowering = lower.Lowering;

/// The compiler-formed `@` type name for a trailing build block.
/// `parseCompilerFormedType` is its only producer.
pub const type_name = "@BuildBlock";

/// Operations a `@BuildBlock(P)` exposes (spec §9–§10).
pub const run_method = "run";
pub const shape_method = "shape";

/// `content.site()` — the block's own source site.
pub const site_method = "site";

/// The method a sink answers a reached expression with (spec §6.3). Resolved on
/// the CONCRETE sink type, so `V` monomorphizes per reached expression and the
/// value stays concrete until the sink itself erases it.
pub const sink_method = "expression";

/// The contract a sink implements.
const contracts_build_sink = "@BuildSink";

/// A `@BuildBlock(P)` parameter bound to the trailing block written at a call
/// site. A build block has no runtime value: what the parameter carries is the
/// block's BODY, as the AST the caller wrote. `run` replays that body into the
/// receiving function, so the block's free names stay the caller's ordinary
/// locals and nothing is captured into compiler-chosen storage (spec §7.6).
pub const Binding = struct {
    /// The zero-param lambda the trailing block parsed to.
    lambda: *const Node,
    protocol: TypeId,
    /// Where the block was WRITTEN — the file its site reports, which is
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
    /// byte offset of its `{`.
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
    // per-expression cascade later. Either the method is on the struct, or the
    // sink conforms to `@BuildSink(P)` through an impl — including a blanket one,
    // which is why this asks the shared conformance query rather than reading
    // the struct's own members only.
    const pointee = self.module.types.get(sink_ty).pointer.pointee;
    const conforms = self.protocolResolver().paramImplExists(
        contracts_build_sink,
        &.{binding.protocol},
        pointee,
    );
    if (!conforms and self.plainStructMethod(sink_ty, sink_method) == null) {
        const sink_name_str = self.formatTypeName(self.module.types.get(sink_ty).pointer.pointee);
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, args[0].span, "'{s}' cannot receive this block: it has no '{s}' method, so it does not implement '@BuildSink({s})'", .{ sink_name_str, sink_method, proto_name });
            d.addHelpFmt(id, args[0].span, null, "declare `{s} :: (self: *{s}, value: @Init($V/{s}))`", .{ sink_method, sink_name_str, proto_name });
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

/// `content.shape()` — side-effect-free static facts about the block (spec §10).
/// Lazy: only computed when this method is referenced. Emits an untyped
/// `@BuildShape{ … }` so the library type supplies the
/// name; planning policy is the library's, never the compiler's.
pub fn lowerShape(self: *Lowering, binding: Binding, args: []const *const Node, span: ast.Span) Ref {
    if (args.len != 0) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'shape' takes no arguments", .{});
        return Ref.none;
    }
    var facts = ShapeFacts{};
    analyzeShapeBody(self, binding.lambda.data.lambda.body, binding.protocol, &facts);
    const src = binding.source_file orelse self.current_source_file;
    return self.lowerExpr(shapeLiteral(self, facts, span, src));
}

const ShapeFacts = struct {
    static_expressions: i32 = 0,
    dynamic_regions: i32 = 0,
    known_bytes: i64 = 0,
    max_alignment: i64 = 1,
    bytes_known: bool = true,
};

fn analyzeShapeBody(self: *Lowering, body: *const Node, protocol: TypeId, facts: *ShapeFacts) void {
    if (body.data != .block) return;
    for (body.data.block.stmts) |stmt| {
        analyzeShapeStmt(self, stmt, protocol, facts);
    }
}

fn analyzeShapeStmt(self: *Lowering, stmt: *const Node, protocol: TypeId, facts: *ShapeFacts) void {
    switch (stmt.data) {
        .if_expr => |ie| {
            if (ie.is_inline) {
                // Inline if contributes selected structure; without a foldable
                // condition both branches are walked (conservative upper bound).
                analyzeShapeStmt(self, ie.then_branch, protocol, facts);
                if (ie.else_branch) |eb| analyzeShapeStmt(self, eb, protocol, facts);
            } else {
                facts.dynamic_regions += 1;
                facts.bytes_known = false;
            }
        },
        .while_expr => {
            facts.dynamic_regions += 1;
            facts.bytes_known = false;
        },
        .for_expr => |fe| {
            if (fe.is_inline) {
                analyzeShapeBody(self, fe.body, protocol, facts);
            } else {
                facts.dynamic_regions += 1;
                facts.bytes_known = false;
            }
        },
        .block => analyzeShapeBody(self, stmt, protocol, facts),
        // Non-expression statements never become reached build values.
        .var_decl, .const_decl, .assignment, .multi_assign, .destructure_decl,
        .return_stmt, .raise_stmt, .break_expr, .continue_expr,
        .defer_stmt, .onfail_stmt, .fn_decl, .struct_decl, .enum_decl, .union_decl,
        .error_set_decl, .protocol_decl, .impl_block, .push_stmt,
        => {},
        else => countStaticExpression(self, stmt, protocol, facts),
    }
}

fn countStaticExpression(self: *Lowering, node: *const Node, protocol: TypeId, facts: *ShapeFacts) void {
    const v = self.inferExprType(node);
    if (v == .unresolved or v == .void or v == .noreturn) return;
    const proto_name = if (self.getProtocolInfo(protocol)) |pi| pi.name else self.formatTypeName(protocol);
    if (!self.protocolResolver().packArgConformsTo(proto_name, v)) return;
    facts.static_expressions += 1;
    if (!facts.bytes_known) return;
    const sz: i64 = @intCast(self.module.types.sizeOf(v));
    const al: i64 = @intCast(self.module.types.typeAlignBytes(v));
    if (al > facts.max_alignment) facts.max_alignment = al;
    // Align then add — same padding a packing sink would need for known rows.
    if (facts.max_alignment > 0) {
        const rem = @mod(facts.known_bytes, facts.max_alignment);
        if (rem != 0) facts.known_bytes += facts.max_alignment - rem;
    }
    facts.known_bytes += sz;
}

fn shapeLiteral(self: *Lowering, facts: ShapeFacts, span: ast.Span, src: ?[]const u8) *Node {
    var fields = std.ArrayList(ast.StructFieldInit).empty;
    self.appendIntField(&fields, "static_expressions", facts.static_expressions, span, src);
    self.appendIntField(&fields, "dynamic_regions", facts.dynamic_regions, span, src);
    if (facts.bytes_known) {
        fields.append(self.alloc, .{
            .name = "known_bytes",
            .value = self.synthNode(.{ .int_literal = .{ .value = facts.known_bytes } }, span, src),
        }) catch {};
    } else {
        fields.append(self.alloc, .{
            .name = "known_bytes",
            .value = self.synthNode(.{ .null_literal = {} }, span, src),
        }) catch {};
    }
    self.appendIntField(&fields, "max_alignment", facts.max_alignment, span, src);
    // Named `@BuildShape{ … }` so `known_bytes: ?i64` resolves against the
    // library declaration rather than an anonymous struct.
    return self.synthNode(.{ .struct_literal = .{
        .struct_name = "@BuildShape",
        .field_inits = fields.toOwnedSlice(self.alloc) catch &.{},
    } }, span, src);
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
    const recv = self.synthNode(.{ .identifier = .{ .name = scope.sink_name } }, node.span, src);
    const callee = self.synthNode(.{ .field_access = .{ .object = recv, .field = sink_method } }, node.span, src);
    const call_args = self.alloc.dupe(*Node, &.{@constCast(node)}) catch return false;
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

/// `content.site()` — the trailing block's own `@SourceSite` (spec §6.2), or
/// null when the block has no indexed site. The block is a compile-time
/// binding, so this resolves to a constant: the site the P3c index recorded for
/// the lambda the trailing block parsed to.
pub fn lowerSite(self: *Lowering, binding: Binding, args: []const *const Node, span: ast.Span) Ref {
    if (args.len != 0) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'{s}' takes no arguments", .{site_method});
        return Ref.none;
    }
    const tid = self.sourceSiteType() orelse {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'{s}' needs '{s}' in scope", .{ site_method, source_site.contract_name });
        return Ref.none;
    };
    const opt_ty = self.module.types.optionalOf(tid);
    const idx = self.site_index orelse return self.builder.constNull(opt_ty);
    const site = idx.get(binding.lambda) orelse return self.builder.constNull(opt_ty);
    const src = binding.source_file orelse self.current_source_file;
    const loc = if (self.diagnostics) |d| d.locate(src, binding.lambda.span.start) else null;
    var fields = [_]Ref{
        self.builder.constString(self.module.types.internString(site.file)),
        self.builder.constString(self.module.types.internString(site.declaration)),
        self.builder.constInt(if (loc) |l| @intCast(l.line) else 0, .i32),
        self.builder.constInt(if (loc) |l| @intCast(l.col) else 0, .i32),
        self.builder.constInt(@bitCast(site.ordinal), .u64),
        self.builder.constInt(@bitCast(site.id), .u64),
    };
    const value = self.builder.emit(.{ .struct_init = .{ .fields = self.alloc.dupe(Ref, &fields) catch unreachable } }, tid);
    return self.builder.emit(.{ .optional_wrap = .{ .operand = value } }, opt_ty);
}

/// Refuse every use of a build block other than `run` / `shape`. A block is a
/// compile-time value with no representation, so there is nothing for a binding,
/// an argument, or a field to hold — and a stored one would replay a body whose
/// locals are gone (spec §7.6).
pub fn rejectValueUse(self: *Lowering, name: []const u8, span: ast.Span) void {
    const binding = lookup(self, name) orelse return;
    if (self.diagnostics) |d| {
        const proto = if (self.getProtocolInfo(binding.protocol)) |pi| pi.name else self.formatTypeName(binding.protocol);
        const id = d.addFmtId(.err, span, "'{s}' is a @BuildBlock({s}) — its only operations are '.{s}(sink)', '.{s}()', and '.{s}()'", .{ name, proto, run_method, shape_method, site_method });
        d.addHelpFmt(id, span, null, "a build block is a compile-time value: it cannot be bound, stored, passed on, or returned", .{});
    }
}
