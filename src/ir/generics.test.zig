// The generic substitution + mono-key owner
// (`GenericResolver`). Reached via `ir.GenericResolver{ .l = &lowering }`,
// mirroring how calls.test.zig drives `CallResolver`.

const std = @import("std");
const ast = @import("../ast.zig");
const Node = ast.Node;

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Lowering = ir_mod.Lowering;
const GenericResolver = ir_mod.GenericResolver;

fn typeKeyword(alloc: std.mem.Allocator, name: []const u8) *Node {
    const n = alloc.create(Node) catch unreachable;
    n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .type_expr = .{ .name = name, .is_generic = false } } };
    return n;
}

test "generics: mangleTypeName encodes the mono-key fragment per type shape" {
    // Arena: the compound arms allocate fragment strings via the module
    // allocator (`allocPrint` / ArrayList) and never free them — the real
    // compiler runs in the compile arena, so an arena keeps the leak checker
    // clean without changing the encoding under test.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const gr = GenericResolver{ .l = &l };
    const tt = &module.types;

    // Builtins — the leaf fragments `mangleGenericName` concatenates per
    // bound type param (`base__<frag>...`).
    try std.testing.expectEqualStrings("i64", gr.mangleTypeName(.i64));
    try std.testing.expectEqualStrings("u8", gr.mangleTypeName(.u8));
    try std.testing.expectEqualStrings("f32", gr.mangleTypeName(.f32));
    try std.testing.expectEqualStrings("bool", gr.mangleTypeName(.bool));
    try std.testing.expectEqualStrings("any", gr.mangleTypeName(.any));
    try std.testing.expectEqualStrings("string", gr.mangleTypeName(.string));

    // Compound shapes — prefix + recursive inner fragment.
    try std.testing.expectEqualStrings("ptr_i64", gr.mangleTypeName(tt.ptrTo(.i64)));
    try std.testing.expectEqualStrings("opt_i64", gr.mangleTypeName(tt.optionalOf(.i64)));
    try std.testing.expectEqualStrings("ptr_opt_u8", gr.mangleTypeName(tt.ptrTo(tt.optionalOf(.u8))));
    try std.testing.expectEqualStrings("SL_f64", gr.mangleTypeName(tt.intern(.{ .slice = .{ .element = .f64 } })));
    try std.testing.expectEqualStrings("mptr_u8", gr.mangleTypeName(tt.intern(.{ .many_pointer = .{ .element = .u8 } })));
    try std.testing.expectEqualStrings("AR_4_i32", gr.mangleTypeName(tt.intern(.{ .array = .{ .element = .i32, .length = 4 } })));
    try std.testing.expectEqualStrings("vec_3_f32", gr.mangleTypeName(tt.intern(.{ .vector = .{ .element = .f32, .length = 3 } })));

    // Named aggregate → its declared name.
    const pt = tt.intern(.{ .@"struct" = .{ .name = tt.internString("Point"), .fields = &.{} } });
    try std.testing.expectEqualStrings("Point", gr.mangleTypeName(pt));

    // A formed int and a struct spelled like that width are two types, so
    // their fragments differ.
    try std.testing.expectEqualStrings("int_7_u", gr.mangleTypeName(tt.intern(.{ .unsigned = 7 })));
    const width_named = tt.intern(.{ .@"struct" = .{ .name = tt.internString("u7"), .fields = &.{} } });
    try std.testing.expectEqualStrings("u7", gr.mangleTypeName(width_named));

    // Anonymous product mangles as its interned `__anon` struct name.
    const tup = tt.internProduct(&[_]TypeId{ .i64, .bool }, null);
    try std.testing.expectEqualStrings("__anon", gr.mangleTypeName(tup));

    // The `Lowering` wrapper delegates here — same result.
    try std.testing.expectEqualStrings("ptr_i64", l.mangleTypeName(tt.ptrTo(.i64)));
}

