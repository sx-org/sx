//! Editor-facing symbol/type INDEX for the language server — not a compiler
//! semantic pass.
//!
//! Powers editor navigation and completion (go-to-definition, find-references,
//! hover, member/field lookup) by building a best-effort, resilient view of a
//! file's symbols and approximate types. The `Type` values here come from
//! `src/types.zig`, which is editor metadata only.
//!
//! This is NOT the compiler's source of truth. Compiler type resolution,
//! lowering, and codegen consume the canonical `TypeId` / `TypeTable` model in
//! `src/ir/`, never this module. sx does not require as-you-type type checking;
//! authoritative diagnostics are produced on save by running the canonical
//! compiler pipeline (`src/lsp/server.zig`), not by this analyzer. The public
//! names below (`Analyzer`, `analyze`, `inferExprType`, `resolveTypeNode`,
//! `SemaResult`) name an editor index, not compiler authority.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Span = ast.Span;
const Type = @import("types.zig").Type;
const errors = @import("errors.zig");
const Diagnostic = errors.Diagnostic;

fn baseName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| name[idx + 1 ..] else name;
}

pub const SymbolKind = enum {
    variable,
    constant,
    function,
    enum_type,
    struct_type,
    protocol_type,
    type_alias,
    param,
    namespace,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    ty: ?Type,
    def_span: Span,
    scope_depth: u32,
    /// null = defined in the current file. Non-null = absolute path of the origin file.
    origin: ?[]const u8 = null,
    /// Module-scope declaration visibility. A `.private` top-level symbol is
    /// not offered to other files (completion / pre-registration).
    visibility: ast.Visibility = .public,
};

pub const Reference = struct {
    span: Span,
    symbol_index: u32,
};

/// A reference to a struct field / method / enum variant. These aren't symbols,
/// so they're tracked separately and matched by (owner type, name).
pub const MemberRef = struct {
    span: Span, // the member-name token
    name: []const u8,
    owner: []const u8 = "", // owning type name, "" if unknown (bare enum literal)
    is_def: bool = false, // declaration site rather than a use
};

pub const FnSignature = struct {
    param_types: []const Type,
    return_type: Type,
    is_variadic: bool = false,
};

pub const StructTypeInfo = struct {
    field_names: []const []const u8,
    field_types: []const Type,
    type_params: []const []const u8 = &.{},
};

pub const TypeMap = std.AutoHashMap(*const Node, Type);

/// Editor index for one file: symbols, references, member refs, approximate
/// types, and best-effort diagnostics for navigation/completion. Not consumed
/// by the compiler pipeline (see module doc).
pub const SemaResult = struct {
    symbols: []const Symbol,
    references: []const Reference,
    member_refs: []const MemberRef,
    diagnostics: []const Diagnostic,
    fn_signatures: std.StringHashMap(FnSignature),
    struct_types: std.StringHashMap(StructTypeInfo),
    enum_types: std.StringHashMap([]const []const u8),
    type_aliases: std.StringHashMap([]const u8),
    type_map: TypeMap,
};

