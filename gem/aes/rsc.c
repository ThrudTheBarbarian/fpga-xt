// aes/rsc.c — the shared portable GEM .rsc codec.  See aes/rsc.h.
//
// One in-memory model, two directions.  The wire layout, byte offsets and
// extensions match fpga-gem/src/GRsc.m exactly (big-endian RSHDR/OBJECT/TEDINFO/
// ICONBLK, tree-relative object indices, char/pixel 8x16-packed coordinates,
// embedded P7 PAM for G_IMAGE/G_CICON, the G_POPUP high-byte linked-tree index,
// Latin-1 strings, nbb=nstring=nimages=0, vrsn=0), so a file written here reads
// back in GemRCS and vice-versa.
//
// libc only (stdio/stdlib/string): portable to arm-none-eabi for libGEM.  PAM
// blobs are stored raw (their exact length is computed from the P7 header); the
// codec never decodes pixels, keeping it free of the img.c dependency — decode
// with img.c at the use site via rsc_image_pam().

#include "aes/rsc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { SZ_HDR = 36, SZ_OBJ = 24, SZ_TED = 28, SZ_IB = 34 };

enum { SPEC_NONE = 0, SPEC_STR, SPEC_BOX, SPEC_TED, SPEC_ICON, SPEC_PAM };

// ---- model ---------------------------------------------------------------

typedef struct {
    char  *text, *tmplt, *valid;   // owned Latin-1 wire strings
    int    font, fontId, just, fontsize, thickness;
    unsigned short color;          // packed GEM colour word (opaque to us)
    TEDINFO aes;                   // AES-facing struct (ob_spec target)
    char  *ebuf;                   // writable te_ptext buffer (owned)
} rsc_ted;

typedef struct {
    char  *label;                  // owned
    unsigned char *data, *mask;    // ib_pdata / ib_pmask bytes (owned)
    int    bytes;
    int    ichar, charX, charY, iconX, iconY, iconW, iconH, textX, textY, textW, textH;
} rsc_iconblk;

typedef struct {
    int   kind;                    // SPEC_*
    unsigned char ext;             // ob_type high byte
    char *str;                     // SPEC_STR label (owned) — ob_spec target
    unsigned char  box_char;       // SPEC_BOX
    signed char    box_thick;
    unsigned short box_color;
    rsc_ted     *ted;              // SPEC_TED (heap: address stable across realloc)
    rsc_iconblk *icon;             // SPEC_ICON
    unsigned char *pam; int pam_len;  // SPEC_PAM (owned raw P7 blob)
    CICON *cicon;                  // ob_spec target for G_CICON
} rsc_spec;

typedef struct {
    int       n, cap;
    OBJECT   *obj;                 // contiguous, tree-relative indices (root = 0)
    rsc_spec *spec;                // parallel metadata
} rsc_tree_t;

struct rsc {
    int         ntree, cap;
    rsc_tree_t *trees;
};

// ---- little helpers ------------------------------------------------------

