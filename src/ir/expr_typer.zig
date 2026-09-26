const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");
const program_index_mod = @import("program_index.zig");
const lower = @import("lower.zig");
const lower_closure = @import("lower/closure.zig");

const Node = ast.Node;
const TypeId = types.TypeId;
const Lowering = lower.Lowering;
const TypeResolver = @import("type_resolver.zig").TypeResolver;

/// AST-level expression typing. Owns the structural / non-call expression shapes —
/// literals, unary / binary ops, `try` / `catch`, `if`, block, field access,
/// identifier / type-name, struct / tuple literals, index / slice / deref,
/// null-coalesce, and the statement shapes that produce no value. Call result
/// typing is owned by `CallResolver` (`calls.zig`); a call node reaching here is
/// routed to it via `Lowering.inferExprType`.
///
/// A `*Lowering` facade like `PackResolver`: expression typing
/// reads live lexical-scope / pack / target-type state and dozens of resolver
/// helpers, so it borrows `Lowering` rather than re-threading every field.
pub const ExprTyper = struct {
    l: *Lowering,

    pub fn memberType(self: ExprTyper, receiver: TypeId, field: []const u8, optional: bool) ?TypeId {
        var ty = receiver;
        if (!ty.isBuiltin() and self.l.module.types.get(ty) == .pointer)
            ty = self.l.module.types.get(ty).pointer.pointee;
        if (optional and !ty.isBuiltin() and self.l.module.types.get(ty) == .optional)
            ty = self.l.module.types.get(ty).optional.child;

        const special_container = switch (self.l.module.types.get(ty)) {
            .slice, .array, .vector => true,
            else => false,
        };
        if (special_container) {
            if (std.mem.eql(u8, field, "len")) {
                const result = self.l.module.types.lenTypeOf(ty);
                return if (optional) self.l.optionalOfFlattened(result) else result;
            }
            if (std.mem.eql(u8, field, "ptr")) {
                const result = self.l.module.types.manyPtrTo(self.l.getElementType(ty));
                return if (optional) self.l.optionalOfFlattened(result) else result;
            }
        }
        if (self.l.errorViewFieldType(ty, field)) |result| return result;
        if (ty.isBuiltin()) return null;

        const info = self.l.module.types.get(ty);
        if (info == .@"union" or (info == .@"enum" and info.@"enum".hasPayload())) {
            const name = self.l.module.types.internString(field);
            var i: u32 = 0;
            while (self.l.module.types.memberName(ty, i)) |member_name| : (i += 1) {
                const member_ty = self.l.module.types.memberType(ty, i) orelse break;
                if (member_name == name) return if (optional) self.l.optionalOfFlattened(member_ty) else member_ty;
                if (!self.l.payloadPromotes(member_ty)) continue;
                switch (self.l.lookupField(member_ty, field)) {
                    .hit, .private => |hit| return if (optional) self.l.optionalOfFlattened(hit.ty) else hit.ty,
                    .missing => {},
                }
            }
        }
        if (self.l.swizzleRecvOf(ty)) |recv| {
            switch (Lowering.parseSwizzle(field)) {
                .ok => |sw| {
                    const result = self.l.swizzleResultType(recv, self.l.getElementType(ty), sw);
                    return if (optional) self.l.optionalOfFlattened(result) else result;
                },
                else => {},
            }
        }
        switch (self.l.lookupField(ty, field)) {
            .hit, .private => |hit| return if (optional) self.l.optionalOfFlattened(hit.ty) else hit.ty,
            .missing => {},
        }
        if (optional and self.l.module.types.get(ty) == .pointer)
            ty = self.l.module.types.get(ty).pointer.pointee;
        if (self.l.getterReturnTypeOnDeref(ty, field)) |result|
            return if (optional) self.l.optionalOfFlattened(result) else result;
        return null;
    }

    pub fn indexType(self: ExprTyper, receiver: TypeId) ?TypeId {
        const optional = !receiver.isBuiltin() and self.l.module.types.get(receiver) == .optional;
        const ty = if (optional) self.l.module.types.get(receiver).optional.child else receiver;
        const element = self.l.ptrToArrayElem(ty) orelse self.l.ptrToSliceElem(ty) orelse self.l.getElementType(ty);
        if (element == .unresolved) return null;
        return if (optional) self.l.optionalOfFlattened(element) else element;
    }

    pub fn sliceType(self: ExprTyper, receiver: TypeId, open_ended: bool) ?TypeId {
        const element = self.l.getElementType(receiver);
        if (element == .unresolved) return null;
        const table = &self.l.module.types;
        if (open_ended) if (table.sentinelOf(receiver)) |x| return table.sliceOfSentinel(element, x);
        return table.sliceOfLen(element, table.lenTypeOf(receiver));
    }

    /// Infer the IR type an expression evaluates to (without lowering it).
    /// Recurses through `Lowering.inferExprType` so a nested call node is typed
    /// by its one owner.
    pub fn inferType(self: ExprTyper, node: *const Node) TypeId {
        if (self.l.isAdaptableFloat(node)) return .f64;
        return switch (node.data) {
            // Call result typing is owned by `CallResolver` (`calls.zig`);
            // delegate through `Lowering.inferExprType` so a call node reaching
            // here is typed by that single owner, not mistyped as `.unresolved`.
            .call => self.l.inferExprType(node),
            .string_literal => .string,
            .int_literal => .i64,
            .float_literal => .f64,
            .bool_literal => .bool,
            .char_literal => .i64,
            .null_literal => .void,
            .binary_op => |bop| switch (bop.op) {
                .eq, .neq, .lt, .lte, .gt, .gte => blk: {
                    const lhs_ty = self.l.inferExprType(bop.lhs);
                    if (!lhs_ty.isBuiltin()) {
                        const info = self.l.module.types.get(lhs_ty);
                        if (info == .vector) {
                            break :blk self.l.module.types.vectorOf(.bool, info.vector.length);
                        }
                    }
                    break :blk .bool;
                },
                .and_op, .or_op, .in_op, .is_op => .bool,
                else => blk: {
                    const operands = program_index_mod.floatOperandTypes(bop, self.l.operandType(self.l.inferExprType(bop.lhs)), self.l.operandType(self.l.inferExprType(bop.rhs)), self.l);
                    const lhs_ty = self.l.untypedOperandType(bop.op, bop.lhs, bop.rhs) orelse operands.lhs.?;
                    const rhs_ty = self.l.untypedOperandType(bop.op, bop.rhs, bop.lhs) orelse operands.rhs.?;
                    break :blk switch (self.l.arithResultType(bop.op, lhs_ty, rhs_ty)) {
                        .type => |ty| ty,
                        .signedness, .lane => .unresolved,
                    };
                },
            },
            .unary_op => |uop| switch (uop.op) {
                .not => .bool,
                .negate, .bit_not => self.l.operandType(self.l.inferExprType(uop.operand)),
                .xx => self.l.target_type orelse .unresolved,
                .address_of => blk: {
                    const inner = self.l.inferExprType(uop.operand);
                    if (uop.operand.data == .index_expr) break :blk self.l.module.types.manyPtrTo(inner);
                    break :blk self.l.module.types.ptrTo(inner);
                },
                .pre_decrement => self.l.inferExprType(uop.operand),
            },
            // `try X` evaluates to X's success type (the value part). A
            // pure-failable operand (`-> !` / `-> !Named`, whose type IS the
            // error set) has no value → `void`; a value-carrying `-> (T..., !)`
            // operand yields its value part (the lone value, or a value-tuple).
            // A `try { … }` boundary's success value IS the block's tail, so
            // the block types the whole expression.
            .try_expr => |te| blk: {
                if (te.operand.data == .block) break :blk self.l.inferExprType(te.operand);
                const op_ty = self.l.inferExprType(te.operand);
                const channel = self.l.errorChannelOf(op_ty) orelse break :blk .unresolved;
                if (op_ty == channel) break :blk .void;
                break :blk self.l.failableSuccessType(op_ty);
            },
            // `expr catch ...` strips the error channel → the success type
            // (void for a pure-failable LHS; the value part for value-carrying).
            .catch_expr => |ce| blk: {
                const attempted = Lowering.catchAttempted(&ce);
                if (attempted.boundary) break :blk self.l.inferExprType(attempted.node);
                const op_ty = self.l.inferExprType(attempted.node);
                const channel = self.l.errorChannelOf(op_ty) orelse break :blk .unresolved;
                if (op_ty == channel) break :blk .void;
                break :blk self.l.failableSuccessType(op_ty);
            },
            // `opt?!` force-unwraps an optional to its child type. Without this
            // arm a chained `opt?!.field` / `opt?![i]` / `opt?!.method()` would
            // type its receiver as `.unresolved` (the `else` below) and fail to
            // resolve — even though `lowerForceUnwrap` produces a correctly
            // typed value. Mirrors lowerForceUnwrap's resolveOptionalInner.
            .force_unwrap => |fu| blk: {
                const opt_ty = self.l.inferExprType(fu.operand);
                if (!opt_ty.isBuiltin()) {
                    const info = self.l.module.types.get(opt_ty);
                    if (info == .optional) break :blk info.optional.child;
                }
                break :blk .unresolved;
            },
            .caller_site => self.l.sourceSiteType() orelse .unresolved,
            .if_expr => |ie| {
                // If-else types as its branches' unified type. A `noreturn`
                // branch (one that diverges — `return` / `raise` / `break` /
                // `continue`) unifies away, so the expression takes the other
                // branch's type; both diverging → `noreturn`.
                if (ie.else_branch) |eb| {
                    const then_ty = self.l.inferExprType(ie.then_branch);
                    if (then_ty == .noreturn) return self.l.inferExprType(eb);
                    const else_ty = self.l.inferExprType(eb);
                    if (else_ty == .noreturn) return then_ty;
                    return self.l.unifyValueArmTypes(then_ty, else_ty) orelse then_ty;
                }
                return .void;
            },
            .match_expr => |me| self.l.inferMatchResultType(&me),
            // Divergence shapes type as `noreturn` — they transfer control and
            // produce no value at their site. A block whose last statement is
            // one of these propagates `noreturn` (block arm below), which lets
            // a `catch` body that ends in `return` / `raise` unify with the
            // success type.
            .return_stmt, .raise_stmt, .break_expr, .continue_expr => .noreturn,
            .block => |blk| {
                // A block's type is its last statement's type when that
                // statement is an expression; otherwise it is void.
                if (blk.produces_value and blk.stmts.len > 0) {
                    return self.l.inferExprType(blk.stmts[blk.stmts.len - 1]);
                }
                return .void;
            },
            .field_access => |fa| {
                // Pack-arity intercept: `<pack_name>.len` is i64. Mirrors
                // the lowerFieldAccess intercept so AST-level type
                // inference picks the same shape.
                if (self.l.pack_param_count) |ppc| {
                    if (fa.object.data == .identifier and std.mem.eql(u8, fa.field, "len")) {
                        if (ppc.contains(fa.object.data.identifier.name)) return .i64;
                    }
                }
                // Struct constant access: `Struct.CONST` — mirrors the
                // `lowerFieldAccess` intercept. Without it, `Phys.GRAVITY`
                // (f64) infers as i64 and pack-fn callers box the float into
                // the int slot.
                if (fa.object.data == .identifier) {
                    const obj_name = fa.object.data.identifier.name;
                    // Nominal-authority selection first, mirroring the
                    // lowerFieldAccess intercept — the global
                    // "Struct.CONST" spelling is last-wins across same-name
                    // authors and stays only as the untracked-head fallback.
                    var author_tracked = false;
                    if (self.l.current_source_file orelse self.l.main_file) |from| {
                        switch (self.l.selectNominalLeaf(obj_name, self.l.environmentForSource(from).?, false)) {
                            .resolved => |head_ty| {
                                if (!head_ty.isBuiltin() and self.l.plain_struct_authors.contains(head_ty)) {
                                    author_tracked = true;
                                    if (self.l.struct_const_by_tid.get(.{ .ty = head_ty, .name = self.l.module.types.internString(fa.field) })) |info| {
                                        if (info.ty) |t| return t;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    if (!author_tracked) {
                        const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ obj_name, fa.field }) catch fa.field;
                        if (self.l.struct_const_map.get(qualified)) |info| {
                            if (info.ty) |t| return t;
                        }
                    }
                }
                // Numeric-limit accessor: `<Type>.min`/`.max` (int or float) or a
                // float-only `.epsilon`/`.minPositive`/`.trueMin`/`.inf`/`.nan`
                // is a comptime const of the queried type — mirrors the
                // lowerFieldAccess intercept so inference reports the same type
                // (without it the const would be mistyped, e.g. boxed into an Any
                // slot). A constructor that does not form a type is `.unresolved`
                // and is not a numeric fold. Cross-type error cases fall through
                // (lowerNumericLimit emits the diagnostic).
                {
                    // The receiver classifier is `lowerNumericLimit`'s own, so
                    // inference and lowering recognize the same receivers —
                    // spellings and constructors alike, and neither folds
                    // through a raw value binding that shadows a type name.
                    if (self.l.limitReceiverType(fa.object)) |t| {
                        if (t == .unresolved) return .unresolved;
                        const folds = (TypeResolver.isIntLimitField(fa.field) and
                            self.l.module.types.isIntegerType(t)) or
                            TypeResolver.floatLimitOf(t, fa.field) != null;
                        if (folds) return t;
                    }
                }
                // `obj.class` on an Obj-C-class pointer returns Class (*void).
                if (std.mem.eql(u8, fa.field, "class")) {
                    if (self.l.objc().isObjcClassPointer(self.l.inferExprType(fa.object))) {
                        return self.l.module.types.ptrTo(.void);
                    }
                }
                // `obj.field` for an Obj-C `@ObjcProperty` field returns the field's type.
                if (self.l.lookupObjcPropertyOnPointer(fa.object, fa.field)) |prop| {
                    return self.l.resolveType(prop.field_type);
                }
                // sx-defined class state field returns the field's type.
                if (self.l.lookupObjcDefinedStateFieldOnPointer(fa.object, fa.field)) |info| {
                    return info.field_ty;
                }

                var obj_ty = self.l.inferExprType(fa.object);
                // A guard-narrowed optional local resolves through its
                // child for PLAIN access — mirrors the lowerFieldAccess
                // narrowing unwrap (two-resolver lockstep).
                // `?.` keeps the optional (the chain arm below).
                if (!fa.is_optional and !obj_ty.isBuiltin() and fa.object.data == .identifier) {
                    const nrw_info = self.l.module.types.get(obj_ty);
                    if (nrw_info == .optional and self.l.provenPresent(fa.object.data.identifier.name)) {
                        obj_ty = nrw_info.optional.child;
                    }
                }
                if (self.memberType(obj_ty, fa.field, fa.is_optional)) |ty| return ty;
                if (self.l.qualifiedErrorSet(fa.object)) |set_ty| return set_ty;
                // Bare `Enum.variant` — a qualified enum literal read as a VALUE
                // (its type is the enum). Mirrors the `lowerFieldAccess`
                // qualified-enum-literal path: object is a type NAME resolving to
                // an enum (not shadowed by a value binding / global
                // value) and `field` is a PAYLOADLESS variant. Without this, a
                // direct `go(E.x)` generic-arg inference (and a `hash_val(E.A)`
                // key) yielded `.unresolved` for the value's type.
                if (fa.object.data == .identifier) {
                    const oname = fa.object.data.identifier.name;
                    const shadowed = if (self.l.scope) |s| s.lookup(oname) != null else false;
                    if (!shadowed and !self.l.program_index.contains(.global, oname)) {
                        if (self.l.module.types.findByName(self.l.module.types.internString(oname))) |ty| {
                            if (!ty.isBuiltin() and self.l.isPayloadlessVariant(ty, fa.field)) return ty;
                        }
                    }
                }
                // Full qualified terminal (`alias.CONST` or
                // `facade.engine_alias.CONST`) — infer the selected author's
                // bare member while pinned to its exact target. Diagnostic-free:
                // lowering owns missing/ambiguous messages.
                if (self.l.qualifiedTypeName(node)) |path| {
                    defer self.l.alloc.free(path);
                    const root_end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
                    const root = path[0..root_end];
                    if (!self.l.identifierBindsVisibleValue(root)) {
                        switch (self.l.qualifiedMemberVerdict(path)) {
                            .selected => |sel| {
                                const synth = Node{ .span = node.span, .data = .{ .identifier = .{ .name = sel.member } } };
                                const saved_src = self.l.lexicalContext();
                                self.l.setAuthorContext(sel.author.id);
                                defer self.l.restoreLexicalContext(saved_src);
                                return self.l.inferExprType(&synth);
                            },
                            .not_qualified, .missing, .ambiguous => {},
                        }
                    }
                }

                // Qualified enum/global field object. Resolve the complete
                // object prefix (`lib.Mode` / `facade.engine_alias.Mode`) as an
                // exact namespace terminal, then type the final field.
                if (self.l.qualifiedTypeName(fa.object)) |path| {
                    defer self.l.alloc.free(path);
                    const root_end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
                    const root = path[0..root_end];
                    if (!self.l.identifierBindsVisibleValue(root)) {
                        switch (self.l.qualifiedMemberVerdict(path)) {
                            .selected => |sel| {
                                const saved_src = self.l.lexicalContext();
                                self.l.setAuthorContext(sel.author.id);
                                var global_info: ?program_index_mod.GlobalInfo = null;
                                if (self.l.program_index.lookup(.global, sel.member)) |fallback| {
                                    switch (self.l.selectGlobalAuthor(sel.member)) {
                                        .resolved => |g| global_info = g,
                                        .untracked => global_info = fallback,
                                        else => {},
                                    }
                                }
                                self.l.restoreLexicalContext(saved_src);
                                if (global_info) |gi| return self.l.resolveFieldType(gi.ty, fa.field);
                                switch (self.l.selectNominalLeaf(sel.member, self.l.program_index.declaration(sel.author.id).environment.?, false)) {
                                    .resolved => |ty| if (!ty.isBuiltin() and self.l.isPayloadlessVariant(ty, fa.field)) return ty,
                                    else => {},
                                }
                            },
                            .not_qualified, .missing, .ambiguous => {},
                        }
                    }
                }
                return .unresolved;
            },
            .identifier => |id| {
                if (self.l.scope) |scope| {
                    if (scope.lookup(id.name)) |binding| {
                        // An `inline for` element capture types as the
                        // synthesized `<iterable>[<i>]` it aliases.
                        if (binding.alias_node) |elem| return self.l.inferExprType(elem);
                        return binding.ty;
                    }
                }
                // `context` is the implicit-ctx identifier; type is Context
                // when the program has registered it (i.e. std.sx imported).
                if (self.l.implicit_ctx_enabled and std.mem.eql(u8, id.name, "context")) {
                    if (self.l.module.types.findByName(self.l.module.types.internString("Context"))) |ty| return ty;
                }
                // Check global variables (e.g., `context : Context`) —
                // source-aware: infer the AUTHOR's global type,
                // never an unrelated module's same-named one. `.not_a_global`
                // falls through to the const / fn arms below.
                if (self.l.program_index.lookup(.global, id.name)) |gi| {
                    switch (self.l.selectGlobalAuthor(id.name)) {
                        .resolved => |g| return g.ty,
                        .untracked => return gi.ty,
                        .ambiguous, .not_visible => return .unresolved,
                        .not_a_global => {},
                    }
                }
                // Check module-level value constants (e.g., WIDTH :f32: 800).
                // A same-name VALUE const must infer the SOURCE-AWARE author's
                // TYPE (own-wins / one-flat-visible), not the global last-wins
                // `module_const_map` — otherwise a return-type / coercion inferred
                // on one module's `K` borrows another module's `K` TYPE. The global
                // map still gates "is this a const name at all?"; `.none` is the
                // registration-only author with no per-source partition (emit its
                // global type), and an ambiguous bare reference yields `.unresolved`
                // (the emission path diagnoses the ambiguity loudly).
                if (self.l.program_index.lookup(.module_const, id.name)) |ci_global| {
                    return switch (self.l.selectModuleConst(id.name)) {
                        .resolved => |sel| sel.info.ty,
                        .none => ci_global.ty,
                        .own_opaque, .ambiguous => .unresolved,
                    };
                }
                // A bare type name (alias like `Vec4`, struct name, or
                // builtin primitive) referenced in expression position
                // is a Type value — IR type `.type_value` (8-byte handle). A
                // BACKTICK raw identifier (`` `string ``) is explicitly a value
                // binding, never the reserved type — so it never resolves here as a
                // Type (it was found in scope above, or is genuinely unresolved).
                if (!id.is_raw and self.l.isKnownTypeName(id.name)) return .type_value;
                return .unresolved;
            },
            .type_expr => |te| {
                // type_expr can also be a variable reference (e.g., "i32" matches builtin i32 type)
                if (self.l.scope) |scope| {
                    if (scope.lookup(te.name)) |binding| {
                        return binding.ty;
                    }
                }
                // A bare type name in expression position (e.g. `i64`,
                // `Point`, `*u8`) is a Type value — IR type `.type_value`.
                if (self.l.isKnownTypeName(te.name)) return .type_value;
                return .unresolved;
            },
            .enum_literal => {
                // Enum literals depend on context — use target_type if available
                return self.l.target_type orelse .unresolved;
            },
            .struct_literal => |sl| {
                if (sl.struct_name) |name| {
                    // Source-aware first, so a head that is a type ALIAS
                    // (`BoxI :: Box(i64)`) infers the type it names — the
                    // global `findByName` below knows only registered type
                    // NAMES and would mint a stub under the alias spelling.
                    const leaf: ?TypeId = if (self.l.current_source_file) |from| switch (self.l.selectNominalLeaf(name, self.l.environmentForSource(from).?, false)) {
                        .resolved => |tid| tid,
                        else => null,
                    } else null;
                    if (leaf) |tid| if (self.l.hasPlainStructAuthor(tid)) return tid;
                    // A bare generic head is the instance its fields infer.
                    {
                        const saved_diag = self.l.diagnostics;
                        self.l.diagnostics = null;
                        defer self.l.diagnostics = saved_diag;
                        switch (self.l.selectGenericStructHead(name, null, false, null)) {
                            .template => |tmpl| if (self.l.genericLiteralType(&sl, &tmpl)) |tid| return tid,
                            else => {},
                        }
                    }
                    if (leaf) |tid| return tid;
                    const name_id = self.l.module.types.internString(name);
                    return self.l.module.types.findByName(name_id) orelse
                        self.l.module.types.intern(.{ .@"struct" = .{ .name = name_id, .fields = &.{} } });
                }
                // A qualified (`m.Cfg{…}`) or generic (`Pair(i32){…}`) prefix
                // carries its type as a NODE — resolve it the same way lowering
                // does, so a `:=`-inferred decl gets the real struct type,
                // not the empty `{}` it would fall to below.
                if (sl.type_expr) |te| {
                    // An error member's brace group holds its payload, so the
                    // literal IS a channel value of the set the head names.
                    if (self.l.qualifiedErrorMember(te)) |qm| return qm.set;
                    // `Ev.key{ ... }` — qualified payload enum variant
                    // construction: the literal's TYPE is the payload enum
                    // `Ev`, not a resolvable `Ev.key` type. Recognize it here
                    // (side-effect-free `findByName`) so inference doesn't fall
                    // to the type_bridge "field_access in type position"
                    // warning; lowering routes the same shape.
                    if (te.data == .field_access) {
                        const fa = te.data.field_access;
                        if (self.l.qualifiedTypeName(fa.object)) |path| {
                            defer self.l.alloc.free(path);
                            switch (self.l.qualifiedMemberVerdict(path)) {
                                .selected => |sel| switch (self.l.selectNominalLeaf(sel.member, self.l.program_index.declaration(sel.author.id).environment.?, false)) {
                                    .resolved => |oty| if (!oty.isBuiltin() and self.l.module.types.get(oty) == .@"enum" and self.l.module.types.get(oty).@"enum".hasPayload()) return oty,
                                    else => {},
                                },
                                .not_qualified, .missing, .ambiguous => {},
                            }
                        }
                        const obj_name: ?[]const u8 = switch (fa.object.data) {
                            .identifier => |id| id.name,
                            .type_expr => |t| t.name,
                            else => null,
                        };
                        if (obj_name) |on| {
                            const oid = self.l.module.types.internString(on);
                            if (self.l.module.types.findByName(oid)) |oty| {
                                if (self.l.module.types.get(oty) == .@"enum" and self.l.module.types.get(oty).@"enum".hasPayload()) return oty;
                            }
                        }
                    }
                    // A `.X{ … }` head names a variant, never a type — what it
                    // builds is the contextual target's, settled below.
                    if (te.data != .enum_literal) {
                        const ty = self.l.resolveTypeWithBindings(te);
                        if (ty != .unresolved) return ty;
                    }
                }
                // A bare `.{ … }` adopts the contextual target only when the
                // target is a shape the literal can actually BUILD (the same
                // classification lowering gates on, plus the union/optional
                // intercepts). A scalar ambient target (an enclosing fn's int
                // return type leaking into a call arg) must not type the
                // literal — it would mistype `$T` bindings before the literal
                // ever lowers.
                if (self.l.target_type) |tt| {
                    const usable = switch (self.l.module.types.get(tt)) {
                        .@"struct", .array, .vector, .slice, .closure, .@"union", .optional, .failable => true,
                        .@"enum" => |e| e.hasPayload(),
                        else => false,
                    };
                    if (usable) return tt;
                }
                return self.l.inferAnonStructType(&sl);
            },
            .array_literal => |al| self.l.arrayLiteralType(&al) catch .unresolved,
            .tuple_literal => |tl| {
                // Explicitly-typed construction with a type prefix: the literal's type is
                // the carried tuple type (preserves field names for the named
                // form), exactly like `Name{ ... }` infers to `Name`.
                if (tl.type_expr) |te| {
                    const tuple_ty = self.l.resolveTypeWithBindings(te);
                    if (tuple_ty != .unresolved) return tuple_ty;
                }
                var field_types = std.ArrayList(TypeId).empty;
                defer field_types.deinit(self.l.alloc);
                // Preserve the literal's element names (the NAMED-tuple form
                // `.(a = x, b = y)`) so the inferred type carries them — this is
                // the type bound to a generic `$T` when a named-tuple literal is
                // passed DIRECTLY as a call argument, and the labels a reflected
                // `.name` answers. Mirrors `lowerTupleLiteral`'s name capture so
                // the inferred type and the lowered value's type agree.
                var names = std.ArrayList(types.StringId).empty;
                defer names.deinit(self.l.alloc);
                var has_names = false;
                for (tl.elements) |elem| {
                    field_types.append(self.l.alloc, self.l.inferExprType(elem.value)) catch unreachable;
                    if (elem.name) |name| {
                        names.append(self.l.alloc, self.l.module.types.internString(name)) catch unreachable;
                        has_names = true;
                    } else {
                        names.append(self.l.alloc, self.l.module.types.internString("")) catch unreachable;
                    }
                }
                return self.l.module.types.internFieldsAsProductOrFailable(
                    self.l.alloc.dupe(TypeId, field_types.items) catch unreachable,
                    if (has_names) self.l.alloc.dupe(types.StringId, names.items) catch unreachable else null,
                );
            },
            .index_expr => |ie| {
                // Pack-arg type lookup: `<pack_name>[<int_literal>]`.
                // Read directly from `pack_arg_types` — bypasses the
                // synthesized-ident detour in `pack_arg_nodes` which
                // would otherwise lose the type when the mono's
                // scope isn't set up yet (generic-`$R` pre-inference).
                if (self.l.pack_arg_types) |pat| {
                    if (ie.object.data == .identifier) {
                        if (pat.get(ie.object.data.identifier.name)) |arg_tys| {
                            if (self.l.comptimeIndexOf(ie.index)) |raw| {
                                if (raw >= 0) {
                                    const i: usize = @intCast(raw);
                                    if (i < arg_tys.len) return arg_tys[i];
                                }
                            }
                        }
                    }
                }
                if (self.l.packArgNodeAt(&ie)) |arg_node| {
                    return self.l.inferExprType(arg_node);
                }
                // A guard-narrowed container local indexes its payload — the
                // lockstep partner of `lowerIndexExpr`'s narrowing peel.
                const obj_ty = self.l.narrowedContainerChild(ie.object) orelse self.l.inferExprType(ie.object);
                return self.indexType(obj_ty) orelse .unresolved;
            },
            .slice_expr => |se| {
                const obj_ty = self.l.narrowedContainerChild(se.object) orelse self.l.inferExprType(se.object);
                return self.sliceType(obj_ty, se.end == null) orelse .unresolved;
            },
            .deref_expr => |de| {
                const ptr_ty = self.l.inferExprType(de.operand);
                if (!ptr_ty.isBuiltin()) {
                    const info = self.l.module.types.get(ptr_ty);
                    if (info == .pointer) return info.pointer.pointee;
                }
                return .unresolved;
            },
            .self_block => |sb| self.inferType(sb.operand),
            // Postfix cast: the expression's type IS the written target;
            // the chained form yields `?T` (an optional target flattens).
            .postfix_cast => |pc| blk: {
                const t = self.l.resolveTypeArg(pc.type_expr);
                if (t == .unresolved) break :blk t;
                var v = t;
                if (pc.is_optional_chain) {
                    const t_is_opt = !t.isBuiltin() and self.l.module.types.get(t) == .optional;
                    v = if (t_is_opt) t else self.l.module.types.optionalOf(t);
                }
                if (!pc.consumed) break :blk v;
                const set = self.l.castErrorSet();
                break :blk if (set == .unresolved) set else self.l.module.types.internFailable(v, set);
            },
            .chained_comparison => .bool,
            .null_coalesce => |nc| blk: {
                // A failable `??` (value-terminator or chain) yields the
                // chain's success type (the error is absorbed/propagated).
                // Detected structurally — a `try`-chain's operands type as
                // non-failable `T`, so a type-only check would miss it.
                if (self.l.coalesceIsFailable(&nc)) break :blk self.l.coalesceChainSuccessType(&nc);
                // `opt ?? default` — result is the inner type when lhs is
                // optional (the unwrap path's value), else falls back to
                // the rhs's type. Without this arm pack-fn callers
                // misinferred float-optional coalesces as i64 and the
                // pack mono mangled the arg as int — the actual f64 value
                // got truncated through Any boxing.
                const lhs_ty = self.l.inferExprType(nc.lhs);
                if (!lhs_ty.isBuiltin()) {
                    const info = self.l.module.types.get(lhs_ty);
                    if (info == .optional) break :blk info.optional.child;
                }
                break :blk self.l.inferExprType(nc.rhs);
            },
            // A lambda literal's type is the closure it denotes, recovered from
            // its annotations. The generic-call binder types args from the raw
            // AST (notably the UFCS path, before args are lowered), so without
            // this a `Closure(..) -> $R` worker couldn't bind `$R` from the
            // lambda's declared return type. An unannotated param /
            // body-inferred return stays `.unresolved` here — that arg simply
            // doesn't contribute a binding, exactly as before.
            .lambda => |*lam| blk: {
                if (lower_closure.hasFormationParam(lam))
                    break :blk self.l.lambdaEnvType(lam) orelse .unresolved;
                var pbuf = std.ArrayList(TypeId).empty;
                defer pbuf.deinit(self.l.alloc);
                for (lam.params) |p| {
                    const pty: TypeId = if (p.type_expr.data == .inferred_type)
                        .unresolved
                    else
                        self.l.resolveTypeWithBindings(p.type_expr);
                    pbuf.append(self.l.alloc, pty) catch {};
                }
                const ret: TypeId = if (lam.return_type) |rt|
                    self.l.resolveTypeWithBindings(rt)
                else
                    .unresolved;
                break :blk self.l.module.types.closureType(pbuf.items, ret);
            },
            // Inline asm result type (0→void, 1→T, N→named tuple) — the single
            // owner is `Lowering.asmResultType`, shared with `lowerAsmExpr` so a
            // `return asm`, a `x := asm`, and a `q, r := asm` destructure all
            // agree on the type.
            .asm_expr => |ae| self.l.asmResultType(&ae),
            // Statements don't produce values (`.return_stmt` is handled above
            // as `.noreturn` — it diverges rather than yielding `void`).
            .assignment,
            .var_decl,
            .const_decl,
            .fn_decl,
            .defer_stmt,
            .push_stmt,
            .multi_assign,
            .destructure_decl,
            => .void,
            else => .unresolved,
        };
    }
};
