const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const c_import = @import("c_import.zig");
const Node = ast.Node;

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
    defer stack.deinit(allocator);
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
    errdefer out.deinit(allocator);
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

pub fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const norm = try lexicalNormalize(allocator, path);
    errdefer allocator.free(norm);
    if (norm.len == 0 or norm[0] != '/') return norm;
    var buf: [4096]u8 = undefined;
    if (getcwd(&buf, buf.len)) |cwd_z| {
        if (relativeTo(norm, std.mem.span(cwd_z))) |rel| {
            const result = try allocator.dupe(u8, rel);
            allocator.free(norm);
            return result;
        }
    }
    if (c_getenv("PWD")) |pwd_z| {
        const pwd = try lexicalNormalize(allocator, std.mem.span(pwd_z));
        defer allocator.free(pwd);
        if (pwd.len > 0 and pwd[0] == '/' and namesCwd(std.mem.span(pwd_z))) {
            if (relativeTo(norm, pwd)) |rel| {
                const result = try allocator.dupe(u8, rel);
                allocator.free(norm);
                return result;
            }
        }
    }
    return norm;
}

/// Whether `dir` is the real cwd; an inherited `$PWD` can name another directory.
fn namesCwd(dir: [:0]const u8) bool {
    const a = fileIdentity(dir) orelse return false;
    const b = fileIdentity(".") orelse return false;
    return std.meta.eql(a, b);
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
/// when it provably names the same file on disk (an
/// absolute entry under the CWD then displays/keys cwd-relative, matching a
/// relative invocation); otherwise keep the user's spelling (nonexistent
/// entry, symlinked `..` component, stale `$PWD`).
pub fn canonicalizeEntryPath(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    const canon = canonicalizePath(allocator, path) catch return path;
    if (std.mem.eql(u8, canon, path)) return canon;
    if (sameFileIdentity(allocator, canon, path)) return canon;
    return path;
}

/// A file's `(device, inode)` pair in the integer types its platform reports,
/// compared field-wise. Zig defines `std.c.Stat` and `std.posix.Stat` as
/// `void` on linux, so linux carries statx's split major/minor device id.
const FileIdentity = switch (builtin.os.tag) {
    .linux => struct { dev_major: u32, dev_minor: u32, ino: u64 },
    else => struct { dev: std.c.dev_t, ino: std.c.ino_t },
};

/// Symlink-following identity of `path`, or null when it cannot be stat'd.
fn fileIdentity(path: [:0]const u8) ?FileIdentity {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var st: linux.Statx = undefined;
            const rc = linux.statx(linux.AT.FDCWD, path.ptr, 0, .{ .INO = true }, &st);
            if (linux.errno(rc) != .SUCCESS or !st.mask.INO) return null;
            return .{ .dev_major = st.dev_major, .dev_minor = st.dev_minor, .ino = st.ino };
        },
        else => {
            var st: std.c.Stat = undefined;
            if (c_stat(path.ptr, &st) != 0) return null;
            return .{ .dev = st.dev, .ino = st.ino };
        },
    }
}

/// Do two path spellings name the SAME file on disk? Symlink-following stat
/// identity (st_dev + st_ino). Any stat failure → false — the caller keeps
/// the spelling that was actually probed.
pub fn sameFileIdentity(allocator: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    const az = allocator.dupeZ(u8, a) catch return false;
    const bz = allocator.dupeZ(u8, b) catch return false;
    const ia = fileIdentity(az) orelse return false;
    const ib = fileIdentity(bz) orelse return false;
    return std.meta.eql(ia, ib);
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
    // directive (e.g. `@import "modules/std.sx"`) supplies the rest.
    // Dev: zig-out/bin/sx -> repo-root/library
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/../../library", .{exe_dir}));
    // Install: <prefix>/bin/sx -> <prefix>/library
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/../library", .{exe_dir}));
    // Alongside the binary.
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/library", .{exe_dir}));
    // Through the same chokepoint resolved file paths take, so a root and the
    // files under it are spelled the same way. Built from `exe_dir`, these carry
    // `..` hops and stay absolute; a resolved file is lexically normalized and
    // cwd-relativized, so without this no root ever prefixes any file.
    for (out.items) |*p| {
        p.* = canonicalizePath(allocator, p.*) catch p.*;
    }
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

pub fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
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
    environment: EnvironmentId,

    pub fn addOwnDecl(
        self: *ResolvedModule,
        allocator: std.mem.Allocator,
        table: *DeclTable,
        list: *std.ArrayList(*Node),
        own_list: *std.ArrayList(*Node),
        seen_list: *std.StringHashMap(void),
        decl: *Node,
    ) !bool {
        var append_to_global = true;
        if (decl.data.declName()) |name| {
            if (!try table.claim(self.environment, decl)) return false;
            if (seen_list.contains(name)) {
                append_to_global = isPerSourceDecl(decl);
            } else {
                try seen_list.put(name, {});
            }
        }
        if (append_to_global) try list.append(allocator, decl);
        try own_list.append(allocator, decl);
        return true;
    }

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
                    if (!isPerSourceDecl(decl)) continue;
                } else {
                    try seen_list.put(name, {});
                }
            }
            try seen_nodes.put(decl, {});
            try list.append(allocator, decl);
        }
    }

    pub fn isPerSourceDecl(decl: *const Node) bool {
        if (decl.data.declName()) |name| {
            if (name.len > 0 and name[0] == '@') return true;
        }
        return switch (decl.data) {
            .struct_decl, .enum_decl, .union_decl, .error_set_decl, .protocol_decl, .open_set_decl, .runtime_class_decl, .scope_decl, .namespace_decl => true,
            .fn_decl => |fd| fd.extern_export == .extern_ or fd.body.data == .intrinsic_expr,
            .const_decl => |cd| cd.value.data != .fn_decl or isPerSourceDecl(cd.value),
            .var_decl => true,
            else => false,
        };
    }

    pub fn addNamespace(
        self: *ResolvedModule,
        allocator: std.mem.Allocator,
        table: *DeclTable,
        list: *std.ArrayList(*Node),
        own_list: *std.ArrayList(*Node),
        seen_list: *std.StringHashMap(void),
        name: []const u8,
        other: ResolvedModule,
        span: ast.Span,
        is_raw: bool,
        visibility: ast.Visibility,
        lexical_block: LexicalBlockId,
    ) !bool {
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
                    .target_module_path = other.path,
                    // Carry the backtick raw escape from the `name :: @import …`
                    // form so a reserved-name namespace is exempt from the decl
                    // check, symmetric to every other decl site.
                    .is_raw = is_raw,
                },
            },
            // A `private ns :: @import "…"` alias stays usable in this file but
            // is never carried to flat importers nor selectable through this
            // module's namespace surface.
            .visibility = visibility,
        };
        ns_node.source_file = self.path;
        ns_node.lexical_block = lexical_block;
        if (!try table.claim(self.environment, ns_node)) return false;
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

