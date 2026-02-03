//! Context extension — `#context_extend` collection pass
//! (design/context-extension.md).
//!
//! Gathers every `#context_extend` declaration across the compilation into
//! `ProgramIndex.context_extensions`, sorted per L6 by (declaring module
//! path, field name), and validates:
//!   - L4: one flat program-global namespace — a field name declared twice
//!     (or colliding with a field of the declared `Context` struct) is a
//!     hard error naming both declaration sites.
//!   - L5: a declaration without a default is an error (the default context
//!     must be constructible before `main` runs).
//!
//! The pass runs UNCONDITIONALLY — also in no-context builds, where the
//! declarations are inert (O3) but the collected list still powers the
//! registered-field diagnostic.
//!
//! `assembleContext` (run after `scanDecls`, once every named type is
//! registered) then APPENDS the valid entries' fields to the registered
//! `Context` struct type — `findByName("Context")` stays the single
//! authority, so push lowering, field access, the hidden-param typing, the
//! comptime VM, and reflection all follow the assembled layout with no
//! further plumbing. Each field's type resolves in its DECLARING module's
//! visibility context. `__sx_default_context` emission
//! (`emitDefaultContextGlobal`) walks the assembled fields by name.

const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const program_index_mod = @import("../program_index.zig");
const ContextFieldDecl = program_index_mod.ContextFieldDecl;
const errors = @import("../../errors.zig");
const types_mod = @import("../types.zig");
const inst_mod = @import("../inst.zig");

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;

/// Program-index collection pass for `#context_extend` (pass 0a family; runs
/// from `lowerRoot` right after `detectContextDecl`, before `scanDecls`).
pub fn collectContextExtensions(self: *Lowering, decls: []const *const Node) void {
    var entries = std.ArrayList(ContextFieldDecl).empty;
    // The flat decl list dedups by node identity, but a module reachable both
    // flat and through a namespace wrapper contributes its decls twice to the
    // walk — dedup by node identity here so one declaration is one entry.
    var seen_nodes = std.AutoHashMap(*const Node, void).init(self.alloc);
    defer seen_nodes.deinit();
    gatherEntries(self, decls, &entries, &seen_nodes);
    if (entries.items.len == 0) return;

    // L6 deterministic order: (declaring module path, field name). Stable, so
    // a same-module duplicate keeps its source order for the L4 error.
    std.sort.insertion(ContextFieldDecl, entries.items, {}, entryLessThan);

    const ext = entries.toOwnedSlice(self.alloc) catch return;
    self.program_index.context_extensions = ext;

    const diags = self.diagnostics orelse return;

    // L5: defaults are mandatory.
    for (ext) |*e| {
        if (e.default_expr != null) continue;
        e.valid = false;
        self.context_structural_error = true;
        diags.addFmtInFile(.err, e.module_path, e.span, "#context_extend '{s}' has no default value — the default context must be constructible before `main` runs", .{e.name});
    }

    // L4: one flat namespace. First (in L6 order) declaration of a name wins
    // the role of "declared here" note; every later same-name declaration is
    // the error site.
    var first_by_name = std.StringHashMap(usize).init(self.alloc);
    defer first_by_name.deinit();
    for (ext, 0..) |*e, i| {
        const gop = first_by_name.getOrPut(e.name) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = i;
            continue;
        }
        const first = ext[gop.value_ptr.*];
        e.valid = false;
        ext[gop.value_ptr.*].valid = false;
        self.context_structural_error = true;
        const id = diags.addFmtId(.err, e.span, "duplicate context field '{s}': the Context namespace is program-global and flat — every field name must be declared exactly once", .{e.name});
        // addFmtId reads the ambient current_source_file; pin the primary to
        // the colliding decl's file and the note to the first decl's file.
        pinDiagnosticFile(diags, id, e.module_path);
        const saved = diags.current_source_file;
        diags.current_source_file = first.module_path;
        diags.addNoteFmt(id, first.span, "'{s}' first declared here, by {s}", .{ first.name, first.module_path });
        diags.current_source_file = saved;
    }

    // L4, builtin half: collision with a field the declared `Context` struct
    // already carries (allocator/io; gone post-L8-retrofit).
    if (findContextStructDecl(decls)) |ctx| {
        for (ext) |*e| {
            for (ctx.decl.field_names) |fname| {
                if (!std.mem.eql(u8, e.name, fname)) continue;
                e.valid = false;
                self.context_structural_error = true;
                const id = diags.addFmtId(.err, e.span, "duplicate context field '{s}': the builtin Context struct already declares it", .{e.name});
                pinDiagnosticFile(diags, id, e.module_path);
                const saved = diags.current_source_file;
                diags.current_source_file = ctx.node.source_file orelse self.main_file orelse "";
                diags.addNoteFmt(id, ctx.node.span, "the Context struct declaring '{s}' is here", .{fname});
                diags.current_source_file = saved;
            }
        }
    }
}

