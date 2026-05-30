// peri_sio.c — SIO bus C-side state machine.

#include "peri_sio.h"

#include <string.h>

#include "peri_regs.h"
#include "peri_irq.h"

// ---- Internal queues (lock-free SPSC ring buffers) ------------------
// Production: the PIO program is the producer (RX) / consumer (TX);
// the C side is the other end. Single-element-headroom convention so
// a zero-length-empty / size-equals-mask-full distinction is trivial.
typedef struct {
    uint8_t  buf[PERI_SIO_RX_QUEUE_SIZE];
    uint8_t  head;
    uint8_t  tail;
} sio_rx_q_t;

typedef struct {
    uint8_t  buf[PERI_SIO_TX_QUEUE_SIZE];
    uint8_t  head;
    uint8_t  tail;
} sio_tx_q_t;

static sio_rx_q_t g_rx;
static sio_tx_q_t g_tx;

// SIO_STAT bit layout (must match peri_bridge.sv's SIO_STAT_*_BIT
// localparams).
#define SIO_STAT_FRAMING_BIT   (1u << 0)
#define SIO_STAT_OVERRUN_BIT   (1u << 1)
#define SIO_STAT_BUSY_BIT      (1u << 2)
#define SIO_STAT_BREAK_BIT     (1u << 3)

static uint8_t g_stat;
static bool    g_break_seen;

// ---- Helpers --------------------------------------------------------

static inline bool rx_empty(void)    { return g_rx.head == g_rx.tail; }
static inline bool rx_full(void) {
    return ((g_rx.tail + 1u) % PERI_SIO_RX_QUEUE_SIZE) == g_rx.head;
}
__attribute__((unused))
static inline size_t rx_len(void) {
    return (g_rx.tail + PERI_SIO_RX_QUEUE_SIZE - g_rx.head)
        % PERI_SIO_RX_QUEUE_SIZE;
}

static inline bool tx_empty(void)    { return g_tx.head == g_tx.tail; }
static inline bool tx_full(void) {
    return ((g_tx.tail + 1u) % PERI_SIO_TX_QUEUE_SIZE) == g_tx.head;
}
static inline size_t tx_len(void) {
    return (g_tx.tail + PERI_SIO_TX_QUEUE_SIZE - g_tx.head)
        % PERI_SIO_TX_QUEUE_SIZE;
}

static void rx_push(uint8_t byte) {
    if (rx_full()) {
        g_stat |= SIO_STAT_OVERRUN_BIT;
        return;
    }
    g_rx.buf[g_rx.tail] = byte;
    g_rx.tail = (g_rx.tail + 1u) % PERI_SIO_RX_QUEUE_SIZE;
}

static uint8_t rx_pop(void) {
    if (rx_empty()) return 0;
    uint8_t v = g_rx.buf[g_rx.head];
    g_rx.head = (g_rx.head + 1u) % PERI_SIO_RX_QUEUE_SIZE;
    return v;
}

static void update_status_after_rx_change(void) {
    uint8_t status = peri_regs_get(PERI_R_STATUS);
    if (rx_empty()) {
        status &= ~PERI_STATUS_SIO_RX;
    } else {
        status |= PERI_STATUS_SIO_RX;
    }
    peri_regs_set(PERI_R_STATUS, status);
    peri_irq_update();

    // Surface flags that ride alongside SIO_RX so the bridge sees
    // them on its read of SIO_STAT.
    uint8_t stat = g_stat;
    if (g_break_seen) stat |= SIO_STAT_BREAK_BIT;
    if (!tx_empty())  stat |= SIO_STAT_BUSY_BIT;
    peri_regs_set(PERI_R_SIO_STAT, stat);
}

// ---- Public API -----------------------------------------------------

void peri_sio_init(void) {
    memset(&g_rx, 0, sizeof(g_rx));
    memset(&g_tx, 0, sizeof(g_tx));
    g_stat       = 0;
    g_break_seen = false;
    peri_regs_set(PERI_R_SIO_IN,   0);
    peri_regs_set(PERI_R_SIO_STAT, 0);
}

void peri_sio_handle_sio_out_write(uint8_t byte) {
    if (tx_full()) {
        // Drop on full (no flag for it today — SIO_STAT.OVERRUN is
        // RX-only). M25-4-followup may add a TX-overflow flag if
        // real software runs into this.
        return;
    }
    g_tx.buf[g_tx.tail] = byte;
    g_tx.tail = (g_tx.tail + 1u) % PERI_SIO_TX_QUEUE_SIZE;
    update_status_after_rx_change();    // refresh SIO_STAT.busy bit
}

uint8_t peri_sio_handle_sio_in_read(void) {
    uint8_t byte = rx_pop();
    update_status_after_rx_change();
    return byte;
}

bool peri_sio_service(void) {
    // Production: PIO ISR pumps RX queue + drains TX queue. Host sim
    // path is a no-op since events are injected directly. Either way,
    // recompute SIO_STAT.busy to reflect TX queue state.
    bool changed = false;
    uint8_t stat = peri_regs_get(PERI_R_SIO_STAT);
    uint8_t fresh = g_stat;
    if (g_break_seen) fresh |= SIO_STAT_BREAK_BIT;
    if (!tx_empty())  fresh |= SIO_STAT_BUSY_BIT;
    if (fresh != stat) {
        peri_regs_set(PERI_R_SIO_STAT, fresh);
        changed = true;
    }
    return changed;
}

#ifdef PERI_POT_HOST_SIM
void peri_sio_inject_rx(uint8_t byte) {
    rx_push(byte);
    peri_regs_set(PERI_R_SIO_IN, byte);   // first byte rides this slot
                                          // (bridge's read drains it)
    update_status_after_rx_change();
}

void peri_sio_inject_break(void)        { g_break_seen = true;
                                          update_status_after_rx_change(); }
void peri_sio_inject_framing_err(void)  { g_stat |= SIO_STAT_FRAMING_BIT;
                                          update_status_after_rx_change(); }
void peri_sio_inject_overrun(void)      { g_stat |= SIO_STAT_OVERRUN_BIT;
                                          update_status_after_rx_change(); }

size_t peri_sio_tx_queue_len(void) { return tx_len(); }
uint8_t peri_sio_tx_queue_pop(void) {
    if (tx_empty()) return 0;
    uint8_t v = g_tx.buf[g_tx.head];
    g_tx.head = (g_tx.head + 1u) % PERI_SIO_TX_QUEUE_SIZE;
    return v;
}
#endif
