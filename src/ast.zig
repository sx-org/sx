const std = @import("std");

pub const Span = struct {
    start: u32,
    end: u32,
};

/// Byte-start sentinel for a member name with no spelling in the source, such
/// as a union's anonymous `__anon_N` field.
pub const no_source_start: u32 = std.math.maxInt(u32);

/// File-local visibility. `.private` restricts the name to its declaring
/// SOURCE FILE: it stays fully usable throughout that file (forward
/// references included) but is never carried by flat imports, never
/// selectable through another module's namespace, and never mentionable as a
/// struct field from another file. Set on module-scope declaration nodes and
/// on `StructDecl.field_visibilities`; every other node stays `.public`.
pub const Visibility = enum { public, private };

pub const Node = struct {
    span: Span,
    data: Data,
    source_file: ?[]const u8 = null,
    /// Declaration visibility (`private NAME :: …`). Defaults to `.public`;
    /// only the parser's module-scope declaration paths ever set `.private`.
    visibility: Visibility = .public,

    pub const Data = union(enum) {
        root: Root,
        fn_decl: FnDecl,
        block: Block,
        int_literal: IntLiteral,
        float_literal: FloatLiteral,
        bool_literal: BoolLiteral,
        string_literal: StringLiteral,
        char_literal: CharLiteral,
        identifier: Identifier,
        enum_literal: EnumLiteral,
        binary_op: BinaryOp,
        chained_comparison: ChainedComparison,
        unary_op: UnaryOp,
        call: Call,
        field_access: FieldAccess,
        if_expr: IfExpr,
        match_expr: MatchExpr,
        match_arm: MatchArm,
        const_decl: ConstDecl,
        var_decl: VarDecl,
        assignment: Assignment,
        multi_assign: MultiAssign,
        destructure_decl: DestructureDecl,
        enum_decl: EnumDecl,
        struct_decl: StructDecl,
        struct_literal: StructLiteral,
        union_decl: UnionDecl,
        error_set_decl: ErrorSetDecl,
        lambda: Lambda,
        type_expr: TypeExpr,
        param: Param,
        defer_stmt: DeferStmt,
        push_stmt: PushStmt,
        comptime_expr: ComptimeExpr,
        error_directive: ErrorDirective,
        insert_expr: InsertExpr,
        return_stmt: ReturnStmt,
        import_decl: ImportDecl,
        namespace_decl: NamespaceDecl,
        array_type_expr: ArrayTypeExpr,
        slice_type_expr: SliceTypeExpr,
        array_literal: ArrayLiteral,
        parameterized_type_expr: ParameterizedTypeExpr,
        index_expr: IndexExpr,
        slice_expr: SliceExpr,
        pointer_type_expr: PointerTypeExpr,
        many_pointer_type_expr: ManyPointerTypeExpr,
        optional_type_expr: OptionalTypeExpr,
        error_type_expr: ErrorTypeExpr,
        raise_stmt: RaiseStmt,
        try_expr: TryExpr,
        catch_expr: CatchExpr,
        onfail_stmt: OnFailStmt,
        /// `@caller` — a marker legal only inside a parameter's default
        /// expression, where it resolves to the CALL site's `@SourceSite`. The
        /// node's `span`/`source_file` carry that site (rewritten during default
        /// expansion). No payload.
        caller_site: void,
        pack_index_type_expr: PackIndexTypeExpr,
        comptime_pack_ref: ComptimePackRef,
        force_unwrap: ForceUnwrap,
        null_coalesce: NullCoalesce,
        deref_expr: DerefExpr,
        postfix_cast: PostfixCast,
        null_literal: void,
        while_expr: WhileExpr,
        for_expr: ForExpr,
        spread_expr: SpreadExpr,
        named_arg: NamedArg,
        trailing_block: TrailingBlock,
        juxtaposition: Juxtaposition,
        break_expr: void,
        continue_expr: void,
        undef_literal: void,
        inferred_type: void,
        intrinsic_expr: void,
        library_decl: LibraryDecl,
        framework_decl: FrameworkDecl,
        function_type_expr: FunctionTypeExpr,
        closure_type_expr: ClosureTypeExpr,
        tuple_type_expr: TupleTypeExpr,
        return_type_expr: ReturnTypeExpr,
        tuple_literal: TupleLiteral,
        ufcs_alias: UfcsAlias,
        c_import_decl: CImportDecl,
        protocol_decl: ProtocolDecl,
        open_set_decl: OpenSetDecl,
        impl_block: ImplBlock,
        ffi_intrinsic_call: FfiIntrinsicCall,
        runtime_class_decl: RuntimeClassDecl,
        jni_env_block: JniEnvBlock,
        asm_expr: AsmExpr,
        asm_global: AsmGlobal,
        context_extend_decl: ContextExtendDecl,

        pub fn declName(self: Data) ?[]const u8 {
            return switch (self) {
                .fn_decl => |d| d.name,
                .const_decl => |d| d.name,
                .var_decl => |d| d.name,
                .enum_decl => |d| d.name,
                .struct_decl => |d| d.name,
                .union_decl => |d| d.name,
                .error_set_decl => |d| d.name,
                .namespace_decl => |d| d.name,
                .ufcs_alias => |d| d.name,
                .c_import_decl => |d| d.name,
                .protocol_decl => |d| d.name,
                .open_set_decl => |d| d.name,
                .runtime_class_decl => |d| d.name,
                else => null,
            };
        }
    };
};

pub const Root = struct {
    decls: []const *Node,
};

/// ABI / calling-convention annotation written as the postfix `abi(.x)` form on a
/// function declaration or function-type literal.
/// - `.default` — no annotation: the ordinary sx-internal convention (implicit
///   context, sx ABI). There is no surface spelling for `.default`; it is the
///   value when `abi(...)` is absent.
/// - `.c` — C ABI / cdecl, no implicit context.
/// - `.zig` — welded to the real internal Zig type/fn: layout follows the bound
///   Zig type, functions dispatch over the comptime host-call bridge. The
///   `compiler` library binds via `abi(.zig)`.
/// - `.compiler` — a COMPILER-DOMAIN function: it runs in the comptime evaluator
///   (VM / interp), NEVER in the shipped binary, so the backend does not lower it.
///   Covers the compiler-API surface (`intern`/`find_type`/`build_options`/… —
///   bodiless decls whose Zig/VM handler is the impl) AND user compiler-domain
///   functions like post-link callbacks (bodied, but emit-skipped). The ABI alone
///   marks it — there is no `extern <lib>` and no fake `@library "compiler"`.
/// - `.naked` — a naked function (inline asm body), no calling-convention
///   prologue/epilogue. The body is responsible for its own `ret`; args arrive
///   in ABI registers (no frame, no implicit `__sx_ctx`).
pub const ABI = enum { default, c, naked };

