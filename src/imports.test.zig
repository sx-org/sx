// Tests for imports.zig — flat-import name-resolution data retention.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const imports = @import("imports.zig");
const errors = @import("errors.zig");

var g_test_threaded: ?std.Io.Threaded = null;
fn testIo() std.Io {
    if (g_test_threaded == null) {
        g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_test_threaded.?.io();
}

// ── buildImportFacts unit tests (Phase A: import-side raw facts) ──

const Facts = struct {
    decls: imports.ModuleDecls,
    ns_edges: imports.NamespaceEdges,
    diags: errors.DiagnosticList,
};

/// Parse `main_path`, resolve its imports, then build the raw import facts —
/// the exact path `core.zig` drives. `alloc` must be an arena that outlives the
/// returned views (they point into AST + cache memory it owns).
fn buildFacts(alloc: std.mem.Allocator, io: std.Io, absdir: []const u8, main_path: []const u8) !Facts {
    const main_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, main_path, alloc, .limited(1 << 20));
    const main_source = try alloc.dupeZ(u8, main_bytes);
    var p = parser.Parser.init(alloc, main_source);
    const root = p.parse() catch return error.ParseFailed;

    var diags = errors.DiagnosticList.init(alloc, main_source, main_path);
    var chain = std.StringHashMap(void).init(alloc);
    var cache = imports.ModuleCache.init(alloc);
    var import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    var flat_import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    const stdlib_paths = [_][]const u8{};

    const mod = try imports.resolveImports(
        alloc,
        io,
        root,
        absdir,
        main_path,
        &chain,
        &cache,
        null,
        &diags,
        &stdlib_paths,
        &import_graph,
        &flat_import_graph,
        .{},
    );

    const facts = try imports.buildImportFacts(alloc, main_path, mod, &cache);
    return .{ .decls = facts.decls, .ns_edges = facts.ns_edges, .diags = diags };
}

fn expectTag(ref: imports.RawDeclRef, expected: std.meta.Tag(imports.RawDeclRef)) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(ref));
}

