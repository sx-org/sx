#include "1210-ffi-02-small-struct.h"

Vec2 ffi_vec2_make(float x, float y) {
    Vec2 r = { x, y };
    return r;
}

Vec2 ffi_vec2_swap(Vec2 v) {
    Vec2 r = { v.y, v.x };
    return r;
}

float ffi_vec2_sum(Vec2 v) {
    return v.x + v.y;
}

Vec4f ffi_vec4f_make(float x, float y, float z, float w) {
    Vec4f r = { x, y, z, w };
    return r;
}

Vec4f ffi_vec4f_reverse(Vec4f v) {
    Vec4f r = { v.w, v.z, v.y, v.x };
    return r;
}

float ffi_vec4f_sum(Vec4f v) {
    return v.x + v.y + v.z + v.w;
}

Pair64 ffi_pair64_make(long long a, long long b) {
    Pair64 r = { a, b };
    return r;
}

Pair64 ffi_pair64_swap(Pair64 p) {
    Pair64 r = { p.b, p.a };
    return r;
}

long long ffi_pair64_sum(Pair64 p) {
    return p.a + p.b;
}

Quad32 ffi_quad32_make(int a, int b, int c, int d) {
    Quad32 r = { a, b, c, d };
    return r;
}

Quad32 ffi_quad32_reverse(Quad32 q) {
    Quad32 r = { q.d, q.c, q.b, q.a };
    return r;
}

int ffi_quad32_sum(Quad32 q) {
    return q.a + q.b + q.c + q.d;
}
