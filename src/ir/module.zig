const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const inst = @import("inst.zig");
const ast = @import("../ast.zig");

const TypeId = types.TypeId;
const TypeInfo = types.TypeInfo;
const TypeTable = types.TypeTable;
const StringId = types.StringId;
const Ref = inst.Ref;
const BlockId = inst.BlockId;
const FuncId = inst.FuncId;
const GlobalId = inst.GlobalId;
const Inst = inst.Inst;
const Op = inst.Op;
const Block = inst.Block;
const Function = inst.Function;
const Global = inst.Global;
const Span = inst.Span;

// ── Module ──────────────────────────────────────────────────────────────

pub const Module = struct {
    types: TypeTable,
    functions: std.ArrayList(Function),
    globals: std.ArrayList(Global),
    /// Maps (protocol_ty, concrete_ty) → list of method FuncIds.
    impl_table: ImplTable,
    /// Interned Obj-C selectors. Kept as an insertion-ordered list of
    /// (selector_string, slot_GlobalId) so emit_llvm.zig produces the
    /// init constructor in a stable order across builds (the
    /// selector-sharing IR snapshot would otherwise flicker on
    /// hashtable rehash). `#objc_call` lowering uses
    /// `lookupObjcSelector` / `appendObjcSelector` to read/write it.
    objc_selector_cache: std.ArrayList(ObjcSelectorEntry),
    /// Interned Obj-C class objects. Parallel structure to
    /// `objc_selector_cache` — kept as an insertion-ordered list of
    /// (class_name, slot_GlobalId) so the constructor that calls
    /// `objc_getClass` per slot at module load is deterministic.
    /// Used by static method dispatch (Phase 3.1) — every
    /// `Cls.static_method(...)` against an `#objc_class` alias resolves
    /// the class object through this cache once per module.
    objc_class_cache: std.ArrayList(ObjcClassEntry),
    /// sx-defined Obj-C classes — every `Cls :: #objc_class("Cls") { ... }`
    /// declaration WITHOUT `extern`. Insertion-ordered so the
    /// class-registration constructors (M1.2 A.4) emit in source order
    /// — parent classes register before children, which matters because
    /// `objc_allocateClassPair(super, ...)` resolves `super` by lookup.
    /// Each entry holds a pointer back into the AST so later passes
    /// (trampoline emission, +alloc/-dealloc synthesis) can re-walk
    /// `members` for fields / methods / `#extends` / `#implements`.
    objc_defined_class_cache: std.ArrayList(ObjcDefinedClassEntry),
    /// Top-level `asm { … }` blocks (ASM stream Phase F), in source order.
    /// Each is verbatim assembly appended to the LLVM module via
    /// `LLVMAppendModuleInlineAsm` at emit time; multiple blocks concatenate.
    global_asm: std.ArrayList([]const u8),
    alloc: Allocator,
    /// Owns the per-instruction operand slices the Builder dupes (aggregate
    /// fields, call args, branch args, switch cases, block params). These live
    /// for the module's lifetime and are never freed individually — an arena
    /// reclaims them all in `deinit`, matching the compiler's arena-style
    /// memory model and keeping the leak-checking test allocator clean.
    slice_arena: std.heap.ArenaAllocator,
    /// True when this module's program imports `std.sx` (and therefore
    /// has the `Context` type). Set by lowering's Pass 0 pre-scan. Read
    /// by emit_llvm to decide whether closure/fn-pointer call sites
    /// need `__sx_ctx` prepended to their LLVM args/types.
    has_implicit_ctx: bool = false,

    pub const ObjcSelectorEntry = struct { sel: []const u8, slot: GlobalId };
    pub const ObjcClassEntry = struct { name: []const u8, slot: GlobalId };
    /// Pointer back to the AST node lets later passes re-walk `members`
    /// for fields / methods / `#extends` / `#implements` without
    /// duplicating that data here. `methods` holds emit-time registration
    /// info derived in lower.zig (selector mangling + type encoding +
    /// IMP symbol name) so emit_llvm can call `class_addMethod` per
    /// instance method without re-resolving types from the AST.
    pub const ObjcDefinedClassEntry = struct {
        name: []const u8,
        decl: *const ast.RuntimeClassDecl,
        methods: []const ObjcDefinedMethodEntry = &.{},
        /// Pre-resolved Obj-C runtime name of the parent class, so
        /// emit_llvm can pass it to `objc_getClass(parent)` /
        /// `objc_allocateClassPair(super, ...)` without walking the
        /// sx-side runtime_class_map (which lives in lower.zig).
        /// Defaults to "NSObject" when no `#extends` member is present.
        parent_objc_name: []const u8 = "NSObject",
    };

    pub const ObjcDefinedMethodEntry = struct {
        sel: []const u8, // mangled Obj-C selector (`add:and:`)
        encoding: []const u8, // Apple-runtime type encoding (`v@:ii`)
        imp_name: []const u8, // C-ABI trampoline symbol (`__Cls_method_imp`)
        is_class: bool = false, // true ⇒ register on the metaclass (M2.1 class methods)
    };

    pub fn init(alloc: Allocator) Module {
        return .{
            .types = TypeTable.init(alloc),
            .functions = std.ArrayList(Function).empty,
            .globals = std.ArrayList(Global).empty,
            .impl_table = ImplTable.init(alloc),
            .objc_selector_cache = std.ArrayList(ObjcSelectorEntry).empty,
            .objc_class_cache = std.ArrayList(ObjcClassEntry).empty,
            .objc_defined_class_cache = std.ArrayList(ObjcDefinedClassEntry).empty,
            .global_asm = std.ArrayList([]const u8).empty,
            .alloc = alloc,
            .slice_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Module) void {
        for (self.functions.items) |*func| {
            func.deinit(self.alloc);
        }
        self.functions.deinit(self.alloc);
        self.globals.deinit(self.alloc);
        self.impl_table.deinit();
        self.objc_selector_cache.deinit(self.alloc);
        self.objc_class_cache.deinit(self.alloc);
        self.objc_defined_class_cache.deinit(self.alloc);
        self.global_asm.deinit(self.alloc);
        self.types.deinit();
        self.slice_arena.deinit();
    }

    /// Linear scan — N is the count of UNIQUE selectors per program,
    /// not the count of call sites. Real programs hit dozens, not
    /// millions; a hashmap would be premature here.
    pub fn lookupObjcSelector(self: *const Module, sel: []const u8) ?GlobalId {
        for (self.objc_selector_cache.items) |entry| {
            if (std.mem.eql(u8, entry.sel, sel)) return entry.slot;
        }
        return null;
    }

    pub fn appendObjcSelector(self: *Module, sel: []const u8, slot: GlobalId) void {
        self.objc_selector_cache.append(self.alloc, .{ .sel = sel, .slot = slot }) catch unreachable;
    }

    /// Linear scan — same rationale as `lookupObjcSelector`.
    pub fn lookupObjcClass(self: *const Module, name: []const u8) ?GlobalId {
        for (self.objc_class_cache.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.slot;
        }
        return null;
    }

    pub fn appendObjcClass(self: *Module, name: []const u8, slot: GlobalId) void {
        self.objc_class_cache.append(self.alloc, .{ .name = name, .slot = slot }) catch unreachable;
    }

    /// Linear scan over sx-defined Obj-C classes.
    pub fn lookupObjcDefinedClass(self: *const Module, name: []const u8) ?*const ast.RuntimeClassDecl {
        for (self.objc_defined_class_cache.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.decl;
        }
        return null;
    }

    pub fn appendObjcDefinedClass(self: *Module, name: []const u8, decl: *const ast.RuntimeClassDecl) void {
        self.objc_defined_class_cache.append(self.alloc, .{ .name = name, .decl = decl }) catch unreachable;
    }

    /// Attach derived method-registration data to an existing
    /// `objc_defined_class_cache` entry. emit_llvm reads this slice to
    /// emit `class_addMethod` calls per instance method.
    pub fn setObjcDefinedClassMethods(self: *Module, name: []const u8, methods: []const ObjcDefinedMethodEntry) void {
        for (self.objc_defined_class_cache.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.methods = methods;
                return;
            }
        }
    }

    /// Set the resolved Obj-C runtime parent name on a cache entry.
    pub fn setObjcDefinedClassParent(self: *Module, name: []const u8, parent_objc_name: []const u8) void {
        for (self.objc_defined_class_cache.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.parent_objc_name = parent_objc_name;
                return;
            }
        }
    }

    pub fn addFunction(self: *Module, func: Function) FuncId {
        const id = FuncId.fromIndex(@intCast(self.functions.items.len));
        self.functions.append(self.alloc, func) catch unreachable;
        return id;
    }

    pub fn getFunction(self: *const Module, id: FuncId) *const Function {
        return &self.functions.items[id.index()];
    }

    pub fn getFunctionMut(self: *Module, id: FuncId) *Function {
        return &self.functions.items[id.index()];
    }

    pub fn addGlobal(self: *Module, global: Global) GlobalId {
        const id = GlobalId.fromIndex(@intCast(self.globals.items.len));
        self.globals.append(self.alloc, global) catch unreachable;
        return id;
    }
};

