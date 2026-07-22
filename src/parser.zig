const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const getKeyword = @import("token.zig").getKeyword;
const Lexer = @import("lexer.zig").Lexer;
const ast = @import("ast.zig");
const Node = ast.Node;
const Type = @import("types.zig").Type;
const errors = @import("errors.zig");
const print = @import("print.zig");
const unescape = @import("unescape.zig");

pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    source: [:0]const u8,
    allocator: std.mem.Allocator,
    err_msg: ?[]const u8,
    err_offset: ?u32 = null,
    err_end: ?u32 = null,
    prev_end: u32 = 0,
    diagnostics: ?*errors.DiagnosticList = null,
    /// Type param names from enclosing generic struct (set while parsing methods)
    struct_type_params: []const []const u8 = &.{},
    /// When true (set while parsing a `for` header's iterable expressions),
    /// a top-level `(` group immediately followed by `{` or `=>` is the loop
    /// CAPTURE, never call arguments — `for xs (x) { }` reads `(x)` as the
    /// capture, while `for zip(a, b) (x, y) { }` still calls `zip(a, b)`
    /// because that group is not the trailing one. Cleared inside any nested
    /// bracket/paren/argument context.
    in_for_header: bool = false,
    /// While parsing an if-condition, a `{` immediately after an anonymous
    /// struct literal starts the if body, not the literal's optional init
    /// block (`if x != .{1, 2} { ... }`, issue 0246).
    in_if_condition: bool = false,
    /// Trailing-block T5 (specs: Trailing Blocks): while parsing a header
    /// expression whose `{` opens the statement body (`while cond {`,
    /// `push expr {`), a call may not take a trailing block. `if`/`for`
    /// headers are covered by `in_if_condition`/`in_for_header`. Cleared
    /// inside nested paren/argument contexts alongside `in_for_header`.
    no_trailing_block: bool = false,
    /// When true (set while parsing an `onfail` body), a `raise` statement is
    /// rejected — an error during cleanup has no propagation target. E1.7
    /// extends this to the full {try, return, break, continue} set.
    in_onfail_body: bool = false,
    /// When true (set while parsing a `defer` body), a `raise` statement is
    /// rejected — same reason as `onfail`: cleanup runs while the function is
    /// already exiting, so there is nothing to propagate to. E1.7 extends this
    /// to the full {try, return, break, continue} set.
    in_defer_body: bool = false,
    /// Set by `expectSemicolonAfter` for the statement just parsed: true when the
    /// statement is a trailing value (an expression / block-form with NO `;`),
    /// false when a `;` terminated it (value discarded). `parseBlock` reads it
    /// after the last statement to set `Block.produces_value`. Reset at the top
    /// of `parseStmt` so non-expression statements (decls, return, …) leave it
    /// false.
    last_stmt_produces_value: bool = false,
    /// Span of the `;` that discarded the just-parsed statement's value, when
    /// that statement was an expression terminated by `;` (so the value could
    /// have been kept by dropping it). Null when the statement kept its value or
    /// wasn't a value expression. Read by `parseBlock` into `Block.discarded_semi`.
    last_stmt_semi_loc: ?ast.Span = null,
    /// True while parsing the branches of a MODULE-SCOPE `inline if`: its
    /// statements are top-level declarations after comptime flattening, so
    /// `private` remains legal on them. Function/lambda bodies clear it — a
    /// nested body's declarations are locals, never module scope.
    in_module_inline_if: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.next();
        return .{
            .lexer = lexer,
            .current = first,
            .source = source,
            .allocator = allocator,
            .err_msg = null,
            .err_offset = null,
        };
    }

    fn createNode(self: *Parser, start: u32, data: Node.Data) !*Node {
        const node = try self.allocator.create(Node);
        node.* = .{ .span = .{ .start = start, .end = self.prev_end }, .data = data };
        return node;
    }

    pub fn parse(self: *Parser) anyerror!*Node {
        var decls = std.ArrayList(*Node).empty;
        while (self.current.tag != .eof) {
            const decl = try self.parseTopLevel();
            try decls.append(self.allocator, decl);
        }
        const node = try self.createNode(0, .{ .root = .{ .decls = try decls.toOwnedSlice(self.allocator) } });
        return node;
    }

    fn parseTopLevel(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;

        // `private NAME …` — a module-scope declaration restricted to its
        // declaring source file. Only identifier-headed declarations take the
        // modifier; every directive/block form is rejected with a placement
        // diagnostic.
        if (self.current.tag == .kw_private) {
            self.advance();
            switch (self.current.tag) {
                .hash_import => return self.fail("'private' is not allowed on a flat '#import'; only a named import ('name :: #import \"…\"') can be private"),
                .kw_asm => return self.fail("'private' is not allowed on global 'asm'"),
                .hash_run => return self.fail("'private' is not allowed on a standalone '#run'"),
                .hash_framework => return self.fail("'private' is not allowed on '#framework'"),
                .kw_impl => return self.fail("'private' is not allowed on an 'impl' block"),
                .hash_error => return self.fail("'private' is not allowed on '#error'"),
                .hash_context_extend => return self.fail("'private' is not allowed on '#context_extend'"),
                .kw_inline => return self.fail("'private' is not allowed on 'inline if'; mark the declarations inside its branches instead"),
                .kw_private => return self.fail("duplicate 'private'"),
                else => {},
            }
            if (!self.isIdentLike() and self.current.tag != .kw_Self) {
                return self.fail("expected a declaration name after 'private'");
            }
            const node = try self.parseTopLevelNamedDecl();
            node.visibility = .private;
            return node;
        }

        // Top-level flat import: #import "path"; or #import c { ... };
        if (self.current.tag == .hash_import) {
            self.advance();
            // Check for #import c { ... } (C import block)
            if (self.current.tag == .identifier and std.mem.eql(u8, self.tokenSlice(self.current), "c") and self.peekNext() == .l_brace) {
                self.advance(); // consume 'c'
                return self.parseCImportBlock(start, null, false);
            }
            if (self.current.tag != .string_literal) {
                return self.fail("expected string path after '#import'");
            }
            const raw = self.tokenSlice(self.current);
            const path = raw[1 .. raw.len - 1];
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .import_decl = .{ .path = path, .name = null } });
        }

        // Top-level (module-scope) global assembly: `asm { "tmpl", };`
        // (template only — no operands/volatile/clobbers). The in-function
        // `asm { … }` expression form is parsed in `parsePrimary` instead.
        if (self.current.tag == .kw_asm) {
            return self.parseAsmGlobal(start);
        }

        // Top-level #run directive
        if (self.current.tag == .hash_run) {
            self.advance();
            const expr = try self.parseExpr();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .comptime_expr = .{ .expr = expr } });
        }

        // Top-level #framework directive: link against an Apple framework.
        if (self.current.tag == .hash_framework) {
            self.advance();
            if (self.current.tag != .string_literal) {
                return self.fail("expected string after '#framework'");
            }
            const raw = self.tokenSlice(self.current);
            const fw_name = raw[1 .. raw.len - 1];
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .framework_decl = .{ .name = fw_name } });
        }

        // impl Protocol for Type { methods }
        if (self.current.tag == .kw_impl) {
            return self.parseImplBlock(start);
        }

        // Top-level `inline if` — compile-time conditional
        if (self.current.tag == .kw_inline) {
            if (self.peekNext() == .kw_if) {
                self.advance(); // skip 'inline'
                const saved_module_if = self.in_module_inline_if;
                self.in_module_inline_if = true;
                defer self.in_module_inline_if = saved_module_if;
                const expr = try self.parseIfExpr();
                if (expr.data == .if_expr) {
                    expr.data.if_expr.is_comptime = true;
                } else if (expr.data == .match_expr) {
                    expr.data.match_expr.is_comptime = true;
                }
                return expr;
            }
        }

        // Top-level `#error "msg";` — compile-time diagnostic.
        if (self.current.tag == .hash_error) {
            return self.parseErrorDirective();
        }

        // Top-level `#context_extend name: Type = default;` — declares a field
        // of the program's assembled Context.
        if (self.current.tag == .hash_context_extend) {
            self.advance();
            if (!self.isIdentLike()) {
                return self.fail("expected field name after '#context_extend'");
            }
            const field_name = self.tokenSlice(self.current);
            const field_name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            self.advance();
            try self.expect(.colon);
            const type_node = try self.parseTypeExpr();
            var default_node: ?*Node = null;
            if (self.current.tag == .equal) {
                self.advance();
                default_node = try self.parseExpr();
            }
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .context_extend_decl = .{
                .name = field_name,
                .name_span = field_name_span,
                .type_expr = type_node,
                .default_expr = default_node,
            } });
        }

        // All top-level declarations start with an identifier
        if (!self.isIdentLike() and self.current.tag != .kw_Self) {
            return self.fail("expected identifier at top level");
        }
        return self.parseTopLevelNamedDecl();
    }

    /// The identifier-headed module-scope declaration tail (`NAME :: …`,
    /// `NAME : T [:|=] …`, `NAME := …`). Shared by the plain and
    /// `private`-prefixed top-level paths; the caller has already verified an
    /// identifier-like token is current.
    fn parseTopLevelNamedDecl(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        const name = self.tokenSlice(self.current);
        const name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
        const name_is_raw = self.current.is_raw;
        self.advance();

        // IDENT :: ...
        if (self.current.tag == .colon_colon) {
            self.advance();
            return self.parseConstBinding(name, name_span, start, name_is_raw);
        }

        // IDENT : type : value; (typed constant)
        // IDENT : type = value; (typed variable)
        if (self.current.tag == .colon) {
            self.advance();
            return self.parseTypedBinding(name, name_span, start, name_is_raw);
        }

        // IDENT := value; (variable)
        if (self.current.tag == .colon_equal) {
            self.advance();
            const value = try self.parseExpr();
            try self.expectSemicolonAfter(value);
            return try self.createNode(start, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = null, .value = value, .is_raw = name_is_raw } });
        }

        return self.fail("expected '::', ':=', or ':' after identifier");
    }

    fn parseConstBinding(self: *Parser, name: []const u8, name_span: ast.Span, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        // After `::`
        // Could be: #run expr, enum { ... }, (params) -> type { body }, or expr;

        // Namespaced import: name :: #import "path"; or name :: #import c { ... };
        if (self.current.tag == .hash_import) {
            self.advance();
            // Check for name :: #import c { ... }
            if (self.current.tag == .identifier and std.mem.eql(u8, self.tokenSlice(self.current), "c") and self.peekNext() == .l_brace) {
                self.advance(); // consume 'c'
                return self.parseCImportBlock(start_pos, name, name_is_raw);
            }
            if (self.current.tag != .string_literal) {
                return self.fail("expected string path after '#import'");
            }
            const raw = self.tokenSlice(self.current);
            const path = raw[1 .. raw.len - 1];
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start_pos, .{ .import_decl = .{ .path = path, .name = name, .is_raw = name_is_raw } });
        }

        // Named library: name :: #library "libname";
        if (self.current.tag == .hash_library) {
            self.advance();
            if (self.current.tag != .string_literal) {
                return self.fail("expected string after '#library'");
            }
            const raw = self.tokenSlice(self.current);
            const lib_name = raw[1 .. raw.len - 1];
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start_pos, .{ .library_decl = .{ .lib_name = lib_name, .name = name, .is_raw = name_is_raw } });
        }

        // Compile-time evaluation: name :: #run expr;
        if (self.current.tag == .hash_run) {
            const run_start = self.current.loc.start;
            self.advance();
            const inner = try self.parseExpr();
            try self.expect(.semicolon);
            const ct = try self.createNode(run_start, .{ .comptime_expr = .{ .expr = inner } });
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = null, .value = ct, .name_span = name_span, .is_raw = name_is_raw } });
        }

        // Intrinsic declaration: name :: intrinsic;
        if (self.current.tag == .kw_intrinsic) {
            const bi_start = self.current.loc.start;
            self.advance();
            try self.expect(.semicolon);
            const bi = try self.createNode(bi_start, .{ .intrinsic_expr = {} });
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = null, .value = bi, .name_span = name_span, .is_raw = name_is_raw } });
        }

        // Enum declaration
        if (self.current.tag == .kw_enum) {
            return self.parseEnumDecl(name, start_pos, name_is_raw);
        }

        // Error-set declaration: name :: error { TagA, TagB }
        if (self.current.tag == .kw_error) {
            return self.parseErrorSetDecl(name, start_pos, name_is_raw);
        }

        // Struct declaration
        if (self.current.tag == .kw_struct) {
            return self.parseStructDecl(name, start_pos, name_is_raw);
        }

        // Protocol declaration
        if (self.current.tag == .kw_protocol) {
            return self.parseProtocolDecl(name, start_pos, name_is_raw);
        }

        // Runtime-class binding with an optional `#jni_main` prefix modifier:
        //   [#jni_main]* (#jni_class / #jni_interface / #objc_class /
        //   #objc_protocol / #swift_class / #swift_struct / #swift_protocol) ("path") { body }
        //
        // Define-by-default: bare `#jni_class("...")` declares a new class (sx-defined).
        // Postfix `extern` flips that to "reference an existing class on the runtime
        // side". `#jni_main` flags the class as the launchable entry (Android Activity).
        if (self.tryParseRuntimeClassPrefix()) |prefix| {
            return self.parseRuntimeClassDecl(name, start_pos, prefix.runtime, prefix.is_main, name_is_raw);
        }

        // C-style union declaration
        if (self.current.tag == .kw_union) {
            return self.parseUnionDecl(name, start_pos, name_is_raw);
        }

        // UFCS forms:
        //   name :: ufcs (params) -> ret { body }   — fn declared dot-callable
        //   name :: ufcs target;                    — dot-callable alias
        if (self.current.tag == .kw_ufcs) {
            self.advance();
            if (self.current.tag == .l_paren) {
                const node = try self.parseFnDecl(name, name_span, name_is_raw, start_pos);
                node.data.fn_decl.is_ufcs = true;
                return node;
            }
            if (self.current.tag != .identifier) {
                return self.fail("expected '(' (a ufcs function declaration) or a function name (a ufcs alias) after 'ufcs'");
            }
            const target = self.tokenSlice(self.current);
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start_pos, .{ .ufcs_alias = .{ .name = name, .target = target, .is_raw = name_is_raw } });
        }

        // Function declaration: (params) -> type { body } or () { body }
        if (self.current.tag == .l_paren) {
            // Look ahead: is this a function or an expression starting with `(`?
            // Heuristic: if after matching parens we see `{` or `->`, it's a function.
            if (self.isFunctionDef()) {
                return self.parseFnDecl(name, name_span, name_is_raw, start_pos);
            }
        }

        // Bare block shorthand: name :: { body } is equivalent to name :: () { body }
        if (self.current.tag == .l_brace) {
            const body = try self.parseBlock();
            return try self.createNode(start_pos, .{ .fn_decl = .{ .name = name, .params = &.{}, .return_type = null, .body = body, .name_span = name_span, .is_raw = name_is_raw } });
        }

        // Otherwise it's a constant expression
        const value = try self.parseExpr();

        // name :: type_expr intrinsic; — intrinsic with type annotation
        if (self.current.tag == .kw_intrinsic) {
            const bi_start = self.current.loc.start;
            self.advance();
            try self.expect(.semicolon);
            const bi = try self.createNode(bi_start, .{ .intrinsic_expr = {} });
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = value, .value = bi, .name_span = name_span, .is_raw = name_is_raw } });
        }

        try self.expect(.semicolon);
        return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = null, .value = value, .name_span = name_span, .is_raw = name_is_raw } });
    }

    fn parseCImportBlock(self: *Parser, start: u32, name: ?[]const u8, name_is_raw: bool) anyerror!*Node {
        try self.expect(.l_brace);
        var includes = std.ArrayList([]const u8).empty;
        var sources = std.ArrayList([]const u8).empty;
        var defines = std.ArrayList([]const u8).empty;
        var flags = std.ArrayList([]const u8).empty;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            if (self.current.tag == .hash_include) {
                self.advance();
                if (self.current.tag != .string_literal) return self.fail("expected string after '#include'");
                const raw = self.tokenSlice(self.current);
                try includes.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else if (self.current.tag == .hash_source) {
                self.advance();
                if (self.current.tag != .string_literal) return self.fail("expected string after '#source'");
                const raw = self.tokenSlice(self.current);
                try sources.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else if (self.current.tag == .hash_define) {
                self.advance();
                if (self.current.tag != .string_literal) return self.fail("expected string after '#define'");
                const raw = self.tokenSlice(self.current);
                try defines.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else if (self.current.tag == .hash_flags) {
                self.advance();
                if (self.current.tag != .string_literal) return self.fail("expected string after '#flags'");
                const raw = self.tokenSlice(self.current);
                try flags.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else {
                return self.fail("unexpected token inside '#import c { ... }'");
            }
        }
        try self.expect(.r_brace);
        try self.expect(.semicolon);

        return try self.createNode(start, .{ .c_import_decl = .{
            .includes = try includes.toOwnedSlice(self.allocator),
            .sources = try sources.toOwnedSlice(self.allocator),
            .defines = try defines.toOwnedSlice(self.allocator),
            .flags = try flags.toOwnedSlice(self.allocator),
            .name = name,
            .is_raw = name_is_raw,
        } });
    }

    fn parseTypedBinding(self: *Parser, name: []const u8, name_span: ast.Span, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        // After `name :`
        // Parse type
        const type_node = try self.parseTypeExpr();

        if (self.current.tag == .colon) {
            // name : type : value; (typed constant)
            self.advance();
            const value = try self.parseExpr();
            try self.expectSemicolonAfter(value);
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = type_node, .value = value, .name_span = name_span, .is_raw = name_is_raw } });
        }

        if (self.current.tag == .equal) {
            // name : type = value; (typed variable)
            self.advance();
            const value = try self.parseExpr();
            try self.expectSemicolonAfter(value);
            return try self.createNode(start_pos, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = type_node, .value = value, .is_raw = name_is_raw } });
        }

        if (self.current.tag == .semicolon) {
            // name : type; (default-initialized variable)
            self.advance();
            return try self.createNode(start_pos, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = type_node, .value = null, .is_raw = name_is_raw } });
        }

        if (self.current.tag == .kw_extern) {
            // name : type extern [LIB] ["csym"];   (extern data global, resolved
            // at link time)
            self.advance();
            var ext_lib: ?[]const u8 = null;
            if (self.current.tag == .identifier) {
                ext_lib = self.tokenSlice(self.current);
                self.advance();
            }
            var ext_name: ?[]const u8 = null;
            if (self.current.tag == .string_literal) {
                const raw = self.tokenSlice(self.current);
                ext_name = raw[1 .. raw.len - 1];
                self.advance();
            }
            try self.expect(.semicolon);
            return try self.createNode(start_pos, .{ .var_decl = .{
                .name = name,
                .name_span = name_span,
                .type_annotation = type_node,
                .value = null,
                .is_extern = true,
                .extern_lib = ext_lib,
                .extern_name = ext_name,
                .is_raw = name_is_raw,
            } });
        }

        return self.fail("expected ':', '=', ';', or 'extern' after type annotation");
    }

    /// Parse a function/method/lambda/closure/fn-pointer return type.
    ///
    /// The canonical failable / multi-return spelling wraps the result list in
    /// parens: `-> (T, !)`, `-> (A, B, !)`, `-> (x: A, y: B, !)` — the error
    /// channel is the last slot. A bare `-> !` (error-only, no value) is parsed
    /// by `parseTypeExpr` as an `error_type_expr` and is unaffected.
    ///
    /// The legacy trailing-`!`-after-the-value-type spelling (`-> T !`,
    /// `-> Tuple(A, B) !`) is REJECTED — it was a redundant second spelling of
    /// `(T, !)` / `(A, B, !)` and is no longer accepted.
    fn parseFnReturnType(self: *Parser) anyerror!*Node {
        const ty = try self.parseTypeExpr();

        // A trailing `!` after a VALUE return type is the removed legacy
        // spelling. (`-> !` already parsed to an error_type_expr above, so a
        // `!` after one would be a doubled channel — leave that to the normal
        // "unexpected token" path.)
        if (self.current.tag == .bang and ty.data != .error_type_expr) {
            return self.fail("a failable return is written `(T, !)` — or `(A, B, !)` for multiple values — not `T !`");
        }
        return ty;
    }

    fn parseTypeExpr(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;

        // Error channel type: bare `!` (inferred set) or `!Named` (named set).
        // Legal only as the trailing element of a multi-return result list
        // (enforced by the parenthesized-list loop below) or as a bare
        // failable return type. Sema (E1) restricts it to return positions.
        if (self.current.tag == .bang) {
            self.advance(); // skip '!'
            var set_name: ?[]const u8 = null;
            if (self.current.tag == .identifier) {
                set_name = self.tokenSlice(self.current);
                self.advance();
            }
            return try self.createNode(start, .{ .error_type_expr = .{ .name = set_name } });
        }

        // Optional type: ?T
        if (self.current.tag == .question) {
            self.advance(); // skip '?'
            const inner_type = try self.parseTypeExpr();
            return try self.createNode(start, .{ .optional_type_expr = .{ .inner_type = inner_type } });
        }

        // Pointer type: *T
        if (self.current.tag == .star) {
            self.advance(); // skip '*'
            const pointee_type = try self.parseTypeExpr();
            return try self.createNode(start, .{ .pointer_type_expr = .{ .pointee_type = pointee_type } });
        }

        // Array type: [N]T, Slice type: []T, Many-pointer type: [*]T, Sentinel slice: [:0]T
        if (self.current.tag == .l_bracket) {
            self.advance(); // skip '['
            if (self.current.tag == .colon) {
                // Sentinel-terminated slice: [:0]T
                self.advance(); // skip ':'
                if (self.current.tag != .int_literal) {
                    return self.fail("expected sentinel value after ':'");
                }
                const sentinel_str = self.tokenSlice(self.current);
                self.advance(); // skip sentinel value
                try self.expect(.r_bracket); // expect ']'
                const elem_type = try self.parseTypeExpr();
                // Build name like "[:0]u8" for type resolution
                const elem_name = if (elem_type.data == .type_expr) elem_type.data.type_expr.name else "?";
                const name = try std.fmt.allocPrint(self.allocator, "[:{s}]{s}", .{ sentinel_str, elem_name });
                return try self.createNode(start, .{ .type_expr = .{ .name = name } });
            }
            if (self.current.tag == .r_bracket) {
                // Slice type: []T
                self.advance(); // skip ']'
                const elem_type = try self.parseTypeExpr();
                return try self.createNode(start, .{ .slice_type_expr = .{ .element_type = elem_type } });
            }
            if (self.current.tag == .star) {
                // Many-pointer type: [*]T
                self.advance(); // skip '*'
                try self.expect(.r_bracket); // expect ']'
                const elem_type = try self.parseTypeExpr();
                return try self.createNode(start, .{ .many_pointer_type_expr = .{ .element_type = elem_type } });
            }
            const len_node = try self.parseExpr();
            try self.expect(.r_bracket);
            const elem_type = try self.parseTypeExpr();
            return try self.createNode(start, .{ .array_type_expr = .{ .length = len_node, .element_type = elem_type } });
        }

        // Generic type parameter introduction: $T or $T/Protocol1/Protocol2.
        // Also: pack-index type access $args[<int_literal>] — resolves to
        // the i-th element type of the active pack binding (step 3 of
        // the variadic heterogeneous type packs feature).
        if (self.current.tag == .dollar) {
            self.advance();
            if (self.current.tag != .identifier) {
                return self.fail("expected type parameter name after '$'");
            }
            const name = self.tokenSlice(self.current);
            self.advance();
            // Pack-index access: $<pack_name>[<int_literal>]
            if (self.current.tag == .l_bracket) {
                self.advance(); // skip '['
                if (self.current.tag != .int_literal) {
                    return self.fail("expected integer literal in pack index");
                }
                const idx_text = self.tokenSlice(self.current);
                // Strip `_` separators / honor `0x`/`0o`/`0b` prefixes via the
                // shared literal parser (matches every other int-literal site).
                const idx_u64 = self.parseIntLiteralText(idx_text) orelse {
                    return self.fail("invalid integer literal in pack index");
                };
                const idx_val = std.math.cast(u32, idx_u64) orelse {
                    return self.fail("pack index out of range");
                };
                self.advance();
                try self.expect(.r_bracket);
                return try self.createNode(start, .{ .pack_index_type_expr = .{
                    .pack_name = name,
                    .index = idx_val,
                } });
            }
            // Parse optional protocol constraints: $T/Eq/Hashable
            var constraints = std.ArrayList([]const u8).empty;
            while (self.current.tag == .slash) {
                self.advance(); // skip '/'
                if (self.current.tag != .identifier) {
                    return self.fail("expected protocol name after '/'");
                }
                try constraints.append(self.allocator, self.tokenSlice(self.current));
                self.advance();
            }
            const pc = try constraints.toOwnedSlice(self.allocator);
            return try self.createNode(start, .{ .type_expr = .{ .name = name, .is_generic = true, .protocol_constraints = pc } });
        }
        // Function type: (ParamTypes) -> ReturnType
        // Tuple type: (T1, T2) or (T1) — no '->' after ')'
        // Named params (documentation only): (name: Type, ...) -> ReturnType
        if (self.current.tag == .l_paren) {
            self.advance(); // skip '('
            var param_types = std.ArrayList(*Node).empty;
            var param_names = std.ArrayList(?[]const u8).empty;
            // Per-element default value (`(sum: i32 = 0, …)`), 1:1 with
            // `param_types`; meaningful only for a multi-return signature
            // (`return_type_expr`) — ignored for grouping / function / tuple forms.
            var param_defaults = std.ArrayList(?*Node).empty;
            var any_default = false;
            var has_names = false;
            // An error channel type (`!` / `!Named`) is only valid as the
            // trailing element of a result list. Reject any element after it.
            var saw_error_type = false;
            // Track an explicit trailing comma so a single-element `(T,)` stays a
            // 1-tuple while `(T)` (no comma) is a GROUPING — see the grouping
            // return below.
            var had_trailing_comma = false;
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (param_types.items.len > 0) {
                    try self.expect(.comma);
                    if (self.current.tag == .r_paren) {
                        had_trailing_comma = true;
                        break; // trailing comma ok
                    }
                }
                if (saw_error_type) {
                    return self.fail("error type '!' must be the last element of a result list");
                }
                // Pack expansion in a tuple/function type: `(..F(Ts))` /
                // `(..F(Ts.Arg))` / `(..Ts)`. Reuses `spread_expr`; its operand
                // is the per-element type expression (e.g. `F(Ts)`), carrying any
                // projection in `Ts.Arg` form.
                if (self.current.tag == .dot_dot) {
                    const spread_start = self.current.loc.start;
                    self.advance(); // skip '..'
                    const operand = try self.parseTypeExpr();
                    const spread = try self.createNode(spread_start, .{ .spread_expr = .{ .operand = operand } });
                    try param_names.append(self.allocator, null);
                    try param_types.append(self.allocator, spread);
                    try param_defaults.append(self.allocator, null);
                    continue;
                }
                // Check for optional param name: `name: Type`
                // An identifier followed by `:` (not `::` or `:=`) is a param name
                if (self.isIdentLike() and self.peekNext() == .colon) {
                    const pname = self.tokenSlice(self.current);
                    self.advance(); // skip name
                    self.advance(); // skip ':'
                    try param_names.append(self.allocator, pname);
                    has_names = true;
                } else {
                    try param_names.append(self.allocator, null);
                }
                const elem = try self.parseTypeExpr();
                if (elem.data == .error_type_expr) saw_error_type = true;
                try param_types.append(self.allocator, elem);
                // Optional default value `name: Type = <expr>` — a multi-return
                // slot default. Parse it for every element (1:1 with types) and
                // attach only to a `return_type_expr` below.
                var elem_default: ?*Node = null;
                if (self.current.tag == .equal) {
                    self.advance(); // skip '='
                    elem_default = try self.parseExpr();
                    any_default = true;
                }
                try param_defaults.append(self.allocator, elem_default);
            }
            try self.expect(.r_paren);
            if (self.current.tag == .arrow) {
                // '->' present: function type. A failable return is the canonical
                // parenthesized list `(i64) -> (i64, !E)` (parseFnReturnType
                // rejects the bare `-> i64 !E` spelling).
                self.advance(); // skip '->'
                const return_type = try self.parseFnReturnType();
                const abi = try self.parseOptionalAbi();
                return try self.createNode(start, .{ .function_type_expr = .{
                    .param_types = try param_types.toOwnedSlice(self.allocator),
                    .param_names = if (has_names) try param_names.toOwnedSlice(self.allocator) else null,
                    .return_type = return_type,
                    .abi = abi,
                } });
            }
            // Empty parens `()` with no `->` is the void/unit type:
            // `a :: () -> () { }` is equivalent to `-> void`. (`() -> R` was the
            // zero-param function type handled by the arrow branch above.)
            if (param_types.items.len == 0) {
                return try self.createNode(start, .{ .type_expr = .{ .name = "void" } });
            }
            // No '->': bare `(...)` in type position is GROUPING ONLY. A single
            // UNNAMED, non-spread element with NO trailing comma resolves to the
            // inner type. This lets `(Closure(i64,i64) -> i64)`, `?(?i64)`, etc.
            // parenthesize a type for readability.
            if (param_types.items.len == 1 and !had_trailing_comma and !has_names and
                param_types.items[0].data != .spread_expr)
            {
                return param_types.items[0];
            }
            // A bare-paren result list classifies by VALUE-slot count (fields
            // minus a trailing error channel — the error is ALWAYS the last slot):
            //   - ≥2 value slots → a MULTI-RETURN signature `(A, B)` /
            //     `(x: A, y: B)` / `(A, B, !)`: its OWN node (`return_type_expr`),
            //     a DISTINCT thing from a `Tuple(…)` value (not a tuple,
            //     return-only, destructure-only).
            //   - 1 value slot + error `(T, !)` → a SINGLE-value failable, exactly
            //     `-> T !` (NOT multi-return): the failable `tuple_type_expr`.
            //   - anything else (a `(T,)` 1-tuple, a stray spread) → rejected;
            //     a real tuple VALUE type uses `Tuple(…)`.
            const last_is_err = param_types.items.len > 0 and
                param_types.items[param_types.items.len - 1].data == .error_type_expr;
            const value_count = param_types.items.len - @as(usize, if (last_is_err) 1 else 0);
            if (value_count >= 2 or (last_is_err and value_count == 1)) {
                var fnames: ?[]const []const u8 = null;
                if (has_names) {
                    // field_names is non-optional and must stay 1:1 with
                    // field_types; map an unnamed value slot to "" and a trailing
                    // error slot to the "!" placeholder (identified by position,
                    // never by this name — see errorChannelOf).
                    const nm = try self.allocator.alloc([]const u8, param_names.items.len);
                    for (param_names.items, 0..) |pn, i| {
                        nm[i] = pn orelse (if (last_is_err and i == param_names.items.len - 1) "!" else "");
                    }
                    fnames = nm;
                }
                const field_types = try param_types.toOwnedSlice(self.allocator);
                // ≥2 value slots → multi-return signature; a lone `(T, !)` is just
                // a single-value failable (= `-> T !`), a plain failable tuple.
                if (value_count >= 2) {
                    return try self.createNode(start, .{ .return_type_expr = .{
                        .field_types = field_types,
                        .field_names = fnames,
                        .field_defaults = if (any_default) try param_defaults.toOwnedSlice(self.allocator) else null,
                    } });
                }
                return try self.createNode(start, .{ .tuple_type_expr = .{
                    .field_types = field_types,
                    .field_names = fnames,
                } });
            }
            // Anything else (a `(T,)` 1-tuple, a spread): the bare-paren tuple
            // grammar is gone — tuple VALUE types are written `Tuple( … )`.
            return self.fail("tuple types use `Tuple( … )` (e.g. `Tuple(A, B)`)");
        }

        if (self.current.tag.isTypeKeyword() or self.isIdentLike()) {
            // A backtick raw identifier (`` `i2 ``) in type position is the
            // LITERAL name `i2` used as a type reference — never the builtin /
            // reserved keyword. The raw flag rides the type ATOM through the
            // SAME qualified-path / `Closure` / parameterized continuations as a
            // bare name (so `` `i2(i64) ``, `` `i2.Inner ``, `` *`i2 `` all
            // parse); it is threaded onto the final `type_expr` /
            // `parameterized_type_expr` so resolution skips the builtin
            // classifier and looks up a `` `i2 ``-declared type.
            const atom_is_raw = self.current.is_raw;
            var name = self.tokenSlice(self.current);
            self.advance();

            // Qualified name: ns.Type or ns.Type(args)
            while (self.current.tag == .dot) {
                const dot_lexer = self.lexer;
                const dot_current = self.current;
                const dot_prev_end = self.prev_end;
                self.advance();
                if (self.isIdentLike() or self.current.tag.isTypeKeyword()) {
                    name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, self.tokenSlice(self.current) });
                    self.advance();
                } else {
                    // Not a qualified name continuation — restore the dot
                    self.lexer = dot_lexer;
                    self.current = dot_current;
                    self.prev_end = dot_prev_end;
                    break;
                }
            }

            // Tuple type: `Tuple(A, B)` / `Tuple(T)` / `Tuple()` /
            //   named `Tuple(x: A, y: B)` / pack `Tuple(..Ts)` / `Tuple(..F(Ts))`.
            //   Magic contextual id — only a `Tuple` IMMEDIATELY followed by `(`
            //   builds a tuple type; a bare `Tuple` stays an ordinary identifier
            //   (mirrors `Closure`). Lowers to the SAME `tuple_type_expr` the
            //   inline `(A, B)` / `(x: A, y: B)` / `(..Ts)` forms produce.
            //   Unlike `Closure`, a trailing `->` is REJECTED (no return type).
            if (std.mem.eql(u8, name, "Tuple") and self.current.tag == .l_paren) {
                return self.parseTupleTypeBody(start);
            }

            // Closure type: Closure(params...) -> R
            //   Variadic-pack trailing form: `Closure(Prefix..., ..$pack) -> R`
            //   binds `pack` to a heterogeneous comptime type list at impl
            //   match time (see plan: variadic heterogeneous type packs).
            if (std.mem.eql(u8, name, "Closure") and self.current.tag == .l_paren) {
                return self.parseClosureTypeBody(start);
            }

            // Parameterized type: Vector(N, T) or later generic struct instantiation
            if (self.current.tag == .l_paren) {
                self.advance(); // skip '('
                var args = std.ArrayList(*Node).empty;
                while (self.current.tag != .r_paren and self.current.tag != .eof) {
                    if (args.items.len > 0) {
                        try self.expect(.comma);
                    }
                    // Pack-spread type arg: `Combined($R, ..sources.T)`.
                    if (self.current.tag == .dot_dot) {
                        const sp_start = self.current.loc.start;
                        self.advance(); // skip '..'
                        const operand = try self.parseTypeExpr();
                        try args.append(self.allocator, try self.createNode(sp_start, .{ .spread_expr = .{ .operand = operand } }));
                        continue;
                    }
                    // An arg is either a TYPE (`f32`, `*T`, `[]u8`, `List(T)`) or a
                    // compile-time integer expression in a value position — a
                    // `Vector` lane count or a generic `$N: u32` arg: `Vector(N, f32)`,
                    // `Vector(M + 1, f32)`. Parse the primary as a literal / type,
                    // then continue as a const-int expression iff an arithmetic
                    // operator follows. A complete type arg is always followed by
                    // `,` / `)`, so `parseBinaryRhs` is a no-op for plain types and
                    // the continuation is unambiguous; `Prec.additive` bounds it to
                    // `+ - * / %`. The shared evaluator folds the expression; a
                    // non-const value position is diagnosed during lowering.
                    var arg: *Node = undefined;
                    if (self.current.tag == .int_literal) {
                        const arg_start = self.current.loc.start;
                        const text = self.tokenSlice(self.current);
                        // Parse the full u64 range (was i64 — values above i64.max
                        // were previously unrepresentable here) and store the bit
                        // pattern, matching the main int-literal path.
                        const value: i64 = @bitCast(self.parseIntLiteralText(text) orelse {
                            return self.fail("invalid integer literal in type argument");
                        });
                        self.advance();
                        arg = try self.createNode(arg_start, .{ .int_literal = .{ .value = value } });
                    } else if (self.current.tag == .char_literal) {
                        // A char literal in a value position (`Buf('A')`) is a
                        // compile-time integer code point — decode it the same
                        // way the primary-expression path does and emit a
                        // `char_literal` node (keeps the `c…` value mangle in
                        // generics.zig distinct from the integer instantiation).
                        const arg_start = self.current.loc.start;
                        const raw = self.tokenSlice(self.current);
                        const inner = raw[1 .. raw.len - 1];
                        const value = unescape.decodeCharLiteral(inner) catch |err| {
                            return self.fail(unescape.charLiteralReason(err));
                        };
                        self.advance();
                        arg = try self.createNode(arg_start, .{ .char_literal = .{ .value = value, .raw = inner } });
                    } else {
                        arg = try self.parseTypeExpr();
                    }
                    arg = try self.parseBinaryRhs(arg, Prec.additive);
                    try args.append(self.allocator, arg);
                }
                try self.expect(.r_paren);
                return try self.createNode(start, .{ .parameterized_type_expr = .{
                    .name = name,
                    .args = try args.toOwnedSlice(self.allocator),
                    .is_raw = atom_is_raw,
                } });
            }

            // Mark as generic if name matches an enclosing struct's type param
            var is_struct_generic = false;
            for (self.struct_type_params) |tp| {
                if (std.mem.eql(u8, tp, name)) {
                    is_struct_generic = true;
                    break;
                }
            }
            return try self.createNode(start, .{ .type_expr = .{ .name = name, .is_generic = is_struct_generic, .is_raw = atom_is_raw } });
        }
        // Inline struct type in type position: struct { ... }
        if (self.current.tag == .kw_struct) {
            return try self.parseStructDecl("__anon", start, false);
        }
        // Inline C-style union in type position: union { ... }
        if (self.current.tag == .kw_union) {
            return try self.parseUnionDecl("__anon", start, false);
        }
        // Inline enum type in type position: enum { ... }
        if (self.current.tag == .kw_enum) {
            return try self.parseEnumDecl("__anon", start, false);
        }
        return self.fail("expected type name");
    }

    fn parseEnumDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'enum'

        // Check for 'flags' modifier: enum flags { ... }
        var is_flags = false;
        if (self.current.tag == .identifier and std.mem.eql(u8, self.tokenSlice(self.current), "flags")) {
            is_flags = true;
            self.advance();
        }

        // Check for optional backing type: enum u8 { ... } or enum flags u32 { ... }
        var backing_type: ?*Node = null;
        if (self.current.tag != .l_brace) {
            backing_type = try self.parseTypeExpr();
        }

        try self.expect(.l_brace);
        var variant_names = std.ArrayList([]const u8).empty;
        var variant_types = std.ArrayList(?*Node).empty;
        var variant_values = std.ArrayList(?*Node).empty;
        var has_any_type = false;
        var has_any_value = false;
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            if (self.current.tag != .identifier) {
                return self.fail("expected variant name");
            }
            try variant_names.append(self.allocator, self.tokenSlice(self.current));
            self.advance();
            if (self.current.tag == .colon_colon) {
                // Explicit value: name :: expr;  or  name :: expr: type;
                self.advance();
                const val_expr = try self.parseExpr();
                try variant_values.append(self.allocator, val_expr);
                has_any_value = true;
                // Check for payload type after value: name :: 0x300: KeyData
                if (self.current.tag == .colon) {
                    if (is_flags) {
                        return self.fail("flags enum variants cannot have payloads");
                    }
                    self.advance();
                    const vtype = try self.parseTypeExpr();
                    try variant_types.append(self.allocator, vtype);
                    has_any_type = true;
                } else {
                    try variant_types.append(self.allocator, null);
                }
            } else if (self.current.tag == .colon) {
                // Typed variant: name: type;
                if (is_flags) {
                    return self.fail("flags enum variants cannot have payloads");
                }
                self.advance();
                const vtype = try self.parseTypeExpr();
                try variant_types.append(self.allocator, vtype);
                try variant_values.append(self.allocator, null);
                has_any_type = true;
            } else {
                // Void variant: name;
                try variant_types.append(self.allocator, null);
                try variant_values.append(self.allocator, null);
            }
            if (self.current.tag == .semicolon) {
                self.advance();
            }
        }
        try self.expect(.r_brace);
        // Always produce enum_decl; variant_types distinguishes payload-less from tagged
        return try self.createNode(start_pos, .{ .enum_decl = .{
            .name = name,
            .variant_names = try variant_names.toOwnedSlice(self.allocator),
            .variant_types = if (has_any_type) try variant_types.toOwnedSlice(self.allocator) else &.{},
            .is_flags = is_flags,
            .variant_values = if (has_any_value) try variant_values.toOwnedSlice(self.allocator) else &.{},
            .backing_type = backing_type,
            .is_raw = name_is_raw,
        } });
    }

    fn parseErrorSetDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'error'
        try self.expect(.l_brace);
        var tag_names = std.ArrayList([]const u8).empty;
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            if (tag_names.items.len > 0) {
                try self.expect(.comma);
                if (self.current.tag == .r_brace) break; // trailing comma ok
            }
            if (self.current.tag != .identifier) {
                return self.fail("expected error tag name");
            }
            try tag_names.append(self.allocator, self.tokenSlice(self.current));
            self.advance();
        }
        try self.expect(.r_brace);
        // Accept an optional trailing `;` — error-set decls read like value
        // bindings and are commonly written `Foo :: error { ... };`.
        if (self.current.tag == .semicolon) self.advance();
        return try self.createNode(start_pos, .{ .error_set_decl = .{
            .name = name,
            .tag_names = try tag_names.toOwnedSlice(self.allocator),
            .is_raw = name_is_raw,
        } });
    }

    fn parseUnionDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'union'
        try self.expect(.l_brace);
        var field_names = std.ArrayList([]const u8).empty;
        var field_types = std.ArrayList(*Node).empty;
        var anon_idx: u32 = 0;
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            // Anonymous struct field: struct { x, y: f32; };
            if (self.current.tag == .kw_struct) {
                const anon_field = try std.fmt.allocPrint(self.allocator, "__anon_{d}", .{anon_idx});
                anon_idx += 1;
                const anon_struct_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, anon_field });
                const struct_node = try self.parseStructDecl(anon_struct_name, self.current.loc.start, false);
                try field_names.append(self.allocator, anon_field);
                try field_types.append(self.allocator, struct_node);
                if (self.current.tag == .semicolon) {
                    self.advance();
                }
                continue;
            }
            if (self.current.tag != .identifier) {
                return self.fail("expected field name or 'struct'");
            }
            try field_names.append(self.allocator, self.tokenSlice(self.current));
            self.advance();
            if (self.current.tag != .colon) {
                return self.fail("union fields must have a type");
            }
            self.advance();
            const ftype = try self.parseTypeExpr();
            try field_types.append(self.allocator, ftype);
            if (self.current.tag == .semicolon) {
                self.advance();
            }
        }
        try self.expect(.r_brace);
        return try self.createNode(start_pos, .{ .union_decl = .{
            .name = name,
            .field_names = try field_names.toOwnedSlice(self.allocator),
            .field_types = try field_types.toOwnedSlice(self.allocator),
            .is_raw = name_is_raw,
        } });
    }

    fn parseStructDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'struct'

        // Optional welded-binding annotation: `struct abi(.zig) extern <lib> { … }`.
        // `abi(...)` (the ABI/layout selector) sits before the `extern` linkage
        // keyword, mirroring the fn-decl slot order; the library handle follows.
        // Parse-only for now — no layout/registry semantics yet.
        const struct_abi = try self.parseOptionalAbi();
        const struct_extern = self.parseOptionalExternExport();
        var struct_extern_lib: ?[]const u8 = null;
        if (struct_extern != .none and self.current.tag == .identifier) {
            struct_extern_lib = self.tokenSlice(self.current);
            self.advance();
        }

        // Optional type params: struct($N: u32, $T: Type) { ... }
        var type_params = std.ArrayList(ast.StructTypeParam).empty;
        if (self.current.tag == .l_paren) {
            self.advance(); // skip '('
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (type_params.items.len > 0) {
                    try self.expect(.comma);
                    if (self.current.tag == .r_paren) break;
                }
                // Optional leading `..` — a pack type-param `..$Ts: []Type`
                // (must be the last param; binds the remaining type args).
                var is_variadic = false;
                if (self.current.tag == .dot_dot) {
                    is_variadic = true;
                    self.advance();
                }
                // Expect $name : constraint
                try self.expect(.dollar);
                if (self.current.tag != .identifier) {
                    return self.fail("expected type parameter name after '$'");
                }
                const param_name = self.tokenSlice(self.current);
                self.advance();
                try self.expect(.colon);
                const constraint = try self.parseTypeExpr();
                // Parse optional protocol constraints: $T: Type/Eq/Hashable
                var pc_list = std.ArrayList([]const u8).empty;
                if (constraint.data == .type_expr and std.mem.eql(u8, constraint.data.type_expr.name, "Type")) {
                    while (self.current.tag == .slash) {
                        self.advance(); // skip '/'
                        if (self.current.tag != .identifier) {
                            return self.fail("expected protocol name after '/'");
                        }
                        try pc_list.append(self.allocator, self.tokenSlice(self.current));
                        self.advance();
                    }
                }
                const pc = try pc_list.toOwnedSlice(self.allocator);
                try type_params.append(self.allocator, .{ .name = param_name, .constraint = constraint, .protocol_constraints = pc, .is_variadic = is_variadic });
            }
            try self.expect(.r_paren);
        }

        try self.expect(.l_brace);

        // Set struct type params context so method params can reference T without $
        var tp_names = std.ArrayList([]const u8).empty;
        for (type_params.items) |tp| try tp_names.append(self.allocator, tp.name);
        const saved_struct_type_params = self.struct_type_params;
        self.struct_type_params = tp_names.items;
        defer self.struct_type_params = saved_struct_type_params;

        var field_names = std.ArrayList([]const u8).empty;
        var field_types = std.ArrayList(*Node).empty;
        var field_defaults = std.ArrayList(?*Node).empty;
        var using_entries = std.ArrayList(ast.UsingEntry).empty;
        var methods = std.ArrayList(*Node).empty;
        var constants = std.ArrayList(*Node).empty;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            // Check for #using directive
            if (self.current.tag == .hash_using) {
                self.advance(); // skip #using
                if (self.current.tag != .identifier) {
                    return self.fail("expected type name after '#using'");
                }
                const used_type = self.tokenSlice(self.current);
                self.advance();
                try using_entries.append(self.allocator, .{
                    .insert_index = @intCast(field_names.items.len),
                    .type_name = used_type,
                });
                if (self.current.tag == .semicolon) self.advance();
                continue;
            }

            // Method declaration: name :: (params) -> type { body }
            if (self.current.tag == .identifier and self.peekNext() == .colon_colon) {
                const method_start = self.current.loc.start;
                const method_name = self.tokenSlice(self.current);
                const method_name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
                const method_is_raw = self.current.is_raw;
                self.advance(); // skip name
                self.advance(); // skip ::
                if (self.current.tag == .l_paren and self.isFunctionDef()) {
                    try methods.append(self.allocator, try self.parseFnDecl(method_name, method_name_span, method_is_raw, method_start));
                } else {
                    // Non-function constant: name :: value;
                    const value = try self.parseExpr();
                    if (self.current.tag == .semicolon) self.advance();
                    try constants.append(self.allocator, try self.createNode(method_start, .{ .const_decl = .{
                        .name = method_name,
                        .type_annotation = null,
                        .value = value,
                        .name_span = method_name_span,
                        .is_raw = method_is_raw,
                    } }));
                }
                continue;
            }

            // Parse field group: name1, name2, ...: type (= default)?;
            // Or typed constant: name :Type: value;
            var group_names = std.ArrayList([]const u8).empty;

            if (self.current.tag != .identifier) {
                return self.fail("expected field name in struct");
            }
            const field_start = self.current.loc.start;
            // Captured for the single-name typed-const path (`name :Type: value`)
            // below: a struct-body const binds a name like any other decl, so
            // its name_span + raw flag must travel to the `const_decl` node
            // (finding 1 — they were being dropped to a 1:1 caret / false
            // reserved-name reject).
            const field_name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            const field_is_raw = self.current.is_raw;
            try group_names.append(self.allocator, self.tokenSlice(self.current));
            self.advance();

            while (self.current.tag == .comma) {
                self.advance(); // skip ','
                if (self.current.tag != .identifier) {
                    return self.fail("expected field name after ','");
                }
                try group_names.append(self.allocator, self.tokenSlice(self.current));
                self.advance();
            }

            try self.expect(.colon);
            const field_type = try self.parseTypeExpr();

            // Typed constant: name :Type: value; (second colon after type)
            if (self.current.tag == .colon and group_names.items.len == 1) {
                self.advance(); // skip second ':'
                const value = try self.parseExpr();
                if (self.current.tag == .semicolon) self.advance();
                try constants.append(self.allocator, try self.createNode(field_start, .{ .const_decl = .{
                    .name = group_names.items[0],
                    .type_annotation = field_type,
                    .value = value,
                    .name_span = field_name_span,
                    .is_raw = field_is_raw,
                } }));
                continue;
            }

            // Check for default value: = expr
            var default_val: ?*Node = null;
            if (self.current.tag == .equal) {
                self.advance();
                default_val = try self.parseExpr();
            }

            // All names in the group share the same type and default
            for (group_names.items) |fname| {
                // `_` is an ignore identifier — auto-rename to unique internal name
                const actual_name = if (std.mem.eql(u8, fname, "_"))
                    try std.fmt.allocPrint(self.allocator, "_{d}", .{field_names.items.len})
                else
                    fname;
                try field_names.append(self.allocator, actual_name);
                try field_types.append(self.allocator, field_type);
                try field_defaults.append(self.allocator, default_val);
            }

            if (self.current.tag == .semicolon) {
                self.advance();
            }
        }
        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .struct_decl = .{
            .name = name,
            .field_names = try field_names.toOwnedSlice(self.allocator),
            .field_types = try field_types.toOwnedSlice(self.allocator),
            .field_defaults = try field_defaults.toOwnedSlice(self.allocator),
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .using_entries = try using_entries.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .constants = try constants.toOwnedSlice(self.allocator),
            .abi = struct_abi,
            .extern_lib = struct_extern_lib,
            .is_raw = name_is_raw,
        } });
    }

    fn parseProtocolDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'protocol'

        // Optional type params: protocol(Target: Type, U: Type) { ... }
        // Names are introduced without a `$` sigil (unlike struct's $T) because
        // the parens after `protocol` already mark this as a parameter list.
        var type_params = std.ArrayList(ast.StructTypeParam).empty;
        if (self.current.tag == .l_paren) {
            self.advance(); // skip '('
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (type_params.items.len > 0) {
                    try self.expect(.comma);
                    if (self.current.tag == .r_paren) break;
                }
                if (self.current.tag != .identifier) {
                    return self.fail("expected type parameter name in protocol header");
                }
                const param_name = self.tokenSlice(self.current);
                self.advance();
                try self.expect(.colon);
                const constraint = try self.parseTypeExpr();
                try type_params.append(self.allocator, .{ .name = param_name, .constraint = constraint });
            }
            try self.expect(.r_paren);
        }

        // Protocol attributes: #inline (layout) and #identity (ownership
        // class) — mutually independent, either order.
        var is_inline = false;
        var is_identity = false;
        while (self.current.tag == .hash_inline or self.current.tag == .hash_identity) {
            if (self.current.tag == .hash_inline) {
                if (is_inline) return self.fail("duplicate #inline on protocol");
                is_inline = true;
            } else {
                if (is_identity) return self.fail("duplicate #identity on protocol");
                is_identity = true;
            }
            self.advance();
        }

        try self.expect(.l_brace);

        // Push type-param names into scope so method signatures can refer to them
        // bare (e.g. `convert :: () -> Target` resolves Target as a generic type expr).
        var tp_names = std.ArrayList([]const u8).empty;
        for (type_params.items) |tp| try tp_names.append(self.allocator, tp.name);
        const saved_struct_type_params = self.struct_type_params;
        self.struct_type_params = tp_names.items;
        defer self.struct_type_params = saved_struct_type_params;

        var methods = std.ArrayList(ast.ProtocolMethodDecl).empty;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            // Method: name :: (params) -> type;  or  name :: (params) -> type { body }
            if (self.current.tag != .identifier) {
                return self.fail("expected method name in protocol body");
            }
            const method_name = self.tokenSlice(self.current);
            self.advance();
            try self.expect(.colon_colon);
            try self.expect(.l_paren);

            var param_types = std.ArrayList(*Node).empty;
            var param_names = std.ArrayList([]const u8).empty;
            var param_name_spans = std.ArrayList(ast.Span).empty;
            var param_name_is_raw = std.ArrayList(bool).empty;

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (param_types.items.len > 0) {
                    try self.expect(.comma);
                    if (self.current.tag == .r_paren) break;
                }
                // Parse: name: type
                if (self.current.tag != .identifier and self.current.tag != .kw_Self) {
                    return self.fail("expected parameter name in protocol method");
                }
                const pname = self.tokenSlice(self.current);
                try param_name_spans.append(self.allocator, .{ .start = self.current.loc.start, .end = self.current.loc.end });
                try param_name_is_raw.append(self.allocator, self.current.is_raw);
                self.advance();
                try self.expect(.colon);
                const ptype = try self.parseTypeExpr();
                try param_names.append(self.allocator, pname);
                try param_types.append(self.allocator, ptype);
            }
            try self.expect(.r_paren);

            // Every protocol method must declare its receiver EXPLICITLY as the
            // first parameter — `self: *Self` (or `self: Self`) — matching how
            // `impl` methods and ordinary methods are written. This removes the
            // old implicit-receiver ambiguity (was the first listed param the
            // receiver, or an extra arg?). The receiver is validated and then
            // stripped here, so downstream lowering sees only the EXTRA-arg
            // params, exactly as it did under the implicit form.
            if (param_names.items.len == 0 or !std.mem.eql(u8, param_names.items[0], "self")) {
                return self.fail("protocol method must declare its receiver as the first parameter: `self: *Self` (or `self: Self`)");
            }
            {
                const rtype = param_types.items[0];
                const is_self_val = rtype.data == .type_expr and std.mem.eql(u8, rtype.data.type_expr.name, "Self");
                const is_self_ptr = rtype.data == .pointer_type_expr and
                    rtype.data.pointer_type_expr.pointee_type.data == .type_expr and
                    std.mem.eql(u8, rtype.data.pointer_type_expr.pointee_type.data.type_expr.name, "Self");
                if (!is_self_val and !is_self_ptr) {
                    return self.fail("protocol method receiver must be typed `*Self` or `Self`");
                }
            }

            // Optional return type
            var return_type: ?*Node = null;
            if (self.current.tag == .arrow) {
                self.advance();
                return_type = try self.parseFnReturnType();
            }

            // Optional body (default method) or semicolon
            var default_body: ?*Node = null;
            if (self.current.tag == .l_brace) {
                // A default-method body's declarations are locals.
                const saved_module_if = self.in_module_inline_if;
                self.in_module_inline_if = false;
                defer self.in_module_inline_if = saved_module_if;
                default_body = try self.parseBlock();
            } else {
                if (self.current.tag == .semicolon) self.advance();
            }

            // Strip the receiver (index 0) — the method's stored params are the
            // extra args only.
            const all_param_types = try param_types.toOwnedSlice(self.allocator);
            const all_param_names = try param_names.toOwnedSlice(self.allocator);
            const all_param_name_spans = try param_name_spans.toOwnedSlice(self.allocator);
            const all_param_name_is_raw = try param_name_is_raw.toOwnedSlice(self.allocator);

            try methods.append(self.allocator, .{
                .name = method_name,
                .params = all_param_types[1..],
                .param_names = all_param_names[1..],
                .param_name_spans = all_param_name_spans[1..],
                .param_name_is_raw = all_param_name_is_raw[1..],
                .return_type = return_type,
                .default_body = default_body,
            });
        }

        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .protocol_decl = .{
            .name = name,
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_inline = is_inline,
            .is_identity = is_identity,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .is_raw = name_is_raw,
        } });
    }

    fn runtimeKindForCurrent(self: *Parser) ?ast.RuntimeKind {
        return switch (self.current.tag) {
            .hash_jni_class => .jni_class,
            .hash_jni_interface => .jni_interface,
            .hash_objc_class => .objc_class,
            .hash_objc_protocol => .objc_protocol,
            .hash_swift_class => .swift_class,
            .hash_swift_struct => .swift_struct,
            .hash_swift_protocol => .swift_protocol,
            else => null,
        };
    }

    const RuntimeClassPrefix = struct {
        runtime: ast.RuntimeKind,
        is_main: bool,
    };

    /// Recognise an optional sequence of `extern` / `#jni_main` modifiers
    /// followed by a type-introducer directive (`#jni_class`, `#objc_class`,
    /// ...). Returns null if the current position isn't a runtime-class
    /// directive (possibly after modifiers). Consumes the modifier tokens
    /// only when a runtime directive follows; otherwise leaves the parser
    /// state untouched.
    fn tryParseRuntimeClassPrefix(self: *Parser) ?RuntimeClassPrefix {
        // Peek ahead through the optional `#jni_main` modifier to confirm a
        // runtime-class directive follows. (reference vs define is decided by the
        // POSTFIX `extern`/`export` keyword in parseRuntimeClassDecl, never a prefix.)
        var lookahead_idx: usize = 0;
        var is_main = false;
        while (true) {
            const tag = self.peekTag(lookahead_idx);
            switch (tag) {
                .hash_jni_main => {
                    is_main = true;
                    lookahead_idx += 1;
                },
                else => break,
            }
        }
        const runtime = self.runtimeKindForOffset(lookahead_idx) orelse return null;
        // Commit: consume modifier tokens.
        var i: usize = 0;
        while (i < lookahead_idx) : (i += 1) self.advance();
        return .{ .runtime = runtime, .is_main = is_main };
    }

    fn peekTag(self: *Parser, offset: usize) Tag {
        if (offset == 0) return self.current.tag;
        var lexer_copy = self.lexer;
        var tok: Token = undefined;
        var i: usize = 0;
        while (i < offset) : (i += 1) {
            tok = lexer_copy.next();
        }
        return tok.tag;
    }

    /// With `self.current` at `(`, true iff the parens enclose exactly a single
    /// identifier — `( ident )`. Distinguishes a match-arm payload capture from
    /// a parenthesized / tuple arm-value expression (`(5)`, `(a, b)`).
    fn isLoneIdentParen(self: *Parser) bool {
        return self.peekTag(1) == .identifier and self.peekTag(2) == .r_paren;
    }

    fn runtimeKindForOffset(self: *Parser, offset: usize) ?ast.RuntimeKind {
        const tag = self.peekTag(offset);
        return switch (tag) {
            .hash_jni_class => .jni_class,
            .hash_jni_interface => .jni_interface,
            .hash_objc_class => .objc_class,
            .hash_objc_protocol => .objc_protocol,
            .hash_swift_class => .swift_class,
            .hash_swift_struct => .swift_struct,
            .hash_swift_protocol => .swift_protocol,
            else => null,
        };
    }

    fn parseRuntimeClassDecl(self: *Parser, name: []const u8, start_pos: u32, runtime: ast.RuntimeKind, is_main: bool, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip directive token

        try self.expect(.l_paren);
        if (self.current.tag != .string_literal) {
            return self.fail("expected string literal runtime-class type path after directive");
        }
        const raw = self.tokenSlice(self.current);
        const runtime_path = raw[1 .. raw.len - 1];
        self.advance();
        try self.expect(.r_paren);

        // The postfix `extern` / `export` modifier after the `#objc_class("X")`
        // directive (mirrors `struct #compiler` postfix placement):
        //   `… extern { … }`  ⇒ reference an existing runtime class.
        //   `… export { … }`  ⇒ define + register a new sx class (the default).
        // Maps onto `is_extern`, threaded into the runtime_class_decl node.
        var is_extern_eff = false;
        if (self.current.tag == .kw_extern or self.current.tag == .kw_export) {
            is_extern_eff = self.current.tag == .kw_extern;
            self.advance();
        }

        try self.expect(.l_brace);

        var members = std.ArrayList(ast.RuntimeClassMember).empty;
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            // #extends Alias;  or  #implements Alias;
            if (self.current.tag == .hash_extends or self.current.tag == .hash_implements) {
                const is_extends = self.current.tag == .hash_extends;
                self.advance();
                if (self.current.tag != .identifier) {
                    return self.fail(if (is_extends) "expected superclass alias after '#extends'" else "expected interface alias after '#implements'");
                }
                const alias = self.tokenSlice(self.current);
                self.advance();
                try self.expect(.semicolon);
                try members.append(self.allocator, if (is_extends)
                    .{ .extends = alias }
                else
                    .{ .implements = alias });
                continue;
            }

            // Field: name: Type;       (instance field — JNI Get/Set<Type>Field)
            // Method: name :: (args...) -> Ret;
            if (self.current.tag != .identifier) {
                return self.fail("expected member name in '#jni_class' body");
            }
            const member_name = self.tokenSlice(self.current);
            self.advance();

            if (self.current.tag == .colon) {
                self.advance(); // consume `:`
                const field_type = try self.parseTypeExpr();

                // M2.2 — optional `#property[(modifier, modifier, ...)]`
                // directive after the field type. Synthesizes Obj-C
                // getter/setter dispatch at access sites.
                var is_property = false;
                var property_modifiers = std.ArrayList([]const u8).empty;
                if (self.current.tag == .hash_property) {
                    is_property = true;
                    self.advance();
                    if (self.current.tag == .l_paren) {
                        self.advance(); // consume `(`
                        while (self.current.tag != .r_paren and self.current.tag != .eof) {
                            if (property_modifiers.items.len > 0) {
                                try self.expect(.comma);
                                if (self.current.tag == .r_paren) break;
                            }
                            if (self.current.tag != .identifier) {
                                return self.fail("expected property modifier name (strong, weak, copy, readonly, ...)");
                            }
                            const mod_name = self.tokenSlice(self.current);
                            self.advance();
                            // Optional argument: getter("name") / setter("name")
                            // — parsed but stored as part of the modifier string
                            // for now (M2.2 first pass; full attribute handling
                            // arrives with M4 ARC wiring).
                            if (self.current.tag == .l_paren) {
                                self.advance();
                                if (self.current.tag != .string_literal) {
                                    return self.fail("expected string literal argument for property modifier");
                                }
                                self.advance();
                                try self.expect(.r_paren);
                            }
                            try property_modifiers.append(self.allocator, mod_name);
                        }
                        try self.expect(.r_paren);
                    }
                }

                try self.expect(.semicolon);
                try members.append(self.allocator, .{ .field = .{
                    .name = member_name,
                    .field_type = field_type,
                    .is_property = is_property,
                    .property_modifiers = try property_modifiers.toOwnedSlice(self.allocator),
                } });
                continue;
            }

            try self.expect(.colon_colon);

            // M2.1(a) — class-level constant `name :: Type = expr;` inside
            // a `#objc_class` block. Reframed as a synthesized class method
            // with an expression body (`name :: () -> Type => expr;`) so
            // the rest of the M1.2 class-synthesis pipeline picks it up:
            // a class-method IMP is emitted and registered on the metaclass.
            // Apple's runtime calls the IMP from `[Cls foo]` — there's no
            // runtime-level distinction between a class-level constant and
            // a niladic class method, just a difference in source spelling.
            if (self.current.tag != .l_paren) {
                const ret_type = try self.parseTypeExpr();
                try self.expect(.equal);
                const expr_node = try self.parseExpr();
                try self.expect(.semicolon);
                const stmts = try self.allocator.alloc(*Node, 1);
                stmts[0] = expr_node;
                const block_node = try self.createNode(expr_node.span.start, .{ .block = .{ .stmts = stmts, .produces_value = true } });
                try members.append(self.allocator, .{ .method = .{
                    .name = member_name,
                    .params = &.{},
                    .param_names = &.{},
                    .param_name_spans = &.{},
                    .return_type = ret_type,
                    .is_static = true,
                    .jni_descriptor_override = null,
                    .selector_override = null,
                    .body = block_node,
                } });
                continue;
            }

            try self.expect(.l_paren);

            var param_types = std.ArrayList(*Node).empty;
            var param_names = std.ArrayList([]const u8).empty;
            var param_name_spans = std.ArrayList(ast.Span).empty;
            var param_name_is_raw = std.ArrayList(bool).empty;
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (param_types.items.len > 0) {
                    try self.expect(.comma);
                    if (self.current.tag == .r_paren) break;
                }
                if (self.current.tag != .identifier and self.current.tag != .kw_Self) {
                    return self.fail("expected parameter name in '#jni_class' method");
                }
                const pname = self.tokenSlice(self.current);
                try param_name_spans.append(self.allocator, .{ .start = self.current.loc.start, .end = self.current.loc.end });
                try param_name_is_raw.append(self.allocator, self.current.is_raw);
                self.advance();
                try self.expect(.colon);
                const ptype = try self.parseTypeExpr();
                try param_names.append(self.allocator, pname);
                try param_types.append(self.allocator, ptype);
            }
            try self.expect(.r_paren);

            // Instance vs class method is determined by the first param's
            // TYPE: `*Self` (pointer-to-Self) ⇒ instance method, anything
            // else (including a method with no params at all) ⇒ class
            // method. Keying on the type, not the param name, means the
            // user can call the receiver whatever they like — `this`,
            // `me`, etc. — without changing the dispatch shape.
            const is_static = blk: {
                if (param_types.items.len == 0) break :blk true;
                const first = param_types.items[0];
                if (first.data != .pointer_type_expr) break :blk true;
                const pointee = first.data.pointer_type_expr.pointee_type;
                if (pointee.data != .type_expr) break :blk true;
                break :blk !std.mem.eql(u8, pointee.data.type_expr.name, "Self");
            };

            var return_type: ?*Node = null;
            if (self.current.tag == .arrow) {
                self.advance();
                return_type = try self.parseFnReturnType();
            }

            // Optional `#jni_method_descriptor("(Sig)Ret")` — explicit JNI descriptor override.
            var desc_override: ?[]const u8 = null;
            if (self.current.tag == .hash_jni_method_descriptor) {
                self.advance(); // skip `#jni_method_descriptor`
                try self.expect(.l_paren);
                if (self.current.tag != .string_literal) {
                    return self.fail("expected string literal JNI descriptor after '#jni_method_descriptor('");
                }
                const raw_desc = self.tokenSlice(self.current);
                desc_override = raw_desc[1 .. raw_desc.len - 1];
                self.advance();
                try self.expect(.r_paren);
            }

            // Optional `#selector("explicit:string")` — explicit Obj-C selector override
            // (Phase 3.2). Same slot as the JNI descriptor; they're not mutually
            // exclusive at parse time though they belong to different runtimes.
            var sel_override: ?[]const u8 = null;
            if (self.current.tag == .hash_selector) {
                self.advance(); // skip `#selector`
                try self.expect(.l_paren);
                if (self.current.tag != .string_literal) {
                    return self.fail("expected string literal selector after '#selector('");
                }
                const raw_sel = self.tokenSlice(self.current);
                sel_override = raw_sel[1 .. raw_sel.len - 1];
                self.advance();
                try self.expect(.r_paren);
            }

            // Method body is optional: `;` → declaration (extern or inherited
            // method we just want to call); `{ ... }` → sx-side block body
            // for sx-defined classes; `=> expr;` → expression-body form
            // (M1.0), lowered as a single-statement block holding `expr`.
            var body_node: ?*Node = null;
            if (self.current.tag == .l_brace) {
                // A runtime-class method body's declarations are locals.
                const saved_module_if = self.in_module_inline_if;
                self.in_module_inline_if = false;
                defer self.in_module_inline_if = saved_module_if;
                body_node = try self.parseBlock();
            } else if (self.current.tag == .fat_arrow) {
                self.advance();
                const expr = try self.parseExpr();
                try self.expect(.semicolon);
                const stmts = try self.allocator.alloc(*Node, 1);
                stmts[0] = expr;
                body_node = try self.createNode(expr.span.start, .{ .block = .{ .stmts = stmts, .produces_value = true } });
            } else {
                try self.expect(.semicolon);
            }

            try members.append(self.allocator, .{ .method = .{
                .name = member_name,
                .params = try param_types.toOwnedSlice(self.allocator),
                .param_names = try param_names.toOwnedSlice(self.allocator),
                .param_name_spans = try param_name_spans.toOwnedSlice(self.allocator),
                .param_name_is_raw = try param_name_is_raw.toOwnedSlice(self.allocator),
                .return_type = return_type,
                .is_static = is_static,
                .jni_descriptor_override = desc_override,
                .selector_override = sel_override,
                .body = body_node,
            } });
        }
        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .runtime_class_decl = .{
            .name = name,
            .runtime_path = runtime_path,
            .runtime = runtime,
            .members = try members.toOwnedSlice(self.allocator),
            .is_extern = is_extern_eff,
            .is_main = is_main,
            .is_raw = name_is_raw,
        } });
    }

    fn parseImplBlock(self: *Parser, start_pos: u32) anyerror!*Node {
        self.advance(); // skip 'impl'

        // Protocol name
        if (self.current.tag != .identifier) {
            return self.fail("expected protocol name after 'impl'");
        }
        const protocol_name = self.tokenSlice(self.current);
        self.advance();

        // Optional protocol type args: impl Into(Block) for ...
        var protocol_type_args = std.ArrayList(*Node).empty;
        if (self.current.tag == .l_paren) {
            self.advance(); // skip '('
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (protocol_type_args.items.len > 0) {
                    try self.expect(.comma);
                    if (self.current.tag == .r_paren) break;
                }
                try protocol_type_args.append(self.allocator, try self.parseTypeExpr());
            }
            try self.expect(.r_paren);
        }

        // 'for' — note: 'for' is a keyword (kw_for), not an identifier
        if (self.current.tag != .kw_for) {
            return self.fail("expected 'for' after protocol name in impl block");
        }
        self.advance();

        // Source-type spelling. For parameterised protocols we accept any TypeExpr
        // (`Closure(...) -> R`, `*T`, etc.). For nullary protocols we keep the
        // legacy identifier-only path so existing `impl P for SomeStruct` keeps
        // working unchanged (the parser doesn't try to over-parse trailing tokens).
        var target_type: []const u8 = "";
        var target_type_expr: ?*Node = null;
        var target_type_params = std.ArrayList(ast.StructTypeParam).empty;

        if (protocol_type_args.items.len > 0) {
            // Parameterised protocol — source is a general TypeExpr.
            target_type_expr = try self.parseTypeExpr();
            // Synthesize a string view of the source for back-compat consumers
            // (LSP hover, etc.). The semantic key for the impl map uses
            // structural mangling, not this string.
            if (target_type_expr.?.data == .type_expr) {
                target_type = target_type_expr.?.data.type_expr.name;
            }
        } else {
            // Legacy nullary-protocol path: single identifier source.
            if (self.current.tag != .identifier and !self.current.tag.isTypeKeyword()) {
                return self.fail("expected type name after 'for'");
            }
            target_type = self.tokenSlice(self.current);
            self.advance();

            // Optional type params: impl Protocol for List($T)
            if (self.current.tag == .l_paren) {
                self.advance(); // skip '('
                while (self.current.tag != .r_paren and self.current.tag != .eof) {
                    if (target_type_params.items.len > 0) {
                        try self.expect(.comma);
                        if (self.current.tag == .r_paren) break;
                    }
                    try self.expect(.dollar);
                    if (self.current.tag != .identifier) {
                        return self.fail("expected type parameter name after '$'");
                    }
                    const param_name = self.tokenSlice(self.current);
                    self.advance();
                    // Optional constraint — for now just use Type
                    const constraint = try self.createNode(self.current.loc.start, .{ .type_expr = .{ .name = "Type" } });
                    try target_type_params.append(self.allocator, .{ .name = param_name, .constraint = constraint });
                }
                try self.expect(.r_paren);
            }
        }

        try self.expect(.l_brace);

        // Set struct type params context so method params can reference T without $
        var tp_names = std.ArrayList([]const u8).empty;
        for (target_type_params.items) |tp| try tp_names.append(self.allocator, tp.name);
        const saved_struct_type_params = self.struct_type_params;
        self.struct_type_params = tp_names.items;
        defer self.struct_type_params = saved_struct_type_params;

        var methods = std.ArrayList(*Node).empty;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            // Method: name :: (params) -> type { body }
            if (self.current.tag != .identifier) {
                return self.fail("expected method name in impl block");
            }
            const method_start = self.current.loc.start;
            const method_name = self.tokenSlice(self.current);
            const method_name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            const method_is_raw = self.current.is_raw;
            self.advance();
            try self.expect(.colon_colon);

            if (self.current.tag == .l_paren and self.isFunctionDef()) {
                try methods.append(self.allocator, try self.parseFnDecl(method_name, method_name_span, method_is_raw, method_start));
            } else {
                return self.fail("expected function declaration in impl block");
            }
        }

        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .impl_block = .{
            .protocol_name = protocol_name,
            .target_type = target_type,
            .target_type_params = try target_type_params.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .protocol_type_args = try protocol_type_args.toOwnedSlice(self.allocator),
            .target_type_expr = target_type_expr,
        } });
    }

    fn parseStructLiteral(self: *Parser, struct_name: ?[]const u8, type_expr: ?*Node, start_pos: u32) anyerror!*Node {
        try self.expect(.l_brace);

        var field_inits = std.ArrayList(ast.StructFieldInit).empty;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            if (field_inits.items.len > 0) {
                try self.expect(.comma);
                if (self.current.tag == .r_brace) break;
            }

            // Spread element: `.{ ..xs }` / `.{ a, ..t, b }` — reuses
            // `spread_expr` as a positional init, mirroring `.( )`'s spread
            // (tuple/pack spreads route in lowering).
            if (self.current.tag == .dot_dot) {
                const sp_start = self.current.loc.start;
                self.advance(); // skip '..'
                const operand = try self.parseExpr();
                const spread = try self.createNode(sp_start, .{ .spread_expr = .{ .operand = operand } });
                try field_inits.append(self.allocator, .{ .name = null, .value = spread });
                continue;
            }

            // Check if this is a named field: identifier followed by '='
            if (self.current.tag == .identifier) {
                const saved_lexer = self.lexer;
                const saved_current = self.current;
                const saved_prev_end = self.prev_end;
                const fname = self.tokenSlice(self.current);
                const ident_start = self.current.loc.start;
                self.advance();

                if (self.current.tag == .equal) {
                    // Named field: name = expr
                    self.advance(); // skip '='
                    const value = try self.parseExpr();
                    try field_inits.append(self.allocator, .{ .name = fname, .value = value });
                    continue;
                } else if (self.current.tag == .comma or self.current.tag == .r_brace) {
                    // Shorthand: just an identifier (name = identifier with same name)
                    const ident_node = try self.createNode(ident_start, .{ .identifier = .{ .name = fname } });
                    try field_inits.append(self.allocator, .{ .name = fname, .value = ident_node, .was_shorthand = true });
                    continue;
                }

                // Not named — backtrack and parse as positional expression
                self.lexer = saved_lexer;
                self.current = saved_current;
                self.prev_end = saved_prev_end;
            }

            // Positional field: just an expression
            const value = try self.parseExpr();
            try field_inits.append(self.allocator, .{ .name = null, .value = value });
        }
        try self.expect(.r_brace);

        // Optional init block: T.{ fields } { stmts }
        const init_block: ?*Node = if (self.current.tag == .l_brace and !self.in_if_condition)
            try self.parseBlock()
        else
            null;

        return try self.createNode(start_pos, .{ .struct_literal = .{
            .struct_name = struct_name,
            .type_expr = type_expr,
            .field_inits = try field_inits.toOwnedSlice(self.allocator),
            .init_block = init_block,
        } });
    }

    fn reconstructQualifiedName(self: *Parser, node: *Node) ![]const u8 {
        if (node.data == .identifier) return node.data.identifier.name;
        if (node.data == .field_access) {
            const obj_name = try self.reconstructQualifiedName(node.data.field_access.object);
            return std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ obj_name, node.data.field_access.field });
        }
        return error.ParseError;
    }

    /// Parse a parenthesized parameter list: `(name: type, $T: Type, args: ..Any)`
    /// Handles `$` generic params, `..` variadic marker, and comptime detection.
    /// Expects opening `(` already NOT consumed — this function consumes `(` through `)`.
    fn parseParams(self: *Parser) anyerror![]const ast.Param {
        try self.expect(.l_paren);
        var params = std.ArrayList(ast.Param).empty;
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            if (params.items.len > 0) {
                try self.expect(.comma);
                if (self.current.tag == .r_paren) break;
            }
            // Leading `..` marks a variadic param at the binding site
            // (e.g., `..$args` heterogeneous pack, or future homogeneous
            // `..args: []$T`). The old `args: ..T` form keeps its marker
            // after the colon (handled below).
            var is_variadic = false;
            if (self.current.tag == .dot_dot) {
                is_variadic = true;
                self.advance();
            }
            var is_ct_param = false;
            if (self.current.tag == .dollar) {
                is_ct_param = true;
                self.advance();
            }
            if (!self.isIdentLike()) {
                return self.fail("expected parameter name");
            }
            const param_name = self.tokenSlice(self.current);
            const param_name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            const param_is_raw = self.current.is_raw;
            self.advance();
            // Optional type annotation: if no ':', infer type from context
            if (self.current.tag != .colon) {
                const inferred_node = try self.createNode(param_name_span.start, .{ .inferred_type = {} });
                try params.append(self.allocator, .{ .name = param_name, .name_span = param_name_span, .type_expr = inferred_node, .is_variadic = is_variadic, .is_comptime = is_ct_param, .is_raw = param_is_raw });
                continue;
            }
            self.advance(); // consume ':'
            const param_type = try self.parseTypeExpr();
            var is_comptime_param = false;
            if (is_ct_param and param_type.data == .type_expr) {
                const constraint_name = param_type.data.type_expr.name;
                if (std.mem.eql(u8, constraint_name, "Type")) {
                    // Parse optional protocol constraints: $T: Type/Eq/Hashable
                    var constraints = std.ArrayList([]const u8).empty;
                    while (self.current.tag == .slash) {
                        self.advance(); // skip '/'
                        if (self.current.tag != .identifier) {
                            return self.fail("expected protocol name after '/'");
                        }
                        try constraints.append(self.allocator, self.tokenSlice(self.current));
                        self.advance();
                    }
                    const pc = try constraints.toOwnedSlice(self.allocator);
                    param_type.data = .{ .type_expr = .{ .name = param_name, .is_generic = true, .protocol_constraints = pc } };
                } else {
                    is_comptime_param = true;
                }
            }
            // Optional default value: `param: T = expr`. Stored on the Param
            // node; lowering fills it in for callers that omit this positional arg.
            var default_expr: ?*Node = null;
            if (self.current.tag == .equal) {
                self.advance(); // consume '='
                default_expr = try self.parseExpr();
            }
            // Protocol-constrained variadic pack: `..xs: Protocol` — a bare
            // type (not a slice/array) on a non-comptime variadic param. The
            // trailing args each conform to the protocol with their own
            // type-arg. Slice variadics (`..xs: []T`) keep `is_pack == false`.
            const is_pack = is_variadic and !is_comptime_param and switch (param_type.data) {
                .type_expr, .parameterized_type_expr => true,
                else => false,
            };
            try params.append(self.allocator, .{ .name = param_name, .name_span = param_name_span, .type_expr = param_type, .is_variadic = is_variadic, .is_comptime = is_comptime_param, .is_pack = is_pack, .default_expr = default_expr, .is_raw = param_is_raw });
        }
        for (params.items, 0..) |param, i| {
            if (param.is_variadic and i != params.items.len - 1) {
                return self.fail("variadic parameter must be the last parameter");
            }
        }
        try self.expect(.r_paren);
        return try params.toOwnedSlice(self.allocator);
    }

    /// Recursively find all generic type names ($T) in a type expression tree.
    fn collectGenericNames(node: *Node, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
        switch (node.data) {
            .type_expr => |te| {
                if (te.is_generic) list.append(allocator, te.name) catch {};
            },
            .pointer_type_expr => |pte| collectGenericNames(pte.pointee_type, list, allocator),
            .many_pointer_type_expr => |mpte| collectGenericNames(mpte.element_type, list, allocator),
            .slice_type_expr => |ste| collectGenericNames(ste.element_type, list, allocator),
            .array_type_expr => |ate| collectGenericNames(ate.element_type, list, allocator),
            .optional_type_expr => |ote| collectGenericNames(ote.inner_type, list, allocator),
            .parameterized_type_expr => |pte| {
                for (pte.args) |arg| collectGenericNames(arg, list, allocator);
            },
            .tuple_type_expr => |tte| {
                // A failable closure return `Closure() -> $R !E` folds to a
                // `(T, !)` tuple_type_expr (parseFnReturnType), so the `$R`
                // binding site lives inside the tuple's field_types — descend so
                // the value type's generic is still inferred from the call site.
                for (tte.field_types) |ft| collectGenericNames(ft, list, allocator);
            },
            .closure_type_expr => |cte| {
                for (cte.param_types) |pt| collectGenericNames(pt, list, allocator);
                if (cte.return_type) |rt| collectGenericNames(rt, list, allocator);
            },
            .function_type_expr => |fte| {
                for (fte.param_types) |pt| collectGenericNames(pt, list, allocator);
                if (fte.return_type) |rt| collectGenericNames(rt, list, allocator);
            },
            else => {},
        }
    }

    /// Collect generic type params and comptime value params from parameter annotations.
    fn collectTypeParams(self: *Parser, params: []const ast.Param) ![]const ast.StructTypeParam {
        var type_params = std.ArrayList(ast.StructTypeParam).empty;
        var seen = std.StringHashMap(void).init(self.allocator);
        for (params) |param| {
            if (param.is_comptime) {
                if (!seen.contains(param.name)) {
                    try seen.put(param.name, {});
                    try type_params.append(self.allocator, .{ .name = param.name, .constraint = param.type_expr });
                }
            } else {
                // Collect all generic type params found anywhere in the type expression
                var generic_names = std.ArrayList([]const u8).empty;
                collectGenericNames(param.type_expr, &generic_names, self.allocator);
                for (generic_names.items) |gen_name| {
                    if (!seen.contains(gen_name)) {
                        try seen.put(gen_name, {});
                        // Propagate protocol constraints from the TypeExpr if present
                        const pc = if (param.type_expr.data == .type_expr)
                            param.type_expr.data.type_expr.protocol_constraints
                        else
                            &[_][]const u8{};
                        const type_constraint = self.createNode(param.type_expr.span.start, .{ .type_expr = .{ .name = "Type" } }) catch continue;
                        type_params.append(self.allocator, .{ .name = gen_name, .constraint = type_constraint, .protocol_constraints = pc }) catch {};
                    }
                }
            }
        }
        return try type_params.toOwnedSlice(self.allocator);
    }

    fn parseFnDecl(self: *Parser, name: []const u8, name_span: ast.Span, name_is_raw: bool, start_pos: u32) anyerror!*Node {
        const params = try self.parseParams();

        // Optional return type
        var return_type: ?*Node = null;
        if (self.current.tag == .arrow) {
            self.advance();
            return_type = try self.parseFnReturnType();
        }

        // Optional `#get` / `#set` property-accessor marker:
        //   read:  `name :: (self) -> R #get => expr;`   (invoked via `obj.name`)
        //   write: `name :: (self, value: V) #set { … }` (invoked via `obj.name = rhs`)
        // The two share the marker slot; a `#set` has no return type (void) and
        // takes the receiver plus exactly one value parameter.
        var is_get = false;
        var is_set = false;
        if (self.current.tag == .hash_get) {
            is_get = true;
            self.advance();
        } else if (self.current.tag == .hash_set) {
            is_set = true;
            self.advance();
            if (return_type != null)
                return self.fail("a '#set' accessor returns void — drop the '-> T' return type");
            // self + exactly one value parameter. `params` here are the value/
            // receiver params only (type params `$T` are collected separately).
            if (params.len != 2)
                return self.fail("a '#set' accessor takes exactly the receiver and one value parameter");
        }

        // Optional ABI / calling-convention annotation: `abi(.c)` / `abi(.zig)` /
        // `abi(.naked)`. Sits in the postfix slot BEFORE the `extern`/`export`
        // linkage keyword (it is part of the function declaration). `abi(.zig)`
        // marks a binding to the comptime `compiler` library.
        const abi = try self.parseOptionalAbi();

        // Optional postfix linkage modifier: `extern` (import) / `export` (define).
        const extern_export = self.parseOptionalExternExport();

        // `extern` and `export` are mutually exclusive — one declaration is either
        // an import or a definition, never both. Reject the redundant second keyword
        // with a clear message rather than the bare "expected ';'" the body parser
        // would otherwise emit.
        if (extern_export != .none and (self.current.tag == .kw_extern or self.current.tag == .kw_export)) {
            return self.fail("conflicting linkage: 'extern' and 'export' cannot be combined — a declaration is either an import ('extern') or a definition ('export')");
        }

        // Optional `[LIB] ["csym"]` tail after extern/export — a library-alias
        // ident then a C symbol-name string, both optional (mirrors
        // `extern LIB "csym"`). Stored on extern_lib/extern_name; the rename
        // is consumed in `declareFunction`, the lib reference in Part B.
        var extern_lib: ?[]const u8 = null;
        var extern_name: ?[]const u8 = null;
        if (extern_export != .none) {
            if (self.current.tag == .identifier) {
                extern_lib = self.tokenSlice(self.current);
                self.advance();
            }
            if (self.current.tag == .string_literal) {
                const raw = self.tokenSlice(self.current);
                extern_name = raw[1 .. raw.len - 1];
                self.advance();
            }
        }

        // Body: block `{ ... }`, arrow `=> expr;`, intrinsic, or #compiler marker.
        // An `extern` import has NO body — just `;`. The extern_export modifier
        // carries the linkage; we synthesize an empty block as the (non-optional)
        // body placeholder, and lowering routes on the modifier rather than this
        // block (no `*_expr` node — naming-constraint rule). `export` keeps its
        // `{ … }` body and flows through the normal chain below.
        //
        // A function body is never module scope — even inside a module-level
        // `inline if` branch its declarations are locals, so `private` stops
        // being legal here.
        const saved_module_if = self.in_module_inline_if;
        self.in_module_inline_if = false;
        defer self.in_module_inline_if = saved_module_if;
        var is_arrow = false;
        const body = if (extern_export == .extern_) blk: {
            const semi_start = self.current.loc.start;
            try self.expect(.semicolon);
            const stmts = try self.allocator.alloc(*Node, 0);
            break :blk try self.createNode(semi_start, .{ .block = .{ .stmts = stmts, .produces_value = false } });
        } else if (self.current.tag == .kw_intrinsic) blk: {
            const bi_start = self.current.loc.start;
            self.advance();
            try self.expect(.semicolon);
            break :blk try self.createNode(bi_start, .{ .intrinsic_expr = {} });
        } else if (self.current.tag == .fat_arrow) blk: {
            is_arrow = true;
            self.advance();
            const expr = try self.parseExpr();
            try self.expect(.semicolon);
            const stmts = try self.allocator.alloc(*Node, 1);
            stmts[0] = expr;
            const block_start = expr.span.start;
            const block = try self.createNode(block_start, .{ .block = .{ .stmts = stmts, .produces_value = true } });
            break :blk block;
        } else try self.parseBlock();

        const type_params = try self.collectTypeParams(params);

        return try self.createNode(start_pos, .{ .fn_decl = .{
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .type_params = type_params,
            .is_arrow = is_arrow,
            .abi = abi,
            .extern_export = extern_export,
            .extern_lib = extern_lib,
            .extern_name = extern_name,
            .name_span = name_span,
            .is_raw = name_is_raw,
            .is_get = is_get,
            .is_set = is_set,
        } });
    }

    fn parseBlock(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        try self.expect(.l_brace);
        var stmts = std.ArrayList(*Node).empty;
        var produces_value = false;
        var discarded_semi: ?ast.Span = null;
        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);
            // The block's value-ness is its LAST statement's value-ness.
            produces_value = self.last_stmt_produces_value;
            // A discarding `;` is only meaningful when the block has no value.
            discarded_semi = if (produces_value) null else self.last_stmt_semi_loc;
        }
        try self.expect(.r_brace);
        return try self.createNode(start, .{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator), .produces_value = produces_value, .discarded_semi = discarded_semi } });
    }

    /// Consume the terminator after an expression/block-form statement and
    /// record whether the statement is a trailing VALUE (no `;`) or a discarded
    /// statement (`;`). A trailing `;` always discards; otherwise the statement
    /// is the (potential) block value — allowed when it is block-form (where
    /// `;` is optional) or when it is the last thing before `}`.
    fn expectSemicolonAfter(self: *Parser, expr: *Node) anyerror!void {
        const block_form = switch (expr.data) {
            .if_expr => |ie| !ie.is_inline,
            .match_expr, .while_expr, .for_expr, .block, .jni_env_block => true,
            // A call ending in a trailing block reads as a block statement
            // (`vstack(8.0) { … }`) — no `;` required after the `}`.
            .call => |call| call.args.len > 0 and call.args[call.args.len - 1].data == .trailing_block,
            else => false,
        };
        if (self.current.tag == .semicolon) {
            self.last_stmt_semi_loc = .{ .start = self.current.loc.start, .end = self.current.loc.end };
            self.advance(); // explicit terminator → value discarded
            self.last_stmt_produces_value = false;
        } else if (block_form or self.current.tag == .r_brace) {
            // Block-form statements never require `;`; a plain expression may
            // omit it only as the trailing value before `}`. Either way this
            // statement is the block's value (and discards nothing — clear any
            // stale semi location from a nested statement).
            self.last_stmt_produces_value = true;
            self.last_stmt_semi_loc = null;
        } else {
            try self.expect(.semicolon); // emits "expected ;"
        }
    }

    pub fn parseStmt(self: *Parser) anyerror!*Node {
        // Default: a statement discards its value unless `expectSemicolonAfter`
        // marks it a trailing value (no `;`). Non-expression statements (decls,
        // return/raise, break/continue, defer/onfail) never set it, so they
        // correctly leave the enclosing block value-less.
        self.last_stmt_produces_value = false;
        self.last_stmt_semi_loc = null;
        // `#error "msg";` — compile-time diagnostic (fires when reached in live code).
        if (self.current.tag == .hash_error) {
            return self.parseErrorDirective();
        }
        // `#context_extend` is a top-level-only directive (L7): the Context is
        // assembled once per program, so a function-local declaration is
        // meaningless — reject it here with a placement error rather than
        // letting it fall through to a generic expression-parse failure.
        if (self.current.tag == .hash_context_extend) {
            return self.fail("'#context_extend' is only allowed at top level (module scope)");
        }
        // `private` on a statement: legal only inside a MODULE-SCOPE `inline if`
        // branch, whose statements become top-level declarations after comptime
        // flattening. Anywhere else (function/method/lambda bodies) the
        // declaration is a local — visibility does not apply.
        if (self.current.tag == .kw_private) {
            if (!self.in_module_inline_if) {
                return self.fail("'private' is only allowed on module-scope declarations");
            }
            self.advance();
            if (!self.isIdentLike() and self.current.tag != .kw_Self) {
                return self.fail("expected a declaration name after 'private'");
            }
            const decl_start = self.current.loc.start;
            const decl_name = self.tokenSlice(self.current);
            const decl_name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            const decl_is_raw = self.current.is_raw;
            self.advance();
            const node = switch (self.current.tag) {
                .colon_colon => blk: {
                    self.advance();
                    break :blk try self.parseConstBinding(decl_name, decl_name_span, decl_start, decl_is_raw);
                },
                .colon => blk: {
                    self.advance();
                    break :blk try self.parseTypedBinding(decl_name, decl_name_span, decl_start, decl_is_raw);
                },
                .colon_equal => blk: {
                    self.advance();
                    const value = try self.parseExpr();
                    try self.expectSemicolonAfter(value);
                    self.last_stmt_produces_value = false;
                    break :blk try self.createNode(decl_start, .{ .var_decl = .{ .name = decl_name, .name_span = decl_name_span, .type_annotation = null, .value = value, .is_raw = decl_is_raw } });
                },
                else => return self.fail("expected '::', ':=', or ':' after the 'private' declaration name"),
            };
            node.visibility = .private;
            return node;
        }
        // Check if this is a declaration (IDENT followed by ::, :=, or : type)
        if (self.isIdentLike()) {
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_prev_end = self.prev_end;
            const start = self.current.loc.start;
            const name = self.tokenSlice(self.current);
            const name_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            const name_is_raw = self.current.is_raw;
            self.advance();

            if (self.current.tag == .colon_colon) {
                self.advance();
                return self.parseConstBinding(name, name_span, start, name_is_raw);
            }
            if (self.current.tag == .colon_equal) {
                self.advance();
                const value = try self.parseExpr();
                try self.expectSemicolonAfter(value);
                return try self.createNode(start, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = null, .value = value, .is_raw = name_is_raw } });
            }
            if (self.current.tag == .colon) {
                self.advance();
                return self.parseTypedBinding(name, name_span, start, name_is_raw);
            }

            // Multi-target assignment: ident, expr, ... = expr, expr, ...;
            if (self.current.tag == .comma) {
                const first_target = try self.createNode(start, .{ .identifier = .{ .name = name, .is_raw = name_is_raw } });
                return try self.parseMultiAssign(first_target, start);
            }

            // Check for assignment operators
            if (self.isAssignOp()) {
                const op = self.assignOp();
                self.advance();
                const value = try self.parseExpr();
                try self.expect(.semicolon);
                const target = try self.createNode(start, .{ .identifier = .{ .name = name, .is_raw = name_is_raw } });
                return try self.createNode(start, .{ .assignment = .{ .target = target, .op = op, .value = value } });
            }

            // Not a declaration or assignment — backtrack and parse as expression
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.prev_end = saved_prev_end;
        }

        // Return statement: return expr; or return;
        if (self.current.tag == .kw_return) {
            try self.rejectInCleanup("return");
            const start = self.current.loc.start;
            self.advance();
            if (self.current.tag == .semicolon) {
                self.advance();
                return try self.createNode(start, .{ .return_stmt = .{ .value = null } });
            }
            // Comma-separated return list — the bare multi-value `return` form:
            // `return a, b` (positional) / `return x = a, y = b` (named), no `.(…)`
            // tuple literal needed. Each element is `name = expr` (named, like the
            // `.(x = v)` form) or a bare `expr` (positional). A SINGLE positional
            // element is an ordinary single-value return (unchanged); a comma list
            // — or any named element — is a multi-value return, synthesized as the
            // same `tuple_literal` the `.(…)` form produces so the return lowering
            // maps it onto the function's multi-return slots.
            var ret_elems = std.ArrayList(ast.TupleElement).empty;
            var ret_any_named = false;
            while (true) {
                if (self.isIdentLike() and self.peekNext() == .equal) {
                    const fname = self.tokenSlice(self.current);
                    self.advance(); // skip name
                    self.advance(); // skip '='
                    const v = try self.parseExpr();
                    try ret_elems.append(self.allocator, .{ .name = fname, .value = v });
                    ret_any_named = true;
                } else {
                    const v = try self.parseExpr();
                    try ret_elems.append(self.allocator, .{ .name = null, .value = v });
                }
                if (self.current.tag == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
            try self.expect(.semicolon);
            const ret_value: *Node = if (ret_elems.items.len == 1 and !ret_any_named)
                ret_elems.items[0].value
            else
                try self.createNode(start, .{ .tuple_literal = .{ .elements = try ret_elems.toOwnedSlice(self.allocator) } });
            return try self.createNode(start, .{ .return_stmt = .{ .value = ret_value } });
        }

        // Defer statement: defer { body } | defer <expr>;
        // A braced body parses as a full statement block (like `onfail`), so it
        // supports every statement form (destructure, `catch`-statement, …); the
        // bare-expression form keeps its trailing `;`.
        if (self.current.tag == .kw_defer) {
            const start = self.current.loc.start;
            self.advance();
            const saved_defer = self.in_defer_body;
            self.in_defer_body = true;
            defer self.in_defer_body = saved_defer;
            const deferred: *Node = if (self.current.tag == .l_brace)
                try self.parseBlock()
            else blk: {
                const e = try self.parseExpr();
                try self.expect(.semicolon);
                break :blk e;
            };
            return try self.createNode(start, .{ .defer_stmt = .{ .expr = deferred } });
        }

        // Raise statement: raise <expr>;
        if (self.current.tag == .kw_raise) {
            const start = self.current.loc.start;
            if (self.in_onfail_body) {
                return self.fail("`raise` is not allowed inside an `onfail` body — an error during cleanup has no propagation target");
            }
            if (self.in_defer_body) {
                return self.fail("`raise` is not allowed inside a `defer` body — an error during cleanup has no propagation target");
            }
            self.advance();
            const tag_expr = try self.parseExpr();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .raise_stmt = .{ .tag = tag_expr } });
        }

        // Onfail statement: onfail { body } | onfail (e) { body } | onfail <expr>;
        // A binding is present only when an identifier is immediately followed
        // by `{`; otherwise the text after `onfail` is the (no-binding) body.
        if (self.current.tag == .kw_onfail) {
            const start = self.current.loc.start;
            self.advance();
            var binding: ?[]const u8 = null;
            var binding_span: ?ast.Span = null;
            var binding_is_raw = false;
            if (self.current.tag == .identifier and self.peekNext() == .l_brace) {
                return self.fail("the onfail error binding needs parens: `onfail (e) { ... }`");
            }
            // `(e)` followed by `{` is the binding form; any other paren
            // group is an ordinary expression cleanup (`onfail (f());`).
            if (self.current.tag == .l_paren and self.tagAfterParenGroup() == .l_brace) {
                self.advance();
                if (self.current.tag != .identifier) {
                    return self.fail("expected an error binding name in `onfail (e)`");
                }
                binding = self.tokenSlice(self.current);
                binding_span = .{ .start = self.current.loc.start, .end = self.current.loc.end };
                binding_is_raw = self.current.is_raw;
                self.advance();
                try self.expect(.r_paren);
            }
            const saved_onfail = self.in_onfail_body;
            self.in_onfail_body = true;
            defer self.in_onfail_body = saved_onfail;
            const body: *Node = if (self.current.tag == .l_brace)
                try self.parseBlock()
            else blk: {
                const e = try self.parseExpr();
                try self.expect(.semicolon);
                break :blk e;
            };
            return try self.createNode(start, .{ .onfail_stmt = .{ .binding = binding, .binding_span = binding_span, .binding_is_raw = binding_is_raw, .body = body } });
        }

        // Break statement: break;
        if (self.current.tag == .kw_break) {
            try self.rejectInCleanup("break");
            const start = self.current.loc.start;
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .break_expr = {} });
        }

        // Continue statement: continue;
        if (self.current.tag == .kw_continue) {
            try self.rejectInCleanup("continue");
            const start = self.current.loc.start;
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .continue_expr = {} });
        }

        // Insert directive: #insert <expr>;
        if (self.current.tag == .hash_insert) {
            const start = self.current.loc.start;
            self.advance();
            const inner = try self.parseExpr();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .insert_expr = .{ .expr = inner } });
        }

        // `#import "path";` / `#framework "Name";` inside a block body.
        // Only meaningful inside an `inline if OS == ... { ... }` arm —
        // the imports.zig flatten pass (issue-0042) surfaces those
        // declarations to the top level before resolution. Anywhere else
        // these nodes survive into lowering and produce a clear error.
        if (self.current.tag == .hash_import) {
            const start = self.current.loc.start;
            self.advance();
            if (self.current.tag != .string_literal) {
                return self.fail("expected string path after '#import'");
            }
            const raw = self.tokenSlice(self.current);
            const path = raw[1 .. raw.len - 1];
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .import_decl = .{ .path = path, .name = null } });
        }
        if (self.current.tag == .hash_framework) {
            const start = self.current.loc.start;
            self.advance();
            if (self.current.tag != .string_literal) {
                return self.fail("expected string after '#framework'");
            }
            const raw = self.tokenSlice(self.current);
            const fw_name = raw[1 .. raw.len - 1];
            self.advance();
            try self.expect(.semicolon);
            return try self.createNode(start, .{ .framework_decl = .{ .name = fw_name } });
        }

        // inline if — compile-time conditional
        if (self.current.tag == .kw_inline) {
            if (self.peekNext() == .kw_if) {
                self.advance(); // skip 'inline'
                const expr = try self.parseIfExpr();
                if (expr.data == .if_expr) {
                    expr.data.if_expr.is_comptime = true;
                } else if (expr.data == .match_expr) {
                    expr.data.match_expr.is_comptime = true;
                }
                try self.expectSemicolonAfter(expr);
                return expr;
            }
            if (self.peekNext() == .kw_for) {
                self.advance(); // skip 'inline'
                const expr = try self.parseForExpr();
                expr.data.for_expr.is_inline = true;
                try self.expectSemicolonAfter(expr);
                return expr;
            }
        }

        // Block-form if/while/for as statements — parse directly to prevent
        // postfix chaining (e.g. `if cond { ... }.field` being misparsed)
        if (self.current.tag == .kw_if) {
            const expr = try self.parseIfExpr();
            try self.expectSemicolonAfter(expr);
            return expr;
        }
        if (self.current.tag == .kw_while) {
            const expr = try self.parsePrimary();
            try self.expectSemicolonAfter(expr);
            return expr;
        }
        if (self.current.tag == .kw_for) {
            const expr = try self.parsePrimary();
            try self.expectSemicolonAfter(expr);
            return expr;
        }
        if (self.current.tag == .kw_push) {
            return try self.parsePushStmt();
        }

        // Expression statement
        const expr = try self.parseExpr();

        // Multi-target assignment: expr, expr, ... = expr, expr, ...;
        if (self.current.tag == .comma) {
            return try self.parseMultiAssign(expr, expr.span.start);
        }

        // Check for field assignment: expr = value; (e.g. a.b = 1;)
        if (self.isAssignOp()) {
            const op = self.assignOp();
            self.advance();
            const value = try self.parseExpr();
            try self.expect(.semicolon);
            return try self.createNode(expr.span.start, .{ .assignment = .{ .target = expr, .op = op, .value = value } });
        }

        // Block-form if/match/while/bare blocks don't require trailing semicolon
        try self.expectSemicolonAfter(expr);
        return expr;
    }

    // ---- Expression parsing (Pratt / precedence climbing) ----

    pub fn parseExpr(self: *Parser) anyerror!*Node {
        return self.parseBinary(Prec.none);
    }

    fn parseBinary(self: *Parser, min_prec: u8) anyerror!*Node {
        const lhs = try self.parseUnary();
        return self.parseBinaryRhs(lhs, min_prec);
    }

    fn parseBinaryRhs(self: *Parser, initial_lhs: *Node, min_prec: u8) anyerror!*Node {
        var lhs = initial_lhs;

        while (true) {
            // Pipe operator: desugar a |> f(args) → f(a, args), a |> f → f(a).
            // Consumer-aware: the piped LHS goes into the RHS's HEAD call,
            // looking THROUGH a `try` prefix / `catch` postfix / `or` fallback
            // and leaving the wrapper intact:
            //   a |> try f(x)            → try f(a, x)
            //   a |> f(x) catch (e) {...}  → f(a, x) catch (e) {...}
            //   a |> f(x) or default     → f(a, x) or default   (only f gets a)
            if (self.current.tag == .pipe_arrow and Prec.pipe >= min_prec) {
                self.advance();
                const rhs = try self.parseBinary(Prec.pipe + 1);
                // Walk through error-handling wrappers to the head call node.
                var head = rhs;
                const head_call: ?*Node = while (true) {
                    switch (head.data) {
                        .call => break head,
                        .try_expr => head = head.data.try_expr.operand,
                        .catch_expr => head = head.data.catch_expr.operand,
                        .binary_op => |bo| {
                            if (bo.op == .or_op) head = bo.lhs else break null;
                        },
                        else => break null,
                    }
                };
                if (head_call) |cn| {
                    // a |> ...f(args)... → ...f(a, args)... (wrapper preserved;
                    // mutating the head call in place updates the wrapper).
                    var new_args = std.ArrayList(*Node).empty;
                    try new_args.append(self.allocator, lhs);
                    for (cn.data.call.args) |arg| try new_args.append(self.allocator, arg);
                    cn.data.call.args = try new_args.toOwnedSlice(self.allocator);
                    lhs = rhs;
                } else {
                    // a |> f → f(a)
                    const args = try self.allocator.alloc(*Node, 1);
                    args[0] = lhs;
                    lhs = try self.createNode(lhs.span.start, .{ .call = .{
                        .callee = rhs,
                        .args = args,
                    } });
                }
                continue;
            }

            // Null coalescing: expr ?? default
            if (self.current.tag == .question_question and Prec.null_coalesce >= min_prec) {
                self.advance();
                const rhs = try self.parseBinary(Prec.null_coalesce);
                lhs = try self.createNode(lhs.span.start, .{ .null_coalesce = .{ .lhs = lhs, .rhs = rhs } });
                continue;
            }

            const prec = self.binaryPrec();
            if (prec == 0 or prec < min_prec) break;

            const op = self.binaryOp() orelse break;
            self.advance();

            const rhs = try self.parseBinary(prec + 1);

            // Chained comparison detection: if op is a comparison and the next
            // token is also a comparison at the same precedence, accumulate
            // into a ChainedComparison node.
            if (isComparisonOp(op) and self.binaryPrec() == prec and self.isComparisonToken()) {
                var operands = std.ArrayList(*Node).empty;
                var ops = std.ArrayList(ast.BinaryOp.Op).empty;
                try operands.append(self.allocator, lhs);
                try operands.append(self.allocator, rhs);
                try ops.append(self.allocator, op);

                while (self.binaryPrec() == prec and self.isComparisonToken()) {
                    const chain_op = self.binaryOp() orelse break;
                    self.advance();
                    const chain_rhs = try self.parseBinary(prec + 1);
                    try operands.append(self.allocator, chain_rhs);
                    try ops.append(self.allocator, chain_op);
                }

                lhs = try self.createNode(lhs.span.start, .{ .chained_comparison = .{
                    .operands = try operands.toOwnedSlice(self.allocator),
                    .ops = try ops.toOwnedSlice(self.allocator),
                } });
            } else {
                lhs = try self.createNode(lhs.span.start, .{ .binary_op = .{ .op = op, .lhs = lhs, .rhs = rhs } });
            }
        }

        return lhs;
    }

    fn parseUnary(self: *Parser) anyerror!*Node {
        if (self.current.tag == .minus) {
            const start = self.current.loc.start;
            self.advance();
            const operand = try self.parseUnary();
            return try self.createNode(start, .{ .unary_op = .{ .op = .negate, .operand = operand } });
        }
        if (self.current.tag == .bang) {
            const start = self.current.loc.start;
            self.advance();
            const operand = try self.parseUnary();
            return try self.createNode(start, .{ .unary_op = .{ .op = .not, .operand = operand } });
        }
        if (self.current.tag == .tilde) {
            const start = self.current.loc.start;
            self.advance();
            const operand = try self.parseUnary();
            return try self.createNode(start, .{ .unary_op = .{ .op = .bit_not, .operand = operand } });
        }
        if (self.current.tag == .kw_xx) {
            const start = self.current.loc.start;
            self.advance();
            const operand = try self.parseUnary();
            return try self.createNode(start, .{ .unary_op = .{ .op = .xx, .operand = operand } });
        }
        if (self.current.tag == .at) {
            const start = self.current.loc.start;
            self.advance();
            const operand = try self.parseUnary();
            return try self.createNode(start, .{ .unary_op = .{ .op = .address_of, .operand = operand } });
        }
        // `try X` — failable-attempt prefix. Joins the unary tier (binds
        // tighter than any binary op incl. `or`); right-recursive so prefixes
        // stack by adjacency (`xx try foo()` = `xx (try foo())`). Failability
        // of the operand is a sema check (E1.4), not a parse-time restriction.
        if (self.current.tag == .kw_try) {
            try self.rejectInCleanup("try");
            const start = self.current.loc.start;
            self.advance();
            const operand = try self.parseUnary();
            return try self.createNode(start, .{ .try_expr = .{ .operand = operand } });
        }
        // `cast` is not a keyword — `cast(Type, value)` is an ordinary 2-arg
        // call, parsed by parsePostfix like any other.
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) anyerror!*Node {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.current.tag == .l_paren and !self.parenGroupIsForCapture()) {
                // Call. Argument expressions are an ordinary nested context —
                // the for-header capture rule does not apply inside them.
                self.advance();
                const saved_hdr_args = self.in_for_header;
                const saved_ntb_args = self.no_trailing_block;
                self.in_for_header = false;
                self.no_trailing_block = false;
                defer self.in_for_header = saved_hdr_args;
                defer self.no_trailing_block = saved_ntb_args;
                var args = std.ArrayList(*Node).empty;
                while (self.current.tag != .r_paren and self.current.tag != .eof) {
                    if (args.items.len > 0) {
                        try self.expect(.comma);
                        if (self.current.tag == .r_paren) break;
                    }
                    // Spread operator: ..expr
                    if (self.current.tag == .dot_dot) {
                        const spread_start = self.current.loc.start;
                        self.advance();
                        const operand = try self.parseExpr();
                        try args.append(self.allocator, try self.createNode(spread_start, .{ .spread_expr = .{ .operand = operand } }));
                    } else if (self.isIdentLike() and self.peekNext() == .equal) {
                        // Named argument: `name = value` (specs: Named
                        // Arguments). Unambiguous — assignment is statement-
                        // only, and `==` lexes as one token.
                        const named_start = self.current.loc.start;
                        const arg_name = self.tokenSlice(self.current);
                        self.advance(); // name
                        self.advance(); // '='
                        const value = try self.parseExpr();
                        try args.append(self.allocator, try self.createNode(named_start, .{ .named_arg = .{ .name = arg_name, .value = value } }));
                    } else {
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                const rparen_end = self.current.loc.end;
                try self.expect(.r_paren);
                // Trailing block (specs: Trailing Blocks): `f(args) { body }`.
                // T4: the `{` must sit on the SAME LINE as `)` — a next-line
                // `{` stays an ordinary scope block. T5: disabled in header
                // position (the OUTER context's flags — the resets above only
                // govern the nested argument list). The block becomes a
                // zero-param closure literal in a `trailing_block` marker
                // appended as the last argument; the mapping pass binds it to
                // the callee's last declared param (T1/T3/N4 live there).
                if (self.current.tag == .l_brace and
                    !saved_ntb_args and !saved_hdr_args and !self.in_if_condition and
                    std.mem.indexOfScalar(u8, self.source[rparen_end..self.current.loc.start], '\n') == null)
                {
                    const block = try self.parseBlock();
                    const lambda = try self.createNode(block.span.start, .{ .lambda = .{
                        .params = &.{},
                        .return_type = null,
                        .body = block,
                    } });
                    try args.append(self.allocator, try self.createNode(block.span.start, .{ .trailing_block = .{ .lambda = lambda } }));
                    expr = try self.createNode(expr.span.start, .{ .call = .{ .callee = expr, .args = try args.toOwnedSlice(self.allocator) } });
                    // T7′: a trailing block TERMINATES the postfix chain —
                    // chaining onto the emitted result would modify a
                    // discarded copy.
                    if (self.current.tag == .dot) {
                        return self.fail("a trailing block ends the call chain — pass the modifier inside the call: `f(x, m = .{ … }) { … }`");
                    }
                    break;
                }
                expr = try self.createNode(expr.span.start, .{ .call = .{ .callee = expr, .args = try args.toOwnedSlice(self.allocator) } });
            } else if (self.current.tag == .dot) {
                self.advance();
                if (self.current.tag == .l_paren and expr.data == .tuple_type_expr) {
                    // `.( )` is GONE (aggregate ladder Step 1 cutover): the
                    // one aggregate literal is `.{ … }` — typed construction
                    // is `Tuple(A, B).{ v1, v2 }`. A tuple-TYPE receiver can
                    // only be the old literal spelling, so it keeps the
                    // migration message instead of parsing as a cast.
                    return self.fail("'.( )' was removed — the aggregate literal is '.{ … }' (typed tuple construction: 'Tuple(A, B).{ v1, v2 }')");
                } else if (self.current.tag == .l_paren) {
                    // Postfix cast `expr.(T)` (aggregate ladder Step 4) on
                    // the syntax freed by the Step-1 cutover. One type, plus
                    // an optional ALLOCATOR expression for the owning
                    // erasure `expr.(P, alloc)` (protocol targets only —
                    // validated at lowering).
                    self.advance(); // '('
                    const target = try self.parseTypeExpr();
                    var alloc_arg: ?*Node = null;
                    if (self.current.tag == .comma) {
                        self.advance(); // ','
                        alloc_arg = try self.parseExpr();
                        if (self.current.tag == .comma)
                            return self.fail("a postfix cast takes one type and at most one allocator: '.(T)' or '.(P, alloc)'");
                    }
                    try self.expect(.r_paren);
                    expr = try self.createNode(expr.span.start, .{ .postfix_cast = .{ .operand = expr, .type_expr = target, .alloc_arg = alloc_arg } });
                } else if (self.current.tag == .l_brace) {
                    // Struct literal: Type.{ ... }
                    if (expr.data == .identifier) {
                        // Simple name: Vec4.{ ... }
                        expr = try self.parseStructLiteral(expr.data.identifier.name, null, expr.span.start);
                    } else if (expr.data == .field_access) {
                        // Qualified name: std.Vec4.{ ... }. Carry the field_access
                        // NODE as type_expr (NOT a flattened "m.Type" string in
                        // struct_name) so lowering + inference resolve it through
                        // the qualified-type resolver — a flattened string is
                        // looked up as a bare type name, fails, and fabricates an
                        // empty `{}` stub literally named "m.Type" (issue 0204).
                        expr = try self.parseStructLiteral(null, expr, expr.span.start);
                    } else {
                        // Expression type: Vec(3, f32).{ ... }
                        expr = try self.parseStructLiteral(null, expr, expr.span.start);
                    }
                } else if (self.current.tag == .l_bracket) {
                    // Typed array/vector literal: Type.[elem, ...]
                    self.advance(); // skip '['
                    var elements = std.ArrayList(*Node).empty;
                    while (self.current.tag != .r_bracket and self.current.tag != .eof) {
                        if (elements.items.len > 0) {
                            try self.expect(.comma);
                            if (self.current.tag == .r_bracket) break;
                        }
                        const elem = try self.parseExpr();
                        try elements.append(self.allocator, elem);
                    }
                    try self.expect(.r_bracket);
                    expr = try self.createNode(expr.span.start, .{ .array_literal = .{
                        .elements = try elements.toOwnedSlice(self.allocator),
                        .type_expr = expr,
                    } });
                } else if (self.current.tag == .star) {
                    // Dereference: expr.*
                    self.advance();
                    expr = try self.createNode(expr.span.start, .{ .deref_expr = .{ .operand = expr } });
                } else if (self.current.tag == .int_literal) {
                    // Numeric field access: tuple.0, tuple.1
                    const field = self.tokenSlice(self.current);
                    self.advance();
                    expr = try self.createNode(expr.span.start, .{ .field_access = .{ .object = expr, .field = field } });
                } else if (self.dotMemberName()) |field| {
                    // Named field access: expr.field. A reserved keyword is a
                    // valid member name here — the leading dot disambiguates
                    // (`x.enum`, `E.struct`), so no backtick escape is needed.
                    expr = try self.createNode(expr.span.start, .{ .field_access = .{ .object = expr, .field = field } });
                } else {
                    return self.fail("expected field name or index after '.'");
                }
            } else if (self.current.tag == .question_dot) {
                // Optional chaining: expr?.field
                self.advance();
                if (self.current.tag == .identifier) {
                    const field = self.tokenSlice(self.current);
                    self.advance();
                    expr = try self.createNode(expr.span.start, .{ .field_access = .{ .object = expr, .field = field, .is_optional = true } });
                } else if (self.current.tag == .int_literal) {
                    const field = self.tokenSlice(self.current);
                    self.advance();
                    expr = try self.createNode(expr.span.start, .{ .field_access = .{ .object = expr, .field = field, .is_optional = true } });
                } else if (self.current.tag == .l_paren) {
                    // Optional-chained postfix cast `x?.(T)`: null
                    // propagates, the cast/assertion applies to the
                    // payload; the result is `?T`.
                    self.advance(); // '('
                    const target = try self.parseTypeExpr();
                    if (self.current.tag == .comma)
                        return self.fail("a postfix cast '.(T)' takes exactly one type");
                    try self.expect(.r_paren);
                    expr = try self.createNode(expr.span.start, .{ .postfix_cast = .{ .operand = expr, .type_expr = target, .is_optional_chain = true } });
                } else {
                    return self.fail("expected field name after '?.'");
                }
            } else if (self.current.tag == .l_bracket) {
                // Index or slice access: expr[expr] or expr[start..end]
                self.advance();
                // Inside `[...]`, calls parse normally even within a for header.
                const saved_hdr_idx = self.in_for_header;
                self.in_for_header = false;
                defer self.in_for_header = saved_hdr_idx;
                if (rangeTokenInfo(self.current.tag)) |rt| {
                    // Prefix form: [..end] / [..=end] / [..] — implicit 0 start
                    // (a start marker applies to it: [<..end] begins at 1).
                    self.advance();
                    if (rt.end_marked and self.current.tag == .r_bracket) {
                        return self.fail("a range with an explicit end marker ('..=' / '..<') requires an end expression — the open form is '..'");
                    }
                    const end_expr: ?*ast.Node = if (self.current.tag != .r_bracket)
                        try self.parseExpr()
                    else
                        null;
                    try self.expect(.r_bracket);
                    expr = try self.createNode(expr.span.start, .{ .slice_expr = .{
                        .object = expr,
                        .start = null,
                        .end = end_expr,
                        .start_exclusive = rt.start_exclusive,
                        .end_inclusive = rt.end_inclusive,
                    } });
                } else {
                    const first = try self.parseExpr();
                    if (rangeTokenInfo(self.current.tag)) |rt| {
                        // [start..end] or [start..] — same bound-marker matrix
                        // as the for-header ranges.
                        self.advance();
                        if (rt.end_marked and self.current.tag == .r_bracket) {
                            return self.fail("a range with an explicit end marker ('..=' / '..<') requires an end expression — the open form is 'a..'");
                        }
                        const end_expr: ?*ast.Node = if (self.current.tag != .r_bracket)
                            try self.parseExpr()
                        else
                            null;
                        try self.expect(.r_bracket);
                        expr = try self.createNode(expr.span.start, .{ .slice_expr = .{
                            .object = expr,
                            .start = first,
                            .end = end_expr,
                            .start_exclusive = rt.start_exclusive,
                            .end_inclusive = rt.end_inclusive,
                        } });
                    } else {
                        // [index] — normal index access
                        try self.expect(.r_bracket);
                        expr = try self.createNode(expr.span.start, .{ .index_expr = .{
                            .object = expr,
                            .index = first,
                        } });
                    }
                }
            } else if (self.current.tag == .bang) {
                // Force unwrap: expr!
                // Only if it's not != (bang_equal would have been lexed as a single token)
                self.advance();
                expr = try self.createNode(expr.span.start, .{ .force_unwrap = .{ .operand = expr } });
            } else if (self.current.tag == .kw_catch) {
                // `X catch [(binding)] BODY` — postfix failure handler.
                // Four shapes, disambiguated by peeking after `catch`:
                //   catch { block }            — no binding (braces required)
                //   catch (e) { block }        — binding + block body
                //   catch (e) == { case ... }  — binding + match body (sugar)
                //   catch (e) EXPR             — binding + bare-expression body
                self.advance(); // consume 'catch'
                var binding: ?[]const u8 = null;
                var binding_span: ?ast.Span = null;
                var binding_is_raw = false;
                if (self.current.tag == .identifier) {
                    return self.fail("the catch error binding needs parens: `catch (e) { ... }`");
                }
                if (self.current.tag == .l_paren) {
                    self.advance();
                    if (self.current.tag != .identifier) {
                        return self.fail("expected an error binding name in `catch (e)`");
                    }
                    binding = self.tokenSlice(self.current);
                    binding_span = .{ .start = self.current.loc.start, .end = self.current.loc.end };
                    binding_is_raw = self.current.is_raw;
                    self.advance();
                    try self.expect(.r_paren);
                }
                var is_match_body = false;
                const body: *Node = if (self.current.tag == .l_brace)
                    try self.parseBlock()
                else if (binding != null and self.current.tag == .equal_equal) blk: {
                    const m_start = self.current.loc.start;
                    self.advance(); // consume '=='
                    is_match_body = true;
                    const subject = try self.createNode(m_start, .{ .identifier = .{ .name = binding.?, .is_raw = binding_is_raw } });
                    break :blk try self.parseMatchBody(subject, m_start);
                } else if (binding != null)
                    try self.parseExpr()
                else
                    return self.fail("`catch` without a binding requires a braced body: `catch { ... }`");
                expr = try self.createNode(expr.span.start, .{ .catch_expr = .{
                    .operand = expr,
                    .binding = binding,
                    .binding_span = binding_span,
                    .binding_is_raw = binding_is_raw,
                    .body = body,
                    .is_match_body = is_match_body,
                } });
            } else {
                break;
            }
        }

        return expr;
    }

    /// True when the current token is a bare identifier with text `word` — used
    /// for the contextual keywords `volatile` / `clobbers` that appear only
    /// inside an `asm { … }` body and are NOT globally reserved.
    fn isContextualWord(self: *const Parser, word: []const u8) bool {
        return self.current.tag == .identifier and std.mem.eql(u8, self.tokenSlice(self.current), word);
    }

    /// Inline assembly expression (ASM stream, design §II.2–II.4):
    ///   `asm volatile? { "tmpl", [name]? "constraint" (-> Type | = expr), …,
    ///                     clobbers(.name, …) }`
    /// A flat, comma-separated brace block: the template first, then operands
    /// and an optional `clobbers(.…)` clause, source order preserved.
    fn parseAsmExpr(self: *Parser, start: u32) anyerror!*Node {
        self.advance(); // consume `asm`
        var is_volatile = false;
        if (self.isContextualWord("volatile")) {
            is_volatile = true;
            self.advance();
        }
        try self.expect(.l_brace);

        // First element: the template (a comptime string — `"..."` or `#string`).
        const template = try self.parseExpr();

        var operands = std.ArrayList(ast.AsmOperand).empty;
        var clobbers = std.ArrayList([]const u8).empty;

        while (self.current.tag == .comma) {
            self.advance(); // consume the separating comma
            if (self.current.tag == .r_brace) break; // trailing comma

            // `clobbers(.name, .name, …)` clause.
            if (self.isContextualWord("clobbers")) {
                self.advance();
                try self.expect(.l_paren);
                while (true) {
                    try self.expect(.dot);
                    if (self.current.tag != .identifier)
                        return self.fail("expected a clobber name after '.' in clobbers(...)");
                    try clobbers.append(self.allocator, self.tokenSlice(self.current));
                    self.advance();
                    if (self.current.tag == .comma) {
                        self.advance();
                        continue;
                    }
                    break;
                }
                try self.expect(.r_paren);
                continue;
            }

            // Operand: `[name]? "constraint" (-> Type | = expr)`.
            var op_name: ?[]const u8 = null;
            if (self.current.tag == .l_bracket) {
                self.advance();
                if (self.current.tag != .identifier)
                    return self.fail("expected an operand name in '[...]'");
                op_name = self.tokenSlice(self.current);
                self.advance();
                try self.expect(.r_bracket);
            }
            if (self.current.tag != .string_literal)
                return self.fail("expected a \"constraint\" string in asm operand");
            const craw = self.tokenSlice(self.current);
            const constraint = craw[1 .. craw.len - 1]; // strip quotes
            self.advance();

            var role: ast.AsmOperand.Role = undefined;
            var payload: *Node = undefined;
            if (self.current.tag == .arrow) {
                self.advance();
                if (self.current.tag == .at) {
                    // `-> @place`: write-through output. `@place` is parsed as an
                    // ordinary address-of expression (a pointer); lowering stores
                    // the asm result through it. The output does NOT join the
                    // result tuple.
                    role = .out_place;
                    payload = try self.parseUnary();
                } else {
                    role = .out_value;
                    payload = try self.parseTypeExpr();
                }
            } else if (self.current.tag == .equal) {
                self.advance();
                role = .input;
                payload = try self.parseExpr();
            } else {
                return self.fail("expected '->' (output) or '=' (input) after the asm constraint");
            }
            try operands.append(self.allocator, .{
                .name = op_name,
                .constraint = constraint,
                .role = role,
                .payload = payload,
            });
        }

        try self.expect(.r_brace);
        return try self.createNode(start, .{ .asm_expr = .{
            .template = template,
            .is_volatile = is_volatile,
            .operands = try operands.toOwnedSlice(self.allocator),
            .clobbers = try clobbers.toOwnedSlice(self.allocator),
        } });
    }

    /// Top-level global assembly `asm { "tmpl", };` — template only. Rejects
    /// `volatile` and any operands/clobbers (design §II.2 Deviation 6).
    fn parseAsmGlobal(self: *Parser, start: u32) anyerror!*Node {
        self.advance(); // consume `asm`
        if (self.isContextualWord("volatile")) {
            return self.fail("global (top-level) asm cannot be `volatile`");
        }
        try self.expect(.l_brace);
        const template = try self.parseExpr();
        if (self.current.tag == .comma) self.advance(); // optional trailing comma
        if (self.current.tag != .r_brace) {
            return self.fail("global (top-level) asm takes no operands, inputs, or clobbers — only a template string");
        }
        try self.expect(.r_brace);
        try self.expect(.semicolon);
        return try self.createNode(start, .{ .asm_global = .{ .template = template } });
    }

    fn parsePrimary(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        // Pack references in expression position:
        //   `$<pack_name>[<int_literal>]` → `pack_index_type_expr`
        //       (single Type value, step 3 shape)
        //   `$<pack_name>`                 → `comptime_pack_ref`
        //       (whole pack as []Type value, step 4 final slice)
        // Lowering routes each through `pack_arg_types` to either
        // a `const_type(TypeId)` or a `[]Type` aggregate of them.
        if (self.current.tag == .dollar) {
            self.advance();
            if (self.current.tag != .identifier) {
                return self.fail("expected pack name after '$'");
            }
            const pname = self.tokenSlice(self.current);
            self.advance();
            if (self.current.tag == .l_bracket) {
                self.advance(); // skip '['
                if (self.current.tag != .int_literal) {
                    return self.fail("expected integer literal in pack index");
                }
                const idx_text = self.tokenSlice(self.current);
                // Strip `_` separators / honor `0x`/`0o`/`0b` prefixes via the
                // shared literal parser (matches every other int-literal site).
                const idx_u64 = self.parseIntLiteralText(idx_text) orelse {
                    return self.fail("invalid integer literal in pack index");
                };
                const idx_val = std.math.cast(u32, idx_u64) orelse {
                    return self.fail("pack index out of range");
                };
                self.advance();
                try self.expect(.r_bracket);
                return try self.createNode(start, .{ .pack_index_type_expr = .{
                    .pack_name = pname,
                    .index = idx_val,
                } });
            }
            return try self.createNode(start, .{ .comptime_pack_ref = .{
                .pack_name = pname,
            } });
        }
        switch (self.current.tag) {
            .int_literal => {
                const text = self.tokenSlice(self.current);
                // A bare integer literal is a non-negative magnitude — parse the
                // FULL u64 range (not i64) so a value with the high bit set
                // (`0xcbf29ce484222325`, `18446744073709551615`) is representable
                // in a `u64` context. Stored as the bit pattern; the fits-check
                // in lowering (`checkIntLiteralMagnitudeFits`) validates the
                // magnitude against the destination type's capacity.
                const value: i64 = @bitCast(self.parseIntLiteralText(text) orelse {
                    return self.fail("integer literal overflow");
                });
                self.advance();
                return try self.createNode(start, .{ .int_literal = .{ .value = value } });
            },
            .float_literal => {
                const text = self.tokenSlice(self.current);
                // std.fmt.parseFloat rejects `_`, so strip all separators first.
                const stripped = try self.stripSeparators(text);
                defer self.allocator.free(stripped);
                const value = std.fmt.parseFloat(f64, stripped) catch {
                    return self.fail("float literal overflow");
                };
                self.advance();
                return try self.createNode(start, .{ .float_literal = .{ .value = value } });
            },
            .string_literal => {
                // raw includes quotes
                const raw = self.tokenSlice(self.current);
                self.advance();
                return try self.createNode(start, .{ .string_literal = .{ .raw = raw[1 .. raw.len - 1] } });
            },
            .raw_string_literal => {
                // #string heredoc — token span is content only, no stripping needed
                const raw = self.tokenSlice(self.current);
                self.advance();
                return try self.createNode(start, .{ .string_literal = .{ .raw = raw, .is_raw = true } });
            },
            .char_literal => {
                // raw includes the surrounding `'`s; strip them for the inner body.
                const raw = self.tokenSlice(self.current);
                self.advance();
                const inner = raw[1 .. raw.len - 1];
                const value = unescape.decodeCharLiteral(inner) catch |err| {
                    return self.fail(unescape.charLiteralReason(err));
                };
                return try self.createNode(start, .{ .char_literal = .{ .value = value, .raw = inner } });
            },
            .kw_true => {
                self.advance();
                return try self.createNode(start, .{ .bool_literal = .{ .value = true } });
            },
            .kw_false => {
                self.advance();
                return try self.createNode(start, .{ .bool_literal = .{ .value = false } });
            },
            .kw_null => {
                self.advance();
                return try self.createNode(start, .{ .null_literal = {} });
            },
            .identifier => {
                const name = self.tokenSlice(self.current);
                const is_raw = self.current.is_raw;
                // `Tuple(...)` in expression position is a tuple TYPE node —
                // identical to the one the type parser produces — NOT a value.
                // It is first-class in `size_of` / `type_info` / generic type
                // args (a non-type element like `Tuple(i32, 1)` is rejected at
                // the type-demanding site), can stand alone as a `Type` value,
                // and a postfix `.( ... )` (handled in `parsePostfix`)
                // constructs a typed tuple VALUE of that type — exactly like
                // `Name.{ ... }` for structs. A bare `Tuple` not followed by `(`
                // (or a backtick-raw `` `Tuple ``) stays an ordinary identifier.
                if (!is_raw and std.mem.eql(u8, name, "Tuple") and self.peekNext() == .l_paren) {
                    self.advance(); // skip `Tuple`; `current` is now `(`
                    return self.parseTupleTypeBody(start);
                }
                // `Closure(...) -> R` in expression position is a closure TYPE
                // node — identical to the one the type parser produces — so a
                // const-decl RHS alias `CB :: Closure(i32) -> i32;` parses (the
                // `-> R` tail is consumed here, not left dangling as after a
                // bare `Closure(i32)` call). Mirrors the `Tuple(` case above; a
                // bare `Closure` not followed by `(` (or a backtick-raw
                // `` `Closure ``) stays an ordinary identifier.
                if (!is_raw and std.mem.eql(u8, name, "Closure") and self.peekNext() == .l_paren) {
                    self.advance(); // skip `Closure`; `current` is now `(`
                    return self.parseClosureTypeBody(start);
                }
                // A backtick raw identifier (`` `i2 ``) is NEVER type-classified —
                // it is always a value identifier, bypassing the reserved-type-name
                // rule. Only a bare spelling is checked for a type name
                // (e.g. i32, u8, s128).
                if (!is_raw and Type.fromName(name) != null) {
                    self.advance();
                    return try self.createNode(start, .{ .type_expr = .{ .name = name } });
                }
                self.advance();
                return try self.createNode(start, .{ .identifier = .{ .name = name, .is_raw = is_raw } });
            },
            .kw_closure, .kw_protocol, .kw_impl, .kw_ufcs => {
                // Contextual keywords used as identifiers in expressions
                const name = self.tokenSlice(self.current);
                self.advance();
                return try self.createNode(start, .{ .identifier = .{ .name = name } });
            },
            .kw_asm => return self.parseAsmExpr(start),
            .dot => {
                self.advance();
                // Anonymous struct literal: .{ ... }
                if (self.current.tag == .l_brace) {
                    return self.parseStructLiteral(null, null, start);
                }
                // Array literal: .[expr, expr, ...]
                if (self.current.tag == .l_bracket) {
                    self.advance(); // skip '['
                    var elements = std.ArrayList(*Node).empty;
                    while (self.current.tag != .r_bracket and self.current.tag != .eof) {
                        if (elements.items.len > 0) {
                            try self.expect(.comma);
                            if (self.current.tag == .r_bracket) break;
                        }
                        const elem = try self.parseExpr();
                        try elements.append(self.allocator, elem);
                    }
                    try self.expect(.r_bracket);
                    return try self.createNode(start, .{ .array_literal = .{ .elements = try elements.toOwnedSlice(self.allocator) } });
                }
                // `.( )` is GONE (aggregate ladder Step 1 cutover): the one
                // aggregate literal is `.{ … }`. (The freed syntax is
                // reserved for the Step-4 postfix cast.)
                if (self.current.tag == .l_paren) {
                    return self.fail("'.( )' was removed — the aggregate literal is '.{ … }' (an untyped '.{ … }' self-types as an anonymous struct; annotate with 'Tuple(…)' for a tuple)");
                }
                // Enum literal: .variant_name. A reserved keyword is a valid
                // variant name here — the leading dot disambiguates (`.enum`,
                // `.struct`), so no backtick escape is needed.
                const name = self.dotMemberName() orelse
                    return self.fail("expected variant name, '{', '[', or '(' after '.'");
                // Enum literal: .variant_name — parsePostfix handles optional (...) as a call
                return try self.createNode(start, .{ .enum_literal = .{ .name = name } });
            },
            .l_paren => {
                // Lambda: (params) => expr
                if (self.isLambda()) {
                    return self.parseLambda();
                }
                // Function-type literal: (T1, T2) -> R (no body — isLambda would have caught a body)
                if (self.isFunctionTypeExprAtLParen()) {
                    return try self.parseTypeExpr();
                }
                self.advance(); // skip '('

                // A `(` here opens a grouping/tuple, so calls inside it parse
                // normally even within a for header.
                const saved_hdr_grp = self.in_for_header;
                self.in_for_header = false;
                defer self.in_for_header = saved_hdr_grp;

                // Bare `(...)` is GROUPING ONLY. Tuple VALUES are written
                // `.( … )` / `Tuple(T..).( … )`. A named element, an empty group,
                // a leading spread, or a top-level comma all used to build a
                // bare-paren `tuple_literal`; that grammar is gone.
                if (self.current.tag == .identifier and self.peekNext() == .colon) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}` or `Tuple(A, B).{a, b}`)");
                }
                if (self.current.tag == .r_paren) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}` or `Tuple(A, B).{a, b}`)");
                }
                if (self.current.tag == .dot_dot) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}` or `Tuple(A, B).{a, b}`)");
                }

                const first = try self.parseExpr();

                // A top-level comma was a tuple; now it is an error.
                if (self.current.tag == .comma) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}` or `Tuple(A, B).{a, b}`)");
                }

                // No comma → grouping
                try self.expect(.r_paren);
                return first;
            },
            .kw_f32, .kw_f64, .kw_Type => {
                // Type keyword used as expression (for type aliases: SOME_TYPE :: f64;)
                const name = self.tokenSlice(self.current);
                self.advance();
                return try self.createNode(start, .{ .type_expr = .{ .name = name } });
            },
            .kw_struct => {
                // Anonymous struct expression: struct { value: T; count: u32; }
                return try self.parseStructDecl("__anon", start, false);
            },
            .kw_enum => {
                // Anonymous enum expression: enum { variant: T; other: u32; }
                return try self.parseEnumDecl("__anon", start, false);
            },
            .kw_union => {
                // Anonymous C-style union expression: union { f: f32; i: i32; }
                return try self.parseUnionDecl("__anon", start, false);
            },
            .kw_if => {
                return self.parseIfExpr();
            },
            .kw_while => {
                return self.parseWhileExpr();
            },
            .kw_for => {
                return self.parseForExpr();
            },
            .kw_push => {
                return self.parsePushStmt();
            },
            .kw_break => {
                self.advance();
                return try self.createNode(start, .{ .break_expr = {} });
            },
            .kw_continue => {
                self.advance();
                return try self.createNode(start, .{ .continue_expr = {} });
            },
            .kw_return => {
                self.advance();
                // return with optional value
                const value = if (self.current.tag != .semicolon and self.current.tag != .eof)
                    try self.parseExpr()
                else
                    null;
                return try self.createNode(start, .{ .return_stmt = .{ .value = value } });
            },
            .l_bracket, .star, .question => {
                return try self.parseTypeExpr();
            },
            .l_brace => {
                return self.parseBlock();
            },
            .triple_minus => {
                self.advance();
                return try self.createNode(start, .{ .undef_literal = {} });
            },
            .hash_run => {
                self.advance(); // skip '#run'
                const inner = try self.parseExpr();
                return try self.createNode(start, .{ .comptime_expr = .{ .expr = inner } });
            },
            .hash_caller_location => {
                self.advance();
                return try self.createNode(start, .{ .caller_location = {} });
            },
            .hash_objc_call, .hash_jni_call, .hash_jni_static_call => {
                return try self.parseFfiIntrinsicCall();
            },
            .hash_jni_env => {
                return try self.parseJniEnvBlock();
            },
            // `error` in expression position is the head of a tag literal
            // `error.X` (parsed as a field access); sema (E1) gives it meaning.
            .kw_error => {
                self.advance();
                return try self.createNode(start, .{ .identifier = .{ .name = "error" } });
            },
            .kw_raise => return self.fail("`raise` is a statement and cannot appear in expression position"),
            .kw_onfail => return self.fail("`onfail` is a statement and cannot appear in expression position"),
            else => {
                return self.fail("unexpected token in expression");
            },
        }
    }

    /// Parse `#objc_call(T)(recv, "sel:", args...)`,
    /// `#jni_call(T)(env, target, "name", "(Sig)R", args...)`, or
    /// `#jni_static_call(T)(class, "name", "(Sig)R", args...)`. The
    /// return type sits in the first parens; the actual call args
    /// follow in the second.
    fn parseJniEnvBlock(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        self.advance(); // skip `#jni_env`

        try self.expect(.l_paren);
        const env_expr = try self.parseExpr();
        try self.expect(.r_paren);

        // Body is a brace-delimited block. The `-> ?T` annotation for
        // exception bubbling lands with step 2.15 / 2.16 follow-ups.
        if (self.current.tag != .l_brace) {
            return self.fail("expected '{' after '#jni_env(env)'");
        }
        const body = try self.parseBlock();

        return try self.createNode(start, .{ .jni_env_block = .{
            .env = env_expr,
            .body = body,
        } });
    }

    fn parseFfiIntrinsicCall(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        const kind: ast.FfiIntrinsicKind = switch (self.current.tag) {
            .hash_objc_call => .objc_call,
            .hash_jni_call => .jni_call,
            .hash_jni_static_call => .jni_static_call,
            else => unreachable,
        };
        self.advance(); // skip the directive

        try self.expect(.l_paren);
        const ret_type = try self.parseTypeExpr();
        try self.expect(.r_paren);

        try self.expect(.l_paren);
        var args = std.ArrayList(*Node).empty;
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const arg = try self.parseExpr();
            try args.append(self.allocator, arg);
            if (self.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        try self.expect(.r_paren);

        return try self.createNode(start, .{ .ffi_intrinsic_call = .{
            .kind = kind,
            .return_type = ret_type,
            .args = try args.toOwnedSlice(self.allocator),
        } });
    }

    fn parseIfExpr(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        self.advance(); // skip 'if'

        // Optional binding: if val := expr { ... }
        // Detect: identifier followed by :=
        if (self.current.tag == .identifier and self.peekNext() == .colon_equal) {
            const binding_name = self.tokenSlice(self.current);
            const binding_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            const binding_is_raw = self.current.is_raw;
            self.advance(); // skip identifier
            self.advance(); // skip :=
            const saved_if_cond = self.in_if_condition;
            self.in_if_condition = true;
            const source_expr = try self.parseExpr();
            self.in_if_condition = saved_if_cond;
            const then_branch = try self.parseBlock();
            var else_branch: ?*Node = null;
            if (self.current.tag == .kw_else) {
                self.advance();
                if (self.current.tag == .kw_if) {
                    else_branch = try self.parseIfExpr();
                } else {
                    else_branch = try self.parseBlock();
                }
            }
            return try self.createNode(start, .{ .if_expr = .{
                .condition = source_expr,
                .then_branch = then_branch,
                .else_branch = else_branch,
                .is_inline = false,
                .binding_name = binding_name,
                .binding_span = binding_span,
                .binding_is_raw = binding_is_raw,
            } });
        }

        // Parse condition above comparison level, leaving comparisons
        // unconsumed for manual handling with match disambiguation.
        const saved_if_cond = self.in_if_condition;
        self.in_if_condition = true;
        var condition = try self.parseBinary(Prec.shift);

        // Handle comparisons with chain detection and match disambiguation.
        // All comparisons (< <= > >= == !=) are at the same precedence.
        if (self.isComparisonToken()) {
            var operands = std.ArrayList(*Node).empty;
            var ops = std.ArrayList(ast.BinaryOp.Op).empty;
            try operands.append(self.allocator, condition);

            while (self.isComparisonToken()) {
                // Match disambiguation: == followed by { is a match expression
                if (self.current.tag == .equal_equal) {
                    self.advance();
                    if (self.current.tag == .l_brace) {
                        // Match expression: if expr == { case ... }
                        // Only valid as the first comparison (no chain before it)
                        if (ops.items.len == 0) {
                            self.in_if_condition = saved_if_cond;
                            return self.parseMatchBody(condition, start);
                        }
                        // Chain followed by == { is an error — fall through to
                        // regular comparison (will likely fail at parse time)
                    }
                    const rhs = try self.parseBinary(Prec.shift);
                    try operands.append(self.allocator, rhs);
                    try ops.append(self.allocator, .eq);
                } else {
                    const cmp_op = self.binaryOp() orelse break;
                    self.advance();
                    const rhs = try self.parseBinary(Prec.shift);
                    try operands.append(self.allocator, rhs);
                    try ops.append(self.allocator, cmp_op);
                }
            }

            if (ops.items.len == 1) {
                // Single comparison — regular binary_op
                condition = try self.createNode(condition.span.start, .{ .binary_op = .{
                    .op = ops.items[0],
                    .lhs = operands.items[0],
                    .rhs = operands.items[1],
                } });
            } else {
                // Chained comparison
                condition = try self.createNode(condition.span.start, .{ .chained_comparison = .{
                    .operands = try operands.toOwnedSlice(self.allocator),
                    .ops = try ops.toOwnedSlice(self.allocator),
                } });
            }
        }

        // Handle and/or with proper Pratt precedence
        condition = try self.parseBinaryRhs(condition, Prec.logical_or);
        self.in_if_condition = saved_if_cond;

        // Inline form: if cond then expr [else expr]
        if (self.current.tag == .kw_then) {
            self.advance();
            const then_branch = try self.parseExpr();
            var else_branch: ?*Node = null;
            if (self.current.tag == .kw_else) {
                self.advance();
                else_branch = try self.parseExpr();
            }
            return try self.createNode(start, .{ .if_expr = .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
                .is_inline = true,
            } });
        }

        // Block form: if cond { ... } else { ... }
        const then_branch = try self.parseBlock();
        var else_branch: ?*Node = null;
        if (self.current.tag == .kw_else) {
            self.advance();
            if (self.current.tag == .kw_if) {
                else_branch = try self.parseIfExpr();
            } else {
                else_branch = try self.parseBlock();
            }
        }
        return try self.createNode(start, .{ .if_expr = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
            .is_inline = false,
        } });
    }

    fn parseWhileExpr(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        self.advance(); // skip 'while'

        // Optional binding: while val := expr { ... }
        if (self.current.tag == .identifier and self.peekNext() == .colon_equal) {
            const binding_name = self.tokenSlice(self.current);
            const binding_span = ast.Span{ .start = self.current.loc.start, .end = self.current.loc.end };
            const binding_is_raw = self.current.is_raw;
            self.advance(); // skip identifier
            self.advance(); // skip :=
            const saved_ntb = self.no_trailing_block;
            self.no_trailing_block = true;
            const source_expr = try self.parseExpr();
            self.no_trailing_block = saved_ntb;
            const body = try self.parseBlock();
            return try self.createNode(start, .{ .while_expr = .{
                .condition = source_expr,
                .body = body,
                .binding_name = binding_name,
                .binding_span = binding_span,
                .binding_is_raw = binding_is_raw,
            } });
        }

        const saved_ntb = self.no_trailing_block;
        self.no_trailing_block = true;
        const condition = try self.parseExpr();
        self.no_trailing_block = saved_ntb;
        const body = try self.parseBlock();

        return try self.createNode(start, .{ .while_expr = .{
            .condition = condition,
            .body = body,
        } });
    }

    fn parsePushStmt(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        self.advance(); // skip 'push'

        const saved_ntb = self.no_trailing_block;
        self.no_trailing_block = true;
        const context_expr = try self.parseExpr();
        self.no_trailing_block = saved_ntb;

        // push Context.{ ... } { body } — if parseExpr consumed the push body
        // as a struct init block, steal it back as the push body.
        // (if/while don't have this issue — they require bool/optional conditions)
        const body = if (context_expr.data == .struct_literal and
            context_expr.data.struct_literal.init_block != null)
        body_blk: {
            const ib = context_expr.data.struct_literal.init_block.?;
            context_expr.data.struct_literal.init_block = null;
            break :body_blk ib;
        } else try self.parseBlock();

        return try self.createNode(start, .{ .push_stmt = .{
            .context_expr = context_expr,
            .body = body,
        } });
    }

    fn parseForExpr(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        self.advance(); // skip 'for'

        var iterables = std.ArrayList(ast.ForIterable).empty;
        var captures = std.ArrayList(ast.ForCapture).empty;

        // Header: comma-separated iterables, each a collection expression or
        // a range (`a..b`, `a..=b`, open `a..`). Top-level trailing call
        // parens are read as the capture (see parenGroupIsForCapture).
        const saved_hdr = self.in_for_header;
        self.in_for_header = true;
        while (true) {
            const expr = try self.parseExpr();
            var it = ast.ForIterable{ .expr = expr };
            if (rangeTokenInfo(self.current.tag)) |rt| {
                it.is_range = true;
                it.start_exclusive = rt.start_exclusive;
                it.end_inclusive = rt.end_inclusive;
                self.advance();
                // End expression — absent for the open range `a..`, i.e. when
                // the header continues (`,`), the body starts (`{` / `=>`),
                // or the capture group follows.
                const open = switch (self.current.tag) {
                    .comma, .l_brace, .fat_arrow => true,
                    .l_paren => self.parenGroupIsForCapture(),
                    else => false,
                };
                if (open) {
                    if (rt.end_marked) return self.fail("a range with an explicit end marker ('..=' / '..<') requires an end expression — the open form is 'a..'");
                } else {
                    it.range_end = try self.parseExpr();
                }
            }
            try iterables.append(self.allocator, it);
            if (self.current.tag != .comma) break;
            self.advance();
        }
        self.in_for_header = saved_hdr;

        // Migration aid for the pre-multi-iterable syntax.
        if (self.current.tag == .colon) {
            return self.fail("for-loop syntax: the ':' before the capture was removed — write `for xs (x) { }` (index via `for xs, 0.. (x, i)`)");
        }

        // Capture group: `(x)`, `(*x)`, `(a, b, ...)` — positional, one
        // capture per iterable.
        if (self.current.tag == .l_paren) {
            self.advance();
            while (true) {
                var cap = ast.ForCapture{ .name = "" };
                if (self.current.tag == .star) {
                    cap.by_ref = true;
                    self.advance();
                }
                if (self.current.tag != .identifier) return self.fail("expected capture variable name (a call iterable also needs a capture: `for f(n) (x) { }`)");
                cap.name = self.tokenSlice(self.current);
                cap.span = .{ .start = self.current.loc.start, .end = self.current.loc.end };
                cap.is_raw = self.current.is_raw;
                self.advance();
                try captures.append(self.allocator, cap);
                if (self.current.tag != .comma) break;
                self.advance();
            }
            try self.expect(.r_paren);
        }

        if (captures.items.len != 0 and captures.items.len != iterables.items.len) {
            return self.fail("for capture count must match the iterable count — one capture per iterable");
        }
        if (iterables.items[0].is_range and iterables.items[0].range_end == null) {
            return self.fail("the first iterable must have a bounded length (it drives the loop) — an open range 'a..' may only follow it");
        }
        for (iterables.items, 0..) |it, i| {
            if (it.is_range and i < captures.items.len and captures.items[i].by_ref) {
                return self.fail("a range element cannot be captured by reference");
            }
        }

        // Body: a block, or the arrow form `=> stmt` (a full statement, so
        // assignments like `=> s += x;` work; parseStmt owns the `;`).
        var body: *Node = undefined;
        if (self.current.tag == .fat_arrow) {
            self.advance();
            body = try self.parseStmt();
        } else {
            body = try self.parseBlock();
        }

        return try self.createNode(start, .{ .for_expr = .{
            .iterables = try iterables.toOwnedSlice(self.allocator),
            .captures = try captures.toOwnedSlice(self.allocator),
            .body = body,
        } });
    }

    fn parseMatchBody(self: *Parser, subject: *Node, start_pos: u32) anyerror!*Node {
        try self.expect(.l_brace);
        var arms = std.ArrayList(ast.MatchArm).empty;
        while (self.current.tag == .kw_case) {
            const arm_start = self.current.loc.start;
            self.advance(); // skip 'case'
            // Allow keyword tokens (struct, enum, union) as type category names in match arms
            const pattern: *Node = if (self.current.tag == .kw_struct or self.current.tag == .kw_enum or self.current.tag == .kw_union) blk: {
                const name = self.tokenSlice(self.current);
                self.advance();
                break :blk try self.createNode(arm_start, .{ .identifier = .{ .name = name } });
            } else try self.parsePrimary(); // .variant
            try self.expect(.colon);

            // Optional payload capture: `(ident)`. Disambiguated from a
            // parenthesized / tuple arm-value expression (`(5)`, `(1, 1)`):
            // a capture is exactly `( <identifier> )`; anything else is the
            // arm body (an expression) and is left for the body parse below.
            var capture: ?[]const u8 = null;
            var capture_span: ?ast.Span = null;
            var capture_is_raw = false;
            if (self.current.tag == .l_paren and self.isLoneIdentParen()) {
                self.advance(); // '('
                capture = self.tokenSlice(self.current);
                capture_span = .{ .start = self.current.loc.start, .end = self.current.loc.end };
                capture_is_raw = self.current.is_raw;
                self.advance(); // ident
                try self.expect(.r_paren);
            }

            if (self.current.tag == .kw_break) {
                self.advance();
                try self.expect(.semicolon);
                const body = try self.createNode(arm_start, .{ .block = .{ .stmts = &.{} } });
                try arms.append(self.allocator, .{ .pattern = pattern, .body = body, .is_break = true, .capture = capture, .capture_span = capture_span, .capture_is_raw = capture_is_raw });
            } else if (self.current.tag == .fat_arrow) {
                // Short form: (ident) => expr;
                self.advance();
                const expr = try self.parseExpr();
                try self.expect(.semicolon);
                // Arm bodies are value-producing regardless of the arm `;` (the
                // `;` is an arm terminator, not a value-discard — match arms are
                // exempt from the block trailing-`;` rule).
                const body = try self.createNode(arm_start, .{ .block = .{ .stmts = try self.allocator.dupe(*Node, &.{expr}), .produces_value = true } });
                try arms.append(self.allocator, .{ .pattern = pattern, .body = body, .is_break = false, .capture = capture, .capture_span = capture_span, .capture_is_raw = capture_is_raw });
            } else {
                const stmts_start = self.current.loc.start;
                var stmts = std.ArrayList(*Node).empty;
                while (self.current.tag != .kw_case and self.current.tag != .kw_else and self.current.tag != .r_brace and self.current.tag != .eof) {
                    try stmts.append(self.allocator, try self.parseStmt());
                }
                // Arm exempt from the trailing-`;` rule (see above); the wrapper
                // yields its last statement's value — which, for a braced-block
                // arm body, still respects that inner block's own flag.
                const body = try self.createNode(stmts_start, .{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator), .produces_value = true } });
                try arms.append(self.allocator, .{ .pattern = pattern, .body = body, .is_break = false, .capture = capture, .capture_span = capture_span, .capture_is_raw = capture_is_raw });
            }
        }
        // Optional else arm (default)
        if (self.current.tag == .kw_else) {
            const else_start = self.current.loc.start;
            self.advance(); // skip 'else'
            try self.expect(.colon);
            var stmts = std.ArrayList(*Node).empty;
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                try stmts.append(self.allocator, try self.parseStmt());
            }
            const body = try self.createNode(else_start, .{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator), .produces_value = true } });
            try arms.append(self.allocator, .{ .pattern = null, .body = body, .is_break = false });
        }
        try self.expect(.r_brace);
        return try self.createNode(start_pos, .{ .match_expr = .{ .subject = subject, .arms = try arms.toOwnedSlice(self.allocator) } });
    }

    /// `#error "message";` — a compile-time diagnostic. Usable as a statement or
    /// a top-level item; the message fires only when the node reaches live decls
    /// (the flatten pass drops it in non-taken `inline if` arms).
    fn parseErrorDirective(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        self.advance(); // skip '#error'
        if (self.current.tag != .string_literal) {
            return self.fail("expected a string message after '#error'");
        }
        const raw = self.tokenSlice(self.current);
        const message = raw[1 .. raw.len - 1];
        self.advance();
        try self.expect(.semicolon);
        return try self.createNode(start, .{ .error_directive = .{ .message = message } });
    }

    /// Parse a `.( ... )` tuple value literal. `current` is the `(`.
    /// A token that can only begin a VALUE literal, never a type. Used to give
    /// `Tuple(...)` a precise lowering-time "element is not a type" diagnostic
    /// (instead of a generic parse error) when a literal is supplied as a tuple
    /// element.
    fn currentTokenIsValueLiteral(self: *Parser) bool {
        switch (self.current.tag) {
            .int_literal,
            .float_literal,
            .string_literal,
            .raw_string_literal,
            .char_literal,
            .kw_true,
            .kw_false,
            .kw_null,
            => return true,
            // A signed numeric literal — `Tuple(i32, -1)` / `Tuple(i32, +2)` —
            // is value-shaped too, so the precise "tuple type element is not a
            // type" diagnostic fires instead of the generic "expected type
            // name" parse error. Only a leading sign DIRECTLY before a number
            // counts (not `-T`, which is never a valid type anyway).
            .minus, .plus => {
                const next = self.peekNext();
                return next == .int_literal or next == .float_literal;
            },
            else => return false,
        }
    }

    /// Parse a `Tuple(...)` tuple-TYPE body. On entry `current` is the `(`
    /// immediately after the `Tuple` contextual id (the caller has already
    /// consumed `Tuple`). Used in BOTH type position (the type parser) and
    /// expression position (`parsePrimary`'s `.identifier` arm) — `Tuple(...)`
    /// always denotes a TYPE, never a value. A postfix `.( ... )` after the
    /// returned `tuple_type_expr` constructs a typed tuple VALUE (handled in
    /// Closure type body: parses `(params...) -> R` after a `Closure` head.
    /// `current` must be at the opening `(`. Shared by the type-expr grammar
    /// (annotation / field / return position) and expression position (a
    /// `Closure(...)` const-decl RHS type alias), so the alias `CB :: Closure(i32)
    /// -> i32;` parses identically to the annotation `f : Closure(i32) -> i32`.
    ///   Variadic-pack trailing form: `Closure(Prefix..., ..$pack) -> R` binds
    ///   `pack` to a heterogeneous comptime type list at impl match time.
    fn parseClosureTypeBody(self: *Parser, start: u32) anyerror!*Node {
        self.advance(); // skip '('
        var param_types = std.ArrayList(*Node).empty;
        var param_names = std.ArrayList(?[]const u8).empty;
        var has_names = false;
        var pack_name: ?[]const u8 = null;
        var pack_projection: ?[]const u8 = null;
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            if (param_types.items.len > 0) {
                try self.expect(.comma);
                if (self.current.tag == .r_paren) break; // trailing comma ok
            }
            // Trailing pack marker: `..$name` or `..pack.Arg` (terminal only).
            if (self.current.tag == .dot_dot) {
                self.advance(); // skip '..'
                if (self.current.tag == .dollar) self.advance(); // optional sigil
                if (!self.isIdentLike()) {
                    return self.fail("expected pack name after '..' in Closure type");
                }
                pack_name = self.tokenSlice(self.current);
                self.advance();
                // Optional projection: `..sources.T` picks a type-arg per element.
                if (self.current.tag == .dot) {
                    self.advance(); // skip '.'
                    if (!self.isIdentLike()) {
                        return self.fail("expected projection name after '.' in Closure pack");
                    }
                    pack_projection = self.tokenSlice(self.current);
                    self.advance();
                }
                // Pack must be the LAST item — only `)` accepted next.
                if (self.current.tag != .r_paren) {
                    return self.fail("variadic pack must be the last parameter in Closure type");
                }
                break;
            }
            // Check for optional param name: `name: Type`
            if (self.current.tag == .identifier and self.peekNext() == .colon) {
                const pname = self.tokenSlice(self.current);
                self.advance(); // skip name
                self.advance(); // skip ':'
                try param_names.append(self.allocator, pname);
                has_names = true;
            } else {
                try param_names.append(self.allocator, null);
            }
            try param_types.append(self.allocator, try self.parseTypeExpr());
        }
        try self.expect(.r_paren);
        var return_type: ?*Node = null;
        if (self.current.tag == .arrow) {
            self.advance();
            // A failable closure return is the canonical parenthesized
            // list `Closure(i64) -> (i64, !E)` (parseFnReturnType rejects
            // the bare `Closure(i64) -> i64 !E` spelling).
            return_type = try self.parseFnReturnType();
        }
        return try self.createNode(start, .{ .closure_type_expr = .{
            .param_types = try param_types.toOwnedSlice(self.allocator),
            .param_names = if (has_names) try param_names.toOwnedSlice(self.allocator) else null,
            .return_type = return_type,
            .pack_name = pack_name,
            .pack_projection = pack_projection,
        } });
    }

    /// `parsePostfix`, mirroring `Name.{ ... }` typed struct literals).
    ///   `Tuple(A, B)` / `Tuple(T)` / `Tuple()` / named `Tuple(x: A, y: B)` /
    ///   pack `Tuple(..Ts)` / `Tuple(..F(Ts))`. Lowers to the SAME
    ///   `tuple_type_expr` the inline `(A, B)` / `(x: A, y: B)` / `(..Ts)`
    ///   forms produce. Unlike `Closure`, a trailing `->` is REJECTED.
    fn parseTupleTypeBody(self: *Parser, start: u32) anyerror!*Node {
        self.advance(); // skip '('
        var field_types = std.ArrayList(*Node).empty;
        var field_name_opt = std.ArrayList(?[]const u8).empty;
        var has_names = false;
        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            if (field_types.items.len > 0) {
                try self.expect(.comma);
                if (self.current.tag == .r_paren) break; // trailing comma ok
            }
            // Pack-spread field: `Tuple(..Ts)` / `Tuple(..F(Ts))` /
            // `Tuple(..Ts.Arg)`. Reuses `spread_expr` (same machinery as
            // the inline tuple-type and Closure pack paths).
            if (self.current.tag == .dot_dot) {
                const sp_start = self.current.loc.start;
                self.advance(); // skip '..'
                const operand = try self.parseTypeExpr();
                try field_name_opt.append(self.allocator, null);
                try field_types.append(self.allocator, try self.createNode(sp_start, .{ .spread_expr = .{ .operand = operand } }));
                continue;
            }
            // Named field: `name: Type` (keeps `:`).
            if (self.isIdentLike() and self.peekNext() == .colon) {
                const fname = self.tokenSlice(self.current);
                self.advance(); // skip name
                self.advance(); // skip ':'
                try field_name_opt.append(self.allocator, fname);
                has_names = true;
            } else {
                try field_name_opt.append(self.allocator, null);
            }
            // A literal element (`Tuple(i32, 1)`) is NOT a type. Parse it as a
            // value expression so the lowering type-arg check rejects it with
            // the precise "tuple type element is not a type" diagnostic, rather
            // than `parseTypeExpr` bailing here with a generic "expected type
            // name" parse error. Type-shaped elements still go through the type
            // parser (so `*T`, `[N]T`, `Tuple(...)`, names all parse).
            if (self.currentTokenIsValueLiteral()) {
                // A leading `+` on a signed literal (`Tuple(i32, +1)`) has no
                // unary-op parse; consume it so the number parses as a bare
                // value literal. `parseUnary` handles the `-` case and falls
                // through to `parsePrimary` for an unsigned literal.
                if (self.current.tag == .plus) self.advance();
                try field_types.append(self.allocator, try self.parseUnary());
            } else {
                try field_types.append(self.allocator, try self.parseTypeExpr());
            }
        }
        try self.expect(.r_paren);
        // A `Tuple(...)` has NO return type — reject `-> R` loudly rather
        // than silently swallowing it the way `Closure` consumes it.
        if (self.current.tag == .arrow) {
            return self.fail("`Tuple` has no return type — remove the `->`");
        }
        // Per-slot field names are non-optional in the AST; synthesize
        // `_<i>` for any unnamed slot (mirrors the inline named-tuple path).
        var field_names: ?[]const []const u8 = null;
        if (has_names) {
            var fns = std.ArrayList([]const u8).empty;
            for (field_name_opt.items, 0..) |fn_opt, i| {
                try fns.append(self.allocator, fn_opt orelse try std.fmt.allocPrint(self.allocator, "_{d}", .{i}));
            }
            field_names = try fns.toOwnedSlice(self.allocator);
        }
        return try self.createNode(start, .{ .tuple_type_expr = .{
            .field_types = try field_types.toOwnedSlice(self.allocator),
            .field_names = field_names,
        } });
    }

    /// Builds the SAME `tuple_literal` node as the inline `(a, b)` form so the
    /// two are structurally identical (operators / splat / `.0` all work with no
    /// target type). Supports positional, 1-tuple, empty, named (`x = a`, using
    /// `=`), spread (`..xs` / `..xs.field`) and nesting.
    /// Save state, skip past matching parens, return the tag of the next token, then restore.
    /// Returns null if no matching ')' found before EOF.
    fn peekPastParens(self: *Parser) ?Tag {
        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_prev_end = self.prev_end;
        defer {
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.prev_end = saved_prev_end;
        }
        self.advance(); // skip '('
        var depth: u32 = 1;
        while (depth > 0 and self.current.tag != .eof) {
            if (self.current.tag == .l_paren) depth += 1;
            if (self.current.tag == .r_paren) depth -= 1;
            if (depth > 0) self.advance();
        }
        if (self.current.tag != .r_paren) return null;
        self.advance(); // skip ')'
        return self.current.tag;
    }

    /// Returns true when the current `(` opens a function-type literal `(T1, T2) -> R`
    /// rather than a tuple/grouping/lambda. Only meaningful after `isLambda` has
    /// returned false — at that point a trailing `->` after the matching `)` can
    /// only be a function type, since any body (`=>` or `{`) would have made it
    /// a lambda.
    fn isFunctionTypeExprAtLParen(self: *Parser) bool {
        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_prev_end = self.prev_end;
        defer {
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.prev_end = saved_prev_end;
        }
        self.advance(); // skip '('
        var depth: u32 = 1;
        while (depth > 0 and self.current.tag != .eof) {
            if (self.current.tag == .l_paren) depth += 1;
            if (self.current.tag == .r_paren) depth -= 1;
            if (depth > 0) self.advance();
        }
        if (self.current.tag != .r_paren) return false;
        self.advance(); // skip ')'
        return self.current.tag == .arrow;
    }

    fn isLambda(self: *Parser) bool {
        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_prev_end = self.prev_end;
        defer {
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.prev_end = saved_prev_end;
        }

        // Check upfront if parens look like function params (for block-body disambiguation)
        const has_param_parens = blk: {
            self.advance(); // skip '('
            if (self.current.tag == .r_paren) break :blk true; // empty parens
            if (self.current.tag != .identifier) break :blk false;
            self.advance();
            break :blk self.current.tag == .colon or
                self.current.tag == .comma or
                self.current.tag == .r_paren;
        };

        // Restore to '(' and scan past parens inline (not via peekPastParens which restores state)
        self.lexer = saved_lexer;
        self.current = saved_current;
        self.prev_end = saved_prev_end;
        self.advance(); // skip '('
        var depth: u32 = 1;
        while (depth > 0 and self.current.tag != .eof) {
            if (self.current.tag == .l_paren) depth += 1;
            if (self.current.tag == .r_paren) depth -= 1;
            if (depth > 0) self.advance();
        }
        if (self.current.tag != .r_paren) return false;
        self.advance(); // skip ')' — now positioned on token after parens

        const tag = self.current.tag;
        // (params) => expr
        if (tag == .fat_arrow) return true;
        // (params) -> ReturnType => expr
        // (params) -> ReturnType { stmts }
        if (tag == .arrow) {
            self.advance(); // skip '->'
            // Skip past the return type tokens until we see '=>', '{', or something unexpected
            while (self.current.tag != .eof) {
                if (self.current.tag == .fat_arrow) return true;
                if (self.current.tag == .l_brace) return true;
                if (self.current.tag == .identifier or self.current.tag.isTypeKeyword() or
                    self.current.tag == .dot or self.current.tag == .dollar or
                    self.current.tag == .l_bracket or self.current.tag == .r_bracket or
                    self.current.tag == .l_paren or self.current.tag == .r_paren or
                    self.current.tag == .comma or self.current.tag == .int_literal or
                    self.current.tag == .star or self.current.tag == .question or
                    self.current.tag == .bang)
                {
                    self.advance();
                } else break;
            }
            return false;
        }
        // (params) { stmts } — block-body lambda
        // Only if contents look like function params (have `:` type annotations or is empty `()`)
        if (tag == .l_brace) {
            return has_param_parens;
        }
        return false;
    }

    fn parseLambda(self: *Parser) anyerror!*Node {
        const start = self.current.loc.start;
        const params = try self.parseParams();

        // Optional return type: (params) -> Type => expr  OR  (params) -> Type { stmts }
        var return_type: ?*Node = null;
        if (self.current.tag == .arrow) {
            self.advance();
            return_type = try self.parseFnReturnType();
        }

        // Optional ABI annotation: abi(.c) / abi(.zig) / abi(.naked)
        const abi = try self.parseOptionalAbi();

        // A closure is its own function boundary: clear the cleanup-body flags
        // so control-flow exits inside the closure body (`return` from the
        // closure, etc.) are legal even when the closure literal appears inside
        // a `defer` / `onfail` body. Restored after the body.
        const saved_onfail = self.in_onfail_body;
        const saved_defer = self.in_defer_body;
        const saved_module_if = self.in_module_inline_if;
        self.in_onfail_body = false;
        self.in_defer_body = false;
        // A closure body's declarations are locals, never module scope.
        self.in_module_inline_if = false;
        defer {
            self.in_onfail_body = saved_onfail;
            self.in_defer_body = saved_defer;
            self.in_module_inline_if = saved_module_if;
        }

        // Two body forms:
        // (params) => expr          — expression lambda
        // (params) { stmts }        — block-body lambda
        const body = if (self.current.tag == .l_brace)
            try self.parseBlock()
        else blk: {
            try self.expect(.fat_arrow);
            break :blk try self.parseExpr();
        };
        const type_params = try self.collectTypeParams(params);
        return try self.createNode(start, .{ .lambda = .{
            .params = params,
            .return_type = return_type,
            .body = body,
            .type_params = type_params,
            .abi = abi,
        } });
    }

    // ---- Helpers ----

    /// Returns true if the current token can be used as an identifier name.
    /// Includes actual identifiers plus contextual keywords that are only
    /// keywords in specific syntactic positions (e.g., `protocol`, `impl`).
    fn isIdentLike(self: *const Parser) bool {
        return switch (self.current.tag) {
            .identifier, .kw_protocol, .kw_impl, .kw_ufcs, .kw_closure => true,
            else => false,
        };
    }

    fn isFunctionDef(self: *Parser) bool {
        const tag = self.peekPastParens() orelse return false;
        // `(T1, T2) -> R` without a trailing body (`{`, `=>`, or an extern/
        // builtin marker) is a function-type literal, not a function def.
        if (tag == .arrow) return self.hasFnBodyAfterArrow();
        // `kw_extern`/`kw_export`: a postfix linkage modifier (e.g. `f :: () extern;`
        // with no return type) marks a fn decl just like `abi(...)`.
        // `#set` is a bodied accessor with NO return type, so it sits directly
        // after `)` (`(self, v) #set { … }`) — a fn-def marker like `{`/`=>`.
        return tag == .l_brace or tag == .kw_intrinsic or tag == .fat_arrow or tag == .hash_set or tag == .kw_abi or tag == .kw_extern or tag == .kw_export;
    }

    fn hasFnBodyAfterArrow(self: *Parser) bool {
        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_prev_end = self.prev_end;
        defer {
            self.lexer = saved_lexer;
            self.current = saved_current;
            self.prev_end = saved_prev_end;
        }
        self.advance(); // skip '('
        var depth: u32 = 1;
        while (depth > 0 and self.current.tag != .eof) {
            if (self.current.tag == .l_paren) depth += 1;
            if (self.current.tag == .r_paren) depth -= 1;
            if (depth > 0) self.advance();
        }
        if (self.current.tag != .r_paren) return false;
        self.advance(); // skip ')'
        if (self.current.tag != .arrow) return false;
        self.advance(); // skip '->'
        while (self.current.tag != .eof) {
            // An inline `struct { … }` / `union { … }` / `enum { … }` return
            // type: the brace group after the keyword belongs to the TYPE,
            // not the body — skip it balanced and keep scanning for the real
            // body `{` (issue 0291). The bodyless alias edge still holds:
            // `F :: () -> struct { x: i64; };` resumes the scan at `;`,
            // finds no body, and classifies as a type alias.
            if (self.current.tag == .kw_struct or self.current.tag == .kw_union or
                self.current.tag == .kw_enum)
            {
                self.advance(); // the keyword
                if (self.current.tag != .l_brace) return false;
                self.advance(); // the type's '{'
                var brace_depth: u32 = 1;
                while (brace_depth > 0 and self.current.tag != .eof) {
                    if (self.current.tag == .l_brace) brace_depth += 1;
                    if (self.current.tag == .r_brace) brace_depth -= 1;
                    self.advance();
                }
                continue;
            }
            if (self.current.tag == .fat_arrow) return true;
            if (self.current.tag == .l_brace) return true;
            if (self.current.tag == .kw_intrinsic) return true;
            if (self.current.tag == .hash_get) return true; // `-> R #get => …` is a fn def
            if (self.current.tag == .hash_set) return true; // `-> R #set { … }` is a fn def
            if (self.current.tag == .kw_abi) return true;
            // Postfix linkage modifier after the return type: `-> R extern;` /
            // `-> R export { … }` (and `-> R abi(.c) extern`). Marks a fn def.
            if (self.current.tag == .kw_extern or self.current.tag == .kw_export) return true;
            if (self.current.tag == .identifier or self.current.tag.isTypeKeyword() or
                self.current.tag == .dot or self.current.tag == .dollar or
                self.current.tag == .l_bracket or self.current.tag == .r_bracket or
                self.current.tag == .l_paren or self.current.tag == .r_paren or
                self.current.tag == .comma or self.current.tag == .int_literal or
                // Arithmetic operators appear in a const-expression dimension /
                // lane / value-param in a return type: `-> [N + 1]f32`,
                // `-> Vector(N + 1, f32)`. They must be skipped while scanning
                // for the body brace, else the decl is misread as a bodyless
                // function-type alias and the `{` body errors as "expected ';'".
                // (`.star` doubles as the pointer sigil and is already listed.)
                self.current.tag == .star or self.current.tag == .slash or
                self.current.tag == .percent or self.current.tag == .plus or
                self.current.tag == .minus or self.current.tag == .question or
                self.current.tag == .bang or
                // A named multi-return slot DEFAULT (`-> (sum: i32 = 0, …)`):
                // skip the `=` and the value expression's literal tokens so the
                // scan keeps going to the body `{`, instead of misreading the
                // decl as a bodyless function-type alias.
                self.current.tag == .equal or self.current.tag == .float_literal or
                self.current.tag == .string_literal or self.current.tag == .char_literal or
                self.current.tag == .kw_true or self.current.tag == .kw_false or
                self.current.tag == .colon or self.current.tag == .arrow)
            {
                self.advance();
            } else break;
        }
        return false;
    }

    /// Optional ABI / calling-convention annotation `abi(.c)` / `abi(.zig)` /
    /// `abi(.naked)` in the postfix slot before `extern`/`export`. `.default` when
    /// absent. Subsumes the old `callconv(...)` spelling.
    fn parseOptionalAbi(self: *Parser) anyerror!ast.ABI {
        if (self.current.tag != .kw_abi) return .default;
        self.advance();
        try self.expect(.l_paren);
        try self.expect(.dot);
        if (self.current.tag != .identifier)
            return self.fail("expected ABI name ('.c' or '.naked') after '.'");
        const abi_name = self.tokenSlice(self.current);
        const abi: ast.ABI = if (std.mem.eql(u8, abi_name, "c"))
            .c
        else if (std.mem.eql(u8, abi_name, "naked"))
            .naked
        else
            return self.fail("unknown ABI (expected '.c' or '.naked')");
        self.advance();
        try self.expect(.r_paren);
        return abi;
    }

    /// Postfix linkage modifier in the slot after `abi(...)`:
    /// `extern` (import) or `export` (define + expose), or `.none` if neither.
    fn parseOptionalExternExport(self: *Parser) ast.ExternExportModifier {
        switch (self.current.tag) {
            .kw_extern => {
                self.advance();
                return .extern_;
            },
            .kw_export => {
                self.advance();
                return .export_;
            },
            else => return .none,
        }
    }

    fn isAssignOp(self: *const Parser) bool {
        return switch (self.current.tag) {
            .equal,
            .plus_equal,
            .minus_equal,
            .star_equal,
            .slash_equal,
            .percent_equal,
            .ampersand_equal,
            .pipe_equal,
            .caret_equal,
            .less_less_equal,
            .greater_greater_equal,
            => true,
            else => false,
        };
    }

    fn assignOp(self: *const Parser) ast.Assignment.Op {
        return switch (self.current.tag) {
            .equal => .assign,
            .plus_equal => .add_assign,
            .minus_equal => .sub_assign,
            .star_equal => .mul_assign,
            .slash_equal => .div_assign,
            .percent_equal => .mod_assign,
            .ampersand_equal => .and_assign,
            .pipe_equal => .or_assign,
            .caret_equal => .xor_assign,
            .less_less_equal => .shl_assign,
            .greater_greater_equal => .shr_assign,
            else => unreachable,
        };
    }

    fn parseMultiAssign(self: *Parser, first_target: *Node, start: u32) !*Node {
        var targets = std.ArrayList(*Node).empty;
        try targets.append(self.allocator, first_target);

        // Consume remaining targets separated by commas
        while (self.current.tag == .comma) {
            self.advance();
            const target = try self.parseExpr();
            try targets.append(self.allocator, target);
        }

        // Destructuring declaration: a, b := expr;
        if (self.current.tag == .colon_equal) {
            self.advance();
            // All targets must be plain identifiers
            var names = std.ArrayList([]const u8).empty;
            var name_spans = std.ArrayList(ast.Span).empty;
            var name_is_raw = std.ArrayList(bool).empty;
            for (targets.items) |target| {
                if (target.data != .identifier) {
                    return self.fail("destructuring targets must be identifiers");
                }
                try names.append(self.allocator, target.data.identifier.name);
                try name_spans.append(self.allocator, target.span);
                try name_is_raw.append(self.allocator, target.data.identifier.is_raw);
            }
            const value = try self.parseExpr();
            try self.expectSemicolonAfter(value);
            return try self.createNode(start, .{ .destructure_decl = .{
                .names = try names.toOwnedSlice(self.allocator),
                .name_spans = try name_spans.toOwnedSlice(self.allocator),
                .name_is_raw = try name_is_raw.toOwnedSlice(self.allocator),
                .value = value,
            } });
        }

        // Multi-target assignment: only plain '=' is allowed
        if (self.current.tag != .equal) {
            return self.fail("multi-target assignment requires '=' or ':='");
        }
        self.advance();

        // Parse RHS values separated by commas
        var values = std.ArrayList(*Node).empty;
        const first_val = try self.parseExpr();
        try values.append(self.allocator, first_val);
        while (self.current.tag == .comma) {
            self.advance();
            const val = try self.parseExpr();
            try values.append(self.allocator, val);
        }

        if (targets.items.len != values.items.len) {
            return self.fail("multi-target assignment: target count does not match value count");
        }

        try self.expect(.semicolon);

        return try self.createNode(start, .{ .multi_assign = .{
            .targets = try targets.toOwnedSlice(self.allocator),
            .values = try values.toOwnedSlice(self.allocator),
        } });
    }

    const Prec = struct {
        const none: u8 = 0;
        const pipe: u8 = 1; // |>
        const null_coalesce: u8 = 2; // ??
        const logical_or: u8 = 3; // or
        const logical_and: u8 = 4; // and
        const bit_or: u8 = 5; // |
        const bit_xor: u8 = 6; // ^
        const bit_and: u8 = 7; // &
        const comparison: u8 = 8; // == != < <= > >= in
        const shift: u8 = 9; // << >>
        const additive: u8 = 10; // + -
        const multiplicative: u8 = 11; // * / %
    };

    fn binaryPrec(self: *const Parser) u8 {
        return switch (self.current.tag) {
            .kw_or => Prec.logical_or,
            .kw_and => Prec.logical_and,
            .pipe => Prec.bit_or,
            .caret => Prec.bit_xor,
            .ampersand => Prec.bit_and,
            .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal, .kw_in => Prec.comparison,
            .less_less, .greater_greater => Prec.shift,
            .plus, .minus => Prec.additive,
            .star, .slash, .percent => Prec.multiplicative,
            else => Prec.none,
        };
    }

    fn binaryOp(self: *const Parser) ?ast.BinaryOp.Op {
        return switch (self.current.tag) {
            .kw_and => .and_op,
            .kw_or => .or_op,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .ampersand => .bit_and,
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .equal_equal => .eq,
            .bang_equal => .neq,
            .less => .lt,
            .less_equal => .lte,
            .greater => .gt,
            .greater_equal => .gte,
            .less_less => .shl,
            .greater_greater => .shr,
            .kw_in => .in_op,
            else => null,
        };
    }

    fn isComparisonOp(op: ast.BinaryOp.Op) bool {
        return switch (op) {
            .lt, .lte, .gt, .gte, .eq, .neq => true,
            else => false,
        };
    }

    fn isComparisonToken(self: *const Parser) bool {
        return switch (self.current.tag) {
            .less, .less_equal, .greater, .greater_equal, .equal_equal, .bang_equal => true,
            else => false,
        };
    }

    /// Peek at the next token's tag without consuming.
    fn peekNext(self: *Parser) Tag {
        const saved_lexer = self.lexer;
        const tok = self.lexer.next();
        self.lexer = saved_lexer;
        return tok.tag;
    }

    /// With `current` on `(`: the tag of the token right after the matching
    /// `)`, scanning a throwaway copy of the lexer. Only parens are counted —
    /// they must balance lexically regardless of what nests inside.
    fn tagAfterParenGroup(self: *Parser) Tag {
        var lex = self.lexer;
        var depth: u32 = 1;
        while (true) {
            const tok = lex.next();
            switch (tok.tag) {
                .l_paren => depth += 1,
                .r_paren => {
                    depth -= 1;
                    if (depth == 0) return lex.next().tag;
                },
                .eof => return .eof,
                else => {},
            }
        }
    }

    /// For-header capture rule: a top-level `(` group immediately followed by
    /// `{` or `=>` is the loop capture, so parsePostfix must not consume it
    /// as call arguments.
    fn parenGroupIsForCapture(self: *Parser) bool {
        if (!self.in_for_header) return false;
        const after = self.tagAfterParenGroup();
        return after == .l_brace or after == .fat_arrow;
    }

    const RangeTokenInfo = struct {
        start_exclusive: bool,
        end_inclusive: bool,
        /// True when the lexeme carries an explicit end marker (`=` / `<`
        /// after the dots) — the end expression is then mandatory.
        end_marked: bool,
    };

    /// Range lexemes: each side of `..` takes an optional bound marker, `=`
    /// inclusive / `<` exclusive, defaulting to start-inclusive,
    /// end-exclusive (`a..b` ≡ `a=..<b`).
    fn rangeTokenInfo(tag: Tag) ?RangeTokenInfo {
        return switch (tag) {
            .dot_dot => .{ .start_exclusive = false, .end_inclusive = false, .end_marked = false },
            .dot_dot_eq => .{ .start_exclusive = false, .end_inclusive = true, .end_marked = true },
            .dot_dot_lt => .{ .start_exclusive = false, .end_inclusive = false, .end_marked = true },
            .lt_dot_dot => .{ .start_exclusive = true, .end_inclusive = false, .end_marked = false },
            .lt_dot_dot_eq => .{ .start_exclusive = true, .end_inclusive = true, .end_marked = true },
            .lt_dot_dot_lt => .{ .start_exclusive = true, .end_inclusive = false, .end_marked = true },
            .eq_dot_dot => .{ .start_exclusive = false, .end_inclusive = false, .end_marked = false },
            .eq_dot_dot_eq => .{ .start_exclusive = false, .end_inclusive = true, .end_marked = true },
            .eq_dot_dot_lt => .{ .start_exclusive = false, .end_inclusive = false, .end_marked = true },
            else => null,
        };
    }

    fn advance(self: *Parser) void {
        self.prev_end = self.current.loc.end;
        self.current = self.lexer.next();
    }

    fn expect(self: *Parser, tag: Tag) !void {
        if (self.current.tag != tag) {
            const expected = tag.lexeme() orelse @tagName(tag);
            return self.failFmt("expected '{s}'", .{expected});
        }
        self.advance();
    }

    fn failFmt(self: *Parser, comptime fmt: []const u8, args: anytype) error{ParseError} {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.ParseError;
        return self.fail(msg);
    }

    /// A cleanup body is a `defer` or `onfail` body. Control-flow exits
    /// (`raise` / `try` / `return` / `break` / `continue`) are banned inside one:
    /// cleanup runs while the block/function is already exiting, so there is
    /// nothing to propagate or transfer to. The ban is transitive through nested
    /// `catch` bodies and loops, but NOT through a nested closure body — a
    /// closure is its own function boundary (parseLambda clears the flags).
    fn inCleanupBody(self: *const Parser) bool {
        return self.in_onfail_body or self.in_defer_body;
    }

    /// The cleanup-body phrase for diagnostics, with article (`onfail` takes
    /// precedence when both are set, e.g. an `onfail` nested in a `defer`).
    fn cleanupKind(self: *const Parser) []const u8 {
        return if (self.in_onfail_body) "an `onfail`" else "a `defer`";
    }

    /// Reject a control-flow exit `kw` (e.g. "return") inside a cleanup body.
    fn rejectInCleanup(self: *Parser, comptime kw: []const u8) error{ParseError}!void {
        if (self.inCleanupBody()) {
            return self.failFmt("`" ++ kw ++ "` is not allowed inside {s} body — cleanup runs while the function is already exiting, so there is nothing to transfer control to", .{self.cleanupKind()});
        }
    }

    fn tokenSlice(self: *const Parser, token: Token) []const u8 {
        return self.source[token.loc.start..token.loc.end];
    }

    /// Detect the base of an integer-literal token (`0x`/`0o`/`0b` prefixes),
    /// strip the 2-char prefix and ALL `_` visual separators into a scratch
    /// buffer, then parse the remaining digits as a full-range `u64`. Returns
    /// null on overflow / invalid digits (the caller emits its own diagnostic).
    /// A literal may exceed 64 chars once separators + leading zeros are counted,
    /// so the scratch buffer is heap-allocated via `self.allocator`, not a fixed
    /// stack array.
    fn parseIntLiteralText(self: *Parser, text: []const u8) ?u64 {
        const base: u8 = if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X'))
            16
        else if (text.len > 2 and text[0] == '0' and (text[1] == 'o' or text[1] == 'O'))
            8
        else if (text.len > 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B'))
            2
        else
            10;
        const digits = if (base != 10) text[2..] else text;
        const stripped = self.stripSeparators(digits) catch return null;
        defer self.allocator.free(stripped);
        return std.fmt.parseInt(u64, stripped, base) catch null;
    }

    /// Copy `text` into a freshly-allocated buffer with every `_` removed.
    /// Caller owns the returned slice (`self.allocator.free`).
    fn stripSeparators(self: *Parser, text: []const u8) ![]u8 {
        const buf = try self.allocator.alloc(u8, text.len);
        var n: usize = 0;
        for (text) |c| {
            if (c == '_') continue;
            buf[n] = c;
            n += 1;
        }
        return buf[0..n];
    }

    /// After a `.` in member / enum-literal / variant position, a reserved
    /// keyword (`enum`, `struct`, `union`, `error`, …) is unambiguously the
    /// member NAME — the leading dot rules out the keyword reading, so no
    /// backtick escape is needed (`x.enum`, `.enum(p)`, `case .enum:`).
    /// Returns the token text and advances when `current` is an identifier OR
    /// an identifier-shaped keyword; null otherwise (a real syntax error there,
    /// left for the caller to report).
    fn dotMemberName(self: *Parser) ?[]const u8 {
        const txt = self.tokenSlice(self.current);
        if (self.current.tag == .identifier or getKeyword(txt) != null) {
            self.advance();
            return txt;
        }
        return null;
    }

    fn fail(self: *Parser, msg: []const u8) error{ParseError} {
        self.err_msg = msg;
        self.err_offset = self.current.loc.start;
        self.err_end = self.current.loc.end;
        if (self.diagnostics) |diags| {
            diags.add(.err, msg, .{ .start = self.current.loc.start, .end = self.current.loc.end });
        }
        return error.ParseError;
    }

    /// Like `fail`, but pins the diagnostic to an explicit source span rather
    /// than `self.current` — used when the offending token has already been
    /// consumed (e.g. a lookahead committed past it before the reject decision).
    fn failAt(self: *Parser, loc: anytype, msg: []const u8) error{ParseError} {
        self.err_msg = msg;
        self.err_offset = loc.start;
        self.err_end = loc.end;
        if (self.diagnostics) |diags| {
            diags.add(.err, msg, .{ .start = loc.start, .end = loc.end });
        }
        return error.ParseError;
    }
};

