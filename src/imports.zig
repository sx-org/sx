const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const c_import = @import("c_import.zig");
const Node = ast.Node;

/// Comptime evaluation context for the inline-if hoisting pass below.
/// Mirrors the values `injectComptimeConstants` will later push into the
/// lowering's `comptime_constants` map (OS / ARCH / POINTER_SIZE), but
/// derived directly from the build target so we can resolve top-level
/// `inline if OS == .X { ... }` arms before imports + lowering run.
pub const ComptimeContext = struct {
    /// Lowercase OS name matching the OperatingSystem enum tag
    /// (macos / linux / windows / wasm / ios / android / unknown).
    os: []const u8 = "unknown",
    /// Lowercase architecture name matching the Architecture enum tag
    /// (aarch64 / x86_64 / wasm32 / wasm64 / unknown).
    arch: []const u8 = "unknown",
    /// 4 for wasm32, 8 for every other target.
    pointer_size: i64 = 8,
};

/// Top-level `inline if OS == .X { decls }` blocks are parsed as
/// `if_expr` / `match_expr` nodes in `root.decls`, but the lowering
/// pass only knows how to dispatch on `.fn_decl` / `.const_decl` /
/// `.var_decl` / etc. at decl positions — an `if_expr` at the top
/// level is silently dropped. Same story for `#import` decls inside an
/// `inline if` body: they need to be surfaced to the top so import
/// resolution sees them.
///
/// This pass walks `decls`, replaces every comptime conditional with
/// the body of its taken arm (recursively flattened), and drops the
/// rest. A condition we can't resolve at this stage is also dropped —
/// the caller may want to surface that as a diagnostic later, but for
/// the OS / ARCH / POINTER_SIZE patterns we cover here it shouldn't
/// happen in practice.
pub fn flattenComptimeConditionals(allocator: std.mem.Allocator, decls: []const *Node, ctx: ComptimeContext, diagnostics: ?*errors.DiagnosticList) std.mem.Allocator.Error![]const *Node {
    var out = std.ArrayList(*Node).empty;
    for (decls) |decl| {
        switch (decl.data) {
            .if_expr => |ie| {
                if (ie.is_comptime) {
                    if (evalComptimeCondition(ie.condition, ctx)) |is_true| {
                        const taken: ?*const Node = if (is_true) ie.then_branch else ie.else_branch;
                        if (taken) |b| try appendBranchDecls(allocator, &out, b, ctx, diagnostics);
                        continue;
                    }
                    // Never silently discard declarations from an unevaluable
                    // module-scope conditional (issue 0241).  This early pass
                    // intentionally supports only target-condition forms; tell
                    // the author exactly what is accepted instead of making a
                    // live function/import/asm vanish and reporting a distant
                    // unresolved-name error later.
                    if (diagnostics) |diags| diags.addFmt(.err, ie.condition.span, "cannot evaluate this module-scope `inline if` condition; use an OS/ARCH/POINTER_SIZE comparison", .{});
                    continue;
                }
                try out.append(allocator, decl);
            },
            .match_expr => |me| {
                if (me.is_comptime) {
                    if (evalComptimeMatch(&me, ctx)) |body| {
                        try appendBranchDecls(allocator, &out, body, ctx, diagnostics);
                    }
                    continue;
                }
                try out.append(allocator, decl);
            },
            .error_directive => |ed| {
                // A `#error` that survived flattening into live decls (a bare
                // top-level one, or the taken arm of an `inline if`) fires here.
                // Non-taken arms were already dropped above, so this only emits
                // when the directive is genuinely reached.
                if (diagnostics) |diags| diags.addFmt(.err, decl.span, "{s}", .{ed.message});
            },
            else => try out.append(allocator, decl),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn appendBranchDecls(allocator: std.mem.Allocator, out: *std.ArrayList(*Node), branch: *const Node, ctx: ComptimeContext, diagnostics: ?*errors.DiagnosticList) std.mem.Allocator.Error!void {
    const stmts: []const *Node = if (branch.data == .block)
        branch.data.block.stmts
    else
        &[_]*Node{@constCast(branch)};
    const recursed = try flattenComptimeConditionals(allocator, stmts, ctx, diagnostics);
    for (recursed) |node| {
        // A module-level `asm { "tmpl", };` inside an `inline if` branch was
        // parsed by the STATEMENT parser (the branch body is a block), so it
        // arrives here as an in-function `.asm_expr` — not the `.asm_global`
        // the top-level parser produces for an unwrapped block. Once the
        // branch is taken and its decls surface to module scope, the node IS
        // module-scope global asm: retag it so lowering's `.asm_global` arm
        // appends the template to `module.global_asm` (issue 0194 — the
        // statement-form node used to fall into lowering's `else => {}` and
        // the symbol silently vanished from the object). The same top-level
        // restrictions as `parseAsmGlobal` apply: template only — a
        // `volatile` marker or any operand/clobber is diagnosed, not dropped.
        if (node.data == .asm_expr) {
            const ae = &node.data.asm_expr;
            if (ae.is_volatile) {
                if (diagnostics) |diags| diags.addFmt(.err, node.span, "global (top-level) asm cannot be `volatile`", .{});
                continue;
            }
            if (ae.operands.len > 0 or ae.clobbers.len > 0) {
                if (diagnostics) |diags| diags.addFmt(.err, node.span, "global (top-level) asm takes no operands, inputs, or clobbers — only a template string", .{});
                continue;
            }
            node.data = .{ .asm_global = .{ .template = ae.template } };
        }
        try out.append(allocator, node);
    }
}

fn evalComptimeCondition(node: *const Node, ctx: ComptimeContext) ?bool {
    if (node.data != .binary_op) return null;
    const bo = &node.data.binary_op;
    if (bo.op == .and_op) {
        const lhs = evalComptimeCondition(bo.lhs, ctx) orelse return null;
        if (!lhs) return false;
        return evalComptimeCondition(bo.rhs, ctx);
    }
    if (bo.op == .or_op) {
        const lhs = evalComptimeCondition(bo.lhs, ctx) orelse return null;
        if (lhs) return true;
        return evalComptimeCondition(bo.rhs, ctx);
    }
    if (bo.op != .eq and bo.op != .neq) return null;
    const name = switch (bo.lhs.data) {
        .identifier => |id| id.name,
        else => return null,
    };
    if (std.mem.eql(u8, name, "OS") or std.mem.eql(u8, name, "ARCH")) {
        const variant = switch (bo.rhs.data) {
            .enum_literal => |el| el.name,
            else => return null,
        };
        const target = if (std.mem.eql(u8, name, "OS")) ctx.os else ctx.arch;
        const matches = std.mem.eql(u8, variant, target);
        return if (bo.op == .eq) matches else !matches;
    }
    if (std.mem.eql(u8, name, "POINTER_SIZE")) {
        const rhs_val: i64 = switch (bo.rhs.data) {
            .int_literal => |il| il.value,
            else => return null,
        };
        const matches = ctx.pointer_size == rhs_val;
        return if (bo.op == .eq) matches else !matches;
    }
    return null;
}

fn evalComptimeMatch(me: *const ast.MatchExpr, ctx: ComptimeContext) ?*const Node {
    const name = switch (me.subject.data) {
        .identifier => |id| id.name,
        else => return null,
    };
    if (std.mem.eql(u8, name, "OS") or std.mem.eql(u8, name, "ARCH")) {
        const target = if (std.mem.eql(u8, name, "OS")) ctx.os else ctx.arch;
        for (me.arms) |arm| {
            const pattern = arm.pattern orelse continue;
            const variant = switch (pattern.data) {
                .enum_literal => |el| el.name,
                else => continue,
            };
            if (std.mem.eql(u8, variant, target)) return arm.body;
        }
        for (me.arms) |arm| if (arm.pattern == null) return arm.body;
        return null;
    }
    if (std.mem.eql(u8, name, "POINTER_SIZE")) {
        for (me.arms) |arm| {
            const pattern = arm.pattern orelse continue;
            const rhs_val: i64 = switch (pattern.data) {
                .int_literal => |il| il.value,
                else => continue,
            };
            if (ctx.pointer_size == rhs_val) return arm.body;
        }
        for (me.arms) |arm| if (arm.pattern == null) return arm.body;
        return null;
    }
    return null;
}

pub fn dirName(path: []const u8) []const u8 {
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

/// Lexically normalize a path: drop `.` segments, collapse `seg/..` pairs,
/// squeeze duplicate separators. Purely lexical — no fs access, no symlink
/// resolution (so `a/../b` where `a` is a symlink collapses lexically; the
/// accepted trade-off for deterministic, machine-independent keys).
/// An empty relative result becomes `"."`; an emptied absolute one `"/"`.
fn lexicalNormalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const is_abs = path.len > 0 and path[0] == '/';
    var stack = std.ArrayList([]const u8).empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (stack.items.len > 0 and !std.mem.eql(u8, stack.items[stack.items.len - 1], "..")) {
                _ = stack.pop();
            } else if (!is_abs) {
                // A relative path may legitimately start with `..` segments.
                try stack.append(allocator, seg);
            }
            // Absolute: `/..` is `/` — drop.
            continue;
        }
        try stack.append(allocator, seg);
    }
    if (stack.items.len == 0) return try allocator.dupe(u8, if (is_abs) "/" else ".");
    var out = std.ArrayList(u8).empty;
    if (is_abs) try out.append(allocator, '/');
    for (stack.items, 0..) |seg, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    return try out.toOwnedSlice(allocator);
}

/// `path` re-expressed relative to directory `base` (both already
/// lexically-normalized, absolute), or null when `path` is not under `base`.
fn relativeTo(path: []const u8, base: []const u8) ?[]const u8 {
    if (base.len == 0) return null;
    if (std.mem.eql(u8, path, base)) return ".";
    if (std.mem.eql(u8, base, "/")) {
        if (path.len > 1 and path[0] == '/') return path[1..];
        return null;
    }
    if (path.len > base.len + 1 and std.mem.startsWith(u8, path, base) and path[base.len] == '/') {
        return path[base.len + 1 ..];
    }
    return null;
}

/// Canonicalize a resolved import path so the SAME source file gets ONE
/// spelling everywhere it is keyed — module cache, `flat_import_graph`,
/// `module_decls`, decl table, namespace edges (issue 0148). Lexically
/// normalizes (strip `./`, collapse `a/../b`) and re-relativizes an
/// absolute path against the process CWD when the file lives under it, so
/// an absolute entry path produces the same cwd-relative keys (and the same
/// cwd-relative diagnostic spellings) as a relative one. Lexical only — no
/// realpath/symlink churn; the physical `getcwd` AND the logical `$PWD`
/// (differs when the shell cd'd through a symlink) are both tried as bases.
pub fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const norm = try lexicalNormalize(allocator, path);
    if (norm.len == 0 or norm[0] != '/') return norm;
    var buf: [4096]u8 = undefined;
    if (getcwd(&buf, buf.len)) |cwd_z| {
        if (relativeTo(norm, std.mem.span(cwd_z))) |rel| return try allocator.dupe(u8, rel);
    }
    if (c_getenv("PWD")) |pwd_z| {
        const pwd = try lexicalNormalize(allocator, std.mem.span(pwd_z));
        if (pwd.len > 0 and pwd[0] == '/') {
            if (relativeTo(norm, pwd)) |rel| return try allocator.dupe(u8, rel);
        }
    }
    return norm;
}