/// Linkage modifier written in the postfix slot before `abi(...)`:
/// `name :: (sig) -> Ret [extern | export] [abi(.x)] [lib] [;|{…}];`
/// `extern` = import (external linkage, no sx ctx — `extern`'s role);
/// `export` = define + expose (body + external linkage + no ctx).
/// Variants carry a trailing `_` to dodge the Zig keywords. `.none` = no linkage
/// modifier (the ordinary sx-internal decl).
pub const ExternExportModifier = enum { none, extern_, export_ };

pub const FnDecl = struct {
    name: []const u8,
    params: []const Param,
    return_type: ?*Node,
    body: *Node,
    type_params: []const StructTypeParam = &.{},
    is_arrow: bool = false,
    /// ABI / calling-convention annotation (`abi(.c)` / `abi(.zig)` / `abi(.naked)`)
    /// in the postfix slot after `extern`/`export`. `.default` = unannotated.
    /// `.zig` marks a function bound to the comptime `compiler` library — its
    /// signature is welded to the real internal Zig fn and it dispatches over the
    /// host-call bridge at comptime.
    abi: ABI = .default,
    /// Postfix linkage modifier (`extern`/`export`) written before the `abi(...)`
    /// slot. `.none` for an ordinary sx-internal function.
    extern_export: ExternExportModifier = .none,
    /// Optional library reference + symbol-name override for an `extern`/`export`
    /// function. Both optional: `extern` alone resolves the sx name against the
    /// default-linked libs; `extern LIB` names the source library;
    /// `extern "csym"` renames the symbol.
    extern_lib: ?[]const u8 = null,
    extern_name: ?[]const u8 = null,
    /// Span of the function's name token, for the reserved-type-name decl
    /// diagnostic. Synthesized decls (e.g. `@import c` extern
    /// functions, lowering-time objc/protocol method synthesis) leave it zero.
    name_span: Span = .{ .start = 0, .end = 0 },
    /// True when the function NAME was written as a backtick raw identifier
    /// (`` `i32 :: … ``) or synthesized by a `@import c` extern decl. A raw
    /// name is exempt from the reserved-type-name binding check.
    /// Every PARSER fn_decl is built through `parseFnDecl`, whose `name_is_raw`
    /// is a REQUIRED parameter, so a parser site cannot drop it; the default
    /// here serves only post-check synthesized decls (which are never raw).
    is_raw: bool = false,
    /// `name :: ufcs (params) { body }` — the fn opted into dot-call
    /// dispatch (`recv.name(args)`). Dot-calls on free functions are
    /// OPT-IN: only `is_ufcs` fns and `ufcs` aliases dispatch; a plain
    /// fn is callable only by direct call.
    is_ufcs: bool = false,
    /// `name :: (self: *T) -> R @get => expr;` — a no-paren property accessor.
    /// Invoked via field syntax (`obj.name`) when no real field matches, rather
    /// than as a `obj.name()` call. Takes only the `self` receiver.
    is_get: bool = false,
    /// `name :: (self: *T, value: V) @set { ... }` — the WRITE counterpart of a
    /// `@get` accessor. `obj.name = rhs` dispatches to it as `obj.name(rhs)` when
    /// no real field matches. Takes the `self` receiver plus exactly one value
    /// parameter and returns void.
    is_set: bool = false,
    /// The parameter list ends in a bare `..` — a C-variadic tail, which binds
    /// no name and no type and is therefore a signature flag rather than a
    /// `Param`. Legal only on an effective-C signature: a definition carrying
    /// `abi(.c)` or `export`, or an `extern` declaration. `params` holds only
    /// the fixed parameters, so the fixed count is `params.len`.
    is_c_variadic: bool = false,
};

/// True when `fd` declares an EFFECTIVE-C SIGNATURE: a definition carrying
/// `abi(.c)` or `export`, or an `extern` declaration. Each emits the C shape
/// with no implicit sx context, so the C-only signature spellings — the bare
/// `..` tail and the by-value `@VaList` parameter — belong exactly here.
pub fn isEffectiveCSignature(fd: *const FnDecl) bool {
    return fd.abi == .c or fd.extern_export != .none;
}

/// The number of fixed parameters a signature declares — the argument index at
/// which its variadic tail begins. The two tail forms hold their tail
/// differently: a bare `..` binds no `Param`, while `..name: []U` keeps its
/// final one. The count may be zero, so no caller has a last fixed parameter to
/// anchor on.
pub fn fixedParamCount(params: []const Param) usize {
    if (params.len > 0 and params[params.len - 1].is_variadic) return params.len - 1;
    return params.len;
}

pub const Param = struct {
    name: []const u8,
    name_span: Span,
    type_expr: *Node,
    is_variadic: bool = false,
    is_comptime: bool = false,
    /// Heterogeneous protocol-constrained variadic pack: `..xs: Protocol`
    /// (no `[]`, no `$`). The annotation is a bare protocol the trailing args
    /// each conform to with their own type-arg — distinct from a slice variadic
    /// (`..xs: []T`, `is_pack == false`) and from the comptime type-pack
    /// (`..$xs`, `is_comptime == true`). Always implies `is_variadic`.
    is_pack: bool = false,
    /// Optional default value expression. When the caller omits this
    /// parameter, lowering substitutes this expression in its place.
    default_expr: ?*Node = null,
    /// True when the param name was written as a backtick raw identifier
    /// (`` `i32 ``) or synthesized by a `@import c` extern decl. A raw name is
    /// exempt from the reserved-type-name binding check.
    is_raw: bool = false,
};

pub const Block = struct {
    stmts: []const *Node,
    /// True when the block's last statement is an EXPRESSION statement, so the
    /// block has a value to hand to whatever position demands one. A
    /// non-expression last statement (a declaration, an empty block) leaves it
    /// false. The statement's terminator is not part of this: `;` separates
    /// statements and never discards a value.
    produces_value: bool = false,
};

pub const IntLiteral = struct {
    value: i64,
};

pub const FloatLiteral = struct {
    value: f64,
};

pub const BoolLiteral = struct {
    value: bool,
};

pub const StringLiteral = struct {
    raw: []const u8,
    is_raw: bool = false,
};

/// A `'...'` char literal. `value` is the decoded code point (fits in i64;
/// max Unicode scalar is 0x10FFFF). `raw` is the inner source body (between
/// the quotes) kept for faithful IR/source printing — mirrors `StringLiteral`.
/// Types/lowers identically to `int_literal` (default i64, coerces to any
/// int/float in context); the only behavioral difference is printing.
pub const CharLiteral = struct {
    value: i64,
    raw: []const u8,
};

