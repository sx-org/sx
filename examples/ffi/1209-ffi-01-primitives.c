#include "1209-ffi-01-primitives.h"

int                ffi_id_int   (int                v) { return v; }
unsigned int       ffi_id_uint  (unsigned int       v) { return v; }
short              ffi_id_short (short              v) { return v; }
unsigned short     ffi_id_ushort(unsigned short     v) { return v; }
long long          ffi_id_i64   (long long          v) { return v; }
unsigned long long ffi_id_u64   (unsigned long long v) { return v; }
signed char        ffi_id_schar (signed char        v) { return v; }
unsigned char      ffi_id_uchar (unsigned char      v) { return v; }
float              ffi_id_f32   (float              v) { return v; }
double             ffi_id_f64   (double             v) { return v; }
void *             ffi_id_ptr   (void *             v) { return v; }

int                ffi_add_int   (int    a, int    b) { return a + b; }
double             ffi_add_double(double a, double b) { return a + b; }
