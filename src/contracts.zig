//! The `@` namespace: compiler-maintained language contracts that stdlib
//! DECLARES in ordinary, reviewable source.
//!
//! An `@` name is not a keyword and carries no privilege — the sigil marks a
//! declaration whose shape is a compiler contract, so changing its fields is a
//! coordinated compiler + stdlib revision. Which `@` names exist and which
//! module owns each is this registry, and the compiler recognizes a contract by
//! that (module, name) identity rather than by a name-and-field-shape test a
//! lookalike could satisfy.
//!
//! Separate from `Parser.compiler_formed_types` (`@Init`, `@BuildBlock`): those
//! are FORMED by the compiler at a parameter type and are never declared or
//! constructed, so they have no stdlib declaration to key on.

const std = @import("std");

pub const Contract = struct {
    /// The declared name, `@` included.
    name: []const u8,
    /// The module that owns the canonical declaration, as an import path
    /// suffix (matched against the declaring file).
    module: []const u8,
};

pub const entries = [_]Contract{
    .{ .name = "@SourceSite", .module = "modules/std/core.sx" },
};

pub fn find(name: []const u8) ?Contract {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// True when `file` is the module that owns `contract`'s canonical
/// declaration. A null file is the main file, which owns none of them.
pub fn declaredIn(contract: Contract, file: ?[]const u8) bool {
    const f = file orelse return false;
    return std.mem.endsWith(u8, f, contract.module);
}

pub fn isAtName(name: []const u8) bool {
    return name.len > 0 and name[0] == '@';
}

test "every contract is found by its own name" {
    for (entries) |e| {
        const got = find(e.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(e.module, got.module);
        try std.testing.expect(isAtName(e.name));
    }
    try std.testing.expect(find("@NotAContract") == null);
}

test "declaredIn matches the owning module only" {
    const c = find("@SourceSite").?;
    try std.testing.expect(declaredIn(c, "library/modules/std/core.sx"));
    try std.testing.expect(!declaredIn(c, "library/modules/std/fmt.sx"));
    try std.testing.expect(!declaredIn(c, null));
}
