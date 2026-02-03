//! The intrinsic registry — the single source of truth for every sx declaration
//! whose implementation lives in the compiler:
//!
//!     size_of :: ($T: Type) -> i64 intrinsic;
//!
//! This table IS, at once: the allow-list (an `intrinsic` declaration whose
//! binding key is absent is a load-time diagnostic, never a dlsym or runtime
//! fallback), the signature validator, the lowering-dispatch key, the
//! comptime-VM-dispatch key, and the audit source that `intrinsics.test.zig`
//! checks against the library sources.
//!
//! **Binding key = (module, name).** The declaring module is part of the
//! identity: `size_of` is an intrinsic *because std/core.sx declares it*, not
//! because the name is magic. A same-named declaration in another module is a
//! different function and gets no intrinsic dispatch.
//!
//! **Not in this table** — two categories that are deliberately absent, so that
//! "every entry has a handler, every `intrinsic` declaration has an entry" holds
//! with no exemption list:
//!
//!   * Language primitives (`string`, `Vector`) — resolved by name by the type
//!     system (`type_resolver` / `type_bridge`) like `int` / `bool` / `f64`.
//!     They are declared nowhere and are not call-dispatched.
//!   * Keywords (`cast`, `type_eq`, `has_impl`, `is_struct`, `is_comptime`,
//!     `compile_error`, `__interp_print_frames`, `__trace_resolve_frame`) —
//!     bare names the compiler recognizes without any declaration.

const std = @import("std");
const types = @import("types.zig");
const TypeId = types.TypeId;

/// How an intrinsic call is dispatched. This describes DISPATCH, not
/// stage-availability — the two are independent. `sqrt` and `atomic_load` are
/// both `.lower`, yet `atomic_load` evaluates at comptime and `sqrt` does not:
/// the VM interprets the atomic ops `atomic_load` lowers to, but has no arm for
/// the `call_builtin` that `sqrt` lowers to.
pub const Mode = enum {
    /// Handled at lowering — folded to a constant, or lowered to IR ops.
    lower,
    /// Serviced only by the comptime VM. (No Stage-1 intrinsic is
    /// evaluate-only; the compiler services in `compiler.sx` / `build.sx` are.)
    evaluate,
    /// Both: a lowering fold for the statically-resolvable case, plus a VM arm
    /// for when the type argument is only known at evaluation time.
    dual,
};

/// Stable intrinsic identity. Order is not significant; the value is never
/// serialized.
pub const Id = enum(u16) {
    // ── std/core.sx — layout ────────────────────────────────────────────────
    size_of,
    align_of,
    // ── std/core.sx — reflection ────────────────────────────────────────────
    type_of,
    type_name,
    is_unsigned,
    struct_field_count,
    variant_count,
    struct_field_name,
    variant_name,
    struct_field_type,
    variant_type,
    struct_field_offset,
    struct_field_value,
    variant_payload,
    variant_value,
    variant_index,
    pointee_type,
    is_flags,
    is_identity,
    error_name,
    vector_lanes,
    @"__sx_variant_tag_width",
    any_element,
    raw_any_data,
    raw_make_any,
    // ── std/core.sx — the comptime compiler-API readers (evaluate-only) ─────
    raw_intern,
    raw_text_of,
    raw_find_type,
    raw_type_kind,
    raw_type_name,
    raw_field_count,
    raw_field_name,
    raw_field_type,
    raw_variant_value,
    raw_pointer_to,
    // ── std/meta.sx ─────────────────────────────────────────────────────────
    type_info,
    raw_declare_type,
    raw_register_type,
    // ── compiler.sx — the build-pipeline services (evaluate-only) ───────────
    c_object_paths,
    link_libraries,
    emit_object,
    link,
    build_output,
    build_target,
    build_frameworks,
    build_flags,
    // ── build.sx — the BuildOptions surface (evaluate-only) ─────────────────
    build_options,
    add_link_flag,
    add_framework,
    set_output_path,
    set_wasm_shell,
    add_asset_dir,
    asset_dir_count,
    asset_dir_src_at,
    asset_dir_dest_at,
    set_post_link_module,
    binary_path,
    set_bundle_path,
    set_bundle_id,
    set_codesign_identity,
    set_provisioning_profile,
    bundle_path,
    bundle_id,
    codesign_identity,
    provisioning_profile,
    target_triple,
    is_macos,
    is_ios,
    is_ios_device,
    is_ios_simulator,
    is_android,
    framework_count,
    framework_at,
    framework_path_count,
    framework_path_at,
    set_manifest_path,
    set_keystore_path,
    manifest_path,
    keystore_path,
    jni_main_count,
    jni_main_runtime_path_at,
    jni_main_java_source_at,
    on_build,
    // ── math/scalar.sx ──────────────────────────────────────────────────────
    sqrt,
    sin,
    cos,
    floor,
    // ── std/atomic.sx ───────────────────────────────────────────────────────
    atomic_load,
    atomic_store,
    atomic_fetch_add,
    atomic_fetch_sub,
    atomic_fetch_and,
    atomic_fetch_or,
    atomic_fetch_xor,
    atomic_fetch_min,
    atomic_fetch_max,
    atomic_swap,
    atomic_fence,
    atomic_cmpxchg,
    atomic_cmpxchg_weak,
};

