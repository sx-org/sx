const std = @import("std");
const builtin = @import("builtin");
const llvm = @import("llvm_api.zig");
const c = llvm.c;
const zig_backend = @import("zig_backend.zig");

/// One `#jni_main #jni_class("...")` declaration's Java-source emission.
/// Populated by lowering and surfaced to the sx Android bundler in
/// `library/modules/platform/bundle.sx` via `BuildConfig.jni_main_*`,
/// which writes a `.java` file under `<stage>/java/<pkg>/<Cls>.java`,
/// compiles via `javac`, dexes via `d8`, and bundles the resulting
/// `classes.dex` into the APK.
pub const JniMainEmission = struct {
    /// runtime_path of the source decl (e.g. "co/swipelab/sxmain/SxApp").
    /// Splits into package + class name for `<stage>/java/<pkg>/<Class>.java`.
    runtime_path: []const u8,
    /// Pre-rendered Java source bytes (from `jni_java_emit.emitJavaSource`).
    java_source: []const u8,
};

pub const TargetConfig = struct {
    /// Target triple (e.g. "aarch64-apple-darwin"). Null = host default.
    triple: ?[*:0]const u8 = null,
    /// CPU name (e.g. "generic", "apple-m1"). Null = "generic".
    cpu: ?[*:0]const u8 = null,
    /// CPU features string (e.g. "+avx2"). Null = "".
    features: ?[*:0]const u8 = null,
    /// Optimization level.
    opt_level: OptLevel = .default,
    /// Library search paths (-L flags).
    lib_paths: []const []const u8 = &.{},
    /// Framework search paths (-F flags). Apple-only.
    framework_paths: []const []const u8 = &.{},
    /// Output path override.
    output_path: ?[]const u8 = null,
    /// Linker command (null = "cc" on Unix, "link.exe" on Windows).
    linker: ?[]const u8 = null,
    /// Sysroot for cross-compilation (passed as --sysroot to linker).
    sysroot: ?[]const u8 = null,
    /// Extra flags passed through to the linker (e.g. Emscripten -s flags).
    extra_link_flags: []const []const u8 = &.{},
    /// Custom WASM shell template path (overrides the built-in template).
    wasm_shell_path: ?[]const u8 = null,
    /// Path to a `.app` bundle directory to produce (iOS/macOS). When set, the
    /// linker output is moved into the bundle alongside a generated Info.plist
    /// and ad-hoc signed for simulator runs.
    bundle_path: ?[]const u8 = null,
    /// CFBundleIdentifier for the bundle (e.g. "co.swipelab.sxhello").
    /// Required when `bundle_path` is set. On Android, doubles as the
    /// AndroidManifest package="..." attribute.
    bundle_id: ?[]const u8 = null,
    /// Path to a `.apk` file to produce (Android). When set, the linked
    /// `.so` is wrapped into a debug-signed APK ready for `adb install`.
    apk_path: ?[]const u8 = null,
    /// Custom AndroidManifest.xml path. When null, a minimal NativeActivity
    /// manifest is generated from `bundle_id`.
    manifest_path: ?[]const u8 = null,
    /// Debug keystore for APK signing. Defaults to `~/.android/debug.keystore`.
    keystore_path: ?[]const u8 = null,
    /// Codesigning identity (e.g. `"Apple Development: Alex (TEAMID)"` or a
    /// SHA-1 fingerprint from `security find-identity -p codesigning`).
    /// When null, ad-hoc signs with `-` (sufficient for simulator, not device).
    codesign_identity: ?[]const u8 = null,
    /// Path to a `.mobileprovision` to embed as `embedded.mobileprovision`.
    /// Required for real-device builds.
    provisioning_profile: ?[]const u8 = null,
    /// Path to an entitlements plist. When null and `provisioning_profile`
    /// is set, the entitlements are auto-extracted from the profile.
    entitlements_path: ?[]const u8 = null,
    /// True when emitting an ahead-of-time binary (`sx build`), false for
    /// in-process JIT (`sx run`). Used by emit_llvm to gate code that only
    /// makes sense for a standalone executable — e.g. the macOS bundle
    /// `chdir` shouldn't run in JIT mode because it would mutate the host
    /// sx process's CWD.
    is_aot: bool = false,
    /// Keep the DWARF-bearing object file after linking (`--emit-obj`) so a
    /// debugger can step the binary: macOS resolves via the debug map → the
    /// `.o`; Linux carries DWARF in the binary directly. Implies `-O0` unless
    /// `--opt` is given explicitly (DWARF is only emitted at opt none/less).
    /// The object is kept at `.sx-tmp/main.o` (its link-time path, so the
    /// debug map resolves when lldb is run from the project root).
    emit_obj: bool = false,
    /// Self-contained link backend (bundled `zig cc`). `.auto` uses it when a
    /// `zig` is discoverable, the target is Linux, and no explicit `--linker`
    /// was given; `.on` forces it (error if no zig / non-Linux target); `.off`
    /// uses the system `cc`. See design/bundled-zig-link-backend-design.md.
    self_contained: SelfContained = .auto,

    pub const SelfContained = enum { auto, on, off };

    pub const OptLevel = enum {
        none,
        less,
        default,
        aggressive,

        pub fn toLLVM(self: OptLevel) c.LLVMCodeGenOptLevel {
            return switch (self) {
                .none => c.LLVMCodeGenLevelNone,
                .less => c.LLVMCodeGenLevelLess,
                .default => c.LLVMCodeGenLevelDefault,
                .aggressive => c.LLVMCodeGenLevelAggressive,
            };
        }

        /// LLVM's middle-end optimization pipeline. The target-machine codegen
        /// level above only tunes instruction selection; non-O0 builds also need
        /// a PassBuilder pipeline for inlining, scalar simplification, vectorization,
        /// dead-code elimination, and the other language-independent IR passes.
        pub fn toLLVMPassPipeline(self: OptLevel) ?[:0]const u8 {
            return switch (self) {
                .none => null,
                .less => "default<O1>",
                .default => "default<O2>",
                .aggressive => "default<O3>",
            };
        }

        /// Keep C sources brought in through `#import c` at the same optimization
        /// level as the sx translation unit.
        pub fn toClangFlag(self: OptLevel) [:0]const u8 {
            return switch (self) {
                .none => "-O0",
                .less => "-O1",
                .default => "-O2",
                .aggressive => "-O3",
            };
        }
    };

    /// Check if target triple indicates aarch64/arm64 (runtime check, not comptime).
    pub fn isAarch64(self: TargetConfig) bool {
        return self.tripleHasPrefix("aarch64", "arm64");
    }

    /// Check if target triple indicates x86_64/x86-64.
    pub fn isX86_64(self: TargetConfig) bool {
        return self.tripleHasPrefix("x86_64", "x86-64");
    }

    /// Check if target triple indicates Windows (contains "windows" or "win32").
    pub fn isWindows(self: TargetConfig) bool {
        return self.tripleContains("windows") or self.tripleContains("win32");
    }

    /// Check if target triple indicates WebAssembly (wasm32 or wasm64).
    pub fn isWasm(self: TargetConfig) bool {
        return self.tripleHasPrefix("wasm32", "wasm64");
    }

    /// Check if target triple indicates wasm32 specifically (4-byte pointers, i32 size_t).
    pub fn isWasm32(self: TargetConfig) bool {
        return self.tripleHasPrefix("wasm32", "wasm32");
    }

    /// Check if target triple indicates wasm64 specifically (8-byte pointers, i64 size_t).
    pub fn isWasm64(self: TargetConfig) bool {
        return self.tripleHasPrefix("wasm64", "wasm64");
    }

    /// Check if target triple indicates macOS/Darwin (does not match iOS).
    pub fn isMacOS(self: TargetConfig) bool {
        if (self.isIOS()) return false;
        return self.tripleContains("darwin") or self.tripleContains("macos");
    }

    /// Check if target triple indicates iOS (device or simulator).
    pub fn isIOS(self: TargetConfig) bool {
        return self.tripleContains("-apple-ios");
    }

    /// Check if target triple indicates the iOS Simulator.
    pub fn isIOSSimulator(self: TargetConfig) bool {
        return self.isIOS() and self.tripleContains("simulator");
    }

    /// Check if target triple indicates a real iOS device (not Simulator).
    pub fn isIOSDevice(self: TargetConfig) bool {
        return self.isIOS() and !self.tripleContains("simulator");
    }

    /// Check if target triple indicates Linux (NOT Android — Android uses
    /// "linux-android" too but isAndroid() must take precedence).
    pub fn isLinux(self: TargetConfig) bool {
        if (self.isAndroid()) return false;
        return self.tripleContains("linux");
    }

    /// Check if target triple indicates Android (e.g. aarch64-linux-android21).
    pub fn isAndroid(self: TargetConfig) bool {
        return self.tripleContains("android");
    }

    /// Check if target triple indicates Emscripten (contains "emscripten").
    pub fn isEmscripten(self: TargetConfig) bool {
        return self.tripleContains("emscripten");
    }

    fn tripleHasPrefix(self: TargetConfig, prefix1: []const u8, prefix2: []const u8) bool {
        if (self.triple) |t| {
            const span = std.mem.span(t);
            return std.mem.startsWith(u8, span, prefix1) or std.mem.startsWith(u8, span, prefix2);
        }
        const dt = c.LLVMGetDefaultTargetTriple();
        defer c.LLVMDisposeMessage(dt);
        const span = std.mem.span(dt);
        return std.mem.startsWith(u8, span, prefix1) or std.mem.startsWith(u8, span, prefix2);
    }

    fn tripleContains(self: TargetConfig, needle: []const u8) bool {
        if (self.triple) |t| {
            return std.mem.indexOf(u8, std.mem.span(t), needle) != null;
        }
        const dt = c.LLVMGetDefaultTargetTriple();
        defer c.LLVMDisposeMessage(dt);
        return std.mem.indexOf(u8, std.mem.span(dt), needle) != null;
    }

    pub fn getCpu(self: TargetConfig) [*:0]const u8 {
        return self.cpu orelse "generic";
    }

    pub fn getFeatures(self: TargetConfig) [*:0]const u8 {
        return self.features orelse "";
    }

    pub fn getLinker(self: TargetConfig) []const u8 {
        return self.linker orelse "cc";
    }

    /// True when this target is in scope for the bundled-`zig` backend:
    /// the three desktop OSes (macOS, Linux, Windows). iOS/Android/wasm keep
    /// their specialized toolchains.
    pub fn zigBackendInScope(self: TargetConfig) bool {
        return self.isMacOS() or self.isLinux() or self.isWindows();
    }

    /// The zig `-target` for the bundled-zig link backend. sx triples already
    /// use zig's scheme, so this is pure pass-through; only the null
    /// (host-default) case synthesizes a portable triple from the host arch +
    /// host OS (musl on Linux for static portability, mingw on Windows).
    /// Caller owns the returned slice.
    pub fn zigTargetTriple(self: TargetConfig, allocator: std.mem.Allocator) ![]const u8 {
        if (self.triple) |t| return allocator.dupe(u8, std.mem.span(t));
        const arch: []const u8 = if (self.isAarch64()) "aarch64" else "x86_64";
        const os_abi: []const u8 = switch (builtin.os.tag) {
            .linux => "linux-musl",
            .macos => "macos-none",
            .windows => "windows-gnu",
            else => "linux-musl",
        };
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, os_abi });
    }
};

