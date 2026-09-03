const std = @import("std");
const ast = @import("ast.zig");
const c_import = @import("c_import.zig");
const target = @import("target.zig");

const SRC = "int f(void) { return 1; }";
const HDR = "int f(void);";
const DEP = "#define INNER 1";
const VER = "19.1.7";

const none: []const []const u8 = &.{};

fn baseKey() u64 {
    return c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
}

test "C compile purpose separates host JIT from a native Linux link target" {
    const a = std.testing.allocator;
    const native: target.TargetConfig = .{};
    const link_libc = (try target.libcHeaderTarget(native, a, .linux)).?;
    defer a.free(link_libc.triple);

    const host_jit = c_import.selectCCompile(.host_jit, null, link_libc.triple);
    try std.testing.expect(!host_jit.use_link_libc);
    try std.testing.expect(host_jit.clang_triple == null);

    const linked_build = c_import.selectCCompile(.linked_build, null, link_libc.triple);
    try std.testing.expect(linked_build.use_link_libc);
    try std.testing.expectEqualStrings(link_libc.triple, linked_build.clang_triple.?);
}

test "cSourceCacheKey: stable when nothing changes" {
    try std.testing.expectEqual(baseKey(), baseKey());
}

test "cSourceCacheKey: source bytes vary the key" {
    const other = c_import.cSourceCacheKey("int f(void) { return 2; }", &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: declared header content varies the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{"int f(void); int g(void);"}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: transitive dep content varies the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{"#define INNER 2"}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);

    // a header is not a dep (same string, different role)
    const as_header = c_import.cSourceCacheKey(SRC, &.{"X"}, none, none, none, none, none, VER, null, null);
    const as_dep = c_import.cSourceCacheKey(SRC, none, &.{"X"}, none, none, none, none, VER, null, null);
    try std.testing.expect(as_header != as_dep);
}

test "cSourceCacheKey: defines vary the key (value and order)" {
    const v2 = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=2"}, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != v2);

    const ab = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{ "A=1", "B=1" }, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
    const ba = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{ "B=1", "A=1" }, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(ab != ba);
}

test "cSourceCacheKey: flags vary the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O3"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: a define is not a flag (same string, different role)" {
    const as_define = c_import.cSourceCacheKey(SRC, none, none, &.{"X"}, none, none, none, VER, null, null);
    const as_flag = c_import.cSourceCacheKey(SRC, none, none, none, &.{"X"}, none, none, VER, null, null);
    try std.testing.expect(as_define != as_flag);
}

test "cSourceCacheKey: include dirs vary the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"other"}, none, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: libc dirs vary the key" {
    // Same source, same flags, same (absent) --target: only the libc differs.
    // A native Linux build varies it by how the link resolves, so an object
    // compiled against glibc must never be served to a musl link.
    const musl = c_import.cSourceCacheKey(SRC, none, none, none, none, none, &.{"/zig/libc/include/x86_64-linux-musl"}, VER, null, null);
    const glibc = c_import.cSourceCacheKey(SRC, none, none, none, none, none, &.{"/zig/libc/include/x86-linux-gnu"}, VER, null, null);
    const host = c_import.cSourceCacheKey(SRC, none, none, none, none, none, none, VER, null, null);
    try std.testing.expect(musl != glibc);
    try std.testing.expect(musl != host);
    try std.testing.expect(glibc != host);
}

test "cSourceCacheKey: a libc dir is not an include dir (same string, different role)" {
    const as_inc = c_import.cSourceCacheKey(SRC, none, none, none, none, &.{"X"}, none, VER, null, null);
    const as_libc = c_import.cSourceCacheKey(SRC, none, none, none, none, none, &.{"X"}, VER, null, null);
    try std.testing.expect(as_inc != as_libc);
}

test "cSourceCacheKey: llvm version varies the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, none, "20.0.0", "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "objectMagicOk: accepts Mach-O and ELF, rejects garbage and truncation" {
    try std.testing.expect(c_import.objectMagicOk(&.{ 0xcf, 0xfa, 0xed, 0xfe, 0x00 })); // Mach-O 64
    try std.testing.expect(c_import.objectMagicOk(&.{ 0xce, 0xfa, 0xed, 0xfe })); // Mach-O 32
    try std.testing.expect(c_import.objectMagicOk(&.{ 0x7f, 'E', 'L', 'F', 0x02 }));
    try std.testing.expect(c_import.objectMagicOk(&.{ 0x00, 'a', 's', 'm', 0x01 })); // wasm
    try std.testing.expect(!c_import.objectMagicOk("not an object file"));
    try std.testing.expect(!c_import.objectMagicOk(&.{ 0xcf, 0xfa, 0xed })); // truncated magic
    try std.testing.expect(!c_import.objectMagicOk(&.{}));
}

