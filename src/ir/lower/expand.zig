//! Module-scope declaration expansion: `inline if`, its `inline if X == { … }`
//! match spelling, and `inline for`.
//!
//! Import resolution leaves these drivers OPAQUE — a branch's declarations,
//! including the modules a branch-local `#import` names, stay inside the node.
//! Lowering owns the evaluation: a driver is folded here against the same
//! comptime facts an in-function `inline if` folds against, and only the
//! selected group is SPLICED into module scope, at the driver's own place in
//! declaration order.
//!
//! Containment is what the opacity buys: the windows and posix `std.fs`
//! backends both resolve, both author `fs_file_is_valid`, and neither reaches
//! module scope until its branch is selected.
//!
//! The pre-lowering facts are already built by the time a group is selected, so
//! the splice MINTS them: module scope entry, import graph edge, raw decl fact,
//! `DeclId`, source and visibility provenance. Everything after that is the
//! ordinary treatment of a textual declaration — the scan registers the group
//! in its own place, so a name a group declares is a declaration like any other.

const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const imports = @import("../../imports.zig");
const types = @import("../types.zig");
const TypeId = types.TypeId;

const lower = @import("../lower.zig");
const Lowering = lower.Lowering;

/// Expand every module-scope driver the program declares, returning the
/// expanded root declaration list. Runs before the scan: a group's
/// declarations are its module's declarations, so they must register in their
/// own textual place, among the text they were written among.
pub fn expandModuleDrivers(self: *Lowering, decls: []const *Node) []const *Node {
    var ex = Expansion{
        .self = self,
        .scope = decls,
        .expanded = std.AutoHashMap(*const Node, void).init(self.alloc),
        .raised = std.AutoHashMap(*const Node, void).init(self.alloc),
        .lists = std.AutoHashMap(ListKey, *Expanded).init(self.alloc),
        .primed = std.StringHashMap(void).init(self.alloc),
        .spliced = std.ArrayList(*Node).empty,
        .parked = std.ArrayList(ParkedDriver).empty,
        .ledgers = std.ArrayList(*Ledger).empty,
        .cursors = std.ArrayList(*std.StringHashMap([]const u8)).empty,
    };
    defer ex.deinit();

    ex.primeTargetFacts(decls);
    // Every driver registers — with the declarations its unexpanded branches
    // could still make — BEFORE any of them folds. A question asked while the
    // first driver folds must already know what the last one might contribute.
    ex.registerDrivers(decls);
    var expanded: []const *Node = decls;
    ex.expandListInto(decls, .transitive, .{ .slot = &expanded });
    ex.expandNamespaces(expanded);
    // A driver that could not decide is parked, not decided: run the drain to
    // quiescence, then write every list from its now-complete slots.
    ex.drainParked();
    ex.flushLists();
    self.expansion.reportDeadlock(self.diagnostics);
    // The member surface publishes last, per module, and only where no driver
    // that could still declare into that scope remains.
    ex.publishNamespaceMembers();
    return expanded;
}

/// Which view of a module a declaration list is: `own` carries only what the
/// module itself authored (a namespace's member surface), `transitive` also
/// carries what its flat imports merged in.
const ListKind = enum { own, transitive };

const ListKey = struct { ptr: usize, len: usize, kind: ListKind };

/// One expanded declaration list, held as SLOTS rather than a finished slice:
/// every driver owns its own slot, so a driver that parks still lands its
/// group at its own place in declaration order once the fact it awaits fires.
const Expanded = struct {
    chunks: std.ArrayList(Chunk),
    sinks: std.ArrayList(Sink),
};

const Chunk = union(enum) {
    node: *Node,
    /// A driver's slot, filled when the driver folds — which may be after the
    /// pass that reached it.
    group: *std.ArrayList(*Node),
};

/// Where an expanded list is written back. A namespace target lives in a map
/// lowering can still grow, so it is addressed by its keys instead of by a
/// pointer a later insertion could move.
const Sink = union(enum) {
    slot: *[]const *Node,
    ns_target: struct { importer: []const u8, alias: []const u8 },
};

/// The dedup state one declaration list is merged against. It outlives the
/// pass: a driver that parks merges its group against the same ledger when it
/// resumes.
const Ledger = struct {
    kind: ListKind,
    names: std.StringHashMap(void),
    nodes: std.AutoHashMap(*const Node, void),
};

/// A driver suspended mid-fold: everything its resumption needs, plus the
/// fact it is waiting on, rendered for the deadlock diagnostic.
const ParkedDriver = struct {
    decl: *const Node,
    src: ?[]const u8,
    group: Group,
    declared: ?*std.StringHashMap([]const u8),
    cursor: []const u8,
    awaited: []const u8,
};

