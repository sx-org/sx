const std = @import("std");
const sx = @import("sx");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    // Stdlib discovered from binary location (or $SX_STDLIB_PATH override).
    // Empty slice on hosts where discovery fails — imports fall back to CWD.
    const stdlib_paths = sx.imports.discoverStdlibPaths(allocator) catch &[_][]const u8{};

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    // LSP subcommand doesn't need a file argument
    if (std.mem.eql(u8, command, "lsp")) {
        runLsp(allocator, io, stdlib_paths);
        return;
    }

    // Parse flags and positional arguments
    var input_path: ?[]const u8 = null;
    var target_config = sx.target.TargetConfig{};
    var lib_paths = std.ArrayList([]const u8).empty;
    var framework_paths = std.ArrayList([]const u8).empty;
    var link_flags = std.ArrayList([]const u8).empty;
    var show_timing: bool = false;
    var explicit_opt: bool = false;
    var enable_cache: bool = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --target requires a value\n", .{}); return; }
            const raw = args[i];
            // Shorthand aliases for common targets
            const expanded = if (std.mem.eql(u8, raw, "wasm") or std.mem.eql(u8, raw, "wasm32") or std.mem.eql(u8, raw, "emscripten"))
                "wasm32-unknown-emscripten"
            else if (std.mem.eql(u8, raw, "wasm64"))
                "wasm64-unknown-emscripten"
            else if (std.mem.eql(u8, raw, "macos") or std.mem.eql(u8, raw, "macos-arm"))
                try macosTripleForArch(allocator, "aarch64")
            else if (std.mem.eql(u8, raw, "macos-x86"))
                try macosTripleForArch(allocator, "x86_64")
            else if (std.mem.eql(u8, raw, "linux") or std.mem.eql(u8, raw, "linux-x86"))
                "x86_64-linux-gnu"
            else if (std.mem.eql(u8, raw, "linux-arm"))
                "aarch64-linux-gnu"
            else if (std.mem.eql(u8, raw, "linux-musl"))
                "x86_64-linux-musl"
            else if (std.mem.eql(u8, raw, "linux-musl-arm"))
                "aarch64-linux-musl"
            else if (std.mem.eql(u8, raw, "windows"))
                "x86_64-windows-msvc"
            else if (std.mem.eql(u8, raw, "windows-gnu"))
                "x86_64-windows-gnu"
            else if (std.mem.eql(u8, raw, "ios") or std.mem.eql(u8, raw, "ios-arm"))
                "arm64-apple-ios14.0"
            else if (std.mem.eql(u8, raw, "ios-sim") or std.mem.eql(u8, raw, "ios-sim-arm"))
                "arm64-apple-ios14.0-simulator"
            else if (std.mem.eql(u8, raw, "ios-sim-x86"))
                "x86_64-apple-ios14.0-simulator"
            else if (std.mem.eql(u8, raw, "android") or std.mem.eql(u8, raw, "android-arm64"))
                "aarch64-linux-android21"
            else if (std.mem.eql(u8, raw, "android-x86_64"))
                "x86_64-linux-android21"
            else
                raw;
            target_config.triple = (try allocator.dupeZ(u8, expanded)).ptr;
        } else if (std.mem.eql(u8, arg, "--cpu")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --cpu requires a value\n", .{}); return; }
            target_config.cpu = (try allocator.dupeZ(u8, args[i])).ptr;
        } else if (std.mem.eql(u8, arg, "--opt")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --opt requires a value\n", .{}); return; }
            target_config.opt_level = parseOptLevel(args[i]) orelse {
                std.debug.print("error: invalid --opt value '{s}' (expected: none/0, less/1, default/2, aggressive/3)\n", .{args[i]});
                return;
            };
            explicit_opt = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: -o requires a value\n", .{}); return; }
            target_config.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--linker")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --linker requires a value\n", .{}); return; }
            target_config.linker = args[i];
        } else if (std.mem.eql(u8, arg, "--self-contained")) {
            target_config.self_contained = .on;
        } else if (std.mem.eql(u8, arg, "--no-self-contained")) {
            target_config.self_contained = .off;
        } else if (std.mem.eql(u8, arg, "--sysroot")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --sysroot requires a value\n", .{}); return; }
            target_config.sysroot = args[i];
        } else if (std.mem.eql(u8, arg, "--bundle")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --bundle requires a path (e.g. MyApp.app)\n", .{}); return; }
            target_config.bundle_path = args[i];
        } else if (std.mem.eql(u8, arg, "--apk")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --apk requires a path (e.g. out.apk)\n", .{}); return; }
            target_config.apk_path = args[i];
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --manifest requires a path\n", .{}); return; }
            target_config.manifest_path = args[i];
        } else if (std.mem.eql(u8, arg, "--keystore")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --keystore requires a path\n", .{}); return; }
            target_config.keystore_path = args[i];
        } else if (std.mem.eql(u8, arg, "--bundle-id")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --bundle-id requires a value (e.g. co.swipelab.myapp)\n", .{}); return; }
            target_config.bundle_id = args[i];
        } else if (std.mem.eql(u8, arg, "--codesign-identity")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --codesign-identity requires a value\n", .{}); return; }
            target_config.codesign_identity = args[i];
        } else if (std.mem.eql(u8, arg, "--provisioning-profile")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --provisioning-profile requires a path\n", .{}); return; }
            target_config.provisioning_profile = args[i];
        } else if (std.mem.eql(u8, arg, "--entitlements")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --entitlements requires a path\n", .{}); return; }
            target_config.entitlements_path = args[i];
        } else if (std.mem.eql(u8, arg, "--time")) {
            show_timing = true;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            enable_cache = true;
        } else if (std.mem.eql(u8, arg, "--emit-obj")) {
            target_config.emit_obj = true;
        } else if (std.mem.startsWith(u8, arg, "-L")) {
            if (arg.len > 2) {
                try lib_paths.append(allocator, arg[2..]);
            } else {
                i += 1;
                if (i >= args.len) { std.debug.print("error: -L requires a value\n", .{}); return; }
                try lib_paths.append(allocator, args[i]);
            }
        } else if (std.mem.startsWith(u8, arg, "-F")) {
            if (arg.len > 2) {
                try framework_paths.append(allocator, arg[2..]);
            } else {
                i += 1;
                if (i >= args.len) { std.debug.print("error: -F requires a value\n", .{}); return; }
                try framework_paths.append(allocator, args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--lflags")) {
            i += 1;
            if (i >= args.len) { std.debug.print("error: --lflags requires a value\n", .{}); return; }
            try link_flags.append(allocator, args[i]);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_path = arg;
        } else {
            std.debug.print("error: unknown flag '{s}'\n", .{arg});
            return;
        }
    }

    target_config.lib_paths = try lib_paths.toOwnedSlice(allocator);
    target_config.framework_paths = try framework_paths.toOwnedSlice(allocator);
    target_config.extra_link_flags = try link_flags.toOwnedSlice(allocator);

    // Auto-discover iOS SDK once so both the C compile path and the link
    // path see the same sysroot. Honors any explicit --sysroot.
    if (target_config.isIOS() and target_config.sysroot == null) {
        const sdk_name: []const u8 = if (target_config.isIOSSimulator()) "iphonesimulator" else "iphoneos";
        target_config.sysroot = sx.target.discoverAppleSdk(allocator, io, sdk_name) catch null;
    }

    // Same idea for Android — the NDK root must be visible to BOTH the
    // C-import compile path (so `--sysroot ndk/.../sysroot` finds bionic
    // headers) and the link path. By convention, target_config.sysroot
    // holds the NDK root on Android (target.zig's link branch + c_import.zig
    // both read it). Honors any explicit --sysroot.
    if (target_config.isAndroid() and target_config.sysroot == null) {
        target_config.sysroot = sx.target.discoverAndroidNdk(allocator, io) catch null;
    }

    const raw_input = input_path orelse {
        printUsage();
        return;
    };
    // Canonicalize the entry path the same way `#import`-resolved paths are
    // keyed (issue 0148): an absolute entry that lives under the CWD becomes
    // the cwd-relative spelling, so the entry file's OWN diagnostics display
    // identically to a relative invocation. Identity-guarded — a respelling
    // that stops naming the same file (or a nonexistent entry) keeps the
    // user's spelling.
    const path = sx.imports.canonicalizeEntryPath(allocator, raw_input);

    if (std.mem.eql(u8, command, "build")) {
        target_config.is_aot = true;
        // `--emit-obj` keeps a debuggable object; DWARF only emits at opt
        // none/less, so default to -O0 unless the user set --opt explicitly.
        if (target_config.emit_obj and !explicit_opt) target_config.opt_level = .none;
        const output_name = target_config.output_path orelse blk: {
            const base = deriveOutputName(path);
            if (target_config.isEmscripten()) {
                break :blk try std.fmt.allocPrint(allocator, "{s}.html", .{base});
            }
            break :blk base;
        };
        compile(allocator, io, path, output_name, target_config, show_timing, enable_cache, stdlib_paths) catch std.process.exit(1);
    } else if (std.mem.eql(u8, command, "ir")) {
        emitIR(allocator, io, path, target_config, stdlib_paths) catch std.process.exit(1);
    } else if (std.mem.eql(u8, command, "ir-dump")) {
        dumpSxIR(allocator, io, path, stdlib_paths) catch std.process.exit(1);
    } else if (std.mem.eql(u8, command, "asm")) {
        emitAsm(allocator, io, path, target_config, stdlib_paths) catch std.process.exit(1);
    } else if (std.mem.eql(u8, command, "run")) {
        if (target_config.isWasm()) {
            std.debug.print("error: 'run' is not supported for wasm targets. Use 'build' instead.\n", .{});
            return;
        }
        // Default to -O0 for run (faster compile) unless user explicitly set --opt
        if (!explicit_opt) target_config.opt_level = .none;
        var timer = Timing.init(io, show_timing);

        // Phase A: read + parse + resolveImports (for cache key)
        timer.mark();
        const source = readSource(allocator, io, path) catch std.process.exit(1);
        timer.record("read");

        var comp = sx.core.Compilation.init(allocator, io, path, source, target_config, stdlib_paths);
        defer comp.deinit();

        timer.mark();
        comp.parse() catch { comp.renderErrors(); std.process.exit(1); };
        timer.record("parse");

        timer.mark();
        comp.resolveImports() catch { comp.renderErrors(); std.process.exit(1); };
        timer.record("imports");

        // Cache check — use .o files (precompiled object, skip IR compilation in JIT)
        // Disable caching for files with top-level #run (side effects lost on cache hit)
        const root = comp.resolved_root orelse comp.root orelse return;

        // Pre-JIT entry-point check. The ORC `main` lookup in
        // runJITFromObject does NOT reliably report "no main" — it has been
        // observed reporting success while leaving the address at garbage
        // (0x0 or a small non-zero value), which then gets called and
        // segfaults (issue 0137). Reject programs with no `main` here, before
        // any codegen/JIT, with a clean diagnostic + non-zero exit.
        if (!hasMainEntry(root)) {
            std.debug.print("error: no 'main' function found — 'sx run' requires a top-level 'main' entry point\n", .{});
            std.process.exit(1);
        }

        // A failed compiler self-hash disables the cache for this process
        // (slower, never stale) — the key must always carry the compiler's
        // identity (issue 0336).
        const self_hash: ?u64 = if (enable_cache and !hasTopLevelRun(root)) compilerSelfHash(allocator, io) else null;
        const use_cache = self_hash != null;
        const key = computeCacheKey(source, &comp.import_sources, target_config, self_hash orelse 0);
        const cache_obj = cachePath(allocator, key, "o") catch std.process.exit(1);

        timer.mark();
        const obj_buf: sx.llvm_api.c.LLVMMemoryBufferRef = blk: {
            if (use_cache) {
                // Try loading cached .o from disk
                var buf: sx.llvm_api.c.LLVMMemoryBufferRef = null;
                var err_msg: [*c]u8 = null;
                if (sx.llvm_api.c.LLVMCreateMemoryBufferWithContentsOfFile(cache_obj.ptr, &buf, &err_msg) == 0) {
                    timer.record("cache");
                    break :blk buf;
                }
                if (err_msg != null) sx.llvm_api.c.LLVMDisposeMessage(err_msg);
            }

            // Cache MISS — codegen (including verification + optimization) and
            // emit the resulting object to memory.
            comp.generateCode() catch { comp.renderErrors(); std.process.exit(1); };
            timer.record("codegen");

            timer.mark();
            const buf = comp.ir_emitter.?.emitObjectToMemory() catch std.process.exit(1);
            timer.record("emit");

            // Save .o to cache (extract data before JIT takes ownership)
            if (use_cache) {
                saveObjectToCache(buf, io, cache_obj);
            }

            break :blk buf;
        };

        // Compile C sources natively and dlopen before JIT
        timer.mark();
        var c_handle = compileCForJIT(allocator, io, &comp) catch { comp.renderErrors(); std.process.exit(1); };
        defer c_handle.unload(io);
        timer.record("c-import");

        // dlopen #library dependencies so JIT can resolve extern symbols.
        // Program-owned dylibs (the #import c unit first, then #library
        // deps in declaration order) also become PRIORITY search targets
        // for the JIT, consulted before the process-wide fallback.
        const libs = extractLibraries(allocator, root) catch std.process.exit(1);
        var lib_handles = std.ArrayList(*anyopaque).empty;
        var priority_dylibs = std.ArrayList([:0]const u8).empty;
        if (c_handle.dylib_path) |cp| priority_dylibs.append(allocator, cp) catch {};
        defer {
            for (lib_handles.items) |h| _ = std.c.dlclose(h);
        }
        for (libs) |lib_name| {
            if (loadLibrary(allocator, lib_name, target_config.lib_paths)) |loaded| {
                lib_handles.append(allocator, loaded.handle) catch {};
                priority_dylibs.append(allocator, loaded.path) catch {};
            } else {
                const e = std.c.dlerror();
                if (e) |msg| std.debug.print("warning: could not load library '{s}': {s}\n", .{ lib_name, std.mem.span(msg) });
            }
        }

        // JIT from precompiled object (relocation only, no IR compilation)
        sx.llvm_api.initNativeTarget();
        timer.mark();
        // Phase separator: emit a clear delimiter between any #run output
        // (which prints via the interp to stderr) and the JIT-executed
        // main's runtime output (which writes to stdout). Without this,
        // test logs and human-eye reads interleave compile-time and
        // run-time output ambiguously. Only when top-level #run exists —
        // pure-runtime tests keep their current snapshots.
        if (hasTopLevelRun(root)) {
            // Stay on the same stream as the #run output (stdout, via
            // core.flushInterpOutput). Same reason as issue-0047: the
            // user doesn't distinguish build-time `print` from
            // runtime `print` at the call site, and the delimiter is
            // meaningless if it lands on a different stream than the
            // output it's separating.
            const marker = "--- build done ---\n";
            _ = std.c.write(1, marker.ptr, marker.len);
        }
        const exit_code = sx.target.runJITFromObject(obj_buf, priority_dylibs.items) catch {
            // JIT failed — fall back to AOT
            timer.record("jit-fail");
            runAOT(allocator, io, path, target_config, &timer, enable_cache, stdlib_paths) catch std.process.exit(1);
            timer.printAll();
            return;
        };
        timer.record("jit");
        timer.printAll();

        if (exit_code != 0) std.process.exit(exit_code);
    } else {
        printUsage();
    }
}

