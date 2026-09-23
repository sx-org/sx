//! The one worklist lowering drains for expansion.
//!
//! Three driver classes register here and nowhere else: the conditions and
//! iterables of module-scope `inline if` / `inline for`, the `@run`s those
//! conditions reach, and the comptime the convergence fixpoint reaches by
//! monomorphizing an admitted member. Each is REGISTERED before it runs and
//! RETIRED when it is decided, so the program's declaration space has an
//! answer to "can anything still add to this?" at every instant.
//!
//! A driver that has not been decided may still contribute declarations, and
//! which ones is judged SYNTACTICALLY and conservatively (specs.md §6.9): an
//! unexpanded body mentioning `impl P for …` contributes an impl of `P`, and
//! every declaration name it spells is a name the module scope may still gain,
//! and every `@context.extend` it spells is a field the program Context may
//! still gain. Every branch and every iteration counts — the whole node is
//! unexpanded, so no arm can be ruled out yet.
//!
//! A branch-local `@import` spells a whole MODULE, so the sweep counts what
//! that module authors — transitively, through its own imports and its own
//! unexpanded branches — as contributions the import could still make. The
//! module is read out of the cache it was contained in and nothing is merged:
//! only selecting the branch makes it an edge.
//!
//! Contributions are what finality reads. A negative about a protocol some
//! unexpanded body still mentions cannot be published, and a namespace's
//! member surface publishes only once no driver can still declare into it.
//! Positives are untouched: an impl that IS visible is readable the moment it
//! lands.
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
const imports = @import("../../imports.zig");
const comptime_vm = @import("../comptime_vm.zig");
const Node = ast.Node;
const lookup = @import("../../name_lookup.zig");

/// What a driver is. The drain treats all three alike — register, run, retire
/// — and the kind exists so a class can be recognized in the registry.
pub const Kind = enum {
    /// A module-scope `inline if` / `inline match` / `inline for`.
    module_driver,
    /// A `@run` a driver's condition reached.
    run,
    /// One round of the convergence fixpoint: materializing the arms whose
    /// monomorphization reaches further comptime.
    monomorphization,
};

/// Retirement releases exactly the contributions recorded at registration.
const Item = struct {
    kind: Kind,
    impls: []const []const u8,
    environment: ?imports.EnvironmentId,
    names: []const NameKey,
    pending_imports: []const PendingImport,
    declarations: []const imports.DeclId,
    spreads: []const PendingSpread,
    /// How many `@context.extend` declarations its unexpanded branches could
    /// still put into the program Context.
    contexts: u32,
    retired: bool,
};

const NameKey = struct {
    environment: imports.EnvironmentId,
    name: []const u8,
};

const PendingSpread = struct {
    node: *const Node,
    environment: imports.EnvironmentId,
};

const PendingImport = struct {
    environment: imports.EnvironmentId,
    block: ?imports.LexicalBlockId,
    target: imports.EnvironmentId,
};

const NameKeyContext = struct {
    pub fn hash(_: @This(), key: NameKey) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, key.environment);
        h.update(key.name);
        return h.final();
    }

    pub fn eql(_: @This(), a: NameKey, b: NameKey) bool {
        return a.environment == b.environment and std.mem.eql(u8, a.name, b.name);
    }
};

