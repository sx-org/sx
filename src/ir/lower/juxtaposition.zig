//! The juxtaposition front. `expr { … }` is two adjacent expressions; the
//! aggregate reading (`Label { text = "x" }`, `List(Move){}`) and the
//! trailing-block reading (`vstack(12.0) { … }`) share that spelling, so types
//! settle it. One routine, two callers: expression lowering, with the local
//! scope in hand, and the module front over top-level initializers, which the
//! registration passes read structurally before any body lowers.

const std = @import("std");

const ast = @import("../../ast.zig");
const Node = ast.Node;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const lower_generic = @import("generic.zig");

/// Settle every juxtaposition a top-level initializer can hold. Statement
/// bodies stay untouched: their local types are registered as their statements
/// lower, and that is where they settle.
pub fn settleModuleFront(self: *Lowering, decls: []const *const Node) void {
    for (decls) |decl| walkIn(self, decl);
}

/// Settle every juxtaposition in ONE statement's own expressions, before the
/// statement lowers. Every reading of a settled node — the target-type seeding
/// that an assignment's RHS shape decides, the `push` field merge, constant
/// folding — then sees the aggregate or the call, never the undecided pair.
pub fn settleStatement(self: *Lowering, node: *const Node) void {
    walk(self, node);
}

/// Rewrite one juxtaposition into the reading its head's type names.
pub fn settle(self: *Lowering, node: *const Node) void {
    const jx = node.data.juxtaposition;
    const target = @constCast(node);
    target.data = if (constructs(self, jx.expr))
        aggregate(self, node, jx)
    else
        fuse(self, node, jx);
}

/// Whether the head names a type to construct. A call head is one only when it
/// applies a generic type constructor or a `-> Type` function; every other
/// designator shape (bare name, qualified name, type application, variant key)
/// is a type position and reports its own unknown-type diagnostic when the name
/// resolves to nothing.
fn constructs(self: *Lowering, head: *const Node) bool {
    return switch (head.data) {
        .call => |c| namesTemplate(self, c.callee) or
            lower_generic.isGenericTypeConstructorCallNode(self, head) or
            lower_generic.isTypeReturningCallNode(self, head),
        .identifier, .field_access, .enum_literal, .parameterized_type_expr, .type_expr, .tuple_type_expr => true,
        else => false,
    };
}

/// Ask the generic-head selector whether `callee` names a struct template —
/// through the alias chain a `BoxAlias :: Box;` head travels. A probe, so the
/// selector's visibility and ambiguity diagnostics stay with the real head
/// site: a poisoned head still constructs, and reports there.
fn namesTemplate(self: *Lowering, callee: *const Node) bool {
    const saved = self.diagnostics;
    self.diagnostics = null;
    defer self.diagnostics = saved;
    return switch (lower_generic.selectGenericStructCallee(self, callee, null)) {
        .template, .poisoned => true,
        .not_generic => false,
    };
}

/// The name a construction head is WRITTEN with, over the shapes `constructs`
/// accepts. The head of `Box(i64){ … }` is `Box`, of `p.Slot(i64){ … }` is
/// `Slot`.
fn constructionHeadName(head: *const Node) []const u8 {
    return switch (head.data) {
        .identifier => |id| id.name,
        .field_access => |fa| fa.field,
        .enum_literal => |el| el.name,
        .type_expr => |te| te.name,
        .parameterized_type_expr => |pte| pte.name,
        .call => |c| constructionHeadName(c.callee),
        .tuple_type_expr => "this head",
        else => "this head",
    };
}

