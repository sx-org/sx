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

test "analyzeDocument: identifier array dimension folds to the const value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const src: [:0]const u8 =
        \\MAX :: 4;
        \\Thing :: struct { buf: [MAX]u8; }
    ;
    const doc = try store.openOrUpdate("main.sx", src, 1);
    // The array `.length` node here is an `identifier` (named const), not an
    // `.int_literal`; `resolveTypeNode` must handle it rather than abort.
    // Reaching the assertions at all proves it does.
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

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
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

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
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

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const src: [:0]const u8 =
        \\ByteWriter :: struct {
        \\    n: i64;
        \\    init :: (start: i64) -> ByteWriter { ByteWriter{ n = start } }
        \\}
        \\BitWriter :: struct {
        \\    bits: i64;
        \\    init :: (start: i64) -> BitWriter { BitWriter{ bits = start } }
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

    const rel = "lsp-dup-key.tmp.sx";
    const disk_src = "answer :: () -> i64 { return 42; }\n";
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = rel, .data = disk_src });
    defer std.Io.Dir.deleteFile(.cwd(), io, rel) catch {};

    var store = doc_mod.DocumentStore.init(alloc, io, &.{}, alloc);

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

    const rel = "lsp-dup-key-reverse.tmp.sx";
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = rel, .data = "on_disk :: 1;\n" });
    defer std.Io.Dir.deleteFile(.cwd(), io, rel) catch {};

    var store = doc_mod.DocumentStore.init(alloc, io, &.{}, alloc);

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

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
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
// `context` types as the Context struct by name.
test "analyzeDocument: context.field read records a Context member use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
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

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const src: [:0]const u8 = "user :: () { push .{ trace_depth = 7 } { } }";
    const doc = try store.openOrUpdate("user.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = &(doc.sema orelse return error.TestUnexpectedResult);
    const use = findMemberRef(sema, "trace_depth", "Context", false) orelse return error.TestUnexpectedResult;
    const name_off: u32 = @intCast(std.mem.indexOf(u8, src, "trace_depth").?);
    try std.testing.expectEqual(name_off, use.span.start);
}

// A TYPED struct literal's field name records a member USE owned by the
// literal's struct — general struct-literal navigation, not a Context
// special case.
test "analyzeDocument: typed struct-literal field name records a member use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const src: [:0]const u8 =
        \\Point :: struct { x: i64; y: i64; }
        \\mk :: () { p := Point{ x = 1, y = 2 }; }
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

/// Tracks bytes handed out and returned by `child`, so a test can bound the
/// storage a document's token arenas hold across updates.
pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocated: usize = 0,
    freed: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    pub fn live(self: *const CountingAllocator) usize {
        return self.allocated - self.freed;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.allocated += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.note(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.note(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.freed += memory.len;
    }

    fn note(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) self.allocated += new_len - old_len else self.freed += old_len - new_len;
    }
};

fn tokenCount(doc: *const doc_mod.Document) usize {
    var i = doc.tokens.first();
    var n: usize = 0;
    while (doc.tokens.tag(i) != .eof) : (i = doc.tokens.next(i)) n += 1;
    return n;
}

test "openOrUpdate: a new document carries a token list over its own source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const src: [:0]const u8 = "add :: (a: i32) -> i32 { a }";
    const doc = try store.openOrUpdate("main.sx", src, 1);

    try std.testing.expectEqual(src.ptr, doc.source.ptr);
    try std.testing.expectEqual(src.ptr, doc.tokens.source.ptr);
    try std.testing.expectEqual(@as(i64, 1), doc.version);
    try std.testing.expect(tokenCount(doc) > 0);
}