/// Resolve an import path. Tries (in order):
///   1. relative to `base_dir` (the importing file's directory)
///   2. relative to CWD, absolutified via `root_path` if supplied
///   3. relative to each path in `stdlib_paths` (the install-discovered stdlib)
/// Returns the first path that exists, CANONICALIZED via `canonicalizePath` —
/// the single chokepoint that guarantees one key spelling per file no matter
/// which chain (absolute entry, cwd fallback, stdlib search) reached it.
/// Falls back to the (canonicalized) raw path if nothing matches so the
/// caller's readFile produces a coherent "not found" error.
pub fn resolveImportPath(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, raw_path: []const u8, root_path: ?[]const u8, stdlib_paths: []const []const u8) ![]const u8 {
    const resolved = try resolveImportPathUncanon(allocator, io, base_dir, raw_path, root_path, stdlib_paths);
    const canon = try canonicalizePath(allocator, resolved);
    if (std.mem.eql(u8, canon, resolved)) return canon;
    // The respelling must still name the SAME file on disk. `resolved` was
    // probed for existence, but a lexical `..` collapse through a SYMLINKED
    // component changes which file the string denotes (`link/../other.sx`
    // resolves through the symlink's target dir in the kernel, but collapses
    // to the sibling `other.sx` lexically) — and a re-relativization against
    // a stale `$PWD` can respell it to a different or nonexistent path.
    // Existence alone can't catch the symlink case (both files exist), so
    // compare stat identity (st_dev + st_ino, symlink-following) and keep
    // the probed spelling whenever the two don't provably match.
    if (sameFileIdentity(allocator, canon, resolved)) return canon;
    return resolved;
}

/// libc `stat`, bound directly (this Zig version doesn't export `std.c.stat`
/// on every host arch). Same platform-symbol selection `std.c` itself uses:
/// x86_64 Darwin needs the `$INODE64` variant to match `std.c.Stat`'s layout.
const c_stat = @extern(*const fn ([*:0]const u8, *std.c.Stat) callconv(.c) c_int, .{
    .name = switch (builtin.os.tag) {
        .driverkit, .ios, .macos, .tvos, .visionos, .watchos => switch (builtin.cpu.arch) {
            .x86_64 => "stat$INODE64",
            else => "stat",
        },
        else => "stat",
    },
    .library_name = "c",
});

/// Canonicalize an ENTRY path (CLI ingestion) with the same identity guard
/// `resolveImportPath` applies to import keys: accept the respelling only
/// when it provably names the same file on disk (issue 0148 fold — an
/// absolute entry under the CWD then displays/keys cwd-relative, matching a
/// relative invocation); otherwise keep the user's spelling (nonexistent
/// entry, symlinked `..` component, stale `$PWD`).
pub fn canonicalizeEntryPath(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    const canon = canonicalizePath(allocator, path) catch return path;
    if (std.mem.eql(u8, canon, path)) return canon;
    if (sameFileIdentity(allocator, canon, path)) return canon;
    return path;
}

/// Do two path spellings name the SAME file on disk? Symlink-following libc
/// stat identity (st_dev + st_ino). Any stat failure → false — the caller
/// keeps the spelling that was actually probed.
fn sameFileIdentity(allocator: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    const az = allocator.dupeZ(u8, a) catch return false;
    const bz = allocator.dupeZ(u8, b) catch return false;
    var sa: std.c.Stat = undefined;
    var sb: std.c.Stat = undefined;
    if (c_stat(az.ptr, &sa) != 0) return false;
    if (c_stat(bz.ptr, &sb) != 0) return false;
    return sa.dev == sb.dev and sa.ino == sb.ino;
}

