// The C side of the cursor differential: each function reads its tail with
// `<stdarg.h>`, and its sx twin reads the same arguments with `@va_*`.

#include <stdarg.h>
#include <string.h>

long long c_sum_ints(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, int);
    va_end(ap);
    return total;
}

double c_sum_doubles(int n, ...) {
    va_list ap;
    va_start(ap, n);
    double total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, double);
    va_end(ap);
    return total;
}

long long c_total_text(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long total = 0;
    for (int i = 0; i < n; i++) total += (long long)strlen(va_arg(ap, const char *));
    va_end(ap);
    return total;
}

long long c_twice(int n, ...) {
    va_list ap;
    va_start(ap, n);
    va_list dup;
    va_copy(dup, ap);
    long long first = 0;
    for (int i = 0; i < n; i++) first += va_arg(ap, int);
    va_end(ap);
    long long second = 0;
    for (int i = 0; i < n; i++) second += va_arg(dup, int);
    va_end(dup);
    return first * 100 + second;
}
