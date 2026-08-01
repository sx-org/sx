const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const contracts = @import("../../contracts.zig");
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;

const lower = @import("../lower.zig");
const source_site = @import("../../source_site.zig");
const lower_closure = @import("closure.zig");
const lower_init_plan = @import("init_plan.zig");
const Lowering = lower.Lowering;

/// The `@` contract name. It is a BOUND head only: `content: $B/@BuildBlock(P)`.
pub const type_name = contracts.build_block_bound;

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

/// One formation site: what the compiler minted a block implementor FOR. The
/// body belongs to the site rather than to the value, so the value carries only
/// the capture environment and `run` can replay the body wherever it is received.
pub const Site = struct {
    /// The zero-param lambda the trailing block parsed to.
    lambda: *const Node,
    protocol: TypeId,
    /// Where the block was WRITTEN — the file its site reports, which is the
    /// forming caller's, not the accepting function's.
    source_file: ?[]const u8,
    /// Locals the body reads, captured BY REFERENCE (N49): the environment holds
    /// their addresses, so a replay in another frame reads them live and a
    /// second `run` observes a mutation.
    captures: []const lower_closure.CaptureInfo,
    /// The environment struct — one `*T` field per capture.
    env_ty: TypeId,
    indexed: ?source_site.Site,
    line: i32,
    column: i32,
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

/// The `P` of a `@BuildBlock(P)` implementor (or of the formation request), else
/// null. THE single build-block classifier: it answers for both, so every
/// consumer that only needs "is this a block" asks once.
pub fn blockProtocolOf(self: *Lowering, ty: TypeId) ?TypeId {
    if (self.module.types.blockSite(ty)) |site| return self.block_sites.items[site - 1].protocol;
    return self.module.types.buildProtocol(ty);
}

/// The formation site record behind a block implementor type.
pub fn siteRecord(self: *Lowering, ty: TypeId) ?*const Site {
    const site = self.module.types.blockSite(ty) orelse return null;
    return &self.block_sites.items[site - 1];
}

/// The `@BuildBlock(P)` bound written on a binder parameter, as the `P` node.
/// Null for any parameter that is not `name: $B/@BuildBlock(P)`.
///
/// This is THE formation trigger: a parameter accepts a build block by carrying
/// this bound, never by annotating a type (§6.2, §19.3).
pub fn boundProtocolNode(param_type: *const Node) ?*const Node {
    if (param_type.data != .type_expr) return null;
    const te = param_type.data.type_expr;
    if (!te.is_generic) return null;
    for (te.protocol_constraints) |bound| {
        if (bound.data != .parameterized_type_expr) continue;
        const pte = bound.data.parameterized_type_expr;
        if (!std.mem.eql(u8, pte.name, type_name)) continue;
        if (pte.args.len != 1) continue;
        return pte.args[0];
    }
    return null;
}

/// The formation request a `$B/@BuildBlock(P)` parameter resolves to while `$B`
/// is unbound. Argument mapping and argument lowering both key on it.
pub fn formationRequest(self: *Lowering, p: *const ast.Param) ?TypeId {
    const protocol_node = boundProtocolNode(p.type_expr) orelse return null;
    const protocol = self.resolveTypeWithBindings(protocol_node);
    if (protocol == .unresolved) return null;
    return self.module.types.buildBlockType(protocol);
}

/// What a `@BuildBlock`-bounded binder binds to at this argument: the
/// implementor an already-formed block passes through as, or the one formation
/// will mint for the trailing block. Null when `param_type` is not `tp_name`
/// carrying the bound.
pub fn binderType(
    self: *Lowering,
    param_type: *const Node,
    tp_name: []const u8,
    arg: *const Node,
    arg_ty: TypeId,
) ?TypeId {
    if (param_type.data != .type_expr) return null;
    if (!std.mem.eql(u8, param_type.data.type_expr.name, tp_name)) return null;
    const protocol_node = boundProtocolNode(param_type) orelse return null;
    // An argument that is already a block implementor is passed on as itself:
    // the same body, replayed by whoever receives it.
    if (self.module.types.blockSite(arg_ty) != null) return arg_ty;
    const protocol = self.resolveTypeWithBindings(protocol_node);
    if (protocol == .unresolved) return null;
    // Not a block at all: bind the REQUEST so inference completes and argument
    // lowering owns the diagnostic — the parameter is what was misused, and one
    // report of it is enough.
    if (arg.data != .lambda) return self.module.types.buildBlockType(protocol);
    return self.module.types.buildBlockImplementorType(protocol, siteFor(self, arg, protocol));
}

/// The formation site for the trailing block `arg`, minted once per source
/// block: two monomorphizations of one enclosing generic function form at the
/// same site (§4.2).
fn siteFor(self: *Lowering, arg: *const Node, protocol: TypeId) u32 {
    if (self.block_site_ids.get(arg)) |id| return id;
    const src = arg.source_file orelse self.current_source_file;
    const loc = if (self.diagnostics) |d| d.locate(src, arg.span.start) else null;
    const indexed = if (self.site_index) |idx| idx.get(arg) else null;

    // The body's free names, captured by ADDRESS. A binding that is not an
    // alloca has no address of its own, so it is spilled to one — it is an
    // immutable value binding, so nothing can observe the copy.
    var param_names = std.StringHashMap(void).init(self.alloc);
    var captures = std.ArrayList(lower_closure.CaptureInfo).empty;
    self.collectCaptures(arg.data.lambda.body, &param_names, &captures);
    var deduped = std.ArrayList(lower_closure.CaptureInfo).empty;
    for (captures.items) |cap| {
        var seen = false;
        for (deduped.items) |d| {
            if (std.mem.eql(u8, d.name, cap.name)) seen = true;
        }
        if (!seen) deduped.append(self.alloc, cap) catch unreachable;
    }
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    for (deduped.items) |cap| {
        fields.append(self.alloc, .{
            .name = self.module.types.internString(cap.name),
            .ty = self.module.types.ptrTo(cap.ty),
        }) catch unreachable;
    }
    const env_ty = self.module.types.internAnonStruct(fields.toOwnedSlice(self.alloc) catch &.{});

    self.block_sites.append(self.alloc, .{
        .lambda = arg,
        .protocol = protocol,
        .source_file = src,
        .captures = deduped.toOwnedSlice(self.alloc) catch &.{},
        .env_ty = env_ty,
        .indexed = indexed,
        .line = if (loc) |l| @intCast(l.line) else 0,
        .column = if (loc) |l| @intCast(l.col) else 0,
    }) catch unreachable;
    // Site ids are one-based: 0 is the formation request.
    const id: u32 = @intCast(self.block_sites.items.len);
    self.block_site_ids.put(self.alloc, arg, id) catch unreachable;
    return id;
}

/// Form the implementor for the trailing block `arg` at a parameter whose
/// formation request names `protocol` (§6.2 rule 1). The body is NOT lowered
/// here: it belongs to the site, and each `run` replays it. What the value
/// carries is the capture environment — addresses of the forming frame's locals,
/// in a stack struct, so forming allocates nothing (N49).
///
/// An argument that already IS an implementor is passed through unchanged
/// (rule 2), which is how a block is handed down without being re-formed.
pub fn formBlock(self: *Lowering, arg: *const Node, protocol: TypeId) Ref {
    if (self.module.types.blockSite(self.inferExprType(arg)) != null) return self.lowerExpr(arg);
    if (arg.data != .lambda) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, arg.span, "a '@BuildBlock({s})' parameter takes a build block — pass it as a trailing block", .{self.formatTypeName(protocol)});
            d.addHelpFmt(id, arg.span, null, "write the call with a trailing `{{ … }}`, or pass on a block this call already received", .{});
        }
        return Ref.none;
    }
    const site = siteFor(self, arg, protocol);
    const block_ty = self.module.types.buildBlockImplementorType(protocol, site);
    const record = &self.block_sites.items[site - 1];

    const env_ptr = blk: {
        if (record.captures.len == 0) break :blk self.builder.constNull(self.module.types.ptrTo(.void));
        const env = self.builder.alloca(record.env_ty);
        for (record.captures, 0..) |cap, i| {
            const addr = if (cap.is_alloca) cap.ref else spill: {
                const slot = self.builder.alloca(cap.ty);
                self.builder.store(slot, cap.ref);
                break :spill slot;
            };
            const field_ptr = self.builder.structGepTyped(env, @intCast(i), self.module.types.ptrTo(self.module.types.ptrTo(cap.ty)), record.env_ty);
            self.builder.store(field_ptr, addr);
        }
        break :blk env;
    };
    const fields = self.alloc.dupe(Ref, &.{env_ptr}) catch unreachable;
    return self.builder.emit(.{ .struct_init = .{ .fields = fields } }, block_ty);
}

