//! The one worklist lowering drains for expansion.
//!
//! Three driver classes register here and nowhere else: the conditions and
//! iterables of module-scope `inline if` / `inline for`, the `#run`s those
//! conditions reach, and the comptime the conformer fixpoint reaches by
//! monomorphizing an admitted impl. Each is REGISTERED before it runs and
//! RETIRED when it is decided, so the program's declaration space has an
//! answer to "can anything still add to this?" at every instant.
//!
//! A driver that has not been decided may still contribute declarations, and
//! which ones is judged SYNTACTICALLY and conservatively (specs.md §7.9): an
//! unexpanded body mentioning `impl P for …` contributes to `P`'s sets, and
//! every declaration name it spells is a name the module scope may still gain.
//! Every branch and every iteration counts — the whole node is unexpanded, so
//! no arm can be ruled out yet.
//!
//! Contributions are what finality reads. `setFinal` cannot publish a negative
//! about a protocol some unexpanded body still mentions, and a namespace's
//! member surface publishes only once no driver can still declare into it.
//! Positives are untouched: membership only grows, so a pair that IS in a set
//! is readable the moment it lands.
//!
//! A unit that needs a fact none of that can answer yet PARKS here rather than
//! failing: a driver whose condition asked, or a whole evaluation suspended at
//! the instruction that asked — which keeps its VM, task, heap, and VM-local
//! Context for as long as the worklist holds it. The drain resumes each one
//! when its fact fires. Quiescence with a bookmark still down is the
//! expansion deadlock, and it is ONE diagnostic naming every parked unit.

const std = @import("std");
const ast = @import("../../ast.zig");
const errors = @import("../../errors.zig");
const comptime_vm = @import("../comptime_vm.zig");
const Node = ast.Node;

/// What a driver is. The drain treats all three alike — register, run, retire
/// — and the kind exists so a class can be recognized in the registry.
pub const Kind = enum {
    /// A module-scope `inline if` / `inline if X == { … }` / `inline for`.
    module_driver,
    /// A `#run` a driver's condition reached.
    run,
    /// One round of the conformer fixpoint: admitting declared impls and
    /// materializing the arms whose monomorphization reaches further comptime.
    monomorphization,
};

/// One registered driver, holding exactly what retiring gives back: the
/// protocols its unexpanded branches could `impl`, and how many names they
/// could declare into `scope` — the module scope the driver was written in.
const Item = struct {
    kind: Kind,
    impls: []const []const u8,
    scope: []const u8,
    names: []const []const u8,
    retired: bool,
};

/// Work the drain cannot run: a driver whose condition asked a question no set
/// can answer yet, or an evaluation suspended at the instruction that asked
/// one. A parked evaluation OWNS its VM — heap, task, and VM-local Context —
/// until it is resumed or refused, so the bookmark it left is intact for as
/// long as the worklist holds it.
pub const Parked = struct {
    /// The suspended evaluation, or null when a driver's fold is what waits.
    evaluation: ?*comptime_vm.Evaluation,
    /// What to call it in the diagnostic, and the fact it awaits.
    what: []const u8,
    awaited: []const u8,
    span: ast.Span,
};

