const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const unescape = @import("../../unescape.zig");
const parser_mod = @import("../../parser.zig");
const comptime_vm = @import("../comptime_vm.zig");
const program_index_mod = @import("../program_index.zig");
const resolver_mod = @import("../resolver.zig");
const ModuleConstInfo = program_index_mod.ModuleConstInfo;

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;
const Function = inst_mod.Function;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;
const ConstFoldFrame = lower.ConstFoldFrame;
const constFoldFrameContains = lower.constFoldFrameContains;
const SourceConstCtx = lower.SourceConstCtx;
const resolveBuiltin = Lowering.resolveBuiltin;
const isFloat = Lowering.isFloat;

/// Try to convert an array literal's elements into a compile-time
/// ConstantValue.aggregate. `array_ty` is the array's resolved TypeId; its
/// element type drives type-aware serialization of struct-literal and
/// nested-array elements. Returns null if `array_ty` is not an array type or
/// any element is not a compile-time constant.
pub fn constArrayLiteral(self: *Lowering, elements: []const *const Node, array_ty: TypeId) ?inst_mod.ConstantValue {
    if (array_ty.isBuiltin()) return null;
    const elem_ty: TypeId = switch (self.module.types.get(array_ty)) {
        .array => |a| a.element,
        else => return null,
    };
    const vals = self.alloc.alloc(inst_mod.ConstantValue, elements.len) catch return null;
    for (elements, 0..) |elem, i| {
        vals[i] = self.constExprValue(elem, elem_ty) orelse return null;
    }
    return .{ .aggregate = vals };
}

/// Try to convert a single AST expression into a compile-time ConstantValue.
/// `expected_ty` is the destination element/field type — it lets aggregate
/// leaves (struct literals, nested arrays) serialize with the correct shape
/// rather than collapsing to null. Returns null if the
/// expression is not constant-foldable here.
pub fn constExprValue(self: *Lowering, expr: *const Node, expected_ty: TypeId) ?inst_mod.ConstantValue {
    return switch (expr.data) {
        // An int element in a FLOAT destination converts exactly (the
        // int+float promotion rule, element-wise — `[2]f64 : .[1, 2.5]`).
        .int_literal => |il| if (isFloat(expected_ty))
            .{ .float = @floatFromInt(il.value) }
        else
            .{ .int = il.value },
        .char_literal => |cl| if (isFloat(expected_ty))
            .{ .float = @floatFromInt(cl.value) }
        else
            .{ .int = cl.value },
        .bool_literal => |bl| .{ .boolean = bl.value },
        // A float into an INTEGER destination follows the implicit
        // narrowing rule: an integral float folds to its int, a
        // non-integral one is a compile error (not a silent bit-coerce).
        .float_literal => |fl| blk: {
            if (self.isIntEx(expected_ty)) {
                if (program_index_mod.floatToIntExact(fl.value)) |iv| break :blk inst_mod.ConstantValue{ .int = iv };
                self.diagNonIntegralNarrow(expr.span, fl.value, expected_ty);
                break :blk null;
            }
            break :blk inst_mod.ConstantValue{ .float = fl.value };
        },
        .string_literal => |sl| .{ .string = self.module.types.internString(sl.raw) },
        .undef_literal => .zeroinit,
        // A `null` in a pointer (or optional-pointer) field is a
        // compile-time constant: the zero pointer. Without this arm the
        // aggregate is wrongly rejected as non-constant.
        .null_literal => .null_val,
        .unary_op => |uo| switch (uo.op) {
            .negate => switch (uo.operand.data) {
                .int_literal => |il| if (isFloat(expected_ty))
                    .{ .float = @floatFromInt(-il.value) }
                else
                    .{ .int = -il.value },
                .float_literal => |fl| .{ .float = -fl.value },
                else => null,
            },
            else => null,
        },
        .array_literal => |al| self.constArrayLiteral(al.elements, expected_ty),
        .struct_literal => |sl| self.constStructLiteral(&sl, expected_ty),
        // An enum tag as an aggregate leaf (`[2]Color = .[.green, .blue]`, or
        // an enum field inside a global struct) serializes to its tag int
        // against the leaf's declared enum type.
        .enum_literal => |el| self.constEnumLiteral(&el, expected_ty, expr.span),
        // Any other shape: a compile-time CONST EXPRESSION over named consts
        // and const-aggregate leaves (`r = K + 1`, `g = LIT.r`, `b = K[1]`)
        // serializes through the shared folders — source-aware, like every
        // const fold. A non-foldable expression (a call, a runtime read)
        // stays null: the caller keeps its fallback (inline re-lowering for
        // struct consts, a loud diagnostic for globals/array consts).
        else => blk: {
            const ctx = SourceConstCtx{ .lowering = self, .frame = null };
            if (self.isIntEx(expected_ty)) {
                if (program_index_mod.evalConstIntExpr(expr, ctx)) |v| break :blk inst_mod.ConstantValue{ .int = v };
            }
            if (isFloat(expected_ty)) {
                if (program_index_mod.evalConstFloatExpr(expr, ctx)) |v| break :blk inst_mod.ConstantValue{ .float = v };
                if (program_index_mod.evalConstIntExpr(expr, ctx)) |v| break :blk inst_mod.ConstantValue{ .float = @floatFromInt(v) };
            }
            break :blk null;
        },
    };
}

/// Serialize an enum-literal initializer (`.Variant`) into a static
/// `ConstantValue.int` holding the variant's tag value, resolved against the
/// destination enum type `ty`. The tag respects explicit variant values
/// (`enum { a; b :: 5; }`); the enum's backing width is applied by the
/// const emitters via the destination type's LLVM type. Plain enums only —
/// a tagged-union or non-enum destination is diagnosed loudly rather than
/// silently zero-initialized.
pub fn constEnumLiteral(self: *Lowering, el: *const ast.EnumLiteral, ty: TypeId, span: ast.Span) ?inst_mod.ConstantValue {
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        if (info == .@"enum") {
            const e = info.@"enum";
            const name_id = self.module.types.internString(el.name);
            for (e.variants, 0..) |variant, i| {
                if (variant != name_id) continue;
                if (e.explicit_values) |vals| {
                    if (i < vals.len) return .{ .int = vals[i] };
                }
                return .{ .int = @intCast(i) };
            }
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "'.{s}' is not a variant of enum '{s}'", .{ el.name, self.module.types.getString(e.name) });
            return null;
        }
    }
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "enum-literal global initializer '.{s}' is only supported for a plain enum destination type", .{el.name});
    return null;
}

/// Try to convert a struct literal into a compile-time ConstantValue.aggregate of the
/// struct's fields in declaration order, filling missing fields from the struct's
/// field defaults. Returns null if any value is not constant-foldable.
pub fn constStructLiteral(self: *Lowering, sl: *const ast.StructLiteral, ty: TypeId) ?inst_mod.ConstantValue {
    if (ty.isBuiltin()) return null;
    const ti = self.module.types.get(ty);
    if (ti != .@"struct") return null;
    const struct_fields = ti.@"struct".fields;
    const struct_name = self.module.types.getString(ti.@"struct".name);
    const field_defaults: []const ?*const Node = self.struct_defaults_map.get(struct_name) orelse &.{};

    const has_names = sl.field_inits.len > 0 and sl.field_inits[0].name != null;

    const vals = self.alloc.alloc(inst_mod.ConstantValue, struct_fields.len) catch return null;
    for (struct_fields, 0..) |sf, fi| {
        const sf_name = self.module.types.getString(sf.name);
        const init_expr: ?*const Node = blk: {
            if (has_names) {
                for (sl.field_inits) |init_pair| {
                    if (init_pair.name) |n| {
                        if (std.mem.eql(u8, n, sf_name)) break :blk init_pair.value;
                    }
                }
            } else if (fi < sl.field_inits.len) {
                break :blk sl.field_inits[fi].value;
            }
            if (fi < field_defaults.len) break :blk field_defaults[fi];
            break :blk null;
        };
        if (init_expr) |e| {
            vals[fi] = self.constExprValue(e, sf.ty) orelse return null;
        } else {
            vals[fi] = .zeroinit;
        }
    }
    return .{ .aggregate = vals };
}

/// Evaluate a compile-time condition for `inline if`.
/// Handles target/value comparisons and short-circuit `and` / `or` chains.
pub fn evalComptimeCondition(self: *Lowering, node: *const Node) ?bool {
    return evalComptimeConditionDepth(self, node, 0);
}

fn evalComptimeConditionDepth(self: *Lowering, node: *const Node, depth: u32) ?bool {
    // Const chains recurse through module_const_map; a (rejected-elsewhere
    // but representable) self-referential const must not loop here.
    if (depth > 16) return null;
    switch (node.data) {
        .bool_literal => |bl| return bl.value,
        // A bare identifier naming a module const folds through the const's
        // value expression (`ENABLED :: false`, chains, `F :: OS == .ios`).
        // Only a bool-shaped fold counts; anything else stays runtime.
        .identifier => |id| {
            const info = self.program_index.module_const_map.get(id.name) orelse return null;
            return evalComptimeConditionDepth(self, info.value, depth + 1);
        },
        .binary_op => {},
        else => return null,
    }
    const bo = &node.data.binary_op;
    if (bo.op == .and_op) {
        const lhs = evalComptimeConditionDepth(self, bo.lhs, depth + 1) orelse return null;
        if (!lhs) return false;
        return evalComptimeConditionDepth(self, bo.rhs, depth + 1);
    }
    if (bo.op == .or_op) {
        const lhs = evalComptimeConditionDepth(self, bo.lhs, depth + 1) orelse return null;
        if (lhs) return true;
        return evalComptimeConditionDepth(self, bo.rhs, depth + 1);
    }
    if (bo.op != .eq and bo.op != .neq) return null;

    // LHS must be an identifier that's in comptime_constants
    const name = switch (bo.lhs.data) {
        .identifier => |id| id.name,
        else => return null,
    };
    const cv = self.comptime_constants.get(name) orelse return null;

    switch (cv) {
        .enum_tag => |et| {
            // RHS must be an enum literal (.variant)
            const variant_name = switch (bo.rhs.data) {
                .enum_literal => |el| el.name,
                else => return null,
            };
            // Look up variant index in the enum type
            const enum_info = self.module.types.get(et.ty);
            if (enum_info != .@"enum") return null;
            const variant_idx = self.findVariantIndex(enum_info.@"enum".variants, variant_name);
            const result = et.tag == variant_idx;
            return if (bo.op == .eq) result else !result;
        },
        .int_val => |iv| {
            // RHS must be an integer literal
            const rhs_val: i64 = switch (bo.rhs.data) {
                .int_literal => |il| il.value,
                .char_literal => |cl| cl.value,
                else => return null,
            };
            const result = iv == rhs_val;
            return if (bo.op == .eq) result else !result;
        },
    }
}

