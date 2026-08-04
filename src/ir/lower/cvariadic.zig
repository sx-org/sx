//! The C-variadic cursor: `@VaList` and the four operations that walk it.
//!
//! `@VaList` is declared with no fields; its storage is the target's `va_list`,
//! substituted when the declaration registers. Those words are not spellable, so
//! every rule below keeps a cursor to the two shapes that reach the backend
//! intact — a local's storage, and a borrowed `*@VaList`.

const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const TypeId = types.TypeId;
const inst_mod = @import("../inst.zig");
const Ref = inst_mod.Ref;
const intrinsics = @import("../intrinsics.zig");
const target_mod = @import("../../target.zig");

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;

/// The contract name of the cursor type, `@` included.
pub const cursor_name = "@VaList";

/// How many pointer-sized words the target's `va_list` occupies.
///
/// x86-64 SysV holds a three-word register-save record; AArch64 AAPCS holds a
/// four-word one. Windows and Apple's AArch64 pass the tail on the stack, so a
/// cursor there is one pointer, as it is on wasm.
pub fn storageWords(tc: target_mod.TargetConfig) u8 {
    if (tc.isWindows()) return 1;
    if (tc.isX86_64()) return 3;
    if (tc.isAarch64() and !tc.isMacOS() and !tc.isIOS()) return 4;
    return 1;
}

/// The field list `@VaList` registers with: `storageWords` pointer-sized words,
/// which give the type the target `va_list`'s size and alignment.
pub fn storageFields(self: *Lowering) []const types.TypeInfo.StructInfo.Field {
    const n = storageWords(self.target_config orelse .{});
    const fields = self.alloc.alloc(types.TypeInfo.StructInfo.Field, n) catch return &.{};
    for (fields, 0..) |*f, i| {
        f.* = .{ .name = self.module.types.internString(wordName(i)), .ty = .usize };
    }
    return fields;
}

fn wordName(i: usize) []const u8 {
    return switch (i) {
        0 => "w0",
        1 => "w1",
        2 => "w2",
        else => "w3",
    };
}

/// True when `sd` is the cursor's declaration. Any other module declaring the
/// name is refused by the contract registry, so the name is the whole test.
pub fn isCursorDecl(sd: *const ast.StructDecl) bool {
    return std.mem.eql(u8, sd.name, cursor_name);
}

/// True when `ty` IS the cursor type.
fn isCursorType(self: *Lowering, ty: TypeId) bool {
    if (ty.isBuiltin()) return false;
    const info = self.module.types.get(ty);
    if (info != .@"struct") return false;
    return std.mem.eql(u8, self.module.types.getString(info.@"struct".name), cursor_name);
}

/// True when `ty` is `*@VaList` — the one shape a cursor crosses a call in.
fn isCursorPointer(self: *Lowering, ty: TypeId) bool {
    if (ty.isBuiltin()) return false;
    const info = self.module.types.get(ty);
    return switch (info) {
        .pointer => |p| isCursorType(self, p.pointee),
        else => false,
    };
}

/// Refuse a position that would need the cursor AS A VALUE. It has no value
/// form: only a local's storage exists, and a borrow reaches it through
/// `*name`. `action` completes "cannot <action>". Returns true when refused.
pub fn refuseValue(self: *Lowering, ty: TypeId, span: ?ast.Span, action: []const u8) bool {
    if (!isCursorType(self, ty)) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "cannot {s} '{s}' — a C-variadic cursor has no value form; declare it as a local and pass '*name'", .{ action, cursor_name });
    return true;
}

/// Refuse a position a cursor could ESCAPE through — a return, a field, a
/// global. Both the cursor and a borrow of it are refused: the storage belongs
/// to the frame whose tail it reads and the borrow dangles once that frame is
/// gone. Returns true when refused.
pub fn refuseEscape(self: *Lowering, ty: TypeId, span: ?ast.Span, action: []const u8) bool {
    if (refuseValue(self, ty, span, action)) return true;
    if (!isCursorPointer(self, ty)) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "cannot {s} '*{s}' — a C-variadic cursor cannot outlive the call frame whose tail it reads", .{ action, cursor_name });
    return true;
}

/// Refuse a query that would publish the cursor's shape — a layout or reflection
/// builtin's type argument, a member selection. Its storage is the target's,
/// substituted at registration, so any answer describes something no sx source
/// can hold.
pub fn refuseInspection(self: *Lowering, ty: TypeId, span: ?ast.Span) bool {
    if (!isCursorType(self, ty)) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "'{s}' is opaque — its storage is the target's and has no published layout", .{cursor_name});
    return true;
}

/// Refuse selecting a member through a cursor or a borrow of one.
pub fn refuseMember(self: *Lowering, ty: TypeId, span: ?ast.Span) bool {
    if (isCursorPointer(self, ty)) return refuseInspection(self, self.module.types.get(ty).pointer.pointee, span);
    return refuseInspection(self, ty, span);
}

/// Which cursor operation `name` is, or null.
fn cursorIntrinsic(name: []const u8) ?intrinsics.Id {
    const id = intrinsics.findByName(name) orelse return null;
    return switch (id) {
        .@"@va_start", .@"@va_arg", .@"@va_copy", .@"@va_end" => id,
        else => null,
    };
}