const Expansion = struct {
    self: *Lowering,
    /// The root declaration list — where an `inline for` looks up the curated
    /// type list its iterable names.
    scope: []const *Node,
    /// Drivers already registered. One driver node is reachable from several
    /// views of its module; its declarations are minted exactly once.
    expanded: std.AutoHashMap(*const Node, void),
    raised: std.AutoHashMap(*const Node, void),
    /// Expanded declaration lists, keyed by the input slice: the module views
    /// share slices, and one expansion answers all of them.
    lists: std.AutoHashMap(ListKey, *Expanded),
    /// Names a driver's condition already pulled into registration. Priming a
    /// name is a write to the real declaration facts, so it happens once.
    primed: std.StringHashMap(void),
    /// Everything a taken group has put into module scope. Together with the
    /// textual root list this IS the decided declaration space — what a
    /// question asked by a later driver is answered against.
    spliced: std.ArrayList(*Node),
    /// Drivers whose condition asked a question no set can answer yet.
    parked: std.ArrayList(ParkedDriver),
    ledgers: std.ArrayList(*Ledger),
    cursors: std.ArrayList(*std.StringHashMap([]const u8)),
    /// The fact the read in the condition being driven could not answer, and
    /// whether the fold it belongs to therefore parked.
    awaited: ?[]const u8 = null,
    just_parked: bool = false,
    parked_any: bool = false,

    fn deinit(ex: *Expansion) void {
        ex.expanded.deinit();
        ex.raised.deinit();
        ex.lists.deinit();
        ex.primed.deinit();
        ex.spliced.deinit(ex.self.alloc);
        ex.parked.deinit(ex.self.alloc);
        for (ex.ledgers.items) |l| {
            l.names.deinit();
            l.nodes.deinit();
        }
        ex.ledgers.deinit(ex.self.alloc);
        for (ex.cursors.items) |c| c.deinit();
        ex.cursors.deinit(ex.self.alloc);
    }

    fn decided(ex: *Expansion, decl: *Node) void {
        ex.spliced.append(ex.self.alloc, decl) catch {};
    }

    /// Register every driver the program's declaration lists hold, so the
    /// contribution ledger is complete before the first fold. A driver reached
    /// only through a branch-local `#import` registers when that branch is
    /// selected — until then its contributions are covered by the driver whose
    /// body holds the import.
    fn registerDrivers(ex: *Expansion, decls: []const *Node) void {
        var seen = std.AutoHashMap(*const Node, void).init(ex.self.alloc);
        defer seen.deinit();
        ex.registerDriversIn(decls, &seen);
    }

    fn registerDriversIn(ex: *Expansion, decls: []const *Node, seen: *std.AutoHashMap(*const Node, void)) void {
        for (decls) |decl| {
            if (imports.isModuleDriver(decl)) {
                ex.self.expansion.registerDriver(decl);
                continue;
            }
            if (decl.data != .namespace_decl) continue;
            if (seen.contains(decl)) continue;
            seen.put(decl, {}) catch {};
            const ns = &decl.data.namespace_decl;
            ex.registerDriversIn(ns.own_decls, seen);
            ex.registerDriversIn(ns.decls, seen);
        }
    }

    /// The comptime facts a driver folds against, established before the scan
    /// that would otherwise establish them: the two target enums the OS / ARCH
    /// constants are tags of, and the module constants a condition can name.
    fn primeTargetFacts(ex: *Expansion, decls: []const *Node) void {
        var seen = std.AutoHashMap(*const Node, void).init(ex.self.alloc);
        defer seen.deinit();
        ex.registerTargetEnums(decls, &seen);
        ex.self.injectComptimeConstants();
        ex.self.registerLiteralModuleConsts(decls);
        ex.self.registerConstAliases(decls);
    }

    fn registerTargetEnums(ex: *Expansion, decls: []const *Node, seen: *std.AutoHashMap(*const Node, void)) void {
        for (decls) |decl| {
            switch (decl.data) {
                .const_decl => |cd| {
                    if (cd.value.data != .enum_decl) continue;
                    if (!isTargetEnumName(cd.name)) continue;
                    ex.self.setCurrentSourceFile(decl.source_file);
                    ex.self.registerEnumDecl(&cd.value.data.enum_decl);
                },
                .enum_decl => |ed| {
                    if (!isTargetEnumName(ed.name)) continue;
                    ex.self.setCurrentSourceFile(decl.source_file);
                    ex.self.registerEnumDecl(&decl.data.enum_decl);
                },
                .namespace_decl => |ns| {
                    if (seen.contains(decl)) continue;
                    seen.put(decl, {}) catch {};
                    ex.registerTargetEnums(ns.decls, seen);
                },
                else => {},
            }
        }
    }

    /// Expand every namespaced module's views in place, so a driver written in
    /// a module reachable only through an alias expands too, and its group is
    /// part of that module's member surface.
    fn expandNamespaces(ex: *Expansion, decls: []const *Node) void {
        var seen = std.AutoHashMap(*const Node, void).init(ex.self.alloc);
        defer seen.deinit();
        ex.expandNamespaceNodes(decls, &seen);

        // Expanding a target mints declaration facts, which can grow the edge
        // map itself — so the aliases are collected before any of them folds.
        const edges = ex.self.program_index.namespace_edges orelse return;
        var targets = std.ArrayList(Sink).empty;
        defer targets.deinit(ex.self.alloc);
        var it = edges.iterator();
        while (it.next()) |edge| {
            var ait = edge.value_ptr.keyIterator();
            while (ait.next()) |alias| {
                targets.append(ex.self.alloc, .{ .ns_target = .{ .importer = edge.key_ptr.*, .alias = alias.* } }) catch {};
            }
        }
        for (targets.items) |sink| {
            const list = ex.namespaceTargetList(sink.ns_target.importer, sink.ns_target.alias) orelse continue;
            ex.expandListInto(list, .own, sink);
        }
    }

    fn namespaceTargetList(ex: *Expansion, importer: []const u8, alias: []const u8) ?[]const *Node {
        const edges = ex.self.program_index.namespace_edges orelse return null;
        const aliases = edges.getPtr(importer) orelse return null;
        const target = aliases.getPtr(alias) orelse return null;
        return target.own_decls;
    }

    /// The `DeclId` surface of every namespaced module. A module publishes
    /// only once its own scope is final — an alias's member table is a claim
    /// about what that module declares, and a driver written there that has
    /// not folded can still add to it.
    fn publishNamespaceMembers(ex: *Expansion) void {
        const edges = ex.self.program_index.namespace_edges orelse return;
        const table = ex.self.program_index.decl_table orelse return;
        var it = edges.valueIterator();
        while (it.next()) |aliases| {
            var ait = aliases.valueIterator();
            while (ait.next()) |target| {
                if (!ex.self.expansion.scopeFinal(target.target_module_path)) continue;
                var ids = std.ArrayList(imports.DeclId).empty;
                for (target.own_decls) |member| {
                    if (imports.rawDeclRefOf(member) == null) continue;
                    const id = table.intern(target.target_module_path, member) catch continue;
                    ids.append(ex.self.alloc, id) catch {};
                }
                target.member_ids = ids.toOwnedSlice(ex.self.alloc) catch target.member_ids;
            }
        }
    }

    fn expandNamespaceNodes(ex: *Expansion, list: []const *Node, seen: *std.AutoHashMap(*const Node, void)) void {
        for (list) |decl| {
            if (decl.data != .namespace_decl) continue;
            if (seen.contains(decl)) continue;
            seen.put(decl, {}) catch {};
            const ns = &decl.data.namespace_decl;
            ex.expandListInto(ns.own_decls, .own, .{ .slot = &ns.own_decls });
            ex.expandListInto(ns.decls, .transitive, .{ .slot = &ns.decls });
            ex.expandNamespaceNodes(ns.decls, seen);
        }
    }

    /// Expand one declaration list — every driver replaced by its selected
    /// group — and write the result to `sink`. A list with nothing to expand
    /// leaves the sink alone; a list already expanded answers from the cache,
    /// since the module views share slices.
    fn expandListInto(ex: *Expansion, list: []const *Node, kind: ListKind, sink: Sink) void {
        if (list.len == 0) return;
        var expandable = false;
        for (list) |decl| {
            if (imports.isModuleDriver(decl) or decl.data == .error_directive) {
                expandable = true;
                break;
            }
        }
        if (!expandable) return;

        const key = ListKey{ .ptr = @intFromPtr(list.ptr), .len = list.len, .kind = kind };
        if (ex.lists.get(key)) |cached| {
            cached.sinks.append(ex.self.alloc, sink) catch {};
            ex.writeSink(sink, ex.flatten(cached));
            return;
        }

        const exp = ex.self.alloc.create(Expanded) catch return;
        exp.* = .{ .chunks = .empty, .sinks = .empty };
        exp.sinks.append(ex.self.alloc, sink) catch {};
        ex.lists.put(key, exp) catch {};

        const ledger = ex.self.alloc.create(Ledger) catch return;
        ledger.* = .{
            .kind = kind,
            .names = std.StringHashMap(void).init(ex.self.alloc),
            .nodes = std.AutoHashMap(*const Node, void).init(ex.self.alloc),
        };
        ex.ledgers.append(ex.self.alloc, ledger) catch {};
        for (list) |decl| {
            ledger.nodes.put(decl, {}) catch {};
            if (decl.data.declName()) |name| ledger.names.put(name, {}) catch {};
        }

        for (list) |decl| {
            if (imports.isModuleDriver(decl)) {
                const slot = ex.self.alloc.create(std.ArrayList(*Node)) catch return;
                slot.* = .empty;
                exp.chunks.append(ex.self.alloc, .{ .group = slot }) catch {};
                var group = Group{ .ex = ex, .out = slot, .ledger = ledger };
                _ = group.expandDriver(decl, decl.source_file, null, "");
                continue;
            }
            if (decl.data == .error_directive) {
                ex.raise(decl);
                continue;
            }
            exp.chunks.append(ex.self.alloc, .{ .node = decl }) catch {};
        }
        ex.writeSink(sink, ex.flatten(exp));
    }

    fn flatten(ex: *Expansion, exp: *Expanded) []const *Node {
        var out = std.ArrayList(*Node).empty;
        for (exp.chunks.items) |chunk| switch (chunk) {
            .node => |n| out.append(ex.self.alloc, n) catch {},
            .group => |g| out.appendSlice(ex.self.alloc, g.items) catch {},
        };
        return out.toOwnedSlice(ex.self.alloc) catch &.{};
    }

    fn writeSink(ex: *Expansion, sink: Sink, list: []const *Node) void {
        switch (sink) {
            .slot => |p| p.* = list,
            .ns_target => |t| {
                const edges = ex.self.program_index.namespace_edges orelse return;
                const aliases = edges.getPtr(t.importer) orelse return;
                const target = aliases.getPtr(t.alias) orelse return;
                target.own_decls = list;
            },
        }
    }

    /// Every list, rewritten from its slots now that the drain has run. Only
    /// a driver that parked can have left a slot empty past its pass.
    fn flushLists(ex: *Expansion) void {
        if (!ex.parked_any) return;
        var it = ex.lists.valueIterator();
        while (it.next()) |exp| {
            const list = ex.flatten(exp.*);
            for (exp.*.sinks.items) |sink| ex.writeSink(sink, list);
        }
    }

    /// Fold every parked driver whose awaited fact has fired, to quiescence.
    /// Resuming one retires it, which can close the set the next is waiting
    /// on — so the loop runs until nothing moves. Whatever is left is handed
    /// to the worklist, which refuses it as the expansion deadlock.
    fn drainParked(ex: *Expansion) void {
        var progress = true;
        while (progress) {
            progress = false;
            var i: usize = 0;
            while (i < ex.parked.items.len) {
                var p = ex.parked.items[i];
                ex.awaited = null;
                ex.just_parked = false;
                _ = p.group.expandDriverBody(p.decl, p.src, p.declared, p.cursor);
                if (ex.just_parked) {
                    ex.just_parked = false;
                    ex.parked.items[i].awaited = ex.awaited orelse p.awaited;
                    i += 1;
                    continue;
                }
                ex.self.expansion.retire(p.decl);
                _ = ex.parked.orderedRemove(i);
                progress = true;
            }
        }
        // The diagnostic is about the driver, not about how many views of its
        // module reached it.
        var named = std.AutoHashMap(*const Node, void).init(ex.self.alloc);
        defer named.deinit();
        for (ex.parked.items) |p| {
            if (named.contains(p.decl)) continue;
            named.put(p.decl, {}) catch {};
            ex.self.expansion.parkDriver(driverWhat(p.decl), p.awaited, driverSpan(p.decl));
        }
    }

    fn parkDriver(ex: *Expansion, group: Group, decl: *const Node, src: ?[]const u8, declared: ?*std.StringHashMap([]const u8), cursor: []const u8) void {
        // One driver node is reachable from several views of its module, and
        // each view holds its own slot — so each waits on its own bookmark.
        for (ex.parked.items) |p| {
            if (p.decl == decl and p.group.out == group.out) return;
        }
        ex.parked_any = true;
        ex.parked.append(ex.self.alloc, .{
            .decl = decl,
            .src = src,
            .group = group,
            .declared = declared,
            .cursor = cursor,
            .awaited = ex.awaited orelse "",
        }) catch {};
    }

    /// The one canonical membership read, asked by a driver condition. A
    /// positive is readable the moment it exists — membership only grows. A
    /// negative is utterable only against a set nothing can still grow, so an
    /// open set parks the driver against the fact instead of answering
    /// something the very next driver could contradict.
    fn readMembership(ex: *Expansion, proto_node: *const Node, target: TypeId) ?bool {
        const query = ex.self.taggedMembershipOf(proto_node, target) orelse return null;
        return switch (query.state) {
            .member => true,
            .absent_final => false,
            .absent_unstable => blk: {
                ex.awaited = std.fmt.allocPrint(ex.self.alloc, "'{s}' membership of '{s}' to be final", .{
                    ex.self.formatTypeName(query.proto),
                    ex.self.formatTypeName(target),
                }) catch "a tagged conformer set to be final";
                break :blk null;
            },
        };
    }

    /// The sole evaluator of a module-scope driver condition. It folds the
    /// facts the scan primed (targets, module constants) and, where the
    /// condition asks about the program instead, drives what the answer needs:
    /// the `#run` a named constant binds, the declarations a membership
    /// question names. Whichever route answers, the driver is the worklist's.
    fn driveCondition(ex: *Expansion, node: *const Node, src: ?[]const u8, depth: u8) ?bool {
        if (depth > 16) return null;
        switch (node.data) {
            .unary_op => |uo| {
                if (uo.op != .not) return null;
                const inner = ex.driveCondition(uo.operand, src, depth + 1) orelse return null;
                return !inner;
            },
            .binary_op => |bo| {
                if (bo.op == .and_op) {
                    const lhs = ex.driveCondition(bo.lhs, src, depth + 1) orelse return null;
                    if (!lhs) return false;
                    return ex.driveCondition(bo.rhs, src, depth + 1);
                }
                if (bo.op == .or_op) {
                    const lhs = ex.driveCondition(bo.lhs, src, depth + 1) orelse return null;
                    if (lhs) return true;
                    return ex.driveCondition(bo.rhs, src, depth + 1);
                }
                return ex.self.evalComptimeCondition(node);
            },
            .identifier => |id| {
                if (ex.self.evalComptimeCondition(node)) |folded| return folded;
                const cd = constNamed(ex, id.name, src) orelse return null;
                return ex.driveCondition(cd.value, src, depth + 1);
            },
            .comptime_expr => |ce| {
                if (!ex.self.expansion.claimRun(node)) return null;
                defer ex.self.expansion.releaseRun(node);
                return ex.driveCondition(ce.expr, src, depth + 1);
            },
            .call => return ex.driveMembershipCondition(node, src),
            else => return ex.self.evalComptimeCondition(node),
        }
    }

    /// `has_impl(P, T)` as a driver condition. The question is answerable only
    /// against real declarations, so the names it spells are registered first;
    /// the answer itself comes from the one canonical membership source, which
    /// refuses a negative no unexpanded branch has ruled out yet.
    fn driveMembershipCondition(ex: *Expansion, node: *const Node, src: ?[]const u8) ?bool {
        const c = node.data.call;
        const callee = ast.bareName(c.callee) orelse return null;
        if (!std.mem.eql(u8, callee, "has_impl") or c.args.len < 2) return null;
        const proto_name = ast.bareName(protocolHead(c.args[0])) orelse return null;
        ex.primeMembershipFacts(proto_name, c.args[1], src);
        // Only `tagged` answers here. The other kinds ask about site-local impl
        // VISIBILITY, which is a fact of the lowered program rather than of the
        // declarations — nothing has been lowered yet, so the question has no
        // answer at expansion and the driver takes the ordinary refusal.
        if (!ex.taggedProtocolNamed(proto_name)) return null;
        const target = ex.self.resolveTypeArg(c.args[1]);
        if (target == .unresolved) return null;
        return ex.readMembership(c.args[0], target);
    }

    fn taggedProtocolNamed(ex: *Expansion, name: []const u8) bool {
        const resolver = ex.self.protocolResolver();
        if (resolver.resolveProtocol(name, ex.self.current_source_file)) |p| {
            if (p.ty) |pty| return ex.self.isTagged(pty);
        }
        if (resolver.resolveParamProtocolHead(name, null)) |pd| return pd.kind == .tagged;
        return false;
    }

    /// Register what a membership question names: the protocol, the queried
    /// type, and every impl of that protocol the program declares. The search
    /// spans the whole root list rather than what registration has reached, so
    /// the answer does not depend on where the driver sits among the
    /// declarations it asks about.
    fn primeMembershipFacts(ex: *Expansion, proto_name: []const u8, target: *const Node, src: ?[]const u8) void {
        ex.primeDecl(proto_name);
        if (ast.bareName(protocolHead(target))) |tname| ex.primeDecl(tname);
        var it = ex.decidedDecls();
        while (it.next()) |decl| {
            if (decl.data != .impl_block) continue;
            const ib = decl.data.impl_block;
            if (!std.mem.eql(u8, ib.protocol_name, proto_name)) continue;
            if (ib.target_type.len > 0) ex.primeDecl(ib.target_type);
        }
        it = ex.decidedDecls();
        while (it.next()) |decl| {
            if (decl.data != .impl_block) continue;
            if (!std.mem.eql(u8, decl.data.impl_block.protocol_name, proto_name)) continue;
            ex.self.setCurrentSourceFile(decl.source_file);
            ex.self.protocolResolver().registerImplBlock(&decl.data.impl_block, false, decl);
        }
        ex.self.setCurrentSourceFile(src);
    }

    /// Register the declaration `name` denotes, wherever the program authors
    /// it. Only the type-shaped declarations a membership question can name
    /// answer here; everything else stays for the scan.
    fn primeDecl(ex: *Expansion, name: []const u8) void {
        if (ex.primed.contains(name)) return;
        ex.primed.put(name, {}) catch {};
        var it = ex.decidedDecls();
        while (it.next()) |decl| {
            const declared = decl.data.declName() orelse continue;
            if (!std.mem.eql(u8, declared, name)) continue;
            ex.self.setCurrentSourceFile(decl.source_file);
            switch (decl.data) {
                .protocol_decl => |*pd| ex.self.registerProtocolDecl(pd),
                .struct_decl => |*sd| ex.self.registerStructDecl(sd, decl.source_file),
                .enum_decl => |*ed| ex.self.registerEnumDecl(ed),
                .union_decl => |*ud| ex.self.registerUnionDecl(ud),
                .const_decl => |cd| switch (cd.value.data) {
                    .protocol_decl => |*pd| ex.self.registerProtocolDecl(pd),
                    .struct_decl => |*sd| ex.self.registerStructDecl(sd, decl.source_file),
                    .enum_decl => |*ed| ex.self.registerEnumDecl(ed),
                    .union_decl => |*ud| ex.self.registerUnionDecl(ud),
                    else => {},
                },
                else => {},
            }
        }
    }

    fn decidedDecls(ex: *Expansion) DecidedDecls {
        return .{ .textual = ex.scope, .spliced = ex.spliced.items };
    }

    /// A `#error` reached in live code. A non-selected group never reaches
    /// here, which is how `std/c.sx`'s per-target tables guard their `else`
    /// arms.
    fn raise(ex: *Expansion, decl: *const Node) void {
        if (ex.raised.contains(decl)) return;
        ex.raised.put(decl, {}) catch {};
        const diags = ex.self.diagnostics orelse return;
        ex.self.setCurrentSourceFile(decl.source_file);
        diags.addFmt(.err, decl.span, "{s}", .{decl.data.error_directive.message});
    }
};

