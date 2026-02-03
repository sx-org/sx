/* Extern C declarations whose names collide with sx's reserved type spellings.
   The `#import c` exemption must accept these generated names unedited, both as
   parameter names (`i1`, `i2`) and as a FUNCTION name (`i2`) — and an extern
   reserved-name function must be bare-callable (issue 0089). */
int ffi_pick(int i1, int i2, int which);
int ffi_sum(int i1, int i2);
int i2(int u8);
