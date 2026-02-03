const std = @import("std");
const builtin = @import("builtin");
const corpus_paths = @import("corpus_paths");

// End-to-end example/issue regression runner. For every
// `<root>/expected/<name>.exit` marker under examples/ and issues/, spawn the
// installed `sx` binary on `<name>.sx`, capture stdout/stderr/exit, normalize,
// and diff against the stored snapshot. Optional `<name>.ir` snapshots
// additionally diff `sx ir` output; an `<name>.aot` marker switches the
// example from JIT `sx run` to a `sx build` + execute flow.
//
// This is the sole regression runner — `zig build test` is the only way to run
// the corpus (the legacy standalone `tests/run_examples.sh` was removed).
//
// Each example runs in its OWN subprocess (via std.process.run), so a crashing
// example reports its exit code (or 128+signal, matching a shell's `$?`) instead
// of taking down the test binary. A per-run deadline guards against hangs.
//
// Paths + the `sx` binary path are injected at configure time (build.zig
// `corpus_paths`); the FILE LIST is enumerated at test time, so new examples are
// covered with no edit here. The child runs with cwd = repo root and is handed a
// repo-relative path (e.g. `examples/0001-foo.sx`) — exactly the form the stored
// snapshots are normalized to, and the cwd `tests/fixtures/` imports resolve
// against. (The shell runner passes absolute paths and relies on a sed rule to
// collapse them back; running relatively makes that rule a no-op, so it is not
// reimplemented here.)
//
// Snapshots are regenerated in-build with `zig build test -Dupdate-goldens`
// (see the update-mode branch below) — no shell script needed.

/// Per-example wall-clock cap. This budgets COMPILE + run, and compile
/// dominates: the http-client examples spend ~5-7s of it in the compiler and
/// <0.5s actually running. At 10s the slowest example sat at 71% of budget on an
/// idle machine and tipped over under the suite's parallel load — a flake, not a
/// slow test. Sized for headroom against compile-time variance while still
/// catching a genuine hang.
const TIMEOUT_SECS = 30;
const MAX_OUTPUT = 16 * 1024 * 1024;

/// Wrap the live C `environ` so spawned children inherit the test process's
/// environment. `Io.Threaded`'s default `process_environ` is EMPTY, and a null
/// `environ_map` on a spawn falls back to it — so without this the child `sx`
/// runs with no PATH (and getenv-based examples like 1222 fail spuriously).
/// The slice points into the process-lifetime `environ` global; no copy needed.
fn currentEnviron() std.process.Environ {
    const raw: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    return .{ .block = .{ .slice = std.mem.span(raw) } };
}

var g_test_threaded: ?std.Io.Threaded = null;
fn test_io() std.Io {
    if (g_test_threaded == null) {
        g_test_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = currentEnviron() });
    }
    return g_test_threaded.?.io();
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// Collapse `0x` + 4-or-more lowercase-hex digits to `0xADDR` so heap/fn
/// addresses don't desync snapshots. (The path-collapse rule is intentionally
/// omitted — see file header.)
fn normalizeStd(arena: std.mem.Allocator, in: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < in.len) {
        if (in[i] == '0' and i + 1 < in.len and in[i + 1] == 'x') {
            var j = i + 2;
            while (j < in.len and isLowerHex(in[j])) j += 1;
            if (j - (i + 2) >= 4) {
                try out.appendSlice(arena, "0xADDR");
                i = j;
                continue;
            }
        }
        try out.append(arena, in[i]);
        i += 1;
    }
    return out.items;
}

/// `^attributes #[0-9]+ = \{` — one of normalize_ir's line-drop patterns.
fn isAttributesLine(line: []const u8) bool {
    const pfx = "attributes #";
    if (!std.mem.startsWith(u8, line, pfx)) return false;
    var k: usize = pfx.len;
    const start = k;
    while (k < line.len and line[k] >= '0' and line[k] <= '9') k += 1;
    return k > start and std.mem.startsWith(u8, line[k..], " = {");
}

fn dropIrLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "; ModuleID =") or
        std.mem.startsWith(u8, line, "source_filename =") or
        std.mem.startsWith(u8, line, "target datalayout =") or
        std.mem.startsWith(u8, line, "target triple =") or
        std.mem.startsWith(u8, line, "!") or
        isAttributesLine(line);
}

/// Apply `s/%([a-z]+)[0-9]+/%\1N/g` to one line — collapse LLVM's auto-suffixed
/// temporaries (`%tmp17` -> `%tmpN`) so renumbering doesn't desync snapshots.
/// O0 IR carries DWARF; remove `!dbg` attachments here so the legacy code-shape
/// snapshots do not depend on debug metadata numbering or source locations.
fn appendIrSubst(arena: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        const dbg_prefix: ?[]const u8 = if (std.mem.startsWith(u8, line[i..], ", !dbg !"))
            ", !dbg !"
        else if (std.mem.startsWith(u8, line[i..], " !dbg !"))
            " !dbg !"
        else
            null;
        if (dbg_prefix) |prefix| {
            var j = i + prefix.len;
            const digits_start = j;
            while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
            if (j > digits_start) {
                i = j;
                continue;
            }
        }
        if (line[i] == '%') {
            const lstart = i + 1;
            var j = lstart;
            while (j < line.len and line[j] >= 'a' and line[j] <= 'z') j += 1;
            const letters_end = j;
            const dstart = j;
            while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
            if (letters_end > lstart and j > dstart) {
                try out.append(arena, '%');
                try out.appendSlice(arena, line[lstart..letters_end]);
                try out.append(arena, 'N');
                i = j;
                continue;
            }
        }
        try out.append(arena, line[i]);
        i += 1;
    }
}