pub const ModuleCache = struct {
    modules: std.StringHashMap(ResolvedModule),
    declarations: DeclTable,

    pub fn init(allocator: std.mem.Allocator) ModuleCache {
        return .{
            .modules = std.StringHashMap(ResolvedModule).init(allocator),
            .declarations = DeclTable.init(allocator),
        };
    }
};

/// A named top-level declaration the resolver may select, kept as the raw AST
/// node pointer (NOT pre-classified — a `const_decl` whose value is a function
/// stays a `.const_decl`). `impl_block`
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
    open_set_decl: *const ast.OpenSetDecl,
    runtime_class_decl: *const ast.RuntimeClassDecl,
    namespace_decl: *const ast.NamespaceDecl,
};

pub const RawAuthor = struct {
    id: DeclId,
    raw: RawDeclRef,
    source: []const u8,
    visibility: ast.Visibility = .public,
};

pub fn aliasPath(allocator: std.mem.Allocator, node: *const Node) ?[]const u8 {
    return switch (node.data) {
        .identifier => |id| allocator.dupe(u8, id.name) catch @panic("out of memory"),
        .type_expr => |te| allocator.dupe(u8, te.name) catch @panic("out of memory"),
        .field_access => |fa| blk: {
            const object = aliasPath(allocator, fa.object) orelse break :blk null;
            defer allocator.free(object);
            break :blk std.fmt.allocPrint(allocator, "{s}.{s}", .{ object, fa.field }) catch @panic("out of memory");
        },
        else => null,
    };
}

pub const EnvironmentId = enum(u32) { _ };
pub const ScopeId = enum(u32) { _ };
pub const LexicalBlockId = ast.LexicalBlockId;

const ScopePathContext = struct {
    pub fn hash(_: @This(), path: []const []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        for (path) |part| {
            std.hash.autoHash(&h, part.len);
            h.update(part);
        }
        return h.final();
    }

    pub fn eql(_: @This(), a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |left, right| {
            if (!std.mem.eql(u8, left, right)) return false;
        }
        return true;
    }
};

pub const Scope = struct {
    path: []const []const u8,
};

pub const LexicalBlock = struct {
    environment: EnvironmentId,
    parent: ?LexicalBlockId,
    node: *const Node,
    imports: std.ArrayList(*const Node) = .empty,
    spreads: std.ArrayList(*const Node) = .empty,
};

pub const WrittenTarget = struct {
    source: []const u8,
    block: LexicalBlockId,
    position: u32,
    operand: *const Node,
};

pub const SpreadSource = union(enum) {
    missing,
    module: []const u8,
    path: *const Node,
    c_import: []const DeclId,
};

pub const Publication = enum { deferred, published };

const EnvironmentKey = struct {
    source: []const u8,
    scope_path: []const []const u8,
};

const EnvironmentKeyContext = struct {
    pub fn hash(_: @This(), key: EnvironmentKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.source);
        for (key.scope_path) |part| {
            std.hash.autoHash(&h, part.len);
            h.update(part);
        }
        return h.final();
    }

    pub fn eql(_: @This(), a: EnvironmentKey, b: EnvironmentKey) bool {
        if (!std.mem.eql(u8, a.source, b.source) or a.scope_path.len != b.scope_path.len) return false;
        for (a.scope_path, b.scope_path) |left, right| {
            if (!std.mem.eql(u8, left, right)) return false;
        }
        return true;
    }
};

pub const Environment = struct {
    source: []const u8,
    scope_path: []const []const u8,
    scope: ?ScopeId = null,
    names: std.StringHashMap(DeclId),
    namespaces: std.StringHashMap(NamespaceTarget),
};

pub const NamespaceTarget = struct {
    alias: []const u8,
    importer_source: []const u8,
    environment: EnvironmentId,
    target_module_path: []const u8,
    own_decls: []const *Node,
    member_ids: []const DeclId,
    visibility: ast.Visibility = .public,
};

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
        .open_set_decl => |*d| .{ .open_set_decl = d },
        .runtime_class_decl => |*d| .{ .runtime_class_decl = d },
        .namespace_decl => |*d| .{ .namespace_decl = d },
        else => null,
    };
}

/// The taxonomy of a declaration, mirroring the `RawDeclRef` variants so a
/// `DeclTable` row carries its kind without re-switching on the AST node.
pub const DeclKind = enum {
    function,
    constant,
    global,
    @"struct",
    @"enum",
    @"union",
    @"error",
    protocol,
    open_set,
    runtime_class,
    namespace,
    scope,
    /// A name lowering mints with no authoring AST declaration.
    synthetic,
    ufcs_alias,
    other,
};

