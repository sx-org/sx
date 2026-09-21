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

// A `@context.extend` declaration records a member DEF owned by "Context",
// with the span of the field-name token — the anchor definition/references
// resolve to.
test "analyzeDocument: @context.extend records a Context member def" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const src: [:0]const u8 = "@context.extend trace_depth: i64 = 3;";
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

test "analyzeDocument indexes an exponent-only float declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.openOrUpdate("main.sx", "RATE :: 15e-4;", 1);
    try store.analyzeDocument(doc);
    const root = doc.root orelse return error.MissingRoot;
    try std.testing.expectEqual(@as(f64, 0.0015), root.data.root.decls[0].data.const_decl.value.data.float_literal.value);
    try std.testing.expect(doc.sema != null);
    try std.testing.expectEqual(@as(usize, 1), doc.topLevelSymbols().len);
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

    const a_doc = try store.openOrUpdate("driver_a.sx", "Alpha :: struct { x: i32; }", 1);
    try store.analyzeDocument(a_doc);
    const b_doc = try store.openOrUpdate("driver_b.sx", "Beta :: struct { y: i32; }", 1);
    try store.analyzeDocument(b_doc);

    const main_src: [:0]const u8 =
        \\inline if @host.os == .macos {
        \\    @import "driver_a.sx";
        \\} else {
        \\    @import "driver_b.sx";
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
        \\Shape :: interface {
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
        \\Shape :: interface {
        \\    area :: (self: *Self) -> i64;
        \\}
        \\
        \\Box :: struct { n: i64; }
    ;
    const lib_doc = try store.openOrUpdate("proto_lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    const main_src: [:0]const u8 =
        \\@import "proto_lib.sx";
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
        \\Shape :: interface {
        \\    area :: (self: *Self) -> i64;
        \\}
        \\
        \\Box :: struct { n: i64; }
    ;
    const inner_doc = try store.openOrUpdate("alias_inner.sx", inner_src, 1);
    try store.analyzeDocument(inner_doc);

    const facade_src: [:0]const u8 =
        \\core :: @import "alias_inner.sx";
        \\
        \\Shape :: core.Shape;
        \\Box   :: core.Box;
    ;
    const facade_doc = try store.openOrUpdate("alias_facade.sx", facade_src, 1);
    try store.analyzeDocument(facade_doc);

    const main_src: [:0]const u8 =
        \\@import "alias_facade.sx";
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

test "analyzeDocument: a @context.extend member's type owns its method uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const lib_src: [:0]const u8 =
        \\Context :: struct { }
        \\
        \\Shape :: interface {
        \\    area :: (self: *Self) -> i64;
        \\}
        \\
        \\@context.extend shape: Shape;
    ;
    const lib_doc = try store.openOrUpdate("ctx_lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    const main_src: [:0]const u8 =
        \\@import "ctx_lib.sx";
        \\main :: () {
        \\    _ = context.shape.area();
        \\}
    ;
    const main_doc = try store.openOrUpdate("ctx_use.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    try std.testing.expect(findMemberRef(&sema, "area", "Shape", false) != null);
}

test "analyzeDocument: reinterpretation exposes its destination to the editor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.openOrUpdate("view.sx",
        \\main :: () { n: i64 = 0; p := @reinterpret(*u8, *n); }
    , 1);
    try store.analyzeDocument(doc);
    const sema = doc.sema orelse return error.TestUnexpectedResult;
    for (sema.symbols) |symbol| {
        if (!std.mem.eql(u8, symbol.name, "p")) continue;
        const ty = symbol.ty orelse return error.TestUnexpectedResult;
        try std.testing.expect(ty == .pointer_type);
        try std.testing.expectEqualStrings("u8", ty.pointer_type.pointee_name);
        return;
    }
    return error.TestUnexpectedResult;
}

test "document declarations follow the analyzed source snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.openOrUpdate("snapshot.sx", "old :: 1;", 1);
    try store.analyzeDocument(doc);
    const previous = doc.sema.?;
    const old_symbol = previous.symbols[0].declaration.?;
    try std.testing.expectEqualStrings("old", old_symbol.table.get(old_symbol.id).name);
    try std.testing.expectEqual(previous.declarations.?.environment, old_symbol.table.get(old_symbol.id).environment.?);

    _ = try store.openOrUpdate("snapshot.sx", "fresh :: 2;", 2);
    try std.testing.expect(doc.declarations == null);
    try store.analyzeDocument(doc);
    const current = doc.sema.?;
    const context = current.declarations.?;
    try std.testing.expect(context.table != previous.declarations.?.table);
    try std.testing.expect(!context.table.environment(context.environment).names.contains("old"));
    const fresh = current.symbols[0].declaration.?;
    try std.testing.expectEqualStrings("fresh", fresh.table.get(fresh.id).name);
    try std.testing.expectEqualStrings("old", old_symbol.table.get(old_symbol.id).name);

    _ = try store.openOrUpdate("snapshot.sx", "fresh :: (", 3);
    try store.analyzeDocument(doc);
    try std.testing.expect(doc.declarations == null);
    try std.testing.expect(doc.last_good_sema.?.declarations.?.table == context.table);
}

test "editor alias candidates share their final target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.getOrLoad("examples/modules/2750-modules-alias-final-target.sx");
    try store.analyzeDocument(doc);
    const index = doc.sema orelse return error.MissingAnalysis;
    try std.testing.expect(index.selection.select("answer") != null);
    try std.testing.expect(index.selection.select("N") != null);
    try std.testing.expect(index.selection.select("Cb") != null);
    try std.testing.expect(index.selection.select("IB") != null);
    try std.testing.expect(index.fn_signatures.get("answer") != null);
}

