const std = @import("std");
const builtin = @import("builtin");
const corpus_paths = @import("corpus_paths");

// End-to-end example/issue regression runner. For every
// `<root>/expected/<name>.exit` marker under examples/ and issues/, spawn the
// installed `sx` binary on `<name>.sx`, capture stdout/stderr/exit, normalize,
// and diff against the stored snapshot. Optional `<name>.ir` snapshots
// additionally diff `sx ir` output; a `<name>.build` sidecar carries
// per-example directives (AOT, cross-target, bundle/apk smoke tests, ...).
//
// This is the sole regression runner — `zig build test` is the only way to run
// the corpus (the legacy standalone `tests/run_examples.sh` was removed).
//
// Each example runs in its OWN subprocess (via std.process.run), so a crashing
// example reports its exit code (or 128+signal, matching a shell's `$?`) instead
// of taking down the test binary. A per-run deadline guards against hangs.
//
// Execution model: the sweep first COLLECTS every runnable item (all categories,
// sequential directory walk), then runs them on a bounded worker-thread pool
// (default `min(8, cores - 2)`, override with `SX_CORPUS_JOBS=<n>`). Each item
// writes into its own preassigned result slot, and slots are reported in
// collection order after the pool drains — so failure output is deterministic
// regardless of completion order. An example whose `.build` sets
// `"serial": true` is held out of the pool and run sequentially afterwards —
// the escape hatch for wall-clock-sensitive tests (socket deadlines) that
// cannot tolerate a loaded machine.
//
// Timing: every run is measured. JIT examples additionally pass `--time` to
// `sx run`, whose stage table (a well-delimited stderr suffix, stripped before
// snapshot comparison) yields the true compile-vs-run split: the `jit` stage
// IS the program's run phase. AOT examples get the split for free (separate
// build/exec subprocesses). After each sweep a sorted per-example report is
// written to `.sx-tmp/corpus-timing-<root>.txt`; examples whose RUN phase
// exceeds the 1-second budget (AGENTS.md) are flagged there. The report is
// diagnostic output only — it never affects pass/fail.
//
// Paths + the `sx` binary path are injected at configure time (build.zig
// `corpus_paths`); the FILE LIST is enumerated at test time, so new examples are
// covered with no edit here. The child runs with cwd = repo root and is handed a
// repo-relative path (e.g. `examples/0001-foo.sx`) — exactly the form the stored
// snapshots are normalized to, and the cwd `tests/fixtures/` imports resolve
// against.
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

/// AGENTS.md budget: an example's RUN phase (post-compile) must fit in 1s.
const RUN_BUDGET_NS: u64 = 1_000_000_000;

/// Wrap the live C `environ` so spawned children inherit the test process's
/// environment. `Io.Threaded`'s default `process_environ` is EMPTY, and a null
/// `environ_map` on a spawn falls back to it — so without this the child `sx`
/// runs with no PATH (and getenv-based examples like 1222 fail spuriously).
/// The slice points into the process-lifetime `environ` global; no copy needed.
fn currentEnviron() std.process.Environ {
    const raw: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    return .{ .block = .{ .slice = std.mem.span(raw) } };
}

/// `sx build` writes fixed-path intermediates under the shared repo cwd —
/// `.sx-tmp/main.o` (kept there for lldb's debug map) and `.sx-tmp/sx_c_<i>.o`
/// — so two concurrent builds clobber each other. All build-pipeline
/// invocations (aot, apk) serialize on this mutex; the JIT majority (pid-unique
/// `/tmp` scratch, content-keyed cache) keeps the pool busy meanwhile. Executing
/// the built binary happens OUTSIDE the lock — its path is per-example.
/// (`std.Io.Mutex` futexes on a shared address, so it synchronizes across the
/// workers' separate `Io.Threaded` instances.)
var g_build_mutex: std.Io.Mutex = .init;

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

