//! Byte-addressable comptime machine — Phase 1 of `current/PLAN-COMPILER-VM.md`.
//!
//! The comptime evaluator is being rebuilt around a byte-addressable memory
//! so comptime values are NATIVE BYTES (like runtime), instead of the tagged
//! `Value` union the legacy interpreter (`interp.zig`) uses. This module is the
//! machine substrate: byte-addressable memory backed by an ARENA of stable host
//! allocations (each `allocBytes` never moves; freed wholesale on `deinit`), plus
//! a per-call `Frame` holding a register file. `Addr` is the allocation's real
//! host pointer, so a comptime pointer and an FFI-returned host pointer are the
//! same kind of value.
//!
//! Value model (grows over later sub-steps): a register (`Reg`) is a raw 64-bit
//! word that is EITHER an immediate scalar (its bits) OR an `Addr` into comptime
//! memory (for aggregates) — interpreted by the IR result type, exactly like a
//! real machine / LLVM. Scalars up to 64 bits (sx's widest is `i64`/`u64`/`f64`)
//! fit a register directly; structs/arrays/slices live in comptime memory and a
//! register holds their address.
//!
//! Target-awareness lives in the EXECUTOR, not here: this module only moves raw
//! bytes. Ordinary target layout is supplied by the type table. During VM
//! execution, pointer-bearing temporary aggregates use host pointer width because
//! their words are real host addresses; the target width is restored before IR
//! emission, so cross-compilation retains its target ABI.
//!
//! `Machine` (arena-backed memory + scalar word read/write + byte views) holds the
//! comptime stack + heap; `Frame` is the per-call register file. A `Frame` does NOT
//! reclaim the machine's memory on exit — a callee can return an aggregate whose
//! register holds an `Addr` into comptime memory, and reclaiming would dangle it. The
//! legacy interpreter remains the live evaluator until the VM reaches parity.

const std = @import("std");
const inst_mod = @import("inst.zig");
const types = @import("types.zig");
const intrinsics = @import("intrinsics.zig");
const mod_mod = @import("module.zig");
const comptime_value = @import("comptime_value.zig");
const compiler_hooks = @import("compiler_hooks.zig");
const host_ffi = @import("host_ffi.zig");
const errors_mod = @import("../errors.zig");
const Value = comptime_value.Value;
const Inst = inst_mod.Inst;
const Ref = inst_mod.Ref;
const BlockId = inst_mod.BlockId;
const Function = inst_mod.Function;
const Module = mod_mod.Module;
const OpTag = std.meta.Tag(inst_mod.Op);
const TypeId = types.TypeId;
const FuncId = inst_mod.FuncId;

// The error return-trace buffer (sx_trace.c, linked into the compiler) — the same
// one emit_llvm reads after a `#run` to render the comptime escape trace. A
// comptime failable that raises emits `sx_trace_push(trace_frame())` as it unwinds;
// the VM services those calls natively so the trace populates identically to legacy.
extern fn sx_trace_push(frame: u64) void;
extern fn sx_trace_clear() void;
const Span = inst_mod.Span;

/// A comptime memory address — a REAL host pointer (`@intFromPtr`), since the
/// machine allocates each object from an arena that never moves it. `null_addr` (0)
/// is the null sentinel (no allocation is ever at address 0), so a zeroed register
/// reads as null — mirroring how the legacy `Value` model distinguishes `null_val`.
/// Because addresses are absolute host pointers, a comptime pointer and an
/// FFI-returned host pointer are the SAME kind of value: the FFI bridge hands them
/// to / from real libc with no translation (Phase 4D).
pub const Addr = u64;
pub const null_addr: Addr = 0;

/// A raw register word: an immediate scalar's bits, or an `Addr`. The IR result
/// type tells the executor which.
pub const Reg = u64;

/// The comptime memory machine: an ARENA of host allocations serving as the
/// comptime stack + heap. Each `allocBytes` is a separate arena allocation that
/// NEVER moves and is freed wholesale on `deinit` (no per-object free — comptime is
/// short-lived). There is NO fixed buffer and NO size cap: the arena grows through
/// its backing allocator on demand. `Addr` is the allocation's REAL host pointer,
/// so a comptime pointer and an FFI-returned host pointer are interchangeable —
/// the FFI bridge passes them to / from libc untouched (Phase 4D).
pub const Machine = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Machine {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Machine) void {
        self.arena.deinit();
    }

    /// Allocate `size` ZEROED bytes aligned to `alignment`; returns the address (a
    /// stable host pointer). `size == 0` still yields a valid, non-null address.
    /// Over-allocates to honor a RUNTIME alignment (`Allocator.alignedAlloc` needs a
    /// comptime alignment) and aligns the base up within the block.
    pub fn allocBytes(self: *Machine, size: usize, alignment: usize) Addr {
        const a = if (alignment == 0) 1 else alignment;
        const n = @max(size, 1);
        const raw = self.arena.allocator().alloc(u8, n + a - 1) catch @panic("comptime VM: out of memory");
        @memset(raw, 0);
        const aligned = std.mem.alignForward(usize, @intFromPtr(raw.ptr), a);
        return @intCast(aligned);
    }

    /// Read a `size`-byte (1/2/4/8) little-endian scalar at `addr` into a register
    /// word (zero-extended). A null / oversized access returns `error.OutOfBounds`
    /// (NOT a panic) so a malformed comptime run BAILS to the legacy fallback rather
    /// than crashing. (Addresses are absolute host pointers, so there is no
    /// upper-bound check — a non-null wild address would fault; the `Frame` `bad_ref`
    /// guard catches the dominant malformed-IR vector before any such deref.)
    pub fn readWord(_: *const Machine, addr: Addr, size: usize) error{OutOfBounds}!Reg {
        if (addr == null_addr or size > 8) return error.OutOfBounds;
        const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(addr)));
        var buf: [8]u8 = @splat(0);
        @memcpy(buf[0..size], p[0..size]);
        return std.mem.readInt(u64, &buf, .little);
    }

    /// Write the low `size` bytes (1/2/4/8) of register word `val` little-endian at
    /// `addr`. Null-checked → `error.OutOfBounds` (not a panic).
    pub fn writeWord(_: *Machine, addr: Addr, size: usize, val: Reg) error{OutOfBounds}!void {
        if (addr == null_addr or size > 8) return error.OutOfBounds;
        const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, val, .little);
        @memcpy(p[0..size], buf[0..size]);
    }

    /// A mutable byte view of `len` bytes at `addr` (for aggregate copies / slice
    /// payloads). Null-checked → `error.OutOfBounds`. A zero-length view is always
    /// valid. The view stays valid across later `allocBytes` — the arena never moves
    /// an allocation.
    pub fn bytes(_: *Machine, addr: Addr, len: usize) error{OutOfBounds}![]u8 {
        if (len == 0) return &[_]u8{};
        if (addr == null_addr) return error.OutOfBounds;
        const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
        return p[0..len];
    }
};

/// One call frame: a register file indexed by IR `Ref` index. It does NOT reclaim
/// the machine stack on exit — a callee can return an aggregate whose value is an
/// `Addr` into comptime memory, and reclaiming the callee's region would dangle it.
/// Comptime evaluation is bounded, so all allocations live until `Vm.deinit`;
/// `Machine.mark`/`reset` remain for explicit scoped use. The register file IS
/// per-call (each `run` gets a fresh one sized to its callee's Ref space).
pub const Frame = struct {
    regs: []Reg,
    gpa: std.mem.Allocator,
    /// Set when `get`/`set` is handed an out-of-range Ref index — a malformed IR
    /// (e.g. a `ret Ref.none` left by an unresolved name during LOWERING-time
    /// comptime eval). The `run` loop checks it after each instruction and bails
    /// (→ legacy fallback), so the VM never panics on imperfect IR.
    bad_ref: bool = false,

    pub fn init(gpa: std.mem.Allocator, num_regs: usize) Frame {
        const regs = gpa.alloc(Reg, num_regs) catch @panic("comptime VM: out of memory (frame regs)");
        @memset(regs, 0);
        return .{ .regs = regs, .gpa = gpa };
    }

    pub fn deinit(self: *Frame) void {
        self.gpa.free(self.regs);
    }

    pub fn get(self: *Frame, ref_index: usize) Reg {
        if (ref_index >= self.regs.len) {
            self.bad_ref = true;
            return 0;
        }
        return self.regs[ref_index];
    }

    pub fn set(self: *Frame, ref_index: usize, word: Reg) void {
        if (ref_index >= self.regs.len) {
            self.bad_ref = true;
            return;
        }
        self.regs[ref_index] = word;
    }
};

/// Why the most recent `tryEval` returned `null` (bailed to the legacy
/// interpreter) — the bail `detail` (op name / one-line reason), or a fixed string
/// for the structural skips. Mirrors the legacy interp's `last_bail_detail`; the
/// host reads it under a coverage-trace gate to learn what to port next. Cleared at
/// the top of every `tryEval`; meaningful only when `tryEval` returned `null`.
pub var last_bail_reason: ?[]const u8 = null;

/// True iff the most recent `tryEval` bail happened at the RESULT-BRIDGE step
/// (`regToValue` — the comptime function RAN to completion but its result shape
/// cannot be materialized into a host `Value`), as opposed to an EXECUTION bail
/// (`runEntry` couldn't evaluate the body — an unported op, a VM
/// `DivisionByZero`, etc.). The distinction matters for a body-local `#run`
/// fold (issue 0182): a BRIDGE bail means a runtime re-execution would run the
/// SAME body over (possibly `---`) storage and produce DIFFERENT, garbage data —
/// a silent miscompile that must fail the build. An EXECUTION bail means the VM
/// simply can't run it; the established runtime-call fallback computes the
/// correct value and must be preserved. Meaningful only when `tryEval` returned
/// `null`; cleared at the top of every `tryEval`.
pub var last_bail_was_bridge: bool = false;

/// Wiring entry point: try to evaluate comptime function `func_id` entirely on the
/// comptime VM and return its result as a legacy `Value`, or `null` if the VM
/// can't handle it (unsupported op, no body, or any bail) — the caller then falls
/// back to the legacy interpreter. The result is deep-copied into `gpa`, so it
/// outlives the VM's comptime memory (freed here on return).
///
/// Safe for ARBITRARY host comptime functions: the `Machine` accessors are
/// hardened to return `error.OutOfBounds` (not a debug panic) on a null/out-of-
/// range/oversized access, so a malformed run bails to `null` (→ legacy fallback)
/// rather than crashing the compiler. On a bail, `last_bail_reason` names the cause.
pub fn tryEval(gpa: std.mem.Allocator, module: *const Module, func_id: inst_mod.FuncId, build_config: ?*compiler_hooks.BuildConfig, source_map: ?*const std.StringHashMap([:0]const u8)) ?Value {
    last_bail_reason = null;
    last_bail_was_bridge = false;
    // VM aggregates contain real host pointers, even while cross-compiling.
    // Lay those temporary values out with the host pointer width; lowering and
    // emission see the restored target width and retain the target ABI.
    const target_pointer_size = module.types.pointer_size;
    @constCast(&module.types).pointer_size = @sizeOf(usize);
    defer @constCast(&module.types).pointer_size = target_pointer_size;
    const func = module.getFunction(func_id);
    if (func.is_extern or func.blocks.items.len == 0) {
        last_bail_reason = "extern / no body";
        return null;
    }
    var vm = Vm.init(gpa);
    defer vm.deinit();
    vm.table = &module.types;
    vm.module = module;
    vm.build_config = build_config;
    vm.source_map = source_map;

    // `runEntry` materializes the implicit `*Context` (a comptime const-init /
    // `#run` wrapper is nullary in user args, so the implicit ctx is its sole
    // param) as a zeroed Context in comptime memory and runs. The common const body
    // never reads the ctx; one that uses the allocator hits unported
    // `call_indirect` → bails → legacy. Gate-ON corpus parity validates this.
    const reg = vm.runEntry(func_id) catch |err| {
        last_bail_reason = vm.detail orelse @errorName(err);
        return null;
    };
    // A void/noreturn entry (a `#run <expr>;` side-effect) produces no value —
    // `regToValue` would bail on the void type, so yield `.void_val` directly.
    if (func.ret == .void or func.ret == .noreturn) return .void_val;
    return vm.regToValue(gpa, &module.types, reg, func.ret) catch |err| {
        // The body RAN; only the result bridge failed → mark this a BRIDGE bail
        // so a body-local `#run` fold can tell a genuine "result can't be
        // materialized" miscompile from a "VM can't run it" fallback (issue 0182).
        last_bail_was_bridge = true;
        last_bail_reason = vm.detail orelse @errorName(err);
        return null;
    };
}

/// Run a post-link build callback on the VM (the post-codegen build driver — see
/// `core.invokeByFuncId`). Like `tryEval`, but for a callback that may take the
/// opaque `BuildOptions` handle as an explicit arg (the `on_build(cb)` form,
/// `cb: (opt: BuildOptions) -> bool`): when `pass_options` is set, the handle (a
/// null sentinel — the real state is the threaded `BuildConfig`) is passed after
/// the implicit ctx. Returns null on a bail (`last_bail_reason` names the cause).
pub fn runBuildCallback(gpa: std.mem.Allocator, module: *const Module, func_id: inst_mod.FuncId, build_config: ?*compiler_hooks.BuildConfig, source_map: ?*const std.StringHashMap([:0]const u8), pass_options: bool) ?Value {
    last_bail_reason = null;
    const target_pointer_size = module.types.pointer_size;
    @constCast(&module.types).pointer_size = @sizeOf(usize);
    defer @constCast(&module.types).pointer_size = target_pointer_size;
    const func = module.getFunction(func_id);
    if (func.is_extern or func.blocks.items.len == 0) {
        last_bail_reason = "extern / no body";
        return null;
    }
    var vm = Vm.init(gpa);
    defer vm.deinit();
    vm.table = &module.types;
    vm.module = module;
    vm.build_config = build_config;
    vm.source_map = source_map;
    const extra: []const Reg = if (pass_options) &.{null_addr} else &.{};
    const reg = vm.runEntryArgs(func_id, extra) catch |err| {
        last_bail_reason = vm.detail orelse @errorName(err);
        return null;
    };
    if (func.ret == .void or func.ret == .noreturn) return .void_val;
    return vm.regToValue(gpa, &module.types, reg, func.ret) catch |err| {
        last_bail_reason = vm.detail orelse @errorName(err);
        return null;
    };
}

// ── Executor ────────────────────────────────────────────────────────────────
//
// Walks the SAME SSA IR the legacy interpreter (`interp.zig`) walks, but over
// comptime frames: each SSA result is a `Reg` word (immediate scalar bits, or
// an `Addr`). Scalar semantics MIRROR the legacy interp so the two evaluators
// agree byte-for-byte (the parity goal): integer math is 64-bit wrapping/signed
// (`+%`, `@divTrunc`, signed compares — the legacy's `.int` is i64 regardless of
// the declared width), float math is f64. Memory/aggregate/call ops are not ported
// yet — they bail loudly (`error.Unsupported` + `detail`), never silently.

pub const Error = error{ DivisionByZero, TypeError, Unsupported, OutOfBounds };

fn isFloat(ty: TypeId) bool {
    return ty == .f32 or ty == .f64;
}

/// The nominal identity (`name` + stable `nominal_id`) of a `declare_type`'d slot —
/// from the forward `tagged_union` OR an already-completed nominal (so a re-fill
/// preserves identity). Mirrors `compiler_lib.nominalIdent`. Null for a non-nominal
/// handle (not a `declare_type` result).
fn nominalIdentOf(info: types.TypeInfo) ?struct { name: types.StringId, nominal_id: u32 } {
    return switch (info) {
        .tagged_union => |u| .{ .name = u.name, .nominal_id = u.nominal_id },
        .@"enum" => |e| .{ .name = e.name, .nominal_id = e.nominal_id },
        .@"struct" => |s| .{ .name = s.name, .nominal_id = s.nominal_id },
        .tuple => .{ .name = types.StringId.empty, .nominal_id = 0 }, // structural; name vestigial
        else => null,
    };
}

/// A `{ name: string, ty: Type }` member decoded from comptime memory — the shared
/// shape of a compiler-API `Member`, a metatype `EnumVariant { name, payload }`,
/// and a `StructField { name, type }` (all 2-field `{ string, Type }` structs).
const NamedMember = struct { name: types.StringId, ty: TypeId };

/// A signed integer type narrower-or-equal to 64 bits — its loaded bytes must be
/// SIGN-extended into the register (the legacy `.int` model is i64).
fn isSignedInt(ty: TypeId) bool {
    return switch (ty) {
        .i8, .i16, .i32, .i64, .isize => true,
        else => false,
    };
}

/// Sign-extend a `sz`-byte (1/2/4) value (zero-extended in `raw`) to a 64-bit reg.
fn signExtendWord(raw: Reg, sz: usize) Reg {
    const shift: u6 = @intCast((8 - sz) * 8);
    return @bitCast((@as(i64, @bitCast(raw)) << shift) >> shift);
}

// ── BuildOptions target predicates (Phase 5.5) ───────────────────────────────
// Computed from the `--target` triple, mirroring `compiler_hooks`'s legacy hooks
// (which mirror `TargetConfig.is{MacOS,IOS,IOSDevice,IOSSimulator}()`).

fn tripleHas(triple: ?[]const u8, needle: []const u8) bool {
    const t = triple orelse return false;
    return std.mem.indexOf(u8, t, needle) != null;
}
fn predIsIOS(triple: ?[]const u8) bool {
    return tripleHas(triple, "apple-ios");
}
fn predIsMacOS(triple: ?[]const u8) bool {
    if (predIsIOS(triple)) return false;
    return tripleHas(triple, "apple-macosx") or tripleHas(triple, "apple-macos") or tripleHas(triple, "apple-darwin");
}
fn predIsIOSDevice(triple: ?[]const u8) bool {
    return predIsIOS(triple) and !tripleHas(triple, "simulator");
}
fn predIsIOSSimulator(triple: ?[]const u8) bool {
    return predIsIOS(triple) and tripleHas(triple, "simulator");
}
fn predIsAndroid(triple: ?[]const u8) bool {
    return tripleHas(triple, "android");
}

/// Map a BuildOptions predicate name (`is_macos`/…) to its triple-test, or null.
fn boolPredicate(name: []const u8) ?*const fn (?[]const u8) bool {
    if (std.mem.eql(u8, name, "is_macos")) return predIsMacOS;
    if (std.mem.eql(u8, name, "is_ios")) return predIsIOS;
    if (std.mem.eql(u8, name, "is_ios_device")) return predIsIOSDevice;
    if (std.mem.eql(u8, name, "is_ios_simulator")) return predIsIOSSimulator;
    if (std.mem.eql(u8, name, "is_android")) return predIsAndroid;
    return null;
}

