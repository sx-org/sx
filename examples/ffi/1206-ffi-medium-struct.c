// Companion to examples/101-ffi-medium-struct.sx — a single
// roundtrip through a 16-byte integer-only struct. Pinned in a
// dedicated example because integer aggregates in this size class
// route through emit_llvm.zig's `[2 x i64]` ABI coercion slot, a
// different path from the small (≤8 B) integer struct, the 16-byte
// HFA, and the >16 B byval-pointer cases.

typedef struct { long long a; long long b; } Pair64;

Pair64 ffi_pair64_swap(Pair64 p) {
    Pair64 r = { p.b, p.a };
    return r;
}
