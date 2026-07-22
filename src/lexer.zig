const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const getKeyword = @import("token.zig").getKeyword;

pub const Lexer = struct {
    source: [:0]const u8,
    index: u32,

    pub fn init(source: [:0]const u8) Lexer {
        return .{ .source = source, .index = 0 };
    }

    pub fn next(self: *Lexer) Token {
        // Skip whitespace and comments
        while (true) {
            if (self.index >= self.source.len) {
                return self.makeToken(.eof, self.index, self.index);
            }
            const c = self.source[self.index];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.index += 1;
                continue;
            }
            // Line comments
            if (c == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                while (self.index < self.source.len and self.source[self.index] != '\n') {
                    self.index += 1;
                }
                continue;
            }
            break;
        }

        const start = self.index;
        const c = self.source[start];

        // Integer / float literals
        if (isDigit(c)) {
            return self.lexNumber(start);
        }

        // Identifiers and keywords
        if (isIdentStart(c)) {
            return self.lexIdentifier(start);
        }

        // String literals
        if (c == '"') {
            return self.lexString(start);
        }

        // Char literals: '...' (single quotes). Body is left raw for the
        // parser to decode (mirrors lexString deferring unescaping).
        if (c == '\'') {
            return self.lexChar(start);
        }

        // Raw-identifier escape: `ident — a leading backtick forces the
        // following identifier to be RAW (never type-classified, never
        // reserved-checked). The emitted token's span excludes the backtick, so
        // its text is the bare name, and a backticked keyword spelling
        // (`` `i2 ``, `` `string ``) is still an `.identifier`, never a keyword.
        if (c == '`') {
            const id_start = start + 1;
            if (id_start < self.source.len and isIdentStart(self.source[id_start])) {
                self.index = id_start;
                var tok = self.lexIdentifier(id_start);
                tok.tag = .identifier;
                tok.is_raw = true;
                return tok;
            }
            self.index += 1;
            return self.makeToken(.invalid, start, self.index);
        }


        // Directives: #import, #insert, #run, #library, #string
        if (c == '#') {
            // #string needs special handling (heredoc)
            const str_kw = "#string";
            const str_len: u32 = str_kw.len;
            if (self.source.len >= start + str_len and
                std.mem.eql(u8, self.source[start .. start + str_len], str_kw) and
                (start + str_len >= self.source.len or !isIdentContinue(self.source[start + str_len])))
            {
                self.index = start + str_len;
                return self.lexHeredoc(start);
            }

            const directives = .{
                .{ "#import", Tag.hash_import },
                .{ "#insert", Tag.hash_insert },
                .{ "#run", Tag.hash_run },
                .{ "#error", Tag.hash_error },
                .{ "#library", Tag.hash_library },
                .{ "#framework", Tag.hash_framework },
                .{ "#using", Tag.hash_using },
                .{ "#include", Tag.hash_include },
                .{ "#source", Tag.hash_source },
                .{ "#define", Tag.hash_define },
                .{ "#flags", Tag.hash_flags },
                .{ "#inline", Tag.hash_inline },
                .{ "#identity", Tag.hash_identity },
                .{ "#objc_call", Tag.hash_objc_call },
                .{ "#jni_call", Tag.hash_jni_call },
                .{ "#jni_static_call", Tag.hash_jni_static_call },
                .{ "#jni_class", Tag.hash_jni_class },
                .{ "#jni_interface", Tag.hash_jni_interface },
                .{ "#objc_class", Tag.hash_objc_class },
                .{ "#objc_protocol", Tag.hash_objc_protocol },
                .{ "#swift_class", Tag.hash_swift_class },
                .{ "#swift_struct", Tag.hash_swift_struct },
                .{ "#swift_protocol", Tag.hash_swift_protocol },
                .{ "#extends", Tag.hash_extends },
                .{ "#implements", Tag.hash_implements },
                .{ "#jni_method_descriptor", Tag.hash_jni_method_descriptor },
                .{ "#jni_env", Tag.hash_jni_env },
                .{ "#jni_main", Tag.hash_jni_main },
                .{ "#selector", Tag.hash_selector },
                .{ "#property", Tag.hash_property },
                .{ "#get", Tag.hash_get },
                .{ "#set", Tag.hash_set },
                .{ "#caller_location", Tag.hash_caller_location },
                .{ "#context_extend", Tag.hash_context_extend },
            };
            inline for (directives) |d| {
                const keyword = d[0];
                const tag = d[1];
                const len: u32 = keyword.len;
                if (self.source.len >= start + len and
                    std.mem.eql(u8, self.source[start .. start + len], keyword) and
                    (start + len >= self.source.len or !isIdentContinue(self.source[start + len])))
                {
                    self.index = start + len;
                    return self.makeToken(tag, start, self.index);
                }
            }
            self.index += 1;
            return self.makeToken(.invalid, start, self.index);
        }

        // Punctuation and operators
        self.index += 1;
        switch (c) {
            ';' => return self.makeToken(.semicolon, start, self.index),
            ',' => return self.makeToken(.comma, start, self.index),
            '(' => return self.makeToken(.l_paren, start, self.index),
            ')' => return self.makeToken(.r_paren, start, self.index),
            '{' => return self.makeToken(.l_brace, start, self.index),
            '}' => return self.makeToken(.r_brace, start, self.index),
            '[' => return self.makeToken(.l_bracket, start, self.index),
            ']' => return self.makeToken(.r_bracket, start, self.index),
            '.' => {
                if (self.peek() == '.') {
                    self.index += 1;
                    if (self.peek() == '=') {
                        self.index += 1;
                        return self.makeToken(.dot_dot_eq, start, self.index);
                    }
                    if (self.peek() == '<') {
                        self.index += 1;
                        return self.makeToken(.dot_dot_lt, start, self.index);
                    }
                    return self.makeToken(.dot_dot, start, self.index);
                }
                return self.makeToken(.dot, start, self.index);
            },
            '$' => return self.makeToken(.dollar, start, self.index),
            ':' => {
                if (self.peek() == ':') {
                    self.index += 1;
                    return self.makeToken(.colon_colon, start, self.index);
                }
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.colon_equal, start, self.index);
                }
                return self.makeToken(.colon, start, self.index);
            },
            '=' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.equal_equal, start, self.index);
                }
                if (self.peek() == '>') {
                    self.index += 1;
                    return self.makeToken(.fat_arrow, start, self.index);
                }
                // Range with an explicit inclusive start: `=..`, `=..=`, `=..<`.
                if (self.peek() == '.' and self.peekAt(1) == '.') {
                    self.index += 2;
                    if (self.peek() == '=') {
                        self.index += 1;
                        return self.makeToken(.eq_dot_dot_eq, start, self.index);
                    }
                    if (self.peek() == '<') {
                        self.index += 1;
                        return self.makeToken(.eq_dot_dot_lt, start, self.index);
                    }
                    return self.makeToken(.eq_dot_dot, start, self.index);
                }
                return self.makeToken(.equal, start, self.index);
            },
            '+' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.plus_equal, start, self.index);
                }
                return self.makeToken(.plus, start, self.index);
            },
            '-' => {
                if (self.peek() == '-' and (self.index + 1) < self.source.len and self.source[self.index + 1] == '-') {
                    self.index += 2;
                    return self.makeToken(.triple_minus, start, self.index);
                }
                if (self.peek() == '>') {
                    self.index += 1;
                    return self.makeToken(.arrow, start, self.index);
                }
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.minus_equal, start, self.index);
                }
                return self.makeToken(.minus, start, self.index);
            },
            '*' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.star_equal, start, self.index);
                }
                return self.makeToken(.star, start, self.index);
            },
            '/' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.slash_equal, start, self.index);
                }
                return self.makeToken(.slash, start, self.index);
            },
            '%' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.percent_equal, start, self.index);
                }
                return self.makeToken(.percent, start, self.index);
            },
            '&' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.ampersand_equal, start, self.index);
                }
                return self.makeToken(.ampersand, start, self.index);
            },
            '|' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.pipe_equal, start, self.index);
                }
                if (self.peek() == '>') {
                    self.index += 1;
                    return self.makeToken(.pipe_arrow, start, self.index);
                }
                return self.makeToken(.pipe, start, self.index);
            },
            '^' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.caret_equal, start, self.index);
                }
                return self.makeToken(.caret, start, self.index);
            },
            '~' => return self.makeToken(.tilde, start, self.index),
            '?' => {
                if (self.peek() == '?') {
                    self.index += 1;
                    return self.makeToken(.question_question, start, self.index);
                }
                if (self.peek() == '.') {
                    self.index += 1;
                    return self.makeToken(.question_dot, start, self.index);
                }
                return self.makeToken(.question, start, self.index);
            },
            '!' => {
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.bang_equal, start, self.index);
                }
                return self.makeToken(.bang, start, self.index);
            },
            '<' => {
                // Range with an exclusive start: `<..`, `<..=`, `<..<`.
                if (self.peek() == '.' and self.peekAt(1) == '.') {
                    self.index += 2;
                    if (self.peek() == '=') {
                        self.index += 1;
                        return self.makeToken(.lt_dot_dot_eq, start, self.index);
                    }
                    if (self.peek() == '<') {
                        self.index += 1;
                        return self.makeToken(.lt_dot_dot_lt, start, self.index);
                    }
                    return self.makeToken(.lt_dot_dot, start, self.index);
                }
                if (self.peek() == '<') {
                    self.index += 1;
                    if (self.peek() == '=') {
                        self.index += 1;
                        return self.makeToken(.less_less_equal, start, self.index);
                    }
                    return self.makeToken(.less_less, start, self.index);
                }
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.less_equal, start, self.index);
                }
                return self.makeToken(.less, start, self.index);
            },
            '>' => {
                if (self.peek() == '>') {
                    self.index += 1;
                    if (self.peek() == '=') {
                        self.index += 1;
                        return self.makeToken(.greater_greater_equal, start, self.index);
                    }
                    return self.makeToken(.greater_greater, start, self.index);
                }
                if (self.peek() == '=') {
                    self.index += 1;
                    return self.makeToken(.greater_equal, start, self.index);
                }
                return self.makeToken(.greater, start, self.index);
            },
            else => return self.makeToken(.invalid, start, self.index),
        }
    }

    fn lexNumber(self: *Lexer, start: u32) Token {
        // Advance past the initial digit that was already matched
        self.index += 1;

        // Check for hex (0x/0X) or binary (0b/0B) prefix
        if (self.source[start] == '0' and self.index < self.source.len) {
            const prefix = self.source[self.index];
            if (prefix == 'x' or prefix == 'X') {
                self.index += 1; // skip 'x'/'X'
                while (self.index < self.source.len and isHexDigitOrSep(self.source[self.index])) {
                    self.index += 1;
                }
                return self.makeToken(.int_literal, start, self.index);
            }
            if (prefix == 'b' or prefix == 'B') {
                self.index += 1; // skip 'b'/'B'
                while (self.index < self.source.len and (self.source[self.index] == '0' or self.source[self.index] == '1' or self.source[self.index] == '_')) {
                    self.index += 1;
                }
                return self.makeToken(.int_literal, start, self.index);
            }
            if (prefix == 'o' or prefix == 'O') {
                self.index += 1; // skip 'o'/'O'
                while (self.index < self.source.len and ((self.source[self.index] >= '0' and self.source[self.index] <= '7') or self.source[self.index] == '_')) {
                    self.index += 1;
                }
                return self.makeToken(.int_literal, start, self.index);
            }
        }

        while (self.index < self.source.len and isDigitOrSep(self.source[self.index])) {
            self.index += 1;
        }
        // Check for float
        if (self.index < self.source.len and self.source[self.index] == '.') {
            // Look ahead: must be followed by a REAL digit (not `.identifier`,
            // and not `_` — so `1_000.method()` doesn't misparse as a float).
            if (self.index + 1 < self.source.len and isDigit(self.source[self.index + 1])) {
                self.index += 1; // skip '.'
                while (self.index < self.source.len and isDigitOrSep(self.source[self.index])) {
                    self.index += 1;
                }
                return self.makeToken(.float_literal, start, self.index);
            }
        }
        return self.makeToken(.int_literal, start, self.index);
    }

    fn lexIdentifier(self: *Lexer, start: u32) Token {
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.index += 1;
        }
        const text = self.source[start..self.index];
        if (getKeyword(text)) |kw| {
            return self.makeToken(kw, start, self.index);
        }
        return self.makeToken(.identifier, start, self.index);
    }

    fn lexString(self: *Lexer, start: u32) Token {
        self.index += 1; // skip opening "
        while (self.index < self.source.len) {
            const ch = self.source[self.index];
            if (ch == '"') {
                self.index += 1;
                return self.makeToken(.string_literal, start, self.index);
            }
            if (ch == '\\') {
                self.index += 1; // skip escape
            }
            self.index += 1;
        }
        // Unterminated string
        return self.makeToken(.invalid, start, self.index);
    }

    /// Lex a `'...'` char literal. Mirrors `lexString`: skip the opening `'`,
    /// scan to the closing `'` (skipping `\\` + the next byte so an escaped
    /// `\'` doesn't terminate early), and produce an `.invalid` token on
    /// unterminated input. The body is left raw for the parser to decode.
    fn lexChar(self: *Lexer, start: u32) Token {
        self.index += 1; // skip opening '
        while (self.index < self.source.len) {
            const ch = self.source[self.index];
            if (ch == '\'') {
                self.index += 1;
                return self.makeToken(.char_literal, start, self.index);
            }
            if (ch == '\\') {
                self.index += 1; // skip escape introducer
            }
            self.index += 1;
        }
        // Unterminated char literal
        return self.makeToken(.invalid, start, self.index);
    }


    /// Lex a #string heredoc. Called after "#string" has been matched.
    /// Syntax: #string DELIM\n...content...\nDELIM
    fn lexHeredoc(self: *Lexer, directive_start: u32) Token {
        // Skip spaces/tabs to find delimiter identifier
        while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) {
            self.index += 1;
        }

        // Read delimiter identifier
        const delim_start = self.index;
        if (self.index >= self.source.len or !isIdentStart(self.source[self.index])) {
            return self.makeToken(.invalid, directive_start, self.index);
        }
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.index += 1;
        }
        const delimiter = self.source[delim_start..self.index];

        // Skip to newline (rest of line after delimiter is ignored)
        while (self.index < self.source.len and self.source[self.index] != '\n') {
            self.index += 1;
        }
        if (self.index >= self.source.len) {
            return self.makeToken(.invalid, directive_start, self.index);
        }
        self.index += 1; // skip the newline

        // Content starts here
        const content_start = self.index;

        // Scan lines until delimiter appears at column 0
        while (self.index < self.source.len) {
            const line_start = self.index;

            // Check if this line starts with the delimiter
            if (self.index + delimiter.len <= self.source.len and
                std.mem.eql(u8, self.source[line_start .. line_start + delimiter.len], delimiter) and
                (line_start + delimiter.len >= self.source.len or
                !isIdentContinue(self.source[line_start + delimiter.len])))
            {
                const content_end = line_start;
                self.index = line_start + @as(u32, @intCast(delimiter.len));
                return self.makeToken(.raw_string_literal, content_start, content_end);
            }

            // Skip to next line
            while (self.index < self.source.len and self.source[self.index] != '\n') {
                self.index += 1;
            }
            if (self.index < self.source.len) {
                self.index += 1; // skip '\n'
            }
        }

        // Unterminated heredoc
        return self.makeToken(.invalid, directive_start, self.index);
    }

    fn peek(self: *const Lexer) u8 {
        if (self.index < self.source.len) {
            return self.source[self.index];
        }
        return 0;
    }

    fn peekAt(self: *const Lexer, offset: u32) u8 {
        const i = self.index + offset;
        if (i < self.source.len) {
            return self.source[i];
        }
        return 0;
    }

    fn makeToken(_: *const Lexer, tag: Tag, start: u32, end: u32) Token {
        return .{ .tag = tag, .loc = .{ .start = start, .end = end } };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    /// Decimal digit or a `_` visual separator (separators are stripped in the parser).
    fn isDigitOrSep(c: u8) bool {
        return isDigit(c) or c == '_';
    }

    /// Hex digit or a `_` visual separator (separators are stripped in the parser).
    fn isHexDigitOrSep(c: u8) bool {
        return isHexDigit(c) or c == '_';
    }

    fn isIdentContinue(c: u8) bool {
        return isIdentStart(c) or isDigit(c);
    }
};

