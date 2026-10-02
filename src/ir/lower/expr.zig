const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const mod_mod = @import("../module.zig");
const type_bridge = @import("../type_bridge.zig");
const program_index_mod = @import("../program_index.zig");
const unescape = @import("../../unescape.zig");
const literal_fields = @import("../../literal_fields.zig");
const contracts = @import("../../contracts.zig");
const errors = @import("../../errors.zig");
const imports_mod = @import("../../imports.zig");
const TypeResolver = @import("../type_resolver.zig").TypeResolver;
const CallResolver = @import("../calls.zig").CallResolver;

const TypeId = types.TypeId;
const StringId = types.StringId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;
const binOpSymbol = Lowering.binOpSymbol;
const exprIsFailable = Lowering.exprIsFailable;
const headNameOfCallee = Lowering.headNameOfCallee;
const StructConstInfo = Lowering.StructConstInfo;

/// Refuse a `void` element in an aggregate slot that holds a value. `{}` is the
/// void value, so a `void` slot legitimately takes one (`.{ {}, 9 }` for a
/// `Tuple(void, i32)`); every other slot would insert `void` into the aggregate
/// and fail LLVM verification. The caller substitutes a zero of the slot type.
pub fn refuseVoidElement(self: *Lowering, src_ty: TypeId, slot_ty: TypeId, field: ?StringId, index: usize, span: ast.Span) bool {
    if (src_ty != .void or slot_ty == .void or slot_ty == .unresolved) return false;
    if (self.diagnostics) |d| {
        const id = if (field) |f|
            d.addFmtId(.err, span, "field '{s}' cannot take 'void' — this expression produces no value", .{self.module.types.getString(f)})
        else
            d.addFmtId(.err, span, "element {d} cannot take 'void' — this expression produces no value", .{index});
        d.addHelpFmt(id, span, null, "call it as a statement instead of using its result", .{});
    }
    return true;
}

const LoweredLiteralInitializer = union(enum) {
    value: Ref,
    spread: []LiteralSpreadField,
};
const InferredLiteral = struct { ty: TypeId, initializers: []const LoweredLiteralInitializer };

/// The type a literal's contributions route into, or — while its instance is
/// still being inferred — the template it instantiates.
const LiteralOwner = union(enum) { ty: TypeId, template: []const u8 };

fn routeLiteralContribution(self: *Lowering, route: *literal_fields.Typed, name: ?[]const u8, origin: literal_fields.Origin, span: ast.Span, owner: LiteralOwner) ?usize {
    return route.contribute(name, origin) catch |err| {
        if ((err == error.UnknownField or err == error.TooManyValues) and self.externalErrorsExist()) return null;
        const type_name = switch (owner) {
            .ty => |ty| self.formatTypeName(ty),
            .template => |template| template,
        };
        if (self.diagnostics) |d| switch (err) {
            error.UnknownField => d.addFmt(.err, span, "field '{s}' not found on type '{s}'", .{ name.?, type_name }),
            error.TooManyValues => d.addFmt(.err, span, "positional initializer {d} exceeds the {d} fields of '{s}'", .{ route.position - 1, route.names.len, type_name }),
            error.UnnamedAfterNamed => d.add(.err, "unnamed contribution after a named field", span),
            error.DirectCollision => d.addFmt(.err, span, "field '{s}' already initialized by a directly written value", .{name.?}),
            error.DuplicateName => d.addFmt(.err, span, "field '{s}' initialized twice", .{name.?}),
        };
        return null;
    };
}

pub const StructLiteralIndices = struct {
    route: literal_fields.Typed,
    ty: TypeId,

    pub fn init(self: *Lowering, sl: *const ast.StructLiteral, ty: TypeId) StructLiteralIndices {
        const fields = self.getStructFields(ty);
        const names = self.alloc.alloc([]const u8, fields.len) catch unreachable;
        for (fields, names) |field, *name| name.* = self.module.types.getString(field.name);
        const layout: literal_fields.Typed.Layout = layout: {
            if (sl.struct_name == null and sl.type_expr == null and self.module.types.isAnonStruct(ty)) {
                for (names) |name| {
                    if (literal_fields.spreadName(name) == null) break :layout .anonymous;
                }
            }
            break :layout .declaration;
        };
        return .{ .route = literal_fields.Typed.init(self.alloc, names, layout), .ty = ty };
    }

    pub fn deinit(self: *StructLiteralIndices, alloc: std.mem.Allocator) void {
        alloc.free(self.route.names);
        self.route.deinit(alloc);
    }

    pub fn plain(self: *StructLiteralIndices, l: *Lowering, fi: ast.StructFieldInit) ?u32 {
        const name = self.route.plainName(fi.name, fi.was_shorthand);
        return self.contribute(l, name, .direct, fi.value.span);
    }

    pub fn spread(self: *StructLiteralIndices, l: *Lowering, name: ?[]const u8, span: ast.Span) ?u32 {
        return self.contribute(l, name, .spread, span);
    }

    fn contribute(self: *StructLiteralIndices, l: *Lowering, name: ?[]const u8, origin: literal_fields.Origin, span: ast.Span) ?u32 {
        const index = routeLiteralContribution(l, &self.route, name, origin, span, .{ .ty = self.ty }) orelse return null;
        if (name) |n| _ = l.mentionField(self.ty, n, span);
        return @intCast(index);
    }
};

fn bindGenericLiteralField(self: *Lowering, tmpl: *const program_index_mod.StructTemplate, k: usize, arg_ty: TypeId, tb: *std.StringHashMap(TypeId), diagnostic: ?struct { bound_by: *std.StringHashMap([]const u8), span: ast.Span }) bool {
    if (arg_ty == .unresolved) return false;
    const node = tmpl.field_type_nodes[k];
    var ok = true;
    for (tmpl.type_params) |tp| {
        if (!self.matchTypeParam(node, tp.name)) continue;
        const ety = self.extractTypeParam(node, arg_ty, tp.name) orelse continue;
        if (tb.get(tp.name)) |prev| {
            if (prev != ety) {
                if (diagnostic) |context| {
                    if (self.diagnostics) |d| d.addFmt(.err, context.span, "'{s}' binds '${s}' to '{s}', but '{s}' bound it to '{s}'", .{
                        tmpl.field_names[k], tp.name, self.formatTypeName(ety), context.bound_by.get(tp.name) orelse "an earlier field", self.formatTypeName(prev),
                    });
                }
                ok = false;
            }
        } else {
            tb.put(tp.name, ety) catch unreachable;
            if (diagnostic) |context| context.bound_by.put(tp.name, tmpl.field_names[k]) catch unreachable;
        }
    }
    return ok;
}

const literalSpreadName = literal_fields.spreadName;

const LiteralSpreadType = struct { name: ?[]const u8, ty: TypeId };

pub fn literalSpreadTypes(self: *Lowering, operand: *const Node) ?[]LiteralSpreadType {
    const saved_tt = self.target_type;
    self.target_type = null;
    defer self.target_type = saved_tt;
    var fields = std.ArrayList(LiteralSpreadType).empty;
    defer fields.deinit(self.alloc);
    const pack: ?struct { name: []const u8, method: ?[]const u8 } = switch (operand.data) {
        .identifier => |id| .{ .name = id.name, .method = null },
        .field_access => |fa| if (fa.object.data == .identifier)
            .{ .name = fa.object.data.identifier.name, .method = fa.field }
        else
            null,
        else => null,
    };
    if (pack) |p| {
        const element_types = if (self.pack_arg_types) |pat| pat.get(p.name) else null;
        if (element_types) |ts| {
            for (ts, 0..) |element_ty, i| {
                if (p.method == null) {
                    fields.append(self.alloc, .{ .name = null, .ty = element_ty }) catch unreachable;
                    continue;
                }
                const object = self.alloc.create(Node) catch unreachable;
                object.* = .{ .span = operand.span, .data = .{ .identifier = .{ .name = p.name } } };
                const index = self.alloc.create(Node) catch unreachable;
                index.* = .{ .span = operand.span, .data = .{ .int_literal = .{ .value = @intCast(i) } } };
                const element = self.alloc.create(Node) catch unreachable;
                element.* = .{ .span = operand.span, .data = .{ .index_expr = .{ .object = object, .index = index } } };
                const member = self.alloc.create(Node) catch unreachable;
                member.* = .{ .span = operand.span, .data = .{ .field_access = .{ .object = element, .field = p.method.? } } };
                const call = self.alloc.create(Node) catch unreachable;
                call.* = .{ .span = operand.span, .data = .{ .call = .{ .callee = member, .args = &.{} } } };
                fields.append(self.alloc, .{ .name = null, .ty = self.inferExprType(call) }) catch unreachable;
            }
            return fields.toOwnedSlice(self.alloc) catch unreachable;
        }
    }
    const ty = self.inferExprType(operand);
    switch (self.module.types.get(ty)) {
        .@"struct" => {
            const source_fields = type_bridge.structSpreadFields(&self.module.types, ty) catch return null;
            for (source_fields) |field| {
                fields.append(self.alloc, .{ .name = literalSpreadName(self.module.types.getString(field.name)), .ty = field.ty }) catch unreachable;
            }
        },
        .array => |array| {
            for (0..array.length) |_| fields.append(self.alloc, .{ .name = null, .ty = array.element }) catch unreachable;
        },
        else => return null,
    }
    return fields.toOwnedSlice(self.alloc) catch unreachable;
}

pub fn checkPlainInitializerNames(self: *Lowering, sl: *const ast.StructLiteral, ty: TypeId) bool {
    var names = std.StringHashMap(void).init(self.alloc);
    defer names.deinit();
    var valid = true;
    for (sl.field_inits) |fi| {
        const name = fi.name orelse continue;
        if (fi.was_shorthand and ty != .unresolved and self.lookupField(ty, name) == .missing) continue;
        const entry = names.getOrPut(name) catch unreachable;
        if (entry.found_existing) {
            if (self.diagnostics) |d|
                d.addFmt(.err, fi.name_span orelse fi.value.span, "field '{s}' initialized twice", .{name});
            valid = false;
        }
    }
    return valid;
}

/// The instance a bare generic literal names, read without lowering it: each
/// written field's initializer is typed as an expression, and a written lambda
/// is the env its `_{ … }` names. An env-less lambda — a closure the typer
/// names only as far as its annotations reach — leaves the answer null, as
/// does a literal that would be refused. The typer asks this for a literal
/// used as an operand (`Box{ item = 1 }.twice()`).
pub fn genericLiteralType(self: *Lowering, sl: *const ast.StructLiteral, tmpl: *const program_index_mod.StructTemplate) ?TypeId {
    for (tmpl.type_params) |tp| if (!tp.is_type_param) return null;
    var tb = std.StringHashMap(TypeId).init(self.alloc);
    var route = literal_fields.Typed.init(self.alloc, tmpl.field_names, .declaration);
    defer route.deinit(self.alloc);
    for (sl.field_inits) |fi| {
        if (fi.value.data == .spread_expr) {
            const fields = literalSpreadTypes(self, fi.value.data.spread_expr.operand) orelse return null;
            defer self.alloc.free(fields);
            for (fields) |field| {
                const idx = route.contribute(field.name, .spread) catch return null;
                if (!bindGenericLiteralField(self, tmpl, idx, field.ty, &tb, null)) return null;
            }
            continue;
        }
        const name = route.plainName(fi.name, fi.was_shorthand);
        const idx = route.contribute(name, .direct) catch return null;
        const arg_ty = if (fi.value.data == .lambda) blk: {
            if (!fi.value.data.lambda.has_env) return null;
            break :blk self.lambdaEnvType(&fi.value.data.lambda) orelse return null;
        } else self.inferExprType(fi.value);
        if (!bindGenericLiteralField(self, tmpl, idx, arg_ty, &tb, null)) return null;
    }
    for (tmpl.type_params) |tp| if (tb.get(tp.name) == null) return null;
    const mangled = self.mangledInstanceName(tmpl, &tb);
    const cvb = std.StringHashMap(i64).init(self.alloc);
    const pb = std.StringHashMap([]const TypeId).init(self.alloc);
    return self.instantiateGenericStructBound(tmpl, tb, cvb, pb, mangled, .{ .start = 0, .end = 0 });
}

/// The instance a bare generic literal names, inferred from its fields, with
/// the initializers lowered once on the way: each written field lowers against
/// its declared type where that type names no parameter, and against nothing
/// where it does — a lambda then IS its env struct, and that is the type its
/// parameter binds. A parameter no written field carries, two fields that
/// disagree on one, or a value parameter refuse at the literal.
fn inferGenericLiteral(self: *Lowering, sl: *const ast.StructLiteral, tmpl: *const program_index_mod.StructTemplate, span: ast.Span) InferredLiteral {
    const failed = InferredLiteral{ .ty = .unresolved, .initializers = &.{} };
    var tb = std.StringHashMap(TypeId).init(self.alloc);
    var initializers = std.ArrayList(LoweredLiteralInitializer).empty;
    defer {
        for (initializers.items) |initializer| {
            if (initializer == .spread) self.alloc.free(initializer.spread);
        }
        initializers.deinit(self.alloc);
    }
    // Which parameter bound from which field, for the conflict diagnostic.
    var bound_by = std.StringHashMap([]const u8).init(self.alloc);
    defer bound_by.deinit();
    var ok = true;

    // A value parameter sits in a dimension or a default, where no field's
    // type can bind it; nothing lowers against a template it cannot fit.
    for (tmpl.type_params) |tp| {
        if (!tp.is_type_param) {
            if (self.diagnostics) |d| d.addFmt(.err, span, "'{s}' takes the value parameter '${s}', which no field can infer — write the type arguments", .{ tmpl.name, tp.name });
            return failed;
        }
    }

    var route = literal_fields.Typed.init(self.alloc, tmpl.field_names, .declaration);
    defer route.deinit(self.alloc);
    for (sl.field_inits) |fi| {
        if (fi.value.data == .spread_expr) {
            const contributions = lowerLiteralSpread(self, fi.value) orelse return failed;
            initializers.append(self.alloc, .{ .spread = contributions }) catch unreachable;
            for (contributions) |contribution| {
                const idx = routeLiteralContribution(self, &route, contribution.name, .spread, fi.value.span, .{ .template = tmpl.name }) orelse return failed;
                const arg_ty = self.builder.getRefType(contribution.value);
                if (!bindGenericLiteralField(self, tmpl, idx, arg_ty, &tb, .{ .bound_by = &bound_by, .span = span })) ok = false;
            }
            continue;
        }
        const name = route.plainName(fi.name, fi.was_shorthand);
        const idx = routeLiteralContribution(self, &route, name, .direct, fi.name_span orelse fi.value.span, .{ .template = tmpl.name }) orelse return failed;
        var target: ?TypeId = null;
        {
            const node = tmpl.field_type_nodes[idx];
            var generic = false;
            for (tmpl.type_params) |tp| {
                if (self.matchTypeParam(node, tp.name)) generic = true;
            }
            if (!generic) {
                const saved_src = self.lexicalContext();
                defer self.restoreLexicalContext(saved_src);
                self.setCurrentEnvironment(self.declarationEnvironment(.{ .struct_decl = tmpl.decl }, tmpl.source_file));
                target = self.resolveTypeWithBindings(node);
            }
        }
        const saved_tt = self.target_type;
        self.target_type = target;
        const val = self.lowerExpr(fi.value);
        self.target_type = saved_tt;
        initializers.append(self.alloc, .{ .value = val }) catch unreachable;
        const arg_ty = self.builder.getRefType(val);
        if (!bindGenericLiteralField(self, tmpl, idx, arg_ty, &tb, .{ .bound_by = &bound_by, .span = span })) ok = false;
    }

    for (tmpl.type_params) |tp| {
        if (tb.get(tp.name) == null) {
            if (self.diagnostics) |d| d.addFmt(.err, span, "'{s}' leaves '${s}' unbound: no written field carries it — write it, or write the type arguments", .{ tmpl.name, tp.name });
            ok = false;
        }
    }
    if (!ok) return failed;

    const mangled = self.mangledInstanceName(tmpl, &tb);
    const cvb = std.StringHashMap(i64).init(self.alloc);
    const pb = std.StringHashMap([]const TypeId).init(self.alloc);
    const ty = self.instantiateGenericStructBound(tmpl, tb, cvb, pb, mangled, span);
    if (ty == .unresolved) return failed;
    return .{ .ty = ty, .initializers = initializers.toOwnedSlice(self.alloc) catch unreachable };
}

const LiteralSpreadField = struct {
    name: ?[]const u8,
    value: Ref,
    node: *const Node,
};

fn lowerLiteralSpread(self: *Lowering, spread: *const Node) ?[]LiteralSpreadField {
    const operand = spread.data.spread_expr.operand;
    const saved_tt = self.target_type;
    self.target_type = null;
    defer self.target_type = saved_tt;
    var fields = std.ArrayList(LiteralSpreadField).empty;
    defer fields.deinit(self.alloc);
    if (self.packSpreadRefs(operand, spread.span)) |refs| {
        defer self.alloc.free(refs);
        const arg_nodes: ?[]const *const Node = if (operand.data == .identifier and self.pack_arg_nodes != null)
            self.pack_arg_nodes.?.get(operand.data.identifier.name)
        else
            null;
        for (refs, 0..) |ref, i| {
            fields.append(self.alloc, .{
                .name = null,
                .value = ref,
                .node = if (arg_nodes) |nodes| (if (i < nodes.len) nodes[i] else spread) else spread,
            }) catch unreachable;
        }
        return fields.toOwnedSlice(self.alloc) catch unreachable;
    }

    const value = self.lowerExpr(operand);
    const ty = self.builder.getRefType(value);
    switch (self.module.types.get(ty)) {
        .@"struct" => {
            const source_fields = type_bridge.structSpreadFields(&self.module.types, ty) catch {
                if (self.diagnostics) |d| d.add(.err, "cannot spread a struct containing a private field", spread.span);
                return null;
            };
            for (source_fields, 0..) |field, i| {
                const name = self.module.types.getString(field.name);
                const node = self.alloc.create(Node) catch unreachable;
                node.* = .{
                    .span = spread.span,
                    .source_file = spread.source_file,
                    .data = .{ .field_access = .{ .object = @constCast(operand), .field = name } },
                };
                fields.append(self.alloc, .{
                    .name = literalSpreadName(name),
                    .value = self.builder.structGet(value, @intCast(i), field.ty),
                    .node = node,
                }) catch unreachable;
            }
        },
        .array => |array| {
            const storage = self.refStorageAddress(value) orelse blk: {
                const slot = self.builder.alloca(ty);
                self.builder.store(slot, value);
                break :blk slot;
            };
            const ptr_ty = self.module.types.ptrTo(array.element);
            for (0..array.length) |i| {
                const index = self.builder.constInt(@intCast(i), .i64);
                const ptr = self.builder.emit(.{ .index_gep = .{ .lhs = storage, .rhs = index } }, ptr_ty);
                fields.append(self.alloc, .{
                    .name = null,
                    .value = self.builder.load(ptr, array.element),
                    .node = spread,
                }) catch unreachable;
            }
        },
        else => {
            if (self.diagnostics) |d| d.add(.err, "literal spread requires a pack, struct or fixed-length array value", spread.span);
            return null;
        },
    }
    return fields.toOwnedSlice(self.alloc) catch unreachable;
}

fn coerceStructInitializer(self: *Lowering, value: Ref, field: types.TypeInfo.StructInfo.Field, index: usize, node: *const Node, span: ast.Span) Ref {
    const saved_span = self.builder.current_span;
    self.builder.current_span = .{ .start = span.start, .end = span.end };
    defer self.builder.current_span = saved_span;
    const src_ty = self.builder.getRefType(value);
    if (refuseVoidElement(self, src_ty, field.ty, field.name, index, node.span)) return self.zeroValue(field.ty);
    return self.coerceOrErase(value, src_ty, field.ty, node);
}

pub fn lowerStructLiteral(self: *Lowering, sl: *const ast.StructLiteral, span: ast.Span) Ref {
    // `.{ }` is a struct literal. It is not a handle and not `?I` absence.
    if (sl.type_expr == null and sl.field_inits.len == 0) {
        if (self.target_type) |t| {
            var iface = t;
            var optional_iface = false;
            if (!t.isBuiltin() and self.module.types.get(t) == .optional) {
                iface = self.module.types.get(t).optional.child;
                optional_iface = self.isErasedProtocolType(iface);
            }
            if (self.isErasedProtocolType(t) or optional_iface) {
                if (self.diagnostics) |d| {
                    const shown = self.formatTypeName(if (optional_iface) iface else t);
                    const id = d.addFmtId(.err, span, "'.{{ }}' is a struct literal, not a '{s}' handle", .{shown});
                    if (optional_iface or (!t.isBuiltin() and self.module.types.get(t) == .optional)) {
                        d.addHelpFmt(id, span, null, "absence of '?{s}' is spelled 'null'", .{shown});
                    } else {
                        d.addHelpFmt(id, span, null, "bind a named value, or write it through 'mem.make'", .{});
                    }
                }
                return self.builder.constUndef(t);
            }
        }
    }
    // Check for payload enum construction: .Variant{ payload_fields }
    // This happens when type_expr is an enum_literal and target_type is a union
    if (sl.type_expr) |te| {
        // An error member's brace group holds its payload, so a head naming one
        // constructs the channel value rather than resolving as a type.
        if (self.qualifiedErrorMember(te)) |qm| {
            return self.lowerErrorMemberConstruction(sl, qm.set, qm.member, span);
        }
        if (te.data == .enum_literal) {
            const variant_name = te.data.enum_literal.name;
            const target = self.target_type orelse .unresolved;
            if (!target.isBuiltin()) {
                switch (self.module.types.get(target)) {
                    .@"error" => return self.lowerErrorMemberConstruction(sl, target, variant_name, span),
                    .@"enum" => |e| if (e.hasPayload()) return self.lowerTaggedEnumLiteral(sl, variant_name, target, e, span),
                    else => {},
                }
            }
        }
        // Qualified variant construction: `Ev.key{ ... }`. Here `type_expr`
        // is a field_access (`Ev.key`), not an `enum_literal` — `Ev` names the
        // payload enum and `key` the variant. Route it through the same path
        // as the inferred `.key{ ... }` form; without this the
        // field_access falls to `resolveTypeWithBindings`, which cannot place
        // `Ev.key` in type position and returns `.unresolved` → LLVM panic.
        if (te.data == .field_access) {
            const fa = te.data.field_access;
            var resolved: TypeId = .unresolved;
            if (self.qualifiedTypeName(fa.object)) |path| {
                defer self.alloc.free(path);
                switch (self.qualifiedMemberVerdict(path)) {
                    .selected => |sel| resolved = switch (self.selectNominalLeaf(sel.member, self.program_index.declaration(sel.author.id).environment.?, false)) {
                        .resolved => |ty| ty,
                        else => .unresolved,
                    },
                    .not_qualified, .missing, .ambiguous => {},
                }
            }
            if (resolved == .unresolved) {
                const obj_name: ?[]const u8 = switch (fa.object.data) {
                    .identifier => |id| id.name,
                    .type_expr => |t| t.name,
                    else => null,
                };
                // Diagnostic-free PROBE: this pass only decides whether the
                // head is a payload enum (`Ev.key{...}` variant construction).
                // The object may equally be a namespace alias (`m.Cfg{...}`)
                // — the real head resolution below owns the
                // diagnostics, so a loud `resolveNominalLeaf` here would blast
                // "unknown type 'm'" for a perfectly valid qualified literal
                // lowered in a non-main module.
                if (obj_name) |on| {
                    const from = self.current_source_file orelse self.main_file;
                    if (from) |f| {
                        resolved = switch (self.selectNominalLeaf(on, self.environmentForSource(f).?, false)) {
                            .resolved => |ty| ty,
                            else => .unresolved,
                        };
                    } else {
                        const sid = self.module.types.internString(on);
                        resolved = self.module.types.findByName(sid) orelse .unresolved;
                    }
                }
            }
            if (!resolved.isBuiltin() and resolved != .unresolved) {
                const info = self.module.types.get(resolved);
                if (info == .@"enum" and info.@"enum".hasPayload()) {
                    return self.lowerTaggedEnumLiteral(sl, fa.field, resolved, info.@"enum", span);
                }
            }
        }
    }

    // A contextual literal against an OPEN SET target. A set slot's contents are
    // whichever MEMBER it carries, and a contextual literal names no type at all —
    // so there is nothing for the expected type to lift (spec: Open Sets —
    // formation). Refused before the payload enum arms below, whose "variant"
    // vocabulary is not the set's.
    if (sl.type_expr == null and sl.struct_name == null) {
        if (self.target_type) |target| {
            if (self.isOpenSet(target)) {
                if (self.diagnostics) |d| {
                    const id = d.addFmtId(.err, span, "a contextual literal cannot form a '{s}' value: it names no member", .{self.formatTypeName(target)});
                    d.addHelpFmt(id, span, null, "a set value is formed FROM a member — name it ('YourMember{{ … }}'), and the expected '{s}' lifts it into the slot", .{self.formatTypeName(target)});
                }
                return self.builder.constUndef(target);
            }
        }
    }

    // `.{ name = ... }` against a payload enum target_type. Reject:
    // the only valid construction forms are `.variant(payload)` and
    // `.variant{ field, ... }`. Falling through would lower the
    // user's values straight into the `(tag, payload_bytes)` slot
    // pair and emit IR that LLVM later rejects.
    if (sl.type_expr == null and sl.struct_name == null) {
        const tu_ty = self.target_type orelse .unresolved;
        if (!tu_ty.isBuiltin()) {
            const tu_info = self.module.types.get(tu_ty);
            if (tu_info == .@"enum" and tu_info.@"enum".hasPayload()) {
                if (sl.field_inits.len > 0 and sl.field_inits[0].name != null) {
                    const first_name = sl.field_inits[0].name.?;
                    if (self.diagnostics) |diags| {
                        const ty_name = self.formatTypeName(tu_ty);
                        if (self.findTaggedVariant(tu_info.@"enum", first_name) != null) {
                            diags.addFmt(
                                .err,
                                span,
                                "cannot construct payload enum '{s}' from `.{{ {s} = ... }}`; use `.{s}(...)` or `.{s}.{{ ... }}`",
                                .{ ty_name, first_name, first_name, first_name },
                            );
                        } else {
                            self.emitBadEnumVariant(tu_ty, tu_info.@"enum", first_name, span);
                        }
                    }
                    return self.builder.enumInit(0, Ref.none, tu_ty);
                }
            }
        }
    }

    // A bare generic head (`Pair{ a = 1, b = "x" }`) infers its type arguments
    // from the written fields; the initializers it lowered are reused below.
    var prelowered: ?[]const LoweredLiteralInitializer = null;
    defer if (prelowered) |initializers| {
        for (initializers) |initializer| {
            if (initializer == .spread) self.alloc.free(initializer.spread);
        }
        self.alloc.free(initializers);
    };
    var inferred_ty: TypeId = .unresolved;
    if (sl.struct_name) |name| {
        // The source-aware leaf answers first: a concrete struct this file can
        // see owns its name over a same-name generic template imported flat.
        const concrete = blk: {
            const from = self.current_source_file orelse self.main_file orelse break :blk false;
            break :blk switch (self.selectNominalLeaf(name, self.environmentForSource(from).?, false)) {
                .resolved => |lt| self.hasPlainStructAuthor(lt),
                else => false,
            };
        };
        if (sl.type_expr == null and !concrete) {
            switch (self.selectGenericStructHead(name, null, false, span)) {
                .template => |tmpl| {
                    const inferred = inferGenericLiteral(self, sl, &tmpl, span);
                    if (inferred.ty == .unresolved) return self.builder.constUndef(.unresolved);
                    inferred_ty = inferred.ty;
                    prelowered = inferred.initializers;
                },
                .poisoned => return self.builder.constUndef(.unresolved),
                .not_generic => {},
            }
        }
    }

    const ty: TypeId = if (inferred_ty != .unresolved)
        inferred_ty
    else if (sl.struct_name) |name|
        // Source-aware: a bare struct-literal type name resolves to the
        // querying source's OWN same-name author, not the global `findByName`
        // first-match — so `Box{...}` in module B builds B's `Box`, never a
        // flat-imported A's. `.undeclared`/`.pending` keep the empty-struct
        // stub; `.ambiguous`/`.not_visible` surface their loud diagnostic + poison.
        self.resolveNominalLeaf(name, false, span)
    else if (sl.type_expr) |te|
        // Generic struct literal: Pair(i32){ ... } — resolve type from type_expr
        self.resolveTypeWithBindings(te)
    else
        self.target_type orelse .unresolved;

    // Plain union target: build by writing each named member into a
    // union-sized slot. `getStructFields` returns empty for a union, so the
    // generic struct path below would emit a malformed `structInit` whose
    // overlapping zero-fill clobbers the named member. Tagged
    // unions were already handled above.
    if (!ty.isBuiltin() and self.module.types.get(ty) == .@"union") {
        return self.lowerUnionLiteral(sl, ty, span);
    }

    // A bare struct literal against an optional target `?T` builds the INNER
    // `T` and wraps it once. Without this `ty` is the optional itself, so the
    // literal is lowered into the optional's `{payload, has_value}` layout and
    // then re-wrapped — corrupting the value (a `?T` arg silently reads as
    // null) or failing LLVM verification on the double wrap.
    // Only the bare `.{ ... }` form reaches here with an optional `ty` (a named
    // / generic literal resolves `ty` from its own type, never the target).
    if (!ty.isBuiltin() and self.module.types.get(ty) == .optional) {
        const child = self.module.types.get(ty).optional.child;
        // Build the inner `T` (targeting it so nested literals resolve), then
        // wrap to `?T`. Building into `ty` (the optional) directly would fill
        // its {payload, has_value} layout and corrupt the value / fail LLVM
        // verification. Wrapping the raw struct_init SSA aggregate ALSO mislays
        // a multi-field payload, so round-trip through memory first — the wrap
        // then sees a loaded value, the same shape the working `T -> ?T` value
        // coercion wraps. Returning a fully-built `?T` makes EVERY caller
        // context correct, including array/struct-literal element slots that
        // don't re-coerce.
        const saved_tt = self.target_type;
        self.target_type = child;
        const inner = self.lowerStructLiteral(sl, span);
        self.target_type = saved_tt;
        const slot = self.builder.alloca(child);
        self.builder.store(slot, inner);
        const reloaded = self.builder.load(slot, child);
        return self.coerceToType(reloaded, child, ty);
    }

    if (!checkPlainInitializerNames(self, sl, ty)) return self.builder.constUndef(ty);

    // No inferable target at all (`t := .{ 1, 2, 3 };` — `ty` stayed
    // `.unresolved`): the literal's type can never be resolved, and an
    // `.unresolved`-typed `struct_init` flows to codegen and panics LLVM
    // emission ("unresolved type reached LLVM emission"), with no
    // diagnostic. Diagnose at the literal site and return an
    // `.unresolved`-typed poison ref — the diagnostic makes `hasErrors()`
    // abort before codegen, and downstream use of the poison value is
    // suppressed (field/index access on an `.unresolved` object defers).
    // Only the bare form is reported here — a named / generic literal whose
    // type failed to resolve (`.ambiguous` / `.not_visible` poison,
    // value-in-type-position) already surfaced its own diagnostic in
    // `resolveNominalLeaf` / `resolveTypeWithBindings`; don't stack a second.
    //
    // For the bare form, `ty` ends up `.unresolved` two ways:
    //  - genuinely TARGETLESS (`self.target_type == null`, `t := .{1};`) —
    //    nothing upstream could have reported it; always diagnose;
    //  - `self.target_type` SET to `.unresolved`. EITHER the target was
    //    poisoned WITH a diagnostic (`s : Secret = .{ ... }`, `Secret` not
    //    visible — the annotation's error already fired; a second here would
    //    double-report), OR the target was inferred `.unresolved` SILENTLY —
    //    a global const `K :: .{1,2,3}` (pass-1 `inferExprType` yields
    //    unresolved, on-demand const lowering targets it), an inferred
    //    return type (`f :: () { return .{1}; }`), an inferred array-literal
    //    element (`arr := .[ .{1}, .{2} ];`). No sentinel distinguishes the
    //    two shapes, so gate on `hasErrors()`: if NO error is recorded yet,
    //    the poison cannot be carrying a diagnostic — report it; otherwise
    //    stay silent. Trade-off (deliberate): an UNRELATED earlier error in
    //    the same compile mutes this literal's diagnostic — acceptable, the
    //    compile already fails loudly; do NOT "simplify" the gate away or
    //    the `s : Secret = .{}` double-report returns.
    if (ty == .unresolved) {
        if (sl.struct_name == null and sl.type_expr == null) {
            // Genuinely TARGETLESS (`t := .{1, 2};`, `p := .{x = 1};`, a
            // call arg binding a `$T` param): SELF-TYPE the literal as an
            // anonymous STRUCTURAL struct — positional elements mint fields
            // "0"/"1"/…, named (and shorthand) elements mint named fields;
            // structural interning gives every same-shaped literal the same
            // TypeId. (Global consts / inferred returns / array elements
            // self-type at pass-1 INFERENCE and never reach this arm; the
            // set-but-unresolved shape left here is a poisoned annotation —
            // stay silent — or an element whose type genuinely cannot be
            // inferred — diagnose.)
            if (self.target_type == null) {
                return self.synthesizeAnonStruct(sl);
            }
            if (self.diagnostics) |d| {
                if (!d.hasErrors())
                    d.addFmt(.err, span, "cannot infer the type of this '.{{ }}' literal — annotate the binding or provide a target type", .{});
            }
        }
        return self.builder.constUndef(.unresolved);
    }

    // The C-variadic cursor is opaque: no literal builds one, and its storage
    // comes from a local declaration alone.
    if (self.refuseCursorValue(ty, span, "construct")) return self.builder.constUndef(ty);

    // A `.{ ... }` literal can only build an AGGREGATE. After the
    // payload enum / union / optional intercepts above, the named and
    // positional paths below handle exactly: struct, tuple, array, vector,
    // the two {ptr, len} fat pointers — a slice (`sl : []T = .{ ptr = …,
    // len = … }`, used throughout the stdlib/corpus) and the builtin `string`
    // (`string{ ptr = …, len = … }` in fmt/hash/cli/sqlite) — and a closure
    // (`c : Closure(i32) -> i32 = .{ fnPtr = …, env = … }`, the {fnPtr, env}
    // pair, exercised by examples/types/0129).
    // Any other resolved target — a scalar builtin (`x : i64 = .{ a = 1 }`),
    // an enum, a pointer, ... — would reach `structInit` against a
    // non-aggregate LLVM type: a non-empty literal fails LLVM verification
    // (`Invalid InsertValueInst operands!`), and the empty `.{}` silently
    // produces garbage. Diagnose and return a typed zero
    // placeholder — the diagnostic aborts the build before codegen; the
    // placeholder only keeps the remaining lowering coherent.
    // A failable product's shorter value tuple must keep its own arity so
    // coercion can add the error slot. Struct spreads retain their field names.
    if (sl.struct_name == null and sl.type_expr == null and !ty.isBuiltin()) {
        const tgt = self.module.types.get(ty);
        const positional_anon = self.module.types.isAnonStruct(ty) and blk: {
            for (tgt.@"struct".fields, 0..) |field, i| {
                const position = std.fmt.parseInt(usize, self.module.types.getString(field.name), 10) catch break :blk false;
                if (position != i) break :blk false;
            }
            break :blk true;
        };
        const route_len: ?usize = if (self.module.types.isAnonStruct(ty))
            tgt.@"struct".fields.len
        else if (tgt == .failable)
            self.module.types.failableValueSlotCount(tgt.failable) + 1
        else
            null;
        var has_spread = false;
        for (sl.field_inits) |fi| {
            if (fi.value.data == .spread_expr) has_spread = true;
        }
        if (route_len) |n| {
            if ((tgt == .failable and has_spread) or
                (!has_spread and (positional_anon or tgt == .failable) and sl.field_inits.len != n))
            {
                var elems = std.ArrayList(ast.TupleElement).empty;
                defer elems.deinit(self.alloc);
                for (sl.field_inits) |fi| {
                    elems.append(self.alloc, .{ .name = fi.name, .value = fi.value }) catch unreachable;
                }
                const tl = ast.TupleLiteral{ .elements = elems.items };
                const saved_tt2 = self.target_type;
                self.target_type = ty;
                const r = self.lowerTupleLiteral(&tl);
                self.target_type = saved_tt2;
                return r;
            }
        }
    }

    // A `[]T`-targeted `.{ … }` that does not name the fat pointer's own slots
    // is an ELEMENT list, lowered exactly as `.[ … ]` is: each element coerces
    // to `T` (a protocol element boxes into `any`) and the backing array
    // becomes the view. Read as a `{ptr, len}` literal instead, an aggregate
    // element lands in the `ptr` word and fails LLVM verification.
    if (sl.struct_name == null and sl.type_expr == null and sl.init_block == null and
        sl.field_inits.len > 0 and self.module.types.sliceInfoOf(ty) != null and !isSliceHeaderLiteral(sl))
    {
        var elems = std.ArrayList(*Node).empty;
        defer elems.deinit(self.alloc);
        for (sl.field_inits) |fi| elems.append(self.alloc, fi.value) catch unreachable;
        const al = ast.ArrayLiteral{ .elements = elems.items };
        const saved_tt = self.target_type;
        self.target_type = ty;
        const arr = self.lowerArrayLiteral(&al, span);
        self.target_type = saved_tt;
        return self.coerceToType(arr, self.builder.getRefType(arr), ty);
    }

    const aggregate_ok = switch (self.module.types.get(ty)) {
        .@"struct", .array, .vector, .slice, .closure, .failable => true,
        else => false,
    };
    if (!aggregate_ok) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "cannot build a struct literal for non-struct type '{s}'", .{self.formatTypeName(ty)});
        return self.zeroValue(ty);
    }

    // Get struct field types for coercion and ordering
    const struct_fields = self.getStructFields(ty);

    const field_defaults: []const ?*const Node = self.struct_defaults_by_tid.get(ty) orelse &.{};
    const default_substitution = self.fieldDefaultSubstitution(ty);

    if (self.module.types.get(ty) == .@"struct") {
        const selected = self.alloc.alloc(?Ref, struct_fields.len) catch unreachable;
        defer self.alloc.free(selected);
        @memset(selected, null);
        var indices = StructLiteralIndices.init(self, sl, ty);
        defer indices.deinit(self.alloc);
        for (sl.field_inits, 0..) |fi, k| {
            if (fi.value.data == .spread_expr) {
                const contributions = if (prelowered) |pl| pl[k].spread else lowerLiteralSpread(self, fi.value) orelse continue;
                defer if (prelowered == null) self.alloc.free(contributions);
                for (contributions) |contribution| {
                    const index = indices.spread(self, contribution.name, fi.value.span);
                    if (index) |idx| {
                        selected[idx] = coerceStructInitializer(self, contribution.value, struct_fields[idx], idx, contribution.node, fi.value.span);
                    }
                }
                continue;
            }
            const index = indices.plain(self, fi);
            const saved_tt = self.target_type;
            self.target_type = if (index) |idx| struct_fields[idx].ty else null;
            const val = if (prelowered) |pl|
                pl[k].value
            else if (index) |idx|
                self.foldComptimeFloatInit(fi.value, struct_fields[idx].ty) orelse self.lowerExpr(fi.value)
            else
                self.lowerExpr(fi.value);
            self.target_type = saved_tt;
            if (index) |idx| {
                selected[idx] = coerceStructInitializer(self, val, struct_fields[idx], idx, fi.value, span);
            }
        }

        var fields = std.ArrayList(Ref).empty;
        defer fields.deinit(self.alloc);
        for (struct_fields, selected, 0..) |sf, value, i| {
            const val = value orelse blk: {
                if (i < field_defaults.len) {
                    if (field_defaults[i]) |default_expr| {
                        break :blk self.lowerDefaultWithBindings(default_expr, sf.ty, default_substitution);
                    }
                }
                break :blk self.zeroValue(sf.ty);
            };
            fields.append(self.alloc, val) catch unreachable;
        }
        const result = self.builder.structInit(fields.items, ty);
        if (sl.init_block) |ib| return self.lowerInitBlock(result, ty, ib, sl.init_block_self.?);
        return result;
    }

    // Positional literal: use source order.
    //
    // For an ARRAY / VECTOR target the literal `.{ a, b, ... }` has no named
    // fields — `getStructFields` returns empty for these, so the per-field
    // coercion below (`i < struct_fields.len`) never fires. Each positional
    // element must still be coerced to the homogeneous element type, or a
    // scalar element flowing into an aggregate element slot stores the wrong
    // shape. Concretely `[N]?T` would store a bare `T`/`null` into a `{T,i1}`
    // slot — corrupting the array (a present element reads back as absent;
    // indexing it segfaults). `coerceToType` is a no-op when the
    // element already matches (the common `[N]i64`/`[N]Struct` case).
    const array_elem_ty: TypeId = if (!ty.isBuiltin()) switch (self.module.types.get(ty)) {
        .array, .vector => self.getElementType(ty),
        else => .unresolved,
    } else .unresolved;

    const failable_fields: []const TypeId = if (!ty.isBuiltin()) switch (self.module.types.get(ty)) {
        .failable => |f| blk: {
            const n = self.module.types.failableValueSlotCount(f);
            const tmp = self.alloc.alloc(TypeId, n + 1) catch break :blk &.{};
            for (0..n) |i| tmp[i] = self.module.types.failableValueSlotType(f, i);
            tmp[n] = f.err;
            break :blk tmp;
        },
        else => &.{},
    } else &.{};

    var fields = std.ArrayList(Ref).empty;
    defer fields.deinit(self.alloc);

    for (sl.field_inits, 0..) |fi, i| {
        const saved_tt = self.target_type;
        // Steer literal lowering with the destination element/field type so a
        // nested untyped literal element (`.{ .{ v = x }, … }`, `null`, an enum
        // literal) resolves against its real slot type — mirrors the named
        // branch (which sets `target_type` to `sf.ty`). The actual wrap/erase
        // still happens in `coerceToType` below.
        const elem_target: TypeId = if (i < struct_fields.len)
            struct_fields[i].ty
        else if (i < failable_fields.len)
            failable_fields[i]
        else if (array_elem_ty != .unresolved)
            array_elem_ty
        else
            fatPointerSlotType(self, ty, fi.name, i) orelse .unresolved;
        if (elem_target != .unresolved) self.target_type = elem_target;
        var val = if (prelowered) |pl|
            pl[i].value
        else
            self.foldComptimeFloatInit(fi.value, elem_target) orelse self.lowerExpr(fi.value);
        self.target_type = saved_tt;
        // Coerce field value to match the destination field/element type.
        // Coerce from the value's ACTUAL lowered type (`getRefType`) rather
        // than a re-inferred source type: a re-inference of a punned positional
        // identifier (`.{ x, … }`, parser-named `x = x`) could disagree with
        // the SSA value's real type and mis-narrow it. The lowered ref's type
        // is authoritative.
        if (elem_target != .unresolved) {
            const src_ty = self.builder.getRefType(val);
            const slot_name: ?StringId = if (i < struct_fields.len) struct_fields[i].name else null;
            if (refuseVoidElement(self, src_ty, elem_target, slot_name, i, fi.value.span)) {
                val = self.zeroValue(elem_target);
            } else if (src_ty != elem_target) {
                val = self.coerceToType(val, src_ty, elem_target);
            }
        }
        fields.append(self.alloc, val) catch unreachable;
    }

    // Pad missing fields with defaults or zeroes
    if (fields.items.len < struct_fields.len) {
        for (struct_fields[fields.items.len..], fields.items.len..) |sf, fi| {
            if (fi < field_defaults.len) {
                if (field_defaults[fi]) |default_expr| {
                    fields.append(self.alloc, self.lowerDefaultWithBindings(default_expr, sf.ty, default_substitution)) catch unreachable;
                    continue;
                }
            }
            fields.append(self.alloc, self.zeroValue(sf.ty)) catch unreachable;
        }
    }

    const result = self.builder.structInit(fields.items, ty);

    // The self-trailing block writes into the value just built.
    if (sl.init_block) |ib| return self.lowerInitBlock(result, ty, ib, sl.init_block_self.?);

    return result;
}

