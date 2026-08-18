//! Expected ids are computed by the independent FNV implementation at the
//! bottom of this file, never by calling the code under test — the encoding is
//! normative, so the test states it rather than observing it.

const std = @import("std");
const ast = @import("ast.zig");
const imports = @import("imports.zig");
const Parser = @import("parser.zig").Parser;
const site = @import("source_site.zig");

const Node = ast.Node;

fn parse(alloc: std.mem.Allocator, source: [:0]const u8) ![]const *const Node {
    var p = try Parser.init(alloc, source);
    const root = try p.parse();
    return root.data.root.decls;
}

/// Every indexed site in `declaration`, ordinal-ordered. `only_calls` narrows
/// to the call nodes — the sites `@caller` will substitute at.
fn sitesFiltered(
    alloc: std.mem.Allocator,
    idx: *const site.SiteIndex,
    declaration: []const u8,
    only_calls: bool,
) ![]site.Site {
    var out = std.ArrayList(site.Site).empty;
    var it = idx.sites.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.value_ptr.declaration, declaration)) continue;
        if (only_calls and e.key_ptr.*.data != .call) continue;
        try out.append(alloc, e.value_ptr.*);
    }
    const items = try out.toOwnedSlice(alloc);
    std.mem.sort(site.Site, items, {}, struct {
        fn lt(_: void, a: site.Site, b: site.Site) bool {
            return a.ordinal < b.ordinal;
        }
    }.lt);
    return items;
}

fn sitesOf(alloc: std.mem.Allocator, idx: *const site.SiteIndex, declaration: []const u8) ![]site.Site {
    return sitesFiltered(alloc, idx, declaration, false);
}

fn callSitesOf(alloc: std.mem.Allocator, idx: *const site.SiteIndex, declaration: []const u8) ![]site.Site {
    return sitesFiltered(alloc, idx, declaration, true);
}

fn declarations(alloc: std.mem.Allocator, idx: *const site.SiteIndex) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = idx.prefixes.iterator();
    while (it.next()) |e| try out.append(alloc, e.key_ptr.*);
    const items = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return items;
}

fn hasDeclaration(list: []const []const u8, want: []const u8) bool {
    for (list) |d| if (std.mem.eql(u8, d, want)) return true;
    return false;
}

// ── The ordinal fold ────────────────────────────────────────────────────────

test "an un-expanded ordinal is the lexical index unchanged" {
    try std.testing.expectEqual(@as(u64, 0), site.foldOrdinal(.{ .lexical = 0 }));
    try std.testing.expectEqual(@as(u64, 7), site.foldOrdinal(.{ .lexical = 7 }));
    try std.testing.expectEqual(@as(u64, 4294967295), site.foldOrdinal(.{ .lexical = 4294967295 }));
}

test "an expanded ordinal is tagged and cannot collide with a lexical one" {
    const expanded = site.foldOrdinal(.{ .lexical = 3, .expansions = &.{1} });
    try std.testing.expect(expanded >> 63 == 1);
    // Every un-expanded ordinal is below the tag bit, so the spaces are disjoint.
    try std.testing.expect(site.foldOrdinal(.{ .lexical = 3 }) >> 63 == 0);
    try std.testing.expect(expanded != site.foldOrdinal(.{ .lexical = 3 }));
}

test "the fold reads the path and nothing else" {
    const a = site.foldOrdinal(.{ .lexical = 2, .expansions = &.{ 4, 9 } });
    const b = site.foldOrdinal(.{ .lexical = 2, .expansions = &.{ 4, 9 } });
    try std.testing.expectEqual(a, b);
    // Distinct expansion indices distinguish expanded copies of one site.
    try std.testing.expect(a != site.foldOrdinal(.{ .lexical = 2, .expansions = &.{ 5, 9 } }));
    try std.testing.expect(a != site.foldOrdinal(.{ .lexical = 2, .expansions = &.{4} }));
    // Depth is not flattened: [2,4] and [2,4,0] are different paths.
    try std.testing.expect(site.foldOrdinal(.{ .lexical = 2, .expansions = &.{4} }) !=
        site.foldOrdinal(.{ .lexical = 2, .expansions = &.{ 4, 0 } }));
}

