// FFI baseline test helpers — one trivial roundtrip per primitive C
// type so the sx-side test can verify both the parameter ABI and the
// return-value ABI per type. Locking these in BEFORE the Phase 1
// `#objc_call` / `#jni_call` work so any future lowering change that
// silently regresses primitive marshalling shows up here.

int                ffi_id_int   (int                v);
unsigned int       ffi_id_uint  (unsigned int       v);
short              ffi_id_short (short              v);
unsigned short     ffi_id_ushort(unsigned short     v);
long long          ffi_id_i64   (long long          v);
unsigned long long ffi_id_u64   (unsigned long long v);
signed char        ffi_id_schar (signed char        v);
unsigned char      ffi_id_uchar (unsigned char      v);
float              ffi_id_f32   (float              v);
double             ffi_id_f64   (double             v);
void *             ffi_id_ptr   (void *             v);

int                ffi_add_int   (int    a, int    b);
double             ffi_add_double(double a, double b);
