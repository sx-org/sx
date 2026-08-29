pub const Tag = enum(u8) {
    // Literals
    int_literal,
    float_literal,
    string_literal,
    raw_string_literal,
    char_literal,

    // Identifiers and keywords
    identifier,
    /// `@Name` — a compiler-formed type name (`@Init`). The `@` is part of the
    /// name; the token is deliberately NOT an `.identifier`, so an `@` name can
    /// only be written where the grammar explicitly accepts one (a type
    /// position). Every other position — declarations, expressions — rejects it
    /// through the ordinary "expected …" path, which is what makes `@` names
    /// undeclarable by user code.
    at_identifier,
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
    kw_match,
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
    kw_is, // is (type-classification infix)
    kw_impl, // impl
    kw_Self, // Self (in interface/constraint declarations)
    kw_inline, // inline (compile-time if/for/while)
    kw_abi, // abi (ABI / calling-convention annotation: abi(.c)/abi(.zig)/abi(.naked))
    kw_extern, // extern (import: external linkage, C ABI, no body)
    kw_export, // export (define + expose: external linkage, C ABI)
    kw_asm, // asm (inline assembly expression / global asm decl)
    kw_intrinsic, // intrinsic (body position: the impl is a compiler intrinsic)
    kw_private, // private (file-local visibility: module-scope decls and struct fields)

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
    caret, // ^
    caret_equal, // ^=
    question, // ?
    question_question, // ??
    question_dot, // ?.
    question_bang, // ?!
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
    /// `_{` — the env a closure literal names after its `|params|`. One token,
    /// so `_ {` with a space is an identifier and a brace instead.
    underscore_l_brace,

    // Arrows
    arrow, // ->
    fat_arrow, // =>

    // Directives
    at_run, // @run — compile-time evaluation prefix
    at_insert, // @insert — splice a compile-time string as sx
    at_import, // @import
    at_library, // @library
    at_framework, // @framework
    at_using, // @using
    at_include, // @include (inside @import c { ... })
    at_source, // @source (inside @import c { ... })
    at_define, // @define (inside @import c { ... })
    at_flags, // @flags (inside @import c { ... })
    at_get, // `name :: (self) -> R @get => expr;` — a no-paren property accessor method (read via field syntax)
    at_set, // `name :: (self, value) @set { ... }` — the write counterpart of @get (`obj.name = rhs` dispatches here)
    at_context_extend, // `@context.extend name: Type = default;` — top-level Context field declaration
    triple_minus, // ---
    minus_minus,

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
            .caret => "^",
            .caret_equal => "^=",
            .question => "?",
            .question_question => "??",
            .question_dot => "?.",
            .question_bang => "?!",
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
            .underscore_l_brace => "_{",
            .arrow => "->",
            .fat_arrow => "=>",
            .triple_minus => "---",
            .minus_minus => "--",
            else => null,
        };
    }

    pub fn isTypeKeyword(tag: Tag) bool {
        return switch (tag) {
            .kw_f32, .kw_f64, .kw_Type, .kw_Self => true,
            else => false,
        };
    }

    /// The coarse token classes consumers dispatch on. `at_identifier` sits
    /// with the type keywords: a compiler-formed `@Name` is only ever a type
    /// spelling.
    pub const Family = enum {
        keyword,
        type_keyword,
        directive,
        identifier,
        number,
        string,
        operator,
        punctuation,
        eof,
        invalid,
    };

    pub fn family(tag: Tag) Family {
        return switch (tag) {
            .int_literal, .float_literal, .char_literal => .number,
            .string_literal, .raw_string_literal => .string,
            .identifier => .identifier,
            .at_identifier, .kw_f32, .kw_f64, .kw_Type, .kw_Self => .type_keyword,
            .kw_if,
            .kw_else,
            .kw_then,
            .kw_true,
            .kw_false,
            .kw_enum,
            .kw_error,
            .kw_raise,
            .kw_try,
            .kw_catch,
            .kw_match,
            .kw_case,
            .kw_break,
            .kw_continue,
            .kw_while,
            .kw_for,
            .kw_return,
            .kw_defer,
            .kw_struct,
            .kw_union,
            .kw_xx,
            .kw_and,
            .kw_or,
            .kw_null,
            .kw_push,
            .kw_ufcs,
            .kw_in,
            .kw_is,
            .kw_impl,
            .kw_inline,
            .kw_abi,
            .kw_extern,
            .kw_export,
            .kw_asm,
            .kw_intrinsic,
            .kw_private,
            => .keyword,
            .at_run,
            .at_import,
            .at_insert,
            .at_library,
            .at_framework,
            .at_using,
            .at_include,
            .at_source,
            .at_define,
            .at_flags,
            .at_get,
            .at_set,
            .at_context_extend,
            => .directive,
            .plus,
            .minus,
            .star,
            .slash,
            .equal,
            .equal_equal,
            .bang,
            .bang_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            .plus_equal,
            .minus_equal,
            .star_equal,
            .slash_equal,
            .percent,
            .percent_equal,
            .ampersand,
            .ampersand_equal,
            .pipe,
            .pipe_equal,
            .caret,
            .caret_equal,
            .question,
            .question_question,
            .question_dot,
            .question_bang,
            .tilde,
            .less_less,
            .less_less_equal,
            .greater_greater,
            .greater_greater_equal,
            .arrow,
            .fat_arrow,
            .colon_colon,
            .colon_equal,
            .triple_minus,
            .minus_minus,
            => .operator,
            .colon,
            .semicolon,
            .comma,
            .dot,
            .dot_dot,
            .dot_dot_eq,
            .dot_dot_lt,
            .lt_dot_dot,
            .lt_dot_dot_eq,
            .lt_dot_dot_lt,
            .eq_dot_dot,
            .eq_dot_dot_eq,
            .eq_dot_dot_lt,
            .dollar,
            .l_paren,
            .r_paren,
            .l_brace,
            .r_brace,
            .l_bracket,
            .r_bracket,
            .underscore_l_brace,
            => .punctuation,
            .eof => .eof,
            .invalid => .invalid,
        };
    }

    /// True for every tag whose spelling lives in the `keywords` map — the
    /// source-keyword question the parser's member-name rules ask.
    pub fn isKeyword(tag: Tag) bool {
        return switch (tag) {
            .kw_if,
            .kw_else,
            .kw_then,
            .kw_true,
            .kw_false,
            .kw_enum,
            .kw_error,
            .kw_raise,
            .kw_try,
            .kw_catch,
            .kw_match,
            .kw_case,
            .kw_break,
            .kw_continue,
            .kw_while,
            .kw_for,
            .kw_return,
            .kw_defer,
            .kw_f32,
            .kw_f64,
            .kw_struct,
            .kw_union,
            .kw_xx,
            .kw_and,
            .kw_or,
            .kw_Type,
            .kw_null,
            .kw_push,
            .kw_ufcs,
            .kw_in,
            .kw_is,
            .kw_impl,
            .kw_Self,
            .kw_inline,
            .kw_abi,
            .kw_extern,
            .kw_export,
            .kw_asm,
            .kw_intrinsic,
            .kw_private,
            => true,
            .int_literal,
            .float_literal,
            .string_literal,
            .raw_string_literal,
            .char_literal,
            .identifier,
            .at_identifier,
            .colon,
            .colon_colon,
            .colon_equal,
            .semicolon,
            .comma,
            .dot,
            .dot_dot,
            .dot_dot_eq,
            .dot_dot_lt,
            .lt_dot_dot,
            .lt_dot_dot_eq,
            .lt_dot_dot_lt,
            .eq_dot_dot,
            .eq_dot_dot_eq,
            .eq_dot_dot_lt,
            .dollar,
            .plus,
            .minus,
            .star,
            .slash,
            .equal,
            .equal_equal,
            .bang,
            .bang_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            .plus_equal,
            .minus_equal,
            .star_equal,
            .slash_equal,
            .percent,
            .percent_equal,
            .ampersand,
            .ampersand_equal,
            .pipe,
            .pipe_equal,
            .caret,
            .caret_equal,
            .question,
            .question_question,
            .question_dot,
            .question_bang,
            .tilde,
            .less_less,
            .less_less_equal,
            .greater_greater,
            .greater_greater_equal,
            .l_paren,
            .r_paren,
            .l_brace,
            .r_brace,
            .l_bracket,
            .r_bracket,
            .underscore_l_brace,
            .arrow,
            .fat_arrow,
            .at_run,
            .at_import,
            .at_insert,
            .at_library,
            .at_framework,
            .at_using,
            .at_include,
            .at_source,
            .at_define,
            .at_flags,
            .at_get,
            .at_set,
            .at_context_extend,
            .triple_minus,
            .minus_minus,
            .eof,
            .invalid,
            => false,
        };
    }
};

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    /// True when an `.identifier` was introduced by a leading backtick
    /// (`` `i32 ``): a RAW identifier whose text excludes the backtick and which
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
    .{ "match", .kw_match },
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
    .{ "is", .kw_is },
    .{ "impl", .kw_impl },
    .{ "Self", .kw_Self },
    .{ "inline", .kw_inline },
    .{ "abi", .kw_abi },
    .{ "extern", .kw_extern },
    .{ "export", .kw_export },
    // `asm` is a real keyword; `volatile` / `clobbers` stay OUT of this table
    // (recognized contextually only inside an `asm { … }` body).
    .{ "asm", .kw_asm },
    // `intrinsic` marks a declaration whose implementation is a compiler
    // intrinsic (`struct_field_count :: ($T: Type) -> i64 intrinsic;`). A
    // reserved word: the registry in `ir/intrinsics.zig` binds it by module +
    // declared name.
    .{ "intrinsic", .kw_intrinsic },
    // `private` restricts a module-scope declaration or a struct field to its
    // declaring source file. A reserved word; `` `private `` stays usable as a
    // raw identifier.
    .{ "private", .kw_private },
});

pub fn getKeyword(bytes: []const u8) ?Tag {
    return keywords.get(bytes);
}

const std = @import("std");