/// Assemble the program Context: append every valid collected field to the
/// registered `Context` struct type (declared EMPTY in core.sx — 100% of the
/// fields come from `#context_extend` declarations, in L6 order). The
/// authoritative call is pass 1a' in `lowerRoot` (after `scanDecls` — every
/// named type registered, diagnostics live). Each field's type resolves in
/// its DECLARING module's visibility context, exactly like a namespaced
/// callee's return type (`resolveTypeInSource`).
pub fn assembleContext(self: *Lowering) void {
    assembleContextImpl(self, .final);
}

/// Best-effort EARLY assembly, for comptime evaluation that runs DURING
/// `scanDecls` (a type-fn const) — its body may read `context.allocator`,
/// which must resolve against the ASSEMBLED layout. Early mode is strictly
/// quieter than the pass-1a' call: if anything is not yet registered
/// (Context itself, or any extension's type), it changes NOTHING and emits
/// NOTHING — the final call assembles and diagnoses.
pub fn assembleContextEarly(self: *Lowering) void {
    assembleContextImpl(self, .early);
}

fn assembleContextImpl(self: *Lowering, mode: enum { early, final }) void {
    if (!self.implicit_ctx_enabled) return;
    const ext = self.program_index.context_extensions;
    if (ext.len == 0) return;
    const tbl = &self.module.types;
    const ctx_ty = tbl.findByName(tbl.internString("Context")) orelse return;
    const info = tbl.get(ctx_ty);
    if (info != .@"struct") return;

    // RECONCILING, not once-only: the Context struct decl can be
    // RE-REGISTERED after an early assembly (per-source re-registration in
    // the scan loop re-derives the TypeInfo from the — empty — declaration,
    // wiping appended fields). Every call re-appends whatever valid
    // extensions the CURRENT TypeInfo is missing; with none missing it is a
    // cheap no-op. Convergent: same fields, same L6 order, every time.
    var fields = std.ArrayList(types_mod.TypeInfo.StructInfo.Field).empty;
    fields.appendSlice(self.alloc, info.@"struct".fields) catch return;
    var appended = false;
    for (ext) |e| {
        if (!e.valid) continue;
        const name_id = tbl.internString(e.name);
        var present = false;
        for (info.@"struct".fields) |f| {
            if (f.name == name_id) {
                present = true;
                break;
            }
        }
        if (present) continue;
        // Side-effect-free readiness check BEFORE resolveType — an unknown
        // name in type position registers a silent empty-struct stub, which
        // would bind the field to a zero-size lie. Early mode defers the
        // whole assembly (a later registration may still supply the type);
        // final mode diagnoses and skips the field.
        if (!typeExprReady(self, e.type_expr, mode == .early)) {
            if (mode == .early) return;
            self.context_structural_error = true;
            if (self.diagnostics) |d|
                d.addFmtInFile(.err, e.module_path, e.type_expr.span, "cannot resolve the type of context field '{s}'", .{e.name});
            continue;
        }
        const fty = self.resolveTypeInSource(e.module_path, e.type_expr);
        if (fty == .unresolved) {
            if (mode == .early) return;
            self.context_structural_error = true;
            if (self.diagnostics) |d|
                d.addFmtInFile(.err, e.module_path, e.type_expr.span, "cannot resolve the type of context field '{s}'", .{e.name});
            continue;
        }
        fields.append(self.alloc, .{
            .name = tbl.internString(e.name),
            .ty = fty,
        }) catch return;
        appended = true;
    }

    if (appended) {
        var assembled = info;
        assembled.@"struct".fields = fields.toOwnedSlice(self.alloc) catch return;
        // A field append changes neither the display name nor the nominal id —
        // the struct's intern key — so this is the sanctioned in-place update.
        tbl.updatePreservingKey(ctx_ty, assembled);
    }
    self.context_assembled = true;
}

