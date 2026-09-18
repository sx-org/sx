#include "text.h"

static char buffer[8] = "raw";

int text_length(const char *s) {
    int n = 0;
    while (s[n]) n++;
    return n;
}

const char *text_tag(void) {
    return "tag";
}

char *text_buffer(void) {
    return buffer;
}
