const std = @import("std");

/// Process escape sequences in a raw string literal.
pub fn unescapeString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, raw.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            result[j] = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '0' => 0,
                else => raw[i],
            };
        } else {
            result[j] = raw[i];
        }
        j += 1;
        i += 1;
    }
    return result[0..j];
}

/// Errors raised by `decodeCharLiteral` for a malformed `'...'` literal.
pub const CharLiteralError = error{
    Empty,
    TooManyCharacters,
    UnterminatedEscape,
    BadEscape,
    BadHexEscape,
    BadUnicodeEscape,
    CodePointOutOfRange,
    SurrogateCodePoint,
};

/// Decode the INNER body of a `'...'` char literal (the text between the
/// quotes, already stripped) into its integer code point.
///
/// Exactly one logical character is accepted: a single raw byte, one `\xNN`,
/// or one `\u{XXXX}`. Anything else (`''`, `'ab'`, a stray `\` at EOF, an
/// unknown escape, an overlong `\u{}` value, or a surrogate) is an error.
///
/// Note: a raw non-ASCII byte (e.g. the UTF-8 bytes of `'é'`) is accepted as
/// "one raw byte" only when the body is a single byte; a multi-byte raw
/// sequence is `TooManyCharacters`. `\u{...}` is the way to spell an
/// arbitrary Unicode scalar regardless of its UTF-8 length.
pub fn decodeCharLiteral(raw: []const u8) CharLiteralError!i64 {
    if (raw.len == 0) return error.Empty;

    // Escape sequence case.
    if (raw[0] == '\\') {
        if (raw.len < 2) return error.UnterminatedEscape;
        switch (raw[1]) {
            'n' => {
                if (raw.len != 2) return error.TooManyCharacters;
                return '\n';
            },
            't' => {
                if (raw.len != 2) return error.TooManyCharacters;
                return '\t';
            },
            'r' => {
                if (raw.len != 2) return error.TooManyCharacters;
                return '\r';
            },
            '\\' => {
                if (raw.len != 2) return error.TooManyCharacters;
                return '\\';
            },
            '\'' => {
                if (raw.len != 2) return error.TooManyCharacters;
                return '\'';
            },
            '0' => {
                if (raw.len != 2) return error.TooManyCharacters;
                return 0;
            },
            'x' => {
                // \xNN — exactly 1..2 hex digits, no trailing characters.
                if (raw.len < 3 or raw.len > 4) return error.BadHexEscape;
                const digits = raw[2..raw.len];
                const v = std.fmt.parseInt(u32, digits, 16) catch return error.BadHexEscape;
                // \xNN is a raw byte value; it must fit in u8.
                if (v > 0xFF) return error.BadHexEscape;
                return @intCast(v);
            },
            'u' => {
                // \u{XXXX} — 1..6 hex digits in braces.
                if (raw.len < 4 or raw[2] != '{') return error.BadUnicodeEscape;
                // Find the closing brace.
                var end: usize = 3;
                while (end < raw.len and raw[end] != '}') end += 1;
                if (end >= raw.len) return error.BadUnicodeEscape;
                if (end != raw.len - 1) return error.TooManyCharacters; // chars after '}'
                const digits = raw[3..end];
                if (digits.len == 0 or digits.len > 6) return error.BadUnicodeEscape;
                const v = std.fmt.parseInt(u32, digits, 16) catch return error.BadUnicodeEscape;
                if (v > 0x10FFFF) return error.CodePointOutOfRange;
                if (v >= 0xD800 and v <= 0xDFFF) return error.SurrogateCodePoint;
                return @intCast(v);
            },
            else => return error.BadEscape,
        }
    }

    // Raw byte(s) case: the body is a literal source character (no escape).
    // A single Unicode scalar may encode as 1–4 UTF-8 bytes, so decode the
    // whole body as UTF-8 and accept it iff it yields exactly one code point.
    // `''` (empty) and `'ab'`/`'éx'` (more than one scalar) reject; invalid
    // UTF-8 rejects as a bad escape.
    if (raw.len == 1) return @intCast(raw[0]); // fast path: ASCII / single byte
    const view = std.unicode.Utf8View.init(raw) catch return error.BadEscape;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return error.Empty;
    if (it.nextCodepoint() != null) return error.TooManyCharacters;
    if (cp > 0x10FFFF) return error.CodePointOutOfRange;
    if (cp >= 0xD800 and cp <= 0xDFFF) return error.SurrogateCodePoint;
    return @intCast(cp);
}

/// A short human-readable reason for a `CharLiteralError`, used by the
/// parser when surfacing `invalid char literal: <reason>`.
pub fn charLiteralReason(err: CharLiteralError) []const u8 {
    return switch (err) {
        error.Empty => "empty char literal",
        error.TooManyCharacters => "too many characters in char literal",
        error.UnterminatedEscape => "unterminated escape in char literal",
        error.BadEscape => "unknown escape sequence in char literal",
        error.BadHexEscape => "malformed \\xNN escape (expect 1-2 hex digits)",
        error.BadUnicodeEscape => "malformed \\u{...} escape (expect 1-6 hex digits in braces)",
        error.CodePointOutOfRange => "unicode code point out of range (max U+10FFFF)",
        error.SurrogateCodePoint => "unicode surrogate code points (U+D800..U+DFFF) are not allowed",
    };
}
