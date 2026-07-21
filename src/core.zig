const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const imports = @import("imports.zig");
const errors = @import("errors.zig");
const c_import = @import("c_import.zig");
const ir = @import("ir/ir.zig");
const target_mod = @import("target.zig");
const Node = ast.Node;

pub const TargetConfig = target_mod.TargetConfig;
pub const JniMainEmission = target_mod.JniMainEmission;

pub const Compilation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    source: [:0]const u8,
    diagnostics: errors.DiagnosticList,
    target_config: TargetConfig,
    stdlib_paths: []const []const u8 = &.{},

    // Pipeline results
    root: ?*Node = null,
    resolved_root: ?*Node = null,
    import_sources: std.StringHashMap([:0]const u8),
    module_scopes: std.StringHashMap(std.StringHashMap(ast.Visibility)),
    import_graph: std.StringHashMap(std.StringHashMap(void)),
    /// Flat-only subset of `import_graph` (bare `#import` edges, no namespaced
    /// `ns :: #import`). Borrowed by `ProgramIndex.flat_import_graph`.
    flat_import_graph: std.StringHashMap(std.StringHashMap(void)),
    /// Per-module scalar raw-decl index (`path → name → RawDeclRef`), built by
    /// `imports.buildImportFacts`. Borrowed by `ProgramIndex.module_decls`.
    module_decls: imports.ModuleDecls,
    /// Namespace import edges (`importer → alias → NamespaceTarget`), built by
    /// `imports.buildImportFacts`. Borrowed by `ProgramIndex.namespace_edges`.
    namespace_edges: imports.NamespaceEdges,
    /// Stable `DeclId` for every declaration (Fork C S1), built by
    /// `imports.buildDeclTable` in parallel with the import facts. Borrowed by
    /// `ProgramIndex.decl_table`.
    decl_table: imports.DeclTable,
    ir_emitter: ?ir.LLVMEmitter = null,
    /// Lowered IR module, kept alive past `generateCode` so post-link
    /// callbacks can re-enter the interpreter to invoke sx functions
    /// (e.g. `platform.bundle.bundle_main` after `target.link`).
    ir_module: ?*ir.Module = null,
    /// C sources requested by the lowering pass (not in the user's AST).
    /// E.g. the JNI env TL runtime when `#jni_env` is used. Merged with
    /// AST sources in `collectCImportSources`.
    lowering_extra_c_sources: std.ArrayList(c_import.CImportInfo) = .empty,
    /// `#jni_main #jni_class("...")` declarations whose Java sources were
    /// rendered during lowering. Surfaced to the sx Android bundler
    /// (`library/modules/platform/bundle.sx`) via `BuildConfig.jni_main_*`
    /// in `compiler_hooks.zig`; the bundler writes `.java` files + runs
    /// `javac` + `d8` + bundles `classes.dex` into the APK.
    lowering_jni_main_decls: std.ArrayList(JniMainEmission) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, source: [:0]const u8, target_config: TargetConfig, stdlib_paths: []const []const u8) Compilation {
        return .{
            .allocator = allocator,
            .io = io,
            .file_path = file_path,
            .source = source,
            .diagnostics = errors.DiagnosticList.init(allocator, source, file_path),
            .import_sources = std.StringHashMap([:0]const u8).init(allocator),
            .module_scopes = std.StringHashMap(std.StringHashMap(ast.Visibility)).init(allocator),
            .import_graph = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .flat_import_graph = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .module_decls = imports.ModuleDecls.init(allocator),
            .namespace_edges = imports.NamespaceEdges.init(allocator),
            .decl_table = imports.DeclTable.init(allocator),
            .target_config = target_config,
            .stdlib_paths = stdlib_paths,
        };
    }

    pub fn deinit(self: *Compilation) void {
        if (self.ir_emitter) |*e| e.deinit();
        if (self.ir_module) |m| {
            m.deinit();
            self.allocator.destroy(m);
        }
        self.diagnostics.deinit();
    }

    pub fn parse(self: *Compilation) !void {
        var p = parser.Parser.init(self.allocator, self.source);
        p.diagnostics = &self.diagnostics;
        self.root = p.parse() catch return error.CompileError;
    }

    /// Derive the comptime evaluation context (OS / ARCH / POINTER_SIZE
    /// values) from the build target. Used by `imports.resolveImports`
    /// to hoist top-level `inline if OS == .X { ... }` body decls
    /// before resolution; mirrors `injectComptimeConstants` in lowering.
    fn comptimeContext(self: *const Compilation) imports.ComptimeContext {
        const tc = self.target_config;
        const os: []const u8 = if (tc.isWasm()) "wasm" else if (tc.isWindows()) "windows" else if (tc.isAndroid()) "android" else if (tc.isLinux()) "linux" else if (tc.isIOS()) "ios" else if (tc.isMacOS()) "macos" else "unknown";
        const arch: []const u8 = if (tc.isWasm32()) "wasm32" else if (tc.isWasm64()) "wasm64" else if (tc.isAarch64()) "aarch64" else if (tc.isX86_64()) "x86_64" else "unknown";
        const ptr_size: i64 = if (tc.isWasm32()) 4 else 8;
        return .{ .os = os, .arch = arch, .pointer_size = ptr_size };
    }

    pub fn resolveImports(self: *Compilation) !void {
        const root = self.root orelse return error.CompileError;
        var chain = std.StringHashMap(void).init(self.allocator);
        var cache = imports.ModuleCache.init(self.allocator);
        const base_dir = imports.dirName(self.file_path);

        // Wire import_sources to diagnostics BEFORE resolving imports, so a parse
        // error in an imported file (reported mid-resolution, which then aborts
        // before the post-resolution wiring below) can resolve its caret against
        // the imported file's OWN source. The map pointer is stable; per-file
        // entries fill in as imports load. The main-file source is seeded here
        // too so a root-file diagnostic resolves identically.
        self.import_sources.put(self.file_path, self.source) catch {};
        self.diagnostics.import_sources = &self.import_sources;

        const mod = imports.resolveImports(
            self.allocator,
            self.io,
            root,
            base_dir,
            self.file_path,
            &chain,
            &cache,
            &self.import_sources,
            &self.diagnostics,
            self.stdlib_paths,
            &self.import_graph,
            &self.flat_import_graph,
            self.comptimeContext(),
        ) catch return error.CompileError;

        // Preserve per-module visibility scopes for C import access checking
        self.module_scopes.put(self.file_path, mod.scope) catch {};
        var cache_it = cache.iterator();
        while (cache_it.next()) |entry| {
            self.module_scopes.put(entry.key_ptr.*, entry.value_ptr.scope) catch {};
        }

        // Raw import facts (the unified-resolver store): scalar per-module
        // raw-decl index + namespace edges, built from the SAME modules. Nothing
        // consumes these yet — they are borrowed by `ProgramIndex` for later
        // phases (and the LSP). Built without IR lowering. A build failure here
        // (allocation) is the Phase A deliverable failing — propagate it rather
        // than leaving the borrowed views silently empty/stale.
        const facts = try imports.buildImportFacts(self.allocator, self.file_path, mod, &cache);
        self.module_decls = facts.decls;
        self.namespace_edges = facts.ns_edges;

        // DeclTable (Fork C S1): a stable DeclId for every declaration, built in
        // parallel from the SAME modules. Additive — nothing consumes it for
        // selection yet, so generated IR + bytes are unchanged. Updates
        // `namespace_edges` in place to record each target's member ids.
        self.decl_table = try imports.buildDeclTable(self.allocator, self.file_path, mod, &cache, &self.module_decls, &self.namespace_edges);

        // (import_sources ↔ diagnostics wiring + main-file seed now done before
        // resolution, above, so mid-resolution parse errors render correctly.)

        // Build a root node from the resolved module's decls
        const new_root = try self.allocator.create(Node);
        new_root.* = .{
            .span = root.span,
            .data = .{ .root = .{ .decls = mod.decls } },
        };
        self.resolved_root = new_root;
    }

    /// Generate code via the IR pipeline: lower AST → IR → LLVM.
    pub fn generateCode(self: *Compilation) !void {
        // Heap-allocate the IR module so its address is stable during emit
        const ir_mod_ptr = try self.allocator.create(ir.Module);
        ir_mod_ptr.* = try self.lowerToIR();
        var emitter = ir.LLVMEmitter.init(self.allocator, ir_mod_ptr, "sx_module", self.target_config);
        emitter.setDebugContext(&self.import_sources, self.file_path);
        emitter.emit();
        // Keep the IR module alive past LLVM emission so post-link
        // callbacks can re-enter the interpreter via `invokeByName`.
        self.ir_module = ir_mod_ptr;
        self.ir_emitter = emitter;
        // A comptime `#run` raised an unhandled error — the diagnostic + trace
        // were already printed to stderr; abort before JIT/link (E5.2).
        if (emitter.comptime_failed) return error.ComptimeError;
        if (emitter.emission_failed) return error.CodegenError;

        // Never feed malformed IR to LLVM's optimizer. Then run the selected
        // middle-end pipeline once, before any caller can print or emit the
        // module, and verify the transformed module as a second invariant gate.
        try self.ir_emitter.?.verifyWithMessage();
        if (self.target_config.opt_level.toLLVMPassPipeline() != null) {
            try self.ir_emitter.?.optimize();
            try self.ir_emitter.?.verifyWithMessage();
        }
    }

    /// Re-enter the IR interpreter after `generateCode` (and after linking,
    /// if applicable) to invoke a named sx function. Used for the post-link
    /// bundling callback. Returns the function's return value, or null if the
    /// name doesn't resolve to a function in the lowered module.
    pub fn invokeByName(self: *Compilation, name: []const u8, pass_options: bool) !?ir.Value {
        const mod = self.ir_module orelse return null;
        var found_id: ?ir.FuncId = null;
        for (mod.functions.items, 0..) |func, i| {
            const fname = mod.types.getString(func.name);
            if (std.mem.eql(u8, fname, name)) {
                found_id = ir.FuncId.fromIndex(@intCast(i));
                break;
            }
        }
        const fid = found_id orelse return null;
        return try self.invokeByFuncId(fid, pass_options);
    }

    /// Re-enter the evaluator and call a previously-resolved function id. The
    /// post-link build callback, captured at `#run` time (by `on_build` /
    /// `set_post_link_callback`). `pass_options` passes the opaque `BuildOptions`
    /// handle as the callback's arg (the `on_build(cb)` form, `cb: (opt:
    /// BuildOptions) -> bool`); false for the legacy no-arg form.
    pub fn invokeByFuncId(self: *Compilation, id: ir.FuncId, pass_options: bool) !ir.Value {
        const mod = self.ir_module orelse return error.NoIRModule;
        // The build driver (post-link callback) runs on the comptime VM — NOT
        // the legacy interp. The driver allocates Lists, which the legacy interp
        // cannot grow at comptime (issue 0141: `struct_get: base has no fields`);
        // the VM can. There is **no fallback**: a side-effecting post-link
        // callback can't safely re-run on a second evaluator (double execution),
        // so a VM bail is a hard build error. The bail reason is in
        // `comptime_vm.last_bail_reason` (surfaced by `main.printInterpBailDiag`).
        const build_config = if (self.ir_emitter) |*e| &e.build_config else null;
        return ir.comptime_vm.runBuildCallback(self.allocator, mod, id, build_config, &self.import_sources, pass_options) orelse
            error.ComptimeVmBail;
    }

    /// Get link flags accumulated from #run build blocks.
    pub fn getBuildLinkFlags(self: *Compilation) []const []const u8 {
        if (self.ir_emitter) |*e| return e.build_config.link_flags.items;
        return &.{};
    }

    /// Get frameworks accumulated from #run build blocks (BuildOptions.add_framework).
    pub fn getBuildFrameworks(self: *Compilation) []const []const u8 {
        if (self.ir_emitter) |*e| return e.build_config.frameworks.items;
        return &.{};
    }

    /// Get output path set from #run build blocks, if any.
    pub fn getBuildOutputPath(self: *Compilation) ?[]const u8 {
        if (self.ir_emitter) |*e| return e.build_config.output_path;
        return null;
    }

    /// Get custom WASM shell template path set from #run build blocks, if any.
    pub fn getBuildWasmShell(self: *Compilation) ?[]const u8 {
        if (self.ir_emitter) |*e| return e.build_config.wasm_shell_path;
        return null;
    }

    /// Get the post-link callback function id (set via `on_build(fn)` or the
    /// legacy `set_post_link_callback(fn)`), if any.
    pub fn getPostLinkCallback(self: *Compilation) ?ir.FuncId {
        if (self.ir_emitter) |*e| return e.build_config.post_link_callback_fn;
        return null;
    }

    /// Whether the post-link callback takes the `BuildOptions` handle arg (the
    /// `on_build(cb)` form). Drives the `pass_options` flag at invocation.
    pub fn getPostLinkTakesOptions(self: *Compilation) bool {
        if (self.ir_emitter) |*e| return e.build_config.post_link_takes_options;
        return false;
    }

    /// Get the post-link module name (set via
    /// `BuildOptions.set_post_link_module("name")`), if any.
    pub fn getPostLinkModule(self: *Compilation) ?[]const u8 {
        if (self.ir_emitter) |*e| return e.build_config.post_link_module;
        return null;
    }

    /// Collect C import source info — both from user-written `#import c { ... }`
    /// blocks in the AST AND from lowering-time auto-injections (currently:
    /// the JNI env TL runtime when `#jni_env` / `#jni_call`-with-omitted-env
    /// is used). The lower-side auto-injections live in
    /// `lowering_extra_c_sources` and are populated by `lowerToIR` based on
    /// `Lowering.needs_jni_env_tl_runtime` etc.
    pub fn collectCImportSources(self: *Compilation) ![]c_import.CImportInfo {
        const root = self.resolved_root orelse self.root orelse return &.{};
        const ast_sources = try c_import.collectCImportSources(self.allocator, root);
        if (self.lowering_extra_c_sources.items.len == 0) return ast_sources;
        var merged = std.ArrayList(c_import.CImportInfo).empty;
        try merged.appendSlice(self.allocator, ast_sources);
        try merged.appendSlice(self.allocator, self.lowering_extra_c_sources.items);
        return merged.toOwnedSlice(self.allocator);
    }

    /// Resolve a stdlib-relative path through the configured `stdlib_paths`.
    /// Returns the first candidate whose absolute path resolves to an
    /// existing file. Used by lower-side auto-injected C sources.
    fn resolveStdlibPath(self: *Compilation, rel: []const u8) !?[]const u8 {
        for (self.stdlib_paths) |root_path| {
            const candidate = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root_path, rel });
            if (std.Io.Dir.readFileAlloc(.cwd(), self.io, candidate, self.allocator, .limited(1024 * 1024))) |buf| {
                self.allocator.free(buf);
                return candidate;
            } else |_| {
                self.allocator.free(candidate);
            }
        }
        return null;
    }

    /// Lower the parsed AST to the sx IR module (shadow pipeline).
    pub fn lowerToIR(self: *Compilation) !ir.Module {
        const root = self.resolved_root orelse self.root orelse return ir.Module.init(self.allocator);

        // Every `extern <ref>` must name a #library constant or a named
        // `#import c` unit — a typo'd ref otherwise resolves silently
        // through whatever image happens to carry the symbol.
        try c_import.validateExternRefs(self.allocator, root, &self.diagnostics);
        if (self.diagnostics.hasErrors()) return error.CompileError;

        var module = ir.Module.init(self.allocator);
        //TODO: find a better place for this
        if (self.target_config.isWasm32()) {
            module.types.pointer_size = 4;
        }
        var lowering = ir.Lowering.init(&module);
        lowering.main_file = self.file_path;
        lowering.resolved_root = root;
        lowering.target_config = self.target_config;
        lowering.diagnostics = &self.diagnostics;
        lowering.program_index.module_scopes = &self.module_scopes;
        lowering.program_index.import_graph = &self.import_graph;
        lowering.program_index.flat_import_graph = &self.flat_import_graph;
        lowering.program_index.module_decls = &self.module_decls;
        lowering.program_index.namespace_edges = &self.namespace_edges;
        lowering.program_index.decl_table = &self.decl_table;
        lowering.lowerRoot(root);
        if (self.diagnostics.hasErrors()) return error.CompileError;

        // Auto-link the JNI env TL runtime when lowering used it. The .c file
        // ships with the sx library; we resolve it through stdlib_paths so
        // consumers don't need to vendor a copy.
        if (lowering.needs_jni_env_tl_runtime) {
            if (try self.resolveStdlibPath("vendors/sx_jni_runtime/sx_jni_env_tl.c")) |abs_path| {
                var sources = std.ArrayList([]const u8).empty;
                try sources.append(self.allocator, abs_path);
                try self.lowering_extra_c_sources.append(self.allocator, .{
                    .sources = try sources.toOwnedSlice(self.allocator),
                    .includes = &.{},
                    .defines = &.{},
                    .flags = &.{},
                });
            }
        }

        // Same pattern for the ERR E3.1 error return-trace runtime.
        if (lowering.needs_trace_runtime) {
            if (try self.resolveStdlibPath("vendors/sx_trace_runtime/sx_trace.c")) |abs_path| {
                var sources = std.ArrayList([]const u8).empty;
                try sources.append(self.allocator, abs_path);
                try self.lowering_extra_c_sources.append(self.allocator, .{
                    .sources = try sources.toOwnedSlice(self.allocator),
                    .includes = &.{},
                    .defines = &.{},
                    .flags = &.{},
                });
            }
        }

        try self.collectJniMainEmissions(&lowering);

        return module;
    }

    /// Walk `lowering.program_index.runtime_class_map` and render Java sources for every
    /// `#jni_main #jni_class("...")` declaration. Renders happen here so the
    /// AST + class-registry snapshot stay confined to the lowering pass; the
    /// downstream APK pipeline only needs `{runtime_path, java_source}` pairs.
    fn collectJniMainEmissions(self: *Compilation, lowering: *ir.Lowering) !void {
        // `runtime_class_map` registers each decl under bare + qualified names —
        // dedupe by runtime_path so a single decl emits one .java.
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        // Class registry passed to jni_java_emit for `*Foo` cross-class refs
        // and `#extends Alias` resolution.
        var registry = std.StringHashMap([]const u8).init(self.allocator);
        defer registry.deinit();
        var it_reg = lowering.program_index.runtime_class_map.iterator();
        while (it_reg.next()) |entry| {
            try registry.put(entry.key_ptr.*, entry.value_ptr.*.runtime_path);
        }

        // Derive the `System.loadLibrary` argument from the `-o` basename
        // (e.g. `/tmp/libsxchess.so` → `sxchess`). When `-o` is unset the
        // emitter omits the static init block; the user must then arrange
        // .so loading via another class.
        const lib_name = libNameFromOutputPath(self.target_config.output_path);

        var it = lowering.program_index.runtime_class_map.iterator();
        while (it.next()) |entry| {
            const fcd = entry.value_ptr.*;
            if (!fcd.is_main) continue;
            if (fcd.is_extern) continue;
            if (fcd.runtime != .jni_class) continue;
            if (seen.contains(fcd.runtime_path)) continue;
            try seen.put(fcd.runtime_path, {});

            const java_source = try ir.jni_java_emit.emitJavaSource(self.allocator, fcd, .{
                .classes = &registry,
                .lib_name = lib_name,
            });
            try self.lowering_jni_main_decls.append(self.allocator, .{
                .runtime_path = try self.allocator.dupe(u8, fcd.runtime_path),
                .java_source = java_source,
            });
        }
    }

    /// `/path/to/libfoo.so` → `foo`. Anything else → null (caller skips
    /// emitting the `System.loadLibrary` init block).
    fn libNameFromOutputPath(output_path: ?[]const u8) ?[]const u8 {
        const path = output_path orelse return null;
        const basename = std.fs.path.basename(path);
        if (!std.mem.startsWith(u8, basename, "lib")) return null;
        if (!std.mem.endsWith(u8, basename, ".so")) return null;
        return basename[3 .. basename.len - 3];
    }

    /// Java sources rendered from `#jni_main #jni_class("...")` decls during
    /// lowering. Empty unless `lowerToIR` has run.
    pub fn getJniMainEmissions(self: *const Compilation) []const JniMainEmission {
        return self.lowering_jni_main_decls.items;
    }

    pub fn renderErrors(self: *const Compilation) void {
        self.diagnostics.renderStderr();
    }
};
