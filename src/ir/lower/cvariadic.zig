//! The C-variadic cursor: `@VaList`, the four operations that walk it, and the
//! C boundary it crosses.
//!
//! `@VaList` is declared with no fields; its storage is the target's `va_list`,
//! substituted when the declaration registers. Those words are not spellable, so
//! every rule below keeps a cursor to the three shapes that reach the backend
//! intact — a local's storage, an incoming C parameter's, and a borrowed
//! `*@VaList`.

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

const cursor_name = types.cvariadic_cursor;

/// The field list `@VaList` registers with: `TargetConfig.vaListWords`
/// pointer-sized words, which give the type the target `va_list`'s size and
/// alignment.
pub fn storageFields(self: *Lowering) []const types.TypeInfo.StructInfo.Field {
    const n = (self.target_config orelse target_mod.TargetConfig{}).vaListWords();
    const fields = self.alloc.alloc(types.TypeInfo.StructInfo.Field, n) catch return &.{};
    for (fields, 0..) |*f, i| {
        f.* = .{ .name = self.module.types.internString(wordName(i)), .ty = .usize };
    }
    return fields;
}

/// One storage word's field name. Every name is distinct, so the list covers
/// every index `TargetConfig.vaListWords` returns — at most four.
fn wordName(i: usize) []const u8 {
    return switch (i) {
        0 => "w0",
        1 => "w1",
        2 => "w2",
        3 => "w3",
        else => unreachable,
    };
}

/// True when `sd` is the cursor's declaration. Any other module declaring the
/// name is refused by the contract registry, so the name is the whole test.
pub fn isCursorDecl(sd: *const ast.StructDecl) bool {
    return std.mem.eql(u8, sd.name, cursor_name);
}

/// True when `ty` IS the cursor type.
fn isCursorType(self: *Lowering, ty: TypeId) bool {
    return self.module.types.isCVariadicCursor(ty);
}

/// True when `ty` is `*@VaList` — the shape an sx helper reads a borrow through.
fn isCursorPointer(self: *Lowering, ty: TypeId) bool {
    return self.module.types.isCVariadicCursorPointer(ty);
}

/// How `ty` reaches cursor storage: as its own bytes, through an indirection, or
/// not at all. Every rule below asks this rather than the two bare spellings, so
/// a wrapper carries the same contract the cursor does.
fn reach(self: *Lowering, ty: TypeId) types.TypeTable.CursorReach {
    return self.module.types.cvariadicCursorReach(ty);
}

/// Refuse a position that would need the cursor AS A VALUE. It has no value
/// form: only a local's storage exists, and a borrow reaches it through
/// `*name`. `action` completes "cannot <action>". Returns true when refused.
pub fn refuseValue(self: *Lowering, ty: TypeId, span: ?ast.Span, action: []const u8) bool {
    if (reach(self, ty) != .owned) return false;
    if (self.diagnostics) |d| {
        if (isCursorType(self, ty))
            d.addFmt(.err, span, "cannot {s} '{s}' — a C-variadic cursor has no value form; declare it as a local and pass '*name'", .{ action, cursor_name })
        else
            d.addFmt(.err, span, "cannot {s} '{s}' — it holds a '{s}', which has no value form", .{ action, self.formatTypeName(ty), cursor_name });
    }
    return true;
}

/// Refuse a position a cursor could ESCAPE through — a return, a field, a
/// global. Both the cursor and a borrow of it are refused: the storage belongs
/// to the frame whose tail it reads and the borrow dangles once that frame is
/// gone. Returns true when refused.
pub fn refuseEscape(self: *Lowering, ty: TypeId, span: ?ast.Span, action: []const u8) bool {
    if (refuseValue(self, ty, span, action)) return true;
    if (reach(self, ty) != .borrowed) return false;
    if (self.diagnostics) |d| {
        if (isCursorPointer(self, ty))
            d.addFmt(.err, span, "cannot {s} '*{s}' — a C-variadic cursor cannot outlive the call frame whose tail it reads", .{ action, cursor_name })
        else
            d.addFmt(.err, span, "cannot {s} '{s}' — it addresses a '{s}', which cannot outlive the call frame whose tail it reads", .{ action, self.formatTypeName(ty), cursor_name });
    }
    return true;
}

