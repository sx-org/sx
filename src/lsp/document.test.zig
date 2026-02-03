const std = @import("std");
const sx = struct {
    pub const sema = @import("../sema.zig");
    pub const types = @import("../types.zig");
    pub const imports = @import("../imports.zig");
};
const doc_mod = @import("document.zig");

// Minimal LSP test harness: drive the editor analyzer through the
// real didOpen path (`DocumentStore.analyzeDocument`) and inspect the resulting
// editor index. This is the FIRST `src/lsp/*.test.zig`; it is pulled into the
// `zig build test` graph via the `_ = lsp.document;` reference in `src/root.zig`
// (its tests live one struct deeper than `refAllDecls` reaches).

var g_test_threaded: ?std.Io.Threaded = null;
fn test_io() std.Io {
    if (g_test_threaded == null) {
        g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_test_threaded.?.io();
}

/// The editor `Type` recorded for field `field` of struct `type_name` in the
/// document's index, or null if the document/struct/field isn't present.
fn fieldTypeOf(doc: *doc_mod.Document, type_name: []const u8, field: []const u8) ?sx.types.Type {
    const sema = doc.sema orelse return null;
    const info = sema.struct_types.get(type_name) orelse return null;
    for (info.field_names, info.field_types) |fname, fty| {
        if (std.mem.eql(u8, fname, field)) return fty;
    }
    return null;
}

test "analyzeDocument: identifier array dimension folds to the const value (issue 0099)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 =
        \\MAX :: 4;
        \\Thing :: struct { buf: [MAX]u8; }
    ;
    const doc = try store.openOrUpdate("main.sx", src, 1);
    // Pre-fix this aborts inside `resolveTypeNode`: the array `.length` node is
    // an `identifier` (named const), but the code read `.int_literal`
    // unconditionally. Reaching the assertions at all proves the crash is gone.
    try store.analyzeDocument(doc);

    const buf_ty = fieldTypeOf(doc, "Thing", "buf") orelse return error.SkipZigTest;
    try std.testing.expect(buf_ty == .array_type);
    try std.testing.expectEqual(@as(?u32, 4), buf_ty.array_type.length);
    try std.testing.expectEqualStrings("u8", buf_ty.array_type.element_name);
}

test "analyzeDocument: int-literal array dimension still resolves to its length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "Buf :: struct { data: [64]u8; }";
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    const data_ty = fieldTypeOf(doc, "Buf", "data") orelse return error.SkipZigTest;
    try std.testing.expect(data_ty == .array_type);
    try std.testing.expectEqual(@as(?u32, 64), data_ty.array_type.length);
    try std.testing.expectEqualStrings("u8", data_ty.array_type.element_name);
}

test "analyzeDocument: unresolvable array dimension records an explicit unknown length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    // `N` is never declared as an integer const → the dimension is unknown.
    // Must not panic and must not fabricate a concrete length.
    const src: [:0]const u8 = "Holder :: struct { slots: [N]u8; }";
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    const slots_ty = fieldTypeOf(doc, "Holder", "slots") orelse return error.SkipZigTest;
    try std.testing.expect(slots_ty == .array_type);
    try std.testing.expectEqual(@as(?u32, null), slots_ty.array_type.length);
}

// Same-named methods on different structs must infer by RECEIVER type, not
// by first-registered bare name: `BitWriter.init(..)` returns BitWriter even
// though ByteWriter registered an `init` first. Without receiver-aware
// signature keys, `writer` types as ByteWriter and `writer.write(..)`
// resolves nowhere (go-to-definition/hover dead on method calls).
test "analyzeDocument: method call return type infers by receiver type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 =
        \\ByteWriter :: struct {
        \\    n: i64;
        \\    init :: (start: i64) -> ByteWriter { ByteWriter.{ n = start } }
        \\}
        \\BitWriter :: struct {
        \\    bits: i64;
        \\    init :: (start: i64) -> BitWriter { BitWriter.{ bits = start } }
        \\    write :: (self: *BitWriter, v: i64) { self.bits = v; }
        \\}
        \\use :: () {
        \\    writer := BitWriter.init(0);
        \\    writer.write(1);
        \\}
    ;
    const doc = try store.openOrUpdate("bitwriter.sx", src, 1);
    try store.analyzeDocument(doc);
    const sema = &(doc.sema orelse return error.TestUnexpectedResult);

    // `writer` types as BitWriter …
    var writer_ty: ?sx.types.Type = null;
    for (sema.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "writer")) writer_ty = sym.ty;
    }
    const ty = writer_ty orelse return error.TestUnexpectedResult;
    try std.testing.expect(ty == .struct_type);
    try std.testing.expectEqualStrings("BitWriter", ty.struct_type);

    // … so the `.write` use is indexed under owner BitWriter — definition,
    // hover, and references on method calls all ride this owner.
    try std.testing.expect(findMemberRef(sema, "write", "BitWriter", false) != null);
}

// ---- Store key canonicalization ----