fn hasErr(diags: *const errors.DiagnosticList, needle: []const u8) bool {
    for (diags.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

// Two flat-imported modules each author `greet`; a third is namespaced. The
// raw facts retain BOTH `greet` authors under their own paths in `module_decls`
// (function authors flow through it) and record the namespaced import in
// `import_graph` but NOT in `flat_import_graph` — WITHOUT touching the merged
// scope: `mod.decls` stays byte-for-byte first-wins (one `greet`, a.sx's).
test "imports: module_decls retains same-name cross-module fns; flat_import_graph excludes namespaced edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.sx", .data = "greet :: () -> i64 { 1 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sx", .data = "greet :: () -> i64 { 2 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nsmod.sx", .data = "helper :: () -> i64 { 3 }\n" });
    const main_src =
        \\#import "a.sx";
        \\#import "b.sx";
        \\ns :: #import "nsmod.sx";
        \\main :: () -> i32 { 0 }
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = main_src });

    var dirbuf: [4096]u8 = undefined;
    const dirlen = try tmp.dir.realPath(io, &dirbuf);
    const absdir = dirbuf[0..dirlen];

    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    // Imported modules are keyed by their CANONICAL path (issue 0148) — e.g.
    // re-relativized against the CWD when the tmp dir lives under it — so the
    // expected keys go through the same chokepoint. `main_path` stays as
    // passed: the entry is keyed literally.
    const a_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/a.sx", .{absdir}));
    const b_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/b.sx", .{absdir}));
    const ns_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/nsmod.sx", .{absdir}));

    const main_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, main_path, alloc, .limited(1 << 20));
    const main_source = try alloc.dupeZ(u8, main_bytes);
    var p = parser.Parser.init(alloc, main_source);
    const root = p.parse() catch return error.ParseFailed;

    var chain = std.StringHashMap(void).init(alloc);
    var cache = imports.ModuleCache.init(alloc);
    var import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    var flat_import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    const stdlib_paths = [_][]const u8{};

    const mod = try imports.resolveImports(
        alloc,
        io,
        root,
        absdir,
        main_path,
        &chain,
        &cache,
        null,
        null,
        &stdlib_paths,
        &import_graph,
        &flat_import_graph,
        .{},
    );

    var facts = try imports.buildImportFacts(alloc, main_path, mod, &cache);

    // The MERGED scope the first-wins resolver consumes is unchanged: mergeFlat
    // still drops the second `greet`, so `mod.decls` carries exactly ONE — and
    // it is a.sx's author (the first flat import), not b.sx's.
    var greet_count: usize = 0;
    var merged_greet: ?*const ast.FnDecl = null;
    for (mod.decls) |decl| {
        const name = decl.data.declName() orelse continue;
        if (!std.mem.eql(u8, name, "greet")) continue;
        greet_count += 1;
        if (decl.data == .fn_decl) merged_greet = &decl.data.fn_decl;
    }
    try std.testing.expectEqual(@as(usize, 1), greet_count);

    // module_decls retains BOTH authors of `greet`, keyed by their own paths —
    // the dropped author is recorded here (side index), not in the merged scope.
    const a_idx = facts.decls.get(a_path) orelse return error.MissingAIndex;
    const b_idx = facts.decls.get(b_path) orelse return error.MissingBIndex;
    const a_greet = switch (a_idx.names.get("greet") orelse return error.MissingAGreet) {
        .fn_decl => |fd| fd,
        else => return error.AGreetNotFn,
    };
    const b_greet = switch (b_idx.names.get("greet") orelse return error.MissingBGreet) {
        .fn_decl => |fd| fd,
        else => return error.BGreetNotFn,
    };
    // Distinct authoring decls — not the same node deduped down to one.
    try std.testing.expect(a_greet != b_greet);
    // First-wins: the surviving merged-scope `greet` is a.sx's author.
    try std.testing.expect(merged_greet == a_greet);

    // flat_import_graph carries the two bare `#import` edges, NOT the
    // namespaced `ns :: #import` edge.
    const flat = flat_import_graph.get(main_path) orelse return error.MissingFlatEdges;
    try std.testing.expect(flat.contains(a_path));
    try std.testing.expect(flat.contains(b_path));
    try std.testing.expect(!flat.contains(ns_path));

    // The full import_graph DOES record the namespaced edge (the contrast that
    // makes the flat-graph exclusion meaningful).
    const full = import_graph.get(main_path) orelse return error.MissingFullEdges;
    try std.testing.expect(full.contains(a_path));
    try std.testing.expect(full.contains(b_path));
    try std.testing.expect(full.contains(ns_path));
}

// Mixed collision: a.sx authors `Widget` as a STRUCT (non-fn), b.sx authors it
// as a FUNCTION. The function-author retention must NOT shift the
// merged scope — first-wins keeps a.sx's struct and drops b.sx's function.
// (The fn author may still be indexed in `module_decls`; resolution is what
// must be untouched.)
test "imports: mixed non-fn/fn same-name collision stays first-wins in merged scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.sx", .data = "Widget :: struct { x: i64 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sx", .data = "Widget :: () -> i64 { 7 }\n" });
    const main_src =
        \\#import "a.sx";
        \\#import "b.sx";
        \\main :: () -> i32 { 0 }
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = main_src });

    var dirbuf: [4096]u8 = undefined;
    const dirlen = try tmp.dir.realPath(io, &dirbuf);
    const absdir = dirbuf[0..dirlen];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    const main_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, main_path, alloc, .limited(1 << 20));
    const main_source = try alloc.dupeZ(u8, main_bytes);
    var p = parser.Parser.init(alloc, main_source);
    const root = p.parse() catch return error.ParseFailed;

    var chain = std.StringHashMap(void).init(alloc);
    var cache = imports.ModuleCache.init(alloc);
    var import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    var flat_import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    const stdlib_paths = [_][]const u8{};

    const mod = try imports.resolveImports(
        alloc,
        io,
        root,
        absdir,
        main_path,
        &chain,
        &cache,
        null,
        null,
        &stdlib_paths,
        &import_graph,
        &flat_import_graph,
        .{},
    );

    // Exactly ONE `Widget` survives the merged scope, and it is a.sx's STRUCT —
    // the function author did not displace or duplicate it.
    var widget_count: usize = 0;
    var merged_is_struct = false;
    for (mod.decls) |decl| {
        const name = decl.data.declName() orelse continue;
        if (!std.mem.eql(u8, name, "Widget")) continue;
        widget_count += 1;
        merged_is_struct = decl.data == .struct_decl;
    }
    try std.testing.expectEqual(@as(usize, 1), widget_count);
    try std.testing.expect(merged_is_struct);
}

