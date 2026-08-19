//! pkg_migrate — syntax-aware migration tool for sx packages.
//!
//! A build-wired executable over the compiler's own `TokenList`, so the
//! lexical surface it migrates against is the one the compiler enforces. Run
//! with:
//!
//!   zig build pkg-migrate -- <subcommand> [options] <paths...>
//!
//! Subcommands: insert-package, rewrite-imports, qualify, to-package-dir,
//! inventory. All mutating subcommands default to DRY-RUN (a unified-diff-
//! style preview; exit 1 if changes are pending) and only write under
//! --apply. See README.md next to this file.
//!
//! Never perform the import migration with blind
//! global substitutions — every rewrite below is occurrence-precise (exact
//! token spans) and fully reported.

const std = @import("std");
const sxlex = @import("sxlex");
const Tag = sxlex.token.Tag;
const TokenList = sxlex.token_list.TokenList;
const Index = sxlex.token_list.Index;
pub const LineIndex = @import("line_index.zig").LineIndex;

const usage_text =
    \\usage: pkg_migrate <subcommand> [options] <paths...>
    \\
    \\subcommands:
    \\  insert-package  --name <pkg> [--apply] <files/dirs...>
    \\      Insert `package <pkg>;` after each file's leading comment block.
    \\  rewrite-imports --map <file> [--apply] <files/dirs...>
    \\      Rewrite @import path strings per `old=new` mapping lines.
    \\  qualify         --map <file> [--apply] <files/dirs...>
    \\      Convert flat uses of mapped names to `alias.name` per
    \\      `name=alias` mapping lines. Never rewrites ambiguous names.
    \\  to-package-dir  --name <pkg> <files...>
    \\      Report (plan only) how a same-directory file set becomes a
    \\      package directory.
    \\  inventory       <dirs/files...>
    \\      D9 collision inventory: every use of `package`, `import`,
    \\      `private`, `intrinsic` as an ordinary identifier, with spans.
    \\
    \\options:
    \\  --apply   write changes (default is dry-run/check)
    \\  --check   explicit dry-run (the default)
    \\  --name    package name (insert-package, to-package-dir)
    \\  --map     mapping file (rewrite-imports: old=new; qualify: name=alias)
    \\
    \\exit codes: 0 = clean / applied; 1 = dry-run found pending changes;
    \\            2 = error (usage, IO, ambiguous mapping, package conflict)
    \\
;

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    var out = std.Io.Writer.Allocating.init(allocator);
    const code = run(allocator, io, args, &out.writer) catch |err| blk: {
        out.writer.print("error: {t}\n", .{err}) catch {};
        break :blk 2;
    };
    std.Io.File.stdout().writeStreamingAll(io, out.written()) catch {};
    std.process.exit(code);
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const [:0]const u8,
    w: *std.Io.Writer,
) !u8 {
    if (args.len < 2) {
        try w.writeAll(usage_text);
        return 2;
    }
    const sub = args[1];

    var apply = false;
    var name_opt: ?[]const u8 = null;
    var map_opt: ?[]const u8 = null;
    var paths: std.ArrayList([]const u8) = .empty;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--apply")) {
            apply = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            apply = false;
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) {
                try w.writeAll("error: --name requires a value\n");
                return 2;
            }
            name_opt = args[i];
        } else if (std.mem.eql(u8, a, "--map")) {
            i += 1;
            if (i >= args.len) {
                try w.writeAll("error: --map requires a value\n");
                return 2;
            }
            map_opt = args[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try w.writeAll(usage_text);
            return 0;
        } else if (std.mem.startsWith(u8, a, "--")) {
            try w.print("error: unknown option '{s}'\n", .{a});
            return 2;
        } else {
            try paths.append(allocator, a);
        }
    }

    if (std.mem.eql(u8, sub, "insert-package")) {
        return cmdInsertPackage(allocator, io, w, name_opt, apply, paths.items);
    } else if (std.mem.eql(u8, sub, "rewrite-imports")) {
        return cmdRewriteImports(allocator, io, w, map_opt, apply, paths.items);
    } else if (std.mem.eql(u8, sub, "qualify")) {
        return cmdQualify(allocator, io, w, map_opt, apply, paths.items);
    } else if (std.mem.eql(u8, sub, "to-package-dir")) {
        if (apply) {
            try w.writeAll("error: to-package-dir is report-only in P0.4 (no --apply)\n");
            return 2;
        }
        return cmdToPackageDir(allocator, io, w, name_opt, paths.items);
    } else if (std.mem.eql(u8, sub, "inventory")) {
        return cmdInventory(allocator, io, w, paths.items);
    } else if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        try w.writeAll(usage_text);
        return 0;
    }
    try w.print("error: unknown subcommand '{s}'\n\n", .{sub});
    try w.writeAll(usage_text);
    return 2;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const max_file_size = 64 * 1024 * 1024;

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(max_file_size));
    defer allocator.free(bytes);
    return allocator.dupeZ(u8, bytes);
}

