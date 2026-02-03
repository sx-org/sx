#ifndef SX_CLANG_SHIM_H
#define SX_CLANG_SHIM_H

#include <llvm-c/Core.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Header parsing --- */

typedef struct {
    const char *name;
    const char *type_spelling;
} SxCParamInfo;

typedef struct {
    const char *name;
    const char *return_type;
    SxCParamInfo *params;
    int num_params;
    const char *source_file;
    unsigned source_line;
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

#ifdef __cplusplus
}
#endif

#endif /* SX_CLANG_SHIM_H */
