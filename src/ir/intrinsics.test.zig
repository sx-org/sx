//! The registry's one-to-one invariant, checked against the real library
//! sources rather than a second hardcoded list — a test that restates the table
//! would pass no matter how far the table drifted from the sx it describes.
//!
//!   * every `Id` has exactly one entry;
//!   * every entry's (module, name) names a real `@` declaration;
//!   * every `@` declaration in the library has an entry.
//!
//! The third check is the one that bites: adding `@foo :: () -> i64;`
//! to std/core.sx without registering it fails here, instead of silently
//! reaching a dispatch site that has no arm for it.

const std = @import("std");
const intrinsics = @import("intrinsics.zig");

/// The library tree, injected as an absolute path at configure time (build.zig)
/// so the scan is CWD-independent. The FILE LIST is walked at test time, so a
/// new intrinsic declaration is covered with no edit here.
const corpus_paths = @import("corpus_paths");
const library_root = corpus_paths.library_dir;

test "every Id has exactly one entry" {
    inline for (@typeInfo(intrinsics.Id).@"enum".fields) |f| {
        const id: intrinsics.Id = @enumFromInt(f.value);
        var seen: usize = 0;
        for (&intrinsics.entries) |*e| {
            if (e.id == id) seen += 1;
        }
        if (seen != 1) {
            std.debug.print("intrinsic id '{s}': expected 1 entry, found {d}\n", .{ f.name, seen });
            return error.RegistryIdWithoutEntry;
        }
    }
}

test "entry name matches its Id tag" {
    // The Id tag and the declared sx name are kept identical so a reader can go
    // from a diagnostic to the declaration without consulting the table.
    for (&intrinsics.entries) |*e| {
        try std.testing.expectEqualStrings(@tagName(e.id), e.name);
    }
}

test "intrinsic names are globally unique" {
    // Call sites dispatch on the declared name alone (`findByName`). That is only
    // sound while no two modules declare the same intrinsic name — if they ever
    // did, the call-site dispatch would silently pick one. Fail here instead.
    for (&intrinsics.entries, 0..) |*a, i| {
        for (intrinsics.entries[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                std.debug.print("intrinsic name '{s}' declared by both {s} and {s};" ++
                    " call-site dispatch keys off the bare name and cannot tell them apart\n", .{ a.name, a.module, b.module });
                return error.AmbiguousIntrinsicName;
            }
        }
    }
}

test "no duplicate binding keys" {
    for (&intrinsics.entries, 0..) |*a, i| {
        for (intrinsics.entries[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.module, b.module)) {
                std.debug.print("duplicate binding key: {s}.{s}\n", .{ a.module, a.name });
                return error.DuplicateBindingKey;
            }
        }
    }
}

/// Collect `@name :: ...;` declarations out of an sx source.
///
/// Statement-based, NOT line-based: a declaration may wrap across lines, as
/// compiler.sx's `@link` does. A line-based scan silently misses those — and
/// missing one means the test PASSES for an unregistered intrinsic, which is the
/// exact failure this file exists to prevent.
///
/// Comments are stripped first so prose in core.sx is never mistaken for a
/// declaration.
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn collectDecls(
    alloc: std.mem.Allocator,
    src: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    // Strip `//` line comments, keeping newlines so statements stay separated.
    var stripped: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.indexOf(u8, raw, "//")) |i| raw[0..i] else raw;
        try stripped.appendSlice(alloc, line);
        try stripped.append(alloc, '\n');
    }

    // A `{` or `}` ends a statement too, so a struct head and its closing brace
    // stand alone and the members of an `@` struct sit between them.
    var split: std.ArrayList(u8) = .empty;
    for (stripped.items) |c| {
        try split.append(alloc, c);
        if (c == '{' or c == '}') try split.append(alloc, ';');
    }

    // The `@` struct whose body is open, if any: its bodyless members are
    // intrinsic methods registered as `@Struct.member`.
    var at_struct: ?[]const u8 = null;
    var depth: usize = 0;
    var stmts = std.mem.splitScalar(u8, split.items, ';');
    while (stmts.next()) |raw| {
        const stmt = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.endsWith(u8, stmt, "}")) {
            depth -|= 1;
            if (depth == 0) at_struct = null;
        }
        const opens = std.mem.endsWith(u8, stmt, "{");
        defer if (opens) {
            depth += 1;
        };
        // The LAST `::`: a chunk may still carry a preceding declaration that
        // ended in neither `;` nor a brace.
        const colons = std.mem.lastIndexOf(u8, stmt, "::") orelse continue;
        // The declared name is the last identifier before that `::`, with its
        // `@` sigil when it has one — the sigil is part of the registered name.
        const head = std.mem.trimEnd(u8, stmt[0..colons], " \t\r\n");
        var start: usize = head.len;
        while (start > 0 and isIdentChar(head[start - 1])) start -= 1;
        if (start > 0 and head[start - 1] == '@') start -= 1;
        const name = head[start..];
        if (name.len == 0) continue;
        const tail = std.mem.trimStart(u8, stmt[colons + 2 ..], " \t\r\n");
        if (opens and depth == 0 and name[0] == '@' and std.mem.startsWith(u8, tail, "struct")) {
            at_struct = name;
            continue;
        }
        // A `(` past the `::` is what makes a declaration a FUNCTION, and a `{`
        // body means its implementation is the sx source, not the compiler. An
        // `@` type contract opens with the `struct` or `protocol` keyword, so it
        // does not match and is not the intrinsic registry's to hold.
        if (opens or !std.mem.startsWith(u8, tail, "(")) continue;
        if (name[0] == '@') {
            try out.append(alloc, try alloc.dupe(u8, name));
        } else if (at_struct) |owner| {
            if (depth == 1) try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}.{s}", .{ owner, name }));
        }
    }
}

