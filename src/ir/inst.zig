const std = @import("std");
const types = @import("types.zig");
const TypeId = types.TypeId;
const StringId = types.StringId;

// ── Handles ─────────────────────────────────────────────────────────────

/// Reference to an SSA value (instruction result).
pub const Ref = enum(u32) {
    /// Sentinel for "no value" / unused operand.
    none = std.math.maxInt(u32),
    _,

    pub fn index(self: Ref) u32 {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: u32) Ref {
        return @enumFromInt(i);
    }

    pub fn isNone(self: Ref) bool {
        return self == .none;
    }
};

pub const BlockId = enum(u32) {
    _,

    pub fn index(self: BlockId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: u32) BlockId {
        return @enumFromInt(i);
    }
};

pub const FuncId = enum(u32) {
    _,

    pub fn index(self: FuncId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: u32) FuncId {
        return @enumFromInt(i);
    }
};

pub const GlobalId = enum(u32) {
    _,

    pub fn index(self: GlobalId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: u32) GlobalId {
        return @enumFromInt(i);
    }
};

// ── Span ────────────────────────────────────────────────────────────────

pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,
};

// ── Instruction ─────────────────────────────────────────────────────────

pub const Inst = struct {
    op: Op,
    ty: TypeId,
    span: Span = .{},
};

// ── Op (tagged union) ───────────────────────────────────────────────────

