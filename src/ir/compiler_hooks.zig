const std = @import("std");
const Allocator = std.mem.Allocator;
const inst = @import("inst.zig");
const FuncId = inst.FuncId;
const types = @import("types.zig");
const TypeId = types.TypeId;
const TypeTable = types.TypeTable;
const Value = @import("comptime_value.zig").Value;

// ── BuildConfig ─────────────────────────────────────────────────────────
// The build state the sx-driven pipeline (`defaultPipeline` / an `@onBuild`
// callback) runs against. The `@BuildOptions` instance itself is sx data: the
// compiler keeps its SNAPSHOT here between comptime evaluations (each one owns
// its memory), materializes it into an evaluation on `@buildOptions()`, and
// copies it back out when the evaluation completes. Zig reads and writes the
// snapshot by field name; the field shape is the `@BuildOptions` contract.

pub const BuildConfig = struct {
    /// The `@BuildOptions` struct type, resolved once lowering has registered
    /// modules/build.sx; `.unresolved` when no program declares it.
    options_ty: TypeId = .unresolved,
    /// The instance snapshot, one Value per field in declaration order; null
    /// until an evaluation materializes it or the driver writes a field.
    options: ?[]Value = null,

    /// Post-link callback registered via `@onBuild(cb)`. When set, the
    /// compiler re-enters the comptime VM after `target.link()`
    /// and invokes this function. A `false` return is treated as a
    /// build failure.
    post_link_callback_fn: ?FuncId = null,
    /// True when the post-link callback takes the `*@BuildOptions` handle
    /// (`cb: (opt: *@BuildOptions) -> bool`) rather than no args. When set, the
    /// compiler invokes the callback with the instance address as its arg.
    post_link_takes_options: bool = false,

    /// C companion object files (`@import c { @source ... }`, compiled to `.o`)
    /// and `@library` link names, forwarded by main.zig before the post-link
    /// callback so the sx-driven build pipeline can read them via the
    /// `@cObjectPaths()` / `@linkLibraries()` compiler primitives and pass them
    /// to `@link`. Slices reference compiler-owned memory that outlives the
    /// callback.
    c_object_paths: []const []const u8 = &.{},
    link_libraries: []const []const u8 = &.{},

    /// The fully-merged link flags (CLI `extra_link_flags` + `@run`
    /// `linkFlags`), forwarded by main.zig. The sx driver reads them via
    /// `@buildFlags()` and passes them to `@link`.
    merged_link_flags: []const []const u8 = &.{},

    /// Host-installed callbacks for build-pipeline ACTIONS the comptime VM can't
    /// perform itself (it can't depend on the driver — `core`/`main`/`target`).
    /// main.zig installs this before the post-link callback; the VM's `@link`
    /// primitive dispatches through it. Null outside a post-link build (a `@link`
    /// call then bails loudly — it's a post-codegen-only action).
    build_hooks: ?*const BuildHooks = null,

    /// The snapshot as one Value, for materialization; `.undef` before any
    /// write, which materializes as the all-empty instance.
    pub fn snapshot(self: *const BuildConfig) Value {
        return if (self.options) |f| .{ .aggregate = f } else .undef;
    }

    /// Index of `@BuildOptions.<name>` in declaration order, or null when the
    /// type is unresolved or has no such field.
    pub fn fieldIndex(self: *const BuildConfig, table: *const TypeTable, name: []const u8) ?usize {
        if (self.options_ty == .unresolved) return null;
        for (table.get(self.options_ty).@"struct".fields, 0..) |f, i| {
            if (std.mem.eql(u8, table.getString(f.name), name)) return i;
        }
        return null;
    }

    /// The snapshot's fields, mutable; an absent snapshot becomes one `.undef`
    /// per field. Null when `@BuildOptions` is unresolved.
    fn fields(self: *BuildConfig, alloc: Allocator, table: *const TypeTable) !?[]Value {
        if (self.options) |f| return f;
        if (self.options_ty == .unresolved) return null;
        const n = table.get(self.options_ty).@"struct".fields.len;
        const f = try alloc.alloc(Value, n);
        @memset(f, .undef);
        self.options = f;
        return f;
    }

    /// A `string` field; `""` when unset or the type is unresolved.
    pub fn getString(self: *const BuildConfig, table: *const TypeTable, name: []const u8) []const u8 {
        const f = self.options orelse return "";
        const i = self.fieldIndex(table, name) orelse return "";
        return switch (f[i]) {
            .string => |s| s,
            else => "",
        };
    }

    pub fn setString(self: *BuildConfig, alloc: Allocator, table: *const TypeTable, name: []const u8, value: []const u8) !void {
        const f = (try self.fields(alloc, table)) orelse return;
        const i = self.fieldIndex(table, name) orelse return error.NoSuchField;
        f[i] = .{ .string = try alloc.dupe(u8, value) };
    }

    /// Fill a `string` field the `@run` configuration left unset.
    pub fn setStringIfUnset(self: *BuildConfig, alloc: Allocator, table: *const TypeTable, name: []const u8, value: ?[]const u8) !void {
        const v = value orelse return;
        if (self.getString(table, name).len == 0) try self.setString(alloc, table, name, v);
    }

    /// The items of a `List(string)` field; empty when unset. The strings are
    /// the snapshot's own.
    pub fn getStrings(self: *const BuildConfig, alloc: Allocator, table: *const TypeTable, name: []const u8) ![]const []const u8 {
        const f = self.options orelse return &.{};
        const i = self.fieldIndex(table, name) orelse return &.{};
        if (f[i] != .aggregate) return &.{};
        const items = f[i].aggregate[0];
        if (items != .aggregate) return &.{};
        const out = try alloc.alloc([]const u8, items.aggregate.len);
        for (items.aggregate, 0..) |v, k| out[k] = if (v == .string) v.string else "";
        return out;
    }

    /// Replace a `List(string)` field with `values` (its items, `cap` = count).
    pub fn setStrings(self: *BuildConfig, alloc: Allocator, table: *const TypeTable, name: []const u8, values: []const []const u8) !void {
        const f = (try self.fields(alloc, table)) orelse return;
        const i = self.fieldIndex(table, name) orelse return error.NoSuchField;
        const items = try alloc.alloc(Value, values.len);
        for (values, 0..) |v, k| items[k] = .{ .string = try alloc.dupe(u8, v) };
        const list = try alloc.alloc(Value, 2);
        list[0] = .{ .aggregate = items };
        list[1] = .{ .int = @intCast(values.len) };
        f[i] = .{ .aggregate = list };
    }
};

/// Host-installed callbacks for build-pipeline ACTIONS the comptime VM dispatches
/// but can't perform itself (it must not depend on the driver: `core`/`main`/
/// `target`). main.zig builds the concrete `ctx` + functions and points
/// `BuildConfig.build_hooks` at it before invoking the post-link callback. The
/// build callback is NOT fallible — a failed action returns an
/// error here and the VM surfaces it as a hard build error.
pub const BuildHooks = struct {
    ctx: *anyopaque,
    /// Verify + emit the codegen'd module to its object file; return the path
    /// (ctx-owned). The `@emitObject()` primitive — an ACTION: emission is
    /// sx-driven via `defaultPipeline`.
    emit_object: *const fn (ctx: *anyopaque) anyerror![]const u8,
    /// Link `objects` → `output`, with the given `libraries` / `frameworks` /
    /// link `flags` / `target` triple. (`objects` is the full object list; the
    /// adapter splits it for the underlying linker.)
    link: *const fn (
        ctx: *anyopaque,
        objects: []const []const u8,
        output: []const u8,
        libraries: []const []const u8,
        frameworks: []const []const u8,
        flags: []const []const u8,
        target: []const u8,
    ) anyerror!void,
};

