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

/// The module path a site reports: the path an `#import` would spell.
///
/// A library module resolves under one of the roots the compiler searched, so
/// stripping that root yields exactly the import path (`modules/std/core.sx`)
/// and the result no longer depends on where the compiler was invoked from.
/// A file under no root keeps its own spelling, made relative to the
/// compilation root's directory for the same reason.
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
/// Restricting the set to one node kind would have made the numbering depend
/// on which consumers existed when it was written.
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
    /// Library roots import resolution searched, for normalizing module paths.
    stdlib_roots: []const []const u8 = &.{},
    /// Directory of the compilation's main file.
    main_dir: ?[]const u8 = null,
    /// Module path for declarations the parser left unstamped (the main file).
    main_file: ?[]const u8 = null,
};

const Builder = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    index: *SiteIndex,
    file: []const u8 = "",
    declaration: []const u8 = "",
    prefix: u64 = 0,
    next_ordinal: u32 = 0,

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
            .file = self.file,
            .declaration = qualified,
            .prefix = declarationPrefix(self.file, qualified),
            .next_ordinal = 0,
        };
    }

    fn record(self: *Builder, node: *const Node) !void {
        const ordinal = foldOrdinal(.{ .lexical = self.next_ordinal });
        self.next_ordinal += 1;
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
    var root = Builder{ .alloc = alloc, .opts = opts, .index = &index };
    for (decls) |decl| {
        const raw_file = decl.source_file orelse opts.main_file orelse "";
        const module_path = normalizeModulePath(raw_file, opts.stdlib_roots, opts.main_dir);
        root.file = module_path;
        root.declaration = try modulePrefix(alloc, module_path);
        try walkDecl(&root, decl);
    }
    return index;
}

/// A module-scope (or member) declaration. A declaration that BINDS A NAME
/// opens a new numbering scope; anything else keeps the caller's.
fn walkDecl(b: *Builder, node: *const Node) anyerror!void {
    switch (node.data) {
        .fn_decl => |fd| {
            var inner = try b.enter(fd.name);
            for (fd.params) |p| try walk(&inner, p.type_expr);
            for (fd.params) |p| if (p.default_expr) |d| try walk(&inner, d);
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
            for (pd.methods) |m| if (m.default_body) |body| try walk(&inner, body);
        },
        .impl_block => |ib| {
            // An impl's methods hang off the pair it implements, so the same
            // method name on two targets keeps two distinct paths.
            const segment = try std.fmt.allocPrint(b.alloc, "{s}#{s}", .{ ib.protocol_name, ib.target_type });
            var inner = try b.enter(segment);
            for (ib.methods) |m| try walkDecl(&inner, m);
        },
        .runtime_class_decl => |rc| {
            var inner = try b.enter(rc.name);
            for (rc.members) |m| switch (m) {
                .method => |md| if (md.body) |body| try walk(&inner, body),
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
        .namespace_decl => |nd| {
            for (nd.decls) |d| try walkDecl(b, d);
            for (nd.own_decls) |d| try walkDecl(b, d);
        },
        .root => |r| for (r.decls) |d| try walkDecl(b, d),
        // Anything else at module scope carries no name of its own; its sites
        // belong to the enclosing declaration.
        else => try walk(b, node),
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
        .fn_decl, .struct_decl, .protocol_decl, .impl_block, .runtime_class_decl, .namespace_decl => return walkDecl(b, node),
        else => try b.record(node),
    }
    switch (node.data) {
        .call => |c| {
            try walk(b, c.callee);
            for (c.args) |a| try walk(b, a);
        },
        .fn_decl, .struct_decl, .protocol_decl, .impl_block, .runtime_class_decl, .namespace_decl => unreachable,
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
            for (l.params) |p| try walk(b, p.type_expr);
            for (l.params) |p| if (p.default_expr) |d| try walk(b, d);
            if (l.return_type) |rt| try walk(b, rt);
            try walk(b, l.body);
        },
        .trailing_block => |tb| try walk(b, tb.lambda),

        .root => |r| for (r.decls) |d| try walkDecl(b, d),
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
            for (a.elements) |e| try walk(b, e);
            if (a.type_expr) |t| try walk(b, t);
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
        .caller_location,
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
