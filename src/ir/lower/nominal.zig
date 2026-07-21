const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const mod_mod = @import("../module.zig");
const type_bridge = @import("../type_bridge.zig");
const program_index_mod = @import("../program_index.zig");
const resolver_mod = @import("../resolver.zig");
const StructTemplate = program_index_mod.StructTemplate;
const TemplateParam = program_index_mod.TemplateParam;

const TypeId = types.TypeId;
const StringId = types.StringId;
const Module = mod_mod.Module;
const FuncId = @import("../inst.zig").FuncId;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const VisibleStructAuthor = Lowering.VisibleStructAuthor;
const structDeclOfRaw = Lowering.structDeclOfRaw;

/// A method selected from the concrete plain-struct TypeId's nominal author.
/// `source` is retained with the declaration so signatures and bodies resolve
/// in the module that authored the layout.
pub const PlainStructMethod = struct {
    fd: *const ast.FnDecl,
    owner_ty: TypeId,
    source: ?[]const u8,
};

/// Source-aware result for a static type head (`Thing.make` / `ns.Thing.make`).
/// Ambiguity and visibility are kept distinct so lowering can preserve the
/// existing loud diagnostics while inference remains side-effect-free.
pub const StaticStructHead = union(enum) {
    resolved: TypeId,
    ambiguous,
    not_visible,
    none,
};

fn staticHeadInSource(self: *Lowering, name: []const u8, source: ?[]const u8) StaticStructHead {
    const from = source orelse {
        const sid = self.module.types.internString(name);
        return if (self.module.types.findByName(sid)) |ty| .{ .resolved = ty } else .none;
    };
    return switch (self.selectNominalLeaf(name, from, false)) {
        .resolved => |ty| .{ .resolved = ty },
        .ambiguous => .ambiguous,
        // A privately-authored-elsewhere head is exactly as unreachable as a
        // namespaced-only one for static-call purposes.
        .not_visible, .private_elsewhere => .not_visible,
        .pending, .forward, .undeclared => .none,
    };
}

/// Resolve the nominal TypeId named by a static-call head without emitting a
/// diagnostic. A namespace-qualified head is resolved from the namespace's
/// target module, so `a.Thing.make()` selects a's `Thing` even when another
/// namespace also declares `Thing`.
pub fn staticStructHead(self: *Lowering, node: *const Node) StaticStructHead {
    return switch (node.data) {
        .identifier => |id| switch (self.namespaceAliasVerdict(id.name)) {
            // A visible namespace alias owns `pkg.member`; do not let an
            // unrelated hidden type named `pkg` hijack that domain. The
            // namespace-call gate diagnoses an ambiguous alias itself.
            .target, .ambiguous => .none,
            .none => staticHeadInSource(self, id.name, self.current_source_file),
        },
        .type_expr => |te| blk: {
            if (std.mem.indexOfScalar(u8, te.name, '.') != null) {
                switch (self.qualifiedMemberVerdict(te.name)) {
                    .selected => |sel| break :blk staticHeadInSource(self, sel.member, sel.target.target_module_path),
                    .ambiguous => break :blk .ambiguous,
                    .missing => break :blk .none,
                    .not_qualified => {},
                }
            }
            break :blk staticHeadInSource(self, te.name, self.current_source_file);
        },
        .field_access => blk: {
            const path = self.qualifiedTypeName(node) orelse break :blk .none;
            defer self.alloc.free(path);
            break :blk switch (self.qualifiedMemberVerdict(path)) {
                .selected => |sel| staticHeadInSource(self, sel.member, sel.target.target_module_path),
                .ambiguous => .ambiguous,
                .not_qualified, .missing => .none,
            };
        },
        else => .none,
    };
}

/// Select a method owned by the concrete nominal `ty`: first an inline method
/// from the struct declaration, then a uniquely matching nullary-protocol impl
/// method. Pointer receivers are dereferenced once, matching
/// `getStructTypeName` and the call dispatch path. Generic-struct instances use
/// their separate author stamp and therefore intentionally do not appear in
/// this map.
fn plainStructOwnerType(self: *Lowering, ty: TypeId) TypeId {
    var owner_ty = ty;
    if (!owner_ty.isBuiltin()) {
        const info = self.module.types.get(owner_ty);
        if (info == .pointer) owner_ty = info.pointer.pointee;
    }
    return owner_ty;
}

/// Whether `ty` is a concrete plain struct whose declaration provenance is
/// known. Once this is true, a missing method is authoritative: callers must
/// not consult the lossy global `StructName.method` compatibility map, where a
/// different module's same-display-name struct may have registered that name.
pub fn hasPlainStructAuthor(self: *Lowering, ty: TypeId) bool {
    return self.plain_struct_authors.contains(plainStructOwnerType(self, ty));
}

fn selectPlainStructMethod(self: *Lowering, ty: TypeId, method: []const u8, include_protocol_defaults: bool) ?PlainStructMethod {
    const owner_ty = plainStructOwnerType(self, ty);
    const author = self.plain_struct_authors.get(owner_ty) orelse return null;
    if (Lowering.structMethodFn(author.decl, method)) |fd| {
        return .{ .fd = fd, .owner_ty = owner_ty, .source = author.source };
    }

    // `impl P for Thing` methods historically also live in the flat
    // `Thing.method` compatibility namespace. Select them by concrete TypeId
    // before consulting that lossy name map, otherwise two modules' distinct
    // `Thing` impls cross-bind. If one concrete type supplies the same method
    // through multiple protocols, retain the legacy path rather than silently
    // choosing between genuinely distinct implementations.
    const method_id = self.module.types.internString(method);
    var selected: ?PlainStructMethod = null;
    var it = self.protocol_impl_methods.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.concrete != owner_ty or entry.key_ptr.method != method_id) continue;
        if (!include_protocol_defaults and entry.value_ptr.is_synthesized_default) continue;
        const candidate: PlainStructMethod = .{
            .fd = entry.value_ptr.fd,
            .owner_ty = owner_ty,
            .source = entry.value_ptr.source,
        };
        if (selected) |prior| {
            if (prior.fd != candidate.fd) return null;
        } else {
            selected = candidate;
        }
    }
    return selected;
}

pub fn plainStructMethod(self: *Lowering, ty: TypeId, method: []const u8) ?PlainStructMethod {
    const owner_ty = plainStructOwnerType(self, ty);
    if (self.protocol_default_dispatch) |domain| {
        if (domain.concrete == owner_ty) {
            // Inside a synthesized default, calls on `self` belong to that
            // exact protocol impl before they belong to the concrete type's
            // inherent namespace. This is deliberately scoped by
            // `lowerFunctionBodyInto`; ordinary and explicit impl bodies see
            // `protocol_default_dispatch == null` and retain inherent-first
            // lookup. `protocolDispatchMethod` is identity-keyed and its
            // adoption path excludes foreign synthesized defaults.
            const protocol_name = self.module.types.getString(domain.protocol_name);
            if (self.protocolResolver().protocolDispatchMethod(domain.protocol, protocol_name, owner_ty, method)) |impl_method| {
                return .{
                    .fd = impl_method.fd,
                    .owner_ty = owner_ty,
                    .source = impl_method.source,
                };
            }
        }
    }
    return selectPlainStructMethod(self, ty, method, true);
}