// Flat imports: each module's authored decls land in ITS OWN scalar index keyed
// by path. Two modules authoring the same `fn`, the same `struct`, and a
// value-vs-type same spelling are ALL retained per-source — no cross-module
// first-wins at the index level. A `const_decl` is stored raw (`.const_decl`),
// not pre-classified into value/fn.
test "buildImportFacts: flat imports keep same-name fn/struct + value-vs-type per source; const stays raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // a.sx: dup() fn, Box struct, Shape as a VALUE const.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.sx", .data = "dup :: () -> i64 { 1 }\nBox :: struct { x: i64 }\nShape :: 7;\n" });
    // b.sx: dup() fn, Box struct, Shape as a TYPE (same spelling as a.sx's value).
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sx", .data = "dup :: () -> i64 { 2 }\nBox :: struct { y: i64 }\nShape :: struct { z: i64 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "#import \"a.sx\";\n#import \"b.sx\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    // Canonical keys for imported modules (issue 0148).
    const a_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/a.sx", .{absdir}));
    const b_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/b.sx", .{absdir}));

    var facts = try buildFacts(alloc, io, absdir, main_path);

    const a_idx = facts.decls.get(a_path) orelse return error.MissingAIndex;
    const b_idx = facts.decls.get(b_path) orelse return error.MissingBIndex;
    const m_idx = facts.decls.get(main_path) orelse return error.MissingMainIndex;

    // The index records its own source path.
    try std.testing.expectEqualStrings(a_path, a_idx.source);

    // main authors `main` as a fn.
    try expectTag(m_idx.names.get("main") orelse return error.MissingMain, .fn_decl);

    // Same-name fn retained per source — two DISTINCT FnDecls.
    const a_dup = a_idx.names.get("dup") orelse return error.MissingADup;
    const b_dup = b_idx.names.get("dup") orelse return error.MissingBDup;
    try expectTag(a_dup, .fn_decl);
    try expectTag(b_dup, .fn_decl);
    try std.testing.expect(a_dup.fn_decl != b_dup.fn_decl);

    // Same-name struct retained per source — two DISTINCT StructDecls.
    const a_box = a_idx.names.get("Box") orelse return error.MissingABox;
    const b_box = b_idx.names.get("Box") orelse return error.MissingBBox;
    try expectTag(a_box, .struct_decl);
    try expectTag(b_box, .struct_decl);
    try std.testing.expect(a_box.struct_decl != b_box.struct_decl);

    // Value-vs-type same spelling across modules: a.sx's `Shape` is a raw const
    // (NOT pre-classified), b.sx's `Shape` is a struct. Both coexist by source.
    try expectTag(a_idx.names.get("Shape") orelse return error.MissingAShape, .const_decl);
    try expectTag(b_idx.names.get("Shape") orelse return error.MissingBShape, .struct_decl);

    // No spurious diagnostics — these are distinct files, not same-module dups.
    try std.testing.expect(!hasErr(&facts.diags, "duplicate top-level"));
}