// ── id parity with the normative encoding ───────────────────────────────────

test "computeId matches the documented encoding" {
    try std.testing.expectEqual(refId("a.sx", "m.f", 2), site.computeId("a.sx", "m.f", 2));
    try std.testing.expectEqual(refId("", "", 0), site.computeId("", "", 0));
    try std.testing.expectEqual(refId("modules/std/core.sx", "std.core.exit", 11), site.computeId("modules/std/core.sx", "std.core.exit", 11));
}

test "the stdlib reference vectors" {
    // The same values examples/std/1733 asserts from sx.
    try std.testing.expectEqual(@as(u64, 4144544759707093223), site.computeId("a.sx", "m.f", 2));
    try std.testing.expectEqual(@as(u64, 17245045948168074949), site.computeId("", "", 0));
    try std.testing.expectEqual(@as(u64, 1912229352739503814), site.computeId("a.sx", "m.f", 3));
}

test "a cached prefix folds only the ordinal" {
    const prefix = site.declarationPrefix("a.sx", "m.f");
    for ([_]u64{ 0, 1, 2, 300, 1 << 40 }) |ord| {
        try std.testing.expectEqual(refId("a.sx", "m.f", ord), site.idFromPrefix(prefix, ord));
    }
}

// ── Module path normalization ───────────────────────────────────────────────

test "a library module reports its import path" {
    const roots = [_][]const u8{"/opt/sx/library"};
    try std.testing.expectEqualStrings(
        "modules/std/core.sx",
        site.normalizeModulePath("/opt/sx/library/modules/std/core.sx", &roots, null),
    );
    // A trailing slash on the root is not a different root.
    const slashed = [_][]const u8{"/opt/sx/library/"};
    try std.testing.expectEqualStrings(
        "modules/std/core.sx",
        site.normalizeModulePath("/opt/sx/library/modules/std/core.sx", &slashed, null),
    );
}

test "a path that merely shares a prefix is not stripped" {
    const roots = [_][]const u8{"/opt/sx/lib"};
    try std.testing.expectEqualStrings(
        "/opt/sx/library/modules/std/core.sx",
        site.normalizeModulePath("/opt/sx/library/modules/std/core.sx", &roots, null),
    );
}

test "a root spelled with '..' matches only after canonicalization" {
    // How discovery actually spells a root: built from the exe dir, so it
    // carries `..` hops. Compared raw against a resolved (normalized) file it
    // matches nothing, which is why the roots go through `canonicalizePath`.
    const raw_root = "/opt/sx-test/zig-out/bin/../../library";
    const file = "/opt/sx-test/library/modules/std/core.sx";
    const raw = [_][]const u8{raw_root};
    try std.testing.expectEqualStrings(file, site.normalizeModulePath(file, &raw, null));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const canon = try imports.canonicalizePath(arena.allocator(), raw_root);
    const canon_roots = [_][]const u8{canon};
    try std.testing.expectEqualStrings(
        "modules/std/core.sx",
        site.normalizeModulePath(file, &canon_roots, null),
    );
}

test "the compilation root makes a file invocation-independent" {
    // The same source reached from two cwds: relative under the root, and the
    // absolute spelling. Both strip to one module path, so the id agrees.
    try std.testing.expectEqualStrings(
        "app/main.sx",
        site.normalizeModulePath("proj/app/main.sx", &.{}, "proj"),
    );
    try std.testing.expectEqualStrings(
        "app/main.sx",
        site.normalizeModulePath("/work/proj/app/main.sx", &.{}, "/work/proj"),
    );
}

test "a library root wins over the compilation root" {
    const roots = [_][]const u8{"library"};
    // A stdlib module under the project tree reports its IMPORT path, not its
    // path relative to the main file.
    try std.testing.expectEqualStrings(
        "modules/ui/store.sx",
        site.normalizeModulePath("library/modules/ui/store.sx", &roots, "examples/ui"),
    );
}

test "a non-library file outside the compilation root keeps its spelling" {
    try std.testing.expectEqualStrings(
        "/elsewhere/main.sx",
        site.normalizeModulePath("/elsewhere/main.sx", &.{}, "/work/proj"),
    );
}