fn resolveImportPathUncanon(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, raw_path: []const u8, root_path: ?[]const u8, stdlib_paths: []const []const u8) ![]const u8 {
    if (!std.mem.eql(u8, base_dir, ".")) {
        const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, raw_path });
        // Check if it exists as file relative to base_dir
        if (std.Io.Dir.readFileAlloc(.cwd(), io, rel_path, allocator, .limited(10 * 1024 * 1024))) |_| {
            return rel_path;
        } else |_| {}
        // Check if it exists as directory relative to base_dir
        if (std.Io.Dir.openDir(.cwd(), io, rel_path, .{})) |dir| {
            dir.close(io);
            return rel_path;
        } else |_| {}
    }
    // Try CWD-relative (absolutified if root_path is known).
    const cwd_candidate = if (root_path) |rp| blk: {
        if (rp.len > 0 and raw_path.len > 0 and raw_path[0] != '/') {
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rp, raw_path });
        }
        break :blk raw_path;
    } else raw_path;
    if (std.Io.Dir.readFileAlloc(.cwd(), io, cwd_candidate, allocator, .limited(10 * 1024 * 1024))) |_| {
        return cwd_candidate;
    } else |_| {}
    if (std.Io.Dir.openDir(.cwd(), io, cwd_candidate, .{})) |dir| {
        dir.close(io);
        return cwd_candidate;
    } else |_| {}
    // Try each stdlib search path.
    for (stdlib_paths) |sp| {
        const cand = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sp, raw_path });
        if (std.Io.Dir.readFileAlloc(.cwd(), io, cand, allocator, .limited(10 * 1024 * 1024))) |_| {
            return cand;
        } else |_| {}
        if (std.Io.Dir.openDir(.cwd(), io, cand, .{})) |dir| {
            dir.close(io);
            return cand;
        } else |_| {}
    }
    return cwd_candidate;
}

/// Discover candidate stdlib search paths from the running binary's location.
/// Honors the `SX_STDLIB_PATH` env var as an explicit override. Returns a slice
/// of absolute paths owned by the allocator.
pub fn discoverStdlibPaths(allocator: std.mem.Allocator) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;

    // Env override via libc getenv (cross-stdlib-version stable).
    if (c_getenv("SX_STDLIB_PATH")) |env_path| {
        try out.append(allocator, try allocator.dupe(u8, std.mem.span(env_path)));
    }

    const exe_path = selfExePath(allocator) catch return try out.toOwnedSlice(allocator);
    const exe_dir = dirName(exe_path);
    // Stdlib paths are directories containing a `modules/` subdir; the import
    // directive (e.g. `#import "modules/std.sx"`) supplies the rest.
    // Dev: zig-out/bin/sx -> repo-root/library
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/../../library", .{exe_dir}));
    // Install: <prefix>/bin/sx -> <prefix>/library
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/../library", .{exe_dir}));
    // Alongside the binary.
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/library", .{exe_dir}));
    if (c_getenv("SX_DEBUG_STDLIB") != null) {
        std.debug.print("[sx] exe_path={s}\n", .{exe_path});
        for (out.items, 0..) |p, i| std.debug.print("[sx] stdlib_paths[{d}]={s}\n", .{ i, p });
    }
    return try out.toOwnedSlice(allocator);
}

const builtin = @import("builtin");

extern "c" fn _NSGetExecutablePath(buf: [*]u8, len: *u32) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;

fn c_getenv(name: [:0]const u8) ?[*:0]const u8 {
    return getenv(name.ptr);
}

/// The process working directory (libc getcwd), or null if unavailable.
/// Import keys are deliberately CWD-relative (`canonicalizePath`); a consumer
/// that needs an absolute spelling (e.g. an LSP `file://` URI) joins against
/// this.
pub fn processCwd(allocator: std.mem.Allocator) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const cwd_z = getcwd(&buf, buf.len) orelse return null;
    return allocator.dupe(u8, std.mem.span(cwd_z)) catch null;
}

fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    switch (builtin.os.tag) {
        .macos, .ios => {
            var len: u32 = buf.len;
            if (_NSGetExecutablePath(&buf, &len) != 0) return error.PathBufferTooSmall;
            const span = std.mem.sliceTo(&buf, 0);
            return try allocator.dupe(u8, span);
        },
        .linux => {
            // Zig 0.16 moved the filesystem API to the io-based `std.Io.Dir`
            // (there is no io-free `std.posix.readlink` anymore); use the raw
            // linux syscall wrapper, which needs no `io` handle.
            const rc = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return try allocator.dupe(u8, buf[0..rc]),
                else => return error.ReadSelfExeFailed,
            }
        },
        else => return error.UnsupportedHostOS,
    }
}

/// A resolved module: the fully-resolved declarations of a single .sx file,
/// with its own scope tracking which names are defined.
///
/// Imports are non-transitive. `scope` is intentionally *narrow*: it
/// contains only the names of decls authored in THIS file (plus namespaced
/// import aliases the file introduces). Visibility for names from
/// flat-imported modules is computed at lookup time by joining the
/// importer's `scope` with each direct flat-import's `scope` via
/// `import_graph` — this lets cyclic imports (e.g. std.sx ↔ allocators.sx)
/// resolve correctly even though one side of the cycle is skipped during
/// `resolveImports` recursion.
///
/// `decls` remains the full transitive flat list so the global lowering
/// pass can resolve a body in B that calls into C even though A never
/// imported C directly.
pub const ResolvedModule = struct {
    path: []const u8,
    /// Full flat decl list: own decls + every transitively-imported module's
    /// own decls (deduped by name). Walked by `lowerRoot`/`scanDecls` so
    /// transitive callees stay resolvable when their callers are lowered.
    decls: []const *Node,
    /// Decls authored in this file. What flat importers of THIS module see
    /// (their visibility BFS joins these names in via `import_graph`).
    own_decls: []const *Node,
    /// Names authored in this file (plus namespace aliases this file
    /// introduces). Used as the per-file leaf in the visibility lookup;
    /// importers do NOT splice this into their own scope — they walk the
    /// import graph at query time instead.
    scope: std.StringHashMap(void),

    /// Add a declaration authored in this file. Updates scope + own_decls +
    /// the global flat decl list; dedups by name through `seen_list` (which
    /// already holds names previously appended via `mergeFlat`, so an
    /// authored decl that collides with a transitively-imported one stays
    /// out of the global list while still entering `own_decls` for
    /// importer-visibility purposes).
    pub fn addOwnDecl(
        self: *ResolvedModule,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(*Node),
        own_list: *std.ArrayList(*Node),
        seen_list: *std.StringHashMap(void),
        decl: *Node,
    ) !bool {
        var append_to_global = true;
        if (decl.data.declName()) |name| {
            if (self.scope.contains(name)) return false;
            try self.scope.put(name, {});
            if (seen_list.contains(name)) {
                // A cross-module name collision: drop from the global list
                // (first-wins) UNLESS this is a per-source decl (a type, alias,
                // or non-function const), which must reach registration as a
                // distinct author of its own module.
                append_to_global = isPerSourceDecl(decl);
            } else {
                try seen_list.put(name, {});
            }
        }
        if (append_to_global) try list.append(allocator, decl);
        try own_list.append(allocator, decl);
        return true;
    }

    /// Flat-import another module. The imported names are NOT added to
    /// `self.scope` — visibility joins per-file scopes at lookup time via
    /// `import_graph`. We only need to append `other.decls` (the full
    /// transitive list) to the global `list` so the lowering pass can
    /// still resolve transitively-imported callees.
    ///
    /// Deduped two ways: named decls by name (first-wins on cross-module
    /// collisions), and EVERY decl by node identity. The latter matters for
    /// anonymous decls — `impl` blocks have no `declName`, so under a diamond
    /// import the same cached node would otherwise be appended once per path
    /// and registered twice (e.g. `duplicate impl 'Into'`).
    pub fn mergeFlat(
        self: *ResolvedModule,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(*Node),
        seen_list: *std.StringHashMap(void),
        seen_nodes: *std.AutoHashMap(*Node, void),
        other: ResolvedModule,
    ) !void {
        _ = self;
        for (other.decls) |decl| {
            if (seen_nodes.contains(decl)) continue;
            if (decl.data.declName()) |name| {
                if (seen_list.contains(name)) {
                    // First-wins on a cross-module name collision — EXCEPT a
                    // per-source decl (a named type, or any non-function const:
                    // type alias + value const), each of which must reach
                    // registration as a distinct same-name author of its own
                    // module (types and aliases; step E5 value consts). Only
                    // FUNCTIONS keep first-wins (the shadowed author
                    // stays reachable via its qualified name / SelectedFunc).
                    // Node identity (above) still de-dups a diamond import of the
                    // SAME decl.
                    if (!isPerSourceDecl(decl)) continue;
                } else {
                    try seen_list.put(name, {});
                }
            }
            try seen_nodes.put(decl, {});
            try list.append(allocator, decl);
        }
    }

    /// A decl that must register PER-SOURCE: each same-name author across modules
    /// registers against its OWN module rather than collapsing to a single
    /// first-wins winner. NAMED types and every non-function `const_decl` (type
    /// aliases + inline type decls + VALUE consts, source-keyed via the alias /
    /// const caches) are per-source — that is what prevents same-name collapse for
    /// types/aliases and supports same-name value consts (step E5). Everything
    /// else keeps the first-wins name-merge: FUNCTIONS (the shadowed
    /// author stays reachable via its qualified name / SelectedFunc), and crucially
    /// `var_decl`s, including a `extern` extern global declared in two files
    /// (e.g. `__stdinp : *void extern;`) that MUST resolve to the ONE libSystem
    /// symbol, not split into a duplicate `__stdinp.1`.
    fn isPerSourceDecl(decl: *const Node) bool {
        return switch (decl.data) {
            .struct_decl, .enum_decl, .union_decl, .error_set_decl, .protocol_decl, .runtime_class_decl => true,
            .const_decl => |cd| cd.value.data != .fn_decl,
            else => false,
        };
    }

    /// Add another module as a namespaced import. The alias `name` becomes
    /// part of this module's own decls (so a flat-importer of this module
    /// sees the alias one hop out — matching authored names).
    ///
    /// Returns `false` (and adds nothing) when `name` already names a decl
    /// authored in THIS module — symmetric to `addOwnDecl`, so a namespace
    /// alias colliding with a prior same-module name is dropped rather than
    /// shadowing it. The caller surfaces the drop via `reportDuplicateName`;
    /// the reverse order (alias first, then a same-name authored decl) is
    /// caught by `addOwnDecl` seeing the alias already in `scope`.
    pub fn addNamespace(
        self: *ResolvedModule,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(*Node),
        own_list: *std.ArrayList(*Node),
        seen_list: *std.StringHashMap(void),
        name: []const u8,
        other: ResolvedModule,
        span: ast.Span,
        is_raw: bool,
    ) !bool {
        if (self.scope.contains(name)) return false;
        const ns_node = try allocator.create(Node);
        ns_node.* = .{
            .span = span,
            .data = .{
                .namespace_decl = .{
                    .name = name,
                    .decls = other.decls,
                    // The module's OWN authored decls — what `ns.fn` should bind
                    // to. `decls` stays the full transitive list so
                    // the lowering pass can still resolve transitive callees.
                    .own_decls = other.own_decls,
                    // The aliased module's resolved path (== the `resolved_path`
                    // computed for this import). Retained for `buildImportFacts`.
                    .target_module_path = other.path,
                    // Carry the backtick raw escape from the `name :: #import …`
                    // form so a reserved-name namespace is exempt from the decl
                    // check, symmetric to every other decl site.
                    .is_raw = is_raw,
                },
            },
        };
        try self.scope.put(name, {});
        try seen_list.put(name, {});
        try list.append(allocator, ns_node);
        try own_list.append(allocator, ns_node);
        return true;
    }

    pub fn finalize(
        self: *ResolvedModule,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(*Node),
        own_list: *std.ArrayList(*Node),
    ) !void {
        self.decls = try list.toOwnedSlice(allocator);
        self.own_decls = try own_list.toOwnedSlice(allocator);
    }
};

