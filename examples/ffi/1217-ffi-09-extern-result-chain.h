// Trivial opaque-handle pattern — `make` produces a heap-allocated
// counter, `bump` returns the new value, `peek` reads without
// mutating, `dispose` frees. Mirrors the shape of real C handles
// (MTLBuffer*, AAssetManager*, file pointers, etc.) without pulling
// in any platform deps.

void *ffi_chain_make    (int seed);
int   ffi_chain_bump    (void *h, int delta);
int   ffi_chain_peek    (void *h);
void  ffi_chain_dispose (void *h);
