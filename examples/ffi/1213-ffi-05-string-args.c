#include "1213-ffi-05-string-args.h"

int ffi_strlen(const char *s) {
    int n = 0;
    while (s[n] != 0) n++;
    return n;
}

int ffi_first_byte(const char *s) {
    return (int)(unsigned char)s[0];
}

int ffi_sum_bytes(const unsigned char *buf, int len) {
    int total = 0;
    for (int i = 0; i < len; i++) total += buf[i];
    return total;
}

void ffi_write_byte(unsigned char *buf, int idx, unsigned char val) {
    buf[idx] = val;
}

const char* ffi_static_greeting(void) {
    return "hello from C";
}
