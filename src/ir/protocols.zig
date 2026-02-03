const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const type_bridge = @import("type_bridge.zig");
const lower = @import("lower.zig");
const program_index_mod = @import("program_index.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;
const ProtocolDeclInfo = program_index_mod.ProtocolDeclInfo;
const ProtocolMethodInfo = program_index_mod.ProtocolMethodInfo;

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
        if (info != .@"struct") return null;
        const name = self.l.module.types.getString(info.@"struct".name);
        return self.l.program_index.protocol_decl_map.get(name);
    }

    /// Have the thunks for (protocol `p_name`, concrete `ty`) been materialized?
    /// `protocol_thunk_map` is populated lazily when a protocol VALUE is created
    /// with `xx`, so this answers "has erasure already happened for this pair".
    pub fn hasImplPlain(self: ProtocolResolver, p_name: []const u8, ty: TypeId) bool {
        const ty_name = self.l.formatTypeName(ty);
        const thunk_key = std.fmt.allocPrint(self.l.alloc, "{s}\x00{s}", .{ p_name, ty_name }) catch return false;
        return self.l.protocol_thunk_map.contains(thunk_key);
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
        // Arg already erased to the protocol struct itself (e.g. `xx a`).
        if (!ty.isBuiltin()) {
            const info = self.l.module.types.get(ty);
            if (info == .@"struct" and info.@"struct".is_protocol and
                std.mem.eql(u8, self.l.module.types.getString(info.@"struct".name), p_name)) return true;
        }
        const pd = self.l.program_index.protocol_ast_map.get(p_name) orelse return false;
        if (pd.type_params.len > 0) {
            const prefix = std.fmt.allocPrint(self.l.alloc, "{s}\x00", .{p_name}) catch return false;
            const suffix = std.fmt.allocPrint(self.l.alloc, "\x00{s}", .{self.l.mangleTypeName(ty)}) catch return false;
            var it = self.l.param_impl_map.keyIterator();
            while (it.next()) |k| {
                if (std.mem.startsWith(u8, k.*, prefix) and std.mem.endsWith(u8, k.*, suffix)) return true;
            }
            return false;
        }
        // Non-parameterised: require each non-default method as `<ty>.<m>`.
        const ty_name = self.l.formatTypeName(ty);
        for (pd.methods) |m| {
            if (m.default_body != null) continue;
            const q = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ ty_name, m.name }) catch return false;
            if (!self.l.program_index.fn_ast_map.contains(q)) return false;
        }
        return true;
    }

    // ── Thunk / impl PLANNING (lookup only; emission stays in Lowering) ──

    /// The dispatch method table for protocol `proto_name` — i.e. exactly which
    /// methods `getOrCreateThunks` must materialize a thunk for. Null if the
    /// name isn't a registered (non-parameterised) protocol.
    pub fn protocolMethodInfos(self: ProtocolResolver, proto_name: []const u8) ?[]const ProtocolMethodInfo {
        const pd = self.l.program_index.protocol_decl_map.get(proto_name) orelse return null;
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
        const id = if (table.findByName(name_id)) |existing| existing else table.intern(struct_info);
        table.updatePreservingKey(id, struct_info);

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
        self.l.program_index.protocol_decl_map.put(pd.name, .{
            .name = pd.name,
            .is_inline = pd.is_inline,
            .ownership = if (pd.is_identity) .identity else .value_own,
            .methods = self.l.alloc.dupe(ProtocolMethodInfo, method_infos.items) catch unreachable,
        }) catch {};
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
        }
    }

    pub fn registerImplBlock(self: ProtocolResolver, ib: *const ast.ImplBlock, is_imported: bool, decl: *const Node) void {
        // Parameterised-protocol impl (e.g. `impl Into(Block) for Closure() -> void`):
        // record into `param_impl_map` for compile-time resolution by `lowerXX`.
        // Methods are NOT registered in fn_ast_map — they're monomorphised lazily
        // per (Source, Target) pair at the xx call site.
        if (ib.protocol_type_args.len > 0) {
            self.registerParamImpl(ib, decl, is_imported);
            return;
        }
        // Collect explicitly implemented method names
        var impl_methods = std.StringHashMap(void).init(self.l.alloc);
        defer impl_methods.deinit();
        for (ib.methods) |method_node| {
            if (method_node.data == .fn_decl) {
                const method_fd = &method_node.data.fn_decl;
                const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ ib.target_type, method_fd.name }) catch continue;
                self.l.program_index.fn_ast_map.put(qualified, method_fd) catch {};
                self.l.program_index.import_flags.put(qualified, is_imported) catch {};
                self.l.declareFunction(method_fd, qualified);
                // Record it as a protocol-impl method so the "declared `!`
                // but never errors" warning skips it: a `!` on a protocol
                // method is part of the contract (e.g. `Io.suspend_raw`), so
                // a conforming impl can't drop it even if its body never raises.
                self.l.impl_method_names.put(qualified, {}) catch {};
                impl_methods.put(method_fd.name, {}) catch {};
            }
        }
        // Synthesize default methods from protocol declaration
        if (self.l.program_index.protocol_ast_map.get(ib.protocol_name)) |pd| {
            for (pd.methods) |method| {
                if (method.default_body != null and !impl_methods.contains(method.name)) {
                    // Create a synthesized fn_decl for the default method
                    const synth_fd = self.synthesizeDefaultMethod(method, ib.target_type);
                    const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ ib.target_type, method.name }) catch continue;
                    self.l.program_index.fn_ast_map.put(qualified, synth_fd) catch {};
                    self.l.program_index.import_flags.put(qualified, is_imported) catch {};
                    self.l.declareFunction(synth_fd, qualified);
                }
            }
        }
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
    pub fn registerParamImpl(self: ProtocolResolver, ib: *const ast.ImplBlock, decl: *const Node, is_imported: bool) void {
        const table = &self.l.module.types;

        // Resolve the protocol's type-arg list to concrete TypeIds.
        var arg_tys = std.ArrayList(TypeId).empty;
        for (ib.protocol_type_args) |arg_node| {
            const t = type_bridge.resolveAstType(arg_node, table, &self.l.program_index.type_alias_map, &self.l.program_index.module_const_map);
            arg_tys.append(self.l.alloc, t) catch return;
        }

        // Resolve the source type. Parser stores it on `target_type_expr` for
        // parameterised impls (back-compat `target_type` string is kept for
        // simple cases but the canonical form is the TypeExpr).
        const src_ty: TypeId = if (ib.target_type_expr) |te|
            type_bridge.resolveAstType(te, table, &self.l.program_index.type_alias_map, &self.l.program_index.module_const_map)
        else if (ib.target_type.len > 0)
            type_bridge.resolveAstType(&.{ .span = decl.span, .data = .{ .type_expr = .{ .name = ib.target_type } } }, table, &self.l.program_index.type_alias_map, &self.l.program_index.module_const_map)
        else
            return;

        // Mangle into the lookup key.
        var key_buf = std.ArrayList(u8).empty;
        key_buf.appendSlice(self.l.alloc, ib.protocol_name) catch return;
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

        const defining_module: []const u8 = self.l.current_source_file orelse "";
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
                            ib.protocol_name, self.l.mangleTypeName(src_ty), defining_module,
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
                // A generic-struct source (`impl VL($R) for Combined($R, ..$Ts)`)
                // registers each method as a TEMPLATE only: its signature
                // references unbound type params (`-> $R`), so declaring it as a
                // standalone function would emit garbage (an unresolved return
                // type). Concrete instances are monomorphized per-erasure by
                // createProtocolThunk via this same fn_ast_map entry.
                const is_generic_src = self.l.program_index.struct_template_map.contains(src_name);
                for (methods.items) |mfd| {
                    const q = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ src_name, mfd.name }) catch continue;
                    if (self.l.program_index.fn_ast_map.contains(q)) continue; // first impl wins
                    self.l.program_index.fn_ast_map.put(q, mfd) catch {};
                    self.l.program_index.import_flags.put(q, is_imported) catch {};
                    if (!is_generic_src) self.l.declareFunction(mfd, q);
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
                                ib.protocol_name, self.l.mangleTypeName(src_ty), defining_module,
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
