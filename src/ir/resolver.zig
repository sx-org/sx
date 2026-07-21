//! The unified sx name/type resolver — the shared author-collection layer.
//!
//! A read-only facade over the borrowed Phase A import facts on a
//! `*ProgramIndex` (`module_decls` / `namespace_edges`) and the existing
//! `import_graph` / `flat_import_graph` views. It OWNS nothing import-derived;
//! those maps live in `imports.zig`/`core.zig` and are borrowed here.
//!
//! Two collectors sit on top of these facts (R5 §1 #1):
//!   - `collectVisibleAuthors` — own author ∪ the flat-import edge walk. THE one
//!     graph-walk; the permanent flat-import F-series root.
//!   - `collectNamespaceAuthors` — a single already-selected namespace target's
//!     members. NO graph walk.
//!
//! Two lazy resolution functions build on the collectors:
//!   - `resolveBare(name, from, domain)` — collect bare authors + compute verdict.
//!     The caller owns the returned `ResolvedAuthors.set.flat` slice.
//!   - `resolveQualified(target, name)` — collect namespace authors + compute verdict.
//!     Returns no allocation (namespace sets are always single-module, flat=&.{}).
//!
//! Both are RAW-author collectors returning verdicts: they say WHO authors a name
//! and whether that author wins outright, is ambiguous, not-visible, etc.
//! Per-domain lowering (R2+) decides what to do with the verdict.
//!
//! Falsifiable invariant (R5 §1 #1): there is EXACTLY ONE iterator over
//! `flat_import_graph`/`import_graph` in this file — inside
//! `collectVisibleAuthors`. `collectNamespaceAuthors` iterates one
//! `NamespaceTarget.own_decls` slice and touches no graph. This is what keeps
//! 0102 (callable) and 0105 (type) the SAME cross-module edge-walk.

const std = @import("std");
const ast = @import("../ast.zig");
const imports = @import("../imports.zig");
const program_index = @import("program_index.zig");
const ProgramIndex = program_index.ProgramIndex;

// ── Raw-fact aliases (defined in imports.zig by buildImportFacts, Phase A) ──
pub const RawDeclRef = imports.RawDeclRef;
pub const RawAuthor = imports.RawAuthor;
pub const NamespaceTarget = imports.NamespaceTarget;

/// Author multiplicity for ONE name as seen from ONE querying module: the
/// own-module author (tier-2) plus the distinct flat-import authors (tier-3),
/// diamond-deduped by author identity. RAW — no verdict, no domain, no pick.
pub const AuthorSet = struct {
    /// The author declared in the querying module itself, if any.
    own: ?RawAuthor,
    /// Distinct flat-import authors. Diamond imports of the SAME author (same
    /// AST node reached over two edges, e.g. a directory aggregate and one of
    /// its member files) collapse to a single entry. Always disjoint from `own`.
    flat: []const RawAuthor,

    /// own + flat, counted by author identity. `flat` is already deduped and
    /// disjoint from `own`, so this is a plain sum.
    pub fn distinctCount(self: AuthorSet) usize {
        return (if (self.own != null) @as(usize, 1) else 0) + self.flat.len;
    }
};

/// How a name's cross-module visibility is computed. The author collector and
/// the lowering-side visibility predicate (`Lowering.isVisible`) both switch on
/// this single vocabulary.
pub const VisibilityMode = enum {
    /// own scope ∪ `flat_import_graph`. The PERMANENT core for bare-name lookup
    /// under flat imports (Agra constraint) — never a transitional path.
    user_bare_flat,
    /// `user_bare_flat` plus the extern-C gate (today's `isCImportVisible`):
    /// only C-import `fn_decl`s without a `library_ref` are policed; everything
    /// else is unconditionally visible.
    c_import_bare,
    /// own scope ∪ the TRANSITIVE import relation (specs.md:793-801). Owned by
    /// `ProtocolResolver.findVisibleImpls`; the single-hop author collector
    /// never serves it.
    impl_transitive,
    /// Registration / lazy lowering: falls open (visible), emits no user
    /// diagnostic, performs no graph walk.
    lowering_internal,
};

/// The selection verdict computed above a reference's collected author set —
/// the own-wins / single-flat-visible / ≥2-ambiguous layer. Evaluated over the
/// DOMAIN-ELIGIBLE subset of the author set (`eligibleKind`), so a same-name
/// VALUE never decides a TYPE reference — the type-vs-value `domain_filtered`
/// outcome.
pub const Verdict = enum {
    /// The querying module's OWN author is eligible — it wins outright,
    /// regardless of how many same-name flat authors exist.
    own_wins,
    /// Exactly ONE eligible flat-visible author, no own — the byte-identical
    /// single-author path.
    single,
    /// ≥2 distinct eligible flat-visible authors, no own — a genuine collision
    /// the source cannot disambiguate (the LOUD diagnostic at R2+).
    ambiguous,
    /// No eligible author is flat-visible, but the name IS authored for this
    /// domain in some module — reachable only over a namespace edge ⇒ a
    /// not-visible leak.
    not_visible,
    /// Visible same-name author(s) exist but NONE is eligible for this domain
    /// (e.g. a same-name VALUE for a TYPE reference), or the name is authored
    /// for this domain nowhere. The caller disambiguates by checking
    /// `set.distinctCount()`: 0 = undeclared / builtin / local; >0 = wrong domain.
    domain_filtered,
};

