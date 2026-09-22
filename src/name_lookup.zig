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

pub fn Query(comptime Backend: type) type {
    return struct {
        backend: Backend,
        alloc: std.mem.Allocator,
        surfaces: std.ArrayList(Surface) = .empty,
        targets: std.ArrayList(*const ast.Node) = .empty,
        aliases: std.ArrayList(Declaration) = .empty,
        carriers: std.ArrayList(Context) = .empty,

        const Self = @This();
        const Error = std.mem.Allocator.Error;
        const Surface = struct { target: Qualifier, name: []const u8 };

        pub fn init(backend: Backend, alloc: std.mem.Allocator) Self {
            return .{ .backend = backend, .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            self.surfaces.deinit(self.alloc);
            self.targets.deinit(self.alloc);
            self.aliases.deinit(self.alloc);
            self.carriers.deinit(self.alloc);
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
                var context = self.backend.namespaceContext(decl) orelse return null;
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

        pub fn spreadTarget(self: *Self, context: Context, node: *const ast.Node) Error!SpreadTarget {
            return self.spreadTargetInView(context, node, context);
        }

        fn spreadTargetInView(self: *Self, context: Context, node: *const ast.Node, view: Context) Error!SpreadTarget {
            for (self.targets.items) |previous| if (previous == node) return .missing;
            try self.targets.append(self.alloc, node);
            defer _ = self.targets.pop();
            const written = context.table.written_targets.get(node).?;
            switch (context.table.spread_sources.get(node).?) {
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

        fn permitted(context: Context, node: *const ast.Node) bool {
            const order = context.order orelse return true;
            const written = context.table.written_targets.get(node).?;
            return std.mem.eql(u8, order.source, written.source) and written.position < order.position;
        }

        fn spreadMembers(self: *Self, context: Context, view: Context, pinned: bool, name: []const u8, requester: []const u8) Error!Candidates {
            var result = std.ArrayList(Selected).empty;
            errdefer result.deinit(self.alloc);
            for (context.table.blocks.items) |block| {
                if (block.environment != context.environment) continue;
                for (block.spreads.items) |node| {
                    if (!permitted(context, node)) continue;
                    const resolved = try self.spreadTargetInView(context, node, view);
                    switch (resolved) {
                        .target => |target| try self.appendCarried(&result, try self.surface(target, name, requester), view, pinned),
                        .c_import => |ids| for (ids) |id| {
                            const decl = Declaration{ .table = context.table, .id = id };
                            if (std.mem.eql(u8, decl.info().name, name)) try result.append(self.alloc, .{ .declaration = decl, .view = context });
                        },
                        else => {},
                    }
                }
            }
            return .{ .imported = try result.toOwnedSlice(self.alloc) };
        }

        fn imported(self: *Self, context: Context, name: []const u8, requester: []const u8) Error!Candidates {
            var files = std.ArrayList(Context).empty;
            defer files.deinit(self.alloc);
            try self.backend.plainImports(context, &files);
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
            for (self.carriers.items) |previous| if (sameContext(previous, context)) return;
            try self.carriers.append(self.alloc, context);
            defer _ = self.carriers.pop();
            try self.addEnvironment(list, context, path);
            for (context.table.blocks.items) |block| {
                if (block.environment != context.environment) continue;
                for (block.spreads.items) |node| {
                    if (!permitted(context, node)) continue;
                    const target = try self.spreadTarget(context, node);
                    if (target != .target) continue;
                    switch (target.target) {
                        .namespace => |file| try self.carriedEnvironments(list, file, path),
                        .scope => |scope| {
                            if (path.len <= scope.path.len or !samePath(path[0..scope.path.len], scope.path)) continue;
                            var environments = std.ArrayList(Context).empty;
                            defer environments.deinit(self.alloc);
                            try self.scopeEnvironments(&environments, scope);
                            for (environments.items) |env| try self.addEnvironment(list, env, path);
                        },
                    }
                }
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
                try self.backend.plainImports(ctx, &files);
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
                if (own(ctx, name, requester)) |decl| {
                    const candidate = Selected{ .declaration = decl, .view = view.context, .pinned_view = view.pinned };
                    if (std.mem.eql(u8, ctx.source(), view.context.source())) {
                        result.deinit(self.alloc);
                        return .{ .own = candidate };
                    }
                    try result.append(self.alloc, candidate);
                }
            }
            if (view.context.order == null and result.items.len != 0) return .{ .imported = try result.toOwnedSlice(self.alloc) };
            for (environments.items) |ctx| try self.append(&result, try self.spreadMembers(ctx, view.context, view.pinned, name, requester));
            return .{ .imported = try result.toOwnedSlice(self.alloc) };
        }

        pub fn surface(self: *Self, target: Qualifier, name: []const u8, requester: []const u8) Error!Candidates {
            for (self.surfaces.items) |previous| {
                if (!std.mem.eql(u8, previous.name, name) or std.meta.activeTag(previous.target) != std.meta.activeTag(target)) continue;
                const equal = switch (target) {
                    .namespace => |ctx| sameContext(ctx, previous.target.namespace),
                    .scope => |scope| samePath(scope.path, previous.target.scope.path) and sameContext(scope.context, previous.target.scope.context) and scope.pinned == previous.target.scope.pinned,
                };
                if (equal) return .{};
            }
            try self.surfaces.append(self.alloc, .{ .target = target, .name = name });
            defer _ = self.surfaces.pop();
            return switch (target) {
                .namespace => |ctx| if (own(ctx, name, requester)) |decl| .{ .own = .{ .declaration = decl, .view = ctx, .pinned_view = true } } else self.spreadMembers(ctx, ctx, true, name, requester),
                .scope => |scope| self.scopeMembers(scope, name, requester),
            };
        }

        pub fn bare(self: *Self, context: Context, name: []const u8, requester: []const u8) Error!Candidates {
            var current: ?Context = context;
            var ordered = std.ArrayList(Selected).empty;
            errdefer ordered.deinit(self.alloc);
            while (current) |ctx| : (current = parent(ctx)) {
                const environment = ctx.table.environment(ctx.environment);
                const members: Candidates = if (environment.scope == null)
                    .{ .own = if (own(ctx, name, requester)) |decl| .{ .declaration = decl, .view = context } else null }
                else
                    try self.surface(.{ .scope = .{ .path = environment.scope_path, .context = context } }, name, requester);
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