/// Builds the editor symbol/type index (see module doc). Not a compiler
/// semantic pass — its `Type` results are editor metadata, not compiler truth.
pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(Symbol),
    references: std.ArrayList(Reference),
    member_refs: std.ArrayList(MemberRef),
    /// Source text — lets `spanOf` map an AST string slice back to a Span.
    source: []const u8 = "",
    /// True while analysing a `callconv(.c)` function body — the C ABI carries
    /// no implicit `context` parameter, so `context` is unavailable there.
    in_c_conv: bool = false,
    diagnostics: std.ArrayList(Diagnostic),
    scope_depth: u32,
    /// Stack of symbol counts at each scope entry, for popScope cleanup.
    scope_starts: std.ArrayList(u32),
    /// Hash index: name → list of indices into symbols array for O(1) lookup
    symbol_index: std.StringHashMap(std.ArrayList(u32)),
    // Type registries
    fn_signatures: std.StringHashMap(FnSignature),
    struct_types: std.StringHashMap(StructTypeInfo),
    enum_types: std.StringHashMap([]const []const u8),
    type_aliases: std.StringHashMap([]const u8),
    /// Module-global integer consts, by bare name → value. Lets an array
    /// dimension written as a named const (`MAX :: 4; [MAX]u8`) fold to a
    /// concrete editor length instead of panicking on the `.int_literal`
    /// union access. Populated at registration time, so it shares
    /// the analyzer's existing intra-pass forward-reference limitation (a const
    /// declared after the struct that uses it resolves to "unknown" length).
    const_int_values: std.StringHashMap(i64),
    type_map: TypeMap,
    /// Visibility of the top-level declaration currently being registered —
    /// stamped onto its `Symbol` by `addSymbol`. `.public` between decls.
    pending_visibility: ast.Visibility = .public,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{
            .allocator = allocator,
            .symbols = std.ArrayList(Symbol).empty,
            .references = std.ArrayList(Reference).empty,
            .member_refs = std.ArrayList(MemberRef).empty,
            .diagnostics = std.ArrayList(Diagnostic).empty,
            .scope_depth = 0,
            .scope_starts = std.ArrayList(u32).empty,
            .symbol_index = std.StringHashMap(std.ArrayList(u32)).init(allocator),
            .fn_signatures = std.StringHashMap(FnSignature).init(allocator),
            .struct_types = std.StringHashMap(StructTypeInfo).init(allocator),
            .enum_types = std.StringHashMap([]const []const u8).init(allocator),
            .type_aliases = std.StringHashMap([]const u8).init(allocator),
            .const_int_values = std.StringHashMap(i64).init(allocator),
            .type_map = TypeMap.init(allocator),
        };
    }

    pub fn analyze(self: *Analyzer, root: *Node) !SemaResult {
        if (root.data != .root) return error.InvalidRoot;

        // Pass 1: Register all top-level declarations so forward references work.
        for (root.data.root.decls) |decl| {
            try self.registerTopLevelDecl(decl);
        }

        // Implicit `context` global (the context system — `context.allocator`,
        // `context.data`). Registered with its `Context` type when that's in
        // scope so the field chain resolves.
        if (self.struct_types.contains("Context")) {
            try self.addSymbol("context", .variable, .{ .struct_type = "Context" }, .{ .start = 0, .end = 0 });
        }

        // Pass 2: Analyze bodies (all top-level names are now in scope).
        for (root.data.root.decls) |decl| {
            try self.analyzeTopLevelDecl(decl);
        }

        return .{
            .symbols = try self.symbols.toOwnedSlice(self.allocator),
            .references = try self.references.toOwnedSlice(self.allocator),
            .member_refs = try self.member_refs.toOwnedSlice(self.allocator),
            .diagnostics = try self.diagnostics.toOwnedSlice(self.allocator),
            .fn_signatures = self.fn_signatures,
            .struct_types = self.struct_types,
            .enum_types = self.enum_types,
            .type_aliases = self.type_aliases,
            .type_map = self.type_map,
        };
    }

    /// Pass 1: register the name/kind/type of a top-level declaration without
    /// analysing its body or value expression.
    fn registerTopLevelDecl(self: *Analyzer, node: *Node) !void {
        try self.registerTopLevelDeclPrefixed(node, null);
    }

    fn registerTopLevelDeclPrefixed(self: *Analyzer, node: *Node, ns_prefix: ?[]const u8) !void {
        self.pending_visibility = node.visibility;
        defer self.pending_visibility = .public;
        switch (node.data) {
            .fn_decl => |fd| {
                const ret_ty = self.resolveReturnType(fd) orelse
                    if (fd.is_arrow) self.inferFnReturnType(fd.params, fd.body) else null;
                try self.addSymbol(fd.name, .function, ret_ty, node.span);
                // Populate fn_signatures registry
                var param_types = std.ArrayList(Type).empty;
                var has_variadic = false;
                for (fd.params) |param| {
                    const pt = self.fieldType(param.type_expr);
                    if (param.is_variadic) {
                        has_variadic = true;
                        // Variadic param becomes a slice type
                        const elem_name = switch (param.type_expr.data) {
                            .type_expr => |te| te.name,
                            // `..xs: []T` — the element is T, not a guessed i32.
                            .slice_type_expr => |st| if (st.element_type.data == .type_expr) st.element_type.data.type_expr.name else "<unresolved>",
                            else => "<unresolved>",
                        };
                        const elem_raw = switch (param.type_expr.data) {
                            .type_expr => |te| te.is_raw,
                            .slice_type_expr => |st| typeExprIsRaw(st.element_type),
                            else => false,
                        };
                        try param_types.append(self.allocator, .{ .slice_type = .{ .element_name = elem_name, .is_raw = elem_raw } });
                    } else {
                        try param_types.append(self.allocator, pt);
                    }
                }
                const key = if (ns_prefix) |pfx|
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pfx, fd.name })
                else
                    fd.name;
                try self.fn_signatures.put(key, .{
                    .param_types = try param_types.toOwnedSlice(self.allocator),
                    .return_type = ret_ty orelse .void_type,
                    .is_variadic = has_variadic,
                });
            },
            .const_decl => |cd| {
                const ty = self.resolveTypeAnnotation(cd.type_annotation) orelse inferValueType(cd.value);
                const kind = classifyConstDecl(cd);
                try self.addSymbol(cd.name, kind, ty, node.span);
                // Record integer-literal consts so a named array dimension
                // (`MAX :: 4; [MAX]u8`) can fold to a concrete length.
                if (cd.value.data == .int_literal) {
                    try self.const_int_values.put(cd.name, cd.value.data.int_literal.value);
                }
                // Populate type_aliases registry
                if (cd.value.data == .type_expr) {
                    try self.type_aliases.put(cd.name, cd.value.data.type_expr.name);
                }
                // Lambda as function
                if (cd.value.data == .lambda) {
                    const lam = cd.value.data.lambda;
                    var param_types = std.ArrayList(Type).empty;
                    for (lam.params) |param| {
                        const pt = self.fieldType(param.type_expr);
                        try param_types.append(self.allocator, pt);
                    }
                    const ret = if (lam.return_type) |rt|
                        Type.fromTypeExpr(rt) orelse .void_type
                    else
                        self.inferFnReturnType(lam.params, lam.body) orelse .void_type;
                    const key = if (ns_prefix) |pfx|
                        try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pfx, cd.name })
                    else
                        cd.name;
                    try self.fn_signatures.put(key, .{
                        .param_types = try param_types.toOwnedSlice(self.allocator),
                        .return_type = ret,
                    });
                }
            },
            .var_decl => |vd| {
                const ty = self.resolveTypeAnnotation(vd.type_annotation);
                try self.addSymbol(vd.name, .variable, ty, node.span);
            },
            .enum_decl => |ed| {
                if (ed.variant_types.len > 0) {
                    // Tagged enum with payloads. Also recorded in `enum_types` so
                    // the name resolves as a type (e.g. a `[*]Event` element).
                    try self.addSymbol(ed.name, .enum_type, .{ .union_type = ed.name }, node.span);
                    try self.enum_types.put(ed.name, ed.variant_names);
                } else {
                    // Payload-less enum
                    try self.addSymbol(ed.name, .enum_type, .{ .enum_type = ed.name }, node.span);
                    try self.enum_types.put(ed.name, ed.variant_names);
                }
                for (ed.variant_names) |vn| self.recordMemberRef(vn, ed.name, true);
            },
            .struct_decl => |sd| {
                try self.addSymbol(sd.name, .struct_type, .{ .struct_type = sd.name }, node.span);
                var tp_names = std.ArrayList([]const u8).empty;
                for (sd.type_params) |p| {
                    try tp_names.append(self.allocator, p.name);
                }
                const tp_slice = try tp_names.toOwnedSlice(self.allocator);
                // Populate struct_types registry, expanding #using entries
                if (sd.using_entries.len > 0) {
                    var all_names = std.ArrayList([]const u8).empty;
                    var all_types = std.ArrayList(Type).empty;
                    var using_idx: usize = 0;
                    for (0..sd.field_names.len + 1) |i| {
                        while (using_idx < sd.using_entries.len and
                            sd.using_entries[using_idx].insert_index == i)
                        {
                            const entry = sd.using_entries[using_idx];
                            if (self.struct_types.get(entry.type_name)) |used| {
                                for (used.field_names, 0..) |fname, fi| {
                                    try all_names.append(self.allocator, fname);
                                    try all_types.append(self.allocator, used.field_types[fi]);
                                }
                            }
                            using_idx += 1;
                        }
                        if (i < sd.field_names.len) {
                            try all_names.append(self.allocator, sd.field_names[i]);
                            const resolved = self.fieldType(sd.field_types[i]);
                            try all_types.append(self.allocator, resolved);
                        }
                    }
                    try self.struct_types.put(sd.name, .{
                        .field_names = try all_names.toOwnedSlice(self.allocator),
                        .field_types = try all_types.toOwnedSlice(self.allocator),
                        .type_params = tp_slice,
                    });
                } else {
                    var field_types = std.ArrayList(Type).empty;
                    for (sd.field_types) |ft| {
                        const resolved = self.fieldType(ft);
                        try field_types.append(self.allocator, resolved);
                    }
                    try self.struct_types.put(sd.name, .{
                        .field_names = sd.field_names,
                        .field_types = try field_types.toOwnedSlice(self.allocator),
                        .type_params = tp_slice,
                    });
                }
                for (sd.field_names) |fname| self.recordMemberRef(fname, sd.name, true);
                for (sd.methods) |mnode| {
                    if (mnode.data == .fn_decl) {
                        try self.registerMethodSig(mnode.data.fn_decl.name, sd.name, mnode.data.fn_decl.return_type);
                        try self.registerMethodSig(mnode.data.fn_decl.name, ns_prefix, mnode.data.fn_decl.return_type);
                        self.recordMemberRef(mnode.data.fn_decl.name, sd.name, true);
                    }
                }
            },
            .protocol_decl => |pd| {
                for (pd.methods) |m| {
                    try self.registerMethodSig(m.name, pd.name, m.return_type);
                    try self.registerMethodSig(m.name, ns_prefix, m.return_type);
                }
            },
            .union_decl => |ud| {
                try self.addSymbol(ud.name, .enum_type, .{ .union_type = ud.name }, node.span);
            },
            .namespace_decl => |ns| {
                try self.addSymbol(ns.name, .namespace, null, node.span);
                // Recurse into namespace decls with qualified prefix (in own scope
                // so inner names don't collide with flat imports of the same names)
                try self.pushScope();
                for (ns.decls) |d| {
                    try self.registerTopLevelDeclPrefixed(d, ns.name);
                }
                self.popScope();
            },
            .ufcs_alias => |ua| {
                try self.addSymbol(ua.name, .function, null, node.span);
            },
            else => {},
        }
    }

    /// Register a method's return type in `fn_signatures`. Called twice per
    /// method: once under the owning type's qualified "{Type}.{name}" key
    /// (the receiver-aware lookup — same-named methods on different types
    /// don't collide) and once under the bare name (first-wins fallback for
    /// calls whose receiver type can't be inferred). Params are omitted —
    /// only the return type is consulted for type inference.
    fn registerMethodSig(self: *Analyzer, name: []const u8, ns_prefix: ?[]const u8, ret_node: ?*Node) !void {
        const key = if (ns_prefix) |pfx|
            try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pfx, name })
        else
            name;
        if (self.fn_signatures.contains(key)) return;
        const ret = if (ret_node) |rt| self.fieldType(rt) else Type.void_type;
        try self.fn_signatures.put(key, .{ .param_types = &.{}, .return_type = ret });
    }

    /// Fold an array dimension node to a concrete editor length, or null
    /// ("unknown") when it isn't a compile-time integer this index can resolve.
    /// Metadata-only — NEVER panic on an unexpected node shape and never
    /// fabricate a misleading concrete length. A literal dim is
    /// taken directly; a bare identifier naming an integer const folds to its
    /// recorded value; anything else (unknown name, non-const expression,
    /// out-of-`u32`-range value) is unknown.
    fn arrayDimLength(self: *Analyzer, len_node: *Node) ?u32 {
        const v: i64 = switch (len_node.data) {
            .int_literal => |lit| lit.value,
            .char_literal => |lit| lit.value,
            .identifier => |id| self.const_int_values.get(id.name) orelse return null,
            else => return null,
        };
        if (v < 0 or v > std.math.maxInt(u32)) return null;
        return @intCast(v);
    }

    /// Resolve a type annotation node to an editor `Type` (metadata only — the
    /// compiler resolves type nodes to canonical `TypeId` in `src/ir/`).
    /// Handles primitives, type_expr, array_type_expr, parameterized_type_expr,
    /// type aliases, enum types, and struct types.
    pub fn resolveTypeNode(self: *Analyzer, type_node: ?*Node) Type {
        if (type_node) |tn| {
            if (Type.fromTypeExpr(tn)) |t| return t;
            // Array type: [N]T
            if (tn.data == .array_type_expr) {
                const ate = tn.data.array_type_expr;
                const length = self.arrayDimLength(ate.length);
                const elem_type = self.resolveTypeNode(ate.element_type);
                const elem_name = elem_type.displayName(self.allocator) catch return .void_type;
                return .{ .array_type = .{ .element_name = elem_name, .length = length, .is_raw = typeExprIsRaw(ate.element_type) } };
            }
            // Slice type: []T
            if (tn.data == .slice_type_expr) {
                const ste = tn.data.slice_type_expr;
                const elem_type = self.resolveTypeNode(ste.element_type);
                const elem_name = elem_type.displayName(self.allocator) catch return .void_type;
                return .{ .slice_type = .{ .element_name = elem_name, .is_raw = typeExprIsRaw(ste.element_type) } };
            }
            // Optional type: ?T
            if (tn.data == .optional_type_expr) {
                const ote = tn.data.optional_type_expr;
                const inner_type = self.resolveTypeNode(ote.inner_type);
                const inner_name = inner_type.displayName(self.allocator) catch return .void_type;
                return .{ .optional_type = .{ .child_name = inner_name, .is_raw = typeExprIsRaw(ote.inner_type) } };
            }
            // Pointer type: *T
            if (tn.data == .pointer_type_expr) {
                const pte = tn.data.pointer_type_expr;
                const pointee_type = self.resolveTypeNode(pte.pointee_type);
                const pointee_name = pointee_type.displayName(self.allocator) catch return .void_type;
                return .{ .pointer_type = .{ .pointee_name = pointee_name, .is_raw = typeExprIsRaw(pte.pointee_type) } };
            }
            // Many-pointer type: [*]T
            if (tn.data == .many_pointer_type_expr) {
                const mpte = tn.data.many_pointer_type_expr;
                const elem_type = self.resolveTypeNode(mpte.element_type);
                const elem_name = elem_type.displayName(self.allocator) catch return .void_type;
                return .{ .many_pointer_type = .{ .element_name = elem_name, .is_raw = typeExprIsRaw(mpte.element_type) } };
            }
            // Function pointer type: (ParamTypes) -> ReturnType
            if (tn.data == .function_type_expr) {
                const fte = tn.data.function_type_expr;
                var param_types = std.ArrayList(Type).empty;
                for (fte.param_types) |pt| {
                    param_types.append(self.allocator, self.resolveTypeNode(pt)) catch return .void_type;
                }
                const ret_ty = if (fte.return_type) |rt| self.resolveTypeNode(rt) else Type.void_type;
                const ret_ptr = self.allocator.create(Type) catch return .void_type;
                ret_ptr.* = ret_ty;
                return .{ .function_type = .{
                    .param_types = param_types.toOwnedSlice(self.allocator) catch return .void_type,
                    .return_type = ret_ptr,
                } };
            }
            // Sema does not resolve generics; codegen handles instantiation
            if (tn.data == .parameterized_type_expr) {
                return .void_type;
            }
            // type_expr or identifier — check aliases, enums, structs. A raw
            // reference (`` `i2 ``) skips the builtin classifier and resolves
            // through user-defined types only.
            if (tn.data == .type_expr or tn.data == .identifier) {
                const name = if (tn.data == .type_expr) tn.data.type_expr.name else tn.data.identifier.name;
                const is_raw = if (tn.data == .type_expr) tn.data.type_expr.is_raw else tn.data.identifier.is_raw;
                if (!is_raw) {
                    if (Type.fromName(name)) |t| return t;
                }
                if (self.type_aliases.get(name)) |target| {
                    if (Type.fromName(target)) |t| return t;
                    if (self.struct_types.contains(target)) return .{ .struct_type = target };
                }
                if (self.enum_types.contains(name)) return .{ .enum_type = name };
                if (self.struct_types.contains(name)) return .{ .struct_type = name };
            }
            return .void_type;
        }
        return .void_type;
    }

    /// Resolve a bare type-name string against the registry (aliases, enums,
    /// structs), falling back to primitive spellings. Unlike `Type.fromName`,
    /// this knows user-defined types; returns `unresolved` when it can't place
    /// the name. `skip_builtin` is the backtick raw escape — a raw
    /// reference (`` `i2 ``) bypasses the builtin/reserved classifier and
    /// resolves only through user-defined types, mirroring the codegen-side
    /// `TypeResolver.resolveNamed`. Inner names of compound shapes
    /// (pointer/slice element/pointee) are always bare, so their callers pass
    /// `false`.
    fn resolveTypeNameStr(self: *Analyzer, name: []const u8, skip_builtin: bool) Type {
        if (!skip_builtin) {
            if (Type.fromName(name)) |t| return t;
        }
        if (self.type_aliases.get(name)) |target| {
            if (Type.fromName(target)) |t| return t;
            if (self.struct_types.contains(target)) return .{ .struct_type = target };
            if (self.enum_types.contains(target)) return .{ .enum_type = target };
        }
        if (self.enum_types.contains(name)) return .{ .enum_type = name };
        if (self.struct_types.contains(name)) return .{ .struct_type = name };
        return Type.unresolved;
    }

    /// Extract the element/pointee name from a type-expr node, keeping generic
    /// param names (`T`) intact for later substitution. Compound shapes fall
    /// back to their spelled form.
    fn typeExprName(self: *Analyzer, node: *Node) []const u8 {
        return switch (node.data) {
            .type_expr => |te| te.name,
            .identifier => |id| id.name,
            else => (self.resolveTypeNode(node)).displayName(self.allocator) catch "",
        };
    }

    /// The backtick raw bit of an inner type-name node (`` `i2 ``). A compound
    /// shape (`*T`, `?T`, `[]T`, …) stores its inner name as a bare string, so
    /// this bit must travel ALONGSIDE that name — otherwise the
    /// resolver re-reads `i2` as the builtin int. Non-leaf nodes are never raw.
    fn typeExprIsRaw(node: *Node) bool {
        return switch (node.data) {
            .type_expr => |te| te.is_raw,
            .identifier => |id| id.is_raw,
            else => false,
        };
    }

    /// When a compound shape stores the NAME of an ALREADY-resolved inner type
    /// (no syntactic node to read `is_raw` from — e.g. a for-loop element), a
    /// user nominal type must be re-resolved with `skip_builtin` so a struct/
    /// enum/union named `i2` is not reclassified as the builtin. Builtins keep
    /// `false`. Harmless for non-colliding names (the registry lookup is the
    /// same either way).
    fn innerNameIsRaw(inner: Type) bool {
        return switch (inner) {
            .struct_type, .enum_type, .union_type => true,
            else => false,
        };
    }

    /// Resolve a struct field's declared type, preserving the raw element/
    /// pointee name of pointer/slice shapes so generic params (`T`) survive
    /// into `instantiateGeneric`'s substitution. Bare names resolve through the
    /// registry; the element name is resolved lazily at index/field time.
    fn fieldType(self: *Analyzer, node: *Node) Type {
        return switch (node.data) {
            .type_expr => |te| self.resolveTypeNameStr(te.name, te.is_raw),
            .identifier => |id| self.resolveTypeNameStr(id.name, id.is_raw),
            .many_pointer_type_expr => |mp| .{ .many_pointer_type = .{ .element_name = self.typeExprName(mp.element_type), .is_raw = typeExprIsRaw(mp.element_type) } },
            .pointer_type_expr => |p| .{ .pointer_type = .{ .pointee_name = self.typeExprName(p.pointee_type), .is_raw = typeExprIsRaw(p.pointee_type) } },
            .slice_type_expr => |s| .{ .slice_type = .{ .element_name = self.typeExprName(s.element_type), .is_raw = typeExprIsRaw(s.element_type) } },
            .parameterized_type_expr => |pte| self.instantiateGeneric(pte.name, pte.args) orelse self.resolveTypeNode(node),
            else => self.resolveTypeNode(node),
        };
    }

    /// The element type yielded by iterating `ty` in a `for` loop: arrays,
    /// slices and many-pointers give their element; a List-like struct (one
    /// with an `items: [*]T` field) gives `T`; a pointer is followed to its
    /// pointee first (so `*List(Move)` still iterates `Move`).
    fn elementTypeOf(self: *Analyzer, ty: Type) ?Type {
        return switch (ty) {
            .array_type => |i| self.resolveTypeNameStr(i.element_name, i.is_raw),
            .slice_type => |i| self.resolveTypeNameStr(i.element_name, i.is_raw),
            .many_pointer_type => |i| self.resolveTypeNameStr(i.element_name, i.is_raw),
            .pointer_type => |i| self.elementTypeOf(self.resolveTypeNameStr(i.pointee_name, i.is_raw)),
            .struct_type => |name| blk: {
                const info = self.struct_types.get(name) orelse break :blk null;
                for (info.field_names, info.field_types) |fname, fty| {
                    if (std.mem.eql(u8, fname, "items") and fty == .many_pointer_type) {
                        break :blk self.resolveTypeNameStr(fty.many_pointer_type.element_name, fty.many_pointer_type.is_raw);
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    /// The type name an instantiation arg node carries (`Move` in
    /// `List(Move)`). Null for non-nameable args (e.g. value params like `3`).
    fn argTypeName(node: *const Node) ?[]const u8 {
        return switch (node.data) {
            .type_expr => |te| te.name,
            .identifier => |id| id.name,
            else => null,
        };
    }

    /// Swap a single type name through a param→arg map (`T` → `Move`).
    fn substName(name: []const u8, params: []const []const u8, args: []const []const u8) []const u8 {
        for (params, 0..) |p, i| {
            if (i < args.len and std.mem.eql(u8, p, name)) return args[i];
        }
        return name;
    }

    /// Substitute generic params in an already-resolved field type. Only the
    /// name-carrying shapes need rewriting; the rest pass through.
    fn substType(ty: Type, params: []const []const u8, args: []const []const u8) Type {
        return switch (ty) {
            .many_pointer_type => |i| .{ .many_pointer_type = .{ .element_name = substName(i.element_name, params, args), .is_raw = i.is_raw } },
            .slice_type => |i| .{ .slice_type = .{ .element_name = substName(i.element_name, params, args), .is_raw = i.is_raw } },
            .array_type => |i| .{ .array_type = .{ .length = i.length, .element_name = substName(i.element_name, params, args), .is_raw = i.is_raw } },
            .pointer_type => |i| .{ .pointer_type = .{ .pointee_name = substName(i.pointee_name, params, args), .is_raw = i.is_raw } },
            .struct_type => |n| .{ .struct_type = substName(n, params, args) },
            else => ty,
        };
    }

    /// Instantiate `base(args...)` as a monomorphized struct entry so field
    /// access resolves the generic params (`List(Move).items` → `[*]Move`).
    /// Returns the instance type, or null when `base` isn't a generic struct,
    /// the arity mismatches, or an arg isn't nameable.
    fn instantiateGeneric(self: *Analyzer, base: []const u8, arg_nodes: []const *Node) ?Type {
        const info = self.struct_types.get(base) orelse return null;
        if (info.type_params.len == 0 or arg_nodes.len != info.type_params.len) return null;

        var args = std.ArrayList([]const u8).empty;
        for (arg_nodes) |an| {
            const nm = argTypeName(an) orelse return null;
            args.append(self.allocator, nm) catch return null;
        }

        // Mangle "base(A,B)".
        var name_buf = std.ArrayList(u8).empty;
        name_buf.appendSlice(self.allocator, base) catch return null;
        name_buf.append(self.allocator, '(') catch return null;
        for (args.items, 0..) |a, i| {
            if (i > 0) name_buf.append(self.allocator, ',') catch return null;
            name_buf.appendSlice(self.allocator, a) catch return null;
        }
        name_buf.append(self.allocator, ')') catch return null;
        const mangled = name_buf.toOwnedSlice(self.allocator) catch return null;

        if (self.struct_types.contains(mangled)) return .{ .struct_type = mangled };

        var new_fts = std.ArrayList(Type).empty;
        for (info.field_types) |ft| {
            new_fts.append(self.allocator, substType(ft, info.type_params, args.items)) catch return null;
        }
        self.struct_types.put(mangled, .{
            .field_names = info.field_names,
            .field_types = new_fts.toOwnedSlice(self.allocator) catch return null,
        }) catch return null;
        return .{ .struct_type = mangled };
    }

    /// Infer an approximate editor `Type` for an expression (hover/completion;
    /// metadata only — NOT a compiler type decision, which uses `TypeId`).
    /// Uses fn_signatures for call return types, struct_types for field access,
    /// and symbols for identifier types.
    pub fn inferExprType(self: *Analyzer, node: *const Node) Type {
        return switch (node.data) {
            .int_literal => Type.s(64),
            .float_literal => .f32,
            .bool_literal => .boolean,
            .string_literal => .string_type,
            .char_literal => Type.s(64),
            .insert_expr => .void_type,
            .comptime_expr => |ct| self.inferExprType(ct.expr),
            .binary_op => |binop| {
                switch (binop.op) {
                    .eq, .neq, .lt, .lte, .gt, .gte, .and_op, .or_op, .in_op => return .boolean,
                    else => {
                        // Editor display only: approximate an arithmetic result as
                        // its left operand's type (or the right when the left is
                        // unresolved). Numeric promotion is a compiler decision on
                        // `TypeId`, never recomputed here.
                        const lhs_ty = self.inferExprType(binop.lhs);
                        if (lhs_ty == .unresolved) return self.inferExprType(binop.rhs);
                        return lhs_ty;
                    },
                }
            },
            .chained_comparison => .boolean,
            .identifier => |ident| {
                // Use symbol index for O(1) name lookup
                if (self.symbol_index.get(ident.name)) |indices| {
                    var j = indices.items.len;
                    while (j > 0) {
                        j -= 1;
                        const sym = self.symbols.items[indices.items[j]];
                        if (sym.scope_depth <= self.scope_depth) {
                            return sym.ty orelse Type.unresolved;
                        }
                    }
                }
                // The implicit `context` is not a declared symbol; it types as
                // the Context struct so `context.field` records a member ref
                // with owner "Context" (definition/hover/references ride the
                // ordinary member machinery). A user binding named `context`
                // shadows via the symbol lookup above.
                if (std.mem.eql(u8, ident.name, "context")) {
                    return .{ .struct_type = "Context" };
                }
                return Type.unresolved;
            },
            .if_expr => |ie| {
                return self.inferExprType(ie.then_branch);
            },
            .block => |blk| {
                if (blk.stmts.len > 0) {
                    return self.inferExprType(blk.stmts[blk.stmts.len - 1]);
                }
                return .void_type;
            },
            .match_expr => |me| {
                for (me.arms) |arm| {
                    if (!arm.is_break) return self.inferExprType(arm.body);
                }
                return .void_type;
            },
            .call => |call_node| {
                // Receiver-aware lookup first: `recv.method()` / `Type.method()`
                // resolves through the "{Type}.{method}" signature key, so
                // same-named methods on different types don't collide.
                if (call_node.callee.data == .field_access) {
                    const fa = call_node.callee.data.field_access;
                    var recv_ty = self.inferExprType(fa.object);
                    if (recv_ty.isPointer()) recv_ty = self.resolveTypeNameStr(recv_ty.pointer_type.pointee_name, recv_ty.pointer_type.is_raw);
                    if (recv_ty.toName()) |owner| {
                        if (std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ owner, fa.field })) |key| {
                            if (self.fn_signatures.get(key)) |sig| return sig.return_type;
                        } else |_| {}
                    }
                }
                const callee_name = self.resolveCalleeName(call_node) orelse return Type.unresolved;
                // Check fn_signatures registry
                if (self.fn_signatures.get(callee_name)) |sig| {
                    return sig.return_type;
                }
                // Built-in: sqrt/sin/cos returns same type as argument
                const base = baseName(callee_name);
                if (std.mem.eql(u8, base, "sqrt") or
                    std.mem.eql(u8, base, "sin") or
                    std.mem.eql(u8, base, "cos"))
                {
                    if (call_node.args.len > 0) return self.inferExprType(call_node.args[0]);
                    return .f32;
                }
                return Type.unresolved;
            },
            .unary_op => |unop| {
                return self.inferExprType(unop.operand);
            },
            .field_access => |fa| {
                var obj_ty = self.inferExprType(fa.object);
                // `p.field` where `p` is `*T` resolves on the pointee `T`.
                if (obj_ty.isPointer()) {
                    obj_ty = self.resolveTypeNameStr(obj_ty.pointer_type.pointee_name, obj_ty.pointer_type.is_raw);
                }
                // `.len` / `.ptr` on the built-in containers (string, slice, array).
                if (std.mem.eql(u8, fa.field, "len")) {
                    if (obj_ty == .string_type or obj_ty.isSlice() or obj_ty.isArray()) return Type.s(64);
                }
                if (std.mem.eql(u8, fa.field, "ptr")) {
                    if (obj_ty == .string_type) return .{ .many_pointer_type = .{ .element_name = "u8", .is_raw = false } };
                    if (obj_ty.isSlice()) return .{ .many_pointer_type = .{ .element_name = obj_ty.slice_type.element_name, .is_raw = obj_ty.slice_type.is_raw } };
                    if (obj_ty.isArray()) return .{ .many_pointer_type = .{ .element_name = obj_ty.array_type.element_name, .is_raw = obj_ty.array_type.is_raw } };
                }
                if (obj_ty.isStruct()) {
                    if (self.struct_types.get(obj_ty.struct_type)) |info| {
                        for (info.field_names, 0..) |fname, idx| {
                            if (std.mem.eql(u8, fname, fa.field)) {
                                return info.field_types[idx];
                            }
                        }
                    }
                }
                if (obj_ty.isArray()) {
                    return self.resolveTypeNameStr(obj_ty.array_type.element_name, obj_ty.array_type.is_raw);
                }
                return Type.unresolved;
            },
            .index_expr => |ie| {
                const obj_ty = self.inferExprType(ie.object);
                if (obj_ty == .string_type) return Type.u(8);
                if (obj_ty.isArray()) return self.resolveTypeNameStr(obj_ty.array_type.element_name, obj_ty.array_type.is_raw);
                if (obj_ty.isManyPointer()) return self.resolveTypeNameStr(obj_ty.many_pointer_type.element_name, obj_ty.many_pointer_type.is_raw);
                if (obj_ty.isSlice()) return self.resolveTypeNameStr(obj_ty.slice_type.element_name, obj_ty.slice_type.is_raw);
                return Type.unresolved;
            },
            .slice_expr => |se| {
                const obj_ty = self.inferExprType(se.object);
                if (obj_ty == .string_type) return .string_type;
                if (obj_ty.isArray()) return .{ .slice_type = .{ .element_name = obj_ty.array_type.element_name, .is_raw = obj_ty.array_type.is_raw } };
                if (obj_ty.isManyPointer()) return .{ .slice_type = .{ .element_name = obj_ty.many_pointer_type.element_name, .is_raw = obj_ty.many_pointer_type.is_raw } };
                if (obj_ty.isSlice()) return obj_ty;
                return .void_type;
            },
            .while_expr => .void_type,
            .for_expr => .void_type,
            .spread_expr => .void_type,
            .break_expr => .void_type,
            .continue_expr => .void_type,
            .enum_literal => .{ .enum_type = "" },
            .struct_literal => |sl| {
                if (sl.struct_name) |name| {
                    if (self.struct_types.contains(name)) return .{ .struct_type = name };
                    if (self.type_aliases.get(name)) |target| {
                        if (self.struct_types.contains(target)) return .{ .struct_type = target };
                    }
                } else if (sl.type_expr) |te| {
                    // Handle parameterized struct: List(i32).{} parses as call node
                    if (te.data == .call) {
                        if (self.resolveCalleeName(te.data.call)) |callee| {
                            if (self.instantiateGeneric(callee, te.data.call.args)) |inst| return inst;
                            if (self.struct_types.contains(callee)) return .{ .struct_type = callee };
                        }
                    }
                    return self.inferExprType(te);
                }
                return .void_type;
            },
            .force_unwrap => |fu| {
                const opt_ty = self.inferExprType(fu.operand);
                if (opt_ty.isOptional()) return self.resolveTypeNameStr(opt_ty.optional_type.child_name, opt_ty.optional_type.is_raw);
                return .void_type;
            },
            .null_coalesce => |nc| {
                const opt_ty = self.inferExprType(nc.lhs);
                if (opt_ty.isOptional()) return self.resolveTypeNameStr(opt_ty.optional_type.child_name, opt_ty.optional_type.is_raw);
                return self.inferExprType(nc.rhs);
            },
            .deref_expr => |de| {
                const ptr_ty = self.inferExprType(de.operand);
                if (ptr_ty.isPointer()) return self.resolveTypeNameStr(ptr_ty.pointer_type.pointee_name, ptr_ty.pointer_type.is_raw);
                return .void_type;
            },
            .postfix_cast => |pc| return self.resolveTypeNode(pc.type_expr),
            .null_literal => .void_type,
            .array_literal => .void_type,
            .type_expr => |te| .{ .meta_type = .{ .name = te.name } },
            .parameterized_type_expr => |pte| {
                if (self.instantiateGeneric(pte.name, pte.args)) |inst| return inst;
                if (self.struct_types.contains(pte.name)) return .{ .struct_type = pte.name };
                return .void_type;
            },
            else => .void_type,
        };
    }

    /// Resolve the callee name from a call node (handles identifiers and field_access).
    fn resolveCalleeName(self: *Analyzer, call_node: ast.Call) ?[]const u8 {
        _ = self;
        if (call_node.callee.data == .identifier) {
            return call_node.callee.data.identifier.name;
        }
        if (call_node.callee.data == .field_access) {
            const fa = call_node.callee.data.field_access;
            if (fa.object.data == .identifier) {
                // Return qualified name — caller will look up in fn_signatures
                // We can't allocate here easily, so just return the field name
                // and let the caller try both qualified and unqualified
                return fa.field;
            }
        }
        return null;
    }

    /// Pass 2: analyse the body/value of a top-level declaration.
    /// The symbol itself was already registered in Pass 1.
    fn analyzeTopLevelDecl(self: *Analyzer, node: *Node) !void {
        switch (node.data) {
            .fn_decl => |fd| {
                const saved_cc = self.in_c_conv;
                self.in_c_conv = fd.abi == .c;
                try self.pushScope();
                try self.analyzeParams(fd.params);
                try self.analyzeNode(fd.body);
                self.popScope();
                self.in_c_conv = saved_cc;
            },
            .const_decl => |cd| {
                try self.analyzeNode(cd.value);
            },
            .var_decl => |vd| {
                if (vd.value) |val| {
                    try self.analyzeNode(val);
                }
            },
            .struct_decl => |sd| {
                // Analyse method bodies (each in its own scope) so identifiers
                // used inside them are recorded as references.
                for (sd.methods) |mnode| {
                    if (mnode.data == .fn_decl) {
                        const m = mnode.data.fn_decl;
                        const saved_cc = self.in_c_conv;
                        self.in_c_conv = m.abi == .c;
                        try self.pushScope();
                        try self.analyzeParams(m.params);
                        try self.analyzeNode(m.body);
                        self.popScope();
                        self.in_c_conv = saved_cc;
                    }
                }
            },
            .enum_decl, .union_decl, .array_type_expr, .slice_type_expr, .array_literal, .parameterized_type_expr, .index_expr, .slice_expr, .insert_expr, .ufcs_alias => {},
            .namespace_decl => |ns| {
                try self.pushScope();
                for (ns.decls) |d| {
                    try self.registerTopLevelDecl(d);
                }
                for (ns.decls) |d| {
                    try self.analyzeTopLevelDecl(d);
                }
                self.popScope();
            },
            else => {
                try self.analyzeNode(node);
            },
        }
    }

    fn pushScope(self: *Analyzer) !void {
        try self.scope_starts.append(self.allocator, @intCast(self.symbols.items.len));
        self.scope_depth += 1;
    }

    fn popScope(self: *Analyzer) void {
        if (self.scope_starts.items.len > 0) {
            _ = self.scope_starts.pop();
            self.scope_depth -= 1;
        }
    }

    fn analyzeParams(self: *Analyzer, params: []const ast.Param) !void {
        for (params) |param| {
            self.resolveTypeRef(param.type_expr);
            // `fieldType` (not `fromTypeExpr`) so pointer/slice/array param types
            // like `*Board` / `[]Event` resolve instead of becoming null.
            try self.addSymbol(param.name, .param, self.fieldType(param.type_expr), param.name_span);
        }
    }

    fn addSymbol(self: *Analyzer, name: []const u8, kind: SymbolKind, ty: ?Type, span: Span) !void {
        // Check for duplicate using the symbol index
        // Variables are allowed to shadow in the same scope (sx semantics)
        if (kind != .variable) if (self.symbol_index.get(name)) |indices| {
            const scope_start: u32 = if (self.scope_starts.items.len > 0)
                self.scope_starts.items[self.scope_starts.items.len - 1]
            else
                0;
            for (indices.items) |idx| {
                if (idx >= scope_start) {
                    const sym = self.symbols.items[idx];
                    // Skip imported symbols — local declarations are allowed to shadow them
                    if (sym.origin != null) continue;
                    if (sym.scope_depth == self.scope_depth) {
                        try self.diagnostics.append(self.allocator, .{
                            .level = .warn,
                            .span = span,
                            .message = "duplicate declaration",
                        });
                        break;
                    }
                }
            }
        };

        try self.symbols.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .ty = ty,
            .visibility = self.pending_visibility,
            .def_span = span,
            .scope_depth = self.scope_depth,
        });
        // Update symbol index
        const idx: u32 = @intCast(self.symbols.items.len - 1);
        const gop = try self.symbol_index.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u32).empty;
        }
        try gop.value_ptr.append(self.allocator, idx);
    }

    /// Check if a symbol name has been registered.
    pub fn hasSymbol(self: *const Analyzer, name: []const u8) bool {
        return self.symbol_index.contains(name);
    }

    /// Pre-register an imported symbol so references in this file can resolve to it.
    pub fn preRegisterSymbol(self: *Analyzer, sym: Symbol) !void {
        try self.symbols.append(self.allocator, sym);
        // Update symbol index
        const idx: u32 = @intCast(self.symbols.items.len - 1);
        const gop = try self.symbol_index.getOrPut(sym.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u32).empty;
        }
        try gop.value_ptr.append(self.allocator, idx);
    }

    /// Span of an AST string slice that points into `source` (field/variant/
    /// method names are such slices). Returns {0,0} for synthetic strings.
    fn spanOf(self: *Analyzer, s: []const u8) Span {
        if (self.source.len == 0 or s.len == 0) return .{ .start = 0, .end = 0 };
        const base = @intFromPtr(self.source.ptr);
        const p = @intFromPtr(s.ptr);
        if (p < base or p + s.len > base + self.source.len) return .{ .start = 0, .end = 0 };
        const start: u32 = @intCast(p - base);
        return .{ .start = start, .end = start + @as(u32, @intCast(s.len)) };
    }

    fn recordMemberRef(self: *Analyzer, name: []const u8, owner: []const u8, is_def: bool) void {
        const span = self.spanOf(name);
        if (span.end == 0) return; // not locatable in source
        self.member_refs.append(self.allocator, .{ .span = span, .name = name, .owner = owner, .is_def = is_def }) catch {};
    }

    fn resolveIdentifier(self: *Analyzer, name: []const u8, span: Span) !void {
        if (self.in_c_conv and std.mem.eql(u8, name, "context")) {
            try self.diagnostics.append(self.allocator, .{
                .level = .warn,
                .span = span,
                .message = "`context` is unavailable in an `abi(.c)` function — the C ABI has no implicit context parameter; pass what you need explicitly",
            });
            return;
        }
        // Use symbol index for O(1) name lookup, then walk backwards through indices
        if (self.symbol_index.get(name)) |indices| {
            var j = indices.items.len;
            while (j > 0) {
                j -= 1;
                const idx = indices.items[j];
                const sym = self.symbols.items[idx];
                if (sym.scope_depth <= self.scope_depth) {
                    try self.references.append(self.allocator, .{
                        .span = span,
                        .symbol_index = idx,
                    });
                    return;
                }
            }
        }

        // Built-in names that aren't declared in source
        const builtins = [_][]const u8{ "io", "true", "false", "closure", "size_of", "align_of", "malloc", "free", "memcpy", "memset", "context" };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return;
        }

        try self.diagnostics.append(self.allocator, .{
            .level = .warn,
            .span = span,
            .message = "undefined variable",
        });
    }

    fn analyzeNode(self: *Analyzer, node: *Node) !void {
        switch (node.data) {
            .fn_decl => |fd| {
                const local_ret_ty = self.resolveReturnType(fd) orelse
                    if (fd.is_arrow) self.inferFnReturnType(fd.params, fd.body) else null;
                try self.addSymbol(fd.name, .function, local_ret_ty, node.span);
                // Register fn_signatures for local functions (for return type hints + hover)
                {
                    var param_types = std.ArrayList(Type).empty;
                    for (fd.params) |param| {
                        const pt = self.fieldType(param.type_expr);
                        try param_types.append(self.allocator, pt);
                    }
                    try self.fn_signatures.put(fd.name, .{
                        .param_types = try param_types.toOwnedSlice(self.allocator),
                        .return_type = local_ret_ty orelse .void_type,
                    });
                }
                const saved_cc = self.in_c_conv;
                self.in_c_conv = fd.abi == .c;
                try self.pushScope();
                try self.analyzeParams(fd.params);
                try self.analyzeNode(fd.body);
                self.popScope();
                self.in_c_conv = saved_cc;
            },
            .block => |blk| {
                try self.pushScope();
                for (blk.stmts) |stmt| {
                    try self.analyzeNode(stmt);
                }
                self.popScope();
            },
            .const_decl => |cd| {
                // Analyze value first (so it can't reference itself)
                try self.analyzeNode(cd.value);
                const ty = self.resolveTypeAnnotation(cd.type_annotation) orelse inferValueType(cd.value);
                const kind = classifyConstDecl(cd);
                try self.addSymbol(cd.name, kind, ty, node.span);
            },
            .var_decl => |vd| {
                if (vd.value) |val| {
                    try self.analyzeNode(val);
                }
                const ty = self.resolveTypeAnnotation(vd.type_annotation) orelse
                    if (vd.value) |val| self.inferExprType(val) else null;
                try self.addSymbol(vd.name, .variable, ty, node.span);
            },
            .context_extend_decl => |ce| {
                // Declares a Context field, not a module-scope symbol. Record
                // the field name as a MEMBER DEFINITION owned by "Context" —
                // the same (owner, name) index struct fields use — so
                // definition/hover/find-references from `context.field` reads
                // and push-literal field names resolve here across documents.
                self.recordMemberRef(ce.name, "Context", true);
                if (ce.default_expr) |de| try self.analyzeNode(de);
            },
            .enum_decl => |ed| {
                if (ed.variant_types.len > 0) {
                    try self.addSymbol(ed.name, .enum_type, .{ .union_type = ed.name }, node.span);
                } else {
                    try self.addSymbol(ed.name, .enum_type, .{ .enum_type = ed.name }, node.span);
                }
            },
            .struct_decl => |sd| {
                try self.addSymbol(sd.name, .struct_type, .{ .struct_type = sd.name }, node.span);
            },
            .identifier => |id| {
                try self.resolveIdentifier(id.name, node.span);
            },
            .binary_op => |bop| {
                try self.analyzeNode(bop.lhs);
                try self.analyzeNode(bop.rhs);
            },
            .chained_comparison => |cc| {
                for (cc.operands) |operand| {
                    try self.analyzeNode(operand);
                }
            },
            .unary_op => |uop| {
                try self.analyzeNode(uop.operand);
            },
            .call => |call| {
                try self.analyzeNode(call.callee);
                for (call.args) |arg| {
                    try self.analyzeNode(arg);
                }
                // Mirror lower.zig: passing a `*T` where a `T` value is expected
                // (a `for xs: (*m)` capture, a `*T` parameter, any pointer local).
                // Restricted to direct (identifier) calls so args align 1:1 with
                // the declared params — UFCS/method calls drop the receiver.
                if (call.callee.data == .identifier) {
                    if (self.resolveCalleeName(call)) |callee_name| {
                        if (self.fn_signatures.get(callee_name)) |sig| {
                            const n = @min(call.args.len, sig.param_types.len);
                            var i: usize = 0;
                            while (i < n) : (i += 1) {
                                const pt = sig.param_types[i];
                                if (pt.isPointer()) continue;
                                const pt_name = pt.toName() orelse continue;
                                const at = self.inferExprType(call.args[i]);
                                if (!at.isPointer()) continue;
                                if (!std.mem.eql(u8, at.pointer_type.pointee_name, pt_name)) continue;
                                const msg = if (call.args[i].data == .identifier)
                                    std.fmt.allocPrint(self.allocator, "argument '{s}' has type '*{s}', but '{s}' is expected here; dereference it with `{s}.*`", .{ call.args[i].data.identifier.name, pt_name, pt_name, call.args[i].data.identifier.name }) catch continue
                                else
                                    std.fmt.allocPrint(self.allocator, "argument has type '*{s}', but '{s}' is expected here; dereference it with `.*`", .{ pt_name, pt_name }) catch continue;
                                try self.diagnostics.append(self.allocator, .{ .level = .err, .span = call.args[i].span, .message = msg });
                            }
                        }
                    }
                }
            },
            .ffi_intrinsic_call => |fic| {
                try self.analyzeNode(fic.return_type);
                for (fic.args) |arg| {
                    try self.analyzeNode(arg);
                }
            },
            .field_access => |fa| {
                try self.analyzeNode(fa.object);
                var owner_ty = self.inferExprType(fa.object);
                if (owner_ty.isPointer()) owner_ty = self.resolveTypeNameStr(owner_ty.pointer_type.pointee_name, owner_ty.pointer_type.is_raw);
                self.recordMemberRef(fa.field, owner_ty.toName() orelse "", false);
            },
            .enum_literal => |el| {
                self.recordMemberRef(el.name, "", false);
            },
            .if_expr => |ie| {
                try self.analyzeNode(ie.condition);
                if (ie.binding_name) |bname| {
                    // `if val := expr { ... }` — val is the unwrapped optional
                    const cond_ty = self.inferExprType(ie.condition);
                    const inner_ty: ?Type = if (cond_ty.isOptional())
                        self.resolveTypeNameStr(cond_ty.optional_type.child_name, cond_ty.optional_type.is_raw)
                    else
                        null;
                    try self.pushScope();
                    try self.addSymbol(bname, .variable, inner_ty, node.span);
                    try self.analyzeNode(ie.then_branch);
                    self.popScope();
                } else {
                    try self.analyzeNode(ie.then_branch);
                }
                if (ie.else_branch) |eb| {
                    try self.analyzeNode(eb);
                }
            },
            .match_expr => |me| {
                try self.analyzeNode(me.subject);
                var subj_ty = self.inferExprType(me.subject);
                if (subj_ty.isPointer()) subj_ty = self.resolveTypeNameStr(subj_ty.pointer_type.pointee_name, subj_ty.pointer_type.is_raw);
                const subj_owner = subj_ty.toName() orelse "";
                for (me.arms) |arm| {
                    if (arm.pattern) |pat| {
                        if (pat.data == .enum_literal) self.recordMemberRef(pat.data.enum_literal.name, subj_owner, false);
                    }
                    try self.pushScope();
                    if (arm.capture) |cap_name| {
                        try self.addSymbol(cap_name, .variable, null, arm.body.span);
                    }
                    try self.analyzeNode(arm.body);
                    self.popScope();
                }
            },
            .while_expr => |we| {
                try self.analyzeNode(we.condition);
                if (we.binding_name) |bname| {
                    const cond_ty = self.inferExprType(we.condition);
                    const inner_ty: ?Type = if (cond_ty.isOptional())
                        self.resolveTypeNameStr(cond_ty.optional_type.child_name, cond_ty.optional_type.is_raw)
                    else
                        null;
                    try self.pushScope();
                    try self.addSymbol(bname, .variable, inner_ty, node.span);
                    try self.analyzeNode(we.body);
                    self.popScope();
                } else {
                    try self.analyzeNode(we.body);
                }
            },
            .for_expr => |fe| {
                for (fe.iterables) |it| {
                    try self.analyzeNode(it.expr);
                    if (it.range_end) |re| try self.analyzeNode(re);
                }
                try self.pushScope();
                for (fe.captures, 0..) |cap, i| {
                    if (std.mem.eql(u8, cap.name, "_")) continue;
                    const it = fe.iterables[i];
                    var cap_ty: ?Type = null;
                    if (it.is_range) {
                        cap_ty = .{ .signed = 64 };
                    } else if (self.elementTypeOf(self.inferExprType(it.expr))) |elem| {
                        cap_ty = if (cap.by_ref)
                            (if (elem.toName()) |en| Type{ .pointer_type = .{ .pointee_name = en, .is_raw = innerNameIsRaw(elem) } } else elem)
                        else
                            elem;
                    }
                    try self.addSymbol(cap.name, .variable, cap_ty, node.span);
                }
                try self.analyzeNode(fe.body);
                self.popScope();
            },
            .spread_expr => |se| try self.analyzeNode(se.operand),
            .break_expr, .continue_expr => {},
            .assignment => |asgn| {
                try self.analyzeNode(asgn.target);
                try self.analyzeNode(asgn.value);
            },
            .multi_assign => |ma| {
                for (ma.targets) |t| try self.analyzeNode(t);
                for (ma.values) |v| try self.analyzeNode(v);
            },
            .destructure_decl => |dd| {
                try self.analyzeNode(dd.value);
            },
            .return_stmt => |ret| {
                if (ret.value) |val| {
                    try self.analyzeNode(val);
                }
            },
            .defer_stmt => |ds| {
                try self.analyzeNode(ds.expr);
            },
            .raise_stmt => |rs| {
                try self.analyzeNode(rs.tag);
            },
            .try_expr => |te| {
                try self.analyzeNode(te.operand);
            },
            .caller_location => {}, // leaf marker (ERR E4.1b) — no sub-nodes
            .error_directive => {}, // leaf marker — the flatten pass owns the emit
            .catch_expr => |ce| {
                try self.analyzeNode(ce.operand);
                try self.pushScope();
                if (ce.binding) |bname| {
                    try self.addSymbol(bname, .variable, null, node.span);
                }
                try self.analyzeNode(ce.body);
                self.popScope();
            },
            .onfail_stmt => |os| {
                try self.pushScope();
                if (os.binding) |bname| {
                    try self.addSymbol(bname, .variable, null, node.span);
                }
                try self.analyzeNode(os.body);
                self.popScope();
            },
            .push_stmt => |ps| {
                // A `push .{ … }` literal patches Context fields: index its
                // field names with owner "Context" (the anonymous literal
                // itself resolves to no owner in the generic arm above).
                if (ps.context_expr.data == .struct_literal) {
                    const sl = ps.context_expr.data.struct_literal;
                    if (sl.struct_name == null and sl.type_expr == null) {
                        for (sl.field_inits) |fi| {
                            if (fi.name) |fname| self.recordMemberRef(fname, "Context", false);
                        }
                    }
                }
                try self.analyzeNode(ps.context_expr);
                try self.analyzeNode(ps.body);
            },
            .comptime_expr => |ct| {
                try self.analyzeNode(ct.expr);
            },
            .insert_expr => |ins| {
                try self.analyzeNode(ins.expr);
            },
            .lambda => |lam| {
                try self.pushScope();
                try self.analyzeParams(lam.params);
                try self.analyzeNode(lam.body);
                self.popScope();
            },
            .struct_literal => |sl| {
                if (sl.type_expr) |te| try self.analyzeNode(te);
                // Index the literal's FIELD NAMES as member refs against the
                // literal's resolved owner type (`Point.{ x = … }` → owner
                // "Point"), so go-to-definition / references work from literal
                // field names, not just `obj.field` reads. An anonymous
                // literal has no resolvable owner here — except as a `push`
                // context expression, which the `.push_stmt` arm owns.
                const owner = self.inferExprType(node).toName() orelse "";
                for (sl.field_inits) |fi| {
                    if (owner.len != 0) {
                        if (fi.name) |fname| self.recordMemberRef(fname, owner, false);
                    }
                    try self.analyzeNode(fi.value);
                }
            },
            .union_decl => |ud| {
                try self.addSymbol(ud.name, .enum_type, .{ .union_type = ud.name }, node.span);
            },
            .error_set_decl => |esd| {
                // Register the set name; error-set semantics arrive in the ERR
                // stream's E1 sema steps.
                try self.addSymbol(esd.name, .type_alias, null, node.span);
            },
            // Leaf nodes — nothing to recurse into
            .int_literal,
            .float_literal,
            .bool_literal,
            .string_literal,
            .char_literal,
            .type_expr,
            .param,
            .match_arm,
            .undef_literal,
            .inferred_type,
            .intrinsic_expr,
            .library_decl,
            .framework_decl,
            .function_type_expr,
            .closure_type_expr,
            .import_decl,
            .c_import_decl,
            .array_type_expr,
            .slice_type_expr,
            .pointer_type_expr,
            .many_pointer_type_expr,
            .optional_type_expr,
            .error_type_expr,
            .pack_index_type_expr,
            .comptime_pack_ref,
            .null_literal,
            .array_literal,
            .parameterized_type_expr,
            .index_expr,
            .slice_expr,
            .tuple_type_expr,
            .return_type_expr,
            => {},
            .protocol_decl => |pd| {
                try self.addSymbol(pd.name, .protocol_type, null, node.span);
                // Recurse into default method bodies
                for (pd.methods) |method| {
                    if (method.default_body) |body| {
                        try self.pushScope();
                        // `self` is implicit in protocol default methods
                        try self.addSymbol("self", .param, null, node.span);
                        for (method.param_names) |pname| {
                            try self.addSymbol(pname, .param, null, node.span);
                        }
                        try self.analyzeNode(body);
                        self.popScope();
                    }
                }
            },
            .runtime_class_decl => |fd| {
                try self.addSymbol(fd.name, .type_alias, null, node.span);
                if (fd.is_extern and fd.is_main) {
                    try self.diagnostics.append(self.allocator, .{
                        .level = .err,
                        .message = "'extern' and '#jni_main' / '#objc_main' are mutually exclusive — a extern-referenced class can't be the app's main entry",
                        .span = node.span,
                    });
                }
                if (fd.is_extern) {
                    for (fd.members) |m| switch (m) {
                        .method => |md| if (md.body != null) {
                            try self.diagnostics.append(self.allocator, .{
                                .level = .err,
                                .message = "methods on a 'extern' class can't have bodies — they reference runtime implementations",
                                .span = node.span,
                            });
                        },
                        else => {},
                    };
                }
            },
            .jni_env_block => |eb| {
                try self.analyzeNode(eb.env);
                try self.pushScope();
                try self.analyzeNode(eb.body);
                self.popScope();
            },
            .asm_expr => |ae| {
                // Walk the template and each operand payload (input exprs;
                // out_value type exprs are leaves). Result-type derivation is
                // Phase B; lowering bails until then.
                try self.analyzeNode(ae.template);
                for (ae.operands) |op| try self.analyzeNode(op.payload);
            },
            .asm_global => |ag| try self.analyzeNode(ag.template),
            .impl_block => |ib| {
                // Each impl block gets its own scope so methods don't conflict across impls
                try self.pushScope();
                for (ib.methods) |method_node| {
                    try self.analyzeNode(method_node);
                }
                self.popScope();
            },
            .ufcs_alias => |ua| {
                // Register the alias name as a function and resolve the target
                try self.addSymbol(ua.name, .function, null, node.span);
                try self.resolveIdentifier(ua.target, node.span);
            },
            .tuple_literal => |tl| {
                for (tl.elements) |elem| {
                    try self.analyzeNode(elem.value);
                }
            },
            .force_unwrap => |fu| {
                try self.analyzeNode(fu.operand);
            },
            .null_coalesce => |nc| {
                try self.analyzeNode(nc.lhs);
                try self.analyzeNode(nc.rhs);
            },
            .deref_expr => |de| {
                try self.analyzeNode(de.operand);
            },
            .postfix_cast => |pc| {
                try self.analyzeNode(pc.operand);
            },
            .namespace_decl => |ns| {
                for (ns.decls) |d| {
                    try self.analyzeNode(d);
                }
            },
            .root => {
                // Should not appear nested
            },
        }

        // Populate TypeMap for expression nodes
        switch (node.data) {
            .int_literal,
            .float_literal,
            .bool_literal,
            .string_literal,
            .char_literal,
            .identifier,
            .binary_op,
            .chained_comparison,
            .unary_op,
            .call,
            .field_access,
            .if_expr,
            .match_expr,
            .block,
            .comptime_expr,
            .enum_literal,
            .struct_literal,
            .array_literal,
            .index_expr,
            .slice_expr,
            .deref_expr,
            .force_unwrap,
            .null_coalesce,
            .null_literal,
            .type_expr,
            .insert_expr,
            .while_expr,
            .for_expr,
            .spread_expr,
            .break_expr,
            .continue_expr,
            => {
                const ty = self.inferExprType(node);
                self.type_map.put(node, ty) catch {};
            },
            else => {},
        }
    }

    fn resolveReturnType(self: *Analyzer, fd: ast.FnDecl) ?Type {
        if (fd.return_type) |rt| {
            // `fieldType`, not `Type.fromTypeExpr` — the latter only handles a
            // bare `type_expr`, so a `[]T` / `*T` / `[*]T` return silently
            // became void and clobbered correct signatures on merge.
            return self.fieldType(rt);
        }
        return null;
    }

    /// Infer return type from a function/lambda body by temporarily registering params.
    fn inferFnReturnType(self: *Analyzer, params: []const ast.Param, body: *const Node) ?Type {
        self.pushScope() catch return null;
        for (params) |param| {
            const pt = self.fieldType(param.type_expr);
            self.addSymbol(param.name, .param, pt, param.name_span) catch {};
        }
        // Arrow fn_decl wraps body in block{[expr]} — unwrap to inner expression
        const expr_node = if (body.data == .block) blk: {
            const stmts = body.data.block.stmts;
            if (stmts.len > 0) break :blk stmts[stmts.len - 1];
            break :blk body;
        } else body;

        const inferred = self.inferExprType(expr_node);
        self.popScope();
        if (inferred != .void_type) return inferred;
        return null;
    }

    fn resolveTypeAnnotation(self: *Analyzer, type_node: ?*Node) ?Type {
        if (type_node) |tn| {
            if (Type.fromTypeExpr(tn)) |t| return t;
            // Check registered types (structs, enums, tagged enums)
            if (tn.data == .type_expr) {
                const name = tn.data.type_expr.name;
                // Check type aliases first
                const resolved = self.type_aliases.get(name) orelse name;
                if (self.symbol_index.get(resolved)) |indices| {
                    for (indices.items) |idx| {
                        if (self.symbols.items[idx].ty) |ty| {
                            // Register a reference so go-to-definition works on type names
                            self.tryAddReference(resolved, tn.span);
                            return ty;
                        }
                    }
                }
            }
            // Compound types: ?T, *T, [*]T, []T, [N]T — delegate to resolveTypeNode
            switch (tn.data) {
                .optional_type_expr, .pointer_type_expr, .many_pointer_type_expr,
                .slice_type_expr, .array_type_expr,
                => {
                    const resolved = self.resolveTypeNode(tn);
                    if (resolved != .void_type) return resolved;
                },
                else => {},
            }
            // For compound types, resolve inner type refs
            self.resolveTypeRef(tn);
        }
        return null;
    }

    /// Try to create a reference for a name without emitting diagnostics.
    /// Used for type names where missing symbols are expected (primitives, builtins).
    fn tryAddReference(self: *Analyzer, name: []const u8, span: Span) void {
        if (self.symbol_index.get(name)) |indices| {
            var j = indices.items.len;
            while (j > 0) {
                j -= 1;
                const idx = indices.items[j];
                const sym = self.symbols.items[idx];
                if (sym.scope_depth <= self.scope_depth) {
                    self.references.append(self.allocator, .{
                        .span = span,
                        .symbol_index = idx,
                    }) catch {};
                    return;
                }
            }
        }
    }

    /// Create references for type expression nodes so go-to-definition works on type names.
    /// Only resolves compound types (pointer/slice/array element types).
    fn resolveTypeRef(self: *Analyzer, node: *Node) void {
        switch (node.data) {
            .type_expr => |te| {
                self.tryAddReference(te.name, node.span);
            },
            .pointer_type_expr => |pte| {
                self.resolveTypeRef(pte.pointee_type);
            },
            .many_pointer_type_expr => |mpte| {
                self.resolveTypeRef(mpte.element_type);
            },
            .slice_type_expr => |ste| {
                self.resolveTypeRef(ste.element_type);
            },
            .array_type_expr => |ate| {
                self.resolveTypeRef(ate.element_type);
            },
            .optional_type_expr => |ote| {
                self.resolveTypeRef(ote.inner_type);
            },
            else => {},
        }
    }

    fn inferValueType(value: *Node) ?Type {
        return switch (value.data) {
            .int_literal => Type.s(64),
            .float_literal => .f64,
            .bool_literal => .boolean,
            .string_literal => .string_type,
            .char_literal => Type.s(64),
            .type_expr => null, // type alias — no value type
            .lambda => null,
            .comptime_expr => null,
            .insert_expr => null,
            else => null,
        };
    }

    fn classifyConstDecl(cd: ast.ConstDecl) SymbolKind {
        return switch (cd.value.data) {
            .type_expr => .type_alias,
            .lambda => .function,
            else => .constant,
        };
    }
};