fn nowNs(io: std.Io) std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn elapsedNs(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    const ns = from.durationTo(to).nanoseconds;
    return if (ns > 0) @intCast(ns) else 0;
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

    /// Cross-target compile-only mode (requires `target`). The example is
    /// compiled for the target and asserts exit code + stderr ONLY — no `.ir`
    /// snapshot exists or is compared. This is the cross-target mode for
    /// examples whose point is "this compiles (or diagnoses) for the target":
    /// IR text tracks LLVM's printer, so snapshotting it tests LLVM, not sx
    /// (AGENTS.md: never snapshot LLVM IR).
    compile_only: bool = false,

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

    /// Run this example OUTSIDE the worker pool, sequentially after the
    /// parallel batch drains. For wall-clock-sensitive examples (socket read
    /// deadlines, stream pacing) that are correct on an idle machine but can
    /// tip over when N sibling compiles saturate the cores. Serial examples
    /// still count toward the run/skip totals and the timing report.
    serial: bool = false,
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

/// One runnable corpus entry, fully resolved at collection time. All strings
/// live in the sweep-wide arena, so worker threads only read them.
const Item = struct {
    source_dir: []const u8, // abs dir holding `<name>.sx`
    rel_prefix: []const u8, // repo-relative dir (e.g. `examples/http`)
    exp_dir: []const u8, // abs `<source_dir>/expected`
    name: []const u8,
    cfg: BuildConfig,
    /// Set when the `.build` sidecar failed to parse — reported as a failure
    /// by the worker (the item still occupies its slot for determinism).
    cfg_error: ?[]const u8,
};

/// A worker's entire report for one item. Every string is allocated from the
/// thread-safe results allocator and owned by the sweep. Slots are written by
/// exactly one worker and read only after the pool joins.
const Outcome = struct {
    ran: bool = false,
    failure: ?[]const u8 = null,
    skip_note: ?[]const u8 = null,
    updated: bool = false,
    /// Whole-item wall clock (all subprocesses for this example).
    total_ns: u64 = 0,
    /// The program's run phase: the `jit` stage for JIT examples, the exec
    /// subprocess wall for AOT. Null when there is no run phase (ir-only,
    /// compile-negative, apk) or the split was unavailable (crash before the
    /// timing table).
    run_ns: ?u64 = null,
};

/// `sx run` stderr split: everything before the `--time` stage table (the
/// program's real stderr, snapshot-compared) and the parsed `jit` stage
/// duration from the table itself. The table is a suffix — `printAll` runs
/// after the JIT'd main returns — so splitting at the LAST marker keeps any
/// program-printed lookalike in the body. No table (compile error, crash,
/// jit-fail fallback) → body = whole stderr, jit_ns = null.
const TimedStderr = struct { body: []const u8, jit_ns: ?u64 };

fn splitTimedStderr(raw: []const u8) TimedStderr {
    const marker = "\n--- timing ---\n";
    const idx = std.mem.lastIndexOf(u8, raw, marker) orelse
        return .{ .body = raw, .jit_ns = null };
    const table = raw[idx + marker.len ..];
    var jit_ns: ?u64 = null;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const stage = it.next() orelse continue;
        const val = it.next() orelse continue;
        const unit = it.next() orelse continue;
        if (!std.mem.eql(u8, unit, "ms")) continue;
        if (std.mem.eql(u8, stage, "jit")) {
            const ms = std.fmt.parseFloat(f64, val) catch continue;
            jit_ns = @intFromFloat(@max(ms, 0.0) * 1_000_000.0);
        }
    }
    return .{ .body = raw[0..idx], .jit_ns = jit_ns };
}

/// Collect every marker under `<source_dir>/expected` into `items`. Strings
/// are duped into `arena` (sweep lifetime). The `.build` sidecar is parsed
/// here — cheap, and it lets the sweep partition serial items before the pool
/// starts.
fn collectExpectedDir(
    arena: std.mem.Allocator,
    io: std.Io,
    source_dir: []const u8,
    rel_prefix: []const u8,
    items: *std.ArrayList(Item),
) !void {
    const exp_dir = try std.fs.path.join(arena, &.{ source_dir, "expected" });
    var dir = std.Io.Dir.openDirAbsolute(io, exp_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue; // accept .file and .unknown d_type
        if (!std.mem.endsWith(u8, entry.name, ".exit")) continue;
        const name = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".exit".len]);

        // `-Dname=<paths>` filter: when set, run ONLY the named example(s) (full
        // repo-relative `.sx` paths, comma-separated). A non-matching example is
        // dropped silently — not counted as ran or skipped.
        if (corpus_paths.name.len > 0) {
            const this_rel = try std.fmt.allocPrint(arena, "{s}/{s}.sx", .{ rel_prefix, name });
            if (!nameMatchesFilter(corpus_paths.name, this_rel)) continue;
        }

        var cfg: BuildConfig = .{};
        var cfg_error: ?[]const u8 = null;
        const build_path = try std.fmt.allocPrint(arena, "{s}/{s}.build", .{ exp_dir, name });
        if (readOptional(io, arena, build_path)) |raw| {
            cfg = parseBuildConfig(arena, raw) catch |err| blk: {
                cfg_error = @errorName(err);
                break :blk .{};
            };
        }

        try items.append(arena, .{
            .source_dir = source_dir,
            .rel_prefix = rel_prefix,
            .exp_dir = exp_dir,
            .name = name,
            .cfg = cfg,
            .cfg_error = cfg_error,
        });
    }
}