/// Decide whether the link step drives the bundled-`zig` backend
/// (`zig cc -target …`) or the system linker. Returns the zig path to use,
/// or null for the system linker. Errors loudly when a self-contained link is
/// requested but cannot be satisfied — never silently falls back in that case.
///
/// Auto mode engages ONLY for a *bundled* zig (a real distribution): a
/// PATH-only zig is a dev convenience and never hijacks a native build, so the
/// dev/CI corpus keeps using the system toolchain. `--self-contained` forces
/// the backend with either bundled or PATH zig.
/// See design/bundled-zig-link-backend-design.md §5.5.
fn selectZigLinker(allocator: std.mem.Allocator, tc: TargetConfig) !?[]const u8 {
    switch (tc.self_contained) {
        .off => return null,
        .on => {
            if (!tc.zigBackendInScope()) {
                std.debug.print("error: --self-contained supports macOS/Linux/Windows targets only\n", .{});
                return error.LinkError;
            }
            const found = zig_backend.discoverZig(allocator) orelse {
                std.debug.print("error: --self-contained requested but no usable `zig` was found (set $SX_ZIG or put zig on PATH)\n", .{});
                return error.LinkError;
            };
            return found.path;
        },
        .auto => {
            if (!tc.zigBackendInScope()) return null;
            if (tc.linker != null) return null; // explicit --linker wins
            const found = zig_backend.discoverZig(allocator) orelse return null;
            if (!found.bundled) return null; // PATH zig does not auto-engage
            return found.path;
        },
    }
}