/// Compile C sources from #import c blocks and dlopen them for JIT.
fn compileCForJIT(allocator: std.mem.Allocator, io: std.Io, comp: *sx.core.Compilation) !sx.c_import.CImportHandle {
    const c_infos = try comp.collectCImportSources();
    if (c_infos.len == 0) return .{ .allocator = allocator };

    const obj_bufs = try sx.c_import.compileCToObjects(allocator, io, c_infos, comp.target_config);
    return try sx.c_import.loadCObjectsForJIT(allocator, io, obj_bufs);
}

/// Compile C sources from #import c blocks to .o files for linking.
fn compileCForBuild(allocator: std.mem.Allocator, io: std.Io, comp: *sx.core.Compilation, tmp_dir: []const u8) ![]const []const u8 {
    const c_infos = try comp.collectCImportSources();
    if (c_infos.len == 0) return &.{};

    // For Emscripten targets, use emcc to cross-compile C sources
    if (comp.target_config.isEmscripten()) {
        return try sx.c_import.compileCWithEmcc(allocator, io, c_infos, comp.target_config, tmp_dir);
    }

    const obj_bufs = try sx.c_import.compileCToObjects(allocator, io, c_infos, comp.target_config);
    return try sx.c_import.writeCObjectFiles(allocator, io, obj_bufs, tmp_dir);
}

