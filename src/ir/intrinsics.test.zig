//! The registry's one-to-one invariant, checked against the real library
//! sources rather than a second hardcoded list — a test that restates the table
//! would pass no matter how far the table drifted from the sx it describes.
//!
//!   * every `Id` has exactly one entry;
//!   * every entry's (module, name) names a real `intrinsic` declaration;
//!   * every `intrinsic` declaration in the library has an entry.
//!
//! The third check is the one that bites: adding `foo :: () -> i64 intrinsic;`
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

/// Collect `name :: ... intrinsic;` declarations out of an sx source.
///
/// Statement-based, NOT line-based: a declaration may wrap across lines, as
/// compiler.sx's `link` does. A line-based scan silently misses those — and
/// missing one means the test PASSES for an unregistered intrinsic, which is the
/// exact failure this file exists to prevent.
///
/// Comments are stripped first so prose in core.sx ("// sqrt :: (x: $T) -> T
/// intrinsic;") is never mistaken for a declaration.
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

    // Each `;` ends a statement. A declaration whose body is the bare
    // `intrinsic` keyword ends with `... intrinsic`.
    var stmts = std.mem.splitScalar(u8, stripped.items, ';');
    while (stmts.next()) |raw| {
        const stmt = std.mem.trim(u8, raw, " \t\r\n");
        if (!std.mem.endsWith(u8, stmt, "intrinsic")) continue;
        // The LAST `::`, not the first: splitting on `;` means this chunk may
        // carry whole preceding declarations that never ended in one (e.g.
        // build.sx's `BuildOptions :: struct { }` sits directly above
        // `build_options :: () -> BuildOptions intrinsic;`). Taking the first
        // `::` would name the wrong declaration.
        const colons = std.mem.lastIndexOf(u8, stmt, "::") orelse continue;
        // The declared name is the last identifier before that `::`.
        const head = std.mem.trimEnd(u8, stmt[0..colons], " \t\r\n");
        var start: usize = head.len;
        while (start > 0 and isIdentChar(head[start - 1])) start -= 1;
        const name = head[start..];
        if (name.len == 0) continue;
        try out.append(alloc, try alloc.dupe(u8, name));
    }
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

    // …and the converse: an entry naming a declaration that no longer exists.
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