/// Refuse a query that would publish the cursor's shape — a layout or reflection
/// builtin's type argument, a member selection. Its storage is the target's,
/// substituted at registration, so any answer describes something no sx source
/// can hold. A wrapper's own layout is built out of that storage and publishes
/// it just as directly.
pub fn refuseInspection(self: *Lowering, ty: TypeId, span: ?ast.Span) bool {
    if (reach(self, ty) != .owned) return false;
    if (self.diagnostics) |d| {
        if (isCursorType(self, ty))
            d.addFmt(.err, span, "'{s}' is opaque — its storage is the target's and has no published layout", .{cursor_name})
        else
            d.addFmt(.err, span, "'{s}' holds a '{s}', whose storage is the target's — it has no published layout", .{ self.formatTypeName(ty), cursor_name });
    }
    return true;
}

/// Refuse capturing a cursor or a borrow of one. The list reads a tail the
/// enclosing frame owns, and a closure may outlive that frame.
pub fn refuseCapture(self: *Lowering, ty: TypeId, span: ?ast.Span) bool {
    if (reach(self, ty) == .none) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "cannot capture a C-variadic cursor — it reads a tail the enclosing frame owns, which a closure may outlive", .{});
    return true;
}

/// Refuse selecting a member through a cursor or a borrow of one. Only a
/// selection that lands on the cursor's own storage is refused — a wrapper's
/// members are its own, and answering for them publishes nothing.
pub fn refuseMember(self: *Lowering, ty: TypeId, span: ?ast.Span) bool {
    const selected = if (isCursorPointer(self, ty)) self.module.types.get(ty).pointer.pointee else ty;
    if (!isCursorType(self, selected)) return false;
    return refuseInspection(self, selected, span);
}

/// True when a composite type expression spells the cursor at some leaf. The
/// reflection guard resolves only such an argument, leaving every other one to
/// the single resolution its own builtin performs.
pub fn mentionsCursorType(self: *Lowering, node: *const ast.Node) bool {
    return switch (node.data) {
        .type_expr => |te| std.mem.eql(u8, te.name, cursor_name),
        .identifier => |id| std.mem.eql(u8, id.name, cursor_name),
        .array_type_expr => |a| mentionsCursorType(self, a.element_type),
        .slice_type_expr => |s| mentionsCursorType(self, s.element_type),
        .optional_type_expr => |o| mentionsCursorType(self, o.inner_type),
        .pointer_type_expr => |p| mentionsCursorType(self, p.pointee_type),
        .many_pointer_type_expr => |p| mentionsCursorType(self, p.element_type),
        .unary_op => |u| u.op == .address_of and mentionsCursorType(self, u.operand),
        .tuple_type_expr => |t| for (t.field_types) |f| {
            if (mentionsCursorType(self, f)) break true;
        } else false,
        .function_type_expr => |f| for (f.param_types) |p| {
            if (mentionsCursorType(self, p)) break true;
        } else f.return_type != null and mentionsCursorType(self, f.return_type.?),
        .closure_type_expr => |co| for (co.param_types) |p| {
            if (mentionsCursorType(self, p)) break true;
        } else co.return_type != null and mentionsCursorType(self, co.return_type.?),
        else => false,
    };
}

/// Refuse a parameter that spells a cursor for the wrong side of the boundary.
/// `is_c` is the enclosing signature's effective-C verdict. The two bare
/// spellings are the whole permitted surface — a wrapper carrying a cursor has
/// no slot on either side. Returns true when refused.
pub fn refuseParam(self: *Lowering, ty: TypeId, span: ?ast.Span, is_c: bool) bool {
    if (isCursorType(self, ty)) {
        if (is_c) return false;
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'{s}' is the C boundary parameter — declare this signature 'abi(.c)', 'extern', or 'export', or take the sx-internal borrow '*{s}'", .{ cursor_name, cursor_name });
        return true;
    }
    if (isCursorPointer(self, ty)) {
        if (!is_c) return false;
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'*{s}' is the sx-internal borrow — a C signature takes the list itself, '{s}'", .{ cursor_name, cursor_name });
        return true;
    }
    if (reach(self, ty) == .none) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "'{s}' carries a '{s}' — a list crosses only as the C boundary parameter '{s}' or the sx-internal borrow '*{s}'", .{ self.formatTypeName(ty), cursor_name, cursor_name, cursor_name });
    return true;
}

/// Refuse a signature that spells a cursor for the wrong side of the boundary,
/// wherever `ty` carries one. A type carries no linkage slot, so `abi(.c)` is
/// the only spelling that makes a signature the C one, and no side returns a
/// list. Returns true when refused.
pub fn refuseSignature(self: *Lowering, ty: TypeId, span: ?ast.Span) bool {
    return refuseSignatureWithin(self, ty, span, null);
}