/// Build an Apple Darwin triple for `arch` (e.g. "aarch64" / "x86_64") using
/// the host's OS version suffix from `LLVMGetDefaultTargetTriple()`. Without
/// the version suffix, the emitted object file carries no platform load
/// command and `ld` warns "no platform load command found ... assuming: macOS".
/// Falls back to "darwin" if the host triple doesn't start with darwin (e.g.
/// when sx is cross-built on Linux for macOS).
fn macosTripleForArch(allocator: std.mem.Allocator, arch: []const u8) ![]const u8 {
    const host = sx.llvm_api.c.LLVMGetDefaultTargetTriple();
    defer sx.llvm_api.c.LLVMDisposeMessage(host);
    const span = std.mem.span(host);
    var it = std.mem.splitScalar(u8, span, '-');
    _ = it.next();
    _ = it.next();
    const os_part = it.next() orelse "darwin";
    const os_suffix = if (std.mem.startsWith(u8, os_part, "darwin")) os_part else "darwin";
    return std.fmt.allocPrint(allocator, "{s}-apple-{s}", .{ arch, os_suffix });
}

fn parseOptLevel(s: []const u8) ?sx.target.TargetConfig.OptLevel {
    if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "0")) return .none;
    if (std.mem.eql(u8, s, "less") or std.mem.eql(u8, s, "1")) return .less;
    if (std.mem.eql(u8, s, "default") or std.mem.eql(u8, s, "2")) return .default;
    if (std.mem.eql(u8, s, "aggressive") or std.mem.eql(u8, s, "3")) return .aggressive;
    return null;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: sx <command> [options] <file.sx>
        \\
        \\Commands:
        \\  run    Build and run immediately
        \\  build  Build binary in current directory
        \\  ir     Print LLVM IR to stdout
        \\  asm    Emit assembly (.s) file
        \\  lsp    Start language server (LSP)
        \\
        \\Options:
        \\  --target <target>   Target triple or shorthand: wasm, macos, linux, windows, ios, ios-sim (default: host)
        \\  --cpu <name>        CPU name (default: generic)
        \\  --opt <level>       Optimization: none/0, less/1, default/2, aggressive/3
        \\  -o <path>           Output path
        \\  -L <path>           Library search path (repeatable)
        \\  --linker <cmd>      Linker command (default: cc)
        \\  --sysroot <path>    Sysroot for cross-compilation
        \\  --lflags <flag>      Extra linker flag (repeatable, e.g. --lflags -sUSE_SDL=2)
        \\  --bundle <Name.app> Wrap the binary in an iOS/macOS .app bundle (after linking)
        \\  --bundle-id <id>    CFBundleIdentifier (required with --bundle)
        \\  --codesign-identity <name>   Codesigning identity (e.g. "Apple Development: ...")
        \\  --provisioning-profile <path>  .mobileprovision to embed (required for device)
        \\  --entitlements <path>  Entitlements plist (auto-extracted from profile if omitted)
        \\  --cache             Enable build caching
        \\  --emit-obj          Keep the debuggable object (DWARF; implies -O0) for lldb/gdb
        \\  --time              Show compilation timing breakdown
        \\
    , .{});
}