/// Method body eligible for adoption by an explicit empty/partial protocol
/// impl. A synthesized default belongs only to its declaring protocol and must
/// never satisfy another protocol's required method.
pub fn plainStructAdoptableMethod(self: *Lowering, ty: TypeId, method: []const u8) ?PlainStructMethod {
    return selectPlainStructMethod(self, ty, method, false);
}

/// Internal dispatch key for a selected plain-struct method. The first/single
/// author preserves the historical `Name.method` key. A shadow author includes
/// its nominal id so independently monomorphized generic methods cannot collide;
/// this key is compiler-internal and does not alter SX spelling.
pub fn plainStructMethodName(self: *Lowering, method: PlainStructMethod) []const u8 {
    const info = self.module.types.get(method.owner_ty);
    if (info != .@"struct") return method.fd.name;
    const s = info.@"struct";
    const name = self.module.types.getString(s.name);
    const eff = self.accessorEffName(method.fd);
    if (s.nominal_id == 0)
        return std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ name, eff }) catch @panic("out of memory");
    // `$` is not legal inside a user identifier, so this internal segment
    // cannot collide with a real source-level struct such as `Thing__n1`.
    return std.fmt.allocPrint(self.alloc, "{s}$nominal{d}.{s}", .{ name, s.nominal_id, eff }) catch @panic("out of memory");
}

/// Author source for signature/body resolution. A selected nominal method with
/// no source would make caller-context fallback silently bind unrelated names;
/// treat that as an internal invariant violation instead.
pub fn plainStructMethodSource(method: PlainStructMethod) []const u8 {
    return method.source orelse method.fd.body.source_file orelse
        std.debug.panic("plain struct method '{s}' has no author source", .{method.fd.name});
}

/// Materialize the selected declaration into its identity-addressed FuncId.
/// Lowering directly into the slot registered for this AST declaration keeps
/// a same-named method from being lowered into another author's function.
pub fn ensurePlainStructMethodLowered(self: *Lowering, method: PlainStructMethod) FuncId {
    const name = self.plainStructMethodName(method);
    const fid = self.fn_decl_fids.get(method.fd) orelse
        std.debug.panic("plain struct method '{s}' has no decl-identity function slot", .{method.fd.name});
    if (!self.lowered_fids.contains(fid)) {
        self.lowered_fids.put(fid, {}) catch @panic("out of memory");
        self.lowerFunctionBodyInto(method.fd, fid, name);
    }
    return fid;
}

/// Register a struct declaration's fields and methods in the IR type table.
/// Register a `Foo :: error { A, B }` declaration as an error-set type.
/// Rejects an empty set here (sema gate) since type_bridge has no
/// diagnostics; non-empty sets are interned via type_bridge.
pub fn registerErrorSetDecl(self: *Lowering, node: *const Node) void {
    const esd = node.data.error_set_decl;
    if (esd.tag_names.len == 0) {
        if (self.diagnostics) |diags| {
            diags.addFmt(.err, node.span, "error set '{s}' must declare at least one tag", .{esd.name});
        }
        return;
    }
    // Per-decl nominal identity (E6a) — the error-set twin of `registerEnumDecl`.
    // A GENUINE same-name shadow already reserved its DISTINCT slot up-front in
    // `scanDecls` (the first at id 0, the rest at nonzero ids): reuse that id. A
    // single-author name keeps id 0 and the legacy registration. The body is built
    // by the shared `type_bridge.buildErrorSetInfo`; `internNamedTypeDecl` interns
    // it under the computed nominal id and records `decl_key → TypeId` so a local
    // `Foo :: error { Boom }` no longer collapses onto a same-name imported set
    // (issue 0134).
    const table = &self.module.types;
    const name_id = table.internString(esd.name);
    const decl_key: *const anyopaque = @ptrCast(&node.data.error_set_decl);
    const nominal_id: u32 = if (table.type_decl_tids.get(decl_key)) |id| nominalIdOf(table.get(id)) else self.shadowNominalId(name_id);
    const info = type_bridge.buildErrorSetInfo(&node.data.error_set_decl, table);
    _ = self.internNamedTypeDecl(decl_key, name_id, info, nominal_id);
}

/// The `nominal_id` stamped on a nominal `TypeInfo` (0 for non-nominal /
/// structural). Reading it back lets a re-registration preserve the slot's
/// existing key when refreshing a forward-stubbed body.
pub fn nominalIdOf(info: types.TypeInfo) u32 {
    return switch (info) {
        .@"struct" => |s| s.nominal_id,
        .@"enum" => |e| e.nominal_id,
        .@"union" => |u| u.nominal_id,
        .tagged_union => |u| u.nominal_id,
        .error_set => |e| e.nominal_id,
        else => 0,
    };
}

/// Return `info` with its nominal arm's `nominal_id` set to `nid` (a no-op for
/// non-nominal infos). Used to build the key-matching body for
/// `updatePreservingKey` after a shadow author interned at a nonzero id.
pub fn stampNominalId(info: types.TypeInfo, nid: u32) types.TypeInfo {
    var out = info;
    switch (out) {
        .@"struct" => |*s| s.nominal_id = nid,
        .@"enum" => |*e| e.nominal_id = nid,
        .@"union" => |*u| u.nominal_id = nid,
        .tagged_union => |*u| u.nominal_id = nid,
        .error_set => |*e| e.nominal_id = nid,
        else => {},
    }
    return out;
}

/// Reserve a GENUINE same-name STRUCT shadow author's DISTINCT nominal slot
/// BEFORE any field resolves, so a self / forward / mutual reference to a shadow
/// name (`next: *Box`; `peer: *Node` where Node is a shadow declared later)
/// binds to ITS nominal TypeId via `type_decl_tids` instead of the global
/// findByName first-author fallback. Called only from the
/// `scanDecls` genuine-shadow pass, which has already established that ≥2
/// distinct struct decls author this name; ALL of them reserve — the FIRST at
/// id 0, the rest at fresh nonzero ids — so none falls through to the name-only
/// `findByName` (which, once a shadow is interned, no longer uniquely identifies
/// the first author). Idempotent per decl key: an already-reserved decl returns
/// before re-invoking `shadowNominalId`, so the shadow id is computed once.
/// Generic templates resolve lazily on instantiation and are skipped.
pub fn reserveShadowStructSlot(self: *Lowering, sd: *const ast.StructDecl) void {
    if (sd.type_params.len > 0) return;
    const table = &self.module.types;
    const decl_key: *const anyopaque = @ptrCast(sd);
    if (table.type_decl_tids.contains(decl_key)) return;
    const name_id = table.internString(sd.name);
    const nominal_id = self.shadowNominalId(name_id); // 0 for the first author, nonzero for the rest
    const reserved = table.internNominal(.{ .@"struct" = .{ .name = name_id, .fields = &.{} } }, nominal_id);
    table.type_decl_tids.put(decl_key, reserved) catch {};
}

