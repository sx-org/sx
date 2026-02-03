//! Minimal syntax-aware scanner for sx source, dedicated to the pkg_migrate
//! tool (P0.4). It is NOT the compiler lexer — it cannot be, because this tool
//! is deliberately unwired from build.zig — but it mirrors the exact lexical
//! surface of `src/lexer.zig` that matters for migration correctness:
//!
//!   - `//` line comments (sx has no block comments) — emitted as tokens so
//!     top-of-file structure ("leading comment block") is recoverable,
//!   - `"..."` string literals with `\` escape skipping,
//!   - `'...'` char literals with `\` escape skipping,
//!   - backtick raw identifiers (`` `name ``) — emitted as identifiers with
//!     `is_raw = true`,
//!   - `#string DELIM ... DELIM` heredocs — the whole body is one opaque
//!     token (this is what keeps `package="{}"` inside the Android manifest
//!     heredocs in `library/modules/platform/bundle.sx` from counting),
//!   - WHITELISTED `#word` directives (`#import`, `#builtin`, ... — the exact
//!     list the real lexer recognizes; see `directive_whitelist` below). A
//!     non-whitelisted `#word` (e.g. `#private`) is NOT swallowed as a
//!     directive: like the real lexer, the `#` is emitted alone and `word`
//!     lexes as an ordinary identifier — so it stays visible to the D9
//!     inventory and to qualify/rewrite logic,
//!   - identifiers ([A-Za-z_][A-Za-z0-9_]*) and numbers terminated by the
//!     real lexer's numeric grammar (so `0x1f` never yields a phantom
//!     identifier `x1f`, and `1package` DOES expose the identifier `package`
//!     exactly as the compiler would see it),
//!   - the multi-byte punctuation the classifiers care about: `::`, `:=`,
//!     `==`, `=>`.
//!
//! A word inside a comment, string, char literal, or heredoc can therefore
//! never surface as an identifier token — which is the entire point.

const std = @import("std");