static char *dupstr(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static int spec_kind(int type) {
    switch (type) {
        case G_STRING: case G_BUTTON: case G_TITLE:
        case G_CHECKBOX: case G_RADIO: case G_POPUP:   return SPEC_STR;
        case G_BOX: case G_IBOX: case G_BOXCHAR:       return SPEC_BOX;
        case G_TEXT: case G_BOXTEXT: case G_FTEXT:
        case G_FBOXTEXT: case G_FIELD:                 return SPEC_TED;
        case G_ICON:                                   return SPEC_ICON;
        case G_IMAGE: case G_CICON:                    return SPEC_PAM;
        default:                                       return SPEC_NONE;
    }
}
static int is_field_type(int type) {
    return type == G_FTEXT || type == G_FBOXTEXT || type == G_FIELD;
}

unsigned rsc_default_color(void) {
    // border=1, text=1, replace=0, pattern=0, inside=0  (matches gcw_default()).
    return (unsigned)((1 << 12) | (1 << 8));
}

// char/pixel 8x16 coordinate packing (GRsc unpackCoord / packCoord).
static int unpack_coord(unsigned short raw, int cell) {
    int lo = raw & 0xff;
    int hi = (signed char)((raw >> 8) & 0xff);
    return lo * cell + hi;
}
static unsigned short pack_coord(int px, int cell) {
    if (cell <= 0) cell = 8;
    int chars = px / cell, extra = px - chars * cell;
    return (unsigned short)(((extra & 0xff) << 8) | (chars & 0xff));
}

// ---- byte readers (endianness explicit) ----------------------------------

static unsigned rd16(const unsigned char *p, int be) {
    return be ? (unsigned)((p[0] << 8) | p[1]) : (unsigned)((p[1] << 8) | p[0]);
}
static unsigned long rd32(const unsigned char *p, int be) {
    return be ? ((unsigned long)p[0] << 24 | (unsigned long)p[1] << 16 | (unsigned long)p[2] << 8 | p[3])
              : ((unsigned long)p[3] << 24 | (unsigned long)p[2] << 16 | (unsigned long)p[1] << 8 | p[0]);
}

// NUL-terminated Latin-1 string at absolute file offset -> owned copy.
static char *read_cstr(const unsigned char *buf, long len, unsigned long off) {
    if (off == 0 || off >= (unsigned long)len) return dupstr("");
    unsigned long e = off;
    while (e < (unsigned long)len && buf[e]) e++;
    size_t n = (size_t)(e - off);
    char *p = (char *)malloc(n + 1);
    if (p) { memcpy(p, buf + off, n); p[n] = 0; }
    return p;
}

// Exact byte length of a P7 PAM at offset (header up to ENDHDR + W*H*DEPTH).
static long pam_length(const unsigned char *buf, long len, unsigned long off) {
    if (off + 2 >= (unsigned long)len || buf[off] != 'P' || buf[off + 1] != '7') return 0;
    unsigned long i = off + 2;
    int w = 0, h = 0, depth = 0;
    while (i < (unsigned long)len) {
        unsigned long s = i;
        while (i < (unsigned long)len && buf[i] != '\n') i++;
        // one header line in [s,i)
        const unsigned char *L = buf + s;
        long ll = (long)(i - s);
        if (i < (unsigned long)len) i++;               // step past '\n'
        while (ll > 0 && (L[0] == ' ' || L[0] == '\t')) { L++; ll--; }
        if (ll >= 6 && !memcmp(L, "ENDHDR", 6)) break;
        if      (ll >= 5 && !memcmp(L, "WIDTH",  5)) w     = atoi((const char *)L + 5);
        else if (ll >= 6 && !memcmp(L, "HEIGHT", 6)) h     = atoi((const char *)L + 6);
        else if (ll >= 5 && !memcmp(L, "DEPTH",  5)) depth = atoi((const char *)L + 5);
    }
    if (w <= 0 || h <= 0 || depth <= 0) return 0;
    return (long)(i - off) + (long)w * h * depth;
}

// ---- model construction --------------------------------------------------

static int tree_grow(rsc_tree_t *t) {
    if (t->n < t->cap) return 0;
    int nc = t->cap ? t->cap * 2 : 8;
    OBJECT *no = (OBJECT *)realloc(t->obj, (size_t)nc * sizeof(OBJECT));
    if (!no) return -1;
    t->obj = no;
    rsc_spec *ns = (rsc_spec *)realloc(t->spec, (size_t)nc * sizeof(rsc_spec));
    if (!ns) return -1;
    t->spec = ns; t->cap = nc;
    return 0;
}

rsc *rsc_new(void) {
    rsc *r = (rsc *)calloc(1, sizeof *r);
    return r;
}

int rsc_add_tree(rsc *r) {
    if (!r) return -1;
    if (r->ntree >= r->cap) {
        int nc = r->cap ? r->cap * 2 : 4;
        rsc_tree_t *nt = (rsc_tree_t *)realloc(r->trees, (size_t)nc * sizeof(rsc_tree_t));
        if (!nt) return -1;
        r->trees = nt; r->cap = nc;
    }
    rsc_tree_t *t = &r->trees[r->ntree];
    memset(t, 0, sizeof *t);
    return r->ntree++;
}

int rsc_add_object(rsc *r, int tree, int parent, int type,
                   unsigned flags, unsigned state, int x, int y, int w, int h) {
    if (!r || tree < 0 || tree >= r->ntree) return -1;
    rsc_tree_t *t = &r->trees[tree];
    if (tree_grow(t)) return -1;
    int idx = t->n++;
    OBJECT *o = &t->obj[idx];
    memset(o, 0, sizeof *o);
    o->ob_next = o->ob_head = o->ob_tail = NIL;
    o->ob_type = (uint16_t)type;
    o->ob_flags = (uint16_t)flags;
    o->ob_state = (uint16_t)state;
    o->ob_x = (int16_t)x; o->ob_y = (int16_t)y; o->ob_w = (int16_t)w; o->ob_h = (int16_t)h;
    o->ob_spec = NULL;
    rsc_spec *s = &t->spec[idx];
    memset(s, 0, sizeof *s);
    s->kind = spec_kind(type);
    // link into the parent's sibling chain (last child's ob_next -> parent)
    if (parent >= 0 && parent < idx) {
        OBJECT *p = &t->obj[parent];
        if (p->ob_head == NIL) { p->ob_head = (int16_t)idx; }
        else { t->obj[p->ob_tail].ob_next = (int16_t)idx; }
        p->ob_tail = (int16_t)idx;
        o->ob_next = (int16_t)parent;
    }
    return idx;
}

static rsc_spec *spec_at(rsc *r, int tree, int obj) {
    if (!r || tree < 0 || tree >= r->ntree) return NULL;
    rsc_tree_t *t = &r->trees[tree];
    if (obj < 0 || obj >= t->n) return NULL;
    return &t->spec[obj];
}

void rsc_set_string(rsc *r, int tree, int obj, const char *s) {
    rsc_spec *sp = spec_at(r, tree, obj);
    if (!sp) return;
    free(sp->str);
    sp->str = dupstr(s);
    sp->kind = SPEC_STR;
}

void rsc_set_box(rsc *r, int tree, int obj, int chr, int thick, unsigned color) {
    rsc_spec *sp = spec_at(r, tree, obj);
    if (!sp) return;
    sp->box_char = (unsigned char)chr;
    sp->box_thick = (signed char)thick;
    sp->box_color = (unsigned short)color;
    sp->kind = SPEC_BOX;
}

static rsc_ted *ted_make(const char *text, const char *tmplt, const char *valid,
                         int just, int font, int fontId, int fontsize,
                         int thickness, unsigned short color) {
    rsc_ted *td = (rsc_ted *)calloc(1, sizeof *td);
    if (!td) return NULL;
    td->text = dupstr(text); td->tmplt = dupstr(tmplt); td->valid = dupstr(valid);
    td->just = just; td->font = font; td->fontId = fontId;
    td->fontsize = fontsize; td->thickness = thickness; td->color = color;
    // AES-facing buffer: room for the value or a full template of input slots.
    size_t cap = strlen(td->text) + strlen(td->tmplt) + 8;
    td->ebuf = (char *)calloc(1, cap);
    if (td->ebuf) memcpy(td->ebuf, td->text, strlen(td->text));
    td->aes.te_ptext  = td->ebuf;
    td->aes.te_ptmplt = td->tmplt[0] ? td->tmplt : NULL;
    td->aes.te_pvalid = td->valid[0] ? td->valid : NULL;
    td->aes.te_txtlen = (int16_t)cap;
    td->aes.te_just   = (int16_t)just;
    return td;
}

void rsc_set_tedinfo(rsc *r, int tree, int obj, const char *text,
                     const char *tmplt, const char *valid, int just) {
    rsc_spec *sp = spec_at(r, tree, obj);
    if (!sp) return;
    if (sp->ted) { rsc_ted *o = sp->ted; free(o->text); free(o->tmplt); free(o->valid); free(o->ebuf); free(o); }
    sp->ted = ted_make(text, tmplt, valid, just, 3, 0, 0, 0, 0);
    sp->kind = SPEC_TED;
}

void rsc_set_popup_link(rsc *r, int tree, int obj, int linked_tree) {
    rsc_spec *sp = spec_at(r, tree, obj);
    if (!sp) return;
    sp->ext = (unsigned char)(linked_tree & 0xff);
}
void rsc_set_exttype(rsc *r, int tree, int obj, int ext) {
    rsc_spec *sp = spec_at(r, tree, obj);
    if (!sp) return;
    sp->ext = (unsigned char)(ext & 0xff);
}

// Point every object's ob_spec at the resolved payload (idempotent; called
// before the tree is handed out or serialised — safe after all growth).
static void tree_finalize(rsc_tree_t *t) {
    for (int i = 0; i < t->n; i++) {
        OBJECT *o = &t->obj[i];
        rsc_spec *s = &t->spec[i];
        switch (s->kind) {
            case SPEC_STR: o->ob_spec = s->str; break;
            case SPEC_TED: o->ob_spec = s->ted ? &s->ted->aes : NULL; break;
            case SPEC_PAM:
                if (o->ob_type == G_CICON) {
                    if (!s->cicon) s->cicon = (CICON *)calloc(1, sizeof(CICON));
                    o->ob_spec = s->cicon;            // img=NULL, text=NULL (undecoded)
                } else o->ob_spec = NULL;              // G_IMAGE: decode via img.c at use
                break;
            case SPEC_BOX: case SPEC_ICON: default: o->ob_spec = NULL; break;
        }
    }
}

// ---- accessors -----------------------------------------------------------

int rsc_ntree(const rsc *r) { return r ? r->ntree : 0; }

OBJECT *rsc_tree(rsc *r, int index) {
    if (!r || index < 0 || index >= r->ntree) return NULL;
    tree_finalize(&r->trees[index]);
    return r->trees[index].obj;
}

int rsc_tree_nobs(const rsc *r, int index) {
    if (!r || index < 0 || index >= r->ntree) return -1;
    return r->trees[index].n;
}

int rsc_popup_link(const rsc *r, int tree, int obj) {
    const rsc_spec *sp = spec_at((rsc *)r, tree, obj);
    return sp ? sp->ext : -1;
}

const unsigned char *rsc_image_pam(const rsc *r, int tree, int obj, int *len) {
    const rsc_spec *sp = spec_at((rsc *)r, tree, obj);
    if (!sp || !sp->pam) { if (len) *len = 0; return NULL; }
    if (len) *len = sp->pam_len;
    return sp->pam;
}

// ---- free ----------------------------------------------------------------

static void spec_free(rsc_spec *s) {
    free(s->str);
    if (s->ted) { free(s->ted->text); free(s->ted->tmplt); free(s->ted->valid); free(s->ted->ebuf); free(s->ted); }
    if (s->icon) { free(s->icon->label); free(s->icon->data); free(s->icon->mask); free(s->icon); }
    free(s->pam);
    free(s->cicon);
}

void rsc_free(rsc *r) {
    if (!r) return;
    for (int t = 0; t < r->ntree; t++) {
        rsc_tree_t *tr = &r->trees[t];
        for (int i = 0; i < tr->n; i++) spec_free(&tr->spec[i]);
        free(tr->obj); free(tr->spec);
    }
    free(r->trees);
    free(r);
}

// ---- reader --------------------------------------------------------------

// Plausibility of a header at `buf` under endianness `be` (endianness sniff).
static int hdr_plausible(const unsigned char *buf, long len, int be) {
    if (len < SZ_HDR) return 0;
    unsigned long objBase = rd16(buf + 2, be), trindex = rd16(buf + 18, be);
    int nobs = (int)rd16(buf + 20, be), ntree = (int)rd16(buf + 22, be);
    if (nobs <= 0 || nobs > 8000 || ntree <= 0 || ntree > 2000) return 0;
    if (objBase < SZ_HDR || objBase >= (unsigned long)len) return 0;
    if (objBase + (unsigned long)nobs * SZ_OBJ > (unsigned long)len) return 0;
    if (trindex + (unsigned long)ntree * 4 > (unsigned long)len) return 0;
    return 1;
}

// Copy the object at absolute wire index `abs` into slot `dst` of tree `t`,
// resolving its spec.  Wire ob_next/head/tail are already tree-relative.
static void read_object(rsc_tree_t *t, int dst, const unsigned char *buf, long len,
                        int be, unsigned long objBase, int abs) {
    const unsigned char *o = buf + objBase + (unsigned long)abs * SZ_OBJ;
    OBJECT *d = &t->obj[dst];
    rsc_spec *s = &t->spec[dst];
    memset(d, 0, sizeof *d);
    memset(s, 0, sizeof *s);
    unsigned next = rd16(o + 0, be), head = rd16(o + 2, be), tail = rd16(o + 4, be);
    unsigned rawtype = rd16(o + 6, be);
    d->ob_next = (next == 0xFFFF) ? NIL : (int16_t)next;
    d->ob_head = (head == 0xFFFF) ? NIL : (int16_t)head;
    d->ob_tail = (tail == 0xFFFF) ? NIL : (int16_t)tail;
    d->ob_type = (uint16_t)(rawtype & 0x00FF);
    d->ob_flags = (uint16_t)rd16(o + 8, be);
    d->ob_state = (uint16_t)rd16(o + 10, be);
    unsigned long spec = rd32(o + 12, be);
    d->ob_x = (int16_t)unpack_coord(rd16(o + 16, be), 8);
    d->ob_y = (int16_t)unpack_coord(rd16(o + 18, be), 16);
    d->ob_w = (int16_t)unpack_coord(rd16(o + 20, be), 8);
    d->ob_h = (int16_t)unpack_coord(rd16(o + 22, be), 16);
    d->ob_spec = NULL;

    // ob_type high byte: preserved except on editable fields (a legacy border
    // colour there would misread as "rounded").
    s->ext = is_field_type(d->ob_type) ? 0 : (unsigned char)((rawtype >> 8) & 0xff);
    s->kind = spec_kind(d->ob_type);

    switch (s->kind) {
        case SPEC_STR:
            s->str = read_cstr(buf, len, spec);
            break;
        case SPEC_BOX:
            s->box_char  = (unsigned char)((spec >> 24) & 0xff);
            s->box_thick = (signed char)((spec >> 16) & 0xff);
            s->box_color = (unsigned short)(spec & 0xffff);
            break;
        case SPEC_TED:
            if (spec + SZ_TED <= (unsigned long)len) {
                const unsigned char *ti = buf + spec;
                char *tx = read_cstr(buf, len, rd32(ti + 0, be));
                char *tm = read_cstr(buf, len, rd32(ti + 4, be));
                char *vl = read_cstr(buf, len, rd32(ti + 8, be));
                s->ted = ted_make(tx, tm, vl, (int)rd16(ti + 16, be),
                                  (int)rd16(ti + 12, be), (int)rd16(ti + 14, be),
                                  (int)rd16(ti + 20, be), (int16_t)rd16(ti + 22, be),
                                  (unsigned short)rd16(ti + 18, be));
                free(tx); free(tm); free(vl);
            } else s->ted = ted_make("", "", "", 0, 3, 0, 0, 0, 0);
            break;
        case SPEC_ICON:
            if (spec + SZ_IB <= (unsigned long)len) {
                const unsigned char *ib = buf + spec;
                rsc_iconblk *ic = (rsc_iconblk *)calloc(1, sizeof *ic);
                unsigned long pmask = rd32(ib + 0, be), pdata = rd32(ib + 4, be), ptext = rd32(ib + 8, be);
                ic->ichar = (int)rd16(ib + 12, be);
                ic->charX = (int)rd16(ib + 14, be); ic->charY = (int)rd16(ib + 16, be);
                ic->iconX = (int16_t)rd16(ib + 18, be); ic->iconY = (int16_t)rd16(ib + 20, be);
                ic->iconW = (int)rd16(ib + 22, be); ic->iconH = (int)rd16(ib + 24, be);
                ic->textX = (int16_t)rd16(ib + 26, be); ic->textY = (int16_t)rd16(ib + 28, be);
                ic->textW = (int)rd16(ib + 30, be); ic->textH = (int)rd16(ib + 32, be);
                ic->label = read_cstr(buf, len, ptext);
                ic->bytes = ((ic->iconW + 15) / 16) * 2 * (ic->iconH > 0 ? ic->iconH : 0);
                if (pdata && pdata + ic->bytes <= (unsigned long)len) {
                    ic->data = (unsigned char *)malloc(ic->bytes ? ic->bytes : 1);
                    if (ic->data) memcpy(ic->data, buf + pdata, ic->bytes);
                }
                if (pmask && pmask + ic->bytes <= (unsigned long)len) {
                    ic->mask = (unsigned char *)malloc(ic->bytes ? ic->bytes : 1);
                    if (ic->mask) memcpy(ic->mask, buf + pmask, ic->bytes);
                }
                s->icon = ic;
            }
            break;
        case SPEC_PAM: {
            long pl = pam_length(buf, len, spec);
            if (pl > 0 && spec + (unsigned long)pl <= (unsigned long)len) {
                s->pam = (unsigned char *)malloc(pl);
                if (s->pam) { memcpy(s->pam, buf + spec, pl); s->pam_len = (int)pl; }
            }
            break;
        }
        default: break;
    }
}

static rsc *parse(const unsigned char *buf, long len, int be) {
    if (!hdr_plausible(buf, len, be)) return NULL;
    unsigned long objBase = rd16(buf + 2, be), trindex = rd16(buf + 18, be);
    int nobs = (int)rd16(buf + 20, be), ntree = (int)rd16(buf + 22, be);

    // root absolute object index per tree
    int *rootAbs = (int *)malloc((size_t)ntree * sizeof(int));
    if (!rootAbs) return NULL;
    for (int i = 0; i < ntree; i++) {
        unsigned long off = rd32(buf + trindex + (unsigned long)i * 4, be);
        long ri = ((long)off - (long)objBase) / SZ_OBJ;
        rootAbs[i] = (ri >= 0 && ri < nobs) ? (int)ri : -1;
    }

    rsc *r = rsc_new();
    if (!r) { free(rootAbs); return NULL; }
    for (int t = 0; t < ntree; t++) {
        rsc_add_tree(r);
        rsc_tree_t *tr = &r->trees[t];
        int base = rootAbs[t];
        if (base < 0) continue;
        // trees are laid out contiguously; this tree ends at the next-greater
        // root index (or nobs).
        int end = nobs;
        for (int u = 0; u < ntree; u++)
            if (rootAbs[u] > base && rootAbs[u] < end) end = rootAbs[u];
        int cnt = end - base;
        if (cnt <= 0) continue;
        tr->obj  = (OBJECT *)malloc((size_t)cnt * sizeof(OBJECT));
        tr->spec = (rsc_spec *)malloc((size_t)cnt * sizeof(rsc_spec));
        if (!tr->obj || !tr->spec) { free(rootAbs); rsc_free(r); return NULL; }
        tr->cap = cnt; tr->n = cnt;
        for (int k = 0; k < cnt; k++)
            read_object(tr, k, buf, len, be, objBase, base + k);
    }
    free(rootAbs);
    return r;
}

rsc *rsc_load(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < SZ_HDR) { fclose(f); return NULL; }
    unsigned char *buf = (unsigned char *)malloc((size_t)len);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)len, f) != (size_t)len) { free(buf); fclose(f); return NULL; }
    fclose(f);

    rsc *r = parse(buf, len, 1);          // big-endian (Atari ST)
    if (!r) r = parse(buf, len, 0);       // little-endian fallback
    free(buf);
    return r;
}

