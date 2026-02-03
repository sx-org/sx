const std = @import("std");
const corpus_paths = @import("corpus_paths");
const doc_mod = @import("document.zig");

// Permanent LSP corpus-sweep test (distribution step B). Drives the editor
// analyzer (`DocumentStore.analyzeDocument` — the exact path `server.zig`'s
// `textDocument/didOpen` handler uses) over EVERY `.sx` file in the example +
// issue corpora, in process. The contract is simply: analysis must complete
// without a panic/abort for any file. A panic aborts the whole test binary —
// that is the loud CI signal that some new AST node shape crashes the analyzer
// (the bug class fixed at `sema.zig`'s `resolveTypeNode`). Files
// that merely fail to parse or sema cleanly are fine: `analyzeDocument` records
// a null index and returns, which counts as a clean (non-crashing) outcome.
//
// The corpus directories are injected as absolute paths at configure time (see
// build.zig `corpus_paths`) so the sweep is CWD-independent. The FILE LIST is
// still read from disk at test time, so new examples are covered automatically
// with no edit to this file.

var g_test_threaded: ?std.Io.Threaded = null;
fn test_io() std.Io {
    if (g_test_threaded == null) {
        g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_test_threaded.?.io();
}

/// Stderr output from a *passing* test makes `zig build test` print
/// `failed command:` despite exiting 0, which automated verifiers read as a
/// build failure. Every print in this file must stay behind this gate.
fn sweepVerbose() bool {
    return std.c.getenv("SX_LSP_SWEEP_VERBOSE") != null;
}

/// Analyze every `.sx` file directly under `dir` through the didOpen pipeline.
/// Returns the number of files swept. Imports resolve against the shipped
/// `library/` so the analyzer runs over real, fully-resolved code (maximum
/// crash surface), exactly like an editor session opened on the repo. Set
/// `SX_LSP_SWEEP_VERBOSE` to print each file before it is analyzed (plus the
/// per-corpus totals) — on a crash the last printed line names the offending file.
fn sweepDirectory(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !usize {
    const verbose = sweepVerbose();

    const lib_paths = [_][]const u8{corpus_paths.library_dir};
    var store = doc_mod.DocumentStore.init(alloc, io, &lib_paths);
    store.root_path = std.fs.path.dirname(corpus_paths.examples_dir) orelse "";

    // `examples/` is organized into category subdirs (`examples/<cat>/*.sx`),
    // while `issues/` is flat (`issues/*.sx`). Sweep the files directly under
    // `dir` AND those one level down in each category subdir (skipping the
    // `expected/` snapshot dirs). Companion fixture dirs nested deeper
    // (`<cat>/<NNNN-...>/lib.sx`) are intentionally not swept — matching the
    // pre-reorg behavior where imported companions were never analyzed directly.
    var total = try sweepFilesIn(alloc, io, &store, dir, verbose);

    var d = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return total;
    defer d.close(io);
    var sub_names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "expected")) continue;
        try sub_names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    for (sub_names.items) |name| {
        const sub = try std.fs.path.join(alloc, &.{ dir, name });
        total += sweepFilesIn(alloc, io, &store, sub, verbose) catch 0;
    }
    return total;
}

/// Analyze every `.sx` directly under `dir` (non-recursive). Returns the count.
fn sweepFilesIn(
    alloc: std.mem.Allocator,
    io: std.Io,
    store: *doc_mod.DocumentStore,
    dir: []const u8,
    verbose: bool,
) !usize {
    const files = store.listDirectoryFiles(dir) orelse return error.CorpusDirNotFound;
    for (files) |path| {
        if (verbose) std.debug.print("[lsp-sweep] {s}\n", .{path});
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(10 * 1024 * 1024));
        const source = try alloc.dupeZ(u8, bytes);
        const doc = try store.openOrUpdate(path, source, 1);
        // didOpen swallows analyze errors (clean failures); a genuine crash
        // panics and aborts here — exactly the regression signal we want.
        store.analyzeDocument(doc) catch {};
    }
    return files.len;
}

test "lsp corpus sweep: every examples/*.sx analyzes without panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();

    const n = try sweepDirectory(alloc, io, corpus_paths.examples_dir);
    if (sweepVerbose()) std.debug.print("[lsp-sweep] examples: analyzed {d} files without a crash\n", .{n});
    try std.testing.expect(n > 0);
}

test "lsp corpus sweep: every issues/*.sx repro analyzes without panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();

    const n = try sweepDirectory(alloc, io, corpus_paths.issues_dir);
    if (sweepVerbose()) std.debug.print("[lsp-sweep] issues: analyzed {d} files without a crash\n", .{n});
}
