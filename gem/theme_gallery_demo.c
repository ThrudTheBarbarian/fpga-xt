// theme_gallery_demo.c — a showcase of the baked Aristo2 theme: most widget
// elements drawn through the 9-slice engine, to eyeball the recipe coverage.
// Shown 1:1 in an SDL window (Esc / close to quit).

#include "theme.h"
#include "font.h"
#include <stdio.h>
#include <SDL2/SDL.h>

#define WIN_W 760
#define WIN_H 560

static theme TH;
static int H;

static const theme_slice *g(const char *n) { return theme_find(&TH, n); }
static void d9(const char *n, int x, int y, int w, int h) { theme_blit(H, &TH, g(n), x, y, w, h); }
static void spr(const char *n, int x, int y) { const theme_slice *s = g(n); if (s) theme_blit(H,&TH,s,x,y,s->sw,s->sh); }
static int  sw(const char *n) { const theme_slice *s = g(n); return s ? s->sw : 0; }
static int  sh(const char *n) { const theme_slice *s = g(n); return s ? s->sh : 0; }
static void lab(int x, int y, const char *s) { vst_color(H,1); vst_height(H,13,0,0,0,0); v_gtext(H,x,y,s); }
static void hdr(int x, int y, const char *s) { vst_color(H,9); vst_height(H,12,0,0,0,0); v_gtext(H,x,y,s); }

static void btn(const char *variant, int x, int y, const char *lbl, font_face *ff) {
    const theme_slice *s = g(variant); int h = s?s->sh:24, w = font_text_width(font_at(ff,14),lbl)+28;
    theme_blit(H,&TH,s,x,y,w,h);
    vst_color(H,1); vst_height(H,14,0,0,0,0); vst_alignment(H,VDI_TA_CENTER,VDI_TA_HALF,0,0);
    v_gtext(H,x+w/2,y+h/2,lbl); vst_alignment(H,VDI_TA_LEFT,VDI_TA_TOP,0,0);
}

static void draw(gfx_surface *d, font_face *ff) {
    for (int i=0;i<WIN_W*WIN_H;i++) d->px[i]=GFX_RGB(238,240,242);
    int col1=30, col2=290, col3=540, y;

    // --- buttons ---
    hdr(col1, 16, "BUTTONS");
    btn("button", col1, 28, "Normal", ff);
    btn("button.selected", col1+96, 28, "Default", ff);
    btn("button.disabled", col1+200, 28, "Disabled", ff);

    // --- popup / combo / text field ---
    hdr(col1, 70, "POPUP / COMBO / FIELD");
    d9("popup", col1, 82, 150, sh("popup"));   lab(col1+10, 86, "Popup");
    d9("combo", col1, 116, 150, sh("combo"));  lab(col1+10, 120, "Combo");
    d9("textfield", col1, 150, 150, 24);       lab(col1+8, 156, "text field");

    // --- checks / radios ---
    hdr(col1, 192, "CHECK / RADIO");
    spr("check", col1, 206);            lab(col1+26, 208, "off");
    spr("check.selected", col1+80, 206); lab(col1+106, 208, "on");
    spr("check.mixed", col1+150, 206);  lab(col1+176, 208, "mixed");
    spr("radio", col1, 232);            lab(col1+26, 234, "off");
    spr("radio.selected", col1+80, 232); lab(col1+106, 234, "on");

    // --- menu ---
    hdr(col1, 270, "MENU");
    int mw=170, mh=92; d9("menu", col1, 282, mw, mh);
    vst_color(H,1); vst_height(H,14,0,0,0,0);
    const char *items[]={"New","Open","Save","Quit"};
    for (int i=0;i<4;i++){ if(i==1){vsf_color(H,2);} v_gtext(H,col1+24,288+i*20,items[i]); }
    spr("menu.tick", col1+6, 308);     // tick by "Open"

    // --- sliders (col2) ---
    hdr(col2, 16, "SLIDERS");
    d9("slider.htrack", col2, 36, 180, sh("slider.htrack"));
    spr("slider.knob", col2+110, 36 + sh("slider.htrack")/2 - sh("slider.knob")/2);
    d9("slider.vtrack", col2, 64, sw("slider.vtrack"), 120);
    spr("slider.knob", col2 - sw("slider.knob")/2 + sw("slider.vtrack")/2, 110);
    spr("slider.circular", col2+60, 70);
    spr("slider.circular.knob", col2+60+sw("slider.circular")/2-sw("slider.circular.knob")/2, 74);

    // --- stepper (col2) ---
    hdr(col2, 210, "STEPPER");
    d9("stepper.up", col2, 222, 28, sh("stepper.up"));
    d9("stepper.down", col2, 222+sh("stepper.up"), 28, sh("stepper.down"));

    // --- table header (col2) ---
    hdr(col2, 280, "TABLE HEADER");
    d9("header", col2, 292, 110, sh("header"));         lab(col2+10, 296, "Column");
    d9("header.pressed", col2+114, 292, 110, sh("header")); lab(col2+124, 296, "Sorted");

    // --- vertical scrollbar (col3) ---
    hdr(col3, 16, "SCROLLBARS");
    int vbx=col3, vby=30, vbh=200, aw=sw("vscroll.up");
    spr("vscroll.up", vbx, vby);
    d9("vscroll.track", vbx, vby+sh("vscroll.up"), sw("vscroll.track"), vbh-sh("vscroll.up")-sh("vscroll.down"));
    spr("vscroll.down", vbx, vby+vbh-sh("vscroll.down"));
    d9("vscroll.thumb", vbx, vby+50, sw("vscroll.thumb"), 70);   // thumb over track
    (void)aw;
    // horizontal scrollbar
    int hbx=col3+30, hby=30, hbw=160;
    spr("hscroll.left", hbx, hby);
    d9("hscroll.track", hbx+sw("hscroll.left"), hby, hbw-sw("hscroll.left")-sw("hscroll.right"), sh("hscroll.track"));
    spr("hscroll.right", hbx+hbw-sw("hscroll.right"), hby);
    d9("hscroll.thumb", hbx+50, hby, 70, sh("hscroll.thumb"));

    // --- a framed window at the bottom ---
    y = 360;
    int wx=col1, wy=y, ww=WIN_W-60, wh=180, th=sh("titlebar");
    d9("window", wx, wy, ww, wh);
    d9("titlebar", wx, wy, ww, th);
    spr("close", wx+8, wy+(th-16)/2); spr("minimize", wx+28, wy+(th-16)/2); spr("maximize", wx+48, wy+(th-16)/2);
    vst_color(H,1); vst_height(H,15,0,0,0,0); vst_alignment(H,VDI_TA_CENTER,VDI_TA_HALF,0,0);
    v_gtext(H, wx+ww/2, wy+th/2, "A themed window"); vst_alignment(H,VDI_TA_LEFT,VDI_TA_TOP,0,0);
    lab(wx+24, wy+th+24, "Every widget above is the real Aristo2 art, 9-sliced through vr_transfer_bits.");
    btn("button", wx+ww-200, wy+wh-46, "Cancel", ff);
    btn("button.selected", wx+ww-96, wy+wh-46, "OK", ff);
}

