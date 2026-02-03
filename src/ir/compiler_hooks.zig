const std = @import("std");
const Allocator = std.mem.Allocator;
const inst = @import("inst.zig");
const FuncId = inst.FuncId;

// ── BuildConfig ─────────────────────────────────────────────────────────
// Mutable build configuration accumulated by the sx-driven build pipeline
// (`default_pipeline` / an `on_build` callback) running on the comptime VM,
// which reads/writes these fields via the `intrinsic` primitives.

/// `(src_dir, dest_in_bundle)` pair recorded by
/// `BuildOptions.add_asset_dir(src, dest)`. The sx bundler walks the
/// list and recursively copies each `src` directory into the bundle
/// at the relative `dest` path (e.g. `("assets", "assets")` copies
/// `./assets/` to `<bundle>/assets/`). Android's Week-7 APK path will
/// zip the same pairs into the unaligned APK.
pub const AssetDir = struct {
    src: []const u8,
    dest: []const u8,
};

pub const BuildConfig = struct {
    link_flags: std.ArrayList([]const u8) = .empty,
    frameworks: std.ArrayList([]const u8) = .empty,
    asset_dirs: std.ArrayList(AssetDir) = .empty,
    output_path: ?[]const u8 = null,
    wasm_shell_path: ?[]const u8 = null,

    /// Post-link callback registered via
    /// `BuildOptions.set_post_link_callback(fn)`. When set, the
    /// compiler re-enters the IR interpreter after `target.link()`
    /// and invokes this function with no args. A `false` return is
    /// treated as a build failure.
    post_link_callback_fn: ?FuncId = null,
    /// True when the post-link callback was registered via `on_build(cb)` (the
    /// Phase 5 form, `cb: (opt: BuildOptions) -> bool`) rather than the legacy
    /// `set_post_link_callback(cb)` (`cb: () -> bool`). When set, the compiler
    /// invokes the callback with the opaque `BuildOptions` handle as its arg.
    post_link_takes_options: bool = false,
    /// Alternative to `post_link_callback_fn`: the qualified name of
    /// a module whose `bundle_main` function should be called
    /// post-link.
    post_link_module: ?[]const u8 = null,

    /// Path of the freshly-linked binary, populated by `main.zig`
    /// right before the post-link callback runs. The sx-side bundler
    /// reads this via `binary_path()` to know what file to wrap.
    binary_path: ?[]const u8 = null,

    // Apple `.app` / Android `.apk` bundling parameters. Set either
    // by the sx-side `BuildOptions.set_bundle_*` methods (preferred)
    // or by main.zig from CLI flags (transitional fallback). The sx
    // bundler reads them via the matching accessor methods.
    bundle_path: ?[]const u8 = null,
    bundle_id: ?[]const u8 = null,
    codesign_identity: ?[]const u8 = null,
    provisioning_profile: ?[]const u8 = null,

    /// Target triple as supplied to `--target` (canonicalized).
    /// Populated by main.zig before the post-link callback runs so the
    /// sx bundler can switch on iOS vs. macOS vs. simulator.
    target_triple: ?[]const u8 = null,

    /// C companion object files (`#import c { #source ... }`, compiled to `.o`)
    /// and `#library` link names, forwarded by main.zig before the post-link
    /// callback so the sx-driven build pipeline (Phase 5) can read them via the
    /// `c_object_paths()` / `link_libraries()` compiler primitives and pass them
    /// to `link`. Slices reference compiler-owned memory that outlives the
    /// callback.
    c_object_paths: []const []const u8 = &.{},
    link_libraries: []const []const u8 = &.{},

    /// The fully-merged link flags (CLI `extra_link_flags` + `#run` build-block
    /// flags), forwarded by main.zig. The sx driver reads them via `build_flags()`
    /// and passes them to `link`. (Distinct from `link_flags`, which holds only
    /// the `#run`-accumulated subset.)
    merged_link_flags: []const []const u8 = &.{},

    /// Host-installed callbacks for build-pipeline ACTIONS the comptime VM can't
    /// perform itself (it can't depend on the driver — `core`/`main`/`target`).
    /// main.zig installs this before the post-link callback; the VM's `link`
    /// primitive dispatches through it. Null outside a post-link build (a `link`
    /// call then bails loudly — it's a post-codegen-only action).
    build_hooks: ?*const BuildHooks = null,

    /// Frameworks the binary links against (`-framework` names) and
    /// the search paths to look them up in (`-F` directories), forwarded
    /// from the link step so the sx bundler can embed them into
    /// `<bundle>/Frameworks/`.
    target_frameworks: []const []const u8 = &.{},
    target_framework_paths: []const []const u8 = &.{},

    /// User-supplied `AndroidManifest.xml` override (`--manifest <path>`
    /// or `BuildOptions.set_manifest_path("...")`). When null, the
    /// Android bundler synthesizes a default manifest.
    manifest_path: ?[]const u8 = null,
    /// User-supplied debug keystore path (`--keystore <path>` or
    /// `BuildOptions.set_keystore_path("...")`). When null, the Android
    /// bundler uses `$HOME/.android/debug.keystore` (auto-generated on
    /// first use via `keytool`).
    keystore_path: ?[]const u8 = null,

    /// `#jni_main #jni_class("path") { ... }` decls discovered during
    /// lowering, paired with their pre-rendered Java source. The
    /// Android bundler writes each entry to
    /// `<stage>/java/<pkg>/<Class>.java`, compiles via `javac` + `d8`,
    /// and bundles the resulting `classes.dex` into the APK. Slices
    /// reference compiler-owned memory that outlives the post-link
    /// callback.
    jni_main_runtime_paths: []const []const u8 = &.{},
    jni_main_java_sources: []const []const u8 = &.{},

    pub fn deinit(self: *BuildConfig, alloc: Allocator) void {
        self.link_flags.deinit(alloc);
        self.frameworks.deinit(alloc);
        self.asset_dirs.deinit(alloc);
    }
};

/// Host-installed callbacks for build-pipeline ACTIONS the comptime VM dispatches
/// but can't perform itself (it must not depend on the driver: `core`/`main`/
/// `target`). main.zig builds the concrete `ctx` + functions and points
/// `BuildConfig.build_hooks` at it before invoking the post-link callback. The
/// build callback is NOT fallible (Phase 5 decision) — a failed action returns an
/// error here and the VM surfaces it as a hard build error.
pub const BuildHooks = struct {
    ctx: *anyopaque,
    /// Verify + emit the codegen'd module to its object file; return the path
    /// (ctx-owned). The `emit_object()` primitive — an ACTION, since the driver
    /// no longer auto-emits (everything is sx-driven via `default_pipeline`).
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

