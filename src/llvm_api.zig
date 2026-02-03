pub const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/DebugInfo.h");

    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/Transforms/PassBuilder.h");
    @cInclude("llvm-c/LLJIT.h");
    @cInclude("llvm-c/Orc.h");
    @cInclude("llvm-c/Error.h");
    @cInclude("llvm-c/BitReader.h");
    @cInclude("llvm-c/BitWriter.h");
    @cInclude("llvm-c/Linker.h");

    // Clang shim for C header parsing + source compilation
    @cInclude("clang_shim.h");
});

extern fn sx_llvm_init_all_targets() void;
extern fn sx_llvm_init_native_target() void;

pub fn initAllTargets() void {
    sx_llvm_init_all_targets();
}

pub fn initNativeTarget() void {
    sx_llvm_init_native_target();
}

// Type aliases for ergonomics
pub const Context = c.LLVMContextRef;
pub const Module = c.LLVMModuleRef;
pub const Builder = c.LLVMBuilderRef;
pub const Value = c.LLVMValueRef;
pub const Type = c.LLVMTypeRef;
pub const BasicBlock = c.LLVMBasicBlockRef;
pub const TargetMachine = c.LLVMTargetMachineRef;

pub fn createContext() Context {
    return c.LLVMContextCreate();
}

pub fn disposeContext(ctx: Context) void {
    c.LLVMContextDispose(ctx);
}

pub fn moduleCreateWithName(name: [*:0]const u8) Module {
    return c.LLVMModuleCreateWithNameInContext(name, c.LLVMGetGlobalContext());
}

pub fn disposeModule(module: Module) void {
    c.LLVMDisposeModule(module);
}

pub fn createBuilderInContext(ctx: Context) Builder {
    return c.LLVMCreateBuilderInContext(ctx);
}

pub fn disposeBuilder(builder: Builder) void {
    c.LLVMDisposeBuilder(builder);
}
