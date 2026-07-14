/* input_udp.c — NETWORK INPUT: real mouse deltas over UDP, until the STM32 HID lands.
 *
 * The serial-terminal mouse is capped at ~12 motion reports/s by the emulator (measured,
 * 2026-07-14 — the whole render pipeline idles while the input starves). This listener is
 * the interim producer with none of that: a Mac-side capture app (gem/tools/xtmouse.c, SDL
 * relative-mouse mode) streams raw deltas at device rate, and this feeds the SAME kernel
 * input queue the serial decoder does — gemd, SYS_input, every consumer downstream is
 * untouched, and the console focus toggle is bypassed entirely (network events do not care
 * who owns the serial lane).
 *
 * Trust model: LAN-open, exactly like the TFTP drop and the netcon console beside it. The
 * STM32 makes all three of these transitional lanes retire together.
 *
 * Packet (8 bytes, LE), one per capture event, lossy-OK because deltas are small and
 * buttons carry full STATE (a lost packet skews the pointer a pixel, never a stuck button):
 *   u8  magic   'X'
 *   u8  buttons bit0 = left, bit1 = right, bit2 = middle  (STATE, not edges)
 *   s16 dx, dy  pointer delta
 *   s8  wheel   notches (+ = away/up)
 *   u8  pad
 */
#include <stdint.h>
#include "lwip/udp.h"
#include "lwip/tcpip.h"
#include "lwip/pbuf.h"
#include "xtsys.h"

#define INPUT_UDP_PORT 4242

extern void klog(const char *);
extern void cursor_move(int x, int y);
extern void cursor_pos(int *x, int *y);
extern int  xt_input_inject(const struct os_event *ev);   /* input_dev.c: the one queue */

static uint8_t s_btn;                 /* last button STATE seen from the wire */

static void in_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                    const ip_addr_t *addr, u16_t port)
{
    (void)arg; (void)pcb; (void)addr; (void)port;
    if (p->len >= 8) {
        const uint8_t *b = (const uint8_t *)p->payload;
        if (b[0] == 'X') {
            int16_t dx = (int16_t)(b[2] | (b[3] << 8));
            int16_t dy = (int16_t)(b[4] | (b[5] << 8));
            int8_t  wh = (int8_t)b[6];
            uint8_t bt = b[1];
            int x, y;
            cursor_pos(&x, &y);
            struct os_event ev;

            if (dx || dy) {
                x += dx; y += dy;
                if (x < 0) x = 0; if (x > 1919) x = 1919;
                if (y < 0) y = 0; if (y > 1079) y = 1079;
                cursor_move(x, y);                       /* HW sprite: free, tear-free */
                ev = (struct os_event){ OS_EV_MOTION, x, y, s_btn & 1, 0, 0, 0 };
                xt_input_inject(&ev);
            }
            if ((bt ^ s_btn) & 1) {                      /* left button edge */
                ev = (struct os_event){ (bt & 1) ? OS_EV_BTN_DOWN : OS_EV_BTN_UP,
                                        x, y, bt & 1, 0, 0, 0 };
                xt_input_inject(&ev);
            }
            s_btn = bt;
            if (wh) {
                ev = (struct os_event){ OS_EV_WHEEL, x, y, s_btn & 1, 0, 0, wh };
                xt_input_inject(&ev);
            }
        }
    }
    pbuf_free(p);
}

static void do_init(void *arg)
{
    (void)arg;
    struct udp_pcb *pcb = udp_new();
    if (!pcb || udp_bind(pcb, IP_ANY_TYPE, INPUT_UDP_PORT) != ERR_OK) {
        klog("[net] input_udp init failed\n");
        if (pcb) udp_remove(pcb);
        return;
    }
    udp_recv(pcb, in_recv, 0);
    klog("[net] input_udp listening (mouse over UDP :4242)\n");
}

void input_udp_init(void)
{
    tcpip_callback(do_init, 0);          /* raw-API init belongs in the lwIP thread */
}