/// Discover every runnable item under a corpus root. Two layouts are supported
/// simultaneously:
///   * flat:     `<root>/expected/<name>.exit` with `<root>/<name>.sx`
///               (used by `issues/`)
///   * by-category: `<root>/<cat>/expected/<name>.exit` with
///                  `<root>/<cat>/<name>.sx` (used by `examples/`)
/// Category directories are visited in sorted order so item order (and
/// therefore all reporting) is stable across filesystems.
fn collectRoot(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    items: *std.ArrayList(Item),
) !void {
    const root_base = std.fs.path.basename(root_dir); // "examples" | "issues"

    // A direct `<root>/expected/` (flat layout, e.g. issues/).
    if (std.Io.Dir.access(.cwd(), io, try std.fs.path.join(arena, &.{ root_dir, "expected" }), .{})) |_| {
        try collectExpectedDir(arena, io, root_dir, root_base, items);
    } else |_| {}

    var root = std.Io.Dir.openDirAbsolute(io, root_dir, .{ .iterate = true }) catch return;
    defer root.close(io);
    var child_names: std.ArrayList([]const u8) = .empty;
    var rit = root.iterate();
    while (try rit.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "expected")) continue;
        try child_names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, child_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (child_names.items) |child| {
        const child_dir = try std.fs.path.join(arena, &.{ root_dir, child });
        const child_expected = try std.fs.path.join(arena, &.{ child_dir, "expected" });
        std.Io.Dir.access(.cwd(), io, child_expected, .{}) catch continue;
        const rel_prefix = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root_base, child });
        try collectExpectedDir(arena, io, child_dir, rel_prefix, items);
    }
}

