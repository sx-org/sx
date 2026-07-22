const std = @import("std");
const sx = struct {
    pub const ast = @import("../ast.zig");
    pub const parser = @import("../parser.zig");
    pub const lexer = @import("../lexer.zig");
    pub const token = @import("../token.zig");
    pub const types = @import("../types.zig");
    pub const sema = @import("../sema.zig");
    pub const errors = @import("../errors.zig");
    pub const imports = @import("../imports.zig");
    pub const c_import = @import("../c_import.zig");
    pub const core = @import("../core.zig");
};
const lsp = @import("types.zig");
const doc_mod = @import("document.zig");
const DocumentStore = doc_mod.DocumentStore;
const Document = doc_mod.Document;
const Transport = @import("transport.zig").Transport;
const SemaResult = sx.sema.SemaResult;

pub const Server = struct {
    allocator: std.mem.Allocator,
    documents: DocumentStore,
    transport: *Transport,
    io: std.Io,
    shutdown_requested: bool = false,
    root_path: []const u8 = "",
    stdlib_paths: []const []const u8 = &.{},
    /// URIs the last whole-program check published diagnostics to, so the next
    /// check can clear (publish empty for) files whose errors are now gone.
    project_diag_uris: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, transport: *Transport, io: std.Io, stdlib_paths: []const []const u8) Server {
        return .{
            .allocator = allocator,
            .documents = DocumentStore.init(allocator, io, stdlib_paths),
            .transport = transport,
            .io = io,
            .stdlib_paths = stdlib_paths,
            .project_diag_uris = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn handleMessage(self: *Server, raw: []const u8) bool {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
            return true;
        };
        const root = parsed.value;

        const method = jsonStr(jsonGet(root, "method") orelse return true) orelse return true;

        const id = jsonGet(root, "id");
        const params = jsonGet(root, "params");

        if (std.mem.eql(u8, method, "initialize")) {
            self.handleInitialize(id, params) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // Nothing to do
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            if (id) |req_id| {
                const id_json = lsp.valueToJson(self.allocator, req_id) catch return true;
                const resp = lsp.jsonRpcResponse(self.allocator, id_json, "null") catch return true;
                self.transport.writeMessage(resp) catch {};
            }
        } else if (std.mem.eql(u8, method, "exit")) {
            return false;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            if (params) |p| self.handleDidOpen(p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            if (params) |p| self.handleDidChange(p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            if (params) |p| self.handleDidClose(p);
        } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
            self.runProjectCheck();
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (params) |p| self.handleDefinition(id, p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            if (params) |p| self.handleReferences(id, p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            if (params) |p| self.handleHover(id, p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            if (params) |p| self.handleDocumentSymbol(id, p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (params) |p| self.handleCompletion(id, p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            if (params) |p| self.handleSignatureHelp(id, p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (params) |p| self.handleSemanticTokens(id, p) catch |e| self.logError(method, e);
        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            if (params) |p| self.handleInlayHint(id, p) catch |e| self.logError(method, e);
        }

        return true;
    }

    fn logError(self: *Server, method: []const u8, err: anyerror) void {
        self.logMessage("lsp: {s} failed: {s}", .{ method, @errorName(err) });
    }

    fn logMessage(self: *Server, comptime fmt: []const u8, args: anytype) void {
        const stderr = std.Io.File.stderr();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        stderr.writeStreamingAll(self.io, msg) catch {};
    }

    const RequestContext = struct {
        id_json: []const u8,
        uri: []const u8,
    };

    fn extractRequest(self: *Server, id: ?std.json.Value, params: std.json.Value) !?RequestContext {
        const req_id = id orelse return null;
        const id_json = try lsp.valueToJson(self.allocator, req_id);
        const td = jsonGet(params, "textDocument") orelse return null;
        const uri = jsonStr(jsonGet(td, "uri") orelse return null) orelse return null;
        return .{ .id_json = id_json, .uri = uri };
    }

    fn extractPosition(params: std.json.Value) ?struct { line: u32, character: u32 } {
        const position = jsonGet(params, "position") orelse return null;
        const line = std.math.cast(u32, jsonInt(jsonGet(position, "line") orelse return null) orelse return null) orelse return null;
        const character = std.math.cast(u32, jsonInt(jsonGet(position, "character") orelse return null) orelse return null) orelse return null;
        return .{ .line = line, .character = character };
    }

    fn sendResponse(self: *Server, id_json: []const u8, result_json: []const u8) !void {
        const resp = try lsp.jsonRpcResponse(self.allocator, id_json, result_json);
        try self.transport.writeMessage(resp);
    }

    fn handleInitialize(self: *Server, id: ?std.json.Value, params: ?std.json.Value) !void {
        // chdir to workspace root so relative paths in #import c work
        chdir: {
            const p = params orelse break :chdir;
            const root_uri_val = jsonGet(p, "rootUri") orelse break :chdir;
            const root_uri = jsonStr(root_uri_val) orelse break :chdir;
            const prefix = "file://";
            if (!std.mem.startsWith(u8, root_uri, prefix)) break :chdir;
            const root_path = root_uri[prefix.len..];
            self.root_path = self.allocator.dupe(u8, root_path) catch break :chdir;
            self.documents.root_path = self.root_path;
            const path_z = self.allocator.dupeZ(u8, root_path) catch break :chdir;
            _ = std.c.chdir(path_z.ptr);
        }
        const req_id = id orelse return;
        const id_json = try lsp.valueToJson(self.allocator, req_id);
        const result_json = try lsp.initializeResultJson(self.allocator);
        try self.sendResponse(id_json, result_json);
    }

    // ---- Document lifecycle ----

    fn handleDidOpen(self: *Server, params: std.json.Value) !void {
        const td = jsonGet(params, "textDocument") orelse return;
        const uri = jsonStr(jsonGet(td, "uri") orelse return) orelse return;
        const text = jsonStr(jsonGet(td, "text") orelse return) orelse return;
        const version = jsonInt(jsonGet(td, "version") orelse return) orelse return;

        try self.refreshEditorIndex(uri, text, version);
        self.runProjectCheck();
    }

    fn handleDidChange(self: *Server, params: std.json.Value) !void {
        const td = jsonGet(params, "textDocument") orelse return;
        const uri = jsonStr(jsonGet(td, "uri") orelse return) orelse return;
        const version = jsonInt(jsonGet(td, "version") orelse return) orelse return;

        const changes_arr = jsonArr(jsonGet(params, "contentChanges") orelse return) orelse return;
        if (changes_arr.len == 0) return;

        const last = changes_arr[changes_arr.len - 1];
        const text = jsonStr(jsonGet(last, "text") orelse return) orelse return;

        try self.refreshEditorIndex(uri, text, version);
    }

    fn handleDidClose(_: *Server, params: std.json.Value) void {
        _ = params;
        // Documents stay in the store (imports may reference them).
    }

    // ---- Go to definition ----

    fn appendRefLoc(self: *Server, buf: *std.ArrayList(u8), first: *bool, target_doc: *const Document, span: sx.ast.Span) !void {
        if (!first.*) try buf.append(self.allocator, ',');
        first.* = false;
        const uri = try self.fileUri(target_doc.path);
        const range = spanToRange(target_doc.source, span);
        const loc = try lsp.locationJson(self.allocator, uri, range);
        try buf.appendSlice(self.allocator, loc);
    }

    /// textDocument/references — all uses of the symbol under the cursor (a
    /// reference or a definition). Same-file matches are precise (by symbol
    /// index); cross-file matches a top-level name (functions/types/globals).
    fn handleReferences(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const ctx = try self.extractRequest(id, params) orelse return;
        const pos = extractPosition(params) orelse return;
        const id_json = ctx.id_json;
        const file_path = uriToFilePath(ctx.uri) orelse "";
        const doc = self.documents.get(file_path) orelse return try self.sendResponse(id_json, "null");
        const sema = doc.sema orelse doc.last_good_sema orelse return try self.sendResponse(id_json, "null");
        const offset = positionToOffset(doc.source, pos.line, pos.character) orelse return try self.sendResponse(id_json, "null");

        // References span the whole project — pull in workspace files the
        // editor hasn't opened so their uses are searched too.
        self.documents.loadWorkspaceFiles();

        var include_decl = true;
        if (jsonGet(params, "context")) |c| {
            if (jsonGet(c, "includeDeclaration")) |v| {
                if (v == .bool) include_decl = v.bool;
            }
        }

        const payload = try self.referencesPayload(doc, &sema, offset, include_decl);
        try self.sendResponse(id_json, payload);
    }

    /// Compute the `textDocument/references` JSON payload for the symbol at
    /// `offset`. Pure over the loaded documents (no transport / io), so it is
    /// unit-testable: build a `DocumentStore` of in-memory docs and call this.
    fn referencesPayload(self: *Server, doc: *const Document, sema: *const SemaResult, offset: u32, include_decl: bool) ![]const u8 {
        // A struct field / method / enum variant under the cursor — matched by
        // (owner type, name) across loaded documents.
        for (sema.member_refs) |mt| {
            if (offset < mt.span.start or offset >= mt.span.end) continue;
            var buf = std.ArrayList(u8).empty;
            try buf.append(self.allocator, '[');
            var first = true;
            var dit = self.documents.by_path.iterator();
            while (dit.next()) |entry| {
                const odoc = entry.value_ptr.*;
                const osema = odoc.sema orelse continue;
                for (osema.member_refs) |mr| {
                    if (!std.mem.eql(u8, mr.name, mt.name)) continue;
                    // Owner must match, treating an unknown owner ("") as a wildcard.
                    if (mr.owner.len != 0 and mt.owner.len != 0 and !std.mem.eql(u8, mr.owner, mt.owner)) continue;
                    if (mr.is_def and !include_decl) continue;
                    try self.appendRefLoc(&buf, &first, odoc, mr.span);
                }
            }
            try buf.append(self.allocator, ']');
            return buf.items;
        }

        // Resolve the target symbol: a reference at the cursor, or a definition.
        var target_idx: ?u32 = null;
        if (sx.sema.findReferenceAtOffset(sema.references, offset)) |ri| {
            target_idx = sema.references[ri].symbol_index;
        } else if (findSymbolNameAtOffset(sema.symbols, doc.source, offset)) |si| {
            target_idx = @intCast(si);
        }
        if (target_idx == null) return "[]";
        const target = sema.symbols[target_idx.?];
        const cross_file = target.scope_depth == 0; // only top-level names span files

        var buf = std.ArrayList(u8).empty;
        try buf.append(self.allocator, '[');
        var first = true;

        // Current document — precise by symbol index.
        if (include_decl) try self.appendRefLoc(&buf, &first, doc, target.def_span);
        for (sema.references) |ref| {
            if (ref.symbol_index == target_idx.?) try self.appendRefLoc(&buf, &first, doc, ref.span);
        }

        // Other documents — match a top-level name by string.
        if (cross_file) {
            var it = self.documents.by_path.iterator();
            while (it.next()) |entry| {
                const odoc = entry.value_ptr.*;
                if (std.mem.eql(u8, odoc.path, doc.path)) continue;
                const osema = odoc.sema orelse continue;
                if (include_decl) {
                    for (osema.symbols) |sym| {
                        if (sym.scope_depth == 0 and sym.origin == null and std.mem.eql(u8, sym.name, target.name)) {
                            try self.appendRefLoc(&buf, &first, odoc, sym.def_span);
                        }
                    }
                }
                for (osema.references) |ref| {
                    const rs = osema.symbols[ref.symbol_index];
                    if (rs.scope_depth == 0 and std.mem.eql(u8, rs.name, target.name)) {
                        try self.appendRefLoc(&buf, &first, odoc, ref.span);
                    }
                }
            }
        }

        try buf.append(self.allocator, ']');
        return buf.items;
    }

    /// The name-token span of a member declaration (struct field, method, enum
    /// variant) at `offset`, or null when `offset` isn't on a declaration. Lets
    /// go-to-definition on a definition resolve to itself.
    fn selfMemberDefAt(sema: *const SemaResult, offset: u32) ?sx.ast.Span {
        for (sema.member_refs) |mr| {
            if (!mr.is_def) continue;
            if (offset < mr.span.start or offset >= mr.span.end) continue;
            return mr.span;
        }
        return null;
    }

    fn handleDefinition(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const ctx = try self.extractRequest(id, params) orelse return;
        const pos = extractPosition(params) orelse return;
        const id_json = ctx.id_json;
        const uri = ctx.uri;
        const file_path = uriToFilePath(uri) orelse "";

        const doc = self.documents.get(file_path) orelse {
            return try self.sendResponse(id_json, "null");
        };
        const sema = doc.sema orelse doc.last_good_sema orelse {
            return try self.sendResponse(id_json, "null");
        };

        const offset = positionToOffset(doc.source, pos.line, pos.character) orelse {
            return try self.sendResponse(id_json, "null");
        };

        // 0. Cursor sits on a member's own declaration (struct field, method
        // name, enum variant). Go-to-definition resolves to itself so the
        // editor recognises it as a definition — clicking a definition then
        // surfaces references instead of doing nothing.
        if (selfMemberDefAt(&sema, offset)) |def_span| {
            const self_uri = try self.fileUri(doc.path);
            const loc = try lsp.locationJson(self.allocator, self_uri, spanToRange(doc.source, def_span));
            const arr = try std.fmt.allocPrint(self.allocator, "[{s}]", .{loc});
            return try self.sendResponse(id_json, arr);
        }

        // 0b. Member USE at offset — the (owner, name) index sema recorded at
        // the use site: `recv.method`/`recv.field` accesses, struct-literal
        // and push-literal field names. The owner was inferred in scope at
        // analysis time, so this beats the name-heuristic in step 1 (which
        // resolves a variable receiver by LAST symbol of that name file-wide
        // and can land on a different function's same-named local).
        if (memberUseAt(&sema, offset)) |mr| {
            if (mr.owner.len != 0) {
                if (std.mem.eql(u8, mr.owner, "Context")) {
                    if (try self.sendContextFieldDef(id_json, doc, mr.name, mr.span)) return;
                } else if (findMemberDefAcrossDocs(&self.documents, mr.owner, mr.name)) |def| {
                    if (try self.sendSpanLocation(id_json, def.doc, def.span, doc, mr.span)) return;
                }
            }
        }

        // 1. Qualified name (e.g. "std.print" or UFCS "list.append") — only
        // when the cursor is ON the member part; the origin span is just the
        // member, so the editor underlines `init`, not `BitWriter.init`. On
        // the receiver part the identifier steps below resolve the receiver.
        if (extractQualifiedName(doc.source, offset)) |qn| qualified: {
            const qn_origin = qualifiedMemberOrigin(qn, offset) orelse break :qualified;
            // `context.field` — the implicit context (not a declared symbol;
            // a user binding named `context` shadows it): resolve against the
            // program's assembled Context (extension declarations
            // program-wide, builtin fields in core.sx).
            if (std.mem.eql(u8, qn.ns, "context") and findSymbolByName(sema.symbols, "context") == null) {
                if (try self.sendContextFieldDef(id_json, doc, qn.member, qn_origin)) return;
            }
            // Namespace import member
            if (self.findImportByNs(doc, qn.ns)) |imp| {
                if (self.documents.get(imp.path)) |imp_doc| {
                    // C import source location: jump to the C header
                    if (imp_doc.c_source_locations.get(qn.member)) |cloc| {
                        if (try self.sendCSourceLocation(id_json, cloc, qn_origin, doc.source)) return;
                    }
                    // Single-file import
                    if (imp_doc.sema) |imp_sema| {
                        if (findSymbolByName(imp_sema.symbols, qn.member)) |si| {
                            const sym = imp_sema.symbols[si];
                            if (try self.sendSymbolLocationWithOrigin(id_json, imp_doc, sym, qn_origin)) return;
                        }
                    }
                } else {
                    // Directory import: search all documents whose path starts with the import directory
                    const dir_prefix = try std.fmt.allocPrint(self.allocator, "{s}/", .{imp.path});
                    var it = self.documents.by_path.iterator();
                    while (it.next()) |entry| {
                        if (!std.mem.startsWith(u8, entry.key_ptr.*, dir_prefix)) continue;
                        const dir_doc = entry.value_ptr.*;
                        if (dir_doc.sema) |dir_sema| {
                            if (findSymbolByName(dir_sema.symbols, qn.member)) |si| {
                                const sym = dir_sema.symbols[si];
                                if (try self.sendSymbolLocationWithOrigin(id_json, dir_doc, sym, qn_origin)) return;
                            }
                        }
                    }
                }
            }

            // Struct method/field: obj.method or Type.method or obj.field.
            // Before the UFCS guess — a member on the receiver's own type
            // wins over a same-named free function (language resolution order).
            if (try self.resolveStructMemberDef(id_json, sema, doc, qn.ns, qn.member, qn_origin)) return;

            // UFCS: obj.method → find free function "method"
            if (findSymbolByName(sema.symbols, qn.member)) |si| {
                const sym = sema.symbols[si];
                if (sym.kind == .function) {
                    if (try self.sendSymbolLocationWithOrigin(id_json, doc, sym, qn_origin)) return;
                }
            }
        }

        // 1b. Dot-shorthand: .method(args) — identifier preceded by dot with no qualifier
        if (extractIdentAtOffset(doc.source, offset)) |name| {
            const name_start = @as(u32, @intCast(@intFromPtr(name.ptr) - @intFromPtr(doc.source.ptr)));
            if (name_start > 0 and doc.source[name_start - 1] == '.' and
                (name_start < 2 or !isIdentChar(doc.source[name_start - 2])))
            {
                const name_end = name_start + @as(u32, @intCast(name.len));
                const origin = sx.ast.Span{ .start = name_start, .end = name_end };
                // Search all type declarations for a matching method/variant/field
                for (sema.symbols) |sym| {
                    if (sym.kind != .struct_type and sym.kind != .enum_type) continue;
                    const lookup = self.findTypeDeclNode(sema, doc, sym.name) orelse continue;
                    if (try self.sendMemberLocation(id_json, lookup, name, doc, origin)) return;
                }
            }
        }

        // 2. Reference at offset → jump to definition
        if (sx.sema.findReferenceAtOffset(sema.references, offset)) |ref_idx| {
            const ref = sema.references[ref_idx];
            if (ref.symbol_index < sema.symbols.len) {
                const sym = sema.symbols[ref.symbol_index];
                if (try self.sendSymbolLocationWithOrigin(id_json, doc, sym, ref.span)) return;
            }
        }

        // 3. Symbol definition name at offset
        if (findSymbolNameAtOffset(sema.symbols, doc.source, offset)) |sym_idx| {
            const sym = sema.symbols[sym_idx];
            if (try self.sendSymbolLocationWithOrigin(id_json, doc, sym, sym.def_span)) return;
        }

        // 4. #import "path" string → open the file (or directory)
        if (findImportPathAtOffset(doc.source, offset)) |import_path| {
            const base_dir = sx.imports.dirName(file_path);
            const rp: ?[]const u8 = if (self.root_path.len > 0) self.root_path else null;
            const resolved = try sx.imports.resolveImportPath(self.allocator, self.io, base_dir, import_path, rp, self.stdlib_paths);

            // For directory imports, try to read as file first
            if (std.Io.Dir.readFileAlloc(.cwd(), self.io, resolved, self.allocator, .limited(10 * 1024 * 1024))) |_| {
                // It's a file — navigate to it
                const target_uri = try self.fileUri(resolved);
                const range = lsp.Range{
                    .start = .{ .line = 0, .character = 0 },
                    .end = .{ .line = 0, .character = 0 },
                };
                const loc_json = try lsp.locationJson(self.allocator, target_uri, range);
                try self.sendResponse(id_json, loc_json);
                return;
            } else |_| {
                // Might be a directory — no single file to navigate to
            }
        }

        // 5. Fallback: identifier in string interpolation
        if (extractIdentAtOffset(doc.source, offset)) |name| {
            const name_start = @as(u32, @intCast(@intFromPtr(name.ptr) - @intFromPtr(doc.source.ptr)));
            const is_qualified = name_start > 0 and doc.source[name_start - 1] == '.';
            if (!is_qualified) {
                if (findSymbolByName(sema.symbols, name)) |si| {
                    const sym = sema.symbols[si];
                    const name_end = name_start + @as(u32, @intCast(name.len));
                    const origin = sx.ast.Span{ .start = name_start, .end = name_end };
                    if (try self.sendSymbolLocationWithOrigin(id_json, doc, sym, origin)) return;
                }
            }
        }

        try self.sendResponse(id_json, "null");
    }

    // ---- Hover ----

    fn handleHover(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const ctx = try self.extractRequest(id, params) orelse return;
        const pos = extractPosition(params) orelse return;
        const id_json = ctx.id_json;
        const file_path = uriToFilePath(ctx.uri) orelse "";

        const doc = self.documents.get(file_path) orelse {
            return try self.sendResponse(id_json, "null");
        };
        const sema = doc.sema orelse {
            return try self.sendResponse(id_json, "null");
        };
        const root = doc.root orelse {
            return try self.sendResponse(id_json, "null");
        };

        const offset = positionToOffset(doc.source, pos.line, pos.character) orelse {
            return try self.sendResponse(id_json, "null");
        };

        // Qualified name (e.g. std.print)
        if (extractQualifiedName(doc.source, offset)) |qn| {
            // `context.field` — Context field hover (declaration spelling +
            // declaring module for an extension; struct-field hover builtin).
            // Only when the cursor is on the FIELD part — on the `context`
            // part the bare-identifier branch below shows the whole
            // assembled Context instead.
            if (std.mem.eql(u8, qn.ns, "context") and findSymbolByName(sema.symbols, "context") == null and
                offset >= qn.full_end - @as(u32, @intCast(qn.member.len)))
            {
                if (try self.formatContextFieldHover(doc, qn.member)) |hover_text| {
                    const hover_json = try lsp.hoverJson(self.allocator, hover_text);
                    return try self.sendResponse(id_json, hover_json);
                }
            }
            // Namespace member hover
            if (self.findImportByNs(doc, qn.ns)) |imp| {
                if (self.documents.get(imp.path)) |imp_doc| {
                    if (imp_doc.root) |imp_root| {
                        if (findDeclByName(imp_root, qn.member)) |decl| {
                            const hover_text = try formatDeclHover(self.allocator, decl, imp_doc.source);
                            const hover_json = try lsp.hoverJson(self.allocator, hover_text);
                            return try self.sendResponse(id_json, hover_json);
                        }
                    }
                }
            }
            // Struct field hover (e.g. point.x)
            if (try self.formatStructFieldHover(doc, qn.ns, qn.member)) |hover_text| {
                const hover_json = try lsp.hoverJson(self.allocator, hover_text);
                return try self.sendResponse(id_json, hover_json);
            }
        }

        // Struct-literal / push-literal field name hover (a member USE with a
        // resolved owner — `push .{ ui = … }` hovers the Context field).
        if (memberUseAt(&sema, offset)) |mr| {
            if (mr.owner.len != 0) {
                const hover_text = if (std.mem.eql(u8, mr.owner, "Context"))
                    try self.formatContextFieldHover(doc, mr.name)
                else
                    try self.formatStructFieldHover(doc, mr.owner, mr.name);
                if (hover_text) |txt| {
                    const hover_json = try lsp.hoverJson(self.allocator, txt);
                    return try self.sendResponse(id_json, hover_json);
                }
            }
        }

        // Bare `context` identifier — the whole assembled Context in one
        // hover (builtin prefix + every `#context_extend` field, each with
        // its declaring module).
        if (extractIdentAtOffset(doc.source, offset)) |name| {
            if (std.mem.eql(u8, name, "context") and findSymbolByName(sema.symbols, "context") == null) {
                if (try self.formatContextHover(sema, doc)) |hover_text| {
                    const hover_json = try lsp.hoverJson(self.allocator, hover_text);
                    return try self.sendResponse(id_json, hover_json);
                }
            }
        }

        // Enum variant hover
        if (sx.sema.findNodeAtOffset(root, offset)) |node| {
            if (node.data == .enum_literal) {
                if (try self.formatEnumVariantHover(doc, node.data.enum_literal.name)) |hover_text| {
                    const hover_json = try lsp.hoverJson(self.allocator, hover_text);
                    return try self.sendResponse(id_json, hover_json);
                }
            }
        }

        // Find symbol via reference or definition name
        var sym_idx: ?usize = null;
        if (sx.sema.findReferenceAtOffset(sema.references, offset)) |ref_idx| {
            const si = sema.references[ref_idx].symbol_index;
            if (si < sema.symbols.len) sym_idx = si;
        } else {
            sym_idx = findSymbolNameAtOffset(sema.symbols, doc.source, offset);
        }

        // Fallback: identifier in string interpolation
        if (sym_idx == null) {
            if (extractIdentAtOffset(doc.source, offset)) |name| {
                const name_start = @as(u32, @intCast(@intFromPtr(name.ptr) - @intFromPtr(doc.source.ptr)));
                const is_qualified = name_start > 0 and doc.source[name_start - 1] == '.';
                if (!is_qualified) {
                    sym_idx = findSymbolByName(sema.symbols, name);
                }
            }
        }

        if (sym_idx) |si| {
            const sym = sema.symbols[si];
            // Resolve the right source and root for hover formatting
            const hover_doc = self.resolveSymbolDoc(doc, sym);
            const hover_root = hover_doc.root orelse root;
            const hover_text = try formatSymbolHover(self.allocator, sym, hover_root, hover_doc.source);
            const hover_json = try lsp.hoverJson(self.allocator, hover_text);
            return try self.sendResponse(id_json, hover_json);
        }

        try self.sendResponse(id_json, "null");
    }

    // ---- Document symbols ----

    fn handleDocumentSymbol(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const ctx = try self.extractRequest(id, params) orelse return;
        const id_json = ctx.id_json;
        const file_path = uriToFilePath(ctx.uri) orelse "";

        const doc = self.documents.get(file_path) orelse {
            return try self.sendResponse(id_json, "[]");
        };
        const sema = doc.sema orelse {
            return try self.sendResponse(id_json, "[]");
        };

        var doc_symbols = std.ArrayList(lsp.DocumentSymbol).empty;
        for (sema.symbols) |sym| {
            if (sym.scope_depth != 0) continue;
            // Only show symbols defined in this file
            if (sym.origin != null) continue;

            const kind: u32 = switch (sym.kind) {
                .function => @intFromEnum(lsp.SymbolKindLsp.Function),
                .variable => @intFromEnum(lsp.SymbolKindLsp.Variable),
                .constant => @intFromEnum(lsp.SymbolKindLsp.Constant),
                .enum_type => @intFromEnum(lsp.SymbolKindLsp.Enum),
                .struct_type => @intFromEnum(lsp.SymbolKindLsp.Struct),
                .protocol_type => @intFromEnum(lsp.SymbolKindLsp.Interface),
                .type_alias => @intFromEnum(lsp.SymbolKindLsp.Class),
                .param => @intFromEnum(lsp.SymbolKindLsp.Variable),
                .namespace => @intFromEnum(lsp.SymbolKindLsp.Namespace),
            };

            const range = spanToRange(doc.source, sym.def_span);
            try doc_symbols.append(self.allocator, .{
                .name = sym.name,
                .kind = kind,
                .range = range,
                .selection_range = range,
            });
        }

        const symbols_json = try lsp.documentSymbolsJson(self.allocator, doc_symbols.items);
        try self.sendResponse(id_json, symbols_json);
    }

    // ---- Completion ----

    fn handleCompletion(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const ctx = try self.extractRequest(id, params) orelse return;
        const pos = extractPosition(params) orelse return;
        const id_json = ctx.id_json;
        const file_path = uriToFilePath(ctx.uri) orelse "";

        const doc = self.documents.get(file_path) orelse {
            return try self.sendResponse(id_json, "[]");
        };

        // Check if cursor is after a dot
        if (positionToOffset(doc.source, pos.line, pos.character)) |off| {
            var scan = off;
            while (scan > 0 and isIdentChar(doc.source[scan - 1])) scan -= 1;
            if (scan > 0 and doc.source[scan - 1] == '.') {
                try self.handleDotCompletion(id_json, doc, scan);
                return;
            }
        }

        // Regular completion: all in-scope symbols + keywords
        // Fall back to last successful analysis when current parse/analysis fails
        // (common while user is mid-typing)
        const sema = doc.sema orelse doc.last_good_sema orelse {
            return try self.sendResponse(id_json, "[]");
        };

        var items = std.ArrayList(lsp.CompletionItem).empty;

        // Inside a `push .{ … }` literal the field-name position patches
        // Context fields — offer the assembled field set first (clients rank
        // these above the general symbols below).
        if (positionToOffset(doc.source, pos.line, pos.character)) |off| {
            if (insidePushLiteral(doc.source, off)) {
                try self.appendContextFieldCompletions(&items, sema, doc);
            }
        }

        for (sema.symbols) |sym| {
            const kind: u32 = switch (sym.kind) {
                .function => @intFromEnum(lsp.CompletionItemKind.Function),
                .variable => @intFromEnum(lsp.CompletionItemKind.Variable),
                .constant => @intFromEnum(lsp.CompletionItemKind.Constant),
                .enum_type => @intFromEnum(lsp.CompletionItemKind.Enum),
                .struct_type => @intFromEnum(lsp.CompletionItemKind.Struct),
                .protocol_type => @intFromEnum(lsp.CompletionItemKind.Interface),
                .type_alias => @intFromEnum(lsp.CompletionItemKind.Class),
                .param => @intFromEnum(lsp.CompletionItemKind.Variable),
                .namespace => @intFromEnum(lsp.CompletionItemKind.Module),
            };

            const detail = if (sym.ty) |ty| try ty.displayName(self.allocator) else null;

            try items.append(self.allocator, .{
                .label = sym.name,
                .kind = kind,
                .detail = detail,
            });
        }

        const keywords = [_][]const u8{
            "if",       "else",  "then",    "return",    "defer",
            "case",     "break", "enum",    "struct",    "true",
            "false",    "xx",    "while",   "continue",
            "and",      "or",    "union",
        };

        const builtins = [_]struct { label: []const u8, detail: []const u8 }{
            .{ .label = "type_of", .detail = "(val: $T) -> Type" },
            .{ .label = "type_name", .detail = "(T | tp: Type) -> string" },
            .{ .label = "type_info", .detail = "(T | tp: Type) -> TypeInfo — kind-first reflection (needs std/meta)" },
            .{ .label = "type_eq", .detail = "(A: Type, B: Type) -> bool" },
            .{ .label = "is_unsigned", .detail = "(T | tp: Type) -> bool" },
            .{ .label = "is_flags", .detail = "(T | tp: Type) -> bool" },
            .{ .label = "is_identity", .detail = "($T: Type) -> bool — is T an #identity protocol (compile-time only)" },
            .{ .label = "is_struct", .detail = "($T: Type) -> bool" },
            .{ .label = "pointee_type", .detail = "($P: Type) -> Type — *X -> X" },
            .{ .label = "struct_field_count", .detail = "(T | tp: Type) -> i64 — struct/tuple fields" },
            .{ .label = "struct_field_name", .detail = "(T | tp: Type, idx: i64) -> string" },
            .{ .label = "struct_field_type", .detail = "(T | tp: Type, idx: i64) -> Type" },
            .{ .label = "struct_field_offset", .detail = "(T | tp: Type, idx: i64) -> i64 — byte offset" },
            .{ .label = "struct_field_value", .detail = "(s: $T, idx: i64) -> any" },
            .{ .label = "variant_count", .detail = "(E | tp: Type) -> i64 — enum/tagged-union variants" },
            .{ .label = "variant_name", .detail = "(E | tp: Type, idx: i64) -> string" },
            .{ .label = "variant_type", .detail = "(E | tp: Type, idx: i64) -> Type — payload type" },
            .{ .label = "variant_value", .detail = "(E | tp: Type, idx: i64) -> i64 — variant's integer value" },
            .{ .label = "variant_index", .detail = "(E | tp: Type, val: E | av: any) -> i64 — value -> ordinal" },
            .{ .label = "variant_payload", .detail = "(u: $E, idx: i64) -> any — live payload" },
            .{ .label = "vector_lanes", .detail = "(T | tp: Type) -> i64 — vector lane count" },
            .{ .label = "any_element", .detail = "(av: any, elem: Type, idx: i64) -> any — array/vector element view" },
            .{ .label = "raw_any_data", .detail = "(av: any) -> *void — the view's data pointer" },
            .{ .label = "raw_make_any", .detail = "(tp: Type, data: *void) -> any — assemble a view (unchecked)" },
            .{ .label = "error_name", .detail = "(e: $T) -> string" },
            .{ .label = "size_of", .detail = "(T | tp: Type) -> i64" },
            .{ .label = "align_of", .detail = "(T | tp: Type) -> i64" },
            .{ .label = "has_impl", .detail = "(P, T: Type) -> bool" },
            .{ .label = "malloc", .detail = "(size: i64) -> *void" },
            .{ .label = "memcpy", .detail = "(dst: *void, src: *void, size: i64) -> *void" },
            .{ .label = "memset", .detail = "(dst: *void, val: i64, size: i64) -> void" },
            .{ .label = "sqrt", .detail = "(x: $T) -> T" },
        };
        for (&keywords) |kw| {
            try items.append(self.allocator, .{
                .label = kw,
                .kind = @intFromEnum(lsp.CompletionItemKind.Keyword),
            });
        }
        for (&builtins) |b| {
            try items.append(self.allocator, .{
                .label = b.label,
                .kind = @intFromEnum(lsp.CompletionItemKind.Function),
                .detail = b.detail,
            });
        }

        const items_json = try lsp.completionItemsJson(self.allocator, items.items);
        try self.sendResponse(id_json, items_json);
    }

    fn handleDotCompletion(self: *Server, id_json: []const u8, doc: *const Document, cursor_offset: u32) !void {
        var items = std.ArrayList(lsp.CompletionItem).empty;

        if (extractDotPrefix(doc.source, cursor_offset)) |prefix| {
            if (doc.sema orelse doc.last_good_sema) |sema| {
                // `context.` — the assembled Context's fields: the builtin
                // prefix plus every `#context_extend` field in the workspace.
                if (std.mem.eql(u8, prefix, "context") and findSymbolByName(sema.symbols, "context") == null) {
                    try self.appendContextFieldCompletions(&items, sema, doc);
                    if (items.items.len > 0) {
                        const items_json = try lsp.completionItemsJson(self.allocator, items.items);
                        return try self.sendResponse(id_json, items_json);
                    }
                }
                // Check if prefix is a namespace — offer imported doc's declarations
                if (self.findImportByNs(doc, prefix)) |imp| {
                    if (self.documents.get(imp.path)) |imp_doc| {
                        if (imp_doc.root) |imp_root| {
                            if (imp_root.data == .root) {
                                try collectDeclCompletions(self.allocator, &items, imp_root.data.root.decls);
                            }
                        }
                    }
                } else if (doc.root) |root| {
                    // Try as type name directly (e.g. Vec2., Color.)
                    try self.collectMemberCompletions(&items, sema, doc, prefix);

                    // Try as variable name — resolve to type and offer fields + UFCS methods
                    if (items.items.len == 0) {
                        if (resolveVariableType(sema, prefix)) |type_name| {
                            try self.collectMemberCompletions(&items, sema, doc, type_name);
                            try self.collectUfcsCompletions(&items, root, type_name);
                        }
                    }
                }
            }
            // Fallback: try resolving as a match arm capture variable (works without current parse)
            if (items.items.len == 0) {
                try self.collectCaptureCompletions(&items, doc, cursor_offset, prefix);
            }
        } else {
            // Bare dot (no prefix) — check if we're inside a match expression
            // and offer the subject's enum variants (e.g. case .quit)
            try self.collectMatchEnumCompletions(&items, doc, cursor_offset);
        }

        const items_json = try lsp.completionListJson(self.allocator, items.items);
        try self.sendResponse(id_json, items_json);
    }

    fn collectMatchEnumCompletions(self: *Server, items: *std.ArrayList(lsp.CompletionItem), doc: *const Document, cursor_offset: u32) !void {
        // Text-based approach: scan backward from cursor to find enclosing "SUBJECT == {"
        // This works even when the file has parse errors (user is mid-typing)
        const subject_name = findMatchSubjectText(doc.source, cursor_offset) orelse return;

        // Use sema (current or last successful) to resolve the subject's type
        const sema = doc.sema orelse doc.last_good_sema orelse return;

        // Resolve subject name to an enum type
        const enum_name = self.resolveExprEnumType(sema, subject_name) orelse return;

        // Use enum variant names directly from sema symbols (works even without doc.root)
        for (sema.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, enum_name)) continue;
            if (sym.kind != .enum_type) continue;

            // Find the enum_decl node in the origin doc (or main doc)
            const lookup_doc = if (sym.origin) |origin_path|
                self.documents.get(origin_path)
            else
                null;
            const lookup_root = if (lookup_doc) |ld| ld.root orelse doc.root else doc.root;
            const root = lookup_root orelse continue;

            if (sx.sema.findNodeAtOffset(root, sym.def_span.start)) |node| {
                if (node.data == .enum_decl) {
                    for (node.data.enum_decl.variant_names) |variant| {
                        try items.append(self.allocator, .{
                            .label = variant,
                            .kind = @intFromEnum(lsp.CompletionItemKind.EnumMember),
                        });
                    }
                }
            }
            break;
        }
    }

    /// Scan backward through source text to find the subject of an enclosing match expression.
    /// Looks for the pattern: SUBJECT == { ... case .
    /// Returns the subject text (e.g. "event", "e.key") or null.
    fn findMatchSubjectText(source: []const u8, cursor_offset: u32) ?[]const u8 {
        var pos: u32 = cursor_offset;
        var brace_depth: u32 = 0;

        // Walk backward, tracking brace depth, looking for "== {"
        while (pos > 2) {
            pos -= 1;
            const ch = source[pos];
            if (ch == '}') {
                brace_depth += 1;
            } else if (ch == '{') {
                if (brace_depth > 0) {
                    brace_depth -= 1;
                } else {
                    // Found an unmatched '{' — check if preceded by "=="
                    var scan = pos;
                    while (scan > 0 and std.ascii.isWhitespace(source[scan - 1])) scan -= 1;
                    if (scan >= 2 and source[scan - 1] == '=' and source[scan - 2] == '=') {
                        // Found "== {" — extract the subject before "=="
                        var end = scan - 2;
                        while (end > 0 and std.ascii.isWhitespace(source[end - 1])) end -= 1;
                        if (end == 0) return null;
                        var start = end;
                        while (start > 0 and (isIdentChar(source[start - 1]) or source[start - 1] == '.')) {
                            start -= 1;
                        }
                        if (start < end) return source[start..end];
                    }
                    // Not a match expr — but keep scanning (might be a nested block)
                }
            }
        }
        return null;
    }

    /// Resolve a capture variable's struct type by scanning backward for `case .VARIANT: (name)`
    /// and looking up the variant's payload type in the enum declaration.
    fn collectCaptureCompletions(self: *Server, items: *std.ArrayList(lsp.CompletionItem), doc: *const Document, cursor_offset: u32, var_name: []const u8) !void {
        const sema = doc.sema orelse doc.last_good_sema orelse return;

        // Scan backward from cursor to find: case .VARIANT: (var_name)
        const variant_name = findCaptureVariant(doc.source, cursor_offset, var_name) orelse return;

        // Find the enclosing match subject
        const subject_name = findMatchSubjectText(doc.source, cursor_offset) orelse return;

        // Resolve subject to an enum type
        const enum_name = self.resolveExprEnumType(sema, subject_name) orelse return;

        // Find the enum_decl and look up the variant's payload type
        for (sema.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, enum_name)) continue;
            if (sym.kind != .enum_type) continue;

            const lookup_doc = if (sym.origin) |origin_path|
                self.documents.get(origin_path)
            else
                null;
            const lookup_root = if (lookup_doc) |ld| ld.root orelse doc.root else doc.root;
            const root = lookup_root orelse continue;

            if (sx.sema.findNodeAtOffset(root, sym.def_span.start)) |node| {
                if (node.data == .enum_decl) {
                    const ed = node.data.enum_decl;
                    // Find the matching variant and its payload type
                    for (ed.variant_names, 0..) |vn, vi| {
                        if (!std.mem.eql(u8, vn, variant_name)) continue;
                        if (vi >= ed.variant_types.len) break;
                        const vt = ed.variant_types[vi] orelse break;
                        // The payload type should be a struct — get its name
                        const payload_type_name = if (vt.data == .type_expr) vt.data.type_expr.name else break;
                        // Now offer that struct's fields
                        const payload_sema = if (lookup_doc) |ld| ld.sema orelse sema else sema;
                        const payload_doc = if (lookup_doc) |ld| ld else doc;
                        try self.collectMemberCompletions(items, payload_sema, payload_doc, payload_type_name);
                        return;
                    }
                }
            }
            break;
        }
    }

    /// Scan backward from cursor to find `case .VARIANT: (var_name)` and return VARIANT.
    fn findCaptureVariant(source: []const u8, cursor_offset: u32, var_name: []const u8) ?[]const u8 {
        // Look backward for pattern: case .VARIANT: (var_name)
        // We search for "(var_name)" first, then look for "case .VARIANT:" before it
        var pos: u32 = cursor_offset;
        while (pos > var_name.len + 10) { // need room for "case .X: (name)"
            pos -= 1;
            // Look for the closing ) of a capture
            if (source[pos] != ')') continue;
            // Check if the capture name matches
            if (pos < var_name.len + 1) continue;
            const name_end = pos;
            const name_start = pos - @as(u32, @intCast(var_name.len));
            if (!std.mem.eql(u8, source[name_start..name_end], var_name)) continue;
            // Check for ( before the name
            if (name_start < 1 or source[name_start - 1] != '(') continue;

            // Now scan backward from '(' to find ": " then ".VARIANT" then "case "
            var scan = name_start - 1;
            // Skip whitespace
            while (scan > 0 and std.ascii.isWhitespace(source[scan - 1])) scan -= 1;
            // Expect ':'
            if (scan < 1 or source[scan - 1] != ':') continue;
            scan -= 1;
            // Now extract the variant name: scan backward for ".VARIANT"
            // Skip whitespace before ':'
            // The variant is an enum literal like .key_down
            // Actually the ':' comes right after the variant value (explicit) or variant name
            // Pattern: case .VARIANT: (name) OR case .VARIANT :: 0x300: PayloadType;... nah
            // In the match arm: case .key_down: (e) {
            // So before ':' we have the enum literal .key_down
            while (scan > 0 and std.ascii.isWhitespace(source[scan - 1])) scan -= 1;
            // Extract identifier (variant name)
            const vend = scan;
            while (scan > 0 and (isIdentChar(source[scan - 1]))) scan -= 1;
            if (scan >= vend) continue;
            const variant = source[scan..vend];
            // Check for '.' before variant name
            if (scan < 1 or source[scan - 1] != '.') continue;

            return variant;
        }
        return null;
    }

    /// Resolve a text expression like "event" or "e.key" to an enum/union type name.
    fn resolveExprEnumType(self: *Server, sema: SemaResult, expr: []const u8) ?[]const u8 {
        // Simple identifier: look up variable type
        if (std.mem.indexOfScalar(u8, expr, '.') == null) {
            for (sema.symbols) |sym| {
                if (!std.mem.eql(u8, sym.name, expr)) continue;
                if (sym.kind != .variable and sym.kind != .param) continue;
                const ty = sym.ty orelse return null;
                return switch (ty) {
                    .enum_type => |n| n,
                    .union_type => |n| n,
                    else => null,
                };
            }
            return null;
        }

        // Field access: "var.field" — resolve var's struct type, then look up field
        if (std.mem.indexOfScalar(u8, expr, '.')) |dot| {
            const var_name = expr[0..dot];
            const field_name = expr[dot + 1 ..];
            for (sema.symbols) |sym| {
                if (!std.mem.eql(u8, sym.name, var_name)) continue;
                const ty = sym.ty orelse return null;
                const struct_name = switch (ty) {
                    .struct_type => |n| n,
                    else => return null,
                };
                if (sema.struct_types.get(struct_name)) |info| {
                    for (info.field_names, 0..) |fname, fi| {
                        if (std.mem.eql(u8, fname, field_name) and fi < info.field_types.len) {
                            return switch (info.field_types[fi]) {
                                .enum_type => |n| n,
                                .union_type => |n| n,
                                else => null,
                            };
                        }
                    }
                }
                // Also check imported docs for struct info
                if (sym.origin) |origin_path| {
                    if (self.documents.get(origin_path)) |od| {
                        if (od.sema) |imp_sema| {
                            if (imp_sema.struct_types.get(struct_name)) |info| {
                                for (info.field_names, 0..) |fname, fi| {
                                    if (std.mem.eql(u8, fname, field_name) and fi < info.field_types.len) {
                                        return switch (info.field_types[fi]) {
                                            .enum_type => |n| n,
                                            .union_type => |n| n,
                                            else => null,
                                        };
                                    }
                                }
                            }
                        }
                    }
                }
                return null;
            }
        }

        return null;
    }

    fn collectDeclCompletions(allocator: std.mem.Allocator, items: *std.ArrayList(lsp.CompletionItem), decls: []const *sx.ast.Node) !void {
        for (decls) |decl| {
            // Namespace-member completion offers ANOTHER file's declarations;
            // its private names are not part of that surface.
            if (decl.visibility == .private) continue;
            switch (decl.data) {
                .fn_decl => |fd| {
                    var detail_buf = std.ArrayList(u8).empty;
                    try detail_buf.append(allocator, '(');
                    for (fd.params, 0..) |param, pi| {
                        if (pi > 0) try detail_buf.appendSlice(allocator, ", ");
                        try detail_buf.appendSlice(allocator, param.name);
                        if (param.type_expr.data != .inferred_type) {
                            try detail_buf.appendSlice(allocator, ": ");
                            if (param.type_expr.data == .type_expr) {
                                try detail_buf.appendSlice(allocator, param.type_expr.data.type_expr.name);
                            } else {
                                try detail_buf.appendSlice(allocator, "?");
                            }
                        }
                    }
                    try detail_buf.append(allocator, ')');
                    if (fd.return_type) |rt| {
                        try detail_buf.appendSlice(allocator, " -> ");
                        if (rt.data == .type_expr) {
                            try detail_buf.appendSlice(allocator, rt.data.type_expr.name);
                        }
                    }
                    try items.append(allocator, .{
                        .label = fd.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Function),
                        .detail = detail_buf.items,
                    });
                },
                .const_decl => |cd| {
                    const kind: u32 = if (cd.value.data == .lambda)
                        @intFromEnum(lsp.CompletionItemKind.Function)
                    else
                        @intFromEnum(lsp.CompletionItemKind.Constant);
                    try items.append(allocator, .{
                        .label = cd.name,
                        .kind = kind,
                    });
                },
                .enum_decl => |ed| {
                    try items.append(allocator, .{
                        .label = ed.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Enum),
                    });
                },
                .struct_decl => |sd| {
                    try items.append(allocator, .{
                        .label = sd.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Struct),
                    });
                },
                .union_decl => |ud| {
                    try items.append(allocator, .{
                        .label = ud.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Struct),
                    });
                },
                .protocol_decl => |pd| {
                    try items.append(allocator, .{
                        .label = pd.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Interface),
                    });
                },
                .var_decl => |vd| {
                    try items.append(allocator, .{
                        .label = vd.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Variable),
                    });
                },
                else => {},
            }
        }
    }

    fn collectMemberCompletions(self: *Server, items: *std.ArrayList(lsp.CompletionItem), sema: SemaResult, doc: *const Document, name: []const u8) !void {
        const lookup = self.findTypeDeclNode(sema, doc, name) orelse return;
        const node = lookup.node;

        if (node.data == .struct_decl) {
            const sd = node.data.struct_decl;
            for (sd.field_names, 0..) |field_name, fi| {
                const detail: ?[]const u8 = if (fi < sd.field_types.len) blk: {
                    const ft = sd.field_types[fi];
                    break :blk if (ft.data == .type_expr) ft.data.type_expr.name else null;
                } else null;

                try items.append(self.allocator, .{
                    .label = field_name,
                    .kind = @intFromEnum(lsp.CompletionItemKind.Field),
                    .detail = detail,
                });
            }
            for (sd.methods) |method_node| {
                if (method_node.data == .fn_decl) {
                    try items.append(self.allocator, .{
                        .label = method_node.data.fn_decl.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Method),
                    });
                }
            }
        } else if (node.data == .enum_decl) {
            const ed = node.data.enum_decl;
            for (ed.variant_names) |variant| {
                try items.append(self.allocator, .{
                    .label = variant,
                    .kind = @intFromEnum(lsp.CompletionItemKind.EnumMember),
                });
            }
        } else if (node.data == .protocol_decl) {
            const pd = node.data.protocol_decl;
            for (pd.methods) |method| {
                // Build detail string: (params) -> ret
                var detail_buf = std.ArrayList(u8).empty;
                try detail_buf.append(self.allocator, '(');
                for (method.param_names, 0..) |pname, pi| {
                    if (pi > 0) try detail_buf.appendSlice(self.allocator, ", ");
                    try detail_buf.appendSlice(self.allocator, pname);
                    if (pi < method.params.len) {
                        try detail_buf.appendSlice(self.allocator, ": ");
                        if (method.params[pi].data == .type_expr) {
                            try detail_buf.appendSlice(self.allocator, method.params[pi].data.type_expr.name);
                        }
                    }
                }
                try detail_buf.append(self.allocator, ')');
                if (method.return_type) |rt| {
                    try detail_buf.appendSlice(self.allocator, " -> ");
                    if (rt.data == .type_expr) {
                        try detail_buf.appendSlice(self.allocator, rt.data.type_expr.name);
                    }
                }
                try items.append(self.allocator, .{
                    .label = method.name,
                    .kind = @intFromEnum(lsp.CompletionItemKind.Method),
                    .detail = detail_buf.items,
                });
            }
        }
    }

    // ---- Signature help ----

    fn handleSignatureHelp(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const req = try self.extractRequest(id, params) orelse return;
        const pos = extractPosition(params) orelse return;
        const id_json = req.id_json;
        const file_path = uriToFilePath(req.uri) orelse "";

        const doc = self.documents.get(file_path) orelse {
            return try self.sendResponse(id_json, "null");
        };

        const offset = positionToOffset(doc.source, pos.line, pos.character) orelse {
            return try self.sendResponse(id_json, "null");
        };

        const call_ctx = findCallContext(doc.source, offset) orelse {
            return try self.sendResponse(id_json, "null");
        };

        // Built-in function signatures
        const builtin_sigs = [_]struct { name: []const u8, label: []const u8, params: []const []const u8 }{
            .{ .name = "type_of", .label = "type_of(val: $T) -> Type", .params = &.{"val: $T"} },
            .{ .name = "type_name", .label = "type_name($T: Type) -> string", .params = &.{"$T: Type"} },
            .{ .name = "struct_field_count", .label = "struct_field_count(T: Type) -> i64", .params = &.{"T: Type"} },
            .{ .name = "struct_field_name", .label = "struct_field_name(T: Type, idx: i64) -> string", .params = &.{ "T: Type", "idx: i64" } },
            .{ .name = "struct_field_type", .label = "struct_field_type(T: Type, idx: i64) -> Type", .params = &.{ "T: Type", "idx: i64" } },
            .{ .name = "struct_field_offset", .label = "struct_field_offset(T: Type, idx: i64) -> i64", .params = &.{ "T: Type", "idx: i64" } },
            .{ .name = "struct_field_value", .label = "struct_field_value(s: $T, idx: i64) -> any", .params = &.{ "s: $T", "idx: i64" } },
            .{ .name = "variant_count", .label = "variant_count(E: Type) -> i64", .params = &.{"E: Type"} },
            .{ .name = "variant_name", .label = "variant_name(E: Type, idx: i64) -> string", .params = &.{ "E: Type", "idx: i64" } },
            .{ .name = "variant_type", .label = "variant_type(E: Type, idx: i64) -> Type", .params = &.{ "E: Type", "idx: i64" } },
            .{ .name = "variant_value", .label = "variant_value(E: Type, idx: i64) -> i64", .params = &.{ "E: Type", "idx: i64" } },
            .{ .name = "variant_index", .label = "variant_index(E: Type, val: E) -> i64", .params = &.{ "E: Type", "val: E" } },
            .{ .name = "variant_payload", .label = "variant_payload(u: $E, idx: i64) -> any", .params = &.{ "u: $E", "idx: i64" } },
            .{ .name = "vector_lanes", .label = "vector_lanes(T: Type) -> i64", .params = &.{"T: Type"} },
            .{ .name = "any_element", .label = "any_element(av: any, elem: Type, idx: i64) -> any", .params = &.{ "av: any", "elem: Type", "idx: i64" } },
            .{ .name = "raw_any_data", .label = "raw_any_data(av: any) -> *void", .params = &.{"av: any"} },
            .{ .name = "raw_make_any", .label = "raw_make_any(tp: Type, data: *void) -> any", .params = &.{ "tp: Type", "data: *void" } },
            .{ .name = "type_info", .label = "type_info(T: Type) -> TypeInfo", .params = &.{"T: Type"} },
            .{ .name = "pointee_type", .label = "pointee_type(P: Type) -> Type", .params = &.{"P: Type"} },
            .{ .name = "is_unsigned", .label = "is_unsigned(T: Type) -> bool", .params = &.{"T: Type"} },
            .{ .name = "error_name", .label = "error_name(e: $T) -> string", .params = &.{"e: $T"} },
            .{ .name = "size_of", .label = "size_of($T: Type) -> i64", .params = &.{"$T: Type"} },
            .{ .name = "align_of", .label = "align_of($T: Type) -> i64", .params = &.{"$T: Type"} },
            .{ .name = "malloc", .label = "malloc(size: i64) -> *void", .params = &.{"size: i64"} },
            .{ .name = "memcpy", .label = "memcpy(dst: *void, src: *void, size: i64) -> *void", .params = &.{ "dst: *void", "src: *void", "size: i64" } },
            .{ .name = "memset", .label = "memset(dst: *void, val: i64, size: i64) -> void", .params = &.{ "dst: *void", "val: i64", "size: i64" } },
            .{ .name = "sqrt", .label = "sqrt(x: $T) -> T", .params = &.{"x: $T"} },
            .{ .name = "print", .label = "print(fmt: string, args: ..any)", .params = &.{ "fmt: string", "args: ..any" } },
            .{ .name = "out", .label = "out(str: string) -> void", .params = &.{"str: string"} },
        };
        for (&builtin_sigs) |b| {
            const matches = std.mem.eql(u8, call_ctx.name, b.name) or
                (std.mem.startsWith(u8, call_ctx.name, "std.") and std.mem.eql(u8, call_ctx.name[4..], b.name));
            if (matches) {
                const sig_json = try lsp.signatureHelpJson(self.allocator, b.label, b.params, call_ctx.active_param);
                return try self.sendResponse(id_json, sig_json);
            }
        }

        // Look up function declaration
        const fn_node = self.findFnDeclByName(doc, call_ctx.name);

        if (fn_node) |fd| {
            var label_buf = std.ArrayList(u8).empty;
            try label_buf.appendSlice(self.allocator, fd.name);
            try label_buf.append(self.allocator, '(');

            var param_labels = std.ArrayList([]const u8).empty;
            for (fd.params, 0..) |param, pi| {
                if (pi > 0) try label_buf.appendSlice(self.allocator, ", ");
                const param_start = label_buf.items.len;
                try label_buf.appendSlice(self.allocator, param.name);
                if (param.type_expr.data != .inferred_type) {
                    try label_buf.appendSlice(self.allocator, ": ");
                    if (param.type_expr.data == .type_expr) {
                        try label_buf.appendSlice(self.allocator, param.type_expr.data.type_expr.name);
                    } else {
                        try label_buf.appendSlice(self.allocator, "?");
                    }
                }
                const param_label = try self.allocator.dupe(u8, label_buf.items[param_start..]);
                try param_labels.append(self.allocator, param_label);
            }
            try label_buf.append(self.allocator, ')');

            if (fd.return_type) |rt| {
                try label_buf.appendSlice(self.allocator, " -> ");
                if (rt.data == .type_expr) {
                    try label_buf.appendSlice(self.allocator, rt.data.type_expr.name);
                }
            }

            const sig_json = try lsp.signatureHelpJson(self.allocator, label_buf.items, param_labels.items, call_ctx.active_param);
            return try self.sendResponse(id_json, sig_json);
        }

        try self.sendResponse(id_json, "null");
    }

    // ---- Semantic tokens ----

    fn handleSemanticTokens(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const ctx = try self.extractRequest(id, params) orelse return;
        const id_json = ctx.id_json;
        const file_path = uriToFilePath(ctx.uri) orelse "";

        const doc = self.documents.get(file_path) orelse {
            return try self.sendResponse(id_json, "{\"data\":[]}");
        };
        const sema = doc.sema orelse {
            return try self.sendResponse(id_json, "{\"data\":[]}");
        };

        var data = std.ArrayList(u32).empty;
        var prev_line: u32 = 0;
        var prev_char: u32 = 0;

        var lexer = sx.lexer.Lexer.init(doc.source);
        while (true) {
            const tok = lexer.next();
            if (tok.tag == .eof) break;

            if (tok.tag == .string_literal or tok.tag == .raw_string_literal) {
                try emitStringParts(&data, self.allocator, doc.source, tok.loc.start, tok.loc.end, &prev_line, &prev_char);
                continue;
            }

            const token_type = classifyToken(tok, sema, doc.source) orelse continue;
            try emitToken(&data, self.allocator, doc.source, tok.loc.start, tok.loc.end, token_type, &prev_line, &prev_char);
        }

        const result_json = try lsp.semanticTokensJson(self.allocator, data.items);
        try self.sendResponse(id_json, result_json);
    }

    // ---- Inlay hints ----

    fn handleInlayHint(self: *Server, id: ?std.json.Value, params: std.json.Value) !void {
        const ctx = try self.extractRequest(id, params) orelse return;
        const id_json = ctx.id_json;
        const file_path = uriToFilePath(ctx.uri) orelse "";

        const doc = self.documents.get(file_path) orelse {
            return try self.sendResponse(id_json, "[]");
        };
        const sema = doc.sema orelse doc.last_good_sema orelse {
            return try self.sendResponse(id_json, "[]");
        };
        const root = doc.root orelse {
            return try self.sendResponse(id_json, "[]");
        };

        var hints = std.ArrayList(lsp.InlayHint).empty;
        collectInlayHints(self.allocator, root, sema.symbols, sema.fn_signatures, doc.source, &hints);
        self.collectCallHints(doc, root, &hints);
        const result_json = try lsp.inlayHintsJson(self.allocator, hints.items);
        try self.sendResponse(id_json, result_json);
    }

    fn collectInlayHints(
        allocator: std.mem.Allocator,
        node: *const sx.ast.Node,
        symbols: []const sx.sema.Symbol,
        fn_signatures: std.StringHashMap(sx.sema.FnSignature),
        source: [:0]const u8,
        hints: *std.ArrayList(lsp.InlayHint),
    ) void {
        switch (node.data) {
            .root => |r| {
                for (r.decls) |decl| collectInlayHints(allocator, decl, symbols, fn_signatures, source, hints);
            },
            .block => |b| {
                for (b.stmts) |stmt| collectInlayHints(allocator, stmt, symbols, fn_signatures, source, hints);
            },
            .fn_decl => |fd| {
                collectInlayHints(allocator, fd.body, symbols, fn_signatures, source, hints);
                // Return type hint for arrow functions without explicit return type
                if (fd.return_type == null and fd.is_arrow) {
                    if (fn_signatures.get(fd.name)) |sig| {
                        if (sig.return_type != .void_type) {
                            addReturnTypeHint(allocator, node.span, source, sig.return_type, hints);
                        }
                    }
                }
            },
            .lambda => |lm| {
                collectInlayHints(allocator, lm.body, symbols, fn_signatures, source, hints);
            },
            .if_expr => |ie| {
                if (ie.binding_name) |bname| {
                    addBindingHint(allocator, bname, node.span, symbols, source, hints);
                }
                collectInlayHints(allocator, ie.then_branch, symbols, fn_signatures, source, hints);
                if (ie.else_branch) |eb| collectInlayHints(allocator, eb, symbols, fn_signatures, source, hints);
            },
            .while_expr => |we| {
                if (we.binding_name) |bname| {
                    addBindingHint(allocator, bname, node.span, symbols, source, hints);
                }
                collectInlayHints(allocator, we.body, symbols, fn_signatures, source, hints);
            },
            .for_expr => |fe| {
                for (fe.captures) |cap| {
                    if (!std.mem.eql(u8, cap.name, "_")) {
                        addForCaptureHint(allocator, cap.name, node.span, symbols, source, hints);
                    }
                }
                collectInlayHints(allocator, fe.body, symbols, fn_signatures, source, hints);
            },
            .struct_decl => |sd| {
                for (sd.methods) |m| collectInlayHints(allocator, m, symbols, fn_signatures, source, hints);
            },
            .var_decl => |vd| {
                // Only show hint when type is inferred (:= syntax)
                if (vd.type_annotation != null) return;
                if (vd.value == null) return;
                addHintForDecl(allocator, vd.name, node.span, symbols, source, hints, true);
            },
            .const_decl => |cd| {
                // Skip if explicit type annotation
                if (cd.type_annotation != null) return;
                // Handle lambda with return type hint
                if (cd.value.data == .lambda) {
                    const lam = cd.value.data.lambda;
                    collectInlayHints(allocator, lam.body, symbols, fn_signatures, source, hints);
                    if (lam.return_type == null) {
                        if (fn_signatures.get(cd.name)) |sig| {
                            if (sig.return_type != .void_type) {
                                addReturnTypeHint(allocator, cd.value.span, source, sig.return_type, hints);
                            }
                        }
                    }
                    return;
                }
                // Struct methods carry their own bodies — descend so locals
                // (and `for` captures) inside them get hints too.
                if (cd.value.data == .struct_decl) {
                    for (cd.value.data.struct_decl.methods) |m| {
                        collectInlayHints(allocator, m, symbols, fn_signatures, source, hints);
                    }
                    return;
                }
                // Skip functions, types, structs, enums, unions, comptime, extern, library
                switch (cd.value.data) {
                    .fn_decl, .type_expr, .struct_decl, .enum_decl, .union_decl,
                    .comptime_expr, .library_decl,
                    => return,
                    else => {},
                }
                addHintForDecl(allocator, cd.name, node.span, symbols, source, hints, false);
            },
            else => {},
        }
    }

    fn addHintForDecl(
        allocator: std.mem.Allocator,
        name: []const u8,
        span: sx.ast.Span,
        symbols: []const sx.sema.Symbol,
        source: [:0]const u8,
        hints: *std.ArrayList(lsp.InlayHint),
        is_colon_equal: bool,
    ) void {
        // Find symbol by matching span start
        const sym = findSymbolAtSpan(symbols, span.start, name) orelse return;
        const ty = sym.ty orelse return;

        // Skip void types — not useful to display
        if (ty == .void_type) return;

        const type_name = ty.displayName(allocator) catch return;

        if (is_colon_equal) {
            // For `:=` declarations: place hint between `:` and `=`
            // Scan from after the name to find `:=`
            var pos = span.start + @as(u32, @intCast(name.len));
            while (pos + 1 < source.len) : (pos += 1) {
                if (source[pos] == ':' and source[pos + 1] == '=') {
                    // Place hint at the `=` position (between `:` and `=`)
                    const eq_offset = pos + 1;
                    const loc = sx.errors.SourceLoc.compute(source, eq_offset);
                    if (loc.line == 0 or loc.col == 0) return;
                    hints.append(allocator, .{
                        .line = loc.line - 1,
                        .character = loc.col - 1,
                        .label = type_name,
                        .padding_left = true,
                        .padding_right = true,
                    }) catch {};
                    return;
                }
            }
        } else {
            // For `::` declarations: place hint between first `:` and second `:`
            var pos = span.start + @as(u32, @intCast(name.len));
            while (pos + 1 < source.len) : (pos += 1) {
                if (source[pos] == ':' and source[pos + 1] == ':') {
                    const second_colon = pos + 1;
                    const loc = sx.errors.SourceLoc.compute(source, second_colon);
                    if (loc.line == 0 or loc.col == 0) return;
                    hints.append(allocator, .{
                        .line = loc.line - 1,
                        .character = loc.col - 1,
                        .label = type_name,
                        .padding_left = true,
                        .padding_right = true,
                    }) catch {};
                    return;
                }
            }
        }
    }

    fn addBindingHint(
        allocator: std.mem.Allocator,
        name: []const u8,
        span: sx.ast.Span,
        symbols: []const sx.sema.Symbol,
        source: [:0]const u8,
        hints: *std.ArrayList(lsp.InlayHint),
    ) void {
        // Look up symbol by name + span (sema stores binding with if/while node span)
        const sym = findSymbolAtSpan(symbols, span.start, name) orelse return;
        const ty = sym.ty orelse return;
        if (ty == .void_type) return;

        const type_name = ty.displayName(allocator) catch return;

        // Scan from span start to find the `:=` used in the binding
        var pos = span.start;
        while (pos + 1 < source.len) : (pos += 1) {
            if (source[pos] == ':' and source[pos + 1] == '=') {
                const eq_offset = pos + 1;
                const loc = sx.errors.SourceLoc.compute(source, eq_offset);
                if (loc.line == 0 or loc.col == 0) return;
                hints.append(allocator, .{
                    .line = loc.line - 1,
                    .character = loc.col - 1,
                    .label = type_name,
                    .padding_left = true,
                    .padding_right = true,
                }) catch {};
                return;
            }
        }
    }

    /// Hint for a `for` loop capture (`for xs: (m)` → `m: T`). The capture has
    /// no `:=`/`::`, so the label carries its own colon and lands right after
    /// the capture name, whose slice points into `source`.
    fn addForCaptureHint(
        allocator: std.mem.Allocator,
        name: []const u8,
        span: sx.ast.Span,
        symbols: []const sx.sema.Symbol,
        source: [:0]const u8,
        hints: *std.ArrayList(lsp.InlayHint),
    ) void {
        const sym = findSymbolAtSpan(symbols, span.start, name) orelse return;
        const ty = sym.ty orelse return;
        if (ty == .void_type) return;
        const type_name = ty.displayName(allocator) catch return;
        const label = std.fmt.allocPrint(allocator, ": {s}", .{type_name}) catch return;

        const base = @intFromPtr(source.ptr);
        const np = @intFromPtr(name.ptr);
        if (np < base or np + name.len > base + source.len) return;
        const end_offset: u32 = @intCast(np - base + name.len);
        const loc = sx.errors.SourceLoc.compute(source, end_offset);
        if (loc.line == 0 or loc.col == 0) return;
        hints.append(allocator, .{
            .line = loc.line - 1,
            .character = loc.col - 1,
            .label = label,
            .padding_left = false,
            .padding_right = false,
        }) catch {};
    }

    fn addReturnTypeHint(
        allocator: std.mem.Allocator,
        span: sx.ast.Span,
        source: [:0]const u8,
        return_type: sx.types.Type,
        hints: *std.ArrayList(lsp.InlayHint),
    ) void {
        // Find '(' from span start
        var pos: u32 = span.start;
        while (pos < source.len and source[pos] != '(') : (pos += 1) {}
        if (pos >= source.len) return;

        // Match nested parens to find closing ')'
        var depth: u32 = 0;
        while (pos < source.len) : (pos += 1) {
            if (source[pos] == '(') {
                depth += 1;
            } else if (source[pos] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (pos >= source.len or depth != 0) return;

        // Place hint right after ')'
        const loc = sx.errors.SourceLoc.compute(source, pos + 1);
        if (loc.line == 0 or loc.col == 0) return;

        const type_name = return_type.displayName(allocator) catch return;
        const label = std.fmt.allocPrint(allocator, "-> {s}", .{type_name}) catch return;

        hints.append(allocator, .{
            .line = loc.line - 1,
            .character = loc.col - 1,
            .label = label,
            .kind = 1,
            .padding_left = true,
            .padding_right = true,
        }) catch {};
    }

    fn findSymbolAtSpan(symbols: []const sx.sema.Symbol, span_start: u32, name: []const u8) ?sx.sema.Symbol {
        for (symbols) |sym| {
            if (sym.def_span.start == span_start and std.mem.eql(u8, sym.name, name)) {
                return sym;
            }
        }
        return null;
    }

    // ---- Parameter name hints at call sites ----

    fn collectCallHints(self: *Server, doc: *const Document, node: *const sx.ast.Node, hints: *std.ArrayList(lsp.InlayHint)) void {
        switch (node.data) {
            .root => |r| {
                for (r.decls) |decl| self.collectCallHints(doc, decl, hints);
            },
            .block => |b| {
                for (b.stmts) |stmt| self.collectCallHints(doc, stmt, hints);
            },
            .fn_decl => |fd| {
                self.collectCallHints(doc, fd.body, hints);
            },
            .lambda => |lm| {
                self.collectCallHints(doc, lm.body, hints);
            },
            .if_expr => |ie| {
                self.collectCallHints(doc, ie.condition, hints);
                self.collectCallHints(doc, ie.then_branch, hints);
                if (ie.else_branch) |eb| self.collectCallHints(doc, eb, hints);
            },
            .while_expr => |we| {
                self.collectCallHints(doc, we.condition, hints);
                self.collectCallHints(doc, we.body, hints);
            },
            .for_expr => |fe| {
                for (fe.iterables) |it| {
                    self.collectCallHints(doc, it.expr, hints);
                    if (it.range_end) |re| self.collectCallHints(doc, re, hints);
                }
                self.collectCallHints(doc, fe.body, hints);
            },
            .var_decl => |vd| {
                if (vd.value) |val| self.collectCallHints(doc, val, hints);
            },
            .const_decl => |cd| {
                self.collectCallHints(doc, cd.value, hints);
            },
            .return_stmt => |rs| {
                if (rs.value) |val| self.collectCallHints(doc, val, hints);
            },
            .assignment => |a| {
                self.collectCallHints(doc, a.value, hints);
            },
            .binary_op => |bop| {
                self.collectCallHints(doc, bop.lhs, hints);
                self.collectCallHints(doc, bop.rhs, hints);
            },
            .unary_op => |uop| {
                self.collectCallHints(doc, uop.operand, hints);
            },
            .call => |c| {
                // Recurse into arguments (they may contain nested calls)
                for (c.args) |arg| self.collectCallHints(doc, arg, hints);
                // Emit parameter name hints for this call
                self.emitCallParamHints(doc, c, hints);
            },
            .push_stmt => |ps| {
                self.collectCallHints(doc, ps.context_expr, hints);
                self.collectCallHints(doc, ps.body, hints);
            },
            .defer_stmt => |ds| {
                self.collectCallHints(doc, ds.expr, hints);
            },
            else => {},
        }
    }

    fn emitCallParamHints(self: *Server, doc: *const Document, call: sx.ast.Call, hints: *std.ArrayList(lsp.InlayHint)) void {
        if (call.args.len == 0) return;

        // Resolve callee name and find function declaration
        var param_offset: usize = 0;
        const fd = self.resolveCallTarget(doc, call, &param_offset) orelse return;

        // Emit hints for each argument
        for (call.args, 0..) |arg, i| {
            const param_idx = i + param_offset;
            if (param_idx >= fd.params.len) break;

            const param = fd.params[param_idx];

            // Skip variadic params
            if (param.is_variadic) break;

            // Skip if arg is an identifier matching the param name
            if (arg.data == .identifier) {
                if (std.mem.eql(u8, arg.data.identifier.name, param.name)) continue;
            }

            // Skip _ params
            if (std.mem.eql(u8, param.name, "_")) continue;

            const loc = sx.errors.SourceLoc.compute(doc.source, arg.span.start);
            if (loc.line == 0 or loc.col == 0) continue;

            const label = std.fmt.allocPrint(self.allocator, "{s}:", .{param.name}) catch continue;
            hints.append(self.allocator, .{
                .line = loc.line - 1,
                .character = loc.col - 1,
                .label = label,
                .padding_left = false,
            }) catch {};
        }
    }

    fn resolveCallTarget(self: *Server, doc: *const Document, call: sx.ast.Call, param_offset: *usize) ?sx.ast.FnDecl {
        param_offset.* = 0;

        if (call.callee.data == .identifier) {
            const name = call.callee.data.identifier.name;
            return self.findFnDeclByName(doc, name);
        }

        if (call.callee.data == .field_access) {
            const fa = call.callee.data.field_access;

            // Try namespaced: "ns.func"
            if (fa.object.data == .identifier) {
                const ns_name = fa.object.data.identifier.name;
                const qualified = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_name, fa.field }) catch return null;
                if (self.findFnDeclByName(doc, qualified)) |fd| {
                    return fd;
                }
            }

            // Try UFCS: bare function name, skip first param (receiver)
            if (self.findFnDeclByName(doc, fa.field)) |fd| {
                if (fd.params.len == call.args.len + 1) {
                    param_offset.* = 1;
                }
                return fd;
            }
        }

        return null;
    }

    fn classifyToken(tok: sx.token.Token, sema: SemaResult, source: [:0]const u8) ?u32 {
        const ST = lsp.SemanticTokenType;
        return switch (tok.tag) {
            .kw_if,
            .kw_else,
            .kw_then,
            .kw_true,
            .kw_false,
            .kw_enum,
            .kw_error,
            .kw_raise,
            .kw_try,
            .kw_catch,
            .kw_onfail,
            .kw_case,
            .kw_break,
            .kw_continue,
            .kw_while,
            .kw_for,
            .kw_return,
            .kw_defer,
            .kw_struct,
            .kw_union,
            .kw_xx,
            .kw_and,
            .kw_or,
            .kw_null,
            .kw_push,
            .kw_ufcs,
            .kw_in,
            .kw_protocol,
            .kw_impl,
            .kw_inline,
            .kw_abi,
            .kw_extern,
            .kw_export,
            .kw_asm,
            .kw_intrinsic,
            .kw_private,
            .hash_run,
            .hash_error,
            .hash_import,
            .hash_insert,
            .hash_library,
            .hash_framework,
            .hash_using,
            .hash_include,
            .hash_source,
            .hash_define,
            .hash_flags,
            .hash_inline,
            .hash_identity,
            .hash_objc_call,
            .hash_jni_call,
            .hash_jni_static_call,
            .hash_jni_class,
            .hash_jni_interface,
            .hash_objc_class,
            .hash_objc_protocol,
            .hash_swift_class,
            .hash_swift_struct,
            .hash_swift_protocol,
            .hash_extends,
            .hash_implements,
            .hash_jni_method_descriptor,
            .hash_jni_env,
            .hash_jni_main,
            .hash_selector,
            .hash_property,
            .hash_get,
            .hash_set,
            .hash_caller_location,
            .hash_context_extend,
            => ST.keyword,

            .kw_f32, .kw_f64, .kw_Type, .kw_Self => ST.type_,

            .int_literal, .float_literal, .char_literal => ST.number,
            .string_literal, .raw_string_literal => null,

            .plus,
            .minus,
            .star,
            .slash,
            .equal,
            .equal_equal,
            .bang,
            .bang_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            .plus_equal,
            .minus_equal,
            .star_equal,
            .slash_equal,
            .percent,
            .percent_equal,
            .ampersand,
            .ampersand_equal,
            .pipe,
            .pipe_equal,
            .pipe_arrow,
            .caret,
            .caret_equal,
            .question,
            .question_question,
            .question_dot,
            .tilde,
            .less_less,
            .less_less_equal,
            .greater_greater,
            .greater_greater_equal,
            .arrow,
            .fat_arrow,
            .colon_colon,
            .colon_equal,
            .triple_minus,
            => ST.operator_,

            .identifier => classifyIdentifier(tok, sema, source),

            .colon,
            .semicolon,
            .comma,
            .dot,
            .dot_dot,
            .dot_dot_eq,
            .dot_dot_lt,
            .lt_dot_dot,
            .lt_dot_dot_eq,
            .lt_dot_dot_lt,
            .eq_dot_dot,
            .eq_dot_dot_eq,
            .eq_dot_dot_lt,
            .dollar,
            .l_paren,
            .r_paren,
            .l_brace,
            .r_brace,
            .l_bracket,
            .r_bracket,
            .eof,
            .invalid,
            => null,
        };
    }

    fn classifyIdentifier(tok: sx.token.Token, sema: SemaResult, source: [:0]const u8) ?u32 {
        const ST = lsp.SemanticTokenType;
        const offset = tok.loc.start;
        if (tok.loc.start >= source.len or tok.loc.end > source.len or tok.loc.start >= tok.loc.end) return null;
        const name = source[tok.loc.start..tok.loc.end];

        if (sx.sema.findReferenceAtOffset(sema.references, offset)) |ref_idx| {
            const si = sema.references[ref_idx].symbol_index;
            if (si >= sema.symbols.len) return null;
            const sym = sema.symbols[si];
            return symbolKindToTokenType(sym.kind);
        }

        for (sema.symbols) |sym| {
            if (sym.def_span.start == offset and std.mem.eql(u8, sym.name, name)) {
                return symbolKindToTokenType(sym.kind);
            }
        }

        if (sx.types.Type.fromName(name) != null) {
            return ST.type_;
        }

        // Uppercase identifiers are conventionally types
        if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') {
            return ST.type_;
        }

        return null;
    }

    fn symbolKindToTokenType(kind: sx.sema.SymbolKind) u32 {
        const ST = lsp.SemanticTokenType;
        return switch (kind) {
            .function => ST.function,
            .variable => ST.variable,
            .constant => ST.variable,
            .param => ST.parameter,
            .enum_type => ST.enum_,
            .struct_type => ST.struct_,
            .protocol_type => ST.interface,
            .type_alias => ST.type_,
            .namespace => ST.namespace,
        };
    }

    fn emitToken(
        data: *std.ArrayList(u32),
        allocator: std.mem.Allocator,
        source: [:0]const u8,
        start: u32,
        end: u32,
        token_type: u32,
        prev_line: *u32,
        prev_char: *u32,
    ) !void {
        if (start >= source.len or end > source.len or start >= end) return;
        const loc = sx.errors.SourceLoc.compute(source, start);
        if (loc.line == 0 or loc.col == 0) return;
        const line = loc.line - 1;
        const col = loc.col - 1;
        const length = end - start;

        if (line < prev_line.*) return;
        const delta_line = line - prev_line.*;
        const delta_char = if (delta_line == 0) (if (col >= prev_char.*) col - prev_char.* else return) else col;

        try data.append(allocator, delta_line);
        try data.append(allocator, delta_char);
        try data.append(allocator, length);
        try data.append(allocator, token_type);
        try data.append(allocator, 0);

        prev_line.* = line;
        prev_char.* = col;
    }

    fn emitStringSegment(
        data: *std.ArrayList(u32),
        allocator: std.mem.Allocator,
        source: [:0]const u8,
        seg_start: u32,
        seg_end: u32,
        token_type: u32,
        prev_line: *u32,
        prev_char: *u32,
    ) !void {
        var line_start = seg_start;
        var pos = seg_start;
        while (pos < seg_end) : (pos += 1) {
            if (source[pos] == '\n') {
                if (pos + 1 > line_start) {
                    try emitToken(data, allocator, source, line_start, pos + 1, token_type, prev_line, prev_char);
                }
                line_start = pos + 1;
            }
        }
        if (line_start < seg_end) {
            try emitToken(data, allocator, source, line_start, seg_end, token_type, prev_line, prev_char);
        }
    }

    fn emitStringParts(
        data: *std.ArrayList(u32),
        allocator: std.mem.Allocator,
        source: [:0]const u8,
        tok_start: u32,
        tok_end: u32,
        prev_line: *u32,
        prev_char: *u32,
    ) !void {
        const ST = lsp.SemanticTokenType;
        var pos = tok_start;
        var seg_start = tok_start;
        var in_interp = false;

        while (pos < tok_end) : (pos += 1) {
            if (in_interp) {
                if (source[pos] == '}') {
                    in_interp = false;
                    seg_start = pos + 1;
                }
            } else {
                if (source[pos] == '\\' and pos + 1 < tok_end) {
                    pos += 1;
                } else if (source[pos] == '{') {
                    if (pos > seg_start) {
                        try emitStringSegment(data, allocator, source, seg_start, pos, ST.string_, prev_line, prev_char);
                    }
                    in_interp = true;
                }
            }
        }

        if (!in_interp and seg_start < tok_end) {
            try emitStringSegment(data, allocator, source, seg_start, tok_end, ST.string_, prev_line, prev_char);
        }
    }

    // ---- Core analysis pipeline ----

    /// Refresh the editor index for a document (symbols/references/types that
    /// power navigation, completion, hover, and token classification). Publishes
    /// no diagnostics — authoritative diagnostics come only from the canonical
    /// compiler pipeline in `runProjectCheck`.
    fn refreshEditorIndex(self: *Server, uri: []const u8, text: []const u8, version: i64) !void {
        const file_path = uriToFilePath(uri) orelse "";
        const source = try self.allocator.dupeZ(u8, text);

        const doc = try self.documents.openOrUpdate(file_path, source, version);
        self.documents.analyzeDocument(doc) catch {};
    }

    fn sendDiagnostics(self: *Server, uri: []const u8, diagnostics: []const lsp.Diagnostic) !void {
        const params_json = try lsp.publishDiagnosticsJson(self.allocator, uri, diagnostics);
        const body = try lsp.jsonRpcNotification(self.allocator, "textDocument/publishDiagnostics", params_json);
        try self.transport.writeMessage(body);
    }

    const ProjectDiag = struct {
        file_path: []const u8,
        range: lsp.Range,
        severity: u32,
        message: []const u8,
    };

    /// Compile the whole program from `entry_path` and return its diagnostics,
    /// each attributed (via `source_file`) to the file it belongs to. A single
    /// module can't be lowered on its own — lowering only type-checks functions
    /// reachable from a root — so we drive the entry and map results back. A
    /// bundled help is folded into its primary's message. Pure of transport, so
    /// it is unit-testable; empty on a parse failure or unreadable entry.
    fn collectProjectDiagnostics(self: *Server, entry_path: []const u8) []const ProjectDiag {
        const entry_doc = self.documents.getOrLoad(entry_path) catch return &.{};
        var comp = sx.core.Compilation.init(self.allocator, self.io, entry_path, entry_doc.source, .{}, self.stdlib_paths);
        defer comp.deinit();
        comp.parse() catch return &.{};
        comp.resolveImports() catch {};
        _ = comp.lowerToIR() catch {};

        var out = std.ArrayList(ProjectDiag).empty;
        for (comp.diagnostics.items.items, 0..) |d, i| {
            if (d.level == .note or d.level == .help) continue;
            const span = d.span orelse continue;
            const file_path = d.source_file orelse entry_path;
            const src = comp.import_sources.get(file_path) orelse entry_doc.source;
            var message = d.message;
            for (comp.diagnostics.items.items) |h| {
                if (h.level == .help and h.primary == i) {
                    message = std.fmt.allocPrint(self.allocator, "{s} — {s}", .{ message, h.message }) catch message;
                    break;
                }
            }
            out.append(self.allocator, .{
                .file_path = file_path,
                .range = spanToRange(src, span),
                .severity = switch (d.level) {
                    .err => 1,
                    .warn => 2,
                    .note => 3,
                    .help => 4,
                },
                .message = message,
            }) catch {};
        }
        return out.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Drive the whole-program check from the workspace entry point and publish
    /// the real compiler's diagnostics per file. Runs on open and save; this is
    /// the sole source of LSP diagnostics (the editor index publishes none).
    fn runProjectCheck(self: *Server) void {
        if (self.root_path.len == 0) return;
        const entry_path = std.fmt.allocPrint(self.allocator, "{s}/main.sx", .{self.root_path}) catch return;

        var by_file = std.StringHashMap(std.ArrayList(lsp.Diagnostic)).init(self.allocator);
        for (self.collectProjectDiagnostics(entry_path)) |pd| {
            const gop = by_file.getOrPut(pd.file_path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(lsp.Diagnostic).empty;
            gop.value_ptr.append(self.allocator, .{ .range = pd.range, .severity = pd.severity, .message = pd.message }) catch {};
        }

        var new_uris = std.StringHashMap(void).init(self.allocator);
        var it = by_file.iterator();
        while (it.next()) |entry| {
            const uri = self.fileUri(entry.key_ptr.*) catch continue;
            self.sendDiagnostics(uri, entry.value_ptr.items) catch {};
            new_uris.put(uri, {}) catch {};
        }
        // Clear any file that reported errors last time but doesn't now.
        var pit = self.project_diag_uris.iterator();
        while (pit.next()) |entry| {
            if (!new_uris.contains(entry.key_ptr.*)) {
                self.sendDiagnostics(entry.key_ptr.*, &.{}) catch {};
            }
        }
        self.project_diag_uris.deinit();
        self.project_diag_uris = new_uris;
    }

    // ---- Symbol resolution helpers ----

    /// Send a Location response for a symbol, resolving to the correct file via origin.
    fn sendSymbolLocation(self: *Server, id_json: []const u8, doc: *const Document, sym: sx.sema.Symbol) !bool {
        return self.sendSymbolLocationWithOrigin(id_json, doc, sym, null);
    }

    fn sendSymbolLocationWithOrigin(self: *Server, id_json: []const u8, doc: *const Document, sym: sx.sema.Symbol, origin_span: ?sx.ast.Span) !bool {
        if (sym.origin) |origin_path| {
            const origin_doc = self.documents.get(origin_path) orelse return false;
            const target_range = spanToRange(origin_doc.source, sym.def_span);
            const target_uri = try self.fileUri(origin_path);
            if (origin_span) |os| {
                const src_range = spanToRange(doc.source, os);
                const loc_json = try lsp.locationLinkJson(self.allocator, target_uri, target_range, src_range);
                try self.sendResponse(id_json, loc_json);
            } else {
                const loc_json = try lsp.locationJson(self.allocator, target_uri, target_range);
                try self.sendResponse(id_json, loc_json);
            }
            return true;
        } else {
            const target_range = spanToRange(doc.source, sym.def_span);
            const target_uri = try self.fileUri(doc.path);
            if (origin_span) |os| {
                const src_range = spanToRange(doc.source, os);
                const loc_json = try lsp.locationLinkJson(self.allocator, target_uri, target_range, src_range);
                try self.sendResponse(id_json, loc_json);
            } else {
                const loc_json = try lsp.locationJson(self.allocator, target_uri, target_range);
                try self.sendResponse(id_json, loc_json);
            }
            return true;
        }
    }

    /// Send a go-to-definition response pointing to a C header source location.
    fn sendCSourceLocation(self: *Server, id_json: []const u8, cloc: sx.c_import.CSourceLocation, origin_span: ?sx.ast.Span, origin_source: [:0]const u8) !bool {
        // Resolve to absolute path if relative
        const abs_path = if (cloc.file.len > 0 and cloc.file[0] != '/')
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root_path, cloc.file })
        else
            cloc.file;
        const target_uri = try self.fileUri(abs_path);
        const line: u32 = if (cloc.line > 0) cloc.line - 1 else 0; // LSP lines are 0-based
        const target_range = lsp.Range{
            .start = .{ .line = line, .character = 0 },
            .end = .{ .line = line, .character = 0 },
        };
        if (origin_span) |os| {
            const src_range = spanToRange(origin_source, os);
            const loc_json = try lsp.locationLinkJson(self.allocator, target_uri, target_range, src_range);
            try self.sendResponse(id_json, loc_json);
        } else {
            const loc_json = try lsp.locationJson(self.allocator, target_uri, target_range);
            try self.sendResponse(id_json, loc_json);
        }
        return true;
    }

    /// Resolve which document a symbol belongs to (for hover/source lookup).
    fn resolveSymbolDoc(self: *Server, doc: *const Document, sym: sx.sema.Symbol) *const Document {
        if (sym.origin) |origin_path| {
            return self.documents.get(origin_path) orelse doc;
        }
        return doc;
    }

    const TypeDeclLookup = struct { node: *sx.ast.Node, doc: *const Document };

    /// Given a type name, find its AST declaration node and the document it lives in.
    /// Works for struct_decl, enum_decl, union_decl, and protocol_decl across files.
    fn findTypeDeclNode(self: *Server, sema: SemaResult, doc: *const Document, type_name: []const u8) ?TypeDeclLookup {
        for (sema.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, type_name)) continue;
            if (sym.kind != .struct_type and sym.kind != .enum_type and sym.kind != .protocol_type) continue;

            const lookup_doc = self.resolveSymbolDoc(doc, sym);
            const lookup_root = lookup_doc.root orelse return null;

            if (sx.sema.findNodeAtOffset(lookup_root, sym.def_span.start)) |node| {
                return .{ .node = node, .doc = lookup_doc };
            }
            return null;
        }
        return null;
    }

    /// Send a go-to-definition response for a struct method, field, or enum variant.
    fn sendMemberLocation(self: *Server, id_json: []const u8, lookup: TypeDeclLookup, member_name: []const u8, origin_doc: *const Document, origin: sx.ast.Span) !bool {
        if (lookup.node.data == .struct_decl) {
            const sd = lookup.node.data.struct_decl;
            // Check methods
            for (sd.methods) |method_node| {
                if (method_node.data == .fn_decl) {
                    if (std.mem.eql(u8, method_node.data.fn_decl.name, member_name)) {
                        return self.sendSpanLocation(id_json, lookup.doc, method_node.span, origin_doc, origin);
                    }
                }
            }
            // Check fields — use field type span as approximate location
            for (sd.field_names, 0..) |fname, fi| {
                if (std.mem.eql(u8, fname, member_name)) {
                    if (fi < sd.field_types.len) {
                        return self.sendSpanLocation(id_json, lookup.doc, sd.field_types[fi].span, origin_doc, origin);
                    }
                }
            }
        } else if (lookup.node.data == .enum_decl) {
            const ed = lookup.node.data.enum_decl;
            for (ed.variant_names) |v| {
                if (std.mem.eql(u8, v, member_name)) {
                    return self.sendSpanLocation(id_json, lookup.doc, lookup.node.span, origin_doc, origin);
                }
            }
        } else if (lookup.node.data == .union_decl) {
            const ud = lookup.node.data.union_decl;
            for (ud.field_names) |fname| {
                if (std.mem.eql(u8, fname, member_name)) {
                    return self.sendSpanLocation(id_json, lookup.doc, lookup.node.span, origin_doc, origin);
                }
            }
        }
        return false;
    }

    // ---- Context extension support (design/context-extension.md, LSP unit) ----
    //
    // Context fields are PROGRAM-GLOBAL (L3: no import gating), so every
    // lookup here spans the whole document store — the server's workspace is
    // the editor-side approximation of "the compilation". The heavy lifting
    // rides sema's (owner, name) member-ref index: `#context_extend` records
    // a member DEF owned by "Context", `context.field` reads and push-literal
    // field names record member USES, and references fall out of the existing
    // cross-document member machinery with no code here.

    const ContextExtendHit = struct { doc: *const Document, ce: sx.ast.ContextExtendDecl, span: sx.ast.Span };

    /// Find the `#context_extend <name>` declaration across all loaded
    /// documents. Deterministic on multi-hit (a compile error anyway): the
    /// lexicographically-smallest declaring path wins — the L6 order.
    fn findContextExtendDecl(store: *DocumentStore, name: []const u8) ?ContextExtendHit {
        var best: ?ContextExtendHit = null;
        var it = store.by_path.iterator();
        while (it.next()) |entry| {
            const odoc = entry.value_ptr.*;
            const root = odoc.root orelse continue;
            if (root.data != .root) continue;
            for (root.data.root.decls) |decl| {
                if (decl.data != .context_extend_decl) continue;
                const ce = decl.data.context_extend_decl;
                if (!std.mem.eql(u8, ce.name, name)) continue;
                if (best == null or std.mem.order(u8, odoc.path, best.?.doc.path) == .lt) {
                    best = .{ .doc = odoc, .ce = ce, .span = decl.span };
                }
            }
        }
        return best;
    }

    /// Every `#context_extend` declaration in the store, in L6 order
    /// (declaring path, field name) — the completion / enumeration source.
    fn collectContextExtendDecls(store: *DocumentStore, allocator: std.mem.Allocator) []ContextExtendHit {
        var hits = std.ArrayList(ContextExtendHit).empty;
        var it = store.by_path.iterator();
        while (it.next()) |entry| {
            const odoc = entry.value_ptr.*;
            const root = odoc.root orelse continue;
            if (root.data != .root) continue;
            for (root.data.root.decls) |decl| {
                if (decl.data != .context_extend_decl) continue;
                hits.append(allocator, .{ .doc = odoc, .ce = decl.data.context_extend_decl, .span = decl.span }) catch return &.{};
            }
        }
        std.sort.insertion(ContextExtendHit, hits.items, {}, struct {
            fn lt(_: void, a: ContextExtendHit, b: ContextExtendHit) bool {
                return switch (std.mem.order(u8, a.doc.path, b.doc.path)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.order(u8, a.ce.name, b.ce.name) == .lt,
                };
            }
        }.lt);
        return hits.toOwnedSlice(allocator) catch &.{};
    }

    /// The member-ref DEF site for (owner, name) across all loaded documents
    /// — `#context_extend` decls and struct-decl fields both record one.
    fn findMemberDefAcrossDocs(store: *DocumentStore, owner: []const u8, name: []const u8) ?struct { doc: *const Document, span: sx.ast.Span } {
        var it = store.by_path.iterator();
        while (it.next()) |entry| {
            const odoc = entry.value_ptr.*;
            const osema = odoc.sema orelse continue;
            for (osema.member_refs) |mr| {
                if (!mr.is_def) continue;
                if (!std.mem.eql(u8, mr.owner, owner)) continue;
                if (!std.mem.eql(u8, mr.name, name)) continue;
                return .{ .doc = odoc, .span = mr.span };
            }
        }
        return null;
    }

    /// The non-def member ref under the cursor, if any.
    fn memberUseAt(sema: *const SemaResult, offset: u32) ?sx.sema.MemberRef {
        for (sema.member_refs) |mr| {
            if (mr.is_def) continue;
            if (offset < mr.span.start or offset >= mr.span.end) continue;
            return mr;
        }
        return null;
    }

    /// Go-to-definition for a Context field named `member`: the
    /// `#context_extend` declaration (extension fields) or the builtin field's
    /// member DEF in core.sx's Context struct.
    fn sendContextFieldDef(self: *Server, id_json: []const u8, origin_doc: *const Document, member: []const u8, origin: sx.ast.Span) !bool {
        self.documents.loadWorkspaceFiles();
        if (findContextExtendDecl(&self.documents, member)) |hit| {
            return self.sendSpanLocation(id_json, hit.doc, hit.ce.name_span, origin_doc, origin);
        }
        if (findMemberDefAcrossDocs(&self.documents, "Context", member)) |def| {
            return self.sendSpanLocation(id_json, def.doc, def.span, origin_doc, origin);
        }
        return false;
    }

    /// Hover for a Context field: the declaration spelling (name, type,
    /// default) + the declaring module — or the builtin field's struct hover.
    fn formatContextFieldHover(self: *Server, doc: *const Document, member: []const u8) !?[]const u8 {
        self.documents.loadWorkspaceFiles();
        if (findContextExtendDecl(&self.documents, member)) |hit| {
            var buf = std.ArrayList(u8).empty;
            if (extractDocComment(hit.doc.source, hit.span.start)) |comment| {
                try buf.appendSlice(self.allocator, comment);
                try buf.appendSlice(self.allocator, "\n\n");
            }
            try buf.appendSlice(self.allocator, "```sx\n");
            try buf.appendSlice(self.allocator, sourceSlice(hit.doc, hit.span) orelse hit.ce.name);
            try buf.appendSlice(self.allocator, "\n```\n\ndeclared by `");
            try buf.appendSlice(self.allocator, hit.doc.path);
            try buf.appendSlice(self.allocator, "`");
            return buf.items;
        }
        // Builtin prefix field (allocator / io) — the ordinary struct-field
        // hover against the Context struct decl.
        return self.formatStructFieldHover(doc, "Context", member);
    }

    /// Slice a document's source at `span` (bounds-checked).
    fn sourceSlice(doc: *const Document, span: sx.ast.Span) ?[]const u8 {
        if (span.start > span.end or span.end > doc.source.len) return null;
        return doc.source[span.start..span.end];
    }

    /// Hover for the bare `context` identifier: the WHOLE assembled Context in
    /// one place — the builtin prefix (from the Context struct decl) plus
    /// every `#context_extend` field, each with its declaring module. The
    /// tooling recovery of the "one visible struct" property the assembled
    /// design trades away in source.
    fn formatContextHover(self: *Server, sema: SemaResult, doc: *const Document) !?[]const u8 {
        self.documents.loadWorkspaceFiles();
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(self.allocator, "```sx\ncontext: Context\n```\n\nassembled context fields:\n");
        var any = false;
        if (self.findTypeDeclNode(sema, doc, "Context")) |lookup| {
            if (lookup.node.data == .struct_decl) {
                const sd = lookup.node.data.struct_decl;
                for (sd.field_names, 0..) |fname, fi| {
                    const ty_txt: []const u8 = if (fi < sd.field_types.len)
                        sourceSlice(lookup.doc, sd.field_types[fi].span) orelse ""
                    else
                        "";
                    try buf.print(self.allocator, "- `{s}: {s}` — `{s}`\n", .{ fname, ty_txt, lookup.doc.path });
                    any = true;
                }
            }
        }
        const hits = collectContextExtendDecls(&self.documents, self.allocator);
        for (hits) |hit| {
            const ty_txt = sourceSlice(hit.doc, hit.ce.type_expr.span) orelse "";
            try buf.print(self.allocator, "- `{s}: {s}` — `{s}`\n", .{ hit.ce.name, ty_txt, hit.doc.path });
            any = true;
        }
        if (!any) return null;
        return buf.items;
    }

    /// Append completion items for every Context field: the builtin prefix
    /// (from the Context struct decl) + all `#context_extend` fields (with
    /// declared type + declaring file as detail).
    fn appendContextFieldCompletions(self: *Server, items: *std.ArrayList(lsp.CompletionItem), sema: SemaResult, doc: *const Document) !void {
        self.documents.loadWorkspaceFiles();
        try self.collectMemberCompletions(items, sema, doc, "Context");
        const hits = collectContextExtendDecls(&self.documents, self.allocator);
        for (hits) |hit| {
            const ty_txt = sourceSlice(hit.doc, hit.ce.type_expr.span) orelse "";
            const detail = try std.fmt.allocPrint(self.allocator, "{s} — {s}", .{ ty_txt, std.fs.path.basename(hit.doc.path) });
            try items.append(self.allocator, .{
                .label = hit.ce.name,
                .kind = @intFromEnum(lsp.CompletionItemKind.Field),
                .detail = detail,
            });
        }
    }

    /// True when `offset` sits inside a `push .{ … }` literal — the backward
    /// scan finds the innermost unmatched `{`, and qualifies it as a push
    /// context literal iff it is a `.{` whose preceding word is `push`.
    fn insidePushLiteral(source: []const u8, offset: u32) bool {
        var depth: i32 = 0;
        var i: usize = @min(offset, source.len);
        while (i > 0) {
            i -= 1;
            const c = source[i];
            if (c == '}') {
                depth += 1;
            } else if (c == '{') {
                if (depth > 0) {
                    depth -= 1;
                    continue;
                }
                if (i == 0 or source[i - 1] != '.') return false;
                var j = i - 1;
                while (j > 0 and std.ascii.isWhitespace(source[j - 1])) j -= 1;
                const kw = "push";
                if (j < kw.len) return false;
                if (!std.mem.eql(u8, source[j - kw.len .. j], kw)) return false;
                return j == kw.len or !isIdentChar(source[j - kw.len - 1]);
            }
        }
        return false;
    }

    /// Resolve qualified name as struct/union method or field, send definition location.
    fn resolveStructMemberDef(self: *Server, id_json: []const u8, sema: SemaResult, doc: *const Document, ns: []const u8, member: []const u8, origin: sx.ast.Span) !bool {
        // Try ns as a type name directly
        if (self.findTypeDeclNode(sema, doc, ns)) |lookup| {
            if (try self.sendMemberLocation(id_json, lookup, member, doc, origin)) return true;
        }
        // Try ns as a variable name → resolve to struct type
        if (resolveStructTypeName(sema, doc, ns)) |type_name| {
            if (self.findTypeDeclNode(sema, doc, type_name)) |lookup| {
                if (try self.sendMemberLocation(id_json, lookup, member, doc, origin)) return true;
            }
        }
        return false;
    }

    /// Send a go-to-definition response pointing to a span in a document.
    fn sendSpanLocation(self: *Server, id_json: []const u8, target_doc: *const Document, target_span: sx.ast.Span, origin_doc: *const Document, origin_span: sx.ast.Span) !bool {
        const target_range = spanToRange(target_doc.source, target_span);
        const target_uri = try self.fileUri(target_doc.path);
        const src_range = spanToRange(origin_doc.source, origin_span);
        const loc_json = try lsp.locationLinkJson(self.allocator, target_uri, target_range, src_range);
        try self.sendResponse(id_json, loc_json);
        return true;
    }

    /// Find an import by namespace name (falls back to last good imports).
    fn findImportByNs(_: *Server, doc: *const Document, ns_name: []const u8) ?doc_mod.Import {
        const imports_lists = [_][]const doc_mod.Import{ doc.imports, doc.last_good_imports };
        for (&imports_lists) |imports| {
            for (imports) |imp| {
                if (imp.ns) |ns| {
                    if (std.mem.eql(u8, ns, ns_name)) return imp;
                }
            }
        }
        return null;
    }

    pub fn searchFnDeclInDoc(target_doc: *const Document, fn_name: []const u8) ?sx.ast.FnDecl {
        const root = target_doc.root orelse return null;
        if (root.data != .root) return null;
        for (root.data.root.decls) |decl| {
            if (decl.data == .fn_decl and std.mem.eql(u8, decl.data.fn_decl.name, fn_name)) {
                return decl.data.fn_decl;
            }
        }
        return null;
    }

    /// Find a fn_decl by name. Supports dotted names like "ns.func".
    fn findFnDeclByName(self: *Server, doc: *const Document, name: []const u8) ?sx.ast.FnDecl {
        // Check for dotted name (e.g. "std.print")
        if (std.mem.indexOfScalar(u8, name, '.')) |dot_idx| {
            const ns_name = name[0..dot_idx];
            const fn_name = name[dot_idx + 1 ..];

            if (self.findImportByNs(doc, ns_name)) |imp| {
                if (self.documents.get(imp.path)) |imp_doc| {
                    if (searchFnDeclInDoc(imp_doc, fn_name)) |fd| return fd;
                } else {
                    // Directory import: search all documents in the directory
                    const dir_prefix = std.fmt.allocPrint(self.allocator, "{s}/", .{imp.path}) catch null;
                    if (dir_prefix) |prefix| {
                        var it = self.documents.by_path.iterator();
                        while (it.next()) |entry| {
                            if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
                            if (searchFnDeclInDoc(entry.value_ptr.*, fn_name)) |fd| return fd;
                        }
                    }
                }
            }
        }

        // Top-level lookup in current doc
        const root = doc.root orelse return null;
        const func_name = extractLastSegment(name);
        if (root.data == .root) {
            for (root.data.root.decls) |decl| {
                if (decl.data == .fn_decl and std.mem.eql(u8, decl.data.fn_decl.name, func_name)) {
                    return decl.data.fn_decl;
                }
            }
        }

        // Also check imported docs for flat-imported functions
        for (doc.imports) |imp| {
            if (imp.ns != null) continue; // skip namespaced
            if (self.documents.get(imp.path)) |imp_doc| {
                if (imp_doc.root) |imp_root| {
                    if (imp_root.data == .root) {
                        for (imp_root.data.root.decls) |decl| {
                            if (decl.data == .fn_decl and std.mem.eql(u8, decl.data.fn_decl.name, func_name)) {
                                return decl.data.fn_decl;
                            }
                        }
                    }
                }
            }
        }

        return null;
    }

    /// UFCS completions: free functions whose first param matches the given type.
    fn collectUfcsCompletions(self: *Server, items: *std.ArrayList(lsp.CompletionItem), root: *sx.ast.Node, type_name: []const u8) !void {
        if (root.data != .root) return;
        for (root.data.root.decls) |decl| {
            try self.collectUfcsFromDecl(items, decl, type_name);
        }
    }

    fn collectUfcsFromDecl(self: *Server, items: *std.ArrayList(lsp.CompletionItem), decl: *sx.ast.Node, type_name: []const u8) !void {
        switch (decl.data) {
            .fn_decl => |fd| {
                if (fd.params.len > 0) {
                    const base = extractBaseTypeName(fd.params[0].type_expr) orelse return;
                    if (!std.mem.eql(u8, base, type_name)) return;

                    const detail = try self.formatUfcsDetail(fd.params[1..], fd.return_type);
                    try items.append(self.allocator, .{
                        .label = fd.name,
                        .kind = @intFromEnum(lsp.CompletionItemKind.Method),
                        .detail = detail,
                    });
                }
            },
            .const_decl => |cd| {
                if (cd.value.data == .lambda) {
                    const lam = cd.value.data.lambda;
                    if (lam.params.len > 0) {
                        const base = extractBaseTypeName(lam.params[0].type_expr) orelse return;
                        if (!std.mem.eql(u8, base, type_name)) return;

                        const detail = try self.formatUfcsDetail(lam.params[1..], lam.return_type);
                        try items.append(self.allocator, .{
                            .label = cd.name,
                            .kind = @intFromEnum(lsp.CompletionItemKind.Method),
                            .detail = detail,
                        });
                    }
                }
            },
            else => {},
        }
    }

    fn formatUfcsDetail(self: *Server, params: []const sx.ast.Param, return_type: ?*sx.ast.Node) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        try buf.append(self.allocator, '(');
        for (params, 0..) |param, pi| {
            if (pi > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, param.name);
            if (param.type_expr.data == .inferred_type) {
                // Inferred type — show name only
            } else if (param.type_expr.data == .type_expr) {
                try buf.appendSlice(self.allocator, ": ");
                try buf.appendSlice(self.allocator, param.type_expr.data.type_expr.name);
            } else {
                try buf.appendSlice(self.allocator, "?");
            }
        }
        try buf.append(self.allocator, ')');
        if (return_type) |rt| {
            try buf.appendSlice(self.allocator, " -> ");
            if (rt.data == .type_expr) {
                try buf.appendSlice(self.allocator, rt.data.type_expr.name);
            }
        }
        return buf.items;
    }

    // ---- Hover helpers ----

    fn formatStructFieldHover(self: *Server, doc: *const Document, obj_name: []const u8, field_name: []const u8) !?[]const u8 {
        const sema = doc.sema orelse return null;
        const struct_name = resolveStructTypeName(sema, doc, obj_name) orelse return null;

        const lookup = self.findTypeDeclNode(sema, doc, struct_name) orelse return null;
        if (lookup.node.data != .struct_decl) return null;
        const sd = lookup.node.data.struct_decl;
        const lookup_doc = lookup.doc;

        for (sd.field_names, 0..) |fn_, fi| {
            if (!std.mem.eql(u8, fn_, field_name)) continue;

            var buf = std.ArrayList(u8).empty;

            // Doc comment above field
            const fn_addr = @intFromPtr(fn_.ptr);
            const src_addr = @intFromPtr(lookup_doc.source.ptr);
            const src_end = src_addr + lookup_doc.source.len;
            if (fn_addr >= src_addr and fn_addr < src_end) {
                const field_offset = @as(u32, @intCast(fn_addr - src_addr));
                if (extractDocComment(lookup_doc.source, field_offset)) |comment| {
                    try buf.appendSlice(self.allocator, comment);
                    try buf.appendSlice(self.allocator, "\n\n");
                }
            }

            try buf.appendSlice(self.allocator, "```sx\n");
            try buf.appendSlice(self.allocator, struct_name);
            try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, field_name);
            if (fi < sd.field_types.len) {
                if (sd.field_types[fi].data == .type_expr) {
                    try buf.appendSlice(self.allocator, " : ");
                    try buf.appendSlice(self.allocator, sd.field_types[fi].data.type_expr.name);
                }
            }
            try buf.appendSlice(self.allocator, "\n```");
            return buf.items;
        }
        return null;
    }

    fn formatEnumVariantHover(self: *Server, doc: *const Document, variant_name: []const u8) !?[]const u8 {
        const sema = doc.sema orelse return null;

        // Search all enum types for the variant
        for (sema.symbols) |sym| {
            if (sym.kind != .enum_type) continue;

            const lookup = self.findTypeDeclNode(sema, doc, sym.name) orelse continue;
            if (lookup.node.data != .enum_decl) continue;
            const ed = lookup.node.data.enum_decl;
            const lookup_doc = lookup.doc;

            for (ed.variant_names) |v| {
                if (!std.mem.eql(u8, v, variant_name)) continue;

                var buf = std.ArrayList(u8).empty;

                const v_addr = @intFromPtr(v.ptr);
                const src_addr2 = @intFromPtr(lookup_doc.source.ptr);
                const src_end2 = src_addr2 + lookup_doc.source.len;
                if (v_addr >= src_addr2 and v_addr < src_end2) {
                    const variant_offset = @as(u32, @intCast(v_addr - src_addr2));
                    if (extractDocComment(lookup_doc.source, variant_offset)) |comment| {
                        try buf.appendSlice(self.allocator, comment);
                        try buf.appendSlice(self.allocator, "\n\n");
                    }
                }

                try buf.appendSlice(self.allocator, "```sx\n");
                try buf.appendSlice(self.allocator, sym.name);
                try buf.append(self.allocator, '.');
                try buf.appendSlice(self.allocator, variant_name);
                try buf.appendSlice(self.allocator, "\n```");
                return buf.items;
            }
        }
        return null;
    }

    fn resolveVariableType(sema: SemaResult, var_name: []const u8) ?[]const u8 {
        var i = sema.symbols.len;
        while (i > 0) {
            i -= 1;
            const sym = sema.symbols[i];
            if (!std.mem.eql(u8, sym.name, var_name)) continue;
            if (sym.kind != .variable and sym.kind != .param) continue;
            const ty = sym.ty orelse return null;
            return switch (ty) {
                .struct_type => |name| name,
                else => null,
            };
        }
        return null;
    }

    fn resolveStructTypeName(sema: SemaResult, doc: *const Document, var_name: []const u8) ?[]const u8 {
        _ = doc;
        // A struct type name used directly resolves to itself (lets member
        // helpers take either a variable or a type name, e.g. "Context").
        if (sema.struct_types.contains(var_name)) return var_name;
        var i = sema.symbols.len;
        while (i > 0) {
            i -= 1;
            const sym = sema.symbols[i];
            if (!std.mem.eql(u8, sym.name, var_name)) continue;

            const ty = sym.ty orelse return null;
            // A struct value, or a pointer to one (`*Board`) — return the struct
            // name so the caller can locate the type's declaration.
            if (ty == .struct_type) return ty.struct_type;
            if (ty.isPointer()) return ty.pointer_type.pointee_name;
            return null;
        }
        return null;
    }

    // ---- JSON helpers ----

    fn jsonGet(val: std.json.Value, key: []const u8) ?std.json.Value {
        return switch (val) {
            .object => |obj| obj.get(key),
            else => null,
        };
    }

    fn jsonStr(val: std.json.Value) ?[]const u8 {
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    fn jsonInt(val: std.json.Value) ?i64 {
        return switch (val) {
            .integer => |i| i,
            else => null,
        };
    }

    fn jsonArr(val: std.json.Value) ?[]std.json.Value {
        return switch (val) {
            .array => |a| a.items,
            else => null,
        };
    }

    // ---- Text helpers ----

    fn findSymbolNameAtOffset(symbols: []const sx.sema.Symbol, source: [:0]const u8, offset: u32) ?usize {
        for (symbols, 0..) |sym, i| {
            if (sym.origin != null) continue; // skip imported symbols
            const name_start = sym.def_span.start;
            const name_end = name_start + @as(u32, @intCast(sym.name.len));
            if (offset >= name_start and offset < name_end and name_end <= source.len) {
                if (std.mem.eql(u8, source[name_start..name_end], sym.name)) {
                    return i;
                }
            }
        }
        return null;
    }

    pub fn positionToOffset(source: []const u8, line: u32, character: u32) ?u32 {
        var cur_line: u32 = 0;
        var cur_col: u32 = 0;
        for (source, 0..) |ch, i| {
            if (cur_line == line and cur_col == character) {
                return @intCast(i);
            }
            if (ch == '\n') {
                if (cur_line == line) return @intCast(i);
                cur_line += 1;
                cur_col = 0;
            } else {
                cur_col += 1;
            }
        }
        if (cur_line == line and cur_col == character) {
            return @intCast(source.len);
        }
        return null;
    }

    fn extractDotPrefix(source: []const u8, cursor_offset: u32) ?[]const u8 {
        if (cursor_offset < 2) return null;
        const dot_pos = cursor_offset - 1;
        if (source[dot_pos] != '.') return null;

        var start: u32 = dot_pos;
        while (start > 0) {
            const ch = source[start - 1];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') {
                start -= 1;
            } else {
                break;
            }
        }

        if (start == dot_pos) return null;
        const prefix = source[start..dot_pos];

        var trimmed_start: usize = 0;
        while (trimmed_start < prefix.len and prefix[trimmed_start] == '.') {
            trimmed_start += 1;
        }
        if (trimmed_start == prefix.len) return null;
        return prefix[trimmed_start..];
    }

    fn findCallContext(source: []const u8, cursor_offset: u32) ?struct { name: []const u8, active_param: u32 } {
        if (cursor_offset == 0) return null;

        var depth: i32 = 0;
        var comma_count: u32 = 0;
        var pos: u32 = cursor_offset;

        while (pos > 0) {
            pos -= 1;
            const ch = source[pos];

            if (ch == ')') {
                depth += 1;
            } else if (ch == '(') {
                if (depth == 0) {
                    if (pos == 0) return null;
                    const name_end: u32 = pos;
                    var name_start: u32 = pos;
                    while (name_start > 0) {
                        const nc = source[name_start - 1];
                        if (std.ascii.isAlphanumeric(nc) or nc == '_' or nc == '.') {
                            name_start -= 1;
                        } else {
                            break;
                        }
                    }
                    if (name_start == name_end) return null;
                    var trimmed = name_start;
                    while (trimmed < name_end and source[trimmed] == '.') {
                        trimmed += 1;
                    }
                    if (trimmed == name_end) return null;
                    return .{
                        .name = source[trimmed..name_end],
                        .active_param = comma_count,
                    };
                }
                depth -= 1;
            } else if (ch == ',' and depth == 0) {
                comma_count += 1;
            }
        }

        return null;
    }

    fn extractLastSegment(name: []const u8) []const u8 {
        var i = name.len;
        while (i > 0) {
            i -= 1;
            if (name[i] == '.') {
                return name[i + 1 ..];
            }
        }
        return name;
    }

    pub fn extractIdentAtOffset(source: []const u8, offset: u32) ?[]const u8 {
        if (offset >= source.len) return null;
        var start: u32 = offset;
        while (start > 0 and isIdentChar(source[start - 1])) {
            start -= 1;
        }
        var end: u32 = offset;
        while (end < source.len and isIdentChar(source[end])) {
            end += 1;
        }
        if (start == end) return null;
        return source[start..end];
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    pub fn findImportPathAtOffset(source: []const u8, offset: u32) ?[]const u8 {
        if (offset >= source.len) return null;

        var qstart: u32 = offset;
        while (qstart > 0 and source[qstart] != '"') : (qstart -= 1) {}
        if (source[qstart] != '"') return null;

        const qend: u32 = if (offset < source.len and source[offset] == '"')
            offset
        else blk: {
            var e = offset;
            while (e < source.len and source[e] != '"' and source[e] != '\n') : (e += 1) {}
            if (e >= source.len or source[e] != '"') return null;
            break :blk e;
        };

        if (qstart == qend) return null;

        var scan = qstart;
        while (scan > 0 and (source[scan - 1] == ' ' or source[scan - 1] == '\t')) : (scan -= 1) {}
        const kw = "#import";
        if (scan < kw.len) return null;
        if (!std.mem.eql(u8, source[scan - kw.len .. scan], kw)) return null;

        return source[qstart + 1 .. qend];
    }

    pub const QualifiedName = struct { ns: []const u8, member: []const u8, full_start: u32, full_end: u32 };

    /// The origin (underline) span for a definition triggered inside a
    /// qualified name: exactly the member part when the cursor sits on it,
    /// null when the cursor is on the receiver/namespace part — the caller
    /// then falls through to bare-identifier resolution so `BitWriter` in
    /// `BitWriter.init` goes to the struct, not the method.
    pub fn qualifiedMemberOrigin(qn: QualifiedName, offset: u32) ?sx.ast.Span {
        const member_start = qn.full_end - @as(u32, @intCast(qn.member.len));
        if (offset < member_start) return null;
        return .{ .start = member_start, .end = qn.full_end };
    }

    pub fn extractQualifiedName(source: []const u8, offset: u32) ?QualifiedName {
        if (offset >= source.len) return null;

        var end: u32 = offset;
        while (end < source.len and isIdentChar(source[end])) end += 1;
        var start: u32 = offset;
        while (start > 0 and isIdentChar(source[start - 1])) start -= 1;

        if (start == end) return null;

        if (start >= 2 and source[start - 1] == '.') {
            var ns_start: u32 = start - 1;
            while (ns_start > 0 and isIdentChar(source[ns_start - 1])) ns_start -= 1;
            if (ns_start < start - 1) {
                return .{
                    .ns = source[ns_start .. start - 1],
                    .member = source[start..end],
                    .full_start = ns_start,
                    .full_end = end,
                };
            }
        }

        if (end < source.len and source[end] == '.') {
            var member_end: u32 = end + 1;
            while (member_end < source.len and isIdentChar(source[member_end])) member_end += 1;
            if (member_end > end + 1) {
                return .{
                    .ns = source[start..end],
                    .member = source[end + 1 .. member_end],
                    .full_start = start,
                    .full_end = member_end,
                };
            }
        }

        return null;
    }

    pub fn findSymbolByName(symbols: []const sx.sema.Symbol, name: []const u8) ?usize {
        var i = symbols.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, symbols[i].name, name)) {
                return i;
            }
        }
        return null;
    }

    fn uriToFilePath(uri: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, uri, "file://")) {
            return uri[7..];
        }
        return null;
    }

    /// Build a `file://` URI from a document path. Import resolution keys
    /// documents by CWD-RELATIVE paths (`canonicalizePath` — the compiler's
    /// diagnostic-spelling contract), and a relative path in a `file://` URI
    /// is unopenable (the editor reads `file://modules/…` as an authority +
    /// absolute path and lands on a nonexistent file). Every outgoing URI
    /// must route through here so relative paths absolutize against the
    /// server's CWD first.
    fn fileUri(self: *Server, path: []const u8) ![]const u8 {
        if (path.len > 0 and path[0] == '/') {
            return std.fmt.allocPrint(self.allocator, "file://{s}", .{path});
        }
        if (sx.imports.processCwd(self.allocator)) |cwd| {
            return std.fmt.allocPrint(self.allocator, "file://{s}/{s}", .{ cwd, path });
        }
        return std.fmt.allocPrint(self.allocator, "file://{s}", .{path});
    }

    fn spanToRange(source: [:0]const u8, span: sx.ast.Span) lsp.Range {
        const clamped_start = @min(span.start, @as(u32, @intCast(source.len)));
        const clamped_end = @min(span.end, @as(u32, @intCast(source.len)));
        const start = sx.errors.SourceLoc.compute(source, clamped_start);
        const end = sx.errors.SourceLoc.compute(source, clamped_end);
        return .{
            .start = .{ .line = start.line - 1, .character = start.col - 1 },
            .end = .{ .line = end.line - 1, .character = end.col - 1 },
        };
    }

    fn extractDocComment(source: []const u8, def_start: u32) ?[]const u8 {
        if (def_start == 0 or def_start > source.len) return null;

        var pos: u32 = def_start;
        while (pos > 0 and source[pos - 1] != '\n') : (pos -= 1) {}
        if (pos == 0) return null;

        const block_end = pos;
        var block_start = pos;

        while (block_start > 0) {
            var scan = block_start - 1;
            while (scan > 0 and source[scan - 1] != '\n') : (scan -= 1) {}
            const line = std.mem.trimEnd(u8, source[scan..block_start], "\r\n");
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') {
                block_start = scan;
            } else {
                break;
            }
        }

        if (block_start >= block_end) return null;
        var end_pos = block_end;
        while (end_pos > block_start and (source[end_pos - 1] == '\n' or source[end_pos - 1] == '\r')) : (end_pos -= 1) {}
        if (end_pos <= block_start) return null;
        return source[block_start..end_pos];
    }

    fn extractBaseTypeName(type_node: *sx.ast.Node) ?[]const u8 {
        return switch (type_node.data) {
            .type_expr => |te| te.name,
            .pointer_type_expr => |pte| extractBaseTypeName(pte.pointee_type),
            .parameterized_type_expr => |pte| pte.name,
            else => null,
        };
    }

    fn findDeclByName(root: *sx.ast.Node, name: []const u8) ?*sx.ast.Node {
        if (root.data != .root) return null;
        for (root.data.root.decls) |decl| {
            if (decl.data.declName()) |dn| {
                if (std.mem.eql(u8, dn, name)) return decl;
            }
        }
        return null;
    }

    fn formatDeclHover(allocator: std.mem.Allocator, decl: *sx.ast.Node, source: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;

        if (extractDocComment(source, decl.span.start)) |comment| {
            try buf.appendSlice(allocator, comment);
            try buf.appendSlice(allocator, "\n\n");
        }

        try buf.appendSlice(allocator, "```sx\n");

        switch (decl.data) {
            .fn_decl => |fd| {
                try buf.appendSlice(allocator, fd.name);
                try buf.appendSlice(allocator, " :: (");
                for (fd.params, 0..) |param, pi| {
                    if (pi > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, param.name);
                    if (param.type_expr.data != .inferred_type) {
                        try buf.appendSlice(allocator, ": ");
                        if (param.type_expr.data == .type_expr) {
                            try buf.appendSlice(allocator, param.type_expr.data.type_expr.name);
                        } else {
                            try buf.appendSlice(allocator, "?");
                        }
                    }
                }
                try buf.append(allocator, ')');
                if (fd.return_type) |rt| {
                    try buf.appendSlice(allocator, " -> ");
                    if (rt.data == .type_expr) {
                        try buf.appendSlice(allocator, rt.data.type_expr.name);
                    }
                }
            },
            .enum_decl => |ed| {
                try buf.appendSlice(allocator, ed.name);
                if (ed.is_flags) {
                    try buf.appendSlice(allocator, " :: enum flags ");
                } else {
                    try buf.appendSlice(allocator, " :: enum ");
                }
                if (ed.backing_type) |bt| {
                    if (bt.data == .type_expr) {
                        try buf.appendSlice(allocator, bt.data.type_expr.name);
                        try buf.appendSlice(allocator, " ");
                    } else if (bt.data == .struct_decl) {
                        const sd = bt.data.struct_decl;
                        try buf.appendSlice(allocator, "struct { ");
                        for (sd.field_names, 0..) |fn_, fi| {
                            if (fi > 0) try buf.appendSlice(allocator, "; ");
                            try buf.appendSlice(allocator, fn_);
                            try buf.appendSlice(allocator, ": ");
                            if (fi < sd.field_types.len) {
                                if (sd.field_types[fi].data == .type_expr) {
                                    try buf.appendSlice(allocator, sd.field_types[fi].data.type_expr.name);
                                } else if (sd.field_types[fi].data == .array_type_expr) {
                                    const ate = sd.field_types[fi].data.array_type_expr;
                                    try buf.append(allocator, '[');
                                    if (ate.length.data == .int_literal) {
                                        const val = ate.length.data.int_literal.value;
                                        var num_buf: [20]u8 = undefined;
                                        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch "?";
                                        try buf.appendSlice(allocator, num_str);
                                    }
                                    try buf.append(allocator, ']');
                                    if (ate.element_type.data == .type_expr) {
                                        try buf.appendSlice(allocator, ate.element_type.data.type_expr.name);
                                    }
                                }
                            }
                        }
                        try buf.appendSlice(allocator, " } ");
                    }
                }
                try buf.appendSlice(allocator, "{ ");
                for (ed.variant_names, 0..) |v, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.append(allocator, '.');
                    try buf.appendSlice(allocator, v);
                }
                try buf.appendSlice(allocator, " }");
            },
            .struct_decl => |sd| {
                try buf.appendSlice(allocator, sd.name);
                try buf.appendSlice(allocator, " :: struct { ");
                for (sd.field_names, 0..) |fn_, fi| {
                    if (fi > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, fn_);
                    if (fi < sd.field_types.len) {
                        if (sd.field_types[fi].data == .type_expr) {
                            try buf.appendSlice(allocator, ": ");
                            try buf.appendSlice(allocator, sd.field_types[fi].data.type_expr.name);
                        }
                    }
                }
                try buf.appendSlice(allocator, " }");
            },
            .union_decl => |ud| {
                try buf.appendSlice(allocator, ud.name);
                try buf.appendSlice(allocator, " :: union { ");
                for (ud.field_names, 0..) |fn_name, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    // Anonymous struct fields: show as "struct { ... }"
                    if (std.mem.startsWith(u8, fn_name, "__anon_")) {
                        if (i < ud.field_types.len and ud.field_types[i].data == .type_expr) {
                            try buf.appendSlice(allocator, ud.field_types[i].data.type_expr.name);
                        } else {
                            try buf.appendSlice(allocator, "struct { ... }");
                        }
                    } else {
                        try buf.appendSlice(allocator, fn_name);
                        if (i < ud.field_types.len) {
                            try buf.appendSlice(allocator, ": ");
                            if (ud.field_types[i].data == .type_expr) {
                                try buf.appendSlice(allocator, ud.field_types[i].data.type_expr.name);
                            }
                        }
                    }
                }
                try buf.appendSlice(allocator, " }");
            },
            .protocol_decl => |pd| {
                try buf.appendSlice(allocator, pd.name);
                try buf.appendSlice(allocator, " :: protocol");
                if (pd.is_inline) try buf.appendSlice(allocator, " #inline");
                if (pd.is_identity) try buf.appendSlice(allocator, " #identity");
                try buf.appendSlice(allocator, " { ");
                for (pd.methods, 0..) |method, mi| {
                    if (mi > 0) try buf.appendSlice(allocator, " ");
                    try buf.appendSlice(allocator, method.name);
                    try buf.appendSlice(allocator, " :: (");
                    for (method.param_names, 0..) |pname, pi| {
                        if (pi > 0) try buf.appendSlice(allocator, ", ");
                        try buf.appendSlice(allocator, pname);
                        if (pi < method.params.len) {
                            try buf.appendSlice(allocator, ": ");
                            if (method.params[pi].data == .type_expr) {
                                try buf.appendSlice(allocator, method.params[pi].data.type_expr.name);
                            } else {
                                try buf.appendSlice(allocator, "?");
                            }
                        }
                    }
                    try buf.append(allocator, ')');
                    if (method.return_type) |rt| {
                        try buf.appendSlice(allocator, " -> ");
                        if (rt.data == .type_expr) {
                            try buf.appendSlice(allocator, rt.data.type_expr.name);
                        }
                    }
                    try buf.appendSlice(allocator, ";");
                }
                try buf.appendSlice(allocator, " }");
            },
            .impl_block => |ib| {
                try buf.appendSlice(allocator, "impl ");
                try buf.appendSlice(allocator, ib.protocol_name);
                try buf.appendSlice(allocator, " for ");
                try buf.appendSlice(allocator, ib.target_type);
            },
            .const_decl => |cd| {
                try buf.appendSlice(allocator, cd.name);
                try buf.appendSlice(allocator, " :: ");
                if (cd.type_annotation) |ta| {
                    if (ta.data == .type_expr) {
                        try buf.appendSlice(allocator, ta.data.type_expr.name);
                    }
                }
            },
            .var_decl => |vd| {
                try buf.appendSlice(allocator, vd.name);
                if (vd.type_annotation) |ta| {
                    if (ta.data == .type_expr) {
                        try buf.appendSlice(allocator, " : ");
                        try buf.appendSlice(allocator, ta.data.type_expr.name);
                    }
                }
            },
            else => {
                try buf.appendSlice(allocator, "(declaration)");
            },
        }

        try buf.appendSlice(allocator, "\n```");
        return buf.items;
    }

    fn formatSymbolHover(allocator: std.mem.Allocator, sym: sx.sema.Symbol, root: *sx.ast.Node, source: [:0]const u8) ![]const u8 {
        // Try offset-based AST lookup
        if (sym.def_span.start < source.len) {
            if (sx.sema.findNodeAtOffset(root, sym.def_span.start)) |node| {
                if (node.data.declName()) |dn| {
                    if (std.mem.eql(u8, dn, sym.name)) {
                        return try formatDeclHover(allocator, node, source);
                    }
                }
            }
        }

        // Fallback: name-based lookup
        if (findDeclByName(root, sym.name)) |decl| {
            return try formatDeclHover(allocator, decl, source);
        }

        // Last resort: simple format
        var buf = std.ArrayList(u8).empty;

        if (sym.def_span.start < source.len) {
            if (extractDocComment(source, sym.def_span.start)) |comment| {
                try buf.appendSlice(allocator, comment);
                try buf.appendSlice(allocator, "\n\n");
            }
        }

        try buf.appendSlice(allocator, "```sx\n");

        switch (sym.kind) {
            .function => {
                try buf.appendSlice(allocator, sym.name);
                try buf.appendSlice(allocator, " :: (...)");
                if (sym.ty) |ty| {
                    try buf.appendSlice(allocator, " -> ");
                    const type_name = try ty.displayName(allocator);
                    try buf.appendSlice(allocator, type_name);
                }
            },
            .variable => {
                try buf.appendSlice(allocator, sym.name);
                if (sym.ty) |ty| {
                    try buf.appendSlice(allocator, " : ");
                    const type_name = try ty.displayName(allocator);
                    try buf.appendSlice(allocator, type_name);
                }
            },
            .constant => {
                try buf.appendSlice(allocator, sym.name);
                try buf.appendSlice(allocator, " :: ");
                if (sym.ty) |ty| {
                    const type_name = try ty.displayName(allocator);
                    try buf.appendSlice(allocator, type_name);
                } else {
                    try buf.appendSlice(allocator, "(constant)");
                }
            },
            .param => {
                try buf.appendSlice(allocator, sym.name);
                if (sym.ty) |ty| {
                    try buf.appendSlice(allocator, " : ");
                    const type_name = try ty.displayName(allocator);
                    try buf.appendSlice(allocator, type_name);
                }
            },
            .enum_type => {
                try buf.appendSlice(allocator, sym.name);
                try buf.appendSlice(allocator, " :: enum { ... }");
            },
            .struct_type => {
                try buf.appendSlice(allocator, sym.name);
                try buf.appendSlice(allocator, " :: struct { ... }");
            },
            .protocol_type => {
                try buf.appendSlice(allocator, sym.name);
                try buf.appendSlice(allocator, " :: protocol { ... }");
            },
            .type_alias => {
                try buf.appendSlice(allocator, sym.name);
                try buf.appendSlice(allocator, " :: (type)");
            },
            .namespace => {
                try buf.appendSlice(allocator, sym.name);
                try buf.appendSlice(allocator, " :: (namespace)");
            },
        }

        try buf.appendSlice(allocator, "\n```");
        return buf.items;
    }
};