test "parse minimal main" {
    const source = "main :: () { 42; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expect(root.data == .root);
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    try std.testing.expectEqualStrings("main", decl.data.fn_decl.name);
    const body = decl.data.fn_decl.body;
    try std.testing.expect(body.data == .block);
    try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
    try std.testing.expect(body.data.block.stmts[0].data == .int_literal);
    try std.testing.expectEqual(@as(i64, 42), body.data.block.stmts[0].data.int_literal.value);
}

test "parseOptionalExternExport recognizes linkage keywords (unconsumed)" {
    // Phase 0.1 plumbing: the helper exists and maps the keywords, but no
    // decl path calls it yet (wired in Phase 1.0). Drive it directly.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        var parser = Parser.init(arena.allocator(), "extern");
        try std.testing.expectEqual(ast.ExternExportModifier.extern_, parser.parseOptionalExternExport());
    }
    {
        var parser = Parser.init(arena.allocator(), "export");
        try std.testing.expectEqual(ast.ExternExportModifier.export_, parser.parseOptionalExternExport());
    }
    {
        var parser = Parser.init(arena.allocator(), "foo");
        try std.testing.expectEqual(ast.ExternExportModifier.none, parser.parseOptionalExternExport());
    }
}

test "extern/export AST fields default to absent (unconsumed)" {
    // FnDecl.extern_export defaults to .none on a normally-parsed function;
    // the fn-decl path does not consume the modifier until Phase 1.0.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () {}");
    const root = try parser.parse();
    const fd = root.data.root.decls[0].data.fn_decl;
    try std.testing.expectEqual(ast.ExternExportModifier.none, fd.extern_export);

    // VarDecl.is_extern / extern_name default to absent (no var-decl path
    // consumes them until Phase 1.2). A struct literal locks field presence +
    // defaults without depending on a top-level var form.
    const vd: ast.VarDecl = .{
        .name = "g",
        .name_span = .{ .start = 0, .end = 0 },
        .type_annotation = null,
        .value = null,
    };
    try std.testing.expect(!vd.is_extern);
    try std.testing.expect(vd.extern_name == null);
}