/// Build the `zig cc` link argv (shared across macOS/Linux/Windows). zig cc is
/// a clang-compatible driver, so `-o`/`-L`/`-l`/`-framework`/extra objects all
/// pass through. `-static` is added only for musl (the portable Linux path);
/// macOS cannot static-link libSystem and Windows uses dynamic mingw.
fn emitZigLinkArgv(
    argv: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    zig_path: []const u8,
    output_obj: []const u8,
    extra_objects: []const []const u8,
    output_bin: []const u8,
    libraries: []const []const u8,
    frameworks: []const []const u8,
    tc: TargetConfig,
) !void {
    try argv.appendSlice(allocator, &.{ zig_path, "cc" });
    if (tc.isMacOS()) {
        // The object stays Mach-O (emitted from Apple's `apple-darwin` triple,
        // which LLVM needs), but zig's -target parser rejects that scheme — so
        // hand it zig's vendor-less `<arch>-macos`. No -static (libSystem can't
        // be statically linked). Cross-to-macOS needs an SDK (out of scope).
        const arch: []const u8 = if (tc.isAarch64()) "aarch64" else "x86_64";
        try argv.appendSlice(allocator, &.{ "-target", try std.fmt.allocPrint(allocator, "{s}-macos", .{arch}) });
    } else {
        const ztriple = try tc.zigTargetTriple(allocator);
        try argv.appendSlice(allocator, &.{ "-target", ztriple });
        if (std.mem.indexOf(u8, ztriple, "musl") != null) try argv.append(allocator, "-static");
    }
    try argv.appendSlice(allocator, &.{ output_obj, "-o", output_bin });
    for (extra_objects) |eo| try argv.append(allocator, eo);

    if (tc.sysroot) |sr| {
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "--sysroot={s}", .{sr}));
    }
    for (tc.lib_paths) |lp| {
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{lp}));
    }
    for (libraries) |lib| {
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
    }
    // Frameworks are Apple-only; ignored on Linux/Windows.
    if (tc.isMacOS()) {
        for (frameworks) |fw| {
            try argv.append(allocator, "-framework");
            try argv.append(allocator, fw);
        }
    }
    for (tc.extra_link_flags) |flag| {
        var it = std.mem.tokenizeScalar(u8, flag, ' ');
        while (it.next()) |part| try argv.append(allocator, part);
    }
}