/// Normalize `sx ir` output for snapshot diffing: drop volatile module
/// header lines and collapse LLVM's auto-suffixed temporaries.
fn normalizeIr(arena: std.mem.Allocator, in: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, in, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (dropIrLine(line)) continue;
        if (!first) try out.append(arena, '\n');
        first = false;
        try appendIrSubst(arena, &out, line);
    }
    return out.items;
}

/// Match the shell runner's `$(...)` capture, which strips trailing newlines
/// from both expected and actual before comparing.
fn trimNl(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n");
}

/// bash `$?` convention: normal exit -> code; signal-terminated -> 128+signal.
fn termCode(term: std.process.Child.Term) u32 {
    return switch (term) {
        .exited => |c| c,
        .signal, .stopped => |s| 128 + @as(u32, @intCast(@intFromEnum(s))),
        .unknown => |u| u,
    };
}

fn deadline(io: std.Io) std.Io.Timeout {
    const dur: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromSeconds(TIMEOUT_SECS),
        .clock = .awake,
    };
    return .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, dur) };
}

fn readOptional(io: std.Io, gpa: std.mem.Allocator, abs_path: []const u8) ?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, abs_path, gpa, .limited(MAX_OUTPUT)) catch null;
}

/// True when `rel_path` (a repo-relative `.sx` path like `examples/0213-foo.sx`)
/// matches the `-Dname` filter — a comma-separated list of full `.sx` paths.
/// Each entry is whitespace-trimmed and a leading `./` is ignored, so both
/// `examples/0213-foo.sx` and `./examples/0213-foo.sx` match.
fn nameMatchesFilter(filter: []const u8, rel_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, filter, ',');
    while (it.next()) |raw| {
        var entry = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.startsWith(u8, entry, "./")) entry = entry[2..];
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, rel_path)) return true;
    }
    return false;
}

/// Per-example build/run directives, parsed from an optional `<name>.build`
/// JSON sidecar (replaces the old standalone `.aot` marker). Output snapshots
/// (.exit/.stdout/.stderr/.ir) stay separate — they are regenerated data, not
/// config. An unknown key is `error.UnknownField` (std.json default
/// `ignore_unknown_fields = false`), surfaced as a loud test failure — never a
/// silent ignore. Future directives (`cpu`, `link`, `cwd`) are just new
/// optional fields here, no new sidecar file.
const BuildConfig = struct {
    aot: bool = false,
    target: ?[]const u8 = null,
    /// Bundle smoke-test directive (requires `aot`). After a successful build the
    /// runner asserts each `expect` entry exists under `app` (repo-relative), then
    /// `rm -rf`s the `app`. macOS-host ONLY (the `.app` + `codesign` are Apple) —
    /// on any other host the example is SKIPPED (the bundler would take a different
    /// per-OS branch / fail codesign).
    bundle: ?BundleCheck = null,
    /// Android `.apk` bundle smoke-test directive. Cross-compiles for
    /// aarch64-linux-android (so the APK can't be executed here — build+inspect
    /// only, no exit/stdout/stderr snapshot). GATED on the Android SDK +
    /// a real JDK being available; when either is missing the example SKIPS
    /// cleanly so a plain `zig build test` on a bare host stays green.
    apk: ?ApkCheck = null,
    /// Host-OS gate (C4 / Linux CI). When set, the example runs ONLY on a host
    /// whose OS matches; on any other host it SKIPS cleanly (not a failure).
    /// For a one-off example whose runtime is host-OS-specific and that has no
    /// `target` ir-only fallback — e.g. links a libc symbol present only on one
    /// OS. Whole CATEGORIES that are inherently host-specific (e.g. `ffi-objc`,
    /// Apple's Objective-C runtime) are gated by `categoryHostOs` without a
    /// sidecar; this directive is the per-example override. Value is a
    /// `std.Target.Os.Tag` spelling (`macos` / `linux` / `windows`); `darwin`
    /// is accepted as an alias for `macos`.
    host_os: ?[]const u8 = null,

    /// Symbols that must NOT appear in the built binary (requires `aot`).
    ///
    /// This is how a compile-time-only function is held to its promise: a build
    /// callback runs during the build and must leave no trace in the output. A
    /// behavioural test cannot see the difference — the program's stdout is the
    /// same either way — so assert the symbol table directly.
    ///
    /// Matched against `nm` output as a whole symbol name, allowing one leading
    /// underscore (Mach-O prefixes them). Skipped where `nm` is unavailable.
    absent_symbols: ?[]const []const u8 = null,
};

const BundleCheck = struct {
    app: []const u8,
    expect: []const []const u8,
};

const ApkCheck = struct {
    /// Repo-relative output `.apk` path (conventionally under `.sx-tmp/`).
    out: []const u8,
    bundle_id: []const u8,
    /// Zip entries asserted present (substring match against `unzip -l` output).
    expect: []const []const u8,
};

