// Tests for jni_java_emit.zig — #jni_main pipeline slice 1.
// Locks in the Java source emitted from `RuntimeClassDecl` AST nodes:
// package split, class header, @Override delegate pattern, primitive
// type mapping, cross-class refs through the runtime_class registry.

const std = @import("std");
const ast = @import("../ast.zig");
const emit = @import("jni_java_emit.zig");

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

/// Marker for "method has a body" — emitJavaSource only checks
/// `body != null`. The actual node contents are unused.
fn makeBodyMarker(allocator: std.mem.Allocator) !*Node {
    const node = try allocator.create(Node);
    node.* = .{
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .block = .{ .stmts = &.{} } },
    };
    return node;
}

test "rejects non-main decl" {
    const a = std.testing.allocator;
    const fcd: ast.RuntimeClassDecl = .{
        .name = "Foo",
        .runtime_path = "co/example/Foo",
        .runtime = .jni_class,
        .is_main = false, // ← not main
    };
    const result = emit.emitJavaSource(a, &fcd, .{});
    try std.testing.expectError(emit.EmitError.NotAJniMainClass, result);
}

test "void onCreate(Bundle) with default Activity superclass" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const bundle_ty = try makePointer(aa, try makeTypeExpr(aa, "Bundle"));
    const body = try makeBodyMarker(aa);

    var registry = std.StringHashMap([]const u8).init(a);
    defer registry.deinit();
    try registry.put("Bundle", "android/os/Bundle");

    const member: ast.RuntimeClassMember = .{ .method = .{
        .name = "onCreate",
        .params = &.{ self_ty, bundle_ty },
        .param_names = &.{ "self", "b" },
        .return_type = null,
        .body = body,
    } };
    const fcd: ast.RuntimeClassDecl = .{
        .name = "SxApp",
        .runtime_path = "co/swipelab/sx_runtime/SxNativeActivity",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{member},
    };

    const out = try emit.emitJavaSource(a, &fcd, .{ .classes = &registry });
    defer a.free(out);

    const expected =
        \\package co.swipelab.sx_runtime;
        \\
        \\public class SxNativeActivity extends android.app.Activity {
        \\    @Override
        \\    public void onCreate(android.os.Bundle b) {
        \\        sx_onCreate(b);
        \\    }
        \\    private native void sx_onCreate(android.os.Bundle b);
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "primitive params" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const bool_ty = try makeTypeExpr(aa, "bool");
    const body = try makeBodyMarker(aa);

    const member: ast.RuntimeClassMember = .{ .method = .{
        .name = "onWindowFocusChanged",
        .params = &.{ self_ty, bool_ty },
        .param_names = &.{ "self", "hasFocus" },
        .return_type = null,
        .body = body,
    } };
    const fcd: ast.RuntimeClassDecl = .{
        .name = "Sx",
        .runtime_path = "co/sample/Sx",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{member},
    };
    const out = try emit.emitJavaSource(a, &fcd, .{});
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "public void onWindowFocusChanged(boolean hasFocus)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "super.onWindowFocusChanged") == null); // emitter never injects super
    try std.testing.expect(std.mem.indexOf(u8, out, "sx_onWindowFocusChanged(hasFocus);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "private native void sx_onWindowFocusChanged(boolean hasFocus);") != null);
}

test "declaration-only methods are skipped" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const body = try makeBodyMarker(aa);

    // One bodied (override), one declaration-only (calls inherited).
    const bodied: ast.RuntimeClassMember = .{ .method = .{
        .name = "onCreate",
        .params = &.{self_ty},
        .param_names = &.{"self"},
        .return_type = null,
        .body = body,
    } };
    const decl_only: ast.RuntimeClassMember = .{ .method = .{
        .name = "finish",
        .params = &.{self_ty},
        .param_names = &.{"self"},
        .return_type = null,
        .body = null, // sx-side just *calls* this; Java's NativeActivity.finish() provides it
    } };

    const fcd: ast.RuntimeClassDecl = .{
        .name = "Sx",
        .runtime_path = "co/example/Sx",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{ bodied, decl_only },
    };
    const out = try emit.emitJavaSource(a, &fcd, .{});
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "sx_onCreate") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sx_finish") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "void finish(") == null);
}

test "#extends Alias resolves through class registry" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const body = try makeBodyMarker(aa);

    const extends_member: ast.RuntimeClassMember = .{ .extends = "MyParent" };
    const method_member: ast.RuntimeClassMember = .{ .method = .{
        .name = "onCreate",
        .params = &.{self_ty},
        .param_names = &.{"self"},
        .return_type = null,
        .body = body,
    } };

    var registry = std.StringHashMap([]const u8).init(a);
    defer registry.deinit();
    try registry.put("MyParent", "co/example/MyParentActivity");

    const fcd: ast.RuntimeClassDecl = .{
        .name = "Sx",
        .runtime_path = "co/example/Sx",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{ extends_member, method_member },
    };
    const out = try emit.emitJavaSource(a, &fcd, .{ .classes = &registry });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "extends co.example.MyParentActivity") != null);
}