/// Execute a precompiled object file in-process using LLVM's ORC JIT.
/// Takes ownership of obj_buf. Returns the exit code from main().
/// `priority_dylibs` are consulted for symbols BEFORE the process-wide
/// search, in order: dylibs that belong to the program (the `#import c`
/// unit's linked objects, then `#library` deps in declaration order)
/// must win over a same-named export of an image the host process
/// happens to carry (libz via LLVM, libsqlite3 via CoreServices, ...).
pub fn runJITFromObject(obj_buf: c.LLVMMemoryBufferRef, priority_dylibs: []const [:0]const u8) !u8 {
    // Create LLJIT with default builder (no custom TM needed — .o is precompiled)
    var jit: c.LLVMOrcLLJITRef = null;
    var err = c.LLVMOrcCreateLLJIT(&jit, null);
    if (err != null) {
        const msg = c.LLVMGetErrorMessage(err);
        defer c.LLVMDisposeErrorMessage(msg);
        std.debug.print("JIT error: {s}\n", .{std.mem.span(msg)});
        return error.CompileError;
    }
    defer _ = c.LLVMOrcDisposeLLJIT(jit);

    const jd = c.LLVMOrcLLJITGetMainJITDylib(jit);
    const prefix = c.LLVMOrcLLJITGetGlobalPrefix(jit);

    // Program-owned dylibs first (generators run in attachment order).
    // A failed generator is skipped: resolution then degrades to the
    // process-wide search below, exactly the pre-priority behavior.
    for (priority_dylibs) |path| {
        var pgen: c.LLVMOrcDefinitionGeneratorRef = null;
        err = c.LLVMOrcCreateDynamicLibrarySearchGeneratorForPath(&pgen, path.ptr, prefix, null, null);
        if (err != null) {
            const msg = c.LLVMGetErrorMessage(err);
            defer c.LLVMDisposeErrorMessage(msg);
            std.debug.print("warning: JIT could not search '{s}': {s}\n", .{ path, std.mem.span(msg) });
            continue;
        }
        c.LLVMOrcJITDylibAddGenerator(jd, pgen);
    }

    // Process-wide fallback so the JIT finds libc (printf, etc.)
    var gen: c.LLVMOrcDefinitionGeneratorRef = null;
    err = c.LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(&gen, prefix, null, null);
    if (err != null) {
        const msg = c.LLVMGetErrorMessage(err);
        defer c.LLVMDisposeErrorMessage(msg);
        std.debug.print("JIT symbol gen error: {s}\n", .{std.mem.span(msg)});
        return error.CompileError;
    }
    c.LLVMOrcJITDylibAddGenerator(jd, gen);

    // Add precompiled object file (transfers ownership of obj_buf)
    err = c.LLVMOrcLLJITAddObjectFile(jit, jd, obj_buf);
    if (err != null) {
        const msg = c.LLVMGetErrorMessage(err);
        defer c.LLVMDisposeErrorMessage(msg);
        std.debug.print("JIT add object error: {s}\n", .{std.mem.span(msg)});
        return error.CompileError;
    }

    // Look up the "main" function
    var main_addr: c.LLVMOrcExecutorAddress = 0;
    err = c.LLVMOrcLLJITLookup(jit, &main_addr, "main");
    if (err != null) {
        const msg = c.LLVMGetErrorMessage(err);
        defer c.LLVMDisposeErrorMessage(msg);
        std.debug.print("JIT lookup error: {s}\n", .{std.mem.span(msg)});
        return error.CompileError;
    }

    // Defensive backstop (issue 0137): ORC has been observed reporting
    // success from the `main` lookup while leaving `main_addr` at 0 — calling
    // @ptrFromInt(0) then segfaults. The real fix is the pre-JIT entry-point
    // check in main.zig (which also catches the observed NON-zero garbage
    // address case); this guard is a last line of defense so a null entry can
    // never be called regardless of how we got here.
    if (main_addr == 0) {
        std.debug.print("error: no 'main' function found in JIT module\n", .{});
        return error.CompileError;
    }

    // Cast to function pointer and call. The exit code is main's integer
    // return truncated to u8 — matching the OS truncation an AOT binary's
    // exit status already gets, so JIT and AOT agree (e.g. 1105 -> 81,
    // -1 -> 255, 256 -> 0). Bit-cast i32 -> u32 first so negatives wrap
    // as two's-complement low byte rather than being clamped.
    const main_fn: *const fn () callconv(.c) i32 = @ptrFromInt(main_addr);
    const result = main_fn();
    return @truncate(@as(u32, @bitCast(result)));
}

// Android APK bundling (createApk, compileJniMainSources,
// buildAndroidManifest, buildJniMainManifest, ensureDebugKeystore,
// libNameFromSoBasename + helpers) has moved to
// `library/modules/platform/bundle.sx`. `src/main.zig` invokes it
// post-link via the BuildOptions callback registered from sx code.
// `--apk <path>` on the CLI is a transitional alias that feeds
// `bundle_path` so the auto-fallback to `platform.bundle.bundle_main`
// fires; programs that opt in via `set_post_link_callback` reach the
// sx bundler directly.


/// Discover the Android NDK root. Honors $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT,
/// otherwise picks the highest-versioned NDK under $HOME/Library/Android/sdk/ndk
/// (the SDK Manager default install location on macOS). Caller owns the slice.
pub fn discoverAndroidNdk(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (std.c.getenv("ANDROID_NDK_HOME")) |env| {
        return try allocator.dupe(u8, std.mem.span(env));
    }
    if (std.c.getenv("ANDROID_NDK_ROOT")) |env| {
        return try allocator.dupe(u8, std.mem.span(env));
    }
    const home_env = std.c.getenv("HOME") orelse {
        std.debug.print("error: cannot locate Android NDK \u{2014} set $ANDROID_NDK_HOME\n", .{});
        return error.NdkNotFound;
    };
    const home = std.mem.span(home_env);
    const ndk_root = try std.fmt.allocPrint(allocator, "{s}/Library/Android/sdk/ndk", .{home});
    var dir = std.Io.Dir.openDir(.cwd(), io, ndk_root, .{ .iterate = true }) catch {
        std.debug.print("error: no NDK at {s} \u{2014} install via Android Studio or set $ANDROID_NDK_HOME\n", .{ndk_root});
        return error.NdkNotFound;
    };
    defer dir.close(io);
    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (best == null or std.mem.order(u8, entry.name, best.?) == .gt) {
            best = try allocator.dupe(u8, entry.name);
        }
    }
    const version = best orelse {
        std.debug.print("error: no NDK versions under {s}\n", .{ndk_root});
        return error.NdkNotFound;
    };
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ndk_root, version });
}

/// Run `xcrun --sdk <sdk_name> --show-sdk-path` and return the trimmed path.
/// Caller owns the returned slice.
pub fn discoverAppleSdk(allocator: std.mem.Allocator, io: std.Io, sdk_name: []const u8) ![]const u8 {
    const r = std.process.run(allocator, io, .{
        .argv = &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" },
    }) catch |e| {
        std.debug.print("error: failed to run xcrun: {} \u{2014} install Xcode Command Line Tools (xcode-select --install)\n", .{e});
        return error.SdkNotFound;
    };
    defer allocator.free(r.stderr);
    errdefer allocator.free(r.stdout);
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("error: xcrun --sdk {s} --show-sdk-path failed\n", .{sdk_name});
        allocator.free(r.stdout);
        return error.SdkNotFound;
    }
    const trimmed = std.mem.trimEnd(u8, r.stdout, " \t\r\n");
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(r.stdout);
    return out;
}