fn declKindOf(ref: RawDeclRef) DeclKind {
    return switch (ref) {
        .fn_decl => .function,
        .const_decl => .constant,
        .var_decl => .global,
        .struct_decl => .@"struct",
        .enum_decl => .@"enum",
        .union_decl => .@"union",
        .error_set_decl => .@"error",
        .protocol_decl => .protocol,
        .open_set_decl => .open_set,
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

/// The declaration a `const_decl` wrapper defines (`S :: struct { … }` wraps a
/// `struct_decl`), or null when the ref is not a wrapper. Wrapper and inner
/// author share one identity.
pub fn innerDeclRef(ref: RawDeclRef) ?RawDeclRef {
    if (ref != .const_decl) return null;
    return rawDeclRefOf(ref.const_decl.value);
}

fn memberName(node: *const Node) ?[]const u8 {
    return switch (node.data) {
        .library_decl => |decl| decl.name,
        .framework_decl => |decl| decl.name,
        else => node.data.declName(),
    };
}

pub const DeclId = enum(u32) { _ };

/// One `DeclTable` row: a `RawDeclRef` lifted to a stable `DeclId`, with its
/// authoring source path, display name, AST span, and `DeclKind`. `ref` is the
/// same raw author the import facts hold (its AST node identity is `id`'s key).
pub const DeclInfo = struct {
    id: DeclId,
    source: ?[]const u8,
    environment: ?EnvironmentId,
    lexical_block: ?LexicalBlockId = null,
    scope: ?ScopeId = null,
    node: ?*const Node = null,
    visibility: ast.Visibility = .public,
    name: []const u8,
    ref: ?RawDeclRef,
    span: ?ast.Span,
    kind: DeclKind,
};

/// Stable `DeclId` for every source / namespaced / imported / C-imported decl.
/// `entries` is indexed by `DeclId`; `by_node` reverse-maps every AST node
/// identity that names the declaration — the author (`authorNodePtrOf`) and,
/// for a `const_decl` wrapper, the declaration it wraps. Borrowed by
/// `ProgramIndex.decl_table`.
pub const DeclTable = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(DeclInfo) = .empty,
    by_node: std.AutoHashMap(usize, DeclId),
    environments: std.ArrayList(Environment) = .empty,
    files: std.StringHashMap(EnvironmentId),
    scoped_environments: std.HashMap(EnvironmentKey, EnvironmentId, EnvironmentKeyContext, std.hash_map.default_max_load_percentage),
    scopes: std.ArrayList(Scope) = .empty,
    scopes_by_path: std.HashMap([]const []const u8, ScopeId, ScopePathContext, std.hash_map.default_max_load_percentage),
    blocks: std.ArrayList(LexicalBlock) = .empty,
    written_targets: std.AutoHashMap(*const Node, WrittenTarget),
    spread_sources: std.AutoHashMap(*const Node, SpreadSource),
    // Namespace selections borrow member slices across expansion.
    member_slices: std.ArrayList([]const DeclId) = .empty,

    pub fn init(alloc: std.mem.Allocator) DeclTable {
        return .{
            .alloc = alloc,
            .by_node = std.AutoHashMap(usize, DeclId).init(alloc),
            .files = std.StringHashMap(EnvironmentId).init(alloc),
            .scoped_environments = .init(alloc),
            .scopes_by_path = .init(alloc),
            .written_targets = .init(alloc),
            .spread_sources = .init(alloc),
        };
    }

    pub fn deinit(self: *DeclTable) void {
        self.entries.deinit(self.alloc);
        self.by_node.deinit();
        for (self.environments.items) |*env| {
            self.alloc.free(env.source);
            for (env.scope_path) |part| self.alloc.free(part);
            self.alloc.free(env.scope_path);
            env.names.deinit();
            env.namespaces.deinit();
        }
        self.environments.deinit(self.alloc);
        var spellings = self.files.keyIterator();
        while (spellings.next()) |path| self.alloc.free(path.*);
        self.files.deinit();
        self.scoped_environments.deinit();
        for (self.scopes.items) |scope| {
            for (scope.path) |part| self.alloc.free(part);
            self.alloc.free(scope.path);
        }
        self.scopes.deinit(self.alloc);
        self.scopes_by_path.deinit();
        for (self.blocks.items) |*block_info| {
            block_info.imports.deinit(self.alloc);
            block_info.spreads.deinit(self.alloc);
        }
        self.blocks.deinit(self.alloc);
        self.written_targets.deinit();
        self.spread_sources.deinit();
        for (self.member_slices.items) |slice| self.alloc.free(slice);
        self.member_slices.deinit(self.alloc);
    }

    pub fn get(self: *const DeclTable, id: DeclId) DeclInfo {
        return self.entries.items[@intFromEnum(id)];
    }

    /// The `DeclId` for an AST node (by its `RawDeclRef` identity), or null when
    /// the node never entered the table.
    pub fn declIdForRef(self: *const DeclTable, ref: RawDeclRef) ?DeclId {
        return self.by_node.get(authorNodePtrOf(ref));
    }

    pub fn internRef(self: *DeclTable, source: ?[]const u8, name: []const u8, ref: RawDeclRef, span: ?ast.Span) !DeclId {
        const env = if (source) |path| try self.internEnvironment(path, &.{}) else null;
        return self.internRefInEnvironment(env, name, ref, span);
    }

    pub fn internRefInEnvironment(self: *DeclTable, env: ?EnvironmentId, name: []const u8, ref: RawDeclRef, span: ?ast.Span) !DeclId {
        const key = authorNodePtrOf(ref);
        if (self.by_node.get(key)) |existing| return existing;
        const inner = innerDeclRef(ref);
        if (inner) |ir| {
            if (self.declIdForRef(ir)) |existing| {
                try self.by_node.put(key, existing);
                return existing;
            }
        }
        const id: DeclId = @enumFromInt(@as(u32, @intCast(self.entries.items.len)));
        try self.entries.append(self.alloc, .{
            .id = id,
            .source = if (env) |id_env| self.environment(id_env).source else null,
            .environment = env,
            .name = name,
            .ref = ref,
            .span = span,
            .kind = declKindOf(inner orelse ref),
        });
        try self.by_node.put(key, id);
        if (inner) |ir| try self.by_node.put(authorNodePtrOf(ir), id);
        return id;
    }

    pub fn intern(self: *DeclTable, source: ?[]const u8, decl: *const Node) !DeclId {
        const env = if (decl.lexical_block) |b| self.block(b).environment else if (decl.source_file orelse source) |path| try self.internEnvironment(path, &.{}) else null;
        return self.internInEnvironment(env, decl);
    }

    pub fn internInEnvironment(self: *DeclTable, env: ?EnvironmentId, decl: *const Node) !DeclId {
        return self.internNamedNode(env, memberName(decl).?, decl);
    }

    pub fn internNamedNode(self: *DeclTable, env: ?EnvironmentId, name: []const u8, decl: *const Node) !DeclId {
        const id = if (rawDeclRefOf(decl)) |ref|
            try self.internRefInEnvironment(env, name, ref, decl.span)
        else blk: {
            const key = @intFromPtr(decl);
            if (self.by_node.get(key)) |existing| break :blk existing;
            const fresh = try self.syntheticInEnvironment(env, name);
            self.entries.items[@intFromEnum(fresh)].kind = switch (decl.data) {
                .ufcs_alias => .ufcs_alias,
                .scope_decl => .scope,
                .import_decl => .namespace,
                else => .other,
            };
            try self.by_node.put(key, fresh);
            break :blk fresh;
        };
        const info = &self.entries.items[@intFromEnum(id)];
        info.node = decl;
        info.visibility = decl.visibility;
        info.span = decl.span;
        info.lexical_block = decl.lexical_block;
        return id;
    }

    /// Mint an identity for a name lowering synthesizes — a fresh id every
    /// call, since no AST node addresses it.
    pub fn internSynthetic(self: *DeclTable, source: ?[]const u8, name: []const u8) !DeclId {
        const env = if (source) |path| try self.internEnvironment(path, &.{}) else null;
        return self.syntheticInEnvironment(env, name);
    }

    pub fn syntheticInEnvironment(self: *DeclTable, env: ?EnvironmentId, name: []const u8) !DeclId {
        const id: DeclId = @enumFromInt(@as(u32, @intCast(self.entries.items.len)));
        try self.entries.append(self.alloc, .{
            .id = id,
            .source = if (env) |id_env| self.environment(id_env).source else null,
            .environment = env,
            .name = name,
            .ref = null,
            .span = null,
            .kind = .synthetic,
        });
        return id;
    }

    pub fn environment(self: *const DeclTable, id: EnvironmentId) *Environment {
        return &self.environments.items[@intFromEnum(id)];
    }

    pub fn scopeInfo(self: *const DeclTable, id: ScopeId) Scope {
        return self.scopes.items[@intFromEnum(id)];
    }

    fn internScope(self: *DeclTable, path: []const []const u8) !ScopeId {
        if (self.scopes_by_path.get(path)) |id| return id;
        const parts = try self.alloc.alloc([]const u8, path.len);
        for (path, parts) |part, *copy| copy.* = try self.alloc.dupe(u8, part);
        const id: ScopeId = @enumFromInt(@as(u32, @intCast(self.scopes.items.len)));
        try self.scopes.append(self.alloc, .{ .path = parts });
        try self.scopes_by_path.put(parts, id);
        return id;
    }

    pub fn block(self: *const DeclTable, id: LexicalBlockId) *LexicalBlock {
        return &self.blocks.items[@intFromEnum(id)];
    }

    pub fn addBlock(self: *DeclTable, env: EnvironmentId, parent: ?LexicalBlockId, node: *const Node) !LexicalBlockId {
        const id: LexicalBlockId = @enumFromInt(@as(u32, @intCast(self.blocks.items.len)));
        try self.blocks.append(self.alloc, .{ .environment = env, .parent = parent, .node = node });
        return id;
    }

    pub fn addScopeBlock(self: *DeclTable, parent: LexicalBlockId, decl: *Node) !LexicalBlockId {
        const author_env = self.block(parent).environment;
        const path = try std.mem.concat(self.alloc, []const u8, &.{ self.environment(author_env).scope_path, &.{decl.data.scope_decl.name} });
        defer self.alloc.free(path);
        const scope_id = try self.internScope(path);
        const env = try self.internEnvironment(self.environment(author_env).source, path);
        self.environment(env).scope = scope_id;
        const id = try self.internInEnvironment(author_env, decl);
        self.entries.items[@intFromEnum(id)].scope = scope_id;
        const body_block = try self.addBlock(env, parent, decl);
        decl.data.scope_decl.body_block = body_block;
        return body_block;
    }

    pub fn prepareExpansion(self: *DeclTable, node: *Node, owner: LexicalBlockId) std.mem.Allocator.Error!void {
        ast.stampLexicalBlock(node, owner);
        node.source_file = self.environment(self.block(owner).environment).source;
        if (node.data == .const_decl) try self.recordWrittenTarget(owner, node);
        switch (node.data) {
            .spread_decl => try self.recordSpread(owner, node, .deferred),
            .scope_decl => |scope| {
                const child = try self.addScopeBlock(owner, node);
                for (scope.decls) |decl| try self.prepareExpansion(decl, child);
            },
            .block => |body| for (body.stmts) |stmt| try self.prepareExpansion(stmt, owner),
            .if_expr => |ie| {
                try self.prepareExpansion(ie.then_branch, owner);
                if (ie.else_branch) |other| try self.prepareExpansion(other, owner);
            },
            .match_expr => |me| for (me.arms) |arm| try self.prepareExpansion(arm.body, owner),
            .for_expr => |fe| try self.prepareExpansion(fe.body, owner),
            else => {},
        }
    }

    pub fn recordImport(self: *DeclTable, owner: LexicalBlockId, node: *const Node) !void {
        try self.block(owner).imports.append(self.alloc, node);
    }

    pub fn recordWrittenTarget(self: *DeclTable, owner: LexicalBlockId, node: *Node) !void {
        const operand = switch (node.data) {
            .const_decl => |decl| decl.value,
            .spread_decl => |spread| spread.source,
            else => return,
        };
        const source = self.environment(self.block(owner).environment).source;
        operand.source_file = source;
        try self.written_targets.put(node, .{ .source = source, .block = owner, .position = node.span.start, .operand = operand });
    }

    pub fn recordSpread(self: *DeclTable, owner: LexicalBlockId, node: *Node, publication: Publication) !void {
        try self.recordWrittenTarget(owner, node);
        const spread = node.data.spread_decl;
        const source: SpreadSource = switch (spread.source.data) {
            .import_decl => |imp| .{ .module = imp.path },
            .c_import_decl => blk: {
                const decls = spread.c_decls orelse break :blk .missing;
                const env = self.block(owner).environment;
                for (decls) |decl| {
                    ast.stampLexicalBlock(decl, owner);
                    decl.source_file = self.environment(env).source;
                }
                break :blk .{ .c_import = try self.memberIds(env, decls) };
            },
            else => .{ .path = spread.source },
        };
        try self.spread_sources.put(node, source);
        if (publication == .published) try self.block(owner).spreads.append(self.alloc, node);
    }

    pub fn fileEnvironment(self: *const DeclTable, path: []const u8) ?EnvironmentId {
        return self.files.get(path);
    }

    pub fn findEnvironment(self: *const DeclTable, source: []const u8, path: []const []const u8) ?EnvironmentId {
        const root = self.fileEnvironment(source) orelse return null;
        if (path.len == 0) return root;
        return self.scoped_environments.get(.{ .source = self.environment(root).source, .scope_path = path });
    }

    fn indexFile(self: *DeclTable, path: []const u8, id: EnvironmentId) !void {
        const owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned);
        const entry = try self.files.getOrPut(owned);
        if (entry.found_existing) {
            self.alloc.free(owned);
        } else entry.value_ptr.* = id;
    }

    pub fn internEnvironment(self: *DeclTable, path: []const u8, scope_path: []const []const u8) !EnvironmentId {
        const root = if (self.fileEnvironment(path)) |id| id else blk: {
            const canonical = try canonicalizePath(self.alloc, path);
            if (self.files.get(canonical)) |id| {
                self.alloc.free(canonical);
                try self.indexFile(path, id);
                break :blk id;
            }
            const id: EnvironmentId = @enumFromInt(@as(u32, @intCast(self.environments.items.len)));
            try self.environments.append(self.alloc, .{
                .source = canonical,
                .scope_path = &.{},
                .names = std.StringHashMap(DeclId).init(self.alloc),
                .namespaces = std.StringHashMap(NamespaceTarget).init(self.alloc),
            });
            try self.indexFile(canonical, id);
            try self.indexFile(path, id);
            break :blk id;
        };
        if (scope_path.len == 0) return root;
        const source = self.environment(root).source;
        if (self.scoped_environments.get(.{ .source = source, .scope_path = scope_path })) |id| return id;
        const parts = try self.alloc.alloc([]const u8, scope_path.len);
        for (scope_path, parts) |part, *copy| copy.* = try self.alloc.dupe(u8, part);
        const id: EnvironmentId = @enumFromInt(@as(u32, @intCast(self.environments.items.len)));
        try self.environments.append(self.alloc, .{
            .source = try self.alloc.dupe(u8, source),
            .scope_path = parts,
            .names = std.StringHashMap(DeclId).init(self.alloc),
            .namespaces = std.StringHashMap(NamespaceTarget).init(self.alloc),
        });
        const env = self.environment(id);
        try self.scoped_environments.put(.{ .source = env.source, .scope_path = env.scope_path }, id);
        return id;
    }

    pub fn directImports(self: *const DeclTable, graph: *const std.StringHashMap(std.StringHashMap(void)), env: EnvironmentId) ?std.StringHashMap(void) {
        return graph.get(self.environment(env).source);
    }

    pub fn fileScope(self: *const DeclTable, path: []const u8) ?*Environment {
        return self.environment(self.fileEnvironment(path) orelse return null);
    }

    pub fn claim(self: *DeclTable, env: EnvironmentId, decl: *const Node) std.mem.Allocator.Error!bool {
        return self.claimNamed(env, decl.data.declName() orelse return true, decl);
    }

    pub fn claimNamed(self: *DeclTable, env: EnvironmentId, name: []const u8, decl: *const Node) std.mem.Allocator.Error!bool {
        if (self.environment(env).names.get(name)) |previous| {
            if (decl.data != .scope_decl or self.get(previous).kind != .scope) return false;
            _ = try self.internNamedNode(env, name, decl);
            return true;
        }
        const id = try self.internNamedNode(env, name, decl);
        try self.environment(env).names.put(name, id);
        if (decl.data == .namespace_decl) try self.publishNamespace(env, decl);
        return true;
    }

    pub fn memberIds(self: *DeclTable, env: EnvironmentId, nodes: []const *Node) ![]const DeclId {
        var ids = std.ArrayList(DeclId).empty;
        for (nodes) |node| {
            if (memberName(node) == null) continue;
            const author_env = if (node.lexical_block) |b| self.block(b).environment else if (node.source_file) |path| try self.internEnvironment(path, &.{}) else env;
            const id = try self.internInEnvironment(author_env, node);
            try ids.append(self.alloc, id);
        }
        const members = try ids.toOwnedSlice(self.alloc);
        try self.member_slices.append(self.alloc, members);
        return members;
    }

    fn publishNamespace(self: *DeclTable, importer: EnvironmentId, decl: *const Node) !void {
        const ns = decl.data.namespace_decl;
        const target_env = if (self.fileEnvironment(ns.target_module_path) == self.fileEnvironment(self.environment(importer).source)) blk: {
            const path = try std.mem.concat(self.alloc, []const u8, &.{ self.environment(importer).scope_path, &.{ns.name} });
            defer self.alloc.free(path);
            break :blk try self.internEnvironment(ns.target_module_path, path);
        } else try self.internEnvironment(ns.target_module_path, &.{});
        if (self.environment(target_env).scope_path.len > 0) {
            const body_block = try self.addBlock(target_env, decl.lexical_block, decl);
            // C namespace lookup selects the first member of a name; every prototype retains its identity.
            for (ns.own_decls) |member| {
                if (rawDeclRefOf(member) == null) continue;
                ast.stampLexicalBlock(member, body_block);
                _ = try self.claim(target_env, member);
            }
        }
        const ids = try self.memberIds(target_env, ns.own_decls);
        try self.environment(importer).namespaces.put(ns.name, .{
            .alias = ns.name,
            .importer_source = self.environment(importer).source,
            .environment = target_env,
            .target_module_path = ns.target_module_path,
            .own_decls = ns.own_decls,
            .member_ids = ids,
            .visibility = decl.visibility,
        });
    }

    pub fn rawAuthor(self: *const DeclTable, env: EnvironmentId, name: []const u8) ?RawAuthor {
        const scope = self.environment(env);
        return self.author(scope.names.get(name) orelse return null, scope.source);
    }

    pub fn author(self: *const DeclTable, id: DeclId, source: []const u8) ?RawAuthor {
        const info = self.get(id);
        return .{ .id = id, .raw = info.ref orelse return null, .source = info.source orelse source, .visibility = info.visibility };
    }
};

