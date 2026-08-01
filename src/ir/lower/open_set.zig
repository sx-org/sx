//! Open sets: `P :: @OpenSet(.{ max, align })` and its members,
//! `V :: @OpenVariant(P)` (spec: Open Sets).
//!
//! An open set is a type-system facility, not a protocol kind: an inline tagged
//! slot whose members declare THEMSELVES into it. There is no registry API and
//! no enrollment statement — the declarations are the registry.
//!
//! The layout is compiler-owned. The set interns as a payload-carrying type whose
//! backing shape is written down explicitly (`{ tag: i64, payload: [N]u8 }`), so
//! size, alignment, and codegen all come from the shipped aggregate paths rather
//! than from a second layout rule:
//!
//!     payload_size      = max(size_of(V) for each declared V)   (≤ max)
//!     payload_alignment = max(declared align, align_of(tag))    (not a max over V)
//!     payload_offset    = align_up(size_of(tag), payload_alignment)
//!     size_of(P)        = align_up(payload_offset + payload_size, payload_alignment)
//!
//! The tag's own alignment is a FLOOR: a set declared `align = 4` is laid out at
//! 8, because the tag word is in the same value. The payload is an array of an
//! element whose alignment IS the payload alignment, so the offset guarantee and
//! `align_of(P)` are delivered by the shape rather than assumed by whoever reads
//! it.
//!
//! `max` is a ceiling, not a reservation: a set whose largest member is small is
//! small, and a set with no members at all is just its tag word. Every member is
//! checked against `max` and the effective alignment AT ITS DECLARATION, so an
//! oversize or over-aligned type cannot be a member at all — there is no
//! conversion-time size check, and no silent spill to heap.
//!
//! Layout follows the members declared, so it GROWS as declarations arrive, and
//! growth is transitive: a member holding another set by value changes size when
//! that set does, which re-lays-out the set it belongs to and re-checks it against
//! its own ceiling (`relayout` → `cascade`).
//!
//! Which is why a set's size is not a source literal. The last member can arrive
//! at any point up to the FREEZE — the point the `tagged` conformer sets converge
//! at — so `size_of(P)` lowers to an `open_set_layout` op that each world resolves
//! against the frozen layout, and one program has ONE answer wherever it asks. A
//! position that must be folded EARLIER than the freeze — an array dimension, a
//! `::` constant — is refused instead of answered against a layout that is not
//! there yet. The freeze also numbers each set's members densely in the set's own
//! tag space and writes its `tag → member Type` table.

const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");

const TypeId = types.TypeId;

const program_index = @import("../program_index.zig");
const inst_mod = @import("../inst.zig");
const errors = @import("../../errors.zig");
const comptime_vm = @import("../comptime_vm.zig");
const lower = @import("../lower.zig");
const resolver_mod = @import("../resolver.zig");
const Lowering = lower.Lowering;
const Ref = inst_mod.Ref;
const FuncId = inst_mod.FuncId;

/// The tag word: the shipped payload-enum tag type, so dispatch and layout reuse
/// the tagged-union machinery unchanged.
pub const tag_type: TypeId = .i64;

/// The name of the backing struct's payload field.
const payload_field = "payload";
const tag_field = "tag";

/// `align` when the declaration omits it: the alignment ordinary allocators
/// guarantee, which is what a `List(P)` can honour.
pub const default_align: u32 = 8;

/// A member whose own size depends on another set's layout: it holds that set BY
/// VALUE, so growing that set grows this member — and therefore the set THIS
/// member belongs to. Recorded at admission (the finiteness walk already visits
/// exactly these edges) and replayed by `relayout`.
pub const Dependent = struct {
    decl: *const ast.StructDecl,
    member: TypeId,
    /// The set this member belongs to, which has to be laid out again.
    set: *const ast.OpenSetDecl,
    span: ast.Span,
};

/// One declared set, as its declaration states it.
pub const Set = struct {
    decl: *const ast.OpenSetDecl,
    /// The interned set type.
    ty: TypeId,
    max: u32,
    /// The alignment the layout uses: the declared option floored by the tag's.
    alignment: u32,
    /// The option as written, for the diagnostic that quotes the declaration.
    declared_align: u32,
    span: ast.Span,
    source_file: ?[]const u8,
    /// Members, in admission order until the freeze numbers them — from there,
    /// in tag order.
    members: std.ArrayList(TypeId) = .empty,
};

/// Register `P :: @OpenSet(.{ … }) { … }`: read the options, intern the type with
/// an empty member set, and record it. Members register themselves later, and the
/// layout is recomputed as each arrives.
/// The alignment the slot is actually laid out at: the declared option, floored by
/// the tag word's own alignment (the tag lives in the same value).
pub fn effectiveAlign(self: *Lowering, declared: u32) u32 {
    const tag_align: u32 = @intCast(self.module.types.typeAlignBytes(tag_type));
    return if (declared > tag_align) declared else tag_align;
}

pub fn registerSetDecl(self: *Lowering, decl: *const ast.OpenSetDecl, node: *const Node) void {
    // One declaration reached twice is one set: the registry is keyed by the
    // declaration, so a second visit finds the entry it made the first time.
    if (self.open_sets.contains(decl)) return;
    const options = readOptions(self, decl, node) orelse return;
    const table = &self.module.types;
    const name_id = table.internString(decl.name);
    const ty = table.internNominal(.{ .tagged_union = .{
        .name = name_id,
        .fields = &.{},
        .tag_type = tag_type,
        .backing_type = backingType(self, 0, effectiveAlign(self, options.alignment)),
    } }, self.shadowNominalId(name_id));
    table.type_decl_tids.put(@ptrCast(decl), ty) catch {};
    self.open_sets.put(decl, .{
        .decl = decl,
        .ty = ty,
        .max = options.max,
        .alignment = effectiveAlign(self, options.alignment),
        .declared_align = options.alignment,
        .span = node.span,
        .source_file = node.source_file orelse self.current_source_file,
    }) catch return;
    self.open_set_by_type.put(ty, decl) catch {};
    settleGenericNotes(self, decl);
}

const Options = struct { max: u32, alignment: u32 };

/// `.{ max = 256, align = 8 }` — `max` is required, `align` defaults to 8. The
/// options are an ordinary struct literal, read here rather than lowered: they
/// are layout, so they must be known before any value of the set exists.
fn readOptions(self: *Lowering, decl: *const ast.OpenSetDecl, node: *const Node) ?Options {
    const span = decl.options_span orelse node.span;
    const opts = decl.options orelse {
        reportOptions(self, span, "an open set states its payload ceiling: write '@OpenSet(.{ max = <bytes> })'");
        return null;
    };
    if (opts.data != .struct_literal) {
        reportOptions(self, span, "the options are a struct literal: '@OpenSet(.{ max = <bytes>, align = <bytes> })'");
        return null;
    }
    var max: ?i64 = null;
    var alignment: i64 = default_align;
    for (opts.data.struct_literal.field_inits) |f| {
        const fname = f.name orelse {
            reportOptions(self, span, "each option is named: 'max = <bytes>' and 'align = <bytes>'");
            return null;
        };
        const folded = program_index.foldDimU32(f.value, self, 1);
        if (folded != .ok) {
            reportOptions(self, f.value.span, "an open set's options are compile-time byte counts");
            return null;
        }
        const value: i64 = folded.ok;
        if (std.mem.eql(u8, fname, "max")) {
            max = value;
        } else if (std.mem.eql(u8, fname, "align")) {
            alignment = value;
        } else {
            if (self.diagnostics) |d| {
                const id = d.addFmtId(.err, f.value.span, "'{s}' is not an open-set option", .{fname});
                d.addHelpFmt(id, f.value.span, null, "the options are 'max' (payload ceiling in bytes) and 'align' (payload alignment)", .{});
            }
            return null;
        }
    }
    const m = max orelse {
        reportOptions(self, span, "'max' has no default — state the payload ceiling in bytes");
        return null;
    };
    if (m <= 0) {
        reportOptions(self, span, "'max' is a byte count, so it is positive");
        return null;
    }
    if (alignment <= 0 or (alignment & (alignment - 1)) != 0) {
        reportOptions(self, span, "'align' is a power of two");
        return null;
    }
    return .{ .max = @intCast(m), .alignment = @intCast(alignment) };
}

fn reportOptions(self: *Lowering, span: ast.Span, help: []const u8) void {
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, span, "the open set's options are incomplete", .{});
    d.addHelpFmt(id, span, null, "{s}", .{help});
}

/// What a `@OpenVariant(path)` head reached, from the file that wrote it.
pub const HeadVerdict = union(enum) {
    /// The one set the head reaches.
    set: *const ast.OpenSetDecl,
    /// Several sets of that name are visible here, and nothing in the spelling
    /// says which — the file must reach the one it means by name.
    ambiguous,
    /// A set of that name is declared, but this file cannot see it: it never
    /// imported the module that declares it.
    not_visible,
    /// Nothing of that name is a set here.
    none,
};

