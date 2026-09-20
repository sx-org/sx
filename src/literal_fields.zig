const std = @import("std");

pub const Origin = enum { direct, spread };
pub const RouteError = error{ UnknownField, TooManyValues, UnnamedAfterNamed, DirectCollision, DuplicateName };

pub fn spreadName(name: []const u8) ?[]const u8 {
    return if (std.fmt.parseInt(usize, name, 10)) |_| null else |_| name;
}

pub const Typed = struct {
    names: []const []const u8,
    direct: []bool,
    plain: []bool,
    position: usize = 0,
    named: bool = false,

    pub fn init(alloc: std.mem.Allocator, names: []const []const u8) Typed {
        const direct = alloc.alloc(bool, names.len) catch unreachable;
        const plain = alloc.alloc(bool, names.len) catch unreachable;
        @memset(direct, false);
        @memset(plain, false);
        return .{ .names = names, .direct = direct, .plain = plain };
    }

    pub fn deinit(self: *Typed, alloc: std.mem.Allocator) void {
        alloc.free(self.direct);
        alloc.free(self.plain);
    }

    pub fn find(self: *const Typed, name: []const u8) ?usize {
        for (self.names, 0..) |field, i| if (std.mem.eql(u8, field, name)) return i;
        return null;
    }

    pub fn plainName(self: *const Typed, name: ?[]const u8, shorthand: bool) ?[]const u8 {
        const n = name orelse return null;
        return if (shorthand and self.find(n) == null) null else n;
    }

    pub fn contribute(self: *Typed, name: ?[]const u8, origin: Origin) RouteError!usize {
        if (name) |n| {
            self.named = true;
            const index = self.find(n) orelse return error.UnknownField;
            if (origin == .direct) {
                if (self.plain[index]) return error.DuplicateName;
                if (self.direct[index]) return error.DirectCollision;
                self.plain[index] = true;
            }
            return index;
        }
        if (self.named) return error.UnnamedAfterNamed;
        const index = self.position;
        self.position += 1;
        if (index >= self.names.len) return error.TooManyValues;
        if (origin == .direct) self.direct[index] = true;
        return index;
    }
};

pub fn Anonymous(comptime Value: type) type {
    return struct {
        const Self = @This();
        pub const Field = struct { name: []const u8, value: Value, plain: bool };
        named: std.ArrayList(Field) = .empty,
        unnamed: std.ArrayList(Value) = .empty,

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.named.deinit(alloc);
            self.unnamed.deinit(alloc);
        }

        pub fn contribute(self: *Self, alloc: std.mem.Allocator, name: ?[]const u8, origin: Origin, value: Value) error{DuplicateName}!void {
            if (name) |n| {
                for (self.named.items) |*field| {
                    if (!std.mem.eql(u8, field.name, n)) continue;
                    if (origin == .direct and field.plain) return error.DuplicateName;
                    field.plain = field.plain or origin == .direct;
                    field.value = value;
                    return;
                }
                self.named.append(alloc, .{ .name = n, .value = value, .plain = origin == .direct }) catch unreachable;
            } else {
                self.unnamed.append(alloc, value) catch unreachable;
            }
        }
    };
}
