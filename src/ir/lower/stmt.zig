const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");
const inst_mod = @import("../inst.zig");
const mod_mod = @import("../module.zig");
const program_index_mod = @import("../program_index.zig");
const errors = @import("../../errors.zig");

const TypeId = types.TypeId;
const Ref = inst_mod.Ref;
const Module = mod_mod.Module;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;
const Scope = lower.Scope;
const Binding = lower.Binding;

pub fn lowerBlock(self: *Lowering, node: *const Node) void {
    // Statement-mode lowering: every statement here is a STATEMENT, not a value.
    // Clear `force_block_value` so it can't LEAK from an enclosing value context
    // (e.g. a void closure body lowered inside `f := closure((..) { if c {..} })`
    // — the outer `:=` RHS left `force_block_value` set) and make a no-`else`
    // guard-`if` look like a value use (0270 false positive). Value-producing
    // sub-lowerings (var-decl / assignment RHS, etc.) re-enable it locally.
    const saved_fbv_block = self.force_block_value;
    self.force_block_value = false;
    defer self.force_block_value = saved_fbv_block;
    switch (node.data) {
        .block => |blk| {
            // Create a child scope for block-level variable shadowing
            var block_scope = Scope.init(self.alloc, self.scope);
            const saved_scope = self.scope;
            self.scope = &block_scope;
            const saved_defer_len = self.defer_stack.items.len;
            // Flow narrowing (issue 0179) is block-scoped: a guard inside this
            // block narrows the rest of THIS block, no further.
            var narrow_snap = self.narrowSnapshot();
            defer {
                self.emitBlockDefers(saved_defer_len);
                self.scope = saved_scope;
                block_scope.deinit();
                self.narrowRestore(&narrow_snap);
            }
            for (blk.stmts) |stmt| {
                if (self.block_terminated) break;
                self.lowerStmt(stmt);
                // A bare `return`/`raise` mid-block terminates the current
                // basic block but deliberately does NOT set `block_terminated`
                // (that flag would leak past an `if cond { return }` merge
                // block, skipping its trailing statements — see lowerReturn).
                // Stop here so dead statements after the terminator aren't
                // emitted into an already-closed block (invalid LLVM IR).
                if (self.currentBlockHasTerminator()) break;
            }
        },
        else => {
            // Single expression as body (arrow functions)
            self.lowerStmt(node);
        },
    }
}

/// Lower an `inline if` branch — block body emits statements, expression returns value.
pub fn lowerInlineBranch(self: *Lowering, node: *const Node) Ref {
    if (node.data == .block) {
        self.lowerBlock(node);
        // A `return` inside the branch terminates the current LLVM block; propagate
        // that up so the enclosing block lowering stops emitting fall-through.
        if (self.currentBlockHasTerminator()) {
            self.block_terminated = true;
            return .none;
        }
        return self.builder.constInt(0, .void);
    }
    return self.lowerExpr(node);
}

/// A block-form `if` with no `else` (and not the inline `if … then …` form) —
/// a valueless guard statement. As the implicit tail of a block/body it must
/// NOT be forced into value-mode (see `lowerBlockValue`).
fn isNoElseValuelessIf(node: *const Node) bool {
    return node.data == .if_expr and
        node.data.if_expr.else_branch == null and
        !node.data.if_expr.is_inline;
}

/// Lower a block and return the last expression's value (for implicit returns).
pub fn lowerBlockValue(self: *Lowering, node: *const Node) ?Ref {
    // Set force_block_value so nested if-else expressions produce values
    const saved = self.force_block_value;
    self.force_block_value = true;
    defer self.force_block_value = saved;

    switch (node.data) {
        .block => |blk| {
            if (blk.stmts.len == 0) return null;
            // Create a child scope for block-level variable shadowing
            var block_scope = Scope.init(self.alloc, self.scope);
            const saved_scope = self.scope;
            self.scope = &block_scope;
            const saved_defer_len = self.defer_stack.items.len;
            var narrow_snap = self.narrowSnapshot();
            defer {
                self.emitBlockDefers(saved_defer_len);
                self.scope = saved_scope;
                block_scope.deinit();
                self.narrowRestore(&narrow_snap);
            }
            // A block whose last statement is `;`-terminated (or not an
            // expression) discards its value: lower every statement as a
            // statement and yield nothing.
            if (!blk.produces_value) {
                self.force_block_value = false;
                for (blk.stmts) |stmt| {
                    if (self.block_terminated) return null;
                    self.lowerStmt(stmt);
                    if (self.currentBlockHasTerminator()) return null;
                }
                return null;
            }
            // Lower all statements except the last normally
            self.force_block_value = false; // don't force for non-last statements
            for (blk.stmts[0 .. blk.stmts.len - 1]) |stmt| {
                if (self.block_terminated) return null;
                self.lowerStmt(stmt);
                // A bare `return`/`raise` mid-block closes the current basic
                // block (without setting `block_terminated`); the remaining
                // statements — including the value-expr — are dead.
                if (self.currentBlockHasTerminator()) return null;
            }
            if (self.block_terminated) return null;
            // Last statement (no trailing `;`): its value is the block's.
            const last = blk.stmts[blk.stmts.len - 1];
            // A no-`else` block-`if` tail is a valueless GUARD statement, not a
            // value expression — e.g. `-> !MyErr { if x < 0 { raise … } }`, where
            // falling off the end is a success return. Do NOT force value-mode for
            // it (that would make `lowerIfExpr` flag it as "an `if` used as a value
            // must have an `else` branch"). Lowered as a statement it yields no
            // value; a value-returning function's missing tail value is still
            // caught downstream by `lowerValueBody`'s "body produces no value".
            self.force_block_value = !isNoElseValuelessIf(last);
            return self.tryLowerAsExpr(last);
        },
        else => {
            // Single expression as body (arrow functions)
            return self.tryLowerAsExpr(node);
        },
    }
}

/// Lower a value-returning function body and emit the implicit return.
/// Emits a hard error when the body yields no value — its last statement is
/// `;`-terminated (value discarded) or void — and the body doesn't already
/// terminate via `return`/`raise`. Replaces the old silent default-return.
pub fn lowerValueBody(self: *Lowering, body: *const Node, ret_ty: TypeId) void {
    // Snapshot the ERROR count so the missing-value error below can be
    // suppressed when the body ALREADY reported a real error (e.g. an explicit
    // `return <pack>` where the pack has no runtime value). Count only `.err`
    // diagnostics — a warning/note emitted while lowering the body (e.g. an
    // ObjC selector arity warning) must NOT suppress a genuine missing-value
    // error, or we'd ship an uninitialized return at exit 0.
    const errs_before: usize = if (self.diagnostics) |d| d.errorCount() else 0;
    const body_val = self.lowerBlockValue(body);
    if (self.currentBlockHasTerminator()) return;
    if (body_val) |val| {
        const val_ty = self.builder.getRefType(val);
        if (val_ty != .void) {
            const span = blk: {
                if (body.data == .block) {
                    const stmts = body.data.block.stmts;
                    if (stmts.len > 0) break :blk stmts[stmts.len - 1].span;
                }
                break :blk body.span;
            };
            // Value-carrying failable `-> (T..., !)`: a trailing success
            // EXPRESSION (no explicit `return`) yields just the value part —
            // the compiler must append the success error slot (0). Mirror the
            // explicit-`return EXPR;` path; a plain `coerceToType` would leave
            // the error-tag slot uninitialized (phantom catch on success).
            if (!ret_ty.isBuiltin() and
                self.module.types.get(ret_ty) == .tuple and
                self.errorChannelOf(ret_ty) != null)
            {
                self.lowerFailableSuccessReturn(val, ret_ty, span);
                return;
            }
            // Issue 0191: a trailing value with NO modeled coercion to the
            // declared return type used to be bit-welded into the return slot
            // (a `string` body "returning" i64 shipped the pointer as the
            // int). Diagnose; on failure skip the coerce (the build aborts
            // via hasErrors before this ret could run).
            const coerced = if (self.checkReturnable(val, val_ty, ret_ty, span))
                self.coerceToType(val, val_ty, ret_ty)
            else
                val;
            self.builder.ret(coerced, ret_ty);
            return;
        }
    }
    // A NAMED multi-return function (`-> (x: A, y: B)`) with no explicit
    // `return`: synthesize the implicit return from the named slot LOCALS (which
    // the body assigned). The must-set rule is checked here — an unset, undefaulted
    // slot is a loud error, not a silent fill. This takes precedence over the
    // "produces no value" diagnostic below (the body legitimately produces its
    // result by assigning the slots, not via a trailing expression).
    if (self.named_return_names) |names| {
        self.synthesizeNamedReturn(body, ret_ty, names);
        return;
    }
    // A PURE-failable function (`-> !` / `-> !Named`, whose entire return IS
    // the error channel) carries no success value — a void body is a normal
    // success exit, not a missing value. `ensureTerminator` emits the
    // error-slot-zero success return.
    if (self.errorChannelOf(ret_ty)) |chan| {
        if (chan == ret_ty) {
            self.ensureTerminator(ret_ty);
            return;
        }
    }
    if (self.diagnostics) |diags| {
        // Only the body produced no value AND no error was reported while
        // lowering it — a genuine "missing trailing value", not the fallout of
        // an already-diagnosed failed return. (If a real error fired, surfacing
        // the redundant missing-value note would just be noise.)
        if (diags.errorCount() == errs_before) {
            if (body.data == .block and body.data.block.discarded_semi != null) {
                diags.addFmt(.err, body.data.block.discarded_semi.?, "function returns '{s}' but the last expression's value is discarded by this `;` — drop the `;` to return it (or use an explicit `return`)", .{self.formatTypeName(ret_ty)});
            } else {
                const span = blk: {
                    if (body.data == .block) {
                        const stmts = body.data.block.stmts;
                        if (stmts.len > 0) break :blk stmts[stmts.len - 1].span;
                    }
                    break :blk body.span;
                };
                diags.addFmt(.err, span, "function returns '{s}' but its body produces no value — end it with a trailing expression (no `;`) or an explicit `return`", .{self.formatTypeName(ret_ty)});
            }
        }
    }
    self.ensureTerminator(ret_ty);
}

/// Definite-assignment check for the named-return must-set rule: true iff every
/// non-diverging path through `node` assigns the bare identifier `name` (or
/// diverges via `return`/`raise` before reaching the implicit return). PATH-
/// SENSITIVE — a slot set in only ONE branch of an `if` (no `else`) is NOT
/// definitely assigned, so it errors instead of returning a stale/garbage value.
///   - `return`/`raise` → vacuously true (that path never reaches the implicit
///     return, so the slot need not be set on it).
///   - block → the FIRST statement that definitely assigns (or diverges) settles
///     it (sequential composition).
///   - `if` → both branches must (an `if` with no `else` cannot).
///   - `push { … }` → always runs its body.
///   - `match` → all arms must AND there is an `else` arm (exhaustiveness).
///   - `while`/`for`/`defer`/`catch` and everything else → not guaranteed.
/// Does not descend into nested function / lambda bodies (their `return`s own).
fn definitelyAssigns(node: *const Node, name: []const u8) bool {
    return switch (node.data) {
        .assignment => |a| a.target.data == .identifier and std.mem.eql(u8, a.target.data.identifier.name, name),
        .multi_assign => |ma| blk: {
            for (ma.targets) |t| {
                if (t.data == .identifier and std.mem.eql(u8, t.data.identifier.name, name)) break :blk true;
            }
            break :blk false;
        },
        // Function-level divergence — this path never reaches the implicit return.
        .return_stmt, .raise_stmt => true,
        .block => |blk| {
            for (blk.stmts) |s| if (definitelyAssigns(s, name)) return true;
            return false;
        },
        .if_expr => |ie| ie.else_branch != null and
            definitelyAssigns(ie.then_branch, name) and definitelyAssigns(ie.else_branch.?, name),
        .push_stmt => |ps| definitelyAssigns(ps.body, name),
        .match_expr => |me| blk: {
            var has_else = false;
            for (me.arms) |arm| {
                if (arm.pattern == null) has_else = true;
                if (!definitelyAssigns(arm.body, name)) break :blk false;
            }
            break :blk has_else;
        },
        else => false,
    };
}

/// Bind a NAMED multi-return signature's value slots (`-> (x: A, y: B)`) as
/// in-scope assignable locals, so the body's `x = …` writes to them. Each slot
/// is a zero-initialized alloca (deterministic value if a path misses it — see
/// `bodyAssignsTo`). Sets `self.named_return_names`; the caller restores it.
/// No-op for a positional multi-return (no names → use an explicit `return`).
pub fn bindNamedReturnSlots(self: *Lowering, fd: *const ast.FnDecl, ret_ty: TypeId, scope: *Scope) void {
    const rt = fd.return_type orelse return;
    if (rt.data != .return_type_expr) return;
    const names = rt.data.return_type_expr.field_names orelse return; // positional → no locals
    const defaults = rt.data.return_type_expr.field_defaults;
    if (ret_ty.isBuiltin()) return;
    const ti = self.module.types.get(ret_ty);
    if (ti != .tuple) return;
    const fields = ti.tuple.fields;
    const value_count = if (self.errorChannelOf(ret_ty) != null) fields.len - 1 else fields.len;
    var i: usize = 0;
    while (i < value_count and i < names.len) : (i += 1) {
        const nm = names[i];
        if (nm.len == 0 or std.mem.eql(u8, nm, "!")) continue;
        // A named-return slot that shadows a PARAMETER of the same name would
        // silently hide the parameter behind a fresh local — reject the collision.
        for (fd.params) |p| {
            if (std.mem.eql(u8, p.name, nm)) {
                if (self.diagnostics) |d| {
                    d.addFmt(.err, rt.span, "named return '{s}' collides with a parameter of the same name — rename one", .{nm});
                }
            }
        }
        const fty = fields[i];
        const slot = self.builder.alloca(fty);
        // Seed the slot. A slot with a DEFAULT gets it (type-checked, lowered,
        // coerced). Otherwise zero/default-init for ANY type (a deterministic
        // value if the path-insensitive must-set can't prove a path sets it —
        // never raw garbage; covers string / struct / float slots too).
        const dflt: ?*const Node = if (defaults) |ds| (if (i < ds.len) ds[i] else null) else null;
        if (dflt) |dn| {
            const saved_target = self.target_type;
            self.target_type = fty;
            const dval = self.lowerExpr(dn);
            self.target_type = saved_target;
            const dval_ty = self.builder.getRefType(dval);
            // Reject a default whose type has NO coercion to the slot type and a
            // mismatched byte width (e.g. `sum: i32 = "hi"`) — a `.none` plan
            // would pass the value through unchanged and overrun / under-fill the
            // slot, corrupting memory (the same guard as plain annotated
            // assignment, issue 0197). A same-width `.none` (`p: *void = typed_ptr`)
            // is a legitimate reinterpretation and stays allowed.
            if (!self.externalErrorsExist() and dval_ty != .unresolved and self.noneReinterpretIsUnsafe(dval_ty, fty)) {
                if (self.diagnostics) |d| {
                    d.addFmt(.err, dn.span, "named return '{s}' has a default of type '{s}' that does not match its declared type '{s}'", .{ nm, self.formatTypeName(dval_ty), self.formatTypeName(fty) });
                    self.assignability_error_count += 1;
                }
                self.builder.store(slot, self.buildDefaultValue(fty));
            } else {
                self.builder.store(slot, self.coerceToType(dval, dval_ty, fty));
            }
        } else {
            self.builder.store(slot, self.buildDefaultValue(fty));
        }
        scope.put(nm, .{ .ref = slot, .ty = fty, .is_alloca = true });
    }
    self.named_return_names = names;
    self.named_return_defaults = defaults;
}

/// Emit the implicit return of a NAMED multi-return body: enforce the must-set
/// rule on each value slot, then synthesize and lower `return n0 = n0, n1 = n1`
/// over the slot locals — reusing the ordinary return path (tuple build +
/// value-carrying-failable assembly), so failable named multi-returns work too.
pub fn synthesizeNamedReturn(self: *Lowering, body: *const Node, ret_ty: TypeId, names: []const []const u8) void {
    const ti = self.module.types.get(ret_ty);
    if (ti != .tuple) {
        self.ensureTerminator(ret_ty);
        return;
    }
    const fields = ti.tuple.fields;
    const value_count = if (self.errorChannelOf(ret_ty) != null) fields.len - 1 else fields.len;

    var elems = std.ArrayList(ast.TupleElement).empty;
    defer elems.deinit(self.alloc);
    var i: usize = 0;
    while (i < value_count and i < names.len) : (i += 1) {
        const nm = names[i];
        if (nm.len == 0 or std.mem.eql(u8, nm, "!")) continue;
        // Must-set: a slot not DEFINITELY assigned (on every non-diverging path)
        // and with no default is an error. A defaulted slot is exempt — its
        // default seeds the local in `bindNamedReturnSlots`.
        const has_default = if (self.named_return_defaults) |ds| (i < ds.len and ds[i] != null) else false;
        if (!has_default and !definitelyAssigns(body, nm)) {
            if (self.diagnostics) |d| {
                d.addFmt(.err, body.span, "named return '{s}' may be unset (not assigned on every path) and has no default — assign it on every path, give it a default, or end with an explicit `return`", .{nm});
            }
        }
        const id_node = self.alloc.create(Node) catch return;
        id_node.* = .{ .span = body.span, .data = .{ .identifier = .{ .name = nm } } };
        elems.append(self.alloc, .{ .name = nm, .value = id_node }) catch return;
    }
    const tl = self.alloc.create(Node) catch return;
    tl.* = .{ .span = body.span, .data = .{ .tuple_literal = .{ .elements = elems.toOwnedSlice(self.alloc) catch return } } };
    const rs = ast.ReturnStmt{ .value = tl };
    self.lowerReturn(&rs);
}

/// Try to lower a node as an expression, returning its value.
/// Statement nodes are lowered as statements (returning null).
pub fn tryLowerAsExpr(self: *Lowering, node: *const Node) ?Ref {
    return switch (node.data) {
        .var_decl, .const_decl, .fn_decl, .return_stmt, .raise_stmt, .assignment, .defer_stmt, .push_stmt, .multi_assign, .destructure_decl => {
            self.lowerStmt(node);
            return null;
        },
        else => self.lowerExpr(node),
    };
}

pub fn lowerStmt(self: *Lowering, node: *const Node) void {
    // Stamp this statement's span onto its instructions (ERR E3.0); see
    // `lowerExpr`.
    const saved_span = self.builder.current_span;
    defer self.builder.current_span = saved_span;
    if (node.span.start != 0 or node.span.end != 0) self.builder.current_span = .{ .start = node.span.start, .end = node.span.end };
    switch (node.data) {
        .var_decl => |vd| self.lowerVarDecl(&vd),
        .const_decl => |cd| self.lowerConstDecl(&cd),
        // Pointer capture, not by-value: `lowerLocalFnDecl` registers the
        // decl pointer in `fn_ast_map`, so it must point into the AST node,
        // not at a stack temporary that the next statement reuses.
        .fn_decl => |*fd| self.lowerLocalFnDecl(fd),
        .return_stmt => |rs| self.lowerReturn(&rs),
        .raise_stmt => |rs| self.lowerRaise(&rs, node.span),
        .assignment => |asgn| self.lowerAssignment(&asgn),
        .defer_stmt => |ds| self.lowerDefer(&ds),
        .onfail_stmt => |ofs| self.lowerOnFail(&ofs, node.span),
        .push_stmt => |ps| self.lowerPush(&ps),
        .multi_assign => |ma| self.lowerMultiAssign(&ma),
        .destructure_decl => |dd| self.lowerDestructureDecl(&dd),
        .insert_expr => |ins| self.lowerInsertExpr(ins.expr),
        .block => self.lowerBlock(node),
        .jni_env_block => |eb| {
            // Compile-time stack push for lexical-direct env resolution
            // (2.16b — `#jni_call` in the same fn picks up env from
            // jni_env_stack directly, no TL read).
            //
            // Runtime TL save/set/restore (2.16c) for cross-function
            // helpers: callees in OTHER fns invoked from inside the
            // body read the slot via `sx_jni_env_tl_get`. Storage
            // lives in a separately-linked C helper (see
            // library/vendors/sx_jni_runtime/sx_jni_env_tl.c) so the
            // JIT doesn't need orc_rt for TLS.
            const env_ref = self.lowerExpr(eb.env);
            const fids = self.getJniEnvTlFids();
            const ptr_ty = self.module.types.ptrTo(.void);
            const saved_tl = self.builder.emit(.{ .call = .{ .callee = fids.get, .args = &.{} } }, ptr_ty);
            const set_args = self.alloc.dupe(Ref, &.{env_ref}) catch unreachable;
            _ = self.builder.emit(.{ .call = .{ .callee = fids.set, .args = set_args } }, .void);
            self.jni_env_stack.append(self.alloc, env_ref) catch unreachable;
            self.lowerBlock(eb.body);
            _ = self.jni_env_stack.pop();
            const restore_args = self.alloc.dupe(Ref, &.{saved_tl}) catch unreachable;
            _ = self.builder.emit(.{ .call = .{ .callee = fids.set, .args = restore_args } }, .void);
        },
        // Block-local type declarations
        .struct_decl => |sd| {
            self.recordLocalTypeName(sd.name);
            self.registerStructDecl(&node.data.struct_decl, node.source_file orelse self.current_source_file);
        },
        .enum_decl => {
            if (node.data.declName()) |dn| self.recordLocalTypeName(dn);
            self.registerEnumDecl(&node.data.enum_decl);
        },
        .union_decl => {
            if (node.data.declName()) |dn| self.recordLocalTypeName(dn);
            self.registerUnionDecl(&node.data.union_decl);
        },
        .error_set_decl => {
            if (node.data.declName()) |dn| self.recordLocalTypeName(dn);
            self.registerErrorSetDecl(node);
        },
        .ufcs_alias => |ua| {
            self.program_index.ufcs_alias_map.put(ua.name, ua.target) catch {};
        },
        // Expression statement
        else => {
            const v = self.lowerExpr(node);
            // A statement-position expression that DIVERGES — a call to a
            // `-> noreturn` fn such as `proc.exit` — ends the basic block. A
            // bare `.call` op is NOT a terminator (see currentBlockHasTerminator),
            // so without emitting `unreachable` here the block stays "open": the
            // statements after it would be lowered into a closed-in-spirit block,
            // and — the bug this fixes — a diverging statement as the live branch
            // of an `inline if` leaves the enclosing function looking value-less,
            // tripping the "produces no value" check (issue 0209). Guard on the
            // block not already being terminated so we never double-terminate.
            if (!self.currentBlockHasTerminator() and self.builder.getRefType(v) == .noreturn) {
                self.builder.emitUnreachable();
            }
        },
    }
}

