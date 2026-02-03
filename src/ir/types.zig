const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");

// ── TypeId ──────────────────────────────────────────────────────────────
// Opaque handle into the TypeTable. First 16 slots are reserved for builtins.

pub const TypeId = enum(u32) {
    // Builtin slots 0–17.
    /// Resolution failed (e.g. an unannotated param whose type was never
    /// inferred from context). A dedicated sentinel — never a legitimate
    /// result — so downstream `== .void`/`== .i64` checks can't silently
    /// swallow it. Must never reach codegen; sizeOf/toLLVMType panic on it.
    ///
    /// Deliberately slot 0: a zero-initialised or forgotten `TypeId` (the most
    /// common accidental value) thus reads as `.unresolved` and trips the
    /// tripwire, rather than silently masquerading as `.void`.
    unresolved = 0,
    bool = 1,
    i8 = 2,
    i16 = 3,
    i32 = 4,
    i64 = 5,
    u8 = 6,
    u16 = 7,
    u32 = 8,
    u64 = 9,
    f32 = 10,
    f64 = 11,
    string = 12, // [:0]u8
    any = 13,
    noreturn = 14,
    isize = 15,
    usize = 16,
    void = 17,
    cstring = 18, // thin null-terminated char* (see TypeInfo.cstring)
    /// A comptime `Type` VALUE — an 8-byte handle (a `TypeId` stored in a word),
    /// DISTINCT from `.any`. A `Type` value is the reified type itself
    /// (`reflect`/`const_type`/the comptime compiler-API), not a boxed Any. It used
    /// to share `.any`'s slot, but `.any` is a 16-byte `{tag,value}` box (variadic
    /// any), so a `Type` stored in an aggregate was sized 16B while the value is 8B
    /// — which blocked the comptime VM. Its own slot fixes the size and
    /// keeps every downstream `== .any`/`switch` check from conflating the two.
    type_value = 19,
    _, // user-defined types start at `first_user` (slots 20–99 reserved for future builtins)

    /// User-defined types start here. Builtins occupy 0–18 (plus `type_value` at
    /// 19); slots 20–99 are RESERVED headroom so adding a new builtin doesn't
    /// renumber every user type (which would churn every `sx ir` snapshot in the
    /// corpus). The `TypeTable` pads its `infos` array out to this index with the
    /// `unresolved` tripwire so an accidental reference to a reserved slot panics
    /// rather than silently aliasing a real type.
    pub const first_user: u32 = 100;

    pub fn index(self: TypeId) u32 {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: u32) TypeId {
        return @enumFromInt(i);
    }

    pub fn isBuiltin(self: TypeId) bool {
        return self.index() < first_user;
    }
};

// ── TypeInfo ────────────────────────────────────────────────────────────
// Resolved type information stored in the TypeTable.
// Unlike the AST-level `types.Type` which uses string names for references,
// TypeInfo uses TypeId handles, making it fully resolved and internable.

pub const TypeInfo = union(enum) {
    signed: u8, // bit width: 1–64
    unsigned: u8,
    f32,
    f64,
    void,
    bool,
    string, // [:0]u8 — fat pointer {ptr, len}
    cstring, // thin null-terminated char* — ONE pointer, length implicit (strlen)

    @"struct": StructInfo,
    @"enum": EnumInfo,
    @"union": UnionInfo,
    tagged_union: TaggedUnionInfo,
    array: ArrayInfo,
    slice: SliceInfo,
    pointer: PointerInfo,
    many_pointer: ManyPointerInfo,
    vector: VectorInfo,
    function: FunctionInfo,
    closure: ClosureInfo,
    optional: OptionalInfo,
    tuple: TupleInfo,
    pack: PackInfo,
    any,
    protocol: ProtocolInfo,
    error_set: ErrorSetInfo,
    noreturn,
    usize,
    isize,
    /// A comptime `Type` VALUE (see `TypeId.type_value`): an 8-byte type handle,
    /// distinct from the 16-byte boxed `any`.
    type_value,
    /// Resolution-failure sentinel (see `TypeId.unresolved`).
    unresolved,

    pub const StructInfo = struct {
        name: StringId,
        fields: []const Field,
        // True iff this struct backs a protocol value (registered via
        // `registerProtocolDecl`). Used by the optional code path: a
        // `?Protocol` is sentinel-shaped (the protocol struct itself,
        // null ctx == none) rather than the standard `{T, i1}` discriminated
        // layout — matching how `?Closure` works.
        is_protocol: bool = false,
        // Stable nominal identity, assigned once per decl pointer. Folds into
        // the intern key so two same-display-name authors get distinct TypeIds.
        // `0` == structural: the type is keyed by display name alone (legacy).
        nominal_id: u32 = 0,

        pub const Field = struct {
            name: StringId,
            ty: TypeId,
        };
    };

    pub const EnumInfo = struct {
        name: StringId,
        variants: []const StringId,
        is_flags: bool = false,
        explicit_values: ?[]const i64 = null, // for flags (power-of-2) or custom values
        backing_type: ?TypeId = null, // e.g. u32 for `enum u32 { ... }`
        nominal_id: u32 = 0, // stable nominal identity; 0 == structural (legacy)
    };

    pub const UnionInfo = struct {
        name: StringId,
        fields: []const StructInfo.Field,
        nominal_id: u32 = 0, // stable nominal identity; 0 == structural (legacy)
    };

    pub const TaggedUnionInfo = struct {
        name: StringId,
        fields: []const StructInfo.Field,
        tag_type: TypeId, // tag integer type (e.g. .u32, .i64)
        backing_type: ?TypeId = null, // enum struct backing (e.g. { tag: u32; _: u32; payload: [30]u32; })
        explicit_tag_values: ?[]const i64 = null, // explicit variant values (e.g., quit :: 0x100)
        nominal_id: u32 = 0, // stable nominal identity; 0 == structural (legacy)
        // True for every real construction (normal unions, error sets, and a
        // `register_type`/`define` completion). False ONLY for a `declare(...)`
        // forward PLACEHOLDER that has not yet been completed — a 0-field
        // tagged_union that is indistinguishable from an explicitly-defined
        // empty union by field count alone. `checkComptimeTypeResult` rejects
        // `defined == false` (declared but never defined) while accepting a
        // legitimately-empty `defined == true` union.
        defined: bool = true,
    };

    pub const ArrayInfo = struct {
        element: TypeId,
        length: u32,
    };

    pub const SliceInfo = struct {
        element: TypeId,
    };

    pub const PointerInfo = struct {
        pointee: TypeId,
    };

    pub const ManyPointerInfo = struct {
        element: TypeId,
    };

    pub const VectorInfo = struct {
        element: TypeId,
        length: u32,
    };

    pub const FunctionInfo = struct {
        params: []const TypeId,
        ret: TypeId,
        call_conv: CallConv = .default,
        /// Pack-variadic shape marker. When set, the signature represents a
        /// heterogeneous type pack: `params` is the fixed prefix, and a
        /// per-call-site type list binds the remainder. `pack_start == 0`
        /// with `params.len == 0` denotes `fn(..$args)`.
        pack_start: ?u32 = null,
    };

    pub const CallConv = enum { default, c };

    pub const ClosureInfo = struct {
        params: []const TypeId,
        ret: TypeId,
        /// Pack-variadic shape marker — same semantics as FunctionInfo.
        /// `Closure(..$args) -> $R` => params = [], pack_start = 0.
        pack_start: ?u32 = null,
    };

    pub const OptionalInfo = struct {
        child: TypeId,
    };

    pub const TupleInfo = struct {
        fields: []const TypeId,
        names: ?[]const StringId,
    };

    /// A heterogeneous variadic pack as a first-class type-system value: an
    /// ordered sequence of per-position element types. Comptime-only — a pack
    /// lowers to flat positional args before codegen and has NO runtime layout
    /// (sizeOf panics). `elements.len == 0` is a valid empty pack.
    pub const PackInfo = struct {
        elements: []const TypeId,
    };

    pub const ProtocolInfo = struct {
        name: StringId,
        methods: []const Method,

        pub const Method = struct {
            name: StringId,
            sig: TypeId, // function type
        };
    };

    /// A declared error set `Foo :: error { A, B }`. `tags` are GLOBAL tag
    /// ids from the TypeTable's `TagRegistry` (sorted, canonical). Identity is
    /// the `name` (like an enum). Runtime layout is u32 — the error channel's
    /// tag value; id 0 is reserved for "no error".
    pub const ErrorSetInfo = struct {
        name: StringId,
        tags: []const u32, // sorted global tag ids
        nominal_id: u32 = 0, // stable nominal identity; 0 == structural (legacy)
    };
};

