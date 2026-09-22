const std = @import("std");
const imports = @import("imports.zig");
const ast = @import("ast.zig");

pub const Declaration = struct {
    table: *const imports.DeclTable,
    id: imports.DeclId,

    pub fn info(self: Declaration) imports.DeclInfo {
        return self.table.get(self.id);
    }
};

pub const Order = struct {
    source: []const u8,
    position: u32,
};

pub const Context = struct {
    table: *const imports.DeclTable,
    environment: imports.EnvironmentId,
    block: ?imports.LexicalBlockId = null,
    order: ?Order = null,

    pub fn source(self: Context) []const u8 {
        return self.table.environment(self.environment).source;
    }

    pub fn root(self: Context) Context {
        return .{ .table = self.table, .environment = self.table.fileEnvironment(self.source()).? };
    }

    pub fn author(decl: Declaration) ?Context {
        const info = decl.info();
        var result = Context{ .table = decl.table, .environment = info.environment orelse return null, .block = info.lexical_block };
        if (info.node) |node| if (decl.table.written_targets.get(node)) |written| {
            result.order = .{ .source = written.source, .position = written.position };
        };
        return result;
    }
};

pub const ScopeView = struct {
    path: []const []const u8,
    context: Context,
    pinned: bool = false,
};

pub const Qualifier = union(enum) {
    namespace: Context,
    scope: ScopeView,
};

pub const Selected = struct {
    declaration: Declaration,
    view: Context,
    pinned_view: bool = false,
};

pub const Selection = union(enum) {
    missing,
    ambiguous,
    selected: Selected,
};

pub const SpreadTarget = union(enum) {
    missing,
    ambiguous,
    not_namespace,
    target: Qualifier,
    c_import: []const imports.DeclId,

    pub fn diagnostic(self: SpreadTarget) ?[]const u8 {
        return switch (self) {
            .missing => "spread target is not declared",
            .ambiguous => "spread target is ambiguous",
            .not_namespace => "spread target is not a scope or namespace",
            .target, .c_import => null,
        };
    }
};

/// Undecided contributions are queried without publishing them into lexical environments.
pub const Contributions = struct {
    declarations: []const Declaration,
    spreads: []const *const ast.Node,
    imports: []const Import,

    pub const Import = struct {
        context: Context,
        target: Context,
    };
};

pub const Candidates = struct {
    own: ?Selected = null,
    imported: []const Selected = &.{},

    pub fn found(self: Candidates) bool {
        return self.own != null or self.imported.len != 0;
    }
};

pub fn own(context: Context, name: []const u8, requester: []const u8) ?Declaration {
    const id = context.table.environment(context.environment).names.get(name) orelse return null;
    const decl = Declaration{ .table = context.table, .id = id };
    if (decl.info().visibility == .private and !std.mem.eql(u8, decl.info().source.?, requester)) return null;
    return decl;
}

pub fn parent(context: Context) ?Context {
    if (context.block) |id| {
        const enclosing = context.table.block(id).parent orelse return null;
        return .{ .table = context.table, .environment = context.table.block(enclosing).environment, .block = enclosing, .order = context.order };
    }
    const path = context.table.environment(context.environment).scope_path;
    if (path.len == 0) return null;
    return .{ .table = context.table, .environment = context.table.findEnvironment(context.source(), path[0 .. path.len - 1]).?, .order = context.order };
}

fn samePath(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn sameContext(a: Context, b: Context) bool {
    return a.table == b.table and a.environment == b.environment and a.block == b.block and std.meta.eql(a.order, b.order);
}

fn sameQualifier(a: Qualifier, b: Qualifier) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .namespace => |ctx| sameContext(ctx, b.namespace),
        .scope => |scope| samePath(scope.path, b.scope.path) and sameContext(scope.context, b.scope.context) and scope.pinned == b.scope.pinned,
    };
}

