/*
 * sio.c — the D1: drive on the serial bus.  See sio.h.
 *
 * Deliberately minimal: it answers a STATUS ($53) command with a real status
 * frame and NAKs anything it cannot make sense of, which is exactly the pair of
 * behaviours the two tests bracket.  pokey_skstat sends a well-formed
 * $31/'S'/$00/$00/$84 frame and reads the reply; pokey_serdirect sends ONE byte
 * and then drops the command line, which no drive can read as a command, and
 * requires a NAK.
 */
#include <stdio.h>
#include <string.h>

#include "sio.h"

/* ACID_SIOPROBE=1: every command-frame byte in, every reply byte out. */
int sio_probe;

void sio_reset(sio *d)
{
    memset(d, 0, sizeof *d);
    d->cmd  = 0;
    d->bit  = -1;
    d->line = 1;               /* idle mark */
}

static void queue(sio *d, uint8_t b)
{
    if (d->ntx < (int)sizeof d->tx) d->tx[d->ntx++] = b;
}

/* SIO's checksum is an 8-bit sum with the carry folded back in. */
static uint8_t cksum(const uint8_t *p, int n)
{
    unsigned s = 0;
    for (int i = 0; i < n; i++) { s += p[i]; s = (s & 0xFF) + (s >> 8); }
    return (uint8_t)s;
}

/* The command line went back up: the frame is whatever arrived while it was
 * down.  A drive that cannot parse it NAKs and says nothing more. */
static void answer(sio *d)
{
    d->ntx = d->txi = 0;
    d->delay = SIO_ACK_CYC;

    if (d->nframe != 5 || d->frame[0] != 0x31 ||
        cksum(d->frame, 4) != d->frame[4]) {
        queue(d, 0x4E);                        /* NAK */
        return;
    }
    if (d->frame[1] != 0x53) {                 /* not STATUS: nothing to say */
        queue(d, 0x4E);
        return;
    }
    queue(d, 0x41);                            /* ACK      */
    queue(d, 0x43);                            /* COMPLETE */
    /* An 810's four status bytes: command status, hardware status, format
     * timeout, and a byte the drive leaves at zero. */
    static const uint8_t st[4] = { 0x10, 0xFF, 0xFE, 0x00 };
    for (int i = 0; i < 4; i++) queue(d, st[i]);
    queue(d, cksum(st, 4));
}

void sio_cmd(sio *d, int asserted)
{
    if (asserted == d->cmd) return;
    if (sio_probe) fprintf(stderr, "  SIO command line %s (frame %d)\n", asserted ? "ASSERT" : "release", d->nframe);
    d->cmd = asserted;
    if (asserted) {
        d->nframe = 0;                         /* a new frame begins */
        d->ntx = d->txi = 0;                   /* and cancels any stale reply */
        d->bit = -1;
        d->line = 1;
    } else {
        answer(d);
    }
}

void sio_recv(sio *d, uint8_t b)
{
    if (sio_probe) fprintf(stderr, "  SIO <- $%02X (cmd %d)\n", b, d->cmd);
    if (!d->cmd) return;                       /* not addressed to the drive */
    if (d->nframe < (int)sizeof d->frame) d->frame[d->nframe++] = b;
}

void sio_tick(sio *d)
{
    if (d->bit < 0) {                          /* between bytes */
        if (d->txi >= d->ntx) return;
        if (d->delay > 0) { d->delay--; return; }
        if (sio_probe) fprintf(stderr, "  SIO -> $%02X\n", d->tx[d->txi]);
        d->bit     = 0;                        /* start bit */
        d->bit_cyc = SIO_BIT_CYC;
        d->line    = 0;
        return;
    }
    if (--d->bit_cyc > 0) return;

    d->bit++;
    if (d->bit <= 8) {                         /* eight data bits, LSB first */
        d->line    = (d->tx[d->txi] >> (d->bit - 1)) & 1;
        d->bit_cyc = SIO_BIT_CYC;
    } else if (d->bit == 9) {                  /* stop bit */
        d->line    = 1;
        d->bit_cyc = SIO_BIT_CYC;
    } else {
        d->txi++;
        d->bit   = -1;
        d->line  = 1;
        d->delay = SIO_GAP_CYC;
    }
}