/// A type the search is inside. The chain of them is the cycle test: a type that
/// repeats carries exactly the signatures its earlier visit carried.
const SignatureEdge = struct {
    ty: TypeId,
    from: ?*const SignatureEdge,

    fn walked(path: ?*const SignatureEdge, ty: TypeId) bool {
        var it = path;
        while (it) |e| : (it = e.from) {
            if (e.ty == ty) return true;
        }
        return false;
    }
};

/// Every signature `ty` carries, checked at each leaf. A wrapper states the same
/// contract its element does, so an array, a slice, an optional, a tuple, an
/// aggregate, and an indirection each hand the search on to what they hold.
fn refuseSignatureWithin(self: *Lowering, ty: TypeId, span: ?ast.Span, path: ?*const SignatureEdge) bool {
    if (ty.isBuiltin()) return false;
    if (SignatureEdge.walked(path, ty)) return false;
    const here = SignatureEdge{ .ty = ty, .from = path };
    return switch (self.module.types.get(ty)) {
        .function => |f| refuseCallableSignature(self, f.params, f.ret, f.call_conv == .c, span, &here),
        .closure => |co| refuseClosureSignature(self, co, span, &here),
        .@"struct" => |s| anyFieldRefusesSignature(self, s.fields, span, &here),
        .@"union" => |u| anyFieldRefusesSignature(self, u.fields, span, &here),
        .tagged_union => |u| anyFieldRefusesSignature(self, u.fields, span, &here),
        .array => |a| refuseSignatureWithin(self, a.element, span, &here),
        .vector => |v| refuseSignatureWithin(self, v.element, span, &here),
        .optional => |o| refuseSignatureWithin(self, o.child, span, &here),
        .pointer => |p| refuseSignatureWithin(self, p.pointee, span, &here),
        .many_pointer => |p| refuseSignatureWithin(self, p.element, span, &here),
        .slice => |s| refuseSignatureWithin(self, s.element, span, &here),
        else => false,
    };
}

/// One callable leaf: each parameter against the side of the boundary its own
/// convention puts it on, the return against the escape rule, and both against
/// the signatures they carry in turn. Every resolved callable — a function
/// type, a closure type, a protocol method — funnels through here.
fn refuseCallableSignature(self: *Lowering, params: []const TypeId, ret: TypeId, is_c: bool, span: ?ast.Span, path: ?*const SignatureEdge) bool {
    for (params) |p| {
        if (refuseParam(self, p, span, is_c)) return true;
        if (refuseSignatureWithin(self, p, span, path)) return true;
    }
    if (refuseEscape(self, ret, span, "return")) return true;
    return refuseSignatureWithin(self, ret, span, path);
}

/// A `Closure` carries an sx environment, so it has no C side: a by-value list
/// gets the closure-shaped refusal rather than the "declare it C" advice, and
/// everything else takes the non-C rules.
fn refuseClosureSignature(self: *Lowering, co: types.TypeInfo.ClosureInfo, span: ?ast.Span, path: ?*const SignatureEdge) bool {
    for (co.params) |p| {
        if (isCursorType(self, p)) {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "a 'Closure' carries an sx environment and has no C signature for '{s}' — take the sx-internal borrow '*{s}'", .{ cursor_name, cursor_name });
            return true;
        }
        if (refuseParam(self, p, span, false)) return true;
        if (refuseSignatureWithin(self, p, span, path)) return true;
    }
    if (refuseEscape(self, co.ret, span, "return")) return true;
    return refuseSignatureWithin(self, co.ret, span, path);
}

fn anyFieldRefusesSignature(self: *Lowering, fields: []const types.TypeInfo.StructInfo.Field, span: ?ast.Span, path: ?*const SignatureEdge) bool {
    for (fields) |f| {
        if (refuseSignatureWithin(self, f.ty, span, path)) return true;
    }
    return false;
}

/// A protocol method's parameter. A method is an sx call on every protocol
/// kind: a by-value list has no C signature to join, and the rest takes the
/// non-C rules.
pub fn refuseMethodParam(self: *Lowering, ty: TypeId, span: ?ast.Span) bool {
    if (isCursorType(self, ty)) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "a constraint or interface method is an sx call and has no C signature for '{s}' — take the sx-internal borrow '*{s}'", .{ cursor_name, cursor_name });
        return true;
    }
    return refuseParam(self, ty, span, false);
}