/// A collected author set paired with the verdict computed over it.
/// `set.flat` is owned by the caller and must be freed when no longer needed
/// (pass `self.alloc` to the same allocator used by the `Resolver`).
/// `resolveQualified` always returns `flat = &.{}` (no allocation).
pub const ResolvedAuthors = struct {
    set: AuthorSet,
    verdict: Verdict,
};

/// The reference domains a verdict is computed over. Each carries its own
/// eligibility filter (`eligibleKind`), so the own-wins / ambiguity count
/// surveys only the authors that can actually decide THIS kind of reference.
pub const Domain = enum {
    bare_type,
    value_const,
    callable,
    generic_struct_head,
    type_fn_head,
    protocol_head,
    runtime_class,
    struct_const,
    namespace_member,
    ufcs,
};

/// Whether `raw` is an author ELIGIBLE to decide a reference in `domain`.
/// `field` is the accessed member name (struct-const domain only; ignored
/// elsewhere). Mirrors the per-kind author predicates the lowering selectors
/// gate on (`isNamedTypeKind`, `isPlainFreeFn`, `typeFnAuthor`, etc.).
pub fn eligibleKind(domain: Domain, raw: RawDeclRef, field: ?[]const u8) bool {
    return switch (domain) {
        .bare_type => switch (raw) {
            .struct_decl, .enum_decl, .union_decl, .error_set_decl,
            .protocol_decl, .runtime_class_decl => true,
            else => false,
        },
        .value_const => raw == .const_decl,
        .callable => if (fnDeclOf(raw)) |fd| isPlainFreeFnDecl(fd) else false,
        .generic_struct_head => if (structDeclOf(raw)) |sd| sd.type_params.len > 0 else false,
        .type_fn_head => if (fnDeclOf(raw)) |fd| fd.type_params.len > 0 else false,
        .protocol_head => raw == .protocol_decl,
        .runtime_class => raw == .runtime_class_decl,
        .struct_const => structHasConstMember(raw, field orelse return false),
        .namespace_member => true,
        .ufcs => fnDeclOf(raw) != null,
    };
}

// ── Domain-predicate helpers ─────────────────────────────────────────────────

/// The `*StructDecl` a raw author wraps (bare or `Name :: struct(...)` const),
/// or null when the author is not a struct.
pub fn structDeclOf(raw: RawDeclRef) ?*const ast.StructDecl {
    return switch (raw) {
        .struct_decl => |sd| sd,
        .const_decl => |cd| if (cd.value.data == .struct_decl) &cd.value.data.struct_decl else null,
        else => null,
    };
}

/// The `*FnDecl` a raw author wraps (bare or `Name :: fn(...)` const), or null
/// when the author is not a function.
pub fn fnDeclOf(raw: RawDeclRef) ?*const ast.FnDecl {
    return switch (raw) {
        .fn_decl => |fd| fd,
        .const_decl => |cd| if (cd.value.data == .fn_decl) &cd.value.data.fn_decl else null,
        else => null,
    };
}

/// A PLAIN free function — no type params, an ordinary (non-`extern`/
/// `intrinsic`/`#compiler`/`extern`) body — the only callable kind the bare-call
/// verdict counts.
pub fn isPlainFreeFnDecl(fd: *const ast.FnDecl) bool {
    if (fd.type_params.len > 0) return false;
    // An `extern` import is an external C symbol with no sx-lowerable body —
    // dispatched name-keyed first-wins, exactly like a `extern` body, so it
    // is NOT a plain free fn (excluded from the bare-call ambiguity verdict and
    // the out-of-line-slot / shadow-author pass). `export` DEFINES a real sx
    // body, so it stays plain-free.
    if (fd.extern_export == .extern_) return false;
    return switch (fd.body.data) {
        .intrinsic_expr => false,
        else => true,
    };
}