const NameCounts = std.HashMap(NameKey, u32, NameKeyContext, std.hash_map.default_max_load_percentage);

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
    source_file: ?[]const u8,
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
    open_environments: std.AutoHashMap(imports.EnvironmentId, u32),
    /// A missing name can be final while other names in its environment remain open.
    open_decls: NameCounts,
    /// `@run` nodes being driven right now — a condition that reaches the run
    /// it is itself part of would otherwise recurse forever.
    driving: std.AutoHashMap(*const Node, void),
    /// How many `@context.extend` declarations unretired drivers could still
    /// add. The program Context is ONE layout, so it publishes only at zero.
    open_contexts: u32 = 0,
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
            .open_environments = .init(alloc),
            .open_decls = .init(alloc),
            .driving = std.AutoHashMap(*const Node, void).init(alloc),
        };
    }

    /// Register a module-scope driver with the contributions its unexpanded
    /// branches could still make. `cache` is every resolved module, so a
    /// branch-local `@import`'s module is counted too. Idempotent per node.
    pub fn registerDriver(w: *Worklist, node: *const Node, environment: ?imports.EnvironmentId, table: *imports.DeclTable, cache: ?*const imports.ModuleCache) void {
        if (w.known.contains(node)) return;
        var scan = Scan{
            .alloc = w.alloc,
            .cache = cache,
            .table = table,
            .impls = std.ArrayList([]const u8).empty,
            .names = .empty,
            .counted = .init(w.alloc),
        };
        defer scan.counted.deinit();
        scan.driver(node, 0, environment);
        const impls = scan.impls.toOwnedSlice(w.alloc) catch @panic("out of memory");
        const names = scan.names.toOwnedSlice(w.alloc) catch @panic("out of memory");
        for (impls) |p| bump(&w.open_impls, p);
        for (names) |name| {
            bump(&w.open_environments, name.environment);
            bump(&w.open_decls, name);
        }
        const pending_imports = scan.pending_imports.toOwnedSlice(w.alloc) catch @panic("out of memory");
        for (pending_imports) |imp| bump(&w.open_environments, imp.environment);
        const spreads = scan.spreads.toOwnedSlice(w.alloc) catch @panic("out of memory");
        for (spreads) |spread| bump(&w.open_environments, spread.environment);
        w.open_contexts += scan.contexts;
        w.known.put(node, w.items.items.len) catch @panic("out of memory");
        w.items.append(w.alloc, .{
            .kind = .module_driver,
            .impls = impls,
            .environment = environment,
            .names = names,
            .pending_imports = pending_imports,
            .declarations = scan.declarations.toOwnedSlice(w.alloc) catch @panic("out of memory"),
            .spreads = spreads,
            .contexts = scan.contexts,
            .retired = false,
        }) catch @panic("out of memory");
    }

    /// A driver has been decided — taken, rejected, or run out of iterations.
    /// Exactly the contributions it was registered with come back.
    pub fn retire(w: *Worklist, node: *const Node) void {
        const idx = w.known.get(node) orelse return;
        const item = &w.items.items[idx];
        if (item.retired) return;
        item.retired = true;
        for (item.impls) |p| drop(&w.open_impls, p);
        for (item.names) |name| {
            drop(&w.open_environments, name.environment);
            drop(&w.open_decls, name);
        }
        for (item.pending_imports) |imp| drop(&w.open_environments, imp.environment);
        for (item.spreads) |spread| drop(&w.open_environments, spread.environment);
        w.open_contexts -= item.contexts;
    }

    pub fn driverEnvironment(w: *const Worklist, node: *const Node) ?imports.EnvironmentId {
        return w.items.items[w.known.get(node).?].environment;
    }

    /// Register a driver of a non-declaration class. These contribute no
    /// declarations of their own — a `@run` computes a value, a fixpoint round
    /// monomorphizes bodies — so they carry an empty contribution set and
    /// retire as soon as they are drained.
    pub fn note(w: *Worklist, kind: Kind) void {
        w.items.append(w.alloc, .{
            .kind = kind,
            .impls = &.{},
            .environment = null,
            .names = &.{},
            .pending_imports = &.{},
            .declarations = &.{},
            .spreads = &.{},
            .contexts = 0,
            .retired = true,
        }) catch {};
    }

    /// Register a round of the convergence fixpoint. Materializing an arm
    /// re-registers, so the drain runs exactly as long as monomorphization
    /// keeps reaching new ground.
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

    /// Claim a `@run` for driving. False when it is already on the stack —
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
    pub fn parkDriver(w: *Worklist, what: []const u8, awaited: []const u8, span: ast.Span, source_file: ?[]const u8) void {
        w.parked.append(w.alloc, .{
            .evaluation = null,
            .what = what,
            .awaited = awaited,
            .span = span,
            .source_file = source_file,
        }) catch {};
    }

    /// An evaluation suspended at the instruction that asked the fact. The
    /// worklist owns it from here: its VM, task, heap, and VM-local Context
    /// stay alive until it resumes or the deadlock refuses it.
    pub fn parkEvaluation(w: *Worklist, evaluation: *comptime_vm.Evaluation, what: []const u8, awaited: []const u8, span: ast.Span, source_file: ?[]const u8) void {
        w.parked.append(w.alloc, .{
            .evaluation = evaluation,
            .what = what,
            .awaited = awaited,
            .span = span,
            .source_file = source_file,
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
            const saved = d.current_source_file;
            defer d.current_source_file = saved;
            d.current_source_file = w.parked.items[0].source_file;
            const id = d.addFmtId(.err, w.parked.items[0].span, "expansion deadlock — nothing can run: every compile-time unit still waiting needs a fact only another waiting unit could publish, so the expansion depends negatively on a set it feeds", .{});
            for (w.parked.items) |p| {
                d.current_source_file = p.source_file;
                d.addNoteFmt(id, p.span, "{s} awaits {s}", .{ p.what, p.awaited });
            }
            d.current_source_file = w.parked.items[0].source_file;
            d.addHelp(id, w.parked.items[0].span, "decide the declaration outside the set it queries — a question whose answer changes what it asks about has no single answer", null);
        }
        for (w.parked.items) |p| {
            if (p.evaluation) |e| e.destroy();
        }
        w.parked.clearRetainingCapacity();
    }

    /// Can an undecided driver still write an `impl` of `name`?
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

    pub fn environmentFinal(w: *const Worklist, environment: imports.EnvironmentId) bool {
        return (w.open_environments.get(environment) orelse 0) == 0;
    }

    /// Has the program Context stopped growing? Its layout is program-global
    /// and single: an evaluation that reads it must see the one the whole
    /// program ends up with, so it publishes only once no undecided driver can
    /// still write a `@context.extend`.
    pub fn contextFinal(w: *const Worklist) bool {
        return w.open_contexts == 0;
    }

    pub fn mayDeclare(w: *const Worklist, environment: imports.EnvironmentId, name: []const u8) bool {
        return (w.open_decls.get(.{ .environment = environment, .name = name }) orelse 0) > 0;
    }

    pub fn pendingImports(w: *const Worklist, environment: imports.EnvironmentId, block: ?imports.LexicalBlockId, targets: *std.ArrayList(imports.EnvironmentId)) void {
        for (w.items.items) |item| {
            if (item.retired) continue;
            for (item.pending_imports) |imp| {
                if (imp.environment == environment and imp.block == block)
                    targets.append(w.alloc, imp.target) catch @panic("out of memory");
            }
        }
    }

    pub fn contributions(w: *const Worklist, table: *const imports.DeclTable) lookup.Contributions {
        var declarations: std.ArrayList(lookup.Declaration) = .empty;
        var spreads: std.ArrayList(*const Node) = .empty;
        var pending_imports: std.ArrayList(lookup.Contributions.Import) = .empty;
        for (w.items.items) |item| {
            if (item.retired) continue;
            for (item.declarations) |id| declarations.append(w.alloc, .{ .table = table, .id = id }) catch @panic("out of memory");
            for (item.spreads) |spread| spreads.append(w.alloc, spread.node) catch @panic("out of memory");
            for (item.pending_imports) |imp| pending_imports.append(w.alloc, .{
                .context = .{ .table = table, .environment = imp.environment, .block = imp.block },
                .target = .{ .table = table, .environment = imp.target },
            }) catch @panic("out of memory");
        }
        return .{
            .declarations = declarations.toOwnedSlice(w.alloc) catch @panic("out of memory"),
            .spreads = spreads.toOwnedSlice(w.alloc) catch @panic("out of memory"),
            .imports = pending_imports.toOwnedSlice(w.alloc) catch @panic("out of memory"),
        };
    }

    fn bump(map: anytype, key: anytype) void {
        bumpBy(map, key, 1);
    }

    fn bumpBy(map: anytype, key: anytype, n: u32) void {
        const e = map.getOrPut(key) catch @panic("out of memory");
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + n else n;
    }

    fn drop(map: anytype, key: anytype) void {
        dropBy(map, key, 1);
    }

    fn dropBy(map: anytype, key: anytype, n: u32) void {
        map.getPtr(key).?.* -= n;
    }
};

