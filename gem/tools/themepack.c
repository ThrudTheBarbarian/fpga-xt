// tools/themepack.c — bake a theme atlas from separate slice PNGs.
//
// Reads a recipe (one element per line: `name type file...`) and the source
// resource directory, decodes each PNG via ImageMagick (`magick ... RGBA:-`),
// composes each element's slices into one sub-image, packs the sub-images into
// a single atlas, and writes:
//   artwork.tex   — "GTEX" + w,h (u32) + RGBA8888 rows (host order; no PNG
//                   decoder needed at runtime)
//   locations.txt — `name x y w h  l t r b  fill` per element
//   theme.ini     — the colours (copied from the Aristo2 descriptor)
//
// Element types:
//   sprite        1 file, drawn 1:1 (fill none)
//   h3            left center right  -> horizontal 3-slice (insets l,r)
//   v3            top center bottom  -> vertical 3-slice   (insets t,b)
//   nine          tl tc tr cl cc cr bl bc br -> 9-slice    (insets from corners)
//
// Insets are derived from the corner/cap slice sizes.  Usage:
//   themepack <resource-dir> <recipe> <out-dir>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { unsigned *px; int w, h; } img;        // px = 0xRRGGBBAA

// Trim `n` px out of the centre of a strip along its longer axis (keeps the
// outer edges / groove walls — narrows a too-wide scrollbar track).
static img trim_center(img m, int n) {
    if (n <= 0) return m;
    if (m.w >= m.h) {                                  // trim columns
        int keep = m.w - n; if (keep < 1) keep = 1;
        int lw = (keep + 1) / 2, rw = keep - lw;
        img o = { malloc((size_t)keep * m.h * 4), keep, m.h };
        for (int y = 0; y < m.h; y++) {
            for (int x = 0; x < lw; x++) o.px[(size_t)y*keep + x] = m.px[(size_t)y*m.w + x];
            for (int x = 0; x < rw; x++) o.px[(size_t)y*keep + lw + x] = m.px[(size_t)y*m.w + (m.w-rw) + x];
        }
        free(m.px); return o;
    } else {                                           // trim rows
        int keep = m.h - n; if (keep < 1) keep = 1;
        int th = (keep + 1) / 2, bh = keep - th;
        img o = { malloc((size_t)m.w * keep * 4), m.w, keep };
        for (int x = 0; x < m.w; x++) {
            for (int y = 0; y < th; y++) o.px[(size_t)y*m.w + x] = m.px[(size_t)y*m.w + x];
            for (int y = 0; y < bh; y++) o.px[(size_t)(th+y)*m.w + x] = m.px[(size_t)(m.h-bh+y)*m.w + x];
        }
        free(m.px); return o;
    }
}

// `name` may carry "@90/180/270" (rotate) and/or "~N" (trim N px from the
// centre of the longer axis) suffixes, in either order.
static img load_png(const char *dir, const char *name) {
    img m = { 0, 0, 0 };
    char base[256]; int rot = 0, trim = 0;
    snprintf(base, sizeof base, "%s", name);
    const char *sfx;
    if ((sfx = strchr(base, '@'))) rot  = atoi(sfx + 1);
    if ((sfx = strchr(base, '~'))) trim = atoi(sfx + 1);
    for (char *q = base; *q; q++) if (*q == '@' || *q == '~') { *q = 0; break; }
    name = base;

    char path[1024], cmd[1200];
    snprintf(path, sizeof path, "%s/%s.png", dir, name);
    snprintf(cmd, sizeof cmd, "magick identify -format '%%w %%h' '%s' 2>/dev/null", path);
    FILE *p = popen(cmd, "r");
    if (!p || fscanf(p, "%d %d", &m.w, &m.h) != 2) { if (p) pclose(p); fprintf(stderr, "missing %s\n", path); exit(1); }
    pclose(p);
    if (rot == 90 || rot == 270) { int t = m.w; m.w = m.h; m.h = t; }   // dims swap

    unsigned char *raw = malloc((size_t)m.w * m.h * 4);
    if (rot) snprintf(cmd, sizeof cmd, "magick '%s' -rotate %d -depth 8 RGBA:- 2>/dev/null", path, rot);
    else     snprintf(cmd, sizeof cmd, "magick '%s' -depth 8 RGBA:- 2>/dev/null", path);
    p = popen(cmd, "r");
    size_t need = (size_t)m.w * m.h * 4;
    if (!p || fread(raw, 1, need, p) != need) { fprintf(stderr, "decode %s\n", path); exit(1); }
    pclose(p);
    m.px = malloc((size_t)m.w * m.h * sizeof(unsigned));
    for (int i = 0; i < m.w * m.h; i++) {              // RGBA bytes -> 0xRRGGBBAA
        unsigned char *b = raw + i*4;
        m.px[i] = ((unsigned)b[0]<<24) | ((unsigned)b[1]<<16) | ((unsigned)b[2]<<8) | b[3];
    }
    free(raw);
    if (trim) m = trim_center(m, trim);
    return m;
}

static void blit(img *dst, const img *src, int dx, int dy) {
    for (int y = 0; y < src->h; y++) for (int x = 0; x < src->w; x++)
        dst->px[(size_t)(dy+y)*dst->w + (dx+x)] = src->px[(size_t)y*src->w + x];
}

typedef struct { char name[64]; img sub; int l,t,r,b; const char *fill; } elem;