// ---- writer --------------------------------------------------------------

typedef struct { unsigned char *p; long n, cap; } dbuf;
static int dbuf_put(dbuf *d, const void *src, long n) {
    if (d->n + n > d->cap) {
        long nc = d->cap ? d->cap : 256;
        while (nc < d->n + n) nc *= 2;
        unsigned char *np = (unsigned char *)realloc(d->p, (size_t)nc);
        if (!np) return -1;
        d->p = np; d->cap = nc;
    }
    memcpy(d->p + d->n, src, (size_t)n);
    d->n += n;
    return 0;
}
static void w16(dbuf *d, unsigned v)      { unsigned char b[2] = { (unsigned char)(v >> 8), (unsigned char)v }; dbuf_put(d, b, 2); }
static void w32(dbuf *d, unsigned long v) { unsigned char b[4] = { (unsigned char)(v >> 24), (unsigned char)(v >> 16), (unsigned char)(v >> 8), (unsigned char)v }; dbuf_put(d, b, 4); }

// A string-interning table (dedup by value, first-encounter order).
typedef struct { char **s; unsigned long *off; int n, cap; } strtab;
static unsigned intern(strtab *st, const char *s) {
    if (!s) s = "";
    for (int i = 0; i < st->n; i++) if (!strcmp(st->s[i], s)) return (unsigned)i;
    if (st->n >= st->cap) {
        int nc = st->cap ? st->cap * 2 : 16;
        st->s = (char **)realloc(st->s, (size_t)nc * sizeof(char *));
        st->off = (unsigned long *)realloc(st->off, (size_t)nc * sizeof(unsigned long));
        st->cap = nc;
    }
    st->s[st->n] = (char *)s;
    return (unsigned)st->n++;
}
// Offset of an already-interned string (0 if absent — shouldn't happen post Pass B).
static unsigned long str_off(const strtab *st, const char *s) {
    if (!s) s = "";
    for (int i = 0; i < st->n; i++) if (!strcmp(st->s[i], s)) return st->off[i];
    return 0;
}