/// Expand a mixed list of files and directories into a sorted list of `.sx`
/// file paths. Directories are walked recursively; `.git`, `zig-out`,
/// `.zig-cache`, and `.sx-tmp` subtrees are skipped. Sorting makes reports
/// deterministic (the std walker's order is undefined).
fn collectSxFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        const stat = std.Io.Dir.statFile(.cwd(), io, p, .{}) catch |err| {
            std.debug.print("pkg_migrate: cannot stat '{s}': {t}\n", .{ p, err });
            return err;
        };
        if (stat.kind == .directory) {
            var dir = try std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walkSelectively(allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind == .directory) {
                    if (std.mem.eql(u8, entry.basename, ".git") or
                        std.mem.eql(u8, entry.basename, "zig-out") or
                        std.mem.eql(u8, entry.basename, ".zig-cache") or
                        std.mem.eql(u8, entry.basename, ".sx-tmp"))
                    {
                        continue; // do not enter
                    }
                    try walker.enter(io, entry);
                    continue;
                }
                if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".sx")) {
                    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimTrailingSlash(p), entry.path });
                    try files.append(allocator, full);
                }
            }
        } else {
            try files.append(allocator, try allocator.dupe(u8, p));
        }
    }
    std.mem.sort([]const u8, files.items, {}, strLessThan);
    return files.toOwnedSlice(allocator);
}

fn trimTrailingSlash(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    return p[0..end];
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One occurrence-precise byte-span replacement. Edits within one file are
/// non-overlapping and sorted by `start`.
const Edit = struct {
    start: usize,
    end: usize, // exclusive; == start for a pure insertion
    replacement: []const u8,
};

fn applyEdits(allocator: std.mem.Allocator, source: []const u8, edits: []const Edit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (edits) |e| {
        std.debug.assert(e.start >= cursor);
        try out.appendSlice(allocator, source[cursor..e.start]);
        try out.appendSlice(allocator, e.replacement);
        cursor = e.end;
    }
    try out.appendSlice(allocator, source[cursor..]);
    return out.toOwnedSlice(allocator);
}

/// Unified-diff-style preview of `edits` against `source`. Each edit becomes
/// one hunk expanded to whole-line boundaries. Line numbers in the `+` header
/// account for lines added/removed by earlier hunks in the same file.
fn printDiff(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    path: []const u8,
    source: []const u8,
    edits: []const Edit,
) !void {
    if (edits.len == 0) return;
    const idx = try LineIndex.build(allocator, source);
    try w.print("--- a/{s}\n+++ b/{s}\n", .{ path, path });

    var line_delta: isize = 0;
    for (edits) |e| {
        // Expand [e.start, e.end) to whole lines of the source text.
        const first_line = idx.pos(e.start).line;
        const last_line = if (e.end > e.start) idx.pos(e.end - 1).line else first_line;
        const lo_start = idx.line_starts[first_line - 1];
        const lo_end = if (last_line < idx.line_starts.len)
            idx.line_starts[last_line]
        else
            source.len;

        const pure_insert_at_line_start = e.start == e.end and e.start == lo_start and
            e.replacement.len > 0 and e.replacement[e.replacement.len - 1] == '\n';

        if (pure_insert_at_line_start) {
            // Insertion between lines: no old lines consumed.
            const new_line_count = std.mem.count(u8, e.replacement, "\n");
            const after: usize = @intCast(@as(isize, @intCast(first_line)) + line_delta);
            try w.print("@@ -{d},0 +{d},{d} @@\n", .{ first_line - 1, after, new_line_count });
            var it = std.mem.splitScalar(u8, e.replacement, '\n');
            while (it.next()) |ln| {
                if (it.peek() == null and ln.len == 0) break; // trailing empty from final \n
                try w.print("+{s}\n", .{ln});
            }
            line_delta += @intCast(new_line_count);
            continue;
        }

        // Replacement hunk: old whole lines vs those lines with the edit
        // spliced in.
        const old_block = source[lo_start..lo_end];
        const new_block = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            source[lo_start..e.start], e.replacement, source[e.end..lo_end],
        });
        const old_n = countLines(old_block);
        const new_n = countLines(new_block);
        const new_first: usize = @intCast(@as(isize, @intCast(first_line)) + line_delta);
        try w.print("@@ -{d},{d} +{d},{d} @@\n", .{ first_line, old_n, new_first, new_n });
        try printBlockLines(w, old_block, '-');
        try printBlockLines(w, new_block, '+');
        line_delta += @as(isize, @intCast(new_n)) - @as(isize, @intCast(old_n));
    }
}