/// Evaluate a compile-time match expression for `inline if ... == { case ... }`.
/// Returns the body of the matching arm, or null if the match can't be resolved.
/// The selection an `inline` TYPE match folds to: a single arm body, or
/// nothing (no arm matched and no `else:` — the runtime form's
/// skip-to-merge, expressed statically).
pub const StaticTypeMatchSel = union(enum) {
    body: *const Node,
    none_matched,
};

/// Fold an `inline if T == { case <category|Type>: … }` whose SUBJECT is a
/// statically-BOUND generic type param: classify the bound type against
/// each arm at lower time and select the first match (else-arm fallback).
/// The siblings are DROPPED WHOLE — each kind arm only type-checks for its
/// own kind (`x.ptr` exists on slices, `x.(ProtocolRaw)` on protocol
/// values), so lowering them all would reject every mixed-kind generic
/// body. Same discipline as `evalComptimeMatch` / `inline if` branch
/// elimination; a `compile_error(…)` arm fires only when SELECTED.
/// Null → not foldable here (subject isn't a bound type param) — the
/// caller keeps the runtime tag-switch lowering.
pub fn evalStaticTypeMatch(self: *Lowering, me: *const ast.MatchExpr) ?StaticTypeMatchSel {
    const sname = switch (me.subject.data) {
        .identifier => |id| id.name,
        .type_expr => |te| te.name,
        else => return null,
    };
    const tb = self.type_bindings orelse return null;
    const subject_tid = tb.get(sname) orelse return null;
    for (me.arms) |arm| {
        const pat = arm.pattern orelse continue; // else: handled below
        const pname = switch (pat.data) {
            .identifier => |id| id.name,
            .type_expr => |te| te.name,
            else => return null, // value patterns — not a type match
        };
        if (self.staticTypeMatchesCategory(subject_tid, pname)) return .{ .body = arm.body };
    }
    for (me.arms) |arm| {
        if (arm.pattern == null) return .{ .body = arm.body };
    }
    return .none_matched;
}

/// Does the STATIC type `tid` belong to category `name` (or equal the
/// specific type `name` denotes)? Mirrors `resolveTypeCategoryTags`'s
/// runtime classification arm for arm so the static fold and the runtime
/// tag switch can never disagree on what a category means — plus the
/// `protocol` category, which exists ONLY here (a protocol value carries
/// no runtime tag to switch on until the phase-2 RTTI story).
pub fn staticTypeMatchesCategory(self: *Lowering, tid: TypeId, name: []const u8) bool {
    const tt = &self.module.types;
    if (std.mem.eql(u8, name, "int")) {
        switch (tid) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize, .isize => return true,
            else => {},
        }
        if (!tid.isBuiltin()) {
            switch (tt.get(tid)) {
                .signed, .unsigned => return true,
                else => {},
            }
        }
        return false;
    }
    if (std.mem.eql(u8, name, "float")) return tid == .f32 or tid == .f64;
    if (std.mem.eql(u8, name, "bool")) return tid == .bool;
    if (std.mem.eql(u8, name, "string")) return tid == .string;
    if (std.mem.eql(u8, name, "void")) return tid == .void;
    if (std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "Type")) return tid == .type_value;
    if (tid.isBuiltin()) {
        // Builtins beyond the fixed categories match only a specific name.
        return false;
    }
    const info = tt.get(tid);
    if (std.mem.eql(u8, name, "struct")) return info == .@"struct";
    if (std.mem.eql(u8, name, "enum")) return info == .@"enum" or info == .tagged_union;
    if (std.mem.eql(u8, name, "union")) return info == .@"union" or info == .tagged_union;
    if (std.mem.eql(u8, name, "slice")) return info == .slice;
    if (std.mem.eql(u8, name, "array")) return info == .array;
    if (std.mem.eql(u8, name, "pointer")) return info == .pointer or info == .many_pointer;
    if (std.mem.eql(u8, name, "vector")) return info == .vector;
    if (std.mem.eql(u8, name, "optional")) return info == .optional;
    if (std.mem.eql(u8, name, "error_set")) return info == .error_set;
    if (std.mem.eql(u8, name, "closure")) return info == .closure;
    if (std.mem.eql(u8, name, "protocol"))
        return info == .protocol or (info == .@"struct" and info.@"struct".is_protocol);
    // A specific type name: generic bindings, then aliases, then the table.
    if (self.type_bindings) |tb| {
        if (tb.get(name)) |bound| return bound == tid;
    }
    if (self.program_index.type_alias_map.get(name)) |alias_ty| return alias_ty == tid;
    const name_id = self.module.types.internString(name);
    if (self.module.types.findByName(name_id)) |t| return t == tid;
    return false;
}

pub fn evalComptimeMatch(self: *Lowering, me: *const ast.MatchExpr) ?*const Node {
    // Subject must be a comptime constant identifier
    const name = switch (me.subject.data) {
        .identifier => |id| id.name,
        else => return null,
    };
    const cv = self.comptime_constants.get(name) orelse return null;

    switch (cv) {
        .enum_tag => |et| {
            const enum_info = self.module.types.get(et.ty);
            if (enum_info != .@"enum") return null;
            for (me.arms) |arm| {
                if (arm.pattern == null) continue; // default arm
                const variant_name = switch (arm.pattern.?.data) {
                    .enum_literal => |el| el.name,
                    else => continue,
                };
                const variant_idx = self.findVariantIndex(enum_info.@"enum".variants, variant_name);
                if (et.tag == variant_idx) return arm.body;
            }
            // No match — try default arm
            for (me.arms) |arm| {
                if (arm.pattern == null) return arm.body;
            }
            return null;
        },
        .int_val => |iv| {
            for (me.arms) |arm| {
                if (arm.pattern == null) continue;
                const rhs_val: i64 = switch (arm.pattern.?.data) {
                    .int_literal => |il| il.value,
                    .char_literal => |cl| cl.value,
                    else => continue,
                };
                if (iv == rhs_val) return arm.body;
            }
            for (me.arms) |arm| {
                if (arm.pattern == null) return arm.body;
            }
            return null;
        },
    }
}

/// Evaluate an `inline for` range bound to a comptime integer. Delegates to
/// the shared `program_index.evalConstIntExpr` — the SAME integer folder the
/// array dimension / Vector lane / value-param count paths build on — so a
/// literal, a comptime constant (cursor), a module/generic const
/// (`inline for 0..M`), a `<pack>.len` leaf, a DIRECT integral float
/// (`0..-2.0` → -2), and any constant-foldable expression over those
/// (`inline for 0..(M + 1)`) all resolve identically. A range bound is an
/// ENDPOINT, not a count (specs.md §2), so it deliberately does NOT take the
/// `foldCountI64` float-const-leaf fallback the count sites add: it accepts a
/// direct integral float but leaves a float-const-leaf expression to the int
/// folder (negatives are valid here, unlike a count).
pub fn evalComptimeInt(self: *Lowering, node: *const Node) ?i64 {
    return program_index_mod.evalConstIntExpr(node, self);
}

/// Lower a `#run expr` that appears as a top-level constant binding:
///   NAME :: #run expr;
/// Creates a comptime function wrapping the expression (for later
/// interpretation), plus a global constant to hold the result.
pub fn lowerComptimeGlobal(self: *Lowering, name: []const u8, expr: *const Node, type_ann: ?*const Node) void {
    // When the user writes `NAME :: #run expr;` with no type annotation,
    // infer the global's type from the comptime expression's return
    // shape. `resolveType(null)` returns `.i64` for legacy reasons —
    // good for primitive helpers, silently wrong for anything else.
    const expr_ty = self.inferExprType(expr);
    // A failable `#run` (bare, no `catch`/`or`): the comptime function
    // returns the full failable tuple so the #run site can inspect the
    // error slot, but the GLOBAL is typed as the success value. On a
    // comptime error the global never materializes — emit halts with a
    // diagnostic + trace (E5.2). A handled `#run … catch/or …` already
    // strips the error channel, so it lands here as non-failable.
    const is_failable = self.errorChannelOf(expr_ty) != null;
    const func_ret: TypeId = if (is_failable)
        expr_ty
    else if (type_ann) |n|
        self.resolveTypeWithBindings(n)
    else
        expr_ty;
    const global_ty: TypeId = if (is_failable) self.failableSuccessType(expr_ty) else func_ret;
    const func_id = self.createComptimeFunction(name, expr, func_ret);

    // Add a global constant whose initializer will be filled by the interpreter.
    const name_id = self.module.types.internString(name);
    const gid = self.module.addGlobal(.{
        .name = name_id,
        .ty = global_ty,
        .init_val = null, // will be filled by interpreter at emit time
        .is_const = true,
        .comptime_func = func_id,
    });

    // Register for runtime lookup: identifier resolution emits global_get
    self.putGlobal(self.current_source_file, name, .{ .id = gid, .ty = global_ty });
}

/// Lower a standalone `#run expr;` at the top level (side-effect only).
/// Creates a comptime function that the interpreter should execute.
pub fn lowerComptimeSideEffect(self: *Lowering, expr: *const Node) void {
    // A failable side-effect `#run f();` returns the failable tuple so the
    // emit-time runner can detect an escaping error and halt (E5.2);
    // non-failable side effects stay `void`.
    const expr_ty = self.inferExprType(expr);
    const ret: TypeId = if (self.errorChannelOf(expr_ty) != null) expr_ty else .void;
    _ = self.createComptimeFunction("__run", expr, ret);
}

/// Lower a `#run expr` that appears inline within an expression.
/// Creates a comptime function and emits a `call` to it, so the
/// interpreter can evaluate it and replace with the constant result.
pub fn lowerInlineComptime(self: *Lowering, expr: *const Node) Ref {
    const ret_ty: TypeId = self.target_type orelse self.inferExprType(expr);
    const func_id = self.createComptimeFunction("__ct", expr, ret_ty);
    // Carry the binding const's name (when this `#run` initializes one) onto the
    // wrapper so a comptime-init failure names the user const, not `__ct_N`.
    if (self.comptime_const_name) |cname| {
        self.module.getFunctionMut(func_id).comptime_display_name = self.module.types.internString(cname);
    }
    // Emit a call to the comptime function. At interpretation time,
    // this will be evaluated and the result inlined as a constant.
    const func = &self.module.functions.items[@intFromEnum(func_id)];
    const final_args: []const Ref = if (func.has_implicit_ctx)
        self.alloc.dupe(Ref, &.{self.current_ctx_ref}) catch &.{}
    else
        &.{};
    return self.builder.call(func_id, final_args, ret_ty);
}

/// Lower a `#insert expr` statement. Evaluates `expr` at compile time to get
/// a string, parses it as sx code, and lowers each statement inline.
pub fn lowerInsertExpr(self: *Lowering, expr: *const Node) void {
    _ = self.lowerInsertExprValue(expr);
}