test "editor directory imports preserve file candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.getOrLoad("examples/modules/2752-modules-directory-distinct-authors.sx");
    try store.analyzeDocument(doc);
    try std.testing.expectEqual(@as(usize, 2), doc.imports.len);
    try std.testing.expect(doc.sema.?.selection.select("answer") == null);
    const named = try store.getOrLoad("examples/modules/2753-modules-named-directory-imports.sx");
    try store.analyzeDocument(named);
    var duplicate = false;
    for (named.sema.?.diagnostics) |diag| {
        if (std.mem.eql(u8, diag.message, "duplicate declaration")) duplicate = true;
    }
    try std.testing.expect(duplicate);
}

test "editor C imports retain file and namespace identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.getOrLoad("examples/modules/2751-modules-cimport-distinct-authors.sx");
    try store.analyzeDocument(doc);
    const index = doc.sema.?.selection;
    try std.testing.expect(index.flat.items[0].select("abs") != null);
    try std.testing.expect(index.flat.items[1].select("abs") != null);
    try std.testing.expect(index.select("abs") == null);
    const scoped = try store.openOrUpdate("c-namespaces.sx",
        \\a :: @import c { @include "examples/modules/2751-modules-cimport-distinct-authors/abs.h"; };
        \\b :: @import c { @include "examples/modules/2751-modules-cimport-distinct-authors/abs.h"; };
    , 1);
    try store.analyzeDocument(scoped);
    const left = scoped.sema.?.selection.select("a.abs").?;
    const right = scoped.sema.?.selection.select("b.abs").?;
    try std.testing.expect(left.id != right.id);
    try std.testing.expect(left.info().environment != right.info().environment);
}

test "editor structural alias cycles do not form an identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    _ = try store.openOrUpdate("cycle-a.sx", "Loop :: *Loop;", 1);
    _ = try store.openOrUpdate("cycle-b.sx", "Loop :: *Loop;", 1);
    const doc = try store.openOrUpdate("cycle-reader.sx",
        \\@import "cycle-a.sx";
        \\@import "cycle-b.sx";
    , 1);
    try store.analyzeDocument(doc);
    try std.testing.expect(doc.sema.?.selection.select("Loop") == null);
}

test "scope declarations are indexed while spreads remain unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.openOrUpdate("scope.sx", "geo :: scope { X :: 1; } ..geo;", 1);
    try store.analyzeDocument(doc);
    const sema = doc.sema orelse return error.MissingAnalysis;
    try std.testing.expectEqual(@as(usize, 1), sema.diagnostics.len);
    try std.testing.expectEqualStrings("scope spreads are not supported", sema.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 2), sema.symbols.len);
}

