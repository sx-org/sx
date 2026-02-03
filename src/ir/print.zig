const std = @import("std");
const types = @import("types.zig");
const inst_mod = @import("inst.zig");
const mod_mod = @import("module.zig");

const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const StringId = types.StringId;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const FuncId = inst_mod.FuncId;
const GlobalId = inst_mod.GlobalId;
const Inst = inst_mod.Inst;
const Op = inst_mod.Op;
const Function = inst_mod.Function;
const Block = inst_mod.Block;
const Global = inst_mod.Global;
const ConstantValue = inst_mod.ConstantValue;
const Module = mod_mod.Module;

const Writer = *std.Io.Writer;

// ── Public API ──────────────────────────────────────────────────────────

pub fn printModule(module: *const Module, writer: Writer) !void {
    // Print globals
    for (module.globals.items, 0..) |global, i| {
        try printGlobal(&global, @intCast(i), module, writer);
    }
    if (module.globals.items.len > 0 and module.functions.items.len > 0) {
        try writer.writeByte('\n');
    }
    // Print functions
    for (module.functions.items, 0..) |*func, i| {
        if (i > 0) try writer.writeByte('\n');
        try printFunction(func, @intCast(i), module, writer);
    }
}

pub fn printFunction(func: *const Function, func_idx: u32, module: *const Module, writer: Writer) !void {
    const tt = &module.types;

    // Signature
    if (func.is_extern) try writer.writeAll("extern ");
    if (func.isComptimeOnly()) try writer.writeAll("comptime ");
    try writer.writeAll("func @");
    try writer.writeAll(tt.getString(func.name));
    try writer.writeByte('(');
    for (func.params, 0..) |param, i| {
        if (i > 0) try writer.writeAll(", ");
        const pname = tt.getString(param.name);
        if (pname.len > 0) {
            try writer.writeAll(pname);
            try writer.writeAll(": ");
        }
        try writeType(param.ty, tt, writer);
    }
    try writer.writeAll(") -> ");
    try writeType(func.ret, tt, writer);

    if (func.is_extern) {
        try writer.writeAll(";\n");
        return;
    }

    try writer.writeAll(" {\n");

    // Blocks — each block tracks its own first_ref from emission order
    _ = func_idx;
    for (func.blocks.items, 0..) |*block, bi| {
        var ref_counter: u32 = block.first_ref;
        try printBlock(block, @intCast(bi), tt, &ref_counter, writer);
    }

    try writer.writeAll("}\n");
}

fn printGlobal(global: *const Global, _: u32, module: *const Module, writer: Writer) !void {
    const tt = &module.types;
    if (global.is_extern) try writer.writeAll("extern ");
    if (global.is_const) try writer.writeAll("const ") else try writer.writeAll("global ");
    try writer.writeAll("@");
    try writer.writeAll(tt.getString(global.name));
    try writer.writeAll(": ");
    try writeType(global.ty, tt, writer);
    if (global.init_val) |init| {
        try writer.writeAll(" = ");
        try writeConstant(init, writer);
    }
    if (global.comptime_func) |fid| {
        try writer.print(" = #run @{d}", .{fid.index()});
    }
    try writer.writeAll(";\n");
}

fn printBlock(block: *const Block, block_idx: u32, tt: *const TypeTable, ref_counter: *u32, writer: Writer) !void {
    // Block header
    try writer.writeAll("  ");
    const name = tt.getString(block.name);
    if (name.len > 0) {
        try writer.writeAll(name);
    } else {
        try writer.print("bb{d}", .{block_idx});
    }
    if (block.params.len > 0) {
        try writer.writeByte('(');
        for (block.params, 0..) |pty, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeType(pty, tt, writer);
        }
        try writer.writeByte(')');
    }
    try writer.writeAll(":\n");

    // Instructions
    for (block.insts.items) |*instruction| {
        try printInst(instruction, ref_counter.*, tt, writer);
        ref_counter.* += 1;
    }
}

