#include "cdef.h"
#ifndef CDEF_BASE
#define CDEF_BASE 1
#endif
int cdef_value(void) { return CDEF_BASE; }
int cdef_doubled(int x) { return x * 2; }