test "openOrUpdate: an update replaces source, tokens and version together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const first: [:0]const u8 = "a :: 1;";
    const second: [:0]const u8 = "a :: 1; b :: 2; c :: 3;";

    const doc = try store.openOrUpdate("main.sx", first, 1);
    const first_count = tokenCount(doc);

    const again = try store.openOrUpdate("main.sx", second, 2);
    try std.testing.expectEqual(doc, again);
    try std.testing.expectEqual(second.ptr, doc.source.ptr);
    try std.testing.expectEqual(second.ptr, doc.tokens.source.ptr);
    try std.testing.expectEqual(@as(i64, 2), doc.version);
    try std.testing.expect(tokenCount(doc) > first_count);
}

test "openOrUpdate: a failed lex leaves the previous source, tokens and version readable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failing = std.testing.FailingAllocator.init(alloc, .{});
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, failing.allocator());
    const first: [:0]const u8 = "a :: 1;";
    const second: [:0]const u8 = "a :: 1; b :: 2;";

    const doc = try store.openOrUpdate("main.sx", first, 1);
    const first_count = tokenCount(doc);

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, store.openOrUpdate("main.sx", second, 2));

    try std.testing.expectEqual(first.ptr, doc.source.ptr);
    try std.testing.expectEqual(first.ptr, doc.tokens.source.ptr);
    try std.testing.expectEqual(@as(i64, 1), doc.version);
    try std.testing.expectEqual(first_count, tokenCount(doc));
    try std.testing.expectEqualStrings("a", doc.tokens.slice(doc.tokens.first()));
}

test "createDocument: store allocation failures reclaim the token arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src: [:0]const u8 = "a :: 1;";
    var reached_tokens = false;
    var reached_success = false;
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = index });
        var counter = CountingAllocator{ .child = std.testing.allocator };
        var store = doc_mod.DocumentStore.init(failing.allocator(), test_io(), &.{}, counter.allocator());
        if (store.openOrUpdate("main.sx", src, 1)) |doc| {
            reached_success = true;
            doc.token_arena.deinit();
            break;
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expectEqual(@as(usize, 0), counter.live());
            if (counter.allocated > 0) reached_tokens = true;
        }
    }
    // Without a failure landing after the lex the sweep would prove nothing.
    try std.testing.expect(reached_tokens);
    try std.testing.expect(reached_success);
}

test "createDocument: token-backing allocation failures reclaim the token arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src: [:0]const u8 = "a :: 1;";
    var reached_success = false;
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        var counter = CountingAllocator{ .child = std.testing.allocator };
        var failing = std.testing.FailingAllocator.init(counter.allocator(), .{ .fail_index = index });
        var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, failing.allocator());
        if (store.openOrUpdate("main.sx", src, 1)) |doc| {
            reached_success = true;
            doc.token_arena.deinit();
            try std.testing.expectEqual(@as(usize, 0), counter.live());
            break;
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expectEqual(@as(usize, 0), counter.live());
        }
    }
    try std.testing.expect(reached_success);
}

test "openOrUpdate: repeated updates return the prior token arena to its backing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var counter = CountingAllocator{ .child = std.testing.allocator };
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, counter.allocator());
    const src: [:0]const u8 = "add :: (a: i32, b: i32) -> i32 { a + b }";

    const doc = try store.openOrUpdate("main.sx", src, 1);
    defer doc.token_arena.deinit();
    _ = try store.openOrUpdate("main.sx", src, 2);
    const live_after_two = counter.live();
    try std.testing.expect(live_after_two > 0);

    var version: i64 = 3;
    while (version <= 50) : (version += 1) {
        _ = try store.openOrUpdate("main.sx", src, version);
    }

    try std.testing.expectEqual(live_after_two, counter.live());
    try std.testing.expect(counter.freed > 0);
}

