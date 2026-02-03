// Focused FP-aggregate (HFA) FFI baselines. Distinct from the int-aggregate
// register-coercion paths because all-float / all-double structs of ≤4 fields
// stay as struct values in LLVM and are passed/returned via the float
// register file (AAPCS64 v0..v3; SysV AMD64 xmm0..xmm7). This was the
// `UIEdgeInsets`-as-f32-vs-f64 landmine — pinned here so a future ABI rule
// change that wrecks the FP path fails this test directly.
//
//   FQuad   — 16 B, four float    (small HFA; same slot as Vec4f)
//   DQuad   — 32 B, four double   (UIEdgeInsets-shape HFA)

typedef struct { float a; float b; float c; float d; }              FQuad;
typedef struct { double a; double b; double c; double d; }          DQuad;

FQuad  ffi_fquad_make   (float a, float b, float c, float d);
FQuad  ffi_fquad_reverse(FQuad v);
float  ffi_fquad_sum    (FQuad v);

DQuad  ffi_dquad_make   (double a, double b, double c, double d);
DQuad  ffi_dquad_reverse(DQuad v);
double ffi_dquad_sum    (DQuad v);
