#include "1220-ffi-c-import-reserved-name-params.h"

int ffi_pick(int i16, int i8, int which) {
    return which == 0 ? i16 : i8;
}

int ffi_sum(int i16, int i8) {
    return i16 + i8;
}

int i8(int u8) {
    return u8 + 100;
}
