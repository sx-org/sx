pub const Tag = enum {
    // Literals
    int_literal,
    float_literal,
    string_literal,
    raw_string_literal,
    char_literal,

    // Identifiers and keywords
    identifier,
    kw_if,
    kw_else,
    kw_then,
    kw_true,
    kw_false,
    kw_enum,
    kw_error, // error (error-set declaration)
    kw_raise, // raise (error propagation statement)
    kw_try, // try (failable-attempt prefix)
    kw_catch, // catch (failable handler postfix)
    kw_onfail, // onfail (error-exit cleanup statement)
    kw_case,
    kw_break,
    kw_continue,
    kw_while,
    kw_for,
    kw_return,
    kw_defer,
    kw_f32,
    kw_f64,
    kw_struct,
    kw_union,
    kw_xx,
    kw_and,
    kw_or,
    kw_Type, // Type (metatype keyword)
    kw_null, // null
    kw_push, // push
    kw_ufcs, // ufcs
    kw_in, // in
    kw_protocol, // protocol
    kw_impl, // impl
    kw_Self, // Self (in protocol declarations)
    kw_inline, // inline (compile-time if/for/while)
    kw_abi, // abi (ABI / calling-convention annotation: abi(.c)/abi(.zig)/abi(.naked))
    kw_extern, // extern (import: external linkage, C ABI, no body)
    kw_export, // export (define + expose: external linkage, C ABI)
    kw_asm, // asm (inline assembly expression / global asm decl)
    kw_intrinsic, // intrinsic (body position: the impl is a compiler intrinsic)
    kw_private, // private (module-scope declaration visibility modifier)

    // Symbols
    colon, // :
    colon_colon, // ::
    colon_equal, // :=
    semicolon, // ;
    comma, // ,
    dot, // .
    dot_dot, // ..
    dot_dot_eq, // ..=
    dot_dot_lt, // ..<
    lt_dot_dot, // <..
    lt_dot_dot_eq, // <..=
    lt_dot_dot_lt, // <..<
    eq_dot_dot, // =..
    eq_dot_dot_eq, // =..=
    eq_dot_dot_lt, // =..<
    dollar, // $

    // Operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    equal, // =
    equal_equal, // ==
    bang, // !
    bang_equal, // !=
    less, // <
    less_equal, // <=
    greater, // >
    greater_equal, // >=
    plus_equal, // +=
    minus_equal, // -=
    star_equal, // *=
    slash_equal, // /=
    percent, // %
    percent_equal, // %=
    ampersand, // &
    ampersand_equal, // &=
    pipe, // |
    pipe_equal, // |=
    pipe_arrow, // |>
    caret, // ^
    caret_equal, // ^=
    question, // ?
    question_question, // ??
    question_dot, // ?.
    tilde, // ~
    less_less, // <<
    less_less_equal, // <<=
    greater_greater, // >>
    greater_greater_equal, // >>=

    // Delimiters
    l_paren, // (
    r_paren, // )
    l_brace, // {
    r_brace, // }
    l_bracket, // [
    r_bracket, // ]

    // Arrows
    arrow, // ->
    fat_arrow, // =>

    // Directives
    hash_run, // #run
    hash_error, // #error "msg" — emit a compile-time diagnostic (e.g. in an unsupported `inline if OS` arm)
    hash_import, // #import
    hash_insert, // #insert
    hash_library, // #library
    hash_framework, // #framework
    hash_using, // #using
    hash_include, // #include (inside #import c { ... })
    hash_source, // #source (inside #import c { ... })
    hash_define, // #define (inside #import c { ... })
    hash_flags, // #flags (inside #import c { ... })
    hash_inline, // #inline (protocol layout modifier)
    hash_identity, // #identity (protocol ownership-class marker: borrow-only values)
    hash_objc_call, // #objc_call(T)(recv, "sel:", args...)
    hash_jni_call, // #jni_call(T)(env, target, "name", "(Sig)R", args...)
    hash_jni_static_call, // #jni_static_call(T)(class, "name", "(Sig)R", args...)
    hash_jni_class, // Foo :: #jni_class("java/path/Foo") { ...body... }
    hash_jni_interface, // Foo :: #jni_interface("java/path/IFoo") { ...body... }
    hash_objc_class, // Foo :: #objc_class("ObjcName") { ...body... }
    hash_objc_protocol, // Foo :: #objc_protocol("ObjcProto") { ...body... }
    hash_swift_class, // Foo :: #swift_class("Module.Type") { ...body... }
    hash_swift_struct, // Foo :: #swift_struct("Module.Type") { ...body... }
    hash_swift_protocol, // Foo :: #swift_protocol("Module.Proto") { ...body... }
    hash_extends, // `#extends Alias;` inside a runtime-class body
    hash_implements, // `#implements Alias;` inside a runtime-class body
    hash_jni_method_descriptor, // `#jni_method_descriptor("(Sig)Ret")` per-method JNI descriptor override
    hash_selector, // `#selector("explicit:string")` per-method Obj-C selector override (Phase 3.2)
    hash_property, // `#property[(modifier, ...)]` field directive — synthesizes getter/setter dispatch (M2.2)
    hash_get, // `name :: (self) -> R #get => expr;` — a no-paren property accessor method (read via field syntax)
    hash_set, // `name :: (self, value) #set { ... }` — the write counterpart of #get (`obj.name = rhs` dispatches here)
    hash_caller_location, // `#caller_location` — as a param default, synthesizes the call site's Source_Location (ERR E4.1b)
    hash_jni_env, // `#jni_env(env) { body }` block-form env-scoping intrinsic
    hash_jni_main, // `#jni_main #jni_class(...) { ... }` — class is the launchable Android Activity
    hash_context_extend, // `#context_extend name: Type = default;` — top-level Context field declaration
    triple_minus, // ---

    // Special
    eof,
    invalid,

    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .colon => ":",
            .colon_colon => "::",
            .colon_equal => ":=",
            .semicolon => ";",
            .comma => ",",
            .dot => ".",
            .dot_dot => "..",
            .dot_dot_eq => "..=",
            .dot_dot_lt => "..<",
            .lt_dot_dot => "<..",
            .lt_dot_dot_eq => "<..=",
            .lt_dot_dot_lt => "<..<",
            .eq_dot_dot => "=..",
            .eq_dot_dot_eq => "=..=",
            .eq_dot_dot_lt => "=..<",
            .dollar => "$",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .equal => "=",
            .equal_equal => "==",
            .bang => "!",
            .bang_equal => "!=",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            .plus_equal => "+=",
            .minus_equal => "-=",
            .star_equal => "*=",
            .slash_equal => "/=",
            .percent => "%",
            .percent_equal => "%=",
            .ampersand => "&",
            .ampersand_equal => "&=",
            .pipe => "|",
            .pipe_equal => "|=",
            .pipe_arrow => "|>",
            .caret => "^",
            .caret_equal => "^=",
            .question => "?",
            .question_question => "??",
            .question_dot => "?.",
            .tilde => "~",
            .less_less => "<<",
            .less_less_equal => "<<=",
            .greater_greater => ">>",
            .greater_greater_equal => ">>=",
            .kw_null => "null",
            .l_paren => "(",
            .r_paren => ")",
            .l_brace => "{",
            .r_brace => "}",
            .l_bracket => "[",
            .r_bracket => "]",
            .arrow => "->",
            .fat_arrow => "=>",
            .triple_minus => "---",
            else => null,
        };
    }

    pub fn isTypeKeyword(tag: Tag) bool {
        return switch (tag) {
            .kw_f32, .kw_f64, .kw_Type, .kw_Self => true,
            else => false,
        };
    }
};

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    /// True when an `.identifier` was introduced by a leading backtick
    /// (`` `i2 ``): a RAW identifier whose text excludes the backtick and which
    /// the parser must NEVER type-classify (it bypasses the reserved-type-name
    /// rule). `loc` already spans only the un-backticked name, so `slice` returns
    /// the bare text.
    is_raw: bool = false,

    pub const Loc = struct {
        start: u32,
        end: u32,
    };

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }
};

pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "then", .kw_then },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "enum", .kw_enum },
    .{ "error", .kw_error },
    .{ "raise", .kw_raise },
    .{ "try", .kw_try },
    .{ "catch", .kw_catch },
    .{ "onfail", .kw_onfail },
    .{ "case", .kw_case },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "while", .kw_while },
    .{ "for", .kw_for },
    .{ "return", .kw_return },
    .{ "defer", .kw_defer },
    .{ "f32", .kw_f32 },
    .{ "f64", .kw_f64 },
    .{ "struct", .kw_struct },
    .{ "union", .kw_union },
    .{ "xx", .kw_xx },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "Type", .kw_Type },
    .{ "null", .kw_null },
    .{ "push", .kw_push },
    .{ "ufcs", .kw_ufcs },
    .{ "in", .kw_in },
    .{ "protocol", .kw_protocol },
    .{ "impl", .kw_impl },
    .{ "Self", .kw_Self },
    .{ "inline", .kw_inline },
    .{ "abi", .kw_abi },
    .{ "extern", .kw_extern },
    .{ "export", .kw_export },
    // `asm` is a real keyword; `volatile` / `clobbers` stay OUT of this table
    // (recognized contextually only inside an `asm { … }` body — see PLAN-ASM).
    .{ "asm", .kw_asm },
    // `intrinsic` marks a declaration whose implementation is a compiler
    // intrinsic (`size_of :: ($T: Type) -> i64 intrinsic;`). A reserved word:
    // the registry in `ir/intrinsics.zig` binds it by module + declared name.
    .{ "intrinsic", .kw_intrinsic },
    // `private` restricts a module-scope declaration to its declaring source
    // file. A reserved word; `` `private `` stays usable as a raw identifier.
    .{ "private", .kw_private },
});

pub fn getKeyword(bytes: []const u8) ?Tag {
    return keywords.get(bytes);
}

const std = @import("std");
