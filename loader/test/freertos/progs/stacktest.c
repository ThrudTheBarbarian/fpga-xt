/* /bin/stacktest — march the stack downward 4 KB per frame (infinite recursion
 * with a page-sized local) until it overflows into the guard page below the
 * stack and takes a precise fault. */
#include <stdio.h>
static volatile int sink;
static void recurse(int depth)
{
    volatile char buf[4096];                 /* one page per frame */
    buf[0] = (char)depth; buf[4095] = (char)depth;
    sink += buf[0];
    recurse(depth + 1);                      /* no base case: guaranteed overflow */
    sink += buf[4095];
}
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    printf("stacktest: overflowing the stack (expect a guard-page fault)...\n");
    fflush(stdout);
    recurse(0);
}
