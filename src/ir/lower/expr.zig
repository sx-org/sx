const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const mod_mod = @import("../module.zig");
const type_bridge = @import("../type_bridge.zig");
const program_index_mod = @import("../program_index.zig");
const unescape = @import("../../unescape.zig");
const errors = @import("../../errors.zig");
const TypeResolver = @import("../type_resolver.zig").TypeResolver;

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
const arithResultType = Lowering.arithResultType;
const exprIsFailable = Lowering.exprIsFailable;
const headNameOfCallee = Lowering.headNameOfCallee;
const StructConstInfo = Lowering.StructConstInfo;

pub fn lowerStructLiteral(self: *Lowering, sl: *const ast.StructLiteral, span: ast.Span) Ref {
    // Check for tagged enum construction: .Variant.{ payload_fields }
    // This happens when type_expr is an enum_literal and target_type is a union
    if (sl.type_expr) |te| {
        if (te.data == .enum_literal) {
            const variant_name = te.data.enum_literal.name;
            const union_ty = self.target_type orelse .unresolved;
            if (!union_ty.isBuiltin()) {
                const union_info = self.module.types.get(union_ty);
                if (union_info == .tagged_union) {
                    return self.lowerTaggedEnumLiteral(sl, variant_name, union_ty, union_info.tagged_union, span);
                }
            }
        }
        // Qualified variant construction: `Ev.key.{ ... }`. Here `type_expr`
        // is a field_access (`Ev.key`), not an `enum_literal` — `Ev` names the
        // tagged union and `key` the variant. Route it through the same path
        // as the inferred `.key.{ ... }` form (issue 0281); without this the
        // field_access falls to `resolveTypeWithBindings`, which cannot place
        // `Ev.key` in type position and returns `.unresolved` → LLVM panic.
        if (te.data == .field_access) {
            const fa = te.data.field_access;
            const obj_name: ?[]const u8 = switch (fa.object.data) {
                .identifier => |id| id.name,
                .type_expr => |t| t.name,
                else => null,
            };
            if (obj_name) |on| {
                const resolved = self.resolveNominalLeaf(on, false, fa.object.span);
                if (!resolved.isBuiltin() and resolved != .unresolved) {
                    const info = self.module.types.get(resolved);
                    if (info == .tagged_union) {
                        return self.lowerTaggedEnumLiteral(sl, fa.field, resolved, info.tagged_union, span);
                    }
                }
            }
        }
    }

    // `.{ name = ... }` against a tagged-union target_type. Reject:
    // the only valid construction forms are `.variant(payload)` and
    // `.variant.{ field, ... }`. Falling through would lower the
    // user's values straight into the `(tag, payload_bytes)` slot
    // pair and emit IR that LLVM later rejects.
    if (sl.type_expr == null and sl.struct_name == null) {
        const tu_ty = self.target_type orelse .unresolved;
        if (!tu_ty.isBuiltin()) {
            const tu_info = self.module.types.get(tu_ty);
            if (tu_info == .tagged_union) {
                if (sl.field_inits.len > 0 and sl.field_inits[0].name != null) {
                    const first_name = sl.field_inits[0].name.?;
                    if (self.diagnostics) |diags| {
                        const ty_name = self.formatTypeName(tu_ty);
                        if (self.findTaggedVariant(tu_info.tagged_union, first_name) != null) {
                            diags.addFmt(
                                .err,
                                span,
                                "cannot construct tagged union '{s}' from `.{{ {s} = ... }}`; use `.{s}(...)` or `.{s}.{{ ... }}`",
                                .{ ty_name, first_name, first_name, first_name },
                            );
                        } else {
                            self.emitBadVariant(tu_ty, tu_info.tagged_union, first_name, span);
                        }
                    }
                    return self.builder.enumInit(0, Ref.none, tu_ty);
                }
            }
        }
    }

    const ty: TypeId = if (sl.struct_name) |name|
        // Source-aware (E2): a bare struct-literal type name resolves to the
        // querying source's OWN same-name author, not the global `findByName`
        // first-match — so `Box.{...}` in module B builds B's `Box`, never a
        // flat-imported A's. `.undeclared`/`.pending` keep the empty-struct
        // stub (byte-identical to the legacy `findByName orelse intern`);
        // `.ambiguous`/`.not_visible` surface their loud diagnostic + poison.
        self.resolveNominalLeaf(name, false, span)
    else if (sl.type_expr) |te|
        // Generic struct literal: Pair(i32).{ ... } — resolve type from type_expr
        self.resolveTypeWithBindings(te)
    else
        self.target_type orelse .unresolved;

    // Plain (untagged) union target: build by writing each named member into a
    // union-sized slot. `getStructFields` returns empty for a union, so the
    // generic struct path below would emit a malformed `structInit` whose
    // overlapping zero-fill clobbers the named member (issue 0158). Tagged
    // unions were already handled above.
    if (!ty.isBuiltin() and self.module.types.get(ty) == .@"union") {
        return self.lowerUnionLiteral(sl, ty, span);
    }

    // A bare struct literal against an optional target `?T` builds the INNER
    // `T` and wraps it once. Without this `ty` is the optional itself, so the
    // literal is lowered into the optional's `{payload, has_value}` layout and
    // then re-wrapped — corrupting the value (a `?T` arg silently reads as
    // null) or failing LLVM verification on the double wrap (issue 0160).
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
        // don't re-coerce (issue 0160).
        const saved_tt = self.target_type;
        self.target_type = child;
        const inner = self.lowerStructLiteral(sl, span);
        self.target_type = saved_tt;
        const slot = self.builder.alloca(child);
        self.builder.store(slot, inner);
        const reloaded = self.builder.load(slot, child);
        return self.coerceToType(reloaded, child, ty);
    }

    // No inferable target at all (`t := .{ 1, 2, 3 };` — `ty` stayed
    // `.unresolved`): the literal's type can never be resolved, and an
    // `.unresolved`-typed `struct_init` flows to codegen and panics LLVM
    // emission ("unresolved type reached LLVM emission"), with no
    // diagnostic (issue 0184). Diagnose at the literal site and return an
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
                return self.synthesizeAnonStruct(sl, span);
            }
            if (self.diagnostics) |d| {
                if (!d.hasErrors())
                    d.addFmt(.err, span, "cannot infer the type of this '.{{ }}' literal — annotate the binding or provide a target type", .{});
            }
        }
        return self.builder.constUndef(.unresolved);
    }

    // A `.{ ... }` literal can only build an AGGREGATE. After the
    // tagged-union / union / optional intercepts above, the named and
    // positional paths below handle exactly: struct, tuple, array, vector,
    // the two {ptr, len} fat pointers — a slice (`sl : []T = .{ ptr = …,
    // len = … }`, used throughout the stdlib/corpus) and the builtin `string`
    // (`string.{ ptr = …, len = … }` in fmt/hash/cli/sqlite) — and a closure
    // (`c : Closure(i32) -> i32 = .{ fn_ptr = …, env = … }`, the {fn_ptr, env}
    // pair, exercised by examples/types/0129).
    // Any other resolved target — a scalar builtin (`x : i64 = .{ a = 1 }`),
    // an enum, a pointer, ... — would reach `structInit` against a
    // non-aggregate LLVM type: a non-empty literal fails LLVM verification
    // (`Invalid InsertValueInst operands!`), and the empty `.{}` silently
    // produces garbage (issue 0161). Diagnose and return a typed zero
    // placeholder — the diagnostic aborts the build before codegen; the
    // placeholder only keeps the remaining lowering coherent.
    // A TUPLE-targeted bare `.{ … }` routes through the tuple-literal
    // machinery for the shapes the positional struct path can't do:
    // spreads (`c.sources = .{..sources}`, `t : Tuple(..xs.T) = .{..xs.get}`)
    // and arity MISMATCHES (a 2-element literal against a 3-field failable
    // tuple must self-type as its own 2-tuple — adopting the full target
    // would leave the error slot uninitialized). An exact-arity literal
    // keeps the struct-literal path below, which owns void-slot skipping
    // and named-against-tuple-names resolution.
    if (sl.struct_name == null and sl.type_expr == null and !ty.isBuiltin() and self.module.types.get(ty) == .tuple) {
        var has_spread = false;
        for (sl.field_inits) |fi| {
            if (fi.value.data == .spread_expr) has_spread = true;
        }
        if (has_spread or sl.field_inits.len != self.module.types.get(ty).tuple.fields.len) {
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

    const aggregate_ok = if (ty.isBuiltin())
        ty == .string
    else switch (self.module.types.get(ty)) {
        .@"struct", .tuple, .array, .vector, .slice, .closure => true,
        else => false,
    };
    if (!aggregate_ok) {
        // TypeTable.formatTypeName (not Lowering's) — the latter falls back
        // to `@tagName` for function / error-set / protocol types, leaking
        // internal spellings ('function', 'error_set') into the message.
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "cannot build a struct literal for non-struct type '{s}'", .{self.module.types.formatTypeName(self.alloc, ty)});
        return self.zeroValue(ty);
    }

    // Get struct field types for coercion and ordering
    const struct_fields = self.getStructFields(ty);

    // Look up field defaults from AST
    const struct_name_for_defaults = if (sl.struct_name) |n| n else if (!ty.isBuiltin()) blk: {
        const ti = self.module.types.get(ty);
        break :blk if (ti == .@"struct") self.module.types.getString(ti.@"struct".name) else @as(?[]const u8, null);
    } else @as(?[]const u8, null);
    const field_defaults: []const ?*const Node = if (struct_name_for_defaults) |sn|
        (self.struct_defaults_map.get(sn) orelse &.{})
    else
        &.{};

    // A generic instance's defaults may REFERENCE its type params — `sz: i64 =
    // size_of(T)` (issue 0221, dependent defaults). Those default AST nodes
    // are monomorphized here: while lowering a missing field's default we
    // temporarily install this instance's captured `type_bindings` (stamped by
    // `instantiateGenericStruct` into `struct_instance_bindings`, keyed by the
    // instance's mangled struct name — or the ALIAS name for `BI :: Box(i64)`,
    // which mirrors the instance's bindings) so `T` resolves to the concrete
    // arg for THIS instantiation. Only a non-generic struct has no entry —
    // `default_bindings` stays null and the default lowers in the ambient
    // (empty) binding context, exactly as before.
    const default_bindings: ?std.StringHashMap(TypeId) =
        if (struct_name_for_defaults) |sn| self.struct_instance_bindings.get(sn) else null;

    // Check if any field_init has a name (named literal).
    //
    // The parser PUNS a bare identifier element `.{ x, ... }` into a named
    // field `x = x` (the shorthand `Vec4.{ w, z }` form, specs §Struct
    // Literals), because it cannot know — without the struct definition —
    // whether `x` names a field or is a positional value. A POSITIONAL literal
    // whose first element is a bare variable (`.{ x, 2 }`, `x` not a field of
    // the target) therefore arrives here as `[name=x][name=null]` — a spurious
    // mix that the named branch below mis-reorders (the unmatched punned name
    // leaves every real field at its default, zeroing the value — issue 0175).
    //
    // Disambiguate using the struct definition we now have: a punned bare-ident
    // field whose name does NOT match any declared field is not a real named
    // field — it is a positional element the parser over-eagerly named. If ANY
    // such non-field punned name is present, treat the whole literal as
    // positional (the only consistent reading: a true named literal names only
    // real fields). An explicit `name = expr` (value ≠ bare ident of same name)
    // that misses a field is still a genuine — and erroneous — named field, so
    // it is NOT reclassified here.
    const has_names = blk: {
        if (sl.field_inits.len == 0 or sl.field_inits[0].name == null) break :blk false;
        if (struct_fields.len > 0) {
            for (sl.field_inits) |fi| {
                const fname = fi.name orelse continue;
                const is_punned = fi.value.data == .identifier and
                    std.mem.eql(u8, fi.value.data.identifier.name, fname);
                if (!is_punned) continue;
                var matches_field = false;
                for (struct_fields) |sf| {
                    if (std.mem.eql(u8, self.module.types.getString(sf.name), fname)) {
                        matches_field = true;
                        break;
                    }
                }
                // A punned name that is not a field name → this was a positional
                // element the parser named; the literal is positional.
                if (!matches_field) break :blk false;
            }
        }
        break :blk true;
    };

    if (has_names and struct_fields.len > 0) {
        // Named literal: reorder fields to match struct declaration order
        // First, lower all field values in source order (to preserve evaluation order)
        var lowered = std.ArrayList(struct { val: Ref, name: []const u8, node: *const Node }).empty;
        defer lowered.deinit(self.alloc);
        for (sl.field_inits) |fi| {
            const saved_tt = self.target_type;
            // Set target_type to the field's declared type so array literals
            // know if the target is a vector, etc.
            if (fi.name) |fname| {
                var matched = false;
                for (struct_fields) |sf| {
                    if (std.mem.eql(u8, self.module.types.getString(sf.name), fname)) {
                        self.target_type = sf.ty;
                        matched = true;
                        break;
                    }
                }
                // An explicit `name = expr` naming no real field is an error —
                // not silently dropped. (A punned bare-ident that misses a field
                // was already reclassified as positional by `has_names` above, so
                // anything unmatched here is a genuine, mistaken named field — a
                // typo or a field removed by an `inline if OS` branch.)
                if (!matched) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, fi.value.span, "field '{s}' not found on type '{s}'", .{ fname, self.formatTypeName(ty) });
                }
            }
            const val = self.lowerExpr(fi.value);
            self.target_type = saved_tt;
            lowered.append(self.alloc, .{
                .val = val,
                .name = fi.name orelse "",
                .node = fi.value,
            }) catch unreachable;
        }

        // Build fields in declaration order
        var fields = std.ArrayList(Ref).empty;
        defer fields.deinit(self.alloc);
        for (struct_fields, 0..) |sf, fi| {
            const sf_name = self.module.types.getString(sf.name);
            // Find the matching lowered value
            var found = false;
            for (lowered.items) |l| {
                if (std.mem.eql(u8, l.name, sf_name)) {
                    var val = l.val;
                    const src_ty = self.builder.getRefType(val);
                    // An #identity protocol field erases NODE-AWARE, so an
                    // lvalue initializer BORROWS (`.{ allocator = gpa }`
                    // aliases `gpa`) — the node-less path would misread the
                    // lvalue as an rvalue and refuse. value/own protocol
                    // fields keep the node-less OWNING copy: the literal may
                    // escape the frame (0401 pins the List-append case), so
                    // a borrow would dangle.
                    const dst_pi = self.getProtocolInfo(sf.ty);
                    val = if (dst_pi != null and dst_pi.?.ownership == .identity)
                        self.coerceOrErase(val, src_ty, sf.ty, l.node)
                    else
                        self.coerceToType(val, src_ty, sf.ty);
                    fields.append(self.alloc, val) catch unreachable;
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Field not specified — use default if available, else zero
                if (fi < field_defaults.len) {
                    if (field_defaults[fi]) |default_expr| {
                        // Coerce the default to the field type at the IR
                        // level (the implicit narrowing rule) so a float
                        // default folds/errors here instead of being
                        // silently bit-coerced by the backend. A generic
                        // instance's default may reference a type param —
                        // lower it with this instance's bindings (issue 0221).
                        fields.append(self.alloc, self.lowerDefaultWithBindings(default_expr, sf.ty, default_bindings)) catch unreachable;
                    } else {
                        fields.append(self.alloc, self.zeroValue(sf.ty)) catch unreachable;
                    }
                } else {
                    fields.append(self.alloc, self.zeroValue(sf.ty)) catch unreachable;
                }
            }
        }

        const result = self.builder.structInit(fields.items, ty);
        if (sl.init_block) |ib| {
            return self.lowerInitBlock(result, ty, ib);
        }
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
    // indexing it segfaults). Issue 0168. `coerceToType` is a no-op when the
    // element already matches (the common `[N]i64`/`[N]Struct` case).
    const array_elem_ty: TypeId = if (!ty.isBuiltin()) switch (self.module.types.get(ty)) {
        .array, .vector => self.getElementType(ty),
        else => .unresolved,
    } else .unresolved;

    // A TUPLE target `(T0, T1, …)` is neither a struct (so `struct_fields` is
    // empty) nor an array/vector (so `array_elem_ty` is `.unresolved`) — yet a
    // positional `.{ a, b }` against it must still coerce element `i` to the
    // tuple's per-position field type, exactly as a struct positional element
    // is coerced to `struct_fields[i].ty`. Without this a bare element flows
    // into the field slot with the wrong shape (e.g. a bare `i64` into a
    // `{i64,i1}` optional slot — the present optional reads back as absent).
    // Issue 0174. `TupleInfo.fields[i]` is the i-th tuple field type.
    const tuple_fields: []const TypeId = if (!ty.isBuiltin()) switch (self.module.types.get(ty)) {
        .tuple => |t| t.fields,
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
        else if (i < tuple_fields.len)
            tuple_fields[i]
        else
            array_elem_ty;
        if (elem_target != .unresolved) self.target_type = elem_target;
        var val = self.lowerExpr(fi.value);
        self.target_type = saved_tt;
        // Coerce field value to match the destination field/element type.
        // Coerce from the value's ACTUAL lowered type (`getRefType`) rather
        // than a re-inferred source type: a re-inference of a punned positional
        // identifier (`.{ x, … }`, parser-named `x = x`) could disagree with
        // the SSA value's real type and mis-narrow it. The lowered ref's type
        // is authoritative (issue 0175).
        if (elem_target != .unresolved) {
            const src_ty = self.builder.getRefType(val);
            if (src_ty != elem_target) {
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
                    fields.append(self.alloc, self.lowerDefaultWithBindings(default_expr, sf.ty, default_bindings)) catch unreachable;
                    continue;
                }
            }
            fields.append(self.alloc, self.zeroValue(sf.ty)) catch unreachable;
        }
    }

    const result = self.builder.structInit(fields.items, ty);

    // Lower init block if present
    if (sl.init_block) |ib| {
        return self.lowerInitBlock(result, ty, ib);
    }

    return result;
}