test "findMatchSubjectText: simple identifier" {
    const source = "if event == {\n    case .";
    const result = Server.findMatchSubjectText(source, @intCast(source.len));
    try std.testing.expectEqualStrings("event", result.?);
}

test "findMatchSubjectText: field access" {
    const source = "if e.key == {\n    case .";
    const result = Server.findMatchSubjectText(source, @intCast(source.len));
    try std.testing.expectEqualStrings("e.key", result.?);
}

test "findMatchSubjectText: nested braces" {
    const source = "if event == {\n    case .quit: { do_something(); }\n    case .";
    const result = Server.findMatchSubjectText(source, @intCast(source.len));
    try std.testing.expectEqualStrings("event", result.?);
}

test "findMatchSubjectText: no match context" {
    const source = "while true {\n    case .";
    const result = Server.findMatchSubjectText(source, @intCast(source.len));
    try std.testing.expect(result == null);
}

test "findCaptureVariant: simple capture" {
    const source = "case .key_down: (e) {\n    e.";
    const result = Server.findCaptureVariant(source, @intCast(source.len), "e");
    try std.testing.expectEqualStrings("key_down", result.?);
}

test "findCaptureVariant: different name" {
    const source = "case .mouse_motion: (evt) {\n    evt.";
    const result = Server.findCaptureVariant(source, @intCast(source.len), "evt");
    try std.testing.expectEqualStrings("mouse_motion", result.?);
}

