/* repl.c — the command line.
 *
 * One dispatcher, fed by console.c, so the same commands work over RTT (Black
 * Magic Probe) and over USART2 (the Zynq).  Everything the board can do should
 * be reachable from here: bring-up goes much faster when a hardware question
 * can be answered by typing rather than by rebuilding.
 */
#include "repl.h"

#include <stddef.h>
#include <stdint.h>

#include "board.h"
#include "clock.h"
#include "console.h"
#include "fan.h"
#include "fault.h"
#include "joystick.h"
#include "pots.h"
#include "usb.h"
#include "stm32f411.h"

#define LINE_MAX    96
#define ARG_MAX     8
#define PROMPT      "xt> "

extern size_t strlen(const char *s);
extern int    strcmp(const char *a, const char *b);

static char s_line[LINE_MAX];
static int  s_len;
static int  s_started;

/* ------------------------------------------------------------ arg parsing -*/

static int parse_u32(const char *s, uint32_t *out)
{
    uint32_t v    = 0;
    int      base = 10, any = 0;

    if (!s || !*s)
        return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s   += 2;
    } else if (s[0] == '$') {
        base = 16;
        s++;
    }

    for (; *s; s++) {
        int d;
        if (*s >= '0' && *s <= '9')       d = *s - '0';
        else if (*s >= 'a' && *s <= 'f')  d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F')  d = *s - 'A' + 10;
        else                              return 0;
        if (d >= base)
            return 0;
        v = v * (uint32_t)base + (uint32_t)d;
        any = 1;
    }
    if (!any)
        return 0;
    *out = v;
    return 1;
}

static gpio_t *port_by_letter(char c)
{
    switch (c) {
    case 'a': case 'A': return GPIOA;
    case 'b': case 'B': return GPIOB;
    case 'c': case 'C': return GPIOC;
    case 'd': case 'D': return GPIOD;
    case 'e': case 'E': return GPIOE;
    case 'h': case 'H': return GPIOH;
    default:            return NULL;
    }
}

/* ------------------------------------------------------------- commands ---*/

typedef void (*cmd_fn)(int argc, char **argv);

struct command {
    const char *name;
    const char *usage;
    const char *help;
    cmd_fn      fn;
};

static const struct command s_cmds[];

static void cmd_help(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    console_puts("\r\n");
    for (const struct command *c = s_cmds; c->name; c++)
        console_printf("  %-22s %s\r\n", c->usage, c->help);
    console_puts("\r\nnumbers accept 0x or $ for hex\r\n");
}

static void cmd_id(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    const uint32_t *uid = (const uint32_t *)UID_BASE;
    uint32_t        idc = DBGMCU_IDCODE;

    console_printf("device    STM32F411x%c  dev 0x%03lx  rev 0x%04lx\r\n",
                   FLASH_SIZE_KB > 256 ? 'E' : 'C',
                   idc & 0xFFFU, (idc >> 16) & 0xFFFFU);
    console_printf("flash     %lu KB\r\n", (uint32_t)FLASH_SIZE_KB);
    console_printf("uid       %08lx-%08lx-%08lx\r\n", uid[0], uid[1], uid[2]);
    console_printf("clock     %lu Hz core, %s\r\n", (uint32_t)SYSCLK_HZ,
                   clock_on_hse() ? "HSE crystal" : "HSI (NO CRYSTAL!)");
    console_printf("reset     %s (csr %08lx)\r\n",
                   clock_reset_cause_str(), clock_reset_cause());
    console_printf("uptime    %lu ms\r\n", clock_millis());
    if (fault_pending())
        console_puts("fault     a fault record is saved; type 'fault'\r\n");
}

static void cmd_uptime(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    uint32_t ms = clock_millis();
    console_printf("%lu.%03lu s\r\n", ms / 1000U, ms % 1000U);
}

static void cmd_reset(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    console_puts("resetting\r\n");
    clock_delay_ms(20);                     /* let the console drain */
    clock_reboot();
}

static void cmd_mr(int argc, char **argv)
{
    uint32_t addr, count = 4;

    if (argc < 2 || !parse_u32(argv[1], &addr)) {
        console_puts("usage: mr <addr> [words]\r\n");
        return;
    }
    if (argc > 2 && !parse_u32(argv[2], &count))
        count = 4;
    if (count > 256)
        count = 256;

    addr &= ~3UL;
    for (uint32_t i = 0; i < count; i++) {
        if ((i & 3U) == 0)
            console_printf("\r\n%08lx:", addr + i * 4U);
        console_printf(" %08lx", *(volatile uint32_t *)(addr + i * 4U));
    }
    console_puts("\r\n");
}

static void cmd_mw(int argc, char **argv)
{
    uint32_t addr, val;

    if (argc < 3 || !parse_u32(argv[1], &addr) || !parse_u32(argv[2], &val)) {
        console_puts("usage: mw <addr> <value>\r\n");
        return;
    }
    addr &= ~3UL;
    *(volatile uint32_t *)addr = val;
    console_printf("%08lx <- %08lx\r\n", addr, val);
}