/// The aggregate reading: the brace group's items are field inits. `name =`
/// names a field, a bare identifier is the shorthand for `name = name`, and
/// anything else is positional.
fn aggregate(self: *Lowering, node: *const Node, jx: ast.Juxtaposition) Node.Data {
    if (jx.has_header) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, node.span, "'{s}' names a type, and a construction takes no parameter header", .{constructionHeadName(jx.expr)});
            d.addHelp(id, null, "a `|…|` header belongs to a block that becomes a closure; parenthesize a closure ELEMENT — `T{ (|x| x), }`", null);
        }
    }
    const stmts = jx.block.data.block.stmts;
    const inits = self.alloc.alloc(ast.StructFieldInit, stmts.len) catch unreachable;
    for (stmts, inits) |stmt, *init| {
        init.* = switch (stmt.data) {
            .assignment => |a| if (a.op == .assign and a.target.data == .identifier)
                .{ .name = a.target.data.identifier.name, .value = a.value }
            else
                .{ .name = null, .value = stmt },
            .identifier => |id| .{ .name = id.name, .value = stmt, .was_shorthand = true },
            else => .{ .name = null, .value = stmt },
        };
    }
    return .{ .struct_literal = .{
        .struct_name = if (jx.expr.data == .identifier) jx.expr.data.identifier.name else null,
        .type_expr = if (jx.expr.data == .identifier) null else jx.expr,
        .field_inits = inits,
        .init_block = jx.init_block,
        .init_block_self = jx.init_block_self,
    } };
}

/// The trailing-block reading: the block becomes a closure literal appended to
/// the head call's arguments, where the mapping pass binds it to the callee's
/// last declared parameter.
fn fuse(self: *Lowering, node: *const Node, jx: ast.Juxtaposition) Node.Data {
    if (jx.expr.data != .call) {
        diagnoseNoBlock(self, node);
        return jx.expr.data;
    }
    if (jx.init_block != null) {
        if (self.diagnostics) |d| {
            const id = d.addId(.err, "a self-trailing '.{ … }' writes into a constructed value; this block fuses onto a call", node.span);
            d.addHelp(id, null, "construct the value first, then attach the block to it", null);
        }
        return jx.expr.data;
    }
    return trailingCall(self, node, jx);
}

/// The call with the block appended as its trailing-block argument.
fn trailingCall(self: *Lowering, node: *const Node, jx: ast.Juxtaposition) Node.Data {
    const c = jx.expr.data.call;
    const lambda = self.alloc.create(Node) catch unreachable;
    lambda.* = .{ .span = jx.block.span, .source_file = node.source_file, .data = .{ .lambda = .{
        .params = jx.params,
        .return_type = null,
        .body = jx.block,
        .type_params = jx.type_params,
        .env = jx.env,
        .has_env = jx.has_env,
    } } };
    if (self.site_index) |idx| idx.adopt(lambda, jx.block);
    const marker = self.alloc.create(Node) catch unreachable;
    marker.* = .{ .span = jx.block.span, .source_file = node.source_file, .data = .{ .trailing_block = .{
        .lambda = lambda,
        .has_header = jx.has_header,
    } } };
    const args = self.alloc.alloc(*Node, c.args.len + 1) catch unreachable;
    @memcpy(args[0..c.args.len], c.args);
    args[c.args.len] = marker;
    return .{ .call = .{ .callee = c.callee, .args = args } };
}

/// A head that is neither a type designator nor a call takes no block at all.
fn diagnoseNoBlock(self: *Lowering, node: *const Node) void {
    const d = self.diagnostics orelse return;
    const id = d.addId(.err, "this expression does not take a block", node.span);
    d.addHelp(id, null, "a block follows a type to construct it, or a call whose last parameter is a `$F/(…) -> R` / `@BuildBlock(P)`", null);
}