/// Convenience: parse and analyze in one call.
pub fn analyzeSource(allocator: std.mem.Allocator, root: *Node) !SemaResult {
    var analyzer = Analyzer.init(allocator);
    return analyzer.analyze(root);
}

fn findSpanAtOffset(comptime T: type, items: []const T, offset: u32, comptime span_field: []const u8) ?usize {
    for (items, 0..) |item, i| {
        const span = @field(item, span_field);
        if (offset >= span.start and offset < span.end) return i;
    }
    return null;
}

/// Find the symbol whose definition span contains the given byte offset.
pub fn findSymbolAtOffset(symbols: []const Symbol, offset: u32) ?usize {
    return findSpanAtOffset(Symbol, symbols, offset, "def_span");
}

/// Find the reference at the given byte offset.
pub fn findReferenceAtOffset(references: []const Reference, offset: u32) ?usize {
    return findSpanAtOffset(Reference, references, offset, "span");
}

/// Walk the AST to find the innermost node whose span contains the offset.
pub fn findNodeAtOffset(node: *Node, offset: u32) ?*Node {
    if (offset < node.span.start or offset >= node.span.end) return null;

    // Try to find a more specific child node
    switch (node.data) {
        .root => |r| {
            for (r.decls) |decl| {
                if (findNodeAtOffset(decl, offset)) |found| return found;
            }
        },
        .fn_decl => |fd| {
            if (fd.return_type) |rt| {
                if (findNodeAtOffset(rt, offset)) |found| return found;
            }
            if (findNodeAtOffset(fd.body, offset)) |found| return found;
        },
        .block => |blk| {
            for (blk.stmts) |stmt| {
                if (findNodeAtOffset(stmt, offset)) |found| return found;
            }
        },
        .const_decl => |cd| {
            if (cd.type_annotation) |ta| {
                if (findNodeAtOffset(ta, offset)) |found| return found;
            }
            if (findNodeAtOffset(cd.value, offset)) |found| return found;
        },
        .var_decl => |vd| {
            if (vd.type_annotation) |ta| {
                if (findNodeAtOffset(ta, offset)) |found| return found;
            }
            if (vd.value) |val| {
                if (findNodeAtOffset(val, offset)) |found| return found;
            }
        },
        .context_extend_decl => |ce| {
            if (findNodeAtOffset(ce.type_expr, offset)) |found| return found;
            if (ce.default_expr) |de| {
                if (findNodeAtOffset(de, offset)) |found| return found;
            }
        },
        .binary_op => |bop| {
            if (findNodeAtOffset(bop.lhs, offset)) |found| return found;
            if (findNodeAtOffset(bop.rhs, offset)) |found| return found;
        },
        .chained_comparison => |cc| {
            for (cc.operands) |operand| {
                if (findNodeAtOffset(operand, offset)) |found| return found;
            }
        },
        .unary_op => |uop| {
            if (findNodeAtOffset(uop.operand, offset)) |found| return found;
        },
        .call => |call| {
            if (findNodeAtOffset(call.callee, offset)) |found| return found;
            for (call.args) |arg| {
                if (findNodeAtOffset(arg, offset)) |found| return found;
            }
        },
        .ffi_intrinsic_call => |fic| {
            if (findNodeAtOffset(fic.return_type, offset)) |found| return found;
            for (fic.args) |arg| {
                if (findNodeAtOffset(arg, offset)) |found| return found;
            }
        },
        .field_access => |fa| {
            if (findNodeAtOffset(fa.object, offset)) |found| return found;
        },
        .if_expr => |ie| {
            if (findNodeAtOffset(ie.condition, offset)) |found| return found;
            if (findNodeAtOffset(ie.then_branch, offset)) |found| return found;
            if (ie.else_branch) |eb| {
                if (findNodeAtOffset(eb, offset)) |found| return found;
            }
        },
        .match_expr => |me| {
            if (findNodeAtOffset(me.subject, offset)) |found| return found;
            for (me.arms) |arm| {
                if (findNodeAtOffset(arm.body, offset)) |found| return found;
                if (arm.pattern) |pat| {
                    if (findNodeAtOffset(pat, offset)) |found| return found;
                }
            }
        },
        .while_expr => |we| {
            if (findNodeAtOffset(we.condition, offset)) |found| return found;
            if (findNodeAtOffset(we.body, offset)) |found| return found;
        },
        .for_expr => |fe| {
            for (fe.iterables) |it| {
                if (findNodeAtOffset(it.expr, offset)) |found| return found;
                if (it.range_end) |re| {
                    if (findNodeAtOffset(re, offset)) |found| return found;
                }
            }
            if (findNodeAtOffset(fe.body, offset)) |found| return found;
        },
        .spread_expr => |se| {
            if (findNodeAtOffset(se.operand, offset)) |found| return found;
        },
        .break_expr, .continue_expr => {},
        .caller_location => {},
        .error_directive => {},
        .assignment => |asgn| {
            if (findNodeAtOffset(asgn.target, offset)) |found| return found;
            if (findNodeAtOffset(asgn.value, offset)) |found| return found;
        },
        .multi_assign => |ma| {
            for (ma.targets) |t| {
                if (findNodeAtOffset(t, offset)) |found| return found;
            }
            for (ma.values) |v| {
                if (findNodeAtOffset(v, offset)) |found| return found;
            }
        },
        .destructure_decl => |dd| {
            if (findNodeAtOffset(dd.value, offset)) |found| return found;
        },
        .return_stmt => |ret| {
            if (ret.value) |val| {
                if (findNodeAtOffset(val, offset)) |found| return found;
            }
        },
        .defer_stmt => |ds| {
            if (findNodeAtOffset(ds.expr, offset)) |found| return found;
        },
        .raise_stmt => |rs| {
            if (findNodeAtOffset(rs.tag, offset)) |found| return found;
        },
        .try_expr => |te| {
            if (findNodeAtOffset(te.operand, offset)) |found| return found;
        },
        .catch_expr => |ce| {
            if (findNodeAtOffset(ce.operand, offset)) |found| return found;
            if (findNodeAtOffset(ce.body, offset)) |found| return found;
        },
        .onfail_stmt => |os| {
            if (findNodeAtOffset(os.body, offset)) |found| return found;
        },
        .push_stmt => |ps| {
            if (findNodeAtOffset(ps.context_expr, offset)) |found| return found;
            if (findNodeAtOffset(ps.body, offset)) |found| return found;
        },
        .comptime_expr => |ct| {
            if (findNodeAtOffset(ct.expr, offset)) |found| return found;
        },
        .insert_expr => |ins| {
            if (findNodeAtOffset(ins.expr, offset)) |found| return found;
        },
        .lambda => |lam| {
            if (findNodeAtOffset(lam.body, offset)) |found| return found;
        },
        .struct_literal => |sl| {
            for (sl.field_inits) |fi| {
                if (findNodeAtOffset(fi.value, offset)) |found| return found;
            }
        },
        // Leaf nodes
        .enum_literal,
        .identifier,
        .int_literal,
        .float_literal,
        .bool_literal,
        .string_literal,
        .char_literal,
        .type_expr,
        .param,
        .match_arm,
        .undef_literal,
        .inferred_type,
        .intrinsic_expr,
        .library_decl,
        .framework_decl,
        .function_type_expr,
        .enum_decl,
        .union_decl,
        .error_set_decl,
        .error_type_expr,
        .import_decl,
        .c_import_decl,
        .array_type_expr,
        .slice_type_expr,
        .pointer_type_expr,
        .many_pointer_type_expr,
        .optional_type_expr,
        .pack_index_type_expr,
        .comptime_pack_ref,
        .null_literal,
        .array_literal,
        .parameterized_type_expr,
        .index_expr,
        .slice_expr,
        .tuple_type_expr,
        .return_type_expr,
        .ufcs_alias,
        .closure_type_expr,
        .runtime_class_decl,
        => {},
        .jni_env_block => |eb| {
            if (findNodeAtOffset(eb.env, offset)) |found| return found;
            if (findNodeAtOffset(eb.body, offset)) |found| return found;
        },
        .struct_decl => |sd| {
            for (sd.methods) |method_node| {
                if (findNodeAtOffset(method_node, offset)) |found| return found;
            }
        },
        .protocol_decl => |pd| {
            for (pd.methods) |method| {
                if (method.default_body) |body| {
                    if (findNodeAtOffset(body, offset)) |found| return found;
                }
                for (method.params) |param| {
                    if (findNodeAtOffset(param, offset)) |found| return found;
                }
            }
        },
        .impl_block => |ib| {
            for (ib.methods) |method_node| {
                if (findNodeAtOffset(method_node, offset)) |found| return found;
            }
        },
        .tuple_literal => |tl| {
            for (tl.elements) |elem| {
                if (findNodeAtOffset(elem.value, offset)) |found| return found;
            }
        },
        .null_coalesce => |nc| {
            if (findNodeAtOffset(nc.lhs, offset)) |found| return found;
            if (findNodeAtOffset(nc.rhs, offset)) |found| return found;
        },
        .force_unwrap => |fu| {
            if (findNodeAtOffset(fu.operand, offset)) |found| return found;
        },
        .deref_expr => |de| {
            if (findNodeAtOffset(de.operand, offset)) |found| return found;
        },
        .postfix_cast => |pc| {
            if (findNodeAtOffset(pc.operand, offset)) |found| return found;
            if (findNodeAtOffset(pc.type_expr, offset)) |found| return found;
        },
        .namespace_decl => |ns| {
            for (ns.decls) |d| {
                if (findNodeAtOffset(d, offset)) |found| return found;
            }
        },
        .asm_expr => |ae| {
            if (findNodeAtOffset(ae.template, offset)) |found| return found;
            for (ae.operands) |op| {
                if (findNodeAtOffset(op.payload, offset)) |found| return found;
            }
        },
        .asm_global => |ag| {
            if (findNodeAtOffset(ag.template, offset)) |found| return found;
        },
    }

    return node;
}