pub fn lowerVarDecl(self: *Lowering, vd: *const ast.VarDecl) void {
    if (vd.value) |val| {
        if (val.data == .identifier and self.isPackName(val.data.identifier.name)) {
            const ph = self.diagPackAsValue(val.data.identifier.name, val.span, .storage);
            // Bind the name to the placeholder so later uses don't cascade
            // into a second "unresolved" error after this one.
            if (self.scope) |scope| {
                scope.put(vd.name, .{ .ref = ph, .ty = .unresolved, .is_alloca = false });
            }
            return;
        }
    }
    if (vd.type_annotation) |ta| {
        // Explicit type annotation — resolve type first, then lower value
        _ = self.rejectMultiReturnValueType(ta, "variable");
        const ty = self.resolveType(ta);
        const slot = self.builder.alloca(ty);
        if (vd.value) |val| {
            if (val.data == .undef_literal and !ty.isBuiltin()) {
                const ti = self.module.types.get(ty);
                // = --- (undef_literal) on tuple types: zero-initialize
                if (ti == .tuple) {
                    var field_vals = std.ArrayList(Ref).empty;
                    defer field_vals.deinit(self.alloc);
                    for (ti.tuple.fields) |f| {
                        field_vals.append(self.alloc, self.builder.constInt(0, f)) catch unreachable;
                    }
                    const zero = self.builder.emit(.{
                        .tuple_init = .{ .fields = self.alloc.dupe(Ref, field_vals.items) catch unreachable },
                    }, ty);
                    self.builder.store(slot, zero);
                    if (self.scope) |scope| {
                        scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
                    }
                    return;
                }
                // `---` on an array: explicitly uninitialized — no store.
                // A whole-array undef store is a store of nothing that
                // LLVM's legalizer scalarizes into one DAG node per
                // element (issue 0124: SelectionDAG segfault at ~64K).
                if (ti == .array) {
                    if (self.scope) |scope| {
                        scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
                    }
                    return;
                }
            }
            // A compile-time float initializer narrowing into an integer
            // local follows the unified rule (integral folds, non-integral
            // errors); a runtime float / `xx` cast falls through to the
            // normal lower+coerce below.
            if (self.foldComptimeFloatInit(val, ty)) |folded| {
                self.builder.store(slot, folded);
                if (self.scope) |scope| {
                    scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
                }
                return;
            }
            const saved_target = self.target_type;
            const saved_fbv = self.force_block_value;
            self.target_type = ty;
            self.force_block_value = true;
            var ref = self.lowerExpr(val);
            self.target_type = saved_target;
            self.force_block_value = saved_fbv;
            // If target is optional and value isn't null, wrap with optional_wrap
            // — UNLESS the value is already that optional (e.g. a `?T`-returning
            // call, or a struct literal that lowered straight to `?T`); wrapping
            // again would build a `??`-shaped value typed `?T` and corrupt it /
            // fail LLVM verification (issue 0160).
            if (!ty.isBuiltin()) {
                const ty_info = self.module.types.get(ty);
                // Is the initializer value ITSELF an optional (`?A`)? If so the
                // target `?B` is a presence-PRESERVING coercion (`.optional_to_optional`),
                // NOT a wrap-present. The manual unwrap-to-child + `optionalWrap(present)`
                // below classifies `?A → child_B` as an unconditional unwrap (→ 0 for a
                // null source) then wraps it as always-present, so a null `?A` becomes a
                // present `?B` carrying zero (issue 0180). Route an optional source through
                // the trailing general `coerceToType(?A → ?B)` instead, which dispatches to
                // the presence-preserving arm. The wrap-present path below stays correct for
                // a non-optional source `T → ?T`.
                const ref_ty0 = self.builder.getRefType(ref);
                const src_is_optional = !ref_ty0.isBuiltin() and self.module.types.get(ref_ty0) == .optional;
                if (ty_info == .optional and val.data != .null_literal and ref_ty0 != ty and !src_is_optional) {
                    // Coerce to the optional's CHILD first (e.g. an array value
                    // into a `?[]T` promotes array→slice), THEN wrap — wrapping
                    // the raw value would store e.g. array bits into the slice
                    // payload and corrupt `.len`/`.ptr`.
                    const child = ty_info.optional.child;
                    const rt = self.builder.getRefType(ref);
                    if (rt != child and rt != .void and child != .void) {
                        // A protocol child erases NODE-AWARE (borrow-mode for
                        // an lvalue initializer, exactly like the plain
                        // `p : P = s` decl branch below) instead of through
                        // the node-less `coerceToType` value arm, which
                        // heap-boxes the receiver via context.allocator with
                        // no owner to ever free it (issue 0213).
                        if (self.getProtocolInfo(child) != null) {
                            ref = self.buildProtocolErasure(ref, val, rt, child);
                            // No progress (e.g. a builtin source with no
                            // node-inferable concrete type) → generic ladder,
                            // whose value arm erases via a self-contained copy.
                            const erased_ty = self.builder.getRefType(ref);
                            if (erased_ty != child) ref = self.coerceToType(ref, erased_ty, child);
                        } else {
                            ref = self.coerceToType(ref, rt, child);
                        }
                    }
                    // After coercion the value MUST be the optional's payload
                    // type. If it isn't (the coercion classified `.none` and
                    // passed the value through unchanged — e.g. a `?i64` value
                    // flowing into `?(?i64)`, whose payload is the 1-tuple
                    // `(?i64)`), wrapping anyway inserts a `{i64,i1}` into a
                    // `{{i64,i1}}` slot and builds malformed IR that aborts the
                    // LLVM verifier (issue 0165). Diagnose loudly instead.
                    const post_rt = self.builder.getRefType(ref);
                    if (post_rt != child and post_rt != .void and child != .void) {
                        if (self.diagnostics) |d| {
                            const cs = self.builder.current_span;
                            // Only mention the `(T)`-is-a-1-tuple gotcha when the
                            // payload actually IS a tuple (the `?(?T)` typo).
                            const note: []const u8 = if (self.module.types.get(child) == .tuple)
                                " (note: '(T,)' with a trailing comma is a 1-tuple; '(T)' without a comma groups to the inner type)"
                            else
                                "";
                            d.addFmt(.err, ast.Span{ .start = cs.start, .end = cs.end }, "cannot assign a value of type '{s}' to optional '{s}': its payload type is '{s}'{s}", .{ self.formatTypeName(post_rt), self.formatTypeName(ty), self.formatTypeName(child), note });
                        }
                        // Already diagnosed — store the value as-is and bail. The
                        // trailing coerce below would re-diagnose the same mismatch
                        // (via the `.optional_wrap` guard in coerce.zig); `hasErrors()`
                        // aborts the build regardless of the bytes we store.
                        self.builder.store(slot, ref);
                        if (self.scope) |scope| {
                            scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
                        }
                        return;
                    }
                    ref = self.builder.optionalWrap(ref, ty);
                } else if (ty_info == .slice) {
                    // Array → slice promotion when the initializer is an array
                    // value bound into a slice-typed local (`s : []T = arr`).
                    // For an ADDRESSABLE array (a named local/global/field)
                    // build a zero-copy VIEW over its storage (issue 0264,
                    // consistent with 0225's aliasing `arr[0..]` subslice), so
                    // a write through `s` reaches `arr`.
                    //
                    // For a NON-addressable rvalue array — an array LITERAL
                    // (`s : []string = .["a","b"]`) or a call result — KEEP the
                    // copying `array_to_slice` op. Its backing is a
                    // FUNCTION-ENTRY alloca (`buildEntryAlloca`) that lives as
                    // long as the binding `s` itself, so the view is NOT
                    // dangling — unlike a STORED SUBSLICE of a temporary
                    // (0225's rejected `makeArr()[0..]`, whose temp dies at the
                    // statement's end). The literal-into-a-slice-local form is
                    // ubiquitous and sound; nothing else aliases the copy, so
                    // there is no aliasing surprise to preserve. Do NOT reject.
                    const ref_ty = self.builder.getRefType(ref);
                    if (!ref_ty.isBuiltin()) {
                        const ref_info = self.module.types.get(ref_ty);
                        if (ref_info == .array) {
                            ref = self.arrayToSliceView(ref, ref_ty) orelse
                                self.builder.emit(.{ .array_to_slice = .{ .operand = ref } }, ty);
                        }
                    }
                } else if (self.getProtocolInfo(ty) != null) {
                    // Auto type erasure: concrete → protocol
                    const ref_ty = self.builder.getRefType(ref);
                    if (ref_ty != ty) {
                        ref = self.buildProtocolErasure(ref, val, ref_ty, ty);
                    }
                } else if (ty_info == .pointer and self.getProtocolInfo(ty_info.pointer.pointee) != null) {
                    // `pv : *P = <concrete>` — the borrowed-VIEW coercion
                    // (erasure model). An lvalue initializer borrows its real
                    // storage (ctx = its address); a pointer-to-concrete makes
                    // the view of the pointee directly. An RVALUE has no
                    // durable storage to borrow — diagnose (issue 0304's
                    // silent accept: the struct's bytes were stored into the
                    // pointer slot).
                    const ref_ty = self.builder.getRefType(ref);
                    if (ref_ty != ty and !ref_ty.isBuiltin() and self.getProtocolInfo(ref_ty) == null) {
                        const ri = self.module.types.get(ref_ty);
                        if (ri == .pointer) {
                            if (self.viewOfConcreteAddr(ref, ri.pointer.pointee, ty)) |v| ref = v;
                        } else if (ri == .@"struct") {
                            if (self.isLvalueExpr(val)) {
                                const place = self.refStorageAddress(ref) orelse self.lowerExprAsPtr(val);
                                const place_ty = self.builder.getRefType(place);
                                const addr = if (place_ty == ref_ty)
                                    self.builder.emit(.{ .addr_of = .{ .operand = place } }, self.module.types.ptrTo(ref_ty))
                                else
                                    place;
                                if (self.viewOfConcreteAddr(addr, ref_ty, ty)) |v| ref = v;
                            } else {
                                if (self.diagnostics) |d| {
                                    d.addFmt(.err, val.span, "cannot initialize '{s}' of type '{s}' from a '{s}' rvalue — an rvalue has no durable storage to borrow; bind it to a local first, or erase to an owned '{s}' value", .{ vd.name, self.formatTypeName(ty), self.formatTypeName(ref_ty), self.formatTypeName(ty_info.pointer.pointee) });
                                }
                                self.builder.store(slot, self.buildDefaultValue(ty));
                                if (self.scope) |scope| {
                                    scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
                                }
                                return;
                            }
                        }
                    }
                }
            }
            if (ty == .any) {
                // `av : any = v` — node-aware boxing: an lvalue initializer
                // borrows its storage (Odin parity), an rvalue spills to a
                // frame temp. The node-less coerceToType arm below would
                // always spill. (`.any` is a builtin id — this hook sits
                // OUTSIDE the user-type block above.)
                const ref_ty = self.builder.getRefType(ref);
                if (ref_ty != .any and ref_ty != .void and ref_ty != .unresolved) {
                    ref = self.boxAnyOf(ref, ref_ty, val);
                }
            }
            // Coerce value to match target type (e.g. u8 → i64 widening)
            {
                const ref_ty = self.builder.getRefType(ref);
                if (ref_ty != ty and ref_ty != .void and ty != .void) {
                    // An initializer with NO coercion to the annotated slot type
                    // (`x : i32 = "hi"`) would otherwise pass through unchanged and
                    // bit-mangle the slot (issue 0197). Diagnose and store a safe
                    // default so the build aborts cleanly instead of segfaulting.
                    if (!self.checkAssignable(ref_ty, ty, val.span, "initialize", vd.name, val)) {
                        self.builder.store(slot, self.buildDefaultValue(ty));
                        if (self.scope) |scope| {
                            scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
                        }
                        return;
                    }
                    ref = self.coerceToType(ref, ref_ty, ty);
                }
            }
            self.builder.store(slot, ref);
        } else {
            // No value: zero-initialize or apply struct defaults
            const zero = self.buildDefaultValue(ty);
            self.builder.store(slot, zero);
        }
        if (self.scope) |scope| {
            scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
        }
    } else if (vd.value) |val| {
        // No type annotation — lower expr first, then get type from result.
        // This is critical for generic calls where the return type is only
        // known after monomorphization.
        const saved_fbv = self.force_block_value;
        const saved_target = self.target_type;
        self.force_block_value = true;
        // An unannotated decl provides no target type: clear the ambient one
        // (the enclosing fn's implicit-return target) so literal initializers
        // take their spec defaults (i64/f64) instead of adopting it.
        self.target_type = null;
        const ref = self.lowerExpr(val);
        self.force_block_value = saved_fbv;
        self.target_type = saved_target;
        // A bare function reference is deliberately represented by the legacy
        // `.i64`-typed `func_ref` op because several async/fiber paths consume
        // that exact IR shape.  For an unannotated local, however, the binding
        // must carry the user-visible function type so a later `f(...)` is
        // planned as an indirect function call rather than as a call through an
        // integer (issue 0237).  Keep the emitted ref unchanged and specialize
        // only this declaration-inference boundary.
        const ty = inferBareFnBindingType(self, val) orelse self.builder.getRefType(ref);
        const slot = self.builder.alloca(ty);
        self.builder.store(slot, ref);
        if (self.scope) |scope| {
            scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
        }
    } else {
        const ty = TypeId.i64;
        const slot = self.builder.alloca(ty);
        self.builder.store(slot, self.zeroValue(ty));
        if (self.scope) |scope| {
            scope.put(vd.name, .{ .ref = slot, .ty = ty, .is_alloca = true });
        }
    }
}

fn inferBareFnBindingType(self: *Lowering, value: *const ast.Node) ?TypeId {
    if (value.data != .identifier) return null;
    const name = value.data.identifier.name;
    const effective_name = if (self.scope) |scope| blk: {
        // A value binding shadows a same-named top-level/local function.  Only
        // use the function table when the identifier really denotes a fn.
        if (scope.lookup(name) != null) return null;
        break :blk scope.lookupFn(name) orelse name;
    } else name;
    const fd = self.program_index.fn_ast_map.get(effective_name) orelse return null;

    var params = std.ArrayList(TypeId).empty;
    defer params.deinit(self.alloc);
    for (fd.params) |*param| {
        params.append(self.alloc, self.resolveParamType(param)) catch unreachable;
    }
    const cc: types.TypeInfo.CallConv = if (fd.abi == .c or fd.extern_export == .export_) .c else .default;
    return self.module.types.functionTypeCC(params.items, self.resolveReturnType(fd), cc);
}

/// Handle a bare fn_decl node as a local function declaration.
/// The parser produces `fn_decl` (not `const_decl`) for `name :: (params) -> T { body }`.
pub fn lowerLocalFnDecl(self: *Lowering, fd: *const ast.FnDecl) void {
    // Use mangled name for local functions to support block-scoped shadowing
    const name = if (self.scope) |scope| blk: {
        const mangled = std.fmt.allocPrint(self.alloc, "{s}__{d}", .{ fd.name, self.local_fn_counter }) catch fd.name;
        self.local_fn_counter += 1;
        scope.fn_names.put(fd.name, mangled) catch {};
        break :blk mangled;
    } else fd.name;
    self.program_index.fn_ast_map.put(name, fd) catch {};
    self.lazyLowerFunction(name);
}

pub fn lowerConstDecl(self: *Lowering, cd: *const ast.ConstDecl) void {
    // Handle local function declarations: fx :: (s:i3) -> i3 { ... }
    if (cd.value.data == .fn_decl) {
        const fd = &cd.value.data.fn_decl;
        // Use mangled name for local functions to support block-scoped shadowing
        const name = if (self.scope != null) blk: {
            const mangled = std.fmt.allocPrint(self.alloc, "{s}__{d}", .{ cd.name, self.local_fn_counter }) catch cd.name;
            self.local_fn_counter += 1;
            // Register the bare→mangled mapping in the current scope
            if (self.scope) |scope| {
                scope.fn_names.put(cd.name, mangled) catch {};
            }
            break :blk mangled;
        } else cd.name;
        // Register in fn_ast_map so it can be resolved by lowerCall
        self.program_index.fn_ast_map.put(name, fd) catch {};
        // Lower the function body (saves/restores builder state)
        self.lazyLowerFunction(name);
        return;
    }

    // Handle local type declarations: MyType :: struct/union/enum { ... }
    if (cd.value.data == .struct_decl) {
        self.recordLocalTypeName(cd.name);
        self.registerStructDecl(&cd.value.data.struct_decl, self.current_source_file);
        return;
    }
    if (cd.value.data == .enum_decl) {
        self.recordLocalTypeName(cd.name);
        self.registerEnumDecl(&cd.value.data.enum_decl);
        return;
    }
    if (cd.value.data == .union_decl) {
        self.recordLocalTypeName(cd.name);
        self.registerUnionDecl(&cd.value.data.union_decl);
        return;
    }

    // For a body-local `#run` const (`L :: #run f()`), record the const NAME so
    // the `__ct` wrapper carries it as a display name — a comptime-init failure
    // then reports `comptime init of 'L' failed` instead of `__ct_N` (issue 0182).
    const saved_ct_name = self.comptime_const_name;
    if (cd.value.data == .comptime_expr) self.comptime_const_name = cd.name;
    defer self.comptime_const_name = saved_ct_name;

    const ref = self.lowerExpr(cd.value);
    // If there's an explicit type annotation, use it. Otherwise, infer from the expression.
    const ty = if (cd.type_annotation) |ta|
        self.resolveType(ta)
    else
        self.builder.getRefType(ref);

    // An annotated constant whose initializer cannot coerce to the declared type
    // would be bound under a type its bytes don't match (issue 0197) — diagnose
    // rather than let a later read reinterpret the wrong-shape value.
    if (cd.type_annotation != null) {
        _ = self.checkAssignable(self.builder.getRefType(ref), ty, cd.value.span, "initialize", cd.name, cd.value);
    }

    if (self.scope) |scope| {
        scope.put(cd.name, .{ .ref = ref, .ty = ty, .is_alloca = false, .origin = .local_const });
    }
}

/// Validate an explicit `return` value against a multi-VALUE return type (≥2
/// value slots). Emits diagnostics; does not rewrite. Covers: a bare value where
/// multiple are required (`return 5` for `-> (i64, i64)`), wrong arity (too few /
/// too many), and named elements that disagree with the slot at their position
/// (named return elements must currently be IN SLOT ORDER — reordering by name is
/// a future nicety, but a mismatch is an error, never a silent wrong result).
/// A single-value or single-failable return is left to the existing path.
pub fn validateMultiReturn(self: *Lowering, value_node: *const Node, ret_ty: TypeId) void {
    const diags = self.diagnostics orelse return;
    const ret_is_tuple = !ret_ty.isBuiltin() and self.module.types.get(ret_ty) == .tuple;
    // A comma list / multi-element literal returned from a SINGLE-value
    // (non-tuple) function would silently drop the extra values — reject it.
    if (!ret_is_tuple and value_node.data == .tuple_literal) {
        const els = value_node.data.tuple_literal.elements;
        if (els.len > 1) {
            for (els) |e| if (e.value.data == .spread_expr) return; // can't count a spread
            diags.addFmt(.err, value_node.span, "this function returns a single value, but a list of {d} was given", .{els.len});
        }
        return;
    }
    if (!ret_is_tuple) return;
    const ti = self.module.types.get(ret_ty);
    const fields = ti.tuple.fields;
    const is_failable = self.errorChannelOf(ret_ty) != null;
    const value_count = if (is_failable) fields.len - 1 else fields.len;
    if (value_count < 2) return; // single value / single failable — not multi-return
    if (value_node.data == .tuple_literal) {
        const els = value_node.data.tuple_literal.elements;
        // A spread (`..xs`) can expand to any arity — can't check statically.
        for (els) |e| if (e.value.data == .spread_expr) return;
        // The value-only list (n == value_count) is the bare-comma form; the full
        // failable tuple (n == fields, including the error slot) is also allowed.
        if (els.len != value_count and els.len != fields.len) {
            diags.addFmt(.err, value_node.span, "this function returns {d} values, but {d} {s} given", .{ value_count, els.len, if (els.len == 1) @as([]const u8, "is") else @as([]const u8, "are") });
            return;
        }
        // Named elements no longer need to be in slot order — `reorderNamedReturn`
        // (called from `lowerReturn` before lowering) permutes them to match the
        // slots and diagnoses unknown / duplicate / missing names. Arity is
        // checked above; nothing more to validate here.
    } else {
        // A bare value (not a comma list) where ≥2 are required is valid only if
        // it already PRODUCES the whole multi-value tuple — forwarding another
        // multi-return's result, or a multi-output `asm { … }`. Any TUPLE-typed
        // value qualifies (names may differ from the slots); a non-tuple scalar
        // does not — that is the `return 5` for `-> (i64, i64)` garbage case.
        const vty = self.inferExprType(value_node);
        const v_is_tuple = vty != .unresolved and !vty.isBuiltin() and self.module.types.get(vty) == .tuple;
        if (vty != .unresolved and !v_is_tuple) {
            diags.addFmt(.err, value_node.span, "this function returns {d} values — return them as `return a, b`, not a single value", .{value_count});
        }
    }
}

