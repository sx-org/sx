const std = @import("std");
const ast = @import("../ast.zig");
const errors = @import("../errors.zig");
const types = @import("types.zig");
const name_class = @import("../types.zig");
const program_index_mod = @import("program_index.zig");
const type_resolver = @import("type_resolver.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const TypeTable = types.TypeTable;
const ProgramIndex = program_index_mod.ProgramIndex;
const TypeResolver = type_resolver.TypeResolver;

/// Declaration-name / type-position diagnostic pass. Two checks, before
/// lowering:
///
/// 1. Unknown-type diagnostic, extracted from `Lowering`
///    (architecture phase A2.4): an identifier used in a type position that
///    names no declared type, primitive, or in-scope generic type parameter.
///    Main-file decls only — imported / library modules are trusted, matching
///    `checkErrorFlow`.
/// 2. Reserved-type-name binding: a value binding
///    (local/global `var`, a typed-local, or a parameter) spelled as a
///    reserved/builtin type name. See `isReservedTypeName`. Runs over EVERY
///    compiled module (no main-file filter): such a binding mis-lowers the same
///    way wherever declared, so an imported module or the stdlib is no
///    exception.
///
/// Without (1)'s check, `TypeResolver.resolveNamed`'s empty-struct-stub fallback silently
/// fabricates a 0-field struct named after the unknown identifier — so a value
/// param mistakenly used as a type (`(T: Type, …) -> T`, missing the `$`) or a
/// typo'd type name compiles and runs, rendering as `T{}`. Main-file decls only;
/// imported / library modules are trusted, matching `checkErrorFlow`.
///
/// Queries the canonical facts rather than maintaining a parallel authoritative
/// list: declared top-level names come from `ProgramIndex` (runtime classes,
/// generic templates, protocols, aliases) plus the AST decl/scope walk (for
/// LOCAL type decls, which `ProgramIndex` doesn't track); primitives come from
/// `TypeResolver.resolvePrimitive`; registered concrete types from the
/// `TypeTable`. Constructed by value with borrowed references; built only when
/// diagnostics are active.
pub const UnknownTypeChecker = struct {
    alloc: std.mem.Allocator,
    diagnostics: *errors.DiagnosticList,
    types: *TypeTable,
    index: *ProgramIndex,
    main_file: ?[]const u8,
    /// Source that authors the declaration currently being checked. This is
    /// semantic lookup authority, kept separate from the diagnostic renderer's
    /// mutable current file so a previously visited facade cannot reclassify a
    /// main-file protocol constraint (issue 0328).
    author_source: ?[]const u8 = null,
    /// Declared error-set names (`E :: error { ... }`) gathered across every
    /// compiled module + nested scope. Populated in `run`; consulted by the
    /// `.error_type_expr` arm of `checkTypeNodeForUnknown` to tell a valid
    /// `!E` (E a declared set) apart from an undeclared name or a value name
    /// used after `!` in type position (both of which silently fabricate a
    /// zero-field `{}` stub — issue 0189). `null` only before `run` populates it.
    error_sets: ?*const std.StringHashMap(void) = null,
    /// The constructing Lowering, borrowed to fold `inline if` conditions
    /// (`evalComptimeCondition` / `evalComptimeMatch`) so the checker prunes
    /// exactly the branches lowering prunes — a statically-dead `inline if`
    /// branch must not have its type annotations resolved (issue 0290).
    /// `null` (unit tests) keeps the walk-everything behavior.
    lowering: ?*lower.Lowering = null,

    pub fn run(self: UnknownTypeChecker, decls: []const *const Node) void {
        // Reserved-type-name binding diagnostic: rejects any
        // parameter name or `var` / `:=` / typed-local binding name spelled as a
        // reserved/builtin type name. Runs over EVERY compiled module — imported
        // user modules and the stdlib `library/` included — because such a
        // binding mis-lowers identically wherever it is declared: a loaded
        // aggregate passed by value to a `ptr` param → LLVM verifier abort. No
        // main-file filter (unlike the unknown-type check below) and no declared-
        // type / scope context — rejection is purely on spelling. The walk
        // tracks each module's source file (via the diagnostic list's
        // `current_source_file`, saved/restored per node) so an imported-module
        // diagnostic renders against that module's text.
        for (decls) |decl| self.checkBindingNames(decl);

        // Unknown-type diagnostic: main-file decls only; imported
        // and library modules are trusted, matching `checkErrorFlow`.
        var declared = std.StringHashMap(void).init(self.alloc);
        defer declared.deinit();
        self.collectDeclaredTypeNames(decls, &declared);
        // Declared error-set names — every module + nested scope. Used by the
        // `.error_type_expr` arm to validate `!E` (issue 0189). Collected
        // unfiltered (imported sets count: `g :: () -> i64 !LibErr` is valid).
        var error_sets = std.StringHashMap(void).init(self.alloc);
        defer error_sets.deinit();
        for (decls) |decl| self.collectErrorSetNames(decl, &error_sets);
        var checker = self;
        checker.error_sets = &error_sets;
        const saved_file = self.diagnostics.current_source_file;
        defer self.diagnostics.current_source_file = saved_file;
        for (decls) |decl| {
            if (self.main_file) |mf| {
                if (decl.source_file) |sf| {
                    if (!std.mem.eql(u8, sf, mf)) continue;
                }
            }
            // Render against the decl's own module, not the ambient file the
            // previous phase left behind (issue 0122). Main-file AST nodes are
            // intentionally unstamped, so null means `main_file`; it is not
            // permission to retain whichever facade was visited last (0328).
            const author_source = decl.source_file orelse self.main_file;
            if (author_source) |sf| self.diagnostics.current_source_file = sf;
            var decl_checker = checker;
            decl_checker.author_source = author_source;
            switch (decl.data) {
                .fn_decl => decl_checker.checkFnSignatureTypes(&decl.data.fn_decl, &declared),
                .struct_decl => |sd| decl_checker.checkStructDeclTypes(&sd, &declared),
                .impl_block => |ib| for (ib.methods) |method| {
                    if (method.data == .fn_decl) decl_checker.checkFnSignatureTypes(&method.data.fn_decl, &declared);
                },
                .var_decl => |vd| if (vd.value) |v| decl_checker.checkTopLevelValue(v, &declared),
                .const_decl => |cd| switch (cd.value.data) {
                    .fn_decl => decl_checker.checkFnSignatureTypes(&cd.value.data.fn_decl, &declared),
                    .struct_decl => |sd| decl_checker.checkStructDeclTypes(&sd, &declared),
                    // A COMPOSITE type alias — tuple / array / slice / optional
                    // / pointer / many-pointer / function / closure RHS
                    // (`NT :: Tuple(a: i64, b: bool)` issue 0196;
                    // `Bad :: [3]T`, `S :: []T`, `O :: ?T`, `P :: *T`,
                    // `F :: (T) -> U`, `CB :: Closure(T) -> U` issue 0230) —
                    // registers the structural TypeId; an unknown element/
                    // pointee/param/return name would otherwise resolve to a
                    // silent empty-struct stub INSIDE the shape (never patched,
                    // wrong layout at every use). Walk the RHS so
                    // `Bad :: [3]NoSuchType` gets the same "unknown type" the
                    // inline annotation form gets. `checkTypeNodeForUnknown`
                    // recurses every composite position (nested `[2][]T` too).
                    .tuple_type_expr,
                    .array_type_expr,
                    .slice_type_expr,
                    .optional_type_expr,
                    .pointer_type_expr,
                    .many_pointer_type_expr,
                    .function_type_expr,
                    .closure_type_expr,
                    => decl_checker.checkTypeNodeForUnknown(cd.value, &declared, &.{}, &.{}, false),
                    else => decl_checker.checkTopLevelValue(cd.value, &declared),
                },
                else => {},
            }
        }
    }

    /// Gather declared error-set names (`E :: error { ... }`) into `out`, from a
    /// top-level decl and every nested scope (fn / closure bodies, local type
    /// decls). A top-level error set parses as a bare `.error_set_decl`; a
    /// local one is a `.const_decl` whose value is an `.error_set_decl`. Walking
    /// every module (not just the main file) keeps an imported `!LibErr` valid.
    fn collectErrorSetNames(self: UnknownTypeChecker, node: *const Node, out: *std.StringHashMap(void)) void {
        switch (node.data) {
            .error_set_decl => |esd| out.put(esd.name, {}) catch {},
            .const_decl => |cd| {
                if (cd.value.data == .error_set_decl)
                    out.put(cd.value.data.error_set_decl.name, {}) catch {};
                self.collectErrorSetNames(cd.value, out);
            },
            .fn_decl => |fd| self.collectErrorSetNames(fd.body, out),
            .block => |b| for (b.stmts) |s| self.collectErrorSetNames(s, out),
            .if_expr => |ie| {
                self.collectErrorSetNames(ie.then_branch, out);
                if (ie.else_branch) |e| self.collectErrorSetNames(e, out);
            },
            .while_expr => |we| self.collectErrorSetNames(we.body, out),
            .for_expr => |fe| self.collectErrorSetNames(fe.body, out),
            .match_expr => |me| for (me.arms) |arm| self.collectErrorSetNames(arm.body, out),
            .push_stmt => |ps| self.collectErrorSetNames(ps.body, out),
            .lambda => |lm| self.collectErrorSetNames(lm.body, out),
            else => {},
        }
    }

    /// Reserved-type-name binding walk. Visits every node
    /// reachable from `node` and rejects each *binding name* — `var` / `:=` /
    /// typed-local declarations, destructure names, function / lambda / method
    /// parameters, `if` / `while` optional bindings, `for` capture + index
    /// names, match-arm captures, and `catch` / `onfail` tag bindings — whose
    /// spelling collides with a reserved/builtin type name. Such a spelling
    /// parses as a `.type_expr`, so the address-of family in `lower.zig` never
    /// sees the scoped local and mis-lowers it (a loaded aggregate passed
    /// by value to a `ptr` param → LLVM verifier abort, or a silent
    /// mutation-losing copy). Rejecting the name here, before lowering, keeps
    /// the `.identifier`-only address-of paths correct with no lowering
    /// special-case.
    ///
    /// The `switch` is EXHAUSTIVE — every `Node.Data` tag is listed and there
    /// is NO `else` arm. A future binding-bearing node type therefore fails to
    /// compile here until it is handled, so coverage is enforced by the
    /// compiler rather than by remembering to extend a hand-maintained list.
    /// (The check can't live at the scope-registration choke point in
    /// `lower.zig`: lowering is lazy, so an UNCALLED function's bindings never
    /// reach `Scope.put` — yet they must still be rejected at their
    /// declaration.) Deliberately filter-free (every compiled module is walked)
    /// and context-free (spelling is the sole criterion), distinct from the
    /// main-file-scoped unknown-type walk. A node carrying its own
    /// `source_file` (every module's top-level decls do) becomes the emit file
    /// for its whole subtree, restored on exit so a sibling in another module
    /// isn't rendered against it.
    fn checkBindingNames(self: UnknownTypeChecker, node: *const Node) void {
        const saved_file = self.diagnostics.current_source_file;
        defer self.diagnostics.current_source_file = saved_file;
        if (node.source_file) |sf| self.diagnostics.current_source_file = sf;
        switch (node.data) {
            // ── Binding-introducing nodes: check the name(s), then recurse. ──
            // Every site passes the node's own `is_raw` straight to the check —
            // never an `if (!is_raw)` call-site guard — so the check and its
            // exemption are one operation that cannot be threaded apart (0089).
            .var_decl => |vd| {
                self.checkBindingName(vd.name, vd.name_span, vd.is_raw);
                if (vd.value) |v| self.checkBindingNames(v);
            },
            .destructure_decl => |dd| {
                for (dd.names, dd.name_spans, dd.name_is_raw) |n, sp, raw| {
                    self.checkBindingName(n, sp, raw);
                }
                self.checkBindingNames(dd.value);
            },
            .fn_decl => |fd| {
                // A function NAME is a binding site too: a bare reserved-name
                // `i2 :: (…) {…}` (free fn or struct/impl method) is rejected,
                // exactly like `i2 := …`. Backtick (`` `i2 :: … ``) and
                // `#import c` extern fns set `is_raw` and are exempt (0089).
                self.checkBindingName(fd.name, fd.name_span, fd.is_raw);
                self.checkParamNames(fd.params);
                self.checkBindingNames(fd.body);
            },
            .lambda => |lm| {
                self.checkParamNames(lm.params);
                self.checkBindingNames(lm.body);
            },
            .param => |p| {
                self.checkBindingName(p.name, p.name_span, p.is_raw);
                if (p.default_expr) |de| self.checkBindingNames(de);
            },
            .if_expr => |ie| {
                if (ie.binding_name) |bn| self.checkBindingName(bn, ie.binding_span, ie.binding_is_raw);
                self.checkBindingNames(ie.condition);
                self.checkBindingNames(ie.then_branch);
                if (ie.else_branch) |e| self.checkBindingNames(e);
            },
            .while_expr => |we| {
                if (we.binding_name) |bn| self.checkBindingName(bn, we.binding_span, we.binding_is_raw);
                self.checkBindingNames(we.condition);
                self.checkBindingNames(we.body);
            },
            .for_expr => |fe| {
                for (fe.captures) |cap| {
                    if (cap.name.len != 0) self.checkBindingName(cap.name, cap.span, cap.is_raw);
                }
                for (fe.iterables) |it| {
                    self.checkBindingNames(it.expr);
                    if (it.range_end) |re| self.checkBindingNames(re);
                }
                self.checkBindingNames(fe.body);
            },
            .match_expr => |me| {
                self.checkBindingNames(me.subject);
                for (me.arms) |arm| {
                    if (arm.capture) |cap| self.checkBindingName(cap, arm.capture_span, arm.capture_is_raw);
                    if (arm.pattern) |p| self.checkBindingNames(p);
                    self.checkBindingNames(arm.body);
                }
            },
            .match_arm => |arm| {
                if (arm.capture) |cap| self.checkBindingName(cap, arm.capture_span, arm.capture_is_raw);
                if (arm.pattern) |p| self.checkBindingNames(p);
                self.checkBindingNames(arm.body);
            },
            .catch_expr => |ce| {
                if (ce.binding) |b| self.checkBindingName(b, ce.binding_span, ce.binding_is_raw);
                self.checkBindingNames(ce.operand);
                self.checkBindingNames(ce.body);
            },
            .onfail_stmt => |os| {
                if (os.binding) |b| self.checkBindingName(b, os.binding_span, os.binding_is_raw);
                self.checkBindingNames(os.body);
            },
            // impl / protocol-default / runtime-class method bodies: each
            // method introduces its own params + locals. A `#jni_main` /
            // `#objc_class` bodied method is lowered (M1.2), so its reserved
            // param/local names mis-lower the same as any other.
            .impl_block => |ib| for (ib.methods) |m| self.checkBindingNames(m),
            .protocol_decl => |pd| {
                self.checkDeclName(node, pd.name, pd.is_raw);
                for (pd.methods) |m| {
                    if (m.default_body) |body| {
                        for (m.param_names, m.param_name_spans, 0..) |pn, sp, i| {
                            const raw = i < m.param_name_is_raw.len and m.param_name_is_raw[i];
                            self.checkBindingName(pn, sp, raw);
                        }
                        self.checkBindingNames(body);
                    }
                }
            },
            .runtime_class_decl => |fcd| {
                // The sx-side alias (left of `::`) is a user-chosen name, so a
                // reserved spelling is rejected like any other type decl (0089).
                self.checkDeclName(node, fcd.name, fcd.is_raw);
                for (fcd.members) |member| switch (member) {
                    .method => |m| if (m.body) |body| {
                        for (m.param_names, m.param_name_spans, 0..) |pn, sp, i| {
                            const raw = i < m.param_name_is_raw.len and m.param_name_is_raw[i];
                            self.checkBindingName(pn, sp, raw);
                        }
                        self.checkBindingNames(body);
                    },
                    .field, .extends, .implements => {},
                };
            },
            // ── Container / control-flow / expression nodes: recurse children
            //    so a binding nested anywhere below is still reached. ──
            // A namespaced import (`mod :: #import "..."`) is wrapped here, its
            // module decls held inline; descend so an imported module's
            // reserved-name binding is rejected too.
            .namespace_decl => |nd| {
                self.checkDeclName(node, nd.name, nd.is_raw);
                for (nd.decls) |d| self.checkBindingNames(d);
            },
            .const_decl => |cd| {
                // A const BINDS `cd.name`. Reject a bare reserved spelling
                // unless it is backtick-raw (`cd.is_raw`) or the compiler's
                // blessed builtin definition (`string :: []u8 intrinsic`, value
                // `.intrinsic_expr`). When the value node is itself a named decl
                // (struct/enum/union/error/fn), that node carries & checks its
                // own name on recursion — don't double-check it here (0089).
                switch (cd.value.data) {
                    .intrinsic_expr, .struct_decl, .enum_decl, .union_decl, .error_set_decl, .fn_decl => {},
                    else => self.checkBindingName(cd.name, cd.name_span, cd.is_raw),
                }
                self.checkBindingNames(cd.value);
            },
            .struct_decl => |sd| {
                self.checkDeclName(node, sd.name, sd.is_raw);
                for (sd.methods) |m| self.checkBindingNames(m);
                for (sd.constants) |c| self.checkBindingNames(c);
                for (sd.field_defaults) |fdef| if (fdef) |d| self.checkBindingNames(d);
            },
            .root => |r| for (r.decls) |d| self.checkBindingNames(d),
            // A Context-field declaration binds no module-scope name (the field
            // lives in the program-global Context namespace), but its default
            // expression can nest binding-bearing nodes (a lambda's params).
            .context_extend_decl => |ce| if (ce.default_expr) |de| self.checkBindingNames(de),
            .block => |b| for (b.stmts) |s| self.checkBindingNames(s),
            .push_stmt => |ps| {
                self.checkBindingNames(ps.context_expr);
                self.checkBindingNames(ps.body);
            },
            .jni_env_block => |jb| {
                self.checkBindingNames(jb.env);
                self.checkBindingNames(jb.body);
            },
            .defer_stmt => |ds| self.checkBindingNames(ds.expr),
            .return_stmt => |r| if (r.value) |v| self.checkBindingNames(v),
            .raise_stmt => |rs| self.checkBindingNames(rs.tag),
            .assignment => |a| {
                self.checkBindingNames(a.value);
                self.checkBindingNames(a.target);
            },
            .multi_assign => |ma| {
                for (ma.targets) |t| self.checkBindingNames(t);
                for (ma.values) |v| self.checkBindingNames(v);
            },
            .call => |c| {
                self.checkBindingNames(c.callee);
                for (c.args) |a| self.checkBindingNames(a);
            },
            .ffi_intrinsic_call => |fic| for (fic.args) |a| self.checkBindingNames(a),
            .binary_op => |b| {
                self.checkBindingNames(b.lhs);
                self.checkBindingNames(b.rhs);
            },
            .chained_comparison => |cc| for (cc.operands) |o| self.checkBindingNames(o),
            .unary_op => |u| self.checkBindingNames(u.operand),
            .field_access => |fa| self.checkBindingNames(fa.object),
            .index_expr => |ix| {
                self.checkBindingNames(ix.object);
                self.checkBindingNames(ix.index);
            },
            .slice_expr => |sx| {
                self.checkBindingNames(sx.object);
                if (sx.start) |s| self.checkBindingNames(s);
                if (sx.end) |e| self.checkBindingNames(e);
            },
            .struct_literal => |sl| {
                for (sl.field_inits) |fi| self.checkBindingNames(fi.value);
                if (sl.init_block) |ib| self.checkBindingNames(ib);
            },
            .array_literal => |al| for (al.elements) |e| self.checkBindingNames(e),
            .tuple_literal => |tl| for (tl.elements) |e| self.checkBindingNames(e.value),
            .force_unwrap => |fu| self.checkBindingNames(fu.operand),
            .null_coalesce => |nc| {
                self.checkBindingNames(nc.lhs);
                self.checkBindingNames(nc.rhs);
            },
            .deref_expr => |de| self.checkBindingNames(de.operand),
            .postfix_cast => |pc| self.checkBindingNames(pc.operand),
            .try_expr => |te| self.checkBindingNames(te.operand),
            .comptime_expr => |ce| self.checkBindingNames(ce.expr),
            .insert_expr => |ins| self.checkBindingNames(ins.expr),
            .spread_expr => |se| self.checkBindingNames(se.operand),
            .named_arg => |na| self.checkBindingNames(na.value),
            .asm_expr => |ae| {
                self.checkBindingNames(ae.template);
                for (ae.operands) |op| self.checkBindingNames(op.payload);
            },
            .asm_global => |ag| self.checkBindingNames(ag.template),
            // ── Named type / alias / import declarations: a bare reserved
            // spelling as the declared name is rejected. These
            //    have no nested binding sites, so only the name is checked. A
            //    flat `#import`/`#import c` (name == null) binds nothing. ──
            .enum_decl => |ed| self.checkDeclName(node, ed.name, ed.is_raw),
            .union_decl => |ud| self.checkDeclName(node, ud.name, ud.is_raw),
            .error_set_decl => |esd| self.checkDeclName(node, esd.name, esd.is_raw),
            .ufcs_alias => |ua| self.checkDeclName(node, ua.name, ua.is_raw),
            .library_decl => |ld| self.checkDeclName(node, ld.name, ld.is_raw),
            .import_decl => |imp| if (imp.name) |n| self.checkDeclName(node, n, imp.is_raw),
            .c_import_decl => |cid| if (cid.name) |n| self.checkDeclName(node, n, cid.is_raw),
            // ── Leaves & pure type-expression nodes: no binding sites below. ──
            // Type-expression subtrees carry only type names (no value
            // bindings). Listing each tag explicitly (rather than an `else`) is
            // what forces a future binding-bearing node to be reconsidered here.
            .int_literal,
            .float_literal,
            .bool_literal,
            .string_literal,
            .char_literal,
            .identifier,
            .enum_literal,
            .type_expr,
            .array_type_expr,
            .slice_type_expr,
            .parameterized_type_expr,
            .pointer_type_expr,
            .many_pointer_type_expr,
            .optional_type_expr,
            .error_type_expr,
            .caller_location,
            .error_directive,
            .pack_index_type_expr,
            .comptime_pack_ref,
            .null_literal,
            .break_expr,
            .continue_expr,
            .undef_literal,
            .inferred_type,
            .intrinsic_expr,
            .framework_decl,
            .function_type_expr,
            .closure_type_expr,
            .tuple_type_expr,
            .return_type_expr,
            => {},
        }
    }

    /// Check each parameter's binding name (`fn` / lambda params are stored as
    /// `Param` values, not child nodes, so they're walked here rather than via
    /// the node `switch`). A param default expression can itself nest bindings
    /// (a lambda default), so recurse into it.
    fn checkParamNames(self: UnknownTypeChecker, params: []const ast.Param) void {
        for (params) |p| {
            // A backtick raw param (`` (`i2: T) ``) or a `#import c` extern
            // param is exempt from the reserved-type-name rule —
            // the exemption is honored inside `checkBindingName` via `p.is_raw`.
            self.checkBindingName(p.name, p.name_span, p.is_raw);
            if (p.default_expr) |de| self.checkBindingNames(de);
        }
    }

    /// Collect every top-level name that can legitimately appear in a type
    /// position: const-decl names (covers `T :: struct/enum/union/error/alias`
    /// and value consts), plus the scan-populated runtime-class / generic-
    /// template / protocol / alias maps from `ProgramIndex`. Built across ALL
    /// files so a main-file reference to an imported type isn't flagged.
    fn collectDeclaredTypeNames(self: UnknownTypeChecker, decls: []const *const Node, out: *std.StringHashMap(void)) void {
        for (decls) |decl| {
            switch (decl.data) {
                .const_decl => |cd| {
                    // Only a const whose VALUE introduces a type (a type decl or
                    // type-expression alias) declares a type name. A value const
                    // like `NotAType :: 123` must NOT satisfy the unknown-type
                    // check.
                    if (constValueIntroducesType(cd.value)) out.put(cd.name, {}) catch {};
                    if (cd.value.data == .fn_decl) self.harvestScopeDecls(cd.value.data.fn_decl.body, out);
                },
                .struct_decl => |sd| out.put(sd.name, {}) catch {},
                .fn_decl => |fd| self.harvestScopeDecls(fd.body, out),
                else => {},
            }
        }
        var it_fc = self.index.runtime_class_map.keyIterator();
        while (it_fc.next()) |k| out.put(k.*, {}) catch {};
        var it_tmpl = self.index.struct_template_map.keyIterator();
        while (it_tmpl.next()) |k| out.put(k.*, {}) catch {};
        var it_pd = self.index.protocol_decl_map.keyIterator();
        while (it_pd.next()) |k| out.put(k.*, {}) catch {};
        var it_pa = self.index.protocol_ast_map.keyIterator();
        while (it_pa.next()) |k| out.put(k.*, {}) catch {};
        var it_al = self.index.type_alias_map.keyIterator();
        while (it_al.next()) |k| out.put(k.*, {}) catch {};
    }

    /// Harvest every type-declaration name (local `T :: struct/enum/union` and
    /// named consts) anywhere in a function body — including inside nested
    /// closure / function bodies — into the global declared set, so a type
    /// annotation in any scope that references one isn't flagged. Over-collection
    /// is safe: it only ever relaxes the unknown-type check, never tightens it.
    fn harvestScopeDecls(self: UnknownTypeChecker, node: *const Node, out: *std.StringHashMap(void)) void {
        switch (node.data) {
            .block => |b| for (b.stmts) |s| self.harvestScopeDecls(s, out),
            .if_expr => |ie| {
                self.harvestScopeDecls(ie.condition, out);
                self.harvestScopeDecls(ie.then_branch, out);
                if (ie.else_branch) |e| self.harvestScopeDecls(e, out);
            },
            .while_expr => |we| {
                self.harvestScopeDecls(we.condition, out);
                self.harvestScopeDecls(we.body, out);
            },
            .for_expr => |fe| {
                for (fe.iterables) |it| {
                    self.harvestScopeDecls(it.expr, out);
                    if (it.range_end) |re| self.harvestScopeDecls(re, out);
                }
                self.harvestScopeDecls(fe.body, out);
            },
            .match_expr => |me| {
                self.harvestScopeDecls(me.subject, out);
                for (me.arms) |arm| self.harvestScopeDecls(arm.body, out);
            },
            .push_stmt => |ps| {
                self.harvestScopeDecls(ps.context_expr, out);
                self.harvestScopeDecls(ps.body, out);
            },
            .defer_stmt => |ds| self.harvestScopeDecls(ds.expr, out),
            .onfail_stmt => |os| self.harvestScopeDecls(os.body, out),
            .return_stmt => |r| if (r.value) |v| self.harvestScopeDecls(v, out),
            .raise_stmt => |rs| self.harvestScopeDecls(rs.tag, out),
            .assignment => |a| {
                self.harvestScopeDecls(a.value, out);
                self.harvestScopeDecls(a.target, out);
            },
            .multi_assign => |ma| for (ma.values) |v| self.harvestScopeDecls(v, out),
            .destructure_decl => |dd| self.harvestScopeDecls(dd.value, out),
            .var_decl => |vd| if (vd.value) |v| self.harvestScopeDecls(v, out),
            .const_decl => |cd| {
                // Local type decl (`T :: struct/enum/union/error/alias`) — add
                // its name; a local VALUE const (`x :: 5`) does not declare a
                // type. Recurse regardless, to harvest nested decls
                // (e.g. type decls inside a `f :: () { ... }` body).
                if (constValueIntroducesType(cd.value)) out.put(cd.name, {}) catch {};
                self.harvestScopeDecls(cd.value, out);
            },
            .struct_decl => |sd| out.put(sd.name, {}) catch {},
            .enum_decl => |ed| out.put(ed.name, {}) catch {},
            .union_decl => |ud| out.put(ud.name, {}) catch {},
            .call => |c| {
                self.harvestScopeDecls(c.callee, out);
                for (c.args) |a| self.harvestScopeDecls(a, out);
            },
            .binary_op => |b| {
                self.harvestScopeDecls(b.lhs, out);
                self.harvestScopeDecls(b.rhs, out);
            },
            .unary_op => |u| self.harvestScopeDecls(u.operand, out),
            .field_access => |fa| self.harvestScopeDecls(fa.object, out),
            .index_expr => |ix| {
                self.harvestScopeDecls(ix.object, out);
                self.harvestScopeDecls(ix.index, out);
            },
            .struct_literal => |sl| {
                for (sl.field_inits) |fi| self.harvestScopeDecls(fi.value, out);
                if (sl.init_block) |ib| self.harvestScopeDecls(ib, out);
            },
            .array_literal => |al| for (al.elements) |e| self.harvestScopeDecls(e, out),
            .force_unwrap => |fu| self.harvestScopeDecls(fu.operand, out),
            .null_coalesce => |nc| {
                self.harvestScopeDecls(nc.lhs, out);
                self.harvestScopeDecls(nc.rhs, out);
            },
            .deref_expr => |de| self.harvestScopeDecls(de.operand, out),
            .postfix_cast => |pc| self.harvestScopeDecls(pc.operand, out),
            .try_expr => |te| self.harvestScopeDecls(te.operand, out),
            .catch_expr => |ce| {
                self.harvestScopeDecls(ce.operand, out);
                self.harvestScopeDecls(ce.body, out);
            },
            .comptime_expr => |ce| self.harvestScopeDecls(ce.expr, out),
            .spread_expr => |se| self.harvestScopeDecls(se.operand, out),
            .named_arg => |na| self.harvestScopeDecls(na.value, out),
            .lambda => |lm| self.harvestScopeDecls(lm.body, out),
            .fn_decl => |fd| self.harvestScopeDecls(fd.body, out),
            else => {},
        }
    }

    fn checkStructFieldTypes(self: UnknownTypeChecker, sd: *const ast.StructDecl, declared: *std.StringHashMap(void)) void {
        // A generic struct's field types may reference its own type params
        // (`$T`, `$N`, the `..$Ts` pack) — those are IN SCOPE here, so pass them
        // through rather than skipping the whole decl. Skipping silently let a
        // genuinely-undeclared field type (`bad: MissingType`) fall through the
        // type leaf's empty-struct stub and compile (stdlib E3). A value-param
        // position (a `Vector` lane count, a `$N: u32` arg) is still skipped
        // inside `checkTypeNodeForUnknown` / `isValueParamPosition`.
        for (sd.field_types) |ft| self.checkTypeNodeForUnknown(ft, declared, sd.type_params, &.{}, true);
    }

    fn checkTopLevelValue(self: UnknownTypeChecker, value: *const Node, declared: *std.StringHashMap(void)) void {
        var in_scope = std.ArrayList(ast.StructTypeParam).empty;
        defer in_scope.deinit(self.alloc);
        var type_vals = std.ArrayList([]const u8).empty;
        defer type_vals.deinit(self.alloc);
        self.walkBodyTypes(value, declared, &in_scope, &type_vals);
    }

    fn checkStructDeclTypes(self: UnknownTypeChecker, sd: *const ast.StructDecl, declared: *std.StringHashMap(void)) void {
        self.checkStructFieldTypes(sd, declared);
        var in_scope = std.ArrayList(ast.StructTypeParam).empty;
        defer in_scope.deinit(self.alloc);
        for (sd.type_params) |tp| in_scope.append(self.alloc, tp) catch {};
        var type_vals = std.ArrayList([]const u8).empty;
        defer type_vals.deinit(self.alloc);
        for (sd.field_defaults) |default| if (default) |value| self.walkBodyTypes(value, declared, &in_scope, &type_vals);
        for (sd.methods) |method| {
            if (method.data == .fn_decl) {
                const fd = &method.data.fn_decl;
                self.checkScope(fd.type_params, fd.params, fd.return_type, fd.body, declared, &in_scope, &type_vals);
            }
        }
    }

    fn checkFnSignatureTypes(self: UnknownTypeChecker, fd: *const ast.FnDecl, declared: *std.StringHashMap(void)) void {
        var in_scope = std.ArrayList(ast.StructTypeParam).empty;
        defer in_scope.deinit(self.alloc);
        var type_vals = std.ArrayList([]const u8).empty;
        defer type_vals.deinit(self.alloc);
        self.checkScope(fd.type_params, fd.params, fd.return_type, fd.body, declared, &in_scope, &type_vals);
    }

    /// Check one function/closure scope: its generic params (`$T`) and value-
    /// `Type` params become in-scope (accumulated onto the parent's, so a nested
    /// closure still sees the outer function's `$T`), its param/return
    /// annotations are checked, then its body is walked. The scope additions are
    /// popped on return.
    fn checkScope(
        self: UnknownTypeChecker,
        type_params: []const ast.StructTypeParam,
        params: []const ast.Param,
        return_type: ?*Node,
        body: *const Node,
        declared: *std.StringHashMap(void),
        in_scope: *std.ArrayList(ast.StructTypeParam),
        type_vals: *std.ArrayList([]const u8),
    ) void {
        const save_s = in_scope.items.len;
        const save_v = type_vals.items.len;
        defer in_scope.shrinkRetainingCapacity(save_s);
        defer type_vals.shrinkRetainingCapacity(save_v);
        for (type_params) |tp| in_scope.append(self.alloc, tp) catch {};
        // Value params declared `: Type` (no `$`) — using one in a type position
        // is the $-prefix-in-cast-position misuse; track them for the tailored hint.
        for (params) |p| {
            if (p.type_expr.data == .type_expr) {
                const cn = p.type_expr.data.type_expr.name;
                if (std.mem.eql(u8, cn, "Type") or std.mem.eql(u8, cn, "type")) {
                    type_vals.append(self.alloc, p.name) catch {};
                }
            }
        }
        for (params) |p| self.checkTypeNodeForUnknown(p.type_expr, declared, in_scope.items, type_vals.items, false);
        for (params) |p| if (p.default_expr) |default| self.walkBodyTypes(default, declared, in_scope, type_vals);
        if (return_type) |rt| self.checkTypeNodeForUnknown(rt, declared, in_scope.items, type_vals.items, false);
        self.walkBodyTypes(body, declared, in_scope, type_vals);
    }

    /// Walk a scope body checking type annotations on local var / const
    /// declarations (and body-local struct fields), descending control flow and
    /// expressions. Nested closure / function literals re-enter via `checkScope`
    /// with their own params added to `in_scope`.
    fn walkBodyTypes(
        self: UnknownTypeChecker,
        node: *const Node,
        declared: *std.StringHashMap(void),
        in_scope: *std.ArrayList(ast.StructTypeParam),
        type_vals: *std.ArrayList([]const u8),
    ) void {
        switch (node.data) {
            .block => |b| for (b.stmts) |s| self.walkBodyTypes(s, declared, in_scope, type_vals),
            .if_expr => |ie| {
                self.walkBodyTypes(ie.condition, declared, in_scope, type_vals);
                // A statically-decided `inline if` lowers only the taken
                // branch (lowerIfExpr's evalComptimeCondition gate), so only
                // that branch's annotations are live — a type behind a
                // disabled target/feature must not error from the dead
                // branch (issue 0290). Unfoldable conditions walk both.
                const live: ?bool = if (ie.is_comptime)
                    (if (self.lowering) |l| l.evalComptimeCondition(ie.condition) else null)
                else
                    null;
                if (live) |is_true| {
                    if (is_true) {
                        self.walkBodyTypes(ie.then_branch, declared, in_scope, type_vals);
                    } else if (ie.else_branch) |e| {
                        self.walkBodyTypes(e, declared, in_scope, type_vals);
                    }
                } else {
                    self.walkBodyTypes(ie.then_branch, declared, in_scope, type_vals);
                    if (ie.else_branch) |e| self.walkBodyTypes(e, declared, in_scope, type_vals);
                }
            },
            .while_expr => |we| {
                self.walkBodyTypes(we.condition, declared, in_scope, type_vals);
                self.walkBodyTypes(we.body, declared, in_scope, type_vals);
            },
            .for_expr => |fe| {
                for (fe.iterables) |it| {
                    self.walkBodyTypes(it.expr, declared, in_scope, type_vals);
                    if (it.range_end) |re| self.walkBodyTypes(re, declared, in_scope, type_vals);
                }
                self.walkBodyTypes(fe.body, declared, in_scope, type_vals);
            },
            .match_expr => |me| {
                self.walkBodyTypes(me.subject, declared, in_scope, type_vals);
                // Comptime match (`inline if x == { case … }`): only the
                // matching arm is lowered — mirror lowerMatch (issue 0290).
                if (me.is_comptime) {
                    if (self.lowering) |l| {
                        if (l.evalComptimeMatch(&me)) |arm_body| {
                            self.walkBodyTypes(arm_body, declared, in_scope, type_vals);
                            return;
                        }
                    }
                }
                for (me.arms) |arm| self.walkBodyTypes(arm.body, declared, in_scope, type_vals);
            },
            .push_stmt => |ps| {
                self.walkBodyTypes(ps.context_expr, declared, in_scope, type_vals);
                self.walkBodyTypes(ps.body, declared, in_scope, type_vals);
            },
            .defer_stmt => |ds| self.walkBodyTypes(ds.expr, declared, in_scope, type_vals),
            .onfail_stmt => |os| self.walkBodyTypes(os.body, declared, in_scope, type_vals),
            .return_stmt => |r| if (r.value) |v| self.walkBodyTypes(v, declared, in_scope, type_vals),
            .raise_stmt => |rs| self.walkBodyTypes(rs.tag, declared, in_scope, type_vals),
            .assignment => |a| {
                self.walkBodyTypes(a.value, declared, in_scope, type_vals);
                self.walkBodyTypes(a.target, declared, in_scope, type_vals);
            },
            .multi_assign => |ma| for (ma.values) |v| self.walkBodyTypes(v, declared, in_scope, type_vals),
            .destructure_decl => |dd| self.walkBodyTypes(dd.value, declared, in_scope, type_vals),
            .var_decl => |vd| {
                if (vd.type_annotation) |ta| self.checkTypeNodeForUnknown(ta, declared, in_scope.items, type_vals.items, false);
                if (vd.value) |v| self.walkBodyTypes(v, declared, in_scope, type_vals);
            },
            .const_decl => |cd| {
                if (cd.type_annotation) |ta| self.checkTypeNodeForUnknown(ta, declared, in_scope.items, type_vals.items, false);
                self.walkBodyTypes(cd.value, declared, in_scope, type_vals);
            },
            .struct_decl => |sd| {
                // A body-local struct's own type params (`$T`) join the enclosing
                // scope's in-scope params (so a local generic struct can name both
                // the outer fn's `$T` and its own); any OTHER bare field type is
                // still a genuinely-undeclared type. Mirrors the top-level
                // `checkStructFieldTypes` close of the generic-struct carveout.
                const save = in_scope.items.len;
                defer in_scope.shrinkRetainingCapacity(save);
                for (sd.type_params) |tp| in_scope.append(self.alloc, tp) catch {};
                for (sd.field_types) |ft| self.checkTypeNodeForUnknown(ft, declared, in_scope.items, type_vals.items, true);
            },
            .call => |c| {
                self.walkBodyTypes(c.callee, declared, in_scope, type_vals);
                for (c.args) |a| self.walkBodyTypes(a, declared, in_scope, type_vals);
            },
            .binary_op => |b| {
                self.walkBodyTypes(b.lhs, declared, in_scope, type_vals);
                self.walkBodyTypes(b.rhs, declared, in_scope, type_vals);
            },
            .unary_op => |u| self.walkBodyTypes(u.operand, declared, in_scope, type_vals),
            .field_access => |fa| self.walkBodyTypes(fa.object, declared, in_scope, type_vals),
            .index_expr => |ix| {
                self.walkBodyTypes(ix.object, declared, in_scope, type_vals);
                self.walkBodyTypes(ix.index, declared, in_scope, type_vals);
            },
            .struct_literal => |sl| {
                // A NAMED struct-literal head (`Point.{ … }`) names its type
                // exactly like a declaration annotation — validate it through the
                // same unknown-type walk. Without this, an undeclared literal type
                // name (`NoSuchType.{ a = 1 }`) bypassed the checker (the main-file
                // diagnostic authority) and reached `resolveNominalLeaf`'s
                // `.undeclared` main-file arm, which keeps the legacy empty-struct
                // stub and defers to THIS checker — so nothing diagnosed it and the
                // literal silently compiled with a 0-field struct, dropping every
                // field (issue 0220). `struct_name` is always a bare, non-raw
                // identifier (the parser only sets it for the simple-name form;
                // `mod.Type.{…}` and `Gen(args).{…}` carry `type_expr` instead,
                // resolved+diagnosed on the lowering path). `reportIfUnknownType`
                // skips forward-refs (`declared`), in-scope generics, value params,
                // builtins, and aliases — so only genuinely-undeclared names fire,
                // mirroring the typed-array-literal head guard just below.
                if (sl.struct_name) |sname|
                    self.reportIfUnknownType(sname, node.span, declared, in_scope.items, type_vals.items, false);
                if (sl.type_expr) |th| self.checkTypeNodeForUnknown(th, declared, in_scope.items, type_vals.items, false);
                for (sl.field_inits) |fi| self.walkBodyTypes(fi.value, declared, in_scope, type_vals);
                if (sl.init_block) |ib| self.walkBodyTypes(ib, declared, in_scope, type_vals);
            },
            .array_literal => |al| {
                // A TYPED array/slice literal head (`([N]T).[…]` / `([]T).[…]`)
                // names its element type exactly like a declaration annotation —
                // validate it through the same unknown-type walk. Without this,
                // an undefined element name (`([2]?Undefined).[…]`) bypassed the
                // checker and reached the lowering's forward-ref stub, silently
                // compiling with an empty-struct element instead of erroring
                // like the `x: [2]?Undefined` declaration path (issues 0173–0175
                // adversarial review). `checkTypeNodeForUnknown` recurses the
                // `[N]?T` / `[]T` head down to its leaf type name and skips
                // forward-refs (`declared`), generics (`in_scope`), aliases, and
                // parameterized element types — so only genuinely-undeclared
                // names are flagged.
                if (al.type_expr) |th| self.checkTypeNodeForUnknown(th, declared, in_scope.items, type_vals.items, false);
                for (al.elements) |e| self.walkBodyTypes(e, declared, in_scope, type_vals);
            },
            .force_unwrap => |fu| self.walkBodyTypes(fu.operand, declared, in_scope, type_vals),
            .null_coalesce => |nc| {
                self.walkBodyTypes(nc.lhs, declared, in_scope, type_vals);
                self.walkBodyTypes(nc.rhs, declared, in_scope, type_vals);
            },
            .deref_expr => |de| self.walkBodyTypes(de.operand, declared, in_scope, type_vals),
            // Postfix cast: the written target is a TYPE position.
            .postfix_cast => |pc| {
                self.walkBodyTypes(pc.operand, declared, in_scope, type_vals);
                self.checkTypeNodeForUnknown(pc.type_expr, declared, in_scope.items, type_vals.items, false);
            },
            .try_expr => |te| self.walkBodyTypes(te.operand, declared, in_scope, type_vals),
            .catch_expr => |ce| {
                self.walkBodyTypes(ce.operand, declared, in_scope, type_vals);
                self.walkBodyTypes(ce.body, declared, in_scope, type_vals);
            },
            .comptime_expr => |ce| self.walkBodyTypes(ce.expr, declared, in_scope, type_vals),
            .spread_expr => |se| self.walkBodyTypes(se.operand, declared, in_scope, type_vals),
            .named_arg => |na| self.walkBodyTypes(na.value, declared, in_scope, type_vals),
            .lambda => |lm| self.checkScope(lm.type_params, lm.params, lm.return_type, lm.body, declared, in_scope, type_vals),
            .fn_decl => |fd| self.checkScope(fd.type_params, fd.params, fd.return_type, fd.body, declared, in_scope, type_vals),
            else => {},
        }
    }

    /// True when a generic param names a TYPE (so its name may appear in a type
    /// position), false for a VALUE param (`$N: u32`) whose name is a
    /// compile-time integer. A type param is `..$Ts` (the `[]Type` pack), or a
    /// `Type`/protocol-constrained `$T` (`$T: Type`, `$T: Lerpable`). Mirrors the
    /// binder's template-param classification (`lower.zig`); the protocol cases
    /// keep a `$T: SomeProtocol` field type from being wrongly rejected.
    fn isTypeParam(self: UnknownTypeChecker, tp: ast.StructTypeParam) bool {
        if (tp.is_variadic) return true;
        if (tp.constraint.data == .type_expr) {
            const cname = tp.constraint.data.type_expr.name;
            if (std.mem.eql(u8, cname, "Type")) return true;
            if (self.lowering) |l| {
                const source = tp.constraint.source_file orelse self.author_source orelse self.diagnostics.current_source_file;
                return l.isProtocolConstraint(cname, source);
            }
            return self.index.protocol_decl_map.contains(cname) or
                self.index.protocol_ast_map.contains(cname);
        }
        return false;
    }

    /// A struct field / fn annotation that names an in-scope generic VALUE param
    /// (`$N: u32`) in a TYPE position is invalid — the name is a compile-time
    /// integer, not a type. The parser marks such a reference `is_generic`
    /// (same as a real type param), so the unknown-type walk would otherwise skip
    /// it and let it reach the `.unresolved` sentinel. Emit the tailored hint; a
    /// genuine type-param reference (or a fresh inline `$R`, not in scope) passes.
    fn reportIfValueParamInTypePosition(self: UnknownTypeChecker, name: []const u8, span: ?ast.Span, in_scope: []const ast.StructTypeParam, struct_field: bool) void {
        for (in_scope) |tp| {
            if (!std.mem.eql(u8, tp.name, name)) continue;
            if (self.isTypeParam(tp)) return;
            self.diagnostics.addFmt(.err, span, "'{s}' is a value parameter, not a type; introduce a generic type parameter with `${s}: Type`", .{ name, name });
            return;
        }
        // Not in scope. In a struct FIELD position, an `is_generic` name can
        // only be a literal `$T` sigil (a bare name matching a header type param
        // would have been found above) — and a struct field cannot introduce a
        // fresh type parameter the way a function param can. Left undiagnosed it
        // resolves to `.unresolved` and panics at LLVM emission (issue 0278).
        // Declare the parameter in the struct header and reference it bare.
        if (struct_field) {
            self.diagnostics.addFmt(.err, span, "'${s}' cannot introduce a type parameter in a struct field; declare it in the struct header with `struct (${s}: Type) {{ ... }}` and reference it as `{s}`", .{ name, name, name });
        }
    }

    /// True when arg `i` of a parameterized type `base(...)` is a VALUE
    /// parameter (a compile-time integer such as a `Vector` lane count or a
    /// generic `$N: u32` arg), not a type. Such a position must be skipped by
    /// the unknown-type walk: a module-const arg (`Vector(N, f32)`) is a value,
    /// not a type name. `Vector`'s arg 0 is always its lane count; a generic
    /// struct template's value-param positions come from its declared params; a
    /// type-RETURNING function (`Make :: ($K: u32, $T: Type) -> Type`) classifies
    /// each param from its constraint, mirroring `instantiateTypeFunction` — so
    /// `Make(N, i64)` (N a module const) is not walked as the type name "N".
    /// Type-returning reflection builtins legal in a type position with
    /// VALUE arguments. Mirrors the lowering's comptime type-fn set.
    fn isTypeFnName(name: []const u8) bool {
        const type_fns = [_][]const u8{ "type_of", "struct_field_type", "variant_type", "pointee_type" };
        for (type_fns) |tf| if (std.mem.eql(u8, name, tf)) return true;
        return false;
    }

    fn isValueParamPosition(self: UnknownTypeChecker, base: []const u8, i: usize) bool {
        if (std.mem.eql(u8, base, "Vector")) return i == 0;
        if (self.index.struct_template_map.get(base)) |tmpl| {
            if (i < tmpl.type_params.len) return !tmpl.type_params[i].is_type_param;
        }
        if (self.index.fn_ast_map.get(base)) |fd| {
            if (i < fd.type_params.len) {
                const tp = fd.type_params[i];
                // A value param is one whose constraint is a non-`Type` type
                // expr (`$K: u32`); a `$T: Type` (or any non-type-expr
                // constraint) is a type param — identical rule to the binder.
                const is_type_param = if (tp.constraint.data == .type_expr)
                    std.mem.eql(u8, tp.constraint.data.type_expr.name, "Type")
                else
                    true;
                return !is_type_param;
            }
        }
        return false;
    }

    /// Recurse a type-annotation node to its leaf names, reporting any unknown.
    /// `struct_field` is true when this annotation sits in a struct FIELD type
    /// position — where a `$T` sigil cannot introduce a fresh type parameter
    /// (unlike a function param, which may). A struct's type params must be
    /// declared in its header; a `$T` field naming no in-scope param is invalid
    /// and would otherwise reach the `.unresolved` sentinel (LLVM panic).
    fn checkTypeNodeForUnknown(
        self: UnknownTypeChecker,
        node: *const Node,
        declared: *std.StringHashMap(void),
        in_scope: []const ast.StructTypeParam,
        type_vals: []const []const u8,
        struct_field: bool,
    ) void {
        switch (node.data) {
            // A `$`-prefixed / struct-param-matched name (`-> $R`, or a field
            // `x: T` naming the struct's own `$T`) is marked `is_generic` by the
            // parser and is normally a valid type-param reference. But the parser
            // marks a struct VALUE param (`$N: u32`) the SAME way, so `x: N` would
            // slip past the unknown-type check and reach the `.unresolved`
            // sentinel (LLVM panic). Catch that one case; a genuine type-param
            // reference still passes.
            .type_expr => |te| if (!te.is_generic)
                self.reportIfUnknownType(te.name, node.span, declared, in_scope, type_vals, te.is_raw)
            else
                self.reportIfValueParamInTypePosition(te.name, node.span, in_scope, struct_field),
            .identifier => |id| self.reportIfUnknownType(id.name, node.span, declared, in_scope, type_vals, id.is_raw),
            .pointer_type_expr => |pt| self.checkTypeNodeForUnknown(pt.pointee_type, declared, in_scope, type_vals, struct_field),
            .many_pointer_type_expr => |mp| self.checkTypeNodeForUnknown(mp.element_type, declared, in_scope, type_vals, struct_field),
            .slice_type_expr => |st| self.checkTypeNodeForUnknown(st.element_type, declared, in_scope, type_vals, struct_field),
            .optional_type_expr => |ot| self.checkTypeNodeForUnknown(ot.inner_type, declared, in_scope, type_vals, struct_field),
            .array_type_expr => |at| self.checkTypeNodeForUnknown(at.element_type, declared, in_scope, type_vals, struct_field),
            .tuple_type_expr => |tt| for (tt.field_types) |ft| self.checkTypeNodeForUnknown(ft, declared, in_scope, type_vals, struct_field),
            .function_type_expr => |ft| {
                for (ft.param_types) |pt| self.checkTypeNodeForUnknown(pt, declared, in_scope, type_vals, struct_field);
                if (ft.return_type) |rt| self.checkTypeNodeForUnknown(rt, declared, in_scope, type_vals, struct_field);
            },
            .closure_type_expr => |ct| {
                // Variadic type-pack closures (`Closure(..$args) -> R`) resolve
                // their projections specially — don't walk them here.
                if (ct.pack_name != null) return;
                for (ct.param_types) |pt| self.checkTypeNodeForUnknown(pt, declared, in_scope, type_vals, struct_field);
                if (ct.return_type) |rt| self.checkTypeNodeForUnknown(rt, declared, in_scope, type_vals, struct_field);
            },
            // Builtin constructors (Vector) and generic templates resolve the
            // base name specially; check only the TYPE args. A value-param
            // position (a `Vector` lane count, or a generic `$N: u32` arg) holds
            // a compile-time integer — `Vector(N, f32)` / `Vec(N, f32)` with `N`
            // a module const — not a type name, so it must not be walked as one
            // (it would falsely report "unknown type 'N'"). The lowering
            // resolvers fold the value and emit the precise diagnostic if it
            // isn't a compile-time integer.
            .parameterized_type_expr => |pt| {
                const base = if (std.mem.lastIndexOfScalar(u8, pt.name, '.')) |dot| pt.name[dot + 1 ..] else pt.name;
                // A Type-returning reflection builtin in type position
                // (`x.(struct_field_type(T, i))`) takes VALUE args (indices,
                // comptime cursors) — never walk them as type names; the
                // lowering fold diagnoses a bad arg precisely.
                if (isTypeFnName(base)) return;
                for (pt.args, 0..) |a, i| {
                    if (self.isValueParamPosition(base, i)) continue;
                    self.checkTypeNodeForUnknown(a, declared, in_scope, type_vals, struct_field);
                }
            },
            // `!E` (named failable channel) in type position. A bare `!`
            // (name == null) is the inferred/void channel and is always valid.
            // A named `!E` is valid ONLY when `E` is a declared error set;
            // otherwise the lowering path silently fabricates a zero-field
            // `{}` stub (issue 0189), so reject it here with a precise
            // diagnostic — "unknown error set" for an undeclared name, "expected
            // an error set" for a name that resolves to a non-error-set type or
            // a value.
            .error_type_expr => |ete| if (ete.name) |name|
                self.reportIfNotErrorSet(name, node.span),
            else => {},
        }
    }

    /// Validate the `E` in an `!E` type. `E` must be a declared error set.
    /// Distinguishes three failure shapes so the user gets an actionable
    /// message: an undeclared name (`unknown error set`), and a declared name
    /// that is NOT an error set — a value or a non-error-set type (`expected an
    /// error set`). Mirrors the silent-fabrication guard for `g.a` in
    /// `resolveTypeWithBindings` (issue 0189): never let a non-error-set name
    /// after `!` reach the lowering stub.
    fn reportIfNotErrorSet(self: UnknownTypeChecker, name: []const u8, span: ?ast.Span) void {
        // Inline-spelled / qualified spellings (`mod.E`) carry non-identifier
        // characters — trust them, matching `reportIfUnknownType`.
        if (!isIdentLike(name)) return;
        const sets = self.error_sets orelse return;
        if (sets.contains(name)) return;
        // A name that names a real (non-error-set) TYPE — a struct/enum/union,
        // a builtin, or a fabricated stub — is a type-in-error-position misuse.
        if (isBuiltinTypeName(name)) {
            self.diagnostics.addFmt(.err, span, "expected an error set after '!', found type '{s}'", .{name});
            return;
        }
        const sid = self.types.internString(name);
        if (self.types.findByName(sid)) |_| {
            self.diagnostics.addFmt(.err, span, "expected an error set after '!', found type '{s}'", .{name});
            return;
        }
        // Otherwise the name is undeclared (or names a value): no error-set
        // author anywhere. Either way it is not a usable error set.
        self.diagnostics.addFmt(.err, span, "unknown error set '{s}'", .{name});
    }

    fn reportIfUnknownType(
        self: UnknownTypeChecker,
        name: []const u8,
        span: ?ast.Span,
        declared: *std.StringHashMap(void),
        in_scope: []const ast.StructTypeParam,
        type_vals: []const []const u8,
        is_raw: bool,
    ) void {
        // Only bare identifiers are validated. Inline-spelled compound types
        // (`[:0]u8`, `mod.Type`, …) carry non-identifier characters — trust them.
        if (!isIdentLike(name)) return;
        // A backtick raw reference (`` `i2 ``) is the LITERAL name used as a
        // type — explicitly NOT the builtin/reserved spelling — so it must
        // resolve to a `` `i2 ``-declared type, else a normal "unknown type"
        // error. Skip the builtin-name exemption that would otherwise wave a
        // bare `i2` through.
        if (!is_raw and isBuiltinTypeName(name)) return;
        for (in_scope) |tp| {
            if (!std.mem.eql(u8, tp.name, name)) continue;
            // A TYPE param (`$T: Type`, `$T: SomeProtocol`, the `..$Ts` pack)
            // names a type and is valid in this position. A VALUE param
            // (`$N: u32`) is a compile-time integer, NOT a type — accepting it
            // would let the field's type leaf resolve to the `.unresolved`
            // sentinel and panic at LLVM emission. Emit the tailored hint.
            if (self.isTypeParam(tp)) return;
            self.diagnostics.addFmt(.err, span, "'{s}' is a value parameter, not a type; introduce a generic type parameter with `${s}: Type`", .{ name, name });
            return;
        }
        if (declared.contains(name)) return;
        // Registered as a real (non-stub) type — covers imported concrete
        // structs / enums / unions absent from the main-file decl list. A
        // fabricated empty-struct stub (the very thing we're catching) is the
        // sole 0-field-struct case, so it doesn't suppress the diagnostic.
        const sid = self.types.internString(name);
        if (self.types.findByName(sid)) |tid| {
            const info = self.types.get(tid);
            const empty_struct_stub = info == .@"struct" and info.@"struct".fields.len == 0;
            if (!empty_struct_stub) return;
        }
        for (type_vals) |tv| {
            if (std.mem.eql(u8, tv, name)) {
                self.diagnostics.addFmt(.err, span, "'{s}' is a value parameter, not a type; introduce a generic type parameter with `${s}: Type`", .{ name, name });
                return;
            }
        }
        self.diagnostics.addFmt(.err, span, "unknown type '{s}'", .{name});
    }

    /// Reject a value binding (local/global `var` or a parameter) spelled as a
    /// reserved/builtin type name. The parser turns such a spelling
    /// into a `.type_expr` rather than an `.identifier` (`parser.zig`, via
    /// `name_class.Type.fromName`), so the address-of family in `lower.zig`
    /// (`@x`, the autoref `x.method(...)` receiver, a bare `f(x)` at a `*T`
    /// param) never sees a scoped local and falls through to value lowering —
    /// loading the whole aggregate and passing it by value to a `ptr` parameter
    /// (LLVM verifier abort, or a silent mutation-losing copy). Rejecting the
    /// name here, before lowering, keeps the `.identifier`-only address-of paths
    /// correct without any lowering special-case.
    /// `is_raw` is a REQUIRED argument, not a call-site guard: the exemption
    /// lives INSIDE the check so no caller can validate a name without also
    /// honoring the backtick / `#import c` extern exemption. This is what keeps
    /// the check and the exemption from desyncing — the recurring failure of the
    /// earlier attempts, where each site threaded an `if (!is_raw)` guard
    /// separately and one was forgotten.
    fn checkBindingName(self: UnknownTypeChecker, name: []const u8, span: ?ast.Span, is_raw: bool) void {
        if (is_raw) return;
        if (isReservedTypeName(name))
            self.diagnostics.addFmt(.err, span, "'{s}' is a reserved type name and cannot be used as an identifier", .{name});
    }

    /// Reserved-name check for a `::` declaration whose own name binds an
    /// identifier but carries no dedicated `name_span` field — struct / enum /
    /// union / error-set / protocol / runtime-class type decls, ufcs aliases,
    /// and namespaced imports. Each such node begins at its name
    /// token (`createNode(name_start, …)`), so the name's length isolates the
    /// caret onto the name — a single source for the span, no separate stored
    /// field to drift from `node.span`. `is_raw` is REQUIRED, exactly as in
    /// `checkBindingName`: a backtick raw / `#import c` extern name is exempt
    /// by construction.
    fn checkDeclName(self: UnknownTypeChecker, node: *const Node, name: []const u8, is_raw: bool) void {
        const span = ast.Span{ .start = node.span.start, .end = node.span.start + @as(u32, @intCast(name.len)) };
        self.checkBindingName(name, span, is_raw);
    }
};

/// A binding name collides with a reserved/builtin type name exactly when the
/// parser would classify the same spelling as a type. `name_class.Type.fromName`
/// is that classifier (`parser.zig` uses it to choose `.type_expr` over
/// `.identifier`), so deferring to it ties the rejection to the parser's set and
/// keeps the two from drifting: the named builtins (`bool`, `string`, `void`,
/// `f32`, `f64`, `usize`, `isize`, `Any`) and the `[iu]N` arbitrary-width ints
/// over sx's supported 1–64 range. A bare value name (`s`, `buf`, `index`,
/// `self`) is not a type spelling and is left alone.
fn isReservedTypeName(name: []const u8) bool {
    return name_class.Type.fromName(name) != null;
}

fn isBuiltinTypeName(name: []const u8) bool {
    if (TypeResolver.resolvePrimitive(name) != null) return true;
    // Arbitrary-width integers / floats: u1, i7, u128, f16, f80, …
    if (name.len >= 2 and (name[0] == 'u' or name[0] == 'i' or name[0] == 'f')) {
        var all_digits = true;
        for (name[1..]) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return true;
    }
    const extra = [_][]const u8{ "Type", "type", "int", "float", "Self", "self", "any", "noreturn", "usize", "isize", "comptime_int", "comptime_float" };
    for (extra) |e| if (std.mem.eql(u8, name, e)) return true;
    return false;
}

/// True when a `const_decl`'s value introduces a TYPE name — a type declaration
/// (`struct`/`enum`/`union`/`error`) or a type-expression alias (`Alias :: u32`,
/// `Ptr :: *u8`, `Cb :: (i32) -> i32`, …). Only these belong in the declared-
/// type-name set; a value const (`NotAType :: 123`) does NOT declare a type and
/// must stay subject to the unknown-type check.
///
/// `.identifier` / `.call` aliases (`B :: A`, `Vec3 :: Vec(3, f32)`) are
/// deliberately NOT matched here: the scan registers the type-valued ones into
/// `ProgramIndex.type_alias_map` / the `TypeTable` (both queried separately), so
/// a value-RHS alias is correctly left out and flagged, while a type-RHS alias
/// is still covered by the canonical facts.
fn constValueIntroducesType(value: *const Node) bool {
    return switch (value.data) {
        .struct_decl, .enum_decl, .union_decl, .error_set_decl => true,
        .type_expr,
        .pointer_type_expr,
        .many_pointer_type_expr,
        .slice_type_expr,
        .optional_type_expr,
        .array_type_expr,
        .function_type_expr,
        .closure_type_expr,
        .tuple_type_expr,
        .parameterized_type_expr,
        => true,
        else => false,
    };
}

fn isIdentLike(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}