/// Find the nearest match_expr ancestor that contains the given offset.
/// Returns the match subject node if found, null otherwise.
pub fn findEnclosingMatchSubject(node: *Node, offset: u32) ?*Node {
    if (offset < node.span.start or offset >= node.span.end) return null;

    switch (node.data) {
        .match_expr => |me| {
            // First recurse into arm bodies — there might be a nested match
            for (me.arms) |arm| {
                if (findEnclosingMatchSubject(arm.body, offset)) |inner| return inner;
            }
            // If offset is inside this match_expr (but not in the subject itself),
            // it's in an arm pattern, between arms, or in a partially-typed arm
            if (me.subject.span.start <= offset and offset < me.subject.span.end) {
                // Cursor is on the subject itself, not in an arm
            } else {
                return me.subject;
            }
        },
        .root => |r| {
            for (r.decls) |decl| {
                if (findEnclosingMatchSubject(decl, offset)) |found| return found;
            }
        },
        .fn_decl => |fd| {
            if (findEnclosingMatchSubject(fd.body, offset)) |found| return found;
        },
        .block => |blk| {
            for (blk.stmts) |stmt| {
                if (findEnclosingMatchSubject(stmt, offset)) |found| return found;
            }
        },
        .if_expr => |ie| {
            if (findEnclosingMatchSubject(ie.then_branch, offset)) |found| return found;
            if (ie.else_branch) |eb| {
                if (findEnclosingMatchSubject(eb, offset)) |found| return found;
            }
        },
        .while_expr => |we| {
            if (findEnclosingMatchSubject(we.body, offset)) |found| return found;
        },
        .for_expr => |fe| {
            if (findEnclosingMatchSubject(fe.body, offset)) |found| return found;
        },
        .const_decl => |cd| {
            if (findEnclosingMatchSubject(cd.value, offset)) |found| return found;
        },
        .var_decl => |vd| {
            if (vd.value) |val| {
                if (findEnclosingMatchSubject(val, offset)) |found| return found;
            }
        },
        .lambda => |lam| {
            if (findEnclosingMatchSubject(lam.body, offset)) |found| return found;
        },
        .namespace_decl => |ns| {
            for (ns.decls) |decl| {
                if (findEnclosingMatchSubject(decl, offset)) |found| return found;
            }
        },
        else => {},
    }
    return null;
}