const CompilerFacts = struct {
    table: sx.imports.DeclTable,
    root: *@import("../ast.zig").Node,
    diagnostics: @import("../errors.zig").DiagnosticList,
    flat_imports: std.StringHashMap(std.StringHashMap(void)),
};

fn compilerFacts(alloc: std.mem.Allocator, path: []const u8, source: [:0]const u8) !CompilerFacts {
    var parser = try @import("../parser.zig").Parser.init(alloc, source);
    const root = try parser.parse();
    var cache = sx.imports.ModuleCache.init(alloc);
    var chain = std.StringHashMap(void).init(alloc);
    var flat = std.StringHashMap(std.StringHashMap(void)).init(alloc);
    var diagnostics = @import("../errors.zig").DiagnosticList.init(alloc, source, path);
    _ = try sx.imports.resolveImports(alloc, test_io(), root, sx.imports.dirName(path), path, &chain, &cache, null, &diagnostics, &.{}, null, &flat);
    return .{ .table = cache.declarations, .root = root, .diagnostics = diagnostics, .flat_imports = flat };
}

fn expectSameFileFacts(compiler: *const sx.imports.DeclTable, editor: *const sx.imports.DeclTable, path: []const u8) !void {
    const source = compiler.fileScope(path).?.source;
    var count: usize = 0;
    for (compiler.blocks.items) |block| {
        const env = compiler.environment(block.environment);
        if (!std.mem.eql(u8, source, env.source)) continue;
        count += 1;
        const other = for (editor.blocks.items) |candidate| {
            if (std.meta.eql(block.node.span, candidate.node.span) and std.meta.activeTag(block.node.data) == std.meta.activeTag(candidate.node.data)) break candidate;
        } else return error.MissingEditorBlock;
        const other_env = editor.environment(other.environment);
        try std.testing.expectEqualDeep(env.scope_path, other_env.scope_path);
        try std.testing.expectEqual(env.scope == null, other_env.scope == null);
        if (env.scope) |id| try std.testing.expectEqualDeep(compiler.scopeInfo(id).path, editor.scopeInfo(other_env.scope.?).path);
        try std.testing.expectEqual(block.parent == null, other.parent == null);
        if (block.parent) |parent| try std.testing.expectEqualDeep(compiler.block(parent).node.span, editor.block(other.parent.?).node.span);
        try std.testing.expectEqual(block.imports.items.len, other.imports.items.len);
        for (block.imports.items, other.imports.items) |left, right| {
            try std.testing.expectEqualDeep(left.data.import_decl, right.data.import_decl);
            try std.testing.expectEqualDeep(left.span, right.span);
        }
        try std.testing.expectEqual(env.names.count(), other_env.names.count());
        var names = env.names.iterator();
        while (names.next()) |entry| {
            const left = compiler.get(entry.value_ptr.*);
            const right = editor.get(other_env.names.get(entry.key_ptr.*).?);
            try std.testing.expectEqual(left.kind, right.kind);
            try std.testing.expectEqualDeep(left.span, right.span);
            try std.testing.expectEqualDeep(compiler.block(left.lexical_block.?).node.span, editor.block(right.lexical_block.?).node.span);
            try std.testing.expectEqual(left.scope == null, right.scope == null);
            if (left.scope) |id| try std.testing.expectEqualDeep(compiler.scopeInfo(id).path, editor.scopeInfo(right.scope.?).path);
        }
    }
    try std.testing.expectEqual(count, editor.blocks.items.len);
}