pub fn lowerSelfBlock(self: *Lowering, sb: *const ast.SelfBlock) Ref {
    const ty = self.inferExprType(sb.operand);
    if (ty == .type_value) {
        if (self.diagnostics) |d| {
            const id = d.addId(.err, "a self-trailing block writes into a value; this operand is a type", sb.operand.span);
            d.addHelp(id, null, "construct the value first: `T{ … }.{ … }`", null);
        }
        return self.builder.constUndef(.unresolved);
    }
    const value = self.lowerExpr(sb.operand);
    return self.lowerInitBlock(value, ty, sb.block, sb.binder);
}

/// Store the value to an alloca, bind `binder` to a pointer to it, run the
/// block, reload.
pub fn lowerInitBlock(self: *Lowering, struct_val: Ref, ty: TypeId, ib: *const Node, binder: []const u8) Ref {
    // Store struct value to a temporary alloca
    const ptr_ty = self.module.types.ptrTo(ty);
    const slot = self.builder.alloca(ty);
    self.builder.store(slot, struct_val);

    // Create a nested scope with the binder bound to the alloca pointer
    var init_scope = Scope.init(self.alloc, self.scope, &self.next_binding_id);
    defer init_scope.deinit();
    const saved_scope = self.scope;
    self.scope = &init_scope;

    // The binder IS the pointer value, not an alloca holding one.
    init_scope.put(binder, .{ .ref = slot, .ty = ptr_ty, .is_alloca = false });

    // Lower the init block body
    self.lowerBlock(ib);

    // Restore scope
    self.scope = saved_scope;

    // Load and return the (possibly modified) struct value
    return self.builder.load(slot, ty);
}

/// The file that wrote `ty`'s declaration — its own, or the template a generic
/// instance was stamped from.
pub fn structDeclaringSource(self: *Lowering, ty: TypeId) ?[]const u8 {
    const author = self.memberAuthor(self.plainStructOwnerType(ty)) orelse return null;
    return author.source;
}

pub fn privateFieldHere(self: *Lowering, ty: TypeId, field: []const u8) bool {
    const wanted = self.module.types.internString(field);
    var vis: ast.Visibility = .public;
    for (self.getStructFields(ty)) |f| {
        if (f.name == wanted) {
            vis = f.visibility;
            break;
        }
    }
    if (vis != .private) return false;
    const from = self.current_source_file orelse return false;
    // Only a named declaration or a generic instance can carry a private field
    // — the parser refuses one on an anonymous body — and both stamp an author.
    const declaring = self.structDeclaringSource(ty) orelse
        std.debug.panic("private field '{s}' on a struct type with no declaring file", .{field});
    return !std.mem.eql(u8, from, declaring);
}

/// The result of matching a source-written name against a named struct's
/// fields.
pub const FieldLookup = union(enum) {
    missing,
    hit: Hit,
    /// The field exists and this file may not name it. Terminal: resolution
    /// stops rather than falling through to `@get`/`@set`, UFCS, or a method.
    private: Hit,

    pub const Hit = struct { index: u32, ty: TypeId, name: StringId };
};

/// The only match of a source-written name against a named struct's fields.
/// A private field is `.private`, never `.missing`: a taken name read as absent
/// reclassifies a punned literal as positional and silently succeeds.
pub fn lookupField(self: *Lowering, ty: TypeId, field: []const u8) FieldLookup {
    const wanted = self.module.types.internString(field);
    for (self.getStructFields(ty), 0..) |f, i| {
        if (f.name != wanted) continue;
        const hit: FieldLookup.Hit = .{ .index = @intCast(i), .ty = f.ty, .name = wanted };
        if (f.visibility == .private and self.privateFieldHere(ty, field)) return .{ .private = hit };
        return .{ .hit = hit };
    }
    return .missing;
}

/// A union variant promotes members only when its payload IS a struct — the
/// union's bytes are the pointer, not the pointee.
pub fn payloadPromotes(self: *Lowering, ty: TypeId) bool {
    if (ty.isBuiltin()) return false;
    return self.module.types.get(ty) == .@"struct";
}

/// `lookupField` for a name a human wrote: diagnoses `.private` once, then
/// answers as `lookupField`.
pub fn mentionField(self: *Lowering, ty: TypeId, field: []const u8, span: ast.Span) FieldLookup {
    const found = self.lookupField(ty, field);
    if (found == .private) _ = self.diagPrivateField(ty, field, span);
    return found;
}

/// Read `field` as a member promoted out of a union variant's struct payload:
/// reinterpret the union as that payload, then `struct_get` the member. The
/// name is mentioned on the PAYLOAD type, which owns its visibility.
fn promotedUnionMemberRead(
    self: *Lowering,
    obj: Ref,
    obj_ty: TypeId,
    field: []const u8,
    span: ast.Span,
) ?Ref {
    var m: usize = 0;
    while (self.module.types.memberType(obj_ty, @intCast(m))) |mty| : (m += 1) {
        if (!self.payloadPromotes(mty)) continue;
        switch (self.mentionField(mty, field, span)) {
            .missing => {},
            .private => return self.emitPlaceholder(field),
            .hit => |h| {
                const reinterpreted = self.builder.emit(.{ .union_get = .{ .base = obj, .field_index = 0 } }, mty);
                return self.builder.structGet(reinterpreted, h.index, h.ty);
            },
        }
    }
    return null;
}

pub fn diagPrivateField(self: *Lowering, ty: TypeId, field: []const u8, span: ast.Span) bool {
    if (!self.privateFieldHere(ty, field)) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "field '{s}' is private to its declaring file", .{field});
    return true;
}

/// A slice literal that names only `ptr`/`len` writes the fat pointer's own
/// slots; any other field list is a list of elements.
fn isSliceHeaderLiteral(sl: *const ast.StructLiteral) bool {
    for (sl.field_inits) |fi| {
        const name = fi.name orelse return false;
        if (!std.mem.eql(u8, name, "ptr") and !std.mem.eql(u8, name, "len")) return false;
    }
    return true;
}

/// Slot type of a `{ptr,len}` fat pointer or `{fnPtr,env}` closure literal,
/// keyed by field name or by position. `getStructFields` is empty for these.
fn fatPointerSlotType(self: *Lowering, ty: TypeId, name: ?[]const u8, index: usize) ?TypeId {
    const is_slice = self.module.types.get(ty) == .slice;
    const is_closure = !ty.isBuiltin() and self.module.types.get(ty) == .closure;
    if (is_slice) {
        const is_ptr = if (name) |n| std.mem.eql(u8, n, "ptr") else index == 0;
        const is_len = if (name) |n| std.mem.eql(u8, n, "len") else index == 1;
        if (is_ptr) return self.module.types.manyPtrTo(self.getElementType(ty));
        if (is_len) return self.module.types.lenTypeOf(ty);
        return null;
    }
    if (is_closure) {
        const is_fn = if (name) |n| std.mem.eql(u8, n, "fnPtr") else index == 0;
        const is_env = if (name) |n| std.mem.eql(u8, n, "env") else index == 1;
        if (is_fn or is_env) return self.module.types.ptrTo(.void);
        return null;
    }
    return null;
}

/// Get the field list for a struct TypeId, or empty if not a struct.
pub fn getStructFields(self: *Lowering, ty: TypeId) []const types.TypeInfo.StructInfo.Field {
    if (ty.isBuiltin()) return &.{};
    var resolved = ty;
    const info = self.module.types.get(resolved);
    // Dereference pointer types to get to the underlying struct
    if (info == .pointer) {
        resolved = info.pointer.pointee;
        if (resolved.isBuiltin()) return &.{};
        const inner = self.module.types.get(resolved);
        return switch (inner) {
            .@"struct" => |s| s.fields,
            else => &.{},
        };
    }
    return switch (info) {
        .@"struct" => |s| s.fields,
        else => &.{},
    };
}

/// A receiver slot for a `*T` param, from the receiver's address. `lowerExprAsPtr`
/// and a struct GEP yield either `*T` already or the pointee `T` as a "place"
/// ref; wrapping the latter with `addr_of` (a no-op in LLVM) sets the IR type to
/// `*T`, which keeps `coerceCallArgs` from doing a spurious alloca+store.
fn receiverPointer(self: *Lowering, place: Ref, obj_ty: TypeId) Ref {
    const ptr_ty = self.module.types.ptrTo(obj_ty);
    if (self.builder.getRefType(place) == ptr_ty) return place;
    return self.builder.emit(.{ .addr_of = .{ .operand = place } }, ptr_ty);
}

/// A `*T` receiver never binds to a constant: its storage is read-only or absent.
fn diagConstantReceiver(self: *Lowering, name: []const u8, span: ast.Span) Ref {
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "cannot take the address of constant '{s}' for a '*T' receiver — constants are immutable (use a '=' variable or a local copy for mutable data)", .{name});
    return self.emitPlaceholder("addr_of_const");
}

/// If a method's first param expects a pointer (*T) but we're passing T by value,
/// swap the first arg with the alloca address (implicit address-of). `place` is
/// the receiver's storage when the caller already produced it — the node
/// branches below re-lower `obj_node`, so a side-effecting receiver expression
/// must arrive with its address instead.
pub fn fixupMethodReceiver(self: *Lowering, method_args: *std.ArrayList(Ref), func: *const Function, obj_node: *const Node, obj_ty: TypeId, place: ?Ref) void {
    // Skip the implicit __sx_ctx param when inspecting the receiver slot.
    const skip: usize = if (func.has_implicit_ctx) 1 else 0;
    if (func.params.len <= skip) return;
    const first_param_ty = func.params[skip].ty;
    // Check if first param expects a pointer
    if (!first_param_ty.isBuiltin()) {
        const pi = self.module.types.get(first_param_ty);
        if (pi == .pointer) {
            // If obj is already a pointer type, it's already correct (no addr_of needed)
            if (!obj_ty.isBuiltin()) {
                const oi = self.module.types.get(obj_ty);
                if (oi == .pointer) return; // already a pointer
            }
            self.noteStorageWrite(obj_node);
            if (self.constantRoot(obj_node)) |root| {
                method_args.items[0] = diagConstantReceiver(self, root, obj_node.span);
                return;
            }
            if (place) |p| {
                method_args.items[0] = receiverPointer(self, p, obj_ty);
                return;
            }
            // Method expects *T — pass the address of the receiver (value type in alloca)
            if (obj_node.data == .identifier) {
                const nm = obj_node.data.identifier.name;
                const local = if (self.scope) |scope| scope.lookup(nm) else null;
                if (local) |binding| {
                    if (binding.is_alloca) {
                        const binding_info = self.module.types.get(binding.ty);
                        method_args.items[0] = if (binding_info == .optional and
                            binding_info.optional.child == obj_ty and self.module.types.optionalShape(obj_ty) == .flag)
                            self.builder.structGepTyped(binding.ref, 0, self.module.types.ptrTo(obj_ty), binding.ty)
                        else
                            receiverPointer(self, binding.ref, obj_ty);
                        return;
                    }
                    if (binding.origin == .local_const) {
                        method_args.items[0] = diagConstantReceiver(self, nm, obj_node.span);
                        return;
                    }
                    // A non-alloca local (SSA value / by-value param) has no
                    // stable storage to address — fall through to alloca+store.
                } else if (self.resolveGlobalRef(nm, null) != null) {
                    // MUTABLE module-global lvalue receiver: address the global's
                    // LIVE storage so `self: *T` mutations target the global
                    // itself, not a throwaway stack copy. Mirrors
                    // the compound-lvalue branch below; `lowerExprAsPtr` yields
                    // the global's `global_addr`.
                    method_args.items[0] = receiverPointer(self, self.lowerExprAsPtr(obj_node), obj_ty);
                    return;
                }
            }
            if (self.fieldCall(obj_node) != null) {
                if (self.refStorageAddress(method_args.items[0])) |address| {
                    method_args.items[0] = receiverPointer(self, address, obj_ty);
                    return;
                }
            }
            // Compound lvalue receiver: obj.field.method() / arr[i].method() /
            // (*p).method() → take the lvalue's real address so mutations
            // through *T are visible on the original storage (not a throwaway
            // copy). Mirrors the explicit-arg path in call.zig.
            //
            // Exclude a comptime-pack index (`xs[i]` where `xs` is a pack): a
            // pack has no runtime storage to address — its element is materialized
            // at comptime and can't be mutated in place — so it must keep flowing
            // through the general alloca+store-of-value path below.
            const is_pack_index = obj_node.data == .index_expr and
                obj_node.data.index_expr.object.data == .identifier and
                self.isPackName(obj_node.data.index_expr.object.data.identifier.name);
            if (!is_pack_index and (obj_node.data == .field_access or obj_node.data == .index_expr or obj_node.data == .deref_expr)) {
                method_args.items[0] = receiverPointer(self, self.lowerExprAsPtr(obj_node), obj_ty);
                return;
            }
            // General case: alloca+store the value and pass the alloca pointer
            {
                const slot = self.builder.alloca(obj_ty);
                self.builder.store(slot, method_args.items[0]);
                method_args.items[0] = slot;
            }
        } else {
            // Method expects a value `T` but the receiver is a `*T` (e.g. a
            // `for *x in xs` by-ref capture) — deref to pass the value.
            if (!obj_ty.isBuiltin()) {
                const oi = self.module.types.get(obj_ty);
                if (oi == .pointer and self.module.types.sameType(oi.pointer.pointee, first_param_ty)) {
                    method_args.items[0] = self.builder.load(method_args.items[0], first_param_ty);
                }
            }
        }
    }
}

/// Get the name of a struct type (dereferencing pointers). Returns null for non-struct types.
pub fn getStructTypeName(self: *Lowering, ty: TypeId) ?[]const u8 {
    if (ty.isBuiltin()) {
        // Map builtin types to their names for method resolution (e.g., i64.eq)
        return builtinTypeName(ty);
    }
    var resolved = ty;
    const info = self.module.types.get(resolved);
    if (info == .pointer) {
        resolved = info.pointer.pointee;
        if (resolved.isBuiltin()) return builtinTypeName(resolved);
    }
    const ri = self.module.types.get(resolved);
    return switch (ri) {
        .@"struct" => |s| self.module.types.getString(s.name),
        else => null,
    };
}

pub fn builtinTypeName(ty: TypeId) ?[]const u8 {
    return switch (ty) {
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .f32 => "f32",
        .f64 => "f64",
        .bool => "bool",
        .string => "string",
        else => null,
    };
}

/// Resolve the type of a named field on a given type. The `.len`/`.ptr`
/// pseudo-fields belong to the special containers (string/slice/array/
/// vector) — a REAL struct/union/tuple member named `len` or `ptr` resolves
/// to its declared type (the unconditional pseudo arm typed a
/// struct's own `ptr: *T` as `[*]unresolved` and its `len` as `i64`). For
/// non-container types with NO matching real member the pseudo typing is
/// kept as a FALLBACK — `@get len` accessors (e.g. `List.len`) have no
/// field entry and type through it.
pub fn resolveFieldType(self: *Lowering, ty: TypeId, field: []const u8) TypeId {
    const is_special_container = switch (self.module.types.get(ty)) {
        .slice, .array, .vector => true,
        else => false,
    };
    if (is_special_container) {
        if (std.mem.eql(u8, field, "len")) return self.module.types.lenTypeOf(ty);
        if (std.mem.eql(u8, field, "ptr")) {
            const elem_ty = self.getElementType(ty);
            return self.module.types.manyPtrTo(elem_ty);
        }
    }
    const field_name_id = self.module.types.internString(field);
    // Check union fields + promoted fields
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        var m: usize = 0;
        if (info == .@"union" or (info == .@"enum" and info.@"enum".hasPayload())) {
            while (self.module.types.memberName(ty, @intCast(m))) |mname| : (m += 1) {
                const mty = self.module.types.memberType(ty, @intCast(m)) orelse break;
                if (mname == field_name_id) return mty;
                if (!self.payloadPromotes(mty)) continue;
                // Members promoted out of a struct variant
                switch (self.lookupField(mty, field)) {
                    .hit, .private => |h| return h.ty,
                    .missing => {},
                }
            }
        }
    }
    switch (self.lookupField(ty, field)) {
        .hit, .private => |h| return h.ty,
        .missing => {},
    }
    // Pseudo-field fallback for non-containers with no matching real
    // member (`@get len` accessors type through here).
    if (std.mem.eql(u8, field, "len")) return .i64;
    if (std.mem.eql(u8, field, "ptr")) {
        return self.module.types.manyPtrTo(self.getElementType(ty));
    }
    return .unresolved;
}

/// A comptime constant as a runtime value. `.target_variant` and `.struct_val`
/// have no scalar to emit, so they answer null.
fn comptimeConstRef(self: *Lowering, cv: lower.Lowering.ComptimeValue) ?Ref {
    return switch (cv) {
        .int_val => |iv| self.builder.constInt(iv, .i64),
        .bool_val => |bv| self.builder.constBool(bv),
        .enum_tag => |et| self.builder.constInt(@intCast(et.tag), et.ty),
        .target_variant, .struct_val => null,
    };
}

/// A whole comptime struct (`x := @host`) as a runtime value: `struct_init`
/// over the field constants in declaration order, typed by the contract the
/// program declares under the same name.
fn comptimeStructRef(self: *Lowering, name: []const u8, fields: []const lower.Lowering.ComptimeValue.Field) ?Ref {
    const tid = self.module.types.findByName(self.module.types.internString(name)) orelse return null;
    const refs = self.alloc.alloc(Ref, fields.len) catch return null;
    for (fields, refs) |f, *r| r.* = comptimeConstRef(self, f.value) orelse return null;
    return self.builder.emit(.{ .struct_init = .{ .fields = refs } }, tid);
}

pub fn lowerFieldAccess(self: *Lowering, fa: *const ast.FieldAccess, span: ast.Span) Ref {
    // An `inline for` element capture as the receiver: re-enter with the
    // synthesized `<iterable>[<i>]` as the object, so every element rule below
    // (interface-only constraint check, projection, substitution) sees the
    // canonical `<iterable>[<i>].<field>` shape.
    if (fa.object.data == .identifier) {
        if (self.scope) |scope| {
            if (scope.lookup(fa.object.data.identifier.name)) |binding| {
                if (binding.alias_node) |elem| {
                    var patched = fa.*;
                    patched.object = elem;
                    return self.lowerFieldAccess(&patched, span);
                }
            }
        }
    }

    // A cursor and a borrow of one carry no declared members. Refuse before the
    // object lowers, so the receiver is not ALSO reported as a value read.
    if (fa.object.data == .identifier) {
        if (self.scope) |scope| {
            if (scope.lookup(fa.object.data.identifier.name)) |binding| {
                if (self.refuseCursorMember(binding.ty, span)) return self.builder.constUndef(.unresolved);
            }
        }
    }

    // The `error` keyword in expression position parses as identifier
    // "error", so `error.X` arrives here as a field access.
    if (fa.object.data == .identifier and std.mem.eql(u8, fa.object.data.identifier.name, "error")) {
        self.emitErrorKeywordMember(span, fa.field);
        return self.builder.constUndef(.unresolved);
    }

    if (self.qualifiedErrorSet(fa.object)) |set_ty| {
        return self.lowerQualifiedErrorMember(set_ty, fa.field, span);
    }

    // Full namespace-member selection in value position. This handles both a
    // direct member (`alias.CONST`) and a nested namespace terminal
    // (`facade.engine_alias.CONST`) without ever stripping to a globally keyed
    // bare name before the complete prefix is proved.
    const full_node = Node{ .span = span, .data = .{ .field_access = fa.* } };

    // A comptime constant's field (`@host.pointerSize`) is a value read, not a
    // namespace member, so it answers ahead of the walk below.
    if (self.evalComptimeValue(&full_node)) |cv| {
        if (comptimeConstRef(self, cv)) |ref| return ref;
    }

    if (self.qualifiedTypeName(&full_node)) |full_path| {
        defer self.alloc.free(full_path);
        const root_end = std.mem.indexOfScalar(u8, full_path, '.') orelse full_path.len;
        const root = full_path[0..root_end];
        if (!self.identifierBindsVisibleValue(root)) {
            switch (self.qualifiedMemberVerdict(full_path)) {
                .selected => |sel| {
                    const synth = self.alloc.create(Node) catch null;
                    if (synth) |n| {
                        n.* = .{ .span = span, .data = .{ .identifier = .{ .name = sel.member } } };
                        const saved_src = self.lexicalContext();
                        self.setAuthorContext(sel.author.id);
                        defer self.restoreLexicalContext(saved_src);
                        return self.lowerExpr(n);
                    }
                },
                .missing => |m| {
                    if (self.namespaceMissWaits(m)) return Ref.none;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, CallResolver.pathSliceSpan(&full_node, full_path, m.member), "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member });
                    return Ref.none;
                },
                .ambiguous => |alias| {
                    if (self.diagnostics) |d|
                        alias.diagnose(d, span);
                    return Ref.none;
                },
                .not_qualified => {},
            }
        }
    }

    // If the complete chain stopped at an ordinary target-owned member,
    // resolve the OBJECT prefix as the namespace terminal, then apply the last
    // field as an enum variant / global field / static member. Covers both
    // `alias.Enum.variant` and `facade.engine_alias.Enum.variant`.
    if (self.qualifiedTypeName(fa.object)) |object_path| {
        defer self.alloc.free(object_path);
        const root_end = std.mem.indexOfScalar(u8, object_path, '.') orelse object_path.len;
        const root = object_path[0..root_end];
        if (!self.identifierBindsVisibleValue(root)) {
            switch (self.qualifiedMemberVerdict(object_path)) {
                .selected => |sel| {
                    const saved_global_src = self.lexicalContext();
                    self.setAuthorContext(sel.author.id);
                    var global_info: ?program_index_mod.GlobalInfo = null;
                    if (self.program_index.lookup(.global, sel.member)) |fallback| {
                        switch (self.selectGlobalAuthor(sel.member)) {
                            .resolved => |g| global_info = g,
                            .untracked => global_info = fallback,
                            else => {},
                        }
                    }
                    self.restoreLexicalContext(saved_global_src);
                    if (global_info) |gi| {
                        const value = self.builder.emit(.{ .global_get = gi.id }, gi.ty);
                        return self.lowerFieldAccessOnType(value, gi.ty, fa.field, span);
                    }

                    if (self.namespacedLeafType(object_path)) |ty| {
                        if (self.module.types.get(ty) == .@"enum") {
                            const synth = self.alloc.create(Node) catch null;
                            if (synth) |n| {
                                n.* = .{ .span = span, .data = .{ .enum_literal = .{ .name = fa.field } } };
                                const saved_tt = self.target_type;
                                self.target_type = ty;
                                const ref = self.lowerExpr(n);
                                self.target_type = saved_tt;
                                return ref;
                            }
                        }
                    }

                    const synth = self.alloc.create(Node) catch null;
                    if (synth) |n| {
                        n.* = .{ .span = fa.object.span, .data = .{ .identifier = .{ .name = sel.member } } };
                        const stripped = ast.FieldAccess{ .object = n, .field = fa.field, .is_optional = fa.is_optional };
                        const saved_member_src = self.lexicalContext();
                        self.setAuthorContext(sel.author.id);
                        defer self.restoreLexicalContext(saved_member_src);
                        return self.lowerFieldAccess(&stripped, span);
                    }
                },
                .missing => |m| {
                    if (self.namespaceMissWaits(m)) return Ref.none;
                    if (self.diagnostics) |d|
                        d.addFmt(.err, fa.object.span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member });
                    return Ref.none;
                },
                .ambiguous => |alias| {
                    if (self.diagnostics) |d|
                        alias.diagnose(d, fa.object.span);
                    return Ref.none;
                },
                .not_qualified => {},
            }
        }
    }

    // Bare `Enum.variant` — a qualified enum literal. When the object is a type
    // NAME resolving to an enum (not shadowed by a value binding /
    // global value) and `field` is a PAYLOADLESS variant, construct it like the
    // leading-dot `.variant` in a typed context. Mirrors the `alias.Enum.variant`
    // namespace path above. Restricted to payloadless variants so a payload-
    // carrying `Ev.a(5)` still flows through the call path (which supplies the
    // payload) rather than being hijacked into a zero-arg `.a` here.
    if (fa.object.data == .identifier) {
        const oname = fa.object.data.identifier.name;
        const shadowed = if (self.scope) |s| s.lookup(oname) != null else false;
        if (!shadowed and !self.program_index.contains(.global, oname)) {
            if (self.module.types.findByName(self.module.types.internString(oname))) |ty| {
                if (!ty.isBuiltin() and self.isElseMember(ty, fa.field)) {
                    self.refuseBareElseMember(ty, fa.field, span);
                    return self.builder.enumInit(0, Ref.none, ty);
                }
                if (!ty.isBuiltin() and self.isPayloadlessVariant(ty, fa.field)) {
                    const synth = self.alloc.create(Node) catch null;
                    if (synth) |n| {
                        n.* = .{ .span = span, .data = .{ .enum_literal = .{ .name = fa.field } } };
                        const saved_tt = self.target_type;
                        self.target_type = ty;
                        const ref = self.lowerExpr(n);
                        self.target_type = saved_tt;
                        return ref;
                    }
                }
            }
        }
    }

    // Pack-arity intercept: `<pack_name>.len` in a pack-fn mono's
    // body resolves to the comptime-known N. The mono doesn't
    // materialise the `[]Any` slice that the inline path used, so
    // `args` isn't in scope as a value.
    if (self.pack_param_count) |ppc| {
        if (fa.object.data == .identifier and std.mem.eql(u8, fa.field, "len")) {
            if (ppc.get(fa.object.data.identifier.name)) |n| {
                return self.builder.constInt(@as(i64, @intCast(n)), .i64);
            }
        }
    }

    // Pack value projection: `xs.<m>` where `<m>` is a (zero-arg) method of
    // the pack's constraint protocol projects it over every element →
    // a tuple `(xs[0].<m>(), …, xs[N-1].<m>())`. (`xs.len` handled above.)
    if (self.pack_constraint) |pcon| {
        if (fa.object.data == .identifier) {
            if (pcon.get(fa.object.data.identifier.name)) |proto| {
                if (self.lookupProtocolField(proto, fa.field) != null) {
                    return self.lowerPackValueProjection(fa.object.data.identifier.name, fa.field, span);
                }
            }
        }
    }

    // Interface-only enforcement (Decision): a member access on a
    // constrained pack element `xs[i].<m>` may only name a method of the
    // constraint protocol — not an arbitrary concrete field. Checked here,
    // on the `xs[i]` (index_expr) base, BEFORE substitution erases the
    // "constrained to P" context. Protocol method CALLS go through the call
    // path; a method name passes this check (it's in the protocol).
    if (self.pack_constraint) |pcon| {
        if (fa.object.data == .index_expr and fa.object.data.index_expr.object.data == .identifier) {
            const base_name = fa.object.data.index_expr.object.data.identifier.name;
            if (pcon.get(base_name)) |proto| {
                if (self.lookupProtocolField(proto, fa.field) == null) {
                    if (self.diagnostics) |diags| {
                        diags.addFmt(.err, span, "'{s}' is not part of '{s}' — a pack element exposes only the methods of that constraint or interface", .{ fa.field, proto });
                    }
                    return self.builder.constInt(0, .void);
                }
            }
        }
    }

    // Check for struct constant access: Struct.CONST. The head resolves
    // through THIS source's nominal authority first (the namespace walk above
    // already re-entered with the target module as current source), so
    // same-name structs select their own constants; the process-global
    // "Struct.CONST" spelling is last-wins and remains only the fallback for
    // heads without a tracked author.
    if (fa.object.data == .identifier) {
        const head_name = fa.object.data.identifier.name;
        var author_tracked = false;
        if (self.current_source_file orelse self.main_file) |from| {
            switch (self.selectNominalLeaf(head_name, self.environmentForSource(from).?, false)) {
                .resolved => |head_ty| {
                    if (!head_ty.isBuiltin() and self.plain_struct_authors.contains(head_ty)) {
                        author_tracked = true;
                        if (self.struct_const_by_tid.get(.{ .ty = head_ty, .name = self.module.types.internString(fa.field) })) |info|
                            return self.lowerStructConstant(info);
                    }
                },
                else => {},
            }
        }
        if (!author_tracked) {
            const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ head_name, fa.field }) catch fa.field;
            if (self.struct_const_map.get(qualified)) |info| {
                return self.lowerStructConstant(info);
            }
        }
    }

    // Numeric-limit accessor: `<IntType>.min` / `.max` folds to a comptime
    // const of the queried type (sibling of the identifier-receiver
    // intercepts above). Placed AFTER `Struct.CONST` so a user const named
    // `min`/`max` wins on its own struct; a builtin type name can never
    // name a user struct (reserved), so they never collide.
    if (self.lowerNumericLimit(fa, span)) |ref| return ref;

    // `obj.class` on any Obj-C-class pointer lowers to
    // `object_getClass(obj)`. Sugar; the receiver is opaque so
    // we don't auto-deref. Returns `Class` (alias for *void;
    // there is no typed Class(T) parameterization).
    if (std.mem.eql(u8, fa.field, "class")) {
        const expr_ty = self.inferExprType(fa.object);
        if (self.objc().isObjcClassPointer(expr_ty)) {
            const obj_ref = self.lowerExpr(fa.object);
            const ptr_void = self.module.types.ptrTo(.void);
            const get_class_fid = self.ensureCRuntimeDecl("object_getClass", &.{ptr_void}, ptr_void);
            const args = self.alloc.alloc(Ref, 1) catch unreachable;
            args[0] = obj_ref;
            return self.builder.emit(.{ .call = .{ .callee = get_class_fid, .args = args } }, ptr_void);
        }
    }

    // `obj.field` where `field` is declared with `@ObjcProperty`
    // on a runtime Obj-C class lowers as `[obj field]` (the synthesized
    // getter). Receiver stays opaque — no auto-deref.
    if (self.lookupObjcPropertyOnPointer(fa.object, fa.field)) |prop| {
        return self.lowerObjcPropertyGetter(fa.object, prop, fa.field, span);
    }

    // `self.field` (or `obj.field`) on a *sx-defined-class
    // pointer for a plain instance field (NOT a @ObjcProperty) lowers as
    // `object_getIvar(obj, load(__<Cls>_state_ivar))` + struct_gep on
    // the state struct + load. The receiver is the opaque Obj-C id
    // (matching Apple's `self` semantics); the state lives in the
    // hidden `__sx_state` ivar.
    if (self.lookupObjcDefinedStateFieldOnPointer(fa.object, fa.field)) |info| {
        return self.lowerObjcDefinedStateFieldRead(fa.object, info);
    }

    // `@get` property accessor: `obj.field` where `field` is a `@get` method
    // dispatches as a no-paren method call (`obj.field()`). Detected via type
    // info only (no lowering) so the receiver is not evaluated twice — the
    // synthesized call re-lowers `fa.object` and handles the receiver
    // address-of + any generic binding itself.
    {
        var recv_ty = self.inferExprType(fa.object);
        if (!recv_ty.isBuiltin()) {
            const di = self.module.types.get(recv_ty);
            if (di == .pointer) recv_ty = di.pointer.pointee;
        }
        if (self.getAccessorFor(recv_ty, fa.field) != null) {
            // For an explicit-deref receiver `(*p).getter`, dispatch on the
            // inner pointer `p` (`p.getter`, auto-deref) — semantically identical
            // and it takes the working receiver path (the synthesized call on a
            // `.deref_expr` receiver otherwise mis-lowers the `*self` address).
            var recv_fa = fa.*;
            if (fa.object.data == .deref_expr) recv_fa.object = fa.object.data.deref_expr.operand;
            const callee_node = Node{ .data = .{ .field_access = recv_fa }, .span = span };
            const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = &.{} };
            return self.lowerCall(&syn_call);
        }
    }

    var obj = self.lowerExpr(fa.object);
    var obj_ty = self.inferExprType(fa.object);

    // A guard-narrowed optional local reads through implicitly: the
    // guard proved presence, so plain field access unwraps exactly as
    // the coercion sites do (narrowing parity for member
    // access), BEFORE the pointer auto-deref so a `?*T` takes the
    // ordinary load-through route. `?.` below keeps the optional;
    // explicit spellings stay.
    if (!fa.is_optional and !obj_ty.isBuiltin()) {
        const nrw_info = self.module.types.get(obj_ty);
        if (nrw_info == .optional and self.narrowed_refs.contains(obj)) {
            obj_ty = nrw_info.optional.child;
            obj = self.builder.emit(.{ .optional_unwrap = .{ .operand = obj } }, obj_ty);
        }
    }

    // Auto-deref: if the object is a pointer to a struct, load through it
    if (!obj_ty.isBuiltin()) {
        const ptr_info = self.module.types.get(obj_ty);
        if (ptr_info == .pointer) {
            const pointee = ptr_info.pointer.pointee;
            obj = self.builder.load(obj, pointee);
            obj_ty = pointee;
        }
    }

    // Special fields on slices/strings (NOT structs with .len/.ptr fields)
    if (std.mem.eql(u8, fa.field, "len") or std.mem.eql(u8, fa.field, "ptr")) {
        // Only use length/data_ptr for slice, string, array, vector types
        const is_special = switch (self.module.types.get(obj_ty)) {
            .slice, .array, .vector => true,
            else => false,
        };

        if (is_special) {
            if (std.mem.eql(u8, fa.field, "len")) {
                return self.emitLength(obj, obj_ty);
            }
            {
                const elem_ty = self.getElementType(obj_ty);
                const mp_ty = self.module.types.manyPtrTo(elem_ty);
                return self.builder.emit(.{ .data_ptr = .{ .operand = obj } }, mp_ty);
            }
        }
    }

    // Optional chaining: p?.field
    if (fa.is_optional) {
        return self.lowerOptionalChain(obj, fa, span);
    }

    return self.lowerFieldAccessOnType(obj, obj_ty, fa.field, span);
}

