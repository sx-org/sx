//! `__emutls_get_address` for the JIT. ORC's default platform sets up no
//! native thread-local storage, so C objects compiled for the JIT lower
//! `_Thread_local` to emulated TLS and resolve this runtime from the host.

const std = @import("std");

/// The control block clang emits for each emulated thread-local variable.
pub const Control = extern struct {
    size: usize,
    alignment: usize,
    /// 1-based slot in every thread's `Slots`; 0 until first access.
    index: usize,
    /// Initial bytes; null zero-fills.
    template: ?[*]const u8,
};

const Slots = struct {
    len: usize,
    items: [*]?*anyopaque,
};

var next_index = std.atomic.Value(usize).init(1);
var slots_key: std.c.pthread_key_t = undefined;

/// Runs before any JIT'd code can call `getAddress`, so the key is never raced.
pub fn init() void {
    if (std.c.pthread_key_create(&slots_key, freeSlots) != .SUCCESS) std.process.abort();
}

pub fn getAddress(control: *Control) callconv(.c) *anyopaque {
    const index = slotIndex(control);
    const slots = threadSlots(index);
    if (slots.items[index - 1]) |object| return object;
    const object = newObject(control);
    slots.items[index - 1] = object;
    return object;
}

fn slotIndex(control: *Control) usize {
    const assigned = @atomicLoad(usize, &control.index, .acquire);
    if (assigned != 0) return assigned;
    const fresh = next_index.fetchAdd(1, .monotonic);
    return @cmpxchgStrong(usize, &control.index, 0, fresh, .acq_rel, .acquire) orelse fresh;
}

fn threadSlots(index: usize) *Slots {
    const slots: *Slots = if (std.c.pthread_getspecific(slots_key)) |p| @ptrCast(@alignCast(p)) else blk: {
        const fresh: *Slots = @ptrCast(@alignCast(std.c.malloc(@sizeOf(Slots)) orelse std.process.abort()));
        fresh.* = .{ .len = 0, .items = undefined };
        if (std.c.pthread_setspecific(slots_key, fresh) != 0) std.process.abort();
        break :blk fresh;
    };
    if (index > slots.len) {
        const len = @max(index, 2 * slots.len);
        const old: ?*anyopaque = if (slots.len == 0) null else @ptrCast(slots.items);
        const items: [*]?*anyopaque = @ptrCast(@alignCast(std.c.realloc(old, len * @sizeOf(?*anyopaque)) orelse std.process.abort()));
        @memset(items[slots.len..len], null);
        slots.* = .{ .len = len, .items = items };
    }
    return slots;
}

fn newObject(control: *const Control) *anyopaque {
    var object: ?*anyopaque = null;
    if (std.c.posix_memalign(&object, @max(control.alignment, @sizeOf(*anyopaque)), control.size) != 0) std.process.abort();
    const bytes: [*]u8 = @ptrCast(object.?);
    if (control.template) |t| @memcpy(bytes[0..control.size], t[0..control.size]) else @memset(bytes[0..control.size], 0);
    return object.?;
}

fn freeSlots(value: *anyopaque) callconv(.c) void {
    const slots: *Slots = @ptrCast(@alignCast(value));
    for (slots.items[0..slots.len]) |object| std.c.free(object);
    if (slots.len != 0) std.c.free(@ptrCast(slots.items));
    std.c.free(slots);
}