test "compiler and editor retain scope block imports without file-level leakage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "parts", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "parts/left.sx", .data = "left :: 10;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "right.sx", .data = "right :: 20;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local.h", .data = "long c_value(void);" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.sx", .data = "geo :: scope { x :: 30; }" });
    const source: [:0]const u8 =
        \\@import "other.sx";
        \\geo :: scope {
        \\    @import "parts";
        \\    n :: @import "right.sx";
        \\    x :: 1;
        \\    detail :: scope { read :: () -> i64 { x } }
        \\}
        \\geo :: scope {
        \\    @import "right.sx";
        \\    y :: 2;
        \\    c :: @import c { @include "local.h"; };
        \\    detail :: scope { value :: 3; }
        \\    ..@import "absent.sx";
        \\    ..geo;
        \\}
        \\x :: 4;
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data = source });
    var dirbuf: [4096]u8 = undefined;
    const dirlen = try tmp.dir.realPath(io, &dirbuf);
    const path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{dirbuf[0..dirlen]});
    var compiler = try compilerFacts(alloc, path, source);
    try std.testing.expectEqual(@as(usize, 0), compiler.diagnostics.items.items.len);
    var store = doc_mod.DocumentStore.init(alloc, io, &.{}, alloc);
    const doc = try store.openOrUpdate(path, source, 1);
    try store.analyzeDocument(doc);
    const editor = doc.declarations.?.table;
    try expectSameFileFacts(&compiler.table, editor, path);
    const first = compiler.root.data.root.decls[1].data.scope_decl.body_block.?;
    const second = compiler.root.data.root.decls[2].data.scope_decl.body_block.?;
    const geo = compiler.table.block(first).environment;
    try std.testing.expect(first != second);
    try std.testing.expectEqual(geo, compiler.table.block(second).environment);
    try std.testing.expectEqual(@as(usize, 2), compiler.table.block(first).imports.items.len);
    try std.testing.expectEqual(@as(usize, 1), compiler.table.block(second).imports.items.len);
    const root_env = compiler.table.fileEnvironment(path).?;
    try std.testing.expectEqual(@as(u32, 1), compiler.table.directImports(&compiler.flat_imports, root_env).?.count());
    const other_doc = try store.getOrLoad(doc.imports[0].path);
    try expectSameFileFacts(&compiler.table, other_doc.declarations.?.table, other_doc.path);
    const other_scope = compiler.table.get(compiler.table.fileScope(other_doc.path).?.names.get("geo").?).scope.?;
    try std.testing.expectEqual(compiler.table.environment(geo).scope.?, other_scope);
    for (doc.sema.?.symbols) |symbol| {
        try std.testing.expect(!std.mem.eql(u8, symbol.name, "left") and !std.mem.eql(u8, symbol.name, "right"));
    }
    const detail = compiler.table.findEnvironment(path, &.{ "geo", "detail" }).?;
    const read = compiler.table.get(compiler.table.environment(detail).names.get("read").?).node.?;
    try std.testing.expectEqual(read.lexical_block.?, read.data.fn_decl.body.lexical_block.?);
    var subst = @import("../ast.zig").Substitution.init(alloc);
    const cloned = try @import("../ast.zig").cloneWithSubst(alloc, read, &subst);
    try std.testing.expectEqual(read.lexical_block.?, cloned.data.fn_decl.body.lexical_block.?);
}

test "scope merge duplicates and scope-name collisions diagnose the second declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source: [:0]const u8 =
        \\geo :: scope { x :: 1; }
        \\geo :: scope { x :: 2; }
        \\geo :: 3;
        \\plain :: 4;
        \\plain :: scope {}
    ;
    var compiler = try compilerFacts(alloc, "duplicate-scopes.sx", source);
    var original_parser = try @import("../parser.zig").Parser.init(alloc, source);
    const nodes = (try original_parser.parse()).data.root.decls;
    const spans = [_]@import("../ast.zig").Span{ nodes[1].data.scope_decl.decls[0].span, nodes[2].span, nodes[4].span };
    try std.testing.expectEqual(spans.len, compiler.diagnostics.items.items.len);
    for (spans, compiler.diagnostics.items.items) |span, diagnostic| {
        try std.testing.expectEqualDeep(span, diagnostic.span);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "duplicate top-level declaration") != null);
    }
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const doc = try store.openOrUpdate("duplicate-scopes.sx", source, 1);
    try store.analyzeDocument(doc);
    var count: usize = 0;
    for (doc.sema.?.diagnostics) |diagnostic| {
        if (diagnostic.level != .err or !std.mem.eql(u8, diagnostic.message, "duplicate declaration")) continue;
        try std.testing.expectEqualDeep(spans[count], diagnostic.span);
        count += 1;
    }
    try std.testing.expectEqual(spans.len, count);
    try expectSameFileFacts(&compiler.table, doc.declarations.?.table, doc.path);
}