/// `content.run(*sink)` — replay the block body once, with each reached
/// expression handed to `sink.expression` (spec §9). The body lowers HERE, in
/// the RECEIVING function's instruction stream: control flow is ordinary sx
/// control flow, and the block's free names are read through the environment the
/// forming frame handed over, so a replay one call down still reads that frame's
/// locals (N49).
pub fn lowerRun(self: *Lowering, block: *const Node, block_ty: TypeId, args: []const *const Node, span: ast.Span) Ref {
    const record = siteRecord(self, block_ty) orelse return Ref.none;
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
            const id = d.addFmtId(.err, args[0].span, "'run' needs a pointer to the sink, but this is '{s}'", .{self.formatSourceTypeName(sink_ty)});
            d.addHelpFmt(id, args[0].span, null, "take its address with `*` so the sink records into your storage", .{});
        }
        return Ref.none;
    }

    const sink_name = std.fmt.allocPrint(self.alloc, "__build_sink{d}", .{self.build_scopes.items.len}) catch return Ref.none;
    const slot = self.builder.alloca(sink_ty);
    self.builder.store(slot, sink_ref);

    const proto_name = if (self.getProtocolInfo(record.protocol)) |pi| pi.name else self.formatTypeName(record.protocol);
    // A sink that cannot answer a handshake is a static error at `run`, not a
    // per-expression cascade later.
    const pointee = self.module.types.get(sink_ty).pointer.pointee;
    if (!sinkAccepts(self, pointee, record.protocol)) {
        if (self.diagnostics) |d| {
            const shown = self.formatSourceTypeName(pointee);
            const id = d.addFmtId(.err, args[0].span, "'{s}' cannot receive this block: it does not implement '@BuildSink({s})'", .{ shown, proto_name });
            d.addHelpFmt(id, args[0].span, null, "declare `{s} :: (self: *{s}, value: $I/@Init($V/{s}))` on it, or write an 'impl @BuildSink({s}) for {s}'", .{ sink_method, shown, proto_name, proto_name, shown });
        }
        return Ref.none;
    }

    // A sink may take the initializer at the interception type itself — the shape a
    // by-value carrier wants, since the value it writes IS a `P`. A CONSTRAINT `P`
    // has no values for it to write, so the initializer has no target and the sink
    // can only take the member (`$V/P`) the block reached.
    if (fixedInitTarget(self, pointee)) |target| {
        if (self.refuseValuelessProtocol(target, args[0].span, "form an initializer for")) return Ref.none;
    }

    self.build_scopes.append(self.alloc, .{
        .protocol = record.protocol,
        .protocol_name = proto_name,
        .sink_name = sink_name,
        .file = record.source_file,
        .block_offset = record.lambda.span.start,
    }) catch return Ref.none;
    defer _ = self.build_scopes.pop();

    replayBody(self, block, record, sink_name, slot, sink_ty);
    return self.builder.constInt(0, .void);
}