test "modulePrefix dots the import path" {
    const p = try site.modulePrefix(std.testing.allocator, "modules/std/core.sx");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("modules.std.core", p);
}

// ── Declaration paths ───────────────────────────────────────────────────────

test "a top-level function is module-qualified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\greet :: () { report(); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const found = try declarations(a, &idx);
    try std.testing.expect(hasDeclaration(found, "app.main.greet"));
}

test "a struct method nests under its type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\Box :: struct {
        \\    n: i64;
        \\    fill :: (self: *Box) { report(); }
        \\}
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const found = try declarations(a, &idx);
    try std.testing.expect(hasDeclaration(found, "app.main.Box.fill"));
}

test "an impl method hangs off the protocol/target pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\impl Ord for i64 {
        \\    less :: (self: *i64, other: i64) -> bool { compare(); }
        \\}
        \\impl Ord for f64 {
        \\    less :: (self: *f64, other: f64) -> bool { compare(); }
        \\}
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const found = try declarations(a, &idx);
    // Same method name on two targets keeps two distinct paths.
    try std.testing.expect(hasDeclaration(found, "app.main.Ord#i64.less"));
    try std.testing.expect(hasDeclaration(found, "app.main.Ord#f64.less"));
}

test "an anonymous closure folds into the nearest named declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\outer :: () {
        \\    f := || { inside(); };
        \\    { nested_block(); }
        \\    direct();
        \\}
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const found = try declarations(a, &idx);
    // One numbering scope: the closure and the bare block add no segment.
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("app.main.outer", found[0]);
    // All three calls — inside the closure, inside the bare block, and direct —
    // are numbered by the one scope, so all three ids are distinct.
    const s = try callSitesOf(a, &idx, "app.main.outer");
    try std.testing.expectEqual(@as(usize, 3), s.len);
    for (s, 0..) |x, i| {
        try std.testing.expectEqualStrings("app.main.outer", x.declaration);
        for (s[i + 1 ..]) |y| {
            try std.testing.expect(x.ordinal != y.ordinal);
            try std.testing.expect(x.id != y.id);
        }
    }
}

test "a generic function keeps one template path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\pick :: (v: $T) -> T { report(); v }
        \\use :: () { pick(1); pick("s"); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const found = try declarations(a, &idx);
    // Two instantiations, one declaration path — the walk never sees them.
    try std.testing.expect(hasDeclaration(found, "app.main.pick"));
    for (found) |d| try std.testing.expect(std.mem.indexOf(u8, d, "__") == null);
    const inner = try callSitesOf(a, &idx, "app.main.pick");
    try std.testing.expectEqual(@as(usize, 1), inner.len);
    // The two `pick(…)` calls live in `use`, and both name one template path.
    const outer = try callSitesOf(a, &idx, "app.main.use");
    try std.testing.expectEqual(@as(usize, 2), outer.len);
    try std.testing.expect(outer[0].id != outer[1].id);
}

// ── Ordinal determinism ─────────────────────────────────────────────────────

test "lexically distinct sites differ, and numbering restarts per declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\one :: () { alpha(); beta(); }
        \\two :: () { gamma(); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s1 = try callSitesOf(a, &idx, "app.main.one");
    const s2 = try callSitesOf(a, &idx, "app.main.two");
    try std.testing.expectEqual(@as(usize, 2), s1.len);
    try std.testing.expect(s1[0].ordinal != s1[1].ordinal);
    try std.testing.expect(s1[0].id != s1[1].id);
    // Numbering restarts, so `two`'s first site repeats an ordinal `one`
    // already used — the declaration in the key is what separates the ids.
    try std.testing.expectEqual(@as(usize, 1), s2.len);
    const all_one = try sitesOf(a, &idx, "app.main.one");
    const all_two = try sitesOf(a, &idx, "app.main.two");
    try std.testing.expectEqual(all_one[0].ordinal, all_two[0].ordinal);
    try std.testing.expect(all_one[0].id != all_two[0].id);
}