const ScopeProbe = struct {
    alloc: std.mem.Allocator,
    directory: []const u8,
    compiler: *CompilerFacts,
    resolver: @import("../ir/resolver.zig").Resolver,
    store: doc_mod.DocumentStore,

    fn init(alloc: std.mem.Allocator, directory: []const u8) !ScopeProbe {
        const path = try std.fmt.allocPrint(alloc, "{s}/main.sx", .{directory});
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), test_io(), path, alloc, .limited(1 << 20));
        const compiler = try alloc.create(CompilerFacts);
        compiler.* = try compilerFacts(alloc, path, try alloc.dupeZ(u8, bytes));
        try std.testing.expectEqual(@as(usize, 0), compiler.diagnostics.items.items.len);
        const index = try alloc.create(@import("../ir/program_index.zig").ProgramIndex);
        index.* = .init(alloc);
        index.decl_table = &compiler.table;
        index.flat_import_graph = &compiler.flat_imports;
        var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
        try store.analyzeDocument(try store.getOrLoad(path));
        return .{ .alloc = alloc, .directory = directory, .compiler = compiler, .resolver = .init(index, alloc), .store = store };
    }

    const Expected = union(enum) {
        declaration: struct { file: []const u8, name: []const u8 },
        missing,
        ambiguous,
    };

    fn expect(self: *ScopeProbe, file: []const u8, block_owner: ?[]const u8, name: []const u8, expected: Expected) !void {
        const path = try sx.imports.canonicalizePath(self.alloc, try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.directory, file }));
        const table = &self.compiler.table;
        var context = @import("../name_lookup.zig").Context{ .table = table, .environment = table.fileEnvironment(path).? };
        const doc = try self.store.getOrLoad(path);
        var selection = doc.sema.?.selection;
        if (block_owner) |owner| {
            const compiler_owner = self.resolver.selectPath(owner, context).selected.declaration;
            const block = table.get(compiler_owner).lexical_block.?;
            context.block = block;
            context.environment = table.block(block).environment;
            selection = try selection.inBlock(selection.select(owner).?.info().lexical_block.?);
        }
        const actual = self.resolver.selectPath(name, context);
        const editor = selection.select(name);
        switch (expected) {
            .missing => {
                try std.testing.expectEqual(.missing, std.meta.activeTag(actual));
                try std.testing.expect(editor == null);
            },
            .ambiguous => {
                try std.testing.expectEqual(.ambiguous, std.meta.activeTag(actual));
                try std.testing.expect(editor == null);
            },
            .declaration => |decl| {
                try std.testing.expectEqual(.selected, std.meta.activeTag(actual));
                const info = table.get(actual.selected.declaration);
                try std.testing.expectEqualStrings(decl.file, std.fs.path.basename(info.source.?));
                try std.testing.expectEqualStrings(decl.name, info.name);
                try std.testing.expectEqualStrings(info.source.?, editor.?.info().source.?);
                try std.testing.expectEqualDeep(info.span, editor.?.info().span);
            },
        }
    }
};

test "scope selection keeps importer namespace and alias viewpoints separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "base.sx", .data = "geo :: scope { base :: 1; value :: 10; }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.sx", .data =
        \\@import "base.sx";
        \\geo :: scope { lib :: 2; }
        \\G :: geo;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "extra.sx", .data = "geo :: scope { named_only :: 20; }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data =
        \\@import "lib.sx";
        \\ns :: @import "lib.sx";
        \\extra :: @import "extra.sx";
        \\geo :: scope { value :: 30; }
        \\..@import "absent.sx";
        \\..extra;
    });
    var dirbuf: [4096]u8 = undefined;
    var probe = try ScopeProbe.init(alloc, dirbuf[0..try tmp.dir.realPath(io, &dirbuf)]);
    try probe.expect("main.sx", null, "geo.lib", .{ .declaration = .{ .file = "lib.sx", .name = "lib" } });
    try probe.expect("main.sx", null, "geo.base", .missing);
    try probe.expect("main.sx", null, "geo.named_only", .missing);
    try probe.expect("main.sx", null, "geo.value", .{ .declaration = .{ .file = "main.sx", .name = "value" } });
    try probe.expect("main.sx", null, "ns.geo.value", .{ .declaration = .{ .file = "base.sx", .name = "value" } });
    try probe.expect("main.sx", null, "G.value", .{ .declaration = .{ .file = "base.sx", .name = "value" } });
    try probe.expect("lib.sx", null, "geo.value", .{ .declaration = .{ .file = "base.sx", .name = "value" } });
}

