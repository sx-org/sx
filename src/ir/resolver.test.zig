// Tests for resolver.zig — the shared author-collection layer.
//
// collectVisibleAuthors is exercised over REAL Phase A facts (parse →
// resolveImports → buildImportFacts, the exact path core.zig drives) plus one
// synthetic diamond fixture for pointer-identity dedup. The visibility-adapter
// tests pin the nameVisibleOverEdges edge-walk that isNameVisible /
// isCImportVisible run on top of — the flat-edge set vs the full import_graph.
// resolveBare / resolveQualified tests pin the verdict layer (own_wins / single /
// ambiguous / not_visible / domain_filtered) over real import facts.

const std = @import("std");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const imports = @import("../imports.zig");
const errors = @import("../errors.zig");
const resolver = @import("resolver.zig");
const lower = @import("lower.zig");
const pi = @import("program_index.zig");
const ProgramIndex = pi.ProgramIndex;

var g_test_threaded: ?std.Io.Threaded = null;
fn testIo() std.Io {
    if (g_test_threaded == null) {
        g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_test_threaded.?.io();
}

const Graph = std.StringHashMap(std.StringHashMap(void));

/// Parse `main_path`, resolve its imports, build the raw facts, and ALSO keep
/// the import / flat-import graphs (the collectors need them). `alloc` must be
/// an arena that outlives the returned views.
const Facts = struct {
    decls: imports.ModuleDecls,
    ns_edges: imports.NamespaceEdges,
    import_graph: Graph,
    flat_import_graph: Graph,
};

fn buildFacts(alloc: std.mem.Allocator, io: std.Io, absdir: []const u8, main_path: []const u8) !Facts {
    const main_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, main_path, alloc, .limited(1 << 20));
    const main_source = try alloc.dupeZ(u8, main_bytes);
    var p = parser.Parser.init(alloc, main_source);
    const root = p.parse() catch return error.ParseFailed;

    var diags = errors.DiagnosticList.init(alloc, main_source, main_path);
    var chain = std.StringHashMap(void).init(alloc);
    var cache = imports.ModuleCache.init(alloc);
    var import_graph = Graph.init(alloc);
    var flat_import_graph = Graph.init(alloc);
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
    return .{
        .decls = facts.decls,
        .ns_edges = facts.ns_edges,
        .import_graph = import_graph,
        .flat_import_graph = flat_import_graph,
    };
}

fn tag(ref: resolver.RawDeclRef) std.meta.Tag(resolver.RawDeclRef) {
    return std.meta.activeTag(ref);
}

// ── collectVisibleAuthors ────────────────────────────────────────────────

// own author present; two distinct flat authors both returned RAW; and the
// user_bare_flat edge set EXCLUDES a namespaced-only import (reachable only over
// a non-flat edge).
test "resolver: collectVisibleAuthors — own author, two distinct flat authors, namespaced edge excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.sx", .data = "dup :: () -> i64 { 1 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sx", .data = "dup :: () -> i64 { 2 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "p.sx", .data = "secret :: () -> i64 { 9 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "#import \"a.sx\";\n#import \"b.sx\";\ng :: #import \"p.sx\";\nselfauthored :: () -> i64 { 0 }\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    var facts = try buildFacts(alloc, io, absdir, main_path);

    var idx = ProgramIndex.init(alloc);
    defer idx.deinit();
    idx.module_decls = &facts.decls;
    idx.flat_import_graph = &facts.flat_import_graph;
    idx.import_graph = &facts.import_graph;

    var r = resolver.Resolver.init(&idx, alloc);

    // Own author (declared in main itself).
    const own_set = r.collectVisibleAuthors("selfauthored", main_path, .user_bare_flat);
    try std.testing.expect(own_set.own != null);
    try std.testing.expectEqualStrings(main_path, own_set.own.?.source);
    try std.testing.expectEqual(@as(usize, 0), own_set.flat.len);
    try std.testing.expectEqual(@as(usize, 1), own_set.distinctCount());

    // Two distinct flat authors of `dup` (a.sx and b.sx), returned raw.
    const dup_set = r.collectVisibleAuthors("dup", main_path, .user_bare_flat);
    try std.testing.expect(dup_set.own == null);
    try std.testing.expectEqual(@as(usize, 2), dup_set.flat.len);
    try std.testing.expectEqual(@as(usize, 2), dup_set.distinctCount());
    try std.testing.expectEqual(std.meta.Tag(resolver.RawDeclRef).fn_decl, tag(dup_set.flat[0].raw));
    try std.testing.expectEqual(std.meta.Tag(resolver.RawDeclRef).fn_decl, tag(dup_set.flat[1].raw));
    try std.testing.expect(dup_set.flat[0].raw.fn_decl != dup_set.flat[1].raw.fn_decl);

    // `secret` is authored only in p.sx, imported NAMESPACED (`g :: #import`).
    // user_bare_flat must NOT see it (p.sx is not a flat edge).
    const flat_secret = r.collectVisibleAuthors("secret", main_path, .user_bare_flat);
    try std.testing.expect(flat_secret.own == null);
    try std.testing.expectEqual(@as(usize, 0), flat_secret.flat.len);
}