fn reportDuplicateName(diagnostics: ?*errors.DiagnosticList, added: bool, name: []const u8, decl: *const Node) void {
    if (added) return;
    const diags = diagnostics orelse return;
    diags.addFmtInFile(.err, decl.source_file, decl.span, "duplicate top-level declaration '{s}'", .{name});
}

/// Build the diagnostic span for a failed import parse, from the parser's
/// ACTUAL error location INSIDE the imported file (`err_offset`/`err_end`) —
/// not the importing file's `@import` span. Pair with `addFmtInFile` so the
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
pub fn stampFnBodySource(decl: *Node, file_path: []const u8) void {
    switch (decl.data) {
        .fn_decl => |fd| fd.body.source_file = file_path,
        .struct_decl => |sd| stampStructMethodSources(sd, file_path),
        // A parameterized protocol is instantiated cross-module; record its
        // defining path so the instantiation resolves method-signature types in
        // this module.
        .protocol_decl => |pd| {
            decl.data.protocol_decl.source_file = file_path;
            stampProtocolMethodSources(pd, file_path);
        },
        // An sx-defined `@ObjcClass` / `@JniClass`: its IMP trampolines are
        // emitted at lowering time (possibly from another module's context), so
        // record the defining path AND stamp each method body.
        .runtime_class_decl => {
            decl.data.runtime_class_decl.source_file = file_path;
            stampRuntimeClassMethodSources(decl.data.runtime_class_decl, file_path);
        },
        // An `impl P for T { ... }`: its methods are registered into
        // `fn_ast_map` and their declared param/return types may name a type
        // bare-visible only in this module. Stamp each method body's source so a
        // cross-module conformance check (erasure to an imported protocol) pins
        // the impl-side type resolution to the impl's OWN module,
        // not the erasure site.
        .impl_block => |ib| stampImplMethodSources(ib, file_path),
        .const_decl => |cd| switch (cd.value.data) {
            .fn_decl => |fd| fd.body.source_file = file_path,
            // `List :: struct { … append :: (…) { … } }` — the methods of a
            // (possibly generic) struct are monomorphized in their template's
            // OWN module (the instantiation source-pin), so their
            // bodies need the defining path stamped just like a top-level fn.
            .struct_decl => |sd| stampStructMethodSources(sd, file_path),
            .protocol_decl => |pd| {
                cd.value.data.protocol_decl.source_file = file_path;
                stampProtocolMethodSources(pd, file_path);
            },
            .runtime_class_decl => {
                cd.value.data.runtime_class_decl.source_file = file_path;
                stampRuntimeClassMethodSources(cd.value.data.runtime_class_decl, file_path);
            },
            else => {},
        },
        else => {},
    }
}