/// Inline assembly expression: `asm volatile? { "tmpl", <operands…>,
/// clobbers(.…) }` (design §II.3). A flat `operands` list in source
/// order — that order keys the `%N`/`%[name]` indices and the LLVM constraint
/// string. The result type is derived in Sema from the `out_value` operands
/// (0→void, 1→T, N→tuple).
pub const AsmExpr = struct {
    /// Template: a string-literal / `@string` heredoc node (a comptime string).
    template: *Node,
    is_volatile: bool = false,
    /// Declaration order preserved (= `%N` indexing).
    operands: []const AsmOperand,
    /// Dot-names from `clobbers(.…)`: e.g. "rcx", "cc", "memory".
    clobbers: []const []const u8,
};

pub const AsmOperand = struct {
    /// Optional `[name]`; null when not written. The *effective* name (for
    /// `%[name]` and the result tuple field) is computed in Sema: explicit
    /// `[name]`, else auto-derived from a `{reg}` pin in `constraint` (design
    /// §II.5 naming rule).
    name: ?[]const u8 = null,
    /// Verbatim constraint, e.g. "={rax}", "=r", "+r", "{rdi}", "r".
    constraint: []const u8,
    role: Role,
    /// `out_value` → a Type node; `input` → an expression node. (`out_place`
    /// payload is a write-through place expr.)
    payload: *Node,

    pub const Role = enum {
        out_value, // `-> Type`     value output; N of these → a tuple result
        out_place, // `-> @place`   write-through to storage
        input, // `= expr`
    };
};

/// Top-level (module-scope) global assembly: `asm { "tmpl", };` (design
/// §II.2 Deviation 6). Template only — no operands, no `volatile`, no
/// `clobbers`, no `%` substitution. Lowers to `LLVMAppendModuleInlineAsm`;
/// multiple blocks concatenate in source order. Symbols it defines are reached
/// with a lib-less `extern` declaration.
pub const AsmGlobal = struct {
    template: *Node, // string-literal / `@string` heredoc node
};

pub const Identifier = struct {
    name: []const u8,
    /// True when written as a backtick raw identifier (`` `i32 ``). Carried so a
    /// destructure target (`` `i32, b := … ``) can be recognised as raw and
    /// exempted from the reserved-type-name binding check.
    is_raw: bool = false,
};

pub const EnumLiteral = struct {
    name: []const u8, // without the leading dot
};

pub const BinaryOp = struct {
    op: Op,
    lhs: *Node,
    rhs: *Node,

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        mod,
        eq,
        neq,
        lt,
        lte,
        gt,
        gte,
        and_op,
        or_op,
        bit_and,
        bit_or,
        bit_xor,
        shl,
        shr,
        in_op,
        /// `x is T` — classification. The RHS is parsed as a TYPE expression,
        /// never as a value, so it holds a type node (or a bare category word
        /// spelled as an identifier / `struct` / `enum` / `union`).
        is_op,
    };
};

pub const ChainedComparison = struct {
    operands: []const *Node,
    ops: []const BinaryOp.Op,
};

pub const UnaryOp = struct {
    op: Op,
    operand: *Node,

    pub const Op = enum {
        negate,
        not,
        bit_not,
        xx,
        address_of,
        pre_decrement,
    };
};

pub const Call = struct {
    callee: *Node,
    args: []const *Node,
};

/// `@ObjcCall(T, recv, "sel:", args...)`,
/// `@JniCall(T, env, target, "name", "(Sig)R", args...)`,
/// `@JniStaticCall(T, env, class, "name", "(Sig)R", args...)`.
/// The return type is the first argument. Codegen branches on `kind`.
pub const FfiIntrinsicKind = enum {
    objc_call,
    jni_call,
    jni_static_call,
};

pub const FfiIntrinsicCall = struct {
    kind: FfiIntrinsicKind,
    return_type: *Node,
    args: []const *Node,
};

pub const FieldAccess = struct {
    object: *Node,
    field: []const u8,
    is_optional: bool = false,
};

pub const IfExpr = struct {
    condition: *Node,
    then_branch: *Node,
    else_branch: ?*Node,
    is_inline: bool, // true for `if cond then a else b`
    is_comptime: bool = false, // true for `inline if` — compile-time branch elimination
    binding_name: ?[]const u8 = null, // for `if val := expr { ... }` optional binding
    binding_span: ?Span = null, // span of `binding_name` (set iff `binding_name` is)
    /// True when the optional binding was a backtick raw identifier
    /// (`` if `i32 := … ``) — exempt from the reserved-type-name check.
    binding_is_raw: bool = false,
};

pub const MatchExpr = struct {
    subject: *Node,
    arms: []const MatchArm,
    is_comptime: bool = false,
};

pub const MatchArm = struct {
    pattern: ?*Node, // null = else (default) arm
    body: *Node,
    is_break: bool,
    capture: ?[]const u8 = null, // payload binding name: case .variant: |name| { ... }
    capture_span: ?Span = null, // span of `capture` (set iff `capture` is)
    /// True when the capture was a backtick raw identifier
    /// (`` case .v: |`i32| ``) — exempt from the reserved-type-name check.
    capture_is_raw: bool = false,
};

pub const ConstDecl = struct {
    name: []const u8,
    type_annotation: ?*Node,
    value: *Node,
    /// Span of the constant's name token, for the reserved-type-name decl
    /// diagnostic. NO default: every construction site must set
    /// it explicitly, so a struct-body const can't silently fall back to a
    /// 1:1 caret (the finding-1 bug).
    name_span: Span,
    /// True when the constant NAME was written as a backtick raw identifier
    /// (`` `i32 :: … ``). NO default: required at every site so the reserved-
    /// name exemption can't be dropped — mirrors `checkBindingName`'s required
    /// `is_raw` argument so the parser and the check can't desync.
    is_raw: bool,
};

pub const VarDecl = struct {
    name: []const u8,
    name_span: Span,
    type_annotation: ?*Node,
    value: ?*Node,
    /// `extern`-global form `g : T extern [LIB] ["csym"];` — a reference to a
    /// global defined elsewhere (external linkage, resolved at link time).
    /// `extern_lib` is the optional source-library reference and `extern_name`
    /// the optional symbol-name override.
    is_extern: bool = false,
    extern_lib: ?[]const u8 = null,
    extern_name: ?[]const u8 = null,
    /// True when the binding name was written as a backtick raw identifier
    /// (`` `i32 := … ``). A raw name is exempt from the reserved-type-name
    /// binding check.
    is_raw: bool = false,
};

pub const Assignment = struct {
    target: *Node,
    op: Op,
    value: *Node,

    pub const Op = enum {
        assign,
        add_assign,
        sub_assign,
        mul_assign,
        div_assign,
        mod_assign,
        and_assign,
        or_assign,
        xor_assign,
        shl_assign,
        shr_assign,
    };
};

pub const MultiAssign = struct {
    targets: []const *Node,
    values: []const *Node,
};

