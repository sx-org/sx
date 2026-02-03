// FFI struct-marshalling baselines covering four aggregate ABI slots:
//   Vec2   — 8 B,  two f32         — register-pair (float) path
//   Vec4f  — 16 B, four f32        — HFA (homogeneous float aggregate)
//   Pair64 — 16 B, two i64         — 9..16 B int ABI ([2 x i64] coercion)
//   Quad32 — 16 B, four i32        — 9..16 B int ABI ([2 x i64] coercion)
// Declared here so the .c has a header to include; sx side imports
// via `#source` only and re-declares the structs natively (c_import
// rewrites struct-typed params/returns to *void).

typedef struct { float x; float y; }                           Vec2;
typedef struct { float x; float y; float z; float w; }         Vec4f;
typedef struct { long long a; long long b; }                   Pair64;
typedef struct { int a; int b; int c; int d; }                 Quad32;

Vec2      ffi_vec2_make    (float x, float y);
Vec2      ffi_vec2_swap    (Vec2 v);
float     ffi_vec2_sum     (Vec2 v);

Vec4f     ffi_vec4f_make   (float x, float y, float z, float w);
Vec4f     ffi_vec4f_reverse(Vec4f v);
float     ffi_vec4f_sum    (Vec4f v);

Pair64    ffi_pair64_make  (long long a, long long b);
Pair64    ffi_pair64_swap  (Pair64 p);
long long ffi_pair64_sum   (Pair64 p);

Quad32    ffi_quad32_make  (int a, int b, int c, int d);
Quad32    ffi_quad32_reverse(Quad32 q);
int       ffi_quad32_sum   (Quad32 q);