/// Module cache: maps resolved file paths to their ResolvedModules.
pub const ModuleCache = std.StringHashMap(ResolvedModule);

// ── Raw import facts (the unified-resolver store) ──
//
// `buildImportFacts` produces two source-keyed views over the resolved program,
// callable WITHOUT IR lowering (the LSP reuses it later): a scalar per-module
// raw-decl index (`name → RawDeclRef`) and the namespace import edges
// (`importer → alias → NamespaceTarget`). Both are built from each module's
// `own_decls` (the main module plus every cache entry). Function authors are
// read out of `name → RawDeclRef` directly (`fnDeclOfRaw`), so there is no
// separate function-only index.

/// A named top-level declaration the resolver may select, kept as the raw AST
/// node pointer (NOT pre-classified — a `const_decl` whose value is a function
/// stays a `.const_decl`; classification is a later phase's job). `impl_block`
/// is deliberately absent: it has no `declName` and is deduped by node identity
/// (`mergeFlat`), so it never enters the scalar index.
pub const RawDeclRef = union(enum) {
    fn_decl: *const ast.FnDecl,
    const_decl: *const ast.ConstDecl,
    var_decl: *const ast.VarDecl,
    struct_decl: *const ast.StructDecl,
    enum_decl: *const ast.EnumDecl,
    union_decl: *const ast.UnionDecl,
    error_set_decl: *const ast.ErrorSetDecl,
    protocol_decl: *const ast.ProtocolDecl,
    runtime_class_decl: *const ast.RuntimeClassDecl,
    namespace_decl: *const ast.NamespaceDecl,
};

/// A raw declaration paired with the source file that authors it.
pub const RawAuthor = struct { raw: RawDeclRef, source: []const u8 };

/// One module's scalar raw-decl index: `name → ONE RawDeclRef`. Scalar because
/// `addOwnDecl` refuses a same-module same-name second author (returns false),
/// so a module's `own_decls` carries at most one author per name. Cross-module
/// multiplicity lives one level up, keyed by path in `ModuleDecls`.
pub const ModuleRawDeclIndex = struct { source: []const u8, names: std.StringHashMap(RawDeclRef) };

/// `path → ModuleRawDeclIndex`. Two modules each authoring `f` are retained
/// under their own paths — the cross-module same-name authors the unified
/// resolver's collector will surface.
pub const ModuleDecls = std.StringHashMap(ModuleRawDeclIndex);

/// One namespace import edge: `alias :: #import "…"` (or `alias :: #import c …`).
/// `target_module_path` is captured at resolution time (otherwise lost — it is
/// not derivable from the namespace node alone). Every alias is module surface
/// under the carry rule — there is no per-edge visibility flag.
pub const NamespaceTarget = struct {
    alias: []const u8,
    importer_source: []const u8,
    target_module_path: []const u8,
    own_decls: []const *Node,
    /// The `DeclId` of each member in `own_decls`, in slice order. Filled by
    /// `buildDeclTable` (empty until then). Lets a member be addressed by stable
    /// id without re-deriving it from the node pointer.
    member_ids: []const DeclId = &.{},
};

/// `importer_source → alias → NamespaceTarget`.
pub const NamespaceEdges = std.StringHashMap(std.StringHashMap(NamespaceTarget));

/// The `RawDeclRef` a top-level node carries, or null when the node is not a
/// selectable named declaration (e.g. `impl_block`, `ufcs_alias`, a flat
/// `c_import_decl`). Public so the unified resolver's namespace collector
/// can classify a `NamespaceTarget.own_decls` node without re-deriving the map.
pub fn rawDeclRefOf(decl: *const Node) ?RawDeclRef {
    return switch (decl.data) {
        .fn_decl => |*d| .{ .fn_decl = d },
        .const_decl => |*d| .{ .const_decl = d },
        .var_decl => |*d| .{ .var_decl = d },
        .struct_decl => |*d| .{ .struct_decl = d },
        .enum_decl => |*d| .{ .enum_decl = d },
        .union_decl => |*d| .{ .union_decl = d },
        .error_set_decl => |*d| .{ .error_set_decl = d },
        .protocol_decl => |*d| .{ .protocol_decl = d },
        .runtime_class_decl => |*d| .{ .runtime_class_decl = d },
        .namespace_decl => |*d| .{ .namespace_decl = d },
        else => null,
    };
}