/// Run one corpus item start-to-finish and fill its outcome slot. Never
/// touches shared mutable state: scratch comes from a local arena, and result
/// strings come from `results_gpa` (thread-safe DebugAllocator).
fn runOne(
    results_gpa: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    item: *const Item,
    out: *Outcome,
) !void {
    var work_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer work_state.deinit();
    const a = work_state.allocator();

    const name = item.name;
    const exp_dir = item.exp_dir;
    const started = nowNs(io);
    defer out.total_ns = elapsedNs(started, nowNs(io));

    const sx_abs = try std.fs.path.join(a, &.{ item.source_dir, try std.fmt.allocPrint(a, "{s}.sx", .{name}) });
    std.Io.Dir.access(.cwd(), io, sx_abs, .{}) catch { // marker without source
        out.skip_note = try std.fmt.allocPrint(results_gpa, "skip {s} (no {s}.sx)", .{ name, name });
        return;
    };
    out.ran = true;

    if (item.cfg_error) |err_name| {
        out.failure = try std.fmt.allocPrint(results_gpa, "{s}: invalid .build config ({s})", .{ name, err_name });
        return;
    }
    const cfg = item.cfg;

    const rel_path = try std.fmt.allocPrint(a, "{s}/{s}.sx", .{ item.rel_prefix, name });
    const exit_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.exit", .{ exp_dir, name })) orelse "";
    const out_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.stdout", .{ exp_dir, name })) orelse "";
    const err_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.stderr", .{ exp_dir, name })) orelse "";
    const ir_raw = readOptional(io, a, try std.fmt.allocPrint(a, "{s}/{s}.ir", .{ exp_dir, name }));

    // A bundle smoke test (`.app`/codesign) only makes sense on a macOS host —
    // skip it elsewhere (the bundler branches per-OS / codesign is Apple-only).
    if (cfg.bundle != null and builtin.target.os.tag != .macos) {
        out.ran = false;
        out.skip_note = try std.fmt.allocPrint(results_gpa, "skip {s} (bundle smoke test — macOS host only)", .{name});
        return;
    }
    // An Android `.apk` smoke test needs the Android SDK AND a real JDK.
    // Missing either → skip (so a bare-host `zig build test` stays green).
    if (cfg.apk != null and !(androidSdkAvailable(a, io) and jdkAvailable(a, io))) {
        out.ran = false;
        out.skip_note = try std.fmt.allocPrint(results_gpa, "skip {s} (no Android SDK/JDK)", .{name});
        return;
    }
    // Host-OS gate (C4): the per-example `host_os` directive, else the
    // example's category gate (`ffi-objc` → macOS). On a non-matching host
    // the example SKIPS cleanly so the corpus stays green off that host
    // (e.g. Objective-C examples on a Linux CI runner).
    if (cfg.host_os orelse categoryHostOs(item.rel_prefix)) |want_os| {
        if (!hostOsMatches(want_os)) {
            out.ran = false;
            out.skip_note = try std.fmt.allocPrint(results_gpa, "skip {s} ({s}-host only)", .{ name, want_os });
            return;
        }
    }
    const is_aot = cfg.aot;

    // An example pinned to a non-host target cannot execute here; it routes
    // to ir-only mode (verify via `sx ir` only — see the first arm below).
    const ir_only = if (cfg.target) |t| !hostMatchesTarget(t) else false;

    // Android `.apk` smoke test: self-contained build+inspect branch. We
    // cross-compile for aarch64-linux-android (can't run on the host), so
    // there is NO exit/stdout/stderr/ir snapshot — this branch asserts the
    // produced APK's zip entries and then returns, never falling through
    // to the stream snapshot comparison below.
    if (cfg.apk) |ac| {
        const out_abs = try std.fs.path.join(a, &.{ repo_root, ac.out });
        // Android requires the shared-lib basename to start with `lib`.
        const so_abs = try std.fmt.allocPrint(a, "{s}/.sx-tmp/libsxapk_{s}.so", .{ repo_root, name });
        const build_res = blk: {
            g_build_mutex.lockUncancelable(io);
            defer g_build_mutex.unlock(io);
            break :blk std.process.run(a, io, .{
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
            });
        } catch |err| {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `sx build --target android` {s}{s}", .{
                name, @errorName(err), if (err == error.Timeout) " (>10s)" else "",
            });
            return;
        };
        if (termCode(build_res.term) != 0) {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: apk build failed (exit {d})\n{s}", .{
                name, termCode(build_res.term), trimNl(build_res.stderr),
            });
            cleanupApk(a, io, out_abs, so_abs);
            return;
        }
        // Inspect the APK's zip entries via `unzip -l`; each `expect` entry
        // must appear as a substring of the listing.
        const list_res = std.process.run(a, io, .{
            .argv = &.{ "unzip", "-l", out_abs },
            .cwd = .{ .path = repo_root },
            .timeout = deadline(io),
        }) catch |err| {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `unzip -l` {s}", .{ name, @errorName(err) });
            cleanupApk(a, io, out_abs, so_abs);
            return;
        };
        if (termCode(list_res.term) != 0) {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `unzip -l` failed (exit {d}) — apk not produced?\n{s}", .{
                name, termCode(list_res.term), trimNl(list_res.stderr),
            });
            cleanupApk(a, io, out_abs, so_abs);
            return;
        }
        var missing: std.ArrayList(u8) = .empty;
        for (ac.expect) |entry| {
            if (std.mem.indexOf(u8, list_res.stdout, entry) == null) {
                try missing.appendSlice(a, try std.fmt.allocPrint(a, "{s}: apk missing entry '{s}' in {s}\n", .{ name, entry, ac.out }));
            }
        }
        if (missing.items.len > 0)
            out.failure = try results_gpa.dupe(u8, trimNl(missing.items));
        cleanupApk(a, io, out_abs, so_abs);
        return;
    }

    var act_exit: u32 = undefined;
    var act_out: []const u8 = undefined;
    var act_err: []const u8 = undefined;
    var act_ir: ?[]const u8 = null;

    if (ir_only) {
        // Cross-target: cannot run on this host. Verify via `sx ir` —
        // exit code and diagnostics (stderr), plus the IR snapshot
        // (stdout) UNLESS the example opted into `compile_only`, whose
        // whole assertion is "compiles/diagnoses for the target" with no
        // IR text pinned (IR snapshots test LLVM's printer, not sx). A
        // non-compile_only example still REQUIRES its .ir snapshot: its
        // absence is a loud failure, never a silent pass.
        if (ir_raw == null and !cfg.compile_only) {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: cross-target example (target={s}) needs an .ir snapshot for ir-only mode (or `compile_only`)", .{ name, cfg.target.? });
            return;
        }
        if (ir_raw != null and cfg.compile_only) {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `compile_only` example must not keep an .ir snapshot (delete expected/{s}.ir)", .{ name, name });
            return;
        }
        const ir_res = std.process.run(a, io, .{
            .argv = try withTarget(a, &.{ corpus_paths.sx_exe, "ir", rel_path, "--opt", "0" }, cfg.target),
            .cwd = .{ .path = repo_root },
            .timeout = deadline(io),
        }) catch |err| {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `sx ir` {s}{s}", .{ name, @errorName(err), if (err == error.Timeout) " (>10s)" else "" });
            return;
        };
        act_exit = termCode(ir_res.term);
        act_out = ""; // stdout carries IR (asserted via .ir when pinned), not a separate stream
        act_err = trimNl(try normalizeStd(a, ir_res.stderr));
        act_ir = if (cfg.compile_only) null else trimNl(try normalizeIr(a, ir_res.stdout));
    } else if (is_aot) {
        // Build a native executable, then run it. The build's own stderr
        // ("compiled: <path>") is intentionally discarded — only the built
        // program's streams are snapshotted. A build failure (e.g. an
        // unresolved exported symbol) surfaces as a non-zero exit with the
        // linker error on stderr.
        const bin_path = try std.fmt.allocPrint(a, "/tmp/sx_aot_{s}", .{name});
        const build_res = blk: {
            g_build_mutex.lockUncancelable(io);
            defer g_build_mutex.unlock(io);
            break :blk std.process.run(a, io, .{
                .argv = try withTarget(a, &.{ corpus_paths.sx_exe, "build", rel_path, "-o", bin_path }, cfg.target),
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            });
        } catch |err| {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `sx build` {s}{s}", .{
                name, @errorName(err), if (err == error.Timeout) " (>10s)" else "",
            });
            return;
        };
        if (termCode(build_res.term) != 0) {
            act_exit = termCode(build_res.term);
            act_out = "";
            act_err = trimNl(try normalizeStd(a, build_res.stderr));
        } else {
            const exec_started = nowNs(io);
            const exec_res = std.process.run(a, io, .{
                .argv = &.{bin_path},
                .cwd = .{ .path = repo_root },
                .timeout = deadline(io),
            }) catch |err| {
                out.failure = try std.fmt.allocPrint(results_gpa, "{s}: exec AOT binary {s}{s}", .{
                    name, @errorName(err), if (err == error.Timeout) " (>10s)" else "",
                });
                return;
            };
            out.run_ns = elapsedNs(exec_started, nowNs(io));
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
                        var present: std.ArrayList(u8) = .empty;
                        for (syms) |sym| {
                            if (nmHasSymbol(nr.stdout, sym)) {
                                try present.appendSlice(a, try std.fmt.allocPrint(a, "{s}: '{s}' is in the binary's symbols but should be compile-time only\n", .{ name, sym }));
                            }
                        }
                        if (present.items.len > 0) {
                            out.failure = try results_gpa.dupe(u8, trimNl(present.items));
                            return;
                        }
                    }
                }
            }

            // Bundle smoke test: the `sx build` above ran the sx bundler
            // (default_pipeline → bundle_main) and produced an `.app`. Assert
            // its structure, then `rm -rf` it so it doesn't linger.
            if (cfg.bundle) |bc| {
                const app_abs = try std.fs.path.join(a, &.{ repo_root, bc.app });
                var missing: std.ArrayList(u8) = .empty;
                for (bc.expect) |entry| {
                    const entry_abs = try std.fs.path.join(a, &.{ app_abs, entry });
                    std.Io.Dir.access(.cwd(), io, entry_abs, .{}) catch {
                        try missing.appendSlice(a, try std.fmt.allocPrint(a, "{s}: bundle missing '{s}' under {s}\n", .{ name, entry, bc.app }));
                    };
                }
                _ = std.process.run(a, io, .{
                    .argv = &.{ "/bin/rm", "-rf", app_abs },
                    .cwd = .{ .path = repo_root },
                    .timeout = deadline(io),
                }) catch {};
                if (missing.items.len > 0) {
                    out.failure = try results_gpa.dupe(u8, trimNl(missing.items));
                    return;
                }
            }
        }
    } else {
        // --- sx run --- (`--time` is stripped back out of stderr before the
        // snapshot comparison; it exists to source the compile-vs-run split.)
        const run_res = std.process.run(a, io, .{
            .argv = try withTarget(a, &.{ corpus_paths.sx_exe, "run", rel_path, "--time" }, cfg.target),
            .cwd = .{ .path = repo_root },
            .timeout = deadline(io),
        }) catch |err| {
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `sx run` {s}{s}", .{
                name,
                @errorName(err),
                if (err == error.Timeout) " (>10s)" else "",
            });
            return;
        };

        const timed = splitTimedStderr(run_res.stderr);
        out.run_ns = timed.jit_ns;
        act_exit = termCode(run_res.term);
        act_out = trimNl(try normalizeStd(a, run_res.stdout));
        act_err = trimNl(try normalizeStd(a, timed.body));
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
            out.failure = try std.fmt.allocPrint(results_gpa, "{s}: `sx ir` {s}", .{ name, @errorName(err) });
            return;
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
        out.updated = true;
        return;
    }

    // --- verify against stored snapshot ---
    const exp_exit = std.fmt.parseInt(u32, std.mem.trim(u8, exit_raw, " \t\r\n"), 10) catch {
        out.failure = try std.fmt.allocPrint(results_gpa, "{s}: unparseable expected exit '{s}'", .{ name, std.mem.trim(u8, exit_raw, " \t\r\n") });
        return;
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

    if (diag.items.len > 0)
        out.failure = try std.fmt.allocPrint(results_gpa, "{s}:\n{s}", .{ name, diag.items });
}

