// FFI large-struct (>16 B) by-value roundtrips. These route through
// the byval-pointer ABI path (caller copies onto its stack, hands the
// callee a pointer; on AAPCS64 a separate `x8` indirect-return
// register; on SysV AMD64 a hidden first arg). Distinct from the
// register-pair / [2 x i64] / HFA paths the small-struct baseline
// covers — locking those in here keeps the byval path honest.
//
//   Big24 — 24 B, three i64
//   Big48 — 48 B, six i64

typedef struct { long long a; long long b; long long c; }                 Big24;
typedef struct { long long a; long long b; long long c;
                 long long d; long long e; long long f; }                 Big48;

Big24     ffi_big24_make  (long long a, long long b, long long c);
Big24     ffi_big24_rotate(Big24 v);
long long ffi_big24_sum   (Big24 v);

Big48     ffi_big48_make  (long long a, long long b, long long c,
                           long long d, long long e, long long f);
Big48     ffi_big48_reverse(Big48 v);
long long ffi_big48_sum   (Big48 v);