pub const TokenKind = enum {
    identifier,
    string, // "..." including quotes
    char, // '...'
    heredoc, // #string DELIM ... DELIM, whole span
    comment, // // to end of line (newline excluded)
    directive, // #import, #run, ...
    number,
    punct, // operators / separators; text via slice()
    invalid, // unterminated string/char/heredoc
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    start: usize, // byte offset, inclusive
    end: usize, // byte offset, exclusive
    is_raw: bool = false, // backtick-escaped identifier

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Warning = struct {
    offset: usize,
    message: []const u8, // static string
};

pub const ScanResult = struct {
    tokens: []Token,
    warnings: []Warning,
};

/// The real lexer's directive whitelist, copied VERBATIM from the
/// `directives` table in `src/lexer.zig` (the `if (c == '#')` branch,
/// currently src/lexer.zig:91-125), plus the special-cased `#string` heredoc
/// keyword handled separately in `scan` below.
///
/// KEEP IN SYNC with src/lexer.zig: if a directive is added to or removed
/// from the compiler's lexer, mirror it here. The real lexer recognizes ONLY
/// these `#word` forms; for any other `#word` it emits an invalid `#` token
/// and then lexes `word` as an ordinary identifier. The scanner mirrors that
/// exactly so a hypothetical `#private` / `#package` in source surfaces the
/// identifiers `private` / `package` — visible to the D9 inventory — instead
/// of being silently swallowed as one unknown-directive token.
const directive_whitelist = [_][]const u8{
    "#import",
    "#insert",
    "#run",
    "#error",
    "#builtin",
    "#library",
    "#framework",
    "#using",
    "#include",
    "#source",
    "#define",
    "#flags",
    "#inline",
    "#objc_call",
    "#jni_call",
    "#jni_static_call",
    "#jni_class",
    "#jni_interface",
    "#objc_class",
    "#objc_protocol",
    "#swift_class",
    "#swift_struct",
    "#swift_protocol",
    "#extends",
    "#implements",
    "#jni_method_descriptor",
    "#jni_env",
    "#jni_main",
    "#selector",
    "#property",
    "#get",
    "#set",
    "#caller_location",
};

fn isWhitelistedDirective(word: []const u8) bool {
    // Exact match against the maximal `#`+ident-continue word is equivalent
    // to the real lexer's prefix-plus-boundary check: the lexer requires a
    // non-ident-continue byte right after the keyword, i.e. the maximal word
    // equals the keyword.
    for (directive_whitelist) |d| {
        if (std.mem.eql(u8, word, d)) return true;
    }
    return false;
}

/// Tokenize `source`. Never fails on malformed input: unterminated literals
/// become `.invalid` tokens that consume to EOF (mirroring src/lexer.zig) and
/// produce a warning, so deliberately-broken fixtures under issues/ still scan.
pub fn scan(allocator: std.mem.Allocator, source: []const u8) !ScanResult {
    var tokens: std.ArrayList(Token) = .empty;
    var warnings: std.ArrayList(Warning) = .empty;

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];

        // Whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }

        // Line comment
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            const start = i;
            while (i < source.len and source[i] != '\n') i += 1;
            try tokens.append(allocator, .{ .kind = .comment, .start = start, .end = i });
            continue;
        }

        // String literal
        if (c == '"') {
            const start = i;
            i += 1;
            var terminated = false;
            while (i < source.len) {
                const ch = source[i];
                if (ch == '"') {
                    i += 1;
                    terminated = true;
                    break;
                }
                if (ch == '\\') i += 1; // skip escape introducer
                i += 1;
            }
            if (terminated) {
                try tokens.append(allocator, .{ .kind = .string, .start = start, .end = i });
            } else {
                try tokens.append(allocator, .{ .kind = .invalid, .start = start, .end = i });
                try warnings.append(allocator, .{ .offset = start, .message = "unterminated string literal (rest of file skipped as literal)" });
            }
            continue;
        }

        // Char literal
        if (c == '\'') {
            const start = i;
            i += 1;
            var terminated = false;
            while (i < source.len) {
                const ch = source[i];
                if (ch == '\'') {
                    i += 1;
                    terminated = true;
                    break;
                }
                if (ch == '\\') i += 1;
                i += 1;
            }
            if (terminated) {
                try tokens.append(allocator, .{ .kind = .char, .start = start, .end = i });
            } else {
                try tokens.append(allocator, .{ .kind = .invalid, .start = start, .end = i });
                try warnings.append(allocator, .{ .offset = start, .message = "unterminated char literal (rest of file skipped as literal)" });
            }
            continue;
        }

        // Backtick raw identifier
        if (c == '`') {
            if (i + 1 < source.len and isIdentStart(source[i + 1])) {
                const id_start = i + 1;
                var j = id_start;
                while (j < source.len and isIdentContinue(source[j])) j += 1;
                // Span excludes the backtick, matching src/lexer.zig, so the
                // token text is the bare name.
                try tokens.append(allocator, .{ .kind = .identifier, .start = id_start, .end = j, .is_raw = true });
                i = j;
            } else {
                try tokens.append(allocator, .{ .kind = .punct, .start = i, .end = i + 1 });
                i += 1;
            }
            continue;
        }

        // Directives, including the #string heredoc
        if (c == '#') {
            const start = i;
            var j = i + 1;
            while (j < source.len and isIdentContinue(source[j])) j += 1;
            const word = source[start..j];
            if (std.mem.eql(u8, word, "#string")) {
                // Heredoc: skip spaces/tabs, read delimiter identifier, skip
                // rest of line, then scan lines until the delimiter appears
                // at column 0 (exactly src/lexer.zig's lexHeredoc).
                i = j;
                while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
                if (i >= source.len or !isIdentStart(source[i])) {
                    try tokens.append(allocator, .{ .kind = .invalid, .start = start, .end = i });
                    try warnings.append(allocator, .{ .offset = start, .message = "#string without delimiter identifier" });
                    continue;
                }
                const delim_start = i;
                while (i < source.len and isIdentContinue(source[i])) i += 1;
                const delimiter = source[delim_start..i];
                while (i < source.len and source[i] != '\n') i += 1;
                if (i >= source.len) {
                    try tokens.append(allocator, .{ .kind = .invalid, .start = start, .end = i });
                    try warnings.append(allocator, .{ .offset = start, .message = "unterminated #string heredoc" });
                    continue;
                }
                i += 1; // skip newline
                var terminated = false;
                while (i < source.len) {
                    const line_start = i;
                    if (line_start + delimiter.len <= source.len and
                        std.mem.eql(u8, source[line_start .. line_start + delimiter.len], delimiter) and
                        (line_start + delimiter.len >= source.len or
                            !isIdentContinue(source[line_start + delimiter.len])))
                    {
                        i = line_start + delimiter.len;
                        terminated = true;
                        break;
                    }
                    while (i < source.len and source[i] != '\n') i += 1;
                    if (i < source.len) i += 1;
                }
                if (terminated) {
                    try tokens.append(allocator, .{ .kind = .heredoc, .start = start, .end = i });
                } else {
                    try tokens.append(allocator, .{ .kind = .invalid, .start = start, .end = i });
                    try warnings.append(allocator, .{ .offset = start, .message = "unterminated #string heredoc (rest of file skipped as literal)" });
                }
                continue;
            }
            if (isWhitelistedDirective(word)) {
                try tokens.append(allocator, .{ .kind = .directive, .start = start, .end = j });
                i = j;
                continue;
            }
            // Unknown `#word`: mirror src/lexer.zig — the `#` alone is one
            // token and `word` lexes as an ordinary identifier on the next
            // iteration (the real lexer tags the lone `#` `.invalid`; we use
            // `.punct` since the scanner reserves `.invalid` for
            // unterminated literals — either way the following word is a
            // plain identifier, which is what inventory/qualify must see).
            try tokens.append(allocator, .{ .kind = .punct, .start = start, .end = start + 1 });
            i = start + 1;
            continue;
        }

        // Numbers — mirror src/lexer.zig's lexNumber (currently
        // src/lexer.zig:339) exactly: the accept-set is chosen by the
        // numeric grammar (0x/0X hex, 0b/0B binary, 0o/0O octal, otherwise
        // decimal with an optional `.digits` fraction; `_` is a separator in
        // every base), NOT by identifier-continue. Any tail byte the real
        // lexer would not accept is left for the next token, so whatever the
        // compiler would expose as an identifier the scanner exposes too:
        // `1package` yields identifier `package`, `0xg` yields `g`. Note the
        // real lexer has NO exponent grammar — `1e9` is int `1` followed by
        // identifier `e9` — and the scanner deliberately matches that.
        if (isDigit(c)) {
            const start = i;
            i += 1;
            var prefixed = false;
            if (c == '0' and i < source.len) {
                const prefix = source[i];
                if (prefix == 'x' or prefix == 'X') {
                    prefixed = true;
                    i += 1; // skip 'x'/'X'
                    while (i < source.len and (isHexDigit(source[i]) or source[i] == '_')) i += 1;
                } else if (prefix == 'b' or prefix == 'B') {
                    prefixed = true;
                    i += 1; // skip 'b'/'B'
                    while (i < source.len and (source[i] == '0' or source[i] == '1' or source[i] == '_')) i += 1;
                } else if (prefix == 'o' or prefix == 'O') {
                    prefixed = true;
                    i += 1; // skip 'o'/'O'
                    while (i < source.len and ((source[i] >= '0' and source[i] <= '7') or source[i] == '_')) i += 1;
                }
            }
            if (!prefixed) {
                while (i < source.len and (isDigit(source[i]) or source[i] == '_')) i += 1;
                // Float: '.' must be followed by a REAL digit (not
                // `.identifier`, and not `_`), same look-ahead as the lexer.
                if (i < source.len and source[i] == '.' and
                    i + 1 < source.len and isDigit(source[i + 1]))
                {
                    i += 1; // skip '.'
                    while (i < source.len and (isDigit(source[i]) or source[i] == '_')) i += 1;
                }
            }
            try tokens.append(allocator, .{ .kind = .number, .start = start, .end = i });
            continue;
        }

        // Identifiers
        if (isIdentStart(c)) {
            const start = i;
            while (i < source.len and isIdentContinue(source[i])) i += 1;
            try tokens.append(allocator, .{ .kind = .identifier, .start = start, .end = i });
            continue;
        }

        // Multi-byte punctuation the classifiers rely on.
        if (i + 1 < source.len) {
            const two = source[i .. i + 2];
            if (std.mem.eql(u8, two, "::") or std.mem.eql(u8, two, ":=") or
                std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "=>"))
            {
                try tokens.append(allocator, .{ .kind = .punct, .start = i, .end = i + 2 });
                i += 2;
                continue;
            }
        }

        try tokens.append(allocator, .{ .kind = .punct, .start = i, .end = i + 1 });
        i += 1;
    }

    try tokens.append(allocator, .{ .kind = .eof, .start = source.len, .end = source.len });
    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

