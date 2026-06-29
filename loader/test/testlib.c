/*
 * testlib.c — a tiny arm32 ELF ET_DYN that exercises every relocation type the
 * loader handles. Built with arm-none-eabi-gcc (-marm -fpic) + ld.lld -shared.
 *
 * It is NEVER executed in the host test (the host is arm64) — the harness loads
 * it and verifies the relocated data, which is the whole point of host-first:
 * prove the parse + relocation arithmetic before there's hardware to run on.
 */

extern void host_log(const char *msg);        /* imported function  */
extern volatile unsigned host_counter;         /* imported data      */

unsigned g_value = 0x1234;                      /* exported data      */
unsigned *g_selfptr = &g_value;                 /* -> R_ARM_ABS32 (defined) */

/* A non-preemptible (static) target so the pointer to it is a pure
 * R_ARM_RELATIVE (just add the load bias) — exercises that path directly. */
static unsigned s_hidden = 0x55;
unsigned *g_relptr = &s_hidden;                 /* -> R_ARM_RELATIVE  */
void (*g_logptr)(const char *) = host_log;      /* -> sym reloc (func)*/
volatile unsigned *g_ctrptr = &host_counter;    /* -> sym reloc (data)*/
const char g_msg[] = "hello from a loaded ARM ET_DYN";

/* Run only if executed (they aren't, on host). Prove init_array/fini_array are
 * discovered (the host checks the counts; it never runs ARM). */
__attribute__((constructor))
static void ctor(void) { g_value = 0xCAFE; }
__attribute__((destructor))
static void dtor(void) { g_value = 0xDEAD; }

unsigned add(unsigned a, unsigned b) { return a + b; }  /* exported function */

/* Exercises a full cross-call when executed (qemu): the loaded code calls an
 * imported (resolved) function and an internal one, and returns a value. */
unsigned greet(void) { host_log(g_msg); return add(40, 2); }
