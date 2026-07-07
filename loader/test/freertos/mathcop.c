/* mathcop.c — math-coprocessor service: the A9 end of the mailbox in mathcop.h.
 *
 * The PL raises IRQ 62 when its doorbell event FIFO is non-empty (level).  The
 * ISR is integer-only (this port's vApplicationIRQHandler does not save VFP
 * state): it drains the FIFO into a small ring and notifies the worker task.
 * The worker (top priority, FPU-enabled via vPortTaskUsesFPU) interprets each
 * chunk's op program with native VFP + libm, writes results + STATUS into the
 * chunk, and pokes MATH_DONE so the PL reloads the result span into the math
 * page and raises $D5C7.0 for the 6502.
 *
 * The chunk stack (0x2080_0000) is a cacheable DMA buffer (mmu.c sections
 * 0x208/0x209, Normal WB-WA), so this file does PS<->PL cache maintenance around
 * the round-trip: INVALIDATE the chunk before reading (the PL just flushed fresh
 * operands into DDR) and CLEAN the result span to the point of coherency before
 * ringing MATH_DONE (else the PL reload reads stale DDR).  A bare `dsb` over a
 * non-cacheable chunk did NOT drain the A9's writes to DDR ahead of the PL read
 * (HW-confirmed: results came back as uninitialised DDR poison).  The interpreter
 * still works on a local copy (bulk op-word copy, per-slot demand load).
 */

#include <stdint.h>
#include <string.h>
#include <math.h>

#include "FreeRTOS.h"
#include "task.h"

#include "mathcop.h"

/* newlib libm's errno hook — the kernel links no libc reent, so give the
 * math wrappers one static cell (only the math-cop worker calls libm) */
int *__errno(void) { static int mc_errno; return &mc_errno; }

#define REG32(a)            (*(volatile uint32_t *)(a))
#define GICD_BASE           0xF8F01000UL
#define GICD_ISENABLER(n)   (*(volatile uint32_t *)(GICD_BASE + 0x100u + 4u * (n)))
#define GICD_ICENABLER(n)   (*(volatile uint32_t *)(GICD_BASE + 0x180u + 4u * (n)))
#define GICD_IPRIORITYR(id) (*(volatile uint8_t  *)(GICD_BASE + 0x400u + (id)))
#define GICD_ITARGETSR(id)  (*(volatile uint8_t  *)(GICD_BASE + 0x800u + (id)))

/* ---- PS<->PL DMA cache maintenance for the cacheable chunk buffer ----------
 * The chunk is Normal WB-WA cacheable (mmu.c 0x208/0x209).  L1 ops are to the
 * Point of Coherency (DDR): DCIMVAC invalidate, DCCMVAC clean — NOT the loader's
 * PoU-only mmu_sync_caches.  PL310 L2 is not enabled in this port, but its
 * CACHE_SYNC still drains the store-buffer pass-through, so we ring it after the
 * clean as cheap insurance.  All spans here are 8 KB / 64 B aligned, so the
 * line-granular loop never touches a neighbour. */
#define MC_CLINE 32u
#define L2CC_CACHE_SYNC     (*(volatile uint32_t *)0xF8F02730u)

static inline void mc_dcache_inval(const volatile void *p, uint32_t len)  /* discard stale, then read fresh DDR */
{
    uint32_t a = (uint32_t)p & ~(MC_CLINE - 1u);
    uint32_t e = ((uint32_t)p + len + MC_CLINE - 1u) & ~(MC_CLINE - 1u);
    for (; a < e; a += MC_CLINE) __asm__ volatile("mcr p15,0,%0,c7,c6,1" :: "r"(a) : "memory"); /* DCIMVAC */
    __asm__ volatile("dsb" ::: "memory");
}
static inline void mc_dcache_clean(const volatile void *p, uint32_t len)  /* push results to DDR */
{
    uint32_t a = (uint32_t)p & ~(MC_CLINE - 1u);
    uint32_t e = ((uint32_t)p + len + MC_CLINE - 1u) & ~(MC_CLINE - 1u);
    for (; a < e; a += MC_CLINE) __asm__ volatile("mcr p15,0,%0,c7,c10,1" :: "r"(a) : "memory"); /* DCCMVAC */
    __asm__ volatile("dsb" ::: "memory");
    L2CC_CACHE_SYNC = 0u;                                     /* drain PL310 store buffer */
    __asm__ volatile("dsb" ::: "memory");
}

/* ---- ISR -> worker ring (matches the PL FIFO depth) ---------------------- */
static volatile uint8_t mc_ring[16];
static volatile uint8_t mc_head, mc_tail;
static volatile uint8_t mc_irq_masked;
static TaskHandle_t     mc_task;