/// Is `node` a type expression whose NAME LEAVES are all registered — checked
/// WITHOUT resolving (resolveType registers stubs for unknown names)?
/// `strict` (early mode): an unrecognized node shape counts as NOT ready, so
/// early assembly defers rather than guessing. Non-strict (final mode): only
/// the common name-leaf shapes are validated; exotic shapes pass through to
/// resolveType, which is authoritative by then.
fn typeExprReady(self: *Lowering, node: *const Node, strict: bool) bool {
    return switch (node.data) {
        .type_expr => |te| typeNameKnown(self, te.name),
        .identifier => |id| typeNameKnown(self, id.name),
        .optional_type_expr => |o| typeExprReady(self, o.inner_type, strict),
        .pointer_type_expr => |p| typeExprReady(self, p.pointee_type, strict),
        .many_pointer_type_expr => |mp| typeExprReady(self, mp.element_type, strict),
        .slice_type_expr => |s| typeExprReady(self, s.element_type, strict),
        .array_type_expr => |a| typeExprReady(self, a.element_type, strict),
        .parameterized_type_expr => |p| blk: {
            if (!typeNameKnown(self, p.name)) break :blk false;
            for (p.args) |arg| {
                if (!typeExprReady(self, arg, strict)) break :blk false;
            }
            break :blk true;
        },
        else => !strict,
    };
}

/// Is `name` a registered type name — primitive, nominal, alias, or generic
/// template? Read-only (never registers anything).
fn typeNameKnown(self: *Lowering, name: []const u8) bool {
    const TypeResolver = @import("../type_resolver.zig").TypeResolver;
    if (TypeResolver.resolvePrimitive(name) != null) return true;
    const tbl = &self.module.types;
    if (tbl.findByName(tbl.internString(name)) != null) return true;
    if (self.program_index.type_alias_map.contains(name)) return true;
    if (self.program_index.struct_template_map.contains(name)) return true;
    return false;
}

pub const ContextFieldRef = struct { index: u32, ty: types_mod.TypeId };

/// Attach the registered `#context_extend` field list (name, declared type
/// spelling, declaring module) as a note under the primary diagnostic `id`.
/// The O3 enumeration — shared by the no-context error ("what would the
/// context have been?") and the Context unknown-field error ("what fields
/// are there?"). No-op when nothing is registered. Invalid entries are
/// listed too: a field that failed validation is still part of the program's
/// declared surface, and its own error explains why it is unusable.
pub fn noteRegisteredContextFields(self: *Lowering, id: usize) void {
    const diags = self.diagnostics orelse return;
    const ext = self.program_index.context_extensions;
    if (ext.len == 0) return;
    var buf = std.ArrayList(u8).empty;
    buf.appendSlice(self.alloc, "registered context fields:") catch return;
    for (ext) |e| {
        buf.print(self.alloc, "\n    {s}: {s}   — {s}", .{
            e.name, typeSpelling(self, e), e.module_path,
        }) catch return;
    }
    const msg = buf.toOwnedSlice(self.alloc) catch return;
    diags.addNote(id, null, msg);
}

/// The declared type's SOURCE spelling — slice the declaring file's text at
/// the type expression's span (exact to what the author wrote; no type
/// printer needed). "?" when the source is unavailable (unit-test paths
/// without import_sources).
fn typeSpelling(self: *Lowering, e: ContextFieldDecl) []const u8 {
    const diags = self.diagnostics orelse return "?";
    var src: ?[]const u8 = null;
    if (diags.import_sources) |is| {
        if (is.get(e.module_path)) |s| src = s;
    }
    if (src == null and std.mem.eql(u8, e.module_path, diags.file_name)) src = diags.source;
    const s = src orelse return "?";
    const sp = e.type_expr.span;
    if (sp.start <= sp.end and sp.end <= s.len) return s[sp.start..sp.end];
    return "?";
}

/// Resolve a Context field BY NAME against the assembled layout (L8 rider b:
/// no compiler-internal access may assume a field index). Null = Context is
/// not a registered struct or carries no such field — callers diagnose; a
/// positional fallback here would be the classic silent-clobber.
pub fn contextFieldByName(self: *Lowering, fname: []const u8) ?ContextFieldRef {
    const tbl = &self.module.types;
    const ctx_ty = tbl.findByName(tbl.internString("Context")) orelse return null;
    const info = tbl.get(ctx_ty);
    if (info != .@"struct") return null;
    for (info.@"struct".fields, 0..) |f, i| {
        if (std.mem.eql(u8, tbl.getString(f.name), fname))
            return .{ .index = @intCast(i), .ty = f.ty };
    }
    return null;
}