test "sema: collect top-level declarations" {
    const parser_mod = @import("parser.zig");

    const source = "main :: () { 42; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Should have one symbol: main (function)
    try std.testing.expectEqual(@as(usize, 1), result.symbols.len);
    try std.testing.expectEqualStrings("main", result.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, result.symbols[0].kind);
}

test "sema: function params as symbols" {
    const parser_mod = @import("parser.zig");

    const source = "add :: (a: i32, b: i32) -> i32 { a + b; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Symbols: add (function), a (param), b (param)
    try std.testing.expectEqual(@as(usize, 3), result.symbols.len);
    try std.testing.expectEqualStrings("add", result.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, result.symbols[0].kind);
    try std.testing.expectEqualStrings("a", result.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.param, result.symbols[1].kind);
    try std.testing.expectEqualStrings("b", result.symbols[2].name);
    try std.testing.expectEqual(SymbolKind.param, result.symbols[2].kind);

    // References: a and b used in body should be resolved
    try std.testing.expect(result.references.len >= 2);
}

test "sema: variable declaration and reference" {
    const parser_mod = @import("parser.zig");

    const source = "main :: () { x := 42; x; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Symbols: main (function), x (variable)
    try std.testing.expectEqual(@as(usize, 2), result.symbols.len);
    try std.testing.expectEqualStrings("main", result.symbols[0].name);
    try std.testing.expectEqualStrings("x", result.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.variable, result.symbols[1].kind);

    // x should have a reference
    try std.testing.expect(result.references.len >= 1);
    // The reference should point to symbol index 1 (x)
    try std.testing.expectEqual(@as(u32, 1), result.references[0].symbol_index);
}