/// True when an `.identifier` receiver text resolves to an in-scope VALUE
/// binding rather than a builtin type. A backtick raw identifier can
/// bind a value whose spelling shadows a builtin type name (`` `f64 := … ``);
/// such a value is reachable through the same three sources the ordinary
/// identifier field-access path consults (see `expr_typer` `.identifier`
/// arm): lexical `scope`, program `global_names`, and module value
/// constants `module_const_map`. The numeric-limit intercept must defer to
/// ordinary field access whenever ANY of the three binds the name, so a
/// raw value field read is never hijacked into a numeric-limit fold
/// (locals, globals, and module-consts alike). A single helper used
/// by both lowering and inference keeps the two resolvers in lockstep
/// (two-resolver defect class).
pub fn identifierBindsValue(self: *Lowering, name: []const u8) bool {
    if (self.scope) |scope| {
        if (scope.lookup(name) != null) return true;
    }
    if (self.program_index.lookup(.global, name) != null) return true;
    if (self.program_index.lookup(.module_const, name) != null) return true;
    return false;
}

/// The type a numeric-limit receiver denotes: a builtin type spelling (`i64`,
/// `usize`) or a compiler-formed constructor (`@int(3, .signed)`). Null when
/// the receiver is not a type spelling. A constructor that does not form a
/// type is `.unresolved`.
///
/// A backtick raw identifier can bind a value whose spelling shadows a builtin
/// type name (`` `f64 := … ``); field access on that value is an ordinary field
/// read, so a raw receiver — and a bare identifier bound through any of scope /
/// globals / module consts — denotes no type here. A bare `.type_expr` receiver
/// is the type spelling itself and folds even while a raw value of the same
/// spelling is bound.
///
/// THE single receiver classifier: lowering, inference and the comptime-int
/// folder all read the queried type through it, so no two of them can disagree
/// about which receiver carries a limit (two-resolver defect class).
pub fn limitReceiverType(self: *Lowering, receiver: *const Node) ?TypeId {
    switch (receiver.data) {
        .identifier => |id| {
            if (id.is_raw or self.identifierBindsValue(id.name)) return null;
            return TypeResolver.resolvePrimitive(id.name);
        },
        .type_expr => |te| {
            if (te.is_raw) return null;
            return TypeResolver.resolvePrimitive(te.name);
        },
        else => return self.probeFormedType(receiver),
    }
}

/// Numeric-limit accessor intercept (`<Type>.min`/`.max`/`.epsilon`/
/// `.minPositive`/`.trueMin`/`.inf`/`.nan`), a sibling of the `Set.X` /
/// `Struct.CONST` / pack-arity identifier-receiver intercepts in
/// `lowerFieldAccess`. Folds the limit to a comptime const of the queried
/// type via the shared `TypeResolver` logic (no second computor) + the
/// existing `constInt` / `constFloat` const paths:
///   - integer `.min`/`.max` → `constInt` (via `TypeTable.integerLimit`);
///   - float `.min`/`.max`/`.epsilon`/`.minPositive`/`.trueMin`/`.inf`/
///     `.nan` → `constFloat` (via `floatLimitOf`).
/// Returns null when the field is not a limit accessor, or the receiver is not
/// a type spelling (a user struct → ordinary field lowering reports
/// field-not-found). A constructor that does not form a type yields a
/// placeholder. Two clean diagnostics (then a placeholder, so lowering
/// finishes and `hasErrors()` aborts the build):
///   - a FLOAT-only accessor on an integer type (`i32.epsilon`, `u8.inf`);
///   - any accessor on a builtin NON-numeric receiver
///     (`bool`/`string`/`void`/`Any`/`noreturn`).
pub fn lowerNumericLimit(self: *Lowering, fa: *const ast.FieldAccess, span: ast.Span) ?Ref {
    if (!TypeResolver.isLimitField(fa.field)) return null;
    const ty = self.limitReceiverType(fa.object) orelse return null;
    if (ty == .unresolved) return self.emitPlaceholder(fa.field);

    if (TypeResolver.isIntLimitField(fa.field)) {
        if (self.module.types.integerLimit(ty, std.mem.eql(u8, fa.field, "max"))) |value| {
            return self.builder.constInt(value, ty);
        }
    }
    if (TypeResolver.floatLimitOf(ty, fa.field)) |value| {
        return self.builder.constFloat(value, ty);
    }
    // The field is a limit accessor, but it does not apply to this type.
    if (self.diagnostics) |d| {
        const name = self.formatTypeName(ty);
        if (self.module.types.isIntegerType(ty)) {
            // Integer receiver + a float-only accessor.
            d.addFmt(.err, span, "type '{s}' has no '.{s}' — '.{s}' applies only to float types (f32/f64); integer types expose only '.min'/'.max'", .{ name, fa.field, fa.field });
        } else {
            // Non-numeric builtin receiver (bool/string/void/Any/noreturn).
            d.addFmt(.err, span, "type '{s}' has no '.{s}' — numeric limits apply only to integer and float types", .{ name, fa.field });
        }
    }
    return self.emitPlaceholder(fa.field);
}

/// `<IntType>.min` / `.max` for the shared comptime-integer folder — the
/// queried type's exact limit through the SAME receiver classifier the value
/// path folds, so an array dimension (`[@int(2, .unsigned).max]i64`) and the
/// expression agree.
pub fn typeLimitInt(self: *Lowering, receiver: *const Node, field: []const u8) ?i128 {
    if (!TypeResolver.isIntLimitField(field)) return null;
    const ty = self.limitReceiverType(receiver) orelse return null;
    return self.module.types.integerBound(ty, std.mem.eql(u8, field, "max"));
}

/// The bytes a string literal denotes, escapes resolved.
pub fn stringLiteralBytes(self: *Lowering, lit: ast.StringLiteral) []const u8 {
    if (lit.form != .quoted) return lit.raw;
    return unescape.unescapeString(self.alloc, lit.raw) catch lit.raw;
}

pub fn lowerStringLiteral(self: *Lowering, lit: ast.StringLiteral) Ref {
    const str = self.stringLiteralBytes(lit);
    const sid = self.module.types.internString(str);
    return self.builder.emit(.{ .const_string = sid }, self.literalType(self.target_type, str.len));
}

/// The type a literal of `len` bytes takes at `target`.
pub fn literalType(self: *Lowering, target: ?TypeId, len: usize) TypeId {
    return switch (self.literalShape(target)) {
        .string => .string,
        .view => .string_z,
        .array => self.module.types.arrayOfSentinel(.u8, @intCast(len), 0),
    };
}

/// The type the literal or untyped constant `node` takes at `target`; null
/// when `node` is typed.
pub fn literalNodeType(self: *Lowering, node: *const Node, target: ?TypeId) ?TypeId {
    if (node.data == .bool_literal) return .bool;
    return switch (program_index_mod.untypedConst(node, self) orelse return null) {
        .integer => integerLiteralType(self, target),
        .float => if (target) |t| (if (Lowering.isFloat(t)) t else .f64) else .f64,
        .string => |lit| self.literalType(target, self.stringLiteralBytes(lit).len),
    };
}

fn integerLiteralType(self: *Lowering, target: ?TypeId) TypeId {
    return self.integerContext(target) orelse self.floatContext(target) orelse .i64;
}

pub const LiteralShape = enum { string, view, array };

/// The shape a string literal takes at `target`: the `[:0]u8` view where the
/// destination names it, the `[N:0]u8` array where it names an array or a byte
/// pointer, and `string` everywhere else.
pub fn literalShape(self: *Lowering, target: ?TypeId) LiteralShape {
    const t = target orelse return .string;
    if (t == .string_z) return .view;
    if (t.isBuiltin()) return .string;
    return switch (self.module.types.get(t)) {
        .array => |a| if (a.element == .u8) .array else .string,
        .many_pointer => |mp| if (mp.element == .u8 or mp.element == .i8) .array else .string,
        .optional => |o| self.literalShape(o.child),
        else => .string,
    };
}

pub fn stringLiteralFits(self: *Lowering, ty: TypeId) bool {
    return ty == .string or self.literalShape(ty) != .string;
}

/// Lower a struct-level constant value (e.g., Phys.GRAVITY).
pub fn lowerStructConstant(self: *Lowering, info: StructConstInfo) Ref {
    var demand = self.enterDemand(if (info.ty) |ty| .{ .coerce = ty } else null);
    defer demand.restore();
    const value = self.lowerExpr(info.value);
    return if (info.ty) |ty| self.coerceToType(value, self.builder.getRefType(value), ty) else value;
}

/// Lower optional chaining: `p?.field` where p is ?T
/// Produces ?FieldType: some(unwrap(p).field) if p has value, else null
/// If FieldType is already optional (?U), flattens to ?U (no double wrapping)
pub fn lowerOptionalChain(self: *Lowering, obj: Ref, fa: *const ast.FieldAccess, span: ast.Span) Ref {
    const obj_ty = self.inferExprType(fa.object);
    // Get the inner (non-optional) type
    const inner_ty = if (!obj_ty.isBuiltin()) blk: {
        const info = self.module.types.get(obj_ty);
        break :blk if (info == .optional) info.optional.child else obj_ty;
    } else obj_ty;

    // `@get` accessor through `?.`: if the unwrapped (and pointer-deref'd)
    // receiver has a getter for this field, the some-branch dispatches the
    // getter instead of a struct-field read. A synthetic receiver local (typed
    // `inner_ty`) lets the existing getter intercept in `lowerFieldAccess` do
    // the deref / address-of; we bind it type-only here for the return-type
    // query, then fill its ref in the some-branch.
    var deref_inner = inner_ty;
    if (!deref_inner.isBuiltin() and self.module.types.get(deref_inner) == .pointer)
        deref_inner = self.module.types.get(deref_inner).pointer.pointee;
    const getter_recv: ?[]const u8 = if (self.scope != null and self.getAccessorFor(deref_inner, fa.field) != null) blk: {
        var buf: [40]u8 = undefined;
        const nm = std.fmt.bufPrint(&buf, "$oc_recv_{d}", .{self.block_counter}) catch "$oc_recv";
        self.block_counter += 1;
        const owned = self.alloc.dupe(u8, nm) catch break :blk null;
        // Type-only binding for the return-type query: type it as a POINTER to
        // the struct so inference routes through the (working) pointer-deref
        // getter path for both `?T` and `?*T`. The some-branch re-binds it to
        // the actual unwrapped receiver before lowering.
        self.scope.?.put(owned, .{ .ref = Ref.none, .ty = self.module.types.ptrTo(deref_inner), .is_alloca = false });
        break :blk owned;
    } else null;
    const read_node: ?*Node = if (getter_recv) |nm| blk: {
        const id = self.alloc.create(Node) catch break :blk null;
        id.* = .{ .span = span, .data = .{ .identifier = .{ .name = nm } } };
        const rn = self.alloc.create(Node) catch break :blk null;
        rn.* = .{ .span = span, .data = .{ .field_access = .{ .object = id, .field = fa.field } } };
        break :blk rn;
    } else null;

    // Warm a generic-instance getter's monomorph BEFORE typing the chain: a
    // cold instance method is absent from `resolveFuncByName`, so `resultType`
    // would resolve the getter to `.unresolved` → a `?unresolved` merge type
    // that panics at LLVM emission. Lowering it now binds its type parameter so
    // both the type query and the some-branch call see the concrete signature.
    if (getter_recv != null) {
        const tn = self.module.types.formatTypeName(self.alloc, deref_inner, null);
        if (self.genericInstanceMethod(tn, fa.field)) |gm| _ = self.ensureGenericInstanceMethodLowered(gm);
    }

    // Get the field type on the inner type (the getter's return type, if any).
    const field_ty = if (read_node) |rn| self.inferExprType(rn) else self.resolveFieldType(inner_ty, fa.field);
    // If field is already optional, flatten (don't double-wrap)
    const field_already_optional = if (!field_ty.isBuiltin()) self.module.types.get(field_ty) == .optional else false;
    const result_ty = if (field_already_optional) field_ty else self.module.types.optionalOf(field_ty);

    // Check if optional has value
    const has_val = self.builder.emit(.{ .optional_has_value = .{ .operand = obj } }, .bool);

    // Create blocks
    const some_bb = self.freshBlock("chain.some");
    const none_bb = self.freshBlock("chain.none");
    const merge_bb = self.freshBlockWithParams("chain.merge", &.{result_ty});

    self.builder.condBr(has_val, some_bb, &.{}, none_bb, &.{});

    // Some: unwrap, access field (already ?FieldType if flattened, else wrap)
    self.builder.switchToBlock(some_bb);
    const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = obj } }, inner_ty);
    const field_val = if (read_node) |rn| blk: {
        // Re-bind the synthetic receiver to the unwrapped value, then dispatch
        // the getter through the normal field-access intercept. A `?*T` unwraps
        // to the pointer receiver directly; a `?T` unwraps to a value that the
        // getter (`self: *T`) needs to address, so materialize it into an alloca
        // and bind it like an ordinary `T` local (is_alloca).
        if (!inner_ty.isBuiltin() and self.module.types.get(inner_ty) == .pointer) {
            self.scope.?.put(getter_recv.?, .{ .ref = unwrapped, .ty = inner_ty, .is_alloca = false });
        } else {
            // Materialize the value and bind the alloca POINTER as a `*T` value
            // (not an is_alloca `T`), so the receiver path is identical to the
            // `?*T` case — a plain pointer receiver the getter intercept derefs.
            const slot = self.builder.alloca(inner_ty);
            self.builder.store(slot, unwrapped);
            self.scope.?.put(getter_recv.?, .{ .ref = slot, .ty = self.module.types.ptrTo(inner_ty), .is_alloca = false });
        }
        break :blk self.lowerExpr(rn);
    } else blk: {
        // Real-field read. For a `?*T` the unwrapped value is the POINTER, so
        // load through it before the struct-field access — `lowerFieldAccessOnType`
        // does not auto-deref, and a `structGet` on the raw pointer would read
        // the pointer bits as the field (silent garbage). A `?T` value optional
        // accesses the unwrapped value directly.
        var fobj = unwrapped;
        var fty = inner_ty;
        if (!fty.isBuiltin() and self.module.types.get(fty) == .pointer) {
            const pointee = self.module.types.get(fty).pointer.pointee;
            fobj = self.builder.load(unwrapped, pointee);
            fty = pointee;
        }
        break :blk self.lowerFieldAccessOnType(fobj, fty, fa.field, span);
    };
    const some_result = if (field_already_optional) field_val else self.builder.emit(.{ .optional_wrap = .{ .operand = field_val } }, result_ty);
    self.builder.br(merge_bb, &.{some_result});

    // None: produce null optional
    self.builder.switchToBlock(none_bb);
    const none_result = self.builder.constNull(result_ty);
    self.builder.br(merge_bb, &.{none_result});

    // Merge
    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, result_ty);
}

/// Lower an indexed optional-chain access: `opt?.xs[i]` where the `?.` field is
/// an array / slice / many-pointer. Mirrors `lowerOptionalChain`'s short-circuit
/// — the index applies in the some-branch, producing `?ElemType` (null when the
/// receiver was null). `child` is the unwrapped container type, `elem_ty` the
/// indexed element type.
pub fn lowerOptionalChainIndex(self: *Lowering, ie: *const ast.IndexExpr, child: TypeId, elem_ty: TypeId) Ref {
    // The chained `?.` field access produced the optional value; lower it.
    const opt_val = self.lowerExpr(ie.object);
    // If the element is itself optional, indexing flattens (no double-wrap),
    // matching the field-chain `?.` flattening rule.
    const elem_is_optional = !elem_ty.isBuiltin() and self.module.types.get(elem_ty) == .optional;
    const result_ty = if (elem_is_optional) elem_ty else self.module.types.optionalOf(elem_ty);

    const has_val = self.builder.emit(.{ .optional_has_value = .{ .operand = opt_val } }, .bool);

    const some_bb = self.freshBlock("chain.some");
    const none_bb = self.freshBlock("chain.none");
    const merge_bb = self.freshBlockWithParams("chain.merge", &.{result_ty});

    self.builder.condBr(has_val, some_bb, &.{}, none_bb, &.{});

    // Some: unwrap the container, index it. A `?*[N]T` unwraps to the pointer
    // (GEP through it); a value container (`?[N]T` / `?[]T`) unwraps to the
    // aggregate value and `index_get`s the element.
    self.builder.switchToBlock(some_bb);
    const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = opt_val } }, child);
    const idx = self.lowerIndexOperand(ie.index);
    const elem_val = if (self.ptrToArrayElem(child)) |pelem| blk: {
        const gep = self.builder.emit(.{ .index_gep = .{ .lhs = unwrapped, .rhs = idx } }, self.module.types.ptrTo(pelem));
        break :blk self.builder.load(gep, pelem);
    } else self.builder.emit(.{ .index_get = .{ .lhs = unwrapped, .rhs = idx } }, elem_ty);
    const some_result = if (elem_is_optional) elem_val else self.builder.emit(.{ .optional_wrap = .{ .operand = elem_val } }, result_ty);
    self.builder.br(merge_bb, &.{some_result});

    // None: null optional.
    self.builder.switchToBlock(none_bb);
    const none_result = self.builder.constNull(result_ty);
    self.builder.br(merge_bb, &.{none_result});

    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, result_ty);
}

/// Field access on a known type (shared by regular field access and optional chaining)
/// A letter-swizzle (`.x`/`.xy`/`.rgba`, …). Position letters (`xyzw`) and
/// colour letters (`rgba`) are two sets; a name uses one set. Each letter
/// names a lane 0..3. One letter is a scalar; two or more build a
/// `@Vector(N, T)` from a vector receiver and an `[N]T` from an array or
/// slice.
pub const SwizzleSet = enum { xyzw, rgba };

pub const Swizzle = struct {
    lanes: [16]u8 = [_]u8{0} ** 16,
    len: u8 = 0,
    set: SwizzleSet = .xyzw,

    pub fn maxLane(self: Swizzle) u32 {
        var m: u8 = 0;
        for (self.lanes[0..self.len]) |lane| {
            if (lane > m) m = lane;
        }
        return m;
    }

    pub fn hasDuplicate(self: Swizzle) bool {
        var seen: u8 = 0;
        for (self.lanes[0..self.len]) |lane| {
            const bit: u8 = @as(u8, 1) << @intCast(lane);
            if (seen & bit != 0) return true;
            seen |= bit;
        }
        return false;
    }
};

pub const SwizzleParse = union(enum) {
    /// First character is not a swizzle letter — not a shuffle name.
    none,
    ok: Swizzle,
    mixed,
    bad_letter,
    too_long,
};

pub const SwizzleRecv = enum { vector, array, slice };

/// Parse a field name as a letter-swizzle. A name that does not start with
/// a swizzle letter is `.none` so struct fields and `.len`/`.ptr` stay
/// ordinary. A name that starts as a swizzle and then mixes sets, uses a
/// non-letter, or exceeds 16 letters is a swizzle error (not a miss).
pub fn parseSwizzle(field: []const u8) SwizzleParse {
    if (field.len == 0) return .none;
    const first = swizzleLetter(field[0]) orelse return .none;
    if (field.len > 16) return .too_long;
    var sw = Swizzle{ .len = @intCast(field.len), .set = first.set };
    sw.lanes[0] = first.lane;
    for (field[1..], 1..) |c, i| {
        const next = swizzleLetter(c) orelse return .bad_letter;
        if (next.set != sw.set) return .mixed;
        sw.lanes[i] = next.lane;
    }
    return .{ .ok = sw };
}

const SwizzleLetter = struct { lane: u8, set: SwizzleSet };

fn swizzleLetter(c: u8) ?SwizzleLetter {
    return switch (c) {
        'x' => .{ .lane = 0, .set = .xyzw },
        'y' => .{ .lane = 1, .set = .xyzw },
        'z' => .{ .lane = 2, .set = .xyzw },
        'w' => .{ .lane = 3, .set = .xyzw },
        'r' => .{ .lane = 0, .set = .rgba },
        'g' => .{ .lane = 1, .set = .rgba },
        'b' => .{ .lane = 2, .set = .rgba },
        'a' => .{ .lane = 3, .set = .rgba },
        else => null,
    };
}

/// Single-letter form of `parseSwizzle`: `.x`/`.y`/`.z`/`.w` or `.r`/`.g`/`.b`/`.a`
/// → lane 0..3. Multi-letter names and non-lane fields return null.
pub fn vectorLaneIndex(field: []const u8) ?u32 {
    return switch (parseSwizzle(field)) {
        .ok => |sw| if (sw.len == 1) sw.lanes[0] else null,
        else => null,
    };
}

pub fn swizzleRecvOf(self: *Lowering, ty: TypeId) ?SwizzleRecv {
    if (ty.isBuiltin()) return null;
    return switch (self.module.types.get(ty)) {
        .vector => .vector,
        .array => .array,
        .slice => .slice,
        else => null,
    };
}

pub fn swizzleStaticLen(self: *Lowering, ty: TypeId) ?u32 {
    if (ty.isBuiltin()) return null;
    return switch (self.module.types.get(ty)) {
        .vector => |v| v.length,
        .array => |a| a.length,
        else => null,
    };
}

pub fn swizzleResultType(self: *Lowering, recv: SwizzleRecv, elem: TypeId, sw: Swizzle) TypeId {
    if (sw.len == 1) return elem;
    return switch (recv) {
        .vector => self.module.types.vectorOf(elem, sw.len),
        .array, .slice => self.module.types.arrayOf(elem, sw.len),
    };
}

pub fn diagnoseSwizzleParse(self: *Lowering, field: []const u8, parsed: SwizzleParse, span: ast.Span) void {
    const d = self.diagnostics orelse return;
    switch (parsed) {
        .mixed => d.addFmt(.err, span, "cannot mix position and colour letters in swizzle '{s}'", .{field}),
        .bad_letter => d.addFmt(.err, span, "invalid swizzle '{s}'", .{field}),
        .too_long => d.addFmt(.err, span, "swizzle '{s}' is longer than 16 letters", .{field}),
        .none, .ok => {},
    }
}

pub fn diagnoseSwizzleOob(self: *Lowering, field: []const u8, sw: Swizzle, obj_ty: TypeId, width: u32, span: ast.Span) void {
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "swizzle '{s}' reads lane {d} of '{s}', which has {d} element{s}", .{
            field,
            sw.maxLane(),
            self.formatTypeName(obj_ty),
            width,
            if (width == 1) "" else "s",
        });
    }
}

fn extractSwizzleLane(self: *Lowering, obj: Ref, _: TypeId, recv: SwizzleRecv, lane: u8, elem_ty: TypeId) Ref {
    return switch (recv) {
        .vector, .array => self.builder.structGet(obj, lane, elem_ty),
        .slice => blk: {
            const idx = self.builder.constInt(lane, .i64);
            break :blk self.builder.emit(.{ .index_get = .{ .lhs = obj, .rhs = idx } }, elem_ty);
        },
    };
}

pub fn lowerSwizzleRead(self: *Lowering, obj: Ref, obj_ty: TypeId, recv: SwizzleRecv, sw: Swizzle) Ref {
    const elem_ty = self.getElementType(obj_ty);
    if (sw.len == 1) return extractSwizzleLane(self, obj, obj_ty, recv, sw.lanes[0], elem_ty);
    var elems: [16]Ref = undefined;
    for (sw.lanes[0..sw.len], 0..) |lane, i| {
        elems[i] = extractSwizzleLane(self, obj, obj_ty, recv, lane, elem_ty);
    }
    const result_ty = self.swizzleResultType(recv, elem_ty, sw);
    return self.builder.structInit(elems[0..sw.len], result_ty);
}

/// A `@get` property accessor for `obj_ty.field`, or null. A `@get` method is a
/// normal method (registered `Type.method`) marked `is_get`; it is reachable via
/// no-paren field syntax. Handles a generic-struct instance (`List(i64).len`)
/// and a plain struct (`Foo.bar`). `ty` must be the dereferenced (non-pointer)
/// receiver type.
pub fn getAccessorFor(self: *Lowering, ty: TypeId, field: []const u8) ?*const ast.FnDecl {
    if (ty.isBuiltin()) return null;
    // A REAL field of this name wins over a same-name `@get` (a getter must not
    // shadow stored data on the read path). If the struct genuinely declares the
    // field, this is not a property access.
    if (self.lookupField(ty, field) != .missing) return null;
    // Generic instance: genericInstanceMethod is keyed by the instance's table
    // name (e.g. "List__i64").
    const tn = self.module.types.formatTypeName(self.alloc, ty, null);
    if (self.genericInstanceMethod(tn, field)) |m| {
        return if (m.fd.is_get) m.fd else null;
    }
    // Plain nominal struct: select from this TypeId's author before the global
    // compatibility map, so same-display-name structs keep distinct accessors.
    if (self.plainStructMethod(ty, field)) |m| {
        return if (m.fd.is_get) m.fd else null;
    }
    if (self.hasPlainStructAuthor(ty)) return null;
    // Fallback for methods supplied outside the inline struct decl.
    const info = self.module.types.get(ty);
    if (info == .@"struct") {
        const sname = self.module.types.getString(info.@"struct".name);
        const q = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, field }) catch return null;
        if (self.program_index.lookup(.function, q)) |fd| {
            return if (fd.is_get) fd else null;
        }
    }
    return null;
}

/// Pre-lowering getter queries have a receiver type but no value bindings.
pub fn getterReturnTypeOnDeref(self: *Lowering, deref_ty: TypeId, field: []const u8) ?TypeId {
    if (self.getAccessorFor(deref_ty, field) == null) return null;
    var scope = lower.Scope.init(self.alloc, self.scope, &self.next_binding_id);
    defer scope.deinit();
    scope.put("$getter", .{ .ref = Ref.none, .ty = self.module.types.ptrTo(deref_ty), .is_alloca = false });
    const saved_scope = self.scope;
    self.scope = &scope;
    defer self.scope = saved_scope;
    var receiver = Node{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "$getter" } } };
    var callee = Node{ .span = receiver.span, .data = .{ .field_access = .{ .object = &receiver, .field = field } } };
    const call = ast.Call{ .callee = &callee, .args = &.{} };
    return self.callResolver().resultType(&call);
}

pub fn getSetterFor(self: *Lowering, ty: TypeId, field: []const u8) ?*const ast.FnDecl {
    if (ty.isBuiltin()) return null;
    // A REAL field of this name wins over a same-name `@set` (a setter must not
    // shadow stored data on the write path).
    if (self.lookupField(ty, field) != .missing) return null;
    const eff = std.fmt.allocPrint(self.alloc, "{s}" ++ Lowering.setter_eff_suffix, .{field}) catch return null;
    // Generic instance: keyed by the instance's table name (e.g. "List__i64").
    const tn = self.module.types.formatTypeName(self.alloc, ty, null);
    if (self.genericInstanceMethod(tn, eff)) |m| {
        return if (m.fd.is_set) m.fd else null;
    }
    // Plain nominal struct: source-pin the setter to this TypeId's author.
    if (self.plainStructMethod(ty, eff)) |m| {
        return if (m.fd.is_set) m.fd else null;
    }
    if (self.hasPlainStructAuthor(ty)) return null;
    // Fallback for methods supplied outside the inline struct decl.
    const info = self.module.types.get(ty);
    if (info == .@"struct") {
        const sname = self.module.types.getString(info.@"struct".name);
        const q = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, eff }) catch return null;
        if (self.program_index.lookup(.function, q)) |fd| {
            return if (fd.is_set) fd else null;
        }
    }
    return null;
}

/// The type `.set` and `.name` answer with: on a live error (or an `any`
/// viewing one) `.set` is the error that declares the live member and `.name`
/// its spelling; on a `Type`, `.name` is the type's own. Null when the receiver
/// carries neither. Shared by lowering and inference.
pub fn errorViewFieldType(self: *Lowering, obj_ty: TypeId, field: []const u8) ?TypeId {
    const is_name = std.mem.eql(u8, field, "name");
    if (obj_ty == .type_value) return if (is_name) .string else null;
    if (!is_name and !std.mem.eql(u8, field, "set")) return null;
    const holds_member = obj_ty == .any or (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .@"error");
    if (!holds_member) return null;
    return if (is_name) .string else .type_value;
}

/// `.set` / `.name` on `obj`. An `any` receiver reads the member word out of
/// the view first; the registry tables answer from it either way.
fn lowerErrorViewField(self: *Lowering, obj: Ref, obj_ty: TypeId, field: []const u8) ?Ref {
    const ty = self.errorViewFieldType(obj_ty, field) orelse return null;
    if (obj_ty == .type_value) {
        const args = self.alloc.dupe(Ref, &.{obj}) catch return null;
        return self.builder.callBuiltin(.type_name, args, .string);
    }
    const member = if (obj_ty == .any) self.builder.emit(.{ .unbox_any = .{ .operand = obj } }, .u32) else obj;
    return if (ty == .string)
        self.builder.emit(.{ .error_member_name_get = .{ .operand = member } }, .string)
    else
        self.builder.emit(.{ .error_owner_get = .{ .operand = member } }, .type_value);
}

pub fn lowerFieldAccessOnType(self: *Lowering, obj: Ref, obj_ty: TypeId, field: []const u8, span: ast.Span) Ref {
    if (lowerErrorViewField(self, obj, obj_ty, field)) |r| return r;
    const field_name_id = self.module.types.internString(field);

    // Check if it's a union type
    if (!obj_ty.isBuiltin()) {
        const info = self.module.types.get(obj_ty);
        switch (info) {
            .@"enum" => |u| if (u.hasPayload()) {
                for (u.variants, 0..) |v, i| {
                    if (v.name == field_name_id) {
                        return self.builder.emit(.{ .enum_payload = .{ .base = obj, .field_index = @intCast(i) } }, v.payload);
                    }
                }
                // Promoted members of a struct variant
                if (promotedUnionMemberRead(self, obj, obj_ty, field, span)) |r| return r;
            },
            .@"union" => |u| {
                // Union — use union_get to reinterpret bytes
                for (u.fields, 0..) |f, i| {
                    if (f.name == field_name_id) {
                        return self.builder.emit(.{ .union_get = .{ .base = obj, .field_index = @intCast(i) } }, f.ty);
                    }
                }
                // Promoted members of a struct variant
                if (promotedUnionMemberRead(self, obj, obj_ty, field, span)) |r| return r;
            },
            else => {},
        }
    }

    // Letter-swizzle on a vector, array, or slice. Shares parseSwizzle
    // with the write path. A non-swizzle name falls through.
    if (self.swizzleRecvOf(obj_ty)) |recv| {
        switch (parseSwizzle(field)) {
            .none => {},
            .ok => |sw| {
                if (self.swizzleStaticLen(obj_ty)) |width| {
                    if (sw.maxLane() >= width) {
                        self.diagnoseSwizzleOob(field, sw, obj_ty, width, span);
                        return self.emitPlaceholder(field);
                    }
                }
                return self.lowerSwizzleRead(obj, obj_ty, recv, sw);
            },
            else => |p| {
                self.diagnoseSwizzleParse(field, p, span);
                return self.emitPlaceholder(field);
            },
        }
    }

    // Closure field access: .fnPtr → field 0, .env → field 1
    if (!obj_ty.isBuiltin()) {
        const cinfo = self.module.types.get(obj_ty);
        if (cinfo == .closure) {
            if (std.mem.eql(u8, field, "fnPtr")) {
                const fn_ptr_ty = self.module.types.ptrTo(.void);
                return self.builder.structGet(obj, 0, fn_ptr_ty);
            } else if (std.mem.eql(u8, field, "env")) {
                const env_ty = self.module.types.ptrTo(.void);
                return self.builder.structGet(obj, 1, env_ty);
            }
        }
    }

    // Resolve struct field index and type
    switch (self.mentionField(obj_ty, field, span)) {
        .hit => |h| return self.builder.structGet(obj, h.index, h.ty),
        .private => return self.emitPlaceholder(field),
        .missing => {},
    }

    return self.emitFieldError(obj_ty, field, span);
}

pub fn lowerEnumLiteral(self: *Lowering, el: *const ast.EnumLiteral) Ref {
    var target = self.target_type orelse .unresolved;

    // An OPTIONAL destination types the literal by its CHILD: `.x` flowing
    // into a `?E` slot must produce an `E` for the coercion layer to wrap
    // (`.optional_wrap`). Resolving against the optional itself fell into
    // resolveVariantValue's non-enum fallback — variant 0, mis-typed as
    // the optional.
    while (!target.isBuiltin()) {
        const info = self.module.types.get(target);
        if (info != .optional) break;
        target = info.optional.child;
    }

    const cs = self.builder.current_span;
    const span = ast.Span{ .start = cs.start, .end = cs.end };

    // An error-set destination types `.Name` as that set's member, membership
    // checked and optional-wrapped from `self.target_type`, which still holds
    // the un-unwrapped destination.
    if (!target.isBuiltin() and self.module.types.get(target) == .@"error") {
        return self.lowerErrorMemberShorthand(el.name, span);
    }

    // The destination must be a known enum that carries the
    // named variant; any other shape would lower to a silent 0.
    if (target == .unresolved) {
        // Cascade guard: an unresolved destination usually means the slot's
        // TYPE already failed to resolve and was diagnosed (not-visible /
        // ambiguous); a second error on the same line is noise.
        if (self.diagnostics) |d| {
            if (!d.hasErrors()) {
                d.addFmt(.err, span, "enum literal '.{s}' has no destination type to resolve against", .{el.name});
            }
        }
        return self.builder.enumInit(0, Ref.none, target);
    }
    var known_variant = false;
    if (!target.isBuiltin()) {
        const info = self.module.types.get(target);
        const name_id = self.module.types.internString(el.name);
        switch (info) {
            .@"enum" => |e| {
                for (e.variants) |v| {
                    if (v.name == name_id) {
                        known_variant = true;
                        break;
                    }
                }
                if (!known_variant) {
                    if (self.isElseMember(target, el.name)) {
                        self.refuseBareElseMember(target, el.name, span);
                        return self.builder.enumInit(0, Ref.none, target);
                    }
                    self.emitBadEnumVariant(target, e, el.name, span);
                }
            },
            else => {},
        }
    }
    if (!known_variant) {
        if (self.diagnostics) |d| {
            const builtin_or_non_enum = target.isBuiltin() or switch (self.module.types.get(target)) {
                .@"enum" => false,
                else => true,
            };
            if (builtin_or_non_enum) {
                d.addFmt(.err, span, "enum literal '.{s}' cannot type itself from non-enum destination '{s}'", .{ el.name, self.formatTypeName(target) });
            }
        }
        return self.builder.enumInit(0, Ref.none, target);
    }

    const tag = self.resolveVariantValue(target, el.name);
    return self.builder.enumInit(tag, Ref.none, target);
}

/// Is `name` the `else` member of enum `ty`?
pub fn isElseMember(self: *Lowering, ty: TypeId, name: []const u8) bool {
    if (ty.isBuiltin()) return false;
    return switch (self.module.types.get(ty)) {
        .@"enum" => |e| if (e.else_member) |m| std.mem.eql(u8, self.module.types.getString(m), name) else false,
        else => false,
    };
}

