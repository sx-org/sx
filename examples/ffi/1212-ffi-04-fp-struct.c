#include "1212-ffi-04-fp-struct.h"

FQuad ffi_fquad_make(float a, float b, float c, float d) {
    FQuad r = { a, b, c, d };
    return r;
}

FQuad ffi_fquad_reverse(FQuad v) {
    FQuad r = { v.d, v.c, v.b, v.a };
    return r;
}

float ffi_fquad_sum(FQuad v) {
    return v.a + v.b + v.c + v.d;
}

DQuad ffi_dquad_make(double a, double b, double c, double d) {
    DQuad r = { a, b, c, d };
    return r;
}

DQuad ffi_dquad_reverse(DQuad v) {
    DQuad r = { v.d, v.c, v.b, v.a };
    return r;
}

double ffi_dquad_sum(DQuad v) {
    return v.a + v.b + v.c + v.d;
}
