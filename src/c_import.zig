const std = @import("std");
const ast = @import("ast.zig");
const llvm = @import("llvm_api.zig");
const Node = ast.Node;
const c = llvm.c;
const builtin = @import("builtin");

pub const CSourceLocation = struct {
    file: []const u8,
    line: u32,
};

/// Derive the NDK sysroot path from the NDK root (which by convention
/// lives in `target_config.sysroot` on Android — see target.zig's
/// Android link branch + main.zig's auto-discovery). Returns a NUL-
/// terminated path suitable for clang's `--sysroot <path>` argv.
fn androidSysrootFromNdkRoot(allocator: std.mem.Allocator, ndk_root: []const u8) ![:0]u8 {
    const host_tag: []const u8 = if (builtin.os.tag == .macos) "darwin-x86_64" else "linux-x86_64";
    return try std.fmt.allocPrintSentinel(allocator, "{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk_root, host_tag }, 0);
}

pub const CImportResult = struct {
    fn_decls: []const *Node,
    /// Source locations for each fn_decl (parallel array, same indices).
    locations: []const CSourceLocation,
};

/// Info collected from c_import_decl AST nodes for native compilation.
pub const CImportInfo = struct {
    sources: []const []const u8,
    includes: []const []const u8,
    defines: []const []const u8,
    flags: []const []const u8,
};

/// Cache key for one compiled `#source` member. Everything that can
/// change the produced object participates: the source bytes, the
/// unit's declared `#include` headers BY CONTENT, the source's
/// TRANSITIVE quoted includes BY CONTENT (`dep_bytes` — editing any
/// header the compile actually reads invalidates), defines / flags /
/// include dirs in declaration order, the toolchain version, and the
/// cross-target (triple + sysroot). Section tags keep equal strings
/// in different roles distinct (a define never aliases a flag, an
/// absent triple never aliases an empty one).
pub fn cSourceCacheKey(
    source_bytes: []const u8,
    header_bytes: []const []const u8,
    dep_bytes: []const []const u8,
    defines: []const []const u8,
    flags: []const []const u8,
    include_dirs: []const []const u8,
    llvm_version: []const u8,
    triple: ?[]const u8,
    sysroot: ?[]const u8,
) u64 {
    const Wyhash = std.hash.Wyhash;
    var key = Wyhash.hash(0, "sx-c-import-v1");
    key = Wyhash.hash(key, source_bytes);
    key = Wyhash.hash(key, "\x01headers");
    for (header_bytes) |hb| key = Wyhash.hash(key, hb);
    key = Wyhash.hash(key, "\x01deps");
    for (dep_bytes) |db| key = Wyhash.hash(key, db);
    key = Wyhash.hash(key, "\x01defines");
    for (defines) |d| key = Wyhash.hash(key, d);
    key = Wyhash.hash(key, "\x01flags");
    for (flags) |f| key = Wyhash.hash(key, f);
    key = Wyhash.hash(key, "\x01incdirs");
    for (include_dirs) |inc| key = Wyhash.hash(key, inc);
    key = Wyhash.hash(key, "\x01llvm");
    key = Wyhash.hash(key, llvm_version);
    if (triple) |t| {
        key = Wyhash.hash(key, "\x01triple");
        key = Wyhash.hash(key, t);
    }
    if (sysroot) |sr| {
        key = Wyhash.hash(key, "\x01sysroot");
        key = Wyhash.hash(key, sr);
    }
    return key;
}

/// Quoted `#include "x"` targets in `source`, appended to `out` in
/// order of appearance. Angle includes (<...>) are system headers and
/// never participate in invalidation. Over-collection (an include
/// inside an inactive `#if` branch) is harmless: an extra existing
/// file gets hashed, a missing one is skipped at resolution.
pub fn scanQuotedIncludes(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        var s = std.mem.trimStart(u8, line, " \t");
        if (s.len == 0 or s[0] != '#') continue;
        s = std.mem.trimStart(u8, s[1..], " \t");
        if (!std.mem.startsWith(u8, s, "include")) continue;
        s = std.mem.trimStart(u8, s["include".len..], " \t");
        if (s.len < 2 or s[0] != '"') continue;
        const rest = s[1..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        if (end == 0) continue;
        try out.append(allocator, rest[0..end]);
    }
}

/// The transitive closure of quoted includes reachable from
/// `root_path`/`root_bytes`, each include resolved against its
/// includer's directory first and the unit's include dirs second;
/// unresolvable names (system or conditionally-absent includes) are
/// skipped. Returns the file CONTENTS of every dependency for
/// cache-key participation — editing any header the compile actually
/// reads must change the key.
fn collectIncludeDepBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_bytes: []const u8,
    include_dirs: []const []const u8,
) ![]const []const u8 {
    const Pending = struct { path: []const u8, bytes: []const u8 };

    var dep_bytes = std.ArrayList([]const u8).empty;
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    var queue = std.ArrayList(Pending).empty;
    try queue.append(allocator, .{ .path = root_path, .bytes = root_bytes });

    var idx: usize = 0;
    while (idx < queue.items.len) : (idx += 1) {
        const item = queue.items[idx];
        var incs = std.ArrayList([]const u8).empty;
        try scanQuotedIncludes(allocator, item.bytes, &incs);
        const base = dirName(item.path);
        for (incs.items) |inc| {
            var candidates = std.ArrayList([]const u8).empty;
            try candidates.append(allocator, try std.fs.path.join(allocator, &.{ base, inc }));
            for (include_dirs) |dir| {
                try candidates.append(allocator, try std.fs.path.join(allocator, &.{ dir, inc }));
            }
            for (candidates.items) |cand| {
                const norm = std.fs.path.resolve(allocator, &.{cand}) catch cand;
                if (visited.contains(norm)) break;
                const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, cand, allocator, .limited(64 * 1024 * 1024)) catch continue;
                try visited.put(norm, {});
                try dep_bytes.append(allocator, bytes);
                try queue.append(allocator, .{ .path = cand, .bytes = bytes });
                break;
            }
        }
    }
    return try dep_bytes.toOwnedSlice(allocator);
}

