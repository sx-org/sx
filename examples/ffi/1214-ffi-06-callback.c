#include "1214-ffi-06-callback.h"

int ffi_apply_callback(int (*cb)(int), int value) {
    return cb(value);
}

int ffi_apply_callback2(int (*cb)(void *ctx, int v), void *ctx, int v) {
    return cb(ctx, v);
}
