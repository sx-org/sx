//! The functions the compiler CALLS rather than implements. Each is an
//! ordinary declaration in its owner module, bound by that (module, name)
//! identity and called by function id, so the name carries no privilege,
//! needs no import at the site, and is never spelled into synthesized source.
//! The `@` registry (`contracts.zig`) is the other class: names the compiler
//! implements or expands.

const std = @import("std");

pub const Binding = struct {
    /// The owner module, as an import path suffix.
    module: []const u8,
    /// The declaration's name in that module; a method is `Type.method`.
    name: []const u8,
};

const core = "modules/std/core.sx";

/// The `@printf` expansion: a stdout `FdWriter` and the renderers it feeds.
pub const entries = [_]Binding{
    .{ .module = core, .name = "FdWriter.init" },
    .{ .module = core, .name = "FdWriter.write" },
    .{ .module = core, .name = "FdWriter.flush" },
    .{ .module = core, .name = "writeBool" },
    .{ .module = core, .name = "writeInt" },
    .{ .module = core, .name = "writeUint" },
    .{ .module = core, .name = "writeFloat" },
    // A boxed `@as` whose pairing has no conversion.
    .{ .module = core, .name = "asRefused" },
};

pub fn find(name: []const u8) ?Binding {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

test "every binding is found by its own name" {
    for (entries) |e| {
        const got = find(e.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(e.module, got.module);
    }
    try std.testing.expect(find("write") == null);
}
