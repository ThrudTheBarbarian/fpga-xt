/* xemacpsif.c — the lwIP netif over the Zynq PS GEM0 (vendored xemacps
 * driver), POLLED (no GEM interrupt — a 1 ms poll task drains RX and reclaims
 * TX; ample for the phase-1 file drop, and there's no ISR integration to
 * debug on first bring-up).
 *
 * DMA coherence by construction: the BD rings and all packet buffers live in
 * a carve of the PL-shared window (NET_DMA_BASE, mapped Normal NON-cacheable
 * by mmu.c) — the CPU and the GEM's AHB master see the same bytes with no
 * cache maintenance at all. Frames are copied pbuf<->carve; at file-drop
 * rates the copies are noise.
 *
 * PHY: MDIO scan finds the address (Z-Turn: KSZ9031, but any IEEE PHY works);
 * autonegotiation resolves the speed, then the SLCR GEM0 clock divisors and
 * the MAC speed bits follow (125/25/2.5 MHz for 1000/100/10).
 */
#include "lwip/netif.h"
#include "lwip/etharp.h"
#include "lwip/pbuf.h"
#include "netif/ethernet.h"
#include "xemacps.h"

extern void puts0(const char *);
extern void putu(unsigned);

#define NET_DMA_BASE  0x3F000000u          /* 1 MB inside the non-cacheable window */
#define RXBD_CNT      32
#define TXBD_CNT      16
#define BUF_SZ        1664                 /* max frame, 64-aligned */

#define RXBD_SPACE  (NET_DMA_BASE + 0x0000u)
#define TXBD_SPACE  (NET_DMA_BASE + 0x1000u)
#define RX_BUFS     (NET_DMA_BASE + 0x2000u)
#define TX_BUFS     (NET_DMA_BASE + 0x2000u + RXBD_CNT * BUF_SZ)

static XEmacPs g_emac;
static int     g_phy = -1;
static int     g_link_speed;               /* 0 = no link */

/* ---- SLCR GEM0 clock (divisors per negotiated speed) ----------------------- */
static void gem0_clk_divs(int d0, int d1)
{
    volatile uint32_t *slcr = (volatile uint32_t *)0xF8000000u;
    slcr[0x008 / 4] = 0xDF0Du;                              /* unlock */
    uint32_t v = slcr[0x140 / 4];                           /* GEM0_CLK_CTRL */
    v = (v & ~0x03F03F00u) | ((uint32_t)(d0 & 0x3F) << 8) | ((uint32_t)(d1 & 0x3F) << 20);
    slcr[0x140 / 4] = v;
    slcr[0x004 / 4] = 0x767Bu;                              /* relock */
}

/* ---- PHY ------------------------------------------------------------------- */
static int phy_find(void)
{
    for (int a = 0; a < 32; a++) {
        u16 id = 0xFFFF;
        if (XEmacPs_PhyRead(&g_emac, (u32)a, 2, &id) != XST_SUCCESS) continue;
        if (id != 0xFFFFu && id != 0x0000u) return a;
    }
    return -1;
}

/* start autoneg (advertise everything); non-blocking — the poll task watches
 * for completion via phy_link_speed() */
static void phy_start(void)
{
    u16 v;
    XEmacPs_PhyRead(&g_emac, (u32)g_phy, 4, &v);
    XEmacPs_PhyWrite(&g_emac, (u32)g_phy, 4, (u16)(v | 0x01E0u));   /* ADV 100FD/HD 10FD/HD */
    XEmacPs_PhyRead(&g_emac, (u32)g_phy, 9, &v);
    XEmacPs_PhyWrite(&g_emac, (u32)g_phy, 9, (u16)(v | 0x0300u));   /* ADV 1000FD/HD */
    XEmacPs_PhyWrite(&g_emac, (u32)g_phy, 0, 0x1340u);              /* 1000FD + ANEG + restart */
}

/* 0 = no link yet; else the resolved speed (10/100/1000) */
static int phy_link_speed(void)
{
    u16 bmsr = 0;
    XEmacPs_PhyRead(&g_emac, (u32)g_phy, 1, &bmsr);
    XEmacPs_PhyRead(&g_emac, (u32)g_phy, 1, &bmsr);        /* latched: read twice */
    if (!(bmsr & 0x0004u)) return 0;                       /* no link */
    if (!(bmsr & 0x0020u)) return 0;                       /* autoneg not complete */
    u16 gbsr = 0, anlpar = 0, anar = 0;
    XEmacPs_PhyRead(&g_emac, (u32)g_phy, 10, &gbsr);       /* 1000BASE-T status */
    if (gbsr & 0x0C00u) return 1000;                       /* LP 1000 FD/HD */
    XEmacPs_PhyRead(&g_emac, (u32)g_phy, 5, &anlpar);
    XEmacPs_PhyRead(&g_emac, (u32)g_phy, 4, &anar);
    u16 common = (u16)(anar & anlpar);
    if (common & 0x0180u) return 100;                      /* 100FD/HD */
    return 10;
}

