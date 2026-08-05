// The `<stdarg.h>` twin of `probe`: it reads the tail as `int`, which is what
// the C default argument promotions leave in the slot for every width the sx
// side passes.
#include <stdarg.h>
#include <stdint.h>

int64_t c_probe(int n, ...) {
    va_list ap;
    va_start(ap, n);
    int64_t total = 0;
    for (int i = 0; i < n; i++) {
        total += va_arg(ap, int);
    }
    va_end(ap);
    return total;
}