/// Permute a FULLY-NAMED multi-return tuple literal (`return b = …, a = …`) so
/// its elements line up with the function's return slots BY NAME, returning a
/// fresh reordered `tuple_literal`. Positional / mixed lists, non-tuple returns,
/// and arity mismatches (diagnosed in `validateMultiReturn`) pass through
/// unchanged. Diagnoses a name that matches no slot, a duplicate, or a missing
/// value slot — returning the original node after diagnosing (the build aborts
/// via `hasErrors`, so the unpermuted node never reaches run time).
fn reorderNamedReturn(self: *Lowering, value_node: *const Node, ret_ty: TypeId) *const Node {
    if (value_node.data != .tuple_literal) return value_node;
    if (ret_ty.isBuiltin()) return value_node;
    const ti = self.module.types.get(ret_ty);
    if (ti != .tuple) return value_node;
    const slot_names = ti.tuple.names orelse return value_node;
    const els = value_node.data.tuple_literal.elements;
    if (els.len == 0) return value_node;
    // Reorder only a FULLY-named list; positional/mixed keeps positional order.
    for (els) |e| if (e.name == null) return value_node;
    const is_failable = self.errorChannelOf(ret_ty) != null;
    const fields_len = ti.tuple.fields.len;
    const value_count = if (is_failable) fields_len - 1 else fields_len;
    // Two accepted shapes (anything else is an arity error diagnosed by
    // `validateMultiReturn` — pass through): the VALUE-ONLY list (one element per
    // value slot, the ergonomic `return a = …, b = …` form) and the FULL-TUPLE
    // list (a trailing element for the error slot too, `els.len == fields_len`).
    // BOTH must be reordered/validated — otherwise a fully-named full-tuple
    // failable return silently lands values positionally (regression found in
    // review). `match_count` slots participate; the error slot (when present)
    // joins by its own slot name.
    const match_count = els.len;
    if (match_count != value_count and match_count != fields_len) return value_node;
    if (match_count > slot_names.len) return value_node;

    // Validate element names FIRST (clearer diagnostics than a downstream
    // "missing slot"): every name must match a participating slot, no duplicates.
    for (els, 0..) |e, ei| {
        const en = e.name.?;
        var matches_slot = false;
        var s: usize = 0;
        while (s < match_count) : (s += 1) {
            const sn = self.module.types.getString(slot_names[s]);
            if (sn.len != 0 and std.mem.eql(u8, en, sn)) {
                matches_slot = true;
                break;
            }
        }
        if (!matches_slot) {
            if (self.diagnostics) |d| d.addFmt(.err, value_node.span, "named return element '{s}' does not name any return slot", .{en});
            return value_node;
        }
        for (els[ei + 1 ..]) |e2| {
            if (std.mem.eql(u8, en, e2.name.?)) {
                if (self.diagnostics) |d| d.addFmt(.err, value_node.span, "named return element '{s}' is given more than once", .{en});
                return value_node;
            }
        }
    }
    // All names are distinct participating-slot names and arity matches, so the
    // mapping is a bijection: every slot has exactly one matching element.
    const reordered = self.alloc.alloc(ast.TupleElement, match_count) catch return value_node;
    var slot: usize = 0;
    while (slot < match_count) : (slot += 1) {
        const sn = self.module.types.getString(slot_names[slot]);
        var filled = false;
        for (els) |e| {
            if (std.mem.eql(u8, e.name.?, sn)) {
                reordered[slot] = e;
                filled = true;
                break;
            }
        }
        // Validation above guarantees a bijection, so every slot is filled. If a
        // slot is somehow unmatched (e.g. an empty/unnamed slot in a full-tuple
        // form), bail rather than lower an uninitialized element.
        if (!filled) return value_node;
    }

    const node = self.alloc.create(Node) catch return value_node;
    node.* = .{ .span = value_node.span, .data = .{ .tuple_literal = .{ .elements = reordered } } };
    return node;
}

/// A bare `.{ … }` in a TUPLE-returning position behaves as the old `.( )`
/// tuple literal — rewrite the node shape so every downstream intercept
/// (multi-return arity validation, named-element reorder, the
/// full-failable-tuple detection in `failableReturnTarget`) sees the tuple
/// form it keys on.
fn tupleFormOfBareBraceLiteral(self: *Lowering, node: *const Node, ret_ty: TypeId) *const Node {
    if (node.data != .struct_literal) return node;
    const sl = node.data.struct_literal;
    if (sl.struct_name != null or sl.type_expr != null or sl.init_block != null) return node;
    if (ret_ty.isBuiltin() or self.module.types.get(ret_ty) != .tuple) return node;
    const elems = self.alloc.alloc(ast.TupleElement, sl.field_inits.len) catch return node;
    for (sl.field_inits, 0..) |fi, i| elems[i] = .{ .name = fi.name, .value = fi.value };
    const n = self.alloc.create(Node) catch return node;
    n.* = .{ .span = node.span, .data = .{ .tuple_literal = .{ .elements = elems } } };
    return n;
}

pub fn lowerReturn(self: *Lowering, rs: *const ast.ReturnStmt) void {
    // Normalize a bare `.{ … }` against a tuple return to the tuple-literal
    // node shape FIRST — the intercepts below key on it.
    const norm_ret_ty: TypeId = if (self.inline_return_target) |iri|
        iri.ret_ty
    else if (self.builder.func) |fid|
        self.module.functions.items[@intFromEnum(fid)].ret
    else
        .i64;
    const rs_value: ?*const Node = if (rs.value) |val| tupleFormOfBareBraceLiteral(self, val, norm_ret_ty) else null;
    if (rs_value) |val| {
        if (val.data == .identifier and self.isPackName(val.data.identifier.name)) {
            _ = self.diagPackAsValue(val.data.identifier.name, val.span, .return_value);
            return;
        }
        // Validate a multi-value return against the function's slots: arity, a
        // bare value where multiple are required, and named-element/slot
        // agreement. Catches silent garbage (`return 5` for `-> (i64, i64)`) and
        // silently-wrong named returns (`return b = …, a = …` ignoring names).
        if (self.builder.func) |fid| {
            self.validateMultiReturn(val, self.module.functions.items[@intFromEnum(fid)].ret);
        }
    }
    // Set target_type to function return type so null_literal etc. get the right type.
    // When inlining a comptime body, the *inlined* fn's declared return type wins
    // over the caller's — otherwise `return 42` inside a `-> i64` body lowered into
    // a `-> i32` caller would coerce 42 to i32 before storing into the i64 slot.
    const old_target = self.target_type;
    const ret_ty_for_target: TypeId = if (self.inline_return_target) |iri|
        iri.ret_ty
    else if (self.builder.func) |fid|
        self.module.functions.items[@intFromEnum(fid)].ret
    else
        TypeId.i64;
    // A value-carrying failable (`-> (T..., !)`) returns its VALUE part and
    // the success error slot (0) is appended by lowerFailableSuccessReturn.
    // Resolve a BARE returned value against that value type, NOT the failable
    // tuple: a bare enum literal `.variant` resolves its tag against
    // `target_type`, and against the tuple it matches no variant (tag 0) and
    // is stamped with the tuple type — which the success-return path then
    // mistakes for a forwarded full tuple, dropping the appended `0` slot.
    // An explicit full failable tuple return (`return (v..., e)`) keeps the
    // full-tuple target so its trailing error element resolves against the
    // error set; it is then forwarded as-is. Applies to the inlined
    // comptime-body return path too (iri.ret_ty is the failable tuple there).
    const target_for_value = self.failableReturnTarget(ret_ty_for_target, rs_value);
    if (target_for_value != .void) self.target_type = target_for_value;
    // A `return <expr>` for a value-returning function is a VALUE position, just
    // like a `:=`/`=` RHS or a call argument: an `if`/`match`/block operand must
    // produce a value (a phi'd merge), not be demoted to a statement whose result
    // is dropped. Force value-mode so `return if c { 7 } else { return -1; }`
    // lowers the live `{7}` arm into the merge phi instead of collapsing to a
    // void statement-`if` that returns 0 (issue 0269 Bug A). The ambient flag is
    // unreliable here — a trailing arm's `produces_value` leaks up through the
    // parser (`last_stmt_produces_value`), so a diverging vs live arm alone would
    // flip it. A void return carries no value, so leave the flag clear for it (a
    // no-`else` guard-`if` in a `-> void`/`-> !` body must stay a statement).
    const saved_fbv_ret = self.force_block_value;
    const ret_is_void = ret_ty_for_target == .void;
    if (rs_value != null and !ret_is_void) self.force_block_value = true;
    // Evaluate return value first (before defers). A fully-named multi-return
    // list is permuted to slot order by name (`return b = …, a = …`) before
    // lowering — `reorderNamedReturn` is a no-op for positional / non-tuple
    // returns and for the inline-comptime case (ret_ty_for_target carries the
    // right tuple either way).
    const ret_val = if (rs_value) |val| self.lowerExpr(reorderNamedReturn(self, val, ret_ty_for_target)) else null;
    self.force_block_value = saved_fbv_ret;
    self.target_type = old_target;

    // Inlined-comptime-body return: store into the slot the inliner
    // gave us and branch to the inliner's "return-done" basic block.
    // The branch is the basic block's terminator — so subsequent
    // dead code in the same block trips the LLVM verifier (the
    // SAME behaviour as a regular `return X;` followed by code).
    //
    // We DO NOT set `block_terminated = true`: that flag would
    // leak past structured control flow (e.g. an `if cond { return
    // X; }` whose merge block continues to subsequent statements)
    // and incorrectly skip the trailing statements. CFG-level
    // termination is what we actually want — let the basic-block
    // terminator do its job.
    if (self.inline_return_target) |iri| {
        if (ret_val) |ref| {
            // Value-carrying failable inlined body: append the success error
            // slot (0) exactly like the real-return path below.
            // lowerFailableSuccessReturn routes through emitTupleRet, which
            // stores into iri.slot and branches to iri.done_bb for an inline
            // target. Defers first, so the returned SSA value is materialized
            // before they run (matching the real-return ordering).
            if (!iri.ret_ty.isBuiltin() and
                self.module.types.get(iri.ret_ty) == .tuple and
                self.errorChannelOf(iri.ret_ty) != null)
            {
                emitReturnDefers(self, self.func_defer_base);
                self.lowerFailableSuccessReturn(ref, iri.ret_ty, rs.value.?.span);
                return;
            }
            const val_ty = self.builder.getRefType(ref);
            const coerced = if (!iri.ret_ty.isBuiltin() and self.module.types.get(iri.ret_ty) == .error_set)
                // Pure-failable inlined body — same forward rules as the
                // real-return path below (set compat / no tuple truncation).
                self.coercePureFailableReturn(ref, iri.ret_ty, rs.value.?.span)
            else if (val_ty != iri.ret_ty and self.checkReturnable(ref, val_ty, iri.ret_ty, rs.value.?.span))
                self.coerceToType(ref, val_ty, iri.ret_ty)
            else
                ref;
            self.builder.store(iri.slot, coerced);
        }
        // Drain block-scoped defers up to the inlined-body base so
        // they fire on this return path the same as a real fn return.
        emitReturnDefers(self, self.func_defer_base);
        self.builder.br(iri.done_bb, &.{});
        return;
    }

    // Emit ALL pending defers for THIS function in LIFO order before the return
    emitReturnDefers(self, self.func_defer_base);

    if (ret_val) |ref| {
        const ret_ty = if (self.builder.func) |fid|
            self.module.functions.items[@intFromEnum(fid)].ret
        else
            TypeId.i64;
        if (ret_ty == .void) {
            // Void function — just return void (the value expression was evaluated for side effects)
            self.builder.retVoid();
        } else if (!ret_ty.isBuiltin() and self.module.types.get(ret_ty) == .tuple and self.errorChannelOf(ret_ty) != null) {
            // Value-carrying failable `-> (T..., !)`: the user returns the
            // value part; the compiler appends the success error slot (0).
            self.lowerFailableSuccessReturn(ref, ret_ty, rs.value.?.span);
        } else if (!ret_ty.isBuiltin() and self.module.types.get(ret_ty) == .error_set) {
            // PURE failable (`-> !` / `-> !Named`, ret type IS the error set)
            // returning a value: the pure→pure forward path. Set compat is
            // checked; a value-carrying failable result is rejected (its
            // value slots have nowhere to go — the plain coerce silently
            // truncated the tuple into a garbage tag).
            self.builder.ret(self.coercePureFailableReturn(ref, ret_ty, rs.value.?.span), ret_ty);
        } else {
            // Coerce return value to match function return type (e.g., ?i32 → i32).
            // Issue 0191: reject an un-coercible value instead of bit-welding
            // it into the return slot; on failure skip the coerce (the build
            // aborts via hasErrors before this ret could run).
            const val_ty = self.builder.getRefType(ref);
            const coerced = if (self.checkReturnable(ref, val_ty, ret_ty, rs.value.?.span))
                self.coerceToType(ref, val_ty, ret_ty)
            else
                ref;
            self.builder.ret(coerced, ret_ty);
        }
    } else {
        // A bare `return;` in a pure failable function (`-> !` / `-> !Named`,
        // whose return type IS the error set) is the success exit — the
        // error slot carries 0 ("no error"). Everything else is a void return.
        const ret_ty = if (self.builder.func) |fid|
            self.module.functions.items[@intFromEnum(fid)].ret
        else
            TypeId.void;
        if (!ret_ty.isBuiltin() and self.module.types.get(ret_ty) == .error_set) {
            self.builder.ret(self.builder.constInt(0, ret_ty), ret_ty);
        } else {
            self.builder.retVoid();
        }
    }
}

/// The ROOT identifier of an assignment-target chain (`K[0].x` → "K",
/// `WHITE.r` → "WHITE"). A deref along the chain (`p.*`, `p.*[i]`) breaks
/// it — writing through a pointer VALUE is not a write to the named root.
fn assignmentRootIdent(target: *const Node) ?[]const u8 {
    var n = target;
    while (true) {
        switch (n.data) {
            .identifier => |id| return id.name,
            .index_expr => |ie| n = ie.object,
            .field_access => |fa| n = fa.object,
            else => return null,
        }
    }
}

/// True when `root` names a module CONSTANT from the current source —
/// a const-flagged global (array/struct consts, #run consts) or a
/// module value const. Locals shadow (caller checks scope first).
pub fn rootIsConstant(self: *Lowering, root: []const u8) bool {
    switch (self.selectGlobalAuthor(root)) {
        .resolved => |g| if (self.module.globals.items[g.id.index()].is_const) return true,
        else => {},
    }
    return switch (self.selectModuleConst(root)) {
        .resolved, .own_opaque => true,
        .ambiguous, .none => false,
    };
}

/// Enclosing-local write guard (issue 0250 + review fold), shared by
/// lowerAssignment and lowerMultiAssign: peel the target chain (`arr[0]`,
/// `p.v`, `px.*`, and nestings — deref INCLUDED, unlike assignmentRootIdent:
/// writing through an enclosing pointer VALUE still requires reading that
/// enclosing local) to its base identifier; a base reachable only across a
/// nested-fn boundary is the ENCLOSING function's storage, which a static
/// nested `::` fn has no env to reach. Diagnose and return true (caller skips
/// the store). Belt-and-braces over the boundary-guarded lvalue helpers
/// (getExprAlloca / lowerExprAsPtr) — this catches the shape at the statement
/// level with the whole target as the span, and covers the multi-assign ident
/// arm (a direct `scope.lookup` store that silently no-op'd into the dead
/// alloca).
fn diagEnclosingRootWrite(self: *Lowering, target: *const Node) bool {
    var root = target;
    peel: while (true) {
        switch (root.data) {
            .index_expr => |ie| root = ie.object,
            .field_access => |fa| root = fa.object,
            .deref_expr => |de| root = de.operand,
            else => break :peel,
        }
    }
    if (root.data != .identifier) return false;
    const scope = self.scope orelse return false;
    if (!scope.lookupBoundary(root.data.identifier.name).crossed_fn_boundary) return false;
    _ = self.diagEnclosingLocalRef(root.data.identifier.name, target.span);
    return true;
}

/// Root-const write guard (issue 0116), shared by lowerAssignment and
/// lowerMultiAssign (issue 0229 — the multi-assign member/index arms bypassed
/// it and wrote through `::` struct consts): when `target`'s chain roots at a
/// module CONSTANT not shadowed by a local, diagnose and return true (the
/// caller skips the store). A deref along the chain breaks the walk
/// (`assignmentRootIdent`) — writing through a pointer VALUE is not a write
/// to the named root, so `CONST_PTR.* = v` stays accepted in both forms.
fn diagConstRootWrite(self: *Lowering, target: *const Node) bool {
    const root = assignmentRootIdent(target) orelse return false;
    const shadowed = if (self.scope) |s| s.lookup(root) != null else false;
    if (!shadowed and rootIsConstant(self, root)) {
        if (self.diagnostics) |d|
            d.addFmt(.err, target.span, "cannot assign through constant '{s}' — constants are immutable (use a '=' global or a local copy for mutable data)", .{root});
        return true;
    }
    return false;
}

/// Context-root write guard, shared by lowerAssignment and lowerMultiAssign:
/// an assignment whose target chain roots at the ambient `context` WITHOUT
/// crossing a pointer hop writes the Context storage itself — but the context
/// is immutable within its scope; only `push` installs new field values.
/// Diagnose and return true (the caller skips the store). A chain that
/// dereferences into pointee memory stays allowed (issue 0337): a pointer
/// field along the chain (`context.s.n = 5`), an explicit deref, or indexing
/// a slice/string field's backing data.
fn diagContextRootWrite(self: *Lowering, target: *const Node) bool {
    if (!self.implicit_ctx_enabled or self.current_ctx_ref == Ref.none) return false;
    var node = target;
    while (true) {
        const obj = switch (node.data) {
            .field_access => |fa| fa.object,
            .index_expr => |ie| ie.object,
            else => return false,
        };
        if (obj.data == .deref_expr) return false;
        if (obj.data == .identifier) {
            if (!std.mem.eql(u8, obj.data.identifier.name, "context")) return false;
            // A local named `context` shadows the builtin — ordinary paths own it.
            if (self.scope) |s| {
                if (s.lookup("context") != null) return false;
            }
            if (self.diagnostics) |d| {
                if (node.data == .field_access) {
                    const f = node.data.field_access.field;
                    d.addFmt(.err, target.span, "cannot assign to context field '{s}' — the context is immutable within its scope; override it for a block with `push .{{ {s} = ... }}` (writing through a pointer field's pointee is allowed)", .{ f, f });
                } else {
                    d.addFmt(.err, target.span, "cannot assign into the context — it is immutable within its scope; override it for a block with `push .{{ ... }}`", .{});
                }
            }
            return true;
        }
        // A hop that dereferences into pointee memory ends the context-rooted
        // walk: a pointer object auto-derefs, and indexing a slice or string
        // targets its backing data, not the context storage.
        const ty = self.inferExprType(obj);
        if (!ty.isBuiltin()) {
            const info = self.module.types.get(ty);
            if (info == .pointer) return false;
            if (info == .slice and node.data == .index_expr) return false;
        } else if (ty == .string and node.data == .index_expr) {
            return false;
        }
        node = obj;
    }
}

/// Shape-aware diagnostic for an assignment whose target is a NON-ALLOCA
/// scope binding — a name that resolves but has no storable slot. Shared by
/// lowerAssignment's ident arm and lowerMultiAssign's ident arm (issue 0219
/// + its review folds; the by-ref arm is issue 0216). Every store that lands
/// here was previously dropped silently: it reached neither a container nor
/// the binding's own copy. The binding's `origin` picks the message:
/// - by-ref capture       → write through it (`x.* = ...`)
/// - local `::` const     → constant-family message (a const is not a capture)
/// - for-loop element     → `(*x)` write-back hint (container storage exists)
/// - range index / match payload / catch binding / pack alias
///                        → copy-into-a-`:=`-local only (per specs.md
///                          §loops/captures these have no container storage
///                          to write back into — a `(*x)` hint would be a lie)
/// - `.other`             → generic non-storable-binding message
/// A `.unresolved`-typed binding is an error PLACEHOLDER from an earlier
/// diagnostic (e.g. `y := xs` where `xs` is a pack — diagPackAsValue already
/// fired); stay silent rather than cascade a second error off one root cause.
fn diagNonstoreBindingAssign(self: *Lowering, span: ast.Span, name: []const u8, b: Binding) void {
    const d = self.diagnostics orelse return;
    if (b.ty == .unresolved) return;
    if (b.is_ref_capture) {
        d.addFmt(.err, span, "cannot assign to by-ref capture '{s}' directly — write through it with '{s}.* = ...'", .{ name, name });
        return;
    }
    switch (b.origin) {
        .local_const => d.addFmt(.err, span, "cannot assign to constant '{s}' — a '::' declaration is immutable; use ':=' to declare a mutable local", .{name}),
        .for_element => d.addFmt(.err, span, "cannot assign to immutable capture '{s}' — it is a by-value copy of the element; capture by reference with '(*{s})' and write '{s}.* = ...' to modify the container, or copy it into a `:=` local to mutate", .{ name, name, name }),
        .range_index => d.addFmt(.err, span, "cannot assign to immutable capture '{s}' — a range/index position has no storage to write back into; copy it into a `:=` local to mutate", .{name}),
        .match_payload => d.addFmt(.err, span, "cannot assign to immutable capture '{s}' — a match payload binding is a read-only copy of the variant's payload; copy it into a `:=` local to mutate", .{name}),
        .catch_err => d.addFmt(.err, span, "cannot assign to immutable capture '{s}' — a catch/onfail error binding is read-only; copy it into a `:=` local to mutate", .{name}),
        .pack_elem_alias => d.addFmt(.err, span, "cannot assign to immutable capture '{s}' — a pack-element alias is read-only; copy it into a `:=` local to mutate", .{name}),
        .other => d.addFmt(.err, span, "cannot assign to '{s}' — it names a binding with no storable location; copy it into a `:=` local to mutate", .{name}),
    }
}

