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

test "a wrapper carrying a cursor is refused wherever the cursor is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\Wraps :: struct {
        \\    row: [1]@VaList;
        \\    lent: [2]*@VaList;
        \\}
        \\rows: [1]@VaList;
        \\borrows: []*@VaList;
        \\hands_back :: () -> [1]@VaList { return ---; }
        \\takes :: (rows: [1]@VaList) -> i64 abi(.c) { return 0; }
        \\takes_borrow :: (rows: []*@VaList) -> i64 { return 0; }
        \\main :: () -> i64 { return 0; }
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 3), countMessages(&lowered, "it holds a '@VaList'"));
    try std.testing.expectEqual(@as(usize, 2), countMessages(&lowered, "it addresses a '@VaList'"));
    try std.testing.expectEqual(@as(usize, 2), countMessages(&lowered, "a list crosses only as"));
}

test "a signature is checked through every wrapper that carries it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\NotC   :: (i32, @VaList) -> i64;
        \\CRead  :: (i32, @VaList) -> i64 abi(.c);
        \\Nested :: (i32, NotC) -> i64 abi(.c);
        \\BadRet :: (i32) -> [1]*@VaList abi(.c);
        \\Legal  :: struct { read: CRead; }
        \\wrapped: [1]NotC;
        \\behind: *NotC;
        \\nested: Nested;
        \\hands_back: BadRet;
        \\legal_rows: [2]CRead;
        \\legal_held: Legal;
        \\main :: () -> i64 { return 0; }
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 3), countMessages(&lowered, "is the C boundary parameter"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "it addresses a '@VaList'"));
    try std.testing.expectEqual(@as(usize, 4), lowered.diagnostics.errorCount());
}

test "a closure signature has no C side for a cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\bad_take: Closure(@VaList) -> i64;
        \\bad_hand: Closure(i32) -> *@VaList;
        \\legal_borrow: Closure(*@VaList) -> i64;
        \\main :: () -> i64 { return 0; }
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "has no C signature for '@VaList'"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "cannot outlive the call frame"));
    try std.testing.expectEqual(@as(usize, 2), lowered.diagnostics.errorCount());
}

test "a generic template meets the boundary rules without an instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\bad_generic :: ($T: Type, ap: @VaList) -> i64 { return 0; }
        \\bad_return  :: ($T: Type) -> *@VaList { return ---; }
        \\bad_nested  :: ($T: Type, cb: Closure(@VaList) -> i64) -> i64 { return 0; }
        \\bad_nested_ret :: ($T: Type) -> (i32, @VaList) -> i64 { return ---; }
        \\legal_c     :: ($T: Type, ap: @VaList) -> i64 abi(.c) { return 0; }
        \\legal_borrow :: ($T: Type, ap: *@VaList) -> i64 { return 0; }
        \\legal_nested_c :: ($T: Type, cb: (i32, @VaList) -> i64 abi(.c)) -> i64 { return 0; }
        \\legal_nested_borrow :: ($T: Type, cb: Closure(*@VaList) -> i64) -> i64 { return 0; }
        \\main :: () -> i64 { return 0; }
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 2), countMessages(&lowered, "is the C boundary parameter"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "has no C signature for '@VaList'"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "cannot outlive the call frame"));
    try std.testing.expectEqual(@as(usize, 4), lowered.diagnostics.errorCount());
}

test "a protocol method meets the boundary rules on every kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\Reader :: protocol vtable {
        \\    read :: (self: *Self, ap: @VaList) -> i64;
        \\}
        \\Templated :: protocol (T: Type) vtable {
        \\    read :: (self: *Self, ap: @VaList) -> T;
        \\    take :: (self: *Self, cb: (@VaList) -> i64) -> i64;
        \\    hand :: (self: *Self) -> Closure(i32) -> *@VaList;
        \\}
        \\LegalBorrow :: protocol vtable {
        \\    read :: (self: *Self, ap: *@VaList) -> i64;
        \\}
        \\holds: Reader;
        \\legal: LegalBorrow;
        \\main :: () -> i64 { return 0; }
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 2), countMessages(&lowered, "a protocol method is an sx call and has no C signature"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "is the C boundary parameter"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "cannot outlive the call frame"));
    try std.testing.expectEqual(@as(usize, 4), lowered.diagnostics.errorCount());
}

