//! The cursor's target storage table and the ops the four operations lower to.

const std = @import("std");
const errors = @import("../../errors.zig");
const parser = @import("../../parser.zig");
const corpus_paths = @import("corpus_paths");
const target_mod = @import("../../target.zig");
const ir_mod = @import("../ir.zig");
const TypeId = ir_mod.TypeId;
const Lowering = ir_mod.Lowering;

fn wordsFor(triple: [*:0]const u8) u8 {
    return (target_mod.TargetConfig{ .triple = triple }).vaListWords();
}

test "cursor storage matches the target's va_list" {
    // Each expectation is the target ABI's
    // `sizeof(__builtin_va_list) / sizeof(void *)`.
    try std.testing.expectEqual(@as(u8, 1), wordsFor("arm64-apple-darwin"));
    try std.testing.expectEqual(@as(u8, 1), wordsFor("arm64-apple-ios"));
    try std.testing.expectEqual(@as(u8, 1), wordsFor("arm64-apple-ios-simulator"));
    try std.testing.expectEqual(@as(u8, 3), wordsFor("x86_64-apple-darwin"));
    try std.testing.expectEqual(@as(u8, 3), wordsFor("x86_64-apple-ios-simulator"));
    try std.testing.expectEqual(@as(u8, 3), wordsFor("x86_64-unknown-linux-gnu"));
    try std.testing.expectEqual(@as(u8, 4), wordsFor("aarch64-unknown-linux-gnu"));
    try std.testing.expectEqual(@as(u8, 4), wordsFor("aarch64-linux-android"));
    try std.testing.expectEqual(@as(u8, 1), wordsFor("x86_64-pc-windows-msvc"));
    try std.testing.expectEqual(@as(u8, 1), wordsFor("aarch64-pc-windows-msvc"));
    try std.testing.expectEqual(@as(u8, 1), wordsFor("wasm32-unknown-unknown"));
    try std.testing.expectEqual(@as(u8, 1), wordsFor("wasm32-unknown-emscripten"));
    try std.testing.expectEqual(@as(u8, 1), wordsFor("wasm64-unknown-unknown"));
}

/// Lower `body` with the cursor declaration in scope.
///
/// The declaration written here is core.sx's, so the lowering is pointed at that
/// module: the contract registry binds `@VaList` to it by file identity and
/// refuses the name anywhere else.
const Lowered = struct {
    module: ir_mod.Module,
    lowering: Lowering,
    diagnostics: errors.DiagnosticList,
};

fn lower(alloc: std.mem.Allocator, body: []const u8, out: *Lowered) !void {
    const src = try std.fmt.allocPrintSentinel(alloc, "@VaList :: struct {{\n}}\n{s}\n", .{body}, 0);
    var p = parser.Parser.init(alloc, src);
    const root = p.parse() catch return error.ParseFailed;

    const core_sx = try std.fs.path.join(alloc, &.{ corpus_paths.library_dir, "modules/std/core.sx" });
    out.module = ir_mod.Module.init(alloc);
    out.diagnostics = errors.DiagnosticList.init(alloc, src, core_sx);
    out.lowering = Lowering.init(&out.module);
    out.lowering.diagnostics = &out.diagnostics;
    out.lowering.main_file = core_sx;
    out.lowering.stdlib_paths = &.{corpus_paths.library_dir};
    out.lowering.lowerRoot(root);
}

test "the cursor type carries the target's storage words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(), "main :: () { }", &lowered);
    defer lowered.module.deinit();

    const table = &lowered.module.types;
    const tid = table.findByName(table.internString("@VaList")).?;
    const words = (target_mod.TargetConfig{}).vaListWords();
    try std.testing.expectEqual(@as(usize, words), table.get(tid).@"struct".fields.len);
    try std.testing.expectEqual(@as(usize, words) * table.pointer_size, table.typeSizeBytes(tid));
    try std.testing.expectEqual(@as(usize, table.pointer_size), table.typeAlignBytes(tid));
}