pub fn Query(comptime Backend: type) type {
    return struct {
        backend: Backend,
        contributions: ?Contributions = null,
        alloc: std.mem.Allocator,
        surfaces: std.ArrayList(Surface) = .empty,
        targets: std.ArrayList(*const ast.Node) = .empty,
        aliases: std.ArrayList(Declaration) = .empty,
        carriers: std.ArrayList(Carrier) = .empty,

        const Self = @This();
        const Error = std.mem.Allocator.Error;
        const Surface = struct { target: Qualifier, name: []const u8 };
        const Carrier = struct { context: Context, path: []const []const u8 };

        pub fn init(backend: Backend, alloc: std.mem.Allocator) Self {
            return .{ .backend = backend, .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            self.surfaces.deinit(self.alloc);
            self.targets.deinit(self.alloc);
            self.aliases.deinit(self.alloc);
            self.carriers.deinit(self.alloc);
        }

        fn local(self: *Self, context: Context, name: []const u8, requester: []const u8) Error!Candidates {
            if (own(context, name, requester)) |decl| return .{ .own = .{ .declaration = decl, .view = context } };
            var result: std.ArrayList(Selected) = .empty;
            errdefer result.deinit(self.alloc);
            if (self.contributions) |pending| for (pending.declarations) |decl| {
                const info = decl.info();
                if (decl.table != context.table or info.environment != context.environment or !std.mem.eql(u8, info.name, name)) continue;
                if (info.visibility == .private and !std.mem.eql(u8, info.source.?, requester)) continue;
                try result.append(self.alloc, .{ .declaration = decl, .view = context });
            };
            return .{ .imported = try result.toOwnedSlice(self.alloc) };
        }

        fn plainImports(self: *Self, context: Context, files: *std.ArrayList(Context)) Error!void {
            try self.backend.plainImports(context, files);
            if (self.contributions) |pending| for (pending.imports) |imp| {
                if (imp.context.table == context.table and imp.context.environment == context.environment and imp.context.block == context.block)
                    try files.append(self.alloc, imp.target);
            };
        }

        fn spreads(self: *Self, context: Context) Error![]const *const ast.Node {
            var result: std.ArrayList(*const ast.Node) = .empty;
            errdefer result.deinit(self.alloc);
            for (context.table.blocks.items) |block| {
                if (block.environment == context.environment) try result.appendSlice(self.alloc, block.spreads.items);
            }
            if (self.contributions) |pending| for (pending.spreads) |node| {
                const block = node.lexical_block.?;
                if (context.table.block(block).environment == context.environment) try result.append(self.alloc, node);
            };
            return result.toOwnedSlice(self.alloc);
        }

        fn append(self: *Self, list: *std.ArrayList(Selected), candidates: Candidates) Error!void {
            defer self.alloc.free(candidates.imported);
            if (candidates.own) |decl| try list.append(self.alloc, decl);
            try list.appendSlice(self.alloc, candidates.imported);
        }

        fn appendCarried(self: *Self, list: *std.ArrayList(Selected), candidates: Candidates, view: Context, pinned: bool) Error!void {
            const start = list.items.len;
            try self.append(list, candidates);
            for (list.items[start..]) |*candidate| {
                if (candidate.declaration.info().scope != null) {
                    candidate.view = view;
                    candidate.pinned_view = pinned;
                }
            }
        }

        fn finalDeclaration(self: *Self, decl: Declaration) Error!?Declaration {
            for (self.aliases.items) |previous| if (std.meta.eql(previous, decl)) return null;
            const ref = decl.info().ref orelse return decl;
            if (ref != .const_decl) return decl;
            const path = imports.aliasPath(self.alloc, ref.const_decl.value) orelse return decl;
            defer self.alloc.free(path);
            const context = Context.author(decl) orelse return decl;
            try self.aliases.append(self.alloc, decl);
            defer _ = self.aliases.pop();
            const result = try self.select(path, context, context.source());
            return switch (result) {
                .selected => |selected| self.finalDeclaration(selected.declaration),
                .missing => decl,
                .ambiguous => null,
            };
        }

        fn equivalent(self: *Self, a: Declaration, b: Declaration) Error!bool {
            if (std.meta.eql(a, b)) return true;
            const left = try self.finalDeclaration(a) orelse return false;
            const right = try self.finalDeclaration(b) orelse return false;
            if (std.meta.eql(left, right)) return true;
            if (left.info().scope) |scope| {
                const other = right.info().scope orelse return false;
                return samePath(left.table.scopeInfo(scope).path, right.table.scopeInfo(other).path);
            }
            return self.backend.equivalentDeclarations(left, right);
        }

        pub fn choose(self: *Self, candidates: Candidates) Error!Selection {
            if (candidates.own) |decl| return .{ .selected = decl };
            var result: ?Selected = null;
            for (candidates.imported) |candidate| {
                if (result) |previous| {
                    if (!try self.equivalent(previous.declaration, candidate.declaration)) return .ambiguous;
                } else result = candidate;
            }
            return if (result) |decl| .{ .selected = decl } else .missing;
        }

        pub fn qualifier(self: *Self, selected: Selected) Error!?Qualifier {
            const decl = selected.declaration;
            const info = decl.info();
            if (info.scope) |scope| return .{ .scope = .{ .path = decl.table.scopeInfo(scope).path, .context = selected.view, .pinned = selected.pinned_view } };
            if (info.kind == .namespace) {
                var context = if (self.contributions != null and info.node != null and info.node.?.data == .import_decl)
                    self.backend.moduleContext(Context.author(decl).?, info.node.?.data.import_decl.path) orelse return null
                else
                    self.backend.namespaceContext(decl) orelse return null;
                if (selected.view.order) |order| if (std.mem.eql(u8, order.source, context.source())) {
                    context.order = order;
                };
                return .{ .namespace = context };
            }
            for (self.aliases.items) |previous| if (std.meta.eql(previous, decl)) return null;
            const ref = info.ref orelse return null;
            if (ref != .const_decl) return null;
            const path = imports.aliasPath(self.alloc, ref.const_decl.value) orelse return null;
            defer self.alloc.free(path);
            const context = Context.author(decl) orelse return null;
            try self.aliases.append(self.alloc, decl);
            defer _ = self.aliases.pop();
            const target = try self.select(path, context, context.source());
            var result = if (target == .selected) try self.qualifier(target.selected) else return null;
            if (result) |*value| {
                const target_context = switch (value.*) {
                    .scope => |*scope| blk: {
                        scope.pinned = true;
                        break :blk &scope.context;
                    },
                    .namespace => |*namespace| namespace,
                };
                target_context.order = null;
                if (selected.view.order) |order| if (std.mem.eql(u8, order.source, target_context.source())) {
                    target_context.order = order;
                };
            }
            return result;
        }

        pub fn select(self: *Self, path: []const u8, context: Context, requester: []const u8) Error!Selection {
            var parts = std.mem.splitScalar(u8, path, '.');
            const candidates = try self.bare(context, parts.next().?, requester);
            defer self.alloc.free(candidates.imported);
            var selected = try self.choose(candidates);
            while (parts.next()) |name| {
                if (selected != .selected) return selected;
                const target = try self.qualifier(selected.selected) orelse return .missing;
                selected = try self.member(target, name, requester);
            }
            return selected;
        }

        pub fn member(self: *Self, target: Qualifier, name: []const u8, requester: []const u8) Error!Selection {
            const candidates = try self.surface(target, name, requester);
            defer self.alloc.free(candidates.imported);
            return self.choose(candidates);
        }

        pub fn enumerateMembers(self: *Self, target: Qualifier, requester: []const u8) Error![]const Selected {
            var names = std.StringHashMap(void).init(self.alloc);
            defer names.deinit();
            var visited: std.ArrayList(Qualifier) = .empty;
            defer visited.deinit(self.alloc);
            try self.surfaceNames(target, &names, &visited);
            var result: std.ArrayList(Selected) = .empty;
            errdefer result.deinit(self.alloc);
            var it = names.keyIterator();
            while (it.next()) |name| {
                const selected = try self.member(target, name.*, requester);
                if (selected == .selected) try result.append(self.alloc, selected.selected);
            }
            return result.toOwnedSlice(self.alloc);
        }

        fn surfaceNames(self: *Self, target: Qualifier, names: *std.StringHashMap(void), visited: *std.ArrayList(Qualifier)) Error!void {
            for (visited.items) |previous| if (sameQualifier(previous, target)) return;
            try visited.append(self.alloc, target);
            var environments: std.ArrayList(Context) = .empty;
            defer environments.deinit(self.alloc);
            const view = switch (target) {
                .namespace => |ctx| blk: {
                    try environments.append(self.alloc, ctx);
                    break :blk ctx;
                },
                .scope => |scope| blk: {
                    try self.scopeEnvironments(&environments, scope);
                    break :blk scope.context;
                },
            };
            for (environments.items) |ctx| {
                var it = ctx.table.environment(ctx.environment).names.keyIterator();
                while (it.next()) |name| try names.put(name.*, {});
                if (self.contributions) |pending| for (pending.declarations) |decl| {
                    if (decl.table == ctx.table and decl.info().environment == ctx.environment)
                        try names.put(decl.info().name, {});
                };
                const nodes = try self.spreads(ctx);
                defer self.alloc.free(nodes);
                for (nodes) |node| {
                    if (!permitted(ctx, node)) continue;
                    const source = ctx.table.spread_sources.get(node).?;
                    if (source == .c_import) {
                        for (source.c_import) |id| try names.put(ctx.table.get(id).name, {});
                    } else {
                        const targets = try self.spreadTargets(ctx, node, view);
                        defer self.alloc.free(targets);
                        for (targets) |spread| try self.surfaceNames(spread, names, visited);
                    }
                }
            }
        }

        pub fn spreadTarget(self: *Self, context: Context, node: *const ast.Node) Error!SpreadTarget {
            return self.spreadTargetInView(context, node, context);
        }

        fn spreadTargetInView(self: *Self, context: Context, node: *const ast.Node, view: Context) Error!SpreadTarget {
            for (self.targets.items) |previous| if (previous == node) return .missing;
            try self.targets.append(self.alloc, node);
            defer _ = self.targets.pop();
            const written = context.table.written_targets.get(node).?;
            switch (context.table.spread_sources.get(node).?) {
                .missing => return .missing,
                .module => |path| return if (self.backend.moduleContext(context, path)) |module| .{ .target = .{ .namespace = module } } else .missing,
                .c_import => |ids| return .{ .c_import = ids },
                .path => |operand| {
                    const path = imports.aliasPath(self.alloc, operand).?;
                    defer self.alloc.free(path);
                    const author_context = Context{ .table = context.table, .environment = context.table.block(written.block).environment, .block = written.block, .order = .{ .source = written.source, .position = written.position } };
                    const result = try self.select(path, author_context, written.source);
                    return switch (result) {
                        .missing => .missing,
                        .ambiguous => .ambiguous,
                        .selected => |selected| blk: {
                            var target = try self.qualifier(selected) orelse break :blk .not_namespace;
                            if (target == .scope) {
                                if (!target.scope.pinned) target.scope.context = view;
                                target.scope.context.order = null;
                            } else target.namespace.order = null;
                            break :blk .{ .target = target };
                        },
                    };
                },
            }
        }

        fn qualifiers(self: *Self, selected: Selected, result: *std.ArrayList(Qualifier)) Error!void {
            const decl = selected.declaration;
            const info = decl.info();
            if (info.scope != null or info.kind == .namespace) {
                if (try self.qualifier(selected)) |target| try result.append(self.alloc, target);
                return;
            }
            for (self.aliases.items) |previous| if (std.meta.eql(previous, decl)) return;
            const ref = info.ref orelse return;
            if (ref != .const_decl) return;
            const path = imports.aliasPath(self.alloc, ref.const_decl.value) orelse return;
            defer self.alloc.free(path);
            try self.aliases.append(self.alloc, decl);
            defer _ = self.aliases.pop();
            const start = result.items.len;
            try self.pathQualifiers(path, Context.author(decl).?, result);
            for (result.items[start..]) |*target| {
                const context = switch (target.*) {
                    .scope => |*scope| blk: {
                        scope.pinned = true;
                        break :blk &scope.context;
                    },
                    .namespace => |*namespace| namespace,
                };
                context.order = null;
                if (selected.view.order) |order| if (std.mem.eql(u8, order.source, context.source())) {
                    context.order = order;
                };
            }
        }

        fn candidateQualifiers(self: *Self, candidates: Candidates, result: *std.ArrayList(Qualifier)) Error!void {
            defer self.alloc.free(candidates.imported);
            if (candidates.own) |selected| try self.qualifiers(selected, result);
            for (candidates.imported) |selected| try self.qualifiers(selected, result);
        }

        // Mutually exclusive branches can name different targets until selection.
        fn pathQualifiers(self: *Self, path: []const u8, context: Context, result: *std.ArrayList(Qualifier)) Error!void {
            var parts = std.mem.splitScalar(u8, path, '.');
            var targets: std.ArrayList(Qualifier) = .empty;
            defer targets.deinit(self.alloc);
            try self.candidateQualifiers(try self.bare(context, parts.next().?, context.source()), &targets);
            while (parts.next()) |name| {
                var next: std.ArrayList(Qualifier) = .empty;
                errdefer next.deinit(self.alloc);
                for (targets.items) |target| try self.candidateQualifiers(try self.surface(target, name, context.source()), &next);
                targets.deinit(self.alloc);
                targets = next;
            }
            try result.appendSlice(self.alloc, targets.items);
        }

        fn spreadTargets(self: *Self, context: Context, node: *const ast.Node, view: Context) Error![]const Qualifier {
            var result: std.ArrayList(Qualifier) = .empty;
            errdefer result.deinit(self.alloc);
            const source = context.table.spread_sources.get(node).?;
            if (self.contributions != null and source == .path) {
                for (self.targets.items) |previous| if (previous == node) return &.{};
                try self.targets.append(self.alloc, node);
                defer _ = self.targets.pop();
                const written = context.table.written_targets.get(node).?;
                const path = imports.aliasPath(self.alloc, source.path).?;
                defer self.alloc.free(path);
                try self.pathQualifiers(path, .{
                    .table = context.table,
                    .environment = context.table.block(written.block).environment,
                    .block = written.block,
                    .order = .{ .source = written.source, .position = written.position },
                }, &result);
                for (result.items) |*target| {
                    if (target.* == .scope) {
                        if (!target.scope.pinned) target.scope.context = view;
                        target.scope.context.order = null;
                    } else target.namespace.order = null;
                }
            } else {
                const resolved = try self.spreadTargetInView(context, node, view);
                if (resolved == .target) try result.append(self.alloc, resolved.target);
            }
            return result.toOwnedSlice(self.alloc);
        }

        fn permitted(context: Context, node: *const ast.Node) bool {
            const order = context.order orelse return true;
            const written = context.table.written_targets.get(node).?;
            return !std.mem.eql(u8, order.source, written.source) or written.position < order.position;
        }

        fn spreadMembers(self: *Self, context: Context, view: Context, pinned: bool, name: []const u8, requester: []const u8) Error!Candidates {
            var result = std.ArrayList(Selected).empty;
            errdefer result.deinit(self.alloc);
            const nodes = try self.spreads(context);
            defer self.alloc.free(nodes);
            for (nodes) |node| {
                if (!permitted(context, node)) continue;
                const source = context.table.spread_sources.get(node).?;
                if (source == .c_import) {
                    for (source.c_import) |id| {
                        const decl = Declaration{ .table = context.table, .id = id };
                        if (std.mem.eql(u8, decl.info().name, name)) try result.append(self.alloc, .{ .declaration = decl, .view = context });
                    }
                } else {
                    const targets = try self.spreadTargets(context, node, view);
                    defer self.alloc.free(targets);
                    for (targets) |target| try self.appendCarried(&result, try self.surface(target, name, requester), view, pinned);
                }
            }
            return .{ .imported = try result.toOwnedSlice(self.alloc) };
        }

        fn imported(self: *Self, context: Context, name: []const u8, requester: []const u8) Error!Candidates {
            var files = std.ArrayList(Context).empty;
            defer files.deinit(self.alloc);
            try self.plainImports(context, &files);
            var result = std.ArrayList(Selected).empty;
            errdefer result.deinit(self.alloc);
            for (files.items) |file| {
                var target = file;
                if (context.order) |order| if (std.mem.eql(u8, order.source, target.source())) {
                    target.order = order;
                };
                try self.appendCarried(&result, try self.surface(.{ .namespace = target }, name, requester), context, false);
            }
            return .{ .imported = try result.toOwnedSlice(self.alloc) };
        }

        fn addEnvironment(self: *Self, list: *std.ArrayList(Context), context: Context, path: []const []const u8) Error!void {
            const env = context.table.findEnvironment(context.source(), path) orelse return;
            if (context.table.environment(env).scope == null) return;
            for (list.items) |existing| if (existing.table == context.table and existing.environment == env) return;
            try list.append(self.alloc, .{ .table = context.table, .environment = env, .order = context.order });
        }

        fn carriedEnvironments(self: *Self, list: *std.ArrayList(Context), context: Context, path: []const []const u8) Error!void {
            for (self.carriers.items) |previous| {
                if (sameContext(previous.context, context) and samePath(previous.path, path)) return;
            }
            try self.carriers.append(self.alloc, .{ .context = context, .path = path });
            defer _ = self.carriers.pop();
            const owner_path = context.table.environment(context.environment).scope_path;
            if (path.len > owner_path.len and samePath(path[0..owner_path.len], owner_path)) {
                try self.addEnvironment(list, context, path);
            }
            const nodes = try self.spreads(context);
            defer self.alloc.free(nodes);
            for (nodes) |node| {
                if (!permitted(context, node)) continue;
                const targets = try self.spreadTargets(context, node, context);
                defer self.alloc.free(targets);
                for (targets) |target| switch (target) {
                    .namespace => |file| try self.carriedEnvironments(list, file, path),
                    .scope => |scope| {
                        var environments = std.ArrayList(Context).empty;
                        defer environments.deinit(self.alloc);
                        try self.scopeEnvironments(&environments, scope);
                        for (environments.items) |env| try self.carriedEnvironments(list, env, path);
                    },
                };
            }
        }

        fn scopeEnvironments(self: *Self, list: *std.ArrayList(Context), view: ScopeView) Error!void {
            var root = view.context.root();
            root.order = view.context.order;
            try self.carriedEnvironments(list, root, view.path);
            var current: ?Context = view.context;
            while (current) |ctx| : (current = parent(ctx)) {
                var files = std.ArrayList(Context).empty;
                defer files.deinit(self.alloc);
                try self.plainImports(ctx, &files);
                for (files.items) |file| try self.carriedEnvironments(list, file, view.path);
            }
            for (list.items) |*ctx| ctx.order = view.context.order;
        }

        pub fn scopeMembers(self: *Self, view: ScopeView, name: []const u8, requester: []const u8) Error!Candidates {
            var environments = std.ArrayList(Context).empty;
            defer environments.deinit(self.alloc);
            try self.scopeEnvironments(&environments, view);
            var result = std.ArrayList(Selected).empty;
            errdefer result.deinit(self.alloc);
            for (environments.items) |ctx| {
                const candidates = try self.local(ctx, name, requester);
                if (std.mem.eql(u8, ctx.source(), view.context.source()) and candidates.found()) {
                    result.deinit(self.alloc);
                    if (candidates.own) |candidate| return .{ .own = .{ .declaration = candidate.declaration, .view = view.context, .pinned_view = view.pinned } };
                    result = .empty;
                    try self.append(&result, candidates);
                    for (result.items) |*candidate| {
                        candidate.view = view.context;
                        candidate.pinned_view = view.pinned;
                    }
                    return .{ .imported = try result.toOwnedSlice(self.alloc) };
                }
                const start = result.items.len;
                try self.append(&result, candidates);
                for (result.items[start..]) |*candidate| {
                    candidate.view = view.context;
                    candidate.pinned_view = view.pinned;
                }
            }
            if (result.items.len != 0) return .{ .imported = try result.toOwnedSlice(self.alloc) };
            for (environments.items) |ctx| try self.append(&result, try self.spreadMembers(ctx, view.context, view.pinned, name, requester));
            return .{ .imported = try result.toOwnedSlice(self.alloc) };
        }

        pub fn surface(self: *Self, target: Qualifier, name: []const u8, requester: []const u8) Error!Candidates {
            for (self.surfaces.items) |previous| {
                if (std.mem.eql(u8, previous.name, name) and sameQualifier(previous.target, target)) return .{};
            }
            try self.surfaces.append(self.alloc, .{ .target = target, .name = name });
            defer _ = self.surfaces.pop();
            return switch (target) {
                .namespace => |ctx| blk: {
                    var candidates = try self.local(ctx, name, requester);
                    if (candidates.own) |*selected| selected.pinned_view = true;
                    if (candidates.found()) break :blk candidates;
                    self.alloc.free(candidates.imported);
                    break :blk try self.spreadMembers(ctx, ctx, true, name, requester);
                },
                .scope => |scope| self.scopeMembers(scope, name, requester),
            };
        }

        pub fn bare(self: *Self, context: Context, name: []const u8, requester: []const u8) Error!Candidates {
            var current: ?Context = context;
            var ordered = std.ArrayList(Selected).empty;
            errdefer ordered.deinit(self.alloc);
            while (current) |ctx| : (current = parent(ctx)) {
                const environment = ctx.table.environment(ctx.environment);
                var members: Candidates = if (environment.scope == null)
                    try self.local(ctx, name, requester)
                else
                    try self.surface(.{ .scope = .{ .path = environment.scope_path, .context = context } }, name, requester);
                if (members.own) |*selected| selected.view = context;
                if (members.own != null or (context.order == null and members.found())) {
                    ordered.deinit(self.alloc);
                    return members;
                }
                try self.append(&ordered, members);
                const from_imports = try self.imported(ctx, name, requester);
                if (environment.scope == null) try self.append(&ordered, try self.spreadMembers(ctx, ctx, false, name, requester));
                try self.append(&ordered, from_imports);
                if (context.order == null and ordered.items.len != 0) break;
            }
            return .{ .imported = try ordered.toOwnedSlice(self.alloc) };
        }
    };
}

pub fn bare(backend: anytype, context: Context, name: []const u8, requester: []const u8, alloc: std.mem.Allocator) !Candidates {
    var query = Query(@TypeOf(backend)).init(backend, alloc);
    defer query.deinit();
    return query.bare(context, name, requester);
}

pub fn scopeMembers(backend: anytype, view: ScopeView, name: []const u8, requester: []const u8, alloc: std.mem.Allocator) !Candidates {
    var query = Query(@TypeOf(backend)).init(backend, alloc);
    defer query.deinit();
    return query.surface(.{ .scope = view }, name, requester);
}
