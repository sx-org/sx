// The C twin the sx function pointer calls: one fixed parameter, then the tail.

#include <stdarg.h>

long long c_sum_ints(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, int);
    va_end(ap);
    return total;
}
