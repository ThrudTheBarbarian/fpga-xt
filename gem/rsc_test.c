// rsc_test.c — headless self-test for the SHARED GEM .rsc engine
// (../fpga-gem/src/rsc.c) + the AES bridge (aes/rscload.c).  No SDL: sets up a
// software VDI + AES + theme like menu_test, then
//   (a) rsc_read the mkrsc-authored desktop.rsc and ASSERT the New dialog's
//       structure (root G_BOX; a G_RADIO pair sharing the root; a G_POPUP whose
//       linked-tree high byte == 1; an editable G_FTEXT; OK w/ OF_DEFAULT +
//       Cancel w/ OF_CANCEL; sane post-obfix coords),
//   (b) render the New dialog centred to /tmp/xtdesk-rsc.ppm THROUGH the bridge
//       (ob_type masked, CICONs decoded), and
//   (c) round-trip rsc_read -> rsc_write -> rsc_read and assert the two written
//       byte streams are identical (deterministic writer) and the two models
//       structurally identical.

#include "aes/aes_internal.h"
#include "aes/rscload.h"     // bridge + (via it) rsc.h engine + aes.h
#include "font.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

gfx_surface *vdi_screen_target(void);   // physical workstation surface (VDI core)

#define WIN_W 520
#define WIN_H 320

static int g_fail;
#define CHECK(cond, msg) do { if (!(cond)) { \
    printf("FAIL: %s  (%s:%d)\n", (msg), __FILE__, __LINE__); g_fail++; } \
    else printf("ok:   %s\n", (msg)); } while (0)

// ---- helpers --------------------------------------------------------------
static long slurp(const char *path, unsigned char **out) {
    *out = NULL;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return -1; }
    unsigned char *b = (unsigned char *)malloc((size_t)n);
    if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) { free(b); fclose(f); return -1; }
    fclose(f);
    *out = b;
    return n;
}

// base global index of tree `i`, and its object count (trees are contiguous).
static int tree_base(RSC *r, int i) {
    RSC_OBJECT *flat = rsc_objects(r, NULL);
    return (int)(rsc_tree(r, i) - flat);
}
static int tree_nobs(RSC *r, int i) {
    int total = 0; rsc_objects(r, &total);
    int b = tree_base(r, i);
    int nxt = (i + 1 < rsc_ntrees(r)) ? tree_base(r, i + 1) : total;
    return nxt - b;
}

static const char *ospec_str(const RSC_OBJECT *o) {
    switch (o->ob_type & 0xFF) {
        case G_STRING: case G_BUTTON: case G_TITLE:
        case G_CHECKBOX: case G_RADIO: case G_POPUP:
            return o->ob_spec ? (const char *)o->ob_spec : "";
        default: return "";
    }
}

// full structural compare of two raw engine models (both keep the high byte).
static int raw_identical(RSC *a, RSC *b) {
    int na = 0, nb = 0;
    RSC_OBJECT *oa = rsc_objects(a, &na), *ob = rsc_objects(b, &nb);
    if (na != nb || rsc_ntrees(a) != rsc_ntrees(b)) return 0;
    for (int i = 0; i < na; i++) {
        if (oa[i].ob_type != ob[i].ob_type) return 0;     // incl. the high byte
        if (oa[i].ob_flags != ob[i].ob_flags || oa[i].ob_state != ob[i].ob_state) return 0;
        if (oa[i].ob_x != ob[i].ob_x || oa[i].ob_y != ob[i].ob_y ||
            oa[i].ob_w != ob[i].ob_w || oa[i].ob_h != ob[i].ob_h) return 0;
        if (oa[i].ob_next != ob[i].ob_next || oa[i].ob_head != ob[i].ob_head ||
            oa[i].ob_tail != ob[i].ob_tail) return 0;
        if (strcmp(ospec_str(&oa[i]), ospec_str(&ob[i])) != 0) return 0;
    }
    return 1;
}