test "block value: trailing expr without `;` produces a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> i32 { 42 }");
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(body.data.block.produces_value);
    try std.testing.expect(body.data.block.discarded_semi == null);
}

test "block value: trailing `;` discards the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () -> i32 { 42; }");
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(!body.data.block.produces_value);
    try std.testing.expect(body.data.block.discarded_semi != null);
}

test "block value: match arms are exempt (keep `;`, still produce a value)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: (n: i32) -> i32 { if n == { case 1: 5; else: 0; } }");
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    // Function body's trailing match has no `;` → the body is a value.
    try std.testing.expect(body.data.block.produces_value);
    const match = body.data.block.stmts[0];
    try std.testing.expect(match.data == .match_expr);
    // Each arm body (built with `;`) is still value-producing (exempt).
    for (match.data.match_expr.arms) |arm| {
        try std.testing.expect(arm.body.data.block.produces_value);
    }
}

test "parse #run const binding" {
    const source = "x :: #run compute(5);";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .const_decl);
    try std.testing.expectEqualStrings("x", decl.data.const_decl.name);
    try std.testing.expect(decl.data.const_decl.value.data == .comptime_expr);
    // inner expr is a call
    try std.testing.expect(decl.data.const_decl.value.data.comptime_expr.expr.data == .call);
}

