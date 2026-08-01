/*
 * xt6502.c — cycle-exact 6502, all 256 opcodes.
 *
 * See xt6502.h for the design.  Every rd()/wr() below is one machine cycle in
 * the order the NMOS part issues it: dummy reads, RMW double writes, page-cross
 * fixups and all.  Conventions for the undocumented opcodes match
 * hdl/xt6502f/xt6502f.sv (which passes all 256 Tom Harte vectors), so the
 * software and fabric cores agree by construction rather than by coincidence —
 * that is what makes a disagreement between them diagnostic.
 */
#include "xt6502.h"

/* ---- bus + interrupt poll -------------------------------------------------
 * The poll is clocked here because "one bus call == one cycle" is the only
 * definition of time this core has.  poll_prev therefore always holds the
 * sample taken one cycle back, which at instruction end is the penultimate
 * cycle — exactly where the NMOS part decides. */
static void poll(xt6502 *c)
{
    c->poll_prev = c->poll;
    if (c->nmi && !c->nmi_prev) c->nmi_pend = 1;    /* edge-latched, one-shot */
    c->nmi_prev = c->nmi;
    c->poll = (uint8_t)(c->nmi_pend || (c->irq && !(c->p & XTF_I)));
}

static uint8_t rd(xt6502 *c, uint16_t a)
{
    uint8_t v = c->rd(c->ctx, a);
    c->cycles++;
    poll(c);
    return v;
}

static void wr(xt6502 *c, uint16_t a, uint8_t v)
{
    c->wr(c->ctx, a, v);
    c->cycles++;
    poll(c);
}

static void push(xt6502 *c, uint8_t v) { wr(c, (uint16_t)(0x0100 | c->s), v); c->s--; }
static uint8_t pull(xt6502 *c) { c->s++; return rd(c, (uint16_t)(0x0100 | c->s)); }

/* ---- flags ---------------------------------------------------------------- */
static void setnz(xt6502 *c, uint8_t v)
{
    c->p = (uint8_t)((c->p & ~(XTF_N | XTF_Z)) | (v & 0x80) | (v ? 0 : XTF_Z));
}
static void setc(xt6502 *c, int b) { c->p = (uint8_t)(b ? (c->p | XTF_C) : (c->p & ~XTF_C)); }
static void setv(xt6502 *c, int b) { c->p = (uint8_t)(b ? (c->p | XTF_V) : (c->p & ~XTF_V)); }

/* ---- ALU ------------------------------------------------------------------
 * NMOS decimal mode, including the quirks real software and ACID800 rely on:
 * ADC takes N and V from the intermediate BEFORE the high-nibble fixup and Z
 * from the BINARY sum; SBC takes ALL its flags from the binary operation and
 * only the accumulator is nibble-adjusted. */
static void op_adc(xt6502 *c, uint8_t v)
{
    unsigned cin = (c->p & XTF_C) ? 1u : 0u;
    unsigned bin = (unsigned)c->a + v + cin;

    if (c->p & XTF_D) {
        unsigned al = (c->a & 0x0fu) + (v & 0x0fu) + cin;
        if (al > 0x09u) al = ((al + 0x06u) & 0x0fu) + 0x10u;
        unsigned inter = (c->a & 0xf0u) + (v & 0xf0u) + al;
        c->p = (uint8_t)((c->p & ~(XTF_N | XTF_V)) | (inter & 0x80u));
        setv(c, (~(c->a ^ v) & (c->a ^ (unsigned char)inter) & 0x80) != 0);
        if (inter > 0x9fu) inter += 0x60u;
        setc(c, inter > 0xffu);
        c->p = (uint8_t)((c->p & ~XTF_Z) | (((bin & 0xffu) == 0) ? XTF_Z : 0));
        c->a = (uint8_t)inter;
    } else {
        setv(c, (~(c->a ^ v) & (c->a ^ (unsigned char)bin) & 0x80) != 0);
        setc(c, bin > 0xffu);
        c->a = (uint8_t)bin;
        setnz(c, c->a);
    }
}

static void op_sbc(xt6502 *c, uint8_t v)
{
    unsigned cin = (c->p & XTF_C) ? 1u : 0u;
    unsigned bin = (unsigned)c->a + (uint8_t)~v + cin;
    uint8_t  res = (uint8_t)bin;

    /* flags: always binary, in both modes */
    setv(c, ((c->a ^ v) & (c->a ^ res) & 0x80) != 0);
    setc(c, bin > 0xffu);
    setnz(c, res);

    if (c->p & XTF_D) {
        int al = (int)(c->a & 0x0f) - (int)(v & 0x0f) + (int)cin - 1;
        if (al < 0) al = ((al - 6) & 0x0f) - 0x10;
        int ai = (int)(c->a & 0xf0) - (int)(v & 0xf0) + al;
        if (ai < 0) ai -= 0x60;
        c->a = (uint8_t)ai;
    } else {
        c->a = res;
    }
}

static void op_cmp(xt6502 *c, uint8_t r, uint8_t v)
{
    setnz(c, (uint8_t)(r - v));
    setc(c, r >= v);
}

static void op_bit(xt6502 *c, uint8_t v)
{
    c->p = (uint8_t)((c->p & ~(XTF_N | XTF_V | XTF_Z))
                     | (v & 0xc0) | (((c->a & v) == 0) ? XTF_Z : 0));
}