pub const Worklist = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Item),
    /// Everything the drain left waiting. Quiescence with any of these is the
    /// expansion deadlock.
    parked: std.ArrayList(Parked) = .empty,
    /// Registered driver nodes, so a driver reached through a second view of
    /// its module registers its contributions exactly once.
    known: std.AutoHashMap(*const Node, usize),
    /// Protocol name → how many unretired drivers could still `impl` it.
    open_impls: std.StringHashMap(u32),
    /// Source file → how many names unretired drivers could still declare into
    /// that module's scope. A namespace's member surface is a claim about
    /// exactly this, so it publishes only at zero.
    open_names: std.StringHashMap(u32),
    /// `scope \x00 name` → how many unretired drivers could still declare that
    /// exact name there. A LOOKUP asks about one name, so it reads this rather
    /// than the whole scope: a driver waiting on a name it does not itself
    /// declare is not waiting on itself.
    open_decls: std.StringHashMap(u32),
    /// `#run` nodes being driven right now — a condition that reaches the run
    /// it is itself part of would otherwise recurse forever.
    driving: std.AutoHashMap(*const Node, void),
    /// Registered-but-untaken monomorphization rounds.
    rounds: u32 = 0,
    /// The fact a threshold read could not answer yet. The read is deep inside
    /// lowering; the unit that must park is the driver whose fold reached it,
    /// so the read records the fact here and the fold consumes it.
    awaited: ?[]const u8 = null,
    /// True while a module-scope driver's condition is being folded. Only there
    /// can a non-monotone read WAIT — an ordinary body is lowered once the
    /// declaration space is decided, so nothing it reads can change again.
    folding: bool = false,

    pub fn init(alloc: std.mem.Allocator) Worklist {
        return .{
            .alloc = alloc,
            .items = std.ArrayList(Item).empty,
            .known = std.AutoHashMap(*const Node, usize).init(alloc),
            .open_impls = std.StringHashMap(u32).init(alloc),
            .open_names = std.StringHashMap(u32).init(alloc),
            .open_decls = std.StringHashMap(u32).init(alloc),
            .driving = std.AutoHashMap(*const Node, void).init(alloc),
        };
    }

    /// Register a module-scope driver with the contributions its unexpanded
    /// branches could still make. Idempotent per node.
    pub fn registerDriver(w: *Worklist, node: *const Node) void {
        if (w.known.contains(node)) return;
        var scan = Scan{
            .alloc = w.alloc,
            .impls = std.ArrayList([]const u8).empty,
            .names = std.ArrayList([]const u8).empty,
        };
        scan.driver(node, 0);
        const impls = scan.impls.toOwnedSlice(w.alloc) catch &.{};
        // The names land in the scope of the file the driver was written in.
        const scope = node.source_file orelse "";
        const names = scan.names.toOwnedSlice(w.alloc) catch &.{};
        for (impls) |p| bump(&w.open_impls, p);
        if (names.len > 0) bumpBy(&w.open_names, scope, @intCast(names.len));
        for (names) |n| bump(&w.open_decls, w.declKey(scope, n));
        w.known.put(node, w.items.items.len) catch {};
        w.items.append(w.alloc, .{
            .kind = .module_driver,
            .impls = impls,
            .scope = scope,
            .names = names,
            .retired = false,
        }) catch {};
    }

    /// A driver has been decided — taken, rejected, or run out of iterations.
    /// Exactly the contributions it was registered with come back.
    pub fn retire(w: *Worklist, node: *const Node) void {
        const idx = w.known.get(node) orelse return;
        const item = &w.items.items[idx];
        if (item.retired) return;
        item.retired = true;
        for (item.impls) |p| drop(&w.open_impls, p);
        if (item.names.len > 0) dropBy(&w.open_names, item.scope, @intCast(item.names.len));
        for (item.names) |n| drop(&w.open_decls, w.declKey(item.scope, n));
    }

    /// Register a driver of a non-declaration class. These contribute no
    /// declarations of their own — a `#run` computes a value, a fixpoint round
    /// monomorphizes bodies — so they carry an empty contribution set and
    /// retire as soon as they are drained.
    pub fn note(w: *Worklist, kind: Kind) void {
        w.items.append(w.alloc, .{
            .kind = kind,
            .impls = &.{},
            .scope = "",
            .names = &.{},
            .retired = true,
        }) catch {};
    }

    /// Register a round of the conformer fixpoint. Admitting a member or
    /// materializing an arm re-registers, so the drain runs exactly as long as
    /// monomorphization keeps reaching new ground.
    pub fn pushRound(w: *Worklist) void {
        w.note(.monomorphization);
        w.rounds += 1;
    }

    /// Take the next registered round, or false when the fixpoint is drained.
    pub fn takeRound(w: *Worklist) bool {
        if (w.rounds == 0) return false;
        w.rounds -= 1;
        return true;
    }

    /// Claim a `#run` for driving. False when it is already on the stack —
    /// a condition reachable from its own run has no value to read.
    pub fn claimRun(w: *Worklist, node: *const Node) bool {
        if (w.driving.contains(node)) return false;
        w.driving.put(node, {}) catch return false;
        w.note(.run);
        return true;
    }

    pub fn releaseRun(w: *Worklist, node: *const Node) void {
        _ = w.driving.remove(node);
    }

    /// A driver the drain could not fold: it awaits `awaited`, and until that
    /// fires it stays undecided — its contributions are still out.
    pub fn parkDriver(w: *Worklist, what: []const u8, awaited: []const u8, span: ast.Span) void {
        w.parked.append(w.alloc, .{
            .evaluation = null,
            .what = what,
            .awaited = awaited,
            .span = span,
        }) catch {};
    }

    /// An evaluation suspended at the instruction that asked the fact. The
    /// worklist owns it from here: its VM, task, heap, and VM-local Context
    /// stay alive until it resumes or the deadlock refuses it.
    pub fn parkEvaluation(w: *Worklist, evaluation: *comptime_vm.Evaluation, what: []const u8, awaited: []const u8, span: ast.Span) void {
        w.parked.append(w.alloc, .{
            .evaluation = evaluation,
            .what = what,
            .awaited = awaited,
            .span = span,
        }) catch {};
    }

    /// Runnable work is exhausted and something is still parked: every waiting
    /// unit needs a fact only another waiting unit could publish, which is a
    /// program admitting more than one consistent outcome. ONE diagnostic names
    /// them all and the facts they await (§7.9); sx refuses rather than
    /// electing a fixpoint.
    pub fn reportDeadlock(w: *Worklist, diagnostics: ?*errors.DiagnosticList) void {
        if (w.parked.items.len == 0) return;
        if (diagnostics) |d| {
            const id = d.addFmtId(.err, w.parked.items[0].span, "expansion deadlock — nothing can run: every compile-time unit still waiting needs a fact only another waiting unit could publish, so the expansion depends negatively on a set it feeds", .{});
            for (w.parked.items) |p| {
                d.addNoteFmt(id, p.span, "{s} awaits {s}", .{ p.what, p.awaited });
            }
            d.addHelp(id, w.parked.items[0].span, "decide the declaration outside the set it queries — a question whose answer changes what it asks about has no single answer", null);
        }
        for (w.parked.items) |p| {
            if (p.evaluation) |e| e.destroy();
        }
        w.parked.clearRetainingCapacity();
    }

    /// Can an undecided driver still admit a conformer into `name`'s sets?
    pub fn mayImpl(w: *const Worklist, name: []const u8) bool {
        return (w.open_impls.get(name) orelse 0) > 0;
    }

    /// Record the fact a threshold read is waiting on. The FIRST wait of a fold
    /// is the one the diagnostic names: it is the read that could not proceed,
    /// and everything after it in that fold is already speculative.
    pub fn awaitFact(w: *Worklist, fact: []const u8) void {
        if (w.awaited == null) w.awaited = fact;
    }

    /// Is a threshold read reached from here allowed to WAIT? Only a driver's
    /// own fold can be re-run once its fact fires; every other reader is past
    /// the point where the declaration space could still change.
    pub fn scheduled(w: *const Worklist) bool {
        return w.folding;
    }

    /// Has `scope` stopped growing? A namespace's member surface is the answer
    /// to "what does this module declare", so it publishes only once no driver
    /// written there can still add a name.
    pub fn scopeFinal(w: *const Worklist, scope: []const u8) bool {
        return (w.open_names.get(scope) orelse 0) == 0;
    }

    /// Can an undecided driver still declare `name` into `scope`? What a
    /// name LOOKUP waits on: the absence of one name, not the closure of the
    /// whole scope.
    pub fn mayDeclare(w: *Worklist, scope: []const u8, name: []const u8) bool {
        return (w.open_decls.get(w.declKey(scope, name)) orelse 0) > 0;
    }

    fn declKey(w: *Worklist, scope: []const u8, name: []const u8) []const u8 {
        return std.fmt.allocPrint(w.alloc, "{s}\x00{s}", .{ scope, name }) catch name;
    }

    fn bump(map: *std.StringHashMap(u32), key: []const u8) void {
        bumpBy(map, key, 1);
    }

    fn bumpBy(map: *std.StringHashMap(u32), key: []const u8, n: u32) void {
        const e = map.getOrPut(key) catch return;
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + n else n;
    }

    fn drop(map: *std.StringHashMap(u32), key: []const u8) void {
        dropBy(map, key, 1);
    }

    fn dropBy(map: *std.StringHashMap(u32), key: []const u8, n: u32) void {
        const e = map.getPtr(key) orelse return;
        e.* = if (e.* > n) e.* - n else 0;
    }
};

