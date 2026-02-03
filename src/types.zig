const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;

/// Editor-indexing and parse-time name metadata — used by `src/sema.zig` (the
/// language-server symbol/type index) for navigation, completion, and hover, and
/// by `src/parser.zig` for parse-time primitive-name classification. This is NOT
/// a compiler type model: it carries no type-resolution surface (no widening,
/// convertibility, or layout). The canonical model the compiler resolves, lowers,
/// and lays out against is `TypeId` / `TypeTable` in `src/ir/types.zig`. Keep this
/// display- and classification-only; never add resolution semantics here.
pub const Type = union(enum) {
    // Variable-width integers (1–64 bits)
    signed: u8,
    unsigned: u8,
    // Fixed-width floats
    f32,
    f64,
    // Other
    void_type,
    boolean,
    string_type,
    cstring_type,
    enum_type: []const u8,
    struct_type: []const u8,
    union_type: []const u8,
    array_type: ArrayTypeInfo,
    slice_type: SliceTypeInfo,
    pointer_type: PointerTypeInfo,
    many_pointer_type: ManyPointerTypeInfo,
    vector_type: VectorTypeInfo,
    function_type: FunctionTypeInfo,
    closure_type: ClosureTypeInfo,
    any_type,
    usize_type,
    isize_type,
    optional_type: OptionalTypeInfo,
    meta_type: MetaTypeInfo,
    tuple_type: TupleTypeInfo,
    /// Type resolution failed (sema couldn't infer/resolve). A dedicated
    /// sentinel — never a legitimate type — so callers can't mistake it for a
    /// real result the way a fabricated `s(64)` would be. Mirrors
    /// `ir.TypeId.unresolved`.
    unresolved,

    /// `is_raw` records whether the inner type-name came from a backtick raw
    /// reference (`` `i2 ``) or an already-resolved user type. It is the
    /// `skip_builtin` the resolver MUST pass when re-resolving the stored inner
    /// name — without it `resolveTypeNameStr` would reclassify a
    /// user type named `i2` as the builtin int, diverging from codegen. The
    /// field is REQUIRED (no default) so a future construction site cannot
    /// silently drop the bit, the way the LSP index did for compound shapes.
    pub const SliceTypeInfo = struct {
        element_name: []const u8,
        is_raw: bool,
    };

    pub const PointerTypeInfo = struct {
        pointee_name: []const u8,
        is_raw: bool,
    };

    pub const ManyPointerTypeInfo = struct {
        element_name: []const u8,
        is_raw: bool,
    };

    pub const FunctionTypeInfo = struct {
        param_types: []const Type,
        return_type: *const Type,
    };

    pub const ClosureTypeInfo = struct {
        param_types: []const Type,
        return_type: *const Type,
    };

    pub const ArrayTypeInfo = struct {
        element_name: []const u8,
        /// null = the dimension could not be folded to a compile-time integer
        /// by the editor index (an identifier const it couldn't resolve, or a
        /// non-const expression). Explicit "unknown" rather than a fabricated
        /// concrete length — this is hover/metadata, not codegen.
        length: ?u32,
        is_raw: bool,
    };

    pub const VectorTypeInfo = struct {
        element_name: []const u8,
        length: u32,
    };

    pub const OptionalTypeInfo = struct {
        child_name: []const u8,
        is_raw: bool,
    };

    pub const MetaTypeInfo = struct {
        name: []const u8,
    };

    pub const TupleTypeInfo = struct {
        field_names: ?[]const []const u8, // null for positional tuples
        field_types: []const Type,
    };

    // Convenience constructors
    pub fn s(width: u8) Type {
        return .{ .signed = width };
    }

    pub fn u(width: u8) Type {
        return .{ .unsigned = width };
    }

    pub fn fromName(name: []const u8) ?Type {
        if (name.len == 0) return null;
        return switch (name[0]) {
            's' => if (std.mem.eql(u8, name, "string")) .string_type else null,
            'c' => if (std.mem.eql(u8, name, "cstring")) .cstring_type else null,
            'u' => {
                if (std.mem.eql(u8, name, "usize")) return .usize_type;
                if (name.len >= 2) {
                    const width = std.fmt.parseInt(u8, name[1..], 10) catch return null;
                    if (width >= 1 and width <= 64) return Type.u(width);
                }
                return null;
            },
            'i' => {
                if (std.mem.eql(u8, name, "isize")) return .isize_type;
                if (name.len >= 2) {
                    const width = std.fmt.parseInt(u8, name[1..], 10) catch return null;
                    if (width >= 1 and width <= 64) return Type.s(width);
                }
                return null;
            },
            'b' => if (std.mem.eql(u8, name, "bool")) .boolean else null,
            'f' => {
                if (std.mem.eql(u8, name, "f32")) return .f32;
                if (std.mem.eql(u8, name, "f64")) return .f64;
                return null;
            },
            '?' => if (name.len >= 2) .{ .optional_type = .{ .child_name = name[1..], .is_raw = false } } else null,
            'a' => if (std.mem.eql(u8, name, "any")) .any_type else null,
            'v' => if (std.mem.eql(u8, name, "void")) .void_type else null,
            '[' => {
                // Sentinel-terminated slice: [:0]u8 → string_type
                if (name.len >= 5 and name[1] == ':') {
                    if (std.mem.indexOfScalar(u8, name, ']')) |close| {
                        const sentinel = name[2..close];
                        const elem = name[close + 1 ..];
                        if (std.mem.eql(u8, sentinel, "0") and std.mem.eql(u8, elem, "u8")) {
                            return .string_type;
                        }
                    }
                }
                // Many-pointer: [*]T
                if (name.len >= 4 and name[1] == '*' and name[2] == ']') {
                    return .{ .many_pointer_type = .{ .element_name = name[3..], .is_raw = false } };
                }
                return null;
            },
            '*' => if (name.len >= 2) .{ .pointer_type = .{ .pointee_name = name[1..], .is_raw = false } } else null,
            'V' => {
                // Vector(N,T)
                if (name.len >= 10 and std.mem.startsWith(u8, name, "Vector(") and name[name.len - 1] == ')') {
                    const inner = name[7 .. name.len - 1];
                    if (std.mem.indexOfScalar(u8, inner, ',')) |comma| {
                        const length = std.fmt.parseInt(u32, inner[0..comma], 10) catch return null;
                        const elem_name = inner[comma + 1 ..];
                        if (elem_name.len > 0) {
                            return .{ .vector_type = .{ .element_name = elem_name, .length = length } };
                        }
                    }
                }
                return null;
            },
            else => null,
        };
    }

    /// Returns the canonical type name for this type, or null for complex types.
    /// Used for looking up impl methods on non-struct types (e.g., i32.eq).
    pub fn toName(self: Type) ?[]const u8 {
        return switch (self) {
            .signed => |w| switch (w) {
                8 => "i8",
                16 => "i16",
                32 => "i32",
                64 => "i64",
                else => null,
            },
            .unsigned => |w| switch (w) {
                8 => "u8",
                16 => "u16",
                32 => "u32",
                64 => "u64",
                else => null,
            },
            .f32 => "f32",
            .f64 => "f64",
            .boolean => "bool",
            .string_type => "string",
            .cstring_type => "cstring",
            .void_type => "void",
            .usize_type => "usize",
            .isize_type => "isize",
            .struct_type => |n| n,
            .enum_type => |n| n,
            .union_type => |n| n,
            else => null,
        };
    }

    pub fn fromTypeExpr(node: *Node) ?Type {
        if (node.data != .type_expr) return null;
        // A backtick raw type reference (`` `i2 ``) is the LITERAL name used as
        // a type — it must skip this builtin/reserved classifier and resolve
        // through user-defined types only, mirroring the codegen-
        // side `resolveNamed`'s `skip_builtin`. Returning null lets the sema
        // callers fall through to their struct/enum/alias registry lookup.
        if (node.data.type_expr.is_raw) return null;
        return fromName(node.data.type_expr.name);
    }

    pub fn isStruct(self: Type) bool {
        return switch (self) {
            .struct_type => true,
            else => false,
        };
    }

    pub fn isOptional(self: Type) bool {
        return switch (self) {
            .optional_type => true,
            else => false,
        };
    }

    pub fn isSlice(self: Type) bool {
        return switch (self) {
            .slice_type => true,
            else => false,
        };
    }

    pub fn isPointer(self: Type) bool {
        return switch (self) {
            .pointer_type => true,
            else => false,
        };
    }

    pub fn isManyPointer(self: Type) bool {
        return switch (self) {
            .many_pointer_type => true,
            else => false,
        };
    }

    pub fn isArray(self: Type) bool {
        return switch (self) {
            .array_type => true,
            else => false,
        };
    }

    fn fmtAlloc(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
        var buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, fmt, args) catch
            return try std.fmt.allocPrint(allocator, fmt, args);
        return try allocator.dupe(u8, result);
    }

    /// Format type name for mangling and display (e.g. "i32", "u8", "f64")
    pub fn displayName(self: Type, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .signed => |w| {
                var buf: [4]u8 = undefined;
                const result = std.fmt.bufPrint(&buf, "i{d}", .{w}) catch unreachable;
                return try allocator.dupe(u8, result);
            },
            .unsigned => |w| {
                var buf: [4]u8 = undefined;
                const result = std.fmt.bufPrint(&buf, "u{d}", .{w}) catch unreachable;
                return try allocator.dupe(u8, result);
            },
            .f32 => "f32",
            .f64 => "f64",
            .boolean => "bool",
            .string_type => "string",
            .cstring_type => "cstring",
            .void_type => "void",
            .any_type => "any",
            .usize_type => "usize",
            .isize_type => "isize",
            .unresolved => "<unresolved>",
            .enum_type => |name| name,
            .struct_type => |name| name,
            .union_type => |name| name,
            .slice_type => |info| return fmtAlloc(allocator, "[]{s}", .{info.element_name}),
            .pointer_type => |info| return fmtAlloc(allocator, "*{s}", .{info.pointee_name}),
            .many_pointer_type => |info| return fmtAlloc(allocator, "[*]{s}", .{info.element_name}),
            .array_type => |info| {
                if (info.length) |n| return fmtAlloc(allocator, "[{d}]{s}", .{ n, info.element_name });
                return fmtAlloc(allocator, "[_]{s}", .{info.element_name});
            },
            .vector_type => |info| return fmtAlloc(allocator, "Vector({d},{s})", .{ info.length, info.element_name }),
            .function_type => |info| {
                var buf = std.ArrayList(u8).empty;
                try buf.append(allocator, '(');
                for (info.param_types, 0..) |pt, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, try pt.displayName(allocator));
                }
                try buf.append(allocator, ')');
                if (!std.meta.eql(info.return_type.*, Type.void_type)) {
                    try buf.appendSlice(allocator, " -> ");
                    try buf.appendSlice(allocator, try info.return_type.displayName(allocator));
                }
                return try buf.toOwnedSlice(allocator);
            },
            .closure_type => |info| {
                var buf = std.ArrayList(u8).empty;
                try buf.appendSlice(allocator, "Closure(");
                for (info.param_types, 0..) |pt, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, try pt.displayName(allocator));
                }
                try buf.append(allocator, ')');
                if (!std.meta.eql(info.return_type.*, Type.void_type)) {
                    try buf.appendSlice(allocator, " -> ");
                    try buf.appendSlice(allocator, try info.return_type.displayName(allocator));
                }
                return try buf.toOwnedSlice(allocator);
            },
            .optional_type => |info| return fmtAlloc(allocator, "?{s}", .{info.child_name}),
            .meta_type => |info| info.name,
            .tuple_type => |info| {
                var buf = std.ArrayList(u8).empty;
                try buf.append(allocator, '(');
                for (info.field_types, 0..) |ft, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    if (info.field_names) |names| {
                        try buf.appendSlice(allocator, names[i]);
                        try buf.appendSlice(allocator, ": ");
                    }
                    try buf.appendSlice(allocator, try ft.displayName(allocator));
                }
                try buf.append(allocator, ')');
                return try buf.toOwnedSlice(allocator);
            },
        };
    }
};