/// A walk over the DECIDED declaration space: what the program wrote, then
/// what taken groups have added so far. A driver asking about the program is
/// answered against both — a group already spliced is module scope.
const DecidedDecls = struct {
    textual: []const *Node,
    spliced: []const *Node,
    i: usize = 0,

    fn next(it: *DecidedDecls) ?*Node {
        if (it.i < it.textual.len) {
            defer it.i += 1;
            return it.textual[it.i];
        }
        const k = it.i - it.textual.len;
        if (k >= it.spliced.len) return null;
        it.i += 1;
        return it.spliced[k];
    }
};

/// The head of a protocol or type spelling: `Series(f32)` names `Series`, a
/// bare `View` names itself.
fn protocolHead(node: *const Node) *const Node {
    return if (node.data == .call) node.data.call.callee else node;
}

fn isTargetEnumName(name: []const u8) bool {
    return std.mem.eql(u8, name, "OperatingSystem") or std.mem.eql(u8, name, "Architecture");
}

/// The name of the driver class in a diagnostic — what the deadlock report
/// calls the thing that cannot be decided.
fn driverWhat(decl: *const Node) []const u8 {
    return switch (decl.data) {
        .for_expr => "this `inline for`",
        .match_expr => "this `inline if ... ==`",
        else => "this `inline if`",
    };
}