pub const Op = union(enum) {
    // ── Constants ───────────────────────────────────────────────────
    const_int: i64,
    const_float: f64,
    const_bool: bool,
    const_string: StringId,
    const_null,
    const_undef, // `---` undefined initializer
    /// ERR E4.1 — `is_comptime()` builtin. The SAME lowered IR is run by both
    /// the comptime interpreter and the compiled backend, so this can't fold at
    /// lower time: the interp evaluates it to `true`, emit_llvm emits constant
    /// `false`. Lets stdlib (`process.exit`, `assert`) take a comptime-only
    /// diagnostic branch that dead-codes out of compiled binaries.
    is_comptime,
    /// ERR E4.1 — `trace.print_interpreter_frames()`. At comptime the interp
    /// walks its sx call-frame chain and appends it to the output; in compiled
    /// code it's a no-op (only ever reached from a dead `is_comptime()` branch,
    /// where there is no interpreter stack to walk).
    interp_print_frames,
    /// ERR E3.0 slice 3a — a return-trace frame value (`u64`) for the push site.
    /// Niladic + span-stamped: it carries NO operands; each backend derives the
    /// frame from its own context. `emit_llvm` resolves this instruction's span
    /// + the current function → `{file,line,col,func}`, interns a `Frame` global,
    /// and yields its address (`ptrtoint`). `interp` yields a packed
    /// `(func_id << 32 | span.start)` for the comptime resolver (slice 3b). The
    /// result feeds the existing `sx_trace_push(u64)` call.
    trace_frame,
    /// ERR E3.0 slice 3b — the read-side resolver: a raw trace-buffer `u64` →
    /// a `Frame` value. The mirror of `trace_frame`'s context split.
    /// `emit_llvm` reinterprets the operand as `*Frame` and loads it (the value
    /// `trace_frame` stamped in). `interp` unpacks `(func_id, span.start)` and
    /// resolves it via the module's functions + the source map into a `Frame`
    /// aggregate. Result type is the `Frame` `TypeId`.
    trace_resolve: UnaryOp,
    /// Comptime-only Type value. Carried as a `Value.type_tag(TypeId)`
    /// in the interpreter. NEVER emitted to LLVM — types are erased
    /// after lowering. `emit_llvm` bails loudly if it sees one,
    /// surfacing a "Type value reached runtime" diagnostic instead of
    /// silently lowering to a stale int.
    const_type: TypeId,

    // ── Arithmetic ──────────────────────────────────────────────────
    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,
    mod: BinOp,
    neg: UnaryOp, // unary -x

    // ── Bitwise ─────────────────────────────────────────────────────
    bit_and: BinOp,
    bit_or: BinOp,
    bit_xor: BinOp,
    bit_not: UnaryOp,
    shl: BinOp,
    shr: BinOp,

    // ── Comparison ──────────────────────────────────────────────────
    cmp_eq: BinOp,
    cmp_ne: BinOp,
    cmp_lt: BinOp,
    cmp_le: BinOp,
    cmp_gt: BinOp,
    cmp_ge: BinOp,
    str_eq: BinOp, // string/slice equality via memcmp
    str_ne: BinOp, // string/slice inequality via memcmp

    // ── Logical ─────────────────────────────────────────────────────
    bool_and: BinOp, // short-circuit &&
    bool_or: BinOp, // short-circuit ||
    bool_not: UnaryOp,

    // ── Conversions ─────────────────────────────────────────────────
    widen: Conversion, // safe widening (i32 → i64)
    narrow: Conversion, // truncation via `xx` (i64 → i32)
    bitcast: Conversion, // reinterpret bits
    int_to_float: Conversion,
    float_to_int: Conversion,

    // ── Memory ──────────────────────────────────────────────────────
    alloca: TypeId, // stack allocation, result is *T
    load: UnaryOp, // load from pointer
    store: Store, // store value to pointer

    // ── Atomics ─────────────────────────────────────────────────────
    atomic_load: AtomicLoad, // atomic load from pointer with memory ordering
    atomic_store: AtomicStore, // atomic store to pointer with memory ordering
    atomic_rmw: AtomicRmw, // atomic read-modify-write; result is the OLD value
    atomic_cmpxchg: AtomicCmpxchg, // atomic compare-exchange; result is ?T (null = success)
    atomic_fence: AtomicFence, // standalone memory fence; void result

    // ── Struct ops ──────────────────────────────────────────────────
    struct_init: Aggregate, // construct struct from field values
    struct_get: FieldAccess, // read struct field by index
    struct_gep: FieldAccess, // get pointer to struct field (GEP)

    // ── Enum ops ────────────────────────────────────────────────────
    enum_init: EnumInit, // construct enum value (tag + optional payload)
    enum_tag: UnaryOp, // extract tag from enum/union
    enum_payload: FieldAccess, // extract payload from tagged union

    // ── Union ops ───────────────────────────────────────────────────
    union_get: FieldAccess, // read union field (reinterpret)
    union_gep: FieldAccess, // pointer to union field

    // ── Array/Slice ops ─────────────────────────────────────────────
    index_get: BinOp, // arr[idx] → value
    index_gep: BinOp, // &arr[idx] → pointer
    length: UnaryOp, // .len on slice/string/array
    data_ptr: UnaryOp, // .ptr on slice/string
    subslice: Subslice, // arr[lo..hi]
    array_to_slice: UnaryOp, // [N]T → []T

    // ── Tuple ops ───────────────────────────────────────────────────
    tuple_init: Aggregate, // construct tuple from values
    tuple_get: FieldAccess, // read tuple element by index

    // ── Optional ops ────────────────────────────────────────────────
    optional_wrap: UnaryOp, // T → ?T
    optional_unwrap: UnaryOp, // ?T → T (UB if null)
    optional_has_value: UnaryOp, // ?T → bool
    optional_coalesce: BinOp, // a ?? b

    // ── Pointer ops ─────────────────────────────────────────────────
    addr_of: UnaryOp, // @x → *T
    deref: UnaryOp, // p.* → T

    // ── Vector ops ──────────────────────────────────────────────────
    vec_splat: UnaryOp, // scalar → vector (broadcast)
    vec_extract: BinOp, // vec[idx] → scalar
    vec_insert: TriOp, // vec, idx, val → new_vec

    // ── Calls ───────────────────────────────────────────────────────
    call: Call,
    call_indirect: CallIndirect,
    call_closure: CallIndirect,
    call_builtin: BuiltinCall,

    /// `#objc_call(ReturnT)(recv, sel, args...)` — dispatched through
    /// `objc_msgSend`. emit_llvm.zig synthesizes a per-call-site LLVM
    /// function type from the arg/result Refs and reuses a single
    /// declared `@objc_msgSend` symbol across all return-type
    /// variants. Encoded as its own opcode (instead of `.call` /
    /// `.call_indirect`) so the IR doesn't need a separate FuncId
    /// per signature shape.
    objc_msg_send: ObjcMsgSend,

    /// `#jni_call(ReturnT)(env, target, name, sig, args...)` and
    /// `#jni_static_call(ReturnT)(env, class, name, sig, args...)`.
    /// emit_llvm.zig expands this into the JNI vtable indirection:
    /// `(*env)->GetObjectClass` (instance only) → `GetMethodID` /
    /// `GetStaticMethodID` → `Call<Type>Method` / `CallStatic<Type>Method`.
    /// Method-ID caching across call sites is added in step 1.17.
    jni_msg_send: JniMsgSend,

    /// `asm volatile? { "tmpl", operands…, clobbers(.…) }` — inline assembly
    /// (ASM stream, design §II.6). emit_llvm.zig assembles the LLVM constraint
    /// string + rewrites the `%[name]` template, then `LLVMGetInlineAsm` +
    /// `LLVMBuildCall2`. The result rides on `Inst.ty` (void / a scalar / a tuple
    /// of the `out_value` types). Never comptime-evaluable — the interp bails.
    inline_asm: InlineAsm,

    // ── Closure creation ────────────────────────────────────────────
    closure_create: ClosureCreate,

    // ── Globals ─────────────────────────────────────────────────────
    global_get: GlobalId,
    global_addr: GlobalId, // address of a global (pointer, not load)
    global_set: GlobalSet,
    func_ref: FuncId, // reference to a function (for function pointers)

    // ── Block params (SSA phi alternative) ──────────────────────────
    block_param: BlockParam,

    // ── Any type ────────────────────────────────────────────────────
    // `any` is a type-erased BORROW `{ type_tag: i64, data: pointer }`
    // (Odin Raw_Any analog). box_any's operand is the ADDRESS of the
    // value (lowering borrows an lvalue's storage or spills an rvalue
    // to a frame temp); unbox_any is a typed LOAD through the data
    // pointer; any_data reads the data word itself (no load); make_any
    // assembles a view from a RUNTIME tag + address (the C2 raw layer).
    box_any: BoxAny, // *T → any (erase type; operand is the value's address)
    unbox_any: UnaryOp, // any → T (typed load through the view)
    any_data: UnaryOp, // any → data pointer (the view address, no load)
    make_any: MakeAny, // {tag, data} → any (assemble a view; tag is runtime)

    // ── Reflection ─────────────────────────────────────────────────
    field_name_get: FieldReflect, // field_name(T, i) → string (runtime index)
    field_value_get: FieldReflect, // field_value(s, i) → Any (runtime struct + index)
    error_tag_name_get: UnaryOp, // error_tag_name(e) → string (runtime tag id → name, via the always-linked tag-name table)

    // ── Terminators ─────────────────────────────────────────────────
    br: Branch,
    cond_br: CondBranch,
    switch_br: SwitchBranch,
    ret: UnaryOp,
    ret_void,
    @"unreachable",

    // ── Misc ────────────────────────────────────────────────────────
    /// No-op placeholder for unlowered AST nodes.
    placeholder: StringId, // name of the unlowered construct
};

