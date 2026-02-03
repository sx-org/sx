const std = @import("std");
const builtin = @import("builtin");
const math = @import("math");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const static_llvm = b.option(bool, "static-llvm", "Statically link LLVM (self-contained binary, no LLVM needed at runtime)") orelse false;
    const llvm_prefix = b.option([]const u8, "llvm-prefix", "Path to LLVM installation") orelse "/opt/homebrew/opt/llvm@22";

    const include_dir = b.fmt("{s}/include", .{llvm_prefix});
    const lib_dir = b.fmt("{s}/lib", .{llvm_prefix});
    const llvm_config = b.fmt("{s}/bin/llvm-config", .{llvm_prefix});

    const mod = b.addModule("sx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addSystemIncludePath(.{ .cwd_relative = include_dir });
    mod.addSystemIncludePath(.{ .cwd_relative = "." }); // for clang_shim.h
    mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    mod.link_libc = true;
    mod.addCSourceFile(.{
        .file = b.path("llvm_shim.c"),
        .flags = &.{b.fmt("-I{s}", .{include_dir})},
    });
    // FFI step 2.16c runtime — `_Thread_local`-backed JNIEnv* slot.
    // Linked into sx-the-compiler so the JIT process-symbol generator
    // can resolve `sx_jni_env_tl_get` / `sx_jni_env_tl_set` without the
    // user importing the runtime module. AOT outputs pick up the same
    // .c file via lower-side auto-injected c_import.
    mod.addCSourceFile(.{
        .file = b.path("library/vendors/sx_jni_runtime/sx_jni_env_tl.c"),
        .flags = &.{},
    });
    // ERR E3.1 runtime — `_Thread_local` error return-trace ring buffer.
    // Same linkage rationale as the JNIEnv* slot above: linked into the
    // compiler so the JIT resolves `sx_trace_*` via dlsym; AOT outputs pick it
    // up via a lower-side auto-injected c_import (gated on needs_trace_runtime).
    mod.addCSourceFile(.{
        .file = b.path("library/vendors/sx_trace_runtime/sx_trace.c"),
        .flags = &.{},
    });
    const target_os = target.result.os.tag;

    var cpp_flags: std.ArrayList([]const u8) = .empty;
    cpp_flags.appendSlice(b.allocator, &.{
        b.fmt("-I{s}", .{include_dir}),
        "-std=c++17",
        "-fno-rtti",
        "-fno-exceptions",
        // Zig turns UBSan on for C/C++ by default, emitting `__ubsan_handle_*`
        // calls into a runtime nothing links here — every non-Debug build then
        // fails to link this object. Debug hides it (it links the runtime).
        // Trap instead: the checks stay, the runtime dependency goes.
        "-fsanitize-trap=undefined",
        "-D__STDC_CONSTANT_MACROS",
        "-D__STDC_FORMAT_MACROS",
        "-D__STDC_LIMIT_MACROS",
        b.fmt("-DSX_LLVM_PREFIX=\"{s}\"", .{llvm_prefix}),
    }) catch @panic("OOM");
    // On Linux, apt's LLVM/clang is built against libstdc++ (GCC). Zig's clang
    // defaults to libc++, which isn't present here — so clang_shim.cpp can't
    // even find `<optional>`. Point it at the SYSTEM libstdc++ headers so it
    // compiles against the same C++ stdlib `libclang-cpp` uses (the std:: ABI
    // must match across the call boundary; zig's bundled libc++ would mismatch).
    // Discover the headers from g++'s version (e.g. 13 → /usr/include/c++/13 +
    // the arch-specific bits/ dir). Native-Linux build only.
    if (builtin.os.tag == .linux and target_os == .linux) {
        const gxxver = std.mem.trim(u8, b.run(&.{ "g++", "-dumpversion" }), " \t\r\n");
        const host_arch = @tagName(target.result.cpu.arch);
        cpp_flags.appendSlice(b.allocator, &.{
            // Compile against the SYSTEM libstdc++ headers (not zig's bundled
            // libc++), matching the ABI of apt's libstdc++-built libclang-cpp.
            // `-nostdinc++` drops zig's libc++ from the C++ search. The libstdc++
            // dirs go in via `-I` (not `-isystem`) ON PURPOSE: zig auto-adds
            // `/usr/include` ahead of any `-isystem` we pass, which would leave
            // the C++ dirs sorted AFTER it — and libstdc++'s `<cstdlib>` does
            // `#include_next <stdlib.h>`, which only searches dirs LATER than the
            // including C++ header. `-I` places the C++ dirs before `/usr/include`
            // so that `#include_next` resolves the C headers there. (Verified:
            // 0 libc++ symbols, libstdc++ `std::__cxx11::` ABI in the object.)
            "-nostdinc++",
            b.fmt("-I/usr/include/c++/{s}", .{gxxver}),
            b.fmt("-I/usr/include/{s}-linux-gnu/c++/{s}", .{ host_arch, gxxver }),
        }) catch @panic("OOM");
    }
    // clang_shim.cpp is ALWAYS compiled with `zig c++` into a standalone object,
    // then linked into `mod` — one compile path for every host. We deliberately
    // do NOT feed the .cpp to the module: a C++ source in a linked module puts the
    // whole compilation into zig's libc++ mode (force-links `-lc++` and prepends
    // zig's bundled `libcxx/include` as an explicit `-isystem` ahead of ours,
    // which not even `-nostdinc++` dislodges). That's fine on macOS — Homebrew
    // LLVM is libc++, which is also `zig c++`'s default — but breaks on Linux,
    // where apt's libclang-cpp is libstdc++ (1170+ `std::__cxx11::` exports, zero
    // libc++): the shim would emit `std::__1::` symbols absent from the lib →
    // undefined-symbol link errors. A standalone `zig c++` compile is not in
    // libc++ mode, so the Linux `-nostdinc++` + system libstdc++ `-isystem` flags
    // (appended to cpp_flags above) take effect and the object matches
    // libclang-cpp's ABI (verified: 0 `__1` refs). macOS, lacking those flags,
    // gets zig's default libc++ — matching Homebrew. Same mechanism, both hosts.
    {
        const cc = b.addSystemCommand(&.{ b.graph.zig_exe, "c++" });
        cc.addArgs(cpp_flags.items);
        cc.addPrefixedDirectoryArg("-I", b.path(".")); // for clang_shim.h
        cc.addArg("-c");
        cc.addFileArg(b.path("clang_shim.cpp"));
        cc.addArg("-o");
        const shim_obj = cc.addOutputFileArg("clang_shim.o");
        mod.addObjectFile(shim_obj);
    }

    if (static_llvm) {
        if (target_os == .windows) {
            // Windows target: enumerate LLVM .lib files in prefix.
            // Use the host-appropriate command to list files.
            const libs_raw = if (builtin.os.tag == .windows) blk: {
                const dir_cmd = b.fmt("dir /b {s}\\lib\\LLVM*.lib", .{llvm_prefix});
                break :blk std.mem.trim(u8, b.run(&.{ "cmd.exe", "/c", dir_cmd }), " \t\n\r");
            } else blk: {
                break :blk std.mem.trim(u8, b.run(&.{ "ls", lib_dir }), " \t\n\r");
            };
            var libs_it = std.mem.tokenizeAny(u8, libs_raw, "\r\n");
            while (libs_it.next()) |filename| {
                const trimmed = std.mem.trim(u8, filename, " \t");
                if (std.mem.endsWith(u8, trimmed, ".lib") and std.mem.startsWith(u8, trimmed, "LLVM")) {
                    mod.linkSystemLibrary(
                        trimmed[0 .. trimmed.len - 4],
                        .{ .preferred_link_mode = .static },
                    );
                }
            }
            // Windows system libraries LLVM depends on
            const win_syslibs = [_][]const u8{
                "advapi32", "shell32", "ole32",  "uuid",
                "psapi",    "version", "ntdll",  "ws2_32",
                "dbghelp",  "msvcprt",
            };
            for (&win_syslibs) |syslib| {
                mod.linkSystemLibrary(syslib, .{});
            }
        } else {
            // Unix target: query llvm-config for the static libraries needed
            const libs_raw = std.mem.trim(u8, b.run(&.{ llvm_config, "--libs", "--link-static" }), " \t\n\r");
            var libs_it = std.mem.tokenizeAny(u8, libs_raw, " \t\n\r");
            while (libs_it.next()) |flag| {
                if (flag.len > 2 and std.mem.startsWith(u8, flag, "-l")) {
                    mod.linkSystemLibrary(flag[2..], .{ .preferred_link_mode = .static });
                }
            }

            // Clang static libraries (for clang_shim: header parsing + C compilation)
            const clang_libs_raw = std.mem.trim(u8, b.run(&.{ "sh", "-c", b.fmt("ls {s}/lib/libclang*.a | xargs -n1 basename | sed 's/^lib//;s/\\.a$//'", .{llvm_prefix}) }), " \t\n\r");
            var clang_libs_it = std.mem.tokenizeAny(u8, clang_libs_raw, "\n");
            while (clang_libs_it.next()) |lib_name| {
                const trimmed = std.mem.trim(u8, lib_name, " \t\r");
                if (trimmed.len > 0) {
                    mod.linkSystemLibrary(trimmed, .{ .preferred_link_mode = .static });
                }
            }

            // System libraries LLVM depends on — link statically where possible.
            // Add homebrew lib paths for static archives.
            if (builtin.os.tag == .macos) {
                const homebrew_static_paths = [_][]const u8{
                    "/opt/homebrew/opt/zlib/lib",
                    "/opt/homebrew/opt/zstd/lib",
                    "/opt/homebrew/opt/ncurses/lib",
                };
                for (&homebrew_static_paths) |p| {
                    mod.addLibraryPath(.{ .cwd_relative = p });
                }
            }

            const syslibs_raw = std.mem.trim(u8, b.run(&.{ llvm_config, "--system-libs", "--link-static" }), " \t\n\r");
            var syslibs_it = std.mem.tokenizeAny(u8, syslibs_raw, " \t\n\r");
            while (syslibs_it.next()) |flag| {
                if (flag.len > 2 and std.mem.startsWith(u8, flag, "-l")) {
                    const name = flag[2..];
                    // Skip xml2 — only used by LLVM's Windows manifest parser (not needed)
                    if (std.mem.eql(u8, name, "xml2")) continue;
                    // Skip m — part of libSystem on macOS, libc on Linux
                    if (std.mem.eql(u8, name, "m")) continue;
                    mod.linkSystemLibrary(name, .{ .preferred_link_mode = .static });
                }
            }

            // On Linux, add the multiarch system library directory so LLVM's
            // system-lib dependencies (zstd, tinfo, xml2) are found by the linker.
            if (builtin.os.tag == .linux) {
                const multiarch = @tagName(builtin.cpu.arch) ++ "-linux-gnu";
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/" ++ multiarch });
            }
        }

        // LLVM is C++ — link the C++ standard library.
        // Windows/MSVC: msvcprt already linked above
        // Linux (apt LLVM): compiled with GCC, needs libstdc++
        // macOS (Homebrew LLVM): compiled with Clang, needs libc++
        if (target_os == .linux) {
            // Link the REAL system libstdc++ to match apt's libclang-cpp and the
            // clang_shim object (both libstdc++). We deliberately do NOT use
            // `linkSystemLibrary("stdc++")`: zig special-cases C++ stdlib names
            // (`isLibCxxLibName`) and silently rewrites that into its OWN libc++
            // (`-lc++`) — the wrong ABI, and it never links the real lib. So pull
            // the .so in by path (the `g++ -print-file-name` symlink → .so.6).
            const libstdcxx = std.mem.trim(u8, b.run(&.{ "g++", "-print-file-name=libstdc++.so" }), " \t\r\n");
            mod.addObjectFile(.{ .cwd_relative = libstdcxx });
        } else if (target_os != .windows) {
            mod.link_libcpp = true;
        }
    } else {
        mod.linkSystemLibrary("LLVM-22", .{});
        mod.linkSystemLibrary("clang-cpp", .{});
        // clang-cpp is C++ — link the matching C++ stdlib. macOS Homebrew LLVM
        // is libc++; Linux apt LLVM is libstdc++ (so clang_shim.cpp, compiled
        // against libstdc++ above, links the same one — no std:: ABI split).
        if (target_os == .linux) {
            // Link the REAL system libstdc++ to match apt's libclang-cpp and the
            // clang_shim object (both libstdc++). We deliberately do NOT use
            // `linkSystemLibrary("stdc++")`: zig special-cases C++ stdlib names
            // (`isLibCxxLibName`) and silently rewrites that into its OWN libc++
            // (`-lc++`) — the wrong ABI, and it never links the real lib. So pull
            // the .so in by path (the `g++ -print-file-name` symlink → .so.6).
            const libstdcxx = std.mem.trim(u8, b.run(&.{ "g++", "-print-file-name=libstdc++.so" }), " \t\r\n");
            mod.addObjectFile(.{ .cwd_relative = libstdcxx });
        } else if (target_os != .windows) {
            mod.link_libcpp = true;
        }
    }

    const exe = b.addExecutable(.{
        .name = "sx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sx", .module = mod },
            },
        }),
    });

    // Nothing in the Zig sources calls these C entry points — the JIT resolves
    // them via dlsym at comptime, and AOT output picks them up via an
    // auto-injected c_import. With no static reference, dead-strip drops them in
    // every non-Debug mode and `#run` fails with "symbol not found via dlsym",
    // so pin them as undefined to force retention.
    // `-u` matches the mangled name, and Mach-O prefixes C symbols with `_`.
    // Covered by tests/jit_symbols_retained.sh.
    const u_prefix: []const u8 = if (target_os == .macos) "_" else "";
    for ([_][]const u8{
        "sx_trace_push",
        "sx_trace_clear",
        "sx_trace_len",
        "sx_trace_frame_at",
        "sx_trace_truncated",
        "sx_trace_report_unhandled",
        "sx_jni_env_tl_get",
        "sx_jni_env_tl_set",
    }) |sym| {
        exe.forceUndefinedSymbol(b.fmt("{s}{s}", .{ u_prefix, sym }));
    }

    b.installArtifact(exe);

    // Install the stdlib alongside the binary so `<prefix>/bin/sx` finds
    // `<prefix>/library/modules/...` via the install-layout fallback in
    // `src/imports.zig::discoverStdlibPaths`.
    const install_library = b.addInstallDirectory(.{
        .source_dir = b.path("library"),
        .install_dir = .prefix,
        .install_subdir = "library",
    });
    b.getInstallStep().dependOn(&install_library.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Corpus paths for the corpus tests (src/lsp/corpus_sweep.test.zig — the
    // in-process analyzer sweep — and src/corpus_run.test.zig — the end-to-end
    // example/issue runner). Inject absolute corpus dirs + the installed `sx`
    // binary path at configure time so the tests are CWD-independent; the
    // runner still ENUMERATES the directory contents at runtime, so new
    // examples are covered with no test edit.
    const corpus_opts = b.addOptions();
    corpus_opts.addOption([]const u8, "examples_dir", b.path("examples").getPath(b));
    corpus_opts.addOption([]const u8, "issues_dir", b.path("issues").getPath(b));
    corpus_opts.addOption([]const u8, "library_dir", b.path("library").getPath(b));
    // Absolute path to the installed `sx` binary the corpus runner spawns per
    // example. The runner test depends on the install step (below) so this
    // exists — and so the sibling library/ tree the binary loads is in place.
    corpus_opts.addOption([]const u8, "sx_exe", b.getInstallPath(.bin, "sx"));
    // `zig build test -Dupdate-goldens` flips src/corpus_run.test.zig from
    // verify mode to regenerate mode: it overwrites each example's expected
    // .exit/.stdout/.stderr (+ .ir where one exists) with freshly-normalized
    // output instead of asserting against it. The in-build equivalent of the
    // legacy `run_examples.sh --update`.
    const update_goldens = b.option(
        bool,
        "update-goldens",
        "Regenerate example/issue snapshots instead of verifying them (use with `zig build test`)",
    ) orelse false;
    corpus_opts.addOption(bool, "update_goldens", update_goldens);
    // `zig build test -Dname=examples/0213-foo.sx[,examples/0214-bar.sx]` restricts
    // the corpus runner to ONLY the named example(s) — full repo-relative `.sx`
    // paths, comma-separated. Empty = run every example. Use it to verify or
    // regenerate (-Dupdate-goldens) a specific example without re-running (or
    // clobbering the snapshots of) the rest of the corpus. Because the value is
    // baked into the corpus options module, changing it also busts the cached
    // test-run result (the runner enumerates .sx/expected files at RUNTIME, so a
    // bare snapshot edit alone would otherwise be served from cache).
    const name_filter = b.option(
        []const u8,
        "name",
        "Run only the named example(s): comma-separated repo-relative .sx paths (e.g. examples/0213-foo.sx)",
    ) orelse "";
    corpus_opts.addOption([]const u8, "name", name_filter);
    mod.addOptions("corpus_paths", corpus_opts);

    // `zig build [test] -Dcomptime-flat` defaults comptime evaluation to the
    // flat-memory VM (`src/ir/comptime_vm.zig`), with the legacy tagged interpreter
    // as the per-eval fallback — the "swap behind a build flag" step of
    // `current/PLAN-COMPILER-VM.md`. Default OFF (legacy). The `SX_COMPTIME_FLAT`
    // env var enables it too (either turns it on); read in `emit_llvm.zig::init`.
    const comptime_flat = b.option(
        bool,
        "comptime-flat",
        "Default comptime evaluation to the flat-memory VM (legacy interp as fallback)",
    ) orelse false;
    // `-Dcomptime-flat-strict` (or env `SX_COMPTIME_FLAT_STRICT`): run EVERY comptime
    // eval on the VM with NO legacy fallback — a VM bail becomes a build-gating error
    // naming the reason. The enumeration gate for retiring `interp.zig`: when the
    // corpus is green under strict mode, the VM handles everything and legacy can be
    // deleted. Implies `comptime_flat`.
    const comptime_flat_strict = b.option(
        bool,
        "comptime-flat-strict",
        "Run all comptime eval on the VM with NO fallback; a bail is a hard error (interp-retirement gate)",
    ) orelse false;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "comptime_flat", comptime_flat);
    build_opts.addOption(bool, "comptime_flat_strict", comptime_flat_strict);
    mod.addOptions("build_opts", build_opts);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    // src/corpus_run.test.zig spawns the installed `sx` binary per example, so
    // the mod test binary must not run until `zig-out/bin/sx` + `zig-out/library`
    // are installed. This is what folds the full example/issue regression suite
    // into `zig build test` — no shell script, just a Zig test.
    run_mod_tests.step.dependOn(b.getInstallStep());

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests + the example/issue regression suite");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
