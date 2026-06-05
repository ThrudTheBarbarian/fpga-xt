// vdi/getoutline.c — v_getoutline / v_get_outline (243): a character's outline
// as a Bézier path (the v_bez point/flag format, so it round-trips through
// v_bez / v_bez_fill).  v_killoutline (242) frees an outline — a no-op here
// since we write into the caller's arrays.  v_flushcache (251) drops the
// rasterised glyph cache.
//
// The character is passed in intin[0]; xyarr/bezarr come back out-of-band (like
// the cpyfm MFDBs) since they don't fit the WORD param block: the binding hands
// the op pointers via globals and reads the count from intout[0].

#include "vdi/vdi.h"
#include "vdi/internal.h"

int16_t *g_outline_xy;          // out-of-band outline buffers (caller-owned)
uint8_t *g_outline_bez;
int      g_outline_max;

void op_getoutline(vdi_pb *pb) {
    pb->intout[0] = 0;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f || !g_outline_xy || !g_outline_bez) return;
    pb->intout[0] = (int16_t)font_get_outline(f, (unsigned)(pb->intin[0] & 0xFFFF),
                                              g_outline_xy, g_outline_bez, g_outline_max);
}

void op_killoutline(vdi_pb *pb) { (void)pb; }           // nothing to free

void op_flushcache(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font_face *face = w->text_face ? w->text_face : g_default_face;
    font_face_flush(face);
}

// Fills xy[] (point pairs) and bez[] (flags) for `ch`; returns the point count.
static int getoutline(int handle, int ch, int16_t *xy, uint8_t *bez, int maxpts) {
    g_outline_xy = xy; g_outline_bez = bez; g_outline_max = maxpts;
    g_intin[0] = (int16_t)ch;
    vdi_emit(VDI_GETOUTLINE, 0, handle, 0, 1);
    g_outline_xy = 0; g_outline_bez = 0;
    return g_intout[0];
}
int v_getoutline(int handle, int ch, int16_t *xy, uint8_t *bez, int maxpts) {
    return getoutline(handle, ch, xy, bez, maxpts);
}
int v_get_outline(int handle, int ch, int16_t *xy, uint8_t *bez, int maxpts) {
    return getoutline(handle, ch, xy, bez, maxpts);     // "improved" variant — same here
}
void v_killoutline(int handle) { vdi_emit(VDI_KILLOUTLINE, 0, handle, 0, 0); }
void v_flushcache(int handle)  { vdi_emit(VDI_FLUSHCACHE, 0, handle, 0, 0); }
