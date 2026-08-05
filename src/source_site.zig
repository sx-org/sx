//! Source-site identity: the `(file, declaration, ordinal, id)` a
//! `@SourceSite` carries, computed over the SOURCE AST.
//!
//! The pass runs on module declarations, not on lowered IR, and that is what
//! makes the design's stability rules structural rather than maintained:
//!
//!   - A generic specialization shares the template's AST nodes, so it reads
//!     the TEMPLATE's declaration path and ordinals. Instantiation order
//!     cannot be observed here because instantiation is not part of the walk.
//!   - Optimization level and repeated runs likewise cannot be observed: the
//!     inputs are the parsed declaration and nothing else.
//!   - A module the import DAG shares is indexed once, against its own file,
//!     so which import path reached it is not observable either.
//!   - A runtime loop reuses one lexical site — the loop body is walked once.
//!   - Numbering restarts at each named declaration, so editing one
//!     declaration cannot renumber another.
//!
//! `id` follows `modules/std/source_site.sx` exactly: FNV-1a over the
//! length-prefixed version string, file, and declaration, then the ordinal as
//! eight little-endian bytes. The state after the three strings is cached per
//! declaration, so a site costs one 8-byte fold (§17.2) and no source string
//! is ever hashed at runtime.

const std = @import("std");
const ast = @import("ast.zig");

const Node = ast.Node;

pub const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
pub const FNV_PRIME: u64 = 0x100000001b3;
pub const VERSION = "sx.source-site.v1";

/// The stdlib contract this pass describes.
pub const contract_name = "@SourceSite";

/// The version string's own domain separation, folded once.
pub const Hasher = struct {
    state: u64 = FNV_OFFSET_BASIS,

    pub fn writeByte(self: *Hasher, value: u8) void {
        self.state = (self.state ^ @as(u64, value)) *% FNV_PRIME;
    }

    pub fn writeU64Le(self: *Hasher, value: u64) void {
        var i: u6 = 0;
        while (true) : (i += 1) {
            self.writeByte(@truncate(value >> (@as(u6, i) * 8)));
            if (i == 7) break;
        }
    }

    /// Length-prefixed, so `("ab", "c")` and `("a", "bc")` cannot collide.
    pub fn writeString(self: *Hasher, value: []const u8) void {
        self.writeU64Le(value.len);
        for (value) |b| self.writeByte(b);
    }
};

/// A site's ordinal before it is folded to `u64`: the zero-based pre-order
/// index of the site within its declaration, then one index per enclosing
/// `inline` expansion, outermost first.
pub const OrdinalPath = struct {
    lexical: u32,
    expansions: []const u32 = &.{},
};

/// THE ORDINAL FOLD.
///
/// A path with no expansions folds to its lexical index unchanged, so an
/// ordinary site's `ordinal` IS the zero-based lexical occurrence the field
/// documents. A path with expansions folds to a 63-bit FNV-1a digest of the
/// whole path with the top bit SET.
///
/// The top bit is therefore a tag, and the two spaces are disjoint by
/// construction: an expanded site can never take an un-expanded site's
/// ordinal, whatever the digest comes out as. Equal paths always fold equal —
/// the fold reads the path and nothing else — and a lexical index cannot
/// reach the tag bit (it counts sites in one declaration, bounded by u32).
pub fn foldOrdinal(path: OrdinalPath) u64 {
    if (path.expansions.len == 0) return path.lexical;
    var h = Hasher{};
    h.writeU64Le(path.lexical);
    for (path.expansions) |e| h.writeU64Le(e);
    return (h.state >> 1) | (@as(u64, 1) << 63);
}

/// The FNV state after the version string, `file`, and `declaration` — every
/// site in one declaration shares it (§17.2).
pub fn declarationPrefix(file: []const u8, declaration: []const u8) u64 {
    var h = Hasher{};
    h.writeString(VERSION);
    h.writeString(file);
    h.writeString(declaration);
    return h.state;
}

/// `source_site_key_id(source_site_key(site))`, resumed from a cached prefix.
pub fn idFromPrefix(prefix: u64, ordinal: u64) u64 {
    var h = Hasher{ .state = prefix };
    h.writeU64Le(ordinal);
    return h.state;
}