/// `E.rest(v)` when `name` is the else member of `ty`: the value IS `v` in
/// the backing integer, retyped as `E`. Any other argument count is the bare
/// spelling's error. Null when `name` is not the else member.
pub fn elseMemberCall(self: *Lowering, ty: TypeId, name: []const u8, args: []const Ref, span: ast.Span) ?Ref {
    if (!self.isElseMember(ty, name)) return null;
    if (args.len != 1) {
        self.refuseBareElseMember(ty, name, span);
        return self.builder.enumInit(0, Ref.none, ty);
    }
    const backing = self.enumBackingType(ty).?;
    const as_backing = self.coerceToType(args[0], self.builder.getRefType(args[0]), backing);
    return self.builder.emit(.{ .bitcast = .{ .operand = as_backing, .from = backing, .to = ty } }, ty);
}

/// The else member spelled without its value.
pub fn refuseBareElseMember(self: *Lowering, ty: TypeId, name: []const u8, span: ast.Span) void {
    if (self.diagnostics) |d| d.addFmt(.err, span, "'{s}' takes the value it names: {s}.{s}(v)", .{ name, self.formatTypeName(ty), name });
}

/// Is `field` a variant of enum `ty` whose payload is `void`? Used by
/// `lowerFieldAccess` to recognise a bare
/// `Enum.variant` qualified literal (payload-carrying variants stay on the call
/// path, which supplies the payload). False for any non-enum type / unknown field.
pub fn isPayloadlessVariant(self: *Lowering, ty: TypeId, field: []const u8) bool {
    return switch (self.module.types.get(ty)) {
        .@"enum" => |e| blk: {
            for (e.variants) |v| if (std.mem.eql(u8, self.module.types.getString(v.name), field)) break :blk (v.payload == .void);
            break :blk false;
        },
        else => false,
    };
}

/// The enum twin of `emitBadVariant`: an unknown variant of a plain enum,
/// with the legal variants listed.
pub fn emitBadEnumVariant(
    self: *Lowering,
    enum_ty: TypeId,
    enum_info: types.TypeInfo.EnumInfo,
    variant_name: []const u8,
    span: ast.Span,
) void {
    const diags = self.diagnostics orelse return;
    const ty_name = self.formatTypeName(enum_ty);
    var list: std.ArrayList(u8) = .empty;
    for (enum_info.variants, 0..) |v, i| {
        if (i > 0) list.appendSlice(self.alloc, ", ") catch return;
        list.appendSlice(self.alloc, self.module.types.getString(v.name)) catch return;
    }
    diags.addFmt(
        .err,
        span,
        "'{s}' is not a variant of '{s}' (variants are: {s})",
        .{ variant_name, ty_name, list.items },
    );
}

/// Lower a `.X` member shorthand against an error-set destination — the set's
/// member `X`, typed as the set, wrapped when the destination is an optional
/// over it. Only reached with such a destination in hand.
pub fn lowerErrorMemberShorthand(self: *Lowering, tag_name: []const u8, span: ast.Span) Ref {
    const t = self.target_type.?;
    const info = self.module.types.get(t);
    const optional_ty: ?TypeId = if (info == .optional) t else null;
    const set_ty = if (info == .optional) info.optional.child else t;
    const member = switch (self.module.types.errorSetMember(set_ty, tag_name)) {
        .one => |id| id,
        .none => blk: {
            // An open channel has no static member set, so it takes any spelling.
            if (!self.channelIsOpen(set_ty)) {
                if (self.diagnostics) |diags| {
                    const set_name = self.module.types.getString(self.module.types.get(set_ty).@"error".name);
                    diags.addFmt(.err, span, "error member '.{s}' is not in error set '{s}'", .{ tag_name, set_name });
                }
            }
            break :blk self.anonymousErrorMember(tag_name);
        },
        .ambiguous => blk: {
            self.emitAmbiguousMember(set_ty, tag_name, span);
            break :blk self.anonymousErrorMember(tag_name);
        },
    };
    const tag = self.builder.constInt(@as(i64, @intCast(member)), set_ty);
    if (optional_ty) |opt_ty| return self.builder.optionalWrap(tag, opt_ty);
    return tag;
}

/// The member `name` names with no set in hand — the anonymous owner's, which
/// no declared set carries.
pub fn anonymousErrorMember(self: *Lowering, name: []const u8) u32 {
    return self.module.types.internMember(types.TagRegistry.anonymous_owner, name);
}

/// Lower a qualified error member `Set.Member` to its member id, typed as `Set`.
/// Membership is `Set`'s, not the destination context's.
pub fn lowerQualifiedErrorMember(self: *Lowering, set_ty: TypeId, member: []const u8, span: ast.Span) Ref {
    const id = switch (self.module.types.errorSetMember(set_ty, member)) {
        .one => |m| m,
        .none => blk: {
            if (self.diagnostics) |diags| {
                const info = self.module.types.get(set_ty).@"error";
                diags.addFmt(.err, span, "error set '{s}' has no member '{s}'", .{ self.module.types.getString(info.name), member });
            }
            break :blk self.anonymousErrorMember(member);
        },
        .ambiguous => blk: {
            self.emitAmbiguousMember(set_ty, member, span);
            break :blk self.anonymousErrorMember(member);
        },
    };
    return self.builder.constInt(@as(i64, @intCast(id)), set_ty);
}

/// Lower a payload enum construction: .Variant{ field_inits }
/// The struct literal provides the payload fields; we wrap them in an enum_init.
pub fn lowerTaggedEnumLiteral(
    self: *Lowering,
    sl: *const ast.StructLiteral,
    variant_name: []const u8,
    union_ty: TypeId,
    union_info: types.TypeInfo.EnumInfo,
    span: ast.Span,
) Ref {
    if (self.findTaggedVariant(union_info, variant_name) == null) {
        self.emitBadEnumVariant(union_ty, union_info, variant_name, span);
        return self.builder.enumInit(0, Ref.none, union_ty);
    }

    const tag = self.resolveVariantValue(union_ty, variant_name);
    const name_id = self.module.types.internString(variant_name);

    // Find the payload type for this variant
    var payload_ty: TypeId = .void;
    for (union_info.variants) |v| {
        if (v.name == name_id) {
            payload_ty = v.payload;
            break;
        }
    }

    if (payload_ty == .void or sl.field_inits.len == 0) {
        // No payload or no fields — just tag
        return self.builder.enumInit(tag, Ref.none, union_ty);
    }

    // Lower the payload as a struct init of the payload type
    const saved_tt = self.target_type;
    self.target_type = payload_ty;
    const payload_fields = self.getStructFields(payload_ty);

    // Scalar (non-aggregate) payload: `.key{ 42 }` where `key`'s payload is a
    // plain i64 — the single field_init IS the payload value. There is no
    // struct to insertvalue into, so wrapping it in a structInit builds an
    // invalid `insertvalue i64 ...`. Emit the value directly.
    if (payload_fields.len == 0) {
        if (sl.field_inits.len > 1) {
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, span, "variant '{s}' takes a single {s} payload, but {d} values were given", .{ variant_name, self.formatTypeName(payload_ty), sl.field_inits.len });
            }
        }
        self.target_type = payload_ty;
        var val = self.lowerExpr(sl.field_inits[0].value);
        const src_ty = self.builder.getRefType(val);
        if (refuseVoidElement(self, src_ty, payload_ty, null, 0, sl.field_inits[0].value.span)) {
            val = self.zeroValue(payload_ty);
        } else {
            val = self.coerceToType(val, src_ty, payload_ty);
        }
        self.target_type = saved_tt;
        return self.builder.enumInit(tag, val, union_ty);
    }

    // Named payload inits (`.key{ a = 1 }`) are a named struct literal of the
    // payload type: reorder-by-name, defaults, and the visibility mention all
    // live there. The head must be stripped — `lowerStructLiteral` routes a
    // literal that still carries its variant spelling back into this function.
    if (sl.field_inits[0].name != null) {
        var payload_sl = sl.*;
        payload_sl.type_expr = null;
        payload_sl.struct_name = null;
        const payload_val = self.lowerStructLiteral(&payload_sl, span);
        self.target_type = saved_tt;
        return self.builder.enumInit(tag, payload_val, union_ty);
    }

    var fields = std.ArrayList(Ref).empty;
    defer fields.deinit(self.alloc);

    for (sl.field_inits, 0..) |fi, i| {
        if (i < payload_fields.len) {
            const saved_inner = self.target_type;
            self.target_type = payload_fields[i].ty;
            var val = self.lowerExpr(fi.value);
            self.target_type = saved_inner;
            const src_ty = self.builder.getRefType(val);
            if (refuseVoidElement(self, src_ty, payload_fields[i].ty, payload_fields[i].name, i, fi.value.span)) {
                val = self.zeroValue(payload_fields[i].ty);
            } else {
                val = self.coerceToType(val, src_ty, payload_fields[i].ty);
            }
            fields.append(self.alloc, val) catch unreachable;
        } else {
            fields.append(self.alloc, self.lowerExpr(fi.value)) catch unreachable;
        }
    }

    // Pad missing payload fields with zeroes
    if (fields.items.len < payload_fields.len) {
        for (payload_fields[fields.items.len..]) |sf| {
            fields.append(self.alloc, self.zeroValue(sf.ty)) catch unreachable;
        }
    }

    const payload = self.builder.structInit(fields.items, payload_ty);
    self.target_type = saved_tt;

    return self.builder.enumInit(tag, payload, union_ty);
}

pub fn findTaggedVariant(
    self: *Lowering,
    union_info: types.TypeInfo.EnumInfo,
    variant_name: []const u8,
) ?usize {
    const name_id = self.module.types.internString(variant_name);
    for (union_info.variants, 0..) |v, i| {
        if (v.name == name_id) return i;
    }
    return null;
}

/// A variant's tag by name.
pub fn resolveVariantValue(self: *Lowering, ty: TypeId, variant_name: []const u8) i64 {
    if (ty.isBuiltin()) return 0;
    const info = self.module.types.get(ty);
    const name_id = self.module.types.internString(variant_name);
    switch (info) {
        .@"enum" => |e| {
            for (e.variants, 0..) |v, i| {
                if (v.name == name_id) {
                    if (e.values) |vals| {
                        if (i < vals.len) return vals[i];
                    }
                    return @intCast(i);
                }
            }
        },
        else => {},
    }
    return 0;
}

/// True iff `variant_name` is a declared variant of the enum
/// `ty`. The call-shaped construction paths (`.Variant(payload)` /
/// `Type.Variant(payload)`) must gate on this BEFORE `resolveVariantIndex`,
/// which returns 0 (the zeroth variant) for an unknown name — silently
/// building the wrong value instead of erroring (the payloadless `.Variant`
/// and `case .Variant` paths already validate; this closes the payload hole).
pub fn hasVariant(self: *Lowering, ty: TypeId, variant_name: []const u8) bool {
    if (ty.isBuiltin()) return false;
    const name_id = self.module.types.internString(variant_name);
    return switch (self.module.types.get(ty)) {
        .@"enum" => |e| blk: {
            for (e.variants) |v| if (v.name == name_id) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Resolve a variant name to its tag index within an enum or union type.
pub fn resolveVariantIndex(self: *Lowering, ty: TypeId, variant_name: []const u8) u32 {
    if (ty.isBuiltin()) return 0;
    const info = self.module.types.get(ty);
    const name_id = self.module.types.internString(variant_name);
    switch (info) {
        .@"enum" => |e| {
            for (e.variants, 0..) |v, i| {
                if (v.name == name_id) return @intCast(i);
            }
        },
        else => {},
    }
    return 0;
}

pub fn lowerArrayLiteral(self: *Lowering, al: *const ast.ArrayLiteral, span: ast.Span) Ref {
    var elems = std.ArrayList(Ref).empty;
    defer elems.deinit(self.alloc);

    const result_ty = self.builtArrayLiteralType(al, span) orelse return self.builder.constUndef(.unresolved);
    const elem_ty: TypeId, const sentinel: ?i64 = switch (self.module.types.get(result_ty)) {
        .array => |a| .{ a.element, a.sentinel },
        .vector => |v| .{ v.element, null },
        else => unreachable,
    };

    for (al.elements) |elem| {
        const old_tt = self.target_type;
        self.target_type = elem_ty;
        var val = self.lowerExpr(elem);
        self.target_type = old_tt;
        // Coerce each element to the declared element type. Setting
        // `target_type` above steers literal lowering, but the actual
        // wrap/erase (scalar → optional `{T,i1}`, array → slice header,
        // concrete → protocol, etc.) lives in `coerceToType`. Without this,
        // an `[N]?T` literal stores bare `T`/`null` elements into a slot whose
        // stride is the optional's `{T,i1}` size — corrupting the aggregate
        // (a present element reads back as absent; indexing segfaults).
        //
        // `coerceToType` classifies a same-type element as `.no_op`/`.none`
        // and returns `val` unchanged, so this is a no-op for elements already
        // at `elem_ty` (the common `[N]i64`/`[N]Struct` case).
        if (elem_ty != .unresolved) {
            const val_ty = self.builder.getRefType(val);
            if (refuseVoidElement(self, val_ty, elem_ty, null, elems.items.len, elem.span)) {
                val = self.zeroValue(elem_ty);
            } else if (val_ty != elem_ty) {
                val = self.coerceToType(val, val_ty, elem_ty);
            }
        }
        elems.append(self.alloc, val) catch unreachable;
    }

    if (sentinel) |x| elems.append(self.alloc, self.sentinelValue(x, elem_ty)) catch unreachable;

    return self.builder.structInit(elems.items, result_ty);
}

/// The array or vector a `.[…]` literal builds, shaped by its type prefix,
/// else its target, else its elements. A prefix naming no array, vector or
/// slice is diagnosed here. A literal nothing types is diagnosed only where it
/// is built, because a caller asking its type may still give it a target.
pub fn arrayLiteralType(self: *Lowering, al: *const ast.ArrayLiteral) error{ NotAggregatePrefix, NoElementType }!TypeId {
    const length: u32 = @intCast(al.elements.len);
    if (al.type_expr) |te| {
        const resolved = self.resolveArrayLiteralType(te);
        if (resolved != .unresolved) {
            if (literalAggregate(self, resolved, length)) |ty| return ty;
            if (self.diagnostics) |d| {
                const name = self.formatTypeName(resolved);
                d.addFmt(.err, te.span, "a '.[ ]' literal's type prefix names the aggregate type, not the element type — '{s}' is not an array/vector/slice; annotate the binding instead: `x : [{d}]{s} = .[ … ]`", .{ name, al.elements.len, name });
            }
            return error.NotAggregatePrefix;
        }
    }
    if (self.target_type) |tt| if (literalAggregate(self, tt, length)) |ty| return ty;
    if (length == 0) return self.module.types.arrayOf(.void, 0);
    const elem_ty = self.genericResolver().elementBinding(al.elements) orelse return error.NoElementType;
    return self.module.types.arrayOf(elem_ty, length);
}

/// The type of a `.[…]` literal built at `span`, where a literal nothing
/// types is diagnosed.
pub fn builtArrayLiteralType(self: *Lowering, al: *const ast.ArrayLiteral, span: ast.Span) ?TypeId {
    return self.arrayLiteralType(al) catch |err| {
        if (err == error.NoElementType) if (self.diagnostics) |d|
            d.add(.err, "cannot infer the element type of this array literal — annotate it", span);
        return null;
    };
}

/// The array or vector a `.[…]` of `length` elements builds for the
/// destination `ty`.
fn literalAggregate(self: *Lowering, ty: TypeId, length: u32) ?TypeId {
    if (self.module.types.sliceInfoOf(ty)) |s| return self.module.types.arrayOf(s.element, length);
    if (ty.isBuiltin()) return null;
    return switch (self.module.types.get(ty)) {
        .array => |a| self.module.types.arrayOfSentinel(a.element, length, a.sentinel),
        .vector => |v| self.module.types.vectorOf(v.element, length),
        else => null,
    };
}

/// Resolve the type annotation on an array literal (e.g. `@Vector(3,f32).[...]`).
/// Handles call nodes (`@Vector(3,f32)`), parameterized_type_expr, and identifier/type_expr.
/// `*<operand>` where the operand denotes a TYPE resolves to the pointer
/// type's Type value (`*i64` → the TypeId of `*i64`). Returns null when the
/// operand is a value — the caller falls through to ordinary address-of.
/// A scope local, a module global, or this module's own non-type declaration
/// wins over a same-named type: taking a value's address must never silently
/// become a type. Nested address_of recurses so `**T` / `***T` resolve
/// inside-out.
fn addrOfTypeOperand(self: *Lowering, node: *const Node) ?TypeId {
    switch (node.data) {
        .identifier => |id| {
            if (self.scope) |sc| {
                if (sc.lookup(id.name) != null) return null;
            }
            if (self.program_index.contains(.global, id.name)) return null;
            if (self.selectHeadType(id.name) == .not_a_type) return null;
            const tid = self.resolveArrayLiteralType(node);
            if (tid == .unresolved) return null;
            return self.module.types.ptrTo(tid);
        },
        .type_expr,
        .slice_type_expr,
        .array_type_expr,
        .pointer_type_expr,
        .many_pointer_type_expr,
        .optional_type_expr,
        .parameterized_type_expr,
        => {
            const tid = self.resolveTypeWithBindings(node);
            if (tid == .unresolved) return null;
            return self.module.types.ptrTo(tid);
        },
        .unary_op => |inner_uop| {
            if (inner_uop.op != .address_of) return null;
            const inner = addrOfTypeOperand(self, inner_uop.operand) orelse return null;
            return self.module.types.ptrTo(inner);
        },
        else => return null,
    }
}

pub fn resolveArrayLiteralType(self: *Lowering, te: *const Node) TypeId {
    switch (te.data) {
        .call => |cl| {
            // `@Vector(3, f32).[…]`
            const callee_name = switch (cl.callee.data) {
                .identifier => |id| id.name,
                .field_access => |fa| fa.field,
                else => return .unresolved,
            };
            if (std.mem.eql(u8, callee_name, contracts.vector_head)) {
                if (cl.args.len == 2) {
                    const length = self.resolveVectorLane(cl.args[0]) orelse return .unresolved;
                    const elem = self.resolveTypeWithBindings(cl.args[1]);
                    return self.module.types.vectorOf(elem, length);
                }
            }
            // `@Array(3, i32).[…]`
            if (std.mem.eql(u8, callee_name, contracts.array_head)) {
                if (cl.args.len == 2) {
                    const length = self.resolveArrayLen(cl.args[0]) orelse return .unresolved;
                    const elem = self.resolveTypeWithBindings(cl.args[1]);
                    return self.module.types.arrayOf(elem, length);
                }
            }
            // `@Slice(u8, u32).[…]`
            if (std.mem.eql(u8, callee_name, contracts.slice_head)) {
                if (cl.args.len == 2) {
                    const elem = self.resolveTypeWithBindings(cl.args[0]);
                    const len_ty = self.resolveSliceLenType(cl.args[1]) orelse return .unresolved;
                    return self.module.types.sliceOfLen(elem, len_ty);
                }
            }
            // Generic-struct typed-literal head (`Box(i64).[...]`): route
            // through the single layout choke-point (CP-1). A qualified head
            // `a.Box(i64).[...]` selects a's OWN template via the namespace edge
            // rather than a global last-wins map; a bare head selects the
            // single bare-VISIBLE author.
            switch (self.selectGenericStructCallee(cl.callee, cl.callee.span)) {
                .template => |t| return self.instantiateGenericStruct(&t, cl.args),
                .poisoned => return .unresolved,
                .not_generic => {},
            }
            return .unresolved;
        },
        .parameterized_type_expr => |pt| return self.resolveParameterizedWithBindings(&pt, te.span),
        .identifier => |id| {
            // Single-hop visibility + ambiguity gate: a 2-flat-hop bare type
            // name in a typed array/vector-literal annotation (`Nums.[1, 2]`) is
            // not bare-visible (consistent with annotations / 0763); ≥2 direct
            // flat same-name authors are ambiguous (loud diagnostic, consistent
            // with the leaf / 0755); a single source-keyed author resolves to
            // ITS TypeId instead of a global `findByName` first-/last-wins pick.
            switch (self.headTypeGate(id.name, te.span)) {
                .ambiguous, .not_visible, .not_a_type => return .unresolved,
                .resolved => |tid| return tid,
                .proceed => {},
            }
            const name_id = self.module.types.internString(id.name);
            return self.module.types.findByName(name_id) orelse .unresolved;
        },
        .type_expr => |inner| {
            if (self.headTypeLeak(inner.name, te.span)) return .unresolved;
            return type_bridge.resolveAstType(te, &self.module.types, &self.program_index);
        },
        // Structural type heads on a typed `.[...]` literal — `[N]T`, `[]T`.
        // These resolve through the canonical `resolveAstType` compound path
        // (which recurses into the element, so `[N]?T` correctly carries the
        // optional element). Without these arms an `array_type_expr` /
        // `slice_type_expr` head falls through to `else => .unresolved`, so a
        // typed `([2]?i64).[ ... ]` loses its `?i64` element type — the null
        // element reaches LLVM as `const_null(.unresolved)` and panics.
        // `resolveTypeWithBindings` is the lowering-side resolver
        // (carries generic bindings); it delegates to `resolveAstType` for
        // these plain structural shapes.
        .array_type_expr,
        .slice_type_expr,
        => return self.resolveTypeWithBindings(te),
        .field_access => |fa| {
            // Module.Type — try to resolve the field as a type name
            const name_id = self.module.types.internString(fa.field);
            return self.module.types.findByName(name_id) orelse .unresolved;
        },
        else => return .unresolved,
    }
}

/// Lower a subscript's INDEX operand. An index is an integer position, never a
/// value of the indexed expression's target type, so the operand lowers under an
/// `i64` target whatever the caller's (`v : f32 = s[0];` indexes with the
/// integer `0`). An unsigned index narrower than a pointer widens to `i64`,
/// since LLVM sign-extends a GEP index to the pointer's width.
pub fn lowerIndexOperand(self: *Lowering, index_node: *const ast.Node) Ref {
    const saved_tt = self.target_type;
    self.target_type = .i64;
    defer self.target_type = saved_tt;
    const idx = self.lowerExpr(index_node);
    const ty = self.builder.getRefType(idx);
    const layout = self.module.types.integerLayout(ty) orelse return idx;
    if (layout.signed or layout.width >= self.module.types.pointer_size * 8) return idx;
    return self.coerceToType(idx, ty, .i64);
}

pub fn lowerIndexExpr(self: *Lowering, ie: *const ast.IndexExpr) Ref {
    // Pack-arg substitution: `args[<int_literal>]` inside a body
    // whose enclosing comptime call bound `args` as a pack name.
    // Lowering the i-th call-site arg directly gives the concrete
    // call-arg type — bypasses the `[]Any` slice boxing that would
    // otherwise lose the type. Non-literal indices fall through to
    // the standard slice indexing path.
    if (self.packArgNodeAt(ie)) |arg_node| {
        return self.lowerExpr(arg_node);
    }
    // Out-of-bounds pack indexing: object IS a pack name + index
    // IS a comptime int literal but exceeds the pack arity. Emit
    // a focused diagnostic so the user gets "pack index 2 out of
    // bounds" instead of the generic "unresolved 'args'" that the
    // fall-through scope-lookup would produce.
    if (self.diagPackIndexOOB(ie)) {
        return self.builder.constInt(0, .i64);
    }
    // Runtime index into a comptime-only pack: a pack has no
    // runtime representation, so the index must be a compile-time constant.
    // A runtime index is a hard error — clearer than the "unresolved
    // '<pack>'" the slice-index fall-through would otherwise produce.
    if (self.pack_param_count) |ppc| {
        if (ie.object.data == .identifier) {
            const pname = ie.object.data.identifier.name;
            if (ppc.contains(pname) and self.comptimeIndexOf(ie.index) == null) {
                if (self.diagnostics) |diags| {
                    diags.addFmt(.err, ie.index.span, "pack '{s}' must be indexed by a compile-time constant — a pack is comptime-only and has no runtime value", .{pname});
                }
                return self.builder.constInt(0, .i64);
            }
        }
    }
    // Infer element type from the object's slice/array type
    const obj_ty = self.inferExprType(ie.object);
    // A guard-narrowed container local indexes its PAYLOAD: the guard proved
    // presence, so `o[i]` is the element, not an optional chain.
    if (self.narrowedContainerChild(ie.object)) |child| {
        const payload = self.lowerNarrowedContainer(ie.object, child);
        const idx = self.lowerIndexOperand(ie.index);
        return self.indexLoweredValue(payload, child, idx, ie.object.span);
    }
    // Optional-chain index: `opt?.xs[i]`. The `?.` makes the object an
    // optional whose child is the (array/slice/many-ptr) field — so the index
    // applies inside the chain's some-branch and the whole expression is
    // `?ElemType` (null if the receiver was null). Without this the element
    // type resolved through `getElementType(?[N]T)` was `.unresolved` and an
    // `index_get` on the optional value reached LLVM emission.
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .optional) {
        const child = self.module.types.get(obj_ty).optional.child;
        // A pointer-to-array child (`?*[N]T`) is indexable too: its element is
        // the pointee array's element. `getElementType` has no pointer arm, so
        // ask `ptrToArrayElem` first (mirrors the non-optional `*[N]T` path
        // below) — otherwise the `?*[N]T` case fell through to a plain
        // `index_get` with an `.unresolved` element type.
        const elem_ty = self.ptrToArrayElem(child) orelse self.ptrToSliceElem(child) orelse self.getElementType(child);
        if (elem_ty != .unresolved) {
            return self.lowerOptionalChainIndex(ie, child, elem_ty);
        }
    }
    // Array with addressable storage: GEP the element in place + load,
    // never `index_get` on the loaded array VALUE — that realizes as
    // copy-whole-array-to-temp per read (the general-expression sibling
    // of the `lowerFor` rule), and on a 64K+ array the whole-aggregate
    // load/store ops segfault LLVM's SelectionDAG. The
    // object must not be lowered as a value on this path or the dead
    // whole-array load still reaches the DAG.
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array) {
        // A simple local (`arr[i]`) uses its alloca directly; any other
        // addressable chain (`table.fast[i]`, `g.grid[i][j]`, `(*p).buf[i]`)
        // recovers its storage through the lvalue machinery (a value fallback
        // would copy the whole field array per read). Each path evaluates the
        // object and the index exactly once.
        const storage: ?Ref = self.getExprAlloca(ie.object) orelse
            if (self.exprHasAddressableStorage(ie.object)) self.lowerExprAsPtr(ie.object) else null;
        if (storage) |base| {
            const idx = self.lowerIndexOperand(ie.index);
            const elem_ty = self.getElementType(obj_ty);
            const gep = self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = idx } }, self.module.types.ptrTo(elem_ty));
            return self.builder.load(gep, elem_ty);
        }
    }
    const obj = self.lowerExpr(ie.object);
    const idx = self.lowerIndexOperand(ie.index);
    return self.indexLoweredValue(obj, obj_ty, idx, ie.object.span);
}

/// Read the element of an already-lowered container VALUE. Every indexable
/// shape a value can carry lands here: `*[N]T` and `*[]T` auto-deref, the
/// remaining containers `index_get` directly.
pub fn indexLoweredValue(self: *Lowering, obj: Ref, obj_ty: TypeId, idx: Ref, obj_span: ast.Span) Ref {
    // `*[N]T` receiver auto-derefs: `obj` IS the pointer
    // value — GEP the pointee array and load the element.
    if (self.ptrToArrayElem(obj_ty)) |elem| {
        const gep = self.builder.emit(.{ .index_gep = .{ .lhs = obj, .rhs = idx } }, self.module.types.ptrTo(elem));
        return self.builder.load(gep, elem);
    }
    if (self.ptrToSliceElem(obj_ty)) |elem| {
        const slice = self.derefPtrToSliceIndexBase(obj, obj_ty);
        return self.builder.emit(.{ .index_get = .{ .lhs = slice, .rhs = idx } }, elem);
    }
    const elem_ty = self.getElementType(obj_ty);
    // Final guard: the object is not an indexable shape here. `getElementType`
    // recognizes `[N]T` array, `[]T` slice, `[*]T` many-pointer, `@Vector` and
    // `string`; `ptrToArrayElem`/`ptrToSliceElem` handled `*[N]T` and `*[]T`
    // above. An `.unresolved` element means the base is a single pointer `*T`
    // or a struct — non-indexable by design. Emitting an `index_get` with
    // `.unresolved` would slip past lowering and panic in emit_llvm
    // ("unresolved type reached LLVM emission"). Diagnose (see
    // diagNonIndexable) and return a placeholder so hasErrors() aborts before
    // codegen.
    if (elem_ty == .unresolved) {
        self.diagNonIndexable(obj_ty, obj_span);
        return self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts before codegen
    }
    return self.builder.emit(.{ .index_get = .{ .lhs = obj, .rhs = idx } }, elem_ty);
}

/// Shared "cannot index this type" diagnostic for every index-lowering path —
/// read (`p[i]`), write (`p[i] = v`), address-of (`@p[i]`), and the L-value
/// pointer path (`p[i].field` as an assignment/GEP base). Each of those paths
/// computes the element type via `ptrToArrayElem(..) orelse
/// ptrToSliceElem(..) orelse getElementType(..)`; an `.unresolved` result
/// means the base is a shape those resolvers don't index — a single pointer
/// `*T` or a struct, non-indexable by design (specs.md Pointer Types).
/// Emitting an `index_get`/`index_gep` whose element type is `.unresolved`
/// would slip past lowering and panic at LLVM emission ("unresolved type
/// reached LLVM emission") on the read, write, address-of and lvalue paths
/// alike. The caller must bail with a placeholder after calling this;
/// hasErrors() aborts before codegen.
///
/// An already-`.unresolved` object type is skipped: it comes from a PRIOR
/// error (e.g. an undefined name) already diagnosed — re-reporting would
/// duplicate the message (mirrors the `??` guard).
pub fn diagNonIndexable(self: *Lowering, obj_ty: TypeId, span: ast.Span) void {
    if (obj_ty == .unresolved) return;
    if (self.diagnostics) |d| {
        const is_single_ptr = !obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .pointer;
        if (is_single_ptr) {
            // If the pointee is itself indexable (slice/array), the right
            // advice is to dereference (`(*p)[i]`); the many-pointer hint
            // only applies to a pointer-to-scalar.
            const pointee = self.module.types.get(obj_ty).pointer.pointee;
            const pointee_indexable = (self.ptrToArrayElem(obj_ty) orelse self.getElementType(pointee)) != .unresolved;
            if (pointee_indexable) {
                d.addFmt(.err, span, "cannot index a value of type '{s}' — dereference first (e.g. `(*p)[i]`)", .{self.formatTypeName(obj_ty)});
            } else {
                d.addFmt(.err, span, "cannot index a value of type '{s}' — use a many-pointer '[*]T', or dereference first", .{self.formatTypeName(obj_ty)});
            }
        } else {
            d.addFmt(.err, span, "cannot index a value of type '{s}'", .{self.formatTypeName(obj_ty)});
        }
    }
}

pub fn lowerSliceExpr(self: *Lowering, se: *const ast.SliceExpr) Ref {
    // A guard-narrowed container local slices its PAYLOAD; the view is over
    // the payload's storage.
    const narrowed_child = self.narrowedContainerChild(se.object);
    const obj = if (narrowed_child) |child|
        self.lowerNarrowedContainer(se.object, child)
    else
        self.lowerExpr(se.object);
    const obj_ty = narrowed_child orelse self.inferExprType(se.object);
    // A slice base whose type never resolved to a concrete array — an inline
    // array literal (`i64.[1,2,3][0..2]`), a struct-literal array, or an
    // already-poisoned base — must not reach codegen: `emitSubslice` would
    // call `toLLVMType` on the `.unresolved` element and panic.
    // It is also a temporary with no backing storage, which
    // specs.md §Subslicing names a compile error. Emit the temporary-array
    // diagnostic (unless an upstream error already fired — avoids a
    // misleading cascade) and return a poison slice; the diagnostic aborts
    // the build before codegen.
    if (obj_ty == .unresolved) {
        if (self.diagnostics) |d| {
            if (!d.hasErrors())
                d.addFmt(.err, se.object.span, "cannot slice a temporary array — a slice is a view into the array's storage, and a temporary (an array literal, a call result) has none; bind it to a local first (`a := <expr>; a[..]`)", .{});
        }
        return self.builder.constUndef(self.module.types.sliceOf(.u8));
    }
    // A base with no element type is a view over nothing: the `sliceOf` that
    // would form carries an `.unresolved` element and panics at LLVM emission.
    // An optional is the shape that HAS an element but hasn't proven it present.
    if (self.getElementType(obj_ty) == .unresolved) {
        if (self.diagnostics) |d| {
            const name = self.formatTypeName(obj_ty);
            if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .optional) {
                d.addFmt(.err, se.object.span, "cannot slice a value of type '{s}' — an optional does not implicitly unwrap; force-unwrap with '?!', bind it (`if v := ...`), or guard with '!= null'", .{name});
            } else {
                d.addFmt(.err, se.object.span, "cannot slice a value of type '{s}' — a slice views an array, a slice, a many-pointer or a string", .{name});
            }
        }
        return self.builder.constUndef(self.module.types.sliceOf(.u8));
    }
    const elem_ty = self.getElementType(obj_ty);
    const sentinel = if (se.end == null) self.module.types.sentinelOf(obj_ty) else null;
    var lo = if (se.start) |s| self.lowerExpr(s) else self.builder.constInt(0, .i64);
    if (se.start_exclusive) lo = self.builder.add(lo, self.builder.constInt(1, .i64), .i64);
    var hi = if (se.end) |e|
        self.lowerExpr(e)
    else if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .many_pointer) blk: {
        if (sentinel) |x| break :blk emitTerminatorScan(self, obj, lo, elem_ty, x);
        if (self.diagnostics) |d|
            d.addFmt(.err, se.object.span, "slicing a many-pointer '{s}' requires an explicit upper bound (`mp[lo..hi]`) — it has no length", .{self.formatTypeName(obj_ty)});
        break :blk self.builder.constInt(0, .i64);
    } else self.emitLengthI64(obj, obj_ty);
    if (se.end_inclusive) hi = self.builder.add(hi, self.builder.constInt(1, .i64), .i64);
    // A subslice keeps its base's length word: `@Slice(T, Len)[a..b]` is again
    // `@Slice(T, Len)`, as `string[a..b]` stays `string`. A typed destination
    // that is a slice of the same element (`b : @Slice(u8, u32) = a[0..]`)
    // forms that `Len` directly.
    const base_len_ty = self.module.types.lenTypeOf(obj_ty);
    const len_ty = blk: {
        if (self.target_type) |tgt| {
            if (self.module.types.sliceInfoOf(tgt)) |ts| {
                if (self.module.types.sameType(ts.element, elem_ty)) break :blk ts.len_type;
            }
        }
        break :blk base_len_ty;
    };
    const slice_ty = if (sentinel != null and len_ty == base_len_ty)
        self.module.types.sliceOfSentinel(elem_ty, sentinel)
    else
        self.module.types.sliceOfLen(elem_ty, len_ty);
    if (self.foldedInt(lo)) |lo_v| {
        if (self.foldedInt(hi)) |hi_v| {
            const n: u64 = if (hi_v >= lo_v) @intCast(hi_v - lo_v) else 0;
            if (self.refuseLenWord(n, slice_ty)) return self.builder.constUndef(slice_ty);
        } else if (self.refuseImplicitLenNarrow(obj_ty, slice_ty)) {
            return self.builder.constUndef(slice_ty);
        }
    } else if (self.refuseImplicitLenNarrow(obj_ty, slice_ty)) {
        return self.builder.constUndef(slice_ty);
    }
    // Slicing an ARRAY must produce a zero-copy VIEW into the array's backing
    // storage (specs.md §Subslicing: "the result points into the original
    // backing storage — no memory allocation"). Lowering the array as a VALUE
    // materializes a fresh temp (emitSubslice's array-value arm does an
    // alloca+store), so the slice would view a COPY and mutations through it
    // would never reach the array. For an ADDRESSABLE array
    // (local, global, struct field, `*[N]T` deref) recover the storage
    // ADDRESS from the already-lowered value — via the `refStorageAddress`
    // walk, which re-emits only address arithmetic, never
    // re-runs a side-effecting index — and subslice over THAT pointer (the
    // many-pointer arm of emitSubslice / the comptime VM GEPs by `lo` in
    // place). `base_ty` becomes `[*]elem` so the comptime VM strides by the
    // element size, not the whole-array size.
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array) {
        // A narrowed payload's storage is the optional's own slot; the
        // unwrapped VALUE has no address to walk back to.
        const storage: ?Ref = if (narrowed_child) |child|
            self.narrowedContainerPtr(se.object, child)
        else
            self.refStorageAddress(obj);
        if (storage) |addr| {
            return self.builder.emit(.{ .subslice = .{
                .base = addr,
                .lo = lo,
                .hi = hi,
                .base_ty = self.module.types.manyPtrTo(elem_ty),
            } }, slice_ty);
        }
        // Non-addressable array rvalue (a call result, a struct/array literal,
        // a by-value binding …): there is no persistent backing to view, so a
        // slice would alias a temporary that dies at the end of this statement
        // — a dangling view. Reject it (Zig rejects slicing an rvalue array
        // for the same reason); the user must bind it to a local first.
        if (self.diagnostics) |d| {
            d.addFmt(.err, se.object.span, "cannot slice a temporary array of type '{s}' — a slice is a view into the array's storage, and a temporary has none; bind it to a local first (`a := <expr>; a[..]`)", .{self.formatTypeName(obj_ty)});
        }
        return self.builder.emit(.{ .subslice = .{ .base = obj, .lo = lo, .hi = hi, .base_ty = obj_ty } }, slice_ty);
    }
    return self.builder.emit(.{ .subslice = .{ .base = obj, .lo = lo, .hi = hi, .base_ty = obj_ty } }, slice_ty);
}

