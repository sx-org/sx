// Java source emission for `#jni_main #jni_class("...") { ... }` decls
// (FFI plan, #jni_main pipeline slice 1).
//
// Given a `RuntimeClassDecl` whose `is_main` flag is set, emit a `.java`
// source file that:
//
//   - declares a `public class` at the runtime_path's package + simple
//     name (e.g. `co/swipelab/Test/SxTestActivity` →
//     `package co.swipelab.Test; public class SxTestActivity`);
//   - extends the parent specified by `#extends Alias` (or
//     `android.app.NativeActivity` by default for a #jni_main class);
//   - for each method with a body, emits an `@Override` Java method
//     that calls `super` then a private native delegate `sx_<method>`;
//   - emits the matching `private native ... sx_<method>(...)` decls.
//
// The downstream pipeline (slice 2+) feeds this through `javac` + `d8`
// and bundles the resulting `.dex` into the APK. Slice 3 wires the
// manifest's `<activity android:name="...">` to point at this class.
// Slice 4 emits a synthetic `JNI_OnLoad` that calls `RegisterNatives`
// to bind the `sx_<method>` symbols.
//
// Type matrix covered today:
//   - void return + primitive returns (i8/i16/i32/i64, u8/u16, bool,
//     f32/f64)
//   - `(self: *Self)` plus primitive params
//   - cross-class refs (`*Foo` where Foo is another declared
//     `#jni_class(…) extern`) lower to Foo's runtime path → Java
//     fully-qualified type
//   - `*void` → `Object` (opaque jobject)

const std = @import("std");
const ast = @import("../ast.zig");
const Allocator = std.mem.Allocator;

pub const EmitError = error{
    OutOfMemory,
    UnsupportedType,
    NotAJniMainClass,
};

pub const Options = struct {
    /// Map from sx alias → runtime path of declared `#jni_class` decls.
    /// Used to resolve `*Foo` cross-class refs in method signatures.
    classes: ?*const std.StringHashMap([]const u8) = null,
    /// Default superclass when the user doesn't write `#extends ...;`.
    /// `android.app.Activity` is the standard base for Java-driven
    /// Activities — `NativeActivity` is the legacy NDK path that
    /// requires native_app_glue's `ANativeActivity_onCreate`.
    default_extends: []const u8 = "android.app.Activity",
    /// `System.loadLibrary(...)` argument for the emitted static init
    /// block. When set, the emitter inserts `static { System.loadLibrary
    /// (lib_name); }` so JNI native delegates can resolve at runtime.
    /// When null, no static init is emitted (caller must arrange .so
    /// loading some other way — e.g. another class's static init).
    lib_name: ?[]const u8 = null,
};

/// Inject a `static { System.loadLibrary("<lib>"); }` block into an already-
/// rendered Java source. Used when the output path isn't known until after
/// `#run` blocks execute — `collectJniMainEmissions` runs during lowering,
/// before `BuildOptions.set_output_path(...)` has populated the lib name.
/// Returns a newly-allocated string; caller owns it.
pub fn injectLoadLibrary(allocator: Allocator, java_source: []const u8, lib_name: []const u8) ![]u8 {
    const marker = " {\n";
    const class_pos = std.mem.indexOf(u8, java_source, "public class ") orelse return try allocator.dupe(u8, java_source);
    const brace_rel = std.mem.indexOf(u8, java_source[class_pos..], marker) orelse return try allocator.dupe(u8, java_source);
    const insert_at = class_pos + brace_rel + marker.len;
    // Already injected? Skip.
    if (std.mem.indexOf(u8, java_source, "System.loadLibrary(") != null) {
        return try allocator.dupe(u8, java_source);
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, java_source[0..insert_at]);
    try buf.appendSlice(allocator, "    static { System.loadLibrary(\"");
    try buf.appendSlice(allocator, lib_name);
    try buf.appendSlice(allocator, "\"); }\n");
    try buf.appendSlice(allocator, java_source[insert_at..]);
    return try buf.toOwnedSlice(allocator);
}