/// Reserve a GENUINE same-name ENUM shadow author's DISTINCT nominal slot
/// up-front — the enum twin of `reserveShadowStructSlot` (E6a). The reserved
/// slot's KIND MUST match what `buildEnumInfo` will produce (a payload enum →
/// `.tagged_union`, a payload-less enum → `.enum`), because `internNamedTypeDecl`
/// later refreshes the body via `updatePreservingKey`, whose key-stability
/// assert compares the FULL info tag — a struct/enum/tagged_union mismatch would
/// trip it. The empty body and placeholder `tag_type` are not part of the intern
/// key (name + nominal id only), so the real body fills in freely.
pub fn reserveShadowEnumSlot(self: *Lowering, ed: *const ast.EnumDecl) void {
    const table = &self.module.types;
    const decl_key: *const anyopaque = @ptrCast(ed);
    if (table.type_decl_tids.contains(decl_key)) return;
    const name_id = table.internString(ed.name);
    const nominal_id = self.shadowNominalId(name_id);
    const empty: types.TypeInfo = if (ed.variant_types.len > 0)
        .{ .tagged_union = .{ .name = name_id, .fields = &.{}, .tag_type = .i64 } }
    else
        .{ .@"enum" = .{ .name = name_id, .variants = &.{} } };
    const reserved = table.internNominal(empty, nominal_id);
    table.type_decl_tids.put(decl_key, reserved) catch {};
}

/// Reserve a GENUINE same-name UNION shadow author's DISTINCT nominal slot
/// up-front — the union twin of `reserveShadowStructSlot` (E6a).
pub fn reserveShadowUnionSlot(self: *Lowering, ud: *const ast.UnionDecl) void {
    const table = &self.module.types;
    const decl_key: *const anyopaque = @ptrCast(ud);
    if (table.type_decl_tids.contains(decl_key)) return;
    const name_id = table.internString(ud.name);
    const nominal_id = self.shadowNominalId(name_id);
    const reserved = table.internNominal(.{ .@"union" = .{ .name = name_id, .fields = &.{} } }, nominal_id);
    table.type_decl_tids.put(decl_key, reserved) catch {};
}

/// Reserve a GENUINE same-name ERROR-SET shadow author's DISTINCT nominal slot
/// up-front — the error-set twin of `reserveShadowStructSlot` (E6a). The reserved
/// slot is an empty `.error_set` (its body — the tag id list — is not part of the
/// intern key, only name + nominal id), so `internNamedTypeDecl` later fills the
/// real tags via `updatePreservingKey`. Without this, a local `Foo :: error { ... }`
/// declared after a same-name imported set would collapse onto the imported
/// TypeId via the `findByName` first-author fallback (issue 0134).
pub fn reserveShadowErrorSetSlot(self: *Lowering, esd: *const ast.ErrorSetDecl) void {
    const table = &self.module.types;
    const decl_key: *const anyopaque = @ptrCast(esd);
    if (table.type_decl_tids.contains(decl_key)) return;
    const name_id = table.internString(esd.name);
    const nominal_id = self.shadowNominalId(name_id);
    const reserved = table.internNominal(.{ .error_set = .{ .name = name_id, .tags = &.{} } }, nominal_id);
    table.type_decl_tids.put(decl_key, reserved) catch {};
}

/// Reserve a nullary protocol shadow as the protocol-backed struct slot that
/// `registerProtocolDecl` will later fill. Parameterized protocols are
/// compile-time templates and deliberately have no runtime TypeId.
pub fn reserveShadowProtocolSlot(self: *Lowering, pd: *const ast.ProtocolDecl) void {
    if (pd.type_params.len > 0) return;
    const table = &self.module.types;
    const decl_key: *const anyopaque = @ptrCast(pd);
    if (table.type_decl_tids.contains(decl_key)) return;
    const name_id = table.internString(pd.name);
    const nominal_id = self.shadowNominalId(name_id);
    const reserved = table.internNominal(.{ .@"struct" = .{
        .name = name_id,
        .fields = &.{},
        .is_protocol = true,
    } }, nominal_id);
    table.type_decl_tids.put(decl_key, reserved) catch {};
}

/// A top-level NAMED type decl the genuine-shadow scan tracks, KIND-tagged so
/// same-name authors of DIFFERENT kinds (a `struct Foo` and an `enum Foo`) are
/// NOT mistaken for one shadow group. Carries the stable decl pointer (the
/// `decl_key` / raw-facts identity) so the scan de-dups by decl identity, and
/// dispatches the per-kind reservation. Later E6 sub-steps add their kind here.
const ShadowTypeDecl = union(enum) {
    @"struct": *const ast.StructDecl,
    @"enum": *const ast.EnumDecl,
    @"union": *const ast.UnionDecl,
    error_set: *const ast.ErrorSetDecl,
    protocol: *const ast.ProtocolDecl,

    pub fn key(self: ShadowTypeDecl) *const anyopaque {
        return switch (self) {
            inline else => |p| @ptrCast(p),
        };
    }
    pub fn name(self: ShadowTypeDecl) []const u8 {
        return switch (self) {
            inline else => |p| p.name,
        };
    }
    pub fn isGeneric(self: ShadowTypeDecl) bool {
        return switch (self) {
            .@"struct" => |p| p.type_params.len > 0,
            .protocol => |p| p.type_params.len > 0,
            else => false,
        };
    }
};

/// Classify a top-level node as the NAMED type decl it authors — a bare
/// `struct`/`enum`/`union` node, or a `const_decl` whose value is one — so the
/// genuine-shadow scan enumerates all three kinds uniformly. Null when the node
/// is not a struct/enum/union author. The shared infra E6b/E6c extend by adding
/// their kind here.
pub fn topLevelTypeDecl(decl: *const Node) ?ShadowTypeDecl {
    return switch (decl.data) {
        .struct_decl => .{ .@"struct" = &decl.data.struct_decl },
        .enum_decl => .{ .@"enum" = &decl.data.enum_decl },
        .union_decl => .{ .@"union" = &decl.data.union_decl },
        .error_set_decl => .{ .error_set = &decl.data.error_set_decl },
        .protocol_decl => .{ .protocol = &decl.data.protocol_decl },
        .const_decl => |cd| switch (cd.value.data) {
            .struct_decl => .{ .@"struct" = &cd.value.data.struct_decl },
            .enum_decl => .{ .@"enum" = &cd.value.data.enum_decl },
            .union_decl => .{ .@"union" = &cd.value.data.union_decl },
            .error_set_decl => .{ .error_set = &cd.value.data.error_set_decl },
            else => null,
        },
        else => null,
    };
}

/// Dispatch a genuine-shadow reservation to the matching per-kind reserver.
pub fn reserveShadowSlot(self: *Lowering, td: ShadowTypeDecl) void {
    switch (td) {
        .@"struct" => |sd| self.reserveShadowStructSlot(sd),
        .@"enum" => |ed| self.reserveShadowEnumSlot(ed),
        .@"union" => |ud| self.reserveShadowUnionSlot(ud),
        .error_set => |esd| self.reserveShadowErrorSetSlot(esd),
        .protocol => |pd| self.reserveShadowProtocolSlot(pd),
    }
}