test "findCaptureVariant: no capture" {
    const source = "case .quit: running = false;\n    e.";
    const result = Server.findCaptureVariant(source, @intCast(source.len), "e");
    try std.testing.expect(result == null);
}

// ---- Helper function tests ----

test "extractQualifiedName: namespace.member at member offset" {
    const source = "pkg.mul(3, 4)";
    // offset inside "mul" (index 4)
    const result = Server.extractQualifiedName(source, 4);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("pkg", result.?.ns);
    try std.testing.expectEqualStrings("mul", result.?.member);
}

test "extractQualifiedName: namespace.member at namespace offset" {
    const source = "pkg.mul(3, 4)";
    // offset inside "pkg" (index 1)
    const result = Server.extractQualifiedName(source, 1);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("pkg", result.?.ns);
    try std.testing.expectEqualStrings("mul", result.?.member);
}

test "extractQualifiedName: bare identifier returns null" {
    const source = "hello(42)";
    const result = Server.extractQualifiedName(source, 2);
    try std.testing.expect(result == null);
}

test "extractQualifiedName: chained a.b.c at c offset" {
    const source = "a.b.c(1)";
    // offset inside "c" (index 4)
    const result = Server.extractQualifiedName(source, 4);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("b", result.?.ns);
    try std.testing.expectEqualStrings("c", result.?.member);
}

