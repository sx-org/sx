//! The suspension substrate the comptime VM runs on: a single-threaded `std.Io`
//! whose `async` tasks are stackful native fibers (`std.Io.fiber`).
//!
//! A comptime evaluation is an ordinary recursive interpreter walk — nested
//! `run`/`invoke` frames on the Zig stack. Suspending one therefore means
//! suspending a whole call chain, which is exactly what a fiber gives: `async`
//! switches onto the task's own stack, `park` switches back to the driver with
//! every frame intact, and `unpark` resumes at the instruction that parked.
//!
//! The task MUST resume on the OS thread that started it: comptime evaluation
//! services `sx_trace_push` into the return-trace buffer, which is
//! `_Thread_local`, and the compiler reads that buffer after the evaluation
//! returns. Fibers keep the thread; a thread pool would not.
//!
//! `async` runs the task until it finishes or parks. A task that never parks —
//! every evaluation in the absence of a scheduler — completes inside `async`,
//! which then reports eager completion (a null `AnyFuture`) so `await` is a
//! no-op. Only a task that actually parked outlives the `async` call.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const fiber = std.Io.fiber;

/// Comptime evaluation recurses up to `Vm.max_depth` interpreter frames, and an
/// `exec` frame is wide (one register-file walk per instruction). A task gets the
/// whole of this to itself, where on the host stack the evaluation started
/// wherever the compiler already was.
const stack_size: usize = 8 << 20;
const page = std.heap.page_size_max;
const max_result_size: usize = 64;
const max_result_align: std.mem.Alignment = .@"16";
const max_context_size: usize = 256;
const max_context_align: std.mem.Alignment = .@"16";

/// One suspendable evaluation: its fiber context, the context to switch back to,
/// and its own stack. Recycled through `free_list` — a stack is expensive to map
/// and evaluations are strictly nested, so the pool never exceeds the deepest
/// nesting reached.
pub const Task = struct {
    /// Where this task resumes.
    context: fiber.Context,
    /// Where control returns when this task parks or finishes.
    resumer: fiber.Context,
    /// The task that was current when this one was entered.
    prev: ?*Task,
    next_free: ?*Task,
    state: State,
    result: [max_result_size]u8 align(max_result_align.toByteUnits()),

    pub const State = enum { start, running, parked, finished };

    /// The header sits at the base of the mapping and the stack grows DOWN
    /// toward it. Depth is bounded by `Vm.max_depth` well before the stack runs
    /// out, which is the interpreter's own overflow guard.
    const header_size = std.mem.alignForward(usize, @sizeOf(Task), max_context_align.toByteUnits());
    const total_size = std.mem.alignForward(
        usize,
        header_size + stack_size + @sizeOf(Closure) + max_context_size + max_context_align.toByteUnits(),
        page,
    );

    fn allocate() *Task {
        const raw = std.heap.page_allocator.alignedAlloc(u8, .of(Task), total_size) catch
            @panic("comptime VM: out of memory (evaluation stack)");
        return @ptrCast(raw.ptr);
    }

    /// The closure sits above the stack, at the top of the mapping, with the
    /// copied `async` arguments directly after it.
    fn closure(t: *Task) *Closure {
        const end = @intFromPtr(t) + total_size;
        return @ptrFromInt(max_context_align.max(.of(Closure)).backward(end - max_context_size) - @sizeOf(Closure));
    }
};

const Closure = struct {
    task: *Task,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,

    fn contextPointer(c: *Closure) [*]align(max_context_align.toByteUnits()) u8 {
        return @alignCast(@as([*]u8, @ptrCast(c)) + @sizeOf(Closure));
    }

    fn call(c: *Closure, _: *const fiber.Switch) callconv(.withStackAlign(.c, @alignOf(Closure))) noreturn {
        const t = c.task;
        t.state = .running;
        c.start(c.contextPointer(), &t.result);
        t.state = .finished;
        switchTo(&t.context, &t.resumer);
        unreachable; // switched back into a finished task
    }
};

