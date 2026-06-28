/* /bin/faultprog — dereferences NULL to prove T2-a.2: the faulting task is
 * killed by the OS and the shell (a separate task) keeps running. */
void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    volatile int *p = 0;
    *p = 0xdead;                 /* NULL write -> DATA-ABORT -> this task dies */
}