/* Integer-only: dispatched from vApplicationIRQHandler (zynq.c) on ID 62.
 * Each MATH_EVT read pops one event; the level IRQ drops once drained.  If
 * the ring is full (worker lagging), stop popping and MASK the IRQ — a level
 * interrupt with events left would re-fire forever — and let the worker
 * unmask after it drains. */
void mathcop_isr(void)
{
    BaseType_t woken = pdFALSE;
    while ((uint8_t)(mc_head - mc_tail) < 16u) {
        uint32_t evt = REG32(MC_GP0_EVT);
        if (!(evt & 0x100u)) goto notify;
        mc_ring[mc_head & 15u] = (uint8_t)evt;
        mc_head++;
    }
    mc_irq_masked = 1;
    GICD_ICENABLER(MC_GIC_IRQ_ID / 32u) = 1u << (MC_GIC_IRQ_ID % 32u);
notify:
    if (mc_task) vTaskNotifyGiveFromISR(mc_task, &woken);
    portYIELD_FROM_ISR(woken);
}

/* ---- interpreter state (single worker task -> statics are fine) ---------- */
typedef union { float f; double d; int32_t i; int64_t l; uint64_t u; } mcval_t;

static uint8_t  mc_slots[MC_NSLOTS * 8];        /* local copy of the slot file */
static uint32_t mc_ops[MC_MAX_OPS];             /* local copy of the program   */
static uint32_t mc_valid[MC_NSLOTS / 32];       /* slot loaded from the chunk  */
static uint32_t mc_dirty[MC_NSLOTS / 32];       /* slot must be written back   */

static inline int bit_get(const uint32_t *m, int i) { return (m[i >> 5] >> (i & 31)) & 1; }
static inline void bit_set(uint32_t *m, int i)      { m[i >> 5] |= 1u << (i & 31); }

/* demand-load slots [first..last] from the chunk (coalesces invalid runs) */
static void ensure_slots(const volatile uint8_t *page, int first, int last)
{
    for (int s = first; s <= last; ) {
        if (bit_get(mc_valid, s)) { s++; continue; }
        int e = s;
        while (e <= last && !bit_get(mc_valid, e)) { bit_set(mc_valid, e); e++; }
        memcpy(mc_slots + s * 8, (const uint8_t *)page + MC_OFF_SLOTS + s * 8,
               (size_t)(e - s) * 8);
        s = e;
    }
}

/* ---- element access (vector ops address the slot file as packed bytes) --- */
static int mc_esize(uint8_t type) { return (type == MC_T_F32 || type == MC_T_I32) ? 4 : 8; }

static int elem_off(int base_slot, int i, int stride, int esize, uint8_t *st)
{
    int off = base_slot * 8 + i * stride * esize;
    if (off < 0 || off + esize > MC_NSLOTS * 8) { *st |= MC_ST_RANGE; return -1; }
    return off;
}

static mcval_t load_elem(const volatile uint8_t *page, int off, int esize)
{
    mcval_t v; v.u = 0;
    ensure_slots(page, off >> 3, (off + esize - 1) >> 3);
    memcpy(&v, mc_slots + off, (size_t)esize);
    return v;
}

static void store_elem(const volatile uint8_t *page, int off, int esize, mcval_t v)
{
    /* a partial-slot store must not clobber the slot's other bytes on
     * writeback, so make sure the slot is populated first */
    ensure_slots(page, off >> 3, (off + esize - 1) >> 3);
    memcpy(mc_slots + off, &v, (size_t)esize);
    for (int s = off >> 3; s <= (off + esize - 1) >> 3; s++) bit_set(mc_dirty, s);
}