test "parse top-level #run" {
    const source = "#run main();";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .comptime_expr);
    // inner expr is a call
    try std.testing.expect(decl.data.comptime_expr.expr.data == .call);
}

test "parse flat import" {
    const source = "#import \"modules/std/math.sx\";";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .import_decl);
    try std.testing.expectEqualStrings("modules/std/math.sx", decl.data.import_decl.path);
    try std.testing.expect(decl.data.import_decl.name == null);
}

test "parse namespaced import" {
    const source = "std :: #import \"modules/std/std.sx\";";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .import_decl);
    try std.testing.expectEqualStrings("modules/std/std.sx", decl.data.import_decl.path);
    try std.testing.expectEqualStrings("std", decl.data.import_decl.name.?);
}

test "parse library declaration" {
    const source = "rl :: #library \"raylib\";";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .library_decl);
    try std.testing.expectEqualStrings("raylib", decl.data.library_decl.lib_name);
    try std.testing.expectEqualStrings("rl", decl.data.library_decl.name);
}

test "parse void function with builtin body" {
    const source = "foo :: () intrinsic;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    try std.testing.expectEqualStrings("foo", decl.data.fn_decl.name);
    try std.testing.expect(decl.data.fn_decl.body.data == .intrinsic_expr);
}

test "parse void function with extern import" {
    // A postfix `extern LIB` fn import builds an empty-block body +
    // extern_export = .extern_ + extern_lib. (Phase 8 removed the legacy
    // prefix `extern` spelling that used to produce this same shape.)
    const source = "InitWindow :: (width: i32, height: i32, title: *u8) -> void extern rl;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    try std.testing.expectEqualStrings("InitWindow", decl.data.fn_decl.name);
    try std.testing.expectEqual(ast.ExternExportModifier.extern_, decl.data.fn_decl.extern_export);
    try std.testing.expectEqualStrings("rl", decl.data.fn_decl.extern_lib.?);
    try std.testing.expect(decl.data.fn_decl.body.data == .block);
    try std.testing.expectEqual(@as(usize, 0), decl.data.fn_decl.body.data.block.stmts.len);
    try std.testing.expectEqual(@as(usize, 3), decl.data.fn_decl.params.len);
}