/// Run `<zig> env` and extract its `.lib_dir` (the `lib/zig` root that holds
/// the bundled libc headers + clang builtins). Caller owns the returned slice.
/// Errors loudly — a Linux self-contained build that reached here already
/// needs zig for the link, so a missing/garbled `zig env` is a hard failure,
/// never a silent fallback.
fn zigLibDir(allocator: std.mem.Allocator, io: std.Io, zig_path: []const u8) ![]const u8 {
    const r = std.process.run(allocator, io, .{
        .argv = &.{ zig_path, "env" },
    }) catch |e| {
        std.debug.print("error: failed to run `{s} env`: {}\n", .{ zig_path, e });
        return error.LinkError;
    };
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("error: `{s} env` failed\n", .{zig_path});
        return error.LinkError;
    }
    // `zig env` emits ZON: `.{ .zig_exe = "...", .lib_dir = "...", ... }`.
    // Scan for the `.lib_dir = "` key and take the quoted value verbatim.
    const key = ".lib_dir = \"";
    const idx = std.mem.indexOf(u8, r.stdout, key) orelse {
        std.debug.print("error: could not find lib_dir in `{s} env` output\n", .{zig_path});
        return error.LinkError;
    };
    const rest = r.stdout[idx + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse {
        std.debug.print("error: malformed lib_dir in `{s} env` output\n", .{zig_path});
        return error.LinkError;
    };
    return allocator.dupe(u8, rest[0..end]);
}

/// Libc include directories for a Linux cross-target, mirroring the set
/// `zig cc` itself searches (arch-abi, generic-libc, arch-any, any-linux-any).
/// sx's embedded clang carries no target libc headers, so a `#import c` unit
/// (sqlite, mbedTLS, …) can't find `string.h` / `stdio.h` for a foreign Linux
/// target without these. The dirs come from the bundled/discovered zig's
/// `lib/zig/libc/include`. Returns null (no-op) for anything but a Linux
/// CROSS build that will link via the zig backend — native builds (no
/// `--target`), non-Linux targets, and system-cc links keep the embedded
/// clang's own header search untouched (this mirrors selectZigLinker so the
/// C objects are always compiled against the same libc the linker uses).
/// Errors loudly when zig or the expected header dirs can't be located.
///
/// ABI selection mirrors zig: a triple containing "gnu" picks glibc headers,
/// everything else (musl or an unspecified abi, e.g. bare `aarch64-linux`)
/// picks musl — matching zig's default-to-musl for cross Linux. Caller owns
/// the returned slice and each element.
pub fn linuxLibcIncludeDirs(allocator: std.mem.Allocator, io: std.Io, tc: TargetConfig) !?[]const []const u8 {
    // Only a Linux CROSS build (an explicit `--target`) needs these. A native
    // build leaves `triple` null; the embedded clang's own default header
    // search — including a native-Linux host's `/usr/include` — must NOT be
    // perturbed (no zig dependency forced, no musl-vs-glibc header mixing).
    if (tc.triple == null) return null;
    if (!tc.isLinux()) return null; // isLinux() already excludes Android

    // The C objects must be compiled against the SAME libc the link step uses.
    // The bundled-zig (musl/glibc) headers are correct only when the link goes
    // through the zig backend, so mirror selectZigLinker's decision exactly —
    // otherwise headers and linker could disagree (compile musl, link glibc).
    const found = zig_backend.discoverZig(allocator);
    const use_zig = switch (tc.self_contained) {
        .off => false,
        .on => true,
        .auto => (tc.linker == null) and (if (found) |f| f.bundled else false),
    };
    if (!use_zig) return null;
    const zig_path = (found orelse {
        std.debug.print("error: --self-contained Linux build needs a `zig` for its libc headers (set $SX_ZIG or put zig on PATH)\n", .{});
        return error.LinkError;
    }).path;
    const lib_dir = try zigLibDir(allocator, io, zig_path);

    // zig's libc-include dirs use two arch spellings: a "full" arch
    // (`aarch64`, `x86_64`) and an arch "family" (`aarch64`, `x86`). The
    // mapping per (arch × abi × dir) is irregular (e.g. x86_64 musl →
    // `x86_64-linux-musl`, but x86_64 gnu → `x86-linux-gnu`, and the `-any`
    // dir is always the family form `x86-linux-any`). One rule reproduces
    // every observed case: prefer `<full>-linux-<suffix>`, fall back to
    // `<family>-linux-<suffix>` (see resolveArchDir).
    const full_arch: []const u8 = if (tc.isAarch64())
        "aarch64"
    else if (tc.isX86_64())
        "x86_64"
    else {
        const ts = if (tc.triple) |t| std.mem.span(t) else "(host)";
        std.debug.print("error: unsupported Linux cross arch in target '{s}' (only aarch64 and x86_64 are wired for #import c)\n", .{ts});
        return error.LinkError;
    };
    const family_arch: []const u8 = if (tc.isAarch64()) "aarch64" else "x86";

    const triple_span = if (tc.triple) |t| std.mem.span(t) else "";
    const is_gnu = std.mem.indexOf(u8, triple_span, "gnu") != null;
    const abi_suffix: []const u8 = if (is_gnu) "gnu" else "musl";
    const libc_generic: []const u8 = if (is_gnu) "generic-glibc" else "generic-musl";

    var dirs = std.ArrayList([]const u8).empty;
    // 1. arch+abi dir (e.g. aarch64-linux-musl)
    try dirs.append(allocator, try resolveArchDir(allocator, io, lib_dir, full_arch, family_arch, abi_suffix, zig_path));
    // 2. generic libc dir — holds string.h/stdio.h/… (must exist)
    try dirs.append(allocator, try requireDir(allocator, io, lib_dir, libc_generic, zig_path));
    // 3. arch+any dir (e.g. x86-linux-any)
    try dirs.append(allocator, try resolveArchDir(allocator, io, lib_dir, full_arch, family_arch, "any", zig_path));
    // 4. any-linux-any — cross-arch Linux fallbacks (must exist)
    try dirs.append(allocator, try requireDir(allocator, io, lib_dir, "any-linux-any", zig_path));
    return try dirs.toOwnedSlice(allocator);
}