/// Index one module's authored decls (`own_decls`) into `decls[path]` and record
/// any namespace aliases into `ns_edges[path]`. First-wins WITHIN a module;
/// `own_decls` is already name-deduped by `addOwnDecl`, so the first-wins guard
/// never actually fires here.
fn indexModuleDecls(
    allocator: std.mem.Allocator,
    decls: *ModuleDecls,
    ns_edges: *NamespaceEdges,
    path: []const u8,
    own_decls: []const *Node,
) !void {
    const gop = try decls.getOrPut(path);
    if (!gop.found_existing) gop.value_ptr.* = .{ .source = path, .names = std.StringHashMap(RawDeclRef).init(allocator) };
    const index = gop.value_ptr;
    for (own_decls) |decl| {
        const ref = rawDeclRefOf(decl) orelse continue;
        const name = decl.data.declName() orelse continue;
        const name_gop = try index.names.getOrPut(name);
        if (!name_gop.found_existing) name_gop.value_ptr.* = ref;

        if (decl.data == .namespace_decl) {
            const ns = &decl.data.namespace_decl;
            const edge_gop = try ns_edges.getOrPut(path);
            if (!edge_gop.found_existing) edge_gop.value_ptr.* = std.StringHashMap(NamespaceTarget).init(allocator);
            const tgt_gop = try edge_gop.value_ptr.getOrPut(ns.name);
            if (!tgt_gop.found_existing) tgt_gop.value_ptr.* = .{
                .alias = ns.name,
                .importer_source = path,
                .target_module_path = ns.target_module_path,
                .own_decls = ns.own_decls,
            };
        }
    }
}

/// Build the raw import facts from a resolved program: the main module (keyed by
/// `main_path`) plus every cached module (keyed by its own path). No IR lowering
/// required.
pub fn buildImportFacts(
    allocator: std.mem.Allocator,
    main_path: []const u8,
    main_mod: ResolvedModule,
    cache: *const ModuleCache,
) !struct { decls: ModuleDecls, ns_edges: NamespaceEdges } {
    var decls = ModuleDecls.init(allocator);
    var ns_edges = NamespaceEdges.init(allocator);
    try indexModuleDecls(allocator, &decls, &ns_edges, main_path, main_mod.own_decls);
    var it = cache.iterator();
    while (it.next()) |entry| {
        try indexModuleDecls(allocator, &decls, &ns_edges, entry.key_ptr.*, entry.value_ptr.own_decls);
    }
    return .{ .decls = decls, .ns_edges = ns_edges };
}

// ── DeclTable: a stable DeclId for every declaration (Fork C S1, additive) ──
//
// `buildDeclTable` lifts every `RawDeclRef` the import facts hold into a stable
// `DeclId` carrying source + name + AST node identity + span + `DeclKind`. It is
// built in PARALLEL with the old maps and nothing in lowering consumes it for
// selection yet (S4 makes it the fact-store key), so generated IR + bytes are
// unchanged by construction.

/// The taxonomy of a declaration, mirroring the `RawDeclRef` variants so a
/// `DeclTable` row carries its kind without re-switching on the AST node.
pub const DeclKind = enum {
    function,
    constant,
    global,
    @"struct",
    @"enum",
    @"union",
    error_set,
    protocol,
    runtime_class,
    namespace,
};

fn declKindOf(ref: RawDeclRef) DeclKind {
    return switch (ref) {
        .fn_decl => .function,
        .const_decl => .constant,
        .var_decl => .global,
        .struct_decl => .@"struct",
        .enum_decl => .@"enum",
        .union_decl => .@"union",
        .error_set_decl => .error_set,
        .protocol_decl => .protocol,
        .runtime_class_decl => .runtime_class,
        .namespace_decl => .namespace,
    };
}

/// The AST node identity a `RawDeclRef` wraps — the inner decl pointer every
/// variant holds (the same identity `resolver.zig` selects authors by). This is
/// the key the `DeclTable` indexes and round-trips on.
pub fn authorNodePtrOf(ref: RawDeclRef) usize {
    return switch (ref) {
        inline else => |p| @intFromPtr(p),
    };
}

/// The `*const ast.StructDecl` a top-level decl node carries, or null when it is
/// not a struct — a bare `struct_decl` or a `const_decl` whose value is one,
/// both unwrapping to the same inner decl (mirrors lower's `structDeclOfRaw`).
fn structDeclPtrOf(decl: *const Node) ?*const ast.StructDecl {
    return switch (decl.data) {
        .struct_decl => &decl.data.struct_decl,
        .const_decl => |cd| if (cd.value.data == .struct_decl) &cd.value.data.struct_decl else null,
        else => null,
    };
}

/// A stable identifier for one declaration, assigned by `DeclTable` in module-
/// walk order. Process-local: it indexes the table's `entries` (S5 stabilizes it
/// to `(source, index)` for the LSP, per the deep-dive's R5).
pub const DeclId = enum(u32) { _ };

/// One `DeclTable` row: a `RawDeclRef` lifted to a stable `DeclId`, with its
/// authoring source path, display name, AST span, and `DeclKind`. `ref` is the
/// same raw author the import facts hold (its AST node identity is `id`'s key).
pub const DeclInfo = struct {
    id: DeclId,
    source: []const u8,
    name: []const u8,
    ref: RawDeclRef,
    span: ast.Span,
    kind: DeclKind,
};

/// Stable `DeclId` for every source / namespaced / imported / C-imported decl.
/// `entries` is indexed by `DeclId`; `by_node` reverse-maps the AST node
/// identity (`authorNodePtrOf`) to its id; `by_struct` maps a generic struct's
/// inner `*StructDecl` to its id (so a template registered during lowering can
/// be keyed by `DeclId`). Borrowed by `ProgramIndex.decl_table`.
pub const DeclTable = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(DeclInfo) = .empty,
    by_node: std.AutoHashMap(usize, DeclId),
    by_struct: std.AutoHashMap(usize, DeclId),

    pub fn init(alloc: std.mem.Allocator) DeclTable {
        return .{
            .alloc = alloc,
            .by_node = std.AutoHashMap(usize, DeclId).init(alloc),
            .by_struct = std.AutoHashMap(usize, DeclId).init(alloc),
        };
    }

    pub fn deinit(self: *DeclTable) void {
        self.entries.deinit(self.alloc);
        self.by_node.deinit();
        self.by_struct.deinit();
    }

    pub fn get(self: *const DeclTable, id: DeclId) DeclInfo {
        return self.entries.items[@intFromEnum(id)];
    }

    /// The `DeclId` for an AST node (by its `RawDeclRef` identity), or null when
    /// the node never entered the table.
    pub fn declIdForRef(self: *const DeclTable, ref: RawDeclRef) ?DeclId {
        return self.by_node.get(authorNodePtrOf(ref));
    }

    /// The `DeclId` for a generic struct template's inner `*StructDecl`, or null.
    pub fn declIdForStructDecl(self: *const DeclTable, sd: *const ast.StructDecl) ?DeclId {
        return self.by_struct.get(@intFromPtr(sd));
    }

    /// Intern one top-level decl node, returning its (possibly pre-existing)
    /// `DeclId`. First-wins / diamond dedup by node identity, matching how the
    /// scalar import facts dedup. The caller guarantees `rawDeclRefOf(decl)` is
    /// non-null (so `declName` is too).
    fn intern(self: *DeclTable, source: []const u8, decl: *const Node) !DeclId {
        const ref = rawDeclRefOf(decl).?;
        const key = authorNodePtrOf(ref);
        if (self.by_node.get(key)) |existing| return existing;
        const id: DeclId = @enumFromInt(@as(u32, @intCast(self.entries.items.len)));
        try self.entries.append(self.alloc, .{
            .id = id,
            .source = source,
            .name = decl.data.declName().?,
            .ref = ref,
            .span = decl.span,
            .kind = declKindOf(ref),
        });
        try self.by_node.put(key, id);
        if (structDeclPtrOf(decl)) |sd| try self.by_struct.put(@intFromPtr(sd), id);
        return id;
    }

    fn internModule(self: *DeclTable, source: []const u8, own_decls: []const *Node) !void {
        for (own_decls) |decl| {
            if (rawDeclRefOf(decl) == null) continue;
            _ = try self.intern(source, decl);
        }
    }

    /// Debug cross-check (S1.1 acceptance): every `RawDeclRef` the import facts
    /// hold round-trips `RawDeclRef → DeclId → AST node ptr` back to the same
    /// node, with matching name. Asserts; call only under `builtin.mode == .Debug`.
    pub fn verifyRoundTrip(self: *const DeclTable, decls: *const ModuleDecls, ns_edges: *const NamespaceEdges) void {
        var mit = decls.iterator();
        while (mit.next()) |m| {
            var nit = m.value_ptr.names.iterator();
            while (nit.next()) |kv| {
                const ref = kv.value_ptr.*;
                const id = self.declIdForRef(ref) orelse @panic("DeclTable round-trip: module ref has no DeclId");
                const info = self.get(id);
                std.debug.assert(authorNodePtrOf(info.ref) == authorNodePtrOf(ref));
                std.debug.assert(std.mem.eql(u8, info.name, kv.key_ptr.*));
            }
        }
        var nsit = ns_edges.iterator();
        while (nsit.next()) |imp| {
            var ait = imp.value_ptr.valueIterator();
            while (ait.next()) |target| {
                for (target.own_decls) |decl| {
                    const ref = rawDeclRefOf(decl) orelse continue;
                    const id = self.declIdForRef(ref) orelse @panic("DeclTable round-trip: ns member has no DeclId");
                    std.debug.assert(authorNodePtrOf(self.get(id).ref) == authorNodePtrOf(ref));
                }
            }
        }
    }
};