pub const DestructureDecl = struct {
    names: []const []const u8,
    name_spans: []const Span, // one per entry in `names`, same order
    /// One per entry in `names`, same order: true when that target was a
    /// backtick raw identifier (`` `i32, b := … ``) — exempt from the
    /// reserved-type-name binding check.
    name_is_raw: []const bool,
    value: *Node,
};

pub const EnumDecl = struct {
    name: []const u8,
    variant_names: []const []const u8,
    /// Byte start of each variant name's spelling, one per entry in
    /// `variant_names`, same order; `no_source_start` when synthesized.
    variant_name_starts: []const u32,
    variant_types: []const ?*Node = &.{}, // null entries = no payload; empty = payload-less enum
    is_flags: bool = false,
    variant_values: []const ?*Node = &.{}, // explicit value per variant (null = auto), empty = all auto
    backing_type: ?*Node = null, // optional backing type: enum u8 { ... }
    /// True when the declared NAME was a backtick raw identifier
    /// (`` `i32 :: enum { … } ``) — exempt from the reserved-type-name decl
    /// check. A bare reserved-name decl still errors.
    is_raw: bool = false,
};

pub const UnionDecl = struct {
    name: []const u8,
    field_names: []const []const u8,
    /// Byte start of each field name's spelling, one per entry in
    /// `field_names`, same order; `no_source_start` when synthesized.
    field_name_starts: []const u32,
    field_types: []const *Node,
    /// True when the declared NAME was a backtick raw identifier — exempt from
    /// the reserved-type-name decl check.
    is_raw: bool = false,
};

/// `Foo :: error { A; B: i32 }` — a named error set, written with the enum
/// member grammar. A member's identity is the pair `(set, tag)`.
pub const ErrorSetDecl = struct {
    name: []const u8,
    tag_names: []const []const u8,
    /// Byte start of each tag name's spelling, one per entry in `tag_names`,
    /// same order; `no_source_start` when synthesized.
    tag_name_starts: []const u32,
    /// Payload type per tag, one per entry in `tag_names`; null = void member.
    /// Empty when no member carries a payload.
    tag_types: []const ?*Node = &.{},
    /// True when the declared NAME was a backtick raw identifier — exempt from
    /// the reserved-type-name decl check.
    is_raw: bool = false,
};

pub const StructTypeParam = struct {
    name: []const u8, // e.g. "N" or "T" (without $)
    constraint: *Node, // type_expr: "u32" for value param, "Type" for type param
    /// Generic bounds — see `TypeExpr.protocol_constraints`.
    protocol_constraints: []const *Node = &.{},
    /// `..$Ts: []Type` — a pack type-param binding the remaining type args as a
    /// sequence (must be last). Field types reference it via `(..$Ts)` etc.
    is_variadic: bool = false,
};

pub const UsingEntry = struct {
    insert_index: u32, // position in field_names where used fields are spliced
    type_name: []const u8, // struct type to inline
};

pub const StructDecl = struct {
    name: []const u8,
    field_names: []const []const u8,
    /// Byte start of each field name's spelling, one per entry in
    /// `field_names`, same order; `no_source_start` when synthesized. A `_`
    /// field keeps its `_` token's start under its `_N` stored name.
    field_name_starts: []const u32,
    field_types: []const *Node, // type_expr nodes
    field_defaults: []const ?*Node, // default value per field, null if none
    field_visibilities: []const Visibility = &.{},
    type_params: []const StructTypeParam = &.{},
    using_entries: []const UsingEntry = &.{},
    methods: []const *Node = &.{}, // fn_decl nodes for struct methods
    constants: []const *Node = &.{}, // const_decl nodes for struct-level constants
    /// ABI / layout annotation (`struct abi(.zig) extern <lib> { … }`). `.default`
    /// for an ordinary struct. `.zig` marks a layout-welded binding to the named
    /// `compiler` library's real Zig type — its field offsets are taken from the
    /// bound Zig type (`@offsetOf`) and asserted equal at compiler-build time.
    /// Consumed by the binding registry and the layout engine.
    abi: ABI = .default,
    /// The bound library handle for an `abi(.zig) extern <lib>` welded struct
    /// (e.g. `compiler`); null for an ordinary struct.
    extern_lib: ?[]const u8 = null,
    /// True when the declared NAME was a backtick raw identifier
    /// (`` `i32 :: struct { … } ``) — exempt from the reserved-type-name decl
    /// check. A bare reserved-name decl still errors.
    is_raw: bool = false,
    /// The open set this declaration joins (`Button :: @OpenVariant(View) { … }`),
    /// as written — a PATH, so a member may name a set the module that owns it
    /// publishes (`@OpenVariant(compose.View)`). A variant IS an ordinary
    /// standalone struct — constructible, with its own layout — that additionally
    /// becomes a member of that set, so this is one more fact ABOUT a struct
    /// rather than a separate declaration form. Null for a plain `struct`.
    open_variant_of: ?[]const u8 = null,
    /// Span of the set name, for the diagnostics that must point at the binding.
    open_variant_span: ?Span = null,
};

/// `View :: @OpenSet(.{ max = 256, align = 8 }) { … }` — an inline tagged slot
/// whose members declare themselves (spec: Open Sets). Not a protocol kind: the
/// methods are a requirement on every member, and the options are the payload
/// ceiling the slot is laid out to.
pub const OpenSetDecl = struct {
    name: []const u8,
    /// The required methods, in declaration order. `Self` in a signature denotes
    /// the member type: each is monomorphized per member.
    methods: []const ProtocolMethodDecl,
    /// The options expression (`.{ max = …, align = … }`), resolved at
    /// registration. `max` is required; `align` defaults to 8.
    options: ?*Node = null,
    options_span: ?Span = null,
    is_raw: bool = false,
    source_file: ?[]const u8 = null,
};

pub const StructFieldInit = struct {
    name: ?[]const u8, // null for positional, non-null for named/shorthand
    value: *Node,
    /// True when the source wrote the bare-identifier SHORTHAND (`.{ x }`,
    /// parser-rewritten to `x = x`). The self-typing of an untyped `.{ }`
    /// needs the distinction: shorthand is NAMED by rule (field `x`), while
    /// a parenthesized `(x)` stays positional.
    was_shorthand: bool = false,
};

pub const StructLiteral = struct {
    struct_name: ?[]const u8, // null for anonymous `.{ ... }`
    type_expr: ?*Node = null, // for GenericType(args){ ... }
    field_inits: []const StructFieldInit,
    /// Optional self-trailing block `T{…}.{…}`, binding a pointer to the value
    /// under `init_block_self` — the `|s|` header's name, or `self`.
    init_block: ?*Node = null,
    init_block_self: ?[]const u8 = null,
};

/// One field of a closure literal's `_{ … }` env: the name the body reads and
/// the expression it holds, evaluated where the literal is written.
pub const EnvField = struct {
    name: []const u8,
    value: *Node,
};