fn countLines(block: []const u8) usize {
    if (block.len == 0) return 0;
    var n = std.mem.count(u8, block, "\n");
    if (block[block.len - 1] != '\n') n += 1;
    return n;
}

fn printBlockLines(w: *std.Io.Writer, block: []const u8, sign: u8) !void {
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |ln| {
        if (it.peek() == null and ln.len == 0) break;
        try w.print("{c}{s}\n", .{ sign, ln });
    }
}

/// Parse a `key=value` mapping file. Blank lines and lines starting with `#`
/// are skipped. The same key appearing twice with the SAME value is
/// harmless; with a DIFFERENT value it is recorded in `ambiguous` (order of
/// first appearance) — callers must refuse to rewrite those keys.
const Mapping = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8),
    ambiguous: [][]const u8,
};

fn parseMapping(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Mapping {
    const text = try readFile(allocator, io, path);
    var entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var ambiguous: std.ArrayList([]const u8) = .empty;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.debug.print("pkg_migrate: {s}:{d}: mapping line has no '='\n", .{ path, line_no });
            return error.BadMappingLine;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or val.len == 0) {
            std.debug.print("pkg_migrate: {s}:{d}: empty key or value\n", .{ path, line_no });
            return error.BadMappingLine;
        }
        const gop = try entries.getOrPut(allocator, key);
        if (gop.found_existing) {
            if (!std.mem.eql(u8, gop.value_ptr.*, val)) {
                var already = false;
                for (ambiguous.items) |a| {
                    if (std.mem.eql(u8, a, key)) already = true;
                }
                if (!already) try ambiguous.append(allocator, key);
            }
        } else {
            gop.value_ptr.* = val;
        }
    }
    return .{ .entries = entries, .ambiguous = try ambiguous.toOwnedSlice(allocator) };
}

fn isValidIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, k| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or
            (k > 0 and c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

/// A bare word in the source. The compiler tags reserved spellings as their
/// own keyword (`private` -> `.kw_private`), and a migration that reads them
/// as anything but words would not see the collisions it exists to find.
pub fn isWord(tag: Tag) bool {
    return tag == .identifier or Tag.isKeyword(tag);
}

pub const Category = enum {
    member_access, // .name (also enum-literal position)
    decl_const, // name ::
    decl_local, // name :=
    typed_decl, // name :  (parameter, field, or typed local)
    call, // name(
    assign_or_field_init, // name =  (assignment or struct-literal field init)
    other_use,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .member_access => "member-access",
            .decl_const => "decl-const",
            .decl_local => "decl-local",
            .typed_decl => "typed-decl(param/field/local)",
            .call => "call",
            .assign_or_field_init => "assign-or-field-init",
            .other_use => "use",
        };
    }
};