/// Outcome of attempting a store through a qualified module-alias member
/// target (`lib.g = v`, `lib.g += v`). `not_applicable` means the base is
/// NOT a namespace alias — the caller falls through to its ordinary
/// field-store path. `handled` means the store was emitted OR a clean
/// diagnostic was produced (const/fn/unresolved target); the caller stops.
const QualifiedStore = enum { not_applicable, handled };

/// Exact mutable-global slot selected from a complete qualified lvalue before
/// its RHS is lowered. `field` is present for `a.b.GLOBAL.member`; otherwise the
/// slot is the global itself. Carrying this descriptor through the store keeps
/// target typing and final emission on the same author/field identity.
const QualifiedGlobalStoreTarget = struct {
    const Field = struct { name: []const u8, index: u32, ty: TypeId };

    global: program_index_mod.GlobalInfo,
    member: []const u8,
    field: ?Field = null,

    fn valueType(self: QualifiedGlobalStoreTarget) TypeId {
        return if (self.field) |f| f.ty else self.global.ty;
    }
};

/// Complete pre-RHS verdict for a namespace-qualified assignment target.
/// Once a namespace path is proved, every failure is terminal and may not
/// fall through to ordinary field lowering after the RHS has run.
const QualifiedGlobalStoreVerdict = union(enum) {
    not_applicable,
    target: QualifiedGlobalStoreTarget,
    missing: struct { namespace: []const u8, member: []const u8, span: ast.Span },
    ambiguous: struct { alias: []const u8, span: ast.Span },
    immutable: struct { name: []const u8, span: ast.Span },
    non_lvalue: struct { name: []const u8, span: ast.Span, is_function: bool },
};

fn qualifiedStorePathSpan(node: *const Node, path: []const u8, part: []const u8) ast.Span {
    const off = @intFromPtr(part.ptr) - @intFromPtr(path.ptr);
    const logical_end = @min(path.len, off + part.len);
    const source_width: usize = node.span.end -| node.span.start;
    return .{
        .start = node.span.start,
        .end = node.span.start + @as(u32, @intCast(@min(source_width, logical_end))),
    };
}

fn qualifiedStoreTerminalSpan(node: *const Node, member: []const u8) ast.Span {
    const width: u32 = @intCast(@min(member.len, node.span.end -| node.span.start));
    return .{ .start = node.span.end - width, .end = node.span.end };
}

fn selectedQualifiedGlobal(self: *Lowering, selected: Lowering.QualifiedMember) ?program_index_mod.GlobalInfo {
    if (selected.author.raw == .var_decl) {
        if (self.global_decl_infos.get(selected.author.raw.var_decl)) |global| return global;
    }
    if (self.program_index.globals_by_source.get(selected.author.source)) |inner| {
        if (inner.get(selected.member)) |global| return global;
    }
    if (self.program_index.globals_by_source.get(selected.target.target_module_path)) |inner| {
        if (inner.get(selected.member)) |global| return global;
    }

    // Some registrations are deliberately deduplicated (notably extern
    // globals), so the per-source partition may have no row. Re-run only the
    // source-aware author selector while pinned to the exact selected module;
    // never consume the process-global winner directly.
    const saved_source = self.current_source_file;
    self.setCurrentSourceFile(selected.author.source);
    const resolved: ?program_index_mod.GlobalInfo = if (self.program_index.global_names.get(selected.member)) |fallback|
        switch (self.selectGlobalAuthor(selected.member)) {
            .resolved => |global| global,
            .untracked => if (selected.author.raw == .var_decl) fallback else null,
            .not_a_global, .ambiguous, .not_visible => null,
        }
    else
        null;
    self.setCurrentSourceFile(saved_source);
    return resolved;
}

/// Diagnostic-free preselection for a namespace-qualified mutable global. It
/// proves every namespace edge, selects the exact authored slot, and retains
/// invalid/ambiguous/immutable outcomes for diagnosis before RHS evaluation.
fn selectQualifiedGlobalStoreTarget(self: *Lowering, node: *const Node) QualifiedGlobalStoreVerdict {
    if (node.data != .field_access) return .not_applicable;
    const fa = node.data.field_access;
    const full_path = self.qualifiedTypeName(node) orelse return .not_applicable;

    const root_end = std.mem.indexOfScalar(u8, full_path, '.') orelse {
        self.alloc.free(full_path);
        return .not_applicable;
    };
    if (self.identifierBindsVisibleValue(full_path[0..root_end])) {
        self.alloc.free(full_path);
        return .not_applicable;
    }

    var selected: Lowering.QualifiedMember = undefined;
    var nested_field: ?[]const u8 = null;
    switch (self.qualifiedMemberVerdict(full_path)) {
        .selected => |sel| selected = sel,
        .missing => |m| return .{ .missing = .{
            .namespace = m.namespace,
            .member = m.member,
            .span = qualifiedStorePathSpan(node, full_path, m.member),
        } },
        .ambiguous => |alias| return .{ .ambiguous = .{
            .alias = alias,
            .span = qualifiedStorePathSpan(node, full_path, alias),
        } },
        .not_qualified => {
            const object_path = self.qualifiedTypeName(fa.object) orelse return .not_applicable;
            nested_field = fa.field;
            switch (self.qualifiedMemberVerdict(object_path)) {
                .selected => |sel| {
                    selected = sel;
                    self.alloc.free(object_path);
                },
                .not_qualified => {
                    self.alloc.free(object_path);
                    return .not_applicable;
                },
                .missing => |m| return .{ .missing = .{
                    .namespace = m.namespace,
                    .member = m.member,
                    .span = qualifiedStorePathSpan(fa.object, object_path, m.member),
                } },
                .ambiguous => |alias| return .{ .ambiguous = .{
                    .alias = alias,
                    .span = qualifiedStorePathSpan(fa.object, object_path, alias),
                } },
            }
        },
    }

    const diagnostic_name = full_path;
    const terminal = nested_field orelse selected.member;
    if (selected.author.raw == .const_decl) return .{ .immutable = .{
        .name = diagnostic_name,
        .span = qualifiedStoreTerminalSpan(node, terminal),
    } };
    if (selected.author.raw != .var_decl) return .{ .non_lvalue = .{
        .name = diagnostic_name,
        .span = qualifiedStoreTerminalSpan(node, terminal),
        .is_function = selected.author.raw == .fn_decl,
    } };

    var gi = selectedQualifiedGlobal(self, selected) orelse return .{ .non_lvalue = .{
        .name = diagnostic_name,
        .span = qualifiedStoreTerminalSpan(node, terminal),
        .is_function = false,
    } };
    // The process-wide global registration is a compatibility index and its
    // cached TypeId can reflect a same-display-name winner. For an annotated
    // exact var author, resolve the slot type in that declaration's source so
    // `a.RECORD.b` uses a's nominal layout end to end.
    if (selected.author.raw == .var_decl) {
        if (selected.author.raw.var_decl.type_annotation) |annotation| {
            const exact_ty = self.resolveTypeInSource(selected.author.source, annotation);
            if (exact_ty != .unresolved) gi.ty = exact_ty;
        }
    }
    if (gi.id.index() < self.module.globals.items.len and self.module.globals.items[gi.id.index()].is_const) {
        return .{ .immutable = .{
            .name = diagnostic_name,
            .span = qualifiedStoreTerminalSpan(node, terminal),
        } };
    }

    var field: ?QualifiedGlobalStoreTarget.Field = null;
    if (nested_field) |field_name| {
        const wanted = self.module.types.internString(field_name);
        for (self.getStructFields(gi.ty), 0..) |f, i| {
            if (f.name != wanted) continue;
            field = .{ .name = field_name, .index = @intCast(i), .ty = f.ty };
            break;
        }
        if (field == null) return .{ .non_lvalue = .{
            .name = diagnostic_name,
            .span = qualifiedStoreTerminalSpan(node, field_name),
            .is_function = false,
        } };
    }

    const stable_member = if (nested_field != null)
        switch (fa.object.data) {
            .field_access => |object_fa| object_fa.field,
            else => return .not_applicable,
        }
    else
        fa.field;
    self.alloc.free(full_path);
    return .{ .target = .{
        .global = gi,
        .member = stable_member,
        .field = field,
    } };
}

fn diagnoseQualifiedStoreVerdict(self: *Lowering, verdict: QualifiedGlobalStoreVerdict) bool {
    switch (verdict) {
        .not_applicable, .target => return false,
        .missing => |m| if (self.diagnostics) |d|
            d.addFmt(.err, m.span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member }),
        .ambiguous => |amb| if (self.diagnostics) |d|
            d.addFmt(.err, amb.span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{amb.alias}),
        .immutable => |bad| if (self.diagnostics) |d|
            d.addFmt(.err, bad.span, "cannot assign to '{s}' — it is a constant, not a mutable global", .{bad.name}),
        .non_lvalue => |bad| if (self.diagnostics) |d| {
            if (bad.is_function)
                d.addFmt(.err, bad.span, "cannot assign to '{s}' — it is a function, not a mutable global", .{bad.name})
            else
                d.addFmt(.err, bad.span, "cannot assign to '{s}' — it is not a mutable global lvalue", .{bad.name});
        },
    }
    return true;
}

/// Emit a store through a preselected qualified-global slot. No name lookup is
/// performed here; target typing and the final write necessarily share the same
/// `GlobalId`/field descriptor.
fn lowerSelectedQualifiedGlobalStore(
    self: *Lowering,
    target: QualifiedGlobalStoreTarget,
    op: ast.Assignment.Op,
    val: Ref,
    val_span: ast.Span,
    val_node: *const Node,
) void {
    if (target.field) |field| {
        const val_ty = self.builder.getRefType(val);
        if (op == .assign and !self.checkAssignable(val_ty, field.ty, val_span, "assign", field.name, val_node)) return;
        const base = self.builder.emit(.{ .global_addr = target.global.id }, self.module.types.ptrTo(target.global.ty));
        const ptr = self.builder.structGepTyped(base, field.index, self.module.types.ptrTo(field.ty), target.global.ty);
        self.storeOrCompound(ptr, val, op, field.ty);
        return;
    }

    if (op == .assign) {
        const val_ty = self.builder.getRefType(val);
        if (val_ty != target.global.ty and val_ty != .void and target.global.ty != .void) {
            if (!self.checkAssignable(val_ty, target.global.ty, val_span, "assign", target.member, val_node)) return;
        }
        const store_val = if (val_ty != target.global.ty and val_ty != .void and target.global.ty != .void)
            self.coerceToType(val, val_ty, target.global.ty)
        else
            val;
        self.builder.emitVoid(.{ .global_set = .{ .global = target.global.id, .value = store_val } }, .void);
    } else {
        const loaded = self.builder.emit(.{ .global_get = target.global.id }, target.global.ty);
        const result = self.emitCompoundOp(loaded, val, op, target.global.ty);
        self.builder.emitVoid(.{ .global_set = .{ .global = target.global.id, .value = result } }, .void);
    }
}

/// Store through `alias.member = val` / `facade.inner.member = val` (or the
/// compound-assignment equivalents) where the complete prefix resolves to a
/// namespace target and `member` is one of that exact target's MUTABLE globals.
/// This is the write counterpart of the full-path module-member READ path in
/// `lowerFieldAccess` (expr.zig). Every nested namespace edge is proved under
/// the own-or-one-direct-flat carry rule before the terminal member is selected;
/// no dotted segment is stripped into a global bare-name lookup (issue 0325).
///
/// An ordinary target-owned intermediate deliberately remains a non-namespace
/// boundary: `alias.global.field = val` first selects the exact qualified
/// `alias.global`, then writes `field` through that global. A qualified CONST or
/// FUNCTION member is rejected cleanly (never silently dropped). `op == .assign`
/// for a plain store; a compound op loads-op-stores through the global's type.
///
/// `val` is the already-lowered RHS; `val_span` locates it for coercion
/// diagnostics. Returns `.not_applicable` (fall through) when the root is not a
/// namespace alias or is shadowed by an ordinary value/global binding.
fn tryLowerQualifiedGlobalStore(
    self: *Lowering,
    fa: ast.FieldAccess,
    op: ast.Assignment.Op,
    val: Ref,
    span: ast.Span,
    val_span: ast.Span,
    val_node: *const Node,
) QualifiedStore {
    const full_node = Node{ .span = span, .data = .{ .field_access = fa } };
    const full_path = self.qualifiedTypeName(&full_node) orelse return .not_applicable;
    defer self.alloc.free(full_path);
    const root_end = std.mem.indexOfScalar(u8, full_path, '.') orelse return .not_applicable;
    const root = full_path[0..root_end];

    // A value binding or a same-named global SHADOWS a namespace alias — those
    // take the ordinary field-store path (mirrors the read-path guards).
    if (self.identifierBindsVisibleValue(root)) return .not_applicable;

    // Prefer the complete path: `facade.inner.GLOBAL`. When an ordinary member
    // stops namespace descent (`facade.inner.GLOBAL.field`), prove the complete
    // object prefix instead and retain only the final field as the lvalue tail.
    var object_path: ?[]const u8 = null;
    defer if (object_path) |path| self.alloc.free(path);
    var nested_field: ?[]const u8 = null;
    const selected: Lowering.QualifiedMember = switch (self.qualifiedMemberVerdict(full_path)) {
        .selected => |sel| sel,
        .missing => |m| {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member });
            return .handled;
        },
        .ambiguous => |alias| {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{alias});
            return .handled;
        },
        .not_qualified => blk: {
            const path = self.qualifiedTypeName(fa.object) orelse return .not_applicable;
            object_path = path;
            const sel = switch (self.qualifiedMemberVerdict(path)) {
                .selected => |s| s,
                .missing => |m| {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, span, "namespace '{s}' has no member '{s}'", .{ m.namespace, m.member });
                    return .handled;
                },
                .ambiguous => |alias| {
                    if (self.diagnostics) |d|
                        d.addFmt(.err, span, "namespace '{s}' is ambiguous: aliases from multiple flat-imported modules point at different targets; declare the alias locally", .{alias});
                    return .handled;
                },
                .not_qualified => return .not_applicable,
            };
            nested_field = fa.field;
            break :blk sel;
        },
    };
    const target = selected.target;
    const member = selected.member;
    const qualified_name = object_path orelse full_path;

    // Classify + resolve the member in the TARGET module's context — the alias
    // edge authorizes the reach, so visibility is judged as the target's own
    // name. Diagnostics that point at the ASSIGNMENT SITE (this file) must be
    // emitted with `current_source_file` RESTORED — DiagnosticList.addFmt
    // stamps the source file at EMIT time, so a message emitted while
    // switched renders the caller-file span against the TARGET module's text:
    // wrong file, and a garbage caret when the offset is past its EOF. That
    // rules out `resolveGlobalRef` here (it self-diagnoses the ambiguous /
    // not-visible outcomes INSIDE the switch): classify with
    // `selectGlobalAuthor` — which emits nothing — then restore, then
    // diagnose/store with correct attribution.
    const saved_src = self.current_source_file;
    self.setCurrentSourceFile(target.target_module_path);
    const is_fn = self.namespaceFnMember(&target, member) != null;
    const is_const = !is_fn and rootIsConstant(self, member);
    var resolved: ?program_index_mod.GlobalInfo = null;
    var member_ambiguous = false;
    var member_not_visible = false;
    if (!is_fn and !is_const) {
        // Mirror resolveGlobalRef's outcome mapping, minus its diagnostics.
        if (self.program_index.global_names.get(member)) |gi| {
            switch (self.selectGlobalAuthor(member)) {
                .resolved => |g| resolved = g,
                .not_a_global => {},
                .ambiguous => member_ambiguous = true,
                .not_visible => member_not_visible = true,
                .untracked => resolved = gi,
            }
        }
    }
    self.setCurrentSourceFile(saved_src);

    // A qualified FUNCTION member (`lib.some_fn = 3`) is not an lvalue.
    if (is_fn) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "cannot assign to '{s}' — it is a function, not a mutable global", .{qualified_name});
        return .handled;
    }
    // A qualified CONST member (`lib.SOME_CONST = 3`) is immutable.
    if (is_const) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "cannot assign to '{s}' — it is a constant, not a mutable global", .{qualified_name});
        return .handled;
    }

    // Mutable global of the target module → `global_set` (plain) or
    // load-op-store (compound).
    if (resolved) |gi| {
        if (nested_field) |field_name| {
            if (gi.id.index() < self.module.globals.items.len and self.module.globals.items[gi.id.index()].is_const) {
                if (self.diagnostics) |d| d.addFmt(.err, span, "cannot assign through constant global '{s}'", .{qualified_name});
                return .handled;
            }
            const wanted = self.module.types.internString(field_name);
            for (self.getStructFields(gi.ty), 0..) |field, i| {
                if (field.name != wanted) continue;
                const val_ty = self.builder.getRefType(val);
                if (op == .assign and !self.checkAssignable(val_ty, field.ty, val_span, "assign", field_name, val_node)) return .handled;
                const base = self.builder.emit(.{ .global_addr = gi.id }, self.module.types.ptrTo(gi.ty));
                const ptr = self.builder.structGepTyped(base, @intCast(i), self.module.types.ptrTo(field.ty), gi.ty);
                self.storeOrCompound(ptr, val, op, field.ty);
                return .handled;
            }
            if (self.diagnostics) |d| d.addFmt(.err, span, "field '{s}' not found on global '{s}'", .{ field_name, qualified_name });
            return .handled;
        }
        if (op == .assign) {
            const val_ty = self.builder.getRefType(val);
            if (val_ty != gi.ty and val_ty != .void and gi.ty != .void) {
                // No coercion to the global's type — bit-mangle guard (issue 0197).
                if (!self.checkAssignable(val_ty, gi.ty, val_span, "assign", member, val_node)) return .handled;
            }
            const store_val = if (val_ty != gi.ty and val_ty != .void and gi.ty != .void)
                self.coerceToType(val, val_ty, gi.ty)
            else
                val;
            self.builder.emitVoid(.{ .global_set = .{ .global = gi.id, .value = store_val } }, .void);
        } else {
            const loaded = self.builder.emit(.{ .global_get = gi.id }, gi.ty);
            const result = self.emitCompoundOp(loaded, val, op, gi.ty);
            self.builder.emitVoid(.{ .global_set = .{ .global = gi.id, .value = result } }, .void);
        }
        return .handled;
    }
    // The ambiguous / not-visible outcomes re-emit resolveGlobalRef's message
    // text here, AFTER the source-file restore, so the span renders against
    // the caller's file at the store site (not the target module's text).
    if (member_ambiguous) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'{s}' is ambiguous: it is declared in multiple flat-imported modules; qualify the reference or remove the duplicate import", .{member});
        return .handled;
    }
    if (member_not_visible) {
        if (self.diagnostics) |d|
            d.addFmt(.err, span, "'{s}' is not visible; #import the module that declares it", .{member});
        return .handled;
    }
    // The alias resolved but the member names nothing storable in the target
    // module — never a silent drop.
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "unresolved '{s}' in assignment — no mutable global with this name in the imported module", .{qualified_name});
    return .handled;
}

/// Map a compound-assignment op to the binary op it folds with, for the
/// get-modify-set rewrite of `obj.prop OP= x` (a `#set` property).
fn compoundAssignToBinaryOp(op: ast.Assignment.Op) ast.BinaryOp.Op {
    return switch (op) {
        .add_assign => .add,
        .sub_assign => .sub,
        .mul_assign => .mul,
        .div_assign => .div,
        .mod_assign => .mod,
        .and_assign => .bit_and,
        .or_assign => .bit_or,
        .xor_assign => .bit_xor,
        .shl_assign => .shl,
        .shr_assign => .shr,
        .assign => unreachable, // plain assign never reaches the rewrite
    };
}

/// Bind an already-lowered `Ref` (`val` of type `ty`) to a fresh, unspellable
/// (`$`-prefixed) local and return an identifier node that resolves to it. Lets
/// a synthesized accessor call reference a pre-computed receiver/value WITHOUT
/// re-lowering it — the basis for single-eval property writes. Null when there
/// is no scope to bind into.
fn bindSyntheticLocal(self: *Lowering, prefix: []const u8, val: Ref, ty: TypeId, span: ast.Span) ?*Node {
    const s = self.scope orelse return null;
    var namebuf: [48]u8 = undefined;
    const tmp = std.fmt.bufPrint(&namebuf, "${s}_{d}", .{ prefix, self.block_counter }) catch prefix;
    self.block_counter += 1;
    const owned = self.alloc.dupe(u8, tmp) catch return null;
    s.put(owned, .{ .ref = val, .ty = ty, .is_alloca = false });
    const id = self.alloc.create(Node) catch return null;
    id.* = .{ .span = span, .data = .{ .identifier = .{ .name = owned } } };
    return id;
}