test "generics: inferGenericReturnType binds explicit type args, resolves return, restores bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const gr = GenericResolver{ .l = &l };

    // pair :: ($T: Type, a: T, b: T) -> T — the return type IS the bound `T`.
    const tps = [_]ast.StructTypeParam{.{ .name = "T", .constraint = typeKeyword(alloc, "Type") }};
    const params = [_]ast.Param{
        .{ .name = "T", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "Type") },
        .{ .name = "a", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
        .{ .name = "b", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
    };
    const body = alloc.create(Node) catch unreachable;
    body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{} } } };
    const fd = ast.FnDecl{ .name = "pair", .params = &params, .return_type = typeKeyword(alloc, "T"), .body = body, .type_params = &tps };

    // Explicit type arg in position 0 binds `T`; the inferred return follows it.
    const mkCall = struct {
        fn f(a: std.mem.Allocator, type_name: []const u8) ast.Call {
            const targ = typeKeyword(a, type_name);
            const x = a.create(Node) catch unreachable;
            x.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 1 } } };
            const y = a.create(Node) catch unreachable;
            y.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = 2 } } };
            const callee = a.create(Node) catch unreachable;
            callee.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .identifier = .{ .name = "pair" } } };
            const args = a.alloc(*Node, 3) catch unreachable;
            args[0] = targ;
            args[1] = x;
            args[2] = y;
            return .{ .callee = callee, .args = args };
        }
    }.f;

    const c_i64 = mkCall(alloc, "i64");
    try std.testing.expectEqual(TypeId.i64, gr.inferGenericReturnType(&fd, &c_i64));
    const c_f64 = mkCall(alloc, "f64");
    try std.testing.expectEqual(TypeId.f64, gr.inferGenericReturnType(&fd, &c_f64));

    // The scoped binding env restores the prior `type_bindings` (null here) —
    // it must NOT leak the call's temporary bindings.
    try std.testing.expect(l.type_bindings == null);
}

test "generics: buildTypeBindings infers a type param from value args, widest wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const gr = GenericResolver{ .l = &l };

    // add :: (a: T, b: T) -> T  with type param T — NO leading `$T: Type` decl,
    // so T is inferred from the value args (strategy 2), not passed explicitly.
    const tps = [_]ast.StructTypeParam{.{ .name = "T", .constraint = typeKeyword(alloc, "Type") }};
    const params = [_]ast.Param{
        .{ .name = "a", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
        .{ .name = "b", .name_span = .{ .start = 0, .end = 0 }, .type_expr = typeKeyword(alloc, "T") },
    };
    const body = alloc.create(Node) catch unreachable;
    body.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .block = .{ .stmts = &.{} } } };
    const fd = ast.FnDecl{ .name = "add", .params = &params, .return_type = typeKeyword(alloc, "T"), .body = body, .type_params = &tps };

    const intLit = struct {
        fn f(a: std.mem.Allocator, v: i64) *Node {
            const n = a.create(Node) catch unreachable;
            n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .int_literal = .{ .value = v } } };
            return n;
        }
    }.f;
    const floatLit = struct {
        fn f(a: std.mem.Allocator, v: f64) *Node {
            const n = a.create(Node) catch unreachable;
            n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .float_literal = .{ .value = v } } };
            return n;
        }
    }.f;

    // add(1, 2) — both args i64 → T = i64.
    {
        const args = [_]*const Node{ intLit(alloc, 1), intLit(alloc, 2) };
        var bindings = gr.buildTypeBindings(&fd, &args);
        defer bindings.deinit();
        try std.testing.expectEqual(TypeId.i64, bindings.get("T").?);
    }
    // add(1.0, 2) — mixed f64/i64 → widest f64 wins regardless of order.
    {
        const args = [_]*const Node{ floatLit(alloc, 1.0), intLit(alloc, 2) };
        var bindings = gr.buildTypeBindings(&fd, &args);
        defer bindings.deinit();
        try std.testing.expectEqual(TypeId.f64, bindings.get("T").?);
    }
    {
        const args = [_]*const Node{ intLit(alloc, 1), floatLit(alloc, 2.0) };
        var bindings = gr.buildTypeBindings(&fd, &args);
        defer bindings.deinit();
        try std.testing.expectEqual(TypeId.f64, bindings.get("T").?);
    }
}