/// Like lowerInsertExpr but returns the value of the last parsed expression.
pub fn lowerInsertExprValue(self: *Lowering, expr: *const Node) Ref {
    // Step 1: Substitute comptime param nodes (e.g., replace $fmt with its literal)
    const substituted = if (self.comptime_param_nodes) |cpn|
        self.substituteComptimeNodes(expr, cpn) catch expr
    else
        expr;

    // Step 2: Evaluate the expression to get a string
    const code_str = self.evalComptimeString(substituted) orelse return self.builder.constInt(0, .void);

    // Step 3: Parse the string as sx code and lower each statement
    // The last expression's value is captured as the return value
    var p = parser_mod.Parser.init(self.alloc, code_str);
    var last_val: Ref = self.builder.constInt(0, .void);
    while (p.current.tag != .eof) {
        const stmt = p.parseStmt() catch break;
        if (p.current.tag == .eof) {
            // Last statement — try to capture as expression value
            // Note: tryLowerAsExpr internally calls lowerStmt for statement nodes,
            // so we must NOT call lowerStmt again in the else branch.
            if (self.tryLowerAsExpr(stmt)) |val| {
                last_val = val;
            }
        } else {
            self.lowerStmt(stmt);
        }
    }
    return last_val;
}

/// Evaluate a `Type`-returning expression at compile time → its `TypeId`.
/// `expr` (a call to any bodied `-> Type` fn) is wrapped in a throwaway comptime
/// fn and run through the interpreter with the type-mint table enabled, so the
/// `declare`/`define` builtins reached inside it mutate the real type table. The
/// result value is a `.type_tag`. A type minted via `define` is already named
/// (the name travels in its `TypeInfo`); a caller needing a different identity
/// name (the type-fn mangled-name path) renames afterwards via
/// `renameNominalType`. Returns null (caller poisons) if evaluation didn't yield
/// a Type.
/// Register an empty forward nominal type named by each `declare("Name")` call
/// reachable from `expr` (and, if `expr` is a call to a known fn, that fn's
/// body). Runs before the comptime expression lowers so a `*Name` self-reference
/// resolves to this forward slot. Idempotent (skips an already-registered name).
fn preregisterForwardTypes(self: *Lowering, expr: *const Node) void {
    scanDeclareNames(self, expr, 0);
    if (expr.data == .call and expr.data.call.callee.data == .identifier) {
        if (self.program_index.fn_ast_map.get(expr.data.call.callee.data.identifier.name)) |fd| {
            scanDeclareNames(self, fd.body, 0);
        }
    }
}

fn scanDeclareNames(self: *Lowering, node: *const Node, depth: u32) void {
    if (depth > 64) return;
    switch (node.data) {
        .call => |c| {
            if (c.callee.data == .identifier and
                std.mem.eql(u8, c.callee.data.identifier.name, "declare") and
                c.args.len == 1 and c.args[0].data == .string_literal)
            {
                const nm = c.args[0].data.string_literal.raw;
                const nid = self.module.types.internString(nm);
                const tid = self.module.types.findByName(nid) orelse self.module.types.internNominal(.{
                    .tagged_union = .{
                        .name = nid,
                        .fields = &.{},
                        .tag_type = .i64,
                        .defined = false, // forward placeholder — never-completed `declare` stays rejected
                    },
                }, 0);
                // Bind the name as a type alias too: a `Name :: <ctor>()` decl
                // makes `Name` a const_decl author, so a `*Name` self-reference
                // resolves through the forward-ALIAS path — which checks
                // `type_aliases_by_source`, not `findByName`. Without this the
                // alias path returns a pending empty-struct stub instead.
                self.putTypeAlias(self.current_source_file, nm, tid);
            }
            for (c.args) |a| scanDeclareNames(self, a, depth + 1);
        },
        .block => |b| for (b.stmts) |s| scanDeclareNames(self, s, depth + 1),
        .return_stmt => |r| if (r.value) |v| scanDeclareNames(self, v, depth + 1),
        .var_decl => |v| if (v.value) |val| scanDeclareNames(self, val, depth + 1),
        .const_decl => |cd| scanDeclareNames(self, cd.value, depth + 1),
        .struct_literal => |sl| for (sl.field_inits) |fi| scanDeclareNames(self, fi.value, depth + 1),
        .array_literal => |al| for (al.elements) |e| scanDeclareNames(self, e, depth + 1),
        else => {},
    }
}

pub fn evalComptimeType(self: *Lowering, expr: *const Node) ?TypeId {
    // Pre-register every `declare("Name")` forward type BEFORE lowering, so a
    // self-referential `*Name` payload resolves (the name is a known forward
    // type when the body lowers). Done up-front rather than at declare's
    // lowering because a `*Name` can lower before its `declare` within the same
    // body. The interp's `declare` returns this same slot; `define` completes it.
    preregisterForwardTypes(self, expr);
    // The wrapper returns a `Type` value → `.type_value` (the dedicated 8-byte
    // handle). The legacy path reads the result via `asTypeId` regardless, but the
    // VM path converts `func.ret` — `.type_value` → `.type_tag` (an `.any` return
    // would box the result and bail at the VM↔legacy boundary).
    const func_id = self.createComptimeFunction("__ctype", expr, .type_value);
    return self.runComptimeTypeFunc(func_id, expr.span);
}

/// Comptime-evaluate a type-fn BODY that has local statements before its
/// `return` (the plain `evalComptimeType` only sees the return expression, so a
/// local declared before it is unresolved). Lowers the pre-return statements as
/// a prelude, then the return expression. Only used for bodies that actually
/// have a prelude — the no-prelude case stays on `evalComptimeType`.
pub fn evalComptimeTypeBody(self: *Lowering, body: *const Node, ret_expr: *const Node) ?TypeId {
    // Scan the WHOLE body for `declare("Name")` (a local `h := declare(…)` is in
    // the prelude, not the return) so forward types register before lowering.
    preregisterForwardTypes(self, body);
    const prelude = preludeBeforeReturn(body);
    // Return type `.type_value` (a `Type` value) — see `evalComptimeType`.
    const func_id = self.createComptimeFunctionWithPrelude("__ctype", prelude, ret_expr, .type_value);
    return self.runComptimeTypeFunc(func_id, ret_expr.span);
}

/// The statements of a block body that PRECEDE its first `return` — the locals a
/// type-fn binds before minting. Empty for a non-block (arrow) body.
fn preludeBeforeReturn(body: *const Node) []const *const Node {
    if (body.data != .block) return &.{};
    const stmts = body.data.block.stmts;
    for (stmts, 0..) |stmt, i| {
        if (stmt.data == .return_stmt) return stmts[0..i];
    }
    return &.{};
}

/// Run a comptime type-construction function and post-process its result: render
/// any interp bail as a build-gating diagnostic (issue 0140) and reject a bare
/// `declare()` never completed by `define()` (a zero-field nominal slot that
/// would otherwise panic at codegen). `span` locates both diagnostics.
pub fn runComptimeTypeFunc(self: *Lowering, func_id: FuncId, span: ast.Span) ?TypeId {
    // The scan-time context comes from the EARLY-emitted
    // `__sx_default_context` (see `evalComptimeType` — assembly + emission
    // run before the body lowers, and the emission's erasure folds force the
    // protocol thunks). No separate thunk-forcing here.

    // If lowering this type-fn's BODY already emitted an error (e.g. a rejected
    // coercion like `[*]T → []T`, issue 0141), the function holds malformed IR —
    // a slice value that is really a bare 8-byte pointer, etc. Running the VM on it
    // would dereference garbage (a comptime Addr is a real host pointer, so a bad
    // data pointer FAULTS, defeating the VM's bail-not-crash guards which only catch
    // malformed Refs, not malformed comptime DATA). The user's real diagnostic is
    // already on the list; skip the eval and let `hasErrors()` abort the build.
    if (self.diagnostics) |d| if (d.hasErrors()) return null;

    // The comptime VM is the SOLE evaluator (P5.7) — no legacy fallback. A
    // type-fn runs on the VM; a bail is ALWAYS a build-gating diagnostic, never a
    // fallback. The VM is hardened against malformed lowering-time IR (it BAILS,
    // never panics; see `comptime_vm.refTy`/`badRef`), and bails BEFORE any table
    // mutation, so a failed mint never leaves a partial type.
    const vm_result = comptime_vm.tryEval(self.alloc, self.module, func_id, null, null);
    if (std.c.getenv("SX_COMPTIME_FLAT_TRACE") != null) {
        if (vm_result != null)
            std.debug.print("[comptime-vm] HANDLED  type-fn\n", .{})
        else
            std.debug.print("[comptime-vm] BAIL type-fn: {s}\n", .{comptime_vm.last_bail_reason orelse "<unknown>"});
    }
    if (vm_result) |v| {
        const tid_vm = v.asTypeId() orelse return null;
        return checkComptimeTypeResult(self, tid_vm, span);
    }

    // VM bailed: render a build-gating diagnostic naming the reason — NOT poison
    // to `.unresolved` silently and let that crash at LLVM emission ("unresolved
    // type reached LLVM emission") or hide behind a downstream cascade (issue
    // 0140). The VM's bail reason carries the precise cause (e.g. "comptime
    // define(): duplicate variant name 'x'"), so a comptime type-construction
    // failure (1179/1180) produces its proper user diagnostic.
    if (self.diagnostics) |d| {
        d.addFmt(.err, span, "comptime type construction failed: {s}", .{comptime_vm.last_bail_reason orelse "<unknown>"});
    }
    return null;
}

/// Post-check a comptime type-construction result (shared by the VM and legacy
/// paths). A bare `declare("X")` never completed by a `define(handle, …)` leaves
/// a forward `tagged_union` PLACEHOLDER (`defined == false`); sizing /
/// constructing / emitting it panics at codegen (`verifySizes`: llvm_size !=
/// ir_size). Reject it loudly here. An *explicitly* defined empty type (an empty
/// struct / tuple / enum / tagged_union — `defined == true`, possibly 0 fields)
/// is a legitimate result and passes through. Returns the type, or null after
/// gating the build.
fn checkComptimeTypeResult(self: *Lowering, tid: TypeId, span: ast.Span) ?TypeId {
    if (!tid.isBuiltin()) {
        const info = self.module.types.get(tid);
        if (info == .tagged_union and !info.tagged_union.defined) {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "type '{s}' is declared but never defined — complete it with define(handle, info)", .{self.module.types.getString(info.tagged_union.name)});
            return null;
        }
    }
    return tid;
}