/// Does `sink` accept a block intercepted at `protocol`? THE sink gate: both ways
/// a type can answer live here, so reach and message cannot disagree —
///
///   - the `expression` method declared on the struct itself, or
///   - an `impl @BuildSink(P)`, concrete or blanket, whose method it dispatches.
///
/// A blanket impl is admitted like any other: its method's own binders are
/// substituted at monomorphization, so replay reaches a resolved signature.
pub fn sinkAccepts(self: *Lowering, sink: TypeId, protocol: TypeId) bool {
    if (self.protocolResolver().paramImplKind(contracts_build_sink, &.{protocol}, sink) != .none) return true;
    return sinkDeclaresMethod(self, sink);
}


/// The FIXED target of a sink's `expression` initializer — `$I/@Init(P)` — or null
/// when it takes the open form (`$I/@Init($V/P)`, whose target is the argument's
/// own type and so resolves to nothing here).
fn fixedInitTarget(self: *Lowering, sink: TypeId) ?TypeId {
    const decl = blk: {
        if (self.plain_struct_authors.get(sink)) |author| break :blk author.decl;
        const inst = self.getStructTypeName(sink) orelse return null;
        break :blk self.struct_instance_author.get(inst) orelse return null;
    };
    const method = Lowering.structMethodFn(decl, sink_method) orelse return null;
    if (method.params.len < 2) return null;
    const target_node = lower_init_plan.boundTargetNode(method.params[1].type_expr) orelse return null;
    const target = self.resolveTypeWithBindings(target_node);
    return if (target == .unresolved) null else target;
}

