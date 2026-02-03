// Lives in library/vendors/ (NOT alongside the sx repo root vendors/),
// so the only way the build can find this from `vendors/...` is via
// imports.zig's stdlib-path resolution chain. Used as a regression net
// for that resolution branch — see examples/ffi-07-c-import-block.sx.

int sx_ffi_resolve_test_add(int a, int b);
int sx_ffi_resolve_test_mul(int a, int b);