// ── ImplTable ───────────────────────────────────────────────────────────

pub const ImplKey = struct {
    protocol: TypeId,
    concrete: TypeId,
};

pub const ImplTable = struct {
    map: std.HashMap(ImplKey, []const FuncId, ImplKeyContext, 80),
    alloc: Allocator,

    pub fn init(alloc: Allocator) ImplTable {
        return .{
            .map = std.HashMap(ImplKey, []const FuncId, ImplKeyContext, 80).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ImplTable) void {
        self.map.deinit();
    }

    pub fn put(self: *ImplTable, key: ImplKey, methods: []const FuncId) void {
        self.map.put(key, methods) catch unreachable;
    }

    pub fn get(self: *const ImplTable, key: ImplKey) ?[]const FuncId {
        return self.map.get(key);
    }

    const ImplKeyContext = struct {
        pub fn hash(_: ImplKeyContext, key: ImplKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key.protocol));
            h.update(std.mem.asBytes(&key.concrete));
            return h.final();
        }

        pub fn eql(_: ImplKeyContext, a: ImplKey, b: ImplKey) bool {
            return a.protocol == b.protocol and a.concrete == b.concrete;
        }
    };
};

// ── Builder ─────────────────────────────────────────────────────────────
// Fluent API for constructing one function at a time.