// Diamond: the SAME author node is reachable over two flat edges. It must
// collapse to a single entry (dedup by author identity), not appear twice.
test "resolver: collectVisibleAuthors — diamond imports of one author dedup to one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // One real fn_decl node, shared between two module indices.
    var body = ast.Node{ .span = .{ .start = 0, .end = 0 }, .data = .intrinsic_expr };
    var shared = ast.Node{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .fn_decl = .{ .name = "shared", .params = &.{}, .return_type = null, .body = &body } },
    };
    const ref = imports.rawDeclRefOf(&shared).?;

    var decls = imports.ModuleDecls.init(alloc);
    inline for (.{ "p1", "p2" }) |path| {
        var names = std.StringHashMap(resolver.RawDeclRef).init(alloc);
        try names.put("shared", ref);
        try decls.put(path, .{ .source = path, .names = names });
    }

    var flat = Graph.init(alloc);
    var from_edges = std.StringHashMap(void).init(alloc);
    try from_edges.put("p1", {});
    try from_edges.put("p2", {});
    try flat.put("from", from_edges);

    var idx = ProgramIndex.init(alloc);
    defer idx.deinit();
    idx.module_decls = &decls;
    idx.flat_import_graph = &flat;

    var r = resolver.Resolver.init(&idx, alloc);
    const set = r.collectVisibleAuthors("shared", "from", .user_bare_flat);
    try std.testing.expect(set.own == null);
    try std.testing.expectEqual(@as(usize, 1), set.flat.len);
    try std.testing.expectEqual(@as(usize, 1), set.distinctCount());
    try std.testing.expectEqual(@intFromPtr(&shared.data.fn_decl), @intFromPtr(set.flat[0].raw.fn_decl));
}

// ── collectNamespaceAuthors ──────────────────────────────────────────────

// Returns a namespace target's members and touches NO graph: the Resolver here
// has no graphs (or module_decls) wired at all, yet the member is found.
test "resolver: collectNamespaceAuthors — returns target members, walks no graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "point.sx", .data = "Point :: struct { x: i64 }\nhelper :: () -> i64 { 0 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "g :: #import \"point.sx\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});
    // Imported modules are keyed by their CANONICAL path (issue 0148), so the
    // expected key goes through the same chokepoint.
    const point_path = try imports.canonicalizePath(alloc, try std.fmt.allocPrint(alloc, "{s}/point.sx", .{absdir}));

    var facts = try buildFacts(alloc, io, absdir, main_path);

    const aliases = facts.ns_edges.get(main_path) orelse return error.MissingNsEdges;
    const target = aliases.get("g") orelse return error.MissingAlias;
    try std.testing.expectEqualStrings(point_path, target.target_module_path);

    // A Resolver over an EMPTY index — no module_decls, no graphs. If
    // collectNamespaceAuthors touched a graph it would crash / miss; it doesn't.
    var idx = ProgramIndex.init(alloc);
    defer idx.deinit();
    try std.testing.expect(idx.flat_import_graph == null);
    try std.testing.expect(idx.import_graph == null);
    var r = resolver.Resolver.init(&idx, alloc);

    const pt = r.collectNamespaceAuthors(target, "Point");
    try std.testing.expect(pt.own != null);
    try std.testing.expectEqual(std.meta.Tag(resolver.RawDeclRef).struct_decl, tag(pt.own.?.raw));
    try std.testing.expectEqualStrings(point_path, pt.own.?.source);
    try std.testing.expectEqual(@as(usize, 0), pt.flat.len);

    const hp = r.collectNamespaceAuthors(target, "helper");
    try std.testing.expect(hp.own != null);
    try std.testing.expectEqual(std.meta.Tag(resolver.RawDeclRef).fn_decl, tag(hp.own.?.raw));

    const miss = r.collectNamespaceAuthors(target, "Missing");
    try std.testing.expect(miss.own == null);
    try std.testing.expectEqual(@as(usize, 0), miss.distinctCount());
}

