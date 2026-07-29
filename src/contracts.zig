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
const imports = @import("imports.zig");

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

/// The path a stdlib root would give `module`.
pub fn candidatePath(allocator: std.mem.Allocator, root: []const u8, module: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, module });
}

/// True when `file` IS the canonical declaration of `contract` — the module
/// resolved from a library root, compared by identity on disk.
///
/// A path-suffix test would not do: `my/modules/std/core.sx` ends with the
/// module path, and a project-local `modules/std/core.sx` wins cwd-first
/// import resolution, so either would pass a spelling comparison while being
/// a different file. `stdlib_roots` is what the compiler actually searched, so
/// no root means no provable origin and nothing matches.
pub fn declaredIn(
    allocator: std.mem.Allocator,
    contract: Contract,
    file: ?[]const u8,
    stdlib_roots: []const []const u8,
) bool {
    const f = file orelse return false;
    for (stdlib_roots) |root| {
        const candidate = candidatePath(allocator, root, contract.module) catch continue;
        if (imports.sameFileIdentity(allocator, f, candidate)) return true;
    }
    return false;
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

test "candidatePath joins a root to the owning module" {
    const p = try candidatePath(std.testing.allocator, "/opt/sx/library", "modules/std/core.sx");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("/opt/sx/library/modules/std/core.sx", p);
}

test "declaredIn proves nothing without a library root" {
    const c = find("@SourceSite").?;
    try std.testing.expect(!declaredIn(std.testing.allocator, c, "library/modules/std/core.sx", &.{}));
    try std.testing.expect(!declaredIn(std.testing.allocator, c, null, &.{}));
}
