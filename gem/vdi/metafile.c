// vdi/metafile.c — the metafile device (v_opnwk id 31..40).  A metafile
// workstation records every VDI call to a file instead of drawing; the file can
// be replayed later to re-issue the calls on a real workstation.
//
// Format (16-bit words, host order — both record and replay are little-endian
// ARM/x86): an 8-word header { 0xFFFF, hdr_len=8, version=1, RC=2, 0,0,0,0 },
// then one record per call { opcode, n_ptsin_pairs, n_intin, sub-opcode } +
// ptsin[2*n] + intin[n], terminated by a record whose opcode is 0xFFFF.  The
// handle (contrl[6]) is not stored — replay supplies the target.
//
// Caveat: vro_cpyfm carries its MFDB pointers out-of-band (not in the param
// block), so raster copies are recorded without their bitmaps and don't replay.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stdio.h>
#include <stdlib.h>

typedef struct { FILE *f; } metafile;

static void w16(FILE *f, int v) { int16_t x = (int16_t)v; fwrite(&x, sizeof x, 1, f); }

int metafile_open(vdi_ws *w, const char *path) {
    FILE *f = fopen(path && path[0] ? path : "out.gem", "wb");
    if (!f) return -1;
    metafile *m = malloc(sizeof *m);
    if (!m) { fclose(f); return -1; }
    m->f = f;
    w16(f, 0xFFFF); w16(f, 8); w16(f, 1); w16(f, 2);    // header
    w16(f, 0); w16(f, 0); w16(f, 0); w16(f, 0);
    w->dev = m;
    return 0;
}

void metafile_record(vdi_ws *w, vdi_pb *pb) {
    metafile *m = w->dev; if (!m) return;
    int npts = pb->contrl[1], nint = pb->contrl[3];
    if (npts < 0) npts = 0; if (nint < 0) nint = 0;
    w16(m->f, pb->contrl[0]); w16(m->f, npts); w16(m->f, nint); w16(m->f, pb->contrl[5]);
    for (int i = 0; i < 2 * npts; i++) w16(m->f, pb->ptsin[i]);
    for (int i = 0; i < nint;     i++) w16(m->f, pb->intin[i]);
}

void metafile_close(vdi_ws *w) {
    metafile *m = w->dev; if (!m) return;
    w16(m->f, 0xFFFF); w16(m->f, 0); w16(m->f, 0); w16(m->f, 0);   // end record
    fclose(m->f); free(m); w->dev = NULL;
}

int vdi_play_metafile(const char *path, int handle) {
    FILE *f = fopen(path, "rb"); if (!f) return -1;
    int16_t hdr[8];
    if (fread(hdr, sizeof(int16_t), 8, f) != 8 || (uint16_t)hdr[0] != 0xFFFF) { fclose(f); return -1; }
    for (int i = 8; i < hdr[1]; i++) { int16_t t; if (fread(&t, sizeof t, 1, f) != 1) break; }

    int16_t contrl[16] = {0}, intin[128], ptsin[256], intout[128], ptsout[256];
    vdi_pb pb = { contrl, intin, ptsin, intout, ptsout };
    int played = 0;
    for (;;) {
        int16_t rec[4];
        if (fread(rec, sizeof(int16_t), 4, f) != 4) break;
        if ((uint16_t)rec[0] == 0xFFFF) break;             // end record
        int npts = rec[1], nint = rec[2];
        if (npts < 0 || npts > 128 || nint < 0 || nint > 128) break;   // corrupt
        if ((int)fread(ptsin, sizeof(int16_t), 2 * npts, f) != 2 * npts) break;
        if ((int)fread(intin, sizeof(int16_t), nint, f) != nint) break;
        contrl[0] = rec[0]; contrl[1] = (int16_t)npts; contrl[3] = (int16_t)nint;
        contrl[5] = rec[3]; contrl[6] = (int16_t)handle;
        vdi_call(&pb);
        played++;
    }
    fclose(f);
    return played;
}
