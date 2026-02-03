#include "1227-ffi-export-fn-rename.h"

// Defined on the sx side via `export "triple_c"` — a plain C-ABI symbol.
extern int triple_c(int n);

int call_triple(int n) {
    return triple_c(n) + 1;
}
