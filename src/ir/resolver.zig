const std = @import("std");
const ast = @import("../ast.zig");
const imports = @import("../imports.zig");
const program_index = @import("program_index.zig");
const ProgramIndex = program_index.ProgramIndex;
const lookup = @import("../name_lookup.zig");

pub const LookupContext = lookup.Context;
pub const ScopeView = lookup.ScopeView;

pub const RawDeclRef = imports.RawDeclRef;
pub const RawAuthor = imports.RawAuthor;
pub const NamespaceTarget = imports.NamespaceTarget;

/// Author multiplicity for ONE name as seen from ONE querying module: the
/// own-module author (tier-2) plus the distinct flat-import authors (tier-3),
/// diamond-deduped by author identity. RAW — no verdict, no domain, no pick.
pub const AuthorSet = struct {
    /// The author declared in the querying module itself, if any.
    own: ?RawAuthor,
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
    /// `user_bare_flat` plus the extern-C gate (`isCImportVisible`):
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
    /// the source cannot disambiguate (the LOUD diagnostic in lowering).
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
/// gate on (`isNamedTypeKind`, `isPlainFreeFn`, `callableAuthorFn`, etc.).
pub fn eligibleKind(domain: Domain, raw: RawDeclRef, field: ?[]const u8) bool {
    return switch (domain) {
        .bare_type => switch (raw) {
            .struct_decl, .enum_decl, .union_decl, .error_set_decl, .protocol_decl, .open_set_decl, .runtime_class_decl => true,
            else => false,
        },
        .value_const => raw == .const_decl,
        .callable => if (fnDeclOf(raw)) |fd| fd.type_params.len == 0 and fd.body.data != .intrinsic_expr else false,
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
        .struct_decl => |sd| if (sd.type_params.len > 0) {
            gs.* = true;
        },
        .fn_decl => |fd| if (fd.type_params.len > 0) {
            tf.* = true;
        },
        .const_decl => |cd| switch (cd.value.data) {
            .struct_decl => |*sd| if (sd.type_params.len > 0) {
                gs.* = true;
            },
            .fn_decl => |*fd| if (fd.type_params.len > 0) {
                tf.* = true;
            },
            else => {},
        },
        .protocol_decl => {
            pr.* = true;
        },
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
    context: ?LookupContext = null,

    pub fn init(index: *ProgramIndex, alloc: std.mem.Allocator) Resolver {
        return .{ .index = index, .alloc = alloc };
    }

    pub fn plainImports(self: *Resolver, context: LookupContext, files: *std.ArrayList(LookupContext)) !void {
        const table = context.table;
        if (table.environment(context.environment).scope_path.len == 0) {
            const direct = self.index.flatImports(context.environment) orelse return;
            var it = direct.keyIterator();
            while (it.next()) |source| {
                const env = table.fileEnvironment(source.*) orelse continue;
                try files.append(self.alloc, .{ .table = table, .environment = env });
            }
        } else if (context.block) |block| {
            for (table.block(block).imports.items) |node| {
                const imp = node.data.import_decl;
                if (imp.name != null) continue;
                const env = table.fileEnvironment(imp.path) orelse continue;
                try files.append(self.alloc, .{ .table = table, .environment = env });
            }
        }
    }

    pub fn collectVisibleAuthors(self: *Resolver, name: []const u8, from: imports.EnvironmentId, vis: VisibilityMode) AuthorSet {
        switch (vis) {
            .user_bare_flat, .c_import_bare => {},
            .impl_transitive, .lowering_internal => @panic("collectVisibleAuthors: visibility mode has no single-hop author walk"),
        }
        const table = self.index.decl_table orelse return .{ .own = null, .flat = &.{} };
        const context = if (self.context) |ctx| (if (ctx.environment == from) ctx else LookupContext{ .table = table, .environment = from }) else LookupContext{ .table = table, .environment = from };
        return self.collectInContext(name, context);
    }

    pub fn collectInContext(self: *Resolver, name: []const u8, context: LookupContext) AuthorSet {
        const candidates = lookup.bare(self, context, name, context.source(), self.alloc) catch @panic("out of memory");
        defer self.alloc.free(candidates.imported);
        return self.authors(candidates);
    }

    fn authors(self: *Resolver, candidates: lookup.Candidates) AuthorSet {
        const own = if (candidates.own) |decl| decl.table.author(decl.id, decl.info().source.?) else null;
        var flat = std.ArrayList(RawAuthor).empty;
        for (candidates.imported) |decl| {
            const candidate = decl.table.author(decl.id, decl.info().source.?) orelse continue;
            if (self.containsIdentity(flat.items, candidate)) continue;
            flat.append(self.alloc, candidate) catch @panic("out of memory");
        }
        return .{ .own = own, .flat = flat.toOwnedSlice(self.alloc) catch @panic("out of memory") };
    }

    const Identity = union(enum) {
        declaration: imports.DeclId,
        type: @import("types.zig").TypeId,
        namespace: imports.EnvironmentId,
        scope: imports.ScopeId,
    };

    pub const Qualifier = union(enum) {
        namespace: LookupContext,
        scope: ScopeView,
    };

    pub const Selected = struct {
        declaration: imports.DeclId,
        view: LookupContext,
    };

    pub const Selection = union(enum) {
        missing,
        ambiguous,
        selected: Selected,
    };

    fn sameIdentity(self: *Resolver, a: RawAuthor, b: RawAuthor) bool {
        var visiting = std.ArrayList(imports.DeclId).empty;
        defer visiting.deinit(self.alloc);
        return self.sameDeclaration(a.id, b.id, &visiting);
    }

    fn sameDeclaration(self: *Resolver, a: imports.DeclId, b: imports.DeclId, visiting: *std.ArrayList(imports.DeclId)) bool {
        if (a == b) return true;
        const left = self.identity(a, visiting) orelse return false;
        const right = self.identity(b, visiting) orelse return false;
        return std.meta.eql(left, right);
    }

    fn containsIdentity(self: *Resolver, authors_list: []const RawAuthor, candidate: RawAuthor) bool {
        for (authors_list) |author| if (self.sameIdentity(author, candidate)) return true;
        return false;
    }

    fn identity(self: *Resolver, id: imports.DeclId, visiting: *std.ArrayList(imports.DeclId)) ?Identity {
        for (visiting.items) |previous| if (previous == id) return null;
        visiting.append(self.alloc, id) catch @panic("out of memory");
        defer _ = visiting.pop();
        const table = self.index.declarations();
        const info = table.get(id);
        if (info.scope) |scope| return .{ .scope = scope };
        const env = info.environment orelse return .{ .declaration = id };
        const ref = info.ref orelse return .{ .declaration = id };
        if (ref == .namespace_decl) {
            const target = table.environment(env).namespaces.get(info.name) orelse return null;
            return .{ .namespace = target.environment };
        }
        if (ref != .const_decl) return .{ .declaration = id };
        const path = imports.aliasPath(self.alloc, ref.const_decl.value) orelse {
            if (self.index.get(.type_alias, id)) |ty| return .{ .type = ty };
            return .{ .declaration = id };
        };
        defer self.alloc.free(path);
        const raw = switch (ref.const_decl.value.data) {
            .identifier => |ident| ident.is_raw,
            .type_expr => |te| te.is_raw,
            else => true,
        };
        if (!raw) if (@import("type_resolver.zig").TypeResolver.resolvePrimitive(path)) |ty| return .{ .type = ty };
        const context = LookupContext{ .table = table, .environment = env, .block = info.lexical_block };
        const target = self.selectPathInner(path, context, context.source(), visiting);
        return if (target == .selected) self.identity(target.selected.declaration, visiting) else null;
    }

    fn choose(self: *Resolver, candidates: lookup.Candidates, view: LookupContext, visiting: *std.ArrayList(imports.DeclId)) Selection {
        if (candidates.own) |decl| return .{ .selected = .{ .declaration = decl.id, .view = view } };
        var selected: ?imports.DeclId = null;
        for (candidates.imported) |decl| {
            if (selected) |previous| {
                if (!self.sameDeclaration(previous, decl.id, visiting)) return .ambiguous;
            } else selected = decl.id;
        }
        return if (selected) |id| .{ .selected = .{ .declaration = id, .view = view } } else .missing;
    }

    pub fn qualifier(self: *Resolver, selected: Selected) ?Qualifier {
        var visiting = std.ArrayList(imports.DeclId).empty;
        defer visiting.deinit(self.alloc);
        return self.qualifierInner(selected, &visiting);
    }

    fn qualifierInner(self: *Resolver, selected: Selected, visiting: *std.ArrayList(imports.DeclId)) ?Qualifier {
        const id = selected.declaration;
        for (visiting.items) |previous| if (previous == id) return null;
        visiting.append(self.alloc, id) catch @panic("out of memory");
        defer _ = visiting.pop();
        const table = self.index.declarations();
        const info = table.get(id);
        if (info.scope) |scope| return .{ .scope = .{ .path = table.scopeInfo(scope).path, .context = selected.view } };
        const context = LookupContext.author(.{ .table = table, .id = id }) orelse return null;
        const ref = info.ref orelse return null;
        if (ref == .namespace_decl) {
            const target = table.environment(context.environment).namespaces.get(info.name) orelse return null;
            return .{ .namespace = .{ .table = table, .environment = target.environment } };
        }
        if (ref != .const_decl) return null;
        const path = imports.aliasPath(self.alloc, ref.const_decl.value) orelse return null;
        defer self.alloc.free(path);
        const target = self.selectPathInner(path, context, context.source(), visiting);
        return if (target == .selected) self.qualifierInner(target.selected, visiting) else null;
    }

    pub fn selectPath(self: *Resolver, path: []const u8, context: LookupContext) Selection {
        var visiting = std.ArrayList(imports.DeclId).empty;
        defer visiting.deinit(self.alloc);
        return self.selectPathInner(path, context, context.source(), &visiting);
    }

    fn selectPathInner(self: *Resolver, path: []const u8, context: LookupContext, requester: []const u8, visiting: *std.ArrayList(imports.DeclId)) Selection {
        var parts = std.mem.splitScalar(u8, path, '.');
        const first = parts.next().?;
        const candidates = lookup.bare(self, context, first, requester, self.alloc) catch @panic("out of memory");
        defer self.alloc.free(candidates.imported);
        var result = self.choose(candidates, context, visiting);
        while (parts.next()) |name| {
            if (result != .selected) return result;
            const target = self.qualifierInner(result.selected, visiting) orelse return .missing;
            result = self.selectMemberInner(target, name, requester, visiting);
        }
        return result;
    }

    pub fn selectMember(self: *Resolver, target: Qualifier, name: []const u8, requester: []const u8) Selection {
        var visiting = std.ArrayList(imports.DeclId).empty;
        defer visiting.deinit(self.alloc);
        return self.selectMemberInner(target, name, requester, &visiting);
    }

    fn selectMemberInner(self: *Resolver, target: Qualifier, name: []const u8, requester: []const u8, visiting: *std.ArrayList(imports.DeclId)) Selection {
        const view = switch (target) {
            .namespace => |context| context,
            .scope => |scope| scope.context,
        };
        const candidates: lookup.Candidates = switch (target) {
            .namespace => |context| lookup.namespaceMembers(self, context, name, requester, self.alloc) catch @panic("out of memory"),
            .scope => |scope| lookup.scopeMembers(self, scope, name, requester, self.alloc) catch @panic("out of memory"),
        };
        defer self.alloc.free(candidates.imported);
        return self.choose(candidates, view, visiting);
    }

    pub fn collectNamespaceAuthors(
        self: *Resolver,
        target: NamespaceTarget,
        name: []const u8,
    ) AuthorSet {
        const table = self.index.declarations();
        for (target.member_ids) |id| {
            if (!std.mem.eql(u8, table.get(id).name, name)) continue;
            return .{ .own = table.author(id, target.target_module_path), .flat = &.{} };
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
        from: imports.EnvironmentId,
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
        if (set.distinctCount() != 0) return .domain_filtered;
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
        const table = self.index.decl_table orelse return false;
        for (table.environments.items) |env| {
            const info = table.get(env.names.get(name) orelse continue);
            if (info.visibility == .private) continue;
            if (eligibleKind(domain, info.ref orelse continue, field)) return true;
        }
        return false;
    }
};