// Compose an element's slices (already loaded) into one sub-image + insets.
static elem compose(const char *name, const char *type, img *s, int n) {
    elem e; memset(&e, 0, sizeof e); snprintf(e.name, sizeof e.name, "%s", name);
    e.fill = "stretch";
    if (!strcmp(type, "sprite")) { e.sub = s[0]; e.fill = "none"; return e; }
    if (!strcmp(type, "h3")) {                         // left center right
        int W = s[0].w + s[1].w + s[2].w, H = s[0].h > s[2].h ? s[0].h : s[2].h;
        if (s[1].h > H) H = s[1].h;
        e.sub.w = W; e.sub.h = H; e.sub.px = calloc((size_t)W*H, sizeof(unsigned));
        blit(&e.sub, &s[0], 0, 0); blit(&e.sub, &s[1], s[0].w, 0); blit(&e.sub, &s[2], s[0].w+s[1].w, 0);
        e.l = s[0].w; e.r = s[2].w; e.t = e.b = 0; return e;
    }
    if (!strcmp(type, "v3")) {                         // top center bottom
        int H = s[0].h + s[1].h + s[2].h, W = s[0].w > s[2].w ? s[0].w : s[2].w;
        if (s[1].w > W) W = s[1].w;
        e.sub.w = W; e.sub.h = H; e.sub.px = calloc((size_t)W*H, sizeof(unsigned));
        blit(&e.sub, &s[0], 0, 0); blit(&e.sub, &s[1], 0, s[0].h); blit(&e.sub, &s[2], 0, s[0].h+s[1].h);
        e.t = s[0].h; e.b = s[2].h; e.l = e.r = 0; return e;
    }
    if (!strcmp(type, "nine")) {                       // tl tc tr cl cc cr bl bc br
        int lw = s[0].w, cw = s[1].w, rw = s[2].w;
        int th = s[0].h, ch = s[3].h, bh = s[6].h;
        int W = lw+cw+rw, H = th+ch+bh;
        e.sub.w = W; e.sub.h = H; e.sub.px = calloc((size_t)W*H, sizeof(unsigned));
        int cx[3] = { 0, lw, lw+cw }, cy[3] = { 0, th, th+ch };
        for (int i = 0; i < 9; i++) blit(&e.sub, &s[i], cx[i%3], cy[i/3]);
        e.l = lw; e.r = rw; e.t = th; e.b = bh; return e;
    }
    fprintf(stderr, "unknown type %s\n", type); exit(1);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: themepack <res-dir> <recipe> <out-dir>\n"); return 1; }
    const char *res = argv[1], *recipe = argv[2], *out = argv[3];
    FILE *rf = fopen(recipe, "r"); if (!rf) { perror(recipe); return 1; }

    elem el[128]; int ne = 0;
    char line[2048];
    while (fgets(line, sizeof line, rf)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char name[64], type[16], *p = line;
        if (sscanf(p, "%63s %15s", name, type) != 2) continue;
        p += strlen(name); while (*p==' ') p++; p += strlen(type);
        img s[9]; int n = 0; char file[128];
        while (n < 9 && sscanf(p, "%127s", file) == 1) { s[n++] = load_png(res, file); p += (strstr(p, file) - p) + strlen(file); }
        el[ne++] = compose(name, type, s, n);
    }
    fclose(rf);

    // Pack: each element on its own row (simple, no overlap).  1px gaps.
    int aw = 0, ah = 0;
    for (int i = 0; i < ne; i++) { if (el[i].sub.w > aw) aw = el[i].sub.w; ah += el[i].sub.h + 1; }
    img atlas; atlas.w = aw; atlas.h = ah; atlas.px = calloc((size_t)aw*ah, sizeof(unsigned));
    int ax[128], ay[128], y = 0;
    for (int i = 0; i < ne; i++) { ax[i] = 0; ay[i] = y; blit(&atlas, &el[i].sub, 0, y); y += el[i].sub.h + 1; }

    char path[1024];
    snprintf(path, sizeof path, "%s/artwork.tex", out);
    FILE *tf = fopen(path, "wb"); if (!tf) { perror(path); return 1; }
    unsigned w = aw, h = ah; fwrite("GTEX",1,4,tf); fwrite(&w,4,1,tf); fwrite(&h,4,1,tf);
    fwrite(atlas.px, sizeof(unsigned), (size_t)aw*ah, tf); fclose(tf);

    snprintf(path, sizeof path, "%s/locations.txt", out);
    FILE *lf = fopen(path, "w");
    fprintf(lf, "# name x y w h  l t r b  fill\n");
    for (int i = 0; i < ne; i++)
        fprintf(lf, "%-22s %d %d %d %d  %d %d %d %d  %s\n", el[i].name,
                ax[i], ay[i], el[i].sub.w, el[i].sub.h, el[i].l, el[i].t, el[i].r, el[i].b, el[i].fill);
    fclose(lf);

    snprintf(path, sizeof path, "%s/theme.ini", out);
    FILE *cf = fopen(path, "w");
    fprintf(cf, "fg=282828\nhighlight=3875D6\nsel_bg=99CCFF\nborder=D9D9D3\ndisabled=A0A0A0\n");
    fclose(cf);

    printf("themepack: %d elements, atlas %dx%d -> %s\n", ne, aw, ah, out);
    return 0;
}