/// Where the diagnostic points: the question the driver could not answer.
fn driverSpan(decl: *const Node) ast.Span {
    return switch (decl.data) {
        .if_expr => |ie| ie.condition.span,
        else => decl.span,
    };
}

/// One driver's expansion cursor: the slot its selected declarations land in,
/// and the dedup state a branch-local flat import merges against.
const Group = struct {
    ex: *Expansion,
    out: *std.ArrayList(*Node),
    ledger: *Ledger,

    /// Whether this driver's declarations still need their module-scope facts
    /// minted. A driver reached through a second view of its module produces
    /// the same declarations again, but mints nothing twice.
    fn claimRegistration(g: *Group, decl: *const Node) bool {
        if (g.ex.expanded.contains(decl)) return false;
        g.ex.expanded.put(decl, {}) catch {};
        return true;
    }

    /// Fold one driver and splice its selected group. `declared` is the
    /// per-`inline for` name ledger (null outside one); false means the
    /// expansion was abandoned after a diagnostic.
    fn expandDriver(g: *Group, decl: *const Node, src: ?[]const u8, declared: ?*std.StringHashMap([]const u8), cursor: []const u8) bool {
        g.ex.self.expansion.registerDriver(decl);
        g.ex.just_parked = false;
        const done = g.expandDriverBody(decl, src, declared, cursor);
        // A driver that parked is not decided: it holds its contributions until
        // the fact it awaits fires and the drain folds it.
        if (g.ex.just_parked) {
            g.ex.just_parked = false;
            g.ex.parkDriver(g.*, decl, src, declared, cursor);
            return done;
        }
        // Taken, rejected, or out of iterations — the driver is decided, and
        // exactly the contributions it registered come back.
        g.ex.self.expansion.retire(decl);
        return done;
    }

    fn expandDriverBody(g: *Group, decl: *const Node, src: ?[]const u8, declared: ?*std.StringHashMap([]const u8), cursor: []const u8) bool {
        g.ex.self.setCurrentSourceFile(src);
        switch (decl.data) {
            .if_expr => |ie| {
                g.ex.awaited = null;
                const folded = g.ex.driveCondition(ie.condition, src, 0);
                // A read that cannot answer yet parks the whole fold: nothing
                // is claimed, nothing is spliced, and the driver stays
                // undecided until its fact fires.
                if (folded == null and g.ex.awaited != null) {
                    g.ex.just_parked = true;
                    return true;
                }
                const mint = g.claimRegistration(decl);
                const is_true = folded orelse {
                    // Never silently discard the declarations of an unevaluable
                    // module-scope conditional (issue 0241): a live function,
                    // import, or asm block would vanish and surface as a
                    // distant unresolved-name error.
                    if (mint) {
                        if (g.ex.self.diagnostics) |diags| {
                            diags.addFmt(.err, ie.condition.span, "cannot evaluate this module-scope `inline if` condition; it must fold to a compile-time constant", .{});
                        }
                    }
                    return true;
                };
                const taken: ?*const Node = if (is_true) ie.then_branch else ie.else_branch;
                const body = taken orelse return true;
                return g.spliceGroup(body, src, mint, declared, cursor);
            },
            .match_expr => |me| {
                const mint = g.claimRegistration(decl);
                const body = g.ex.self.evalComptimeMatch(&me) orelse return true;
                return g.spliceGroup(body, src, mint, declared, cursor);
            },
            .for_expr => |fe| return g.expandInlineFor(decl, &fe, src, g.claimRegistration(decl)),
            else => return true,
        }
    }

    fn spliceGroup(g: *Group, body: *const Node, src: ?[]const u8, mint: bool, declared: ?*std.StringHashMap([]const u8), cursor: []const u8) bool {
        const stmts: []const *Node = if (body.data == .block)
            body.data.block.stmts
        else
            &[_]*Node{@constCast(body)};
        for (stmts) |stmt| {
            if (imports.isModuleDriver(stmt)) {
                if (!g.expandDriver(stmt, src, declared, cursor)) return false;
                continue;
            }
            g.ex.self.setCurrentSourceFile(src);
            switch (stmt.data) {
                .error_directive => g.ex.raise(stmt),
                .import_decl => g.spliceImport(stmt, src, mint),
                .asm_expr, .asm_global => g.spliceGlobalAsm(stmt, src, mint),
                else => if (!g.spliceDecl(stmt, src, mint, declared, cursor)) return false,
            }
        }
        return true;
    }

    /// A module-level `asm { "tmpl", };` inside a group was parsed by the
    /// STATEMENT parser, so it arrives as an in-function `.asm_expr` — not the
    /// `.asm_global` the top-level parser produces. Once its branch is
    /// selected the node IS module-scope global asm: retag it so lowering's
    /// `.asm_global` arm appends the template to `module.global_asm` (issue
    /// 0194). `parseAsmGlobal`'s top-level restrictions apply: template only.
    fn spliceGlobalAsm(g: *Group, stmt: *Node, src: ?[]const u8, mint: bool) void {
        if (stmt.data == .asm_global) {
            g.out.append(g.ex.self.alloc, stmt) catch {};
            return;
        }
        const ae = &stmt.data.asm_expr;
        if (ae.is_volatile) {
            if (mint) {
                if (g.ex.self.diagnostics) |diags| diags.addFmt(.err, stmt.span, "global (top-level) asm cannot be `volatile`", .{});
            }
            return;
        }
        if (ae.operands.len > 0 or ae.clobbers.len > 0) {
            if (mint) {
                if (g.ex.self.diagnostics) |diags| diags.addFmt(.err, stmt.span, "global (top-level) asm takes no operands, inputs, or clobbers — only a template string", .{});
            }
            return;
        }
        stmt.data = .{ .asm_global = .{ .template = ae.template } };
        stmt.source_file = src;
        g.out.append(g.ex.self.alloc, stmt) catch {};
    }

    /// Splice a branch-local `#import`. Its module resolved re-entrantly during
    /// import resolution and has been waiting in the module cache under the
    /// canonical path the node now carries; selecting the branch is what makes
    /// it a real edge of the importing file.
    fn spliceImport(g: *Group, stmt: *const Node, src: ?[]const u8, mint: bool) void {
        const self = g.ex.self;
        const imp = stmt.data.import_decl;
        const source = src orelse self.main_file orelse return;
        const cache = self.program_index.module_cache orelse return;
        const imported = cache.get(imp.path) orelse return;

        if (mint) {
            if (self.program_index.import_graph) |graph| {
                if (graph.getPtr(source)) |set| set.put(imp.path, {}) catch {};
            }
            if (imp.name == null) {
                if (self.program_index.flat_import_graph) |graph| {
                    if (graph.getPtr(source)) |set| set.put(imp.path, {}) catch {};
                }
            }
        }

        if (imp.name) |ns_name| {
            if (mint and !g.claimName(ns_name, source, stmt.visibility, stmt.span)) return;
            const ns_node = self.alloc.create(Node) catch return;
            ns_node.* = .{
                .span = stmt.span,
                .data = .{ .namespace_decl = .{
                    .name = ns_name,
                    .decls = imported.decls,
                    .own_decls = imported.own_decls,
                    .target_module_path = imported.path,
                    .is_raw = imp.is_raw,
                } },
                .visibility = stmt.visibility,
            };
            if (mint) g.mintFacts(ns_node, source);
            g.emit(ns_node);
            return;
        }

        // A flat import merges the imported module's transitive declarations
        // into the importing module's list — never into its own surface. The
        // merged list is unexpanded: this is the only place a module reached
        // solely through a branch is ever walked, so its own drivers fold here.
        if (g.ledger.kind == .own) return;
        for (imported.decls) |decl| {
            if (imports.isModuleDriver(decl)) {
                _ = g.expandDriver(decl, decl.source_file, null, "");
                continue;
            }
            if (decl.data == .error_directive) {
                g.ex.raise(decl);
                continue;
            }
            if (g.ledger.nodes.contains(decl)) continue;
            if (decl.data.declName()) |name| {
                if (g.ledger.names.contains(name)) {
                    if (!imports.ResolvedModule.isPerSourceDecl(decl)) continue;
                } else g.ledger.names.put(name, {}) catch {};
            }
            g.ledger.nodes.put(decl, {}) catch {};
            g.ex.decided(decl);
            g.out.append(self.alloc, decl) catch {};
        }
    }

    /// Splice one declaration AUTHORED by the group. It becomes module surface
    /// of the driver's own file: same scope entry, same provenance stamp, same
    /// raw fact and `DeclId` a textual declaration gets.
    fn spliceDecl(g: *Group, stmt: *Node, src: ?[]const u8, mint: bool, declared: ?*std.StringHashMap([]const u8), cursor: []const u8) bool {
        const self = g.ex.self;
        const source = src orelse self.main_file orelse return true;
        if (stmt.data.declName()) |name| {
            if (declared) |ledger| {
                if (ledger.get(name)) |first_cursor| {
                    if (mint) {
                        if (self.diagnostics) |diags| {
                            const id = diags.addFmtId(.err, stmt.span, "`inline for` expansion declares '{s}' more than once — a declaration group flattens into module scope", .{name});
                            diags.addNoteFmt(id, stmt.span, "first at {s}", .{first_cursor});
                            diags.addNoteFmt(id, stmt.span, "again at {s}", .{cursor});
                            diags.addHelp(id, stmt.span, "parameterize the declaration instead of re-declaring it per iteration", null);
                        }
                    }
                    return false;
                }
                ledger.put(name, cursor) catch {};
            }
            if (mint and !g.claimName(name, source, stmt.visibility, stmt.span)) return true;
        }
        stmt.source_file = source;
        imports.stampFnBodySource(stmt, source);
        if (mint) g.mintFacts(stmt, source);
        g.emit(stmt);
        return true;
    }

    /// Place a declaration the group authored. In a transitive list it also
    /// takes part in the cross-module first-wins merge — except a per-source
    /// declaration, which must reach registration as its own module's author.
    fn emit(g: *Group, decl: *Node) void {
        if (g.ledger.kind == .transitive) {
            if (decl.data.declName()) |name| {
                if (g.ledger.names.contains(name)) {
                    if (!imports.ResolvedModule.isPerSourceDecl(decl)) return;
                } else g.ledger.names.put(name, {}) catch {};
            }
        }
        g.ledger.nodes.put(decl, {}) catch {};
        g.ex.decided(decl);
        g.out.append(g.ex.self.alloc, decl) catch {};
    }

    /// Claim `name` in the declaring file's module scope. False when the file
    /// already declares it — a group shares one module scope with the text
    /// around it, so a second author is the ordinary duplicate error.
    fn claimName(g: *Group, name: []const u8, source: []const u8, visibility: ast.Visibility, span: ast.Span) bool {
        const self = g.ex.self;
        const scopes = self.program_index.module_scopes orelse return true;
        const scope = scopes.getPtr(source) orelse return true;
        if (scope.contains(name)) {
            if (self.diagnostics) |diags| {
                diags.addFmt(.err, span, "duplicate top-level declaration '{s}'", .{name});
            }
            return false;
        }
        scope.put(name, visibility) catch {};
        return true;
    }

    fn mintFacts(g: *Group, decl: *Node, source: []const u8) void {
        const self = g.ex.self;
        if (self.program_index.module_decls) |decls| {
            if (self.program_index.namespace_edges) |edges| {
                imports.indexOneDecl(self.alloc, decls, edges, source, decl) catch {};
            }
        }
        if (self.program_index.decl_table) |table| {
            if (imports.rawDeclRefOf(decl) != null) _ = table.intern(source, decl) catch {};
        }
    }

    /// Expand a module-scope `inline for` into one declaration group per
    /// element of its comptime type list. The cursor binds each element as a
    /// type name, substituted through the cloned group.
    fn expandInlineFor(g: *Group, decl: *const Node, fe: *const ast.ForExpr, src: ?[]const u8, mint: bool) bool {
        const self = g.ex.self;
        const diags = if (mint) self.diagnostics else null;
        if (fe.captures.len == 0 or fe.captures[0].name.len == 0) {
            if (diags) |d| d.addFmt(.err, decl.span, "a module-scope `inline for` needs a cursor — `inline for LIST (T) {{ … }}`", .{});
            return true;
        }
        if (fe.captures[0].by_ref) {
            if (diags) |d| d.addFmt(.err, decl.span, "a type-list cursor cannot be captured by reference", .{});
            return true;
        }
        const list_iterable = fe.iterables[0];
        if (list_iterable.is_range) {
            if (diags) |d| d.addFmt(.err, list_iterable.expr.span, "a module-scope `inline for` iterates a comptime type list — `inline for .[A, B] (T) {{ … }}`", .{});
            return true;
        }
        const literal = typeListLiteral(g.ex, list_iterable.expr, src, 0) orelse {
            if (diags) |d| d.addFmt(.err, list_iterable.expr.span, "a module-scope `inline for` iterates a comptime type list — this is not an array literal or a constant bound to one", .{});
            return true;
        };

        // Elements are bare type names: the cursor is substituted into type
        // position, including an `impl`'s target-type spelling, which carries
        // no node. Instantiations reach the list through a type alias.
        for (literal.elements) |element| {
            if (ast.bareName(element) != null) continue;
            if (diags) |d| d.addFmt(.err, element.span, "a type-list element must name a type; bind an instantiation to a type alias first (`B :: Buffer(f64);`)", .{});
            return true;
        }
        for (literal.elements, 0..) |element, i| {
            const name = ast.bareName(element).?;
            for (literal.elements[0..i], 0..) |earlier, j| {
                if (!std.mem.eql(u8, ast.bareName(earlier).?, name)) continue;
                if (diags) |d| {
                    const id = d.addFmtId(.err, element.span, "type list repeats '{s}' — each element expands its own declaration group", .{name});
                    d.addNoteFmt(id, earlier.span, "first at element {d}", .{j});
                    d.addNoteFmt(id, element.span, "again at element {d}", .{i});
                }
                return true;
            }
        }

        // Declaration names produced by the expansion, with the cursor that
        // produced each — the groups share one module scope, so a name that
        // does not vary with the cursor collides with itself. A driver inside
        // the unroll can park holding it, so it outlives the unroll.
        const declared = self.alloc.create(std.StringHashMap([]const u8)) catch return true;
        declared.* = std.StringHashMap([]const u8).init(self.alloc);
        g.ex.cursors.append(self.alloc, declared) catch {};

        for (literal.elements, 0..) |element, i| {
            var subst = ast.Substitution.init(self.alloc);
            defer subst.deinit();
            subst.put(fe.captures[0].name, element) catch return true;
            if (fe.captures.len > 1 and fe.captures[1].name.len > 0) {
                const index_node = self.alloc.create(Node) catch return true;
                index_node.* = .{ .span = decl.span, .data = .{ .int_literal = .{ .value = @intCast(i) } } };
                subst.put(fe.captures[1].name, index_node) catch return true;
            }
            const cursor = renderCursor(self.alloc, fe.captures, element, i) catch return true;

            const stmts: []const *Node = if (fe.body.data == .block)
                fe.body.data.block.stmts
            else
                &[_]*Node{fe.body};
            var iteration = std.ArrayList(*Node).empty;
            defer iteration.deinit(self.alloc);
            for (stmts) |stmt| {
                const clone = ast.cloneWithSubst(self.alloc, stmt, &subst) catch return true;
                iteration.append(self.alloc, clone) catch return true;
            }
            const body = self.alloc.create(Node) catch return true;
            body.* = .{
                .span = decl.span,
                .data = .{ .block = .{ .stmts = iteration.toOwnedSlice(self.alloc) catch return true, .produces_value = false } },
            };
            if (!g.spliceGroup(body, src, mint, declared, cursor)) return false;
        }
        return true;
    }
};