pub fn computeId(file: []const u8, declaration: []const u8, ordinal: u64) u64 {
    return idFromPrefix(declarationPrefix(file, declaration), ordinal);
}

/// The module path a site reports, which must not depend on how the compiler
/// was invoked (§4.2). Two rules, in order:
///
///  1. A library module resolves under one of the roots the compiler searched,
///     so stripping that root yields the import path (`modules/std/core.sx`)
///     whether the library sits in a dev tree or an install prefix.
///  2. Everything else is relative to the compilation root — the main file's
///     directory — so the same source names one path whatever directory `sx`
///     ran from and whether the entry was spelled relatively or absolutely.
///
/// Both inputs must already have been through `imports.canonicalizePath`: the
/// roots are built with `..` hops and the files are lexically normalized and
/// cwd-relativized, so comparing raw spellings matches nothing.
pub fn normalizeModulePath(
    file: []const u8,
    stdlib_roots: []const []const u8,
    main_dir: ?[]const u8,
) []const u8 {
    for (stdlib_roots) |root| {
        if (stripDirPrefix(file, root)) |rel| return rel;
    }
    if (main_dir) |dir| {
        if (stripDirPrefix(file, dir)) |rel| return rel;
    }
    return file;
}

fn stripDirPrefix(file: []const u8, dir: []const u8) ?[]const u8 {
    var end = dir.len;
    while (end > 0 and dir[end - 1] == '/') end -= 1;
    const trimmed = dir[0..end];
    if (trimmed.len == 0) return null;
    if (!std.mem.startsWith(u8, file, trimmed)) return null;
    if (file.len <= trimmed.len or file[trimmed.len] != '/') return null;
    return file[trimmed.len + 1 ..];
}

/// The `declaration` prefix a module contributes: its import path with the
/// extension dropped and separators as dots, so a site's declaration path
/// reads as one dotted name.
pub fn modulePrefix(alloc: std.mem.Allocator, module_path: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, module_path, ".sx"))
        module_path[0 .. module_path.len - ".sx".len]
    else
        module_path;
    const out = try alloc.dupe(u8, stem);
    for (out) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return out;
}

/// One indexed site.
pub const Site = struct {
    file: []const u8,
    declaration: []const u8,
    ordinal: u64,
    id: u64,
};

/// Sites, keyed by the AST node that IS the site.
///
/// EVERY node the walk reaches inside a named declaration is indexed, in
/// pre-order, so any node a consumer can point at is a site: a call (what
/// `@caller` substitutes at) and a reached expression in a build block alike.
/// Restricting the set to one node kind would make the numbering depend on
/// which consumers exist.
pub const SiteIndex = struct {
    alloc: std.mem.Allocator,
    sites: std.AutoHashMapUnmanaged(*const Node, Site) = .empty,
    /// One entry per named declaration that contained at least one site.
    prefixes: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn deinit(self: *SiteIndex) void {
        self.sites.deinit(self.alloc);
        self.prefixes.deinit(self.alloc);
    }

    pub fn get(self: *const SiteIndex, node: *const Node) ?Site {
        return self.sites.get(node);
    }

    /// The cached prefix for a declaration, for extending a site's ordinal
    /// under an `inline` expansion without re-hashing the source strings.
    pub fn prefixFor(self: *const SiteIndex, declaration: []const u8) ?u64 {
        return self.prefixes.get(declaration);
    }

    pub fn count(self: *const SiteIndex) usize {
        return self.sites.count();
    }
};

pub const Options = struct {
    /// Library roots import resolution searched, canonicalized.
    stdlib_roots: []const []const u8 = &.{},
    /// The compilation root: the main file's directory, canonicalized.
    main_dir: ?[]const u8 = null,
    /// Module path for declarations the parser left unstamped (the main file).
    main_file: ?[]const u8 = null,
};

