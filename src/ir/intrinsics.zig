//! The intrinsic registry — the single source of truth for every sx declaration
//! whose implementation lives in the compiler:
//!
//!     @sizeOf :: ($T: Type) -> i64;
//!
//! This table IS, at once: the allow-list (an `intrinsic` declaration whose
//! binding key is absent is a load-time diagnostic, never a dlsym or runtime
//! fallback), the signature validator, the lowering-dispatch key, the
//! comptime-VM-dispatch key, and the audit source that `intrinsics.test.zig`
//! checks against the library sources.
//!
//! **Binding key = (module, name).** The declaring module is part of the
//! identity: `@sizeOf` is an intrinsic *because std/core.sx declares it*, not
//! because the name is magic. A same-named declaration in another module is a
//! different function and gets no intrinsic dispatch.
//!
//! **Not in this table** — two categories that are deliberately absent, so that
//! "every entry has a handler, every `intrinsic` declaration has an entry" holds
//! with no exemption list:
//!
//!   * Language primitives (`string`, `@Vector`) — resolved by name by the type
//!     system (`type_resolver` / `type_bridge`) like `int` / `bool` / `f64`.
//!     They are declared nowhere and are not call-dispatched.
//!   * Keywords (`cast`, `compile_error`, `__interp_print_frames`,
//!     `__trace_resolve_frame`) — bare names the compiler recognizes without
//!     any declaration.

const std = @import("std");
const types = @import("types.zig");
const TypeId = types.TypeId;