// ── visibility predicate (the isNameVisible / isCImportVisible core) ──────

// nameVisibleOverEdges is the edge-walk isVisible(.user_bare_flat) runs on (the
// flat graph). Walked over the flat set vs the full import_graph, the two agree
// on own + flat names and differ ONLY on a namespaced-only name — the flat set
// the bare-name predicate uses, contrasted with the over-permissive full set.
test "resolver: visibility edge-walk — own + flat visible; namespaced-only only under import_graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var scopes = Graph.init(alloc);
    inline for (.{
        .{ "main", &[_][]const u8{ "selfauthored", "g" } },
        .{ "a", &[_][]const u8{"dup"} },
        .{ "p", &[_][]const u8{"secret"} },
    }) |entry| {
        var s = std.StringHashMap(void).init(alloc);
        for (entry[1]) |n| try s.put(n, {});
        try scopes.put(entry[0], s);
    }

    // Flat graph: main flat-imports a only. Import graph: main reaches a + p.
    var flat = Graph.init(alloc);
    var flat_edges = std.StringHashMap(void).init(alloc);
    try flat_edges.put("a", {});
    try flat.put("main", flat_edges);

    var all = Graph.init(alloc);
    var all_edges = std.StringHashMap(void).init(alloc);
    try all_edges.put("a", {});
    try all_edges.put("p", {});
    try all.put("main", all_edges);

    // Own-scope name: visible regardless of edge set.
    try std.testing.expect(lower.nameVisibleOverEdges(&scopes, &flat, "main", "selfauthored"));
    try std.testing.expect(lower.nameVisibleOverEdges(&scopes, &all, "main", "selfauthored"));

    // Flat-imported name: visible under both (the flat edge is in both graphs).
    try std.testing.expect(lower.nameVisibleOverEdges(&scopes, &flat, "main", "dup"));
    try std.testing.expect(lower.nameVisibleOverEdges(&scopes, &all, "main", "dup"));

    // Namespaced-only name: NOT visible under the flat set (user_bare_flat),
    // but visible under the full import_graph set.
    try std.testing.expect(!lower.nameVisibleOverEdges(&scopes, &flat, "main", "secret"));
    try std.testing.expect(lower.nameVisibleOverEdges(&scopes, &all, "main", "secret"));

    // Unknown name: not visible.
    try std.testing.expect(!lower.nameVisibleOverEdges(&scopes, &flat, "main", "nope"));

    // Falls open when scoping infra is unwired (null scopes/graph).
    try std.testing.expect(lower.nameVisibleOverEdges(null, &flat, "main", "secret"));
    try std.testing.expect(lower.nameVisibleOverEdges(&scopes, null, "main", "secret"));
}

// ── resolveBare ──────────────────────────────────────────────────────────────

