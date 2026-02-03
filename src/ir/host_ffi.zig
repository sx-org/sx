//! Host FFI dispatch for the IR interpreter.
//!
//! When the interpreter encounters a call to an extern function during `#run`
//! (or post-link interpretation), it has no body to walk. This module
//! `dlsym`s the symbol from the host's already-loaded dylibs (libc, libSystem,
//! kernel32, whatever the OS provides) and calls it via an arity-switched
//! cdecl function pointer.
//!
//! Limits:
//!   * Up to 8 cdecl-passed arguments. Beyond that, return error.
//!   * All arguments are marshalled to / from `usize`. Pointer-sized integers,
//!     pointers, null-terminated strings, and booleans are supported; floats,
//!     aggregates passed by value, and varargs are not.
//!   * Return value can be void, integer (i64), pointer (usize), or boolean.

const std = @import("std");
const builtin = @import("builtin");

// `RTLD_DEFAULT` — the dlsym pseudo-handle for "search every loaded image" —
// has a DIFFERENT value per libc: glibc/Linux defines it as `(void*)0` (NULL),
// while macOS/BSD use `(void*)-2`. Passing the wrong one makes dlsym segfault
// (a -2 handle on glibc dereferences a near-null address). Pick by target.
const RTLD_DEFAULT: ?*anyopaque = switch (builtin.os.tag) {
    .linux => null,
    else => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))),
};

extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

/// Look up an extern symbol in the host's loaded image. Returns null if not
/// found.
pub fn lookupSymbol(allocator: std.mem.Allocator, name: []const u8) !?*anyopaque {
    const name_z = try allocator.allocSentinel(u8, name.len, 0);
    defer allocator.free(name_z);
    @memcpy(name_z[0..name.len], name);
    return dlsym(RTLD_DEFAULT, name_z.ptr);
}

/// Call a cdecl symbol that returns `i64`. Args are pre-marshalled to `usize`.
pub fn callIntRet(symbol: *anyopaque, args: []const usize) !i64 {
    return switch (args.len) {
        0 => @as(*const fn () callconv(.c) i64, @ptrCast(@alignCast(symbol)))(),
        1 => @as(*const fn (usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0]),
        2 => @as(*const fn (usize, usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
        3 => @as(*const fn (usize, usize, usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
        4 => @as(*const fn (usize, usize, usize, usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (usize, usize, usize, usize, usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4]),
        6 => @as(*const fn (usize, usize, usize, usize, usize, usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5]),
        7 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6]),
        8 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]),
        else => return error.TooManyArgs,
    };
}

/// Call a cdecl symbol that returns a pointer (or any pointer-sized value).
pub fn callPtrRet(symbol: *anyopaque, args: []const usize) !usize {
    return switch (args.len) {
        0 => @as(*const fn () callconv(.c) usize, @ptrCast(@alignCast(symbol)))(),
        1 => @as(*const fn (usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0]),
        2 => @as(*const fn (usize, usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
        3 => @as(*const fn (usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
        4 => @as(*const fn (usize, usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (usize, usize, usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4]),
        6 => @as(*const fn (usize, usize, usize, usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5]),
        7 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6]),
        8 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]),
        else => return error.TooManyArgs,
    };
}

/// Call a cdecl symbol with void return.
pub fn callVoidRet(symbol: *anyopaque, args: []const usize) !void {
    switch (args.len) {
        0 => @as(*const fn () callconv(.c) void, @ptrCast(@alignCast(symbol)))(),
        1 => @as(*const fn (usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0]),
        2 => @as(*const fn (usize, usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
        3 => @as(*const fn (usize, usize, usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
        4 => @as(*const fn (usize, usize, usize, usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (usize, usize, usize, usize, usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4]),
        6 => @as(*const fn (usize, usize, usize, usize, usize, usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5]),
        7 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6]),
        8 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]),
        else => return error.TooManyArgs,
    }
}

// ── Variadic cdecl dispatch ─────────────────────────────────────────
// For extern functions declared with `args: ..T` (C-variadic, e.g.
// libc `open(path, flags, ...)`). The trailing args must be passed
// through the C-variadic ABI — arm64 places them on the stack rather
// than in argument registers. Calling a variadic function as if it
// were fixed-arity puts the mode/etc. in the wrong register and the
// callee reads garbage.
//
// The dispatch is keyed by (fixed_count, total_args). `fixed_count`
// is the number of declared (non-variadic) params; trailing
// `total_args - fixed_count` slots are the variadic tail. The Zig
// function-pointer types use `...` so the compiler emits
// proper-variadic calls.

pub fn callIntRetVar(symbol: *anyopaque, fixed: usize, args: []const usize) !i64 {
    if (args.len < fixed) return error.TooFewArgs;
    // Special-case the shapes we actually use today; extend as
    // needed. fixed_count > total is impossible.
    return switch (fixed) {
        2 => switch (args.len) {
            2 => @as(*const fn (usize, usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
            3 => @as(*const fn (usize, usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
            4 => @as(*const fn (usize, usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
            5 => @as(*const fn (usize, usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4]),
            else => return error.TooManyArgs,
        },
        1 => switch (args.len) {
            1 => @as(*const fn (usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0]),
            2 => @as(*const fn (usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
            3 => @as(*const fn (usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
            4 => @as(*const fn (usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
            5 => @as(*const fn (usize, ...) callconv(.c) i64, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3], args[4]),
            else => return error.TooManyArgs,
        },
        else => return error.UnsupportedVariadicArity,
    };
}

pub fn callPtrRetVar(symbol: *anyopaque, fixed: usize, args: []const usize) !usize {
    if (args.len < fixed) return error.TooFewArgs;
    return switch (fixed) {
        2 => switch (args.len) {
            2 => @as(*const fn (usize, usize, ...) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
            3 => @as(*const fn (usize, usize, ...) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
            4 => @as(*const fn (usize, usize, ...) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
            else => return error.TooManyArgs,
        },
        1 => switch (args.len) {
            1 => @as(*const fn (usize, ...) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0]),
            2 => @as(*const fn (usize, ...) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
            3 => @as(*const fn (usize, ...) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
            4 => @as(*const fn (usize, ...) callconv(.c) usize, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
            else => return error.TooManyArgs,
        },
        else => return error.UnsupportedVariadicArity,
    };
}

pub fn callVoidRetVar(symbol: *anyopaque, fixed: usize, args: []const usize) !void {
    if (args.len < fixed) return error.TooFewArgs;
    switch (fixed) {
        2 => switch (args.len) {
            2 => @as(*const fn (usize, usize, ...) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
            3 => @as(*const fn (usize, usize, ...) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
            4 => @as(*const fn (usize, usize, ...) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
            else => return error.TooManyArgs,
        },
        1 => switch (args.len) {
            1 => @as(*const fn (usize, ...) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0]),
            2 => @as(*const fn (usize, ...) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1]),
            3 => @as(*const fn (usize, ...) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2]),
            4 => @as(*const fn (usize, ...) callconv(.c) void, @ptrCast(@alignCast(symbol)))(args[0], args[1], args[2], args[3]),
            else => return error.TooManyArgs,
        },
        else => return error.UnsupportedVariadicArity,
    }
}