/// Entry trampoline: the initial context points the fiber's stack pointer at its
/// `Closure`, which is the first argument here; `contextSwitch` leaves its message
/// in the second argument register.
///
/// The return address is ZEROED before the branch. Nothing ever returns from
/// `Closure.call`, but a stack-trace capture inside the evaluation (the testing
/// allocator takes one per allocation) unwinds through this frame and must find
/// a terminator instead of whatever the switching context happened to leave in
/// the link register.
fn taskEntry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ movq $0, (%%rsp)
            \\ jmp %[call:P]
            :
            : [call] "X" (&Closure.call),
        ),
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ mov x30, xzr
            \\ b %[call]
            :
            : [call] "X" (&Closure.call),
        ),
        .riscv64 => asm volatile (
            \\ mv a0, sp
            \\ li ra, 0
            \\ tail %[call]
            :
            : [call] "X" (&Closure.call),
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

var current_task: ?*Task = null;
var free_list: ?*Task = null;

/// Out of line so the caller treats the link register as call-clobbered
/// (`fiber.contextSwitch` is inline asm; the aarch64 backend does not honor
/// that clobber in the same function).
///
/// aarch64/riscv64 keep the return address in a register the switch destroys,
/// so this frame carries a slot for it. The slot address is pinned to a
/// register the switch clobbers: an unpinned operand can land in the link
/// register itself, and the reload then reads the other fiber's slot.
noinline fn switchTo(save: *fiber.Context, target: *fiber.Context) void {
    var s: fiber.Switch = .{ .old = save, .new = target };
    switch (comptime builtin.cpu.arch) {
        .aarch64 => {
            var lr: usize = undefined;
            asm volatile ("str x30, [%[p]]"
                :
                : [p] "{x9}" (&lr),
                : .{ .memory = true });
            _ = fiber.contextSwitch(&s);
            asm volatile ("ldr x30, [%[p]]"
                :
                : [p] "{x9}" (&lr),
                : .{ .x30 = true, .memory = true });
        },
        .riscv64 => {
            var ra: usize = undefined;
            asm volatile ("sd ra, 0(%[p])"
                :
                : [p] "{x5}" (&ra),
                : .{ .memory = true });
            _ = fiber.contextSwitch(&s);
            asm volatile ("ld ra, 0(%[p])"
                :
                : [p] "{x5}" (&ra),
                : .{ .x1 = true, .memory = true });
        },
        else => {
            _ = fiber.contextSwitch(&s);
        },
    }
}

/// Switch onto `t`'s stack; returns once `t` parks or finishes.
fn enter(t: *Task) void {
    t.prev = current_task;
    current_task = t;
    switchTo(&t.resumer, &t.context);
    current_task = t.prev;
}

/// The task the caller is running on, or null on the driver's own stack.
pub fn current() ?*Task {
    return current_task;
}

/// Suspend the running task and return control to whoever entered it. Returns
/// when `unpark` switches back — at this instruction, with every frame below it
/// untouched.
pub fn park() void {
    const t = current_task orelse @panic("comptime VM: park outside an evaluation task");
    t.state = .parked;
    switchTo(&t.context, &t.resumer);
    t.state = .running;
}

/// Resume a parked task; returns once it parks again or finishes.
pub fn unpark(t: *Task) void {
    std.debug.assert(t.state == .parked);
    enter(t);
}

fn recycle(t: *Task) void {
    t.next_free = free_list;
    free_list = t;
}

/// Give up on a parked task: it is never resumed, so its stack returns to the
/// pool. Only reached once the evaluation it carries has been refused.
pub fn abandon(t: *Task) void {
    std.debug.assert(t.state == .parked);
    recycle(t);
}

fn asyncImpl(
    _: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    std.debug.assert(result.len <= max_result_size);
    std.debug.assert(result_alignment.compare(.lte, max_result_align));
    std.debug.assert(context.len <= max_context_size);
    std.debug.assert(context_alignment.compare(.lte, max_context_align));

    const t = if (free_list) |f| blk: {
        free_list = f.next_free;
        break :blk f;
    } else Task.allocate();
    const c = t.closure();
    t.* = .{
        .context = switch (builtin.cpu.arch) {
            .x86_64 => .{ .rsp = @intFromPtr(c) - @sizeOf(usize), .rbp = 0, .rip = @intFromPtr(&taskEntry) },
            .aarch64, .riscv64 => .{ .sp = @intFromPtr(c), .fp = 0, .pc = @intFromPtr(&taskEntry) },
            else => comptime unreachable,
        },
        .resumer = undefined,
        .prev = null,
        .next_free = null,
        .state = .start,
        .result = undefined,
    };
    c.* = .{ .task = t, .start = start };
    @memcpy(c.contextPointer()[0..context.len], context);

    enter(t);
    if (t.state != .finished) return @ptrCast(t);
    @memcpy(result, t.result[0..result.len]);
    recycle(t);
    return null;
}

fn awaitImpl(_: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: std.mem.Alignment) void {
    const t: *Task = @ptrCast(@alignCast(any_future));
    if (t.state != .finished) @panic("comptime VM: awaited an evaluation that is still parked");
    @memcpy(result, t.result[0..result.len]);
    recycle(t);
}

/// Concurrency needs a second thread, which the thread-local return-trace buffer
/// forbids; every caller here uses `async`, whose tasks share this thread.
fn concurrentImpl(
    _: ?*anyopaque,
    _: usize,
    _: std.mem.Alignment,
    _: []const u8,
    _: std.mem.Alignment,
    _: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    return error.ConcurrencyUnavailable;
}

fn crashHandlerImpl(_: ?*anyopaque) void {}

fn unsupportedOp() callconv(.c) noreturn {
    @panic("comptime VM: the evaluation runtime implements no I/O operations");
}

/// The VM performs no I/O through this interface — only `async`/`await` — so
/// every other entry traps instead of pretending to work.
const vtable: Io.VTable = init: {
    var v: Io.VTable = undefined;
    for (@typeInfo(Io.VTable).@"struct".fields) |f| {
        @field(v, f.name) = @ptrCast(&unsupportedOp);
    }
    v.crashHandler = crashHandlerImpl;
    v.async = asyncImpl;
    v.concurrent = concurrentImpl;
    v.await = awaitImpl;
    break :init v;
};

pub fn io() Io {
    return .{ .userdata = null, .vtable = &vtable };
}
