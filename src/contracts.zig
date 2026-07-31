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
//! The `@` namespace holds two classes, both registered here so one lookup
//! answers for either:
//!
//!   - `.declared` — stdlib owns the canonical declaration, and the compiler
//!     recognizes it by (module, name) identity plus, for a struct, its field
//!     shape. `@SourceSite`, `@BuildSink`, `@BuildShape`.
//!   - `.compiler_formed` — the compiler FORMS the type for a parameter; there
//!     is no declaration anywhere, so declaring the name is an error wherever
//!     it appears. `@Init`, `@BuildBlock`. Both are constraints, so both are
//!     `bound_only`: they are written as a generic bound on the parameter
//!     (`$I/@Init(T)`, `$B/@BuildBlock(P)`), never as its type.

const std = @import("std");
const imports = @import("imports.zig");

pub const Kind = enum { declared, compiler_formed };

pub const Contract = struct {
    /// The declared name, `@` included.
    name: []const u8,
    kind: Kind = .declared,
    /// The module that owns the canonical declaration, as an import path
    /// suffix (matched against the declaring file). Empty when
    /// `kind == .compiler_formed`.
    module: []const u8 = "",
    /// The shape the compiler depends on, in declaration order. Empty for a
    /// contract that is not a struct.
    fields: []const Field = &.{},
    /// How a compiler-formed name is SPELLED in a diagnostic — the bare name
    /// would read as an incomplete type.
    spelling: []const u8 = "",
    /// A contract that is only ever a generic BOUND head: it names a
    /// constraint, so no position — parameter annotation included — may write
    /// it as a type. Its implementors are minted per formation site and are not
    /// spellable.
    bound_only: bool = false,
    /// The bound this contract is written as, when `bound_only`.
    bound_spelling: []const u8 = "",
};

/// One field of a contract's required shape, in declaration order.
pub const Field = struct {
    name: []const u8,
    /// The type as SPELLED in the declaration. A contract's fields are
    /// primitives, so the spelling is the whole check.
    type_name: []const u8,
};

pub const entries = [_]Contract{
    .{
        .name = "@SourceSite",
        .module = "modules/std/core.sx",
        .fields = &.{
            .{ .name = "file", .type_name = "string" },
            .{ .name = "declaration", .type_name = "string" },
            .{ .name = "line", .type_name = "i32" },
            .{ .name = "column", .type_name = "i32" },
            .{ .name = "ordinal", .type_name = "u64" },
            .{ .name = "id", .type_name = "u64" },
        },
    },
    // The build contracts. `@BuildSink` is a protocol, so it has no field
    // shape; `@BuildShape` is a fact record the compiler synthesizes values of.
    .{ .name = "@BuildSink", .module = "modules/fluent.sx" },
    .{
        .name = "@BuildShape",
        .module = "modules/fluent.sx",
        .fields = &.{
            .{ .name = "static_expressions", .type_name = "i32" },
            .{ .name = "dynamic_regions", .type_name = "i32" },
            .{ .name = "known_bytes", .type_name = "?i64" },
            .{ .name = "max_alignment", .type_name = "i64" },
        },
    },
    // Formed, never declared.
    .{
        .name = "@Init",
        .kind = .compiler_formed,
        .spelling = "@Init(T)",
        .bound_only = true,
        .bound_spelling = "$I/@Init(T)",
    },
    .{
        .name = "@BuildBlock",
        .kind = .compiler_formed,
        .spelling = "@BuildBlock(P)",
        .bound_only = true,
        .bound_spelling = "$B/@BuildBlock(P)",
    },
};

/// The bound whose type argument the compiler INFERS from the argument an
/// initializer is formed from, so a binder written inside it (`$I/@Init($T)`)
/// is one of the declaration's type parameters.
pub const init_bound = "@Init";

/// The bound naming the trailing-block contract.
pub const build_block_bound = "@BuildBlock";

/// The two open-set DECLARATION heads. A third class of `@` name: neither a
/// stdlib-declared contract nor a formed type, but a declaration form —
/// `P :: @OpenSet(.{…}) { … }` declares the set, `V :: @OpenVariant(P) { … }`
/// declares a member of it.
pub const open_set_head = "@OpenSet";
pub const open_variant_head = "@OpenVariant";

/// True for a name the compiler FORMS. `parseCompilerFormedType` is its only
/// producer, so these names never reach a declaration or a value.
pub fn isCompilerFormed(name: []const u8) bool {
    const c = find(name) orelse return false;
    return c.kind == .compiler_formed;
}

/// Every compiler-formed spelling, joined for the diagnostic that lists them.
pub fn compilerFormedList(alloc: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var n: usize = 0;
    for (entries) |e| {
        if (e.kind != .compiler_formed) continue;
        if (n > 0) try out.appendSlice(alloc, if (n + 1 == compilerFormedCount()) " and " else ", ");
        try out.print(alloc, "'{s}'", .{e.spelling});
        n += 1;
    }
    return out.toOwnedSlice(alloc);
}

pub fn compilerFormedCount() usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.kind == .compiler_formed) n += 1;
    }
    return n;
}

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

test "the @SourceSite shape is the one lowering builds" {
    // `lowerCallerSite` emits these six fields, in this order. Changing either
    // side alone mis-lowers every `@caller`, so the table is the lock.
    const c = find("@SourceSite").?;
    const want = [_]Field{
        .{ .name = "file", .type_name = "string" },
        .{ .name = "declaration", .type_name = "string" },
        .{ .name = "line", .type_name = "i32" },
        .{ .name = "column", .type_name = "i32" },
        .{ .name = "ordinal", .type_name = "u64" },
        .{ .name = "id", .type_name = "u64" },
    };
    try std.testing.expectEqual(want.len, c.fields.len);
    for (want, c.fields) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.type_name, b.type_name);
    }
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
