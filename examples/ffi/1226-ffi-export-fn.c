#include "1226-ffi-export-fn.h"

// Defined on the sx side via `export` — a plain C-ABI symbol, no sx context.
extern int sx_square(int n);

int call_sx_square(int n) {
    return sx_square(n) + 1;
}