// ---- (a) structure asserts on the raw New tree ----------------------------
static void assert_new_dialog(RSC *r, rscdoc *d) {
    printf("--- New dialog structure ------------------------------\n");
    CHECK(rsc_ntrees(r) >= 3, "resource has the New/Type/Confirm trees");
    RSC_OBJECT *nw = rsc_tree(r, 0);
    int n = tree_nobs(r, 0);
    CHECK(nw != NULL && n > 0, "tree 0 (New) loads");
    CHECK((nw[0].ob_type & 0xFF) == G_BOX, "root is a G_BOX");
    CHECK(nw[0].ob_w == 360 && nw[0].ob_h == 220, "root coords sane post-obfix (360x220)");

    int nradio = 0, npopup = -1, nfield = -1, nok = -1, ncancel = -1;
    for (int i = 0; i < n; i++) {
        switch (nw[i].ob_type & 0xFF) {
            case G_RADIO:
                nradio++;
                CHECK((nw[i].ob_flags & OF_RBUTTON) != 0, "radio has OF_RBUTTON");
                break;
            case G_POPUP: npopup = i; break;
            case G_FTEXT: if (nw[i].ob_flags & OF_EDITABLE) nfield = i; break;
            case G_BUTTON:
                if (nw[i].ob_flags & OF_DEFAULT) nok = i;
                if (nw[i].ob_flags & OF_CANCEL)  ncancel = i;
                break;
            default: break;
        }
    }
    CHECK(nradio == 2, "exactly two radio buttons (Folder/File)");
    int under_root = 0;
    for (int c = nw[0].ob_head; c >= 0; c = (c == nw[0].ob_tail ? -1 : nw[c].ob_next))
        if ((nw[c].ob_type & 0xFF) == G_RADIO) under_root++;
    CHECK(under_root == 2, "the radio pair shares the root as parent (same group)");

    CHECK(npopup >= 0, "a G_POPUP exists");
    if (npopup >= 0) {
        CHECK(((nw[npopup].ob_type >> 8) & 0xFF) == 1,
              "the popup's linked-tree high byte == 1 (Type menu)");
        CHECK(rscload_ext(d, 0, npopup) == 1,
              "the bridge reports the same popup link (rscload_ext == 1)");
        CHECK(nw[npopup].ob_spec && !strcmp((char *)nw[npopup].ob_spec, ".txt"),
              "the popup's current value is \".txt\"");
    }
    CHECK(nfield >= 0, "an editable G_FTEXT field exists");
    if (nfield >= 0) {
        TEDINFO *te = (TEDINFO *)nw[nfield].ob_spec;
        CHECK(te && te->te_ptmplt && strchr(te->te_ptmplt, '_'),
              "the field's TEDINFO has an underscore template");
    }
    CHECK(nok >= 0, "OK button has OF_DEFAULT");
    CHECK(ncancel >= 0, "Cancel button has OF_CANCEL");
    if (nok >= 0)     CHECK(!strcmp((char *)nw[nok].ob_spec, "OK"), "OK button label");
    if (ncancel >= 0) CHECK(!strcmp((char *)nw[ncancel].ob_spec, "Cancel"), "Cancel button label");
}

