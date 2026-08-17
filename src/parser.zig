const std = @import("std");
const sxlex = @import("sxlex");
const Token = sxlex.token.Token;
const Tag = sxlex.token.Tag;
const lexer = sxlex.lexer;
const token_list = sxlex.token_list;
const TokenList = token_list.TokenList;
const Index = token_list.Index;
const ast = @import("ast.zig");
const contracts = @import("contracts.zig");
const Node = ast.Node;
const Type = @import("types.zig").Type;
const errors = @import("errors.zig");
const print = @import("print.zig");
const unescape = @import("unescape.zig");

const named_aggregate_dot_msg = "a named aggregate literal places '{' directly after its type";

/// A statement header's claim on the brace group written at `depth`.
const Header = struct {
    kind: Kind,
    depth: u32,

    const Kind = enum { if_condition, while_condition, for_header, match_subject, push_context };
};

pub const Parser = struct {
    tokens: TokenList,
    tok: Index,
    allocator: std.mem.Allocator,
    err_msg: ?[]const u8,
    err_offset: ?u32 = null,
    err_end: ?u32 = null,
    diagnostics: ?*errors.DiagnosticList = null,
    /// Type param names from enclosing generic struct (set while parsing methods)
    struct_type_params: []const []const u8 = &.{},
    /// The statement header being parsed, with the `{` `(` `[` depth it was
    /// taken at: the header reserves exactly the group written at that depth,
    /// so `{` opens the statement body (`if x != .{1, 2} { … }`,
    /// `while cond { … }`, `match F(args) { case … }`, `push expr { … }`) and
    /// a SPACED `(` before `{` or `=>` ends a `for` header. A group opened
    /// after the header began holds its contents one deeper, where the
    /// reservation does not apply and `expr { … }` juxtaposes as usual.
    /// Saved and restored around each header expression, so a header nested in
    /// another gets its own.
    header: ?Header = null,
    /// True inside a juxtaposition's own brace group, where `,` ends an item
    /// the way `;` does. Cleared by every nested block.
    comma_separates_items: bool = false,
    /// When true (set while parsing an `onfail` body), a `raise` statement is
    /// rejected — an error during cleanup has no propagation target. The
    /// error-flow pass extends this to the full {try, return, break, continue} set.
    in_onfail_body: bool = false,
    /// When true (set while parsing a `defer` body), a `raise` statement is
    /// rejected — same reason as `onfail`: cleanup runs while the function is
    /// already exiting, so there is nothing to propagate to. The error-flow pass
    /// extends this to the full {try, return, break, continue} set.
    in_defer_body: bool = false,
    /// Set for the statement just parsed: true when it is an EXPRESSION
    /// statement, whose value the enclosing block can hand on (`endExprStatement`);
    /// false for a declaration (`endDeclaration`). `parseBlock` reads it after the
    /// last statement to set `Block.produces_value`. Reset at the top of
    /// `parseStmt` so the forms that end through neither (return, break, `push`, …)
    /// leave it false. A `;` does not enter into it: the terminator separates
    /// statements and carries no value semantics.
    ///
    /// The mark belongs to ONE statement list at a time: every recursive
    /// statement container (`parseBlock`, `parseMatchBody`, the arrow body of
    /// `parseForExpr`) saves and restores it, so a nested body classifies its own
    /// statements and never the statement that encloses it. Without that, a
    /// nested tail expression would reclassify an enclosing declaration — the
    /// forms that end through `expectStatementEnd` rather than `endDeclaration`
    /// (`::` bindings, assignments, `return`, `defer`) have nothing else to
    /// clear it.
    last_stmt_produces_value: bool = false,
    /// True while parsing the body of a MODULE-SCOPE expansion form — an
    /// `inline if` branch or an `inline for` iteration group. Their statements
    /// are top-level declarations after comptime flattening, so `private` and
    /// the declaration-only forms (`impl`) remain legal on them.
    /// Function/lambda bodies clear it — a nested body's declarations are
    /// locals, never module scope.
    in_module_expansion: bool = false,
    /// True while parsing a parameter's default expression — the one place
    /// `@caller` may be written.
    in_param_default: bool = false,

    /// Lexes `source` and owns the resulting list from `allocator`.
    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) error{OutOfMemory}!Parser {
        return initFromTokens(allocator, try lexer.lex(allocator, source));
    }

    /// Borrows an already-built list.
    pub fn initFromTokens(allocator: std.mem.Allocator, tokens: TokenList) Parser {
        return .{
            .tokens = tokens,
            .tok = tokens.first(),
            .allocator = allocator,
            .err_msg = null,
            .err_offset = null,
        };
    }

    fn createNode(self: *Parser, start: u32, data: Node.Data) !*Node {
        const node = try self.allocator.create(Node);
        node.* = .{ .span = .{ .start = start, .end = self.tokens.end(self.tokens.prev(self.tok)) }, .data = data };
        return node;
    }

    pub fn atEof(self: *const Parser) bool {
        return self.tokens.tag(self.tok) == .eof;
    }

    pub fn parse(self: *Parser) anyerror!*Node {
        var decls = std.ArrayList(*Node).empty;
        while (self.tokens.tag(self.tok) != .eof) {
            const decl = try self.parseTopLevel();
            try decls.append(self.allocator, decl);
        }
        const node = try self.createNode(0, .{ .root = .{ .decls = try decls.toOwnedSlice(self.allocator) } });
        return node;
    }

    fn parseTopLevel(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);

        // `private NAME …` — a module-scope declaration restricted to its
        // declaring source file. Only identifier-headed declarations take the
        // modifier; every directive/block form is rejected with a placement
        // diagnostic.
        if (self.tokens.tag(self.tok) == .kw_private) {
            self.advance();
            switch (self.tokens.tag(self.tok)) {
                .hash_import => return self.fail("'private' is not allowed on a flat '#import'; only a named import ('name :: #import \"…\"') can be private"),
                .kw_asm => return self.fail("'private' is not allowed on global 'asm'"),
                .hash_run => return self.fail("'private' is not allowed on a standalone '#run'"),
                .hash_framework => return self.fail("'private' is not allowed on '#framework'"),
                .kw_impl => return self.fail("'private' is not allowed on an 'impl' block"),
                .at_identifier => if (std.mem.eql(u8, self.tokens.slice(self.tok), "@error"))
                    return self.fail("'private' is not allowed on '@error'"),
                .hash_context_extend => return self.fail("'private' is not allowed on '#context_extend'"),
                .kw_inline => return self.fail("'private' is not allowed on 'inline if'; mark the declarations inside its branches instead"),
                .kw_private => return self.fail("duplicate 'private'"),
                else => {},
            }
            if (!self.isIdentLike() and self.tokens.tag(self.tok) != .kw_Self) {
                return self.fail("expected a declaration name after 'private'");
            }
            const node = try self.parseTopLevelNamedDecl();
            node.visibility = .private;
            return node;
        }

        // Top-level flat import: #import "path"; or #import c { ... };
        if (self.tokens.tag(self.tok) == .hash_import) {
            self.advance();
            // Check for #import c { ... } (C import block)
            if (self.tokens.tag(self.tok) == .identifier and std.mem.eql(u8, self.tokens.slice(self.tok), "c") and self.peekNext() == .l_brace) {
                self.advance(); // consume 'c'
                return self.parseCImportBlock(start, null, false);
            }
            if (self.tokens.tag(self.tok) != .string_literal) {
                return self.fail("expected string path after '#import'");
            }
            const raw = self.tokens.slice(self.tok);
            const path = raw[1 .. raw.len - 1];
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .import_decl = .{ .path = path, .name = null } });
        }

        // Top-level (module-scope) global assembly: `asm { "tmpl", };`
        // (template only — no operands/volatile/clobbers). The in-function
        // `asm { … }` expression form is parsed in `parsePrimary` instead.
        if (self.tokens.tag(self.tok) == .kw_asm) {
            return self.parseAsmGlobal(start);
        }

        // Top-level #run directive
        if (self.tokens.tag(self.tok) == .hash_run) {
            self.advance();
            const expr = try self.parseExpr();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .comptime_expr = .{ .expr = expr } });
        }

        // Top-level #framework directive: link against an Apple framework.
        if (self.tokens.tag(self.tok) == .hash_framework) {
            self.advance();
            if (self.tokens.tag(self.tok) != .string_literal) {
                return self.fail("expected string after '#framework'");
            }
            const raw = self.tokens.slice(self.tok);
            const fw_name = raw[1 .. raw.len - 1];
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .framework_decl = .{ .name = fw_name } });
        }

        // impl Protocol for Type { methods }
        if (self.tokens.tag(self.tok) == .kw_impl) {
            return self.parseImplBlock(start);
        }

        // Top-level `inline if` / `inline for` — compile-time expansion forms.
        // Both bodies hold module-scope declarations, spliced into module scope
        // by lowering's `expandModuleDrivers`.
        if (self.tokens.tag(self.tok) == .kw_inline) {
            if (self.peekNext() == .kw_if) {
                self.advance(); // skip 'inline'
                const saved_module_expansion = self.in_module_expansion;
                self.in_module_expansion = true;
                defer self.in_module_expansion = saved_module_expansion;
                const expr = try self.parseIfExpr(.bit_or);
                expr.data.if_expr.is_comptime = true;
                return expr;
            }
            if (self.peekNext() == .kw_match) {
                self.advance(); // skip 'inline'
                const saved_module_expansion = self.in_module_expansion;
                self.in_module_expansion = true;
                defer self.in_module_expansion = saved_module_expansion;
                const expr = try self.parseMatchExpr();
                expr.data.match_expr.is_comptime = true;
                return expr;
            }
            if (self.peekNext() == .kw_for) {
                self.advance(); // skip 'inline'
                const saved_module_expansion = self.in_module_expansion;
                self.in_module_expansion = true;
                defer self.in_module_expansion = saved_module_expansion;
                const expr = try self.parseForExpr();
                expr.data.for_expr.is_inline = true;
                return expr;
            }
        }

        // Top-level `@error("msg");` — compile-time diagnostic.
        if (self.isErrorContractCall()) {
            return self.parseErrorDirective();
        }

        // Top-level `#context_extend name: Type = default;` — declares a field
        // of the program's assembled Context.
        if (self.tokens.tag(self.tok) == .hash_context_extend) return self.parseContextExtend(start);

        // All top-level declarations start with an identifier. An `@` name is
        // one too: the compiler-maintained contracts are ordinary stdlib
        // declarations, source-visible and reviewable. Which `@` names exist
        // and which module owns each is `contracts`' registry, checked after
        // parsing where the declaring file is known.
        if (!self.isIdentLike() and self.tokens.tag(self.tok) != .kw_Self and self.tokens.tag(self.tok) != .at_identifier) {
            return self.fail("expected identifier at top level");
        }
        return self.parseTopLevelNamedDecl();
    }

    /// The identifier-headed module-scope declaration tail (`NAME :: …`,
    /// `NAME : T [:|=] …`, `NAME := …`). Shared by the plain and
    /// `private`-prefixed top-level paths; the caller has already verified an
    /// identifier-like token is current.
    fn parseTopLevelNamedDecl(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        const name = self.tokens.slice(self.tok);
        const name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
        const name_is_raw = self.tokens.flagsOf(self.tok).is_raw;
        self.advance();

        // IDENT :: ...
        if (self.tokens.tag(self.tok) == .colon_colon) {
            self.advance();
            return self.parseConstBinding(name, name_span, start, name_is_raw);
        }

        // IDENT : type : value; (typed constant)
        // IDENT : type = value; (typed variable)
        if (self.tokens.tag(self.tok) == .colon) {
            self.advance();
            return self.parseTypedBinding(name, name_span, start, name_is_raw);
        }

        // IDENT := value; (variable)
        if (self.tokens.tag(self.tok) == .colon_equal) {
            self.advance();
            const value = try self.parseExpr();
            try self.endDeclaration(value);
            return try self.createNode(start, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = null, .value = value, .is_raw = name_is_raw } });
        }

        return self.fail("expected '::', ':=', or ':' after identifier");
    }

    fn parseConstBinding(self: *Parser, name: []const u8, name_span: ast.Span, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        // After `::`
        // Could be: #run expr, enum { ... }, (params) -> type { body }, or expr;

        // Namespaced import: name :: #import "path"; or name :: #import c { ... };
        if (self.tokens.tag(self.tok) == .hash_import) {
            self.advance();
            // Check for name :: #import c { ... }
            if (self.tokens.tag(self.tok) == .identifier and std.mem.eql(u8, self.tokens.slice(self.tok), "c") and self.peekNext() == .l_brace) {
                self.advance(); // consume 'c'
                return self.parseCImportBlock(start_pos, name, name_is_raw);
            }
            if (self.tokens.tag(self.tok) != .string_literal) {
                return self.fail("expected string path after '#import'");
            }
            const raw = self.tokens.slice(self.tok);
            const path = raw[1 .. raw.len - 1];
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start_pos, .{ .import_decl = .{ .path = path, .name = name, .is_raw = name_is_raw } });
        }

        // Named library: name :: #library "libname";
        if (self.tokens.tag(self.tok) == .hash_library) {
            self.advance();
            if (self.tokens.tag(self.tok) != .string_literal) {
                return self.fail("expected string after '#library'");
            }
            const raw = self.tokens.slice(self.tok);
            const lib_name = raw[1 .. raw.len - 1];
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start_pos, .{ .library_decl = .{ .lib_name = lib_name, .name = name, .is_raw = name_is_raw } });
        }

        // Compile-time evaluation: name :: #run expr;
        if (self.tokens.tag(self.tok) == .hash_run) {
            const run_start = self.tokens.start(self.tok);
            self.advance();
            const inner = try self.parseExpr();
            try self.expectStatementEnd();
            const ct = try self.createNode(run_start, .{ .comptime_expr = .{ .expr = inner } });
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = null, .value = ct, .name_span = name_span, .is_raw = name_is_raw } });
        }

        // Intrinsic declaration: name :: intrinsic;
        if (self.tokens.tag(self.tok) == .kw_intrinsic) {
            const bi_start = self.tokens.start(self.tok);
            self.advance();
            try self.expectStatementEnd();
            const bi = try self.createNode(bi_start, .{ .intrinsic_expr = {} });
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = null, .value = bi, .name_span = name_span, .is_raw = name_is_raw } });
        }

        // Enum declaration
        if (self.tokens.tag(self.tok) == .kw_enum) {
            return self.parseEnumDecl(name, start_pos, name_is_raw);
        }

        // Error-set declaration: name :: error { TagA, TagB }
        if (self.tokens.tag(self.tok) == .kw_error) {
            return self.parseErrorSetDecl(name, start_pos, name_is_raw);
        }

        // Struct declaration
        if (self.tokens.tag(self.tok) == .kw_struct) {
            return self.parseStructDecl(name, start_pos, name_is_raw);
        }

        // Protocol declaration
        if (self.tokens.tag(self.tok) == .kw_protocol) {
            return self.parseProtocolDecl(name, start_pos, name_is_raw);
        }

        // Open-set declaration heads. Both are `@` names with an argument list,
        // and both open a body, so they are declaration FORMS — neither a
        // stdlib-declared contract nor a compiler-formed type.
        if (self.tokens.tag(self.tok) == .at_identifier) {
            const at_name = self.tokens.slice(self.tok);
            if (std.mem.eql(u8, at_name, contracts.open_set_head)) {
                return self.parseOpenSetDecl(name, start_pos, name_is_raw);
            }
            if (std.mem.eql(u8, at_name, contracts.open_variant_head)) {
                return self.parseOpenVariantDecl(name, start_pos, name_is_raw);
            }
        }

        // Runtime-class binding: `Name :: @JniClass("path", extends = Super, main = true) extern { … }`
        if (self.tokens.tag(self.tok) == .at_identifier) {
            if (self.runtimeKindForAtName(self.tokens.slice(self.tok))) |kind| {
                return self.parseRuntimeClassDecl(name, start_pos, kind, name_is_raw);
            }
        }

        // C-style union declaration
        if (self.tokens.tag(self.tok) == .kw_union) {
            return self.parseUnionDecl(name, start_pos, name_is_raw);
        }

        // UFCS forms:
        //   name :: ufcs (params) -> ret { body }   — fn declared dot-callable
        //   name :: ufcs target;                    — dot-callable alias
        if (self.tokens.tag(self.tok) == .kw_ufcs) {
            self.advance();
            if (self.tokens.tag(self.tok) == .l_paren) {
                const node = try self.parseFnDecl(name, name_span, name_is_raw, start_pos);
                node.data.fn_decl.is_ufcs = true;
                return node;
            }
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected '(' (a ufcs function declaration) or a function name (a ufcs alias) after 'ufcs'");
            }
            const target = self.tokens.slice(self.tok);
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start_pos, .{ .ufcs_alias = .{ .name = name, .target = target, .is_raw = name_is_raw } });
        }

        // A compiler-owned function: `@NAME :: (params) [-> R];`. The sigil is
        // the whole marker, so the signature stands alone with no body — the
        // form a plain name spells with the `intrinsic` keyword. It routes
        // ahead of the function-definition heuristic, which reads a bodyless
        // `(types) -> R` as a function-type alias.
        if (name.len > 0 and name[0] == '@' and self.tokens.tag(self.tok) == .l_paren) {
            return self.parseAtFnDecl(name, name_span, start_pos, name_is_raw);
        }

        // Function declaration: (params) -> type { body } or () { body }
        if (self.tokens.tag(self.tok) == .l_paren) {
            // Look ahead: is this a function or an expression starting with `(`?
            // Heuristic: if after matching parens we see `{` or `->`, it's a function.
            if (self.isFunctionDef()) {
                return self.parseFnDecl(name, name_span, name_is_raw, start_pos);
            }
        }

        // Bare block shorthand: name :: { body } is equivalent to name :: () { body }
        if (self.tokens.tag(self.tok) == .l_brace) {
            const body = try self.parseBlock();
            return try self.createNode(start_pos, .{ .fn_decl = .{ .name = name, .params = &.{}, .return_type = null, .body = body, .name_span = name_span, .is_raw = name_is_raw } });
        }

        // A type-constructor head after `::` opens a type ALIAS
        // (`NT :: Tuple(a: i64);`, `CB :: Closure(i32) -> i32;`), so the RHS
        // parses with the type grammar; anything else is a constant expression.
        const value = if (self.atTypeConstructorHead())
            try self.parseTypeExpr()
        else
            try self.parseExpr();

        // name :: type_expr intrinsic; — intrinsic with type annotation. The
        // declaration is already whole without the tail, so the tail binds only
        // where the declaration has not already ended.
        if (!self.atStatementEnd() and self.tokens.tag(self.tok) == .kw_intrinsic) {
            const bi_start = self.tokens.start(self.tok);
            self.advance();
            try self.expectStatementEnd();
            const bi = try self.createNode(bi_start, .{ .intrinsic_expr = {} });
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = value, .value = bi, .name_span = name_span, .is_raw = name_is_raw } });
        }

        try self.expectStatementEnd();
        return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = null, .value = value, .name_span = name_span, .is_raw = name_is_raw } });
    }

    fn parseCImportBlock(self: *Parser, start: u32, name: ?[]const u8, name_is_raw: bool) anyerror!*Node {
        try self.expect(.l_brace);
        var includes = std.ArrayList([]const u8).empty;
        var sources = std.ArrayList([]const u8).empty;
        var defines = std.ArrayList([]const u8).empty;
        var flags = std.ArrayList([]const u8).empty;

        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            if (self.tokens.tag(self.tok) == .hash_include) {
                self.advance();
                if (self.tokens.tag(self.tok) != .string_literal) return self.fail("expected string after '#include'");
                const raw = self.tokens.slice(self.tok);
                try includes.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else if (self.tokens.tag(self.tok) == .hash_source) {
                self.advance();
                if (self.tokens.tag(self.tok) != .string_literal) return self.fail("expected string after '#source'");
                const raw = self.tokens.slice(self.tok);
                try sources.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else if (self.tokens.tag(self.tok) == .hash_define) {
                self.advance();
                if (self.tokens.tag(self.tok) != .string_literal) return self.fail("expected string after '#define'");
                const raw = self.tokens.slice(self.tok);
                try defines.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else if (self.tokens.tag(self.tok) == .hash_flags) {
                self.advance();
                if (self.tokens.tag(self.tok) != .string_literal) return self.fail("expected string after '#flags'");
                const raw = self.tokens.slice(self.tok);
                try flags.append(self.allocator, raw[1 .. raw.len - 1]);
                self.advance();
                try self.expect(.semicolon);
            } else {
                return self.fail("unexpected token inside '#import c { ... }'");
            }
        }
        try self.expect(.r_brace);
        try self.expectStatementEnd();

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

        // `name : type` is already a whole declaration, so ask whether it ended
        // before looking at what an initializer or a linkage tail would have
        // started. `:`, `=` and `extern` cannot open a statement, so a line
        // break in front of any of them continues this one.
        if (self.atStatementEnd()) {
            // name : type; (default-initialized variable)
            try self.expectStatementEnd();
            return try self.createNode(start_pos, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = type_node, .value = null, .is_raw = name_is_raw } });
        }

        if (self.tokens.tag(self.tok) == .colon) {
            // name : type : value; (typed constant)
            self.advance();
            const value = try self.parseExpr();
            try self.endDeclaration(value);
            return try self.createNode(start_pos, .{ .const_decl = .{ .name = name, .type_annotation = type_node, .value = value, .name_span = name_span, .is_raw = name_is_raw } });
        }

        if (self.tokens.tag(self.tok) == .equal) {
            // name : type = value; (typed variable)
            self.advance();
            const value = try self.parseExpr();
            try self.endDeclaration(value);
            return try self.createNode(start_pos, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = type_node, .value = value, .is_raw = name_is_raw } });
        }

        if (self.tokens.tag(self.tok) == .kw_extern) {
            // name : type extern [LIB] ["csym"];   (extern data global, resolved
            // at link time)
            self.advance();
            const tail = self.parseLinkageTail(true);
            try self.expectStatementEnd();
            return try self.createNode(start_pos, .{ .var_decl = .{
                .name = name,
                .name_span = name_span,
                .type_annotation = type_node,
                .value = null,
                .is_extern = true,
                .extern_lib = tail.lib,
                .extern_name = tail.name,
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
    /// A trailing `!` after the value type (`-> T !`, `-> Tuple(A, B) !`) is
    /// REJECTED; the error channel is only ever a slot in the parens.
    fn parseFnReturnType(self: *Parser) anyerror!*Node {
        const ty = try self.parseTypeExpr();

        // A trailing `!` after a VALUE return type is rejected.
        // (`-> !` already parsed to an error_type_expr above, so a
        // `!` after one would be a doubled channel — leave that to the normal
        // "unexpected token" path.)
        if (self.tokens.tag(self.tok) == .bang and ty.data != .error_type_expr) {
            return self.fail("a failable return is written `(T, !)` — or `(A, B, !)` for multiple values — not `T !`");
        }
        return ty;
    }

    fn parseTypeExpr(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        // A compiler-formed contract (`@Init`, `@BuildBlock`) is a CONSTRAINT: it
        // names a bound, never a type, and `parseCompilerFormedType` says so.
        // Every other `@` name in type position names a compiler-maintained
        // stdlib declaration (`@SourceSite`) and resolves like any other type.
        if (self.tokens.tag(self.tok) == .at_identifier) {
            const at_name = self.tokens.slice(self.tok);
            // `@Slice(T, Len)` is the type constructor; nullary `@Slice` is
            // the declared ABI view. Other formed names always take arguments.
            if (contracts.isTypeConstructor(at_name) and self.peekTag(1) == .l_paren) {
                return self.parseCompilerFormedType(start);
            }
            if (isCompilerFormedTypeName(at_name)) {
                return self.parseCompilerFormedType(start);
            }
            const at_idx = self.tok;
            self.advance();
            // A type-argument list is what a compiler-formed type takes; a
            // declared contract is a plain type name.
            if (self.tokens.tag(self.tok) == .l_paren) {
                return self.failAt(self.tokens.token(at_idx).loc, try self.unknownCompilerFormedTypeMsg(at_name));
            }
            return try self.createNode(start, .{ .type_expr = .{ .name = at_name } });
        }

        // Error channel type: bare `!` (inferred set) or `!Named` (named set).
        // Legal only as the trailing element of a multi-return result list
        // (enforced by the parenthesized-list loop below) or as a bare
        // failable return type. Sema restricts it to return positions.
        if (self.tokens.tag(self.tok) == .bang) {
            self.advance(); // skip '!'
            var set_name: ?[]const u8 = null;
            if (self.tokens.tag(self.tok) == .identifier) {
                set_name = self.tokens.slice(self.tok);
                self.advance();
            }
            return try self.createNode(start, .{ .error_type_expr = .{ .name = set_name } });
        }

        // Optional type: ?T
        if (self.tokens.tag(self.tok) == .question) {
            self.advance(); // skip '?'
            const inner_type = try self.parseTypeExpr();
            return try self.createNode(start, .{ .optional_type_expr = .{ .inner_type = inner_type } });
        }

        // Pointer type: *T
        if (self.tokens.tag(self.tok) == .star) {
            self.advance(); // skip '*'
            const pointee_type = try self.parseTypeExpr();
            return try self.createNode(start, .{ .pointer_type_expr = .{ .pointee_type = pointee_type } });
        }

        // Array type: [N]T, Slice type: []T, Many-pointer type: [*]T, Sentinel slice: [:0]T
        if (self.tokens.tag(self.tok) == .l_bracket) {
            self.advance(); // skip '['
            if (self.tokens.tag(self.tok) == .colon) {
                // Sentinel-terminated slice: [:0]T
                self.advance(); // skip ':'
                if (self.tokens.tag(self.tok) != .int_literal) {
                    return self.fail("expected sentinel value after ':'");
                }
                const sentinel_str = self.tokens.slice(self.tok);
                self.advance(); // skip sentinel value
                try self.expect(.r_bracket); // expect ']'
                const elem_type = try self.parseTypeExpr();
                // Build name like "[:0]u8" for type resolution
                const elem_name = if (elem_type.data == .type_expr) elem_type.data.type_expr.name else "?";
                const name = try std.fmt.allocPrint(self.allocator, "[:{s}]{s}", .{ sentinel_str, elem_name });
                return try self.createNode(start, .{ .type_expr = .{ .name = name } });
            }
            if (self.tokens.tag(self.tok) == .r_bracket) {
                // Slice type: []T
                self.advance(); // skip ']'
                const elem_type = try self.parseTypeExpr();
                return try self.createNode(start, .{ .slice_type_expr = .{ .element_type = elem_type } });
            }
            if (self.tokens.tag(self.tok) == .star) {
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
        // the i-th element type of the active pack binding.
        if (self.tokens.tag(self.tok) == .dollar) {
            self.advance();
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected type parameter name after '$'");
            }
            const name = self.tokens.slice(self.tok);
            self.advance();
            // Pack-index access: $<pack_name>[<int_literal>]
            if (self.tokens.tag(self.tok) == .l_bracket) {
                self.advance(); // skip '['
                if (self.tokens.tag(self.tok) != .int_literal) {
                    return self.fail("expected integer literal in pack index");
                }
                const idx_text = self.tokens.slice(self.tok);
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
            const pc = try self.parseBoundList();
            return try self.createNode(start, .{ .type_expr = .{ .name = name, .is_generic = true, .protocol_constraints = pc } });
        }
        // Function type: (ParamTypes) -> ReturnType
        // Tuple type: (T1, T2) or (T1) — no '->' after ')'
        // Named params (documentation only): (name: Type, ...) -> ReturnType
        if (self.tokens.tag(self.tok) == .l_paren) {
            // A bare `..` tail belongs to a function TYPE. Without a `->` these
            // parens are a grouping, the void type, or a result list, where a
            // `..` is the pack spread — so the tail is recognized only here.
            const is_fn_type = self.tagAfterParenGroup() == .arrow;
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
            var is_c_variadic = false;
            // Span of the bare `..`, for the refusals that name it.
            var tail_span: ast.Span = .{ .start = 0, .end = 0 };
            while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                if (param_types.items.len > 0) {
                    try self.expect(.comma);
                    if (self.tokens.tag(self.tok) == .r_paren) {
                        had_trailing_comma = true;
                        break; // trailing comma ok
                    }
                }
                if (saw_error_type) {
                    return self.fail("error type '!' must be the last element of a result list");
                }
                // The bare `..` C-variadic tail — one token of lookahead
                // separates it from every pack spread, which always carries an
                // operand. It is the last entry, so an ordinary trailing comma
                // may follow it and nothing else may.
                if (self.tokens.tag(self.tok) == .dot_dot and is_fn_type and
                    (self.peekTag(1) == .r_paren or self.peekTag(1) == .comma))
                {
                    const dots = self.tokens.token(self.tok).loc;
                    is_c_variadic = true;
                    tail_span = .{ .start = dots.start, .end = dots.end };
                    self.advance();
                    if (self.tokens.tag(self.tok) == .comma) self.advance();
                    if (self.tokens.tag(self.tok) != .r_paren) {
                        return self.failAt(tail_span, "a C-variadic '..' tail must be the last parameter entry");
                    }
                    break;
                }
                // Pack expansion in a tuple/function type: `(..F(Ts))` /
                // `(..F(Ts.Arg))` / `(..Ts)`. Reuses `spread_expr`; its operand
                // is the per-element type expression (e.g. `F(Ts)`), carrying any
                // projection in `Ts.Arg` form.
                if (self.tokens.tag(self.tok) == .dot_dot) {
                    const spread_start = self.tokens.start(self.tok);
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
                    const pname = self.tokens.slice(self.tok);
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
                if (self.tokens.tag(self.tok) == .equal) {
                    self.advance(); // skip '='
                    elem_default = try self.parseExpr();
                    any_default = true;
                }
                try param_defaults.append(self.allocator, elem_default);
            }
            try self.expect(.r_paren);
            if (self.tokens.tag(self.tok) == .arrow) {
                // '->' present: function type. A failable return is the canonical
                // parenthesized list `(i64) -> (i64, !E)` (parseFnReturnType
                // rejects the bare `-> i64 !E` spelling).
                self.advance(); // skip '->'
                const return_type = try self.parseFnReturnType();
                const abi = try self.parseOptionalAbi();
                // A type has no linkage slot, so `abi(.c)` is the only spelling
                // that gives the tail its C signature.
                if (is_c_variadic) {
                    if (abi == .naked) {
                        return self.failAt(tail_span, "a C-variadic '..' tail cannot use explicit ABI '.naked'; use 'abi(.c)'");
                    }
                    if (abi != .c) {
                        return self.failAt(tail_span, "a C-variadic '..' tail requires 'abi(.c)'");
                    }
                }
                return try self.createNode(start, .{ .function_type_expr = .{
                    .param_types = try param_types.toOwnedSlice(self.allocator),
                    .param_names = if (has_names) try param_names.toOwnedSlice(self.allocator) else null,
                    .return_type = return_type,
                    .abi = abi,
                    .is_c_variadic = is_c_variadic,
                } });
            }
            // Empty parens `()` with no `->` is the void/unit type:
            // `a :: () -> () { }` is equivalent to `-> void`. (`() -> R` is the
            // zero-param function type, handled by the arrow branch above.)
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

        if (self.tokens.tag(self.tok).isTypeKeyword() or self.isIdentLike()) {
            // A backtick raw identifier (`` `i2 ``) in type position is the
            // LITERAL name `i2` used as a type reference — never the builtin /
            // reserved keyword. The raw flag rides the type ATOM through the
            // SAME qualified-path / `Closure` / parameterized continuations as a
            // bare name (so `` `i2(i64) ``, `` `i2.Inner ``, `` *`i2 `` all
            // parse); it is threaded onto the final `type_expr` /
            // `parameterized_type_expr` so resolution skips the builtin
            // classifier and looks up a `` `i2 ``-declared type.
            const atom_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            var name = self.tokens.slice(self.tok);
            self.advance();

            // Qualified name: ns.Type or ns.Type(args)
            while (self.tokens.tag(self.tok) == .dot) {
                const dot_saved = self.tok;
                self.advance();
                if (self.isIdentLike() or self.tokens.tag(self.tok).isTypeKeyword()) {
                    name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, self.tokens.slice(self.tok) });
                    self.advance();
                } else {
                    // Not a qualified name continuation — restore the dot
                    self.tok = dot_saved;
                    break;
                }
            }

            // Only a `Tuple` / `Closure` IMMEDIATELY followed by `(` builds the
            // type; a bare one is an ordinary name.
            if (std.mem.eql(u8, name, "Tuple") and self.tokens.tag(self.tok) == .l_paren) {
                return self.parseTupleTypeBody(start);
            }

            if (std.mem.eql(u8, name, "Closure") and self.tokens.tag(self.tok) == .l_paren) {
                return self.parseClosureTypeBody(start);
            }

            // Parameterized head: a generic struct, a parameterized protocol,
            // or a type-returning function.
            if (self.tokens.tag(self.tok) == .l_paren) {
                return try self.createNode(start, .{ .parameterized_type_expr = .{
                    .name = name,
                    .args = try self.parseTypeArgList(),
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
        if (self.tokens.tag(self.tok) == .kw_struct) {
            return try self.parseStructDecl("__anon", start, false);
        }
        // Inline C-style union in type position: union { ... }
        if (self.tokens.tag(self.tok) == .kw_union) {
            return try self.parseUnionDecl("__anon", start, false);
        }
        // Inline enum type in type position: enum { ... }
        if (self.tokens.tag(self.tok) == .kw_enum) {
            return try self.parseEnumDecl("__anon", start, false);
        }
        return self.fail("expected type name");
    }

    /// The bounds trailing a type-variable binder: `('/' BoundExpr)*`.
    fn parseBoundList(self: *Parser) anyerror![]const *Node {
        var bounds = std.ArrayList(*Node).empty;
        while (self.tokens.tag(self.tok) == .slash) {
            self.advance(); // skip '/'
            try bounds.append(self.allocator, try self.parseBoundExpr());
        }
        return try bounds.toOwnedSlice(self.allocator);
    }

    /// One generic bound (specs: Generic bounds):
    /// `ProtocolHead [ '(' TypeExpr (',' TypeExpr)* ')' ]`, where the head is a
    /// bare name, an `@` name, or a name QUALIFIED by the module that owns it.
    /// The head is an ordinary name reference, NOT the closed compiler-formed
    /// set that `parseCompilerFormedType` guards:
    /// `lower/bound.zig` resolves it, and a head naming nothing is an
    /// unknown-name error there. Type arguments are full type expressions, so a
    /// bound argument may introduce its own binder with its own bounds
    /// (`@Init($V/P)`).
    fn parseBoundExpr(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        if (self.tokens.tag(self.tok) != .identifier and self.tokens.tag(self.tok) != .at_identifier) {
            return self.fail("expected protocol name after '/'");
        }
        var head = self.tokens.slice(self.tok);
        self.advance();
        // A head may be QUALIFIED (`$V/pkg.View`): a module reached by name owns
        // the protocol or set the bound asks about, exactly as a type
        // annotation names it. The path is carried whole; `lower/bound.zig`
        // resolves it.
        while (self.tokens.tag(self.tok) == .dot) {
            self.advance();
            if (self.tokens.tag(self.tok) != .identifier) return self.fail("expected a name after '.' in a bound head");
            const seg = self.tokens.slice(self.tok);
            self.advance();
            head = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ head, seg }) catch head;
        }
        if (self.tokens.tag(self.tok) != .l_paren) {
            return try self.createNode(start, .{ .type_expr = .{ .name = head } });
        }
        const l_paren_loc = self.tokens.token(self.tok).loc;
        self.advance(); // skip '('
        var args = std.ArrayList(*Node).empty;
        while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
            if (args.items.len > 0) {
                try self.expect(.comma);
                if (self.tokens.tag(self.tok) == .r_paren) break;
            }
            // A bound argument may itself bind: `@Init($V/P)`.
            try args.append(self.allocator, try self.parseTypeExpr());
        }
        if (args.items.len == 0) {
            return self.failAt(l_paren_loc, try std.fmt.allocPrint(
                self.allocator,
                "the bound '{s}' has an empty type-argument list — write '{s}' for the bare head, or give it arguments",
                .{ head, head },
            ));
        }
        try self.expect(.r_paren);
        return try self.createNode(start, .{ .parameterized_type_expr = .{
            .name = head,
            .args = try args.toOwnedSlice(self.allocator),
        } });
    }

    fn unknownCompilerFormedTypeMsg(self: *Parser, name: []const u8) ![]const u8 {
        const list = try contracts.compilerFormedList(self.allocator);
        return std.fmt.allocPrint(
            self.allocator,
            "unknown compiler-formed type '{s}' — the only ones are {s}",
            .{ name, list },
        );
    }

    /// The compiler-provided default-parameter value (spec: `@caller`).
    pub const caller_site_name = "@caller";

    /// True for the `@` names the compiler FORMS — `contracts` is the single
    /// registry for both `@` classes, so the formed set and the declared set
    /// cannot drift apart.
    fn isCompilerFormedTypeName(name: []const u8) bool {
        return contracts.isCompilerFormed(name);
    }

    /// The parenthesized argument list a parameterized type head takes:
    /// `@Vector(N, T)`, `List(T)`, `Combined($R, ..sources.T)`. `current` must
    /// be at the opening `(`.
    fn parseTypeArgList(self: *Parser) anyerror![]const *Node {
        self.advance(); // skip '('
        var args = std.ArrayList(*Node).empty;
        while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
            if (args.items.len > 0) {
                try self.expect(.comma);
            }
            // Pack-spread type arg: `Combined($R, ..sources.T)`.
            if (self.tokens.tag(self.tok) == .dot_dot) {
                const sp_start = self.tokens.start(self.tok);
                self.advance(); // skip '..'
                const operand = try self.parseTypeExpr();
                try args.append(self.allocator, try self.createNode(sp_start, .{ .spread_expr = .{ .operand = operand } }));
                continue;
            }
            // An arg is either a TYPE (`f32`, `*T`, `[]u8`, `List(T)`) or a
            // compile-time integer expression in a value position — a
            // `@Vector` lane count or a generic `$N: u32` arg: `@Vector(N, f32)`,
            // `@Vector(M + 1, f32)`. Parse the primary as a literal / type,
            // then continue as a const-int expression iff an arithmetic
            // operator follows. A complete type arg is always followed by
            // `,` / `)`, so `parseBinaryRhs` is a no-op for plain types and
            // the continuation is unambiguous; `Prec.additive` bounds it to
            // `+ - * / %`. The shared evaluator folds the expression; a
            // non-const value position is diagnosed during lowering.
            var arg: *Node = undefined;
            if (self.tokens.tag(self.tok) == .int_literal) {
                const arg_start = self.tokens.start(self.tok);
                const text = self.tokens.slice(self.tok);
                // Parse the full u64 range and store the bit pattern,
                // matching the main int-literal path.
                const value: i64 = @bitCast(self.parseIntLiteralText(text) orelse {
                    return self.fail("invalid integer literal in type argument");
                });
                self.advance();
                arg = try self.createNode(arg_start, .{ .int_literal = .{ .value = value } });
            } else if (self.tokens.tag(self.tok) == .char_literal) {
                // A char literal in a value position (`Buf('A')`) is a
                // compile-time integer code point — decode it the same
                // way the primary-expression path does and emit a
                // `char_literal` node (keeps the `c…` value mangle in
                // generics.zig distinct from the integer instantiation).
                const arg_start = self.tokens.start(self.tok);
                const raw = self.tokens.slice(self.tok);
                const inner = raw[1 .. raw.len - 1];
                const value = unescape.decodeCharLiteral(inner) catch |err| {
                    return self.fail(unescape.charLiteralReason(err));
                };
                self.advance();
                arg = try self.createNode(arg_start, .{ .char_literal = .{ .value = value, .raw = inner } });
            } else {
                arg = try self.parseTypeExpr();
            }
            arg = try self.parseBinaryRhs(arg, Prec.additive, .bit_or);
            try args.append(self.allocator, arg);
        }
        try self.expect(.r_paren);
        return try args.toOwnedSlice(self.allocator);
    }

    fn parseCompilerFormedType(self: *Parser, start: u32) anyerror!*Node {
        const name_idx = self.tok;
        const name = self.tokens.slice(name_idx);
        self.advance();
        const contract = contracts.find(name);
        const spelling = if (contracts.isTypeConstructor(name))
            if (std.mem.eql(u8, name, contracts.slice_head)) "@Slice(T, Len)" else if (contract) |c| c.spelling else name
        else if (contract != null and contract.?.kind == .compiler_formed)
            contract.?.spelling
        else
            return self.failAt(self.tokens.token(name_idx).loc, try self.unknownCompilerFormedTypeMsg(name));
        // A bound-only contract names a constraint: its implementors are minted
        // per formation site, so no type position can name one.
        if (contract.?.bound_only) {
            return self.failAt(self.tokens.token(name_idx).loc, try std.fmt.allocPrint(
                self.allocator,
                "'{s}' is a generic bound, not a type — write the parameter as '{s}'",
                .{ spelling, contract.?.bound_spelling },
            ));
        }
        if (self.tokens.tag(self.tok) != .l_paren) {
            return self.failAt(self.tokens.token(name_idx).loc, try std.fmt.allocPrint(
                self.allocator,
                "'{s}' needs its type argument: write '{s}'",
                .{ name, spelling },
            ));
        }
        return try self.createNode(start, .{ .parameterized_type_expr = .{
            .name = name,
            .args = try self.parseTypeArgList(),
        } });
    }

    fn parseEnumDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'enum'

        // Check for 'flags' modifier: enum flags { ... }
        var is_flags = false;
        if (self.tokens.tag(self.tok) == .identifier and std.mem.eql(u8, self.tokens.slice(self.tok), "flags")) {
            is_flags = true;
            self.advance();
        }

        // Check for optional backing type: enum u8 { ... } or enum flags u32 { ... }
        var backing_type: ?*Node = null;
        if (self.tokens.tag(self.tok) != .l_brace) {
            backing_type = try self.parseTypeExpr();
        }

        try self.expect(.l_brace);
        var variant_names = std.ArrayList([]const u8).empty;
        var variant_name_starts = std.ArrayList(u32).empty;
        var variant_types = std.ArrayList(?*Node).empty;
        var variant_values = std.ArrayList(?*Node).empty;
        var has_any_type = false;
        var has_any_value = false;
        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            if (!self.isMemberDeclName()) {
                return self.failMemberDeclName("expected variant name");
            }
            try variant_names.append(self.allocator, self.tokens.slice(self.tok));
            try variant_name_starts.append(self.allocator, self.tokens.start(self.tok));
            self.advance();
            if (self.tokens.tag(self.tok) == .colon_colon) {
                // Explicit value: name :: expr;  or  name :: expr: type;
                self.advance();
                const val_expr = try self.parseExpr();
                try variant_values.append(self.allocator, val_expr);
                has_any_value = true;
                // Check for payload type after value: name :: 0x300: KeyData
                if (self.tokens.tag(self.tok) == .colon) {
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
            } else if (self.tokens.tag(self.tok) == .colon) {
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
            if (self.tokens.tag(self.tok) == .semicolon) {
                self.advance();
            }
        }
        try self.expect(.r_brace);
        // Always produce enum_decl; variant_types distinguishes payload-less from tagged
        return try self.createNode(start_pos, .{ .enum_decl = .{
            .name = name,
            .variant_names = try variant_names.toOwnedSlice(self.allocator),
            .variant_name_starts = try variant_name_starts.toOwnedSlice(self.allocator),
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
        var tag_name_starts = std.ArrayList(u32).empty;
        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            if (tag_names.items.len > 0) {
                try self.expect(.comma);
                if (self.tokens.tag(self.tok) == .r_brace) break; // trailing comma ok
            }
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected error tag name");
            }
            try tag_names.append(self.allocator, self.tokens.slice(self.tok));
            try tag_name_starts.append(self.allocator, self.tokens.start(self.tok));
            self.advance();
        }
        try self.expect(.r_brace);
        // Accept an optional trailing `;` — error-set decls read like value
        // bindings and are commonly written `Foo :: error { ... };`.
        if (self.tokens.tag(self.tok) == .semicolon) self.advance();
        return try self.createNode(start_pos, .{ .error_set_decl = .{
            .name = name,
            .tag_names = try tag_names.toOwnedSlice(self.allocator),
            .tag_name_starts = try tag_name_starts.toOwnedSlice(self.allocator),
            .is_raw = name_is_raw,
        } });
    }

    fn parseUnionDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'union'
        try self.expect(.l_brace);
        var field_names = std.ArrayList([]const u8).empty;
        var field_name_starts = std.ArrayList(u32).empty;
        var field_types = std.ArrayList(*Node).empty;
        var anon_idx: u32 = 0;
        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            // Anonymous struct field: struct { x, y: f32; };
            if (self.tokens.tag(self.tok) == .kw_struct) {
                const anon_field = try std.fmt.allocPrint(self.allocator, "__anon_{d}", .{anon_idx});
                anon_idx += 1;
                const anon_struct_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, anon_field });
                const struct_node = try self.parseStructDecl(anon_struct_name, self.tokens.start(self.tok), false);
                try field_names.append(self.allocator, anon_field);
                try field_name_starts.append(self.allocator, ast.no_source_start);
                try field_types.append(self.allocator, struct_node);
                if (self.tokens.tag(self.tok) == .semicolon) {
                    self.advance();
                }
                continue;
            }
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected field name or 'struct'");
            }
            try field_names.append(self.allocator, self.tokens.slice(self.tok));
            try field_name_starts.append(self.allocator, self.tokens.start(self.tok));
            self.advance();
            if (self.tokens.tag(self.tok) != .colon) {
                return self.fail("union fields must have a type");
            }
            self.advance();
            const ftype = try self.parseTypeExpr();
            try field_types.append(self.allocator, ftype);
            if (self.tokens.tag(self.tok) == .semicolon) {
                self.advance();
            }
        }
        try self.expect(.r_brace);
        return try self.createNode(start_pos, .{ .union_decl = .{
            .name = name,
            .field_names = try field_names.toOwnedSlice(self.allocator),
            .field_name_starts = try field_name_starts.toOwnedSlice(self.allocator),
            .field_types = try field_types.toOwnedSlice(self.allocator),
            .is_raw = name_is_raw,
        } });
    }

    fn parseStructDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'struct'
        return self.parseStructTail(name, start_pos, name_is_raw, null, null);
    }

    /// Everything after the declaration's head word. `open_variant_of` names the
    /// set a `@OpenVariant(P)` head bound this declaration to: the body grammar is
    /// the struct grammar, because a variant IS a struct.
    fn parseStructTail(
        self: *Parser,
        name: []const u8,
        start_pos: u32,
        name_is_raw: bool,
        open_variant_of: ?[]const u8,
        open_variant_span: ?ast.Span,
    ) anyerror!*Node {

        // Optional welded-binding annotation: `struct abi(.zig) extern <lib> { … }`.
        // `abi(...)` (the ABI/layout selector) sits before the `extern` linkage
        // keyword, mirroring the fn-decl slot order; the library handle follows.
        // Parse-only — no layout/registry semantics.
        const struct_abi = try self.parseOptionalAbi();
        const struct_extern = self.parseOptionalExternExport();
        var struct_extern_lib: ?[]const u8 = null;
        if (struct_extern != .none) {
            struct_extern_lib = self.parseLinkageTail(false).lib;
        }

        // Optional type params: struct($N: u32, $T: Type) { ... }
        var type_params = std.ArrayList(ast.StructTypeParam).empty;
        if (self.tokens.tag(self.tok) == .l_paren) {
            self.advance(); // skip '('
            while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                if (type_params.items.len > 0) {
                    try self.expect(.comma);
                    if (self.tokens.tag(self.tok) == .r_paren) break;
                }
                // Optional leading `..` — a pack type-param `..$Ts: []Type`
                // (must be the last param; binds the remaining type args).
                var is_variadic = false;
                if (self.tokens.tag(self.tok) == .dot_dot) {
                    is_variadic = true;
                    self.advance();
                }
                // Expect $name : constraint
                try self.expect(.dollar);
                if (self.tokens.tag(self.tok) != .identifier) {
                    return self.fail("expected type parameter name after '$'");
                }
                const param_name = self.tokens.slice(self.tok);
                self.advance();
                try self.expect(.colon);
                const constraint = try self.parseTypeExpr();
                // Bounds on the explicit form: `$T: Type/Eq/Hashable`.
                const pc: []const *Node = if (constraint.data == .type_expr and std.mem.eql(u8, constraint.data.type_expr.name, "Type"))
                    try self.parseBoundList()
                else
                    &.{};
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
        var field_name_starts = std.ArrayList(u32).empty;
        var field_types = std.ArrayList(*Node).empty;
        var field_defaults = std.ArrayList(?*Node).empty;
        var using_entries = std.ArrayList(ast.UsingEntry).empty;
        var methods = std.ArrayList(*Node).empty;
        var constants = std.ArrayList(*Node).empty;

        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            // Check for #using directive
            if (self.tokens.tag(self.tok) == .hash_using) {
                self.advance(); // skip #using
                if (self.tokens.tag(self.tok) != .identifier) {
                    return self.fail("expected type name after '#using'");
                }
                const used_type = self.tokens.slice(self.tok);
                self.advance();
                try using_entries.append(self.allocator, .{
                    .insert_index = @intCast(field_names.items.len),
                    .type_name = used_type,
                });
                if (self.tokens.tag(self.tok) == .semicolon) self.advance();
                continue;
            }

            // Method declaration: name :: (params) -> type { body }
            if (self.isMemberDeclName() and self.peekNext() == .colon_colon) {
                const method_start = self.tokens.start(self.tok);
                const method_name = self.tokens.slice(self.tok);
                const method_name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
                const method_is_raw = self.tokens.flagsOf(self.tok).is_raw;
                self.advance(); // skip name
                self.advance(); // skip ::
                if (self.tokens.tag(self.tok) == .l_paren and self.isFunctionDef()) {
                    try methods.append(self.allocator, try self.parseFnDecl(method_name, method_name_span, method_is_raw, method_start));
                } else {
                    // Non-function constant: name :: value;
                    const value = try self.parseExpr();
                    if (self.tokens.tag(self.tok) == .semicolon) self.advance();
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
            var group_starts = std.ArrayList(u32).empty;

            if (!self.isMemberDeclName()) {
                return self.failMemberDeclName("expected field name in struct");
            }
            const field_start = self.tokens.start(self.tok);
            // Captured for the single-name typed-const path (`name :Type: value`)
            // below: a struct-body const binds a name like any other decl, so
            // its name_span + raw flag must travel to the `const_decl` node
            // (finding 1 — they were being dropped to a 1:1 caret / false
            // reserved-name reject).
            const field_name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
            const field_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            try group_names.append(self.allocator, self.tokens.slice(self.tok));
            try group_starts.append(self.allocator, self.tokens.start(self.tok));
            self.advance();

            while (self.tokens.tag(self.tok) == .comma) {
                self.advance(); // skip ','
                if (!self.isMemberDeclName()) {
                    return self.failMemberDeclName("expected field name after ','");
                }
                try group_names.append(self.allocator, self.tokens.slice(self.tok));
                try group_starts.append(self.allocator, self.tokens.start(self.tok));
                self.advance();
            }

            try self.expect(.colon);
            const field_type = try self.parseTypeExpr();

            // Typed constant: name :Type: value; (second colon after type)
            if (self.tokens.tag(self.tok) == .colon and group_names.items.len == 1) {
                self.advance(); // skip second ':'
                const value = try self.parseExpr();
                if (self.tokens.tag(self.tok) == .semicolon) self.advance();
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
            if (self.tokens.tag(self.tok) == .equal) {
                self.advance();
                default_val = try self.parseExpr();
            }

            // All names in the group share the same type and default
            for (group_names.items, group_starts.items) |fname, fstart| {
                // `_` is an ignore identifier — auto-rename to unique internal name
                const actual_name = if (std.mem.eql(u8, fname, "_"))
                    try std.fmt.allocPrint(self.allocator, "_{d}", .{field_names.items.len})
                else
                    fname;
                try field_names.append(self.allocator, actual_name);
                try field_name_starts.append(self.allocator, fstart);
                try field_types.append(self.allocator, field_type);
                try field_defaults.append(self.allocator, default_val);
            }

            if (self.tokens.tag(self.tok) == .semicolon) {
                self.advance();
            }
        }
        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .struct_decl = .{
            .name = name,
            .field_names = try field_names.toOwnedSlice(self.allocator),
            .field_name_starts = try field_name_starts.toOwnedSlice(self.allocator),
            .field_types = try field_types.toOwnedSlice(self.allocator),
            .field_defaults = try field_defaults.toOwnedSlice(self.allocator),
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .using_entries = try using_entries.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .constants = try constants.toOwnedSlice(self.allocator),
            .abi = struct_abi,
            .extern_lib = struct_extern_lib,
            .is_raw = name_is_raw,
            .open_variant_of = open_variant_of,
            .open_variant_span = open_variant_span,
        } });
    }

    /// `V :: @OpenVariant(P) [($T: Type)] { fields + the set's methods }`.
    fn parseOpenVariantDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip '@OpenVariant'
        try self.expect(.l_paren);
        const set_idx = self.tok;
        if (self.tokens.tag(self.tok) != .identifier) {
            return self.fail("expected the open set's name in '@OpenVariant(…)'");
        }
        var set_name = self.tokens.slice(set_idx);
        self.advance();
        // The head may be QUALIFIED (`@OpenVariant(pkg.View)`): the set a module
        // reached by name declares. The path is carried whole; `lower/open_set.zig`
        // resolves it from this declaration's own file.
        var head_end = self.tokens.end(set_idx);
        while (self.tokens.tag(self.tok) == .dot) {
            self.advance();
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected a name after '.' in the open set's name");
            }
            const seg_idx = self.tok;
            self.advance();
            set_name = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ set_name, self.tokens.slice(seg_idx) }) catch set_name;
            head_end = self.tokens.end(seg_idx);
        }
        try self.expect(.r_paren);
        return self.parseStructTail(name, start_pos, name_is_raw, set_name, .{ .start = self.tokens.start(set_idx), .end = head_end });
    }

    /// `P :: @OpenSet(.{ max = …, align = … }) { required methods }`.
    fn parseOpenSetDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip '@OpenSet'
        try self.expect(.l_paren);
        const opt_start = self.tokens.start(self.tok);
        const options = try self.parseExpr();
        const opt_end = self.tokens.end(self.tok);
        try self.expect(.r_paren);
        try self.expect(.l_brace);

        var methods = std.ArrayList(ast.ProtocolMethodDecl).empty;
        try self.parseRequiredMethods(&methods);
        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .open_set_decl = .{
            .name = name,
            .methods = try methods.toOwnedSlice(self.allocator),
            .options = options,
            .options_span = .{ .start = opt_start, .end = opt_end },
            .is_raw = name_is_raw,
        } });
    }

    /// The shared `{ name :: (params) -> T; … }` member list of a protocol and of
    /// an open set: both declare REQUIRED methods, with `Self` denoting the
    /// implementing type, and both monomorphize them per member.
    fn parseRequiredMethods(self: *Parser, methods: *std.ArrayList(ast.ProtocolMethodDecl)) anyerror!void {
        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            // Method: name :: (params) -> type;  or  name :: (params) -> type { body }
            if (!self.isMemberDeclName()) {
                return self.failMemberDeclName("expected method name in protocol body");
            }
            const method_name = self.tokens.slice(self.tok);
            self.advance();
            try self.expect(.colon_colon);
            try self.expect(.l_paren);

            var param_types = std.ArrayList(*Node).empty;
            var param_names = std.ArrayList([]const u8).empty;
            var param_name_spans = std.ArrayList(ast.Span).empty;
            var param_name_is_raw = std.ArrayList(bool).empty;

            while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                if (param_types.items.len > 0) {
                    try self.expect(.comma);
                    if (self.tokens.tag(self.tok) == .r_paren) break;
                }
                // Parse: name: type
                if (self.tokens.tag(self.tok) != .identifier and self.tokens.tag(self.tok) != .kw_Self) {
                    return self.fail("expected parameter name in protocol method");
                }
                const pname = self.tokens.slice(self.tok);
                try param_name_spans.append(self.allocator, .{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) });
                try param_name_is_raw.append(self.allocator, self.tokens.flagsOf(self.tok).is_raw);
                self.advance();
                try self.expect(.colon);
                const ptype = try self.parseTypeExpr();
                try param_names.append(self.allocator, pname);
                try param_types.append(self.allocator, ptype);
            }
            try self.expect(.r_paren);

            // Every protocol method must declare its receiver EXPLICITLY as the
            // first parameter — `self: *Self` (or `self: Self`) — matching how
            // `impl` methods and ordinary methods are written, so no listed
            // param is ambiguous between receiver and extra arg. The receiver
            // is validated and then stripped here, so downstream lowering sees
            // only the EXTRA-arg params.
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
            if (self.tokens.tag(self.tok) == .arrow) {
                self.advance();
                return_type = try self.parseFnReturnType();
            }

            // Optional body (default method) or semicolon
            var default_body: ?*Node = null;
            if (self.tokens.tag(self.tok) == .l_brace) {
                // A default-method body's declarations are locals.
                const saved_module_expansion = self.in_module_expansion;
                self.in_module_expansion = false;
                defer self.in_module_expansion = saved_module_expansion;
                default_body = try self.parseBlock();
            } else {
                if (self.tokens.tag(self.tok) == .semicolon) self.advance();
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
    }

    fn parseProtocolDecl(self: *Parser, name: []const u8, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip 'protocol'

        // Optional type params: protocol(Target: Type, U: Type) { ... }
        // Names are introduced without a `$` sigil (unlike struct's $T) because
        // the parens after `protocol` already mark this as a parameter list.
        var type_params = std.ArrayList(ast.StructTypeParam).empty;
        if (self.tokens.tag(self.tok) == .l_paren) {
            self.advance(); // skip '('
            while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                if (type_params.items.len > 0) {
                    try self.expect(.comma);
                    if (self.tokens.tag(self.tok) == .r_paren) break;
                }
                if (self.tokens.tag(self.tok) != .identifier) {
                    return self.fail("expected type parameter name in protocol header");
                }
                const param_name = self.tokens.slice(self.tok);
                self.advance();
                try self.expect(.colon);
                const constraint = try self.parseTypeExpr();
                try type_params.append(self.allocator, .{ .name = param_name, .constraint = constraint });
            }
            try self.expect(.r_paren);
        }

        // The kind slot, after the parameter list and before the attributes.
        // `constraint` / `vtable` are CONTEXTUAL here — ordinary identifiers
        // everywhere else. Absent ⇒ constraint. Nothing but a kind word or
        // `{` may stand here, so an identifier is unambiguously a kind.
        var kind: ast.ProtocolKind = .constraint;
        if (self.tokens.tag(self.tok) == .identifier and !self.tokens.flagsOf(self.tok).is_raw) {
            const word = self.tokens.slice(self.tok);
            if (std.mem.eql(u8, word, "constraint")) {
                kind = .constraint;
            } else if (std.mem.eql(u8, word, "vtable")) {
                kind = .vtable;
            } else {
                return self.fail("expected a protocol kind ('constraint', 'vtable') or '{' after the protocol head");
            }
            self.advance();
        }

        var is_identity = false;
        while (self.tokens.tag(self.tok) == .hash_identity) {
            if (is_identity) return self.fail("duplicate #identity on protocol");
            if (kind == .constraint) {
                return self.fail("#identity is meaningless on a constraint protocol — there are no runtime values to classify");
            }
            is_identity = true;
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

        try self.parseRequiredMethods(&methods);

        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .protocol_decl = .{
            .name = name,
            .methods = try methods.toOwnedSlice(self.allocator),
            .kind = kind,
            .is_identity = is_identity,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .is_raw = name_is_raw,
        } });
    }

    fn parseRuntimeAliasList(self: *Parser, out: *std.ArrayList([]const u8)) !void {
        if (self.tokens.tag(self.tok) == .dot) {
            self.advance();
            try self.expect(.l_bracket);
            while (self.tokens.tag(self.tok) != .r_bracket and self.tokens.tag(self.tok) != .eof) {
                if (out.items.len > 0) {
                    try self.expect(.comma);
                    if (self.tokens.tag(self.tok) == .r_bracket) break;
                }
                if (self.tokens.tag(self.tok) != .identifier) {
                    return self.fail("expected type alias in the implements/extends list");
                }
                try out.append(self.allocator, self.tokens.slice(self.tok));
                self.advance();
            }
            try self.expect(.r_bracket);
            if (out.items.len == 0) return self.fail("expected at least one type alias in '.[…]'");
            return;
        }
        if (self.tokens.tag(self.tok) != .identifier) {
            return self.fail("expected a type alias after '='");
        }
        try out.append(self.allocator, self.tokens.slice(self.tok));
        self.advance();
    }

    const ObjcPropertyParsed = struct { payload: *Node, modifiers: []const []const u8 };

    fn parseObjcPropertyType(self: *Parser) !ObjcPropertyParsed {
        self.advance(); // skip @ObjcProperty
        try self.expect(.l_paren);
        const payload = try self.parseTypeExpr();
        var mods = std.ArrayList([]const u8).empty;
        while (self.tokens.tag(self.tok) == .comma) {
            self.advance();
            if (self.tokens.tag(self.tok) == .r_paren) break;
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected 'ownership', 'access', 'atomic', 'getter', or 'setter'");
            }
            const key = self.tokens.slice(self.tok);
            self.advance();
            try self.expect(.equal);
            if (std.mem.eql(u8, key, "ownership") or std.mem.eql(u8, key, "access")) {
                if (self.tokens.tag(self.tok) != .identifier) {
                    return self.fail("expected an identifier after '='");
                }
                try mods.append(self.allocator, self.tokens.slice(self.tok));
                self.advance();
            } else if (std.mem.eql(u8, key, "atomic")) {
                if (self.tokens.tag(self.tok) == .kw_false) {
                    try mods.append(self.allocator, "nonatomic");
                    self.advance();
                } else if (self.tokens.tag(self.tok) == .kw_true) {
                    try mods.append(self.allocator, "atomic");
                    self.advance();
                } else {
                    return self.fail("expected true or false after 'atomic ='");
                }
            } else if (std.mem.eql(u8, key, "getter") or std.mem.eql(u8, key, "setter")) {
                if (self.tokens.tag(self.tok) != .string_literal) {
                    return self.fail("expected a string literal after '='");
                }
                // Stored as the bare key; the string is consumed. ARC does not read getter/setter names.
                _ = self.tokens.slice(self.tok);
                self.advance();
                try mods.append(self.allocator, key);
            } else {
                return self.fail("expected 'ownership', 'access', 'atomic', 'getter', or 'setter'");
            }
        }
        try self.expect(.r_paren);
        return .{ .payload = payload, .modifiers = try mods.toOwnedSlice(self.allocator) };
    }

    fn parseObjcMethodNote(self: *Parser) ![]const u8 {
        self.advance(); // skip @ObjcMethod
        try self.expect(.l_paren);
        if (self.tokens.tag(self.tok) != .identifier or !std.mem.eql(u8, self.tokens.slice(self.tok), "selector")) {
            return self.fail("expected 'selector =' after '@ObjcMethod('");
        }
        self.advance();
        try self.expect(.equal);
        if (self.tokens.tag(self.tok) != .string_literal) {
            return self.fail("expected string literal after 'selector ='");
        }
        const raw = self.tokens.slice(self.tok);
        const sel = raw[1 .. raw.len - 1];
        self.advance();
        try self.expect(.r_paren);
        return sel;
    }

    fn parseJniMethodNote(self: *Parser) ![]const u8 {
        self.advance(); // skip @JniMethod
        try self.expect(.l_paren);
        if (self.tokens.tag(self.tok) != .identifier or !std.mem.eql(u8, self.tokens.slice(self.tok), "descriptor")) {
            return self.fail("expected 'descriptor =' after '@JniMethod('");
        }
        self.advance();
        try self.expect(.equal);
        if (self.tokens.tag(self.tok) != .string_literal) {
            return self.fail("expected string literal after 'descriptor ='");
        }
        const raw = self.tokens.slice(self.tok);
        const desc = raw[1 .. raw.len - 1];
        self.advance();
        try self.expect(.r_paren);
        return desc;
    }

    fn peekTag(self: *Parser, offset: usize) Tag {
        return self.tokens.tag(self.tokens.peek(self.tok, @intCast(offset)));
    }

    fn runtimeKindForAtName(_: *Parser, at_name: []const u8) ?ast.RuntimeKind {
        if (std.mem.eql(u8, at_name, contracts.jni_class_head)) return .jni_class;
        if (std.mem.eql(u8, at_name, contracts.jni_interface_head)) return .jni_interface;
        if (std.mem.eql(u8, at_name, contracts.objc_class_head)) return .objc_class;
        if (std.mem.eql(u8, at_name, contracts.objc_protocol_head)) return .objc_protocol;
        if (std.mem.eql(u8, at_name, contracts.swift_class_head)) return .swift_class;
        if (std.mem.eql(u8, at_name, contracts.swift_struct_head)) return .swift_struct;
        if (std.mem.eql(u8, at_name, contracts.swift_protocol_head)) return .swift_protocol;
        return null;
    }

    fn parseRuntimeClassDecl(self: *Parser, name: []const u8, start_pos: u32, runtime: ast.RuntimeKind, name_is_raw: bool) anyerror!*Node {
        self.advance(); // skip @JniClass / @ObjcClass / …

        try self.expect(.l_paren);
        if (self.tokens.tag(self.tok) != .string_literal) {
            return self.fail("expected string literal runtime path as the first argument");
        }
        const raw = self.tokens.slice(self.tok);
        const runtime_path = raw[1 .. raw.len - 1];
        self.advance();

        var is_main = false;
        var extends_aliases = std.ArrayList([]const u8).empty;
        var implements_aliases = std.ArrayList([]const u8).empty;
        while (self.tokens.tag(self.tok) == .comma) {
            self.advance();
            if (self.tokens.tag(self.tok) == .r_paren) break;
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected named argument 'extends', 'implements', or 'main'");
            }
            const arg_name = self.tokens.slice(self.tok);
            self.advance();
            try self.expect(.equal);
            if (std.mem.eql(u8, arg_name, "main")) {
                if (self.tokens.tag(self.tok) == .kw_true) {
                    is_main = true;
                    self.advance();
                } else if (self.tokens.tag(self.tok) == .kw_false) {
                    is_main = false;
                    self.advance();
                } else {
                    return self.fail("expected true or false after 'main ='");
                }
            } else if (std.mem.eql(u8, arg_name, "extends")) {
                try self.parseRuntimeAliasList(&extends_aliases);
            } else if (std.mem.eql(u8, arg_name, "implements")) {
                try self.parseRuntimeAliasList(&implements_aliases);
            } else {
                return self.fail("expected named argument 'extends', 'implements', or 'main'");
            }
        }
        try self.expect(.r_paren);

        if (extends_aliases.items.len > 1 and (runtime == .jni_class or runtime == .objc_class or runtime == .swift_class)) {
            return self.fail("a class takes one 'extends' type");
        }
        if (implements_aliases.items.len > 0 and (runtime == .jni_interface or runtime == .objc_protocol or runtime == .swift_protocol)) {
            return self.fail("'implements' is only legal on a class");
        }
        if (is_main and (runtime != .jni_class and runtime != .objc_class)) {
            return self.fail("'main = true' is only legal on @JniClass or @ObjcClass");
        }

        // Postfix `extern` / `export` after the constructor:
        //   `… extern { … }`  ⇒ reference an existing runtime class.
        //   `… export { … }`  ⇒ define + register a new sx class (the default).
        var is_extern_eff = false;
        if (self.tokens.tag(self.tok) == .kw_extern or self.tokens.tag(self.tok) == .kw_export) {
            is_extern_eff = self.tokens.tag(self.tok) == .kw_extern;
            self.advance();
        }

        try self.expect(.l_brace);

        var members = std.ArrayList(ast.RuntimeClassMember).empty;
        for (extends_aliases.items) |alias| {
            try members.append(self.allocator, .{ .extends = alias });
        }
        for (implements_aliases.items) |alias| {
            try members.append(self.allocator, .{ .implements = alias });
        }
        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            // Field: name: Type;       (instance field — JNI Get/Set<Type>Field)
            // Method: name :: (args...) -> Ret;
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected member name in a runtime-class body");
            }
            const member_name = self.tokens.slice(self.tok);
            self.advance();

            if (self.tokens.tag(self.tok) == .colon) {
                self.advance(); // consume `:`
                var field_type: *Node = undefined;
                var is_property = false;
                var property_modifiers: []const []const u8 = &.{};
                if (self.tokens.tag(self.tok) == .at_identifier and
                    std.mem.eql(u8, self.tokens.slice(self.tok), contracts.objc_property_head))
                {
                    const parsed = try self.parseObjcPropertyType();
                    field_type = parsed.payload;
                    is_property = true;
                    property_modifiers = parsed.modifiers;
                } else {
                    field_type = try self.parseTypeExpr();
                }

                try self.expect(.semicolon);
                try members.append(self.allocator, .{ .field = .{
                    .name = member_name,
                    .field_type = field_type,
                    .is_property = is_property,
                    .property_modifiers = property_modifiers,
                } });
                continue;
            }

            try self.expect(.colon_colon);

            // Class-level constant `name :: Type = expr;` inside
            // a `@ObjcClass` block. Reframed as a synthesized class method
            // with an expression body (`name :: () -> Type => expr;`) so
            // the class-synthesis pipeline picks it up:
            // a class-method IMP is emitted and registered on the metaclass.
            // Apple's runtime calls the IMP from `[Cls foo]` — there's no
            // runtime-level distinction between a class-level constant and
            // a niladic class method, just a difference in source spelling.
            if (self.tokens.tag(self.tok) != .l_paren) {
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
            while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                if (param_types.items.len > 0) {
                    try self.expect(.comma);
                    if (self.tokens.tag(self.tok) == .r_paren) break;
                }
                if (self.tokens.tag(self.tok) != .identifier and self.tokens.tag(self.tok) != .kw_Self) {
                    return self.fail("expected parameter name in '@JniClass' method");
                }
                const pname = self.tokens.slice(self.tok);
                try param_name_spans.append(self.allocator, .{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) });
                try param_name_is_raw.append(self.allocator, self.tokens.flagsOf(self.tok).is_raw);
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
            if (self.tokens.tag(self.tok) == .arrow) {
                self.advance();
                return_type = try self.parseFnReturnType();
            }

            var desc_override: ?[]const u8 = null;
            var sel_override: ?[]const u8 = null;
            if (self.tokens.tag(self.tok) == .at_identifier) {
                const note = self.tokens.slice(self.tok);
                if (std.mem.eql(u8, note, contracts.objc_method_head)) {
                    sel_override = try self.parseObjcMethodNote();
                } else if (std.mem.eql(u8, note, contracts.jni_method_head)) {
                    desc_override = try self.parseJniMethodNote();
                }
            }

            // Method body is optional: `;` → declaration (extern or inherited
            // method we just want to call); `{ ... }` → sx-side block body
            // for sx-defined classes; `=> expr;` → expression-body form
            // Lowered as a single-statement block holding `expr`.
            var body_node: ?*Node = null;
            if (self.tokens.tag(self.tok) == .l_brace) {
                // A runtime-class method body's declarations are locals.
                const saved_module_expansion = self.in_module_expansion;
                self.in_module_expansion = false;
                defer self.in_module_expansion = saved_module_expansion;
                body_node = try self.parseBlock();
            } else if (self.tokens.tag(self.tok) == .fat_arrow) {
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

        // Protocol name. A contract protocol (`impl @BuildSink(P) for …`) is an
        // ordinary protocol here — the `@` is part of its name.
        if (self.tokens.tag(self.tok) != .identifier and self.tokens.tag(self.tok) != .at_identifier) {
            return self.fail("expected protocol name after 'impl'");
        }
        const protocol_name = self.tokens.slice(self.tok);
        self.advance();

        // Optional protocol type args: impl Into(Block) for ...
        var protocol_type_args = std.ArrayList(*Node).empty;
        if (self.tokens.tag(self.tok) == .l_paren) {
            self.advance(); // skip '('
            while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                if (protocol_type_args.items.len > 0) {
                    try self.expect(.comma);
                    if (self.tokens.tag(self.tok) == .r_paren) break;
                }
                try protocol_type_args.append(self.allocator, try self.parseTypeExpr());
            }
            try self.expect(.r_paren);
        }

        // 'for' — note: 'for' is a keyword (kw_for), not an identifier
        if (self.tokens.tag(self.tok) != .kw_for) {
            return self.fail("expected 'for' after protocol name in impl block");
        }
        self.advance();

        // Source-type spelling. For parameterised protocols we accept any TypeExpr
        // (`Closure(...) -> R`, `*T`, etc.). For nullary protocols the source is
        // an identifier alone, so the parser doesn't over-parse trailing tokens.
        var target_type: []const u8 = "";
        var target_type_expr: ?*Node = null;
        var target_type_params = std.ArrayList(ast.StructTypeParam).empty;

        if (protocol_type_args.items.len > 0) {
            // Parameterised protocol — source is a general TypeExpr.
            target_type_expr = try self.parseTypeExpr();
            // Synthesize a string view of the source for name-only consumers
            // (LSP hover, etc.). The semantic key for the impl map uses
            // structural mangling, not this string.
            if (target_type_expr.?.data == .type_expr) {
                target_type = target_type_expr.?.data.type_expr.name;
            }
        } else {
            // Nullary protocol: single identifier source.
            if (self.tokens.tag(self.tok) != .identifier and !self.tokens.tag(self.tok).isTypeKeyword()) {
                return self.fail("expected type name after 'for'");
            }
            target_type = self.tokens.slice(self.tok);
            self.advance();

            // Optional type params: impl Protocol for List($T)
            if (self.tokens.tag(self.tok) == .l_paren) {
                self.advance(); // skip '('
                while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                    if (target_type_params.items.len > 0) {
                        try self.expect(.comma);
                        if (self.tokens.tag(self.tok) == .r_paren) break;
                    }
                    try self.expect(.dollar);
                    if (self.tokens.tag(self.tok) != .identifier) {
                        return self.fail("expected type parameter name after '$'");
                    }
                    const param_name = self.tokens.slice(self.tok);
                    self.advance();
                    // Optional constraint — always `Type`.
                    const constraint = try self.createNode(self.tokens.start(self.tok), .{ .type_expr = .{ .name = "Type" } });
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

        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            // Method: name :: (params) -> type { body }
            if (!self.isMemberDeclName()) {
                return self.failMemberDeclName("expected method name in impl block");
            }
            const method_start = self.tokens.start(self.tok);
            const method_name = self.tokens.slice(self.tok);
            const method_name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
            const method_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            self.advance();
            try self.expect(.colon_colon);

            if (self.tokens.tag(self.tok) == .l_paren and self.isFunctionDef()) {
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

        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            if (field_inits.items.len > 0) {
                try self.expect(.comma);
                if (self.tokens.tag(self.tok) == .r_brace) break;
            }

            // Spread element: `.{ ..xs }` / `.{ a, ..t, b }` — reuses
            // `spread_expr` as a positional init, mirroring `.( )`'s spread
            // (tuple/pack spreads route in lowering).
            if (self.tokens.tag(self.tok) == .dot_dot) {
                const sp_start = self.tokens.start(self.tok);
                self.advance(); // skip '..'
                const operand = try self.parseExpr();
                const spread = try self.createNode(sp_start, .{ .spread_expr = .{ .operand = operand } });
                try field_inits.append(self.allocator, .{ .name = null, .value = spread });
                continue;
            }

            // Named field: an IDENTIFIER followed by '='. A keyword label takes
            // the backtick raw escape (`` .{ `if = 2 } ``); bare, the keyword
            // heads a positional expression (`.{ if x then 1 else 2 }`).
            if (self.tokens.tag(self.tok) == .identifier) {
                const saved = self.tok;
                const fname = self.tokens.slice(self.tok);
                const ident_start = self.tokens.start(self.tok);
                self.advance();

                if (self.tokens.tag(self.tok) == .equal) {
                    // Named field: name = expr
                    self.advance(); // skip '='
                    const value = try self.parseExpr();
                    try field_inits.append(self.allocator, .{ .name = fname, .value = value });
                    continue;
                } else if (self.tokens.tag(self.tok) == .comma or self.tokens.tag(self.tok) == .r_brace) {
                    // Shorthand: just an identifier (name = identifier with same name)
                    const ident_node = try self.createNode(ident_start, .{ .identifier = .{ .name = fname } });
                    try field_inits.append(self.allocator, .{ .name = fname, .value = ident_node, .was_shorthand = true });
                    continue;
                }

                // Not named — backtrack and parse as positional expression
                self.tok = saved;
            }

            // Positional field: just an expression
            const value = try self.parseExpr();
            try field_inits.append(self.allocator, .{ .name = null, .value = value });
        }
        try self.expect(.r_brace);

        return try self.createNode(start_pos, .{ .struct_literal = .{
            .struct_name = struct_name,
            .type_expr = type_expr,
            .field_inits = try field_inits.toOwnedSlice(self.allocator),
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

    /// A parsed parameter list: its fixed parameters, and whether it ends in a
    /// bare `..` C-variadic tail (which binds no name and no type, so it is a
    /// flag rather than a `Param`).
    const ParamList = struct {
        params: []const ast.Param,
        is_c_variadic: bool = false,
        /// Span of the bare `..`, for the refusals that name it.
        tail_span: ast.Span = .{ .start = 0, .end = 0 },
    };

    /// Parse a parenthesized parameter list: `(name: type, $T: Type, args: ..Any)`
    /// Handles `$` generic params, `..` variadic marker, and comptime detection.
    /// Expects opening `(` already NOT consumed — this function consumes `(` through `)`.
    fn parseParams(self: *Parser) anyerror!ParamList {
        try self.expect(.l_paren);
        return self.parseParamsUntil(.r_paren);
    }

    /// The parameter list itself, with its opener already consumed and `close`
    /// as its closer: `)` for a signature, `|` for a closure literal.
    fn parseParamsUntil(self: *Parser, close: Tag) anyerror!ParamList {
        var params = std.ArrayList(ast.Param).empty;
        var is_c_variadic = false;
        var tail_span: ast.Span = .{ .start = 0, .end = 0 };
        while (self.tokens.tag(self.tok) != close and self.tokens.tag(self.tok) != .eof) {
            if (params.items.len > 0) {
                try self.expect(.comma);
                if (self.tokens.tag(self.tok) == close) break;
            }
            // Leading `..` marks a variadic param at the binding site:
            // `..$args` (heterogeneous comptime pack), `..xs: []T` (slice),
            // `..xs: P` (protocol-constrained pack).
            var is_variadic = false;
            if (self.tokens.tag(self.tok) == .dot_dot) {
                const dots = self.tokens.token(self.tok).loc;
                is_variadic = true;
                self.advance();
                // A bare `..` — one token of lookahead separates the C-variadic
                // tail from every named form: the tail carries no operand. It
                // is the last entry, so an ordinary trailing comma may follow
                // it and nothing else may.
                if (self.tokens.tag(self.tok) == close or self.tokens.tag(self.tok) == .comma) {
                    is_c_variadic = true;
                    tail_span = .{ .start = dots.start, .end = dots.end };
                    if (self.tokens.tag(self.tok) == .comma) self.advance();
                    if (self.tokens.tag(self.tok) != close) {
                        return self.failAt(tail_span, "a C-variadic '..' tail must be the last parameter entry");
                    }
                    break;
                }
            }
            var is_ct_param = false;
            if (self.tokens.tag(self.tok) == .dollar) {
                is_ct_param = true;
                self.advance();
            }
            if (!self.isIdentLike()) {
                return self.fail("expected parameter name");
            }
            const param_name = self.tokens.slice(self.tok);
            const param_name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
            const param_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            self.advance();
            // Optional type annotation: if no ':', infer type from context
            if (self.tokens.tag(self.tok) != .colon) {
                // A variadic binding has no context to infer from: the slice
                // and protocol forms are their annotation, and `..$name` is a
                // comptime pack whose types come from the call.
                if (is_variadic and !is_ct_param) {
                    return self.failAt(
                        param_name_span,
                        "a variadic parameter carries its type: '..name: []T' binds a slice, '..name: P' a protocol pack, '..$name' a comptime pack",
                    );
                }
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
                    // Bounds on the explicit form: `$T: Type/Eq/Hashable`.
                    const pc = try self.parseBoundList();
                    param_type.data = .{ .type_expr = .{ .name = param_name, .is_generic = true, .protocol_constraints = pc } };
                } else {
                    is_comptime_param = true;
                }
            }
            // Optional default value: `param: T = expr`. Stored on the Param
            // node; lowering fills it in for callers that omit this positional arg.
            var default_expr: ?*Node = null;
            if (self.tokens.tag(self.tok) == .equal) {
                self.advance(); // consume '='
                const saved_in_default = self.in_param_default;
                self.in_param_default = true;
                defer self.in_param_default = saved_in_default;
                default_expr = try self.parseBinary(Prec.none, if (close == .pipe) PipeRole.closer else .bit_or);
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
        // One tail per signature: a named `..name: []T` and a bare `..` state
        // two different contracts over the same argument positions.
        if (is_c_variadic and params.items.len > 0 and params.items[params.items.len - 1].is_variadic) {
            return self.failAt(tail_span, "a signature has one variadic tail: '..name: []T' or bare '..'");
        }
        try self.expect(close);
        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .is_c_variadic = is_c_variadic,
            .tail_span = tail_span,
        };
    }

    /// The type arguments of the `@Init` bound on `node`, empty when it carries
    /// none. That bound's argument is inferred from the argument an initializer
    /// is formed from, so a binder written there belongs to the declaration
    /// exactly as one written in the annotation does.
    fn initBoundArgs(node: *const Node) []const *Node {
        if (node.data != .type_expr) return &.{};
        for (node.data.type_expr.protocol_constraints) |bound| {
            if (bound.data != .parameterized_type_expr) continue;
            const pte = bound.data.parameterized_type_expr;
            if (!std.mem.eql(u8, pte.name, contracts.init_bound)) continue;
            return pte.args;
        }
        return &.{};
    }

    /// Recursively find all generic type names ($T) in a type expression tree.
    /// Every bound the `$name` binder carries inside `node`, searching each
    /// element position a type constructor can nest one in — `*$S/@BuildSink(P)`
    /// binds `S` under a pointer, and the bounds belong to `S`, not to the
    /// pointer around it. Appends, so one binder's bounds accumulate across
    /// every spelling of it.
    fn collectBinderBounds(self: *Parser, node: *const Node, name: []const u8, out: *std.ArrayList(*Node)) void {
        switch (node.data) {
            .type_expr => |te| {
                if (te.is_generic and std.mem.eql(u8, te.name, name))
                    out.appendSlice(self.allocator, te.protocol_constraints) catch {};
                // A binder introduced INSIDE an `@Init` bound (`$I/@Init($V/P)`)
                // carries its own bounds, which belong to it and not to `$I`.
                for (initBoundArgs(node)) |a| collectBinderBounds(self, a, name, out);
            },
            .pointer_type_expr => |p| collectBinderBounds(self, p.pointee_type, name, out),
            .many_pointer_type_expr => |m| collectBinderBounds(self, m.element_type, name, out),
            .slice_type_expr => |s| collectBinderBounds(self, s.element_type, name, out),
            .array_type_expr => |a| collectBinderBounds(self, a.element_type, name, out),
            .optional_type_expr => |o| collectBinderBounds(self, o.inner_type, name, out),
            .parameterized_type_expr => |p| for (p.args) |a| collectBinderBounds(self, a, name, out),
            .tuple_type_expr => |t| for (t.field_types) |f| collectBinderBounds(self, f, name, out),
            .closure_type_expr => |c| {
                for (c.param_types) |p| collectBinderBounds(self, p, name, out);
                if (c.return_type) |r| collectBinderBounds(self, r, name, out);
            },
            .function_type_expr => |f| {
                for (f.param_types) |p| collectBinderBounds(self, p, name, out);
                if (f.return_type) |r| collectBinderBounds(self, r, name, out);
            },
            else => {},
        }
    }

    fn collectGenericNames(node: *Node, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
        switch (node.data) {
            .type_expr => |te| {
                if (te.is_generic) list.append(allocator, te.name) catch {};
                // A binder written inside an `@Init` bound (`$I/@Init($T)`,
                // `$I/@Init($V/View)`) is one of this declaration's type
                // parameters.
                for (initBoundArgs(node)) |a| collectGenericNames(a, list, allocator);
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
                        const type_constraint = self.createNode(param.type_expr.span.start, .{ .type_expr = .{ .name = "Type" } }) catch continue;
                        type_params.append(self.allocator, .{ .name = gen_name, .constraint = type_constraint }) catch {};
                    }
                }
            }
        }
        // Bounds are gathered after the names, over EVERY parameter: one binder
        // may be spelled in several of them (`(a: $T/Ord, b: $T/Show)`), and each
        // spelling's bounds are the declaration's. Keeping only the first
        // spelling's would discard a written constraint.
        for (type_params.items) |*tp| {
            var bounds = std.ArrayList(*Node).empty;
            for (params) |param| {
                if (param.is_comptime) continue;
                collectBinderBounds(self, param.type_expr, tp.name, &bounds);
            }
            if (bounds.items.len > 0)
                tp.protocol_constraints = bounds.toOwnedSlice(self.allocator) catch tp.protocol_constraints;
        }
        return try type_params.toOwnedSlice(self.allocator);
    }

    /// `@NAME :: (params) [-> R] { body }` or, where the implementation is the
    /// compiler's, `@NAME :: (params) [-> R];`. A bodyless declaration takes
    /// the body node the `intrinsic` keyword builds for a plain name, so every
    /// downstream consumer reads one shape. Either form carries no ABI,
    /// linkage, `ufcs`, or accessor modifier.
    fn parseAtFnDecl(self: *Parser, name: []const u8, name_span: ast.Span, start_pos: u32, name_is_raw: bool) anyerror!*Node {
        const list = try self.parseParams();
        if (list.is_c_variadic) {
            return self.failAt(list.tail_span, "a C-variadic '..' tail requires 'abi(.c)', 'extern', or 'export'");
        }
        const params = list.params;

        var return_type: ?*Node = null;
        if (self.tokens.tag(self.tok) == .arrow) {
            self.advance();
            return_type = try self.parseFnReturnType();
        }

        const body = if (self.tokens.tag(self.tok) == .l_brace) blk: {
            const saved_module_expansion = self.in_module_expansion;
            self.in_module_expansion = false;
            defer self.in_module_expansion = saved_module_expansion;
            break :blk try self.parseBlock();
        } else blk: {
            const body_start = self.tokens.start(self.tok);
            try self.expectStatementEnd();
            break :blk try self.createNode(body_start, .{ .intrinsic_expr = {} });
        };
        const type_params = try self.collectTypeParams(params);

        return try self.createNode(start_pos, .{ .fn_decl = .{
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .type_params = type_params,
            .name_span = name_span,
            .is_raw = name_is_raw,
        } });
    }

    fn parseFnDecl(self: *Parser, name: []const u8, name_span: ast.Span, name_is_raw: bool, start_pos: u32) anyerror!*Node {
        const param_list = try self.parseParams();
        const params = param_list.params;

        // Optional return type
        var return_type: ?*Node = null;
        if (self.tokens.tag(self.tok) == .arrow) {
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
        if (self.tokens.tag(self.tok) == .hash_get) {
            is_get = true;
            self.advance();
        } else if (self.tokens.tag(self.tok) == .hash_set) {
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
        if (extern_export != .none and (self.tokens.tag(self.tok) == .kw_extern or self.tokens.tag(self.tok) == .kw_export)) {
            return self.fail("conflicting linkage: 'extern' and 'export' cannot be combined — a declaration is either an import ('extern') or a definition ('export')");
        }

        // A bare `..` tail is legal only on an EFFECTIVE-C SIGNATURE: a
        // definition carrying `abi(.c)` or `export`, or an `extern` declaration.
        // Every one of those emits the C shape with no implicit sx context.
        if (param_list.is_c_variadic) {
            if (abi == .naked) {
                return self.failAt(param_list.tail_span, "a C-variadic '..' tail cannot use explicit ABI '.naked'; use 'abi(.c)' or omit it on an 'extern' or 'export'");
            }
            if (abi != .c and extern_export == .none) {
                return self.failAt(param_list.tail_span, "a C-variadic '..' tail requires 'abi(.c)', 'extern', or 'export'");
            }
        }

        // Optional `[LIB] ["csym"]` tail after extern/export — a library-alias
        // ident then a C symbol-name string, both optional (mirrors
        // `extern LIB "csym"`). Stored on extern_lib/extern_name; the rename
        // is consumed in `declareFunction`, the lib reference in Part B.
        var extern_lib: ?[]const u8 = null;
        var extern_name: ?[]const u8 = null;
        if (extern_export != .none) {
            const tail = self.parseLinkageTail(true);
            extern_lib = tail.lib;
            extern_name = tail.name;
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
        const saved_module_expansion = self.in_module_expansion;
        self.in_module_expansion = false;
        defer self.in_module_expansion = saved_module_expansion;
        var is_arrow = false;
        const body = if (extern_export == .extern_) blk: {
            const semi_start = self.tokens.start(self.tok);
            try self.expectStatementEnd();
            const stmts = try self.allocator.alloc(*Node, 0);
            break :blk try self.createNode(semi_start, .{ .block = .{ .stmts = stmts, .produces_value = false } });
        } else if (self.tokens.tag(self.tok) == .kw_intrinsic) blk: {
            const bi_start = self.tokens.start(self.tok);
            self.advance();
            try self.expectStatementEnd();
            break :blk try self.createNode(bi_start, .{ .intrinsic_expr = {} });
        } else if (self.tokens.tag(self.tok) == .fat_arrow) blk: {
            is_arrow = true;
            self.advance();
            const expr = try self.parseExpr();
            try self.expectStatementEnd();
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
            .is_c_variadic = param_list.is_c_variadic,
        } });
    }

    fn parseBlock(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        try self.expect(.l_brace);
        return self.parseBlockBody(start);
    }

    /// The statements of a block whose `{` — at `start` — is already consumed.
    fn parseBlockBody(self: *Parser, start: u32) anyerror!*Node {
        return self.parseBraceBody(start, false);
    }

    /// The items of a brace group whose `{` — at `start` — is already consumed.
    /// `commas` marks a juxtaposition's group, where `,` ends an item too.
    fn parseBraceBody(self: *Parser, start: u32, commas: bool) anyerror!*Node {
        const saved_commas = self.comma_separates_items;
        self.comma_separates_items = commas;
        defer self.comma_separates_items = saved_commas;
        // This body's statements are classified here and nowhere else: the
        // enclosing statement's mark comes back untouched at the `}`.
        const saved_produces = self.last_stmt_produces_value;
        defer self.last_stmt_produces_value = saved_produces;
        var stmts = std.ArrayList(*Node).empty;
        var produces_value = false;
        while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
            const stmt = if (commas) try self.parseBraceItem() else try self.parseStmt();
            try stmts.append(self.allocator, stmt);
            // The block's value-ness is its LAST statement's value-ness.
            produces_value = self.last_stmt_produces_value;
        }
        try self.expect(.r_brace);
        return try self.createNode(start, .{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator), .produces_value = produces_value } });
    }

    /// One item of a juxtaposition's brace group. `name = value` binds here so
    /// that it ends on the group's separators. The label is an IDENTIFIER: a
    /// keyword one takes the backtick raw escape (`` Pair(i64){ `push = 7 } ``),
    /// bare it heads a statement.
    fn parseBraceItem(self: *Parser) anyerror!*Node {
        if (self.tokens.tag(self.tok) == .identifier and self.peekNext() == .equal) {
            const start = self.tokens.start(self.tok);
            const name = self.tokens.slice(self.tok);
            const target = try self.createNode(start, .{ .identifier = .{ .name = name } });
            self.advance(); // name
            self.advance(); // '='
            const value = try self.parseExpr();
            const item = try self.createNode(start, .{ .assignment = .{ .target = target, .op = .assign, .value = value } });
            try self.expectSemicolonAfter(item);
            return item;
        }
        return self.parseStmt();
    }

    /// `expr { … }` with the `{` at the cursor: the block's optional `|params|`
    /// header, then its items. The group is a function boundary — settling may
    /// yet make it a closure body.
    fn parseJuxtaposition(self: *Parser, head: *Node) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        try self.expect(.l_brace);
        var params: []const ast.Param = &.{};
        var has_header = false;
        if (self.tokens.tag(self.tok) == .pipe) {
            has_header = true;
            self.advance();
            const param_list = try self.parseParamsUntil(.pipe);
            if (param_list.is_c_variadic) {
                return self.failAt(param_list.tail_span, "C-variadic function pointers use '(fixed, ..) -> R abi(.c)'; Closure values carry an sx environment");
            }
            params = param_list.params;
        }
        const block = blk: {
            const boundary = self.beginFunctionBoundary();
            defer self.endFunctionBoundary(boundary);
            break :blk try self.parseBraceBody(start, true);
        };
        const node = try self.createNode(head.span.start, .{ .juxtaposition = .{
            .expr = head,
            .block = block,
            .params = params,
            .type_params = try self.collectTypeParams(params),
            .has_header = has_header,
        } });
        node.span.end = block.span.end;
        return node;
    }

    /// Whether the `{` at the cursor attaches to `expr`. A head that owns its
    /// own brace group never juxtaposes, and a juxtaposition does not stack.
    fn juxtaposes(self: *Parser, expr: *const Node) bool {
        switch (expr.data) {
            .if_expr, .match_expr, .while_expr, .for_expr, .block, .juxtaposition, .struct_literal => return false,
            else => {},
        }
        // A header reserves the brace group written at its own depth for the
        // statement body, so a juxtaposition that ends one is parenthesized:
        // `if (Button {}) { … }`.
        const h = self.headerAtCursor() orelse return true;
        if (h.kind != .push_context) return false;
        // `push` takes its body from the LAST group, so brace shape splits
        // `push Context { a = x } { body }` from `push ctx { body }`.
        if (!self.braceLooksLikeAggregateBody()) return false;
        return !(self.braceIsEmpty() and expr.data == .field_access);
    }

    /// The header whose reservation covers the token at the cursor: null once
    /// the cursor sits inside a group opened after the header began.
    fn headerAtCursor(self: *const Parser) ?Header {
        const h = self.header orelse return null;
        return if (self.tokens.depth(self.tok) == h.depth) h else null;
    }

    /// Consume the terminator after an expression: the written `;`, or one of
    /// the positions that ends the expression on its own — before the `}` that
    /// closes the enclosing block, or at the end of the file. A block-form
    /// expression ends at its own `}` and never takes one.
    fn expectSemicolonAfter(self: *Parser, expr: *Node) anyerror!void {
        const block_form = switch (expr.data) {
            .if_expr => |ie| !ie.is_inline,
            .match_expr, .while_expr, .for_expr, .block, .jni_env_block => true,
            else => false,
        };
        if (self.tokens.tag(self.tok) == .semicolon) {
            self.advance();
            return;
        }
        // Inside a juxtaposition's brace group, `,` separates items — the group
        // is an aggregate body or a statement list, and only types tell which.
        if (self.comma_separates_items and self.tokens.tag(self.tok) == .comma) {
            self.advance();
            return;
        }
        if (block_form or self.tokens.tag(self.tok) == .r_brace or self.tokens.tag(self.tok) == .eof) return;
        try self.expect(.semicolon); // emits "expected ;"
    }

    /// End an EXPRESSION statement: consume its terminator and mark the
    /// statement as carrying a value, which the enclosing block hands to
    /// whatever position demands one — `;` separates statements and decides
    /// nothing about the value.
    fn endExprStatement(self: *Parser, expr: *Node) anyerror!void {
        try self.expectSemicolonAfter(expr);
        self.last_stmt_produces_value = true;
    }

    /// End a DECLARATION at its initializer's terminator. A declaration is
    /// never its block's value, so this also clears the mark a block inside
    /// that initializer left behind.
    fn endDeclaration(self: *Parser, value: *Node) anyerror!void {
        try self.expectSemicolonAfter(value);
        self.last_stmt_produces_value = false;
    }

    pub fn parseStmt(self: *Parser) anyerror!*Node {
        // Default: a statement carries no value unless `expectSemicolonAfter`
        // marks it an expression statement. Non-expression statements (decls,
        // return/raise, break/continue, defer/onfail) never set it, so they
        // correctly leave the enclosing block value-less.
        self.last_stmt_produces_value = false;
        if (self.tokens.tag(self.tok) == .pipe) {
            return self.fail("a closure literal cannot open a statement — bind it (`f := |x| …`) or pass it as an argument");
        }
        // `@error("msg");` — compile-time diagnostic (fires when reached in live code).
        if (self.isErrorContractCall()) {
            return self.parseErrorDirective();
        }
        // `#context_extend` is a top-level-only directive: the Context is
        // assembled once per program, so a function-local declaration is
        // meaningless — reject it here with a placement error rather than
        // letting it fall through to a generic expression-parse failure. A
        // MODULE-SCOPE expansion body is top level, though: its statements
        // become module-scope declarations, and a branch that declares a
        // Context field is exactly what the expansion scheduler weighs.
        if (self.tokens.tag(self.tok) == .hash_context_extend) {
            if (!self.in_module_expansion) {
                return self.fail("'#context_extend' is only allowed at top level (module scope)");
            }
            return self.parseContextExtend(self.tokens.start(self.tok));
        }
        // `impl Protocol for T { … }` inside a MODULE-SCOPE expansion body is an
        // ordinary module-scope declaration that the flatten pass surfaces to
        // the top level (comptime-expanded conformance). A bare `impl` followed
        // by a binding operator is the ordinary name.
        if (self.tokens.tag(self.tok) == .kw_impl and self.in_module_expansion and self.peekNext() == .identifier) {
            return self.parseImplBlock(self.tokens.start(self.tok));
        }
        // `private` on a statement: legal only inside a MODULE-SCOPE expansion
        // body, whose statements become top-level declarations after comptime
        // flattening. Anywhere else (function/method/lambda bodies) the
        // declaration is a local — visibility does not apply.
        if (self.tokens.tag(self.tok) == .kw_private) {
            if (!self.in_module_expansion) {
                return self.fail("'private' is only allowed on module-scope declarations");
            }
            self.advance();
            if (!self.isIdentLike() and self.tokens.tag(self.tok) != .kw_Self) {
                return self.fail("expected a declaration name after 'private'");
            }
            const decl_start = self.tokens.start(self.tok);
            const decl_name = self.tokens.slice(self.tok);
            const decl_name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
            const decl_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            self.advance();
            const node = switch (self.tokens.tag(self.tok)) {
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
                    try self.endDeclaration(value);
                    break :blk try self.createNode(decl_start, .{ .var_decl = .{ .name = decl_name, .name_span = decl_name_span, .type_annotation = null, .value = value, .is_raw = decl_is_raw } });
                },
                else => return self.fail("expected '::', ':=', or ':' after the 'private' declaration name"),
            };
            node.visibility = .private;
            return node;
        }
        // Check if this is a declaration (IDENT followed by ::, :=, or : type)
        if (self.isIdentLike()) {
            const saved = self.tok;
            const start = self.tokens.start(self.tok);
            const name = self.tokens.slice(self.tok);
            const name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
            const name_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            self.advance();

            if (self.tokens.tag(self.tok) == .colon_colon) {
                self.advance();
                return self.parseConstBinding(name, name_span, start, name_is_raw);
            }
            if (self.tokens.tag(self.tok) == .colon_equal) {
                self.advance();
                const value = try self.parseExpr();
                try self.endDeclaration(value);
                return try self.createNode(start, .{ .var_decl = .{ .name = name, .name_span = name_span, .type_annotation = null, .value = value, .is_raw = name_is_raw } });
            }
            if (self.tokens.tag(self.tok) == .colon) {
                self.advance();
                return self.parseTypedBinding(name, name_span, start, name_is_raw);
            }

            // Multi-target assignment: ident, expr, ... = expr, expr, ...;
            if (self.tokens.tag(self.tok) == .comma and !self.comma_separates_items) {
                const first_target = try self.createNode(start, .{ .identifier = .{ .name = name, .is_raw = name_is_raw } });
                return try self.parseMultiAssign(first_target, start);
            }

            // Check for assignment operators
            if (assignmentInfo(self.tokens.tag(self.tok))) |op| {
                self.advance();
                const value = try self.parseExpr();
                try self.expectStatementEnd();
                const target = try self.createNode(start, .{ .identifier = .{ .name = name, .is_raw = name_is_raw } });
                return try self.createNode(start, .{ .assignment = .{ .target = target, .op = op, .value = value } });
            }

            // Not a declaration or assignment — backtrack and parse as expression
            self.tok = saved;
        }

        // Return statement: return expr; or return;
        if (self.tokens.tag(self.tok) == .kw_return) {
            try self.rejectInCleanup("return");
            const start = self.tokens.start(self.tok);
            self.advance();
            if (self.atStatementEnd()) {
                // `return` with no value — terminated by its `;`.
                try self.expectStatementEnd();
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
                    const fname = self.tokens.slice(self.tok);
                    self.advance(); // skip name
                    self.advance(); // skip '='
                    const v = try self.parseExpr();
                    try ret_elems.append(self.allocator, .{ .name = fname, .value = v });
                    ret_any_named = true;
                } else {
                    const v = try self.parseExpr();
                    try ret_elems.append(self.allocator, .{ .name = null, .value = v });
                }
                if (self.tokens.tag(self.tok) == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
            try self.expectStatementEnd();
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
        if (self.tokens.tag(self.tok) == .kw_defer) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const saved_defer = self.in_defer_body;
            self.in_defer_body = true;
            defer self.in_defer_body = saved_defer;
            const deferred: *Node = if (self.tokens.tag(self.tok) == .l_brace)
                try self.parseBlock()
            else blk: {
                const e = try self.parseExpr();
                try self.expectStatementEnd();
                break :blk e;
            };
            return try self.createNode(start, .{ .defer_stmt = .{ .expr = deferred } });
        }

        // Raise statement: raise <expr>;
        if (self.tokens.tag(self.tok) == .kw_raise) {
            const start = self.tokens.start(self.tok);
            if (self.in_onfail_body) {
                return self.fail("`raise` is not allowed inside an `onfail` body — an error during cleanup has no propagation target");
            }
            if (self.in_defer_body) {
                return self.fail("`raise` is not allowed inside a `defer` body — an error during cleanup has no propagation target");
            }
            self.advance();
            const tag_expr = try self.parseExpr();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .raise_stmt = .{ .tag = tag_expr } });
        }

        // Onfail statement: `onfail { body }`, `onfail |e| { body }`, `onfail <expr>;`.
        if (self.tokens.tag(self.tok) == .kw_onfail) {
            const start = self.tokens.start(self.tok);
            self.advance();
            var binding: ?[]const u8 = null;
            var binding_span: ?ast.Span = null;
            var binding_is_raw = false;
            if (self.tokens.tag(self.tok) == .identifier and self.peekNext() == .l_brace) {
                return self.fail("the onfail error binding needs pipes: `onfail |e| { ... }`");
            }
            if (self.tokens.tag(self.tok) == .pipe) {
                self.advance();
                if (self.tokens.tag(self.tok) != .identifier) {
                    return self.fail("expected an error binding name in `onfail |e|`");
                }
                binding = self.tokens.slice(self.tok);
                binding_span = .{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
                binding_is_raw = self.tokens.flagsOf(self.tok).is_raw;
                self.advance();
                try self.expect(.pipe);
            }
            const saved_onfail = self.in_onfail_body;
            self.in_onfail_body = true;
            defer self.in_onfail_body = saved_onfail;
            const body: *Node = if (self.tokens.tag(self.tok) == .l_brace)
                try self.parseBlock()
            else blk: {
                const e = try self.parseExpr();
                try self.expectStatementEnd();
                break :blk e;
            };
            return try self.createNode(start, .{ .onfail_stmt = .{ .binding = binding, .binding_span = binding_span, .binding_is_raw = binding_is_raw, .body = body } });
        }

        // Break statement: break;
        if (self.tokens.tag(self.tok) == .kw_break) {
            try self.rejectInCleanup("break");
            const start = self.tokens.start(self.tok);
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .break_expr = {} });
        }

        // Continue statement: continue;
        if (self.tokens.tag(self.tok) == .kw_continue) {
            try self.rejectInCleanup("continue");
            const start = self.tokens.start(self.tok);
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .continue_expr = {} });
        }

        // Insert directive: #insert <expr>;
        if (self.tokens.tag(self.tok) == .hash_insert) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const inner = try self.parseExpr();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .insert_expr = .{ .expr = inner } });
        }

        // `#import "path";` / `#framework "Name";` inside a block body.
        // Only meaningful inside an `inline if OS == ... { ... }` arm —
        // the imports.zig flatten pass surfaces those
        // declarations to the top level before resolution. Anywhere else
        // these nodes survive into lowering and produce a clear error.
        if (self.tokens.tag(self.tok) == .hash_import) {
            const start = self.tokens.start(self.tok);
            self.advance();
            if (self.tokens.tag(self.tok) != .string_literal) {
                return self.fail("expected string path after '#import'");
            }
            const raw = self.tokens.slice(self.tok);
            const path = raw[1 .. raw.len - 1];
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .import_decl = .{ .path = path, .name = null } });
        }
        if (self.tokens.tag(self.tok) == .hash_framework) {
            const start = self.tokens.start(self.tok);
            self.advance();
            if (self.tokens.tag(self.tok) != .string_literal) {
                return self.fail("expected string after '#framework'");
            }
            const raw = self.tokens.slice(self.tok);
            const fw_name = raw[1 .. raw.len - 1];
            self.advance();
            try self.expectStatementEnd();
            return try self.createNode(start, .{ .framework_decl = .{ .name = fw_name } });
        }

        // inline if / inline match — compile-time conditionals
        if (self.tokens.tag(self.tok) == .kw_inline) {
            if (self.peekNext() == .kw_if) {
                self.advance(); // skip 'inline'
                const expr = try self.parseIfExpr(.bit_or);
                expr.data.if_expr.is_comptime = true;
                try self.endExprStatement(expr);
                return expr;
            }
            if (self.peekNext() == .kw_match) {
                self.advance(); // skip 'inline'
                const expr = try self.parseMatchExpr();
                expr.data.match_expr.is_comptime = true;
                try self.endExprStatement(expr);
                return expr;
            }
            if (self.peekNext() == .kw_for) {
                self.advance(); // skip 'inline'
                const expr = try self.parseForExpr();
                expr.data.for_expr.is_inline = true;
                try self.endExprStatement(expr);
                return expr;
            }
        }

        // Block-form if/while/for as statements — parse directly to prevent
        // postfix chaining (e.g. `if cond { ... }.field` being misparsed)
        if (self.tokens.tag(self.tok) == .kw_if) {
            const expr = try self.parseIfExpr(.bit_or);
            try self.endExprStatement(expr);
            return expr;
        }
        if (self.tokens.tag(self.tok) == .kw_match) {
            const expr = try self.parseMatchExpr();
            try self.endExprStatement(expr);
            return expr;
        }
        if (self.tokens.tag(self.tok) == .kw_while) {
            const expr = try self.parsePrimary(.bit_or);
            try self.endExprStatement(expr);
            return expr;
        }
        if (self.tokens.tag(self.tok) == .kw_for) {
            const expr = try self.parsePrimary(.bit_or);
            try self.endExprStatement(expr);
            return expr;
        }
        if (self.tokens.tag(self.tok) == .kw_push) {
            return try self.parsePushStmt();
        }

        // A bare scope block is a statement like the keyword-led forms above:
        // it ends at its `}` and never continues into a postfix chain, so
        // `{ … }` then `.flush()` on the next line is two statements. An
        // EXPRESSION that happens to end in a block — a trailing-block call, an
        // aggregate literal — is a different thing and keeps chaining.
        if (self.tokens.tag(self.tok) == .l_brace) {
            const block = try self.parseBlock();
            try self.endExprStatement(block);
            return block;
        }

        // Expression statement
        const expr = try self.parseExpr();

        // Multi-target assignment: expr, expr, ... = expr, expr, ...;
        if (self.tokens.tag(self.tok) == .comma and !self.comma_separates_items) {
            return try self.parseMultiAssign(expr, expr.span.start);
        }

        // Check for field assignment: expr = value; (e.g. a.b = 1;)
        if (assignmentInfo(self.tokens.tag(self.tok))) |op| {
            self.advance();
            const value = try self.parseExpr();
            try self.expectStatementEnd();
            return try self.createNode(expr.span.start, .{ .assignment = .{ .target = expr, .op = op, .value = value } });
        }

        // Block-form if/match/while/bare blocks don't require trailing semicolon
        try self.endExprStatement(expr);
        return expr;
    }

    // ---- Expression parsing (Pratt / precedence climbing) ----

    /// What a `|` after a completed operand means on this expression spine:
    /// the bitwise-OR infix, or the closer of the `|params|` list whose
    /// default this expression is. `.closer` reaches the default's own Pratt
    /// spine and the last unbracketed child of the productions that carry it;
    /// every other expression starts at `.bit_or` through `parseExpr`.
    const PipeRole = enum { bit_or, closer };

    pub fn parseExpr(self: *Parser) anyerror!*Node {
        return self.parseBinary(Prec.none, .bit_or);
    }

    fn parseExprRole(self: *Parser, pipe: PipeRole) anyerror!*Node {
        return self.parseBinary(Prec.none, pipe);
    }

    fn parseBinary(self: *Parser, min_prec: u8, pipe: PipeRole) anyerror!*Node {
        const lhs = try self.parseUnary(pipe);
        return self.parseBinaryRhs(lhs, min_prec, pipe);
    }

    fn parseBinaryRhs(self: *Parser, initial_lhs: *Node, min_prec: u8, pipe: PipeRole) anyerror!*Node {
        var lhs = initial_lhs;

        while (true) {
            if (pipe == .closer and self.tokens.tag(self.tok) == .pipe) break;

            // Null coalescing: expr ?? default
            if (self.tokens.tag(self.tok) == .question_question and Prec.null_coalesce >= min_prec) {
                self.advance();
                const rhs = try self.parseBinary(Prec.null_coalesce, pipe);
                lhs = try self.createNode(lhs.span.start, .{ .null_coalesce = .{ .lhs = lhs, .rhs = rhs } });
                continue;
            }

            const info = binaryInfo(self.tokens.tag(self.tok)) orelse break;
            if (info.prec < min_prec) break;

            const op = info.op;
            self.advance();

            const rhs = try self.parseBinary(info.prec + 1, pipe);

            // Chained comparison detection: if op is a comparison and the next
            // token is also a comparison at the same precedence, accumulate
            // into a ChainedComparison node.
            if (isComparisonOp(op) and self.atComparison()) {
                var operands = std.ArrayList(*Node).empty;
                var ops = std.ArrayList(ast.BinaryOp.Op).empty;
                try operands.append(self.allocator, lhs);
                try operands.append(self.allocator, rhs);
                try ops.append(self.allocator, op);

                while (self.atComparison()) {
                    const chain_info = binaryInfo(self.tokens.tag(self.tok)) orelse break;
                    self.advance();
                    const chain_rhs = try self.parseBinary(info.prec + 1, pipe);
                    try operands.append(self.allocator, chain_rhs);
                    try ops.append(self.allocator, chain_info.op);
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

    fn parseUnary(self: *Parser, pipe: PipeRole) anyerror!*Node {
        if (self.tokens.tag(self.tok) == .minus_minus) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const operand = try self.parseUnary(pipe);
            return try self.createNode(start, .{ .unary_op = .{ .op = .pre_decrement, .operand = operand } });
        }
        if (self.tokens.tag(self.tok) == .minus) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const operand = try self.parseUnary(pipe);
            return try self.createNode(start, .{ .unary_op = .{ .op = .negate, .operand = operand } });
        }
        if (self.tokens.tag(self.tok) == .bang) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const operand = try self.parseUnary(pipe);
            return try self.createNode(start, .{ .unary_op = .{ .op = .not, .operand = operand } });
        }
        if (self.tokens.tag(self.tok) == .tilde) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const operand = try self.parseUnary(pipe);
            return try self.createNode(start, .{ .unary_op = .{ .op = .bit_not, .operand = operand } });
        }
        if (self.tokens.tag(self.tok) == .kw_xx) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const operand = try self.parseUnary(pipe);
            return try self.createNode(start, .{ .unary_op = .{ .op = .xx, .operand = operand } });
        }
        // Prefix `*` — address-of. One glyph, two sides of the same coin:
        // prefix `*` TAKES a pointer, postfix `.*` FOLLOWS one, and `*T` in
        // a type position is the pointer TYPE. On a Type-valued operand the
        // lowering resolves `*T` to the pointer type (so `size_of(*T)` and
        // Type-arg positions keep working); on a value it is address-of.
        if (self.tokens.tag(self.tok) == .star) {
            const start = self.tokens.start(self.tok);
            self.advance();
            const operand = try self.parseUnary(pipe);
            return try self.createNode(start, .{ .unary_op = .{ .op = .address_of, .operand = operand } });
        }
        // `try X` — failable-attempt prefix. Joins the unary tier (binds
        // tighter than any binary op incl. `or`); right-recursive so prefixes
        // stack by adjacency (`xx try foo()` = `xx (try foo())`). Failability
        // of the operand is a sema check, not a parse-time restriction.
        if (self.tokens.tag(self.tok) == .kw_try) {
            try self.rejectInCleanup("try");
            const start = self.tokens.start(self.tok);
            self.advance();
            const operand = try self.parseUnary(pipe);
            return try self.createNode(start, .{ .try_expr = .{ .operand = operand } });
        }
        // `cast` is not a keyword — `cast(Type, value)` is an ordinary 2-arg
        // call, parsed by parsePostfix like any other.
        return self.parsePostfix(pipe);
    }

    fn parsePostfix(self: *Parser, pipe: PipeRole) anyerror!*Node {
        var expr = try self.parsePrimary(pipe);

        while (true) {
            if (self.tokens.tag(self.tok) == .l_paren and !self.spacedGroupEndsHeader()) {
                self.advance();
                var args = std.ArrayList(*Node).empty;
                while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
                    if (args.items.len > 0) {
                        try self.expect(.comma);
                        if (self.tokens.tag(self.tok) == .r_paren) break;
                    }
                    // Spread operator: ..expr
                    if (self.tokens.tag(self.tok) == .dot_dot) {
                        const spread_start = self.tokens.start(self.tok);
                        self.advance();
                        const operand = try self.parseExpr();
                        try args.append(self.allocator, try self.createNode(spread_start, .{ .spread_expr = .{ .operand = operand } }));
                    } else if (self.isIdentLike() and self.peekNext() == .equal) {
                        // Named argument: `name = value` (specs: Named
                        // Arguments). Unambiguous — assignment is statement-
                        // only, and `==` lexes as one token.
                        const named_start = self.tokens.start(self.tok);
                        const arg_name = self.tokens.slice(self.tok);
                        self.advance(); // name
                        self.advance(); // '='
                        const value = try self.parseExpr();
                        try args.append(self.allocator, try self.createNode(named_start, .{ .named_arg = .{ .name = arg_name, .value = value } }));
                    } else {
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                try self.expect(.r_paren);
                expr = try self.createNode(expr.span.start, .{ .call = .{ .callee = expr, .args = try args.toOwnedSlice(self.allocator) } });
            } else if (self.tokens.tag(self.tok) == .l_brace and self.juxtaposes(expr)) {
                // `expr { … }` — two adjacent expressions. Whether the block
                // constructs an aggregate or fuses as a trailing block is a
                // question for types, so both readings park in one node.
                expr = try self.parseJuxtaposition(expr);
                // Only DOT-led postfix continues the chain past the `}`
                // (`f() { … }.map()`); every other token ends it. Infix
                // continues in `parseBinary`, above this loop.
                if (self.tokens.tag(self.tok) != .dot) break;
            } else if (self.tokens.tag(self.tok) == .dot) {
                self.advance();
                if (self.tokens.tag(self.tok) == .l_paren) {
                    // Postfix cast `expr.(T)`. One type, plus
                    // an optional ALLOCATOR expression for the owning
                    // erasure `expr.(P, alloc)` (protocol targets only —
                    // validated at lowering).
                    self.advance(); // '('
                    const target = try self.parseTypeExpr();
                    var alloc_arg: ?*Node = null;
                    if (self.tokens.tag(self.tok) == .comma) {
                        self.advance(); // ','
                        alloc_arg = try self.parseExpr();
                        if (self.tokens.tag(self.tok) == .comma)
                            return self.fail("a postfix cast takes one type and at most one allocator: '.(T)' or '.(P, alloc)'");
                    }
                    try self.expect(.r_paren);
                    expr = try self.createNode(expr.span.start, .{ .postfix_cast = .{ .operand = expr, .type_expr = target, .alloc_arg = alloc_arg } });
                } else if (self.tokens.tag(self.tok) == .l_brace) {
                    // `T{ fields }.{ stmts }` — self-trailing after a completed
                    // aggregate, binding the value pointer to the header name or
                    // to `self`. It attaches to a juxtaposition (settling copies
                    // it onto the aggregate) or to a `.{ … }` primary.
                    // Separator-dot `Type.{…}` on a type designator is a hard error.
                    if (expr.data == .juxtaposition or expr.data == .struct_literal) {
                        const attached = switch (expr.data) {
                            .juxtaposition => |jx| jx.init_block != null,
                            .struct_literal => |sl| sl.init_block != null,
                            else => unreachable,
                        };
                        if (attached) {
                            return self.fail("a struct literal already has a following block");
                        }
                        const start = self.tokens.start(self.tok);
                        try self.expect(.l_brace);
                        const name = try self.parseSelfBinder();
                        const block = try self.parseBlockBody(start);
                        switch (expr.data) {
                            .juxtaposition => |*jx| {
                                jx.init_block = block;
                                jx.init_block_self = name;
                            },
                            .struct_literal => |*sl| {
                                sl.init_block = block;
                                sl.init_block_self = name;
                            },
                            else => unreachable,
                        }
                        expr.span.end = block.span.end;
                    } else if (isNamedAggregatePrefix(expr)) {
                        return self.failNamedAggregateDot();
                    } else {
                        return self.fail(named_aggregate_dot_msg);
                    }
                } else if (self.tokens.tag(self.tok) == .l_bracket) {
                    // Typed array/vector literal: Type.[elem, ...]
                    self.advance(); // skip '['
                    var elements = std.ArrayList(*Node).empty;
                    while (self.tokens.tag(self.tok) != .r_bracket and self.tokens.tag(self.tok) != .eof) {
                        if (elements.items.len > 0) {
                            try self.expect(.comma);
                            if (self.tokens.tag(self.tok) == .r_bracket) break;
                        }
                        const elem = try self.parseExpr();
                        try elements.append(self.allocator, elem);
                    }
                    try self.expect(.r_bracket);
                    expr = try self.createNode(expr.span.start, .{ .array_literal = .{
                        .elements = try elements.toOwnedSlice(self.allocator),
                        .type_expr = expr,
                    } });
                } else if (self.tokens.tag(self.tok) == .star) {
                    // Dereference: expr.*
                    self.advance();
                    expr = try self.createNode(expr.span.start, .{ .deref_expr = .{ .operand = expr } });
                } else if (self.tokens.tag(self.tok) == .int_literal) {
                    // Numeric field access: tuple.0, tuple.1
                    const field = self.tokens.slice(self.tok);
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
            } else if (self.tokens.tag(self.tok) == .question_dot) {
                // Optional chaining: expr?.field
                self.advance();
                if (self.tokens.tag(self.tok) == .identifier or self.tokens.tag(self.tok).isKeyword()) {
                    const field = self.tokens.slice(self.tok);
                    self.advance();
                    expr = try self.createNode(expr.span.start, .{ .field_access = .{ .object = expr, .field = field, .is_optional = true } });
                } else if (self.tokens.tag(self.tok) == .int_literal) {
                    const field = self.tokens.slice(self.tok);
                    self.advance();
                    expr = try self.createNode(expr.span.start, .{ .field_access = .{ .object = expr, .field = field, .is_optional = true } });
                } else if (self.tokens.tag(self.tok) == .l_paren) {
                    // Optional-chained postfix cast `x?.(T)`: null
                    // propagates, the cast/assertion applies to the
                    // payload; the result is `?T`.
                    self.advance(); // '('
                    const target = try self.parseTypeExpr();
                    if (self.tokens.tag(self.tok) == .comma)
                        return self.fail("a postfix cast '.(T)' takes exactly one type");
                    try self.expect(.r_paren);
                    expr = try self.createNode(expr.span.start, .{ .postfix_cast = .{ .operand = expr, .type_expr = target, .is_optional_chain = true } });
                } else {
                    return self.fail("expected field name after '?.'");
                }
            } else if (self.tokens.tag(self.tok) == .l_bracket) {
                // Index or slice access: expr[expr] or expr[start..end]
                self.advance();
                if (rangeTokenInfo(self.tokens.tag(self.tok))) |rt| {
                    // Prefix form: [..end] / [..=end] / [..] — implicit 0 start
                    // (a start marker applies to it: [<..end] begins at 1).
                    self.advance();
                    if (rt.end_marked and self.tokens.tag(self.tok) == .r_bracket) {
                        return self.fail("a range with an explicit end marker ('..=' / '..<') requires an end expression — the open form is '..'");
                    }
                    const end_expr: ?*ast.Node = if (self.tokens.tag(self.tok) != .r_bracket)
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
                    if (rangeTokenInfo(self.tokens.tag(self.tok))) |rt| {
                        // [start..end] or [start..] — same bound-marker matrix
                        // as the for-header ranges.
                        self.advance();
                        if (rt.end_marked and self.tokens.tag(self.tok) == .r_bracket) {
                            return self.fail("a range with an explicit end marker ('..=' / '..<') requires an end expression — the open form is 'a..'");
                        }
                        const end_expr: ?*ast.Node = if (self.tokens.tag(self.tok) != .r_bracket)
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
            } else if (self.tokens.tag(self.tok) == .bang and !self.tokens.flagsOf(self.tok).newline_left) {
                // Force unwrap: expr! — postfix on the expression's own line.
                // `!` is also the prefix `not`, which is what a `!` opening the
                // line below spells.
                // Only if it's not != (bang_equal would have been lexed as a single token)
                self.advance();
                expr = try self.createNode(expr.span.start, .{ .force_unwrap = .{ .operand = expr } });
            } else if (self.tokens.tag(self.tok) == .kw_catch) {
                // `X catch [|binding|] BODY` — postfix failure handler.
                // Three shapes, disambiguated by peeking after `catch`:
                //   catch { block }            — no binding (braces required)
                //   catch |e| { block }        — binding + block body
                //   catch |e| EXPR             — binding + bare-expression body
                self.advance(); // consume 'catch'
                var binding: ?[]const u8 = null;
                var binding_span: ?ast.Span = null;
                var binding_is_raw = false;
                if (self.tokens.tag(self.tok) == .identifier) {
                    return self.fail("the catch error binding needs pipes: `catch |e| { ... }`");
                }
                if (self.tokens.tag(self.tok) == .pipe) {
                    self.advance();
                    if (self.tokens.tag(self.tok) != .identifier) {
                        return self.fail("expected an error binding name in `catch |e|`");
                    }
                    binding = self.tokens.slice(self.tok);
                    binding_span = .{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
                    binding_is_raw = self.tokens.flagsOf(self.tok).is_raw;
                    self.advance();
                    try self.expect(.pipe);
                }
                const body: *Node = if (self.tokens.tag(self.tok) == .l_brace)
                    try self.parseBlock()
                else if (binding != null)
                    try self.parseExprRole(pipe)
                else
                    return self.fail("`catch` without a binding requires a braced body: `catch { ... }`");
                expr = try self.createNode(expr.span.start, .{ .catch_expr = .{
                    .operand = expr,
                    .binding = binding,
                    .binding_span = binding_span,
                    .binding_is_raw = binding_is_raw,
                    .body = body,
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
        return self.tokens.tag(self.tok) == .identifier and std.mem.eql(u8, self.tokens.slice(self.tok), word);
    }

    /// Inline assembly expression (design §II.2–II.4):
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

        while (self.tokens.tag(self.tok) == .comma) {
            self.advance(); // consume the separating comma
            if (self.tokens.tag(self.tok) == .r_brace) break; // trailing comma

            // `clobbers(.name, .name, …)` clause.
            if (self.isContextualWord("clobbers")) {
                self.advance();
                try self.expect(.l_paren);
                while (true) {
                    try self.expect(.dot);
                    if (self.tokens.tag(self.tok) != .identifier)
                        return self.fail("expected a clobber name after '.' in clobbers(...)");
                    try clobbers.append(self.allocator, self.tokens.slice(self.tok));
                    self.advance();
                    if (self.tokens.tag(self.tok) == .comma) {
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
            if (self.tokens.tag(self.tok) == .l_bracket) {
                self.advance();
                if (self.tokens.tag(self.tok) != .identifier)
                    return self.fail("expected an operand name in '[...]'");
                op_name = self.tokens.slice(self.tok);
                self.advance();
                try self.expect(.r_bracket);
            }
            if (self.tokens.tag(self.tok) != .string_literal)
                return self.fail("expected a \"constraint\" string in asm operand");
            const craw = self.tokens.slice(self.tok);
            const constraint = craw[1 .. craw.len - 1]; // strip quotes
            self.advance();

            var role: ast.AsmOperand.Role = undefined;
            var payload: *Node = undefined;
            if (self.tokens.tag(self.tok) == .arrow) {
                self.advance();
                if (self.tokens.tag(self.tok) == .star) {
                    // `-> *place`: write-through output — an ordinary
                    // address-of expression (a pointer); lowering stores
                    // the asm result through it. The output does NOT join
                    // the result tuple. (A pointer-TYPED value output is
                    // not expressible here — spell it `-> usize` and cast.)
                    role = .out_place;
                    payload = try self.parseUnary(.bit_or);
                } else {
                    role = .out_value;
                    payload = try self.parseTypeExpr();
                }
            } else if (self.tokens.tag(self.tok) == .equal) {
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
        if (self.tokens.tag(self.tok) == .comma) self.advance(); // optional trailing comma
        if (self.tokens.tag(self.tok) != .r_brace) {
            return self.fail("global (top-level) asm takes no operands, inputs, or clobbers — only a template string");
        }
        try self.expect(.r_brace);
        try self.expectStatementEnd();
        return try self.createNode(start, .{ .asm_global = .{ .template = template } });
    }

    fn parsePrimary(self: *Parser, pipe: PipeRole) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        // `@Init` names a constraint, never a value a program builds: there is
        // no `@Init(T){ … }` literal and no `@Init` expression. Every other `@`
        // name is an ordinary type reference here — a declared contract takes
        // an aggregate literal (`@SourceSite{ … }`), and `@Vector(N, T)` is the
        // type an expression such as `vector_lanes(@Vector(3, f32))` names.
        if (self.tokens.tag(self.tok) == .at_identifier) {
            const at_name = self.tokens.slice(self.tok);
            if (contracts.isBoundOnly(at_name)) {
                return self.failFmt(
                    "'{s}' is a compiler-formed type — it has no literal form and cannot be named in an expression",
                    .{at_name},
                );
            }
            if (std.mem.eql(u8, at_name, caller_site_name)) {
                // `@caller` is the call site itself, so it can only be written
                // where a call supplies one: a parameter's default.
                if (!self.in_param_default) {
                    return self.fail("'@caller' is only legal in a parameter's default value: `site: @SourceSite = @caller`");
                }
                self.advance();
                return try self.createNode(start, .{ .caller_site = {} });
            }
            if (std.mem.eql(u8, at_name, contracts.objc_call_head) or
                std.mem.eql(u8, at_name, contracts.jni_call_head) or
                std.mem.eql(u8, at_name, contracts.jni_static_call_head))
            {
                return try self.parseFfiAtCall(start, at_name);
            }
            self.advance();
            return try self.createNode(start, .{ .identifier = .{ .name = at_name } });
        }
        // Pack references in expression position:
        //   `$<pack_name>[<int_literal>]` → `pack_index_type_expr`
        //       (a single Type value)
        //   `$<pack_name>`                 → `comptime_pack_ref`
        //       (the whole pack as a []Type value)
        // Lowering routes each through `pack_arg_types` to either
        // a `const_type(TypeId)` or a `[]Type` aggregate of them.
        if (self.tokens.tag(self.tok) == .dollar) {
            self.advance();
            if (self.tokens.tag(self.tok) != .identifier) {
                return self.fail("expected pack name after '$'");
            }
            const pname = self.tokens.slice(self.tok);
            self.advance();
            if (self.tokens.tag(self.tok) == .l_bracket) {
                self.advance(); // skip '['
                if (self.tokens.tag(self.tok) != .int_literal) {
                    return self.fail("expected integer literal in pack index");
                }
                const idx_text = self.tokens.slice(self.tok);
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
        switch (self.tokens.tag(self.tok)) {
            .int_literal => {
                const text = self.tokens.slice(self.tok);
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
                const text = self.tokens.slice(self.tok);
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
                const raw = self.tokens.slice(self.tok);
                self.advance();
                return try self.createNode(start, .{ .string_literal = .{ .raw = raw[1 .. raw.len - 1] } });
            },
            .raw_string_literal => {
                // #string heredoc — token span is content only, no stripping needed
                const raw = self.tokens.slice(self.tok);
                self.advance();
                return try self.createNode(start, .{ .string_literal = .{ .raw = raw, .is_raw = true } });
            },
            .char_literal => {
                // raw includes the surrounding `'`s; strip them for the inner body.
                const raw = self.tokens.slice(self.tok);
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
                const name = self.tokens.slice(self.tok);
                const is_raw = self.tokens.flagsOf(self.tok).is_raw;
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
            .kw_protocol, .kw_impl, .kw_ufcs => {
                // Contextual keywords used as identifiers in expressions
                const name = self.tokens.slice(self.tok);
                self.advance();
                return try self.createNode(start, .{ .identifier = .{ .name = name } });
            },
            .kw_asm => return self.parseAsmExpr(start),
            .dot => {
                self.advance();
                // Anonymous struct literal: .{ ... }
                if (self.tokens.tag(self.tok) == .l_brace) {
                    return self.parseStructLiteral(null, null, start);
                }
                // Array literal: .[expr, expr, ...]
                if (self.tokens.tag(self.tok) == .l_bracket) {
                    self.advance(); // skip '['
                    var elements = std.ArrayList(*Node).empty;
                    while (self.tokens.tag(self.tok) != .r_bracket and self.tokens.tag(self.tok) != .eof) {
                        if (elements.items.len > 0) {
                            try self.expect(.comma);
                            if (self.tokens.tag(self.tok) == .r_bracket) break;
                        }
                        const elem = try self.parseExpr();
                        try elements.append(self.allocator, elem);
                    }
                    try self.expect(.r_bracket);
                    return try self.createNode(start, .{ .array_literal = .{ .elements = try elements.toOwnedSlice(self.allocator) } });
                }
                // `.( )` is not an aggregate literal: the one aggregate
                // literal is `.{ … }`. The spelling is reserved for the
                // postfix cast.
                if (self.tokens.tag(self.tok) == .l_paren) {
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
            .pipe => return self.parseClosure(start, pipe),
            .l_paren => {
                // Function-type literal: (T1, T2) -> R
                if (self.isFunctionTypeExprAtLParen()) {
                    return try self.parseTypeExpr();
                }
                self.advance(); // skip '('

                // Bare `(...)` is GROUPING ONLY. Tuple VALUES are written
                // `.{ … }` with a `Tuple(…)` annotation, so a named element, an
                // empty group, a leading spread, or a top-level comma is an error.
                if (self.tokens.tag(self.tok) == .identifier and self.peekNext() == .colon) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)");
                }
                if (self.tokens.tag(self.tok) == .r_paren) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)");
                }
                if (self.tokens.tag(self.tok) == .dot_dot) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)");
                }

                const first = try self.parseExpr();

                // A top-level comma is an error — tuples need the annotated form.
                if (self.tokens.tag(self.tok) == .comma) {
                    return self.fail("tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)");
                }

                // No comma → grouping
                try self.expect(.r_paren);
                return first;
            },
            .kw_f32, .kw_f64, .kw_Type => {
                // Type keyword used as expression (for type aliases: SOME_TYPE :: f64;)
                const name = self.tokens.slice(self.tok);
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
                return self.parseIfExpr(pipe);
            },
            .kw_match => {
                return self.parseMatchExpr();
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
                // Whether a value follows is the same question a
                // statement-position `return` asks.
                const value = if (self.atStatementEnd())
                    null
                else
                    try self.parseExprRole(pipe);
                return try self.createNode(start, .{ .return_stmt = .{ .value = value } });
            },
            .l_bracket, .question => {
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
                const inner = try self.parseExprRole(pipe);
                return try self.createNode(start, .{ .comptime_expr = .{ .expr = inner } });
            },

            // `error` in expression position is the head of a tag literal
            // `error.X` (parsed as a field access); sema gives it meaning.
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

    fn parseFfiAtCall(self: *Parser, start: u32, at_name: []const u8) anyerror!*Node {
        const kind: ast.FfiIntrinsicKind = if (std.mem.eql(u8, at_name, contracts.objc_call_head))
            .objc_call
        else if (std.mem.eql(u8, at_name, contracts.jni_static_call_head))
            .jni_static_call
        else
            .jni_call;
        self.advance(); // skip @JniCall / @ObjcCall / @JniStaticCall
        try self.expect(.l_paren);
        const ret_type = try self.parseTypeExpr();
        var args = std.ArrayList(*Node).empty;
        while (self.tokens.tag(self.tok) == .comma) {
            self.advance();
            if (self.tokens.tag(self.tok) == .r_paren) break;
            try args.append(self.allocator, try self.parseExpr());
        }
        try self.expect(.r_paren);
        return try self.createNode(start, .{ .ffi_intrinsic_call = .{
            .kind = kind,
            .return_type = ret_type,
            .args = try args.toOwnedSlice(self.allocator),
        } });
    }

    fn parseIfExpr(self: *Parser, pipe: PipeRole) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        self.advance(); // skip 'if'

        // Optional binding: if val := expr { ... }
        // Detect: identifier followed by :=
        if (self.tokens.tag(self.tok) == .identifier and self.peekNext() == .colon_equal) {
            const binding_name = self.tokens.slice(self.tok);
            const binding_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
            const binding_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            self.advance(); // skip identifier
            self.advance(); // skip :=
            const saved_if_cond = self.header;
            self.header = .{ .kind = .if_condition, .depth = self.tokens.depth(self.tok) };
            const source_expr = try self.parseExpr();
            self.header = saved_if_cond;
            const then_branch = try self.parseBlock();
            var else_branch: ?*Node = null;
            if (self.atChainingElse()) {
                self.advance();
                if (self.tokens.tag(self.tok) == .kw_if) {
                    else_branch = try self.parseIfExpr(pipe);
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
        // unconsumed so a chain (`a < b < c`) is collected as one node.
        const saved_if_cond = self.header;
        self.header = .{ .kind = .if_condition, .depth = self.tokens.depth(self.tok) };
        var condition = try self.parseBinary(Prec.shift, .bit_or);

        // All comparisons (< <= > >= == !=) are at the same precedence.
        if (self.atComparison()) {
            var operands = std.ArrayList(*Node).empty;
            var ops = std.ArrayList(ast.BinaryOp.Op).empty;
            try operands.append(self.allocator, condition);

            while (self.atComparison()) {
                const cmp_info = binaryInfo(self.tokens.tag(self.tok)) orelse break;
                self.advance();
                const rhs = try self.parseBinary(Prec.shift, .bit_or);
                try operands.append(self.allocator, rhs);
                try ops.append(self.allocator, cmp_info.op);
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
        condition = try self.parseBinaryRhs(condition, Prec.logical_or, .bit_or);
        self.header = saved_if_cond;

        // Inline form: if cond then expr [else expr]
        if (self.tokens.tag(self.tok) == .kw_then) {
            self.advance();
            const then_branch = try self.parseExprRole(pipe);
            var else_branch: ?*Node = null;
            if (self.atChainingElse()) {
                self.advance();
                else_branch = try self.parseExprRole(pipe);
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
        if (self.atChainingElse()) {
            self.advance();
            if (self.tokens.tag(self.tok) == .kw_if) {
                else_branch = try self.parseIfExpr(pipe);
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
        const start = self.tokens.start(self.tok);
        self.advance(); // skip 'while'

        // Optional binding: while val := expr { ... }
        if (self.tokens.tag(self.tok) == .identifier and self.peekNext() == .colon_equal) {
            const binding_name = self.tokens.slice(self.tok);
            const binding_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
            const binding_is_raw = self.tokens.flagsOf(self.tok).is_raw;
            self.advance(); // skip identifier
            self.advance(); // skip :=
            const saved_hdr = self.header;
            self.header = .{ .kind = .while_condition, .depth = self.tokens.depth(self.tok) };
            const source_expr = try self.parseExpr();
            self.header = saved_hdr;
            const body = try self.parseBlock();
            return try self.createNode(start, .{ .while_expr = .{
                .condition = source_expr,
                .body = body,
                .binding_name = binding_name,
                .binding_span = binding_span,
                .binding_is_raw = binding_is_raw,
            } });
        }

        const saved_hdr = self.header;
        self.header = .{ .kind = .while_condition, .depth = self.tokens.depth(self.tok) };
        const condition = try self.parseExpr();
        self.header = saved_hdr;
        const body = try self.parseBlock();

        return try self.createNode(start, .{ .while_expr = .{
            .condition = condition,
            .body = body,
        } });
    }

    fn parsePushStmt(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        self.advance(); // skip 'push'

        // `push` owns the LAST brace group as its body. Brace shape inside the
        // context expression splits `push Context { a = x } { body }` — one
        // juxtaposition, then the body — from `push ctx { body }`.
        const saved_hdr = self.header;
        self.header = .{ .kind = .push_context, .depth = self.tokens.depth(self.tok) };
        const context_expr = try self.parseExpr();
        self.header = saved_hdr;

        const body = try self.parseBlock();

        return try self.createNode(start, .{ .push_stmt = .{
            .context_expr = context_expr,
            .body = body,
        } });
    }

    fn parseForExpr(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        self.advance(); // skip 'for'

        var iterables = std.ArrayList(ast.ForIterable).empty;
        var captures = std.ArrayList(ast.ForCapture).empty;

        // Captures lead the header, closed by `in`: `for x, *y in xs, ys`.
        // Without `in` the header is iterables alone, so the `*` of
        // `for *p { }` is the prefix operator.
        if (self.forHeaderOpensWithCaptures()) {
            while (true) {
                var cap = ast.ForCapture{ .name = "" };
                if (self.tokens.tag(self.tok) == .star) {
                    cap.by_ref = true;
                    self.advance();
                }
                cap.name = self.tokens.slice(self.tok);
                cap.span = .{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
                cap.is_raw = self.tokens.flagsOf(self.tok).is_raw;
                self.advance();
                if (self.tokens.tag(self.tok) == .colon) {
                    self.advance();
                    cap.type_annotation = try self.parseTypeExpr();
                }
                try captures.append(self.allocator, cap);
                if (self.tokens.tag(self.tok) != .comma) break;
                self.advance();
            }
            try self.expect(.kw_in);
        }

        // Iterables: comma-separated, each a collection expression or a range
        // (`a..b`, `a..=b`, open `a..`).
        const saved_hdr = self.header;
        self.header = .{ .kind = .for_header, .depth = self.tokens.depth(self.tok) };
        while (true) {
            const expr = try self.parseExpr();
            var it = ast.ForIterable{ .expr = expr };
            if (rangeTokenInfo(self.tokens.tag(self.tok))) |rt| {
                it.is_range = true;
                it.start_exclusive = rt.start_exclusive;
                it.end_inclusive = rt.end_inclusive;
                self.advance();
                // End expression — absent for the open range `a..`: the
                // header continues (`,`), the body starts (`{` / `=>`), or a
                // spaced group ends the header.
                const open = switch (self.tokens.tag(self.tok)) {
                    .comma, .l_brace, .fat_arrow => true,
                    .l_paren => self.spacedGroupEndsHeader(),
                    else => false,
                };
                if (open) {
                    if (rt.end_marked) return self.fail("a range with an explicit end marker ('..=' / '..<') requires an end expression — the open form is 'a..'");
                } else {
                    it.range_end = try self.parseExpr();
                }
            }
            try iterables.append(self.allocator, it);
            if (self.tokens.tag(self.tok) != .comma) break;
            self.advance();
        }
        self.header = saved_hdr;

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
        if (self.tokens.tag(self.tok) == .fat_arrow) {
            self.advance();
            // A braced body isolates the mark in `parseBlock`; the arrow body is
            // one statement parsed in place, so it isolates it here.
            const saved_produces = self.last_stmt_produces_value;
            defer self.last_stmt_produces_value = saved_produces;
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

    /// `match <subject> { case … }` — the subject is a header expression, so
    /// the `{` that closes it opens the arm list.
    fn parseMatchExpr(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        self.advance(); // skip 'match'
        const saved_hdr = self.header;
        self.header = .{ .kind = .match_subject, .depth = self.tokens.depth(self.tok) };
        const subject = try self.parseExpr();
        self.header = saved_hdr;
        return self.parseMatchBody(subject, start);
    }

    fn parseMatchBody(self: *Parser, subject: *Node, start_pos: u32) anyerror!*Node {
        try self.expect(.l_brace);
        // An arm body is its own statement list — an arm wrapper always carries
        // the arm's value, so the arms decide nothing about the statement the
        // `match` itself sits in.
        const saved_produces = self.last_stmt_produces_value;
        defer self.last_stmt_produces_value = saved_produces;
        var arms = std.ArrayList(ast.MatchArm).empty;
        while (self.tokens.tag(self.tok) == .kw_case) {
            const arm_start = self.tokens.start(self.tok);
            self.advance(); // skip 'case'
            // Allow keyword tokens (struct, enum, union) as type category names in match arms
            const pattern: *Node = if (self.tokens.tag(self.tok) == .kw_struct or self.tokens.tag(self.tok) == .kw_enum or self.tokens.tag(self.tok) == .kw_union) blk: {
                const name = self.tokens.slice(self.tok);
                self.advance();
                break :blk try self.createNode(arm_start, .{ .identifier = .{ .name = name } });
            } else if (self.isIdentLike() and self.peekNext() == .l_paren)
                // An instantiation spelling names a type in arm position
                // (`case Buffer(f32):`, nested `case Buffer(Buffer(f32)):`).
                // A name followed by `(` can only be a parameterized type
                // here — the arm value grammar has no call form.
                try self.parseTypeExpr()
            else
                try self.parsePrimary(.bit_or); // .variant
            try self.expect(.colon);

            // Optional payload capture: `|ident|`. An arm with no payload
            // carries no pipes (`case .none: 0`).
            var capture: ?[]const u8 = null;
            var capture_span: ?ast.Span = null;
            var capture_is_raw = false;
            if (self.tokens.tag(self.tok) == .pipe) {
                self.advance(); // '|'
                if (self.tokens.tag(self.tok) != .identifier) {
                    return self.fail("expected a payload binding name in `case .variant: |name|`");
                }
                capture = self.tokens.slice(self.tok);
                capture_span = .{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
                capture_is_raw = self.tokens.flagsOf(self.tok).is_raw;
                self.advance(); // ident
                try self.expect(.pipe);
            }

            if (self.tokens.tag(self.tok) == .kw_break) {
                self.advance();
                // The arm's `break` ends like a `break` statement anywhere.
                try self.expectStatementEnd();
                const body = try self.createNode(arm_start, .{ .block = .{ .stmts = &.{} } });
                try arms.append(self.allocator, .{ .pattern = pattern, .body = body, .is_break = true, .capture = capture, .capture_span = capture_span, .capture_is_raw = capture_is_raw });
            } else {
                const stmts_start = self.tokens.start(self.tok);
                var stmts = std.ArrayList(*Node).empty;
                while (self.tokens.tag(self.tok) != .kw_case and self.tokens.tag(self.tok) != .kw_else and self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
                    try stmts.append(self.allocator, try self.parseStmt());
                }
                // The wrapper yields its last statement's value — which, for a
                // braced-block arm body, is that inner block's own value.
                const body = try self.createNode(stmts_start, .{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator), .produces_value = true } });
                try arms.append(self.allocator, .{ .pattern = pattern, .body = body, .is_break = false, .capture = capture, .capture_span = capture_span, .capture_is_raw = capture_is_raw });
            }
        }
        // Optional else arm (default)
        if (self.tokens.tag(self.tok) == .kw_else) {
            const else_start = self.tokens.start(self.tok);
            self.advance(); // skip 'else'
            try self.expect(.colon);
            var stmts = std.ArrayList(*Node).empty;
            while (self.tokens.tag(self.tok) != .r_brace and self.tokens.tag(self.tok) != .eof) {
                try stmts.append(self.allocator, try self.parseStmt());
            }
            const body = try self.createNode(else_start, .{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator), .produces_value = true } });
            try arms.append(self.allocator, .{ .pattern = null, .body = body, .is_break = false });
        }
        try self.expect(.r_brace);
        return try self.createNode(start_pos, .{ .match_expr = .{ .subject = subject, .arms = try arms.toOwnedSlice(self.allocator) } });
    }

    fn isErrorContractCall(self: *Parser) bool {
        return self.tokens.tag(self.tok) == .at_identifier and
            std.mem.eql(u8, self.tokens.slice(self.tok), "@error") and
            self.peekTag(1) == .l_paren;
    }

    /// `@error("message");` — a compile-time diagnostic. Usable as a statement or
    /// a top-level item; the message fires only when the node reaches live decls
    /// (the flatten pass drops it in non-taken `inline if` arms).
    fn parseErrorDirective(self: *Parser) anyerror!*Node {
        const start = self.tokens.start(self.tok);
        self.advance(); // skip '@error'
        try self.expect(.l_paren);
        if (self.tokens.tag(self.tok) != .string_literal) {
            return self.fail("expected a string message in '@error(...)'");
        }
        const raw = self.tokens.slice(self.tok);
        const message = raw[1 .. raw.len - 1];
        self.advance();
        try self.expect(.r_paren);
        try self.expectStatementEnd();
        return try self.createNode(start, .{ .error_directive = .{ .message = message } });
    }

    /// Parse `#context_extend name: Type = default;` — a field of the
    /// program's assembled Context. `current` is the directive token.
    fn parseContextExtend(self: *Parser, start: u32) anyerror!*Node {
        self.advance();
        if (!self.isIdentLike()) {
            return self.fail("expected field name after '#context_extend'");
        }
        const field_name = self.tokens.slice(self.tok);
        const field_name_span = ast.Span{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) };
        self.advance();
        try self.expect(.colon);
        const type_node = try self.parseTypeExpr();
        var default_node: ?*Node = null;
        if (self.tokens.tag(self.tok) == .equal) {
            self.advance();
            default_node = try self.parseExpr();
        }
        try self.expectStatementEnd();
        return try self.createNode(start, .{ .context_extend_decl = .{
            .name = field_name,
            .name_span = field_name_span,
            .type_expr = type_node,
            .default_expr = default_node,
        } });
    }

    /// A token that can only begin a VALUE literal, never a type. Used to give
    /// `Tuple(...)` a precise lowering-time "element is not a type" diagnostic
    /// (instead of a generic parse error) when a literal is supplied as a tuple
    /// element.
    fn atValueLiteral(self: *Parser) bool {
        switch (self.tokens.tag(self.tok)) {
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

    /// The exact token pair `Tuple`+`(` / `Closure`+`(` that opens a type
    /// constructor. A backtick-raw spelling is an ordinary identifier.
    fn atTypeConstructorHead(self: *Parser) bool {
        if (self.tokens.tag(self.tok) != .identifier) return false;
        if (self.tokens.flagsOf(self.tok).is_raw) return false;
        if (self.peekNext() != .l_paren) return false;
        const name = self.tokens.slice(self.tok);
        return std.mem.eql(u8, name, "Tuple") or std.mem.eql(u8, name, "Closure");
    }

    /// Closure type body: `(params...) -> R` after a `Closure` head; `current`
    /// must be at the opening `(`.
    ///   Variadic-pack trailing form: `Closure(Prefix..., ..$pack) -> R` binds
    ///   `pack` to a heterogeneous comptime type list at impl match time.
    fn parseClosureTypeBody(self: *Parser, start: u32) anyerror!*Node {
        self.advance(); // skip '('
        var param_types = std.ArrayList(*Node).empty;
        var param_names = std.ArrayList(?[]const u8).empty;
        var has_names = false;
        var pack_name: ?[]const u8 = null;
        var pack_projection: ?[]const u8 = null;
        while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
            if (param_types.items.len > 0) {
                try self.expect(.comma);
                if (self.tokens.tag(self.tok) == .r_paren) break; // trailing comma ok
            }
            // Trailing pack marker: `..$name` or `..pack.Arg` (terminal only).
            if (self.tokens.tag(self.tok) == .dot_dot) {
                self.advance(); // skip '..'
                if (self.tokens.tag(self.tok) == .dollar) self.advance(); // optional sigil
                if (!self.isIdentLike()) {
                    return self.fail("expected pack name after '..' in Closure type");
                }
                pack_name = self.tokens.slice(self.tok);
                self.advance();
                // Optional projection: `..sources.T` picks a type-arg per element.
                if (self.tokens.tag(self.tok) == .dot) {
                    self.advance(); // skip '.'
                    if (!self.isIdentLike()) {
                        return self.fail("expected projection name after '.' in Closure pack");
                    }
                    pack_projection = self.tokens.slice(self.tok);
                    self.advance();
                }
                // Pack must be the LAST item — only `)` accepted next.
                if (self.tokens.tag(self.tok) != .r_paren) {
                    return self.fail("variadic pack must be the last parameter in Closure type");
                }
                break;
            }
            // Check for optional param name: `name: Type`
            if (self.tokens.tag(self.tok) == .identifier and self.peekNext() == .colon) {
                const pname = self.tokens.slice(self.tok);
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
        if (self.tokens.tag(self.tok) == .arrow) {
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

    /// Tuple type body after a `Tuple` head; `current` must be at the opening
    /// `(`. `Tuple(A, B)` / `Tuple(T)` / `Tuple()` / named `Tuple(x: A, y: B)` /
    /// pack `Tuple(..Ts)` / `Tuple(..F(Ts))` lower to the SAME `tuple_type_expr`
    /// the inline `(A, B)` / `(x: A, y: B)` / `(..Ts)` forms produce. Unlike
    /// `Closure`, a trailing `->` is REJECTED.
    fn parseTupleTypeBody(self: *Parser, start: u32) anyerror!*Node {
        self.advance(); // skip '('
        var field_types = std.ArrayList(*Node).empty;
        var field_name_opt = std.ArrayList(?[]const u8).empty;
        var has_names = false;
        while (self.tokens.tag(self.tok) != .r_paren and self.tokens.tag(self.tok) != .eof) {
            if (field_types.items.len > 0) {
                try self.expect(.comma);
                if (self.tokens.tag(self.tok) == .r_paren) break; // trailing comma ok
            }
            // Pack-spread field: `Tuple(..Ts)` / `Tuple(..F(Ts))` /
            // `Tuple(..Ts.Arg)`. Reuses `spread_expr` (same machinery as
            // the inline tuple-type and Closure pack paths).
            if (self.tokens.tag(self.tok) == .dot_dot) {
                const sp_start = self.tokens.start(self.tok);
                self.advance(); // skip '..'
                const operand = try self.parseTypeExpr();
                try field_name_opt.append(self.allocator, null);
                try field_types.append(self.allocator, try self.createNode(sp_start, .{ .spread_expr = .{ .operand = operand } }));
                continue;
            }
            // Named field: `name: Type` (keeps `:`).
            if (self.isIdentLike() and self.peekNext() == .colon) {
                const fname = self.tokens.slice(self.tok);
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
            if (self.atValueLiteral()) {
                // A leading `+` on a signed literal (`Tuple(i32, +1)`) has no
                // unary-op parse; consume it so the number parses as a bare
                // value literal. `parseUnary` handles the `-` case and falls
                // through to `parsePrimary` for an unsigned literal.
                if (self.tokens.tag(self.tok) == .plus) self.advance();
                try field_types.append(self.allocator, try self.parseUnary(.bit_or));
            } else {
                try field_types.append(self.allocator, try self.parseTypeExpr());
            }
        }
        try self.expect(.r_paren);
        // A `Tuple(...)` has NO return type — reject `-> R` loudly rather
        // than silently swallowing it the way `Closure` consumes it.
        if (self.tokens.tag(self.tok) == .arrow) {
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

    /// The tag after the `)` matching the current `(`, or null when no matching
    /// `)` is found before EOF.
    fn peekPastParens(self: *Parser) ?Tag {
        const close = self.tokens.scanBalanced(self.tok, .l_paren, .r_paren) orelse return null;
        return self.tokens.tag(self.tokens.next(close));
    }

    /// Returns true when the current `(` opens a function-type literal
    /// `(T1, T2) -> R` rather than a grouping.
    fn isFunctionTypeExprAtLParen(self: *Parser) bool {
        const close = self.tokens.scanBalanced(self.tok, .l_paren, .r_paren) orelse return false;
        return self.tokens.tag(self.tokens.next(close)) == .arrow;
    }

    /// `|params| body` — the closure literal, parsed where a primary starts.
    /// After a completed operand `|` is bitwise OR, so only this position ever
    /// reaches here; `||` is two `|` tokens around an empty list.
    fn parseClosure(self: *Parser, start: u32, pipe: PipeRole) anyerror!*Node {
        try self.expect(.pipe);
        const param_list = try self.parseParamsUntil(.pipe);
        // A closure carries an sx environment, so it has no C signature to hang
        // a tail on; the C-variadic function pointer is a function TYPE.
        if (param_list.is_c_variadic) {
            return self.failAt(param_list.tail_span, "C-variadic function pointers use '(fixed, ..) -> R abi(.c)'; Closure values carry an sx environment");
        }
        const params = param_list.params;

        var return_type: ?*Node = null;
        if (self.tokens.tag(self.tok) == .arrow) {
            self.advance();
            return_type = try self.parseFnReturnType();
        }

        const boundary = self.beginFunctionBoundary();
        defer self.endFunctionBoundary(boundary);

        const body = if (self.tokens.tag(self.tok) == .l_brace)
            try self.parseBlock()
        else
            try self.parseExprRole(pipe);
        const type_params = try self.collectTypeParams(params);
        return try self.createNode(start, .{ .lambda = .{
            .params = params,
            .return_type = return_type,
            .body = body,
            .type_params = type_params,
        } });
    }

    const FunctionBoundary = struct {
        onfail: bool,
        defer_body: bool,
        module: bool,
    };

    /// A closure or trailing-block body is a function boundary: cleanup-body
    /// flags and module expansion do not apply inside it.
    fn beginFunctionBoundary(self: *Parser) FunctionBoundary {
        const saved: FunctionBoundary = .{
            .onfail = self.in_onfail_body,
            .defer_body = self.in_defer_body,
            .module = self.in_module_expansion,
        };
        self.in_onfail_body = false;
        self.in_defer_body = false;
        self.in_module_expansion = false;
        return saved;
    }

    fn endFunctionBoundary(self: *Parser, saved: FunctionBoundary) void {
        self.in_onfail_body = saved.onfail;
        self.in_defer_body = saved.defer_body;
        self.in_module_expansion = saved.module;
    }

    /// The name a self-trailing block binds the value's pointer to, with the
    /// `{` of `.{ … }` already consumed: the `|name|` header's, or `self`.
    fn parseSelfBinder(self: *Parser) anyerror![]const u8 {
        if (self.tokens.tag(self.tok) != .pipe) return "self";
        self.advance();
        if (self.tokens.tag(self.tok) != .identifier or self.peekNext() != .pipe) {
            return self.fail("a self-trailing block's header binds one name: `.{ |s| … }`");
        }
        const name = self.tokens.slice(self.tok);
        self.advance(); // name
        self.advance(); // '|'
        return name;
    }

    /// Returns true if the current token can be used as an identifier name.
    /// Includes actual identifiers plus contextual keywords that are only
    /// keywords in specific syntactic positions (e.g., `protocol`, `impl`).
    fn isIdentLike(self: *const Parser) bool {
        return switch (self.tokens.tag(self.tok)) {
            .identifier, .kw_protocol, .kw_impl, .kw_ufcs => true,
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
        const saved = self.tok;
        defer self.tok = saved;
        const paren_close = self.tokens.scanBalanced(self.tok, .l_paren, .r_paren) orelse return false;
        self.tok = self.tokens.next(paren_close); // skip past ')'
        if (self.tokens.tag(self.tok) != .arrow) return false;
        self.advance(); // skip '->'
        while (self.tokens.tag(self.tok) != .eof) {
            // An inline `struct { … }` / `union { … }` / `enum { … }` return
            // type: the brace group after the keyword belongs to the TYPE,
            // not the body — skip it balanced and keep scanning for the real
            // body `{`. The bodyless alias edge still holds:
            // `F :: () -> struct { x: i64; };` resumes the scan at `;`,
            // finds no body, and classifies as a type alias.
            if (self.tokens.tag(self.tok) == .kw_struct or self.tokens.tag(self.tok) == .kw_union or
                self.tokens.tag(self.tok) == .kw_enum)
            {
                self.advance(); // the keyword
                if (self.tokens.tag(self.tok) != .l_brace) return false;
                // On an unterminated type brace group, park at `.eof` so the
                // outer scan ends without finding a body.
                if (self.tokens.scanBalanced(self.tok, .l_brace, .r_brace)) |brace_close| {
                    self.tok = self.tokens.next(brace_close);
                } else {
                    self.tok = self.tokens.last();
                }
                continue;
            }
            if (self.tokens.tag(self.tok) == .fat_arrow) return true;
            if (self.tokens.tag(self.tok) == .l_brace) return true;
            if (self.tokens.tag(self.tok) == .kw_intrinsic) return true;
            if (self.tokens.tag(self.tok) == .hash_get) return true; // `-> R #get => …` is a fn def
            if (self.tokens.tag(self.tok) == .hash_set) return true; // `-> R #set { … }` is a fn def
            // Postfix linkage modifier after the return type: `-> R extern;` /
            // `-> R export { … }` (and `-> R abi(.c) extern`). Marks a fn def.
            if (self.tokens.tag(self.tok) == .kw_extern or self.tokens.tag(self.tok) == .kw_export) return true;
            if (self.tokens.tag(self.tok) == .identifier or self.tokens.tag(self.tok).isTypeKeyword() or
                // `abi(...)` states a convention, not a body: `-> R abi(.c) { … }`
                // is a definition and `-> R abi(.c);` a function-type alias, so
                // the scan reads through the annotation to whatever follows.
                // (Its `(`/`.`/name/`)` tokens are already skipped below.)
                self.tokens.tag(self.tok) == .kw_abi or
                // A compiler-formed `@Init(T)` is a type spelling like any
                // other here: skipping it keeps the scan on course to the body
                // brace, so the decl is classified as a fn DEF and the
                // return-position refusal lands on the return type.
                self.tokens.tag(self.tok) == .at_identifier or
                self.tokens.tag(self.tok) == .dot or self.tokens.tag(self.tok) == .dollar or
                self.tokens.tag(self.tok) == .l_bracket or self.tokens.tag(self.tok) == .r_bracket or
                self.tokens.tag(self.tok) == .l_paren or self.tokens.tag(self.tok) == .r_paren or
                self.tokens.tag(self.tok) == .comma or self.tokens.tag(self.tok) == .int_literal or
                // Arithmetic operators appear in a const-expression dimension /
                // lane / value-param in a return type: `-> [N + 1]f32`,
                // `-> @Vector(N + 1, f32)`. They must be skipped while scanning
                // for the body brace, else the decl is misread as a bodyless
                // function-type alias and the `{` body errors as "expected ';'".
                // (`.star` doubles as the pointer sigil and is already listed.)
                self.tokens.tag(self.tok) == .star or self.tokens.tag(self.tok) == .slash or
                self.tokens.tag(self.tok) == .percent or self.tokens.tag(self.tok) == .plus or
                self.tokens.tag(self.tok) == .minus or self.tokens.tag(self.tok) == .question or
                self.tokens.tag(self.tok) == .bang or
                // A named multi-return slot DEFAULT (`-> (sum: i32 = 0, …)`):
                // skip the `=` and the value expression's literal tokens so the
                // scan keeps going to the body `{`, instead of misreading the
                // decl as a bodyless function-type alias.
                self.tokens.tag(self.tok) == .equal or self.tokens.tag(self.tok) == .float_literal or
                self.tokens.tag(self.tok) == .string_literal or self.tokens.tag(self.tok) == .char_literal or
                self.tokens.tag(self.tok) == .kw_true or self.tokens.tag(self.tok) == .kw_false or
                self.tokens.tag(self.tok) == .colon or self.tokens.tag(self.tok) == .arrow)
            {
                self.advance();
            } else break;
        }
        return false;
    }

    /// Optional ABI / calling-convention annotation `abi(.c)` / `abi(.zig)` /
    /// `abi(.naked)` in the postfix slot before `extern`/`export`. `.default` when
    /// absent.
    fn parseOptionalAbi(self: *Parser) anyerror!ast.ABI {
        if (self.tokens.tag(self.tok) != .kw_abi) return .default;
        self.advance();
        try self.expect(.l_paren);
        try self.expect(.dot);
        if (self.tokens.tag(self.tok) != .identifier)
            return self.fail("expected ABI name ('.c' or '.naked') after '.'");
        const abi_name = self.tokens.slice(self.tok);
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

    const LinkageTail = struct {
        lib: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };

    /// The `[LIB] ["csym"]` tail after `extern` / `export`. Both slots are
    /// optional, and the declaration's `;` is what closes the tail.
    fn parseLinkageTail(self: *Parser, admits_symbol: bool) LinkageTail {
        var tail: LinkageTail = .{};
        if (self.tokens.tag(self.tok) == .identifier) {
            tail.lib = self.tokens.slice(self.tok);
            self.advance();
        }
        if (!admits_symbol) return tail;
        if (self.tokens.tag(self.tok) == .string_literal) {
            const raw = self.tokens.slice(self.tok);
            tail.name = raw[1 .. raw.len - 1];
            self.advance();
        }
        return tail;
    }

    /// Postfix linkage modifier in the slot after `abi(...)`:
    /// `extern` (import) or `export` (define + expose), or `.none` if neither.
    fn parseOptionalExternExport(self: *Parser) ast.ExternExportModifier {
        switch (self.tokens.tag(self.tok)) {
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

    fn assignmentInfo(tag: Tag) ?ast.Assignment.Op {
        return switch (tag) {
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
            .int_literal,
            .float_literal,
            .string_literal,
            .raw_string_literal,
            .char_literal,
            .identifier,
            .at_identifier,
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
            .kw_onfail,
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
            .kw_protocol,
            .kw_impl,
            .kw_Self,
            .kw_inline,
            .kw_abi,
            .kw_extern,
            .kw_export,
            .kw_asm,
            .kw_intrinsic,
            .kw_private,
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
            .equal_equal,
            .bang,
            .bang_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            .percent,
            .ampersand,
            .pipe,
            .caret,
            .question,
            .question_question,
            .question_dot,
            .tilde,
            .less_less,
            .greater_greater,
            .l_paren,
            .r_paren,
            .l_brace,
            .r_brace,
            .l_bracket,
            .r_bracket,
            .arrow,
            .fat_arrow,
            .hash_run,
            .hash_error,
            .hash_import,
            .hash_insert,
            .hash_library,
            .hash_framework,
            .hash_using,
            .hash_include,
            .hash_source,
            .hash_define,
            .hash_flags,
            .hash_identity,
            .hash_get,
            .hash_set,
            .hash_context_extend,
            .triple_minus,
            .minus_minus,
            .eof,
            .invalid,
            => null,
        };
    }

    fn parseMultiAssign(self: *Parser, first_target: *Node, start: u32) !*Node {
        var targets = std.ArrayList(*Node).empty;
        try targets.append(self.allocator, first_target);

        // Consume remaining targets separated by commas
        while (self.tokens.tag(self.tok) == .comma) {
            self.advance();
            const target = try self.parseExpr();
            try targets.append(self.allocator, target);
        }

        // Destructuring declaration: a, b := expr;
        if (self.tokens.tag(self.tok) == .colon_equal) {
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
            try self.endDeclaration(value);
            return try self.createNode(start, .{ .destructure_decl = .{
                .names = try names.toOwnedSlice(self.allocator),
                .name_spans = try name_spans.toOwnedSlice(self.allocator),
                .name_is_raw = try name_is_raw.toOwnedSlice(self.allocator),
                .value = value,
            } });
        }

        // Multi-target assignment: only plain '=' is allowed
        if (self.tokens.tag(self.tok) != .equal) {
            return self.fail("multi-target assignment requires '=' or ':='");
        }
        self.advance();

        // Parse RHS values separated by commas
        var values = std.ArrayList(*Node).empty;
        const first_val = try self.parseExpr();
        try values.append(self.allocator, first_val);
        while (self.tokens.tag(self.tok) == .comma) {
            self.advance();
            const val = try self.parseExpr();
            try values.append(self.allocator, val);
        }

        if (targets.items.len != values.items.len) {
            return self.fail("multi-target assignment: target count does not match value count");
        }

        try self.expectStatementEnd();

        return try self.createNode(start, .{ .multi_assign = .{
            .targets = try targets.toOwnedSlice(self.allocator),
            .values = try values.toOwnedSlice(self.allocator),
        } });
    }

    const Prec = struct {
        const none: u8 = 0;
        const null_coalesce: u8 = 1; // ??
        const logical_or: u8 = 2; // or
        const logical_and: u8 = 3; // and
        const bit_or: u8 = 4; // |
        const bit_xor: u8 = 5; // ^
        const bit_and: u8 = 6; // &
        const comparison: u8 = 7; // == != < <= > >= in
        const shift: u8 = 8; // << >>
        const additive: u8 = 9; // + -
        const multiplicative: u8 = 10; // * / %
    };

    const BinaryInfo = struct { prec: u8, op: ast.BinaryOp.Op, comparison: bool };

    /// One lookup per infix token: precedence tier, AST operator, and whether
    /// the token joins a comparison chain (`in` shares the tier but never
    /// chains).
    fn binaryInfo(tag: Tag) ?BinaryInfo {
        return switch (tag) {
            .kw_or => .{ .prec = Prec.logical_or, .op = .or_op, .comparison = false },
            .kw_and => .{ .prec = Prec.logical_and, .op = .and_op, .comparison = false },
            .pipe => .{ .prec = Prec.bit_or, .op = .bit_or, .comparison = false },
            .caret => .{ .prec = Prec.bit_xor, .op = .bit_xor, .comparison = false },
            .ampersand => .{ .prec = Prec.bit_and, .op = .bit_and, .comparison = false },
            .equal_equal => .{ .prec = Prec.comparison, .op = .eq, .comparison = true },
            .bang_equal => .{ .prec = Prec.comparison, .op = .neq, .comparison = true },
            .less => .{ .prec = Prec.comparison, .op = .lt, .comparison = true },
            .less_equal => .{ .prec = Prec.comparison, .op = .lte, .comparison = true },
            .greater => .{ .prec = Prec.comparison, .op = .gt, .comparison = true },
            .greater_equal => .{ .prec = Prec.comparison, .op = .gte, .comparison = true },
            .kw_in => .{ .prec = Prec.comparison, .op = .in_op, .comparison = false },
            .less_less => .{ .prec = Prec.shift, .op = .shl, .comparison = false },
            .greater_greater => .{ .prec = Prec.shift, .op = .shr, .comparison = false },
            .plus => .{ .prec = Prec.additive, .op = .add, .comparison = false },
            .minus => .{ .prec = Prec.additive, .op = .sub, .comparison = false },
            .star => .{ .prec = Prec.multiplicative, .op = .mul, .comparison = false },
            .slash => .{ .prec = Prec.multiplicative, .op = .div, .comparison = false },
            .percent => .{ .prec = Prec.multiplicative, .op = .mod, .comparison = false },
            .int_literal,
            .float_literal,
            .string_literal,
            .raw_string_literal,
            .char_literal,
            .identifier,
            .at_identifier,
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
            .kw_onfail,
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
            .kw_Type,
            .kw_null,
            .kw_push,
            .kw_ufcs,
            .kw_protocol,
            .kw_impl,
            .kw_Self,
            .kw_inline,
            .kw_abi,
            .kw_extern,
            .kw_export,
            .kw_asm,
            .kw_intrinsic,
            .kw_private,
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
            .equal,
            .bang,
            .plus_equal,
            .minus_equal,
            .star_equal,
            .slash_equal,
            .percent_equal,
            .ampersand_equal,
            .pipe_equal,
            .caret_equal,
            .question,
            .question_question,
            .question_dot,
            .tilde,
            .less_less_equal,
            .greater_greater_equal,
            .l_paren,
            .r_paren,
            .l_brace,
            .r_brace,
            .l_bracket,
            .r_bracket,
            .arrow,
            .fat_arrow,
            .hash_run,
            .hash_error,
            .hash_import,
            .hash_insert,
            .hash_library,
            .hash_framework,
            .hash_using,
            .hash_include,
            .hash_source,
            .hash_define,
            .hash_flags,
            .hash_identity,
            .hash_get,
            .hash_set,
            .hash_context_extend,
            .triple_minus,
            .minus_minus,
            .eof,
            .invalid,
            => null,
        };
    }

    fn isComparisonOp(op: ast.BinaryOp.Op) bool {
        return switch (op) {
            .lt, .lte, .gt, .gte, .eq, .neq => true,
            else => false,
        };
    }

    fn atComparison(self: *const Parser) bool {
        const info = binaryInfo(self.tokens.tag(self.tok)) orelse return false;
        return info.comparison;
    }

    /// The head shapes a separator-dot `Type.{…}` could have been written for,
    /// which get the fix-it to the compact spelling rather than the generic
    /// message.
    fn isNamedAggregatePrefix(expr: *const Node) bool {
        return switch (expr.data) {
            // Enum/variant heads (`.key{…}`, `Ev.key{…}`) share the compact
            // aggregate body; contextual `.{…}` still starts with a leading dot alone.
            .identifier, .field_access, .parameterized_type_expr, .call, .type_expr, .tuple_type_expr, .enum_literal => true,
            else => false,
        };
    }

    fn braceIsEmpty(self: *Parser) bool {
        if (self.tokens.tag(self.tok) != .l_brace) return false;
        return self.tokens.tag(self.tokens.next(self.tok)) == .r_brace;
    }

    /// The markers a brace group carries at its OWN top level — what tells a
    /// construction body (field inits, element commas) from a `push` body.
    const BraceShape = struct {
        saw_token: bool = false,
        semi: bool = false,
        stmt_kw: bool = false,
        comma: bool = false,
        field_eq: bool = false,
        colon_eq: bool = false,
    };

    /// Scan the brace group at `current` on a throwaway lexer. Nesting counts
    /// parens and brackets alongside braces, so the `,` separating call
    /// arguments, the `=` naming one, and anything else inside a nested group
    /// belongs to that group rather than to the brace body.
    fn scanBraceShape(self: *Parser) BraceShape {
        var shape = BraceShape{};
        var i = self.tokens.next(self.tok);
        var depth: u32 = 1;
        var prev_was_name = false;
        while (true) : (i = self.tokens.next(i)) {
            const t = self.tokens.tag(i);
            if (t == .eof) break;
            if (t == .r_brace) {
                depth -= 1;
                if (depth == 0) break;
            }
            shape.saw_token = true;
            const top = depth == 1;
            var names = false;
            switch (t) {
                .l_brace, .l_paren, .l_bracket => depth += 1,
                .r_paren, .r_bracket => if (depth > 1) {
                    depth -= 1;
                },
                .semicolon => shape.semi = shape.semi or top,
                .comma => shape.comma = shape.comma or top,
                // `bound := …` is a statement, never a field init.
                .colon_equal => shape.colon_eq = shape.colon_eq or top,
                .equal => shape.field_eq = shape.field_eq or (top and prev_was_name),
                .kw_return,
                .kw_break,
                .kw_continue,
                .kw_defer,
                .kw_raise,
                .kw_onfail,
                .kw_if,
                .kw_match,
                .kw_for,
                .kw_while,
                .kw_push,
                => shape.stmt_kw = shape.stmt_kw or top,
                // A field label is an identifier; a bare keyword heads a statement.
                .identifier => names = top,
                else => {},
            }
            prev_was_name = names;
        }
        return shape;
    }

    /// Peek whether the brace group at `current` is construction-shaped (fields
    /// / commas / empty) vs statement-shaped (`;`, `:=`, statement keywords).
    fn braceLooksLikeAggregateBody(self: *Parser) bool {
        if (self.tokens.tag(self.tok) != .l_brace) return false;
        const shape = self.scanBraceShape();
        if (!shape.saw_token) return true; // empty `{}` is aggregate-shaped
        if (shape.semi or shape.stmt_kw or shape.colon_eq) return false;
        return shape.field_eq or shape.comma;
    }

    /// Separator-dot `Type.{…}` is invalid. Point at the `.` and offer the
    /// compact `Type{…}` spelling.
    fn failNamedAggregateDot(self: *Parser) error{ParseError} {
        // The cursor is on `{`; the separator `.` is the token before it.
        const sep_end = self.tokens.end(self.tokens.prev(self.tok));
        const dot_start = if (sep_end > 0) sep_end - 1 else self.tokens.start(self.tok);
        const dot_end = sep_end;
        const msg = named_aggregate_dot_msg;
        self.err_msg = msg;
        self.err_offset = dot_start;
        self.err_end = self.tokens.end(self.tok);
        if (self.diagnostics) |diags| {
            const id = diags.addId(.err, msg, .{ .start = dot_start, .end = dot_end });
            // Rebuild the current line with the separator dot removed as fix-it.
            // Help span covers the `.{` region so carets sit on the edit.
            const line = errors.lineAt(self.tokens.source, dot_start);
            var line_start: u32 = dot_start;
            while (line_start > 0 and self.tokens.source[line_start - 1] != '\n') : (line_start -= 1) {}
            const rel_dot = dot_start - line_start;
            var fix_buf: std.ArrayList(u8) = .empty;
            defer fix_buf.deinit(self.allocator);
            if (rel_dot < line.len and line[rel_dot] == '.') {
                fix_buf.appendSlice(self.allocator, line[0..rel_dot]) catch {};
                fix_buf.appendSlice(self.allocator, line[rel_dot + 1 ..]) catch {};
                const fix = fix_buf.toOwnedSlice(self.allocator) catch null;
                diags.addHelp(id, .{ .start = dot_start, .end = self.tokens.end(self.tok) }, "write the type, then '{'", fix);
            } else {
                diags.addHelp(id, null, "write `Type{...}` — remove the separator dot", null);
            }
        }
        return error.ParseError;
    }

    /// Peek at the next token's tag without consuming.
    fn peekNext(self: *Parser) Tag {
        return self.tokens.tag(self.tokens.next(self.tok));
    }

    /// With `current` on `(`: the tag of the token right after the matching
    /// `)`, scanning a throwaway copy of the lexer. Only parens are counted —
    /// they must balance lexically regardless of what nests inside.
    fn tagAfterParenGroup(self: *Parser) Tag {
        const close = self.tokens.scanBalanced(self.tok, .l_paren, .r_paren) orelse return .eof;
        return self.tokens.tag(self.tokens.next(close));
    }

    /// With `current` on the token after `for`: whether the header opens with
    /// a capture list — `('*')? name (':' type)?` over commas, closed by `in`.
    fn forHeaderOpensWithCaptures(self: *Parser) bool {
        var idx = self.tok;
        while (true) {
            if (self.tokens.tag(idx) == .star) idx = self.tokens.next(idx);
            if (self.tokens.tag(idx) != .identifier) return false;
            idx = self.tokens.next(idx);
            if (self.tokens.tag(idx) == .colon) {
                idx = self.tokens.next(idx);
                idx = self.skipCaptureTypeTokens(idx) orelse return false;
            }
            switch (self.tokens.tag(idx)) {
                .kw_in => return true,
                .comma => idx = self.tokens.next(idx),
                else => return false,
            }
        }
    }

    /// From the first token of a capture's type annotation: the index of the
    /// `,` or `in` that closes it. A type argument list carries its own commas
    /// (`Map(K, V)`), so only depth-0 ones separate captures. A brace group
    /// (`struct { … }`) belongs to the type and is skipped balanced. Null when
    /// the header ends first — the `:` is then not an annotation.
    fn skipCaptureTypeTokens(self: *Parser, from: Index) ?Index {
        var idx = from;
        var depth: u32 = 0;
        while (true) {
            switch (self.tokens.tag(idx)) {
                .l_paren, .l_bracket => depth += 1,
                .r_paren, .r_bracket => {
                    if (depth == 0) return null;
                    depth -= 1;
                },
                .comma, .kw_in => if (depth == 0) return idx,
                .l_brace => {
                    const close = self.tokens.scanBalanced(idx, .l_brace, .r_brace) orelse return null;
                    idx = self.tokens.next(close);
                    continue;
                },
                .r_brace, .fat_arrow, .semicolon, .eof => return null,
                else => {},
            }
            idx = self.tokens.next(idx);
        }
    }

    /// A SPACED top-level `(` group immediately followed by `{` or `=>` is
    /// not a call and not a range end: parsePostfix leaves it, an open
    /// range stays open, and the header ends.
    fn spacedGroupEndsHeader(self: *Parser) bool {
        const h = self.headerAtCursor() orelse return false;
        if (h.kind != .for_header) return false;
        if (self.tokens.flagsOf(self.tok).glued_left) return false;
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
        self.tok = self.tokens.next(self.tok);
    }

    /// The terminator of a statement or of a declaration written in statement
    /// or top-level position: the written `;`, or the end of the file — there is
    /// no next statement for the last one to run into.
    fn expectStatementEnd(self: *Parser) !void {
        if (self.tokens.tag(self.tok) == .semicolon) {
            self.advance();
            return;
        }
        if (self.tokens.tag(self.tok) == .eof) return;
        try self.expect(.semicolon);
    }

    /// `else` followed by `:` heads a `match`'s default arm; every other
    /// `else` chains the enclosing `if`. One token of lookahead is the whole
    /// disambiguation.
    fn atMatchDefaultArm(self: *const Parser) bool {
        if (self.tokens.tag(self.tok) != .kw_else) return false;
        return self.tokens.tag(self.tokens.next(self.tok)) == .colon;
    }

    /// True at an `else` that chains the enclosing `if` — every `else` but a
    /// `match` default-arm head.
    fn atChainingElse(self: *const Parser) bool {
        return self.tokens.tag(self.tok) == .kw_else and !self.atMatchDefaultArm();
    }

    /// True where the statement or declaration could end right here — at its
    /// written `;`, or at the end of the file. The query form of
    /// `expectStatementEnd`, which consumes. A construct parser asks it before
    /// every optional slot that a completed declaration would not have.
    fn atStatementEnd(self: *const Parser) bool {
        return self.tokens.tag(self.tok) == .semicolon or self.tokens.tag(self.tok) == .eof;
    }

    fn expect(self: *Parser, tag: Tag) !void {
        if (self.tokens.tag(self.tok) != tag) {
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
    /// `catch` bodies and loops, but NOT through a nested closure or
    /// trailing-block body — those are their own function boundary.
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
        const txt = self.tokens.slice(self.tok);
        if (self.tokens.tag(self.tok) == .identifier or self.tokens.tag(self.tok).isKeyword()) {
            self.advance();
            return txt;
        }
        return null;
    }

    /// A token usable as a MEMBER name in declaration position (struct
    /// field/method/const, protocol method, impl method): identifiers,
    /// and every keyword except `inline` — declaration
    /// position holds only declarations, access is dot-disambiguated.
    fn isMemberDeclName(self: *Parser) bool {
        if (self.tokens.tag(self.tok) == .identifier) return true;
        if (self.tokens.tag(self.tok) == .kw_inline) return false;
        return self.tokens.tag(self.tok).isKeyword();
    }

    /// Member-name reject: `inline` (the one excluded keyword) gets its
    /// targeted escape-hint; anything else the site's own message.
    fn failMemberDeclName(self: *Parser, msg: []const u8) error{ParseError} {
        if (self.tokens.tag(self.tok) == .kw_inline) {
            return self.fail("'inline' cannot name a member bare — escape it with a backtick (`inline) or rename");
        }
        return self.fail(msg);
    }

    fn fail(self: *Parser, msg: []const u8) error{ParseError} {
        self.err_msg = msg;
        self.err_offset = self.tokens.start(self.tok);
        self.err_end = self.tokens.end(self.tok);
        if (self.diagnostics) |diags| {
            diags.add(.err, msg, .{ .start = self.tokens.start(self.tok), .end = self.tokens.end(self.tok) });
        }
        return error.ParseError;
    }

    /// Like `fail`, but pins the diagnostic to an explicit source span rather
    /// than the current token — used when the offending token has already been
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
    var parser = try Parser.init(arena.allocator(), source);
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
    // The helper maps the keywords; no decl path calls it, so drive it
    // directly.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        var parser = try Parser.init(arena.allocator(), "extern");
        try std.testing.expectEqual(ast.ExternExportModifier.extern_, parser.parseOptionalExternExport());
    }
    {
        var parser = try Parser.init(arena.allocator(), "export");
        try std.testing.expectEqual(ast.ExternExportModifier.export_, parser.parseOptionalExternExport());
    }
    {
        var parser = try Parser.init(arena.allocator(), "foo");
        try std.testing.expectEqual(ast.ExternExportModifier.none, parser.parseOptionalExternExport());
    }
}

test "extern/export AST fields default to absent (unconsumed)" {
    // FnDecl.extern_export defaults to .none on a normally-parsed function;
    // the fn-decl path does not consume the modifier.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () {}");
    const root = try parser.parse();
    const fd = root.data.root.decls[0].data.fn_decl;
    try std.testing.expectEqual(ast.ExternExportModifier.none, fd.extern_export);

    // VarDecl.is_extern / extern_name default to absent (no var-decl path
    // consumes them). A struct literal locks field presence +
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
    var parser = try Parser.init(arena.allocator(), "f :: () -> i32 { 42 }");
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(body.data.block.produces_value);
}

test "block value: a trailing `;` leaves the value untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> i32 { 42; }");
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(body.data.block.produces_value);
}

test "block value: a declaration tail leaves the block value-less" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () -> i32 { n := 42; }");
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    try std.testing.expect(!body.data.block.produces_value);
}

test "block value: an arm's written `;` still leaves the arm producing a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: (n: i32) -> i32 { match n { case 1: 5; else: 0; } }");
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    // Function body's trailing match has no `;` → the body is a value.
    try std.testing.expect(body.data.block.produces_value);
    const match = body.data.block.stmts[0];
    try std.testing.expect(match.data == .match_expr);
    // Each arm body ends with a written `;` and still produces its value.
    for (match.data.match_expr.arms) |arm| {
        try std.testing.expect(arm.body.data.block.produces_value);
    }
}

test "parse #run const binding" {
    const source = "x :: #run compute(5);";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), root.data.root.decls.len);
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    try std.testing.expectEqualStrings("foo", decl.data.fn_decl.name);
    try std.testing.expect(decl.data.fn_decl.body.data == .intrinsic_expr);
}

test "parse void function with extern import" {
    // A postfix `extern LIB` fn import builds an empty-block body +
    // extern_export = .extern_ + extern_lib.
    const source = "InitWindow :: (width: i32, height: i32, title: *u8) -> void extern rl;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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

test "parse fn decl with generic params" {
    const source = "f :: (x: $T) => x;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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

test "parse fn decl with return type" {
    const source = "f :: (x: i32) -> i32 => x;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .fn_decl);
    const fd = decl.data.fn_decl;
    try std.testing.expect(fd.return_type != null);
    try std.testing.expect(fd.return_type.?.data == .type_expr);
    try std.testing.expectEqualStrings("i32", fd.return_type.?.data.type_expr.name);
}

test "a closure literal is `|params| body`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { g := |x: i32| -> i32 x + 1; }");
    const root = try parser.parse();
    const decl = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const lam = decl.data.var_decl.value.?.data.lambda;
    try std.testing.expectEqual(@as(usize, 1), lam.params.len);
    try std.testing.expectEqualStrings("x", lam.params[0].name);
    try std.testing.expectEqualStrings("i32", lam.return_type.?.data.type_expr.name);
    try std.testing.expect(lam.body.data == .binary_op);
}

test "a pipe-parameter default is `|x: i64 = 1| x`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { g := |x: i64 = 1| x; }");
    const root = try parser.parse();
    const decl = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const lam = decl.data.var_decl.value.?.data.lambda;
    try std.testing.expectEqual(@as(usize, 1), lam.params.len);
    try std.testing.expectEqualStrings("x", lam.params[0].name);
    try std.testing.expect(lam.params[0].default_expr != null);
    try std.testing.expect(lam.params[0].default_expr.?.data == .int_literal);
    try std.testing.expectEqual(@as(i64, 1), lam.params[0].default_expr.?.data.int_literal.value);
    try std.testing.expect(lam.body.data == .identifier);
    try std.testing.expectEqualStrings("x", lam.body.data.identifier.name);
}

test "a parenthesized bitwise OR is a pipe-parameter default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { g := |x: i64 = (a | b)| x; }");
    const root = try parser.parse();
    const decl = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const lam = decl.data.var_decl.value.?.data.lambda;
    try std.testing.expect(lam.params[0].default_expr != null);
    const dflt = lam.params[0].default_expr.?.data.binary_op;
    try std.testing.expectEqual(ast.BinaryOp.Op.bit_or, dflt.op);
    try std.testing.expectEqualStrings("a", dflt.lhs.data.identifier.name);
    try std.testing.expectEqualStrings("b", dflt.rhs.data.identifier.name);
    try std.testing.expectEqualStrings("x", lam.body.data.identifier.name);
}

test "a pipe-parameter default may precede another parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { g := |x: i64 = 1, y: i64| x + y; }");
    const root = try parser.parse();
    const decl = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const lam = decl.data.var_decl.value.?.data.lambda;
    try std.testing.expectEqual(@as(usize, 2), lam.params.len);
    try std.testing.expect(lam.params[0].default_expr != null);
    try std.testing.expectEqual(@as(i64, 1), lam.params[0].default_expr.?.data.int_literal.value);
    try std.testing.expect(lam.params[1].default_expr == null);
    try std.testing.expectEqualStrings("y", lam.params[1].name);
    try std.testing.expect(lam.body.data == .binary_op);
    try std.testing.expectEqual(ast.BinaryOp.Op.add, lam.body.data.binary_op.op);
}

test "`||` is an empty parameter list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { g := || { h(); }; }");
    const root = try parser.parse();
    const decl = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const lam = decl.data.var_decl.value.?.data.lambda;
    try std.testing.expectEqual(@as(usize, 0), lam.params.len);
    try std.testing.expect(lam.body.data == .block);
}

test "`|` after a completed operand is bitwise OR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { m := a | b; }");
    const root = try parser.parse();
    const decl = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const bin = decl.data.var_decl.value.?.data.binary_op;
    try std.testing.expectEqual(ast.BinaryOp.Op.bit_or, bin.op);
}

/// Parses `f :: () { g := <literal>; }` and returns the bound lambda.
fn pipeLambda(arena: std.mem.Allocator, literal: []const u8) !ast.Lambda {
    const src = try std.fmt.allocPrintSentinel(arena, "f :: () {{ g := {s}; }}", .{literal}, 0);
    var parser = try Parser.init(arena, src);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    return stmt.data.var_decl.value.?.data.lambda;
}

fn expectBitOr(node: *const Node, lhs: []const u8, rhs: []const u8) !void {
    try std.testing.expectEqual(ast.BinaryOp.Op.bit_or, node.data.binary_op.op);
    try std.testing.expectEqualStrings(lhs, node.data.binary_op.lhs.data.identifier.name);
    try std.testing.expectEqualStrings(rhs, node.data.binary_op.rhs.data.identifier.name);
}

test "a `|` inside a call argument of a pipe-parameter default is bitwise OR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|x: i64 = mask(a | b)| x");
    const dflt = lam.params[0].default_expr.?;
    try expectBitOr(dflt.data.call.args[0], "a", "b");
    try std.testing.expectEqualStrings("x", lam.body.data.identifier.name);
}

test "a `|` inside an index of a pipe-parameter default is bitwise OR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|x: i64 = xs[a | b]| x");
    const dflt = lam.params[0].default_expr.?;
    try expectBitOr(dflt.data.index_expr.index, "a", "b");
    try std.testing.expectEqualStrings("x", lam.body.data.identifier.name);
}

test "a `|` inside a braced branch of a pipe-parameter default is bitwise OR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|x: i64 = if c { a | b } else { 0 }| x");
    const dflt = lam.params[0].default_expr.?;
    try std.testing.expect(!dflt.data.if_expr.is_inline);
    try expectBitOr(dflt.data.if_expr.then_branch.data.block.stmts[0], "a", "b");
    try std.testing.expectEqualStrings("x", lam.body.data.identifier.name);
}

test "a `|` inside an `if` condition of a pipe-parameter default is bitwise OR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|x: i64 = if a | b { 1 } else { 0 }| x");
    const dflt = lam.params[0].default_expr.?;
    try expectBitOr(dflt.data.if_expr.condition, "a", "b");
    try std.testing.expectEqualStrings("x", lam.body.data.identifier.name);
}

test "a pipe-parameter default descends the whole precedence spine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const and_lam = try pipeLambda(arena.allocator(), "|x: i64 = a and b| x");
    try std.testing.expectEqual(ast.BinaryOp.Op.and_op, and_lam.params[0].default_expr.?.data.binary_op.op);

    const coalesce_lam = try pipeLambda(arena.allocator(), "|x: i64 = a ?? b| x");
    try std.testing.expect(coalesce_lam.params[0].default_expr.?.data == .null_coalesce);
}

test "the first `|` on a pipe-parameter default's own spine closes the list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|x: i64 = a | b| x");
    try std.testing.expectEqualStrings("a", lam.params[0].default_expr.?.data.identifier.name);
    try expectBitOr(lam.body, "b", "x");
}

test "an inline `if` is a pipe-parameter default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const then_lam = try pipeLambda(arena.allocator(), "|x: i64 = if c then 7| x");
    const then_if = then_lam.params[0].default_expr.?.data.if_expr;
    try std.testing.expect(then_if.is_inline);
    try std.testing.expectEqual(@as(i64, 7), then_if.then_branch.data.int_literal.value);
    try std.testing.expectEqualStrings("x", then_lam.body.data.identifier.name);

    const else_lam = try pipeLambda(arena.allocator(), "|x: i64 = if c then 1 else 7| x");
    const else_if = else_lam.params[0].default_expr.?.data.if_expr;
    try std.testing.expectEqual(@as(i64, 7), else_if.else_branch.?.data.int_literal.value);
    try std.testing.expectEqualStrings("x", else_lam.body.data.identifier.name);

    const closer_lam = try pipeLambda(arena.allocator(), "|x: i64 = if c then a | b| x");
    const closer_if = closer_lam.params[0].default_expr.?.data.if_expr;
    try std.testing.expectEqualStrings("a", closer_if.then_branch.data.identifier.name);
    try expectBitOr(closer_lam.body, "b", "x");
}

test "a `catch` body is a pipe-parameter default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|x: i64 = f() catch |e| 0| x");
    const caught = lam.params[0].default_expr.?.data.catch_expr;
    try std.testing.expectEqual(@as(i64, 0), caught.body.data.int_literal.value);
    try std.testing.expectEqualStrings("x", lam.body.data.identifier.name);
}

test "a `#run` and a `return` are pipe-parameter defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_lam = try pipeLambda(arena.allocator(), "|x: i64 = #run 13| x");
    const inner = run_lam.params[0].default_expr.?.data.comptime_expr.expr;
    try std.testing.expectEqual(@as(i64, 13), inner.data.int_literal.value);
    try std.testing.expectEqualStrings("x", run_lam.body.data.identifier.name);

    const ret_lam = try pipeLambda(arena.allocator(), "|x: i64 = return 1| x");
    const value = ret_lam.params[0].default_expr.?.data.return_stmt.value.?;
    try std.testing.expectEqual(@as(i64, 1), value.data.int_literal.value);
    try std.testing.expectEqualStrings("x", ret_lam.body.data.identifier.name);
}