/// Is `expression` declared on the sink's own struct? The method-on-the-struct
/// path, asked of the DECLARATION rather than the flat method namespace: a method
/// an impl block contributed belongs to that impl's protocol, and whether it
/// answers for THIS `P` is the conformance question above.
fn sinkDeclaresMethod(self: *Lowering, sink: TypeId) bool {
    if (self.plain_struct_authors.get(sink)) |author| {
        if (Lowering.structMethodFn(author.decl, sink_method) != null) return true;
    }
    if (self.getStructTypeName(sink)) |inst| {
        if (self.struct_instance_author.get(inst)) |author| {
            if (Lowering.structMethodFn(author, sink_method) != null) return true;
        }
    }
    return false;
}

/// Lower the block's body in the current function, with its captures bound to
/// the addresses the environment carries. The scope has NO parent: the body's
/// free names are exactly its captures, so a same-named local of the receiving
/// function can neither shadow a capture nor be picked up in place of a global.
fn replayBody(
    self: *Lowering,
    block: *const Node,
    record: *const Site,
    sink_name: []const u8,
    sink_slot: Ref,
    sink_ty: TypeId,
) void {
    const saved_scope = self.scope;
    var body_scope = lower.Scope.init(self.alloc, null);
    defer {
        body_scope.deinit();
        self.scope = saved_scope;
    }
    // Function names resolve lexically wherever the body was written; carry the
    // chain the ordinary closure-body lowering carries.
    if (saved_scope) |outer| {
        var s: ?*lower.Scope = outer;
        while (s) |sc| : (s = sc.parent) {
            var it = sc.fn_names.iterator();
            while (it.next()) |e| {
                if (!body_scope.fn_names.contains(e.key_ptr.*)) {
                    body_scope.fn_names.put(e.key_ptr.*, e.value_ptr.*) catch {};
                }
            }
        }
    }
    body_scope.put(sink_name, .{ .ref = sink_slot, .ty = sink_ty, .is_alloca = true });

    if (record.captures.len > 0) {
        const block_ptr = blockValue(self, block);
        const block_struct_ty = self.module.types.get(self.builder.getRefType(block_ptr)).pointer.pointee;
        const ptr_void = self.module.types.ptrTo(.void);
        const env_field = self.builder.structGepTyped(block_ptr, 0, self.module.types.ptrTo(ptr_void), block_struct_ty);
        const env = self.builder.load(env_field, ptr_void);
        for (record.captures, 0..) |cap, i| {
            const field_ptr = self.builder.structGepTyped(env, @intCast(i), self.module.types.ptrTo(self.module.types.ptrTo(cap.ty)), record.env_ty);
            const addr = self.builder.load(field_ptr, self.module.types.ptrTo(cap.ty));
            // Bound as the local itself: reads and writes go straight through
            // the address, which is what "captured by reference" means.
            body_scope.put(cap.name, .{ .ref = addr, .ty = cap.ty, .is_alloca = true });
        }
    }

    self.scope = &body_scope;
    // A name in the body is asked of the file that WROTE the block, not of the
    // function replaying it: a block does not inherit the collector's namespace.
    const saved_file = self.current_source_file;
    defer self.current_source_file = saved_file;
    if (record.source_file) |f| self.current_source_file = f;
    self.lowerBlock(record.lambda.data.lambda.body);
}