fn runLsp(allocator: std.mem.Allocator, io: std.Io, stdlib_paths: []const []const u8) void {
    const Transport = sx.lsp.transport.Transport;
    const Server = sx.lsp.server.Server;

    const stdin_file = std.Io.File.stdin();
    const stdout_file = std.Io.File.stdout();

    var read_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.readerStreaming(io, &read_buf);

    var transport = Transport.init(allocator, io, &stdin_reader.interface, stdout_file);
    var server = Server.init(allocator, &transport, io, stdlib_paths);

    while (true) {
        const msg = transport.readMessage() catch |err| {
            if (err == error.EndOfStream) break;
            std.debug.print("lsp: read error: {}\n", .{err});
            break;
        };

        const keep_going = server.handleMessage(msg);

        if (!keep_going) break;
    }
}

fn deriveOutputName(input_path: []const u8) []const u8 {
    // Get basename (strip directory)
    var start: usize = 0;
    for (input_path, 0..) |ch, idx| {
        if (ch == '/' or ch == '\\') start = idx + 1;
    }
    const basename = input_path[start..];
    // Strip .sx extension
    if (std.mem.endsWith(u8, basename, ".sx")) {
        return basename[0 .. basename.len - 3];
    }
    return basename;
}


/// Format the "interpreter bailed during X" message, attaching the IR op
/// and the source location (line:col) when the interpreter captured them.
fn printInterpBailDiag(comp: *const sx.core.Compilation, label: []const u8, err: anyerror) void {
    _ = comp;
    // The comptime VM is the sole evaluator; a bail sets comptime_vm.last_bail_reason.
    if (sx.ir.comptime_vm.last_bail_reason) |reason| {
        std.debug.print("error: {s} failed: {s}: {s}\n", .{ label, @errorName(err), reason });
        return;
    }
    std.debug.print("error: {s} failed: {s}\n", .{ label, @errorName(err) });
}

fn readSource(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8) ![:0]const u8 {
    const source_bytes = std.Io.Dir.readFileAlloc(.cwd(), io, input_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("error: cannot read '{s}': {}\n", .{ input_path, err });
        return error.CompileError;
    };
    return try allocator.dupeZ(u8, source_bytes);
}

fn compilePipeline(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, target_config: sx.target.TargetConfig, timer: *Timing, stdlib_paths: []const []const u8) !sx.core.Compilation {
    timer.mark();
    const source = try readSource(allocator, io, input_path);
    timer.record("read");

    var comp = sx.core.Compilation.init(allocator, io, input_path, source, target_config, stdlib_paths);
    errdefer comp.deinit();

    timer.mark();
    comp.parse() catch { comp.renderErrors(); return error.CompileError; };
    timer.record("parse");

    timer.mark();
    comp.resolveImports() catch { comp.renderErrors(); return error.CompileError; };
    timer.record("imports");

    timer.mark();
    comp.generateCode() catch { comp.renderErrors(); return error.CompileError; };
    timer.record("codegen");

    return comp;
}

fn dumpSxIR(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, stdlib_paths: []const []const u8) !void {
    const source = try readSource(allocator, io, input_path);
    var comp = sx.core.Compilation.init(allocator, io, input_path, source, .{}, stdlib_paths);
    defer comp.deinit();

    comp.parse() catch { comp.renderErrors(); return error.CompileError; };
    comp.resolveImports() catch { comp.renderErrors(); return error.CompileError; };

    var ir_module = comp.lowerToIR() catch { comp.renderErrors(); return error.CompileError; };
    defer ir_module.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    sx.ir.printModule(&ir_module, &aw.writer) catch return error.CompileError;
    var result = aw.writer.toArrayList();
    defer result.deinit(allocator);
    // Emit to stdout (fd 1), not stderr: `ir-dump` is a data-emitting command
    // meant to be piped/redirected. Matches `sx ir`'s stdout routing.
    _ = std.c.write(1, result.items.ptr, result.items.len);
}

fn emitIR(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, target_config: sx.target.TargetConfig, stdlib_paths: []const []const u8) !void {
    var timer = Timing.init(io, false);
    var comp = try compilePipeline(allocator, io, input_path, target_config, &timer, stdlib_paths);
    defer comp.deinit();
    comp.ir_emitter.?.printIR();
}

fn emitAsm(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, target_config: sx.target.TargetConfig, stdlib_paths: []const []const u8) !void {
    var timer = Timing.init(io, false);
    var comp = try compilePipeline(allocator, io, input_path, target_config, &timer, stdlib_paths);
    defer comp.deinit();
    const asm_path = target_config.output_path orelse blk: {
        const name = deriveOutputName(input_path);
        break :blk try std.fmt.allocPrint(allocator, "{s}.s", .{name});
    };
    const asm_path_z = try allocator.dupeZ(u8, asm_path);
    comp.ir_emitter.?.emitAssembly(asm_path_z.ptr) catch return error.CompileError;
    std.debug.print("emitted: {s}\n", .{asm_path});
}

fn compile(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, output_path: []const u8, target_config: sx.target.TargetConfig, show_timing: bool, enable_cache: bool, stdlib_paths: []const []const u8) !void {
    var timer = Timing.init(io, show_timing);
    try compileWithTimer(allocator, io, input_path, output_path, target_config, &timer, enable_cache, stdlib_paths);
    timer.printAll();
}

/// Driver-side adapter behind the `link` build-pipeline primitive (Phase 5). The
/// comptime VM can't link itself (it must not depend on `target`), so it
/// dispatches `link(...)` through a `BuildHooks` whose `ctx` is one of these. The
/// VM passes the full object list; `target.link` takes (first object, rest), but
/// treats both as plain inputs, so the split is immaterial.
const BuildHooksCtx = struct {
    comp: *sx.core.Compilation,
    obj_path: [:0]const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    base_config: sx.target.TargetConfig,
    has_jni_main: bool,

    /// `emit_object()` — emit the already verified/optimized module to its object file,
    /// return the path. The compiler no longer auto-emits; the sx driver calls this.
    fn emitObject(ctx_opaque: *anyopaque) anyerror![]const u8 {
        const self: *BuildHooksCtx = @ptrCast(@alignCast(ctx_opaque));
        const e = if (self.comp.ir_emitter) |*p| p else return error.NoEmitter;
        try e.emitObject(self.obj_path.ptr);
        return self.obj_path;
    }

    fn link(
        ctx_opaque: *anyopaque,
        objects: []const []const u8,
        output: []const u8,
        libraries: []const []const u8,
        frameworks: []const []const u8,
        flags: []const []const u8,
        target: []const u8,
    ) anyerror!void {
        _ = target; // the triple is already encoded in base_config (CLI-derived);
        // explicit-triple reconciliation is a P5.4 concern when sx owns the config.
        const self: *BuildHooksCtx = @ptrCast(@alignCast(ctx_opaque));
        if (objects.len == 0) return error.NoObjects;
        var cfg = self.base_config;
        // The passed `flags` are already the full merged set (`build_flags()` returns
        // the merged CLI + `#run` flags), so use them as-is rather than re-unioning.
        cfg.extra_link_flags = flags;
        try sx.target.link(self.allocator, self.io, objects[0], objects[1..], output, libraries, frameworks, cfg, self.has_jni_main);
    }
};