const Builder = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    index: *SiteIndex,
    /// Module-scope declarations already indexed. Shared by every builder in
    /// one `build`.
    seen: *std.AutoHashMapUnmanaged(*const Node, void),
    /// The next module-scope ordinal of each module, keyed by module path and
    /// shared by every builder in one `build`. A module's top-level scope is
    /// entered once per top-level declaration, so the count that spans them
    /// has to outlive the builders that consume it.
    module_ordinals: *std.StringHashMapUnmanaged(u32),
    file: []const u8 = "",
    declaration: []const u8 = "",
    prefix: u64 = 0,
    next_ordinal: u32 = 0,
    /// Sites number in `file`'s module scope rather than in `next_ordinal`.
    module_scope: bool = false,

    /// Enter a named declaration: numbering restarts and the prefix is folded
    /// once for every site the declaration holds.
    fn enter(self: *Builder, segment: []const u8) !Builder {
        const qualified = if (self.declaration.len == 0)
            try self.alloc.dupe(u8, segment)
        else
            try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ self.declaration, segment });
        return .{
            .alloc = self.alloc,
            .opts = self.opts,
            .index = self.index,
            .seen = self.seen,
            .module_ordinals = self.module_ordinals,
            .file = self.file,
            .declaration = qualified,
            .prefix = declarationPrefix(self.file, qualified),
            .next_ordinal = 0,
        };
    }

    /// The module counter is looked up per site: walking one site's children
    /// can reach a module the map does not hold yet, and that insertion
    /// invalidates a value pointer held across it.
    fn nextLexical(self: *Builder) !u32 {
        if (!self.module_scope) {
            defer self.next_ordinal += 1;
            return self.next_ordinal;
        }
        const entry = try self.module_ordinals.getOrPut(self.alloc, self.file);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        defer entry.value_ptr.* += 1;
        return entry.value_ptr.*;
    }

    fn record(self: *Builder, node: *const Node) !void {
        const ordinal = foldOrdinal(.{ .lexical = try self.nextLexical() });
        try self.index.sites.put(self.alloc, node, .{
            .file = self.file,
            .declaration = self.declaration,
            .ordinal = ordinal,
            .id = idFromPrefix(self.prefix, ordinal),
        });
        try self.index.prefixes.put(self.alloc, self.declaration, self.prefix);
    }
};

/// Index every site in `decls`. Declarations are walked in source order and
/// each named declaration numbers its own sites from zero.
pub fn build(alloc: std.mem.Allocator, decls: []const *const Node, opts: Options) !SiteIndex {
    var index = SiteIndex{ .alloc = alloc };
    var seen: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
    defer seen.deinit(alloc);
    var module_ordinals: std.StringHashMapUnmanaged(u32) = .empty;
    defer module_ordinals.deinit(alloc);
    var root = Builder{
        .alloc = alloc,
        .opts = opts,
        .index = &index,
        .seen = &seen,
        .module_ordinals = &module_ordinals,
    };
    for (decls) |decl| try walkModuleDecl(&root, decl);
    return index;
}

/// A declaration at MODULE scope: its file and root declaration path are read
/// off the declaration itself, so the same declaration indexes identically
/// whichever import path reaches it, and reaching it again is a no-op.
///
/// The no-op is what bounds the pass. A namespace carries its target's whole
/// transitive decl list, so a module the import DAG shares sits at the end of
/// one path per route through the graph — a count that grows with the graph,
/// not with the source.
fn walkModuleDecl(b: *Builder, node: *const Node) anyerror!void {
    if ((try b.seen.getOrPut(b.alloc, node)).found_existing) return;
    const raw_file = node.source_file orelse b.opts.main_file orelse "";
    const module_path = normalizeModulePath(raw_file, b.opts.stdlib_roots, b.opts.main_dir);
    const declaration = try modulePrefix(b.alloc, module_path);
    var module = Builder{
        .alloc = b.alloc,
        .opts = b.opts,
        .index = b.index,
        .seen = b.seen,
        .module_ordinals = b.module_ordinals,
        .file = module_path,
        .declaration = declaration,
        .prefix = declarationPrefix(module_path, declaration),
        .module_scope = true,
    };
    try walkDecl(&module, node);
}

