#include <stdarg.h>

long long sx_ext_sum_ints(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, int);
    va_end(ap);
    return total;
}

double sx_ext_avg_doubles(int n, ...) {
    va_list ap;
    va_start(ap, n);
    double total = 0.0;
    for (int i = 0; i < n; i++) total += va_arg(ap, double);
    va_end(ap);
    if (n == 0) return 0.0;
    return total / n;
}
