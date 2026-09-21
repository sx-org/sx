const std = @import("std");
const imports = @import("imports.zig");

pub const Declaration = struct {
    table: *const imports.DeclTable,
    id: imports.DeclId,

    pub fn info(self: Declaration) imports.DeclInfo {
        return self.table.get(self.id);
    }
};

pub const Context = struct {
    table: *const imports.DeclTable,
    environment: imports.EnvironmentId,
    block: ?imports.LexicalBlockId = null,

    pub fn source(self: Context) []const u8 {
        return self.table.environment(self.environment).source;
    }

    pub fn root(self: Context) Context {
        return .{ .table = self.table, .environment = self.table.fileEnvironment(self.source()).? };
    }

    pub fn author(decl: Declaration) ?Context {
        const info = decl.info();
        return .{ .table = decl.table, .environment = info.environment orelse return null, .block = info.lexical_block };
    }
};

pub const ScopeView = struct {
    path: []const []const u8,
    context: Context,
};

pub const Candidates = struct {
    own: ?Declaration = null,
    imported: []const Declaration = &.{},

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

fn parent(context: Context) ?Context {
    if (context.block) |id| {
        const enclosing = context.table.block(id).parent orelse return null;
        return .{ .table = context.table, .environment = context.table.block(enclosing).environment, .block = enclosing };
    }
    const path = context.table.environment(context.environment).scope_path;
    if (path.len == 0) return null;
    return .{ .table = context.table, .environment = context.table.findEnvironment(context.source(), path[0 .. path.len - 1]).? };
}

fn imported(backend: anytype, context: Context, name: []const u8, requester: []const u8, alloc: std.mem.Allocator) !Candidates {
    var files = std.ArrayList(Context).empty;
    defer files.deinit(alloc);
    try backend.plainImports(context, &files);
    var candidates = std.ArrayList(Declaration).empty;
    errdefer candidates.deinit(alloc);
    for (files.items) |file| {
        if (own(file, name, requester)) |decl| try candidates.append(alloc, decl);
    }
    return .{ .imported = try candidates.toOwnedSlice(alloc) };
}

pub fn scopeMembers(backend: anytype, view: ScopeView, name: []const u8, requester: []const u8, alloc: std.mem.Allocator) !Candidates {
    const context = view.context;
    if (context.table.findEnvironment(context.source(), view.path)) |env| {
        if (context.table.environment(env).scope != null) {
            if (own(.{ .table = context.table, .environment = env }, name, requester)) |decl| return .{ .own = decl };
        }
    }
    var files = std.ArrayList(Context).empty;
    defer files.deinit(alloc);
    var current: ?Context = context;
    while (current) |ctx| : (current = parent(ctx)) try backend.plainImports(ctx, &files);
    var candidates = std.ArrayList(Declaration).empty;
    errdefer candidates.deinit(alloc);
    for (files.items) |file| {
        const env = file.table.findEnvironment(file.source(), view.path) orelse continue;
        if (file.table.environment(env).scope == null) continue;
        if (own(.{ .table = file.table, .environment = env }, name, requester)) |decl| try candidates.append(alloc, decl);
    }
    return .{ .imported = try candidates.toOwnedSlice(alloc) };
}

pub fn bare(backend: anytype, context: Context, name: []const u8, requester: []const u8, alloc: std.mem.Allocator) !Candidates {
    var current: ?Context = context;
    while (current) |ctx| : (current = parent(ctx)) {
        const environment = ctx.table.environment(ctx.environment);
        const members: Candidates = if (environment.scope == null)
            .{ .own = own(ctx, name, requester) }
        else
            try scopeMembers(backend, .{ .path = environment.scope_path, .context = context }, name, requester, alloc);
        if (members.found()) return members;
        alloc.free(members.imported);
        const from_imports = try imported(backend, ctx, name, requester, alloc);
        if (from_imports.found()) return from_imports;
        alloc.free(from_imports.imported);
    }
    return .{};
}