int main(int argc, char **argv) {
    gfx_surface *desk=gfx_surface_alloc(WIN_W,WIN_H);
    vdi_init(desk); H=v_opnvwk(desk);
    font_face *ff=font_face_open("fonts/AovelSansRounded.ttf"); if(ff)font_face_set_tracking(ff,1); vdi_set_face(ff);
    if (theme_load(&TH,"themes/Aristo2/1x")!=0){fprintf(stderr,"theme load failed (make themepack)\n");return 1;}

    if (argc>1 && !strcmp(argv[1],"--ppm")) {           // headless render for screenshots
        draw(desk,ff);
        FILE *f=fopen("/tmp/theme_gallery.ppm","wb"); fprintf(f,"P6\n%d %d\n255\n",WIN_W,WIN_H);
        for(int i=0;i<WIN_W*WIN_H;i++){uint32_t v=desk->px[i];unsigned char c[3]={v>>24,v>>16,v>>8};fwrite(c,1,3,f);}
        fclose(f); return 0;
    }

    if (SDL_Init(SDL_INIT_VIDEO)!=0){fprintf(stderr,"SDL: %s\n",SDL_GetError());return 1;}
    SDL_Window *win=SDL_CreateWindow("GEM theme — Aristo2 gallery",
        SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,WIN_W,WIN_H,SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren=SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    SDL_Texture *tex=SDL_CreateTexture(ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    int run=1,dirty=1;
    while(run){ SDL_Event e;
        while(SDL_PollEvent(&e)) if(e.type==SDL_QUIT||(e.type==SDL_KEYDOWN&&e.key.keysym.sym==SDLK_ESCAPE))run=0;
        if(dirty){draw(desk,ff);dirty=0;}
        SDL_UpdateTexture(tex,NULL,desk->px,desk->stride*(int)sizeof(uint32_t));
        int ow=WIN_W,oh=WIN_H; SDL_GetRendererOutputSize(ren,&ow,&oh);
        SDL_Rect ds={(ow-WIN_W)/2,(oh-WIN_H)/2,WIN_W,WIN_H};
        SDL_SetRenderDrawColor(ren,0,0,0,255); SDL_RenderClear(ren);
        SDL_RenderCopy(ren,tex,NULL,&ds); SDL_RenderPresent(ren); SDL_Delay(16);
    }
    theme_free(&TH); if(ff)font_face_close(ff); gfx_surface_free(desk);
    SDL_DestroyTexture(tex); SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
