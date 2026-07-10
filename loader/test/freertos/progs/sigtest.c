/* sigtest — exercises the real kernel signal path.
 *   sigtest            : run the test battery
 *   sigtest send P S D : helper — after D ms, kill(P, S) [a real 2nd process, so
 *                        it can signal the parent while the parent spins/blocks]
 * Run under qemu:  printf 'sigtest\nexit 66\n' | (make freertos, piped) */
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static volatile sig_atomic_t got_usr1;
static volatile sig_atomic_t got_usr2;
static volatile sig_atomic_t got_chld;

static void on_usr1(int s) { (void)s; got_usr1 = 1; }
static void on_usr2(int s) { (void)s; got_usr2 = 1; }
static void on_chld(int s) { (void)s; got_chld = 1; }

/* spawn a real child (vfork+exec, which works now) that signals us later */
static void spawn_sender(pid_t target, int sig, int delay_ms)
{
    char sp[16], ss[16], sd[16];
    snprintf(sp, sizeof sp, "%d", (int)target);
    snprintf(ss, sizeof ss, "%d", sig);
    snprintf(sd, sizeof sd, "%d", delay_ms);
    char *argv[] = { "sigtest", "send", sp, ss, sd, 0 };
    pid_t k = vfork();
    if (k == 0) { execv("/bin/sigtest", argv); _exit(127); }
}

int main(int argc, char **argv)
{
    if (argc == 5 && !strcmp(argv[1], "send")) {           /* helper: kill(target,sig) after delay_ms */
        usleep(atoi(argv[4]) * 1000);
        kill(atoi(argv[2]), atoi(argv[3]));
        return 0;
    }

    int pass = 0, total = 0;

    /* ---- 1. synchronous self-delivery at a syscall boundary ---- */
    signal(SIGUSR1, on_usr1);
    total++;
    kill(getpid(), SIGUSR1);           /* delivered on kill()'s return-to-PL0 */
    if (got_usr1) { pass++; printf("sigtest: [1] sync self-deliver   PASS\n"); }
    else            printf("sigtest: [1] sync self-deliver   FAIL\n");

    /* ---- 2. async delivery into a CPU-bound loop (no syscalls in the loop) ---- */
    signal(SIGUSR2, on_usr2);
    total++;
    spawn_sender(getpid(), SIGUSR2, 60);
    volatile unsigned long spins = 0;
    while (!got_usr2 && spins < 300000000UL) spins++;     /* pure userland */
    if (got_usr2) { pass++; printf("sigtest: [2] async CPU-loop     PASS\n"); }
    else            printf("sigtest: [2] async CPU-loop     FAIL (never delivered)\n");

    /* ---- 3. EINTR: a blocked pipe read cut short by a signal (deferred path) ---- */
    total++;
    got_usr1 = 0;
    int fds[2];
    if (pipe(fds) == 0) {
        spawn_sender(getpid(), SIGUSR1, 60);
        char c; long r = read(fds[0], &c, 1);      /* blocks (empty pipe, writer open) */
        if (got_usr1) { pass++; printf("sigtest: [3] EINTR blocked read  PASS (read=%ld)\n", r); }
        else            printf("sigtest: [3] EINTR blocked read  FAIL\n");
    } else printf("sigtest: [3] EINTR blocked read  SKIP (pipe failed)\n");

    /* ---- 4. kernel SIGCHLD-on-exit: a child dying signals the parent ---- */
    total++;
    got_chld = 0;
    signal(SIGCHLD, on_chld);
    spawn_sender(getpid(), 0, 0);                          /* child: kill(pid,0) then exit -> SIGCHLD */
    for (int i = 0; i < 60 && !got_chld; i++) usleep(10000);   /* usleep = a delivery point */
    if (got_chld) { pass++; printf("sigtest: [4] SIGCHLD on exit    PASS\n"); }
    else            printf("sigtest: [4] SIGCHLD on exit    FAIL\n");

    printf("sigtest: %d/%d passed\n", pass, total);
    return pass == total ? 0 : 1;
}
