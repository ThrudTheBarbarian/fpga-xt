/* /bin/finictor — exercises DT_INIT_ARRAY / DT_FINI_ARRAY. The constructor runs
 * per process at spawn (app_main -> xtld_run_init); the destructor runs when the
 * cached image is UNLOADED (eviction -> xtld_unload -> xtld_run_fini). So "CTOR"
 * prints on each run, and "DTOR" prints later, when this image is evicted. */
#include <stdio.h>

__attribute__((constructor)) static void ctor(void) { printf("finictor: CTOR\n"); fflush(stdout); }
__attribute__((destructor))  static void dtor(void) { printf("finictor: DTOR\n"); fflush(stdout); }

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    printf("finictor: main\n");
    fflush(stdout);
}