// ── StringId ────────────────────────────────────────────────────────────

pub const StringId = enum(u32) {
    empty = 0,
    _,

    pub fn index(self: StringId) u32 {
        return @intFromEnum(self);
    }
};

// ── StringPool ──────────────────────────────────────────────────────────
// Intern strings for type/field/variant names. Deduplicates by content.

pub const StringPool = struct {
    /// Maps string content → StringId for dedup. Keys point to owned allocations in `strings`.
    map: std.StringHashMap(StringId),
    /// Owned string data indexed by StringId. Each entry is separately heap-allocated.
    strings: std.ArrayList([]const u8),
    next_id: u32,

    pub fn init(alloc: Allocator) StringPool {
        var pool = StringPool{
            .map = std.StringHashMap(StringId).init(alloc),
            .strings = std.ArrayList([]const u8).empty,
            .next_id = 1, // 0 is reserved for empty
        };
        // Slot 0 = empty string (not heap-allocated)
        pool.strings.append(alloc, "") catch unreachable;
        return pool;
    }

    pub fn deinit(self: *StringPool, alloc: Allocator) void {
        // Free heap-allocated strings (skip slot 0 which is a string literal)
        for (self.strings.items[1..]) |s| {
            alloc.free(@constCast(s));
        }
        self.strings.deinit(alloc);
        self.map.deinit();
    }

    pub fn intern(self: *StringPool, alloc: Allocator, str: []const u8) StringId {
        if (str.len == 0) return .empty;
        if (self.map.get(str)) |id| return id;

        const id: StringId = @enumFromInt(self.next_id);
        self.next_id += 1;

        // Allocate a stable copy — used as both map key and lookup value
        const owned = alloc.dupe(u8, str) catch unreachable;
        self.strings.append(alloc, owned) catch unreachable;
        self.map.put(owned, id) catch unreachable;

        return id;
    }

    pub fn get(self: *const StringPool, id: StringId) []const u8 {
        const idx = id.index();
        if (idx >= self.strings.items.len) return "";
        return self.strings.items[idx];
    }
};

// ── TagRegistry ─────────────────────────────────────────────────────────
// Global error-tag pool: tag name → u32 id, monotonic, id 0 reserved for
// "no error". Tag identity is the name, program-wide — two declared sets that
// list the same tag share its id (the design's global-flat tag identity). A
// separate namespace from StringPool so tag ids stay dense (compact id→name
// table for `{}` interpolation + traces).

pub const TagRegistry = struct {
    /// tag name → id. Keys point to owned allocations in `names`.
    map: std.StringHashMap(u32),
    /// id → tag name. Index 0 is the reserved "" (no-error) slot.
    names: std.ArrayList([]const u8),
    next_id: u32,

    pub fn init(alloc: Allocator) TagRegistry {
        var reg = TagRegistry{
            .map = std.StringHashMap(u32).init(alloc),
            .names = std.ArrayList([]const u8).empty,
            .next_id = 1, // 0 reserved for "no error"
        };
        reg.names.append(alloc, "") catch unreachable; // slot 0
        return reg;
    }

    pub fn deinit(self: *TagRegistry, alloc: Allocator) void {
        for (self.names.items[1..]) |n| alloc.free(@constCast(n));
        self.names.deinit(alloc);
        self.map.deinit();
    }

    pub fn intern(self: *TagRegistry, alloc: Allocator, name: []const u8) u32 {
        if (self.map.get(name)) |id| return id;
        const id = self.next_id;
        self.next_id += 1;
        const owned = alloc.dupe(u8, name) catch unreachable;
        self.names.append(alloc, owned) catch unreachable;
        self.map.put(owned, id) catch unreachable;
        return id;
    }

    pub fn getName(self: *const TagRegistry, id: u32) []const u8 {
        if (id >= self.names.items.len) return "";
        return self.names.items[id];
    }
};

// ── TypeTable ───────────────────────────────────────────────────────────
// Holds all resolved types. Builtins in slots 0–15, user types interned from 16+.