/// Build the `DeclTable` from the resolved program + the import facts: every
/// module author (main + cache) interned first, then every namespace member
/// (reusing the module author's id when it is also a module decl, minting a new
/// id for a synthetic C-import member). `ns_edges` is updated in place so each
/// `NamespaceTarget.member_ids` lists its members' ids. Built from the SAME
/// modules `buildImportFacts` walks; no IR lowering required.
pub fn buildDeclTable(
    allocator: std.mem.Allocator,
    main_path: []const u8,
    main_mod: ResolvedModule,
    cache: *const ModuleCache,
    decls: *const ModuleDecls,
    ns_edges: *NamespaceEdges,
) !DeclTable {
    var table = DeclTable.init(allocator);
    try table.internModule(main_path, main_mod.own_decls);
    var it = cache.iterator();
    while (it.next()) |entry| {
        try table.internModule(entry.key_ptr.*, entry.value_ptr.own_decls);
    }

    var nsit = ns_edges.iterator();
    while (nsit.next()) |imp| {
        var ait = imp.value_ptr.valueIterator();
        while (ait.next()) |target| {
            var ids = std.ArrayList(DeclId).empty;
            for (target.own_decls) |decl| {
                if (rawDeclRefOf(decl) == null) continue;
                const id = try table.intern(target.target_module_path, decl);
                try ids.append(allocator, id);
            }
            target.member_ids = try ids.toOwnedSlice(allocator);
        }
    }

    if (builtin.mode == .Debug) table.verifyRoundTrip(decls, ns_edges);
    return table;
}

/// Surface a same-module duplicate top-level declaration as a hard error at an
/// explicit name + span. `addOwnDecl` / `addNamespace` return `false` when the
/// name is already in this module's scope and drop the second author; without
/// this the drop is silent, and the scalar `ModuleRawDeclIndex` would lose an
/// authored name with no diagnostic.
fn reportDuplicateName(diagnostics: ?*errors.DiagnosticList, added: bool, name: []const u8, span: ast.Span) void {
    if (added) return;
    const diags = diagnostics orelse return;
    diags.addFmt(.err, span, "duplicate top-level declaration '{s}'", .{name});
}

/// Build the diagnostic span for a failed import parse, from the parser's
/// ACTUAL error location INSIDE the imported file (`err_offset`/`err_end`) —
/// not the importing file's `#import` span. Pair with `addFmtInFile` so the
/// caret resolves against the imported file's own source (the source is already
/// registered in `import_sources`); otherwise it falls back to the root file
/// and the caret lands on an unrelated line.
fn importErrSpan(p: *const parser.Parser) ast.Span {
    const start = p.err_offset orelse 0;
    return .{ .start = start, .end = p.err_end orelse start };
}

/// Stamp the DEFINING module path onto a function body node, so a later
/// pack/comptime monomorphization can pin `current_source_file` to the body's
/// own module and resolve its bare names in that module's visibility context
/// — mirroring how a normally-declared function carries
/// `Function.source_file`. Only top-level decl Nodes are otherwise stamped, so
/// the body Node would carry no source; a null body source after this means a
/// synthesized/sourceless decl (the monomorphizer then keeps its caller's
/// context, the legitimate fall-open).
fn stampFnBodySource(decl: *Node, file_path: []const u8) void {
    switch (decl.data) {
        .fn_decl => |fd| fd.body.source_file = file_path,
        .struct_decl => |sd| stampStructMethodSources(sd, file_path),
        // A parameterized protocol is instantiated cross-module; record its
        // defining path so the instantiation resolves method-signature types in
        // this module (E4).
        .protocol_decl => decl.data.protocol_decl.source_file = file_path,
        // An sx-defined `#objc_class` / `#jni_class`: its IMP trampolines are
        // emitted at lowering time (possibly from another module's context), so
        // record the defining path AND stamp each method body (E4).
        .runtime_class_decl => {
            decl.data.runtime_class_decl.source_file = file_path;
            stampRuntimeClassMethodSources(decl.data.runtime_class_decl, file_path);
        },
        // An `impl P for T { ... }`: its methods are registered into
        // `fn_ast_map` and their declared param/return types may name a type
        // bare-visible only in this module. Stamp each method body's source so a
        // cross-module conformance check (erasure to an imported protocol) pins
        // the impl-side type resolution to the impl's OWN module (issue 0208),
        // not the erasure site.
        .impl_block => |ib| stampImplMethodSources(ib, file_path),
        .const_decl => |cd| switch (cd.value.data) {
            .fn_decl => |fd| fd.body.source_file = file_path,
            // `List :: struct { … append :: (…) { … } }` — the methods of a
            // (possibly generic) struct are monomorphized in their template's
            // OWN module (the E4 instantiation source-pin), so their
            // bodies need the defining path stamped just like a top-level fn.
            .struct_decl => |sd| stampStructMethodSources(sd, file_path),
            .protocol_decl => cd.value.data.protocol_decl.source_file = file_path,
            .runtime_class_decl => {
                cd.value.data.runtime_class_decl.source_file = file_path;
                stampRuntimeClassMethodSources(cd.value.data.runtime_class_decl, file_path);
            },
            else => {},
        },
        else => {},
    }
}

/// Stamp the defining module path onto every method (and struct-level fn
/// constant) body of a struct decl, so a generic-struct method monomorphized at
/// a cross-module call site still pins to the module that declares it.
fn stampStructMethodSources(sd: ast.StructDecl, file_path: []const u8) void {
    for (sd.methods) |m| {
        if (m.data == .fn_decl) m.data.fn_decl.body.source_file = file_path;
    }
    for (sd.constants) |c| {
        if (c.data == .const_decl and c.data.const_decl.value.data == .fn_decl) {
            c.data.const_decl.value.data.fn_decl.body.source_file = file_path;
        }
    }
}

/// Stamp the defining module path onto every method body of an `impl P for T`
/// block, so a cross-module protocol conformance check resolves the impl
/// method's declared param/return types in the impl's OWN module (issue 0208).
fn stampImplMethodSources(ib: ast.ImplBlock, file_path: []const u8) void {
    for (ib.methods) |m| {
        if (m.data == .fn_decl) m.data.fn_decl.body.source_file = file_path;
    }
}