/// Follow an `inline for` iterable to the array literal it names: the literal
/// written in the header, a `NAME :: .[…]` constant, or a chain of constant
/// aliases ending in one. The driver's own file authors it when it can;
/// otherwise any module's same-named constant answers, matching how a
/// flat-imported list is reached.
fn typeListLiteral(ex: *Expansion, node: *const Node, src: ?[]const u8, depth: u8) ?*const ast.ArrayLiteral {
    if (depth > 8) return null;
    switch (node.data) {
        .array_literal => |*al| return al,
        .identifier => |id| {
            const target = constNamed(ex, id.name, src) orelse return null;
            return typeListLiteral(ex, target.value, src, depth + 1);
        },
        else => return null,
    }
}

fn constNamed(ex: *Expansion, name: []const u8, src: ?[]const u8) ?*const ast.ConstDecl {
    var fallback: ?*const ast.ConstDecl = null;
    for (ex.scope) |decl| {
        if (decl.data != .const_decl) continue;
        const cd = &decl.data.const_decl;
        if (!std.mem.eql(u8, cd.name, name)) continue;
        if (src) |s| {
            if (decl.source_file) |ds| {
                if (std.mem.eql(u8, ds, s)) return cd;
            }
        }
        if (fallback == null) fallback = cd;
    }
    return fallback;
}

/// One expanded iteration's cursor bindings, rendered for diagnostics
/// ("T = Point", "T = Point, i = 1").
fn renderCursor(allocator: std.mem.Allocator, captures: []const ast.ForCapture, element: *const Node, index: usize) std.mem.Allocator.Error![]const u8 {
    const type_name = ast.bareName(element) orelse "?";
    if (captures.len > 1 and captures[1].name.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} = {s}, {s} = {d}", .{ captures[0].name, type_name, captures[1].name, index });
    }
    return std.fmt.allocPrint(allocator, "{s} = {s}", .{ captures[0].name, type_name });
}