test "lex minimal main" {
    var lex = Lexer.init("main :: () { 42; }");
    const expected = [_]Tag{ .identifier, .colon_colon, .l_paren, .r_paren, .l_brace, .int_literal, .semicolon, .r_brace, .eof };
    for (expected) |exp| {
        const tok = lex.next();
        try std.testing.expectEqual(exp, tok.tag);
    }
}

test "lex with comments" {
    var lex = Lexer.init("// comment\nmain :: () { 0; }");
    try std.testing.expectEqual(Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Tag.colon_colon, lex.next().tag);
}

test "lex operators" {
    var lex = Lexer.init(":= : :: += -= *= /= -> => == != <= >=");
    const expected = [_]Tag{
        .colon_equal, .colon,       .colon_colon, .plus_equal, .minus_equal,
        .star_equal,  .slash_equal, .arrow,       .fat_arrow,  .equal_equal,
        .bang_equal,  .less_equal,  .greater_equal,
    };
    for (expected) |exp| {
        try std.testing.expectEqual(exp, lex.next().tag);
    }
}

test "lex float" {
    var lex = Lexer.init("0.3 42 0.9");
    try std.testing.expectEqual(Tag.float_literal, lex.next().tag);
    try std.testing.expectEqual(Tag.int_literal, lex.next().tag);
    try std.testing.expectEqual(Tag.float_literal, lex.next().tag);
}

