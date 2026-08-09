/*
 * sio.h — a disk drive on the serial bus, seen from the computer's end.
 *
 * pokey_skstat and pokey_serdirect both drive the SIO line by hand once past
 * their `jsr dskinv` gate: they write PBCTL, SKCTL and SEROUT directly and then
 * watch SKSTAT.  Nothing above the wire can stand in for that, so this models
 * the wire — a device that collects the five-byte command frame, checks its
 * checksum, and shifts its answer back one bit at a time at 19200 baud.
 *
 * The command line is PIA port B's CB2, driven by PBCTL bit 3: LOW asserts it.
 * A frame runs from the assert to the deassert, and the drive answers after
 * the deassert, which is when both tests go looking for it.
 */
#ifndef SIO_H
#define SIO_H

#include <stdint.h>

/* One bit time at 19200 baud.  pokey_serdirect names the same number twice —
 * it bit-bangs the reply with AUDF1 = 94-4 after a 47-cycle half-bit lead-in —
 * so this is the rate the test itself samples at, not a derived one. */
#define SIO_BIT_CYC   94
/* The gap between the bytes of a reply.  A real drive is not gapless, and both
 * tests need to SEE the line return to mark: pokey_skstat's last two loops
 * watch SKSTAT bit 1 fall and rise again across one byte. */
#define SIO_GAP_CYC   400
/* How long the drive takes to answer once the command line goes back up. */
#define SIO_ACK_CYC  2000

typedef struct {
    int     cmd;             /* command line asserted */
    uint8_t frame[8];        /* the command frame as it arrives */
    int     nframe;
    uint8_t tx[16];          /* what the drive still owes the computer */
    int     ntx, txi;
    long    delay;           /* cycles before the next byte's start bit */
    int     bit;             /* -1 idle, else 0..9 of the byte going out */
    long    bit_cyc;         /* cycles left in that bit */
    int     line;            /* the serial INPUT line, 1 = mark */
} sio;

extern int sio_probe;

void sio_reset(sio *d);
/* PBCTL bit 3 moved: `asserted` is 1 when the command line is LOW. */
void sio_cmd(sio *d, int asserted);
/* POKEY finished shifting a byte out. */
void sio_recv(sio *d, uint8_t b);
void sio_tick(sio *d);

static inline int sio_line(const sio *d) { return d->line; }

#endif /* SIO_H */