pub const Lambda = struct {
    params: []const Param,
    return_type: ?*Node,
    body: *Node,
    type_params: []const StructTypeParam = &.{},
    /// The `_{ … }` env written between the parameter list and the return type.
    env: []const EnvField = &.{},
    /// True when the source wrote `_{`, including the empty `_{ }` — which is
    /// a written env with no fields, not an absent one.
    has_env: bool = false,
};

pub const TypeExpr = struct {
    name: []const u8,
    is_generic: bool = false,
    /// Generic bounds after the binder: `$T/Eq/Hashable`, `$I/@Init($V/P)`.
    /// Each is one bound expression — a `type_expr` holding a bare protocol
    /// head, or a `parameterized_type_expr` holding a head plus its type
    /// arguments. The head may be an `@` name; type arguments are ordinary
    /// type expressions and may introduce their own binders.
    protocol_constraints: []const *Node = &.{},
    /// True when written as a backtick raw identifier in type position
    /// (`` `i32 ``). Such a reference is the LITERAL name `i32` used as a type —
    /// resolution skips the builtin/reserved classifier and looks up a
    /// `` `i32 ``-declared type (struct/enum/union/alias), else "unknown
    /// type". A bare `i32` keeps `is_raw = false` and is the int type.
    is_raw: bool = false,
};

/// `$<pack_name>[<index>]` in type position. Resolves to the i-th
/// element type of the active pack binding — used in trampoline bodies,
/// generic conversions, struct fields parameterised over the pack.
pub const PackIndexTypeExpr = struct {
    pack_name: []const u8,
    index: u32,
};

/// `$<pack_name>` (no indexing) in expression position. Evaluates
/// to a comptime `[]Type` slice — the WHOLE pack as data. Lets builder
/// fns walk the pack types and emit per-position code, as a generic
/// `Into(Block)` trampoline body does.
pub const ComptimePackRef = struct {
    pack_name: []const u8,
};

pub const DeferStmt = struct {
    expr: *Node,
};

// ── Error handling (ERR stream) ──────────────────────────────────────────

/// `raise EXPR;` — terminates control flow like `return`, populating the
/// error channel. `tag` is a tag-typed expression: `error.X` (a field
/// access on the `error` keyword) or a tag-bound variable (`raise e`).
pub const RaiseStmt = struct {
    tag: *Node,
};

/// `try X` — a failable attempt. Unary prefix, binds tighter than any
/// binary operator. Sema rejects a non-failable operand.
pub const TryExpr = struct {
    operand: *Node,
};

/// `X catch [|e|] BODY` — inline failure handler (postfix). The binding is
/// optional. Body is a block or a bare expression.
pub const CatchExpr = struct {
    operand: *Node,
    binding: ?[]const u8 = null,
    binding_span: ?Span = null, // span of `binding` (set iff `binding` is)
    /// True when the binding was a backtick raw identifier
    /// (`` x catch |`i32| { … } ``) — exempt from the reserved-type-name check.
    binding_is_raw: bool = false,
    body: *Node,
};

/// `onfail [|e|] BODY` — cleanup run on error-exit of the enclosing block.
/// The binding is optional. Body is a block (`onfail [|e|] { ... }`) or
/// a bare expression (`onfail EXPR;`).
pub const OnFailStmt = struct {
    binding: ?[]const u8 = null,
    binding_span: ?Span = null, // span of `binding` (set iff `binding` is)
    /// True when the binding was a backtick raw identifier
    /// (`` onfail |`i32| { … } ``) — exempt from the reserved-type-name check.
    binding_is_raw: bool = false,
    body: *Node,
};

pub const PushStmt = struct {
    context_expr: *Node,
    body: *Node,
};

pub const ComptimeExpr = struct {
    expr: *Node,
};

/// `@error("message")` — a compile-time diagnostic. When it survives the
/// comptime-conditional flatten pass into live decls (e.g. the taken arm of an
/// `inline match OS { ... }` is an unsupported-target `else`), the flatten pass
/// emits `message` as an error and drops the node. In a non-taken arm it is
/// pruned before it can fire.
pub const ErrorDirective = struct {
    message: []const u8,
};

/// `@context_extend name: Type = default;` — a top-level directive declaring a
/// field the program's assembled Context carries (design/context-extension.md).
/// It declares no module-scope name (`declName` is null): the field lives in the
/// program-global Context namespace, collected across all modules.
pub const ContextExtendDecl = struct {
    name: []const u8,
    /// Span of the field-name token (collision / missing-default diagnostics
    /// anchor here).
    name_span: Span,
    type_expr: *Node,
    /// null = the `= default` clause is absent. The parser accepts it so the
    /// collection pass can reject it with the tailored wording (defaults are
    /// mandatory and comptime-evaluable) instead of a bare parse error.
    default_expr: ?*Node,
};

pub const InsertExpr = struct {
    expr: *Node,
};

pub const ReturnStmt = struct {
    value: ?*Node,
};

pub const ImportDecl = struct {
    path: []const u8,
    name: ?[]const u8,
    /// True when the namespace NAME was a backtick raw identifier
    /// (`` `i32 :: @import "…" ``) — exempt from the reserved-type-name decl
    /// check. A flat `@import` (name == null) binds nothing.
    is_raw: bool = false,
};

pub const ArrayTypeExpr = struct {
    length: *Node, // int_literal for the size
    element_type: *Node, // type_expr for the element type
};

pub const SliceTypeExpr = struct {
    element_type: *Node, // type_expr for the element type
};

pub const ArrayLiteral = struct {
    elements: []const *Node,
    type_expr: ?*Node = null,
};

pub const ParameterizedTypeExpr = struct {
    name: []const u8, // e.g. "@Vector", or later generic struct names
    args: []const *Node, // e.g. [int_literal(3), type_expr("f32")]
    /// True when the base name was a backtick raw identifier in type position
    /// (`` `i32(i64) ``). Such a reference is the LITERAL name `i32` used as a
    /// parameterized type — resolution skips the builtin parameterized
    /// classifier (e.g. the `@Vector` intrinsic) and instantiates a
    /// `` `i32 ``-declared generic template.
    is_raw: bool = false,
};

pub const IndexExpr = struct {
    object: *Node,
    index: *Node,
};

pub const SliceExpr = struct {
    object: *Node,
    start: ?*Node = null, // null = 0
    end: ?*Node = null, // null = len
    /// `<..` family — slice begins one past `start`.
    start_exclusive: bool = false,
    /// `..=` family — slice includes `end`.
    end_inclusive: bool = false,
};

pub const PointerTypeExpr = struct {
    pointee_type: *Node,
};

pub const ManyPointerTypeExpr = struct {
    element_type: *Node,
};

pub const OptionalTypeExpr = struct {
    inner_type: *Node,
};

