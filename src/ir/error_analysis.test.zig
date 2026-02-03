// Tests for error_analysis.zig — the error-set convergence owner
// (`ErrorAnalysis`). Reached via `ir.ErrorAnalysis{ .l = &lowering }`, mirroring
// the other facade tests. Moved here from lower.test.zig when the convergence
// traversals moved out of `Lowering` (A5.1 sub-step 2). The whole-program
// fix-point + closure-shape union are what A5.1 must preserve.

const std = @import("std");
const ast = @import("../ast.zig");
const errors = @import("../errors.zig");
const Node = ast.Node;

const ir_mod = @import("ir.zig");
const TypeId = ir_mod.TypeId;
const Lowering = ir_mod.Lowering;
const ErrorAnalysis = ir_mod.ErrorAnalysis;

fn mk(alloc: std.mem.Allocator, data: ast.Node.Data) *Node {
    const n = alloc.create(Node) catch unreachable;
    n.* = .{ .span = .{ .start = 0, .end = 0 }, .data = data };
    return n;
}

test "error_analysis: convergeInferredErrorSets propagates a callee set across a try edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);
    const ea = ErrorAnalysis{ .l = &lowering };

    // raiser :: () -> ! { raise error.Foo; }
    const r_rt = mk(alloc, .{ .error_type_expr = .{ .name = null } });
    const r_err = mk(alloc, .{ .identifier = .{ .name = "error" } });
    const r_fa = mk(alloc, .{ .field_access = .{ .object = r_err, .field = "Foo" } });
    const r_raise = mk(alloc, .{ .raise_stmt = .{ .tag = r_fa } });
    const r_body = mk(alloc, .{ .block = .{ .stmts = &[_]*Node{r_raise} } });
    const raiser_fd = ast.FnDecl{ .name = "raiser", .params = &.{}, .return_type = r_rt, .body = r_body };

    // caller :: () -> ! { try raiser(); }  — no direct raise; inherits {Foo}.
    const c_rt = mk(alloc, .{ .error_type_expr = .{ .name = null } });
    const c_callee = mk(alloc, .{ .identifier = .{ .name = "raiser" } });
    const c_call = mk(alloc, .{ .call = .{ .callee = c_callee, .args = &.{} } });
    const c_try = mk(alloc, .{ .try_expr = .{ .operand = c_call } });
    const c_body = mk(alloc, .{ .block = .{ .stmts = &[_]*Node{c_try} } });
    const caller_fd = ast.FnDecl{ .name = "caller", .params = &.{}, .return_type = c_rt, .body = c_body };

    lowering.program_index.fn_ast_map.put("raiser", &raiser_fd) catch unreachable;
    lowering.program_index.fn_ast_map.put("caller", &caller_fd) catch unreachable;

    ea.convergeInferredErrorSets();

    const foo = module.types.internTag("Foo");
    const raiser_set = lowering.inferred_error_sets.get("raiser") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), raiser_set.len);
    try std.testing.expectEqual(foo, raiser_set[0]);
    // The caller raises nothing directly but converges to {Foo} via the edge.
    const caller_set = lowering.inferred_error_sets.get("caller") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), caller_set.len);
    try std.testing.expectEqual(foo, caller_set[0]);

    // facts() exposes the same converged store.
    try std.testing.expect(ea.facts().inferred_error_sets.get("caller") != null);
}

test "error_analysis: convergeClosureShapeSets unions a bare-! closure literal's raises" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);
    const ea = ErrorAnalysis{ .l = &lowering };

    // host :: () { () -> ! { raise error.Bar; }; }  — a bare-`!` closure literal
    // sitting in `host`'s body; its raises union into the shape set.
    const lam_rt = mk(alloc, .{ .error_type_expr = .{ .name = null } });
    const l_err = mk(alloc, .{ .identifier = .{ .name = "error" } });
    const l_fa = mk(alloc, .{ .field_access = .{ .object = l_err, .field = "Bar" } });
    const l_raise = mk(alloc, .{ .raise_stmt = .{ .tag = l_fa } });
    const lam_body = mk(alloc, .{ .block = .{ .stmts = &[_]*Node{l_raise} } });
    const lambda = mk(alloc, .{ .lambda = .{ .params = &.{}, .return_type = lam_rt, .body = lam_body } });
    const host_body = mk(alloc, .{ .block = .{ .stmts = &[_]*Node{lambda} } });
    const host_fd = ast.FnDecl{ .name = "host", .params = &.{}, .return_type = null, .body = host_body };

    lowering.program_index.fn_ast_map.put("host", &host_fd) catch unreachable;

    ea.convergeClosureShapeSets();

    // Exactly one closure shape recorded, carrying {Bar}.
    try std.testing.expectEqual(@as(u32, 1), lowering.shape_inferred_sets.count());
    var it = lowering.shape_inferred_sets.valueIterator();
    const tags = it.next().?.*;
    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqual(module.types.internTag("Bar"), tags[0]);
}

test "error_analysis: empty-inferred warnings are emitted in source order, not hashmap order" {
    // `work` is a StringHashMap, so iterating it to emit diagnostics yields hash
    // order. Zig and Odin do not share a hash, so a faithful port would reorder
    // this output — hence the sort. Names here are deliberately chosen so hash
    // order != source order (see issues/0133).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var module = ir_mod.Module.init(alloc);
    defer module.deinit();
    var lowering = Lowering.init(&module);
    var diags = errors.DiagnosticList.init(alloc, "", "test.sx");
    lowering.diagnostics = &diags;
    const ea = ErrorAnalysis{ .l = &lowering };

    // Eight `-> !` functions that never raise → each warns. Span order is the
    // declaration order below; `fds` is registered in that same order.
    const names = [_][]const u8{
        "alpha", "bravo", "charlie", "delta", "echo_fn", "foxtrot", "golf", "hotel",
    };
    var fds: [names.len]ast.FnDecl = undefined;
    for (&names, 0..) |name, i| {
        const rt = mk(alloc, .{ .error_type_expr = .{ .name = null } });
        // Ascending, distinct spans → source order is unambiguous.
        rt.span = .{ .start = @intCast((i + 1) * 100), .end = @intCast((i + 1) * 100 + 1) };
        const body = mk(alloc, .{ .block = .{ .stmts = &[_]*Node{} } });
        fds[i] = ast.FnDecl{ .name = name, .params = &.{}, .return_type = rt, .body = body };
    }
    for (&names, 0..) |name, i| {
        lowering.program_index.fn_ast_map.put(name, &fds[i]) catch unreachable;
    }

    ea.convergeInferredErrorSets();

    // Every function warned, and the warnings ascend by span.
    var warns = std.ArrayList(errors.Diagnostic).empty;
    defer warns.deinit(alloc);
    for (diags.items.items) |d| {
        if (d.level == .warn) warns.append(alloc, d) catch unreachable;
    }
    try std.testing.expectEqual(names.len, warns.items.len);

    var prev: u32 = 0;
    for (warns.items) |w| {
        const span = w.span orelse return error.TestExpectedSpan;
        try std.testing.expect(span.start > prev); // strictly ascending == source order
        prev = span.start;
    }
}