/// Lower an init block: store struct value to alloca, bind `self`, execute block, reload.
pub fn lowerInitBlock(self: *Lowering, struct_val: Ref, ty: TypeId, ib: *const Node) Ref {
    // Store struct value to a temporary alloca
    const ptr_ty = self.module.types.ptrTo(ty);
    const slot = self.builder.alloca(ty);
    self.builder.store(slot, struct_val);

    // Create a nested scope with `self` bound to the alloca pointer
    var init_scope = Scope.init(self.alloc, self.scope);
    defer init_scope.deinit();
    const saved_scope = self.scope;
    self.scope = &init_scope;

    // `self` is the pointer to the struct (not an alloca itself — it IS the pointer value)
    init_scope.put("self", .{ .ref = slot, .ty = ptr_ty, .is_alloca = false });

    // Lower the init block body
    self.lowerBlock(ib);

    // Restore scope
    self.scope = saved_scope;

    // Load and return the (possibly modified) struct value
    return self.builder.load(slot, ty);
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

/// If a method's first param expects a pointer (*T) but we're passing T by value,
/// swap the first arg with the alloca address (implicit address-of).
pub fn fixupMethodReceiver(self: *Lowering, method_args: *std.ArrayList(Ref), func: *const Function, obj_node: *const Node, obj_ty: TypeId) void {
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
            // Method expects *T — pass the address of the receiver (value type in alloca)
            if (obj_node.data == .identifier) {
                const nm = obj_node.data.identifier.name;
                const local = if (self.scope) |scope| scope.lookup(nm) else null;
                if (local) |binding| {
                    if (binding.is_alloca) {
                        const ptr_ty = self.module.types.ptrTo(binding.ty);
                        method_args.items[0] = self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, ptr_ty);
                        return;
                    }
                    // A non-alloca local (SSA value / by-value param) has no
                    // stable storage to address — fall through to alloca+store.
                } else if (self.resolveGlobalRef(nm, null) != null and !self.rootIsConstant(nm)) {
                    // MUTABLE module-global lvalue receiver: address the global's
                    // LIVE storage so `self: *T` mutations target the global
                    // itself, not a throwaway stack copy (issue 0202). Mirrors
                    // the compound-lvalue branch below; `lowerExprAsPtr` yields
                    // the global's `global_addr`.
                    //
                    // A `::` CONST global is deliberately EXCLUDED: its storage
                    // is read-only (`.rodata`), so handing a `*T` to it would let
                    // a mutating method store through it — a silent write past
                    // the `cannot assign through constant` guard, and a SIGBUS in
                    // an AOT binary. Const receivers fall through to the value
                    // copy below (pre-0202 behavior): a read-only `*Self` method
                    // still sees the right value via the copy; a mutating one
                    // harmlessly scribbles the throwaway, never the `.rodata`.
                    const ptr_ty = self.module.types.ptrTo(obj_ty);
                    const place = self.lowerExprAsPtr(obj_node);
                    const place_ty = self.builder.getRefType(place);
                    method_args.items[0] = if (place_ty == ptr_ty)
                        place
                    else
                        self.builder.emit(.{ .addr_of = .{ .operand = place } }, ptr_ty);
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
                // `lowerExprAsPtr` yields the lvalue's address, typed either as
                // `*T` already (index/deref) or as the pointee `T` (a field
                // "place" ref). Normalize to `*T`: if it's already the pointer
                // type, pass it directly; if it's the pointee value type, wrap
                // with addr_of (a no-op in LLVM) to set the IR type to *T,
                // preventing coerceCallArgs from doing a spurious alloca+store.
                const ptr_ty = self.module.types.ptrTo(obj_ty);
                const place = self.lowerExprAsPtr(obj_node);
                const place_ty = self.builder.getRefType(place);
                if (place_ty == ptr_ty) {
                    method_args.items[0] = place;
                } else {
                    method_args.items[0] = self.builder.emit(.{ .addr_of = .{ .operand = place } }, ptr_ty);
                }
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
            // `for xs: (*x)` by-ref capture) — deref to pass the value.
            if (!obj_ty.isBuiltin()) {
                const oi = self.module.types.get(obj_ty);
                if (oi == .pointer and oi.pointer.pointee == first_param_ty) {
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

/// Resolve the type of a named field on a given type.
pub fn resolveFieldType(self: *Lowering, ty: TypeId, field: []const u8) TypeId {
    if (std.mem.eql(u8, field, "len")) return .i64;
    if (std.mem.eql(u8, field, "ptr")) {
        const elem_ty = self.getElementType(ty);
        return self.module.types.manyPtrTo(elem_ty);
    }
    const field_name_id = self.module.types.internString(field);
    // Check union fields + promoted fields
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        const u_fields: ?[]const types.TypeInfo.StructInfo.Field = switch (info) {
            .@"union" => |u| u.fields,
            .tagged_union => |u| u.fields,
            else => null,
        };
        if (u_fields) |ufields| {
            for (ufields) |f| {
                if (f.name == field_name_id) return f.ty;
                // Check promoted fields from anonymous struct variants
                if (!f.ty.isBuiltin()) {
                    const fi = self.module.types.get(f.ty);
                    if (fi == .@"struct") {
                        for (fi.@"struct".fields) |sf| {
                            if (sf.name == field_name_id) return sf.ty;
                        }
                    }
                }
            }
        }
    }
    // Check tuple fields
    if (!ty.isBuiltin()) {
        const ti = self.module.types.get(ty);
        if (ti == .tuple) {
            const tuple = ti.tuple;
            // Try named fields
            if (tuple.names) |names| {
                for (names, 0..) |name_id, i| {
                    if (name_id == field_name_id) return tuple.fields[i];
                }
            }
            // Try numeric index
            const idx = std.fmt.parseInt(usize, field, 10) catch {
                return .unresolved;
            };
            if (idx < tuple.fields.len) return tuple.fields[idx];
            return .unresolved;
        }
    }
    const struct_fields = self.getStructFields(ty);
    for (struct_fields) |f| {
        if (f.name == field_name_id) return f.ty;
    }
    return .unresolved;
}

pub fn lowerFieldAccess(self: *Lowering, fa: *const ast.FieldAccess, span: ast.Span) Ref {
    // `inline for xs (x)` element capture as the receiver: re-enter with the
    // synthesized `xs[<i>]` as the object, so every pack-element rule below
    // (interface-only constraint check, projection, substitution) sees the
    // canonical `xs[i].<field>` shape.
    if (fa.object.data == .identifier) {
        if (self.scope) |scope| {
            if (scope.lookup(fa.object.data.identifier.name)) |binding| {
                if (binding.pack_elem) |elem| {
                    var patched = fa.*;
                    patched.object = elem;
                    return self.lowerFieldAccess(&patched, span);
                }
            }
        }
    }

    // `error.X` — an error-tag literal. The `error` keyword in expression
    // position parses as identifier "error" (E0.2), so `error.X` is a
    // field access we intercept here. `error` is reserved, so this is
    // unambiguous (no struct/pack can be named `error`).
    if (fa.object.data == .identifier and std.mem.eql(u8, fa.object.data.identifier.name, "error")) {
        return self.lowerErrorTagLiteral(fa.field, span);
    }

    // Namespace-alias stripping in value position. The target module's
    // declarations register under their bare names, so `alias.Member`
    // re-enters as `Member` (`r.LIMIT`, and `r.Color` as the receiver of
    // `r.Color.green`); `alias.Type.field` re-enters as `Type.field`.
    if (self.namespaceRootedMember(fa.object)) |inner| {
        const root = fa.object.data.field_access.object.data.identifier.name;
        if (self.namespaceAliasTarget(root, span)) |target| {
            // `alias.global.field`: the inner namespace member may be a VALUE
            // global, not a type/static head (issue 0261). Resolve it in the
            // target module and then apply ordinary field access to its value.
            const saved_global_src = self.current_source_file;
            self.setCurrentSourceFile(target.target_module_path);
            var global_info: ?program_index_mod.GlobalInfo = null;
            if (self.program_index.global_names.get(inner)) |fallback| {
                switch (self.selectGlobalAuthor(inner)) {
                    .resolved => |g| global_info = g,
                    .untracked => global_info = fallback,
                    else => {},
                }
            }
            self.setCurrentSourceFile(saved_global_src);
            if (global_info) |gi| {
                const value = self.builder.emit(.{ .global_get = gi.id }, gi.ty);
                return self.lowerFieldAccessOnType(value, gi.ty, fa.field, span);
            }
            // Resolve the inner name as a TYPE in the target's context
            // (the alias edge authorizes the reach).
            const saved_src = self.current_source_file;
            self.setCurrentSourceFile(target.target_module_path);
            const ty = self.resolveNominalLeaf(inner, false, span);
            self.setCurrentSourceFile(saved_src);
            if (ty != .unresolved and !ty.isBuiltin()) {
                const info = self.module.types.get(ty);
                if (info == .@"enum" or info == .tagged_union) {
                    // `alias.Enum.variant` — a typed enum literal.
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
            // `alias.Type.member` (struct constants etc.) — strip the alias;
            // the type's members register under the bare type name globally.
            const synth = self.alloc.create(Node) catch null;
            if (synth) |n| {
                n.* = .{ .span = fa.object.span, .data = .{ .identifier = .{ .name = inner } } };
                const stripped = ast.FieldAccess{ .object = n, .field = fa.field, .is_optional = fa.is_optional };
                return self.lowerFieldAccess(&stripped, span);
            }
        }
    }
    if (fa.object.data == .identifier) {
        const oname = fa.object.data.identifier.name;
        const shadowed = if (self.scope) |s| s.lookup(oname) != null else false;
        if (!shadowed and !self.program_index.global_names.contains(oname)) {
            if (self.namespaceAliasTarget(oname, span)) |target| {
                const synth = self.alloc.create(Node) catch null;
                if (synth) |n| {
                    n.* = .{ .span = span, .data = .{ .identifier = .{ .name = fa.field } } };
                    // Lower in the TARGET module's context: the alias edge
                    // authorizes the member, so the bare-visibility gate must
                    // judge it as the target's own name, not the caller's.
                    const saved_src = self.current_source_file;
                    self.setCurrentSourceFile(target.target_module_path);
                    const ref = self.lowerExpr(n);
                    self.setCurrentSourceFile(saved_src);
                    return ref;
                }
            }
        }
    }

    // Bare `Enum.variant` — a qualified enum literal. When the object is a type
    // NAME resolving to an enum / tagged-union (not shadowed by a value binding /
    // global value) and `field` is a PAYLOADLESS variant, construct it like the
    // leading-dot `.variant` in a typed context. Mirrors the `alias.Enum.variant`
    // namespace path above. Restricted to payloadless variants so a payload-
    // carrying `Ev.a(5)` still flows through the call path (which supplies the
    // payload) rather than being hijacked into a zero-arg `.a` here.
    if (fa.object.data == .identifier) {
        const oname = fa.object.data.identifier.name;
        const shadowed = if (self.scope) |s| s.lookup(oname) != null else false;
        if (!shadowed and !self.program_index.global_names.contains(oname)) {
            if (self.module.types.findByName(self.module.types.internString(oname))) |ty| {
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
                        diags.addFmt(.err, span, "'{s}' is not part of protocol '{s}' — a pack element exposes only the protocol's interface", .{ fa.field, proto });
                    }
                    return self.builder.constInt(0, .void);
                }
            }
        }
    }

    // Check for struct constant access: Struct.CONST
    if (fa.object.data == .identifier) {
        const qualified = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ fa.object.data.identifier.name, fa.field }) catch fa.field;
        if (self.struct_const_map.get(qualified)) |info| {
            return self.lowerStructConstant(info);
        }
    }

    // Numeric-limit accessor: `<IntType>.min` / `.max` folds to a comptime
    // const of the queried type (sibling of the identifier-receiver
    // intercepts above). Placed AFTER `Struct.CONST` so a user const named
    // `min`/`max` wins on its own struct; a builtin type name can never
    // name a user struct (reserved), so they never collide.
    if (self.lowerNumericLimit(fa, span)) |ref| return ref;

    // M1.3 — `obj.class` on any Obj-C-class pointer lowers to
    // `object_getClass(obj)`. Sugar; the receiver is opaque so
    // we don't auto-deref. Returns `Class` (alias for *void;
    // typed Class(T) parameterization is M1.1.b).
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

    // M2.2 — `obj.field` where `field` is declared with `#property`
    // on a runtime Obj-C class lowers as `[obj field]` (the synthesized
    // getter). Receiver stays opaque — no auto-deref.
    if (self.lookupObjcPropertyOnPointer(fa.object, fa.field)) |prop| {
        return self.lowerObjcPropertyGetter(fa.object, prop, fa.field, span);
    }

    // M1.2 A.3 — `self.field` (or `obj.field`) on a *sx-defined-class
    // pointer for a plain instance field (NOT a #property) lowers as
    // `object_getIvar(obj, load(__<Cls>_state_ivar))` + struct_gep on
    // the state struct + load. The receiver is the opaque Obj-C id
    // (matching Apple's `self` semantics); the state lives in the
    // hidden `__sx_state` ivar.
    if (self.lookupObjcDefinedStateFieldOnPointer(fa.object, fa.field)) |info| {
        return self.lowerObjcDefinedStateFieldRead(fa.object, info);
    }

    // `#get` property accessor: `obj.field` where `field` is a `#get` method
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
        const is_special = obj_ty == .string or (if (!obj_ty.isBuiltin()) blk: {
            const info = self.module.types.get(obj_ty);
            break :blk info == .slice or info == .array or info == .vector;
        } else false);

        if (is_special) {
            if (std.mem.eql(u8, fa.field, "len")) {
                return self.builder.emit(.{ .length = .{ .operand = obj } }, .i64);
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
/// binding rather than a builtin type. A backtick raw identifier (F0.6) can
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
    if (self.program_index.global_names.get(name) != null) return true;
    if (self.program_index.module_const_map.get(name) != null) return true;
    return false;
}

/// Numeric-limit accessor intercept (`<Type>.min`/`.max`/`.epsilon`/
/// `.min_positive`/`.true_min`/`.inf`/`.nan`), a sibling of the `error.X` /
/// `Struct.CONST` / pack-arity identifier-receiver intercepts in
/// `lowerFieldAccess`. Folds the limit to a comptime const of the queried
/// type via the shared `TypeResolver` logic (no second computor) + the
/// existing `constInt` / `constFloat` const paths:
///   - integer `.min`/`.max` → `constInt` (NL.1, via `integerLimitFor`);
///   - float `.min`/`.max`/`.epsilon`/`.min_positive`/`.true_min`/`.inf`/
///     `.nan` → `constFloat` (via `floatLimitFor`).
/// Returns null when the field is not a limit accessor, or the receiver is not
/// a builtin type (a user struct → ordinary field lowering reports
/// field-not-found). Two clean diagnostics (then a placeholder, so lowering
/// finishes and `hasErrors()` aborts the build):
///   - a FLOAT-only accessor on an integer type (`i32.epsilon`, `u8.inf`);
///   - any accessor on a builtin NON-numeric receiver
///     (`bool`/`string`/`void`/`Any`/`noreturn`).
pub fn lowerNumericLimit(self: *Lowering, fa: *const ast.FieldAccess, span: ast.Span) ?Ref {
    const name = switch (fa.object.data) {
        .identifier => |id| id.name,
        .type_expr => |te| te.name,
        else => return null,
    };
    if (!TypeResolver.isLimitField(fa.field)) return null;
    const ty = TypeResolver.resolveBuiltinName(name, &self.module.types) orelse return null;

    // A backtick raw identifier (F0.6) can bind a value whose spelling
    // shadows a builtin type name (`` `f64 := … ``). Field access on that
    // value is an ordinary field read, not a numeric-limit fold — defer to
    // the normal field-access path when the receiver identifier resolves to
    // a value binding through any of scope / globals / module consts
    //. A `.type_expr` receiver is unambiguously a type
    // and can never be value-shadowed.
    if (fa.object.data == .identifier and self.identifierBindsValue(name)) return null;

    if (TypeResolver.integerLimitFor(name, fa.field)) |value| {
        return self.builder.constInt(value, ty);
    }
    if (TypeResolver.floatLimitFor(name, fa.field)) |value| {
        return self.builder.constFloat(value, ty);
    }
    // The field is a limit accessor, but it does not apply to this type.
    if (self.diagnostics) |d| {
        if (TypeResolver.integerWidthSign(name) != null) {
            // Integer receiver + a float-only accessor.
            d.addFmt(.err, span, "type '{s}' has no '.{s}' — '.{s}' applies only to float types (f32/f64); integer types expose only '.min'/'.max'", .{ name, fa.field, fa.field });
        } else {
            // Non-numeric builtin receiver (bool/string/void/Any/noreturn).
            d.addFmt(.err, span, "type '{s}' has no '.{s}' — numeric limits apply only to integer and float types", .{ name, fa.field });
        }
    }
    return self.emitPlaceholder(fa.field);
}

/// Lower a struct-level constant value (e.g., Phys.GRAVITY).
pub fn lowerStructConstant(self: *Lowering, info: StructConstInfo) Ref {
    const val_node = info.value;
    return switch (val_node.data) {
        .int_literal => |lit| blk: {
            self.checkIntLiteralMagnitudeFits(lit.value, info.ty orelse .i64, val_node.span);
            break :blk self.builder.constInt(lit.value, info.ty orelse .i64);
        },
        .char_literal => |lit| blk: {
            if (info.ty) |t| self.checkCharLiteralFits(lit, t, val_node.span);
            break :blk self.builder.constInt(lit.value, info.ty orelse .i64);
        },
        .float_literal => |lit| self.builder.constFloat(lit.value, info.ty orelse .f64),
        .bool_literal => |lit| self.builder.constBool(lit.value),
        .string_literal => |lit| self.builder.constString(self.module.types.internString(lit.raw)),
        else => self.lowerExpr(val_node),
    };
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

    // `#get` accessor through `?.`: if the unwrapped (and pointer-deref'd)
    // receiver has a getter for this field, the some-branch dispatches the
    // getter instead of a struct-field read. A synthetic receiver local (typed
    // `inner_ty`) lets the existing getter intercept in `lowerFieldAccess` do
    // the deref / address-of; we bind it type-only here for the return-type
    // query, then fill its ref in the some-branch (issue 0160).
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
        const tn = self.formatTypeName(deref_inner);
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
/// Map a Vector swizzle component (`.x`/`.y`/`.z`/`.w` or the colour
/// aliases `.r`/`.g`/`.b`/`.a`) to its lane index. Returns null for any
/// other field name so the read path (`lowerFieldAccessOnType`) and the
/// write path (`lowerAssignment`) share one resolver and reject a
/// non-lane field identically.
pub fn vectorLaneIndex(field: []const u8) ?u32 {
    if (std.mem.eql(u8, field, "x") or std.mem.eql(u8, field, "r")) return 0;
    if (std.mem.eql(u8, field, "y") or std.mem.eql(u8, field, "g")) return 1;
    if (std.mem.eql(u8, field, "z") or std.mem.eql(u8, field, "b")) return 2;
    if (std.mem.eql(u8, field, "w") or std.mem.eql(u8, field, "a")) return 3;
    return null;
}

/// A `#get` property accessor for `obj_ty.field`, or null. A `#get` method is a
/// normal method (registered `Type.method`) marked `is_get`; it is reachable via
/// no-paren field syntax. Handles a generic-struct instance (`List(i64).len`)
/// and a plain struct (`Foo.bar`). `ty` must be the dereferenced (non-pointer)
/// receiver type.
pub fn getAccessorFor(self: *Lowering, ty: TypeId, field: []const u8) ?*const ast.FnDecl {
    if (ty.isBuiltin()) return null;
    // A REAL field of this name wins over a same-name `#get` (a getter must not
    // shadow stored data on the read path). If the struct genuinely declares the
    // field, this is not a property access.
    const field_id = self.module.types.internString(field);
    for (self.getStructFields(ty)) |f| {
        if (f.name == field_id) return null;
    }
    // Generic instance: genericInstanceMethod is keyed by the instance name
    // (e.g. "List(i64)"), which is what formatTypeName produces.
    const tn = self.formatTypeName(ty);
    if (self.genericInstanceMethod(tn, field)) |m| {
        return if (m.fd.is_get) m.fd else null;
    }
    // Plain struct: methods are registered "StructName.method" in fn_ast_map.
    const info = self.module.types.get(ty);
    if (info == .@"struct") {
        const sname = self.module.types.getString(info.@"struct".name);
        const q = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, field }) catch return null;
        if (self.program_index.fn_ast_map.get(q)) |fd| {
            return if (fd.is_get) fd else null;
        }
    }
    return null;
}

/// A `#set` property accessor for `obj_ty.field`, or null — the WRITE
/// counterpart of `getAccessorFor`. A `#set` is registered/dispatched under its
/// effective `field$set` name (so a same-name `#get` keeps the plain `field`),
/// and a REAL field of the same name wins over it (parallels the `#get` rule).
/// `ty` must be the dereferenced (non-pointer) receiver type.
/// The return type of a `#get` accessor named `field` on `deref_ty` (a
/// dereferenced struct type), or null when there is no such getter (or no scope
/// to resolve through). Resolves the type the SAME way a real read does — via a
/// synthetic `*deref_ty` receiver local routed through inference — so a generic
/// instance getter (`List(T).len`) binds its type parameter exactly as the call
/// path would. Shared by `lowerOptionalChain` and the optional-chain inference
/// in `expr_typer`, so `obj?.getter` types identically to how it lowers.
pub fn getterReturnTypeOnDeref(self: *Lowering, deref_ty: TypeId, field: []const u8) ?TypeId {
    if (deref_ty.isBuiltin()) return null;
    if (self.getAccessorFor(deref_ty, field) == null) return null;
    const s = self.scope orelse return null;
    // Warm a generic-instance getter's monomorph so its return type resolves
    // (cold instance methods are absent from `resolveFuncByName` → `.unresolved`).
    if (self.genericInstanceMethod(self.formatTypeName(deref_ty), field)) |gm|
        _ = self.ensureGenericInstanceMethodLowered(gm);
    var buf: [40]u8 = undefined;
    const nm = std.fmt.bufPrint(&buf, "$oc_ty_{d}", .{self.block_counter}) catch "$oc_ty";
    self.block_counter += 1;
    const owned = self.alloc.dupe(u8, nm) catch return null;
    s.put(owned, .{ .ref = Ref.none, .ty = self.module.types.ptrTo(deref_ty), .is_alloca = false });
    const id = self.alloc.create(Node) catch return null;
    id.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = owned } } };
    const rn = self.alloc.create(Node) catch return null;
    rn.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .field_access = .{ .object = id, .field = field } } };
    return self.inferExprType(rn);
}