/// Handle returned from loadCObjectsForJIT — caller must call unload() after JIT.
pub const CImportHandle = struct {
    dylib_handle: ?*anyopaque = null,
    /// Where the unit's linked dylib lives for THIS run; the JIT adds it
    /// as a priority symbol-search target ahead of the process images.
    dylib_path: ?[:0]const u8 = null,
    temp_paths: []const []const u8 = &.{},
    allocator: std.mem.Allocator,

    pub fn unload(self: *CImportHandle, io: std.Io) void {
        // dlclose
        if (self.dylib_handle) |h| {
            _ = std.c.dlclose(h);
        }
        // Clean up temp files
        for (self.temp_paths) |path| {
            std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
        }
    }
};

/// Parse C headers to extract function declarations as synthetic AST nodes.
/// Called during import resolution (no LLVM context needed).
pub fn processCImport(
    allocator: std.mem.Allocator,
    includes: []const []const u8,
    defines: []const []const u8,
    flags: []const []const u8,
) !CImportResult {
    // Build clang args: -I dirs, -D defines, raw flags
    var args_list = std.ArrayList([*c]const u8).empty;

    for (includes) |inc| {
        const dir = dirName(inc);
        const arg = try allocPrintZ(allocator, "-I{s}", .{dir});
        try args_list.append(allocator, arg.ptr);
    }
    for (defines) |def| {
        const arg = try allocPrintZ(allocator, "-D{s}", .{def});
        try args_list.append(allocator, arg.ptr);
    }
    for (flags) |flag| {
        const arg = try allocator.dupeZ(u8, flag);
        try args_list.append(allocator, arg.ptr);
    }

    var all_decls = std.ArrayList(*Node).empty;
    var all_locs = std.ArrayList(CSourceLocation).empty;

    for (includes) |header| {
        const header_z = try allocator.dupeZ(u8, header);
        var err_msg: [*c]u8 = null;

        const args_ptr: [*c][*c]const u8 = if (args_list.items.len > 0)
            @ptrCast(args_list.items.ptr)
        else
            null;

        const info = c.sx_clang_parse_header(
            header_z.ptr,
            args_ptr,
            @intCast(args_list.items.len),
            &err_msg,
        );

        if (info == null) {
            if (err_msg) |e| {
                std.debug.print("clang parse error for '{s}': {s}\n", .{ header, std.mem.span(e) });
            }
            return error.CompileError;
        }
        defer c.sx_clang_free_header_info(info);

        const funcs = info.*.functions;
        const num: usize = @intCast(info.*.num_functions);

        for (0..num) |i| {
            const fi = funcs[i];
            const name = try allocator.dupe(u8, std.mem.span(fi.name));

            // Build params
            var params = std.ArrayList(ast.Param).empty;
            const np: usize = @intCast(fi.num_params);
            for (0..np) |j| {
                const pi = fi.params[j];
                const pname_raw = std.mem.span(pi.name);
                const pname = if (pname_raw.len > 0)
                    try allocator.dupe(u8, pname_raw)
                else
                    try std.fmt.allocPrint(allocator, "p{d}", .{j});
                const ptype_str = std.mem.span(pi.type_spelling);
                const ptype_node = try mapCTypeToSxNode(allocator, ptype_str);

                try params.append(allocator, .{
                    .name = pname,
                    .name_span = .{ .start = 0, .end = 0 },
                    .type_expr = ptype_node,
                    // Extern C param names (`i1`, `i2`, …) are RAW — exempt from
                    // the reserved-type-name binding check; generated bindings
                    // must import without hand-edits.
                    .is_raw = true,
                });
            }

            // Return type
            const ret_str = std.mem.span(fi.return_type);
            const ret_node = if (std.mem.eql(u8, ret_str, "void"))
                null
            else
                try mapCTypeToSxNode(allocator, ret_str);

            // Extern-import body: an empty block + `extern_export = .extern_` (no
            // LIB / csym — symbols resolve at runtime). Same shape the postfix
            // `extern` keyword produces; lowering reads `extern_export`.
            const extern_body = try allocator.create(Node);
            extern_body.* = .{
                .span = .{ .start = 0, .end = 0 },
                .data = .{ .block = .{ .stmts = &.{}, .produces_value = false } },
            };

            const fn_node = try allocator.create(Node);
            fn_node.* = .{
                .span = .{ .start = 0, .end = 0 },
                .data = .{ .fn_decl = .{
                    .name = name,
                    .params = try params.toOwnedSlice(allocator),
                    .return_type = ret_node,
                    .body = extern_body,
                    .extern_export = .extern_,
                    // A C function whose own NAME collides with a reserved type
                    // spelling (`int i2(int);`) is RAW — exempt from the
                    // reserved-type-name decl check so generated bindings import
                    // without hand-edits.
                    .is_raw = true,
                } },
            };

            try all_decls.append(allocator, fn_node);

            // Collect source location
            const src_file = if (fi.source_file) |sf|
                try allocator.dupe(u8, std.mem.span(sf))
            else
                header;
            try all_locs.append(allocator, .{
                .file = src_file,
                .line = @intCast(fi.source_line),
            });
        }
    }

    return .{
        .fn_decls = try all_decls.toOwnedSlice(allocator),
        .locations = try all_locs.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------------------
// Native C compilation (compile to .o, not LLVM module)
// ---------------------------------------------------------------------------

// ── extern ref validation ───────────────────────────────────────────

fn collectExternRefTargets(valid: *std.StringHashMap(void), decls: []const *Node) !void {
    for (decls) |d| {
        switch (d.data) {
            .library_decl => |ld| try valid.put(ld.name, {}),
            .namespace_decl => |ns| {
                // A NAMED `#import c` unit lowers to a namespace wrapping
                // its c_import_decl — the namespace name is the unit ref.
                for (ns.decls) |nd| {
                    if (nd.data == .c_import_decl) {
                        try valid.put(ns.name, {});
                        break;
                    }
                }
                try collectExternRefTargets(valid, ns.decls);
            },
            else => {},
        }
    }
}

fn checkExternRefs(valid: *const std.StringHashMap(void), decls: []const *Node, diags: *@import("errors.zig").DiagnosticList) void {
    for (decls) |d| {
        switch (d.data) {
            .fn_decl => |fd| {
                // A library reference rides on the `extern LIB` keyword
                // (extern_lib); it must name a declared #library / #import c unit.
                if (fd.extern_export != .extern_) continue;
                const ref = fd.extern_lib orelse continue;
                if (!valid.contains(ref)) {
                    diags.addFmt(.err, d.span, "extern library '{s}' is not declared; expected a #library constant or a named '#import c' unit", .{ref});
                }
            },
            .namespace_decl => |ns| checkExternRefs(valid, ns.decls, diags),
            else => {},
        }
    }
}

/// Validate every `extern <ref>` in the merged program: the ref must
/// name a `#library` constant or a NAMED `#import c` unit. Refs are
/// author-side module-local names, but modules merge flat or
/// namespaced into one tree, so existence is checked program-wide.
/// Decls synthesized from `#include` headers carry no ref and are
/// exempt.
pub fn validateExternRefs(allocator: std.mem.Allocator, root: *const Node, diags: *@import("errors.zig").DiagnosticList) !void {
    if (root.data != .root) return;
    var valid = std.StringHashMap(void).init(allocator);
    defer valid.deinit();
    try collectExternRefTargets(&valid, root.data.root.decls);
    checkExternRefs(&valid, root.data.root.decls, diags);
}

/// A cached entry must at least LOOK like an object file (Mach-O,
/// ELF, or wasm magic) — a truncated or garbage entry falls back to a
/// fresh compile instead of poisoning the link with an opaque error.
pub fn objectMagicOk(data: []const u8) bool {
    if (data.len < 4) return false;
    if (data[0] == 0x7f and data[1] == 'E' and data[2] == 'L' and data[3] == 'F') return true;
    if (data[0] == 0xcf and data[1] == 0xfa and data[2] == 0xed and data[3] == 0xfe) return true; // Mach-O 64
    if (data[0] == 0xce and data[1] == 0xfa and data[2] == 0xed and data[3] == 0xfe) return true; // Mach-O 32
    if (data[0] == 0x00 and data[1] == 'a' and data[2] == 's' and data[3] == 'm') return true; // wasm (emcc -c)
    return false;
}

fn loadCachedObject(path: [:0]const u8) ?c.LLVMMemoryBufferRef {
    var buf: c.LLVMMemoryBufferRef = null;
    var err_msg: [*c]u8 = null;
    if (c.LLVMCreateMemoryBufferWithContentsOfFile(path.ptr, &buf, &err_msg) != 0) {
        if (err_msg != null) c.LLVMDisposeMessage(err_msg);
        return null;
    }
    const start = c.LLVMGetBufferStart(buf);
    const size = c.LLVMGetBufferSize(buf);
    if (start == null or size < 4) {
        c.LLVMDisposeMemoryBuffer(buf);
        return null;
    }
    const data = @as([*]const u8, @ptrCast(start))[0..size];
    if (!objectMagicOk(data)) {
        c.LLVMDisposeMemoryBuffer(buf);
        return null;
    }
    return buf;
}

// Best-effort, never fails the build: write to a per-pid temp at the
// repo root, then copy into place (copyFile's make_path creates
// .sx-cache/ if needed) — same pattern as main.zig's object cache.
fn saveCachedObject(allocator: std.mem.Allocator, obj_buf: c.LLVMMemoryBufferRef, io: std.Io, cache_path: [:0]const u8) void {
    const start = c.LLVMGetBufferStart(obj_buf);
    const size = c.LLVMGetBufferSize(obj_buf);
    if (start == null or size == 0) return;
    const data = @as([*]const u8, @ptrCast(start))[0..size];
    const tmp = std.fmt.allocPrint(allocator, ".sx-c-cache-tmp-{d}", .{std.c.getpid()}) catch return;
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = tmp, .data = data }) catch return;
    std.Io.Dir.copyFile(.cwd(), tmp, .cwd(), cache_path, io, .{ .make_path = true }) catch {};
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};
}

