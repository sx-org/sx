// Tests for the demanded-body owner in lower/stmt.zig: the table that decides
// what a function body's tail flows to, read off the DECLARED return type
// alone. `.value` belongs to expression positions and is never a body's demand.

const std = @import("std");

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Lowering = ir_mod.Lowering;

test "lower: bodyDemand maps a declared return type to one demand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var l = Lowering.init(&module);
    const tt = &module.types;

    // Nothing to hand back: nothing is demanded.
    try std.testing.expect(l.bodyDemand(.void) == .none);
    try std.testing.expect(l.bodyDemand(.noreturn) == .none);

    // An ordinary return type demands the tail as the returned VALUE.
    try std.testing.expect(l.bodyDemand(.i32) == .return_value);
    try std.testing.expectEqual(TypeId.i32, l.bodyDemand(.i32).return_value);
    try std.testing.expect(l.bodyDemand(.string) == .return_value);
    const point = tt.intern(.{ .tuple = .{ .fields = &[_]TypeId{ .i64, .i64 }, .names = null } });
    try std.testing.expect(l.bodyDemand(point) == .return_value);

    // PURE failable (`-> !Named`): only an ERROR tail is the return.
    const tag = tt.internTag("Nope");
    const failed = tt.errorSetType(tt.internString("Failed"), &[_]u32{tag});
    try std.testing.expect(l.bodyDemand(failed) == .error_only);
    try std.testing.expectEqual(failed, l.bodyDemand(failed).error_only);

    // A VALUE-carrying failable (`-> (i32, !Failed)`) still returns a value —
    // its tail is the success value, not the error channel.
    const carrying = tt.intern(.{ .tuple = .{ .fields = &[_]TypeId{ .i32, failed }, .names = null } });
    try std.testing.expect(l.bodyDemand(carrying) == .return_value);

    // The classifier never invents an expression position.
    for ([_]TypeId{ .void, .noreturn, .i32, .string, failed, carrying }) |ty| {
        try std.testing.expect(l.bodyDemand(ty) != .value);
    }
}