/// Does `nm` output name `sym` as a whole symbol? Substring matching would let
/// `build` hit `build_options`, and `main` hit `domain_main` — a false pass is
/// worse than no test here.
fn nmHasSymbol(nm_out: []const u8, sym: []const u8) bool {
    var lines = std.mem.splitScalar(u8, nm_out, '\n');
    while (lines.next()) |line| {
        // `<addr> <type> <name>` — the name is the last field.
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        var last: ?[]const u8 = null;
        while (it.next()) |tok| last = tok;
        const name = last orelse continue;
        const bare = if (name.len > 0 and name[0] == '_') name[1..] else name;
        if (std.mem.eql(u8, bare, sym)) return true;
    }
    return false;
}

fn parseBuildConfig(a: std.mem.Allocator, text: []const u8) !BuildConfig {
    return std.json.parseFromSliceLeaky(BuildConfig, a, text, .{});
}

/// Expand the `sx --target` shorthands we care about to a triple whose `arch`
/// (token 0) and OS substring are stable — versions/vendors are irrelevant to
/// host matching. Mirrors the table in `main.zig`; unknown values pass through
/// (already a triple, or LLVM rejects later).
fn expandTargetShorthand(raw: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, raw, "macos") or eql(u8, raw, "macos-arm")) return "aarch64-apple-macos";
    if (eql(u8, raw, "macos-x86")) return "x86_64-apple-macos";
    if (eql(u8, raw, "linux") or eql(u8, raw, "linux-x86")) return "x86_64-linux-gnu";
    if (eql(u8, raw, "linux-arm")) return "aarch64-linux-gnu";
    if (eql(u8, raw, "windows")) return "x86_64-windows-msvc";
    if (eql(u8, raw, "ios") or eql(u8, raw, "ios-arm")) return "aarch64-apple-ios";
    if (eql(u8, raw, "ios-sim") or eql(u8, raw, "ios-sim-arm")) return "aarch64-apple-ios-simulator";
    if (eql(u8, raw, "wasm") or eql(u8, raw, "wasm32") or eql(u8, raw, "emscripten")) return "wasm32-unknown-emscripten";
    return raw;
}

/// `arm64` and `aarch64` name the same ISA; normalize so a `.build` may spell
/// either.
fn normalizeArch(arch: []const u8) []const u8 {
    return if (std.mem.eql(u8, arch, "arm64")) "aarch64" else arch;
}

/// Canonical OS name detected from a triple by substring, mapped to the
/// `std.Target.Os.Tag` spelling used by `@tagName`. Order matters: `ios` is
/// checked before `macos`/`darwin` (Apple triples share the `apple` vendor).
fn tripleOsName(triple: []const u8) ?[]const u8 {
    const has = std.mem.indexOf;
    if (has(u8, triple, "ios") != null) return "ios";
    if (has(u8, triple, "android") != null) return "linux"; // linux-android
    if (has(u8, triple, "macos") != null or has(u8, triple, "darwin") != null) return "macos";
    if (has(u8, triple, "linux") != null) return "linux";
    if (has(u8, triple, "windows") != null) return "windows";
    if (has(u8, triple, "emscripten") != null or has(u8, triple, "wasi") != null) return "emscripten";
    return null;
}

/// True when `value` (a `.build` target shorthand or triple) names the host's
/// arch AND OS — i.e. an example built for it can actually execute here. A
/// mismatch routes the example to ir-only mode (Phase 0.1).
fn hostMatchesTarget(value: []const u8) bool {
    const triple = expandTargetShorthand(value);
    const dash = std.mem.indexOfScalar(u8, triple, '-') orelse return false;
    const arch = normalizeArch(triple[0..dash]);
    if (!std.mem.eql(u8, arch, @tagName(builtin.cpu.arch))) return false;
    const os = tripleOsName(triple) orelse return false;
    return std.mem.eql(u8, os, @tagName(builtin.os.tag));
}

/// True when `name` (a `host_os` directive / `categoryHostOs` value) names the
/// running host's OS. `darwin` is accepted as an alias for `macos`.
fn hostOsMatches(name: []const u8) bool {
    const want = if (std.mem.eql(u8, name, "darwin")) "macos" else name;
    return std.mem.eql(u8, want, @tagName(builtin.os.tag));
}

/// The host OS a whole CATEGORY folder is pinned to, or null if the category is
/// portable. `ffi-objc` links Apple's Objective-C runtime + Foundation/AppKit,
/// which exist only on macOS — so the entire folder skips off a macOS host
/// (C4 / Linux CI), with no per-example `host_os` sidecar needed. Keep this list
/// minimal: prefer the per-example `host_os` directive for one-offs.
fn categoryHostOs(rel_prefix: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(rel_prefix);
    if (std.mem.eql(u8, base, "ffi-objc")) return "macos";
    return null;
}

/// `base` with `--target <t>` appended when `target` is set, else `base`
/// unchanged. `--target` is a global `sx` flag (main.zig), valid after any
/// subcommand.
fn withTarget(a: std.mem.Allocator, base: []const []const u8, target: ?[]const u8) ![]const []const u8 {
    const t = target orelse return base;
    const v = try a.alloc([]const u8, base.len + 2);
    @memcpy(v[0..base.len], base);
    v[base.len] = "--target";
    v[base.len + 1] = t;
    return v;
}

/// True when an Android SDK directory is discoverable: `$ANDROID_HOME`, then
/// `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`. The first whose `dir`
/// exists wins.
fn envVar(key: []const u8) ?[]const u8 {
    return std.process.Environ.getPosix(currentEnviron(), key);
}