/// Compile C sources to native object files (in memory), through a
/// persistent content-addressed cache (`.sx-cache/c-<key>.o`, default
/// on). A `#source` unit recompiles only when its cache key changes —
/// see `cSourceCacheKey` for what participates. Any cache-machinery
/// failure (unreadable input for hashing, corrupt entry) falls back to
/// a fresh compile; the cache can never fail a build.
/// Returns list of LLVMMemoryBufferRef (each containing a .o file).
pub fn compileCToObjects(
    allocator: std.mem.Allocator,
    io: std.Io,
    infos: []const CImportInfo,
    target_config: @import("target.zig").TargetConfig,
) ![]c.LLVMMemoryBufferRef {
    var obj_bufs = std.ArrayList(c.LLVMMemoryBufferRef).empty;
    var labels = std.ArrayList([]const u8).empty; // source path per buffer, for diagnostics

    var ver_maj: c_uint = 0;
    var ver_min: c_uint = 0;
    var ver_pat: c_uint = 0;
    c.LLVMGetVersion(&ver_maj, &ver_min, &ver_pat);
    const llvm_version = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ ver_maj, ver_min, ver_pat });
    const triple_slice: ?[]const u8 = if (target_config.triple) |t| std.mem.span(t) else null;
    const opt_flag = target_config.opt_level.toClangFlag();

    for (infos) |info| {
        if (info.sources.len == 0) continue;

        // Build clang args: -I dirs, -D defines, raw flags
        var args_list = std.ArrayList([*c]const u8).empty;
        // Cross-compile target: forward -target / -isysroot when set.
        if (target_config.triple) |t| {
            try args_list.append(allocator, "-target");
            try args_list.append(allocator, t);
        }
        if (target_config.sysroot) |sr| {
            try args_list.append(allocator, "-isysroot");
            try args_list.append(allocator, (try allocator.dupeZ(u8, sr)).ptr);
        }
        // Android: route through the NDK sysroot so bionic headers resolve.
        // The embedded clang library doesn't know how to be an Android cross-
        // compiler on its own. `target_config.sysroot` holds the NDK root
        // by convention (main.zig auto-fills it for --target android), so
        // derive the headers/libs sysroot inside it.
        if (target_config.isAndroid()) {
            if (target_config.sysroot) |ndk_root| {
                const sysroot = try androidSysrootFromNdkRoot(allocator, ndk_root);
                try args_list.append(allocator, "--sysroot");
                try args_list.append(allocator, sysroot.ptr);
            }
        }
        // Linux cross-target: the embedded clang has no libc headers for a
        // foreign Linux target. Point it at the bundled-zig libc include set
        // (musl/glibc, mirroring `zig cc`) so `<string.h>`/`<stdio.h>` resolve.
        // `-isystem` (not `-I`) so user `-I` anchors still win and these are
        // searched as system headers (warnings suppressed). See
        // target.linuxLibcIncludeDirs.
        if (try @import("target.zig").linuxLibcIncludeDirs(allocator, io, target_config)) |libc_dirs| {
            for (libc_dirs) |dir| {
                try args_list.append(allocator, "-isystem");
                try args_list.append(allocator, (try allocator.dupeZ(u8, dir)).ptr);
            }
        }
        try args_list.append(allocator, opt_flag.ptr);
        var inc_dirs = std.ArrayList([]const u8).empty;
        for (info.includes) |inc| {
            const dir = dirName(inc);
            try inc_dirs.append(allocator, dir);
            try args_list.append(allocator, (try allocPrintZ(allocator, "-I{s}", .{dir})).ptr);
        }
        for (info.defines) |def| {
            try args_list.append(allocator, (try allocPrintZ(allocator, "-D{s}", .{def})).ptr);
        }
        for (info.flags) |flag| {
            try args_list.append(allocator, (try allocator.dupeZ(u8, flag)).ptr);
        }

        // The effective optimization flag participates in the persistent cache
        // key. User flags follow it (and therefore may deliberately override it).
        var cache_flags = std.ArrayList([]const u8).empty;
        try cache_flags.append(allocator, opt_flag);
        try cache_flags.appendSlice(allocator, info.flags);

        const args_ptr: [*c][*c]const u8 = if (args_list.items.len > 0)
            @ptrCast(args_list.items.ptr)
        else
            null;
        const args_len: c_int = @intCast(args_list.items.len);

        // Declared headers participate in the cache key BY CONTENT; an
        // unreadable one disables caching for this unit, never the build.
        var header_bytes = std.ArrayList([]const u8).empty;
        var cache_ok = true;
        for (info.includes) |inc| {
            const hb = std.Io.Dir.readFileAlloc(.cwd(), io, inc, allocator, .limited(64 * 1024 * 1024)) catch {
                cache_ok = false;
                break;
            };
            try header_bytes.append(allocator, hb);
        }

        for (info.sources) |src| {
            var cache_path: ?[:0]const u8 = null;
            if (cache_ok) {
                if (std.Io.Dir.readFileAlloc(.cwd(), io, src, allocator, .limited(64 * 1024 * 1024))) |src_bytes| {
                    const dep_bytes = collectIncludeDepBytes(allocator, io, src, src_bytes, inc_dirs.items) catch &.{};
                    const key = cSourceCacheKey(
                        src_bytes,
                        header_bytes.items,
                        dep_bytes,
                        info.defines,
                        cache_flags.items,
                        inc_dirs.items,
                        llvm_version,
                        triple_slice,
                        target_config.sysroot,
                    );
                    cache_path = try std.fmt.allocPrintSentinel(allocator, ".sx-cache/c-{x:0>16}.o", .{key}, 0);
                    if (loadCachedObject(cache_path.?)) |cached| {
                        try obj_bufs.append(allocator, cached);
                        try labels.append(allocator, src);
                        continue;
                    }
                } else |_| {}
            }

            const src_z = try allocator.dupeZ(u8, src);
            var err_msg: [*c]u8 = null;

            const obj_buf = c.sx_clang_compile_to_object(
                src_z.ptr,
                args_ptr,
                args_len,
                &err_msg,
            );

            if (obj_buf == null) {
                if (err_msg) |e| {
                    std.debug.print("clang compile error for '{s}': {s}\n", .{ src, std.mem.span(e) });
                }
                return error.CompileError;
            }

            if (cache_path) |cp| saveCachedObject(allocator, obj_buf, io, cp);
            try obj_bufs.append(allocator, obj_buf);
            try labels.append(allocator, src);
        }
    }

    // Cross-object duplicate exports are diagnosed HERE, before they
    // surface as an opaque dylib/binary link failure: every `#import c`
    // unit shares one link namespace (per-unit symbol isolation is
    // PLAN-C C3.2, deferred). Scan failures are non-fatal — the linker
    // remains the backstop.
    var sym_owner = std.StringHashMap(usize).init(allocator);
    defer sym_owner.deinit();
    for (obj_bufs.items, 0..) |buf, i| {
        var err_msg: [*c]u8 = null;
        const list = c.sx_clang_object_exported_symbols(buf, &err_msg);
        if (list == null) {
            if (err_msg != null) c.LLVMDisposeMessage(err_msg);
            continue;
        }
        defer c.sx_clang_free_symbol_list(list);
        const n: usize = @intCast(list.*.num_names);
        for (0..n) |j| {
            const nm = std.mem.span(list.*.names[j]);
            const gop = try sym_owner.getOrPut(try allocator.dupe(u8, nm));
            if (gop.found_existing) {
                if (gop.value_ptr.* != i) {
                    const disp = if (nm.len > 1 and nm[0] == '_') nm[1..] else nm;
                    std.debug.print("error: C symbol '{s}' is defined by multiple '#import c' sources: '{s}' and '{s}' — all units share one link namespace\n", .{ disp, labels.items[gop.value_ptr.*], labels.items[i] });
                    return error.CompileError;
                }
            } else {
                gop.value_ptr.* = i;
            }
        }
    }

    return try obj_bufs.toOwnedSlice(allocator);
}