/// The index of the first `sentinel` at or after `lo` in the many-pointer `base`.
fn emitTerminatorScan(self: *Lowering, base: Ref, lo: Ref, elem_ty: TypeId, sentinel: i64) Ref {
    const lo_ty = self.builder.getRefType(lo);
    const start = if (lo_ty == .i64) lo else self.builder.widen(lo, lo_ty, .i64);
    const head = self.freshBlockWithParams("scan.head", &.{.i64});
    const done = self.freshBlockWithParams("scan.done", &.{.i64});
    self.builder.br(head, &.{start});
    self.builder.switchToBlock(head);
    const at = self.builder.blockParam(head, 0, .i64);
    const elem = self.builder.emit(.{ .index_get = .{ .lhs = base, .rhs = at } }, elem_ty);
    const next = self.builder.add(at, self.builder.constInt(1, .i64), .i64);
    self.builder.condBr(self.builder.cmpEq(elem, self.sentinelValue(sentinel, elem_ty)), done, &.{at}, head, &.{next});
    self.builder.switchToBlock(done);
    return self.builder.blockParam(done, 0, .i64);
}

const AnonLiteralValue = struct { ty: TypeId, value: ?Ref = null };
const AnonLiteralShape = literal_fields.Anonymous(AnonLiteralValue);

fn internAnonLiteral(self: *Lowering, shape: *const AnonLiteralShape) TypeId {
    const fields = self.module.types.slice_arena.allocator().alloc(types.TypeInfo.StructInfo.Field, shape.named.items.len + shape.unnamed.items.len) catch unreachable;
    for (shape.named.items, fields[0..shape.named.items.len]) |field, *dest| {
        dest.* = .{ .name = self.module.types.internString(field.name), .ty = field.value.ty };
    }
    for (shape.unnamed.items, fields[shape.named.items.len..], shape.named.items.len..) |value, *dest, i| {
        var buf: [24]u8 = undefined;
        dest.* = .{ .name = self.module.types.internString(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable), .ty = value.ty };
    }
    return self.module.types.internAnonStruct(fields);
}

pub fn inferAnonStructType(self: *Lowering, sl: *const ast.StructLiteral) TypeId {
    var shape = AnonLiteralShape{};
    defer shape.deinit(self.alloc);
    const saved_target = self.target_type;
    self.target_type = null;
    defer self.target_type = saved_target;
    const saved_diag = self.diagnostics;
    self.diagnostics = null;
    defer self.diagnostics = saved_diag;
    for (sl.field_inits) |fi| {
        if (fi.value.data == .spread_expr) {
            const contributions = literalSpreadTypes(self, fi.value.data.spread_expr.operand) orelse return .unresolved;
            defer self.alloc.free(contributions);
            for (contributions) |contribution| {
                if (contribution.ty == .unresolved or contribution.ty == .void) return .unresolved;
                shape.contribute(self.alloc, contribution.name, .spread, .{ .ty = contribution.ty }) catch return .unresolved;
            }
        } else {
            const ty = self.inferExprType(fi.value);
            if (ty == .unresolved or ty == .void) return .unresolved;
            shape.contribute(self.alloc, fi.name, .direct, .{ .ty = ty }) catch return .unresolved;
        }
    }
    return internAnonLiteral(self, &shape);
}

pub fn synthesizeAnonStruct(self: *Lowering, sl: *const ast.StructLiteral) Ref {
    var shape = AnonLiteralShape{};
    defer shape.deinit(self.alloc);
    const saved_target = self.target_type;
    self.target_type = null;
    defer self.target_type = saved_target;
    for (sl.field_inits) |fi| {
        if (fi.value.data == .spread_expr) {
            const contributions = lowerLiteralSpread(self, fi.value) orelse return self.builder.constUndef(.unresolved);
            defer self.alloc.free(contributions);
            for (contributions) |contribution| {
                shape.contribute(self.alloc, contribution.name, .spread, .{
                    .ty = self.builder.getRefType(contribution.value),
                    .value = contribution.value,
                }) catch unreachable;
            }
        } else {
            const value = self.lowerExpr(fi.value);
            shape.contribute(self.alloc, fi.name, .direct, .{ .ty = self.builder.getRefType(value), .value = value }) catch {
                if (self.diagnostics) |d| d.addFmt(.err, fi.name_span orelse fi.value.span, "field '{s}' initialized twice", .{fi.name.?});
                return self.builder.constUndef(.unresolved);
            };
        }
    }
    var values = std.ArrayList(Ref).empty;
    defer values.deinit(self.alloc);
    for (shape.named.items) |field| values.append(self.alloc, field.value.value.?) catch unreachable;
    for (shape.unnamed.items) |value| values.append(self.alloc, value.value.?) catch unreachable;
    const ty = internAnonLiteral(self, &shape);
    const result = self.builder.structInit(values.items, ty);
    if (sl.init_block) |ib| return self.lowerInitBlock(result, ty, ib, sl.init_block_self.?);
    return result;
}

pub fn lowerTupleLiteral(self: *Lowering, tl: *const ast.TupleLiteral) Ref {
    var elems = std.ArrayList(Ref).empty;
    defer elems.deinit(self.alloc);
    var field_type_ids = std.ArrayList(TypeId).empty;
    defer field_type_ids.deinit(self.alloc);
    var name_ids = std.ArrayList(types.StringId).empty;
    defer name_ids.deinit(self.alloc);
    var has_names = false;

    // A tuple_init's element values must match its field types exactly
    // (LLVM `insertvalue` does no implicit conversion). When a contextual
    // target tuple of matching arity is in scope (annotation, assignment
    // LHS, call/return slot), its field types drive element lowering so an
    // ambient scalar `target_type` (e.g. the enclosing fn's int return
    // type) can't narrow an element below its field width. Otherwise each
    // element's type is inferred independently.
    // A pack-spread element `(..xs)` / `(..xs.method)` expands to N fields,
    // so element-count ≠ field-count and a contextual target tuple can't be
    // aligned by index — infer field types from the expanded refs instead.
    var has_spread = false;
    for (tl.elements) |elem| {
        if (elem.value.data == .spread_expr) has_spread = true;
    }

    // Explicitly-typed construction with a type prefix: the literal carries
    // its tuple type, exactly like `Name{ ... }` for structs. Resolve it and
    // drive element lowering through it as the target tuple — the produced
    // value equals what the anonymous `.( ... )` form yields against that type.
    // An ambient contextual `target_type` (annotation / call slot), if present
    // and a tuple, is honored over the explicit one only when the explicit type
    // fails to resolve; otherwise the explicit type wins.
    const saved_explicit_target = self.target_type;
    var restore_explicit_target = false;
    if (tl.type_expr) |te| {
        const tuple_ty = self.resolveTypeWithBindings(te);
        if (tuple_ty != .unresolved) {
            self.target_type = tuple_ty;
            restore_explicit_target = true;
        }
    }
    defer if (restore_explicit_target) {
        self.target_type = saved_explicit_target;
    };

    // Contextual target tuple field types. Without a spread we require
    // exact arity (existing behavior); with a spread we index positionally
    // by output position (so `(..sources)` into a `(VL(T0), …)` field coerces
    // / erases each spliced element to its slot's type).
    var target_fields: ?[]const TypeId = null;
    if (self.target_type) |tt| {
        if (!tt.isBuiltin()) {
            const tinfo = self.module.types.get(tt);
            if (tinfo == .@"struct" and (has_spread or tinfo.@"struct".fields.len == tl.elements.len)) {
                const tmp = self.alloc.alloc(TypeId, tinfo.@"struct".fields.len) catch unreachable;
                for (tinfo.@"struct".fields, 0..) |f, i| tmp[i] = f.ty;
                target_fields = tmp;
            } else if (tinfo == .failable) {
                const n = self.module.types.failableValueSlotCount(tinfo.failable);
                if (has_spread or n == tl.elements.len or n + 1 == tl.elements.len) {
                    const tmp = self.alloc.alloc(TypeId, n + 1) catch unreachable;
                    for (0..n) |i| tmp[i] = self.module.types.failableValueSlotType(tinfo.failable, i);
                    tmp[n] = tinfo.failable.err;
                    target_fields = tmp;
                }
            }
        }
    }

    const saved_target = self.target_type;
    var out_idx: usize = 0;
    for (tl.elements) |elem| {
        // Pack-spread element → splice its per-element values as fields.
        if (elem.value.data == .spread_expr) {
            const sp_operand = elem.value.data.spread_expr.operand;
            if (self.packSpreadRefs(sp_operand, elem.value.span)) |refs| {
                defer self.alloc.free(refs);
                // Element AST nodes (for protocol-erasure lvalue/name fallback)
                // when the spread is a bare pack name.
                const elem_nodes: ?[]const *const Node = if (sp_operand.data == .identifier and self.pack_arg_nodes != null)
                    self.pack_arg_nodes.?.get(sp_operand.data.identifier.name)
                else
                    null;
                for (refs, 0..) |r, ri| {
                    var val = r;
                    var vty = self.builder.getRefType(r);
                    if (target_fields) |tf| {
                        if (out_idx < tf.len and tf[out_idx] != vty and tf[out_idx] != .void) {
                            const want = tf[out_idx];
                            const node = if (elem_nodes) |ens| (if (ri < ens.len) ens[ri] else elem.value) else elem.value;
                            val = self.coerceOrErase(r, vty, want, node);
                            vty = want;
                        }
                    }
                    elems.append(self.alloc, val) catch unreachable;
                    field_type_ids.append(self.alloc, vty) catch unreachable;
                    name_ids.append(self.alloc, self.module.types.internString("")) catch unreachable;
                    out_idx += 1;
                }
                continue;
            }
            // Value spread (specs.md §"Tuple parallels"): `.(..t)` where `t`
            // is a concrete tuple/array — splice its elements as fields.
            if (self.valueSpreadRefs(sp_operand, elem.value.span)) |refs| {
                defer self.alloc.free(refs);
                for (refs) |r| {
                    var val = r;
                    var vty = self.builder.getRefType(r);
                    if (target_fields) |tf| {
                        if (out_idx < tf.len and tf[out_idx] != vty and tf[out_idx] != .void) {
                            val = self.coerceOrErase(r, vty, tf[out_idx], elem.value);
                            vty = tf[out_idx];
                        }
                    }
                    elems.append(self.alloc, val) catch unreachable;
                    field_type_ids.append(self.alloc, vty) catch unreachable;
                    name_ids.append(self.alloc, self.module.types.internString("")) catch unreachable;
                    out_idx += 1;
                }
                continue;
            }
            // Neither a pack nor a tuple/array value spread.
            _ = self.lowerExpr(elem.value); // surfaces the spread_expr diagnostic
            continue;
        }
        const field_ty = if (target_fields) |tf| (if (out_idx < tf.len) tf[out_idx] else self.inferExprType(elem.value)) else self.inferExprType(elem.value);
        self.target_type = field_ty;
        var val = self.lowerExpr(elem.value);
        self.target_type = saved_target;
        const val_ty = self.builder.getRefType(val);
        const name_id: ?StringId = if (elem.name) |name| self.module.types.internString(name) else null;
        if (refuseVoidElement(self, val_ty, field_ty, name_id, out_idx, elem.value.span)) {
            val = self.zeroValue(field_ty);
        } else if (val_ty != field_ty) {
            val = self.coerceToType(val, val_ty, field_ty);
        }
        elems.append(self.alloc, val) catch unreachable;
        field_type_ids.append(self.alloc, field_ty) catch unreachable;
        if (name_id) |nid| {
            name_ids.append(self.alloc, nid) catch unreachable;
            has_names = true;
        } else {
            name_ids.append(self.alloc, self.module.types.internString("")) catch unreachable;
        }
        out_idx += 1;
    }

    // Reuse the contextual target tuple type when it drove lowering so the
    // value's type identity (incl. field names) matches the destination
    // slot; otherwise build the tuple type from the inferred fields.
    const tuple_ty = if (target_fields != null and self.target_type != null)
        self.target_type.?
    else
        self.module.types.internFieldsAsProductOrFailable(
            self.alloc.dupe(TypeId, field_type_ids.items) catch unreachable,
            if (has_names) self.alloc.dupe(types.StringId, name_ids.items) catch unreachable else null,
        );

    const owned = self.alloc.dupe(Ref, elems.items) catch unreachable;
    return self.builder.structInit(owned, tuple_ty);
}

pub fn lowerDerefExpr(self: *Lowering, de: *const ast.DerefExpr) Ref {
    const ptr = self.lowerExpr(de.operand);
    // Resolve pointee type from the pointer type.
    const ptr_ty = self.inferExprType(de.operand);
    if (!ptr_ty.isBuiltin()) {
        const info = self.module.types.get(ptr_ty);
        if (info == .pointer) {
            return self.builder.emit(.{ .deref = .{ .operand = ptr } }, info.pointer.pointee);
        }
    }
    // Operand isn't a pointer — `.*` is invalid. Diagnose here instead of
    // emitting a `.deref` with an `.unresolved` result type, which would
    // otherwise slip through to emit_llvm's "unresolved type reached LLVM
    // emission" panic with no source location.
    if (self.diagnostics) |d| {
        d.addFmt(.err, de.operand.span, "cannot dereference with `.*`: '{s}' is not a pointer", .{self.formatTypeName(ptr_ty)});
    }
    return ptr;
}

/// Reject using an un-narrowed optional directly as a binary-op operand.
/// Mirrors the `coerceMode` `?T → concrete` rejection:
/// the optional does not implicitly unwrap; steer the user to an explicit form.
pub fn diagOptionalOperand(self: *Lowering, opt_ty: TypeId, span: ast.Span) void {
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "cannot use a value of type '{s}' as an operand: an optional does not implicitly unwrap; force-unwrap with '?!', supply a fallback with '?? <default>', or guard with '!= null'", .{self.formatTypeName(opt_ty)});
    }
}

/// The payload of an optional arithmetic operand; null when `ty` is not
/// optional. An operand not guard-narrowed is diagnosed and still unwrapped.
pub fn unwrapOptionalOperand(self: *Lowering, operand: Ref, ty: TypeId, span: ast.Span) ?Ref {
    if (ty.isBuiltin()) return null;
    const info = self.module.types.get(ty);
    if (info != .optional) return null;
    if (!self.narrowed_refs.contains(operand)) self.diagOptionalOperand(ty, span);
    return self.builder.emit(.{ .optional_unwrap = .{ .operand = operand } }, info.optional.child);
}

pub fn lowerForceUnwrap(self: *Lowering, fu: *const ast.ForceUnwrap) Ref {
    const val = self.lowerExpr(fu.operand);
    const inner_ty = self.resolveOptionalInner(self.inferExprType(fu.operand));
    return self.builder.optionalUnwrap(val, inner_ty);
}

pub fn lowerNullCoalesce(self: *Lowering, nc: *const ast.NullCoalesce) Ref {
    // A failable left operand (value-terminator or chain) routes to the
    // error-handling lowering, not the optional unwrap below. Detected
    // structurally (a `try`-chain's value type is non-failable `T`, so a
    // type-only `exprIsFailable` would miss nested chains).
    if (self.coalesceIsFailable(nc)) return self.lowerFailableCoalesce(nc);

    const lhs = self.lowerExpr(nc.lhs);
    const lhs_ty = self.inferExprType(nc.lhs);

    // `??` requires an optional left operand. A resolved non-optional lhs is
    // malformed user input: diagnose it here instead of letting the
    // `.unresolved` inner type (from `resolveOptionalInner`) flow into the
    // merge-block params / `optionalUnwrap` / the RHS target type and reach
    // emit_llvm's "unresolved type reached LLVM emission" panic with no source
    // location. Skip an already-`.unresolved` lhs: that comes
    // from a PRIOR error (e.g. an undefined name) which has already been
    // diagnosed — re-reporting would be a confusing second message.
    const lhs_is_optional = !lhs_ty.isBuiltin() and self.module.types.get(lhs_ty) == .optional;
    if (lhs_ty != .unresolved and !lhs_is_optional) {
        if (self.diagnostics) |d|
            d.addFmt(.err, nc.lhs.span, "left operand of '??' must be an optional, but has type '{s}'", .{self.formatTypeName(lhs_ty)});
        return lhs; // placeholder — hasErrors() aborts before codegen
    }

    const inner_ty = self.resolveOptionalInner(lhs_ty);

    // Short-circuit: only evaluate RHS if LHS is null.
    // IMPORTANT: optional_unwrap must be in the "has value" branch,
    // not before the condBr — the interpreter errors on unwrapping null.
    const has_val = self.builder.emit(.{ .optional_has_value = .{ .operand = lhs } }, .bool);

    const then_bb = self.freshBlock("nc.has");
    const rhs_bb = self.freshBlock("nc.rhs");
    const merge_bb = self.freshBlockWithParams("nc.merge", &.{inner_ty});

    // If has value, go to then_bb to unwrap; else go to rhs_bb
    self.builder.condBr(has_val, then_bb, &.{}, rhs_bb, &.{});

    // Then block: unwrap LHS and branch to merge
    self.builder.switchToBlock(then_bb);
    const unwrapped = self.builder.optionalUnwrap(lhs, inner_ty);
    self.builder.br(merge_bb, &.{unwrapped});

    // RHS block: evaluate fallback and branch to merge
    self.builder.switchToBlock(rhs_bb);
    // Thread the optional's child type as the expected/target type so an
    // untyped struct literal default (`?? .{ ... }`) resolves to `T` rather
    // than staying `.unresolved` and reaching codegen as a malformed
    // struct_init. Scalar/pointer/typed defaults are unaffected:
    // they ignore `target_type` or coerce identically. Restore afterwards so
    // a `??` nested inside a larger expression doesn't leak this target type.
    const saved_tt = self.target_type;
    self.target_type = inner_ty;
    var rhs = self.lowerExpr(nc.rhs);
    self.target_type = saved_tt;
    if (self.currentBlockHasTerminator()) {
        self.builder.switchToBlock(merge_bb);
        return self.builder.blockParam(merge_bb, 0, inner_ty);
    }
    const rhs_ty = self.builder.getRefType(rhs);
    if (rhs_ty != inner_ty and self.conversionAvailable(rhs_ty, inner_ty, .implicit)) {
        rhs = self.coerceToType(rhs, rhs_ty, inner_ty);
    }
    // The merge-block param, the unwrapped LHS, and the coerced RHS must all
    // share `inner_ty` — they feed the same PHI. If the RHS default still does
    // not match after coercion (e.g. a scalar `5` default against an optional
    // whose payload is a 1-tuple `(i32,)`: there is no implicit scalar→1-tuple
    // coercion — a 1-tuple value is written `(5,)`), branching with the
    // mismatched type emits a `phi {i32}` vs `i32` that aborts the LLVM
    // verifier. Diagnose loudly and br with a typed placeholder so
    // the PHI stays well-formed; `hasErrors()` aborts before codegen anyway.
    const coerced_ty = self.builder.getRefType(rhs);
    if (coerced_ty != inner_ty) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, nc.rhs.span, "'??' default has type '{s}', but the optional's payload is '{s}'", .{ self.formatTypeName(coerced_ty), self.formatTypeName(inner_ty) });
        }
        rhs = self.builder.constNull(inner_ty); // typed placeholder — keeps the PHI well-formed
    }
    self.builder.br(merge_bb, &.{rhs});

    // Continue at merge
    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, inner_ty);
}

pub fn resolveOptionalInner(self: *Lowering, ty: TypeId) TypeId {
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        if (info == .optional) return info.optional.child;
    }
    return .unresolved;
}

// ── Core expression dispatch ───────────────────────────────────

pub fn lowerMarkedExpr(self: *Lowering, node: *const Node, pure_only: bool) Ref {
    const saved = self.marked_error_expr;
    self.marked_error_expr = .{ .node = node, .pure_only = pure_only };
    defer self.marked_error_expr = saved;
    return self.lowerExpr(node);
}

/// Only result paths inherit a marker; arguments and prefix statements do not.
fn errorPathContains(root: *const Node, node: *const Node) bool {
    if (root == node) return true;
    return switch (root.data) {
        .block => |b| b.produces_value and b.stmts.len > 0 and errorPathContains(b.stmts[b.stmts.len - 1], node),
        .if_expr => |ie| errorPathContains(ie.then_branch, node) or
            (if (ie.else_branch) |eb| errorPathContains(eb, node) else false),
        .match_expr => |me| blk: {
            for (me.arms) |arm| if (errorPathContains(arm.body, node)) break :blk true;
            break :blk false;
        },
        .null_coalesce => |nc| errorPathContains(nc.lhs, node) or errorPathContains(nc.rhs, node),
        else => false,
    };
}

pub fn lowerExpr(self: *Lowering, node: *const Node) Ref {
    // A named-argument value pre-lowered in written order by `mapNamedArgs`
    // already produced its ref — return it; re-lowering would evaluate the
    // value's side effects a second time.
    if (self.precomputed_args.count() > 0) {
        if (self.precomputed_args.get(node)) |pre| return pre;
    }
    // A synthetic declared-default root evaluates with the callee declaration's
    // lexical authority and substitution, not the caller's local scope.
    // Keep this override for the entire recursive lowering of the default
    // expression. Caller-provided comptime substitutions also carry
    // `source_file` but are deliberately not in this identity map, so they
    // retain caller bindings.
    const authored_default = self.authored_call_defaults.get(node);
    const saved_scope_for_default = self.scope;
    const saved_default_call_site = self.active_default_call_site;
    const saved_default_context = self.lexicalContext();
    const default_substitution: ?Lowering.SubstitutionPin = if (authored_default) |dflt| .enter(self, dflt.substitution) else null;
    defer if (default_substitution) |pin| pin.restore();
    if (authored_default) |dflt| {
        self.scope = null;
        self.active_default_call_site = dflt.site;
        self.setCurrentEnvironment(dflt.environment);
    }
    defer if (authored_default != null) {
        self.scope = saved_scope_for_default;
        self.active_default_call_site = saved_default_call_site;
        self.restoreLexicalContext(saved_default_context);
    };

    // Stamp this node's source span onto the instructions it emits (it
    // feeds DWARF line-info + comptime frame resolution). Save/
    // restore so a parent's later emits keep the parent's span after a
    // child lowers. Skip the empty default so synthetic nodes don't reset
    // a meaningful enclosing span to offset 0.
    const saved_span = self.builder.current_span;
    defer self.builder.current_span = saved_span;
    if (node.span.start != 0 or node.span.end != 0) self.builder.current_span = .{ .start = node.span.start, .end = node.span.end };
    // Resolve this node's bare names in the module that wrote it, overriding
    // the body's defining-module pin for the whole recursive lowering.
    const author = Lowering.AuthorScope.enter(self, node);
    defer author.leave();
    if (self.isScopeDesignator(node)) {
        if (self.diagnostics) |d| d.add(.err, "a scope is not a value", node.span);
        const name = imports_mod.aliasPath(self.alloc, node).?;
        defer self.alloc.free(name);
        return self.emitPlaceholder(name);
    }
    const result = lowerExprInner(self, node);
    const ty = self.builder.getRefType(result);
    const produces_failable = blk: {
        if (self.errorChannelOf(ty) == null) break :blk false;
        if (node.data == .call) break :blk true;
        if (node.data == .null_coalesce) break :blk self.coalesceIsFailable(&node.data.null_coalesce);
        if (node.data != .field_access) break :blk false;
        const fa = node.data.field_access;
        var recv_ty = self.inferExprType(fa.object);
        if (self.module.types.get(recv_ty) == .pointer)
            recv_ty = self.module.types.get(recv_ty).pointer.pointee;
        break :blk self.getAccessorFor(recv_ty, fa.field) != null;
    };
    if (produces_failable and !(if (self.marked_error_expr) |marker|
        (!marker.pure_only or self.module.types.get(ty) == .@"error") and errorPathContains(marker.node, node)
    else
        false))
    {
        if (self.diagnostics) |d| d.add(.err, if (self.module.types.get(ty) == .@"error")
            "a pure failable expression needs an error-path marker; use `catch` to handle the error"
        else
            "a failable expression needs an error-path marker: `try`, `catch`, `??` with a value, a destructure binding, or a forwarded call", node.span);
    }
    return result;
}

fn lowerCastOperand(self: *Lowering, operand: *const Node) Ref {
    const saved = self.cast_operand;
    const saved_reached = self.cast_reached;
    defer {
        self.cast_operand = saved;
        self.cast_reached = saved_reached;
    }
    self.cast_operand = if (program_index_mod.untypedConst(operand, self) != null) .untyped else .typed;
    self.cast_reached = if (self.cast_operand == .typed) operand else null;
    return self.lowerExpr(operand);
}