/// A default method body is written in the protocol's module and reused by
/// every conformer's synthesized method, so it carries the protocol's path.
fn stampProtocolMethodSources(pd: ast.ProtocolDecl, file_path: []const u8) void {
    for (pd.methods) |m| {
        if (m.default_body) |body| body.source_file = file_path;
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
/// method's declared param/return types in the impl's OWN module.
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
    reportDuplicateName(diagnostics, added, name, decl);
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
) !ResolvedModule {
    const env = try cache.declarations.internEnvironment(file_path, &.{});
    const canonical_file = cache.declarations.environment(env).source;
    // Record this file's edge set so `param_impl_map` lookups can filter
    // candidates by what's been imported from where. Populated as each
    // import resolves below; transitive closure computed on demand.
    if (import_graph) |g| {
        if (!g.contains(canonical_file)) {
            try g.put(canonical_file, std.StringHashMap(void).init(allocator));
        }
    }
    // FLAT-only edge set: identical to `import_graph` but records ONLY bare
    // `@import "…"` edges (`imp.name == null`), never a namespaced
    // `ns :: @import "…"`. The bare-name disambiguation walks this to
    // decide which same-name authors a flat importer can actually reach.
    if (flat_import_graph) |g| {
        if (!g.contains(canonical_file)) {
            try g.put(canonical_file, std.StringHashMap(void).init(allocator));
        }
    }
    try chain.put(canonical_file, {});
    defer _ = chain.remove(canonical_file);
    const block_id = try cache.declarations.addBlock(env, null, root);
    root.lexical_block = block_id;
    if (root.data != .root) return .{ .path = file_path, .decls = &.{}, .own_decls = &.{}, .environment = env };
    for (root.data.root.decls) |decl| try cache.declarations.prepareExpansion(decl, block_id);
    return resolveBlockImports(allocator, io, &root.data.root.decls, block_id, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
}

fn resolveBlockImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    nodes: *[]const *Node,
    block_id: LexicalBlockId,
    base_dir: []const u8,
    file_path: []const u8,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
) anyerror!ResolvedModule {
    const env = cache.declarations.block(block_id).environment;
    const canonical_file = cache.declarations.environment(env).source;
    var mod = ResolvedModule{ .path = file_path, .decls = &.{}, .own_decls = &.{}, .environment = env };
    nodes.* = try expandDirectoryImports(allocator, io, nodes.*, base_dir, file_path, null, stdlib_paths, diagnostics);
    for (nodes.*) |decl| if (decl.data == .spread_decl) {
        try cache.declarations.recordSpread(block_id, decl, .published);
    };

    var decl_list = std.ArrayList(*Node).empty;
    var own_decl_list = std.ArrayList(*Node).empty;
    var seen_in_list = std.StringHashMap(void).init(allocator);
    // Node-identity set for the same purpose, covering anonymous decls
    // (impl blocks) that carry no name to dedupe on.
    var seen_nodes = std.AutoHashMap(*Node, void).init(allocator);

    for (nodes.*) |decl| {
        ast.stampLexicalBlock(decl, block_id);
        decl.source_file = canonical_file;
        try cache.declarations.recordWrittenTarget(block_id, decl);
        if (decl.data == .spread_decl) {
            try resolveSpreadSource(allocator, io, decl, base_dir, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
            try cache.declarations.recordSpread(block_id, decl, .deferred);
            if (decl.data.spread_decl.source.data == .import_decl) {
                const path = decl.data.spread_decl.source.data.import_decl.path;
                if (cache.modules.get(path)) |imported_mod| try mod.mergeFlat(allocator, &decl_list, &seen_in_list, &seen_nodes, imported_mod);
                if (import_graph) |graph| if (graph.getPtr(canonical_file)) |edges| try edges.put(path, {});
            }
            try decl_list.append(allocator, decl);
            continue;
        }
        if (decl.data == .scope_decl) {
            decl.source_file = file_path;
            const added = try mod.addOwnDecl(allocator, &cache.declarations, &decl_list, &own_decl_list, &seen_in_list, decl);
            reportDuplicateDecl(diagnostics, added, decl);
            if (added) {
                const child = decl.data.scope_decl.body_block.?;
                const body = try resolveBlockImports(allocator, io, &decl.data.scope_decl.decls, child, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
                decl.data.scope_decl.decls = body.decls;
            }
            continue;
        }
        if (isModuleDriver(decl)) {
            // A module-scope `inline if` / comptime `match` / `inline for` is
            // OPAQUE here: its groups stay inside the node until lowering
            // evaluates the driver and splices the taken one. Only the
            // `@import`s inside its bodies resolve now, re-entrantly and
            // CONTAINED — the windows and posix `std.fs` backends both load,
            // and neither reaches module scope until its branch is selected.
            try resolveBranchImports(allocator, io, decl, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
            decl.source_file = file_path;
            reportDuplicateDecl(diagnostics, try mod.addOwnDecl(allocator, &cache.declarations, &decl_list, &own_decl_list, &seen_in_list, decl), decl);
            continue;
        }
        if (decl.data == .c_import_decl) {
            const result = try processCImport(allocator, io, decl, base_dir, null, stdlib_paths, diagnostics);
            const ci = decl.data.c_import_decl;

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
                ns_node.lexical_block = block_id;
                // A `private ns :: @import c { … }` namespace stays file-local.
                ns_node.visibility = decl.visibility;
                reportDuplicateName(diagnostics, try mod.addOwnDecl(allocator, &cache.declarations, &decl_list, &own_decl_list, &seen_in_list, ns_node), ns_name, decl);
            } else {
                // Flat: add fn_decls directly + keep c_import_decl
                for (result.fn_decls) |fd| {
                    fd.source_file = file_path;
                    ast.stampLexicalBlock(fd, block_id);
                    reportDuplicateDecl(diagnostics, try mod.addOwnDecl(allocator, &cache.declarations, &decl_list, &own_decl_list, &seen_in_list, fd), fd);
                }
                decl.source_file = file_path;
                reportDuplicateDecl(diagnostics, try mod.addOwnDecl(allocator, &cache.declarations, &decl_list, &own_decl_list, &seen_in_list, decl), decl);
            }
            continue;
        }
        if (decl.data != .import_decl) {
            decl.source_file = file_path;
            stampFnBodySource(decl, file_path);
            reportDuplicateDecl(diagnostics, try mod.addOwnDecl(allocator, &cache.declarations, &decl_list, &own_decl_list, &seen_in_list, decl), decl);
            continue;
        }
        try cache.declarations.recordImport(block_id, decl);
        const imp = decl.data.import_decl;

        const resolved_path = imp.path;

        // Record direct-import edge file_path → resolved_path. Self-imports
        // and chain duplicates are still recorded so the graph reflects what
        // the user wrote (filter happens at lookup).
        if (import_graph) |g| {
            if (g.getPtr(canonical_file)) |set| {
                set.put(resolved_path, {}) catch {};
            }
        }
        if (imp.name == null and cache.declarations.block(block_id).parent == null) {
            if (flat_import_graph) |g| {
                if (g.getPtr(canonical_file)) |set| {
                    set.put(resolved_path, {}) catch {};
                }
            }
        }

        const imported_mod = (try loadImport(allocator, io, resolved_path, decl, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph)) orelse continue;

        if (imp.name) |ns_name| {
            const added = try mod.addNamespace(allocator, &cache.declarations, &decl_list, &own_decl_list, &seen_in_list, ns_name, imported_mod, decl.span, imp.is_raw, decl.visibility, block_id);
            reportDuplicateName(diagnostics, added, ns_name, decl);
        } else {
            try mod.mergeFlat(allocator, &decl_list, &seen_in_list, &seen_nodes, imported_mod);
        }
    }

    try mod.finalize(allocator, &decl_list, &own_decl_list);
    return mod;
}

pub fn processCImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    node: *Node,
    base_dir: []const u8,
    root_path: ?[]const u8,
    stdlib_paths: []const []const u8,
    diagnostics: ?*errors.DiagnosticList,
) !c_import.CImportResult {
    const operand = if (node.data == .spread_decl) node.data.spread_decl.source else node;
    const ci = &operand.data.c_import_decl;
    for ([_]*[]const []const u8{ &ci.includes, &ci.sources }) |paths| {
        const resolved = try allocator.alloc([]const u8, paths.*.len);
        for (paths.*, resolved) |path, *out| out.* = try resolveImportPath(allocator, io, base_dir, path, root_path, stdlib_paths);
        paths.* = resolved;
    }
    return switch (try c_import.processCImport(allocator, ci.includes, ci.defines, ci.flags)) {
        .success => |result| result,
        .failure => |failure| {
            if (diagnostics) |diags| {
                diags.addFmtInFile(.err, node.source_file, node.span, "@import c failed: cannot parse '{s}': {s}", .{ failure.header, failure.message });
            }
            return error.ImportError;
        },
    };
}

fn resolveSpreadSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    node: *Node,
    base_dir: []const u8,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
) !void {
    const operand = node.data.spread_decl.source;
    switch (operand.data) {
        .import_decl => |imp| {
            _ = try loadImport(allocator, io, imp.path, node, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
        },
        .c_import_decl => {
            const result = try processCImport(allocator, io, node, base_dir, null, stdlib_paths, diagnostics);
            node.data.spread_decl.c_decls = result.fn_decls;
        },
        else => {},
    }
}

fn loadImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved_path: []const u8,
    decl: *const Node,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
) anyerror!?ResolvedModule {
    if (chain.contains(resolved_path)) return null;
    if (cache.modules.get(resolved_path)) |cached| return cached;

    if (try loadFileModule(allocator, io, resolved_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph)) |result| return result;
    if (diagnostics) |diags| diags.addFmt(.err, decl.span, "cannot read import '{s}' (not a file or directory)", .{resolved_path});
    return error.ImportError;
}

/// Parse and resolve the module file at `resolved_path` and cache it. Null when
/// the path is not a readable file.
fn loadFileModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved_path: []const u8,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
) anyerror!?ResolvedModule {
    const imp_bytes = std.Io.Dir.readFileAlloc(.cwd(), io, resolved_path, allocator, .limited(10 * 1024 * 1024)) catch return null;
    const imp_source = try allocator.dupeZ(u8, imp_bytes);

    if (source_map) |sm| {
        sm.put(resolved_path, imp_source) catch {};
    }

    var p = try parser.Parser.init(allocator, imp_source);
    const imp_root = p.parse() catch {
        if (diagnostics) |diags| {
            diags.addFmtInFile(.err, resolved_path, importErrSpan(&p), "parse error in '{s}': {s}", .{ resolved_path, p.err_msg orelse "unknown" });
        }
        return error.ImportError;
    };

    const imp_dir = dirName(resolved_path);
    const result = try resolveImports(allocator, io, imp_root, imp_dir, resolved_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);

    try cache.modules.put(resolved_path, result);
    return result;
}