/// `<lib_dir>/libc/include/<sub>`, asserting it exists. Caller owns the slice.
fn requireDir(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, sub: []const u8, zig_path: []const u8) ![]const u8 {
    const d = try std.fs.path.join(allocator, &.{ lib_dir, "libc", "include", sub });
    std.Io.Dir.access(.cwd(), io, d, .{}) catch {
        std.debug.print("error: expected libc headers at '{s}' (from zig at '{s}') but the directory is missing\n", .{ d, zig_path });
        return error.LinkError;
    };
    return d;
}

/// Resolve `<arch>-linux-<suffix>`, preferring the full arch spelling
/// (`x86_64-linux-musl`) and falling back to the family spelling
/// (`x86-linux-gnu`, `x86-linux-any`) — matching zig's own dir layout.
/// Caller owns the slice.
fn resolveArchDir(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, full_arch: []const u8, family_arch: []const u8, suffix: []const u8, zig_path: []const u8) ![]const u8 {
    const full_sub = try std.fmt.allocPrint(allocator, "{s}-linux-{s}", .{ full_arch, suffix });
    const full = try std.fs.path.join(allocator, &.{ lib_dir, "libc", "include", full_sub });
    if (std.Io.Dir.access(.cwd(), io, full, .{})) |_| return full else |_| {}
    const fam_sub = try std.fmt.allocPrint(allocator, "{s}-linux-{s}", .{ family_arch, suffix });
    const fam = try std.fs.path.join(allocator, &.{ lib_dir, "libc", "include", fam_sub });
    if (std.Io.Dir.access(.cwd(), io, fam, .{})) |_| return fam else |_| {}
    std.debug.print("error: expected libc headers for '{s}'/'{s}' linux-{s} (from zig at '{s}') but neither directory exists\n", .{ full_arch, family_arch, suffix, zig_path });
    return error.LinkError;
}

