// JNI descriptor derivation for #jni_class methods (Phase 2 step 2.8).
//
// Walks sx parameter / return type AST nodes through the standard JNI
// signature alphabet (JLS §4.3.3 and JNI spec §3.3) to produce the
// descriptor string consumed by `GetMethodID` / `GetStaticMethodID`.
//
//   void          → V
//   bool          → Z   (jboolean)
//   i8            → B   (jbyte)
//   i16           → S   (jshort)
//   i32           → I   (jint)
//   i64           → J   (jlong)
//   u8            → B   (jbyte — JNI bytes are signed; sx u8 still bridges via B)
//   u16           → C   (jchar — unsigned 16-bit)
//   f32           → F   (jfloat)
//   f64           → D   (jdouble)
//   []T           → [<elem>
//   [*]T          → [<elem>   (sx many-pointer treated as array for now)
//   *Self         → L<enclosing-runtime-path>;
//   *Foo          → L<Foo's runtime path>;   (cross-class — step 2.9)
//
// `#jni_method_descriptor("...")` (step 2.6) overrides this whole walk
// when set; sema/lowering use the override verbatim.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");

const Node = ast.Node;
const TypeId = types.TypeId;

pub const DeriveError = error{
    UnknownPrimitive,
    UnknownClassAlias, // *Foo where Foo isn't a declared #jni_class
    UnsupportedType,
    OutOfMemory,
};

/// Map from sx-side alias → runtime path of declared `#jni_class` /
/// `#jni_interface` decls. Used to resolve `*Foo` into `L<path>;` in
/// the descriptor. Built during lowering's scan pass.
pub const ClassRegistry = std.StringHashMap([]const u8);

pub const Context = struct {
    /// Runtime path of the enclosing #jni_class — used to resolve `*Self`.
    /// e.g. "android/view/View".
    enclosing_path: []const u8,
    /// Lookup for sibling/forward-declared `#jni_class` aliases. When null,
    /// only `*Self` resolves; any other pointer-to-named-type errors.
    classes: ?*const ClassRegistry = null,
};

/// Appends a single JNI type-descriptor to `buf` for `type_node`.
/// A null type_node represents a void return ('V').
pub fn writeType(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    ctx: Context,
    type_node: ?*const Node,
) DeriveError!void {
    if (type_node == null) {
        try buf.append(allocator, 'V');
        return;
    }
    const tn = type_node.?;
    switch (tn.data) {
        .type_expr => |te| {
            const ch = primitiveChar(te.name) orelse return DeriveError.UnknownPrimitive;
            try buf.append(allocator, ch);
        },
        .slice_type_expr => |sl| {
            try buf.append(allocator, '[');
            try writeType(allocator, buf, ctx, sl.element_type);
        },
        .many_pointer_type_expr => |mp| {
            try buf.append(allocator, '[');
            try writeType(allocator, buf, ctx, mp.element_type);
        },
        .array_type_expr => |arr| {
            try buf.append(allocator, '[');
            try writeType(allocator, buf, ctx, arr.element_type);
        },
        .pointer_type_expr => |ptr| {
            // *Self → L<enclosing>;,  *Foo → L<Foo's runtime path>;,
            // *void → Ljava/lang/Object; (opaque jobject — common when
            // users don't have a precise Java type for the value).
            const inner = ptr.pointee_type;
            if (inner.data != .type_expr) return DeriveError.UnsupportedType;
            const target_name = inner.data.type_expr.name;
            const target_path: []const u8 = if (std.mem.eql(u8, target_name, "Self"))
                ctx.enclosing_path
            else if (std.mem.eql(u8, target_name, "void"))
                "java/lang/Object"
            else if (ctx.classes) |reg|
                reg.get(target_name) orelse return DeriveError.UnknownClassAlias
            else
                return DeriveError.UnknownClassAlias;
            try buf.append(allocator, 'L');
            try buf.appendSlice(allocator, target_path);
            try buf.append(allocator, ';');
        },
        else => return DeriveError.UnsupportedType,
    }
}

/// Derives the full `(args)ret` method descriptor for a `RuntimeMethodDecl`.
/// The first param is skipped when `is_static == false` (it's the implicit
/// `self: *Self` receiver, which doesn't appear in the JNI descriptor).
pub fn deriveMethod(
    allocator: std.mem.Allocator,
    ctx: Context,
    method: ast.RuntimeMethodDecl,
) DeriveError![]u8 {
    // `#jni_method_descriptor("(Sig)Ret")` short-circuits derivation
    // entirely. Allocate a copy so the caller has uniform ownership
    // semantics regardless of which branch ran.
    if (method.jni_descriptor_override) |override| {
        return allocator.dupe(u8, override);
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '(');
    const start: usize = if (method.is_static) 0 else 1;
    if (method.params.len < start) return DeriveError.UnsupportedType;
    for (method.params[start..]) |param| {
        try writeType(allocator, &buf, ctx, param);
    }
    try buf.append(allocator, ')');
    try writeType(allocator, &buf, ctx, method.return_type);

    return buf.toOwnedSlice(allocator);
}

fn primitiveChar(name: []const u8) ?u8 {
    const table = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "void", .ch = 'V' },
        .{ .name = "bool", .ch = 'Z' },
        .{ .name = "i8", .ch = 'B' },
        .{ .name = "u8", .ch = 'B' },
        .{ .name = "i16", .ch = 'S' },
        .{ .name = "u16", .ch = 'C' },
        .{ .name = "i32", .ch = 'I' },
        .{ .name = "i64", .ch = 'J' },
        .{ .name = "f32", .ch = 'F' },
        .{ .name = "f64", .ch = 'D' },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.ch;
    }
    return null;
}

/// Whether emit_llvm's `jni_msg_send` lowering can dispatch a Call<T>Method
/// for this return type. Anything outside this set falls into the `else`
/// arm of the switches in `emit_llvm.zig` and would silently produce
/// `LLVMGetUndef` — a footgun that previously shipped (chess Android touch
/// went undef because `MotionEvent.getX() -> f32` wasn't in the switch).
/// Pointer-typed returns route through `CallObjectMethod`.
pub fn isJniReturnTypeSupported(table: *const types.TypeTable, ret_ty: TypeId) bool {
    return switch (ret_ty) {
        .void, .bool, .i32, .i64, .f32, .f64 => true,
        else => blk: {
            if (ret_ty.isBuiltin()) break :blk false;
            const info = table.get(ret_ty);
            break :blk info == .pointer or info == .many_pointer;
        },
    };
}

/// Encode a (runtime_path, method_name) pair as the JNI-resolved symbol
/// `Java_<pkg-mangled>_<Class>_sx_1<method-mangled>`. JNI mangling:
/// `/` → `_`, `_` → `_1`. The `sx_` prefix matches the Java-side
/// `private native sx_<name>(...)` delegate.
pub fn jniMangleNativeName(allocator: std.mem.Allocator, runtime_path: []const u8, method_name: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, "Java_");
    for (runtime_path) |ch| {
        if (ch == '/') {
            try buf.append(allocator, '_');
        } else if (ch == '_') {
            try buf.appendSlice(allocator, "_1");
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, '_');
    try buf.appendSlice(allocator, "sx_1");
    for (method_name) |ch| {
        if (ch == '_') {
            try buf.appendSlice(allocator, "_1");
        } else {
            try buf.append(allocator, ch);
        }
    }
    return buf.toOwnedSlice(allocator);
}