/* ---- scalar core: dst = op(a, b) in the given element type --------------- */
/* returns the result; flags accumulate into *st */
static mcval_t mc_scalar(uint8_t op, uint8_t type, mcval_t a, mcval_t b, uint8_t *st)
{
    mcval_t r; r.u = 0;
    int isf = (type == MC_T_F32 || type == MC_T_F64);

    /* CVT: type field = dest, b already holds the SOURCE value widened to
     * double/int64 by the caller — handled there, not here */

    if (isf) {
        double x = (type == MC_T_F32) ? (double)a.f : a.d;
        double y = (type == MC_T_F32) ? (double)b.f : b.d;
        double z;
        switch (op) {
        case MC_OP_NOP:   z = x; break;
        case MC_OP_ADD:   z = x + y; break;
        case MC_OP_SUB:   z = x - y; break;
        case MC_OP_MUL:   z = x * y; break;
        case MC_OP_DIV:   if (y == 0.0) *st |= MC_ST_DIV0; z = x / y; break;
        case MC_OP_NEG:   z = -x; break;
        case MC_OP_ABS:   z = fabs(x); break;
        case MC_OP_SQRT:  z = sqrt(x); break;
        case MC_OP_MIN:   z = (x < y) ? x : y; break;
        case MC_OP_MAX:   z = (x > y) ? x : y; break;
        case MC_OP_CMP:   r.i = (x < y) ? -1 : (x > y) ? 1 : 0; return r;
        case MC_OP_REM:   if (y == 0.0) *st |= MC_ST_DIV0; z = fmod(x, y); break;
        case MC_OP_SIN:   z = sin(x); break;
        case MC_OP_COS:   z = cos(x); break;
        case MC_OP_TAN:   z = tan(x); break;
        case MC_OP_ASIN:  z = asin(x); break;
        case MC_OP_ACOS:  z = acos(x); break;
        case MC_OP_ATAN:  z = atan(x); break;
        case MC_OP_ATAN2: z = atan2(x, y); break;
        case MC_OP_EXP:   z = exp(x); break;
        case MC_OP_LOG:   z = log(x); break;
        case MC_OP_LOG10: z = log10(x); break;
        case MC_OP_POW:   z = pow(x, y); break;
        case MC_OP_FLOOR: z = floor(x); break;
        case MC_OP_CEIL:  z = ceil(x); break;
        case MC_OP_ROUND: z = round(x); break;
        case MC_OP_TRUNC: z = trunc(x); break;
        default:          *st |= MC_ST_BADOP; z = 0.0; break;
        }
        if (isnan(z) || isinf(z)) *st |= MC_ST_INVALID;
        if (type == MC_T_F32) r.f = (float)z; else r.d = z;
        return r;
    }

    /* integer */
    {
        int64_t x = (type == MC_T_I32) ? (int64_t)a.i : a.l;
        int64_t y = (type == MC_T_I32) ? (int64_t)b.i : b.l;
        int64_t z;
        switch (op) {
        case MC_OP_NOP:  z = x; break;
        case MC_OP_ADD:  z = x + y; break;
        case MC_OP_SUB:  z = x - y; break;
        case MC_OP_MUL:  z = x * y; break;
        case MC_OP_DIV:  if (y == 0) { *st |= MC_ST_DIV0; z = 0; } else z = x / y; break;
        case MC_OP_NEG:  z = -x; break;
        case MC_OP_ABS:  z = (x < 0) ? -x : x; break;
        case MC_OP_MIN:  z = (x < y) ? x : y; break;
        case MC_OP_MAX:  z = (x > y) ? x : y; break;
        case MC_OP_CMP:  r.i = (x < y) ? -1 : (x > y) ? 1 : 0; return r;
        case MC_OP_REM:  if (y == 0) { *st |= MC_ST_DIV0; z = 0; } else z = x % y; break;
        case MC_OP_AND:  z = x & y; break;
        case MC_OP_OR:   z = x | y; break;
        case MC_OP_XOR:  z = x ^ y; break;
        case MC_OP_NOT:  z = ~x; break;
        case MC_OP_SHL:  z = x << (y & 63); break;
        case MC_OP_SHR:  z = (int64_t)((type == MC_T_I32 ? (uint64_t)(uint32_t)x
                                                         : (uint64_t)x) >> (y & 63)); break;
        case MC_OP_SAR:  z = x >> (y & 63); break;
        case MC_OP_SQRT: default: *st |= MC_ST_BADOP; z = 0; break;
        }
        if (type == MC_T_I32) r.i = (int32_t)z; else r.l = z;
        return r;
    }
}

/* widen a raw slot value of `type` to double (FP) or int64 for conversions */
static double  as_double(mcval_t v, uint8_t t)
{ return t == MC_T_F32 ? (double)v.f : t == MC_T_F64 ? v.d
       : t == MC_T_I32 ? (double)v.i : (double)v.l; }
static int64_t as_int64(mcval_t v, uint8_t t)
{ return t == MC_T_F32 ? (int64_t)v.f : t == MC_T_F64 ? (int64_t)v.d
       : t == MC_T_I32 ? (int64_t)v.i : v.l; }

static mcval_t mc_convert(uint8_t dst_t, uint8_t src_t, mcval_t v)
{
    mcval_t r; r.u = 0;
    switch (dst_t) {
    case MC_T_F32: r.f = (float)as_double(v, src_t);  break;
    case MC_T_F64: r.d = as_double(v, src_t);         break;
    case MC_T_I32: r.i = (int32_t)as_int64(v, src_t); break;
    default:       r.l = as_int64(v, src_t);          break;
    }
    return r;
}