pub fn getSetterFor(self: *Lowering, ty: TypeId, field: []const u8) ?*const ast.FnDecl {
    if (ty.isBuiltin()) return null;
    // A REAL field of this name wins over a same-name `#set` (a setter must not
    // shadow stored data on the write path).
    const field_id = self.module.types.internString(field);
    for (self.getStructFields(ty)) |f| {
        if (f.name == field_id) return null;
    }
    const eff = std.fmt.allocPrint(self.alloc, "{s}" ++ Lowering.setter_eff_suffix, .{field}) catch return null;
    // Generic instance: keyed by the instance name (e.g. "List(i64)").
    const tn = self.formatTypeName(ty);
    if (self.genericInstanceMethod(tn, eff)) |m| {
        return if (m.fd.is_set) m.fd else null;
    }
    // Plain struct: the setter stub is registered "StructName.field$set".
    const info = self.module.types.get(ty);
    if (info == .@"struct") {
        const sname = self.module.types.getString(info.@"struct".name);
        const q = std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ sname, eff }) catch return null;
        if (self.program_index.fn_ast_map.get(q)) |fd| {
            return if (fd.is_set) fd else null;
        }
    }
    return null;
}

pub fn lowerFieldAccessOnType(self: *Lowering, obj: Ref, obj_ty: TypeId, field: []const u8, span: ast.Span) Ref {
    const field_name_id = self.module.types.internString(field);

    // Check if it's a union type
    if (!obj_ty.isBuiltin()) {
        const info = self.module.types.get(obj_ty);
        switch (info) {
            .tagged_union => |u| {
                // .tag → extract the enum tag value with the correct tag type
                if (std.mem.eql(u8, field, "tag")) {
                    return self.builder.emit(.{ .enum_tag = .{ .operand = obj } }, u.tag_type);
                }
                // Tagged union — use enum_payload
                for (u.fields, 0..) |f, i| {
                    if (f.name == field_name_id) {
                        return self.builder.emit(.{ .enum_payload = .{ .base = obj, .field_index = @intCast(i) } }, f.ty);
                    }
                }
                // Check promoted fields from anonymous struct variants
                for (u.fields) |f| {
                    if (!f.ty.isBuiltin()) {
                        const field_info = self.module.types.get(f.ty);
                        if (field_info == .@"struct") {
                            for (field_info.@"struct".fields, 0..) |sf, si| {
                                if (sf.name == field_name_id) {
                                    const reinterpreted = self.builder.emit(.{ .union_get = .{ .base = obj, .field_index = 0 } }, f.ty);
                                    return self.builder.structGet(reinterpreted, @intCast(si), sf.ty);
                                }
                            }
                        }
                    }
                }
            },
            .@"union" => |u| {
                // Untagged union — use union_get to reinterpret bytes
                for (u.fields, 0..) |f, i| {
                    if (f.name == field_name_id) {
                        return self.builder.emit(.{ .union_get = .{ .base = obj, .field_index = @intCast(i) } }, f.ty);
                    }
                }
                // Check promoted fields from anonymous struct variants
                for (u.fields) |f| {
                    if (!f.ty.isBuiltin()) {
                        const field_info = self.module.types.get(f.ty);
                        if (field_info == .@"struct") {
                            for (field_info.@"struct".fields, 0..) |sf, si| {
                                if (sf.name == field_name_id) {
                                    const reinterpreted = self.builder.emit(.{ .union_get = .{ .base = obj, .field_index = 0 } }, f.ty);
                                    return self.builder.structGet(reinterpreted, @intCast(si), sf.ty);
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Vector lane access: .x/.y/.z/.w (or colour aliases .r/.g/.b/.a) →
    // lane 0/1/2/3. Shares lane-index resolution with the write path
    // (lowerAssignment) via vectorLaneIndex; a non-lane field falls
    // through to the field-not-found error below.
    if (!obj_ty.isBuiltin()) {
        const vinfo = self.module.types.get(obj_ty);
        if (vinfo == .vector) {
            if (Lowering.vectorLaneIndex(field)) |vidx| {
                return self.builder.structGet(obj, vidx, vinfo.vector.element);
            }
        }
    }

    // Closure field access: .fn_ptr → field 0, .env → field 1
    if (!obj_ty.isBuiltin()) {
        const cinfo = self.module.types.get(obj_ty);
        if (cinfo == .closure) {
            if (std.mem.eql(u8, field, "fn_ptr")) {
                const fn_ptr_ty = self.module.types.ptrTo(.void);
                return self.builder.structGet(obj, 0, fn_ptr_ty);
            } else if (std.mem.eql(u8, field, "env")) {
                const env_ty = self.module.types.ptrTo(.void);
                return self.builder.structGet(obj, 1, env_ty);
            }
        }
    }

    // Tuple field access: .0, .1, etc. or named fields
    if (!obj_ty.isBuiltin()) {
        const tinfo = self.module.types.get(obj_ty);
        if (tinfo == .tuple) {
            const tuple = tinfo.tuple;
            // Try named fields first
            if (tuple.names) |names| {
                for (names, 0..) |name_id, i| {
                    if (name_id == field_name_id) {
                        return self.builder.structGet(obj, @intCast(i), tuple.fields[i]);
                    }
                }
            }
            // Try numeric index (e.g., "0", "1")
            const idx = std.fmt.parseInt(u32, field, 10) catch {
                return self.emitFieldError(obj_ty, field, span);
            };
            if (idx < tuple.fields.len) {
                return self.builder.structGet(obj, idx, tuple.fields[idx]);
            }
            return self.emitFieldError(obj_ty, field, span);
        }
    }

    // Resolve struct field index and type
    const struct_fields = self.getStructFields(obj_ty);
    for (struct_fields, 0..) |f, i| {
        if (f.name == field_name_id) {
            return self.builder.structGet(obj, @intCast(i), f.ty);
        }
    }

    return self.emitFieldError(obj_ty, field, span);
}

pub fn lowerEnumLiteral(self: *Lowering, el: *const ast.EnumLiteral) Ref {
    var target = self.target_type orelse .unresolved;

    // An OPTIONAL destination types the literal by its CHILD: `.x` flowing
    // into a `?E` slot must produce an `E` for the coercion layer to wrap
    // (`.optional_wrap`). Resolving against the optional itself fell into
    // resolveVariantValue's non-enum fallback — variant 0, mis-typed as
    // the optional (issue 0098).
    while (!target.isBuiltin()) {
        const info = self.module.types.get(target);
        if (info != .optional) break;
        target = info.optional.child;
    }

    const cs = self.builder.current_span;
    const span = ast.Span{ .start = cs.start, .end = cs.end };

    // The destination must be a known enum / tagged union that carries the
    // named variant — every other shape used to lower to a silent 0.
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
                    if (v == name_id) {
                        known_variant = true;
                        break;
                    }
                }
                if (!known_variant) self.emitBadEnumVariant(target, e, el.name, span);
            },
            .tagged_union => |u| {
                for (u.fields) |f| {
                    if (f.name == name_id) {
                        known_variant = true;
                        break;
                    }
                }
                if (!known_variant) self.emitBadVariant(target, u, el.name, span);
            },
            else => {},
        }
    }
    if (!known_variant) {
        if (self.diagnostics) |d| {
            const builtin_or_non_enum = target.isBuiltin() or switch (self.module.types.get(target)) {
                .@"enum", .tagged_union => false,
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

/// Is `field` a PAYLOADLESS variant of enum/tagged-union `ty`? A plain `.@"enum"`
/// variant is always payloadless; a `tagged_union` variant is payloadless iff its
/// payload is `void`. Used by `lowerFieldAccess` to recognise a bare
/// `Enum.variant` qualified literal (payload-carrying variants stay on the call
/// path, which supplies the payload). False for any non-enum type / unknown field.
pub fn isPayloadlessVariant(self: *Lowering, ty: TypeId, field: []const u8) bool {
    return switch (self.module.types.get(ty)) {
        .@"enum" => |e| blk: {
            for (e.variants) |v| if (std.mem.eql(u8, self.module.types.getString(v), field)) break :blk true;
            break :blk false;
        },
        .tagged_union => |u| blk: {
            for (u.fields) |f| if (std.mem.eql(u8, self.module.types.getString(f.name), field)) break :blk (f.ty == .void);
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
        list.appendSlice(self.alloc, self.module.types.getString(v)) catch return;
    }
    diags.addFmt(
        .err,
        span,
        "'{s}' is not a variant of '{s}' (variants are: {s})",
        .{ variant_name, ty_name, list.items },
    );
}

/// Lower an `error.X` tag literal to its global tag id (a `u32`). When the
/// destination context (`target_type`) is a named error set, the value is
/// typed as that set and `X`'s membership is validated; otherwise the value
/// is the raw `u32` global tag id (per the spec's context rule).
pub fn lowerErrorTagLiteral(self: *Lowering, tag_name: []const u8, span: ast.Span) Ref {
    const tag_id = self.module.types.internTag(tag_name);
    if (self.target_type) |t| {
        if (!t.isBuiltin()) {
            const info = self.module.types.get(t);
            if (info == .error_set) {
                // The bare-`!` inferred placeholder (reserved name "!") accepts
                // any tag — its members aren't known until the whole-program SCC
                // pass (E1.4) folds in every raised tag. Skip membership for it.
                if (!std.mem.eql(u8, self.module.types.getString(info.error_set.name), "!")) {
                    var in_set = false;
                    for (info.error_set.tags) |member| {
                        if (member == tag_id) {
                            in_set = true;
                            break;
                        }
                    }
                    if (!in_set) {
                        if (self.diagnostics) |diags| {
                            diags.addFmt(.err, span, "error tag 'error.{s}' is not in error set '{s}'", .{ tag_name, self.module.types.getString(info.error_set.name) });
                        }
                    }
                }
                return self.builder.constInt(@as(i64, @intCast(tag_id)), t);
            }
            // A NOMINAL non-error destination (struct / enum / union /
            // tagged union): an error tag has no representation there — the
            // raw-u32 fallback below would flow the global tag id into the
            // aggregate's bytes and silently reinterpret it (issue 0212:
            // `f(error.Fault)` into a struct-typed param read back as the
            // struct's first field). Per the spec's context rule the fallback
            // exists for the UNTYPED / integer context only — reject the
            // cross-kind destination loudly.
            switch (info) {
                .@"struct", .@"enum", .@"union", .tagged_union => {
                    if (self.diagnostics) |diags| {
                        diags.addFmt(.err, span, "error tag 'error.{s}' cannot be used where '{s}' is expected; an error tag is only an error-set value (or its raw u32 id in an integer context)", .{ tag_name, self.formatTypeName(t) });
                    }
                    // Diagnosed — hasErrors() aborts before codegen; the u32
                    // below is never executed.
                },
                else => {},
            }
        }
    }
    return self.builder.constInt(@as(i64, @intCast(tag_id)), .u32);
}

/// Lower a tagged enum construction: .Variant.{ field_inits }
/// The struct literal provides the payload fields; we wrap them in an enum_init.
pub fn lowerTaggedEnumLiteral(
    self: *Lowering,
    sl: *const ast.StructLiteral,
    variant_name: []const u8,
    union_ty: TypeId,
    union_info: types.TypeInfo.TaggedUnionInfo,
    span: ast.Span,
) Ref {
    if (self.findTaggedVariant(union_info, variant_name) == null) {
        self.emitBadVariant(union_ty, union_info, variant_name, span);
        return self.builder.enumInit(0, Ref.none, union_ty);
    }

    const tag = self.resolveVariantValue(union_ty, variant_name);
    const name_id = self.module.types.internString(variant_name);

    // Find the payload type for this variant
    var payload_ty: TypeId = .void;
    for (union_info.fields) |f| {
        if (f.name == name_id) {
            payload_ty = f.ty;
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

    // Scalar (non-aggregate) payload: `.key.{ 42 }` where `key`'s payload is a
    // plain i64 — the single field_init IS the payload value. There is no
    // struct to insertvalue into, so wrapping it in a structInit builds an
    // invalid `insertvalue i64 ...` (issue 0281). Emit the value directly.
    if (payload_fields.len == 0) {
        if (sl.field_inits.len > 1) {
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, span, "variant '{s}' takes a single {s} payload, but {d} values were given", .{ variant_name, self.formatTypeName(payload_ty), sl.field_inits.len });
            }
        }
        self.target_type = payload_ty;
        var val = self.lowerExpr(sl.field_inits[0].value);
        const src_ty = self.inferExprType(sl.field_inits[0].value);
        val = self.coerceToType(val, src_ty, payload_ty);
        self.target_type = saved_tt;
        return self.builder.enumInit(tag, val, union_ty);
    }

    var fields = std.ArrayList(Ref).empty;
    defer fields.deinit(self.alloc);

    for (sl.field_inits, 0..) |fi, i| {
        if (i < payload_fields.len) {
            const saved_inner = self.target_type;
            self.target_type = payload_fields[i].ty;
            var val = self.lowerExpr(fi.value);
            self.target_type = saved_inner;
            const src_ty = self.inferExprType(fi.value);
            val = self.coerceToType(val, src_ty, payload_fields[i].ty);
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
    union_info: types.TypeInfo.TaggedUnionInfo,
    variant_name: []const u8,
) ?usize {
    const name_id = self.module.types.internString(variant_name);
    for (union_info.fields, 0..) |f, i| {
        if (f.name == name_id) return i;
    }
    return null;
}

pub fn emitBadVariant(
    self: *Lowering,
    union_ty: TypeId,
    union_info: types.TypeInfo.TaggedUnionInfo,
    variant_name: []const u8,
    span: ast.Span,
) void {
    const diags = self.diagnostics orelse return;
    const ty_name = self.formatTypeName(union_ty);
    var list: std.ArrayList(u8) = .empty;
    for (union_info.fields, 0..) |f, i| {
        if (i > 0) list.appendSlice(self.alloc, ", ") catch return;
        list.appendSlice(self.alloc, self.module.types.getString(f.name)) catch return;
    }
    diags.addFmt(
        .err,
        span,
        "'{s}' is not a variant of '{s}' (variants are: {s})",
        .{ variant_name, ty_name, list.items },
    );
}

/// Resolve a variant name to its runtime value (flags: power-of-2, regular: index).
pub fn resolveVariantValue(self: *Lowering, ty: TypeId, variant_name: []const u8) u32 {
    if (ty.isBuiltin()) return 0;
    const info = self.module.types.get(ty);
    const name_id = self.module.types.internString(variant_name);
    switch (info) {
        .@"enum" => |e| {
            for (e.variants, 0..) |v, i| {
                if (v == name_id) {
                    if (e.explicit_values) |vals| {
                        if (i < vals.len) return @intCast(@as(u64, @bitCast(vals[i])));
                    }
                    return @intCast(i);
                }
            }
        },
        .tagged_union => |u| {
            for (u.fields, 0..) |f, i| {
                if (f.name == name_id) {
                    if (u.explicit_tag_values) |vals| {
                        if (i < vals.len) return @intCast(@as(u64, @bitCast(vals[i])));
                    }
                    return @intCast(i);
                }
            }
        },
        else => {},
    }
    return 0;
}

/// True iff `variant_name` is a declared variant of the enum / tagged-union
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
            for (e.variants) |v| if (v == name_id) break :blk true;
            break :blk false;
        },
        .tagged_union => |u| blk: {
            for (u.fields) |f| if (f.name == name_id) break :blk true;
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
        .tagged_union => |u| {
            for (u.fields, 0..) |f, i| {
                if (f.name == name_id) return @intCast(i);
            }
        },
        .@"enum" => |e| {
            for (e.variants, 0..) |v, i| {
                if (v == name_id) return @intCast(i);
            }
        },
        else => {},
    }
    return 0;
}

pub fn lowerArrayLiteral(self: *Lowering, al: *const ast.ArrayLiteral) Ref {
    var elems = std.ArrayList(Ref).empty;
    defer elems.deinit(self.alloc);

    // Determine element type: explicit type_expr > target_type > inference
    var elem_ty: TypeId = .unresolved;
    var from_target = false;
    var is_vector = false;

    // First, check explicit type annotation on the literal (e.g. Vector(3,f32).[1,2,3]).
    // The prefix slot names the AGGREGATE type; a prefix that resolves to
    // anything else (scalar `i16.[…]`, struct `Point.[…]`) reads as an
    // element-type prefix — a second meaning this spelling never had. It
    // used to be silently ignored (elements fell back to the literal
    // default, so `i32.[1]` built a `[1]i64`); refuse it instead
    // (issue 0293).
    if (al.type_expr) |te| {
        const resolved = self.resolveArrayLiteralType(te);
        if (resolved != .unresolved) {
            if (!resolved.isBuiltin()) {
                const info = self.module.types.get(resolved);
                switch (info) {
                    .array => |a| {
                        elem_ty = a.element;
                        from_target = true;
                    },
                    .vector => |v| {
                        elem_ty = v.element;
                        from_target = true;
                        is_vector = true;
                    },
                    .slice => |s| {
                        elem_ty = s.element;
                        from_target = true;
                    },
                    else => {},
                }
            }
            if (!from_target) {
                if (self.diagnostics) |d| {
                    const name = self.module.types.formatTypeName(self.alloc, resolved);
                    d.addFmt(.err, te.span, "a '.[ ]' literal's type prefix names the aggregate type, not the element type — '{s}' is not an array/vector/slice; annotate the binding instead: `x : [{d}]{s} = .[ … ]`", .{ name, al.elements.len, name });
                }
                return self.builder.constUndef(.unresolved);
            }
        }
    }

    if (!from_target) {
        if (self.target_type) |tt| {
            if (!tt.isBuiltin()) {
                const info = self.module.types.get(tt);
                switch (info) {
                    .array => |a| {
                        elem_ty = a.element;
                        from_target = true;
                    },
                    .slice => |s| {
                        elem_ty = s.element;
                        from_target = true;
                    },
                    .vector => |v| {
                        elem_ty = v.element;
                        from_target = true;
                        is_vector = true;
                    },
                    else => {},
                }
            }
        }
    }
    if (!from_target and al.elements.len > 0) {
        const inferred = self.inferExprType(al.elements[0]);
        if (inferred != .void) elem_ty = inferred;
    }

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
        // Issue 0168.
        //
        // `coerceToType` classifies a same-type element as `.no_op`/`.none`
        // and returns `val` unchanged, so this is a no-op for elements already
        // at `elem_ty` (the common `[N]i64`/`[N]Struct` case). The earlier
        // slice special-case is now subsumed by this general coercion.
        if (elem_ty != .unresolved) {
            const val_ty = self.builder.getRefType(val);
            if (val_ty != elem_ty) {
                val = self.coerceToType(val, val_ty, elem_ty);
            }
        }
        elems.append(self.alloc, val) catch unreachable;
    }

    const result_ty = if (is_vector)
        self.module.types.vectorOf(elem_ty, @intCast(al.elements.len))
    else
        self.module.types.arrayOf(elem_ty, @intCast(al.elements.len));
    return self.builder.structInit(elems.items, result_ty);
}

/// Resolve the type annotation on an array literal (e.g. Vector(3,f32).[...]).
/// Handles call nodes (Vector(3,f32)), parameterized_type_expr, and identifier/type_expr.
pub fn resolveArrayLiteralType(self: *Lowering, te: *const Node) TypeId {
    switch (te.data) {
        .call => |cl| {
            // Vector(3, f32) or Module.Vector(3, f32)
            const callee_name = switch (cl.callee.data) {
                .identifier => |id| id.name,
                .field_access => |fa| fa.field,
                else => return .unresolved,
            };
            if (std.mem.eql(u8, callee_name, "Vector")) {
                if (cl.args.len == 2) {
                    const length = self.resolveVectorLane(cl.args[0]) orelse return .unresolved;
                    const elem = self.resolveTypeWithBindings(cl.args[1]);
                    return self.module.types.vectorOf(elem, length);
                }
            }
            // Generic-struct typed-literal head (`Box(i64).[...]`): route
            // through the single layout choke-point (CP-1). A qualified head
            // `a.Box(i64).[...]` selects a's OWN template via the namespace edge
            // (Counter-1: was the global last-wins map); a bare head selects the
            // single bare-VISIBLE author.
            if (headNameOfCallee(cl.callee)) |hn| {
                switch (self.selectGenericStructHead(hn.name, hn.alias, hn.is_qualified, cl.callee.span)) {
                    .template => |t| return self.instantiateGenericStruct(&t, cl.args),
                    .poisoned => return .unresolved,
                    .not_generic => {},
                }
            }
            return .unresolved;
        },
        .parameterized_type_expr => |pt| return self.resolveParameterizedWithBindings(&pt, te.span),
        .identifier => |id| {
            // E4 single-hop visibility + ambiguity gate: a 2-flat-hop bare type
            // name in a typed array/vector-literal annotation (`Nums.[1, 2]`) is
            // not bare-visible (consistent with annotations / 0763); ≥2 direct
            // flat same-name authors are ambiguous (loud diagnostic, consistent
            // with the leaf / 0755); a single source-keyed author resolves to
            // ITS TypeId instead of a global `findByName` first-/last-wins pick.
            switch (self.headTypeGate(id.name, te.span)) {
                .ambiguous, .not_visible => return .unresolved,
                .resolved => |tid| return tid,
                .proceed => {},
            }
            const name_id = self.module.types.internString(id.name);
            return self.module.types.findByName(name_id) orelse .unresolved;
        },
        .type_expr => |inner| {
            if (self.headTypeLeak(inner.name, te.span)) return .unresolved;
            return type_bridge.resolveAstType(te, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
        },
        // Structural type heads on a typed `.[...]` literal — `[N]T`, `[]T`.
        // These resolve through the canonical `resolveAstType` compound path
        // (which recurses into the element, so `[N]?T` correctly carries the
        // optional element). Without these arms an `array_type_expr` /
        // `slice_type_expr` head fell through to `else => .unresolved`, so a
        // typed `([2]?i64).[ ... ]` lost its `?i64` element type — the null
        // element then reached LLVM as `const_null(.unresolved)` and panicked
        // (issue 0173). `resolveTypeWithBindings` is the lowering-side resolver
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
/// value of the indexed expression's target type, so the ambient `target_type`
/// must not steer it: under an `f32` target (`v : f32 = s[0];`, a `-> f32`
/// body) the literal `0` lowered as the float constant `0.0` and reached the
/// backend as `getelementptr float, ptr %d, float 0.0` — "GEP indexes must be
/// integers" from the LLVM verifier, with no source location (issue 0289).
/// Pin the target to `i64` for the operand and restore the caller's.
pub fn lowerIndexOperand(self: *Lowering, index_node: *const ast.Node) Ref {
    const saved_tt = self.target_type;
    self.target_type = .i64;
    defer self.target_type = saved_tt;
    return self.lowerExpr(index_node);
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
    // Runtime index into a comptime-only pack (Decision 1): a pack has no
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
    // Comptime-constant index into a tuple VALUE — `tup[i]` where `i` folds
    // to a compile-time integer (an `inline for` cursor or a literal). A tuple
    // has heterogeneous element types, so there is no runtime element-indexing
    // op; treat it exactly like the `.N` field-access path (a `structGet` of
    // the i-th field), yielding the field's CONCRETE type. This is what the
    // `race`/reflection loops need: read the i-th `*Task(T_i)` from a
    // named-tuple param with its real type, not a type-erased `Any`. A
    // *runtime* index into a tuple value falls through to the generic guard
    // below ("cannot index a value of type '(...)'") — there is no single
    // element type to index by at runtime.
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .tuple) {
        const tinfo = self.module.types.get(obj_ty).tuple;
        if (self.comptimeIndexOf(ie.index)) |ci| {
            if (ci >= 0 and @as(usize, @intCast(ci)) < tinfo.fields.len) {
                const fi: u32 = @intCast(ci);
                const obj = self.lowerExpr(ie.object);
                return self.builder.structGet(obj, fi, tinfo.fields[fi]);
            }
            // Comptime index is out of range — diagnose loudly rather than
            // letting it fall through to the generic "cannot index" message,
            // which would obscure the real cause (a bad constant index).
            if (self.diagnostics) |d| {
                d.addFmt(.err, ie.index.span, "tuple index {} out of bounds — tuple '{s}' has {} field{s}", .{
                    ci,
                    self.formatTypeName(obj_ty),
                    tinfo.fields.len,
                    if (tinfo.fields.len == 1) "" else "s",
                });
            }
            return self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts before codegen
        }
    }
    // Comptime-constant index into a STRUCT value — `s[i]` where `i` folds
    // (aggregate-ladder Step 2/3 access model: exact parity with the tuple
    // path above — the field itself, typed; a runtime index does NOT apply
    // to structs, use `struct_field_value(s, j)`). This is what lets a
    // positional anonymous struct (`t := .{1, 2}`) keep the `t[i]` walks
    // that tuple literals supported.
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .@"struct") {
        const sinfo = self.module.types.get(obj_ty).@"struct";
        if (self.comptimeIndexOf(ie.index)) |ci| {
            if (ci >= 0 and @as(usize, @intCast(ci)) < sinfo.fields.len) {
                const fi: u32 = @intCast(ci);
                const obj = self.lowerExpr(ie.object);
                return self.builder.structGet(obj, fi, sinfo.fields[fi].ty);
            }
            if (self.diagnostics) |d| {
                d.addFmt(.err, ie.index.span, "struct index {} out of bounds — '{s}' has {} field{s}", .{
                    ci,
                    self.formatTypeName(obj_ty),
                    sinfo.fields.len,
                    if (sinfo.fields.len == 1) "" else "s",
                });
            }
            return self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts before codegen
        }
    }
    // Optional-chain index: `opt?.xs[i]`. The `?.` makes the object an
    // optional whose child is the (array/slice/many-ptr) field — so the index
    // applies inside the chain's some-branch and the whole expression is
    // `?ElemType` (null if the receiver was null). Without this the element
    // type resolved through `getElementType(?[N]T)` was `.unresolved` and an
    // `index_get` on the optional value reached LLVM emission (issue 0181).
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .optional) {
        const child = self.module.types.get(obj_ty).optional.child;
        // A pointer-to-array child (`?*[N]T`) is indexable too: its element is
        // the pointee array's element. `getElementType` has no pointer arm, so
        // ask `ptrToArrayElem` first (mirrors the non-optional `*[N]T` path
        // below) — otherwise the `?*[N]T` case fell through to a plain
        // `index_get` with an `.unresolved` element type (issue 0181).
        const elem_ty = self.ptrToArrayElem(child) orelse self.ptrToSliceElem(child) orelse self.getElementType(child);
        if (elem_ty != .unresolved) {
            return self.lowerOptionalChainIndex(ie, child, elem_ty);
        }
    }
    // Array with addressable storage: GEP the element in place + load,
    // never `index_get` on the loaded array VALUE — that realizes as
    // copy-whole-array-to-temp per read (the general-expression sibling
    // of 0110's `lowerFor` fix), and on a 64K+ array the whole-aggregate
    // load/store ops segfault LLVM's SelectionDAG (issue 0124). The
    // object must not be lowered as a value on this path or the dead
    // whole-array load still reaches the DAG.
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array) {
        // A simple local (`arr[i]`) uses its alloca directly; any other
        // addressable chain (`table.fast[i]`, `g.grid[i][j]`, `(*p).buf[i]`)
        // recovers its storage through the lvalue machinery (issue 0317 —
        // the value fallback copied the whole field array per read). Each
        // path evaluates the object and the index exactly once.
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
    // `*[N]T` receiver auto-derefs (issue 0117): `obj` IS the pointer
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
    // recognizes `[N]T` array, `[]T` slice, `[*]T` many-pointer, `Vector`,
    // `string`, and `ptrToArrayElem` handled `*[N]T` above; an `.unresolved`
    // element means the base is a single pointer `*T` / a struct (non-indexable
    // by design), or a pointer-to-slice `*[]T` (indexable per spec, not yet
    // implemented — issue 0242). Emitting an `index_get` with `.unresolved`
    // would slip past lowering and panic in emit_llvm ("unresolved type
    // reached LLVM emission", issue 0183). Diagnose (see diagNonIndexable) and
    // return a placeholder so hasErrors() aborts before codegen.
    if (elem_ty == .unresolved) {
        self.diagNonIndexable(obj_ty, ie.object.span);
        return self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts before codegen
    }
    return self.builder.emit(.{ .index_get = .{ .lhs = obj, .rhs = idx } }, elem_ty);
}

/// Shared "cannot index this type" diagnostic for every index-lowering path —
/// read (`p[i]`), write (`p[i] = v`), address-of (`@p[i]`), and the L-value
/// pointer path (`p[i].field` as an assignment/GEP base). Each of those paths
/// computes the element type via `ptrToArrayElem(..) orelse
/// getElementType(..)`; an `.unresolved` result means the base is a shape
/// those resolvers don't index — a single pointer `*T` or a struct
/// (non-indexable by design, specs.md Pointer Types), or a pointer-to-slice
/// `*[]T` (indexable per spec but not yet implemented — tracked as issue
/// 0242; it lands here until that lands). Emitting an `index_get`/`index_gep`
/// whose element type is `.unresolved` would slip past lowering and panic at
/// LLVM emission ("unresolved type reached LLVM emission" — issues 0183 read,
/// 0155 write/address-of/lvalue). The caller must bail with a placeholder
/// after calling this; hasErrors() aborts before codegen.
///
/// An already-`.unresolved` object type is skipped: it comes from a PRIOR
/// error (e.g. an undefined name) already diagnosed — re-reporting would
/// duplicate the message (mirrors the issue-0172 `??` guard).
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
    const obj = self.lowerExpr(se.object);
    const obj_ty = self.inferExprType(se.object);
    // A slice base whose type never resolved to a concrete array — an inline
    // array literal (`i64.[1,2,3][0..2]`), a struct-literal array, or an
    // already-poisoned base — must not reach codegen: `emitSubslice` would
    // call `toLLVMType` on the `.unresolved` element and panic (issue 0225
    // review MED-1). It is also a temporary with no backing storage, which
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
    var lo = if (se.start) |s| self.lowerExpr(s) else self.builder.constInt(0, .i64);
    if (se.start_exclusive) lo = self.builder.add(lo, self.builder.constInt(1, .i64), .i64);
    // Open-ended `hi`: for a fixed-size array the length is a compile-time
    // constant — emit it directly rather than a runtime `.length` op. Runtime
    // codegen folds the identical constant for an array (`emitLength`), so the
    // result is unchanged; the win is the comptime interp, which can't
    // disambiguate a 2-element array from a `{ptr,len}` fat pointer by Value
    // shape and so would misread a `.length` op on an array.
    var hi = if (se.end) |e|
        self.lowerExpr(e)
    else if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array)
        self.builder.constInt(@intCast(self.module.types.get(obj_ty).array.length), .i64)
    else if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .many_pointer) blk: {
        // A many-pointer `[*]T` carries no length, so an open-ended slice
        // `mp[lo..]` has no upper bound to resolve — a `.length` op on it would
        // yield a garbage length (issue 0159). Require an explicit `hi`.
        if (self.diagnostics) |d|
            d.addFmt(.err, se.object.span, "slicing a many-pointer `[*]T` requires an explicit upper bound (`mp[lo..hi]`) — it has no length", .{});
        break :blk self.builder.constInt(0, .i64);
    } else self.builder.emit(.{ .length = .{ .operand = obj } }, .i64);
    if (se.end_inclusive) hi = self.builder.add(hi, self.builder.constInt(1, .i64), .i64);
    // Subslice of string stays string (same {ptr, i64} layout, correct type category)
    if (obj_ty == .string) {
        return self.builder.emit(.{ .subslice = .{ .base = obj, .lo = lo, .hi = hi, .base_ty = obj_ty } }, .string);
    }
    const elem_ty = self.getElementType(obj_ty);
    const slice_ty = if (elem_ty != .void) self.module.types.sliceOf(elem_ty) else self.module.types.sliceOf(.u8);
    // Slicing an ARRAY must produce a zero-copy VIEW into the array's backing
    // storage (specs.md §Subslicing: "the result points into the original
    // backing storage — no memory allocation"). Lowering the array as a VALUE
    // materializes a fresh temp (emitSubslice's array-value arm does an
    // alloca+store), so the slice would view a COPY and mutations through it
    // would never reach the array (issue 0225). For an ADDRESSABLE array
    // (local, global, struct field, `*[N]T` deref) recover the storage
    // ADDRESS from the already-lowered value — via the issue-0214
    // `refStorageAddress` walk, which re-emits only address arithmetic, never
    // re-runs a side-effecting index — and subslice over THAT pointer (the
    // many-pointer arm of emitSubslice / the comptime VM GEPs by `lo` in
    // place). `base_ty` becomes `[*]elem` so the comptime VM strides by the
    // element size, not the whole-array size.
    if (!obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array) {
        if (self.refStorageAddress(obj)) |addr| {
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

/// Self-type an UNTYPED `.{ ... }` literal as an anonymous STRUCTURAL
/// struct (the aggregate-ladder Step-2 resolution): every element is
/// positional (fields "0"/"1"/…) or every element is named — the
/// bare-identifier shorthand `.{ x }` counts as NAMED (field `x`;
/// `.{ (x) }` is the positional escape), a spread splices positionally.
/// Mixing the two is a compile error. The struct type interns
/// STRUCTURALLY, so identical shapes at different sites share a TypeId.
pub fn synthesizeAnonStruct(self: *Lowering, sl: *const ast.StructLiteral, span: ast.Span) Ref {
    var named_n: usize = 0;
    var pos_n: usize = 0;
    for (sl.field_inits) |fi| {
        if (fi.name != null) named_n += 1 else pos_n += 1;
    }
    if (named_n > 0 and pos_n > 0) {
        if (self.diagnostics) |d| {
            d.addFmt(.err, span, "an untyped '.{{ }}' literal cannot mix positional and named elements — name all elements or none", .{});
        }
        return self.builder.constUndef(.unresolved);
    }

    var elems = std.ArrayList(Ref).empty;
    defer elems.deinit(self.alloc);
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    defer fields.deinit(self.alloc);

    const saved_target = self.target_type;
    var out_idx: usize = 0;
    for (sl.field_inits) |fi| {
        if (fi.value.data == .spread_expr) {
            const sp_operand = fi.value.data.spread_expr.operand;
            // Pack spread (`stored := .{ ..xs };`) — splice the pack's
            // materialized element values as positional fields.
            if (self.packSpreadRefs(sp_operand, fi.value.span)) |refs| {
                defer self.alloc.free(refs);
                for (refs) |r| {
                    elems.append(self.alloc, r) catch unreachable;
                    const fname = std.fmt.allocPrint(self.alloc, "{d}", .{out_idx}) catch unreachable;
                    fields.append(self.alloc, .{ .name = self.module.types.internString(fname), .ty = self.builder.getRefType(r) }) catch unreachable;
                    out_idx += 1;
                }
                continue;
            }
            // Value spread (`.{ ..t, 3 }` over a tuple/array/anon struct).
            if (self.valueSpreadRefs(sp_operand, fi.value.span)) |refs| {
                defer self.alloc.free(refs);
                for (refs) |r| {
                    elems.append(self.alloc, r) catch unreachable;
                    const fname = std.fmt.allocPrint(self.alloc, "{d}", .{out_idx}) catch unreachable;
                    fields.append(self.alloc, .{ .name = self.module.types.internString(fname), .ty = self.builder.getRefType(r) }) catch unreachable;
                    out_idx += 1;
                }
                continue;
            }
            _ = self.lowerExpr(fi.value); // surfaces the spread_expr diagnostic
            continue;
        }
        self.target_type = null;
        const val = self.lowerExpr(fi.value);
        self.target_type = saved_target;
        const vty = self.builder.getRefType(val);
        const fname = fi.name orelse (std.fmt.allocPrint(self.alloc, "{d}", .{out_idx}) catch unreachable);
        elems.append(self.alloc, val) catch unreachable;
        fields.append(self.alloc, .{ .name = self.module.types.internString(fname), .ty = vty }) catch unreachable;
        out_idx += 1;
    }

    const sty = self.module.types.internAnonStruct(
        self.alloc.dupe(types.TypeInfo.StructInfo.Field, fields.items) catch unreachable,
    );
    return self.builder.structInit(elems.items, sty);
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

    // Explicitly-typed construction `Tuple(A, B).( ... )`: the literal carries
    // its tuple type, exactly like `Name.{ ... }` for structs. Resolve it and
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
            if (tinfo == .tuple and (has_spread or tinfo.tuple.fields.len == tl.elements.len)) {
                target_fields = tinfo.tuple.fields;
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
        if (val_ty != field_ty and val_ty != .void) {
            val = self.coerceToType(val, val_ty, field_ty);
        }
        elems.append(self.alloc, val) catch unreachable;
        field_type_ids.append(self.alloc, field_ty) catch unreachable;
        if (elem.name) |name| {
            name_ids.append(self.alloc, self.module.types.internString(name)) catch unreachable;
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
        self.module.types.intern(.{ .tuple = .{
            .fields = self.alloc.dupe(TypeId, field_type_ids.items) catch unreachable,
            .names = if (has_names) self.alloc.dupe(types.StringId, name_ids.items) catch unreachable else null,
        } });

    const owned = self.alloc.dupe(Ref, elems.items) catch unreachable;
    return self.builder.emit(.{ .tuple_init = .{ .fields = owned } }, tuple_ty);
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

/// Reject using an un-narrowed optional directly as a binary-op operand
/// (issue 0185). Mirrors the `coerceMode` `?T → concrete` rejection (0179):
/// the optional does not implicitly unwrap; steer the user to an explicit form.
pub fn diagOptionalOperand(self: *Lowering, opt_ty: TypeId, span: ast.Span) void {
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "cannot use a value of type '{s}' as an operand: an optional does not implicitly unwrap; force-unwrap with '!', supply a fallback with '?? <default>', or guard with '!= null'", .{self.formatTypeName(opt_ty)});
    }
}

pub fn lowerForceUnwrap(self: *Lowering, fu: *const ast.ForceUnwrap) Ref {
    const val = self.lowerExpr(fu.operand);
    const inner_ty = self.resolveOptionalInner(self.inferExprType(fu.operand));
    return self.builder.optionalUnwrap(val, inner_ty);
}

pub fn lowerNullCoalesce(self: *Lowering, nc: *const ast.NullCoalesce) Ref {
    const lhs = self.lowerExpr(nc.lhs);
    const lhs_ty = self.inferExprType(nc.lhs);

    // `??` requires an optional left operand. A resolved non-optional lhs is
    // malformed user input: diagnose it here instead of letting the
    // `.unresolved` inner type (from `resolveOptionalInner`) flow into the
    // merge-block params / `optionalUnwrap` / the RHS target type and reach
    // emit_llvm's "unresolved type reached LLVM emission" panic with no source
    // location (issue 0172). Skip an already-`.unresolved` lhs: that comes
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
    // struct_init (issue 0166). Scalar/pointer/typed defaults are unaffected:
    // they ignore `target_type` or coerce identically. Restore afterwards so
    // a `??` nested inside a larger expression doesn't leak this target type.
    const saved_tt = self.target_type;
    self.target_type = inner_ty;
    var rhs = self.lowerExpr(nc.rhs);
    self.target_type = saved_tt;
    const rhs_ty = self.builder.getRefType(rhs);
    // Skip the coerce entirely when the pair has NO modeled coercion and a
    // width mismatch: `coerceToType` would be a passthrough no-op anyway, and
    // its issue-0191 guard would fire a generic "cannot coerce" ahead of the
    // focused `'??' default has type ...` diagnostic below (double error).
    if (rhs_ty != inner_ty and rhs_ty != .void and inner_ty != .void and !self.noneReinterpretIsUnsafe(rhs_ty, inner_ty)) {
        rhs = self.coerceToType(rhs, rhs_ty, inner_ty);
    }
    // The merge-block param, the unwrapped LHS, and the coerced RHS must all
    // share `inner_ty` — they feed the same PHI. If the RHS default still does
    // not match after coercion (e.g. a scalar `5` default against an optional
    // whose payload is a 1-tuple `(i32,)`: there is no implicit scalar→1-tuple
    // coercion — a 1-tuple value is written `(5,)`), branching with the
    // mismatched type emits a `phi {i32}` vs `i32` that aborts the LLVM
    // verifier (issue 0180). Diagnose loudly and br with a typed placeholder so
    // the PHI stays well-formed; `hasErrors()` aborts before codegen anyway.
    const coerced_ty = self.builder.getRefType(rhs);
    if (coerced_ty != inner_ty and coerced_ty != .void and inner_ty != .void) {
        if (self.diagnostics) |d| {
            const note: []const u8 = if (!inner_ty.isBuiltin() and self.module.types.get(inner_ty) == .tuple)
                " (note: a 1-tuple value is written '(x,)' with a trailing comma)"
            else
                "";
            d.addFmt(.err, nc.rhs.span, "'??' default has type '{s}', but the optional's payload is '{s}'{s}", .{ self.formatTypeName(coerced_ty), self.formatTypeName(inner_ty), note });
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

pub fn lowerExpr(self: *Lowering, node: *const Node) Ref {
    // Stamp this node's source span onto the instructions it emits (ERR
    // E3.0 — feeds DWARF line-info + comptime frame resolution). Save/
    // restore so a parent's later emits keep the parent's span after a
    // child lowers. Skip the empty default so synthetic nodes don't reset
    // a meaningful enclosing span to offset 0.
    const saved_span = self.builder.current_span;
    defer self.builder.current_span = saved_span;
    if (node.span.start != 0 or node.span.end != 0) self.builder.current_span = .{ .start = node.span.start, .end = node.span.end };
    // A node carrying an explicit `source_file` is one spliced into a body
    // from another module — a substituted caller comptime-`$`-arg (stamped
    // at the `cpn` build site in lowerComptimeCall / monomorphizePackFn).
    // Resolve its bare names in THAT module's visibility context, overriding
    // the body's defining-module pin, then restore so sibling callee nodes
    // keep the enclosing context. Ordinary expression nodes never carry a
    // `source_file`, so this is a no-op on the hot path.
    const restore_source = node.source_file != null;
    const saved_source = self.current_source_file;
    if (node.source_file) |sf| self.setCurrentSourceFile(sf);
    defer if (restore_source) self.setCurrentSourceFile(saved_source);
    return switch (node.data) {
        // Bare `$<pack>` in expression position → an `[]Type` slice
        // value where each element is a `const_type(arg_types[i])`.
        // Per `Type → .any` mapping in type_bridge, the IR slice
        // type is `[]Any`; the interp stores raw `.type_tag` Values
        // (NOT Any-boxed) so `args[i]` reads back as a Type value
        // directly. Step 4 final slice — lets builder fns walk the
        // whole pack at interp time.
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
            // If target is a float type, emit as float literal
            if (self.target_type) |tt| {
                if (tt == .f32 or tt == .f64) {
                    return self.builder.constFloat(@floatFromInt(lit.value), tt);
                }
            }
            const ty = if (self.target_type) |tt| blk: {
                break :blk if (self.isIntEx(tt)) tt else .i64;
            } else .i64;
            self.checkIntLiteralMagnitudeFits(lit.value, ty, node.span);
            return self.builder.constInt(lit.value, ty);
        },
        .char_literal => |lit| {
            if (self.target_type) |tt| {
                if (tt == .f32 or tt == .f64) {
                    return self.builder.constFloat(@floatFromInt(lit.value), tt);
                }
            }
            const ty = if (self.target_type) |tt| blk: {
                break :blk if (self.isIntEx(tt)) tt else .i64;
            } else .i64;
            self.checkCharLiteralFits(lit, ty, node.span);
            return self.builder.constInt(lit.value, ty);
        },
        .float_literal => |lit| {
            const fty: TypeId = if (self.target_type) |tt| (if (tt == .f32 or tt == .f64) tt else .f64) else .f64;
            return self.builder.constFloat(lit.value, fty);
        },
        .bool_literal => |lit| self.builder.constBool(lit.value),
        .string_literal => |lit| blk: {
            const str = if (lit.is_raw)
                lit.raw
            else
                unescape.unescapeString(self.alloc, lit.raw) catch lit.raw;
            const sid = self.module.types.internString(str);
            break :blk self.builder.constString(sid);
        },
        // A bare `null` / `---` with no surrounding type expectation is a
        // legitimate typeless literal, not a failed lookup: `.void` is its
        // intentional default (emitConstNull/emitConstUndef handle void as
        // null-ptr / undef-i64). Not a candidate for the `.unresolved` tripwire.
        .null_literal => self.builder.constNull(self.target_type orelse .void),
        .undef_literal => self.builder.constUndef(self.target_type orelse .void),

        .identifier => |id| blk: {
            // A bare pack name in value position has no runtime
            // representation (Decision 1). Projections (`xs.len`, `xs[i]`,
            // `xs.value`) are field/index nodes handled elsewhere, so a bare
            // `xs` reaching here is always a pack-as-value misuse.
            if (self.isPackName(id.name)) {
                break :blk self.diagPackAsValue(id.name, node.span, .generic);
            }
            if (self.scope) |scope| {
                const sb = scope.lookupBoundary(id.name);
                if (sb.crossed_fn_boundary) break :blk self.diagEnclosingLocalRef(id.name, node.span);
                if (sb.binding) |binding| {
                    // `inline for xs (x)` element capture — lower the
                    // synthesized `xs[<i>]` it aliases.
                    if (binding.pack_elem) |elem| break :blk self.lowerExpr(elem);
                    // Flow narrowing (issue 0179): a name proven present by a
                    // `!= null` guard tags its loaded value so the implicit
                    // `?T → concrete` unwrap in `coerceMode` is permitted (an
                    // un-narrowed unwrap is rejected, not silently zeroed).
                    const is_narrowed = self.narrowed.count() > 0 and self.narrowed.contains(id.name);
                    if (binding.is_alloca) {
                        const loaded = self.builder.load(binding.ref, binding.ty);
                        if (is_narrowed) self.narrowed_refs.put(loaded, {}) catch {};
                        break :blk loaded;
                    }
                    if (is_narrowed) self.narrowed_refs.put(binding.ref, {}) catch {};
                    break :blk binding.ref;
                }
            }
            // Check compile-time constants (OS, ARCH, POINTER_SIZE) before globals
            if (self.comptime_constants.get(id.name)) |cv| {
                switch (cv) {
                    .int_val => |iv| break :blk self.builder.constInt(iv, .i64),
                    .enum_tag => |et| break :blk self.builder.constInt(@intCast(et.tag), et.ty),
                }
            }
            // `context` resolves to a load through the lowering's
            // current `__sx_ctx` pointer. Every sx function (and
            // every `push Context.{...}` body) sets `current_ctx_ref`
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
            // Check globals (#run constants) — source-aware (issue 0115):
            // the global registry is last-wins across modules, so select the
            // AUTHOR first and emit ITS global, never an unrelated module's
            // same-named one.
            if (self.program_index.global_names.get(id.name)) |gi| {
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
                            d.addFmt(.err, node.span, "'{s}' is not visible; #import the module that declares it", .{id.name});
                        break :blk self.emitError(id.name, node.span);
                    },
                    .untracked => break :blk self.builder.emit(.{ .global_get = gi.id }, gi.ty),
                }
            }
            // Check module-level value constants (e.g. AF_INET :i32: 2)
            if (self.program_index.module_const_map.get(id.name)) |ci_global| {
                if (!self.isNameVisible(id.name)) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "'{s}' is not visible; #import the module that declares it", .{id.name});
                    break :blk self.emitError(id.name, node.span);
                }
                // F2: emit the SOURCE-AWARE author's value (own-wins), not the
                // global last-wins `ci_global`. ≥2 flat-visible same-name const
                // authors → a loud ambiguity, never a silent
                // pick. `.none` after a visible name is the registration-only
                // author (no per-source partition) — emit its global value.
                switch (self.selectModuleConst(id.name)) {
                    .resolved => |sel| break :blk self.emitModuleConst(sel.info, sel.source),
                    // Own const author with no materialized value (unsupported
                    // shape, e.g. an array const) — fall through; the tail of
                    // identifier lowering diagnoses it as unresolved.
                    .own_opaque => {},
                    .ambiguous => {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, node.span, "'{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{id.name});
                        break :blk self.emitPlaceholder(id.name);
                    },
                    .none => break :blk self.emitModuleConst(ci_global, null),
                }
            }
            // Check if it's a function name — produce function pointer reference
            // Resolve mangled name for block-local functions
            const eff_fn_name = if (self.scope) |scope| scope.lookupFn(id.name) orelse id.name else id.name;
            // An own fn whose name a flat-merge collision dropped from the
            // global decl list (first-wins) has no `fn_ast_map` entry but IS
            // a raw-facts author — the author selection inside this arm
            // serves it, so admit it through the gate.
            const fn_author_only = !self.program_index.fn_ast_map.contains(eff_fn_name) and
                std.mem.eql(u8, eff_fn_name, id.name) and
                (if (self.scope) |scope| scope.lookup(id.name) == null else true) and
                self.current_source_file != null and
                self.selectPlainCallableAuthor(id.name, self.current_source_file.?) == .func;
            if (self.program_index.fn_ast_map.contains(eff_fn_name) or fn_author_only) {
                // Visibility check only for user-typed bare names (id.name
                // == eff_fn_name) without a UFCS alias. Mangled local-
                // scope names and UFCS rewrites are compiler indirections
                // and stay exempt.
                if (std.mem.eql(u8, eff_fn_name, id.name) and
                    self.program_index.ufcs_alias_map.get(id.name) == null and
                    !self.isNameVisible(eff_fn_name))
                {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "'{s}' is not visible; #import the module that declares it", .{eff_fn_name});
                    break :blk self.emitError(eff_fn_name, node.span);
                }
                // Type-as-value: a bare function name in a `Type` (`.type_value`)
                // slot is its FUNCTION TYPE — `const_type(() -> R)` — so it prints
                // / reflects as the real function type, not a func-ref. For a
                // genuine `Any` param the old behavior is kept (a formatted
                // type-name string boxed as Any).
                if (self.target_type == .any or self.target_type == .type_value) {
                    const fd_any: ?*const ast.FnDecl = self.program_index.fn_ast_map.get(eff_fn_name) orelse fd_blk: {
                        switch (self.selectPlainCallableAuthor(id.name, self.current_source_file.?)) {
                            .func => |sf| break :fd_blk sf.decl,
                            else => break :fd_blk null,
                        }
                    };
                    if (fd_any) |fd| {
                        if (self.target_type == .type_value) {
                            var param_ids = std.ArrayList(TypeId).empty;
                            defer param_ids.deinit(self.alloc);
                            for (fd.params) |p| param_ids.append(self.alloc, self.resolveParamType(&p)) catch {};
                            const fn_tid = self.module.types.functionType(param_ids.items, self.resolveReturnType(fd));
                            break :blk self.builder.constType(fn_tid);
                        }
                        const fn_type_str = self.formatFnTypeString(fd);
                        const sid = self.module.types.internString(fn_type_str);
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
                        self.program_index.ufcs_alias_map.get(id.name) == null and
                        (if (self.scope) |scope| scope.lookup(id.name) == null else true))
                    {
                        if (self.current_source_file) |caller_file| {
                            switch (self.selectPlainCallableAuthor(id.name, caller_file)) {
                                .func => |sf| {
                                    var selected = sf;
                                    break :blk_fv self.selectedFuncId(&selected, id.name);
                                },
                                .ambiguous => {
                                    if (self.diagnostics) |d|
                                        d.addFmt(.err, node.span, "'{s}' is ambiguous; declared by multiple imported modules — qualify the call", .{id.name});
                                    break :blk self.emitError(id.name, node.span);
                                },
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
                            if (tt_info == .closure) {
                                const tramp_id = self.createBareFnTrampoline(fid, tt_info.closure);
                                break :blk self.builder.closureCreate(tramp_id, Ref.none, tt);
                            }
                            // Coercing a bare fn name to a fn-pointer
                            // type — the call_conv must match. A
                            // default-conv sx fn assigned to a
                            // abi(.c) slot (e.g. passed to
                            // pthread_create) would otherwise crash at
                            // runtime when the C caller doesn't supply
                            // the implicit __sx_ctx arg.
                            if (tt_info == .function) {
                                const func_cc = self.module.functions.items[@intFromEnum(fid)].call_conv;
                                if (func_cc != tt_info.function.call_conv) {
                                    if (self.diagnostics) |d| {
                                        const want_cc = if (tt_info.function.call_conv == .c) "abi(.c)" else "default sx convention";
                                        const have_cc = if (func_cc == .c) "abi(.c)" else "default sx convention";
                                        d.addFmt(.err, node.span, "call-convention mismatch: '{s}' is declared with {s} but the target type expects {s}", .{ eff_fn_name, have_cc, want_cc });
                                    }
                                    break :blk self.emitPlaceholder(eff_fn_name);
                                }
                            }
                            // NOTE: `xx <sx_fn> : *void` (e.g.
                            // `class_addMethod(_, _, xx my_imp, _)`)
                            // is intentionally NOT diagnosed here.
                            // Manually-constructed Closure values
                            // legitimately store default-conv sx fns
                            // into a `*void` slot for sx-side dispatch
                            // through the closure trampoline ABI. The
                            // compiler can't distinguish C-side vs
                            // sx-side use from the cast alone.
                            // examples/50-smoke.sx has both shapes.
                        }
                    }
                    // A bare function value keeps the legacy integer-shaped IR
                    // used by the async/fiber lowering paths (issue 0237), but
                    // that word must match the target pointer width. Hard-coding
                    // i64 made an otherwise exact callback assignment fail on
                    // wasm32: the destination function slot is 4 bytes while the
                    // synthetic source type claimed 8. Preserve i64 byte-for-
                    // byte on existing 64-bit targets; use the canonical signed
                    // pointer word on narrower targets.
                    const func_ref_ty: TypeId = if (self.module.types.pointer_size == 8) .i64 else .isize;
                    break :blk self.builder.emit(.{ .func_ref = fid }, func_ref_ty);
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
            // E4 single-hop visibility + ambiguity gate: a bare type name used
            // as a VALUE (`x: Type = COnly`, `x == COnly`) reachable only over
            // 2+ flat hops is not bare-visible (consistent with annotations /
            // 0763); ≥2 direct flat same-name authors are ambiguous (loud
            // diagnostic, 0755/0767). A single source-keyed author — including
            // the querying source's OWN author over a same-name flat import
            // (own-wins, 0754) — resolves to ITS TypeId, NOT whichever same-name
            // author a global `findByName` would pick. A value name / generic
            // param / undeclared name → `.proceed`, falling through below.
            const ty = blk_ty: {
                switch (self.headTypeGate(id.name, node.span)) {
                    .ambiguous, .not_visible => break :blk self.emitPlaceholder(id.name),
                    .resolved => |tid| break :blk_ty tid,
                    .proceed => {},
                }
                if (self.type_bindings) |tb| {
                    if (tb.get(id.name)) |t| break :blk_ty t;
                }
                if (self.program_index.type_alias_map.get(id.name)) |t| break :blk_ty t;
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

        .binary_op => |bop| self.lowerBinaryOp(&bop),

        .unary_op => |uop| blk: {
            // `xx <pack>` with a slice target materializes the comptime
            // pack into a runtime `[]elem` (issue 0053). Must run before the
            // operand is lowered (a bare pack name otherwise hits the
            // pack-as-value error).
            if (uop.op == .xx and uop.operand.data == .identifier and self.isPackName(uop.operand.data.identifier.name)) {
                const pname = uop.operand.data.identifier.name;
                if (self.target_type) |tt| {
                    if (!tt.isBuiltin() and self.module.types.get(tt) == .slice) {
                        break :blk self.lowerPackToSlice(pname, tt);
                    }
                }
                break :blk self.diagPackAsValue(pname, node.span, .generic);
            }
            // address_of(index_expr) → emit index_gep (pointer to element) instead of index_get + addr_of
            if (uop.op == .address_of and uop.operand.data == .index_expr) {
                const ie = &uop.operand.data.index_expr;
                const obj_ty = self.inferExprType(ie.object);
                // Comptime-constant index into a tuple VALUE — `@tup[i]`. A tuple is
                // heterogeneous: the element address is a typed `structGep` of the
                // i-th field, never an `index_gep` (whose `ptrTo(.unresolved)`
                // element type panics at LLVM emit). Out-of-range diagnoses loudly,
                // mirroring the read path.
                if (!obj_ty.isBuiltin() and (self.module.types.get(obj_ty) == .tuple or self.module.types.get(obj_ty) == .@"struct")) {
                    // Struct parity (aggregate ladder): `@s[comptime i]` is the
                    // i-th field's address, exactly like tuples.
                    const nfields: usize = @intCast(self.module.types.memberCount(obj_ty) orelse 0);
                    if (self.comptimeIndexOf(ie.index)) |ci| {
                        if (ci >= 0 and @as(usize, @intCast(ci)) < nfields) {
                            const fi: u32 = @intCast(ci);
                            const fld_ty = self.module.types.memberType(obj_ty, ci) orelse .unresolved;
                            const base = self.getExprAlloca(ie.object) orelse self.lowerExprAsPtr(ie.object);
                            break :blk self.builder.structGepTyped(base, fi, self.module.types.ptrTo(fld_ty), obj_ty);
                        }
                        if (self.diagnostics) |d| {
                            d.addFmt(.err, ie.index.span, "tuple index {} out of bounds — tuple '{s}' has {} field{s}", .{
                                ci, self.formatTypeName(obj_ty), nfields, if (nfields == 1) "" else "s",
                            });
                        }
                        break :blk self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts
                    }
                }
                const idx = self.lowerIndexOperand(ie.index);
                const elem_ty = self.ptrToArrayElem(obj_ty) orelse self.ptrToSliceElem(obj_ty) orelse self.getElementType(obj_ty);
                // Non-indexable base (`@pc[i]` on a `*T`, a struct, ...): an
                // `index_gep` typed `ptrTo(.unresolved)` panics at LLVM
                // emission (issue 0155) — diagnose and bail instead.
                if (elem_ty == .unresolved) {
                    self.diagNonIndexable(obj_ty, ie.object.span);
                    break :blk self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts
                }
                const ptr_ty = self.module.types.ptrTo(elem_ty);
                // For array targets, use the storage pointer (alloca for a
                // local, global_addr for a module global) so the resulting
                // pointer is into live storage, not a loaded copy.
                const is_array = !obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array;
                var base = if (is_array) (self.getExprAlloca(ie.object) orelse self.lowerExprAsPtr(ie.object)) else self.lowerExpr(ie.object);
                base = self.derefPtrToSliceIndexBase(base, obj_ty);
                break :blk self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = idx } }, ptr_ty);
            }
            // address_of(field_access) → use lowerExprAsPtr for GEP chain
            // Handles all cases: pointer-based, index-based, nested field access
            if (uop.op == .address_of and uop.operand.data == .field_access) {
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
                    if (sb.crossed_fn_boundary) break :blk self.diagEnclosingLocalRef(id_name, node.span);
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
                        // for asm `-> @const` (issue 0138). Diagnose loudly.
                        if (!binding.is_ref_capture and binding.pack_elem == null) {
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
                // become `inttoptr (i64 <value> to ptr)`. Diagnose (issue 0138).
                if (self.program_index.module_const_map.get(id_name) != null) {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, node.span, "cannot take the address of constant '{s}' — a scalar '::' constant has no storage (use a '=' variable or a local copy for mutable data)", .{id_name});
                    break :blk self.emitPlaceholder("addr_of_const");
                }
            }
            // Fold a negated integer literal into one constant: `-128` must
            // range-check as -128, not as an out-of-range +128 intermediate.
            if (uop.op == .negate and uop.operand.data == .int_literal) {
                const lit = uop.operand.data.int_literal;
                const v = -%lit.value;
                if (self.target_type) |tt| {
                    if (tt == .f32 or tt == .f64) {
                        break :blk self.builder.constFloat(@floatFromInt(v), tt);
                    }
                }
                const nty = if (self.target_type) |tt| (if (self.isIntEx(tt)) tt else TypeId.i64) else TypeId.i64;
                self.checkIntLiteralFits(v, nty, node.span);
                break :blk self.builder.constInt(v, nty);
            }
            // An explicit `xx` cast requests the conversion, truncation
            // included — literal operands skip the fits-check.
            const saved_fit = self.suppress_int_fit_check;
            if (uop.op == .xx) self.suppress_int_fit_check = true;
            const operand = self.lowerExpr(uop.operand);
            self.suppress_int_fit_check = saved_fit;
            break :blk switch (uop.op) {
                .negate => self.builder.emit(.{ .neg = .{ .operand = operand } }, self.inferExprType(uop.operand)),
                // `!` is LOGICAL not. Only a real bool may go through the
                // bitwise `bool_not` (i1); an integer-backed operand — an
                // error binding (u32 tag), a plain integer — lowers as the
                // truthiness complement `operand == 0`: a bitwise not of a
                // nonzero tag stays nonzero, so `if !e` held even on a set
                // error (issue 0129). Anything else is diagnosed.
                .not => blk2: {
                    const oty = self.inferExprType(uop.operand);
                    if (oty == .bool) {
                        break :blk2 self.builder.emit(.{ .bool_not = .{ .operand = operand } }, .bool);
                    }
                    const int_like = self.isIntEx(oty) or
                        (!oty.isBuiltin() and self.module.types.get(oty) == .error_set);
                    if (int_like) {
                        const zero = self.builder.constInt(0, oty);
                        break :blk2 self.builder.emit(.{ .cmp_eq = .{ .lhs = operand, .rhs = zero } }, .bool);
                    }
                    if (self.diagnostics) |d| {
                        d.addFmt(.err, node.span, "'!' needs a bool, integer, or error operand; got '{s}'", .{self.formatTypeName(oty)});
                    }
                    break :blk2 self.builder.constBool(false);
                },
                .bit_not => self.builder.emit(.{ .bit_not = .{ .operand = operand } }, self.inferExprType(uop.operand)),
                .xx => self.lowerXX(operand, uop.operand),
                .address_of => blk2: {
                    const inner_ty = self.inferExprType(uop.operand);
                    const ptr_ty = self.module.types.ptrTo(inner_ty);
                    break :blk2 self.builder.emit(.{ .addr_of = .{ .operand = operand } }, ptr_ty);
                },
            };
        },

        .if_expr => |ie| self.lowerIfExpr(&ie),
        .match_expr => |me| self.lowerMatch(&me),
        .while_expr => |we| self.lowerWhile(&we),
        .for_expr => |fe| self.lowerFor(&fe),
        .break_expr => self.lowerBreak(node.span),
        .continue_expr => self.lowerContinue(node.span),
        .call => |c| self.lowerCall(&c),
        .ffi_intrinsic_call => |fic| self.lowerFfiIntrinsicCall(&fic),
        .field_access => |fa| self.lowerFieldAccess(&fa, node.span),
        .struct_literal => |sl| self.lowerStructLiteral(&sl, node.span),
        .array_literal => |al| self.lowerArrayLiteral(&al),
        .index_expr => |ie| self.lowerIndexExpr(&ie),
        .slice_expr => |se| self.lowerSliceExpr(&se),
        .lambda => |lam| self.lowerLambda(&lam),
        .force_unwrap => |fu| self.lowerForceUnwrap(&fu),
        .null_coalesce => |nc| self.lowerNullCoalesce(&nc),
        .deref_expr => |de| self.lowerDerefExpr(&de),

        // Postfix cast `expr.(T)` (aggregate ladder Step 4). A
        // statically-typed receiver converts through the explicit-target
        // `xx` engine — resolve T, lower the operand under it (literals
        // adopt the target exactly as they do for `x : T = xx v`), then
        // lowerXX with T as the destination. One engine, not a fourth
        // cast. A type-erased receiver (`any` / protocol value) is the
        // CHECKED-assertion regime — S4.2; refused loudly until it lands.
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
                    // Assertion regime through the chain: soft target →
                    // conflating maybe-helper; concrete target unconsumed →
                    // panic helper (consumers claim the failable form via
                    // desugarErasedAssert before reaching this arm).
                    const helper: []const u8 = if (pc.type_expr.data == .optional_type_expr) "__sx_chain_cast_maybe" else "__sx_chain_cast_or_panic";
                    const targ_node = if (pc.type_expr.data == .optional_type_expr) pc.type_expr.data.optional_type_expr.inner_type else pc.type_expr;
                    const callee_node = Node{ .data = .{ .identifier = .{ .name = helper } }, .span = node.span, .source_file = node.source_file };
                    const args = self.alloc.dupe(*Node, &.{ pc.operand, targ_node }) catch unreachable;
                    const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = args };
                    break :blk self.lowerCall(&syn_call);
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
                self.target_type = dst;
                const converted = self.lowerXX(unwrapped, pc.operand);
                self.target_type = saved_target;
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
            // An `any` receiver is the checked-assertion regime. Reaching
            // THIS arm means no graceful consumer claimed it (`try` / `or` /
            // `catch` desugar their direct assertion operands via
            // desugarErasedAssert) — so this is the UNCONSUMED form:
            // panic on mismatch (the deliberate carve-out from the
            // unconsumed-failable rule, scoped to assertion forms).
            if (self.inferExprType(pc.operand) == .any) {
                // `av.(AnyRaw)` is the raw-view RETRIEVAL — the view's own
                // {data, type_id} words, built field-wise; NOT an
                // assertion about the boxed payload. POSTFIX-only:
                // `xx av` keeps the unbox meaning for every target
                // (AnyRaw included) — the assert helpers' generic
                // `xx av` must stay universal. Name-and-shape gated,
                // like ProtocolRaw on a protocol receiver.
                raw_view: {
                    if (pc.alloc_arg != null) break :raw_view;
                    const tname: []const u8 = switch (pc.type_expr.data) {
                        .identifier => |id| id.name,
                        .type_expr => |te| te.name,
                        else => "",
                    };
                    if (!std.mem.eql(u8, tname, "AnyRaw")) break :raw_view;
                    const raw_dst = self.resolveTypeArg(pc.type_expr);
                    if (raw_dst == .unresolved or !self.coercionResolver().isAnyRawDst(raw_dst))
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
                // `.(?T)` is the SOFT assertion: mismatch is a value
                // (`null`), never a failure — the optional IS the check.
                // The asserted type is the INNER T; the result is `?T`.
                if (pc.type_expr.data == .optional_type_expr) {
                    const callee_node = Node{ .data = .{ .identifier = .{ .name = "__sx_cast_maybe" } }, .span = node.span, .source_file = node.source_file };
                    const args = self.alloc.dupe(*Node, &.{ pc.operand, pc.type_expr.data.optional_type_expr.inner_type }) catch unreachable;
                    const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = args };
                    break :blk self.lowerCall(&syn_call);
                }
                const callee_node = Node{ .data = .{ .identifier = .{ .name = "__sx_cast_or_panic" } }, .span = node.span, .source_file = node.source_file };
                const args = self.alloc.dupe(*Node, &.{ pc.operand, pc.type_expr }) catch unreachable;
                const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = args };
                break :blk self.lowerCall(&syn_call);
            }
            // A PROTOCOL receiver with a concrete (non-recovery) target is
            // the checked DOWNCAST: with the type_id word (RTTI Option B)
            // it is exactly the any assertion over the value's
            // {ctx, type_id} prefix view — the operand wraps in an
            // `xx …: any` (the modeled protocol_to_any conversion) and the
            // SAME helpers serve all three temperaments. Recovery /
            // conversion targets (p.(*T), p.(ProtocolRaw), p.(any),
            // re-erasure to another protocol) fall through to lowerXX.
            {
                const recv_ty = self.inferExprType(pc.operand);
                const recv_erased = self.getProtocolInfo(recv_ty) != null;
                if (recv_erased) delegate: {
                    const full_dst = self.resolveTypeArg(pc.type_expr);
                    if (full_dst == .unresolved) break :delegate; // diagnosed below
                    switch (self.coercionResolver().classifyXX(recv_ty, full_dst)) {
                        .protocol_to_pointer, .protocol_to_raw, .protocol_to_any, .no_op, .erase_protocol, .erase_protocol_wrap => {},
                        else => {
                            const xx_node = self.alloc.create(Node) catch unreachable;
                            xx_node.* = Node{ .data = .{ .unary_op = .{ .op = .xx, .operand = pc.operand } }, .span = pc.operand.span, .source_file = pc.operand.source_file };
                            if (pc.type_expr.data == .optional_type_expr) {
                                const callee_node = Node{ .data = .{ .identifier = .{ .name = "__sx_cast_maybe" } }, .span = node.span, .source_file = node.source_file };
                                const args = self.alloc.dupe(*Node, &.{ xx_node, pc.type_expr.data.optional_type_expr.inner_type }) catch unreachable;
                                const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = args };
                                break :blk self.lowerCall(&syn_call);
                            }
                            const callee_node = Node{ .data = .{ .identifier = .{ .name = "__sx_cast_or_panic" } }, .span = node.span, .source_file = node.source_file };
                            const args = self.alloc.dupe(*Node, &.{ xx_node, pc.type_expr }) catch unreachable;
                            const syn_call = ast.Call{ .callee = @constCast(&callee_node), .args = args };
                            break :blk self.lowerCall(&syn_call);
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
            // Owning erasure `expr.(P)` / `expr.(P, alloc)`: a PROTOCOL
            // target with a CONCRETE (or pointer) receiver OWNS — copy /
            // snapshot / promotion per receiver shape; #identity targets
            // keep the borrow. Erased receivers (any / protocol) were
            // handled above; a protocol receiver reaching here is the
            // recovery/re-erasure family and stays on lowerXX.
            {
                const recv_t = self.inferExprType(pc.operand);
                const recv_erased = recv_t == .any or self.getProtocolInfo(recv_t) != null;
                if (!recv_erased and self.getProtocolInfo(dst) != null) {
                    break :blk self.lowerOwningErasure(&pc, dst, node.span);
                }
            }
            if (pc.alloc_arg != null) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, node.span, "an allocator argument only applies to an owning protocol erasure — '.({s}, alloc)' needs a protocol target and a concrete receiver", .{self.formatTypeName(dst)});
                break :blk self.builder.constUndef(dst);
            }
            const saved_target = self.target_type;
            self.target_type = dst;
            defer self.target_type = saved_target;
            // An explicit cast requests the conversion, truncation
            // included — literal operands skip the fits-check (same
            // stance as the `xx` unary arm).
            const saved_fit = self.suppress_int_fit_check;
            self.suppress_int_fit_check = true;
            const operand = self.lowerExpr(pc.operand);
            self.suppress_int_fit_check = saved_fit;
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

        // `#jni_env(env) { body }` in expression position — the block's
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
            var block_scope = Scope.init(self.alloc, self.scope);
            const saved_scope = self.scope;
            self.scope = &block_scope;
            const saved_defer_len = self.defer_stack.items.len;
            defer {
                self.emitBlockDefers(saved_defer_len);
                self.scope = saved_scope;
                block_scope.deinit();
            }
            // This block sits in value position (lowerExpr is reached only
            // for value contexts — statement blocks go through lowerBlock).
            // If its last expression's value is discarded by a `;`, the
            // surrounding expression has no value to use: report it.
            if (!blk.produces_value and blk.discarded_semi != null) {
                if (self.diagnostics) |diags| {
                    diags.addFmt(.err, blk.discarded_semi.?, "this block is used as a value but its last expression's value is discarded by this `;` — drop the `;`", .{});
                }
            }
            // A block in expression position yields its last statement's
            // value only when it produces one (no trailing `;`); otherwise
            // it runs as statements and evaluates to void.
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
                // result is dropped (issue 0259). Mirrors `lowerBlockValue`.
                self.force_block_value = true;
                // The last statement may itself terminate the block (a trailing
                // `return`/`break`/`continue` statement — e.g. an `if`-arm
                // `{ return -1; }` in value position). In that case there is no
                // value to yield AND appending a `const_int(0, .void)` placeholder
                // would land a non-terminator instruction AFTER the terminator,
                // producing invalid "terminator in the middle of a block" IR
                // (issue 0269). Return `Ref.none` — the caller detects the
                // termination via `currentBlockHasTerminator()` and never reads it.
                const last_val = self.tryLowerAsExpr(blk.stmts[blk.stmts.len - 1]) orelse
                    (if (self.currentBlockHasTerminator()) Ref.none else self.builder.constInt(0, .void));
                self.force_block_value = saved_fbv;
                break :blk last_val;
            }
            for (blk.stmts) |stmt| {
                self.lowerStmt(stmt);
            }
            // Same terminator guard as the produces-value path above: a block whose
            // statements terminated it (trailing `return`/`break`/`continue`) must
            // not get a `const_int` placeholder appended after the terminator.
            break :blk if (self.currentBlockHasTerminator()) Ref.none else self.builder.constInt(0, .void);
        },

        // type_expr can appear as a variable reference when the name collides
        // with a builtin type name (e.g. i2, u8). Check scope first.
        .type_expr => |te| blk: {
            if (self.scope) |scope| {
                if (scope.lookup(te.name)) |binding| {
                    if (binding.is_alloca) {
                        break :blk self.builder.load(binding.ref, binding.ty);
                    }
                    break :blk binding.ref;
                }
            }
            if (self.program_index.global_names.get(te.name)) |gi| {
                break :blk self.builder.emit(.{ .global_get = gi.id }, gi.ty);
            }
            // Type literal in expression position → first-class
            // `const_type` Value (i64 = TypeId.index()). Makes
            // `t : Type = f64;` store a real TypeId; lets
            // `t == f64` icmp at runtime against the same TypeId.
            if (self.isKnownTypeName(te.name)) {
                const ty = type_bridge.resolveAstType(node, &self.module.types, &self.program_index.type_alias_map, &self.program_index.module_const_map);
                break :blk self.builder.constType(ty);
            }
            break :blk self.emitError(te.name, node.span);
        },

        // Compound type literals (`*T`, `[]T`, `[*]T`, `?T`, `[N]T`, fn types)
        // in expression position are first-class `Type` values, exactly like
        // the named form above (`t : Type = *i64;` ↔ `t : Type = f64;`). Also
        // the path a static `cast(*i64) v` type argument takes — call args are
        // lowered before the cast handler inspects the AST (issue 0118).
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
        .caller_location => self.lowerCallerLocation(node),
        .asm_expr => |ae| self.lowerAsmExpr(&ae, node.span),
        else => self.emitError("unknown_expr", node.span),
    };
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
    return self.module.types.intern(.{ .tuple = .{
        .fields = self.alloc.dupe(TypeId, fields.items) catch unreachable,
        .names = if (has_names) self.alloc.dupe(types.StringId, names.items) catch unreachable else null,
    } });
}

/// Inline assembly lowering. Phase B (partial): validate the asm shape in the
/// compile path with specific named diagnostics, THEN bail on the not-yet-
/// implemented codegen so the user sees the real problem first (the IR op +
/// LLVM emit land in Phases C–E; result-type derivation + the auto-naming rule
/// move to the expression typer once lowering produces a real value). Always
/// returns a placeholder Ref so `hasErrors()` aborts the build on whichever
/// diagnostic fired (CLAUDE.md no-silent-arm).
pub fn lowerAsmExpr(self: *Lowering, ae: *const ast.AsmExpr, span: ast.Span) Ref {
    const diags = self.diagnostics orelse return self.emitPlaceholder("inline_asm");

    // (1) The template must be a compile-time-known string (a `"..."` literal or
    // a `#string` heredoc), not a runtime expression.
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
                // `@place` lowers to its address (a pointer); the asm result is
                // stored through it. The stored type is the pointee.
                operand_ref = self.lowerExpr(op.payload);
                const pty = self.inferExprType(op.payload);
                out_ty = if (!pty.isBuiltin()) blk: {
                    const info = self.module.types.get(pty);
                    break :blk if (info == .pointer) info.pointer.pointee else .unresolved;
                } else .unresolved;
                if (out_ty == .unresolved) {
                    diags.addFmt(.err, span, "asm `-> @place` output target must be an addressable place", .{});
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

    // Template text RAW — no sx escape processing (matches `#string` literal
    // bytes; the `%[name]`/`%%`/`$` rewrite happens at emit). §II.11.
    const template_text = ae.template.data.string_literal.raw;

    return self.builder.emit(.{ .inline_asm = .{
        .template = self.module.types.internString(template_text),
        .operands = ir_ops,
        .clobbers = ir_clobbers,
        .has_side_effects = ae.is_volatile,
    } }, result_ty);
}

/// If `node` names a `for xs: (*x)` by-ref capture (an `*elem`), returns
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
///     and `error_set` (a u32 tag) — both reach condBr as a plain integer
///   • pointers: `*T` / `[*]T` / `cstring` (compared against null)
///   • `optional` — the caller emits `optional_has_value`
/// Everything else (float, void, string, any, type_value, struct/union/tuple/
/// array/slice/vector/function/closure/protocol/pack) reaches condBr as a
/// non-comparable aggregate or a value with no truthiness, and previously got
/// silently folded truthy then `@panic`d in the backend (issue 0164). Such a
/// condition is a type error — see `checkConditionType`.
fn isValidConditionType(self: *Lowering, ty: TypeId) bool {
    if (ty == .unresolved) return true; // already-diagnosed elsewhere; don't double-report
    return switch (self.module.types.get(ty)) {
        .bool, .signed, .unsigned, .usize, .isize => true,
        .pointer, .many_pointer, .cstring => true,
        .@"enum", .error_set => true,
        .optional => true,
        else => false,
    };
}

/// Emit a located type error when `ty` cannot be used as a branch condition
/// (see `isValidConditionType`). Returns `true` if the type is valid (caller
/// proceeds normally), `false` if a diagnostic was emitted (caller should
/// recover with a placeholder bool so lowering doesn't crash before the
/// diagnostic surfaces). This is the lowering-time replacement for the
/// backend `@panic` in `emitCondBr` (issue 0164): the type and span are both
/// available here, so we report a clean compile-time error instead.
pub fn checkConditionType(self: *Lowering, ty: TypeId, span: ast.Span) bool {
    if (isValidConditionType(self, ty)) return true;
    if (self.diagnostics) |d| d.addFmt(.err, span, "condition must be a bool, integer, pointer, or optional, but has type '{s}'", .{self.formatTypeName(ty)});
    return false;
}

/// Lower `node` as a boolean condition. If its type is an optional, reduce
/// it to its has_value flag (presence-as-truth) — same rule as `if opt`/
/// `while opt`. Without this, a bare optional operand reaches a condBr/phi as
/// a `{T,i1}` aggregate and folds truthy (issue 0164). Returns an i1/bool Ref.
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
    if (!ty.isBuiltin() and self.module.types.get(ty) == .optional) {
        return self.builder.emit(.{ .optional_has_value = .{ .operand = v } }, .bool);
    }
    return v;
}

pub fn lowerBinaryOp(self: *Lowering, bop: *const ast.BinaryOp) Ref {
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
        // A failable `or` (value-terminator or chain) routes to the error-
        // handling lowering, not the optional/boolean unwrap below. Detected
        // structurally (a `try`-chain's value type is non-failable `T`, so a
        // type-only `exprIsFailable(lhs)` would miss nested chains).
        if (self.orIsFailableChain(bop)) {
            return self.lowerFailableOr(bop);
        }
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

    // Type-literal comparison fold: when both sides are type-shaped
    // AST nodes (`i64`, `*u8`, `?T`, `[3]f64`, etc.) OR resolve to
    // a static TypeId at lower time (`type_of(x)` for any
    // statically-typed `x`), resolve each and emit a `const_bool`.
    // Same semantic as `type_eq(A, B)` but using the standard `==`
    // operator — the user's intuition. Without the fold, both
    // sides lower as `const_type` undef-i64 and the runtime icmp
    // returns garbage.
    if (bop.op == .eq or bop.op == .neq) {
        if (self.isStaticTypeRef(bop.lhs) and self.isStaticTypeRef(bop.rhs)) {
            const lhs_ty = self.resolveTypeArg(bop.lhs);
            const rhs_ty = self.resolveTypeArg(bop.rhs);
            const eq_result = lhs_ty == rhs_ty;
            return self.builder.constBool(if (bop.op == .eq) eq_result else !eq_result);
        }
    }

    // `==`/`!=` with an `any` operand is REFUSED (Odin parity: no binary
    // ops are defined on `any`). An `any` is a type-erased BORROW
    // `{tag, data-pointer}` — the only comparable words are the view
    // address (accidental pointer identity) — so there is no meaningful
    // language-level equality. Unbox to a typed value first, or compare
    // `type_of(av)` for tag questions. (Supersedes the issue-0199 arm,
    // which compared the old value-in-payload words.)
    if (bop.op == .eq or bop.op == .neq) {
        const lhs_ty = self.inferExprType(bop.lhs);
        const rhs_ty = self.inferExprType(bop.rhs);
        if ((lhs_ty == .any or rhs_ty == .any) and
            lhs_ty != .unresolved and rhs_ty != .unresolved and
            lhs_ty != .void and rhs_ty != .void)
        {
            if (self.diagnostics) |d| {
                d.addFmt(.err, ast.Span{ .start = bop.lhs.span.start, .end = bop.rhs.span.end }, "cannot compare an 'any' value with '{s}': an 'any' is a type-erased borrow, so only its view address could be compared — unbox it first (checked 'av.(T)' or unchecked 'xx av' with the concrete type), or compare 'type_of(av)' against a type", .{if (bop.op == .eq) "==" else "!="});
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

    // Error-set equality: an error-set value compares only with an
    // `error.X` tag literal or another error-set value. Comparing to a raw
    // integer is a type error (coerce with `xx`). `e == error.X` resolves
    // X against e's set and validates membership.
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
    var lhs = self.lowerExpr(bop.lhs);
    // A `for xs: (*x)` capture is a pointer; in a value position (here, an
    // operand) it auto-derefs to the element.
    const lhs_ref_pointee = self.refCapturePointee(bop.lhs);
    if (lhs_ref_pointee) |p| lhs = self.builder.load(lhs, p);
    // Set target_type from LHS so enum literals on RHS resolve correctly.
    // When the LHS isn't statically inferable (e.g. `#objc_call(...)`), use
    // the lowered operand's concrete type rather than a guess.
    const lhs_ty = blk: {
        if (lhs_ref_pointee) |p| break :blk p;
        const it = self.inferExprType(bop.lhs);
        break :blk if (it == .unresolved) self.builder.getRefType(lhs) else it;
    };
    const saved_tt = self.target_type;
    if (lhs_ty != .void) {
        if (!lhs_ty.isBuiltin()) {
            const lhs_info = self.module.types.get(lhs_ty);
            if (lhs_info == .@"enum" or lhs_info == .@"union" or lhs_info == .tagged_union) {
                self.target_type = lhs_ty;
            }
        } else if (lhs_ty == .f32 or lhs_ty == .f64) {
            self.target_type = lhs_ty;
        }
    }
    // In a comparison, an anonymous positional literal on the RHS is typed
    // from the LHS just like an enum shorthand. This also keeps the following
    // `{` available as the if body after the parser's issue-0246 brace fix.
    if (bop.rhs.data == .struct_literal and
        bop.rhs.data.struct_literal.struct_name == null and
        bop.rhs.data.struct_literal.type_expr == null)
    {
        self.target_type = lhs_ty;
    }
    var rhs = self.lowerExpr(bop.rhs);
    const rhs_ref_pointee = self.refCapturePointee(bop.rhs);
    if (rhs_ref_pointee) |p| rhs = self.builder.load(rhs, p);
    self.target_type = saved_tt;
    // Result type follows the shared promotion rule: an int LHS with a
    // float RHS promotes to the float (`i64 * f32` → `f32`); vectors /
    // structs keep the LHS type. `inferExprType` reuses the same helper
    // so static typing agrees with the value produced here.
    const rhs_inferred = rhs_ref_pointee orelse self.inferExprType(bop.rhs);
    var ty = arithResultType(lhs_ty, rhs_inferred);

    // Auto-unwrap optional operands for arithmetic/comparison — ONLY when the
    // operand is PROVEN present by flow narrowing (issue 0185, the operand-side
    // sibling of 0179). An un-narrowed `?T` operand used to unwrap
    // UNCONDITIONALLY, so a null operand silently became its zero payload
    // (`null + 10` → `10`, no diagnostic). `lowerIdentifier` tags a
    // guard-narrowed local's loaded `Ref` into `narrowed_refs`; an un-narrowed
    // optional operand is rejected loudly (then still unwrapped so the IR stays
    // well-formed — `hasErrors()` aborts before codegen). Presence tests
    // (`x == null` / `x != null`) returned early above, so they're unaffected.
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        if (info == .optional) {
            if (!self.narrowed_refs.contains(lhs)) self.diagOptionalOperand(ty, bop.lhs.span);
            ty = info.optional.child;
            lhs = self.builder.emit(.{ .optional_unwrap = .{ .operand = lhs } }, ty);
        }
    }
    const rhs_ty = rhs_ref_pointee orelse self.inferExprType(bop.rhs);
    if (!rhs_ty.isBuiltin()) {
        const rhs_info = self.module.types.get(rhs_ty);
        if (rhs_info == .optional) {
            if (!self.narrowed_refs.contains(rhs)) self.diagOptionalOperand(rhs_ty, bop.rhs.span);
            rhs = self.builder.emit(.{ .optional_unwrap = .{ .operand = rhs } }, rhs_info.optional.child);
        }
    }

    // String comparison: use str_eq/str_ne (memcmp-based) instead of pointer comparison
    if (ty == .string and (bop.op == .eq or bop.op == .neq)) {
        return if (bop.op == .eq)
            self.builder.emit(.{ .str_eq = .{ .lhs = lhs, .rhs = rhs } }, .bool)
        else
            self.builder.emit(.{ .str_ne = .{ .lhs = lhs, .rhs = rhs } }, .bool);
    }

    // Non-comparable aggregate `==` / `!=` guard (issue 0233).
    //
    // An untagged `union { ... }` and a fixed `[N]T` array are raw byte /
    // element aggregates with NO defined value-equality: a union's inactive-
    // variant + padding bytes are unspecified, so a byte-wise `icmp` over the
    // `[N x i8]` union storage (or `[N x T]` array storage) is both semantically
    // wrong AND rejected by the LLVM verifier ("Invalid operand types for ICmp").
    // Reject at lower time — where the span and the named type are available —
    // with a located diagnostic + a hint to compare a specific variant/element
    // instead, rather than emitting invalid IR downstream. Tagged unions (compare
    // by tag), payload-less enums, tuples, strings, slices, and optionals all have
    // their own valid compare paths and are unaffected.
    if ((bop.op == .eq or bop.op == .neq) and !ty.isBuiltin()) {
        const agg_info = self.module.types.get(ty);
        const hint: ?[]const u8 = switch (agg_info) {
            .@"union" => "compare a specific variant field (e.g. `a.field == b.field`)",
            .array => "compare elements individually, or loop over the elements",
            else => null,
        };
        if (hint) |h| {
            if (self.diagnostics) |d| {
                const pid = d.addFmtId(.err, bop.lhs.span, "cannot compare '{s}' values with '{s}'", .{
                    self.formatTypeName(ty), binOpSymbol(bop.op),
                });
                d.addNote(pid, bop.lhs.span, h);
            }
            return self.emitPlaceholder("uncomparable-aggregate-eq");
        }
    }

    // Struct value equality (issue 0245). A user `struct` `==` / `!=` is a
    // recursive FIELD-WISE compare — the same element-wise policy the spec
    // already mandates for tuples (which share struct layout), and the only
    // shape that ignores padding bytes (a byte-wise compare would read the
    // unspecified pad between an `i8` and an `i64`). Do it at LOWER time, where
    // each field's TypeId + the operand span are available: emit a per-field
    // `cmp_eq`/`cmp_ne` against the field's OWN type (so a float field gets
    // fcmp, a string field str_eq, a nested struct recurses, a tagged-union
    // field tag-compares) and AND-reduce (`==`) / OR-reduce (`!=`). This keeps
    // the buggy `emit_llvm` struct arm (which only ever handled a 2-scalar-field
    // shape, silently dropped fields 2+, and mis-ICMP'd non-int fields) from
    // ever seeing a user struct — it now only sees the string/slice/tagged-union
    // `{ptr,len}` / `{tag,payload}` reductions it was actually written for.
    // Non-comparable sub-fields (untagged union, fixed array) are rejected with
    // the issue-0233 diagnostic, consistent with rejecting those shapes bare.
    if ((bop.op == .eq or bop.op == .neq) and !ty.isBuiltin()) {
        const eq_info = self.module.types.get(ty);
        if (eq_info == .@"struct" and !eq_info.@"struct".is_protocol) {
            const other_ty = if (rhs_ty == .unresolved) self.builder.getRefType(rhs) else rhs_ty;
            if (other_ty != ty) {
                if (self.diagnostics) |d| d.addFmt(.err, bop.rhs.span, "cannot compare values of distinct types '{s}' and '{s}'", .{
                    self.formatTypeName(ty), self.formatTypeName(other_ty),
                });
                return self.emitPlaceholder("distinct-struct-equality");
            }
            return self.lowerStructEquality(bop, lhs, rhs, ty);
        }
    }

    // Tuple operators
    if (!ty.isBuiltin()) {
        const lhs_info = self.module.types.get(ty);
        if (lhs_info == .tuple) {
            return self.lowerTupleOp(bop, lhs, rhs, ty);
        }
    }
    // Tuple membership: value in (tuple)
    if (bop.op == .in_op) {
        const rhs_ty_raw = self.inferExprType(bop.rhs);
        if (!rhs_ty_raw.isBuiltin()) {
            const rhs_info_raw = self.module.types.get(rhs_ty_raw);
            if (rhs_info_raw == .tuple) {
                return self.lowerTupleMembership(lhs, rhs, rhs_info_raw.tuple);
            }
        }
    }

    // Reject scalar ops on incompatible operand types (e.g.
    // `i64 + string`, `i64 < string`, `i64 & string`). The result type
    // `ty` is derived from the LHS, so without this the op lowers as
    // `<op> : <lhs>` and either reinterprets the RHS bytes (arithmetic
    // / bitwise → garbage) or feeds mismatched LLVM types to `icmp`
    // (ordering → verifier failure).
    {
        const group: enum { none, arith, ordering, bitwise } = switch (bop.op) {
            .add, .sub, .mul, .div, .mod => .arith,
            .lt, .lte, .gt, .gte => .ordering,
            .bit_and, .bit_or, .bit_xor, .shl, .shr => .bitwise,
            else => .none,
        };
        if (group != .none) {
            const eff_rhs_ty = blk: {
                if (rhs_ty == .unresolved) break :blk self.builder.getRefType(rhs);
                if (!rhs_ty.isBuiltin()) {
                    const ri = self.module.types.get(rhs_ty);
                    if (ri == .optional) break :blk ri.optional.child;
                }
                break :blk rhs_ty;
            };
            const ok = switch (group) {
                .arith => self.isArithOperand(ty) and self.isArithOperand(eff_rhs_ty),
                .ordering => self.isOrderingOperand(ty) and self.isOrderingOperand(eff_rhs_ty),
                .bitwise => self.isBitwiseOperand(ty) and self.isBitwiseOperand(eff_rhs_ty),
                .none => true,
            };
            if (!ok) {
                if (self.diagnostics) |diags| {
                    diags.addFmt(.err, bop.lhs.span, "cannot apply '{s}' to operands of type '{s}' and '{s}'", .{
                        binOpSymbol(bop.op), self.formatTypeName(ty), self.formatTypeName(eff_rhs_ty),
                    });
                }
                return self.emitPlaceholder("operand-type-mismatch");
            }
        }
    }

    // Comparison operand promotion. Arithmetic arms below carry the promoted
    // common type `ty` on the result op, so the LLVM emitter re-matches the
    // operands against it (`matchBinOpTypes`). Comparisons carry `.bool`
    // instead, so `emitCmp`/`emitCmpOrdered` only see the raw operand LLVM
    // types — and those only reconcile int↔int width (SExt/ZExt). A mixed
    // int-vs-float compare (`xx i < t`, i:i32 t:f32) or a two-float-width
    // compare (`f64 >= f32`) reaches the emitter with mismatched operands and
    // fails LLVM verification (issue 0146). Coerce each operand up to the
    // promoted common type HERE — `coerceToType` emits the SIToFP / FPExt /
    // width-ext — so the operands are already type-equal when the cmp is built.
    // Restricted to float `ty`: an int↔int compare is handled by the emitter,
    // and a non-numeric `ty` (struct/string/enum) has its own cmp path.
    switch (bop.op) {
        .eq, .neq, .lt, .lte, .gt, .gte => {
            if (Lowering.isFloat(ty)) {
                const lhs_ir = self.builder.getRefType(lhs);
                if (lhs_ir != ty and (Lowering.isFloat(lhs_ir) or self.isIntEx(lhs_ir))) {
                    lhs = self.coerceToType(lhs, lhs_ir, ty);
                }
                const rhs_ir = self.builder.getRefType(rhs);
                if (rhs_ir != ty and (Lowering.isFloat(rhs_ir) or self.isIntEx(rhs_ir))) {
                    rhs = self.coerceToType(rhs, rhs_ir, ty);
                }
            }
        },
        else => {},
    }

    return switch (bop.op) {
        .add => self.builder.add(lhs, rhs, ty),
        .sub => self.builder.sub(lhs, rhs, ty),
        .mul => self.builder.mul(lhs, rhs, ty),
        .div => self.builder.div(lhs, rhs, ty),
        .mod => self.builder.emit(.{ .mod = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .eq => self.builder.cmpEq(lhs, rhs),
        .neq => self.builder.emit(.{ .cmp_ne = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .lt => self.builder.cmpLt(lhs, rhs),
        .lte => self.builder.emit(.{ .cmp_le = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .gt => self.builder.cmpGt(lhs, rhs),
        .gte => self.builder.emit(.{ .cmp_ge = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .and_op => self.builder.emit(.{ .bool_and = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .or_op => self.builder.emit(.{ .bool_or = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .bit_and => self.builder.emit(.{ .bit_and = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .bit_or => self.builder.emit(.{ .bit_or = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .bit_xor => self.builder.emit(.{ .bit_xor = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .shl => self.builder.emit(.{ .shl = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .shr => self.builder.emit(.{ .shr = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .in_op => self.emitError("in_op", bop.lhs.span),
    };
}

/// Handle tuple binary ops: concat (+), repeat (*), comparison (==, !=, <, <=, >, >=)
pub fn lowerTupleOp(self: *Lowering, bop: *const ast.BinaryOp, lhs: Ref, rhs: Ref, lhs_ty: TypeId) Ref {
    const lhs_info = self.module.types.get(lhs_ty);
    const lhs_fields = lhs_info.tuple.fields;

    switch (bop.op) {
        .add => {
            // Tuple concatenation: (a, b) + (c, d) → (a, b, c, d)
            const rhs_ty = self.inferExprType(bop.rhs);
            const rhs_fields = if (!rhs_ty.isBuiltin()) blk: {
                const ri = self.module.types.get(rhs_ty);
                break :blk if (ri == .tuple) ri.tuple.fields else &[_]TypeId{};
            } else &[_]TypeId{};

            var all_fields = std.ArrayList(TypeId).empty;
            defer all_fields.deinit(self.alloc);
            var all_vals = std.ArrayList(Ref).empty;
            defer all_vals.deinit(self.alloc);

            for (lhs_fields, 0..) |f, i| {
                all_fields.append(self.alloc, f) catch unreachable;
                all_vals.append(self.alloc, self.builder.structGet(lhs, @intCast(i), f)) catch unreachable;
            }
            for (rhs_fields, 0..) |f, i| {
                all_fields.append(self.alloc, f) catch unreachable;
                all_vals.append(self.alloc, self.builder.structGet(rhs, @intCast(i), f)) catch unreachable;
            }

            const result_ty = self.module.types.intern(.{ .tuple = .{
                .fields = self.alloc.dupe(TypeId, all_fields.items) catch unreachable,
                .names = null,
            } });
            const owned = self.alloc.dupe(Ref, all_vals.items) catch unreachable;
            return self.builder.emit(.{ .tuple_init = .{ .fields = owned } }, result_ty);
        },
        .mul => {
            // Tuple repeat: (a, b) * 3 → (a, b, a, b, a, b)
            const count: usize = switch (bop.rhs.data) {
                .int_literal => |il| @intCast(@as(u64, @bitCast(il.value))),
                .char_literal => |cl| @intCast(@as(u64, @bitCast(cl.value))),
                else => 1,
            };

            var all_fields = std.ArrayList(TypeId).empty;
            defer all_fields.deinit(self.alloc);
            var all_vals = std.ArrayList(Ref).empty;
            defer all_vals.deinit(self.alloc);

            for (0..count) |_| {
                for (lhs_fields, 0..) |f, i| {
                    all_fields.append(self.alloc, f) catch unreachable;
                    all_vals.append(self.alloc, self.builder.structGet(lhs, @intCast(i), f)) catch unreachable;
                }
            }

            const result_ty = self.module.types.intern(.{ .tuple = .{
                .fields = self.alloc.dupe(TypeId, all_fields.items) catch unreachable,
                .names = null,
            } });
            const owned = self.alloc.dupe(Ref, all_vals.items) catch unreachable;
            return self.builder.emit(.{ .tuple_init = .{ .fields = owned } }, result_ty);
        },
        .eq, .neq => {
            // Element-wise equality (or single-element tuple vs scalar)
            const rhs_is_tuple = blk: {
                const rt = self.inferExprType(bop.rhs);
                if (!rt.isBuiltin()) {
                    break :blk self.module.types.get(rt) == .tuple;
                }
                break :blk false;
            };
            if (!rhs_is_tuple and lhs_fields.len == 1) {
                // Single-element tuple vs scalar: unwrap and compare
                const lf = self.builder.structGet(lhs, 0, lhs_fields[0]);
                const eq = self.builder.cmpEq(lf, rhs);
                return if (bop.op == .neq) self.builder.emit(.{ .bool_not = .{ .operand = eq } }, .bool) else eq;
            }
            var result = self.builder.constBool(true);
            for (lhs_fields, 0..) |f, i| {
                const lf = self.builder.structGet(lhs, @intCast(i), f);
                const rf = self.builder.structGet(rhs, @intCast(i), f);
                const eq = self.builder.cmpEq(lf, rf);
                result = self.builder.emit(.{ .bool_and = .{ .lhs = result, .rhs = eq } }, .bool);
            }
            return if (bop.op == .neq) self.builder.emit(.{ .bool_not = .{ .operand = result } }, .bool) else result;
        },
        .lt, .lte, .gt, .gte => {
            // Lexicographic comparison
            return self.lowerTupleLexCompare(bop.op, lhs, rhs, lhs_fields);
        },
        else => return self.builder.constInt(0, .i64),
    }
}

pub fn lowerTupleLexCompare(self: *Lowering, op: ast.BinaryOp.Op, lhs: Ref, rhs: Ref, fields: []const TypeId) Ref {
    // Lexicographic comparison using boolean logic.
    // (a0,a1) < (b0,b1) = (a0 < b0) || (a0 == b0 && a1 < b1)
    // (a0,a1) <= (b0,b1) = (a0 < b0) || (a0 == b0 && a1 <= b1)
    if (fields.len == 0) return self.builder.constBool(op == .lte or op == .gte);

    const n = fields.len;
    // Start with the last field using the actual op
    const lf_last = self.builder.structGet(lhs, @intCast(n - 1), fields[n - 1]);
    const rf_last = self.builder.structGet(rhs, @intCast(n - 1), fields[n - 1]);
    var result = switch (op) {
        .lt => self.builder.cmpLt(lf_last, rf_last),
        .lte => self.builder.emit(.{ .cmp_le = .{ .lhs = lf_last, .rhs = rf_last } }, .bool),
        .gt => self.builder.cmpGt(lf_last, rf_last),
        .gte => self.builder.emit(.{ .cmp_ge = .{ .lhs = lf_last, .rhs = rf_last } }, .bool),
        else => unreachable,
    };

    // Work backwards: result = (a[i] < b[i]) || (a[i] == b[i] && result)
    if (n > 1) {
        var i: usize = n - 1;
        while (i > 0) {
            i -= 1;
            const lf = self.builder.structGet(lhs, @intCast(i), fields[i]);
            const rf = self.builder.structGet(rhs, @intCast(i), fields[i]);
            const strict = if (op == .lt or op == .lte) self.builder.cmpLt(lf, rf) else self.builder.cmpGt(lf, rf);
            const eq = self.builder.cmpEq(lf, rf);
            const eq_and_rest = self.builder.emit(.{ .bool_and = .{ .lhs = eq, .rhs = result } }, .bool);
            result = self.builder.emit(.{ .bool_or = .{ .lhs = strict, .rhs = eq_and_rest } }, .bool);
        }
    }
    return result;
}

pub fn lowerTupleMembership(self: *Lowering, value: Ref, tuple: Ref, tuple_info: anytype) Ref {
    // value in (a, b, c) → value == a || value == b || value == c
    var result = self.builder.constBool(false);
    for (tuple_info.fields, 0..) |f, i| {
        const elem = self.builder.structGet(tuple, @intCast(i), f);
        const eq = self.builder.cmpEq(value, elem);
        result = self.builder.emit(.{ .bool_or = .{ .lhs = result, .rhs = eq } }, .bool);
    }
    return result;
}

/// Struct value equality (issue 0245): recursive field-wise `==` / `!=`.
///
/// Emits a per-field comparison against each field's OWN type, AND-reduces for
/// `==` (OR-reduces for `!=`), matching the tuple element-wise policy and the
/// natural "two structs are equal iff every field is equal" semantics. Padding
/// bytes are never read (that is exactly why field-wise beats a byte-compare).
///
/// A field that is not itself comparable — an untagged `union`, a fixed `[N]T`
/// array, or an `?T` optional — is rejected with a located diagnostic, mirroring
/// how those shapes are rejected as bare `==` operands (issues 0233 + the
/// optional-operand guard). The reduced per-field comparisons that DO get built
/// are scalar / pointer / string / slice / tagged-union / nested-struct — each
/// with its own valid lowering — so `emit_llvm`'s narrow struct arm never sees a
/// user struct.
pub fn lowerStructEquality(self: *Lowering, bop: *const ast.BinaryOp, lhs: Ref, rhs: Ref, ty: TypeId) Ref {
    const info = self.module.types.get(ty);
    const fields = info.@"struct".fields;

    // A zero-field struct compares equal to itself (vacuously — no fields to
    // differ). `==` → true, `!=` → false.
    if (fields.len == 0) return self.builder.constBool(bop.op == .eq);

    var result: ?Ref = null;
    var rejected = false;
    for (fields, 0..) |f, i| {
        const lf = self.builder.structGet(lhs, @intCast(i), f.ty);
        const rf = self.builder.structGet(rhs, @intCast(i), f.ty);
        const field_eq = self.lowerFieldEquality(lf, rf, f.ty, bop.lhs.span) orelse {
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
    return if (bop.op == .neq)
        self.builder.emit(.{ .bool_not = .{ .operand = eq_all } }, .bool)
    else
        eq_all;
}

/// Build a `bool` Ref for `lf == rf` where both are values of `field_ty`, the
/// per-field step of `lowerStructEquality`. Returns null (after emitting a
/// located diagnostic) for a field type that has no defined value-equality.
pub fn lowerFieldEquality(self: *Lowering, lf: Ref, rf: Ref, field_ty: TypeId, span: ast.Span) ?Ref {
    // Builtins (ints, floats, bool, pointers, enums-as-int, usize/isize,
    // cstring): a plain `cmp_eq`. The LLVM emitter picks fcmp for a float
    // operand and icmp otherwise off the operand's own type, so f32/f64 fields
    // get the correct ordered-equal compare with no special-casing here.
    if (field_ty.isBuiltin()) {
        // `string` is a fat `{ptr,len}` — a byte-wise `icmp` on it is invalid
        // IR; route to memcmp-based `str_eq` (the same path top-level string
        // `==` takes).
        if (field_ty == .string) {
            return self.builder.emit(.{ .str_eq = .{ .lhs = lf, .rhs = rf } }, .bool);
        }
        return self.builder.cmpEq(lf, rf);
    }

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
        .tuple => blk: {
            const elems = fi.tuple.fields;
            if (elems.len == 0) break :blk self.builder.constBool(true);
            var acc: ?Ref = null;
            var bad = false;
            for (elems, 0..) |et, j| {
                const nlf = self.builder.structGet(lf, @intCast(j), et);
                const nrf = self.builder.structGet(rf, @intCast(j), et);
                const sub = self.lowerFieldEquality(nlf, nrf, et, span) orelse {
                    bad = true;
                    continue;
                };
                acc = if (acc) |a| self.builder.emit(.{ .bool_and = .{ .lhs = a, .rhs = sub } }, .bool) else sub;
            }
            if (bad) break :blk null;
            break :blk acc.?;
        },
        // Tagged union: tag-only compare, matching bare tagged-union `==`. A
        // `cmp_eq` on the `{tag,[N x i8]}` value reaches emit_llvm's tag-only arm.
        .tagged_union => self.builder.cmpEq(lf, rf),
        // Slice (`{ptr,len}` fat pointer): pointer+len identity, same as bare
        // slice `==`. emit_llvm's 2-scalar-field arm handles it.
        .slice => self.builder.cmpEq(lf, rf),
        // Enum (payload-less, i-backed) and pointers-by-info: scalar identity.
        .@"enum", .pointer, .many_pointer => self.builder.cmpEq(lf, rf),
        // Non-comparable field types — reject with the issue-0233 policy. An
        // untagged union's inactive bytes are unspecified; a fixed array has no
        // defined value-equality (compare elements); an optional does not
        // implicitly compare (guard with `!= null` / unwrap first). Each mirrors
        // how the bare shape is rejected as a top-level `==` operand.
        .@"union", .array, .optional => blk: {
            const hint: []const u8 = switch (fi) {
                .@"union" => "compare a specific variant sub-field",
                .array => "compare elements individually, or loop over the elements",
                .optional => "an optional field does not compare; guard with '!= null' or unwrap first",
                else => unreachable,
            };
            if (self.diagnostics) |d| {
                const pid = d.addFmtId(.err, span, "cannot compare struct: field of type '{s}' has no value-equality", .{
                    self.formatTypeName(field_ty),
                });
                d.addNote(pid, span, hint);
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
                d.addFmt(.err, span, "cannot compare struct: field of type '{s}' has no value-equality", .{
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

    var refs = std.ArrayList(Ref).empty;
    defer refs.deinit(self.alloc);
    for (cc.operands) |op| {
        refs.append(self.alloc, self.lowerExpr(op)) catch unreachable;
    }

    var result = self.emitCmp(refs.items[0], refs.items[1], cc.ops[0]);

    var i: usize = 1;
    while (i < cc.ops.len) : (i += 1) {
        const next_cmp = self.emitCmp(refs.items[i], refs.items[i + 1], cc.ops[i]);
        result = self.builder.emit(.{ .bool_and = .{ .lhs = result, .rhs = next_cmp } }, .bool);
    }

    return result;
}

pub fn emitCmp(self: *Lowering, lhs: Ref, rhs: Ref, op: ast.BinaryOp.Op) Ref {
    return switch (op) {
        .eq => self.builder.cmpEq(lhs, rhs),
        .neq => self.builder.emit(.{ .cmp_ne = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .lt => self.builder.cmpLt(lhs, rhs),
        .lte => self.builder.emit(.{ .cmp_le = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        .gt => self.builder.cmpGt(lhs, rhs),
        .gte => self.builder.emit(.{ .cmp_ge = .{ .lhs = lhs, .rhs = rhs } }, .bool),
        else => self.builder.constBool(false),
    };
}