/// The module the `@` contracts and the runtime bindings are declared in.
pub const core_module = "modules/std/core.sx";

/// Put `core_module` into the program behind `mod` when no import brought it,
/// ahead of the program's own declarations as an `@import` on the first line
/// would. The `@` names and the runtime bindings resolve program-wide, so
/// every program carries their declaring module; no import edge is recorded,
/// so its other names stay out of bare lookup.
pub fn loadCoreModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    mod: *ResolvedModule,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
) !void {
    const path = resolveImportPath(allocator, io, dirName(mod.path), core_module, null, stdlib_paths) catch return;
    if (cache.modules.contains(path) or sameFileIdentity(allocator, path, mod.path)) return;
    const core = (try loadFileModule(allocator, io, path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph)) orelse return;

    var list = std.ArrayList(*Node).empty;
    var seen_in_list = std.StringHashMap(void).init(allocator);
    var seen_nodes = std.AutoHashMap(*Node, void).init(allocator);
    try mod.mergeFlat(allocator, &list, &seen_in_list, &seen_nodes, core);
    for (mod.decls) |decl| {
        if (seen_nodes.contains(decl)) continue;
        try seen_nodes.put(decl, {});
        try list.append(allocator, decl);
    }
    mod.decls = try list.toOwnedSlice(allocator);
}

