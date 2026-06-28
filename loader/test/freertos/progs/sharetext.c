/* /bin/sharetext — mmap-exec proof. Spawned twice, the program is LOADED ONCE:
 * its text/rodata/GOT are shared READ-ONLY (one physical copy), while each
 * instance gets PRIVATE data via copy-on-write from the post-init pristine image.
 *
 * Each run prints the address of a code symbol (shared text -> identical address
 * both runs) and of a writable global (same VA both runs), and shows the global
 * starting at its pristine value (100) in BOTH runs -> proving each got its own
 * COW copy. The shell reports the load count: 1 load for 2 spawns = shared.
 */
#include <stdio.h>

static int        g_counter = 100;       /* writable global -> per-process via COW */
static const char g_msg[]   = "shared-rodata";

static void marker(void) { }             /* a code symbol whose address we print */

void _app_entry(int argc, char **argv)
{
    const char *tag = argc > 1 ? argv[1] : "?";
    printf("sharetext[%s]: &marker=%p (text)  &g_counter=%p  msg=\"%s\"\n",
           tag, (void *)marker, (void *)&g_counter, g_msg);
    int before = g_counter;
    g_counter += (tag[0] == 'A') ? 1 : 1000;     /* first write -> COW private copy */
    printf("sharetext[%s]: g_counter %d -> %d (own private copy)\n",
           tag, before, g_counter);
    fflush(stdout);
}