test "parse void function with arrow body" {
    const source = "foo :: () => 42;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    try std.testing.expectEqualStrings("foo", decl.data.fn_decl.name);
    try std.testing.expect(decl.data.fn_decl.is_arrow);
    // Arrow bodies are wrapped in a block; the expression is the sole stmt.
    const body = decl.data.fn_decl.body;
    try std.testing.expect(body.data == .block);
    try std.testing.expectEqual(@as(usize, 1), body.data.block.stmts.len);
    try std.testing.expect(body.data.block.stmts[0].data == .int_literal);
    try std.testing.expectEqual(@as(i64, 42), body.data.block.stmts[0].data.int_literal.value);
}

test "parse hex and binary literals" {
    const source = "main :: () { 0xFF; 0b1010; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expectEqual(@as(usize, 2), body.data.block.stmts.len);
    try std.testing.expectEqual(@as(i64, 255), body.data.block.stmts[0].data.int_literal.value);
    try std.testing.expectEqual(@as(i64, 10), body.data.block.stmts[1].data.int_literal.value);
}

test "parse array type with identifier length" {
    const source = "foo :: (arr: [N]f32) => arr;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    const param_type = decl.data.fn_decl.params[0].type_expr;
    try std.testing.expect(param_type.data == .array_type_expr);
    // length is an identifier "N", not an int literal
    try std.testing.expect(param_type.data.array_type_expr.length.data == .identifier);
    try std.testing.expectEqualStrings("N", param_type.data.array_type_expr.length.data.identifier.name);
    try std.testing.expect(param_type.data.array_type_expr.element_type.data == .type_expr);
}