// ── Operand structs ─────────────────────────────────────────────────────

pub const UnaryOp = struct {
    operand: Ref,
};

pub const BinOp = struct {
    lhs: Ref,
    rhs: Ref,
};

pub const TriOp = struct {
    a: Ref,
    b: Ref,
    c: Ref,
};

pub const Store = struct {
    ptr: Ref,
    val: Ref,
    /// Declared type of the value being stored. Threaded through so the
    /// interp's raw-pointer store knows the destination byte width — a
    /// `.int` Value alone is ambiguous (i8/i16/i32/i64/u*/usize/pointer
    /// all flatten to `.int`). The LLVM emitter ignores this (LLVM knows
    /// the width from the SSA value's type already).
    val_ty: TypeId = .void,
};

/// Memory ordering for atomic ops. The sx-surface `Ordering` enum
/// (`relaxed`/`acquire`/`release`/`acq_rel`/`seq_cst`) is read statically at
/// lower-time (the arg MUST be a constant enum literal) and baked here, so the
/// op carries no runtime ordering operand. The LLVM mapping is EXPLICIT (LLVM's
/// `LLVMAtomicOrdering` is non-contiguous: Monotonic=2/Acquire=4/…/SeqCst=7) —
/// never an identity cast.
pub const AtomicOrdering = enum { relaxed, acquire, release, acq_rel, seq_cst };

pub const AtomicLoad = struct {
    ptr: Ref,
    ordering: AtomicOrdering,
};

pub const AtomicStore = struct {
    ptr: Ref,
    val: Ref,
    /// Declared type of the stored value (same role as `Store.val_ty`).
    val_ty: TypeId = .void,
    ordering: AtomicOrdering,
};