/// runOne with the error channel folded into the outcome slot, so a worker
/// thread never unwinds past an item.
fn runOneCaught(
    results_gpa: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    item: *const Item,
    out: *Outcome,
) void {
    runOne(results_gpa, io, repo_root, item, out) catch |err| {
        out.ran = true;
        out.failure = std.fmt.allocPrint(results_gpa, "{s}: internal runner error ({s})", .{ item.name, @errorName(err) }) catch
            "internal runner error (allocation failed formatting it)";
    };
}

/// Bounded pool size: `SX_CORPUS_JOBS=<n>` wins; else `min(8, cores - 2)`,
/// never below 1. The subtraction leaves room for the build runner and the
/// spawned `sx` processes' own threads.
fn workerCount() usize {
    if (std.c.getenv("SX_CORPUS_JOBS")) |raw| {
        const n = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 0;
        if (n > 0) return n;
    }
    const cores = std.Thread.getCpuCount() catch 4;
    return @max(1, @min(@as(usize, 8), cores -| 2));
}

const WorkerCtx = struct {
    results_gpa: std.mem.Allocator,
    repo_root: []const u8,
    items: []const Item,
    outcomes: []Outcome,
    queue: []const usize, // indices into items/outcomes
    next: *std.atomic.Value(usize),
};