/// For JIT mode: write .o files to temp, link into a shared library, dlopen it.
/// Returns a handle that must be unloaded after JIT execution.
pub fn loadCObjectsForJIT(
    allocator: std.mem.Allocator,
    io: std.Io,
    obj_bufs: []c.LLVMMemoryBufferRef,
) !CImportHandle {
    if (obj_bufs.len == 0) return .{ .allocator = allocator };

    var temp_paths = std.ArrayList([]const u8).empty;

    // Write each .o buffer to a temp file (per-pid names: concurrent
    // `sx run` processes must not clobber each other's link inputs)
    const pid = std.c.getpid();
    var obj_paths = std.ArrayList([]const u8).empty;
    for (obj_bufs, 0..) |buf, i| {
        const path = try std.fmt.allocPrint(allocator, "/tmp/sx_c_{d}_{d}.o", .{ pid, i });
        const start = c.LLVMGetBufferStart(buf);
        const size = c.LLVMGetBufferSize(buf);
        const data = @as([*]const u8, @ptrCast(start))[0..size];
        std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = data }) catch {
            std.debug.print("failed to write temp object: {s}\n", .{path});
            return error.CompileError;
        };
        try obj_paths.append(allocator, path);
        try temp_paths.append(allocator, path);
        c.LLVMDisposeMemoryBuffer(buf);
    }

    // Link into a shared library
    const dylib_path = try std.fmt.allocPrintSentinel(allocator, "/tmp/sx_c_import_{d}.dylib", .{pid}, 0);
    try temp_paths.append(allocator, dylib_path);

    var argv = std.ArrayList([]const u8).empty;
    try argv.append(allocator, "cc");
    if (comptime builtin.os.tag == .macos) {
        try argv.append(allocator, "-dynamiclib");
    } else {
        try argv.append(allocator, "-shared");
    }
    try argv.append(allocator, "-o");
    try argv.append(allocator, dylib_path);
    for (obj_paths.items) |op| {
        try argv.append(allocator, op);
    }

    const argv_slice = try argv.toOwnedSlice(allocator);
    var child = std.process.spawn(io, .{
        .argv = argv_slice,
    }) catch {
        std.debug.print("failed to spawn linker for C import shared library\n", .{});
        return error.CompileError;
    };
    const result = child.wait(io) catch {
        std.debug.print("linker wait failed for C import shared library\n", .{});
        return error.CompileError;
    };
    if (result != .exited or result.exited != 0) {
        std.debug.print("linker failed for C import shared library (exit={})\n", .{result.exited});
        return error.CompileError;
    }

    // dlopen the shared library
    const dylib_z = try allocator.dupeZ(u8, dylib_path);
    const handle = std.c.dlopen(dylib_z.ptr, .{ .NOW = true });
    if (handle == null) {
        const err = std.c.dlerror();
        if (err) |e| {
            std.debug.print("dlopen failed: {s}\n", .{std.mem.span(e)});
        }
        return error.CompileError;
    }

    return .{
        .dylib_handle = handle,
        .dylib_path = dylib_path,
        .temp_paths = try temp_paths.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Compile C sources using emcc for Emscripten/WASM targets.
/// Shells out to `emcc -c` for each source file, returns temp object file paths.
// First line of `emcc --version` (the toolchain component of emcc
// cache keys); "" when it cannot be determined — keys then share one
// unversioned bucket, which only risks staleness across emsdk
// upgrades, never wrong content for a fixed toolchain.
fn emccVersionLine(allocator: std.mem.Allocator, io: std.Io) []const u8 {
    const tmp = std.fmt.allocPrint(allocator, "/tmp/sx_emcc_ver_{d}", .{std.c.getpid()}) catch return "";
    const cmd = std.fmt.allocPrint(allocator, "emcc --version 2>/dev/null | head -1 > {s}", .{tmp}) catch return "";
    var child = std.process.spawn(io, .{ .argv = &.{ "sh", "-c", cmd } }) catch return "";
    const result = child.wait(io) catch return "";
    if (result != .exited or result.exited != 0) return "";
    const line = std.Io.Dir.readFileAlloc(.cwd(), io, tmp, allocator, .limited(4096)) catch return "";
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};
    return std.mem.trim(u8, line, " \t\r\n");
}

