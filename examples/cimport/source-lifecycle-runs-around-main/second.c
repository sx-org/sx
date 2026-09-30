#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void second_ctor(void) { write(1, "second ctor\n", 12); }
__attribute__((destructor)) static void second_dtor(void) { write(1, "second dtor\n", 12); }
static void second_atexit(void) { write(1, "second atexit\n", 14); }

void arm_second(void) { atexit(second_atexit); }