test "a closure literal is a pipe-parameter default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|x: i64 = |y: i64| y| 0");
    const inner = lam.params[0].default_expr.?.data.lambda;
    try std.testing.expectEqualStrings("y", inner.params[0].name);
    try std.testing.expectEqualStrings("y", inner.body.data.identifier.name);
    try std.testing.expectEqual(@as(i64, 0), lam.body.data.int_literal.value);
}

test "a nested pipe-parameter default closes against its own list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lam = try pipeLambda(arena.allocator(), "|f: C = |y: i64 = 1| y| f(1)");
    const inner = lam.params[0].default_expr.?.data.lambda;
    try std.testing.expectEqual(@as(i64, 1), inner.params[0].default_expr.?.data.int_literal.value);
    try std.testing.expectEqualStrings("y", inner.body.data.identifier.name);
    try std.testing.expect(lam.body.data == .call);
}

test "a `|` on a paren-parameter default is bitwise OR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "h :: (x: i64 = a | b) -> i64 { x }");
    const root = try parser.parse();
    const fd = root.data.root.decls[0].data.fn_decl;
    try expectBitOr(fd.params[0].default_expr.?, "a", "b");
}

test "a closure body inside a paren-parameter default keeps `|` as bitwise OR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "h :: (g: C = |y: i64| y | z) -> i64 { g(0) }");
    const root = try parser.parse();
    const fd = root.data.root.decls[0].data.fn_decl;
    const inner = fd.params[0].default_expr.?.data.lambda;
    try expectBitOr(inner.body, "y", "z");
}

