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

pub const InstanceArgument = union(enum) {
    declaration: Declaration,
    name: []const u8,
};

pub const InstanceKey = struct {
    declaration: Declaration,
    arguments: []const InstanceArgument,

    pub const Context = struct {
        pub fn hash(_: Context, key: InstanceKey) u64 {
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key.declaration);
            for (key.arguments) |arg| {
                std.hash.autoHash(&h, std.meta.activeTag(arg));
                switch (arg) {
                    .declaration => |d| std.hash.autoHash(&h, d),
                    .name => |n| {
                        std.hash.autoHash(&h, n.len);
                        h.update(n);
                    },
                }
            }
            return h.final();
        }

        pub fn eql(_: Context, a: InstanceKey, b: InstanceKey) bool {
            if (!std.meta.eql(a.declaration, b.declaration) or a.arguments.len != b.arguments.len) return false;
            for (a.arguments, b.arguments) |x, y| {
                if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
                switch (x) {
                    .declaration => |d| if (!std.meta.eql(d, y.declaration)) return false,
                    .name => |n| if (!std.mem.eql(u8, n, y.name)) return false,
                }
            }
            return true;
        }
    };
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

    const Located = struct { selection: *const Selection, declaration: Declaration };
    const Entity = union(enum) {
        declaration: Declaration,
        expression: struct { selection: *const Selection, node: *const ast.Node },
    };

    fn entity(located: Located, visiting: *std.ArrayList(Declaration)) ?Entity {
        const decl = located.declaration;
        const self = located.selection;
        for (visiting.items) |previous| if (std.meta.eql(previous, decl)) return null;
        visiting.append(self.alloc, decl) catch @panic("out of memory");
        defer _ = visiting.pop();
        const ref = decl.info().ref orelse return .{ .declaration = decl };
        if (ref != .const_decl) return .{ .declaration = decl };
        const node = ref.const_decl.value;
        if (imports.aliasPath(self.alloc, node)) |path| {
            defer self.alloc.free(path);
            if (self.locate(path, visiting)) |target| return entity(target, visiting);
            if (@import("types.zig").Type.fromTypeExpr(node) != null)
                return .{ .expression = .{ .selection = self, .node = node } };
            return null;
        }
        if (node.data == .call) {
            const path = imports.aliasPath(self.alloc, node.data.call.callee) orelse return .{ .declaration = decl };
            defer self.alloc.free(path);
            const target = self.locate(path, visiting) orelse return null;
            const resolved = entity(target, visiting) orelse return null;
            if (resolved == .declaration) {
                const raw = resolved.declaration.info().ref orelse return null;
                const inner = imports.innerDeclRef(raw) orelse raw;
                if (inner == .struct_decl and inner.struct_decl.type_params.len > 0)
                    return .{ .expression = .{ .selection = self, .node = node } };
            }
        }
        return switch (node.data) {
            .function_type_expr, .closure_type_expr, .pointer_type_expr, .many_pointer_type_expr, .slice_type_expr, .array_type_expr, .optional_type_expr, .tuple_type_expr, .parameterized_type_expr => .{ .expression = .{ .selection = self, .node = node } },
            else => .{ .declaration = decl },
        };
    }

    fn sameEntity(a: Entity, b: Entity, visiting: *std.ArrayList(Declaration)) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .declaration => |d| std.meta.eql(d, b.declaration),
            .expression => |e| sameExpression(e.selection, e.node, b.expression.selection, b.expression.node, visiting),
        };
    }

    fn sameExpression(a: *const Selection, x: *const ast.Node, b: *const Selection, y: *const ast.Node, visiting: *std.ArrayList(Declaration)) bool {
        if (imports.aliasPath(a.alloc, x)) |xp| {
            defer a.alloc.free(xp);
            const yp = imports.aliasPath(b.alloc, y) orelse return false;
            defer b.alloc.free(yp);
            const xl = a.locate(xp, visiting);
            const yl = b.locate(yp, visiting);
            if (xl != null or yl != null) {
                const left: Entity = if (xl) |l| entity(l, visiting) orelse return false else .{ .expression = .{ .selection = a, .node = x } };
                const right: Entity = if (yl) |r| entity(r, visiting) orelse return false else .{ .expression = .{ .selection = b, .node = y } };
                return sameEntity(left, right, visiting);
            }
            return std.mem.eql(u8, xp, yp);
        }
        if (std.meta.activeTag(x.data) != std.meta.activeTag(y.data)) return false;
        return switch (x.data) {
            .function_type_expr => |t| t.abi == y.data.function_type_expr.abi and
                t.is_c_variadic == y.data.function_type_expr.is_c_variadic and
                sameExpressions(a, t.param_types, b, y.data.function_type_expr.param_types, visiting) and
                sameOptionalExpression(a, t.return_type, b, y.data.function_type_expr.return_type, visiting),
            .closure_type_expr => |t| std.meta.eql(t.pack_name, y.data.closure_type_expr.pack_name) and
                std.meta.eql(t.pack_projection, y.data.closure_type_expr.pack_projection) and
                sameExpressions(a, t.param_types, b, y.data.closure_type_expr.param_types, visiting) and
                sameOptionalExpression(a, t.return_type, b, y.data.closure_type_expr.return_type, visiting),
            .tuple_type_expr => |t| sameExpressions(a, t.field_types, b, y.data.tuple_type_expr.field_types, visiting) and sameFieldNames(t.field_names, y.data.tuple_type_expr.field_names),
            .parameterized_type_expr => |t| blk: {
                const left = ast.Node{ .span = x.span, .data = .{ .identifier = .{ .name = t.name, .is_raw = t.is_raw } } };
                const right = ast.Node{ .span = y.span, .data = .{ .identifier = .{ .name = y.data.parameterized_type_expr.name, .is_raw = y.data.parameterized_type_expr.is_raw } } };
                break :blk sameExpression(a, &left, b, &right, visiting) and sameExpressions(a, t.args, b, y.data.parameterized_type_expr.args, visiting);
            },
            .pointer_type_expr => |t| sameExpression(a, t.pointee_type, b, y.data.pointer_type_expr.pointee_type, visiting),
            .many_pointer_type_expr => |t| t.sentinel == y.data.many_pointer_type_expr.sentinel and sameExpression(a, t.element_type, b, y.data.many_pointer_type_expr.element_type, visiting),
            .slice_type_expr => |t| t.sentinel == y.data.slice_type_expr.sentinel and sameExpression(a, t.element_type, b, y.data.slice_type_expr.element_type, visiting),
            .optional_type_expr => |t| sameExpression(a, t.inner_type, b, y.data.optional_type_expr.inner_type, visiting),
            .array_type_expr => |t| t.sentinel == y.data.array_type_expr.sentinel and sameExpression(a, t.length, b, y.data.array_type_expr.length, visiting) and sameExpression(a, t.element_type, b, y.data.array_type_expr.element_type, visiting),
            .call => |c| sameExpression(a, c.callee, b, y.data.call.callee, visiting) and sameExpressions(a, c.args, b, y.data.call.args, visiting),
            .int_literal => |v| v.value == y.data.int_literal.value,
            else => x == y,
        };
    }

    fn sameFieldNames(a: ?[]const []const u8, b: ?[]const []const u8) bool {
        const left = a orelse return b == null;
        const right = b orelse return false;
        if (left.len != right.len) return false;
        for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    fn sameOptionalExpression(a: *const Selection, x: ?*ast.Node, b: *const Selection, y: ?*ast.Node, visiting: *std.ArrayList(Declaration)) bool {
        if (x) |node| return sameExpression(a, node, b, y orelse return false, visiting);
        return y == null;
    }

    fn sameExpressions(a: *const Selection, x: []const *ast.Node, b: *const Selection, y: []const *ast.Node, visiting: *std.ArrayList(Declaration)) bool {
        if (x.len != y.len) return false;
        for (x, y) |left, right| if (!sameExpression(a, left, b, right, visiting)) return false;
        return true;
    }

    fn equivalent(a: Located, b: Located, visiting: *std.ArrayList(Declaration)) bool {
        if (std.meta.eql(a.declaration, b.declaration)) return true;
        const left = entity(a, visiting) orelse return false;
        const right = entity(b, visiting) orelse return false;
        visiting.appendSlice(a.selection.alloc, &.{ a.declaration, b.declaration }) catch @panic("out of memory");
        defer visiting.shrinkRetainingCapacity(visiting.items.len - 2);
        return sameEntity(left, right, visiting);
    }

    fn one(candidates: []const *Selection, name: []const u8, visiting: *std.ArrayList(Declaration)) ?Located {
        var selected: ?Located = null;
        for (candidates) |candidate| {
            const decl = candidate.publicOwn(name) orelse continue;
            const current = Located{ .selection = candidate, .declaration = decl };
            if (selected) |previous| {
                if (!equivalent(previous, current, visiting)) return null;
            } else selected = current;
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

    fn locate(self: *const Selection, name: []const u8, visiting: *std.ArrayList(Declaration)) ?Located {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const targets = self.namespace(name[0..dot]) orelse return null;
            const rest = name[dot + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '.') == null) return one(targets, rest, visiting);
            var selected: ?Located = null;
            for (targets) |target| {
                const current = target.locate(rest, visiting) orelse continue;
                if (selected) |previous| {
                    if (!equivalent(previous, current, visiting)) return null;
                } else selected = current;
            }
            return selected;
        }
        if (self.own.get(name)) |decl| return .{ .selection = self, .declaration = decl };
        return one(self.flat.items, name, visiting);
    }

    pub fn select(self: *const Selection, name: []const u8) ?Declaration {
        var visiting = std.ArrayList(Declaration).empty;
        defer visiting.deinit(self.alloc);
        return (self.locate(name, &visiting) orelse return null).declaration;
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