// Directory import: the combined module (keyed by the directory path) carries
// the UNION of every file's authored decls in its scalar index.
test "buildImportFacts: directory import unions member-file decls under the dir path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/one.sx", .data = "from_one :: () -> i64 { 1 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/two.sx", .data = "Two :: struct { v: i64 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "#import \"lib\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    // Canonical key for the imported directory module (issue 0148).
    const lib_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/lib", .{absdir}));

    var facts = try buildFacts(alloc, io, absdir, main_path);

    const lib_idx = facts.decls.get(lib_path) orelse return error.MissingLibIndex;
    try expectTag(lib_idx.names.get("from_one") orelse return error.MissingFromOne, .fn_decl);
    try expectTag(lib_idx.names.get("Two") orelse return error.MissingTwo, .struct_decl);
}

// Namespaced file import (`g :: #import "point.sx"`): recorded as a namespace
// edge whose `target_module_path` is the aliased file (the fact lost today),
// AND as a `.namespace_decl` in the importer's scalar index.
test "buildImportFacts: namespaced file import captures target_module_path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "point.sx", .data = "Point :: struct { x: i64 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "g :: #import \"point.sx\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    // Canonical key for the imported module (issue 0148).
    const point_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/point.sx", .{absdir}));

    var facts = try buildFacts(alloc, io, absdir, main_path);

    const main_edges = facts.ns_edges.get(main_path) orelse return error.MissingMainEdges;
    const g = main_edges.get("g") orelse return error.MissingGEdge;
    try std.testing.expectEqualStrings("g", g.alias);
    try std.testing.expectEqualStrings(main_path, g.importer_source);
    try std.testing.expectEqualStrings(point_path, g.target_module_path);
    try std.testing.expect(g.own_decls.len >= 1);

    // The alias is also a `.namespace_decl` in the importer's scalar index.
    const m_idx = facts.decls.get(main_path) orelse return error.MissingMainIndex;
    try expectTag(m_idx.names.get("g") orelse return error.MissingGRef, .namespace_decl);
}

// Namespaced directory import: same edge capture, target is the directory path.
test "buildImportFacts: namespaced directory import captures dir path as target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/m.sx", .data = "helper :: () -> i64 { 9 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "pkg :: #import \"pkg\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    // Canonical key for the imported directory module (issue 0148).
    const pkg_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/pkg", .{absdir}));

    var facts = try buildFacts(alloc, io, absdir, main_path);

    const main_edges = facts.ns_edges.get(main_path) orelse return error.MissingMainEdges;
    const pkg = main_edges.get("pkg") orelse return error.MissingPkgEdge;
    try std.testing.expectEqualStrings(pkg_path, pkg.target_module_path);
}

// C-import namespace (`c :: #import c { #include ... }`): recorded as a namespace
// edge. With no separate sx module, the target is the importing file itself.
test "buildImportFacts: c-import namespace recorded as an edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "ch.h", .data = "int cm_add(int a, int b);\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "cmod :: #import c {\n    #include \"ch.h\";\n};\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    var facts = try buildFacts(alloc, io, absdir, main_path);

    const main_edges = facts.ns_edges.get(main_path) orelse return error.MissingMainEdges;
    const cmod = main_edges.get("cmod") orelse return error.MissingCmodEdge;
    try std.testing.expectEqualStrings("cmod", cmod.alias);
    try std.testing.expectEqualStrings(main_path, cmod.target_module_path);

    const m_idx = facts.decls.get(main_path) orelse return error.MissingMainIndex;
    try expectTag(m_idx.names.get("cmod") orelse return error.MissingCmodRef, .namespace_decl);
}

