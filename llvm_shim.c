#include <llvm-c/Core.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/Analysis.h>

void sx_llvm_init_all_targets(void) {
    LLVMInitializeAllTargetInfos();
    LLVMInitializeAllTargets();
    LLVMInitializeAllTargetMCs();
    LLVMInitializeAllAsmPrinters();
    LLVMInitializeAllAsmParsers();
}

void sx_llvm_init_native_target(void) {
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
    // Required for inline assembly: the JIT must assemble the asm template at
    // run time, which needs the target's asm parser (ASM stream Phase D).
    LLVMInitializeNativeAsmParser();
}