pub fn link(allocator: std.mem.Allocator, io: std.Io, output_obj: []const u8, extra_objects: []const []const u8, output_bin: []const u8, libraries: []const []const u8, frameworks: []const []const u8, target_config: TargetConfig, has_jni_main: bool) !void {
    var argv = std.ArrayList([]const u8).empty;

    if (try selectZigLinker(allocator, target_config)) |zig_path| {
        // Bundled-zig backend: macOS/Linux/Windows linked uniformly via
        // `zig cc`, which supplies lld + CRT + libc with no host toolchain.
        try emitZigLinkArgv(&argv, allocator, zig_path, output_obj, extra_objects, output_bin, libraries, frameworks, target_config);
    } else if (target_config.isIOS()) {
        // iOS: clang driver with -isysroot pointing at the iOS SDK.
        // -l libraries are generally wrong for iOS (Apple ships system code
        // as frameworks); user-declared #library still pass through.
        const linker = target_config.linker orelse "clang";
        try argv.append(allocator, linker);
        if (target_config.triple) |t| {
            try argv.append(allocator, "-target");
            try argv.append(allocator, std.mem.span(t));
        }
        const sdk_path = if (target_config.sysroot) |sr|
            try allocator.dupe(u8, sr)
        else blk: {
            const sdk_name: []const u8 = if (target_config.isIOSSimulator()) "iphonesimulator" else "iphoneos";
            break :blk try discoverAppleSdk(allocator, io, sdk_name);
        };
        try argv.append(allocator, "-isysroot");
        try argv.append(allocator, sdk_path);
        const min_flag: []const u8 = if (target_config.isIOSSimulator()) "-mios-simulator-version-min=14.0" else "-mios-version-min=14.0";
        try argv.append(allocator, min_flag);
        // Embedded framework load path: bundle/Frameworks at runtime.
        try argv.append(allocator, "-Wl,-rpath,@executable_path/Frameworks");
        try argv.append(allocator, output_obj);
        try argv.append(allocator, "-o");
        try argv.append(allocator, output_bin);
        for (extra_objects) |eo| try argv.append(allocator, eo);
        for (target_config.lib_paths) |lp| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{lp}));
        }
        for (target_config.framework_paths) |fp| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-F{s}", .{fp}));
        }
        for (libraries) |lib| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
        }
        for (frameworks) |fw| {
            try argv.append(allocator, "-framework");
            try argv.append(allocator, fw);
        }
        for (target_config.extra_link_flags) |flag| {
            var it = std.mem.tokenizeScalar(u8, flag, ' ');
            while (it.next()) |part| try argv.append(allocator, part);
        }
    } else if (target_config.isAndroid()) {
        // Android: NDK clang. Produces a shared library (.so).
        //
        // Two entry shapes:
        //
        //   - **#jni_main path (`has_jni_main = true`)** — the Java side
        //     drives lifecycle (the bundled classes.dex declares an
        //     Activity that overrides `onCreate` etc.). The .so just
        //     provides JNI implementations bound at load time via the
        //     `JNI_OnLoad` synthesized in slice R.3. No native_app_glue
        //     is needed: there's no `ANativeActivity_onCreate` to host,
        //     no `android_main` event loop to run.
        //
        //   - **Legacy NativeActivity path (`has_jni_main = false`)** —
        //     native_app_glue.c is compiled and linked alongside the sx
        //     code; the glue owns `ANativeActivity_onCreate` and forwards
        //     into the user's `android_main` on a worker thread. The
        //     `-u ANativeActivity_onCreate` keeps the glue's symbol from
        //     being stripped (nothing in our .o references it).
        //
        // The `libraries` parameter (collected from `#library` directives)
        // and `frameworks` parameter (Apple-only by definition) are
        // intentionally ignored here. On Android, users opt into specific
        // libs via `opts.add_link_flag("-l<name>")` in their build.sx —
        // the platform-specific link surface should be expressed in build
        // options rather than auto-inherited from every imported module
        // (most of which assume Apple targets).
        const ndk_root = if (target_config.sysroot) |sr|
            try allocator.dupe(u8, sr)
        else
            try discoverAndroidNdk(allocator, io);
        const host_tag: []const u8 = if (@import("builtin").os.tag == .macos) "darwin-x86_64" else "linux-x86_64";
        const clang = try std.fmt.allocPrint(allocator, "{s}/toolchains/llvm/prebuilt/{s}/bin/clang", .{ ndk_root, host_tag });

        const glue_obj_opt: ?[]const u8 = if (has_jni_main) null else blk: {
            const glue_src = try std.fmt.allocPrint(allocator, "{s}/sources/android/native_app_glue/android_native_app_glue.c", .{ndk_root});
            const glue_obj = try std.fmt.allocPrint(allocator, "{s}.glue.o", .{output_obj});
            var glue_argv = std.ArrayList([]const u8).empty;
            try glue_argv.appendSlice(allocator, &.{ clang, "-c", "-fPIC" });
            if (target_config.triple) |t| {
                try glue_argv.append(allocator, "-target");
                try glue_argv.append(allocator, std.mem.span(t));
            }
            try glue_argv.appendSlice(allocator, &.{ glue_src, "-o", glue_obj });
            const glue_slice = try glue_argv.toOwnedSlice(allocator);
            var glue_child = std.process.spawn(io, .{ .argv = glue_slice }) catch return error.LinkError;
            const glue_term = glue_child.wait(io) catch return error.LinkError;
            if (glue_term != .exited or glue_term.exited != 0) return error.LinkError;
            break :blk glue_obj;
        };

        try argv.append(allocator, clang);
        if (target_config.triple) |t| {
            try argv.append(allocator, "-target");
            try argv.append(allocator, std.mem.span(t));
        }
        try argv.append(allocator, "-shared");
        try argv.append(allocator, "-fPIC");
        if (!has_jni_main) {
            try argv.appendSlice(allocator, &.{ "-u", "ANativeActivity_onCreate" });
        }
        try argv.append(allocator, output_obj);
        if (glue_obj_opt) |go| try argv.append(allocator, go);
        for (extra_objects) |eo| try argv.append(allocator, eo);
        try argv.append(allocator, "-o");
        try argv.append(allocator, output_bin);
        for (target_config.lib_paths) |lp| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{lp}));
        }
        // Default libs available on every Android runtime; linker drops
        // unreferenced ones automatically. `#library` directives are
        // intentionally NOT auto-emitted here (most assume Apple targets);
        // users opt in per-target via `opts.add_link_flag("-l...")` in
        // their build.sx.
        try argv.appendSlice(allocator, &.{ "-llog", "-landroid", "-lEGL", "-lGLESv3", "-lm", "-ldl" });
        for (target_config.extra_link_flags) |flag| {
            var it = std.mem.tokenizeScalar(u8, flag, ' ');
            while (it.next()) |part| try argv.append(allocator, part);
        }
    } else if (target_config.isEmscripten()) {
        // Emscripten: use emcc as the linker/driver
        const linker = target_config.linker orelse "emcc";
        try argv.appendSlice(allocator, &.{ linker, output_obj, "-o", output_bin });
        for (extra_objects) |eo| try argv.append(allocator, eo);

        if (target_config.sysroot) |sr| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "--sysroot={s}", .{sr}));
        }

        for (target_config.lib_paths) |lp| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{lp}));
        }
        // Skip -l flags for Emscripten: libraries like SDL3 are provided via
        // -sUSE_SDL=3, not -lSDL3. User provides everything via --lflags.

        // wasm64: automatically add -sMEMORY64 for the linker
        if (target_config.isWasm64()) {
            try argv.append(allocator, "-sMEMORY64");
        }

        // HTML shell template: use custom path if set, otherwise write built-in template to temp file
        if (std.mem.endsWith(u8, output_bin, ".html")) {
            if (target_config.wasm_shell_path) |custom_shell| {
                try argv.appendSlice(allocator, &.{ "--shell-file", custom_shell });
            } else {
                const shell_html = @embedFile("wasm_shell.html");
                const shell_path = try std.fmt.allocPrint(allocator, "{s}.shell.html", .{output_obj});
                std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = shell_path, .data = shell_html }) catch {};
                try argv.appendSlice(allocator, &.{ "--shell-file", shell_path });
            }
        }

        // Extra linker flags (e.g. -sUSE_SDL=3, -sUSE_WEBGL2=1, --preload-file assets)
        // Split space-separated flags into individual argv entries.
        for (target_config.extra_link_flags) |flag| {
            var it = std.mem.tokenizeScalar(u8, flag, ' ');
            while (it.next()) |part| {
                try argv.append(allocator, part);
            }
        }
    } else if (target_config.isWindows()) {
        // Windows: MSVC-style linker flags
        const linker = target_config.linker orelse "link.exe";
        try argv.appendSlice(allocator, &.{ linker, output_obj });
        for (extra_objects) |eo| try argv.append(allocator, eo);
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "/OUT:{s}", .{output_bin}));

        for (target_config.lib_paths) |lp| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "/LIBPATH:{s}", .{lp}));
        }
        for (libraries) |lib| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));
        }
    } else {
        // Unix: cc-style linker flags
        try argv.appendSlice(allocator, &.{ target_config.getLinker(), output_obj, "-o", output_bin });
        for (extra_objects) |eo| try argv.append(allocator, eo);

        if (target_config.sysroot) |sr| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "--sysroot={s}", .{sr}));
        }

        // User-supplied library paths first
        for (target_config.lib_paths) |lp| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{lp}));
        }

        // Auto-detect host OS library paths when linking external libraries
        if (libraries.len > 0 and target_config.triple == null) {
            for (host_lib_paths) |path| {
                try argv.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{path}));
            }
        }

        for (libraries) |lib| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{lib}));
        }

        // Frameworks: only meaningful on Apple targets; silently ignored elsewhere.
        if (target_config.isMacOS()) {
            for (frameworks) |fw| {
                try argv.append(allocator, "-framework");
                try argv.append(allocator, fw);
            }
        }

        // Extra linker flags — split space-separated flags into individual argv entries.
        for (target_config.extra_link_flags) |flag| {
            var it = std.mem.tokenizeScalar(u8, flag, ' ');
            while (it.next()) |part| {
                try argv.append(allocator, part);
            }
        }
    }

    const argv_slice = try argv.toOwnedSlice(allocator);
    if (std.c.getenv("SX_DEBUG_LINK") != null) {
        std.debug.print("[sx] link argv:", .{});
        for (argv_slice) |a| std.debug.print(" {s}", .{a});
        std.debug.print("\n", .{});
    }
    var child = std.process.spawn(io, .{
        .argv = argv_slice,
    }) catch return error.LinkError;
    const result = child.wait(io) catch return error.LinkError;
    if (result != .exited) return error.LinkError;
    if (result.exited != 0) return error.LinkError;
}