/// Emit a `.java` source for the given runtime-class decl. Result is
/// heap-allocated through `allocator`; caller owns it.
pub fn emitJavaSource(
    allocator: Allocator,
    fcd: *const ast.RuntimeClassDecl,
    opts: Options,
) EmitError![]u8 {
    if (!fcd.is_main) return EmitError.NotAJniMainClass;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const parts = splitRuntimePath(fcd.runtime_path);
    if (parts.pkg.len > 0) {
        try buf.appendSlice(allocator, "package ");
        try appendDotted(allocator, &buf, parts.pkg);
        try buf.appendSlice(allocator, ";\n\n");
    }

    var parent: []const u8 = opts.default_extends;
    var parent_owned = false;
    for (fcd.members) |m| switch (m) {
        .extends => |alias| {
            if (opts.classes) |reg| {
                if (reg.get(alias)) |path| {
                    parent = try runtimePathToJavaName(allocator, path);
                    parent_owned = true;
                    break;
                }
            }
            parent = alias;
            break;
        },
        else => {},
    };
    defer if (parent_owned) allocator.free(parent);

    try buf.appendSlice(allocator, "public class ");
    try buf.appendSlice(allocator, parts.cls);
    try buf.appendSlice(allocator, " extends ");
    try buf.appendSlice(allocator, parent);

    // `#implements Alias;` body items become Java `implements` clauses on the
    // class header. Aliases resolve through the class registry the same way
    // `#extends` does — an unmapped alias passes through verbatim (useful for
    // referring to built-in JVM interfaces without declaring them).
    var first_iface = true;
    for (fcd.members) |m| switch (m) {
        .implements => |alias| {
            try buf.appendSlice(allocator, if (first_iface) " implements " else ", ");
            first_iface = false;
            if (opts.classes) |reg| {
                if (reg.get(alias)) |path| {
                    try appendDotted(allocator, &buf, path);
                    continue;
                }
            }
            try buf.appendSlice(allocator, alias);
        },
        else => {},
    };

    try buf.appendSlice(allocator, " {\n");

    if (opts.lib_name) |ln| {
        try buf.appendSlice(allocator, "    static { System.loadLibrary(\"");
        try buf.appendSlice(allocator, ln);
        try buf.appendSlice(allocator, "\"); }\n");
    }

    // Fields. `name: Type;` body items render as private Java fields —
    // primitive types pass through, pointer types resolve to fully
    // qualified Java class names via the class registry.
    for (fcd.members) |m| switch (m) {
        .field => |fd| {
            try buf.appendSlice(allocator, "    private ");
            try emitJavaType(allocator, &buf, fd.field_type, opts);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, fd.name);
            try buf.appendSlice(allocator, ";\n");
        },
        else => {},
    };

    // Two passes: @Override stubs + native delegate; then the native
    // declarations.
    for (fcd.members) |m| switch (m) {
        .method => |md| {
            if (md.body == null) continue;
            if (md.is_static) continue; // TODO: static native handling
            try emitOverride(allocator, &buf, md, opts);
        },
        else => {},
    };

    for (fcd.members) |m| switch (m) {
        .method => |md| {
            if (md.body == null) continue;
            if (md.is_static) continue;
            try emitNativeDecl(allocator, &buf, md, opts);
        },
        else => {},
    };

    try buf.appendSlice(allocator, "}\n");
    return buf.toOwnedSlice(allocator);
}

const PathParts = struct { pkg: []const u8, cls: []const u8 };

fn splitRuntimePath(runtime_path: []const u8) PathParts {
    const last_slash = std.mem.lastIndexOfScalar(u8, runtime_path, '/') orelse {
        return .{ .pkg = "", .cls = runtime_path };
    };
    return .{
        .pkg = runtime_path[0..last_slash],
        .cls = runtime_path[last_slash + 1 ..],
    };
}

fn appendDotted(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    slash_path: []const u8,
) EmitError!void {
    // `/` and `$` both become `.` in Java source: `android/view/SurfaceHolder$Callback`
    // → `android.view.SurfaceHolder.Callback`. The `$` form is the JNI-descriptor
    // / class-file shape for nested classes; Java source uses `.` for both.
    for (slash_path) |c| {
        try buf.append(allocator, if (c == '/' or c == '$') '.' else c);
    }
}

fn runtimePathToJavaName(allocator: Allocator, slash_path: []const u8) EmitError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendDotted(allocator, &buf, slash_path);
    return buf.toOwnedSlice(allocator);
}