/// Register (or re-register) a top-level NAMED type decl under a per-source
/// nominal identity (E2), returning its TypeId. `decl_key` is the decl's
/// stable pointer (the import raw-facts identity); `info` carries the full
/// body; `nominal_id` is the slot's identity (0 for a single / first author,
/// nonzero for a later same-name shadow) — computed once by the caller
/// (`registerStructDecl`), which reuses the id reserved up-front in `scanDecls`
/// for a genuine shadow (so its fields' self / forward / mutual refs already
/// resolved against it). This stamps the id and records the `decl_key → TypeId`
/// map (`type_decl_tids`, the `fn_decl_fids` analogue).
///
/// A `nominal_id == 0` author adopts any forward-reference stub (`findByName`
/// orelse intern) — BYTE-IDENTICAL to pre-E2 registration. For a genuinely
/// multi-authored name, the FIRST source keeps id 0 and later sources get
/// fresh ids → DISTINCT TypeIds, so the authors no longer collapse last-wins
///. Idempotent per `decl_key`: a re-registration — OR an up-front
/// shadow reservation — reuses the recorded slot, refreshing its body via
/// `updatePreservingKey` (key-stable because a struct's intern key is its
/// name + nominal id, not its fields).
pub fn internNamedTypeDecl(self: *Lowering, decl_key: *const anyopaque, name_id: types.StringId, info: types.TypeInfo, nominal_id: u32) TypeId {
    const table = &self.module.types;
    // Slot already recorded (re-registration, or a reserve-before-fields shadow
    // reservation) → reuse its slot + nominal id, refresh the body.
    if (table.type_decl_tids.get(decl_key)) |existing_id| {
        table.updatePreservingKey(existing_id, stampNominalId(info, nominalIdOf(table.get(existing_id))));
        return existing_id;
    }
    const id = if (nominal_id == 0)
        (table.findByName(name_id) orelse table.internNominal(info, 0))
    else
        table.internNominal(info, nominal_id);
    const stamped = stampNominalId(info, nominal_id);
    // A self / mutual `*Name` field in an enum/union body — or a fn signature
    // referencing an error set declared later (issue 0211) — forward-creates a
    // STRUCT placeholder under `Name` (the stateless resolver has no kind
    // context — `type_resolver.resolveNamed` always stubs a struct), which the
    // `findByName` above then returns. Adopting a wrong-kind stub needs a
    // re-key, NOT the in-place `updatePreservingKey` body-fill — whose
    // kind-stability assert trips on struct→enum/union/error_set.
    if (adoptsForwardStructStub(table.get(id), stamped))
        table.replaceKeyedInfo(id, stamped)
    else
        table.updatePreservingKey(id, stamped);
    table.type_decl_tids.put(decl_key, id) catch {};
    return id;
}

/// TRUE when `existing` is a forward-reference STRUCT placeholder (empty
/// fields — the stateless resolver's stub for an as-yet-unregistered name) and
/// `incoming` is a NON-struct nominal (enum / union / tagged_union /
/// error_set): the one case where `internNamedTypeDecl` must re-key the slot
/// rather than fill its body in place. A struct adopting its own struct stub
/// is same-kind and stays on `updatePreservingKey`; a fresh-interned slot has
/// no stub to adopt.
pub fn adoptsForwardStructStub(existing: types.TypeInfo, incoming: types.TypeInfo) bool {
    if (existing != .@"struct" or existing.@"struct".fields.len != 0) return false;
    return switch (incoming) {
        .@"enum", .@"union", .tagged_union, .error_set => true,
        else => false,
    };
}

/// The `nominal_id` to register a NAMED type author of `name_id` under. 0
/// unless `name_id` is authored as a named type by ≥2 distinct modules (a real
/// same-name shadow per the import facts): the FIRST source to register keeps
/// 0, each later source gets a fresh monotonic id. Gating on the import facts
/// keeps the single-author path at id 0 (byte-identical) even when one logical
/// type is re-registered from several `current_source_file` contexts.
pub fn shadowNominalId(self: *Lowering, name_id: types.StringId) u32 {
    if (!self.nameHasMultipleTypeAuthors(self.module.types.getString(name_id))) return 0;
    const src = self.current_source_file orelse self.main_file orelse "";
    const gop = self.nominal_name_authors.getOrPut(name_id) catch return 0;
    if (!gop.found_existing) {
        gop.value_ptr.* = src;
        return 0;
    }
    if (std.mem.eql(u8, gop.value_ptr.*, src)) return 0;
    self.next_nominal_id += 1;
    return self.next_nominal_id;
}

/// TRUE iff `name` is authored AS A NAMED TYPE (struct / enum / union /
/// error-set / protocol / runtime class) by ≥2 DISTINCT modules in the import
/// raw facts — the authoritative same-name-shadow signal (the only case where
/// distinct `nominal_id`s are needed). Module distinctness is by LEXICALLY
/// NORMALIZED path: one logical file reached through several spellings
/// (`testpkg/../allocators.sx` vs `allocators.sx`) is cached — and so parsed —
/// twice, landing two `module_decls` entries with two decl pointers for the
/// SAME source; normalizing collapses them to one author, NOT a false shadow.
/// False when the facts are unwired (comptime / registration host with no
/// `module_decls`): the single-author path applies, correct there.
pub fn nameHasMultipleTypeAuthors(self: *Lowering, name: []const u8) bool {
    const decls = self.program_index.module_decls orelse return false;
    var first_norm: ?[]const u8 = null;
    defer if (first_norm) |f| self.alloc.free(f);
    var it = decls.iterator();
    while (it.next()) |entry| {
        const m = entry.value_ptr;
        const ref = m.names.get(name) orelse continue;
        if (rawNamedTypePtr(ref) == null) continue;
        const norm = std.fs.path.resolvePosix(self.alloc, &.{entry.key_ptr.*}) catch continue;
        if (first_norm) |f| {
            defer self.alloc.free(norm);
            if (!std.mem.eql(u8, f, norm)) return true;
        } else {
            first_norm = norm;
        }
    }
    return false;
}

/// The opaque decl-pointer identity of a NAMED-type `RawDeclRef`, or null when
/// the ref is not a named type (fn / value-const / namespace alias). Used to
/// de-dup same-name authors by decl identity.
pub fn rawNamedTypePtr(ref: resolver_mod.RawDeclRef) ?*const anyopaque {
    return switch (ref) {
        .struct_decl => |d| @ptrCast(d),
        .enum_decl => |d| @ptrCast(d),
        .union_decl => |d| @ptrCast(d),
        .error_set_decl => |d| @ptrCast(d),
        .protocol_decl => |d| @ptrCast(d),
        .runtime_class_decl => |d| @ptrCast(d),
        .fn_decl, .const_decl, .var_decl, .namespace_decl => null,
    };
}

/// Build an owned generic-struct template (type params, field names, field
/// type nodes) for `sd`, pinned to its declaring `source_file`. The returned
/// template is heap-owned via `self.alloc`; callers register it under a bare
/// or namespace-qualified key. Null on OOM.
pub fn buildGenericStructTemplate(self: *Lowering, sd: *const ast.StructDecl, source_file: ?[]const u8) ?StructTemplate {
    // Main-file top-level AST nodes are deliberately unstamped. Preserve the
    // declaration's real lookup authority instead of leaving a null template
    // to inherit an unrelated instantiation/facade context (issue 0328).
    const author_source = source_file orelse self.current_source_file orelse self.main_file;
    const owned_name = self.alloc.dupe(u8, sd.name) catch return null;

    const tps = self.alloc.alloc(TemplateParam, sd.type_params.len) catch return null;
    for (sd.type_params, 0..) |tp, i| {
        const is_type_param = tp.is_variadic or (if (tp.constraint.data == .type_expr) blk: {
            const cname = tp.constraint.data.type_expr.name;
            // "Type" or a protocol name → type param
            break :blk std.mem.eql(u8, cname, "Type") or
                self.isProtocolConstraint(cname, author_source);
        } else false);
        tps[i] = .{
            .name = self.alloc.dupe(u8, tp.name) catch return null,
            // $T: Type, $T: Lerpable, $T: Type/Eq — all are type params.
            // `..$Ts: []Type` (variadic) is a type-pack param. Only value
            // params like $N: u32 are non-type.
            .is_type_param = is_type_param,
            .is_variadic = tp.is_variadic,
            // Capture a value param's declared type name (`$K: u32` →
            // "u32") so instantiation can range-check the folded arg.
            .value_type = if (!is_type_param and tp.constraint.data == .type_expr)
                (self.alloc.dupe(u8, tp.constraint.data.type_expr.name) catch null)
            else
                null,
        };
    }

    const fnames = self.alloc.alloc([]const u8, sd.field_names.len) catch return null;
    for (sd.field_names, 0..) |fn_str, i| {
        fnames[i] = self.alloc.dupe(u8, fn_str) catch return null;
    }

    // Field type nodes are *Node pointers into the AST; copy the slice of
    // pointers (the nodes themselves are heap-allocated).
    const ftype_nodes = self.alloc.dupe(*const Node, sd.field_types) catch return null;

    return .{
        .name = owned_name,
        .type_params = tps,
        .field_names = fnames,
        .field_type_nodes = ftype_nodes,
        .source_file = author_source,
        .decl = sd,
    };
}