pub fn classify(tl: TokenList, i: Index) Category {
    const p = tl.prev(i);
    if (p != i) switch (tl.tag(p)) {
        .dot, .question_dot => return .member_access,
        else => {},
    };
    switch (tl.tag(tl.next(i))) {
        .colon_colon => return .decl_const,
        .colon_equal => return .decl_local,
        .colon => return .typed_decl,
        .l_paren => return .call,
        .equal => return .assign_or_field_init,
        else => return .other_use,
    }
}

pub const Warning = struct {
    offset: u32,
    message: []const u8,
};

/// The malformed-literal message for an `.invalid` row, read off the source
/// spelling at `at`. Compiler `.invalid` rows carry no reason and most of them
/// are not literals at all — a lone `#`, a stray backtick or `@`, an unknown
/// byte — so anything but the five literal spellings warns about nothing.
pub fn literalWarning(source: []const u8, at: u32) ?[]const u8 {
    switch (source[at]) {
        '"' => return "unterminated string literal (rest of file skipped as literal)",
        '\'' => return "unterminated char literal (rest of file skipped as literal)",
        '@' => {},
        else => return null,
    }
    const kw = "@string";
    var j: usize = at;
    if (j + kw.len > source.len or !std.mem.eql(u8, source[j..][0..kw.len], kw)) return null;
    j += kw.len;
    if (j < source.len and isIdentContinue(source[j])) return null;
    while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
    if (j >= source.len or !isIdentStart(source[j])) return "@string without delimiter identifier";
    while (j < source.len and isIdentContinue(source[j])) j += 1;
    while (j < source.len and source[j] != '\n') j += 1;
    if (j >= source.len) return "unterminated @string heredoc";
    return "unterminated @string heredoc (rest of file skipped as literal)";
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

pub fn scanWarnings(allocator: std.mem.Allocator, tl: TokenList) ![]Warning {
    var out: std.ArrayList(Warning) = .empty;
    var i = tl.first();
    while (tl.tag(i) != .eof) : (i = tl.next(i)) {
        if (tl.tag(i) != .invalid) continue;
        const at = tl.start(i);
        if (literalWarning(tl.source, at)) |message| {
            try out.append(allocator, .{ .offset = at, .message = message });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn printScanWarnings(
    w: *std.Io.Writer,
    path: []const u8,
    idx: LineIndex,
    warnings: []const Warning,
) !void {
    for (warnings) |warn| {
        const p = idx.pos(warn.offset);
        try w.print("warning: {s}:{d}:{d}: {s}\n", .{ path, p.line, p.col, warn.message });
    }
}

/// Detect an existing leading `package <name>;` declaration: the first token is
/// the word `package`, followed by a word, followed by `;`. Returns the
/// declared name.
pub fn existingPackageDecl(tl: TokenList) ?[]const u8 {
    const a = tl.first();
    const b = tl.next(a);
    const c = tl.next(b);
    if (isWord(tl.tag(a)) and !tl.flagsOf(a).is_raw and std.mem.eql(u8, tl.slice(a), "package") and
        isWord(tl.tag(b)) and tl.tag(c) == .semicolon)
    {
        return tl.slice(b);
    }
    return null;
}

// ---------------------------------------------------------------------------
// insert-package
// ---------------------------------------------------------------------------

/// Insertion point for `package <name>;`: after the file's leading
/// header-comment block. The leading block is the maximal run of blank or
/// `//` lines at the top; the package line goes after the LAST BLANK LINE in
/// that run (so a comment run that directly abuts the first declaration is
/// treated as that declaration's doc comment and stays attached to it). A
/// file with no blank line in the leading run gets the package line at the
/// very top.
pub fn insertionOffset(source: []const u8) usize {
    var offset: usize = 0; // start of current line
    var insert_at: usize = 0; // start of line after the last blank leading line
    var i: usize = 0;
    while (i <= source.len) {
        // find end of line
        var j = i;
        while (j < source.len and source[j] != '\n') j += 1;
        const line = source[i..j];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const is_blank = trimmed.len == 0;
        const is_comment = trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/';
        if (!is_blank and !is_comment) break; // first code line ends the run
        if (j >= source.len) {
            // file is all comments/blanks
            if (is_blank) insert_at = source.len;
            break;
        }
        offset = j + 1;
        if (is_blank) insert_at = offset;
        i = offset;
    }
    return insert_at;
}

fn cmdInsertPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    name_opt: ?[]const u8,
    apply: bool,
    paths: []const []const u8,
) !u8 {
    const name = name_opt orelse {
        try w.writeAll("error: insert-package requires --name <pkg>\n");
        return 2;
    };
    if (!isValidIdent(name)) {
        try w.print("error: '{s}' is not a valid package identifier\n", .{name});
        return 2;
    }
    if (paths.len == 0) {
        try w.writeAll("error: no input files\n");
        return 2;
    }
    const files = try collectSxFiles(allocator, io, paths);

    var pending = false;
    var conflict = false;
    for (files) |path| {
        const source = try readFile(allocator, io, path);
        var tl = try sxlex.lexer.lex(allocator, source);
        defer tl.deinit(allocator);
        const idx = try LineIndex.build(allocator, source);
        try printScanWarnings(w, path, idx, try scanWarnings(allocator, tl));

        if (existingPackageDecl(tl)) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                try w.print("{s}: already declares `package {s};` — no change\n", .{ path, name });
            } else {
                try w.print("error: {s}: already declares `package {s};` (wanted `{s}`) — refusing\n", .{ path, existing, name });
                conflict = true;
            }
            continue;
        }

        const at = insertionOffset(source);
        var text: std.ArrayList(u8) = .empty;
        // Separate from an abutting comment line above.
        if (at > 0) {
            const prev_line_end = at - 1; // at is a line start; byte before is '\n'
            _ = prev_line_end;
            // find previous line's content
            var ls = at - 1;
            while (ls > 0 and source[ls - 1] != '\n') ls -= 1;
            const prev_line = std.mem.trim(u8, source[ls .. at - 1], " \t\r");
            if (prev_line.len != 0) try text.append(allocator, '\n');
        }
        try text.appendSlice(allocator, "package ");
        try text.appendSlice(allocator, name);
        try text.appendSlice(allocator, ";\n");
        // Separate from following code/comment line, if any.
        if (at < source.len) {
            var le = at;
            while (le < source.len and source[le] != '\n') le += 1;
            const next_line = std.mem.trim(u8, source[at..le], " \t\r");
            if (next_line.len != 0) try text.append(allocator, '\n');
        }

        const edits = [_]Edit{.{ .start = at, .end = at, .replacement = text.items }};
        pending = true;
        if (apply) {
            const new_source = try applyEdits(allocator, source, &edits);
            try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = new_source });
            const p = idx.pos(at);
            try w.print("{s}:{d}: inserted `package {s};`\n", .{ path, p.line, name });
        } else {
            try printDiff(allocator, w, path, source, &edits);
        }
    }
    if (conflict) return 2;
    if (!apply and pending) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// rewrite-imports