fn emitOverride(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    md: ast.RuntimeMethodDecl,
    opts: Options,
) EmitError!void {
    // The Java @Override only calls the native delegate. `super.<method>(...)`
    // is NOT injected — if the user wants to invoke the supertype's
    // implementation (e.g. `super.onCreate(b)` for an Activity lifecycle hook
    // that requires it) they call super from the sx-side body via JNI
    // dispatch. This keeps the emitter free of "is this an interface method
    // or a supertype override?" guesswork and matches the sx principle of
    // user-space code expressing the dispatch.
    try buf.appendSlice(allocator, "    @Override\n    public ");
    try emitJavaReturnType(allocator, buf, md.return_type, opts);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, md.name);
    try buf.append(allocator, '(');
    try emitJavaParamList(allocator, buf, md, opts);
    // Non-void return types `return` the native delegate's result; void
    // returns just call it. The user's sx-side body decides what to
    // return — the Java side is a pass-through.
    const has_ret = md.return_type != null;
    try buf.appendSlice(allocator, ") {\n        ");
    if (has_ret) try buf.appendSlice(allocator, "return ");
    try buf.appendSlice(allocator, "sx_");
    try buf.appendSlice(allocator, md.name);
    try buf.append(allocator, '(');
    try emitJavaArgList(allocator, buf, md);
    try buf.appendSlice(allocator, ");\n    }\n");
}

fn emitNativeDecl(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    md: ast.RuntimeMethodDecl,
    opts: Options,
) EmitError!void {
    try buf.appendSlice(allocator, "    private native ");
    try emitJavaReturnType(allocator, buf, md.return_type, opts);
    try buf.appendSlice(allocator, " sx_");
    try buf.appendSlice(allocator, md.name);
    try buf.append(allocator, '(');
    try emitJavaParamList(allocator, buf, md, opts);
    try buf.appendSlice(allocator, ");\n");
}

fn emitJavaReturnType(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    ret: ?*ast.Node,
    opts: Options,
) EmitError!void {
    if (ret == null) {
        try buf.appendSlice(allocator, "void");
        return;
    }
    try emitJavaType(allocator, buf, ret.?, opts);
}

fn emitJavaParamList(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    md: ast.RuntimeMethodDecl,
    opts: Options,
) EmitError!void {
    const start: usize = if (md.is_static) 0 else 1; // skip self
    for (md.params[start..], 0..) |p, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try emitJavaType(allocator, buf, p, opts);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, md.param_names[start + i]);
    }
}

fn emitJavaArgList(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    md: ast.RuntimeMethodDecl,
) EmitError!void {
    const start: usize = if (md.is_static) 0 else 1;
    for (md.param_names[start..], 0..) |name, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, name);
    }
}

fn emitJavaType(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    type_node: *ast.Node,
    opts: Options,
) EmitError!void {
    switch (type_node.data) {
        .type_expr => |te| {
            const name = javaPrimitiveName(te.name) orelse return EmitError.UnsupportedType;
            try buf.appendSlice(allocator, name);
        },
        .pointer_type_expr => |ptr| {
            const inner = ptr.pointee_type;
            if (inner.data != .type_expr) return EmitError.UnsupportedType;
            const target_name = inner.data.type_expr.name;
            if (std.mem.eql(u8, target_name, "void")) {
                try buf.appendSlice(allocator, "Object");
                return;
            }
            if (opts.classes) |reg| {
                if (reg.get(target_name)) |path| {
                    try appendDotted(allocator, buf, path);
                    return;
                }
            }
            // Unknown alias — pass through dotted as best-effort. Sema
            // should catch this earlier; tolerate for now.
            try appendDotted(allocator, buf, target_name);
        },
        else => return EmitError.UnsupportedType,
    }
}

fn javaPrimitiveName(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "void")) return "void";
    if (std.mem.eql(u8, name, "bool")) return "boolean";
    if (std.mem.eql(u8, name, "i8")) return "byte";
    if (std.mem.eql(u8, name, "u8")) return "byte";
    if (std.mem.eql(u8, name, "i16")) return "short";
    if (std.mem.eql(u8, name, "u16")) return "char";
    if (std.mem.eql(u8, name, "i32")) return "int";
    if (std.mem.eql(u8, name, "i64")) return "long";
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    return null;
}