// Build the whole .rsc image into a fresh buffer.  Returns length (0 on error);
// *out receives the malloc'd bytes (caller frees).
long rsc_save_mem(const rsc *r, unsigned char **out) {
    if (!r || !out) return 0;
    *out = NULL;

    // Pass A: global flatten order = trees in order, each in index order.
    int nobs = 0, ntree = r->ntree;
    for (int t = 0; t < ntree; t++) nobs += r->trees[t].n;
    if (nobs == 0) return 0;

    // Index maps for the global object stream.
    OBJECT  **gobj = (OBJECT **)malloc((size_t)nobs * sizeof(OBJECT *));
    rsc_spec **gsp = (rsc_spec **)malloc((size_t)nobs * sizeof(rsc_spec *));
    unsigned long *treeBase = (unsigned long *)malloc((size_t)ntree * sizeof(unsigned long));
    if (!gobj || !gsp || !treeBase) { free(gobj); free(gsp); free(treeBase); return 0; }
    {
        int g = 0;
        for (int t = 0; t < ntree; t++) {
            treeBase[t] = (unsigned long)g;
            for (int i = 0; i < r->trees[t].n; i++) { gobj[g] = &r->trees[t].obj[i]; gsp[g] = &r->trees[t].spec[i]; g++; }
        }
    }

    // Pass B: collect strings / TEDINFOs / ICONBLKs / image data.
    strtab st; memset(&st, 0, sizeof st);
    int *tedIdx = (int *)malloc((size_t)nobs * sizeof(int));   // -> position in ted list, or -1
    int *ibIdx  = (int *)malloc((size_t)nobs * sizeof(int));
    unsigned long *pamOff = (unsigned long *)malloc((size_t)nobs * sizeof(unsigned long));
    unsigned long *dataOff = (unsigned long *)malloc((size_t)nobs * sizeof(unsigned long));
    unsigned long *maskOff = (unsigned long *)malloc((size_t)nobs * sizeof(unsigned long));
    dbuf im; memset(&im, 0, sizeof im);
    if (!tedIdx || !ibIdx || !pamOff || !dataOff || !maskOff) {
        free(gobj); free(gsp); free(treeBase); free(st.s); free(st.off);
        free(tedIdx); free(ibIdx); free(pamOff); free(dataOff); free(maskOff); free(im.p);
        return 0;
    }
    int nted = 0, nib = 0;
    for (int g = 0; g < nobs; g++) {
        tedIdx[g] = ibIdx[g] = -1; pamOff[g] = dataOff[g] = maskOff[g] = 0;
        rsc_spec *s = gsp[g];
        switch (s->kind) {
            case SPEC_STR: intern(&st, s->str ? s->str : ""); break;
            case SPEC_TED:
                if (s->ted) { intern(&st, s->ted->text); intern(&st, s->ted->tmplt); intern(&st, s->ted->valid); }
                tedIdx[g] = nted++;
                break;
            case SPEC_ICON:
                if (s->icon) {
                    intern(&st, s->icon->label ? s->icon->label : "");
                    ibIdx[g] = nib++;
                    int bytes = s->icon->bytes;
                    dataOff[g] = (unsigned long)im.n;
                    if (s->icon->data) dbuf_put(&im, s->icon->data, bytes);
                    else { for (int z = 0; z < bytes; z++) { unsigned char zero = 0; dbuf_put(&im, &zero, 1); } }
                    maskOff[g] = (unsigned long)im.n;
                    if (s->icon->mask) dbuf_put(&im, s->icon->mask, bytes);
                    else { for (int z = 0; z < bytes; z++) { unsigned char zero = 0; dbuf_put(&im, &zero, 1); } }
                }
                break;
            case SPEC_PAM:
                if (s->pam) { pamOff[g] = (unsigned long)im.n; dbuf_put(&im, s->pam, s->pam_len); }
                break;
            default: break;
        }
    }

    // Region layout (identical algorithm to GRsc).
    unsigned long objBase = SZ_HDR;
    unsigned long tedBase = objBase + (unsigned long)nobs * SZ_OBJ;
    unsigned long ibBase  = tedBase + (unsigned long)nted * SZ_TED;
    unsigned long bbBase  = ibBase + (unsigned long)nib * SZ_IB;
    unsigned long frstr = bbBase, frimg = bbBase, trindex = bbBase;
    unsigned long strBase = trindex + (unsigned long)ntree * 4;
    // resolve string offsets
    unsigned long cur = strBase;
    for (int i = 0; i < st.n; i++) { st.off[i] = cur; cur += (unsigned long)strlen(st.s[i]) + 1; }
    unsigned long imBase = cur;
    unsigned long total = imBase + (unsigned long)im.n;

    dbuf ob; memset(&ob, 0, sizeof ob);
    // ---- header (18 words) ----
    w16(&ob, 0);                                        // vrsn
    w16(&ob, objBase); w16(&ob, tedBase); w16(&ob, ibBase); w16(&ob, bbBase);
    w16(&ob, frstr); w16(&ob, strBase); w16(&ob, imBase); w16(&ob, frimg);
    w16(&ob, trindex); w16(&ob, (unsigned)nobs); w16(&ob, (unsigned)ntree); w16(&ob, (unsigned)nted);
    w16(&ob, (unsigned)nib); w16(&ob, 0); w16(&ob, 0); w16(&ob, 0); w16(&ob, total);

    // ---- OBJECT array ----
    for (int g = 0; g < nobs; g++) {
        OBJECT *o = gobj[g]; rsc_spec *s = gsp[g];
        w16(&ob, o->ob_next == NIL ? 0xFFFF : (unsigned)(uint16_t)o->ob_next);
        w16(&ob, o->ob_head == NIL ? 0xFFFF : (unsigned)(uint16_t)o->ob_head);
        w16(&ob, o->ob_tail == NIL ? 0xFFFF : (unsigned)(uint16_t)o->ob_tail);
        w16(&ob, (unsigned)(((s->ext & 0xff) << 8) | (o->ob_type & 0xff)));
        unsigned fl = o->ob_flags;
        if (g == nobs - 1) fl |= OF_LASTOB;              // the last object terminates
        w16(&ob, fl);
        w16(&ob, o->ob_state);
        unsigned long spec = 0;
        switch (s->kind) {
            case SPEC_BOX:
                spec = ((unsigned long)(s->box_char & 0xff) << 24) |
                       ((unsigned long)((unsigned char)s->box_thick) << 16) | s->box_color;
                break;
            case SPEC_STR: spec = str_off(&st, s->str ? s->str : ""); break;
            case SPEC_TED: spec = tedBase + (unsigned long)tedIdx[g] * SZ_TED; break;
            case SPEC_ICON: spec = ibBase + (unsigned long)ibIdx[g] * SZ_IB; break;
            case SPEC_PAM: spec = s->pam ? imBase + pamOff[g] : 0; break;
            default: break;
        }
        w32(&ob, spec);
        w16(&ob, pack_coord(o->ob_x, 8));
        w16(&ob, pack_coord(o->ob_y, 16));
        w16(&ob, pack_coord(o->ob_w, 8));
        w16(&ob, pack_coord(o->ob_h, 16));
    }

    // ---- TEDINFO array ----
    for (int g = 0; g < nobs; g++) {
        if (tedIdx[g] < 0) continue;
        rsc_ted *t = gsp[g]->ted;
        w32(&ob, str_off(&st, t->text));
        w32(&ob, str_off(&st, t->tmplt));
        w32(&ob, str_off(&st, t->valid));
        w16(&ob, (unsigned)t->font); w16(&ob, (unsigned)t->fontId); w16(&ob, (unsigned)t->just);
        w16(&ob, t->color); w16(&ob, (unsigned)t->fontsize); w16(&ob, (unsigned)(uint16_t)t->thickness);
        w16(&ob, (unsigned)(strlen(t->text) + 1));      // te_txtlen
        w16(&ob, (unsigned)(strlen(t->tmplt) + 1));     // te_tmplen
    }

    // ---- ICONBLK array ----
    for (int g = 0; g < nobs; g++) {
        if (ibIdx[g] < 0) continue;
        rsc_iconblk *ic = gsp[g]->icon;
        w32(&ob, imBase + maskOff[g]); w32(&ob, imBase + dataOff[g]);
        w32(&ob, str_off(&st, ic->label ? ic->label : ""));
        w16(&ob, (unsigned)ic->ichar); w16(&ob, (unsigned)ic->charX); w16(&ob, (unsigned)ic->charY);
        w16(&ob, (unsigned)(uint16_t)ic->iconX); w16(&ob, (unsigned)(uint16_t)ic->iconY);
        w16(&ob, (unsigned)ic->iconW); w16(&ob, (unsigned)ic->iconH);
        w16(&ob, (unsigned)(uint16_t)ic->textX); w16(&ob, (unsigned)(uint16_t)ic->textY);
        w16(&ob, (unsigned)ic->textW); w16(&ob, (unsigned)ic->textH);
    }

    // ---- tree index ----
    for (int t = 0; t < ntree; t++) w32(&ob, objBase + treeBase[t] * SZ_OBJ);

    // ---- string data ----
    for (int i = 0; i < st.n; i++) dbuf_put(&ob, st.s[i], (long)strlen(st.s[i]) + 1);
    // ---- image data ----
    if (im.n) dbuf_put(&ob, im.p, im.n);

    long rc = (ob.n == (long)total) ? ob.n : 0;
    *out = ob.p;
    if (!rc) { free(ob.p); *out = NULL; }

    free(gobj); free(gsp); free(treeBase);
    free(st.s); free(st.off);
    free(tedIdx); free(ibIdx); free(pamOff); free(dataOff); free(maskOff); free(im.p);
    return rc;
}

int rsc_save(const rsc *r, const char *path) {
    unsigned char *buf = NULL;
    long n = rsc_save_mem(r, &buf);
    if (n <= 0 || !buf) { free(buf); return -1; }
    FILE *f = fopen(path, "wb");
    if (!f) { free(buf); return -1; }
    size_t wrote = fwrite(buf, 1, (size_t)n, f);
    fclose(f);
    free(buf);
    return wrote == (size_t)n ? 0 : -1;
}