static void cmd_gpio(int argc, char **argv)
{
    if (argc < 2) {
        console_puts("usage: gpio <port><pin> [in|out|0|1]\r\n"
                     "       gpio <port>\r\n");
        return;
    }

    gpio_t *p = port_by_letter(argv[1][0]);
    if (!p) {
        console_puts("bad port (a-e, h)\r\n");
        return;
    }

    if (!argv[1][1]) {                      /* whole port */
        console_printf("P%c idr %04lx  odr %04lx  moder %08lx  pupdr %08lx\r\n",
                       argv[1][0] & ~0x20, p->IDR & 0xFFFFU, p->ODR & 0xFFFFU,
                       p->MODER, p->PUPDR);
        return;
    }

    uint32_t pin;
    if (!parse_u32(&argv[1][1], &pin) || pin > 15) {
        console_puts("bad pin (0-15)\r\n");
        return;
    }

    if (argc >= 3) {
        if (!strcmp(argv[2], "in")) {
            gpio_mode(p, pin, GPIO_MODE_IN);
        } else if (!strcmp(argv[2], "out")) {
            gpio_mode(p, pin, GPIO_MODE_OUT);
        } else if (!strcmp(argv[2], "0") || !strcmp(argv[2], "1")) {
            gpio_write(p, pin, argv[2][0] - '0');
            gpio_mode(p, pin, GPIO_MODE_OUT);
        } else {
            console_puts("expected in, out, 0 or 1\r\n");
            return;
        }
    }

    /* IDR lags a BSRR write by a cycle or two, so a read taken immediately
     * after driving the pin reports the OLD level — which reads as "the write
     * did not work" when it did. */
    clock_delay_us(2);

    static const char *modes[] = { "in", "out", "af", "analog" };
    console_printf("P%c%lu = %d  (%s)\r\n", argv[1][0] & ~0x20, pin,
                   gpio_read(p, pin), modes[(p->MODER >> (pin * 2)) & 3U]);
}

static void cmd_hub(int argc, char **argv)
{
    if (argc < 2 || !strcmp(argv[1], "cycle")) {
        console_puts("cycling hub reset\r\n");
        board_hub_cycle();
        console_puts("hub released\r\n");
        return;
    }
    if (!strcmp(argv[1], "1") || !strcmp(argv[1], "hold")) {
        board_hub_reset(1);
        console_puts("hub held in reset\r\n");
    } else if (!strcmp(argv[1], "0") || !strcmp(argv[1], "run")) {
        board_hub_reset(0);
        console_puts("hub released\r\n");
    } else {
        console_puts("usage: hub [cycle|hold|run]\r\n");
    }
}

static void cmd_js(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    static const char *names[JOY_PORTS] = { "ILL", "IL ", "IR ", "IRR" };

    console_printf("raw dirs %04x  btns %x\r\n",
                   joystick_raw_dirs(), joystick_raw_btns());
    for (int p = 0; p < JOY_PORTS; p++) {
        uint8_t v = joystick_state(p);
        console_printf("  %s  %c%c%c%c %s\r\n", names[p],
                       (v & JOY_UP)    ? 'U' : '.',
                       (v & JOY_DOWN)  ? 'D' : '.',
                       (v & JOY_LEFT)  ? 'L' : '.',
                       (v & JOY_RIGHT) ? 'R' : '.',
                       (v & JOY_FIRE)  ? "FIRE" : "");
    }
}

static void cmd_pot(int argc, char **argv)
{
    static const char *names[POT_COUNT] = {
        "ILL_A", "ILL_B", "IL_A", "IL_B", "IR_A", "IR_B", "IRR_A", "IRR_B"
    };

    if (argc >= 4 && !strcmp(argv[1], "cal")) {
        uint32_t lo, hi;
        if (parse_u32(argv[2], &lo) && parse_u32(argv[3], &hi)) {
            pots_calibrate(lo, hi);
            console_printf("calibration %lu..%lu us\r\n", lo, hi);
        } else {
            console_puts("usage: pot cal <min_us> <max_us>\r\n");
        }
        return;
    }

    uint32_t lo, hi;
    pots_calibration(&lo, &hi);
    console_printf("sweeps %lu, calibration %lu..%lu us\r\n",
                   pots_frames(), lo, hi);
    for (int i = 0; i < POT_COUNT; i++)
        console_printf("  %-6s %3u   (%lu us)\r\n",
                       names[i], pots_value(i), pots_micros(i));
}