// The definition origin (the editor's cmd-hover underline) for a qualified
// name covers ONLY the member, never the whole `Receiver.member` expression.
test "qualifiedMemberOrigin: member offset underlines just the member" {
    const source = "writer := BitWriter.init(alloc);";
    const init_off: u32 = @intCast(std.mem.indexOf(u8, source, "init").?);
    const qn = Server.extractQualifiedName(source, init_off + 2).?;
    const origin = Server.qualifiedMemberOrigin(qn, init_off + 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(init_off, origin.start);
    try std.testing.expectEqual(init_off + @as(u32, "init".len), origin.end);
}

// Cursor on the receiver part → null, so definition falls through to
// bare-identifier resolution (the receiver itself), not the member.
test "qualifiedMemberOrigin: receiver offset falls through" {
    const source = "writer := BitWriter.init(alloc);";
    const bw_off: u32 = @intCast(std.mem.indexOf(u8, source, "BitWriter").?);
    const qn = Server.extractQualifiedName(source, bw_off + 3).?;
    try std.testing.expect(Server.qualifiedMemberOrigin(qn, bw_off + 3) == null);
}

test "positionToOffset: line 0 char 0" {
    const source = "hello\nworld\n";
    const result = Server.positionToOffset(source, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), result.?);
}

test "positionToOffset: line 1 char 0" {
    const source = "hello\nworld\n";
    const result = Server.positionToOffset(source, 1, 0);
    try std.testing.expectEqual(@as(u32, 6), result.?);
}

