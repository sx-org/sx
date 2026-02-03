// Thread-local JNIEnv* slot for the `#jni_env(env) { body }` block and
// the `#jni_call` cross-function fallback (FFI plan step 2.16c).
//
// Lives outside the user's IR module on purpose. The natural place
// would be `@sx_jni_env_tl = internal thread_local global ptr null`
// inside the lowered IR, but LLVM ORC JIT's default platform support
// doesn't initialise TLS slots for objects added via
// `LLVMOrcLLJITAddObjectFile`. Wrapping the storage in an externally-
// linked C helper sidesteps that — JIT process-symbol resolution finds
// these `_Thread_local`-backed functions via the host's dlsym (sx
// itself is built with this .c linked in via build.zig); AOT targets
// (Android, etc.) pick it up as a regular `#import c { #source ...; }`
// auto-injected by the lowering pass.
//
// The slot is per-thread; nesting is handled at the call site via
// save → set(new) → body → set(saved) (see lower.zig). Multi-VM
// nesting needs the caller to track that themselves — the slot
// doesn't know which JVM the env belongs to.

#include <stddef.h>

static _Thread_local void *sx_jni_env_tl_slot;

void *sx_jni_env_tl_get(void) {
    return sx_jni_env_tl_slot;
}

void sx_jni_env_tl_set(void *env) {
    sx_jni_env_tl_slot = env;
}