/// Select the generic struct template AUTHORED by namespace `alias`'s target
/// module (the `importer → alias → NamespaceTarget` edge), not the bare
/// last-wins `struct_template_map`. A qualified head `ns.Box(..)` must
/// instantiate ns's OWN `Box`, even when another module's same-name `Box` won
/// the bare map. Null when the alias is unknown in the current source or its
/// module authors no such generic struct — the caller then falls back to the
/// legacy bare lookup.
pub fn qualifiedStructTemplate(self: *Lowering, alias: []const u8, member: []const u8) ?StructTemplate {
    const target = self.namespaceAliasTarget(alias, null) orelse return null;
    for (target.own_decls) |decl| {
        // A top-level struct is authored either as a bare `struct_decl` node
        // or a `const_decl` whose value is one (`Box :: struct($T){...}`).
        const sd: *const ast.StructDecl = switch (decl.data) {
            .struct_decl => |*s| s,
            .const_decl => |cd| if (cd.value.data == .struct_decl) &cd.value.data.struct_decl else continue,
            else => continue,
        };
        if (!std.mem.eql(u8, sd.name, member)) continue;
        if (sd.type_params.len == 0) continue;
        return self.buildGenericStructTemplate(sd, decl.source_file orelse target.target_module_path);
    }
    return null;
}

/// TRUE iff `alias` is a KNOWN namespace in the current source but its target
/// module authors NO member named `member` at all. A qualified generic head
/// `a.Box(..)` whose namespace lacks `Box` must diagnose the missing member —
/// never silently fall back to the bare last-wins `struct_template_map` (which
/// would instantiate an unrelated module's same-name `Box`, E4 finding #2).
/// FALSE when `alias` is not a namespace at all (leave the caller's existing
/// non-namespace handling), or when the namespace DOES author `member` (a
/// generic struct → `qualifiedStructTemplate` already selected it; any other
/// kind → the type-fn / named-type arms handle it).
pub fn qualifiedMemberMissing(self: *Lowering, alias: []const u8, member: []const u8) bool {
    const target = self.namespaceAliasTarget(alias, null) orelse return false;
    for (target.own_decls) |decl| {
        const dn = decl.data.declName() orelse continue;
        if (std.mem.eql(u8, dn, member)) return false;
    }
    return true;
}

/// The `*ConstDecl` a raw author wraps when it is a const ALIAS of another
/// name — `BoxAlias :: Box;` (identifier RHS) or `Box :: r.Box;` (namespace-
/// member RHS). Null for every other shape, including const-wrapped struct /
/// fn DEFINITIONS, which are authors in their own right.
fn constAliasOfRaw(ref: resolver_mod.RawDeclRef) ?*const ast.ConstDecl {
    return switch (ref) {
        .const_decl => |cd| switch (cd.value.data) {
            .identifier, .field_access => cd,
            else => null,
        },
        else => null,
    };
}

/// The single author of `name` as seen from `from` — own wins, else exactly
/// one flat-import author. Null when absent or when ≥2 flat authors compete
/// (the use site then diagnoses the unresolved head; no silent pick).
fn singleVisibleAuthor(self: *Lowering, name: []const u8, from: []const u8) ?resolver_mod.RawAuthor {
    var res = self.resolver();
    const set = res.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (set.flat.len > 0) self.alloc.free(set.flat);
    if (set.own) |o| return o;
    if (set.flat.len == 1) return set.flat[0];
    return null;
}

/// Resolve `name`, as seen from `from`, to a generic-struct template by
/// following const ALIAS declarations (issue 0120). Entry for the head
/// selector's bare tail: the FIRST hop must be alias-shaped — a direct
/// struct author is the template map's business, never this path's. Each
/// hop resolves from the ALIAS AUTHOR's source, so visibility is the
/// author's, not the use site's (a consumer one flat hop from a facade
/// reaches the facade's `Box :: r.Box;` without seeing `r` itself).
pub fn aliasedStructTemplate(self: *Lowering, name: []const u8, from: []const u8) ?StructTemplate {
    const author = singleVisibleAuthor(self, name, from) orelse return null;
    if (constAliasOfRaw(author.raw) == null) return null;
    return followToTemplate(self, author);
}

/// One alias hop: a generic-struct author terminates the chain with its
/// rebuilt source-pinned template; an alias author recurses via
/// `followAliasChain`.
fn followToTemplate(self: *Lowering, author: resolver_mod.RawAuthor) ?StructTemplate {
    const terminal = followAliasChain(self, author) orelse return null;
    const sd = structDeclOfRaw(terminal.raw) orelse return null;
    if (sd.type_params.len == 0) return null;
    return self.buildGenericStructTemplate(sd, terminal.source);
}

/// Walk a chain of const ALIAS decls to its terminal author. Each hop
/// resolves the RHS from the hop AUTHOR's own source — a bare identifier
/// via the visible-author walk, `ns.X` through the author's namespace edge
/// into the target module's own member. A non-alias author terminates the
/// chain (callers unwrap it by domain: `structDeclOfRaw` / `fnDeclOfRaw`).
/// Any acyclic chain resolves — the walk is bounded by the finite set of
/// alias decls; a cycle (`A :: B; B :: A;`) is detected by declaration
/// identity, diagnosed once, and returns null (issue 0331).
pub fn followAliasChain(self: *Lowering, author: resolver_mod.RawAuthor) ?resolver_mod.RawAuthor {
    var visited: std.ArrayList(*const ast.ConstDecl) = .empty;
    defer visited.deinit(self.alloc);
    var cur = author;
    while (true) {
        const cd = constAliasOfRaw(cur.raw) orelse return cur;
        for (visited.items, 0..) |seen, i| {
            if (seen == cd) {
                diagnoseAliasCycle(self, visited.items[i..]);
                return null;
            }
        }
        visited.append(self.alloc, cd) catch @panic("out of memory");
        const next: ?resolver_mod.RawAuthor = switch (cd.value.data) {
            .identifier => |id| singleVisibleAuthor(self, id.name, cur.source),
            .field_access => blk: {
                const path = self.qualifiedTypeName(cd.value) orelse break :blk null;
                defer self.alloc.free(path);
                break :blk switch (self.qualifiedMemberVerdictFrom(path, cur.source)) {
                    .selected => |sel| sel.author,
                    .not_qualified, .missing, .ambiguous => null,
                };
            },
            else => null,
        };
        cur = next orelse return null;
    }
}