// Duplicate-name invariant (R5 #2): a same-module authored duplicate top-level
// name is DIAGNOSED, not silently dropped. The parser/decl-checker does not
// catch this today (verified: `sx run` of a same-file double decl exits 0 with
// no diagnostic), so `resolveImports` surfaces it where `addOwnDecl` refuses the
// second author. This test FAILS on the pre-diagnostic code and PASSES after.
test "buildImportFacts: same-module duplicate top-level name is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "foo :: () -> i64 { 1 }\nfoo :: () -> i64 { 2 }\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    var facts = try buildFacts(alloc, io, absdir, main_path);

    try std.testing.expect(hasErr(&facts.diags, "duplicate top-level declaration 'foo'"));
    // The surviving author is still in the scalar index (first-wins, not lost).
    const m_idx = facts.decls.get(main_path) orelse return error.MissingMainIndex;
    try expectTag(m_idx.names.get("foo") orelse return error.MissingFoo, .fn_decl);
}

// F1: the duplicate-name invariant must also cover NAMESPACE ALIASES. A
// `dup :: #import "…"` alias colliding with a same-module authored name is a
// duplicate in EITHER order — `addNamespace` (alias second) and `addOwnDecl`
// (alias first) each refuse the second author and the site diagnoses it. Before
// the fix the fn-then-alias order compiled clean (silent first-win in the scalar
// index). Surviving author is whichever came FIRST.
test "buildImportFacts: fn-then-namespace-alias same-module collision is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "lib.sx", .data = "helper :: () -> i64 { 9 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "dup :: () -> i64 { 1 }\ndup :: #import \"lib.sx\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    var facts = try buildFacts(alloc, io, absdir, main_path);

    try std.testing.expect(hasErr(&facts.diags, "duplicate top-level declaration 'dup'"));
    // The fn came first, so it survives in the scalar index; the alias dropped.
    const m_idx = facts.decls.get(main_path) orelse return error.MissingMainIndex;
    try expectTag(m_idx.names.get("dup") orelse return error.MissingDup, .fn_decl);
}

test "buildImportFacts: namespace-alias-then-fn same-module collision is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "lib.sx", .data = "helper :: () -> i64 { 9 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "dup :: #import \"lib.sx\";\ndup :: () -> i64 { 1 }\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    var facts = try buildFacts(alloc, io, absdir, main_path);

    try std.testing.expect(hasErr(&facts.diags, "duplicate top-level declaration 'dup'"));
    // The alias came first, so the namespace_decl survives; the fn dropped.
    const m_idx = facts.decls.get(main_path) orelse return error.MissingMainIndex;
    try expectTag(m_idx.names.get("dup") orelse return error.MissingDup, .namespace_decl);
}

// ── canonicalizePath (issue 0148) ──

// One file, many spellings: absolute (under CWD), cwd-relative, redundant-`./`,
// and `seg/../` all canonicalize to the SAME key. This is the mechanism that
// keeps an absolute entry path from splitting the module cache into two
// identities for the same source file (issue 0148).
test "canonicalizePath: abs + cwd-relative + redundant ./ and .. spellings unify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "mod.sx", .data = "x :: 1;\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];

    const abs_spelling = try std.fmt.allocPrint(alloc, "{s}/mod.sx", .{absdir});
    const canon = try imports.canonicalizePath(alloc, abs_spelling);

    // The tmp dir lives under the test-runner CWD, so the canonical spelling is
    // the cwd-RELATIVE one — the same spelling diagnostics display.
    try std.testing.expect(canon.len > 0);
    try std.testing.expect(canon[0] != '/');

    // Redundant-`./` and `seg/../` variants of the SAME absolute path unify.
    const dotted = try std.fmt.allocPrint(alloc, "{s}/./mod.sx", .{absdir});
    try std.testing.expectEqualStrings(canon, try imports.canonicalizePath(alloc, dotted));
    const upped = try std.fmt.allocPrint(alloc, "{s}/sub/../mod.sx", .{absdir});
    try std.testing.expectEqualStrings(canon, try imports.canonicalizePath(alloc, upped));

    // The cwd-relative spelling is a fixpoint (canonicalizing it changes nothing),
    // and a `./`-prefixed relative spelling collapses to it.
    try std.testing.expectEqualStrings(canon, try imports.canonicalizePath(alloc, canon));
    const rel_dotted = try std.fmt.allocPrint(alloc, "./{s}", .{canon});
    try std.testing.expectEqualStrings(canon, try imports.canonicalizePath(alloc, rel_dotted));
}