/// Stamp the defining module path onto every bodied method of an sx-defined
/// runtime class, so the method's sx body lowers in the class's own module.
fn stampRuntimeClassMethodSources(fcd: ast.RuntimeClassDecl, file_path: []const u8) void {
    for (fcd.members) |m| {
        if (m == .method) {
            if (m.method.body) |b| b.source_file = file_path;
        }
    }
}

/// `reportDuplicateName` keyed off a node whose `declName()` carries the name
/// (the regular authored-decl sites; an `import_decl` has no `declName`, so a
/// namespace alias must use `reportDuplicateName` with the alias directly).
fn reportDuplicateDecl(diagnostics: ?*errors.DiagnosticList, added: bool, decl: *const Node) void {
    if (added) return;
    const name = decl.data.declName() orelse return;
    reportDuplicateName(diagnostics, added, name, decl.span);
}

pub fn resolveImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *Node,
    base_dir: []const u8,
    file_path: []const u8,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    comptime_ctx: ComptimeContext,
) !ResolvedModule {
    // Record this file's edge set so `param_impl_map` lookups can filter
    // candidates by what's been imported from where. Populated as each
    // import resolves below; transitive closure computed on demand.
    if (import_graph) |g| {
        if (!g.contains(file_path)) {
            try g.put(file_path, std.StringHashMap(void).init(allocator));
        }
    }
    // FLAT-only edge set: identical to `import_graph` but records ONLY bare
    // `#import "…"` edges (`imp.name == null`), never a namespaced
    // `ns :: #import "…"`. The bare-name disambiguation walks this to
    // decide which same-name authors a flat importer can actually reach.
    if (flat_import_graph) |g| {
        if (!g.contains(file_path)) {
            try g.put(file_path, std.StringHashMap(void).init(allocator));
        }
    }
    var mod = ResolvedModule{
        .path = file_path,
        .decls = &.{},
        .own_decls = &.{},
        .scope = std.StringHashMap(void).init(allocator),
    };

    if (root.data != .root) {
        mod.decls = &.{};
        return mod;
    }

    // Hoist top-level `inline if OS == .X { ... }` body decls (including
    // any `#import`s inside them) to the top level before resolution
    // proceeds. After this pass, the decl list contains no top-level
    // `if_expr` / `match_expr` nodes with `is_comptime = true`.
    const flat_decls = try flattenComptimeConditionals(allocator, root.data.root.decls, comptime_ctx, diagnostics);

    var decl_list = std.ArrayList(*Node).empty;
    var own_decl_list = std.ArrayList(*Node).empty;
    // Name set spanning every decl already appended to `decl_list` — used
    // by `mergeFlat` to dedupe across diamond imports now that `mod.scope`
    // is non-transitive and can no longer serve as the dedup key.
    var seen_in_list = std.StringHashMap(void).init(allocator);
    // Node-identity set for the same purpose, covering anonymous decls
    // (impl blocks) that carry no name to dedupe on.
    var seen_nodes = std.AutoHashMap(*Node, void).init(allocator);

    for (flat_decls) |decl| {
        if (decl.data == .c_import_decl) {
            // Resolve `#source` / `#include` paths through the same chain
            // as `#import`: importing-file's directory → CWD → stdlib
            // search paths. This lets sx-library modules ship their own
            // C helpers (e.g. the Android JNI insets bridge) without
            // forcing every consumer to vendor an identically-named copy.
            {
                const ci_pre = decl.data.c_import_decl;
                if (ci_pre.sources.len > 0) {
                    var resolved = try allocator.alloc([]const u8, ci_pre.sources.len);
                    for (ci_pre.sources, 0..) |raw_src, idx| {
                        resolved[idx] = try resolveImportPath(allocator, io, base_dir, raw_src, null, stdlib_paths);
                    }
                    decl.data.c_import_decl.sources = resolved;
                }
                if (ci_pre.includes.len > 0) {
                    var resolved = try allocator.alloc([]const u8, ci_pre.includes.len);
                    for (ci_pre.includes, 0..) |raw_inc, idx| {
                        resolved[idx] = try resolveImportPath(allocator, io, base_dir, raw_inc, null, stdlib_paths);
                    }
                    decl.data.c_import_decl.includes = resolved;
                }
            }
            const ci = decl.data.c_import_decl;

            // Parse headers to get synthetic function declarations
            const result = c_import.processCImport(
                allocator,
                ci.includes,
                ci.defines,
                ci.flags,
            ) catch |err| {
                if (diagnostics) |diags| {
                    diags.addFmt(.err, decl.span, "#import c failed: {}", .{err});
                }
                return error.ImportError;
            };

            if (ci.name) |ns_name| {
                // Namespaced: wrap fn_decls + c_import_decl in a namespace
                var ns_decls = std.ArrayList(*Node).empty;
                for (result.fn_decls) |fd| {
                    try ns_decls.append(allocator, fd);
                }
                // Keep c_import_decl inside namespace so codegen can find sources
                try ns_decls.append(allocator, decl);

                const ns_slice = try ns_decls.toOwnedSlice(allocator);
                const ns_node = try allocator.create(Node);
                ns_node.* = .{
                    .span = decl.span,
                    .data = .{
                        .namespace_decl = .{
                            .name = ns_name,
                            .decls = ns_slice,
                            // A C-import namespace authors exactly the wrapped fn
                            // decls — they ARE its own decls.
                            .own_decls = ns_slice,
                            // No separate sx module: the synthesized members are
                            // authored in THIS file. Record the importer's path.
                            .target_module_path = file_path,
                            .is_raw = ci.is_raw,
                        },
                    },
                };
                ns_node.source_file = file_path;
                if (mod.scope.contains(ns_name)) {
                    reportDuplicateName(diagnostics, false, ns_name, decl.span);
                } else {
                    try mod.scope.put(ns_name, {});
                    try seen_in_list.put(ns_name, {});
                    try decl_list.append(allocator, ns_node);
                    try own_decl_list.append(allocator, ns_node);
                }
            } else {
                // Flat: add fn_decls directly + keep c_import_decl
                for (result.fn_decls) |fd| {
                    fd.source_file = file_path;
                    reportDuplicateDecl(diagnostics, try mod.addOwnDecl(allocator, &decl_list, &own_decl_list, &seen_in_list, fd), fd);
                }
                decl.source_file = file_path;
                reportDuplicateDecl(diagnostics, try mod.addOwnDecl(allocator, &decl_list, &own_decl_list, &seen_in_list, decl), decl);
            }
            continue;
        }
        if (decl.data != .import_decl) {
            decl.source_file = file_path;
            stampFnBodySource(decl, file_path);
            reportDuplicateDecl(diagnostics, try mod.addOwnDecl(allocator, &decl_list, &own_decl_list, &seen_in_list, decl), decl);
            continue;
        }
        const imp = decl.data.import_decl;

        const resolved_path = try resolveImportPath(allocator, io, base_dir, imp.path, null, stdlib_paths);

        // Record direct-import edge file_path → resolved_path. Self-imports
        // and chain duplicates are still recorded so the graph reflects what
        // the user wrote (filter happens at lookup).
        if (import_graph) |g| {
            if (g.getPtr(file_path)) |set| {
                set.put(resolved_path, {}) catch {};
            }
        }
        // The same edge, FLAT-only: recorded only for a bare `#import`
        // (`imp.name == null`), excluding a namespaced `ns :: #import`. Covers
        // both a flat file import and a flat directory import (`resolved_path`
        // is the directory in the latter case).
        if (imp.name == null) {
            if (flat_import_graph) |g| {
                if (g.getPtr(file_path)) |set| {
                    set.put(resolved_path, {}) catch {};
                }
            }
        }

        // Circular import check — only along the current chain
        if (chain.contains(resolved_path)) continue;

        // Resolve or retrieve the imported module
        const imported_mod = if (cache.get(resolved_path)) |cached|
            cached
        else blk: {
            // Try as file first
            if (std.Io.Dir.readFileAlloc(.cwd(), io, resolved_path, allocator, .limited(10 * 1024 * 1024))) |imp_bytes| {
                const imp_source = try allocator.dupeZ(u8, imp_bytes);

                if (source_map) |sm| {
                    sm.put(resolved_path, imp_source) catch {};
                }

                var p = parser.Parser.init(allocator, imp_source);
                const imp_root = p.parse() catch {
                    if (diagnostics) |diags| {
                        diags.addFmtInFile(.err, resolved_path, importErrSpan(&p), "parse error in '{s}': {s}", .{ resolved_path, p.err_msg orelse "unknown" });
                    }
                    return error.ImportError;
                };

                // Push onto chain before recursing, pop after
                try chain.put(resolved_path, {});
                const imp_dir = dirName(resolved_path);
                const result = try resolveImports(allocator, io, imp_root, imp_dir, resolved_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph, comptime_ctx);
                _ = chain.remove(resolved_path);

                // Cache
                try cache.put(resolved_path, result);
                break :blk result;
            } else |_| {
                // File read failed — try as directory import. An extensionless
                // path that names a directory next to a same-named `.sx` file
                // is ambiguous: require the explicit `.sx` spelling for the
                // file rather than silently picking the directory. Exception:
                // when the sibling `.sx` is the importing file itself (a test
                // importing its own companion directory), the directory is the
                // only sensible target.
                const sibling_sx = try std.fmt.allocPrint(allocator, "{s}.sx", .{resolved_path});
                const sibling_exists = if (std.mem.eql(u8, sibling_sx, file_path))
                    false
                else if (std.Io.Dir.readFileAlloc(.cwd(), io, sibling_sx, allocator, .limited(10 * 1024 * 1024))) |_|
                    true
                else |_|
                    false;
                if (sibling_exists) {
                    const is_dir = if (std.Io.Dir.openDir(.cwd(), io, resolved_path, .{})) |d| dir_blk: {
                        d.close(io);
                        break :dir_blk true;
                    } else |_| false;
                    if (is_dir) {
                        if (diagnostics) |diags| {
                            diags.addFmt(.err, decl.span, "ambiguous import '{s}': both a file '{s}.sx' and a directory '{s}' exist — write \"{s}.sx\" to import the file", .{ imp.path, imp.path, imp.path, imp.path });
                        }
                        return error.ImportError;
                    }
                }
                const result = resolveDirectoryImport(allocator, io, resolved_path, chain, cache, source_map, diagnostics, decl.span, stdlib_paths, import_graph, flat_import_graph, comptime_ctx) catch {
                    if (diagnostics) |diags| {
                        diags.addFmt(.err, decl.span, "cannot read import '{s}' (not a file or directory)", .{resolved_path});
                    }
                    return error.ImportError;
                };
                try cache.put(resolved_path, result);
                break :blk result;
            }
        };

        if (imp.name) |ns_name| {
            const added = try mod.addNamespace(allocator, &decl_list, &own_decl_list, &seen_in_list, ns_name, imported_mod, decl.span, imp.is_raw);
            reportDuplicateName(diagnostics, added, ns_name, decl.span);
        } else {
            try mod.mergeFlat(allocator, &decl_list, &seen_in_list, &seen_nodes, imported_mod);
        }
    }

    try mod.finalize(allocator, &decl_list, &own_decl_list);
    return mod;
}