test "a parenthesized closure literal is a block tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { g := if c { (|x: i64| x) } else { (|x: i64| 0 - x) }; }");
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const branch = stmt.data.var_decl.value.?.data.if_expr.then_branch;
    try std.testing.expect(branch.data.block.stmts[0].data == .lambda);
}

test "a closure literal takes no `=>` and no abi tail" {
    try expectParseErrorAt("f :: () { g := |x: i32| => x; }", "unexpected token in expression", 24);
    try expectParseErrorAt("f :: () { g := |x: i32| abi(.c) x; }", "unexpected token in expression", 24);
}

test "a closure literal cannot open a statement" {
    try expectParseErrorAt(
        "f :: () { |x: i32| x + 1; }",
        "a closure literal cannot open a statement — bind it (`f := |x| …`) or pass it as an argument",
        10,
    );
}

test "parse match with else arm" {
    const source =
        \\main :: () {
        \\  x := 5;
        \\  match x {
        \\    case 1: 10;
        \\    else: 99;
        \\  };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
    const result = parser.parse();
    try std.testing.expectError(error.ParseError, result);
    try std.testing.expectEqualStrings("integer literal overflow", parser.err_msg.?);
}

test "parse pack-constrained variadic parameter (..xs: Protocol)" {
    const source = "map :: (..sources: ValueListenable) => sources;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const p = root.data.root.decls[0].data.fn_decl.params[0];
    try std.testing.expect(p.is_variadic);
    try std.testing.expect(p.is_comptime); // comptime type pack
    try std.testing.expect(!p.is_pack); // not the protocol-constrained form
}

// ── Pack expansion in the four positions ──────────────────────────────
// All spread forms reuse `spread_expr` (its operand carries any projection /
// type-application); closure-sig packs use ClosureTypeExpr.pack_name +
// pack_projection. Arrow bodies wrap the expression in a block.

test "parse pack expansion: brace value .{..xs}" {
    const source = "f :: () => .{..xs};";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const call = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(call.data == .call);
    try std.testing.expectEqual(@as(usize, 1), call.data.call.args.len);
    try std.testing.expect(call.data.call.args[0].data == .spread_expr);
}

// ── `error { ... }` decls + `!` / `!Named` type exprs ──

test "parse error-set decl: tags collected" {
    const source = "ParseErr :: error { BadDigit, Overflow, Empty }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .error_type_expr);
    try std.testing.expect(rt.data.error_type_expr.name == null);
}

test "parse bare failable return: named `!Foo`" {
    const source = "f :: () -> !ParseErr { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .error_type_expr);
    try std.testing.expectEqualStrings("ParseErr", rt.data.error_type_expr.name.?);
}

test "parse single-value failable `-> (T, !)`" {
    const source = "f :: () -> (i32, !) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
    try std.testing.expect(rt.data == .return_type_expr or rt.data == .tuple_type_expr);
    const fields = if (rt.data == .return_type_expr) rt.data.return_type_expr.field_types else rt.data.tuple_type_expr.field_types;
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expect(fields[2].data == .error_type_expr);
    try std.testing.expectEqualStrings("ParseErr", fields[2].data.error_type_expr.name.?);
}

test "parse bare failable `-> T !` is rejected" {
    const source = "f :: () -> i32 ! { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "parse bare-paren failable `-> (!, i32)` is rejected" {
    const source = "f :: () -> (!, i32) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "parse bare-paren failable `-> (i32, !, i64)` is rejected" {
    const source = "f :: () -> (i32, !, i64) { 0; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "round-trip print: error-set decl" {
    const source = "ParseErr :: error { BadDigit, Overflow, Empty }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    var parser = try Parser.init(arena.allocator(), source);
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
        var parser = try Parser.init(arena.allocator(), "f :: () -> ! { 0; }");
        const root = try parser.parse();
        const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
        var aw = std.Io.Writer.Allocating.init(arena.allocator());
        try print.printType(rt, &aw.writer);
        try std.testing.expectEqualStrings("!", aw.writer.toArrayList().items);
    }
    {
        var parser = try Parser.init(arena.allocator(), "f :: () -> !ParseErr { 0; }");
        const root = try parser.parse();
        const rt = root.data.root.decls[0].data.fn_decl.return_type.?;
        var aw = std.Io.Writer.Allocating.init(arena.allocator());
        try print.printType(rt, &aw.writer);
        try std.testing.expectEqualStrings("!ParseErr", aw.writer.toArrayList().items);
    }
}