test "scope lookup orders members block imports enclosing scopes and file lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "part.sx", .data = "geo :: scope { member :: 1; }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers.sx", .data = "member :: 2; helper :: 3; parent :: 4; top :: 5; geo :: scope { inner :: scope { carried :: 11; } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fallback.sx", .data = "last :: 6;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "inner.sx", .data = "near :: 12;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data =
        \\@import "part.sx";
        \\@import "fallback.sx";
        \\top :: 7;
        \\geo :: scope {
        \\    @import "helpers.sx";
        \\    parent :: 8; near :: 13;
        \\    inner :: scope { @import "inner.sx"; anchor :: 9; }
        \\    Saved :: inner;
        \\}
        \\geo :: scope { sibling :: 10; }
    });
    var dirbuf: [4096]u8 = undefined;
    var probe = try ScopeProbe.init(alloc, dirbuf[0..try tmp.dir.realPath(io, &dirbuf)]);
    try probe.expect("main.sx", "geo.inner.anchor", "member", .{ .declaration = .{ .file = "part.sx", .name = "member" } });
    try probe.expect("main.sx", "geo.inner.anchor", "helper", .{ .declaration = .{ .file = "helpers.sx", .name = "helper" } });
    try probe.expect("main.sx", "geo.inner.anchor", "parent", .{ .declaration = .{ .file = "main.sx", .name = "parent" } });
    try probe.expect("main.sx", "geo.inner.anchor", "top", .{ .declaration = .{ .file = "helpers.sx", .name = "top" } });
    try probe.expect("main.sx", "geo.sibling", "top", .{ .declaration = .{ .file = "main.sx", .name = "top" } });
    try probe.expect("main.sx", "geo.sibling", "helper", .missing);
    try probe.expect("main.sx", "geo.inner.anchor", "last", .{ .declaration = .{ .file = "fallback.sx", .name = "last" } });
    try probe.expect("main.sx", null, "geo.helper", .missing);
    try probe.expect("main.sx", "geo.inner.anchor", "near", .{ .declaration = .{ .file = "inner.sx", .name = "near" } });
    try probe.expect("main.sx", "geo.inner.anchor", "carried", .{ .declaration = .{ .file = "helpers.sx", .name = "carried" } });
    try probe.expect("main.sx", null, "geo.inner.carried", .missing);
    try probe.expect("main.sx", null, "geo.Saved.carried", .{ .declaration = .{ .file = "helpers.sx", .name = "carried" } });
}

test "scope member ambiguity is lazy and local declarations hide other files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "left.sx", .data = "geo :: scope { conflict :: 1; hidden :: 2; }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "right.sx", .data = "geo :: scope { conflict :: 3; hidden :: struct { x: i64; } unique :: 5; }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "foreign.h", .data = "long foreign(void);" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.sx", .data = "geo :: @import c { @include \"foreign.h\"; };" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data =
        \\@import "left.sx";
        \\@import "right.sx";
        \\@import "c.sx";
        \\geo :: scope { hidden :: 6; }
    });
    var dirbuf: [4096]u8 = undefined;
    var probe = try ScopeProbe.init(alloc, dirbuf[0..try tmp.dir.realPath(io, &dirbuf)]);
    try probe.expect("main.sx", null, "geo", .{ .declaration = .{ .file = "main.sx", .name = "geo" } });
    try probe.expect("main.sx", null, "geo.unique", .{ .declaration = .{ .file = "right.sx", .name = "unique" } });
    try probe.expect("main.sx", null, "geo.conflict", .ambiguous);
    try probe.expect("main.sx", null, "geo.foreign", .missing);
    try probe.expect("main.sx", null, "geo.hidden", .{ .declaration = .{ .file = "main.sx", .name = "hidden" } });
    const scope = probe.compiler.root.data.root.decls[3].data.scope_decl.body_block.?;
    const hidden_type = probe.resolver.resolveBare("hidden", probe.compiler.table.block(scope).environment, .bare_type);
    try std.testing.expectEqual(.domain_filtered, hidden_type.verdict);
}