test "positionToOffset: line 0 char 3" {
    const source = "hello\nworld\n";
    const result = Server.positionToOffset(source, 0, 3);
    try std.testing.expectEqual(@as(u32, 3), result.?);
}

test "extractIdentAtOffset: middle of identifier" {
    const source = "foo bar baz";
    const result = Server.extractIdentAtOffset(source, 5);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("bar", result.?);
}

test "extractIdentAtOffset: at end of identifier scans back" {
    // Cursor just past "foo" (on the space) resolves the word to its left.
    const source = "foo bar";
    const result = Server.extractIdentAtOffset(source, 3);
    try std.testing.expectEqualStrings("foo", result.?);
}

test "extractIdentAtOffset: surrounded by whitespace returns null" {
    const source = "a  b";
    const result = Server.extractIdentAtOffset(source, 2);
    try std.testing.expect(result == null);
}

test "findSymbolByName: finds existing symbol" {
    const symbols = [_]sx.sema.Symbol{
        .{ .name = "add", .kind = .function, .ty = null, .def_span = .{ .start = 0, .end = 3 }, .scope_depth = 0 },
        .{ .name = "mul", .kind = .function, .ty = null, .def_span = .{ .start = 10, .end = 13 }, .scope_depth = 0 },
    };
    const result = Server.findSymbolByName(&symbols, "mul");
    try std.testing.expectEqual(@as(usize, 1), result.?);
}