/// A module-scope (or member) declaration. A declaration that BINDS A NAME
/// opens a new numbering scope; anything else keeps the caller's.
fn walkDecl(b: *Builder, node: *const Node) anyerror!void {
    switch (node.data) {
        .fn_decl => |fd| {
            var inner = try b.enter(fd.name);
            for (fd.params) |p| {
                try walk(&inner, p.type_expr);
                if (p.default_expr) |d| try walk(&inner, d);
            }
            if (fd.return_type) |rt| try walk(&inner, rt);
            try walk(&inner, fd.body);
        },
        .struct_decl => |sd| {
            var inner = try b.enter(sd.name);
            for (sd.field_defaults) |d| if (d) |dd| try walk(&inner, dd);
            for (sd.methods) |m| try walkDecl(&inner, m);
            for (sd.constants) |c| try walkDecl(&inner, c);
        },
        .protocol_decl => |pd| {
            var inner = try b.enter(pd.name);
            for (pd.methods) |m| if (m.default_body) |body| {
                var method = try inner.enter(m.name);
                try walk(&method, body);
            };
        },
        // An open set declares required methods the same way a protocol does.
        .open_set_decl => |sd| {
            var inner = try b.enter(sd.name);
            for (sd.methods) |m| if (m.default_body) |body| {
                var method = try inner.enter(m.name);
                try walk(&method, body);
            };
        },
        .impl_block => |ib| {
            // An impl's methods hang off the impl's STRUCTURAL identity —
            // protocol name + its type arguments + the structural target —
            // so two impl blocks never share a path. `ib.target_type` alone
            // is a display string ("" for non-identifier targets) and would
            // conflate `impl Into(Alpha) for i64` with
            // `impl Into(Beta) for i64`.
            var seg = std.ArrayList(u8).empty;
            try seg.appendSlice(b.alloc, ib.protocol_name);
            if (ib.protocol_type_args.len > 0) {
                try seg.append(b.alloc, '(');
                for (ib.protocol_type_args, 0..) |arg, i| {
                    if (i > 0) try seg.append(b.alloc, ',');
                    try seg.appendSlice(b.alloc, try spellType(b.alloc, arg));
                }
                try seg.append(b.alloc, ')');
            }
            try seg.append(b.alloc, '#');
            if (ib.target_type_expr) |te| {
                try seg.appendSlice(b.alloc, try spellType(b.alloc, te));
            } else {
                try seg.appendSlice(b.alloc, ib.target_type);
                if (ib.target_type_params.len > 0) {
                    try seg.append(b.alloc, '(');
                    for (ib.target_type_params, 0..) |tp, i| {
                        if (i > 0) try seg.append(b.alloc, ',');
                        try seg.appendSlice(b.alloc, tp.name);
                    }
                    try seg.append(b.alloc, ')');
                }
            }
            var inner = try b.enter(try seg.toOwnedSlice(b.alloc));
            for (ib.methods) |m| try walkDecl(&inner, m);
        },
        .runtime_class_decl => |rc| {
            var inner = try b.enter(rc.name);
            for (rc.members) |m| switch (m) {
                .method => |md| if (md.body) |body| {
                    var method = try inner.enter(md.name);
                    try walk(&method, body);
                },
                .field, .extends, .implements => {},
            };
        },
        .const_decl => |cd| {
            var inner = try b.enter(cd.name);
            try walk(&inner, cd.value);
        },
        .var_decl => |vd| {
            var inner = try b.enter(vd.name);
            if (vd.value) |v| try walk(&inner, v);
        },
        // A namespace's members are module-scope declarations of the module it
        // targets. `own_decls` is not always inside `decls`: a name a flat
        // import already claimed keeps the author out of the global list.
        .namespace_decl => |nd| {
            for (nd.decls) |d| try walkModuleDecl(b, d);
            for (nd.own_decls) |d| try walkModuleDecl(b, d);
        },
        .root => |r| for (r.decls) |d| try walkModuleDecl(b, d),
        // Anything else at module scope carries no name of its own; its sites
        // belong to the enclosing declaration.
        else => try walk(b, node),
    }
}