/// Report a const-alias cycle once. `cycle` is the closed loop's decls in
/// walk order (first element = re-visited decl). Keyed by the cycle's
/// minimum decl address so every entry point into the same loop — each
/// member decl's own registration probe, plus any use-site probe — shares
/// one diagnostic.
fn diagnoseAliasCycle(self: *Lowering, cycle: []const *const ast.ConstDecl) void {
    const diags = self.diagnostics orelse return;
    var key: usize = std.math.maxInt(usize);
    for (cycle) |cd| key = @min(key, @intFromPtr(cd));
    const gop = self.alias_cycle_diagnosed.getOrPut(key) catch return;
    if (gop.found_existing) return;
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(self.alloc);
    for (cycle) |cd| {
        names.appendSlice(self.alloc, cd.name) catch @panic("out of memory");
        names.appendSlice(self.alloc, " -> ") catch @panic("out of memory");
    }
    names.appendSlice(self.alloc, cycle[0].name) catch @panic("out of memory");
    diags.addFmt(.err, cycle[0].name_span, "alias cycle '{s}' can never resolve — point one of these at a real declaration", .{names.items});
}

/// The fn decl a const ALIAS chain terminates at, or null when `cd` is not
/// an alias of a function. Entry for fn-alias registration (issue 0121):
/// `cd` itself seeds the chain (it IS the first alias hop), `from` is its
/// declaring source.
pub fn aliasedFnDecl(self: *Lowering, cd: *const ast.ConstDecl, from: []const u8) ?*const ast.FnDecl {
    const terminal = followAliasChain(self, .{ .raw = .{ .const_decl = cd }, .source = from }) orelse return null;
    return Lowering.fnDeclOfRaw(terminal.raw);
}

/// The bare-VISIBLE single generic-struct author of `name` (its `StructDecl` +
/// defining source) when that author is NOT the one the global last-wins
/// `struct_template_map` already holds — the E4 non-transitive selection for a
/// bare generic head / alias / static-method head whose visible author (own or
/// a single 1-hop flat import) is shadowed in the global map by a NON-visible
/// (≥2-flat-hop) same-name template (finding #1). Exposing the decl (not just a
/// rebuilt template) lets a static-method head source-pin the METHOD body too,
/// not only the type layout. Null — caller uses the global map unchanged
/// (byte-identical) — when: no source context; the single visible author IS the
/// canonical map author (the common single-author case, matched by source
/// file); or the visible picture is not a clean single generic-struct author
/// (own non-generic shadow, or ≥2 flat authors whose ambiguity `headTypeLeak`
/// has already diagnosed + poisoned before this is consulted).
pub fn bareVisibleStructDecl(self: *Lowering, name: []const u8) ?VisibleStructAuthor {
    if (self.emitting_default_context) return null;
    const from = self.current_source_file orelse return null;
    const canon = self.program_index.struct_template_map.get(name) orelse return null;
    const canon_src = canon.source_file orelse "";

    var res_walk = self.resolver();
    const set = res_walk.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (set.flat.len > 0) self.alloc.free(set.flat);

    // Own author wins — must be a generic struct to count.
    if (set.own) |own| {
        const sd = structDeclOfRaw(own.raw) orelse return null; // alias / fn / other → skip
        if (sd.type_params.len == 0) return null;
        if (std.mem.eql(u8, from, canon_src)) return null;
        return .{ .sd = sd, .source = from };
    }

    // Single flat-import generic-struct author.
    var picked: ?*const ast.StructDecl = null;
    var picked_src: []const u8 = "";
    for (set.flat) |fa| {
        const sd = structDeclOfRaw(fa.raw) orelse continue;
        if (sd.type_params.len == 0) continue;
        if (picked != null) return null; // ≥2 visible authors
        picked = sd;
        picked_src = fa.source;
    }
    const sd = picked orelse return null;
    if (std.mem.eql(u8, picked_src, canon_src)) return null;
    return .{ .sd = sd, .source = picked_src };
}

/// The rebuilt, source-pinned generic struct TEMPLATE of the single bare-VISIBLE
/// author (`bareVisibleStructDecl`) — instantiate this INSTEAD of the global
/// last-wins map entry. Null under the same conditions `bareVisibleStructDecl`
/// returns null (caller keeps the global map, byte-identical).
pub fn bareVisibleStructTemplate(self: *Lowering, name: []const u8) ?StructTemplate {
    const v = self.bareVisibleStructDecl(name) orelse return null;
    return self.buildGenericStructTemplate(v.sd, v.source);
}

/// Instantiate a generic struct template and register the result under an
/// alias name (`Vec3 :: Vec(3, f32)` / `ABox :: a.Box(i64)`). Shared by the
/// `.call` and `.parameterized_type_expr` const-decl alias branches and the
/// qualified-head selection that precedes the bare `struct_template_map`
/// fallback in each.
pub fn registerGenericStructAlias(self: *Lowering, alias_name: []const u8, tmpl: *const StructTemplate, args: []const *const Node) void {
    const inst_id = self.instantiateGenericStruct(tmpl, args);
    const alias_name_id = self.module.types.internString(alias_name);
    const inst_info = self.module.types.get(inst_id);
    if (inst_info != .@"struct") return;
    const alias_info: types.TypeInfo = .{ .@"struct" = .{
        .name = alias_name_id,
        .fields = inst_info.@"struct".fields,
    } };
    const alias_id = if (self.module.types.findByName(alias_name_id)) |existing| existing else self.module.types.intern(alias_info);
    self.module.types.updatePreservingKey(alias_id, alias_info);
    // A generic-struct instantiation alias IS a type author: route it through
    // the unified writer so it lands in `type_aliases_by_source` and the
    // bare-TYPE gate treats it like any other alias.
    self.putTypeAlias(self.current_source_file, alias_name, alias_id);
    // CP-3: the alias display name (`ABox`) is the struct type name a receiver
    // typed `x: ABox` reports, so method dispatch on it looks up the instance
    // maps under `ABox`. Mirror the mangled instance's template/bindings/author
    // onto the alias name so an alias-typed receiver is a first-class dispatch
    // instance (runs the selected author's body + bindings), not a dead end.
    const inst_name = self.formatTypeName(inst_id);
    if (self.struct_instance_author.get(inst_name)) |author_decl| {
        const tmpl_name = self.struct_instance_template.get(inst_name) orelse return;
        const bindings = self.struct_instance_bindings.getPtr(inst_name) orelse return;
        self.struct_instance_template.put(self.alloc.dupe(u8, alias_name) catch return, tmpl_name) catch {};
        self.struct_instance_bindings.put(self.alloc.dupe(u8, alias_name) catch return, bindings.*) catch {};
        self.struct_instance_author.put(self.alloc.dupe(u8, alias_name) catch return, author_decl) catch {};
        // Mirror the instance's field DEFAULTS onto the alias name too (issue
        // 0221 fold): the alias struct's stored type name is the ALIAS ('BI'
        // for `BI :: Box(i64)`), so the literal path's defaults lookup keys on
        // it — without this mirror an alias-typed literal zero-filled its
        // defaulted fields while the direct `Box(i64)` spelling applied them.
        // Bindings are mirrored above, so a DEPENDENT default (`size_of(T)`)
        // monomorphizes identically through the alias.
        if (self.struct_defaults_map.get(inst_name)) |defs| {
            self.struct_defaults_map.put(self.alloc.dupe(u8, alias_name) catch return, defs) catch {};
        }
    }
}