/// Atomic read-modify-write operation kind. `min`/`max` pick the signed vs
/// unsigned LLVM op (`Min`/`Max` vs `UMin`/`UMax`) from the value type's
/// signedness at emit time. No `nand` (deliberately omitted).
pub const RmwKind = enum { add, sub, @"and", @"or", xor, min, max, xchg };

pub const AtomicRmw = struct {
    ptr: Ref,
    operand: Ref,
    /// Declared type of the operand / result (drives byte width + signedness).
    val_ty: TypeId = .void,
    ordering: AtomicOrdering,
    kind: RmwKind,
};

/// Atomic compare-exchange. The result is `?T` (an Optional of `val_ty`):
/// `null` means SUCCESS (the stored value equalled `cmp`, replaced by `new`);
/// a present value is the ACTUAL current value on failure (for a retry loop).
/// `weak` permits spurious failure (LLVM `cmpxchg weak`) — at comptime it
/// behaves as a strong exchange (single-thread, no spurious failure).
pub const AtomicCmpxchg = struct {
    ptr: Ref,
    cmp: Ref,
    new: Ref,
    /// Declared element type `T` (drives byte width; the result type is `?T`).
    val_ty: TypeId = .void,
    success_ordering: AtomicOrdering,
    failure_ordering: AtomicOrdering,
    weak: bool,
};

/// Standalone memory fence (`fence(.seq_cst)`) — no address, void result. The
/// ordering may NOT be `relaxed` (LLVM has no monotonic/unordered fence).
pub const AtomicFence = struct {
    ordering: AtomicOrdering,
};

pub const Conversion = struct {
    operand: Ref,
    from: TypeId,
    to: TypeId,
};

pub const FieldAccess = struct {
    base: Ref,
    field_index: u32,
    /// The IR type of the aggregate being accessed (struct, union, etc.).
    /// Used by the LLVM emitter to resolve the correct type for GEP operations
    /// without guessing from LLVM value chains.
    base_type: ?TypeId = null,
};

pub const Aggregate = struct {
    fields: []const Ref,
};

pub const EnumInit = struct {
    tag: u32,
    payload: Ref, // Ref.none if no payload
};

pub const Subslice = struct {
    base: Ref,
    lo: Ref,
    hi: Ref,
    /// The base operand's IR type (array vs slice vs string). The runtime
    /// backend reads array/slice-ness off `LLVMTypeOf`, but the comptime
    /// interp can't tell a 2-element array from a `{ptr,len}` fat pointer by
    /// Value shape alone, so it consults this. `.void` for old call sites.
    base_ty: TypeId = .void,
};

pub const Call = struct {
    callee: FuncId,
    args: []const Ref,
};

pub const CallIndirect = struct {
    callee: Ref,
    args: []const Ref,
};

/// `#objc_call` dispatch through `objc_msgSend`. emit_llvm reads
/// `recv`/`sel`/each arg's IR type to build the per-call-site LLVM
/// function type; the instruction's own `ty` field (`Inst.ty`) is the
/// Obj-C return type. One declared `@objc_msgSend` symbol is shared
/// across every distinct signature shape.
pub const ObjcMsgSend = struct {
    recv: Ref,
    sel: Ref,
    args: []const Ref, // additional args after recv + sel
};

/// Inline assembly payload (design §II.6). All strings interned; operands in
/// SOURCE ORDER (= the `%N` index space and the LLVM constraint order). The
/// result type rides on `Inst.ty`: void (no value outputs), a scalar (one), or
/// a tuple (N). emit_llvm.zig owns the constraint-string assembly + `%[name]`
/// template rewrite.
pub const InlineAsm = struct {
    /// Interned template, RAW — the `%[name]`→`${N}` rewrite happens at emit.
    template: StringId,
    /// Declaration order preserved (keys `%N` and the LLVM operand order).
    operands: []const AsmOperand,
    /// Interned dot-names from `clobbers(.…)`: "rcx", "cc", "memory", …
    clobbers: []const StringId,
    /// `volatile` — passed as LLVM `HasSideEffects`.
    has_side_effects: bool,

    pub const AsmOperand = struct {
        role: Role,
        /// Effective operand name (explicit `[name]` or auto-derived register);
        /// `.empty` when anonymous.
        name: StringId,
        /// Verbatim constraint, e.g. "={rax}", "=r", "+r", "{rdi}", "r".
        constraint: StringId,
        /// `input` → the value `Ref`; `out_value` → `.none` (the asm yields it);
        /// `out_place` → the place ADDRESS `Ref` (a pointer; the asm result is
        /// `store`d through it).
        operand: Ref,
        /// The value type carried by an OUTPUT slot — `out_value`: its result
        /// type; `out_place`: the pointee type stored through `operand`. `.void`
        /// for inputs (their type comes from the input `Ref`). Lets emit build
        /// the combined LLVM return struct without re-deriving from `Inst.ty`.
        out_ty: TypeId = .void,

        pub const Role = enum { out_value, out_place, input };
    };
};