test "lex keywords" {
    var lex = Lexer.init("if else then true false enum case break return f32 f64 struct");
    const expected = [_]Tag{
        .kw_if, .kw_else, .kw_then, .kw_true, .kw_false,
        .kw_enum, .kw_case, .kw_break, .kw_return, .kw_f32, .kw_f64, .kw_struct,
    };
    for (expected) |exp| {
        try std.testing.expectEqual(exp, lex.next().tag);
    }
}

test "lex linkage keywords" {
    // extern / export are keywords (FFI-linkage stream), lexed beside abi.
    var lex = Lexer.init("abi extern export");
    const expected = [_]Tag{ .kw_abi, .kw_extern, .kw_export };
    for (expected) |exp| {
        try std.testing.expectEqual(exp, lex.next().tag);
    }
}

test "lex type-like identifiers" {
    // i32, u8, bool, string are identifiers, not keywords
    var lex = Lexer.init("i32 u8 bool string");
    for (0..4) |_| {
        try std.testing.expectEqual(Tag.identifier, lex.next().tag);
    }
}

test "lex backtick raw identifier" {
    const source: [:0]const u8 = "`i2 `string `for";
    var lex = Lexer.init(source);
    // Each is an `.identifier` carrying `is_raw`, even a keyword spelling
    // (`for`), with text that excludes the leading backtick.
    const t1 = lex.next();
    try std.testing.expectEqual(Tag.identifier, t1.tag);
    try std.testing.expect(t1.is_raw);
    try std.testing.expectEqualStrings("i2", t1.slice(source));
    const t2 = lex.next();
    try std.testing.expectEqual(Tag.identifier, t2.tag);
    try std.testing.expect(t2.is_raw);
    try std.testing.expectEqualStrings("string", t2.slice(source));
    const t3 = lex.next();
    try std.testing.expectEqual(Tag.identifier, t3.tag);
    try std.testing.expect(t3.is_raw);
    try std.testing.expectEqualStrings("for", t3.slice(source));
    try std.testing.expectEqual(Tag.eof, lex.next().tag);
}