// ── raise / try / catch / onfail + precedence + pipe ──

/// Parse `src` (a single `f :: () { ... }` decl) and return its body's first
/// statement node.
fn e02FirstStmt(alloc: std.mem.Allocator, src: [:0]const u8) anyerror!*Node {
    var parser = try Parser.init(alloc, src);
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

test "postfix cast parses: a.(i8)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := a.(i8); }");
    try std.testing.expect(v.data == .postfix_cast);
    try e02ExpectPrints(arena.allocator(), v, "a.(i8)");
}

test "postfix cast: int-literal receiver does not lex as a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := 56.(i8); }");
    try std.testing.expect(v.data == .postfix_cast);
    try std.testing.expect(v.data.postfix_cast.operand.data == .int_literal);
}

test "postfix cast: composite targets *T / []u8 / ?T" {
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

test "postfix cast binds tighter than unary minus: -x.(i8)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := -x.(i8); }");
    try std.testing.expect(v.data == .unary_op and v.data.unary_op.op == .negate);
    try std.testing.expect(v.data.unary_op.operand.data == .postfix_cast);
}

test "postfix cast: '.(P, alloc)' parses with the allocator argument; a third element is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x.(P, alloc); }");
    try std.testing.expect(v.data == .postfix_cast);
    try std.testing.expect(v.data.postfix_cast.alloc_arg != null);
    try std.testing.expectError(error.ParseError, e02FirstValue(arena.allocator(), "f :: () { v := x.(P, a, b); }"));
}

