#include <stdlib.h>
#include <unistd.h>

__attribute__((destructor)) static void quit_dtor(void) { write(1, "dtor\n", 5); }
static void quit_atexit(void) { write(1, "atexit\n", 7); }

void quit(int code) {
    atexit(quit_atexit);
    exit(code);
}