test "findSymbolByName: returns null for missing" {
    const symbols = [_]sx.sema.Symbol{
        .{ .name = "add", .kind = .function, .ty = null, .def_span = .{ .start = 0, .end = 3 }, .scope_depth = 0 },
    };
    const result = Server.findSymbolByName(&symbols, "sub");
    try std.testing.expect(result == null);
}

test "findImportPathAtOffset: inside import string" {
    const source = "#import \"modules/std.sx\";";
    // offset inside the string (index 10)
    const result = Server.findImportPathAtOffset(source, 10);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("modules/std.sx", result.?);
}

test "findImportPathAtOffset: outside import returns null" {
    const source = "x := 42;";
    const result = Server.findImportPathAtOffset(source, 2);
    try std.testing.expect(result == null);
}

// ---- Document analysis pipeline tests ----

test "analyzeDocument: parse and sema basic function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "add :: (a: i32, b: i32) -> i32 { a + b; }";
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = doc.sema orelse return error.SkipZigTest;
    // Should have "add" as a function symbol
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "add") != null);
    const idx = Server.findSymbolByName(sema.symbols, "add").?;
    try std.testing.expectEqual(sx.sema.SymbolKind.function, sema.symbols[idx].kind);
}

test "analyzeDocument: flat import pre-registers symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    // Pre-load the imported module
    const lib_src: [:0]const u8 = "mul :: (a: i32, b: i32) -> i32 { a * b; }";
    const lib_doc = try store.openOrUpdate("lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    // Load main file with flat import
    const main_src: [:0]const u8 =
        \\#import "lib.sx";
        \\main :: () -> i32 { mul(3, 4); }
    ;
    const main_doc = try store.openOrUpdate("main.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    // "mul" should be pre-registered from flat import
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "mul") != null);
    // "main" should be defined locally
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "main") != null);
}

