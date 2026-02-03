// Tests for jni_descriptor.zig — Phase 2 step 2.8.
// Table-driven golden test for the primitive / array / *Self JNI
// signature alphabet. Cross-class references land in 2.9.

const std = @import("std");
const ast = @import("../ast.zig");
const desc = @import("jni_descriptor.zig");

const Node = ast.Node;

fn makeTypeExpr(allocator: std.mem.Allocator, name: []const u8) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .type_expr = .{ .name = name } },
    };
    return node;
}

fn makePointer(allocator: std.mem.Allocator, pointee: *Node) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .pointer_type_expr = .{ .pointee_type = pointee } },
    };
    return node;
}

fn makeSlice(allocator: std.mem.Allocator, element: *Node) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .slice_type_expr = .{ .element_type = element } },
    };
    return node;
}

fn expectType(name: []const u8, expected: []const u8) !void {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const tn = try makeTypeExpr(aa, name);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try desc.writeType(a, &buf, .{ .enclosing_path = "" }, tn);
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "primitive descriptors" {
    try expectType("void", "V");
    try expectType("bool", "Z");
    try expectType("i8", "B");
    try expectType("u8", "B");
    try expectType("i16", "S");
    try expectType("u16", "C");
    try expectType("i32", "I");
    try expectType("i64", "J");
    try expectType("f32", "F");
    try expectType("f64", "D");
}

test "void return is V (null type_node)" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try desc.writeType(a, &buf, .{ .enclosing_path = "" }, null);
    try std.testing.expectEqualStrings("V", buf.items);
}

test "*void resolves to java/lang/Object (opaque jobject)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const void_te = try makeTypeExpr(aa, "void");
    const ptr = try makePointer(aa, void_te);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try desc.writeType(a, &buf, .{ .enclosing_path = "anything" }, ptr);
    try std.testing.expectEqualStrings("Ljava/lang/Object;", buf.items);
}

test "*Self resolves to enclosing class L-form" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_te = try makeTypeExpr(aa, "Self");
    const ptr = try makePointer(aa, self_te);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try desc.writeType(a, &buf, .{ .enclosing_path = "android/view/View" }, ptr);
    try std.testing.expectEqualStrings("Landroid/view/View;", buf.items);
}

test "slice of primitive is array descriptor" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const i32_te = try makeTypeExpr(aa, "i32");
    const slice = try makeSlice(aa, i32_te);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try desc.writeType(a, &buf, .{ .enclosing_path = "" }, slice);
    try std.testing.expectEqualStrings("[I", buf.items);
}

test "cross-class *Foo resolves via class registry" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var registry = desc.ClassRegistry.init(a);
    defer registry.deinit();
    try registry.put("Window", "android/view/Window");
    try registry.put("View", "android/view/View");

    const foo = try makeTypeExpr(aa, "Window");
    const ptr = try makePointer(aa, foo);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try desc.writeType(a, &buf, .{
        .enclosing_path = "android/view/View",
        .classes = &registry,
    }, ptr);
    try std.testing.expectEqualStrings("Landroid/view/Window;", buf.items);
}

test "cross-class *Foo without registry errors" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const foo = try makeTypeExpr(aa, "Window");
    const ptr = try makePointer(aa, foo);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const result = desc.writeType(a, &buf, .{
        .enclosing_path = "android/view/View",
    }, ptr);
    try std.testing.expectError(desc.DeriveError.UnknownClassAlias, result);
}

test "cross-class *Foo with empty registry errors" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var registry = desc.ClassRegistry.init(a);
    defer registry.deinit();

    const foo = try makeTypeExpr(aa, "WindowInsets");
    const ptr = try makePointer(aa, foo);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const result = desc.writeType(a, &buf, .{
        .enclosing_path = "android/view/Window",
        .classes = &registry,
    }, ptr);
    try std.testing.expectError(desc.DeriveError.UnknownClassAlias, result);
}