test "optional-chained cast parses: x?.(i64)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := x?.(i64); }");
    try std.testing.expect(v.data == .postfix_cast);
    try std.testing.expect(v.data.postfix_cast.is_optional_chain);
    try e02ExpectPrints(arena.allocator(), v, "x?.(i64)");
}

test "try binds tighter than ??: try foo() ?? try boo()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := try foo() ?? try boo(); }");
    try std.testing.expect(v.data == .null_coalesce);
    try std.testing.expect(v.data.null_coalesce.lhs.data == .try_expr);
    try std.testing.expect(v.data.null_coalesce.rhs.data == .try_expr);
}

test "?? is right-associative: a ?? b ?? c => a ?? (b ?? c)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := try a() ?? try b() ?? try c(); }");
    try std.testing.expect(v.data == .null_coalesce);
    // LHS is the first operand; RHS is the nested (b ?? c).
    try std.testing.expect(v.data.null_coalesce.lhs.data == .try_expr);
    try std.testing.expect(v.data.null_coalesce.rhs.data == .null_coalesce);
    try std.testing.expect(v.data.null_coalesce.rhs.data.null_coalesce.lhs.data == .try_expr);
}

test "try prefix stacks under xx: xx try foo()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := xx try foo(); }");
    try std.testing.expect(v.data == .unary_op and v.data.unary_op.op == .xx);
    try std.testing.expect(v.data.unary_op.operand.data == .try_expr);
}