fn androidSdkAvailable(a: std.mem.Allocator, io: std.Io) bool {
    const env_keys = [_][]const u8{ "ANDROID_HOME", "ANDROID_SDK_ROOT" };
    for (env_keys) |key| {
        const val = envVar(key) orelse continue;
        if (val.len == 0) continue;
        if (std.Io.Dir.access(.cwd(), io, val, .{})) |_| return true else |_| {}
    }
    // Fall back to the default macOS install location under $HOME.
    const home = envVar("HOME") orelse return false;
    if (home.len == 0) return false;
    const path = std.fs.path.join(a, &.{ home, "Library/Android/sdk" }) catch return false;
    if (std.Io.Dir.access(.cwd(), io, path, .{})) |_| return true else |_| {}
    return false;
}

/// True when a real JDK `javac` is on PATH. The macOS `/usr/bin/javac` stub
/// returns non-zero ("Unable to locate a Java Runtime") when no JDK is
/// installed, so we require `javac -version` to exit 0.
fn jdkAvailable(a: std.mem.Allocator, io: std.Io) bool {
    const res = std.process.run(a, io, .{
        .argv = &.{ "javac", "-version" },
        .timeout = deadline(io),
    }) catch return false;
    return termCode(res.term) == 0;
}

/// Remove the APK, the staged `.so`, and the bundler's intermediates
/// (`<apk>.stage` dir, `<apk>.unaligned`/`.aligned`) so a smoke test leaves no
/// litter. Best-effort `/bin/rm -rf` — failures are ignored.
fn cleanupApk(a: std.mem.Allocator, io: std.Io, out_abs: []const u8, so_abs: []const u8) void {
    const targets = [_][]const u8{
        out_abs,
        so_abs,
        std.fmt.allocPrint(a, "{s}.stage", .{out_abs}) catch return,
        std.fmt.allocPrint(a, "{s}.unaligned", .{out_abs}) catch return,
        std.fmt.allocPrint(a, "{s}.aligned", .{out_abs}) catch return,
        std.fmt.allocPrint(a, "{s}.idsig", .{out_abs}) catch return, // apksigner sidecar
    };
    for (targets) |t| {
        _ = std.process.run(a, io, .{
            .argv = &.{ "/bin/rm", "-rf", t },
            .timeout = deadline(io),
        }) catch {};
    }
}

/// Run every `<root>/expected/*.exit` test. Appends a formatted diagnostic to
/// `failures` (owned by `fail_gpa`) for each mismatch. Returns the number of
/// tests actually run (markers whose `.sx` is missing are skipped).
/// Sweep a corpus root, discovering every `expected/` directory under it and
/// running the markers in each. Two layouts are supported simultaneously:
///   * flat:     `<root>/expected/<name>.exit` with `<root>/<name>.sx`
///               (used by `issues/`)
///   * by-category: `<root>/<cat>/expected/<name>.exit` with
///                  `<root>/<cat>/<name>.sx` (used by `examples/`)
/// `rel_prefix` (the source dir relative to repo root, e.g. `examples/basic`)
/// is what gets handed to `sx` as the repo-relative `.sx` path, so diagnostics
/// and snapshots stay normalized to the on-disk location.
fn sweepRoot(
    fail_gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    failures: *std.ArrayList([]const u8),
) !usize {
    // Repo root (parent of examples/ or issues/) is the child's cwd: relative
    // source paths land in diagnostics already-normalized, and tests/fixtures/
    // imports resolve here.
    const repo_root = std.fs.path.dirname(root_dir) orelse ".";
    const root_base = std.fs.path.basename(root_dir); // "examples" | "issues"

    var arena_state = std.heap.ArenaAllocator.init(fail_gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var total: usize = 0;

    // A direct `<root>/expected/` (flat layout, e.g. issues/).
    if (std.Io.Dir.access(.cwd(), io, try std.fs.path.join(a, &.{ root_dir, "expected" }), .{})) |_| {
        total += try sweepExpectedDir(fail_gpa, io, repo_root, root_dir, root_base, failures);
    } else |_| {}

    // Each immediate child dir holding an `expected/` (by-category layout,
    // e.g. examples/<cat>/). Collect child names first — spawning subprocesses
    // while iterating the dir handle is asking for trouble.
    var root = std.Io.Dir.openDirAbsolute(io, root_dir, .{ .iterate = true }) catch return total;
    defer root.close(io);
    var child_names: std.ArrayList([]const u8) = .empty;
    var rit = root.iterate();
    while (try rit.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "expected")) continue;
        try child_names.append(a, try a.dupe(u8, entry.name));
    }
    for (child_names.items) |child| {
        const child_dir = try std.fs.path.join(a, &.{ root_dir, child });
        const child_expected = try std.fs.path.join(a, &.{ child_dir, "expected" });
        std.Io.Dir.access(.cwd(), io, child_expected, .{}) catch continue;
        const rel_prefix = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_base, child });
        total += try sweepExpectedDir(fail_gpa, io, repo_root, child_dir, rel_prefix, failures);
    }
    return total;
}