test "a named tail refuses what its element type refuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\flags :: (n: i32, ..args: []bool) -> i64 extern;
        \\main :: () -> i64 {
        \\    p: ?*i32 = null;
        \\    return flags(1, p);
        \\}
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "where 'bool' is expected"));
    try std.testing.expectEqual(@as(usize, 0), countMessages(&lowered, "cannot cross a C-variadic tail"));
    try std.testing.expectEqual(@as(usize, 1), lowered.diagnostics.errorCount());
}

test "a named tail refuses a conversion that turns on the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\joins :: (n: i32, ..args: []cstring) -> i64 extern;
        \\texts :: (n: i32, ..args: []string) -> i64 extern;
        \\relay :: (s: string) -> i64 { return joins(1, s); }
        \\main :: () -> i64 {
        \\    held: cstring = "de";
        \\    return relay("ab") + texts(1, held);
        \\}
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "only a string LITERAL coerces"));
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "does not coerce to 'string' implicitly"));
}

test "an unwrapped C boundary and an internal borrow stay legal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\Reader :: (i32, @VaList) -> i64 abi(.c);
        \\Api :: struct { read: Reader; }
        \\c_reader :: (n: i32, ap: @VaList) -> i64 extern;
        \\borrow :: (n: i32, ap: *@VaList) -> i64 { return c_reader(n, ap.*); }
        \\own :: (n: i32, ..) -> i64 abi(.c) {
        \\    ap: @VaList = ---;
        \\    @va_start(*ap);
        \\    defer @va_end(*ap);
        \\    return borrow(n, *ap);
        \\}
        \\main :: () -> i64 { return own(1, 7); }
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expect(!lowered.diagnostics.hasErrors());
}

test "one C symbol's fixed and variadic views conflict, equal variadic ones share" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\fixed :: (n: i32) -> i32 extern "same";
        \\tail  :: (n: i32, ..) -> i32 extern "same";
        \\first  :: (n: i32, ..) -> i32 extern "other";
        \\second :: (n: i32, ..) -> i32 extern "other";
        \\main :: () -> i32 { return tail(1, 2) + first(1, 2) + second(1, 2, 3); }
    , &lowered);
    defer lowered.module.deinit();

    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "is already bound with a different signature"));
    try std.testing.expectEqual(@as(usize, 1), countExterns(&lowered, "other"));
}

test "a named tail converts each argument to its element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\joins :: (n: i32, ..args: []cstring) -> i64 extern;
        \\sums  :: (n: i32, ..args: []i32) -> i64 extern;
        \\main :: () -> i64 {
        \\    held: cstring = "de";
        \\    return joins(2, "abc", held) + sums(2, 1, 2);
        \\}
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expect(!lowered.diagnostics.hasErrors());

    const main = &lowered.module.functions.items[@intFromEnum(lowered.lowering.resolveFuncByName("main").?)];
    const joins = lowered.lowering.resolveFuncByName("joins").?;
    var tail_args: usize = 0;
    for (main.blocks.items) |blk| {
        for (blk.insts.items) |ins| {
            const call = switch (ins.op) {
                .call => |c| c,
                else => continue,
            };
            if (call.callee != joins) continue;
            for (call.args[1..]) |arg| {
                const producer = defOf(main, arg) orelse return error.TailArgumentHasNoProducer;
                try std.testing.expectEqual(TypeId.cstring, producer.ty);
                tail_args += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), tail_args);
}

