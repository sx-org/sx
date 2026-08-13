//! The `F(args){}` front. A same-line empty brace body after an
//! argument-carrying call fits both the parameterized aggregate and the
//! trailing block, so the parser parks it in an `empty_brace_call` and this
//! pass rewrites each one into the reading its callee names — once, before any
//! constant folding or body lowering reads the node.

const ast = @import("../../ast.zig");
const Node = ast.Node;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const lower_call = @import("call.zig");
const lower_generic = @import("generic.zig");

/// Resolve every `empty_brace_call` under `decls`.
pub fn normalizeEmptyBraceCalls(self: *Lowering, decls: []const *const Node) void {
    for (decls) |decl| walkIn(self, decl);
}

/// A head that names a generic type constructor or a `-> Type` function
/// constructs; otherwise the block trails where the callee's last parameter
/// takes one. A callee with no declaration here has no constructor reading
/// either, so its block trails and the binder reports what it finds.
fn resolve(self: *Lowering, node: *const Node) void {
    const ebc = node.data.empty_brace_call;
    const target = @constCast(node);
    if (lower_generic.isGenericTypeConstructorCallNode(self, ebc.call) or
        lower_generic.isTypeReturningCallNode(self, ebc.call))
    {
        target.data = .{ .struct_literal = .{
            .struct_name = null,
            .type_expr = ebc.call,
            .field_inits = &.{},
        } };
        return;
    }
    const c = &ebc.call.data.call;
    switch (lower_call.calleeTrailingBlockFit(self, c)) {
        .unknown, .binds => target.data = trailingCall(self, node, ebc),
        // Reported, the block drops — keeping it would stack the binder's own
        // refusal on the one just emitted. Unreported (a scan with diagnostics
        // off), it stays a trailing block, which the binder refuses there.
        .refuses => |param| target.data = if (diagnoseNeither(self, node, c, param))
            ebc.call.data
        else
            trailingCall(self, node, ebc),
    }
}

/// The call with the empty body appended as its trailing-block argument — the
/// shape `f(args) { … }` parses directly.
fn trailingCall(self: *Lowering, node: *const Node, ebc: ast.EmptyBraceCall) Node.Data {
    const c = ebc.call.data.call;
    const lambda = self.alloc.create(Node) catch unreachable;
    lambda.* = .{ .span = ebc.block.span, .source_file = node.source_file, .data = .{ .lambda = .{
        .params = &.{},
        .return_type = null,
        .body = ebc.block,
    } } };
    const marker = self.alloc.create(Node) catch unreachable;
    marker.* = .{ .span = ebc.block.span, .source_file = node.source_file, .data = .{ .trailing_block = .{ .lambda = lambda } } };
    const args = self.alloc.alloc(*Node, c.args.len + 1) catch unreachable;
    @memcpy(args[0..c.args.len], c.args);
    args[c.args.len] = marker;
    return .{ .call = .{ .callee = c.callee, .args = args } };
}

/// Report that neither reading exists, naming both intents. False when this
/// scan carries no diagnostics.
fn diagnoseNeither(
    self: *Lowering,
    node: *const Node,
    c: *const ast.Call,
    param: ?lower_call.RefusedBlockParam,
) bool {
    const d = self.diagnostics orelse return false;
    const callee_name: []const u8 = switch (c.callee.data) {
        .identifier => |id| id.name,
        .field_access => |fa| fa.field,
        .enum_literal => |el| el.name,
        else => "callee",
    };
    if (param) |p| {
        const id = d.addFmtId(.err, node.span, "the empty '{{}}' after '{s}(…)' has no reading — '{s}' names no parameterized type, and its last parameter '{s}' is '{s}', which is neither a `Closure` nor a `@BuildBlock(P)`", .{
            callee_name,
            callee_name,
            p.name,
            self.formatTypeName(p.ty),
        });
        d.addHelpFmt(id, node.span, null, "name a parameterized type to construct one, or declare '{s}' as `Closure()` / `@BuildBlock(P)` to take the block", .{p.name});
    } else {
        const id = d.addFmtId(.err, node.span, "the empty '{{}}' after '{s}(…)' has no reading — '{s}' names no parameterized type and declares no parameter to take a trailing block", .{ callee_name, callee_name });
        d.addHelp(id, null, "name a parameterized type to construct one, or declare a `Closure()` / `@BuildBlock(P)` parameter to take the block", null);
    }
    return true;
}

/// Pre-order walk over every AST position an expression can occupy. The switch
/// is exhaustive on purpose: a new node kind must say where its children are
/// rather than silently hiding an undecided brace beneath it.
fn walk(self: *Lowering, node: *const Node) void {
    switch (node.data) {
        .empty_brace_call => {
            resolve(self, node);
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
            walk(self, fd.body);
        },
        .lambda => |l| {
            walkParams(self, l.params);
            if (l.return_type) |rt| walk(self, rt);
            walk(self, l.body);
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
                if (md.body) |b| walk(self, b);
            },
            .field, .extends, .implements => {},
        },
        .block => |b| for (b.stmts) |s| walk(self, s),
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
        .onfail_stmt => |os| walk(self, os.body),
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
        if (m.default_body) |b| walk(self, b);
    }
}

fn walkArm(self: *Lowering, arm: ast.MatchArm) void {
    if (arm.pattern) |p| walk(self, p);
    walk(self, arm.body);
}
