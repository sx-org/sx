// The C side of the `va_list` boundary differential. Each reader takes a count
// and a `va_list` exactly as `vsnprintf` and `sqlite3_vmprintf` do, and each has
// an sx twin the sx side calls with the same arguments.

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

// The sx `export` twins, called from C with a list this file opened.
long long sx_sum_ints(int n, va_list ap);
double sx_sum_doubles(int n, va_list ap);
long long sx_total_text(int n, va_list ap);
long long sx_twice(int n, va_list ap);

long long c_sum_ints(int n, va_list ap) {
    long long total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, int);
    return total;
}

double c_sum_doubles(int n, va_list ap) {
    double total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, double);
    return total;
}

long long c_total_text(int n, va_list ap) {
    long long total = 0;
    for (int i = 0; i < n; i++) total += (long long)strlen(va_arg(ap, const char *));
    return total;
}

// Two traversals of one list: the second reads a copy taken before the first
// moved the position.
long long c_twice(int n, va_list ap) {
    va_list dup;
    va_copy(dup, ap);
    long long first = 0;
    for (int i = 0; i < n; i++) first += va_arg(ap, int);
    long long second = 0;
    for (int i = 0; i < n; i++) second += va_arg(dup, int);
    va_end(dup);
    return first * 100 + second;
}

long long c_calls_sx_twice(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long r = sx_twice(n, ap);
    va_end(ap);
    return r;
}

long long c_twice_tail(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long r = c_twice(n, ap);
    va_end(ap);
    return r;
}

// The C owners: each opens a list over its own tail and hands it to the sx
// export, so the incoming direction is exercised with a list C built.
long long c_calls_sx_ints(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long r = sx_sum_ints(n, ap);
    va_end(ap);
    return r;
}

double c_calls_sx_doubles(int n, ...) {
    va_list ap;
    va_start(ap, n);
    double r = sx_sum_doubles(n, ap);
    va_end(ap);
    return r;
}

long long c_calls_sx_text(int n, ...) {
    va_list ap;
    va_start(ap, n);
    long long r = sx_total_text(n, ap);
    va_end(ap);
    return r;
}

static char vmprintf_buf[128];

const char *vmprintf(const char *fmt, va_list ap) {
    vsnprintf(vmprintf_buf, sizeof vmprintf_buf, fmt, ap);
    return vmprintf_buf;
}

unsigned char *xvsnprintf(int size, unsigned char *out, const char *fmt, va_list ap) {
    vsnprintf((char *)out, (size_t)size, fmt, ap);
    return out;
}

typedef struct sqlite3_str {
    char text[64];
    int used;
} sqlite3_str;

void str_vappendf(sqlite3_str *s, const char *fmt, va_list ap) {
    s->used += vsnprintf(s->text + s->used, sizeof s->text - (size_t)s->used, fmt, ap);
}
