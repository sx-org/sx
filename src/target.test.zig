const std = @import("std");
const target = @import("target.zig");
const TargetConfig = target.TargetConfig;

test "optimization levels select matching LLVM and Clang pipelines" {
    try std.testing.expect(TargetConfig.OptLevel.none.toLLVMPassPipeline() == null);
    try std.testing.expectEqualStrings("default<O1>", TargetConfig.OptLevel.less.toLLVMPassPipeline().?);
    try std.testing.expectEqualStrings("default<O2>", TargetConfig.OptLevel.default.toLLVMPassPipeline().?);
    try std.testing.expectEqualStrings("default<O3>", TargetConfig.OptLevel.aggressive.toLLVMPassPipeline().?);

    try std.testing.expectEqualStrings("-O0", TargetConfig.OptLevel.none.toClangFlag());
    try std.testing.expectEqualStrings("-O1", TargetConfig.OptLevel.less.toClangFlag());
    try std.testing.expectEqualStrings("-O2", TargetConfig.OptLevel.default.toClangFlag());
    try std.testing.expectEqualStrings("-O3", TargetConfig.OptLevel.aggressive.toClangFlag());
}

test "a native Linux build compiles C imports against the libc it links" {
    // No `--target`: the shape `sx build` takes on a native Linux host, where
    // the zig backend links a synthesized musl triple. The `#import c` headers
    // must be musl too — glibc's LFS redirects reference open64/stat64/…,
    // which musl does not define.
    const a = std.testing.allocator;
    const native: TargetConfig = .{};

    const ht = (try target.libcHeaderTarget(native, a, .linux)).?;
    defer a.free(ht.triple);
    try std.testing.expect(std.mem.indexOf(u8, ht.triple, "linux-musl") != null);
    try std.testing.expectEqualStrings("musl", ht.layout.abi_suffix);
    try std.testing.expectEqualStrings("generic-musl", ht.layout.generic);
}

test "libcHeaderTarget: an explicit --target keeps its own libc" {
    const a = std.testing.allocator;
    const cross: TargetConfig = .{ .triple = "aarch64-linux-gnu" };

    const ht = (try target.libcHeaderTarget(cross, a, .macos)).?;
    defer a.free(ht.triple);
    try std.testing.expectEqualStrings("aarch64-linux-gnu", ht.triple);
    try std.testing.expectEqualStrings("gnu", ht.layout.abi_suffix);

    // A native macOS build links libSystem — no zig libc headers.
    const native: TargetConfig = .{};
    try std.testing.expect(try target.libcHeaderTarget(native, a, .macos) == null);
}

test "libcHeaderLayout: abi and arch spellings follow the link triple" {
    const musl = (try target.libcHeaderLayout("x86_64-linux-musl")).?;
    try std.testing.expectEqualStrings("x86_64", musl.full_arch);
    try std.testing.expectEqualStrings("x86", musl.family_arch);
    try std.testing.expectEqualStrings("musl", musl.abi_suffix);
    try std.testing.expectEqualStrings("generic-musl", musl.generic);

    const gnu = (try target.libcHeaderLayout("aarch64-linux-gnu")).?;
    try std.testing.expectEqualStrings("aarch64", gnu.full_arch);
    try std.testing.expectEqualStrings("aarch64", gnu.family_arch);
    try std.testing.expectEqualStrings("gnu", gnu.abi_suffix);
    try std.testing.expectEqualStrings("generic-glibc", gnu.generic);

    // An unspecified abi is musl — zig's default for a Linux target.
    const bare = (try target.libcHeaderLayout("aarch64-linux")).?;
    try std.testing.expectEqualStrings("musl", bare.abi_suffix);
}

test "libcHeaderLayout: only plain Linux triples carry a zig libc header set" {
    try std.testing.expect(try target.libcHeaderLayout("aarch64-macos-none") == null);
    try std.testing.expect(try target.libcHeaderLayout("x86_64-windows-gnu") == null);
    try std.testing.expect(try target.libcHeaderLayout("wasm32-unknown-emscripten") == null);
    // Android's bionic headers come from the NDK sysroot.
    try std.testing.expect(try target.libcHeaderLayout("aarch64-linux-android21") == null);
}
