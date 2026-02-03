const llvm = @import("llvm_api.zig");
const c = llvm.c;

pub const Builtins = struct {
    printf_fn: c.LLVMValueRef,
    malloc_fn: c.LLVMValueRef,
    free_fn: c.LLVMValueRef,
    memcpy_fn: c.LLVMValueRef,
    memset_fn: c.LLVMValueRef,

    pub fn init(module: c.LLVMModuleRef, ctx: c.LLVMContextRef) Builtins {
        const ptr_type = c.LLVMPointerTypeInContext(ctx, 0);
        const i64_type = c.LLVMInt64TypeInContext(ctx);
        const i32_type = c.LLVMInt32TypeInContext(ctx);
        const void_type = c.LLVMVoidTypeInContext(ctx);

        // Declare: int printf(const char*, ...)
        var printf_params = [_]c.LLVMTypeRef{ptr_type};
        const printf_type = c.LLVMFunctionType(i32_type, &printf_params, 1, 1);
        const printf_fn = c.LLVMAddFunction(module, "printf", printf_type);

        // Declare: void* malloc(size_t size)
        var malloc_params = [_]c.LLVMTypeRef{i64_type};
        const malloc_type = c.LLVMFunctionType(ptr_type, &malloc_params, 1, 0);
        const malloc_fn = c.LLVMAddFunction(module, "malloc", malloc_type);

        // Declare: void free(void* ptr)
        var free_params = [_]c.LLVMTypeRef{ptr_type};
        const free_type = c.LLVMFunctionType(void_type, &free_params, 1, 0);
        const free_fn = c.LLVMAddFunction(module, "free", free_type);

        // Declare: void* memcpy(void* dst, const void* src, size_t n)
        var memcpy_params = [_]c.LLVMTypeRef{ ptr_type, ptr_type, i64_type };
        const memcpy_type = c.LLVMFunctionType(ptr_type, &memcpy_params, 3, 0);
        const memcpy_fn = c.LLVMAddFunction(module, "memcpy", memcpy_type);

        // Declare: void* memset(void* s, int c, size_t n)
        var memset_params = [_]c.LLVMTypeRef{ ptr_type, i32_type, i64_type };
        const memset_type = c.LLVMFunctionType(ptr_type, &memset_params, 3, 0);
        const memset_fn = c.LLVMAddFunction(module, "memset", memset_type);

        return .{
            .printf_fn = printf_fn,
            .malloc_fn = malloc_fn,
            .free_fn = free_fn,
            .memcpy_fn = memcpy_fn,
            .memset_fn = memset_fn,
        };
    }
};
