/* test_run.c — a trivial loadable ET_DYN to prove the dynamic loader runs on the
 * real A9 (relocations + I/D cache coherency). Exports run(); imports the
 * kernel-exported xtos_log so we can see it executed (over UART). */
extern void xtos_log(const char *s);
int run(int a, int b)
{
    xtos_log("[ldtest] hello from a loaded .so, running on the A9!\n");
    return a + b;
}