test "analyzeDocument: namespaced import registers namespace symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    // Pre-load the imported module
    const lib_src: [:0]const u8 = "add :: (a: i32, b: i32) -> i32 { a + b; }";
    const lib_doc = try store.openOrUpdate("lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    // Load main file with namespaced import
    const main_src: [:0]const u8 =
        \\pkg :: #import "lib.sx";
        \\main :: () -> i32 { pkg.add(3, 4); }
    ;
    const main_doc = try store.openOrUpdate("main.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    // "pkg" should be a namespace symbol
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "pkg") != null);
    const idx = Server.findSymbolByName(sema.symbols, "pkg").?;
    try std.testing.expectEqual(sx.sema.SymbolKind.namespace, sema.symbols[idx].kind);
}

test "analyzeDocument: namespaced import fn_signatures have prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const lib_src: [:0]const u8 = "add :: (a: i32, b: i32) -> i32 { a + b; }";
    const lib_doc = try store.openOrUpdate("lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    const main_src: [:0]const u8 =
        \\pkg :: #import "lib.sx";
        \\main :: () -> i32 { pkg.add(1, 2); }
    ;
    const main_doc = try store.openOrUpdate("main.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    // fn_signatures should contain "pkg.add"
    try std.testing.expect(sema.fn_signatures.contains("pkg.add"));
}

test "analyzeDocument: pipe operator desugars to call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const lib_src: [:0]const u8 = "add :: (a: i32, b: i32) -> i32 { a + b; }";
    const lib_doc = try store.openOrUpdate("lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    // Pipe operator should parse and analyze without errors
    const main_src: [:0]const u8 =
        \\pkg :: #import "lib.sx";
        \\main :: () -> i32 { 3 |> pkg.add(4); }
    ;
    const main_doc = try store.openOrUpdate("main.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    // Should parse successfully with no sema errors for "add"
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "main") != null);
}