/// How an intrinsic call is dispatched. This describes DISPATCH, not
/// stage-availability — the two are independent. `@sqrt` and `atomicLoad` are
/// both `.lower`. The VM interprets the atomic ops `atomicLoad` lowers to,
/// and evaluates the `call_builtin` that `@sqrt` lowers to.
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
    @"@sizeOf",
    @"@alignOf",
    // ── std/core.sx — reflection ────────────────────────────────────────────
    @"@typeOf",
    @"@typeName",
    @"@typeInfo",
    structFieldValue,
    variantPayload,
    variantIndex,
    pointeeType,
    isFlags,
    @"@errorName",
    @"@errorPayload",
    @"@len",
    @"@field",
    @"@inner",
    @"@typeEq",
    @"@unbox",
    vectorLanes,
    @"__sx_variant_tag_width",
    anyElement,
    rawAnyData,
    rawMakeAny,
    // ── std/core.sx — the comptime compiler-API readers (evaluate-only) ─────
    rawIntern,
    rawTextOf,
    rawFindType,
    rawTypeKind,
    rawTypeName,
    rawFieldCount,
    rawFieldName,
    rawFieldType,
    rawVariantValue,
    rawPointerTo,
    // ── std/meta.sx ─────────────────────────────────────────────────────────
    rawDeclareType,
    rawRegisterType,
    // ── compiler.sx — the build-pipeline services (evaluate-only) ───────────
    cObjectPaths,
    linkLibraries,
    emitObject,
    link,
    buildOutput,
    buildTarget,
    buildFrameworks,
    buildFlags,
    // ── build.sx — the BuildOptions surface (evaluate-only) ─────────────────
    buildOptions,
    addLinkFlag,
    addFramework,
    setOutputPath,
    setWasmShell,
    addAssetDir,
    assetDirCount,
    assetDirSrcAt,
    assetDirDestAt,
    setPostLinkModule,
    binaryPath,
    setBundlePath,
    setBundleId,
    setCodesignIdentity,
    setProvisioningProfile,
    bundlePath,
    bundleId,
    codesignIdentity,
    provisioningProfile,
    targetTriple,
    isMacos,
    isIos,
    isIosDevice,
    isIosSimulator,
    isAndroid,
    frameworkCount,
    frameworkAt,
    frameworkPathCount,
    frameworkPathAt,
    setManifestPath,
    setKeystorePath,
    manifestPath,
    keystorePath,
    jniMainCount,
    jniMainRuntimePathAt,
    jniMainJavaSourceAt,
    onBuild,
    // ── math/scalar.sx ──────────────────────────────────────────────────────
    @"@sqrt",
    @"@sin",
    @"@cos",
    @"@floor",
    // ── std/atomic.sx ───────────────────────────────────────────────────────
    atomicLoad,
    atomicStore,
    atomicFetchAdd,
    atomicFetchSub,
    atomicFetchAnd,
    atomicFetchOr,
    atomicFetchXor,
    atomicFetchMin,
    atomicFetchMax,
    atomicSwap,
    atomicFence,
    atomicCmpxchg,
    atomicCmpxchgWeak,
    // std/core.sx declares these two; the `@` is part of the name.
    @"@volatileLoad",
    @"@volatileStore",
    @"@printf",
    @"@isComptime",
    @"@error",
    @"@vaStart",
    @"@vaArg",
    @"@vaCopy",
    @"@vaEnd",
    @"@envType",
    @"@envOf",
    @"@callPtr",
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
    /// `null` means the handler computes it, for one of two reasons: the result
    /// depends on an argument — the math intrinsics return their argument's type
    /// (`f32` in, `f32` out), the atomics return `T`, `@typeInfo` returns the
    /// `TypeInfo` it must look up in the type table — or the result is a type
    /// this field cannot spell, since only a builtin `TypeId` is a comptime
    /// value (`@inner` returns an interned `?any`). Callers that need a type for
    /// a null entry must ask the handler — there is no default to fall back on.
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
    .{ .id = .@"@sizeOf", .module = core, .name = "@sizeOf", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .@"@alignOf", .module = core, .name = "@alignOf", .mode = .lower, .arity = 1, .ret = .i64 },

    // ── reflection: folded at lowering when the type arg is static ──────────
    .{ .id = .@"@typeOf", .module = core, .name = "@typeOf", .mode = .lower, .arity = 1, .ret = .type_value },
    .{ .id = .structFieldValue, .module = core, .name = "structFieldValue", .mode = .lower, .arity = 2, .ret = .any },
    .{ .id = .variantPayload, .module = core, .name = "variantPayload", .mode = .lower, .arity = 2, .ret = .any },
    .{ .id = .variantIndex, .module = core, .name = "variantIndex", .mode = .lower, .arity = 2, .ret = .i64 },
    .{ .id = .pointeeType, .module = core, .name = "pointeeType", .mode = .lower, .arity = 1, .ret = .type_value },
    .{ .id = .isFlags, .module = core, .name = "isFlags", .mode = .lower, .arity = 1, .ret = .bool },
    .{ .id = .@"@errorName", .module = core, .name = "@errorName", .mode = .lower, .arity = 1, .ret = .string },
    .{ .id = .@"@errorPayload", .module = core, .name = "@errorPayload", .mode = .lower, .arity = 1, .ret = .any },
    .{ .id = .@"@len", .module = core, .name = "@len", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .@"@field", .module = core, .name = "@field", .mode = .lower, .arity = 2, .ret = .any },
    .{ .id = .@"@inner", .module = core, .name = "@inner", .mode = .lower, .arity = 1 },
    .{ .id = .@"@typeEq", .module = core, .name = "@typeEq", .mode = .lower, .arity = 2, .ret = .bool },
    .{ .id = .@"@unbox", .module = core, .name = "@unbox", .mode = .lower, .arity = 2 },
    .{ .id = .vectorLanes, .module = core, .name = "vectorLanes", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .@"__sx_variant_tag_width", .module = core, .name = "__sx_variant_tag_width", .mode = .lower, .arity = 1, .ret = .i64 },
    .{ .id = .anyElement, .module = core, .name = "anyElement", .mode = .lower, .arity = 3, .ret = .any },
    .{ .id = .rawAnyData, .module = core, .name = "rawAnyData", .mode = .lower, .arity = 1 },
    .{ .id = .rawMakeAny, .module = core, .name = "rawMakeAny", .mode = .lower, .arity = 2, .ret = .any },

    // ── the comptime compiler-API readers: the VM reads/mints into the string
    // pool and type table. Handles are bare u32 (see core.sx).
    .{ .id = .rawIntern, .module = core, .name = "rawIntern", .mode = .evaluate, .arity = 1 },
    .{ .id = .rawTextOf, .module = core, .name = "rawTextOf", .mode = .evaluate, .arity = 1 },
    .{ .id = .rawFindType, .module = core, .name = "rawFindType", .mode = .evaluate, .arity = 1 },
    .{ .id = .rawTypeKind, .module = core, .name = "rawTypeKind", .mode = .evaluate, .arity = 1 },
    .{ .id = .rawTypeName, .module = core, .name = "rawTypeName", .mode = .evaluate, .arity = 1 },
    .{ .id = .rawFieldCount, .module = core, .name = "rawFieldCount", .mode = .evaluate, .arity = 1 },
    .{ .id = .rawFieldName, .module = core, .name = "rawFieldName", .mode = .evaluate, .arity = 2 },
    .{ .id = .rawFieldType, .module = core, .name = "rawFieldType", .mode = .evaluate, .arity = 2 },
    .{ .id = .rawVariantValue, .module = core, .name = "rawVariantValue", .mode = .evaluate, .arity = 2 },
    .{ .id = .rawPointerTo, .module = core, .name = "rawPointerTo", .mode = .evaluate, .arity = 1 },

    // ── reflection with a VM arm: the type arg may only be known at eval time
    // (e.g. `args[i]` inside a builder body, carrying a `.type_tag(TypeId)`).
    .{ .id = .@"@typeName", .module = core, .name = "@typeName", .mode = .dual, .arity = 1, .ret = .string },
    .{ .id = .@"@typeInfo", .module = core, .name = "@typeInfo", .mode = .dual, .arity = 1 },

    // ── evaluate-only: the comptime VM services these itself (no lowering, no
    // runtime form). `declare_type` / `register_type` mint into the type table;
    // the compiler.sx set answers from, or acts on, the build state.
    .{ .id = .rawDeclareType, .module = meta, .name = "rawDeclareType", .mode = .evaluate, .arity = 1 },
    .{ .id = .rawRegisterType, .module = meta, .name = "rawRegisterType", .mode = .evaluate, .arity = 3 },
    .{ .id = .cObjectPaths, .module = compiler, .name = "cObjectPaths", .mode = .evaluate, .arity = 0 },
    .{ .id = .linkLibraries, .module = compiler, .name = "linkLibraries", .mode = .evaluate, .arity = 0 },
    .{ .id = .emitObject, .module = compiler, .name = "emitObject", .mode = .evaluate, .arity = 0 },
    .{ .id = .link, .module = compiler, .name = "link", .mode = .evaluate, .arity = 6 },
    .{ .id = .buildOutput, .module = compiler, .name = "buildOutput", .mode = .evaluate, .arity = 0 },
    .{ .id = .buildTarget, .module = compiler, .name = "buildTarget", .mode = .evaluate, .arity = 0 },
    .{ .id = .buildFrameworks, .module = compiler, .name = "buildFrameworks", .mode = .evaluate, .arity = 0 },
    .{ .id = .buildFlags, .module = compiler, .name = "buildFlags", .mode = .evaluate, .arity = 0 },

    // ── build.sx: the BuildOptions DSL. Every one is a hook in compiler_hooks.zig
    // acting on the threaded BuildConfig. `self: BuildOptions` is an opaque
    // zero-field handle, so the ufcs receiver counts toward arity.
    .{ .id = .buildOptions, .module = build, .name = "buildOptions", .mode = .evaluate, .arity = 0 },
    .{ .id = .addLinkFlag, .module = build, .name = "addLinkFlag", .mode = .evaluate, .arity = 2 },
    .{ .id = .addFramework, .module = build, .name = "addFramework", .mode = .evaluate, .arity = 2 },
    .{ .id = .setOutputPath, .module = build, .name = "setOutputPath", .mode = .evaluate, .arity = 2 },
    .{ .id = .setWasmShell, .module = build, .name = "setWasmShell", .mode = .evaluate, .arity = 2 },
    .{ .id = .addAssetDir, .module = build, .name = "addAssetDir", .mode = .evaluate, .arity = 3 },
    .{ .id = .assetDirCount, .module = build, .name = "assetDirCount", .mode = .evaluate, .arity = 1 },
    .{ .id = .assetDirSrcAt, .module = build, .name = "assetDirSrcAt", .mode = .evaluate, .arity = 2 },
    .{ .id = .assetDirDestAt, .module = build, .name = "assetDirDestAt", .mode = .evaluate, .arity = 2 },
    .{ .id = .setPostLinkModule, .module = build, .name = "setPostLinkModule", .mode = .evaluate, .arity = 2 },
    .{ .id = .binaryPath, .module = build, .name = "binaryPath", .mode = .evaluate, .arity = 1 },
    .{ .id = .setBundlePath, .module = build, .name = "setBundlePath", .mode = .evaluate, .arity = 2 },
    .{ .id = .setBundleId, .module = build, .name = "setBundleId", .mode = .evaluate, .arity = 2 },
    .{ .id = .setCodesignIdentity, .module = build, .name = "setCodesignIdentity", .mode = .evaluate, .arity = 2 },
    .{ .id = .setProvisioningProfile, .module = build, .name = "setProvisioningProfile", .mode = .evaluate, .arity = 2 },
    .{ .id = .bundlePath, .module = build, .name = "bundlePath", .mode = .evaluate, .arity = 1 },
    .{ .id = .bundleId, .module = build, .name = "bundleId", .mode = .evaluate, .arity = 1 },
    .{ .id = .codesignIdentity, .module = build, .name = "codesignIdentity", .mode = .evaluate, .arity = 1 },
    .{ .id = .provisioningProfile, .module = build, .name = "provisioningProfile", .mode = .evaluate, .arity = 1 },
    .{ .id = .targetTriple, .module = build, .name = "targetTriple", .mode = .evaluate, .arity = 1 },
    .{ .id = .isMacos, .module = build, .name = "isMacos", .mode = .evaluate, .arity = 1 },
    .{ .id = .isIos, .module = build, .name = "isIos", .mode = .evaluate, .arity = 1 },
    .{ .id = .isIosDevice, .module = build, .name = "isIosDevice", .mode = .evaluate, .arity = 1 },
    .{ .id = .isIosSimulator, .module = build, .name = "isIosSimulator", .mode = .evaluate, .arity = 1 },
    .{ .id = .isAndroid, .module = build, .name = "isAndroid", .mode = .evaluate, .arity = 1 },
    .{ .id = .frameworkCount, .module = build, .name = "frameworkCount", .mode = .evaluate, .arity = 1 },
    .{ .id = .frameworkAt, .module = build, .name = "frameworkAt", .mode = .evaluate, .arity = 2 },
    .{ .id = .frameworkPathCount, .module = build, .name = "frameworkPathCount", .mode = .evaluate, .arity = 1 },
    .{ .id = .frameworkPathAt, .module = build, .name = "frameworkPathAt", .mode = .evaluate, .arity = 2 },
    .{ .id = .setManifestPath, .module = build, .name = "setManifestPath", .mode = .evaluate, .arity = 2 },
    .{ .id = .setKeystorePath, .module = build, .name = "setKeystorePath", .mode = .evaluate, .arity = 2 },
    .{ .id = .manifestPath, .module = build, .name = "manifestPath", .mode = .evaluate, .arity = 1 },
    .{ .id = .keystorePath, .module = build, .name = "keystorePath", .mode = .evaluate, .arity = 1 },
    .{ .id = .jniMainCount, .module = build, .name = "jniMainCount", .mode = .evaluate, .arity = 1 },
    .{ .id = .jniMainRuntimePathAt, .module = build, .name = "jniMainRuntimePathAt", .mode = .evaluate, .arity = 2 },
    .{ .id = .jniMainJavaSourceAt, .module = build, .name = "jniMainJavaSourceAt", .mode = .evaluate, .arity = 2 },
    .{ .id = .onBuild, .module = build, .name = "onBuild", .mode = .evaluate, .arity = 1 },

    // ── math: lowered to a `call_builtin` the LLVM backend maps to an
    // intrinsic / libm call. The VM evaluates the same ops (`@sqrt` / `@sin` /
    // `@cos` / `@floor`), so `@run @sqrt(x)` is a compile-time constant.
    .{ .id = .@"@sqrt", .module = scalar, .name = "@sqrt", .mode = .lower, .arity = 1 },
    .{ .id = .@"@sin", .module = scalar, .name = "@sin", .mode = .lower, .arity = 1 },
    .{ .id = .@"@cos", .module = scalar, .name = "@cos", .mode = .lower, .arity = 1 },
    .{ .id = .@"@floor", .module = scalar, .name = "@floor", .mode = .lower, .arity = 1 },

    // ── atomics: lowered to dedicated atomic IR ops. `.lower`, yet they DO
    // evaluate at comptime — the VM interprets the ops they lower to.
    .{ .id = .atomicLoad, .module = atomic, .name = "atomicLoad", .mode = .lower, .arity = 3 },
    .{ .id = .atomicStore, .module = atomic, .name = "atomicStore", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFetchAdd, .module = atomic, .name = "atomicFetchAdd", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFetchSub, .module = atomic, .name = "atomicFetchSub", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFetchAnd, .module = atomic, .name = "atomicFetchAnd", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFetchOr, .module = atomic, .name = "atomicFetchOr", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFetchXor, .module = atomic, .name = "atomicFetchXor", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFetchMin, .module = atomic, .name = "atomicFetchMin", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFetchMax, .module = atomic, .name = "atomicFetchMax", .mode = .lower, .arity = 4 },
    .{ .id = .atomicSwap, .module = atomic, .name = "atomicSwap", .mode = .lower, .arity = 4 },
    .{ .id = .atomicFence, .module = atomic, .name = "atomicFence", .mode = .lower, .arity = 1 },
    .{ .id = .atomicCmpxchg, .module = atomic, .name = "atomicCmpxchg", .mode = .lower, .arity = 6 },
    .{ .id = .atomicCmpxchgWeak, .module = atomic, .name = "atomicCmpxchgWeak", .mode = .lower, .arity = 6 },

    // Lowered to the volatile load/store IR ops. The access is non-atomic and
    // carries no ordering, so — like the atomics — the VM interprets it
    // directly and `@run` sees an ordinary access. The `@` is part of the name:
    // these are compiler-maintained contracts (contracts.zig) as well as
    // intrinsics.
    .{ .id = .@"@volatileLoad", .module = core, .name = "@volatileLoad", .mode = .lower, .arity = 2 },
    .{ .id = .@"@volatileStore", .module = core, .name = "@volatileStore", .mode = .lower, .arity = 3 },

    // The persist primitives. `@envType` folds to a type, so it also answers
    // in a type-argument slot; `@envOf` carries its argument's env through at
    // that type, and `@callPtr` resolves — or synthesizes — the trampoline.
    .{ .id = .@"@envType", .module = core, .name = "@envType", .mode = .lower, .arity = 1, .ret = .type_value },
    .{ .id = .@"@envOf", .module = core, .name = "@envOf", .mode = .lower, .arity = 1 },
    .{ .id = .@"@callPtr", .module = core, .name = "@callPtr", .mode = .lower, .arity = 1 },

    // Expanded at lowering into calls to the emission primitives core.sx
    // declares beside it — one per format segment, one per argument. The
    // expansion is ordinary sx calls, so `@run` renders through the same
    // primitives the runtime does. Arity 2 is the declaration's `($fmt, ..$args)`;
    // the call site takes one argument per `{}`.
    .{ .id = .@"@printf", .module = core, .name = "@printf", .mode = .lower, .arity = 2, .ret = .void },

    // Lowered to the `is_comptime` IR op, which the two backends answer
    // differently: the VM reads `true`, compiled code folds `false`. One lowered
    // body serves both stages, so the answer cannot be folded here.
    .{ .id = .@"@isComptime", .module = core, .name = "@isComptime", .mode = .lower, .arity = 0, .ret = .bool },
    .{ .id = .@"@error", .module = core, .name = "@error", .mode = .lower, .arity = 2 },

    // Lowered to the four cursor IR ops. A cursor walks arguments a real call
    // frame delivered, so there is no VM arm: `@run` over one bails loudly
    // rather than inventing a frame to read.
    .{ .id = .@"@vaStart", .module = core, .name = "@vaStart", .mode = .lower, .arity = 1, .ret = .void },
    .{ .id = .@"@vaArg", .module = core, .name = "@vaArg", .mode = .lower, .arity = 2 },
    .{ .id = .@"@vaCopy", .module = core, .name = "@vaCopy", .mode = .lower, .arity = 2, .ret = .void },
    .{ .id = .@"@vaEnd", .module = core, .name = "@vaEnd", .mode = .lower, .arity = 1, .ret = .void },
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
/// enforced at the declaration — a `@sizeOf` reaching a call site is std/core.sx's
/// `@sizeOf` or it never got declared.
///
/// Returns null for any name that is not a registered intrinsic, including the
/// bare names the compiler recognizes without a declaration (`cast`,
/// `compile_error`, …). Those are keywords, handled by their own recognizers.
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