pub const Entry = struct {
    id: Id,
    /// Binding key, part 1: the declaring module, as a stdlib-root-relative
    /// source path (matched against the declaration's source file).
    module: []const u8,
    /// Binding key, part 2: the declared name.
    name: []const u8,
    mode: Mode,
    /// Expected parameter count, validated against the declaration at load.
    arity: u8,
    /// The return type, when it is fixed regardless of the arguments.
    ///
    /// `null` means the handler computes it, and the reason is always that the
    /// result depends on an argument: the math intrinsics return their
    /// argument's type (`f32` in, `f32` out), the atomics return `T`, and
    /// `type_info` returns the `TypeInfo` it must look up in the type table.
    /// Callers that need a type for a null entry must ask the handler — there is
    /// no default to fall back on.
    ret: ?TypeId = null,
};

const core = "modules/std/core.sx";
const meta = "modules/std/meta.sx";
const scalar = "modules/math/scalar.sx";
const atomic = "modules/std/atomic.sx";
const compiler = "modules/compiler.sx";
const build = "modules/build.sx";

/// The registry. Every `intrinsic` declaration in the library appears here
/// exactly once, and every entry has a handler reachable from the dispatch
/// sites keyed by `Id`.
pub const entries = [_]Entry{
    // ── layout: folded to a `const_int` at lowering ─────────────────────────
    .{ .id = .size_of, .module = core, .name = "size_of", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .align_of, .module = core, .name = "align_of", .mode = .lower, .arity = 1, .ret = .i64 },

    // ── reflection: folded at lowering when the type arg is static ──────────
    .{ .id = .type_of, .module = core, .name = "type_of", .mode = .lower, .arity = 1, .ret = .type_value },
    .{ .id = .struct_field_count, .module = core, .name = "struct_field_count", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .variant_count, .module = core, .name = "variant_count", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .struct_field_name, .module = core, .name = "struct_field_name", .mode = .lower, .arity = 2, .ret = .string },
    .{ .id = .variant_name, .module = core, .name = "variant_name", .mode = .lower, .arity = 2, .ret = .string },
    .{ .id = .struct_field_type, .module = core, .name = "struct_field_type", .mode = .lower, .arity = 2, .ret = .type_value },
    .{ .id = .struct_field_offset, .module = core, .name = "struct_field_offset", .mode = .lower, .arity = 2, .ret = .i64 },
    .{ .id = .variant_type, .module = core, .name = "variant_type", .mode = .lower, .arity = 2, .ret = .type_value },
    .{ .id = .struct_field_value, .module = core, .name = "struct_field_value", .mode = .lower, .arity = 2, .ret = .any },
    .{ .id = .variant_payload, .module = core, .name = "variant_payload", .mode = .lower, .arity = 2, .ret = .any },
    .{ .id = .variant_value, .module = core, .name = "variant_value", .mode = .lower, .arity = 2, .ret = .i64 },
    .{ .id = .variant_index, .module = core, .name = "variant_index", .mode = .lower, .arity = 2, .ret = .i64 },
    .{ .id = .pointee_type, .module = core, .name = "pointee_type", .mode = .lower, .arity = 1, .ret = .type_value },
    .{ .id = .is_flags, .module = core, .name = "is_flags", .mode = .lower, .arity = 1, .ret = .bool },
    .{ .id = .is_identity, .module = core, .name = "is_identity", .mode = .lower, .arity = 1, .ret = .bool },
    .{ .id = .error_name, .module = core, .name = "error_name", .mode = .lower, .arity = 1, .ret = .string },
    .{ .id = .vector_lanes, .module = core, .name = "vector_lanes", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .@"__sx_variant_tag_width", .module = core, .name = "__sx_variant_tag_width", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .any_element, .module = core, .name = "any_element", .mode = .lower, .arity = 3, .ret = .any },
    .{ .id = .raw_any_data, .module = core, .name = "raw_any_data", .mode = .lower, .arity = 1 },
    .{ .id = .raw_make_any, .module = core, .name = "raw_make_any", .mode = .lower, .arity = 2, .ret = .any },

    // ── the comptime compiler-API readers: the VM reads/mints into the string
    // pool and type table. Handles are bare u32 (see core.sx).
    .{ .id = .raw_intern, .module = core, .name = "raw_intern", .mode = .evaluate, .arity = 1 },
    .{ .id = .raw_text_of, .module = core, .name = "raw_text_of", .mode = .evaluate, .arity = 1 },
    .{ .id = .raw_find_type, .module = core, .name = "raw_find_type", .mode = .evaluate, .arity = 1 },
    .{ .id = .raw_type_kind, .module = core, .name = "raw_type_kind", .mode = .evaluate, .arity = 1 },
    .{ .id = .raw_type_name, .module = core, .name = "raw_type_name", .mode = .evaluate, .arity = 1 },
    .{ .id = .raw_field_count, .module = core, .name = "raw_field_count", .mode = .evaluate, .arity = 1 },
    .{ .id = .raw_field_name, .module = core, .name = "raw_field_name", .mode = .evaluate, .arity = 2 },
    .{ .id = .raw_field_type, .module = core, .name = "raw_field_type", .mode = .evaluate, .arity = 2 },
    .{ .id = .raw_variant_value, .module = core, .name = "raw_variant_value", .mode = .evaluate, .arity = 2 },
    .{ .id = .raw_pointer_to, .module = core, .name = "raw_pointer_to", .mode = .evaluate, .arity = 1 },

    // ── reflection with a VM arm: the type arg may only be known at eval time
    // (e.g. `args[i]` inside a builder body, carrying a `.type_tag(TypeId)`).
    .{ .id = .type_name, .module = core, .name = "type_name", .mode = .dual, .arity = 1, .ret = .string },
    .{ .id = .is_unsigned, .module = core, .name = "is_unsigned", .mode = .dual, .arity = 1, .ret = .bool },
    .{ .id = .type_info, .module = meta, .name = "type_info", .mode = .dual, .arity = 1 },

    // ── evaluate-only: the comptime VM services these itself (no lowering, no
    // runtime form). `declare_type` / `register_type` mint into the type table;
    // the compiler.sx set answers from, or acts on, the build state.
    .{ .id = .raw_declare_type, .module = meta, .name = "raw_declare_type", .mode = .evaluate, .arity = 1 },
    .{ .id = .raw_register_type, .module = meta, .name = "raw_register_type", .mode = .evaluate, .arity = 3 },
    .{ .id = .c_object_paths, .module = compiler, .name = "c_object_paths", .mode = .evaluate, .arity = 0 },
    .{ .id = .link_libraries, .module = compiler, .name = "link_libraries", .mode = .evaluate, .arity = 0 },
    .{ .id = .emit_object, .module = compiler, .name = "emit_object", .mode = .evaluate, .arity = 0 },
    .{ .id = .link, .module = compiler, .name = "link", .mode = .evaluate, .arity = 6 },
    .{ .id = .build_output, .module = compiler, .name = "build_output", .mode = .evaluate, .arity = 0 },
    .{ .id = .build_target, .module = compiler, .name = "build_target", .mode = .evaluate, .arity = 0 },
    .{ .id = .build_frameworks, .module = compiler, .name = "build_frameworks", .mode = .evaluate, .arity = 0 },
    .{ .id = .build_flags, .module = compiler, .name = "build_flags", .mode = .evaluate, .arity = 0 },

    // ── build.sx: the BuildOptions DSL. Every one is a hook in compiler_hooks.zig
    // acting on the threaded BuildConfig. `self: BuildOptions` is an opaque
    // zero-field handle, so the ufcs receiver counts toward arity.
    .{ .id = .build_options, .module = build, .name = "build_options", .mode = .evaluate, .arity = 0 },
    .{ .id = .add_link_flag, .module = build, .name = "add_link_flag", .mode = .evaluate, .arity = 2 },
    .{ .id = .add_framework, .module = build, .name = "add_framework", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_output_path, .module = build, .name = "set_output_path", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_wasm_shell, .module = build, .name = "set_wasm_shell", .mode = .evaluate, .arity = 2 },
    .{ .id = .add_asset_dir, .module = build, .name = "add_asset_dir", .mode = .evaluate, .arity = 3 },
    .{ .id = .asset_dir_count, .module = build, .name = "asset_dir_count", .mode = .evaluate, .arity = 1 },
    .{ .id = .asset_dir_src_at, .module = build, .name = "asset_dir_src_at", .mode = .evaluate, .arity = 2 },
    .{ .id = .asset_dir_dest_at, .module = build, .name = "asset_dir_dest_at", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_post_link_module, .module = build, .name = "set_post_link_module", .mode = .evaluate, .arity = 2 },
    .{ .id = .binary_path, .module = build, .name = "binary_path", .mode = .evaluate, .arity = 1 },
    .{ .id = .set_bundle_path, .module = build, .name = "set_bundle_path", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_bundle_id, .module = build, .name = "set_bundle_id", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_codesign_identity, .module = build, .name = "set_codesign_identity", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_provisioning_profile, .module = build, .name = "set_provisioning_profile", .mode = .evaluate, .arity = 2 },
    .{ .id = .bundle_path, .module = build, .name = "bundle_path", .mode = .evaluate, .arity = 1 },
    .{ .id = .bundle_id, .module = build, .name = "bundle_id", .mode = .evaluate, .arity = 1 },
    .{ .id = .codesign_identity, .module = build, .name = "codesign_identity", .mode = .evaluate, .arity = 1 },
    .{ .id = .provisioning_profile, .module = build, .name = "provisioning_profile", .mode = .evaluate, .arity = 1 },
    .{ .id = .target_triple, .module = build, .name = "target_triple", .mode = .evaluate, .arity = 1 },
    .{ .id = .is_macos, .module = build, .name = "is_macos", .mode = .evaluate, .arity = 1 },
    .{ .id = .is_ios, .module = build, .name = "is_ios", .mode = .evaluate, .arity = 1 },
    .{ .id = .is_ios_device, .module = build, .name = "is_ios_device", .mode = .evaluate, .arity = 1 },
    .{ .id = .is_ios_simulator, .module = build, .name = "is_ios_simulator", .mode = .evaluate, .arity = 1 },
    .{ .id = .is_android, .module = build, .name = "is_android", .mode = .evaluate, .arity = 1 },
    .{ .id = .framework_count, .module = build, .name = "framework_count", .mode = .evaluate, .arity = 1 },
    .{ .id = .framework_at, .module = build, .name = "framework_at", .mode = .evaluate, .arity = 2 },
    .{ .id = .framework_path_count, .module = build, .name = "framework_path_count", .mode = .evaluate, .arity = 1 },
    .{ .id = .framework_path_at, .module = build, .name = "framework_path_at", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_manifest_path, .module = build, .name = "set_manifest_path", .mode = .evaluate, .arity = 2 },
    .{ .id = .set_keystore_path, .module = build, .name = "set_keystore_path", .mode = .evaluate, .arity = 2 },
    .{ .id = .manifest_path, .module = build, .name = "manifest_path", .mode = .evaluate, .arity = 1 },
    .{ .id = .keystore_path, .module = build, .name = "keystore_path", .mode = .evaluate, .arity = 1 },
    .{ .id = .jni_main_count, .module = build, .name = "jni_main_count", .mode = .evaluate, .arity = 1 },
    .{ .id = .jni_main_runtime_path_at, .module = build, .name = "jni_main_runtime_path_at", .mode = .evaluate, .arity = 2 },
    .{ .id = .jni_main_java_source_at, .module = build, .name = "jni_main_java_source_at", .mode = .evaluate, .arity = 2 },
    .{ .id = .on_build, .module = build, .name = "on_build", .mode = .evaluate, .arity = 1 },

    // ── math: lowered to a `call_builtin` the LLVM backend maps to an
    // intrinsic / libm call. The VM has no arm — a `#run sqrt(x)` bails loudly
    // ("comptime init failed: sqrt") rather than silently folding.
    .{ .id = .sqrt, .module = scalar, .name = "sqrt", .mode = .lower, .arity = 1 },
    .{ .id = .sin, .module = scalar, .name = "sin", .mode = .lower, .arity = 1 },
    .{ .id = .cos, .module = scalar, .name = "cos", .mode = .lower, .arity = 1 },
    .{ .id = .floor, .module = scalar, .name = "floor", .mode = .lower, .arity = 1 },

    // ── atomics: lowered to dedicated atomic IR ops. `.lower`, yet they DO
    // evaluate at comptime — the VM interprets the ops they lower to.
    .{ .id = .atomic_load, .module = atomic, .name = "atomic_load", .mode = .lower, .arity = 3 },
    .{ .id = .atomic_store, .module = atomic, .name = "atomic_store", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fetch_add, .module = atomic, .name = "atomic_fetch_add", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fetch_sub, .module = atomic, .name = "atomic_fetch_sub", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fetch_and, .module = atomic, .name = "atomic_fetch_and", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fetch_or, .module = atomic, .name = "atomic_fetch_or", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fetch_xor, .module = atomic, .name = "atomic_fetch_xor", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fetch_min, .module = atomic, .name = "atomic_fetch_min", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fetch_max, .module = atomic, .name = "atomic_fetch_max", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_swap, .module = atomic, .name = "atomic_swap", .mode = .lower, .arity = 4 },
    .{ .id = .atomic_fence, .module = atomic, .name = "atomic_fence", .mode = .lower, .arity = 1 },
    .{ .id = .atomic_cmpxchg, .module = atomic, .name = "atomic_cmpxchg", .mode = .lower, .arity = 6 },
    .{ .id = .atomic_cmpxchg_weak, .module = atomic, .name = "atomic_cmpxchg_weak", .mode = .lower, .arity = 6 },
};