/// Pool worker: claim queue slots until drained. Each worker owns a private
/// `std.Io.Threaded` so no `std.Io` state is shared across OS threads.
fn workerMain(ctx: *const WorkerCtx) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = currentEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    while (true) {
        const qi = ctx.next.fetchAdd(1, .monotonic);
        if (qi >= ctx.queue.len) return;
        const i = ctx.queue[qi];
        runOneCaught(ctx.results_gpa, io, ctx.repo_root, &ctx.items[i], &ctx.outcomes[i]);
    }
}

/// Write the sorted per-example timing report to
/// `<repo_root>/.sx-tmp/corpus-timing-<label>.txt`. Sorted by run phase
/// (descending, unknown last within their total order), with the 1s
/// run-budget offenders flagged. Best-effort — a write failure only prints a
/// note (the report is diagnostics, not a gate).
fn writeTimingReport(
    a: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    label: []const u8,
    items: []const Item,
    outcomes: []const Outcome,
) !void {
    var order: std.ArrayList(usize) = .empty;
    for (outcomes, 0..) |*o, i| {
        if (o.ran) try order.append(a, i);
    }
    const Sorter = struct {
        items: []const Item,
        outcomes: []const Outcome,
        fn key(self: @This(), i: usize) u64 {
            return self.outcomes[i].run_ns orelse 0;
        }
        fn lt(self: @This(), x: usize, y: usize) bool {
            const kx = self.key(x);
            const ky = self.key(y);
            if (kx != ky) return kx > ky;
            if (self.outcomes[x].total_ns != self.outcomes[y].total_ns)
                return self.outcomes[x].total_ns > self.outcomes[y].total_ns;
            return std.mem.order(u8, self.items[x].name, self.items[y].name) == .lt;
        }
    };
    std.mem.sort(usize, order.items, Sorter{ .items = items, .outcomes = outcomes }, Sorter.lt);

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# per-example corpus timing — sorted by run phase (desc)\n");
    try buf.appendSlice(a, "# run = jit stage (JIT) / exec wall (AOT); compile = total - run\n");
    try buf.appendSlice(a, "# budget: run <= 1000.0 ms (AGENTS.md); offenders flagged OVER\n");
    try buf.appendSlice(a, "# measured UNDER pool load — AOT exec walls especially inflate\n");
    try buf.appendSlice(a, "# with scheduler contention; re-measure a flagged example idle\n");
    try buf.appendSlice(a, "# (`sx run <ex> --time`, jit stage) before trimming it\n");
    try buf.appendSlice(a, "#   run_ms  compile_ms    total_ms  path\n");
    var over: usize = 0;
    for (order.items) |i| {
        const o = outcomes[i];
        const total_ms = @as(f64, @floatFromInt(o.total_ns)) / 1_000_000.0;
        const run_ms: ?f64 = if (o.run_ns) |r| @as(f64, @floatFromInt(r)) / 1_000_000.0 else null;
        const compile_ms: f64 = if (o.run_ns) |r| @as(f64, @floatFromInt(o.total_ns -| r)) / 1_000_000.0 else total_ms;
        const is_over = (o.run_ns orelse 0) > RUN_BUDGET_NS;
        if (is_over) over += 1;
        if (run_ms) |r| {
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "{d:>10.1}{d:>12.1}{d:>12.1}  {s}/{s}.sx{s}\n", .{
                r, compile_ms, total_ms, items[i].rel_prefix, items[i].name, if (is_over) "  OVER" else "",
            }));
        } else {
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "         -{d:>12.1}{d:>12.1}  {s}/{s}.sx\n", .{
                compile_ms, total_ms, items[i].rel_prefix, items[i].name,
            }));
        }
    }
    const dir_path = try std.fmt.allocPrint(a, "{s}/.sx-tmp", .{repo_root});
    std.Io.Dir.createDirPath(.cwd(), io, dir_path) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/corpus-timing-{s}.txt", .{ dir_path, label });
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = buf.items }) catch |err| {
        std.debug.print("[corpus-run] timing report write failed: {s} ({s})\n", .{ path, @errorName(err) });
        return;
    };
    // The budget note is diagnostics: only surface it when asked (any stderr
    // on a passing test makes the build runner print `failed command`).
    if (over > 0 and corpusVerbose())
        std.debug.print("[corpus-run] {s}: {d} example(s) OVER the 1s run budget — see {s}\n", .{ label, over, path });
}

