const std = @import("std");
const llvm = @import("../../llvm_api.zig");
const c = llvm.c;
const errors = @import("../../errors.zig");
const emit = @import("../../ir/emit_llvm.zig");
const ir_inst = @import("../../ir/inst.zig");

const LLVMEmitter = emit.LLVMEmitter;
const Function = ir_inst.Function;
const Span = ir_inst.Span;

/// DWARF debug-info emission (architecture phase A7.2), extracted from
/// `LLVMEmitter`. A backend `*LLVMEmitter` facade (field `e`): it owns the
/// `DIBuilder` lifecycle, the compile unit, per-function `DISubprogram` scopes,
/// and per-instruction `DILocation`s. The mutable DI state (`di_builder`/
/// `di_cu`/`di_files`/`di_scope`/`current_func_file`) + the shared source map
/// (`import_sources`/`main_file`, also read by `#caller_location`) stay on
/// `LLVMEmitter`; this reads/writes them via `self.e.*`. `LLVMEmitter.emit`
/// drives the pass order and calls in via `self.debugInfo()`.
pub const DebugInfo = struct {
    e: *LLVMEmitter,

    /// Debug info is emitted only when error traces are kept (opt_level
    /// none/less, matching `tracesEnabled` in lower.zig) and a source
    /// map is available. Release builds (default/aggressive) skip it, so
    /// the DWARF is strippable cost-free.
    fn debugEnabled(self: DebugInfo) bool {
        if (self.e.import_sources == null) return false;
        return self.e.target_config.opt_level == .none or self.e.target_config.opt_level == .less;
    }

    /// The `DIFile` for `path`, created once and cached. Splits the path
    /// into basename + directory as DWARF expects. The directory MUST be
    /// non-empty: an empty `DW_AT_comp_dir` makes Apple's `ld` silently drop
    /// the whole object's debug map (no `N_OSO`), so a binary built from a
    /// bare filename (e.g. `sx build main.sx`) becomes undebuggable. Fall back
    /// to "." when the path has no directory component.
    fn diFileFor(self: DebugInfo, path: []const u8) c.LLVMMetadataRef {
        if (self.e.di_files.get(path)) |f| return f;
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const dir = if (slash) |s| (if (s == 0) "/" else path[0..s]) else ".";
        const base = if (slash) |s| path[s + 1 ..] else path;
        const f = c.LLVMDIBuilderCreateFile(self.e.di_builder, base.ptr, base.len, dir.ptr, dir.len);
        self.e.di_files.put(path, f) catch {};
        return f;
    }

    /// Create the DIBuilder, the module flags ("Debug Info Version" /
    /// "Dwarf Version"), and the single compile unit on the main file.
    pub fn initDebugInfo(self: DebugInfo) void {
        if (!self.debugEnabled()) return;
        self.e.di_builder = c.LLVMCreateDIBuilder(self.e.llvm_module);

        c.LLVMAddModuleFlag(
            self.e.llvm_module,
            c.LLVMModuleFlagBehaviorWarning,
            "Debug Info Version",
            "Debug Info Version".len,
            c.LLVMValueAsMetadata(c.LLVMConstInt(self.e.cached_i32, c.LLVMDebugMetadataVersion(), 0)),
        );
        c.LLVMAddModuleFlag(
            self.e.llvm_module,
            c.LLVMModuleFlagBehaviorWarning,
            "Dwarf Version",
            "Dwarf Version".len,
            c.LLVMValueAsMetadata(c.LLVMConstInt(self.e.cached_i32, 4, 0)),
        );

        const cu_file = self.diFileFor(if (self.e.main_file.len > 0) self.e.main_file else "sx");
        self.e.di_cu = c.LLVMDIBuilderCreateCompileUnit(
            self.e.di_builder,
            c.LLVMDWARFSourceLanguageC,
            cu_file,
            "sx",
            "sx".len,
            0, // isOptimized
            "",
            0, // flags
            0, // runtime version
            "",
            0, // split name
            c.LLVMDWARFEmissionFull,
            0, // DWOId
            0, // split debug inlining
            0, // debug info for profiling
            "",
            0, // sysroot
            "",
            0, // sdk
        );
    }

    /// Create a `DISubprogram` for `func` and attach it to `llvm_func`,
    /// making it the scope (`di_scope`) for the function's instruction
    /// locations. Clears any stale builder location first so synthetic
    /// functions emitted between sx functions carry none.
    pub fn beginFunctionDebug(self: DebugInfo, func: *const Function, llvm_func: c.LLVMValueRef, name: []const u8) void {
        self.e.di_scope = null;
        c.LLVMSetCurrentDebugLocation2(self.e.builder, null);
        if (self.e.di_builder == null) return;

        const file = func.source_file orelse self.e.main_file;
        self.e.current_func_file = file;
        const di_file = self.diFileFor(file);
        const subroutine_ty = c.LLVMDIBuilderCreateSubroutineType(self.e.di_builder, di_file, null, 0, c.LLVMDIFlagZero);

        // Line = the first instruction's line (the function body's start),
        // else 1 when the body is empty / span-less.
        var line: c_uint = 1;
        if (func.blocks.items.len > 0 and func.blocks.items[0].insts.items.len > 0) {
            const sp = func.blocks.items[0].insts.items[0].span;
            const src = self.e.sourceForFile(file);
            line = errors.SourceLoc.compute(src, sp.start).line;
        }

        const is_local: c.LLVMBool = if (func.linkage == .external) 0 else 1;
        const subprogram = c.LLVMDIBuilderCreateFunction(
            self.e.di_builder,
            di_file, // scope
            name.ptr,
            name.len,
            name.ptr,
            name.len, // linkage name
            di_file,
            line,
            subroutine_ty,
            is_local,
            1, // is definition
            line, // scope line
            c.LLVMDIFlagZero,
            0, // isOptimized
        );
        c.LLVMSetSubprogram(llvm_func, subprogram);
        self.e.di_scope = subprogram;
    }

    /// End the current function's debug scope and clear the builder's
    /// location, so the next (possibly synthetic) function doesn't
    /// inherit a DILocation pointing into this function's subprogram.
    pub fn endFunctionDebug(self: DebugInfo) void {
        self.e.di_scope = null;
        c.LLVMSetCurrentDebugLocation2(self.e.builder, null);
    }

    /// Set the builder's current debug location from an instruction span,
    /// scoped to the current function's subprogram. No-op when debug info
    /// is off (`di_scope == null`).
    pub fn setInstDebugLocation(self: DebugInfo, span: Span) void {
        const scope = self.e.di_scope orelse return;
        const src = self.e.sourceForFile(self.e.current_func_file);
        const loc = errors.SourceLoc.compute(src, span.start);
        const di_loc = c.LLVMDIBuilderCreateDebugLocation(self.e.context, loc.line, loc.col, scope, null);
        c.LLVMSetCurrentDebugLocation2(self.e.builder, di_loc);
    }

    pub fn finalizeDebugInfo(self: DebugInfo) void {
        if (self.e.di_builder == null) return;
        c.LLVMDIBuilderFinalize(self.e.di_builder);
    }
};