/// The DECLARATION a head reaches. A qualified path reaches what the module it
/// names publishes; a bare name reaches whatever the file that wrote it can SEE,
/// which is the same question every other bare type reference asks — so two sets
/// of one name are told apart the way two structs of one name are, and a file that
/// imported neither is told so rather than handed one of them.
pub fn setDeclVerdict(self: *Lowering, path: []const u8, from: ?[]const u8) HeadVerdict {
    const source = from orelse self.current_source_file orelse self.main_file orelse "";
    if (std.mem.indexOfScalar(u8, path, '.')) |_| {
        return switch (self.qualifiedMemberVerdictFrom(path, source)) {
            .selected => |sel| switch (sel.author.raw) {
                .open_set_decl => |osd| .{ .set = osd },
                // A facade re-exports by naming, so what it publishes is an ALIAS
                // of the declaration — the set is what the alias names.
                .const_decl => |cd| blk: {
                    const saved = self.current_source_file;
                    defer self.setCurrentSourceFile(saved);
                    self.setCurrentSourceFile(sel.author.source);
                    const ty = self.resolveTypeArg(cd.value);
                    if (ty == .unresolved) break :blk .none;
                    const set = setOf(self, ty) orelse break :blk .none;
                    break :blk .{ .set = set.decl };
                },
                else => .none,
            },
            else => .none,
        };
    }
    var r = self.resolver();
    const res = r.resolveBare(path, source, .bare_type);
    defer self.alloc.free(res.set.flat);
    const chosen: ?resolver_mod.RawAuthor = switch (res.verdict) {
        .own_wins => res.set.own,
        .single => if (res.set.flat.len == 1) res.set.flat[0] else res.set.own,
        .ambiguous => return .ambiguous,
        .not_visible => return .not_visible,
        .domain_filtered => null,
    };
    const author = chosen orelse return .none;
    return switch (author.raw) {
        .open_set_decl => |osd| .{ .set = osd },
        else => .none,
    };
}

/// What a bare TYPE name reaches from the file that wrote it — the same question a
/// bare set head asks, for the target of a downcast. A name two modules declare
/// resolves to the one this file's own declaration or import selects, so a module
/// asking about its OWN member is answered with its own.
pub const TargetVerdict = union(enum) {
    ty: TypeId,
    ambiguous,
    not_visible,
    none,
};

pub fn bareTypeVerdict(self: *Lowering, name: []const u8, from: ?[]const u8) TargetVerdict {
    const source = from orelse self.current_source_file orelse self.main_file orelse "";
    var r = self.resolver();
    const res = r.resolveBare(name, source, .bare_type);
    defer self.alloc.free(res.set.flat);
    const chosen: ?resolver_mod.RawAuthor = switch (res.verdict) {
        .own_wins => res.set.own,
        .single => if (res.set.flat.len == 1) res.set.flat[0] else res.set.own,
        .ambiguous => return .ambiguous,
        .not_visible => return .not_visible,
        .domain_filtered => null,
    };
    const author = chosen orelse return .none;
    const ty = self.namedRefTid(author.raw, name) orelse return .none;
    return .{ .ty = ty };
}

/// The declaration a head reaches, or null — the shape callers that only need the
/// answer use.
pub fn setDeclNamed(self: *Lowering, path: []const u8, from: ?[]const u8) ?*const ast.OpenSetDecl {
    return switch (setDeclVerdict(self, path, from)) {
        .set => |decl| decl,
        else => null,
    };
}

/// The set a `@OpenVariant(path)` head names, or null with a diagnostic.
pub fn setNamed(self: *Lowering, name: []const u8, span: ast.Span) ?*Set {
    switch (setDeclVerdict(self, name, self.current_source_file)) {
        .set => |decl| {
            if (self.open_sets.getPtr(decl)) |set| return set;
        },
        .ambiguous => {
            if (self.diagnostics) |d| {
                const id = d.addFmtId(.err, span, "'{s}' is declared as an open set by more than one module here", .{name});
                d.addHelpFmt(id, span, null, "name the one this member joins through the module that declares it ('pkg.{s}')", .{name});
            }
            return null;
        },
        .not_visible => {
            if (self.diagnostics) |d| {
                const id = d.addFmtId(.err, span, "'{s}' is an open set, but not one this module can see", .{name});
                d.addHelpFmt(id, span, null, "import the module that declares it, or name it through one ('pkg.{s}')", .{name});
            }
            return null;
        },
        .none => {},
    }
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'{s}' is not an open set", .{name});
        // A qualified head asks another module for a set: what it can be told is
        // that the module publishes no such one, not to declare it here.
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            d.addHelpFmt(id, span, null, "'{s}' publishes no open set '{s}' — a member joins a set the module that declares it publishes", .{ name[0..dot], name[dot + 1 ..] });
        } else {
            d.addHelpFmt(id, span, null, "a member joins a set declared '{s} :: @OpenSet(.{{ max = … }}) {{ … }}'", .{name});
        }
    }
    return null;
}

/// The set `ty` is, or null.
pub fn setOf(self: *Lowering, ty: TypeId) ?*Set {
    const decl = self.open_set_by_type.get(ty) orelse return null;
    return self.open_sets.getPtr(decl);
}

/// True when `ty` is an open set.
pub fn isOpenSet(self: *Lowering, ty: TypeId) bool {
    return self.open_set_by_type.contains(ty);
}

/// Admit `variant` into the set its declaration named, checking everything the
/// declaration is answerable for (spec: Open Sets — admission):
///
///   - `size_of(V) ≤ max` and `align_of(V) ≤ align`;
///   - finite size: `V` must not contain the set by value, at any depth;
///   - every required method, on the variant itself;
///   - one set per type.
///
/// Rejection is at the DECLARATION, so a type that cannot be a member never has
/// a tag, and no conversion site needs a second check.
pub fn admitVariant(
    self: *Lowering,
    sd: *const ast.StructDecl,
    variant: TypeId,
    span: ast.Span,
) void {
    const set_name = sd.open_variant_of orelse return;
    const set = setNamed(self, set_name, sd.open_variant_span orelse span) orelse return;

    if (self.open_variant_of.get(variant)) |existing| {
        if (existing != set.decl) {
            if (self.diagnostics) |d| {
                const id = d.addFmtId(.err, span, "'{s}' already joins the open set '{s}'", .{ sd.name, existing.name });
                d.addHelpFmt(id, span, null, "a type belongs to one set; wrap it in another member to take part in a second", .{});
            }
            return;
        }
    }

    if (containsByValue(self, variant, set.ty, 0)) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': it contains '{s}' by value, so its size would be infinite", .{ sd.name, set_name, set_name });
            d.addHelpFmt(id, span, null, "hold it behind a pointer ('*{s}') or in a list whose elements live outside the value", .{set_name});
        }
        return;
    }

    if (!fits(self, sd, set, variant, span, null)) return;
    if (nonConformance(self, set, variant)) |nc| {
        reportNonConformance(self, sd, set, variant, nc, span);
        return;
    }

    for (set.members.items) |m| {
        if (m == variant) return;
    }
    set.members.append(self.alloc, variant) catch return;
    self.open_set_epoch += 1;
    self.open_variant_of.put(variant, set.decl) catch {};
    recordDependencies(self, sd, variant, set.decl, span);
    relayout(self, set);
}

/// A generic member whose head has not reached a set yet.
pub const PendingGenericMember = struct {
    member: *const ast.StructDecl,
    head: []const u8,
    source: ?[]const u8,
};

/// Record that the set this member's head names has a GENERIC member declaration.
/// The template has no layout of its own; each instantiation the program spells is
/// another member, and the program is not finished spelling them — which is
/// exactly what keeps the set's layout open past the declaration pass.
///
/// A template is built while the declarations are still being scanned, so the head
/// may reach nothing YET. That is a fact still owed rather than a fact denied: the
/// note waits, `registerSetDecl` answers it the moment the set arrives, and what is
/// still owed when the declarations are done is reported against the member that
/// wrote it (§7.9 — a bookmark, not a stage wall).
pub fn noteGenericMember(self: *Lowering, member: *const ast.StructDecl, head: []const u8, source: ?[]const u8) void {
    if (setDeclNamed(self, head, source)) |decl| {
        self.open_set_generic_members.put(decl, {}) catch {};
        return;
    }
    self.open_set_generic_pending.append(self.alloc, .{ .member = member, .head = head, .source = source }) catch {};
}