test "each cursor operation takes the local's address in every statement position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\walk :: (n: i32, ..) -> i64 abi(.c) {
        \\    ap: @VaList = ---;
        \\    @va_start(*ap);
        \\    dup: @VaList = ---;
        \\    @va_copy(*dup, *ap);
        \\    v := @va_arg(i64, *ap);
        \\    @va_end(*ap);
        \\    defer @va_end(*dup);
        \\    return v;
        \\}
        \\main :: () -> i64 { return walk(1, 7); }
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expect(!lowered.diagnostics.hasErrors());

    const walk = &lowered.module.functions.items[@intFromEnum(lowered.lowering.resolveFuncByName("walk").?)];
    var starts: usize = 0;
    var args: usize = 0;
    var copies: usize = 0;
    var ends: usize = 0;
    for (walk.blocks.items) |blk| {
        for (blk.insts.items) |ins| {
            switch (ins.op) {
                .va_start => |u| {
                    starts += 1;
                    try expectAddressOfAlloca(walk, u.operand);
                },
                .va_arg => |u| {
                    args += 1;
                    try std.testing.expectEqual(TypeId.i64, ins.ty);
                    try expectAddressOfAlloca(walk, u.operand);
                },
                .va_copy => |v| {
                    copies += 1;
                    try expectAddressOfAlloca(walk, v.dst);
                    try expectAddressOfAlloca(walk, v.src);
                },
                .va_end => |u| {
                    ends += 1;
                    try expectAddressOfAlloca(walk, u.operand);
                },
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), starts);
    try std.testing.expectEqual(@as(usize, 1), args);
    try std.testing.expectEqual(@as(usize, 1), copies);
    // The direct statement and the deferred one.
    try std.testing.expectEqual(@as(usize, 2), ends);
}

test "an incoming C list is a cursor place, and a boundary argument passes one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\reader :: (n: i32, ap: @VaList) -> i64 extern;
        \\relay :: (n: i32, ap: @VaList) -> i64 export {
        \\    return reader(n, ap);
        \\}
        \\main :: () -> i64 { return 0; }
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expect(!lowered.diagnostics.hasErrors());

    const relay = &lowered.module.functions.items[@intFromEnum(lowered.lowering.resolveFuncByName("relay").?)];
    var places: usize = 0;
    var passes: usize = 0;
    for (relay.blocks.items) |blk| {
        for (blk.insts.items) |ins| {
            switch (ins.op) {
                // The place opens over the incoming parameter itself — ref 1,
                // the list slot of `(n, ap)`.
                .va_place => |u| {
                    places += 1;
                    try std.testing.expectEqual(@as(u32, 1), u.operand.index());
                },
                // The argument carries that same place, reached as an address.
                .va_pass => |u| {
                    passes += 1;
                    const addr = defOf(relay, u.operand) orelse return error.PassOperandHasNoProducer;
                    try std.testing.expect(addr.op == .addr_of);
                    const place = defOf(relay, addr.op.addr_of.operand) orelse return error.AddressOfHasNoProducer;
                    try std.testing.expect(place.op == .va_place);
                },
                else => {},
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), places);
    try std.testing.expectEqual(@as(usize, 1), passes);
}

test "a boundary argument names a place, not a borrow or a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\reader :: (n: i32, ap: @VaList) -> i64 extern;
        \\walk :: (n: i32, ..) -> i64 abi(.c) {
        \\    ap: @VaList = ---;
        \\    @va_start(*ap);
        \\    defer @va_end(*ap);
        \\    return reader(n, *ap) + reader(n, 7);
        \\}
        \\main :: () -> i64 { return walk(1, 7); }
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expectEqual(@as(usize, 2), countMessages(&lowered, "names a live list"));
}

test "each list spelling belongs to one side of the C boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\c_by_value  :: (ap: @VaList) -> i64 extern;
        \\sx_borrow   :: (ap: *@VaList) -> i64 { return 0; }
        \\sx_by_value :: (ap: @VaList) -> i64 { return 0; }
        \\c_borrow    :: (ap: *@VaList) -> i64 abi(.c) { return 0; }
        \\main :: () -> i64 { return 0; }
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "is the C boundary parameter"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "is the sx-internal borrow"));
}

/// How many error diagnostics carry `needle`.
fn countMessages(lowered: *const Lowered, needle: []const u8) usize {
    var n: usize = 0;
    for (lowered.diagnostics.items.items) |d| {
        if (d.level == .err and std.mem.indexOf(u8, d.message, needle) != null) n += 1;
    }
    return n;
}

/// A cursor operand is the STORAGE address: an `addr_of` over the local's
/// `alloca`. A `load` there would hand the backend the cursor's contents.
fn expectAddressOfAlloca(func: *const ir_mod.Function, ref: ir_mod.Ref) !void {
    const producer = defOf(func, ref) orelse return error.OperandHasNoProducer;
    switch (producer.op) {
        .addr_of => |inner| {
            const slot = defOf(func, inner.operand) orelse return error.AddressOfHasNoProducer;
            try std.testing.expect(slot.op == .alloca);
        },
        else => return error.CursorOperandIsNotAnAddress,
    }
}

/// The instruction that defined `ref`, found by the block ref ranges.
fn defOf(func: *const ir_mod.Function, ref: ir_mod.Ref) ?ir_mod.Inst {
    const idx = ref.index();
    if (idx < func.params.len) return null;
    for (func.blocks.items) |blk| {
        const count: u32 = @intCast(blk.insts.items.len);
        if (idx >= blk.first_ref and idx < blk.first_ref + count) return blk.insts.items[idx - blk.first_ref];
    }
    return null;
}
