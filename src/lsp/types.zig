const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const Diagnostic = struct {
    range: Range,
    severity: u32,
    message: []const u8,
    source: []const u8 = "sx",
};

/// Build a JSON-RPC response with a pre-built result JSON string.
pub fn jsonRpcResponse(allocator: std.mem.Allocator, id_json: []const u8, result_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json });
}

/// Build a JSON-RPC notification.
pub fn jsonRpcNotification(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
}

/// Serialize a JSON Value to string.
pub fn valueToJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try writeJsonValue(&buf, allocator, value);
    return buf.items;
}

/// Escape a string for JSON.
pub fn jsonString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, ch),
        }
    }
    try buf.append(allocator, '"');
    return buf.items;
}

fn writeJsonValue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            const escaped = try jsonString(allocator, s);
            try buf.appendSlice(allocator, escaped);
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ',');
                try writeJsonValue(buf, allocator, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                const key = try jsonString(allocator, entry.key_ptr.*);
                try buf.appendSlice(allocator, key);
                try buf.append(allocator, ':');
                try writeJsonValue(buf, allocator, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
    }
}

/// Build the initialize result JSON.
pub fn initializeResultJson(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"capabilities\":{{\"textDocumentSync\":{{\"openClose\":true,\"change\":1,\"save\":true}},\"definitionProvider\":true,\"referencesProvider\":true,\"hoverProvider\":true,\"documentSymbolProvider\":true," ++
            "\"completionProvider\":{{\"triggerCharacters\":[\".\"]}}," ++
            "\"signatureHelpProvider\":{{\"triggerCharacters\":[\"(\",\",\"]}}," ++
            "\"semanticTokensProvider\":{{\"legend\":{{" ++
            "\"tokenTypes\":[\"namespace\",\"type\",\"enum\",\"struct\",\"parameter\",\"variable\",\"enumMember\",\"function\",\"keyword\",\"number\",\"string\",\"operator\",\"interface\"]," ++
            "\"tokenModifiers\":[\"declaration\",\"readonly\"]" ++
            "}},\"full\":true}}," ++
            "\"inlayHintProvider\":true}}}}",
        .{},
    );
}

/// LSP SymbolKind enum values.
pub const SymbolKindLsp = enum(u32) {
    File = 1,
    Module = 2,
    Namespace = 3,
    Package = 4,
    Class = 5,
    Method = 6,
    Property = 7,
    Field = 8,
    Constructor = 9,
    Enum = 10,
    Interface = 11,
    Function = 12,
    Variable = 13,
    Constant = 14,
    String = 15,
    Number = 16,
    Boolean = 17,
    Array = 18,
    Object = 19,
    Key = 20,
    Null = 21,
    EnumMember = 22,
    Struct = 23,
    Event = 24,
    Operator = 25,
    TypeParameter = 26,
};

/// LSP CompletionItemKind enum values.
pub const CompletionItemKind = enum(u32) {
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25,
};

/// Build document symbols JSON array.
pub fn documentSymbolsJson(allocator: std.mem.Allocator, symbols: []const DocumentSymbol) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.append(allocator, '[');
    for (symbols, 0..) |sym, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const name_escaped = try jsonString(allocator, sym.name);
        const item = try std.fmt.allocPrint(allocator,
            "{{\"name\":{s},\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
            .{
                name_escaped,                                          sym.kind,
                sym.range.start.line,      sym.range.start.character,
                sym.range.end.line,        sym.range.end.character,
                sym.selection_range.start.line, sym.selection_range.start.character,
                sym.selection_range.end.line,   sym.selection_range.end.character,
            },
        );
        try buf.appendSlice(allocator, item);
    }
    try buf.append(allocator, ']');
    return buf.items;
}

pub const DocumentSymbol = struct {
    name: []const u8,
    kind: u32,
    range: Range,
    selection_range: Range,
};

/// Build completion items JSON array.
pub fn completionItemsJson(allocator: std.mem.Allocator, items: []const CompletionItem) ![]const u8 {
    return completionItemsJsonInner(allocator, items, false);
}

/// Build a CompletionList object with isIncomplete: false, preventing the client
/// from supplementing results with its own word-based suggestions.
pub fn completionListJson(allocator: std.mem.Allocator, items: []const CompletionItem) ![]const u8 {
    return completionItemsJsonInner(allocator, items, true);
}

fn completionItemsJsonInner(allocator: std.mem.Allocator, items: []const CompletionItem, as_list: bool) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    if (as_list) try buf.appendSlice(allocator, "{\"isIncomplete\":false,\"items\":");
    try buf.append(allocator, '[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const label_escaped = try jsonString(allocator, item.label);
        const detail_escaped = if (item.detail) |d| try jsonString(allocator, d) else null;
        if (detail_escaped) |de| {
            const json = try std.fmt.allocPrint(allocator,
                "{{\"label\":{s},\"kind\":{d},\"detail\":{s}}}",
                .{ label_escaped, item.kind, de },
            );
            try buf.appendSlice(allocator, json);
        } else {
            const json = try std.fmt.allocPrint(allocator,
                "{{\"label\":{s},\"kind\":{d}}}",
                .{ label_escaped, item.kind },
            );
            try buf.appendSlice(allocator, json);
        }
    }
    try buf.append(allocator, ']');
    if (as_list) try buf.append(allocator, '}');
    return buf.items;
}

pub const CompletionItem = struct {
    label: []const u8,
    kind: u32,
    detail: ?[]const u8 = null,
};