test "catch no binding, braced body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch { }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expect(v.data.catch_expr.binding == null);
    try std.testing.expect(v.data.catch_expr.body.data == .block);
}

test "catch with binding, block body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch |e| { bar(); }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expectEqualStrings("e", v.data.catch_expr.binding.?);
    try std.testing.expect(v.data.catch_expr.body.data == .block);
}

test "catch with binding, bare-expression body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch |e| bar(); }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expectEqualStrings("e", v.data.catch_expr.binding.?);
    try std.testing.expect(v.data.catch_expr.body.data == .call);
}

test "catch body is a match over the binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := foo() catch |e| match e { case .Empty: 0; else: 1; }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expect(v.data.catch_expr.body.data == .match_expr);
    try std.testing.expectEqual(@as(usize, 2), v.data.catch_expr.body.data.match_expr.arms.len);
    // subject is the binding identifier
    try std.testing.expect(v.data.catch_expr.body.data.match_expr.subject.data == .identifier);
    try std.testing.expectEqualStrings("e", v.data.catch_expr.body.data.match_expr.subject.data.identifier.name);
}

test "catch over a parenthesized ??-chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := (try foo() ?? try boo()) catch |e| { }; }");
    try std.testing.expect(v.data == .catch_expr);
    try std.testing.expect(v.data.catch_expr.operand.data == .null_coalesce);
}