test "lex bare identifier is not raw" {
    var lex = Lexer.init("i2");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.identifier, tok.tag);
    try std.testing.expect(!tok.is_raw);
}

test "lex lone backtick is invalid" {
    var lex = Lexer.init("` 5");
    try std.testing.expectEqual(Tag.invalid, lex.next().tag);
}

test "lex hash_run" {
    var lex = Lexer.init("#run");
    try std.testing.expectEqual(Tag.hash_run, lex.next().tag);
    try std.testing.expectEqual(Tag.eof, lex.next().tag);

    // #run followed by identifier
    var lex2 = Lexer.init("#run compute(5)");
    try std.testing.expectEqual(Tag.hash_run, lex2.next().tag);
    try std.testing.expectEqual(Tag.identifier, lex2.next().tag);

    // #running should not match (identContinue after "run")
    var lex3 = Lexer.init("#running");
    try std.testing.expectEqual(Tag.invalid, lex3.next().tag);
}

test "lex hash_import" {
    var lex = Lexer.init("#import \"foo.sx\"");
    try std.testing.expectEqual(Tag.hash_import, lex.next().tag);
    try std.testing.expectEqual(Tag.string_literal, lex.next().tag);
    try std.testing.expectEqual(Tag.eof, lex.next().tag);

    // #importing should not match
    var lex2 = Lexer.init("#importing");
    try std.testing.expectEqual(Tag.invalid, lex2.next().tag);
}

