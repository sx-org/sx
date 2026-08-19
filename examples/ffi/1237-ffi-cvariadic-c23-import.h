/* The variadic prototype shapes `@import c` synthesizes an extern declaration
   for: a C23 tail with no named parameter before it, the fixed-parameter tail,
   and a reader that takes the list itself. */

#include <stdarg.h>

long long sum_all(...);
double scale_all(...);
long long tally(int n, ...);
long long relay(int n, va_list ap);

/* The differential: C calls each shape with the arguments the sx side passes. */
long long c_sum_all(void);
double c_scale_all(void);
long long c_tally(void);
