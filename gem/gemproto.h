/*
 * gemproto.h — the gemd wire protocol. Shared by the server half (gem/gemd/) and the
 * client half (gem/gemclient.c); it is the ONLY thing the two agree on.
 *
 * Spec: Rocks/doc/RESPONSIBILITIES.md §3-§14; plan: docs/OS/gemd-plan.md.
 *
 * A message is a FIXED 32-byte record — AES-message shaped (16-bit words), plus four
 * 32-bit fields for the things that must not be 16 bits (ids, generations, sequence
 * numbers). Fixed size means a byte-stream channel needs no framing: a reader accumulates
 * until it has 32 bytes and dispatches. There is no length field to disagree about, and a
 * malformed sender cannot desynchronise the stream by lying about a length.
 *
 * THE THREE THAT MUST BE RIGHT ON DAY ONE (§14 — each is a protocol break if added later):
 *
 *   1. DAMAGE carries `retire_seq` FROM THE FIRST COMMIT. It is DEAD in phase 1 (drawing is
 *      synchronous: "I posted damage" really does mean "my pixels are in memory") and the
 *      client always sends 0. In phase 2 the blitter is a QUEUE and that is false — gemd
 *      holds priority and can composite a window whose draws have not retired. The field is
 *      the fence. Omitting it now costs a protocol change across every client later.
 *   2. A surface is named by `surf_id` (a u32 handle) EVERYWHERE, NEVER by an address. Phase
 *      2 then changes only the allocator behind the id, not the wire.
 *   3. A surface's STRIDE IS ITS CAPACITY WIDTH, not its extent width — so WIND_CREATED
 *      returns cap_w/cap_h and the client draws into the TOP-LEFT extent sub-rect. If stride
 *      tracked the visible width, growing a window by one pixel would move every row.
 */
#ifndef GEM_PROTO_H
#define GEM_PROTO_H

#include <stdint.h>

#define GEM_SERVICE  "gem"          /* SYS_svc_register / SYS_svc_connect */

/* client -> gemd */
#define GEM_WIND_CREATE   1         /* w[1]=kind w[2]=x w[3]=y w[4]=w w[5]=h (FULL rect) */
#define GEM_DAMAGE        3         /* see below */
#define GEM_SURF_DROP     4         /* u[0]=surf_id: the client has unmapped it (§11) */
#define GEM_WIND_OPEN     6         /* w[1]=wh w[2..5]=x,y,w,h -> WIND_SURF + MSG_REDRAW */
#define GEM_WIND_CLOSE    7         /* w[1]=wh */
#define GEM_WIND_DELETE   8         /* w[1]=wh */
#define GEM_WIND_NAME     9         /* w[1]=wh, then GEM_NAME_MAX bytes of NUL-terminated name */

/* gemd -> client */
#define GEM_WIND_CREATED  2         /* w[1]=wh  (no surface yet: geometry is not final until OPEN) */
#define GEM_WIND_ERROR    5         /* w[1]=reason (out of windows / surfaces / bad request) */
#define GEM_WIND_SURF    10         /* w[1]=wh w[2]=work_w w[3]=work_h w[4]=cap_w w[5]=cap_h
                                     * u[0]=surf_id u[1]=surf_gen
                                     * The backing store is the WORK AREA, not the full window:
                                     * chrome is gemd's (§3) and a client never sees it. */
#define GEM_MSG_REDRAW   11         /* w[1]=wh w[2..5]=x,y,w,h (SURFACE coords).
                                     * §3: sent for FIRST PAINT and RESIZE ONLY — never for
                                     * occlusion, moves or topping, because gemd already holds
                                     * those pixels. WM_REDRAW nearly disappearing is the whole
                                     * point of the per-window backing store. */

/* ---- input (M4) — gemd -> client -------------------------------------------------------
 * gemd owns the pointer, hit-tests the z-order, and sends an event to exactly ONE client: the
 * focused one. A client is never told where it is on screen, so coordinates are WINDOW-LOCAL —
 * the same space its content callback draws in (0,0 = the top-left of its work area / surface).
 * The client cannot even express a question about another window, which is the point (§2).
 *
 * Chrome events never reach a client: a click on the closer, the title bar or the sizer is
 * gemd's, and the client hears only the CONSEQUENCE (MSG_CLOSED, MSG_MOVED, MSG_SIZED). */
#define GEM_EV_KEY       12         /* w[1]=wh w[2]=key w[3]=shift */
#define GEM_EV_BUTTON    13         /* w[1]=wh w[2]=x w[3]=y w[4]=button (0 = release) w[5]=shift */
#define GEM_EV_MOTION    14         /* w[1]=wh w[2]=x w[3]=y w[4]=button (buttons held) */

#define GEM_MSG_CLOSED   15         /* w[1]=wh — the CLOSER was clicked. gemd does NOT close the
                                     * window: closing is the app's decision (it may want to ask
                                     * "save?"). The app calls wind_close when it agrees. */
#define GEM_MSG_MOVED    16         /* w[1]=wh w[2..5]=x,y,w,h — NO redraw implied: gemd already
                                     * has the pixels and moved them itself (§3). */
#define GEM_MSG_SIZED    17         /* w[1]=wh w[2]=work_w w[3]=work_h w[4]=cap_w w[5]=cap_h
                                     * u[0]=surf_id u[1]=surf_gen
                                     * SAME surf_id  => the resize fitted inside the capacity:
                                     *                  nothing to remap, just draw a bigger
                                     *                  sub-rect of the SAME buffer (§12).
                                     * NEW surf_id   => capacity was exceeded; the old surface is
                                     *                  dropped and this one is granted instead. */
#define GEM_MSG_ACTIVATE 18         /* w[1]=wh w[2]=1 focused / 0 lost focus */

/* A window name has to fit the fixed 32-byte record: op + wh + 28 bytes. Titles are short, and
 * a variable-length message would buy 200 bytes of title at the cost of a framing rule that a
 * malformed sender could desynchronise. Truncated, deliberately. */
#define GEM_NAME_MAX 27             /* + the NUL */

/* Window kind bits (a mask, as in wind_create) — M1 defines only the one it honours. */
#define GEM_W_BOTTOM  0x0001        /* insert at the BOTTOM of the z-order, never topped (§4) */

/*
 * DAMAGE — client -> gemd:
 *   w[1] = wh              window handle (0 = the menu strip, once §10 lands)
 *   w[2..5] = x,y,w,h      SURFACE coordinates. gemd CLAMPS them (§9): a client's damage
 *                          rect is a request, not an instruction.
 *   u[0] = surf_id         the handle it drew into — never an address (§13.1)
 *   u[1] = surf_gen        gemd discards damage posted against a stale surface (§11)
 *   u[2] = retire_seq      §14: DEAD IN PHASE 1. The client sends 0. DO NOT OMIT.
 */
typedef struct {
    int16_t  w[8];
    uint32_t u[4];
} gem_msg;                          /* exactly 32 bytes on every target we build for */

#define GEM_MSG_SZ ((int)sizeof(gem_msg))

/* Capacity quantum (§12): capacity is the extent rounded up to a 64px grid and capped at
 * the screen, so a small resize costs no realloc, no remap and no new id. It also means
 * cap_w != w for almost every window — which is exactly what keeps the stride rule (3,
 * above) honest instead of accidentally true. */
#define GEM_CAP_QUANTUM 64

#endif /* GEM_PROTO_H */