/// JNI dispatch payload. `env` is `JNIEnv*` (typed as ptr); `target`
/// is a `jobject` for instance calls and a `jclass` for static calls.
/// `name` and `sig` are pointers to NUL-terminated bytes (typically
/// `[*]u8` from a string-literal `.ptr`). When the source-level
/// `name` and `sig` are string literals, `cache_key` carries their
/// content so emit_llvm.zig can intern a shared `jclass GlobalRef` +
/// `jmethodID` slot keyed on `(name, sig)`; otherwise the lookup
/// stays uncached. The dispatch sequence is expanded in
/// emit_llvm.zig — see `Inst.jni_msg_send`.
pub const JniMsgSend = struct {
    env: Ref,
    target: Ref,
    name: Ref,
    sig: Ref,
    args: []const Ref,
    is_static: bool,
    /// `true` when this is a `super.method(args)` dispatch from inside a
    /// `#jni_main` Activity method body — lowers to `CallNonvirtual<T>Method`
    /// against `parent_class_path`. Mutually exclusive with `is_static`.
    is_nonvirtual: bool = false,
    /// `true` when this is a `Foo.new(args)` constructor dispatch — lowers
    /// to `FindClass(parent_class_path) + GetMethodID("<init>", sig) +
    /// NewObject(env, clazz, mid, args...)`. Returns a fresh jobject.
    /// Mutually exclusive with the other dispatch flags.
    is_constructor: bool = false,
    /// Runtime path of the parent class (e.g. `android/app/Activity`) when
    /// `is_nonvirtual` is true, OR of the class being constructed when
    /// `is_constructor` is true. emit_llvm uses `FindClass` to materialise
    /// the jclass at the call site (per-call; caching is follow-up).
    parent_class_path: ?[]const u8 = null,
    cache_key: ?CacheKey = null,
};

pub const CacheKey = struct {
    name_str: []const u8,
    sig_str: []const u8,
};

pub const BuiltinCall = struct {
    builtin: BuiltinId,
    args: []const Ref,
};

pub const BuiltinId = enum(u16) {
    sqrt,
    sin,
    cos,
    floor,
    size_of,
    align_of,
    // Comptime-only reflection builtins. Today's `tryLowerReflectionCall`
    // folds these at lower time when the type argument is statically
    // resolvable — emits a `const_string` / `const_bool` directly.
    // These BuiltinId entries are the FALLBACK path: when the arg is
    // a runtime/interp-time value (e.g. `args[i]` inside a builder
    // body, carrying a `.type_tag(TypeId)` only at interp execution),
    // lowering emits a `builtin_call` to one of these. The interp
    // implements them; emit_llvm bails (Type is comptime-only).
    type_name,
    is_unsigned,
    // Runtime-Type scalar reflection (1a-S2): tag-indexed table reads
    // (sizes/aligns/counts/flag-bits); type_eq is a plain tag compare.
    rt_size_of,
    rt_align_of,
    rt_struct_field_count,
    rt_variant_count,
    rt_is_flags,
    rt_vector_lanes,
    // The tag-word byte width a runtime variant read loads (sign-encoded:
    // negative = sign-extend). Internal — serves fmt's `__sx_any_tag_word`.
    rt_variant_tag_width,
    rt_type_eq,
    // Field-family runtime paths (1a-S3b): master-index [N x ptr] tables →
    // per-type arrays (names reuse the per-type name arrays; type tags,
    // offsets, and variant values get their own). variant_* shares the same
    // member arrays.
    rt_member_name,
    rt_member_type,
    rt_field_offset,
    rt_variant_value,
    // (`declare` and `define` are no longer builtins — they're plain sx over the
    // `declare_type` / `register_type` compiler-API primitives in
    // `modules/std/meta.sx`.)
    // The comptime reflection INVERSE of `define`: read a type's variants
    // (name + payload type) out of the type table and CONSTRUCT the same
    // `.enum(EnumInfo{ variants })` value `define` decodes. Comptime-only
    // (the interp builds the Value aggregate); emit bails (Type is
    // comptime-only). `type_info($T)` round-trips through `define`.
    type_info,
};