test "catch without binding and unbraced body is rejected" {
    // No binding (the token after `catch` is not an identifier) and no braces:
    // the no-binding form requires a braced body.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { v := foo() catch 42; }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "raise error.X parses as raise_stmt over a field access" {
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

test "raise variable form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try e02FirstStmt(arena.allocator(), "f :: () { raise e; }");
    try std.testing.expect(s.data == .raise_stmt);
    try std.testing.expect(s.data.raise_stmt.tag.data == .identifier);
}

test "raise rejected in expression position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { x := 1 + raise error.X; }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "raise rejected inside an onfail body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { onfail { raise error.X; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "raise rejected inside a defer body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { defer { raise error.X; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "return rejected inside a defer body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { defer { return; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "try rejected inside an onfail body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { onfail { try g(); } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "break rejected inside a defer body (transitive through a loop)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { defer { for i in 0..1 { break; } } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "continue rejected inside an onfail body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { onfail |e| { continue; } }");
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "return inside a closure within a cleanup body is allowed" {
    // A closure is its own function boundary: parseClosure clears the cleanup
    // flags, so `return` from the closure body is legal even inside `defer`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { defer g(|x: i32| -> i32 { return x; }); }");
    _ = try parser.parse();
}

test "control-flow legal after the cleanup body (flag restored)" {
    // The cleanup-body flag must not leak to statements that follow the defer.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: () { defer cleanup(); return; }");
    _ = try parser.parse();
}

test "onfail with binding and block body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try e02FirstStmt(arena.allocator(), "f :: () { onfail |e| { close(h); } }");
    try std.testing.expect(s.data == .onfail_stmt);
    try std.testing.expectEqualStrings("e", s.data.onfail_stmt.binding.?);
    try std.testing.expect(s.data.onfail_stmt.body.data == .block);
}

test "onfail no-binding block vs bare-expression body" {
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

test "`|>` is not an operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ParseError, e02FirstValue(arena.allocator(), "f :: () { v := x |> g(a); }"));
    try std.testing.expectError(error.ParseError, e02FirstValue(arena.allocator(), "f :: () { v := x |> g; }"));
}

test "round-trip print: try / or precedence / raise / catch / onfail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := try foo(); }"), "try foo()");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := try foo() or try boo(); }"), "try foo() or try boo()");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { raise error.BadDigit; }"), "raise error.BadDigit");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { raise e; }"), "raise e");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := foo() catch |e| bar(); }"), "foo() catch |e| bar()");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := foo() catch |e| { bar(); }; }"), "foo() catch |e| { bar(); }");
    try e02ExpectPrints(a, try e02FirstValue(a, "f :: () { v := foo() catch { bar(); }; }"), "foo() catch { bar(); }");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { onfail close(h); }"), "onfail close(h)");
    try e02ExpectPrints(a, try e02FirstStmt(a, "f :: () { onfail |e| { close(h); } }"), "onfail |e| { close(h); }");
}

