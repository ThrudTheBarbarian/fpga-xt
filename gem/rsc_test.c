// rsc_test.c — headless self-test for the shared GEM .rsc codec (aes/rsc.c).
// No SDL: sets up a software VDI + AES + theme like menu_test, then
//   (a) rsc_load the mkrsc-authored desktop.rsc and ASSERT the New dialog's
//       structure (root G_BOX; a G_RADIO pair; a G_POPUP with a nonzero linked
//       tree index; an editable field; OK w/ OF_DEFAULT + Cancel w/ OF_CANCEL;
//       sane post-obfix coords),
//   (b) render the New dialog centred to /tmp/xtdesk-rsc.ppm, and
//   (c) round-trip load -> save -> load and assert the two models are
//       structurally identical AND that the two .rsc byte streams match.

#include "aes/aes_internal.h"
#include "aes/rsc.h"
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

// ---- structural comparison of two loaded models ---------------------------
static const char *obj_str(OBJECT *o) {
    switch (o->ob_type) {
        case G_STRING: case G_BUTTON: case G_TITLE:
        case G_CHECKBOX: case G_RADIO: case G_POPUP:
            return o->ob_spec ? (const char *)o->ob_spec : "";
        default: return "";
    }
}
static int models_identical(rsc *a, rsc *b) {
    if (rsc_ntree(a) != rsc_ntree(b)) return 0;
    for (int t = 0; t < rsc_ntree(a); t++) {
        int na = rsc_tree_nobs(a, t), nb = rsc_tree_nobs(b, t);
        if (na != nb) return 0;
        OBJECT *oa = rsc_tree(a, t), *ob = rsc_tree(b, t);
        for (int i = 0; i < na; i++) {
            if (oa[i].ob_type != ob[i].ob_type) return 0;
            if (oa[i].ob_flags != ob[i].ob_flags || oa[i].ob_state != ob[i].ob_state) return 0;
            if (oa[i].ob_x != ob[i].ob_x || oa[i].ob_y != ob[i].ob_y ||
                oa[i].ob_w != ob[i].ob_w || oa[i].ob_h != ob[i].ob_h) return 0;
            if (oa[i].ob_next != ob[i].ob_next || oa[i].ob_head != ob[i].ob_head ||
                oa[i].ob_tail != ob[i].ob_tail) return 0;
            if (strcmp(obj_str(&oa[i]), obj_str(&ob[i])) != 0) return 0;
            if (rsc_popup_link(a, t, i) != rsc_popup_link(b, t, i)) return 0;
        }
    }
    return 1;
}

// ---- render the New dialog centred, dump a PPM ----------------------------
static void render_new(rsc *r) {
    gfx_surface *d = vdi_screen_target();
    for (int i = 0; i < d->w * d->h; i++) d->px[i] = GFX_RGB(64, 86, 114);
    int HV = aes_handle();
    vst_color(HV, 0); vst_height(HV, 15, 0, 0, 0, 0);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0, 0);
    v_gtext(HV, 16, 12, "rsc_test — New dialog loaded from desktop.rsc");

    OBJECT *nw = rsc_tree(r, 0);
    int w = nw[0].ob_w, h = nw[0].ob_h;
    nw[0].ob_x = (WIN_W - w) / 2;
    nw[0].ob_y = (WIN_H - h) / 2;
    objc_draw(nw, 0, 8, 0, 0, WIN_W, WIN_H);

    FILE *f = fopen("/tmp/xtdesk-rsc.ppm", "wb");
    if (!f) { perror("fopen"); return; }
    fprintf(f, "P6\n%d %d\n255\n", WIN_W, WIN_H);
    for (int i = 0; i < WIN_W * WIN_H; i++) {
        uint32_t v = d->px[i];
        unsigned char c[3] = { (unsigned char)(v >> 24), (unsigned char)(v >> 16), (unsigned char)(v >> 8) };
        fwrite(c, 1, 3, f);
    }
    fclose(f);
    printf("\nwrote /tmp/xtdesk-rsc.ppm (%dx%d)\n", WIN_W, WIN_H);
}