pub const ClosureCreate = struct {
    func: FuncId, // trampoline function
    env: Ref, // allocated env pointer (or Ref.none for no captures)
};

pub const GlobalSet = struct {
    global: GlobalId,
    value: Ref,
};

pub const BlockParam = struct {
    block: BlockId,
    param_index: u32,
};

pub const BoxAny = struct {
    operand: Ref, // ADDRESS of the boxed value (borrowed storage or a spilled temp)
    source_type: TypeId,
};

pub const MakeAny = struct {
    tag: Ref, // runtime Type value (i64 tag word)
    data: Ref, // address of the viewed value
};

pub const FieldReflect = struct {
    base: Ref, // struct value (for field_value_get) or Ref.none (for field_name_get)
    index: Ref, // runtime field index
    struct_type: TypeId, // compile-time resolved struct type
};

pub const Branch = struct {
    target: BlockId,
    args: []const Ref, // block param values
};

pub const CondBranch = struct {
    cond: Ref,
    then_target: BlockId,
    then_args: []const Ref,
    else_target: BlockId,
    else_args: []const Ref,
};

pub const SwitchBranch = struct {
    operand: Ref,
    cases: []const Case,
    default: BlockId,
    default_args: []const Ref,

    pub const Case = struct {
        value: i64,
        target: BlockId,
        args: []const Ref,
    };
};

// ── Block ───────────────────────────────────────────────────────────────

pub const Block = struct {
    name: StringId,
    params: []const TypeId, // block parameter types (SSA phi alternative)
    insts: std.ArrayList(Inst),
    first_ref: u32 = 0, // ref index of the first instruction in this block

    pub fn init(name: StringId, params: []const TypeId) Block {
        return .{
            .name = name,
            .params = params,
            .insts = std.ArrayList(Inst).empty,
        };
    }

    pub fn deinit(self: *Block, alloc: std.mem.Allocator) void {
        self.insts.deinit(alloc);
    }
};

// ── Function ────────────────────────────────────────────────────────────

/// Why a function exists only at compile time. Each arm is a distinct fact that
/// lowering knows for a distinct reason; they share only the consequence that the
/// function is never emitted into the binary.
pub const ComptimeRole = enum {
    /// Not compiler-only: an ordinary function, emitted when runtime-reachable.
    none,
    /// A wrapper lowering synthesized for a `#run`, a `::` initializer, or an
    /// `#insert` — evaluated by the comptime VM, never called at runtime.
    run_wrapper,
    /// A `-> Type` constructor, evaluated at lowering time to mint a type. Types
    /// are erased after lowering, so it has nothing to return at runtime.
    type_builder,
    /// A registered build / post-link callback: it has an sx body the VM runs
    /// after linking, but the binary it produces never calls it.
    build_callback,
};