test "generics: a function type's mono key is injective over its identity fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const gr = GenericResolver{ .l = &l };
    const tt = &module.types;

    // Nominal names crafted to shadow a metadata fragment: the key holds its
    // fields in fixed positions BEFORE the parameter/return fragments, so no
    // return-type spelling can absorb them.
    const r = tt.intern(.{ .@"struct" = .{ .name = tt.internString("R"), .fields = &.{} } });
    const r_cc = tt.intern(.{ .@"struct" = .{ .name = tt.internString("R_cc"), .fields = &.{} } });
    const r_ps0 = tt.intern(.{ .@"struct" = .{ .name = tt.internString("R_ps0"), .fields = &.{} } });

    const d_fixed_rcc = tt.functionTypeCC(&.{}, r_cc, .default);
    const c_fixed_r = tt.functionTypeCC(&.{}, r, .c);
    try std.testing.expect(!std.mem.eql(u8, gr.mangleTypeName(d_fixed_rcc), gr.mangleTypeName(c_fixed_r)));

    const c_var_i = tt.functionTypeVariadic(&.{.i32}, .i64, .c, true);
    const c_fixed_i = tt.functionTypeVariadic(&.{.i32}, .i64, .c, false);
    try std.testing.expect(!std.mem.eql(u8, gr.mangleTypeName(c_var_i), gr.mangleTypeName(c_fixed_i)));

    const d_fixed_rps0 = tt.functionTypeCC(&.{}, r_ps0, .default);
    const d_pack_r = tt.functionTypePack(&.{}, r, .default, 0);
    try std.testing.expect(!std.mem.eql(u8, gr.mangleTypeName(d_fixed_rps0), gr.mangleTypeName(d_pack_r)));
}