pub fn registerStructDecl(self: *Lowering, sd: *const ast.StructDecl, source_file: ?[]const u8) void {
    const table = &self.module.types;
    const name_id = table.internString(sd.name);

    // Generic structs: store as owned template, don't resolve fields yet
    if (sd.type_params.len > 0) {
        const tmpl = self.buildGenericStructTemplate(sd, source_file) orelse return;
        self.program_index.struct_template_map.put(tmpl.name, tmpl) catch {};

        // S1.1 (additive): key the template by DeclId in parallel. Nothing
        // reads this for selection yet; `struct_template_map` stays the live
        // consumer. A template whose decl is not in the table (comptime /
        // block-local registration with facts unwired) keeps only the
        // name-keyed entry.
        if (self.program_index.decl_table) |dt| {
            if (dt.declIdForStructDecl(sd)) |id| {
                self.program_index.struct_template_by_decl.put(id, tmpl) catch {};
            }
        }

        // Register methods under "TemplateName.method" in fn_ast_map
        for (sd.methods) |method_node| {
            if (method_node.data == .fn_decl) {
                const method_fd = &method_node.data.fn_decl;
                // A `#set` accessor registers under `name$set` so it never
                // clobbers a same-name `#get` (issue: get+set coexistence).
                const eff = self.accessorEffName(method_fd);
                const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sd.name, eff }) catch continue;
                self.program_index.fn_ast_map.put(qualified, method_fd) catch {};
            }
        }
        return;
    }

    // Per-decl nominal identity (E2). EACH author of a GENUINE same-name STRUCT
    // shadow already reserved its distinct slot up-front in `scanDecls` (the
    // first at id 0, the rest at nonzero ids), so a self / forward / mutual
    // reference to the shadow name bound to ITS nominal TypeId via
    // `type_decl_tids`, not the global findByName first-author fallback (issue
    // 0105 / F1): reuse that reserved id. A single-author name (or a phantom
    // over-counted by the raw import facts) was NOT reserved — it keeps id 0 and
    // the legacy post-field registration, byte-identical to pre-F1.
    // `shadowNominalId` here only fires for the non-scanDecls registration paths
    // (comptime `lowerDecls`, block-local), where module facts are unwired so it
    // returns 0.
    const decl_key: *const anyopaque = @ptrCast(sd);
    const nominal_id: u32 = if (table.type_decl_tids.get(decl_key)) |id| nominalIdOf(table.get(id)) else self.shadowNominalId(name_id);

    // Build field list, expanding #using entries. Defaults are built IN THE
    // SAME interleave so they stay aligned with the FLATTENED layout — an
    // embedded base field holds null (base defaults do not flow through
    // `#using`, matching generic instantiation; issue 0335), and an explicit
    // field's declared default lands at its flattened position.
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    var layout_defaults = std.ArrayList(?*const Node).empty;
    var field_idx: usize = 0;
    var using_idx: usize = 0;
    const using_authority: ?[]const u8 = source_file orelse self.current_source_file;
    const total_explicit = sd.field_names.len;
    while (field_idx < total_explicit or using_idx < sd.using_entries.len) {
        // Insert #using fields at their declared positions
        while (using_idx < sd.using_entries.len and sd.using_entries[using_idx].insert_index == fields.items.len) {
            const ue = sd.using_entries[using_idx];
            if (self.resolveUsingBase(ue.type_name, using_authority, sd.name)) |used_ty| {
                const used_info = table.get(used_ty);
                if (used_info == .@"struct") {
                    for (used_info.@"struct".fields) |f| {
                        fields.append(self.alloc, f) catch unreachable;
                        layout_defaults.append(self.alloc, null) catch unreachable;
                    }
                }
            }
            using_idx += 1;
        }
        if (field_idx < total_explicit) {
            _ = self.rejectMultiReturnValueType(sd.field_types[field_idx], "field");
            const field_ty = self.resolveType(sd.field_types[field_idx]);
            fields.append(self.alloc, .{
                .name = table.internString(sd.field_names[field_idx]),
                .ty = field_ty,
            }) catch unreachable;
            layout_defaults.append(self.alloc, if (field_idx < sd.field_defaults.len) sd.field_defaults[field_idx] else null) catch unreachable;
            field_idx += 1;
        } else break;
    }
    // Append remaining #using entries after all explicit fields
    while (using_idx < sd.using_entries.len) {
        const ue = sd.using_entries[using_idx];
        if (self.resolveUsingBase(ue.type_name, using_authority, sd.name)) |used_ty| {
            const used_info = table.get(used_ty);
            if (used_info == .@"struct") {
                for (used_info.@"struct".fields) |f| {
                    fields.append(self.alloc, f) catch unreachable;
                    layout_defaults.append(self.alloc, null) catch unreachable;
                }
            }
        }
        using_idx += 1;
    }

    // Qualify inline __anon type names: __anon → StructName.field_name
    for (sd.field_names, 0..) |fname, fi| {
        if (fi < fields.items.len) {
            const field_ty = fields.items[fi].ty;
            if (!field_ty.isBuiltin()) {
                self.qualifyAnonType(table, field_ty, sd.name, fname);
            }
        }
    }

    // Register under the per-decl nominal identity computed above. A non-first
    // shadow author's slot was already reserved before fields resolved, so this
    // fills it (key-stable updatePreservingKey); a first / single author adopts
    // any forward-reference stub. Same-name structs in DIFFERENT sources get
    // distinct TypeIds instead of last-wins clobbering the first.
    const info: types.TypeInfo = .{ .@"struct" = .{ .name = name_id, .fields = fields.items } };
    const struct_ty = self.internNamedTypeDecl(decl_key, name_id, info, nominal_id);
    // Couple the nominal layout identity to its authoring declaration. Method
    // calls must select through this TypeId-keyed provenance, never through the
    // process-global `StructName.method` spelling (issue 0320).
    self.plain_struct_authors.put(struct_ty, .{ .decl = sd, .source = source_file orelse self.current_source_file }) catch @panic("out of memory");

    // Store field defaults for struct literal lowering — the LAYOUT-ALIGNED
    // array, keyed by the concrete TypeId (authoritative; issue 0320) and by
    // display name (legacy fallback for consumers without a nominal identity;
    // still last-wins across same-name authors).
    {
        var has_any_default = false;
        for (layout_defaults.items) |d| {
            if (d != null) {
                has_any_default = true;
                break;
            }
        }
        if (has_any_default) {
            const owned_defaults = layout_defaults.toOwnedSlice(self.alloc) catch &.{};
            self.struct_defaults_by_tid.put(struct_ty, owned_defaults) catch {};
            self.struct_defaults_map.put(sd.name, owned_defaults) catch {};
        }
    }

    // Register struct methods as StructName.method in fn_ast_map
    for (sd.methods) |method_node| {
        if (method_node.data == .fn_decl) {
            const method_fd = &method_node.data.fn_decl;
            // Build qualified name: StructName.method. A `#set` accessor uses
            // its `name$set` effective name so a get+set pair keeps two distinct
            // fn_ast_map slots and two distinct FuncId stubs (coexistence).
            const eff = self.accessorEffName(method_fd);
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sd.name, eff }) catch continue;
            // The function table resolves the first stub by name. Keep the
            // compatibility AST map coherent with that first author; every
            // later same-name method remains reachable through its decl-
            // identity `fn_decl_fids` slot and nominal author dispatch.
            if (!self.program_index.fn_ast_map.contains(qualified))
                self.program_index.fn_ast_map.put(qualified, method_fd) catch {};
            // Declare extern stub (body is lowered lazily on demand)
            self.declareFunction(method_fd, qualified);
        }
    }

    // Register struct-level constants (e.g., GRAVITY :f32: 9.81) — keyed by
    // the concrete TypeId (authoritative; issue 0320) and by the legacy
    // "Struct.CONST" spelling (fallback for heads with no nominal identity;
    // still last-wins across same-name authors).
    for (sd.constants) |const_node| {
        if (const_node.data == .const_decl) {
            const cd = const_node.data.const_decl;
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sd.name, cd.name }) catch continue;
            const ty: ?TypeId = if (cd.type_annotation) |ta| self.resolveType(ta) else null;
            const info_entry: Lowering.StructConstInfo = .{ .value = cd.value, .ty = ty };
            self.struct_const_by_tid.put(.{ .ty = struct_ty, .name = table.internString(cd.name) }, info_entry) catch {};
            self.struct_const_map.put(qualified, info_entry) catch {};
        }
    }
}

