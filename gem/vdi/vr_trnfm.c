// vdi/vr_trnfm.c — vr_trnfm: convert a form between standard and device format.
// Standard is device-independent planar (nplanes word-interleaved bit planes,
// MSB = leftmost pixel); our device-native form is RGBA-8888 chunky, so this is
// a real planar<->chunky conversion (NOT identity).  The pixel's colour index
// runs through the palette: standard->device looks pen[index] up to RGBA;
// device->standard finds the matching pen and scatters its bits to the planes.
// Direction is set by the source's `stand` flag.  MFDBs travel out of band.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

static int pen_of(uint32_t rgba) {
    for (int i = 0; i < 256; i++) if (vdi_pen_rgba(i) == rgba) return i;
    return 0;
}

void op_vr_trnfm(vdi_pb *pb) {
    (void)pb;
    const MFDB *s = g_cpyfm_src, *d = g_cpyfm_dst;
    if (!s || !s->addr || !d || !d->addr) return;
    int w = s->w < d->w ? s->w : d->w, h = s->h < d->h ? s->h : d->h;

    if (s->stand) {                                     // standard (planar) -> device (chunky)
        int N = s->nplanes > 0 ? s->nplanes : 1, sw = s->stride;
        const uint16_t *sb = (const uint16_t *)s->addr;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                const uint16_t *grp = sb + (size_t)y * sw * N + (x >> 4) * N;
                int b = 15 - (x & 15), idx = 0;
                for (int p = 0; p < N; p++) idx |= ((grp[p] >> b) & 1) << p;
                d->addr[(size_t)y * d->stride + x] = vdi_pen_rgba(idx);
            }
    } else {                                            // device (chunky) -> standard (planar)
        int N = d->nplanes > 0 ? d->nplanes : 8, dw = d->stride;
        uint16_t *db = (uint16_t *)d->addr;
        for (size_t i = 0; i < (size_t)h * dw * N; i++) db[i] = 0;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int idx = pen_of(s->addr[(size_t)y * s->stride + x]);
                uint16_t *grp = db + (size_t)y * dw * N + (x >> 4) * N;
                uint16_t bit = (uint16_t)(1u << (15 - (x & 15)));
                for (int p = 0; p < N; p++) if ((idx >> p) & 1) grp[p] |= bit;
            }
    }
}

void vr_trnfm(int handle, const MFDB *src, const MFDB *dst) {
    g_cpyfm_src = src; g_cpyfm_dst = dst;
    vdi_emit(VDI_VR_TRNFM, 0, handle, 0, 0);
    g_cpyfm_src = g_cpyfm_dst = NULL;
}
