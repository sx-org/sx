// String / byte-pointer FFI baselines. Covers the three shapes
// callers actually use at the sx ↔ C boundary:
//   - null-terminated `[:0]u8`              (C-style string)
//   - raw byte pointer `[*]u8` + length     (slice-style)
//   - sx `string` decayed to `ptr`          (the slice-decay branch
//                                            in coerceArg pulls .ptr)

#include <stddef.h>

int    ffi_strlen     (const char *s);
int    ffi_first_byte (const char *s);
int    ffi_sum_bytes  (const unsigned char *buf, int len);
void   ffi_write_byte (unsigned char *buf, int idx, unsigned char val);
const char* ffi_static_greeting(void);
