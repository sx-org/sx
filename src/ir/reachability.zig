//! Which functions the shipped binary can actually reach, and how it got there.
//!
//! sx functions are stage-polymorphic: nothing about a function declares which
//! stage it belongs to. What decides is REACHABILITY — a function is in the
//! binary because `main` (or an export, or something whose address was taken) can
//! reach it through the call graph, and it runs at compile time because a `#run`,
//! a constant initializer, a type builder, or a registered build callback can.
//! A helper reached from both does both.
//!
//! This pass answers the runtime half, and keeps the parent edge that found each
//! function so a diagnostic can show the path rather than just the last hop.

const std = @import("std");
const inst = @import("inst.zig");
const module_mod = @import("module.zig");

const FuncId = inst.FuncId;
const Function = inst.Function;
const Module = module_mod.Module;

pub const Reachability = struct {
    /// Did the module have any runtime root at all (a `main`, an export, a
    /// function named by global data)?
    ///
    /// With no roots there is no binary, so "what can the binary reach" has no
    /// answer — and answering "nothing" would drop every function. Callers must
    /// treat a rootless module as "emit everything": that is the conservative
    /// reading, and it means a future break in root detection degrades to
    /// emitting dead code rather than to emitting an empty module.
    has_roots: bool,
    /// Indexed by FuncId: can a runtime root reach this function?
    runtime: []bool,
    /// Indexed by FuncId: can a COMPILE-TIME root reach it? (a `#run` wrapper, a
    /// type builder, a registered build callback)
    compiler: []bool,
    /// The function through which the runtime search first reached this one.
    /// `null` for a root, and for anything unreached.
    via: []?FuncId,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Reachability) void {
        self.alloc.free(self.runtime);
        self.alloc.free(self.compiler);
        self.alloc.free(self.via);
    }

    /// Should the binary carry this function? Only what a runtime root reaches —
    /// everything else is dead code for the binary. A rootless module has no
    /// answer, so everything stays (see `has_roots`).
    pub fn emits(self: *const Reachability, f: FuncId) bool {
        if (!self.has_roots) return true;
        return self.runtime[f.index()];
    }

    /// Does this function exist only at compile time? True when the compile-time
    /// graph reaches it and the runtime graph does not — the case where emitting
    /// it would put a function in the binary that nothing there can call, and
    /// whose body may call compiler services that have no symbol.
    ///
    /// A function reached by NEITHER graph is not compiler-only: it is ordinary
    /// dead code (an unused stdlib helper), and it keeps being emitted exactly as
    /// before, for LLVM to drop.
    pub fn isCompilerOnly(self: *const Reachability, f: FuncId) bool {
        return self.compiler[f.index()] and !self.runtime[f.index()];
    }

    /// The call path from a runtime root to `f`, root first. Caller owns it.
    /// Empty when `f` is not runtime-reachable.
    pub fn pathTo(self: *const Reachability, alloc: std.mem.Allocator, f: FuncId) ![]FuncId {
        if (!self.runtime[f.index()]) return &.{};
        var rev: std.ArrayList(FuncId) = .empty;
        defer rev.deinit(alloc);
        var cur: ?FuncId = f;
        // `via` is a tree (each node is set once, when first reached), so this
        // terminates — but bound it anyway rather than trust that invariant.
        var guard: usize = 0;
        while (cur) |c| : (guard += 1) {
            if (guard > self.runtime.len) break;
            try rev.append(alloc, c);
            cur = self.via[c.index()];
        }
        const out = try alloc.alloc(FuncId, rev.items.len);
        for (rev.items, 0..) |id, i| out[out.len - 1 - i] = id;
        return out;
    }
};

/// Is `f` a runtime root — something the binary can enter through without any
/// caller inside it?
fn isRoot(m: *const Module, f: *const Function, name: []const u8) bool {
    // A compiler-only function is never a runtime root, whatever its linkage: a
    // build callback has external linkage so its dead declaration verifies, but
    // the binary it produces never calls it.
    if (f.isComptimeOnly()) return false;
    if (f.is_intrinsic) return false;
    _ = m;
    if (std.mem.eql(u8, name, "main")) return true;
    // Anything visible to the linker can be entered from outside this module.
    if (f.linkage == .external and !f.is_extern) return true;
    return false;
}

