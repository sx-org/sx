//! The suspension substrate on its own: a task that parks keeps its whole frame
//! chain, and the side that entered it keeps its own live values across the
//! stack switch.

const std = @import("std");
const comptime_async = @import("comptime_async.zig");

var parked_inner: ?*comptime_async.Task = null;
var parked_outer: ?*comptime_async.Task = null;
var shared: u64 = 0;

fn eager(a: u64, b: u64) u64 {
    return a *% b;
}

fn parksOnce(a: u64, b: u64) u64 {
    shared = a;
    parked_outer = comptime_async.current().?;
    comptime_async.park();
    return a +% b +% shared;
}

fn parksAndNeverResumes(seed: u64) u64 {
    parked_outer = comptime_async.current().?;
    comptime_async.park();
    return seed;
}

fn innerParks(a: u64) u64 {
    parked_inner = comptime_async.current().?;
    comptime_async.park();
    return a +% 1;
}

fn outerDrivesInner(v: u64) u64 {
    const io = comptime_async.io();
    var witness: u64 = v;
    var f = io.async(innerParks, .{v *% 2});
    if (parked_inner == null) return 0;
    if (comptime_async.current() == null) return 0;
    comptime_async.unpark(parked_inner.?);
    witness +%= f.await(io);
    return witness;
}

test "async substrate: a task that never parks completes eagerly" {
    const io = comptime_async.io();
    var witness: u64 = 0xfeed_face_dead_beef;
    var f = io.async(eager, .{ @as(u64, 6), @as(u64, 7) });
    try std.testing.expectEqual(@as(u64, 42), f.await(io));
    try std.testing.expectEqual(@as(u64, 0xfeed_face_dead_beef), witness);
    witness +%= 1;
    try std.testing.expectEqual(@as(u64, 0xfeed_face_dead_bef0), witness);
}

test "async substrate: a parked task resumes at the instruction that parked" {
    const io = comptime_async.io();
    parked_outer = null;
    shared = 0;
    var witness: u64 = 0x0123_4567_89ab_cdef;
    var f = io.async(parksOnce, .{ @as(u64, 3), @as(u64, 4) });
    // The value the entering side held must survive the switch, and so must the
    // task's own frame: `shared` is what the task assigned before it parked.
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), witness);
    try std.testing.expectEqual(@as(u64, 3), shared);
    try std.testing.expect(parked_outer != null);

    shared = 10;
    comptime_async.unpark(parked_outer.?);
    witness +%= 1;
    try std.testing.expectEqual(@as(u64, 17), f.await(io));
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdf0), witness);
}

test "async substrate: an abandoned task's stack is recycled" {
    const io = comptime_async.io();
    parked_outer = null;
    var f = io.async(parksAndNeverResumes, .{@as(u64, 99)});
    try std.testing.expect(parked_outer != null);
    const abandoned = parked_outer.?;
    comptime_async.abandon(abandoned);
    f = undefined;

    var g = io.async(eager, .{ @as(u64, 5), @as(u64, 5) });
    try std.testing.expectEqual(@as(u64, 25), g.await(io));
}

test "async substrate: a running task drives a nested parked task" {
    const io = comptime_async.io();
    parked_inner = null;
    var witness: u64 = 0xaaaa_bbbb_cccc_dddd;
    var f = io.async(outerDrivesInner, .{@as(u64, 8)});
    try std.testing.expectEqual(@as(u64, 8 + 17), f.await(io));
    try std.testing.expectEqual(@as(u64, 0xaaaa_bbbb_cccc_dddd), witness);
    witness +%= 1;
    try std.testing.expectEqual(@as(u64, 0xaaaa_bbbb_cccc_ddde), witness);
    try std.testing.expect(comptime_async.current() == null);
}