/* ---- BD rings --------------------------------------------------------------- */
static void rx_arm_bd(XEmacPs_Bd *bd, u32 buf)
{
    /* SetAddressRx PRESERVES the low addr bits — the new/used bit must be
     * cleared explicitly or the GEM's completed BD replays the same frame to
     * FromHwRx forever (HW-found: an infinite loop of the last RRQ) */
    XEmacPs_BdSetAddressRx(bd, buf);
    XEmacPs_BdClearRxNew(bd);
    XEmacPs_BdSetStatus(bd, 0);
}

static int rings_init(void)
{
    XEmacPs_BdRing *rx = &XEmacPs_GetRxRing(&g_emac);
    XEmacPs_BdRing *tx = &XEmacPs_GetTxRing(&g_emac);
    XEmacPs_Bd tmpl;

    XEmacPs_BdClear(&tmpl);
    if (XEmacPs_BdRingCreate(rx, RXBD_SPACE, RXBD_SPACE, XEMACPS_BD_ALIGNMENT, RXBD_CNT) != XST_SUCCESS) return -1;
    if (XEmacPs_BdRingClone(rx, &tmpl, XEMACPS_RECV) != XST_SUCCESS) return -1;

    XEmacPs_BdClear(&tmpl);
    XEmacPs_BdSetStatus(&tmpl, XEMACPS_TXBUF_USED_MASK);
    if (XEmacPs_BdRingCreate(tx, TXBD_SPACE, TXBD_SPACE, XEMACPS_BD_ALIGNMENT, TXBD_CNT) != XST_SUCCESS) return -1;
    if (XEmacPs_BdRingClone(tx, &tmpl, XEMACPS_SEND) != XST_SUCCESS) return -1;

    /* pre-arm every RX BD with its buffer */
    XEmacPs_Bd *bd;
    if (XEmacPs_BdRingAlloc(rx, RXBD_CNT, &bd) != XST_SUCCESS) return -1;
    XEmacPs_Bd *b = bd;
    for (int i = 0; i < RXBD_CNT; i++) {
        rx_arm_bd(b, RX_BUFS + (u32)i * BUF_SZ);
        b = XEmacPs_BdRingNext(rx, b);
    }
    if (XEmacPs_BdRingToHw(rx, RXBD_CNT, bd) != XST_SUCCESS) return -1;

    XEmacPs_SetQueuePtr(&g_emac, rx->BaseBdAddr, 0, (u16)XEMACPS_RECV);
    XEmacPs_SetQueuePtr(&g_emac, tx->BaseBdAddr, 0, (u16)XEMACPS_SEND);

    /* DMACR resets with RX buffer size 0 — the DMA must be told our buffers
     * are 1600 B (25 * 64), and to use the full packet-buffer SRAM + INCR16
     * bursts (the values the Xilinx port programs) */
    XEmacPs_WriteReg(g_emac.Config.BaseAddress, XEMACPS_DMACR_OFFSET,
                     ((BUF_SZ / 64) << XEMACPS_DMACR_RXBUF_SHIFT) |
                     XEMACPS_DMACR_TXSIZE_MASK | XEMACPS_DMACR_RXSIZE_MASK |
                     XEMACPS_DMACR_INCR16_AHB_BURST);
    return 0;
}

/* ---- lwIP glue --------------------------------------------------------------- */
static err_t low_level_output(struct netif *nif, struct pbuf *p)
{
    (void)nif;
    XEmacPs_BdRing *tx = &XEmacPs_GetTxRing(&g_emac);

    /* reclaim everything the MAC has finished with */
    XEmacPs_Bd *done;
    u32 n = XEmacPs_BdRingFromHwTx(tx, TXBD_CNT, &done);
    if (n) XEmacPs_BdRingFree(tx, n, done);

    if (p->tot_len > BUF_SZ) return ERR_MEM;
    XEmacPs_Bd *bd;
    if (XEmacPs_BdRingAlloc(tx, 1, &bd) != XST_SUCCESS) return ERR_MEM;

    /* slot index from the BD position -> a stable per-BD buffer */
    u32 idx = ((u32)(UINTPTR)bd - TXBD_SPACE) / (u32)tx->Separation;
    u32 buf = TX_BUFS + idx * BUF_SZ;
    pbuf_copy_partial(p, (void *)(UINTPTR)buf, p->tot_len, 0);

    XEmacPs_BdSetAddressTx(bd, buf);
    XEmacPs_BdSetLength(bd, p->tot_len);
    XEmacPs_BdClearTxUsed(bd);
    XEmacPs_BdSetLast(bd);
    if (XEmacPs_BdRingToHw(tx, 1, bd) != XST_SUCCESS) { XEmacPs_BdRingUnAlloc(tx, 1, bd); return ERR_MEM; }
    XEmacPs_Transmit(&g_emac);
    return ERR_OK;
}