// ---------------------------------------------------------------------------

fn cmdRewriteImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    map_opt: ?[]const u8,
    apply: bool,
    paths: []const []const u8,
) !u8 {
    const map_path = map_opt orelse {
        try w.writeAll("error: rewrite-imports requires --map <file> (lines: old=new)\n");
        return 2;
    };
    if (paths.len == 0) {
        try w.writeAll("error: no input files\n");
        return 2;
    }
    const mapping = try parseMapping(allocator, io, map_path);
    if (mapping.ambiguous.len != 0) {
        for (mapping.ambiguous) |k| {
            try w.print("error: AMBIGUOUS mapping: '{s}' maps to multiple targets in {s}\n", .{ k, map_path });
        }
        try w.writeAll("refusing to rewrite anything until the mapping is unambiguous\n");
        return 2;
    }
    const files = try collectSxFiles(allocator, io, paths);

    var pending = false;
    for (files) |path| {
        const source = try readFile(allocator, io, path);
        var tl = try sxlex.lexer.lex(allocator, source);
        defer tl.deinit(allocator);
        const idx = try LineIndex.build(allocator, source);
        try printScanWarnings(w, path, idx, try scanWarnings(allocator, tl));

        var edits: std.ArrayList(Edit) = .empty;
        var ti = tl.first();
        while (tl.tag(ti) != .eof) : (ti = tl.next(ti)) {
            if (tl.tag(ti) != .at_import) continue;
            const n = tl.next(ti);
            if (tl.tag(n) != .string_literal) continue;
            const inner = source[tl.start(n) + 1 .. tl.end(n) - 1];
            const new_path = mapping.entries.get(inner) orelse continue;
            const p = idx.pos(tl.start(n));
            try w.print("{s}:{d}:{d}: @import \"{s}\" -> \"{s}\"\n", .{ path, p.line, p.col, inner, new_path });
            try edits.append(allocator, .{
                .start = tl.start(n) + 1,
                .end = tl.end(n) - 1,
                .replacement = new_path,
            });
        }
        if (edits.items.len == 0) continue;
        pending = true;
        if (apply) {
            const new_source = try applyEdits(allocator, source, edits.items);
            try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = new_source });
            try w.print("{s}: rewrote {d} import(s)\n", .{ path, edits.items.len });
        } else {
            try printDiff(allocator, w, path, source, edits.items);
        }
    }
    if (!apply and pending) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// qualify