/* map a vector opcode onto its scalar core op (VMLA/VCOPY/reductions/VCVT
 * are handled inline in the vector loop) */
static uint8_t vec_to_scalar(uint8_t vop)
{
    switch (vop) {
    case MC_OP_VADD:  return MC_OP_ADD;
    case MC_OP_VSUB:  return MC_OP_SUB;
    case MC_OP_VMUL:  return MC_OP_MUL;
    case MC_OP_VDIV:  return MC_OP_DIV;
    case MC_OP_VMIN:  return MC_OP_MIN;
    case MC_OP_VMAX:  return MC_OP_MAX;
    case MC_OP_VABS:  return MC_OP_ABS;
    case MC_OP_VNEG:  return MC_OP_NEG;
    case MC_OP_VSQRT: return MC_OP_SQRT;
    default:          return MC_OP_NOP;
    }
}

/* ---- run one chunk's program --------------------------------------------- */
static void mc_run_chunk(uint8_t chunk)
{
    volatile uint8_t *page =
        (volatile uint8_t *)(MC_CHUNK_BASE + (uint32_t)chunk * MC_CHUNK_SIZE);
    uint8_t st = 0;

    /* The PL flushed this chunk's fresh operands into DDR; drop any stale cached
     * copy from a prior run so the interpreter reads DDR, not L1. */
    mc_dcache_inval(page, MC_CHUNK_SIZE);

    unsigned op_count = page[MC_OFF_OPCOUNT] | ((unsigned)page[MC_OFF_OPCOUNT + 1] << 8);
    if (op_count > MC_MAX_OPS) { op_count = MC_MAX_OPS; st |= MC_ST_RANGE; }

    memcpy(mc_ops, (const uint8_t *)page + MC_OFF_OPS, op_count * 4);
    memset(mc_valid, 0, sizeof mc_valid);
    memset(mc_dirty, 0, sizeof mc_dirty);

    for (unsigned pc = 0; pc < op_count && !(st & (MC_ST_BADOP | MC_ST_RANGE)); pc++) {
        uint32_t w    = mc_ops[pc];
        uint8_t  op   = w & 0x3F;
        uint8_t  type = (w >> 6) & 3;
        uint8_t  s1   = (w >> 8)  & 0xFF;
        uint8_t  s2   = (w >> 16) & 0xFF;
        uint8_t  dst  = (w >> 24) & 0xFF;

        if (op < MC_OP_VECBASE) {
            /* ---- scalar ---- */
            mcval_t a, b, r;
            if (op == MC_OP_CVT) {
                uint8_t src_t = s2 & 3;
                a = load_elem(page, s1 * 8, mc_esize(src_t));
                r = mc_convert(type, src_t, a);
            } else {
                a = load_elem(page, s1 * 8, mc_esize(type));
                b = load_elem(page, s2 * 8, mc_esize(type));
                r = mc_scalar(op, type, a, b, &st);
            }
            store_elem(page, dst * 8, (op == MC_OP_CMP) ? 4 : mc_esize(type), r);
        } else {
            /* ---- vector: consume the second word ---- */
            if (op > MC_OP_VECTOP || pc + 1 >= op_count) { st |= MC_ST_BADOP; break; }
            uint32_t w1   = mc_ops[++pc];
            unsigned n    = w1 & 0xFF; if (n == 0) n = 256;
            int      st1  = (int8_t)(w1 >> 8);
            int      st2  = (int8_t)(w1 >> 16);
            int      stD  = (int8_t)(w1 >> 24);
            int      es   = mc_esize(type);
            uint8_t  sop  = vec_to_scalar(op);
            double   facc = 0.0;
            int64_t  iacc = 0;
            int      isf  = (type == MC_T_F32 || type == MC_T_F64);

            for (unsigned i = 0; i < n; i++) {
                int o1 = elem_off(s1, (int)i, st1, es, &st);
                if (o1 < 0) break;
                mcval_t a = load_elem(page, o1, es);
                mcval_t b; b.u = 0;
                mcval_t r;

                if (op == MC_OP_VCOPY) { r = a; }
                else if (op == MC_OP_VCVT) {
                    uint8_t src_t = s2 & 3;
                    int     ses   = mc_esize(src_t);
                    int o1s = elem_off(s1, (int)i, st1, ses, &st);
                    if (o1s < 0) break;
                    r = mc_convert(type, src_t, load_elem(page, o1s, ses));
                }
                else if (op == MC_OP_VSUM) {
                    if (isf) facc += as_double(a, type); else iacc += as_int64(a, type);
                    continue;
                }
                else if (op == MC_OP_VDOT || op == MC_OP_VMLA ||
                         (op != MC_OP_VABS && op != MC_OP_VNEG && op != MC_OP_VSQRT)) {
                    int o2 = elem_off(s2, (int)i, st2, es, &st);
                    if (o2 < 0) break;
                    b = load_elem(page, o2, es);
                    if (op == MC_OP_VDOT) {
                        if (isf) facc += as_double(a, type) * as_double(b, type);
                        else     iacc += as_int64(a, type) * as_int64(b, type);
                        continue;
                    }
                    if (op == MC_OP_VMLA) {
                        int oD = elem_off(dst, (int)i, stD, es, &st);
                        if (oD < 0) break;
                        mcval_t c = load_elem(page, oD, es);
                        mcval_t p = mc_scalar(MC_OP_MUL, type, a, b, &st);
                        r = mc_scalar(MC_OP_ADD, type, c, p, &st);
                        store_elem(page, oD, es, r);
                        continue;
                    }
                    r = mc_scalar(sop, type, a, b, &st);
                }
                else {
                    r = mc_scalar(sop, type, a, b, &st);   /* unary */
                }

                int oD = elem_off(dst, (int)i, stD, es, &st);
                if (oD < 0) break;
                store_elem(page, oD, es, r);
            }

            if (op == MC_OP_VDOT || op == MC_OP_VSUM) {
                mcval_t r; r.u = 0;
                switch (type) {
                case MC_T_F32: r.f = (float)facc; break;
                case MC_T_F64: r.d = facc;        break;
                case MC_T_I32: r.i = (int32_t)iacc; break;
                default:       r.l = iacc;        break;
                }
                if (isf && (isnan(facc) || isinf(facc))) st |= MC_ST_INVALID;
                store_elem(page, dst * 8, es, r);
            }
        }
    }

    if (!(st & (MC_ST_BADOP | MC_ST_RANGE))) st |= MC_ST_OK;

    /* write back: dirty slots (coalesced runs) + the status byte */
    int max_slot = -1;
    for (int s = 0; s < MC_NSLOTS; ) {
        if (!bit_get(mc_dirty, s)) { s++; continue; }
        int e = s;
        while (e < MC_NSLOTS && bit_get(mc_dirty, e)) e++;
        memcpy((uint8_t *)page + MC_OFF_SLOTS + s * 8, mc_slots + s * 8,
               (size_t)(e - s) * 8);
        max_slot = e - 1;
        s = e;
    }
    page[MC_OFF_STATUS] = st;

    /* result span: line 0 (header/status) .. last dirty slot's line */
    unsigned last_line = 0;
    if (max_slot >= 0)
        last_line = (unsigned)(MC_OFF_SLOTS + max_slot * 8 + 7) >> 6;

    /* Clean the result span to DDR so the PL reload reads the A9's writes, not
     * stale memory — this is the release barrier the doorbell relies on. */
    mc_dcache_clean(page, (last_line + 1u) * 64u);
    REG32(MC_GP0_DONE) = ((last_line + 1u) << 16) | (0u << 8) | chunk;
}