/// Rename a nominal type to a new name, re-keying `intern_map` so
/// `findByName(name)` resolves it. Used by the type-fn instantiation path to
/// give a comptime-minted type its mangled instantiation name (identity /
/// Contract 1). A no-op for a non-nominal / already-named-as-requested type.
pub fn renameNominalType(self: *Lowering, tid: TypeId, name: []const u8) void {
    const tbl = &self.module.types;
    const new_name_id = tbl.internString(name);
    var info = tbl.get(tid);
    switch (info) {
        .tagged_union => |*u| {
            if (u.name == new_name_id) return;
            u.name = new_name_id;
        },
        .@"enum" => |*e| {
            if (e.name == new_name_id) return;
            e.name = new_name_id;
        },
        else => return,
    }
    tbl.replaceKeyedInfo(tid, info);
}

/// Evaluate an expression at compile time, returning its string value.
/// Returns null if evaluation fails.
pub fn evalComptimeString(self: *Lowering, expr: *const Node) ?[:0]const u8 {
    // Case 1: String literal — return it directly (no need for interpreter)
    if (expr.data == .string_literal) {
        const lit = expr.data.string_literal;
        const str = if (lit.is_raw)
            lit.raw
        else
            unescape.unescapeString(self.alloc, lit.raw) catch lit.raw;
        return self.alloc.dupeZ(u8, str) catch null;
    }

    // Case 2: evaluate on the comptime VM (the SOLE evaluator — P5.7), reusing
    // the parent module. The parent's `scanDecls` pass has already registered
    // every type / protocol / impl / thunk the comptime call may need
    // (Allocator, CAllocator, Context, the per-impl thunks); a fresh empty
    // module would miss those and break `context.allocator.X`.
    //
    // Lowering-time IR can be malformed (e.g. a `ret Ref.none` left by an
    // unresolved name — see `0737`); the VM is hardened to BAIL (never panic) on
    // it, so `tryEval` yields null and we return null. The real user diagnostic
    // (the visibility error, …) was already emitted while lowering the inserted
    // expression. `regToValue` dupes the result string into `self.alloc`, so it
    // outlives the VM's arena.
    const ct_func_id = self.createComptimeFunction("__insert", expr, .string);
    const result = comptime_vm.tryEval(self.alloc, self.module, ct_func_id, null, null) orelse return null;
    const str = switch (result) {
        .string => |s| s,
        else => return null,
    };
    return self.alloc.dupeZ(u8, str) catch null;
}

/// Lower the direct callee of a comptime expression into the ct module.
/// Transitive dependencies are resolved lazily via the shared fn_ast_map.
pub fn lowerComptimeDeps(self: *Lowering, ct: *Lowering, expr: *const Node) void {
    if (expr.data != .call) return;
    if (expr.data.call.callee.data != .identifier) return;
    const name = expr.data.call.callee.data.identifier.name;
    if (resolveBuiltin(name) != null) return;
    if (self.program_index.fn_ast_map.get(name)) |fd| {
        if (ct.resolveFuncByName(name) == null) {
            ct.lowerFunction(fd, name, false);
        }
    }
}

/// Substitute comptime parameter identifiers with their actual AST nodes.
pub fn substituteComptimeNodes(self: *Lowering, node: *const Node, cpn: std.StringHashMap(*const Node)) !*const Node {
    // Direct identifier match
    if (node.data == .identifier) {
        if (cpn.get(node.data.identifier.name)) |replacement| {
            return replacement;
        }
    }

    // Recurse into call arguments
    if (node.data == .call) {
        var changed = false;
        const new_args = try self.alloc.alloc(*Node, node.data.call.args.len);
        for (node.data.call.args, 0..) |arg, i| {
            const substituted = try self.substituteComptimeNodes(arg, cpn);
            new_args[i] = @constCast(substituted);
            if (substituted != arg) changed = true;
        }
        if (changed) {
            const new_node = try self.alloc.create(Node);
            new_node.* = .{
                .span = node.span,
                .data = .{ .call = .{
                    .callee = node.data.call.callee,
                    .args = new_args,
                } },
            };
            return new_node;
        }
    }

    return node;
}

/// Lower a call to a function with comptime params by inlining its body.
/// Comptime params are substituted, `#insert` expressions are evaluated.
pub fn lowerComptimeCall(self: *Lowering, fd: *const ast.FnDecl, call_node: *const ast.Call) Ref {
    return self.lowerComptimeCallArgs(fd, call_node.args);
}

/// Core of `lowerComptimeCall`, parameterized over the EFFECTIVE call-site arg
/// nodes. A free call passes `call_node.args`; a generic-struct method passes
/// the receiver node prepended ahead of `call_node.args`, so `fd.params[0]`
/// (`self`) binds from the receiver and the method's `$o` / comptime params bind
/// from the rest. The caller is responsible for installing any type bindings
/// (e.g. `type_bindings` for a generic struct's `T`) before invoking this — the
/// body lowers with whatever bindings are active.
pub fn lowerComptimeCallArgs(self: *Lowering, fd: *const ast.FnDecl, call_args: []const *Node) Ref {
    return self.lowerComptimeCallArgsSkip(fd, call_args, 0);
}

/// Generalization of `lowerComptimeCallArgs` that skips the FIRST `skip_params`
/// formal params — they are PRE-BOUND in the current scope by the caller before
/// invoking (the generic-struct-method path binds `self` via the normal
/// receiver-fixup so a `self: *Box(T)` pointer param is correct, then routes the
/// method's `$o`/comptime params through here). `call_args` corresponds to
/// `fd.params[skip_params..]`. With `skip_params == 0` this is the ordinary
/// free-call inline.
pub fn lowerComptimeCallArgsSkip(self: *Lowering, fd: *const ast.FnDecl, call_args: []const *Node, skip_params: usize) Ref {
    // Build comptime param substitution map: param_name → call_site AST node
    var cpn = std.StringHashMap(*const Node).init(self.alloc);
    var call_arg_idx: usize = 0;
    // Pack-arg-node registration (step 2 of the variadic heterogeneous
    // type packs feature): when the fn declares a pack param, record
    // the slice of call-site arg nodes under the pack name so the
    // body's `args[$i]` lowering can substitute the i-th arg with
    // its concrete-typed value instead of the `[]Any` slice load.
    var pack_arg_name: ?[]const u8 = null;
    var pack_arg_slice: []const *const Node = &.{};

    for (fd.params[skip_params..]) |param| {
        if (param.is_variadic) {
            // Variadic param: pack remaining call args into []Any slice
            self.lowerVariadicArgs(param.name, call_args, call_arg_idx);
            // Only heterogeneous pack form `..$args` (is_comptime AND
            // is_variadic) registers for typed indexing. Plain
            // `args: ..Any` keeps the existing []Any path so stdlib's
            // `format`/`print` continue boxing through Any.
            if (param.is_comptime and call_arg_idx <= call_args.len) {
                pack_arg_name = param.name;
                pack_arg_slice = call_args[call_arg_idx..];
                // Stamp each pack arg with the caller's source so the
                // body's typed `args[i]` substitution (via packArgNodeAt,
                // lowered under the defining-module pin set below) resolves
                // its bare names in the CALLER's visibility context — the
                // same treatment the fixed comptime params get below.
                // Without it a caller-owned helper passed to an imported
                // metaprogram (`std.print("{}", caller_fn())`) resolves
                // under the callee's module and is reported "not visible".
                for (call_args[call_arg_idx..]) |pack_arg| {
                    self.stampCallerSource(pack_arg);
                }
            }
            break; // variadic is always the last param
        }
        if (call_arg_idx >= call_args.len) break;
        if (param.is_comptime) {
            self.stampCallerSource(call_args[call_arg_idx]);
            cpn.put(param.name, call_args[call_arg_idx]) catch {};
            call_arg_idx += 1;
        } else {
            const arg_val = self.lowerExpr(call_args[call_arg_idx]);
            const pty = self.resolveParamType(&param);
            const slot = self.builder.alloca(pty);
            self.builder.store(slot, arg_val);
            if (self.scope) |scope| {
                scope.put(param.name, .{ .ref = slot, .ty = pty, .is_alloca = true });
            }
            call_arg_idx += 1;
        }
    }

    // Also bind comptime params as local string variables (for `fmt` used in runtime code)
    var cpn_iter = cpn.iterator();
    while (cpn_iter.next()) |entry| {
        const param_name = entry.key_ptr.*;
        const param_node = entry.value_ptr.*;
        if (param_node.data == .string_literal) {
            // Create a local string variable with the literal value
            const str_ref = self.lowerExpr(param_node);
            const slot = self.builder.alloca(.string);
            self.builder.store(slot, str_ref);
            if (self.scope) |scope| {
                scope.put(param_name, .{ .ref = slot, .ty = .string, .is_alloca = true });
            }
        }
    }

    // Bind VALUE-typed comptime params (`$o: Ord`, `$s: Shape`, ...) to their
    // argument's materialized comptime value — both into
    // `comptime_value_bindings` (the comptime-readable scalar: int / enum-tag /
    // tagged-union-tag, so a downstream lowerer can read the constant for an
    // identifier) AND as a scoped value (so `if o == .a` / `if s == .circle`
    // lowers as an ordinary comparison). Saved/restored around the body so
    // nested comptime calls don't leak the outer call's bindings. A
    // non-constant / unknown-variant arg is a loud diagnostic (never a silent
    // default) per the value-param rules.
    const saved_value_bindings = self.comptime_value_bindings;
    const saved_value_ref_bindings = self.comptime_value_ref_bindings;
    var value_bindings: ?std.StringHashMap(i64) = null;
    var value_ref_bindings: ?std.StringHashMap(Ref) = null;
    self.bindComptimeValueParams(fd, cpn, &value_bindings, &value_ref_bindings);
    defer {
        if (value_bindings) |*vb| vb.deinit();
        if (value_ref_bindings) |*vrb| vrb.deinit();
        self.comptime_value_bindings = saved_value_bindings;
        self.comptime_value_ref_bindings = saved_value_ref_bindings;
    }

    // Install comptime param nodes and lower the function body inline
    const saved_cpn = self.comptime_param_nodes;
    self.comptime_param_nodes = cpn;
    defer self.comptime_param_nodes = saved_cpn;

    // Install pack-arg-node binding. Mirrors `comptime_param_nodes`:
    // each call owns its own map, nested calls shadow. `lowerIndexExpr`
    // reads the map for `args[<int_literal>]` substitution.
    const saved_pan = self.pack_arg_nodes;
    var pan_map: std.StringHashMap([]const *const Node) = undefined;
    var pan_installed = false;
    if (pack_arg_name) |pn| {
        pan_map = std.StringHashMap([]const *const Node).init(self.alloc);
        pan_map.put(pn, pack_arg_slice) catch {};
        self.pack_arg_nodes = pan_map;
        pan_installed = true;
    }
    defer {
        if (pan_installed) pan_map.deinit();
        self.pack_arg_nodes = saved_pan;
    }

    // Pin the lowering to the metaprogram's OWN module for the body (and
    // its return type + anything it `#insert`s, e.g. `build_format` / `out`
    // / `emit` inside `std.print` / `log.*`), so those bare names resolve
    // in the defining module's visibility context rather than the call
    // site's. The call-site ARGS above are deliberately lowered
    // BEFORE this, in the caller's context. Mirrors `lowerFunctionBodyInto`,
    // which switches to `func.source_file`. The defining path is stamped on
    // the body node by `resolveImports`; a sourceless body keeps the
    // caller's context.
    const saved_source = self.current_source_file;
    defer self.setCurrentSourceFile(saved_source);
    if (fd.body.source_file) |src| self.setCurrentSourceFile(src);

    // Lower the body — capture return value for functions with return type
    const ret_ty = self.resolveReturnType(fd);
    if (ret_ty != .void) {
        // Detect whether the body might use `return X;` statements.
        // If so, set up the inline-return slot AND a dedicated
        // "return-done" basic block so each `return X;` stores to
        // the slot and branches to ret_done. After the body lowers,
        // we switch to ret_done and load. Pure tail-expression
        // bodies (arrow form, or a block whose last stmt is an
        // expression) skip the slot+block — keeps the common
        // `format`/`#insert`-style path unchanged.
        const has_return = fnBodyHasReturn(fd.body);
        if (has_return) {
            const ret_slot = self.builder.alloca(ret_ty);
            const ret_done_bb = self.freshBlock("ct.ret_done");
            const saved_iri = self.inline_return_target;
            self.inline_return_target = .{ .slot = ret_slot, .ret_ty = ret_ty, .done_bb = ret_done_bb };
            defer self.inline_return_target = saved_iri;

            // Lower body. Tail-expression bodies (rare here since
            // has_return == true) produce a tail value we still
            // route through the slot so the load in ret_done picks
            // it up. Block-statement bodies whose last stmt is
            // `return X;` already br to ret_done from inside
            // lowerReturn.
            if (self.lowerBlockValue(fd.body)) |val| {
                if (!self.currentBlockHasTerminator()) {
                    const v_ty = self.builder.getRefType(val);
                    // Issue 0191: same returnable check as the regular body
                    // path — no bit-weld into the inline return slot.
                    const coerced = if (v_ty != ret_ty and self.checkReturnable(val, v_ty, ret_ty, fd.body.span))
                        self.coerceToType(val, v_ty, ret_ty)
                    else
                        val;
                    self.builder.store(ret_slot, coerced);
                    self.builder.br(ret_done_bb, &.{});
                }
            } else if (!self.currentBlockHasTerminator()) {
                // Body fell through without producing a tail value
                // AND without branching to ret_done — this only
                // happens for bodies whose last stmt is a void
                // statement (e.g. side-effecting). Slot is
                // uninitialised on this path; safer to br anyway
                // so the CFG is well-formed. The load in ret_done
                // will read uninit, which is the same garbage
                // behaviour the regular fn-body lowering would
                // produce for a missing return.
                self.builder.br(ret_done_bb, &.{});
            }

            self.builder.switchToBlock(ret_done_bb);
            return self.builder.load(ret_slot, ret_ty);
        } else {
            if (self.lowerBlockValue(fd.body)) |val| {
                return val;
            }
        }
    } else {
        self.lowerBlock(fd.body);
    }

    return self.builder.constInt(0, .void);
}