/// Synthesize and lower `recv_obj.<setter-effective-name>(value_node)` — the
/// shared tail of every `#set` dispatch.
fn emitSetterCall(self: *Lowering, recv_obj: *Node, setter: *const ast.FnDecl, value_node: *Node, span: ast.Span) void {
    const callee = self.alloc.create(Node) catch return;
    callee.* = .{ .span = span, .data = .{ .field_access = .{ .object = recv_obj, .field = self.accessorEffName(setter) } } };
    const args = self.alloc.alloc(*Node, 1) catch return;
    args[0] = value_node;
    const syn_call = ast.Call{ .callee = callee, .args = args };
    _ = self.lowerCall(&syn_call);
}

/// `<fa> = <already-lowered val>` where `prop` is a `#set` property and the RHS
/// `Ref` was computed by the caller (the multi-assign path evaluates ALL RHS
/// values up front, so re-lowering would double-evaluate and break ordering).
/// Binds `val` to a synthetic local and dispatches the setter through it.
/// Returns true when it consumed the store (setter write, or a read-only
/// diagnostic for a `#get`-only property); false for an ordinary field.
fn tryLowerPropertyStore(self: *Lowering, fa: ast.FieldAccess, val: Ref, span: ast.Span) bool {
    var recv_ty = self.inferExprType(fa.object);
    if (!recv_ty.isBuiltin()) {
        const di = self.module.types.get(recv_ty);
        if (di == .pointer) recv_ty = di.pointer.pointee;
    }
    if (recv_ty.isBuiltin()) return false;
    const setter = self.getSetterFor(recv_ty, fa.field) orelse {
        if (self.getAccessorFor(recv_ty, fa.field) != null) {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "property '{s}' is read-only (no '#set')", .{fa.field});
            return true;
        }
        return false;
    };
    var recv_obj: *Node = fa.object;
    if (fa.object.data == .deref_expr) recv_obj = fa.object.data.deref_expr.operand;
    const val_id = bindSyntheticLocal(self, "prop_val", val, self.builder.getRefType(val), span) orelse return false;
    emitSetterCall(self, recv_obj, setter, val_id, span);
    return true;
}

/// `obj.prop = rhs` (or `obj.prop OP= rhs`) where `prop` is a `#set` property
/// accessor. Dispatches to the setter as `obj.prop$set(rhs)` — the write
/// counterpart of the `#get` read dispatch in `lowerFieldAccess`. Returns true
/// when it consumed the assignment (a real setter write, or a clean
/// read-only/write-only diagnostic); false to let normal field-store lowering
/// proceed (an ordinary field, or no property at all).
///
/// Must run BEFORE `lowerAssignment` lowers the RHS: a plain-assign setter call
/// lowers `rhs` itself (once, with the setter's value-param type as target), so
/// pre-lowering it here would double-evaluate.
fn tryLowerPropertyAssignment(self: *Lowering, asgn: *const ast.Assignment) bool {
    const fa = asgn.target.data.field_access;
    // Dereference the receiver type down to the struct that owns the accessor.
    var recv_ty = self.inferExprType(fa.object);
    if (!recv_ty.isBuiltin()) {
        const di = self.module.types.get(recv_ty);
        if (di == .pointer) recv_ty = di.pointer.pointee;
    }
    if (recv_ty.isBuiltin()) return false;

    const setter = self.getSetterFor(recv_ty, fa.field);
    const getter = self.getAccessorFor(recv_ty, fa.field);

    if (setter == null) {
        // No setter. A same-name `#get` (with no real field — getAccessorFor
        // guarantees a real field wins) means the property is read-only: reject
        // the write with a clear message rather than "field not found".
        if (getter != null) {
            if (self.diagnostics) |d|
                d.addFmt(.err, asgn.target.span, "property '{s}' is read-only (no '#set')", .{fa.field});
            return true;
        }
        return false; // ordinary field, or not a property → normal store path
    }

    // The receiver node the synthesized get/set dispatch on. An explicit-deref
    // receiver `(*p).prop` dispatches on the inner pointer `p` (auto-deref takes
    // the working path).
    var recv_obj: *Node = fa.object;
    if (fa.object.data == .deref_expr) recv_obj = fa.object.data.deref_expr.operand;

    // For a compound `OP=`, the receiver is read (via `#get`) AND written (via
    // `#set`), so it must be evaluated EXACTLY ONCE — otherwise a side-effecting
    // receiver (`next().prop += 1`) reads one object and writes another. Bind
    // the receiver's `*T` to a synthetic, unspellable local and dispatch both
    // the read and the write on it. (A plain assign's single setter call already
    // evaluates the receiver once, so it keeps using the original node.)
    if (asgn.op != .assign) {
        if (getter == null) {
            if (self.diagnostics) |d|
                d.addFmt(.err, asgn.target.span, "property '{s}' is write-only (no '#get'); compound assignment needs to read the current value", .{fa.field});
            return true;
        }
        // Evaluate the receiver once into a synthetic `*T` binding. `*T` receiver
        // → the pointer value itself; a `T` lvalue → its address (so the setter
        // mutates the original, not a copy). Guarded on a scope being present;
        // without one (e.g. a top-level init) fall back to the original node —
        // the receiver re-lowers, but functionality is preserved.
        if (self.scope != null) {
            var ptr_ty = self.inferExprType(recv_obj);
            const is_ptr = !ptr_ty.isBuiltin() and self.module.types.get(ptr_ty) == .pointer;
            const recv_ptr = if (is_ptr) self.lowerExpr(recv_obj) else self.lowerExprAsPtr(recv_obj);
            if (!is_ptr) ptr_ty = self.module.types.ptrTo(ptr_ty);
            if (bindSyntheticLocal(self, "prop_recv", recv_ptr, ptr_ty, asgn.target.span)) |id| recv_obj = id;
        }
    }

    // The value the setter receives. For a compound `OP=`: `(recv.prop) OP rhs`
    // — the read dispatches to the `#get` on the (now single-eval) receiver.
    var value_node: *Node = asgn.value;
    if (asgn.op != .assign) {
        const read_node = self.alloc.create(Node) catch return false;
        read_node.* = .{ .span = asgn.target.span, .data = .{ .field_access = .{ .object = recv_obj, .field = fa.field } } };
        const bin_node = self.alloc.create(Node) catch return false;
        bin_node.* = .{ .span = asgn.value.span, .data = .{ .binary_op = .{
            .op = compoundAssignToBinaryOp(asgn.op),
            .lhs = read_node,
            .rhs = asgn.value,
        } } };
        value_node = bin_node;
    }

    emitSetterCall(self, recv_obj, setter.?, value_node, asgn.target.span);
    return true;
}

/// Whether an assignment RHS needs `target_type` seeded from the LHS before
/// lowering. Shared by the field-access and deref target-type arms of
/// `lowerAssignment` so the two can't drift on which RHS shapes take the
/// target's type.
///
/// `null` / `---` (undef) carry NO type of their own — they take the store
/// slot's type from `target_type`. Without setting it to the target's type,
/// a leaked enclosing `target_type` (e.g. the function's return type while
/// lowering its body, decl.zig) reaches `constNull`/`constUndef` and builds
/// a WHOLE-STRUCT-typed null, emitting an oversized store that overruns the
/// slot and corrupts neighboring stack (issue 0154). Enum/struct/tuple
/// literals, branch arms, and `xx` casts resolve against it too. Skipped for
/// forms that would forward the type unchanged into method-call arg slots
/// (`resolveCallParamTypes` can't override target_type per-arg).
fn rhsNeedsTargetType(value: *const ast.Node) bool {
    return switch (value.data) {
        .enum_literal, .struct_literal, .tuple_literal, .if_expr, .match_expr, .block, .unary_op, .binary_op, .null_literal, .undef_literal => true,
        .call => |vc| vc.callee.data == .enum_literal,
        else => false,
    };
}

pub fn lowerAssignment(self: *Lowering, asgn: *const ast.Assignment) void {
    // Reassignment kills flow narrowing (issue 0179 / specs.md §Flow-Sensitive
    // Narrowing): a fresh value may be null, so the name is no longer proven
    // present. Drop it from the narrowed set before lowering the store.
    if (asgn.target.data == .identifier) {
        _ = self.narrowed.remove(asgn.target.data.identifier.name);
    }

    // Writes through a constant are rejected at compile time (issue 0116):
    // the target chain's root naming a const global (array/struct consts,
    // #run consts) or a module value const cannot be stored to — for a
    // struct const the store previously compiled and bus-errored at
    // runtime; for scalars it silently misfired.
    if (diagConstRootWrite(self, asgn.target)) return;
    // Context-root write guard (issue 0337): the context is immutable within
    // its scope — only pointer-hop chains (pointee writes) may proceed.
    if (diagContextRootWrite(self, asgn.target)) return;
    // `#set` property accessor: `obj.prop = rhs` (or `OP=`) dispatches to the
    // setter as `obj.prop$set(rhs)`. Must run before the RHS is lowered below
    // (the synthesized call lowers it itself). Falls through for ordinary fields.
    if (asgn.target.data == .field_access) {
        if (tryLowerPropertyAssignment(self, asgn)) return;
    }

    // Resolve a namespace-qualified global lvalue before touching the RHS.
    // Target-directed literals must see this exact author's slot type, and
    // the eventual store must reuse the same GlobalId instead of resolving
    // the dotted spelling a second time after RHS lowering changed context.
    const qualified_store_verdict = selectQualifiedGlobalStoreTarget(self, asgn.target);
    if (diagnoseQualifiedStoreVerdict(self, qualified_store_verdict)) return;
    const qualified_store_target: ?QualifiedGlobalStoreTarget = switch (qualified_store_verdict) {
        .target => |target| target,
        .not_applicable => null,
        .missing, .ambiguous, .immutable, .non_lvalue => unreachable,
    };

    // Set target_type from LHS for RHS lowering (enum literals, struct literals, etc.)
    const old_target = self.target_type;
    if (asgn.target.data == .identifier) {
        var found_local = false;
        if (self.scope) |scope| {
            if (scope.lookup(asgn.target.data.identifier.name)) |binding| {
                self.target_type = binding.ty;
                found_local = true;
            }
        }
        if (!found_local) {
            // Quiet author-aware lookup (type inference only; the store
            // site diagnoses ambiguity / visibility).
            if (self.program_index.global_names.get(asgn.target.data.identifier.name)) |gi| {
                switch (self.selectGlobalAuthor(asgn.target.data.identifier.name)) {
                    .resolved => |g| self.target_type = g.ty,
                    .untracked => self.target_type = gi.ty,
                    else => {},
                }
            }
        }
    } else if (asgn.target.data == .index_expr) {
        // For array[i] = val, set target_type to the element type. An
        // `.unresolved` element (non-indexable base — diagnosed by the store
        // arm below) must not become the RHS target type: it would mistype
        // RHS literals before the diagnostic fires (issue 0155).
        const tgt_obj_ty = self.inferExprType(asgn.target.data.index_expr.object);
        const elem_ty = self.ptrToArrayElem(tgt_obj_ty) orelse self.ptrToSliceElem(tgt_obj_ty) orelse self.getElementType(tgt_obj_ty);
        if (elem_ty != .void and elem_ty != .unresolved) self.target_type = elem_ty;
    } else if (asgn.target.data == .field_access) {
        // For obj.field = val, set target_type to the field's type so RHS
        // sub-expressions (enum/struct literals, branch arms, xx casts) can
        // resolve against it. Skipped for forms that would forward the type
        // unchanged into method-call arg slots (`resolveCallParamTypes` can't
        // override target_type per-arg).
        if (rhsNeedsTargetType(asgn.value)) {
            if (qualified_store_target) |target| {
                self.target_type = target.valueType();
            } else {
                const fa = asgn.target.data.field_access;
                const obj_ty_raw = self.inferExprType(fa.object);
                const obj_ty = if (!obj_ty_raw.isBuiltin()) blk: {
                    const pinfo = self.module.types.get(obj_ty_raw);
                    break :blk if (pinfo == .pointer) pinfo.pointer.pointee else obj_ty_raw;
                } else obj_ty_raw;
                // Resolve the LHS member's type via the SAME resolver the lvalue-
                // pointer path uses (fieldLvalueResolve), so the RHS target type
                // and the store slot can't diverge. Covers union/tagged-union
                // direct + promoted members, tuple/vector lanes, and structs —
                // not just structs (a plain getStructFields loop returned nothing
                // for a union member, leaving a struct-literal RHS untyped →
                // struct_init.ty == .unresolved → LLVM-emission panic; issue 0133).
                if (self.fieldLvalueResolve(obj_ty, fa.field)) |res| {
                    self.target_type = res.valueType();
                } else {
                    // The special-container pseudo-fields (`.ptr`/`.len` on
                    // string/slice/array/vector) are not struct fields, so the
                    // resolver returns null — without a target the AMBIENT one
                    // (the enclosing fn's return type, per decl.zig) leaks into
                    // the RHS and mis-types `s.ptr = xx raw` as an xx-to-string
                    // (surfaced by the 0305 explicit-pun refusal). Mirror the
                    // store arm's field types.
                    const is_special = obj_ty == .string or (!obj_ty.isBuiltin() and blk: {
                        const oi = self.module.types.get(obj_ty);
                        break :blk oi == .slice or oi == .array or oi == .vector;
                    });
                    if (is_special) {
                        if (std.mem.eql(u8, fa.field, "ptr")) {
                            self.target_type = self.module.types.manyPtrTo(self.getElementType(obj_ty));
                        } else if (std.mem.eql(u8, fa.field, "len")) {
                            self.target_type = .i64;
                        }
                    }
                }
            }
        }
    } else if (asgn.target.data == .deref_expr) {
        // For `p.* = val`, set target_type to the POINTEE of the LHS pointer
        // so RHS sub-expressions (enum/struct literals, branch arms, null/---)
        // resolve against the assignment target. Without this the RHS fell
        // back to the ambient target_type — the ENCLOSING FUNCTION'S RETURN
        // TYPE while lowering its body (decl.zig) — so `p.* = .{...}` typed
        // the literal from whatever the fn returned (issue 0215): .unresolved
        // → LLVM-emission panic for a void fn, bogus "cannot assign"/"field
        // not found" for scalar/struct returns, invalid insertvalue for `?T`.
        if (rhsNeedsTargetType(asgn.value)) {
            const ptr_ty = self.inferExprType(asgn.target.data.deref_expr.operand);
            if (!ptr_ty.isBuiltin()) {
                const pinfo = self.module.types.get(ptr_ty);
                // Not a pointer → leave target_type alone; the store arm
                // below diagnoses the bad deref target.
                if (pinfo == .pointer) self.target_type = pinfo.pointer.pointee;
            }
        }
    }
    // The RHS is a VALUE position: a block-form `if C { A } else { B }` /
    // `match` on the RHS of an assignment must yield its branch value, not
    // lower as a statement-if that returns a bare void 0 (issue 0268). Mirrors
    // `lowerVarDecl` (the `:=` path); a plain `z = if false { 100 } else { 200 }`
    // — and the compound / index / field target forms — otherwise stored 0.
    const saved_fbv = self.force_block_value;
    self.force_block_value = true;
    const val = self.lowerExpr(asgn.value);
    self.force_block_value = saved_fbv;
    self.target_type = old_target;

    // A static nested `::` fn writing through an ENCLOSING local/param is the
    // write-side of issue 0250: bare stores silently no-op'd; indexed / member
    // stores Bus-errored through the enclosing frame's dead alloca.
    if (diagEnclosingRootWrite(self, asgn.target)) return;
    if (qualified_store_target) |target| {
        lowerSelectedQualifiedGlobalStore(self, target, asgn.op, val, asgn.value.span, asgn.value);
        return;
    }
    switch (asgn.target.data) {
        .identifier => |id| {
            var handled = false;
            // A scope binding that is NOT an alloca (loop/match/error capture,
            // pack-element alias, synthetic receiver) has no storable slot in
            // this arm — remember it so the fall-through can tell "declared
            // but not storable here" apart from "resolves nowhere" (0216).
            var nonstore_binding: ?Binding = null;
            if (self.scope) |scope| {
                if (scope.lookup(id.name)) |binding| {
                    if (!binding.is_alloca) nonstore_binding = binding;
                    if (binding.is_alloca) {
                        handled = true;
                        if (asgn.op == .assign) {
                            // Coerce value to match binding type (e.g., f32 → ?f32, concrete → protocol)
                            var store_val = val;
                            const val_ty = self.builder.getRefType(val);
                            if (val_ty != binding.ty and val_ty != .void and binding.ty != .void) {
                                // A reassignment with no coercion to the slot type
                                // (`x = "hi"` for `x: i32`) would pass through and
                                // bit-mangle the slot (issue 0197) — diagnose instead.
                                if (!self.checkAssignable(val_ty, binding.ty, asgn.value.span, "reassign", id.name, asgn.value)) return;
                                store_val = self.coerceToType(val, val_ty, binding.ty);
                            }
                            self.builder.store(binding.ref, store_val);
                        } else {
                            // Compound assignment: load, op, store
                            const loaded = self.builder.load(binding.ref, binding.ty);
                            const result = self.emitCompoundOp(loaded, val, asgn.op, binding.ty);
                            self.builder.store(binding.ref, result);
                        }
                    }
                }
            }
            // Fallback: global variable assignment — source-aware (issue
            // 0115): write the AUTHOR's global, never an unrelated module's
            // same-named one.
            if (!handled) {
                if (nonstore_binding) |b| {
                    // A scope binding SHADOWS any same-named global — without
                    // this arm, `for xs (*g) { g = 77; }` with a module global
                    // `g` fell through to resolveGlobalRef and silently wrote
                    // the GLOBAL instead of addressing the capture (0216 review
                    // fold 1). Reads resolve the capture; writes must never
                    // resolve past it to different storage. Every non-alloca
                    // binding here previously accepted the store as a silent
                    // no-op (issues 0216/0219) — diagNonstoreBindingAssign
                    // picks the shape-correct rejection (by-ref write-through
                    // hint / immutable capture / local `::` const).
                    diagNonstoreBindingAssign(self, asgn.target.span, id.name, b);
                } else if (self.resolveGlobalRef(id.name, asgn.target.span)) |gi| {
                    if (asgn.op == .assign) {
                        const val_ty = self.builder.getRefType(val);
                        if (val_ty != gi.ty and val_ty != .void and gi.ty != .void) {
                            // No coercion to the global's type — bit-mangle guard (issue 0197).
                            if (!self.checkAssignable(val_ty, gi.ty, asgn.value.span, "reassign", id.name, asgn.value)) return;
                        }
                        const store_val = if (val_ty != gi.ty and val_ty != .void and gi.ty != .void)
                            self.coerceToType(val, val_ty, gi.ty)
                        else
                            val;
                        self.builder.emitVoid(.{ .global_set = .{ .global = gi.id, .value = store_val } }, .void);
                    } else {
                        // Compound assignment: load current value, apply op, store back
                        const loaded = self.builder.emit(.{ .global_get = gi.id }, gi.ty);
                        const result = self.emitCompoundOp(loaded, val, asgn.op, gi.ty);
                        self.builder.emitVoid(.{ .global_set = .{ .global = gi.id, .value = result } }, .void);
                    }
                } else if (std.mem.eql(u8, id.name, "_")) {
                    // `_ = expr;` is the discard idiom — plain assign only.
                    // A compound `_ OP= expr` has no current value to read
                    // and was silently accepted (0216 review fold 3).
                    if (asgn.op != .assign) {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, asgn.target.span, "cannot use compound assignment on '_' — the discard has no value to read; only '_ = expr' is allowed", .{});
                    }
                } else {
                    // The LHS name resolves to no assignable storage anywhere:
                    // no local slot, no visible global. Previously the RHS
                    // lowered and the store was DISCARDED silently — a typo'd
                    // assignment (`totl = 42;`) compiled and ran (issue 0216).
                    // `resolveGlobalRef` already diagnosed the ambiguous /
                    // not-visible outcomes itself; don't stack a second error.
                    const already_diagnosed = self.program_index.global_names.get(id.name) != null and
                        switch (self.selectGlobalAuthor(id.name)) {
                            .ambiguous, .not_visible => true,
                            else => false,
                        };
                    if (!already_diagnosed) {
                        if (self.diagnostics) |d|
                            d.addFmt(.err, asgn.target.span, "unresolved '{s}' in assignment — no variable or global with this name; use '{s} := ...' to declare a new variable", .{ id.name, id.name });
                    }
                }
            }
        },
        .field_access => |fa| {
            // `alias.member = val` where `alias` is a module namespace edge:
            // store into the imported module's mutable global (issue 0223).
            // Runs BEFORE the value-lvalue path below — a module alias is not
            // a value, so `lowerExprAsPtr(fa.object)` would fail "unresolved".
            switch (tryLowerQualifiedGlobalStore(self, fa, asgn.op, val, asgn.target.span, asgn.value.span, asgn.value)) {
                .handled => return,
                .not_applicable => {},
            }
            // M2.2 — `obj.field = val` for an Obj-C `#property` field
            // dispatches via objc_msgSend `setField:`. Skip struct-
            // pointer / GEP entirely; receivers are opaque Obj-C ids.
            // Compound ops on properties are deferred (need load-via-
            // getter + op + store-via-setter — Month 4 ARC territory).
            if (asgn.op == .assign) {
                if (self.lookupObjcPropertyOnPointer(fa.object, fa.field)) |prop| {
                    self.lowerObjcPropertySetter(fa.object, prop, val);
                    return;
                }
            }
            // M1.2 A.3 — `self.field [op]= val` on a sx-defined Obj-C
            // class instance field (NOT a #property): write through
            // the __sx_state ivar. Handles plain assignment AND
            // compound ops (+=, -=, etc.) via storeOrCompound.
            if (self.lookupObjcDefinedStateFieldOnPointer(fa.object, fa.field)) |info| {
                const obj_ref = self.lowerExpr(fa.object);
                const state_ptr = self.lowerObjcDefinedStateForObj(obj_ref, info.fcd) orelse return;
                const ptr_void = self.module.types.ptrTo(.void);
                const field_addr = self.builder.emit(.{ .struct_gep = .{
                    .base = state_ptr,
                    .field_index = info.field_idx,
                    .base_type = info.state_ty,
                } }, ptr_void);
                self.storeOrCompound(field_addr, val, asgn.op, info.field_ty);
                return;
            }

            var obj_ptr = self.lowerExprAsPtr(fa.object);
            var obj_ty = self.inferExprType(fa.object);
            // A guard-narrowed `?*T` local writes through implicitly:
            // load the optional, unwrap to the pointer, store through it
            // — parity with reads/receivers (issue 0352). A narrowed
            // `?Struct` VALUE keeps the explicit spelling (an in-place
            // payload write is a different lvalue).
            if (fa.object.data == .identifier and !obj_ty.isBuiltin()) {
                const ninfo = self.module.types.get(obj_ty);
                if (ninfo == .optional and self.narrowed.count() > 0 and
                    self.narrowed.contains(fa.object.data.identifier.name))
                {
                    const child = ninfo.optional.child;
                    if (!child.isBuiltin() and self.module.types.get(child) == .pointer) {
                        const opt_val = self.builder.load(obj_ptr, obj_ty);
                        const unwrapped = self.builder.emit(.{ .optional_unwrap = .{ .operand = opt_val } }, child);
                        obj_ptr = unwrapped;
                        obj_ty = self.module.types.get(child).pointer.pointee;
                    }
                }
            }
            // Auto-deref: if the object is a pointer field from a non-identifier
            // (i.e., result of structGep on a pointer slot), load the pointer value.
            if (fa.object.data != .identifier and !obj_ty.isBuiltin()) {
                const pinfo = self.module.types.get(obj_ty);
                if (pinfo == .pointer) {
                    obj_ptr = self.builder.load(obj_ptr, obj_ty);
                    obj_ty = pinfo.pointer.pointee;
                }
            }

            // Reject a direct write to a tagged-union variant (issue 0136): it
            // sets the payload but not the tag. Construct via `x = .variant(...)`.
            if (self.diagTaggedUnionVariantWrite(obj_ty, fa.field, asgn.target.span)) return;

            // Special .len/.ptr handling only for slices, strings, arrays — NOT structs
            const is_special_container = obj_ty == .string or (if (!obj_ty.isBuiltin()) blk: {
                const obj_info = self.module.types.get(obj_ty);
                break :blk obj_info == .slice or obj_info == .array or obj_info == .vector;
            } else false);

            if (is_special_container and std.mem.eql(u8, fa.field, "len")) {
                const gep = self.builder.structGepTyped(obj_ptr, 1, .i64, obj_ty);
                self.storeOrCompound(gep, val, asgn.op, .i64);
            } else if (is_special_container and std.mem.eql(u8, fa.field, "ptr")) {
                const elem_ty = self.getElementType(obj_ty);
                const field_ty = self.module.types.manyPtrTo(elem_ty);
                const gep = self.builder.structGepTyped(obj_ptr, 0, self.module.types.ptrTo(field_ty), obj_ty);
                self.storeOrCompound(gep, val, asgn.op, field_ty);
            } else if (self.fieldLvaluePtr(obj_ptr, obj_ty, fa.field)) |fl| {
                // Resolve the target field (struct / union direct / promoted
                // anonymous-struct member / tuple element / vector lane) via
                // the shared lvalue resolver — the same one the address-of
                // and multi-target store paths use — so the three never
                // resolve a field to a different slot or default field 0
                // (two-resolver defect class). fl.ptr is
                // *field_ty (the store handler unwraps one pointer level);
                // fl.ty is the value type to coerce the rhs to.
                const src_ty = self.builder.getRefType(val);
                // Guard a width-mismatched `.none` store into the field slot
                // (`w.s = "hi"` for a struct field `s`) — it would overrun the
                // slot and corrupt neighbors (issue 0197). Plain `=` only;
                // compound ops load-op-store through the field type.
                if (asgn.op == .assign and !self.checkAssignable(src_ty, fl.ty, asgn.value.span, "assign", fa.field, asgn.value)) return;
                const coerced = self.coerceToType(val, src_ty, fl.ty);
                self.storeOrCompound(fl.ptr, coerced, asgn.op, fl.ty);
            } else {
                // No struct / union / tuple / vector field matches the
                // assignment target. Emit the same field-not-found
                // diagnostic the read path uses (emitFieldError) and bail;
                // building a pointer with field_ty = .unresolved would
                // otherwise store through a pointer-to-.unresolved that
                // panics at LLVM emission.
                _ = self.emitFieldError(obj_ty, fa.field, asgn.target.span);
            }
        },
        .index_expr => |ie| {
            const obj_ty = self.inferExprType(ie.object);
            // Comptime-constant store into a tuple element — `tup[i] = v`. A tuple
            // is heterogeneous, so the destination is a typed `structGep` of field
            // `i`, never an `index_gep` (whose `ptrTo(.unresolved)` element type
            // panics at LLVM emit). Mirrors the read path in `lowerIndexExpr`; an
            // out-of-range comptime index diagnoses loudly here too rather than
            // falling through to that panic.
            if (!obj_ty.isBuiltin() and (self.module.types.get(obj_ty) == .tuple or self.module.types.get(obj_ty) == .@"struct")) {
                // Struct parity (aggregate ladder): `s[comptime i] = v` is the
                // i-th field store, exactly like tuples.
                const nfields: usize = @intCast(self.module.types.memberCount(obj_ty) orelse 0);
                if (self.comptimeIndexOf(ie.index)) |ci| {
                    if (ci >= 0 and @as(usize, @intCast(ci)) < nfields) {
                        const fi: u32 = @intCast(ci);
                        const fld_ty = self.module.types.memberType(obj_ty, ci) orelse .unresolved;
                        const base = self.getExprAlloca(ie.object) orelse self.lowerExprAsPtr(ie.object);
                        const gep = self.builder.structGepTyped(base, fi, self.module.types.ptrTo(fld_ty), obj_ty);
                        if (asgn.op == .assign and !self.checkAssignable(self.builder.getRefType(val), fld_ty, asgn.value.span, "assign", "element", asgn.value)) return;
                        const coerced = self.coerceToType(val, self.builder.getRefType(val), fld_ty);
                        self.storeOrCompound(gep, coerced, asgn.op, fld_ty);
                        return;
                    }
                    if (self.diagnostics) |d| {
                        d.addFmt(.err, ie.index.span, "tuple index {} out of bounds — tuple '{s}' has {} field{s}", .{
                            ci, self.formatTypeName(obj_ty), nfields, if (nfields == 1) "" else "s",
                        });
                    }
                    return; // hasErrors() aborts before codegen
                }
            }
            const idx = self.lowerIndexOperand(ie.index);
            const elem_ty = self.ptrToArrayElem(obj_ty) orelse self.ptrToSliceElem(obj_ty) orelse self.getElementType(obj_ty);
            // Non-indexable assignment base (`pc[i] = v` on a `*T`, a struct,
            // ...): an `index_gep` typed `ptrTo(.unresolved)` panics at LLVM
            // emission (issue 0155) — diagnose (same message as the read
            // path) and bail instead.
            if (elem_ty == .unresolved) {
                self.diagNonIndexable(obj_ty, ie.object.span);
                return; // hasErrors() aborts before codegen
            }
            const ptr_ty = self.module.types.ptrTo(elem_ty);
            // Guard a width-mismatched `.none` store into an element slot
            // (`arr[0] = "hi"` for an i32 array) — it would overrun the element
            // and corrupt neighbors (issue 0197). Plain `=` only.
            if (asgn.op == .assign and !self.checkAssignable(self.builder.getRefType(val), elem_ty, asgn.value.span, "assign", "element", asgn.value)) return;
            // For fixed-size array assignment targets, use the alloca pointer directly
            // so that the store modifies the original variable (not a loaded copy).
            const is_array = !obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array;
            const obj_alloca = if (is_array) self.getExprAlloca(ie.object) else null;
            if (obj_alloca) |alloca_ref| {
                // Array alloca: single-index GEP with element stride
                const gep = self.builder.emit(.{ .index_gep = .{ .lhs = alloca_ref, .rhs = idx } }, ptr_ty);
                self.storeOrCompound(gep, val, asgn.op, elem_ty);
            } else if (is_array) {
                // Array in a struct field or other composite: get pointer to array in-place
                const obj_ptr = self.lowerExprAsPtr(ie.object);
                const gep = self.builder.emit(.{ .index_gep = .{ .lhs = obj_ptr, .rhs = idx } }, ptr_ty);
                self.storeOrCompound(gep, val, asgn.op, elem_ty);
            } else {
                // Pointer/slice: load the pointer value and GEP
                var obj = self.lowerExpr(ie.object);
                obj = self.derefPtrToSliceIndexBase(obj, obj_ty);
                const gep = self.builder.emit(.{ .index_gep = .{ .lhs = obj, .rhs = idx } }, ptr_ty);
                self.storeOrCompound(gep, val, asgn.op, elem_ty);
            }
        },
        .deref_expr => |de| {
            const ptr = self.lowerExpr(de.operand);
            if (asgn.op == .assign) {
                const pointee_ty = blk: {
                    const ptr_ty = self.inferExprType(de.operand);
                    if (!ptr_ty.isBuiltin()) {
                        const info = self.module.types.get(ptr_ty);
                        if (info == .pointer) break :blk info.pointer.pointee;
                    }
                    break :blk ptr_ty;
                };
                const val_ty = self.builder.getRefType(val);
                // Guard a width-mismatched `.none` store through the pointer
                // (`p.* = "hi"` for a `*i32`) — overruns the pointee (issue 0197).
                if (!self.checkAssignable(val_ty, pointee_ty, asgn.value.span, "assign", "target", asgn.value)) return;
                const store_val = if (val_ty != pointee_ty and val_ty != .void and pointee_ty != .void)
                    self.coerceToType(val, val_ty, pointee_ty)
                else
                    val;
                self.builder.store(ptr, store_val);
            } else {
                const pointee_ty = self.inferExprType(de.operand);
                const elem_ty = blk: {
                    if (!pointee_ty.isBuiltin()) {
                        const info = self.module.types.get(pointee_ty);
                        if (info == .pointer) break :blk info.pointer.pointee;
                    }
                    break :blk pointee_ty;
                };
                self.storeOrCompound(ptr, val, asgn.op, elem_ty);
            }
        },
        else => {
            _ = self.emitError("assignment_target", asgn.target.span);
        },
    }
}