// ---------------------------------------------------------------------------

fn cmdQualify(
    allocator: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    map_opt: ?[]const u8,
    apply: bool,
    paths: []const []const u8,
) !u8 {
    const map_path = map_opt orelse {
        try w.writeAll("error: qualify requires --map <file> (lines: name=alias)\n");
        return 2;
    };
    if (paths.len == 0) {
        try w.writeAll("error: no input files\n");
        return 2;
    }
    const mapping = try parseMapping(allocator, io, map_path);
    if (mapping.ambiguous.len != 0) {
        for (mapping.ambiguous) |k| {
            try w.print("error: AMBIGUOUS name: '{s}' is provided by multiple sources in {s}\n", .{ k, map_path });
        }
        try w.writeAll("refusing to rewrite anything: resolve the ambiguity in the mapping first\n");
        return 2;
    }
    for (mapping.entries.keys()) |k| {
        if (!isValidIdent(k)) {
            try w.print("error: mapping key '{s}' is not a valid identifier\n", .{k});
            return 2;
        }
    }
    const files = try collectSxFiles(allocator, io, paths);

    var pending = false;
    for (files) |path| {
        const source = try readFile(allocator, io, path);
        var tl = try sxlex.lexer.lex(allocator, source);
        defer tl.deinit(allocator);
        const idx = try LineIndex.build(allocator, source);
        try printScanWarnings(w, path, idx, try scanWarnings(allocator, tl));

        // Pass 1 (conservative shadow guard): if a mapped name appears in a
        // declaration position ANYWHERE in this file (name ::, name :=,
        // name :), the file may declare/shadow it — a token scanner cannot
        // scope-resolve, so we refuse to rewrite that name in this whole
        // file and report every occurrence instead of guessing.
        var declared_here: std.StringArrayHashMapUnmanaged(void) = .empty;
        var ti = tl.first();
        while (tl.tag(ti) != .eof) : (ti = tl.next(ti)) {
            if (!isWord(tl.tag(ti))) continue;
            const text = tl.slice(ti);
            if (mapping.entries.get(text) == null) continue;
            switch (classify(tl, ti)) {
                .decl_const, .decl_local, .typed_decl => _ = try declared_here.getOrPut(allocator, text),
                else => {},
            }
        }

        // Pass 2: rewrite clear use positions; report every skip.
        var edits: std.ArrayList(Edit) = .empty;
        ti = tl.first();
        while (tl.tag(ti) != .eof) : (ti = tl.next(ti)) {
            if (!isWord(tl.tag(ti))) continue;
            const text = tl.slice(ti);
            const alias = mapping.entries.get(text) orelse continue;
            const p = idx.pos(tl.start(ti));
            const cat = classify(tl, ti);
            if (declared_here.get(text) != null) {
                try w.print("{s}:{d}:{d}: SKIP '{s}' [{s}]: declared in this file (possible shadow) — not rewriting any occurrence\n", .{ path, p.line, p.col, text, cat.label() });
                continue;
            }
            if (tl.flagsOf(ti).is_raw) {
                try w.print("{s}:{d}:{d}: SKIP '`{s}' [{s}]: backtick-escaped identifier\n", .{ path, p.line, p.col, text, cat.label() });
                continue;
            }
            switch (cat) {
                .member_access => {
                    // already qualified (x.name) or an enum-literal (.name);
                    // silent — this is the expected end state, not a finding
                },
                .assign_or_field_init => {
                    try w.print("{s}:{d}:{d}: SKIP '{s}' [{s}]: ambiguous position (struct-literal field init or assignment) — not rewriting\n", .{ path, p.line, p.col, text, cat.label() });
                },
                .decl_const, .decl_local, .typed_decl => unreachable, // handled by declared_here
                .call, .other_use => {
                    const repl = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ alias, text });
                    try w.print("{s}:{d}:{d}: '{s}' -> '{s}' [{s}]\n", .{ path, p.line, p.col, text, repl, cat.label() });
                    try edits.append(allocator, .{ .start = tl.start(ti), .end = tl.end(ti), .replacement = repl });
                },
            }
        }
        if (edits.items.len == 0) continue;
        pending = true;
        if (apply) {
            const new_source = try applyEdits(allocator, source, edits.items);
            try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = new_source });
            try w.print("{s}: qualified {d} occurrence(s)\n", .{ path, edits.items.len });
        } else {
            try printDiff(allocator, w, path, source, edits.items);
        }
    }
    if (!apply and pending) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// to-package-dir (report-only)