pub fn compileCWithEmcc(
    allocator: std.mem.Allocator,
    io: std.Io,
    infos: []const CImportInfo,
    target_config: @import("target.zig").TargetConfig,
    tmp_dir: []const u8,
) ![]const []const u8 {
    var paths = std.ArrayList([]const u8).empty;
    var obj_idx: usize = 0;

    const triple: []const u8 = if (target_config.isWasm64()) "wasm64-emscripten" else "wasm32-emscripten";
    const opt_flag = target_config.opt_level.toClangFlag();
    var emcc_version: ?[]const u8 = null; // resolved lazily, once, only if a unit exists

    for (infos) |info| {
        if (info.sources.len == 0) continue;

        var inc_dirs = std.ArrayList([]const u8).empty;
        for (info.includes) |inc| {
            try inc_dirs.append(allocator, dirName(inc));
        }

        // Same cache participation as the native path: declared headers
        // by content; an unreadable one disables caching, never the build.
        var header_bytes = std.ArrayList([]const u8).empty;
        var cache_ok = true;
        for (info.includes) |inc| {
            const hb = std.Io.Dir.readFileAlloc(.cwd(), io, inc, allocator, .limited(64 * 1024 * 1024)) catch {
                cache_ok = false;
                break;
            };
            try header_bytes.append(allocator, hb);
        }

        for (info.sources) |src| {
            var cache_flags = std.ArrayList([]const u8).empty;
            try cache_flags.append(allocator, opt_flag);
            try cache_flags.appendSlice(allocator, info.flags);
            var cache_path: ?[:0]const u8 = null;
            if (cache_ok) {
                if (std.Io.Dir.readFileAlloc(.cwd(), io, src, allocator, .limited(64 * 1024 * 1024))) |src_bytes| {
                    if (emcc_version == null) emcc_version = emccVersionLine(allocator, io);
                    const dep_bytes = collectIncludeDepBytes(allocator, io, src, src_bytes, inc_dirs.items) catch &.{};
                    const key = cSourceCacheKey(
                        src_bytes,
                        header_bytes.items,
                        dep_bytes,
                        info.defines,
                        cache_flags.items,
                        inc_dirs.items,
                        emcc_version.?,
                        triple,
                        null,
                    );
                    cache_path = try std.fmt.allocPrintSentinel(allocator, ".sx-cache/c-{x:0>16}.o", .{key}, 0);
                    if (loadCachedObject(cache_path.?)) |cached| {
                        // The linker only reads it — hand the cache path over
                        // directly, no copy into tmp_dir.
                        c.LLVMDisposeMemoryBuffer(cached);
                        try paths.append(allocator, cache_path.?);
                        continue;
                    }
                } else |_| {}
            }

            const out_path = try std.fmt.allocPrint(allocator, "{s}/sx_emcc_{d}.o", .{ tmp_dir, obj_idx });
            obj_idx += 1;

            var argv = std.ArrayList([]const u8).empty;
            try argv.appendSlice(allocator, &.{ "emcc", "-c", opt_flag, src, "-o", out_path });
            // wasm64: compile C sources with memory64 support
            if (target_config.isWasm64()) {
                try argv.append(allocator, "-sMEMORY64");
            }
            for (inc_dirs.items) |dir| {
                try argv.append(allocator, try std.fmt.allocPrint(allocator, "-I{s}", .{dir}));
            }
            for (info.defines) |def| {
                try argv.append(allocator, try std.fmt.allocPrint(allocator, "-D{s}", .{def}));
            }
            for (info.flags) |flag| {
                try argv.append(allocator, flag);
            }

            const argv_slice = try argv.toOwnedSlice(allocator);
            var child = std.process.spawn(io, .{ .argv = argv_slice }) catch {
                std.debug.print("error: failed to spawn emcc for '{s}'\n", .{src});
                return error.CompileError;
            };
            const result = child.wait(io) catch return error.CompileError;
            if (result != .exited or result.exited != 0) {
                std.debug.print("error: emcc failed for '{s}'\n", .{src});
                return error.CompileError;
            }

            if (cache_path) |cp| {
                std.Io.Dir.copyFile(.cwd(), out_path, .cwd(), cp, io, .{ .make_path = true }) catch {};
            }
            try paths.append(allocator, out_path);
        }
    }

    return try paths.toOwnedSlice(allocator);
}

