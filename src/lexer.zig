const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const getKeyword = @import("token.zig").getKeyword;
const token_list = @import("token_list.zig");
const TokenList = token_list.TokenList;
const Flags = token_list.Flags;
const Comment = token_list.Comment;

/// Count line starts after `from` up to and including `to`; the start of the
/// file counts as one line start.
fn lineStartsBetween(source: []const u8, from: u32, to: u32) u32 {
    const newlines: u32 = @intCast(std.mem.count(u8, source[from..to], "\n"));
    return newlines + @intFromBool(from == 0);
}

/// Only spaces/tabs lie between the previous LF (or the start of file) and
/// `offset`.
fn isLineLeading(source: []const u8, offset: u32) bool {
    var i = offset;
    while (i > 0) : (i -= 1) {
        const c = source[i - 1];
        if (c == '\n') break;
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// Tokenize `source` in one pass into a `TokenList`. Malformed input becomes
/// `.invalid` rows, exactly as the streaming scanner emits them; the only
/// error is OOM.
///
/// Every adjacency flag is computed from the emitted spans (`ends[i-1]` vs
/// the written start of row `i`), never from the scan cursor — after a
/// heredoc the cursor sits past the terminator while the token span ends at
/// the content, and the spans are what the whitespace rules read.
pub fn lex(allocator: Allocator, source: [:0]const u8) error{OutOfMemory}!TokenList {
    var tags: std.ArrayList(Tag) = .empty;
    errdefer tags.deinit(allocator);
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(allocator);
    var ends: std.ArrayList(u32) = .empty;
    errdefer ends.deinit(allocator);
    var flags: std.ArrayList(Flags) = .empty;
    errdefer flags.deinit(allocator);
    var depths: std.ArrayList(u32) = .empty;
    errdefer depths.deinit(allocator);
    var trivia_index: std.ArrayList(u32) = .empty;
    errdefer trivia_index.deinit(allocator);
    var comments: std.ArrayList(Comment) = .empty;
    errdefer comments.deinit(allocator);

    var lx = Lexer.init(source);
    // Saturating, so an unbalanced buffer — an editor's mid-edit source —
    // still yields a defined column.
    var depth: u32 = 0;
    while (true) {
        try trivia_index.append(allocator, @intCast(comments.items.len));
        const prev_end: u32 = if (ends.items.len == 0) 0 else ends.items[ends.items.len - 1];
        // Nearest preceding lexical item — the last comment row once one is
        // appended — for the blank_left counts.
        var item_end = prev_end;
        while (lx.nextComment()) |c| {
            try comments.append(allocator, .{
                .start = c.start,
                .end = c.end,
                .line_leading = isLineLeading(source, c.start),
                .blank_left = lineStartsBetween(source, item_end, c.start) >= 2,
            });
            item_end = c.end;
        }
        const tok = lx.lexToken();
        const ws = tok.loc.start - @intFromBool(tok.is_raw);
        const is_first = tags.items.len == 0;
        try tags.append(allocator, tok.tag);
        try starts.append(allocator, tok.loc.start);
        try ends.append(allocator, tok.loc.end);
        try flags.append(allocator, .{
            .glued_left = !is_first and prev_end == ws,
            .newline_left = is_first or std.mem.indexOfScalar(u8, source[prev_end..ws], '\n') != null,
            .blank_left = lineStartsBetween(source, item_end, ws) >= 2,
            .is_raw = tok.is_raw,
        });
        switch (tok.tag) {
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        }
        try depths.append(allocator, depth);
        switch (tok.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            else => {},
        }
        if (tok.tag == .eof) break;
    }
    try trivia_index.append(allocator, @intCast(comments.items.len));

    const tags_s = try tags.toOwnedSlice(allocator);
    errdefer allocator.free(tags_s);
    const starts_s = try starts.toOwnedSlice(allocator);
    errdefer allocator.free(starts_s);
    const ends_s = try ends.toOwnedSlice(allocator);
    errdefer allocator.free(ends_s);
    const flags_s = try flags.toOwnedSlice(allocator);
    errdefer allocator.free(flags_s);
    const depths_s = try depths.toOwnedSlice(allocator);
    errdefer allocator.free(depths_s);
    const trivia_s = try trivia_index.toOwnedSlice(allocator);
    errdefer allocator.free(trivia_s);
    const comments_s = try comments.toOwnedSlice(allocator);

    return .{
        .source = source,
        .tags = tags_s,
        .starts = starts_s,
        .ends = ends_s,
        .flags = flags_s,
        .depths = depths_s,
        .trivia_index = trivia_s,
        .comments = comments_s,
    };
}

pub const Lexer = struct {
    source: [:0]const u8,
    index: u32,

    fn init(source: [:0]const u8) Lexer {
        return .{ .source = source, .index = 0 };
    }

    /// Advance past whitespace up to the next `//` run or token start.
    /// Returns the comment's span — its `end` excludes a trailing CR, since
    /// the run stops only at LF — or null once at a token start.
    fn nextComment(self: *Lexer) ?struct { start: u32, end: u32 } {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.index += 1;
                continue;
            }
            if (c == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                const start = self.index;
                while (self.index < self.source.len and self.source[self.index] != '\n') {
                    self.index += 1;
                }
                var end = self.index;
                if (self.source[end - 1] == '\r') end -= 1;
                return .{ .start = start, .end = end };
            }
            break;
        }
        return null;
    }

    /// Scan one token; `self.index` is at a token start (trivia skipped).
    fn lexToken(self: *Lexer) Token {
        if (self.index >= self.source.len) {
            return self.makeToken(.eof, self.index, self.index);
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

        // Compiler-formed type name: `@Init`. The `@` is part of the name, so
        // the token spans it; the tag keeps it out of every identifier position.
        if (c == '@') {
            const id_start = start + 1;
            if (id_start < self.source.len and isIdentStart(self.source[id_start])) {
                self.index = id_start;
                var tok = self.lexIdentifier(id_start);
                tok.tag = .at_identifier;
                tok.loc.start = start;
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
                .{ "#identity", Tag.hash_identity },
                .{ "#expand", Tag.hash_expand },
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
                if (self.peek() == '-') {
                    self.index += 1;
                    return self.makeToken(.minus_minus, start, self.index);
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