// ── DeclTable unit tests (Fork C S1.1) ──

// Every source / imported / namespaced declaration gets a stable DeclId; the
// RawDeclRef → DeclId → AST node round-trip holds; a generic struct is keyable
// by DeclId; and the namespace target records its members' ids. The OLD facts
// (`module_decls` / `ns_edges`) are untouched — the table is built in parallel.
test "buildDeclTable: stable DeclId per decl, round-trip, struct keying, namespace member ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "lib.sx", .data = "helper :: () -> i64 { 9 }\nBox :: struct($T: Type) { v: T; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "geom.sx", .data = "Point :: struct { x: i64 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "#import \"lib.sx\";\ng :: #import \"geom.sx\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    // Canonical key for the imported module (issue 0148).
    const lib_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/lib.sx", .{absdir}));

    const main_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, main_path, alloc, .limited(1 << 20));
    const main_source = try alloc.dupeZ(u8, main_bytes);
    var p = parser.Parser.init(alloc, main_source);
    const root = p.parse() catch return error.ParseFailed;

    var diags = errors.DiagnosticList.init(alloc, main_source, main_path);
    var chain = std.StringHashMap(void).init(alloc);
    var cache = imports.ModuleCache.init(alloc);
    var import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    var flat_import_graph = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    const stdlib_paths = [_][]const u8{};

    const mod = try imports.resolveImports(
        alloc,
        io,
        root,
        absdir,
        main_path,
        &chain,
        &cache,
        null,
        &diags,
        &stdlib_paths,
        &import_graph,
        &flat_import_graph,
        .{},
    );

    var facts = try imports.buildImportFacts(alloc, main_path, mod, &cache);
    var table = try imports.buildDeclTable(alloc, main_path, mod, &cache, &facts.decls, &facts.ns_edges);
    defer table.deinit();

    // Every module author resolves to a DeclId that round-trips to the same node
    // and carries the matching name + source. (verifyRoundTrip also asserts this
    // in Debug; this pins the public lookup API too.)
    var mit = facts.decls.iterator();
    var seen: usize = 0;
    while (mit.next()) |m| {
        var nit = m.value_ptr.names.iterator();
        while (nit.next()) |kv| {
            const ref = kv.value_ptr.*;
            const id = table.declIdForRef(ref) orelse return error.MissingDeclId;
            const info = table.get(id);
            try std.testing.expectEqual(imports.authorNodePtrOf(ref), imports.authorNodePtrOf(info.ref));
            try std.testing.expectEqualStrings(kv.key_ptr.*, info.name);
            try std.testing.expectEqualStrings(m.value_ptr.source, info.source);
            seen += 1;
        }
    }
    try std.testing.expect(seen > 0);

    // The generic struct `Box` (authored in lib.sx) is keyable by DeclId via its
    // inner *StructDecl, and the id reports DeclKind.@"struct" + name "Box".
    const lib_idx = facts.decls.get(lib_path) orelse return error.MissingLibIndex;
    const box_ref = lib_idx.names.get("Box") orelse return error.MissingBox;
    const box_sd = switch (box_ref) {
        .struct_decl => |sd| sd,
        .const_decl => |cd| if (cd.value.data == .struct_decl) &cd.value.data.struct_decl else return error.BoxNotStruct,
        else => return error.BoxNotStruct,
    };
    const box_id = table.declIdForStructDecl(box_sd) orelse return error.BoxNoDeclId;
    try std.testing.expectEqual(imports.DeclKind.@"struct", table.get(box_id).kind);
    try std.testing.expectEqualStrings("Box", table.get(box_id).name);

    // The namespaced `geom.sx` target records its members' DeclIds (here: Point),
    // each round-tripping to a DeclInfo named "Point".
    const aliases = facts.ns_edges.get(main_path) orelse return error.MissingNsEdges;
    const target = aliases.get("g") orelse return error.MissingAlias;
    try std.testing.expect(target.member_ids.len >= 1);
    var found_point = false;
    for (target.member_ids) |id| {
        if (std.mem.eql(u8, table.get(id).name, "Point")) found_point = true;
    }
    try std.testing.expect(found_point);
}