fn compileWithTimer(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, output_path: []const u8, target_config: sx.target.TargetConfig, timer: *Timing, enable_cache: bool, stdlib_paths: []const []const u8) !void {
    // Phase A: read + parse + resolveImports (fast: ~0.5ms)
    timer.mark();
    const source = try readSource(allocator, io, input_path);
    timer.record("read");

    var comp = sx.core.Compilation.init(allocator, io, input_path, source, target_config, stdlib_paths);
    defer comp.deinit();

    timer.mark();
    comp.parse() catch { comp.renderErrors(); return error.CompileError; };
    timer.record("parse");

    // Auto-import the stdlib build driver so `default_pipeline` (+ the build
    // primitives) is always present to drive the build — the program need not
    // import the prelude (e.g. minimal asm tests). A flat import is idempotent if
    // it's already pulled in transitively. BUILD-path only: the JIT `sx run` path
    // emits + executes in-process and never invokes default_pipeline.
    if (comp.root) |r| {
        const imp = try allocator.create(sx.ast.Node);
        imp.* = .{ .span = r.span, .source_file = input_path, .data = .{ .import_decl = .{ .path = "modules/build.sx", .name = null } } };
        const old_decls = r.data.root.decls;
        const new_decls = try allocator.alloc(*sx.ast.Node, old_decls.len + 1);
        new_decls[0] = imp;
        @memcpy(new_decls[1..], old_decls);
        r.data.root.decls = new_decls;
    }

    timer.mark();
    comp.resolveImports() catch { comp.renderErrors(); return error.CompileError; };
    timer.record("imports");

    // Extract library + framework names from AST (needed for linking regardless of cache)
    const root = comp.resolved_root orelse comp.root orelse return error.CompileError;
    const libs = try extractLibraries(allocator, root);
    var fws = try extractFrameworks(allocator, root);

    // Create temp directory for build artifacts
    const tmp_dir: []const u8 = ".sx-tmp";
    std.Io.Dir.createDirPath(.cwd(), io, tmp_dir) catch {};

    const obj_path = try std.fmt.allocPrintSentinel(allocator, "{s}/main.o", .{tmp_dir}, 0);

    // Codegen only. There is NO auto-emit / auto-link: the build is driven
    // entirely by the sx `default_pipeline` (or a user `#run on_build(...)`
    // override), invoked after codegen below. `emit_object` (verify + object
    // emission) and `link` run as sx-called ACTIONS through the build hooks.
    // (The build cache short-circuited codegen, which the always-run sx driver
    // can't tolerate — removed; a future cache can live inside default_pipeline.)
    _ = enable_cache;
    timer.mark();
    comp.generateCode() catch { comp.renderErrors(); return error.CompileError; };
    timer.record("codegen");

    // Compile C sources from #import c blocks to .o files
    timer.mark();
    const c_obj_paths = compileCForBuild(allocator, io, &comp, tmp_dir) catch {
        std.debug.print("error: C import compilation failed\n", .{});
        return error.CompileError;
    };
    timer.record("c-import");

    // Merge build config (from #run blocks) with CLI config
    var merged_config = target_config;
    const build_flags = comp.getBuildLinkFlags();
    const build_fws = comp.getBuildFrameworks();
    if (build_fws.len > 0) {
        var merged_fws: std.ArrayList([]const u8) = .empty;
        for (fws) |f| try merged_fws.append(allocator, f);
        for (build_fws) |f| try merged_fws.append(allocator, f);
        // Shadow the outer `fws` for the rest of the function by reassignment.
        fws = try merged_fws.toOwnedSlice(allocator);
    }

    if (build_flags.len > 0) {
        var all_flags: std.ArrayList([]const u8) = .empty;
        for (target_config.extra_link_flags) |f| try all_flags.append(allocator, f);
        for (build_flags) |f| try all_flags.append(allocator, f);
        merged_config.extra_link_flags = try all_flags.toOwnedSlice(allocator);
    }
    // Override output path from #run if set (and no explicit -o was given on CLI)
    const final_output = if (target_config.output_path == null)
        (comp.getBuildOutputPath() orelse output_path)
    else
        output_path;

    // Override WASM shell template from #run if set
    if (comp.getBuildWasmShell()) |shell| {
        merged_config.wasm_shell_path = shell;
    }

    // Ensure output directory exists
    if (std.mem.lastIndexOfScalar(u8, final_output, '/')) |sep| {
        if (sep > 0) {
            std.Io.Dir.createDirPath(.cwd(), io, final_output[0..sep]) catch {};
        }
    }

    // NO auto-link here — the sx `default_pipeline` (or a user `on_build`
    // override) calls `link` (and `emit_object`) as actions through these hooks.
    // The ctx lives on this stack frame so it outlives the callback below.
    var build_ctx = BuildHooksCtx{
        .comp = &comp,
        .obj_path = obj_path,
        .allocator = allocator,
        .io = io,
        .base_config = merged_config,
        .has_jni_main = comp.getJniMainEmissions().len > 0,
    };
    var build_hooks = sx.ir.compiler_hooks.BuildHooks{
        .ctx = &build_ctx,
        .emit_object = BuildHooksCtx.emitObject,
        .link = BuildHooksCtx.link,
    };

    // Make the linked binary's path + bundling config visible to the
    // post-link callback via `BuildOptions.binary_path()`,
    // `BuildOptions.bundle_path()`, etc. CLI flags
    // (`--bundle Foo.app`, `--bundle-id`, ...) feed in here so the sx
    // bundler doesn't need a separate code path.
    if (comp.ir_emitter) |*e| {
        e.build_config.binary_path = final_output;
        e.build_config.build_hooks = &build_hooks;
        // `--apk <path>` is a transitional alias for the bundle_path
        // → post_link_module = "platform.bundle" auto-fallback. The
        // sx Android bundler reads `bundle_path()` regardless of which
        // CLI flag the user typed.
        if (e.build_config.bundle_path == null) e.build_config.bundle_path = merged_config.bundle_path orelse merged_config.apk_path;
        if (e.build_config.bundle_id == null) e.build_config.bundle_id = merged_config.bundle_id;
        if (e.build_config.codesign_identity == null) e.build_config.codesign_identity = merged_config.codesign_identity;
        if (e.build_config.provisioning_profile == null) e.build_config.provisioning_profile = merged_config.provisioning_profile;
        // Target triple + framework lists drive the sx bundler's per-platform
        // branching (iOS device vs simulator vs macOS) and `Frameworks/`
        // embedding. Slice fields point into the long-lived target_config /
        // CLI argv buffers, which outlive the post-link callback.
        if (merged_config.triple) |t| {
            e.build_config.target_triple = std.mem.span(t);
        } else {
            // Host build (no `--target`): expose the HOST triple so the sx
            // bundler's `is_macos()`/`is_ios()`/… predicates resolve correctly.
            // Left empty, a host macOS `.app` would get the flat iOS-style layout
            // (is_macos() == false) instead of `Contents/MacOS/`.
            const host = sx.llvm_api.c.LLVMGetDefaultTargetTriple();
            defer sx.llvm_api.c.LLVMDisposeMessage(host);
            e.build_config.target_triple = allocator.dupe(u8, std.mem.span(host)) catch null;
        }
        e.build_config.target_frameworks = fws;
        e.build_config.target_framework_paths = merged_config.framework_paths;
        // Phase 5: the sx-driven build pipeline reads these via the
        // `c_object_paths()` / `link_libraries()` / `build_*()` primitives. Slices
        // reference compileWithTimer locals that outlive the callback.
        e.build_config.c_object_paths = c_obj_paths;
        e.build_config.link_libraries = libs;
        e.build_config.output_path = final_output;
        e.build_config.merged_link_flags = merged_config.extra_link_flags;
        // Android-specific bundling state.
        if (e.build_config.manifest_path == null) e.build_config.manifest_path = merged_config.manifest_path;
        if (e.build_config.keystore_path == null) e.build_config.keystore_path = merged_config.keystore_path;
        // `#jni_main` decls flow from the compiler's lowering pass —
        // pre-rendered Java sources + the runtime_path for each. Build
        // two parallel slices since BuildConfig hooks return strings.
        const jni_decls = comp.getJniMainEmissions();
        if (jni_decls.len > 0) {
            // If the output path was set via `BuildOptions.set_output_path`
            // (i.e. from a #run block, not CLI -o), the Java sources were
            // rendered during lowering before we knew the .so basename and
            // they're missing the `static { System.loadLibrary(...); }`
            // block. Inject it now using the final resolved output.
            const lib_name: ?[]const u8 = blk: {
                const base = std.fs.path.basename(final_output);
                if (!std.mem.startsWith(u8, base, "lib")) break :blk null;
                if (!std.mem.endsWith(u8, base, ".so")) break :blk null;
                break :blk base[3 .. base.len - 3];
            };
            const fps = try allocator.alloc([]const u8, jni_decls.len);
            const srcs = try allocator.alloc([]const u8, jni_decls.len);
            for (jni_decls, 0..) |em, idx| {
                fps[idx] = em.runtime_path;
                srcs[idx] = if (lib_name) |ln|
                    try sx.ir.jni_java_emit.injectLoadLibrary(allocator, em.java_source, ln)
                else
                    em.java_source;
            }
            e.build_config.jni_main_runtime_paths = fps;
            e.build_config.jni_main_java_sources = srcs;
        }
    }

    // Post-link build driver. Either the user registered an `on_build(cb)`
    // override (bundling is `#run on_build(bundle_main);` — bundle_main runs the
    // emit+link core then wraps the `.app`/`.apk`), or we run the stdlib
    // `default_pipeline` (emit + link; it fails with a precise hint if a bundle was
    // requested via `--bundle`/`--apk` but no bundler was registered). The CLI
    // bundle flags only feed `BuildConfig` (bundle_path/id/…) — there is no Zig
    // bundler shim; bundling is entirely sx-driven. A `false` return fails the build.
    if (comp.getPostLinkCallback()) |fid| {
        const ret = comp.invokeByFuncId(fid, comp.getPostLinkTakesOptions()) catch |err| {
            printInterpBailDiag(&comp, "post-link callback", err);
            return error.CompileError;
        };
        if (ret.asBool() == false) {
            std.debug.print("error: post-link callback returned false\n", .{});
            return error.CompileError;
        }
    } else {
        // No override → run the force-lowered stdlib `default_pipeline`.
        const ret_opt = comp.invokeByName("default_pipeline", true) catch |err| {
            printInterpBailDiag(&comp, "default build pipeline", err);
            return error.CompileError;
        };
        if (ret_opt) |ret| {
            if (ret.asBool() == false) {
                std.debug.print("error: default build pipeline returned false\n", .{});
                return error.CompileError;
            }
        } else {
            std.debug.print("error: default build pipeline 'default_pipeline' not found (is the prelude imported?)\n", .{});
            return error.CompileError;
        }
    }

    // Post-process wasm HTML: inject content hash for cache busting
    if (merged_config.isEmscripten() and std.mem.endsWith(u8, final_output, ".html")) {
        sx.target.postProcessWasmHtml(allocator, io, final_output);
    }

    std.debug.print("compiled: {s}\n", .{final_output});

    // Clean up temp directory and all build artifacts. Under --emit-obj, keep
    // the object (DWARF for lldb/gdb) at its link-time path — the binary's
    // debug map resolves to it — and skip removing the temp dir.
    const shell_tmp = std.fmt.allocPrint(allocator, "{s}.shell.html", .{obj_path}) catch null;
    if (shell_tmp) |sp| std.Io.Dir.deleteFile(.cwd(), io, sp) catch {};
    for (c_obj_paths) |cop| {
        std.Io.Dir.deleteFile(.cwd(), io, cop) catch {};
    }
    if (target_config.emit_obj) {
        std.debug.print("debug object kept: {s} (DWARF; run lldb/gdb from the project root)\n", .{obj_path});
    } else {
        std.Io.Dir.deleteFile(.cwd(), io, obj_path) catch {};
        std.Io.Dir.deleteDir(.cwd(), io, tmp_dir) catch {};
    }
}