test "a generic monomorph keeps the declaration's convention and tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\read_tail :: ($T: Type, first: $T, ..) -> i64 abi(.c) {
        \\    ap: @VaList = ---;
        \\    @va_start(*ap);
        \\    defer @va_end(*ap);
        \\    total: i64 = xx first;
        \\    total += xx @va_arg(i32, *ap);
        \\    return total;
        \\}
        \\main :: () -> i64 { return read_tail(i32, 40, 2); }
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expect(!lowered.diagnostics.hasErrors());

    // `i32` binds `$T` even though the tail argument keeps the arity open.
    const fid = lowered.lowering.resolveFuncByName("read_tail__i32") orelse return error.MonomorphNotFound;
    const func = &lowered.module.functions.items[@intFromEnum(fid)];
    try std.testing.expect(func.is_c_variadic);
    try std.testing.expect(func.call_conv == .c);

    // The call carries the fixed argument AND the tail argument.
    const main_fn = &lowered.module.functions.items[@intFromEnum(lowered.lowering.resolveFuncByName("main").?)];
    var seen: usize = 0;
    for (main_fn.blocks.items) |blk| {
        for (blk.insts.items) |ins| {
            const call = switch (ins.op) {
                .call => |c| c,
                else => continue,
            };
            if (call.callee != fid) continue;
            seen += 1;
            try std.testing.expectEqual(@as(usize, 2), call.args.len);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "a function value meets the tail rules by its signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\sum_ints :: (n: i32, ..args: []i32) -> i64 extern;
        \\take :: (n: i32, ..) -> i64 extern;
        \\sx_cb :: (x: i64) -> i64 { return x; }
        \\c_cb  :: (x: i64) -> i64 abi(.c) { return x; }
        \\is_var :: ($F: Type, f: F) -> i64 { return 0; }
        \\fixed :: (n: i32) -> i64 abi(.c) { return 0; }
        \\tail  :: (n: i32, ..) -> i64 abi(.c) { return 0; }
        \\main :: () -> i64 {
        \\    f := sum_ints;
        \\    ok := f(3, 10, 20, 12);
        \\    bad := take(1, sx_cb);
        \\    good := take(1, c_cb);
        \\    return ok + bad + good + is_var((i32) -> i64 abi(.c), fixed) + is_var((i32, ..) -> i64 abi(.c), tail);
        \\}
    , &lowered);
    defer lowered.module.deinit();

    // The alias of the named extern tail keeps its open arity; the fixed and
    // variadic function types monomorphize apart; the sx-convention callback
    // is the one refusal — its hidden context has no C slot.
    try std.testing.expectEqual(@as(usize, 1), countMessages(&lowered, "cannot cross a C-variadic tail"));
    try std.testing.expectEqual(@as(usize, 1), lowered.diagnostics.errorCount());
}

test "function types monomorphize apart whatever their return names spell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\R :: struct { x: i64; }
        \\R_cc :: struct { x: i64; }
        \\mk_d :: () -> R_cc { return ---; }
        \\mk_c :: () -> R abi(.c) { return ---; }
        \\accept :: ($F: Type, f: F) -> i64 { return 0; }
        \\main :: () -> i64 {
        \\    return accept(() -> R_cc, mk_d) + accept(() -> R abi(.c), mk_c);
        \\}
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expect(!lowered.diagnostics.hasErrors());
}

test "a bare C-variadic function reflects with its convention and tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lowered: Lowered = undefined;
    try lower(arena.allocator(),
        \\cb :: (x: i32, ..) -> i64 abi(.c) { return 0; }
        \\taker :: (v: any) -> i64 { return 0; }
        \\main :: () -> i64 { return taker(cb); }
    , &lowered);
    defer lowered.module.deinit();
    try std.testing.expect(!lowered.diagnostics.hasErrors());

    // The `any` boxing renders the declared signature — convention and tail
    // included, the same spelling the canonical formatter produces.
    const main_fn = &lowered.module.functions.items[@intFromEnum(lowered.lowering.resolveFuncByName("main").?)];
    var found = false;
    for (main_fn.blocks.items) |blk| {
        for (blk.insts.items) |ins| {
            const sid = switch (ins.op) {
                .const_string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, lowered.module.types.getString(sid), "(i32, ..) -> i64 abi(.c)")) found = true;
        }
    }
    try std.testing.expect(found);
}

test "a C tail reads isize and usize at the target's address width" {
    var module = ir_mod.Module.init(std.testing.allocator);
    defer module.deinit();
    var lowering = Lowering.init(&module);

    try std.testing.expectEqual(@as(?u32, 64), lowering.tailIntegerWidth(.isize));
    try std.testing.expectEqual(@as(?u32, 64), lowering.tailIntegerWidth(.usize));

    module.types.pointer_size = 4;
    try std.testing.expectEqual(@as(?u32, 32), lowering.tailIntegerWidth(.isize));
    try std.testing.expectEqual(@as(?u32, 32), lowering.tailIntegerWidth(.usize));

    // The fixed widths do not move with the target.
    try std.testing.expectEqual(@as(?u32, 64), lowering.tailIntegerWidth(.i64));
    try std.testing.expectEqual(@as(?u32, 16), lowering.tailIntegerWidth(.u16));
    try std.testing.expect(lowering.tailIntegerWidth(.f64) == null);
}

/// How many extern functions carry `sym` as their symbol name.
fn countExterns(lowered: *const Lowered, sym: []const u8) usize {
    var n: usize = 0;
    for (lowered.module.functions.items) |func| {
        if (func.is_extern and std.mem.eql(u8, lowered.module.types.getString(func.name), sym)) n += 1;
    }
    return n;
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
