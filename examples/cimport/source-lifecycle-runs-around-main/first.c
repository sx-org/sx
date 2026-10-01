#include <unistd.h>

__attribute__((constructor)) static void first_ctor(void) { write(1, "first ctor\n", 11); }
__attribute__((destructor)) static void first_dtor(void) { write(1, "first dtor\n", 11); }