/// Byte-offset -> 1-based line/col (col counted in bytes).
pub const LineIndex = struct {
    /// Byte offset of the start of each line (line_starts[0] == 0).
    line_starts: []usize,

    pub fn build(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var starts: std.ArrayList(usize) = .empty;
        try starts.append(allocator, 0);
        for (source, 0..) |c, idx| {
            if (c == '\n') try starts.append(allocator, idx + 1);
        }
        return .{ .line_starts = try starts.toOwnedSlice(allocator) };
    }

    pub const Pos = struct { line: usize, col: usize };

    pub fn pos(self: LineIndex, offset: usize) Pos {
        // Binary search for the last line start <= offset.
        var lo: usize = 0;
        var hi: usize = self.line_starts.len; // exclusive
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= offset) lo = mid else hi = mid;
        }
        return .{ .line = lo + 1, .col = offset - self.line_starts[lo] + 1 };
    }

    /// The full text of the (1-based) line containing `offset`, newline
    /// excluded.
    pub fn lineText(self: LineIndex, source: []const u8, line: usize) []const u8 {
        const start = self.line_starts[line - 1];
        var end = if (line < self.line_starts.len) self.line_starts[line] else source.len;
        while (end > start and (source[end - 1] == '\n' or source[end - 1] == '\r')) end -= 1;
        return source[start..end];
    }
};
