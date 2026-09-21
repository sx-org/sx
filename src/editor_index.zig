const std = @import("std");
const ast = @import("ast.zig");
const imports = @import("imports.zig");

pub const Declaration = struct {
    table: *const imports.DeclTable,
    id: imports.DeclId,

    pub fn info(self: Declaration) imports.DeclInfo {
        return self.table.get(self.id);
    }
};

pub const DeclarationContext = struct {
    table: *const imports.DeclTable,
    environment: imports.EnvironmentId,
};

pub const Selection = struct {
    alloc: std.mem.Allocator,
    context: ?DeclarationContext = null,
    own: std.StringHashMap(Declaration),
    flat: std.ArrayList(*Selection) = .empty,
    namespaces: std.StringHashMap(std.ArrayList(*Selection)),

    pub fn init(alloc: std.mem.Allocator) Selection {
        return .{ .alloc = alloc, .own = .init(alloc), .namespaces = .init(alloc) };
    }

    pub fn register(self: *Selection, nodes: []const *ast.Node) !void {
        const table = if (self.context) |ctx| @constCast(ctx.table) else blk: {
            const t = try self.alloc.create(imports.DeclTable);
            t.* = imports.DeclTable.init(self.alloc);
            break :blk t;
        };
        for (nodes) |node| {
            const name = node.data.declName() orelse (if (node.data == .import_decl) node.data.import_decl.name else null) orelse continue;
            const id = try table.internNamedNode(if (self.context) |ctx| ctx.environment else null, name, node);
            try self.own.put(name, .{ .table = table, .id = id });
            if (node.data == .namespace_decl) {
                const ns = node.data.namespace_decl;
                const child = try self.alloc.create(Selection);
                child.* = Selection.init(self.alloc);
                if (self.context) |ctx| {
                    const target = ctx.table.environment(ctx.environment).namespaces.get(name).?;
                    child.context = .{ .table = ctx.table, .environment = target.environment };
                }
                try child.register(ns.own_decls);
                try self.addImport(name, child);
            }
        }
    }

    pub fn addImport(self: *Selection, alias: ?[]const u8, imported: *Selection) !void {
        if (alias) |name| {
            const entry = try self.namespaces.getOrPut(name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.alloc, imported);
        } else try self.flat.append(self.alloc, imported);
    }

    fn publicOwn(self: *const Selection, name: []const u8) ?Declaration {
        const decl = self.own.get(name) orelse return null;
        return if (decl.info().visibility == .public) decl else null;
    }

    fn one(candidates: []const *Selection, name: []const u8) ?Declaration {
        var selected: ?Declaration = null;
        for (candidates) |candidate| {
            const decl = candidate.publicOwn(name) orelse continue;
            if (selected) |previous| {
                if (!std.meta.eql(previous, decl)) return null;
            } else selected = decl;
        }
        return selected;
    }

    pub fn namespace(self: *const Selection, name: []const u8) ?[]const *Selection {
        if (self.namespaces.get(name)) |targets| return targets.items;
        var selected: ?[]const *Selection = null;
        for (self.flat.items) |imported| {
            _ = imported.publicOwn(name) orelse continue;
            const targets = imported.namespaces.get(name) orelse continue;
            if (selected) |previous| {
                if (!std.mem.eql(*Selection, previous, targets.items)) return null;
            } else selected = targets.items;
        }
        return selected;
    }

    pub fn select(self: *const Selection, name: []const u8) ?Declaration {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const targets = self.namespace(name[0..dot]) orelse return null;
            const rest = name[dot + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '.') == null) return one(targets, rest);
            var selected: ?Declaration = null;
            for (targets) |target| {
                const decl = target.select(rest) orelse continue;
                if (selected) |previous| {
                    if (!std.meta.eql(previous, decl)) return null;
                } else selected = decl;
            }
            return selected;
        }
        return self.own.get(name) orelse one(self.flat.items, name);
    }
};

pub fn Registry(comptime T: type) type {
    return struct {
        selection: *Selection,
        declarations: std.AutoHashMap(Declaration, T),
        members: std.AutoHashMap(Declaration, std.StringHashMap(T)),
        local: std.StringHashMap(T),

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, selection: *Selection) Self {
            return .{ .selection = selection, .declarations = .init(alloc), .members = .init(alloc), .local = .init(alloc) };
        }

        const Member = struct { owner: Declaration, name: []const u8 };

        fn member(self: Self, name: []const u8) ?Member {
            const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
            return .{ .owner = self.selection.select(name[0..dot]) orelse return null, .name = name[dot + 1 ..] };
        }

        pub fn get(self: Self, name: []const u8) ?T {
            if (self.selection.select(name)) |decl| return self.declarations.get(decl);
            if (self.member(name)) |m| return (self.members.get(m.owner) orelse return null).get(m.name);
            return self.local.get(name);
        }

        pub fn contains(self: Self, name: []const u8) bool {
            return self.get(name) != null;
        }

        pub fn put(self: *Self, name: []const u8, value: T) !void {
            if (self.selection.select(name)) |decl| return self.declarations.put(decl, value);
            if (self.member(name)) |m| {
                const entry = try self.members.getOrPut(m.owner);
                if (!entry.found_existing) entry.value_ptr.* = .init(self.selection.alloc);
                return entry.value_ptr.put(m.name, value);
            }
            return self.local.put(name, value);
        }

        pub fn merge(self: *Self, other: Self) !void {
            var declarations = other.declarations.iterator();
            while (declarations.next()) |entry| try self.declarations.put(entry.key_ptr.*, entry.value_ptr.*);
            var members = other.members.iterator();
            while (members.next()) |entry| try self.members.put(entry.key_ptr.*, entry.value_ptr.*);
            var local = other.local.iterator();
            while (local.next()) |entry| try self.local.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    };
}
