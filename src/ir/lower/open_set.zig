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
const comptime_vm = @import("../comptime_vm.zig");
const lower = @import("../lower.zig");
const Lowering = lower.Lowering;

/// The tag word: the shipped payload-enum tag type, so dispatch and layout reuse
/// the tagged-union machinery unchanged.
pub const tag_type: TypeId = .i64;

/// The name of the backing struct's payload field.
const payload_field = "payload";
const tag_field = "tag";

/// `align` when the declaration omits it: the alignment ordinary allocators
/// guarantee, which is what a `List(P)` can honour today.
pub const default_align: u32 = 8;

/// A member whose own size depends on another set's layout: it holds that set BY
/// VALUE, so growing that set grows this member — and therefore the set THIS
/// member belongs to. Recorded at admission (the finiteness walk already visits
/// exactly these edges) and replayed by `relayout`.
pub const Dependent = struct {
    decl: *const ast.StructDecl,
    member: TypeId,
    /// The set this member belongs to, which has to be laid out again.
    set_name: []const u8,
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
    if (self.open_sets.getPtr(decl.name) != null) {
        if (self.diagnostics) |d|
            d.addFmt(.err, node.span, "'{s}' is already declared as an open set", .{decl.name});
        return;
    }
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
    self.open_sets.put(decl.name, .{
        .decl = decl,
        .ty = ty,
        .max = options.max,
        .alignment = effectiveAlign(self, options.alignment),
        .declared_align = options.alignment,
        .span = node.span,
        .source_file = node.source_file orelse self.current_source_file,
    }) catch return;
    self.open_set_by_type.put(ty, decl.name) catch {};
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

/// The set a `@OpenVariant(name)` head names, or null with a diagnostic.
pub fn setNamed(self: *Lowering, name: []const u8, span: ast.Span) ?*Set {
    if (self.open_sets.getPtr(name)) |set| return set;
    if (self.diagnostics) |d| {
        const id = d.addFmtId(.err, span, "'{s}' is not an open set", .{name});
        d.addHelpFmt(id, span, null, "a member joins a set declared '{s} :: @OpenSet(.{{ max = … }}) {{ … }}'", .{name});
    }
    return null;
}

/// The set `ty` is, or null.
pub fn setOf(self: *Lowering, ty: TypeId) ?*Set {
    const name = self.open_set_by_type.get(ty) orelse return null;
    return self.open_sets.getPtr(name);
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
        if (!std.mem.eql(u8, existing, set_name)) {
            if (self.diagnostics) |d| {
                const id = d.addFmtId(.err, span, "'{s}' already joins the open set '{s}'", .{ sd.name, existing });
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
    if (missingMethod(self, set, variant)) |missing| {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': it has no '{s}'", .{ sd.name, set_name, missing });
            d.addHelpFmt(id, span, null, "every member declares every method the set requires; '{s}' is declared on '{s}'", .{ missing, set_name });
        }
        return;
    }

    for (set.members.items) |m| {
        if (m == variant) return;
    }
    set.members.append(self.alloc, variant) catch return;
    self.open_set_epoch += 1;
    self.open_variant_of.put(variant, set_name) catch {};
    recordDependencies(self, sd, variant, set_name, span);
    relayout(self, set);
}

/// Record that `set_name` has a GENERIC member declaration. The template has no
/// layout of its own; each instantiation the program spells is another member,
/// and the program is not finished spelling them — which is exactly what keeps
/// the set's layout open past the declaration pass.
pub fn noteGenericMember(self: *Lowering, set_name: []const u8) void {
    self.open_set_generic_members.put(set_name, {}) catch {};
}

/// Can a generic member still be instantiated into `set`?
fn mayGrowGenerically(self: *Lowering, set: TypeId) bool {
    const name = self.open_set_by_type.get(set) orelse return false;
    return self.open_set_generic_members.contains(name);
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

/// The first required method `variant` does not declare, or null. A generic
/// member's methods hang off its instance author, so both lookups are asked —
/// the requirement is on the member, however it was declared.
fn missingMethod(self: *Lowering, set: *const Set, variant: TypeId) ?[]const u8 {
    const inst = self.getStructTypeName(variant);
    for (set.decl.methods) |m| {
        if (m.default_body != null) continue;
        if (self.plainStructMethod(variant, m.name) != null) continue;
        if (inst) |name| {
            if (self.genericInstanceMethod(name, m.name) != null) continue;
        }
        return m.name;
    }
    return null;
}

/// Record every OTHER set this member holds by value. Those edges are what makes
/// growth transitive: a member of `R` holding a `Q` grows when `Q` grows, so `R`
/// has to be laid out again — and re-checked, since the member may no longer fit.
fn recordDependencies(
    self: *Lowering,
    sd: *const ast.StructDecl,
    variant: TypeId,
    set_name: []const u8,
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
                .set_name = set_name,
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
        const owner = self.open_sets.getPtr(dep.set_name) orelse continue;
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
            const owner = self.open_sets.getPtr(dep.set_name) orelse continue;
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
        emitTypeIdTable(self, set);
    }
    publish(self);
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

/// The set's `tag → member Type` table: what a raw view, a type switch, and the
/// `any` bridge read to recover the active member's type from a slot's tag word.
/// One row per member, in tag order; a memberless set still gets its one zero row
/// so the symbol exists.
fn emitTypeIdTable(self: *Lowering, set: *Set) void {
    const members = set.members.items;
    const rows = self.alloc.alloc(inst_mod.ConstantValue, @max(members.len, 1)) catch return;
    rows[0] = .{ .int = 0 };
    for (members, 0..) |member, i| rows[i] = .{ .int = @intCast(member.index()) };
    const name = std.fmt.allocPrint(self.alloc, "__sx_set_{s}_type_ids", .{tableName(self, set)}) catch return;
    const gid = self.module.addGlobal(.{
        .name = self.module.types.internString(name),
        .ty = self.module.types.arrayOf(.type_value, @intCast(@max(members.len, 1))),
        .init_val = .{ .aggregate = rows },
        .is_const = true,
    });
    self.open_set_tables.put(set.ty, gid) catch {};
}

/// The set's name, sanitized for a symbol.
fn tableName(self: *Lowering, set: *const Set) []const u8 {
    const out = self.alloc.dupe(u8, set.decl.name) catch return "set";
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
    if (self.open_set_by_type.get(measured)) |name| return name;
    var seen = std.AutoHashMap(TypeId, void).init(self.alloc);
    defer seen.deinit();
    collectSetsByValue(self, measured, &seen, 0);
    var best: ?[]const u8 = null;
    var it = seen.keyIterator();
    while (it.next()) |k| {
        const name = self.open_set_by_type.get(k.*) orelse continue;
        if (best == null or std.mem.order(u8, name, best.?) == .lt) best = name;
    }
    return best;
}