/// For build mode: write .o buffers to temp files, return paths for the linker.
pub fn writeCObjectFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    obj_bufs: []c.LLVMMemoryBufferRef,
    tmp_dir: []const u8,
) ![]const []const u8 {
    var paths = std.ArrayList([]const u8).empty;

    for (obj_bufs, 0..) |buf, i| {
        const path = try std.fmt.allocPrint(allocator, "{s}/sx_c_{d}.o", .{ tmp_dir, i });
        const start = c.LLVMGetBufferStart(buf);
        const size = c.LLVMGetBufferSize(buf);
        const data = @as([*]const u8, @ptrCast(start))[0..size];
        std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = data }) catch {
            std.debug.print("failed to write temp object: {s}\n", .{path});
            return error.CompileError;
        };
        try paths.append(allocator, path);
        c.LLVMDisposeMemoryBuffer(buf);
    }

    return try paths.toOwnedSlice(allocator);
}

/// Walk the resolved AST and collect CImportInfo from all c_import_decl nodes.
/// Deduplicates by source pointer identity (shared nodes from import propagation).
pub fn collectCImportSources(allocator: std.mem.Allocator, root: *const Node) ![]CImportInfo {
    if (root.data != .root) return &.{};

    var infos = std.ArrayList(CImportInfo).empty;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Aliased imports lower to namespace_decl nodes and NEST when a
    // namespaced module declares its own named unit — recurse, or a
    // unit two aliases deep is silently never compiled and its symbols
    // resolve from whatever process image carries the same names (the
    // extractLibraries depth bug, issue 0130, in c_import form).
    //
    // Dedup is by CONTENT (sources + includes + defines + flags), not
    // node identity: one module imported through several aliased paths
    // materializes several copies of its c_import_decl, and collecting
    // each copy would compile (and link!) the same unit repeatedly —
    // duplicate-symbol death at AOT link time.
    const walker = struct {
        // Lexically normalized: the SAME file reached through different
        // import chains spells differently ("src/app/../repo/../db/../..
        // /vendor/x.c" vs "src/db/../../vendor/x.c") and must dedup.
        fn appendNormalized(key: *std.ArrayList(u8), alloc: std.mem.Allocator, path: []const u8) !void {
            const norm = std.fs.path.resolve(alloc, &.{path}) catch path;
            try key.appendSlice(alloc, norm);
            try key.append(alloc, 0);
        }

        fn contentKey(alloc: std.mem.Allocator, ci: anytype) ![]const u8 {
            var key = std.ArrayList(u8).empty;
            for (ci.sources) |s| {
                try appendNormalized(&key, alloc, s);
            }
            try key.append(alloc, 1);
            for (ci.includes) |s| {
                try appendNormalized(&key, alloc, s);
            }
            try key.append(alloc, 1);
            for (ci.defines) |s| {
                try key.appendSlice(alloc, s);
                try key.append(alloc, 0);
            }
            try key.append(alloc, 1);
            for (ci.flags) |s| {
                try key.appendSlice(alloc, s);
                try key.append(alloc, 0);
            }
            return try key.toOwnedSlice(alloc);
        }

        fn walk(
            infos_: *std.ArrayList(CImportInfo),
            seen_: *std.StringHashMap(void),
            alloc: std.mem.Allocator,
            decls: []const *Node,
        ) !void {
            for (decls) |d| {
                switch (d.data) {
                    .c_import_decl => |ci| {
                        if (ci.sources.len > 0) {
                            const key = try contentKey(alloc, ci);
                            if (!seen_.contains(key)) {
                                try seen_.put(key, {});
                                try infos_.append(alloc, .{
                                    .sources = ci.sources,
                                    .includes = ci.includes,
                                    .defines = ci.defines,
                                    .flags = ci.flags,
                                });
                            }
                        }
                    },
                    .namespace_decl => |ns| try walk(infos_, seen_, alloc, ns.decls),
                    else => {},
                }
            }
        }
    };
    try walker.walk(&infos, &seen, allocator, root.data.root.decls);

    return try infos.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// C type → sx type mapping
// ---------------------------------------------------------------------------

fn mapCTypeToSxNode(
    allocator: std.mem.Allocator,
    c_type: []const u8,
) !*Node {
    const trimmed = std.mem.trim(u8, c_type, " ");

    // Pointer types (trailing *)
    if (std.mem.endsWith(u8, trimmed, "*")) {
        const base = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " ");

        // const char * → [*]u8 (raw pointer, matches C ABI)
        if (std.mem.eql(u8, base, "const char") or std.mem.eql(u8, base, "char const")) {
            return makeManyPointerTypeNode(allocator, "u8");
        }
        // char * → [*]u8
        if (std.mem.eql(u8, base, "char")) {
            return makeManyPointerTypeNode(allocator, "u8");
        }
        // unsigned char * / const unsigned char * → [*]u8
        if (std.mem.eql(u8, base, "unsigned char") or
            std.mem.eql(u8, base, "const unsigned char") or
            std.mem.eql(u8, base, "unsigned char const"))
        {
            return makeManyPointerTypeNode(allocator, "u8");
        }
        // void * / const void * → *void
        if (std.mem.eql(u8, base, "void") or std.mem.eql(u8, base, "const void")) {
            return makePointerTypeNode(allocator, "void");
        }
        // int * → *i32
        if (std.mem.eql(u8, base, "int") or std.mem.eql(u8, base, "const int")) {
            return makePointerTypeNode(allocator, "i32");
        }
        // unsigned int * / unsigned * → *u32
        if (std.mem.eql(u8, base, "unsigned int") or std.mem.eql(u8, base, "unsigned") or std.mem.eql(u8, base, "const unsigned int")) {
            return makePointerTypeNode(allocator, "u32");
        }
        // float * → *f32
        if (std.mem.eql(u8, base, "float") or std.mem.eql(u8, base, "const float")) {
            return makePointerTypeNode(allocator, "f32");
        }
        // double * → *f64
        if (std.mem.eql(u8, base, "double") or std.mem.eql(u8, base, "const double")) {
            return makePointerTypeNode(allocator, "f64");
        }
        // short * → *i16
        if (std.mem.eql(u8, base, "short") or std.mem.eql(u8, base, "const short")) {
            return makePointerTypeNode(allocator, "i16");
        }
        // Pointer to pointer → *void
        if (std.mem.endsWith(u8, base, "*")) {
            return makePointerTypeNode(allocator, "void");
        }
        // Remove const qualifier and retry
        if (std.mem.startsWith(u8, base, "const ")) {
            const without_const = try std.fmt.allocPrint(allocator, "{s} *", .{base[6..]});
            return mapCTypeToSxNode(allocator, without_const);
        }
        // Default: struct/opaque pointer → *void
        return makePointerTypeNode(allocator, "void");
    }

    // Direct types
    if (std.mem.eql(u8, trimmed, "int") or std.mem.eql(u8, trimmed, "signed int")) return makeTypeExprNode(allocator, "i32");
    if (std.mem.eql(u8, trimmed, "unsigned int") or std.mem.eql(u8, trimmed, "unsigned")) return makeTypeExprNode(allocator, "u32");
    if (std.mem.eql(u8, trimmed, "long") or std.mem.eql(u8, trimmed, "long int") or std.mem.eql(u8, trimmed, "signed long")) return makeTypeExprNode(allocator, "i64");
    if (std.mem.eql(u8, trimmed, "unsigned long") or std.mem.eql(u8, trimmed, "unsigned long int")) return makeTypeExprNode(allocator, "u64");
    if (std.mem.eql(u8, trimmed, "long long") or std.mem.eql(u8, trimmed, "long long int")) return makeTypeExprNode(allocator, "i64");
    if (std.mem.eql(u8, trimmed, "unsigned long long") or std.mem.eql(u8, trimmed, "unsigned long long int")) return makeTypeExprNode(allocator, "u64");
    if (std.mem.eql(u8, trimmed, "short") or std.mem.eql(u8, trimmed, "short int") or std.mem.eql(u8, trimmed, "signed short")) return makeTypeExprNode(allocator, "i16");
    if (std.mem.eql(u8, trimmed, "unsigned short") or std.mem.eql(u8, trimmed, "unsigned short int")) return makeTypeExprNode(allocator, "u16");
    if (std.mem.eql(u8, trimmed, "char") or std.mem.eql(u8, trimmed, "signed char")) return makeTypeExprNode(allocator, "u8");
    if (std.mem.eql(u8, trimmed, "unsigned char")) return makeTypeExprNode(allocator, "u8");
    if (std.mem.eql(u8, trimmed, "float")) return makeTypeExprNode(allocator, "f32");
    if (std.mem.eql(u8, trimmed, "double")) return makeTypeExprNode(allocator, "f64");
    if (std.mem.eql(u8, trimmed, "size_t")) return makeTypeExprNode(allocator, "u64");
    if (std.mem.eql(u8, trimmed, "_Bool") or std.mem.eql(u8, trimmed, "bool")) return makeTypeExprNode(allocator, "u8");

    // Default: unknown type → i64 (treat as opaque integer-sized value)
    return makeTypeExprNode(allocator, "i64");
}

