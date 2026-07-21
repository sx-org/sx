const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const type_bridge = @import("type_bridge.zig");
const TypeResolver = @import("type_resolver.zig").TypeResolver;
const lower = @import("lower.zig");
const program_index_mod = @import("program_index.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;
const ProtocolDeclInfo = program_index_mod.ProtocolDeclInfo;
const ProtocolMethodInfo = program_index_mod.ProtocolMethodInfo;
const ProtocolImplMethod = lower.ProtocolImplMethod;

pub const ResolvedProtocol = struct {
    name: []const u8,
    /// Null for parameterized protocol templates, which have no runtime
    /// TypeId until instantiated. Nullary declarations always carry their
    /// exact nominal identity.
    ty: ?TypeId,
    decl: *const ast.ProtocolDecl,
};

fn typeExprHasGeneric(node: *const Node) bool {
    return switch (node.data) {
        .type_expr => |te| te.is_generic,
        .comptime_pack_ref, .pack_index_type_expr => true,
        .pointer_type_expr => |pt| typeExprHasGeneric(pt.pointee_type),
        .many_pointer_type_expr => |mp| typeExprHasGeneric(mp.element_type),
        .optional_type_expr => |opt| typeExprHasGeneric(opt.inner_type),
        .slice_type_expr => |st| typeExprHasGeneric(st.element_type),
        .array_type_expr => |at| typeExprHasGeneric(at.element_type),
        .parameterized_type_expr => |pt| blk: {
            for (pt.args) |arg| if (typeExprHasGeneric(arg)) break :blk true;
            break :blk false;
        },
        .function_type_expr => |ft| blk: {
            for (ft.param_types) |p| if (typeExprHasGeneric(p)) break :blk true;
            break :blk if (ft.return_type) |rt| typeExprHasGeneric(rt) else false;
        },
        .closure_type_expr => |ct| blk: {
            if (ct.pack_name != null) break :blk true;
            for (ct.param_types) |p| if (typeExprHasGeneric(p)) break :blk true;
            break :blk if (ct.return_type) |rt| typeExprHasGeneric(rt) else false;
        },
        .return_type_expr => |rt| blk: {
            for (rt.field_types) |field| if (typeExprHasGeneric(field)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn typeContainsUnresolved(table: *const types.TypeTable, ty: TypeId) bool {
    if (ty == .unresolved) return true;
    if (ty.isBuiltin()) return false;
    return switch (table.get(ty)) {
        .pointer => |p| typeContainsUnresolved(table, p.pointee),
        .many_pointer => |p| typeContainsUnresolved(table, p.element),
        .slice => |s| typeContainsUnresolved(table, s.element),
        .array => |a| typeContainsUnresolved(table, a.element),
        .optional => |o| typeContainsUnresolved(table, o.child),
        else => false,
    };
}

/// Protocol / impl LOOKUP + REGISTRATION (architecture phase A4.2), extracted
/// from `Lowering`. Owns:
///   - read-only conformance queries: `getProtocolInfo` (is a type a registered
///     protocol + its method table), `hasImplPlain` (have a (protocol, type)
///     pair's thunks been materialized), `packArgConformsTo` (impl-declaration
///     conformance for protocol-pack `..xs: P` elements),
///   - registration: `registerProtocolDecl` (protocol struct + method table +
///     vtable type), `registerImplBlock` / `registerParamImpl` (populate the
///     impl maps + the `0410`/`0411`/`0412` visibility/duplicate diagnostics),
///     and the default-method synthesis they use.
///
/// A `*Lowering` facade (Principle 5, like `GenericResolver` / `CallResolver`):
/// it reads/writes the protocol/impl registries (`protocol_decl_map` /
/// `protocol_ast_map` in `ProgramIndex`; `protocol_thunk_map` / `param_impl_map`
/// / `param_impl_pack_map` / `protocol_vtable_type_map` on `Lowering`) plus the
/// type table, so it borrows `*Lowering` rather than re-threading every map.
/// IR EMISSION stays in `Lowering` for the later A4.2 increment — registration
/// calls `self.l.declareFunction` (the emission primitive) but the thunk/value
/// builders (`createProtocolThunk` / `buildProtocolValue` / `tryUserConversion`)
/// are NOT moved here.
pub const ProtocolResolver = struct {
    l: *Lowering,

    /// If `ty` is a registered protocol struct, return its decl info (method
    /// table); else null.
    pub fn getProtocolInfo(self: ProtocolResolver, ty: TypeId) ?ProtocolDeclInfo {
        if (ty.isBuiltin()) return null;
        const info = self.l.module.types.get(ty);
        if (info != .@"struct" or !info.@"struct".is_protocol) return null;
        return self.l.protocol_info_by_type.get(ty);
    }

    pub fn getProtocolAst(self: ProtocolResolver, ty: TypeId) ?*const ast.ProtocolDecl {
        return self.l.protocol_ast_by_type.get(ty);
    }

    /// Whether `written` resolves to a protocol declaration in `source`'s
    /// visibility domain. A protocol that exists only behind a named import
    /// must not turn a same-spelled local enum/value constraint into a generic
    /// TYPE parameter.
    pub fn isProtocolConstraint(self: ProtocolResolver, written: []const u8, source: ?[]const u8) bool {
        if (self.l.program_index.module_decls == null or self.l.program_index.flat_import_graph == null) {
            return self.l.program_index.protocol_decl_map.contains(written) or
                self.l.program_index.protocol_ast_map.contains(written);
        }
        return self.canonicalProtocolName(written, source) != null;
    }

    /// Have the thunks for (protocol `p_name`, concrete `ty`) been materialized?
    /// `protocol_thunk_map` is populated lazily when a protocol VALUE is created
    /// with `xx`, so this answers "has erasure already happened for this pair".
    pub fn hasImplPlain(self: ProtocolResolver, p_name: []const u8, ty: TypeId) bool {
        const proto = self.resolveProtocol(p_name, self.l.current_source_file);
        return self.l.protocol_thunk_map.contains(self.protocolConcreteKey(
            if (proto) |p| p.ty else null,
            if (proto) |p| p.name else p_name,
            ty,
        ));
    }

    pub fn protocolConcreteKey(self: ProtocolResolver, proto_ty: ?TypeId, p_name: []const u8, ty: TypeId) lower.ProtocolConcreteKey {
        return .{
            .protocol = proto_ty orelse .unresolved,
            .protocol_name = self.l.module.types.internString(p_name),
            .concrete = ty,
        };
    }

    fn protocolImplKey(self: ProtocolResolver, proto_ty: ?TypeId, p_name: []const u8, ty: TypeId, method: []const u8) lower.ProtocolImplMethodKey {
        return .{
            .protocol = proto_ty orelse .unresolved,
            .protocol_name = self.l.module.types.internString(p_name),
            .concrete = ty,
            .method = self.l.module.types.internString(method),
        };
    }

    /// Internal runtime name for one parameterized protocol instance. Type
    /// arguments use nominal-aware mangles, so `P(a.Thing)` and `P(b.Thing)`
    /// cannot share a protocol type, impl key, thunk set, or vtable merely
    /// because both arguments display as `Thing`.
    pub fn paramProtocolInstanceName(self: ProtocolResolver, p_name: []const u8, arg_tys: []const TypeId) []const u8 {
        var buf = std.ArrayList(u8).empty;
        buf.appendSlice(self.l.alloc, p_name) catch @panic("out of memory");
        for (arg_tys) |ty| {
            buf.appendSlice(self.l.alloc, "__") catch @panic("out of memory");
            buf.appendSlice(self.l.alloc, self.l.mangleTypeName(ty)) catch @panic("out of memory");
        }
        return buf.items;
    }

    /// Exact explicit impl method for a protocol + nominal concrete TypeId.
    /// This is the protocol counterpart of `plainStructMethod`: display names
    /// are deliberately absent from the lookup key.
    pub fn protocolImplMethod(self: ProtocolResolver, proto_ty: ?TypeId, p_name: []const u8, ty: TypeId, method: []const u8) ?ProtocolImplMethod {
        return self.l.protocol_impl_methods.get(self.protocolImplKey(proto_ty, p_name, ty, method));
    }

    /// Concrete method selected for dispatch through an explicitly declared
    /// protocol impl. Exact bodies/defaults on that impl win. An empty/partial
    /// impl may adopt a uniquely selected body already owned by the SAME
    /// concrete TypeId (inline or another protocol impl), matching the legacy
    /// `Type.method` behavior without cross-binding display-name collisions.
    pub fn protocolDispatchMethod(self: ProtocolResolver, proto_ty: ?TypeId, p_name: []const u8, ty: TypeId, method: []const u8) ?ProtocolImplMethod {
        if (self.protocolImplMethod(proto_ty, p_name, ty, method)) |exact| return exact;
        if (!self.l.protocol_impl_decls.contains(self.protocolConcreteKey(proto_ty, p_name, ty))) return null;
        const adopted = self.l.plainStructAdoptableMethod(ty, method) orelse return null;
        return .{ .fd = adopted.fd, .concrete = ty, .source = adopted.source, .is_synthesized_default = false };
    }

    fn resolvedProtocolAuthor(self: ProtocolResolver, author: @import("resolver.zig").RawAuthor) ?ResolvedProtocol {
        const terminal = self.l.followAliasChain(author, 16) orelse return null;
        if (terminal.raw != .protocol_decl) return null;
        const pd = terminal.raw.protocol_decl;
        var protocol_ty: ?TypeId = null;
        if (pd.type_params.len == 0) {
            const saved = self.l.current_source_file;
            self.l.setCurrentSourceFile(terminal.source);
            self.registerProtocolDecl(pd);
            self.l.setCurrentSourceFile(saved);
            protocol_ty = self.l.namedRefTid(terminal.raw, pd.name) orelse return null;
        }
        return .{ .name = pd.name, .ty = protocol_ty, .decl = pd };
    }

    /// Resolve a written protocol head to its exact declaration and, for a
    /// nullary runtime protocol, its nominal TypeId. Unrelated same-spelled
    /// values/functions are filtered before ambiguity is decided.
    pub fn resolveProtocol(self: ProtocolResolver, written: []const u8, source: ?[]const u8) ?ResolvedProtocol {
        // Compilation must resolve the written head in the impl declaration's
        // own visibility domain before consulting the process-global protocol
        // spelling map. A namespaced-only foreign `P` may coexist with a local
        // alias `P :: Q`; looking up `protocol_ast_map["P"]` first would let
        // the hidden foreign declaration hijack the local impl (issue 0320).
        // Unit/comptime registration hosts intentionally omit import facts, so
        // retain their explicit-spelling fallback below.
        if (self.l.program_index.module_decls == null or self.l.program_index.flat_import_graph == null) {
            const pd = self.l.program_index.protocol_ast_map.get(written) orelse return null;
            const ty = if (pd.type_params.len == 0)
                self.l.module.types.type_decl_tids.get(@ptrCast(pd)) orelse self.l.module.types.findByName(self.l.module.types.internString(pd.name))
            else
                null;
            return .{ .name = pd.name, .ty = ty, .decl = pd };
        }
        const src = source orelse self.l.current_source_file;
        if (src) |from| {
            // Protocol heads can be compile-time-only parameterized protocols,
            // so they do not necessarily have a runtime TypeId for
            // selectNominalLeaf to return. Select the visible RAW author, then
            // follow facade/local const aliases (`Into :: core.Into`, `P :: Q`)
            // in each alias author's source until the terminal protocol decl.
            // Own wins; otherwise exactly one direct flat author is required.
            var resolver = self.l.resolver();
            const set = resolver.collectVisibleAuthors(written, from, .user_bare_flat);
            defer if (set.flat.len > 0) self.l.alloc.free(set.flat);
            if (set.own) |own| return self.resolvedProtocolAuthor(own);

            var selected: ?ResolvedProtocol = null;
            for (set.flat) |author| {
                const candidate = self.resolvedProtocolAuthor(author) orelse continue;
                if (selected) |prior| {
                    if (prior.decl != candidate.decl) return null;
                } else {
                    selected = candidate;
                }
            }
            return selected;
        }
        return null;
    }

    fn canonicalProtocolName(self: ProtocolResolver, written: []const u8, source: ?[]const u8) ?[]const u8 {
        if (self.resolveProtocol(written, source)) |resolved| return resolved.name;
        if (self.l.program_index.module_decls == null or self.l.program_index.flat_import_graph == null) return written;
        return null;
    }

    fn concreteImplTarget(self: ProtocolResolver, ib: *const ast.ImplBlock, source: ?[]const u8) ?TypeId {
        // `impl P for Box($T)` is a template selected by the existing generic
        // instance machinery only after Box is instantiated.
        if (ib.target_type_params.len > 0 or ib.target_type.len == 0) return null;
        if (source orelse self.l.current_source_file) |from| {
            return switch (self.l.selectNominalLeaf(ib.target_type, from, false)) {
                .resolved => |ty| ty,
                else => null,
            };
        }
        // Unit/comptime hosts may not wire source/import facts. Preserve their
        // pre-source-aware registered-type lookup without fabricating a type.
        if (TypeResolver.resolveBuiltinName(ib.target_type, &self.l.module.types)) |ty| return ty;
        return self.l.module.types.findByName(self.l.module.types.internString(ib.target_type));
    }

    /// A parameterized impl may be scanned before a concrete source/type-arg
    /// alias reaches its target. Such an impl must remain retryable: committing
    /// an `unresolved` key and marking it registered permanently disconnects it
    /// from the concrete instance after the alias fixpoint. Generic/pack-shaped
    /// nodes deliberately carry unresolved binders and remain templates.
    fn concreteParamImplTypesReady(self: ProtocolResolver, ib: *const ast.ImplBlock, decl: *const Node) bool {
        const source = decl.source_file orelse self.l.current_source_file;
        const table = &self.l.module.types;
        for (ib.protocol_type_args) |arg_node| {
            if (typeExprHasGeneric(arg_node)) continue;
            if (!self.l.typeNodeLeavesReady(arg_node, source)) return false;
            const ty = self.l.resolveTypeInSource(source, arg_node);
            if (typeContainsUnresolved(table, ty)) return false;
        }
        if (ib.target_type_expr) |target| {
            if (typeExprHasGeneric(target)) return true;
            if (!self.l.typeNodeLeavesReady(target, source)) return false;
            return !typeContainsUnresolved(table, self.l.resolveTypeInSource(source, target));
        }
        if (ib.target_type.len == 0 or ib.target_type_params.len > 0) return true;
        const target: Node = .{ .span = decl.span, .data = .{ .type_expr = .{ .name = ib.target_type } } };
        if (!self.l.typeNodeLeavesReady(&target, source)) return false;
        return !typeContainsUnresolved(table, self.l.resolveTypeInSource(source, &target));
    }

    fn recordProtocolImplMethod(self: ProtocolResolver, proto_ty: ?TypeId, p_name: []const u8, concrete: ?TypeId, fd: *const ast.FnDecl, source: ?[]const u8, is_synthesized_default: bool) void {
        const ty = concrete orelse return;
        const key = self.protocolImplKey(proto_ty, p_name, ty, fd.name);
        if (!self.l.protocol_impl_methods.contains(key)) {
            self.l.protocol_impl_methods.put(key, .{
                .fd = fd,
                .concrete = ty,
                .source = source,
                .is_synthesized_default = is_synthesized_default,
            }) catch @panic("out of memory");
        }
        if (self.l.fn_decl_fids.get(fd)) |fid| {
            const f = self.l.module.getFunction(fid);
            const user_base: usize = if (f.has_implicit_ctx) 1 else 0;
            if (user_base < f.params.len) {
                self.l.protocol_impl_receiver_types.put(fd, f.params[user_base].ty) catch @panic("out of memory");
            }
        }
    }

    /// Does `ty` conform to protocol `p_name` (under SOME type-args for a
    /// parameterised protocol)? Used to check protocol-pack elements
    /// (`..xs: P`), where each element's protocol type-args are inferred from
    /// its impl rather than written out.
    ///
    /// Conformance is queried at the IMPL-DECLARATION level (not via
    /// `protocol_thunk_map`, which is only populated lazily when a protocol
    /// VALUE is created with `xx`):
    /// - Parameterised `P`: any `param_impl_map` key `P\x00<args>\x00<mangle(ty)>`.
    /// - Non-parameterised `P`: every required (non-default) method `m` is
    ///   registered as `<ty>.<m>` in `fn_ast_map` (how `registerImplBlock`
    ///   records a non-parameterised impl).
    /// An arg already of the protocol's own (erased) type trivially conforms.
    pub fn packArgConformsTo(self: ProtocolResolver, p_name: []const u8, ty: TypeId) bool {
        const proto = self.resolveProtocol(p_name, self.l.current_source_file) orelse return false;
        // Arg already erased to the protocol struct itself (e.g. `xx a`).
        if (proto.ty != null and ty == proto.ty.?) return true;
        const pd = proto.decl;
        if (pd.type_params.len > 0) {
            const prefix = std.fmt.allocPrint(self.l.alloc, "{s}\x00", .{proto.name}) catch return false;
            const suffix = std.fmt.allocPrint(self.l.alloc, "\x00{s}", .{self.l.mangleTypeName(ty)}) catch return false;
            var it = self.l.param_impl_map.keyIterator();
            while (it.next()) |k| {
                if (std.mem.startsWith(u8, k.*, prefix) and std.mem.endsWith(u8, k.*, suffix)) return true;
            }
            return false;
        }
        // Non-parameterised: require each non-default method from the exact
        // protocol + nominal concrete identity. A display-name lookup here
        // would let another module's same-named struct satisfy the constraint.
        for (pd.methods) |m| {
            if (m.default_body != null) continue;
            if (self.protocolDispatchMethod(proto.ty, proto.name, ty, m.name) == null) return false;
        }
        return true;
    }

    // ── Thunk / impl PLANNING (lookup only; emission stays in Lowering) ──

    /// The dispatch method table for protocol `proto_name` — i.e. exactly which
    /// methods `getOrCreateThunks` must materialize a thunk for. Null if the
    /// name isn't a registered (non-parameterised) protocol.
    pub fn protocolMethodInfos(self: ProtocolResolver, proto_ty: ?TypeId, proto_name: []const u8) ?[]const ProtocolMethodInfo {
        const pd = if (proto_ty) |ty|
            self.l.protocol_info_by_type.get(ty) orelse return null
        else
            self.l.program_index.protocol_decl_map.get(proto_name) orelse return null;
        return pd.methods;
    }

    /// Filter parameterised-impl `entries` to those reachable from the current
    /// source file (the file itself + everything it transitively imports). The
    /// cross-module visibility selection behind the `0410` path. Falls open
    /// (all entries) when the source-file context or import graph isn't wired
    /// (e.g. comptime callers). Appends the visible subset to `out`.
    pub fn findVisibleImpls(self: ProtocolResolver, entries: []const Lowering.ParamImplEntry, out: *std.ArrayList(Lowering.ParamImplEntry)) void {
        const here = self.l.current_source_file orelse {
            out.appendSlice(self.l.alloc, entries) catch {};
            return;
        };
        const graph = self.l.program_index.import_graph orelse {
            out.appendSlice(self.l.alloc, entries) catch {};
            return;
        };

        // BFS over the import graph to compute the visible set.
        var visible = std.StringHashMap(void).init(self.l.alloc);
        defer visible.deinit();
        visible.put(here, {}) catch {};
        var queue = std.ArrayList([]const u8).empty;
        defer queue.deinit(self.l.alloc);
        queue.append(self.l.alloc, here) catch {};
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            const direct = graph.get(node) orelse continue;
            var it = direct.iterator();
            while (it.next()) |kv| {
                const next = kv.key_ptr.*;
                if (visible.contains(next)) continue;
                visible.put(next, {}) catch {};
                queue.append(self.l.alloc, next) catch {};
            }
        }

        for (entries) |e| {
            if (visible.contains(e.defining_module)) {
                out.append(self.l.alloc, e) catch {};
            }
        }
    }

    /// A pack-impl selected for a concrete source closure/function: the matched
    /// entry plus its `convert` method. Pure SELECTION — binding + monomorphise
    /// + emission stay in `Lowering.tryPackImplMatch`.
    pub const PackImplMatch = struct {
        entry: Lowering.PackParamImplEntry,
        convert_fd: *const ast.FnDecl,
        /// The source closure/function's param + return types — the binding
        /// step (in `Lowering`) reads these to bind the pack-var tail + ret-var.
        src_params: []const TypeId,
        src_ret: TypeId,
    };

    /// Among the pack impls under `pack_key`, find the first whose fixed prefix
    /// matches `src_ty`'s leading params (and whose return matches, unless the
    /// impl's return is a generic var). Returns the matched entry + its
    /// `convert` method, or null when nothing matches. No emission.
    pub fn matchPackImpl(self: ProtocolResolver, src_ty: TypeId, pack_key: []const u8) ?PackImplMatch {
        const pack_entries = self.l.param_impl_pack_map.get(pack_key) orelse return null;
        if (pack_entries.items.len == 0) return null;
        const table = &self.l.module.types;
        // Source must itself be a closure/function the pack can match.
        const src_info = table.get(src_ty);
        if (src_info != .closure and src_info != .function) return null;

        const src_params: []const TypeId = switch (src_info) {
            .closure => |c| c.params,
            .function => |f| f.params,
            else => unreachable,
        };
        const src_ret: TypeId = switch (src_info) {
            .closure => |c| c.ret,
            .function => |f| f.ret,
            else => unreachable,
        };

        // Find pack impls whose fixed prefix matches src's leading params.
        var matched_idx: ?usize = null;
        for (pack_entries.items, 0..) |entry, i| {
            const ent_info = table.get(entry.source_pack_ty);
            // Pack impls always wear a closure (resolveClosureType routes
            // both Closure and the future Fn pack forms through
            // closureTypePack); a function-typed pack impl is not produced
            // by current parser shapes.
            if (ent_info != .closure) continue;
            const ent_ci = ent_info.closure;
            const pack_start = ent_ci.pack_start orelse continue;
            // Fixed prefix must fit within the source's params.
            if (pack_start > src_params.len) continue;
            var prefix_ok = true;
            var i_fix: u32 = 0;
            while (i_fix < pack_start) : (i_fix += 1) {
                if (ent_ci.params[i_fix] != src_params[i_fix]) {
                    prefix_ok = false;
                    break;
                }
            }
            if (!prefix_ok) continue;
            // Return type: if the impl's return is a generic var
            // (ret_var_name set), any source return binds; otherwise it
            // must equal the source's return exactly.
            if (entry.ret_var_name == null and ent_ci.ret != src_ret) continue;
            // First match wins for v1; concrete-wins-over-pack already
            // happened by the caller checking concrete first. Multiple
            // overlapping pack impls would be a separate diagnostic
            // (deferred — same module duplicates are caught at registration).
            matched_idx = i;
            break;
        }
        const idx = matched_idx orelse return null;
        const entry = pack_entries.items[idx];

        // Find the `convert` method.
        for (entry.methods) |m| {
            if (std.mem.eql(u8, m.name, "convert")) {
                return .{ .entry = entry, .convert_fd = m, .src_params = src_params, .src_ret = src_ret };
            }
        }
        return null;
    }

    // ── Registration ────────────────────────────────────────────────────

    pub fn registerProtocolDecl(self: ProtocolResolver, pd: *const ast.ProtocolDecl) void {
        if (self.l.registered_protocol_decls.contains(pd)) return;
        self.l.registered_protocol_decls.put(pd, {}) catch @panic("out of memory");

        // Decision 4 soft-convention warning: a type-arg and a method (the
        // "runtime accessor" namespace — protocols have no fields) sharing a
        // name is allowed, but `..pack.<name>` then resolves by *position*
        // rather than by precedence, which surprises readers. Alert at decl.
        for (pd.type_params) |tp| {
            for (pd.methods) |m| {
                if (std.mem.eql(u8, tp.name, m.name)) {
                    if (self.l.diagnostics) |diags| {
                        diags.addFmt(.warn, null, "protocol '{s}' declares type-arg and method both named '{s}'; `..pack.{s}` resolves by position (type-arg in type position, method in value position)", .{ pd.name, tp.name, tp.name });
                    }
                }
            }
        }

        // Parameterised protocols are compile-time-only — no vtable, no boxed
        // instance struct. Methods reference unbound type params (e.g.
        // `convert :: () -> Target`) that only get a concrete TypeId per
        // (Source, Target) pair at xx resolution time. Stash the AST so
        // `param_impl_map` lookup can resolve method signatures lazily.
        if (pd.type_params.len > 0) {
            self.l.program_index.protocol_ast_map.put(pd.name, pd) catch {};
            return;
        }

        const table = &self.l.module.types;
        const name_id = table.internString(pd.name);

        var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;

        // Field 0: ctx: *void. Field 1: __type_id — the concrete type's
        // TypeId, stamped at erasure (RTTI, Agra's Option-B ruling). The
        // {ctx, __type_id} prefix is byte-identical to an `any`
        // {data, type_id}, so downcasts and the protocol type switch read
        // the prefix through the any machinery. Dunder name: a protocol
        // METHOD named `type_id` must not collide (same reason as
        // `__vtable`); the public spelling is ProtocolRaw's `type_id`.
        const void_ptr_ty = table.ptrTo(.void);
        fields.append(self.l.alloc, .{
            .name = table.internString("ctx"),
            .ty = void_ptr_ty,
        }) catch unreachable;
        fields.append(self.l.alloc, .{
            .name = table.internString("__type_id"),
            .ty = .type_value,
        }) catch unreachable;

        if (pd.is_inline) {
            // One fn-ptr field per DISPATCHABLE protocol method (Era-2:
            // a method whose signature mentions `Self` past the receiver
            // has no slot — it is only callable through a generic bound).
            for (pd.methods) |method| {
                if (program_index_mod.protocolMethodSelfOccurrence(method) != null) continue;
                fields.append(self.l.alloc, .{
                    .name = table.internString(method.name),
                    .ty = void_ptr_ty, // fn ptrs are opaque pointers
                }) catch unreachable;
            }
        } else {
            // Vtable pointer
            fields.append(self.l.alloc, .{
                .name = table.internString("__vtable"),
                .ty = void_ptr_ty,
            }) catch unreachable;
        }

        const struct_info: types.TypeInfo = .{ .@"struct" = .{ .name = name_id, .fields = fields.items, .is_protocol = true } };
        const decl_key: *const anyopaque = @ptrCast(pd);
        const nominal_id: u32 = if (table.type_decl_tids.get(decl_key)) |existing|
            Lowering.nominalIdOf(table.get(existing))
        else
            self.l.shadowNominalId(name_id);
        const protocol_ty = self.l.internNamedTypeDecl(decl_key, name_id, struct_info, nominal_id);

        // Build protocol method info for dispatch. Resolve each method's
        // param/return type NAMES in the protocol's OWN declaring module
        // (`pd.source_file`, stamped by `resolveImports`), via the
        // visibility-aware stateful resolver — NOT the flat, visibility-unaware
        // `type_bridge.resolveAstType`. The flat lookup picks the WRONG author
        // when the type name collides across modules (issue 0132: the user's
        // `Event` enum vs the stdlib `event.Event` struct pulled in by
        // `modules/std.sx`). This mirrors the parameterized-protocol path
        // (`instantiateParamProtocol`, lower/protocol.zig) and concrete-fn
        // signatures, which already pin to the defining module. `Self` short-
        // circuits to `*void` before the leaf, as before. `pd.source_file ==
        // null` (synthesized decl) falls back to the current context.
        var method_infos = std.ArrayList(ProtocolMethodInfo).empty;
        for (pd.methods) |method| {
            var ptypes = std.ArrayList(TypeId).empty;
            for (method.params) |p| {
                const pty = blk: {
                    if (p.data == .type_expr and std.mem.eql(u8, p.data.type_expr.name, "Self")) {
                        break :blk void_ptr_ty;
                    }
                    break :blk self.l.resolveTypeInSource(pd.source_file, p);
                };
                ptypes.append(self.l.alloc, pty) catch unreachable;
            }
            const ret = if (method.return_type) |rt| blk: {
                if (rt.data == .type_expr and std.mem.eql(u8, rt.data.type_expr.name, "Self")) {
                    break :blk void_ptr_ty;
                }
                break :blk self.l.resolveTypeInSource(pd.source_file, rt);
            } else .void;
            const self_occ = program_index_mod.protocolMethodSelfOccurrence(method);
            method_infos.append(self.l.alloc, .{
                .name = method.name,
                .param_types = self.l.alloc.dupe(TypeId, ptypes.items) catch unreachable,
                .ret_type = ret,
                .dispatchable = self_occ == null,
                .self_param = if (self_occ) |occ| occ.param_name else null,
            }) catch unreachable;
        }
        const protocol_info: ProtocolDeclInfo = .{
            .name = pd.name,
            .is_inline = pd.is_inline,
            .ownership = if (pd.is_identity) .identity else .value_own,
            .methods = self.l.alloc.dupe(ProtocolMethodInfo, method_infos.items) catch unreachable,
        };
        self.l.protocol_info_by_type.put(protocol_ty, protocol_info) catch @panic("out of memory");
        self.l.protocol_ast_by_type.put(protocol_ty, pd) catch @panic("out of memory");
        // Compatibility/template discovery maps remain name-keyed. Runtime
        // dispatch and ABI classification use the TypeId-keyed maps above.
        if (!self.l.program_index.protocol_decl_map.contains(pd.name))
            self.l.program_index.protocol_decl_map.put(pd.name, protocol_info) catch {};
        if (!self.l.program_index.protocol_ast_map.contains(pd.name))
            self.l.program_index.protocol_ast_map.put(pd.name, pd) catch {};

        // For vtable protocols, create the vtable struct type — one slot per
        // DISPATCHABLE method (Era-2), same filter as the #inline field list.
        if (!pd.is_inline) {
            var vtable_fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
            for (pd.methods) |method| {
                if (program_index_mod.protocolMethodSelfOccurrence(method) != null) continue;
                vtable_fields.append(self.l.alloc, .{
                    .name = table.internString(method.name),
                    .ty = void_ptr_ty,
                }) catch unreachable;
            }
            var vtable_name_buf: [128]u8 = undefined;
            const vtable_name = std.fmt.bufPrint(&vtable_name_buf, "__{s}__Vtable", .{pd.name}) catch "__Vtable";
            const vtable_name_id = table.internString(vtable_name);
            const vtable_info: types.TypeInfo = .{ .@"struct" = .{ .name = vtable_name_id, .fields = vtable_fields.items } };
            const vtable_ty = table.intern(vtable_info);
            self.l.protocol_vtable_type_map.put(pd.name, vtable_ty) catch {};
            self.l.protocol_vtable_type_by_type.put(protocol_ty, vtable_ty) catch @panic("out of memory");
        }
    }

    pub fn registerImplBlock(self: ProtocolResolver, ib: *const ast.ImplBlock, is_imported: bool, decl: *const Node) void {
        if (self.l.registered_protocol_impls.contains(ib)) return;
        const source = decl.source_file orelse self.l.current_source_file;
        // Parameterised-protocol impl (e.g. `impl Into(Block) for Closure() -> void`):
        // record into `param_impl_map` for compile-time resolution by `lowerXX`.
        // Methods are NOT registered in fn_ast_map — they're monomorphised lazily
        // per (Source, Target) pair at the xx call site.
        if (ib.protocol_type_args.len > 0) {
            const proto_name = self.canonicalProtocolName(ib.protocol_name, source) orelse return;
            if (!self.concreteParamImplTypesReady(ib, decl)) return;
            self.registerParamImpl(ib, decl, is_imported, proto_name);
            self.l.registered_protocol_impls.put(ib, {}) catch @panic("out of memory");
            return;
        }
        const proto = self.resolveProtocol(ib.protocol_name, source) orelse return;
        const proto_name = proto.name;
        const concrete_ty = self.concreteImplTarget(ib, source);
        // A plain named target with no generic binders is a concrete nominal
        // impl. Its TypeId may not exist yet when the impl precedes the struct
        // declaration, so leave the impl unregistered and let scanDecls retry
        // it after declaration/alias fixpoints settle. Proceeding with a null
        // identity would create name-keyed stubs but permanently omit the
        // exact impl maps (issue 0320).
        if (ib.target_type_params.len == 0 and ib.target_type.len > 0 and concrete_ty == null) return;
        if (concrete_ty) |cty| {
            self.l.protocol_impl_decls.put(self.protocolConcreteKey(proto.ty, proto_name, cty), {}) catch @panic("out of memory");
        }
        // Collect explicitly implemented method names
        var impl_methods = std.StringHashMap(void).init(self.l.alloc);
        defer impl_methods.deinit();
        for (ib.methods) |method_node| {
            if (method_node.data == .fn_decl) {
                const method_fd = &method_node.data.fn_decl;
                const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ ib.target_type, method_fd.name }) catch continue;
                // Compatibility map: keep a coherent first AST/first FuncId
                // winner. Exact protocol dispatch uses the identity map below.
                if (!self.l.program_index.fn_ast_map.contains(qualified)) {
                    self.l.program_index.fn_ast_map.put(qualified, method_fd) catch {};
                    self.l.program_index.import_flags.put(qualified, is_imported) catch {};
                }
                self.l.declareFunction(method_fd, qualified);
                self.recordProtocolImplMethod(proto.ty, proto_name, concrete_ty, method_fd, source, false);
                // Record it as a protocol-impl method so the "declared `!`
                // but never errors" warning skips it: a `!` on a protocol
                // method is part of the contract (e.g. `Io.suspend_raw`), so
                // a conforming impl can't drop it even if its body never raises.
                self.l.impl_method_names.put(qualified, {}) catch {};
                impl_methods.put(method_fd.name, {}) catch {};
            }
        }
        // Synthesize default methods from protocol declaration
        {
            const pd = proto.decl;
            for (pd.methods) |method| {
                if (method.default_body != null and !impl_methods.contains(method.name)) {
                    // Create a synthesized fn_decl for the default method
                    const synth_fd = self.synthesizeDefaultMethod(method, ib.target_type);
                    const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ ib.target_type, method.name }) catch continue;
                    if (!self.l.program_index.fn_ast_map.contains(qualified)) {
                        self.l.program_index.fn_ast_map.put(qualified, synth_fd) catch {};
                        self.l.program_index.import_flags.put(qualified, is_imported) catch {};
                    }
                    // The default body and its protocol-declared parameter
                    // types belong to the protocol module. Register the exact
                    // concrete receiver before declaration so neither stub
                    // creation nor later body lowering text-resolves the
                    // synthetic `self: *Target` in that foreign domain.
                    const default_source: ?[]const u8 = if (method.default_body.?.source_file) |src| src else pd.source_file;
                    if (concrete_ty) |cty| {
                        self.l.protocol_impl_receiver_types.put(synth_fd, self.l.module.types.ptrTo(cty)) catch @panic("out of memory");
                    }
                    const saved_source = self.l.current_source_file;
                    if (default_source) |src| self.l.setCurrentSourceFile(src);
                    self.l.declareFunction(synth_fd, qualified);
                    self.l.setCurrentSourceFile(saved_source);
                    self.recordProtocolImplMethod(proto.ty, proto_name, concrete_ty, synth_fd, default_source, true);
                }
            }
        }
        self.l.registered_protocol_impls.put(ib, {}) catch @panic("out of memory");
    }

    /// Register a parameterised-protocol impl into `param_impl_map`.
    /// Resolves the protocol's type args + the source type, mangles them, and
    /// stashes the impl's method fn_decls for later monomorphisation by
    /// `lowerXX`. Same-module duplicate impls produce a diagnostic here;
    /// cross-module duplicates are detected at the xx resolution site.
    ///
    /// Pack-shaped sources (`Closure(..$args) -> $R`, detected via
    /// `pack_start != null`) are additionally registered into
    /// `param_impl_pack_map` keyed without the source suffix — the matching
    /// site walks that map to bind packs against any concrete closure shape.
    pub fn registerParamImpl(self: ProtocolResolver, ib: *const ast.ImplBlock, decl: *const Node, is_imported: bool, proto_name: []const u8) void {
        const table = &self.l.module.types;
        const source = decl.source_file orelse self.l.current_source_file;
        const saved_source = self.l.current_source_file;
        if (source) |src| self.l.setCurrentSourceFile(src);
        defer self.l.setCurrentSourceFile(saved_source);

        // Resolve the protocol's type-arg list to concrete TypeIds.
        var arg_tys = std.ArrayList(TypeId).empty;
        for (ib.protocol_type_args) |arg_node| {
            const t = self.l.resolveTypeInSource(source, arg_node);
            arg_tys.append(self.l.alloc, t) catch return;
        }

        // Resolve the source type. Parser stores it on `target_type_expr` for
        // parameterised impls (back-compat `target_type` string is kept for
        // simple cases but the canonical form is the TypeExpr).
        const src_ty: TypeId = if (ib.target_type_expr) |te| blk: {
            // Generic/pack impl sources are templates, not concrete nominal
            // leaves. Preserve their binding-aware structural resolver; only
            // concrete sources use the source-aware nominal path below.
            if (typeExprHasGeneric(te))
                break :blk type_bridge.resolveAstType(te, table, &self.l.program_index.type_alias_map, &self.l.program_index.module_const_map);
            break :blk self.l.resolveTypeInSource(source, te);
        } else if (ib.target_type.len > 0) blk: {
            const node: Node = .{ .span = decl.span, .data = .{ .type_expr = .{ .name = ib.target_type } } };
            if (ib.target_type_params.len > 0)
                break :blk type_bridge.resolveAstType(&node, table, &self.l.program_index.type_alias_map, &self.l.program_index.module_const_map);
            break :blk self.l.resolveTypeInSource(source, &node);
        } else return;

        // Mangle into the lookup key.
        var key_buf = std.ArrayList(u8).empty;
        key_buf.appendSlice(self.l.alloc, proto_name) catch return;
        for (arg_tys.items) |t| {
            key_buf.append(self.l.alloc, 0) catch return;
            key_buf.appendSlice(self.l.alloc, self.l.mangleTypeName(t)) catch return;
        }
        const pack_key_len = key_buf.items.len; // proto + args, no src — used for pack map
        key_buf.append(self.l.alloc, 0) catch return;
        key_buf.appendSlice(self.l.alloc, self.l.mangleTypeName(src_ty)) catch return;
        const key = key_buf.items;

        // Collect method fn_decl pointers.
        var methods = std.ArrayList(*const ast.FnDecl).empty;
        for (ib.methods) |method_node| {
            if (method_node.data == .fn_decl) {
                methods.append(self.l.alloc, &method_node.data.fn_decl) catch {};
            }
        }

        const defining_module: []const u8 = source orelse "";
        const entry: Lowering.ParamImplEntry = .{
            .methods = self.l.alloc.dupe(*const ast.FnDecl, methods.items) catch return,
            .source_ty = src_ty,
            .target_args = self.l.alloc.dupe(TypeId, arg_tys.items) catch return,
            .defining_module = defining_module,
            .span = decl.span,
        };

        const gop = self.l.param_impl_map.getOrPut(key) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(Lowering.ParamImplEntry).empty;
        } else {
            // Same-file duplicate is an immediate error. Cross-file overlaps
            // are deferred to the xx resolution site (Phase 5) so the impl
            // surface can be richer than any one file's view.
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing.defining_module, defining_module)) {
                    if (self.l.diagnostics) |diags| {
                        diags.addFmt(.err, decl.span, "duplicate impl '{s}' for source '{s}' in {s}", .{
                            proto_name, self.l.mangleTypeName(src_ty), defining_module,
                        });
                    }
                    return;
                }
            }
        }
        gop.value_ptr.append(self.l.alloc, entry) catch return;

        // Concrete-struct source: also register the impl's methods as
        // `<Source>.<method>` in fn_ast_map so UFCS resolves them (e.g.
        // `xs[i].get()` on a pack element). For a concrete impl like
        // `impl Box(i64) for IntCell`, the method is already fully concrete —
        // nothing to monomorphize, unlike generic/pack sources (which stay
        // lazy in param_impl_map and are handled below).
        {
            const si = table.get(src_ty);
            if (!src_ty.isBuiltin() and si == .@"struct") {
                const src_name = self.l.formatTypeName(src_ty);
                const instance_name = self.paramProtocolInstanceName(proto_name, arg_tys.items);
                // A generic-struct source (`impl VL($R) for Combined($R, ..$Ts)`)
                // registers each method as a TEMPLATE only: its signature
                // references unbound type params (`-> $R`), so declaring it as a
                // standalone function would emit garbage (an unresolved return
                // type). Concrete instances are monomorphized per-erasure by
                // createProtocolThunk via this same fn_ast_map entry.
                const is_generic_src = self.l.program_index.struct_template_map.contains(src_name);
                if (!is_generic_src) {
                    self.l.protocol_impl_decls.put(self.protocolConcreteKey(null, instance_name, src_ty), {}) catch @panic("out of memory");
                }
                for (methods.items) |mfd| {
                    const q = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ src_name, mfd.name }) catch continue;
                    if (!self.l.program_index.fn_ast_map.contains(q)) {
                        self.l.program_index.fn_ast_map.put(q, mfd) catch {};
                        self.l.program_index.import_flags.put(q, is_imported) catch {};
                    }
                    if (!is_generic_src) {
                        self.l.declareFunction(mfd, q);
                        self.recordProtocolImplMethod(null, instance_name, src_ty, mfd, source, false);
                        self.l.impl_method_names.put(q, {}) catch {};
                    }
                }
            }
        }

        // Pack-shaped source: also register in the pack map. The source
        // closure carries `pack_start` set; matching binds the source's
        // tail param types to the pack-name and the source's return to
        // the impl's return-type-var (when the return is generic).
        const src_info = table.get(src_ty);
        if (src_info == .closure and src_info.closure.pack_start != null) {
            const target_expr_node = ib.target_type_expr orelse return;
            if (target_expr_node.data != .closure_type_expr) return;
            const ct = target_expr_node.data.closure_type_expr;
            const pack_var = ct.pack_name orelse return;
            // Extract the return-type-var name if the impl's return is generic.
            // `Closure(...) -> $R` parses with the return-type node carrying
            // `is_generic = true`. Concrete returns leave it null.
            var ret_var: ?[]const u8 = null;
            if (ct.return_type) |rt| {
                if (rt.data == .type_expr and rt.data.type_expr.is_generic) {
                    ret_var = rt.data.type_expr.name;
                }
            }
            const pack_entry: Lowering.PackParamImplEntry = .{
                .methods = self.l.alloc.dupe(*const ast.FnDecl, methods.items) catch return,
                .source_pack_ty = src_ty,
                .target_args = self.l.alloc.dupe(TypeId, arg_tys.items) catch return,
                .defining_module = defining_module,
                .span = decl.span,
                .pack_var_name = self.l.alloc.dupe(u8, pack_var) catch return,
                .ret_var_name = if (ret_var) |rv| (self.l.alloc.dupe(u8, rv) catch return) else null,
            };
            const pack_key = key_buf.items[0..pack_key_len];
            const pack_key_owned = self.l.alloc.dupe(u8, pack_key) catch return;
            const pgop = self.l.param_impl_pack_map.getOrPut(pack_key_owned) catch return;
            if (!pgop.found_existing) {
                pgop.value_ptr.* = std.ArrayList(Lowering.PackParamImplEntry).empty;
            } else {
                for (pgop.value_ptr.items) |existing| {
                    if (std.mem.eql(u8, existing.defining_module, defining_module)) {
                        if (self.l.diagnostics) |diags| {
                            diags.addFmt(.err, decl.span, "duplicate pack impl '{s}' for source '{s}' in {s}", .{
                                proto_name, self.l.mangleTypeName(src_ty), defining_module,
                            });
                        }
                        return;
                    }
                }
            }
            pgop.value_ptr.append(self.l.alloc, pack_entry) catch return;
        }
    }

    /// Synthesize a fn_decl from a protocol default method for a concrete type.
    fn synthesizeDefaultMethod(self: ProtocolResolver, method: ast.ProtocolMethodDecl, target_type: []const u8) *const ast.FnDecl {
        // Build parameter list: self: *TargetType, then the protocol method params
        var params_list = std.ArrayList(ast.Param).empty;
        defer params_list.deinit(self.l.alloc);

        // Add self parameter: self: *TargetType
        const self_type_node = self.l.alloc.create(ast.Node) catch unreachable;
        const pointee_node = self.l.alloc.create(ast.Node) catch unreachable;
        pointee_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = target_type } } };
        self_type_node.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .pointer_type_expr = .{
            .pointee_type = pointee_node,
        } } };
        params_list.append(self.l.alloc, .{
            .name = "self",
            .name_span = .{ .start = 0, .end = 0 },
            .type_expr = self_type_node,
        }) catch unreachable;

        // Add remaining params from the protocol method
        for (method.params, method.param_names) |pty, pname| {
            params_list.append(self.l.alloc, .{
                .name = pname,
                .name_span = .{ .start = 0, .end = 0 },
                .type_expr = pty,
            }) catch unreachable;
        }

        const fd = self.l.alloc.create(ast.FnDecl) catch unreachable;
        fd.* = .{
            .name = method.name,
            .params = self.l.alloc.dupe(ast.Param, params_list.items) catch unreachable,
            .body = method.default_body.?,
            .return_type = method.return_type,
        };
        return fd;
    }
};
