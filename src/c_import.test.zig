const std = @import("std");
const c_import = @import("c_import.zig");

const SRC = "int f(void) { return 1; }";
const HDR = "int f(void);";
const DEP = "#define INNER 1";
const VER = "19.1.7";

const none: []const []const u8 = &.{};

fn baseKey() u64 {
    return c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
}

test "cSourceCacheKey: stable when nothing changes" {
    try std.testing.expectEqual(baseKey(), baseKey());
}

test "cSourceCacheKey: source bytes vary the key" {
    const other = c_import.cSourceCacheKey("int f(void) { return 2; }", &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: declared header content varies the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{"int f(void); int g(void);"}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: transitive dep content varies the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{"#define INNER 2"}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);

    // a header is not a dep (same string, different role)
    const as_header = c_import.cSourceCacheKey(SRC, &.{"X"}, none, none, none, none, VER, null, null);
    const as_dep = c_import.cSourceCacheKey(SRC, none, &.{"X"}, none, none, none, VER, null, null);
    try std.testing.expect(as_header != as_dep);
}

test "cSourceCacheKey: defines vary the key (value and order)" {
    const v2 = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=2"}, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != v2);

    const ab = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{ "A=1", "B=1" }, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
    const ba = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{ "B=1", "A=1" }, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(ab != ba);
}

test "cSourceCacheKey: flags vary the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O3"}, &.{"inc"}, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: a define is not a flag (same string, different role)" {
    const as_define = c_import.cSourceCacheKey(SRC, none, none, &.{"X"}, none, none, VER, null, null);
    const as_flag = c_import.cSourceCacheKey(SRC, none, none, none, &.{"X"}, none, VER, null, null);
    try std.testing.expect(as_define != as_flag);
}

test "cSourceCacheKey: include dirs vary the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"other"}, VER, "arm64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other);
}

test "cSourceCacheKey: llvm version varies the key" {
    const other = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, "20.0.0", "arm64-apple-darwin", "/sdk");
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
    const other_triple = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, VER, "x86_64-apple-darwin", "/sdk");
    try std.testing.expect(baseKey() != other_triple);

    const other_sysroot = c_import.cSourceCacheKey(SRC, &.{HDR}, &.{DEP}, &.{"A=1"}, &.{"-O2"}, &.{"inc"}, VER, "arm64-apple-darwin", "/ndk");
    try std.testing.expect(baseKey() != other_sysroot);

    const absent = c_import.cSourceCacheKey(SRC, none, none, none, none, none, VER, null, null);
    const empty = c_import.cSourceCacheKey(SRC, none, none, none, none, none, VER, "", "");
    try std.testing.expect(absent != empty);
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