/// Build a Location JSON response (for go-to-definition).
pub fn locationJson(allocator: std.mem.Allocator, uri: []const u8, range: Range) ![]const u8 {
    const uri_escaped = try jsonString(allocator, uri);
    return std.fmt.allocPrint(allocator,
        "{{\"uri\":{s},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
        .{ uri_escaped, range.start.line, range.start.character, range.end.line, range.end.character },
    );
}

/// Build a LocationLink JSON response (for go-to-definition with origin range).
pub fn locationLinkJson(allocator: std.mem.Allocator, target_uri: []const u8, target_range: Range, origin_range: Range) ![]const u8 {
    const uri_escaped = try jsonString(allocator, target_uri);
    return std.fmt.allocPrint(allocator,
        "[{{\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}," ++
            "\"targetUri\":{s}," ++
            "\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}," ++
            "\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}]",
        .{
            origin_range.start.line, origin_range.start.character, origin_range.end.line, origin_range.end.character,
            uri_escaped,
            target_range.start.line, target_range.start.character, target_range.end.line, target_range.end.character,
            target_range.start.line, target_range.start.character, target_range.end.line, target_range.end.character,
        },
    );
}

/// Build a Hover JSON response.
pub fn hoverJson(allocator: std.mem.Allocator, contents: []const u8) ![]const u8 {
    const escaped = try jsonString(allocator, contents);
    return std.fmt.allocPrint(allocator,
        "{{\"contents\":{{\"kind\":\"markdown\",\"value\":{s}}}}}",
        .{escaped},
    );
}

/// Build a SignatureHelp JSON response.
pub fn signatureHelpJson(allocator: std.mem.Allocator, label: []const u8, param_labels: []const []const u8, active_param: u32) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    const label_escaped = try jsonString(allocator, label);

    try buf.appendSlice(allocator, "{\"signatures\":[{\"label\":");
    try buf.appendSlice(allocator, label_escaped);
    try buf.appendSlice(allocator, ",\"parameters\":[");

    for (param_labels, 0..) |pl, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const pl_escaped = try jsonString(allocator, pl);
        try buf.appendSlice(allocator, "{\"label\":");
        try buf.appendSlice(allocator, pl_escaped);
        try buf.append(allocator, '}');
    }

    const ap_str = try std.fmt.allocPrint(allocator, "{d}", .{active_param});
    try buf.appendSlice(allocator, "]}],\"activeSignature\":0,\"activeParameter\":");
    try buf.appendSlice(allocator, ap_str);
    try buf.append(allocator, '}');

    return buf.items;
}

/// Semantic token type indices (must match legend in initializeResultJson).
pub const SemanticTokenType = struct {
    pub const namespace: u32 = 0;
    pub const type_: u32 = 1;
    pub const enum_: u32 = 2;
    pub const struct_: u32 = 3;
    pub const parameter: u32 = 4;
    pub const variable: u32 = 5;
    pub const enum_member: u32 = 6;
    pub const function: u32 = 7;
    pub const keyword: u32 = 8;
    pub const number: u32 = 9;
    pub const string_: u32 = 10;
    pub const operator_: u32 = 11;
    pub const interface: u32 = 12;
};

/// Build a SemanticTokens JSON response.
pub fn semanticTokensJson(allocator: std.mem.Allocator, data: []const u32) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, "{\"data\":[");
    for (data, 0..) |val, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const s = try std.fmt.allocPrint(allocator, "{d}", .{val});
        try buf.appendSlice(allocator, s);
    }
    try buf.appendSlice(allocator, "]}");
    return buf.items;
}

/// Build publishDiagnostics params JSON.
pub fn publishDiagnosticsJson(allocator: std.mem.Allocator, uri: []const u8, diagnostics: []const Diagnostic) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    const uri_escaped = try jsonString(allocator, uri);

    try buf.appendSlice(allocator, "{\"uri\":");
    try buf.appendSlice(allocator, uri_escaped);
    try buf.appendSlice(allocator, ",\"diagnostics\":[");

    for (diagnostics, 0..) |d, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const msg_escaped = try jsonString(allocator, d.message);
        const src_escaped = try jsonString(allocator, d.source);
        const diag_json = try std.fmt.allocPrint(allocator,
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"message\":{s},\"source\":{s}}}",
            .{ d.range.start.line, d.range.start.character, d.range.end.line, d.range.end.character, d.severity, msg_escaped, src_escaped },
        );
        try buf.appendSlice(allocator, diag_json);
    }

    try buf.appendSlice(allocator, "]}");
    return buf.items;
}

pub const InlayHint = struct {
    line: u32,
    character: u32,
    label: []const u8,
    kind: u32 = 1, // 1 = Type
    padding_left: bool = true,
    padding_right: bool = false,
};

/// Build inlay hints JSON array response.
pub fn inlayHintsJson(allocator: std.mem.Allocator, hints: []const InlayHint) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.append(allocator, '[');
    for (hints, 0..) |hint, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const label_escaped = try jsonString(allocator, hint.label);
        const json = try std.fmt.allocPrint(allocator,
            "{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":{s},\"kind\":{d},\"paddingLeft\":{s},\"paddingRight\":{s}}}",
            .{ hint.line, hint.character, label_escaped, hint.kind, if (hint.padding_left) "true" else "false", if (hint.padding_right) "true" else "false" },
        );
        try buf.appendSlice(allocator, json);
    }
    try buf.append(allocator, ']');
    return buf.items;
}