// ---------------------------------------------------------------------------
// AST node construction helpers
// ---------------------------------------------------------------------------

fn makeTypeExprNode(allocator: std.mem.Allocator, name: []const u8) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .type_expr = .{ .name = name } },
    };
    return node;
}

fn makePointerTypeNode(allocator: std.mem.Allocator, pointee: []const u8) !*Node {
    const inner = try makeTypeExprNode(allocator, pointee);
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .pointer_type_expr = .{ .pointee_type = inner } },
    };
    return node;
}

fn makeManyPointerTypeNode(allocator: std.mem.Allocator, element: []const u8) !*Node {
    const inner = try makeTypeExprNode(allocator, element);
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .many_pointer_type_expr = .{ .element_type = inner } },
    };
    return node;
}

fn makeSliceTypeNode(allocator: std.mem.Allocator, element: []const u8) !*Node {
    const inner = try makeTypeExprNode(allocator, element);
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .slice_type_expr = .{ .element_type = inner } },
    };
    return node;
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    return allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, fmt, args));
}

fn dirName(path: []const u8) []const u8 {
    var last_sep: usize = 0;
    var found = false;
    for (path, 0..) |ch, i| {
        if (ch == '/') {
            last_sep = i;
            found = true;
        }
    }
    return if (found) path[0..last_sep] else ".";
}