/// A module-scope declaration-expansion driver: `inline if`, `inline match`,
/// or `inline for`. Lowering owns their evaluation — here they are opaque
/// containers whose bodies keep their declarations until a branch is selected.
pub fn isModuleDriver(decl: *const Node) bool {
    return switch (decl.data) {
        .if_expr => |ie| ie.is_comptime,
        .match_expr => |me| me.is_comptime,
        .for_expr => |fe| fe.is_inline,
        else => false,
    };
}

/// Resolve every `@import` inside a module-scope driver's bodies, in every
/// branch — the taken one is not known until lowering. Each import's module is
/// parsed and cached under its canonical path, and the `@import` node's own
/// path is rewritten to that path so the splice can read the module back out
/// of the cache. Nothing is merged and no edge is recorded: containment is the
/// point — two backends authoring the same name (`std.fs`'s windows / posix
/// `fsFileIsValid`) never meet in module scope.
fn resolveBranchImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    decl: *Node,
    base_dir: []const u8,
    file_path: []const u8,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
) anyerror!void {
    switch (decl.data) {
        .if_expr => |ie| {
            try resolveBranchBodyImports(allocator, io, ie.then_branch, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
            if (ie.else_branch) |eb| try resolveBranchBodyImports(allocator, io, eb, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
        },
        .match_expr => |me| {
            for (me.arms) |arm| {
                try resolveBranchBodyImports(allocator, io, arm.body, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
            }
        },
        .for_expr => |fe| {
            try resolveBranchBodyImports(allocator, io, fe.body, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
        },
        else => {},
    }
}

fn resolveBranchBodyImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    body: *Node,
    base_dir: []const u8,
    file_path: []const u8,
    chain: *std.StringHashMap(void),
    cache: *ModuleCache,
    source_map: ?*std.StringHashMap([:0]const u8),
    diagnostics: ?*errors.DiagnosticList,
    stdlib_paths: []const []const u8,
    import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
    flat_import_graph: ?*std.StringHashMap(std.StringHashMap(void)),
) anyerror!void {
    const original: []const *Node = if (body.data == .block) body.data.block.stmts else &[_]*Node{body};
    const stmts = try expandDirectoryImports(allocator, io, original, base_dir, file_path, null, stdlib_paths, diagnostics);
    if (body.data == .block) {
        body.data.block.stmts = stmts;
    } else if (body.data == .import_decl or (body.data == .spread_decl and body.data.spread_decl.source.data == .import_decl)) {
        body.data = .{ .block = .{ .stmts = stmts } };
    }
    for (stmts) |stmt| if (stmt.data == .spread_decl) {
        try cache.declarations.recordSpread(body.lexical_block.?, stmt, .deferred);
    };
    for (stmts) |stmt| {
        ast.stampLexicalBlock(stmt, body.lexical_block.?);
        stmt.source_file = file_path;
        try cache.declarations.recordWrittenTarget(body.lexical_block.?, stmt);
        if (stmt.data == .spread_decl) {
            try resolveSpreadSource(allocator, io, stmt, base_dir, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
            try cache.declarations.recordSpread(body.lexical_block.?, stmt, .deferred);
            continue;
        }
        if (stmt.data == .scope_decl) {
            const child = stmt.data.scope_decl.body_block.?;
            var scope_body = Node{ .span = stmt.span, .lexical_block = child, .data = .{ .block = .{ .stmts = stmt.data.scope_decl.decls } } };
            try resolveBranchBodyImports(allocator, io, &scope_body, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
            stmt.data.scope_decl.decls = scope_body.data.block.stmts;
            continue;
        }
        if (isModuleDriver(stmt)) {
            try resolveBranchImports(allocator, io, stmt, base_dir, file_path, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
            continue;
        }
        if (stmt.data != .import_decl) continue;
        const resolved_path = stmt.data.import_decl.path;
        _ = try loadImport(allocator, io, resolved_path, stmt, chain, cache, source_map, diagnostics, stdlib_paths, import_graph, flat_import_graph);
    }
}

pub fn expandDirectoryImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    nodes: []const *Node,
    base_dir: []const u8,
    file_path: []const u8,
    root_path: ?[]const u8,
    stdlib_paths: []const []const u8,
    diagnostics: ?*errors.DiagnosticList,
) ![]const *Node {
    var expanded = std.ArrayList(*Node).empty;
    for (nodes) |node| {
        const operand = if (node.data == .spread_decl) node.data.spread_decl.source else node;
        if (operand.data != .import_decl) {
            try expanded.append(allocator, node);
            continue;
        }
        const resolved = try resolveImportPath(allocator, io, base_dir, operand.data.import_decl.path, root_path, stdlib_paths);
        const paths = try importFiles(allocator, io, resolved, file_path, operand, diagnostics);
        for (paths) |path| {
            const imported = try allocator.create(Node);
            imported.* = operand.*;
            imported.data.import_decl.path = path;
            if (node.data == .spread_decl) {
                const spread = try allocator.create(Node);
                spread.* = node.*;
                spread.data.spread_decl.source = imported;
                try expanded.append(allocator, spread);
            } else try expanded.append(allocator, imported);
        }
    }
    return expanded.toOwnedSlice(allocator);
}

fn importFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file_path: []const u8,
    node: *const Node,
    diagnostics: ?*errors.DiagnosticList,
) ![]const []const u8 {
    const dir = std.Io.Dir.openDir(.cwd(), io, path, .{ .iterate = true }) catch {
        const files = try allocator.alloc([]const u8, 1);
        files[0] = path;
        return files;
    };
    defer dir.close(io);
    const sibling = try std.fmt.allocPrint(allocator, "{s}.sx", .{path});
    const importer = try canonicalizePath(allocator, file_path);
    if (!std.mem.eql(u8, sibling, importer)) {
        if (std.Io.Dir.readFileAlloc(.cwd(), io, sibling, allocator, .limited(10 * 1024 * 1024))) |_| {
            if (diagnostics) |diags| {
                const spelling = node.data.import_decl.path;
                diags.addFmt(.err, node.span, "ambiguous import '{s}': both a file '{s}.sx' and a directory '{s}' exist — write \"{s}.sx\" to import the file", .{ spelling, spelling, spelling, spelling });
            }
            return error.ImportError;
        } else |_| {}
    }
    var paths = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sx")) continue;
        const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        try paths.append(allocator, try canonicalizePath(allocator, joined));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return paths.toOwnedSlice(allocator);
}