pub const Vm = struct {
    machine: Machine,
    gpa: std.mem.Allocator,
    /// The type table — supplies layout for memory + aggregate ops. VM entry
    /// temporarily selects host pointer width because stored addresses are real
    /// host pointers; the target width is restored on return. Optional so
    /// scalar-only runs need no table; memory ops bail loudly if it is absent.
    table: ?*const types.TypeTable = null,
    /// The module — resolves a `call`'s callee `FuncId` to its `Function`. Optional
    /// so leaf functions (no calls) need none; a `call` bails loudly if it is absent.
    module: ?*const Module = null,
    /// The mutable build configuration (`BuildOptions` accumulator) — the SAME
    /// `BuildConfig` `EmitLLVM` owns and `main.zig` reads post-link. Threaded in at
    /// the `#run`/const-init eval sites so a `BuildOptions` intrinsic
    /// (e.g. `set_post_link_callback`) records into it directly. Null at lowering-time
    /// type-fn evals (no build config exists yet); such a function bails loudly.
    build_config: ?*compiler_hooks.BuildConfig = null,
    /// File → source text (the diagnostics' `import_sources`), threaded from the host
    /// so `trace_resolve` can turn a packed `(func_id, span.start)` comptime frame into
    /// `file:line:col` + the source line. Null → line/col degrade to 1 / "".
    source_map: ?*const std.StringHashMap([:0]const u8) = null,
    /// Current call-recursion depth, guarded against host stack overflow on deep /
    /// infinite comptime recursion (mirrors the legacy interp's `call_depth`).
    depth: u32 = 0,
    /// Reason for the last `error.Unsupported` / `error.TypeError` bail — the op
    /// tag name or a one-line explanation. Mirrors the legacy interp's
    /// `last_bail_detail` so the host can surface a real message, not a bare error.
    detail: ?[]const u8 = null,
    /// Per-global memo of comptime-evaluated globals (the legacy interp's
    /// `global_values`): `global_get` caches a global's Reg so a chain of globals
    /// reading each other doesn't re-run inits (and so each runs at most once).
    global_cache: std.AutoHashMap(u32, Reg),
    /// Addressable storage for globals referenced through `@global`. Kept
    /// separate from value memoization so taking a scalar global's address
    /// never changes a later `global_get` into the pointer value.
    global_addr_cache: std.AutoHashMap(u32, Reg),
    /// The active call chain of `FuncId`s (mirrors the legacy interp's
    /// `call_chain`). `trace_frame` packs the top of this stack into a return-trace
    /// frame; pushed by `invoke`/`runEntry`, popped on return.
    call_stack: std.ArrayList(FuncId) = .empty,

    pub const max_depth: u32 = 512;

    pub fn init(gpa: std.mem.Allocator) Vm {
        return .{
            .machine = Machine.init(gpa),
            .gpa = gpa,
            .global_cache = std.AutoHashMap(u32, Reg).init(gpa),
            .global_addr_cache = std.AutoHashMap(u32, Reg).init(gpa),
        };
    }

    pub fn deinit(self: *Vm) void {
        self.global_cache.deinit();
        self.global_addr_cache.deinit();
        self.call_stack.deinit(self.gpa);
        self.machine.deinit();
    }

    /// Run a comptime ENTRY function (nullary in user args): materialize the
    /// implicit `*Context` arg if the function declares one, then run. Shared by
    /// `tryEval` (the host entry) and `evalGlobal` (a comptime global's init). The
    /// materialized ctx is zeroed; a body that ignores it runs, one that uses the
    /// allocator hits unported `call_indirect` and bails.
    fn runEntry(self: *Vm, func_id: FuncId) Error!Reg {
        return self.runEntryArgs(func_id, &.{});
    }

    /// Run a comptime entry with the materialized implicit `*Context` (when the
    /// function has one) PREPENDED to `extra` explicit arg words. A nullary
    /// const-init / `#run` passes `extra = &.{}`; a post-link build callback of
    /// the `on_build` form passes the opaque `BuildOptions` handle.
    fn runEntryArgs(self: *Vm, func_id: FuncId, extra: []const Reg) Error!Reg {
        const module = self.module orelse return self.failMsg("comptime VM: entry run needs a module");
        const func = module.getFunction(func_id);
        var argbuf: std.ArrayList(Reg) = .empty;
        defer argbuf.deinit(self.gpa);
        if (func.has_implicit_ctx) {
            argbuf.append(self.gpa, try self.materializeDefaultContext(module)) catch @panic("comptime VM: out of memory (entry args)");
        }
        for (extra) |a| argbuf.append(self.gpa, a) catch @panic("comptime VM: out of memory (entry args)");
        if (argbuf.items.len != func.params.len)
            return self.failMsg("comptime VM: entry arg count mismatch (ctx + explicit args vs params)");
        self.call_stack.append(self.gpa, func_id) catch @panic("comptime VM: out of memory (call stack)");
        defer _ = self.call_stack.pop();
        return self.run(func, argbuf.items);
    }

    /// Materialize the default `Context` in comptime memory and return its address —
    /// the VM analogue of the static `__sx_default_context` global. The
    /// implicit-ctx param is an opaque `*void`, so the real Context type AND
    /// its initializer come from the `__sx_default_context` global — the ONE
    /// source of truth (lowering emits it EARLY for scan-time type-fn evals;
    /// see `emitDefaultContextGlobalEarly`). Laying that constant into
    /// comptime memory gives a context whose fn slots are real func-refs, so
    /// a comptime body that allocates via `context.allocator` dispatches
    /// through `call_indirect` to the thunk to `CAllocator.alloc_bytes` to
    /// `libc_malloc` to the VM's native `malloc` — all on the VM, no host
    /// heap. No hand-built shadow context exists: if the global is absent
    /// (std not imported, or its defaults not yet constructible at this
    /// point in the scan), bail LOUDLY — never a hardcoded thunk table that
    /// drifts from the real protocol shape.
    fn materializeDefaultContext(self: *Vm, module: *const Module) Error!Addr {
        const table = self.table orelse return self.failMsg("comptime VM: default context needs a type table");
        for (module.globals.items) |*g| {
            if (!std.mem.eql(u8, module.types.getString(g.name), "__sx_default_context")) continue;
            const addr = self.machine.allocBytes(table.typeSizeBytes(g.ty), table.typeAlignBytes(g.ty)); // zeroed
            if (g.init_val) |iv| try self.layoutConst(table, iv, g.ty, addr);
            return addr;
        }
        return self.failMsg("comptime VM: `__sx_default_context` is not emitted yet — the implicit context is unavailable in this evaluation");
    }

    /// Lay a static `ConstantValue` of type `ty` into comptime memory at `addr` (the
    /// destination is pre-zeroed). Scalars/func-refs write a word; a null/zero/undef
    /// leaf stays zeroed; an aggregate recurses per field at the type's natural
    /// offsets. Builds the default context from its global constant.
    fn layoutConst(self: *Vm, table: *const types.TypeTable, cv: inst_mod.ConstantValue, ty: TypeId, addr: Addr) Error!void {
        switch (cv) {
            .int => |v| try self.writeField(table, addr, ty, @bitCast(v)),
            .boolean => |b| try self.writeField(table, addr, ty, @intFromBool(b)),
            .float => |v| try self.writeField(table, addr, ty, @bitCast(v)),
            .func_ref => |fid| try self.writeField(table, addr, ty, funcRefWord(fid)),
            .global_ref => |gid| try self.writeField(table, addr, ty, try self.evalGlobalAddress(gid)),
            .null_val, .zeroinit, .undef => {}, // destination already zeroed
            .aggregate => |fields| {
                if (ty.isBuiltin()) return self.failMsg("comptime VM: const aggregate at a builtin type");
                switch (table.get(ty)) {
                    .@"struct" => |s| for (fields, 0..) |fv, i| {
                        if (i >= s.fields.len) break;
                        try self.layoutConst(table, fv, s.fields[i].ty, addr + fieldOffset(table, ty, @intCast(i)));
                    },
                    .tuple => |t| for (fields, 0..) |fv, i| {
                        if (i >= t.fields.len) break;
                        try self.layoutConst(table, fv, t.fields[i], addr + tupleFieldOffset(table, ty, @intCast(i)));
                    },
                    .array => |a| for (fields, 0..) |fv, i| {
                        try self.layoutConst(table, fv, a.element, addr + @as(Addr, @intCast(i)) * @as(Addr, @intCast(table.typeSizeBytes(a.element))));
                    },
                    .optional => |o| {
                        if (fields.len > 0) try self.layoutConst(table, fields[0], o.child, addr);
                        if (fields.len > 1) try self.layoutConst(table, fields[1], .bool, addr + table.typeSizeBytes(o.child));
                    },
                    else => return self.failMsg("comptime VM: const aggregate at an unsupported type"),
                }
            },
            .string, .vtable => return self.failMsg("comptime VM: const string/vtable not supported in layoutConst yet"),
        }
    }

    /// Evaluate comptime global `gid` to its Reg value — lazily running its
    /// `comptime_func` (with implicit-ctx bootstrap), or reading a scalar static
    /// `init_val` — memoized in `global_cache`. The legacy `getGlobal` analogue.
    fn evalGlobal(self: *Vm, gid: inst_mod.GlobalId) Error!Reg {
        const module = self.module orelse return self.failMsg("comptime VM: global_get needs a module");
        const idx = gid.index();
        if (self.global_cache.get(idx)) |r| return r;
        if (idx >= module.globals.items.len) return self.failMsg("comptime VM: global_get index out of range");
        const global = &module.globals.items[idx];
        if (self.global_addr_cache.get(idx)) |addr| {
            const table = try self.requireTable();
            if (kindOf(table, global.ty) == .aggregate) {
                self.global_cache.put(idx, addr) catch @panic("comptime VM: out of memory (global cache)");
                return addr;
            }
        }
        const r: Reg = if (global.comptime_func) |fid|
            try self.runEntry(fid)
        else if (global.init_val) |iv|
            try self.constToReg(iv, global.ty)
        else
            return self.failMsg("comptime VM: global_get of a global with no comptime_func / init_val");
        self.global_cache.put(idx, r) catch @panic("comptime VM: out of memory (global cache)");
        return r;
    }

    /// Convert a static `ConstantValue` (a global's `init_val`) to a Reg. Scalars
    /// only for now (float regs hold f64 bits — storage narrows f32); aggregate /
    /// string / vtable / func_ref bail loudly (add when a real global_get needs it).
    fn constToReg(self: *Vm, cv: inst_mod.ConstantValue, ty: TypeId) Error!Reg {
        const table = try self.requireTable();
        if (kindOf(table, ty) == .aggregate) {
            const addr = self.machine.allocBytes(table.typeSizeBytes(ty), table.typeAlignBytes(ty));
            try self.layoutConst(table, cv, ty, addr);
            return addr;
        }
        return switch (cv) {
            .int => |v| @bitCast(v),
            .boolean => |b| @intFromBool(b),
            .float => |v| @bitCast(v),
            .null_val, .zeroinit, .undef => null_addr,
            else => self.failMsg("comptime VM: global_get static init kind not yet supported (string/aggregate/vtable/func_ref)"),
        };
    }

    fn evalGlobalAddress(self: *Vm, gid: inst_mod.GlobalId) Error!Reg {
        const module = self.module orelse return self.failMsg("comptime VM: global address needs a module");
        if (self.global_addr_cache.get(gid.index())) |cached| return cached;
        if (gid.index() >= module.globals.items.len) return self.failMsg("comptime VM: global address out of range");
        const g = &module.globals.items[gid.index()];
        const table = try self.requireTable();
        if (kindOf(table, g.ty) == .aggregate) {
            if (self.global_cache.get(gid.index())) |cached| return cached;
        }
        const addr = self.machine.allocBytes(table.typeSizeBytes(g.ty), table.typeAlignBytes(g.ty));
        if (g.init_val) |iv| try self.layoutConst(table, iv, g.ty, addr);
        self.global_addr_cache.put(gid.index(), addr) catch @panic("comptime VM: out of memory (global address cache)");
        return addr;
    }

    /// Run `func` with scalar `args` (one `Reg` word each, in param order) and
    /// return the scalar result word. `ret_void` / falling off a block with no
    /// terminator yields 0. Aggregate args/results await the memory sub-step.
    pub fn run(self: *Vm, func: *const Function, args: []const Reg) Error!Reg {
        if (self.depth >= max_depth) {
            self.detail = "comptime VM: call recursion too deep";
            return error.Unsupported;
        }
        self.depth += 1;
        defer self.depth -= 1;

        // The Ref index space is flat: params first, then every block's
        // instructions in block order (each `block.first_ref` is its base). Size
        // the register file + a parallel Ref→type map to it.
        var total: usize = func.params.len;
        for (func.blocks.items) |blk| total += blk.insts.items.len;

        const ref_types = self.gpa.alloc(TypeId, total) catch @panic("comptime VM: out of memory (ref types)");
        defer self.gpa.free(ref_types);
        for (func.params, 0..) |p, i| ref_types[i] = p.ty;
        for (func.blocks.items) |blk| {
            for (blk.insts.items, 0..) |ins, j| ref_types[@as(usize, blk.first_ref) + j] = ins.ty;
        }

        var frame = Frame.init(self.gpa, total);
        defer frame.deinit();
        for (args, 0..) |a, i| frame.set(i, a);

        var current = BlockId.fromIndex(0);
        // Branch args are passed as Refs (not resolved values): the same frame
        // persists, and a target block's `block_param`s — its first instructions —
        // read the source registers before anything overwrites them (SSA: a block
        // only writes its own Ref range).
        var block_args: []const Ref = &.{};
        while (true) {
            // A malformed branch target (out-of-range block) bails, not panics.
            if (current.index() >= func.blocks.items.len) return self.badRef();
            const blk = &func.blocks.items[current.index()];
            var ref: usize = blk.first_ref;
            var jumped = false;
            for (blk.insts.items) |*ins| {
                if (ins.op == .block_param) {
                    const bp = ins.op.block_param;
                    if (bp.param_index < block_args.len)
                        frame.set(ref, frame.get(block_args[bp.param_index].index()));
                    if (frame.bad_ref) return self.badRef();
                    ref += 1;
                    continue;
                }
                const step = try self.exec(ins, &frame, ref_types);
                // A malformed IR (an out-of-range / `Ref.none` operand from an
                // unresolved name) flips `frame.bad_ref` instead of panicking — bail.
                if (frame.bad_ref) return self.badRef();
                switch (step) {
                    .value => |w| {
                        frame.set(ref, w);
                        ref += 1;
                    },
                    .jump => |j| {
                        current = j.target;
                        block_args = j.args;
                        jumped = true;
                        break;
                    },
                    .ret => |w| return w,
                    .ret_void => return 0,
                }
            }
            if (!jumped) return 0; // fell off the block with no terminator → void
        }
    }

    const Step = union(enum) {
        value: Reg,
        jump: struct { target: BlockId, args: []const Ref },
        ret: Reg,
        ret_void,
    };

    fn exec(self: *Vm, ins: *const Inst, frame: *Frame, ref_types: []const TypeId) Error!Step {
        switch (ins.op) {
            // ── Constants ───────────────────────────────────────
            .const_int => |v| return .{ .value = @bitCast(v) },
            .const_bool => |v| return .{ .value = @intFromBool(v) },
            .const_float => |v| return .{ .value = @bitCast(v) },
            .const_null, .const_undef => return .{ .value = null_addr },
            // A `Type` literal: the 8-byte handle is the `TypeId` index in a word
            // (the `.type_value` representation). `regToValue` maps it back to a
            // `.type_tag` Value at the legacy boundary.
            .const_type => |tid| return .{ .value = @as(Reg, tid.index()) },

            // ── Arithmetic ──────────────────────────────────────
            .add, .sub, .mul, .div, .mod => |b| return .{
                .value = try arith(std.meta.activeTag(ins.op), ins.ty, frame.get(b.lhs.index()), frame.get(b.rhs.index())),
            },
            // ── Bitwise + shift (i64, mirroring the legacy interp) ─
            .bit_and, .bit_or, .bit_xor, .shl, .shr => |b| return .{
                .value = bitwise(std.meta.activeTag(ins.op), frame.get(b.lhs.index()), frame.get(b.rhs.index())),
            },
            .bit_not => |u| return .{ .value = @bitCast(~@as(i64, @bitCast(frame.get(u.operand.index())))) },
            .neg => |u| {
                const x = frame.get(u.operand.index());
                if (isFloat(ins.ty)) return .{ .value = @bitCast(-@as(f64, @bitCast(x))) };
                return .{ .value = @bitCast(-%@as(i64, @bitCast(x))) };
            },

            // ── Comparison (operand type drives signedness/kind) ─
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => |b| {
                const r = try self.cmp(std.meta.activeTag(ins.op), (try self.refTy(ref_types, b.lhs)), frame.get(b.lhs.index()), frame.get(b.rhs.index()));
                return .{ .value = @intFromBool(r) };
            },

            // ── Logical (operands already evaluated) ────────────
            .bool_and => |b| return .{ .value = @intFromBool(frame.get(b.lhs.index()) != 0 and frame.get(b.rhs.index()) != 0) },
            .bool_or => |b| return .{ .value = @intFromBool(frame.get(b.lhs.index()) != 0 or frame.get(b.rhs.index()) != 0) },
            .bool_not => |u| return .{ .value = @intFromBool(frame.get(u.operand.index()) == 0) },

            // ── Conversions ─────────────────────────────────────
            // widen/narrow/bitcast pass the bits through (comptime values don't
            // truncate — matches the legacy interp). int↔float DO convert.
            .widen, .narrow, .bitcast => |c| return .{ .value = frame.get(c.operand.index()) },
            .int_to_float => |c| return .{ .value = @bitCast(@as(f64, @floatFromInt(@as(i64, @bitCast(frame.get(c.operand.index())))))) },
            .float_to_int => |c| return .{ .value = @bitCast(@as(i64, @intFromFloat(@as(f64, @bitCast(frame.get(c.operand.index())))))) },

            // ── Memory + structs (flat layout, target-aware) ────
            .alloca => |t| {
                const table = try self.requireTable();
                return .{ .value = self.machine.allocBytes(table.typeSizeBytes(t), table.typeAlignBytes(t)) };
            },
            .load => |u| {
                const table = try self.requireTable();
                return .{ .value = try self.readField(table, frame.get(u.operand.index()), ins.ty) };
            },
            .store => |s| {
                const table = try self.requireTable();
                const vty = if (s.val_ty != .void) s.val_ty else (try self.refTy(ref_types, s.val));
                try self.writeField(table, frame.get(s.ptr.index()), vty, frame.get(s.val.index()));
                return .{ .value = 0 }; // store has a void result but still occupies a Ref slot
            },
            // Comptime is single-threaded, so seq_cst is trivially satisfied —
            // atomic load/store are ordinary load/store here (the ordering is
            // a no-op at comptime). Mirrors the design (§3): the interp needs no
            // atomics machinery.
            .atomic_load => |a| {
                const table = try self.requireTable();
                return .{ .value = try self.readField(table, frame.get(a.ptr.index()), ins.ty) };
            },
            .atomic_store => |a| {
                const table = try self.requireTable();
                const vty = if (a.val_ty != .void) a.val_ty else (try self.refTy(ref_types, a.val));
                try self.writeField(table, frame.get(a.ptr.index()), vty, frame.get(a.val.index()));
                return .{ .value = 0 };
            },
            // RMW at comptime (single-thread): load old, compute new, store new,
            // return old — the ordering is a no-op. min/max pick signed vs
            // unsigned compare from the value type.
            .atomic_rmw => |a| {
                const table = try self.requireTable();
                const vty = if (a.val_ty != .void) a.val_ty else ins.ty;
                const old = try self.readField(table, frame.get(a.ptr.index()), ins.ty);
                const operand = frame.get(a.operand.index());
                const new_val: Reg = switch (a.kind) {
                    .add => old +% operand,
                    .sub => old -% operand,
                    .@"and" => old & operand,
                    .@"or" => old | operand,
                    .xor => old ^ operand,
                    .min, .max => blk: {
                        // `Reg` is u64, so `@max`/`@min` on it is an UNSIGNED
                        // compare. For a signed type, reinterpret as i64 first so
                        // a negative value loses to a positive one — matching LLVM
                        // `atomicrmw min`/`max` (signed) and the emit side.
                        const want_max = a.kind == .max;
                        if (table.isUnsignedInt(vty)) {
                            break :blk if (want_max) @max(old, operand) else @min(old, operand);
                        }
                        const so: i64 = @bitCast(old);
                        const sp: i64 = @bitCast(operand);
                        break :blk @bitCast(if (want_max) @max(so, sp) else @min(so, sp));
                    },
                    .xchg => operand, // swap: new value IS the operand
                };
                try self.writeField(table, frame.get(a.ptr.index()), vty, new_val);
                return .{ .value = old };
            },
            // Compare-exchange at comptime (single-thread): read actual, compare
            // to cmp, and on equality store new. The ordering is a no-op; `weak`
            // behaves as a strong exchange (no spurious failure with one thread).
            // Result is `?T` (ins.ty): SUCCESS → none, FAILURE → some(actual).
            // Integer T only (the recognizer's guard rules out pointer optionals),
            // so the optional is laid out as payload@0 + has_value flag — exactly
            // like the `optional_wrap` arm below.
            .atomic_cmpxchg => |a| {
                const table = try self.requireTable();
                const elem_ty = if (a.val_ty != .void) a.val_ty else return self.failMsg("comptime compare_exchange: missing element type");
                const ptr = frame.get(a.ptr.index());
                const actual = try self.readField(table, ptr, elem_ty);
                const cmp_val = frame.get(a.cmp.index());
                const success = actual == cmp_val;
                if (success) try self.writeField(table, ptr, elem_ty, frame.get(a.new.index()));
                // Build the `?T` result in VM memory.
                const opt_ty = ins.ty; // ?T
                const addr = self.machine.allocBytes(table.typeSizeBytes(opt_ty), table.typeAlignBytes(opt_ty));
                // writeWord(addr, SIZE, val): write the 1-byte has_value flag
                // EXPLICITLY (size=1) — never rely on alloc zero-init for the
                // success/null case (a size=0 write is a no-op, correct only by
                // accident; REJECTED-PATTERNS "coincidentally correct").
                const has_value_off = addr + table.typeSizeBytes(elem_ty);
                if (success) {
                    try self.machine.writeWord(has_value_off, 1, 0); // has_value = 0 (null)
                } else {
                    try self.writeField(table, addr, elem_ty, actual); // payload = actual
                    try self.machine.writeWord(has_value_off, 1, 1); // has_value = 1
                }
                return .{ .value = addr };
            },
            // A fence is a no-op at comptime (single-thread → nothing to order).
            .atomic_fence => return .{ .value = 0 },
            .struct_init => |agg| {
                const table = try self.requireTable();
                const sty = ins.ty;
                // `string`/`any` are builtin TWO-WORD aggregates (`{ptr@0, len@8}` /
                // `{tag@0, value@8}`) — a literal like `string.{ ptr = p, len = n }`
                // (e.g. `from_cstring`) struct_inits one. Lay each operand as an
                // 8-byte word; the other builtins have no aggregate literal form.
                if (sty == .string or sty == .any) {
                    const a = self.machine.allocBytes(16, 8);
                    for (agg.fields, 0..) |fr, i| {
                        if (i >= 2) break;
                        try self.machine.writeWord(a + @as(Addr, @intCast(i)) * 8, 8, frame.get(fr.index()));
                    }
                    return .{ .value = a };
                }
                if (sty.isBuiltin()) return self.failMsg("comptime VM: struct_init at a builtin result type");
                const addr = self.machine.allocBytes(table.typeSizeBytes(sty), table.typeAlignBytes(sty));
                // `struct_init` is the generic aggregate-literal op — its result
                // type may be a struct, an ARRAY (e.g. `EnumVariant.[ … ]`), or a
                // tuple. Lay each operand out at the matching offset; bail loudly on
                // any other shape (never a `.@"struct"`-union-access panic).
                switch (table.get(sty)) {
                    .@"struct" => |s| for (s.fields, 0..) |f, i| {
                        if (i >= agg.fields.len) break;
                        try self.writeField(table, addr + fieldOffset(table, sty, @intCast(i)), f.ty, frame.get(agg.fields[i].index()));
                    },
                    .array => |a| {
                        const esz: Addr = @intCast(table.typeSizeBytes(a.element));
                        for (agg.fields, 0..) |fr, i| try self.writeField(table, addr + @as(Addr, @intCast(i)) * esz, a.element, frame.get(fr.index()));
                    },
                    .tuple => |t| for (t.fields, 0..) |fty, i| {
                        if (i >= agg.fields.len) break;
                        try self.writeField(table, addr + tupleFieldOffset(table, sty, @intCast(i)), fty, frame.get(agg.fields[i].index()));
                    },
                    else => return self.failMsg("comptime VM: struct_init at a non-aggregate result type"),
                }
                return .{ .value = addr };
            },
            .struct_get => |fa| {
                const table = try self.requireTable();
                const sty = try self.aggType(table, fa, ref_types);
                // For a real struct the field type comes from the table; for a
                // string/slice fat-pointer base ({ptr,len}) the result type IS the
                // field type (`ins.ty`).
                const fty = if (!sty.isBuiltin() and table.get(sty) == .@"struct")
                    table.get(sty).@"struct".fields[fa.field_index].ty
                else
                    ins.ty;
                return .{ .value = try self.readField(table, frame.get(fa.base.index()) + fieldOffset(table, sty, fa.field_index), fty) };
            },
            .struct_gep => |fa| {
                const table = try self.requireTable();
                const sty = try self.aggType(table, fa, ref_types);
                return .{ .value = frame.get(fa.base.index()) + fieldOffset(table, sty, fa.field_index) };
            },

            // ── Tuples (positional aggregates) ──────────────────
            .tuple_init => |agg| {
                const table = try self.requireTable();
                const tty = ins.ty;
                const addr = self.machine.allocBytes(table.typeSizeBytes(tty), table.typeAlignBytes(tty));
                const elems = table.get(tty).tuple.fields;
                for (elems, 0..) |fty, i| {
                    if (i >= agg.fields.len) break;
                    try self.writeField(table, addr + tupleFieldOffset(table, tty, @intCast(i)), fty, frame.get(agg.fields[i].index()));
                }
                return .{ .value = addr };
            },
            .tuple_get => |fa| {
                const table = try self.requireTable();
                const tty = try self.aggType(table, fa, ref_types);
                const fty = table.get(tty).tuple.fields[fa.field_index];
                return .{ .value = try self.readField(table, frame.get(fa.base.index()) + tupleFieldOffset(table, tty, fa.field_index), fty) };
            },

            // ── Arrays (contiguous, elem-size stride) ───────────
            .index_get => |b| {
                const table = try self.requireTable();
                const addr = try self.elemAddr(table, (try self.refTy(ref_types, b.lhs)), frame.get(b.lhs.index()), frame.get(b.rhs.index()), table.typeSizeBytes(ins.ty));
                return .{ .value = try self.readField(table, addr, ins.ty) };
            },
            .index_gep => |b| {
                const table = try self.requireTable();
                const elem_ty = pointeeOf(table, ins.ty);
                return .{ .value = try self.elemAddr(table, (try self.refTy(ref_types, b.lhs)), frame.get(b.lhs.index()), frame.get(b.rhs.index()), table.typeSizeBytes(elem_ty)) };
            },
            .length => |u| {
                const table = try self.requireTable();
                const oty = (try self.refTy(ref_types, u.operand));
                if (oty == .string) return .{ .value = try self.sliceLen(frame.get(u.operand.index())) };
                if (!oty.isBuiltin()) {
                    switch (table.get(oty)) {
                        .array => |a| return .{ .value = a.length },
                        .slice => return .{ .value = try self.sliceLen(frame.get(u.operand.index())) },
                        else => {},
                    }
                }
                self.detail = "comptime VM: length() on a non-array/slice/string operand";
                return error.Unsupported;
            },

            // ── Slices + strings ({ptr,len} fat pointers) ───────
            .const_string => |sid| {
                const table = try self.requireTable();
                const text = table.getString(sid);
                const data = self.machine.allocBytes(text.len + 1, 1); // +1: NUL (zero-init)
                if (text.len > 0) @memcpy(try self.machine.bytes(data, text.len), text);
                return .{ .value = try self.makeSlice(table, data, text.len) };
            },
            .data_ptr => |u| {
                const table = try self.requireTable();
                const oty = (try self.refTy(ref_types, u.operand));
                if (oty == .string or (!oty.isBuiltin() and table.get(oty) == .slice))
                    return .{ .value = try self.sliceData(table, frame.get(u.operand.index())) };
                self.detail = "comptime VM: .ptr (data_ptr) on a non-slice/string operand";
                return error.Unsupported;
            },
            .array_to_slice => |u| {
                const table = try self.requireTable();
                var aty = (try self.refTy(ref_types, u.operand));
                if (!aty.isBuiltin() and table.get(aty) == .pointer) aty = table.get(aty).pointer.pointee;
                if (aty.isBuiltin() or table.get(aty) != .array) {
                    self.detail = "comptime VM: array_to_slice on a non-array operand";
                    return error.Unsupported;
                }
                return .{ .value = try self.makeSlice(table, frame.get(u.operand.index()), table.get(aty).array.length) };
            },
            .subslice => |s| {
                const table = try self.requireTable();
                const base = frame.get(s.base.index());
                const lo: u64 = @bitCast(frame.get(s.lo.index()));
                const hi: u64 = @bitCast(frame.get(s.hi.index()));
                const bty = if (s.base_ty != .void) s.base_ty else (try self.refTy(ref_types, s.base));
                var elem: TypeId = .u8;
                var data: Addr = base;
                if (bty == .string) {
                    data = try self.sliceData(table, base);
                } else if (!bty.isBuiltin()) {
                    switch (table.get(bty)) {
                        .array => |a| elem = a.element,
                        // `[*]T` (a List's `items` field) / `*T`: the base IS the
                        // data pointer; subslicing yields `{ base + lo, hi - lo }`.
                        .many_pointer => |mp| elem = mp.element,
                        .pointer => |p| elem = p.pointee,
                        .slice => |sl| {
                            elem = sl.element;
                            data = try self.sliceData(table, base);
                        },
                        else => {
                            self.detail = "comptime VM: subslice on a non-array/slice/string base";
                            return error.Unsupported;
                        },
                    }
                } else {
                    self.detail = "comptime VM: subslice on an unsupported base";
                    return error.Unsupported;
                }
                const esz: u64 = @intCast(table.typeSizeBytes(elem));
                return .{ .value = try self.makeSlice(table, data +% lo *% esz, hi - lo) };
            },
            .str_eq, .str_ne => |b| {
                const table = try self.requireTable();
                const lb = frame.get(b.lhs.index());
                const rb = frame.get(b.rhs.index());
                const ls = try self.machine.bytes(try self.sliceData(table, lb), @intCast(try self.sliceLen(lb)));
                const rs = try self.machine.bytes(try self.sliceData(table, rb), @intCast(try self.sliceLen(rb)));
                const eq = std.mem.eql(u8, ls, rs);
                return .{ .value = @intFromBool(if (std.meta.activeTag(ins.op) == .str_eq) eq else !eq) };
            },

            // ── Optionals ───────────────────────────────────────
            .optional_wrap => |u| {
                const table = try self.requireTable();
                const child = table.get(ins.ty).optional.child; // ins.ty is ?T
                const val = frame.get(u.operand.index());
                if (optChildIsPtr(table, child)) return .{ .value = val }; // pointer optional: the pointer
                const addr = self.machine.allocBytes(table.typeSizeBytes(ins.ty), table.typeAlignBytes(ins.ty));
                try self.writeField(table, addr, child, val); // payload @ 0
                try self.machine.writeWord(addr + table.typeSizeBytes(child), 1, 1); // has_value flag = 1
                return .{ .value = addr };
            },
            .optional_unwrap => |u| {
                const table = try self.requireTable();
                const opt_ty = (try self.refTy(ref_types, u.operand));
                const v = frame.get(u.operand.index());
                if (!try self.optHas(table, opt_ty, v)) {
                    self.detail = "comptime VM: unwrap of a null optional";
                    return error.TypeError;
                }
                const child = table.get(opt_ty).optional.child;
                if (optChildIsPtr(table, child)) return .{ .value = v };
                return .{ .value = try self.readField(table, v, child) };
            },
            .optional_has_value => |u| {
                const table = try self.requireTable();
                return .{ .value = @intFromBool(try self.optHas(table, (try self.refTy(ref_types, u.operand)), frame.get(u.operand.index()))) };
            },
            .optional_coalesce => |b| {
                const table = try self.requireTable();
                const opt_ty = (try self.refTy(ref_types, b.lhs));
                const v = frame.get(b.lhs.index());
                if (try self.optHas(table, opt_ty, v)) {
                    const child = table.get(opt_ty).optional.child;
                    if (optChildIsPtr(table, child)) return .{ .value = v };
                    return .{ .value = try self.readField(table, v, child) };
                }
                return .{ .value = frame.get(b.rhs.index()) };
            },

            // ── Enums (payloadless: the tag is the value) ───────
            .enum_init => |ei| {
                if (ei.payload.isNone()) return .{ .value = @as(Reg, ei.tag) };
                // Tagged union { tag@0, payload@tag_size } — `{ header, [N x i8] }`
                // in the LLVM layout (see backend/llvm/types.zig). Allocate the
                // whole value (zeroed: the payload area is max-payload sized, so a
                // smaller variant leaves the tail zero), write the tag at offset 0,
                // and copy the payload bytes in at `tag_size`.
                const table = try self.requireTable();
                const uty = ins.ty;
                if (uty.isBuiltin() or table.get(uty) != .tagged_union)
                    return self.failMsg("comptime VM: enum_init-with-payload on a non-tagged-union result type not supported");
                const tu = table.get(uty).tagged_union;
                // The simple `{ header(tag)@0, [N x i8] payload@tag_size }` layout
                // assumed below holds ONLY for a tag_type-headed tagged union. A
                // `backing_type` union is laid out as the backing STRUCT (header from
                // all-but-last fields, payload = last field) — different offsets — so
                // bail loudly rather than write the payload to the wrong place.
                if (tu.backing_type != null)
                    return self.failMsg("comptime VM: enum_init on a backing_type tagged union not yet ported (layout differs)");
                const size = table.typeSizeBytes(uty);
                const addr = self.machine.allocBytes(size, table.typeAlignBytes(uty));
                @memset(try self.machine.bytes(addr, size), 0);
                try self.writeField(table, addr, tu.tag_type, @as(Reg, ei.tag));
                const tag_size: Addr = @intCast(table.typeSizeBytes(tu.tag_type));
                const payload_ty = try self.refTy(ref_types, ei.payload);
                try self.writeField(table, addr + tag_size, payload_ty, frame.get(ei.payload.index()));
                return .{ .value = addr };
            },
            .enum_tag => |u| {
                const oty = (try self.refTy(ref_types, u.operand));
                const v = frame.get(u.operand.index());
                if (oty.isBuiltin()) return .{ .value = v }; // already an integer tag
                const table = try self.requireTable();
                if (table.get(oty) == .@"enum") return .{ .value = v }; // payloadless: word IS the tag
                if (table.get(oty) == .tagged_union) {
                    // `{ tag@0, payload@tag_size }` — read the tag word from the
                    // value's address. A `backing_type` union lays the tag out
                    // differently (it's a field of the backing struct), so bail
                    // rather than read the wrong bytes.
                    const tu = table.get(oty).tagged_union;
                    if (tu.backing_type != null) {
                        self.detail = "comptime VM: enum_tag on a backing_type tagged union not yet ported (layout differs)";
                        return error.Unsupported;
                    }
                    return .{ .value = try self.readField(table, v, tu.tag_type) };
                }
                self.detail = "comptime VM: enum_tag on an unexpected operand type";
                return error.Unsupported;
            },
            // Extract a tagged union's active payload — the bytes at `tag_size`,
            // read as the variant's payload type. Mirrors the `enum_init` write
            // layout (`{ tag@0, [N x i8] payload@tag_size }`). The match-arm
            // capture binding (`case .v: (x)`) uses this.
            .enum_payload => |fa| {
                const oty = (try self.refTy(ref_types, fa.base));
                const base = frame.get(fa.base.index());
                const table = try self.requireTable();
                if (oty.isBuiltin() or table.get(oty) != .tagged_union) {
                    self.detail = "comptime VM: enum_payload on a non-tagged-union operand";
                    return error.Unsupported;
                }
                const tu = table.get(oty).tagged_union;
                if (tu.backing_type != null) {
                    self.detail = "comptime VM: enum_payload on a backing_type tagged union not yet ported (layout differs)";
                    return error.Unsupported;
                }
                if (fa.field_index >= tu.fields.len)
                    return self.failMsg("comptime VM: enum_payload variant index out of range");
                const payload_ty = tu.fields[fa.field_index].ty;
                const tag_size: Addr = @intCast(table.typeSizeBytes(tu.tag_type));
                return .{ .value = try self.readField(table, base + tag_size, payload_ty) };
            },

            // `is_comptime()` — always true on the comptime VM (folds to false in
            // compiled code). Mirrors the legacy interp's `.is_comptime => true`.
            .is_comptime => return .{ .value = @as(Reg, 1) },

            // A comptime return-trace frame: pack `(func_id << 32 | span.start)`
            // from the top of the call chain (mirrors the legacy interp). The
            // failable-propagation lowering feeds this to `sx_trace_push`.
            .trace_frame => {
                const fid: u64 = if (self.call_stack.items.len > 0) self.call_stack.items[self.call_stack.items.len - 1].index() else 0;
                return .{ .value = (fid << 32) | @as(u64, ins.span.start) };
            },
            // Dump the comptime call-frame chain (`trace.print_interpreter_frames`) —
            // the VM-native mirror of the legacy `printInterpFrames`. Walks the active
            // `call_stack` (skipping the last frame, the `print_interpreter_frames`
            // fn itself, like the legacy) and writes `  at <name>` lines straight to
            // fd 1 (consistent with `out`'s now-direct libc `write`).
            .interp_print_frames => {
                const module = self.module orelse return self.failMsg("comptime interp_print_frames: no module");
                const n = self.call_stack.items.len;
                if (n <= 1) return .{ .value = null_addr };
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.gpa);
                buf.appendSlice(self.gpa, "comptime call frames (most recent call last):\n") catch return self.failMsg("comptime interp_print_frames: out of memory");
                var i: usize = 0;
                while (i < n - 1) : (i += 1) {
                    const fname = module.types.getString(module.getFunction(self.call_stack.items[i]).name);
                    buf.appendSlice(self.gpa, "  at ") catch return self.failMsg("comptime interp_print_frames: out of memory");
                    buf.appendSlice(self.gpa, fname) catch return self.failMsg("comptime interp_print_frames: out of memory");
                    buf.append(self.gpa, '\n') catch return self.failMsg("comptime interp_print_frames: out of memory");
                }
                _ = std.c.write(1, buf.items.ptr, buf.items.len);
                return .{ .value = null_addr };
            },
            // Unpack a comptime frame `(func_id << 32 | span.start)` and build a
            // `Frame { file, line, col, func, line_text }` aggregate in comptime memory —
            // the VM-native mirror of the legacy interp's `.trace_resolve`. `ins.ty`
            // is the `Frame` struct, so each field's type/offset comes from the table.
            .trace_resolve => |u| {
                const table = try self.requireTable();
                const module = self.module orelse return self.failMsg("comptime trace_resolve: no module");
                const raw = frame.get(u.operand.index());
                const fid: u32 = @intCast(raw >> 32);
                const offset: u32 = @truncate(raw);
                if (fid >= module.functions.items.len) return self.failMsg("comptime trace_resolve: func id out of range");
                const func = module.getFunction(inst_mod.FuncId.fromIndex(fid));
                const func_name = module.types.getString(func.name);
                const file_full = func.source_file orelse "";
                const file = std.fs.path.basename(file_full);
                var line: i64 = 1;
                var col: i64 = 1;
                var line_text: []const u8 = "";
                if (self.source_map) |sm| {
                    if (sm.get(file_full)) |src| {
                        const loc = errors_mod.SourceLoc.compute(src, offset);
                        line = @intCast(loc.line);
                        col = @intCast(loc.col);
                        line_text = errors_mod.lineAt(src, offset);
                    }
                }
                const fty = ins.ty;
                if (fty.isBuiltin() or table.get(fty) != .@"struct")
                    return self.failMsg("comptime trace_resolve: result type is not a Frame struct");
                const sfields = table.get(fty).@"struct".fields;
                if (sfields.len != 5) return self.failMsg("comptime trace_resolve: Frame struct is not 5 fields");
                const addr = self.machine.allocBytes(table.typeSizeBytes(fty), table.typeAlignBytes(fty));
                // { file, line, col, func, line_text } — positional, matching the legacy build.
                try self.writeField(table, addr + fieldOffset(table, fty, 0), sfields[0].ty, try self.makeStringValue(table, file));
                try self.writeField(table, addr + fieldOffset(table, fty, 1), sfields[1].ty, @bitCast(line));
                try self.writeField(table, addr + fieldOffset(table, fty, 2), sfields[2].ty, @bitCast(col));
                try self.writeField(table, addr + fieldOffset(table, fty, 3), sfields[3].ty, try self.makeStringValue(table, func_name));
                try self.writeField(table, addr + fieldOffset(table, fty, 4), sfields[4].ty, try self.makeStringValue(table, line_text));
                return .{ .value = addr };
            },
            // `error_tag_name(e)` — the runtime tag id (a word) → its name string via
            // the always-linked tag-name table. Pure: builds a `{ptr,len}` string in
            // comptime memory. Mirrors the legacy interp's `error_tag_name_get`.
            .error_tag_name_get => |u| {
                const table = try self.requireTable();
                const id: u32 = @intCast(frame.get(u.operand.index()));
                return .{ .value = try self.makeStringValue(table, table.getTagName(id)) };
            },

            // ── Calls ───────────────────────────────────────────
            // Direct call: resolve the static callee `FuncId` and dispatch.
            .call => |c| return .{ .value = try self.invoke(c.callee, c.args, frame, ref_types, ins.ty) },
            // Indirect call: the callee is a `func_ref` value (its `FuncId.index()`
            // as a word) in a register — e.g. an allocator protocol's `alloc_fn`.
            // A null (0) function pointer can't be dispatched → bail.
            .call_indirect => |ci| {
                const w = frame.get(ci.callee.index());
                const fid = funcRefToId(w) orelse {
                    self.detail = "comptime VM: call_indirect through a null function pointer";
                    return error.Unsupported;
                };
                return .{ .value = try self.invoke(fid, ci.args, frame, ref_types, ins.ty) };
            },
            .call_closure => |ci| {
                const module = self.module orelse return self.failMsg("comptime VM: closure call needs a module");
                const table = try self.requireTable();
                const closure_addr = frame.get(ci.callee.index());
                const fid = funcRefToId(try self.machine.readWord(closure_addr, table.pointer_size)) orelse
                    return self.failMsg("comptime VM: closure call through a null function pointer");
                const env = try self.machine.readWord(closure_addr + table.pointer_size, table.pointer_size);
                const callee = module.getFunction(fid);
                const has_ctx = module.has_implicit_ctx;
                const regs = self.gpa.alloc(Reg, ci.args.len + 1) catch @panic("comptime VM: out of memory (closure args)");
                defer self.gpa.free(regs);
                if (has_ctx) {
                    regs[0] = if (ci.args.len > 0) frame.get(ci.args[0].index()) else 0;
                    regs[1] = env;
                    for (ci.args[1..], 0..) |a, i| regs[i + 2] = frame.get(a.index());
                } else {
                    regs[0] = env;
                    for (ci.args, 0..) |a, i| regs[i + 1] = frame.get(a.index());
                }
                self.call_stack.append(self.gpa, fid) catch @panic("comptime VM: out of memory (call stack)");
                defer _ = self.call_stack.pop();
                return .{ .value = try self.run(callee, regs) };
            },

            // ── Globals / function values ───────────────────────
            // Read another comptime global by lazily evaluating its init (its
            // `comptime_func` run on this same VM, or a scalar static value),
            // memoized. Mirrors the legacy interp's `getGlobal`.
            .global_get => |gid| return .{ .value = try self.evalGlobal(gid) },
            // `&global` — only `&__sx_default_context` is materialised at comptime
            // (its address sees runtime use via the implicit-ctx plumbing). Return
            // the context's comptime address — an aggregate value IS its address,
            // so a later `load`/field read sees the materialised Context. Mirrors the
            // legacy interp's `global_addr` (the sole supported global); any other
            // global bails to legacy fallback.
            .global_addr => |gid| {
                const module = self.module orelse return self.failMsg("comptime VM: global_addr needs a module");
                if (gid.index() < module.globals.items.len and
                    std.mem.eql(u8, module.types.getString(module.globals.items[gid.index()].name), "__sx_default_context"))
                {
                    return .{ .value = try self.materializeDefaultContext(module) };
                }
                return self.failMsg("comptime global_addr: only `&__sx_default_context` is materialised at comptime");
            },
            // A function value is its encoded func-ref word (see `funcRefWord`).
            .func_ref => |fid| return .{ .value = funcRefWord(fid) },
            .closure_create => |cc| {
                const table = try self.requireTable();
                const addr = self.machine.allocBytes(table.typeSizeBytes(ins.ty), table.typeAlignBytes(ins.ty));
                try self.machine.writeWord(addr, table.pointer_size, funcRefWord(cc.func));
                const env = if (cc.env == Ref.none) null_addr else frame.get(cc.env.index());
                try self.machine.writeWord(addr + table.pointer_size, table.pointer_size, env);
                return .{ .value = addr };
            },

            // ── Pointers ────────────────────────────────────────
            // `@x` — pass through: an aggregate value already IS its address, and a
            // pointer value is already an address (mirrors the legacy interp).
            .addr_of => |u| return .{ .value = frame.get(u.operand.index()) },
            // `p.*` — read the pointee (like `load`); `ins.ty` is the pointee type.
            .deref => |u| {
                const table = try self.requireTable();
                return .{ .value = try self.readField(table, frame.get(u.operand.index()), ins.ty) };
            },

            // ── Terminators ─────────────────────────────────────
            .br => |b| return .{ .jump = .{ .target = b.target, .args = b.args } },
            .cond_br => |b| {
                if (frame.get(b.cond.index()) != 0) return .{ .jump = .{ .target = b.then_target, .args = b.then_args } };
                return .{ .jump = .{ .target = b.else_target, .args = b.else_args } };
            },
            // Multi-way branch on an integer discriminant: an enum/error tag, or a
            // type-category match where the operand is a `.type_value` whose word IS
            // its `TypeId` index (so the same i64 compare covers both, mirroring the
            // legacy `switch_br`'s `asInt orelse asTypeId().index()`).
            .switch_br => |sb| {
                const operand: i64 = @bitCast(frame.get(sb.operand.index()));
                for (sb.cases) |case| {
                    if (operand == case.value) return .{ .jump = .{ .target = case.target, .args = case.args } };
                }
                return .{ .jump = .{ .target = sb.default, .args = sb.default_args } };
            },
            .ret => |u| return .{ .ret = frame.get(u.operand.index()) },
            .ret_void => return .ret_void,

            // T → any: a 16-byte view `{ data: addr @0, type_id: i64 @8 }` (the
            // borrow representation — the LLVM layout; Odin Raw_Any order,
            // prefix-shared with protocol values). The operand IS the
            // value's comptime ADDRESS (lowering borrows lvalue storage or
            // spills to an alloca); the type_id is the source TypeId index
            // (lowering pre-normalizes arbitrary-width ints).
            .box_any => |ba| {
                const table = try self.requireTable();
                const sz = table.typeSizeBytes(.any); // 16
                const addr = self.machine.allocBytes(sz, table.typeAlignBytes(.any));
                @memset(try self.machine.bytes(addr, sz), 0);
                try self.machine.writeWord(addr, 8, frame.get(ba.operand.index()));
                try self.machine.writeWord(addr + 8, 8, @as(Reg, ba.source_type.index()));
                return .{ .value = addr };
            },
            // any → T: a typed LOAD through the view's data pointer. A word
            // target reads its scalar bytes; an aggregate target's value IS the
            // pointed-at address (VM convention: aggregate value = its address).
            .unbox_any => |ua| {
                const table = try self.requireTable();
                const base = frame.get(ua.operand.index()); // Addr of the {data, type_id} view
                const data = try self.machine.readWord(base, 8);
                switch (kindOf(table, ins.ty)) {
                    .word => return .{ .value = try self.readField(table, data, ins.ty) },
                    .aggregate => return .{ .value = data },
                    .unsupported => return self.failMsg("comptime VM: unbox_any to an unsupported target type"),
                }
            },
            // The view's data pointer itself (no load).
            .any_data => |ua| {
                const base = frame.get(ua.operand.index());
                return .{ .value = try self.machine.readWord(base, 8) };
            },
            // Assemble a view from a runtime tag word + address.
            .make_any => |ma| {
                const table = try self.requireTable();
                const sz = table.typeSizeBytes(.any); // 16
                const addr = self.machine.allocBytes(sz, table.typeAlignBytes(.any));
                try self.machine.writeWord(addr, 8, frame.get(ma.data.index()));
                try self.machine.writeWord(addr + 8, 8, frame.get(ma.tag.index()));
                return .{ .value = addr };
            },

            // Comptime metatype `intrinsic`s (`declare`/`define`). The VM-native
            // mirror of the legacy `execBuiltin` arms; an unmodeled builtin returns
            // null → bail with its name → legacy fallback (dual-path parity).
            .call_builtin => |bi| {
                if (try self.callBuiltinVm(bi, ins.ty, frame, ref_types)) |r| return .{ .value = r };
                self.detail = @tagName(bi.builtin);
                return error.Unsupported;
            },

            // Not yet ported (memory, aggregates, calls, …): bail loudly with the
            // op name — never a silent default.
            else => {
                self.detail = @tagName(ins.op);
                return error.Unsupported;
            },
        }
    }

    /// 64-bit integer (wrapping/signed) or f64 arithmetic, keyed on the result
    /// type — mirrors the legacy `evalArith`.
    fn arith(tag: OpTag, ty: TypeId, l: Reg, r: Reg) Error!Reg {
        if (isFloat(ty)) {
            const lf: f64 = @bitCast(l);
            const rf: f64 = @bitCast(r);
            const res: f64 = switch (tag) {
                .add => lf + rf,
                .sub => lf - rf,
                .mul => lf * rf,
                .div => if (rf == 0.0) return error.DivisionByZero else lf / rf,
                .mod => @mod(lf, rf),
                else => unreachable,
            };
            return @bitCast(res);
        }
        const li: i64 = @bitCast(l);
        const ri: i64 = @bitCast(r);
        const res: i64 = switch (tag) {
            .add => li +% ri,
            .sub => li -% ri,
            .mul => li *% ri,
            .div => if (ri == 0) return error.DivisionByZero else @divTrunc(li, ri),
            .mod => if (ri == 0) return error.DivisionByZero else @mod(li, ri),
            else => unreachable,
        };
        return @bitCast(res);
    }

    /// 64-bit bitwise AND/OR/XOR and shifts — mirrors the legacy interp's i64
    /// model exactly: shifts clamp the amount to `@min(rhs, 63)` and `shr` is an
    /// ARITHMETIC right shift (signed `>>`, sign-extending), matching the legacy
    /// `.int` representation.
    fn bitwise(tag: OpTag, l: Reg, r: Reg) Reg {
        const li: i64 = @bitCast(l);
        const ri: i64 = @bitCast(r);
        const res: i64 = switch (tag) {
            .bit_and => li & ri,
            .bit_or => li | ri,
            .bit_xor => li ^ ri,
            .shl => li << @as(u6, @intCast(@min(ri, 63))),
            .shr => li >> @as(u6, @intCast(@min(ri, 63))),
            else => unreachable,
        };
        return @bitCast(res);
    }

    /// Comparison keyed on the operand type: f64 for floats, == / != only for
    /// bool, else signed i64 — mirrors the legacy `evalCmp`.
    fn cmp(self: *Vm, tag: OpTag, lty: TypeId, l: Reg, r: Reg) Error!bool {
        if (isFloat(lty)) {
            const lf: f64 = @bitCast(l);
            const rf: f64 = @bitCast(r);
            return switch (tag) {
                .cmp_eq => lf == rf,
                .cmp_ne => lf != rf,
                .cmp_lt => lf < rf,
                .cmp_le => lf <= rf,
                .cmp_gt => lf > rf,
                .cmp_ge => lf >= rf,
                else => unreachable,
            };
        }
        if (lty == .bool) {
            const lb = l != 0;
            const rb = r != 0;
            return switch (tag) {
                .cmp_eq => lb == rb,
                .cmp_ne => lb != rb,
                else => {
                    self.detail = "comptime VM: bool comparison supports only == / !=";
                    return error.TypeError;
                },
            };
        }
        const li: i64 = @bitCast(l);
        const ri: i64 = @bitCast(r);
        return switch (tag) {
            .cmp_eq => li == ri,
            .cmp_ne => li != ri,
            .cmp_lt => li < ri,
            .cmp_le => li <= ri,
            .cmp_gt => li > ri,
            .cmp_ge => li >= ri,
            else => unreachable,
        };
    }

    fn requireTable(self: *Vm) Error!*const types.TypeTable {
        return self.table orelse {
            self.detail = "comptime VM: memory/aggregate op needs a type table (not provided)";
            return error.Unsupported;
        };
    }

    fn failMsg(self: *Vm, msg: []const u8) error{Unsupported} {
        self.detail = msg;
        return error.Unsupported;
    }

    /// Like `failMsg` but for a runtime-formatted reason (e.g. naming the offending
    /// variant). Allocated in `gpa` so it survives to the host's diagnostic render;
    /// the build fails on this path, so the small leak is moot.
    fn failFmt(self: *Vm, comptime fmt: []const u8, args: anytype) error{Unsupported} {
        self.detail = std.fmt.allocPrint(self.gpa, fmt, args) catch "comptime VM: out of memory formatting diagnostic";
        return error.Unsupported;
    }

    fn badRef(self: *Vm) error{Unsupported} {
        self.detail = "comptime VM: malformed IR — operand ref out of range (unresolved name?)";
        return error.Unsupported;
    }

    /// The IR type of operand `r`, bounds-checked. Lowering-time IR can carry an
    /// out-of-range / `Ref.none` operand (an unresolved name lowers to a dangling
    /// ref); reading `ref_types` raw would panic, so bail instead — the host then
    /// falls back to the legacy interpreter. The companion to `Frame.get`'s
    /// `bad_ref` guard (which covers the value side; this covers the type side).
    fn refTy(self: *Vm, ref_types: []const TypeId, r: Ref) Error!TypeId {
        if (r.index() >= ref_types.len) return self.badRef();
        return ref_types[r.index()];
    }

    /// Dispatch a call to function `fid` with `args` (Refs in the current frame),
    /// shared by `call` (static callee) and `call_indirect` (func-ref callee). An
    /// extern/bodyless callee routes to the native libc memory builtins (else
    /// bails); a normal callee runs on the VM. Aggregate args pass as their Addr
    /// over the shared comptime memory (no copy).
    fn invoke(self: *Vm, fid: inst_mod.FuncId, args: []const Ref, frame: *Frame, ref_types: []const TypeId, result_ty: TypeId) Error!Reg {
        const module = self.module orelse return self.failMsg("comptime VM: call needs a module (not provided)");
        if (fid.index() >= module.functions.items.len) return self.failMsg("comptime VM: call to an out-of-range function id");
        const callee = module.getFunction(fid);
        if (callee.is_extern or callee.blocks.items.len == 0) {
            const name = module.types.getString(callee.name);
            // A curated set of libc MEMORY builtins is modeled natively on comptime
            // memory (sandboxed, target-aware) — comptime malloc/free/memcpy/…
            // never reach the host heap or dlsym.
            if (try self.callMemBuiltin(name, args, frame)) |r| return r;
            // An `evaluate`-mode intrinsic: the comptime compiler-API, serviced
            // natively on comptime memory. The REGISTRY is the safety boundary —
            // dispatch only for a name it carries, and only for an entry whose mode
            // says the VM owns it. A `lower`/`dual` intrinsic reaching here would
            // be a lowering bug, so it falls through to the extern path and fails
            // loudly rather than being serviced by the wrong handler.
            if (callee.is_intrinsic) {
                if (intrinsics.findByName(name)) |id| {
                    if (intrinsics.byId(id).mode == .evaluate) {
                        if (try self.callCompilerFn(id, name, args, frame, ref_types, result_ty)) |r| return r;
                    }
                }
            }
            // General host-FFI escape: any other extern resolves via dlsym and is
            // dispatched through the host_ffi trampolines. Because `Addr` is a real
            // host pointer, args pass as `usize` untouched (a scalar's bits OR a
            // pointer) and a pointer return comes back as a valid `Addr` — no
            // translation. Aggregate/float args+returns aren't marshaled yet (4D.2).
            return self.callHostExtern(callee, name, args, frame, ref_types);
        }
        const argbuf = self.gpa.alloc(Reg, args.len) catch @panic("comptime VM: out of memory (call args)");
        defer self.gpa.free(argbuf);
        for (args, 0..) |a, i| argbuf[i] = frame.get(a.index());
        self.call_stack.append(self.gpa, fid) catch @panic("comptime VM: out of memory (call stack)");
        defer _ = self.call_stack.pop();
        return self.run(callee, argbuf);
    }

    /// Call a real extern (libc / host) function via dlsym + the `host_ffi`
    /// trampolines — the comptime VM's host-FFI escape (the legacy `interp.callExtern`
    /// equivalent). Marshalling is trivial here because `Addr` is already a host
    /// pointer: every WORD-kind arg (scalar OR pointer) passes as `usize` verbatim,
    /// and a pointer return is a valid `Addr`. Non-word (aggregate/string/float)
    /// args+returns bail loudly (4D.2 adds them) — never a silent miscall.
    fn callHostExtern(self: *Vm, callee: *const Function, name: []const u8, args: []const Ref, frame: *Frame, ref_types: []const TypeId) Error!Reg {
        const table = try self.requireTable();
        if (args.len > 8) return self.failMsg("comptime extern call: more than 8 args (host_ffi trampolines max out at 8)");
        const symbol = (host_ffi.lookupSymbol(self.gpa, name) catch return self.failMsg("comptime extern call: dlsym error looking up symbol")) orelse
            return self.failMsg("comptime extern call: symbol not found via dlsym (target-specific binding called at compile time?)");

        var packed_args: [8]usize = undefined;
        for (args, 0..) |a, i| {
            packed_args[i] = try self.marshalExternArg(table, try self.refTy(ref_types, a), frame.get(a.index()));
        }
        const argv = packed_args[0..args.len];
        const fixed = callee.params.len;
        const variadic = callee.is_variadic and args.len > fixed;
        const ret = callee.ret;

        if (isFloat(ret))
            return self.failMsg("comptime extern call: float return not supported (host_ffi has no float trampoline)");
        if (ret == .void or ret == .noreturn) {
            if (variadic)
                host_ffi.callVoidRetVar(symbol, fixed, argv) catch return self.failMsg("comptime extern call failed (void)")
            else
                host_ffi.callVoidRet(symbol, argv) catch return self.failMsg("comptime extern call failed (void)");
            return @as(Reg, 0);
        }
        // The C function returns a single register word. For a plain word return
        // that word IS the result. For an OPTIONAL whose child is itself a single
        // word (e.g. `getenv() -> ?cstring`, a `char*` the sx side treats as a
        // nullable handle), the C returns the bare payload and we wrap it into the
        // `{payload@0, has@sizeof(child)}` aggregate below (present iff non-null) —
        // mirroring emit_llvm's wrapping of an extern `char*`→`?cstring` return.
        const opt_child: ?TypeId = if (!ret.isBuiltin() and table.get(ret) == .optional) blk: {
            const ch = table.get(ret).optional.child;
            // An optional with a SENTINEL (pointer) child is itself a word and is
            // handled by the plain-word path; only the `{payload, has}` aggregate
            // form (kindOf == .aggregate) needs wrapping here.
            break :blk if (kindOf(table, ret) == .aggregate and kindOf(table, ch) == .word and !isFloat(ch)) ch else null;
        } else null;
        const word_ty: TypeId = opt_child orelse ret;
        if (kindOf(table, word_ty) != .word or isFloat(word_ty))
            return self.failFmt("comptime extern call '{s}': non-word (aggregate/string/float) return ({s}) not yet supported on the VM", .{ name, table.typeName(ret) });
        // A pointer-ish return goes through callPtrRet (void* ABI); an integer-ish
        // return through callIntRet (i64 ABI). Either way the result is a single
        // word — a returned pointer is already a valid absolute `Addr`.
        const r: u64 = if (isPointerish(table, word_ty)) blk: {
            break :blk if (variadic)
                host_ffi.callPtrRetVar(symbol, fixed, argv) catch return self.failMsg("comptime extern call failed (ptr)")
            else
                host_ffi.callPtrRet(symbol, argv) catch return self.failMsg("comptime extern call failed (ptr)");
        } else blk: {
            const v = if (variadic)
                host_ffi.callIntRetVar(symbol, fixed, argv) catch return self.failMsg("comptime extern call failed (int)")
            else
                host_ffi.callIntRet(symbol, argv) catch return self.failMsg("comptime extern call failed (int)");
            break :blk @bitCast(v);
        };
        if (opt_child) |child| {
            // Wrap the bare payload word into the `{payload, has}` optional aggregate.
            const addr = self.machine.allocBytes(table.typeSizeBytes(ret), table.typeAlignBytes(ret));
            try self.writeField(table, addr, child, r);
            try self.machine.writeWord(addr + table.typeSizeBytes(child), 1, @intFromBool(r != 0));
            return @as(Reg, addr);
        }
        return @as(Reg, r);
    }

    /// Marshal one extern arg (of IR type `aty`, register value `reg`) to the `usize`
    /// the host_ffi trampolines expect. A scalar/pointer WORD passes verbatim (a
    /// pointer Reg is already a host pointer). A string/slice fat-pointer is copied
    /// into a NUL-terminated buffer and its `char*` passed (mirrors the legacy
    /// `marshalExternArg`). Floats (no float trampoline) and non-fat-pointer
    /// aggregates bail loudly — never a silent miscall.
    fn marshalExternArg(self: *Vm, table: *const types.TypeTable, aty: TypeId, reg: Reg) Error!usize {
        switch (kindOf(table, aty)) {
            .word => {
                if (isFloat(aty))
                    return self.failMsg("comptime extern call: float arg not supported (host_ffi has no float trampoline)");
                return @intCast(reg); // scalar bits OR host pointer
            },
            .aggregate => {
                // Only a string/slice `{ptr, len}` fat pointer marshals (→ a
                // NUL-terminated `char*`); any other aggregate bails.
                if (aty != .string and (aty.isBuiltin() or table.get(aty) != .slice))
                    return self.failMsg("comptime extern call: non-string/slice aggregate arg not marshaled on the VM");
                const n: usize = @intCast(try self.sliceLen(reg));
                const data = try self.sliceData(table, reg);
                const buf = self.machine.allocBytes(n + 1, 1); // zeroed → NUL at [n]
                if (n > 0) @memcpy(try self.machine.bytes(buf, n), try self.machine.bytes(data, n));
                return @intCast(buf);
            },
            .unsupported => return self.failMsg("comptime extern call: unsupported arg type"),
        }
    }

    /// Largest single comptime allocation the VM will service natively. A bogus /
    /// pathological comptime `malloc` above this bails to the legacy path (which
    /// calls real libc) rather than OOM-panicking the compiler via `allocBytes`.
    const max_builtin_alloc: usize = 1 << 28; // 256 MiB

    /// Read call arg `i` as a non-negative byte count (libc size/length arg).
    fn argLen(self: *Vm, args: []const Ref, frame: *Frame, i: usize) Error!usize {
        const w: i64 = @bitCast(frame.get(args[i].index()));
        return std.math.cast(usize, w) orelse self.failMsg("comptime mem builtin: negative/oversized size arg");
    }

    /// Model a curated set of libc MEMORY builtins directly on comptime memory, so a
    /// comptime `malloc`/`free`/`memcpy`/… stays sandboxed (no host heap, no
    /// dlsym) and target-aware. Returns the result word, or `null` if `name` is
    /// not one of them (the caller then bails to the legacy interpreter). libc
    /// `malloc` returns 16-byte-aligned storage; we mirror that. The COMPUTED
    /// result is byte-identical to the legacy path (which calls real libc) — only
    /// the backing memory differs (comptime arena vs host heap), which the result can't see.
    fn callMemBuiltin(self: *Vm, name: []const u8, args: []const Ref, frame: *Frame) Error!?Reg {
        // Error return-trace runtime (sx_trace.c, linked into the compiler). A
        // comptime failable that raises emits `sx_trace_push(trace_frame())` as it
        // unwinds; service it natively so the trace buffer the host reads is
        // populated identically to the legacy interp's dlsym path.
        if (std.mem.eql(u8, name, "sx_trace_push")) {
            if (args.len >= 1) sx_trace_push(frame.get(args[0].index()));
            return @as(Reg, 0);
        }
        if (std.mem.eql(u8, name, "sx_trace_clear")) {
            sx_trace_clear();
            return @as(Reg, 0);
        }
        if (std.mem.eql(u8, name, "malloc")) {
            if (args.len < 1) return self.failMsg("comptime malloc: missing size arg");
            const size = try self.argLen(args, frame, 0);
            if (size > max_builtin_alloc) return self.failMsg("comptime malloc: size exceeds the VM cap");
            return self.machine.allocBytes(size, 16);
        }
        if (std.mem.eql(u8, name, "calloc")) {
            if (args.len < 2) return self.failMsg("comptime calloc: missing args");
            const n = try self.argLen(args, frame, 0);
            const sz = try self.argLen(args, frame, 1);
            const total = std.math.mul(usize, n, sz) catch return self.failMsg("comptime calloc: size overflow");
            if (total > max_builtin_alloc) return self.failMsg("comptime calloc: size exceeds the VM cap");
            return self.machine.allocBytes(total, 16); // allocBytes zero-inits
        }
        if (std.mem.eql(u8, name, "free")) {
            // No per-object free: comptime allocations live to `Vm.deinit`.
            return @as(Reg, 0);
        }
        if (std.mem.eql(u8, name, "memcpy") or std.mem.eql(u8, name, "memmove")) {
            if (args.len < 3) return self.failMsg("comptime memcpy: missing args");
            const dst = frame.get(args[0].index());
            const src = frame.get(args[1].index());
            const n = try self.argLen(args, frame, 2);
            if (n > 0) {
                const d = try self.machine.bytes(dst, n);
                const s = try self.machine.bytes(src, n);
                // Overlap-safe (memmove semantics; correct for memcpy's too).
                if (dst < src) std.mem.copyForwards(u8, d, s) else std.mem.copyBackwards(u8, d, s);
            }
            return dst; // libc returns dst
        }
        if (std.mem.eql(u8, name, "memset")) {
            if (args.len < 3) return self.failMsg("comptime memset: missing args");
            const dst = frame.get(args[0].index());
            const byte: u8 = @truncate(frame.get(args[1].index()));
            const n = try self.argLen(args, frame, 2);
            if (n > 0) @memset(try self.machine.bytes(dst, n), byte);
            return dst; // libc returns dst
        }
        return null; // not a modeled builtin → caller bails to legacy
    }

    /// Service a welded `compiler`-library function natively on comptime memory — the
    /// comptime compiler-API (Phase 3 of `PLAN-COMPILER-VM.md`). Returns the result
    /// word, or `null` for an unknown name (caller bails → legacy). Mirrors the
    /// legacy `compiler_lib` handlers, but reads/writes comptime memory directly instead
    /// of marshaling `Value`s. The seed pair is the string-pool round-trip:
    ///   `intern(s: string) -> StringId` and `text_of(id: StringId) -> string`.
    /// Read compiler-call arg `i` as a u32 handle (a `StringId` / `TypeId` word),
    /// range-checked — never a silent truncation.
    fn argHandle(self: *Vm, args: []const Ref, frame: *Frame, i: usize) Error!u32 {
        const raw = frame.get(args[i].index());
        if (raw > std.math.maxInt(u32)) return self.failMsg("comptime compiler call: handle arg out of u32 range");
        return @intCast(raw);
    }

    /// Read compiler-call arg `i` as a `TypeId` handle.
    fn argTypeId(self: *Vm, args: []const Ref, frame: *Frame, i: usize) Error!TypeId {
        return @enumFromInt(try self.argHandle(args, frame, i));
    }

    /// Service an `evaluate`-mode intrinsic. Dispatch is keyed by the registry `id`;