test "sema: undefined variable diagnostic" {
    const parser_mod = @import("parser.zig");

    const source = "main :: () { y; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Should have a diagnostic for undefined 'y'
    try std.testing.expect(result.diagnostics.len >= 1);
    try std.testing.expectEqualStrings("undefined variable", result.diagnostics[0].message);
}

test "sema: enum and struct declarations" {
    const parser_mod = @import("parser.zig");

    const source = "Color :: enum { red; green; blue; } Vec2 :: struct { x, y: f32; } main :: () { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Symbols: Color (enum), Vec2 (struct), main (function)
    try std.testing.expectEqual(@as(usize, 3), result.symbols.len);
    try std.testing.expectEqualStrings("Color", result.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.enum_type, result.symbols[0].kind);
    try std.testing.expectEqualStrings("Vec2", result.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.struct_type, result.symbols[1].kind);
    try std.testing.expectEqualStrings("main", result.symbols[2].name);
}

test "sema: var_decl infers struct type from parameterized struct literal" {
    const parser_mod = @import("parser.zig");

    const source = "List :: struct { len: i64; } main :: () { list := List.{}; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Find the 'list' variable symbol
    var found_list = false;
    for (result.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "list")) {
            found_list = true;
            try std.testing.expectEqual(SymbolKind.variable, sym.kind);
            // Must have inferred struct type
            const ty = sym.ty orelse return error.TestUnexpectedResult;
            try std.testing.expect(ty == .struct_type);
            try std.testing.expectEqualStrings("List", ty.struct_type);
            break;
        }
    }
    try std.testing.expect(found_list);
}