const FieldLvalue = struct { ptr: Ref, ty: TypeId };

/// Pure description of which slot `obj.field` resolves to — the GEP path plus
/// the field's value type — computed WITHOUT emitting any IR. The single
/// field-matching resolver for the LVALUE/WRITE paths: `fieldLvaluePtr` builds
/// GEPs from it, and the assignment target-type path reads `.valueType()` from
/// it, so the lvalue-pointer path and the RHS target-type path can never
/// disagree on which field (or what type) a name resolves to — the two-resolver
/// defect class this codebase keeps burning on. To handle a new aggregate
/// shape, add an arm here and a matching GEP arm in `fieldLvaluePtr`; both fail
/// to compile until the union is exhaustive, forcing the two to stay in lockstep.
///
/// NOTE: the READ path (`lowerFieldAccess`, expr.zig) and the TYPE-INFER path
/// (`ExprTyper.inferType`, expr_typer.zig) still carry their OWN parallel field
/// matchers (emitting `union_get`/`enum_payload`/`struct_get` value reads, and
/// returning a bare `TypeId`, respectively). They are not yet routed through
/// here, so a new aggregate shape must currently be taught to all three. Folding
/// read + infer onto this resolver (switching the descriptor to value-read ops /
/// `.valueType()`) would make it the genuine compiler-wide single matcher.
const FieldResolution = union(enum) {
    /// Direct union/tagged-union member: union_gep(index) into the aggregate.
    union_direct: struct { index: u32, ty: TypeId },
    /// Promoted member of an anonymous-struct union variant: union_gep into
    /// the variant struct `variant_ty`, then struct_gep into the member.
    union_promoted: struct { variant_index: u32, variant_ty: TypeId, member_index: u32, ty: TypeId },
    /// Tuple element / vector lane / plain struct field: a single
    /// struct_gep(index) into the aggregate.
    indexed: struct { index: u32, ty: TypeId },

    /// The field's value type — what the caller coerces the rhs to / sets as
    /// the RHS target type. Identical regardless of the GEP path taken.
    fn valueType(self: FieldResolution) TypeId {
        return switch (self) {
            .union_direct => |u| u.ty,
            .union_promoted => |u| u.ty,
            .indexed => |s| s.ty,
        };
    }
};

/// Match `obj.field` against the aggregate `obj_ty` and return the resolution
/// descriptor, or null when no field matches (the caller emits the
/// field-not-found diagnostic). Emits NO IR — see `FieldResolution`.
///
/// Handles union direct fields, promoted anonymous-struct union members,
/// tuple elements (numeric or named), vector lanes (`.x`/`.y`/`.z`/`.w` and
/// the colour aliases), and plain struct fields.
pub fn fieldLvalueResolve(self: *Lowering, obj_ty: TypeId, field: []const u8) ?FieldResolution {
    if (obj_ty.isBuiltin()) return null;
    const field_name_id = self.module.types.internString(field);
    const type_info = self.module.types.get(obj_ty);

    // Union / tagged-union: variants overlay at offset 0. A direct field is a
    // union_gep; a promoted anonymous-struct member is a union_gep into the
    // variant followed by a struct_gep into the member.
    const union_fields: ?[]const types.TypeInfo.StructInfo.Field = switch (type_info) {
        .@"union" => |u| u.fields,
        .tagged_union => |u| u.fields,
        else => null,
    };
    if (union_fields) |fields| {
        for (fields, 0..) |f, i| {
            if (f.name == field_name_id) {
                return .{ .union_direct = .{ .index = @intCast(i), .ty = f.ty } };
            }
            if (!f.ty.isBuiltin()) {
                const fi = self.module.types.get(f.ty);
                if (fi == .@"struct") {
                    for (fi.@"struct".fields, 0..) |sf, si| {
                        if (sf.name == field_name_id) {
                            return .{ .union_promoted = .{ .variant_index = @intCast(i), .variant_ty = f.ty, .member_index = @intCast(si), .ty = sf.ty } };
                        }
                    }
                }
            }
        }
        return null;
    }

    // Tuple element: `.0` (numeric) or `.name`.
    if (type_info == .tuple) {
        const tup = type_info.tuple;
        var elem_idx: ?usize = null;
        if (std.fmt.parseInt(usize, field, 10)) |n| {
            if (n < tup.fields.len) elem_idx = n;
        } else |_| {
            if (tup.names) |names| {
                for (names, 0..) |nm, i| {
                    if (nm == field_name_id and i < tup.fields.len) {
                        elem_idx = i;
                        break;
                    }
                }
            }
        }
        if (elem_idx) |idx| {
            return .{ .indexed = .{ .index = @intCast(idx), .ty = tup.fields[idx] } };
        }
        return null;
    }

    // Vector lane: `.x`/`.y`/`.z`/`.w` (or colour aliases `.r`/`.g`/`.b`/`.a`)
    // → lane 0/1/2/3 via the same vectorLaneIndex the read path uses. A
    // non-lane field on a vector is a genuine miss (caller diagnoses).
    if (type_info == .vector) {
        const vidx = Lowering.vectorLaneIndex(field) orelse return null;
        return .{ .indexed = .{ .index = vidx, .ty = type_info.vector.element } };
    }

    // Plain struct field.
    const struct_fields = self.getStructFields(obj_ty);
    for (struct_fields, 0..) |f, i| {
        if (f.name == field_name_id) {
            return .{ .indexed = .{ .index = @intCast(i), .ty = f.ty } };
        }
    }
    return null;
}

/// Resolve `obj.field` — where `obj_ptr` already points at the aggregate —
/// to a typed pointer into the field's storage plus the field's value type.
/// Delegates the field MATCH to `fieldLvalueResolve` (shared with the RHS
/// target-type path) and only builds the GEP(s) here. Returns null when no
/// field matches; the caller emits the field-not-found diagnostic.
///
/// `ptr`'s IR type is `*field_ty` (a pointer to the field), NOT the field
/// value type: `emitStore` reads the store-target pointer's IR type and
/// unwraps one `.pointer` level to find the stored value's type. Labelling
/// the GEP with the bare field type instead would make a field whose own
/// type is a pointer-to-aggregate (`*Pair`) coerce the stored pointer into
/// the aggregate (closure auto-promotion in `coerceArg`), storing an
/// oversized struct that clobbers the neighbouring field. `.ty` carries the
/// field's value type for the caller's coercion.
///
/// Single source of lvalue field GEP-building shared by all three store/
/// address-of sites — lowerAssignment (single-target store), lowerExprAsPtr
/// (address-of), and lowerMultiAssign (multi-target store); the field MATCH
/// itself is delegated to `fieldLvalueResolve` (above), so they never resolve
/// a field to a different slot or default field 0.
pub fn fieldLvaluePtr(self: *Lowering, obj_ptr: Ref, obj_ty: TypeId, field: []const u8) ?FieldLvalue {
    const res = self.fieldLvalueResolve(obj_ty, field) orelse return null;
    switch (res) {
        .union_direct => |u| {
            const ptr = self.builder.emit(.{ .union_gep = .{ .base = obj_ptr, .field_index = u.index, .base_type = obj_ty } }, self.module.types.ptrTo(u.ty));
            return .{ .ptr = ptr, .ty = u.ty };
        },
        .union_promoted => |u| {
            const ug = self.builder.emit(.{ .union_gep = .{ .base = obj_ptr, .field_index = u.variant_index, .base_type = obj_ty } }, self.module.types.ptrTo(u.variant_ty));
            const ptr = self.builder.structGepTyped(ug, u.member_index, self.module.types.ptrTo(u.ty), u.variant_ty);
            return .{ .ptr = ptr, .ty = u.ty };
        },
        .indexed => |s| {
            const ptr = self.builder.structGepTyped(obj_ptr, s.index, self.module.types.ptrTo(s.ty), obj_ty);
            return .{ .ptr = ptr, .ty = s.ty };
        },
    }
}

/// Lower a plain (untagged) `union` struct-literal `.{ member = value, ... }`.
/// The generic struct-literal path can't build a union — `getStructFields`
/// returns empty for a union, so a union literal would fall through to a
/// malformed `structInit` whose overlapping zero-fill clobbers the named member
/// (issue 0158). Instead, mirror the spec's `--- `+per-field form: write each
/// named member into an (otherwise-undefined) union-sized slot via the SAME
/// lvalue resolver the assignment path uses, then load the union value back.
///
/// Validity: union members overlay one storage slot, so the named members must
/// all belong to ONE arm — either a single direct member (`.{ f = 3.14 }`) or
/// several promoted members of the SAME anonymous-struct variant
/// (`.{ x = 1.0, y = 2.0 }`). Naming two direct members, or members from
/// different arms, would silently let a later store clobber an earlier one —
/// reject it loudly (no silent last-wins). `tagged_union`s never reach here
/// (handled earlier in `lowerStructLiteral`).
pub fn lowerUnionLiteral(self: *Lowering, sl: *const ast.StructLiteral, ty: TypeId, span: ast.Span) Ref {
    // Empty `.{}` → an undefined union value (matches the spec's `--- ` form;
    // `zeroValue` of a union is `constUndef`).
    if (sl.field_inits.len == 0) return self.zeroValue(ty);

    // Validate every member is named and all share one arm.
    const Arm = struct { promoted: bool, index: u32 };
    var arm: ?Arm = null;
    for (sl.field_inits) |fi| {
        const fname = fi.name orelse {
            if (self.diagnostics) |d|
                d.addFmt(.err, span, "a union literal must name its member(s): `.{{ member = value }}` (positional union init is ambiguous)", .{});
            return self.zeroValue(ty);
        };
        const res = self.fieldLvalueResolve(ty, fname) orelse {
            _ = self.emitFieldError(ty, fname, span);
            return self.zeroValue(ty);
        };
        const cur: Arm = switch (res) {
            .union_direct => |u| .{ .promoted = false, .index = u.index },
            .union_promoted => |u| .{ .promoted = true, .index = u.variant_index },
            // A union name never resolves to `.indexed`, but be safe rather
            // than silently mis-store.
            .indexed => {
                _ = self.emitFieldError(ty, fname, span);
                return self.zeroValue(ty);
            },
        };
        if (arm) |a| {
            // Allowed only when BOTH are promoted members of the SAME variant.
            if (!a.promoted or !cur.promoted or a.index != cur.index) {
                if (self.diagnostics) |d|
                    d.addFmt(.err, span, "a union literal may set only one member, or several members of the same anonymous-struct arm — '{s}'s members overlay the same storage", .{self.formatTypeName(ty)});
                return self.zeroValue(ty);
            }
        } else {
            arm = cur;
        }
    }

    // Construct: write each member at its lvalue into an undefined union slot.
    const slot = self.builder.alloca(ty);
    for (sl.field_inits) |fi| {
        const fname = fi.name.?; // validated above
        const member_ty = (self.fieldLvalueResolve(ty, fname) orelse unreachable).valueType();
        const saved_tt = self.target_type;
        self.target_type = member_ty;
        const val = self.lowerExpr(fi.value);
        self.target_type = saved_tt;
        const fl = self.fieldLvaluePtr(slot, ty, fname) orelse unreachable;
        const coerced = self.coerceToType(val, self.builder.getRefType(val), fl.ty);
        self.builder.store(fl.ptr, coerced);
    }
    return self.builder.load(slot, ty);
}