/// `name` is carried only for diagnostics. The caller has already checked the
/// mode, so an id that is not evaluate-only cannot arrive here.
fn callCompilerFn(self: *Vm, intr: intrinsics.Id, name: []const u8, args: []const Ref, frame: *Frame, ref_types: []const TypeId, result_ty: TypeId) Error!?Reg {
        const table = try self.requireTable();
        if (intr == .raw_intern) {
            if (args.len != 1) return self.failMsg("comptime intern: expected one string arg");
            const s = frame.get(args[0].index()); // string fat-pointer Addr
            const text = try self.machine.bytes(try self.sliceData(table, s), @intCast(try self.sliceLen(s)));
            // The string pool is genuinely mutable; the VM holds the table `const`
            // (it never mutates TYPE layout — interning a string is pool-only, so it
            // can't invalidate the cached type sizes the VM relies on). Same access
            // the legacy `compiler_lib.mintTable` uses.
            const id = @constCast(table).internString(text);
            return @as(Reg, @intFromEnum(id));
        }
        if (intr == .raw_text_of) {
            if (args.len != 1) return self.failMsg("comptime text_of: expected one StringId arg");
            const raw = frame.get(args[0].index());
            if (raw > std.math.maxInt(u32)) return self.failMsg("comptime text_of: StringId out of range");
            const id: types.StringId = @enumFromInt(@as(u32, @intCast(raw)));
            return try self.makeStringValue(table, table.getString(id));
        }
        // ── read-only reflection readers (Phase 3) ──────────────────────────
        // Type handle = a u32 `TypeId` (a word), exactly like `StringId` — so
        // these mirror intern/text_of's shape: word in, word out, no marshaling.
        if (intr == .raw_find_type) {
            if (args.len != 1) return self.failMsg("comptime find_type: expected one StringId arg");
            const sid: types.StringId = @enumFromInt(try self.argHandle(args, frame, 0));
            // Not found → the dedicated `unresolved` (0) sentinel, never a real
            // type id (mirrors `compiler_lib.handleFindType`).
            const tid = table.findByName(sid) orelse TypeId.unresolved;
            return @as(Reg, tid.index());
        }
        if (intr == .raw_field_count) {
            if (args.len != 1) return self.failMsg("comptime type_field_count: expected one TypeId arg");
            const tid = try self.argTypeId(args, frame, 0);
            // Same `TypeTable.memberCount` the legacy handler reads → no drift; a
            // type with no member count bails loudly (no silent 0).
            const count = table.memberCount(tid) orelse
                return self.failMsg("comptime type_field_count: type has no field/variant count");
            return @as(Reg, @bitCast(count));
        }
        if (intr == .raw_type_name) {
            if (args.len != 1) return self.failMsg("comptime type_nominal_name: expected one TypeId arg");
            const tid = try self.argTypeId(args, frame, 0);
            const sid = table.nominalName(tid) orelse
                return self.failMsg("comptime type_nominal_name: type has no nominal name");
            return @as(Reg, @intFromEnum(sid));
        }
        if (intr == .raw_field_name) {
            if (args.len != 2) return self.failMsg("comptime type_field_name: expected (TypeId, idx)");
            const tid = try self.argTypeId(args, frame, 0);
            const idx: i64 = @bitCast(frame.get(args[1].index()));
            const sid = table.memberName(tid, idx) orelse
                return self.failMsg("comptime type_field_name: out-of-range idx or unnamed member");
            return @as(Reg, @intFromEnum(sid));
        }
        if (intr == .raw_field_type) {
            if (args.len != 2) return self.failMsg("comptime type_field_type: expected (TypeId, idx)");
            const tid = try self.argTypeId(args, frame, 0);
            const idx: i64 = @bitCast(frame.get(args[1].index()));
            const mty = table.memberType(tid, idx) orelse
                return self.failMsg("comptime type_field_type: out-of-range idx or member has no type");
            return @as(Reg, mty.index());
        }
        if (intr == .raw_type_kind) {
            if (args.len != 1) return self.failMsg("comptime type_kind: expected one TypeId arg");
            const tid = try self.argTypeId(args, frame, 0);
            return @as(Reg, @bitCast(table.kindCode(tid))); // total — never bails
        }
        if (intr == .raw_variant_value) {
            if (args.len != 2) return self.failMsg("comptime type_field_value: expected (TypeId, idx)");
            const tid = try self.argTypeId(args, frame, 0);
            const idx: i64 = @bitCast(frame.get(args[1].index()));
            const v = table.memberValue(tid, idx) orelse
                return self.failMsg("comptime type_field_value: non-enum or out-of-range idx");
            return @as(Reg, @bitCast(v));
        }
        // ── write side (lowering-time, mints into the type table) ───────────
        // These MINT into the type table via `@constCast(table)` — the same
        // mutable access the read-side `intern` uses (the table is genuinely
        // mutable; the VM merely holds it `const`). They take/return real `Type`
        // values (`.type_value` words = `TypeId.index()`). Mirror the legacy
        // `compiler_lib` handlers exactly so the dual paths can't drift.
        if (intr == .raw_declare_type) {
            if (args.len != 1) return self.failMsg("comptime declare_type: expected (name)");
            const s = frame.get(args[0].index()); // string fat-pointer Addr
            const text = try self.machine.bytes(try self.sliceData(table, s), @intCast(try self.sliceLen(s)));
            return @as(Reg, (self.declareNominal(table, text)).index());
        }
        if (intr == .raw_pointer_to) {
            if (args.len != 1) return self.failMsg("comptime pointer_to: expected (Type)");
            const t = try self.argTypeId(args, frame, 0);
            return @as(Reg, @constCast(table).intern(.{ .pointer = .{ .pointee = t } }).index());
        }
        if (intr == .raw_register_type) {
            return self.registerTypeVm(args, frame, ref_types);
        }
        // ── BuildOptions ───────────────────────────────────────────────────
        // `build_options()` hands back an opaque, zero-field `BuildOptions` handle;
        // the real state lives on the threaded `BuildConfig`. Return the null
        // sentinel word (the handle is never dereferenced — every operation takes it
        // as an ignored `self`). Mirrors the legacy `hookBuildOptions` (`.void_val`).
        if (intr == .build_options) {
            return @as(Reg, null_addr);
        }
        // `on_build(cb)` — register the build callback (the Phase 5 form, `cb:
        // (opt: BuildOptions) -> bool`). Like `set_post_link_callback` but a free
        // fn (cb is arg 0, no self) and the callback receives the `BuildOptions`
        // handle when invoked (the `post_link_takes_options` flag drives that).
        if (intr == .on_build) {
            if (args.len != 1) return self.failMsg("comptime on_build: expected (cb)");
            const bc = self.build_config orelse
                return self.failMsg("comptime on_build: no build config threaded into the VM");
            const fid = funcRefToId(frame.get(args[0].index())) orelse
                return self.failMsg("comptime on_build: cb arg is not a function value");
            bc.post_link_callback_fn = fid;
            bc.post_link_takes_options = true;
            return @as(Reg, null_addr);
        }
        // ── build-pipeline metadata queries (Phase 5.2) ─────────────────────
        // Read-only: the compiler answers them from the `BuildConfig` `main.zig`
        // forwards before the post-link callback runs. Each builds a fresh
        // `List(string)` in comptime memory (the result type drives its layout) — no
        // driver action, so they're pure data even in the sx-driven end state.
        if (intr == .c_object_paths) {
            if (args.len != 0) return self.failMsg("comptime c_object_paths: expected no args");
            const bc = self.build_config orelse
                return self.failMsg("comptime c_object_paths: no build config threaded into the VM");
            return try self.makeStringList(table, result_ty, bc.c_object_paths);
        }
        if (intr == .link_libraries) {
            if (args.len != 0) return self.failMsg("comptime link_libraries: expected no args");
            const bc = self.build_config orelse
                return self.failMsg("comptime link_libraries: no build config threaded into the VM");
            return try self.makeStringList(table, result_ty, bc.link_libraries);
        }
        // `emit_object() -> string` — ACTION: verify + emit the codegen'd module
        // to its object file and return the path. Dispatches through the
        // host-installed hook (the VM can't emit itself); the driver no longer
        // auto-emits (everything is sx-driven via `default_pipeline`).
        if (intr == .emit_object) {
            if (args.len != 0) return self.failMsg("comptime emit_object: expected no args");
            const bc = self.build_config orelse
                return self.failMsg("comptime emit_object: no build config threaded into the VM");
            const hooks = bc.build_hooks orelse
                return self.failMsg("comptime emit_object: no build hooks installed (emit is a post-codegen-only action)");
            const path = hooks.emit_object(hooks.ctx) catch
                return self.failMsg("comptime emit_object: object emission failed");
            return try self.makeStringValue(table, path);
        }
        // Build-config metadata the sx driver passes to `link`. Read-only data
        // forwarded by `main.zig` (the merged CLI + `#run` build config).
        if (intr == .build_output) {
            if (args.len != 0) return self.failMsg("comptime build_output: expected no args");
            const bc = self.build_config orelse return self.failMsg("comptime build_output: no build config");
            return try self.makeStringValue(table, bc.output_path orelse "");
        }
        if (intr == .build_target) {
            if (args.len != 0) return self.failMsg("comptime build_target: expected no args");
            const bc = self.build_config orelse return self.failMsg("comptime build_target: no build config");
            return try self.makeStringValue(table, bc.target_triple orelse "");
        }
        if (intr == .build_frameworks) {
            if (args.len != 0) return self.failMsg("comptime build_frameworks: expected no args");
            const bc = self.build_config orelse return self.failMsg("comptime build_frameworks: no build config");
            return try self.makeStringList(table, result_ty, bc.target_frameworks);
        }
        if (intr == .build_flags) {
            if (args.len != 0) return self.failMsg("comptime build_flags: expected no args");
            const bc = self.build_config orelse return self.failMsg("comptime build_flags: no build config");
            return try self.makeStringList(table, result_ty, bc.merged_link_flags);
        }
        // `link(objects, output, libraries, frameworks, flags, target)` — the one
        // genuine ACTION: dispatch to the host-installed linker (the VM can't link
        // itself). Void return (the build callback isn't fallible — Phase 5
        // decision); a link failure bails loudly → hard build error. `ref_types`
        // gives each List(string) arg its concrete type for the comptime reader.
        if (intr == .link) {
            if (args.len != 6) return self.failMsg("comptime link: expected (objects, output, libraries, frameworks, flags, target)");
            const bc = self.build_config orelse
                return self.failMsg("comptime link: no build config threaded into the VM");
            const hooks = bc.build_hooks orelse
                return self.failMsg("comptime link: no build hooks installed (link is a post-codegen-only action)");
            const objects = try self.readStringList(table, ref_types[args[0].index()], frame.get(args[0].index()));
            const output = try self.readStringArg(table, frame.get(args[1].index()));
            const libraries = try self.readStringList(table, ref_types[args[2].index()], frame.get(args[2].index()));
            const frameworks = try self.readStringList(table, ref_types[args[3].index()], frame.get(args[3].index()));
            const flags = try self.readStringList(table, ref_types[args[4].index()], frame.get(args[4].index()));
            const target_str = try self.readStringArg(table, frame.get(args[5].index()));
            hooks.link(hooks.ctx, objects, output, libraries, frameworks, flags, target_str) catch
                return self.failMsg("comptime link: linking failed");
            return @as(Reg, null_addr); // void
        }
        // ── BuildOptions accessors (Phase 5.5) ──────────────────────────────
        // Migrated off `struct #compiler` hooks onto VM-native arms. `self` (the
        // opaque BuildOptions handle) is args[0] and ignored; the real state lives
        // on the threaded `BuildConfig`. SETTERS dupe the string arg into the
        // PERSISTENT `self.gpa` (the Compilation allocator — NOT the per-eval VM
        // arena, whose bytes die at `Vm.deinit`) so it survives to post-link.
        if (try self.callBuildOptionFn(name, args, frame)) |r| return r;
        // The caller only routes here for a registry entry whose mode is
        // `evaluate`, so reaching this point means a registered intrinsic has no
        // VM handler. Returning null would drop it to the dlsym path, where it
        // would either fail as an undefined symbol or — worse — bind to an
        // unrelated host symbol of the same name. Name it and stop.
        self.detail = name;
        return self.failMsg("evaluate-mode intrinsic has no VM handler");
    }

    /// Read string arg `idx` (a `{ptr,len}` fat pointer) and DUPE it into the
    /// persistent `self.gpa`. The VM-arena view dies at `Vm.deinit`, so a
    /// BuildConfig string set at `#run` must own a persistent copy.
    fn dupeArgStr(self: *Vm, args: []const Ref, frame: *Frame, idx: usize) Error![]const u8 {
        const table = try self.requireTable();
        const view = try self.readStringArg(table, frame.get(args[idx].index()));
        return self.gpa.dupe(u8, view) catch return self.failMsg("comptime BuildOptions setter: out of memory");
    }

    /// VM-native `BuildOptions` accessors (Phase 5.5). Returns null when `name` is
    /// not a BuildOptions accessor (the caller then yields null → "unknown").
    fn callBuildOptionFn(self: *Vm, name: []const u8, args: []const Ref, frame: *Frame) Error!?Reg {
        const table = try self.requireTable();
        // A getter/setter on a string field: `name` → the `?[]const u8` field. A
        // setter (one extra arg) writes a persistent dupe; a getter returns the
        // value (or "" when unset). Both ignore the `self` handle at args[0].
        const StrField = struct { set: []const u8, get: []const u8, field: *?[]const u8 };
        // A BuildOptions accessor is only ever reached from a `#run` / post-link
        // eval, which always threads a `BuildConfig`. A null `bc` here means this
        // isn't a BuildOptions call at all (e.g. a lowering-time type-fn) — yield
        // null so the caller treats it as unknown (it then bails loudly).
        const bc = self.build_config orelse return null;
        const str_fields = [_]StrField{
            .{ .set = "set_output_path", .get = "", .field = &bc.output_path },
            .{ .set = "set_wasm_shell", .get = "", .field = &bc.wasm_shell_path },
            .{ .set = "set_post_link_module", .get = "", .field = &bc.post_link_module },
            .{ .set = "set_bundle_path", .get = "bundle_path", .field = &bc.bundle_path },
            .{ .set = "set_bundle_id", .get = "bundle_id", .field = &bc.bundle_id },
            .{ .set = "set_codesign_identity", .get = "codesign_identity", .field = &bc.codesign_identity },
            .{ .set = "set_provisioning_profile", .get = "provisioning_profile", .field = &bc.provisioning_profile },
            .{ .set = "set_manifest_path", .get = "manifest_path", .field = &bc.manifest_path },
            .{ .set = "set_keystore_path", .get = "keystore_path", .field = &bc.keystore_path },
            .{ .set = "_", .get = "binary_path", .field = &bc.binary_path },
            .{ .set = "_", .get = "target_triple", .field = &bc.target_triple },
        };
        for (str_fields) |sf| {
            if (sf.set.len > 1 and std.mem.eql(u8, name, sf.set)) {
                if (args.len != 2) return self.failMsg("comptime BuildOptions setter: expected (self, value)");
                sf.field.* = try self.dupeArgStr(args, frame, 1);
                return @as(Reg, null_addr);
            }
            if (sf.get.len > 0 and std.mem.eql(u8, name, sf.get)) {
                if (args.len != 1) return self.failMsg("comptime BuildOptions getter: expected (self)");
                return try self.makeStringValue(table, sf.field.* orelse "");
            }
        }
        // List-appending setters (dupe + append into the persistent gpa).
        if (std.mem.eql(u8, name, "add_link_flag")) {
            if (args.len != 2) return self.failMsg("comptime add_link_flag: expected (self, flag)");
            bc.link_flags.append(self.gpa, try self.dupeArgStr(args, frame, 1)) catch
                return self.failMsg("comptime add_link_flag: out of memory");
            return @as(Reg, null_addr);
        }
        if (std.mem.eql(u8, name, "add_framework")) {
            if (args.len != 2) return self.failMsg("comptime add_framework: expected (self, name)");
            bc.frameworks.append(self.gpa, try self.dupeArgStr(args, frame, 1)) catch
                return self.failMsg("comptime add_framework: out of memory");
            return @as(Reg, null_addr);
        }
        if (std.mem.eql(u8, name, "add_asset_dir")) {
            if (args.len != 3) return self.failMsg("comptime add_asset_dir: expected (self, src, dest)");
            const src = try self.dupeArgStr(args, frame, 1);
            const dest = try self.dupeArgStr(args, frame, 2);
            bc.asset_dirs.append(self.gpa, .{ .src = src, .dest = dest }) catch
                return self.failMsg("comptime add_asset_dir: out of memory");
            return @as(Reg, null_addr);
        }
        // Count getters (i64).
        if (std.mem.eql(u8, name, "asset_dir_count"))
            return @as(Reg, @bitCast(@as(i64, @intCast(bc.asset_dirs.items.len))));
        if (std.mem.eql(u8, name, "framework_count"))
            return @as(Reg, @bitCast(@as(i64, @intCast(bc.target_frameworks.len))));
        if (std.mem.eql(u8, name, "framework_path_count"))
            return @as(Reg, @bitCast(@as(i64, @intCast(bc.target_framework_paths.len))));
        if (std.mem.eql(u8, name, "jni_main_count"))
            return @as(Reg, @bitCast(@as(i64, @intCast(bc.jni_main_runtime_paths.len))));
        // Indexed string getters (out-of-range → "", mirroring the legacy hooks).
        // Asset dirs are `{src,dest}` structs, so read the field directly.
        if (std.mem.eql(u8, name, "asset_dir_src_at") or std.mem.eql(u8, name, "asset_dir_dest_at")) {
            if (args.len != 2) return self.failMsg("comptime asset_dir getter: expected (self, i)");
            const idx: i64 = @bitCast(frame.get(args[1].index()));
            if (idx < 0 or @as(usize, @intCast(idx)) >= bc.asset_dirs.items.len)
                return try self.makeStringValue(table, "");
            const ad = bc.asset_dirs.items[@intCast(idx)];
            return try self.makeStringValue(table, if (name[10] == 's') ad.src else ad.dest);
        }
        if (std.mem.eql(u8, name, "framework_at"))
            return try self.indexedStr(args, frame, bc.target_frameworks);
        if (std.mem.eql(u8, name, "framework_path_at"))
            return try self.indexedStr(args, frame, bc.target_framework_paths);
        if (std.mem.eql(u8, name, "jni_main_runtime_path_at"))
            return try self.indexedStr(args, frame, bc.jni_main_runtime_paths);
        if (std.mem.eql(u8, name, "jni_main_java_source_at"))
            return try self.indexedStr(args, frame, bc.jni_main_java_sources);
        // Target predicates (computed from the triple — mirror the legacy hooks).
        if (boolPredicate(name)) |pred| {
            if (args.len != 1) return self.failMsg("comptime BuildOptions predicate: expected (self)");
            return @as(Reg, if (pred(bc.target_triple)) 1 else 0);
        }
        return null; // not a BuildOptions accessor
    }

    /// Read index arg 1, bounds-check against `items`, and return the element
    /// string (or "" when out of range — mirrors the legacy hook behavior).
    fn indexedStr(self: *Vm, args: []const Ref, frame: *Frame, items: []const []const u8) Error!Reg {
        const table = try self.requireTable();
        if (args.len != 2) return self.failMsg("comptime BuildOptions indexed getter: expected (self, i)");
        const idx: i64 = @bitCast(frame.get(args[1].index()));
        if (idx < 0 or @as(usize, @intCast(idx)) >= items.len)
            return try self.makeStringValue(table, "");
        return try self.makeStringValue(table, items[@intCast(idx)]);
    }

    /// VM-native `register_type(handle: Type, kind: i64, members: []Member) -> Type`
    /// — fill a `declare_type`'d forward slot, branching on `kind` in the compiler
    /// (mirrors `compiler_lib.handleRegisterType`, but reads `[]Member` from comptime
    /// memory instead of decoding a `Value`). `Member` is `{ name: string, ty: Type }`.
    fn registerTypeVm(self: *Vm, args: []const Ref, frame: *Frame, ref_types: []const TypeId) Error!?Reg {
        const table = try self.requireTable();
        if (args.len != 3) return self.failMsg("comptime register_type: expected (handle, kind, members)");
        const handle = try self.argTypeId(args, frame, 0);
        const kind: i64 = @bitCast(frame.get(args[1].index()));

        // Decode the `[]Member` slice (element layout `{ name: string, ty: Type }`).
        const slice_ty = try self.refTy(ref_types, args[2]);
        const members_word = frame.get(args[2].index());
        var members = std.ArrayList(NamedMember).empty;
        defer members.deinit(self.gpa);
        try self.decodeMemberSlice(table, members_word, slice_ty, &members);
        // A comptime-constructed type with NO members is VALID for every kind
        // (empty struct / tuple / enum / tagged_union). The per-kind loops below
        // are vacuous for an empty member list and the dup-name checks stay
        // correct. The completion always sets `defined = true`, so the result is
        // distinguishable from a never-completed `declare(...)` placeholder
        // (which carries `defined = false`).

        const tbl = @constCast(table);
        // The slot's nominal identity — accept the forward `tagged_union` from
        // `declare_type` AND an already-completed nominal of the same name (so a
        // re-fill via two import edges is idempotent). A non-nominal handle (not a
        // `declare_type`'d slot) is rejected.
        const ident = nominalIdentOf(table.get(handle)) orelse
            return self.failMsg("comptime register_type: handle is not a declare_type'd nominal slot");

        switch (kind) {
            4 => { // tuple — positional element types (names ignored)
                const tys = self.gpa.alloc(TypeId, members.items.len) catch return self.failMsg("comptime register_type: out of memory");
                for (members.items, 0..) |m, i| tys[i] = m.ty;
                tbl.replaceKeyedInfo(handle, .{ .tuple = .{ .fields = tys, .names = null } });
            },
            2 => { // actual (payloadless) enum — members are variant NAMES; payload must be void
                const names = self.gpa.alloc(types.StringId, members.items.len) catch return self.failMsg("comptime register_type: out of memory");
                for (members.items, 0..) |m, i| {
                    if (m.ty != .void) return self.failMsg("comptime register_type: payload variant — use kind 3 (tagged_union)");
                    for (names[0..i]) |prev| if (prev == m.name) return self.failFmt("comptime register_type: duplicate variant name '{s}'", .{tbl.getString(m.name)});
                    names[i] = m.name;
                }
                tbl.replaceKeyedInfo(handle, .{ .@"enum" = .{ .name = ident.name, .variants = names, .nominal_id = ident.nominal_id } });
            },
            1, 3 => { // struct / tagged_union — `{ name, ty }` fields (dup names rejected)
                const flds = self.gpa.alloc(types.TypeInfo.StructInfo.Field, members.items.len) catch return self.failMsg("comptime register_type: out of memory");
                for (members.items, 0..) |m, i| {
                    for (flds[0..i]) |prev| if (prev.name == m.name) return self.failFmt("comptime register_type: duplicate member name '{s}'", .{tbl.getString(m.name)});
                    flds[i] = .{ .name = m.name, .ty = m.ty };
                }
                const full: types.TypeInfo = if (kind == 1)
                    .{ .@"struct" = .{ .name = ident.name, .fields = flds, .nominal_id = ident.nominal_id } }
                else
                    .{ .tagged_union = .{ .name = ident.name, .fields = flds, .tag_type = .i64, .nominal_id = ident.nominal_id } };
                tbl.replaceKeyedInfo(handle, full);
            },
            else => return self.failMsg("comptime register_type: unknown kind code"),
        }
        return @as(Reg, handle.index());
    }

    /// Mint (or find) a forward `declare`'d nominal slot named `text`: an empty
    /// `tagged_union` placeholder a later `define`/`register_type` completes in
    /// place. Idempotent — lowering already registered the named forward slot (so a
    /// `*Name` self-reference in the body resolved), so return THAT slot. Shared by
    /// the compiler-API `declare_type` and the metatype `declare` builtin.
    fn declareNominal(self: *Vm, table: *const types.TypeTable, text: []const u8) TypeId {
        _ = self;
        const tbl = @constCast(table);
        const name_id = tbl.internString(text);
        if (tbl.findByName(name_id)) |existing| return existing;
        return tbl.internNominal(.{ .tagged_union = .{ .name = name_id, .fields = &.{}, .tag_type = .i64, .defined = false } }, 0);
    }

    /// Decode a `[]{ name: string, ty: Type }` slice from comptime memory into interned
    /// `(StringId, TypeId)` pairs — the shared shape of a compiler-API `Member`, a
    /// metatype `EnumVariant { name, payload }`, and a `StructField { name, type }`.
    /// `slice_ty` (the slice's IR type) gives the element layout (field offsets +
    /// stride). Every malformed shape bails loudly (no silent default).
    fn decodeMemberSlice(self: *Vm, table: *const types.TypeTable, slice_word: Reg, slice_ty: TypeId, out: *std.ArrayList(NamedMember)) Error!void {
        if (slice_ty.isBuiltin() or table.get(slice_ty) != .slice)
            return self.failMsg("comptime define/register: members arg is not a slice");
        const member_ty = table.get(slice_ty).slice.element;
        if (member_ty.isBuiltin() or table.get(member_ty) != .@"struct" or table.get(member_ty).@"struct".fields.len != 2)
            return self.failMsg("comptime define/register: member element must be a {name, ty} struct");
        const mfields = table.get(member_ty).@"struct".fields;
        const name_off = fieldOffset(table, member_ty, 0);
        const ty_off = fieldOffset(table, member_ty, 1);
        const name_fty = mfields[0].ty; // string
        const len = try self.sliceLen(slice_word);
        const base = try self.sliceData(table, slice_word);
        const stride: Addr = @intCast(table.typeSizeBytes(member_ty));
        const tbl = @constCast(table);
        for (0..@intCast(len)) |i| {
            const elem = base + @as(Addr, @intCast(i)) * stride;
            const name_fp = try self.readField(table, elem + name_off, name_fty); // string fat-pointer Addr
            const mname = try self.machine.bytes(try self.sliceData(table, name_fp), @intCast(try self.sliceLen(name_fp)));
            const mty: TypeId = @enumFromInt(@as(u32, @intCast(try self.readField(table, elem + ty_off, .type_value))));
            out.append(self.gpa, .{ .name = tbl.internString(mname), .ty = mty }) catch return self.failMsg("comptime define/register: out of memory");
        }
    }

    /// Resolve the `TypeId` a reflection builtin (`type_name` / `type_is_unsigned`)
    /// queries, given the arg's IR type `aty` and its register word `w`. A
    /// `.type_value` word IS a `TypeId`; an Any box `{ data@0, type_id@8 }` yields
    /// its type_id (the boxed value's runtime type), unless it == `type_value` — a
    /// boxed Type (the `type_of(x)` shape) whose real id sits behind the data
    /// pointer. The VM-native mirror of the legacy `Value.reflectTypeId`.
    fn reflectArgTypeId(self: *Vm, aty: TypeId, w: Reg) Error!TypeId {
        // A `TypeId` index is a u32; a word that doesn't fit is a garbage/mis-read
        // value (e.g. a wrong slice stride yielding an `Any` element at the wrong
        // offset — see 0522). Bail loudly instead of letting `@intCast` abort: the
        // VM must never crash.
        if (aty == .type_value) return TypeId.fromIndex(try self.typeIdxOf(w));
        if (aty == .any) {
            const tag = try self.machine.readWord(w + 8, 8);
            if (tag == @as(u64, TypeId.type_value.index())) {
                // A boxed Type: the data slot is the view's ADDRESS; the
                // TypeId sits behind it (an 8-byte load).
                const data = try self.machine.readWord(w, 8);
                return TypeId.fromIndex(try self.typeIdxOf(try self.machine.readWord(data, 8)));
            }
            return TypeId.fromIndex(try self.typeIdxOf(tag));
        }
        return self.failMsg("comptime reflection builtin: arg is not a Type value or an any box");
    }

    /// Narrow a 64-bit word to a `u32` `TypeId` index, bailing (never crashing) when
    /// it doesn't fit — the tripwire for a mis-read reflection arg.
    fn typeIdxOf(self: *Vm, w: u64) Error!u32 {
        return std.math.cast(u32, w) orelse
            self.failMsg("comptime reflection builtin: type word out of TypeId range (mis-read arg?)");
    }

    /// Service a comptime metatype `intrinsic` (`meta.sx`'s `declare`/`define`)
    /// natively on comptime memory, the VM-native mirror of the legacy
    /// `interp.execBuiltinInner` arms. Returns the result word, or `null` for a
    /// builtin the VM doesn't model yet (caller bails → legacy fallback, so dual-path
    /// parity holds). Keeps BOTH paths alive during the VM-default transition.
    fn callBuiltinVm(self: *Vm, bi: inst_mod.BuiltinCall, ins_ty: TypeId, frame: *Frame, ref_types: []const TypeId) Error!?Reg {
        switch (bi.builtin) {
            // `declare(name)` and `define(handle, info)` are no longer builtins —
            // they're plain sx in `modules/std/meta.sx` over the compiler-API
            // primitives `declare_type` / `register_type` (`callCompilerFn`). The
            // `.declare` / `.define` BuiltinIds and `defineFromInfo` were removed.
            // type_name(x) → the type's name as a string. The arg is a Type value
            // (`.type_value` word = a TypeId) or an Any box (`{tag@0, value@8}` whose
            // tag IS the boxed value's type, unless tag == type_value: then the boxed
            // Type's id is in the value slot). Mirrors the legacy `reflectTypeId`.
            .type_name => {
                const table = try self.requireTable();
                if (bi.args.len < 1) return self.failMsg("comptime type_name: missing argument");
                const tid = try self.reflectArgTypeId(try self.refTy(ref_types, bi.args[0]), frame.get(bi.args[0].index()));
                return try self.makeStringValue(table, table.typeName(tid));
            },
            // type_is_unsigned(x) → is x's type an unsigned int? Resolves the TypeId
            // the same way as type_name (a `.type_value` word, or an Any box whose tag
            // IS the boxed value's type), then queries `isUnsignedInt`. Mirrors the
            // legacy `type_is_unsigned` builtin (`reflectTypeId` + `isUnsignedInt`).
            .is_unsigned => {
                const table = try self.requireTable();
                if (bi.args.len < 1) return self.failMsg("comptime type_is_unsigned: missing argument");
                const tid = try self.reflectArgTypeId(try self.refTy(ref_types, bi.args[0]), frame.get(bi.args[0].index()));
                return @as(Reg, @intFromBool(table.isUnsignedInt(tid)));
            },
            // Runtime-Type scalar reflection (1a-S2): the tag resolves the same
            // way type_name's does; answers come straight from the type table.
            .rt_size_of, .rt_align_of, .rt_struct_field_count, .rt_variant_count, .rt_is_flags, .rt_vector_lanes, .rt_variant_tag_width => {
                const table = try self.requireTable();
                if (bi.args.len < 1) return self.failMsg("comptime reflection: missing argument");
                const tid = try self.reflectArgTypeId(try self.refTy(ref_types, bi.args[0]), frame.get(bi.args[0].index()));
                return switch (bi.builtin) {
                    .rt_size_of => @as(Reg, @intCast(table.typeSizeBytes(tid))),
                    .rt_align_of => @as(Reg, @intCast(table.typeAlignBytes(tid))),
                    .rt_struct_field_count => blk: {
                        if (!tid.isBuiltin()) switch (table.get(tid)) {
                            .@"struct" => |st| break :blk @as(Reg, @intCast(st.fields.len)),
                            .@"union" => |u| break :blk @as(Reg, @intCast(u.fields.len)),
                            .tuple => |t| break :blk @as(Reg, @intCast(t.fields.len)),
                            else => {},
                        };
                        break :blk 0;
                    },
                    .rt_variant_count => blk: {
                        if (!tid.isBuiltin()) switch (table.get(tid)) {
                            .@"enum" => |e| break :blk @as(Reg, @intCast(e.variants.len)),
                            .tagged_union => |u| break :blk @as(Reg, @intCast(u.fields.len)),
                            else => {},
                        };
                        break :blk 0;
                    },
                    .rt_is_flags => blk: {
                        if (!tid.isBuiltin()) {
                            const i = table.get(tid);
                            if (i == .@"enum") break :blk @as(Reg, @intFromBool(i.@"enum".is_flags));
                        }
                        break :blk 0;
                    },
                    .rt_vector_lanes => blk: {
                        if (!tid.isBuiltin()) {
                            const i = table.get(tid);
                            if (i == .vector) break :blk @as(Reg, @intCast(i.vector.length));
                        }
                        break :blk 0;
                    },
                    .rt_variant_tag_width => @as(Reg, @bitCast(table.variantTagWidth(tid))),
                    else => unreachable,
                };
            },
            .rt_member_name, .rt_member_type, .rt_field_offset, .rt_variant_value => {
                const table = try self.requireTable();
                if (bi.args.len < 2) return self.failMsg("comptime reflection: missing arguments");
                const tid = try self.reflectArgTypeId(try self.refTy(ref_types, bi.args[0]), frame.get(bi.args[0].index()));
                const idx: i64 = @bitCast(frame.get(bi.args[1].index()));
                return switch (bi.builtin) {
                    .rt_member_name => try self.makeStringValue(table, table.getString(table.memberName(tid, idx) orelse types.StringId.empty)),
                    .rt_member_type => @as(Reg, (table.memberType(tid, idx) orelse TypeId.void).index()),
                    .rt_field_offset => @as(Reg, @intCast(table.memberOffsetBytes(tid, idx) orelse 0)),
                    .rt_variant_value => @as(Reg, @bitCast(table.memberValue(tid, idx) orelse 0)),
                    else => unreachable,
                };
            },
            .rt_type_eq => {
                if (bi.args.len < 2) return self.failMsg("comptime type_eq: expected two arguments");
                const ta = try self.reflectArgTypeId(try self.refTy(ref_types, bi.args[0]), frame.get(bi.args[0].index()));
                const tb = try self.reflectArgTypeId(try self.refTy(ref_types, bi.args[1]), frame.get(bi.args[1].index()));
                return @as(Reg, @intFromBool(ta == tb));
            },
            // type_info($T) → reflect a type INTO a TypeInfo VALUE (the inverse of
            // define's decode). The arg folded to a `const_type` (a `.type_value`
            // word = the source TypeId); build the value in comptime memory.
            .type_info => {
                const table = try self.requireTable();
                if (bi.args.len != 1) return self.failMsg("comptime type_info: expected (Type)");
                const tid = try self.reflectArgTypeId(try self.refTy(ref_types, bi.args[0]), frame.get(bi.args[0].index()));
                return try self.buildTypeInfo(table, ins_ty, tid);
            },
            else => return null, // not modeled on the VM yet → caller bails to legacy
        }
    }

    /// Reflect type `tid` INTO a `TypeInfo` VALUE built in comptime memory — the inverse
    /// of the sx `define` (which calls `register_type`). The
    /// element/struct layouts come from the `result_ty` (= the metatype `TypeInfo`
    /// tagged union): variant tag `t` → payload struct `EnumInfo`/`StructInfo`/
    /// `TupleInfo` (one slice field) → the slice element (`EnumVariant`/`StructField`/
    /// `Type`). Mirrors the legacy member shapes: a tagged-union/struct field and an
    /// enum variant reflect as `{ name, ty }` (a payloadless variant carries `void`);
    /// tuple elements are bare positional `Type`s. `define(declare(n), type_info(T))`
    /// round-trips to a byte-identical nominal copy.
    fn buildTypeInfo(self: *Vm, table: *const types.TypeTable, result_ty: TypeId, tid: TypeId) Error!Reg {
        if (result_ty.isBuiltin() or table.get(result_ty) != .tagged_union)
            return self.failMsg("comptime type_info: result type is not the TypeInfo tagged union");
        const ti = table.get(result_ty).tagged_union;
        if (ti.backing_type != null)
            return self.failMsg("comptime type_info: TypeInfo result is a backing_type tagged union (unexpected layout)");
        if (tid == .unresolved)
            return self.failMsg("comptime type_info: unresolved type");

        // Decode tid into its TypeInfo variant NAME + a payload writer. The
        // variant is found BY NAME in the result type (never by ordinal), so
        // meta.sx can grow/reorder reflect-only variants freely. EXHAUSTIVE
        // over the type-table kinds — a new kind fails here until classified.
        const Payload = union(enum) {
            none,
            int: struct { bits: i64, signed: bool },
            float: struct { bits: i64 },
            elem_len: struct { elem: TypeId, len: i64 }, // array/vector
            one_type: TypeId, // slice/pointer/many_pointer/optional
            named2: []const NamedMember, // EnumVariant {name, payload}
            named3: []const NamedMember, // StructField {name, type, offset}
            tuple: []const TypeId,
        };
        var pairs = std.ArrayList(NamedMember).empty;
        defer pairs.deinit(self.gpa);
        var tup = std.ArrayList(TypeId).empty;
        defer tup.deinit(self.gpa);
        const oom = "comptime type_info: out of memory";

        var vname: []const u8 = undefined;
        var payload: Payload = .none;
        if (tid.isBuiltin()) {
            switch (tid) {
                .bool => vname = "bool",
                .void => vname = "void",
                .string => vname = "string",
                .cstring => vname = "cstring",
                .any => vname = "any",
                .noreturn => vname = "noreturn",
                .usize => vname = "usize",
                .isize => vname = "isize",
                .type_value => vname = "type_value",
                .f32 => {
                    vname = "float";
                    payload = .{ .float = .{ .bits = 32 } };
                },
                .f64 => {
                    vname = "float";
                    payload = .{ .float = .{ .bits = 64 } };
                },
                .i8, .i16, .i32, .i64 => {
                    vname = "int";
                    payload = .{ .int = .{ .bits = @intCast(table.typeSizeBytes(tid) * 8), .signed = true } };
                },
                .u8, .u16, .u32, .u64 => {
                    vname = "int";
                    payload = .{ .int = .{ .bits = @intCast(table.typeSizeBytes(tid) * 8), .signed = false } };
                },
                else => return self.failMsg("comptime type_info: unclassified builtin type"),
            }
        } else switch (table.get(tid)) {
            .signed => |w| {
                vname = "int";
                payload = .{ .int = .{ .bits = w, .signed = true } };
            },
            .unsigned => |w| {
                vname = "int";
                payload = .{ .int = .{ .bits = w, .signed = false } };
            },
            .f32 => {
                vname = "float";
                payload = .{ .float = .{ .bits = 32 } };
            },
            .f64 => {
                vname = "float";
                payload = .{ .float = .{ .bits = 64 } };
            },
            .bool => vname = "bool",
            .void => vname = "void",
            .string => vname = "string",
            .cstring => vname = "cstring",
            .any => vname = "any",
            .noreturn => vname = "noreturn",
            .usize => vname = "usize",
            .isize => vname = "isize",
            .type_value, .unresolved => vname = "type_value",
            .tagged_union => |u| {
                vname = "enum";
                for (u.fields) |f| pairs.append(self.gpa, .{ .name = f.name, .ty = f.ty }) catch return self.failMsg(oom);
                payload = .{ .named2 = pairs.items };
            },
            .@"enum" => |e| {
                vname = "enum";
                for (e.variants) |v| pairs.append(self.gpa, .{ .name = v, .ty = .void }) catch return self.failMsg(oom);
                payload = .{ .named2 = pairs.items };
            },
            .@"struct" => |st| {
                vname = "struct";
                for (st.fields) |f| pairs.append(self.gpa, .{ .name = f.name, .ty = f.ty }) catch return self.failMsg(oom);
                payload = .{ .named3 = pairs.items };
            },
            .@"union" => |u| {
                vname = "union";
                for (u.fields) |f| pairs.append(self.gpa, .{ .name = f.name, .ty = f.ty }) catch return self.failMsg(oom);
                payload = .{ .named3 = pairs.items };
            },
            .tuple => |t| {
                vname = "tuple";
                for (t.fields) |ety| tup.append(self.gpa, ety) catch return self.failMsg(oom);
                payload = .{ .tuple = tup.items };
            },
            .array => |a| {
                vname = "array";
                payload = .{ .elem_len = .{ .elem = a.element, .len = @intCast(a.length) } };
            },
            .vector => |v| {
                vname = "vector";
                payload = .{ .elem_len = .{ .elem = v.element, .len = @intCast(v.length) } };
            },
            .slice => |sl| {
                vname = "slice";
                payload = .{ .one_type = sl.element };
            },
            .pointer => |p| {
                vname = "pointer";
                payload = .{ .one_type = p.pointee };
            },
            .many_pointer => |mp| {
                vname = "many_pointer";
                payload = .{ .one_type = mp.element };
            },
            .optional => |o| {
                vname = "optional";
                payload = .{ .one_type = o.child };
            },
            .function => vname = "function",
            .closure => vname = "closure",
            .protocol => vname = "protocol",
            .error_set => vname = "error_set",
            .pack => vname = "pack",
        }

        // Find the variant ordinal by NAME in the result TypeInfo union.
        const tag: u32 = blk: {
            for (ti.fields, 0..) |f, i| {
                if (std.mem.eql(u8, table.getString(f.name), vname)) break :blk @intCast(i);
            }
            return self.failMsg("comptime type_info: TypeInfo has no variant for this kind");
        };
        const payload_ty = ti.fields[tag].ty;

        // Materialize the payload (if any) into comptime memory.
        var pinfo: Addr = 0;
        var has_payload = true;
        switch (payload) {
            .none => has_payload = false,
            .int => |iv| {
                pinfo = try self.allocZeroed(table, payload_ty);
                try self.writePayloadField(table, payload_ty, pinfo, 0, @as(Reg, @bitCast(iv.bits)));
                try self.writePayloadField(table, payload_ty, pinfo, 1, @intFromBool(iv.signed));
            },
            .float => |fv| {
                pinfo = try self.allocZeroed(table, payload_ty);
                try self.writePayloadField(table, payload_ty, pinfo, 0, @as(Reg, @bitCast(fv.bits)));
            },
            .elem_len => |el| {
                pinfo = try self.allocZeroed(table, payload_ty);
                try self.writePayloadField(table, payload_ty, pinfo, 0, @as(Reg, el.elem.index()));
                try self.writePayloadField(table, payload_ty, pinfo, 1, @as(Reg, @bitCast(el.len)));
            },
            .one_type => |t| {
                pinfo = try self.allocZeroed(table, payload_ty);
                try self.writePayloadField(table, payload_ty, pinfo, 0, @as(Reg, t.index()));
            },
            .tuple => |elems| {
                pinfo = try self.buildMembersPayload(table, payload_ty, .bare_types, elems, &.{}, tid);
            },
            .named2 => |mems| {
                pinfo = try self.buildMembersPayload(table, payload_ty, .name_ty, &.{}, mems, tid);
            },
            .named3 => |mems| {
                pinfo = try self.buildMembersPayload(table, payload_ty, .name_ty_offset, &.{}, mems, tid);
            },
        }

        // TypeInfo { tag, payload }.
        const ti_size = table.typeSizeBytes(result_ty);
        const ti_addr = self.machine.allocBytes(ti_size, table.typeAlignBytes(result_ty));
        @memset(try self.machine.bytes(ti_addr, ti_size), 0);
        try self.writeField(table, ti_addr, ti.tag_type, @as(Reg, tag));
        if (has_payload) {
            const tag_size: Addr = @intCast(table.typeSizeBytes(ti.tag_type));
            try self.writeField(table, ti_addr + tag_size, payload_ty, pinfo);
        }
        return @as(Reg, ti_addr);
    }

    fn allocZeroed(self: *Vm, table: *const types.TypeTable, ty: TypeId) Error!Addr {
        const size = table.typeSizeBytes(ty);
        const a = self.machine.allocBytes(size, table.typeAlignBytes(ty));
        @memset(try self.machine.bytes(a, size), 0);
        return a;
    }

    fn writePayloadField(self: *Vm, table: *const types.TypeTable, payload_ty: TypeId, base: Addr, idx: u32, val: Reg) Error!void {
        if (payload_ty.isBuiltin() or table.get(payload_ty) != .@"struct" or table.get(payload_ty).@"struct".fields.len <= idx)
            return self.failMsg("comptime type_info: payload shape mismatch (meta.sx TypeInfo drifted from the record builder)");
        const fty = table.get(payload_ty).@"struct".fields[idx].ty;
        try self.writeField(table, base + fieldOffset(table, payload_ty, idx), fty, val);
    }

    const MemberShape = enum { bare_types, name_ty, name_ty_offset };

    /// Build a `{ <slice> }` info payload whose slice elements are bare Type
    /// words (tuple), `{name, payload}` (EnumVariant), or `{name, type,
    /// offset}` (StructField — offsets from the SAME layout walk the field
    /// accessors use).
    fn buildMembersPayload(self: *Vm, table: *const types.TypeTable, payload_ty: TypeId, shape: MemberShape, elems: []const TypeId, mems: []const NamedMember, src_ty: TypeId) Error!Addr {
        if (payload_ty.isBuiltin() or table.get(payload_ty) != .@"struct" or table.get(payload_ty).@"struct".fields.len != 1)
            return self.failMsg("comptime type_info: TypeInfo payload is not a single-slice info struct");
        const slice_field_ty = table.get(payload_ty).@"struct".fields[0].ty;
        if (slice_field_ty.isBuiltin() or table.get(slice_field_ty) != .slice)
            return self.failMsg("comptime type_info: info struct field is not a slice");
        const elem_ty = table.get(slice_field_ty).slice.element;
        const elem_size: Addr = @intCast(table.typeSizeBytes(elem_ty));
        const count = if (shape == .bare_types) elems.len else mems.len;

        const data = self.machine.allocBytes(@intCast(elem_size * @as(Addr, @intCast(@max(count, 1)))), table.typeAlignBytes(elem_ty));
        if (shape == .bare_types) {
            for (elems, 0..) |ety, i| try self.writeField(table, data + @as(Addr, @intCast(i)) * elem_size, elem_ty, @as(Reg, ety.index()));
        } else {
            const want_fields: usize = if (shape == .name_ty_offset) 3 else 2;
            if (elem_ty.isBuiltin() or table.get(elem_ty) != .@"struct" or table.get(elem_ty).@"struct".fields.len != want_fields)
                return self.failMsg("comptime type_info: member element shape mismatch (meta.sx drifted from the record builder)");
            const name_fty = table.get(elem_ty).@"struct".fields[0].ty; // string
            const name_off = fieldOffset(table, elem_ty, 0);
            const ty_off = fieldOffset(table, elem_ty, 1);
            for (mems, 0..) |m, i| {
                const elem = data + @as(Addr, @intCast(i)) * elem_size;
                @memset(try self.machine.bytes(elem, @intCast(elem_size)), 0);
                const name_val = try self.makeStringValue(table, table.getString(m.name));
                try self.writeField(table, elem + name_off, name_fty, name_val);
                try self.writeField(table, elem + ty_off, .type_value, @as(Reg, m.ty.index()));
                if (shape == .name_ty_offset) {
                    const off_off = fieldOffset(table, elem_ty, 2);
                    // Untagged-union arms all overlay at 0; struct fields get
                    // the layout walk's offsets.
                    const foff: i64 = if (table.get(src_ty) == .@"union") 0 else @intCast(fieldOffset(table, src_ty, @intCast(i)));
                    try self.writeField(table, elem + off_off, .i64, @as(Reg, @bitCast(foff)));
                }
            }
        }

        const slice = try self.makeSlice(table, data, @intCast(count));
        const pinfo = try self.allocZeroed(table, payload_ty);
        try self.writeField(table, pinfo + fieldOffset(table, payload_ty, 0), slice_field_ty, slice);
        return pinfo;
    }

    // ── Reg ↔ Value bridge (legacy-interop boundary) ────────────────────────
    //
    // The wiring step routes a comptime eval through the VM, falling back to the
    // legacy `interp.zig` (tagged `Value` model) on `error.Unsupported`. The
    // boundary converts host `Value` args → VM `Reg` words and the VM's result back
    // → a `Value`. This IS a (de)serialization, but ONLY at the legacy boundary and
    // ONLY for the shapes the VM handled — it is transitional, deleted once the VM
    // owns comptime end-to-end. Covers scalars + strings + structs; other aggregate
    // shapes bail loudly (added as wiring surfaces them).

    /// Convert a VM `Reg` (+ comptime memory) of type `ty` back into a legacy `Value`.
    /// Strings/aggregates are deep-copied into `alloc` (they must outlive comptime memory).
    pub fn regToValue(self: *Vm, alloc: std.mem.Allocator, table: *const types.TypeTable, reg: Reg, ty: TypeId) Error!Value {
        switch (kindOf(table, ty)) {
            .word => {
                if (isFloat(ty)) return .{ .float = @bitCast(reg) };
                if (ty == .bool) return .{ .boolean = reg != 0 };
                // A `Type` value word is a `TypeId` index → the first-class
                // `.type_tag` Value the legacy interp/host uses for Type values.
                if (ty == .type_value) return .{ .type_tag = TypeId.fromIndex(@intCast(reg)) };
                // A function-typed word is an encoded func-ref; map it back to
                // `.func_ref` (or `.null_val` for the null word) so the host
                // serializes it identically to the legacy (e.g. the comptime-global
                // func-ref rejection diagnostic).
                if (isFuncRefType(table, ty)) {
                    return if (funcRefToId(reg)) |fid| .{ .func_ref = fid } else .null_val;
                }
                return .{ .int = @bitCast(reg) };
            },
            .aggregate => {
                if (ty == .string) {
                    const src = try self.machine.bytes(try self.sliceData(table, reg), @intCast(try self.sliceLen(reg)));
                    return .{ .string = alloc.dupe(u8, src) catch return self.failMsg("reg→value: out of memory (string)") };
                }
                const info = table.get(ty);
                if (info == .@"struct") {
                    const out = alloc.alloc(Value, info.@"struct".fields.len) catch return self.failMsg("reg→value: out of memory (struct)");
                    for (info.@"struct".fields, 0..) |f, i| {
                        const fr = try self.readField(table, reg + fieldOffset(table, ty, @intCast(i)), f.ty);
                        out[i] = try self.regToValue(alloc, table, fr, f.ty);
                    }
                    return .{ .aggregate = out };
                }
                if (info == .tuple) {
                    // A failable `(value…, error_tag)` is a tuple; the host's
                    // `checkComptimeFailable` reads the last field as the tag.
                    const elems = info.tuple.fields;
                    const out = alloc.alloc(Value, elems.len) catch return self.failMsg("reg→value: out of memory (tuple)");
                    for (elems, 0..) |ety, i| {
                        const fr = try self.readField(table, reg + tupleFieldOffset(table, ty, @intCast(i)), ety);
                        out[i] = try self.regToValue(alloc, table, fr, ety);
                    }
                    return .{ .aggregate = out };
                }
                if (info == .array) {
                    // `[N]E` is held by-address as N contiguous `E` slots at
                    // stride `sizeof(E)`. Bridge each element via `regToValue`
                    // recursively (so a nested array / array-of-struct / array
                    // inside a struct all compose), producing an `.aggregate`
                    // Value whose serializer arm (`serializeAggregateValue`'s
                    // `.array` case) emits an `LLVMConstArray2`.
                    const elem_ty = info.array.element;
                    const len: usize = @intCast(info.array.length);
                    const stride: Addr = @intCast(table.typeSizeBytes(elem_ty));
                    const out = alloc.alloc(Value, len) catch return self.failMsg("reg→value: out of memory (array)");
                    for (0..len) |i| {
                        const elem_addr = reg + @as(Addr, @intCast(i)) * stride;
                        const er = try self.readField(table, elem_addr, elem_ty);
                        out[i] = try self.regToValue(alloc, table, er, elem_ty);
                    }
                    return .{ .aggregate = out };
                }
                if (info == .optional) {
                    // Only the `{ payload@0, has_value@sizeof(child) }` aggregate
                    // shape lands here — a pointer-child optional is a word and
                    // bridges through the `.word` arm. A closure / protocol child
                    // has a different layout (sentinel func-ref / ctx-ptr-as-flag),
                    // so guard against it and bail loudly rather than mis-read.
                    const child = info.optional.child;
                    if (optChildIsPtr(table, child))
                        return self.failMsg("reg→value: pointer optional reached the aggregate arm");
                    if (!child.isBuiltin()) switch (table.get(child)) {
                        .closure => return self.failMsg("reg→value: ?Closure optional not bridged (sentinel layout)"),
                        .@"struct" => |s| if (s.is_protocol)
                            return self.failMsg("reg→value: ?Protocol optional not bridged (ctx-ptr layout)"),
                        else => {},
                    };
                    // has_value flag lives at offset sizeof(child); clear → null.
                    // The `const_null` form is a bare `null_addr` (no allocation);
                    // treat that as none too (mirrors `optHas`).
                    if (reg == null_addr) return .null_val;
                    const has = (try self.machine.readWord(reg + table.typeSizeBytes(child), 1)) != 0;
                    if (!has) return .null_val;
                    // Present: bridge the payload (read from offset 0) as the child
                    // type, and present it as the `{ payload, i1=true }` LLVM-struct
                    // shape the host's optional serializer expects.
                    const payload_reg = try self.readField(table, reg, child);
                    const payload = try self.regToValue(alloc, table, payload_reg, child);
                    const out = alloc.alloc(Value, 2) catch return self.failMsg("reg→value: out of memory (optional)");
                    out[0] = payload;
                    out[1] = .{ .boolean = true };
                    return .{ .aggregate = out };
                }
                return self.failMsg("reg→value: aggregate shape not bridged yet");
            },
            .unsupported => return self.failMsg("reg→value: unsupported type"),
        }
    }

    /// How a value of type `ty` is held: a register word (scalar/pointer, ≤8
    /// bytes) or by-address in comptime memory (struct). Anything else is not ported
    /// yet (slice/string/any/optional/enum/union/array/tuple/vector — sub-step 4+).
    const Kind = enum { word, aggregate, unsupported };

    fn kindOf(table: *const types.TypeTable, ty: TypeId) Kind {
        switch (ty) {
            .bool, .i8, .u8, .i16, .u16, .i32, .u32, .f32, .i64, .u64, .f64, .usize, .isize, .cstring => return .word,
            // A comptime `Type` value is an 8-byte handle (a `TypeId` in a word) —
            // distinct from the 16-byte boxed `.any`. It rides as a word.
            .type_value => return .word,
            .string => return .aggregate, // {ptr,len} fat pointer (16B), by-address
            .any => return .aggregate, // boxed { type_tag, value } (16B), by-address
            else => {},
        }
        if (ty.isBuiltin()) return .unsupported; // void, noreturn, unresolved
        return switch (table.get(ty)) {
            .pointer, .many_pointer, .function => .word,
            .@"enum" => .word, // payloadless enum: i64 (or its backing) — a word
            .error_set => .word, // the error channel is a u32 tag id — a word
            // A tagged union is a `{ tag@0, [N x i8] payload@tag_size }` value held
            // by-address (like a struct) — same as the `enum_init` write path.
            .@"struct", .array, .tuple, .slice, .tagged_union => .aggregate,
            // `?T`: a pointer child is null-as-0 (word); else `{T, i1}` by-address.
            .optional => |o| if (optChildIsPtr(table, o.child)) .word else .aggregate,
            else => .unsupported,
        };
    }

    /// A function value (func-ref) is encoded in a register as `FuncId.index() + 1`
    /// so that 0 is reserved for the NULL function pointer (a `FuncId` of 0 is a
    /// real function and must stay distinguishable from null). `funcRefWord` encodes;
    /// `funcRefToId` decodes (returns null for the 0/null word).
    fn funcRefWord(fid: inst_mod.FuncId) Reg {
        return @as(Reg, fid.index()) + 1;
    }
    fn funcRefToId(word: Reg) ?inst_mod.FuncId {
        if (word == null_addr) return null;
        return inst_mod.FuncId.fromIndex(@intCast(word - 1));
    }

    /// Is `ty` a function value type — a function type directly, or a pointer to
    /// one? Such a word holds an encoded func-ref (see `funcRefWord`), not a raw int.
    fn isFuncRefType(table: *const types.TypeTable, ty: TypeId) bool {
        if (ty.isBuiltin()) return false;
        return switch (table.get(ty)) {
            .function => true,
            .pointer => |p| !p.pointee.isBuiltin() and table.get(p.pointee) == .function,
            else => false,
        };
    }

    /// A pointer-shaped (word) type — picks the `void*`-ABI extern-return trampoline
    /// (`callPtrRet`) over the `i64`-ABI one. `cstring` plus any `pointer` /
    /// `many_pointer` / `function`; a non-pointer optional folds to its child word.
    fn isPointerish(table: *const types.TypeTable, ty: TypeId) bool {
        if (ty == .cstring) return true;
        if (ty.isBuiltin()) return false;
        return switch (table.get(ty)) {
            .pointer, .many_pointer, .function => true,
            .optional => |o| optChildIsPtr(table, o.child),
            else => false,
        };
    }

    /// A `?T` whose child is a pointer/many-pointer/function is represented as a
    /// bare pointer (null == 0), not a `{T, i1}` aggregate — mirrors `typeSizeBytes`.
    fn optChildIsPtr(table: *const types.TypeTable, child: TypeId) bool {
        if (child.isBuiltin()) return false;
        return switch (table.get(child)) {
            .pointer, .many_pointer, .function => true,
            else => false,
        };
    }

    /// Does an optional value `v` of type `opt_ty` hold a value? A pointer optional
    /// is present iff non-null; a `{T,i1}` optional is none when `v` is `null_addr`
    /// (the `const_null` form) else its flag byte (at offset `sizeof(child)`) is set.
    fn optHas(self: *Vm, table: *const types.TypeTable, opt_ty: TypeId, v: Reg) Error!bool {
        const child = table.get(opt_ty).optional.child;
        if (optChildIsPtr(table, child)) return v != null_addr;
        if (v == null_addr) return false;
        return (try self.machine.readWord(v + table.typeSizeBytes(child), 1)) != 0;
    }

    /// Read a value of type `ty` from comptime address `addr`: a scalar reads its
    /// bytes; an aggregate value IS its address (it lives inline at `addr`).
    /// `f32` is special: float REGISTERS hold f64 bits (like the legacy interp's
    /// `.float`), but memory holds the 4-byte IEEE-754 single — so read 4 bytes as
    /// `f32` and widen to the f64 register form. A SIGNED sub-64-bit integer
    /// (`i8`/`i16`/`i32`/`isize`) is SIGN-extended into the 64-bit register — the
    /// legacy `.int` model is i64, so a stored-and-reloaded negative value must
    /// stay negative (else e.g. `i32 -1` reloads as `0xFFFFFFFF` and `< 0` is false).
    fn readField(self: *Vm, table: *const types.TypeTable, addr: Addr, ty: TypeId) Error!Reg {
        if (ty == .f32) {
            const bits: u32 = @truncate(try self.machine.readWord(addr, 4));
            const f: f32 = @bitCast(bits);
            return @bitCast(@as(f64, f));
        }
        return switch (kindOf(table, ty)) {
            .word => {
                const sz = table.typeSizeBytes(ty);
                const raw = try self.machine.readWord(addr, sz);
                return if (isSignedInt(ty) and sz < 8) signExtendWord(raw, sz) else raw;
            },
            .aggregate => addr,
            .unsupported => {
                self.detail = "comptime VM: value type not yet supported on comptime memory (slice/optional/enum/array/etc.)";
                return error.Unsupported;
            },
        };
    }

    /// Write register word `val` (of type `ty`) to comptime address `addr`: a scalar
    /// writes its bytes; an aggregate copies `sizeof(ty)` bytes from `val` (its
    /// source address) into `addr`. A `null_addr` aggregate source is the
    /// null/none sentinel (a non-pointer `?T` set to `null`, an empty slice/string,
    /// …): there is no source object to copy, so the destination is ZEROED — the
    /// all-zero representation IS none / `{ptr:0,len:0}` (flag byte 0 → not present).
    fn writeField(self: *Vm, table: *const types.TypeTable, addr: Addr, ty: TypeId, val: Reg) Error!void {
        // `f32`: the register holds f64 bits (see `readField`); narrow to a 4-byte
        // IEEE-754 single for storage — mirrors the legacy interp's `@floatCast`.
        if (ty == .f32) {
            const f: f32 = @floatCast(@as(f64, @bitCast(val)));
            const bits: u32 = @bitCast(f);
            return self.machine.writeWord(addr, 4, bits);
        }
        switch (kindOf(table, ty)) {
            .word => try self.machine.writeWord(addr, table.typeSizeBytes(ty), val),
            .aggregate => {
                const n = table.typeSizeBytes(ty);
                if (n == 0) return;
                if (val == null_addr) {
                    @memset(try self.machine.bytes(addr, n), 0);
                } else {
                    @memcpy(try self.machine.bytes(addr, n), try self.machine.bytes(val, n));
                }
            },
            .unsupported => {
                self.detail = "comptime VM: value type not yet supported on comptime memory (slice/optional/enum/array/etc.)";
                return error.Unsupported;
            },
        }
    }

    /// The byte offset of struct field `idx`, computed the same way
    /// `TypeTable.typeSizeBytes` lays a struct out (each field aligned to its own
    /// alignment, in declaration order) — so init/get/gep agree, and the layout
    /// matches the table's size computation. A string/slice is a `{ptr@0, len@8}`
    /// fat pointer (the `makeSlice` layout), accessed by field 0 (ptr) / 1 (len).
    fn fieldOffset(table: *const types.TypeTable, sty: TypeId, idx: u32) Addr {
        // string/slice `{ptr@0, len@8}` and the boxed Any `{type_tag@0, value@8}`
        // share the same two-8-byte-field layout.
        if (sty == .string or sty == .any or (!sty.isBuiltin() and table.get(sty) == .slice))
            return if (idx == 0) 0 else 8;
        const fields = table.get(sty).@"struct".fields;
        var off: usize = 0;
        for (fields, 0..) |f, i| {
            off = std.mem.alignForward(usize, off, table.typeAlignBytes(f.ty));
            if (i == idx) return @intCast(off);
            off += table.typeSizeBytes(f.ty);
        }
        return @intCast(off);
    }

    /// The struct type a `FieldAccess` operates on: the explicit `base_type` when
    /// lowering set it, else the base operand's Ref type — dereferenced when the
    /// base is a POINTER (`struct_gep` on an `alloca` result is `*S` → `S`).
    fn aggType(self: *Vm, table: *const types.TypeTable, fa: inst_mod.FieldAccess, ref_types: []const TypeId) Error!TypeId {
        // The explicit `base_type` when lowering set it, else the base operand's
        // Ref type. Either way, deref ONE pointer level when the result is a
        // pointer-to-struct: a `struct_gep`/`struct_get` on a `*Struct` receiver
        // (e.g. `list.field` where `list: *List`) computes the field offset on the
        // POINTEE struct, with the base register already holding the pointer
        // address. Lowering sets `base_type = *Struct` on the write/lvalue path.
        const raw = fa.base_type orelse (try self.refTy(ref_types, fa.base));
        if (!raw.isBuiltin() and table.get(raw) == .pointer) return table.get(raw).pointer.pointee;
        return raw;
    }

    /// The byte offset of tuple element `idx` — the positional analogue of
    /// `fieldOffset` (each element aligned to its own alignment, in order).
    fn tupleFieldOffset(table: *const types.TypeTable, tty: TypeId, idx: u32) Addr {
        const fields = table.get(tty).tuple.fields;
        var off: usize = 0;
        for (fields, 0..) |fty, i| {
            off = std.mem.alignForward(usize, off, table.typeAlignBytes(fty));
            if (i == idx) return @intCast(off);
            off += table.typeSizeBytes(fty);
        }
        return @intCast(off);
    }

    /// The pointee of a single-element pointer type (the result of `index_gep` is
    /// `*element`). Falls back to `ty` if it isn't a `.pointer` (the caller only
    /// uses the result for an element-size query).
    fn pointeeOf(table: *const types.TypeTable, ty: TypeId) TypeId {
        if (!ty.isBuiltin()) {
            const info = table.get(ty);
            if (info == .pointer) return info.pointer.pointee;
        }
        return ty;
    }

    /// Address of element `idx_word` in `base`: `data + idx * elem_size`, where
    /// `data` is `base` itself for a directly-addressable base (`array` / `pointer`
    /// / `many_pointer` / `cstring`) or the loaded `.ptr` field for a fat-pointer
    /// base (`slice` / `string`).
    fn elemAddr(self: *Vm, table: *const types.TypeTable, base_ty: TypeId, base: Reg, idx_word: Reg, elem_size: usize) Error!Addr {
        const data: Addr = blk: {
            if (base_ty == .string) break :blk try self.machine.readWord(base, table.pointer_size);
            if (base_ty == .cstring) break :blk base;
            if (base_ty.isBuiltin()) {
                self.detail = "comptime VM: indexing an unsupported builtin base";
                return error.Unsupported;
            }
            break :blk switch (table.get(base_ty)) {
                .array, .pointer, .many_pointer => base,
                .slice => try self.machine.readWord(base, table.pointer_size),
                else => {
                    self.detail = "comptime VM: indexing a non-array/pointer/slice base";
                    return error.Unsupported;
                },
            };
        };
        const idx: u64 = @bitCast(idx_word); // non-negative comptime index
        return data +% idx *% @as(u64, @intCast(elem_size));
    }

    /// Materialize `text` into comptime memory as a `string` VALUE — NUL-terminated
    /// bytes + a `{ptr, len}` fat pointer (len excludes the NUL). Shared by
    /// `text_of` and `type_info`'s variant/field-name construction.
    fn makeStringValue(self: *Vm, table: *const types.TypeTable, text: []const u8) Error!Reg {
        const data = self.machine.allocBytes(text.len + 1, 1); // +1: NUL (zero-init)
        if (text.len > 0) @memcpy(try self.machine.bytes(data, text.len), text);
        return try self.makeSlice(table, data, text.len);
    }

    /// Build a `{ptr, len}` fat pointer (slice/string value) in comptime memory and
    /// return its address. `ptr` is `pointer_size` bytes at offset 0; `len` is an
    /// i64 at offset 8 (the layout `typeSizeBytes` uses for slice/string: 16B).
    fn makeSlice(self: *Vm, table: *const types.TypeTable, data: Addr, len: u64) Error!Addr {
        const fp = self.machine.allocBytes(16, 8);
        try self.machine.writeWord(fp, table.pointer_size, data);
        try self.machine.writeWord(fp + 8, 8, len);
        return fp;
    }

    /// Read the `.len` field (i64 @ offset 8) of a fat-pointer value at `base`.
    fn sliceLen(self: *Vm, base: Addr) Error!u64 {
        return self.machine.readWord(base + 8, 8);
    }

    /// Read the `.ptr` field (`pointer_size` @ offset 0) of a fat-pointer at `base`.
    fn sliceData(self: *Vm, table: *const types.TypeTable, base: Addr) Error!Addr {
        return self.machine.readWord(base, table.pointer_size);
    }

    /// Build a `List(string)` aggregate in comptime memory from host strings and
    /// return its Addr (the VM's aggregate value IS its address). `list_ty` is
    /// the result type of the calling primitive (`List(string)`); its field
    /// offsets/types drive the layout (target-aware via the table), so this works
    /// for any `{ items: [*]string, len: i64, cap: i64 }`-shaped struct. Used by
    /// the metadata-query compiler primitives (`c_object_paths`/`link_libraries`).
    fn makeStringList(self: *Vm, table: *const types.TypeTable, list_ty: TypeId, items: []const []const u8) Error!Reg {
        if (list_ty.isBuiltin() or table.get(list_ty) != .@"struct")
            return self.failMsg("comptime List builder: result type is not a List struct");
        const str_size = table.typeSizeBytes(.string);
        // Backing array of `items.len` `string` fat pointers (null when empty —
        // the List's `items` is then a null `[*]string`, matching `len`/`cap` 0).
        const backing: Addr = if (items.len == 0) null_addr else self.machine.allocBytes(items.len * str_size, 8);
        for (items, 0..) |s, i| {
            try self.writeField(table, backing + i * str_size, .string, try self.makeStringValue(table, s));
        }
        // The List struct: field 0 = items (`[]string` fat pointer {ptr, len}),
        // field 1 = cap (i64). `items.ptr` = backing, `items.len` = cap = n.
        const addr = self.machine.allocBytes(table.typeSizeBytes(list_ty), 8);
        const items_fty = table.memberType(list_ty, 0) orelse
            return self.failMsg("comptime List builder: result type has no items field");
        const cap_fty = table.memberType(list_ty, 1) orelse
            return self.failMsg("comptime List builder: result type has no cap field");
        const n: Reg = @bitCast(@as(i64, @intCast(items.len)));
        // Write the `items` slice as a {ptr, len} fat pointer at field 0.
        if (items_fty.isBuiltin() or table.get(items_fty) != .slice)
            return self.failMsg("comptime List builder: items field is not a slice");
        const items_off = addr + fieldOffset(table, list_ty, 0);
        try self.machine.writeWord(items_off, table.pointer_size, backing);
        try self.machine.writeWord(items_off + table.pointer_size, 8, n);
        // cap = live count (the backing is exactly `n` elements).
        try self.writeField(table, addr + fieldOffset(table, list_ty, 1), cap_fty, n);
        return addr;
    }

    /// Read a `string` argument (a `{ptr, len}` fat pointer at `val`) as a host
    /// `[]const u8`. The bytes are a VIEW into comptime memory (Addr is a real host
    /// pointer over a stable arena), valid for the duration of the call.
    fn readStringArg(self: *Vm, table: *const types.TypeTable, val: Reg) Error![]const u8 {
        const len: usize = @intCast(try self.sliceLen(val));
        if (len == 0) return "";
        return try self.machine.bytes(try self.sliceData(table, val), len);
    }

    /// Read a `List(string)` aggregate (at `addr`) into a host `[][]const u8` —
    /// the inverse of `makeStringList`. Element string bytes are VIEWS into comptime
    /// memory (stable arena); the outer array is gpa-allocated (freed at
    /// `Vm.deinit`). Used by the `link` primitive to read its List args.
    fn readStringList(self: *Vm, table: *const types.TypeTable, list_ty: TypeId, addr: Addr) Error![]const []const u8 {
        if (list_ty.isBuiltin() or table.get(list_ty) != .@"struct")
            return self.failMsg("comptime List reader: arg type is not a List struct");
        // `items` is a `[]string` fat pointer at field 0: ptr at offset 0, len
        // at offset `pointer_size` (there is no separate `len` field now).
        const items_off = addr + fieldOffset(table, list_ty, 0);
        const items_ptr = try self.machine.readWord(items_off, table.pointer_size);
        const len: usize = @intCast(try self.machine.readWord(items_off + table.pointer_size, 8));
        const str_size = table.typeSizeBytes(.string);
        const out = self.gpa.alloc([]const u8, len) catch return self.failMsg("comptime List reader: out of memory");
        var i: usize = 0;
        while (i < len) : (i += 1) {
            out[i] = try self.readStringArg(table, items_ptr + i * str_size);
        }
        return out;
    }
};