/// The conservative syntactic sweep over an unexpanded driver: every branch of
/// an `inline if`, every arm of its match spelling, and the body of an
/// `inline for` — the cursor is unsubstituted, which only widens the answer.
const Scan = struct {
    alloc: std.mem.Allocator,
    impls: std.ArrayList([]const u8),
    names: std.ArrayList([]const u8),

    fn driver(s: *Scan, node: *const Node, depth: u8) void {
        if (depth > 16) return;
        switch (node.data) {
            .if_expr => |ie| {
                s.body(ie.then_branch, depth);
                if (ie.else_branch) |eb| s.body(eb, depth);
            },
            .match_expr => |me| {
                for (me.arms) |arm| s.body(arm.body, depth);
            },
            .for_expr => |fe| s.body(fe.body, depth),
            else => {},
        }
    }

    fn body(s: *Scan, node: *const Node, depth: u8) void {
        const stmts: []const *Node = if (node.data == .block)
            node.data.block.stmts
        else
            &[_]*Node{@constCast(node)};
        for (stmts) |stmt| {
            switch (stmt.data) {
                .if_expr, .match_expr, .for_expr => s.driver(stmt, depth + 1),
                .impl_block => |ib| s.addImpl(ib.protocol_name),
                .import_decl => |imp| if (imp.name) |ns| s.addName(ns),
                else => {},
            }
            if (stmt.data.declName()) |name| s.addName(name);
        }
    }

    /// An impl head reaches its protocol by whatever spelling is in scope
    /// there, so a qualified `ns.P` counts for `P` as well — the ledger errs
    /// towards keeping a set open.
    fn addImpl(s: *Scan, spelling: []const u8) void {
        s.addImplWord(spelling);
        if (std.mem.lastIndexOfScalar(u8, spelling, '.')) |dot| {
            if (dot + 1 < spelling.len) s.addImplWord(spelling[dot + 1 ..]);
        }
    }

    fn addImplWord(s: *Scan, name: []const u8) void {
        for (s.impls.items) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        s.impls.append(s.alloc, name) catch {};
    }

    fn addName(s: *Scan, name: []const u8) void {
        for (s.names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        s.names.append(s.alloc, name) catch {};
    }
};