/// True (and emits the diagnostic) when `obj.field` names a DIRECT variant of a
/// tagged union — a store target that would set the payload but NOT the tag
/// (issue 0136): a tagged union is laid out `{ tag, payload }`, the write path
/// emits a `union_gep` into the payload only, so the discriminant goes stale and
/// a later `match`/`==` takes the wrong arm. The variant is set via construction
/// (`x = .variant(...)`, which writes both), so a direct member write is rejected.
///
/// Returns false (keeps working) for: plain `union` (no tag); promoted / nested
/// sub-field writes (`s.rect.w = ...`, where the immediate object is the payload
/// struct, resolving to `.indexed`/`.union_promoted`, not `.union_direct`); and
/// non-aggregates. Derefs one pointer level so a `*TaggedUnion` receiver is
/// caught too. Uses the shared `fieldLvalueResolve` matcher, so the guard can't
/// drift from the store path's notion of which member a name resolves to.
pub fn diagTaggedUnionVariantWrite(self: *Lowering, obj_ty: TypeId, field: []const u8, span: ast.Span) bool {
    var ty = obj_ty;
    if (!ty.isBuiltin()) {
        const info = self.module.types.get(ty);
        if (info == .pointer) ty = info.pointer.pointee;
    }
    if (ty.isBuiltin() or self.module.types.get(ty) != .tagged_union) return false;
    const res = self.fieldLvalueResolve(ty, field) orelse return false;
    if (res != .union_direct) return false;
    if (self.diagnostics) |d|
        d.addFmt(.err, span, "cannot assign to tagged-union variant '{s}' directly — a member write sets the payload but leaves the tag stale; construct the variant instead (e.g. `x = .{s}(...)`)", .{ field, field });
    return true;
}

/// Get the pointer (alloca ref) for an lvalue expression, without loading.
pub fn lowerExprAsPtr(self: *Lowering, node: *const Node) Ref {
    switch (node.data) {
        .identifier => |id| {
            // An lvalue reached only ACROSS a nested-fn boundary is the
            // enclosing function's storage — dead here (issue 0250 fold: the
            // field-write path Bus-errored through it). Diagnose; the
            // placeholder Ref is never emitted (hasErrors() aborts).
            if (self.scope) |scope| {
                if (scope.lookupBoundary(id.name).crossed_fn_boundary) {
                    return self.diagEnclosingLocalRef(id.name, node.span);
                }
            }
            const local = if (self.scope) |scope| scope.lookup(id.name) else null;
            if (local) |binding| {
                if (binding.is_alloca) {
                    // If the variable IS a pointer (e.g., p: *Vec2), load it
                    // to get the actual pointer value for GEP/store operations
                    if (!binding.ty.isBuiltin()) {
                        const info = self.module.types.get(binding.ty);
                        if (info == .pointer) {
                            return self.builder.load(binding.ref, binding.ty);
                        }
                    }
                    return binding.ref;
                }
            } else if (std.mem.eql(u8, id.name, "context") and
                self.implicit_ctx_enabled and self.current_ctx_ref != Ref.none)
            {
                // `context` roots an lvalue chain through the hidden `*Context`
                // itself, so a member chain GEPs the live ambient context like
                // any named pointer local — the fallback below would lower the
                // VALUE load, whose struct_gep has no pointer base and dies at
                // LLVM emission (issue 0337). Stores that would land in the
                // context storage itself are rejected by diagContextRootWrite;
                // only chains crossing a pointer field reach a store.
                return self.current_ctx_ref;
            } else if (self.resolveGlobalRef(id.name, null)) |gi| {
                // Module-global lvalue: address into the global's live storage
                // so a downstream GEP/store targets the global itself, not a
                // loaded copy. A pointer-typed global is loaded first to get
                // the pointer value to GEP through (mirrors the local pointer
                // case above); any other global yields its storage address.
                if (!gi.ty.isBuiltin() and self.module.types.get(gi.ty) == .pointer) {
                    return self.builder.emit(.{ .global_get = gi.id }, gi.ty);
                }
                return self.builder.emit(.{ .global_addr = gi.id }, self.module.types.ptrTo(gi.ty));
            }
        },
        .field_access => |fa| {
            // A complete namespace-qualified mutable global is one lvalue,
            // not a recursive field chain rooted at the alias token. Preserve
            // the exact `VarDecl -> GlobalId` selected by the namespace walk;
            // recursively lowering `a.one.engine.STATE` would eventually try
            // to take the address of identifier `a` and diagnose it as an
            // unresolved runtime value.
            if (self.qualifiedTypeName(node)) |path| {
                defer self.alloc.free(path);
                const root_end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
                if (!self.identifierBindsVisibleValue(path[0..root_end])) {
                    switch (self.qualifiedMemberVerdict(path)) {
                        .selected => |selected| if (selected.author.raw == .var_decl) {
                            if (selectedQualifiedGlobal(self, selected)) |global| {
                                if (!global.ty.isBuiltin() and self.module.types.get(global.ty) == .pointer) {
                                    return self.builder.emit(.{ .global_get = global.id }, global.ty);
                                }
                                return self.builder.emit(.{ .global_addr = global.id }, self.module.types.ptrTo(global.ty));
                            }
                        },
                        .not_qualified, .missing, .ambiguous => {},
                    }
                }
            }
            var obj_ptr = self.lowerExprAsPtr(fa.object);
            var obj_ty = self.inferExprType(fa.object);
            // A guard-narrowed `?*T` local roots the lvalue chain through
            // its pointer: load the optional, unwrap, GEP through the
            // pointee — narrowing parity for address-of chains (issue
            // 0352; the getter-receiver and address-of routes both land
            // here). A narrowed `?Struct` VALUE keeps the explicit
            // spelling, same as the store path.
            if (fa.object.data == .identifier and !obj_ty.isBuiltin()) {
                const ninfo = self.module.types.get(obj_ty);
                if (ninfo == .optional and self.narrowed.count() > 0 and
                    self.narrowed.contains(fa.object.data.identifier.name))
                {
                    const child = ninfo.optional.child;
                    if (!child.isBuiltin() and self.module.types.get(child) == .pointer) {
                        const opt_val = self.builder.load(obj_ptr, obj_ty);
                        obj_ptr = self.builder.emit(.{ .optional_unwrap = .{ .operand = opt_val } }, child);
                        obj_ty = self.module.types.get(child).pointer.pointee;
                    }
                }
            }
            // Auto-deref for chained pointer field access:
            // When fa.object is a field_access or index_expr, lowerExprAsPtr returns
            // a structGep/pointer to the slot. If the slot holds a pointer type,
            // we need to load the pointer value before GEPing into the pointee struct.
            // (Identifiers are already loaded by the identifier handler in lowerExprAsPtr.)
            if (fa.object.data != .identifier and !obj_ty.isBuiltin()) {
                const info = self.module.types.get(obj_ty);
                if (info == .pointer) {
                    obj_ptr = self.builder.load(obj_ptr, obj_ty);
                    obj_ty = info.pointer.pointee;
                }
            }
            // Resolve the field lvalue (struct / union direct / promoted
            // anonymous-struct member / tuple element) via the shared
            // resolver so address-of and the multi-target store path never
            // disagree on the slot. No match → emit the read path's
            // field-not-found diagnostic (lowerFieldAccessOnType →
            // emitFieldError) instead of silently GEPing field 0 as .i64;
            // that bogus pointer reaches LLVM emission as ptrTo(.unresolved)
            // and panics.
            if (self.fieldLvaluePtr(obj_ptr, obj_ty, fa.field)) |r| return r.ptr;
            return self.emitFieldError(obj_ty, fa.field, node.span);
        },
        .index_expr => |ie| {
            const obj_ty = self.inferExprType(ie.object);
            // Comptime-constant index into a tuple VALUE — the L-value sibling of
            // `lowerIndexExpr`'s tuple read path. A tuple is heterogeneous, so its
            // element address is a `structGep` of the i-th field (typed with that
            // field's type), NOT an `index_gep` (which assumes a uniform element
            // type — `getElementType(tuple)` is `.unresolved`, and an `index_gep`
            // with a `ptrTo(.unresolved)` result panics at LLVM emit). Needed for
            // `tasks[i].waiter = …` in the `race` runtime, where the i-th element
            // is read back as a pointer to GEP into its pointee.
            if (!obj_ty.isBuiltin() and (self.module.types.get(obj_ty) == .tuple or self.module.types.get(obj_ty) == .@"struct")) {
                // Struct parity (aggregate ladder): `s[comptime i]` is the
                // i-th field's address, exactly like tuples.
                const nfields: usize = @intCast(self.module.types.memberCount(obj_ty) orelse 0);
                if (self.comptimeIndexOf(ie.index)) |ci| {
                    if (ci >= 0 and @as(usize, @intCast(ci)) < nfields) {
                        const fi: u32 = @intCast(ci);
                        const fld_ty = self.module.types.memberType(obj_ty, ci) orelse .unresolved;
                        const base = self.getExprAlloca(ie.object) orelse self.lowerExprAsPtr(ie.object);
                        return self.builder.structGepTyped(base, fi, self.module.types.ptrTo(fld_ty), obj_ty);
                    }
                    // Comptime index out of range — diagnose loudly (mirror the
                    // read path in `lowerIndexExpr`) rather than falling through to
                    // the `index_gep` below, whose `ptrTo(.unresolved)` element type
                    // would panic at LLVM emit with no source diagnostic.
                    if (self.diagnostics) |d| {
                        d.addFmt(.err, ie.index.span, "tuple index {} out of bounds — tuple '{s}' has {} field{s}", .{
                            ci, self.formatTypeName(obj_ty), nfields, if (nfields == 1) "" else "s",
                        });
                    }
                    return self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts before codegen
                }
            }
            const idx = self.lowerIndexOperand(ie.index);
            const elem_ty = self.ptrToArrayElem(obj_ty) orelse self.ptrToSliceElem(obj_ty) orelse self.getElementType(obj_ty);
            // Non-indexable L-value base (`ps[i].field = v` / `@ps[i].field`
            // where `ps: *S`): an `index_gep` typed `ptrTo(.unresolved)`
            // panics at LLVM emission (issue 0155) — diagnose and bail.
            if (elem_ty == .unresolved) {
                self.diagNonIndexable(obj_ty, ie.object.span);
                return self.builder.constInt(0, .i64); // placeholder — hasErrors() aborts before codegen
            }
            const ptr_ty = self.module.types.ptrTo(elem_ty);
            // For fixed-size arrays, use the alloca so GEP addresses the original memory
            const is_array = !obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array;
            var base = if (is_array)
                (self.getExprAlloca(ie.object) orelse self.lowerExprAsPtr(ie.object))
            else
                self.lowerExpr(ie.object);
            base = self.derefPtrToSliceIndexBase(base, obj_ty);
            return self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = idx } }, ptr_ty);
        },
        .deref_expr => |de| {
            return self.lowerExpr(de.operand);
        },
        else => {},
    }
    // Fallback: lower as expression (may produce a value, not pointer)
    return self.lowerExpr(node);
}

/// Store a value to a GEP, handling both plain and compound assignment.
pub fn storeOrCompound(self: *Lowering, gep: Ref, val: Ref, op: ast.Assignment.Op, ty: TypeId) void {
    if (op == .assign) {
        const val_ty = self.builder.getRefType(val);
        const store_val = if (val_ty != ty and val_ty != .void and ty != .void)
            self.coerceToType(val, val_ty, ty)
        else
            val;
        self.builder.store(gep, store_val);
    } else {
        const loaded = self.builder.load(gep, ty);
        const result = self.emitCompoundOp(loaded, val, op, ty);
        self.builder.store(gep, result);
    }
}