fn runAOT(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, target_config: sx.target.TargetConfig, timer: *Timing, enable_cache: bool, stdlib_paths: []const []const u8) !void {
    const tmp_bin = if (comptime @import("builtin").os.tag == .windows) "sx_run_tmp.exe" else "/tmp/sx_run_tmp";
    try compileWithTimer(allocator, io, input_path, tmp_bin, target_config, timer, enable_cache, stdlib_paths);
    defer {
        std.Io.Dir.deleteFile(.cwd(), io, tmp_bin) catch {};
    }

    timer.mark();
    var child = std.process.spawn(io, .{
        .argv = &.{tmp_bin},
    }) catch {
        std.debug.print("error: failed to run program\n", .{});
        return error.CompileError;
    };
    const term = child.wait(io) catch {
        std.debug.print("error: program execution failed\n", .{});
        return error.CompileError;
    };
    timer.record("exec");

    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        .signal => std.process.exit(1),
        .stopped, .unknown => std.process.exit(1),
    }
}

// --- Cache helpers ---

/// Content hash of the RUNNING compiler executable, computed once per
/// process (~11MB wyhash, a few ms). Mixed into the object-cache key so a
/// rebuilt compiler can never satisfy a key an older build produced
/// (issue 0336 — the cache silently replayed stale codegen). Null when the
/// executable cannot be located or read: the caller must treat that as
/// cache-off — slower but never stale.
var g_compiler_hash: ?u64 = null;
var g_compiler_hash_computed: bool = false;
fn compilerSelfHash(allocator: std.mem.Allocator, io: std.Io) ?u64 {
    if (g_compiler_hash_computed) return g_compiler_hash;
    g_compiler_hash_computed = true;
    const exe_path = sx.imports.selfExePath(allocator) catch return null;
    defer allocator.free(exe_path);
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, exe_path, allocator, .limited(512 * 1024 * 1024)) catch return null;
    defer allocator.free(data);
    g_compiler_hash = std.hash.Wyhash.hash(0x5158_0336, data);
    return g_compiler_hash;
}

