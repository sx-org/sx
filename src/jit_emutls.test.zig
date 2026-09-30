const std = @import("std");
const jit_emutls = @import("jit_emutls.zig");

test "each thread reads its own copy of an emulated thread-local, starting from the template" {
    jit_emutls.init();
    const initial: u64 = 7;
    var control: jit_emutls.Control = .{ .size = @sizeOf(u64), .alignment = @alignOf(u64), .index = 0, .template = @ptrCast(&initial) };

    const main_copy = copyOf(&control);
    main_copy.* += 1;
    try std.testing.expectEqual(main_copy, copyOf(&control));

    var seen: u64 = 0;
    const other = try std.Thread.spawn(.{}, readAndOverwrite, .{ &control, &seen });
    other.join();
    try std.testing.expectEqual(7, seen);
    try std.testing.expectEqual(8, main_copy.*);
}

fn copyOf(control: *jit_emutls.Control) *u64 {
    return @ptrCast(@alignCast(jit_emutls.getAddress(control)));
}

fn readAndOverwrite(control: *jit_emutls.Control, seen: *u64) void {
    const copy = copyOf(control);
    seen.* = copy.*;
    copy.* = 100;
}
