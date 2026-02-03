#include "1217-ffi-09-extern-result-chain.h"
#include <stdlib.h>

void *ffi_chain_make(int seed) {
    int *p = (int *)malloc(sizeof(int));
    if (p) *p = seed;
    return p;
}

int ffi_chain_bump(void *h, int delta) {
    int *p = (int *)h;
    *p += delta;
    return *p;
}

int ffi_chain_peek(void *h) {
    return *(int *)h;
}

void ffi_chain_dispose(void *h) {
    free(h);
}