static uint8_t op_asl(xt6502 *c, uint8_t v) { setc(c, v & 0x80); v = (uint8_t)(v << 1); setnz(c, v); return v; }
static uint8_t op_lsr(xt6502 *c, uint8_t v) { setc(c, v & 0x01); v = (uint8_t)(v >> 1); setnz(c, v); return v; }
static uint8_t op_rol(xt6502 *c, uint8_t v)
{
    uint8_t o = (uint8_t)((v << 1) | ((c->p & XTF_C) ? 1 : 0));
    setc(c, v & 0x80); setnz(c, o); return o;
}
static uint8_t op_ror(xt6502 *c, uint8_t v)
{
    uint8_t o = (uint8_t)((v >> 1) | ((c->p & XTF_C) ? 0x80 : 0));
    setc(c, v & 0x01); setnz(c, o); return o;
}
static uint8_t op_inc(xt6502 *c, uint8_t v) { v++; setnz(c, v); return v; }
static uint8_t op_dec(xt6502 *c, uint8_t v) { v--; setnz(c, v); return v; }

/* ---- addressing modes -----------------------------------------------------
 * Each performs exactly the cycles the real part performs.  The _r / _w split
 * is the page-cross rule: a READ skips the fixup cycle when the index does not
 * cross a page, a WRITE or RMW always spends it (it cannot know the address is
 * final until it has added). */
static uint16_t am_imm(xt6502 *c)  { return c->pc++; }
static uint16_t am_zp(xt6502 *c)   { return rd(c, c->pc++); }
static uint16_t am_zpx(xt6502 *c)  { uint8_t z = rd(c, c->pc++); rd(c, z); return (uint8_t)(z + c->x); }
static uint16_t am_zpy(xt6502 *c)  { uint8_t z = rd(c, c->pc++); rd(c, z); return (uint8_t)(z + c->y); }

static uint16_t am_abs(xt6502 *c)
{
    uint8_t lo = rd(c, c->pc++);
    uint8_t hi = rd(c, c->pc++);
    return (uint16_t)(lo | (hi << 8));
}

static uint16_t am_absi_r(xt6502 *c, uint8_t i)
{
    uint8_t lo = rd(c, c->pc++), hi = rd(c, c->pc++);
    uint16_t base = (uint16_t)(lo | (hi << 8));
    uint16_t ea   = (uint16_t)(base + i);
    if ((ea ^ base) & 0xff00)
        rd(c, (uint16_t)((base & 0xff00) | (ea & 0x00ff)));   /* wrong-page read */
    return ea;
}

static uint16_t am_absi_w(xt6502 *c, uint8_t i)
{
    uint8_t lo = rd(c, c->pc++), hi = rd(c, c->pc++);
    uint16_t base = (uint16_t)(lo | (hi << 8));
    uint16_t ea   = (uint16_t)(base + i);
    rd(c, (uint16_t)((base & 0xff00) | (ea & 0x00ff)));       /* always */
    return ea;
}

static uint16_t am_izx(xt6502 *c)
{
    uint8_t p = rd(c, c->pc++);
    rd(c, p);                                                 /* dummy, pre-index */
    uint8_t lo = rd(c, (uint8_t)(p + c->x));
    uint8_t hi = rd(c, (uint8_t)(p + c->x + 1));              /* zero-page wrap */
    return (uint16_t)(lo | (hi << 8));
}

static uint16_t am_izy_r(xt6502 *c)
{
    uint8_t p  = rd(c, c->pc++);
    uint8_t lo = rd(c, p), hi = rd(c, (uint8_t)(p + 1));
    uint16_t base = (uint16_t)(lo | (hi << 8));
    uint16_t ea   = (uint16_t)(base + c->y);
    if ((ea ^ base) & 0xff00)
        rd(c, (uint16_t)((base & 0xff00) | (ea & 0x00ff)));
    return ea;
}

static uint16_t am_izy_w(xt6502 *c)
{
    uint8_t p  = rd(c, c->pc++);
    uint8_t lo = rd(c, p), hi = rd(c, (uint8_t)(p + 1));
    uint16_t base = (uint16_t)(lo | (hi << 8));
    uint16_t ea   = (uint16_t)(base + c->y);
    rd(c, (uint16_t)((base & 0xff00) | (ea & 0x00ff)));
    return ea;
}

/* ---- helpers for the instruction shapes ----------------------------------- */
static void ld(xt6502 *c, uint8_t *reg, uint16_t ea) { *reg = rd(c, ea); setnz(c, *reg); }

/* Read-modify-write: read, write the OLD value back, then the new one.  That
 * middle write is real and visible — hardware registers that latch on write see
 * it, which is why INC $D40A (WSYNC) behaves the way ACID800 expects. */
static void rmw(xt6502 *c, uint16_t ea, uint8_t (*f)(xt6502 *, uint8_t))
{
    uint8_t v = rd(c, ea);
    wr(c, ea, v);
    wr(c, ea, f(c, v));
}

/* The combined illegal RMWs (SLO/RLA/SRE/RRA/DCP/ISC): the same double write,
 * then the ALU half acts on the result. */