// ---------------------------------------------------------------------------

fn cmdToPackageDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    name_opt: ?[]const u8,
    paths: []const []const u8,
) !u8 {
    const name = name_opt orelse {
        try w.writeAll("error: to-package-dir requires --name <pkg>\n");
        return 2;
    };
    if (!isValidIdent(name)) {
        try w.print("error: '{s}' is not a valid package identifier\n", .{name});
        return 2;
    }
    if (paths.len == 0) {
        try w.writeAll("error: no input files\n");
        return 2;
    }

    // All inputs must be .sx files in one directory.
    var dir_name: ?[]const u8 = null;
    for (paths) |p| {
        if (!std.mem.endsWith(u8, p, ".sx")) {
            try w.print("error: '{s}' is not a .sx file\n", .{p});
            return 2;
        }
        const d = std.fs.path.dirname(p) orelse ".";
        if (dir_name) |prev| {
            if (!std.mem.eql(u8, prev, d)) {
                try w.print("error: files span multiple directories ('{s}' vs '{s}') — one package is one directory\n", .{ prev, d });
                return 2;
            }
        } else dir_name = d;
    }

    try w.print("plan: directory '{s}' becomes package '{s}' ({d} file(s))\n", .{ dir_name.?, name, paths.len });
    var changes: usize = 0;
    var conflict = false;
    for (paths) |path| {
        const source = try readFile(allocator, io, path);
        var tl = try sxlex.lexer.lex(allocator, source);
        defer tl.deinit(allocator);
        const idx = try LineIndex.build(allocator, source);
        try printScanWarnings(w, path, idx, try scanWarnings(allocator, tl));
        if (existingPackageDecl(tl)) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                try w.print("  {s}: already declares `package {s};` — no change\n", .{ path, name });
            } else {
                try w.print("  {s}: CONFLICT — declares `package {s};`, wanted `{s}`\n", .{ path, existing, name });
                conflict = true;
            }
        } else {
            const at = insertionOffset(source);
            const p = idx.pos(at);
            try w.print("  {s}:{d}: would insert `package {s};`\n", .{ path, p.line, name });
            changes += 1;
        }
    }
    try w.print("plan: {d} file(s) would change; apply via: pkg_migrate insert-package --name {s} --apply <files>\n", .{ changes, name });
    if (conflict) return 2;
    if (changes > 0) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// inventory (the collision inventory)