/// A generic template's explicitly-spelled cursor leaves, validated at the
/// declaration even when nothing instantiates it. Only a type expression that
/// spells the cursor resolves here — with diagnostics off, so an unbound `$T`
/// elsewhere in the signature stays out of the check and instantiation
/// validates the rest.
pub fn templatePreflight(self: *Lowering, fd: *const ast.FnDecl) void {
    const is_c = ast.isEffectiveCSignature(fd);
    for (fd.params) |p| {
        if (!mentionsCursorType(self, p.type_expr)) continue;
        const pty = resolveQuiet(self, p.type_expr) orelse continue;
        if (refuseParam(self, pty, p.type_expr.span, is_c)) continue;
        _ = refuseSignature(self, pty, p.type_expr.span);
    }
    if (fd.return_type) |rt| {
        if (!mentionsCursorType(self, rt)) return;
        const rty = resolveQuiet(self, rt) orelse return;
        if (refuseEscape(self, rty, rt.span, "declare a return of type")) return;
        _ = refuseSignature(self, rty, rt.span);
    }
}

/// A parameterized protocol's methods resolve only per instantiation, so an
/// explicitly-spelled cursor is validated at the declaration — otherwise an
/// uninstantiated template ships a signature no one ever checks.
pub fn protocolTemplatePreflight(self: *Lowering, pd: *const ast.ProtocolDecl) void {
    for (pd.methods) |m| {
        for (m.params) |p| {
            if (!mentionsCursorType(self, p)) continue;
            const pty = resolveQuiet(self, p) orelse continue;
            if (refuseMethodParam(self, pty, p.span)) continue;
            _ = refuseSignature(self, pty, p.span);
        }
        if (m.return_type) |rt| {
            if (!mentionsCursorType(self, rt)) continue;
            const rty = resolveQuiet(self, rt) orelse continue;
            if (refuseEscape(self, rty, rt.span, "declare a return of type")) continue;
            _ = refuseSignature(self, rty, rt.span);
        }
    }
}

/// `node`'s type with diagnostics off, or null when it does not resolve.
fn resolveQuiet(self: *Lowering, node: *const ast.Node) ?TypeId {
    const saved = self.diagnostics;
    self.diagnostics = null;
    defer self.diagnostics = saved;
    const ty = self.resolveTypeWithBindings(node);
    return if (ty == .unresolved) null else ty;
}

/// The cursor place of an incoming C `va_list` parameter, bound so the body
/// reads it exactly as it reads a local's storage.
pub fn bindBoundaryParam(self: *Lowering, param_ref: Ref, ty: TypeId) Ref {
    return self.builder.emit(.{ .va_place = .{ .operand = param_ref } }, self.module.types.ptrTo(ty));
}

/// The argument for a C `va_list` parameter, or null when `param_ty` is not one.
///
/// The parameter is PLACE-ONLY: `ap` names a list this frame holds — a local or
/// an incoming boundary parameter — and `ap.*` the one a borrow points at.
/// Neither is read as a value; the place crosses under the target's C ABI.
pub fn boundaryArg(self: *Lowering, node: *const Node, param_ty: TypeId) ?Ref {
    if (!isCursorType(self, param_ty)) return null;
    const place = boundaryPlace(self, node) orelse blk: {
        if (self.diagnostics) |d|
            d.addFmt(.err, node.span, "a '{s}' argument names a live list — pass a '{s}' local or parameter as 'ap', or a borrow's list as 'ap.*'", .{ cursor_name, cursor_name });
        // The diagnostic halts the build; an unopened local keeps the argument
        // the same shape the accepted spellings produce.
        break :blk self.builder.alloca(param_ty);
    };
    return self.builder.emit(.{ .va_pass = .{ .operand = place } }, param_ty);
}

/// The address of the list `node` names, or null when it names no place.
fn boundaryPlace(self: *Lowering, node: *const Node) ?Ref {
    if (node.data == .identifier) {
        const b = cursorBinding(self, node.data.identifier.name) orelse return null;
        return self.builder.emit(.{ .addr_of = .{ .operand = b.ref } }, self.module.types.ptrTo(b.ty));
    }
    if (node.data == .deref_expr) {
        const ref = self.lowerExpr(node.data.deref_expr.operand);
        if (!isCursorPointer(self, self.builder.getRefType(ref))) return null;
        return ref;
    }
    return null;
}

/// The binding `name` denotes when it holds a cursor's storage, or null.
fn cursorBinding(self: *Lowering, name: []const u8) ?lower.Binding {
    const scope = self.scope orelse return null;
    const sb = scope.lookupBoundary(name);
    if (sb.crossed != .none) return null;
    const binding = sb.binding orelse return null;
    if (!binding.is_alloca or !isCursorType(self, binding.ty)) return null;
    return binding;
}