// Apple .app bundling (createBundle, embedFramework, extractEntitlements,
// buildInfoPlist, codesign) has moved to
// `library/modules/platform/bundle.sx`. `src/main.zig` invokes it
// post-link via the BuildOptions callback registered from sx code.

/// After emcc produces HTML output, inject cache-busting hashes into the
/// generated <script> tag and add Module.locateFile for .wasm/.data files.
pub fn postProcessWasmHtml(allocator: std.mem.Allocator, io: std.Io, html_path: []const u8) void {
    const base = if (std.mem.endsWith(u8, html_path, ".html"))
        html_path[0 .. html_path.len - 5]
    else
        return;

    // Hash build output contents (.js + .wasm + optional .data)
    var hash: u64 = 0;
    const exts = [_][]const u8{ ".js", ".wasm", ".data" };
    for (exts) |ext| {
        const path = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ext }) catch continue;
        if (std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(64 * 1024 * 1024))) |data| {
            hash = std.hash.Wyhash.hash(hash, data);
        } else |_| {}
    }

    const hash_hex = std.fmt.allocPrint(allocator, "{x:0>8}", .{@as(u32, @truncate(hash))}) catch return;

    // Read the final HTML produced by emcc
    const html = std.Io.Dir.readFileAlloc(.cwd(), io, html_path, allocator, .limited(10 * 1024 * 1024)) catch return;

    var out = std.ArrayList(u8).empty;
    var pos: usize = 0;
    var injected_locateFile = false;

    // Find emcc's generated script tag: <script ...src="*.js"></script>
    // Inject ?v=HASH into the src and prepend a Module.locateFile script.
    while (std.mem.indexOfPos(u8, html, pos, "src=\"")) |src_start| {
        const val_start = src_start + 5; // past src="
        const val_end = std.mem.indexOfPos(u8, html, val_start, "\"") orelse break;
        const src_val = html[val_start..val_end];

        if (!std.mem.endsWith(u8, src_val, ".js")) {
            // Not a .js src — skip past this attribute and keep searching
            pos = val_end + 1;
            continue;
        }

        // Find the opening < of this tag to inject locateFile before it
        const tag_start = if (std.mem.lastIndexOf(u8, html[pos..src_start], "<")) |off| pos + off else src_start;

        // Copy everything up to the tag start
        out.appendSlice(allocator, html[pos..tag_start]) catch return;

        // Inject Module.locateFile once, before the first .js script tag
        if (!injected_locateFile) {
            out.appendSlice(allocator, "<script>Module.locateFile=function(p){return p+'?v=") catch return;
            out.appendSlice(allocator, hash_hex) catch return;
            out.appendSlice(allocator, "'}</script>\n") catch return;
            injected_locateFile = true;
        }

        // Copy tag up to the closing quote of src, inserting ?v=HASH
        out.appendSlice(allocator, html[tag_start..val_end]) catch return;
        out.appendSlice(allocator, "?v=") catch return;
        out.appendSlice(allocator, hash_hex) catch return;

        pos = val_end;
    }
    // Copy remaining HTML
    out.appendSlice(allocator, html[pos..]) catch return;

    const final = out.toOwnedSlice(allocator) catch return;
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = html_path, .data = final }) catch {};
}

/// Common library paths for the host OS, computed at comptime.
pub const host_lib_paths = blk: {
    var paths: []const []const u8 = &.{};
    if (builtin.os.tag == .macos) {
        if (builtin.cpu.arch == .aarch64) {
            // Apple Silicon Homebrew
            paths = &.{ "/opt/homebrew/lib", "/usr/local/lib" };
        } else {
            // Intel Mac Homebrew
            paths = &.{"/usr/local/lib"};
        }
    } else if (builtin.os.tag == .linux) {
        paths = &.{ "/usr/local/lib", "/usr/lib" };
    }
    break :blk paths;
};