test "default-package class (no slash in runtime_path)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const body = try makeBodyMarker(aa);

    const member: ast.RuntimeClassMember = .{ .method = .{
        .name = "onCreate",
        .params = &.{self_ty},
        .param_names = &.{"self"},
        .return_type = null,
        .body = body,
    } };
    const fcd: ast.RuntimeClassDecl = .{
        .name = "Sx",
        .runtime_path = "SxNoPackage",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{member},
    };
    const out = try emit.emitJavaSource(a, &fcd, .{});
    defer a.free(out);

    // No `package ...;` line when the runtime path has no slashes.
    try std.testing.expect(std.mem.indexOf(u8, out, "package ") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "public class SxNoPackage") != null);
}

test "lib_name renders System.loadLibrary static init block" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const body = try makeBodyMarker(aa);
    const method: ast.RuntimeClassMember = .{ .method = .{
        .name = "onCreate",
        .params = &.{self_ty},
        .param_names = &.{"self"},
        .return_type = null,
        .body = body,
    } };

    const fcd: ast.RuntimeClassDecl = .{
        .name = "SxApp",
        .runtime_path = "co/example/SxApp",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{method},
    };

    const out = try emit.emitJavaSource(a, &fcd, .{ .lib_name = "sxchess" });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "static { System.loadLibrary(\"sxchess\"); }") != null);

    // Without lib_name the static init is omitted.
    const out2 = try emit.emitJavaSource(a, &fcd, .{});
    defer a.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "System.loadLibrary") == null);
}

test "field declarations render as private Java fields" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const surface_view_ty = try makePointer(aa, try makeTypeExpr(aa, "SurfaceView"));
    const int_ty = try makeTypeExpr(aa, "i32");
    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const body = try makeBodyMarker(aa);

    const view_field: ast.RuntimeClassMember = .{ .field = .{ .name = "view", .field_type = surface_view_ty } };
    const w_field: ast.RuntimeClassMember = .{ .field = .{ .name = "viewport_w", .field_type = int_ty } };
    const method: ast.RuntimeClassMember = .{ .method = .{
        .name = "onCreate",
        .params = &.{self_ty},
        .param_names = &.{"self"},
        .return_type = null,
        .body = body,
    } };

    var registry = std.StringHashMap([]const u8).init(a);
    defer registry.deinit();
    try registry.put("SurfaceView", "android/view/SurfaceView");

    const fcd: ast.RuntimeClassDecl = .{
        .name = "SxApp",
        .runtime_path = "co/example/SxApp",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{ view_field, w_field, method },
    };
    const out = try emit.emitJavaSource(a, &fcd, .{ .classes = &registry });
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "private android.view.SurfaceView view;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "private int viewport_w;") != null);
}

test "#implements clauses on the class header" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const self_ty = try makePointer(aa, try makeTypeExpr(aa, "Self"));
    const body = try makeBodyMarker(aa);

    // Two interfaces: one resolvable via the registry, one passed through verbatim.
    const impl_a: ast.RuntimeClassMember = .{ .implements = "Callback" };
    const impl_b: ast.RuntimeClassMember = .{ .implements = "java.lang.Runnable" };
    const method: ast.RuntimeClassMember = .{ .method = .{
        .name = "onCreate",
        .params = &.{self_ty},
        .param_names = &.{"self"},
        .return_type = null,
        .body = body,
    } };

    var registry = std.StringHashMap([]const u8).init(a);
    defer registry.deinit();
    try registry.put("Callback", "android/view/SurfaceHolder$Callback");

    const fcd: ast.RuntimeClassDecl = .{
        .name = "SxApp",
        .runtime_path = "co/example/SxApp",
        .runtime = .jni_class,
        .is_main = true,
        .members = &.{ impl_a, impl_b, method },
    };
    const out = try emit.emitJavaSource(a, &fcd, .{ .classes = &registry });
    defer a.free(out);

    // Registry value `android/view/SurfaceHolder$Callback` is emitted in Java
    // *source* form: `/` → `.` and the nested-class `$` → `.`.
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "public class SxApp extends android.app.Activity implements android.view.SurfaceHolder.Callback, java.lang.Runnable {",
    ) != null);
}