/// Which cursor operation `name` is, or null.
fn cursorIntrinsic(name: []const u8) ?intrinsics.Id {
    const id = intrinsics.findByName(name) orelse return null;
    return switch (id) {
        .@"@vaStart", .@"@vaArg", .@"@vaCopy", .@"@vaEnd" => id,
        else => null,
    };
}

/// Lower `@vaStart` / `@vaArg` / `@vaCopy` / `@vaEnd`, or return null when
/// `name` is not one of them.
pub fn tryLowerIntrinsic(self: *Lowering, name: []const u8, c: *const ast.Call) ?Ref {
    const id = cursorIntrinsic(name) orelse return null;
    const expected: usize = switch (id) {
        .@"@vaArg", .@"@vaCopy" => 2,
        else => 1,
    };
    if (c.args.len != expected) {
        if (self.diagnostics) |d| d.addFmt(.err, c.callee.span, "{s} expects {d} arguments", .{ name, expected });
        return Ref.none;
    }

    switch (id) {
        .@"@vaStart" => {
            requireVariadicDefinition(self, name, c.callee.span);
            const cursor = ownedCursor(self, c.args[0], name) orelse return Ref.none;
            self.builder.emitVoid(.{ .va_start = .{ .operand = cursor } }, .void);
            return Ref.none;
        },
        .@"@vaEnd" => {
            const cursor = ownedCursor(self, c.args[0], name) orelse return Ref.none;
            self.builder.emitVoid(.{ .va_end = .{ .operand = cursor } }, .void);
            return Ref.none;
        },
        .@"@vaCopy" => {
            const dst = ownedCursor(self, c.args[0], name) orelse return Ref.none;
            const src = borrowedCursor(self, c.args[1], name) orelse return Ref.none;
            self.builder.emitVoid(.{ .va_copy = .{ .dst = dst, .src = src } }, .void);
            return Ref.none;
        },
        .@"@vaArg" => {
            const read_ty = argumentType(self, c.args[0]) orelse return Ref.none;
            const cursor = borrowedCursor(self, c.args[1], name) orelse return Ref.none;
            return self.builder.emit(.{ .va_arg = .{ .operand = cursor } }, read_ty);
        },
        else => unreachable,
    }
}

/// `@vaStart` opens a cursor over the enclosing call's tail, so it needs one:
/// the definition being lowered must end its parameter list in a bare `..`.
fn requireVariadicDefinition(self: *Lowering, name: []const u8, span: ast.Span) void {
    if (self.current_fn_decl) |fd| {
        if (fd.is_c_variadic and fd.extern_export != .extern_) return;
    }
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "'{s}' needs a C-variadic tail to open — end this definition's parameter list in '..' (`(fixed, ..) -> R abi(.c)`)", .{name});
}

/// The address of a cursor this function OWNS: `*name`, where `name` is a local
/// of type `@VaList`. `@vaStart`, `@vaEnd`, and `@vaCopy`'s destination act
/// on the owner's storage — an incoming list and a borrowed `*@VaList` both
/// belong to another frame, which ends them itself.
fn ownedCursor(self: *Lowering, node: *const Node, name: []const u8) ?Ref {
    if (localCursorSlot(self, node)) |local| {
        if (!local.borrowed) return local.slot;
        if (self.diagnostics) |d|
            d.addFmt(.err, node.span, "'{s}' acts on a cursor this function owns — an incoming '{s}' is borrowed already open, and its caller ends it", .{ name, cursor_name });
        return null;
    }
    if (self.diagnostics) |d|
        d.addFmt(.err, node.span, "'{s}' acts on a cursor this function owns — pass '*name' for a local '{s}'", .{ name, cursor_name });
    return null;
}

/// The address of any cursor: a local's storage, an incoming list's, or a
/// `*@VaList` passed in. Reading and copying FROM a cursor are both legal on a
/// borrow.
fn borrowedCursor(self: *Lowering, node: *const Node, name: []const u8) ?Ref {
    if (localCursorSlot(self, node)) |local| return local.slot;
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
fn localCursorSlot(self: *Lowering, node: *const Node) ?struct { slot: Ref, borrowed: bool } {
    if (node.data != .unary_op) return null;
    const uop = node.data.unary_op;
    if (uop.op != .address_of or uop.operand.data != .identifier) return null;
    const binding = cursorBinding(self, uop.operand.data.identifier.name) orelse return null;
    return .{
        .slot = self.builder.emit(.{ .addr_of = .{ .operand = binding.ref } }, self.module.types.ptrTo(binding.ty)),
        .borrowed = binding.borrowed_cursor,
    };
}

/// The type `@vaArg` reads. The caller asks for what the C default argument
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