test "sema: var_decl infers struct type from parameterized call literal" {
    const parser_mod = @import("parser.zig");

    // List(i32).{} — parser produces struct_literal with type_expr = call node
    const source = "List :: struct { len: i64; } main :: () { list := List(i32).{}; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Find the 'list' variable symbol
    var found_list = false;
    for (result.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "list")) {
            found_list = true;
            try std.testing.expectEqual(SymbolKind.variable, sym.kind);
            const ty = sym.ty orelse return error.TestUnexpectedResult;
            try std.testing.expect(ty == .struct_type);
            try std.testing.expectEqualStrings("List", ty.struct_type);
            break;
        }
    }
    try std.testing.expect(found_list);
}

test "sema: index into generic List(T).items resolves the element struct" {
    const parser_mod = @import("parser.zig");

    const source =
        "Move :: struct { score: i64; }" ++
        "List :: struct ($T: Type) { items: [*]T = null; len: i64; }" ++
        "main :: () { legal := List(Move).{}; m := legal.items[0]; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    var found_m = false;
    for (result.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "m")) {
            found_m = true;
            const ty = sym.ty orelse return error.TestUnexpectedResult;
            try std.testing.expect(ty == .struct_type);
            try std.testing.expectEqualStrings("Move", ty.struct_type);
            break;
        }
    }
    try std.testing.expect(found_m);
}