fn computeCacheKey(source: [:0]const u8, import_sources: *const std.StringHashMap([:0]const u8), target_config: sx.target.TargetConfig, compiler_hash: u64) u64 {
    const Wyhash = std.hash.Wyhash;
    var key = Wyhash.hash(compiler_hash, source);

    // XOR import hashes for order independence (HashMap iteration is non-deterministic)
    var import_hash: u64 = 0;
    var it = import_sources.iterator();
    while (it.next()) |entry| {
        var h = Wyhash.hash(0, entry.key_ptr.*);
        h = Wyhash.hash(h, entry.value_ptr.*);
        import_hash ^= h;
    }
    key = Wyhash.hash(key, std.mem.asBytes(&import_hash));

    // Hash target config fields that affect codegen
    if (target_config.triple) |t| key = Wyhash.hash(key, std.mem.span(t));
    if (target_config.cpu) |cp| key = Wyhash.hash(key, std.mem.span(cp));
    if (target_config.features) |f| key = Wyhash.hash(key, std.mem.span(f));
    key = Wyhash.hash(key, std.mem.asBytes(&target_config.opt_level));

    return key;
}

fn cachePath(allocator: std.mem.Allocator, key: u64, ext: []const u8) ![:0]const u8 {
    return try std.fmt.allocPrintSentinel(allocator, ".sx-cache/{x:0>16}.{s}", .{ key, ext }, 0);
}

fn saveObjectToCache(obj_buf: sx.llvm_api.c.LLVMMemoryBufferRef, io: std.Io, cache_path: [:0]const u8) void {
    const c_api = sx.llvm_api.c;
    const start = c_api.LLVMGetBufferStart(obj_buf);
    const size = c_api.LLVMGetBufferSize(obj_buf);
    if (start == null or size == 0) return;
    const data = @as([*]const u8, @ptrCast(start))[0..size];
    // Stage through a PID-UNIQUE temp inside the cache dir, then rename —
    // atomic on POSIX (same directory), so concurrent `--cache` processes
    // (the parallel corpus runner) never observe or clobber a half-written
    // object. The old fixed `.sx-cache-tmp` staging path raced (issue 0336).
    var tmp_buf: [64]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, ".sx-cache/.tmp-{d}", .{std.c.getpid()}) catch return;
    std.Io.Dir.createDirPath(.cwd(), io, ".sx-cache") catch return;
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = tmp, .data = data }) catch return;
    std.Io.Dir.rename(.cwd(), tmp, .cwd(), cache_path, io) catch {};
    std.Io.Dir.deleteFile(.cwd(), io, ".sx-cache-tmp") catch {};
}

fn hasTopLevelRun(root: *const sx.ast.Node) bool {
    for (root.data.root.decls) |decl| {
        if (decl.data == .comptime_expr) return true;
    }
    return false;
}

/// Does the program declare a `main` entry point? The JIT (and an AOT
/// binary) entry symbol is a flat function named `main`; this scans the
/// resolved AST for a `fn_decl` named "main", recursing into namespace
/// decls so a `main` brought in behind an aliased import is still found.
/// Used as a pre-JIT guard (issue 0137): the ORC `main` lookup does not
/// reliably surface "no main", so we reject the no-main program here with
/// a clean diagnostic instead of calling a garbage function pointer.
fn hasMainEntry(root: *const sx.ast.Node) bool {
    const walker = struct {
        fn walk(decls: []const *sx.ast.Node) bool {
            for (decls) |d| {
                switch (d.data) {
                    .fn_decl => |fd| {
                        if (std.mem.eql(u8, fd.name, "main")) return true;
                    },
                    .namespace_decl => |ns| {
                        if (walk(ns.decls)) return true;
                    },
                    else => {},
                }
            }
            return false;
        }
    };
    return walker.walk(root.data.root.decls);
}

fn extractLibraries(allocator: std.mem.Allocator, root: *const sx.ast.Node) ![]const []const u8 {
    var libs = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);
    // Aliased imports lower to namespace_decl nodes and NEST when a
    // namespaced module aliases its own imports, so the walk must recurse —
    // a `#library` at any namespace depth belongs on the link line / in the
    // JIT dlopen list.
    const walker = struct {
        fn walk(l: *std.ArrayList([]const u8), s: *std.StringHashMap(void), a: std.mem.Allocator, decls: []const *sx.ast.Node) !void {
            for (decls) |d| {
                switch (d.data) {
                    .library_decl => |ld| {
                        // The `compiler` library is the comptime-only internal
                        // surface (welded types / host-call functions), not a
                        // linkable dylib — never dlopen it. See
                        // design/comptime-compiler-api.md.
                        if (std.mem.eql(u8, ld.lib_name, sx.ir.compiler_lib.lib_name)) continue;
                        if (s.contains(ld.lib_name)) continue;
                        try s.put(ld.lib_name, {});
                        try l.append(a, ld.lib_name);
                    },
                    .namespace_decl => |ns| try walk(l, s, a, ns.decls),
                    else => {},
                }
            }
        }
    };
    try walker.walk(&libs, &seen, allocator, root.data.root.decls);
    return try libs.toOwnedSlice(allocator);
}