test "cSourceCacheKey: triple and sysroot vary the key; absent is not empty" {
    const other_triple = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, none, VER, "x86_64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other_triple);

    const other_sysroot = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, none, VER, "arm64-apple-darwin", "/ndk");
    try std.testing.expect(baseKey() != other_sysroot);

    const absent = c_import.cSourceCacheKey(SRC, none, none, none, none, none, none, VER, null, null);
    const empty = c_import.cSourceCacheKey(SRC, none, none, none, none, none, none, VER, "", "");
    try std.testing.expect(absent != empty);
}

var g_test_threaded: ?std.Io.Threaded = null;
fn testIo() std.Io {
    if (g_test_threaded == null) {
        g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_test_threaded.?.io();
}

/// Parse `header` as the one `@include` of an `@import c` unit and return the
/// synthesized extern decls.
fn importHeader(
    alloc: std.mem.Allocator,
    header: []const u8,
    flags: []const []const u8,
) !c_import.CImportResult {
    const io = testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "h.h", .data = header });
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const path = try std.fmt.allocPrint(alloc, "{s}/h.h", .{buf[0..len]});
    return c_import.processCImport(alloc, &.{path}, &.{}, flags);
}

fn findFn(result: c_import.CImportResult, name: []const u8) !ast.FnDecl {
    for (result.fn_decls) |d| {
        if (d.data == .fn_decl and std.mem.eql(u8, d.data.fn_decl.name, name)) return d.data.fn_decl;
    }
    return error.NoSuchDecl;
}

fn isCursorParam(p: ast.Param) bool {
    return p.type_expr.data == .type_expr and
        std.mem.eql(u8, p.type_expr.data.type_expr.name, "@VaList");
}

test "processCImport: a variadic prototype imports with the bare `..` tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try importHeader(alloc,
        \\int tally(int n, ...);
        \\int fixed(int n);
    , &.{});

    const tally = try findFn(result, "tally");
    try std.testing.expect(tally.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 1), tally.params.len);

    const fixed = try findFn(result, "fixed");
    try std.testing.expect(!fixed.is_c_variadic);
}

// C23 permits a variadic prototype with no named parameter, so the fixed count
// may be zero.
test "processCImport: a zero-fixed C23 variadic prototype imports with the tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try importHeader(alloc, "long long all(...);", &.{"-std=c23"});

    const all = try findFn(result, "all");
    try std.testing.expect(all.is_c_variadic);
    try std.testing.expectEqual(@as(usize, 0), all.params.len);
}

test "processCImport: a `va_list` parameter imports as the `@VaList` boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try importHeader(alloc,
        \\#include <stdarg.h>
        \\int direct(const char *fmt, va_list ap);
        \\typedef va_list aliased_t;
        \\int aliased(aliased_t ap);
        \\int builtin(__builtin_va_list ap);
    , &.{});

    const direct = try findFn(result, "direct");
    try std.testing.expectEqual(@as(usize, 2), direct.params.len);
    try std.testing.expect(!isCursorParam(direct.params[0]));
    try std.testing.expect(isCursorParam(direct.params[1]));

    // A typedef of `va_list` is still the same list.
    try std.testing.expect(isCursorParam((try findFn(result, "aliased")).params[0]));
    try std.testing.expect(isCursorParam((try findFn(result, "builtin")).params[0]));
}

// The cursor is recognized by typedef identity. Nothing that merely
// canonicalizes to what `va_list` canonicalizes to on some target — `char *`
// here, an array of records elsewhere — may reach the boundary.
test "processCImport: a `va_list` lookalike stays an ordinary parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try importHeader(alloc,
        \\typedef char *lookalike_t;
        \\struct __va_list_tag { int gp_offset; };
        \\int by_typedef(lookalike_t ap);
        \\int by_pointer(char *ap);
        \\int by_array(struct __va_list_tag ap[1]);
    , &.{});

    try std.testing.expect(!isCursorParam((try findFn(result, "by_typedef")).params[0]));
    try std.testing.expect(!isCursorParam((try findFn(result, "by_pointer")).params[0]));
    try std.testing.expect(!isCursorParam((try findFn(result, "by_array")).params[0]));
}

test "scanQuotedIncludes: quoted forms collected in order, angle and noise skipped" {
    const src =
        \\#include "a.h"
        \\  #  include   "sub/b.h"
        \\#include <system.h>
        \\#includex "not_an_include.h"
        \\int f(void);
        \\#include ""
        \\#include "c.h"
    ;
    var out = std.ArrayList([]const u8).empty;
    try c_import.scanQuotedIncludes(std.testing.allocator, src, &out);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("a.h", out.items[0]);
    try std.testing.expectEqualStrings("sub/b.h", out.items[1]);
    try std.testing.expectEqualStrings("c.h", out.items[2]);
}