test "lex hash_insert" {
    var lex = Lexer.init("#insert #run generate()");
    try std.testing.expectEqual(Tag.hash_insert, lex.next().tag);
    try std.testing.expectEqual(Tag.hash_run, lex.next().tag);
    try std.testing.expectEqual(Tag.identifier, lex.next().tag);

    // #inserting should not match
    var lex2 = Lexer.init("#inserting");
    try std.testing.expectEqual(Tag.invalid, lex2.next().tag);
}

test "lex hash_library" {
    var lex = Lexer.init("#library \"raylib\"");
    try std.testing.expectEqual(Tag.hash_library, lex.next().tag);
    try std.testing.expectEqual(Tag.string_literal, lex.next().tag);
    try std.testing.expectEqual(Tag.eof, lex.next().tag);

    var lex2 = Lexer.init("#librarypath");
    try std.testing.expectEqual(Tag.invalid, lex2.next().tag);
}

test "lex string" {
    var lex = Lexer.init("\"Hello\"");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.string_literal, tok.tag);
    try std.testing.expectEqualStrings("\"Hello\"", tok.slice("\"Hello\""));
}

test "lex multiline string" {
    const source: [:0]const u8 = "\"line1\nline2\nline3\"";
    var lex = Lexer.init(source);
    const tok = lex.next();
    try std.testing.expectEqual(Tag.string_literal, tok.tag);
    try std.testing.expectEqualStrings("\"line1\nline2\nline3\"", tok.slice(source));
}