/// Bind VALUE-typed comptime params for an inlined comptime call. For each
/// comptime param whose declared constraint resolves to a value type and whose
/// call-site argument is a constant literal of that type, this materializes the
/// argument as a compile-time-known value and binds the param so it resolves in
/// the body. Two stores are written:
///   - `int_store` (`comptime_value_bindings`, param → i64): the
///     comptime-readable SCALAR — the int for an `int` param, the variant TAG
///     for an `enum` or `tagged_union` param. Preserves the integration
///     contract: `comptimeIntNamed(param)` keeps returning the tag/int, and the
///     param remains usable in a type position (`[o]i64`).
///   - `ref_store` (`comptime_value_ref_bindings`, param → Ref): the full
///     materialized value Ref for a non-scalar param (the `enum_init(tag,
///     payload)` of a tagged-union, the aggregate const of a struct/array), so
///     a lowering-time consumer can read the WHOLE bound value via
///     `comptimeValueRefNamed(param)`.
/// Supported constraint kinds:
///   - `.@"enum"` (payload-less): bind the variant tag, scope an
///     `enum_init(tag, none)` so `if o == .a` lowers as an enum comparison.
///   - `.tagged_union` (payload-bearing enum): bind the variant tag (int_store)
///     AND the full `enum_init(tag, payload)` value (ref_store + scope), so a
///     bare variant (`.point`) or a payload variant (`.circle(5.0)`) both
///     resolve — `if s == .circle` lowers as a tag comparison and any payload
///     read works off the bound value.
/// A non-constant argument, or one naming an unknown variant, emits a loud
/// diagnostic and binds nothing — never a silent default. Constraint kinds that
/// are not value types (a metatype / `type` constraint, a generic type param)
/// are left to the type-binding machinery and skipped here.
pub fn bindComptimeValueParams(
    self: *Lowering,
    fd: *const ast.FnDecl,
    cpn: std.StringHashMap(*const Node),
    int_store: *?std.StringHashMap(i64),
    ref_store: *?std.StringHashMap(Ref),
) void {
    for (fd.params) |param| {
        if (!param.is_comptime or param.is_variadic) continue;
        const arg_node = cpn.get(param.name) orelse continue;

        // Resolve the param's declared constraint type in the function's own
        // defining module (the enum/union may be bare-visible only there).
        const constraint_ty = self.resolveParamTypeInSource(fd.body.source_file, &param);
        if (constraint_ty.isBuiltin()) continue;
        const info = self.module.types.get(constraint_ty);
        switch (info) {
            .@"enum" => self.bindEnumValueParam(param.name, constraint_ty, info.@"enum", arg_node, int_store),
            .tagged_union => self.bindTaggedUnionValueParam(param.name, constraint_ty, info.tagged_union, arg_node, int_store, ref_store),
            // Other constraint kinds (`type`-metatype params, generic type
            // params, structs/arrays) are not bound here. struct/array
            // aggregate value params are not yet wired (no literal-shape repro
            // in the corpus drives them); when one lands, add a `.@"struct"` /
            // `.array` arm that lowers the literal to an aggregate const and
            // writes `ref_store`. Until then we leave the param to whatever
            // downstream resolution already applies — never a silent default.
            else => {},
        }
    }
}

/// Record `param → tag` in `int_store` (lazily creating/activating it, seeded
/// from any outer-active bindings so a surrounding comptime call's value params
/// stay visible). Shared by the enum and tagged-union binders.
pub fn recordComptimeTag(self: *Lowering, store: *?std.StringHashMap(i64), name: []const u8, tag: i64) void {
    if (store.* == null) {
        var m = std.StringHashMap(i64).init(self.alloc);
        if (self.comptime_value_bindings) |outer| {
            var it = outer.iterator();
            while (it.next()) |e| m.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }
        store.* = m;
        self.comptime_value_bindings = store.*;
    }
    store.*.?.put(name, tag) catch {};
    self.comptime_value_bindings = store.*;
}

/// Record `param → value Ref` in `ref_store` (lazily creating/activating it,
/// seeded from any outer-active ref bindings). Companion to `recordComptimeTag`
/// for the full materialized value of a non-scalar comptime value param.
pub fn recordComptimeValueRef(self: *Lowering, store: *?std.StringHashMap(Ref), name: []const u8, ref: Ref) void {
    if (store.* == null) {
        var m = std.StringHashMap(Ref).init(self.alloc);
        if (self.comptime_value_ref_bindings) |outer| {
            var it = outer.iterator();
            while (it.next()) |e| m.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }
        store.* = m;
        self.comptime_value_ref_bindings = store.*;
    }
    store.*.?.put(name, ref) catch {};
    self.comptime_value_ref_bindings = store.*;
}

/// Bind a payload-less `.@"enum"` comptime value param. The arg must be a
/// constant enum literal (`.b`) naming a known variant; records the tag and
/// scopes an `enum_init(tag, none)`.
pub fn bindEnumValueParam(
    self: *Lowering,
    name: []const u8,
    constraint_ty: TypeId,
    enum_info: types.TypeInfo.EnumInfo,
    arg_node: *const Node,
    int_store: *?std.StringHashMap(i64),
) void {
    // The argument must be a constant enum literal (`.b`). A non-literal arg
    // (a runtime value, an arbitrary expression) cannot bind a compile-time
    // variant tag — diagnose loudly rather than fabricate one.
    if (arg_node.data != .enum_literal) {
        if (self.diagnostics) |d|
            d.addFmt(.err, arg_node.span, "comptime enum value parameter '{s}' must be a constant enum literal of '{s}'", .{ name, self.formatTypeName(constraint_ty) });
        return;
    }
    const variant_name = arg_node.data.enum_literal.name;
    if (!self.enumHasVariant(enum_info.variants, variant_name)) {
        self.emitBadEnumVariant(constraint_ty, enum_info, variant_name, arg_node.span);
        return;
    }

    const tag = self.resolveVariantValue(constraint_ty, variant_name);
    self.recordComptimeTag(int_store, name, @intCast(tag));

    if (self.scope) |scope| {
        const enum_val = self.builder.enumInit(tag, Ref.none, constraint_ty);
        const slot = self.builder.alloca(constraint_ty);
        self.builder.store(slot, enum_val);
        scope.put(name, .{ .ref = slot, .ty = constraint_ty, .is_alloca = true });
    }
}