fn printInst(instruction: *const Inst, ref_idx: u32, tt: *const TypeTable, writer: Writer) !void {
    const op = instruction.op;
    const ty = instruction.ty;

    // Check if this is a void/terminator instruction (no result)
    const has_result = !isVoidOp(op);

    try writer.writeAll("    ");
    if (has_result) {
        try writer.print("%{d} = ", .{ref_idx});
    }

    switch (op) {
        // ── Constants ───────────────────────────────────────────
        .const_int => |v| try writer.print("const {d} : ", .{v}),
        .const_float => |v| try writer.print("const {d:.6} : ", .{v}),
        .const_bool => |v| try writer.print("const {s} : ", .{if (v) "true" else "false"}),
        .const_string => |sid| {
            try writer.writeAll("const \"");
            try writer.writeAll(tt.getString(sid));
            try writer.writeAll("\" : ");
        },
        .const_null => try writer.writeAll("const null : "),
        .const_undef => try writer.writeAll("const undef : "),
        .is_comptime => try writer.writeAll("is_comptime : "),
        .interp_print_frames => try writer.writeAll("interp_print_frames : "),
        .trace_frame => try writer.writeAll("trace_frame : "),
        .trace_resolve => |u| try writer.print("trace_resolve %{d} : ", .{u.operand.index()}),
        .const_type => |tid| try writer.print("const type({s}) : ", .{tt.typeName(tid)}),

        // ── Arithmetic ──────────────────────────────────────────
        .add => |b| try writer.print("add %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .sub => |b| try writer.print("sub %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .mul => |b| try writer.print("mul %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .div => |b| try writer.print("div %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .mod => |b| try writer.print("mod %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .neg => |u| try writer.print("neg %{d} : ", .{u.operand.index()}),

        // ── Bitwise ─────────────────────────────────────────────
        .bit_and => |b| try writer.print("bit_and %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .bit_or => |b| try writer.print("bit_or %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .bit_xor => |b| try writer.print("bit_xor %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .bit_not => |u| try writer.print("bit_not %{d} : ", .{u.operand.index()}),
        .shl => |b| try writer.print("shl %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .shr => |b| try writer.print("shr %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),

        // ── Comparison ──────────────────────────────────────────
        .cmp_eq => |b| try writer.print("cmp_eq %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .cmp_ne => |b| try writer.print("cmp_ne %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .cmp_lt => |b| try writer.print("cmp_lt %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .cmp_le => |b| try writer.print("cmp_le %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .cmp_gt => |b| try writer.print("cmp_gt %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .cmp_ge => |b| try writer.print("cmp_ge %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .str_eq => |b| try writer.print("str_eq %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .str_ne => |b| try writer.print("str_ne %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),

        // ── Logical ─────────────────────────────────────────────
        .bool_and => |b| try writer.print("bool_and %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .bool_or => |b| try writer.print("bool_or %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),
        .bool_not => |u| try writer.print("bool_not %{d} : ", .{u.operand.index()}),

        // ── Conversions ─────────────────────────────────────────
        .widen => |c| {
            try writer.print("widen %{d} : ", .{c.operand.index()});
            try writeType(c.from, tt, writer);
            try writer.writeAll(" -> ");
            try writeType(c.to, tt, writer);
            try writer.writeByte('\n');
            return;
        },
        .narrow => |c| {
            try writer.print("narrow %{d} : ", .{c.operand.index()});
            try writeType(c.from, tt, writer);
            try writer.writeAll(" -> ");
            try writeType(c.to, tt, writer);
            try writer.writeByte('\n');
            return;
        },
        .bitcast => |c| {
            try writer.print("bitcast %{d} : ", .{c.operand.index()});
            try writeType(c.from, tt, writer);
            try writer.writeAll(" -> ");
            try writeType(c.to, tt, writer);
            try writer.writeByte('\n');
            return;
        },
        .int_to_float => |c| {
            try writer.print("int_to_float %{d} : ", .{c.operand.index()});
            try writeType(c.from, tt, writer);
            try writer.writeAll(" -> ");
            try writeType(c.to, tt, writer);
            try writer.writeByte('\n');
            return;
        },
        .float_to_int => |c| {
            try writer.print("float_to_int %{d} : ", .{c.operand.index()});
            try writeType(c.from, tt, writer);
            try writer.writeAll(" -> ");
            try writeType(c.to, tt, writer);
            try writer.writeByte('\n');
            return;
        },

        // ── Memory ──────────────────────────────────────────────
        .alloca => |aty| {
            try writer.writeAll("alloca ");
            try writeType(aty, tt, writer);
            try writer.writeAll(" : ");
        },
        .load => |u| try writer.print("load %{d} : ", .{u.operand.index()}),
        .store => |s| {
            try writer.print("store %{d}, %{d}\n", .{ s.ptr.index(), s.val.index() });
            return;
        },
        .atomic_load => |a| try writer.print("atomic_load %{d} {s} : ", .{ a.ptr.index(), @tagName(a.ordering) }),
        .atomic_store => |a| {
            try writer.print("atomic_store %{d}, %{d} {s}\n", .{ a.ptr.index(), a.val.index(), @tagName(a.ordering) });
            return;
        },
        .atomic_rmw => |a| try writer.print("atomic_rmw.{s} %{d}, %{d} {s} : ", .{ @tagName(a.kind), a.ptr.index(), a.operand.index(), @tagName(a.ordering) }),
        .atomic_cmpxchg => |a| try writer.print("atomic_cmpxchg{s} %{d}, %{d}, %{d} {s} {s} : ", .{ if (a.weak) "_weak" else "", a.ptr.index(), a.cmp.index(), a.new.index(), @tagName(a.success_ordering), @tagName(a.failure_ordering) }),
        .atomic_fence => |a| {
            try writer.print("atomic_fence {s}\n", .{@tagName(a.ordering)});
            return;
        },
        // ── Struct ops ──────────────────────────────────────────
        .struct_init => |agg| {
            try writer.writeAll("struct_init [");
            for (agg.fields, 0..) |f, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("%{d}", .{f.index()});
            }
            try writer.writeAll("] : ");
        },
        .struct_get => |fa| try writer.print("struct_get %{d}, {d} : ", .{ fa.base.index(), fa.field_index }),
        .struct_gep => |fa| try writer.print("struct_gep %{d}, {d} : ", .{ fa.base.index(), fa.field_index }),

        // ── Enum ops ────────────────────────────────────────────
        .enum_init => |ei| {
            if (ei.payload.isNone()) {
                try writer.print("enum_init tag={d} : ", .{ei.tag});
            } else {
                try writer.print("enum_init tag={d}, payload=%{d} : ", .{ ei.tag, ei.payload.index() });
            }
        },
        .enum_tag => |u| try writer.print("enum_tag %{d} : ", .{u.operand.index()}),
        .enum_payload => |fa| try writer.print("enum_payload %{d}, {d} : ", .{ fa.base.index(), fa.field_index }),

        // ── Union ops ───────────────────────────────────────────
        .union_get => |fa| try writer.print("union_get %{d}, {d} : ", .{ fa.base.index(), fa.field_index }),
        .union_gep => |fa| try writer.print("union_gep %{d}, {d} : ", .{ fa.base.index(), fa.field_index }),

        // ── Array/Slice ops ─────────────────────────────────────
        .index_get => |b| try writer.print("index_get %{d}[%{d}] : ", .{ b.lhs.index(), b.rhs.index() }),
        .index_gep => |b| try writer.print("index_gep %{d}[%{d}] : ", .{ b.lhs.index(), b.rhs.index() }),
        .length => |u| try writer.print("length %{d} : ", .{u.operand.index()}),
        .data_ptr => |u| try writer.print("data_ptr %{d} : ", .{u.operand.index()}),
        .subslice => |s| try writer.print("subslice %{d}[%{d}..%{d}] : ", .{ s.base.index(), s.lo.index(), s.hi.index() }),
        .array_to_slice => |u| try writer.print("array_to_slice %{d} : ", .{u.operand.index()}),

        // ── Tuple ops ───────────────────────────────────────────
        .tuple_init => |agg| {
            try writer.writeAll("tuple_init [");
            for (agg.fields, 0..) |f, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("%{d}", .{f.index()});
            }
            try writer.writeAll("] : ");
        },
        .tuple_get => |fa| try writer.print("tuple_get %{d}, {d} : ", .{ fa.base.index(), fa.field_index }),

        // ── Optional ops ────────────────────────────────────────
        .optional_wrap => |u| try writer.print("optional_wrap %{d} : ", .{u.operand.index()}),
        .optional_unwrap => |u| try writer.print("optional_unwrap %{d} : ", .{u.operand.index()}),
        .optional_has_value => |u| try writer.print("optional_has_value %{d} : ", .{u.operand.index()}),
        .optional_coalesce => |b| try writer.print("optional_coalesce %{d}, %{d} : ", .{ b.lhs.index(), b.rhs.index() }),

        // ── Pointer ops ─────────────────────────────────────────
        .addr_of => |u| try writer.print("addr_of %{d} : ", .{u.operand.index()}),
        .deref => |u| try writer.print("deref %{d} : ", .{u.operand.index()}),

        // ── Vector ops ──────────────────────────────────────────
        .vec_splat => |u| try writer.print("vec_splat %{d} : ", .{u.operand.index()}),
        .vec_extract => |b| try writer.print("vec_extract %{d}[%{d}] : ", .{ b.lhs.index(), b.rhs.index() }),
        .vec_insert => |t| try writer.print("vec_insert %{d}[%{d}] = %{d} : ", .{ t.a.index(), t.b.index(), t.c.index() }),

        // ── Calls ───────────────────────────────────────────────
        .call => |c| {
            try writer.print("call @{d}(", .{c.callee.index()});
            try writeArgs(c.args, writer);
            try writer.writeAll(") : ");
        },
        .call_indirect => |c| {
            try writer.print("call_indirect %{d}(", .{c.callee.index()});
            try writeArgs(c.args, writer);
            try writer.writeAll(") : ");
        },
        .call_closure => |c| {
            try writer.print("call_closure %{d}(", .{c.callee.index()});
            try writeArgs(c.args, writer);
            try writer.writeAll(") : ");
        },
        .call_builtin => |c| {
            try writer.print("call_builtin {s}(", .{@tagName(c.builtin)});
            try writeArgs(c.args, writer);
            try writer.writeAll(") : ");
        },
        .objc_msg_send => |c| {
            try writer.print("objc_msg_send recv=%{d} sel=%{d}(", .{ c.recv.index(), c.sel.index() });
            try writeArgs(c.args, writer);
            try writer.writeAll(") : ");
        },
        .jni_msg_send => |c| {
            const kind: []const u8 = if (c.is_static) "static" else "instance";
            try writer.print("jni_msg_send {s} env=%{d} target=%{d} name=%{d} sig=%{d}(", .{
                kind, c.env.index(), c.target.index(), c.name.index(), c.sig.index(),
            });
            try writeArgs(c.args, writer);
            try writer.writeAll(") : ");
        },
        .inline_asm => |a| {
            try writer.print("inline_asm{s} tmpl=#{d} ops={d} clobbers={d} : ", .{
                if (a.has_side_effects) " volatile" else "",
                a.template.index(),
                a.operands.len,
                a.clobbers.len,
            });
        },
        // ── Closure ─────────────────────────────────────────────
        .closure_create => |cc| {
            try writer.print("closure_create @{d}", .{cc.func.index()});
            if (!cc.env.isNone()) {
                try writer.print(", env=%{d}", .{cc.env.index()});
            }
            try writer.writeAll(" : ");
        },

        // ── Globals ─────────────────────────────────────────────
        .global_get => |gid| try writer.print("global_get @{d} : ", .{gid.index()}),
        .global_addr => |gid| try writer.print("global_addr @{d} : ", .{gid.index()}),
        .func_ref => |fid| try writer.print("func_ref @{d} : ", .{@intFromEnum(fid)}),
        .global_set => |gs| {
            try writer.print("global_set @{d}, %{d}\n", .{ gs.global.index(), gs.value.index() });
            return;
        },

        // ── Block params ────────────────────────────────────────
        .block_param => |bp| try writer.print("block_param bb{d}[{d}] : ", .{ bp.block.index(), bp.param_index }),

        // ── Any ─────────────────────────────────────────────────
        .box_any => |ba| try writer.print("box_any %{d} : ", .{ba.operand.index()}),
        .unbox_any => |u| try writer.print("unbox_any %{d} : ", .{u.operand.index()}),
        .any_data => |u| try writer.print("any_data %{d} : ", .{u.operand.index()}),
        .make_any => |ma| try writer.print("make_any %{d}, %{d} : ", .{ ma.tag.index(), ma.data.index() }),

        // ── Reflection ──────────────────────────────────────────
        .field_name_get => |fr| try writer.print("field_name_get T{d}[%{d}] : ", .{ fr.struct_type.index(), fr.index.index() }),
        .field_value_get => |fr| try writer.print("field_value_get %{d}, T{d}[%{d}] : ", .{ fr.base.index(), fr.struct_type.index(), fr.index.index() }),
        .error_tag_name_get => |u| try writer.print("error_tag_name_get %{d} : ", .{u.operand.index()}),

        // ── Terminators ─────────────────────────────────────────
        .br => |b| {
            try writer.print("br bb{d}", .{b.target.index()});
            if (b.args.len > 0) {
                try writer.writeByte('(');
                try writeArgs(b.args, writer);
                try writer.writeByte(')');
            }
            try writer.writeByte('\n');
            return;
        },
        .cond_br => |cb| {
            try writer.print("cond_br %{d}, bb{d}", .{ cb.cond.index(), cb.then_target.index() });
            if (cb.then_args.len > 0) {
                try writer.writeByte('(');
                try writeArgs(cb.then_args, writer);
                try writer.writeByte(')');
            }
            try writer.print(", bb{d}", .{cb.else_target.index()});
            if (cb.else_args.len > 0) {
                try writer.writeByte('(');
                try writeArgs(cb.else_args, writer);
                try writer.writeByte(')');
            }
            try writer.writeByte('\n');
            return;
        },
        .switch_br => |sb| {
            try writer.print("switch_br %{d} [", .{sb.operand.index()});
            for (sb.cases, 0..) |case, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{d} -> bb{d}", .{ case.value, case.target.index() });
            }
            try writer.print("] default bb{d}\n", .{sb.default.index()});
            return;
        },
        .ret => |u| {
            try writer.print("ret %{d}\n", .{u.operand.index()});
            return;
        },
        .ret_void => {
            try writer.writeAll("ret void\n");
            return;
        },
        .@"unreachable" => {
            try writer.writeAll("unreachable\n");
            return;
        },

        // ── Misc ────────────────────────────────────────────────
        .placeholder => |sid| {
            try writer.writeAll("placeholder \"");
            try writer.writeAll(tt.getString(sid));
            try writer.writeAll("\" : ");
        },
    }

    // Default: print the result type
    try writeType(ty, tt, writer);
    try writer.writeByte('\n');
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn writeType(id: TypeId, tt: *const TypeTable, writer: Writer) !void {
    // Fast path for builtins
    if (id.isBuiltin()) {
        try writer.writeAll(tt.typeName(id));
        return;
    }
    // Composite types — format recursively
    const info = tt.get(id);
    switch (info) {
        .@"struct" => |s| try writer.writeAll(tt.getString(s.name)),
        .@"enum" => |e| try writer.writeAll(tt.getString(e.name)),
        .@"union" => |u| try writer.writeAll(tt.getString(u.name)),
        .tagged_union => |u| try writer.writeAll(tt.getString(u.name)),
        .protocol => |p| try writer.writeAll(tt.getString(p.name)),
        .error_set => |e| try writer.writeAll(tt.getString(e.name)),
        .pointer => |p| {
            try writer.writeByte('*');
            try writeType(p.pointee, tt, writer);
        },
        .many_pointer => |p| {
            try writer.writeAll("[*]");
            try writeType(p.element, tt, writer);
        },
        .slice => |s| {
            try writer.writeAll("[]");
            try writeType(s.element, tt, writer);
        },
        .array => |a| {
            try writer.print("[{d}]", .{a.length});
            try writeType(a.element, tt, writer);
        },
        .optional => |o| {
            try writer.writeByte('?');
            try writeType(o.child, tt, writer);
        },
        .vector => |v| {
            try writer.print("Vector({d}, ", .{v.length});
            try writeType(v.element, tt, writer);
            try writer.writeByte(')');
        },
        .function => |f| {
            try writer.writeByte('(');
            for (f.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeType(p, tt, writer);
            }
            try writer.writeAll(") -> ");
            try writeType(f.ret, tt, writer);
        },
        .closure => |c| {
            try writer.writeAll("closure(");
            for (c.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeType(p, tt, writer);
            }
            try writer.writeAll(") -> ");
            try writeType(c.ret, tt, writer);
        },
        .tuple => |t| {
            try writer.writeByte('(');
            for (t.fields, 0..) |f, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeType(f, tt, writer);
            }
            try writer.writeByte(')');
        },
        else => try writer.writeAll(tt.typeName(id)),
    }
}

fn writeArgs(args: []const Ref, writer: Writer) !void {
    for (args, 0..) |arg, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("%{d}", .{arg.index()});
    }
}

fn writeConstant(val: ConstantValue, writer: Writer) !void {
    switch (val) {
        .int => |v| try writer.print("{d}", .{v}),
        .float => |v| try writer.print("{d:.6}", .{v}),
        .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
        .string => try writer.writeAll("\"...\""),
        .null_val => try writer.writeAll("null"),
        .undef => try writer.writeAll("undef"),
        .zeroinit => try writer.writeAll("zeroinit"),
        .aggregate => try writer.writeAll("{...}"),
        .vtable => try writer.writeAll("vtable{...}"),
        .func_ref => |fid| try writer.print("func_ref(#{d})", .{fid.index()}),
        .global_ref => |gid| try writer.print("global_ref(#{d})", .{gid.index()}),
    }
}

fn isVoidOp(op: Op) bool {
    return switch (op) {
        .store, .global_set, .br, .cond_br, .switch_br, .ret, .ret_void, .@"unreachable" => true,
        else => false,
    };
}
