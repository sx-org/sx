#include "1220-ffi-c-import-reserved-name-params.h"

int ffi_pick(int i1, int i2, int which) {
    return which == 0 ? i1 : i2;
}

int ffi_sum(int i1, int i2) {
    return i1 + i2;
}

int i2(int u8) {
    return u8 + 100;
}