/// The error channel of a multi-return result list. Appears only as the
/// trailing result element; the parser enforces the position and sema
/// restricts it to return positions.
pub const ErrorTypeExpr = struct {
    /// The set references `!` takes, as written: empty = the inferred channel
    /// (bare `!`); one entry = a named set or qualified member (`!IoErr.Failed`);
    /// more = a parenthesized composition (`!(A | B)`).
    operands: []const []const u8 = &.{},

    /// The single set the channel names; null when it is inferred or composed.
    pub fn namedSet(self: ErrorTypeExpr) ?[]const u8 {
        return if (self.operands.len == 1) self.operands[0] else null;
    }
};

pub const ForceUnwrap = struct {
    operand: *Node,
};

pub const NullCoalesce = struct {
    lhs: *Node,
    rhs: *Node,
};

pub const DerefExpr = struct {
    operand: *Node,
};

/// Postfix cast `expr.(T)`. Statically-typed
/// receivers convert via the explicit-target `xx` engine; type-erased
/// receivers (`any` / protocol values) are checked assertions. The
/// optional-chained form `expr?.(T)` maps over the optional receiver:
/// chain-null propagates as null and the cast/assertion applies to the
/// payload, yielding `?T`.
pub const PostfixCast = struct {
    operand: *Node,
    type_expr: *Node,
    is_optional_chain: bool = false,
    // `expr.(T, alloc)` — the allocator an `Into` conversion funds from
    // (lvalue-only; an interface target refuses it, both at lowering).
    alloc_arg: ?*Node = null,
};

pub const WhileExpr = struct {
    condition: *Node,
    body: *Node,
    binding_name: ?[]const u8 = null, // for `while val := expr { ... }` optional binding
    binding_span: ?Span = null, // span of `binding_name` (set iff `binding_name` is)
    /// True when the optional binding was a backtick raw identifier
    /// (`` while `i32 := … ``) — exempt from the reserved-type-name check.
    binding_is_raw: bool = false,
};

/// One position of a (possibly multi-iterable) `for` header.
pub const ForIterable = struct {
    /// Collection expression, or the range START for the range forms.
    expr: *Node,
    /// Range end. Null for a plain collection AND for the open-ended range
    /// `a..` (distinguished by `is_range`).
    range_end: ?*Node = null,
    /// True for any range form. Each side of `..` takes an optional bound
    /// marker — `=` inclusive, `<` exclusive — with defaults start-inclusive,
    /// end-exclusive: `a..b` ≡ `a=..<b`; `a<..<b` is 1-past-start to
    /// end-1; `a=..=b` includes both ends; `a..=b` keeps the short
    /// end-inclusive spelling.
    is_range: bool = false,
    /// `<..` family — start is exclusive (cursor begins at start+1).
    start_exclusive: bool = false,
    /// `..=` family — end is inclusive.
    end_inclusive: bool = false,
};

/// One capture of a `for` header: `x`, `*x`, `x: T`, `*x: T`.
pub const ForCapture = struct {
    name: []const u8,
    span: ?Span = null,
    /// True when the name was a backtick raw identifier (`` for `i32 in xs ``)
    /// — exempt from the reserved-type-name check.
    is_raw: bool = false,
    /// `*x` — bind a pointer into the collection (no per-element copy).
    by_ref: bool = false,
    /// `x: T` — the ELEMENT type, independent of `by_ref`: `*x: T` binds `*T`.
    type_annotation: ?*Node = null,
};

/// `for c1, c2, ... in it1, it2, ... { }` — parallel iteration. The FIRST
/// iterable's length drives the loop (first-iterable-wins); the others are
/// indexed along it, and a non-first range's end is not consulted. The
/// captures are positional: empty (no bindings) or one capture per
/// iterable. The body is a block or an `=> expr;` arrow body.
pub const ForExpr = struct {
    iterables: []ForIterable,
    captures: []ForCapture,
    body: *Node,
    /// `inline for` — comptime-unrolled (single bounded range, comptime bounds).
    is_inline: bool = false,
};

pub const SpreadExpr = struct {
    operand: *Node,
};

/// `name = value` in call-argument position (named argument, specs: Named
/// Arguments). Exists only inside `Call.args`; the mapping pass rewrites the
/// call to positional order before general lowering.
pub const NamedArg = struct {
    name: []const u8,
    value: *Node,
};

/// `f(args) { body }` trailing block (specs: Trailing Blocks). `lambda` is
/// the closure literal built from a juxtaposition's block. Exists
/// only as the LAST element of `Call.args`; the mapping pass binds it to the
/// callee's last declared parameter, which is where its checks live.
pub const TrailingBlock = struct {
    lambda: *Node,
    /// True when the source wrote `|…|` after `{`, including empty `| |`.
    has_header: bool = false,
};

/// `expr { … }` — two adjacent expressions. The same spelling carries the
/// named aggregate (`Label { text = "x" }`, `List(Move){}`) and the trailing
/// block (`vstack(12.0) { … }`), so types settle it: `settle` rewrites the
/// node into a `struct_literal` over `expr`, or into a call with `block`
/// appended as a `trailing_block` argument.
pub const Juxtaposition = struct {
    expr: *Node,
    /// The brace group, parsed as a statement list. An aggregate reading
    /// re-reads each statement as a field init.
    block: *Node,
    /// The block's `|params|` header, spelled as a closure literal's.
    params: []const Param = &.{},
    /// The header's `_{ … }` env, spelled as a closure literal's.
    env: []const EnvField = &.{},
    /// True when the source wrote `_{`, including the empty `_{ }`.
    has_env: bool = false,
    type_params: []const StructTypeParam = &.{},
    /// True when the source wrote `|…|` after `{`, including empty `| |`.
    has_header: bool = false,
    /// `expr { … }.{ |s| … }` — the self-trailing block and the name it binds
    /// the value's pointer to. Settling copies both onto the aggregate.
    init_block: ?*Node = null,
    init_block_self: ?[]const u8 = null,
};

pub const NamespaceDecl = struct {
    name: []const u8,
    decls: []const *Node,
    /// Decls AUTHORED in the namespaced module itself (its `own_decls`), a
    /// subset of `decls` (which also carries the module's transitive flat
    /// imports). Lowering registers these under their module-qualified name
    /// (`ns.fn`) so `pkg.fn(...)` resolves to a unique FuncId distinct from a
    /// same-named function in another module.
    own_decls: []const *Node = &.{},
    /// The resolved path of the module this alias targets — the importing file's
    /// own path for a `@import c` namespace (its members are synthesized there).
    /// Captured at import-resolution time (the `resolved_path` that is otherwise
    /// not retained on the node) so `buildImportFacts` can record the namespace
    /// edge without re-walking the import graph.
    target_module_path: []const u8,
    /// True when the namespace NAME was a backtick raw identifier — exempt
    /// from the reserved-type-name decl check.
    is_raw: bool = false,
};