test "parse lambda with generic params" {
    const source = "f :: (x: $T) => x;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const decl = root.data.root.decls[0];
    // A named `::` arrow function is a fn_decl (carrying its own type params).
    try std.testing.expect(decl.data == .fn_decl);
    const fd = decl.data.fn_decl;
    try std.testing.expectEqual(@as(usize, 1), fd.params.len);
    try std.testing.expectEqualStrings("x", fd.params[0].name);
    try std.testing.expectEqual(@as(usize, 1), fd.type_params.len);
    try std.testing.expectEqualStrings("T", fd.type_params[0].name);
}

test "parse lambda with return type" {
    const source = "f :: (x: i32) -> i32 => x;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    const fd = decl.data.fn_decl;
    try std.testing.expect(fd.return_type != null);
    try std.testing.expect(fd.return_type.?.data == .type_expr);
    try std.testing.expectEqualStrings("i32", fd.return_type.?.data.type_expr.name);
}

test "parse match with else arm" {
    const source =
        \\main :: () {
        \\  x := 5;
        \\  if x == {
        \\    case 1: 10;
        \\    else: 99;
        \\  };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    // second stmt is the match expr (after var decl)
    const match_node = body.data.block.stmts[1];
    try std.testing.expect(match_node.data == .match_expr);
    const arms = match_node.data.match_expr.arms;
    try std.testing.expectEqual(@as(usize, 2), arms.len);
    // first arm has a pattern
    try std.testing.expect(arms[0].pattern != null);
    // second arm is the else arm (null pattern)
    try std.testing.expect(arms[1].pattern == null);
}

test "integer literal overflow error" {
    const source = "main :: () { 99999999999999999999; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const result = parser.parse();
    try std.testing.expectError(error.ParseError, result);
    try std.testing.expectEqualStrings("integer literal overflow", parser.err_msg.?);
}

test "parse pack-constrained variadic parameter (..xs: Protocol)" {
    const source = "map :: (..sources: ValueListenable) => sources;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const params = root.data.root.decls[0].data.fn_decl.params;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    const p = params[0];
    try std.testing.expect(p.is_variadic);
    try std.testing.expect(p.is_pack); // protocol-constrained pack
    try std.testing.expect(!p.is_comptime);
    try std.testing.expectEqualStrings("sources", p.name);
    // The constraint is a bare type reference, not a slice.
    try std.testing.expect(p.type_expr.data == .type_expr);
    try std.testing.expectEqualStrings("ValueListenable", p.type_expr.data.type_expr.name);
}

test "parse slice variadic is NOT a pack (..xs: []T)" {
    const source = "join :: (..parts: []string) => parts;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const p = root.data.root.decls[0].data.fn_decl.params[0];
    try std.testing.expect(p.is_variadic);
    try std.testing.expect(!p.is_pack); // slice variadic, not a pack
    try std.testing.expect(p.type_expr.data == .slice_type_expr);
}

test "parse comptime type-pack is NOT a protocol pack (..$args)" {
    const source = "foo :: (..$args) => args;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const p = root.data.root.decls[0].data.fn_decl.params[0];
    try std.testing.expect(p.is_variadic);
    try std.testing.expect(p.is_comptime); // comptime type pack
    try std.testing.expect(!p.is_pack); // not the protocol-constrained form
}

// ── Step 1.2 — pack expansion in the four positions ───────────────────
// All spread forms reuse `spread_expr` (its operand carries any projection /
// type-application); closure-sig packs use ClosureTypeExpr.pack_name +
// pack_projection. Arrow bodies wrap the expression in a block.

test "parse pack expansion: brace value .{..xs}" {
    const source = "f :: () => .{..xs};";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    const lit = body.data.block.stmts[0];
    try std.testing.expect(lit.data == .struct_literal);
    try std.testing.expectEqual(@as(usize, 1), lit.data.struct_literal.field_inits.len);
    const el = lit.data.struct_literal.field_inits[0].value;
    try std.testing.expect(el.data == .spread_expr);
    try std.testing.expect(el.data.spread_expr.operand.data == .identifier);
    try std.testing.expectEqualStrings("xs", el.data.spread_expr.operand.data.identifier.name);
}

test "parse pack expansion: brace value projection .{..xs.value}" {
    const source = "f :: () => .{..xs.value};";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const lit = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const el = lit.data.struct_literal.field_inits[0].value;
    try std.testing.expect(el.data == .spread_expr);
    const op = el.data.spread_expr.operand;
    try std.testing.expect(op.data == .field_access);
    try std.testing.expectEqualStrings("value", op.data.field_access.field);
    try std.testing.expect(op.data.field_access.object.data == .identifier);
    try std.testing.expectEqualStrings("xs", op.data.field_access.object.data.identifier.name);
}

test "parse pack expansion: tuple type Tuple(..F(Ts))" {
    const source = "g :: (x: Tuple(..F(Ts))) => x;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const ty = root.data.root.decls[0].data.fn_decl.params[0].type_expr;
    try std.testing.expect(ty.data == .tuple_type_expr);
    try std.testing.expectEqual(@as(usize, 1), ty.data.tuple_type_expr.field_types.len);
    const field = ty.data.tuple_type_expr.field_types[0];
    try std.testing.expect(field.data == .spread_expr);
    const op = field.data.spread_expr.operand;
    try std.testing.expect(op.data == .parameterized_type_expr);
    try std.testing.expectEqualStrings("F", op.data.parameterized_type_expr.name);
}

test "parse pack expansion: closure sig projection Closure(..sources.T)" {
    const source = "h :: (cb: Closure(..sources.T) -> i32) => cb;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const ty = root.data.root.decls[0].data.fn_decl.params[0].type_expr;
    try std.testing.expect(ty.data == .closure_type_expr);
    try std.testing.expectEqualStrings("sources", ty.data.closure_type_expr.pack_name.?);
    try std.testing.expectEqualStrings("T", ty.data.closure_type_expr.pack_projection.?);
}

test "parse closure sig bare pack Closure(..Ts) has no projection" {
    const source = "j :: (cb: Closure(..Ts) -> i32) => cb;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const ty = root.data.root.decls[0].data.fn_decl.params[0].type_expr;
    try std.testing.expect(ty.data == .closure_type_expr);
    try std.testing.expectEqualStrings("Ts", ty.data.closure_type_expr.pack_name.?);
    try std.testing.expect(ty.data.closure_type_expr.pack_projection == null);
}

test "parse pack expansion: call-arg spread q(..xs) reuses spread_expr" {
    const source = "k :: () => q(..xs);";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const call = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(call.data == .call);
    try std.testing.expectEqual(@as(usize, 1), call.data.call.args.len);
    try std.testing.expect(call.data.call.args[0].data == .spread_expr);
}

// ── ERR step E0.1 — `error { ... }` decls + `!` / `!Named` type exprs ──

test "parse error-set decl: tags collected" {
    const source = "ParseErr :: error { BadDigit, Overflow, Empty }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .error_set_decl);
    try std.testing.expectEqualStrings("ParseErr", decl.data.error_set_decl.name);
    const tags = decl.data.error_set_decl.tag_names;
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("BadDigit", tags[0]);
    try std.testing.expectEqualStrings("Overflow", tags[1]);
    try std.testing.expectEqualStrings("Empty", tags[2]);
}

test "parse error-set decl: single tag, trailing comma, trailing semicolon" {
    const source = "E :: error { Only, };";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .error_set_decl);
    const tags = decl.data.error_set_decl.tag_names;
    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("Only", tags[0]);
}