/// Lower `@va_start` / `@va_arg` / `@va_copy` / `@va_end`, or return null when
/// `name` is not one of them.
pub fn tryLowerIntrinsic(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    const id = cursorIntrinsic(name) orelse return null;
    const expected: usize = switch (id) {
        .@"@va_arg", .@"@va_copy" => 2,
        else => 1,
    };
    if (c.args.len != expected) {
        if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "{s} expects {d} arguments", .{ name, expected });
        return Ref.none;
    }

    switch (id) {
        .@"@va_start" => {
            requireVariadicDefinition(self, name, c.callee.span);
            const cursor = ownedCursor(self, c.args[0], name) orelse return Ref.none;
            self.builder.emitVoid(.{ .va_start = .{ .operand = cursor } }, .void);
            return Ref.none;
        },
        .@"@va_end" => {
            const cursor = ownedCursor(self, c.args[0], name) orelse return Ref.none;
            self.builder.emitVoid(.{ .va_end = .{ .operand = cursor } }, .void);
            return Ref.none;
        },
        .@"@va_copy" => {
            const dst = ownedCursor(self, c.args[0], name) orelse return Ref.none;
            const src = borrowedCursor(self, c.args[1], name) orelse return Ref.none;
            self.builder.emitVoid(.{ .va_copy = .{ .dst = dst, .src = src } }, .void);
            return Ref.none;
        },
        .@"@va_arg" => {
            const read_ty = argumentType(self, c.args[0]) orelse return Ref.none;
            const cursor = borrowedCursor(self, c.args[1], name) orelse return Ref.none;
            return self.builder.emit(.{ .va_arg = .{ .operand = cursor } }, read_ty);
        },
        else => unreachable,
    }
}

/// `@va_start` opens a cursor over the enclosing call's tail, so it needs one:
/// the definition being lowered must end its parameter list in a bare `..`.
fn requireVariadicDefinition(self: *Lowering, name: []const u8, span: ast.Span) void {
    if (self.current_fn_decl) |fd| {
        if (fd.is_c_variadic and fd.extern_export != .extern_) return;
    }
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "'{s}' needs a C-variadic tail to open — end this definition's parameter list in '..' (`(fixed, ..) -> R abi(.c)`)", .{name});
}

/// The address of a cursor this function OWNS: `*name`, where `name` is a local
/// of type `@VaList`. `@va_start`, `@va_end`, and `@va_copy`'s destination act
/// on the owner's storage — a borrowed `*@VaList` belongs to another frame,
/// which ends it itself.
fn ownedCursor(self: *Lowering, node: *const Node, name: []const u8) ?Ref {
    if (localCursorSlot(self, node)) |slot| return slot;
    if (self.diagnostics) |d|
        d.addFmt(.err, node.span, "'{s}' acts on a cursor this function owns — pass '*name' for a local '{s}'", .{ name, cursor_name });
    return null;
}

/// The address of any cursor: an owned local's storage, or a `*@VaList` passed
/// in. Reading and copying FROM a cursor are both legal on a borrow.
fn borrowedCursor(self: *Lowering, node: *const Node, name: []const u8) ?Ref {
    if (localCursorSlot(self, node)) |slot| return slot;
    const ref = self.lowerExpr(node);
    const ty = self.builder.getRefType(ref);
    if (isCursorPointer(self, ty)) return ref;
    if (self.diagnostics) |d|
        d.addFmt(.err, node.span, "'{s}' takes a '*{s}'; got '{s}'", .{ name, cursor_name, self.formatTypeName(ty) });
    return null;
}

/// `*name` over a cursor-typed local, lowered to that local's storage address.
/// Reading the binding's slot directly is what makes the argument the ADDRESS in
/// every statement position — a cursor has no value form to fall back to.
fn localCursorSlot(self: *Lowering, node: *const Node) ?Ref {
    if (node.data != .unary_op) return null;
    const uop = node.data.unary_op;
    if (uop.op != .address_of or uop.operand.data != .identifier) return null;
    const scope = self.scope orelse return null;
    const sb = scope.lookupBoundary(uop.operand.data.identifier.name);
    if (sb.crossed_fn_boundary) return null;
    const binding = sb.binding orelse return null;
    if (!binding.is_alloca or !isCursorType(self, binding.ty)) return null;
    return self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, self.module.types.ptrTo(binding.ty));
}

/// The type `@va_arg` reads. The caller asks for what the C default argument
/// promotions leave in the slot, so the types those promotions REPLACE are
/// refused by the name the caller wrote, and the rest must be what a C ABI can
/// pass through a tail at all.
fn argumentType(self: *Lowering, node: *const Node) ?TypeId {
    const ty = self.resolveTypeArg(node);
    if (ty == .unresolved) return null;
    if (self.promotedTailType(ty)) |promoted| {
        if (self.diagnostics) |d|
            d.addFmt(.err, node.span, "'{s}' is promoted before it crosses a C-variadic tail — read '{s}'", .{ self.formatTypeName(ty), self.formatTypeName(promoted) });
        return null;
    }
    if (!self.tailAdmissible(ty)) {
        if (self.diagnostics) |d|
            d.addFmt(.err, node.span, "'{s}' cannot cross a C-variadic tail; use a C ABI integer, 'f64', a pointer, or an 'abi(.c)' function value", .{self.formatTypeName(ty)});
        return null;
    }
    return ty;
}
