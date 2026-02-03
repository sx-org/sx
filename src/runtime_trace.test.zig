// Unit tests for the ERR E3.1 error return-trace ring buffer
// (library/vendors/sx_trace_runtime/sx_trace.c). The .c is linked into the
// module via build.zig, so these extern symbols resolve at test-link time.
// This grounds the buffer logic (push / overflow-survives-newest / clear /
// len / truncated / oldest-to-newest ordering) before E3.2 wires the
// push/clear calls into codegen.

const std = @import("std");

extern fn sx_trace_push(frame: u64) void;
extern fn sx_trace_clear() void;
extern fn sx_trace_len() u32;
extern fn sx_trace_truncated() u32;
extern fn sx_trace_frame_at(i: u32) u64;

const CAP: u32 = 32;

test "trace buffer: push / len / frame_at oldest-to-newest" {
    sx_trace_clear();
    try std.testing.expectEqual(@as(u32, 0), sx_trace_len());
    try std.testing.expectEqual(@as(u32, 0), sx_trace_truncated());

    sx_trace_push(10);
    sx_trace_push(20);
    sx_trace_push(30);
    try std.testing.expectEqual(@as(u32, 3), sx_trace_len());
    try std.testing.expectEqual(@as(u64, 10), sx_trace_frame_at(0));
    try std.testing.expectEqual(@as(u64, 20), sx_trace_frame_at(1));
    try std.testing.expectEqual(@as(u64, 30), sx_trace_frame_at(2));
    // Out-of-range frame → 0.
    try std.testing.expectEqual(@as(u64, 0), sx_trace_frame_at(3));
    try std.testing.expectEqual(@as(u32, 0), sx_trace_truncated());
}

test "trace buffer: clear resets length and truncation" {
    sx_trace_clear();
    sx_trace_push(1);
    sx_trace_push(2);
    sx_trace_clear();
    try std.testing.expectEqual(@as(u32, 0), sx_trace_len());
    try std.testing.expectEqual(@as(u32, 0), sx_trace_truncated());
    try std.testing.expectEqual(@as(u64, 0), sx_trace_frame_at(0));
}

test "trace buffer: overflow keeps the newest CAP frames, latches truncated" {
    sx_trace_clear();
    // Push CAP + 5 frames with distinguishable values (i = 1..CAP+5).
    var i: u64 = 1;
    while (i <= CAP + 5) : (i += 1) sx_trace_push(i);

    // Length saturates at CAP; truncation latched.
    try std.testing.expectEqual(CAP, sx_trace_len());
    try std.testing.expectEqual(@as(u32, 1), sx_trace_truncated());

    // The surviving frames are the newest CAP, oldest-to-newest. The first 5
    // (values 1..5) were overwritten, so frame_at(0) is value 6.
    try std.testing.expectEqual(@as(u64, 6), sx_trace_frame_at(0));
    try std.testing.expectEqual(@as(u64, CAP + 5), sx_trace_frame_at(CAP - 1));
    // Strictly increasing by 1 across the surviving window.
    var k: u32 = 0;
    while (k < CAP) : (k += 1) {
        try std.testing.expectEqual(@as(u64, 6 + k), sx_trace_frame_at(k));
    }
}

test "trace buffer: exactly CAP frames, no truncation" {
    sx_trace_clear();
    var i: u64 = 0;
    while (i < CAP) : (i += 1) sx_trace_push(i * 100);
    try std.testing.expectEqual(CAP, sx_trace_len());
    try std.testing.expectEqual(@as(u32, 0), sx_trace_truncated());
    try std.testing.expectEqual(@as(u64, 0), sx_trace_frame_at(0));
    try std.testing.expectEqual(@as(u64, (CAP - 1) * 100), sx_trace_frame_at(CAP - 1));
    sx_trace_clear();
}
