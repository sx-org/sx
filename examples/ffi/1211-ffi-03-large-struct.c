#include "1211-ffi-03-large-struct.h"

Big24 ffi_big24_make(long long a, long long b, long long c) {
    Big24 r = { a, b, c };
    return r;
}

Big24 ffi_big24_rotate(Big24 v) {
    Big24 r = { v.c, v.a, v.b };
    return r;
}

long long ffi_big24_sum(Big24 v) {
    return v.a + v.b + v.c;
}

Big48 ffi_big48_make(long long a, long long b, long long c,
                     long long d, long long e, long long f) {
    Big48 r = { a, b, c, d, e, f };
    return r;
}

Big48 ffi_big48_reverse(Big48 v) {
    Big48 r = { v.f, v.e, v.d, v.c, v.b, v.a };
    return r;
}

long long ffi_big48_sum(Big48 v) {
    return v.a + v.b + v.c + v.d + v.e + v.f;
}
