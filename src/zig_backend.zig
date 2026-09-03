//! Discovery for the bundled-`zig` link backend.
//!
//! When `sx build` links a native binary, it can drive a bundled `zig` as
//! `zig cc` instead of the host's system `cc`. `zig cc` brings its own lld,
//! CRT objects, and libc (musl/glibc/mingw) for the target — making a
//! distributed sx able to finish a build with no host toolchain installed.
//!
//! This module only *locates* a usable `zig`. The decision of whether to use
//! it, and the construction of the `zig cc -target … -static` argv, live in
//! `target.zig` (which has the TargetConfig it needs). Design-of-record:
//! `design/bundled-zig-link-backend-design.md`.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn _NSGetExecutablePath(buf: [*]u8, len: *u32) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Trace discovery when `SX_DEBUG_ZIG` is set (mirrors `SX_DEBUG_STDLIB`).
fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("SX_DEBUG_ZIG") != null) std.debug.print("[sx] " ++ fmt, args);
}

fn fileExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return access(@ptrCast(&buf), 0) == 0; // 0 == F_OK
}

/// Path of the running `sx` binary. Mirrors imports.zig's resolver (no Io
/// dependency): `_NSGetExecutablePath` on Darwin, `/proc/self/exe` on Linux.
fn selfExePath(buf: []u8) ![]const u8 {
    switch (builtin.os.tag) {
        .macos, .ios => {
            var len: u32 = @intCast(buf.len);
            if (_NSGetExecutablePath(buf.ptr, &len) != 0) return error.PathBufferTooSmall;
            return std.mem.sliceTo(buf[0..buf.len], 0);
        },
        .linux => {
            // Zig 0.16 moved the filesystem API to the io-based `std.Io.Dir`
            // (there is no io-free `std.posix.readlink` anymore); use the raw
            // linux syscall wrapper, which needs no `io` handle.
            const rc = std.os.linux.readlink("/proc/self/exe", buf.ptr, buf.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return buf[0..rc],
                else => return error.ReadSelfExeFailed,
            }
        },
        else => return error.UnsupportedHostOS,
    }
}

/// A discovered `zig`. `bundled` distinguishes a distribution-bundled (or
/// deliberately-pinned) zig — which auto-activates the backend — from a
/// PATH-resolved one, which is a dev convenience and only used when forced
/// via `--self-contained`.
pub const Found = struct {
    path: []const u8,
    bundled: bool,
};

/// Resolution order (first hit wins):
///   1. $SX_ZIG                          — explicit override   (bundled=true)
///   2. <exe_dir>/../libexec/zig/zig     — install layout      (bundled=true)
///   3. <exe_dir>/../../zig-bundle/zig   — dev vendored layout (bundled=true)
///   4. `zig` on $PATH                   — dev fallback         (bundled=false)
/// Returns an allocator-owned path + provenance, or null if none resolve.
pub fn discoverZig(allocator: std.mem.Allocator) ?Found {
    // 1. Explicit override — a deliberate pin, treated as bundled.
    if (std.c.getenv("SX_ZIG")) |env| {
        const p = std.mem.span(env);
        if (fileExists(p)) {
            dbg("zig: SX_ZIG={s}\n", .{p});
            return .{ .path = allocator.dupe(u8, p) catch return null, .bundled = true };
        }
        dbg("zig: SX_ZIG={s} (not found, ignoring)\n", .{p});
    }

    // 2 & 3. Exe-relative candidates — a real distribution.
    var buf: [4096]u8 = undefined;
    if (selfExePath(&buf)) |exe| {
        const exe_dir = std.fs.path.dirname(exe) orelse exe;
        const rels = [_][]const u8{ "../libexec/zig/zig", "../../zig-bundle/zig" };
        for (rels) |rel| {
            const cand = std.fs.path.join(allocator, &.{ exe_dir, rel }) catch continue;
            if (fileExists(cand)) {
                dbg("zig: bundled={s}\n", .{cand});
                return .{ .path = cand, .bundled = true };
            }
            dbg("zig: tried {s} (absent)\n", .{cand});
            allocator.free(cand);
        }
    } else |_| {}

    // 4. $PATH fallback — dev convenience; does not auto-engage.
    if (findOnPath(allocator, "zig")) |p| {
        dbg("zig: PATH={s}\n", .{p});
        return .{ .path = p, .bundled = false };
    }

    dbg("zig: none found — falling back to system cc\n", .{});
    return null;
}

fn findOnPath(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const path_env = std.c.getenv("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, std.mem.span(path_env), ':');
    while (it.next()) |dir| {
        const cand = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        if (fileExists(cand)) return cand;
        allocator.free(cand);
    }
    return null;
}