/// Run every `<root>/expected/*.exit` test: collect, run on the pool (serial
/// items afterwards), then report in collection order. Appends a formatted
/// diagnostic to `failures` (owned by `fail_gpa`) for each failing example.
/// Returns the number of tests actually run (markers whose `.sx` is missing
/// are skipped).
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
    const root_base = std.fs.path.basename(root_dir);

    var arena_state = std.heap.ArenaAllocator.init(fail_gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var items: std.ArrayList(Item) = .empty;
    try collectRoot(a, io, root_dir, &items);
    if (items.items.len == 0) return 0;

    // Directory iteration order is filesystem-dependent; sort so slot order —
    // and with it failure reporting, skip notes, and the timing report — is
    // identical on every machine.
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            const p = std.mem.order(u8, x.rel_prefix, y.rel_prefix);
            if (p != .eq) return p == .lt;
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);

    const outcomes = try a.alloc(Outcome, items.items.len);
    for (outcomes) |*o| o.* = .{};

    var parallel_q: std.ArrayList(usize) = .empty;
    var serial_q: std.ArrayList(usize) = .empty;
    for (items.items, 0..) |*item, i| {
        if (item.cfg.serial) try serial_q.append(a, i) else try parallel_q.append(a, i);
    }

    var next = std.atomic.Value(usize).init(0);
    var ctx = WorkerCtx{
        .results_gpa = fail_gpa,
        .repo_root = repo_root,
        .items = items.items,
        .outcomes = outcomes,
        .queue = parallel_q.items,
        .next = &next,
    };
    const jobs = @min(workerCount(), @max(parallel_q.items.len, 1));
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..jobs) |_| {
        const t = std.Thread.spawn(.{}, workerMain, .{&ctx}) catch break;
        try threads.append(a, t);
    }
    if (threads.items.len == 0) {
        // Could not spawn any worker — degrade to inline execution.
        workerMain(&ctx);
    }
    for (threads.items) |t| t.join();

    // Wall-clock-sensitive examples run alone on the quiesced machine.
    for (serial_q.items) |i| {
        runOneCaught(fail_gpa, io, repo_root, &items.items[i], &outcomes[i]);
    }

    // Report strictly in collection order — deterministic regardless of the
    // pool's completion order.
    var ran: usize = 0;
    var skipped: usize = 0;
    var updated: usize = 0;
    for (outcomes) |*o| {
        if (o.ran) ran += 1;
        if (o.updated) updated += 1;
        if (o.skip_note) |note| {
            skipped += 1;
            std.debug.print("[corpus-run] {s}\n", .{note});
            fail_gpa.free(note);
            o.skip_note = null;
        }
        if (o.failure) |f| {
            try failures.append(fail_gpa, f);
            o.failure = null;
        }
    }

    writeTimingReport(a, io, repo_root, root_base, items.items, outcomes) catch |err| {
        std.debug.print("[corpus-run] timing report failed ({s})\n", .{@errorName(err)});
    };

    if (skipped > 0)
        std.debug.print("[corpus-run] {s}: {d} marker(s) skipped\n", .{ root_base, skipped });
    if (corpus_paths.update_goldens)
        std.debug.print("[corpus-run] {s}: {d} snapshot(s) regenerated\n", .{ root_base, updated });
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
    try std.testing.expect(!empty.serial);

    const aot = try parseBuildConfig(a, "{ \"aot\": true }");
    try std.testing.expect(aot.aot);
    try std.testing.expect(aot.target == null);

    const tgt = try parseBuildConfig(a, "{ \"target\": \"x86_64-linux\" }");
    try std.testing.expect(!tgt.aot);
    try std.testing.expectEqualStrings("x86_64-linux", tgt.target.?);

    const ser = try parseBuildConfig(a, "{ \"serial\": true }");
    try std.testing.expect(ser.serial);
    try std.testing.expect(!ser.aot);

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