/// Bind a `.tagged_union` (payload-bearing enum) comptime value param. The arg
/// is one of two constant forms:
///   - a bare variant literal `.point` (no payload), an `.enum_literal` node, or
///   - a payload variant `.circle(5.0)`, a `.call` node whose callee is an
///     `.enum_literal`.
/// Both must name a known variant. Records the variant TAG in `int_store` (so
/// `comptimeIntNamed`/`if s == .circle` work) AND the full materialized
/// `enum_init(tag, payload)` value in `ref_store` + scope (so a payload read off
/// the bound value resolves). A non-constant arg (any other node shape) or an
/// unknown variant is a loud diagnostic.
pub fn bindTaggedUnionValueParam(
    self: *Lowering,
    name: []const u8,
    constraint_ty: TypeId,
    union_info: types.TypeInfo.TaggedUnionInfo,
    arg_node: *const Node,
    int_store: *?std.StringHashMap(i64),
    ref_store: *?std.StringHashMap(Ref),
) void {
    // Identify the variant name from either accepted literal shape.
    const variant_name: []const u8 = switch (arg_node.data) {
        .enum_literal => |el| el.name,
        .call => |c| if (c.callee.data == .enum_literal) c.callee.data.enum_literal.name else {
            if (self.diagnostics) |d|
                d.addFmt(.err, arg_node.span, "comptime tagged-union value parameter '{s}' must be a constant variant literal of '{s}' (e.g. `.variant` or `.variant(payload)`)", .{ name, self.formatTypeName(constraint_ty) });
            return;
        },
        else => {
            if (self.diagnostics) |d|
                d.addFmt(.err, arg_node.span, "comptime tagged-union value parameter '{s}' must be a constant variant literal of '{s}' (e.g. `.variant` or `.variant(payload)`)", .{ name, self.formatTypeName(constraint_ty) });
            return;
        },
    };

    if (self.findTaggedVariant(union_info, variant_name) == null) {
        self.emitBadVariant(constraint_ty, union_info, variant_name, arg_node.span);
        return;
    }

    const tag = self.resolveVariantIndex(constraint_ty, variant_name);
    self.recordComptimeTag(int_store, name, @intCast(tag));

    // Materialize the full value by lowering the argument expression with the
    // constraint as its target type — `.circle(5.0)` lowers to an
    // `enum_init(tag, payload)`, `.point` to `enum_init(tag, none)`. This runs
    // in the CALLER's scope/source context (the arg was authored there), which
    // is exactly where its payload sub-expressions must resolve.
    const saved_target = self.target_type;
    self.target_type = constraint_ty;
    const value = self.lowerExpr(arg_node);
    self.target_type = saved_target;

    self.recordComptimeValueRef(ref_store, name, value);

    if (self.scope) |scope| {
        const slot = self.builder.alloca(constraint_ty);
        self.builder.store(slot, value);
        scope.put(name, .{ .ref = slot, .ty = constraint_ty, .is_alloca = true });
    }
}

/// True iff `variants` (interned enum variant name-ids) contains `variant_name`.
pub fn enumHasVariant(self: *Lowering, variants: []const types.StringId, variant_name: []const u8) bool {
    const name_id = self.module.types.internString(variant_name);
    for (variants) |v| {
        if (v == name_id) return true;
    }
    return false;
}

/// True if `node` (a fn body) contains any top-level `return` statement.
/// Used by inline-comptime lowering to decide whether to allocate a
/// result slot — pure tail-expression bodies skip the slot. Walks past
/// `if`/`while`/`for`/`match` arms (early-return inside a conditional
/// counts) but stops at nested fn/lambda bodies (those have their own
/// return contexts).
pub fn fnBodyHasReturn(node: *const Node) bool {
    return switch (node.data) {
        .return_stmt => true,
        .block => |b| blk: {
            for (b.stmts) |s| if (fnBodyHasReturn(s)) break :blk true;
            break :blk false;
        },
        .if_expr => |ie| blk: {
            if (fnBodyHasReturn(ie.then_branch)) break :blk true;
            if (ie.else_branch) |eb| if (fnBodyHasReturn(eb)) break :blk true;
            break :blk false;
        },
        .while_expr => |we| fnBodyHasReturn(we.body),
        .for_expr => |fe| fnBodyHasReturn(fe.body),
        .match_expr => |me| blk: {
            for (me.arms) |arm| if (fnBodyHasReturn(arm.body)) break :blk true;
            break :blk false;
        },
        .defer_stmt => |ds| fnBodyHasReturn(ds.expr),
        else => false,
    };
}

/// Creates a temporary function marked `is_comptime = true` that wraps
/// the given expression as its return value. Returns the FuncId.
pub fn createComptimeFunction(self: *Lowering, prefix: []const u8, expr: *const Node, ret_ty: TypeId) FuncId {
    return self.createComptimeFunctionWithPrelude(prefix, &.{}, expr, ret_ty);
}

/// Like `createComptimeFunction`, but lowers `prelude` statements (e.g. a
/// type-fn body's local declarations) into the comptime function's scope BEFORE
/// the result `expr`, so the expr can reference names they bind. Used to
/// comptime-evaluate a generic type-fn body that has locals before its `return`
/// (the non-prelude path only sees the return expression).
pub fn createComptimeFunctionWithPrelude(self: *Lowering, prefix: []const u8, prelude: []const *const Node, expr: *const Node, ret_ty: TypeId) FuncId {
    // EVERY comptime wrapper body (type-fn, #run-at-scan, #insert, …) lowers
    // through here — and it (or a lazily-lowered callee) may read
    // `context.allocator`, which only exists once the Context is ASSEMBLED
    // and whose VALUE the VM materializes from the EMITTED
    // `__sx_default_context` constant. Best-effort early assembly +
    // emission at the one choke point; both defer silently when something
    // isn't registered yet.
    self.assembleContextEarly();
    self.emitDefaultContextGlobalEarly();
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}_{d}", .{ prefix, self.comptime_counter }) catch prefix;
    self.comptime_counter += 1;

    // Flow narrowing (issue 0179) is per-function: this wrapper body has its
    // own `Ref` space (overlapping the caller's), so isolate it from the
    // caller's `narrowed`/`narrowed_refs` to avoid a false-positive unwrap gate.
    var narrow_guard = Lowering.NarrowGuard.enter(self);
    defer narrow_guard.restore();

    // Save current builder + lowering state. The wrapper fn we're
    // about to build runs the comptime expression in isolation —
    // it must NOT inherit the enclosing call's `inline_return_target`
    // (which would re-route a `return` inside the wrapper into a
    // slot belonging to a different basic block), pack bindings
    // (which would substitute caller's `args` inside the wrapper),
    // or comptime-param bindings (which would substitute caller's
    // `$fmt` inside the wrapper's #insert children). Without these
    // saves, nested comptime calls leak outer state into the
    // interp-executed wrapper, producing garbage stores (issue-0046
    // face 1 — storeAtRawPtr null).
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    const saved_scope = self.scope;
    const saved_ctx_ref = self.current_ctx_ref;
    const saved_iri = self.inline_return_target;
    const saved_pan = self.pack_arg_nodes;
    const saved_ppc = self.pack_param_count;
    const saved_pat = self.pack_arg_types;
    const saved_cpn = self.comptime_param_nodes;
    const saved_block_terminated = self.block_terminated;
    const saved_target_type = self.target_type;
    const saved_func_defer_base = self.func_defer_base;
    self.inline_return_target = null;
    self.pack_arg_nodes = null;
    self.pack_param_count = null;
    self.pack_arg_types = null;
    self.comptime_param_nodes = null;
    self.block_terminated = false;
    self.target_type = null;
    self.func_defer_base = self.defer_stack.items.len;
    defer {
        self.current_ctx_ref = saved_ctx_ref;
        self.inline_return_target = saved_iri;
        self.pack_arg_nodes = saved_pan;
        self.pack_param_count = saved_ppc;
        self.pack_arg_types = saved_pat;
        self.comptime_param_nodes = saved_cpn;
        self.block_terminated = saved_block_terminated;
        self.target_type = saved_target_type;
        self.func_defer_base = saved_func_defer_base;
    }

    // Build params: implicit `__sx_ctx` at slot 0 when the program
    // uses Context (so the body's `context.X` reads + transitive calls
    // resolve cleanly). The comptime function's top-level invocation
    // supplies `&__sx_default_context` (interp via callWithDefaultContext;
    // codegen via the comptime-eval glue in emit_llvm).
    const wants_ctx = self.implicit_ctx_enabled;
    const params_slice = blk: {
        if (!wants_ctx) break :blk &[_]Function.Param{};
        const owned = self.alloc.alloc(Function.Param, 1) catch break :blk &[_]Function.Param{};
        owned[0] = .{
            .name = self.module.types.internString("__sx_ctx"),
            .ty = self.module.types.ptrTo(.void),
        };
        break :blk owned;
    };

    // Create the comptime function
    const name_id = self.module.types.internString(name);
    const func_id = self.builder.beginFunction(name_id, params_slice, ret_ty);

    // Mark as comptime + has_implicit_ctx
    const fn_mut = self.module.getFunctionMut(func_id);
    fn_mut.comptime_role = .run_wrapper;
    fn_mut.has_implicit_ctx = wants_ctx;

    // Create entry block
    const entry_name = self.module.types.internString("entry");
    const entry = self.builder.appendBlock(entry_name, &.{});
    self.builder.switchToBlock(entry);
    if (wants_ctx) self.current_ctx_ref = Ref.fromIndex(0);

    // Create a scope that chains to the enclosing scope (so the
    // expression can reference names visible at the #run site).
    var ct_scope = Scope.init(self.alloc, saved_scope);
    self.scope = &ct_scope;

    // Lower any prelude statements (type-fn body locals) so the result
    // expression can reference the names they bind. Empty for the common
    // single-expression case.
    for (prelude) |stmt| self.lowerStmt(stmt);

    // Lower the expression and return it
    const result = self.lowerExpr(expr);
    if (ret_ty == .void) {
        self.builder.retVoid();
    } else {
        self.builder.ret(result, ret_ty);
    }

    self.builder.finalize();

    // Restore builder state
    self.scope = saved_scope;
    ct_scope.deinit();
    self.builder.func = saved_func;
    self.builder.current_block = saved_block;
    self.builder.inst_counter = saved_counter;

    return func_id;
}

// ── Source-const folding ────────────────────────────────────────

/// Resolve a name to a compile-time integer across the three const tables.
/// A comptime binding (generic value param / inline-for cursor) or a
/// `#run`/`OS`/`ARCH` comptime constant wins first; otherwise the name is a
/// SOURCE-AWARE module const, folded with nested leaves resolved own-wins.
pub fn comptimeIntNamed(self: *Lowering, name: []const u8) ?i64 {
    if (self.comptime_constants.get(name)) |cv| switch (cv) {
        .int_val => |iv| return iv,
        else => {},
    };
    if (self.comptime_value_bindings) |cvb| {
        if (cvb.get(name)) |v| return v;
    }
    return self.foldSourceConstInt(name, null);
}

/// Lowering-time accessor for the full materialized value of a NON-scalar
/// comptime value param (a tagged-union literal, a struct/array aggregate):
/// returns the IR `Ref` of the bound value (e.g. the `enum_init(tag, payload)`
/// of a `$s: Shape` bound to `.circle(5.0)`), or null if `name` is not a
/// non-scalar comptime value binding. Companion to `comptimeIntNamed`, which
/// returns the comptime-readable SCALAR (the variant tag) for the same param.
pub fn comptimeValueRefNamed(self: *Lowering, name: []const u8) ?Ref {
    if (self.comptime_value_ref_bindings) |crb| {
        if (crb.get(name)) |r| return r;
    }
    return null;
}