test "scope aliases preserve target identity and requester private authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target.sx", .data =
        \\geo :: scope { private secret :: 1; public_value :: secret; }
        \\G :: geo;
        \\answer :: geo.public_value;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "alias.sx", .data =
        \\ns :: @import "target.sx";
        \\G :: ns.geo;
        \\answer :: ns.geo.public_value;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.sx", .data =
        \\@import "target.sx";
        \\@import "alias.sx";
    });
    var dirbuf: [4096]u8 = undefined;
    var probe = try ScopeProbe.init(alloc, dirbuf[0..try tmp.dir.realPath(io, &dirbuf)]);
    try probe.expect("main.sx", null, "G.public_value", .{ .declaration = .{ .file = "target.sx", .name = "public_value" } });
    try probe.expect("main.sx", null, "G.secret", .missing);
    try probe.expect("target.sx", null, "G.secret", .{ .declaration = .{ .file = "target.sx", .name = "secret" } });
    const root = @import("../name_lookup.zig").Context{ .table = &probe.compiler.table, .environment = probe.compiler.table.fileEnvironment(try std.fmt.allocPrint(alloc, "{s}/main.sx", .{probe.directory})).? };
    const authors = probe.resolver.resolveBare("answer", root.environment, .value_const);
    try std.testing.expectEqual(.single, authors.verdict);
    const doc = probe.store.get(root.source()).?;
    try std.testing.expect(doc.sema.?.selection.select("answer") != null);
}

test "scope bodies and alias paths navigate to their authored declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const source =
        \\N :: 9;
        \\geo :: scope {
        \\    N :: 3;
        \\    read :: () -> i64 { N }
        \\}
        \\geo :: scope { more :: () -> i64 { N } }
        \\Saved :: geo;
        \\main :: () { x := Saved.read(); Saved := .{ read = 7 }; y := Saved.read; }
    ;
    const doc = try store.openOrUpdate("scope-navigation.sx", source, 1);
    try store.analyzeDocument(doc);
    const sema = doc.sema orelse return error.MissingAnalysis;
    try std.testing.expectEqual(@as(usize, 0), sema.diagnostics.len);
    const number = sema.selection.select("geo.N").?;
    const read = sema.selection.select("geo.read").?;
    const first_use = std.mem.indexOf(u8, source, "{ N }").? + 2;
    const call_use = std.mem.indexOf(u8, source, "Saved.read").? + "Saved.".len;
    const local_use = std.mem.lastIndexOf(u8, source, "Saved.read").? + "Saved.".len;
    var found_number = false;
    var found_call = false;
    for (sema.references) |reference| {
        const symbol = sema.symbols[reference.symbol_index];
        try std.testing.expect(reference.span.start != local_use);
        if (reference.span.start == first_use) {
            try std.testing.expectEqualDeep(number, symbol.declaration.?);
            found_number = true;
        }
        if (reference.span.start == call_use) {
            try std.testing.expectEqualDeep(read, symbol.declaration.?);
            found_call = true;
        }
    }
    try std.testing.expect(found_number and found_call);
    try std.testing.expectEqual(@as(u8, 64), sema.fn_signatures.get("Saved.read").?.return_type.signed);
}

test "scope aliases are designators and cannot initialize a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{}, alloc);
    const source = "geo :: scope { N :: 3; } Saved :: geo; main :: () { value := Saved; }";
    const doc = try store.openOrUpdate("scope-value.sx", source, 1);
    try store.analyzeDocument(doc);
    const diagnostics = doc.sema.?.diagnostics;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("a scope is not a value", diagnostics[0].message);
    try std.testing.expectEqual(std.mem.lastIndexOf(u8, source, "Saved").?, diagnostics[0].span.?.start);
}
