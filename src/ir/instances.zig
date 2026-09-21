const std = @import("std");
const imports = @import("../imports.zig");
const types = @import("types.zig");
const ast = @import("../ast.zig");

pub const Argument = union(enum) {
    type_id: types.TypeId,
    integer: i64,
    character: i64,
    boolean: bool,
    float_bits: u64,
    string: []const u8,
    pack: []const types.TypeId,
    binding: struct { name: []const u8, ty: types.TypeId },

    pub fn literal(node: *const ast.Node) ?Argument {
        return switch (node.data) {
            .int_literal => |v| .{ .integer = v.value },
            .char_literal => |v| .{ .character = v.value },
            .bool_literal => |v| .{ .boolean = v.value },
            .float_literal => |v| .{ .float_bits = @bitCast(v.value) },
            .string_literal => |v| .{ .string = v.raw },
            else => null,
        };
    }
};

pub const Key = struct {
    declaration: imports.DeclId,
    arguments: []const Argument,

    pub const Context = struct {
        pub fn hash(_: Context, key: Key) u64 {
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key.declaration);
            std.hash.autoHashStrat(&h, key.arguments, .DeepRecursive);
            return h.final();
        }

        pub fn eql(_: Context, a: Key, b: Key) bool {
            if (a.declaration != b.declaration or a.arguments.len != b.arguments.len) return false;
            for (a.arguments, b.arguments) |x, y| {
                if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
                const equal = switch (x) {
                    .string => |v| std.mem.eql(u8, v, y.string),
                    .pack => |v| std.mem.eql(types.TypeId, v, y.pack),
                    .binding => |v| v.ty == y.binding.ty and std.mem.eql(u8, v.name, y.binding.name),
                    inline else => |v, tag| v == @field(y, @tagName(tag)),
                };
                if (!equal) return false;
            }
            return true;
        }
    };
};

pub fn Cache(comptime Value: type) type {
    return std.HashMap(Key, Value, Key.Context, std.hash_map.default_max_load_percentage);
}

pub fn appendBindings(alloc: std.mem.Allocator, arguments: *std.ArrayList(Argument), bindings: *const std.StringHashMap(types.TypeId)) void {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(alloc);
    var it = bindings.keyIterator();
    while (it.next()) |name| names.append(alloc, name.*) catch @panic("out of memory");
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| arguments.append(alloc, .{ .binding = .{ .name = name, .ty = bindings.get(name).? } }) catch @panic("out of memory");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn ownKey(alloc: std.mem.Allocator, key: Key) Key {
    const args = alloc.dupe(Argument, key.arguments) catch @panic("out of memory");
    for (args) |*arg| switch (arg.*) {
        .string => |s| arg.string = alloc.dupe(u8, s) catch @panic("out of memory"),
        .pack => |p| arg.pack = alloc.dupe(types.TypeId, p) catch @panic("out of memory"),
        .binding => |*b| b.name = alloc.dupe(u8, b.name) catch @panic("out of memory"),
        else => {},
    };
    return .{ .declaration = key.declaration, .arguments = args };
}