/// Resolve a directory import by aggregating all .sx files in the directory.
fn resolveDirectoryImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    span: ast.Span,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    comptime_ctx: ComptimeContext,
) anyerror!ResolvedModule {
    // Open the directory with iteration capability
    const dir = std.Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch {
        return error.ImportError;
    };
    defer dir.close(io);

    // Collect all .sx file names
    var file_names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sx")) continue;
        const name_copy = try allocator.dupe(u8, entry.name);
        try file_names.append(allocator, name_copy);
    }

    // Sort alphabetically for deterministic ordering
    std.mem.sort([]const u8, file_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Add directory to chain for circular import detection
    try chain.put(dir_path, {});
    defer _ = chain.remove(dir_path);

    // Merge all files into a combined module. From an importer's perspective
    // a directory is one big module: the combined module's `own_decls` is
    // the union of every file's `own_decls`, so flat-importing the directory
    // exposes everything the files themselves authored — but not what those
    // files transitively imported from outside the directory.
    var combined = ResolvedModule{
        .path = dir_path,
        .decls = &.{},
        .own_decls = &.{},
        .scope = std.StringHashMap(void).init(allocator),
    };
    var decl_list = std.ArrayList(*Node).empty;
    var own_decl_list = std.ArrayList(*Node).empty;
    var seen_in_list = std.StringHashMap(void).init(allocator);
    var seen_nodes = std.AutoHashMap(*Node, void).init(allocator);

    for (file_names.items) |file_name| {
        // `dir_path` arrives canonical from `resolveImportPath`, but the join
        // can still de-canonicalize (e.g. a `.` dir_path → `./x.sx`), so the
        // per-file key goes through the same chokepoint.
        const file_path = try canonicalizePath(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name }));

        if (chain.contains(file_path)) continue;

        const file_mod = if (cache.get(file_path)) |cached|
            cached
        else file_blk: {
            const imp_bytes = std.Io.Dir.readFileAlloc(.cwd(), io, file_path, allocator, .limited(10 * 1024 * 1024)) catch {
                if (diagnostics) |diags| {
                    diags.addFmt(.err, span, "cannot read '{s}' in directory import", .{file_path});
                }
                return error.ImportError;
            };
            const imp_source = try allocator.dupeZ(u8, imp_bytes);

            if (source_map) |sm| {
                sm.put(file_path, imp_source) catch {};
            }

            var p = parser.Parser.init(allocator, imp_source);
            const imp_root = p.parse() catch {
                if (diagnostics) |diags| {
                    diags.addFmtInFile(.err, file_path, importErrSpan(&p), "parse error in '{s}': {s}", .{ file_path, p.err_msg orelse "unknown" });
                }
                return error.ImportError;
            };

            try chain.put(file_path, {});
            const result = try resolveImports(allocator, io, imp_root, dir_path, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph, comptime_ctx);
            _ = chain.remove(file_path);

            try cache.put(file_path, result);
            break :file_blk result;
        };

        // Source-order matters: a file's own decls (e.g. `impl Foo` blocks)
        // may reference types defined in OTHER files that THIS file imports.
        // `file_mod.decls` already lists transitive-imported decls before
        // the file's own decls (resolveImports processes `#import` lines in
        // source order, and #imports usually come first), so iterating it
        // directly preserves the scan order the lowering pass needs to
        // register `Event` (a tagged_union) before `handle_event(e: *Event)`
        // triggers the placeholder-struct fallback in `resolveTypeName`.
        for (file_mod.decls) |decl| {
            if (seen_nodes.contains(decl)) continue;
            if (decl.data.declName()) |name| {
                if (seen_in_list.contains(name)) continue;
                try seen_in_list.put(name, {});
            }
            try seen_nodes.put(decl, {});
            try decl_list.append(allocator, decl);
        }
        // Separately track which decls the directory `re-exports` to its
        // flat-importers. Position in `own_decl_list` doesn't matter — it's
        // only consumed by the importer-side visibility join (`isNameVisible`
        // in lower.zig) which treats it as a set.
        for (file_mod.own_decls) |decl| {
            if (decl.data.declName()) |name| {
                if (combined.scope.contains(name)) continue;
                try combined.scope.put(name, {});
            }
            try own_decl_list.append(allocator, decl);
        }
    }

    try combined.finalize(allocator, &decl_list, &own_decl_list);
    return combined;
}