pub const TypeTable = struct {
    infos: std.ArrayList(TypeInfo),
    strings: StringPool,
    /// Global error-tag pool (string → u32 id). Populated as `error { ... }`
    /// sets are registered; queried when lowering `error.X` value expressions.
    tags: TagRegistry,
    /// Maps TypeInfo → TypeId for dedup of structural types
    intern_map: std.HashMap(TypeKey, TypeId, TypeKeyContext, 80),
    /// Stable nominal identity: the declaring decl's pointer → its TypeId. The
    /// `fn_decl_fids` analogue — one entry per declaring decl, so two
    /// same-display-name declarations resolve to distinct TypeIds via their own
    /// decl pointer. Keyed by the opaque `RawDeclRef` inner pointer (e.g.
    /// `*const ast.StructDecl`) — the SAME pointer the import raw-facts hold and
    /// `registerStructDecl` receives, so registration and resolution agree on
    /// identity without threading the wrapping `ast.Node`. Populated by the
    /// resolver (E2) as it assigns nominal ids.
    type_decl_tids: std.AutoHashMap(*const anyopaque, TypeId),
    /// Anonymous-struct-literal identity: canonical (field-name, field-type)
    /// shape → TypeId. The nominal intern map keys structs by DISPLAY NAME,
    /// and every anonymous literal displays as `__anon` — shape keying here
    /// is what makes `.{x = 1}` at two sites one type while `.{x = 1}` and
    /// `.{1, 2}` stay distinct. Entries are appended to `infos` directly and
    /// deliberately NOT added to the name-keyed intern map.
    anon_struct_map: std.StringHashMap(TypeId),
    alloc: Allocator,
    /// Owns the element/param slices duped by the type constructors
    /// (`functionType*`, `closureType*`, `packType`). Freed wholesale in
    /// `deinit` — these slices live as long as the table, so an arena avoids
    /// per-slice bookkeeping and the owned-vs-borrowed ambiguity that blocks
    /// freeing them individually.
    slice_arena: std.heap.ArenaAllocator,
    /// Target pointer size in bytes (4 for wasm32, 8 for 64-bit targets).
    pointer_size: u8 = 8,

    pub fn init(alloc: Allocator) TypeTable {
        var table = TypeTable{
            .infos = std.ArrayList(TypeInfo).empty,
            .strings = StringPool.init(alloc),
            .tags = TagRegistry.init(alloc),
            .intern_map = std.HashMap(TypeKey, TypeId, TypeKeyContext, 80).init(alloc),
            .type_decl_tids = std.AutoHashMap(*const anyopaque, TypeId).init(alloc),
            .anon_struct_map = std.StringHashMap(TypeId).init(alloc),
            .alloc = alloc,
            .slice_arena = std.heap.ArenaAllocator.init(alloc),
        };

        // Pre-populate builtin slots 0–17 (must match TypeId enum order)
        const builtins = [_]TypeInfo{
            .unresolved, // 0: resolution-failure sentinel
            .bool, // 1
            .{ .signed = 8 }, // 2: i8
            .{ .signed = 16 }, // 3: i16
            .{ .signed = 32 }, // 4: i32
            .{ .signed = 64 }, // 5: i64
            .{ .unsigned = 8 }, // 6: u8
            .{ .unsigned = 16 }, // 7: u16
            .{ .unsigned = 32 }, // 8: u32
            .{ .unsigned = 64 }, // 9: u64
            .f32, // 10
            .f64, // 11
            .string, // 12
            .any, // 13
            .noreturn, // 14
            .isize, // 15: isize (pointer-sized signed)
            .usize, // 16: usize (pointer-sized unsigned)
            .void, // 17
            .cstring, // 18: thin null-terminated char*
            .type_value, // 19: comptime `Type` value (8-byte handle, distinct from any)
        };
        for (&builtins) |info| {
            table.infos.append(alloc, info) catch unreachable;
        }
        // Pad the reserved builtin headroom (slots after the real builtins, up to
        // `first_user`) with the `unresolved` tripwire: these slots are never a
        // legitimate type, so any reference panics in `sizeOf`/`get` rather than
        // silently aliasing a user type. Reserving the range keeps user TypeIds
        // stable as new builtins are added (no snapshot churn).
        std.debug.assert(table.infos.items.len <= TypeId.first_user);
        while (table.infos.items.len < TypeId.first_user) {
            table.infos.append(alloc, .unresolved) catch unreachable;
        }

        return table;
    }

    pub fn deinit(self: *TypeTable) void {
        self.infos.deinit(self.alloc);
        self.strings.deinit(self.alloc);
        self.tags.deinit(self.alloc);
        self.intern_map.deinit();
        self.type_decl_tids.deinit();
        self.anon_struct_map.deinit();
        self.slice_arena.deinit();
    }

    /// Look up the TypeInfo for a given TypeId.
    pub fn get(self: *const TypeTable, id: TypeId) TypeInfo {
        return self.infos.items[id.index()];
    }

    /// Intern a TypeInfo, returning the existing TypeId if structurally equal.
    pub fn intern(self: *TypeTable, info: TypeInfo) TypeId {
        const key = TypeKey{ .info = info };
        if (self.intern_map.get(key)) |existing| {
            return existing;
        }
        const id = TypeId.fromIndex(@intCast(self.infos.items.len));
        self.infos.append(self.alloc, info) catch unreachable;
        self.intern_map.putNoClobber(key, id) catch unreachable;
        return id;
    }

    /// Intern an anonymous STRUCTURAL struct (an untyped `.{ … }` literal's
    /// synthesized type) by SHAPE — the canonical (field-name, field-type)
    /// sequence — not by display name. See `internAnonShape` for the identity
    /// rule. `fields` must outlive the table (callers dupe into a stable
    /// allocator, same contract as `intern`).
    pub fn internAnonStruct(self: *TypeTable, fields: []const TypeInfo.StructInfo.Field) TypeId {
        return self.internAnonShape(.{ .@"struct" = .{
            .name = self.internString("__anon"),
            .fields = fields,
        } });
    }

    /// Intern an anonymous (`__anon`) nominal TypeInfo by SHAPE, not by
    /// display name. The nominal intern map keys these kinds by name, and
    /// every anonymous decl displays as `__anon`, so routing them through
    /// `intern` would collapse differently-shaped anonymous types onto
    /// whichever shape interned first (the issue-0294 class — untyped `.{ }`
    /// literals, inline `struct { … }` / `union { … }` / `enum { … }`
    /// annotations). The entry is appended to `infos` directly and NOT added
    /// to the name-keyed map; `anon_struct_map` alone owns identity, so
    /// identical shapes at any two sites share a TypeId and distinct shapes
    /// never merge. Slices inside `info` must outlive the table (same
    /// contract as `intern`).
    pub fn internAnonShape(self: *TypeTable, info: TypeInfo) TypeId {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.alloc);
        key.append(self.alloc, @intFromEnum(std.meta.activeTag(info))) catch unreachable;
        // Optional components get a presence byte so "absent" can never
        // alias a value's raw bytes.
        switch (info) {
            .@"struct" => |s| {
                for (s.fields) |f| {
                    key.appendSlice(self.alloc, std.mem.asBytes(&f.name)) catch unreachable;
                    key.appendSlice(self.alloc, std.mem.asBytes(&f.ty)) catch unreachable;
                }
            },
            .@"union" => |u| {
                for (u.fields) |f| {
                    key.appendSlice(self.alloc, std.mem.asBytes(&f.name)) catch unreachable;
                    key.appendSlice(self.alloc, std.mem.asBytes(&f.ty)) catch unreachable;
                }
            },
            .tagged_union => |tu| {
                for (tu.fields) |f| {
                    key.appendSlice(self.alloc, std.mem.asBytes(&f.name)) catch unreachable;
                    key.appendSlice(self.alloc, std.mem.asBytes(&f.ty)) catch unreachable;
                }
                key.appendSlice(self.alloc, std.mem.asBytes(&tu.tag_type)) catch unreachable;
                key.append(self.alloc, if (tu.backing_type != null) 1 else 0) catch unreachable;
                if (tu.backing_type) |bt| key.appendSlice(self.alloc, std.mem.asBytes(&bt)) catch unreachable;
                key.append(self.alloc, if (tu.explicit_tag_values != null) 1 else 0) catch unreachable;
                if (tu.explicit_tag_values) |vals| for (vals) |v| {
                    key.appendSlice(self.alloc, std.mem.asBytes(&v)) catch unreachable;
                };
            },
            .@"enum" => |e| {
                for (e.variants) |v| key.appendSlice(self.alloc, std.mem.asBytes(&v)) catch unreachable;
                key.append(self.alloc, if (e.is_flags) 1 else 0) catch unreachable;
                key.append(self.alloc, if (e.backing_type != null) 1 else 0) catch unreachable;
                if (e.backing_type) |bt| key.appendSlice(self.alloc, std.mem.asBytes(&bt)) catch unreachable;
                key.append(self.alloc, if (e.explicit_values != null) 1 else 0) catch unreachable;
                if (e.explicit_values) |vals| for (vals) |v| {
                    key.appendSlice(self.alloc, std.mem.asBytes(&v)) catch unreachable;
                };
            },
            // Only anonymous nominal shapes route here; a non-nominal info
            // is a caller bug.
            else => unreachable,
        }
        if (self.anon_struct_map.get(key.items)) |existing| return existing;
        const id = TypeId.fromIndex(@intCast(self.infos.items.len));
        self.infos.append(self.alloc, info) catch unreachable;
        const owned_key = self.alloc.dupe(u8, key.items) catch unreachable;
        self.anon_struct_map.put(owned_key, id) catch unreachable;
        return id;
    }

    /// Intern a nominal type (struct/enum/union/tagged_union/error_set) under a
    /// stable nominal identity. `nominal_id` folds into the intern key so two
    /// authors that share a display name still get distinct TypeIds. With
    /// `nominal_id == 0` this is byte-identical to `intern` (structural keying),
    /// which is the only id used until same-name shadows land. Passing a nonzero
    /// id for a non-nominal info is a caller bug (the id would be dropped).
    pub fn internNominal(self: *TypeTable, info: TypeInfo, nominal_id: u32) TypeId {
        var stamped = info;
        switch (stamped) {
            .@"struct" => |*s| s.nominal_id = nominal_id,
            .@"enum" => |*e| e.nominal_id = nominal_id,
            .@"union" => |*u| u.nominal_id = nominal_id,
            .tagged_union => |*u| u.nominal_id = nominal_id,
            .error_set => |*e| e.nominal_id = nominal_id,
            else => std.debug.assert(nominal_id == 0),
        }
        return self.intern(stamped);
    }

    /// Replace the TypeInfo for an existing TypeId WITHOUT changing its intern
    /// key. Used when a forward-declared type (struct with empty fields) gets
    /// its full definition later: the key is the display name + nominal id, and
    /// a field-fill touches neither. Asserts the key is unchanged so a real
    /// re-key can't sneak through this path (use `replaceKeyedInfo` for that).
    pub fn updatePreservingKey(self: *TypeTable, id: TypeId, info: TypeInfo) void {
        const idx = id.index();
        const old = self.infos.items[idx];
        std.debug.assert((TypeKeyContext{}).eql(.{ .info = old }, .{ .info = info }));
        self.infos.items[idx] = info;
    }

    /// Replace the TypeInfo for an existing TypeId AND re-key `intern_map` to
    /// match the new info. The one legitimate re-key is the anonymous-type
    /// rename (`__anon` → `Parent.field`), which mutates the display name and
    /// therefore the key. Removes the stale key and installs the new one so the
    /// renamed type interns and looks up under its new name only.
    pub fn replaceKeyedInfo(self: *TypeTable, id: TypeId, info: TypeInfo) void {
        const idx = id.index();
        const old = self.infos.items[idx];
        _ = self.intern_map.remove(.{ .info = old });
        self.infos.items[idx] = info;
        self.intern_map.put(.{ .info = info }, id) catch unreachable;
    }

    /// Find a named type (struct/union/enum) by its StringId name.
    /// Returns the TypeId if found, null otherwise.
    pub fn findByName(self: *const TypeTable, name: StringId) ?TypeId {
        for (self.infos.items, 0..) |info, i| {
            const n: ?StringId = switch (info) {
                .@"struct" => |s| s.name,
                .@"union" => |u| u.name,
                .tagged_union => |u| u.name,
                .@"enum" => |e| e.name,
                .error_set => |e| e.name,
                else => null,
            };
            if (n != null and n.? == name) return TypeId.fromIndex(@intCast(i));
        }
        return null;
    }

    /// Member count of an aggregate type: struct/union/tagged-union fields, enum
    /// variants, or array/vector length. Returns null for a type that has no
    /// member count (a scalar, pointer, the `unresolved` sentinel, …) — so a
    /// caller bails loudly rather than reading a silent 0. The comptime
    /// compiler-API reflection reader `type_field_count` rides on this (both the
    /// legacy `compiler_lib` handler and the comptime VM call it, so the two
    /// paths can never drift). Out-of-range ids return null, not a panic.
    pub fn memberCount(self: *const TypeTable, id: TypeId) ?i64 {
        if (id.index() >= self.infos.items.len) return null;
        return switch (self.get(id)) {
            .@"struct" => |s| @intCast(s.fields.len),
            .@"union" => |u| @intCast(u.fields.len),
            .tagged_union => |u| @intCast(u.fields.len),
            .@"enum" => |e| @intCast(e.variants.len),
            .tuple => |t| @intCast(t.fields.len),
            .array => |a| @intCast(a.length),
            .vector => |v| @intCast(v.length),
            else => null,
        };
    }

    /// Nominal name of a named type (struct / union / tagged-union / enum /
    /// error-set / protocol), or null for an unnamed type (scalar, pointer,
    /// slice, …) or an out-of-range id. Backs the `type_nominal_name` comptime
    /// compiler-API reader (legacy handler + VM both call it — no drift).
    /// (Distinct from `typeName` below, which renders a display string for any
    /// type; this returns the interned nominal-name handle for NAMED types only.)
    pub fn nominalName(self: *const TypeTable, id: TypeId) ?StringId {
        if (id.index() >= self.infos.items.len) return null;
        return switch (self.get(id)) {
            .@"struct" => |s| s.name,
            .@"union" => |u| u.name,
            .tagged_union => |u| u.name,
            .@"enum" => |e| e.name,
            .error_set => |e| e.name,
            .protocol => |p| p.name,
            else => null,
        };
    }

    /// Name of member `idx` of an aggregate: a struct/union/tagged-union field
    /// name, an enum variant name, or a named-tuple element name. Null for a
    /// negative / out-of-range `idx`, an unnamed tuple element, or a type with no
    /// named members. Backs the `type_field_name` reader.
    pub fn memberName(self: *const TypeTable, id: TypeId, idx: i64) ?StringId {
        if (idx < 0 or id.index() >= self.infos.items.len) return null;
        const i: usize = @intCast(idx);
        return switch (self.get(id)) {
            .@"struct" => |s| if (i < s.fields.len) s.fields[i].name else null,
            .@"union" => |u| if (i < u.fields.len) u.fields[i].name else null,
            .tagged_union => |u| if (i < u.fields.len) u.fields[i].name else null,
            .@"enum" => |e| if (i < e.variants.len) e.variants[i] else null,
            .tuple => |t| if (t.names) |ns| (if (i < ns.len) ns[i] else null) else null,
            else => null,
        };
    }

    /// Type of member `idx` of an aggregate: a struct/union/tagged-union field
    /// type, a tuple element type, an array/vector element type, a slice's
    /// element (row 0 — the static length doesn't exist), or an optional's
    /// child (row 0). Null for a negative / out-of-range `idx` or a type with
    /// no member types (e.g. a payloadless enum). Backs the `type_field_type`
    /// reader.
    pub fn memberType(self: *const TypeTable, id: TypeId, idx: i64) ?TypeId {
        if (idx < 0 or id.index() >= self.infos.items.len) return null;
        const i: usize = @intCast(idx);
        return switch (self.get(id)) {
            .@"struct" => |s| if (i < s.fields.len) s.fields[i].ty else null,
            .@"union" => |u| if (i < u.fields.len) u.fields[i].ty else null,
            .tagged_union => |u| if (i < u.fields.len) u.fields[i].ty else null,
            .tuple => |t| if (i < t.fields.len) t.fields[i] else null,
            .array => |a| if (i < a.length) a.element else null,
            .vector => |v| if (i < v.length) v.element else null,
            .slice => |sl| if (i == 0) sl.element else null,
            .optional => |o| if (i == 0) o.child else null,
            else => null,
        };
    }

    /// Row count of the runtime member tables for `id` — `memberCount` where
    /// a count exists, plus ONE row for the kinds that answer a member TYPE
    /// without a static count (slice element / optional child at row 0).
    /// Null → the type gets a null master-table slot. Every runtime member
    /// table (names / types / offsets) and the GEP sizing on its readers
    /// derive from THIS, so a kind that answers `memberType` can never meet
    /// a null or short row (issue 0300: runtime slice tags dereferenced a
    /// null row).
    pub fn memberTableLen(self: *const TypeTable, id: TypeId) ?i64 {
        if (self.memberCount(id)) |n| return n;
        if (self.memberType(id, 0) != null) return 1;
        return null;
    }

    /// Byte offset of member `idx` inside a value of type `id` — the single
    /// source of truth behind `struct_field_offset` (static fold, the runtime
    /// `__sx_field_offset_ptrs` tables, and the VM's `rt_field_offset`), so
    /// the three can never drift. Struct/tuple members use the same aligned
    /// walk `typeSizeBytes` lays out. A tagged union answers its PAYLOAD
    /// offset (the header size — identical for every variant); an untagged
    /// union's arms all overlay at 0. Null for a type without addressable
    /// members or an out-of-range `idx`.
    pub fn memberOffsetBytes(self: *const TypeTable, id: TypeId, idx: i64) ?usize {
        if (idx < 0 or id.index() >= self.infos.items.len or id.isBuiltin()) return null;
        const i: usize = @intCast(idx);
        switch (self.get(id)) {
            .@"struct" => |s| {
                if (i >= s.fields.len) return null;
                var off: usize = 0;
                for (s.fields[0 .. i + 1], 0..) |f, m| {
                    off = std.mem.alignForward(usize, off, self.typeAlignBytes(f.ty));
                    if (m == i) return off;
                    off += self.typeSizeBytes(f.ty);
                }
                unreachable;
            },
            .tuple => |t| {
                if (i >= t.fields.len) return null;
                var off: usize = 0;
                for (t.fields[0 .. i + 1], 0..) |fty, m| {
                    off = std.mem.alignForward(usize, off, self.typeAlignBytes(fty));
                    if (m == i) return off;
                    off += self.typeSizeBytes(fty);
                }
                unreachable;
            },
            .@"union" => |u| return if (i < u.fields.len) 0 else null,
            .tagged_union => |u| {
                if (i >= u.fields.len) return null;
                // Payload area starts after the header. Mirrors the LLVM type
                // (backend/llvm/types.zig): header = tag, or — for a
                // backing-type union — every backing field except the last.
                if (u.backing_type) |bt| {
                    const bi = self.get(bt);
                    if (bi == .@"struct" and bi.@"struct".fields.len > 1) {
                        var header: usize = 0;
                        const bfields = bi.@"struct".fields;
                        for (bfields[0 .. bfields.len - 1]) |bf| {
                            header += self.typeSizeBytes(bf.ty);
                        }
                        return header;
                    }
                }
                return self.typeSizeBytes(u.tag_type);
            },
            else => return null,
        }
    }

    /// Stable kind discriminant of a type, for comptime reflection branching.
    /// TOTAL (never fails): an unnamed / non-aggregate type or an out-of-range id
    /// is `other` (0). Codes are compiler-owned and stable — NOT tied to any sx
    /// enum's declaration order; the sx side maps them. Backs the `type_kind`
    /// reader. (A `tagged_union` is a payload-carrying enum; the sx metatype folds
    /// codes 2 and 3 onto its single `.enum` TypeInfo variant.)
    ///   0 other · 1 struct · 2 enum · 3 tagged_union · 4 tuple
    ///   5 union · 6 array · 7 vector · 8 error_set
    pub fn kindCode(self: *const TypeTable, id: TypeId) i64 {
        if (id.index() >= self.infos.items.len) return 0;
        return switch (self.get(id)) {
            .@"struct" => 1,
            .@"enum" => 2,
            .tagged_union => 3,
            .tuple => 4,
            .@"union" => 5,
            .array => 6,
            .vector => 7,
            .error_set => 8,
            else => 0,
        };
    }

    /// Integer value of variant `idx`: its explicit value when the enum /
    /// tagged union declares one (custom values, flags, explicit tags), else
    /// its ordinal. Null for a non-variant type, a negative / out-of-range
    /// `idx`, or an out-of-range id. The single value source behind
    /// `variant_value` (static fold, the runtime `__sx_member_value_ptrs`
    /// tables, and the VM's `rt_variant_value`), so the three can never
    /// drift. Backs the `type_field_value` reader too.
    pub fn memberValue(self: *const TypeTable, id: TypeId, idx: i64) ?i64 {
        if (idx < 0 or id.index() >= self.infos.items.len) return null;
        const i: usize = @intCast(idx);
        return switch (self.get(id)) {
            .@"enum" => |e| blk: {
                if (i >= e.variants.len) break :blk null;
                if (e.explicit_values) |vals| if (i < vals.len) break :blk vals[i];
                break :blk @intCast(i); // ordinal default
            },
            .tagged_union => |u| blk: {
                if (i >= u.fields.len) break :blk null;
                if (u.explicit_tag_values) |vals| if (i < vals.len) break :blk vals[i];
                break :blk @intCast(i); // ordinal default
            },
            else => null,
        };
    }

    /// The byte width of the tag word a runtime variant read must load from a
    /// value of type `id`, SIGN-ENCODED: positive = zero-extend, negative =
    /// |width| bytes, sign-extend (a signed backing / tag type, so small
    /// negative explicit values round-trip). A payload-less enum's whole
    /// value IS its tag (backing size, default 8); a tagged union's tag is
    /// the LOW size_of(tag_type) bytes at offset 0 (a backing-type union's
    /// header can be wider than the tag — the width must come from the tag
    /// type, never the header). 0 for a non-variant kind. Feeds the
    /// `__sx_variant_tag_widths` runtime table and its static fold.
    pub fn variantTagWidth(self: *const TypeTable, id: TypeId) i64 {
        if (id.index() >= self.infos.items.len or id.isBuiltin()) return 0;
        const tag_ty: TypeId = switch (self.get(id)) {
            .@"enum" => |e| e.backing_type orelse .i64,
            .tagged_union => |u| u.tag_type,
            else => return 0,
        };
        const w: i64 = @intCast(self.typeSizeBytes(tag_ty));
        return if (self.isUnsignedInt(tag_ty)) w else -w;
    }

    /// Source-sensitive variant of `findByName`: asserts at most one named type
    /// matches, then returns it (or null). Quarantines the global first-match
    /// scan — new resolver code that must not silently pick a first-of-many
    /// author uses this so a same-name collision trips the assert instead of
    /// resolving arbitrarily.
    pub fn findUniqueByName(self: *const TypeTable, name: StringId) ?TypeId {
        var found: ?TypeId = null;
        for (self.infos.items, 0..) |info, i| {
            const n: ?StringId = switch (info) {
                .@"struct" => |s| s.name,
                .@"union" => |u| u.name,
                .tagged_union => |u| u.name,
                .@"enum" => |e| e.name,
                .error_set => |e| e.name,
                else => null,
            };
            if (n != null and n.? == name) {
                std.debug.assert(found == null);
                found = TypeId.fromIndex(@intCast(i));
            }
        }
        return found;
    }

    // ── Convenience constructors ────────────────────────────────────────

    pub fn ptrTo(self: *TypeTable, pointee: TypeId) TypeId {
        return self.intern(.{ .pointer = .{ .pointee = pointee } });
    }

    pub fn manyPtrTo(self: *TypeTable, element: TypeId) TypeId {
        return self.intern(.{ .many_pointer = .{ .element = element } });
    }

    pub fn sliceOf(self: *TypeTable, element: TypeId) TypeId {
        return self.intern(.{ .slice = .{ .element = element } });
    }

    pub fn arrayOf(self: *TypeTable, element: TypeId, length: u32) TypeId {
        return self.intern(.{ .array = .{ .element = element, .length = length } });
    }

    pub fn optionalOf(self: *TypeTable, child: TypeId) TypeId {
        return self.intern(.{ .optional = .{ .child = child } });
    }

    pub fn functionType(self: *TypeTable, params: []const TypeId, ret: TypeId) TypeId {
        return self.functionTypeCC(params, ret, .default);
    }

    pub fn functionTypeCC(self: *TypeTable, params: []const TypeId, ret: TypeId, cc: TypeInfo.CallConv) TypeId {
        const owned_params = self.slice_arena.allocator().dupe(TypeId, params) catch unreachable;
        return self.intern(.{ .function = .{ .params = owned_params, .ret = ret, .call_conv = cc } });
    }

    pub fn functionTypePack(self: *TypeTable, params: []const TypeId, ret: TypeId, cc: TypeInfo.CallConv, pack_start: u32) TypeId {
        const owned_params = self.slice_arena.allocator().dupe(TypeId, params) catch unreachable;
        return self.intern(.{ .function = .{ .params = owned_params, .ret = ret, .call_conv = cc, .pack_start = pack_start } });
    }

    pub fn closureType(self: *TypeTable, params: []const TypeId, ret: TypeId) TypeId {
        const owned_params = self.slice_arena.allocator().dupe(TypeId, params) catch unreachable;
        return self.intern(.{ .closure = .{ .params = owned_params, .ret = ret } });
    }

    pub fn closureTypePack(self: *TypeTable, params: []const TypeId, ret: TypeId, pack_start: u32) TypeId {
        const owned_params = self.slice_arena.allocator().dupe(TypeId, params) catch unreachable;
        return self.intern(.{ .closure = .{ .params = owned_params, .ret = ret, .pack_start = pack_start } });
    }

    pub fn vectorOf(self: *TypeTable, element: TypeId, length: u32) TypeId {
        return self.intern(.{ .vector = .{ .element = element, .length = length } });
    }

    /// Construct (and intern) a heterogeneous pack type from an ordered
    /// element-type list. `elements.len == 0` yields the empty pack.
    pub fn packType(self: *TypeTable, elements: []const TypeId) TypeId {
        const owned = self.slice_arena.allocator().dupe(TypeId, elements) catch unreachable;
        return self.intern(.{ .pack = .{ .elements = owned } });
    }

    /// Intern an error-tag name into the global tag pool, returning its id.
    pub fn internTag(self: *TypeTable, name: []const u8) u32 {
        return self.tags.intern(self.alloc, name);
    }

    /// Look up a tag name from its global id.
    pub fn getTagName(self: *const TypeTable, id: u32) []const u8 {
        return self.tags.getName(id);
    }

    /// Construct (and intern) a named error-set type. `tag_ids` are global tag
    /// ids (from `internTag`); they are sorted here for canonical storage.
    pub fn errorSetType(self: *TypeTable, name: StringId, tag_ids: []const u32) TypeId {
        const owned = self.slice_arena.allocator().dupe(u32, tag_ids) catch unreachable;
        std.mem.sort(u32, owned, {}, std.sort.asc(u32));
        return self.intern(.{ .error_set = .{ .name = name, .tags = owned } });
    }

    /// Size in bytes for a type (pointer-sized = 8 on 64-bit).
    pub fn sizeOf(self: *const TypeTable, id: TypeId) u32 {
        const info = self.get(id);
        return switch (info) {
            .void, .noreturn => 0,
            .bool => 1,
            .signed => |w| @max(1, w / 8),
            .unsigned => |w| @max(1, w / 8),
            .f32 => 4,
            .f64 => 8,
            .string => 16, // {ptr, len}
            .cstring => 8, // one pointer
            .pointer, .many_pointer, .function => 8,
            .closure => 16, // {fn_ptr, env}
            .optional => |opt| blk: {
                // Sentinel-shaped optionals (pointer/closure/protocol) cost
                // no extra storage — null reuses the payload's null state.
                const child_info = self.get(opt.child);
                if (child_info == .pointer or child_info == .many_pointer or child_info == .function or child_info == .cstring) break :blk 8;
                if (child_info == .closure) break :blk 16;
                if (child_info == .@"struct" and child_info.@"struct".is_protocol) break :blk self.sizeOf(opt.child);
                // Discriminated form: payload + has_value flag (8-aligned).
                break :blk self.sizeOf(opt.child) + 8;
            },
            .slice => 16, // {ptr, len}
            .array => |arr| arr.length * self.sizeOf(arr.element),
            .vector => |vec| vec.length * self.sizeOf(vec.element),
            .any => 16, // {type_tag, data_ptr}
            .type_value => 8, // an 8-byte type handle (a `TypeId` in a word), NOT the 16-byte any box
            .@"struct" => |s| {
                var total: u32 = 0;
                for (s.fields) |f| total += @max(self.sizeOf(f.ty), 8);
                return if (total == 0) 8 else total;
            },
            .@"union" => |u| {
                var max_field: u32 = 0;
                for (u.fields) |f| {
                    const sz = self.sizeOf(f.ty);
                    if (sz > max_field) max_field = sz;
                }
                return @max(max_field, 8);
            },
            .tagged_union => |u| {
                if (u.backing_type) |bt| return self.sizeOf(bt);
                var max_field: u32 = 0;
                for (u.fields) |f| {
                    const sz = self.sizeOf(f.ty);
                    if (sz > max_field) max_field = sz;
                }
                const tag_sz = @as(u32, @intCast(self.typeSizeBytes(u.tag_type)));
                return tag_sz + @max(max_field, 8);
            },
            .@"enum" => |e| {
                if (e.backing_type) |bt| return self.sizeOf(bt);
                return 8;
            },
            .tuple => |t| {
                var total: u32 = 0;
                for (t.fields) |f| total += @max(self.sizeOf(f), 8);
                return if (total == 0) 8 else total;
            },
            .protocol => 24, // {ctx, type_id, vtable}
            .error_set => 4, // u32 tag id on the error channel
            .usize, .isize => 8, // pointer-sized (this path is not target-aware; see typeSizeBytes)
            // Comptime-only: a pack must be expanded to flat positional args
            // before codegen. Reaching runtime layout means a pack leaked.
            .pack => @panic("pack type has no runtime layout (comptime-only)"),
            // Tripwire: a failed type resolution must have surfaced a
            // diagnostic and aborted before any layout query.
            .unresolved => @panic("unresolved type reached sizeOf — a type resolution failure was not diagnosed/aborted"),
        };
    }

    /// Compute the ABI size in bytes for a type, matching LLVM's struct layout rules.
    /// This is the authoritative size computation used for closure env sizing and
    /// verified against LLVMABISizeOfType.
    fn intAbiBytes(w: u16) usize {
        // LLVM ABI size for iN: round w up to the next power of 2, then /8.
        // Sub-byte widths (i1, i2, ..., i7) are 1 byte.
        if (w <= 8) return 1;
        if (w <= 16) return 2;
        if (w <= 32) return 4;
        return 8;
    }

    /// True iff `ty` is an unsigned integer — a builtin (u8/u16/u32/u64/usize)
    /// or a user-defined arbitrary-width unsigned int. Canonical signedness
    /// query for reflection (`type_is_unsigned`) and the `{}` formatter so a
    /// u64 value renders as unsigned decimal rather than the i64 reinterpretation.
    pub fn isUnsignedInt(self: *const TypeTable, ty: TypeId) bool {
        switch (ty) {
            .u8, .u16, .u32, .u64, .usize => return true,
            .bool, .i8, .i16, .i32, .i64, .isize => return false,
            else => {},
        }
        if (ty.isBuiltin()) return false;
        return self.get(ty) == .unsigned;
    }

    pub fn typeSizeBytes(self: *const TypeTable, ty: TypeId) usize {
        const ptr_size: usize = self.pointer_size;
        if (ty == .void) return 0;
        if (ty == .bool) return 1;
        if (ty == .u8 or ty == .i8) return 1;
        if (ty == .u16 or ty == .i16) return 2;
        if (ty == .i32 or ty == .u32 or ty == .f32) return 4;
        if (ty == .i64 or ty == .u64 or ty == .f64) return 8;
        if (ty == .usize or ty == .isize) return ptr_size;
        if (ty == .cstring) return ptr_size;
        if (ty == .string) return 16; // {ptr, i64} — always 16 (i64 alignment pads on wasm32)
        if (ty == .any) return 16; // {i64 tag, i64 value} — Any boxed layout
        if (ty == .type_value) return 8; // 8-byte type handle (a `TypeId` in a word)
        if (ty.isBuiltin()) return ptr_size; // default for unknown builtins
        const info = self.get(ty);
        return switch (info) {
            .pointer, .many_pointer, .function => ptr_size,
            .slice => 16, // {ptr, i64} — same layout as string
            .closure => 2 * ptr_size, // {fn_ptr, env_ptr}
            .optional => |o| blk: {
                const child_info = self.get(o.child);
                if (child_info == .pointer or child_info == .many_pointer or child_info == .function)
                    break :blk ptr_size;
                if (child_info == .closure)
                    break :blk 2 * ptr_size;
                if (child_info == .@"struct" and child_info.@"struct".is_protocol)
                    break :blk self.typeSizeBytes(o.child);
                const cs = self.typeSizeBytes(o.child);
                const ca = self.typeAlignBytes(o.child);
                // { T, i1 } — i1 goes right after T, then pad to struct alignment
                const unpadded = cs + 1;
                break :blk (unpadded + ca - 1) & ~(ca - 1);
            },
            .@"struct" => |s| blk: {
                var offset: usize = 0;
                var max_a: usize = 1;
                for (s.fields) |f| {
                    const fs = self.typeSizeBytes(f.ty);
                    const fa = self.typeAlignBytes(f.ty);
                    if (fa > max_a) max_a = fa;
                    offset = (offset + fa - 1) & ~(fa - 1);
                    offset += fs;
                }
                break :blk if (offset == 0) 0 else (offset + max_a - 1) & ~(max_a - 1);
            },
            .@"union" => |u| blk: {
                var max_payload: usize = 0;
                for (u.fields) |f| {
                    const fs = self.typeSizeBytes(f.ty);
                    if (fs > max_payload) max_payload = fs;
                }
                break :blk if (max_payload == 0) 8 else max_payload;
            },
            .tagged_union => |u| blk: {
                if (u.backing_type) |bt| break :blk self.typeSizeBytes(bt);
                var max_payload: usize = 0;
                for (u.fields) |f| {
                    const fs = self.typeSizeBytes(f.ty);
                    if (fs > max_payload) max_payload = fs;
                }
                // Mirror the LLVM lowering (backend/llvm/types.zig): the payload
                // area is laid out as `[max_size x i8]` with a floor of 8 when no
                // field carries a payload (all-void / empty union). Without this
                // floor an empty/all-void tagged_union sizes to tag_size only,
                // diverging from the LLVM type and tripping verifySizes.
                if (max_payload == 0) max_payload = 8;
                const tag_size = self.typeSizeBytes(u.tag_type);
                const raw = max_payload + tag_size;
                break :blk (raw + 7) & ~@as(usize, 7);
            },
            .array => |a| blk: {
                const elem_size = self.typeSizeBytes(a.element);
                break :blk elem_size * @as(usize, @intCast(a.length));
            },
            .vector => |v| blk: {
                const elem_size = self.typeSizeBytes(v.element);
                const raw = elem_size * @as(usize, @intCast(v.length));
                // LLVM vectors round ABI size up to next power of 2
                break :blk std.math.ceilPowerOfTwo(usize, raw) catch raw;
            },
            .tuple => |t| blk: {
                var offset: usize = 0;
                var max_a: usize = 1;
                for (t.fields) |f| {
                    const fs = self.typeSizeBytes(f);
                    const fa = self.typeAlignBytes(f);
                    if (fa > max_a) max_a = fa;
                    offset = (offset + fa - 1) & ~(fa - 1);
                    offset += fs;
                }
                break :blk if (offset == 0) 0 else (offset + max_a - 1) & ~(max_a - 1);
            },
            .any => 2 * ptr_size, // {type_tag, data_ptr}
            .protocol => 3 * ptr_size, // {ctx, type_id, vtable}
            .error_set => 4, // u32 tag id
            .@"enum" => |e| {
                if (e.backing_type) |bt| return self.typeSizeBytes(bt);
                return 8;
            },
            // LLVM rounds arbitrary-width integers up to the next power-of-2
            // width before computing ABI size (i12 → 2 bytes, i24 → 4 bytes).
            .signed => |w| intAbiBytes(w),
            .unsigned => |w| intAbiBytes(w),
            else => 8,
        };
    }

    /// Compute the ABI alignment in bytes for a type, matching LLVM's rules.
    pub fn typeAlignBytes(self: *const TypeTable, ty: TypeId) usize {
        const ptr_align: usize = self.pointer_size;
        if (ty == .void) return 1;
        if (ty == .bool) return 1;
        if (ty == .u8 or ty == .i8) return 1;
        if (ty == .u16 or ty == .i16) return 2;
        if (ty == .i32 or ty == .u32 or ty == .f32) return 4;
        if (ty == .i64 or ty == .u64 or ty == .f64) return 8;
        if (ty == .usize or ty == .isize) return ptr_align;
        if (ty == .string) return 8; // i64 drives alignment
        if (ty == .cstring) return ptr_align;
        if (ty == .any) return 8; // {i64, i64} aligns to 8
        if (ty == .type_value) return 8; // 8-byte type handle
        if (ty.isBuiltin()) return ptr_align;
        const info = self.get(ty);
        return switch (info) {
            .pointer, .many_pointer, .function => ptr_align,
            .slice => 8, // i64 drives alignment
            .closure => ptr_align, // {ptr, ptr}
            .optional => |o| blk: {
                const child_info = self.get(o.child);
                if (child_info == .pointer or child_info == .many_pointer or child_info == .function or child_info == .closure)
                    break :blk ptr_align;
                break :blk self.typeAlignBytes(o.child);
            },
            .@"struct" => |s| blk: {
                var max_a: usize = 1;
                for (s.fields) |f| {
                    const fa = self.typeAlignBytes(f.ty);
                    if (fa > max_a) max_a = fa;
                }
                break :blk max_a;
            },
            .@"union", .tagged_union => 8,
            .error_set => 4, // u32 tag id
            .@"enum" => |e| {
                if (e.backing_type) |bt| return self.typeAlignBytes(bt);
                return 8;
            },
            .array => |a| self.typeAlignBytes(a.element),
            // LLVM gives vectors their NATURAL alignment — the ABI size
            // rounded up to a power of two — not the element alignment.
            // Element alignment here silently diverged from LLVM's struct
            // layout for any vector-typed field (wrong interior offsets;
            // total-size mismatches trip emit_llvm's verifySizes assert).
            .vector => |v| blk: {
                const raw = self.typeSizeBytes(v.element) * @as(usize, @intCast(v.length));
                break :blk std.math.ceilPowerOfTwo(usize, raw) catch raw;
            },
            .tuple => |t| blk: {
                var max_a: usize = 1;
                for (t.fields) |f| {
                    const fa = self.typeAlignBytes(f);
                    if (fa > max_a) max_a = fa;
                }
                break :blk max_a;
            },
            .signed => |w| intAbiBytes(w),
            .unsigned => |w| intAbiBytes(w),
            else => 8,
        };
    }

    /// Intern a string into the pool.
    pub fn internString(self: *TypeTable, str: []const u8) StringId {
        return self.strings.intern(self.alloc, str);
    }

    /// Look up a string from its id.
    pub fn getString(self: *const TypeTable, id: StringId) []const u8 {
        return self.strings.get(id);
    }

    /// Format a TypeId for display (e.g., "i32", "*bool", "[]u8").
    pub fn typeName(self: *const TypeTable, id: TypeId) []const u8 {
        // Fast path for builtins
        return switch (id) {
            .void => "void",
            .bool => "bool",
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .f32 => "f32",
            .f64 => "f64",
            .string => "string",
            .cstring => "cstring",
            .any => "any",
            .type_value => "Type",
            .noreturn => "noreturn",
            .isize => "isize",
            .usize => "usize",
            .unresolved => "<unresolved>",
            else => {
                // User types — format from TypeInfo
                const info = self.get(id);
                return switch (info) {
                    .@"struct" => |s| self.getString(s.name),
                    .@"enum" => |e| self.getString(e.name),
                    .@"union" => |u| self.getString(u.name),
                    .tagged_union => |u| self.getString(u.name),
                    .protocol => |p| self.getString(p.name),
                    .error_set => |e| self.getString(e.name),
                    else => "?",
                };
            },
        };
    }

    /// Like `typeName` but produces structural names for compound
    /// types (`*T`, `[]T`, `[N]T`, `?T`, `Vector(N,T)`, function and
    /// tuple types) instead of returning `"?"`. Compound names are
    /// freshly allocated via `alloc`; builtin and named user types
    /// return borrowed slices.
    pub fn formatTypeName(self: *const TypeTable, alloc: std.mem.Allocator, id: TypeId) []const u8 {
        if (id.isBuiltin()) return self.typeName(id);
        const info = self.get(id);
        return switch (info) {
            .@"struct" => |s| self.getString(s.name),
            .@"enum" => |e| self.getString(e.name),
            .@"union" => |u| self.getString(u.name),
            .tagged_union => |u| self.getString(u.name),
            .protocol => |p| self.getString(p.name),
            .error_set => |e| self.getString(e.name),
            .pointer => |p| blk: {
                const inner = self.formatTypeName(alloc, p.pointee);
                break :blk std.fmt.allocPrint(alloc, "*{s}", .{inner}) catch "*?";
            },
            .many_pointer => |p| blk: {
                const inner = self.formatTypeName(alloc, p.element);
                break :blk std.fmt.allocPrint(alloc, "[*]{s}", .{inner}) catch "[*]?";
            },
            .slice => |s| blk: {
                const inner = self.formatTypeName(alloc, s.element);
                break :blk std.fmt.allocPrint(alloc, "[]{s}", .{inner}) catch "[]?";
            },
            .array => |a| blk: {
                const inner = self.formatTypeName(alloc, a.element);
                break :blk std.fmt.allocPrint(alloc, "[{d}]{s}", .{ a.length, inner }) catch "[N]?";
            },
            .vector => |v| blk: {
                const inner = self.formatTypeName(alloc, v.element);
                break :blk std.fmt.allocPrint(alloc, "Vector({d},{s})", .{ v.length, inner }) catch "Vector(?)";
            },
            .optional => |o| blk: {
                const inner = self.formatTypeName(alloc, o.child);
                break :blk std.fmt.allocPrint(alloc, "?{s}", .{inner}) catch "?_";
            },
            .function => |f| blk: {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(alloc);
                buf.append(alloc, '(') catch break :blk "(?)";
                for (f.params, 0..) |p, i| {
                    if (i > 0) buf.appendSlice(alloc, ", ") catch break :blk "(?)";
                    buf.appendSlice(alloc, self.formatTypeName(alloc, p)) catch break :blk "(?)";
                }
                buf.append(alloc, ')') catch break :blk "(?)";
                if (f.ret != .void) {
                    buf.appendSlice(alloc, " -> ") catch break :blk "(?)";
                    buf.appendSlice(alloc, self.formatTypeName(alloc, f.ret)) catch break :blk "(?)";
                }
                break :blk buf.toOwnedSlice(alloc) catch "(?)";
            },
            .closure => |co| blk: {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(alloc);
                buf.appendSlice(alloc, "Closure(") catch break :blk "Closure(?)";
                for (co.params, 0..) |p, i| {
                    if (i > 0) buf.appendSlice(alloc, ", ") catch break :blk "Closure(?)";
                    buf.appendSlice(alloc, self.formatTypeName(alloc, p)) catch break :blk "Closure(?)";
                }
                buf.append(alloc, ')') catch break :blk "Closure(?)";
                if (co.ret != .void) {
                    buf.appendSlice(alloc, " -> ") catch break :blk "Closure(?)";
                    buf.appendSlice(alloc, self.formatTypeName(alloc, co.ret)) catch break :blk "Closure(?)";
                }
                break :blk buf.toOwnedSlice(alloc) catch "Closure(?)";
            },
            .tuple => |tu| blk: {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(alloc);
                buf.append(alloc, '(') catch break :blk "(?)";
                for (tu.fields, 0..) |f, i| {
                    if (i > 0) buf.appendSlice(alloc, ", ") catch break :blk "(?)";
                    buf.appendSlice(alloc, self.formatTypeName(alloc, f)) catch break :blk "(?)";
                }
                // 1-tuple renders `(T,)` — `(T)` now spells a grouping.
                if (tu.fields.len == 1) buf.append(alloc, ',') catch break :blk "(?)";
                buf.append(alloc, ')') catch break :blk "(?)";
                break :blk buf.toOwnedSlice(alloc) catch "(?)";
            },
            .pack => |pk| blk: {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(alloc);
                buf.appendSlice(alloc, "pack(") catch break :blk "pack(?)";
                for (pk.elements, 0..) |e, i| {
                    if (i > 0) buf.appendSlice(alloc, ", ") catch break :blk "pack(?)";
                    buf.appendSlice(alloc, self.formatTypeName(alloc, e)) catch break :blk "pack(?)";
                }
                buf.append(alloc, ')') catch break :blk "pack(?)";
                break :blk buf.toOwnedSlice(alloc) catch "pack(?)";
            },
            .signed => |w| std.fmt.allocPrint(alloc, "i{d}", .{w}) catch "i?",
            .unsigned => |w| std.fmt.allocPrint(alloc, "u{d}", .{w}) catch "u?",
            else => self.typeName(id),
        };
    }
};

