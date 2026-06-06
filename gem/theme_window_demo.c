// theme_window_demo.c — render a window dressed in the real Aristo2 theme:
// titlebar + window controls + frame, with buttons / checkbox / radio / text
// field inside, text drawn through the VDI.  Proves the baked atlas + 9-slice
// engine on actual artwork.

#include "theme.h"
#include "font.h"
#include <stdio.h>

static theme TH;
static int H;                                          // the VDI workstation

static void putppm(const char *p, gfx_surface *s) {
    FILE *f = fopen(p, "wb"); fprintf(f, "P6\n%d %d\n255\n", s->w, s->h);
    for (int i = 0; i < s->w * s->h; i++) { uint32_t v = s->px[i];
        unsigned char c[3] = { v>>24, v>>16, v>>8 }; fwrite(c, 1, 3, f); }
    fclose(f);
}
static void sprite(const char *name, int x, int y) {   // draw at natural size
    const theme_slice *s = theme_find(&TH, name);
    if (s) theme_blit(H, &TH, s, x, y, s->sw, s->sh);
}
static int text_w(const char *s, int px) { return font_text_width(font_at(font_face_open("fonts/AovelSansRounded.ttf"), px), s); }

static void label(int x, int y, const char *s) { vst_color(H,1); v_gtext(H, x, y, s); }

// A themed push button sized to its label; returns its width.
static int button(const char *variant, int x, int y, const char *lbl) {
    const theme_slice *s = theme_find(&TH, variant);
    int h = s ? s->sh : 24, w = text_w(lbl, 15) + 28;
    theme_blit(H, &TH, s, x, y, w, h);
    vst_color(H,1); vst_height(H,15,0,0,0,0);
    vst_alignment(H, VDI_TA_CENTER, VDI_TA_HALF, 0,0);
    v_gtext(H, x + w/2, y + h/2, lbl);
    vst_alignment(H, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
    return w;
}

int main(void) {
    gfx_surface *d = gfx_surface_alloc(440, 300);
    for (int i = 0; i < 440*300; i++) d->px[i] = GFX_RGB(236,238,240);
    vdi_init(d); H = v_opnvwk(d);
    font_face *ff = font_face_open("fonts/AovelSansRounded.ttf");
    font_face_set_tracking(ff, 1); vdi_set_face(ff);

    if (theme_load(&TH, "themes/Aristo2/1x") != 0) { fprintf(stderr, "theme load failed\n"); return 1; }

    // ---- a window: frame + titlebar + controls ----
    int wx = 30, wy = 26, ww = 380, wh = 240, th = 0;
    const theme_slice *head = theme_find(&TH, "titlebar");
    th = head ? head->sh : 24;
    theme_draw(H, &TH, "window", wx, wy, ww, wh);                 // 9-slice frame
    theme_blit(H, &TH, head, wx, wy, ww, th);                     // titlebar strip
    sprite("close", wx + 8, wy + (th-16)/2);
    sprite("minimize", wx + 28, wy + (th-16)/2);
    sprite("maximize", wx + 48, wy + (th-16)/2);
    vst_color(H,1); vst_height(H,15,0,0,0,0);
    vst_alignment(H, VDI_TA_CENTER, VDI_TA_HALF, 0,0);
    v_gtext(H, wx + ww/2, wy + th/2, "Aristo2 Window");
    vst_alignment(H, VDI_TA_LEFT, VDI_TA_TOP, 0,0);

    // ---- contents ----
    int cx = wx + 24, cy = wy + th + 24;
    vst_height(H,15,0,0,0,0);
    sprite("check.selected", cx, cy);        label(cx+28, cy+3, "Enabled option");
    sprite("radio.selected", cx, cy+34);     label(cx+28, cy+37, "Selected radio");
    // a text field
    const theme_slice *tf = theme_find(&TH, "textfield");
    theme_blit(H, &TH, tf, cx, cy+72, 220, 26);
    vst_color(H,1); v_gtext(H, cx+8, cy+78, "text field");
    // buttons along the bottom
    int by = wy + wh - 50;
    int bw = button("button.disabled", wx + 24, by, "Disabled");
    int b2 = button("button", wx + 40 + bw, by, "Cancel");
    button("button.selected", wx + 56 + bw + b2, by, "Accept");

    putppm("/tmp/theme_window.ppm", d);
    theme_free(&TH);
    return 0;
}