/// The block value as an addressable aggregate: `struct_gep` needs a pointer, so
/// a value-shaped receiver is spilled to a slot first.
fn blockValue(self: *Lowering, block: *const Node) Ref {
    const ref = self.lowerExpr(block);
    const ty = self.builder.getRefType(ref);
    if (!ty.isBuiltin() and self.module.types.get(ty) == .pointer) return ref;
    const slot = self.builder.alloca(ty);
    self.builder.store(slot, ref);
    return slot;
}

/// `content.shape()` — side-effect-free static facts about the block (spec §10).
/// Lazy: only computed when this method is referenced. Emits an untyped
/// `@BuildShape{ … }` so the library type supplies the
/// name; planning policy is the library's, never the compiler's.
pub fn lowerShape(self: *Lowering, block_ty: TypeId, args: []const *const Node, span: ast.Span) Ref {
    if (args.len != 0) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'shape' takes no arguments", .{});
        return Ref.none;
    }
    const record = siteRecord(self, block_ty) orelse return Ref.none;
    var facts = ShapeFacts{};
    analyzeShapeBody(self, record.lambda.data.lambda.body, record.protocol, &facts);
    const src = record.source_file orelse self.current_source_file;
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
    if (!publishesAt(self, scope.protocol, scope.protocol_name, v)) return false;

    const src = node.source_file orelse self.current_source_file;
    const recv = self.synthNode(.{ .identifier = .{ .name = scope.sink_name } }, node.span, src);
    const callee = self.synthNode(.{ .field_access = .{ .object = recv, .field = sink_method } }, node.span, src);
    const call_args = self.alloc.dupe(*Node, &.{@constCast(node)}) catch return false;
    scope.ordinal += 1;
    const call = ast.Call{ .callee = callee, .args = call_args };
    // A sink whose conformance comes from a BLANKET impl answers with a method
    // that spells the impl's own binders, so the dispatch carries what the
    // carrier's instantiation bound them to. A sink with the method on itself
    // (or through a concrete impl) needs no seed: name lookup finds it.
    var seed = blanketSeed(self, scope);
    defer if (seed) |*s| s.deinit();
    const saved_seed = self.impl_binder_seed;
    if (seed) |*s| self.impl_binder_seed = s;
    defer self.impl_binder_seed = saved_seed;
    _ = self.lowerCall(&call);
    return true;
}

/// The impl-binder bindings a blanket sink's `expression` must monomorphize
/// with, or null when the sink answers without one.
fn blanketSeed(self: *Lowering, scope: *const Scope) ?std.StringHashMap(TypeId) {
    const binding = if (self.scope) |sc| sc.lookup(scope.sink_name) orelse return null else return null;
    if (binding.ty.isBuiltin()) return null;
    const info = self.module.types.get(binding.ty);
    if (info != .pointer) return null;
    const sink = info.pointer.pointee;
    const found = self.protocolResolver().blanketMethod(contracts_build_sink, &.{scope.protocol}, sink, sink_method) orelse return null;
    return found.bindings;
}

