const std = @import("std");
const Span = @import("ast.zig").Span;

pub const Level = enum {
    err,
    warn,
    note,
    help,
};

pub const RenderStyle = enum {
    compact,
    extended,
};

pub const SourceLoc = struct {
    line: u32,
    col: u32,

    pub fn compute(source: []const u8, byte_offset: u32) SourceLoc {
        var line: u32 = 1;
        var col: u32 = 1;
        const end = @min(byte_offset, @as(u32, @intCast(source.len)));
        for (source[0..end]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }
};

/// The whole source line containing `byte_offset` (no trailing newline). Empty
/// when `source` is empty. Used to embed the offending line in a trace `Frame`.
pub fn lineAt(source: []const u8, byte_offset: u32) []const u8 {
    if (source.len == 0) return source;
    const at = @min(byte_offset, @as(u32, @intCast(source.len)));
    var start: usize = at;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    var end: usize = at;
    while (end < source.len and source[end] != '\n') end += 1;
    return source[start..end];
}

pub const LineInfo = struct {
    line_num: u32,
    text: []const u8,
};

pub const ContextLines = struct {
    lines: []LineInfo,
    start_col: u32,
    end_col: u32,

    pub fn deinit(self: *ContextLines, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
    }
};

pub fn extractContext(
    allocator: std.mem.Allocator,
    source: []const u8,
    span: Span,
) !ContextLines {
    const source_len: u32 = @intCast(source.len);
    const start = @min(span.start, source_len);
    const end = @max(start, @min(span.end, source_len));

    var line_num: u32 = 1;
    var line_start: u32 = 0;
    var i: u32 = 0;
    while (i < start) : (i += 1) {
        if (source[i] == '\n') {
            line_num += 1;
            line_start = i + 1;
        }
    }

    const start_col = (start - line_start) + 1;

    var lines: std.ArrayList(LineInfo) = .empty;
    defer lines.deinit(allocator);

    var cur_line_num = line_num;
    var cur_line_start = line_start;

    while (true) {
        var cur_line_end = cur_line_start;
        while (cur_line_end < source_len and source[cur_line_end] != '\n') : (cur_line_end += 1) {}

        try lines.append(allocator, .{
            .line_num = cur_line_num,
            .text = source[cur_line_start..cur_line_end],
        });

        if (end <= cur_line_end) {
            const end_col = (end - cur_line_start) + 1;
            const owned = try lines.toOwnedSlice(allocator);
            return ContextLines{
                .lines = owned,
                .start_col = start_col,
                .end_col = end_col,
            };
        }

        cur_line_num += 1;
        cur_line_start = cur_line_end + 1;
    }
}

pub const Diagnostic = struct {
    level: Level,
    message: []const u8,
    span: ?Span,
    source_file: ?[]const u8 = null,

    /// Index into `DiagnosticList.items` of the primary `err`/`warn` this
    /// note/help is bundled under. `null` for a standalone primary.
    primary: ?usize = null,

    /// For a `.help`: the suggested replacement source shown on the excerpt
    /// line in place of the original code. `null` renders the help as a bare
    /// suggestion line with no code block.
    fix_code: ?[]const u8 = null,
};

pub const DiagnosticList = struct {
    items: std.ArrayList(Diagnostic) = .empty,
    allocator: std.mem.Allocator,
    source: []const u8,
    file_name: []const u8,
    current_source_file: ?[]const u8 = null,
    import_sources: ?*const std.StringHashMap([:0]const u8) = null,
    render_style: RenderStyle = .extended,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) DiagnosticList {
        return .{
            .allocator = allocator,
            .source = source,
            .file_name = file_name,
        };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *DiagnosticList, level: Level, message: []const u8, span: ?Span) void {
        _ = self.addId(level, message, span);
    }

    /// Append a primary diagnostic, returning its index in `items`. The index
    /// is the handle passed to `addNote` / `addHelp` to bundle related
    /// messages under it. On a deduplicated hit the existing index is
    /// returned, so bundling still attaches to the surviving primary.
    pub fn addId(self: *DiagnosticList, level: Level, message: []const u8, span: ?Span) usize {
        // Deduplicate: skip if same level+span+message already exists
        for (self.items.items, 0..) |d, i| {
            if (d.level == level and std.mem.eql(u8, d.message, message)) {
                const a = d.span orelse continue;
                const b = span orelse continue;
                if (a.start == b.start and a.end == b.end) return i;
            }
        }
        const idx = self.items.items.len;
        self.items.append(self.allocator, .{
            .level = level,
            .message = message,
            .span = span,
            .source_file = self.current_source_file,
        }) catch return idx;
        return idx;
    }

    pub fn addFmt(self: *DiagnosticList, level: Level, span: ?Span, comptime fmt: []const u8, args: anytype) void {
        _ = self.addFmtId(level, span, fmt, args);
    }

    /// Like `addFmt`, but renders against an EXPLICIT source file (resolved via
    /// `import_sources`) instead of the ambient `current_source_file`. Used to
    /// pin a diagnostic whose `span` is an offset into a NON-current file — e.g.
    /// a parse error raised while resolving an `#import`, where the span belongs
    /// to the imported file, not the importer.
    pub fn addFmtInFile(self: *DiagnosticList, level: Level, source_file: []const u8, span: ?Span, comptime fmt: []const u8, args: anytype) void {
        const saved = self.current_source_file;
        self.current_source_file = source_file;
        defer self.current_source_file = saved;
        _ = self.addFmtId(level, span, fmt, args);
    }

    pub fn addFmtId(self: *DiagnosticList, level: Level, span: ?Span, comptime fmt: []const u8, args: anytype) usize {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch "diagnostic format error";
        return self.addId(level, message, span);
    }

    /// Attach a `note:` block to the primary diagnostic at `primary_id`.
    /// Notes render after the primary, in insertion order, before any helps.
    pub fn addNote(self: *DiagnosticList, primary_id: usize, span: ?Span, message: []const u8) void {
        self.items.append(self.allocator, .{
            .level = .note,
            .message = message,
            .span = span,
            .source_file = self.current_source_file,
            .primary = primary_id,
        }) catch {};
    }

    pub fn addNoteFmt(self: *DiagnosticList, primary_id: usize, span: ?Span, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch "diagnostic format error";
        self.addNote(primary_id, span, message);
    }

    /// Attach a `help:` block to the primary diagnostic at `primary_id`.
    /// When `fix_code` is non-null it is shown on the excerpt line in place of
    /// the original source as a fix-it suggestion.
    pub fn addHelp(self: *DiagnosticList, primary_id: usize, span: ?Span, message: []const u8, fix_code: ?[]const u8) void {
        self.items.append(self.allocator, .{
            .level = .help,
            .message = message,
            .span = span,
            .source_file = self.current_source_file,
            .primary = primary_id,
            .fix_code = fix_code,
        }) catch {};
    }

    pub fn addHelpFmt(self: *DiagnosticList, primary_id: usize, span: ?Span, fix_code: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch "diagnostic format error";
        self.addHelp(primary_id, span, message, fix_code);
    }

    pub fn hasErrors(self: *const DiagnosticList) bool {
        for (self.items.items) |d| {
            if (d.level == .err) return true;
        }
        return false;
    }

    /// Count of `.err`-level diagnostics (excludes warnings / notes / help).
    /// Used to detect whether a NEW error was reported across a span of work,
    /// without a warning/note bumping the total `items` length.
    pub fn errorCount(self: *const DiagnosticList) usize {
        var n: usize = 0;
        for (self.items.items) |d| {
            if (d.level == .err) n += 1;
        }
        return n;
    }

    fn resolveSourceAndFile(self: *const DiagnosticList, d: Diagnostic) struct { source: []const u8, file_name: []const u8 } {
        if (d.source_file) |sf| {
            if (self.import_sources) |is| {
                if (is.get(sf)) |src| {
                    return .{ .source = src, .file_name = sf };
                }
            }
        }
        return .{ .source = self.source, .file_name = self.file_name };
    }

    pub fn render(self: *const DiagnosticList, writer: anytype) !void {
        switch (self.render_style) {
            .compact => try self.renderCompact(writer),
            .extended => try self.renderExtended(writer),
        }
    }

    pub fn renderCompact(self: *const DiagnosticList, writer: anytype) !void {
        for (self.items.items) |d| {
            const level_str = levelStr(d.level);
            if (d.span) |span| {
                const resolved = self.resolveSourceAndFile(d);
                const loc = SourceLoc.compute(resolved.source, span.start);
                try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ resolved.file_name, loc.line, loc.col, level_str, d.message });
            } else {
                try writer.print("{s}: {s}: {s}\n", .{ self.file_name, level_str, d.message });
            }
        }
    }

    /// Render every primary diagnostic, each followed by its bundled notes
    /// (insertion order) and then its bundled helps. Bundles are separated by
    /// a blank line; blocks within a bundle are too.
    pub fn renderExtended(self: *const DiagnosticList, writer: anytype) !void {
        var first = true;
        for (self.items.items, 0..) |d, i| {
            if (d.primary != null) continue;
            if (!first) try writer.writeAll("\n");
            first = false;
            try self.renderBlock(writer, d, true);

            for (self.items.items) |n| {
                if (n.primary == i and n.level == .note) {
                    try writer.writeAll("\n");
                    try self.renderBlock(writer, n, true);
                }
            }
            for (self.items.items) |h| {
                if (h.primary == i and h.level == .help) {
                    try writer.writeAll("\n");
                    try self.renderBlock(writer, h, false);
                }
            }
        }
    }

    /// Render one diagnostic as a header line, optional `-->` location arrow,
    /// and a code excerpt with caret underline. A `.help` with `fix_code`
    /// substitutes the suggested source on the excerpt line and omits the
    /// arrow (`show_arrow == false`).
    fn renderBlock(self: *const DiagnosticList, writer: anytype, d: Diagnostic, show_arrow: bool) !void {
        const level_str = levelStr(d.level);
        try writer.print("{s}: {s}\n", .{ level_str, d.message });

        const span = d.span orelse return;
        const resolved = self.resolveSourceAndFile(d);

        if (show_arrow) {
            const loc = SourceLoc.compute(resolved.source, span.start);
            try writer.print("  --> {s}:{d}:{d}\n", .{ resolved.file_name, loc.line, loc.col });
        }

        var ctx = extractContext(self.allocator, resolved.source, span) catch return;
        defer ctx.deinit(self.allocator);
        if (ctx.lines.len == 0) return;

        const max_line_num = ctx.lines[ctx.lines.len - 1].line_num;
        const line_num_width = @max(@as(usize, 2), digitCount(max_line_num));

        try writeRepeated(writer, ' ', line_num_width + 1);
        try writer.writeAll("|\n");

        // Fix-it: show the suggested replacement on the primary span's line
        // instead of the original source, with carets under the change.
        if (d.fix_code) |fix| {
            const ln = ctx.lines[0].line_num;
            const pad = line_num_width - digitCount(ln);
            try writeRepeated(writer, ' ', pad);
            try writer.print("{d} | {s}\n", .{ ln, fix });

            try writeRepeated(writer, ' ', line_num_width + 1);
            try writer.writeAll("| ");
            try writeRepeated(writer, ' ', ctx.start_col - 1);
            const caret_count = if (ctx.end_col > ctx.start_col) ctx.end_col - ctx.start_col else 1;
            try writeRepeated(writer, '^', caret_count);
            try writer.writeAll("\n");
            return;
        }

        for (ctx.lines, 0..) |line, idx| {
            const pad = line_num_width - digitCount(line.line_num);
            try writeRepeated(writer, ' ', pad);
            try writer.print("{d} | {s}\n", .{ line.line_num, line.text });

            try writeRepeated(writer, ' ', line_num_width + 1);
            try writer.writeAll("| ");
            const col_start: u32 = if (idx == 0) ctx.start_col else 1;
            const col_end: u32 = if (idx == ctx.lines.len - 1)
                ctx.end_col
            else
                @as(u32, @intCast(line.text.len)) + 1;
            try writeRepeated(writer, ' ', col_start - 1);
            const caret_count = if (col_end > col_start) col_end - col_start else 1;
            try writeRepeated(writer, '^', caret_count);
            try writer.writeAll("\n");
        }
    }

    fn levelStr(level: Level) []const u8 {
        return switch (level) {
            .err => "error",
            .warn => "warning",
            .note => "note",
            .help => "help",
        };
    }

    fn digitCount(n: u32) usize {
        if (n == 0) return 1;
        var count: usize = 0;
        var v = n;
        while (v > 0) : (v /= 10) count += 1;
        return count;
    }

    fn writeRepeated(writer: anytype, byte: u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try writer.writeByte(byte);
    }

    /// Render diagnostics to stderr respecting `render_style`. This is the
    /// path the CLI uses; `renderDebug` remains a compact fallback.
    pub fn renderStderr(self: *const DiagnosticList) void {
        var aw = std.Io.Writer.Allocating.init(self.allocator);
        self.render(&aw.writer) catch {
            self.renderDebug();
            return;
        };
        var result = aw.writer.toArrayList();
        defer result.deinit(self.allocator);
        std.debug.print("{s}", .{result.items});
    }

    pub fn renderDebug(self: *const DiagnosticList) void {
        for (self.items.items) |d| {
            const level_str = levelStr(d.level);
            if (d.span) |span| {
                const resolved = self.resolveSourceAndFile(d);
                const loc = SourceLoc.compute(resolved.source, span.start);
                std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{ resolved.file_name, loc.line, loc.col, level_str, d.message });
            } else {
                std.debug.print("{s}: {s}: {s}\n", .{ self.file_name, level_str, d.message });
            }
        }
    }
};
