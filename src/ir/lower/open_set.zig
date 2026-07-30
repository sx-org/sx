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
//!     payload_alignment = the DECLARED align                    (not a max)
//!     payload_offset    = align_up(size_of(tag), payload_alignment)
//!     size_of(P)        = align_up(payload_offset + payload_size, payload_alignment)
//!
//! `max` is a ceiling, not a reservation: a set whose largest member is small is
//! small. Every member is checked against `max` and `align` AT ITS DECLARATION,
//! so an oversize or over-aligned type cannot be a member at all — there is no
//! conversion-time size check, and no silent spill to heap.

const std = @import("std");
const ast = @import("../../ast.zig");
const Node = ast.Node;
const types = @import("../types.zig");

const TypeId = types.TypeId;

const program_index = @import("../program_index.zig");
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

/// One declared set, as its declaration states it.
pub const Set = struct {
    decl: *const ast.OpenSetDecl,
    /// The interned set type.
    ty: TypeId,
    max: u32,
    alignment: u32,
    span: ast.Span,
    source_file: ?[]const u8,
    /// Members, in declaration order — which is tag order.
    members: std.ArrayList(TypeId) = .empty,
};

/// Register `P :: @OpenSet(.{ … }) { … }`: read the options, intern the type with
/// an empty member set, and record it. Members register themselves later, and the
/// layout is recomputed as each arrives.
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
        .backing_type = backingType(self, 0, options.alignment),
    } }, self.shadowNominalId(name_id));
    table.type_decl_tids.put(@ptrCast(decl), ty) catch {};
    self.open_sets.put(decl.name, .{
        .decl = decl,
        .ty = ty,
        .max = options.max,
        .alignment = options.alignment,
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

    const size = self.module.types.typeSizeBytes(variant);
    const alignment = self.module.types.typeAlignBytes(variant);
    if (size > set.max) {
        reportOversize(self, sd, set, variant, size, span);
        return;
    }
    if (alignment > set.alignment) {
        if (self.diagnostics) |d| {
            const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': it needs {d}-byte alignment, and the set's payload alignment is {d}", .{ sd.name, set_name, alignment, set.alignment });
            d.addHelpFmt(id, span, null, "raise 'align' on the '{s}' declaration — every storage path for it must honour that alignment — or drop the over-aligned field", .{set_name});
        }
        return;
    }
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
    self.open_variant_of.put(variant, set_name) catch {};
    relayout(self, set);
}

fn reportOversize(
    self: *Lowering,
    sd: *const ast.StructDecl,
    set: *const Set,
    variant: TypeId,
    size: usize,
    span: ast.Span,
) void {
    const d = self.diagnostics orelse return;
    const id = d.addFmtId(.err, span, "'{s}' cannot be a member of '{s}': it is {d} bytes, and the set's payload ceiling is {d}", .{ sd.name, self.module.types.getString(self.module.types.get(set.ty).tagged_union.name), size, set.max });
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

/// Recompute the set's layout from its current members and re-intern the backing
/// shape. Called as each member is admitted: the payload is the largest member so
/// far, which is why a later, larger member grows `size_of(P)`.
pub fn relayout(self: *Lowering, set: *Set) void {
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

/// The explicit backing shape the layout is stated with: `{ tag: i64, payload:
/// [payload_size]u8 }`, padded so the payload starts on the declared alignment.
/// Handing the backend a written-down shape is what keeps set layout out of the
/// backend entirely.
fn backingType(self: *Lowering, payload_size: u32, alignment: u32) TypeId {
    const table = &self.module.types;
    const tag_size: u32 = @intCast(table.typeSizeBytes(tag_type));
    const payload_offset = alignUp(tag_size, alignment);
    const pad = payload_offset - tag_size;
    var fields = std.ArrayList(types.TypeInfo.StructInfo.Field).empty;
    fields.append(self.alloc, .{ .name = table.internString(tag_field), .ty = tag_type }) catch return tag_type;
    if (pad > 0) {
        fields.append(self.alloc, .{
            .name = table.internString("__pad"),
            .ty = table.arrayOf(.u8, pad),
        }) catch return tag_type;
    }
    fields.append(self.alloc, .{
        .name = table.internString(payload_field),
        .ty = table.arrayOf(.u8, alignUp(payload_size, alignment)),
    }) catch return tag_type;
    return table.internAnonStruct(self.alloc.dupe(types.TypeInfo.StructInfo.Field, fields.items) catch return tag_type);
}

fn alignUp(value: u32, alignment: u32) u32 {
    if (alignment == 0) return value;
    return (value + alignment - 1) & ~(alignment - 1);
}