// ---------------------------------------------------------------------------

const d9_words = [_][]const u8{ "package", "import", "private", "intrinsic" };

fn cmdInventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    paths: []const []const u8,
) !u8 {
    if (paths.len == 0) {
        try w.writeAll("error: no input paths\n");
        return 2;
    }
    const files = try collectSxFiles(allocator, io, paths);

    var per_word = [_]usize{0} ** d9_words.len;
    var per_cat: [d9_words.len][std.enums.values(Category).len]usize =
        .{.{0} ** std.enums.values(Category).len} ** d9_words.len;
    var raw_count: usize = 0;
    var total: usize = 0;
    var files_with_hits: usize = 0;
    var warning_count: usize = 0;

    try w.writeAll("== D9 collision inventory: `package` / `import` / `private` / `intrinsic` as ordinary identifiers ==\n");
    try w.writeAll("(comments, string/char literals, and @string heredocs excluded by the scanner)\n\n");

    for (files) |path| {
        const source = try readFile(allocator, io, path);
        var tl = try sxlex.lexer.lex(allocator, source);
        defer tl.deinit(allocator);
        const idx = try LineIndex.build(allocator, source);
        var file_hits: usize = 0;
        var ti = tl.first();
        while (tl.tag(ti) != .eof) : (ti = tl.next(ti)) {
            if (!isWord(tl.tag(ti))) continue;
            const text = tl.slice(ti);
            const wi = for (d9_words, 0..) |word, k| {
                if (std.mem.eql(u8, text, word)) break k;
            } else continue;
            const cat = classify(tl, ti);
            const p = idx.pos(tl.start(ti));
            const is_raw = tl.flagsOf(ti).is_raw;
            const line_text = std.mem.trim(u8, idx.lineText(source, p.line), " \t");
            try w.print("{s}:{d}:{d}: {s} [{s}]{s} | {s}\n", .{
                path,                              p.line, p.col, text, cat.label(),
                if (is_raw) " (backticked)" else "", line_text,
            });
            per_word[wi] += 1;
            per_cat[wi][@intFromEnum(cat)] += 1;
            if (is_raw) raw_count += 1;
            total += 1;
            file_hits += 1;
        }
        if (file_hits > 0) files_with_hits += 1;
        for (try scanWarnings(allocator, tl)) |warn| {
            const p = idx.pos(warn.offset);
            try w.print("scan-warning: {s}:{d}:{d}: {s}\n", .{ path, p.line, p.col, warn.message });
            warning_count += 1;
        }
    }

    try w.writeAll("\n== summary ==\n");
    for (d9_words, 0..) |word, k| {
        try w.print("{s}: {d}\n", .{ word, per_word[k] });
        for (std.enums.values(Category)) |cat| {
            const n = per_cat[k][@intFromEnum(cat)];
            if (n != 0) try w.print("  {s}: {d}\n", .{ cat.label(), n });
        }
    }
    try w.print("total identifier hits: {d} in {d} file(s) (scanned {d} .sx file(s))\n", .{ total, files_with_hits, files.len });
    if (raw_count != 0) try w.print("backticked (already escape-protected): {d}\n", .{raw_count});
    if (warning_count != 0) try w.print("scan warnings: {d}\n", .{warning_count});
    return 0;
}