pub const Function = struct {
    name: StringId,
    params: []const Param,
    ret: TypeId,
    blocks: std.ArrayList(Block),
    is_extern: bool = false,
    /// WHY this function is compiler-only, when it is. Three unrelated facts used
    /// to share one `is_comptime` bool, which is why `runComptimeSideEffects` had
    /// to string-match on a `__run` name prefix: the flag could not tell a `#run`
    /// wrapper from a type builder.
    ///
    /// Every role means "never present in the shipped binary" — that shared
    /// consequence is `isComptimeOnly()`, and it is the only thing the emit gates
    /// should ask. Anything that needs to know WHICH kind asks the role.
    comptime_role: ComptimeRole = .none,
    linkage: Linkage = .internal,
    call_conv: CallingConvention = .default,
    source_file: ?[]const u8 = null,
    /// Variadic tail at the IR signature level. Only `extern` decls reach
    /// IR with this set — sx-side `..T` params are slice-packed before
    /// lowering, so anything that survives is the C calling convention's
    /// `...`. emit_llvm passes `is_var_arg=1` to `LLVMFunctionType`; call
    /// sites apply the standard default argument promotions (i8/i16/bool →
    /// i32, f32 → f64) to extras past the fixed param count.
    is_variadic: bool = false,
    /// True if `params[0]` is the synthetic `__sx_ctx: *Context`
    /// parameter that every default-conv sx function receives. Callers
    /// read this flag to decide whether to prepend their current
    /// `__sx_ctx` value to the args of a call. Extern decls and
    /// `abi(.c)` functions have it false.
    has_implicit_ctx: bool = false,

    /// True for a declaration whose body is the `intrinsic` keyword — its
    /// implementation lives in the compiler (see `ir/intrinsics.zig`).
    ///
    /// An intrinsic has NO symbol of any kind: `size_of` folds to a constant,
    /// the atomics lower to ops, the evaluate-mode ones are serviced by the VM.
    /// So the backend must not emit a declaration for one — a `declare i32
    /// @intern(ptr)` is dead weight in every module that transitively sees the
    /// declaring file, which for std/core.sx means all of them.
    is_intrinsic: bool = false,


    /// For a body-local `#run` wrapper (`L :: #run f()` → an `is_comptime`
    /// `__ct_N` function): the user-facing const NAME the `#run` initializes, so
    /// a comptime-init failure can report `comptime init of 'L' failed` (issue
    /// 0182) rather than the internal `__ct_N` wrapper name. Null when the `#run`
    /// is not bound to a named const (a bare inline `#run`).
    comptime_display_name: ?StringId = null,

    /// True for an `abi(.naked)` function — no calling-convention
    /// prologue/epilogue/frame, no implicit `__sx_ctx`. Its body is a single
    /// inline-asm block that reads args from ABI registers and emits its own
    /// `ret` (the context-switch primitive; design §4.6). emit_llvm lowers this
    /// via LLVM's `naked` function attribute and generates no frame setup. A
    /// `.c` epilogue would restore SP from the wrong stack across a context
    /// switch (SP-in ≠ SP-out by design), which is why `.naked` is distinct
    /// from `.c`.
    is_naked: bool = false,

    /// `#get` property accessor (ast.FnDecl.is_get). Registered as an ordinary
    /// method, but ALSO reachable via no-paren field syntax (`obj.name`) when no
    /// real field matches — field-access lowering/inference calls it with the
    /// receiver as `self`.
    is_get: bool = false,

    /// `#set` property accessor (ast.FnDecl.is_set). The write counterpart of
    /// `is_get`: `obj.name = rhs` dispatches to it as `obj.name(rhs)` when no
    /// real field matches.
    is_set: bool = false,

    pub const Param = struct {
        name: StringId,
        ty: TypeId,
    };

    pub const Linkage = enum {
        internal,
        external,
        private,
    };

    pub const CallingConvention = types.TypeInfo.CallConv;


    /// True when the function exists only at compile time, whatever the reason.
    /// The emit gates want exactly this — never the specific role.
    pub fn isComptimeOnly(self: *const Function) bool {
        return self.comptime_role != .none;
    }
    pub fn init(name: StringId, params: []const Param, ret: TypeId) Function {
        return .{
            .name = name,
            .params = params,
            .ret = ret,
            .blocks = std.ArrayList(Block).empty,
        };
    }

    pub fn deinit(self: *Function, alloc: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            block.deinit(alloc);
        }
        self.blocks.deinit(alloc);
    }
};

// ── Global ──────────────────────────────────────────────────────────────

pub const Global = struct {
    name: StringId,
    ty: TypeId,
    init_val: ?ConstantValue = null,
    is_extern: bool = false,
    is_const: bool = false,
    /// Thread-local storage. `global_get` / `global_set` emit normal LLVM
    /// load/store instructions; LLVM handles the per-thread access through
    /// the `thread_local` attribute on the global.
    is_thread_local: bool = false,
    /// For comptime globals: the function to interpret to get the init value.
    comptime_func: ?FuncId = null,
};

// ── ConstantValue ───────────────────────────────────────────────────────

pub const ConstantValue = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: StringId,
    null_val,
    undef,
    zeroinit,
    aggregate: []const ConstantValue,
    /// Vtable constant: struct of function pointers, used for protocol vtable globals.
    vtable: []const FuncId,
    /// Function pointer leaf, for static initializers that include
    /// function addresses inside nested aggregates (e.g. the inline
    /// Allocator value `{ ctx, alloc_fn, dealloc_fn }` for the
    /// process-wide default Context).
    func_ref: FuncId,
    /// Relocatable address of another IR global (e.g. `p : *T = @g`).
    global_ref: GlobalId,
};