fn sweepExpectedDir(
    fail_gpa: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    source_dir: []const u8,
    rel_prefix: []const u8,
    failures: *std.ArrayList([]const u8),
) !usize {
    var name_arena_state = std.heap.ArenaAllocator.init(fail_gpa);
    defer name_arena_state.deinit();
    const name_arena = name_arena_state.allocator();

    const expected_dir_path = try std.fs.path.join(name_arena, &.{ source_dir, "expected" });
    var dir = std.Io.Dir.openDirAbsolute(io, expected_dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    // Collect marker names first (entry.name is only valid until the next
    // iterate step; spawning subprocesses mid-iteration is asking for trouble).
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue; // accept .file and .unknown d_type
        if (!std.mem.endsWith(u8, entry.name, ".exit")) continue;
        const name = entry.name[0 .. entry.name.len - ".exit".len];
        try names.append(name_arena, try name_arena.dupe(u8, name));
    }

    var work_state = std.heap.ArenaAllocator.init(fail_gpa);
    defer work_state.deinit();

    var ran: usize = 0;
    var skipped: usize = 0;
    var updated: usize = 0;
    for (names.items) |name| {
        _ = work_state.reset(.retain_capacity);
        const a = work_state.allocator();

        // `-Dname=<paths>` filter: when set, run ONLY the named example(s) (full
        // repo-relative `.sx` paths, comma-separated). A non-matching example is
        // dropped silently — not counted as ran or skipped.
        if (corpus_paths.name.len > 0) {
            const this_rel = try std.fmt.allocPrint(a, "{s}/{s}.sx", .{ rel_prefix, name });
            if (!nameMatchesFilter(corpus_paths.name, this_rel)) continue;
        }

        const sx_abs = try std.fs.path.join(a, &.{ source_dir, try std.fmt.allocPrint(a, "{s}.sx", .{name}) });
        std.Io.Dir.access(.cwd(), io, sx_abs, .{}) catch { // marker without source
            skipped += 1;
            std.debug.print("[corpus-run] skip {s} (no {s}.sx)\n", .{ name, name });
            continue;
        };
        ran += 1;

        const rel_path = try std.fmt.allocPrint(a, "{s}/{s}.sx", .{ rel_prefix, name });
        const exp_dir = expected_dir_path;
        const exit_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.exit", .{ exp_dir, name })) orelse "";
        const out_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.stdout", .{ exp_dir, name })) orelse "";
        const err_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.stderr", .{ exp_dir, name })) orelse "";
        const ir_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.ir", .{ exp_dir, name }));

        // Per-example directives live in an optional `<name>.build` JSON sidecar
        // (BuildConfig). `aot` switches the JIT `sx run` to a build+execute flow:
        // `sx build` links the sx object with any C `#source` companions into a
        // native binary, which is then executed — the ONLY way to exercise a
        // C-ABI symbol exported FROM sx (an `export` fn): in JIT mode the sx
        // symbol lives in JIT memory and is invisible to a dlopen'd C dylib's
        // flat-namespace lookup, so a C→sx-by-name call can only be linked
        // ahead-of-time. `target` threads `--target` and gates host execution.
        const cfg: BuildConfig = if (readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.build", .{ exp_dir, name }))) |raw|
            parseBuildConfig(a, raw) catch |err| {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: invalid .build config ({s})", .{ name, @errorName(err) }));
                continue;
            }
        else
            .{};
        // A bundle smoke test (`.app`/codesign) only makes sense on a macOS host —
        // skip it elsewhere (the bundler branches per-OS / codesign is Apple-only).
        if (cfg.bundle != null and builtin.target.os.tag != .macos) {
            ran -= 1;
            skipped += 1;
            std.debug.print("[corpus-run] skip {s} (bundle smoke test — macOS host only)\n", .{name});
            continue;
        }
        // An Android `.apk` smoke test needs the Android SDK AND a real JDK.
        // Missing either → skip (so a bare-host `zig build test` stays green).
        if (cfg.apk != null and !(androidSdkAvailable(a, io) and jdkAvailable(a, io))) {
            ran -= 1;
            skipped += 1;
            std.debug.print("[corpus-run] skip {s} (no Android SDK/JDK)\n", .{name});
            continue;
        }
        // Host-OS gate (C4): the per-example `host_os` directive, else the
        // example's category gate (`ffi-objc` → macOS). On a non-matching host
        // the example SKIPS cleanly so the corpus stays green off that host
        // (e.g. Objective-C examples on a Linux CI runner).
        if (cfg.host_os orelse categoryHostOs(rel_prefix)) |want_os| {
            if (!hostOsMatches(want_os)) {
                ran -= 1;
                skipped += 1;
                std.debug.print("[corpus-run] skip {s} ({s}-host only)\n", .{ name, want_os });
                continue;
            }
        }
        const is_aot = cfg.aot;

        // An example pinned to a non-host target cannot execute here; it routes
        // to ir-only mode (verify via `sx ir` only — see the first arm below).
        const ir_only = if (cfg.target) |t| !hostMatchesTarget(t) else false;

        // Android `.apk` smoke test: self-contained build+inspect branch. We
        // cross-compile for aarch64-linux-android (can't run on the host), so
        // there is NO exit/stdout/stderr/ir snapshot — this branch asserts the
        // produced APK's zip entries and then `continue`s, never falling through
        // to the stream snapshot comparison below.
        if (cfg.apk) |ac| {
            const out_abs = try std.fs.path.join(a, &.{ repo_root, ac.out });
            // Android requires the shared-lib basename to start with `lib`.
            const so_abs = try std.fmt.allocPrint(a, "{s}/.sx-tmp/libsxapk_{s}.so", .{ repo_root, name });
            const build_res = std.process.run(a, io, .{
                .argv = &.{
                    corpus_paths.sx_exe, "build",
                    "--target",          "android",
                    "--apk",             out_abs,
                    "--bundle-id",       ac.bundle_id,
                    "-o",                so_abs,
                    rel_path,
                },
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            }) catch |err| {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: `sx build --target android` {s}{s}", .{
                    name, @errorName(err), if (err == error.Timeout) " (>10s)" else "",
                }));
                continue;
            };
            if (termCode(build_res.term) != 0) {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: apk build failed (exit {d})\n{s}", .{
                    name, termCode(build_res.term), trimNl(build_res.stderr),
                }));
                cleanupApk(a, io, out_abs, so_abs);
                continue;
            }
            // Inspect the APK's zip entries via `unzip -l`; each `expect` entry
            // must appear as a substring of the listing.
            const list_res = std.process.run(a, io, .{
                .argv = &.{ "unzip", "-l", out_abs },
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            }) catch |err| {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: `unzip -l` {s}", .{ name, @errorName(err) }));
                cleanupApk(a, io, out_abs, so_abs);
                continue;
            };
            if (termCode(list_res.term) != 0) {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: `unzip -l` failed (exit {d}) — apk not produced?\n{s}", .{
                    name, termCode(list_res.term), trimNl(list_res.stderr),
                }));
                cleanupApk(a, io, out_abs, so_abs);
                continue;
            }
            for (ac.expect) |entry| {
                if (std.mem.indexOf(u8, list_res.stdout, entry) == null) {
                    try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: apk missing entry '{s}' in {s}", .{ name, entry, ac.out }));
                }
            }
            cleanupApk(a, io, out_abs, so_abs);
            continue;
        }

        var act_exit: u32 = undefined;
        var act_out: []const u8 = undefined;
        var act_err: []const u8 = undefined;
        var act_ir: ?[]const u8 = null;

        if (ir_only) {
            // Cross-target: cannot run on this host. Verify via `sx ir` only —
            // exit code, the IR snapshot (stdout), and diagnostics (stderr). An
            // .ir snapshot is REQUIRED: without it an arch-pinned example would
            // assert nothing. Its absence is a loud failure, never a silent pass.
            if (ir_raw == null) {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: cross-target example (target={s}) needs an .ir snapshot for ir-only mode", .{ name, cfg.target.? }));
                continue;
            }
            const ir_res = std.process.run(a, io, .{
                .argv = try withTarget(a, &.{ corpus_paths.sx_exe, "ir", rel_path, "--opt", "0" }, cfg.target),
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            }) catch |err| {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: `sx ir` {s}{s}", .{ name, @errorName(err), if (err == error.Timeout) " (>10s)" else "" }));
                continue;
            };
            act_exit = termCode(ir_res.term);
            act_out = ""; // stdout carries IR (asserted via .ir), not a separate stream
            act_err = trimNl(try normalizeStd(a, ir_res.stderr));
            act_ir = trimNl(try normalizeIr(a, ir_res.stdout));
        } else if (is_aot) {
            // Build a native executable, then run it. The build's own stderr
            // ("compiled: <path>") is intentionally discarded — only the built
            // program's streams are snapshotted. A build failure (e.g. an
            // unresolved exported symbol) surfaces as a non-zero exit with the
            // linker error on stderr.
            const bin_path = try std.fmt.allocPrint(a, "/tmp/sx_aot_{s}", .{name});
            const build_res = std.process.run(a, io, .{
                .argv = try withTarget(a, &.{ corpus_paths.sx_exe, "build", rel_path, "-o", bin_path }, cfg.target),
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            }) catch |err| {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: `sx build` {s}{s}", .{
                    name, @errorName(err), if (err == error.Timeout) " (>10s)" else "",
                }));
                continue;
            };
            if (termCode(build_res.term) != 0) {
                act_exit = termCode(build_res.term);
                act_out = "";
                act_err = trimNl(try normalizeStd(a, build_res.stderr));
            } else {
                const exec_res = std.process.run(a, io, .{
                    .argv = &.{bin_path},
                    .cwd = .{ .path = repo_root },
                    .timeout = deadline(io),
                }) catch |err| {
                    try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: exec AOT binary {s}{s}", .{
                        name, @errorName(err), if (err == error.Timeout) " (>10s)" else "",
                    }));
                    continue;
                };
                act_exit = termCode(exec_res.term);
                act_out = trimNl(try normalizeStd(a, exec_res.stdout));
                act_err = trimNl(try normalizeStd(a, exec_res.stderr));

                // Compile-time-only symbols must be absent from the binary.
                if (cfg.absent_symbols) |syms| {
                    const nm_res = std.process.run(a, io, .{
                        .argv = &.{ "nm", bin_path },
                        .cwd = .{ .path = repo_root },
                        .timeout = deadline(io),
                    }) catch null;
                    if (nm_res) |nr| {
                        if (termCode(nr.term) == 0) {
                            for (syms) |sym| {
                                if (nmHasSymbol(nr.stdout, sym)) {
                                    try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: '{s}' is in the binary's symbols but should be compile-time only", .{ name, sym }));
                                }
                            }
                        }
                    }
                }

                // Bundle smoke test: the `sx build` above ran the sx bundler
                // (default_pipeline → bundle_main) and produced an `.app`. Assert
                // its structure, then `rm -rf` it so it doesn't linger.
                if (cfg.bundle) |bc| {
                    const app_abs = try std.fs.path.join(a, &.{ repo_root, bc.app });
                    for (bc.expect) |entry| {
                        const entry_abs = try std.fs.path.join(a, &.{ app_abs, entry });
                        std.Io.Dir.access(.cwd(), io, entry_abs, .{}) catch {
                            try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: bundle missing '{s}' under {s}", .{ name, entry, bc.app }));
                        };
                    }
                    _ = std.process.run(a, io, .{
                        .argv = &.{ "/bin/rm", "-rf", app_abs },
                        .cwd = .{ .path = repo_root },
                        .timeout = deadline(io),
                    }) catch {};
                }
            }
        } else {
            // --- sx run ---
            const run_res = std.process.run(a, io, .{
                .argv = try withTarget(a, &.{ corpus_paths.sx_exe, "run", rel_path }, cfg.target),
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            }) catch |err| {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: `sx run` {s}{s}", .{
                    name,
                    @errorName(err),
                    if (err == error.Timeout) " (>10s)" else "",
                }));
                continue;
            };

            act_exit = termCode(run_res.term);
            act_out = trimNl(try normalizeStd(a, run_res.stdout));
            act_err = trimNl(try normalizeStd(a, run_res.stderr));
        }

        // --- sx ir (execute-mode only; ir-only produced act_ir above). Runs
        // when a snapshot already exists; mirrors the shell's `$has_ir` gate —
        // update mode never CREATES new .ir files. ---
        if (!ir_only and ir_raw != null) {
            const ir_res = std.process.run(a, io, .{
                .argv = try withTarget(a, &.{ corpus_paths.sx_exe, "ir", rel_path, "--opt", "0" }, cfg.target),
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            }) catch |err| {
                try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: `sx ir` {s}", .{ name, @errorName(err) }));
                continue;
            };
            // `sx ir` writes IR to stdout; mirror the shell's `2>&1` by appending
            // stderr (empty for a clean dump).
            const merged = try std.fmt.allocPrint(a, "{s}{s}", .{ ir_res.stdout, ir_res.stderr });
            act_ir = trimNl(try normalizeIr(a, merged));
        }

        // --- update mode: overwrite snapshots with freshly-normalized output ---
        if (corpus_paths.update_goldens) {
            try writeGolden(io, a, exp_dir, name, "exit", try std.fmt.allocPrint(a, "{d}", .{act_exit}));
            if (!ir_only) try writeGolden(io, a, exp_dir, name, "stdout", act_out);
            try writeGolden(io, a, exp_dir, name, "stderr", act_err);
            if (act_ir) |ir| try writeGolden(io, a, exp_dir, name, "ir", ir);
            updated += 1;
            continue;
        }

        // --- verify against stored snapshot ---
        const exp_exit = std.fmt.parseInt(u32, std.mem.trim(u8, exit_raw, " \t\r\n"), 10) catch {
            try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}: unparseable expected exit '{s}'", .{ name, std.mem.trim(u8, exit_raw, " \t\r\n") }));
            continue;
        };
        const exp_out = trimNl(try normalizeStd(a, out_raw));
        const exp_err = trimNl(try normalizeStd(a, err_raw));

        var diag: std.ArrayList(u8) = .empty;
        if (act_exit != exp_exit)
            try diag.appendSlice(a, try std.fmt.allocPrint(a, "  exit: expected={d} actual={d}\n", .{ exp_exit, act_exit }));
        if (!ir_only and !std.mem.eql(u8, act_out, exp_out))
            try appendDiff(a, &diag, "stdout", exp_out, act_out);
        if (!std.mem.eql(u8, act_err, exp_err))
            try appendDiff(a, &diag, "stderr", exp_err, act_err);
        if (ir_raw) |ir_expected_raw| {
            const exp_ir = trimNl(try normalizeIr(a, ir_expected_raw));
            if (!std.mem.eql(u8, act_ir.?, exp_ir))
                try appendDiff(a, &diag, "IR", exp_ir, act_ir.?);
        }

        try recordIfFailed(fail_gpa, failures, name, diag.items);
    }
    if (skipped > 0)
        std.debug.print("[corpus-run] {s}: {d} marker(s) skipped (no matching .sx)\n", .{ rel_prefix, skipped });
    if (corpus_paths.update_goldens)
        std.debug.print("[corpus-run] {s}: {d} snapshot(s) regenerated\n", .{ rel_prefix, updated });
    return ran;
}