fn extractFrameworks(allocator: std.mem.Allocator, root: *const sx.ast.Node) ![]const []const u8 {
    var fws = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);
    // Same nested-namespace recursion as extractLibraries: `#framework`
    // declarations behind multiple aliased imports must still be linked.
    const walker = struct {
        fn walk(l: *std.ArrayList([]const u8), s: *std.StringHashMap(void), a: std.mem.Allocator, decls: []const *sx.ast.Node) !void {
            for (decls) |d| {
                switch (d.data) {
                    .framework_decl => |fd| {
                        if (s.contains(fd.name)) continue;
                        try s.put(fd.name, {});
                        try l.append(a, fd.name);
                    },
                    .namespace_decl => |ns| try walk(l, s, a, ns.decls),
                    else => {},
                }
            }
        }
    };
    try walker.walk(&fws, &seen, allocator, root.data.root.decls);
    return try fws.toOwnedSlice(allocator);
}

const LoadedLibrary = struct {
    handle: *anyopaque,
    /// The name dlopen succeeded on (full path or bare name) — reused
    /// verbatim as the JIT's priority search target for this library.
    path: [:0]const u8,
};

/// Try to dlopen a library by name, searching user paths, host paths, and common naming conventions.
fn loadLibrary(allocator: std.mem.Allocator, lib_name: []const u8, user_lib_paths: []const []const u8) ?LoadedLibrary {
    const is_macos = comptime @import("builtin").os.tag == .macos;
    const suffixes: []const []const u8 = if (is_macos) &.{ ".dylib", ".so" } else &.{ ".so", ".dylib" };

    // Search paths: user-supplied first, then host defaults
    const search_paths = comptime blk: {
        var paths: []const []const u8 = &.{};
        for (sx.target.host_lib_paths) |p| {
            paths = paths ++ .{p};
        }
        break :blk paths;
    };

    // Try each path with each suffix
    const all_paths = [_][]const []const u8{ user_lib_paths, search_paths };
    for (&all_paths) |paths| {
        for (paths) |dir| {
            for (suffixes) |sfx| {
                const full = std.fmt.allocPrintSentinel(allocator, "{s}/lib{s}{s}", .{ dir, lib_name, sfx }, 0) catch continue;
                if (std.c.dlopen(full.ptr, .{ .NOW = true })) |h| return .{ .handle = h, .path = full };
            }
        }
    }

    // Fallback: bare name (let dlopen search its default paths)
    for (suffixes) |sfx| {
        const bare = std.fmt.allocPrintSentinel(allocator, "lib{s}{s}", .{ lib_name, sfx }, 0) catch continue;
        if (std.c.dlopen(bare.ptr, .{ .NOW = true })) |h| return .{ .handle = h, .path = bare };
    }

    // Versioned-soname fallback (Linux): core system libs are installed ONLY
    // as versioned sonames — e.g. `libc.so.6`, `libssl.so.3`. The unversioned
    // `lib<name>.so` is a dev-only linker SCRIPT (text, not dlopen-able) or
    // absent, so the attempts above fail and we'd otherwise warn about a
    // `libc.dylib` that never exists. Scan the standard + multiarch lib dirs for
    // `lib<name>.so.*` and dlopen the first match. Not a libc special-case; it
    // resolves any versioned soname. (No-op on macOS — unversioned .dylib.)
    // We iterate via std.c.opendir/readdir/closedir (libc, with the platform-
    // correct readdir ABI baked in) rather than std.fs.Dir — the latter is
    // Io-based in zig 0.16 and this resolver runs with no Io handle (cf. the
    // raw readlink in imports.zig for the same constraint).
    if (@import("builtin").os.tag == .linux) {
        const multiarch = @tagName(@import("builtin").cpu.arch) ++ "-linux-gnu";
        const linux_dirs = [_][:0]const u8{
            "/lib/" ++ multiarch, "/usr/lib/" ++ multiarch,
            "/lib",               "/usr/lib",
            "/usr/local/lib",
        };
        const prefix = std.fmt.allocPrint(allocator, "lib{s}.so.", .{lib_name}) catch return null;
        for (linux_dirs) |dir| {
            const dh = std.c.opendir(dir.ptr) orelse continue;
            defer _ = std.c.closedir(dh);
            while (std.c.readdir(dh)) |ent| {
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
                if (!std.mem.startsWith(u8, name, prefix)) continue;
                const full = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0) catch continue;
                if (std.c.dlopen(full.ptr, .{ .NOW = true })) |h| return .{ .handle = h, .path = full };
            }
        }
    }

    return null;
}

// Simple timing helper — records stage durations and prints a summary table.
const Timing = struct {
    const max_entries = 16;

    enabled: bool,
    io: std.Io,
    names: [max_entries][]const u8,
    durations_ns: [max_entries]u64,
    count: usize,
    last: ?std.Io.Timestamp,

    fn init(io: std.Io, enabled: bool) Timing {
        return .{
            .enabled = enabled,
            .io = io,
            .names = undefined,
            .durations_ns = undefined,
            .count = 0,
            .last = if (enabled) std.Io.Timestamp.now(io, .awake) else null,
        };
    }

    fn mark(self: *Timing) void {
        if (self.enabled) self.last = std.Io.Timestamp.now(self.io, .awake);
    }

    fn record(self: *Timing, name: []const u8) void {
        if (!self.enabled) return;
        const now = std.Io.Timestamp.now(self.io, .awake);
        const elapsed_ns: u64 = if (self.last) |prev| @intCast(prev.durationTo(now).nanoseconds) else 0;
        if (self.count < max_entries) {
            self.names[self.count] = name;
            self.durations_ns[self.count] = elapsed_ns;
            self.count += 1;
        }
        self.last = now;
    }

    fn printAll(self: *const Timing) void {
        if (!self.enabled or self.count == 0) return;
        var total_ns: u64 = 0;
        for (self.durations_ns[0..self.count]) |d| total_ns += d;

        std.debug.print("\n--- timing ---\n", .{});
        for (0..self.count) |idx| {
            const ms = @as(f64, @floatFromInt(self.durations_ns[idx])) / 1_000_000.0;
            std.debug.print("  {s:<10} {d:>7.1} ms\n", .{ self.names[idx], ms });
        }
        const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
        std.debug.print("  {s:<10} {d:>7.1} ms\n", .{ "total", total_ms });
    }
};