test "generic layouts and method bodies follow declaration identity despite equal instance labels" {
    const parser = @import("../parser.zig");
    const imports = @import("../imports.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var a_parser = try parser.Parser.init(alloc, "Box :: struct ($T: Type) { value: T; tag :: () -> i64 { 11 } }");
    var b_parser = try parser.Parser.init(alloc, "Box :: struct ($T: Type) { other: T; tag :: () -> i64 { 22 } }");
    const a = (try a_parser.parse()).data.root.decls[0];
    const b = (try b_parser.parse()).data.root.decls[0];
    var table = imports.DeclTable.init(alloc);
    const a_env = try table.internEnvironment("same.sx", &.{"a"});
    const b_env = try table.internEnvironment("same.sx", &.{"b"});
    try std.testing.expect(try table.claim(a_env, a));
    try std.testing.expect(try table.claim(b_env, b));
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    l.program_index.decl_table = &table;
    l.scanDecls(&.{ a, b });
    const ta = l.buildGenericStructTemplate(&a.data.struct_decl, "same.sx").?;
    const tb = l.buildGenericStructTemplate(&b.data.struct_decl, "same.sx").?;
    var bindings = std.StringHashMap(TypeId).init(alloc);
    try bindings.put("T", .i64);
    const values = std.StringHashMap(i64).init(alloc);
    const packs = std.StringHashMap([]const TypeId).init(alloc);
    const ia = l.instantiateGenericStructBound(&ta, try bindings.clone(), values, packs, "Box__i64", a.span);
    const ib = l.instantiateGenericStructBound(&tb, try bindings.clone(), values, packs, "Box__i64", b.span);
    try std.testing.expect(ia != ib);
    try std.testing.expectEqual(ia, l.instantiateGenericStructBound(&ta, try bindings.clone(), values, packs, "another label", a.span));
    try std.testing.expectEqualStrings("value", module.types.getString(module.types.get(ia).@"struct".fields[0].name));
    try std.testing.expectEqualStrings("other", module.types.getString(module.types.get(ib).@"struct".fields[0].name));
    const ma = l.genericInstanceMethod(l.formatTypeName(ia), "tag").?;
    const mb = l.genericInstanceMethod(l.formatTypeName(ib), "tag").?;
    try std.testing.expectEqual(&a.data.struct_decl.methods[0].data.fn_decl, ma.fd);
    try std.testing.expectEqual(&b.data.struct_decl.methods[0].data.fn_decl, mb.fd);
    const fa = l.ensureGenericInstanceMethodLowered(ma).?;
    const fb = l.ensureGenericInstanceMethodLowered(mb).?;
    try std.testing.expect(fa != fb);
    try std.testing.expectEqual(fa, l.ensureGenericInstanceMethodLowered(ma).?);
    var body_values: [2]?i64 = .{ null, null };
    for ([_]ir_mod.FuncId{ fa, fb }, &body_values) |fid, *value| {
        for (module.getFunction(fid).blocks.items) |block| {
            for (block.insts.items) |instruction| {
                if (instruction.op == .const_int) value.* = instruction.op.const_int;
            }
        }
    }
    try std.testing.expectEqual(@as(?i64, 11), body_values[0]);
    try std.testing.expectEqual(@as(?i64, 22), body_values[1]);
}

test "monomorph arguments retain type and pack boundaries independently of symbol spelling" {
    const parser = @import("../parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = try parser.Parser.init(alloc, "f :: ($T: Type) -> i64 { 1 } pack :: (..$args) -> i64 { 2 }");
    const decls = (try p.parse()).data.root.decls;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const one = module.types.internProduct(&.{.i64}, null);
    const two = module.types.internProduct(&.{ .i64, .i64 }, null);
    try std.testing.expectEqualStrings(l.mangleTypeName(one), l.mangleTypeName(two));
    var bindings = std.StringHashMap(TypeId).init(alloc);
    try bindings.put("T", one);
    const fd = &decls[0].data.fn_decl;
    const f1 = l.monomorphizeFunction(fd, "f__anon", &bindings).?;
    try bindings.put("T", two);
    const f2 = l.monomorphizeFunction(fd, "f__anon", &bindings).?;
    try std.testing.expect(f1 != f2);
    try bindings.put("T", one);
    try std.testing.expectEqual(f1, l.monomorphizeFunction(fd, "renamed", &bindings).?);
    const empty = std.StringHashMap(TypeId).init(alloc);
    const call = ast.Call{ .callee = typeKeyword(alloc, "pack"), .args = &.{} };
    const pack_fd = &decls[1].data.fn_decl;
    const p1 = l.monomorphizePackFn(pack_fd, "pack__anon", &.{one}, &call, &empty).?;
    const p2 = l.monomorphizePackFn(pack_fd, "pack__anon", &.{two}, &call, &empty).?;
    try std.testing.expect(p1 != p2);
    try std.testing.expectEqual(p1, l.monomorphizePackFn(pack_fd, "renamed", &.{one}, &call, &empty).?);
}

test "type function result reuse includes empty layouts and alias-first calls" {
    const parser = @import("../parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = try parser.Parser.init(alloc, "Make :: ($T: Type) -> Type { return struct {}; }");
    const fd = &(try p.parse()).data.root.decls[0].data.fn_decl;
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const args = [_]*const Node{typeKeyword(alloc, "i64")};
    const first = l.instantiateTypeFunction("Alias", "Make", fd, &args).?;
    const count = module.types.infos.items.len;
    try std.testing.expectEqual(first, l.instantiateTypeFunction("Make", "Make", fd, &args).?);
    try std.testing.expectEqual(count, module.types.infos.items.len);
    var other = fd.*;
    const second = l.instantiateTypeFunction("Alias", "Make", &other, &args).?;
    try std.testing.expect(first != second);
}