fn lowerExprInner(self: *Lowering, node: *const Node) Ref {
    if (program_index_mod.untypedConst(node, self)) |untyped| switch (untyped) {
        .float => {
            const ty = self.floatContext(self.target_type) orelse .f64;
            if (program_index_mod.evalConstFloatInit(node, self, ty)) |value|
                return self.builder.constFloat(value, ty);
        },
        .string => |lit| return self.lowerStringLiteral(lit),
        // A char literal keeps its code-point diagnostic.
        .integer => if (node.data != .char_literal) {
            // A shift by a runtime or negative amount does not fold; lowering
            // computes or diagnoses it at its type.
            const folded = program_index_mod.foldConstInt(node, self) catch |fault| {
                if (self.diagnostics) |d| d.add(.err, switch (fault) {
                    error.Overflow => "integer constant overflows 128 bits",
                    error.DivisionByZero => "integer constant divides by zero",
                }, node.span);
                return self.emitPlaceholder("integer-constant-fault");
            };
            if (folded) |value| {
                const ty = integerLiteralType(self, self.target_type);
                if (Lowering.isFloat(ty)) return self.builder.constFloat(types.floatFromInt(value, ty), ty);
                self.checkIntLiteralFits(value, ty, node.span);
                return self.builder.constInt(@truncate(value), ty);
            }
        },
    };
    return switch (node.data) {
        // Bare `$<pack>` in expression position → an `[]Type` slice
        // value where each element is a `const_type(arg_types[i])`.
        // Per `Type → .any` mapping in type_bridge, the IR slice
        // type is `[]Any`; the interp stores raw `.type_tag` Values
        // (NOT Any-boxed) so `args[i]` reads back as a Type value
        // directly — this lets builder fns walk the whole pack at
        // interp time.
        .comptime_pack_ref => |cpr| blk: {
            // `$<name>` is overloaded in expression position:
            //   - Inside a pack-fn mono (or a `tryPackImplMatch`
            //     impl mono), `name` is a pack binding → slice of
            //     element types (`[]Type` lowered as `[]Any`).
            //   - Inside an impl mono whose impl pattern bound a
            //     single-type generic (`$R: Type` in
            //     `Closure(..$args) -> $R`), `name` is in
            //     `type_bindings` → single `const_type(R)` value.
            // Pack arg types are checked first (the slice form),
            // then pack_bindings (the impl-mono mirror), then
            // type_bindings (single-type binding); only if all
            // miss is it a real "outside an active binding" error.
            if (self.pack_arg_types) |pat| {
                if (pat.get(cpr.pack_name)) |arg_tys| {
                    break :blk self.buildPackSliceValue(arg_tys);
                }
            }
            if (self.pack_bindings) |pb| {
                if (pb.get(cpr.pack_name)) |arg_tys| {
                    break :blk self.buildPackSliceValue(arg_tys);
                }
            }
            if (self.type_bindings) |tb| {
                if (tb.get(cpr.pack_name)) |ty| {
                    break :blk self.builder.constType(ty);
                }
            }
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, node.span, "pack reference ${s} used outside an active pack binding", .{cpr.pack_name});
            }
            break :blk self.builder.constNull(self.module.types.sliceOf(.any));
        },
        // Pack-index in expression position: `$<pack>[<lit>]` →
        // `const_type(arg_types[index])`. Yields a comptime-only
        // Type value (`Value.type_tag(TypeId)` in the interp).
        // OOB / no-active-pack-binding → focused diagnostic; the
        // emitted Ref is a const_type(.void) placeholder so the
        // verifier downstream catches misuse rather than silently
        // succeeding with .void.
        .pack_index_type_expr => |pi| blk: {
            if (self.pack_arg_types) |pat| {
                if (pat.get(pi.pack_name)) |arg_tys| {
                    if (pi.index < arg_tys.len) {
                        break :blk self.builder.constType(arg_tys[pi.index]);
                    }
                    if (self.diagnostics) |diags| {
                        diags.addFmt(.err, node.span, "pack-index value ${s}[{}] out of bounds: '{s}' has {} element{s}", .{
                            pi.pack_name,                                                        pi.index, pi.pack_name, arg_tys.len,
                            if (arg_tys.len == 1) @as([]const u8, "") else @as([]const u8, "s"),
                        });
                    }
                    break :blk self.builder.constType(.void);
                }
            }
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, node.span, "pack-index value ${s}[{}] used outside an active pack binding", .{
                    pi.pack_name, pi.index,
                });
            }
            break :blk self.builder.constType(.void);
        },
        .int_literal => |lit| {
            const ty = self.literalNodeType(node, self.target_type).?;
            if (Lowering.isFloat(ty)) return self.builder.constFloat(types.floatFromInt(lit.value, ty), ty);
            self.checkIntLiteralMagnitudeFits(lit.value, ty, node.span);
            return self.builder.constInt(lit.value, ty);
        },
        .char_literal => |lit| {
            const ty = self.literalNodeType(node, self.target_type).?;
            if (Lowering.isFloat(ty)) return self.builder.constFloat(@floatFromInt(lit.value), ty);
            self.checkCharLiteralFits(lit, ty, node.span);
            return self.builder.constInt(lit.value, ty);
        },
        .float_literal => |lit| {
            const fty = self.literalNodeType(node, self.target_type).?;
            return self.builder.constFloat(self.adoptFloatValue(lit.value, fty, node.span), fty);
        },
        .bool_literal => |lit| self.builder.constBool(lit.value),
        .string_literal => |lit| self.lowerStringLiteral(lit),
        // A bare `null` / `---` with no surrounding type expectation is a
        // legitimate typeless literal, not a failed lookup: `.void` is its
        // intentional default (emitConstNull/emitConstUndef handle void as
        // null-ptr / undef-i64). Not a candidate for the `.unresolved` tripwire.
        .null_literal => blk: {
            const t = self.target_type orelse .void;
            if (self.refuseNullAtNonOptional(t, node.span)) break :blk self.builder.constUndef(t);
            break :blk self.builder.constNull(t);
        },
        .undef_literal => self.builder.constUndef(self.target_type orelse .void),

        .identifier => |id| blk: {
            // A bare pack name in value position has no runtime
            // representation. Projections (`xs.len`, `xs[i]`,
            // `xs.value`) are field/index nodes handled elsewhere, so a bare
            // `xs` reaching here is always a pack-as-value misuse.
            if (self.isPackName(id.name)) {
                break :blk self.diagPackAsValue(id.name, node.span, .generic);
            }
            if (self.scope) |scope| {
                const sb = scope.lookupBoundary(id.name);
                if (sb.crossed != .none) break :blk self.diagEnclosingLocalRef(id.name, node.span, sb.crossed);
                if (sb.binding) |binding| {
                    // `inline for x in xs` element capture — lower the
                    // synthesized `xs[<i>]` it aliases.
                    if (binding.alias_node) |elem| break :blk self.lowerExpr(elem);
                    // Flow narrowing: a name proven present by a
                    // `!= null` guard tags its loaded value so the implicit
                    // `?T → concrete` unwrap in `coerceMode` is permitted (an
                    // un-narrowed unwrap is rejected, not silently zeroed).
                    const is_narrowed = self.provenPresent(id.name);
                    // Reading a cursor's storage as a value would copy a
                    // position the ABI owns; `*name` is the only way to reach
                    // it, and it never lowers the name as a value.
                    if (self.refuseCursorValue(binding.ty, node.span, "read"))
                        break :blk self.builder.constUndef(binding.ty);
                    if (binding.is_alloca) {
                        const loaded = self.builder.load(binding.ref, binding.ty);
                        if (is_narrowed) self.narrowed_refs.put(loaded, {}) catch {};
                        if (binding.literal_init) |init| self.literal_local_refs.put(loaded, .{ .binding = binding.id.?, .name = id.name, .init = init }) catch {};
                        break :blk loaded;
                    }
                    if (is_narrowed) self.narrowed_refs.put(binding.ref, {}) catch {};
                    break :blk binding.ref;
                }
            }
            // A compile-time constant answers before globals.
            if (self.comptime_constants.get(id.name)) |cv| {
                if (comptimeConstRef(self, cv)) |ref| break :blk ref;
                if (cv == .struct_val) {
                    if (comptimeStructRef(self, id.name, cv.struct_val)) |ref| break :blk ref;
                }
            }
            // `context` resolves to a load through the lowering's
            // current `__sx_ctx` pointer. Every sx function (and
            // every `push .{...}` / `push Context{...}` body) sets `current_ctx_ref`
            // to a `*Context` it owns, so this is one indirection.
            if (std.mem.eql(u8, id.name, "context")) {
                if (!self.implicit_ctx_enabled or self.current_ctx_ref == Ref.none) {
                    break :blk self.diagnoseMissingContext("the `context` identifier");
                }
                const ctx_ty = self.module.types.findByName(self.module.types.internString("Context")) orelse {
                    break :blk self.diagnoseMissingContext("the `context` identifier");
                };
                break :blk self.builder.load(self.current_ctx_ref, ctx_ty);
            }
            // A generic body lowers in its caller's visibility, where a
            // same-named declaration may be in view, so a bound generic
            // parameter answers first.
            if (self.type_bindings) |tb| {
                if (tb.get(id.name)) |t| break :blk self.builder.constType(t);
            }
            // Check globals (@run constants) — source-aware:
            // the global registry is last-wins across modules, so select the
            // AUTHOR first and emit ITS global, never an unrelated module's
            // same-named one.
            if (self.program_index.lookup(.global, id.name)) |gi| {
                switch (self.selectGlobalAuthor(id.name)) {
                    .resolved => |g| break :blk self.builder.emit(.{ .global_get = g.id }, g.ty),
                    .not_a_global => {},
                    .ambiguous => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, node.span, "'{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{id.name});
                        break :blk self.emitPlaceholder(id.name);
                    },
                    .not_visible => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, node.span, "'{s}' is not visible; @import the module that declares it", .{id.name});
                        break :blk self.emitError(id.name, node.span);
                    },
                    .untracked => break :blk self.builder.emit(.{ .global_get = gi.id }, gi.ty),
                }
            }
            // Check module-level value constants (e.g. AF_INET :i32: 2)
            if (self.program_index.lookup(.module_const, id.name)) |ci_global| {
                if (!self.isNameVisible(id.name)) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "'{s}' is not visible; @import the module that declares it", .{id.name});
                    break :blk self.emitError(id.name, node.span);
                }
                // Emit the SOURCE-AWARE author's value (own-wins), not the
                // global last-wins `ci_global`. ≥2 flat-visible same-name const
                // authors → a loud ambiguity, never a silent
                // pick. `.none` after a visible name is the registration-only
                // author (no per-source partition) — emit its global value.
                switch (self.selectModuleConst(id.name)) {
                    .resolved => |sel| break :blk self.emitModuleConst(id.name, sel.info, sel.environment),
                    // Own const author with no materialized value (unsupported
                    // shape, e.g. an array const) — fall through; the tail of
                    // identifier lowering diagnoses it as unresolved.
                    .own_opaque => {},
                    .not_a_const => {},
                    .ambiguous => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, node.span, "'{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{id.name});
                        break :blk self.emitPlaceholder(id.name);
                    },
                    .none => break :blk self.emitModuleConst(id.name, ci_global, null),
                }
            }
            // Check if it's a function name — produce function pointer reference
            // Resolve mangled name for block-local functions
            const eff_fn_name = if (self.scope) |scope| scope.lookupFn(id.name) orelse id.name else id.name;
            // An own fn whose name a flat-merge collision dropped from the
            // global decl list (first-wins) has no `fn_ast_map` entry but IS
            // a raw-facts author — the author selection inside this arm
            // serves it, so admit it through the gate.
            const fn_author_only = !self.program_index.contains(.function, eff_fn_name) and
                std.mem.eql(u8, eff_fn_name, id.name) and
                (if (self.scope) |scope| scope.lookup(id.name) == null else true) and
                self.current_source_file != null and
                self.selectCallableAuthor(id.name, self.environmentForSource(self.current_source_file.?).?, .non_generic) == .func;
            if (self.program_index.contains(.function, eff_fn_name) or fn_author_only) {
                // Visibility check only for user-typed bare names (id.name
                // == eff_fn_name) without a UFCS alias. Mangled local-
                // scope names and UFCS rewrites are compiler indirections
                // and stay exempt.
                if (std.mem.eql(u8, eff_fn_name, id.name) and
                    self.ufcsAliasTarget(id.name) == null and
                    !self.isNameVisible(eff_fn_name))
                {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "'{s}' is not visible; @import the module that declares it", .{eff_fn_name});
                    break :blk self.emitError(eff_fn_name, node.span);
                }
                // Type-as-value: a bare function name in a `Type` (`.type_value`)
                // slot is its FUNCTION TYPE — `const_type(() -> R)` — so it prints
                // / reflects as the real function type, not a func-ref. A
                // genuine `Any` param takes a formatted type-name string boxed
                // as Any.
                if (self.target_type == .any or self.target_type == .type_value) {
                    const fd_any: ?*const ast.FnDecl = self.program_index.lookup(.function, eff_fn_name) orelse fd_blk: {
                        switch (self.selectCallableAuthor(id.name, self.environmentForSource(self.current_source_file.?).?, .non_generic)) {
                            .func => |sf| break :fd_blk sf.decl,
                            else => break :fd_blk null,
                        }
                    };
                    if (fd_any) |fd| {
                        // Both reflection shapes read the one declared
                        // signature, convention and tail included.
                        const fn_tid = self.declSignatureType(fd);
                        if (self.target_type == .type_value) {
                            break :blk self.builder.constType(fn_tid);
                        }
                        const sid = self.module.types.internString(self.module.types.formatTypeName(self.alloc, fn_tid, null));
                        const str = self.builder.constString(sid);
                        break :blk self.boxAnyOf(str, .string, null);
                    }
                }
                // taking a bare same-name fn as a VALUE
                // (func_ref, fn-ptr / closure coercion) must capture the
                // RESOLVED author's FuncId for a genuine flat collision, not
                // the first-wins winner's. Plain bare name only; `.ambiguous`
                // → loud diagnostic; `.none` → existing first-wins path. The
                // winner is lazily lowered ONLY on `.none` — a rerouted value
                // never uses the winner, so its body must not be lowered.
                const value_fid: ?FuncId = blk_fv: {
                    if (std.mem.eql(u8, eff_fn_name, id.name) and
                        self.ufcsAliasTarget(id.name) == null and
                        (if (self.scope) |scope| scope.lookup(id.name) == null else true))
                    {
                        if (self.current_source_file) |caller_file| {
                            switch (self.selectCallableAuthor(id.name, self.environmentForSource(caller_file).?, .non_generic)) {
                                .func => |sf| {
                                    var selected = sf;
                                    break :blk_fv self.selectedFuncId(&selected);
                                },
                                .ambiguous => {
                                    if (self.diagnostics) |d|
                                        d.addFmt(.err, node.span, "'{s}' is ambiguous; declared by multiple imported modules — qualify the call", .{id.name});
                                    break :blk self.emitError(id.name, node.span);
                                },
                                // The visible author is a value: the name-keyed
                                // winner is not what this spelling means here.
                                .not_callable => break :blk_fv null,
                                .none => {},
                            }
                        }
                    }
                    if (!self.lowered_functions.contains(eff_fn_name)) {
                        self.lazyLowerFunction(eff_fn_name);
                    }
                    break :blk_fv self.resolveFuncByName(eff_fn_name);
                };
                if (value_fid) |fid| {
                    // Auto-promote bare function → closure when target_type is closure
                    if (self.target_type) |tt| {
                        if (!tt.isBuiltin()) {
                            const tt_info = self.module.types.get(tt);
                            if (self.slotReturnType(tt)) |slot_ret| {
                                const declared_ret = self.module.functions.items[@intFromEnum(fid)].ret;
                                if (!self.checkSlotChannel(declared_ret, slot_ret, node.span))
                                    break :blk self.emitPlaceholder(eff_fn_name);
                            }
                            if (tt_info == .closure) {
                                const tramp_id = self.createBareFnTrampoline(fid, tt_info.closure);
                                break :blk self.builder.closureCreate(tramp_id, Ref.none, tt);
                            }
                            // fn → Closure promotion composes with T → ?T
                            // wrapping: a `?Closure(...)` target
                            // promotes to the CHILD closure type here, and the
                            // standard optional_wrap coercion wraps the value —
                            // call args, struct-literal fields, decl targets,
                            // and returns all thread target_type through.
                            if (tt_info == .optional and !tt_info.optional.child.isBuiltin()) {
                                const child = tt_info.optional.child;
                                const child_info = self.module.types.get(child);
                                if (child_info == .closure) {
                                    const tramp_id = self.createBareFnTrampoline(fid, child_info.closure);
                                    break :blk self.builder.closureCreate(tramp_id, Ref.none, child);
                                }
                            }
                            // Coercing a bare fn name to a fn-pointer
                            // type — the call_conv must match. A
                            // default-conv sx fn assigned to a
                            // abi(.c) slot (e.g. passed to
                            // pthread_create) would otherwise crash at
                            // runtime when the C caller doesn't supply
                            // the implicit __sx_ctx arg.
                            if (tt_info == .function) {
                                const target_fn = self.module.functions.items[@intFromEnum(fid)];
                                const func_cc = target_fn.call_conv;
                                if (func_cc != tt_info.function.call_conv) {
                                    if (self.diagnostics) |d| {
                                        const want_cc = if (tt_info.function.call_conv == .c) "abi(.c)" else "default sx convention";
                                        const have_cc = if (func_cc == .c) "abi(.c)" else "default sx convention";
                                        d.addFmt(.err, node.span, "call-convention mismatch: '{s}' is declared with {s} but the target type expects {s}", .{ eff_fn_name, have_cc, want_cc });
                                    }
                                    break :blk self.emitPlaceholder(eff_fn_name);
                                }
                                // A C-variadic tail is part of the ABI: the
                                // caller promotes tail arguments and the callee
                                // reads them through a cursor, so a fixed
                                // signature and a variadic one cannot stand in
                                // for each other.
                                if (target_fn.is_c_variadic != tt_info.function.is_c_variadic) {
                                    if (self.diagnostics) |d| {
                                        const want_tail = if (tt_info.function.is_c_variadic) "a C-variadic '..' tail" else "a fixed parameter list";
                                        const have_tail = if (target_fn.is_c_variadic) "a C-variadic '..' tail" else "a fixed parameter list";
                                        d.addFmt(.err, node.span, "variadic-tail mismatch: '{s}' is declared with {s} but the target type expects {s}", .{ eff_fn_name, have_tail, want_tail });
                                    }
                                    break :blk self.emitPlaceholder(eff_fn_name);
                                }
                            }
                        }
                    }
                    const sig_ty = self.functionSignatureType(fid) orelse return Ref.none;
                    break :blk self.builder.emit(.{ .func_ref = fid }, sig_ty);
                }
            }
            // Type-as-value: a name that resolves to a TypeId
            // (primitive, alias, registered struct/enum/union,
            // generic-struct instantiation) evaluates to a
            // `const_type` in expression position. Works for
            // direct assignment to a `Type`-typed slot
            // (`x: Type = Vec4`), comparison (`x == Vec4`), and
            // pack-arg / Any context (boxing happens at the
            // consumer).
            // Single-hop visibility + ambiguity gate: a bare type name used
            // as a VALUE (`x: Type = COnly`, `x == COnly`) reachable only over
            // 2+ flat hops is not bare-visible (consistent with annotations /
            // 0763); ≥2 direct flat same-name authors are ambiguous (loud
            // diagnostic, 0755/0767). A single source-keyed author — including
            // the querying source's OWN author over a same-name flat import
            // (own-wins, 0754) — resolves to ITS TypeId, NOT whichever same-name
            // author a global `findByName` would pick. An own non-type author
            // that hides a type authored elsewhere is refused as that
            // declaration; any other value name / undeclared name →
            // `.proceed`, falling through below.
            const ty = blk_ty: {
                switch (self.headTypeGate(id.name, node.span)) {
                    .ambiguous, .not_visible, .not_a_type => break :blk self.emitPlaceholder(id.name),
                    .resolved => |tid| break :blk_ty tid,
                    .proceed => {},
                }
                if (self.program_index.lookup(.type_alias, id.name)) |t| break :blk_ty t;
                if (type_bridge.resolveTypePrimitive(id.name)) |t| break :blk_ty t;
                const name_id = self.module.types.internString(id.name);
                if (self.module.types.findByName(name_id)) |t| break :blk_ty t;
                break :blk_ty TypeId.void;
            };
            if (ty != .void) {
                break :blk self.builder.constType(ty);
            }
            // Unknown identifier
            break :blk self.emitError(id.name, node.span);
        },

        .binary_op => self.lowerBinaryOp(node),

        .unary_op => |uop| blk: {
            // `xx <pack>` with a slice target materializes the comptime
            // pack into a runtime `[]elem`. Must run before the
            // operand is lowered (a bare pack name otherwise hits the
            // pack-as-value error).
            if (uop.op == .xx and uop.operand.data == .identifier and self.isPackName(uop.operand.data.identifier.name)) {
                const pname = uop.operand.data.identifier.name;
                if (self.target_type) |tt| {
                    if (self.module.types.sliceInfoOf(tt) != null) {
                        break :blk self.lowerPackToSlice(pname, tt);
                    }
                }
                break :blk self.diagPackAsValue(pname, node.span, .generic);
            }
            if (uop.op == .address_of) self.noteStorageWrite(uop.operand);
            // address_of(index_expr) → emit index_gep (pointer to element) instead of index_get + addr_of
            if (uop.op == .address_of and uop.operand.data == .index_expr) {
                const ie = &uop.operand.data.index_expr;
                const narrowed_child = self.narrowedContainerChild(ie.object);
                const obj_ty = narrowed_child orelse self.inferExprType(ie.object);
                const idx = self.lowerIndexOperand(ie.index);
                const elem_ty = self.ptrToArrayElem(obj_ty) orelse self.ptrToSliceElem(obj_ty) orelse self.getElementType(obj_ty);
                // Non-indexable base (`@pc[i]` on a `*T`, a struct, ...): an
                // `index_gep` typed `ptrTo(.unresolved)` panics at LLVM
                // emission — diagnose and bail instead.
                if (elem_ty == .unresolved) {
                    self.diagNonIndexable(obj_ty, ie.object.span);
                    break :blk self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts
                }
                const ptr_ty = self.module.types.manyPtrTo(elem_ty);
                const base = self.indexBase(ie.object, obj_ty, narrowed_child);
                break :blk self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = idx } }, ptr_ty);
            }
            // address_of(field_access) → use lowerExprAsPtr for GEP chain
            // Handles all cases: pointer-based, index-based, nested field access
            if (uop.op == .address_of and (uop.operand.data == .field_access or self.fieldCall(uop.operand) != null)) {
                const inner_ty = self.inferExprType(uop.operand);
                const ptr_ty = self.module.types.ptrTo(inner_ty);
                const ptr = self.lowerExprAsPtr(uop.operand);
                break :blk self.builder.emit(.{ .addr_of = .{ .operand = ptr } }, ptr_ty);
            }
            // address_of(identifier) → return alloca directly (pointer to variable)
            if (uop.op == .address_of and uop.operand.data == .identifier) {
                const id_name = uop.operand.data.identifier.name;
                if (self.scope) |scope| {
                    const sb = scope.lookupBoundary(id_name);
                    if (sb.crossed != .none) break :blk self.diagEnclosingLocalRef(id_name, node.span, sb.crossed);
                    if (sb.binding) |binding| {
                        if (binding.is_alloca) {
                            const ptr_ty = self.module.types.ptrTo(binding.ty);
                            break :blk self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, ptr_ty);
                        }
                        // A non-storage value binding — a scalar `::` constant
                        // folded to its value (`is_alloca == false`, not a
                        // ref-capture pointer or pack-element alias). It has NO
                        // address: array/struct consts get real storage (reached
                        // via `resolveGlobalRef` below), but a scalar const does
                        // not. Taking `@const` would otherwise fall through to the
                        // generic `addr_of` arm and reinterpret the folded value
                        // as a pointer — `inttoptr (i64 <value> to ptr)`, a wild
                        // pointer that segfaults on deref and emits invalid stores
                        // for asm `-> @const`. Diagnose loudly.
                        if (!binding.is_ref_capture and binding.alias_node == null) {
                            if (self.diagnostics) |d|
                                d.addFmt(.err, node.span, "cannot take the address of constant '{s}' — a scalar '::' constant has no storage (use a '=' variable or a local copy for mutable data)", .{id_name});
                            break :blk self.emitPlaceholder("addr_of_const");
                        }
                    }
                }
                // address_of(global) → emit global_addr (pointer to global, not load)
                if (self.resolveGlobalRef(id_name, node.span)) |gi| {
                    const ptr_ty = self.module.types.ptrTo(gi.ty);
                    break :blk self.builder.emit(.{ .global_addr = gi.id }, ptr_ty);
                }
                // A module-scope scalar `::` constant (not in lexical `scope`, and
                // not a storage-backed array/struct const — those resolve above).
                // Same defect as the local case: without storage, `@FORTY` would
                // become `inttoptr (i64 <value> to ptr)`. Diagnose.
                if (self.program_index.lookup(.module_const, id_name) != null) {
                    switch (self.selectModuleConst(id_name)) {
                        .resolved, .ambiguous, .none => {
                            if (self.diagnostics) |d|
                                d.addFmt(.err, node.span, "cannot take the address of constant '{s}' — a scalar '::' constant has no storage (use a '=' variable or a local copy for mutable data)", .{id_name});
                            break :blk self.emitPlaceholder("addr_of_const");
                        },
                        .own_opaque, .not_a_const => {},
                    }
                }
            }
            // A dest-typed float literal is that dest width; the negated form
            // is the same constant with the sign flipped.
            if (uop.op == .negate and uop.operand.data == .float_literal) {
                const lit = uop.operand.data.float_literal;
                const fty: TypeId = if (self.target_type) |tt| (if (tt == .f32 or tt == .f64) tt else .f64) else .f64;
                break :blk self.builder.constFloat(-self.adoptFloatValue(lit.value, fty, node.span), fty);
            }
            // Prefix `*` on a TYPE-valued operand is the pointer TYPE, not
            // address-of: `@sizeOf(*T)`, Type-arg positions, and nested
            // `**T` (address_of over address_of resolves inside-out). Must
            // run before the operand lowers as a value — a bare type name
            // has no value to take the address of. A local/global VALUE
            // shadowing a type name stays a value (address-of wins).
            if (uop.op == .address_of) {
                if (addrOfTypeOperand(self, uop.operand)) |ptid| {
                    break :blk self.builder.emit(.{ .const_type = ptid }, .type_value);
                }
            }
            // `--x` writes the place its operand names. Must run before the
            // operand is lowered: lowering it as a value would evaluate the
            // place's subexpressions a second time (`--xs[idx()]`).
            if (uop.op == .pre_decrement) {
                self.noteStorageWrite(uop.operand);
                if (self.diagConstRootWrite(uop.operand)) break :blk self.emitPlaceholder("pre-decrement");
                if (self.diagContextRootWrite(uop.operand)) break :blk self.emitPlaceholder("pre-decrement");
                if (self.diagEnclosingRootWrite(uop.operand)) break :blk self.emitPlaceholder("pre-decrement");
                if (self.diagNonstoreRootWrite(uop.operand)) break :blk self.emitPlaceholder("pre-decrement");
                const place = self.resolveMutablePlace(uop.operand) orelse
                    break :blk self.diagDecrementTarget(node.span);
                const ty = Lowering.placeType(place);
                if (!self.isIntEx(ty)) break :blk self.diagDecrementNonInteger(ty, node.span);
                break :blk self.lowerPlaceRmw(place, .sub_assign, self.builder.constInt(1, ty));
            }
            const operand = switch (uop.op) {
                .xx => lowerCastOperand(self, uop.operand),
                .negate, .bit_not => self.lowerReachedOperand(node, uop.operand),
                else => self.lowerExpr(uop.operand),
            };
            break :blk switch (uop.op) {
                .negate => blk2: {
                    const value = self.unwrapOptionalOperand(operand, self.builder.getRefType(operand), uop.operand.span) orelse operand;
                    break :blk2 self.builder.emit(.{ .neg = .{ .operand = value } }, self.builder.getRefType(value));
                },
                // `!` is LOGICAL not. Only a real bool may go through the
                // bitwise `bool_not` (i1); an integer-backed operand — an
                // error binding (u32 tag), a plain integer — lowers as the
                // truthiness complement `operand == 0`: a bitwise not of a
                // nonzero tag stays nonzero, so `if !e` held even on a set
                // error. Anything else is diagnosed.
                .not => blk2: {
                    const oty = self.inferExprType(uop.operand);
                    if (oty == .bool) {
                        break :blk2 self.builder.emit(.{ .bool_not = .{ .operand = operand } }, .bool);
                    }
                    const int_like = self.isIntEx(oty) or
                        (!oty.isBuiltin() and self.module.types.get(oty) == .@"error");
                    if (int_like) {
                        const zero = self.builder.constInt(0, oty);
                        break :blk2 self.builder.emit(.{ .cmp_eq = .{ .lhs = operand, .rhs = zero } }, .bool);
                    }
                    if (self.diagnostics) |d| {
                        d.addFmt(.err, node.span, "'!' needs a bool, integer, or error operand; got '{s}'", .{self.formatTypeName(oty)});
                    }
                    break :blk2 self.builder.constBool(false);
                },
                .bit_not => self.builder.emit(.{ .bit_not = .{ .operand = operand } }, self.builder.getRefType(operand)),
                .xx => self.lowerXX(operand, uop.operand),
                .address_of => blk2: {
                    const inner_ty = self.inferExprType(uop.operand);
                    const ptr_ty = self.module.types.ptrTo(inner_ty);
                    break :blk2 self.builder.emit(.{ .addr_of = .{ .operand = operand } }, ptr_ty);
                },
                .pre_decrement => unreachable,
            };
        },

        .if_expr => self.lowerIfExpr(node, .value),
        .match_expr => self.lowerMatch(node, .value),
        .while_expr => |we| self.lowerWhile(&we),
        .for_expr => |fe| self.lowerFor(&fe),
        .break_expr => self.lowerBreak(node.span),
        .continue_expr => self.lowerContinue(node.span),
        .call => |c| self.lowerCall(&c),
        .ffi_intrinsic_call => |fic| self.lowerFfiIntrinsicCall(&fic, node.span),
        .field_access => |fa| self.lowerFieldAccess(&fa, node.span),
        .struct_literal => |sl| self.lowerStructLiteral(&sl, node.span),
        .self_block => |sb| self.lowerSelfBlock(&sb),
        // `expr { … }` settles here, where the local scope holds the types a
        // function-local declaration registered.
        .juxtaposition => blk: {
            self.settleJuxtaposition(node);
            break :blk self.lowerExpr(node);
        },
        .array_literal => |al| self.lowerArrayLiteral(&al, node.span),
        .index_expr => |ie| self.lowerIndexExpr(&ie),
        .slice_expr => |se| self.lowerSliceExpr(&se),
        // The literal's identity is its node: the env type memo keys on it.
        .lambda => self.lowerLambda(&node.data.lambda),
        .force_unwrap => |fu| self.lowerForceUnwrap(&fu),
        .null_coalesce => |nc| self.lowerNullCoalesce(&nc),
        .deref_expr => |de| self.lowerDerefExpr(&de),

        // Postfix cast `expr.(T)`. A statically-typed receiver converts
        // through the explicit-target `xx` engine — resolve T, lower the
        // operand under it (literals adopt the target exactly as they do
        // for `x : T = xx v`), then lowerXX with T as the destination. One
        // engine, not a fourth cast. A type-erased receiver (`any` /
        // protocol value) is the CHECKED-assertion regime.
        .postfix_cast => |pc| blk: {
            // Optional-chained form `o?.(T)`: chain-null propagates as a
            // null result, the cast/assertion applies to the payload; the
            // result is `?T` (an optional TARGET flattens — one null level).
            if (pc.is_optional_chain) {
                const recv_ty = self.inferExprType(pc.operand);
                const recv_child: ?TypeId = if (!recv_ty.isBuiltin()) child_blk: {
                    const ri = self.module.types.get(recv_ty);
                    if (ri == .optional) break :child_blk ri.optional.child;
                    break :child_blk null;
                } else null;
                const child = recv_child orelse {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "'?.(T)' requires an optional receiver; got '{s}' — use '.(T)'", .{self.formatTypeName(recv_ty)});
                    break :blk self.builder.constUndef(.unresolved);
                };
                if (child == .any) {
                    if (self.refuseProtocolAssertTargetOnAny(pc.type_expr, node.span))
                        break :blk self.builder.constUndef(.unresolved);
                    if (lowerAnyAssertAtSet(self, &pc, node.span, true)) |answer| break :blk answer;
                    break :blk lowerChainedErasedAssert(self, &pc, node);
                }
                // Conversion regime mapped over the chain (typed payload).
                const dst = self.resolveTypeArg(pc.type_expr);
                if (dst == .unresolved) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, pc.type_expr.span, "unknown type in postfix cast '.(T)'", .{});
                    break :blk self.builder.constUndef(.unresolved);
                }
                const dst_is_opt = !dst.isBuiltin() and self.module.types.get(dst) == .optional;
                const result_ty = if (dst_is_opt) dst else self.module.types.optionalOf(dst);
                const opt_val = self.lowerExpr(pc.operand);
                const has_val = self.builder.emit(.{ .optional_has_value = .{ .operand = opt_val } }, .bool);
                const some_bb = self.freshBlock("cast.some");
                const none_bb = self.freshBlock("cast.none");
                const merge_bb = self.freshBlockWithParams("cast.merge", &.{result_ty});
                self.builder.condBr(has_val, some_bb, &.{}, none_bb, &.{});
                self.builder.switchToBlock(some_bb);
                const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = opt_val } }, child);
                const saved_target = self.target_type;
                const saved_postfix = self.xx_is_postfix;
                self.target_type = dst;
                self.xx_is_postfix = true;
                const converted = self.lowerXX(unwrapped, pc.operand);
                self.target_type = saved_target;
                self.xx_is_postfix = saved_postfix;
                const some_result = if (dst_is_opt) converted else self.builder.emit(.{ .optional_wrap = .{ .operand = converted } }, result_ty);
                self.builder.br(merge_bb, &.{some_result});
                self.builder.switchToBlock(none_bb);
                const none_result = self.builder.constNull(result_ty);
                self.builder.br(merge_bb, &.{none_result});
                self.builder.switchToBlock(merge_bb);
                break :blk self.builder.blockParam(merge_bb, 0, result_ty);
            }
            // Unchained `.(T)` with an OPTIONAL receiver: refused — the
            // null case must be handled where the optional is.
            {
                const recv_ty = self.inferExprType(pc.operand);
                if (!recv_ty.isBuiltin() and self.module.types.get(recv_ty) == .optional) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "the receiver is optional ('{s}') — chain with '?.(T)' (null propagates) or unwrap first (`if v := x {{ v.(T) }}`)", .{self.formatTypeName(recv_ty)});
                    break :blk self.builder.constUndef(.unresolved);
                }
            }
            // A set VALUE asked for a member: the tag decides which member the
            // slot carries, so the answer is that member's own value — and a
            // target that never declared itself into the set is refused, since
            // no value of the set is ever one (spec: Open Sets — the downcast).
            {
                const recv_ty = self.inferExprType(pc.operand);
                if (self.isOpenSet(recv_ty)) {
                    const soft = pc.type_expr.data == .optional_type_expr;
                    const target_node = if (soft) pc.type_expr.data.optional_type_expr.inner_type else pc.type_expr;
                    // A bare target name is asked of THIS file: a member's name two
                    // modules declare must reach the one this file selects, or the
                    // downcast asks about somebody else's type.
                    const bare_target: ?[]const u8 = switch (target_node.data) {
                        .identifier => |id| id.name,
                        .type_expr => |te| if (te.protocol_constraints.len == 0) te.name else null,
                        else => null,
                    };
                    var target = TypeId.unresolved;
                    if (bare_target) |nm| {
                        switch (self.bareTypeVerdict(nm, self.current_source_file)) {
                            .ty => |t| target = t,
                            .ambiguous => {
                                if (self.diagnostics) |d| {
                                    const amb_id = d.addFmtId(.err, target_node.span, "'{s}' is declared by more than one module here", .{nm});
                                    d.addHelpFmt(amb_id, target_node.span, null, "name the one this asks about through the module that declares it ('pkg.{s}')", .{nm});
                                }
                                break :blk self.builder.constUndef(.unresolved);
                            },
                            .not_visible => {
                                if (self.diagnostics) |d| {
                                    const nv_id = d.addFmtId(.err, target_node.span, "'{s}' is declared, but not where this module can see it", .{nm});
                                    d.addHelpFmt(nv_id, target_node.span, null, "import the module that declares it, or name it through one ('pkg.{s}')", .{nm});
                                }
                                break :blk self.builder.constUndef(.unresolved);
                            },
                            .none => {},
                        }
                    }
                    if (target == .unresolved) target = self.resolveTypeArg(target_node);
                    if (target != .unresolved and target != .any and target != recv_ty) {
                        const set_decl = self.openSetOf(recv_ty).?.decl;
                        if (self.openSetDeclaresMembership(target, set_decl) and self.scope != null) {
                            const value = self.lowerExpr(pc.operand);
                            break :blk self.lowerOpenSetDowncast(recv_ty, target, value, pc.operand, target_node, soft, node.span);
                        }
                        if (!self.openSetDeclaresMembership(target, set_decl) and
                            self.refuseOpenSetNonMemberTarget(recv_ty, target, node.span))
                        {
                            break :blk self.builder.constUndef(if (soft) self.module.types.optionalOf(target) else target);
                        }
                    }
                }
            }
            // An `any` receiver is the checked-assertion regime; the node
            // carries whether a graceful consumer claimed it.
            if (self.inferExprType(pc.operand) == .any) {
                // `av.(@Any)` is the raw-view RETRIEVAL — the view's own
                // {data, typeId} words, built field-wise; NOT an
                // assertion about the boxed payload. POSTFIX-only:
                // `xx av` keeps the unbox meaning for every target
                // (@Any included) — the assert helpers' generic
                // `xx av` must stay universal. Name-and-shape gated,
                // like @Protocol on a protocol receiver.
                raw_view: {
                    const tname: []const u8 = switch (pc.type_expr.data) {
                        .identifier => |id| id.name,
                        .type_expr => |te| te.name,
                        else => "",
                    };
                    if (!std.mem.eql(u8, tname, "@Any")) break :raw_view;
                    const raw_dst = self.resolveTypeArg(pc.type_expr);
                    if (raw_dst == .unresolved or !self.coercionResolver().isAnyViewDst(raw_dst))
                        break :raw_view;
                    const av_ref = self.lowerExpr(pc.operand);
                    const void_ptr_ty = self.module.types.ptrTo(.void);
                    const data_ref = self.builder.emit(.{ .struct_get = .{ .base = av_ref, .field_index = 0 } }, void_ptr_ty);
                    const tid_ref = self.builder.emit(.{ .struct_get = .{ .base = av_ref, .field_index = 1 } }, .type_value);
                    var raw_fields = [2]Ref{ data_ref, tid_ref };
                    break :blk self.builder.structInit(&raw_fields, raw_dst);
                }
                if (self.refuseProtocolAssertTargetOnAny(pc.type_expr, node.span))
                    break :blk self.builder.constUndef(.unresolved);
                if (lowerAnyAssertAtSet(self, &pc, node.span, false)) |answer| break :blk answer;
                break :blk lowerErasedAssert(self, &pc, pc.operand, node);
            }
            // A PROTOCOL receiver with a concrete (non-recovery) target is
            // the checked DOWNCAST: with the typeId word
            // it is exactly the any assertion over the value's
            // {ctx, typeId} prefix view — the operand wraps in an
            // `xx …: any` (the modeled protocol_to_any conversion) and the
            // same lowering serves all three temperaments. Recovery /
            // conversion targets (p.(*T), p.(@Protocol), p.(any),
            // re-erasure to another protocol) fall through to lowerXX.
            {
                const recv_ty = self.inferExprType(pc.operand);
                const recv_erased = self.getProtocolInfo(recv_ty) != null;
                if (recv_erased) delegate: {
                    const full_dst = self.resolveTypeArg(pc.type_expr);
                    if (full_dst == .unresolved) break :delegate; // diagnosed below
                    // `p.(?*T)` is the SOFT ctx recovery: a checked `p.(*T)`,
                    // not a downcast to the POINTER type. The any-view helpers,
                    // whose type word is the concrete `T`, cannot answer for
                    // `*T`.
                    if (self.lowerSoftPointerRecovery(&pc, full_dst)) |answer|
                        break :blk answer;
                    switch (self.coercionResolver().classifyXX(recv_ty, full_dst)) {
                        .protocol_to_pointer, .protocol_to_raw, .protocol_to_any, .no_op, .erase_protocol, .erase_protocol_wrap, .reerase_protocol, .reerase_protocol_wrap => {},
                        else => {
                            const xx_node = self.alloc.create(Node) catch unreachable;
                            xx_node.* = Node{ .data = .{ .unary_op = .{ .op = .xx, .operand = pc.operand } }, .span = pc.operand.span, .source_file = pc.operand.source_file };
                            break :blk lowerErasedAssert(self, &pc, xx_node, node);
                        },
                    }
                }
            }
            const dst = self.resolveTypeArg(pc.type_expr);
            if (dst == .unresolved) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, pc.type_expr.span, "unknown type in postfix cast '.(T)'", .{});
                break :blk self.builder.constUndef(.unresolved);
            }
            // `expr.(I)`: an INTERFACE target over a CONCRETE (or pointer)
            // receiver builds the handle that borrows that receiver's
            // storage. Erased receivers (any / handle) were handled above; a
            // handle reaching here is the recovery/re-erasure family and
            // stays on lowerXX.
            {
                const recv_t = self.inferExprType(pc.operand);
                const recv_erased = recv_t == .any or self.getProtocolInfo(recv_t) != null;
                // `x.(?P)` on a concrete receiver is the soft PROBE, not a
                // conversion: it answers conformance, so a non-conformer is
                // `null` rather than the erasure's error (§7.9).
                if (!recv_erased and !dst.isBuiltin()) {
                    const di = self.module.types.get(dst);
                    if (di == .optional and self.getProtocolInfo(di.optional.child) != null) {
                        if (self.lowerProtocolProbe(&pc, di.optional.child, dst)) |answer| break :blk answer;
                    }
                }
                if (!recv_erased and self.getProtocolInfo(dst) != null) {
                    break :blk self.lowerInterfaceErasure(&pc, dst, node.span);
                }
            }
            // `value.(P)` on an OPEN SET is the explicit spelling of ordinary set
            // formation, so it accepts exactly what formation accepts: a member of
            // that set (or a `P` already). Anything else has nothing to lift, and
            // an explicit cast must not pass the bytes through as if it did.
            if (self.isOpenSet(dst)) {
                if (self.refuseOpenSetNonMember(self.inferExprType(pc.operand), dst, node.span))
                    break :blk self.builder.constUndef(dst);
            }
            const saved_target = self.target_type;
            self.target_type = dst;
            defer self.target_type = saved_target;
            const operand = lowerCastOperand(self, pc.operand);
            const saved_postfix = self.xx_is_postfix;
            self.xx_is_postfix = true;
            defer self.xx_is_postfix = saved_postfix;
            break :blk self.lowerXX(operand, pc.operand);
        },
        .enum_literal => |el| self.lowerEnumLiteral(&el),
        .comptime_expr => |ct| self.lowerInlineComptime(ct.expr),
        .insert_expr => |ins| blk: {
            break :blk self.lowerInsertExprValue(ins.expr);
        },
        .tuple_literal => |tl| self.lowerTupleLiteral(&tl),
        .spread_expr => self.emitError("spread_expr", node.span),
        .chained_comparison => |cc| self.lowerChainedComparison(&cc),

        // `context.jni(env) { body }` in expression position — the block's
        // value becomes the env-scope's value. Save→set→body-value→restore.
        .jni_env_block => |eb| blk: {
            const env_ref = self.lowerExpr(eb.env);
            const fids = self.getJniEnvTlFids();
            const ptr_ty = self.module.types.ptrTo(.void);
            const saved_tl = self.builder.emit(.{ .call = .{ .callee = fids.get, .args = &.{} } }, ptr_ty);
            const set_args = self.alloc.dupe(Ref, &.{env_ref}) catch unreachable;
            _ = self.builder.emit(.{ .call = .{ .callee = fids.set, .args = set_args } }, .void);
            self.jni_env_stack.append(self.alloc, env_ref) catch unreachable;
            const value = self.lowerBlockValue(eb.body) orelse self.builder.constInt(0, .void);
            _ = self.jni_env_stack.pop();
            const restore_args = self.alloc.dupe(Ref, &.{saved_tl}) catch unreachable;
            _ = self.builder.emit(.{ .call = .{ .callee = fids.set, .args = restore_args } }, .void);
            break :blk value;
        },

        // Statements that can appear in expression position
        .block => |blk| blk: {
            // Create a child scope for block-level variable shadowing
            var block_scope = Scope.init(self.alloc, self.scope, &self.next_binding_id);
            const saved_scope = self.scope;
            self.scope = &block_scope;
            const saved_defer_len = self.defer_stack.items.len;
            defer {
                self.emitBlockDefers(saved_defer_len);
                self.scope = saved_scope;
                block_scope.deinit();
            }
            // A block in expression position yields its last statement's
            // value when that statement is an expression; otherwise it runs as
            // statements and evaluates to void.
            if (blk.produces_value and blk.stmts.len > 0) {
                // Non-last statements lower as plain statements; force_block_value
                // must be OFF for them (a mid-block if-else is a statement).
                const saved_fbv = self.force_block_value;
                self.force_block_value = false;
                for (blk.stmts[0 .. blk.stmts.len - 1]) |stmt| {
                    self.lowerStmt(stmt);
                }
                // The LAST statement is the block's value — force value-position
                // lowering so a trailing (possibly nested) if-else / match yields
                // a phi'd value instead of being demoted to a statement whose
                // result is dropped. Mirrors `lowerBlockValue`.
                self.force_block_value = true;
                const tail = blk.stmts[blk.stmts.len - 1];
                const saved_target = self.saveTarget();
                self.reachOperand(node, tail);
                // The last statement may itself terminate the block (a trailing
                // `return`/`break`/`continue` statement — e.g. an `if`-arm
                // `{ return -1; }` in value position). In that case there is no
                // value to yield AND appending a `const_int(0, .void)` placeholder
                // would land a non-terminator instruction AFTER the terminator,
                // producing invalid "terminator in the middle of a block" IR.
                // Return `Ref.none` — the caller detects the
                // termination via `currentBlockHasTerminator()` and never reads it.
                const last_val = self.tryLowerAsExpr(tail) orelse
                    (if (self.currentBlockHasTerminator()) Ref.none else self.builder.constInt(0, .void));
                saved_target.restore();
                self.force_block_value = saved_fbv;
                break :blk last_val;
            }
            // Nothing here is in value position — clear `force_block_value` so
            // the demand this block sits under cannot reach its statements and
            // make a guard-`if` look like a value use (mirrors `lowerBlock`).
            const saved_fbv_stmts = self.force_block_value;
            self.force_block_value = false;
            for (blk.stmts) |stmt| {
                self.lowerStmt(stmt);
            }
            self.force_block_value = saved_fbv_stmts;
            // Same terminator guard as the produces-value path above: a block whose
            // statements terminated it (trailing `return`/`break`/`continue`) must
            // not get a `const_int` placeholder appended after the terminator.
            if (self.currentBlockHasTerminator()) break :blk Ref.none;
            // The position demanded a value and this block's last statement is a
            // declaration, so it has none. Say so here rather than hand back a
            // void the binding tries to `alloca`. An EMPTY block is exempt: `{}`
            // is how the void value itself is written (`.{ {}, 9 }` for a
            // `Tuple(void, i32)`).
            if (blk.stmts.len > 0) {
                if (self.diagnostics) |diags| {
                    diags.addFmt(.err, blk.stmts[blk.stmts.len - 1].span, "this block is used as a value but produces none — end it with a trailing expression", .{});
                }
            }
            break :blk self.builder.constInt(0, .void);
        },

        // type_expr can appear as a variable reference when the name collides
        // with a builtin type name (e.g. u8). Check scope first.
        .type_expr => |te| blk: {
            if (self.scope) |scope| {
                if (scope.lookup(te.name)) |binding| {
                    if (binding.is_alloca) {
                        break :blk self.builder.load(binding.ref, binding.ty);
                    }
                    break :blk binding.ref;
                }
            }
            if (self.program_index.lookup(.global, te.name)) |gi| {
                break :blk self.builder.emit(.{ .global_get = gi.id }, gi.ty);
            }
            // Type literal in expression position → first-class
            // `const_type` Value (i64 = TypeId.index()). Makes
            // `t : Type = f64;` store a real TypeId; lets
            // `t == f64` icmp at runtime against the same TypeId.
            if (self.isKnownTypeName(te.name)) {
                const ty = type_bridge.resolveAstType(node, &self.module.types, &self.program_index);
                break :blk self.builder.constType(ty);
            }
            break :blk self.emitError(te.name, node.span);
        },

        // Compound type literals (`*T`, `[]T`, `[*]T`, `?T`, `[N]T`, fn types)
        // in expression position are first-class `Type` values, exactly like
        // the named form above (`t : Type = *i64;` ↔ `t : Type = f64;`). Also
        // the path a static `cast(*i64) v` type argument takes — call args are
        // lowered before the cast handler inspects the AST.
        .pointer_type_expr,
        .many_pointer_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .array_type_expr,
        .function_type_expr,
        .tuple_type_expr,
        => blk: {
            const ty = self.resolveTypeWithBindings(node);
            // The resolver diagnosed any unresolved leaf; don't mint a Type
            // value around the failure sentinel. For `Tuple(...)` this is also
            // where a standalone `Tuple(1, 2)` value-expression is rejected —
            // `resolveTupleTypeWithBindings` diagnoses the non-type element and
            // returns `.unresolved`, so no value is fabricated.
            if (ty == .unresolved) break :blk self.emitError("unknown_expr", node.span);
            break :blk self.builder.constType(ty);
        },

        .try_expr => |te| self.lowerTry(te.operand, node.span),
        .catch_expr => |ce| self.lowerCatch(&ce, node.span),
        .caller_site => self.lowerCallerSite(node),
        .asm_expr => |ae| self.lowerAsmExpr(&ae, node.span),
        // `@error("msg");` that survived comptime pruning into live code —
        // fire at lower time (specs: the directive fires when REACHED; a
        // pruned `inline if` arm never lowers, so per-monomorphization
        // rejection works exactly like the module-scope `inline match` form).
        // Inside a monomorphized body the diagnostic anchors at the
        // OUTERMOST instantiation call site — the user call that forced the
        // instantiation — with the directive's own location as a note; a
        // library-internal anchor would read like a comptime panic.
        .error_directive => |ed| blk: {
            if (self.diagnostics) |d| {
                if (self.mono_sites.items.len > 0) {
                    const site = self.mono_sites.items[0];
                    const saved_file = d.current_source_file;
                    d.current_source_file = site.source;
                    const id = d.addFmtId(.err, site.span, "{s}", .{ed.message});
                    d.current_source_file = saved_file;
                    d.addNoteFmt(id, node.span, "raised by '@error' here", .{});
                } else {
                    d.addFmt(.err, node.span, "{s}", .{ed.message});
                }
            }
            break :blk self.emitPlaceholder("error_directive");
        },
        else => self.emitError("unknown_expr", node.span),
    };
}