test "deriveMethod respects #jni_method_descriptor override verbatim" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // The actual sx signature `(self: *Self) -> i32` would derive to
    // `()I`. The override should win regardless.
    const self_te = try makeTypeExpr(aa, "Self");
    const self_ptr = try makePointer(aa, self_te);
    const ret = try makeTypeExpr(aa, "i32");

    const method: ast.RuntimeMethodDecl = .{
        .name = "weirdMethod",
        .params = &.{self_ptr},
        .param_names = &.{"self"},
        .return_type = ret,
        .is_static = false,
        .jni_descriptor_override = "(Ljava/lang/Object;)Ljava/util/List;",
    };
    const out = try desc.deriveMethod(a, .{ .enclosing_path = "com/example/Foo" }, method);
    defer a.free(out);
    try std.testing.expectEqualStrings("(Ljava/lang/Object;)Ljava/util/List;", out);
}

test "deriveMethod override bypasses unresolvable cross-class refs" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // The signature references `*UnknownClass` that isn't in the
    // registry — would normally fail with `UnknownClassAlias`. The
    // override short-circuits derivation, so it succeeds.
    const self_te = try makeTypeExpr(aa, "Self");
    const self_ptr = try makePointer(aa, self_te);
    const unknown = try makeTypeExpr(aa, "UnknownClass");
    const unknown_ptr = try makePointer(aa, unknown);

    const method: ast.RuntimeMethodDecl = .{
        .name = "weirdMethod",
        .params = &.{self_ptr},
        .param_names = &.{"self"},
        .return_type = unknown_ptr,
        .is_static = false,
        .jni_descriptor_override = "()V",
    };
    const out = try desc.deriveMethod(a, .{ .enclosing_path = "com/example/Foo" }, method);
    defer a.free(out);
    try std.testing.expectEqualStrings("()V", out);
}

test "deriveMethod chains *Foo returns and params" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var registry = desc.ClassRegistry.init(a);
    defer registry.deinit();
    try registry.put("Window", "android/view/Window");
    try registry.put("View", "android/view/View");
    try registry.put("WindowInsets", "android/view/WindowInsets");

    // getDecorView :: (self: *Self) -> *View  →  ()Landroid/view/View;
    const self_te = try makeTypeExpr(aa, "Self");
    const self_ptr = try makePointer(aa, self_te);
    const view_te = try makeTypeExpr(aa, "View");
    const view_ptr = try makePointer(aa, view_te);

    const method: ast.RuntimeMethodDecl = .{
        .name = "getDecorView",
        .params = &.{self_ptr},
        .param_names = &.{"self"},
        .return_type = view_ptr,
        .is_static = false,
    };
    const out = try desc.deriveMethod(a, .{
        .enclosing_path = "android/view/Window",
        .classes = &registry,
    }, method);
    defer a.free(out);
    try std.testing.expectEqualStrings("()Landroid/view/View;", out);
}

test "deriveMethod skips implicit self for instance methods" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // method: getId :: (self: *Self) -> i32  →  ()I
    const self_te = try makeTypeExpr(aa, "Self");
    const self_ptr = try makePointer(aa, self_te);
    const ret = try makeTypeExpr(aa, "i32");

    const method: ast.RuntimeMethodDecl = .{
        .name = "getId",
        .params = &.{self_ptr},
        .param_names = &.{"self"},
        .return_type = ret,
        .is_static = false,
    };
    const out = try desc.deriveMethod(a, .{ .enclosing_path = "android/view/View" }, method);
    defer a.free(out);
    try std.testing.expectEqualStrings("()I", out);
}

test "deriveMethod for static method emits all params" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // static abs :: (n: i32) -> i32  →  (I)I
    const n_ty = try makeTypeExpr(aa, "i32");
    const ret = try makeTypeExpr(aa, "i32");

    const method: ast.RuntimeMethodDecl = .{
        .name = "abs",
        .params = &.{n_ty},
        .param_names = &.{"n"},
        .return_type = ret,
        .is_static = true,
    };
    const out = try desc.deriveMethod(a, .{ .enclosing_path = "java/lang/Math" }, method);
    defer a.free(out);
    try std.testing.expectEqualStrings("(I)I", out);
}

