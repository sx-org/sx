// Tests for lower/nominal.zig

const std = @import("std");
const types = @import("../types.zig");
const nominal = @import("nominal.zig");

const TypeInfo = types.TypeInfo;
const StringId = types.StringId;

// A forward-reference stub: the stateless resolver's empty-fields STRUCT
// placeholder for an as-yet-unregistered name.
const stub: TypeInfo = .{ .@"struct" = .{ .name = StringId.empty, .fields = &.{} } };

const enum_info: TypeInfo = .{ .@"enum" = .{ .name = StringId.empty, .variants = &.{} } };
const union_info: TypeInfo = .{ .@"union" = .{ .name = StringId.empty, .fields = &.{} } };
const tagged_union_info: TypeInfo = .{ .tagged_union = .{ .name = StringId.empty, .fields = &.{}, .tag_type = .i64 } };
const error_set_info: TypeInfo = .{ .error_set = .{ .name = StringId.empty, .tags = &.{} } };
const struct_info: TypeInfo = .{ .@"struct" = .{ .name = StringId.empty, .fields = &.{} } };

test "adoptsForwardStructStub: every non-struct nominal kind adopts a forward struct stub" {
    // The adopting-kind list (issue 0211 folded `.error_set` in): a forward
    // struct stub must be RE-KEYED (replaceKeyedInfo), never body-filled in
    // place (updatePreservingKey's kind-stability assert would trip).
    try std.testing.expect(nominal.adoptsForwardStructStub(stub, enum_info));
    try std.testing.expect(nominal.adoptsForwardStructStub(stub, union_info));
    try std.testing.expect(nominal.adoptsForwardStructStub(stub, tagged_union_info));
    try std.testing.expect(nominal.adoptsForwardStructStub(stub, error_set_info));
}

test "adoptsForwardStructStub: a struct never adopts (same-kind stays on updatePreservingKey)" {
    try std.testing.expect(!nominal.adoptsForwardStructStub(stub, struct_info));
}

test "adoptsForwardStructStub: scalar / non-nominal incoming kinds never adopt" {
    try std.testing.expect(!nominal.adoptsForwardStructStub(stub, .{ .signed = 32 }));
    try std.testing.expect(!nominal.adoptsForwardStructStub(stub, .{ .unsigned = 32 }));
    try std.testing.expect(!nominal.adoptsForwardStructStub(stub, .f64));
    try std.testing.expect(!nominal.adoptsForwardStructStub(stub, .bool));
    try std.testing.expect(!nominal.adoptsForwardStructStub(stub, .string));
    try std.testing.expect(!nominal.adoptsForwardStructStub(stub, .void));
}

test "adoptsForwardStructStub: a NON-EMPTY existing struct is a real type, not a stub" {
    const one_field = [_]TypeInfo.StructInfo.Field{.{ .name = StringId.empty, .ty = .i32 }};
    const real_struct: TypeInfo = .{ .@"struct" = .{ .name = StringId.empty, .fields = &one_field } };
    try std.testing.expect(!nominal.adoptsForwardStructStub(real_struct, enum_info));
    try std.testing.expect(!nominal.adoptsForwardStructStub(real_struct, error_set_info));
}

test "adoptsForwardStructStub: a non-struct existing slot never counts as a stub" {
    try std.testing.expect(!nominal.adoptsForwardStructStub(enum_info, error_set_info));
    try std.testing.expect(!nominal.adoptsForwardStructStub(error_set_info, enum_info));
    try std.testing.expect(!nominal.adoptsForwardStructStub(.f64, error_set_info));
}