/* ---- worker task ---------------------------------------------------------- */
static void mc_worker(void *arg)
{
    (void)arg;
    vPortTaskUsesFPU();                    /* VFP context for this task */
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        while (mc_tail != mc_head) {
            mc_run_chunk(mc_ring[mc_tail & 15u]);
            mc_tail++;
        }
        if (mc_irq_masked) {           /* ring was full: resume the level IRQ */
            mc_irq_masked = 0;
            GICD_ISENABLER(MC_GIC_IRQ_ID / 32u) = 1u << (MC_GIC_IRQ_ID % 32u);
        }
    }
}

void mathcop_init(void)
{
    GICD_IPRIORITYR(MC_GIC_IRQ_ID) = 0xA0;   /* same band as the tick: API-callable ISR */
    GICD_ITARGETSR(MC_GIC_IRQ_ID)  = 0x01;   /* deliver to CPU0 */
    GICD_ISENABLER(MC_GIC_IRQ_ID / 32u) = 1u << (MC_GIC_IRQ_ID % 32u);

    /* math work is µs-scale per doorbell and the 6502 spins on $D5C7 —
     * highest priority so a doorbell never queues behind bulk work */
    xTaskCreate(mc_worker, "mathcop", 1024, NULL, configMAX_PRIORITIES - 1, &mc_task);
}
