const std = @import("std");
const sx = struct {
    pub const ast = @import("../ast.zig");
    pub const lexer = @import("sxlex").lexer;
    pub const token_list = @import("sxlex").token_list;
    pub const parser = @import("../parser.zig");
    pub const sema = @import("../sema.zig");
    pub const imports = @import("../imports.zig");
    pub const c_import = @import("../c_import.zig");
};

pub const Import = struct {
    block: sx.imports.LexicalBlockId,
    exposure: enum { plain, spread } = .plain,
    declaration: ?sx.sema.Declaration = null,
    /// Namespace name. null for flat imports.
    ns: ?[]const u8,
    /// Resolved absolute file path.
    path: []const u8,
};

/// An arena shared by every holder that points into it, freed with its last
/// holder.
pub const SharedArena = struct {
    arena: std.heap.ArenaAllocator,
    holders: u32 = 1,
    /// Arenas this one's contents point into, released with it.
    held: std.ArrayList(*SharedArena) = .empty,

    /// The header lives in its own arena: `release` frees it with the blocks.
    pub fn create(backing: std.mem.Allocator) !*SharedArena {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const shared = try arena.allocator().create(SharedArena);
        shared.* = .{ .arena = arena };
        return shared;
    }

    pub fn allocator(self: *SharedArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn retain(self: *SharedArena) *SharedArena {
        self.holders += 1;
        return self;
    }

    fn hold(self: *SharedArena, other: *SharedArena) !void {
        try self.held.append(self.allocator(), other);
        _ = other.retain();
    }

    pub fn release(self: *SharedArena) void {
        self.holders -= 1;
        if (self.holders > 0) return;
        for (self.held.items) |other| other.release();
        self.arena.deinit();
    }
};

pub const Document = struct {
    /// Resolved absolute file path.
    path: []const u8,
    /// Source text of this file.
    source: [:0]const u8,
    /// Token vector for `source`. Replaced only by `setSource`, never alone.
    tokens: sx.token_list.TokenList,
    /// Owns `source` and `tokens`; replaced in the same transaction as both.
    text: *SharedArena,
    /// LSP version (from didOpen/didChange), -1 for disk-loaded imports.
    version: i64,
    /// Owns `root`, `declarations`, `sema`, `imports` and
    /// `c_source_locations`: the latest analysis whose parse succeeded.
    analysis: ?*SharedArena = null,
    /// AST root for this file only (not merged).
    root: ?*sx.ast.Node,
    declarations: ?sx.sema.DeclarationContext = null,
    /// Editor index for this file — symbols/references/types for navigation,
    /// completion, and hover (references are relative to this source). Not a
    /// diagnostic source; see `sema.zig` module doc.
    sema: ?sx.sema.SemaResult,
    /// Owns `last_good_sema` and `last_good_imports`.
    last_good: ?*SharedArena = null,
    /// Last successful sema (preserved across parse failures for completions).
    last_good_sema: ?sx.sema.SemaResult = null,
    /// Import declarations parsed from this file.
    imports: []const Import,
    /// Last successful imports (preserved across parse failures for completions).
    last_good_imports: []const Import = &.{},
    /// Source locations for C import functions (name → file:line for go-to-definition).
    c_source_locations: std.StringHashMap(sx.c_import.CSourceLocation),
    /// True while this document is being analyzed (circular import guard).
    is_analyzing: bool = false,

    pub fn topLevelSymbols(self: *const Document) []const sx.sema.Symbol {
        const sr = self.sema orelse return &.{};
        return sr.symbols;
    }

    /// The doc-comment block above the site at `site_start`, which must spell
    /// `name` in this document's source. A site spelling anything else came
    /// from another document and yields null, never this file's comment at
    /// that offset.
    pub fn docFor(self: *const Document, site_start: u32, name: []const u8) ?[]const u8 {
        if (site_start == sx.ast.no_source_start) return null;
        const i = self.tokens.tokenAtStart(site_start) orelse return null;
        if (!std.mem.eql(u8, self.tokens.slice(i), name)) return null;
        return self.tokens.docBlock(i);
    }
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Workspace root path (from initialize). Used to absolutify CWD-relative import paths.
    root_path: []const u8 = "",
    /// Install-discovered stdlib search paths. Mirrors the compiler's
    /// `--lib-path` resolution so `@import "modules/std.sx"` etc. find the
    /// shipped library files even when the workspace is something other
    /// than the sx repo (e.g. /Users/agra/projects/game).
    stdlib_paths: []const []const u8 = &.{},
    /// All loaded documents, keyed by the canonical path spelling (`canonKey`)
    /// so absolute (didOpen URI) and CWD-relative (import resolution)
    /// spellings of the same file share one Document.
    by_path: std.StringHashMap(*Document),
    /// Backs every Document's arenas, and must reclaim on free: an arena
    /// child of an arena never returns its blocks, and `allocator` is the
    /// process arena in production.
    backing: std.mem.Allocator,
    /// Analyses replaced since the last `reclaim`, which releases them once no
    /// request handler can still hold pointers into them.
    retired: std.ArrayList(*SharedArena) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stdlib_paths: []const []const u8,
        backing: std.mem.Allocator,
    ) DocumentStore {
        return .{
            .allocator = allocator,
            .io = io,
            .stdlib_paths = stdlib_paths,
            .by_path = std.StringHashMap(*Document).init(allocator),
            .backing = backing,
        };
    }

    pub fn reclaim(self: *DocumentStore) void {
        for (self.retired.items) |analysis| analysis.release();
        self.retired.clearRetainingCapacity();
    }

    fn retire(self: *DocumentStore, analysis: *SharedArena) !void {
        try self.retired.append(self.allocator, analysis);
    }

    fn rootPathOpt(self: *const DocumentStore) ?[]const u8 {
        return if (self.root_path.len > 0) self.root_path else null;
    }

    /// Normalize a `by_path` key to ONE spelling per file. Import resolution
    /// registers documents under the compiler's CWD-relative spelling
    /// (`canonicalizePath` — the diagnostic/key contract), while the editor's
    /// didOpen and request lookups arrive with the absolute path from the
    /// `file://` URI; both must land on the same Document. Identity-guarded:
    /// a respelling that can't be proven (stat) to name the same file keeps
    /// the caller's spelling. The key lives in `buffer`, in the caller's
    /// frame: lookups run on every request and `allocator` never frees.
    fn canonKey(self: *const DocumentStore, buffer: *KeyBuffer, path: []const u8) []const u8 {
        buffer.* = std.heap.stackFallback(key_capacity, self.allocator);
        return sx.imports.canonicalizeEntryPath(buffer.get(), path);
    }

    const key_capacity = 4 * std.Io.Dir.max_path_bytes;
    const KeyBuffer = std.heap.StackFallbackAllocator(key_capacity);

    /// Get or create a document for the given file path. Reads from disk if not yet loaded.
    pub fn getOrLoad(self: *DocumentStore, path: []const u8) !*Document {
        var buffer: KeyBuffer = undefined;
        const key = self.canonKey(&buffer, path);
        if (self.by_path.get(key)) |doc| return doc;
        // A document created before its file existed on disk is keyed by the
        // caller's spelling; honor it rather than loading a duplicate.
        if (!std.mem.eql(u8, key, path)) {
            if (self.by_path.get(path)) |doc| return doc;
        }

        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.io, key, self.backing, .limited(10 * 1024 * 1024)) catch {
            return error.FileNotFound;
        };
        defer self.backing.free(bytes);
        return self.createDocument(key, bytes, -1);
    }

    /// Try to list .sx files in a directory. Returns null if path is not a directory.
    pub fn listDirectoryFiles(self: *DocumentStore, dir_path: []const u8) ?[]const []const u8 {
        const dir = std.Io.Dir.openDir(.cwd(), self.io, dir_path, .{ .iterate = true }) catch return null;
        defer dir.close(self.io);

        var file_paths = std.ArrayList([]const u8).empty;
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sx")) continue;
            const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            file_paths.append(self.allocator, full_path) catch continue;
        }

        // Sort for deterministic order
        std.mem.sort([]const u8, file_paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        return file_paths.toOwnedSlice(self.allocator) catch null;
    }

    /// Recursively load and analyse every `.sx` file under the workspace root so
    /// cross-file features (find-references) see uses in files the editor never
    /// opened. Already-loaded documents keep their in-editor content.
    pub fn loadWorkspaceFiles(self: *DocumentStore) void {
        const root = self.rootPathOpt() orelse return;
        self.loadDirRecursive(root, 0);
    }

    fn loadDirRecursive(self: *DocumentStore, dir_path: []const u8, depth: u32) void {
        if (depth > 16) return;
        const dir = std.Io.Dir.openDir(.cwd(), self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            defer self.allocator.free(full);
            if (entry.kind == .directory) {
                self.loadDirRecursive(full, depth + 1);
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sx")) {
                const doc = self.getOrLoad(full) catch continue;
                if (doc.sema == null) self.analyzeDocument(doc) catch {};
            }
        }
    }

    /// Create or update a document with editor-provided source (for didOpen/didChange).
    /// The document keeps its own copy of `source`.
    pub fn openOrUpdate(self: *DocumentStore, path: []const u8, source: []const u8, version: i64) !*Document {
        var buffer: KeyBuffer = undefined;
        const key = self.canonKey(&buffer, path);
        const existing = self.by_path.get(key) orelse
            (if (!std.mem.eql(u8, key, path)) self.by_path.get(path) else null);
        if (existing) |doc| {
            try self.setSource(doc, source, version);
            // Invalidate analysis
            doc.root = null;
            doc.declarations = null;
            doc.sema = null;
            doc.imports = &.{};
            return doc;
        }
        return self.createDocument(key, source, version);
    }

    /// The one place `source` changes. Copies and lexes into a fresh arena
    /// first, so an allocation failure leaves the document's previous
    /// source/tokens/version triple intact and mutually consistent.
    fn setSource(self: *DocumentStore, doc: *Document, source: []const u8, version: i64) !void {
        const text = try SharedArena.create(self.backing);
        errdefer text.release();
        const owned = try text.allocator().dupeZ(u8, source);
        const tokens = try sx.lexer.lex(text.allocator(), owned);
        doc.text.release();
        doc.text = text;
        doc.tokens = tokens;
        doc.source = owned;
        doc.version = version;
    }

    fn createDocument(self: *DocumentStore, path: []const u8, source: []const u8, version: i64) !*Document {
        const doc = try self.allocator.create(Document);
        errdefer self.allocator.destroy(doc);
        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);
        doc.* = .{
            .path = path_owned,
            .source = undefined,
            .tokens = undefined,
            .text = try SharedArena.create(self.backing),
            .version = undefined,
            .root = null,
            .sema = null,
            .imports = &.{},
            .c_source_locations = std.StringHashMap(sx.c_import.CSourceLocation).init(self.allocator),
        };
        errdefer doc.text.release();
        try self.setSource(doc, source, version);
        try self.by_path.put(path_owned, doc);
        return doc;
    }

    /// Collect `@import`s from a decl list, descending into module drivers
    /// (`inline if` / comptime `match` / `inline for`). Every branch
    /// contributes, whichever one the driver would select: the editor answers
    /// for the whole file, including the arms this target does not compile.
    fn collectImports(self: *DocumentStore, allocator: std.mem.Allocator, list: *std.ArrayList(Import), decls: []const *sx.ast.Node, base_dir: []const u8, file_path: []const u8) anyerror!void {
        for (decls) |decl| {
            if (decl.data == .scope_decl) {
                if (decl.data.scope_decl.body_block != null) try self.collectImports(allocator, list, decl.data.scope_decl.decls, base_dir, file_path);
                continue;
            }
            if (sx.imports.isModuleDriver(decl)) {
                switch (decl.data) {
                    .if_expr => |ie| {
                        try self.collectBranchImports(allocator, list, ie.then_branch, base_dir, file_path);
                        if (ie.else_branch) |eb| try self.collectBranchImports(allocator, list, eb, base_dir, file_path);
                    },
                    .match_expr => |me| {
                        for (me.arms) |arm| try self.collectBranchImports(allocator, list, arm.body, base_dir, file_path);
                    },
                    .for_expr => |fe| try self.collectBranchImports(allocator, list, fe.body, base_dir, file_path),
                    else => {},
                }
                continue;
            }
            const operand = if (decl.data == .spread_decl) decl.data.spread_decl.source else decl;
            if (operand.data != .import_decl) continue;
            const imp = operand.data.import_decl;
            const resolved_path = try sx.imports.resolveImportPath(allocator, self.io, base_dir, imp.path, self.rootPathOpt(), self.stdlib_paths);
            try list.append(allocator, .{
                .block = decl.lexical_block.?,
                .exposure = if (decl.data == .spread_decl) .spread else .plain,
                .ns = imp.name,
                .path = resolved_path,
            });
        }
    }

    fn collectBranchImports(self: *DocumentStore, allocator: std.mem.Allocator, list: *std.ArrayList(Import), body: *sx.ast.Node, base_dir: []const u8, file_path: []const u8) anyerror!void {
        const stmts: []const *sx.ast.Node = if (body.data == .block) body.data.block.stmts else &[_]*sx.ast.Node{body};
        try self.collectImports(allocator, list, stmts, base_dir, file_path);
    }

    fn expandBranchDeclarations(self: *DocumentStore, allocator: std.mem.Allocator, doc: *Document, body: *sx.ast.Node) anyerror!void {
        if (body.data == .block) {
            try self.expandDeclarations(allocator, doc, &body.data.block.stmts, .deferred);
        } else {
            const original = try allocator.create(sx.ast.Node);
            original.* = body.*;
            var nodes: []const *sx.ast.Node = &.{original};
            try self.expandDeclarations(allocator, doc, &nodes, .deferred);
            body.data = .{ .block = .{ .stmts = nodes } };
        }
    }

    fn expandDeclarations(self: *DocumentStore, allocator: std.mem.Allocator, doc: *Document, nodes: *[]const *sx.ast.Node, publication: sx.imports.Publication) anyerror!void {
        nodes.* = try sx.imports.expandDirectoryImports(allocator, self.io, nodes.*, sx.imports.dirName(doc.path), doc.path, self.rootPathOpt(), self.stdlib_paths, null);
        var expanded = std.ArrayList(*sx.ast.Node).empty;
        for (nodes.*) |decl| {
            if (decl.data == .scope_decl) try self.expandDeclarations(allocator, doc, &decl.data.scope_decl.decls, publication);
            if (sx.imports.isModuleDriver(decl)) switch (decl.data) {
                .if_expr => |ie| {
                    try self.expandBranchDeclarations(allocator, doc, ie.then_branch);
                    if (ie.else_branch) |other| try self.expandBranchDeclarations(allocator, doc, other);
                },
                .match_expr => |me| for (me.arms) |arm| try self.expandBranchDeclarations(allocator, doc, arm.body),
                .for_expr => |fe| try self.expandBranchDeclarations(allocator, doc, fe.body),
                else => unreachable,
            };
            if (decl.data == .spread_decl and decl.data.spread_decl.source.data == .c_import_decl) {
                const result = try sx.imports.processCImport(allocator, self.io, decl, sx.imports.dirName(doc.path), self.rootPathOpt(), self.stdlib_paths, null);
                decl.data.spread_decl.c_decls = result.fn_decls;
                if (publication == .published) for (result.fn_decls, result.locations) |generated, location| {
                    if (generated.data == .fn_decl) try doc.c_source_locations.put(generated.data.fn_decl.name, location);
                };
            }
            if (decl.data == .c_import_decl and publication == .published) {
                if (sx.imports.processCImport(allocator, self.io, decl, sx.imports.dirName(doc.path), self.rootPathOpt(), self.stdlib_paths, null)) |result| {
                    const ci = decl.data.c_import_decl;
                    for (result.fn_decls, result.locations) |fd, loc| {
                        if (ci.name == null) {
                            fd.source_file = doc.path;
                            try expanded.append(allocator, fd);
                        }
                        if (fd.data == .fn_decl) {
                            try doc.c_source_locations.put(fd.data.fn_decl.name, loc);
                        }
                    }
                    if (ci.name) |name| {
                        const ns = try allocator.create(sx.ast.Node);
                        ns.* = .{
                            .span = decl.span,
                            .source_file = doc.path,
                            .visibility = decl.visibility,
                            .data = .{ .namespace_decl = .{
                                .name = name,
                                .decls = result.fn_decls,
                                .own_decls = result.fn_decls,
                                .target_module_path = doc.path,
                                .is_raw = ci.is_raw,
                            } },
                        };
                        try expanded.append(allocator, ns);
                        continue;
                    }
                } else |_| {}
            }
            try expanded.append(allocator, decl);
        }
        nodes.* = try expanded.toOwnedSlice(allocator);
    }

    fn indexBlock(self: *DocumentStore, allocator: std.mem.Allocator, table: *sx.imports.DeclTable, block: sx.imports.LexicalBlockId, nodes: []const *sx.ast.Node, duplicates: *std.ArrayList(sx.ast.Span)) anyerror!void {
        const env = table.block(block).environment;
        const source = table.environment(env).source;
        for (nodes) |decl| {
            sx.ast.stampLexicalBlock(decl, block);
            decl.source_file = source;
            sx.imports.stampFnBodySource(decl, source);
            try table.recordWrittenTarget(block, decl);
            const name = decl.data.declName() orelse (if (decl.data == .import_decl) decl.data.import_decl.name else null);
            if (name) |n| {
                if (!try table.claimNamed(env, n, decl)) {
                    try duplicates.append(allocator, decl.span);
                    continue;
                }
            }
            if (decl.data == .scope_decl) {
                const child = decl.data.scope_decl.body_block.?;
                try self.indexBlock(allocator, table, child, decl.data.scope_decl.decls, duplicates);
            } else if (decl.data == .import_decl) {
                try table.recordImport(block, decl);
            } else if (decl.data == .spread_decl) {
                try table.recordSpread(block, decl, .published);
            }
        }
    }

    /// Analyze a document: parse, resolve imports, run sema with imported symbols pre-registered.
    /// Each attempt builds in a fresh arena that replaces `analysis` once its
    /// parse succeeds.
    pub fn analyzeDocument(self: *DocumentStore, doc: *Document) !void {
        if (doc.is_analyzing) return; // circular import guard
        doc.is_analyzing = true;
        defer doc.is_analyzing = false;

        const analysis = try SharedArena.create(self.backing);
        defer analysis.release();
        try analysis.hold(doc.text);
        const allocator = analysis.allocator();

        var p = sx.parser.Parser.initFromTokens(allocator, doc.tokens);
        const root = p.parse() catch return;
        if (doc.analysis) |previous| try self.retire(previous);
        doc.analysis = analysis.retain();
        doc.root = root;
        doc.declarations = null;
        doc.sema = null;
        doc.imports = &.{};
        doc.c_source_locations = std.StringHashMap(sx.c_import.CSourceLocation).init(allocator);
        if (root.data == .root) try self.expandDeclarations(allocator, doc, &root.data.root.decls, .published);

        const table = try allocator.create(sx.imports.DeclTable);
        table.* = sx.imports.DeclTable.init(allocator);
        const environment = try table.internEnvironment(doc.path, &.{});
        const block = try table.addBlock(environment, null, root);
        root.lexical_block = block;
        var duplicates = std.ArrayList(sx.ast.Span).empty;
        if (root.data == .root) {
            for (root.data.root.decls) |decl| try table.prepareExpansion(decl, block);
            try self.indexBlock(allocator, table, block, root.data.root.decls, &duplicates);
        }
        doc.declarations = .{ .table = table, .environment = environment, .block = block };

        // Extract imports from AST — uses shared resolution logic from imports.zig
        var import_list = std.ArrayList(Import).empty;
        const base_dir = sx.imports.dirName(doc.path);
        if (root.data == .root) {
            try self.collectImports(allocator, &import_list, root.data.root.decls, base_dir, doc.path);
        }
        for (import_list.items) |*imp| {
            if (imp.ns) |name| {
                const env = table.block(imp.block).environment;
                if (table.environment(env).names.get(name)) |id| imp.declaration = .{ .table = table, .id = id };
            }
        }
        doc.imports = try import_list.toOwnedSlice(allocator);

        // Recursively analyze imported documents and pre-register their symbols
        var analyzer = sx.sema.Analyzer.init(allocator);
        analyzer.declarations = doc.declarations;
        analyzer.selection.context = doc.declarations;
        for (duplicates.items) |span| {
            try analyzer.diagnostics.append(allocator, .{ .span = span, .message = "duplicate declaration", .level = .err });
        }

        var symbol_candidates = std.ArrayList(sx.sema.Symbol).empty;
        defer symbol_candidates.deinit(allocator);
        var candidate_declarations = std.AutoHashMap(sx.sema.Declaration, void).init(allocator);
        defer candidate_declarations.deinit();
        for (doc.imports) |imp| {
            const imp_doc = self.getOrLoad(imp.path) catch continue;

            // Ensure imported doc is analyzed
            if (imp_doc.sema == null) {
                self.analyzeDocument(imp_doc) catch {};
            }

            const imp_sema = imp_doc.sema orelse continue;
            try analysis.hold(imp_doc.analysis.?);
            if (imp.exposure == .spread) {
                try analyzer.selection.spread_modules.put(imp.path, imp_sema.selection);
            } else try (try analyzer.selection.inBlock(imp.block)).addImport(imp.ns, imp_sema.selection);
            try analyzer.mergeMetadata(imp_sema);

            if (imp.ns) |ns_name| {
                try symbol_candidates.append(allocator, .{
                    .declaration = imp.declaration,
                    .name = ns_name,
                    .kind = .namespace,
                    .ty = null,
                    .def_span = .{ .start = 0, .end = 0 },
                    .scope_depth = 0,
                    .origin = imp.path,
                });
            }
            for ([_][]const sx.sema.Symbol{ imp_sema.symbols, imp_sema.imported_candidates }) |symbols| {
                for (symbols) |sym| {
                    const declaration = sym.declaration orelse continue;
                    const entry = try candidate_declarations.getOrPut(declaration);
                    if (entry.found_existing) continue;
                    var candidate = sym;
                    candidate.scope_depth = 0;
                    candidate.origin = sym.origin orelse imp.path;
                    try symbol_candidates.append(allocator, candidate);
                }
            }
        }

        analyzer.imported_candidates = try symbol_candidates.toOwnedSlice(allocator);

        // Run sema on this file's own AST
        analyzer.source = doc.source;
        doc.sema = analyzer.analyze(root) catch null;
        if (doc.sema != null) {
            if (doc.last_good) |previous| try self.retire(previous);
            doc.last_good = analysis.retain();
            doc.last_good_sema = doc.sema;
            doc.last_good_imports = doc.imports;
        }
    }

    pub fn get(self: *const DocumentStore, path: []const u8) ?*Document {
        if (self.by_path.get(path)) |doc| return doc;
        var buffer: KeyBuffer = undefined;
        const key = self.canonKey(&buffer, path);
        if (std.mem.eql(u8, key, path)) return null;
        return self.by_path.get(key);
    }
};