static void rmw2(xt6502 *c, uint16_t ea, uint8_t (*f)(xt6502 *, uint8_t),
                 void (*g)(xt6502 *, uint8_t))
{
    uint8_t v = rd(c, ea);
    wr(c, ea, v);
    uint8_t o = f(c, v);
    wr(c, ea, o);
    g(c, o);
}

static void alu_and(xt6502 *c, uint8_t v) { c->a &= v; setnz(c, c->a); }
static void alu_ora(xt6502 *c, uint8_t v) { c->a |= v; setnz(c, c->a); }
static void alu_eor(xt6502 *c, uint8_t v) { c->a ^= v; setnz(c, c->a); }
static void alu_cmpa(xt6502 *c, uint8_t v) { op_cmp(c, c->a, v); }

static void branch(xt6502 *c, int take)
{
    int8_t off = (int8_t)rd(c, c->pc++);
    if (!take) return;
    uint16_t from = c->pc;
    uint16_t to   = (uint16_t)(from + off);
    rd(c, from);                                              /* discarded fetch */
    if ((to ^ from) & 0xff00)
        rd(c, (uint16_t)((from & 0xff00) | (to & 0x00ff)));   /* unfixed PCH */
    c->pc = to;
}

/* Unstable stores (SHA/SHX/SHY/TAS): the value is reg & (high byte of the
 * UNFIXED address + 1), and on a page cross that value replaces the high byte.
 * Same convention as the fabric core. */
static void ush(xt6502 *c, uint8_t reg, uint8_t idx, int tas)
{
    uint8_t lo = rd(c, c->pc++), hi = rd(c, c->pc++);
    uint16_t base = (uint16_t)(lo | (hi << 8));
    uint16_t ea   = (uint16_t)(base + idx);
    rd(c, (uint16_t)((base & 0xff00) | (ea & 0x00ff)));
    uint8_t val = (uint8_t)(reg & (uint8_t)(hi + 1));
    if ((ea ^ base) & 0xff00) ea = (uint16_t)((val << 8) | (ea & 0x00ff));
    if (tas) c->s = (uint8_t)(c->a & c->x);
    wr(c, ea, val);
}

static void ush_izy(xt6502 *c)          /* SHA (zp),Y — $93 */
{
    uint8_t p  = rd(c, c->pc++);
    uint8_t lo = rd(c, p), hi = rd(c, (uint8_t)(p + 1));
    uint16_t base = (uint16_t)(lo | (hi << 8));
    uint16_t ea   = (uint16_t)(base + c->y);
    rd(c, (uint16_t)((base & 0xff00) | (ea & 0x00ff)));
    uint8_t val = (uint8_t)((c->a & c->x) & (uint8_t)(hi + 1));
    if ((ea ^ base) & 0xff00) ea = (uint16_t)((val << 8) | (ea & 0x00ff));
    wr(c, ea, val);
}

/* ---- interrupt / reset sequences ------------------------------------------ */
static void interrupt(xt6502 *c, uint16_t vec, int brk)
{
    /* Seven cycles either way.  BRK has already spent one on its opcode fetch
     * and spends this one consuming its padding byte; a hardware interrupt has
     * fetched nothing, so it burns two discarded reads here instead. */
    rd(c, c->pc);
    if (brk) c->pc++;
    else     rd(c, c->pc);
    push(c, (uint8_t)(c->pc >> 8));
    /* ---- the vector is committed HERE, after the PCH push ------------------
     * i.e. at the end of the sequence's THIRD cycle, which for a BRK is its
     * third cycle too (the opcode fetch is cycle one).  An NMI latched up to
     * and including this cycle diverts the vector to $FFFA; one latched later
     * does NOT — and is not merely deferred either, it is SWALLOWED, because
     * the edge detector stays held reset for the rest of the sequence.
     *
     * Both halves of ACID800 antic_blockednmi turn on this one cycle.  The VBI
     * request appears at scanline cycle 6 (ANTIC_CYC_NMIST); the test places a
     * BRK at scanline cycles 3-9 and then, one cycle later, at 4-10.  The first
     * lands the request on BRK cycle 4 and the BRK must complete through $FFFE
     * with the NMI lost for good; the second lands it on cycle 3 and the NMI
     * must take over with the BRK's own pushes and its pushed PC intact. */
    if (c->nmi_pend) { vec = 0xFFFA; c->nmi_pend = 0; }
    push(c, (uint8_t)c->pc);
    push(c, (uint8_t)(brk ? (c->p | XTF_B | XTF_U) : ((c->p | XTF_U) & ~XTF_B)));
    c->p |= XTF_I;
    uint8_t lo = rd(c, vec);
    uint8_t hi = rd(c, (uint16_t)(vec + 1));
    /* Anything latched after the commit dies with the sequence.  The poll is
     * cleared with it: poll_prev at this point is the sample taken during the
     * vector fetch, and leaving it set would hand the swallowed NMI straight
     * back at the next instruction boundary.  I is set, so a pending IRQ is
     * masked and re-polled on its own the moment the handler enables it. */
    c->nmi_pend = 0;
    c->poll = c->poll_prev = 0;
    c->pc = (uint16_t)(lo | (hi << 8));
}

