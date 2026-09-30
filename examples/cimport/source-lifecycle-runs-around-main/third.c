#include <unistd.h>

__attribute__((destructor)) static void third_dtor(void) { write(1, "third dtor\n", 11); }