test "round-trip print: a match over the catch binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try e02FirstValue(a, "f :: () { v := foo() catch |e| match e { case .Empty: 0; else: 1; }; }");
    try e02ExpectPrints(a, v, "foo() catch |e| match e { case .Empty: 0; else: 1; }");
}

test "try in statement position (propagate, discard value)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try e02FirstStmt(arena.allocator(), "f :: () { try must_init(); }");
    try std.testing.expect(s.data == .try_expr);
    try std.testing.expect(s.data.try_expr.operand.data == .call);
}

test "try over a parenthesized ??-chain: try (foo() ?? boo())" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := try (foo() ?? boo()); }");
    // Distinct from `try foo() ?? try boo()`: here `try` wraps the whole chain.
    try std.testing.expect(v.data == .try_expr);
    try std.testing.expect(v.data.try_expr.operand.data == .null_coalesce);
}

test "?? value-terminator: parse(s) ?? 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try e02FirstValue(arena.allocator(), "f :: () { v := parse(s) ?? 0; }");
    try std.testing.expect(v.data == .null_coalesce);
    try std.testing.expect(v.data.null_coalesce.lhs.data == .call);
    try std.testing.expect(v.data.null_coalesce.rhs.data == .int_literal);
}

test "full failable function parses end-to-end (every failable form)" {
    const source =
        \\parse :: (s: string) -> (i32, !ParseErr) {
        \\    onfail |e| { cleanup(s); }
        \\    v := try inner(s) ?? 0;
        \\    w := other(s) catch |e2| { return 0; };
        \\    if bad(s) { raise error.BadDigit; }
        \\    return v;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
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
    try std.testing.expect(stmts[1].data == .var_decl and stmts[1].data.var_decl.value.?.data == .null_coalesce);
    try std.testing.expect(stmts[2].data == .var_decl and stmts[2].data.var_decl.value.?.data == .catch_expr);
    try std.testing.expect(stmts[3].data == .if_expr);
    try std.testing.expect(stmts[4].data == .return_stmt);
    // the onfail flag was restored: the raise inside the (separate) if-block is allowed
    const then_block = stmts[3].data.if_expr.then_branch;
    try std.testing.expect(then_block.data.block.stmts[0].data == .raise_stmt);
}

test "parse Type{ fields } as a juxtaposition" {
    const source =
        \\Point :: struct { x: i64; y: i64; }
        \\main :: () {
        \\  p := Point{ x = 1, y = 2 };
        \\  q := Point{};
        \\  r: Point = .{};
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[1].data.fn_decl.body;
    const stmts = body.data.block.stmts;
    try std.testing.expect(stmts[0].data == .var_decl);
    const p_init = stmts[0].data.var_decl.value.?;
    try std.testing.expect(p_init.data == .juxtaposition);
    try std.testing.expectEqualStrings("Point", p_init.data.juxtaposition.expr.data.identifier.name);
    try std.testing.expectEqual(@as(usize, 2), p_init.data.juxtaposition.block.data.block.stmts.len);
    const q_init = stmts[1].data.var_decl.value.?;
    try std.testing.expect(q_init.data == .juxtaposition);
    try std.testing.expectEqual(@as(usize, 0), q_init.data.juxtaposition.block.data.block.stmts.len);
    // Contextual .{} is a primary, not a juxtaposition.
    const r_init = stmts[2].data.var_decl.value.?;
    try std.testing.expect(r_init.data == .struct_literal);
    try std.testing.expect(r_init.data.struct_literal.struct_name == null);
    try std.testing.expect(r_init.data.struct_literal.type_expr == null);
}

test "a backticked keyword labels a literal field" {
    const source =
        \\main :: () {
        \\  a := .{ `if = 2 };
        \\  b := Pair{ `push = 7 };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    const a_init = stmts[0].data.var_decl.value.?;
    try std.testing.expect(a_init.data == .struct_literal);
    try std.testing.expectEqualStrings("if", a_init.data.struct_literal.field_inits[0].name.?);
    const b_init = stmts[1].data.var_decl.value.?;
    try std.testing.expect(b_init.data == .juxtaposition);
    const item = b_init.data.juxtaposition.block.data.block.stmts[0];
    try std.testing.expect(item.data == .assignment);
    try std.testing.expectEqualStrings("push", item.data.assignment.target.data.identifier.name);
}

test "a bare keyword does not label a literal field" {
    try expectParseErrorAt("main :: () { a := .{ if = 2 }; }", "unexpected token in expression", 24);
    try expectParseErrorAt("main :: () { b := Pair{ push = 7 }; }", "unexpected token in expression", 29);
}

test "parse an empty brace after an argument call as a juxtaposition" {
    // Neither spelling decides: tight, spaced, a wide gap, a type-expr
    // argument, a value argument, a lowercase or PascalCase callee, and `*x`.
    const source =
        \\main :: () {
        \\  a := List(i64){};
        \\  b := List(i64) {};
        \\  c := List(Move)     {};
        \\  d := Box(pair){};
        \\  e := Buf(16){};
        \\  f := list(i64){};
        \\  g := Group(n) {};
        \\  h := render(*screen) {};
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    for (body.data.block.stmts) |stmt| {
        const init_expr = stmt.data.var_decl.value.?;
        try std.testing.expect(init_expr.data == .juxtaposition);
        const jx = init_expr.data.juxtaposition;
        try std.testing.expect(jx.expr.data == .call);
        try std.testing.expectEqual(@as(usize, 1), jx.expr.data.call.args.len);
        try std.testing.expectEqual(@as(usize, 0), jx.block.data.block.stmts.len);
    }
}

test "parse a comment-only body as a juxtaposition too" {
    const source =
        \\main :: () {
        \\  b := Box(pair){ // nothing yet
        \\  };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    const init_expr = body.data.block.stmts[0].data.var_decl.value.?;
    try std.testing.expect(init_expr.data == .juxtaposition);
}

test "parse a juxtaposition continues only on a dot" {
    // `.len` chains onto the juxtaposition; the next statement starts on its own.
    const source =
        \\main :: () {
        \\  n := List(i64){}.len;
        \\  Group(n) {};
        \\  m := 1;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    const chained = stmts[0].data.var_decl.value.?;
    try std.testing.expect(chained.data == .field_access);
    try std.testing.expect(chained.data.field_access.object.data == .juxtaposition);
    try std.testing.expect(stmts[1].data == .juxtaposition);
}

test "parse a juxtaposition does not stack" {
    // `T { fields } { stmts }` is the aggregate, then an ordinary scope — with
    // the `;` that ends the first statement.
    const source =
        \\main :: () {
        \\  p := T { x = 1 };
        \\  {
        \\    work();
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expect(stmts[0].data.var_decl.value.?.data == .juxtaposition);
    try std.testing.expect(stmts[1].data == .block);
}

test "a second brace group on one line wants the terminator" {
    try expectParseErrorAt(
        "main :: () { p := T { x = 1 } { work(); } }",
        "expected ';'",
        30,
    );
}

test "parse a statement ending in a juxtaposition takes its terminator" {
    const source =
        \\main :: () {
        \\  identity.begin_build();
        \\  {
        \\    work();
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expect(stmts[0].data == .call);
    try std.testing.expect(stmts[1].data == .block);
}

test "parse a wrapped brace juxtaposes the same way" {
    const source =
        \\main :: () {
        \\  screen := vstack(12.0)
        \\  {
        \\    Label { text = "x" };
        \\  };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const jx = stmts[0].data.var_decl.value.?.data.juxtaposition;
    try std.testing.expect(jx.expr.data == .call);
    try std.testing.expectEqual(@as(usize, 1), jx.block.data.block.stmts.len);
    try std.testing.expect(jx.block.data.block.stmts[0].data == .juxtaposition);
}

test "infix continues past a juxtaposition's brace" {
    const source =
        \\main :: () {
        \\  n := f() { } + x;
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const sum = stmts[0].data.var_decl.value.?;
    try std.testing.expect(sum.data == .binary_op and sum.data.binary_op.op == .add);
    try std.testing.expect(sum.data.binary_op.lhs.data == .juxtaposition);
}

test "an if value does not juxtapose" {
    const source =
        \\main :: () {
        \\  x := if true { 1 } else { 2 }
        \\  { print("{}", x); }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expect(stmts[0].data.var_decl.value.?.data == .if_expr);
    try std.testing.expect(stmts[1].data == .block);
}

test "parse a zero-arg empty brace as a juxtaposition" {
    const source =
        \\f :: (body: Closure()) { body(); }
        \\main :: () { f(){} }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[1].data.fn_decl.body;
    const jx = body.data.block.stmts[0];
    try std.testing.expect(jx.data == .juxtaposition);
    try std.testing.expect(jx.data.juxtaposition.expr.data == .call);
    try std.testing.expect(!jx.data.juxtaposition.has_header);
}

test "a juxtaposed block's header is its closure's parameter list" {
    const source =
        \\main :: () {
        \\  each(xs) { |x: i64, k| print("{}\n", x + k); }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const jx = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0].data.juxtaposition;
    try std.testing.expect(jx.has_header);
    try std.testing.expectEqual(@as(usize, 2), jx.params.len);
    try std.testing.expectEqualStrings("x", jx.params[0].name);
    try std.testing.expectEqualStrings("i64", jx.params[0].type_expr.data.type_expr.name);
    try std.testing.expectEqualStrings("k", jx.params[1].name);
    try std.testing.expect(jx.params[1].type_expr.data == .inferred_type);
    try std.testing.expect(jx.block.data == .block);
}

test "a juxtaposed header is a function boundary inside a defer body" {
    const source =
        \\main :: () {
        \\  defer { each(xs) { |x| return; } }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const defer_stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const jx = defer_stmt.data.defer_stmt.expr.data.block.stmts[0].data.juxtaposition;
    try std.testing.expect(jx.has_header);
    try std.testing.expectEqual(@as(usize, 1), jx.params.len);
}

test "an empty pipe pair is a juxtaposed header" {
    const source =
        \\main :: () {
        \\  each(xs) { || }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const jx = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0].data.juxtaposition;
    try std.testing.expect(jx.has_header);
    try std.testing.expectEqual(@as(usize, 0), jx.params.len);
}

test "parse compound and multi-argument type applications as juxtapositions" {
    // `[]u8` → slice_type_expr; `?i64` → optional_type_expr;
    // `(i64) -> i64` → function_type_expr; `Vec(3, f32)` mixes value + type
    // args. Every shape reaches the callee the same way.
    const source =
        \\main :: () {
        \\  xs := List([]u8){};
        \\  ps := List(*Node){};
        \\  os := List(?i64){};
        \\  fs := Marker((i64) -> i64, [:0]u8){};
        \\  vs := Vec(3, f32){};
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    for (body.data.block.stmts) |stmt| {
        const init_expr = stmt.data.var_decl.value.?;
        try std.testing.expect(init_expr.data == .juxtaposition);
        try std.testing.expect(init_expr.data.juxtaposition.expr.data == .call);
    }
}

test "parse rejects separator-dot Type.{}" {
    const source =
        \\main :: () {
        \\  p := Point.{ x = 1 };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const result = parser.parse();
    try std.testing.expectError(error.ParseError, result);
    try std.testing.expect(parser.err_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, parser.err_msg.?, "named aggregate") != null);
}

test "parse a self-trailing block on a juxtaposition binds self" {
    const source =
        \\main :: () {
        \\  b := Button{ label = "x" }.{
        \\    self.label = "y";
        \\  };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    const init_expr = body.data.block.stmts[0].data.var_decl.value.?;
    try std.testing.expect(init_expr.data == .juxtaposition);
    try std.testing.expect(init_expr.data.juxtaposition.init_block != null);
    try std.testing.expectEqualStrings("self", init_expr.data.juxtaposition.init_block_self.?);
}

test "a self-trailing header names the binding" {
    const source =
        \\main :: () {
        \\  b := Button{ label = "x" }.{ |btn|
        \\    btn.label = "y";
        \\  };
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    const init_expr = body.data.block.stmts[0].data.var_decl.value.?;
    try std.testing.expectEqualStrings("btn", init_expr.data.juxtaposition.init_block_self.?);
    try std.testing.expectEqual(@as(usize, 1), init_expr.data.juxtaposition.init_block.?.data.block.stmts.len);
}

test "a self-trailing block on a contextual literal stays a struct literal" {
    const source =
        \\main :: () {
        \\  use(.{ f }.{ |s| s.f = 2; });
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const call = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    const arg = call.data.call.args[0];
    try std.testing.expect(arg.data == .struct_literal);
    try std.testing.expectEqualStrings("s", arg.data.struct_literal.init_block_self.?);
}

test "a self-trailing header binds one name" {
    try expectParseErrorAt(
        "main :: () { b := Button{ label = \"x\" }.{ |a, b| a.label = \"y\"; }; }",
        "a self-trailing block's header binds one name: `.{ |s| … }`",
        43,
    );
}

test "a second self-trailing block is refused" {
    try expectParseErrorAt(
        "main :: () { b := Button{ label = \"x\" }.{ self.a = 1; }.{ self.b = 2; }; }",
        "a struct literal already has a following block",
        56,
    );
}

test "parse push Context { fields } { body } without parens" {
    const source =
        \\main :: () {
        \\  push Context{ allocator = context.allocator } {
        \\    x := 1;
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    const stmt = body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .push_stmt);
    const ctx = stmt.data.push_stmt.context_expr;
    try std.testing.expect(ctx.data == .juxtaposition);
    try std.testing.expect(ctx.data.juxtaposition.init_block == null);
    try std.testing.expect(stmt.data.push_stmt.body.data == .block);
}

test "parse push over a value keeps the brace as the body" {
    const source =
        \\main :: () {
        \\  push ctx { x := 1; }
        \\  push self.dctx { y := 2; }
        \\  push .{ allocator = a } { z := 3; }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmts = root.data.root.decls[0].data.fn_decl.body.data.block.stmts;
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    try std.testing.expect(stmts[0].data.push_stmt.context_expr.data == .identifier);
    try std.testing.expect(stmts[1].data.push_stmt.context_expr.data == .field_access);
    try std.testing.expect(stmts[2].data.push_stmt.context_expr.data == .struct_literal);
    for (stmts) |s| try std.testing.expectEqual(@as(usize, 1), s.data.push_stmt.body.data.block.stmts.len);
}

test "parse a juxtaposition inside a push context field value" {
    const source =
        \\main :: () {
        \\  push Ctx { n = Box(i64){ 1 } } { }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .push_stmt);
    const ctx = stmt.data.push_stmt.context_expr;
    try std.testing.expect(ctx.data == .juxtaposition);
    const item = ctx.data.juxtaposition.block.data.block.stmts[0];
    try std.testing.expect(item.data == .assignment);
    try std.testing.expect(item.data.assignment.value.data == .juxtaposition);
    try std.testing.expect(item.data.assignment.value.data.juxtaposition.expr.data == .call);
}

test "parse a juxtaposition inside a grouped push context" {
    const source =
        \\main :: () {
        \\  push (vstack(8) { x(); }) { }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .push_stmt);
    const ctx = stmt.data.push_stmt.context_expr;
    try std.testing.expect(ctx.data == .juxtaposition);
    try std.testing.expect(ctx.data.juxtaposition.expr.data == .call);
}

test "parse a juxtaposition inside a push context call argument" {
    const source =
        \\main :: () {
        \\  push wrap(vstack(8) { x(); }) { y(); }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .push_stmt);
    const ctx = stmt.data.push_stmt.context_expr;
    try std.testing.expect(ctx.data == .call);
    try std.testing.expectEqual(@as(usize, 1), ctx.data.call.args.len);
    try std.testing.expect(ctx.data.call.args[0].data == .juxtaposition);
    try std.testing.expectEqual(@as(usize, 1), stmt.data.push_stmt.body.data.block.stmts.len);
}

test "parse a juxtaposition inside a push .{ } field value" {
    const source =
        \\main :: () {
        \\  push .{ b = Box(i64){ 1 } } { }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .push_stmt);
    const ctx = stmt.data.push_stmt.context_expr;
    try std.testing.expect(ctx.data == .struct_literal);
    const value = ctx.data.struct_literal.field_inits[0].value;
    try std.testing.expect(value.data == .juxtaposition);
    try std.testing.expect(value.data.juxtaposition.expr.data == .call);
    try std.testing.expect(stmt.data.push_stmt.body.data == .block);
}

test "parse a juxtaposition inside a for-header .[ ] element" {
    const source =
        \\main :: () {
        \\  for x in .[ Label { text = "a" } ] { g(); }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .for_expr);
    const iterable = stmt.data.for_expr.iterables[0].expr;
    try std.testing.expect(iterable.data == .array_literal);
    try std.testing.expect(iterable.data.array_literal.elements[0].data == .juxtaposition);
    try std.testing.expectEqual(@as(usize, 1), stmt.data.for_expr.body.data.block.stmts.len);
}

test "parse a juxtaposition inside an if-header index" {
    const source =
        \\main :: () {
        \\  if xs[Pt{ 1 }.x] { g(); }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .if_expr);
    const cond = stmt.data.if_expr.condition;
    try std.testing.expect(cond.data == .index_expr);
    try std.testing.expect(cond.data.index_expr.index.data.field_access.object.data == .juxtaposition);
    try std.testing.expectEqual(@as(usize, 1), stmt.data.if_expr.then_branch.data.block.stmts.len);
}

test "parse a juxtaposition inside a Type.[ ] under a match subject" {
    const source =
        \\main :: () {
        \\  match Pt.[ Pt{ 1 } ][0] { case .a: 1; }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .match_expr);
    const subject = stmt.data.match_expr.subject;
    try std.testing.expect(subject.data == .index_expr);
    const arr = subject.data.index_expr.object;
    try std.testing.expect(arr.data == .array_literal);
    try std.testing.expect(arr.data.array_literal.elements[0].data == .juxtaposition);
    try std.testing.expectEqual(@as(usize, 1), stmt.data.match_expr.arms.len);
}

test "parse a juxtaposition inside a brace-as-primary if condition" {
    const source =
        \\main :: () {
        \\  if { Pt { 1 }.x } == 1 { g(); }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .if_expr);
    const cond = stmt.data.if_expr.condition;
    try std.testing.expect(cond.data == .binary_op and cond.data.binary_op.op == .eq);
    const inner = cond.data.binary_op.lhs.data.block.stmts[0];
    try std.testing.expect(inner.data.field_access.object.data == .juxtaposition);
}

test "parse a catch-bare tail in a while header keeps the body brace" {
    const source =
        \\main :: () {
        \\  while mk(n) catch |e| false { n = n + 1; }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .while_expr);
    try std.testing.expect(stmt.data.while_expr.condition.data == .catch_expr);
    try std.testing.expectEqual(@as(usize, 1), stmt.data.while_expr.body.data.block.stmts.len);
}

test "parse a named aggregate ending an if header only when parenthesized" {
    const source =
        \\main :: () {
        \\  if (Button{ label = "x" }.ready) { g(); }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .if_expr);
    const cond = stmt.data.if_expr.condition;
    try std.testing.expect(cond.data == .field_access);
    try std.testing.expect(cond.data.field_access.object.data == .juxtaposition);
    try std.testing.expectEqual(@as(usize, 1), stmt.data.if_expr.then_branch.data.block.stmts.len);
    // Unparenthesized, the header keeps the brace: the aggregate's `{` is the body.
    try expectParseErrorAt(
        "main :: () {\n  if Button{ label = \"x\" }.ready { g(); }\n}",
        "expected ';'",
        38,
    );
}

test "parse if cond { body } is not Type{}" {
    const source =
        \\main :: () {
        \\  if neg { x = 1; }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const root = try parser.parse();
    const body = root.data.root.decls[0].data.fn_decl.body;
    const ife = body.data.block.stmts[0];
    try std.testing.expect(ife.data == .if_expr);
    try std.testing.expect(ife.data.if_expr.condition.data == .identifier);
    try std.testing.expectEqualStrings("neg", ife.data.if_expr.condition.data.identifier.name);
}

test "parse `if x == y {` stays an if over a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "main :: () {\n  if x == y { g(); }\n}");
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .if_expr);
    const cond = stmt.data.if_expr.condition;
    try std.testing.expect(cond.data == .binary_op and cond.data.binary_op.op == .eq);
}

test "parse the match subject as a header expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A call subject: the `{` opens the arm list, not a trailing block on `f`.
    var parser = try Parser.init(arena.allocator(), "main :: () {\n  match f(1) { case .a: |v| v; }\n}");
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .match_expr);
    const me = stmt.data.match_expr;
    try std.testing.expect(me.subject.data == .call);
    try std.testing.expectEqual(@as(usize, 1), me.arms.len);
    try std.testing.expectEqualStrings("v", me.arms[0].capture.?);
}

test "parse empty braces after a call subject as the arm list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "main :: () {\n  match f(1) {}\n}");
    const root = try parser.parse();
    const stmt = root.data.root.decls[0].data.fn_decl.body.data.block.stmts[0];
    try std.testing.expect(stmt.data == .match_expr);
    try std.testing.expect(stmt.data.match_expr.subject.data == .call);
    try std.testing.expectEqual(@as(usize, 0), stmt.data.match_expr.arms.len);
}

test "parse inline match as a comptime match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "inline match OS {\n  case .macos: X :: 1;\n  else: X :: 2;\n}");
    const root = try parser.parse();
    const decl = root.data.root.decls[0];
    try std.testing.expect(decl.data == .match_expr);
    try std.testing.expect(decl.data.match_expr.is_comptime);
}

/// Parse `src`, expect `error.ParseError`, and pin both the diagnostic text
/// and the byte offset it reports at.
fn expectParseErrorAt(src: [:0]const u8, msg: []const u8, offset: u32) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqualStrings(msg, parser.err_msg orelse "");
    try std.testing.expectEqual(offset, parser.err_offset orelse std.math.maxInt(u32));
}

test "unterminated paren in grouping position fails as tuple" {
    // isFunctionTypeExprAtLParen sees no closer and declines; the grouping
    // parse then runs into EOF.
    try expectParseErrorAt("x := (a, b\n", "tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)", 7);
    try expectParseErrorAt("x := ((a, b)\n", "tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)", 8);
}

test "crossed delimiters report missing closer at the unexpected token" {
    // The paren scan passes `]` through unmatched; the element parse reports
    // the missing `)` at the bracket.
    try expectParseErrorAt("x := (a]; y := 1;", "expected ')'", 7);
}

test "function-type path without closer fails as tuple" {
    // tagAfterParenGroup finds no `)` before EOF, so the `->` never counts as
    // a function type and the tuple refusal fires.
    try expectParseErrorAt("F :: (i32, i32 -> i32;", "tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)", 9);
}

test "return-type inline struct without closer reports missing brace" {
    // hasFnBodyAfterArrow parks at .eof and classifies no body; the alias
    // parse then demands the struct body's `}`.
    try expectParseErrorAt("f :: () -> struct { x: i64;", "expected '}'", 27);
}

test "unterminated aggregate reports missing brace" {
    try expectParseErrorAt("x := Plan{ a = 1", "expected '}'", 16);
}

test "param list missing closer fails as tuple" {
    try expectParseErrorAt("f :: (a: i32 { 1 }", "tuple values use `.{ … }` with a `Tuple(…)` annotation (e.g. `t : Tuple(A, B) = .{a, b}`)", 6);
}

test "peekTag saturates at the eof row for any runtime offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "x :: 1;");
    try std.testing.expectEqual(Tag.semicolon, parser.peekTag(3));
    try std.testing.expectEqual(Tag.eof, parser.peekTag(4));
    var offset: usize = 5;
    while (offset < 100) : (offset += 17) {
        try std.testing.expectEqual(Tag.eof, parser.peekTag(offset));
    }
}

test "a lex OOM during construction surfaces as error.OutOfMemory, never ParseError" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Parser.init(failing.allocator(), "x :: 1;"));
}

test "malformed source fails at parse, not at construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "f :: (");
    try std.testing.expectError(error.ParseError, parser.parse());
}