static void cmd_fan(int argc, char **argv)
{
    if (argc >= 3 && !strcmp(argv[1], "rpm")) {
        uint32_t rpm;
        if (parse_u32(argv[2], &rpm)) {
            fan_set_target_rpm((uint16_t)rpm);
            console_printf("target %lu rpm (closed loop%s)\r\n",
                           rpm, rpm ? "" : " off");
        }
        return;
    }
    if (argc >= 2) {
        uint32_t duty;
        if (parse_u32(argv[1], &duty)) {
            fan_set_duty((uint16_t)duty);
            console_printf("duty %lu/1000, open loop\r\n", duty);
            return;
        }
        console_puts("usage: fan [<duty 0-1000> | rpm <target>]\r\n");
        return;
    }

    console_printf("duty   %u/1000\r\n", fan_duty());
    console_printf("rpm    %lu\r\n", fan_rpm());
    console_printf("mode   %s", fan_closed_loop() ? "PID, target " : "open loop");
    if (fan_closed_loop())
        console_printf("%u rpm", fan_target_rpm());
    console_puts("\r\n");
}

static void cmd_fault(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "clear")) {
        fault_clear();
        console_puts("cleared\r\n");
        return;
    }
    fault_dump();
}

static void cmd_usb(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "hub")) {
        console_puts("cycling hub reset\r\n");
        board_hub_cycle();
        return;
    }
    usb_status();
}

static void cmd_ring(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    board_doorbell();
    console_puts("PA4 doorbell pulsed\r\n");
}

static void cmd_crash(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    console_puts("faulting deliberately\r\n");
    clock_delay_ms(20);
    *(volatile uint32_t *)0xF0000000UL = 1;
}

static const struct command s_cmds[] = {
    { "help",   "help",                 "this list",                    cmd_help   },
    { "?",      "?",                    "alias for help",               cmd_help   },
    { "id",     "id",                   "chip, clocks, reset cause",    cmd_id     },
    { "uptime", "uptime",               "time since boot",              cmd_uptime },
    { "mr",     "mr <addr> [n]",        "read memory words",            cmd_mr     },
    { "mw",     "mw <addr> <val>",      "write a memory word",          cmd_mw     },
    { "gpio",   "gpio <pin> [state]",   "inspect or drive a pin",       cmd_gpio   },
    { "hub",    "hub [cycle|hold|run]", "USB hub reset on PA9",         cmd_hub    },
    { "js",     "js",                   "joystick and button state",    cmd_js     },
    { "pot",    "pot [cal lo hi]",      "paddle values",                cmd_pot    },
    { "fan",    "fan [duty|rpm n]",     "fan duty, tach and PID",       cmd_fan    },
    { "usb",    "usb [hub]",            "USB host + HID state",         cmd_usb    },
    { "ring",   "ring",                 "pulse the FPGA doorbell",      cmd_ring   },
    { "fault",  "fault [clear]",        "saved fault record",           cmd_fault  },
    { "crash",  "crash",                "force a fault (test)",         cmd_crash  },
    { "reset",  "reset",                "reboot the STM32",             cmd_reset  },
    { NULL, NULL, NULL, NULL }
};

/* ------------------------------------------------------------- line loop --*/

static void execute(char *line)
{
    char *argv[ARG_MAX];
    int   argc = 0;

    for (char *p = line; *p && argc < ARG_MAX; ) {
        while (*p == ' ' || *p == '\t')
            *p++ = '\0';
        if (!*p)
            break;
        argv[argc++] = p;
        while (*p && *p != ' ' && *p != '\t')
            p++;
    }

    if (argc == 0)
        return;

    for (const struct command *c = s_cmds; c->name; c++) {
        if (!strcmp(argv[0], c->name)) {
            c->fn(argc, argv);
            return;
        }
    }
    console_printf("unknown command '%s' — try help\r\n", argv[0]);
}

void repl_banner(void)
{
    console_puts("\r\n\r\nAtari-XT motherboard companion — STM32F411VE\r\n");
    console_printf("%lu MHz, %s, reset: %s\r\n",
                   (uint32_t)(SYSCLK_HZ / 1000000UL),
                   clock_on_hse() ? "HSE" : "HSI fallback",
                   clock_reset_cause_str());
    if (fault_pending()) {
        console_puts("\r\nprevious boot faulted:\r\n");
        fault_dump();
    }
    console_puts("\r\ntype 'help' for commands\r\n" PROMPT);
    s_started = 1;
}

void repl_poll(void)
{
    int ch;

    if (!s_started)
        repl_banner();

    while ((ch = console_getc()) >= 0) {
        switch (ch) {
        case '\r':
        case '\n':
            console_puts("\r\n");
            s_line[s_len] = '\0';
            execute(s_line);
            s_len = 0;
            console_puts(PROMPT);
            break;

        case 0x08:                          /* backspace */
        case 0x7F:                          /* delete */
            if (s_len > 0) {
                s_len--;
                console_puts("\b \b");
            }
            break;

        case 0x03:                          /* ctrl-C */
            s_len = 0;
            console_puts("^C\r\n" PROMPT);
            break;

        case 0x0C:                          /* ctrl-L */
            console_puts("\r\n" PROMPT);
            console_write(s_line, s_len);
            break;

        default:
            if (ch >= 0x20 && ch < 0x7F && s_len < LINE_MAX - 1) {
                s_line[s_len++] = (char)ch;
                console_putc((char)ch);
            }
            break;
        }
    }
}
