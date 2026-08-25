const std = @import("std");
const ast = @import("../ast.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const Lowering = lower.Lowering;

/// The converged error-analysis facts lowering consumes: each pure-failable
/// function's inferred error-tag set, and each bare-`!` closure SHAPE's
/// inferred set. The backing maps live on `Lowering` (the facade writes
/// `self.l.*`); `facts()` returns a view over them.
pub const ErrorFacts = struct {
    inferred_error_sets: std.StringHashMap([]const u32),
    shape_inferred_sets: std.StringHashMap([]const u32),
};

/// Whole-program error-set convergence. Owns the fix-point traversals that
/// converge inferred `!` error sets (`convergeInferredErrorSets`) and bare-`!` closure-shape sets
/// (`convergeClosureShapeSets`), plus the AST collectors that feed them.
///
/// A `*Lowering` facade (like `CallResolver`/`ProtocolResolver`):
/// it reads the declaration map (`fn_ast_map`) + tag registry and writes the
/// `inferred_error_sets` / `shape_inferred_sets` maps that live on
/// `Lowering` (consumers read them there). The per-closure-literal contribution
/// (`recordClosureShape`) + its type/shape helpers stay in `Lowering`; this
/// module calls back for that and reaches its own `collectErrorSites` via the
/// facade.
pub const ErrorAnalysis = struct {
    l: *Lowering,

    pub fn facts(self: ErrorAnalysis) ErrorFacts {
        return .{
            .inferred_error_sets = self.l.inferred_error_sets,
            .shape_inferred_sets = self.l.shape_inferred_sets,
        };
    }

    /// The escape a `try`ed or `return`ed call contributes: an EDGE naming the
    /// callee's declaration, or `dyn` when the callee spelling names none. A
    /// resolved non-failable callee contributes an edge whose declared channel
    /// is empty. `enclosing_fd` types a receiver written as one of its
    /// parameters; a receiver that is anything else is not typed here.
    fn contributeCallee(self: ErrorAnalysis, callee: *const Node, enclosing_fd: ?*const ast.FnDecl, edges: *std.ArrayList([]const u8), dyn: *bool) void {
        switch (callee.data) {
            .identifier => |id| edges.append(self.l.alloc, id.name) catch {},
            .field_access => |fa| {
                if (fa.object.data == .identifier) {
                    const obj = fa.object.data.identifier.name;
                    // A namespace- or type-qualified callee is spelled exactly as
                    // its declaration is registered, so it outranks the bare name:
                    // two modules may each author `parse`.
                    if (self.qualifiedEdge(obj, fa.field)) |q| {
                        edges.append(self.l.alloc, q) catch {};
                        return;
                    }
                    // A typed Type.method outranks the bare name: a free function
                    // may share it (libc `read`).
                    if (self.paramTypeName(enclosing_fd, obj)) |tn| {
                        if (self.qualifiedEdge(tn, fa.field)) |q| {
                            edges.append(self.l.alloc, q) catch {};
                            return;
                        }
                    }
                }
                // A UFCS free function lives under the BARE method name.
                const bare = self.l.ufcsAliasTarget(fa.field) orelse fa.field;
                if (self.l.edgeCalleeDecl(bare, self.l.current_source_file) != null) {
                    edges.append(self.l.alloc, bare) catch {};
                    return;
                }
                dyn.* = true;
            },
            else => dyn.* = true,
        }
    }

    /// `"<head>.<method>"` when that names a declaration, else null.
    fn qualifiedEdge(self: ErrorAnalysis, head: []const u8, method: []const u8) ?[]const u8 {
        const qualified = std.fmt.allocPrint(self.l.alloc, "{s}.{s}", .{ head, method }) catch return null;
        if (self.l.edgeCalleeDecl(qualified, self.l.current_source_file) == null) return null;
        return qualified;
    }

    /// The nominal spelling of the parameter `name` of `fd`, seen past a
    /// pointer, or null when `fd` has no such parameter or its written type is
    /// not nominal.
    fn paramTypeName(self: ErrorAnalysis, fd: ?*const ast.FnDecl, name: []const u8) ?[]const u8 {
        const decl = fd orelse return null;
        for (decl.params) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            var ty = self.l.resolveType(p.type_expr);
            if (ty.isBuiltin()) return null;
            if (self.l.module.types.get(ty) == .pointer) ty = self.l.module.types.get(ty).pointer.pointee;
            if (ty.isBuiltin()) return null;
            return switch (self.l.module.types.get(ty)) {
                .@"struct" => |s| self.l.module.types.getString(s.name),
                else => null,
            };
        }
        return null;
    }

    /// Collect the error TAGS raised + the call EDGES of a function body, for
    /// the inferred-set fix-point. Stops at nested function boundaries.
    pub fn collectErrorSites(self: ErrorAnalysis, node: *const Node, tags: *std.ArrayList(u32), edges: *std.ArrayList([]const u8), dyn: *bool, enclosing_fd: ?*const ast.FnDecl) void {
        switch (node.data) {
            .raise_stmt => |rs| {
                if (Lowering.literalTagName(rs.tag)) |nm| {
                    tags.append(self.l.alloc, self.l.anonymousErrorMember(nm)) catch {};
                } else if (self.l.qualifiedErrorMember(rs.tag)) |qm| {
                    // What a qualified member contributes is its STATIC TYPE —
                    // the whole set, not the one member named at the site.
                    for (self.l.module.types.get(qm.set).error_set.tags) |t| {
                        if (!Lowering.containsTag(tags.items, t)) tags.append(self.l.alloc, t) catch {};
                    }
                } else {
                    // A computed tag (`raise e`) names no static set here.
                    dyn.* = true;
                }
                self.collectErrorSites(rs.tag, tags, edges, dyn, enclosing_fd);
            },
            .try_expr => |te| {
                if (te.operand.data == .call) {
                    self.contributeCallee(te.operand.data.call.callee, enclosing_fd, edges, dyn);
                } else {
                    // A `try` on a non-call — a closure / fn-pointer value, a
                    // checked assertion (`av.(T)`) — escapes through a channel
                    // no declaration names.
                    dyn.* = true;
                }
                self.collectErrorSites(te.operand, tags, edges, dyn, enclosing_fd);
            },
            .block => |b| {
                for (b.stmts) |s| self.collectErrorSites(s, tags, edges, dyn, enclosing_fd);
                // A producing block's last call is the implicit `return <call>` tail.
                if (b.produces_value and b.stmts.len > 0) {
                    const last = b.stmts[b.stmts.len - 1];
                    if (last.data == .call) self.contributeCallee(last.data.call.callee, enclosing_fd, edges, dyn);
                }
            },
            .if_expr => |ie| {
                self.collectErrorSites(ie.condition, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(ie.then_branch, tags, edges, dyn, enclosing_fd);
                if (ie.else_branch) |eb| self.collectErrorSites(eb, tags, edges, dyn, enclosing_fd);
            },
            .match_expr => |me| {
                self.collectErrorSites(me.subject, tags, edges, dyn, enclosing_fd);
                for (me.arms) |arm| self.collectErrorSites(arm.body, tags, edges, dyn, enclosing_fd);
            },
            .while_expr => |w| {
                self.collectErrorSites(w.condition, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(w.body, tags, edges, dyn, enclosing_fd);
            },
            .for_expr => |f| {
                for (f.iterables) |it| {
                    self.collectErrorSites(it.expr, tags, edges, dyn, enclosing_fd);
                    if (it.range_end) |re| self.collectErrorSites(re, tags, edges, dyn, enclosing_fd);
                }
                self.collectErrorSites(f.body, tags, edges, dyn, enclosing_fd);
            },
            .return_stmt => |r| if (r.value) |v| {
                // `return callee(...)` FORWARDS the callee's error channel, so
                // it contributes the callee's set exactly like a `try` edge.
                if (v.data == .call) self.contributeCallee(v.data.call.callee, enclosing_fd, edges, dyn);
                self.collectErrorSites(v, tags, edges, dyn, enclosing_fd);
            },
            .var_decl => |v| if (v.value) |val| self.collectErrorSites(val, tags, edges, dyn, enclosing_fd),
            .const_decl => |c| self.collectErrorSites(c.value, tags, edges, dyn, enclosing_fd),
            .destructure_decl => |d| self.collectErrorSites(d.value, tags, edges, dyn, enclosing_fd),
            .assignment => |a| {
                self.collectErrorSites(a.target, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(a.value, tags, edges, dyn, enclosing_fd);
            },
            .multi_assign => |m| {
                for (m.targets) |t| self.collectErrorSites(t, tags, edges, dyn, enclosing_fd);
                for (m.values) |v| self.collectErrorSites(v, tags, edges, dyn, enclosing_fd);
            },
            .call => |c| {
                self.collectErrorSites(c.callee, tags, edges, dyn, enclosing_fd);
                for (c.args) |a| self.collectErrorSites(a, tags, edges, dyn, enclosing_fd);
            },
            .binary_op => |b| {
                self.collectErrorSites(b.lhs, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(b.rhs, tags, edges, dyn, enclosing_fd);
            },
            .unary_op => |u| self.collectErrorSites(u.operand, tags, edges, dyn, enclosing_fd),
            .deref_expr => |d| self.collectErrorSites(d.operand, tags, edges, dyn, enclosing_fd),
            .force_unwrap => |fu| self.collectErrorSites(fu.operand, tags, edges, dyn, enclosing_fd),
            .null_coalesce => |nc| {
                self.collectErrorSites(nc.lhs, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(nc.rhs, tags, edges, dyn, enclosing_fd);
            },
            .field_access => |fa| self.collectErrorSites(fa.object, tags, edges, dyn, enclosing_fd),
            .index_expr => |ix| {
                self.collectErrorSites(ix.object, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(ix.index, tags, edges, dyn, enclosing_fd);
            },
            .spread_expr => |s| self.collectErrorSites(s.operand, tags, edges, dyn, enclosing_fd),
            .catch_expr => |ce| {
                self.collectErrorSites(ce.operand, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(ce.body, tags, edges, dyn, enclosing_fd);
            },
            .defer_stmt => |d| self.collectErrorSites(d.expr, tags, edges, dyn, enclosing_fd),
            .push_stmt => |p| {
                self.collectErrorSites(p.context_expr, tags, edges, dyn, enclosing_fd);
                self.collectErrorSites(p.body, tags, edges, dyn, enclosing_fd);
            },
            .array_literal => |al| for (al.elements) |el| self.collectErrorSites(el, tags, edges, dyn, enclosing_fd),
            .tuple_literal => |tl| for (tl.elements) |el| self.collectErrorSites(el.value, tags, edges, dyn, enclosing_fd),
            // Stop at nested function boundaries; leaves contribute nothing.
            else => {},
        }
    }

    /// Whole-program fix-point that converges each bare-`!` function's inferred
    /// error set — `-> !` and value-carrying `-> (T..., !)` alike — and
    /// materialises the converged set as that declaration's channel TypeId.
    /// Runs after `scanDecls` (ASTs + named error sets registered) and before
    /// body lowering, so every later check reads the materialised channel. Also
    /// emits the empty-inferred warning.
    pub fn convergeInferredErrorSets(self: ErrorAnalysis) void {
        const Node_ = struct {
            fd: *const ast.FnDecl,
            tags: std.ArrayList(u32),
            edges: std.ArrayList([]const u8),
            rt: ?*const Node,
            // Module the function is written in. `rt.span` is an offset into
            // THAT file, and this whole-program pass runs with whatever
            // ambient source file the previous phase left behind.
            source_file: ?[]const u8,
            // The body escapes through a channel that cannot be named (a `try`
            // of a closure value or a checked assertion, a `raise` of a
            // computed tag, a call whose callee names no declaration), so it
            // genuinely propagates a dynamic error even when no concrete tag
            // converges. Suppresses the empty-set "drop the `!`" warning, and
            // makes the channel the DYNAMIC one: a merge over a channel nobody
            // can name is not the set the body escapes.
            dyn: bool,
        };
        var work = std.StringHashMap(Node_).init(self.l.alloc);
        defer work.deinit();
        // A bare-`!` declaration's key in `work`, so an edge that resolved to a
        // DECLARATION reaches that declaration's node rather than whichever
        // same-name function the map is keyed under.
        var work_key = std.AutoHashMap(*const ast.FnDecl, []const u8).init(self.l.alloc);
        defer work_key.deinit();

        // Seed each bare-`!` function with its direct escape sites.
        {
            const saved = self.l.current_source_file;
            defer self.l.setCurrentSourceFile(saved);
            var it = self.l.program_index.fn_ast_map.iterator();
            while (it.next()) |e| {
                const fd = e.value_ptr.*;
                if (!Lowering.astChannelIsInferred(fd.return_type)) continue;
                var tags = std.ArrayList(u32).empty;
                var edges = std.ArrayList([]const u8).empty;
                var dyn = false;
                self.l.setCurrentSourceFile(fd.body.source_file orelse saved);
                self.collectErrorSites(fd.body, &tags, &edges, &dyn, fd);
                work.put(e.key_ptr.*, .{ .fd = fd, .tags = tags, .edges = edges, .rt = fd.return_type, .source_file = fd.body.source_file, .dyn = dyn }) catch {};
                work_key.put(fd, e.key_ptr.*) catch {};
            }
        }

        // Union edge contributions until no set grows (monotone → terminates).
        var changed = true;
        while (changed) {
            changed = false;
            var wit = work.iterator();
            while (wit.next()) |we| {
                for (we.value_ptr.edges.items) |callee| {
                    const callee_fd = self.l.edgeCalleeDecl(callee, we.value_ptr.source_file) orelse {
                        // No single author is visible at the edge, so the
                        // channel it escapes through is not statically known.
                        if (!we.value_ptr.dyn) {
                            we.value_ptr.dyn = true;
                            changed = true;
                        }
                        continue;
                    };
                    const callee_tags: []const u32 = blk: {
                        if (work_key.get(callee_fd)) |k| {
                            if (work.getPtr(k)) |cc| {
                                // A callee whose merge is non-static makes this
                                // node's merge non-static.
                                if (cc.dyn and !we.value_ptr.dyn) {
                                    we.value_ptr.dyn = true;
                                    changed = true;
                                }
                                break :blk cc.tags.items;
                            }
                        }
                        break :blk self.l.declaredChannelTags(callee_fd);
                    };
                    for (callee_tags) |t| {
                        if (!Lowering.containsTag(we.value_ptr.tags.items, t)) {
                            we.value_ptr.tags.append(self.l.alloc, t) catch {};
                            changed = true;
                        }
                    }
                }
            }
        }

        // Store the converged sets (sorted), materialise them, and warn on
        // empty inferred sets.
        // `work` is a StringHashMap, so its iteration order is hash order — walk
        // it directly and the warnings below come out scrambled, and differently
        // under any other hash. Order by source span first so the diagnostics
        // read top-to-bottom and stay identical across implementations.
        const Entry = struct { name: []const u8, node: *const Node_ };
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(self.l.alloc);
        var sit = work.iterator();
        while (sit.next()) |se| {
            entries.append(self.l.alloc, .{ .name = se.key_ptr.*, .node = se.value_ptr }) catch {};
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                // A function with no return-type node never warns; order it by
                // name so the sort stays total regardless.
                const a_start: u32 = if (a.node.rt) |rt| rt.span.start else std.math.maxInt(u32);
                const b_start: u32 = if (b.node.rt) |rt| rt.span.start else std.math.maxInt(u32);
                if (a_start != b_start) return a_start < b_start;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        const saved_file = self.l.current_source_file;
        defer self.l.setCurrentSourceFile(saved_file);

        for (entries.items) |se| {
            const sorted = self.l.alloc.dupe(u32, se.node.tags.items) catch continue;
            std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
            self.l.inferred_error_sets.put(se.name, sorted) catch {};
            if (se.node.dyn) self.l.materialiseDynChannel(se.node.fd, se.name) else self.l.materialiseInferredChannel(se.node.fd, se.name, sorted);
            // Skip `main` (its `!` is the program's top error channel) and any
            // protocol-impl method (its `!` is dictated by the protocol
            // contract — e.g. `Io.suspend_raw` — so a non-raising impl body
            // is not a "drop the `!`" case; see `impl_method_names`).
            const whole_return_is_channel = Lowering.astChannelNode(se.node.rt) == se.node.rt;
            if (sorted.len == 0 and whole_return_is_channel and !se.node.dyn and !std.mem.eql(u8, se.name, "main") and !self.l.impl_method_names.contains(se.name)) {
                if (self.l.diagnostics) |diags| {
                    if (se.node.rt) |rt| {
                        self.l.setCurrentSourceFile(se.node.source_file orelse saved_file);
                        diags.addFmt(.warn, rt.span, "function '{s}' is declared `!` but never errors — drop the `!`", .{se.name});
                    }
                }
            }
        }
    }

    /// Whole-program union of each bare-`!` closure/fn-type SHAPE's escape set
    /// Walks every function body for closure literals;
    /// each bare-`!` failable literal contributes its raises (+ `try named_fn()`
    /// edges, resolved against the name-keyed converged sets) to the node shared
    /// by all occurrences of its value-signature shape. A `try slot(x)` against
    /// any matching-shape slot then widens against this union.
    pub fn convergeClosureShapeSets(self: ErrorAnalysis) void {
        // Pin the visibility context to each fn's DEFINING module
        // (body.source_file, stamped by resolveImports) — a closure literal's
        // param/return annotations must resolve where the fn is written, not
        // against whatever module the previous pipeline phase happened to
        // leave as the ambient context.
        const saved = self.l.current_source_file;
        defer self.l.setCurrentSourceFile(saved);
        var it = self.l.program_index.fn_ast_map.iterator();
        while (it.next()) |e| {
            self.l.setCurrentSourceFile(e.value_ptr.*.body.source_file orelse saved);
            self.collectClosureShapes(e.value_ptr.*.body);
        }
    }

    /// Recurse the AST collecting closure-literal shape contributions. Unlike
    /// `collectErrorSites`, this descends THROUGH lambda boundaries (a nested
    /// closure is its own shape, and may itself contain closures). The
    /// per-literal recording (`recordClosureShape`) stays in `Lowering`.
    fn collectClosureShapes(self: ErrorAnalysis, node: *const Node) void {
        switch (node.data) {
            .lambda => |lam| {
                self.l.recordClosureShape(&lam);
                self.collectClosureShapes(lam.body);
            },
            .block => |b| for (b.stmts) |s| self.collectClosureShapes(s),
            .if_expr => |ie| {
                self.collectClosureShapes(ie.condition);
                self.collectClosureShapes(ie.then_branch);
                if (ie.else_branch) |eb| self.collectClosureShapes(eb);
            },
            .while_expr => |w| {
                self.collectClosureShapes(w.condition);
                self.collectClosureShapes(w.body);
            },
            .for_expr => |f| {
                for (f.iterables) |it| {
                    self.collectClosureShapes(it.expr);
                    if (it.range_end) |re| self.collectClosureShapes(re);
                }
                self.collectClosureShapes(f.body);
            },
            .return_stmt => |r| if (r.value) |v| self.collectClosureShapes(v),
            .raise_stmt => |rs| self.collectClosureShapes(rs.tag),
            .var_decl => |v| if (v.value) |val| self.collectClosureShapes(val),
            .const_decl => |c| self.collectClosureShapes(c.value),
            .destructure_decl => |d| self.collectClosureShapes(d.value),
            .assignment => |a| {
                self.collectClosureShapes(a.target);
                self.collectClosureShapes(a.value);
            },
            .multi_assign => |m| {
                for (m.targets) |t| self.collectClosureShapes(t);
                for (m.values) |v| self.collectClosureShapes(v);
            },
            .call => |c| {
                self.collectClosureShapes(c.callee);
                for (c.args) |a| self.collectClosureShapes(a);
            },
            .binary_op => |b| {
                self.collectClosureShapes(b.lhs);
                self.collectClosureShapes(b.rhs);
            },
            .unary_op => |u| self.collectClosureShapes(u.operand),
            .deref_expr => |d| self.collectClosureShapes(d.operand),
            .force_unwrap => |fu| self.collectClosureShapes(fu.operand),
            .null_coalesce => |nc| {
                self.collectClosureShapes(nc.lhs);
                self.collectClosureShapes(nc.rhs);
            },
            .field_access => |fa| self.collectClosureShapes(fa.object),
            .index_expr => |ix| {
                self.collectClosureShapes(ix.object);
                self.collectClosureShapes(ix.index);
            },
            .spread_expr => |s| self.collectClosureShapes(s.operand),
            .try_expr => |te| self.collectClosureShapes(te.operand),
            .catch_expr => |ce| {
                self.collectClosureShapes(ce.operand);
                self.collectClosureShapes(ce.body);
            },
            .defer_stmt => |d| self.collectClosureShapes(d.expr),
            .push_stmt => |p| {
                self.collectClosureShapes(p.context_expr);
                self.collectClosureShapes(p.body);
            },
            .array_literal => |al| for (al.elements) |el| self.collectClosureShapes(el),
            .tuple_literal => |tl| for (tl.elements) |el| self.collectClosureShapes(el.value),
            else => {},
        }
    }
};