test "ordinals follow source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\seq :: () { alpha(); beta(); gamma(); delta(); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try callSitesOf(a, &idx, "app.main.seq");
    try std.testing.expectEqual(@as(usize, 4), s.len);
    // `sitesFiltered` sorts by ordinal; if the walk is pre-order the spans
    // must come out sorted too.
    var it = idx.sites.iterator();
    var prev_ordinal: u64 = 0;
    var prev_start: u32 = 0;
    var seen = false;
    while (it.next()) |e| {
        if (e.key_ptr.*.data != .call) continue;
        const ord = e.value_ptr.ordinal;
        const start = e.key_ptr.*.span.start;
        if (seen) {
            const ordinal_order = std.math.order(prev_ordinal, ord);
            const span_order = std.math.order(prev_start, start);
            if (ordinal_order != .eq) try std.testing.expectEqual(ordinal_order, span_order);
        }
        prev_ordinal = ord;
        prev_start = start;
        seen = true;
    }
}

test "a named declaration nested in a body opens its own scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\host :: () {
        \\    Helper :: struct {
        \\        n: i64;
        \\        act :: (self: *Helper) { deep(); }
        \\    }
        \\    shallow();
        \\}
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const found = try declarations(a, &idx);
    try std.testing.expect(hasDeclaration(found, "app.main.host"));
    try std.testing.expect(hasDeclaration(found, "app.main.host.Helper.act"));
    const inner = try callSitesOf(a, &idx, "app.main.host.Helper.act");
    try std.testing.expectEqual(@as(usize, 1), inner.len);
    const outer = try callSitesOf(a, &idx, "app.main.host");
    try std.testing.expectEqual(@as(usize, 1), outer.len);
}

test "a loop body is one lexical site" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\spin :: () { for i in 0..10 { tick(); } }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    // The body is walked once, so the loop contributes exactly one site
    // however many times it runs.
    const s = try callSitesOf(a, &idx, "app.main.spin");
    try std.testing.expectEqual(@as(usize, 1), s.len);
}

test "an unrelated declaration does not renumber its neighbours" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try parse(a,
        \\keep :: () { alpha(); beta(); }
    );
    const after = try parse(a,
        \\added :: () { inserted(); other(); }
        \\keep :: () { alpha(); beta(); }
    );
    var idx_before = try site.build(a, before, .{ .main_file = "app/main.sx" });
    defer idx_before.deinit();
    var idx_after = try site.build(a, after, .{ .main_file = "app/main.sx" });
    defer idx_after.deinit();
    const b = try sitesOf(a, &idx_before, "app.main.keep");
    const c = try sitesOf(a, &idx_after, "app.main.keep");
    try std.testing.expectEqual(b.len, c.len);
    for (b, c) |x, y| {
        try std.testing.expectEqual(x.ordinal, y.ordinal);
        try std.testing.expectEqual(x.id, y.id);
    }
}

test "re-indexing the same source is stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\work :: () { alpha(); { beta(); } gamma(); }
    ;
    const first = try parse(a, src);
    const second = try parse(a, src);
    var idx1 = try site.build(a, first, .{ .main_file = "app/main.sx" });
    defer idx1.deinit();
    var idx2 = try site.build(a, second, .{ .main_file = "app/main.sx" });
    defer idx2.deinit();
    const s1 = try sitesOf(a, &idx1, "app.main.work");
    const s2 = try sitesOf(a, &idx2, "app.main.work");
    try std.testing.expect(s1.len > 0);
    try std.testing.expectEqual(s1.len, s2.len);
    for (s1, s2) |x, y| {
        try std.testing.expectEqual(x.ordinal, y.ordinal);
        try std.testing.expectEqual(x.id, y.id);
    }
}

test "an indexed site carries the id its own fields imply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\run :: () { alpha(); beta(); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try sitesOf(a, &idx, "app.main.run");
    for (s) |one| {
        try std.testing.expectEqualStrings("app/main.sx", one.file);
        try std.testing.expectEqual(refId(one.file, one.declaration, one.ordinal), one.id);
    }
}