test "collectDecls keeps the `@` sigil, which is part of the registered name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList([]const u8).empty;
    try collectDecls(arena.allocator(),
        \\@buildOptions :: () -> BuildOptions;
        \\@volatileLoad :: ($T: Type, address: *T) -> T;
    , &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("@buildOptions", out.items[0]);
    try std.testing.expectEqualStrings("@volatileLoad", out.items[1]);
}

test "collectDecls takes an `@` function by its signature and leaves `@` type contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList([]const u8).empty;
    try collectDecls(arena.allocator(),
        \\@VaList :: struct {
        \\}
        \\@vaStart :: (list: *@VaList);
        \\@BuildSink :: constraint(P: Type) {
        \\}
        \\@vaArg :: ($T: Type, list: *@VaList) -> T;
    , &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("@vaStart", out.items[0]);
    try std.testing.expectEqualStrings("@vaArg", out.items[1]);
}

test "collectDecls leaves an `@` function whose body is sx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList([]const u8).empty;
    try collectDecls(arena.allocator(),
        \\@panic :: (msg: string) -> noreturn {
        \\    @printf("{}", msg);
        \\    c.abort()
        \\}
        \\@vaEnd :: (list: *@VaList);
    , &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("@vaEnd", out.items[0]);
}

test "collectDecls registers a bodyless member of an `@` struct as `@Struct.member`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList([]const u8).empty;
    try collectDecls(arena.allocator(),
        \\@Handle :: struct {
        \\    isMacos :: (self: *@Handle) -> bool;
        \\    plain :: (self: *@Handle) -> i32 { 1 }
        \\}
        \\@buildOptions :: () -> @Handle;
        \\Plain :: struct {
        \\    alias :: (a: i32, b: i32);
        \\}
    , &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("@Handle.isMacos", out.items[0]);
    try std.testing.expectEqualStrings("@buildOptions", out.items[1]);
}

var g_threaded: ?std.Io.Threaded = null;
fn testIo() std.Io {
    if (g_threaded == null) g_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

/// Recursively scan `dir_abs` for `.sx` files, collecting their intrinsic
/// declarations. Recurses because the declarations live at several depths
/// (modules/std/core.sx, modules/math/scalar.sx, …) and a new one must be
/// caught wherever it lands.
fn scanDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_abs: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // Collect names first, then act — mutating/reading while the dir handle is
    // mid-iteration is the pattern the corpus runner avoids too.
    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            try dirs.append(alloc, try alloc.dupe(u8, entry.name));
        } else if (std.mem.endsWith(u8, entry.name, ".sx")) {
            try files.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }

    for (files.items) |f| {
        const path = try std.fs.path.join(alloc, &.{ dir_abs, f });
        const src = std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(4 << 20)) catch continue;
        try collectDecls(alloc, src, out);
    }
    for (dirs.items) |d| {
        try scanDir(alloc, io, try std.fs.path.join(alloc, &.{ dir_abs, d }), out);
    }
}

fn scanLibrary(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    try scanDir(alloc, testIo(), library_root, out);
}

test "every intrinsic declaration in the library is registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var declared = std.ArrayList([]const u8).empty;
    try scanLibrary(alloc, &declared);

    // A library with no intrinsic declarations means the scan broke, not that
    // the invariant holds — fail rather than pass vacuously.
    try std.testing.expect(declared.items.len > 0);

    var missing: usize = 0;
    for (declared.items) |name| {
        if (intrinsics.find(name, null) == null) {
            std.debug.print("unregistered intrinsic declaration: '{s}'\n", .{name});
            missing += 1;
        }
    }
    if (missing != 0) return error.UnregisteredIntrinsicDeclaration;

    // …and the converse: an entry naming a declaration that does not exist.
    for (&intrinsics.entries) |*e| {
        var found = false;
        for (declared.items) |name| {
            if (std.mem.eql(u8, name, e.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("registry entry '{s}' has no sx declaration\n", .{e.name});
            return error.RegistryEntryWithoutDeclaration;
        }
    }
}

test "registry count matches the library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var declared = std.ArrayList([]const u8).empty;
    try scanLibrary(arena.allocator(), &declared);
    try std.testing.expectEqual(intrinsics.entries.len, declared.items.len);
}