/// An assertion on an `any` receiver whose target is a BARE open set, answered
/// here rather than through the checked-cast helpers: an `any` never holds a set
/// value, since boxing a set boxes the member it carries, so no box can ever
/// supply the conversion those helpers would ask for. Each form answers from its
/// own contract — the soft `.(?P)` is a question whose answer is null for every
/// box, and an assertion states what cannot hold, so it is refused where it is
/// written. Null for a target that is not a bare set: the ordinary route stands.
const AssertRegime = enum { unconsumed, consumed, soft };

fn assertRegime(pc: *const ast.PostfixCast) AssertRegime {
    if (pc.type_expr.data == .optional_type_expr) return .soft;
    return if (pc.consumed) .consumed else .unconsumed;
}

/// The `CastError` set core.sx declares — an error set of that name carrying
/// `mismatch` — or `.unresolved` when core is not in the program.
pub fn castErrorSet(self: *Lowering) TypeId {
    const set = self.module.types.findByName(self.module.types.internString("CastError")) orelse return .unresolved;
    if (self.module.types.get(set) != .@"error") return .unresolved;
    return if (self.module.types.errorSetMember(set, "mismatch") == .one) set else .unresolved;
}

fn mismatchTag(self: *Lowering, set: TypeId) Ref {
    const member = self.module.types.errorSetMember(set, "mismatch").one;
    return self.builder.constInt(@intCast(member), set);
}

fn diagCastErrorMissing(self: *Lowering, span: ast.Span) Ref {
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "a consumed assertion needs 'CastError' in scope — @import \"modules/std/core.sx\"", .{});
    return self.builder.constUndef(.unresolved);
}

/// A checked assertion whose receiver node `recv` lowers to an `any` view
/// (an `any`, or a protocol wrapped in `xx`). Unconsumed is the spelled
/// `@cast` call, so the call site is the panic's site; graceful and soft
/// lower structurally over the boxed tag.
fn lowerErasedAssert(self: *Lowering, pc: *const ast.PostfixCast, recv: *Node, node: *const Node) Ref {
    const regime = assertRegime(pc);
    if (regime == .unconsumed) {
        const callee_node = Node{ .data = .{ .identifier = .{ .name = "@cast" } }, .span = node.span, .source_file = node.source_file };
        const args = self.alloc.dupe(*Node, &.{ pc.type_expr, recv }) catch unreachable;
        const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = args };
        return self.lowerCall(&syn_call);
    }
    const target_node = if (regime == .soft) pc.type_expr.data.optional_type_expr.inner_type else pc.type_expr;
    const target = self.resolveTypeArg(target_node);
    if (target == .unresolved) {
        if (self.diagnostics) |d| d.addFmt(.err, target_node.span, "unknown type in postfix cast '.(T)'", .{});
        return self.builder.constUndef(.unresolved);
    }
    const saved_target = self.target_type;
    self.target_type = .any;
    const av = self.lowerExpr(recv);
    self.target_type = saved_target;
    return lowerAnyAssertView(self, av, target, regime, node.span);
}

/// The graceful or soft assertion over the `any` view `av`: the boxed tag
/// against `target`, a typed load on a match. Soft answers `?T`; consumed
/// answers the failable `(T, !CastError)` tuple.
fn lowerAnyAssertView(self: *Lowering, av: Ref, target: TypeId, regime: AssertRegime, span: ast.Span) Ref {
    const soft = regime == .soft;
    const set = self.castErrorSet();
    if (!soft and set == .unresolved) return diagCastErrorMissing(self, span);
    const result_ty = if (soft) self.module.types.optionalOf(target) else self.module.types.internFailable(target, set);
    const tid = self.builder.emit(.{ .struct_get = .{ .base = av, .field_index = 1 } }, .type_value);
    const eq_args = self.alloc.dupe(Ref, &.{ tid, self.builder.constType(target) }) catch unreachable;
    const matches = self.builder.callBuiltin(.rt_type_eq, eq_args, .bool);
    const ok_bb = self.freshBlock("assert.ok");
    const miss_bb = self.freshBlock("assert.miss");
    const merge_bb = self.freshBlockWithParams("assert.merge", &.{result_ty});
    self.builder.condBr(matches, ok_bb, &.{}, miss_bb, &.{});
    self.builder.switchToBlock(ok_bb);
    const value = self.builder.emit(.{ .unbox_any = .{ .operand = av } }, target);
    const ok_result = if (soft)
        self.builder.optionalWrap(value, result_ty)
    else
        self.buildFailableTuple(result_ty, &.{value}, self.builder.constInt(0, set));
    self.builder.br(merge_bb, &.{ok_result});
    self.builder.switchToBlock(miss_bb);
    const miss_result = if (soft)
        self.builder.constNull(result_ty)
    else
        self.buildFailableTuple(result_ty, &.{self.builder.constUndef(target)}, mismatchTag(self, set));
    self.builder.br(merge_bb, &.{miss_result});
    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, result_ty);
}

/// `o?.(T)` on a `?any`: the unchained assertion mapped over the optional.
/// Chain-null is a value in every regime; a present payload runs the
/// unchained form on a scope-bound temp and its answer is lifted — `?T`
/// for soft (one null level) and unconsumed, `(?T, !CastError)` for consumed.
fn lowerChainedErasedAssert(self: *Lowering, pc: *const ast.PostfixCast, node: *const Node) Ref {
    const regime = assertRegime(pc);
    const target_node = if (regime == .soft) pc.type_expr.data.optional_type_expr.inner_type else pc.type_expr;
    const target = self.resolveTypeArg(target_node);
    if (target == .unresolved) {
        if (self.diagnostics) |d| d.addFmt(.err, target_node.span, "unknown type in postfix cast '.(T)'", .{});
        return self.builder.constUndef(.unresolved);
    }
    const opt_ty = self.module.types.optionalOf(target);
    const set = self.castErrorSet();
    if (regime == .consumed and set == .unresolved) return diagCastErrorMissing(self, node.span);
    const result_ty = if (regime == .consumed) self.module.types.internFailable(opt_ty, set) else opt_ty;

    const opt_val = self.lowerExpr(pc.operand);
    const has_val = self.builder.emit(.{ .optional_has_value = .{ .operand = opt_val } }, .bool);
    const some_bb = self.freshBlock("cast.some");
    const none_bb = self.freshBlock("cast.none");
    const merge_bb = self.freshBlockWithParams("cast.merge", &.{result_ty});
    self.builder.condBr(has_val, some_bb, &.{}, none_bb, &.{});

    self.builder.switchToBlock(some_bb);
    const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = opt_val } }, .any);
    const temp_name = std.fmt.allocPrint(self.alloc, "$cast_{d}", .{self.block_counter}) catch @panic("out of memory");
    self.block_counter += 1;
    self.scope.?.put(temp_name, .{ .ref = unwrapped, .ty = .any, .is_alloca = false });
    const recv = self.synthNode(.{ .identifier = .{ .name = temp_name } }, node.span, node.source_file);
    const inner = lowerErasedAssert(self, pc, recv, node);
    const some_result = switch (regime) {
        .soft => inner,
        .unconsumed => self.builder.optionalWrap(inner, opt_ty),
        .consumed => lifted: {
            const inner_ty = self.module.types.internFailable(target, set);
            const value = self.extractSuccessValue(inner, inner_ty, target);
            const tag = self.extractErrorSlot(inner, inner_ty, set);
            break :lifted self.buildFailableTuple(result_ty, &.{self.builder.optionalWrap(value, opt_ty)}, tag);
        },
    };
    self.builder.br(merge_bb, &.{some_result});

    self.builder.switchToBlock(none_bb);
    const none_result = if (regime == .consumed)
        self.buildFailableTuple(result_ty, &.{self.builder.constNull(opt_ty)}, self.builder.constInt(0, set))
    else
        self.builder.constNull(opt_ty);
    self.builder.br(merge_bb, &.{none_result});

    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, result_ty);
}

fn lowerAnyAssertAtSet(self: *Lowering, pc: *const ast.PostfixCast, span: ast.Span, chained: bool) ?Ref {
    const soft = pc.type_expr.data == .optional_type_expr;
    const target_node = if (soft) pc.type_expr.data.optional_type_expr.inner_type else pc.type_expr;
    const target = self.resolveTypeArg(target_node);
    if (target == .unresolved or !self.isOpenSet(target)) return null;
    const optional_ty = self.module.types.optionalOf(target);
    if (soft) return self.builder.constNull(optional_ty);
    if (self.refuseSetFromAny(target, span))
        return self.builder.constUndef(if (chained) optional_ty else target);
    return null;
}

/// The single register a constraint pins, or null for a register-class /
/// memory constraint. Strips a leading `=`/`+` (output / read-write marker),
/// then returns the `{reg}` body. `"={eax}"` → `eax`, `"+{rax}"` → `rax`,
/// `"{rdi}"` → `rdi`; `"=r"` / `"r"` / `"=m"` → null.
fn pinnedRegister(constraint: []const u8) ?[]const u8 {
    var c = constraint;
    if (c.len > 0 and (c[0] == '=' or c[0] == '+')) c = c[1..];
    if (c.len >= 2 and c[0] == '{' and c[c.len - 1] == '}') return c[1 .. c.len - 1];
    return null;
}

/// The asm expression's result type from its `out_value` operands (design
/// §II.5): 0 → `void`; 1 → that operand's type; N → a tuple `(T1,…,Tn)`, named
/// by each operand's effective name (explicit `[name]` else the `{reg}` pin;
/// `.empty` for an anonymous field). Returns `.unresolved` if any output type is
/// unresolvable (the resolver already diagnosed). Shared by `lowerAsmExpr` and
/// `ExprTyper.inferType` so a `return asm`, a `:=` binding, and a `q, r := asm`
/// destructure all agree on the type.
pub fn asmResultType(self: *Lowering, ae: *const ast.AsmExpr) TypeId {
    var fields = std.ArrayList(TypeId).empty;
    defer fields.deinit(self.alloc);
    var names = std.ArrayList(types.StringId).empty;
    defer names.deinit(self.alloc);
    var has_names = false;
    for (ae.operands) |op| {
        if (op.role != .out_value) continue;
        const fty = self.resolveTypeWithBindings(op.payload);
        if (fty == .unresolved) return .unresolved;
        fields.append(self.alloc, fty) catch unreachable;
        const eff = op.name orelse (pinnedRegister(op.constraint) orelse "");
        if (eff.len != 0) has_names = true;
        names.append(self.alloc, if (eff.len == 0) types.StringId.empty else self.module.types.internString(eff)) catch unreachable;
    }
    if (fields.items.len == 0) return .void;
    if (fields.items.len == 1) return fields.items[0];
    return self.module.types.internProduct(
        self.alloc.dupe(TypeId, fields.items) catch unreachable,
        if (has_names) self.alloc.dupe(types.StringId, names.items) catch unreachable else null,
    );
}