test "deriveMethod with multiple primitive params and void return" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // setBounds :: (self: *Self, x: i32, y: i32, w: i32, h: i32) -> void  →  (IIII)V
    const self_te = try makeTypeExpr(aa, "Self");
    const self_ptr = try makePointer(aa, self_te);
    const s = try makeTypeExpr(aa, "i32");

    const method: ast.RuntimeMethodDecl = .{
        .name = "setBounds",
        .params = &.{ self_ptr, s, s, s, s },
        .param_names = &.{ "self", "x", "y", "w", "h" },
        .return_type = null,
        .is_static = false,
    };
    const out = try desc.deriveMethod(a, .{ .enclosing_path = "android/graphics/Rect" }, method);
    defer a.free(out);
    try std.testing.expectEqualStrings("(IIII)V", out);
}

test "deriveMethod with slice param" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // copy :: (self: *Self, src: []i8) -> i32  →  ([B)I
    const self_te = try makeTypeExpr(aa, "Self");
    const self_ptr = try makePointer(aa, self_te);
    const i8_te = try makeTypeExpr(aa, "i8");
    const src_slice = try makeSlice(aa, i8_te);
    const ret = try makeTypeExpr(aa, "i32");

    const method: ast.RuntimeMethodDecl = .{
        .name = "copy",
        .params = &.{ self_ptr, src_slice },
        .param_names = &.{ "self", "src" },
        .return_type = ret,
        .is_static = false,
    };
    const out = try desc.deriveMethod(a, .{ .enclosing_path = "java/nio/ByteBuffer" }, method);
    defer a.free(out);
    try std.testing.expectEqualStrings("([B)I", out);
}

// ── A6.2: native-name mangling + return-type dispatchability ─────────

const types = @import("types.zig");

test "jniMangleNativeName mangles package path + method (/ -> _, _ -> _1)" {
    const alloc = std.testing.allocator;

    // Plain path + method: `/` separators collapse to `_`, `Java_` prefix,
    // `_sx_1` infix before the (mangled) method name.
    const m1 = try desc.jniMangleNativeName(alloc, "com/sx/App", "tick");
    defer alloc.free(m1);
    try std.testing.expectEqualStrings("Java_com_sx_App_sx_1tick", m1);

    // Underscores in BOTH the path and the method escape to `_1` (so the JNI
    // resolver can round-trip them), distinct from the `/`->`_` separator.
    const m2 = try desc.jniMangleNativeName(alloc, "a_b/C", "do_it");
    defer alloc.free(m2);
    try std.testing.expectEqualStrings("Java_a_1b_C_sx_1do_1it", m2);
}

test "isJniReturnTypeSupported accepts the dispatchable set + pointers only" {
    const alloc = std.testing.allocator;
    var table = types.TypeTable.init(alloc);
    defer table.deinit();
    const t = &table;

    // The Call<T>Method-dispatchable primitives.
    inline for (.{ types.TypeId.void, types.TypeId.bool, types.TypeId.i32, types.TypeId.i64, types.TypeId.f32, types.TypeId.f64 }) |ty| {
        try std.testing.expect(desc.isJniReturnTypeSupported(t, ty));
    }

    // Other primitive widths are NOT dispatchable (would hit emit_llvm's
    // undef-producing `else` arm — the footgun this predicate guards).
    inline for (.{ types.TypeId.i8, types.TypeId.i16, types.TypeId.u8, types.TypeId.u32, types.TypeId.u64 }) |ty| {
        try std.testing.expect(!desc.isJniReturnTypeSupported(t, ty));
    }

    // Pointer / many-pointer returns route through CallObjectMethod → true.
    try std.testing.expect(desc.isJniReturnTypeSupported(t, table.ptrTo(.void)));
    try std.testing.expect(desc.isJniReturnTypeSupported(t, table.manyPtrTo(.u8)));

    // A pass-by-value struct return is unsupported.
    const sname = table.internString("CGRectish");
    const sty = table.intern(.{ .@"struct" = .{ .name = sname, .fields = &.{} } });
    try std.testing.expect(!desc.isJniReturnTypeSupported(t, sty));
}