/// Resolve a `#using` base name from the DECLARING struct's own source
/// authority (issue 0320: the global `findByName` first/last-match let a
/// different module's same-name base win). `.resolved` wins; any other
/// verdict falls back to the legacy global lookup so forward references and
/// unwired-facts registration keep their existing behavior. When BOTH miss,
/// the base is genuinely unknown — diagnose loudly instead of silently
/// registering a layout without the embedded fields.
pub fn resolveUsingBase(self: *Lowering, base_name: []const u8, authority: ?[]const u8, struct_name: []const u8) ?TypeId {
    const table = &self.module.types;
    if (authority) |from| {
        switch (self.selectNominalLeaf(base_name, from, false)) {
            .resolved => |ty| if (!ty.isBuiltin()) return ty,
            else => {},
        }
    }
    if (table.findByName(table.internString(base_name))) |ty| return ty;
    if (self.diagnostics) |d|
        d.addFmt(.err, .{ .start = 0, .end = 0 }, "unknown type '{s}' in #using inside struct '{s}'", .{ base_name, struct_name });
    return null;
}

/// Register a top-level ENUM decl under a per-decl nominal identity (E6a) —
/// the enum twin of `registerStructDecl`. A GENUINE same-name shadow already
/// reserved its DISTINCT slot up-front in `scanDecls` (the first at id 0, the
/// rest at nonzero ids), so a forward / self / mutual reference to the shadow
/// name already bound to ITS nominal TypeId via `type_decl_tids`: reuse that
/// reserved id. A single-author name (or one over-counted by the raw facts but
/// not a genuine scanned shadow) was NOT reserved — it keeps id 0 and the legacy
/// post-build registration, byte-identical to pre-E6a. The body is built once by
/// the shared `type_bridge.buildEnumInfo`; `internNamedTypeDecl` interns it under
/// the computed nominal id and records `decl_key → TypeId` so `namedRefTid`
/// resolves bare references to this exact author.
pub fn registerEnumDecl(self: *Lowering, ed: *const ast.EnumDecl) void {
    const table = &self.module.types;
    const name_id = table.internString(ed.name);
    const decl_key: *const anyopaque = @ptrCast(ed);
    const nominal_id: u32 = if (table.type_decl_tids.get(decl_key)) |id| nominalIdOf(table.get(id)) else self.shadowNominalId(name_id);
    // Pass `self` (the visibility-aware `Lowering` resolver) as the `inner`
    // recursion hook — the same seam `resolveCompound` uses — so a payload type
    // NAME resolves in the enum's OWN module visibility context (own author wins
    // over a namespaced same-name import), not via a global `findByName`
    // first-match (issue 0132's class).
    const info = type_bridge.buildEnumInfo(ed, table, self);
    _ = self.internNamedTypeDecl(decl_key, name_id, info, nominal_id);
}

/// Register a top-level UNION decl under a per-decl nominal identity (E6a) —
/// the union twin of `registerEnumDecl` / `registerStructDecl`.
pub fn registerUnionDecl(self: *Lowering, ud: *const ast.UnionDecl) void {
    const table = &self.module.types;
    const name_id = table.internString(ud.name);
    const decl_key: *const anyopaque = @ptrCast(ud);
    const nominal_id: u32 = if (table.type_decl_tids.get(decl_key)) |id| nominalIdOf(table.get(id)) else self.shadowNominalId(name_id);
    // `self` as the visibility-aware `inner` hook — see `registerEnumDecl`.
    const info = type_bridge.buildUnionInfo(ud, table, self);
    _ = self.internNamedTypeDecl(decl_key, name_id, info, nominal_id);
}

/// Rename an __anon type to a qualified name: ParentStruct.field_name
/// Also renames variant payload struct types from __anon.X to ParentStruct.field_name.X
pub fn qualifyAnonType(self: *Lowering, table: *types.TypeTable, ty: TypeId, parent_name: []const u8, field_name: []const u8) void {
    const ti = table.get(ty);
    switch (ti) {
        .@"union" => |u| {
            const old_name = table.getString(u.name);
            if (!std.mem.eql(u8, old_name, "__anon")) return;
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ parent_name, field_name }) catch return;
            const qname_id = table.internString(qualified);
            table.replaceKeyedInfo(ty, .{ .@"union" = .{ .name = qname_id, .fields = u.fields } });
        },
        .tagged_union => |u| {
            const old_name = table.getString(u.name);
            if (!std.mem.eql(u8, old_name, "__anon")) return;
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ parent_name, field_name }) catch return;
            const qname_id = table.internString(qualified);
            // Rename variant payload structs: __anon.X → ParentStruct.field.X
            for (u.fields) |f| {
                if (!f.ty.isBuiltin()) {
                    const finfo = table.get(f.ty);
                    if (finfo == .@"struct") {
                        const sname = table.getString(finfo.@"struct".name);
                        if (std.mem.startsWith(u8, sname, "__anon.")) {
                            const suffix = sname["__anon".len..]; // .VariantName
                            const sq = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ qualified, suffix }) catch continue;
                            const sq_id = table.internString(sq);
                            table.replaceKeyedInfo(f.ty, .{ .@"struct" = .{ .name = sq_id, .fields = finfo.@"struct".fields } });
                        }
                    }
                }
            }
            table.replaceKeyedInfo(ty, .{ .tagged_union = .{ .name = qname_id, .fields = u.fields, .tag_type = u.tag_type, .backing_type = u.backing_type, .explicit_tag_values = u.explicit_tag_values } });
        },
        .@"enum" => |e| {
            const old_name = table.getString(e.name);
            if (!std.mem.eql(u8, old_name, "__anon")) return;
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ parent_name, field_name }) catch return;
            const qname_id = table.internString(qualified);
            table.replaceKeyedInfo(ty, .{ .@"enum" = .{ .name = qname_id, .variants = e.variants, .explicit_values = e.explicit_values } });
        },
        .@"struct" => |s| {
            const old_name = table.getString(s.name);
            if (!std.mem.eql(u8, old_name, "__anon")) return;
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ parent_name, field_name }) catch return;
            const qname_id = table.internString(qualified);
            table.replaceKeyedInfo(ty, .{ .@"struct" = .{ .name = qname_id, .fields = s.fields } });
        },
        else => {},
    }
}