/// Overwrite `<exp_dir>/<name>.<ext>` with `content` + a trailing newline —
/// matching the shell runner's `echo "$x" > file` (command substitution strips
/// trailing newlines; echo re-adds exactly one). Update mode only.
fn writeGolden(
    io: std.Io,
    a: std.mem.Allocator,
    exp_dir: []const u8,
    name: []const u8,
    ext: []const u8,
    content: []const u8,
) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}.{s}", .{ exp_dir, name, ext });
    const data = try std.fmt.allocPrint(a, "{s}\n", .{content});
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = data });
}

fn recordIfFailed(
    fail_gpa: std.mem.Allocator,
    failures: *std.ArrayList([]const u8),
    name: []const u8,
    diag: []const u8,
) !void {
    if (diag.len == 0) return;
    try failures.append(fail_gpa, try std.fmt.allocPrint(fail_gpa, "{s}:\n{s}", .{ name, diag }));
}

const DIFF_CAP = 2000;

fn appendDiff(a: std.mem.Allocator, diag: *std.ArrayList(u8), label: []const u8, expected: []const u8, actual: []const u8) !void {
    try diag.appendSlice(a, try std.fmt.allocPrint(a, "  --- {s}: expected ---\n{s}\n  --- {s}: actual ---\n{s}\n", .{
        label, cap(expected), label, cap(actual),
    }));
}

