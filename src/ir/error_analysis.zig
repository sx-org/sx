const std = @import("std");
const ast = @import("../ast.zig");
const lower = @import("lower.zig");
const imports = @import("../imports.zig");

const Node = ast.Node;
const Lowering = lower.Lowering;
const TypeId = @import("types.zig").TypeId;

/// The converged error-analysis facts lowering consumes: each pure-failable
/// function's inferred error-tag set, and each bare-`!` closure SHAPE's
/// inferred set. The backing maps live on `Lowering` (the facade writes
/// `self.l.*`); `facts()` returns a view over them.
pub const ErrorFacts = struct {
    inferred_error_sets: std.AutoHashMap(imports.DeclId, []const u32),
    shape_inferred_sets: std.StringHashMap([]const u32),
};

/// Whole-program error-set convergence. Owns the fix-point traversals that
/// converge inferred `!` error sets (`convergeInferredErrorSets`) and bare-`!` closure-shape sets
/// (`convergeClosureShapeSets`), plus the AST collectors that feed them.
///
/// A `*Lowering` facade (like `CallResolver`/`ProtocolResolver`):
/// it reads the declaration facts + tag registry and writes the
/// `inferred_error_sets` / `shape_inferred_sets` maps that live on
/// `Lowering` (consumers read them there). The per-closure-literal contribution
/// (`recordClosureShape`) + its type/shape helpers stay in `Lowering`; this
/// module calls back for that and reaches its own `collectEscapes` via the
/// facade.
pub const ErrorAnalysis = struct {
    l: *Lowering,
    locals: ?*const LocalScope = null,

    const LocalScope = struct {
        preceding: []const *Node = &.{},
        loop: ?*const ast.ForExpr = null,
        payload: ?struct { name: []const u8, condition: *const Node } = null,
        arm: ?struct { capture: []const u8, pattern: ?*const Node, subject: *const Node } = null,
        parent: ?*const LocalScope,
    };

    pub fn facts(self: ErrorAnalysis) ErrorFacts {
        return .{
            .inferred_error_sets = self.l.inferred_error_sets,
            .shape_inferred_sets = self.l.shape_inferred_sets,
        };
    }

    /// The declaration a callee spelling selects, or null when it selects none.
    fn calleeDecl(self: ErrorAnalysis, callee: *const Node, enclosing_fd: ?*const ast.FnDecl) ?*const ast.FnDecl {
        switch (callee.data) {
            .identifier => |id| return self.l.edgeCalleeDecl(id.name, self.l.current_source_file),
            .field_access => |fa| {
                if (fa.object.data == .identifier) {
                    const obj = fa.object.data.identifier.name;
                    // A namespace- or type-qualified callee is spelled exactly as
                    // its declaration is registered, so it outranks the bare name:
                    // two modules may each author `parse`.
                    if (self.bindingType(enclosing_fd, obj)) |ty| {
                        return self.receiverMethod(ty, fa.field);
                    } else if (self.qualifiedDecl(obj, fa.field)) |q| return q;
                }
                return self.ufcsDecl(fa.field);
            },
            else => return null,
        }
    }

    /// The escape a `try`ed or `return`ed call contributes: an EDGE naming the
    /// callee's declaration, the members of a callable binding's closed
    /// channel, or `dyn` when the callee names neither. A non-failable callee
    /// contributes no member.
    fn contributeCallee(self: ErrorAnalysis, callee: *const Node, enclosing_fd: ?*const ast.FnDecl, tags: *std.ArrayList(u32), edges: *std.ArrayList(*const ast.FnDecl), dyn: *bool) void {
        if (self.calleeDecl(callee, enclosing_fd)) |edge| {
            edges.append(self.l.alloc, edge) catch {};
            return;
        }
        if (callee.data == .identifier) {
            if (self.slotReturn(enclosing_fd, callee.data.identifier.name)) |ret| {
                const channel = self.l.errorChannelOf(ret) orelse return;
                if (!self.l.channelIsOpen(channel)) return self.contributeSet(channel, tags);
            }
        }
        dyn.* = true;
    }

    fn contributeSet(self: ErrorAnalysis, set: TypeId, tags: *std.ArrayList(u32)) void {
        for (self.l.module.types.get(set).@"error".tags) |t| {
            if (!Lowering.containsTag(tags.items, t)) tags.append(self.l.alloc, t) catch {};
        }
    }

    /// Visit the callee of every call `node` hands back with no `return`
    /// keyword. A `while` or `for` body is not that position.
    fn eachTailCallee(self: ErrorAnalysis, node: *const Node, visitor: anytype) void {
        switch (node.data) {
            .block => |b| {
                if (!b.produces_value or b.stmts.len == 0) return;
                const scope = LocalScope{ .preceding = b.stmts[0 .. b.stmts.len - 1], .parent = self.locals };
                var nested = self;
                nested.locals = &scope;
                nested.eachTailCallee(b.stmts[b.stmts.len - 1], visitor);
            },
            .if_expr => |ie| {
                const scope = payloadScope(ie.binding_name, ie.condition, self.locals);
                var nested = self;
                nested.locals = &scope;
                nested.eachTailCallee(ie.then_branch, visitor);
                if (ie.else_branch) |eb| self.eachTailCallee(eb, visitor);
            },
            .match_expr => |me| for (me.arms) |arm| {
                const scope = armScope(arm, me.subject, self.locals);
                var nested = self;
                nested.locals = &scope;
                nested.eachTailCallee(arm.body, visitor);
            },
            .call => |c| visitor.visit(self, c.callee),
            else => {},
        }
    }

    /// The call a failable body hands back with no `return` keyword.
    fn contributeTailCall(self: ErrorAnalysis, node: *const Node, tags: *std.ArrayList(u32), edges: *std.ArrayList(*const ast.FnDecl), dyn: *bool, enclosing_fd: ?*const ast.FnDecl) void {
        var visitor = struct {
            tags: *std.ArrayList(u32),
            edges: *std.ArrayList(*const ast.FnDecl),
            dyn: *bool,
            fd: ?*const ast.FnDecl,
            fn visit(v: *@This(), analysis: ErrorAnalysis, callee: *const Node) void {
                analysis.contributeCallee(callee, v.fd, v.tags, v.edges, v.dyn);
            }
        }{ .tags = tags, .edges = edges, .dyn = dyn, .fd = enclosing_fd };
        self.eachTailCallee(node, &visitor);
    }

    /// Does this `??` operand hand back a failure rather than an optional?
    /// The collect-time reading of `operandIsFailableLike`: this pass runs
    /// before body lowering, so no local carries a type yet.
    fn operandFails(self: ErrorAnalysis, node: *const Node, enclosing_fd: ?*const ast.FnDecl) bool {
        switch (node.data) {
            .try_expr => return true,
            .null_coalesce => |inner| return self.operandFails(inner.lhs, enclosing_fd),
            // A checked assertion is failable by shape; `.(?T)` is the soft
            // form, a plain optional value.
            .postfix_cast => |pc| return pc.type_expr.data != .optional_type_expr,
            else => {},
        }
        var visitor = struct {
            fd: ?*const ast.FnDecl,
            fails: bool,
            fn visit(v: *@This(), analysis: ErrorAnalysis, callee: *const Node) void {
                if (analysis.calleeIsFailable(callee, v.fd)) v.fails = true;
            }
        }{ .fd = enclosing_fd, .fails = false };
        self.eachTailCallee(node, &visitor);
        return visitor.fails;
    }

    /// Does a call through this callee spelling carry an error channel? Read
    /// from what the source WROTE — a lambda's return, the callee
    /// declaration's return, a callable binding's return. A spelling collect
    /// cannot read fails: the extra contribution then routes it through
    /// `contributeCallee`, which marks it `dyn`.
    fn calleeIsFailable(self: ErrorAnalysis, callee: *const Node, enclosing_fd: ?*const ast.FnDecl) bool {
        if (callee.data == .lambda)
            return Lowering.astChannelNode(callee.data.lambda.return_type) != null;
        if (self.calleeDecl(callee, enclosing_fd)) |fd|
            return Lowering.astChannelNode(fd.return_type) != null;
        if (callee.data == .identifier) {
            if (self.slotReturn(enclosing_fd, callee.data.identifier.name)) |ret| return self.l.errorChannelOf(ret) != null;
        }
        return true;
    }

    /// The return of the callable binding `name` selects at the site, or null
    /// when `name` selects none.
    fn slotReturn(self: ErrorAnalysis, fd: ?*const ast.FnDecl, name: []const u8) ?TypeId {
        return self.l.slotReturnType(self.bindingType(fd, name) orelse return null);
    }

    /// The declaration `"<head>.<method>"` names, else null.
    fn qualifiedDecl(self: ErrorAnalysis, head: []const u8, method: []const u8) ?*const ast.FnDecl {
        const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ head, method }) catch return null;
        return self.l.edgeCalleeDecl(qualified, self.l.current_source_file);
    }

    /// The method a call on a `ty` receiver dispatches to. `ty`'s own
    /// declaration answers first: two modules may each declare a `Name`, so
    /// the `Name.method` spelling speaks only for a type with no known author.
    fn receiverMethod(self: ErrorAnalysis, ty: TypeId, method: []const u8) ?*const ast.FnDecl {
        if (self.l.plainStructMethod(ty, method)) |m| return m.fd;
        if (!self.l.hasPlainStructAuthor(ty)) {
            if (self.nominalName(ty)) |name| {
                if (self.qualifiedDecl(name, method)) |fd| return fd;
            }
        }
        return self.ufcsDecl(method);
    }

    fn ufcsDecl(self: ErrorAnalysis, method: []const u8) ?*const ast.FnDecl {
        return self.l.edgeCalleeDecl(self.l.ufcsAliasTarget(method) orelse method, self.l.current_source_file);
    }

    fn nominalName(self: ErrorAnalysis, original: TypeId) ?[]const u8 {
        var ty = original;
        if (ty.isBuiltin()) return null;
        if (self.l.module.types.get(ty) == .pointer) ty = self.l.module.types.get(ty).pointer.pointee;
        if (ty.isBuiltin()) return null;
        return switch (self.l.module.types.get(ty)) {
            .@"struct" => |s| self.l.module.types.getString(s.name),
            else => null,
        };
    }

    // A local initializer sees only preceding declarations, including when
    // it shadows a receiver in an outer scope.
    fn bindingType(self: ErrorAnalysis, fd: ?*const ast.FnDecl, name: []const u8) ?TypeId {
        var scope = self.locals;
        while (scope) |current| : (scope = current.parent) {
            var i = current.preceding.len;
            while (i > 0) {
                i -= 1;
                const node = current.preceding[i];
                const preceding = LocalScope{ .preceding = current.preceding[0..i], .parent = current.parent, .loop = current.loop, .payload = current.payload, .arm = current.arm };
                var initializer = self;
                initializer.locals = &preceding;
                if (node.data == .destructure_decl) {
                    const d = node.data.destructure_decl;
                    for (d.names, 0..) |target, index| {
                        if (!std.mem.eql(u8, target, name)) continue;
                        const ty = initializer.receiverType(fd, d.value);
                        const len = self.l.module.types.productLen(ty) orelse return .unresolved;
                        return if (index < len) self.l.module.types.productFieldType(ty, index) else .unresolved;
                    }
                    continue;
                }
                const binding: struct { name: []const u8, annotation: ?*Node, value: ?*Node } = switch (node.data) {
                    .var_decl => |v| .{ .name = v.name, .annotation = v.type_annotation, .value = v.value },
                    .const_decl => |c| .{ .name = c.name, .annotation = c.type_annotation, .value = @as(?*Node, c.value) },
                    else => continue,
                };
                if (!std.mem.eql(u8, binding.name, name)) continue;
                if (binding.annotation) |annotation| return self.l.resolveType(annotation);
                const value = binding.value orelse return .unresolved;
                return initializer.receiverType(fd, value);
            }
            if (current.payload) |payload| {
                if (std.mem.eql(u8, payload.name, name)) {
                    var outer = self;
                    outer.locals = current.parent;
                    const ty = outer.receiverType(fd, payload.condition);
                    if (!ty.isBuiltin() and self.l.module.types.get(ty) == .optional)
                        return self.l.module.types.get(ty).optional.child;
                    return ty;
                }
            }
            if (current.arm) |arm| {
                if (std.mem.eql(u8, arm.capture, name)) {
                    var outer = self;
                    outer.locals = current.parent;
                    return self.l.matchCaptureType(outer.receiverType(fd, arm.subject), arm.pattern) orelse .unresolved;
                }
            }
            if (current.loop) |loop| {
                for (loop.captures, 0..) |capture, index| {
                    if (!std.mem.eql(u8, capture.name, name)) continue;
                    const iterable = loop.iterables[index];
                    var outer = self;
                    outer.locals = current.parent;
                    const element = if (capture.type_annotation) |annotation|
                        self.l.resolveType(annotation)
                    else if (iterable.is_range)
                        TypeId.i64
                    else
                        outer.iterableElementType(fd, iterable.expr);
                    return if (capture.by_ref) self.l.module.types.ptrTo(element) else element;
                }
            }
        }
        const decl = fd orelse return null;
        for (decl.params) |p| {
            if (std.mem.eql(u8, p.name, name)) return self.l.resolveType(p.type_expr);
        }
        return null;
    }

    fn armScope(arm: ast.MatchArm, subject: *const Node, parent: ?*const LocalScope) LocalScope {
        return .{ .parent = parent, .arm = if (arm.capture) |c| .{ .capture = c, .pattern = arm.pattern, .subject = subject } else null };
    }

    fn payloadScope(name: ?[]const u8, condition: *const Node, parent: ?*const LocalScope) LocalScope {
        return .{ .parent = parent, .payload = if (name) |n| .{ .name = n, .condition = condition } else null };
    }

    fn iterableElementType(self: ErrorAnalysis, fd: ?*const ast.FnDecl, expr: *const Node) TypeId {
        var ty = self.receiverType(fd, expr);
        if (!ty.isBuiltin() and self.l.module.types.get(ty) == .pointer)
            ty = self.l.module.types.get(ty).pointer.pointee;
        if (!ty.isBuiltin() and self.l.module.types.get(ty) == .@"struct") {
            const fields = self.l.module.types.get(ty).@"struct".fields;
            for (fields) |field| {
                if (!std.mem.eql(u8, self.l.module.types.getString(field.name), "items")) continue;
                if (self.l.module.types.sliceInfoOf(field.ty)) |slice| return slice.element;
                if (!field.ty.isBuiltin() and self.l.module.types.get(field.ty) == .many_pointer) {
                    for (fields) |other| {
                        if (std.mem.eql(u8, self.l.module.types.getString(other.name), "len"))
                            return self.l.module.types.get(field.ty).many_pointer.element;
                    }
                }
            }
        }
        return self.l.getElementType(ty);
    }

    fn receiverType(self: ErrorAnalysis, fd: ?*const ast.FnDecl, node: *const Node) TypeId {
        switch (node.data) {
            .identifier => |id| if (self.bindingType(fd, id.name)) |ty| return ty,
            .unary_op => |op| if (op.op == .address_of)
                return self.l.module.types.ptrTo(self.receiverType(fd, op.operand)),
            .call => |call| result: {
                if (call.callee.data != .field_access) break :result;
                const receiver = call.callee.data.field_access.object;
                if (receiver.data != .identifier) break :result;
                const ty = self.bindingType(fd, receiver.data.identifier.name) orelse break :result;
                const callee = self.receiverMethod(ty, call.callee.data.field_access.field) orelse break :result;
                if (callee.type_params.len != 0) break :result;
                const ret = callee.return_type orelse break :result;
                return self.l.resolveTypeInSource(callee.body.source_file, ret);
            },
            .try_expr => |attempt| {
                if (attempt.operand.data == .block) return self.receiverType(fd, attempt.operand);
                return self.successType(fd, attempt.operand);
            },
            .catch_expr => |handler| {
                const attempted = Lowering.catchAttempted(&handler);
                return if (attempted.boundary) self.receiverType(fd, attempted.node) else self.successType(fd, attempted.node);
            },
            .block => |block| {
                if (!block.produces_value or block.stmts.len == 0) return .void;
                const scope = LocalScope{ .preceding = block.stmts[0 .. block.stmts.len - 1], .parent = self.locals };
                var nested = self;
                nested.locals = &scope;
                return nested.receiverType(fd, block.stmts[block.stmts.len - 1]);
            },
            else => {},
        }
        return self.l.inferExprType(node);
    }

    fn successType(self: ErrorAnalysis, fd: ?*const ast.FnDecl, operand: *const Node) TypeId {
        const ty = self.receiverType(fd, operand);
        const channel = self.l.errorChannelOf(ty) orelse return .unresolved;
        return if (ty == channel) .void else self.l.failableSuccessType(ty);
    }

    /// Collect the error TAGS raised + the call EDGES of a function body, for
    /// the inferred-set fix-point. Stops at nested function boundaries.
    pub fn collectErrorSites(self: ErrorAnalysis, node: *const Node, tags: *std.ArrayList(u32), edges: *std.ArrayList(*const ast.FnDecl), dyn: *bool, enclosing_fd: ?*const ast.FnDecl) void {
        switch (node.data) {
            .raise_stmt => |rs| {
                if (self.l.raisedMember(rs.tag)) |rm| {
                    if (rm.set) |set| {
                        // What a qualified member contributes is its STATIC TYPE —
                        // the whole set, not the one member named at the site.
                        self.contributeSet(set, tags);
                    } else {
                        tags.append(self.l.alloc, self.l.anonymousErrorMember(rm.member)) catch {};
                    }
                } else {
                    // A computed tag (`raise e`) names no static set here.
                    dyn.* = true;
                }
                self.collectErrorSites(rs.tag, tags, edges, dyn, enclosing_fd);
            },
            .try_expr => |te| {
                if (te.operand.data == .call) {
                    self.contributeCallee(te.operand.data.call.callee, enclosing_fd, tags, edges, dyn);
                } else if (te.operand.data != .block) {
                    // A `try` on a non-call — a closure / fn-pointer value, a
                    // checked assertion (`av.(T)`) — escapes through a channel
                    // no declaration names. A `try { … }` boundary escapes
                    // through the sites the recursion below collects.
                    dyn.* = true;
                }
                self.collectErrorSites(te.operand, tags, edges, dyn, enclosing_fd);
            },
            .block => |b| {
                for (b.stmts, 0..) |stmt, i| {
                    const scope = LocalScope{ .preceding = b.stmts[0..i], .parent = self.locals };
                    var nested = self;
                    nested.locals = &scope;
                    nested.collectErrorSites(stmt, tags, edges, dyn, enclosing_fd);
                }
            },
            .if_expr => |ie| {
                self.collectErrorSites(ie.condition, tags, edges, dyn, enclosing_fd);
                const scope = payloadScope(ie.binding_name, ie.condition, self.locals);
                var nested = self;
                nested.locals = &scope;
                nested.collectErrorSites(ie.then_branch, tags, edges, dyn, enclosing_fd);
                if (ie.else_branch) |eb| self.collectErrorSites(eb, tags, edges, dyn, enclosing_fd);
            },
            .match_expr => |me| {
                self.collectErrorSites(me.subject, tags, edges, dyn, enclosing_fd);
                for (me.arms) |arm| {
                    const scope = armScope(arm, me.subject, self.locals);
                    var nested = self;
                    nested.locals = &scope;
                    nested.collectErrorSites(arm.body, tags, edges, dyn, enclosing_fd);
                }
            },
            .while_expr => |w| {
                self.collectErrorSites(w.condition, tags, edges, dyn, enclosing_fd);
                const scope = payloadScope(w.binding_name, w.condition, self.locals);
                var nested = self;
                nested.locals = &scope;
                nested.collectErrorSites(w.body, tags, edges, dyn, enclosing_fd);
            },
            .for_expr => |f| {
                for (f.iterables) |it| {
                    self.collectErrorSites(it.expr, tags, edges, dyn, enclosing_fd);
                    if (it.range_end) |re| self.collectErrorSites(re, tags, edges, dyn, enclosing_fd);
                }
                const scope = LocalScope{ .loop = &f, .parent = self.locals };
                var nested = self;
                nested.locals = &scope;
                nested.collectErrorSites(f.body, tags, edges, dyn, enclosing_fd);
            },
            .return_stmt => |r| if (r.value) |v| {
                // `return callee(...)` FORWARDS the callee's error channel, so
                // it contributes the callee's set exactly like a `try` edge.
                if (v.data == .call) self.contributeCallee(v.data.call.callee, enclosing_fd, tags, edges, dyn);
                self.collectErrorSites(v, tags, edges, dyn, enclosing_fd);
            },
            .var_decl => |v| if (v.value) |val| self.collectErrorSites(val, tags, edges, dyn, enclosing_fd),
            .const_decl => |c| self.collectErrorSites(c.value, tags, edges, dyn, enclosing_fd),
            .destructure_decl => |d| self.collectErrorSites(d.value, tags, edges, dyn, enclosing_fd),
            .assignment => |a| {
                self.collectErrorSites(a.target, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(a.value, tags, edges, dyn, enclosing_fd);
            },
            .multi_assign => |m| {
                for (m.targets) |t| self.collectErrorSites(t, tags, edges, dyn, enclosing_fd);
                for (m.values) |v| self.collectErrorSites(v, tags, edges, dyn, enclosing_fd);
            },
            .call => |c| {
                self.collectErrorSites(c.callee, tags, edges, dyn, enclosing_fd);
                for (c.args) |a| self.collectErrorSites(a, tags, edges, dyn, enclosing_fd);
            },
            .binary_op => |b| {
                self.collectErrorSites(b.lhs, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(b.rhs, tags, edges, dyn, enclosing_fd);
            },
            .unary_op => |u| self.collectErrorSites(u.operand, tags, edges, dyn, enclosing_fd),
            .deref_expr => |d| self.collectErrorSites(d.operand, tags, edges, dyn, enclosing_fd),
            .force_unwrap => |fu| self.collectErrorSites(fu.operand, tags, edges, dyn, enclosing_fd),
            .null_coalesce => |nc| self.collectCoalesce(&nc, tags, edges, dyn, enclosing_fd, false),
            .field_access => |fa| self.collectErrorSites(fa.object, tags, edges, dyn, enclosing_fd),
            .index_expr => |ix| {
                self.collectErrorSites(ix.object, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(ix.index, tags, edges, dyn, enclosing_fd);
            },
            .spread_expr => |s| self.collectErrorSites(s.operand, tags, edges, dyn, enclosing_fd),
            // The handler body's own escapes forward; what the fallback
            // attempts is absorbed.
            .catch_expr => |ce| {
                self.collectAbsorbed(ce.operand, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(ce.body, tags, edges, dyn, enclosing_fd);
            },
            .defer_stmt => |d| self.collectErrorSites(d.expr, tags, edges, dyn, enclosing_fd),
            .push_stmt => |p| {
                self.collectErrorSites(p.context_expr, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(p.body, tags, edges, dyn, enclosing_fd);
            },
            .array_literal => |al| for (al.elements) |el| self.collectErrorSites(el, tags, edges, dyn, enclosing_fd),
            .tuple_literal => |tl| for (tl.elements) |el| self.collectErrorSites(el.value, tags, edges, dyn, enclosing_fd),
            // Stop at nested function boundaries; leaves contribute nothing.
            else => {},
        }
    }

    /// A `??` chain routes each operand's failure to the operand that follows,
    /// so every operand but the last is absorbed. The last one propagates,
    /// unless `absorbed` — a `catch` over the chain takes its total failure.
    fn collectCoalesce(self: ErrorAnalysis, nc: *const ast.NullCoalesce, tags: *std.ArrayList(u32), edges: *std.ArrayList(*const ast.FnDecl), dyn: *bool, enclosing_fd: ?*const ast.FnDecl, absorbed: bool) void {
        self.collectAbsorbed(nc.lhs, tags, edges, dyn, enclosing_fd);
        // `??` is right-associative, so the chain continues down the rhs.
        if (nc.rhs.data == .null_coalesce) {
            self.collectCoalesce(&nc.rhs.data.null_coalesce, tags, edges, dyn, enclosing_fd, absorbed);
            return;
        }
        if (absorbed) {
            self.collectAbsorbed(nc.rhs, tags, edges, dyn, enclosing_fd);
            return;
        }
        self.collectErrorSites(nc.rhs, tags, edges, dyn, enclosing_fd);
        // The last operand of a chain that routes failure is a tail: its calls
        // escape with or without a `try` marker. An optional `??` routes no
        // failure, and a value terminator ends the chain, so neither adds one.
        if (self.operandFails(nc.lhs, enclosing_fd) and self.operandFails(nc.rhs, enclosing_fd))
            self.contributeTailCall(nc.rhs, tags, edges, dyn, enclosing_fd);
    }

    /// An operand whose failure a fallback absorbs: its own attempt goes
    /// nowhere, while a `try` nested inside it re-raises before the fallback
    /// runs and still escapes. A `try { … }` boundary owns every escape
    /// inside it.
    fn collectAbsorbed(self: ErrorAnalysis, node: *const Node, tags: *std.ArrayList(u32), edges: *std.ArrayList(*const ast.FnDecl), dyn: *bool, enclosing_fd: ?*const ast.FnDecl) void {
        switch (node.data) {
            .null_coalesce => |nc| self.collectCoalesce(&nc, tags, edges, dyn, enclosing_fd, true),
            .try_expr => |te| if (te.operand.data != .block) self.collectAbsorbed(te.operand, tags, edges, dyn, enclosing_fd),
            else => self.collectErrorSites(node, tags, edges, dyn, enclosing_fd),
        }
    }

    /// Every escape of a failable `body`: the tags it raises and the edges of
    /// the calls whose failure leaves it.
    pub fn collectEscapes(self: ErrorAnalysis, body: *const Node, tags: *std.ArrayList(u32), edges: *std.ArrayList(*const ast.FnDecl), dyn: *bool, enclosing_fd: ?*const ast.FnDecl) void {
        self.collectErrorSites(body, tags, edges, dyn, enclosing_fd);
        self.contributeTailCall(body, tags, edges, dyn, enclosing_fd);
    }

    /// Whole-program fix-point that converges each bare-`!` function's inferred
    /// error set — `-> !` and value-carrying `-> (T..., !)` alike — and
    /// materialises the converged set as that declaration's channel TypeId.
    /// Runs after `scanDecls` (ASTs + named error sets registered) and before
    /// body lowering, so every later check reads the materialised channel. Also
    /// emits the empty-inferred warning.
    pub fn convergeInferredErrorSets(self: ErrorAnalysis) void {
        const Node_ = struct {
            fd: *const ast.FnDecl,
            /// The smallest name that selects this declaration — the spelling
            /// the empty-inferred warning names it by.
            name: []const u8,
            tags: std.ArrayList(u32),
            edges: std.ArrayList(*const ast.FnDecl),
            rt: ?*const Node,
            // Module the function is written in. `rt.span` is an offset into
            // THAT file, and this whole-program pass runs with whatever
            // ambient source file the previous phase left behind.
            source_file: ?[]const u8,
            // The body escapes through a channel that cannot be named (a `try`
            // of a closure value or a checked assertion, a `raise` of a
            // computed tag, a call whose callee names neither a declaration
            // nor a closed channel), so it genuinely propagates a dynamic
            // error even when no concrete tag converges. Suppresses the
            // empty-set "drop the `!`" warning, and makes the channel the
            // DYNAMIC one: a merge over a channel nobody can name is not the
            // set the body escapes.
            dyn: bool,
            // `main`'s `!` is the program's top error channel, and a
            // protocol-impl method's `!` is dictated by the contract — e.g.
            // `Io.suspendRaw` — so a non-raising body is not a "drop the `!`"
            // case for either.
            suppress_empty_warning: bool,
        };
        var work = std.AutoHashMap(imports.DeclId, Node_).init(self.l.alloc);
        defer work.deinit();

        // Seed each bare-`!` declaration with its direct escape sites. Several
        // names may select one declaration (a bare and a namespace-qualified
        // spelling); it converges once, under the smallest of them so the
        // diagnostics below read the same on every run.
        {
            const saved = self.l.current_source_file;
            defer self.l.setCurrentSourceFile(saved);
            var it = self.l.program_index.iterator(.function);
            while (it.next()) |e| {
                const fd = e.value;
                if (!Lowering.astChannelIsInferred(fd.return_type)) continue;
                const suppressed = std.mem.eql(u8, e.name, "main") or self.l.impl_method_names.contains(e.name);
                const id = self.l.declId(.{ .fn_decl = fd }, fd.body.source_file);
                if (work.getPtr(id)) |seen| {
                    if (std.mem.lessThan(u8, e.name, seen.name)) seen.name = e.name;
                    seen.suppress_empty_warning = seen.suppress_empty_warning or suppressed;
                    continue;
                }
                var tags = std.ArrayList(u32).empty;
                var edges = std.ArrayList(*const ast.FnDecl).empty;
                var dyn = false;
                self.l.setCurrentSourceFile(fd.body.source_file orelse saved);
                self.collectEscapes(fd.body, &tags, &edges, &dyn, fd);
                work.put(id, .{
                    .fd = fd,
                    .name = e.name,
                    .tags = tags,
                    .edges = edges,
                    .rt = fd.return_type,
                    .source_file = fd.body.source_file,
                    .dyn = dyn,
                    .suppress_empty_warning = suppressed,
                }) catch {};
            }
        }

        // Union edge contributions until no set grows (monotone → terminates).
        var changed = true;
        while (changed) {
            changed = false;
            var wit = work.iterator();
            while (wit.next()) |we| {
                for (we.value_ptr.edges.items) |callee_fd| {
                    const callee_tags: []const u32 = blk: {
                        const callee_id = self.l.declId(.{ .fn_decl = callee_fd }, callee_fd.body.source_file);
                        if (work.getPtr(callee_id)) |cc| {
                            // A callee whose merge is non-static makes this
                            // node's merge non-static.
                            if (cc.dyn and !we.value_ptr.dyn) {
                                we.value_ptr.dyn = true;
                                changed = true;
                            }
                            break :blk cc.tags.items;
                        }
                        break :blk self.l.declaredChannelTags(callee_fd);
                    };
                    for (callee_tags) |t| {
                        if (!Lowering.containsTag(we.value_ptr.tags.items, t)) {
                            we.value_ptr.tags.append(self.l.alloc, t) catch {};
                            changed = true;
                        }
                    }
                }
            }
        }

        // Store the converged sets (sorted), materialise them, and warn on
        // empty inferred sets. Hash order is not source order — order by the
        // return-type span so the diagnostics read top-to-bottom and stay
        // identical across implementations.
        const Entry = struct { id: imports.DeclId, node: *const Node_ };
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(self.l.alloc);
        var sit = work.iterator();
        while (sit.next()) |se| {
            entries.append(self.l.alloc, .{ .id = se.key_ptr.*, .node = se.value_ptr }) catch {};
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                // A function with no return-type node never warns; order it by
                // name so the sort stays total regardless.
                const a_start: u32 = if (a.node.rt) |rt| rt.span.start else std.math.maxInt(u32);
                const b_start: u32 = if (b.node.rt) |rt| rt.span.start else std.math.maxInt(u32);
                if (a_start != b_start) return a_start < b_start;
                return std.mem.lessThan(u8, a.node.name, b.node.name);
            }
        }.lessThan);

        const saved_file = self.l.current_source_file;
        defer self.l.setCurrentSourceFile(saved_file);

        for (entries.items) |se| {
            const sorted = self.l.alloc.dupe(u32, se.node.tags.items) catch continue;
            std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
            self.l.inferred_error_sets.put(se.id, sorted) catch {};
            if (se.node.dyn) self.l.materialiseDynChannel(se.node.fd) else self.l.materialiseInferredChannel(se.node.fd, sorted);
            const whole_return_is_channel = Lowering.astChannelNode(se.node.rt) == se.node.rt;
            if (sorted.len == 0 and whole_return_is_channel and !se.node.dyn and !se.node.suppress_empty_warning) {
                if (self.l.diagnostics) |diags| {
                    if (se.node.rt) |rt| {
                        self.l.setCurrentSourceFile(se.node.source_file orelse saved_file);
                        diags.addFmt(.warn, rt.span, "function '{s}' is declared `!` but never errors — drop the `!`", .{se.node.name});
                    }
                }
            }
        }
    }

    /// Whole-program union of each bare-`!` closure/fn-type SHAPE's escape set
    /// Walks every function body for closure literals;
    /// each bare-`!` failable literal contributes its raises (+ `try named_fn()`
    /// edges, resolved against their declarations' converged sets) to the node shared
    /// by all occurrences of its value-signature shape. A `try slot(x)` against
    /// any matching-shape slot then widens against this union.
    pub fn convergeClosureShapeSets(self: ErrorAnalysis) void {
        // Pin the visibility context to each fn's DEFINING module
        // (body.source_file, stamped by resolveImports) — a closure literal's
        // param/return annotations must resolve where the fn is written, not
        // against whatever module the previous pipeline phase happened to
        // leave as the ambient context.
        const saved = self.l.current_source_file;
        defer self.l.setCurrentSourceFile(saved);
        var it = self.l.program_index.iterator(.function);
        while (it.next()) |e| {
            self.l.setCurrentSourceFile(e.value.body.source_file orelse saved);
            self.collectClosureShapes(e.value.body);
        }
    }

    /// Recurse the AST collecting closure-literal shape contributions. Unlike
    /// `collectErrorSites`, this descends THROUGH lambda boundaries (a nested
    /// closure is its own shape, and may itself contain closures). The
    /// per-literal recording (`recordClosureShape`) stays in `Lowering`.
    fn collectClosureShapes(self: ErrorAnalysis, node: *const Node) void {
        switch (node.data) {
            .lambda => |lam| {
                self.l.recordClosureShape(&lam);
                self.collectClosureShapes(lam.body);
            },
            .block => |b| for (b.stmts) |s| self.collectClosureShapes(s),
            .if_expr => |ie| {
                self.collectClosureShapes(ie.condition);
                self.collectClosureShapes(ie.then_branch);
                if (ie.else_branch) |eb| self.collectClosureShapes(eb);
            },
            .while_expr => |w| {
                self.collectClosureShapes(w.condition);
                self.collectClosureShapes(w.body);
            },
            .for_expr => |f| {
                for (f.iterables) |it| {
                    self.collectClosureShapes(it.expr);
                    if (it.range_end) |re| self.collectClosureShapes(re);
                }
                self.collectClosureShapes(f.body);
            },
            .return_stmt => |r| if (r.value) |v| self.collectClosureShapes(v),
            .raise_stmt => |rs| self.collectClosureShapes(rs.tag),
            .var_decl => |v| if (v.value) |val| self.collectClosureShapes(val),
            .const_decl => |c| self.collectClosureShapes(c.value),
            .destructure_decl => |d| self.collectClosureShapes(d.value),
            .assignment => |a| {
                self.collectClosureShapes(a.target);
                self.collectClosureShapes(a.value);
            },
            .multi_assign => |m| {
                for (m.targets) |t| self.collectClosureShapes(t);
                for (m.values) |v| self.collectClosureShapes(v);
            },
            .call => |c| {
                self.collectClosureShapes(c.callee);
                for (c.args) |a| self.collectClosureShapes(a);
            },
            .binary_op => |b| {
                self.collectClosureShapes(b.lhs);
                self.collectClosureShapes(b.rhs);
            },
            .unary_op => |u| self.collectClosureShapes(u.operand),
            .deref_expr => |d| self.collectClosureShapes(d.operand),
            .force_unwrap => |fu| self.collectClosureShapes(fu.operand),
            .null_coalesce => |nc| {
                self.collectClosureShapes(nc.lhs);
                self.collectClosureShapes(nc.rhs);
            },
            .field_access => |fa| self.collectClosureShapes(fa.object),
            .index_expr => |ix| {
                self.collectClosureShapes(ix.object);
                self.collectClosureShapes(ix.index);
            },
            .spread_expr => |s| self.collectClosureShapes(s.operand),
            .try_expr => |te| self.collectClosureShapes(te.operand),
            .catch_expr => |ce| {
                self.collectClosureShapes(ce.operand);
                self.collectClosureShapes(ce.body);
            },
            .defer_stmt => |d| self.collectClosureShapes(d.expr),
            .push_stmt => |p| {
                self.collectClosureShapes(p.context_expr);
                self.collectClosureShapes(p.body);
            },
            .array_literal => |al| for (al.elements) |el| self.collectClosureShapes(el),
            .tuple_literal => |tl| for (tl.elements) |el| self.collectClosureShapes(el.value),
            else => {},
        }
    }
};