/// True when the raw author is a struct carrying a const member named `field`.
pub fn structHasConstMember(raw: RawDeclRef, field: []const u8) bool {
    return switch (raw) {
        .struct_decl => |sd| blk: {
            for (sd.constants) |c| {
                if (c.data == .const_decl and std.mem.eql(u8, c.data.const_decl.name, field))
                    break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// True when any author in the set (own or flat) is a struct with const member
/// `field`. Used by resolveStructConst to short-circuit empty sets.
pub fn authorSetHasStructConst(set: AuthorSet, field: []const u8) bool {
    if (set.own) |a| if (structHasConstMember(a.raw, field)) return true;
    for (set.flat) |a| if (structHasConstMember(a.raw, field)) return true;
    return false;
}

/// Bin ONE raw author by the head kind(s) it can author: generic struct, type
/// function, or protocol. Used by lowering's parameterized-head classification.
pub fn classifyHeadKind(raw: RawDeclRef, gs: *bool, tf: *bool, pr: *bool) void {
    switch (raw) {
        .struct_decl => |sd| if (sd.type_params.len > 0) { gs.* = true; },
        .fn_decl => |fd| if (fd.type_params.len > 0) { tf.* = true; },
        .const_decl => |cd| switch (cd.value.data) {
            .struct_decl => |*sd| if (sd.type_params.len > 0) { gs.* = true; },
            .fn_decl => |*fd| if (fd.type_params.len > 0) { tf.* = true; },
            else => {},
        },
        .protocol_decl => { pr.* = true; },
        else => {},
    }
}

/// True when the bare-type verdict selected a runtime-class author
/// unambiguously. Used by lowering to route to the runtime-class path.
pub fn runtimeClassWinsType(set: AuthorSet, verdict: Verdict) bool {
    return switch (verdict) {
        .own_wins => if (set.own) |a| std.meta.activeTag(a.raw) == .runtime_class_decl else false,
        .single => blk: {
            var selected: ?RawAuthor = null;
            for (set.flat) |a| {
                if (!eligibleKind(.bare_type, a.raw, null)) continue;
                if (selected != null) break :blk false;
                selected = a;
            }
            const a = selected orelse break :blk false;
            break :blk std.meta.activeTag(a.raw) == .runtime_class_decl;
        },
        .ambiguous, .not_visible, .domain_filtered => false,
    };
}

// ── Resolver ─────────────────────────────────────────────────────────────────

/// Read-only facade over the borrowed import facts. `alloc` backs the
/// `AuthorSet.flat` slices the collectors return (the caller owns + frees them).
pub const Resolver = struct {
    index: *ProgramIndex,
    alloc: std.mem.Allocator,

    pub fn init(index: *ProgramIndex, alloc: std.mem.Allocator) Resolver {
        return .{ .index = index, .alloc = alloc };
    }

    /// THE single graph-walk in this file (falsifiable invariant, R5 §1 #1):
    /// the own author declared in `from` ∪ the flat-import authors reachable
    /// over the edge set `vis` chooses. RAW — selectors decide eligibility, not
    /// this. `from` is the querying module's source path.
    ///
    /// Edge set by mode: `flat_import_graph` for `user_bare_flat`/`c_import_bare`.
    /// `impl_transitive` and `lowering_internal` are not single-hop author walks —
    /// reaching them here is a wiring bug, so we trip loudly.
    pub fn collectVisibleAuthors(
        self: *Resolver,
        name: []const u8,
        from: []const u8,
        vis: VisibilityMode,
    ) AuthorSet {
        const decls = self.index.module_decls orelse return .{ .own = null, .flat = &.{} };

        const own: ?RawAuthor = blk: {
            const mod = decls.get(from) orelse break :blk null;
            const ref = mod.names.get(name) orelse break :blk null;
            const vis_own: ast.Visibility = if (mod.private_names.contains(name)) .private else .public;
            break :blk .{ .raw = ref, .source = mod.source, .visibility = vis_own };
        };

        const graph = (switch (vis) {
            .user_bare_flat, .c_import_bare => self.index.flat_import_graph,
            .impl_transitive, .lowering_internal => @panic(
                "collectVisibleAuthors: vis mode performs no single-hop author walk",
            ),
        }) orelse return .{ .own = own, .flat = &.{} };

        const direct = graph.get(from) orelse return .{ .own = own, .flat = &.{} };

        var flat = std.ArrayList(RawAuthor).empty;
        var it = direct.iterator(); // ← the one graph iterator (invariant)
        while (it.next()) |kv| {
            const dep = decls.get(kv.key_ptr.*) orelse continue;
            const ref = dep.names.get(name) orelse continue;
            // A flat import never carries a private declaration out of its
            // declaring file — the author simply does not exist for `from`.
            if (dep.private_names.contains(name)) continue;
            const cand = RawAuthor{ .raw = ref, .source = dep.source };
            if (sameAuthor(own, cand)) continue;
            if (containsAuthor(flat.items, cand)) continue;
            flat.append(self.alloc, cand) catch @panic("collectVisibleAuthors: OOM");
        }
        return .{
            .own = own,
            .flat = flat.toOwnedSlice(self.alloc) catch @panic("collectVisibleAuthors: OOM"),
        };
    }

    /// Container collector for ONE already-selected namespace target. Iterates
    /// the target's `own_decls` and touches NO import graph (R5 §1 #1). A
    /// namespace's `own_decls` is name-deduped, so a name has at most one author
    /// here — returned as `own`, sourced to the target's module path.
    pub fn collectNamespaceAuthors(
        self: *Resolver,
        target: NamespaceTarget,
        name: []const u8,
    ) AuthorSet {
        _ = self;
        for (target.own_decls) |decl| {
            const dn = decl.data.declName() orelse continue;
            if (!std.mem.eql(u8, dn, name)) continue;
            const ref = imports.rawDeclRefOf(decl) orelse continue;
            return .{ .own = .{
                .raw = ref,
                .source = target.target_module_path,
                .visibility = decl.visibility,
                // Privacy authority is the EXACT declaring file — for a
                // directory-import namespace that is the member file, not the
                // directory module path.
                .vis_source = decl.source_file,
            }, .flat = &.{} };
        }
        return .{ .own = null, .flat = &.{} };
    }

    /// Collect bare-name authors for `name` as seen from `from`, filter by
    /// `domain` eligibility, and compute the selection verdict. The caller owns
    /// the returned `ResolvedAuthors.set.flat` slice (allocator = `self.alloc`).
    ///
    /// Returns `.domain_filtered` with an empty set when `name` has no author
    /// anywhere in the domain (builtin / local variable / undeclared name).
    pub fn resolveBare(
        self: *Resolver,
        name: []const u8,
        from: []const u8,
        domain: Domain,
    ) ResolvedAuthors {
        const set = self.collectVisibleAuthors(name, from, .user_bare_flat);
        const verdict = self.verdictOver(domain, name, set, null);
        return .{ .set = set, .verdict = verdict };
    }

    /// Collect namespace-qualified authors for `target.member` and compute the
    /// verdict. Namespace resolution has no own-wins / ambiguity — the target is
    /// already selected, so "found" is `.single` and "not found" is
    /// `.domain_filtered`. Returns no allocation (`flat = &.{}`).
    pub fn resolveQualified(
        self: *Resolver,
        target: NamespaceTarget,
        name: []const u8,
    ) ResolvedAuthors {
        const set = self.collectNamespaceAuthors(target, name);
        const verdict: Verdict = if (set.own != null) .single else .domain_filtered;
        return .{ .set = set, .verdict = verdict };
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /// Compute the verdict over a collected author set for `domain`: own-wins
    /// when the querying module's own author is eligible; ≥2 distinct eligible
    /// flat authors → ambiguous; exactly one → single; none eligible but authored
    /// for this domain anywhere (non-flat-visible) → not_visible; otherwise
    /// domain_filtered.
    fn verdictOver(
        self: *Resolver,
        domain: Domain,
        name: []const u8,
        set: AuthorSet,
        field: ?[]const u8,
    ) Verdict {
        if (set.own) |o| {
            if (eligibleKind(domain, o.raw, field)) return .own_wins;
        }
        var n: usize = 0;
        for (set.flat) |fa| {
            if (eligibleKind(domain, fa.raw, field)) {
                n += 1;
                if (n >= 2) return .ambiguous;
            }
        }
        if (n == 1) return .single;
        if (self.authoredAsDomainAnywhere(domain, name, field)) return .not_visible;
        return .domain_filtered;
    }

    /// True iff `name` is authored for `domain` in ANY module's raw facts —
    /// the not-visible leak detector. Reached only with zero eligible
    /// flat-visible authors, so a hit means the author is reachable only over a
    /// namespace edge.
    fn authoredAsDomainAnywhere(
        self: *Resolver,
        domain: Domain,
        name: []const u8,
        field: ?[]const u8,
    ) bool {
        const decls = self.index.module_decls orelse return false;
        var it = decls.valueIterator();
        while (it.next()) |m| {
            if (m.names.get(name)) |ref| {
                // A private-only author is invisible everywhere but its own
                // file (which the own/flat walk already served), so it must
                // not turn "undeclared" into a misleading not-visible leak.
                if (m.private_names.contains(name)) continue;
                if (eligibleKind(domain, ref, field)) return true;
            }
        }
        return false;
    }
};

// ── Private identity helpers ─────────────────────────────────────────────────

fn authorNodePtr(ref: RawDeclRef) usize {
    return switch (ref) {
        inline else => |p| @intFromPtr(p),
    };
}

fn sameAuthor(a: ?RawAuthor, b: RawAuthor) bool {
    const aa = a orelse return false;
    return authorNodePtr(aa.raw) == authorNodePtr(b.raw);
}

fn containsAuthor(list: []const RawAuthor, b: RawAuthor) bool {
    for (list) |x| {
        if (authorNodePtr(x.raw) == authorNodePtr(b.raw)) return true;
    }
    return false;
}