test "splitTimedStderr: table stripped, jit stage parsed, body preserved" {
    // Program stderr + timing table suffix (the `sx run --time` shape).
    const with_table = "warning: something\n\n--- timing ---\n  read          0.2 ms\n  parse         1.0 ms\n  jit          42.5 ms\n  total        43.7 ms\n";
    const split = splitTimedStderr(with_table);
    try std.testing.expectEqualStrings("warning: something\n", split.body);
    try std.testing.expectEqual(@as(?u64, 42_500_000), split.jit_ns);

    // No table (compile error / crash): whole stderr is the body.
    const plain = "error: unknown type 'x'\n";
    const none = splitTimedStderr(plain);
    try std.testing.expectEqualStrings(plain, none.body);
    try std.testing.expect(none.jit_ns == null);

    // A program-printed lookalike earlier in the stream stays in the body —
    // only the LAST marker splits.
    const tricky = "fake\n--- timing ---\nnot really\n\n--- timing ---\n  jit           1.0 ms\n  total         1.5 ms\n";
    const t = splitTimedStderr(tricky);
    try std.testing.expectEqualStrings("fake\n--- timing ---\nnot really\n", t.body);
    try std.testing.expectEqual(@as(?u64, 1_000_000), t.jit_ns);

    // jit-fail fallback table has no `jit` stage — split still strips it.
    const jf = "\n--- timing ---\n  jit-fail      0.1 ms\n  total         9.9 ms\n";
    const j = splitTimedStderr(jf);
    try std.testing.expectEqualStrings("", j.body);
    try std.testing.expect(j.jit_ns == null);
}