/// Deterministic structural spelling of a type expression, for declaration
/// segments. The segment is identity, not display: distinct source spellings
/// must yield distinct strings.
fn spellType(alloc: std.mem.Allocator, node: *const Node) anyerror![]const u8 {
    switch (node.data) {
        .type_expr => |t| return alloc.dupe(u8, t.name),
        .parameterized_type_expr => |p| {
            var out = std.ArrayList(u8).empty;
            try out.appendSlice(alloc, p.name);
            try out.append(alloc, '(');
            for (p.args, 0..) |a, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, try spellType(alloc, a));
            }
            try out.append(alloc, ')');
            return out.toOwnedSlice(alloc);
        },
        .pointer_type_expr => |p| return std.fmt.allocPrint(alloc, "*{s}", .{try spellType(alloc, p.pointee_type)}),
        .many_pointer_type_expr => |m| return std.fmt.allocPrint(alloc, "[*]{s}", .{try spellType(alloc, m.element_type)}),
        .optional_type_expr => |o| return std.fmt.allocPrint(alloc, "?{s}", .{try spellType(alloc, o.inner_type)}),
        .slice_type_expr => |s| return std.fmt.allocPrint(alloc, "[]{s}", .{try spellType(alloc, s.element_type)}),
        .array_type_expr => |a| return std.fmt.allocPrint(alloc, "[{s}]{s}", .{ try spellType(alloc, a.length), try spellType(alloc, a.element_type) }),
        .int_literal => |il| return std.fmt.allocPrint(alloc, "{d}", .{il.value}),
        .function_type_expr => |f| {
            var out = std.ArrayList(u8).empty;
            try out.append(alloc, '(');
            for (f.param_types, 0..) |p, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, try spellType(alloc, p));
            }
            if (f.is_c_variadic) {
                if (f.param_types.len > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, "..");
            }
            try out.appendSlice(alloc, ")->");
            if (f.return_type) |r| try out.appendSlice(alloc, try spellType(alloc, r)) else try out.appendSlice(alloc, "void");
            return out.toOwnedSlice(alloc);
        },
        .closure_type_expr => |c| {
            var out = std.ArrayList(u8).empty;
            try out.appendSlice(alloc, "Closure(");
            for (c.param_types, 0..) |p, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, try spellType(alloc, p));
            }
            try out.appendSlice(alloc, ")->");
            if (c.return_type) |r| try out.appendSlice(alloc, try spellType(alloc, r)) else try out.appendSlice(alloc, "void");
            return out.toOwnedSlice(alloc);
        },
        .tuple_type_expr => |t| {
            var out = std.ArrayList(u8).empty;
            try out.appendSlice(alloc, "Tuple(");
            for (t.field_types, 0..) |f, i| {
                if (i > 0) try out.append(alloc, ',');
                if (t.field_names) |names| {
                    try out.appendSlice(alloc, names[i]);
                    try out.append(alloc, ':');
                }
                try out.appendSlice(alloc, try spellType(alloc, f));
            }
            try out.append(alloc, ')');
            return out.toOwnedSlice(alloc);
        },
        // Const-expr forms reachable in type positions (array dimensions,
        // value args of parameterized types) carry distinguishing structure.
        .binary_op => |o| return std.fmt.allocPrint(alloc, "({s}){s}({s})", .{
            try spellType(alloc, o.lhs),
            @tagName(o.op),
            try spellType(alloc, o.rhs),
        }),
        .unary_op => |o| return std.fmt.allocPrint(alloc, "{s}({s})", .{
            @tagName(o.op),
            try spellType(alloc, o.operand),
        }),
        .call => |c| {
            var out = std.ArrayList(u8).empty;
            try out.appendSlice(alloc, try spellType(alloc, c.callee));
            try out.append(alloc, '(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, try spellType(alloc, a));
            }
            try out.append(alloc, ')');
            return out.toOwnedSlice(alloc);
        },
        .field_access => |fa| return std.fmt.allocPrint(alloc, "{s}.{s}", .{
            try spellType(alloc, fa.object),
            fa.field,
        }),
        else => {
            if (ast.bareName(node)) |n| return alloc.dupe(u8, n);
            return alloc.dupe(u8, @tagName(node.data));
        },
    }
}