// The SAME file must never live under two keys: import resolution registers
// the compiler's CWD-relative spelling (`canonicalizePath` contract), while
// the editor's didOpen hands the store the absolute path from the file://
// URI. Both spellings must resolve to one Document.
test "DocumentStore: absolute didOpen of a relatively-keyed file reuses the Document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();

    const rel = "lsp-dup-key-regression.tmp.sx";
    const disk_src = "answer :: () -> i64 { return 42; }\n";
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = rel, .data = disk_src });
    defer std.Io.Dir.deleteFile(.cwd(), io, rel) catch {};

    var store = doc_mod.DocumentStore.init(alloc, io, &.{});

    // Import resolution path: loaded from disk under the relative spelling.
    const rel_doc = try store.getOrLoad(rel);
    try std.testing.expectEqual(@as(u32, 1), store.by_path.count());

    // Editor path: didOpen with the absolute spelling of the same file.
    const cwd = sx.imports.processCwd(alloc) orelse return error.SkipZigTest;
    const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, rel });
    const editor_src: [:0]const u8 = "answer :: () -> i64 { return 43; }\n";
    const abs_doc = try store.openOrUpdate(abs, editor_src, 1);

    try std.testing.expectEqual(rel_doc, abs_doc);
    try std.testing.expectEqual(@as(u32, 1), store.by_path.count());
    try std.testing.expectEqualStrings(editor_src, rel_doc.source);

    // Request lookups arrive with the absolute URI spelling too.
    try std.testing.expectEqual(@as(?*doc_mod.Document, rel_doc), store.get(abs));
    try std.testing.expectEqual(@as(?*doc_mod.Document, rel_doc), store.get(rel));
}

// Reverse order: the editor opens the file first (absolute URI), then import
// resolution asks for it by the relative key — the in-editor content must win
// over a fresh disk read.
test "DocumentStore: relative import lookup after absolute didOpen sees editor content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();

    const rel = "lsp-dup-key-regression2.tmp.sx";
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = rel, .data = "on_disk :: 1;\n" });
    defer std.Io.Dir.deleteFile(.cwd(), io, rel) catch {};

    var store = doc_mod.DocumentStore.init(alloc, io, &.{});

    const cwd = sx.imports.processCwd(alloc) orelse return error.SkipZigTest;
    const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, rel });
    const editor_src: [:0]const u8 = "in_editor :: 2;\n";
    const abs_doc = try store.openOrUpdate(abs, editor_src, 1);

    const rel_doc = try store.getOrLoad(rel);
    try std.testing.expectEqual(abs_doc, rel_doc);
    try std.testing.expectEqual(@as(u32, 1), store.by_path.count());
    try std.testing.expectEqualStrings(editor_src, rel_doc.source);
}

// ---- Context extension member indexing (design/context-extension.md, LSP unit) ----

fn findMemberRef(sema: *const sx.sema.SemaResult, name: []const u8, owner: []const u8, is_def: bool) ?sx.sema.MemberRef {
    for (sema.member_refs) |mr| {
        if (mr.is_def != is_def) continue;
        if (!std.mem.eql(u8, mr.name, name)) continue;
        if (!std.mem.eql(u8, mr.owner, owner)) continue;
        return mr;
    }
    return null;
}

// A `#context_extend` declaration records a member DEF owned by "Context",
// with the span of the field-name token — the anchor definition/references
// resolve to.
test "analyzeDocument: #context_extend records a Context member def" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "#context_extend trace_depth: i64 = 3;";
    const doc = try store.openOrUpdate("ctx_decl.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = &(doc.sema orelse return error.TestUnexpectedResult);
    const def = findMemberRef(sema, "trace_depth", "Context", true) orelse return error.TestUnexpectedResult;
    const name_off: u32 = @intCast(std.mem.indexOf(u8, src, "trace_depth").?);
    try std.testing.expectEqual(name_off, def.span.start);
    try std.testing.expectEqual(name_off + "trace_depth".len, def.span.end);
}

// A `context.field` read records a member USE owned by "Context" — WITHOUT
// the declaring module (or even core.sx) being imported: the implicit
// `context` types as the Context struct by name (the L3 pin's LSP twin).
test "analyzeDocument: context.field read records a Context member use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "reader :: () -> i64 { return context.trace_depth; }";
    const doc = try store.openOrUpdate("reader.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = &(doc.sema orelse return error.TestUnexpectedResult);
    const use = findMemberRef(sema, "trace_depth", "Context", false) orelse return error.TestUnexpectedResult;
    const name_off: u32 = @intCast(std.mem.indexOf(u8, src, "trace_depth").?);
    try std.testing.expectEqual(name_off, use.span.start);
}

// A `push .{ field = … }` literal's FIELD NAME records a member USE owned by
// "Context" (the push arm owns the anonymous context literal).
test "analyzeDocument: push-literal field name records a Context member use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "user :: () { push .{ trace_depth = 7 } { } }";
    const doc = try store.openOrUpdate("user.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = &(doc.sema orelse return error.TestUnexpectedResult);
    const use = findMemberRef(sema, "trace_depth", "Context", false) orelse return error.TestUnexpectedResult;
    const name_off: u32 = @intCast(std.mem.indexOf(u8, src, "trace_depth").?);
    try std.testing.expectEqual(name_off, use.span.start);
}

// A TYPED struct literal's field name records a member USE owned by the
// literal's struct — the general struct-literal navigation win (stress
// review finding 8), not a Context special case.
test "analyzeDocument: typed struct-literal field name records a member use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 =
        \\Point :: struct { x: i64; y: i64; }
        \\mk :: () { p := Point.{ x = 1, y = 2 }; }
    ;
    const doc = try store.openOrUpdate("point.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = &(doc.sema orelse return error.TestUnexpectedResult);
    const use = findMemberRef(sema, "x", "Point", false) orelse return error.TestUnexpectedResult;
    const lit_x: u32 = @intCast(std.mem.indexOf(u8, src, "x = 1").?);
    try std.testing.expectEqual(lit_x, use.span.start);
    // The struct decl's own field is the DEF the use resolves to.
    try std.testing.expect(findMemberRef(sema, "x", "Point", true) != null);
}