fn cap(s: []const u8) []const u8 {
    return if (s.len > DIFF_CAP) s[0..DIFF_CAP] else s;
}

/// Anything a PASSING test writes to stderr makes the Zig build runner print
/// `failed command: <cmd>` even though the build exits 0 — automated verifiers
/// grep for that and read a green build as broken. So stay silent unless there
/// is something to report (or `SX_CORPUS_VERBOSE` asks).
fn corpusVerbose() bool {
    return std.c.getenv("SX_CORPUS_VERBOSE") != null;
}

fn reportFailures(label: []const u8, ran: usize, failures: []const []const u8) !void {
    if (failures.len > 0 or corpusVerbose())
        std.debug.print("[corpus-run] {s}: {d} ran, {d} failed\n", .{ label, ran, failures.len });
    for (failures) |f| std.debug.print("FAIL {s}\n", .{f});
    if (failures.len > 0 and !corpus_paths.update_goldens) std.debug.print(
        \\
        \\  ── snapshot mismatch ──────────────────────────────────────────────
        \\  If the new output is CORRECT (intentional change), regenerate snapshots:
        \\      zig build test -Dupdate-goldens
        \\      git diff examples/expected/ issues/expected/   # review before committing
        \\  Otherwise this is a regression — fix the code, don't update the snapshot.
        \\  ───────────────────────────────────────────────────────────────────
        \\
    , .{});
    try std.testing.expect(failures.len == 0);
}