test "the module path a site reports is the import path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\halt :: () { stop(); }
    );
    for (decls) |d| {
        const mutable: *Node = @constCast(d);
        mutable.source_file = "/opt/sx/library/modules/std/process.sx";
    }
    const roots = [_][]const u8{"/opt/sx/library"};
    var idx = try site.build(a, decls, .{ .stdlib_roots = &roots, .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try callSitesOf(a, &idx, "modules.std.process.halt");
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqualStrings("modules/std/process.sx", s[0].file);
}

test "the index exposes the declaration prefix a site was built from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\emit :: () { send(); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const prefix = idx.prefixFor("app.main.emit") orelse return error.TestUnexpectedResult;
    // An expansion of that site re-uses the prefix and folds only the ordinal.
    const expanded = site.foldOrdinal(.{ .lexical = 0, .expansions = &.{2} });
    try std.testing.expectEqual(
        refId("app/main.sx", "app.main.emit", expanded),
        site.idFromPrefix(prefix, expanded),
    );
}

test "distinct parameterized impls keep distinct paths and ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\impl Into(Alpha) for i64 {
        \\    conv :: (self: *i64) -> i64 { first(); }
        \\}
        \\impl Into(Beta) for i64 {
        \\    conv :: (self: *i64) -> i64 { second(); }
        \\}
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const alpha = try callSitesOf(a, &idx, "app.main.Into(Alpha)#i64.conv");
    const beta = try callSitesOf(a, &idx, "app.main.Into(Beta)#i64.conv");
    try std.testing.expectEqual(@as(usize, 1), alpha.len);
    try std.testing.expectEqual(@as(usize, 1), beta.len);
    try std.testing.expect(alpha[0].id != beta[0].id);
}

test "const-expr array dimensions keep distinct impl paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\impl Show(K) for [N + 1]f32 {
        \\    go :: (self: *[N + 1]f32) { first(); }
        \\}
        \\impl Show(K) for [N + 2]f32 {
        \\    go :: (self: *[N + 2]f32) { second(); }
        \\}
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    var paths = std.StringHashMapUnmanaged(u64){};
    defer paths.deinit(a);
    var it = idx.sites.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.*.data != .call) continue;
        try paths.put(a, e.value_ptr.declaration, e.value_ptr.id);
    }
    // Two impl blocks, two declaration paths, two ids.
    try std.testing.expectEqual(@as(usize, 2), paths.count());
}

test "protocol default bodies number in their own method scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\Ord :: protocol constraint {
        \\    less :: (self: *Self, other: Self) -> bool { one(); }
        \\    more :: (self: *Self, other: Self) -> bool { two(); }
        \\}
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const less = try callSitesOf(a, &idx, "app.main.Ord.less");
    const more = try callSitesOf(a, &idx, "app.main.Ord.more");
    try std.testing.expectEqual(@as(usize, 1), less.len);
    try std.testing.expectEqual(@as(usize, 1), more.len);
    try std.testing.expect(less[0].id != more[0].id);
}

test "numbering is zero-based" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\z :: () { only(); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try sitesOf(a, &idx, "app.main.z");
    try std.testing.expect(s.len > 0);
    try std.testing.expectEqual(@as(u64, 0), s[0].ordinal);
}

test "param types and defaults interleave in lexical order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\f :: (x: i64 = seed(), ys: [dim()]i64) -> i64 { body(); }
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try callSitesOf(a, &idx, "app.main.f");
    try std.testing.expectEqual(@as(usize, 3), s.len);
    // callSitesOf sorts by ordinal; lexical order is seed(), dim(), body().
    var prev: u32 = 0;
    var seen = false;
    for (s) |one| {
        const key = blk: {
            var it = idx.sites.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.id == one.id) break :blk e.key_ptr.*.span.start;
            }
            unreachable;
        };
        if (seen) try std.testing.expect(prev < key);
        prev = key;
        seen = true;
    }
}

test "distinct top-level sites in one module take distinct ordinals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try parse(a,
        \\@run probe("first");
        \\@run probe("second");
    );
    var idx = try site.build(a, decls, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try callSitesOf(a, &idx, "app.main");
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expect(s[0].ordinal != s[1].ordinal);
    try std.testing.expect(s[0].id != s[1].id);
}