/* drain received frames into lwIP (called from the poll task; netif->input is
 * tcpip_input, which posts to the lwIP thread — safe from here) */
int xemacpsif_poll(struct netif *nif)
{
    XEmacPs_BdRing *rx = &XEmacPs_GetRxRing(&g_emac);
    XEmacPs_Bd *bd;
    int got = 0;
    u32 n;
    while ((n = XEmacPs_BdRingFromHwRx(rx, 4, &bd)) > 0) {
        XEmacPs_Bd *b = bd;
        for (u32 i = 0; i < n; i++) {
            u32 buf = (u32)XEmacPs_BdGetBufAddr(b) & ~0x3u;
            u32 len = XEmacPs_BdGetLength(b);
            if (len && len <= BUF_SZ) {
                struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
                if (p) {
                    pbuf_take(p, (const void *)(UINTPTR)buf, (u16_t)len);
                    if (nif->input(p, nif) != ERR_OK) pbuf_free(p);
                    got++;
                }
            }
            b = XEmacPs_BdRingNext(rx, b);
        }
        /* recycle the BDs (same buffers re-armed in ring order) */
        XEmacPs_BdRingFree(rx, n, bd);
        XEmacPs_Bd *fresh;
        if (XEmacPs_BdRingAlloc(rx, n, &fresh) == XST_SUCCESS) {
            XEmacPs_Bd *f = fresh;
            for (u32 i = 0; i < n; i++) {
                u32 idx = ((u32)(UINTPTR)f - RXBD_SPACE) / (u32)rx->Separation;
                rx_arm_bd(f, RX_BUFS + idx * BUF_SZ);
                f = XEmacPs_BdRingNext(rx, f);
            }
            XEmacPs_BdRingToHw(rx, n, fresh);
        }
    }
    /* clear latched RX status (buffer-not-available etc.) so reception continues */
    XEmacPs_WriteReg(g_emac.Config.BaseAddress, XEMACPS_RXSR_OFFSET,
                     XEmacPs_ReadReg(g_emac.Config.BaseAddress, XEMACPS_RXSR_OFFSET));
    return got;
}

/* watch the link; on first link-up program the MAC + SLCR for the speed.
 * Returns the speed when newly up, 0 otherwise. */
int xemacpsif_link_poll(void)
{
    if (g_phy < 0) return 0;
    int sp = phy_link_speed();
    if (sp == g_link_speed) return 0;
    g_link_speed = sp;
    if (!sp) return 0;
    XEmacPs_Config *c = g_emac.Config.BaseAddress ? &g_emac.Config : 0;
    if (sp == 1000)     gem0_clk_divs(c->S1GDiv0,   c->S1GDiv1);
    else if (sp == 100) gem0_clk_divs(c->S100MDiv0, c->S100MDiv1);
    else                gem0_clk_divs(c->S10MDiv0,  c->S10MDiv1);
    XEmacPs_SetOperatingSpeed(&g_emac, (u16)sp);
    return sp;
}

err_t xemacpsif_init(struct netif *nif)
{
    XEmacPs_Config *cfg = XEmacPs_LookupConfig(0);
    if (!cfg || XEmacPs_CfgInitialize(&g_emac, cfg, cfg->BaseAddress) != XST_SUCCESS)
        return ERR_IF;

    unsigned char mac[6] = { 0x02, 0x78, 0x74, 0x6F, 0x73, 0x01 };   /* locally administered, "xtos" */
    XEmacPs_SetMacAddress(&g_emac, mac, 1);
    XEmacPs_SetMdioDivisor(&g_emac, MDC_DIV_224);
    XEmacPs_SetOptions(&g_emac, XEMACPS_FCS_STRIP_OPTION | XEMACPS_BROADCAST_OPTION);

    if (rings_init() != 0) return ERR_IF;

    g_phy = phy_find();
    if (g_phy >= 0) phy_start();
    else puts0("[net] no PHY found on MDIO\n");

    /* provisional speed: 100 until the link resolves (qemu's model reports
     * link+aneg immediately, HW in a second or two) */
    XEmacPs_SetOperatingSpeed(&g_emac, 100);
    XEmacPs_Start(&g_emac);

    nif->name[0] = 'e'; nif->name[1] = '0';
    nif->output     = etharp_output;
    nif->linkoutput = low_level_output;
    nif->mtu        = 1500;
    nif->hwaddr_len = 6;
    memcpy(nif->hwaddr, mac, 6);
    nif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_LINK_UP;
    return ERR_OK;
}