// ── Intern map support ──────────────────────────────────────────────────
// We use a custom hash/eql context so structurally identical types dedup.

const TypeKey = struct {
    info: TypeInfo,
};

const TypeKeyContext = struct {
    pub fn hash(_: TypeKeyContext, key: TypeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        hashTypeInfo(&h, key.info);
        return h.final();
    }

    pub fn eql(_: TypeKeyContext, a: TypeKey, b: TypeKey) bool {
        return typeInfoEql(a.info, b.info);
    }
};

fn hashTypeInfo(h: *std.hash.Wyhash, info: TypeInfo) void {
    // Hash the tag
    const tag: u8 = @intFromEnum(std.meta.activeTag(info));
    h.update(&.{tag});

    switch (info) {
        .signed => |w| h.update(&.{w}),
        .unsigned => |w| h.update(&.{w}),
        .f32, .f64, .void, .bool, .string, .cstring, .any, .type_value, .noreturn, .usize, .isize, .unresolved => {},
        .pointer => |p| h.update(std.mem.asBytes(&p.pointee)),
        .many_pointer => |p| h.update(std.mem.asBytes(&p.element)),
        .slice => |s| h.update(std.mem.asBytes(&s.element)),
        .array => |a| {
            h.update(std.mem.asBytes(&a.element));
            h.update(std.mem.asBytes(&a.length));
        },
        .vector => |v| {
            h.update(std.mem.asBytes(&v.element));
            h.update(std.mem.asBytes(&v.length));
        },
        .optional => |o| h.update(std.mem.asBytes(&o.child)),
        .function => |f| {
            for (f.params) |p| h.update(std.mem.asBytes(&p));
            h.update(std.mem.asBytes(&f.ret));
            const cc_byte: u8 = @intFromEnum(f.call_conv);
            h.update(&.{cc_byte});
            const pack_present: u8 = if (f.pack_start != null) 1 else 0;
            h.update(&.{pack_present});
            if (f.pack_start) |ps| h.update(std.mem.asBytes(&ps));
        },
        .closure => |c| {
            for (c.params) |p| h.update(std.mem.asBytes(&p));
            h.update(std.mem.asBytes(&c.ret));
            const pack_present: u8 = if (c.pack_start != null) 1 else 0;
            h.update(&.{pack_present});
            if (c.pack_start) |ps| h.update(std.mem.asBytes(&ps));
        },
        // Nominal arms key by display name; `nominal_id` joins the key only when
        // nonzero, so structural (legacy) interning hashes byte-identically.
        .@"struct" => |s| {
            h.update(std.mem.asBytes(&s.name));
            if (s.nominal_id != 0) h.update(std.mem.asBytes(&s.nominal_id));
        },
        .@"enum" => |e| {
            h.update(std.mem.asBytes(&e.name));
            if (e.nominal_id != 0) h.update(std.mem.asBytes(&e.nominal_id));
        },
        .@"union" => |u| {
            h.update(std.mem.asBytes(&u.name));
            if (u.nominal_id != 0) h.update(std.mem.asBytes(&u.nominal_id));
        },
        .tagged_union => |u| {
            h.update(std.mem.asBytes(&u.name));
            if (u.nominal_id != 0) h.update(std.mem.asBytes(&u.nominal_id));
        },
        .protocol => |p| h.update(std.mem.asBytes(&p.name)),
        .error_set => |e| {
            h.update(std.mem.asBytes(&e.name));
            if (e.nominal_id != 0) h.update(std.mem.asBytes(&e.nominal_id));
        },
        .tuple => |t| {
            for (t.fields) |f| h.update(std.mem.asBytes(&f));
            if (t.names) |ns| for (ns) |n| h.update(std.mem.asBytes(&n));
        },
        .pack => |p| {
            for (p.elements) |e| h.update(std.mem.asBytes(&e));
        },
    }
}