/// A `const_float` instruction read back from its Ref: the compile-time value
/// and the span it was emitted with.
pub const ConstFloatInfo = struct {
    value: f64,
    span: Span,
};

pub const Builder = struct {
    module: *Module,
    func: ?FuncId = null,
    current_block: ?BlockId = null,
    /// Running instruction counter within the current function (for Ref assignment).
    inst_counter: u32 = 0,
    /// Source span stamped onto every instruction emitted via `emit`/`emitVoid`
    /// (ERR E3.0). Lowering sets it (save/restore) at each AST node so the IR
    /// carries per-instruction locations for DWARF `.debug_line` + comptime
    /// frame resolution. Defaults empty for instructions emitted outside a
    /// node context (synthetic prologue/epilogue, etc.).
    current_span: Span = .{},

    pub fn init(module: *Module) Builder {
        return .{ .module = module };
    }

    // ── Function setup ──────────────────────────────────────────────

    pub fn beginFunction(self: *Builder, name: StringId, params: []const Function.Param, ret_ty: TypeId) FuncId {
        // Check if there's an existing extern stub with this name — upgrade it in-place
        for (self.module.functions.items, 0..) |*existing, i| {
            if (existing.name == name and existing.is_extern) {
                existing.is_extern = false;
                existing.linkage = .internal;
                existing.params = self.module.slice_arena.allocator().dupe(Function.Param, params) catch params;
                existing.ret = ret_ty;
                const id = FuncId.fromIndex(@intCast(i));
                self.func = id;
                self.inst_counter = @intCast(params.len);
                self.current_block = null;
                return id;
            }
        }
        const func = Function.init(name, params, ret_ty);
        const id = self.module.addFunction(func);
        self.func = id;
        // Reserve refs 0..N-1 for function parameters; instructions start at ref N.
        self.inst_counter = @intCast(params.len);
        self.current_block = null;
        return id;
    }

    /// Declare an extern function (no body, external linkage).
    pub fn declareExtern(self: *Builder, name: StringId, params: []const Function.Param, ret_ty: TypeId) FuncId {
        var func = Function.init(name, params, ret_ty);
        func.is_extern = true;
        func.linkage = .external;
        const id = self.module.addFunction(func);
        return id;
    }

    pub fn finalize(self: *Builder) void {
        self.func = null;
        self.current_block = null;
        self.inst_counter = 0;
    }

    // ── Blocks ──────────────────────────────────────────────────────

    pub fn appendBlock(self: *Builder, name: StringId, params: []const TypeId) BlockId {
        const f = self.currentFunc();
        const id = BlockId.fromIndex(@intCast(f.blocks.items.len));
        // Dupe params so the block owns the memory (callers may pass stack slices).
        const owned_params = if (params.len > 0)
            (self.module.slice_arena.allocator().dupe(TypeId, params) catch unreachable)
        else
            params;
        f.blocks.append(self.module.alloc, Block.init(name, owned_params)) catch unreachable;
        return id;
    }

    pub fn switchToBlock(self: *Builder, block: BlockId) void {
        self.current_block = block;
        // Record the starting ref index for this block
        const func = self.currentFunc();
        const blk = &func.blocks.items[block.index()];
        blk.first_ref = self.inst_counter;
    }

    /// Get the type of a previously emitted instruction Ref. A ref that can't
    /// be located (no active function, or an out-of-range ref) has no knowable
    /// type — return the `.unresolved` sentinel rather than a fabricated `.i64`.
    pub fn getRefType(self: *Builder, ref: Ref) TypeId {
        if (self.func == null) return .unresolved;
        const func = self.currentFunc();
        const ref_idx = @intFromEnum(ref);
        // Check function parameters first (refs 0..N-1)
        if (ref_idx < func.params.len) {
            return func.params[ref_idx].ty;
        }
        for (func.blocks.items) |*block| {
            const first = block.first_ref;
            if (ref_idx >= first and ref_idx < first + @as(u32, @intCast(block.insts.items.len))) {
                return block.insts.items[ref_idx - first].ty;
            }
        }
        return .unresolved;
    }

    /// The Op of the instruction that defined `ref`, or null when the ref is
    /// not an instruction result in the current function (a function/block
    /// parameter, or an out-of-range ref). Returns the Op by value — callers
    /// inspect the defining shape (e.g. "was this value loaded from storage,
    /// and from which address?"), they don't mutate it.
    pub fn getRefOp(self: *Builder, ref: Ref) ?Op {
        if (self.func == null) return null;
        const func = self.currentFunc();
        const ref_idx = @intFromEnum(ref);
        if (ref_idx < func.params.len) return null;
        for (func.blocks.items) |*block| {
            const first = block.first_ref;
            if (ref_idx >= first and ref_idx < first + @as(u32, @intCast(block.insts.items.len))) {
                return block.insts.items[ref_idx - first].op;
            }
        }
        return null;
    }

    /// If `ref` points at a compile-time `const_float` instruction, return its
    /// value and the span it was emitted with; else null. The implicit
    /// float→int coercion rule reads this to fold an integral literal to its
    /// int (and to locate a non-integral one for its diagnostic).
    /// True iff `ref` is a `const_string` instruction — a string LITERAL
    /// value (terminated constant data), the only string shape that may
    /// implicitly coerce to `cstring`.
    pub fn isConstString(self: *Builder, ref: Ref) bool {
        if (self.func == null) return false;
        const func = self.currentFunc();
        const ref_idx = @intFromEnum(ref);
        if (ref_idx < func.params.len) return false;
        for (func.blocks.items) |*block| {
            const first = block.first_ref;
            if (ref_idx >= first and ref_idx < first + @as(u32, @intCast(block.insts.items.len))) {
                const i = block.insts.items[ref_idx - first];
                return i.op == .const_string;
            }
        }
        return false;
    }

    pub fn constFloatInfo(self: *Builder, ref: Ref) ?ConstFloatInfo {
        if (self.func == null) return null;
        const func = self.currentFunc();
        const ref_idx = @intFromEnum(ref);
        if (ref_idx < func.params.len) return null;
        for (func.blocks.items) |*block| {
            const first = block.first_ref;
            if (ref_idx >= first and ref_idx < first + @as(u32, @intCast(block.insts.items.len))) {
                const i = block.insts.items[ref_idx - first];
                return switch (i.op) {
                    .const_float => |v| .{ .value = v, .span = i.span },
                    else => null,
                };
            }
        }
        return null;
    }

    // ── Emit helpers ────────────────────────────────────────────────

    pub fn emit(self: *Builder, op: Op, ty: TypeId) Ref {
        return self.emitSpan(op, ty, self.current_span);
    }

    fn emitSpan(self: *Builder, op: Op, ty: TypeId, span: Span) Ref {
        const block = self.currentBlock();
        const ref = Ref.fromIndex(self.inst_counter);
        self.inst_counter += 1;
        block.insts.append(self.module.alloc, .{ .op = op, .ty = ty, .span = span }) catch unreachable;
        return ref;
    }

    /// Emit an instruction with no meaningful result (terminators, stores).
    pub fn emitVoid(self: *Builder, op: Op, ty: TypeId) void {
        const block = self.currentBlock();
        self.inst_counter += 1;
        block.insts.append(self.module.alloc, .{ .op = op, .ty = ty, .span = self.current_span }) catch unreachable;
    }

    // ── Constants ───────────────────────────────────────────────────

    pub fn constInt(self: *Builder, val: i64, ty: TypeId) Ref {
        return self.emit(.{ .const_int = val }, ty);
    }

    pub fn constFloat(self: *Builder, val: f64, ty: TypeId) Ref {
        return self.emit(.{ .const_float = val }, ty);
    }

    pub fn constBool(self: *Builder, val: bool) Ref {
        return self.emit(.{ .const_bool = val }, .bool);
    }

    pub fn constString(self: *Builder, val: StringId) Ref {
        return self.emit(.{ .const_string = val }, .string);
    }

    pub fn constNull(self: *Builder, ty: TypeId) Ref {
        return self.emit(.const_null, ty);
    }

    pub fn constUndef(self: *Builder, ty: TypeId) Ref {
        return self.emit(.const_undef, ty);
    }

    /// Comptime-only Type value. Produces a `Value.type_tag(tid)` in
    /// the interp; bails loudly in LLVM emit (Type is comptime-only).
    /// The result-Ref's IR type is `.any` to flag the value as
    /// "untyped at runtime" — emitters that try to coerce it will
    /// fail loudly rather than silently materialise the TypeId as an
    /// int.
    pub fn constType(self: *Builder, tid: TypeId) Ref {
        // A Type value is its own 8-byte builtin handle (`.type_value`), a bare
        // i64 carrying `tid.index()` — distinct from the 16-byte boxed `.any`.
        // Flowing it into an `Any` slot boxes it (`{ tag = .any.index(), value =
        // tid }`) via the standard box-any coercion. The interp keeps the
        // high-fidelity `.type_tag` Value for comptime ops.
        return self.emit(.{ .const_type = tid }, .type_value);
    }

    // ── Arithmetic ──────────────────────────────────────────────────

    pub fn add(self: *Builder, lhs: Ref, rhs: Ref, ty: TypeId) Ref {
        return self.emit(.{ .add = .{ .lhs = lhs, .rhs = rhs } }, ty);
    }

    pub fn sub(self: *Builder, lhs: Ref, rhs: Ref, ty: TypeId) Ref {
        return self.emit(.{ .sub = .{ .lhs = lhs, .rhs = rhs } }, ty);
    }

    pub fn mul(self: *Builder, lhs: Ref, rhs: Ref, ty: TypeId) Ref {
        return self.emit(.{ .mul = .{ .lhs = lhs, .rhs = rhs } }, ty);
    }

    pub fn div(self: *Builder, lhs: Ref, rhs: Ref, ty: TypeId) Ref {
        return self.emit(.{ .div = .{ .lhs = lhs, .rhs = rhs } }, ty);
    }

    // ── Comparison ──────────────────────────────────────────────────

    pub fn cmpEq(self: *Builder, lhs: Ref, rhs: Ref) Ref {
        return self.emit(.{ .cmp_eq = .{ .lhs = lhs, .rhs = rhs } }, .bool);
    }

    pub fn cmpLt(self: *Builder, lhs: Ref, rhs: Ref) Ref {
        return self.emit(.{ .cmp_lt = .{ .lhs = lhs, .rhs = rhs } }, .bool);
    }

    pub fn cmpGt(self: *Builder, lhs: Ref, rhs: Ref) Ref {
        return self.emit(.{ .cmp_gt = .{ .lhs = lhs, .rhs = rhs } }, .bool);
    }

    // ── Memory ──────────────────────────────────────────────────────

    pub fn alloca(self: *Builder, ty: TypeId) Ref {
        const ptr_ty = self.module.types.ptrTo(ty);
        return self.emit(.{ .alloca = ty }, ptr_ty);
    }

    pub fn load(self: *Builder, ptr: Ref, ty: TypeId) Ref {
        return self.emit(.{ .load = .{ .operand = ptr } }, ty);
    }

    pub fn store(self: *Builder, ptr: Ref, val: Ref) void {
        const val_ty = self.getRefType(val);
        self.emitVoid(.{ .store = .{ .ptr = ptr, .val = val, .val_ty = val_ty } }, .void);
    }

    // ── Struct ops ──────────────────────────────────────────────────

    pub fn structInit(self: *Builder, fields: []const Ref, ty: TypeId) Ref {
        const owned = self.module.slice_arena.allocator().dupe(Ref, fields) catch unreachable;
        return self.emit(.{ .struct_init = .{ .fields = owned } }, ty);
    }

    pub fn structGet(self: *Builder, base: Ref, field_index: u32, ty: TypeId) Ref {
        return self.emit(.{ .struct_get = .{ .base = base, .field_index = field_index } }, ty);
    }

    pub fn structGep(self: *Builder, base: Ref, field_index: u32, ty: TypeId) Ref {
        return self.emit(.{ .struct_gep = .{ .base = base, .field_index = field_index } }, ty);
    }

    pub fn structGepTyped(self: *Builder, base: Ref, field_index: u32, ty: TypeId, base_type: TypeId) Ref {
        return self.emit(.{ .struct_gep = .{ .base = base, .field_index = field_index, .base_type = base_type } }, ty);
    }

    // ── Enum ops ────────────────────────────────────────────────────

    pub fn enumInit(self: *Builder, tag: u32, payload: Ref, ty: TypeId) Ref {
        return self.emit(.{ .enum_init = .{ .tag = tag, .payload = payload } }, ty);
    }

    pub fn enumTag(self: *Builder, val: Ref, tag_ty: TypeId) Ref {
        return self.emit(.{ .enum_tag = .{ .operand = val } }, tag_ty);
    }

    // ── Optional ops ────────────────────────────────────────────────

    pub fn optionalWrap(self: *Builder, val: Ref, ty: TypeId) Ref {
        return self.emit(.{ .optional_wrap = .{ .operand = val } }, ty);
    }

    pub fn optionalUnwrap(self: *Builder, val: Ref, ty: TypeId) Ref {
        return self.emit(.{ .optional_unwrap = .{ .operand = val } }, ty);
    }

    pub fn optionalHasValue(self: *Builder, val: Ref) Ref {
        return self.emit(.{ .optional_has_value = .{ .operand = val } }, .bool);
    }

    // ── Calls ───────────────────────────────────────────────────────

    pub fn call(self: *Builder, callee: FuncId, args: []const Ref, ret_ty: TypeId) Ref {
        const owned = self.module.slice_arena.allocator().dupe(Ref, args) catch unreachable;
        return self.emit(.{ .call = .{ .callee = callee, .args = owned } }, ret_ty);
    }

    pub fn callClosure(self: *Builder, callee: Ref, args: []const Ref, ret_ty: TypeId) Ref {
        const owned = self.module.slice_arena.allocator().dupe(Ref, args) catch unreachable;
        return self.emit(.{ .call_closure = .{ .callee = callee, .args = owned } }, ret_ty);
    }

    pub fn callBuiltin(self: *Builder, builtin: inst.BuiltinId, args: []const Ref, ret_ty: TypeId) Ref {
        const owned = self.module.slice_arena.allocator().dupe(Ref, args) catch unreachable;
        return self.emit(.{ .call_builtin = .{ .builtin = builtin, .args = owned } }, ret_ty);
    }

    // ── Closure ─────────────────────────────────────────────────────

    pub fn closureCreate(self: *Builder, func_id: FuncId, env: Ref, ty: TypeId) Ref {
        return self.emit(.{ .closure_create = .{ .func = func_id, .env = env } }, ty);
    }

    // ── Conversions ─────────────────────────────────────────────────

    pub fn widen(self: *Builder, operand: Ref, from: TypeId, to: TypeId) Ref {
        return self.emit(.{ .widen = .{ .operand = operand, .from = from, .to = to } }, to);
    }

    pub fn narrow(self: *Builder, operand: Ref, from: TypeId, to: TypeId) Ref {
        return self.emit(.{ .narrow = .{ .operand = operand, .from = from, .to = to } }, to);
    }

    // ── Any ─────────────────────────────────────────────────────────

    /// Emit a `box_any` over an already-computed ADDRESS of the value.
    /// Callers with a VALUE ref use `Lowering.boxAnyOf`, which decides
    /// borrow-vs-spill and normalizes arbitrary-width int tags.
    pub fn boxAnyAt(self: *Builder, operand_addr: Ref, source_type: TypeId) Ref {
        return self.emit(.{ .box_any = .{ .operand = operand_addr, .source_type = source_type } }, .any);
    }

    pub fn anyData(self: *Builder, operand: Ref, ptr_ty: TypeId) Ref {
        return self.emit(.{ .any_data = .{ .operand = operand } }, ptr_ty);
    }

    pub fn makeAny(self: *Builder, tag: Ref, data: Ref) Ref {
        return self.emit(.{ .make_any = .{ .tag = tag, .data = data } }, .any);
    }

    // ── Terminators ─────────────────────────────────────────────────

    pub fn br(self: *Builder, target: BlockId, args: []const Ref) void {
        const owned = self.module.slice_arena.allocator().dupe(Ref, args) catch unreachable;
        self.emitVoid(.{ .br = .{ .target = target, .args = owned } }, .void);
    }

    pub fn condBr(self: *Builder, cond: Ref, then_target: BlockId, then_args: []const Ref, else_target: BlockId, else_args: []const Ref) void {
        const t_args = self.module.slice_arena.allocator().dupe(Ref, then_args) catch unreachable;
        const e_args = self.module.slice_arena.allocator().dupe(Ref, else_args) catch unreachable;
        self.emitVoid(.{ .cond_br = .{
            .cond = cond,
            .then_target = then_target,
            .then_args = t_args,
            .else_target = else_target,
            .else_args = e_args,
        } }, .void);
    }

    pub fn ret(self: *Builder, val: Ref, ty: TypeId) void {
        self.emitVoid(.{ .ret = .{ .operand = val } }, ty);
    }

    pub fn retVoid(self: *Builder) void {
        self.emitVoid(.ret_void, .void);
    }

    pub fn switchBr(self: *Builder, operand: Ref, cases: []const inst.SwitchBranch.Case, default: BlockId, default_args: []const Ref) void {
        const owned_cases = self.module.slice_arena.allocator().dupe(inst.SwitchBranch.Case, cases) catch unreachable;
        const owned_default_args = self.module.slice_arena.allocator().dupe(Ref, default_args) catch unreachable;
        self.emitVoid(.{ .switch_br = .{
            .operand = operand,
            .cases = owned_cases,
            .default = default,
            .default_args = owned_default_args,
        } }, .void);
    }

    pub fn emitUnreachable(self: *Builder) void {
        self.emitVoid(.@"unreachable", .void);
    }

    // ── Block params ───────────────────────────────────────────────

    pub fn blockParam(self: *Builder, block: BlockId, param_index: u32, ty: TypeId) Ref {
        return self.emit(.{ .block_param = .{ .block = block, .param_index = param_index } }, ty);
    }

    // ── Internal helpers ────────────────────────────────────────────

    pub fn currentFunc(self: *Builder) *Function {
        return self.module.getFunctionMut(self.func.?);
    }

    fn currentBlock(self: *Builder) *Block {
        const f = self.currentFunc();
        return &f.blocks.items[self.current_block.?.index()];
    }
};