test "parse bare failable return: inferred `!`" {
    const source = "f :: () -> ! { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .error_type_expr);
    try std.testing.expect(rt.data.error_type_expr.name == null);
}

test "parse bare failable return: named `!Foo`" {
    const source = "f :: () -> !ParseErr { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .error_type_expr);
    try std.testing.expectEqualStrings("ParseErr", rt.data.error_type_expr.name.?);
}

test "parse single-value failable `-> (T, !)`" {
    const source = "f :: () -> (i32, !) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .tuple_type_expr);
    const fields = rt.data.tuple_type_expr.field_types;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[0].data == .type_expr);
    try std.testing.expectEqualStrings("i32", fields[0].data.type_expr.name);
    try std.testing.expect(fields[1].data == .error_type_expr);
    try std.testing.expect(fields[1].data.error_type_expr.name == null);
}

test "parse multi-value named failable `-> (A, B, !Foo)`" {
    const source = "f :: () -> (i32, i64, !ParseErr) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .return_type_expr or rt.data == .tuple_type_expr);
    const fields = if (rt.data == .return_type_expr) rt.data.return_type_expr.field_types else rt.data.tuple_type_expr.field_types;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expect(fields[2].data == .error_type_expr);
    try std.testing.expectEqualStrings("ParseErr", fields[2].data.error_type_expr.name.?);
}