/// Pre-order walk over every AST position a MODULE-LEVEL initializer can
/// occupy. The switch is exhaustive on purpose: a new node kind must say where
/// its children are rather than silently hiding an unsettled brace beneath it.
/// A function body is not one of those positions — it stops here.
fn walk(self: *Lowering, node: *const Node) void {
    switch (node.data) {
        .juxtaposition => {
            settle(self, node);
            walk(self, node);
        },
        .root => |r| for (r.decls) |d| walkIn(self, d),
        .namespace_decl => |nd| {
            for (nd.decls) |d| walkIn(self, d);
            for (nd.own_decls) |d| walkIn(self, d);
        },
        .fn_decl => |fd| {
            walkParams(self, fd.params);
            if (fd.return_type) |rt| walk(self, rt);
        },
        .lambda => |l| {
            walkParams(self, l.params);
            if (l.return_type) |rt| walk(self, rt);
        },
        .struct_decl => |sd| {
            for (sd.field_types) |t| walk(self, t);
            for (sd.field_defaults) |dv| if (dv) |v| walk(self, v);
            for (sd.methods) |m| walk(self, m);
            for (sd.constants) |k| walk(self, k);
        },
        .impl_block => |ib| {
            for (ib.methods) |m| walk(self, m);
            for (ib.protocol_type_args) |a| walk(self, a);
            if (ib.target_type_expr) |te| walk(self, te);
        },
        .protocol_decl => |pd| walkProtocolMethods(self, pd.methods),
        .open_set_decl => |sd| {
            walkProtocolMethods(self, sd.methods);
            if (sd.options) |o| walk(self, o);
        },
        .runtime_class_decl => |rcd| for (rcd.members) |m| switch (m) {
            .method => |md| {
                for (md.params) |p| walk(self, p);
                if (md.return_type) |rt| walk(self, rt);
            },
            .field, .extends, .implements => {},
        },
        // A nested statement list settles statement by statement as it lowers,
        // where the locals declared above each one are already registered.
        .block => {},
        .call => |c| {
            walk(self, c.callee);
            for (c.args) |a| walk(self, a);
        },
        .trailing_block => |tb| walk(self, tb.lambda),
        .const_decl => |cd| {
            if (cd.type_annotation) |t| walk(self, t);
            walk(self, cd.value);
        },
        .var_decl => |vd| {
            if (vd.type_annotation) |t| walk(self, t);
            if (vd.value) |v| walk(self, v);
        },
        .destructure_decl => |dd| walk(self, dd.value),
        .binary_op => |o| {
            walk(self, o.lhs);
            walk(self, o.rhs);
        },
        .chained_comparison => |cc| for (cc.operands) |o| walk(self, o),
        .unary_op => |o| walk(self, o.operand),
        .field_access => |fa| walk(self, fa.object),
        .if_expr => |ie| {
            walk(self, ie.condition);
            walk(self, ie.then_branch);
            if (ie.else_branch) |e| walk(self, e);
        },
        .match_expr => |me| {
            walk(self, me.subject);
            for (me.arms) |arm| walkArm(self, arm);
        },
        .match_arm => |arm| walkArm(self, arm),
        .assignment => |a| {
            walk(self, a.target);
            walk(self, a.value);
        },
        .multi_assign => |ma| {
            for (ma.targets) |t| walk(self, t);
            for (ma.values) |v| walk(self, v);
        },
        .enum_decl => |ed| {
            for (ed.variant_types) |t| if (t) |tt| walk(self, tt);
            for (ed.variant_values) |v| if (v) |vv| walk(self, vv);
            if (ed.backing_type) |bt| walk(self, bt);
        },
        .union_decl => |ud| for (ud.field_types) |t| walk(self, t),
        .struct_literal => |sl| {
            if (sl.type_expr) |t| walk(self, t);
            for (sl.field_inits) |fi| walk(self, fi.value);
            if (sl.init_block) |ib| walk(self, ib);
        },
        .tuple_literal => |t| {
            if (t.type_expr) |te| walk(self, te);
            for (t.elements) |e| walk(self, e.value);
        },
        .array_literal => |al| {
            if (al.type_expr) |t| walk(self, t);
            for (al.elements) |e| walk(self, e);
        },
        .param => |p| {
            walk(self, p.type_expr);
            if (p.default_expr) |dv| walk(self, dv);
        },
        .defer_stmt => |ds| walk(self, ds.expr),
        .push_stmt => |ps| {
            walk(self, ps.context_expr);
            walk(self, ps.body);
        },
        .comptime_expr => |ce| walk(self, ce.expr),
        .insert_expr => |ie| walk(self, ie.expr),
        .return_stmt => |rs| if (rs.value) |v| walk(self, v),
        .array_type_expr => |at| {
            walk(self, at.length);
            walk(self, at.element_type);
        },
        .slice_type_expr => |st| walk(self, st.element_type),
        .parameterized_type_expr => |pt| for (pt.args) |a| walk(self, a),
        .index_expr => |ie| {
            walk(self, ie.object);
            walk(self, ie.index);
        },
        .slice_expr => |se| {
            walk(self, se.object);
            if (se.start) |s| walk(self, s);
            if (se.end) |e| walk(self, e);
        },
        .pointer_type_expr => |pt| walk(self, pt.pointee_type),
        .many_pointer_type_expr => |mp| walk(self, mp.element_type),
        .optional_type_expr => |ot| walk(self, ot.inner_type),
        .raise_stmt => |rs| walk(self, rs.tag),
        .try_expr => |te| walk(self, te.operand),
        .catch_expr => |ce| {
            walk(self, ce.operand);
            walk(self, ce.body);
        },
        .force_unwrap => |fu| walk(self, fu.operand),
        .null_coalesce => |nc| {
            walk(self, nc.lhs);
            walk(self, nc.rhs);
        },
        .deref_expr => |de| walk(self, de.operand),
        .postfix_cast => |pc| {
            walk(self, pc.operand);
            walk(self, pc.type_expr);
            if (pc.alloc_arg) |a| walk(self, a);
        },
        .while_expr => |we| {
            walk(self, we.condition);
            walk(self, we.body);
        },
        .for_expr => |fe| {
            for (fe.iterables) |it| {
                walk(self, it.expr);
                if (it.range_end) |e| walk(self, e);
            }
            walk(self, fe.body);
        },
        .spread_expr => |se| walk(self, se.operand),
        .named_arg => |na| walk(self, na.value),
        .type_expr => |te| for (te.protocol_constraints) |pc| walk(self, pc),
        .function_type_expr => |ft| {
            for (ft.param_types) |p| walk(self, p);
            if (ft.return_type) |r| walk(self, r);
        },
        .closure_type_expr => |ct| {
            for (ct.param_types) |p| walk(self, p);
            if (ct.return_type) |r| walk(self, r);
        },
        .tuple_type_expr => |tt| for (tt.field_types) |f| walk(self, f),
        .return_type_expr => |rt| {
            for (rt.field_types) |f| walk(self, f);
            if (rt.field_defaults) |ds| {
                for (ds) |dv| if (dv) |v| walk(self, v);
            }
        },
        .ffi_intrinsic_call => |fi| {
            walk(self, fi.return_type);
            for (fi.args) |a| walk(self, a);
        },
        .jni_env_block => |j| {
            walk(self, j.env);
            walk(self, j.body);
        },
        .asm_expr => |ae| {
            walk(self, ae.template);
            for (ae.operands) |op| walk(self, op.payload);
        },
        .asm_global => |ag| walk(self, ag.template),
        .context_extend_decl => |ce| {
            walk(self, ce.type_expr);
            if (ce.default_expr) |dv| walk(self, dv);
        },

        // Leaves.
        .int_literal,
        .float_literal,
        .bool_literal,
        .string_literal,
        .char_literal,
        .identifier,
        .enum_literal,
        .error_set_decl,
        .error_directive,
        .import_decl,
        .c_import_decl,
        .library_decl,
        .framework_decl,
        .ufcs_alias,
        .error_type_expr,
        .caller_site,
        .pack_index_type_expr,
        .comptime_pack_ref,
        .null_literal,
        .break_expr,
        .continue_expr,
        .undef_literal,
        .inferred_type,
        .intrinsic_expr,
        => {},
    }
}

/// A declaration carrying its own source file walks under that file, so a
/// module's heads resolve where they were written.
fn walkIn(self: *Lowering, node: *const Node) void {
    const saved_source = self.current_source_file;
    defer self.setCurrentSourceFile(saved_source);
    if (node.source_file) |sf| self.setCurrentSourceFile(sf);
    walk(self, node);
}

fn walkParams(self: *Lowering, params: []const ast.Param) void {
    for (params) |p| {
        walk(self, p.type_expr);
        if (p.default_expr) |d| walk(self, d);
    }
}

fn walkProtocolMethods(self: *Lowering, methods: []const ast.ProtocolMethodDecl) void {
    for (methods) |m| {
        for (m.params) |p| walk(self, p);
        if (m.return_type) |rt| walk(self, rt);
    }
}

fn walkArm(self: *Lowering, arm: ast.MatchArm) void {
    if (arm.pattern) |p| walk(self, p);
    walk(self, arm.body);
}