// ---- (b) render the New dialog centred, dump a PPM ------------------------
static void render_new(rscdoc *d) {
    gfx_surface *scr = vdi_screen_target();
    for (int i = 0; i < scr->w * scr->h; i++) scr->px[i] = GFX_RGB(64, 86, 114);
    int HV = aes_handle();
    vst_color(HV, 0); vst_height(HV, 15, 0, 0, 0, 0);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0, 0);
    v_gtext(HV, 16, 12, "rsc_test — New dialog loaded from desktop.rsc");

    OBJECT *nw = rscload_tree(d, 0);            // bridge: ob_type masked, ready to draw
    int w = nw[0].ob_w, h = nw[0].ob_h;
    nw[0].ob_x = (WIN_W - w) / 2;
    nw[0].ob_y = (WIN_H - h) / 2;
    objc_draw(nw, 0, 8, 0, 0, WIN_W, WIN_H);

    FILE *f = fopen("/tmp/xtdesk-rsc.ppm", "wb");
    if (!f) { perror("fopen"); return; }
    fprintf(f, "P6\n%d %d\n255\n", WIN_W, WIN_H);
    for (int i = 0; i < WIN_W * WIN_H; i++) {
        uint32_t v = scr->px[i];
        unsigned char c[3] = { (unsigned char)(v >> 24), (unsigned char)(v >> 16), (unsigned char)(v >> 8) };
        fwrite(c, 1, 3, f);
    }
    fclose(f);
    printf("\nwrote /tmp/xtdesk-rsc.ppm (%dx%d)\n", WIN_W, WIN_H);
}

// ---- (c) round-trip: rsc_read -> rsc_write -> rsc_read --------------------
static void roundtrip(const unsigned char *orig, long olen) {
    printf("--- round-trip (rsc_read -> rsc_write -> rsc_read) ----\n");
    const char *err = NULL;
    RSC *a = rsc_read(orig, (size_t)olen, &err);
    CHECK(a != NULL, "rsc_read the source image");
    if (!a) return;

    uint8_t *b1 = NULL; size_t l1 = 0;
    CHECK(rsc_write(a, &b1, &l1, &err) == 0 && b1 && l1 > 0, "rsc_write the model to memory");

    RSC *b = b1 ? rsc_read(b1, l1, &err) : NULL;
    CHECK(b != NULL, "rsc_read the written image back");

    uint8_t *b2 = NULL; size_t l2 = 0;
    CHECK(b && rsc_write(b, &b2, &l2, &err) == 0 && b2, "rsc_write the reloaded model");

    CHECK(b1 && b2 && l1 == l2 && !memcmp(b1, b2, l1),
          "the two written .rsc byte streams are identical (deterministic writer)");
    CHECK(b && raw_identical(a, b), "the two models are structurally identical");
    printf("      (image size: %zu bytes)\n", l1);

    free(b1); free(b2);
    rsc_free(a); if (b) rsc_free(b);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "resources/desktop.rsc";

    gfx_surface *desk = gfx_surface_alloc(WIN_W, WIN_H);
    vdi_init(desk);
    int HV = v_opnvwk(desk);
    font_face *ff = font_face_open("fonts/AovelSansRounded.ttf");
    if (ff) font_face_set_tracking(ff, 1);
    vdi_set_face(ff);
    static theme TH;
    if (theme_load(&TH, "themes/Aristo2/1x")) {
        fprintf(stderr, "theme load failed (run: make -C gem themepack)\n");
        return 1;
    }
    aes_init(HV, &TH);
    appl_init();

    printf("=== rsc engine + bridge self-test =====================\n");
    printf("loading %s\n", path);
    unsigned char *bytes = NULL;
    long len = slurp(path, &bytes);
    if (len <= 0) {
        fprintf(stderr, "FAIL: could not read %s (run: make -C gem mkrsc)\n", path);
        return 1;
    }
    const char *err = NULL;
    RSC *raw = rsc_read(bytes, (size_t)len, &err);
    rscdoc *doc = rscload_mem(bytes, (size_t)len, &err);
    if (!raw || !doc) {
        fprintf(stderr, "FAIL: could not parse %s (%s)\n", path, err ? err : "?");
        return 1;
    }
    printf("loaded %d trees\n", rsc_ntrees(raw));

    assert_new_dialog(raw, doc);
    render_new(doc);

    roundtrip(bytes, len);

    rsc_free(raw);
    rscload_free(doc);
    free(bytes);

    printf("\n%s\n", g_fail ? "SOME TESTS FAILED" : "ALL TESTS PASSED");
    theme_free(&TH); if (ff) font_face_close(ff); gfx_surface_free(desk);
    return g_fail ? 1 : 0;
}
