const std = @import("std");
const ast = @import("../ast.zig");
const lower = @import("lower.zig");

const Node = ast.Node;
const Lowering = lower.Lowering;

/// The converged error-analysis facts lowering consumes (PLAN-ARCH A5.1): each
/// pure-failable function's inferred error-tag set, and each bare-`!` closure
/// SHAPE's inferred set. Backing maps currently live on `Lowering` (the facade
/// writes `self.l.*`); `facts()` returns a view over them.
pub const ErrorFacts = struct {
    inferred_error_sets: std.StringHashMap([]const u32),
    shape_inferred_sets: std.StringHashMap([]const u32),
};

/// Whole-program error-set convergence (architecture phase A5.1), extracted
/// from `Lowering`. Owns the fix-point traversals that converge inferred
/// `!` error sets (`convergeInferredErrorSets`) and bare-`!` closure-shape sets
/// (`convergeClosureShapeSets`), plus the AST collectors that feed them.
///
/// A `*Lowering` facade (Principle 5, like `CallResolver`/`ProtocolResolver`):
/// it reads the declaration map (`fn_ast_map`) + tag registry and writes the
/// `inferred_error_sets` / `shape_inferred_sets` maps that still live on
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

    /// Collect the error TAGS raised + the `try`-call EDGES of a function body,
    /// for the inferred-set fix-point. Stops at nested function boundaries.
    pub fn collectErrorSites(self: ErrorAnalysis, node: *const Node, tags: *std.ArrayList(u32), edges: *std.ArrayList([]const u8), dyn: *bool) void {
        switch (node.data) {
            .raise_stmt => |rs| {
                if (Lowering.isErrorTagLiteralNode(rs.tag)) {
                    tags.append(self.l.alloc, self.l.module.types.internTag(rs.tag.data.field_access.field)) catch {};
                }
                self.collectErrorSites(rs.tag, tags, edges, dyn);
            },
            .try_expr => |te| {
                if (Lowering.callTargetName(te.operand)) |nm| {
                    edges.append(self.l.alloc, nm) catch {};
                } else if (te.operand.data == .call) {
                    // A `try` whose callee is NOT a plain identifier — a protocol
                    // method (`io.suspend_raw`), a UFCS / instance method, a
                    // closure / fn-pointer value. Its error channel is OPAQUE to
                    // this static convergence (no free-fn name to resolve a set
                    // from), so the function genuinely propagates a dynamic error.
                    // Mark it so the "declared `!` but never errors" warning is
                    // suppressed — the `!` is load-bearing, not droppable.
                    dyn.* = true;
                }
                self.collectErrorSites(te.operand, tags, edges, dyn);
            },
            .block => |b| for (b.stmts) |s| self.collectErrorSites(s, tags, edges, dyn),
            .if_expr => |ie| {
                self.collectErrorSites(ie.condition, tags, edges, dyn);
                self.collectErrorSites(ie.then_branch, tags, edges, dyn);
                if (ie.else_branch) |eb| self.collectErrorSites(eb, tags, edges, dyn);
            },
            .while_expr => |w| {
                self.collectErrorSites(w.condition, tags, edges, dyn);
                self.collectErrorSites(w.body, tags, edges, dyn);
            },
            .for_expr => |f| {
                for (f.iterables) |it| {
                    self.collectErrorSites(it.expr, tags, edges, dyn);
                    if (it.range_end) |re| self.collectErrorSites(re, tags, edges, dyn);
                }
                self.collectErrorSites(f.body, tags, edges, dyn);
            },
            .return_stmt => |r| if (r.value) |v| self.collectErrorSites(v, tags, edges, dyn),
            .var_decl => |v| if (v.value) |val| self.collectErrorSites(val, tags, edges, dyn),
            .const_decl => |c| self.collectErrorSites(c.value, tags, edges, dyn),
            .destructure_decl => |d| self.collectErrorSites(d.value, tags, edges, dyn),
            .assignment => |a| {
                self.collectErrorSites(a.target, tags, edges, dyn);
                self.collectErrorSites(a.value, tags, edges, dyn);
            },
            .multi_assign => |m| {
                for (m.targets) |t| self.collectErrorSites(t, tags, edges, dyn);
                for (m.values) |v| self.collectErrorSites(v, tags, edges, dyn);
            },
            .call => |c| {
                self.collectErrorSites(c.callee, tags, edges, dyn);
                for (c.args) |a| self.collectErrorSites(a, tags, edges, dyn);
            },
            .binary_op => |b| {
                self.collectErrorSites(b.lhs, tags, edges, dyn);
                self.collectErrorSites(b.rhs, tags, edges, dyn);
            },
            .unary_op => |u| self.collectErrorSites(u.operand, tags, edges, dyn),
            .deref_expr => |d| self.collectErrorSites(d.operand, tags, edges, dyn),
            .force_unwrap => |fu| self.collectErrorSites(fu.operand, tags, edges, dyn),
            .null_coalesce => |nc| {
                self.collectErrorSites(nc.lhs, tags, edges, dyn);
                self.collectErrorSites(nc.rhs, tags, edges, dyn);
            },
            .field_access => |fa| self.collectErrorSites(fa.object, tags, edges, dyn),
            .index_expr => |ix| {
                self.collectErrorSites(ix.object, tags, edges, dyn);
                self.collectErrorSites(ix.index, tags, edges, dyn);
            },
            .spread_expr => |s| self.collectErrorSites(s.operand, tags, edges, dyn),
            .catch_expr => |ce| {
                self.collectErrorSites(ce.operand, tags, edges, dyn);
                self.collectErrorSites(ce.body, tags, edges, dyn);
            },
            .defer_stmt => |d| self.collectErrorSites(d.expr, tags, edges, dyn),
            .push_stmt => |p| {
                self.collectErrorSites(p.context_expr, tags, edges, dyn);
                self.collectErrorSites(p.body, tags, edges, dyn);
            },
            .array_literal => |al| for (al.elements) |el| self.collectErrorSites(el, tags, edges, dyn),
            .tuple_literal => |tl| for (tl.elements) |el| self.collectErrorSites(el.value, tags, edges, dyn),
            // Stop at nested function boundaries; leaves contribute nothing.
            else => {},
        }
    }

    /// Whole-program fix-point that converges each top-level bare-`!` function's
    /// inferred error set (ERR E1.4b). Runs after `scanDecls` (ASTs + named
    /// error sets registered) and before body lowering, so `lowerTry`'s
    /// named-caller widening sees the converged callee sets. Also emits the
    /// empty-inferred warning. Scope: pure-failable functions (value-carrying
    /// raise/try aren't lowered yet — E2).
    pub fn convergeInferredErrorSets(self: ErrorAnalysis) void {
        const Node_ = struct {
            tags: std.ArrayList(u32),
            edges: std.ArrayList([]const u8),
            rt: ?*const Node,
            // The body `try`s a callee with an OPAQUE error channel (a protocol
            // method / UFCS-method / closure call) — so it genuinely propagates a
            // dynamic error even when no concrete tag converges. Suppresses the
            // empty-set "drop the `!`" warning.
            dyn: bool,
        };
        var work = std.StringHashMap(Node_).init(self.l.alloc);
        defer work.deinit();

        // Seed each bare-`!` function with its direct escape sites.
        var it = self.l.program_index.fn_ast_map.iterator();
        while (it.next()) |e| {
            const fd = e.value_ptr.*;
            if (!Lowering.astIsPureBareInferred(fd.return_type)) continue;
            var tags = std.ArrayList(u32).empty;
            var edges = std.ArrayList([]const u8).empty;
            var dyn = false;
            self.collectErrorSites(fd.body, &tags, &edges, &dyn);
            work.put(e.key_ptr.*, .{ .tags = tags, .edges = edges, .rt = fd.return_type, .dyn = dyn }) catch {};
        }

        // Union edge contributions until no set grows (monotone → terminates).
        var changed = true;
        while (changed) {
            changed = false;
            var wit = work.iterator();
            while (wit.next()) |we| {
                for (we.value_ptr.edges.items) |callee| {
                    const callee_tags: []const u32 = blk: {
                        if (work.getPtr(callee)) |cc| break :blk cc.tags.items;
                        if (self.l.program_index.fn_ast_map.get(callee)) |cfd| {
                            if (Lowering.astPureNamedSet(cfd.return_type)) |nm| {
                                break :blk self.l.namedSetTags(nm) orelse &.{};
                            }
                        }
                        break :blk &.{};
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

        // Store the converged sets (sorted) and warn on empty inferred sets.
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

        for (entries.items) |se| {
            const sorted = self.l.alloc.dupe(u32, se.node.tags.items) catch continue;
            std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
            self.l.inferred_error_sets.put(se.name, sorted) catch {};
            // Skip `main` (its `!` is the program's top error channel) and any
            // protocol-impl method (its `!` is dictated by the protocol
            // contract — e.g. `Io.suspend_raw` — so a non-raising impl body
            // is not a "drop the `!`" case; see `impl_method_names`).
            if (sorted.len == 0 and !se.node.dyn and !std.mem.eql(u8, se.name, "main") and !self.l.impl_method_names.contains(se.name)) {
                if (self.l.diagnostics) |diags| {
                    if (se.node.rt) |rt| {
                        diags.addFmt(.warn, rt.span, "function '{s}' is declared `!` but never errors — drop the `!`", .{se.name});
                    }
                }
            }
        }
    }

    /// Whole-program union of each bare-`!` closure/fn-type SHAPE's escape set
    /// (ERR E5.1 sub-feature 2). Walks every function body for closure literals;
    /// each bare-`!` failable literal contributes its raises (+ `try named_fn()`
    /// edges, resolved against the name-keyed converged sets) to the node shared
    /// by all occurrences of its value-signature shape. A `try slot(x)` against
    /// any matching-shape slot then widens against this union.
    pub fn convergeClosureShapeSets(self: ErrorAnalysis) void {
        // Pin the visibility context to each fn's DEFINING module
        // (body.source_file, stamped by resolveImports) — a closure literal's
        // param/return annotations must resolve where the fn is written, not
        // against whatever module the previous pipeline phase happened to
        // leave as the ambient context (issue 0122).
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