/// Source-aware INTEGER fold of a module const `name` (E2/F2/R1). Select the
/// SOURCE-AWARE author (own-wins; ≥2 flat-visible → ambiguous → null, the loud
/// diagnostic is the reference site's job), then fold ITS RHS with nested const
/// leaves resolved through `SourceConstCtx` — each leaf re-selects its OWN
/// source author, NOT the global last-wins `module_const_map`. So a shadowed
/// `K :: M + 1` folds `M` to the SELECTED author's `M`, coherently whether `K`
/// is read as a value (`return K`) or used as an array dimension / count
/// (`[K]u8`). `frame` (keyed by name + author-source, F3) cycle-guards a const
/// whose value references another const. Single-author → byte-identical to the
/// legacy fold (the selected `ci` IS the global one and every nested leaf has
/// exactly one author).
pub fn foldSourceConstInt(self: *Lowering, name: []const u8, frame: ?*const ConstFoldFrame) ?i64 {
    return switch (self.selectModuleConst(name)) {
        .resolved => |sel| {
            if (constFoldFrameContains(frame, name, sel.source)) return null;
            if (!program_index_mod.isCountableConstType(&self.module.types, sel.info.ty)) return null;
            var f = ConstFoldFrame{ .name = name, .source = sel.source, .parent = frame };
            const restore = self.pinConstAuthorSource(sel.source);
            defer restore.unpin();
            return program_index_mod.evalConstIntExpr(sel.info.value, SourceConstCtx{ .lowering = self, .frame = &f });
        },
        .own_opaque, .ambiguous, .none => null,
    };
}

/// Resolve a QUALIFIED module const `ns.field` (a namespaced-import member —
/// `m :: #import "lib.sx"; … m.CAP`) to its authoring source + info (issue
/// 0192). The alias `ns` is resolved in the CURRENT source context — the file
/// that wrote `ns.field`, since an alias binds in its declaring file, not the
/// use site — then `field` is read from that target module's per-source const
/// cache (`module_consts_by_source`). Null when `ns` is not a visible namespace
/// alias, is ambiguous, or names no such const there. Diagnostic-free: a
/// speculative const fold must not emit (a real "name resolves nowhere" error is
/// the reference site's job), so the ambiguous-alias case folds to null here.
pub fn selectQualifiedConst(self: *Lowering, ns: []const u8, field: []const u8) ?SelectedConst {
    // Resolve the alias from the use-site source — the file that wrote `ns.field`
    // (where `ns` binds). A main-file body carries a null `current_source_file`
    // (it IS the root), so fall back to `main_file`, matching `selectModuleConst`.
    const from = self.current_source_file orelse self.main_file orelse return null;
    const target = switch (self.namespaceAliasVerdictFrom(ns, from)) {
        .target => |t| t,
        .ambiguous, .none => return null,
    };
    const src = target.target_module_path;
    const ci = self.sourceModuleConst(src, field) orelse return null;
    return .{ .info = ci, .source = src };
}

/// Source-aware INTEGER fold of a qualified const `ns.field` (issue 0192): the
/// qualified twin of `foldSourceConstInt`. Resolve the namespace member to its
/// authoring source, then fold ITS RHS PINNED to that source so nested const
/// leaves (`CAP :: BASE + 1`, `BASE` authored in the target module) re-select
/// against the target module, not the use site. `frame` (keyed by name +
/// author-source) cycle-guards a const whose value references another const.
pub fn foldQualifiedConstInt(self: *Lowering, ns: []const u8, field: []const u8, frame: ?*const ConstFoldFrame) ?i64 {
    const sel = self.selectQualifiedConst(ns, field) orelse return null;
    if (constFoldFrameContains(frame, field, sel.source)) return null;
    if (!program_index_mod.isCountableConstType(&self.module.types, sel.info.ty)) return null;
    var f = ConstFoldFrame{ .name = field, .source = sel.source, .parent = frame };
    const restore = self.pinConstAuthorSource(sel.source);
    defer restore.unpin();
    return program_index_mod.evalConstIntExpr(sel.info.value, SourceConstCtx{ .lowering = self, .frame = &f });
}

/// FLOAT counterpart of `foldQualifiedConstInt` (issue 0192) — the qualified
/// twin of `foldSourceConstFloat`, so a qualified non-integral float const
/// (`m.PI`) folds the same way its bare-name sibling does.
pub fn foldQualifiedConstFloat(self: *Lowering, ns: []const u8, field: []const u8, frame: ?*const ConstFoldFrame) ?f64 {
    const sel = self.selectQualifiedConst(ns, field) orelse return null;
    if (constFoldFrameContains(frame, field, sel.source)) return null;
    if (!program_index_mod.isCountableConstType(&self.module.types, sel.info.ty)) return null;
    var f = ConstFoldFrame{ .name = field, .source = sel.source, .parent = frame };
    const restore = self.pinConstAuthorSource(sel.source);
    defer restore.unpin();
    return program_index_mod.evalConstFloatExpr(sel.info.value, SourceConstCtx{ .lowering = self, .frame = &f });
}

/// "Is the qualified const `ns.field` FLOAT-valued" (issue 0192) — the
/// qualified twin of `sourceConstIsFloatTyped`, consulted by the int folder's
/// division guard so `m.K / 3` (with `m.K : f64`) is recognised as float
/// division exactly as a bare `K / 3` is.
pub fn qualifiedConstIsFloatTyped(self: *Lowering, ns: []const u8, field: []const u8, frame: ?*const ConstFoldFrame) bool {
    const sel = self.selectQualifiedConst(ns, field) orelse return false;
    if (constFoldFrameContains(frame, field, sel.source)) return false;
    if (program_index_mod.isFloatConstType(sel.info.ty)) return true;
    var f = ConstFoldFrame{ .name = field, .source = sel.source, .parent = frame };
    const restore = self.pinConstAuthorSource(sel.source);
    defer restore.unpin();
    return program_index_mod.isFloatValuedExpr(sel.info.value, SourceConstCtx{ .lowering = self, .frame = &f });
}

/// Float counterpart of `foldSourceConstInt` (E2/F2/R1).
pub fn foldSourceConstFloat(self: *Lowering, name: []const u8, frame: ?*const ConstFoldFrame) ?f64 {
    return switch (self.selectModuleConst(name)) {
        .resolved => |sel| {
            if (constFoldFrameContains(frame, name, sel.source)) return null;
            if (!program_index_mod.isCountableConstType(&self.module.types, sel.info.ty)) return null;
            var f = ConstFoldFrame{ .name = name, .source = sel.source, .parent = frame };
            const restore = self.pinConstAuthorSource(sel.source);
            defer restore.unpin();
            return program_index_mod.evalConstFloatExpr(sel.info.value, SourceConstCtx{ .lowering = self, .frame = &f });
        },
        .own_opaque, .ambiguous, .none => null,
    };
}

/// Source-aware "is `name` a FLOAT-valued module const" (E2/F2/R1): judge the
/// SELECTED author's value, with nested const leaves resolved source-aware.
pub fn sourceConstIsFloatTyped(self: *Lowering, name: []const u8, frame: ?*const ConstFoldFrame) bool {
    return switch (self.selectModuleConst(name)) {
        .resolved => |sel| {
            if (constFoldFrameContains(frame, name, sel.source)) return false;
            if (program_index_mod.isFloatConstType(sel.info.ty)) return true;
            var f = ConstFoldFrame{ .name = name, .source = sel.source, .parent = frame };
            const restore = self.pinConstAuthorSource(sel.source);
            defer restore.unpin();
            return program_index_mod.isFloatValuedExpr(sel.info.value, SourceConstCtx{ .lowering = self, .frame = &f });
        },
        .own_opaque, .ambiguous, .none => false,
    };
}

/// A selected module const plus the SOURCE that authored it. `source` pins the
/// context in which the const's RHS leaves must be folded (F1): a same-name
/// `K :: M + 1` selected from author `a.sx` folds its nested `M` against `a.sx`,
/// not against whichever module read `K`. `source` is null only on the
/// fully-unwired fallback (no source partition at all), where the RHS resolves
/// through the global registration context unchanged.
pub const SelectedConst = struct {
    info: ModuleConstInfo,
    source: ?[]const u8,
};

const ConstAuthor = union(enum) {
    resolved: SelectedConst,
    /// The reader's OWN module authors `name` as a const, but no per-source
    /// value registered — an unsupported const shape (e.g. an array-literal
    /// const). The own author owns the name: the read must NOT borrow another
    /// module's same-named const, so callers treat it as unresolvable.
    own_opaque,
    ambiguous,
    none,
};

/// The source-aware module-const author of `name` from the querying module
/// (E2/F2) — the value-const analogue of `selectNominalLeaf` (types) and
/// `selectPlainCallableAuthor` (functions). Selects over the ONE graph-walk
/// collector and reads the value from the SELECTED author's per-source cache
/// (`module_consts_by_source`), never the global last-wins `module_const_map`:
///
/// - **own-wins**: the querying module's OWN const author is selected outright.
/// - else the FLAT-import-reachable const authors: exactly one → it; ≥2 distinct
/// → `.ambiguous` (never a silent first-/last-wins pick).
/// - none visible → `.none` (a namespaced-only const must be qualified `ns.X`;
///   a non-const name folds to `.none` too).
///
/// A main-file body carries a null `current_source_file` (it IS the root), so
/// the querying module is `main_file` there; a fully unwired index (no source
/// at all) falls open to the global registration, byte-identical to the legacy
/// reader for the registration / comptime-host path.
pub fn selectModuleConst(self: *Lowering, name: []const u8) ConstAuthor {
    const from = self.current_source_file orelse self.main_file orelse {
        if (self.program_index.module_const_map.get(name)) |ci| return .{ .resolved = .{ .info = ci, .source = null } };
        return .none;
    };
    var res = self.resolver();
    const set = res.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (set.flat.len > 0) self.alloc.free(set.flat);
    if (set.own) |o| {
        if (self.sourceModuleConst(o.source, name)) |ci| return .{ .resolved = .{ .info = ci, .source = o.source } };
        // The reader's own module authors `name` as a const that never
        // materialized a per-source value (unsupported shape). Owning the
        // name blocks borrowing a flat import's / the global registration's
        // same-named const (issue 0115).
        if (o.raw == .const_decl) return .own_opaque;
    }
    var the_one: ?SelectedConst = null;
    var count: usize = 0;
    for (set.flat) |fa| {
        const ci = self.sourceModuleConst(fa.source, name) orelse continue;
        count += 1;
        if (count >= 2) return .ambiguous;
        the_one = .{ .info = ci, .source = fa.source };
    }
    if (the_one) |sc| return .{ .resolved = sc };
    return .none;
}

/// `<array const>.len` as a compile-time integer — the SELECTED author's
/// element count (E2/F2 source-aware, like every const fold).
pub fn foldConstAggLen(self: *Lowering, name: []const u8) ?i64 {
    return switch (self.selectModuleConst(name)) {
        .resolved => |sel| if (sel.info.value.data == .array_literal)
            @intCast(sel.info.value.data.array_literal.elements.len)
        else
            null,
        .own_opaque, .ambiguous, .none => null,
    };
}