void xt6502_init(xt6502 *c, xt6502_rd_fn rdf, xt6502_wr_fn wrf, void *ctx)
{
    for (unsigned i = 0; i < sizeof *c; i++) ((unsigned char *)c)[i] = 0;
    c->rd = rdf; c->wr = wrf; c->ctx = ctx;
    c->p = XTF_I | XTF_U;
    c->s = 0xFD;
}

void xt6502_reset(xt6502 *c)
{
    c->jammed = 0;
    c->nmi_pend = 0;
    c->poll = c->poll_prev = 0;
    rd(c, c->pc);
    rd(c, c->pc);
    rd(c, (uint16_t)(0x0100 | c->s)); c->s--;      /* three dummy stack cycles: */
    rd(c, (uint16_t)(0x0100 | c->s)); c->s--;      /* the pushes are suppressed  */
    rd(c, (uint16_t)(0x0100 | c->s)); c->s--;      /* but S still decrements     */
    c->p |= XTF_I;
    uint8_t lo = rd(c, 0xFFFC);
    uint8_t hi = rd(c, 0xFFFD);
    c->pc = (uint16_t)(lo | (hi << 8));
}

void xt6502_step(xt6502 *c)
{
    /* A jammed CPU never retires another instruction, but the bus does not go
     * quiet: the address lines settle into a fixed dance (FFFF, FFFE, FFFE,
     * then FFFF for ever).  ANTIC still gets its cycles, so a jam must still
     * advance the world — hence one cycle per call rather than a spin. */
    if (c->jammed) {
        uint16_t a = (c->jam_cnt == 0) ? 0xFFFF
                   : (c->jam_cnt <= 2) ? 0xFFFE : 0xFFFF;
        rd(c, a);
        if (c->jam_cnt < 15) c->jam_cnt++;
        return;
    }

    if (c->poll_prev) {
        uint16_t vec = 0xFFFE;
        if (c->nmi_pend) { vec = 0xFFFA; c->nmi_pend = 0; }
        interrupt(c, vec, 0);
        c->poll = c->poll_prev = 0;
        return;
    }

    uint8_t op = rd(c, c->pc++);
    uint16_t ea;

    switch (op) {
    /* ---- loads ---- */
    case 0xA9: ld(c, &c->a, am_imm(c)); break;
    case 0xA5: ld(c, &c->a, am_zp(c)); break;
    case 0xB5: ld(c, &c->a, am_zpx(c)); break;
    case 0xAD: ld(c, &c->a, am_abs(c)); break;
    case 0xBD: ld(c, &c->a, am_absi_r(c, c->x)); break;
    case 0xB9: ld(c, &c->a, am_absi_r(c, c->y)); break;
    case 0xA1: ld(c, &c->a, am_izx(c)); break;
    case 0xB1: ld(c, &c->a, am_izy_r(c)); break;

    case 0xA2: ld(c, &c->x, am_imm(c)); break;
    case 0xA6: ld(c, &c->x, am_zp(c)); break;
    case 0xB6: ld(c, &c->x, am_zpy(c)); break;
    case 0xAE: ld(c, &c->x, am_abs(c)); break;
    case 0xBE: ld(c, &c->x, am_absi_r(c, c->y)); break;

    case 0xA0: ld(c, &c->y, am_imm(c)); break;
    case 0xA4: ld(c, &c->y, am_zp(c)); break;
    case 0xB4: ld(c, &c->y, am_zpx(c)); break;
    case 0xAC: ld(c, &c->y, am_abs(c)); break;
    case 0xBC: ld(c, &c->y, am_absi_r(c, c->x)); break;

    /* ---- stores ---- */
    case 0x85: wr(c, am_zp(c), c->a); break;
    case 0x95: wr(c, am_zpx(c), c->a); break;
    case 0x8D: wr(c, am_abs(c), c->a); break;
    case 0x9D: wr(c, am_absi_w(c, c->x), c->a); break;
    case 0x99: wr(c, am_absi_w(c, c->y), c->a); break;
    case 0x81: wr(c, am_izx(c), c->a); break;
    case 0x91: wr(c, am_izy_w(c), c->a); break;

    case 0x86: wr(c, am_zp(c), c->x); break;
    case 0x96: wr(c, am_zpy(c), c->x); break;
    case 0x8E: wr(c, am_abs(c), c->x); break;

    case 0x84: wr(c, am_zp(c), c->y); break;
    case 0x94: wr(c, am_zpx(c), c->y); break;
    case 0x8C: wr(c, am_abs(c), c->y); break;

    /* ---- ALU: ORA / AND / EOR ---- */
    case 0x09: alu_ora(c, rd(c, am_imm(c))); break;
    case 0x05: alu_ora(c, rd(c, am_zp(c))); break;
    case 0x15: alu_ora(c, rd(c, am_zpx(c))); break;
    case 0x0D: alu_ora(c, rd(c, am_abs(c))); break;
    case 0x1D: alu_ora(c, rd(c, am_absi_r(c, c->x))); break;
    case 0x19: alu_ora(c, rd(c, am_absi_r(c, c->y))); break;
    case 0x01: alu_ora(c, rd(c, am_izx(c))); break;
    case 0x11: alu_ora(c, rd(c, am_izy_r(c))); break;

    case 0x29: alu_and(c, rd(c, am_imm(c))); break;
    case 0x25: alu_and(c, rd(c, am_zp(c))); break;
    case 0x35: alu_and(c, rd(c, am_zpx(c))); break;
    case 0x2D: alu_and(c, rd(c, am_abs(c))); break;
    case 0x3D: alu_and(c, rd(c, am_absi_r(c, c->x))); break;
    case 0x39: alu_and(c, rd(c, am_absi_r(c, c->y))); break;
    case 0x21: alu_and(c, rd(c, am_izx(c))); break;
    case 0x31: alu_and(c, rd(c, am_izy_r(c))); break;

    case 0x49: alu_eor(c, rd(c, am_imm(c))); break;
    case 0x45: alu_eor(c, rd(c, am_zp(c))); break;
    case 0x55: alu_eor(c, rd(c, am_zpx(c))); break;
    case 0x4D: alu_eor(c, rd(c, am_abs(c))); break;
    case 0x5D: alu_eor(c, rd(c, am_absi_r(c, c->x))); break;
    case 0x59: alu_eor(c, rd(c, am_absi_r(c, c->y))); break;
    case 0x41: alu_eor(c, rd(c, am_izx(c))); break;
    case 0x51: alu_eor(c, rd(c, am_izy_r(c))); break;

    /* ---- ADC / SBC ---- */
    case 0x69: op_adc(c, rd(c, am_imm(c))); break;
    case 0x65: op_adc(c, rd(c, am_zp(c))); break;
    case 0x75: op_adc(c, rd(c, am_zpx(c))); break;
    case 0x6D: op_adc(c, rd(c, am_abs(c))); break;
    case 0x7D: op_adc(c, rd(c, am_absi_r(c, c->x))); break;
    case 0x79: op_adc(c, rd(c, am_absi_r(c, c->y))); break;
    case 0x61: op_adc(c, rd(c, am_izx(c))); break;
    case 0x71: op_adc(c, rd(c, am_izy_r(c))); break;

    case 0xE9: case 0xEB: op_sbc(c, rd(c, am_imm(c))); break;   /* $EB = undoc SBC */
    case 0xE5: op_sbc(c, rd(c, am_zp(c))); break;
    case 0xF5: op_sbc(c, rd(c, am_zpx(c))); break;
    case 0xED: op_sbc(c, rd(c, am_abs(c))); break;
    case 0xFD: op_sbc(c, rd(c, am_absi_r(c, c->x))); break;
    case 0xF9: op_sbc(c, rd(c, am_absi_r(c, c->y))); break;
    case 0xE1: op_sbc(c, rd(c, am_izx(c))); break;
    case 0xF1: op_sbc(c, rd(c, am_izy_r(c))); break;

    /* ---- compares ---- */
    case 0xC9: op_cmp(c, c->a, rd(c, am_imm(c))); break;
    case 0xC5: op_cmp(c, c->a, rd(c, am_zp(c))); break;
    case 0xD5: op_cmp(c, c->a, rd(c, am_zpx(c))); break;
    case 0xCD: op_cmp(c, c->a, rd(c, am_abs(c))); break;
    case 0xDD: op_cmp(c, c->a, rd(c, am_absi_r(c, c->x))); break;
    case 0xD9: op_cmp(c, c->a, rd(c, am_absi_r(c, c->y))); break;
    case 0xC1: op_cmp(c, c->a, rd(c, am_izx(c))); break;
    case 0xD1: op_cmp(c, c->a, rd(c, am_izy_r(c))); break;

    case 0xE0: op_cmp(c, c->x, rd(c, am_imm(c))); break;
    case 0xE4: op_cmp(c, c->x, rd(c, am_zp(c))); break;
    case 0xEC: op_cmp(c, c->x, rd(c, am_abs(c))); break;

    case 0xC0: op_cmp(c, c->y, rd(c, am_imm(c))); break;
    case 0xC4: op_cmp(c, c->y, rd(c, am_zp(c))); break;
    case 0xCC: op_cmp(c, c->y, rd(c, am_abs(c))); break;

    /* ---- BIT ---- */
    case 0x24: op_bit(c, rd(c, am_zp(c))); break;
    case 0x2C: op_bit(c, rd(c, am_abs(c))); break;

    /* ---- shifts / rotates, accumulator ---- */
    case 0x0A: rd(c, c->pc); c->a = op_asl(c, c->a); break;
    case 0x4A: rd(c, c->pc); c->a = op_lsr(c, c->a); break;
    case 0x2A: rd(c, c->pc); c->a = op_rol(c, c->a); break;
    case 0x6A: rd(c, c->pc); c->a = op_ror(c, c->a); break;

    /* ---- shifts / rotates / inc / dec, memory ---- */
    case 0x06: rmw(c, am_zp(c), op_asl); break;
    case 0x16: rmw(c, am_zpx(c), op_asl); break;
    case 0x0E: rmw(c, am_abs(c), op_asl); break;
    case 0x1E: rmw(c, am_absi_w(c, c->x), op_asl); break;

    case 0x46: rmw(c, am_zp(c), op_lsr); break;
    case 0x56: rmw(c, am_zpx(c), op_lsr); break;
    case 0x4E: rmw(c, am_abs(c), op_lsr); break;
    case 0x5E: rmw(c, am_absi_w(c, c->x), op_lsr); break;

    case 0x26: rmw(c, am_zp(c), op_rol); break;
    case 0x36: rmw(c, am_zpx(c), op_rol); break;
    case 0x2E: rmw(c, am_abs(c), op_rol); break;
    case 0x3E: rmw(c, am_absi_w(c, c->x), op_rol); break;

    case 0x66: rmw(c, am_zp(c), op_ror); break;
    case 0x76: rmw(c, am_zpx(c), op_ror); break;
    case 0x6E: rmw(c, am_abs(c), op_ror); break;
    case 0x7E: rmw(c, am_absi_w(c, c->x), op_ror); break;

    case 0xE6: rmw(c, am_zp(c), op_inc); break;
    case 0xF6: rmw(c, am_zpx(c), op_inc); break;
    case 0xEE: rmw(c, am_abs(c), op_inc); break;
    case 0xFE: rmw(c, am_absi_w(c, c->x), op_inc); break;

    case 0xC6: rmw(c, am_zp(c), op_dec); break;
    case 0xD6: rmw(c, am_zpx(c), op_dec); break;
    case 0xCE: rmw(c, am_abs(c), op_dec); break;
    case 0xDE: rmw(c, am_absi_w(c, c->x), op_dec); break;

    /* ---- register transfers / inc / dec / flags (2 cycles) ---- */
    case 0xAA: rd(c, c->pc); c->x = c->a; setnz(c, c->x); break;
    case 0xA8: rd(c, c->pc); c->y = c->a; setnz(c, c->y); break;
    case 0x8A: rd(c, c->pc); c->a = c->x; setnz(c, c->a); break;
    case 0x98: rd(c, c->pc); c->a = c->y; setnz(c, c->a); break;
    case 0xBA: rd(c, c->pc); c->x = c->s; setnz(c, c->x); break;
    case 0x9A: rd(c, c->pc); c->s = c->x; break;             /* TXS sets no flags */
    case 0xE8: rd(c, c->pc); c->x++; setnz(c, c->x); break;
    case 0xC8: rd(c, c->pc); c->y++; setnz(c, c->y); break;
    case 0xCA: rd(c, c->pc); c->x--; setnz(c, c->x); break;
    case 0x88: rd(c, c->pc); c->y--; setnz(c, c->y); break;
    case 0x18: rd(c, c->pc); c->p &= ~XTF_C; break;
    case 0x38: rd(c, c->pc); c->p |=  XTF_C; break;
    case 0x58: rd(c, c->pc); c->p &= ~XTF_I; break;
    case 0x78: rd(c, c->pc); c->p |=  XTF_I; break;
    case 0xD8: rd(c, c->pc); c->p &= ~XTF_D; break;
    case 0xF8: rd(c, c->pc); c->p |=  XTF_D; break;
    case 0xB8: rd(c, c->pc); c->p &= ~XTF_V; break;
    case 0xEA: rd(c, c->pc); break;                          /* NOP */

    /* ---- stack ---- */
    case 0x48: rd(c, c->pc); push(c, c->a); break;
    case 0x08: rd(c, c->pc); push(c, (uint8_t)(c->p | XTF_B | XTF_U)); break;
    case 0x68: rd(c, c->pc); rd(c, (uint16_t)(0x0100 | c->s)); c->a = pull(c); setnz(c, c->a); break;
    case 0x28: rd(c, c->pc); rd(c, (uint16_t)(0x0100 | c->s));
               c->p = (uint8_t)((pull(c) & ~XTF_B) | XTF_U); break;

    /* ---- jumps / subroutines ---- */
    case 0x4C: c->pc = am_abs(c); break;
    case 0x6C: {                                             /* JMP (ind) */
        uint16_t p = am_abs(c);
        uint8_t lo = rd(c, p);
        /* the NMOS page-wrap bug: the high byte comes from the SAME page */
        uint8_t hi = rd(c, (uint16_t)((p & 0xff00) | ((p + 1) & 0x00ff)));
        c->pc = (uint16_t)(lo | (hi << 8));
        break;
    }
    case 0x20: {                                             /* JSR */
        uint8_t lo = rd(c, c->pc++);
        rd(c, (uint16_t)(0x0100 | c->s));                    /* internal */
        push(c, (uint8_t)(c->pc >> 8));
        push(c, (uint8_t)c->pc);
        uint8_t hi = rd(c, c->pc);
        c->pc = (uint16_t)(lo | (hi << 8));
        break;
    }
    case 0x60: {                                             /* RTS */
        rd(c, c->pc);
        rd(c, (uint16_t)(0x0100 | c->s));
        uint8_t lo = pull(c), hi = pull(c);
        c->pc = (uint16_t)(lo | (hi << 8));
        rd(c, c->pc);
        c->pc++;
        break;
    }
    case 0x40: {                                             /* RTI */
        rd(c, c->pc);
        rd(c, (uint16_t)(0x0100 | c->s));
        c->p = (uint8_t)((pull(c) & ~XTF_B) | XTF_U);
        uint8_t lo = pull(c), hi = pull(c);
        c->pc = (uint16_t)(lo | (hi << 8));
        break;
    }
    case 0x00: interrupt(c, 0xFFFE, 1); break;               /* BRK */

    /* ---- branches ---- */
    case 0x10: branch(c, !(c->p & XTF_N)); break;
    case 0x30: branch(c,  (c->p & XTF_N)); break;
    case 0x50: branch(c, !(c->p & XTF_V)); break;
    case 0x70: branch(c,  (c->p & XTF_V)); break;
    case 0x90: branch(c, !(c->p & XTF_C)); break;
    case 0xB0: branch(c,  (c->p & XTF_C)); break;
    case 0xD0: branch(c, !(c->p & XTF_Z)); break;
    case 0xF0: branch(c,  (c->p & XTF_Z)); break;

    /* ================= undocumented opcodes ================================
     * The stable set real software needs (Prince of Persia executes ANC, SAX
     * and LAX), plus the unstable group with the fabric core's conventions. */

    /* LAX — load A and X together */
    case 0xA7: ea = am_zp(c);          c->a = c->x = rd(c, ea); setnz(c, c->a); break;
    case 0xB7: ea = am_zpy(c);         c->a = c->x = rd(c, ea); setnz(c, c->a); break;
    case 0xAF: ea = am_abs(c);         c->a = c->x = rd(c, ea); setnz(c, c->a); break;
    case 0xBF: ea = am_absi_r(c, c->y);c->a = c->x = rd(c, ea); setnz(c, c->a); break;
    case 0xA3: ea = am_izx(c);         c->a = c->x = rd(c, ea); setnz(c, c->a); break;
    case 0xB3: ea = am_izy_r(c);       c->a = c->x = rd(c, ea); setnz(c, c->a); break;

    /* SAX — store A & X (no flags) */
    case 0x87: wr(c, am_zp(c),  (uint8_t)(c->a & c->x)); break;
    case 0x97: wr(c, am_zpy(c), (uint8_t)(c->a & c->x)); break;
    case 0x8F: wr(c, am_abs(c), (uint8_t)(c->a & c->x)); break;
    case 0x83: wr(c, am_izx(c), (uint8_t)(c->a & c->x)); break;

    /* SLO = ASL + ORA */
    case 0x07: rmw2(c, am_zp(c),           op_asl, alu_ora); break;
    case 0x17: rmw2(c, am_zpx(c),          op_asl, alu_ora); break;
    case 0x0F: rmw2(c, am_abs(c),          op_asl, alu_ora); break;
    case 0x1F: rmw2(c, am_absi_w(c, c->x), op_asl, alu_ora); break;
    case 0x1B: rmw2(c, am_absi_w(c, c->y), op_asl, alu_ora); break;
    case 0x03: rmw2(c, am_izx(c),          op_asl, alu_ora); break;
    case 0x13: rmw2(c, am_izy_w(c),        op_asl, alu_ora); break;

    /* RLA = ROL + AND */
    case 0x27: rmw2(c, am_zp(c),           op_rol, alu_and); break;
    case 0x37: rmw2(c, am_zpx(c),          op_rol, alu_and); break;
    case 0x2F: rmw2(c, am_abs(c),          op_rol, alu_and); break;
    case 0x3F: rmw2(c, am_absi_w(c, c->x), op_rol, alu_and); break;
    case 0x3B: rmw2(c, am_absi_w(c, c->y), op_rol, alu_and); break;
    case 0x23: rmw2(c, am_izx(c),          op_rol, alu_and); break;
    case 0x33: rmw2(c, am_izy_w(c),        op_rol, alu_and); break;

    /* SRE = LSR + EOR */
    case 0x47: rmw2(c, am_zp(c),           op_lsr, alu_eor); break;
    case 0x57: rmw2(c, am_zpx(c),          op_lsr, alu_eor); break;
    case 0x4F: rmw2(c, am_abs(c),          op_lsr, alu_eor); break;
    case 0x5F: rmw2(c, am_absi_w(c, c->x), op_lsr, alu_eor); break;
    case 0x5B: rmw2(c, am_absi_w(c, c->y), op_lsr, alu_eor); break;
    case 0x43: rmw2(c, am_izx(c),          op_lsr, alu_eor); break;
    case 0x53: rmw2(c, am_izy_w(c),        op_lsr, alu_eor); break;

    /* RRA = ROR + ADC */
    case 0x67: rmw2(c, am_zp(c),           op_ror, op_adc); break;
    case 0x77: rmw2(c, am_zpx(c),          op_ror, op_adc); break;
    case 0x6F: rmw2(c, am_abs(c),          op_ror, op_adc); break;
    case 0x7F: rmw2(c, am_absi_w(c, c->x), op_ror, op_adc); break;
    case 0x7B: rmw2(c, am_absi_w(c, c->y), op_ror, op_adc); break;
    case 0x63: rmw2(c, am_izx(c),          op_ror, op_adc); break;
    case 0x73: rmw2(c, am_izy_w(c),        op_ror, op_adc); break;

    /* DCP = DEC + CMP */
    case 0xC7: rmw2(c, am_zp(c),           op_dec, alu_cmpa); break;
    case 0xD7: rmw2(c, am_zpx(c),          op_dec, alu_cmpa); break;
    case 0xCF: rmw2(c, am_abs(c),          op_dec, alu_cmpa); break;
    case 0xDF: rmw2(c, am_absi_w(c, c->x), op_dec, alu_cmpa); break;
    case 0xDB: rmw2(c, am_absi_w(c, c->y), op_dec, alu_cmpa); break;
    case 0xC3: rmw2(c, am_izx(c),          op_dec, alu_cmpa); break;
    case 0xD3: rmw2(c, am_izy_w(c),        op_dec, alu_cmpa); break;

    /* ISC = INC + SBC */
    case 0xE7: rmw2(c, am_zp(c),           op_inc, op_sbc); break;
    case 0xF7: rmw2(c, am_zpx(c),          op_inc, op_sbc); break;
    case 0xEF: rmw2(c, am_abs(c),          op_inc, op_sbc); break;
    case 0xFF: rmw2(c, am_absi_w(c, c->x), op_inc, op_sbc); break;
    case 0xFB: rmw2(c, am_absi_w(c, c->y), op_inc, op_sbc); break;
    case 0xE3: rmw2(c, am_izx(c),          op_inc, op_sbc); break;
    case 0xF3: rmw2(c, am_izy_w(c),        op_inc, op_sbc); break;

    /* immediate-ALU illegals */
    case 0x0B: case 0x2B:                                     /* ANC */
        c->a &= rd(c, am_imm(c)); setnz(c, c->a); setc(c, c->a & 0x80); break;
    case 0x4B: {                                              /* ALR = AND then LSR */
        uint8_t t = (uint8_t)(c->a & rd(c, am_imm(c)));
        setc(c, t & 1); c->a = (uint8_t)(t >> 1); setnz(c, c->a); break;
    }
    case 0x6B: {                                              /* ARR */
        uint8_t t = (uint8_t)(c->a & rd(c, am_imm(c)));
        uint8_t r = (uint8_t)((t >> 1) | ((c->p & XTF_C) ? 0x80 : 0));
        setnz(c, r);
        setv(c, ((r >> 6) ^ (r >> 5)) & 1);
        if (c->p & XTF_D) {
            /* decimal: flags come from the PRE-adjust value, A is nibble-fixed */
            uint8_t s = r;
            if (((t & 0x0f) + (t & 0x01)) > 5) s = (uint8_t)((s & 0xf0) | ((s + 6) & 0x0f));
            if ((((t >> 4) & 0x0f) + ((t >> 4) & 0x01)) > 5) { s = (uint8_t)(s + 0x60); setc(c, 1); }
            else setc(c, 0);
            c->a = s;
        } else {
            setc(c, (r >> 6) & 1);
            c->a = r;
        }
        break;
    }
    case 0x8B:                                                /* ANE/XAA (magic $EE) */
        c->a = (uint8_t)((c->a | 0xEE) & c->x & rd(c, am_imm(c))); setnz(c, c->a); break;
    case 0xAB:                                                /* LXA (magic $EE) */
        c->a = c->x = (uint8_t)((c->a | 0xEE) & rd(c, am_imm(c))); setnz(c, c->a); break;
    case 0xCB: {                                              /* SBX: X = (A&X) - imm */
        uint8_t t = (uint8_t)(c->a & c->x), m = rd(c, am_imm(c));
        c->x = (uint8_t)(t - m); setnz(c, c->x); setc(c, t >= m); break;
    }

    /* unstable stores */
    case 0x9F: ush(c, (uint8_t)(c->a & c->x), c->y, 0); break;   /* SHA abs,Y */
    case 0x9E: ush(c, c->x,                   c->y, 0); break;   /* SHX abs,Y */
    case 0x9C: ush(c, c->y,                   c->x, 0); break;   /* SHY abs,X */
    case 0x9B: ush(c, (uint8_t)(c->a & c->x), c->y, 1); break;   /* TAS abs,Y */
    case 0x93: ush_izy(c); break;                                /* SHA (zp),Y */
    case 0xBB:                                                   /* LAS abs,Y */
        ea = am_absi_r(c, c->y);
        c->a = c->x = c->s = (uint8_t)(rd(c, ea) & c->s);
        setnz(c, c->a);
        break;

    /* undocumented NOPs — the addressing cycles still happen */
    case 0x1A: case 0x3A: case 0x5A: case 0x7A: case 0xDA: case 0xFA:
        rd(c, c->pc); break;
    case 0x80: case 0x82: case 0x89: case 0xC2: case 0xE2:
        rd(c, am_imm(c)); break;
    case 0x04: case 0x44: case 0x64:
        rd(c, am_zp(c)); break;
    case 0x14: case 0x34: case 0x54: case 0x74: case 0xD4: case 0xF4:
        rd(c, am_zpx(c)); break;
    case 0x0C:
        rd(c, am_abs(c)); break;
    case 0x1C: case 0x3C: case 0x5C: case 0x7C: case 0xDC: case 0xFC:
        rd(c, am_absi_r(c, c->x)); break;

    /* KIL/JAM — the CPU stops fetching for good.  PC has already advanced past
     * the opcode and stays there; this second cycle reads the byte after it
     * without consuming it. */
    default:
        rd(c, c->pc);
        c->jammed = 1;
        c->jam_cnt = 0;
        c->jam_pc  = (uint16_t)(c->pc - 1);   /* pc advanced past the opcode */
        c->jam_op  = op;
        break;
    }
}