test "analyzeDocument: for-loop capture variables are registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const src: [:0]const u8 =
        \\main :: () {
        \\    arr : [3]i32 = ---;
        \\    for arr, 0.. (it, ix) {
        \\        x := it + ix;
        \\    }
        \\}
    ;
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = doc.sema orelse return error.SkipZigTest;
    // Capture variables should be registered — "it" and "ix" should not produce unresolved errors
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "it") != null);
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "ix") != null);
    // "x" should also be registered
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "x") != null);
}

test "analyzeDocument: for-loop with underscore capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const src: [:0]const u8 =
        \\main :: () {
        \\    arr : [3]i32 = ---;
        \\    for arr, 0.. (_, ix) {
        \\        x := ix;
        \\    }
        \\}
    ;
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = doc.sema orelse return error.SkipZigTest;
    // "_" should NOT be registered as a symbol
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "_") == null);
    // "ix" should be registered
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "ix") != null);
}

test "analyzeDocument: for-loop value-only capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const src: [:0]const u8 =
        \\main :: () {
        \\    arr : [3]i32 = ---;
        \\    for arr (val) {
        \\        x := val;
        \\    }
        \\}
    ;
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    const sema = doc.sema orelse return error.SkipZigTest;
    // "val" should be registered
    try std.testing.expect(Server.findSymbolByName(sema.symbols, "val") != null);
}

/// A real std.Io for the document-store tests. Import resolution touches the
/// filesystem (to probe candidate paths), so a working io is required; the
/// pre-loaded `by_path` entries win over disk, so the probes harmlessly miss.
/// Process-lifetime and intentionally never deinitialised.
var g_test_threaded: ?std.Io.Threaded = null;
fn test_io() std.Io {
    if (g_test_threaded == null) {
        g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return g_test_threaded.?.io();
}

test "lsp/references: a field's uses are found across documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const lib_src: [:0]const u8 = "Move :: struct { flag: i64; }";
    const lib_doc = try store.openOrUpdate("lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    const main_src: [:0]const u8 =
        \\#import "lib.sx";
        \\use :: (m: *Move) -> i64 { m.flag; }
    ;
    const main_doc = try store.openOrUpdate("main.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    var server = Server{ .allocator = alloc, .documents = store, .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };

    // Cursor on the `flag` field definition in lib.sx.
    const flag_off: u32 = @intCast(std.mem.indexOf(u8, lib_src, "flag").?);
    const payload = try server.referencesPayload(lib_doc, &lib_doc.sema.?, flag_off, true);

    // The definition (lib.sx) plus the one use (main.sx) — even though main.sx
    // is a different document that only learns `Move` through the import.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, payload, "\"uri\""));
    try std.testing.expect(std.mem.indexOf(u8, payload, "lib.sx") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "main.sx") != null);
}

test "lsp/references: excluding the declaration drops the definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "Move :: struct { flag: i64; } use :: (m: *Move) -> i64 { m.flag; }";
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    var server = Server{ .allocator = alloc, .documents = store, .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };
    const flag_off: u32 = @intCast(std.mem.indexOf(u8, src, "flag").?);

    const with_decl = try server.referencesPayload(doc, &doc.sema.?, flag_off, true);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, with_decl, "\"uri\""));
    const without_decl = try server.referencesPayload(doc, &doc.sema.?, flag_off, false);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, without_decl, "\"uri\""));
}

test "lsp/definition: cursor on a member declaration resolves to itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "Move :: struct { flag: i64; }";
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);
    const sema = doc.sema orelse return error.SkipZigTest;

    // On the `flag` field declaration → resolves to itself (so the editor
    // offers references on a definition-click instead of doing nothing).
    const flag_off: u32 = @intCast(std.mem.indexOf(u8, src, "flag").?);
    const span = Server.selfMemberDefAt(&sema, flag_off) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(flag_off, span.start);

    // On the struct name (not a member declaration) → null, so normal
    // resolution still runs.
    try std.testing.expect(Server.selfMemberDefAt(&sema, 0) == null);
}

test "lsp/inlayHint: a for-loop capture in a struct method shows its element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const lib_src: [:0]const u8 =
        \\Move :: struct { flag: i64; }
        \\List :: struct ($T: Type) { items: [*]T = null; len: i64 = 0; }
    ;
    const lib_doc = try store.openOrUpdate("lib.sx", lib_src, 1);
    try store.analyzeDocument(lib_doc);

    const main_src: [:0]const u8 =
        \\#import "lib.sx";
        \\Game :: struct {
        \\    legal: List(Move);
        \\    scan :: (self: *Game) {
        \\        for self.legal (m) { x := m.flag; }
        \\    }
        \\}
    ;
    const main_doc = try store.openOrUpdate("main.sx", main_src, 1);
    try store.analyzeDocument(main_doc);

    const sema = main_doc.sema orelse return error.SkipZigTest;
    var hints = std.ArrayList(lsp.InlayHint).empty;
    Server.collectInlayHints(alloc, main_doc.root.?, sema.symbols, sema.fn_signatures, main_doc.source, &hints);

    // The capture `m` iterates `List(Move)`, so it is hinted `: Move` — which
    // requires descending into struct method bodies and resolving the element.
    var found_move = false;
    for (hints.items) |h| {
        if (std.mem.indexOf(u8, h.label, "Move") != null) found_move = true;
    }
    try std.testing.expect(found_move);
}

test "lsp/workspace: loadWorkspaceFiles analyses .sx files that were never opened" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();

    const dir = ".sx-lsp-ws-test";
    std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
    defer {
        std.Io.Dir.deleteFile(.cwd(), io, dir ++ "/a.sx") catch {};
        std.Io.Dir.deleteFile(.cwd(), io, dir ++ "/b.sx") catch {};
        std.Io.Dir.deleteDir(.cwd(), io, dir) catch {};
    }
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = dir ++ "/a.sx", .data = "Foo :: struct { x: i64; }" });
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = dir ++ "/b.sx", .data = "Bar :: struct { y: i64; }" });

    var store = doc_mod.DocumentStore.init(alloc, io, &.{});
    store.root_path = dir;
    store.loadWorkspaceFiles();

    // Both files are loaded and analysed without any didOpen — this is what
    // makes find-references work when the using files aren't open in the editor.
    const a = store.get(dir ++ "/a.sx") orelse return error.TestUnexpectedResult;
    const b = store.get(dir ++ "/b.sx") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a.sema != null);
    try std.testing.expect(b.sema != null);
}

test "lsp/project: whole-program check attributes a reachable error to its module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = test_io();

    const dir = ".sx-lsp-proj-test";
    std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
    defer {
        std.Io.Dir.deleteFile(.cwd(), io, dir ++ "/main.sx") catch {};
        std.Io.Dir.deleteFile(.cwd(), io, dir ++ "/mod.sx") catch {};
        std.Io.Dir.deleteDir(.cwd(), io, dir) catch {};
    }
    // `use` forwards a `*Move` into a by-value parameter — an error the compiler
    // only sees because `main` calls `use` (reachability). Lowering mod.sx alone
    // would miss it; the whole-program check catches it and pins it to mod.sx.
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = dir ++ "/mod.sx", .data =
        "Move :: struct { flag: i64; }\n" ++
        "take :: (m: Move) -> i64 { return m.flag; }\n" ++
        "use :: (p: *Move) -> i64 { return take(p); }\n" });
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = dir ++ "/main.sx", .data =
        "#import \"mod.sx\";\n" ++
        "main :: () -> i32 { mv : Move = .{ flag = 1 }; return xx use(*mv); }\n" });

    const store = doc_mod.DocumentStore.init(alloc, io, &.{});
    var server = Server{
        .allocator = alloc,
        .documents = store,
        .transport = undefined,
        .io = io,
        .project_diag_uris = std.StringHashMap(void).init(alloc),
    };

    var found = false;
    for (server.collectProjectDiagnostics(dir ++ "/main.sx")) |d| {
        if (std.mem.indexOf(u8, d.message, "expected here") != null and std.mem.endsWith(u8, d.file_path, "mod.sx")) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

// ---- Context extension LSP (design/context-extension.md, context-lsp unit) ----

// Definition targets for Context fields resolve program-wide: the
// `#context_extend` declaration is found across documents, and the reading
// document needs NO import of the declaring module (the L3 pin's LSP twin).
test "lsp/context: cross-file field def resolves without an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const decl_src: [:0]const u8 = "#context_extend trace_depth: i64 = 3;";
    const decl_doc = try store.openOrUpdate("ctx_decl.sx", decl_src, 1);
    try store.analyzeDocument(decl_doc);

    // Reader: no #import of ctx_decl.sx.
    const reader_src: [:0]const u8 = "reader :: () -> i64 { return context.trace_depth; }";
    const reader_doc = try store.openOrUpdate("reader.sx", reader_src, 1);
    try store.analyzeDocument(reader_doc);

    // The declaration is discoverable from the store...
    const hit = Server.findContextExtendDecl(&store, "trace_depth") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ctx_decl.sx", hit.doc.path);
    const decl_name_off: u32 = @intCast(std.mem.indexOf(u8, decl_src, "trace_depth").?);
    try std.testing.expectEqual(decl_name_off, hit.ce.name_span.start);

    // ...and so is the member DEF the read resolves to.
    const def = Server.findMemberDefAcrossDocs(&store, "Context", "trace_depth") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ctx_decl.sx", def.doc.path);

    // The read itself is a member USE under the cursor.
    const read_off: u32 = @intCast(std.mem.indexOf(u8, reader_src, "trace_depth").?);
    const use = Server.memberUseAt(&reader_doc.sema.?, read_off) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Context", use.owner);
}

// Find-all-references from the `#context_extend` declaration lists every
// `context.field` read and push-literal patch site program-wide.
test "lsp/context: references span reads and push sites across documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});

    const decl_src: [:0]const u8 = "#context_extend trace_depth: i64 = 3;";
    const decl_doc = try store.openOrUpdate("ctx_decl.sx", decl_src, 1);
    try store.analyzeDocument(decl_doc);

    const reader_src: [:0]const u8 = "reader :: () -> i64 { return context.trace_depth; }";
    const reader_doc = try store.openOrUpdate("reader.sx", reader_src, 1);
    try store.analyzeDocument(reader_doc);

    const pusher_src: [:0]const u8 = "pusher :: () { push .{ trace_depth = 7 } { } }";
    const pusher_doc = try store.openOrUpdate("pusher.sx", pusher_src, 1);
    try store.analyzeDocument(pusher_doc);

    var server = Server{ .allocator = alloc, .documents = store, .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };

    const decl_off: u32 = @intCast(std.mem.indexOf(u8, decl_src, "trace_depth").?);
    const payload = try server.referencesPayload(decl_doc, &decl_doc.sema.?, decl_off, true);

    // Declaration + read + push site.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, payload, "\"uri\""));
    try std.testing.expect(std.mem.indexOf(u8, payload, "ctx_decl.sx") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "reader.sx") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "pusher.sx") != null);
}

// Hover on a Context field shows the declaration spelling and declaring file.
test "lsp/context: hover carries type, default, and declaring module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const decl_src: [:0]const u8 = "#context_extend ui_scale: f64 = 1.5;";
    const decl_doc = try store.openOrUpdate("ui_mod.sx", decl_src, 1);
    try store.analyzeDocument(decl_doc);

    var server = Server{ .allocator = alloc, .documents = store, .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };

    const hover = (try server.formatContextFieldHover(decl_doc, "ui_scale")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, hover, "#context_extend ui_scale: f64 = 1.5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover, "ui_mod.sx") != null);
}

// Completion after `context.` includes every `#context_extend` field with its
// declared type and declaring file.
test "lsp/context: completion lists extension fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const decl_src: [:0]const u8 = "#context_extend ui_scale: f64 = 1.5;\n#context_extend frame_no: i64 = 0;";
    const decl_doc = try store.openOrUpdate("ui_mod.sx", decl_src, 1);
    try store.analyzeDocument(decl_doc);

    var server = Server{ .allocator = alloc, .documents = store, .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };

    var items = std.ArrayList(lsp.CompletionItem).empty;
    try server.appendContextFieldCompletions(&items, decl_doc.sema.?, decl_doc);

    var saw_scale = false;
    var saw_frame = false;
    for (items.items) |it| {
        if (std.mem.eql(u8, it.label, "ui_scale")) {
            saw_scale = true;
            try std.testing.expect(std.mem.indexOf(u8, it.detail.?, "f64") != null);
            try std.testing.expect(std.mem.indexOf(u8, it.detail.?, "ui_mod.sx") != null);
        }
        if (std.mem.eql(u8, it.label, "frame_no")) saw_frame = true;
    }
    try std.testing.expect(saw_scale and saw_frame);
}

// The push-literal position detector: field-name positions inside
// `push .{ … }` qualify; other braces and closed literals do not.
test "lsp/context: insidePushLiteral detection" {
    const src1 = "main :: () { push .{ tr";
    try std.testing.expect(Server.insidePushLiteral(src1, @intCast(src1.len)));

    const src2 = "main :: () { foo(.{ tr";
    try std.testing.expect(!Server.insidePushLiteral(src2, @intCast(src2.len)));

    const src3 = "main :: () { push .{ a = 1 } ";
    try std.testing.expect(!Server.insidePushLiteral(src3, @intCast(src3.len)));

    const src4 = "main :: () { pushx .{ tr";
    try std.testing.expect(!Server.insidePushLiteral(src4, @intCast(src4.len)));
}

// Hover on the bare `context` identifier enumerates the whole assembled
// Context — builtin prefix + extensions, each with its declaring module.
test "lsp/context: bare context hover enumerates the assembled struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 =
        \\Context :: struct { allocator: i64; }
        \\#context_extend ui_scale: f64 = 1.5;
    ;
    const doc = try store.openOrUpdate("main.sx", src, 1);
    try store.analyzeDocument(doc);

    var server = Server{ .allocator = alloc, .documents = store, .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };

    const hover = (try server.formatContextHover(doc.sema.?, doc)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, hover, "allocator") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover, "ui_scale: f64") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover, "main.sx") != null);
}

// Regression (QA 2026-07-19): go-to-definition into an imported stdlib file
// produced `file://modules/ffi/objc_block.sx` — import resolution keys
// documents CWD-RELATIVE (the compiler's diagnostic-spelling contract), and
// the editor reads a relative `file://` URI as authority + absolute path,
// landing on a nonexistent `/modules/…`. Every outgoing URI now routes
// through `fileUri`, which absolutizes relative paths against the server CWD.
test "lsp/uri: relative document paths absolutize against the server cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var server = Server{ .allocator = alloc, .documents = doc_mod.DocumentStore.init(alloc, test_io(), &.{}), .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };

    const rel = try server.fileUri("modules/ffi/objc_block.sx");
    try std.testing.expect(std.mem.startsWith(u8, rel, "file:///"));
    try std.testing.expect(std.mem.endsWith(u8, rel, "/modules/ffi/objc_block.sx"));

    const abs = try server.fileUri("/tmp/x.sx");
    try std.testing.expectEqualStrings("file:///tmp/x.sx", abs);
}

// The payload-level pin of the same regression: a references payload over
// relative-keyed documents carries only absolute file:// URIs.
test "lsp/uri: references payload URIs are absolute for relative-keyed docs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = doc_mod.DocumentStore.init(alloc, test_io(), &.{});
    const src: [:0]const u8 = "Move :: struct { flag: i64; } use :: (m: *Move) -> i64 { m.flag; }";
    const doc = try store.openOrUpdate("rel_dir/main.sx", src, 1);
    try store.analyzeDocument(doc);

    var server = Server{ .allocator = alloc, .documents = store, .transport = undefined, .io = test_io(), .project_diag_uris = std.StringHashMap(void).init(alloc) };
    const flag_off: u32 = @intCast(std.mem.indexOf(u8, src, "flag").?);
    const payload = try server.referencesPayload(doc, &doc.sema.?, flag_off, true);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"uri\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "file:///") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "file://rel_dir") == null);
}