// own_wins when the querying module authors the name; single when one flat
// author exists; ambiguous for ≥2 flat authors; not_visible when the name is
// authored only over a namespace edge; domain_filtered for a builtin / local /
// wrong-domain name.
test "resolver: resolveBare — own_wins / single / ambiguous / not_visible / domain_filtered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.sx", .data = "dup :: () -> i64 { 1 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sx", .data = "dup :: () -> i64 { 2 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ns.sx", .data = "secret :: () -> i64 { 9 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data =
        \\#import "a.sx";
        \\#import "b.sx";
        \\g :: #import "ns.sx";
        \\selfauthored :: () -> i64 { 0 }
        \\main :: () -> i32 { 0 }
        \\
    });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    var facts = try buildFacts(alloc, io, absdir, main_path);

    var idx = ProgramIndex.init(alloc);
    defer idx.deinit();
    idx.module_decls = &facts.decls;
    idx.flat_import_graph = &facts.flat_import_graph;
    idx.import_graph = &facts.import_graph;

    var r = resolver.Resolver.init(&idx, alloc);

    // own_wins: selfauthored is authored in main itself
    const own = r.resolveBare("selfauthored", main_path, .callable);
    try std.testing.expectEqual(resolver.Verdict.own_wins, own.verdict);
    try std.testing.expect(own.set.own != null);

    // ambiguous: dup is authored in both a.sx and b.sx
    const amb = r.resolveBare("dup", main_path, .callable);
    try std.testing.expectEqual(resolver.Verdict.ambiguous, amb.verdict);

    // not_visible: secret is authored in ns.sx (namespaced-only import)
    const nv = r.resolveBare("secret", main_path, .callable);
    try std.testing.expectEqual(resolver.Verdict.not_visible, nv.verdict);

    // domain_filtered: selfauthored exists but is not a type author
    const df = r.resolveBare("selfauthored", main_path, .bare_type);
    try std.testing.expectEqual(resolver.Verdict.domain_filtered, df.verdict);

    // domain_filtered with empty set: i64 is a builtin, no user author
    const builtin = r.resolveBare("i64", main_path, .bare_type);
    try std.testing.expectEqual(resolver.Verdict.domain_filtered, builtin.verdict);
    try std.testing.expectEqual(@as(usize, 0), builtin.set.distinctCount());
}

// ── resolveQualified ─────────────────────────────────────────────────────────

test "resolver: resolveQualified — single for existing member, domain_filtered for missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = testIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "point.sx", .data = "Point :: struct { x: i64 }\nhelper :: () -> i64 { 0 }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = "g :: #import \"point.sx\";\nmain :: () -> i32 { 0 }\n" });

    var dirbuf: [4096]u8 = undefined;
    const absdir = dirbuf[0..try tmp.dir.realPath(io, &dirbuf)];
    const main_path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{absdir});

    var facts = try buildFacts(alloc, io, absdir, main_path);

    var idx = ProgramIndex.init(alloc);
    defer idx.deinit();
    idx.module_decls = &facts.decls;
    idx.flat_import_graph = &facts.flat_import_graph;
    idx.namespace_edges = &facts.ns_edges;

    var r = resolver.Resolver.init(&idx, alloc);

    const aliases = facts.ns_edges.get(main_path) orelse return error.MissingNsEdges;
    const target = aliases.get("g") orelse return error.MissingAlias;

    // Point is a struct — namespace_member eligible
    const pt = r.resolveQualified(target, "Point");
    try std.testing.expectEqual(resolver.Verdict.single, pt.verdict);
    try std.testing.expect(pt.set.own != null);
    try std.testing.expectEqual(
        std.meta.Tag(resolver.RawDeclRef).struct_decl,
        std.meta.activeTag(pt.set.own.?.raw),
    );
    try std.testing.expectEqual(@as(usize, 0), pt.set.flat.len);

    // helper is a fn — namespace_member eligible
    const hp = r.resolveQualified(target, "helper");
    try std.testing.expectEqual(resolver.Verdict.single, hp.verdict);

    // Missing member → domain_filtered with empty set
    const miss = r.resolveQualified(target, "Missing");
    try std.testing.expectEqual(resolver.Verdict.domain_filtered, miss.verdict);
    try std.testing.expectEqual(@as(usize, 0), miss.set.distinctCount());
}