fn typeInfoEql(a: TypeInfo, b: TypeInfo) bool {
    const Tag = std.meta.Tag(TypeInfo);
    const a_tag: Tag = a;
    const b_tag: Tag = b;
    if (a_tag != b_tag) return false;

    return switch (a) {
        .signed => |w| w == b.signed,
        .unsigned => |w| w == b.unsigned,
        .f32, .f64, .void, .bool, .string, .cstring, .any, .type_value, .noreturn, .usize, .isize, .unresolved => true,
        .pointer => |p| p.pointee == b.pointer.pointee,
        .many_pointer => |p| p.element == b.many_pointer.element,
        .slice => |s| s.element == b.slice.element,
        .array => |ar| ar.element == b.array.element and ar.length == b.array.length,
        .vector => |v| v.element == b.vector.element and v.length == b.vector.length,
        .optional => |o| o.child == b.optional.child,
        .function => |f| {
            const g = b.function;
            if (f.params.len != g.params.len) return false;
            for (f.params, g.params) |fp, gp| {
                if (fp != gp) return false;
            }
            if (f.call_conv != g.call_conv) return false;
            if ((f.pack_start == null) != (g.pack_start == null)) return false;
            if (f.pack_start) |fp| if (fp != g.pack_start.?) return false;
            return f.ret == g.ret;
        },
        .closure => |c| {
            const d = b.closure;
            if (c.params.len != d.params.len) return false;
            for (c.params, d.params) |cp, dp| {
                if (cp != dp) return false;
            }
            if ((c.pack_start == null) != (d.pack_start == null)) return false;
            if (c.pack_start) |cp| if (cp != d.pack_start.?) return false;
            return c.ret == d.ret;
        },
        // Nominal arms compare display name + nominal id. With both ids 0 this is
        // name-only equality (legacy); a nonzero id distinguishes same-name authors.
        .@"struct" => |s| s.name == b.@"struct".name and s.nominal_id == b.@"struct".nominal_id,
        .@"enum" => |e| e.name == b.@"enum".name and e.nominal_id == b.@"enum".nominal_id,
        .@"union" => |u| u.name == b.@"union".name and u.nominal_id == b.@"union".nominal_id,
        .tagged_union => |u| u.name == b.tagged_union.name and u.nominal_id == b.tagged_union.nominal_id,
        .protocol => |p| p.name == b.protocol.name,
        .error_set => |e| e.name == b.error_set.name and e.nominal_id == b.error_set.nominal_id,
        .tuple => |t| {
            const u = b.tuple;
            if (t.fields.len != u.fields.len) return false;
            for (t.fields, u.fields) |tf, uf| {
                if (tf != uf) return false;
            }
            if ((t.names == null) != (u.names == null)) return false;
            if (t.names) |tn| {
                const un = u.names.?;
                if (tn.len != un.len) return false;
                for (tn, un) |tna, una| if (tna != una) return false;
            }
            return true;
        },
        .pack => |p| {
            const q = b.pack;
            if (p.elements.len != q.elements.len) return false;
            for (p.elements, q.elements) |pe, qe| {
                if (pe != qe) return false;
            }
            return true;
        },
    };
}
