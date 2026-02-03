//! Comptime VALUE — the result/materialization representation produced by the
//! comptime VM (`comptime_vm.regToValue`) and consumed by
//! `emit_llvm.valueToLLVMConst`. The byte-addressable VM executes natively;
//! this type is only the result DTO at the VM↔host boundary.

const std = @import("std");
const types = @import("types.zig");
const inst_mod = @import("inst.zig");

const TypeId = types.TypeId;
const FuncId = inst_mod.FuncId;

// ── Value ───────────────────────────────────────────────────────────────

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    null_val,
    void_val,
    undef,
    aggregate: []const Value,
    slot_ptr: u32, // index into the frame's local slots
    func_ref: FuncId,
    closure: ClosureVal,
    type_tag: TypeId,
    heap_ptr: HeapPtr, // pointer into heap-allocated memory
    /// Byte-granular raw pointer. Produced by `index_gep` on a string /
    /// `[*]u8` aggregate whose data field is itself a raw integer pointer
    /// (e.g. from libc_malloc). Store/load through this variant operate
    /// on a single byte — matching the heap_ptr semantics for the same
    /// op shape.
    byte_ptr: usize,

    pub const ClosureVal = struct {
        func: FuncId,
        env: ?[]const Value,
    };

    /// A pointer to heap-allocated memory, with an optional byte offset.
    pub const HeapPtr = struct {
        id: u32, // index into the legacy heap (historical)
        offset: u32 = 0,
    };

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |v| v,
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |v| v,
            .int => |v| @floatFromInt(v), // implicit int→float for convenience
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |v| v,
            else => null,
        };
    }

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    /// Extract the TypeId from a first-class Type value. Returns null
    /// for anything else — including `.int(N)` where N happens to be
    /// a valid TypeId enum value. The kinds are distinct: a Type IS
    /// NOT an int. Use this helper instead of `asInt` when reading a
    /// TypeId out of a Value to keep the kind-distinction honest.
    pub fn asTypeId(self: Value) ?TypeId {
        return switch (self) {
            .type_tag => |id| id,
            else => null,
        };
    }
};

/// Normalize a comptime value into the list of EnumVariant element values.
/// A `[]EnumVariant` slice evaluates to a `{ data, len }` aggregate (`len` an
/// int); a `[N]EnumVariant` array literal evaluates to the element aggregate
/// directly. Returns null for any other shape (the caller bails loudly).
pub fn decodeVariantElements(result: Value) ?[]const Value {
    const fields = switch (result) {
        .aggregate => |f| f,
        else => return null,
    };
    // Slice fat pointer `{ data, len }`: a 2-field aggregate whose 2nd field is
    // an integer length. (A 2-VARIANT array can't collide — its 2nd field is an
    // EnumVariant aggregate, so `asInt` is null.)
    if (fields.len == 2) {
        if (fields[1].asInt()) |len_i| {
            const len: usize = @intCast(len_i);
            switch (fields[0]) {
                .aggregate => |arr| return if (len <= arr.len) arr[0..len] else null,
                else => return null,
            }
        }
    }
    return fields;
}