pub const LibraryDecl = struct {
    lib_name: []const u8,
    name: []const u8, // sx-side constant name
    /// True when the constant NAME was a backtick raw identifier — exempt from
    /// the reserved-type-name decl check.
    is_raw: bool = false,
};

pub const FrameworkDecl = struct {
    name: []const u8, // framework name, e.g. "Foundation"
};

pub const FunctionTypeExpr = struct {
    param_types: []const *Node,
    param_names: ?[]const ?[]const u8 = null, // optional documentation names
    return_type: ?*Node, // null = void return
    abi: ABI = .default,
    /// The parameter list ends in a bare `..` — a C-variadic tail, which binds
    /// no name and no type and is therefore a signature flag rather than an
    /// entry of `param_types`. Legal only with `abi(.c)`, so the fixed count is
    /// `param_types.len` and may be zero.
    is_c_variadic: bool = false,
};

pub const ClosureTypeExpr = struct {
    param_types: []const *Node,
    param_names: ?[]const ?[]const u8 = null, // optional documentation names
    return_type: ?*Node, // null = void return
    /// Variadic heterogeneous type pack trailing the param list.
    /// `Closure(..$args) -> R` ⇒ pack_name = "args", param_types = [].
    /// `Closure(Prefix, ..$args)` ⇒ pack_name = "args", param_types = [Prefix].
    pack_name: ?[]const u8 = null,
    /// Projection on the pack: `Closure(..sources.T) -> R` ⇒ pack_name =
    /// "sources", pack_projection = "T". Null for a bare `..pack`.
    pack_projection: ?[]const u8 = null,
};

pub const TupleTypeExpr = struct {
    field_types: []const *Node,
    field_names: ?[]const []const u8, // null for positional
};

/// A bare-paren MULTI-RETURN signature `(A, B)` / `(x: A, y: B)` / `(A, B, !)`
/// (≥2 value slots, error always the LAST slot). A function with this return
/// returns MULTIPLE VALUES — interned as an anonymous structural struct, valid
/// ONLY as a function/closure return type (the general type resolver rejects
/// it anywhere else). The result is consumed by destructuring (`a, b := f()`)
/// or as a positional product (`s.0`). Same AST shape as a parenthesized
/// failable `(T, !)` list so the resolver can reuse the field-resolution path.
/// The single-value `(T, !)` (one value + error) is NOT this — it is a
/// dedicated failable kind.
pub const ReturnTypeExpr = struct {
    field_types: []const *Node,
    field_names: ?[]const []const u8, // null for positional
    /// Per-slot default value expressions (`(sum: i32 = 0, good: bool)`), 1:1
    /// with `field_types`; an entry is null when that slot has no default. null
    /// (the whole field) when NO slot has a default. A defaulted named slot is
    /// exempt from the must-set rule — the default seeds the slot local.
    field_defaults: ?[]const ?*Node = null,
};

pub const TupleLiteral = struct {
    elements: []const TupleElement,
    // Explicit type prefix on a product literal, when present. null for the
    // anonymous, contextually-typed form.
    type_expr: ?*Node = null,
};

pub const TupleElement = struct {
    name: ?[]const u8, // null for positional
    value: *Node,
};

pub const UfcsAlias = struct {
    name: []const u8,
    target: []const u8,
    /// True when the alias NAME was a backtick raw identifier — exempt from
    /// the reserved-type-name decl check.
    is_raw: bool = false,
};

pub const CImportDecl = struct {
    includes: []const []const u8,
    sources: []const []const u8,
    defines: []const []const u8,
    flags: []const []const u8,
    name: ?[]const u8 = null,
    bitcode_paths: []const []const u8 = &.{}, // populated during import resolution
    /// True when the namespace NAME was a backtick raw identifier — exempt
    /// from the reserved-type-name decl check.
    is_raw: bool = false,
};

pub const ProtocolMethodDecl = struct {
    name: []const u8,
    params: []const *Node, // type_expr nodes for parameter types (excluding implicit self)
    param_names: []const []const u8, // parameter names (excluding implicit self)
    param_name_spans: []const Span = &.{}, // one per `param_names` entry; empty for synthesized methods
    /// One per `param_names` entry: true when written as a backtick raw
    /// identifier — exempt from the reserved-type-name check.
    /// Empty for synthesized methods (treated as all-false).
    param_name_is_raw: []const bool = &.{},
    /// The stripped receiver's form: the declaration wrote `self: *Self` rather
    /// than `self: Self`.
    receiver_is_pointer: bool = true,
    return_type: ?*Node, // null = void return
    default_body: ?*Node, // null = required method, non-null = default implementation
};

/// Which head declared this contract: `constraint` names a bound and emits
/// nothing; `interface` mints an erased runtime value type.
pub const ProtocolKind = enum {
    constraint,
    erased,
};

pub const ProtocolDecl = struct {
    name: []const u8,
    methods: []const ProtocolMethodDecl,
    kind: ProtocolKind = .constraint,
    type_params: []const StructTypeParam = &.{}, // for `constraint(Target: Type) { ... }`
    /// True when the declared NAME was a backtick raw identifier — exempt from
    /// the reserved-type-name decl check.
    is_raw: bool = false,
    /// Defining module path (stamped by `resolveImports`), so a parameterized
    /// protocol instantiated cross-module resolves its method signature types in
    /// the module that declares it (— the protocol analog of
    /// `StructTemplate.source_file`). Null for a synthesized/sourceless decl.
    source_file: ?[]const u8 = null,
};

pub const RuntimeKind = enum {
    jni_class,
    jni_interface,
    objc_class,
    objc_protocol,
    swift_class,
    swift_struct,
    swift_protocol,
};

pub const RuntimeMethodDecl = struct {
    name: []const u8,
    params: []const *Node, // type_expr nodes — first is `*Self` for instance methods
    param_names: []const []const u8,
    param_name_spans: []const Span = &.{}, // one per `param_names` entry; empty for synthesized methods
    /// One per `param_names` entry: true when written as a backtick raw
    /// identifier — exempt from the reserved-type-name check.
    /// Empty for synthesized methods (treated as all-false).
    param_name_is_raw: []const bool = &.{},
    return_type: ?*Node, // null = void
    is_static: bool = false, // true for `static name :: ...`
    jni_descriptor_override: ?[]const u8 = null, // `@JniMethod("(Sig)Ret")` — JNI runtime only
    selector_override: ?[]const u8 = null, // `@ObjcMethod("explicit:string")` — Obj-C runtime only
    body: ?*Node = null, // sx-side implementation (defined-class only). null = `;`-terminated decl referencing inherited / external method.
};