/// Serialize the `#context_extend` declaration named `fname`'s default into a
/// static ConstantValue against the assembled field type — the extension
/// half of the `__sx_default_context` initializer. Reuses the global-
/// initializer serializer (L5: defaults are exactly the compile-time-constant
/// class), evaluated in the DECLARING module's visibility context so a
/// default naming the author's own consts resolves there. Null = the default
/// failed to serialize (the serializer already emitted the diagnostic) or
/// the entry is invalid (its L4/L5 error is already out).
pub fn contextExtensionDefault(self: *Lowering, fname: []const u8, fty: types_mod.TypeId) ?inst_mod.ConstantValue {
    for (self.program_index.context_extensions) |e| {
        if (!std.mem.eql(u8, e.name, fname)) continue;
        if (!e.valid) return null;
        const de = e.default_expr orelse return null;
        const saved = self.current_source_file;
        defer self.setCurrentSourceFile(saved);
        self.setCurrentSourceFile(e.module_path);
        const vd = ast.VarDecl{
            .name = e.name,
            .name_span = e.name_span,
            .type_annotation = @constCast(e.type_expr),
            .value = @constCast(de),
        };
        return self.globalInitValue(&vd, fty);
    }
    // No declaration for this field — a hand-declared Context struct field
    // (outside std). Not an error here: `emitDefaultContextGlobal` checks
    // `hasContextExtension` first and skips emission for such programs.
    return null;
}

/// Is `fname` a collected `#context_extend` declaration (valid or not)?
pub fn hasContextExtension(self: *Lowering, fname: []const u8) bool {
    for (self.program_index.context_extensions) |e| {
        if (std.mem.eql(u8, e.name, fname)) return true;
    }
    return false;
}


fn gatherEntries(
    self: *Lowering,
    decls: []const *const Node,
    entries: *std.ArrayList(ContextFieldDecl),
    seen_nodes: *std.AutoHashMap(*const Node, void),
) void {
    for (decls) |decl| {
        switch (decl.data) {
            .context_extend_decl => |ce| {
                const gop = seen_nodes.getOrPut(decl) catch continue;
                if (gop.found_existing) continue;
                entries.append(self.alloc, .{
                    .name = ce.name,
                    .name_span = ce.name_span,
                    .type_expr = ce.type_expr,
                    .default_expr = ce.default_expr,
                    .span = decl.span,
                    .module_path = decl.source_file orelse self.main_file orelse "",
                }) catch {};
            },
            // A namespaced import wraps its module's decls inline — descend so
            // `ns :: #import "m"` still contributes m's context fields (L3:
            // imports gate existence, never visibility).
            .namespace_decl => |ns| gatherEntries(self, ns.decls, entries, seen_nodes),
            else => {},
        }
    }
}

fn entryLessThan(_: void, a: ContextFieldDecl, b: ContextFieldDecl) bool {
    return switch (std.mem.order(u8, a.module_path, b.module_path)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.name, b.name) == .lt,
    };
}

/// Rewrite an already-appended diagnostic's source file. `addFmtId` stamps the
/// ambient `current_source_file`; collision primaries need the entry's OWN
/// file regardless of what is ambient during the pass.
fn pinDiagnosticFile(diags: *errors.DiagnosticList, id: usize, file: []const u8) void {
    if (id < diags.items.items.len) diags.items.items[id].source_file = file;
}

const ContextStructRef = struct { node: *const Node, decl: ast.StructDecl };

/// Find the `Context :: struct {...}` declaration (same shapes as
/// `detectContextDecl`) so builtin-field collisions can name its site.
fn findContextStructDecl(decls: []const *const Node) ?ContextStructRef {
    for (decls) |decl| {
        switch (decl.data) {
            .struct_decl => |sd| if (std.mem.eql(u8, sd.name, "Context")) return .{ .node = decl, .decl = sd },
            .const_decl => |cd| if (std.mem.eql(u8, cd.name, "Context") and cd.value.data == .struct_decl)
                return .{ .node = decl, .decl = cd.value.data.struct_decl },
            .namespace_decl => |ns| if (findContextStructDecl(ns.decls)) |found| return found,
            else => {},
        }
    }
    return null;
}
