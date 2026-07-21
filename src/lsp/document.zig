const std = @import("std");
const sx = struct {
    pub const ast = @import("../ast.zig");
    pub const parser = @import("../parser.zig");
    pub const sema = @import("../sema.zig");
    pub const imports = @import("../imports.zig");
    pub const c_import = @import("../c_import.zig");
};

pub const Import = struct {
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
    /// LSP version (from didOpen/didChange), -1 for disk-loaded imports.
    version: i64,
    /// AST root for this file only (not merged).
    root: ?*sx.ast.Node,
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
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Workspace root path (from initialize). Used to absolutify CWD-relative import paths.
    root_path: []const u8 = "",
    /// Install-discovered stdlib search paths. Mirrors the compiler's
    /// `--lib-path` resolution so `#import "modules/std.sx"` etc. find the
    /// shipped library files even when the workspace is something other
    /// than the sx repo (e.g. /Users/agra/projects/game).
    stdlib_paths: []const []const u8 = &.{},
    /// All loaded documents, keyed by the canonical path spelling (`canonKey`)
    /// so absolute (didOpen URI) and CWD-relative (import resolution)
    /// spellings of the same file share one Document.
    by_path: std.StringHashMap(*Document),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stdlib_paths: []const []const u8) DocumentStore {
        return .{
            .allocator = allocator,
            .io = io,
            .stdlib_paths = stdlib_paths,
            .by_path = std.StringHashMap(*Document).init(allocator),
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
            doc.source = source;
            doc.version = version;
            // Invalidate analysis
            doc.root = null;
            doc.sema = null;
            doc.imports = &.{};
            return doc;
        }
        return self.createDocument(key, source, version);
    }

    fn createDocument(self: *DocumentStore, path: []const u8, source: [:0]const u8, version: i64) !*Document {
        const doc = try self.allocator.create(Document);
        const path_owned = try self.allocator.dupe(u8, path);
        doc.* = .{
            .path = path_owned,
            .source = source,
            .version = version,
            .root = null,
            .sema = null,
            .imports = &.{},
            .c_source_locations = std.StringHashMap(sx.c_import.CSourceLocation).init(self.allocator),
        };
        try self.by_path.put(path_owned, doc);
        return doc;
    }

    /// Analyze a document: parse, resolve imports, run sema with imported symbols pre-registered.
    pub fn analyzeDocument(self: *DocumentStore, doc: *Document) !void {
        if (doc.is_analyzing) return; // circular import guard
        doc.is_analyzing = true;
        defer doc.is_analyzing = false;

        // Parse if needed
        if (doc.root == null) {
            var p = sx.parser.Parser.init(self.allocator, doc.source);
            doc.root = p.parse() catch return;
        }

        // Expand root with synthetic fn_decls from #import c { ... } declarations.
        // This makes C functions visible to sema, completions, and hover.
        doc.c_source_locations = std.StringHashMap(sx.c_import.CSourceLocation).init(self.allocator);
        if (doc.root) |parsed_root| {
            if (parsed_root.data == .root) {
                var expanded = std.ArrayList(*sx.ast.Node).empty;
                for (parsed_root.data.root.decls) |decl| {
                    if (decl.data == .c_import_decl) {
                        const ci = decl.data.c_import_decl;
                        if (sx.c_import.processCImport(
                            self.allocator,
                            ci.includes,
                            ci.defines,
                            ci.flags,
                        )) |result| {
                            for (result.fn_decls, result.locations) |fd, loc| {
                                try expanded.append(self.allocator, fd);
                                if (fd.data == .fn_decl) {
                                    try doc.c_source_locations.put(fd.data.fn_decl.name, loc);
                                }
                            }
                        } else |_| {}
                    }
                    try expanded.append(self.allocator, decl);
                }
                if (expanded.items.len != parsed_root.data.root.decls.len) {
                    const new_root = try self.allocator.create(sx.ast.Node);
                    new_root.* = .{
                        .span = parsed_root.span,
                        .data = .{ .root = .{ .decls = try expanded.toOwnedSlice(self.allocator) } },
                    };
                    doc.root = new_root;
                }
            }
        }

        const root = doc.root orelse return;

        // Extract imports from AST — uses shared resolution logic from imports.zig
        var import_list = std.ArrayList(Import).empty;
        const base_dir = sx.imports.dirName(doc.path);
        if (root.data == .root) {
            for (root.data.root.decls) |decl| {
                if (decl.data != .import_decl) continue;
                const imp = decl.data.import_decl;
                const resolved_path = try sx.imports.resolveImportPath(self.allocator, self.io, base_dir, imp.path, self.rootPathOpt(), self.stdlib_paths);
                try import_list.append(self.allocator, .{
                    .ns = imp.name,
                    .path = resolved_path,
                });
            }
        }
        doc.imports = try import_list.toOwnedSlice(self.allocator);
        doc.last_good_imports = doc.imports;

        // Recursively analyze imported documents and pre-register their symbols
        var analyzer = sx.sema.Analyzer.init(self.allocator);

        for (doc.imports) |imp| {
            // Try as file first; if that fails, try as directory import
            const imp_doc = self.getOrLoad(imp.path) catch {
                // Directory import: load each .sx file and merge their symbols
                const dir_files = self.listDirectoryFiles(imp.path) orelse continue;
                for (dir_files) |file_path| {
                    const file_doc = self.getOrLoad(file_path) catch continue;
                    if (file_doc.sema == null) {
                        self.analyzeDocument(file_doc) catch {};
                    }
                    const file_sema = file_doc.sema orelse continue;
                    if (imp.ns) |ns_name| {
                        // Only register namespace symbol once (first file)
                        if (!analyzer.hasSymbol(ns_name)) {
                            try analyzer.preRegisterSymbol(.{
                                .name = ns_name,
                                .kind = .namespace,
                                .ty = null,
                                .def_span = .{ .start = 0, .end = 0 },
                                .scope_depth = 0,
                                .origin = imp.path,
                            });
                        }
                        var sig_it = file_sema.fn_signatures.iterator();
                        while (sig_it.next()) |entry| {
                            const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_name, entry.key_ptr.* });
                            try analyzer.fn_signatures.put(prefixed, entry.value_ptr.*);
                        }
                        var struct_it = file_sema.struct_types.iterator();
                        while (struct_it.next()) |entry| {
                            const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_name, entry.key_ptr.* });
                            try analyzer.struct_types.put(prefixed, entry.value_ptr.*);
                        }
                        var enum_it = file_sema.enum_types.iterator();
                        while (enum_it.next()) |entry| {
                            const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_name, entry.key_ptr.* });
                            try analyzer.enum_types.put(prefixed, entry.value_ptr.*);
                        }
                    } else {
                        for (file_sema.symbols) |sym| {
                            if (sym.scope_depth == 0) {
                                // Private module-scope symbols never cross a
                                // flat import into another file.
                                if (sym.visibility == .private) continue;
                                try analyzer.preRegisterSymbol(.{
                                    .name = sym.name,
                                    .kind = sym.kind,
                                    .ty = sym.ty,
                                    .def_span = sym.def_span,
                                    .scope_depth = 0,
                                    .origin = sym.origin orelse file_path,
                                });
                            }
                        }
                        var sig_it = file_sema.fn_signatures.iterator();
                        while (sig_it.next()) |entry| {
                            try analyzer.fn_signatures.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var struct_it = file_sema.struct_types.iterator();
                        while (struct_it.next()) |entry| {
                            try analyzer.struct_types.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var enum_it = file_sema.enum_types.iterator();
                        while (enum_it.next()) |entry| {
                            try analyzer.enum_types.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                    }
                }
                continue;
            };

            // Ensure imported doc is analyzed
            if (imp_doc.sema == null) {
                self.analyzeDocument(imp_doc) catch {};
            }

            const imp_sema = imp_doc.sema orelse continue;

            if (imp.ns) |ns_name| {
                // Namespaced import: register one namespace symbol
                try analyzer.preRegisterSymbol(.{
                    .name = ns_name,
                    .kind = .namespace,
                    .ty = null,
                    .def_span = .{ .start = 0, .end = 0 },
                    .scope_depth = 0,
                    .origin = imp.path,
                });
                // Copy fn_signatures with namespace prefix
                var sig_it = imp_sema.fn_signatures.iterator();
                while (sig_it.next()) |entry| {
                    const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_name, entry.key_ptr.* });
                    try analyzer.fn_signatures.put(prefixed, entry.value_ptr.*);
                }
                // Copy struct_types with namespace prefix
                var struct_it = imp_sema.struct_types.iterator();
                while (struct_it.next()) |entry| {
                    const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_name, entry.key_ptr.* });
                    try analyzer.struct_types.put(prefixed, entry.value_ptr.*);
                }
                // Copy enum_types with namespace prefix
                var enum_it = imp_sema.enum_types.iterator();
                while (enum_it.next()) |entry| {
                    const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_name, entry.key_ptr.* });
                    try analyzer.enum_types.put(prefixed, entry.value_ptr.*);
                }
            } else {
                // Flat import: pre-register all top-level symbols with origin set
                for (imp_sema.symbols) |sym| {
                    if (sym.scope_depth == 0) {
                        // Private module-scope symbols never cross a flat
                        // import into another file.
                        if (sym.visibility == .private) continue;
                        try analyzer.preRegisterSymbol(.{
                            .name = sym.name,
                            .kind = sym.kind,
                            .ty = sym.ty,
                            .def_span = sym.def_span,
                            .scope_depth = 0,
                            .origin = sym.origin orelse imp.path,
                        });
                    }
                }
                // Copy fn_signatures as-is
                var sig_it = imp_sema.fn_signatures.iterator();
                while (sig_it.next()) |entry| {
                    try analyzer.fn_signatures.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                // Copy struct_types
                var struct_it = imp_sema.struct_types.iterator();
                while (struct_it.next()) |entry| {
                    try analyzer.struct_types.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                // Copy enum_types
                var enum_it = imp_sema.enum_types.iterator();
                while (enum_it.next()) |entry| {
                    try analyzer.enum_types.put(entry.key_ptr.*, entry.value_ptr.*);
                }
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