test "sema: generic index resolves with pre-registered (imported) struct types" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // An "imported" module defining List + Move.
    const lib_src = "Move :: struct { score: i64; }" ++
        "List :: struct ($T: Type) { items: [*]T = null; len: i64; }";
    var lib_parser = parser_mod.Parser.init(alloc, lib_src);
    const lib_root = try lib_parser.parse();
    var lib = Analyzer.init(alloc);
    const lib_res = try lib.analyze(lib_root);

    // Main analyzer pre-loaded with the imported struct_types (bare names),
    // mirroring DocumentStore.analyzeDocument's flat-import merge.
    var main_an = Analyzer.init(alloc);
    var it = lib_res.struct_types.iterator();
    while (it.next()) |e| try main_an.struct_types.put(e.key_ptr.*, e.value_ptr.*);

    const main_src = "main :: () { legal := List(Move).{}; m := legal.items[0]; }";
    var main_parser = parser_mod.Parser.init(alloc, main_src);
    const main_root = try main_parser.parse();
    const main_res = try main_an.analyze(main_root);

    var found_m = false;
    for (main_res.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "m")) {
            found_m = true;
            const ty = sym.ty orelse return error.TestUnexpectedResult;
            try std.testing.expect(ty == .struct_type);
            try std.testing.expectEqualStrings("Move", ty.struct_type);
            break;
        }
    }
    try std.testing.expect(found_m);
}

test "sema: generic index resolves with realistic List/Move (methods, cross-refs)" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lib_src =
        "Square :: struct { index: i64; }" ++
        "MoveFlag :: enum { none; promote_rook; }" ++
        "Move :: struct { from: Square; to: Square; flag: MoveFlag; is_capture :: (self: Move) -> bool { true; } }" ++
        "List :: struct ($T: Type) { items: [*]T = null; len: i64 = 0; cap: i64 = 0; append :: (list: *List(T), item: T) {} }";
    var lib_parser = parser_mod.Parser.init(alloc, lib_src);
    const lib_root = try lib_parser.parse();
    var lib = Analyzer.init(alloc);
    const lib_res = try lib.analyze(lib_root);

    var main_an = Analyzer.init(alloc);
    var sit = lib_res.struct_types.iterator();
    while (sit.next()) |e| try main_an.struct_types.put(e.key_ptr.*, e.value_ptr.*);
    var eit = lib_res.enum_types.iterator();
    while (eit.next()) |e| try main_an.enum_types.put(e.key_ptr.*, e.value_ptr.*);

    const main_src = "main :: () { legal := List(Move).{}; m := legal.items[0]; f := m.from; }";
    var main_parser = parser_mod.Parser.init(alloc, main_src);
    const main_root = try main_parser.parse();
    const main_res = try main_an.analyze(main_root);

    var m_ty: ?Type = null;
    var f_ty: ?Type = null;
    for (main_res.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "m")) m_ty = sym.ty;
        if (std.mem.eql(u8, sym.name, "f")) f_ty = sym.ty;
    }
    try std.testing.expect(m_ty != null and m_ty.? == .struct_type);
    try std.testing.expectEqualStrings("Move", m_ty.?.struct_type);
    try std.testing.expect(f_ty != null and f_ty.? == .struct_type);
    try std.testing.expectEqualStrings("Square", f_ty.?.struct_type);
}

test "sema: method-return slice + .ptr index + tagged-enum element" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        "Event :: enum { none; click: i64; }" ++
        "Plat :: protocol { poll :: (self: *Self) -> []Event; }" ++
        "go :: (p: *Plat) { evs := p.poll(); e := evs.ptr[0]; }";
    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();
    var an = Analyzer.init(alloc);
    const res = try an.analyze(root);

    var evs_ty: ?Type = null;
    var e_ty: ?Type = null;
    for (res.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "evs")) evs_ty = sym.ty;
        if (std.mem.eql(u8, sym.name, "e")) e_ty = sym.ty;
    }
    // `p.poll()` resolves to its slice return type, not void.
    try std.testing.expect(evs_ty != null and evs_ty.? == .slice_type);
    try std.testing.expectEqualStrings("Event", evs_ty.?.slice_type.element_name);
    // `evs.ptr[0]` resolves to the (tagged-enum) element type.
    try std.testing.expect(e_ty != null);
    try std.testing.expectEqualStrings("Event", e_ty.?.toName().?);
}

test "sema: field access + index through a *Struct param" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        "Cell :: struct { v: i64; }" ++
        "Grid :: struct { cells: [4]Cell; }" ++
        "look :: (g: *Grid) { c := g.cells[0]; }";
    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();
    var an = Analyzer.init(alloc);
    const res = try an.analyze(root);

    var c_ty: ?Type = null;
    for (res.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "c")) c_ty = sym.ty;
    }
    try std.testing.expect(c_ty != null and c_ty.? == .struct_type);
    try std.testing.expectEqualStrings("Cell", c_ty.?.struct_type);
}

test "sema: for-loop captures resolve element, by-ref pointer, and range cursor" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        "Move :: struct { flag: i64; }" ++
        "List :: struct ($T: Type) { items: [*]T = null; len: i64 = 0; }" ++
        "Game :: struct { legal: List(Move);" ++
        "  scan :: (self: *Game) {" ++
        "    for self.legal (m) { a := m.flag; }" ++
        "    for self.legal (*p) { b := p.flag; }" ++
        "    for 0..10 (i) { c := i; }" ++
        "  } }";
    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();
    var an = Analyzer.init(alloc);
    an.source = source;
    const res = try an.analyze(root);

    var m_ty: ?Type = null;
    var p_ty: ?Type = null;
    var i_ty: ?Type = null;
    for (res.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "m")) m_ty = sym.ty;
        if (std.mem.eql(u8, sym.name, "p")) p_ty = sym.ty;
        if (std.mem.eql(u8, sym.name, "i")) i_ty = sym.ty;
    }
    // by-value capture over List(Move) yields the element struct.
    try std.testing.expect(m_ty != null and m_ty.? == .struct_type);
    try std.testing.expectEqualStrings("Move", m_ty.?.struct_type);
    // by-ref capture yields a pointer to the element.
    try std.testing.expect(p_ty != null and p_ty.? == .pointer_type);
    try std.testing.expectEqualStrings("Move", p_ty.?.pointer_type.pointee_name);
    // range cursor is i64.
    try std.testing.expect(i_ty != null and i_ty.? == .signed);
    try std.testing.expect(i_ty.?.signed == 64);

    // The typed capture lets `m.flag` / `p.flag` resolve their owner to `Move`
    // (an untyped capture would leave the owner blank — a wildcard that quietly
    // over-matches in find-references).
    var value_owner_ok = false;
    var ref_owner_ok = false;
    for (res.member_refs) |mr| {
        if (mr.is_def or !std.mem.eql(u8, mr.name, "flag")) continue;
        if (!std.mem.eql(u8, mr.owner, "Move")) continue;
        if (offsetIn(source, mr.span, "m.flag")) value_owner_ok = true;
        if (offsetIn(source, mr.span, "p.flag")) ref_owner_ok = true;
    }
    try std.testing.expect(value_owner_ok);
    try std.testing.expect(ref_owner_ok);
}

/// True when `span` falls inside the first occurrence of `needle` in `source`.
fn offsetIn(source: []const u8, span: ast.Span, needle: []const u8) bool {
    const at = std.mem.indexOf(u8, source, needle) orelse return false;
    return span.start >= at and span.start < at + needle.len;
}

test "sema: passing *T where a T value is expected is diagnosed" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        "Move :: struct { flag: i64; }" ++
        "take :: (m: Move) -> i64 { m.flag; }" ++
        "take_ptr :: (m: *Move) -> i64 { m.flag; }" ++
        "bad :: (p: *Move) -> i64 { take(p); }" ++ // *Move into a Move param → flagged
        "good :: (p: *Move) -> i64 { take_ptr(p); }"; // *Move into a *Move param → fine
    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();
    var an = Analyzer.init(alloc);
    an.source = source;
    const res = try an.analyze(root);

    var mismatch_count: usize = 0;
    for (res.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "expected here") != null) mismatch_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), mismatch_count);
}

test "sema: member references record fields, methods, and enum variants" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        "Color :: enum { red; green; }" ++
        "P :: struct { x: i64; m :: (self: P) -> i64 { self.x; } }" ++
        "use :: (p: *P) { a := p.x; b := p.m(); c := Color.red; }";
    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();
    var an = Analyzer.init(alloc);
    an.source = source;
    const res = try an.analyze(root);

    var x_use = false;
    var m_use = false;
    var red_use = false;
    for (res.member_refs) |mr| {
        if (mr.is_def) continue;
        if (std.mem.eql(u8, mr.name, "x") and std.mem.eql(u8, mr.owner, "P")) x_use = true;
        if (std.mem.eql(u8, mr.name, "m") and std.mem.eql(u8, mr.owner, "P")) m_use = true;
        if (std.mem.eql(u8, mr.name, "red") and std.mem.eql(u8, mr.owner, "Color")) red_use = true;
    }
    try std.testing.expect(x_use);
    try std.testing.expect(m_use);
    try std.testing.expect(red_use);
}

test "sema: context in an abi(.c) function reports a specific diagnostic" {
    const parser_mod = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        "Context :: struct { allocator: i64; data: i64; }" ++
        "cb :: () -> i64 abi(.c) { context; 0; }" ++
        "ok :: () -> i64 { context; 0; }";
    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();
    var an = Analyzer.init(alloc);
    an.source = source;
    const res = try an.analyze(root);

    var c_conv_diag = false;
    var undefined_diag = false;
    for (res.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "abi(.c)") != null) c_conv_diag = true;
        if (std.mem.indexOf(u8, d.message, "undefined") != null) undefined_diag = true;
    }
    try std.testing.expect(c_conv_diag); // `cb` accesses context under the C ABI
    try std.testing.expect(!undefined_diag); // `ok`'s context resolves cleanly
}

test "sema: variable shadowing in same scope is allowed" {
    const parser_mod = @import("parser.zig");

    // Two variables with the same name in the same function body — sx allows this
    const source = "main :: () { x : i64 = 1; x : f64 = 2.0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // Should have NO diagnostics — variable shadowing is allowed
    for (result.diagnostics) |d| {
        if (std.mem.eql(u8, d.message, "duplicate declaration")) {
            return error.TestUnexpectedResult;
        }
    }
}

test "sema: ufcs_alias registers symbol" {
    const parser_mod = @import("parser.zig");

    const source = "add :: (a: i64, b: i64) -> i64 { a + b; } main :: () { sum :: ufcs add; sum(1, 2); }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // `sum` should be registered as a symbol — no "undefined variable" diagnostic
    for (result.diagnostics) |d| {
        if (std.mem.eql(u8, d.message, "undefined variable")) {
            return error.TestUnexpectedResult;
        }
    }

    // Should find `sum` in symbols
    var found_sum = false;
    for (result.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "sum")) {
            found_sum = true;
            try std.testing.expectEqual(SymbolKind.function, sym.kind);
            break;
        }
    }
    try std.testing.expect(found_sum);
}

test "sema: top-level ufcs_alias registers symbol" {
    const parser_mod = @import("parser.zig");

    const source = "add :: (a: i64, b: i64) -> i64 { a + b; } sum :: ufcs add;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = parser_mod.Parser.init(alloc, source);
    const root = try parser.parse();

    var analyzer = Analyzer.init(alloc);
    const result = try analyzer.analyze(root);

    // No diagnostics
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    // Should find `sum` as function symbol
    var found_sum = false;
    for (result.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "sum")) {
            found_sum = true;
            try std.testing.expectEqual(SymbolKind.function, sym.kind);
            break;
        }
    }
    try std.testing.expect(found_sum);
}