// ── flattenComptimeConditionals unit tests (issue 0194) ──

fn flattenFor(alloc: std.mem.Allocator, source: [:0]const u8, os: []const u8, diags: ?*errors.DiagnosticList) ![]const *ast.Node {
    var p = parser.Parser.init(alloc, source);
    const root = p.parse() catch return error.ParseFailed;
    return imports.flattenComptimeConditionals(
        alloc,
        root.data.root.decls,
        .{ .os = os, .arch = "aarch64" },
        diags,
    );
}

/// Parse `source` and flatten its top-level comptime conditionals for macOS.
fn flattenForMacos(alloc: std.mem.Allocator, source: [:0]const u8, diags: ?*errors.DiagnosticList) ![]const *ast.Node {
    return flattenFor(alloc, source, "macos", diags);
}

test "flatten: top-level target condition supports logical or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\inline if OS == .linux or OS == .android {
        \\    SocketAbi :: struct { family: u16; }
        \\}
    ;
    const android = try flattenFor(alloc, source, "android", null);
    try std.testing.expectEqual(@as(usize, 1), android.len);
    try std.testing.expectEqual(ast.Node.Data.struct_decl, std.meta.activeTag(android[0].data));

    const macos = try flattenFor(alloc, source, "macos", null);
    try std.testing.expectEqual(@as(usize, 0), macos.len);
}

// Regression (issue 0194): a module-level `asm { "tmpl", };` inside a taken
// `inline if OS == { case ... }` arm is statement-parsed as `.asm_expr`; the
// flatten pass must retag the surfaced node to `.asm_global` so lowering's
// global-asm arm emits it (it used to fall into `else => {}` and the symbol
// silently vanished from the object).
test "flatten: wrapped module-level asm surfaces as asm_global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\inline if OS == {
        \\    case .linux: asm { "linux_tmpl", };
        \\    case .macos: asm { "macos_tmpl", };
        \\}
        \\main :: () {}
    ;
    const flat = try flattenForMacos(alloc, source, null);
    try std.testing.expectEqual(@as(usize, 2), flat.len);
    try std.testing.expectEqual(ast.Node.Data.asm_global, std.meta.activeTag(flat[0].data));
    const tmpl = flat[0].data.asm_global.template;
    try std.testing.expectEqualStrings("macos_tmpl", tmpl.data.string_literal.raw);
}

// A `volatile` or operand-carrying asm surfaced to module scope is diagnosed
// (mirrors `parseAsmGlobal`'s top-level restrictions), never silently dropped.
test "flatten: wrapped volatile/operand asm at module scope is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const vol_source: [:0]const u8 =
        \\inline if OS == .macos {
        \\    asm volatile { "tmpl", };
        \\}
    ;
    var vol_diags = errors.DiagnosticList.init(alloc, vol_source, "vol.sx");
    const vol_flat = try flattenForMacos(alloc, vol_source, &vol_diags);
    try std.testing.expectEqual(@as(usize, 0), vol_flat.len);
    try std.testing.expect(hasErr(&vol_diags, "cannot be `volatile`"));

    const ops_source: [:0]const u8 =
        \\inline if OS == .macos {
        \\    asm { "tmpl", "r" = 1 };
        \\}
    ;
    var ops_diags = errors.DiagnosticList.init(alloc, ops_source, "ops.sx");
    const ops_flat = try flattenForMacos(alloc, ops_source, &ops_diags);
    try std.testing.expectEqual(@as(usize, 0), ops_flat.len);
    try std.testing.expect(hasErr(&ops_diags, "no operands, inputs, or clobbers"));
}