test "parse legacy bare failable `-> T !` is rejected" {
    const source = "f :: () -> i32 ! { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "parse old bare-paren failable `-> (!, i32)` is rejected" {
    const source = "f :: () -> (!, i32) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "parse old bare-paren failable `-> (i32, !, i64)` is rejected" {
    const source = "f :: () -> (i32, !, i64) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "round-trip print: error-set decl" {
    const source = "ParseErr :: error { BadDigit, Overflow, Empty }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    try print.printNode(root.data.root.decls[0], &aw.writer);
    try std.testing.expectEqualStrings(source, aw.writer.toArrayList().items);
}

test "print: failable result list with pointer + named error renders canonically" {
    // A single value + named error channel `(*Handle, !IoErr)` renders back as
    // the canonical parenthesized result list.
    const source = "open :: () -> (*Handle, !IoErr) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    try print.printType(rt, &aw.writer);
    try std.testing.expectEqualStrings("(*Handle, !IoErr)", aw.writer.toArrayList().items);
}

test "round-trip print: bare inferred and named error types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        var parser = Parser.init(arena.allocator(), "f :: () -> ! { 0; }");
        const root = try parser.parse();
        const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
        var aw = std.Io.Writer.Allocating.init(arena.allocator());
        try print.printType(rt, &aw.writer);
        try std.testing.expectEqualStrings("!", aw.writer.toArrayList().items);
    }
    {
        var parser = Parser.init(arena.allocator(), "f :: () -> !ParseErr { 0; }");
        const root = try parser.parse();
        const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
        var aw = std.Io.Writer.Allocating.init(arena.allocator());
        try print.printType(rt, &aw.writer);
        try std.testing.expectEqualStrings("!ParseErr", aw.writer.toArrayList().items);
    }
}

// ── ERR step E0.2 — raise / try / catch / onfail + precedence + pipe ──

/// Parse `src` (a single `f :: () { ... }` decl) and return its body's first
/// statement node.
fn e02FirstStmt(alloc: std.mem.Allocator, src: [:0]const u8) anyerror!*Node {
    var parser = Parser.init(alloc, src);
    const root = try parser.parse();
    return root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
}

/// Parse `src` (a `f :: () { v := EXPR; }` decl) and return the EXPR node.
fn e02FirstValue(alloc: std.mem.Allocator, src: [:0]const u8) anyerror!*Node {
    const stmt = try e02FirstStmt(alloc, src);
    return stmt.data.var_decl.value.?;
}

fn e02ExpectPrints(alloc: std.mem.Allocator, node: *const Node, expected: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(alloc);
    try print.printNode(node, &aw.writer);
    try std.testing.expectEqualStrings(expected, aw.writer.toArrayList().items);
}

test "S4.1 postfix cast parses: a.(i8)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := a.(i8); }");
    try std.testing.expect(v.data == .postfix_cast);
    try e02ExpectPrints(arena.allocator(), v, "a.(i8)");
}

test "S4.1 postfix cast: int-literal receiver does not lex as a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := 56.(i8); }");
    try std.testing.expect(v.data == .postfix_cast);
    try std.testing.expect(v.data.postfix_cast.operand.data == .int_literal);
}

test "S4.1 postfix cast: composite targets *T / []u8 / ?T" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try e02FirstValue(arena.allocator(), "f :: () { v := x.(*Point); }");
    try std.testing.expect(p.data == .postfix_cast);
    try e02ExpectPrints(arena.allocator(), p, "x.(*Point)");
    const s = try e02FirstValue(arena.allocator(), "f :: () { v := x.([]u8); }");
    try std.testing.expect(s.data == .postfix_cast);
    const o = try e02FirstValue(arena.allocator(), "f :: () { v := x.(?i64); }");
    try std.testing.expect(o.data == .postfix_cast);
    try std.testing.expect(o.data.postfix_cast.type_expr.data == .optional_type_expr);
}

test "S4.1 postfix cast binds tighter than unary minus: -x.(i8)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := -x.(i8); }");
    try std.testing.expect(v.data == .unary_op and v.data.unary_op.op == .negate);
    try std.testing.expect(v.data.unary_op.operand.data == .postfix_cast);
}

test "E4 postfix cast: '.(P, alloc)' parses with the allocator argument; a third element is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x.(P, alloc); }");
    try std.testing.expect(v.data == .postfix_cast);
    try std.testing.expect(v.data.postfix_cast.alloc_arg != null);
    try std.testing.expectError(error.ParseError, e02FirstValue(arena.allocator(), "f :: () { v := x.(P, a, b); }"));
}

test "S4.2c optional-chained cast parses: x?.(i64)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x?.(i64); }");
    try std.testing.expect(v.data == .postfix_cast);
    try std.testing.expect(v.data.postfix_cast.is_optional_chain);
    try e02ExpectPrints(arena.allocator(), v, "x?.(i64)");
}

test "E0.2 try binds tighter than or: try foo() or try boo()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := try foo() or try boo(); }");
    try std.testing.expect(v.data == .binary_op);
    try std.testing.expect(v.data.binary_op.op == .or_op);
    try std.testing.expect(v.data.binary_op.lhs.data == .try_expr);
    try std.testing.expect(v.data.binary_op.rhs.data == .try_expr);
}

test "E0.2 or is left-associative: a or b or c => (a or b) or c" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := try a() or try b() or try c(); }");
    try std.testing.expect(v.data == .binary_op and v.data.binary_op.op == .or_op);
    // LHS is the nested (a or b); RHS is the final operand.
    try std.testing.expect(v.data.binary_op.lhs.data == .binary_op);
    try std.testing.expect(v.data.binary_op.lhs.data.binary_op.op == .or_op);
    try std.testing.expect(v.data.binary_op.rhs.data == .try_expr);
}

test "E0.2 try prefix stacks under xx: xx try foo()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := xx try foo(); }");
    try std.testing.expect(v.data == .unary_op and v.data.unary_op.op == .xx);
    try std.testing.expect(v.data.unary_op.operand.data == .try_expr);
}

test "E0.2 catch no binding, braced body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch { }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expect(v.data.catch_expr.binding == null);
    try std.testing.expect(v.data.catch_expr.is_match_body == false);
    try std.testing.expect(v.data.catch_expr.body.data == .block);
}

test "E0.2 catch with binding, block body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch (e) { bar(); }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expectEqualStrings("e", v.data.catch_expr.binding.?);
    try std.testing.expect(v.data.catch_expr.body.data == .block);
}

test "E0.2 catch with binding, bare-expression body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch (e) bar(); }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expectEqualStrings("e", v.data.catch_expr.binding.?);
    try std.testing.expect(v.data.catch_expr.is_match_body == false);
    try std.testing.expect(v.data.catch_expr.body.data == .call);
}

test "E0.2 catch match-body desugars to match_expr over the binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch (e) == { case .Empty: 0; else: 1; }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expect(v.data.catch_expr.is_match_body);
    try std.testing.expect(v.data.catch_expr.body.data == .match_expr);
    try std.testing.expectEqual(@as(usize, 2), v.data.catch_expr.body.data.match_expr.arms.len);
    // subject is the binding identifier
    try std.testing.expect(v.data.catch_expr.body.data.match_expr.subject.data == .identifier);
    try std.testing.expectEqualStrings("e", v.data.catch_expr.body.data.match_expr.subject.data.identifier.name);
}

test "E0.2 catch over a parenthesized or-chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := (try foo() or try boo()) catch (e) { }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expect(v.data.catch_expr.operand.data == .binary_op);
    try std.testing.expect(v.data.catch_expr.operand.data.binary_op.op == .or_op);
}

test "E0.2 catch without binding and unbraced body is rejected" {
    // No binding (the token after `catch` is not an identifier) and no braces:
    // the no-binding form requires a braced body.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { v := foo() catch 42; }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E0.2 raise error.X parses as raise_stmt over a field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try e02FirstStmt(arena.allocator(), "f :: () { raise error.BadDigit; }");
    try std.testing.expect(s.data == .raise_stmt);
    try std.testing.expect(s.data.raise_stmt.tag.data == .field_access);
    try std.testing.expectEqualStrings("BadDigit", s.data.raise_stmt.tag.data.field_access.field);
    const obj = s.data.raise_stmt.tag.data.field_access.object;
    try std.testing.expect(obj.data == .identifier);
    try std.testing.expectEqualStrings("error", obj.data.identifier.name);
}

test "E0.2 raise variable form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try e02FirstStmt(arena.allocator(), "f :: () { raise e; }");
    try std.testing.expect(s.data == .raise_stmt);
    try std.testing.expect(s.data.raise_stmt.tag.data == .identifier);
}

test "E0.2 raise rejected in expression position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { x := 1 + raise error.X; }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E0.2 raise rejected inside an onfail body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { onfail { raise error.X; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E1.3 raise rejected inside a defer body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { defer { raise error.X; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E1.7 return rejected inside a defer body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { defer { return; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E1.7 try rejected inside an onfail body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { onfail { try g(); } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E1.7 break rejected inside a defer body (transitive through a loop)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { defer { for 0..1 (i) { break; } } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E1.7 continue rejected inside an onfail body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { onfail (e) { continue; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "E1.7 return inside a closure within a cleanup body is allowed" {
    // A closure is its own function boundary: parseLambda clears the cleanup
    // flags, so `return` from the closure body is legal even inside `defer`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { defer g((x: i32) -> i32 { return x; }); }");
    _ = try parser.parse();
}

test "E1.7 control-flow legal again after the cleanup body (flag restored)" {
    // The cleanup-body flag must not leak to statements that follow the defer.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "f :: () { defer cleanup(); return; }");
    _ = try parser.parse();
}

test "E0.2 onfail with binding and block body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try e02FirstStmt(arena.allocator(), "f :: () { onfail (e) { close(h); } }");
    try std.testing.expect(s.data == .onfail_stmt);
    try std.testing.expectEqualStrings("e", s.data.onfail_stmt.binding.?);
    try std.testing.expect(s.data.onfail_stmt.body.data == .block);
}

test "E0.2 onfail no-binding block vs bare-expression body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const block_body = try e02FirstStmt(arena.allocator(), "f :: () { onfail { close(h); } }");
    try std.testing.expect(block_body.data == .onfail_stmt);
    try std.testing.expect(block_body.data.onfail_stmt.binding == null);
    try std.testing.expect(block_body.data.onfail_stmt.body.data == .block);

    const expr_body = try e02FirstStmt(arena.allocator(), "f :: () { onfail close(h); }");
    try std.testing.expect(expr_body.data == .onfail_stmt);
    try std.testing.expect(expr_body.data.onfail_stmt.binding == null);
    try std.testing.expect(expr_body.data.onfail_stmt.body.data == .call);
}

test "E0.2 consumer-aware pipe: x |> try f() inserts x into the head call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x |> try f(); }");
    try std.testing.expect(v.data == .try_expr);
    const call = v.data.try_expr.operand;
    try std.testing.expect(call.data == .call);
    try std.testing.expectEqual(@as(usize, 1), call.data.call.args.len);
    try std.testing.expect(call.data.call.args[0].data == .identifier);
    try std.testing.expectEqualStrings("x", call.data.call.args[0].data.identifier.name);
}

test "E0.2 consumer-aware pipe: x |> f() catch (e) { } preserves the catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x |> g() catch (e) { }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expectEqualStrings("e", v.data.catch_expr.binding.?);
    try std.testing.expect(v.data.catch_expr.operand.data == .call);
    try std.testing.expectEqual(@as(usize, 1), v.data.catch_expr.operand.data.call.args.len);
}

test "E0.2 consumer-aware pipe: x |> f() or d feeds only the head call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x |> g() or d; }");
    try std.testing.expect(v.data == .binary_op and v.data.binary_op.op == .or_op);
    // LHS (head call g) receives x; RHS fallback `d` is untouched.
    try std.testing.expect(v.data.binary_op.lhs.data == .call);
    try std.testing.expectEqual(@as(usize, 1), v.data.binary_op.lhs.data.call.args.len);
    try std.testing.expect(v.data.binary_op.rhs.data == .identifier);
    try std.testing.expectEqualStrings("d", v.data.binary_op.rhs.data.identifier.name);
}

test "E0.2 plain pipe still works: x |> f(a) => f(x, a)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x |> g(a); }");
    try std.testing.expect(v.data == .call);
    try std.testing.expectEqual(@as(usize, 2), v.data.call.args.len);
    try std.testing.expectEqualStrings("x", v.data.call.args[0].data.identifier.name);
    try std.testing.expectEqualStrings("a", v.data.call.args[1].data.identifier.name);
}

test "E0.2 round-trip print: try / or precedence / raise / catch / onfail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := try foo(); }"), "try foo()");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := try foo() or try boo(); }"), "try foo() or try boo()");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { raise error.BadDigit; }"), "raise error.BadDigit");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { raise e; }"), "raise e");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := foo() catch (e) bar(); }"), "foo() catch (e) bar()");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := foo() catch (e) { bar(); }; }"), "foo() catch (e) { bar(); }");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := foo() catch { bar(); }; }"), "foo() catch { bar(); }");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { onfail close(h); }"), "onfail close(h)");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { onfail (e) { close(h); } }"), "onfail (e) { close(h); }");
}

test "E0.2 round-trip print: catch match-body form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try e02FirstValue(a, "f :: () { v := foo() catch (e) == { case .Empty: 0; else: 1; }; }");
    try e02ExpectPrints(a, v, "foo() catch (e) == { case .Empty: 0; else: 1; }");
}

// ── ERR step E0.3 — coverage consolidation (gaps + integration) ──

test "E0.3 try in statement position (propagate, discard value)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try e02FirstStmt(arena.allocator(), "f :: () { try must_init(); }");
    try std.testing.expect(s.data == .try_expr);
    try std.testing.expect(s.data.try_expr.operand.data == .call);
}

test "E0.3 try over a parenthesized or-chain: try (foo() or boo())" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := try (foo() or boo()); }");
    // Distinct from `try foo() or try boo()`: here `try` wraps the whole chain.
    try std.testing.expect(v.data == .try_expr);
    try std.testing.expect(v.data.try_expr.operand.data == .binary_op);
    try std.testing.expect(v.data.try_expr.operand.data.binary_op.op == .or_op);
}

test "E0.3 or value-terminator: parse(s) or 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := parse(s) or 0; }");
    try std.testing.expect(v.data == .binary_op and v.data.binary_op.op == .or_op);
    try std.testing.expect(v.data.binary_op.lhs.data == .call);
    try std.testing.expect(v.data.binary_op.rhs.data == .int_literal);
}

test "E0.3 full failable function parses end-to-end (all E0 forms)" {
    const source =
        \\parse :: (s: string) -> (i32, !ParseErr) {
        \\    onfail (e) { cleanup(s); }
        \\    v := try inner(s) or 0;
        \\    w := other(s) catch (e2) { return 0; };
        \\    if bad(s) { raise error.BadDigit; }
        \\    return v;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    try std.testing.expectEqualStrings("parse", decl.data.fn_decl.name);
    // return type is a multi-value result list ending in `!ParseErr`
    const rt = decl.data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .tuple_type_expr);
    const fields = rt.data.tuple_type_expr.field_types;
    try std.testing.expect(fields[fields.len - 1].data == .error_type_expr);
    try std.testing.expectEqualStrings("ParseErr", fields[fields.len - 1].data.error_type_expr.name.?);
    // body statement kinds
    const stmts = decl.data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 5), stmts.len);
    try std.testing.expect(stmts[0].data == .onfail_stmt);
    try std.testing.expect(stmts[1].data == .var_decl and stmts[1].data.var_decl.value.?.data == .binary_op);
    try std.testing.expect(stmts[2].data == .var_decl and stmts[2].data.var_decl.value.?.data == .catch_expr);
    try std.testing.expect(stmts[3].data == .if_expr);
    try std.testing.expect(stmts[4].data == .return_stmt);
    // the onfail flag was restored: the raise inside the (separate) if-block is allowed
    const then_block = stmts[3].data.if_expr.then_branch;
    try std.testing.expect(then_block.data.block.stmts[0].data == .raise_stmt);
}