/// A resolved `alias :: #import "…"` node over `members`, shaped as import
/// resolution builds it: the alias carries the target module's whole decl list.
fn aliasOver(alloc: std.mem.Allocator, name: []const u8, members: []const *const Node, authored_in: ?[]const u8) !*const Node {
    var list = std.ArrayList(*Node).empty;
    for (members) |m| try list.append(alloc, @constCast(m));
    const slice = try list.toOwnedSlice(alloc);
    const node = try alloc.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .source_file = authored_in,
        .data = .{ .namespace_decl = .{
            .name = name,
            .decls = slice,
            .own_decls = slice,
            .target_module_path = "",
        } },
    };
    return node;
}

fn stamp(decls: []const *const Node, file: []const u8) void {
    for (decls) |d| @constCast(d).source_file = file;
}

test "a namespaced module's sites name that module, not the importer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = try parse(a,
        \\helper :: () { probe(); }
    );
    stamp(lib, "lib/shared.sx");
    const alias = try aliasOver(a, "lib", lib, "app/main.sx");
    var idx = try site.build(a, &.{alias}, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try callSitesOf(a, &idx, "lib.shared.helper");
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqualStrings("lib/shared.sx", s[0].file);
    try std.testing.expectEqual(refId("lib/shared.sx", "lib.shared.helper", s[0].ordinal), s[0].id);
    try std.testing.expect(!hasDeclaration(try declarations(a, &idx), "app.main.helper"));
}

test "two aliases of one module reach one site" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = try parse(a,
        \\helper :: () { probe(); }
    );
    stamp(lib, "lib/shared.sx");
    const left = try aliasOver(a, "one", lib, "app/left.sx");
    const right = try aliasOver(a, "two", lib, "app/right.sx");
    var idx = try site.build(a, &.{ left, right }, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try callSitesOf(a, &idx, "lib.shared.helper");
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqualStrings("lib/shared.sx", s[0].file);
    const decls = try declarations(a, &idx);
    try std.testing.expect(!hasDeclaration(decls, "app.left.helper"));
    try std.testing.expect(!hasDeclaration(decls, "app.right.helper"));
}

test "a module the import DAG shares costs one walk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = try parse(a,
        \\helper :: () { probe(); }
    );
    stamp(lib, "lib/shared.sx");
    // Each level aliases the one below it TWICE, so the leaf sits at the end of
    // 4096 distinct import paths.
    var level: []const *const Node = lib;
    var depth: u32 = 0;
    while (depth < 12) : (depth += 1) {
        const file = try std.fmt.allocPrint(a, "lib/level{d}.sx", .{depth});
        const pair = try a.alloc(*const Node, 2);
        pair[0] = try aliasOver(a, "low", level, file);
        pair[1] = try aliasOver(a, "high", level, file);
        level = pair;
    }
    const top = try aliasOver(a, "top", level, "app/main.sx");
    // The index is a function of the declarations, so it fits a budget that
    // scales with them (25 aliases and one function) and not with the paths
    // that reach them. One walk per path exhausts this many times over.
    var budget = std.heap.FixedBufferAllocator.init(try a.alloc(u8, 16 * 1024));
    var idx = try site.build(budget.allocator(), &.{top}, .{ .main_file = "app/main.sx" });
    defer idx.deinit();
    const s = try callSitesOf(a, &idx, "lib.shared.helper");
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqualStrings("lib/shared.sx", s[0].file);
}

// ── Independent reference implementation of the normative encoding ──────────

const REF_BASIS: u64 = 0xcbf29ce484222325;
const REF_PRIME: u64 = 0x100000001b3;

fn refByte(h: u64, b: u8) u64 {
    return (h ^ @as(u64, b)) *% REF_PRIME;
}

fn refU64(h_in: u64, v: u64) u64 {
    var h = h_in;
    var shift: u6 = 0;
    while (true) : (shift += 1) {
        h = refByte(h, @truncate(v >> (@as(u6, shift) * 8)));
        if (shift == 7) break;
    }
    return h;
}

fn refString(h_in: u64, s: []const u8) u64 {
    var h = refU64(h_in, s.len);
    for (s) |b| h = refByte(h, b);
    return h;
}

fn refId(file: []const u8, declaration: []const u8, ordinal: u64) u64 {
    var h = REF_BASIS;
    h = refString(h, "sx.source-site.v1");
    h = refString(h, file);
    h = refString(h, declaration);
    return refU64(h, ordinal);
}