test "examples corpus: every examples/*.sx runs and matches its snapshot" {
    const io = test_io();
    var failures: std.ArrayList([]const u8) = .empty;
    defer failures.deinit(std.testing.allocator);

    const ran = try sweepRoot(std.testing.allocator, io, corpus_paths.examples_dir, &failures);
    defer for (failures.items) |f| std.testing.allocator.free(f);
    try std.testing.expect(ran > 0);
    try reportFailures("examples", ran, failures.items);
}

test "issues corpus: every pinned issues/*.sx repro runs and matches its snapshot" {
    const io = test_io();
    var failures: std.ArrayList([]const u8) = .empty;
    defer failures.deinit(std.testing.allocator);

    const ran = try sweepRoot(std.testing.allocator, io, corpus_paths.issues_dir, &failures);
    defer for (failures.items) |f| std.testing.allocator.free(f);
    try reportFailures("issues", ran, failures.items);
}

test "parseBuildConfig: defaults, fields, unknown key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty = try parseBuildConfig(a, "{}");
    try std.testing.expect(!empty.aot);
    try std.testing.expect(empty.target == null);

    const aot = try parseBuildConfig(a, "{ \"aot\": true }");
    try std.testing.expect(aot.aot);
    try std.testing.expect(aot.target == null);

    const tgt = try parseBuildConfig(a, "{ \"target\": \"x86_64-linux\" }");
    try std.testing.expect(!tgt.aot);
    try std.testing.expectEqualStrings("x86_64-linux", tgt.target.?);

    const bnd = try parseBuildConfig(a, "{ \"aot\": true, \"bundle\": { \"app\": \"x.app\", \"expect\": [\"Contents/MacOS\", \"Contents/Info.plist\"] } }");
    try std.testing.expect(bnd.aot);
    try std.testing.expectEqualStrings("x.app", bnd.bundle.?.app);
    try std.testing.expectEqual(@as(usize, 2), bnd.bundle.?.expect.len);
    try std.testing.expectEqualStrings("Contents/Info.plist", bnd.bundle.?.expect[1]);

    const apk = try parseBuildConfig(a, "{ \"apk\": { \"out\": \".sx-tmp/x.apk\", \"bundle_id\": \"co.example.x\", \"expect\": [\"AndroidManifest.xml\", \"classes.dex\", \"lib/arm64-v8a/\"] } }");
    try std.testing.expect(apk.apk != null);
    try std.testing.expectEqualStrings(".sx-tmp/x.apk", apk.apk.?.out);
    try std.testing.expectEqualStrings("co.example.x", apk.apk.?.bundle_id);
    try std.testing.expectEqual(@as(usize, 3), apk.apk.?.expect.len);
    try std.testing.expectEqualStrings("lib/arm64-v8a/", apk.apk.?.expect[2]);

    // Unknown key is a loud error, not a silent ignore.
    try std.testing.expectError(error.UnknownField, parseBuildConfig(a, "{ \"bogus\": 1 }"));
}

test "hostMatchesTarget: host arch+os matches, cross-arch does not" {
    const arch = @tagName(builtin.cpu.arch);
    const os = @tagName(builtin.os.tag);

    // A triple built from the host's own arch + os must match.
    var buf: [64]u8 = undefined;
    const host_triple = std.fmt.bufPrint(&buf, "{s}-unknown-{s}", .{ arch, os }) catch unreachable;
    try std.testing.expect(hostMatchesTarget(host_triple));

    // A different arch never matches (same os).
    const other_arch = if (builtin.cpu.arch == .x86_64) "aarch64" else "x86_64";
    var buf2: [64]u8 = undefined;
    const cross = std.fmt.bufPrint(&buf2, "{s}-unknown-{s}", .{ other_arch, os }) catch unreachable;
    try std.testing.expect(!hostMatchesTarget(cross));

    // `arm64` normalizes to `aarch64`.
    try std.testing.expect(normalizeArch("arm64").len == "aarch64".len);
}