/// Answer every pending note this registration settles.
fn settleGenericNotes(self: *Lowering, decl: *const ast.OpenSetDecl) void {
    var i: usize = 0;
    while (i < self.open_set_generic_pending.items.len) {
        const pending = self.open_set_generic_pending.items[i];
        if (setDeclNamed(self, pending.head, pending.source) == decl) {
            self.open_set_generic_members.put(decl, {}) catch {};
            _ = self.open_set_generic_pending.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

/// The declarations are done, so a head that still reaches no set never will.
/// Reported against the member that wrote it, naming what it asked for.
pub fn reportUnreachedGenericHeads(self: *Lowering) void {
    for (self.open_set_generic_pending.items) |pending| {
        if (setDeclNamed(self, pending.head, pending.source) != null) continue;
        const d = self.diagnostics orelse continue;
        const span = pending.member.open_variant_span orelse ast.Span{ .start = 0, .end = 0 };
        const saved = d.current_source_file;
        if (pending.source) |src| d.current_source_file = src;
        const id = d.addFmtId(.err, span, "'{s}' joins '{s}', which is not an open set", .{ pending.member.name, pending.head });
        if (std.mem.lastIndexOfScalar(u8, pending.head, '.')) |dot| {
            d.addHelpFmt(id, span, null, "'{s}' publishes no open set '{s}' — a member joins a set the module that declares it publishes", .{ pending.head[0..dot], pending.head[dot + 1 ..] });
        } else {
            d.addHelpFmt(id, span, null, "a member joins a set declared '{s} :: @OpenSet(.{{ max = … }}) {{ … }}'", .{pending.head});
        }
        d.current_source_file = saved;
    }
    self.open_set_generic_pending.clearRetainingCapacity();
}

/// Can a generic member still be instantiated into `set`?
fn mayGrowGenerically(self: *Lowering, set: TypeId) bool {
    const decl = self.open_set_by_type.get(set) orelse return false;
    return self.open_set_generic_members.contains(decl);
}

/// Does the member fit the set's ceiling and alignment? `grown` names the set
/// whose growth prompted a re-measure, so the refusal can say what changed.
fn fits(
    self: *Lowering,
    sd: *const ast.StructDecl,
    set: *const Set,
    variant: TypeId,
    span: ast.Span,
    grown: ?[]const u8,
) bool {
    const size = self.module.types.typeSizeBytes(variant);
    const alignment = self.module.types.typeAlignBytes(variant);
    const set_name = self.module.types.getString(self.module.types.get(set.ty).tagged_union.name);
    if (size > set.max) {
        reportOversize(self, sd, set, variant, size, span, grown);
        return false;
    }
    if (alignment > set.alignment) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': it needs {d}-byte alignment, and the set's payload alignment is {d}", .{ sd.name, set_name, alignment, set.alignment });
            d.addHelpFmt(id, span, null, "raise 'align' on the '{s}' declaration — every storage path for it must honour that alignment — or drop the over-aligned field", .{set_name});
        }
        return false;
    }
    return true;
}

fn reportOversize(
    self: *Lowering,
    sd: *const ast.StructDecl,
    set: *const Set,
    variant: TypeId,
    size: usize,
    span: ast.Span,
    grown: ?[]const u8,
) void {
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': it is {d} bytes, and the set's payload ceiling is {d}", .{ sd.name, self.module.types.getString(self.module.types.get(set.ty).tagged_union.name), size, set.max });
    if (grown) |g| {
        d.addHelpFmt(id, span, null, "it grew when '{s}' did — a set's layout follows the largest member declared anywhere in the program", .{g});
    }
    // The fields that account for the size are what the author has to act on.
    if (largestField(self, variant)) |big| {
        d.addHelpFmt(id, span, null, "the largest field is '{s}' at {d} bytes — hold bulk state elsewhere and borrow it, or raise 'max' on the set", .{ big.name, big.size });
    } else {
        d.addHelpFmt(id, span, null, "hold bulk state elsewhere and borrow it, or raise 'max' on the set", .{});
    }
}

const FieldSize = struct { name: []const u8, size: usize };

fn largestField(self: *Lowering, variant: TypeId) ?FieldSize {
    if (variant.isBuiltin()) return null;
    const info = self.module.types.get(variant);
    if (info != .@"struct") return null;
    var best: ?FieldSize = null;
    for (info.@"struct".fields) |f| {
        const size = self.module.types.typeSizeBytes(f.ty);
        if (best == null or size > best.?.size) {
            best = .{ .name = self.module.types.getString(f.name), .size = size };
        }
    }
    return best;
}

/// Does `ty` contain `set` by value, at any depth? A pointer breaks the chain —
/// its size is fixed whatever it points at — and so does a list whose elements
/// live outside its own value.
fn containsByValue(self: *Lowering, ty: TypeId, set: TypeId, depth: u32) bool {
    if (depth > 32) return false;
    if (ty == set) return true;
    if (ty.isBuiltin()) return false;
    return switch (self.module.types.get(ty)) {
        .@"struct" => |s| blk: {
            for (s.fields) |f| {
                if (containsByValue(self, f.ty, set, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .tuple => |t| blk: {
            for (t.fields) |f| {
                if (containsByValue(self, f, set, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .array => |a| containsByValue(self, a.element, set, depth + 1),
        .optional => |o| containsByValue(self, o.child, set, depth + 1),
        .@"union" => |u| blk: {
            for (u.fields) |f| {
                if (containsByValue(self, f.ty, set, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .tagged_union => |u| blk: {
            for (u.fields) |f| {
                if (containsByValue(self, f.ty, set, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        // A pointer, slice, or many-pointer holds an address: the pointee is not
        // part of this value's layout.
        else => false,
    };
}

/// How a member fails a required method, or null when it answers every one of
/// them as the set declared it.
const NonConformance = struct {
    method: []const u8,
    kind: enum { missing, arity, param, ret },
    detail: []const u8 = "",
};

/// Does `variant` answer every method the set requires, at the types the set
/// declared them? Membership is what makes a member dispatchable and what a
/// membership bound promises, so the signature is part of admission — not
/// something the first call site discovers.
///
/// `Self` in a required method denotes the MEMBER, so it is substituted before
/// comparing: the set's `(self: *Self, other: Self) -> Self` is answered by
/// `(self: *Label, other: Label) -> Label`. The receiver is not compared — a
/// generic member spells it as its template (`self: *Padded`), which only the
/// instance machinery can resolve.
///
/// Comparison is by canonical TypeId and only flags when BOTH sides resolve, so
/// a signature this cannot fully resolve is never a false refusal.
fn nonConformance(self: *Lowering, set: *const Set, variant: TypeId) ?NonConformance {
    const inst = self.getStructTypeName(variant);
    for (set.decl.methods) |m| {
        if (m.default_body != null) continue;
        var bindings: ?*const std.StringHashMap(TypeId) = null;
        const impl: *const ast.FnDecl = blk: {
            if (self.plainStructMethod(variant, m.name)) |pm| break :blk pm.fd;
            if (inst) |name| {
                if (self.genericInstanceMethod(name, m.name)) |gm| {
                    // A generic member's method spells the template's parameters
                    // (`-> $T`); the instantiation is what says what they are, so
                    // its bindings resolve the signature being admitted.
                    bindings = gm.bindings;
                    break :blk gm.fd;
                }
            }
            return .{ .method = m.name, .kind = .missing };
        };
        if (signatureFault(self, set, m, impl, variant, bindings)) |nc| return nc;
    }
    return null;
}

/// The member's implementation of one required method, compared against the
/// declaration. Returns the first clear fault.
fn signatureFault(
    self: *Lowering,
    set: *const Set,
    declared: ast.ProtocolMethodDecl,
    impl: *const ast.FnDecl,
    variant: TypeId,
    bindings: ?*const std.StringHashMap(TypeId),
) ?NonConformance {
    // The receiver occupies params[0]; everything after it is what the set states.
    if (impl.params.len == 0) return null;
    const extra = impl.params[1..];
    if (extra.len != declared.params.len) {
        return .{
            .method = declared.name,
            .kind = .arity,
            .detail = std.fmt.allocPrint(self.alloc, "the set declares {d} argument{s} after the receiver, and this takes {d}", .{
                declared.params.len, if (declared.params.len == 1) "" else "s", extra.len,
            }) catch "",
        };
    }
    const impl_src = impl.body.source_file;
    const saved = self.type_bindings;
    defer self.type_bindings = saved;
    if (bindings) |b| self.type_bindings = b.*;
    for (declared.params, extra) |want_node, got| {
        const want = self.resolveDeclaredTypeSubSelf(want_node, variant, set.source_file);
        const got_ty = resolveMemberTypeIn(self, impl_src, got.type_expr, bindings != null);
        if (!self.typesClearlyDiffer(want, got_ty)) continue;
        return .{
            .method = declared.name,
            .kind = .param,
            .detail = std.fmt.allocPrint(self.alloc, "'{s}' is '{s}', and the set declares '{s}'", .{
                got.name, self.formatTypeName(got_ty), self.formatTypeName(want),
            }) catch "",
        };
    }
    const want_ret: TypeId = if (declared.return_type) |rt| self.resolveDeclaredTypeSubSelf(rt, variant, set.source_file) else .void;
    const got_ret: TypeId = if (impl.return_type) |rt| resolveMemberTypeIn(self, impl_src, rt, bindings != null) else .void;
    if (self.typesClearlyDiffer(want_ret, got_ret)) {
        return .{
            .method = declared.name,
            .kind = .ret,
            .detail = std.fmt.allocPrint(self.alloc, "it returns '{s}', and the set declares '{s}'", .{
                self.formatTypeName(got_ret), self.formatTypeName(want_ret),
            }) catch "",
        };
    }
    return null;
}

/// One type in a member's method signature. A generic member's spelling is
/// resolved against the instantiation's bindings; a plain member's in its own
/// module, where a module-local type name is visible.
fn resolveMemberTypeIn(self: *Lowering, src: ?[]const u8, node: *const Node, bound: bool) TypeId {
    if (!bound) return self.resolveTypeInSource(src, node);
    const saved = self.current_source_file;
    defer self.setCurrentSourceFile(saved);
    self.setCurrentSourceFile(src);
    return self.resolveTypeWithBindings(node);
}

fn reportNonConformance(
    self: *Lowering,
    sd: *const ast.StructDecl,
    set: *const Set,
    variant: TypeId,
    nc: NonConformance,
    span: ast.Span,
) void {
    const d = self.diagnostics orelse return;
    const set_name = set.decl.name;
    if (nc.kind == .missing) {
        const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': it has no '{s}'", .{ sd.name, set_name, nc.method });
        d.addHelpFmt(id, span, null, "every member declares every method the set requires; '{s}' is declared on '{s}'", .{ nc.method, set_name });
        return;
    }
    const spelled = self.formatSourceTypeName(variant);
    const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': its '{s}' is not the '{s}' the set declares", .{ spelled, set_name, nc.method, nc.method });
    d.addHelpFmt(id, span, null, "{s}", .{nc.detail});
    d.addHelpFmt(id, span, null, "every member answers a required method at the SAME types — the set's declaration states them, and 'Self' there denotes the member ('{s}')", .{spelled});
    // A generic member is admitted per instantiation: the declaration is not at
    // fault, since another instantiation may answer correctly.
    if (!std.mem.eql(u8, spelled, sd.name))
        d.addHelpFmt(id, span, null, "'{s}' is declared '@OpenVariant({s})'; this instantiation is the one that does not answer", .{ sd.name, set_name });
    noteInstantiation(self, d, id);
}

/// Record every OTHER set this member holds by value. Those edges are what makes
/// growth transitive: a member of `R` holding a `Q` grows when `Q` grows, so `R`
/// has to be laid out again — and re-checked, since the member may not fit.
fn recordDependencies(
    self: *Lowering,
    sd: *const ast.StructDecl,
    variant: TypeId,
    set: *const ast.OpenSetDecl,
    span: ast.Span,
) void {
    var seen = std.AutoHashMap(TypeId, void).init(self.alloc);
    defer seen.deinit();
    collectSetsByValue(self, variant, &seen, 0);
    var it = seen.keyIterator();
    while (it.next()) |other| {
        const gop = self.open_set_dependents.getOrPut(other.*) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Dependent).empty;
        for (gop.value_ptr.items) |d| {
            if (d.member == variant) break;
        } else {
            gop.value_ptr.append(self.alloc, .{
                .decl = sd,
                .member = variant,
                .set = set,
                .span = span,
            }) catch {};
        }
    }
}

/// Every open set `ty` contains by value, at any depth. The same walk the
/// finiteness check performs, collecting instead of answering yes/no.
fn collectSetsByValue(self: *Lowering, ty: TypeId, out: *std.AutoHashMap(TypeId, void), depth: u32) void {
    if (depth > 32 or ty.isBuiltin()) return;
    if (isOpenSet(self, ty)) {
        out.put(ty, {}) catch {};
        // A set's own payload is bytes, not the members: growth stops here.
        return;
    }
    switch (self.module.types.get(ty)) {
        .@"struct" => |st| for (st.fields) |f| collectSetsByValue(self, f.ty, out, depth + 1),
        .tuple => |t| for (t.fields) |f| collectSetsByValue(self, f, out, depth + 1),
        .array => |a| collectSetsByValue(self, a.element, out, depth + 1),
        .optional => |o| collectSetsByValue(self, o.child, out, depth + 1),
        .@"union" => |u| for (u.fields) |f| collectSetsByValue(self, f.ty, out, depth + 1),
        .tagged_union => |u| for (u.fields) |f| collectSetsByValue(self, f.ty, out, depth + 1),
        else => {},
    }
}

/// Recompute the set's layout from its current members and re-intern the backing
/// shape, then CASCADE: any member of another set that holds this one by value
/// just changed size, so that set is laid out again too — and the member is
/// re-checked against its own set's ceiling, because growth can push it over.
///
/// The cascade terminates: a member may not hold its own set by value (the
/// finiteness check), and a cycle BETWEEN sets is caught here — two sets whose
/// layouts each depend on the other have no finite answer.
pub fn relayout(self: *Lowering, set: *Set) void {
    layoutFields(self, set);
    cascade(self, set);
}

/// The layout itself: the payload is the largest member, and the interned shape
/// carries the members in the order the set holds them — which the freeze turns
/// into tag order, so from there `fields[tag]` is the member that tag selects.
fn layoutFields(self: *Lowering, set: *Set) void {
    var payload: u32 = 0;
    for (set.members.items) |m| {
        const size: u32 = @intCast(self.module.types.typeSizeBytes(m));
        if (size > payload) payload = size;
    }
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    for (set.members.items) |m| {
        fields.append(self.alloc, .{
            .name = self.module.types.internString(self.module.types.typeName(m)),
            .ty = m,
        }) catch return;
    }
    const info = self.module.types.get(set.ty);
    var updated = info;
    updated.tagged_union.fields = self.alloc.dupe(types.TypeInfo.StructInfo.Field, fields.items) catch return;
    updated.tagged_union.backing_type = backingType(self, payload, set.alignment);
    self.module.types.updatePreservingKey(set.ty, updated);
}

/// Re-lay-out every set whose members hold `grown` by value.
fn cascade(self: *Lowering, grown: *Set) void {
    const deps = self.open_set_dependents.getPtr(grown.ty) orelse return;
    if (deps.items.len == 0) return;
    const grown_name = self.module.types.getString(self.module.types.get(grown.ty).tagged_union.name);
    if (self.open_set_relayout.contains(grown.ty)) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, grown.span, "'{s}' has no finite layout: it holds a set by value that holds '{s}' by value", .{ grown_name, grown_name });
            d.addHelpFmt(id, grown.span, null, "break the cycle with a pointer on one side", .{});
        }
        return;
    }
    self.open_set_relayout.put(grown.ty, {}) catch return;
    defer _ = self.open_set_relayout.remove(grown.ty);
    for (deps.items) |dep| {
        const owner = self.open_sets.getPtr(dep.set) orelse continue;
        // The member is measured again through the grown set; its verdict can
        // change, and the ceiling it now fails is reported where it is declared.
        if (!fits(self, dep.decl, owner, dep.member, dep.span, grown_name)) continue;
        relayout(self, owner);
    }
}

/// The explicit backing shape the layout is stated with: `{ tag: i64, payload:
/// [k]Elem }`, where `Elem`'s own alignment IS the payload alignment. Stating the
/// shape is what keeps set layout out of the backend: the aggregate rules place
/// the payload at `align_up(size_of(tag), align)` and give the whole value that
/// alignment, so both are delivered rather than promised.
fn backingType(self: *Lowering, payload_size: u32, alignment: u32) TypeId {
    const table = &self.module.types;
    const elem = payloadElement(self, alignment);
    const elem_size: u32 = @intCast(table.typeSizeBytes(elem));
    const bytes = alignUp(payload_size, elem_size);
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    fields.append(self.alloc, .{ .name = table.internString(tag_field), .ty = tag_type }) catch return tag_type;
    fields.append(self.alloc, .{
        .name = table.internString(payload_field),
        .ty = table.arrayOf(elem, bytes / elem_size),
    }) catch return tag_type;
    return table.internAnonStruct(self.alloc.dupe(types.TypeInfo.StructInfo.Field, fields.items) catch return tag_type);
}

/// A payload element whose size and alignment are both `alignment`: the tag word
/// for the default 8, and a vector of tag words above it. `alignment` is always a
/// power of two ≥ the tag's own, so the division is exact.
fn payloadElement(self: *Lowering, alignment: u32) TypeId {
    const table = &self.module.types;
    const tag_size: u32 = @intCast(table.typeSizeBytes(tag_type));
    if (alignment <= tag_size) return tag_type;
    return table.vectorOf(tag_type, alignment / tag_size);
}

fn alignUp(value: u32, alignment: u32) u32 {
    if (alignment == 0) return value;
    return (value + alignment - 1) & ~(alignment - 1);
}

// ── Finality (spec: Open Sets — when the layout is final) ────────────────

/// Is `ty` a type an open set's layout decides — the set itself, or anything
/// holding one by value at any depth? Those are the sizes that do not exist
/// until the sets freeze.
pub fn layoutDependsOnSet(self: *Lowering, ty: TypeId) bool {
    if (self.open_set_by_type.count() == 0) return false;
    var seen = std.AutoHashMap(TypeId, void).init(self.alloc);
    defer seen.deinit();
    collectSetsByValue(self, ty, &seen, 0);
    return seen.count() > 0;
}

/// Can the layout of any set `ty` is measured through still change?
///
/// A set grows only when a member is declared into it. Once the declaration pass
/// has admitted every member it can see, the one remaining source of growth is a
/// GENERIC member's instantiation — of the set itself, or of any set whose growth
/// cascades into it (`relayout` → `cascade`). A set that no generic member can
/// reach is therefore already final, and a read of its size is answerable well
/// before the freeze.
pub fn layoutFinal(self: *Lowering, ty: TypeId) bool {
    if (self.module.open_sets_final) return true;
    if (!self.open_set_decls_admitted) return false;
    // No generic member anywhere in the program: the declaration pass admitted the
    // last member any set will ever have.
    if (self.open_set_generic_members.count() == 0) return true;
    var seen = std.AutoHashMap(TypeId, void).init(self.alloc);
    defer seen.deinit();
    collectSetsByValue(self, ty, &seen, 0);

    var pending = std.ArrayList(TypeId).empty;
    defer pending.deinit(self.alloc);
    var it = seen.keyIterator();
    while (it.next()) |k| pending.append(self.alloc, k.*) catch return false;

    var visited = std.AutoHashMap(TypeId, void).init(self.alloc);
    defer visited.deinit();
    while (pending.pop()) |set| {
        const gop = visited.getOrPut(set) catch return false;
        if (gop.found_existing) continue;
        if (mayGrowGenerically(self, set)) return false;
        for (growersOf(self, set)) |grown| pending.append(self.alloc, grown) catch return false;
    }
    return true;
}

/// Every set whose growth reaches `set`: the sets `set`'s own members hold by
/// value, read off the dependency edges the cascade replays.
fn growersOf(self: *Lowering, set: TypeId) []const TypeId {
    var out = std.ArrayList(TypeId).empty;
    var it = self.open_set_dependents.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.items) |dep| {
            const owner = self.open_sets.getPtr(dep.set) orelse continue;
            if (owner.ty != set) continue;
            out.append(self.alloc, e.key_ptr.*) catch {};
            break;
        }
    }
    return out.toOwnedSlice(self.alloc) catch &.{};
}

/// The answer a parked comptime evaluation awaits: the sets have frozen, so the
/// layout it asked for exists. Answered the instant nothing can grow the set
/// (`layoutFinal`); otherwise the evaluation stays parked, and quiescence with it
/// still parked is the expansion deadlock — a program whose set layout depends on
/// a compile-time answer that depends on the layout.
pub fn resolveLayoutFact(self: *Lowering, measured: TypeId) comptime_vm.FactAnswer {
    if (!layoutFinal(self, measured)) return .later;
    self.module.open_set_layouts.put(measured, .{
        .size = @intCast(self.module.types.typeSizeBytes(measured)),
        .alignment = @intCast(self.module.types.typeAlignBytes(measured)),
    }) catch {};
    return .{ .now = .published };
}

// ── The freeze ──────────────────────────────────────────────────────────

/// Freeze the program's open sets, at the same point the `tagged` conformer sets
/// converge: number every member densely inside its OWN set's tag space, write
/// each set's `tag → member Type` table, and publish the layouts. From here an
/// open set has a size, and it is the same one wherever the program asks.
pub fn freezeSets(self: *Lowering) void {
    for (setsByName(self)) |set| {
        numberMembers(self, set);
        // The interned shape follows the numbering, so `fields[tag]` names the
        // member that tag selects.
        layoutFields(self, set);
        fillTypeIdTable(self, set);
    }
    publish(self);
    // The routines every call site already calls: their switch is total over the
    // numbering just assigned, and every arm's callee was lowered in the fixpoint.
    emitDispatchBodies(self);
}

/// The declared sets, ordered by name, so the tables emit in an order the
/// program's text decides rather than a hash's.
fn setsByName(self: *Lowering) []const *Set {
    var out = std.ArrayList(*Set).empty;
    var it = self.open_sets.valueIterator();
    while (it.next()) |set| out.append(self.alloc, set) catch {};
    const Ctx = struct {
        fn lt(_: void, a: *Set, b: *Set) bool {
            return std.mem.order(u8, a.decl.name, b.decl.name) == .lt;
        }
    };
    std.mem.sort(*Set, out.items, {}, Ctx.lt);
    return out.toOwnedSlice(self.alloc) catch &.{};
}

/// The dense tags, from 0, in the members' canonical identity order — their
/// nominal-aware mangle, so two same-spelled members from different modules order
/// deterministically. Each set numbers its own space: a member's tag indexes the
/// set it joined and nothing else.
fn numberMembers(self: *Lowering, set: *Set) void {
    const Ctx = struct {
        l: *Lowering,
        fn lt(ctx: @This(), a: TypeId, b: TypeId) bool {
            return std.mem.order(u8, ctx.l.mangleTypeName(a), ctx.l.mangleTypeName(b)) == .lt;
        }
    };
    std.mem.sort(TypeId, set.members.items, Ctx{ .l = self }, Ctx.lt);
    for (set.members.items, 0..) |member, tag| {
        self.open_set_tags.put(.{ .set = set.ty, .member = member }, @intCast(tag)) catch {};
    }
}

/// The set's `tag → member Type` table: what `type_of`, the `any` view, and the
/// type switch read to recover the active member's type from a slot's tag word.
/// Created EMPTY at the first site that reads it — a site lowers long before the
/// numbering exists — and filled here, at the freeze, one row per member in tag
/// order. A set nothing consumes needs no table.
fn fillTypeIdTable(self: *Lowering, set: *Set) void {
    const gid = self.open_set_tables.get(set.ty) orelse return;
    const members = set.members.items;
    const rows = self.alloc.alloc(inst_mod.ConstantValue, @max(members.len, 1)) catch return;
    rows[0] = .{ .int = 0 };
    for (members, 0..) |member, i| rows[i] = .{ .int = @intCast(member.index()) };
    const g = &self.module.globals.items[@intFromEnum(gid)];
    g.ty = self.module.types.arrayOf(.type_value, @intCast(@max(members.len, 1)));
    g.init_val = .{ .aggregate = rows };
}

/// The set's table global, minted on first read with a single zero row so the
/// site has a symbol to index; `fillTypeIdTable` writes the rows at the freeze.
fn typeIdTable(self: *Lowering, set: *const Set) inst_mod.GlobalId {
    if (self.open_set_tables.get(set.ty)) |gid| return gid;
    const name = std.fmt.allocPrint(self.alloc, "__sx_set_{s}_type_ids", .{tableName(self, set)}) catch @panic("out of memory");
    const gid = self.module.addGlobal(.{
        .name = self.module.types.internString(name),
        .ty = self.module.types.arrayOf(.type_value, 1),
        .init_val = .{ .zeroinit = {} },
        .is_const = true,
    });
    self.open_set_tables.put(set.ty, gid) catch @panic("out of memory");
    return gid;
}

/// The set's name, sanitized for a symbol.
fn tableName(self: *Lowering, set: *const Set) []const u8 {
    const out = self.alloc.dupe(u8, self.declIdentityName(set.decl.name, @ptrCast(set.decl))) catch return "set";
    for (out) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_') ch.* = '_';
    }
    return out;
}

/// Publish the frozen layouts: the numbering crosses into the module, and the
/// flag is what every reader of a set's size gates on.
fn publish(self: *Lowering) void {
    self.module.open_sets_final = true;
    var it = self.open_set_tags.iterator();
    while (it.next()) |e| {
        self.module.open_set_tags.put(
            .{ .set = e.key_ptr.set, .member = e.key_ptr.member },
            e.value_ptr.*,
        ) catch {};
    }
}

/// A position that must be folded BEFORE the freeze asked for a size an open set
/// has not settled: an array dimension, a `::` constant, an `inline for` bound.
/// Such a position is fixed where it is written, and a set's members are declared
/// anywhere in the program, so there is no number to answer with — the refusal is
/// the answer.
pub fn refuseUnfrozenLayout(self: *Lowering, measured: TypeId, span: ast.Span) void {
    const d = self.diagnostics orelse return;
    const set_name = firstSetName(self, measured) orelse return;
    const before = d.items.items.len;
    const id = if (isOpenSet(self, measured))
        d.addFmtId(.err, span, "the layout of the open set '{s}' is not final here", .{set_name})
    else
        d.addFmtId(.err, span, "the layout of '{s}' is not final here: it holds the open set '{s}' by value", .{ self.formatTypeName(measured), set_name });
    // One position folds more than once; the refusal deduplicates, and the helps
    // belong to the one that stands.
    if (d.items.items.len == before) return;
    d.addHelpFmt(id, span, null, "a set's members are declared anywhere in the program, and this position is fixed where it is written — a member declared later would contradict the number", .{});
    d.addHelpFmt(id, span, null, "read the size where it is a VALUE ('n := size_of(…)'), or bind it with '#run size_of(…)' — both are answered from the frozen layout", .{});
}

/// The set `measured`'s layout depends on, named for the refusal.
fn firstSetName(self: *Lowering, measured: TypeId) ?[]const u8 {
    if (self.open_set_by_type.get(measured)) |decl| return decl.name;
    var seen = std.AutoHashMap(TypeId, void).init(self.alloc);
    defer seen.deinit();
    collectSetsByValue(self, measured, &seen, 0);
    var best: ?[]const u8 = null;
    var it = seen.keyIterator();
    while (it.next()) |k| {
        const decl = self.open_set_by_type.get(k.*) orelse continue;
        if (best == null or std.mem.order(u8, decl.name, best.?) == .lt) best = decl.name;
    }
    return best;
}

// ── Membership as the declarations state it ──────────────────────────────

/// Is `ty` a member of the set named `set_name`? Membership IS the member's
/// declaration (spec: Open Sets), so the question is answered from the
/// declarations rather than from the admitted list: an ADMITTED type is a member,
/// and so is one whose declaration joins the set but whose admission has not run
/// yet. That keeps the answer independent of when it is asked — there is no point
/// at which a declared member reads as a non-member and a later pass contradicts
/// it.
pub fn declaresMembership(self: *Lowering, ty: TypeId, set: *const ast.OpenSetDecl) bool {
    if (self.open_variant_of.get(ty)) |joined| return joined == set;
    const author = memberAuthor(self, ty) orelse return false;
    const joined = author.decl.open_variant_of orelse return false;
    // The head is a PATH, and what it reaches is the question — comparing its
    // spelling against the set's would answer differently for the same member
    // depending on how it wrote the head.
    return setDeclNamed(self, joined, author.source) == set;
}

/// The struct declaration `ty` was written as — its own, or the template a
/// generic instance was stamped from — with the file that wrote it, which is what
/// its `@OpenVariant` head resolves from.
const MemberAuthor = struct { decl: *const ast.StructDecl, source: ?[]const u8 };

fn memberAuthor(self: *Lowering, ty: TypeId) ?MemberAuthor {
    const name = self.getStructTypeName(ty) orelse return null;
    // A generic instance carries its template's declaration; the file that wrote
    // the template is where its head resolves from, and the template is reached
    // through the same author record its instantiation was stamped from.
    if (self.struct_instance_author.get(name)) |decl| {
        // The TEMPLATE's module is where its head was written, and the template
        // carries it — asking that rather than whatever file is current keeps the
        // answer the member's own.
        const src: ?[]const u8 = blk: {
            const tmpl_name = self.struct_instance_template.get(name) orelse break :blk null;
            const tmpl = self.program_index.struct_template_map.get(tmpl_name) orelse break :blk null;
            break :blk tmpl.source_file;
        };
        return .{ .decl = decl, .source = src };
    }
    if (self.plain_struct_authors.get(ty)) |author| return .{ .decl = author.decl, .source = author.source };
    return null;
}

fn memberDecl(self: *Lowering, ty: TypeId) ?*const ast.StructDecl {
    const author = memberAuthor(self, ty) orelse return null;
    return author.decl;
}

/// The set `member` joins, when it joins one.
pub fn setOfMember(self: *Lowering, member: TypeId) ?*Set {
    if (self.open_variant_of.get(member)) |decl| return self.open_sets.getPtr(decl);
    const author = memberAuthor(self, member) orelse return null;
    const joined = author.decl.open_variant_of orelse return null;
    const set_decl = setDeclNamed(self, joined, author.source) orelse return null;
    return self.open_sets.getPtr(set_decl);
}

/// Refuse a conversion of `src_ty` into the set `set_ty` when `src_ty` never
/// declared itself into it — true when refused, and the caller yields a value of
/// the set instead of converting. Membership is a declaration, so a non-member has
/// nothing to lift and its bytes are not a set value in any spelling; a member of
/// ANOTHER set is told it belongs to one (spec: Open Sets — formation).
pub fn refuseNonMember(self: *Lowering, src_ty: TypeId, set_ty: TypeId, span: ast.Span) bool {
    if (src_ty == set_ty or src_ty == .unresolved) return false;
    const set = setOf(self, set_ty) orelse return false;
    if (declaresMembership(self, src_ty, set.decl)) return false;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'{s}' cannot be converted to '{s}': it is not a member of it", .{ self.formatSourceTypeName(src_ty), self.formatSourceTypeName(set_ty) });
        membershipHelp(self, d, id, src_ty, set_ty, span);
        noteInstantiation(self, d, id);
    }
    return true;
}

/// A refusal raised while a generic body is being monomorphized names the call
/// that forced this instantiation: the body is written once and refused per
/// instantiation, so the site that spelled this one is where the fault is answered
/// — and for a caller in another module it is the only span it can act on.
pub fn noteInstantiation(self: *Lowering, d: *errors.DiagnosticList, id: usize) void {
    if (self.mono_sites.items.len == 0) return;
    const site = self.mono_sites.items[0];
    const saved = d.current_source_file;
    d.current_source_file = site.source;
    d.addNoteFmt(id, site.span, "instantiated from here", .{});
    d.current_source_file = saved;
}

/// Why a type is not a member, in the terms the declarations state it: a type that
/// joined ANOTHER set is told it belongs to one, and any other type is shown the
/// declaration that would make it a member.
pub fn membershipHelp(self: *Lowering, d: *errors.DiagnosticList, id: usize, member_ty: TypeId, set_ty: TypeId, span: ast.Span) void {
    if (setOfMember(self, member_ty)) |other| {
        d.addHelpFmt(id, span, null, "'{s}' is a member of '{s}', and a type belongs to one set", .{ self.formatSourceTypeName(member_ty), self.formatSourceTypeName(other.ty) });
    } else if (member_ty.isBuiltin() or self.getStructTypeName(member_ty) == null) {
        // A builtin carries no declaration of its own, so there is no spelling
        // that would make it a member — only a type the program declares can be.
        d.addHelpFmt(id, span, null, "'{s}' is a builtin and cannot declare itself into a set — a member is a type the program declares: 'YourType :: @OpenVariant({s}) {{ … }}'", .{ self.formatSourceTypeName(member_ty), self.formatTypeName(set_ty) });
    } else {
        d.addHelpFmt(id, span, null, "a type joins by declaring itself into the set: '{s} :: @OpenVariant({s}) {{ … }}'", .{ self.formatSourceTypeName(member_ty), self.formatSourceTypeName(set_ty) });
    }
}

/// Refuse a conversion of an `any` into the set `set_ty` — always true, and the
/// caller yields a value of the set instead of converting. Boxing a set boxes the
/// MEMBER it carries, so no `any` in the program holds a set value: there is
/// nothing at a set destination for an unbox to read (spec: Open Sets — what a set
/// value answers about itself).
pub fn refuseSetFromAny(self: *Lowering, set_ty: TypeId, span: ast.Span) bool {
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'any' cannot be converted to '{s}': an 'any' never holds a set value — boxing a set boxes the member it carries", .{self.formatTypeName(set_ty)});
        d.addHelpFmt(id, span, null, "name the member as the target instead, or open the box with a type switch — its arms bind the member", .{});
        noteInstantiation(self, d, id);
    }
    return true;
}

/// The set's required method of that name, or null when the set does not require
/// one. A method with a default body is not dispatched through the set — nothing
/// in this packet declares one.
pub fn requiredMethod(set: *const Set, name: []const u8) ?ast.ProtocolMethodDecl {
    for (set.decl.methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

// ── Formation: a member value becomes a set value ────────────────────────

/// Write `value` into the set slot `slot` points at: the member's tag in the tag
/// word, the member's bytes in the payload. The payload is addressed through the
/// backing shape, so the member lands exactly where the layout promised.
pub fn writeMemberInto(self: *Lowering, slot: Ref, value: Ref, member_ty: TypeId, set_ty: TypeId) void {
    const table = &self.module.types;
    const tag_ptr = self.builder.structGepTyped(slot, 0, table.ptrTo(tag_type), set_ty);
    self.builder.store(tag_ptr, self.builder.emit(.{ .open_set_tag_of = .{ .set = set_ty, .member = member_ty } }, tag_type));
    self.builder.store(payloadAddress(self, slot, set_ty, member_ty), value);
}

/// The active member's storage inside the slot, typed as that member.
fn payloadAddress(self: *Lowering, slot: Ref, set_ty: TypeId, member_ty: TypeId) Ref {
    const table = &self.module.types;
    const info = table.get(set_ty).tagged_union;
    const payload_ty = table.get(info.backing_type.?).@"struct".fields[1].ty;
    const bytes = self.builder.structGepTyped(slot, 1, table.ptrTo(payload_ty), set_ty);
    const want = table.ptrTo(member_ty);
    return self.builder.emit(.{ .bitcast = .{
        .operand = bytes,
        .from = table.ptrTo(payload_ty),
        .to = want,
    } }, want);
}

/// A member VALUE where the set is expected: an independent slot holding this
/// member's tag and a copy of its bytes. The set is an inline slot, so this is a
/// by-value formation — the source is untouched and later writes through either
/// one do not reach the other.
pub fn coerceMemberToSet(self: *Lowering, value: Ref, member_ty: TypeId, set_ty: TypeId) Ref {
    const slot = self.builder.alloca(set_ty);
    writeMemberInto(self, slot, value, member_ty, set_ty);
    return self.builder.load(slot, set_ty);
}

// ── What a set value answers about itself ───────────────────────────────

/// The address of the slot `value` is. An lvalue answers with its own storage, so
/// what is read is the value itself; an rvalue gets a temporary, which is all a
/// value about to be discarded needs.
pub fn slotAddress(self: *Lowering, set_ty: TypeId, value: Ref, node: ?*const Node) Ref {
    if (self.refStorageAddress(value)) |addr| return addr;
    if (node) |n| if (self.isLvalueExpr(n)) return self.lowerExprAsPtr(n);
    const slot = self.builder.alloca(set_ty);
    self.builder.store(slot, value);
    return slot;
}

/// The `Type` of the member the slot at `slot_addr` carries: its tag word, read
/// through the set's own numbering. Everything that answers what a set value IS —
/// `type_of`, the `any` view — goes through here.
pub fn memberTypeId(self: *Lowering, set_ty: TypeId, slot_addr: Ref) Ref {
    const set = setOf(self, set_ty) orelse return self.builder.constType(set_ty);
    const table = &self.module.types;
    const tag_ptr = self.builder.structGepTyped(slot_addr, 0, table.ptrTo(tag_type), set_ty);
    const tag = self.builder.load(tag_ptr, tag_type);
    return self.builder.emit(.{ .open_set_type_id = .{
        .set = set_ty,
        .tag = tag,
        .table = typeIdTable(self, set),
    } }, .type_value);
}

/// A set value's `any` view: the member's address INSIDE the slot, and the
/// member's own `Type`. The view borrows the slot, so it answers for the member
/// carried there and lives exactly as long as that slot does.
pub fn anyView(self: *Lowering, set_ty: TypeId, value: Ref, node: ?*const Node) Ref {
    return anyViewOfSlot(self, set_ty, slotAddress(self, set_ty, value, node));
}

/// The same view over a slot already addressed.
fn anyViewOfSlot(self: *Lowering, set_ty: TypeId, slot: Ref) Ref {
    const table = &self.module.types;
    const info = table.get(set_ty).tagged_union;
    const payload_ty = table.get(info.backing_type.?).@"struct".fields[1].ty;
    const bytes = self.builder.structGepTyped(slot, 1, table.ptrTo(payload_ty), set_ty);
    const void_ptr = table.ptrTo(.void);
    const data = self.builder.emit(.{ .bitcast = .{
        .operand = bytes,
        .from = table.ptrTo(payload_ty),
        .to = void_ptr,
    } }, void_ptr);
    return self.builder.makeAny(memberTypeId(self, set_ty, slot), data);
}

/// A set value asked for one of its members: the tag decides. `member` is a member
/// of `set_ty`, so the question is one compare against that member's constant tag,
/// and the answer is a COPY of the member read out of the payload. The soft form
/// answers `null` on the other members; the hard form panics through the same
/// helper every checked cast panics through, over the view that names the member
/// actually carried.
pub fn lowerDowncast(
    self: *Lowering,
    set_ty: TypeId,
    member: TypeId,
    value: Ref,
    value_node: *const Node,
    type_node: *const Node,
    soft: bool,
    span: ast.Span,
) Ref {
    const table = &self.module.types;
    const result_ty = if (soft) table.optionalOf(member) else member;
    const slot = slotAddress(self, set_ty, value, value_node);
    const tag_ptr = self.builder.structGepTyped(slot, 0, table.ptrTo(tag_type), set_ty);
    const tag = self.builder.load(tag_ptr, tag_type);
    const want = self.builder.emit(.{ .open_set_tag_of = .{ .set = set_ty, .member = member } }, tag_type);
    const matches = self.builder.emit(.{ .cmp_eq = .{ .lhs = tag, .rhs = want } }, .bool);

    const ok_bb = self.freshBlock("setcast.ok");
    const fail_bb = self.freshBlock("setcast.fail");
    const merge_bb = self.freshBlockWithParams("setcast.merge", &.{result_ty});
    self.builder.condBr(matches, ok_bb, &.{}, fail_bb, &.{});

    self.builder.switchToBlock(ok_bb);
    const held = self.builder.load(payloadAddress(self, slot, set_ty, member), member);
    self.builder.br(merge_bb, &.{if (soft) self.builder.optionalWrap(held, result_ty) else held});

    self.builder.switchToBlock(fail_bb);
    if (soft) {
        self.builder.br(merge_bb, &.{self.builder.constNull(result_ty)});
    } else {
        const view = anyViewOfSlot(self, set_ty, slot);
        var buf: [40]u8 = undefined;
        const nm = std.fmt.bufPrint(&buf, "$setcast_{d}", .{self.block_counter}) catch "$setcast";
        self.block_counter += 1;
        const owned = self.alloc.dupe(u8, nm) catch @panic("out of memory");
        self.scope.?.put(owned, .{ .ref = view, .ty = .any, .is_alloca = false });
        const src = value_node.source_file;
        const recv_id = self.synthNode(.{ .identifier = .{ .name = owned } }, span, src);
        const callee = self.synthNode(.{ .identifier = .{ .name = "__sx_cast_or_panic" } }, span, src);
        const args = self.alloc.dupe(*Node, &.{ recv_id, @constCast(type_node) }) catch @panic("out of memory");
        const call = ast.Call{ .callee = callee, .args = args };
        self.builder.br(merge_bb, &.{self.lowerCall(&call)});
    }

    self.builder.switchToBlock(merge_bb);
    return self.builder.blockParam(merge_bb, 0, result_ty);
}

/// Refuse asking a set value for a type that never declared itself into the set —
/// true when refused. Membership is a declaration, so no value of the set is ever a
/// value of that type, whatever tag it carries.
pub fn refuseNonMemberTarget(self: *Lowering, set_ty: TypeId, target: TypeId, span: ast.Span) bool {
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "a '{s}' value is never '{s}': it is not a member of it", .{ self.formatSourceTypeName(set_ty), self.formatSourceTypeName(target) });
        membershipHelp(self, d, id, target, set_ty, span);
        noteInstantiation(self, d, id);
    }
    return true;
}

/// Refuse a type-switch arm that names a SET over a set subject — true when
/// refused. The switch opens the member a value carries, and a set is what a slot
/// is declared as, never what it holds: its own set included.
pub fn refuseSetArm(self: *Lowering, subject_ty: TypeId, arm_ty: TypeId, span: ast.Span) bool {
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "a switch on '{s}' opens the member the value carries, and '{s}' is a set — never a member of one", .{ self.formatTypeName(subject_ty), self.formatTypeName(arm_ty) });
        d.addHelpFmt(id, span, null, "name the members this code handles ('case <Member>:'), and let 'else:' answer for the rest", .{});
        noteInstantiation(self, d, id);
    }
    return true;
}

/// Refuse `xx` between a set value and one of its members: the conversion is the
/// downcast, and it can fail — which `xx` has no way to say. True when refused.
pub fn refuseUntemperedDowncast(self: *Lowering, set_ty: TypeId, member: TypeId, span: ast.Span) bool {
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'{s}' holds one member at a time, so reading a '{s}' out of it can fail, and 'xx' does not say what happens then", .{ self.formatTypeName(set_ty), self.formatSourceTypeName(member) });
        d.addHelpFmt(id, span, null, "ask with a temperament: '.({s})' panics on another member, '.(?{s})' answers null", .{ self.formatSourceTypeName(member), self.formatSourceTypeName(member) });
        noteInstantiation(self, d, id);
    }
    return true;
}

// ── Dispatch ────────────────────────────────────────────────────────────

/// One outlined dispatch routine: `__sx_set_<P>_<m>(v: *P, args…) -> ret`.
/// Declared at the first call site — its FuncId is what the site calls — and
/// BODIED at the freeze, where the member set is final and the tags are numbered.
pub const PendingDispatch = struct {
    set_name: []const u8,
    set_decl: *const ast.OpenSetDecl,
    set_ty: TypeId,
    method: ast.ProtocolMethodDecl,
    fid: FuncId,
    ret: TypeId,
    /// The first site that called it, for the diagnostic a memberless set earns.
    site: ast.Span,
    source_file: ?[]const u8,
};

pub const MethodKey = struct { set: TypeId, method: types.StringId };
pub const ArmKey = struct { set: TypeId, member: TypeId, method: types.StringId };

/// Call a required method on a set value: one call into the set's outlined
/// routine, which switches on the tag. `recv_addr` is the slot's address — the
/// arm hands it to the member's own method as `*Member`, so a method that writes
/// through `self` writes into this very slot.
pub fn emitDispatch(
    self: *Lowering,
    recv_addr: Ref,
    set: *Set,
    method: ast.ProtocolMethodDecl,
    args: []const Ref,
    span: ast.Span,
) Ref {
    const job = dispatchRoutine(self, set, method, span) orelse return Ref.none;
    if (args.len != method.params.len) {
        if (self.diagnostics) |d| {
            const s: []const u8 = if (method.params.len == 1) "" else "s";
            const verb: []const u8 = if (args.len == 1) "was" else "were";
            d.addFmt(.err, span, "'{s}' expects {d} argument{s}, but {d} {s} given", .{ method.name, method.params.len, s, args.len, verb });
        }
        return self.builder.constUndef(job.ret);
    }
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (self.implicit_ctx_enabled) call_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
    call_args.append(self.alloc, recv_addr) catch unreachable;
    const params = self.module.functions.items[@intFromEnum(job.fid)].params;
    const first_user: usize = if (self.implicit_ctx_enabled) 2 else 1;
    for (args, 0..) |a, i| {
        const want = if (first_user + i < params.len) params[first_user + i].ty else self.builder.getRefType(a);
        call_args.append(self.alloc, self.coerceToType(a, self.builder.getRefType(a), want)) catch unreachable;
    }
    const owned = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    return self.builder.call(job.fid, owned, job.ret);
}

/// The routine for one (set, method), created once. Its signature comes from the
/// SET's declaration — the one statement of what the method is — so every member
/// answers at the same types whatever its own body says.
fn dispatchRoutine(self: *Lowering, set: *Set, method: ast.ProtocolMethodDecl, span: ast.Span) ?PendingDispatch {
    const key = MethodKey{ .set = set.ty, .method = self.module.types.internString(method.name) };
    if (self.open_set_dispatch.get(key)) |at| return self.open_set_pending.items[at];
    const saved = self.current_source_file;
    defer self.setCurrentSourceFile(saved);
    self.setCurrentSourceFile(set.source_file);

    const void_ptr = self.module.types.ptrTo(.void);
    var params = std.ArrayList(inst_mod.Function.Param).empty;
    defer params.deinit(self.alloc);
    if (self.implicit_ctx_enabled)
        params.append(self.alloc, .{ .name = self.module.types.internString("__sx_ctx"), .ty = void_ptr }) catch unreachable;
    params.append(self.alloc, .{
        .name = self.module.types.internString("v"),
        .ty = self.module.types.ptrTo(set.ty),
    }) catch unreachable;
    for (method.params, 0..) |pnode, i| {
        if (spellsSelf(pnode, 0)) {
            refuseUndispatchable(self, set, method, pnode.span);
            return null;
        }
        const pty = self.resolveTypeWithBindings(pnode);
        if (pty == .unresolved) {
            refuseUndispatchable(self, set, method, pnode.span);
            return null;
        }
        const pname = if (i < method.param_names.len) method.param_names[i] else "a";
        params.append(self.alloc, .{ .name = self.module.types.internString(pname), .ty = pty }) catch unreachable;
    }
    const ret: TypeId = if (method.return_type) |rt| blk: {
        if (spellsSelf(rt, 0)) {
            refuseUndispatchable(self, set, method, rt.span);
            return null;
        }
        const rty = self.resolveTypeWithBindings(rt);
        if (rty == .unresolved) {
            refuseUndispatchable(self, set, method, rt.span);
            return null;
        }
        break :blk rty;
    } else .void;

    const fname = std.fmt.allocPrint(self.alloc, "__sx_set_{s}_{s}", .{ symbolName(self, set), method.name }) catch return null;
    var func = inst_mod.Function.init(
        self.module.types.internString(fname),
        self.alloc.dupe(inst_mod.Function.Param, params.items) catch return null,
        ret,
    );
    func.has_implicit_ctx = self.implicit_ctx_enabled;
    const fid = self.module.addFunction(func);
    self.open_set_dispatch.put(key, self.open_set_pending.items.len) catch {};
    const job = PendingDispatch{
        .set_name = set.decl.name,
        .set_decl = set.decl,
        .set_ty = set.ty,
        .method = method,
        .fid = fid,
        .ret = ret,
        .site = span,
        .source_file = saved,
    };
    self.open_set_pending.append(self.alloc, job) catch {};
    return job;
}

/// Does this type expression name `Self` anywhere? `Self` in a required method
/// denotes the MEMBER, so a signature mentioning it has no caller-side type on a
/// set value — whatever composite it is written under.
fn spellsSelf(node: *const Node, depth: u8) bool {
    if (depth > 8) return false;
    return switch (node.data) {
        .type_expr => |te| std.mem.eql(u8, te.name, "Self"),
        .pointer_type_expr => |p| spellsSelf(p.pointee_type, depth + 1),
        .many_pointer_type_expr => |p| spellsSelf(p.element_type, depth + 1),
        .optional_type_expr => |o| spellsSelf(o.inner_type, depth + 1),
        .slice_type_expr => |sl| spellsSelf(sl.element_type, depth + 1),
        .array_type_expr => |a| spellsSelf(a.element_type, depth + 1),
        .parameterized_type_expr => |pte| blk: {
            if (std.mem.eql(u8, pte.name, "Self")) break :blk true;
            for (pte.args) |a| {
                if (spellsSelf(a, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// A required method whose signature has no caller-side type on a set value —
/// `Self` past the receiver names the MEMBER, and a set value is not any one
/// member. The generic bound is where `Self` is a type.
fn refuseUndispatchable(self: *Lowering, set: *const Set, method: ast.ProtocolMethodDecl, span: ast.Span) void {
    const d = self.diagnostics orelse return;
    const before = d.items.items.len;
    const id = d.addFmtId(.err, span, "'{s}' cannot be dispatched on a '{s}' value: its signature names a type that no set value has", .{ method.name, set.decl.name });
    // Every call site asks again; the refusal deduplicates, and the help belongs to
    // the one that stands.
    if (d.items.items.len == before) return;
    d.addHelpFmt(id, span, null, "'Self' in a required method denotes the MEMBER, and a set value is not any one member — call it through a membership bound instead: 'f :: (v: $V/{s}) {{ v.{s}(…); }}'", .{ set.decl.name, method.name });
}

/// The set's name, sanitized for a symbol.
fn symbolName(self: *Lowering, set: *const Set) []const u8 {
    const out = self.alloc.dupe(u8, self.declIdentityName(set.decl.name, @ptrCast(set.decl))) catch return "set";
    for (out) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_') ch.* = '_';
    }
    return out;
}

/// Lower every member's implementation of every called method, so the arms exist
/// before the tags are numbered. Returns true when doing so grew anything — the
/// convergence fixpoint's signal to run another round, since lowering a member's
/// method can instantiate a generic member of this or another set.
pub fn materializeArms(self: *Lowering) bool {
    var changed = false;
    var i: usize = 0;
    while (i < self.open_set_pending.items.len) : (i += 1) {
        const job = self.open_set_pending.items[i];
        const set = self.open_sets.getPtr(job.set_decl) orelse continue;
        var m: usize = 0;
        while (m < set.members.items.len) : (m += 1) {
            const member = set.members.items[m];
            const key = ArmKey{ .set = job.set_ty, .member = member, .method = self.module.types.internString(job.method.name) };
            if (self.open_set_arms.contains(key)) continue;
            const before = self.open_set_epoch;
            const fid = memberMethod(self, member, job.method.name) orelse continue;
            self.open_set_arms.put(key, fid) catch {};
            changed = true;
            if (self.open_set_epoch != before) break;
        }
    }
    return changed;
}

/// The member's own implementation of `name`, lowered. A member declares its
/// methods in its own body, so this is the ordinary struct-method lookup — asked
/// of a plain member and of a generic instance alike. Admission already proved the
/// signature is the one the set declares, so the arm is a direct call.
fn memberMethod(self: *Lowering, member: TypeId, name: []const u8) ?FuncId {
    if (self.plainStructMethod(member, name)) |m| return self.ensurePlainStructMethodLowered(m);
    const inst = self.getStructTypeName(member) orelse return null;
    if (self.genericInstanceMethod(inst, name)) |gm| return self.ensureGenericInstanceMethodLowered(gm);
    return null;
}

/// Write every declared routine's body: a total switch over the frozen tag space,
/// each arm a direct call to that member's own method through the payload. The
/// switch is total by construction — the tags ARE the frozen members — so the
/// default arm is unreachable rather than a fallback. A single-member set has no
/// switch at all: the call devirtualizes completely.
pub fn emitDispatchBodies(self: *Lowering) void {
    for (self.open_set_pending.items) |job| emitDispatchBody(self, job);
}

fn emitDispatchBody(self: *Lowering, job: PendingDispatch) void {
    const set = self.open_sets.getPtr(job.set_decl) orelse return;
    if (set.members.items.len == 0) {
        refuseMemberlessDispatch(self, job);
        return;
    }
    const saved_func = self.builder.func;
    const saved_block = self.builder.current_block;
    const saved_counter = self.builder.inst_counter;
    const saved_ctx = self.current_ctx_ref;
    defer {
        self.builder.func = saved_func;
        self.builder.current_block = saved_block;
        self.builder.inst_counter = saved_counter;
        self.current_ctx_ref = saved_ctx;
    }

    const has_ctx = self.implicit_ctx_enabled;
    const nparams = self.module.functions.items[@intFromEnum(job.fid)].params.len;
    self.builder.func = job.fid;
    self.builder.inst_counter = @intCast(nparams);
    if (has_ctx) self.current_ctx_ref = Ref.fromIndex(0);
    const entry = self.builder.appendBlock(self.module.types.internString("entry"), &.{});
    self.builder.switchToBlock(entry);

    const recv = Ref.fromIndex(if (has_ctx) 1 else 0);
    const user_base: u32 = if (has_ctx) 2 else 1;

    if (set.members.items.len == 1) {
        emitArm(self, job, set.members.items[0], recv, user_base);
        self.builder.finalize();
        return;
    }

    const tag_ptr = self.builder.structGepTyped(recv, 0, self.module.types.ptrTo(tag_type), job.set_ty);
    const tag = self.builder.load(tag_ptr, tag_type);
    var cases = std.ArrayList(inst_mod.SwitchBranch.Case).empty;
    defer cases.deinit(self.alloc);
    var arms = std.ArrayList(inst_mod.BlockId).empty;
    defer arms.deinit(self.alloc);
    for (set.members.items) |member| {
        const b = self.freshBlock("set.arm");
        arms.append(self.alloc, b) catch unreachable;
        const value = self.open_set_tags.get(.{ .set = job.set_ty, .member = member }) orelse 0;
        cases.append(self.alloc, .{ .value = @intCast(value), .target = b, .args = &.{} }) catch unreachable;
    }
    const unr = self.freshBlock("set.unr");
    self.builder.switchBr(tag, cases.items, unr, &.{});
    for (set.members.items, 0..) |member, i| {
        self.builder.switchToBlock(arms.items[i]);
        emitArm(self, job, member, recv, user_base);
    }
    // Total over the frozen tag space: every tag a value can carry has an arm,
    // so this block is reached by no tag the program can produce.
    self.builder.switchToBlock(unr);
    _ = self.builder.emit(.{ .@"unreachable" = {} }, .void);
    self.builder.finalize();
}

fn emitArm(self: *Lowering, job: PendingDispatch, member: TypeId, recv: Ref, user_base: u32) void {
    const key = ArmKey{ .set = job.set_ty, .member = member, .method = self.module.types.internString(job.method.name) };
    const callee = self.open_set_arms.get(key) orelse {
        _ = self.builder.emit(.{ .@"unreachable" = {} }, .void);
        return;
    };
    const self_ptr = payloadAddress(self, recv, job.set_ty, member);
    var call_args = std.ArrayList(Ref).empty;
    defer call_args.deinit(self.alloc);
    if (self.implicit_ctx_enabled) call_args.append(self.alloc, self.current_ctx_ref) catch unreachable;
    call_args.append(self.alloc, self_ptr) catch unreachable;
    for (job.method.params, 0..) |_, i| {
        call_args.append(self.alloc, Ref.fromIndex(@intCast(user_base + i))) catch unreachable;
    }
    const owned = self.alloc.dupe(Ref, call_args.items) catch unreachable;
    const result = self.builder.call(callee, owned, job.ret);
    if (job.ret == .void) self.builder.retVoid() else self.builder.ret(result, job.ret);
}

/// A required method was called on a set nothing is a member of. No value of that
/// set can exist, so there is no receiver the call could have had.
fn refuseMemberlessDispatch(self: *Lowering, job: PendingDispatch) void {
    const d = self.diagnostics orelse return;
    const saved = d.current_source_file;
    defer d.current_source_file = saved;
    if (job.source_file) |src| d.current_source_file = src;
    const id = d.addFmtId(.err, job.site, "'{s}' cannot be called on a '{s}' value: nothing is a member of '{s}', so no value of it exists", .{ job.method.name, job.set_name, job.set_name });
    d.addHelpFmt(id, job.site, null, "a type joins the set by declaring itself into it: 'YourType :: @OpenVariant({s}) {{ … }}'", .{job.set_name});
}
