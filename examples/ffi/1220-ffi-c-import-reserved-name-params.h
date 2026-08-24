/* Extern C declarations whose names collide with sx's reserved type spellings.
   The `@import c` exemption must accept these generated names unedited, both as
   parameter names (`i16`, `i8`) and as a FUNCTION name (`i8`) — and an extern
   reserved-name function must be bare-callable. */
int ffi_pick(int i16, int i8, int which);
int ffi_sum(int i16, int i8);
int i8(int u8);