/// Does a statement of type `v` publish to a block intercepting at `protocol`
/// (§6.3 rule 2)? `P` may be ANY type:
///
///   - a PROTOCOL: the statement's type conforms to it — or IS it, which is the
///     identity publish: a value that already is a `P` is written into the
///     sink's slot as itself, with no second formation and no re-erasure.
///   - an OPEN SET: its MEMBERS publish too. A set carries its member inside the
///     slot, so a member statement type-checked at the expected `P` IS a complete
///     `P` value — the same allocator-free formation the expected type performs
///     anywhere else, not a sink-side widening (A1, spec: Open Sets — formation).
///   - anything else: the statement's type IS `P`. Identity only — a type that
///     merely converts to `P` is an ordinary statement, not a child.
fn publishesAt(self: *Lowering, protocol: TypeId, protocol_name: []const u8, v: TypeId) bool {
    if (v == protocol) return true;
    if (self.openSetOf(protocol)) |set| return self.openSetDeclaresMembership(v, set.decl);
    if (self.getProtocolInfo(protocol) == null) return false;
    return self.protocolResolver().packArgConformsTo(protocol_name, v);
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
/// binding, so this resolves to a constant: the site the index recorded for
/// the lambda the trailing block parsed to.
pub fn lowerSite(self: *Lowering, block_ty: TypeId, args: []const *const Node, span: ast.Span) Ref {
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
    const record = siteRecord(self, block_ty) orelse return self.builder.constNull(opt_ty);
    const indexed = record.indexed orelse return self.builder.constNull(opt_ty);
    const value = self.sourceSiteValue(tid, indexed, record.line, record.column);
    return self.builder.emit(.{ .optional_wrap = .{ .operand = value } }, opt_ty);
}

// ── Frame-bound values (§6.2, N49) ─────────────────────────────────────────
// A block implementor holds the ADDRESSES of the forming frame's locals, so it
// is valid exactly as long as that frame. Handing it to a callee is what N45
// rule 2 is for — the callee runs within the call. Everything that would outlive
// the call is refused: a local binding, a closure capture, and a return.

/// Refuse binding a block to a local (`saved := content`). The value would
/// outlive nothing by itself, but a name is what a closure captures and what a
/// later statement can return, so the block stays parameter-shaped.
pub fn rejectBinding(self: *Lowering, value: ?*const Node, name: []const u8, ty: TypeId) bool {
    const val = value orelse return false;
    if (self.module.types.blockSite(ty) == null) return false;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, val.span, "'{s}' cannot bind a '{s}' — a build block is valid only within the call that received it", .{ name, self.formatTypeName(ty) });
        d.addHelpFmt(id, val.span, null, "call '.run(*sink)' here, or pass it to another '@BuildBlock' parameter", .{});
    }
    return true;
}

/// Refuse capturing a block into a closure: the closure may outlive the frame
/// whose locals the block's environment points at.
pub fn rejectCapture(self: *Lowering, ty: TypeId, name: []const u8, span: ast.Span) void {
    if (self.module.types.blockSite(ty) == null) return;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'{s}' is a '{s}' and cannot be captured by a closure", .{ name, self.formatTypeName(ty) });
        d.addHelpFmt(id, span, null, "replay it where it was received ('.run(*sink)'), or collect what you need into storage the closure can reach", .{});
    }
}

/// Refuse returning a block. The value would name a frame that has ended.
pub fn rejectReturn(self: *Lowering, ty: TypeId, span: ast.Span) bool {
    if (self.module.types.blockSite(ty) == null) return false;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "a '{s}' cannot be returned — it is valid only within the call that received it", .{self.formatTypeName(ty)});
        d.addHelpFmt(id, span, null, "run it here and return what the sink collected", .{});
    }
    return true;
}