/// `K[<const idx>]` over an ARRAY const: the element's compile-time integer
/// value, folded in the AUTHOR's context. Out-of-range diagnoses loudly —
/// never a wrap or a silent null-into-runtime.
pub fn foldConstArrayElem(self: *Lowering, name: []const u8, idx: i64, span: ?ast.Span, frame: ?*const ConstFoldFrame) ?i64 {
    switch (self.selectModuleConst(name)) {
        .resolved => |sel| {
            if (sel.info.value.data != .array_literal) return null;
            const elems = sel.info.value.data.array_literal.elements;
            if (idx < 0 or idx >= elems.len) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, span, "index {d} is out of bounds for constant '{s}' ({d} elements)", .{ idx, name, elems.len });
                return null;
            }
            if (constFoldFrameContains(frame, name, sel.source)) return null;
            var f = ConstFoldFrame{ .name = name, .source = sel.source, .parent = frame };
            const restore = self.pinConstAuthorSource(sel.source);
            defer restore.unpin();
            return program_index_mod.evalConstIntExpr(elems[@intCast(idx)], SourceConstCtx{ .lowering = self, .frame = &f });
        },
        .own_opaque, .ambiguous, .none => return null,
    }
}

/// `<struct const>.field` as a compile-time integer — the SELECTED author's
/// field initializer, matched by name (named inits) or position, folded in
/// the author's context.
pub fn foldConstStructField(self: *Lowering, name: []const u8, field: []const u8, frame: ?*const ConstFoldFrame) ?i64 {
    switch (self.selectModuleConst(name)) {
        .resolved => |sel| {
            if (sel.info.value.data != .struct_literal) return null;
            const sl = &sel.info.value.data.struct_literal;
            const init_expr: ?*const Node = blk: {
                const has_names = sl.field_inits.len > 0 and sl.field_inits[0].name != null;
                if (has_names) {
                    for (sl.field_inits) |fi| {
                        if (fi.name) |n| if (std.mem.eql(u8, n, field)) break :blk fi.value;
                    }
                    break :blk null;
                }
                // Positional inits: index via the struct type's field order.
                if (sel.info.ty.isBuiltin()) break :blk null;
                const ti = self.module.types.get(sel.info.ty);
                if (ti != .@"struct") break :blk null;
                for (ti.@"struct".fields, 0..) |sf, i| {
                    if (std.mem.eql(u8, self.module.types.getString(sf.name), field)) {
                        if (i < sl.field_inits.len) break :blk sl.field_inits[i].value;
                        break :blk null;
                    }
                }
                break :blk null;
            };
            const e = init_expr orelse return null;
            if (constFoldFrameContains(frame, name, sel.source)) return null;
            var f = ConstFoldFrame{ .name = name, .source = sel.source, .parent = frame };
            const restore = self.pinConstAuthorSource(sel.source);
            defer restore.unpin();
            return program_index_mod.evalConstIntExpr(e, SourceConstCtx{ .lowering = self, .frame = &f });
        },
        .own_opaque, .ambiguous, .none => return null,
    }
}

/// `source`'s per-source const cache entry for `name` (E0's
/// `module_consts_by_source` write side), or null.
pub fn sourceModuleConst(self: *Lowering, source: []const u8, name: []const u8) ?ModuleConstInfo {
    const inner = self.program_index.module_consts_by_source.get(source) orelse return null;
    return inner.get(name);
}

pub const GlobalAuthor = union(enum) {
    /// The visible author's OWN global (per-source partition) — emit it.
    resolved: program_index_mod.GlobalInfo,
    /// The visible author declares `name` but NOT as a global (a const, fn,
    /// type, ...) — skip the global arm and let the later arms decide.
    not_a_global,
    /// ≥2 distinct flat-visible authors and none is the reader's own.
    ambiguous,
    /// `name` is authored somewhere, but no author is visible from the
    /// reading module (namespaced-only / beyond one flat hop).
    not_visible,
    /// No raw author anywhere — a compiler-synthesized global (FFI metadata,
    /// trace machinery, ...). Emit the global registration directly.
    untracked,
};

/// The source-aware GLOBAL author of `name` from the querying module — the
/// global-variable analogue of `selectModuleConst`. The global registry
/// (`global_names`) is last-wins across modules; this selects the AUTHOR
/// first (own wins, then the single direct flat author) and reads the
/// global from the SELECTED author's per-source partition, so a module
/// whose own `K` is a const (or whose flat import authors `K`) never has a
/// bare `K` hijacked by an unrelated module's same-named global.
pub fn selectGlobalAuthor(self: *Lowering, name: []const u8) GlobalAuthor {
    const from = self.current_source_file orelse self.main_file orelse return .untracked;
    var res = self.resolver();
    const set = res.collectVisibleAuthors(name, from, .user_bare_flat);
    defer if (set.flat.len > 0) self.alloc.free(set.flat);
    if (set.own) |o| return globalAuthorAt(self, o, name);
    if (set.flat.len >= 2) return .ambiguous;
    if (set.flat.len == 1) return globalAuthorAt(self, set.flat[0], name);
    return if (anyRawAuthor(self, name)) .not_visible else .untracked;
}

fn globalAuthorAt(self: *Lowering, author: resolver_mod.RawAuthor, name: []const u8) GlobalAuthor {
    if (self.program_index.globals_by_source.get(author.source)) |inner| {
        if (inner.get(name)) |g| return .{ .resolved = g };
    }
    // A var_decl author with no per-source registration: the decl was deduped
    // at flat-merge (two modules declaring the same extern symbol), so the
    // global registered under the surviving author's source. The author IS a
    // global — serve the symbol's registration.
    if (author.raw == .var_decl) {
        if (self.program_index.global_names.get(name)) |g| return .{ .resolved = g };
    }
    return .not_a_global;
}

/// The source-aware global for a bare reference to `name`, or null when the
/// reference does not (visibly) resolve to a global — the ambiguous /
/// not-visible outcomes diagnose here and return null so the caller's
/// fall-through path runs. Sites needing custom placeholder emission use
/// `selectGlobalAuthor` directly.
pub fn resolveGlobalRef(self: *Lowering, name: []const u8, span: ?ast.Span) ?program_index_mod.GlobalInfo {
    const gi = self.program_index.global_names.get(name) orelse return null;
    switch (self.selectGlobalAuthor(name)) {
        .resolved => |g| return g,
        .not_a_global => return null,
        .ambiguous => {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "'{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{name});
            return null;
        },
        .not_visible => {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "'{s}' is not visible; #import the module that declares it", .{name});
            return null;
        },
        .untracked => return gi,
    }
}

/// True when ANY module's raw-decl index carries `name` — distinguishes a
/// user-authored-but-not-visible name from a compiler-synthesized one.
fn anyRawAuthor(self: *Lowering, name: []const u8) bool {
    const decls = self.program_index.module_decls orelse return false;
    var it = decls.valueIterator();
    while (it.next()) |mod| {
        if (mod.names.contains(name)) return true;
    }
    return false;
}

/// Saved `current_source_file` for a const-author pin; `unpin()` restores it.
const ConstSourcePin = struct {
    lowering: *Lowering,
    saved: ?[]const u8,
    active: bool,
    pub fn unpin(self: ConstSourcePin) void {
        if (self.active) self.lowering.setCurrentSourceFile(self.saved);
    }
};

/// Pin `current_source_file` to a SELECTED const's AUTHOR source while its RHS
/// is folded / lowered, so nested same-name leaves resolve in the author's
/// visibility context (F1): `K :: M + 1` selected from `a.sx` always folds `M`
/// against `a.sx`, regardless of which module read `K`. A null author (the
/// fully-unwired fallback) leaves the context untouched. Single-author programs
/// pin to the source they were already in → byte-identical.
pub fn pinConstAuthorSource(self: *Lowering, source: ?[]const u8) ConstSourcePin {
    if (source) |s| {
        const saved = self.current_source_file;
        self.setCurrentSourceFile(s);
        return .{ .lowering = self, .saved = saved, .active = true };
    }
    return .{ .lowering = self, .saved = self.current_source_file, .active = false };
}

/// Apply the unified float→int narrowing rule to a typed-binding initializer
/// EXPRESSION `node` whose declared type is `dst` (a typed local, a struct
/// field default, or a call argument incl. an expanded param default). When
/// `node` is a COMPILE-TIME float narrowing into an integer type:
///   - an INTEGRAL value (`4.0`, `M + 2.0`) folds to its `constInt`;
///   - a NON-integral value (`1.5`, `M + 0.5`) emits the narrowing
///     diagnostic and returns a placeholder so lowering finishes.
/// Returns null — so the caller lowers `node` normally — when the rule does
/// not apply: `dst` is not an integer, `node` is not statically float-typed,
/// or `node` is not a compile-time constant (a genuine runtime float keeps
/// truncating, and `xx` / `cast` keep their explicit-truncation escape since
/// a cast node's inferred type is the destination integer, not a float).
/// Reuses `program_index.evalConstIntExpr` (exact integral fold) +
/// `evalConstFloatExpr` (non-integral detection) + `floatToIntExact`.
pub fn foldComptimeFloatInit(self: *Lowering, node: *const Node, dst: TypeId) ?Ref {
    if (!self.isIntEx(dst)) return null;
    // PURE & side-effect-free, so it runs FIRST: a runtime / non-comptime /
    // non-numeric node — incl. a `$pack[i]` index expression — folds to null
    // and is left to the normal path untouched. (Calling `inferExprType` on
    // a pack-index value before this guard would spuriously resolve the
    // enclosing pack type outside an active binding.)
    const fv = program_index_mod.evalConstFloatExpr(node, self) orelse return null;
    // Only a FLOAT-flavored initializer narrows here; a plain comptime int
    // (`5`, `M + 2`) is left to the normal integer path. Safe to infer now —
    // `evalConstFloatExpr` only succeeds for literal / const-arithmetic
    // nodes, never an unbound pack index. `inferExprType` is the primary
    // signal, but it reads a const's DECLARED type — which is a placeholder
    // `i64` for an untyped float-EXPRESSION const (`ME :: 4.0 + 1.0`), so
    // `ME / 2` would look like integer division; `isFloatValuedExpr` (judging
    // by VALUE) catches that case so it narrows under the unified rule too.
    if (!isFloat(self.inferExprType(node)) and !program_index_mod.isFloatValuedExpr(node, self)) return null;
    // Integral comptime float folds to its int (`floatToIntExact`, the same
    // facility the array-dim / `$K: Count` paths use); a non-integral one is
    // the narrowing error.
    if (program_index_mod.floatToIntExact(fv)) |iv| return self.builder.constInt(iv, dst);
    self.diagNonIntegralNarrow(node.span, fv, dst);
    return self.builder.constInt(0, dst);
}