static void assert_new_dialog(rsc *r) {
    printf("--- New dialog structure ------------------------------\n");
    CHECK(rsc_ntree(r) >= 3, "resource has the New/Type/Confirm trees");
    OBJECT *nw = rsc_tree(r, 0);
    int n = rsc_tree_nobs(r, 0);
    CHECK(nw != NULL && n > 0, "tree 0 (New) loads");
    CHECK(nw[0].ob_type == G_BOX, "root is a G_BOX");
    CHECK(nw[0].ob_w == 360 && nw[0].ob_h == 220, "root coords sane post-obfix (360x220)");

    int nradio = 0, npopup = -1, nfield = -1, nok = -1, ncancel = -1;
    int radio_parent[2], nr = 0;
    for (int i = 0; i < n; i++) {
        switch (nw[i].ob_type) {
            case G_RADIO:
                nradio++;
                CHECK((nw[i].ob_flags & OF_RBUTTON) != 0, "radio has OF_RBUTTON");
                if (nr < 2) radio_parent[nr++] = nw[i].ob_next;  // last child -> parent idx
                break;
            case G_POPUP: npopup = i; break;
            case G_FTEXT: if (nw[i].ob_flags & OF_EDITABLE) nfield = i; break;
            case G_BUTTON:
                if (nw[i].ob_flags & OF_DEFAULT) nok = i;
                if (nw[i].ob_flags & OF_CANCEL) ncancel = i;
                break;
            default: break;
        }
    }
    CHECK(nradio == 2, "exactly two radio buttons (Folder/File)");
    // both radios sit directly under the root (index 0): each is a middle child
    // whose ob_next is the next sibling, so instead verify via ob_head walk.
    int under_root = 0;
    for (int c = nw[0].ob_head; c >= 0; c = (c == nw[0].ob_tail ? -1 : nw[c].ob_next))
        if (nw[c].ob_type == G_RADIO) under_root++;
    CHECK(under_root == 2, "the radio pair shares the root as parent (same group)");
    (void)radio_parent;

    CHECK(npopup >= 0, "a G_POPUP exists");
    if (npopup >= 0) {
        CHECK(rsc_popup_link(r, 0, npopup) > 0, "the popup has a nonzero linked-tree index");
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

static void roundtrip(const char *src) {
    printf("--- round-trip (load -> save -> load) -----------------\n");
    rsc *a = rsc_load(src);
    CHECK(a != NULL, "reload source resource");
    if (!a) return;

    const char *tmp = "/tmp/xtdesk-rsc-roundtrip.rsc";
    CHECK(rsc_save(a, tmp) == 0, "save the model to a temp .rsc");
    rsc *b = rsc_load(tmp);
    CHECK(b != NULL, "reload the saved .rsc");

    if (b) CHECK(models_identical(a, b), "two models are structurally identical");

    // byte-identity: save both models into memory and compare the streams.
    unsigned char *ba = NULL, *bb = NULL;
    long la = rsc_save_mem(a, &ba), lb = b ? rsc_save_mem(b, &bb) : 0;
    CHECK(la > 0 && la == lb && ba && bb && !memcmp(ba, bb, (size_t)la),
          "two .rsc byte streams are identical (deterministic save)");
    printf("      (image size: %ld bytes)\n", la);
    free(ba); free(bb);

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

    printf("=== rsc codec self-test ===============================\n");
    printf("loading %s\n", path);
    rsc *r = rsc_load(path);
    if (!r) {
        fprintf(stderr, "FAIL: could not load %s (run: make -C gem mkrsc && ./build/mkrsc)\n", path);
        return 1;
    }
    printf("loaded %d trees\n", rsc_ntree(r));

    assert_new_dialog(r);
    render_new(r);
    rsc_free(r);

    roundtrip(path);

    printf("\n%s\n", g_fail ? "SOME TESTS FAILED" : "ALL TESTS PASSED");
    theme_free(&TH); if (ff) font_face_close(ff); gfx_surface_free(desk);
    return g_fail ? 1 : 0;
}
