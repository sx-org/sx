#include "1237-ffi-cvariadic-c23-import.h"

/* C23 opens a list over a tail that no named parameter precedes: `va_start`
   takes the list alone, and the count rides in the tail like everything else. */
long long sum_all(...) {
    va_list ap;
    va_start(ap);
    int n = va_arg(ap, int);
    long long total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, int);
    va_end(ap);
    return total;
}

double scale_all(...) {
    va_list ap;
    va_start(ap);
    int n = va_arg(ap, int);
    double total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, double);
    va_end(ap);
    return total;
}

long long relay(int n, va_list ap) {
    long long total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, int);
    return total;
}

long long tally(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long r = relay(n, ap);
    va_end(ap);
    return r;
}

long long c_sum_all(void) { return sum_all(3, 4, 5, 6); }
double c_scale_all(void) { return scale_all(3, 1.25, 2.5, 0.5); }
long long c_tally(void) { return tally(3, 7, 8, 9); }