/// Inline assembly lowering: validate the asm shape with specific named
/// diagnostics, then emit the `inline_asm` op. Every rejection returns a
/// placeholder Ref instead of the op, so `hasErrors()` aborts the build on
/// whichever diagnostic fired.
pub fn lowerAsmExpr(self: *Lowering, ae: *const ast.AsmExpr, span: ast.Span) Ref {
    const diags = self.diagnostics orelse return self.emitPlaceholder("inline_asm");

    // (1) The template must be a compile-time-known string (a `"..."` literal or
    // a `@string` heredoc), not a runtime expression.
    const template_is_string = switch (ae.template.data) {
        .string_literal => true,
        else => false,
    };
    if (!template_is_string) {
        diags.addFmt(.err, ae.template.span, "asm template must be a compile-time-known string", .{});
        return self.emitPlaceholder("inline_asm");
    }

    // (2) Operand-name validation (design §II.5 auto-naming rule). For each
    // explicit `[name]`:
    //   - reject the ECHO form `[eax] "={eax}"` — a label identical to the
    //     register its own constraint pins carries no information (the operand
    //     is already auto-named after that register); and
    //   - reject DUPLICATE names — `%[name]` / the result field would be
    //     ambiguous.
    for (ae.operands, 0..) |op, i| {
        const name = op.name orelse continue;
        if (pinnedRegister(op.constraint)) |reg| {
            if (std.mem.eql(u8, name, reg)) {
                diags.addFmt(.err, span, "redundant asm operand name `{s}` — it already names the pinned register; drop the `[{s}]`", .{ name, name });
                return self.emitPlaceholder("inline_asm");
            }
        }
        for (ae.operands[0..i]) |prev| {
            const pname = prev.name orelse continue;
            if (std.mem.eql(u8, name, pname)) {
                diags.addFmt(.err, span, "duplicate asm operand name `{s}`", .{name});
                return self.emitPlaceholder("inline_asm");
            }
        }
    }

    // (3) An asm with no value outputs yields no result, so it must be
    // `volatile` — otherwise its effects could be deleted. Mirrors Zig's rule.
    var n_outputs: usize = 0;
    for (ae.operands) |op| {
        if (op.role == .out_value) n_outputs += 1;
    }
    if (n_outputs == 0 and !ae.is_volatile) {
        diags.addFmt(.err, span, "asm expression with no outputs must be marked `volatile`", .{});
        return self.emitPlaceholder("inline_asm");
    }

    // (4) Every `%[name]` in the template must name an operand (effective name:
    // explicit `[name]` or auto-derived register). Caught here so emit's
    // template rewriter never sees an unknown reference. §II.6.
    {
        const tmpl = ae.template.data.string_literal.raw;
        var i: usize = 0;
        while (i < tmpl.len) : (i += 1) {
            if (tmpl[i] != '%' or i + 1 >= tmpl.len) continue;
            const nxt = tmpl[i + 1];
            if (nxt == '%' or nxt == '=') {
                i += 1;
                continue;
            }
            if (nxt != '[') continue;
            const close = std.mem.indexOfScalarPos(u8, tmpl, i + 2, ']') orelse {
                diags.addFmt(.err, span, "unterminated `%[` in asm template", .{});
                return self.emitPlaceholder("inline_asm");
            };
            var ref_name = tmpl[i + 2 .. close];
            if (std.mem.indexOfScalar(u8, ref_name, ':')) |colon| ref_name = ref_name[0..colon];
            var found = false;
            for (ae.operands) |op| {
                const eff = op.name orelse (pinnedRegister(op.constraint) orelse "");
                if (eff.len != 0 and std.mem.eql(u8, eff, ref_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                diags.addFmt(.err, span, "asm template references `%[{s}]` but no operand is named `{s}`", .{ ref_name, ref_name });
                return self.emitPlaceholder("inline_asm");
            }
            i = close;
        }
    }

    // (5) An indirect (`*`) constraint hands the asm an address, which only a
    // place output supplies.
    for (ae.operands) |op| {
        if (op.role == .out_place or std.mem.indexOfScalar(u8, op.constraint, '*') == null) continue;
        diags.addFmt(.err, op.payload.span, "asm constraint \"{s}\" is indirect: its operand is a place output, `-> *place`", .{op.constraint});
        return self.emitPlaceholder("inline_asm");
    }

    // ── Build the IR op. Result type from the out_value operands (0→void,
    // 1→T, N→named tuple). N outputs → LLVM returns a struct {T1,…,Tn}, which
    // is exactly sx's tuple representation, so emit needs no special case. ──
    const result_ty = self.asmResultType(ae);
    if (result_ty == .unresolved) return self.emitPlaceholder("inline_asm");

    // IR operands, in source order (= `%N` index space + LLVM operand order).
    const ir_ops = self.alloc.alloc(inst_mod.InlineAsm.AsmOperand, ae.operands.len) catch unreachable;
    for (ae.operands, 0..) |op, i| {
        // Effective name (design §II.5): explicit `[name]`, else auto-derived
        // from a `{reg}` pin, else anonymous (`.empty`).
        const eff_name: []const u8 = op.name orelse (pinnedRegister(op.constraint) orelse "");
        var operand_ref: Ref = Ref.none;
        var out_ty: TypeId = .void;
        switch (op.role) {
            // Inputs (incl. symbol operands `"s"` — a function/global whose
            // mangled name the template emits, e.g. a direct `bl %[fn]`). A
            // symbol RHS (a function name) lowers to its address (`ptr @fn`);
            // emit passes it with its own type so the backend prints the symbol.
            .input => operand_ref = self.lowerExpr(op.payload),
            .out_value => out_ty = self.resolveTypeWithBindings(op.payload),
            .out_place => {
                // Read-write (`+`) outputs tie an input to the output and seed
                // it with the place's loaded value; indirect-memory (`=*m`)
                // outputs pass the place address as a pointer arg and the asm
                // writes through it — both handled in `emitInlineAsm`.
                // `*place` lowers to its address (a pointer); the asm result is
                // stored through it. The stored type is the pointee.
                operand_ref = self.lowerExpr(op.payload);
                const pty = self.inferExprType(op.payload);
                out_ty = if (!pty.isBuiltin()) blk: {
                    const info = self.module.types.get(pty);
                    break :blk if (info == .pointer) info.pointer.pointee else .unresolved;
                } else .unresolved;
                if (out_ty == .unresolved) {
                    diags.addFmt(.err, span, "asm `-> *place` output target must be an addressable place", .{});
                    return self.emitPlaceholder("inline_asm");
                }
            },
        }
        ir_ops[i] = .{
            .role = switch (op.role) {
                .out_value => .out_value,
                .out_place => .out_place,
                .input => .input,
            },
            .name = if (eff_name.len == 0) types.StringId.empty else self.module.types.internString(eff_name),
            .constraint = self.module.types.internString(op.constraint),
            .operand = operand_ref,
            .out_ty = out_ty,
        };
    }

    const ir_clobbers = self.alloc.alloc(types.StringId, ae.clobbers.len) catch unreachable;
    for (ae.clobbers, 0..) |cl, i| {
        ir_clobbers[i] = self.module.types.internString(cl);
    }

    // Template text RAW — no sx escape processing (matches `@string` literal
    // bytes; the `%[name]`/`%%`/`$` rewrite happens at emit). §II.11.
    const template_text = ae.template.data.string_literal.raw;

    return self.builder.emit(.{ .inline_asm = .{
        .template = self.module.types.internString(template_text),
        .operands = ir_ops,
        .clobbers = ir_clobbers,
        .has_side_effects = ae.is_volatile,
    } }, result_ty);
}

/// If `node` names a `for *x in xs` by-ref capture (an `*elem`), returns
/// the element (pointee) type so a value-position use can auto-deref it.
pub fn refCapturePointee(self: *Lowering, node: *const Node) ?TypeId {
    if (node.data != .identifier) return null;
    const scope = self.scope orelse return null;
    const binding = scope.lookup(node.data.identifier.name) orelse return null;
    if (!binding.is_ref_capture or binding.ty.isBuiltin()) return null;
    const info = self.module.types.get(binding.ty);
    return if (info == .pointer) info.pointer.pointee else null;
}

/// Is `ty` a type that may be used directly as a runtime branch condition?
/// A condBr (and the short-circuit `and`/`or` merges) ultimately tests an
/// i1: lowering must therefore reduce the condition to something the backend
/// can compare against zero/null. The acceptable categories all lower to an
/// LLVM integer or pointer (or, for `.optional`, are reduced to their
/// has_value i1 by the caller):
///   • bool / integers (signed/unsigned/usize/isize)
///   • integer-backed nominals: `enum` (incl. `enum flags`, e.g. `if p & .read`)
///     and an error (a u32 tag) — both reach condBr as a plain integer
///   • pointers: `*T` / `[*]T` (compared against null)
///   • `optional` — the caller emits `optional_has_value`
/// Everything else (float, void, string, any, type_value, struct/union/tuple/
/// array/slice/vector/function/closure/protocol/pack) reaches condBr as a
/// non-comparable aggregate or a value with no truthiness, which folds truthy
/// and `@panic`s in the backend. Such a condition is a type
/// error — see `checkConditionType`.
fn isValidConditionType(self: *Lowering, ty: TypeId) bool {
    if (ty == .unresolved) return true; // already-diagnosed elsewhere; don't double-report
    return switch (self.module.types.get(ty)) {
        .bool, .signed, .unsigned, .usize, .isize => true,
        .pointer, .many_pointer => true,
        .@"enum", .@"error" => true,
        .optional => true,
        else => false,
    };
}

/// Emit a located type error when `ty` cannot be used as a branch condition
/// (see `isValidConditionType`). Returns `true` if the type is valid (caller
/// proceeds normally), `false` if a diagnostic was emitted (caller should
/// recover with a placeholder bool so lowering doesn't crash before the
/// diagnostic surfaces). This is the lowering-time replacement for the
/// backend `@panic` in `emitCondBr`: the type and span are both
/// available here, so we report a clean compile-time error instead.
pub fn checkConditionType(self: *Lowering, ty: TypeId, span: ast.Span) bool {
    if (isValidConditionType(self, ty)) return true;
    if (self.diagnostics) |d| d.addFmt(.err, span, "condition must be a bool, integer, pointer, or optional, but has type '{s}'", .{self.formatTypeName(ty)});
    return false;
}

/// Lower `node` as a boolean condition, narrowing every truthy shape
/// `isValidConditionType` admits down to an i1: an integer-backed value against
/// zero, a pointer against null, an optional to its has_value flag
/// (presence-as-truth, the same rule as `if opt`/`while opt`). The narrowing is
/// mandatory here rather than deferred to the branch, because `and`/`or` join
/// both operands in ONE `bool` merge parameter — a wider operand reaching that
/// merge is an ill-typed phi.
/// A non-condition-typed operand (struct/float/...) is rejected with a located
/// type error via `checkConditionType`; on rejection a placeholder `false` is
/// returned so lowering can continue to surface the diagnostic.
pub fn lowerBoolCondition(self: *Lowering, node: *const Node) Ref {
    const ty = self.inferExprType(node);
    if (!self.checkConditionType(ty, node.span)) {
        _ = self.lowerExpr(node); // still lower for side effects / further diagnostics
        return self.builder.constBool(false);
    }
    const v = self.lowerExpr(node);
    if (ty == .unresolved) return v;
    return switch (self.module.types.get(ty)) {
        .signed, .unsigned, .usize, .isize, .@"enum", .@"error" => self.builder.emit(.{ .cmp_ne = .{
            .lhs = v,
            .rhs = self.builder.constInt(0, ty),
        } }, .bool),
        .pointer, .many_pointer => self.builder.emit(.{ .cmp_ne = .{
            .lhs = v,
            .rhs = self.builder.constNull(ty),
        } }, .bool),
        .optional => self.builder.emit(.{ .optional_has_value = .{ .operand = v } }, .bool),
        else => v,
    };
}

/// `subject is target`. The target is a TYPE, so the answer is a
/// classification, never a value comparison. Four subject shapes reach here:
/// a static type reference (folded), an interface handle (a handle's referent
/// is behind `@typeOf`, so the handle itself answers about the interface it
/// carries), an `any` box (its tag, unpeeled), and a runtime `Type` value.
/// Anything else is a statically-typed value and folds through its own type.
pub fn lowerIs(self: *Lowering, bop: *const ast.BinaryOp) Ref {
    if (self.staticIsCondition(bop.lhs, bop.rhs)) |answer| return self.builder.constBool(answer);

    const subject = self.lowerExpr(bop.lhs);
    const subject_ty = self.builder.getRefType(subject);

    // An interface HANDLE classifies as the interface it carries: the referent
    // is reached through `@typeOf(h)`, not through the handle.
    if (self.getProtocolInfo(subject_ty)) |_| return self.builder.constBool(staticAnswerOrFalse(self, subject_ty, bop.rhs));

    const tag: Ref = if (subject_ty == .type_value)
        subject
    else if (subject_ty == .any)
        self.builder.emit(.{ .struct_get = .{ .base = subject, .field_index = 1 } }, .type_value)
    else
        return self.builder.constBool(staticAnswerOrFalse(self, subject_ty, bop.rhs));

    return runtimeIsAnswer(self, tag, bop.rhs, bop.lhs.span);
}

/// The static answer for a subject whose TYPE is the classified thing: an
/// interface handle (it is its own interface, no other interface and no
/// concrete type, and satisfies a constraint exactly when a bridge
/// `impl C for I` is visible) or an ordinary value (its static type).
fn staticAnswerOrFalse(self: *Lowering, subject_ty: TypeId, rhs: *const Node) bool {
    return self.staticIsAnswer(subject_ty, rhs) orelse false;
}

/// The runtime answer over a `Type`-valued tag: an OR-reduction over the tag
/// set the target denotes.
fn runtimeIsAnswer(self: *Lowering, tag: Ref, rhs: *const Node, span: ast.Span) Ref {
    const target = self.classifyIsTarget(rhs) orelse return self.builder.constBool(false);
    // Signedness reads the tag-indexed table rather than an OR over the tag
    // set: the set is only complete once every type is registered, and the
    // `{}` formatter asks this of types that register after it lowers.
    if (target == .category and std.mem.eql(u8, target.category, "unsigned")) {
        const args = self.alloc.dupe(Ref, &.{tag}) catch return self.builder.constBool(false);
        return self.builder.callBuiltin(.is_unsigned, args, .bool);
    }
    if (target == .category and (std.mem.eql(u8, target.category, "int") or std.mem.eql(u8, target.category, "signed"))) {
        const b = &self.builder;
        const yes = self.freshBlock("is.integer");
        const no = self.freshBlock("is.other");
        const merge = self.freshBlock("is.merge");
        const slot = b.alloca(.bool);
        var cases = [_]inst_mod.SwitchBranch.IntegerCase{
            .{ .signed = true, .target = yes },
            .{ .signed = false, .target = yes },
        };
        const count: usize = if (std.mem.eql(u8, target.category, "int")) 2 else 1;
        b.integerSwitchBr(tag, &.{}, cases[0..count], no);
        b.switchToBlock(yes);
        b.store(slot, b.constBool(true));
        b.br(merge, &.{});
        b.switchToBlock(no);
        b.store(slot, b.constBool(false));
        b.br(merge, &.{});
        b.switchToBlock(merge);
        return b.load(slot, .bool);
    }
    const tags: []const u64 = switch (target) {
        .category => |word| self.resolveTypeCategoryTags(word),
        .concrete => |ty| blk: {
            const one = self.alloc.alloc(u64, 1) catch break :blk &.{};
            one[0] = ty.index();
            break :blk one;
        },
        .interface, .constraint => |contract| return conformanceAsk(self, tag, contract),
        // A parameterized constraint instantiation mints no type, so it keys no
        // conformance table; only the static fold answers for one.
        .param_constraint => {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "a parameterized constraint has no runtime conformer set — ask it of a type expression, where it folds", .{});
            return self.builder.constBool(false);
        },
    };
    if (tags.len == 0) return self.builder.constBool(false);
    var acc: ?Ref = null;
    for (tags) |t| {
        const want = self.builder.emit(.{ .const_type = TypeId.fromIndex(@intCast(t)) }, .type_value);
        const args = self.alloc.dupe(Ref, &.{ tag, want }) catch continue;
        const eq = self.builder.callBuiltin(.rt_type_eq, args, .bool);
        acc = if (acc) |a| self.builder.emit(.{ .bit_or = .{ .lhs = a, .rhs = eq } }, .bool) else eq;
    }
    return acc orelse self.builder.constBool(false);
}

/// `tag is <contract>` over a runtime `Type`: one row of the contract's
/// conformance table. An interface's row is its vtable-or-null, so the question
/// is whether that word is present; a constraint's row is the answer itself.
pub fn conformanceAsk(self: *Lowering, tag: Ref, contract: TypeId) Ref {
    const table = self.conformanceTable(contract) orelse return self.builder.constBool(false);
    if (self.protocolKindOf(contract)) |kind| {
        if (kind == .erased) {
            const vt = self.builder.emit(.{ .conformance_lookup = .{
                .contract = contract,
                .tag = tag,
                .table = table,
                .row = .vtable,
            } }, self.module.types.ptrTo(.void));
            return self.builder.emit(.{ .cmp_ne = .{ .lhs = vt, .rhs = self.builder.constNull(self.module.types.ptrTo(.void)) } }, .bool);
        }
    }
    return self.builder.emit(.{ .conformance_lookup = .{
        .contract = contract,
        .tag = tag,
        .table = table,
        .row = .bit,
    } }, .bool);
}

pub fn lowerBinaryOp(self: *Lowering, node: *const Node) Ref {
    const bop = &node.data.binary_op;
    // `is` reads its RHS as a TYPE, so it is answered before either operand is
    // lowered as a value.
    if (bop.op == .is_op) return self.lowerIs(bop);
    // Short-circuit: `a and b` → if a then b else false
    if (bop.op == .and_op) {
        const lhs = self.lowerBoolCondition(bop.lhs);
        const rhs_bb = self.freshBlock("and.rhs");
        const merge_bb = self.freshBlockWithParams("and.merge", &.{.bool});
        const false_val = self.builder.constBool(false);
        self.builder.condBr(lhs, rhs_bb, &.{}, merge_bb, &.{false_val});
        self.builder.switchToBlock(rhs_bb);
        const rhs = self.lowerBoolCondition(bop.rhs);
        self.builder.br(merge_bb, &.{rhs});
        self.builder.switchToBlock(merge_bb);
        return self.builder.blockParam(merge_bb, 0, .bool);
    }
    // Short-circuit: `a or b` → if a then true else b
    if (bop.op == .or_op) {
        const lhs = self.lowerBoolCondition(bop.lhs);
        const rhs_bb = self.freshBlock("or.rhs");
        const merge_bb = self.freshBlockWithParams("or.merge", &.{.bool});
        const true_val = self.builder.constBool(true);
        self.builder.condBr(lhs, merge_bb, &.{true_val}, rhs_bb, &.{});
        self.builder.switchToBlock(rhs_bb);
        const rhs = self.lowerBoolCondition(bop.rhs);
        self.builder.br(merge_bb, &.{rhs});
        self.builder.switchToBlock(merge_bb);
        return self.builder.blockParam(merge_bb, 0, .bool);
    }

    // A comparison's value is `bool`; the ambient expected type describes THAT
    // value, never the operands. An operand carrying no type of its own — an
    // `xx` cast is the shape — takes its target from its PEER instead, so
    // `a == xx b` casts `b` to `a`'s type exactly as the hoisted
    // `t : <type of a> = xx b; a == t` does.
    const comparison = switch (bop.op) {
        .eq, .neq, .lt, .lte, .gt, .gte => true,
        else => false,
    };
    const ambient = self.saveTarget();
    if (comparison) {
        self.target_type = null;
        self.cast_reached = null;
    }
    defer if (comparison) ambient.restore();

    // Type-literal comparison fold: when both sides are type-shaped
    // AST nodes (`i64`, `*u8`, `?T`, `[3]f64`, etc.) OR resolve to
    // a static TypeId at lower time (`@typeOf(x)` for any
    // statically-typed `x`), resolve each and emit a `const_bool`.
    // Same semantic as `@typeEq(A, B)` but using the standard `==`
    // operator — the user's intuition. Without the fold, both
    // sides lower as `const_type` undef-i64 and the runtime icmp
    // returns garbage.
    if (bop.op == .eq or bop.op == .neq) {
        if (self.isStaticTypeRef(bop.lhs) and self.isStaticTypeRef(bop.rhs)) {
            const lhs_ty = self.resolveTypeArg(bop.lhs);
            const rhs_ty = self.resolveTypeArg(bop.rhs);
            const eq_result = self.module.types.sameType(lhs_ty, rhs_ty);
            return self.builder.constBool(if (bop.op == .eq) eq_result else !eq_result);
        }
    }

    // `==`/`!=` with an `any` operand is REFUSED (Odin parity: no binary
    // ops are defined on `any`). An `any` is a type-erased BORROW
    // `{tag, data-pointer}` — the only comparable words are the view
    // address (accidental pointer identity) — so there is no meaningful
    // language-level equality. Unbox to a typed value first, or compare
    // `@typeOf(av)` for tag questions.
    if (bop.op == .eq or bop.op == .neq) {
        const lhs_ty = self.inferExprType(bop.lhs);
        const rhs_ty = self.inferExprType(bop.rhs);
        if ((lhs_ty == .any or rhs_ty == .any) and
            lhs_ty != .unresolved and rhs_ty != .unresolved and
            lhs_ty != .void and rhs_ty != .void)
        {
            if (self.diagnostics) |d| {
                d.addFmt(.err, ast.Span{ .start = bop.lhs.span.start, .end = bop.rhs.span.end }, "cannot compare an 'any' value with '{s}': an 'any' is a type-erased borrow, so only its view address could be compared — unbox it first (checked 'av.(T)' or unchecked '@unbox(T, av)'), or compare '@typeOf(av)' against a type", .{if (bop.op == .eq) "==" else "!="});
            }
            return self.builder.constBool(false);
        }
    }

    // Special case: optional == null / optional != null
    if (bop.op == .eq or bop.op == .neq) {
        const lhs_is_null = bop.lhs.data == .null_literal;
        const rhs_is_null = bop.rhs.data == .null_literal;
        if (lhs_is_null or rhs_is_null) {
            const opt_node = if (rhs_is_null) bop.lhs else bop.rhs;
            const opt_ty = self.inferExprType(opt_node);
            if (!opt_ty.isBuiltin()) {
                const info = self.module.types.get(opt_ty);
                if (info == .optional) {
                    const opt_val = self.lowerExpr(opt_node);
                    const has = self.builder.emit(.{ .optional_has_value = .{ .operand = opt_val } }, .bool);
                    // == null → !has_value, != null → has_value
                    return if (bop.op == .eq) self.builder.emit(.{ .bool_not = .{ .operand = has } }, .bool) else has;
                }
            }
        }
    }

    // Error-set equality: an error-set value compares only with a member
    // spelling or another error-set value. Comparing to a raw integer is a
    // type error (coerce with `xx`). `e == .X` resolves X against e's set and
    // validates membership.
    if (bop.op == .eq or bop.op == .neq) {
        if (self.tryLowerErrorSetEquality(bop)) |result| return result;
    }

    // Set target_type for null literals to match the other operand's type.
    // This ensures null gets the same LLVM type as the value being compared.
    if (bop.op == .eq or bop.op == .neq) {
        const null_on_rhs = bop.rhs.data == .null_literal;
        const null_on_lhs = bop.lhs.data == .null_literal;
        if (null_on_rhs or null_on_lhs) {
            var other_ty = if (null_on_rhs) self.inferExprType(bop.lhs) else self.inferExprType(bop.rhs);
            // Lower the non-null side first when its type isn't statically
            // inferable, and take the null's type from the lowered value —
            // never a guess.
            var pre_lowered: ?Ref = null;
            if (other_ty == .unresolved) {
                pre_lowered = self.lowerExpr(if (null_on_rhs) bop.lhs else bop.rhs);
                other_ty = self.builder.getRefType(pre_lowered.?);
            }
            if (other_ty != .void and other_ty != .unresolved) {
                const saved_tt = self.target_type;
                self.target_type = other_ty;
                const lv = if (null_on_lhs or pre_lowered == null) self.lowerExpr(bop.lhs) else pre_lowered.?;
                const rv = if (null_on_rhs or pre_lowered == null) self.lowerExpr(bop.rhs) else pre_lowered.?;
                self.target_type = saved_tt;
                const cmp_op: inst_mod.Op = if (bop.op == .eq) .{ .cmp_eq = .{ .lhs = lv, .rhs = rv } } else .{ .cmp_ne = .{ .lhs = lv, .rhs = rv } };
                return self.builder.emit(cmp_op, .bool);
            }
        }
    }
    if (comparison and self.inferExprType(bop.lhs) == .unresolved) {
        const peer_ty = self.inferExprType(bop.rhs);
        if (peer_ty != .unresolved and peer_ty != .void) self.target_type = peer_ty;
    }
    const float_operands = program_index_mod.floatOperandTypes(bop.*, self.operandType(self.inferExprType(bop.lhs)), self.operandType(self.inferExprType(bop.rhs)), self);
    // An untyped operand of an untyped operation computes in its type; of a
    // typed one, with no typed peer, in `i64`.
    const untyped_ty = untypedOperationType(self, bop);
    const shift = bop.op == .shl or bop.op == .shr;
    const lhs_adopted = self.untypedOperandType(bop.op, bop.lhs, bop.rhs) orelse untyped_ty orelse untypedBesideTyped(self, comparison, bop.lhs, self.inferExprType(bop.rhs));
    const operand_target = self.saveTarget();
    self.reachOperand(node, bop.lhs);
    if (self.isAdaptableFloat(bop.lhs)) self.target_type = float_operands.lhs;
    if (lhs_adopted) |ty| self.target_type = ty;
    var lhs = self.lowerExpr(bop.lhs);
    operand_target.restore();
    if (comparison) self.target_type = null;
    // A `for *x in xs` capture is a pointer; in a value position (here, an
    // operand) it auto-derefs to the element.
    const lhs_ref_pointee = self.refCapturePointee(bop.lhs);
    if (lhs_ref_pointee) |p| lhs = self.builder.load(lhs, p);
    // Set target_type from LHS so enum literals on RHS resolve correctly.
    // When the LHS isn't statically inferable (e.g. `@ObjcCall(...)`), use
    // the lowered operand's concrete type rather than a guess.
    const lhs_ty = blk: {
        if (lhs_ref_pointee) |p| break :blk p;
        if (lhs_adopted) |ty| break :blk ty;
        if (self.isAdaptableFloat(bop.lhs)) break :blk self.builder.getRefType(lhs);
        const it = self.inferExprType(bop.lhs);
        break :blk if (it == .unresolved) self.builder.getRefType(lhs) else it;
    };
    const rhs_untyped = comparison and self.inferExprType(bop.rhs) == .unresolved;
    const saved_target = self.saveTarget();
    const rhs_peer_tt: ?TypeId = peer: {
        if (lhs_ty == .void or lhs_ty == .unresolved) break :peer null;
        if (lhs_ty.isBuiltin()) break :peer if (lhs_ty == .f32 or lhs_ty == .f64 or rhs_untyped) lhs_ty else null;
        const lhs_info = self.module.types.get(lhs_ty);
        if (lhs_info == .@"enum" or lhs_info == .@"union") break :peer lhs_ty;
        // `?T == <rhs>`: type the RHS at the payload so a literal
        // (numeric, enum shorthand, struct) lands on T directly —
        // the mixed compare below needs the concrete side at T.
        if (lhs_info == .optional and (bop.op == .eq or bop.op == .neq)) break :peer lhs_info.optional.child;
        break :peer if (rhs_untyped) lhs_ty else null;
    };
    if (rhs_peer_tt) |ty| self.target_type = ty else self.reachOperand(node, bop.rhs);
    // In a comparison, an anonymous positional literal on the RHS is typed
    // from the LHS just like an enum shorthand. This also keeps the following
    // `{` available as the if body.
    // Against a `?T` LHS the literal types at the payload (mixed compare).
    if (bop.rhs.data == .struct_literal and
        bop.rhs.data.struct_literal.struct_name == null and
        bop.rhs.data.struct_literal.type_expr == null)
    {
        self.target_type = blk: {
            if ((bop.op == .eq or bop.op == .neq) and !lhs_ty.isBuiltin()) {
                const li = self.module.types.get(lhs_ty);
                if (li == .optional) break :blk li.optional.child;
            }
            break :blk lhs_ty;
        };
    }
    if (self.isAdaptableFloat(bop.rhs)) self.target_type = float_operands.rhs;
    const rhs_adopted = self.untypedOperandType(bop.op, bop.rhs, bop.lhs) orelse (if (shift) null else untyped_ty) orelse untypedBesideTyped(self, comparison, bop.rhs, lhs_ty);
    if (rhs_adopted) |ty| self.target_type = ty;
    var rhs = self.lowerExpr(bop.rhs);
    const rhs_ref_pointee = self.refCapturePointee(bop.rhs);
    if (rhs_ref_pointee) |p| rhs = self.builder.load(rhs, p);
    saved_target.restore();
    const rhs_ty = blk: {
        if (rhs_ref_pointee) |p| break :blk p;
        if (rhs_adopted) |ty| break :blk ty;
        if (self.isAdaptableFloat(bop.rhs)) break :blk self.builder.getRefType(rhs);
        const it = self.inferExprType(bop.rhs);
        break :blk if (it == .unresolved) self.builder.getRefType(rhs) else it;
    };
    return lowerBinaryValues(self, bop.op, lhs, lhs_ty, bop.lhs.span, rhs, rhs_ty, bop.rhs.span);
}

fn isPlaceholder(self: *Lowering, ref: Ref) bool {
    const op = self.builder.getRefOp(ref) orelse return false;
    return op == .placeholder;
}

/// A guard-narrowed optional operand's payload: it compares as its payload.
fn narrowedPayload(self: *Lowering, operand: Ref, ty: TypeId) ?struct { ref: Ref, ty: TypeId } {
    if (ty.isBuiltin() or !self.narrowed_refs.contains(operand)) return null;
    const info = self.module.types.get(ty);
    if (info != .optional) return null;
    return .{ .ref = self.builder.emit(.{ .optional_unwrap = .{ .operand = operand } }, info.optional.child), .ty = info.optional.child };
}

/// `lhs op rhs` over operands already lowered.
fn lowerBinaryValues(self: *Lowering, op: ast.BinaryOp.Op, lhs_value: Ref, lhs_ty: TypeId, lhs_span: ast.Span, rhs_value: Ref, rhs_ty: TypeId, rhs_span: ast.Span) Ref {
    // A refused operand already reported its error; the operation over it
    // reports nothing further.
    if (isPlaceholder(self, lhs_value) or isPlaceholder(self, rhs_value)) return self.emitPlaceholder("refused-operand");
    var lhs = lhs_value;
    var rhs = rhs_value;
    // Optional value-equality: `?T == ?T` — equal iff both
    // null or both present with equal payloads — and the mixed `?T == T`,
    // where a null optional is simply unequal. Equality never reads a
    // payload without a presence guard, so the no-implicit-unwrap doctrine
    // (0179/0185) is untouched: arithmetic and ordering on un-narrowed
    // optionals still reject below. Presence tests (`x == null`) returned
    // earlier.
    if (op == .eq or op == .neq) {
        const l_actual = if (lhs_ty == .unresolved) self.builder.getRefType(lhs) else lhs_ty;
        if (narrowedPayload(self, lhs, l_actual)) |p| return lowerBinaryValues(self, op, p.ref, p.ty, lhs_span, rhs, rhs_ty, rhs_span);
        if (narrowedPayload(self, rhs, rhs_ty)) |p| return lowerBinaryValues(self, op, lhs, lhs_ty, lhs_span, p.ref, p.ty, rhs_span);
        const l_opt: ?TypeId = if (!l_actual.isBuiltin() and self.module.types.get(l_actual) == .optional)
            self.module.types.get(l_actual).optional.child
        else
            null;
        const r_opt: ?TypeId = if (!rhs_ty.isBuiltin() and self.module.types.get(rhs_ty) == .optional)
            self.module.types.get(rhs_ty).optional.child
        else
            null;
        if (l_opt != null and r_opt != null) {
            if (l_actual != rhs_ty) {
                if (self.diagnostics) |d| d.addFmt(.err, rhs_span, "cannot compare values of distinct types '{s}' and '{s}'", .{
                    self.formatTypeName(l_actual), self.formatTypeName(rhs_ty),
                });
                return self.emitPlaceholder("distinct-optional-equality");
            }
            const eq = self.lowerOptionalEquality(lhs, rhs, l_opt.?, lhs_span);
            return if (op == .neq) self.builder.emit(.{ .bool_not = .{ .operand = eq } }, .bool) else eq;
        }
        if (l_opt != null or r_opt != null) {
            const inner = l_opt orelse r_opt.?;
            const opt_ref = if (l_opt != null) lhs else rhs;
            var conc = if (l_opt != null) rhs else lhs;
            const conc_ty = if (l_opt != null) rhs_ty else l_actual;
            if (conc_ty != inner) conc = self.coerceToType(conc, conc_ty, inner);
            const eq = self.lowerOptionalMixedEquality(opt_ref, conc, inner, lhs_span);
            return if (op == .neq) self.builder.emit(.{ .bool_not = .{ .operand = eq } }, .bool) else eq;
        }
    }

    var ty = lhs_ty;

    if (self.unwrapOptionalOperand(lhs, ty, lhs_span)) |payload| {
        lhs = payload;
        ty = self.builder.getRefType(payload);
    }
    if (self.unwrapOptionalOperand(rhs, rhs_ty, rhs_span)) |payload| rhs = payload;

    // Sequence value equality: `[N]T`, `[N:X]T`, `[]T`, `[:X]T` and `string`
    // compare CONTENT. The operands need one element type; an array meets the
    // slice, and the lengths answer at run time. A sequence has no comparison
    // with a non-sequence peer.
    if (op == .eq or op == .neq) {
        const l_ty = refTypeOr(self, lhs, ty);
        const r_ty = refTypeOr(self, rhs, rhs_ty);
        const l_elem = sequenceElement(self, l_ty);
        const r_elem = sequenceElement(self, r_ty);
        if (l_elem != null and r_elem != null and self.module.types.sameType(l_elem.?, r_elem.?)) {
            return lowerSequenceEquality(self, lhs, rhs, l_elem.?, op == .eq, lhs_span);
        }
        if (l_elem != null or r_elem != null) {
            if (self.diagnostics) |d| d.addFmt(.err, rhs_span, "cannot compare values of distinct types '{s}' and '{s}'", .{
                self.formatTypeName(l_ty), self.formatTypeName(r_ty),
            });
            return self.emitPlaceholder("distinct-sequence-equality");
        }
    }

    // A `union`'s inactive-variant and padding bytes are unspecified, so it has
    // no value-equality: a byte-wise `icmp` over its `[N x i8]` storage is both
    // wrong and rejected by the LLVM verifier. Reject at lower time, where the
    // span and the named type are available.
    if ((op == .eq or op == .neq) and !ty.isBuiltin()) {
        if (self.module.types.get(ty) == .@"union") {
            if (self.diagnostics) |d| {
                const pid = d.addFmtId(.err, lhs_span, "cannot compare '{s}' values with '{s}'", .{
                    self.formatTypeName(ty), binOpSymbol(op),
                });
                d.addNote(pid, lhs_span, "compare a specific variant field (e.g. `a.field == b.field`)");
            }
            return self.emitPlaceholder("uncomparable-aggregate-eq");
        }
    }

    // Struct value equality. A user `struct` `==` / `!=` is a
    // recursive FIELD-WISE compare — the same element-wise policy the spec
    // already mandates for tuples (which share struct layout), and the only
    // shape that ignores padding bytes (a byte-wise compare would read the
    // unspecified pad between an `i8` and an `i64`). Do it at LOWER time, where
    // each field's TypeId + the operand span are available: emit a per-field
    // `cmp_eq`/`cmp_ne` against the field's OWN type (so a float field gets
    // fcmp, a string field str_eq, a nested struct recurses, a payload enum
    // field tag-compares) and AND-reduce (`==`) / OR-reduce (`!=`). This keeps
    // the `emit_llvm` struct arm (which handles only a 2-scalar-field shape,
    // silently drops fields 2+, and mis-ICMPs non-int fields) from ever seeing
    // a user struct — it sees only the string/slice/payload enum `{ptr,len}` /
    // `{tag,payload}` reductions it is written for.
    // Non-comparable sub-fields (union, fixed array) are rejected with
    // a located diagnostic, consistent with rejecting those shapes bare.
    if ((op == .eq or op == .neq) and !ty.isBuiltin()) {
        const eq_info = self.module.types.get(ty);
        if (eq_info == .@"struct" and !eq_info.@"struct".is_protocol) {
            const other_ty = if (rhs_ty == .unresolved) self.builder.getRefType(rhs) else rhs_ty;
            if (!self.module.types.sameType(other_ty, ty)) {
                if (self.diagnostics) |d| d.addFmt(.err, rhs_span, "cannot compare values of distinct types '{s}' and '{s}'", .{
                    self.formatTypeName(ty), self.formatTypeName(other_ty),
                });
                return self.emitPlaceholder("distinct-struct-equality");
            }
            return self.lowerStructEquality(op, lhs, rhs, ty, lhs_span);
        }
    }

    if (self.diagOperandTypes(op, ty, self.operandType(rhs_ty), lhs_span)) return self.emitPlaceholder("operand-type-mismatch");

    switch (op) {
        .eq, .neq, .lt, .lte, .gt, .gte => {
            const span = ast.Span{ .start = lhs_span.start, .end = rhs_span.end };
            return lowerComparison(self, op, lhs, rhs, span) orelse self.emitPlaceholder("compare-meet");
        },
        else => {
            const span: ast.Span = .{ .start = lhs_span.start, .end = rhs_span.end };
            const met = meetArithOperands(self, op, lhs, ty, rhs, self.operandType(rhs_ty), span) orelse return self.emitPlaceholder("arith-meet");
            lhs = met.lhs;
            rhs = met.rhs;
            ty = met.ty;
        },
    }

    // LLVM's shifts are poison at or past the operand's width, and that poison
    // folds to a different constant in each context that reaches it.
    switch (op) {
        .shl, .shr => {
            if (self.module.types.integerLayout(ty)) |layout| {
                if (constIntOf(self, rhs)) |amount| {
                    const width: i64 = @intCast(layout.width);
                    if (amount < 0 or amount >= width) {
                        if (self.diagnostics) |diags| {
                            const id = diags.addFmtId(.err, rhs_span, "shift amount {d} is out of range for '{s}': valid amounts are 0 to {d}", .{
                                amount, self.formatTypeName(ty), width - 1,
                            });
                            if (amount < 0) {
                                diags.addHelp(id, rhs_span, "a shift amount is never negative", null);
                            } else {
                                diags.addHelpFmt(id, rhs_span, null, "widen the operand to at least {d} bits before shifting", .{amount + 1});
                            }
                        }
                        return self.emitPlaceholder("shift-amount-out-of-range");
                    }
                }
            }
        },
        else => {},
    }

    return switch (op) {
        .add => self.builder.add(lhs, rhs, ty),
        .sub => self.builder.sub(lhs, rhs, ty),
        .mul => self.builder.mul(lhs, rhs, ty),
        .div => self.builder.div(lhs, rhs, ty),
        .mod => self.builder.emit(.{ .mod = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .eq, .neq, .lt, .lte, .gt, .gte => unreachable, // returned by lowerComparison
        .and_op => self.builder.emit(.{ .bool_and = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .or_op => self.builder.emit(.{ .bool_or = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .bit_and => self.builder.emit(.{ .bit_and = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .bit_or => self.builder.emit(.{ .bit_or = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .bit_xor => self.builder.emit(.{ .bit_xor = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .shl => self.builder.emit(.{ .shl = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .shr => self.builder.emit(.{ .shr = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .in_op => self.emitError("in_op", lhs_span),
        .is_op => unreachable, // intercepted at the head of lowerBinaryOp
    };
}

/// Struct value equality: recursive field-wise `==` / `!=`.
///
/// Emits a per-field comparison against each field's OWN type, AND-reduces for
/// `==` (OR-reduces for `!=`), matching the tuple element-wise policy and the
/// natural "two structs are equal iff every field is equal" semantics. Padding
/// bytes are never read (that is exactly why field-wise beats a byte-compare).
///
/// A field with no value-equality of its own — a `union` — is rejected with a
/// located diagnostic, mirroring how that shape is rejected as a bare `==`
/// operand. Every field comparison that DOES get built has its own valid
/// lowering, so `emit_llvm`'s narrow struct arm never sees a user struct.
pub fn lowerStructEquality(self: *Lowering, op: ast.BinaryOp.Op, lhs: Ref, rhs: Ref, ty: TypeId, span: ast.Span) Ref {
    const info = self.module.types.get(ty);
    const fields = info.@"struct".fields;

    // A zero-field struct compares equal to itself (vacuously — no fields to
    // differ). `==` → true, `!=` → false.
    if (fields.len == 0) return self.builder.constBool(op == .eq);

    var result: ?Ref = null;
    var rejected = false;
    for (fields, 0..) |f, i| {
        const lf = self.builder.structGet(lhs, @intCast(i), f.ty);
        const rf = self.builder.structGet(rhs, @intCast(i), f.ty);
        const field_eq = self.lowerFieldEquality(lf, rf, f.ty, span) orelse {
            rejected = true;
            continue; // keep scanning so every bad field is reported at once
        };
        result = if (result) |acc|
            self.builder.emit(.{ .bool_and = .{ .lhs = acc, .rhs = field_eq } }, .bool)
        else
            field_eq;
    }
    // A non-comparable field already emitted a diagnostic; return a placeholder
    // so IR stays well-formed (`hasErrors()` aborts before codegen).
    if (rejected) return self.emitPlaceholder("uncomparable-struct-field-eq");

    const eq_all = result.?; // fields.len > 0 and no rejection ⇒ result is set
    return if (op == .neq)
        self.builder.emit(.{ .bool_not = .{ .operand = eq_all } }, .bool)
    else
        eq_all;
}

/// Build a `bool` Ref for `?T == ?T`: equal iff both null, or both present
/// with `==`-equal payloads (each payload compared by its own type's rule).
/// The payload compare is branch-guarded so a null payload is never read
/// (the interpreter errors on unwrapping null). A non-comparable payload
/// type diagnoses via `lowerFieldEquality` and yields a typed placeholder —
/// `hasErrors()` aborts before codegen, and the CFG stays well-formed.
pub fn lowerOptionalEquality(self: *Lowering, l: Ref, r: Ref, inner_ty: TypeId, span: ast.Span) Ref {
    const ha = self.builder.emit(.{ .optional_has_value = .{ .operand = l } }, .bool);
    const hb = self.builder.emit(.{ .optional_has_value = .{ .operand = r } }, .bool);
    const both = self.builder.emit(.{ .bool_and = .{ .lhs = ha, .rhs = hb } }, .bool);
    const both_bb = self.freshBlock("opteq.both");
    const none_bb = self.freshBlock("opteq.none");
    const merge_bb = self.freshBlockWithParams("opteq.merge", &.{.bool});
    self.builder.condBr(both, both_bb, &.{}, none_bb, &.{});
    self.builder.switchToBlock(both_bb);
    const pl = self.builder.optionalUnwrap(l, inner_ty);
    const pr = self.builder.optionalUnwrap(r, inner_ty);
    const pe = self.lowerFieldEquality(pl, pr, inner_ty, span) orelse self.builder.constBool(false);
    self.builder.br(merge_bb, &.{pe});
    self.builder.switchToBlock(none_bb);
    // Not both present: equal only when both are null.
    const same = self.builder.cmpEq(ha, hb);
    self.builder.br(merge_bb, &.{same});
    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, .bool);
}

/// Build a `bool` Ref for the mixed `?T == T`: a null optional is simply
/// unequal; a present one compares its payload. `conc` must already carry
/// the payload type (callers coerce first).
pub fn lowerOptionalMixedEquality(self: *Lowering, opt: Ref, conc: Ref, inner_ty: TypeId, span: ast.Span) Ref {
    const has = self.builder.emit(.{ .optional_has_value = .{ .operand = opt } }, .bool);
    const not_eq = self.builder.constBool(false);
    const has_bb = self.freshBlock("optmix.has");
    const merge_bb = self.freshBlockWithParams("optmix.merge", &.{.bool});
    self.builder.condBr(has, has_bb, &.{}, merge_bb, &.{not_eq});
    self.builder.switchToBlock(has_bb);
    const pl = self.builder.optionalUnwrap(opt, inner_ty);
    const pe = self.lowerFieldEquality(pl, conc, inner_ty, span) orelse self.builder.constBool(false);
    self.builder.br(merge_bb, &.{pe});
    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, .bool);
}

fn refTypeOr(self: *Lowering, r: Ref, fallback: TypeId) TypeId {
    const t = self.builder.getRefType(r);
    return if (t == .unresolved) fallback else t;
}

/// The element type of a sequence whose `==` compares content — `[N]T`,
/// `[N:X]T`, `[]T`, `[:X]T` — or null for every other type.
fn sequenceElement(self: *Lowering, ty: TypeId) ?TypeId {
    return switch (self.module.types.get(ty)) {
        .array => |a| a.element,
        .slice => |sl| sl.element,
        else => null,
    };
}

/// The `{ptr, len}` reading of a sequence operand: a slice already is one, an
/// array meets it. `[N:X]T` lands on its written N — the terminator is the
/// type's guarantee, not part of the value.
fn sequenceAsSlice(self: *Lowering, v: Ref, elem: TypeId) Ref {
    const ty = self.builder.getRefType(v);
    if (ty.isBuiltin() or self.module.types.get(ty) != .array) return v;
    return self.builder.emit(.{ .array_to_slice = .{ .operand = v } }, self.module.types.sliceOf(elem));
}

/// Build a `bool` Ref for `lhs == rhs` (or `!=`) over two sequences of `elem`:
/// the lengths, then every element through `lowerFieldEquality`. `memcmp`
/// stands in for the loop where an element's bytes are its value.
fn lowerSequenceEquality(self: *Lowering, lhs: Ref, rhs: Ref, elem: TypeId, want_eq: bool, span: ast.Span) Ref {
    const l = sequenceAsSlice(self, lhs, elem);
    const r = sequenceAsSlice(self, rhs, elem);
    if (self.module.types.bytesAreValue(elem)) {
        const size: u32 = @intCast(self.module.types.typeSizeBytes(elem));
        const cmp: inst_mod.SeqCmp = .{ .lhs = l, .rhs = r, .elem_size = size };
        return if (want_eq)
            self.builder.emit(.{ .str_eq = cmp }, .bool)
        else
            self.builder.emit(.{ .str_ne = cmp }, .bool);
    }

    const l_len = self.builder.emit(.{ .length = .{ .operand = l } }, self.module.types.lenTypeOf(self.builder.getRefType(l)));
    const r_len = self.builder.emit(.{ .length = .{ .operand = r } }, self.module.types.lenTypeOf(self.builder.getRefType(r)));
    const len_eq = self.builder.cmpEq(l_len, r_len);

    const head_bb = self.freshBlockWithParams("seqeq.head", &.{.i64});
    const body_bb = self.freshBlock("seqeq.body");
    const merge_bb = self.freshBlockWithParams("seqeq.merge", &.{.bool});
    const zero = self.builder.constInt(0, .i64);
    self.builder.condBr(len_eq, head_bb, &.{zero}, merge_bb, &.{self.builder.constBool(false)});

    self.builder.switchToBlock(head_bb);
    const i = self.builder.blockParam(head_bb, 0, .i64);
    const done = self.builder.cmpEq(i, l_len);
    self.builder.condBr(done, merge_bb, &.{self.builder.constBool(true)}, body_bb, &.{});

    self.builder.switchToBlock(body_bb);
    const le = self.builder.emit(.{ .index_get = .{ .lhs = l, .rhs = i } }, elem);
    const re = self.builder.emit(.{ .index_get = .{ .lhs = r, .rhs = i } }, elem);
    // A rejected element has diagnosed; closing the loop anyway keeps the CFG
    // well-formed until `hasErrors()` aborts.
    const elem_eq = self.lowerFieldEquality(le, re, elem, span) orelse self.builder.constBool(false);
    const next = self.builder.add(i, self.builder.constInt(1, .i64), .i64);
    self.builder.condBr(elem_eq, head_bb, &.{next}, merge_bb, &.{self.builder.constBool(false)});

    self.builder.switchToBlock(merge_bb);
    const all_eq = self.builder.blockParam(merge_bb, 0, .bool);
    return if (want_eq) all_eq else self.builder.emit(.{ .bool_not = .{ .operand = all_eq } }, .bool);
}

/// Build a `bool` Ref for `lf == rf` where both are values of `field_ty`, the
/// per-field step of `lowerStructEquality`. Returns null (after emitting a
/// located diagnostic) for a field type that has no defined value-equality.
pub fn lowerFieldEquality(self: *Lowering, lf: Ref, rf: Ref, field_ty: TypeId, span: ast.Span) ?Ref {
    if (sequenceElement(self, field_ty)) |elem| return lowerSequenceEquality(self, lf, rf, elem, true, span);

    // Builtins (ints, floats, bool, pointers, enums-as-int, usize/isize) and
    // every `@int(N, ...)`: a plain `cmp_eq`. The LLVM emitter picks fcmp for a
    // float operand and icmp otherwise off the operand's own type, so f32/f64
    // fields get the correct ordered-equal compare with no special-casing here.
    if (field_ty.isBuiltin() or self.module.types.isIntegerType(field_ty)) return self.builder.cmpEq(lf, rf);

    const fi = self.module.types.get(field_ty);
    return switch (fi) {
        // Nested aggregate: recurse field-wise. Tuples share struct layout, so
        // the same per-index walk applies.
        .@"struct" => blk: {
            if (fi.@"struct".is_protocol) break :blk self.builder.cmpEq(lf, rf); // fat-ptr identity
            const nested_fields = fi.@"struct".fields;
            if (nested_fields.len == 0) break :blk self.builder.constBool(true);
            var acc: ?Ref = null;
            var bad = false;
            for (nested_fields, 0..) |nf, j| {
                const nlf = self.builder.structGet(lf, @intCast(j), nf.ty);
                const nrf = self.builder.structGet(rf, @intCast(j), nf.ty);
                const sub = self.lowerFieldEquality(nlf, nrf, nf.ty, span) orelse {
                    bad = true;
                    continue;
                };
                acc = if (acc) |a| self.builder.emit(.{ .bool_and = .{ .lhs = a, .rhs = sub } }, .bool) else sub;
            }
            if (bad) break :blk null;
            break :blk acc.?;
        },
        // Enum and pointers-by-info: scalar identity; a payload-carrying enum
        // compares its tag only (emit_llvm's tag-only arm).
        .@"enum", .pointer, .many_pointer => self.builder.cmpEq(lf, rf),
        // Optional field: both-null equal, one-null unequal, both-present →
        // payload compare — the same rule as bare `?T == ?T`.
        .optional => self.lowerOptionalEquality(lf, rf, fi.optional.child, span),
        .@"union" => blk: {
            if (self.diagnostics) |d| {
                const pid = d.addFmtId(.err, span, "cannot compare: '{s}' has no value-equality", .{
                    self.formatTypeName(field_ty),
                });
                d.addNote(pid, span, "compare a specific variant field");
            }
            break :blk null;
        },
        // Any other aggregate field (vector, closure, function, pack, `any`,
        // etc.) has no defined struct-field value-equality — reject loudly with
        // a located diagnostic rather than emit invalid IR or a silent partial
        // compare. (A bare vector `==`, for instance, produces an element-wise
        // vector-of-bool, not a scalar; comparing one as a struct field would be
        // ill-defined.)
        else => blk: {
            if (self.diagnostics) |d| {
                d.addFmt(.err, span, "cannot compare: '{s}' has no value-equality", .{
                    self.formatTypeName(field_ty),
                });
            }
            break :blk null;
        },
    };
}

// ── Chained comparison ──────────────────────────────────────────

pub fn lowerChainedComparison(self: *Lowering, cc: *const ast.ChainedComparison) Ref {
    // a < b < c → (a < b) and (b < c)
    // Pre-lower all operands so shared ones (e.g., b) aren't evaluated twice.
    if (cc.operands.len < 2 or cc.ops.len == 0) {
        return self.builder.constBool(true);
    }

    // The chain's value is `bool`; the ambient expected type describes THAT
    // value, never the operands. An operand carrying no type of its own — an
    // `xx` cast is the shape — takes its target from a neighboring operand.
    const ambient_tt = self.target_type;
    self.target_type = null;
    defer self.target_type = ambient_tt;
    var refs = std.ArrayList(Ref).empty;
    defer refs.deinit(self.alloc);
    for (cc.operands, 0..) |op, i| {
        if (isUntypedInteger(self, op)) {
            if (untypedChainPeer(self, cc.operands, i)) |p| self.target_type = p;
        } else if (self.inferExprType(op) == .unresolved) {
            var peer: ?TypeId = null;
            if (i > 0) {
                const prev = self.inferExprType(cc.operands[i - 1]);
                if (prev != .unresolved and prev != .void) peer = prev;
            }
            if (peer == null) {
                for (cc.operands[i + 1 ..]) |later_op| {
                    const later = self.inferExprType(later_op);
                    if (later != .unresolved and later != .void) {
                        peer = later;
                        break;
                    }
                }
            }
            if (peer == null and i > 0) {
                const prev_ty = self.builder.getRefType(refs.items[i - 1]);
                if (prev_ty != .unresolved and prev_ty != .void) peer = prev_ty;
            }
            if (peer) |p| self.target_type = p;
        }
        var ref = self.lowerExpr(op);
        if (self.refCapturePointee(op)) |p| ref = self.builder.load(ref, p);
        refs.append(self.alloc, ref) catch unreachable;
        self.target_type = null;
    }

    var result: ?Ref = null;
    for (cc.ops, 0..) |cmp_op, i| {
        const lhs = refs.items[i];
        const rhs = refs.items[i + 1];
        const cmp = lowerBinaryValues(self, cmp_op, lhs, self.builder.getRefType(lhs), cc.operands[i].span, rhs, self.builder.getRefType(rhs), cc.operands[i + 1].span);
        result = if (result) |acc| self.builder.emit(.{ .bool_and = .{ .lhs = acc, .rhs = cmp } }, .bool) else cmp;
    }
    return result.?;
}

fn isUntypedInteger(self: *Lowering, node: *const Node) bool {
    const kind = program_index_mod.untypedConst(node, self) orelse return false;
    return kind == .integer;
}

/// The type an untyped integer operand of a chain takes: a typed neighbor's,
/// the left one first.
fn untypedChainPeer(self: *Lowering, operands: []const *Node, i: usize) ?TypeId {
    const neighbors = [_]?*const Node{
        if (i > 0) operands[i - 1] else null,
        if (i + 1 < operands.len) operands[i + 1] else null,
    };
    for (neighbors) |neighbor| {
        const n = neighbor orelse continue;
        if (isUntypedInteger(self, n)) continue;
        if (comparePeerType(self, self.inferExprType(n))) |ty| return ty;
    }
    return null;
}

/// The type an untyped integer compared with a peer of `peer_ty` takes: the
/// peer's numeric type, seen through `?` — `n == 0` with `n: ?usize` is a
/// usize compare, not signed-vs-unsigned.
fn comparePeerType(self: *Lowering, peer_ty: TypeId) ?TypeId {
    return self.integerContext(peer_ty) orelse self.floatContext(peer_ty);
}

/// The type an untyped integer `operand` takes beside a typed peer of
/// `peer_ty` that does not adopt it: compared, the peer's; otherwise `i64`.
fn untypedBesideTyped(self: *Lowering, comparison: bool, operand: *const Node, peer_ty: TypeId) ?TypeId {
    if (!isUntypedInteger(self, operand)) return null;
    return if (comparison) comparePeerType(self, peer_ty) else .i64;
}

fn constIntOf(self: *Lowering, val: Ref) ?i64 {
    const op = self.builder.getRefOp(val) orelse return null;
    return switch (op) {
        .const_int => |v| v,
        .neg => |n| blk: {
            const inner = constIntOf(self, n.operand) orelse break :blk null;
            break :blk -%inner;
        },
        else => null,
    };
}

/// `lhs op rhs` for a comparison `op`, or null once refused at `span`.
fn lowerComparison(self: *Lowering, op: ast.BinaryOp.Op, lhs: Ref, rhs: Ref, span: ast.Span) ?Ref {
    const lhs_ty = self.builder.getRefType(lhs);
    const rhs_ty = self.builder.getRefType(rhs);
    switch (self.coercionResolver().classifyCompare(lhs_ty, rhs_ty)) {
        .type => |meet_ty| {
            const l = coerceCompareOperand(self, lhs, lhs_ty, meet_ty);
            const r = coerceCompareOperand(self, rhs, rhs_ty, meet_ty);
            return compareValues(self, op, l, r);
        },
        .incompatible => {
            if (self.diagnostics) |d| {
                d.addFmt(.err, span, "cannot compare values of type '{s}' and '{s}'", .{ self.formatTypeName(lhs_ty), self.formatTypeName(rhs_ty) });
            }
            return null;
        },
        .signedness => {
            if (self.foldedInt(lhs)) |n| return compareWithConstant(self, op, n, lhs_ty, rhs, rhs_ty, true);
            if (self.foldedInt(rhs)) |n| return compareWithConstant(self, op, n, rhs_ty, lhs, lhs_ty, false);
            return compareOppositeSignedness(self, op, lhs, lhs_ty, rhs, rhs_ty);
        },
        .bool_number => {
            if (self.diagnostics) |d| {
                d.addFmt(.err, span, "cannot compare values of type '{s}' and '{s}'; use an explicit cast (`.({s})`)", .{
                    self.formatTypeName(lhs_ty), self.formatTypeName(rhs_ty), self.formatTypeName(if (lhs_ty == .bool) rhs_ty else lhs_ty),
                });
            }
            return null;
        },
        .none => {
            const l_proto = self.getProtocolInfo(lhs_ty) != null;
            const r_proto = self.getProtocolInfo(rhs_ty) != null;
            if (l_proto or r_proto) {
                if (self.diagnostics) |d| {
                    const other = if (l_proto) rhs_ty else lhs_ty;
                    d.addFmt(.err, span, "cannot compare a handle with '{s}'", .{self.formatTypeName(other)});
                }
                return null;
            }
            return compareValues(self, op, lhs, rhs);
        },
    }
}

fn compareValues(self: *Lowering, op: ast.BinaryOp.Op, lhs: Ref, rhs: Ref) Ref {
    return switch (op) {
        .eq => self.builder.cmpEq(lhs, rhs),
        .neq => self.builder.emit(.{ .cmp_ne = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .lt => self.builder.cmpLt(lhs, rhs),
        .lte => self.builder.emit(.{ .cmp_le = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .gt => self.builder.cmpGt(lhs, rhs),
        .gte => self.builder.emit(.{ .cmp_ge = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        else => unreachable,
    };
}

/// `lhs op rhs` for operands known to differ, `lhs_less` telling which is less.
fn unequalAnswer(op: ast.BinaryOp.Op, lhs_less: bool) bool {
    return switch (op) {
        .eq => false,
        .neq => true,
        .lt, .lte => lhs_less,
        .gt, .gte => !lhs_less,
        else => unreachable,
    };
}

/// Integers of opposite signedness with no common type compare exactly: a
/// negative signed operand is less than every unsigned value, and otherwise
/// both compare as the unsigned type, which is at least as wide.
fn compareOppositeSignedness(self: *Lowering, op: ast.BinaryOp.Op, lhs: Ref, lhs_ty: TypeId, rhs: Ref, rhs_ty: TypeId) Ref {
    const signed_left = !self.module.types.isUnsignedInt(lhs_ty);
    const signed = if (signed_left) lhs else rhs;
    const signed_ty = if (signed_left) lhs_ty else rhs_ty;
    const as_unsigned = self.coerceExplicit(signed, signed_ty, if (signed_left) rhs_ty else lhs_ty);
    const unsigned_cmp = if (signed_left) compareValues(self, op, as_unsigned, rhs) else compareValues(self, op, lhs, as_unsigned);
    const zero = self.builder.constInt(0, signed_ty);
    if (unequalAnswer(op, signed_left)) {
        const negative = self.builder.cmpLt(signed, zero);
        return self.builder.emit(.{ .bool_or = .{ .lhs = negative, .rhs = unsigned_cmp } }, .bool);
    }
    const non_negative = self.builder.emit(.{ .cmp_ge = .{ .lhs = signed, .rhs = zero } }, .bool);
    return self.builder.emit(.{ .bool_and = .{ .lhs = non_negative, .rhs = unsigned_cmp } }, .bool);
}

/// `compareOppositeSignedness` with the constant `n` of type `n_ty` on one
/// side: inside the range of `other_ty` it compares as an `other_ty`, and
/// outside it lies below or above every `other_ty` value.
fn compareWithConstant(self: *Lowering, op: ast.BinaryOp.Op, n: i64, n_ty: TypeId, other: Ref, other_ty: TypeId, constant_left: bool) Ref {
    const value = self.intConstantValue(n, n_ty);
    const range = self.intLiteralRange(other_ty).?;
    if (value < range.min or value > range.max) {
        return self.builder.constBool(unequalAnswer(op, constant_left == (value < range.min)));
    }
    const constant = self.builder.constInt(n, other_ty);
    return if (constant_left) compareValues(self, op, constant, other) else compareValues(self, op, other, constant);
}

pub const ArithOperands = struct { lhs: Ref, rhs: Ref, ty: TypeId };

/// The operands of `lhs op rhs` converted to their common type, or null once
/// refused at `span`. A shift converts only its left operand.
pub fn meetArithOperands(self: *Lowering, op: ast.BinaryOp.Op, lhs: Ref, lhs_ty: TypeId, rhs: Ref, rhs_ty: TypeId, span: ast.Span) ?ArithOperands {
    const ty = switch (self.arithResultType(op, lhs_ty, rhs_ty)) {
        .type => |result_ty| result_ty,
        .signedness => {
            if (self.diagnostics) |d| d.addFmt(.err, span, "cannot apply '{s}' to signed and unsigned values of type '{s}' and '{s}'; write an explicit cast on one side", .{
                binOpSymbol(op), self.formatTypeName(lhs_ty), self.formatTypeName(rhs_ty),
            });
            return null;
        },
        .lane => {
            if (self.diagnostics) |d| d.addFmt(.err, span, "cannot apply '{s}' to '{s}' and '{s}': the scalar does not convert implicitly to the vector's lane type; write an explicit cast", .{
                binOpSymbol(op), self.formatTypeName(lhs_ty), self.formatTypeName(rhs_ty),
            });
            return null;
        },
    };
    const shift = op == .shl or op == .shr;
    return .{ .lhs = convertArithOperand(self, lhs, ty), .rhs = if (shift) rhs else convertArithOperand(self, rhs, ty), .ty = ty };
}

/// The type an untyped integer operation computes in: an integer destination's
/// type, else `i64`.
fn untypedOperationType(self: *Lowering, bop: *const ast.BinaryOp) ?TypeId {
    const kind = program_index_mod.untypedBinary(bop.*, self) orelse return null;
    if (kind != .integer) return null;
    return self.integerContext(self.target_type) orelse .i64;
}

/// A numeric scalar operand converts to its operation's type, or beside a
/// vector to the lane type, which emission splats.
fn convertArithOperand(self: *Lowering, val: Ref, ty: TypeId) Ref {
    const src_ty = self.builder.getRefType(val);
    const dst_ty = if (self.isVectorType(ty)) self.module.types.get(ty).vector.element else ty;
    const coercions = self.coercionResolver();
    if (src_ty == dst_ty or !coercions.isNumericScalar(src_ty) or !coercions.isNumericScalar(dst_ty)) return val;
    return self.coerceToType(val, src_ty, dst_ty);
}

fn coerceCompareOperand(self: *Lowering, val: Ref, src_ty: TypeId, dst_ty: TypeId) Ref {
    if (src_ty == dst_ty) return val;
    return self.coerceToType(val, src_ty, dst_ty);
}