pub const RuntimeFieldDecl = struct {
    name: []const u8,
    field_type: *Node, // type_expr node
    /// True iff the declaration carries a `@ObjcProperty[(...)]` directive
    /// For runtime classes, that means synthesize getter/setter
    /// dispatch through `objc_msgSend`; for sx-defined classes it adds
    /// runtime-introspectable property metadata + ARC-aware setter
    /// emission.
    is_property: bool = false,
    /// Comma-separated modifier names from `@ObjcProperty(strong, weak, ...)`.
    /// Stored verbatim; the semantic interpretation lives downstream.
    property_modifiers: []const []const u8 = &.{},
};

pub const RuntimeClassMember = union(enum) {
    method: RuntimeMethodDecl,
    field: RuntimeFieldDecl, // JNI runtime only
    extends: []const u8, // sx-side alias name (right of `extends =`)
    implements: []const u8, // sx-side alias name (right of `implements =`)
};

pub const RuntimeClassDecl = struct {
    name: []const u8, // sx-side alias (left of `::`)
    runtime_path: []const u8, // directive arg: "java/path/Foo" / "NSString" / "Foundation.URL"
    runtime: RuntimeKind,
    members: []const RuntimeClassMember = &.{},
    is_extern: bool = false, // `@ObjcClass(…) extern` — class is provided by the runtime; we only reference it (vs `export`, which defines + registers a new sx class)
    is_main: bool = false, // `main = true` / `main = true` — class is the launchable entry (Activity / UIApplicationDelegate / ...)
    /// True when the sx-side alias NAME was a backtick raw identifier — exempt
    /// from the reserved-type-name decl check.
    is_raw: bool = false,
    /// Defining module path (stamped by `resolveImports`), so the IMP trampolines
    /// emitted for an sx-defined class resolve their method-signature types in the
    /// module that declares the class — not the (cross-module) lowering site that
    /// happens to trigger emission. Null for a synthesized/sourceless decl.
    source_file: ?[]const u8 = null,
};

pub const JniEnvBlock = struct {
    env: *Node, // expression yielding the *JNIEnv for this scope
    body: *Node, // block (or expression) — runs with `env` scoped via TL push/pop
};

pub const ImplBlock = struct {
    protocol_name: []const u8,
    target_type: []const u8,
    target_type_params: []const StructTypeParam = &.{}, // for `impl P for List($T)`
    methods: []const *Node, // fn_decl nodes
    protocol_type_args: []const *Node = &.{}, // for `impl Into(Block) for Source` — type args on the protocol side
    target_type_expr: ?*Node = null, // populated for parameterised-protocol impls; carries non-identifier source spellings (e.g. `Closure() -> void`)
    /// `impl (i64) -> i64 for Accumulator` — the function-type head, which
    /// makes the conformer callable. It names no protocol, so `protocol_name`
    /// is empty wherever this is set.
    protocol_fn_type: ?*Node = null,
};

// ── Expansion cloning ───────────────────────────────────────────────────

/// Name → replacement node, as bound by a module-scope `inline for` cursor.
pub const Substitution = std.StringHashMap(*const Node);

/// The bare NAME a node denotes, when it denotes one. `inline for` cursors
/// bind type names, so only the two bare-name spellings answer.
pub fn bareName(node: *const Node) ?[]const u8 {
    return switch (node.data) {
        .identifier => |id| id.name,
        .type_expr => |te| te.name,
        else => null,
    };
}

/// Deep-copy an AST subtree, replacing every reference to a substituted name
/// with a fresh copy of its bound node. Reference sites are the bare-name
/// spellings a cursor can occupy: an expression identifier, a type
/// expression, a parameterized-type head, a struct-literal prefix, and an
/// `impl`'s target-type spelling. The copy is complete — an expansion never
/// shares nodes with its template, so per-iteration source stamping and
/// diagnostics stay independent.
pub fn cloneWithSubst(
    allocator: std.mem.Allocator,
    node: *const Node,
    subst: *const Substitution,
) std.mem.Allocator.Error!*Node {
    if (bareName(node)) |name| {
        if (subst.get(name)) |replacement| {
            var empty = Substitution.init(allocator);
            defer empty.deinit();
            const copy = try cloneWithSubst(allocator, replacement, &empty);
            copy.span = node.span;
            return copy;
        }
    }
    const out = try allocator.create(Node);
    out.* = .{
        .span = node.span,
        .data = try cloneData(allocator, node.data, subst),
        .source_file = node.source_file,
        .visibility = node.visibility,
    };
    switch (out.data) {
        .parameterized_type_expr => |*pt| {
            if (subst.get(pt.name)) |replacement| {
                if (bareName(replacement)) |name| pt.name = name;
            }
        },
        .struct_literal => |*sl| {
            if (sl.struct_name) |sn| {
                if (subst.get(sn)) |replacement| {
                    if (bareName(replacement)) |name| sl.struct_name = name;
                }
            }
        },
        .impl_block => |*ib| {
            if (subst.get(ib.target_type)) |replacement| {
                if (bareName(replacement)) |name| ib.target_type = name;
            }
        },
        else => {},
    }
    return out;
}

fn cloneData(
    allocator: std.mem.Allocator,
    data: Node.Data,
    subst: *const Substitution,
) std.mem.Allocator.Error!Node.Data {
    switch (data) {
        inline else => |payload, tag| {
            const cloned = try cloneValue(@TypeOf(payload), allocator, payload, subst);
            return @unionInit(Node.Data, @tagName(tag), cloned);
        },
    }
}

fn cloneValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: T,
    subst: *const Substitution,
) std.mem.Allocator.Error!T {
    if (comptime !holdsNode(T)) return value;
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => return try cloneWithSubst(allocator, value, subst),
            .slice => {
                const buf = try allocator.alloc(p.child, value.len);
                for (value, 0..) |elem, i| buf[i] = try cloneValue(p.child, allocator, elem, subst);
                return buf;
            },
            else => return value,
        },
        .optional => |o| return if (value) |inner| try cloneValue(o.child, allocator, inner, subst) else null,
        .@"struct" => |s| {
            var out: T = value;
            inline for (s.fields) |f| {
                @field(out, f.name) = try cloneValue(f.type, allocator, @field(value, f.name), subst);
            }
            return out;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                const cloned = try cloneValue(@TypeOf(payload), allocator, payload, subst);
                return @unionInit(T, @tagName(tag), cloned);
            },
        },
        else => return value,
    }
}

/// True when `T` reaches a `*Node` — the comptime gate that keeps the cloner
/// off the payload types it must copy verbatim (names, spans, flags).
fn holdsNode(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => p.child == Node,
            .slice => holdsNode(p.child),
            else => false,
        },
        .optional => |o| holdsNode(o.child),
        .@"struct" => |s| blk: {
            for (s.fields) |f| {
                if (holdsNode(f.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            for (u.fields) |f| {
                if (holdsNode(f.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}
