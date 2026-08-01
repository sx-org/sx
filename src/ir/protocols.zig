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

/// Protocol / impl LOOKUP + REGISTRATION, extracted
/// from `Lowering`. Owns:
///   - read-only conformance queries: `getProtocolInfo` (is a type a registered
///     protocol + its method table), `packArgConformsTo` (impl-declaration
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

    /// The key spelling of a protocol DECLARATION: its display name plus a
    /// declaration-identity suffix once another declaration has claimed that
    /// spelling. Every protocol-keyed registry — the decl/ast maps, impl,
    /// thunk and vtable keys, and parameterized instance names — is keyed with
    /// it, so two modules authoring `P` cannot share any of them.
    pub fn protocolIdentityName(self: ProtocolResolver, pd: *const ast.ProtocolDecl) []const u8 {
        return self.l.declIdentityName(pd.name, pd);
    }

    /// Internal runtime name for one parameterized protocol instance. `p_name`
    /// is the declaration's identity name and type arguments use nominal-aware
    /// mangles, so neither two same-spelled protocols nor `P(a.Thing)` and
    /// `P(b.Thing)` can share a protocol type, impl key, thunk set, or vtable.
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
    /// concrete TypeId (inline or another protocol impl), matching
    /// `Type.method` selection without cross-binding display-name collisions.
    pub fn protocolDispatchMethod(self: ProtocolResolver, proto_ty: ?TypeId, p_name: []const u8, ty: TypeId, method: []const u8) ?ProtocolImplMethod {
        if (self.protocolImplMethod(proto_ty, p_name, ty, method)) |exact| return exact;
        if (!self.l.protocol_impl_decls.contains(self.protocolConcreteKey(proto_ty, p_name, ty))) return null;
        const adopted = self.l.plainStructAdoptableMethod(ty, method) orelse return null;
        return .{ .fd = adopted.fd, .concrete = ty, .source = adopted.source, .is_synthesized_default = false };
    }

    fn resolvedProtocolAuthor(self: ProtocolResolver, author: @import("resolver.zig").RawAuthor) ?ResolvedProtocol {
        const terminal = self.l.followAliasChain(author) orelse return null;
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
        return .{ .name = self.protocolIdentityName(pd), .ty = protocol_ty, .decl = pd };
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
            return .{ .name = self.protocolIdentityName(pd), .ty = ty, .decl = pd };
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

    /// The exact PARAMETERIZED protocol declaration a written type head names.
    /// A qualified head (`ns.P(i64)`) selects the namespace's own author; a bare
    /// head selects the visible author (own wins, otherwise a single direct flat
    /// author). Null when the head is not a parameterized protocol — the global
    /// spelling map cannot decide this, since two modules may both author `P`.
    pub fn resolveParamProtocolHead(self: ProtocolResolver, base_name: []const u8, qualified_path: ?[]const u8) ?*const ast.ProtocolDecl {
        const resolved = if (qualified_path) |path| switch (self.l.qualifiedMemberVerdict(path)) {
            .selected => |sel| self.resolvedProtocolAuthor(sel.author),
            .not_qualified, .missing, .ambiguous => null,
        } else self.resolveProtocol(base_name, self.l.current_source_file);
        const pd = (resolved orelse return null).decl;
        return if (pd.type_params.len > 0) pd else null;
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
            self.l.program_index.protocol_ast_map.put(self.protocolIdentityName(pd), pd) catch {};
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
        // A `tagged` value is {ctx, __tag} instead — 16 bytes, always: the
        // dense conformer index replaces the stamped type id, and the
        // concrete id is synthesized through the protocol's tag table.
        const void_ptr_ty = table.ptrTo(.void);
        fields.append(self.l.alloc, .{
            .name = table.internString("ctx"),
            .ty = void_ptr_ty,
        }) catch unreachable;
        fields.append(self.l.alloc, .{
            .name = table.internString(if (pd.kind == .tagged) "__tag" else "__type_id"),
            .ty = if (pd.kind == .tagged) .i64 else .type_value,
        }) catch unreachable;

        if (pd.kind == .tagged) {
            // No third word: dispatch is an outlined switch on the tag,
            // emitted at whole-program link.
        } else if (pd.kind == .@"inline") {
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
            const shape = program_index_mod.protocolMethodSelfShape(self.l.alloc, method);
            var info: ProtocolMethodInfo = .{
                .name = method.name,
                .param_types = self.l.alloc.dupe(TypeId, ptypes.items) catch unreachable,
                .ret_type = ret,
                .dispatchable = self_occ == null,
                .self_param = if (self_occ) |occ| occ.param_name else null,
                .self_params = shape.direct_params,
                .returns_self = shape.direct_return,
                .self_at_depth = shape.at_depth,
                .expand = pd.is_expand or method.is_expand,
            };
            program_index_mod.applyDispatchSignature(self.l.alloc, &info, pd.kind, protocol_ty);
            method_infos.append(self.l.alloc, info) catch unreachable;
        }
        const identity_name = self.protocolIdentityName(pd);
        const protocol_info: ProtocolDeclInfo = .{
            .name = identity_name,
            .kind = pd.kind,
            .ownership = if (pd.is_identity) .identity else .value_own,
            .methods = self.l.alloc.dupe(ProtocolMethodInfo, method_infos.items) catch unreachable,
        };
        self.l.protocol_info_by_type.put(protocol_ty, protocol_info) catch @panic("out of memory");
        self.l.protocol_ast_by_type.put(protocol_ty, pd) catch @panic("out of memory");
        // Template-discovery maps are name-keyed on the DECLARATION identity, so
        // a second author of the same spelling gets its own entry instead of
        // losing to the first. Runtime dispatch and ABI classification use the
        // TypeId-keyed maps above.
        if (!self.l.program_index.protocol_decl_map.contains(identity_name))
            self.l.program_index.protocol_decl_map.put(identity_name, protocol_info) catch {};
        if (!self.l.program_index.protocol_ast_map.contains(identity_name))
            self.l.program_index.protocol_ast_map.put(identity_name, pd) catch {};

        // For vtable protocols, create the vtable struct type — one slot per
        // DISPATCHABLE method (Era-2), same filter as the `inline`-kind field list.
        if (pd.kind != .@"inline" and pd.kind != .tagged) {
            var vtable_fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
            for (pd.methods) |method| {
                if (program_index_mod.protocolMethodSelfOccurrence(method) != null) continue;
                vtable_fields.append(self.l.alloc, .{
                    .name = table.internString(method.name),
                    .ty = void_ptr_ty,
                }) catch unreachable;
            }
            const vtable_name = std.fmt.allocPrint(self.l.alloc, "__{s}__Vtable", .{identity_name}) catch @panic("out of memory while naming a protocol vtable");
            const vtable_name_id = table.internString(vtable_name);
            const vtable_info: types.TypeInfo = .{ .@"struct" = .{ .name = vtable_name_id, .fields = vtable_fields.items } };
            const vtable_ty = table.intern(vtable_info);
            self.l.protocol_vtable_type_map.put(identity_name, vtable_ty) catch {};
            self.l.protocol_vtable_type_by_type.put(protocol_ty, vtable_ty) catch @panic("out of memory");
        }
    }

    /// Import-scoped coherence (§3): one module declaring two impls of a
    /// `(protocol-instantiation, concrete type)` pair. Reported at the first
    /// impl, naming the other; `label` distinguishes the pack-shaped variant.
    fn reportDuplicateImpl(
        self: ProtocolResolver,
        comptime label: []const u8,
        proto_name: []const u8,
        type_name: []const u8,
        module: []const u8,
        first: ast.Span,
        other: ast.Span,
    ) void {
        const diags = self.l.diagnostics orelse return;
        const id = diags.addFmtId(.err, first, "duplicate " ++ label ++ "impl '{s}' for source '{s}' in {s}", .{ proto_name, type_name, module });
        diags.addNoteFmt(id, other, "also implemented here", .{});
    }

    /// Record one declared impl site of a concrete pair. Returns true when the
    /// site duplicates one the same module already declared — it is reported
    /// and dropped, so the cross-module and tagged checks keep seeing at most
    /// one site per module and a same-module pair yields one diagnostic.
    fn recordConcreteImplSite(
        self: ProtocolResolver,
        key: lower.ProtocolConcreteKey,
        proto_name: []const u8,
        concrete: TypeId,
        span: ast.Span,
        source: ?[]const u8,
    ) bool {
        const module = source orelse "";
        const gop = self.l.protocol_impl_sites.getOrPut(key) catch @panic("out of memory");
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |site| {
            const site_module = site.source orelse "";
            if (!std.mem.eql(u8, site_module, module)) continue;
            if (site.span.start == span.start and site.span.end == span.end) return false;
            self.reportDuplicateImpl("", proto_name, self.l.formatTypeName(concrete), module, site.span, span);
            return true;
        }
        gop.value_ptr.append(self.l.alloc, .{ .span = span, .source = source }) catch @panic("out of memory");
        return false;
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
            // Protocols are not concrete types, so they never conform (§10).
            // A curated `inline for` list that names one lands here.
            if (!cty.isBuiltin() and self.l.module.types.get(cty) == .@"struct" and
                self.l.module.types.get(cty).@"struct".is_protocol)
            {
                if (self.l.diagnostics) |d|
                    d.addFmt(.err, decl.span, "'{s}' is a protocol, not a concrete type — an impl target names a type", .{ib.target_type});
                self.l.registered_protocol_impls.put(ib, {}) catch @panic("out of memory");
                return;
            }
            const key = self.protocolConcreteKey(proto.ty, proto_name, cty);
            // A tagged pair's coherence is whole-program and belongs to the
            // conformer fixpoint (lower/tagged.zig), which sees the same-module
            // pair too — reporting it here as well would name it twice.
            const is_tagged = if (proto.ty) |pty| self.l.isTagged(pty) else false;
            if (!is_tagged and self.recordConcreteImplSite(key, proto_name, cty, decl.span, source)) {
                self.l.registered_protocol_impls.put(ib, {}) catch @panic("out of memory");
                return;
            }
            self.l.protocol_impl_decls.put(key, {}) catch @panic("out of memory");
            if (proto.ty) |pty| self.l.recordTaggedImplSite(pty, cty, decl.span, source);
        } else if (proto.ty) |pty| {
            // A template target (`impl P for Box($T)`) names no one conformer:
            // each generic instance the program spells joins the set, so a
            // tagged set with such an impl stays open until publication.
            self.l.noteTemplateTaggedImpl(pty);
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

    /// Issue 0346: an impl block still unregistered after every registration
    /// pass (scan, order retry, body lowering) has an unresolvable protocol
    /// head, type argument, or target — the impl is dead code no consumer can
    /// see (an `xx` site silently degrades to the reinterpret spill). Runs at
    /// the end of `lowerRoot`; walks exactly where registration walked
    /// (top-level decls, plus namespace decls in full-program hosts).
    pub fn diagnoseUnregisteredImpls(self: ProtocolResolver, decls: []const *const Node) void {
        const diags = self.l.diagnostics orelse return;
        for (decls) |decl| {
            switch (decl.data) {
                .impl_block => {
                    const ib = &decl.data.impl_block;
                    if (self.l.registered_protocol_impls.contains(ib)) continue;
                    const source = decl.source_file orelse self.l.current_source_file;
                    const saved = diags.current_source_file;
                    if (source) |src| diags.current_source_file = src;
                    defer diags.current_source_file = saved;
                    if (self.resolveProtocol(ib.protocol_name, source) == null) {
                        diags.addFmt(.err, decl.span, "unknown protocol '{s}' in impl — not declared or imported in this module", .{ib.protocol_name});
                    } else if (ib.protocol_type_args.len > 0) {
                        diags.addFmt(.err, decl.span, "impl '{s}' cannot register: a protocol type argument or the source type does not resolve in this module", .{ib.protocol_name});
                    } else {
                        diags.addFmt(.err, decl.span, "impl '{s}' cannot register: target type '{s}' does not resolve in this module", .{ ib.protocol_name, ib.target_type });
                    }
                },
                .namespace_decl => |ns| if (self.l.main_file != null) self.diagnoseUnregisteredImpls(ns.decls),
                else => {},
            }
        }
    }

/// True when `node` spells one of the impl's own binders rather than a concrete
/// type — `$T` in `impl Series($T) for Buffer($T)`.
fn nodeIsBinder(node: *const ast.Node) bool {
    return node.data == .type_expr and node.data.type_expr.is_generic;
}

/// Record a blanket impl under its protocol name. Only impls with at least one
/// binder among the protocol's type arguments qualify — a fully concrete impl is
/// already findable by its own key.
fn registerGenericParamImpl(
    self: ProtocolResolver,
    ib: *const ast.ImplBlock,
    decl: *const Node,
    proto_name: []const u8,
    defining_module: []const u8,
) void {
    var any_proto_binder = false;
    for (ib.protocol_type_args) |a| {
        if (nodeIsBinder(a)) any_proto_binder = true;
    }
    const target = ib.target_type_expr;
    const target_args: []const *const Node = if (target) |t|
        (if (t.data == .parameterized_type_expr) t.data.parameterized_type_expr.args else &.{})
    else
        &.{};
    var any_target_binder = false;
    for (target_args) |a| {
        if (nodeIsBinder(a)) any_target_binder = true;
    }
    if (!any_proto_binder and !any_target_binder) return;

    // A TAGGED family collects members through whole-program membership rather
    // than this keyed index, so a GENERIC CARRIER whose binder the head never
    // mentions is ordinary there — `impl Series(f32) for Repeat($U)` is one
    // member per instantiated `Repeat`. That exemption covers only that shape.
    const is_tagged = if (self.resolveProtocol(proto_name, decl.source_file)) |rp|
        rp.decl.kind == .tagged
    else
        false;

    // A binder in the protocol arguments with no carrier instantiation to bind it
    // from is unreachable under EITHER machinery: keyed lookup has no binding to
    // read, and membership would be an open-ended family rather than one member
    // per instantiation. Refused for every protocol kind.
    if (any_proto_binder and target_args.len == 0) {
        if (self.l.diagnostics) |d| {
            const id = d.addFmtId(.err, decl.span, "'impl {s}' binds a type parameter the carrier cannot supply", .{proto_name});
            d.addHelpFmt(id, decl.span, null, "a blanket impl's carrier must be an instantiation spelling the same binder, as in 'for Carrier($T)'", .{});
        }
        return;
    }
    if (!is_tagged and any_target_binder and !any_proto_binder) {
        if (self.l.diagnostics) |d| {
            const id = d.addFmtId(.err, decl.span, "'impl {s}' names a generic carrier but no binder among its type arguments", .{proto_name});
            d.addHelpFmt(id, decl.span, null, "spell the carrier's binder in the protocol arguments too ('impl {s}($T) for …($T)'), or give the carrier a concrete instantiation", .{proto_name});
        }
        return;
    }
    const template = target.?.data.parameterized_type_expr.name;

    // Where each protocol argument's binder sits in the CARRIER's argument list.
    // Resolution has to be positional: an impl author spells their own binder
    // name (`$U`) and cannot be expected to know the template's (`$T`).
    var positions = std.ArrayList(?usize).empty;
    for (ib.protocol_type_args) |a| {
        var found: ?usize = null;
        if (nodeIsBinder(a)) {
            const want = a.data.type_expr.name;
            for (target_args, 0..) |t, i| {
                if (nodeIsBinder(t) and std.mem.eql(u8, t.data.type_expr.name, want)) {
                    found = i;
                    break;
                }
            }
            if (found == null) {
                if (self.l.diagnostics) |d| {
                    const id = d.addFmtId(.err, decl.span, "'impl {s}' binds '${s}', which its carrier never spells", .{ proto_name, want });
                    d.addHelpFmt(id, decl.span, null, "every binder in the protocol arguments must appear in the carrier's arguments", .{});
                }
                return;
            }
        }
        positions.append(self.l.alloc, found) catch return;
    }

    var methods = std.ArrayList(*const ast.FnDecl).empty;
    for (ib.methods) |m| {
        if (m.data == .fn_decl) methods.append(self.l.alloc, &m.data.fn_decl) catch {};
    }
    const entry: Lowering.GenericParamImplEntry = .{
        .methods = self.l.alloc.dupe(*const ast.FnDecl, methods.items) catch return,
        .arg_nodes = self.l.alloc.dupe(*const ast.Node, ib.protocol_type_args) catch return,
        .arg_positions = self.l.alloc.dupe(?usize, positions.items) catch return,
        .target_template = template,
        .target_arg_nodes = self.l.alloc.dupe(*const ast.Node, target_args) catch return,
        .defining_module = defining_module,
        .span = decl.span,
        .block = ib,
    };
    const gop = self.l.param_impl_generic_map.getOrPut(proto_name) catch return;
    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Lowering.GenericParamImplEntry).empty;
    for (gop.value_ptr.items) |existing| {
        if (existing.block == ib) return;
    }
    gop.value_ptr.append(self.l.alloc, entry) catch return;
}

/// Is there ANY parameterized impl of `proto_name` at `arg_tys` for `src_ty`?
/// The one conformance question for a parameterized protocol, in the specificity
/// order: the concrete key first, a blanket impl only if nothing concrete matches.
pub fn paramImplExists(
    self: ProtocolResolver,
    proto_name: []const u8,
    arg_tys: []const TypeId,
    src_ty: TypeId,
) bool {
    return paramImplKind(self, proto_name, arg_tys, src_ty) != .none;
}

/// Which KIND of parameterized impl answers, in the specificity order. Callers
/// that can only consume one kind (a build sink needs a substituted method body,
/// which a blanket impl does not yet have) branch on this instead of re-deriving
/// the lookup.
pub const ParamImplKind = enum { none, concrete, blanket };

pub fn paramImplKind(
    self: ProtocolResolver,
    proto_name: []const u8,
    arg_tys: []const TypeId,
    src_ty: TypeId,
) ParamImplKind {
    var key_buf = std.ArrayList(u8).empty;
    defer key_buf.deinit(self.l.alloc);
    key_buf.appendSlice(self.l.alloc, proto_name) catch return .none;
    for (arg_tys) |t| {
        key_buf.append(self.l.alloc, 0) catch return .none;
        key_buf.appendSlice(self.l.alloc, self.l.mangleTypeName(t)) catch return .none;
    }
    key_buf.append(self.l.alloc, 0) catch return .none;
    key_buf.appendSlice(self.l.alloc, self.l.mangleTypeName(src_ty)) catch return .none;
    const concrete = self.l.param_impl_map.contains(key_buf.items);
    const blanket = matchGenericParamImpl(self, proto_name, arg_tys, src_ty);
    // Same carrier covered twice, once concretely and once by a blanket impl.
    // Method dispatch does not follow the specificity order, so which body runs
    // would be decided by nothing the source states.
    if (concrete and blanket) {
        reportOverlappingImpls(self, proto_name, arg_tys, src_ty);
        return .concrete;
    }
    if (concrete) return .concrete;
    if (blanket) return .blanket;
    return .none;
}

/// Refuse a concrete/blanket overlap on one carrier, once per (protocol,
/// arguments, carrier).
fn reportOverlappingImpls(
    self: ProtocolResolver,
    proto_name: []const u8,
    arg_tys: []const TypeId,
    src_ty: TypeId,
) void {
    const d = self.l.diagnostics orelse return;
    var key = std.ArrayList(u8).empty;
    key.appendSlice(self.l.alloc, proto_name) catch return;
    for (arg_tys) |t| {
        key.append(self.l.alloc, 0) catch return;
        key.appendSlice(self.l.alloc, self.l.mangleTypeName(t)) catch return;
    }
    key.append(self.l.alloc, 0) catch return;
    key.appendSlice(self.l.alloc, self.l.mangleTypeName(src_ty)) catch return;
    const gop = self.l.reported_impl_overlaps.getOrPut(key.items) catch return;
    if (gop.found_existing) return;
    const entries = self.l.param_impl_generic_map.get(proto_name) orelse return;
    const span = if (entries.items.len > 0) entries.items[0].span else ast.Span{ .start = 0, .end = 0 };
    const id = d.addFmtId(.err, span, "'{s}' has both a concrete and a blanket 'impl {s}' — which one applies is not stated by either", .{ self.l.formatTypeName(src_ty), proto_name });
    d.addHelpFmt(id, span, null, "drop one of them: a blanket impl covers every instantiation of its carrier, so a concrete impl for the same one is a second answer", .{});
}

/// Does a blanket impl of `proto_name` cover `src_ty` at `arg_tys`?
///
/// The source instantiation carries its own template name and type-parameter
/// bindings, so matching is: same template, then every protocol argument the
/// impl wrote must resolve — a binder through those bindings, anything else
/// concretely — to the argument the request asked for.
pub fn matchGenericParamImpl(
    self: ProtocolResolver,
    proto_name: []const u8,
    arg_tys: []const TypeId,
    src_ty: TypeId,
) bool {
    const entries = self.l.param_impl_generic_map.get(proto_name) orelse return false;
    const src_name = self.l.mangleTypeName(src_ty);
    const template = self.l.struct_instance_template.get(src_name) orelse return false;
    const binds = self.l.struct_instance_bindings.getPtr(src_name) orelse return false;
    // The template's own parameter names, which is what the instantiation keyed
    // its bindings by.
    const tmpl_decl = self.l.program_index.struct_template_map.get(template) orelse return false;
    for (entries.items) |entry| {
        if (entry.arg_nodes.len != arg_tys.len) continue;
        if (!std.mem.eql(u8, entry.target_template, template)) continue;
        if (entry.target_arg_nodes.len != tmpl_decl.type_params.len) continue;
        if (!carrierMatches(self, entry, tmpl_decl, binds)) continue;
        var all = true;
        for (entry.arg_nodes, entry.arg_positions, arg_tys) |node, pos, want| {
            const got: TypeId = if (pos) |p| blk: {
                if (p >= tmpl_decl.type_params.len) break :blk .unresolved;
                break :blk binds.get(tmpl_decl.type_params[p].name) orelse .unresolved;
            } else self.l.resolveTypeArg(node);
            if (got != want) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

/// The method a BLANKET impl supplies for `carrier`, with the impl's own binders
/// bound to what the carrier's instantiation gives them (`$T` → `Drawable` for
/// `impl @BuildSink($T) for Bag($T)` at `Bag(Drawable)`).
///
/// Dispatch needs both halves: the declaration to call, and those bindings —
/// without them the method's signature still spells `$T` and monomorphization
/// would stamp an unresolved type.
pub const BlanketMethod = struct {
    fd: *const ast.FnDecl,
    /// Impl binder name → concrete type, to seed the monomorphization with.
    bindings: std.StringHashMap(TypeId),
    defining_module: ?[]const u8,
};

pub fn blanketMethod(
    self: ProtocolResolver,
    proto_name: []const u8,
    arg_tys: []const TypeId,
    carrier: TypeId,
    method: []const u8,
) ?BlanketMethod {
    const entries = self.l.param_impl_generic_map.get(proto_name) orelse return null;
    const src_name = self.l.mangleTypeName(carrier);
    const template = self.l.struct_instance_template.get(src_name) orelse return null;
    const binds = self.l.struct_instance_bindings.getPtr(src_name) orelse return null;
    const tmpl_decl = self.l.program_index.struct_template_map.get(template) orelse return null;
    for (entries.items) |entry| {
        if (entry.arg_nodes.len != arg_tys.len) continue;
        if (!std.mem.eql(u8, entry.target_template, template)) continue;
        if (entry.target_arg_nodes.len != tmpl_decl.type_params.len) continue;
        if (!carrierMatches(self, entry, tmpl_decl, binds)) continue;
        var all = true;
        for (entry.arg_nodes, entry.arg_positions, arg_tys) |node, pos, want| {
            const got: TypeId = if (pos) |p| blk: {
                if (p >= tmpl_decl.type_params.len) break :blk .unresolved;
                break :blk binds.get(tmpl_decl.type_params[p].name) orelse .unresolved;
            } else self.l.resolveTypeArg(node);
            if (got != want) {
                all = false;
                break;
            }
        }
        if (!all) continue;
        for (entry.methods) |fd| {
            if (!std.mem.eql(u8, fd.name, method)) continue;
            // The impl's binders, read off the carrier's own instantiation by
            // position — the same reading `carrierMatches` just accepted.
            var seed = std.StringHashMap(TypeId).init(self.l.alloc);
            for (entry.target_arg_nodes, 0..) |node, i| {
                if (!nodeIsBinder(node)) continue;
                const bound = binds.get(tmpl_decl.type_params[i].name) orelse continue;
                seed.put(node.data.type_expr.name, bound) catch {};
            }
            return .{ .fd = fd, .bindings = seed, .defining_module = entry.defining_module };
        }
    }
    return null;
}

/// Does the CARRIER the impl spelled describe this instantiation?
///
/// A concrete slot constrains the impl just as a binder does: `for Map2(i64, $W)`
/// covers only instantiations whose first argument is `i64`. A binder repeated
/// across slots additionally has to bind consistently.
fn carrierMatches(
    self: ProtocolResolver,
    entry: Lowering.GenericParamImplEntry,
    tmpl_decl: anytype,
    binds: *const std.StringHashMap(TypeId),
) bool {
    var seen = std.StringHashMap(TypeId).init(self.l.alloc);
    defer seen.deinit();
    for (entry.target_arg_nodes, 0..) |node, i| {
        const bound = binds.get(tmpl_decl.type_params[i].name) orelse return false;
        if (nodeIsBinder(node)) {
            const name = node.data.type_expr.name;
            const gop = seen.getOrPut(name) catch return false;
            if (gop.found_existing) {
                if (gop.value_ptr.* != bound) return false;
            } else {
                gop.value_ptr.* = bound;
            }
            continue;
        }
        if (self.l.resolveTypeArg(node) != bound) return false;
    }
    return true;
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
            .block = ib,
        };

        // A blanket impl also lands in the generic map: its concrete key above
        // mangles binders, which no request can ever spell, so that key alone
        // would make the impl unfindable.
        registerGenericParamImpl(self, ib, decl, proto_name, defining_module);

        const gop = self.l.param_impl_map.getOrPut(key) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(Lowering.ParamImplEntry).empty;
        } else {
            // Same-file duplicate is an immediate error. Cross-file overlaps
            // are deferred to the xx resolution site so the impl
            // surface can be richer than any one file's view.
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing.defining_module, defining_module)) {
                    self.reportDuplicateImpl("", proto_name, self.l.mangleTypeName(src_ty), defining_module, existing.span, decl.span);
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
                        self.reportDuplicateImpl("pack ", proto_name, self.l.mangleTypeName(src_ty), defining_module, existing.span, decl.span);
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