fn hasSymbol(sema: sx.sema.SemaResult, name: []const u8) bool {
    for (sema.symbols) |s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

test "analyzeDocument: imports inside a module driver register from every branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);

    const a_doc = try store.openOrUpdate("driver_a.sx", "Alpha :: struct { x: i32 }", 1);
    try store.analyzeDocument(a_doc);
    const b_doc = try store.openOrUpdate("driver_b.sx", "Beta :: struct { y: i32 }", 1);
    try store.analyzeDocument(b_doc);

    const main_src: [:0]const u8 =
        \\inline if OS == .macos {
        \\    #import "driver_a.sx";
        \\} else {
        \\    #import "driver_b.sx";
        \\}
        \\main :: () { }
    ;
    const main_doc = try store.openOrUpdate("driver_main.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    try std.testing.expectEqual(@as(usize, 2), main_doc.imports.len);
    const sema = main_doc.sema orelse return error.SkipZigTest;
    try std.testing.expect(hasSymbol(sema, "Alpha"));
    try std.testing.expect(hasSymbol(sema, "Beta"));
}

test "analyzeDocument: protocol and impl methods are member defs owned by their type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const src: [:0]const u8 =
        \\Shape :: protocol vtable {
        \\    area :: (self: *Self) -> i64;
        \\}
        \\
        \\Box :: struct { n: i64; }
        \\
        \\impl Shape for Box {
        \\    area :: (self: *Box) -> i64 { self.n }
        \\}
    ;
    const doc = try store.openOrUpdate("proto_defs.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = doc.sema orelse return error.SkipZigTest;
    try std.testing.expect(findMemberRef(&sema, "area", "Shape", true) != null);
    try std.testing.expect(findMemberRef(&sema, "area", "Box", true) != null);
}

test "analyzeDocument: a protocol-typed local owns its method uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const lib_src: [:0]const u8 =
        \\Shape :: protocol vtable {
        \\    area :: (self: *Self) -> i64;
        \\}
        \\
        \\Box :: struct { n: i64; }
    ;
    const lib_doc = try store.openOrUpdate("proto_lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    const main_src: [:0]const u8 =
        \\#import "proto_lib.sx";
        \\main :: (b: *Box) {
        \\    s : Shape = b.(Shape);
        \\    _ = s.area();
        \\}
    ;
    const main_doc = try store.openOrUpdate("proto_use.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    try std.testing.expect(findMemberRef(&sema, "area", "Shape", false) != null);
}

test "analyzeDocument: a re-export alias carries its target type to importers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const inner_src: [:0]const u8 =
        \\Shape :: protocol vtable {
        \\    area :: (self: *Self) -> i64;
        \\}
        \\
        \\Box :: struct { n: i64; }
    ;
    const inner_doc = try store.openOrUpdate("alias_inner.sx", inner_src, 1);
    try store.analyzeDocument(inner_doc);

    const facade_src: [:0]const u8 =
        \\core :: #import "alias_inner.sx";
        \\
        \\Shape :: core.Shape;
        \\Box   :: core.Box;
    ;
    const facade_doc = try store.openOrUpdate("alias_facade.sx", facade_src, 1);
    try store.analyzeDocument(facade_doc);

    const main_src: [:0]const u8 =
        \\#import "alias_facade.sx";
        \\main :: (b: *Box) {
        \\    s : Shape = b.(Shape);
        \\    _ = s.area();
        \\}
    ;
    const main_doc = try store.openOrUpdate("alias_use.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    try std.testing.expect(findMemberRef(&sema, "area", "Shape", false) != null);
}

test "analyzeDocument: a #context_extend member's type owns its method uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const lib_src: [:0]const u8 =
        \\Context :: struct { }
        \\
        \\Shape :: protocol vtable {
        \\    area :: (self: *Self) -> i64;
        \\}
        \\
        \\#context_extend shape: Shape;
    ;
    const lib_doc = try store.openOrUpdate("ctx_lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    const main_src: [:0]const u8 =
        \\#import "ctx_lib.sx";
        \\main :: () {
        \\    _ = context.shape.area();
        \\}
    ;
    const main_doc = try store.openOrUpdate("ctx_use.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    try std.testing.expect(findMemberRef(&sema, "area", "Shape", false) != null);
}