/// The conservative syntactic sweep over an unexpanded driver: every branch of
/// an `inline if`, every arm of its match spelling, and the body of an
/// `inline for` — the cursor is unsubstituted, which only widens the answer.
const Scan = struct {
    alloc: std.mem.Allocator,
    /// Every resolved module, keyed by canonical path — where a branch-local
    /// `@import`'s module has been waiting since import resolution contained
    /// it, under the very path the node carries.
    cache: ?*const imports.ModuleCache,
    impls: std.ArrayList([]const u8),
    names: std.ArrayList(NameKey),
    pending_imports: std.ArrayList(PendingImport) = .empty,
    table: *imports.DeclTable,
    declarations: std.ArrayList(imports.DeclId) = .empty,
    spreads: std.ArrayList(PendingSpread) = .empty,
    contexts: u32 = 0,
    counted: std.StringHashMap(void),

    fn driver(s: *Scan, node: *const Node, depth: u8, environment: ?imports.EnvironmentId) void {
        if (depth > 16) return;
        switch (node.data) {
            .if_expr => |ie| {
                s.body(ie.then_branch, depth, environment);
                if (ie.else_branch) |eb| s.body(eb, depth, environment);
            },
            .match_expr => |me| for (me.arms) |arm| s.body(arm.body, depth, environment),
            .for_expr => |fe| s.body(fe.body, depth, environment),
            else => {},
        }
    }

    fn body(s: *Scan, node: *const Node, depth: u8, environment: ?imports.EnvironmentId) void {
        const stmts: []const *Node = if (node.data == .block) node.data.block.stmts else &.{@constCast(node)};
        for (stmts) |stmt| s.declaration(stmt, depth, environment);
    }

    fn declaration(s: *Scan, node: *const Node, depth: u8, fallback: ?imports.EnvironmentId) void {
        const environment = if (node.lexical_block) |block| s.table.block(block).environment else fallback;
        if (node.data.declName() orelse (if (node.data == .import_decl) node.data.import_decl.name else null)) |name| {
            s.addName(environment, name);
            const id = s.table.internNamedNode(environment, name, node) catch @panic("out of memory");
            s.declarations.append(s.alloc, id) catch @panic("out of memory");
        }
        switch (node.data) {
            .if_expr, .match_expr, .for_expr => s.driver(node, depth + 1, environment),
            .scope_decl => |scope| for (scope.decls) |decl| s.declaration(decl, depth + 1, environment),
            .impl_block => |ib| s.addImpl(ib.protocol_name),
            .context_extend_decl => s.contexts += 1,
            .import_decl => |imp| {
                if (imp.name) |name| s.addName(environment, name);
                s.module(imp.path, if (imp.name == null) environment else null, node.lexical_block, depth + 1);
            },
            .namespace_decl => |ns| s.module(ns.target_module_path, null, null, depth + 1),
            .spread_decl => {
                s.spreads.append(s.alloc, .{ .node = node, .environment = environment.? }) catch @panic("out of memory");
                const source = s.table.spread_sources.get(node).?;
                if (source == .module) s.module(source.module, null, null, depth + 1);
            },
            else => {},
        }
    }

    fn module(s: *Scan, path: []const u8, exposure: ?imports.EnvironmentId, block: ?imports.LexicalBlockId, depth: u8) void {
        if (depth > 16) return;
        const cache = s.cache orelse return;
        const resolved = cache.modules.get(path) orelse return;
        if (exposure) |env| {
            s.pending_imports.append(s.alloc, .{ .environment = env, .block = block, .target = resolved.environment }) catch @panic("out of memory");
        }
        const seen = s.counted.getOrPut(path) catch @panic("out of memory");
        if (seen.found_existing) return;
        seen.value_ptr.* = {};
        for (resolved.decls) |decl| s.declaration(decl, depth, resolved.environment);
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

    fn addName(s: *Scan, environment: ?imports.EnvironmentId, name: []const u8) void {
        const key = NameKey{ .environment = environment orelse return, .name = name };
        for (s.names.items) |seen| {
            if (NameKeyContext.eql(.{}, seen, key)) return;
        }
        s.names.append(s.alloc, key) catch @panic("out of memory");
    }
};
