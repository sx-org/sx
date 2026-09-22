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

pub const Document = struct {
    /// Resolved absolute file path.
    path: []const u8,
    /// Source text of this file.
    source: [:0]const u8,
    /// Token vector for `source`. Replaced only by `setSource`, never alone.
    tokens: sx.token_list.TokenList,
    /// Backs `tokens`. Replaced wholesale in the same transaction as `source`.
    token_arena: std.heap.ArenaAllocator,
    /// LSP version (from didOpen/didChange), -1 for disk-loaded imports.
    version: i64,
    /// AST root for this file only (not merged).
    root: ?*sx.ast.Node,
    declarations: ?sx.sema.DeclarationContext = null,
    /// Editor index for this file — symbols/references/types for navigation,
    /// completion, and hover (references are relative to this source). Not a
    /// diagnostic source; see `sema.zig` module doc.
    sema: ?sx.sema.SemaResult,
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
    /// Backs every Document's `token_arena`, and must reclaim on free: an
    /// arena child of an arena never returns its blocks, and `allocator` is
    /// the process arena in production.
    token_backing: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stdlib_paths: []const []const u8,
        token_backing: std.mem.Allocator,
    ) DocumentStore {
        return .{
            .allocator = allocator,
            .io = io,
            .stdlib_paths = stdlib_paths,
            .by_path = std.StringHashMap(*Document).init(allocator),
            .token_backing = token_backing,
        };
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
    /// the caller's spelling.
    fn canonKey(self: *const DocumentStore, path: []const u8) []const u8 {
        return sx.imports.canonicalizeEntryPath(self.allocator, path);
    }

    /// Get or create a document for the given file path. Reads from disk if not yet loaded.
    pub fn getOrLoad(self: *DocumentStore, path: []const u8) !*Document {
        const key = self.canonKey(path);
        if (self.by_path.get(key)) |doc| return doc;
        // A document created before its file existed on disk is keyed by the
        // caller's spelling; honor it rather than loading a duplicate.
        if (!std.mem.eql(u8, key, path)) {
            if (self.by_path.get(path)) |doc| return doc;
        }

        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.io, key, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return error.FileNotFound;
        };
        const source = try self.allocator.dupeZ(u8, bytes);
        return self.createDocument(key, source, -1);
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
    pub fn openOrUpdate(self: *DocumentStore, path: []const u8, source: [:0]const u8, version: i64) !*Document {
        const key = self.canonKey(path);
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

    /// The one place `source` changes. Lexes into a fresh arena first, so an
    /// allocation failure leaves the document's previous
    /// source/tokens/version triple intact and mutually consistent.
    fn setSource(self: *DocumentStore, doc: *Document, source: [:0]const u8, version: i64) !void {
        var arena = std.heap.ArenaAllocator.init(self.token_backing);
        errdefer arena.deinit();
        const tokens = try sx.lexer.lex(arena.allocator(), source);
        doc.token_arena.deinit();
        doc.token_arena = arena;
        doc.tokens = tokens;
        doc.source = source;
        doc.version = version;
    }

    fn createDocument(self: *DocumentStore, path: []const u8, source: [:0]const u8, version: i64) !*Document {
        const doc = try self.allocator.create(Document);
        errdefer self.allocator.destroy(doc);
        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);
        doc.* = .{
            .path = path_owned,
            .source = undefined,
            .tokens = undefined,
            .token_arena = std.heap.ArenaAllocator.init(self.token_backing),
            .version = undefined,
            .root = null,
            .sema = null,
            .imports = &.{},
            .c_source_locations = std.StringHashMap(sx.c_import.CSourceLocation).init(self.allocator),
        };
        errdefer doc.token_arena.deinit();
        try self.setSource(doc, source, version);
        try self.by_path.put(path_owned, doc);
        return doc;
    }

    /// Collect `@import`s from a decl list, descending into module drivers
    /// (`inline if` / comptime `match` / `inline for`). Every branch
    /// contributes, whichever one the driver would select: the editor answers
    /// for the whole file, including the arms this target does not compile.
    fn collectImports(self: *DocumentStore, list: *std.ArrayList(Import), decls: []const *sx.ast.Node, base_dir: []const u8, file_path: []const u8) anyerror!void {
        for (decls) |decl| {
            if (decl.data == .scope_decl) {
                if (decl.data.scope_decl.body_block != null) try self.collectImports(list, decl.data.scope_decl.decls, base_dir, file_path);
                continue;
            }
            if (sx.imports.isModuleDriver(decl)) {
                switch (decl.data) {
                    .if_expr => |ie| {
                        try self.collectBranchImports(list, ie.then_branch, base_dir, file_path);
                        if (ie.else_branch) |eb| try self.collectBranchImports(list, eb, base_dir, file_path);
                    },
                    .match_expr => |me| {
                        for (me.arms) |arm| try self.collectBranchImports(list, arm.body, base_dir, file_path);
                    },
                    .for_expr => |fe| try self.collectBranchImports(list, fe.body, base_dir, file_path),
                    else => {},
                }
                continue;
            }
            const operand = if (decl.data == .spread_decl) decl.data.spread_decl.source else decl;
            if (operand.data != .import_decl) continue;
            const imp = operand.data.import_decl;
            const resolved_path = try sx.imports.resolveImportPath(self.allocator, self.io, base_dir, imp.path, self.rootPathOpt(), self.stdlib_paths);
            try list.append(self.allocator, .{
                .block = decl.lexical_block.?,
                .exposure = if (decl.data == .spread_decl) .spread else .plain,
                .ns = imp.name,
                .path = resolved_path,
            });
        }
    }

    fn collectBranchImports(self: *DocumentStore, list: *std.ArrayList(Import), body: *sx.ast.Node, base_dir: []const u8, file_path: []const u8) anyerror!void {
        const stmts: []const *sx.ast.Node = if (body.data == .block) body.data.block.stmts else &[_]*sx.ast.Node{body};
        try self.collectImports(list, stmts, base_dir, file_path);
    }

    fn expandBranchDeclarations(self: *DocumentStore, doc: *Document, body: *sx.ast.Node) anyerror!void {
        if (body.data == .block) {
            try self.expandDeclarations(doc, &body.data.block.stmts, .deferred);
        } else {
            const original = try self.allocator.create(sx.ast.Node);
            original.* = body.*;
            var nodes: []const *sx.ast.Node = &.{original};
            try self.expandDeclarations(doc, &nodes, .deferred);
            body.data = .{ .block = .{ .stmts = nodes } };
        }
    }

    fn expandDeclarations(self: *DocumentStore, doc: *Document, nodes: *[]const *sx.ast.Node, publication: sx.imports.Publication) anyerror!void {
        nodes.* = try sx.imports.expandDirectoryImports(self.allocator, self.io, nodes.*, sx.imports.dirName(doc.path), doc.path, self.rootPathOpt(), self.stdlib_paths, null);
        var expanded = std.ArrayList(*sx.ast.Node).empty;
        for (nodes.*) |decl| {
            if (decl.data == .scope_decl) try self.expandDeclarations(doc, &decl.data.scope_decl.decls, publication);
            if (sx.imports.isModuleDriver(decl)) switch (decl.data) {
                .if_expr => |ie| {
                    try self.expandBranchDeclarations(doc, ie.then_branch);
                    if (ie.else_branch) |other| try self.expandBranchDeclarations(doc, other);
                },
                .match_expr => |me| for (me.arms) |arm| try self.expandBranchDeclarations(doc, arm.body),
                .for_expr => |fe| try self.expandBranchDeclarations(doc, fe.body),
                else => unreachable,
            };
            if (decl.data == .spread_decl and decl.data.spread_decl.source.data == .c_import_decl) {
                const result = try sx.imports.processCImport(self.allocator, self.io, decl.data.spread_decl.source, sx.imports.dirName(doc.path), self.rootPathOpt(), self.stdlib_paths);
                decl.data.spread_decl.c_decls = result.fn_decls;
                if (publication == .published) for (result.fn_decls, result.locations) |generated, location| {
                    if (generated.data == .fn_decl) try doc.c_source_locations.put(generated.data.fn_decl.name, location);
                };
            }
            if (decl.data == .c_import_decl and publication == .published) {
                if (sx.imports.processCImport(self.allocator, self.io, decl, sx.imports.dirName(doc.path), self.rootPathOpt(), self.stdlib_paths)) |result| {
                    const ci = decl.data.c_import_decl;
                    for (result.fn_decls, result.locations) |fd, loc| {
                        if (ci.name == null) {
                            fd.source_file = doc.path;
                            try expanded.append(self.allocator, fd);
                        }
                        if (fd.data == .fn_decl) {
                            try doc.c_source_locations.put(fd.data.fn_decl.name, loc);
                        }
                    }
                    if (ci.name) |name| {
                        const ns = try self.allocator.create(sx.ast.Node);
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
                        try expanded.append(self.allocator, ns);
                        continue;
                    }
                } else |_| {}
            }
            try expanded.append(self.allocator, decl);
        }
        nodes.* = try expanded.toOwnedSlice(self.allocator);
    }

    fn indexBlock(self: *DocumentStore, table: *sx.imports.DeclTable, block: sx.imports.LexicalBlockId, nodes: []const *sx.ast.Node, duplicates: *std.ArrayList(sx.ast.Span)) anyerror!void {
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
                    try duplicates.append(self.allocator, decl.span);
                    continue;
                }
            }
            if (sx.imports.isModuleDriver(decl)) {
                try table.prepareExpansion(decl, block);
                try self.indexDeferredSpreads(table, decl);
            }
            if (decl.data == .scope_decl) {
                const child = try table.addScopeBlock(block, decl);
                try self.indexBlock(table, child, decl.data.scope_decl.decls, duplicates);
            } else if (decl.data == .import_decl) {
                try table.recordImport(block, decl);
            } else if (decl.data == .spread_decl) {
                try table.recordSpread(block, decl, .published);
            }
        }
    }

    fn indexDeferredSpreads(self: *DocumentStore, table: *sx.imports.DeclTable, node: *sx.ast.Node) anyerror!void {
        switch (node.data) {
            .spread_decl => try table.recordSpread(node.lexical_block.?, node, .deferred),
            .scope_decl => |scope| for (scope.decls) |decl| try self.indexDeferredSpreads(table, decl),
            .block => |body| for (body.stmts) |stmt| try self.indexDeferredSpreads(table, stmt),
            .if_expr => |ie| {
                try self.indexDeferredSpreads(table, ie.then_branch);
                if (ie.else_branch) |other| try self.indexDeferredSpreads(table, other);
            },
            .match_expr => |me| for (me.arms) |arm| try self.indexDeferredSpreads(table, arm.body),
            .for_expr => |fe| try self.indexDeferredSpreads(table, fe.body),
            else => {},
        }
    }

    /// Analyze a document: parse, resolve imports, run sema with imported symbols pre-registered.
    pub fn analyzeDocument(self: *DocumentStore, doc: *Document) !void {
        if (doc.is_analyzing) return; // circular import guard
        doc.is_analyzing = true;
        defer doc.is_analyzing = false;

        // Parse if needed
        if (doc.root == null) {
            var p = sx.parser.Parser.initFromTokens(self.allocator, doc.tokens);
            doc.root = p.parse() catch return;
        }

        doc.c_source_locations = std.StringHashMap(sx.c_import.CSourceLocation).init(self.allocator);
        if (doc.root) |parsed_root| {
            if (parsed_root.data == .root) try self.expandDeclarations(doc, &parsed_root.data.root.decls, .published);
        }

        const root = doc.root orelse return;
        const table = try self.allocator.create(sx.imports.DeclTable);
        table.* = sx.imports.DeclTable.init(self.allocator);
        const environment = try table.internEnvironment(doc.path, &.{});
        const block = try table.addBlock(environment, null, root);
        root.lexical_block = block;
        var duplicates = std.ArrayList(sx.ast.Span).empty;
        if (root.data == .root) try self.indexBlock(table, block, root.data.root.decls, &duplicates);
        doc.declarations = .{ .table = table, .environment = environment, .block = block };

        // Extract imports from AST — uses shared resolution logic from imports.zig
        var import_list = std.ArrayList(Import).empty;
        const base_dir = sx.imports.dirName(doc.path);
        if (root.data == .root) {
            try self.collectImports(&import_list, root.data.root.decls, base_dir, doc.path);
        }
        for (import_list.items) |*imp| {
            if (imp.ns) |name| {
                const env = table.block(imp.block).environment;
                if (table.environment(env).names.get(name)) |id| imp.declaration = .{ .table = table, .id = id };
            }
        }
        doc.imports = try import_list.toOwnedSlice(self.allocator);
        doc.last_good_imports = doc.imports;

        // Recursively analyze imported documents and pre-register their symbols
        var analyzer = sx.sema.Analyzer.init(self.allocator);
        analyzer.declarations = doc.declarations;
        analyzer.selection.context = doc.declarations;
        for (duplicates.items) |span| {
            try analyzer.diagnostics.append(self.allocator, .{ .span = span, .message = "duplicate declaration", .level = .err });
        }

        var imported_symbols = std.AutoHashMap(sx.sema.Declaration, void).init(self.allocator);
        defer imported_symbols.deinit();
        for (doc.imports) |imp| {
            const imp_doc = self.getOrLoad(imp.path) catch continue;

            // Ensure imported doc is analyzed
            if (imp_doc.sema == null) {
                self.analyzeDocument(imp_doc) catch {};
            }

            const imp_sema = imp_doc.sema orelse continue;
            if (imp.exposure == .spread) {
                try analyzer.selection.spread_modules.put(imp.path, imp_sema.selection);
            } else try (try analyzer.selection.inBlock(imp.block)).addImport(imp.ns, imp_sema.selection);
            try analyzer.mergeMetadata(imp_sema);

            if (imp.ns) |ns_name| {
                // Namespaced import: register one namespace symbol
                try analyzer.preRegisterSymbol(.{
                    .declaration = imp.declaration,
                    .name = ns_name,
                    .kind = .namespace,
                    .ty = null,
                    .def_span = .{ .start = 0, .end = 0 },
                    .scope_depth = 0,
                    .origin = imp.path,
                });
            }
            for (imp_sema.symbols) |sym| {
                if (sym.scope_depth != 0 or sym.visibility == .private) continue;
                const declaration = sym.declaration orelse continue;
                const entry = try imported_symbols.getOrPut(declaration);
                if (entry.found_existing) continue;
                try analyzer.preRegisterSymbol(.{
                    .declaration = sym.declaration,
                    .name = sym.name,
                    .kind = sym.kind,
                    .ty = sym.ty,
                    .def_span = sym.def_span,
                    .scope_depth = 0,
                    .origin = sym.origin orelse imp.path,
                });
            }
        }

        // Run sema on this file's own AST
        analyzer.source = doc.source;
        doc.sema = analyzer.analyze(root) catch null;
        if (doc.sema != null) {
            doc.last_good_sema = doc.sema;
        }
    }

    pub fn get(self: *const DocumentStore, path: []const u8) ?*Document {
        if (self.by_path.get(path)) |doc| return doc;
        const key = self.canonKey(path);
        if (std.mem.eql(u8, key, path)) return null;
        return self.by_path.get(key);
    }
};