/// Collect every function a global's initializer names. Protocol vtables and the
/// process-wide default `Context` put function addresses in DATA, not in any
/// call — a search that only walks function bodies would conclude every vtable
/// method is dead and drop it.
///
/// The switch is exhaustive on purpose: a new `ConstantValue` arm that can carry
/// a function must decide here, rather than silently hide one.
fn collectConstFuncs(cv: inst.ConstantValue, out: *std.ArrayList(FuncId), alloc: std.mem.Allocator) !void {
    switch (cv) {
        .vtable => |ids| for (ids) |id| try out.append(alloc, id),
        .func_ref => |id| try out.append(alloc, id),
        .aggregate => |elems| for (elems) |e| try collectConstFuncs(e, out, alloc),
        // Carry no function reference.
        .int, .float, .boolean, .string, .null_val, .undef, .zeroinit, .global_ref => {},
    }
}

/// Compute the runtime-reachable set: a BFS from the roots over direct calls,
/// plus every function whose address is taken (a `func_ref` or a closure
/// trampoline can be called through a pointer we cannot follow statically, so
/// treat it as reachable rather than risk dropping a live function).
pub fn compute(alloc: std.mem.Allocator, m: *const Module) !Reachability {
    const n = m.functions.items.len;
    var r = Reachability{
        .has_roots = false,
        .runtime = try alloc.alloc(bool, n),
        .compiler = try alloc.alloc(bool, n),
        .via = try alloc.alloc(?FuncId, n),
        .alloc = alloc,
    };
    @memset(r.runtime, false);
    @memset(r.compiler, false);
    @memset(r.via, null);

    var queue: std.ArrayList(FuncId) = .empty;
    defer queue.deinit(alloc);

    for (m.functions.items, 0..) |*f, i| {
        const name = m.types.getString(f.name);
        if (isRoot(m, f, name)) {
            r.runtime[i] = true;
            try queue.append(alloc, FuncId.fromIndex(@intCast(i)));
        }
    }

    // Functions named by global DATA (vtables, the default Context's allocator
    // fns) are roots too: the code that calls them goes through the pointer, so
    // no call edge leads there.
    var from_data: std.ArrayList(FuncId) = .empty;
    defer from_data.deinit(alloc);
    for (m.globals.items) |g| {
        if (g.init_val) |iv| try collectConstFuncs(iv, &from_data, alloc);
    }
    for (from_data.items) |id| {
        if (id.index() >= n) continue;
        if (r.runtime[id.index()]) continue;
        r.runtime[id.index()] = true;
        try queue.append(alloc, id);
    }

    r.has_roots = queue.items.len > 0;
    try bfs(alloc, m, r.runtime, r.via, &queue);

    // The compile-time graph: every function a `#run` wrapper, a type builder, or
    // a registered build callback can reach. Same traversal, different roots and
    // no parent tracking (only the runtime path is ever printed).
    var cq: std.ArrayList(FuncId) = .empty;
    defer cq.deinit(alloc);
    for (m.functions.items, 0..) |*f, i| {
        if (!f.isComptimeOnly()) continue;
        r.compiler[i] = true;
        try cq.append(alloc, FuncId.fromIndex(@intCast(i)));
    }
    try bfs(alloc, m, r.compiler, null, &cq);

    return r;
}

/// Breadth-first over call / address-taken edges, marking `seen` and optionally
/// recording the parent that first reached each function.
fn bfs(
    alloc: std.mem.Allocator,
    m: *const Module,
    seen: []bool,
    via: ?[]?FuncId,
    queue: *std.ArrayList(FuncId),
) !void {
    const n = m.functions.items.len;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        const f = &m.functions.items[cur.index()];
        for (f.blocks.items) |blk| {
            for (blk.insts.items) |ins| {
                const callee: ?FuncId = switch (ins.op) {
                    .call => |c| c.callee,
                    // An address-taken function may be called through a pointer.
                    .func_ref => |fid| fid,
                    .closure_create => |cc| cc.func,
                    else => null,
                };
                const cid = callee orelse continue;
                if (cid.index() >= n) continue;
                if (seen[cid.index()]) continue;
                seen[cid.index()] = true;
                if (via) |v| v[cid.index()] = cur;
                try queue.append(alloc, cid);
            }
        }
    }
}
