//! Focused AST round-trip printer.
//!
//! Reconstructs sx source text from AST nodes. The scope is intentionally
//! narrow: it covers the declaration, type-expression, and (since ERR E0.2)
//! the error-handling expression/statement node kinds the ERR stream's parser
//! tests round-trip, and bails loudly (`error.UnsupportedNode`) on anything it
//! does not yet handle — so an unsupported node can never be silently
//! mis-printed (CLAUDE.md REJECTED PATTERNS: no silent arms). Later steps
//! extend it as new surface syntax lands.

const std = @import("std");
const ast = @import("ast.zig");

const Node = ast.Node;
const Writer = *std.Io.Writer;

/// Print a node back to source text. Routes declarations here, expressions /
/// statements to `printExpr`, and type expressions to `printType`.
pub fn printNode(node: *const Node, writer: Writer) anyerror!void {
    switch (node.data) {
        .error_set_decl => |d| {
            try writer.writeAll(d.name);
            try writer.writeAll(" :: error {");
            for (d.tag_names, 0..) |tag, i| {
                try writer.writeAll(if (i == 0) " " else ", ");
                try writer.writeAll(tag);
            }
            if (d.tag_names.len > 0) try writer.writeByte(' ');
            try writer.writeByte('}');
        },
        else => try printExpr(node, writer),
    }
}

/// Print an expression or statement node back to source text.
pub fn printExpr(node: *const Node, writer: Writer) anyerror!void {
    switch (node.data) {
        .identifier => |id| try writer.writeAll(id.name),
        .enum_literal => |el| {
            try writer.writeByte('.');
            try writer.writeAll(el.name);
        },
        .int_literal => |l| try writer.print("{d}", .{l.value}),
        .bool_literal => |l| try writer.writeAll(if (l.value) "true" else "false"),
        .char_literal => |l| {
            try writer.writeByte('\'');
            try writer.writeAll(l.raw);
            try writer.writeByte('\'');
        },
        .string_literal => |l| {
            try writer.writeByte('"');
            try writer.writeAll(l.raw);
            try writer.writeByte('"');
        },
        .call => |c| {
            try printExpr(c.callee, writer);
            try writer.writeByte('(');
            for (c.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try printExpr(arg, writer);
            }
            try writer.writeByte(')');
        },
        .field_access => |fa| {
            try printExpr(fa.object, writer);
            try writer.writeByte('.');
            try writer.writeAll(fa.field);
        },
        .binary_op => |b| {
            const op_str = binaryOpStr(b.op) orelse return error.UnsupportedNode;
            try printExpr(b.lhs, writer);
            try writer.writeByte(' ');
            try writer.writeAll(op_str);
            try writer.writeByte(' ');
            try printExpr(b.rhs, writer);
        },
        .try_expr => |t| {
            try writer.writeAll("try ");
            try printExpr(t.operand, writer);
        },
        .catch_expr => |c| {
            try printExpr(c.operand, writer);
            try writer.writeAll(" catch");
            if (c.binding) |bnd| {
                try writer.writeAll(" (");
                try writer.writeAll(bnd);
                try writer.writeByte(')');
            }
            if (c.is_match_body) {
                try writer.writeAll(" == ");
                try printMatchArms(c.body, writer);
            } else {
                try writer.writeByte(' ');
                try printExpr(c.body, writer);
            }
        },
        .raise_stmt => |r| {
            try writer.writeAll("raise ");
            try printExpr(r.tag, writer);
        },
        .onfail_stmt => |o| {
            try writer.writeAll("onfail");
            if (o.binding) |bnd| {
                try writer.writeAll(" (");
                try writer.writeAll(bnd);
                try writer.writeByte(')');
            }
            try writer.writeByte(' ');
            try printExpr(o.body, writer);
        },
        .return_stmt => |r| {
            try writer.writeAll("return");
            if (r.value) |v| {
                try writer.writeByte(' ');
                try printExpr(v, writer);
            }
        },
        .postfix_cast => |pc| {
            try printExpr(pc.operand, writer);
            try writer.writeAll(if (pc.is_optional_chain) "?.(" else ".(");
            try printType(pc.type_expr, writer);
            try writer.writeByte(')');
        },
        .block => |blk| {
            try writer.writeByte('{');
            for (blk.stmts) |stmt| {
                try writer.writeByte(' ');
                try printExpr(stmt, writer);
                try writer.writeByte(';');
            }
            try writer.writeAll(" }");
        },
        else => try printType(node, writer),
    }
}

/// Print a type-expression node back to source text.
pub fn printType(node: *const Node, writer: Writer) anyerror!void {
    switch (node.data) {
        .type_expr => |t| try writer.writeAll(t.name),
        .error_type_expr => |e| {
            try writer.writeByte('!');
            if (e.name) |n| try writer.writeAll(n);
        },
        .pointer_type_expr => |p| {
            try writer.writeByte('*');
            try printType(p.pointee_type, writer);
        },
        .optional_type_expr => |o| {
            try writer.writeByte('?');
            try printType(o.inner_type, writer);
        },
        .slice_type_expr => |s| {
            try writer.writeAll("[]");
            try printType(s.element_type, writer);
        },
        .many_pointer_type_expr => |m| {
            try writer.writeAll("[*]");
            try printType(m.element_type, writer);
        },
        .tuple_type_expr => |t| {
            try writer.writeByte('(');
            for (t.field_types, 0..) |ft, i| {
                if (i > 0) try writer.writeAll(", ");
                try printType(ft, writer);
            }
            try writer.writeByte(')');
        },
        else => return error.UnsupportedNode,
    }
}

/// Print the `{ case ... }` arms of a `match_expr` (used for the catch
/// match-body form `catch e == { ... }`). The subject is implicit (the catch
/// binding), so only the arms are emitted. Each arm body must be a one-statement
/// block (the common case); anything else bails loudly.
fn printMatchArms(node: *const Node, writer: Writer) anyerror!void {
    if (node.data != .match_expr) return error.UnsupportedNode;
    try writer.writeByte('{');
    for (node.data.match_expr.arms) |arm| {
        try writer.writeByte(' ');
        if (arm.pattern) |pat| {
            try writer.writeAll("case ");
            try printExpr(pat, writer);
            try writer.writeAll(": ");
        } else {
            try writer.writeAll("else: ");
        }
        if (arm.body.data != .block or arm.body.data.block.stmts.len != 1) {
            return error.UnsupportedNode;
        }
        try printExpr(arm.body.data.block.stmts[0], writer);
        try writer.writeByte(';');
    }
    try writer.writeAll(" }");
}

fn binaryOpStr(op: ast.BinaryOp.Op) ?[]const u8 {
    return switch (op) {
        .or_op => "or",
        .and_op => "and",
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .lte => "<=",
        .gt => ">",
        .gte => ">=",
        else => null,
    };
}