/// Look up an intrinsic by its declared name. `source_file` is the declaration's
/// source path; when non-null it must match the entry's module (the binding key
/// is (module, name), not the bare name).
///
/// Returns null when the name is not a registered intrinsic — callers surface
/// that as a diagnostic against the declaration span, never a fallback.
pub fn find(name: []const u8, source_file: ?[]const u8) ?*const Entry {
    for (&entries) |*e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (source_file) |sf| if (!std.mem.endsWith(u8, sf, e.module)) continue;
        return e;
    }
    return null;
}

/// Dispatch key for a CALL SITE: the declared name alone. Sound because intrinsic
/// names are globally unique across the registry (asserted by
/// `intrinsics.test.zig`), and because the (module, name) binding key was already
/// enforced at the declaration — a `size_of` reaching a call site is std/core.sx's
/// `size_of` or it never got declared.
///
/// Returns null for any name that is not a registered intrinsic, including the
/// bare names the compiler recognizes without a declaration (`cast`, `type_eq`,
/// `has_impl`, …). Those are keywords, handled by their own recognizers.
pub fn findByName(name: []const u8) ?Id {
    for (&entries) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e.id;
    }
    return null;
}

/// Look up by stable id. Total — every `Id` has an entry (enforced by
/// `intrinsics.test.zig`).
pub fn byId(id: Id) *const Entry {
    for (&entries) |*e| {
        if (e.id == id) return e;
    }
    unreachable; // an Id with no entry is a registry bug, caught by the tests
}
