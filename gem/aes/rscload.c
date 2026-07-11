// aes/rscload.c — AES-side adapter over the shared GEM .rsc engine.  See
// aes/rscload.h.  The engine (../fpga-gem/src/rsc.c) does all the parsing; this
// file only (a) decodes each G_CICON/G_IMAGE embedded P7 PAM into our CICON and
// (b) masks the ob_type high byte for AES traversal, capturing it for
// rscload_ext().  It links against the engine and the gfx surface layer.

#include "aes/rscload.h"
#include "gfx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct rscdoc {
    RSC     *r;            // the shared engine resource (owns objects/strings/TEDINFOs)
    uint8_t *ext;          // per global object: original ob_type high byte
    int      nobj;         // length of ext[] and cicons[]
    CICON   *cicons;       // per global object: decoded colour icon (img==NULL if none)
};

// ---- P7 PAM -> gfx_surface ------------------------------------------------
// The engine hands back the raw PAM bytes; img.c only decodes from a FILE* path
// (no memory entry point, and it is out of this task's edit scope), so decode
// here — mirroring img.c's decode_body/row_expand so the surface matches what
// load_icon builds.  Straight (non-premultiplied) RGBA, MAXVAL 255, DEPTH 1..4.
static gfx_surface *decode_pam(const uint8_t *p, uint32_t len)
{
    if (!p || len < 3 || p[0] != 'P' || p[1] != '7') return NULL;
    uint32_t i = 2;
    int w = 0, h = 0, depth = 0, mx = 0;
    while (i < len) {
        uint32_t s = i;
        while (i < len && p[i] != '\n') i++;
        uint32_t n = i - s;
        const char *ln = (const char *)(p + s);
        if (i < len) i++;                                // step past '\n'
        if      (n >= 6 && !memcmp(ln, "ENDHDR", 6)) break;
        else if (n >= 6 && !memcmp(ln, "WIDTH ",  6)) w     = atoi(ln + 6);
        else if (n >= 7 && !memcmp(ln, "HEIGHT ", 7)) h     = atoi(ln + 7);
        else if (n >= 6 && !memcmp(ln, "DEPTH ",  6)) depth = atoi(ln + 6);
        else if (n >= 7 && !memcmp(ln, "MAXVAL ", 7)) mx    = atoi(ln + 7);
    }
    if (w <= 0 || h <= 0 || depth < 1 || depth > 4 || mx != 255) return NULL;
    if ((uint64_t)i + (uint64_t)w * h * depth > len) return NULL;

    gfx_surface *sfc = gfx_surface_alloc(w, h);
    if (!sfc) return NULL;
    const uint8_t *px = p + i;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const uint8_t *q = px + ((size_t)y * w + x) * depth;
            uint8_t r, g, b, a;
            switch (depth) {
                case 1: r = g = b = q[0]; a = 0xFF;  break;
                case 2: r = g = b = q[0]; a = q[1];  break;
                case 4: r = q[0]; g = q[1]; b = q[2]; a = q[3]; break;
                default: r = q[0]; g = q[1]; b = q[2]; a = 0xFF; break;  // 3 = RGB
            }
            sfc->px[(size_t)y * sfc->stride + x] = GFX_RGBA(r, g, b, a);
        }
    }
    return sfc;
}

// ---- load ------------------------------------------------------------------

rscdoc *rscload_mem(const uint8_t *data, size_t len, const char **err)
{
    RSC *r = rsc_read(data, len, err);
    if (!r) return NULL;

    rscdoc *d = (rscdoc *)calloc(1, sizeof *d);
    if (!d) { rsc_free(r); if (err) *err = "out of memory"; return NULL; }
    d->r = r;

    int count = 0;
    RSC_OBJECT *obj = rsc_objects(r, &count);
    d->nobj = count;
    d->ext    = (uint8_t *)calloc(count ? count : 1, sizeof(uint8_t));
    d->cicons = (CICON  *)calloc(count ? count : 1, sizeof(CICON));
    if (!d->ext || !d->cicons) { rscload_free(d); if (err) *err = "out of memory"; return NULL; }

    for (int i = 0; i < count; i++) {
        RSC_OBJECT *o = &obj[i];
        int type = o->ob_type;
        d->ext[i] = (uint8_t)((type >> 8) & 0xFF);
        int low   = type & 0xFF;

        if ((low == G_CICON || low == G_IMAGE) && o->ob_spec) {
            RSC_CICON *ci = (RSC_CICON *)o->ob_spec;      // engine's colour-icon record
            gfx_surface *sfc = decode_pam(ci->pam, ci->pam_len);
            d->cicons[i].img  = sfc;                      // NULL if no/undecodable PAM
            d->cicons[i].text = ci->text;                 // arena-owned by the engine
            o->ob_spec = &d->cicons[i];                   // objc_draw sees our CICON*
        }
        o->ob_type = (uint16_t)low;                        // AES switches on the low byte
    }
    return d;
}

rscdoc *rscload_file(const char *path, const char **err)
{
    FILE *f = fopen(path, "rb");
    if (!f) { if (err) *err = "cannot open file"; return NULL; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len <= 0) { fclose(f); if (err) *err = "empty file"; return NULL; }
    uint8_t *buf = (uint8_t *)malloc((size_t)len);
    if (!buf) { fclose(f); if (err) *err = "out of memory"; return NULL; }
    if (fread(buf, 1, (size_t)len, f) != (size_t)len) {
        free(buf); fclose(f); if (err) *err = "short read"; return NULL;
    }
    fclose(f);
    rscdoc *d = rscload_mem(buf, (size_t)len, err);
    free(buf);
    return d;
}

// ---- accessors + free ------------------------------------------------------

int rscload_ntrees(const rscdoc *d) { return d ? rsc_ntrees(d->r) : 0; }

OBJECT *rscload_tree(rscdoc *d, int index)
{
    return d ? (OBJECT *)rsc_tree(d->r, index) : NULL;
}

int rscload_ext(const rscdoc *d, int index, int obj)
{
    if (!d) return -1;
    RSC_OBJECT *root = rsc_tree(d->r, index);
    RSC_OBJECT *base = rsc_objects(d->r, NULL);
    if (!root || !base || obj < 0) return -1;
    int gi = (int)(root - base) + obj;                     // tree-relative -> global
    if (gi < 0 || gi >= d->nobj) return -1;
    return d->ext[gi];
}

void rscload_free(rscdoc *d)
{
    if (!d) return;
    if (d->cicons)
        for (int i = 0; i < d->nobj; i++)
            if (d->cicons[i].img) gfx_surface_free(d->cicons[i].img);
    free(d->cicons);
    free(d->ext);
    if (d->r) rsc_free(d->r);
    free(d);
}