pub fn emitCompoundOp(self: *Lowering, lhs: Ref, rhs: Ref, op: ast.Assignment.Op, ty: TypeId) Ref {
    return switch (op) {
        .add_assign => self.builder.add(lhs, rhs, ty),
        .sub_assign => self.builder.sub(lhs, rhs, ty),
        .mul_assign => self.builder.mul(lhs, rhs, ty),
        .div_assign => self.builder.div(lhs, rhs, ty),
        .mod_assign => self.builder.emit(.{ .mod = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .and_assign => self.builder.emit(.{ .bit_and = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .or_assign => self.builder.emit(.{ .bit_or = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .xor_assign => self.builder.emit(.{ .bit_xor = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .shl_assign => self.builder.emit(.{ .shl = .{ .lhs = lhs, .rhs = rhs } }, ty),
        .shr_assign => self.builder.emit(.{ .shr = .{ .lhs = lhs, .rhs = rhs } }, ty),
        else => self.emitError("compound_assign", null),
    };
}

// ── Defer / cleanup ─────────────────────────────────────────────

pub fn lowerDefer(self: *Lowering, ds: *const ast.DeferStmt) void {
    // Push deferred expression onto the stack — emitted at every block exit, LIFO.
    self.defer_stack.append(self.alloc, .{ .body = ds.expr, .is_onfail = false }) catch {};
}

/// `onfail [e] BODY` (ERR E1.7) — cleanup that runs only when an error
/// leaves the enclosing block. Recorded on the shared cleanup stack;
/// emitted (interleaved with defers, reverse) at error exits by
/// `emitErrorCleanup`, and discarded — never run — on a success exit.
pub fn lowerOnFail(self: *Lowering, ofs: *const ast.OnFailStmt, span: ast.Span) void {
    // `onfail` is only meaningful inside a failable function — a
    // non-failable function never error-exits, so it could never fire.
    const ret_ty = self.effectiveReturnType() orelse {
        self.diagOnFailNotFailable(span);
        return;
    };
    if (self.errorChannelOf(ret_ty) == null) {
        self.diagOnFailNotFailable(span);
        return;
    }
    self.defer_stack.append(self.alloc, .{ .body = ofs.body, .is_onfail = true, .binding = ofs.binding }) catch {};
}

pub fn diagOnFailNotFailable(self: *Lowering, span: ast.Span) void {
    if (self.diagnostics) |diags| {
        diags.addFmt(.err, span, "`onfail` is only valid inside a failable function (a return type with `!` or `!Named`) — use `defer` for unconditional cleanup", .{});
    }
}

/// Emit pending success cleanups for one RETURN edge without mutating the
/// lowering-time stack. A return inside one branch (notably a `catch` handler)
/// terminates only that CFG edge; sibling/success edges are lowered afterward
/// and still own every cleanup registered before the branch. Truncating here
/// erased those entries globally, so a later `catch { return ... }` made
/// earlier defers disappear from the runtime success path.
fn emitReturnDefers(self: *Lowering, base: usize) void {
    if (base > self.defer_stack.items.len) return;
    const stack = self.defer_stack.items;
    var i = stack.len;
    while (i > base) {
        i -= 1;
        if (!stack[i].is_onfail) self.lowerCleanupBody(stack[i].body);
    }
}

/// Emit cleanups from saved_len..current in reverse (LIFO) order on a
/// SUCCESS exit: only `defer` entries run; `onfail` entries are skipped
/// (and discarded by the truncation). Truncates the stack to saved_len.
pub fn emitBlockDefers(self: *Lowering, saved_len: usize) void {
    // Guard: if stack was already drained (e.g., by a return that emitted all defers)
    if (saved_len > self.defer_stack.items.len) return;
    if (self.currentBlockHasTerminator()) {
        // Block already terminated (e.g., by return) — cleanups were already emitted
        self.defer_stack.shrinkRetainingCapacity(saved_len);
        return;
    }
    const stack = self.defer_stack.items;
    var i = stack.len;
    while (i > saved_len) {
        i -= 1;
        if (!stack[i].is_onfail) self.lowerCleanupBody(stack[i].body);
    }
    self.defer_stack.shrinkRetainingCapacity(saved_len);
}

/// Emit pending `defer` cleanups for a `break`/`continue` exit: everything
/// registered since the innermost loop's body began, in LIFO order. `onfail`
/// entries are skipped (a break is a success exit). The stack is NOT
/// truncated — the same entries still belong to the fall-through lowering
/// path after the branch that contains the break; the enclosing block scopes
/// truncate as usual.
pub fn emitLoopExitDefers(self: *Lowering) void {
    const stack = self.defer_stack.items;
    var i = stack.len;
    while (i > self.loop_defer_base) {
        i -= 1;
        if (!stack[i].is_onfail) self.lowerCleanupBody(stack[i].body);
    }
}

/// Run a `defer`/`onfail` cleanup body for its side effects (void context).
/// A braced body lowers as statements (NOT as a value) so a trailing-`;`
/// last expression is fine here — cleanup bodies never yield a value.
pub fn lowerCleanupBody(self: *Lowering, body: *const Node) void {
    if (body.data == .block) self.lowerBlock(body) else _ = self.lowerExpr(body);
}

/// Emit cleanups from `base`..current in reverse order on an ERROR exit
/// (raise / try-propagation): BOTH `defer` and `onfail` entries run,
/// interleaved in reverse declaration order. `err_tag` is the in-flight
/// error tag, bound to each `onfail e`'s binding. Does not truncate — the
/// terminating `ret` + the unwinding block-scope `emitBlockDefers` (which
/// then see the terminator and skip) leave the stack consistent.
pub fn emitErrorCleanup(self: *Lowering, base: usize, err_tag: Ref) void {
    if (base > self.defer_stack.items.len) return;
    const tag_ty = self.builder.getRefType(err_tag);
    const stack = self.defer_stack.items;
    var i = stack.len;
    while (i > base) {
        i -= 1;
        const entry = stack[i];
        if (entry.is_onfail) {
            if (entry.binding) |name| {
                var ofscope = Scope.init(self.alloc, self.scope);
                const saved = self.scope;
                self.scope = &ofscope;
                ofscope.put(name, .{ .ref = err_tag, .ty = tag_ty, .is_alloca = false, .origin = .catch_err });
                self.lowerCleanupBody(entry.body);
                self.scope = saved;
                ofscope.deinit();
            } else {
                self.lowerCleanupBody(entry.body);
            }
        } else {
            self.lowerCleanupBody(entry.body);
        }
    }
}

pub fn lowerPush(self: *Lowering, ps: *const ast.PushStmt) void {
    // push Context.{...} { body } — allocates a fresh Context on the
    // stack frame, rebinds the lowering's `current_ctx_ref` to it for
    // the body's lexical scope, then restores. No global, no walk.
    if (!self.implicit_ctx_enabled) {
        _ = self.diagnoseMissingContext("`push Context.{...}`");
        self.lowerBlock(ps.body);
        return;
    }
    const ctx_ty = self.module.types.findByName(self.module.types.internString("Context")) orelse {
        _ = self.diagnoseMissingContext("`push Context.{...}`");
        self.lowerBlock(ps.body);
        return;
    };
    const saved_ctx_ref = self.current_ctx_ref;
    defer self.current_ctx_ref = saved_ctx_ref;

    const slot = self.builder.alloca(ctx_ty);

    // Inherit-omitted semantics: a `push Context.{ ... }` is a CAPABILITY
    // bag — fields the literal does NOT name are inherited from the ambient
    // context, not zero-inited. Zero-init would install a NULL `io`/
    // `allocator` vtable (a latent crash if the field is later used inside
    // the pushed scope). So seed the new slot from the ambient context,
    // then overwrite only the fields the literal explicitly names.
    //
    // This applies only to a `Context.{...}` struct-literal context-expr;
    // any other form (e.g. `push some_ctx_value`) keeps the whole-value
    // store (no field-level merge to do).
    const lit: ?*const ast.StructLiteral = switch (ps.context_expr.data) {
        .struct_literal => |*sl| sl,
        else => null,
    };

    if (lit != null and self.current_ctx_ref != Ref.none) {
        // 1. Copy the ambient context into the fresh slot (load + store the
        //    whole struct), so every omitted field carries its current value.
        const ambient = self.builder.load(self.current_ctx_ref, ctx_ty);
        self.builder.store(slot, ambient);

        // 2. Overwrite only the named fields. `push Context.{...}` always
        //    uses named field-inits (it is a Context literal); a positional
        //    init has no field name to target, so it is rejected loudly
        //    rather than silently writing the wrong field.
        self.current_ctx_ref = slot; // body + field values see the new slot
        for (lit.?.field_inits) |fi| {
            const fname = fi.name orelse {
                if (self.diagnostics) |d|
                    d.addFmt(.err, ps.context_expr.span, "`push Context.{{...}}` requires named fields (positional init not supported)", .{});
                continue;
            };
            const fl = self.fieldLvaluePtr(slot, ctx_ty, fname) orelse {
                _ = self.emitFieldError(ctx_ty, fname, ps.context_expr.span);
                continue;
            };
            const saved_target_f = self.target_type;
            self.target_type = fl.ty;
            const fval = self.lowerExpr(fi.value);
            self.target_type = saved_target_f;
            const fval_ty = self.builder.getRefType(fval);
            // An #identity Context field (`allocator`, `io`) erases
            // NODE-AWARE so an lvalue BORROWS (`push .{ allocator = gpa }`
            // aliases `gpa`) — the node-less path would misread the lvalue
            // as an rvalue and refuse. Other fields keep the node-less
            // coercion (value/own protocol fields own their copy until the
            // ownership cutover).
            const fl_pi = self.getProtocolInfo(fl.ty);
            const store_val = if (fval_ty != fl.ty and fval_ty != .void and fl.ty != .void)
                (if (fl_pi != null and fl_pi.?.ownership == .identity)
                    self.coerceOrErase(fval, fval_ty, fl.ty, fi.value)
                else
                    self.coerceToType(fval, fval_ty, fl.ty))
            else
                fval;
            self.builder.store(fl.ptr, store_val);
        }
    } else {
        // Non-literal context-expr, or no ambient context to inherit from:
        // lower the whole value and store it (the original behaviour).
        const saved_target = self.target_type;
        self.target_type = ctx_ty;
        const ctx_val = self.lowerExpr(ps.context_expr);
        self.target_type = saved_target;
        self.builder.store(slot, ctx_val);
        self.current_ctx_ref = slot;
    }

    self.lowerBlock(ps.body);
}

/// Mirror of lowerAssignment's target-typing preamble for ONE multi-assign
/// (target, value) pair: point `self.target_type` at the TARGET's resolved
/// type so the RHS value lowers against it. Without this every RHS lowered
/// against the AMBIENT target_type — the enclosing function's RETURN TYPE
/// while lowering its body — so `go, a = null, 2;` with `go: ?i64` typed the
/// `null` as a zero of i32 and coerceToType then wrapped a PRESENT optional
/// (Some(0)) into the target (0218 review fold); enum/struct literals
/// diagnosed against the wrong destination the same way. Pure typing — emits
/// no ops, so it cannot reorder the left-to-right evaluate-all-then-store-all
/// semantics. Caller saves/restores the ambient target_type around the loop.
fn setMultiAssignTargetType(self: *Lowering, target: *const Node, value: *const Node) void {
    switch (target.data) {
        .identifier => |id| {
            var found_local = false;
            if (self.scope) |scope| {
                if (scope.lookup(id.name)) |binding| {
                    self.target_type = binding.ty;
                    found_local = true;
                }
            }
            if (!found_local) {
                // Quiet author-aware lookup (type inference only; the store
                // site diagnoses ambiguity / visibility).
                if (self.program_index.global_names.get(id.name)) |gi| {
                    switch (self.selectGlobalAuthor(id.name)) {
                        .resolved => |g| self.target_type = g.ty,
                        .untracked => self.target_type = gi.ty,
                        else => {},
                    }
                }
            }
        },
        .index_expr => |ie| {
            // For `arr[i] = val`, type the RHS against the element type.
            const tgt_obj_ty = self.inferExprType(ie.object);
            const elem_ty = self.ptrToArrayElem(tgt_obj_ty) orelse self.ptrToSliceElem(tgt_obj_ty) orelse self.getElementType(tgt_obj_ty);
            if (elem_ty != .void) self.target_type = elem_ty;
        },
        .field_access => |fa| {
            // For `obj.field = val`, type the RHS against the field's type —
            // via the SAME resolver the lvalue-pointer store path uses, so
            // the RHS target type and the store slot can't diverge (issue
            // 0133). Gated like single-assign: only for RHS forms that
            // consume a target type.
            if (rhsNeedsTargetType(value)) {
                const obj_ty_raw = self.inferExprType(fa.object);
                const obj_ty = if (!obj_ty_raw.isBuiltin()) blk: {
                    const pinfo = self.module.types.get(obj_ty_raw);
                    break :blk if (pinfo == .pointer) pinfo.pointer.pointee else obj_ty_raw;
                } else obj_ty_raw;
                if (self.fieldLvalueResolve(obj_ty, fa.field)) |res| {
                    self.target_type = res.valueType();
                }
            }
        },
        .deref_expr => |de| {
            // For `p.* = val`, type the RHS against the POINTEE (issue 0215).
            if (rhsNeedsTargetType(value)) {
                const ptr_ty = self.inferExprType(de.operand);
                if (!ptr_ty.isBuiltin()) {
                    const pinfo = self.module.types.get(ptr_ty);
                    // Not a pointer → leave target_type alone; the store arm
                    // diagnoses the bad deref target.
                    if (pinfo == .pointer) self.target_type = pinfo.pointer.pointee;
                }
            }
        },
        else => {},
    }
}

pub fn lowerMultiAssign(self: *Lowering, ma: *const ast.MultiAssign) void {
    // Reassignment kills flow narrowing (issue 0179; multi-assign sibling
    // 0228): a fresh value may be null, so an assigned name is no longer
    // proven present. Mirror lowerAssignment exactly — IDENT targets only
    // (narrowing keys are bare local names, never field/index/deref paths),
    // removed BEFORE any RHS lowers, so `o, a = o + 1, 2;` inside an
    // `if o != null` diagnoses the RHS use just like `o = o + 1;` does.
    for (ma.targets) |t| {
        if (t.data == .identifier) _ = self.narrowed.remove(t.data.identifier.name);
    }

    // Select every namespace-qualified destination before evaluating any RHS.
    // Multi-assignment evaluates all values first, so a later re-resolution
    // cannot be allowed to choose the type/author for an earlier target.
    const qualified_store_verdicts = self.alloc.alloc(QualifiedGlobalStoreVerdict, ma.targets.len) catch @panic("out of memory while selecting multi-assignment targets");
    defer self.alloc.free(qualified_store_verdicts);
    var invalid_qualified_target = false;
    for (ma.targets, 0..) |target, i| {
        qualified_store_verdicts[i] = selectQualifiedGlobalStoreTarget(self, target);
        if (diagnoseQualifiedStoreVerdict(self, qualified_store_verdicts[i]))
            invalid_qualified_target = true;
    }
    // Multi-assignment evaluates every RHS before storing any destination. If
    // one namespace destination is invalid, stop before *all* RHS side effects
    // while still reporting every invalid target in this statement.
    if (invalid_qualified_target) return;

    // Evaluate all RHS values first (left-to-right, each typed against ITS
    // target — see setMultiAssignTargetType), then assign to LHS targets.
    var vals = std.ArrayList(Ref).empty;
    defer vals.deinit(self.alloc);
    const old_target = self.target_type;
    for (ma.values, 0..) |v, vi| {
        self.target_type = old_target;
        if (vi < ma.targets.len) {
            if (qualified_store_verdicts[vi] == .target) {
                const target = qualified_store_verdicts[vi].target;
                if (rhsNeedsTargetType(v)) self.target_type = target.valueType();
            } else {
                setMultiAssignTargetType(self, ma.targets[vi], v);
            }
        }
        vals.append(self.alloc, self.lowerExpr(v)) catch unreachable;
    }
    self.target_type = old_target;

    for (ma.targets, 0..) |target, i| {
        if (i >= vals.items.len) break;
        const val = vals.items[i];
        // Root-const write guard (issue 0116 / 0229) — same helper single-
        // assign runs, applied PER TARGET before its store: a member/index
        // target rooted at a `::` const (`CP.x, a = 9, 9;`) previously wrote
        // through the constant (only IDENT targets were guarded, by the arm
        // below). Diagnose this target and keep going so every bad target in
        // the statement is reported (batched, like consecutive single-assigns).
        if (diagConstRootWrite(self, target)) continue;
        // Context-root write guard (issue 0337) — same helper single-assign
        // runs, per target: only pointer-hop chains (pointee writes) proceed.
        if (diagContextRootWrite(self, target)) continue;
        // Enclosing-local write guard (issue 0250 fold) — same helper single-
        // assign runs, per target: a nested static fn's multi-assign to an
        // enclosing local previously stored into the dead alloca (silent no-op).
        if (diagEnclosingRootWrite(self, target)) continue;
        if (qualified_store_verdicts[i] == .target) {
            const selected = qualified_store_verdicts[i].target;
            lowerSelectedQualifiedGlobalStore(self, selected, .assign, val, ma.values[i].span, ma.values[i]);
            continue;
        }
        switch (target.data) {
            .identifier => |id| {
                // Mirror of lowerAssignment's ident arm (issue 0218, the
                // multi-assign sibling of 0216): local alloca slot → non-alloca
                // scope binding (captures shadow globals) → global fallback →
                // `_` discard → unresolved diagnostic. Previously only the
                // alloca case existed — an undeclared or module-global target
                // was silently dropped.
                var handled = false;
                // A scope binding that is NOT an alloca (loop/match/error
                // capture, pack-element alias, synthetic receiver) has no
                // storable slot in this arm — remember it so the fall-through
                // can tell "declared but not storable here" apart from
                // "resolves nowhere".
                var nonstore_binding: ?Binding = null;
                if (self.scope) |scope| {
                    if (scope.lookup(id.name)) |binding| {
                        if (!binding.is_alloca) nonstore_binding = binding;
                        if (binding.is_alloca) {
                            handled = true;
                            const val_ty = self.builder.getRefType(val);
                            // Width-mismatched `.none` store guard (issue 0197).
                            if (!self.checkAssignable(val_ty, binding.ty, ma.values[i].span, "assign", id.name, ma.values[i])) continue;
                            const store_val = if (val_ty != binding.ty and val_ty != .void and binding.ty != .void)
                                self.coerceToType(val, val_ty, binding.ty)
                            else
                                val;
                            self.builder.store(binding.ref, store_val);
                        }
                    }
                }
                if (!handled) {
                    if (nonstore_binding) |b| {
                        // A scope binding SHADOWS any same-named global —
                        // reads resolve the capture; writes must never resolve
                        // past it to different storage (0216 review fold 1).
                        // The multi-assign spelling (`x, a = v, w`) previously
                        // dropped the store silently, same as single-assign
                        // (issues 0216/0219) — diagNonstoreBindingAssign picks
                        // the shape-correct rejection identically.
                        diagNonstoreBindingAssign(self, target.span, id.name, b);
                    } else if (std.mem.eql(u8, id.name, "_")) {
                        // `_` discards this position's value — the multi-assign
                        // spelling of the discard idiom (`a, _ = x, y`).
                        // Multi-assign is always plain '=' (no compound form),
                        // so no `_ OP=` case exists here.
                        // (A `::`-const ident target never reaches this chain:
                        // the per-target diagConstRootWrite guard above already
                        // diagnosed it — issue 0116 / 0229.)
                    } else if (self.resolveGlobalRef(id.name, target.span)) |gi| {
                        // Module-global target — source-aware (issue 0115):
                        // write the AUTHOR's global, never an unrelated
                        // module's same-named one. Previously multi-assign had
                        // NO global fallback and dropped the store (0218).
                        const val_ty = self.builder.getRefType(val);
                        if (val_ty != gi.ty and val_ty != .void and gi.ty != .void) {
                            // No coercion to the global's type — bit-mangle guard (issue 0197).
                            if (!self.checkAssignable(val_ty, gi.ty, ma.values[i].span, "assign", id.name, ma.values[i])) continue;
                        }
                        const store_val = if (val_ty != gi.ty and val_ty != .void and gi.ty != .void)
                            self.coerceToType(val, val_ty, gi.ty)
                        else
                            val;
                        self.builder.emitVoid(.{ .global_set = .{ .global = gi.id, .value = store_val } }, .void);
                    } else {
                        // The target name resolves to no assignable storage
                        // anywhere: no local slot, no visible global.
                        // Previously the store was DISCARDED silently — a
                        // typo'd target in `a, totl = x, y;` compiled and ran
                        // (issue 0218). `resolveGlobalRef` already diagnosed
                        // the ambiguous / not-visible outcomes itself; don't
                        // stack a second error.
                        const already_diagnosed = self.program_index.global_names.get(id.name) != null and
                            switch (self.selectGlobalAuthor(id.name)) {
                                .ambiguous, .not_visible => true,
                                else => false,
                            };
                        if (!already_diagnosed) {
                            if (self.diagnostics) |d|
                                d.addFmt(.err, target.span, "unresolved '{s}' in assignment — no variable or global with this name; use '{s} := ...' to declare a new variable", .{ id.name, id.name });
                        }
                    }
                }
            },
            .index_expr => |ie| {
                const obj_ty = self.inferExprType(ie.object);
                // Comptime-constant direct store into a tuple element — `tup[i] = v`
                // (the store sibling of the L-value tuple path above). Heterogeneous
                // elements → a typed `structGep` of field `i`, never an `index_gep`
                // (a uniform-element op whose `ptrTo(.unresolved)` element type would
                // panic at LLVM emit).
                if (!obj_ty.isBuiltin() and (self.module.types.get(obj_ty) == .tuple or self.module.types.get(obj_ty) == .@"struct")) {
                    // Struct parity (aggregate ladder): comptime-index stores
                    // apply to struct values too.
                    const nfields: usize = @intCast(self.module.types.memberCount(obj_ty) orelse 0);
                    if (self.comptimeIndexOf(ie.index)) |ci| {
                        if (ci >= 0 and @as(usize, @intCast(ci)) < nfields) {
                            const fi: u32 = @intCast(ci);
                            const fld_ty = self.module.types.memberType(obj_ty, ci) orelse .unresolved;
                            const base = self.getExprAlloca(ie.object) orelse self.lowerExprAsPtr(ie.object);
                            const gep = self.builder.structGepTyped(base, fi, self.module.types.ptrTo(fld_ty), obj_ty);
                            const v_ty = self.builder.getRefType(val);
                            if (!self.checkAssignable(v_ty, fld_ty, ma.values[i].span, "assign", "element", ma.values[i])) continue;
                            const sv = if (v_ty != fld_ty and v_ty != .void and fld_ty != .void) self.coerceToType(val, v_ty, fld_ty) else val;
                            self.builder.store(gep, sv);
                            continue;
                        }
                        // Comptime index out of range — diagnose loudly instead of
                        // falling through to the `index_gep` store (whose
                        // `ptrTo(.unresolved)` element type would panic at LLVM emit).
                        if (self.diagnostics) |d| {
                            d.addFmt(.err, ie.index.span, "tuple index {} out of bounds — tuple '{s}' has {} field{s}", .{
                                ci, self.formatTypeName(obj_ty), nfields, if (nfields == 1) "" else "s",
                            });
                        }
                        continue; // hasErrors() aborts before codegen
                    }
                }
                const idx = self.lowerIndexOperand(ie.index);
                const elem_ty = self.ptrToArrayElem(obj_ty) orelse self.ptrToSliceElem(obj_ty) orelse self.getElementType(obj_ty);
                // Non-indexable multi-assign base (`ps[i], a = v, w` where
                // `ps: *S`, a struct, etc.): an `index_gep` typed
                // `ptrTo(.unresolved)` panics at LLVM emission — diagnose (same
                // message as single-assign / the read path) and bail instead of
                // building it (issue 0155; this arm previously lacked the guard).
                if (elem_ty == .unresolved) {
                    self.diagNonIndexable(obj_ty, ie.object.span);
                    continue; // hasErrors() aborts before codegen
                }
                const ptr_ty = self.module.types.ptrTo(elem_ty);
                const val_ty = self.builder.getRefType(val);
                if (!self.checkAssignable(val_ty, elem_ty, ma.values[i].span, "assign", "element", ma.values[i])) continue;
                const store_val = if (val_ty != elem_ty and val_ty != .void and elem_ty != .void)
                    self.coerceToType(val, val_ty, elem_ty)
                else
                    val;
                // For fixed-size arrays, address the storage IN PLACE — a local
                // alloca, or a MODULE-GLOBAL array via `global_addr`
                // (lowerExprAsPtr resolves both). Previously a global-array base
                // missed the alloca and fell through to `lowerExpr` (a load of
                // the whole array into a register); the GEP+store hit that
                // throwaway COPY and the write was silently dropped (issue 0249;
                // single-assign already took the `is_array → lowerExprAsPtr`
                // path). A slice/pointer base still loads the pointer VALUE.
                const is_array = !obj_ty.isBuiltin() and self.module.types.get(obj_ty) == .array;
                var base = if (is_array)
                    (self.getExprAlloca(ie.object) orelse self.lowerExprAsPtr(ie.object))
                else
                    self.lowerExpr(ie.object);
                base = self.derefPtrToSliceIndexBase(base, obj_ty);
                const gep = self.builder.emit(.{ .index_gep = .{ .lhs = base, .rhs = idx } }, ptr_ty);
                self.builder.store(gep, store_val);
            },
            .field_access => |fa| {
                // `alias.member, a = v, w` — store into an imported module's
                // mutable global (issue 0223, the multi-assign sibling). Runs
                // BEFORE lowerExprAsPtr, which cannot address a module alias.
                // Multi-assign is always plain `=`.
                switch (tryLowerQualifiedGlobalStore(self, fa, .assign, val, target.span, ma.values[i].span, ma.values[i])) {
                    .handled => continue,
                    .not_applicable => {},
                }
                // `#set` property target: dispatch to the setter with the
                // already-lowered RHS value (multi-assign evaluated all RHS up
                // front). Falls through for an ordinary field.
                if (tryLowerPropertyStore(self, fa, val, target.span)) continue;
                const obj_ptr = self.lowerExprAsPtr(fa.object);
                const obj_ty = self.inferExprType(fa.object);
                // Reject a direct write to a tagged-union variant (issue 0136).
                if (self.diagTaggedUnionVariantWrite(obj_ty, fa.field, target.span)) continue;
                // Resolve the target field via the shared lvalue resolver —
                // the same one address-of uses — so a missing field emits a
                // diagnostic instead of defaulting to field 0 / field_ty
                // .unresolved, which silently corrupted a neighbouring field
                // (or panicked at LLVM emission).
                if (self.fieldLvaluePtr(obj_ptr, obj_ty, fa.field)) |r| {
                    const val_ty = self.builder.getRefType(val);
                    if (!self.checkAssignable(val_ty, r.ty, ma.values[i].span, "assign", fa.field, ma.values[i])) continue;
                    const store_val = if (val_ty != r.ty and val_ty != .void and r.ty != .void)
                        self.coerceToType(val, val_ty, r.ty)
                    else
                        val;
                    self.builder.store(r.ptr, store_val);
                } else {
                    _ = self.emitFieldError(obj_ty, fa.field, target.span);
                }
            },
            .deref_expr => |de| {
                const ptr = self.lowerExpr(de.operand);
                const pointee_ty = blk: {
                    const ptr_ty = self.inferExprType(de.operand);
                    if (!ptr_ty.isBuiltin()) {
                        const info = self.module.types.get(ptr_ty);
                        if (info == .pointer) break :blk info.pointer.pointee;
                    }
                    break :blk ptr_ty;
                };
                const val_ty = self.builder.getRefType(val);
                if (!self.checkAssignable(val_ty, pointee_ty, ma.values[i].span, "assign", "target", ma.values[i])) continue;
                const store_val = if (val_ty != pointee_ty and val_ty != .void and pointee_ty != .void)
                    self.coerceToType(val, val_ty, pointee_ty)
                else
                    val;
                self.builder.store(ptr, store_val);
            },
            else => {
                _ = self.emitError("multi_assign_target", target.span);
            },
        }
    }
}

pub fn lowerDestructureDecl(self: *Lowering, dd: *const ast.DestructureDecl) void {
    // Lower the RHS expression (must produce a tuple)
    const saved_fbv = self.force_block_value;
    const saved_target = self.target_type;
    self.force_block_value = true;
    // Same as the unannotated var-decl path: the destructure declares new
    // bindings, so the ambient target type must not type the RHS literals.
    self.target_type = null;
    const ref = self.lowerExpr(dd.value);
    self.force_block_value = saved_fbv;
    self.target_type = saved_target;
    const ty = self.builder.getRefType(ref);

    // Get tuple field info
    if (ty.isBuiltin()) return;
    const ti = self.module.types.get(ty);
    // A STRUCT RHS destructures field-wise like a tuple — `a, b := .{10, 20}`
    // is the post-cutover spelling (an untyped `.{ }` self-types as an
    // anonymous positional struct), and any struct value destructures in
    // declaration order (tuple parity).
    if (ti == .@"struct") {
        const st = ti.@"struct";
        if (dd.names.len > st.fields.len) return;
        for (dd.names, 0..) |name, i| {
            if (std.mem.eql(u8, name, "_")) continue; // discard
            const field_ty = st.fields[i].ty;
            const field_val = self.builder.structGet(ref, @intCast(i), field_ty);
            const slot = self.builder.alloca(field_ty);
            self.builder.store(slot, field_val);
            if (self.scope) |scope| {
                scope.put(name, .{ .ref = slot, .ty = field_ty, .is_alloca = true });
            }
        }
        return;
    }
    if (ti != .tuple) return;
    const tuple = ti.tuple;
    if (dd.names.len > tuple.fields.len) return;

    // E1.8 (discard rejection): when the RHS is a value-carrying failable,
    // the error slot (always the LAST tuple field) cannot be dropped. It is
    // dropped when the destructure omits it (fewer names than fields, so the
    // trailing error slot is never reached) or binds it to `_`. The `try` /
    // `catch` / `or value` consumer forms all strip the error channel (their
    // result type is non-failable), so this fires only on a BARE failable
    // destructure — exactly the case that would let an error vanish silently.
    if (self.errorChannelOf(ty) != null) {
        const err_dropped = dd.names.len < tuple.fields.len or
            std.mem.eql(u8, dd.names[dd.names.len - 1], "_");
        if (err_dropped) {
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, dd.value.span, "the error slot of a failable cannot be dropped — bind it (`v, err := …`) and handle it, or use `try` / `catch`", .{});
            }
        }
    }

    // Extract each field and bind to a new variable
    for (dd.names, 0..) |name, i| {
        if (std.mem.eql(u8, name, "_")) continue; // discard
        const field_ty = tuple.fields[i];
        const field_val = self.builder.emit(.{ .tuple_get = .{
            .base = ref,
            .field_index = @intCast(i),
            .base_type = ty,
        } }, field_ty);
        const slot = self.builder.alloca(field_ty);
        self.builder.store(slot, field_val);
        if (self.scope) |scope| {
            scope.put(name, .{ .ref = slot, .ty = field_ty, .is_alloca = true });
        }
    }

    // Destructuring a failable's result binds the error slot to a variable:
    // the user now owns the error explicitly, so the trace is absorbed
    // (ERR E3.2). A plain (non-failable) tuple destructure clears nothing.
    if (self.errorChannelOf(ty) != null) self.emitTraceClear();
}