test "lex #string heredoc" {
    const source: [:0]const u8 = "#string END\nhello world\nEND";
    var lex = Lexer.init(source);
    const tok = lex.next();
    try std.testing.expectEqual(Tag.raw_string_literal, tok.tag);
    try std.testing.expectEqualStrings("hello world\n", tok.slice(source));
}

test "lex #string heredoc multiline" {
    const source: [:0]const u8 = "#string GLSL\n#version 330\nvoid main() {}\nGLSL";
    var lex = Lexer.init(source);
    const tok = lex.next();
    try std.testing.expectEqual(Tag.raw_string_literal, tok.tag);
    try std.testing.expectEqualStrings("#version 330\nvoid main() {}\n", tok.slice(source));
}

test "lex #string heredoc followed by semicolon" {
    const source: [:0]const u8 = "#string END\ncontent\nEND;";
    var lex = Lexer.init(source);
    const tok = lex.next();
    try std.testing.expectEqual(Tag.raw_string_literal, tok.tag);
    try std.testing.expectEqualStrings("content\n", tok.slice(source));
    const semi = lex.next();
    try std.testing.expectEqual(Tag.semicolon, semi.tag);
}

test "lex hex literal" {
    var lex = Lexer.init("0xFF 0X1A");
    const tok1 = lex.next();
    try std.testing.expectEqual(Tag.int_literal, tok1.tag);
    try std.testing.expectEqualStrings("0xFF", tok1.slice("0xFF 0X1A"));
    const tok2 = lex.next();
    try std.testing.expectEqual(Tag.int_literal, tok2.tag);
    try std.testing.expectEqualStrings("0X1A", tok2.slice("0xFF 0X1A"));
}

test "lex binary literal" {
    var lex = Lexer.init("0b1010 0B110");
    const tok1 = lex.next();
    try std.testing.expectEqual(Tag.int_literal, tok1.tag);
    try std.testing.expectEqualStrings("0b1010", tok1.slice("0b1010 0B110"));
    const tok2 = lex.next();
    try std.testing.expectEqual(Tag.int_literal, tok2.tag);
    try std.testing.expectEqualStrings("0B110", tok2.slice("0b1010 0B110"));
}