/// Pre-order walk inside one numbering scope: the node takes the next ordinal,
/// then its children do, left to right. A nested NAMED declaration re-enters
/// `walkDecl` and numbers its own body from zero; an anonymous block or
/// closure does not — per the design it folds into the nearest named
/// declaration and only contributes to the ordinal.
///
/// The switch is exhaustive on purpose: a new node kind must be classified
/// here rather than silently dropping the sites beneath it.
fn walk(b: *Builder, node: *const Node) anyerror!void {
    switch (node.data) {
        // A nested named declaration is a scope, not a site in this one.
        .fn_decl, .struct_decl, .protocol_decl, .open_set_decl, .impl_block, .runtime_class_decl, .namespace_decl => return walkDecl(b, node),
        else => try b.record(node),
    }
    switch (node.data) {
        .call => |c| {
            try walk(b, c.callee);
            for (c.args) |a| try walk(b, a);
        },
        .fn_decl, .struct_decl, .protocol_decl, .open_set_decl, .impl_block, .runtime_class_decl, .namespace_decl => unreachable,
        .const_decl => |cd| {
            if (cd.type_annotation) |t| try walk(b, t);
            try walk(b, cd.value);
        },
        .var_decl => |vd| {
            if (vd.type_annotation) |t| try walk(b, t);
            if (vd.value) |v| try walk(b, v);
        },

        // Anonymous scopes fold into the enclosing named declaration.
        .block => |bl| for (bl.stmts) |s| try walk(b, s),
        .lambda => |l| {
            for (l.params) |p| {
                try walk(b, p.type_expr);
                if (p.default_expr) |d| try walk(b, d);
            }
            if (l.return_type) |rt| try walk(b, rt);
            try walk(b, l.body);
        },
        .trailing_block => |tb| try walk(b, tb.lambda),

        .root => |r| for (r.decls) |d| try walkModuleDecl(b, d),
        .binary_op => |o| {
            try walk(b, o.lhs);
            try walk(b, o.rhs);
        },
        .chained_comparison => |cc| for (cc.operands) |o| try walk(b, o),
        .unary_op => |o| try walk(b, o.operand),
        .field_access => |fa| try walk(b, fa.object),
        .if_expr => |ie| {
            try walk(b, ie.condition);
            try walk(b, ie.then_branch);
            if (ie.else_branch) |e| try walk(b, e);
        },
        .match_expr => |me| {
            try walk(b, me.subject);
            for (me.arms) |arm| {
                if (arm.pattern) |p| try walk(b, p);
                try walk(b, arm.body);
            }
        },
        .match_arm => |arm| {
            if (arm.pattern) |p| try walk(b, p);
            try walk(b, arm.body);
        },
        .assignment => |a| {
            try walk(b, a.target);
            try walk(b, a.value);
        },
        .multi_assign => |ma| {
            for (ma.targets) |t| try walk(b, t);
            for (ma.values) |v| try walk(b, v);
        },
        .destructure_decl => |dd| try walk(b, dd.value),
        .enum_decl => |ed| {
            for (ed.variant_types) |t| if (t) |tt| try walk(b, tt);
            for (ed.variant_values) |v| if (v) |vv| try walk(b, vv);
            if (ed.backing_type) |bt| try walk(b, bt);
        },
        .union_decl => |ud| for (ud.field_types) |t| try walk(b, t),
        .struct_literal => |sl| {
            if (sl.type_expr) |t| try walk(b, t);
            for (sl.field_inits) |fi| try walk(b, fi.value);
            if (sl.init_block) |ib| try walk(b, ib);
        },
        .param => |p| {
            try walk(b, p.type_expr);
            if (p.default_expr) |d| try walk(b, d);
        },
        .defer_stmt => |d| try walk(b, d.expr),
        .push_stmt => |p| {
            try walk(b, p.context_expr);
            try walk(b, p.body);
        },
        .comptime_expr => |c| try walk(b, c.expr),
        .insert_expr => |i| try walk(b, i.expr),
        .return_stmt => |r| if (r.value) |v| try walk(b, v),
        .array_type_expr => |a| {
            try walk(b, a.length);
            try walk(b, a.element_type);
        },
        .slice_type_expr => |s| try walk(b, s.element_type),
        .array_literal => |a| {
            if (a.type_expr) |t| try walk(b, t);
            for (a.elements) |e| try walk(b, e);
        },
        .parameterized_type_expr => |p| for (p.args) |a| try walk(b, a),
        .index_expr => |i| {
            try walk(b, i.object);
            try walk(b, i.index);
        },
        .slice_expr => |s| {
            try walk(b, s.object);
            if (s.start) |st| try walk(b, st);
            if (s.end) |e| try walk(b, e);
        },
        .pointer_type_expr => |p| try walk(b, p.pointee_type),
        .many_pointer_type_expr => |m| try walk(b, m.element_type),
        .optional_type_expr => |o| try walk(b, o.inner_type),
        .raise_stmt => |r| try walk(b, r.tag),
        .try_expr => |t| try walk(b, t.operand),
        .catch_expr => |c| {
            try walk(b, c.operand);
            try walk(b, c.body);
        },
        .onfail_stmt => |o| try walk(b, o.body),
        .force_unwrap => |f| try walk(b, f.operand),
        .null_coalesce => |n| {
            try walk(b, n.lhs);
            try walk(b, n.rhs);
        },
        .deref_expr => |d| try walk(b, d.operand),
        .postfix_cast => |p| {
            try walk(b, p.operand);
            try walk(b, p.type_expr);
            if (p.alloc_arg) |a| try walk(b, a);
        },
        .while_expr => |w| {
            try walk(b, w.condition);
            try walk(b, w.body);
        },
        .for_expr => |f| {
            for (f.iterables) |it| {
                try walk(b, it.expr);
                if (it.range_end) |e| try walk(b, e);
            }
            try walk(b, f.body);
        },
        .spread_expr => |s| try walk(b, s.operand),
        .named_arg => |n| try walk(b, n.value),
        .type_expr => |t| for (t.protocol_constraints) |pc| try walk(b, pc),
        .function_type_expr => |f| {
            for (f.param_types) |p| try walk(b, p);
            if (f.return_type) |r| try walk(b, r);
        },
        .closure_type_expr => |c| {
            for (c.param_types) |p| try walk(b, p);
            if (c.return_type) |r| try walk(b, r);
        },
        .tuple_type_expr => |t| for (t.field_types) |f| try walk(b, f),
        .return_type_expr => |r| {
            for (r.field_types) |f| try walk(b, f);
            if (r.field_defaults) |ds| for (ds) |d| if (d) |dd| try walk(b, dd);
        },
        .tuple_literal => |t| {
            if (t.type_expr) |te| try walk(b, te);
            for (t.elements) |e| try walk(b, e.value);
        },
        .ffi_intrinsic_call => |f| {
            try walk(b, f.return_type);
            for (f.args) |a| try walk(b, a);
        },
        .jni_env_block => |j| {
            try walk(b, j.env);
            try walk(b, j.body);
        },
        .asm_expr => |a| {
            try walk(b, a.template);
            for (a.operands) |op| try walk(b, op.payload);
        },
        .asm_global => |a| try walk(b, a.template),
        .context_extend_decl => |c| {
            try walk(b, c.type_expr);
            if (c.default_expr) |d| try walk(b, d);
        },

        // Leaves: indexed above, nothing below them.
        .int_literal,
        .float_literal,
        .bool_literal,
        .string_literal,
        .char_literal,
        .identifier,
        .enum_literal,
        .error_set_decl,
        .error_directive,
        .import_decl,
        .c_import_decl,
        .library_decl,
        .framework_decl,
        .ufcs_alias,
        .error_type_expr,
        .caller_site,
        .pack_index_type_expr,
        .comptime_pack_ref,
        .null_literal,
        .break_expr,
        .continue_expr,
        .undef_literal,
        .inferred_type,
        .intrinsic_expr,
        => {},
    }
}
