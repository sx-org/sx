#ifndef SX_CLANG_SHIM_H
#define SX_CLANG_SHIM_H

#include <llvm-c/Core.h>
#include <llvm-c/LLJIT.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Header parsing --- */

typedef struct {
    const char *name;
    const char *type_spelling;
    /* The parameter is written as the C `va_list` typedef. Canonicalization
       erases that identity into a target-specific pointer, array or record, so
       `type_spelling` cannot answer it. */
    int is_va_list;
} SxCParamInfo;

typedef struct {
    const char *name;
    const char *return_type;
    SxCParamInfo *params;
    int num_params;
    const char *source_file;
    unsigned source_line;
    /* The prototype ends in `...`; `num_params` is then the fixed count and may
       be zero (C23). */
    int is_variadic;
} SxCFunctionInfo;

typedef struct {
    SxCFunctionInfo *functions;
    int num_functions;
} SxCHeaderInfo;

SxCHeaderInfo *sx_clang_parse_header(
    const char *filename,
    const char **args, int num_args,
    char **out_error);

void sx_clang_free_header_info(SxCHeaderInfo *info);

/* --- C source compilation to LLVM module --- */

LLVMModuleRef sx_clang_compile_to_module(
    LLVMContextRef ctx,
    const char *filename,
    const char **args, int num_args,
    char **out_error);

/* --- C source compilation to native object code --- */

LLVMMemoryBufferRef sx_clang_compile_to_object(
    const char *filename,
    const char **args, int num_args,
    char **out_error);

/* --- Exported (defined, global) symbols of an object buffer --- */

typedef struct {
    const char **names;
    int num_names;
} SxCSymbolList;

SxCSymbolList *sx_clang_object_exported_symbols(
    LLVMMemoryBufferRef obj,
    char **out_error);

void sx_clang_free_symbol_list(SxCSymbolList *list);

/* --- Lifecycle of JIT-linked C objects --- */

typedef struct SxJitCLifecycle SxJitCLifecycle;

/* Adds the C objects, in link order, to the main JITDylib of `jit`, taking
   ownership of each buffer, and routes that JITDylib's `__cxa_atexit` to the
   JIT platform. Fails when the JIT's object linker is not JITLink. `*out`
   records the objects' init and fini arrays and lives as long as `jit`. */
LLVMErrorRef sx_jit_add_c_objects(
    LLVMOrcLLJITRef jit, const LLVMMemoryBufferRef *objects, size_t count,
    SxJitCLifecycle **out);

/* Links every added C object, runs the main JITDylib's platform
   initializers, then the recorded init arrays. */
LLVMErrorRef sx_jit_run_initializers(LLVMOrcLLJITRef jit, SxJitCLifecycle *c_lifecycle);

/* Runs the main JITDylib's atexit handlers, then the recorded fini arrays in
   reverse. */
LLVMErrorRef sx_jit_run_finalizers(LLVMOrcLLJITRef jit, SxJitCLifecycle *c_lifecycle);

#ifdef __cplusplus
}
#endif

#endif /* SX_CLANG_SHIM_H */
