// theme_window_demo.c — the Aristo2 theme showcase: a real themed window
// containing every baked widget, most shown in several states, all rendered
// through the 9-slice engine (vr_transfer_bits VR_OVER) with VDI text on top.
// Shown 1:1 in an SDL window (Esc / close to quit); `--ppm` dumps a screenshot.

#include "theme.h"
#include "font.h"
#include <stdio.h>
#include <string.h>
#include <SDL2/SDL.h>

#define WIN_W 820
#define WIN_H 600

static theme TH;
static int H;
static font_face *FF;

static const theme_slice *g(const char *n) { return theme_find(&TH, n); }
static void d9(const char *n, int x, int y, int w, int h) { theme_blit(H, &TH, g(n), x, y, w, h); }
static void spr(const char *n, int x, int y) { const theme_slice *s=g(n); if(s) theme_blit(H,&TH,s,x,y,s->sw,s->sh); }
static int  sw(const char *n){ const theme_slice *s=g(n); return s?s->sw:0; }
static int  sh(const char *n){ const theme_slice *s=g(n); return s?s->sh:0; }
static void lab(int x,int y,const char *s){ vst_color(H,1); vst_height(H,13,0,0,0,0); v_gtext(H,x,y,s); }
static void hdr(int x,int y,const char *s){ vst_color(H,9); vst_height(H,11,0,0,0,0); v_gtext(H,x,y,s); }

// A push button sized to its label; returns its width.
static int btn(const char *variant, int x, int y, const char *l) {
    const theme_slice *s=g(variant); int h=s?s->sh:24, w=font_text_width(font_at(FF,14),l)+26;
    theme_blit(H,&TH,s,x,y,w,h);
    vst_color(H, strstr(variant,"disabled")?9:1); vst_height(H,14,0,0,0,0);
    vst_alignment(H,VDI_TA_CENTER,VDI_TA_HALF,0,0); v_gtext(H,x+w/2,y+h/2,l);
    vst_alignment(H,VDI_TA_LEFT,VDI_TA_TOP,0,0);
    return w;
}
// A label-in-field helper (popup/combo/textfield) at a fixed width; h==0 = the
// element's natural height.  (x,y,w,h) is the *content* box: a focus variant's
// glow ring draws outward from it (the focused bezel is larger than the base),
// so all states share one content box.  The ring is derived from how much the
// variant's 9-slice insets exceed the base element's.
static void field(const char *variant, int x, int y, int w, int h, const char *l, int dim) {
    if(!h) h=sh(variant); if(!h) h=24;
    char base[40]; snprintf(base,sizeof base,"%s",variant);
    char *dot=strchr(base,'.'); if(dot)*dot=0;
    const theme_slice *b=g(base), *v=g(variant);
    int rl=0,rt=0,rr=0,rb=0;
    if(b && v && strcmp(base,variant)) {             // a state variant: find its ring
        rl=v->l-b->l; rr=v->r-b->r;
        if(b->t||b->b){ rt=v->t-b->t; rb=v->b-b->b; } else { rt=rb=(v->sh-b->sh)/2; }
        if(rl<0)rl=0; if(rt<0)rt=0; if(rr<0)rr=0; if(rb<0)rb=0;
    }
    d9(variant, x-rl, y-rt, w+rl+rr, h+rt+rb);
    vst_color(H,dim?9:1); vst_height(H,13,0,0,0,0); v_gtext(H,x+8,y+h/2-7,l);
}

static void draw(gfx_surface *d) {
    for (int i=0;i<WIN_W*WIN_H;i++) d->px[i]=GFX_RGB(232,234,236);

    // ---- outer window ----
    int wx=10, wy=10, ww=WIN_W-20, wh=WIN_H-20, th=sh("titlebar");
    d9("window", wx, wy, ww, wh);
    d9("titlebar", wx, wy, ww, th);
    spr("close", wx+10, wy+(th-16)/2); spr("minimize", wx+30, wy+(th-16)/2); spr("maximize", wx+50, wy+(th-16)/2);
    vst_color(H,1); vst_height(H,15,0,0,0,0); vst_alignment(H,VDI_TA_CENTER,VDI_TA_HALF,0,0);
    v_gtext(H, wx+ww/2, wy+th/2, "Aristo2 — GEM Theme"); vst_alignment(H,VDI_TA_LEFT,VDI_TA_TOP,0,0);

    int c1=34, c2=304, c3=566, y0=wy+th+22;

    // ===== column 1 =====
    int y=y0;
    hdr(c1,y,"BUTTONS"); y+=12;
    int bx=c1;
    bx += btn("button",bx,y,"Normal")+8;
    bx += btn("button.selected",bx,y,"Default")+8;
    btn("button.disabled",bx,y,"Disabled");
    y+=42;
    hdr(c1,y,"CHECKBOX"); y+=14;
    spr("check",c1,y); lab(c1+24,y+2,"off"); spr("check.selected",c1+70,y); lab(c1+94,y+2,"on");
    spr("check.mixed",c1+140,y); lab(c1+164,y+2,"mixed"); spr("check.pressed",c1+220,y); lab(c1+244,y+2,"pressed");
    y+=32;
    hdr(c1,y,"RADIO"); y+=14;
    spr("radio",c1,y); lab(c1+24,y+2,"off"); spr("radio.selected",c1+70,y); lab(c1+94,y+2,"on");
    spr("radio.pressed",c1+140,y); lab(c1+164,y+2,"pressed");
    y+=34;
    hdr(c1,y,"MENU"); y+=12;
    int mw=180, mh=96; d9("menu",c1,y,mw,mh);
    vst_height(H,14,0,0,0,0); const char *it[]={"New","Open","Save","Quit"};
    for(int i=0;i<4;i++){ vst_color(H,1); v_gtext(H,c1+26,y+10+i*20,it[i]); }
    spr("menu.tick",c1+7,y+30);
    y+=mh+18;
    hdr(c1,y,"TABLE HEADER"); y+=12;
    field("header",c1,y,120,0,"Column",0); field("header.pressed",c1+122,y,120,0,"Sorted",0);

    // ===== column 2 (uniform field height = the popup/combo row height) =====
    int fh = sh("popup"); if (fh < 1) fh = 25;
    y=y0;
    hdr(c2,y,"POPUP"); y+=14;
    field("popup",c2,y,150,fh,"Choose…",0); y+=fh+10;
    field("popup.disabled",c2,y,150,fh,"Disabled",1); y+=fh+18;
    hdr(c2,y,"COMBO"); y+=14;
    field("combo",c2,y,170,fh,"Editable",0); y+=fh+8;
    field("combo.focused",c2,y,170,fh,"Focused",0); y+=fh+8;
    field("combo.disabled",c2,y,170,fh,"Disabled",1); y+=fh+18;
    hdr(c2,y,"TEXT FIELD"); y+=14;
    field("textfield",c2,y,170,fh,"normal",0); y+=fh+6;
    field("textfield.focused",c2,y,170,fh,"focused",0); y+=fh+6;
    field("textfield.disabled",c2,y,170,fh,"disabled",1); y+=fh+18;
    hdr(c2,y,"STEPPER"); y+=12;
    d9("stepper.up",c2,y,30,sh("stepper.up")); d9("stepper.down",c2,y+sh("stepper.up"),30,sh("stepper.down"));

    // ===== column 3 =====
    y=y0;
    hdr(c3,y,"SLIDERS"); y+=18;
    d9("slider.htrack",c3,y,180,sh("slider.htrack"));
    spr("slider.knob",c3+60,y+sh("slider.htrack")/2-sh("slider.knob")/2);
    spr("slider.knob.hi",c3+130,y+sh("slider.htrack")/2-sh("slider.knob")/2);
    y+=30;
    d9("slider.vtrack",c3,y,sw("slider.vtrack"),110);
    spr("slider.knob",c3+sw("slider.vtrack")/2-sw("slider.knob")/2,y+70);
    spr("slider.circular",c3+50,y+8);
    spr("slider.circular.knob",c3+50+sw("slider.circular")/2-sw("slider.circular.knob")/2,y+12);
    y+=130;
    hdr(c3,y,"SCROLLBARS"); y+=16;
    int trk=sw("vscroll.track"), vbh=150;            // centre arrows + thumb on the track
    int vax=c3+(trk-sw("vscroll.up"))/2, vtx=c3+(trk-sw("vscroll.thumb"))/2;
    spr("vscroll.up",vax,y);
    d9("vscroll.track",c3,y+sh("vscroll.up"),trk,vbh-sh("vscroll.up")-sh("vscroll.down"));
    spr("vscroll.down",vax,y+vbh-sh("vscroll.down"));
    d9("vscroll.thumb",vtx,y+40,sw("vscroll.thumb"),60);
    // horizontal: the legacy track is 14px tall; centre arrows + thumb vertically on it
    int hx=c3+30, htk=sh("hscroll.track"), hw=150;
    int hay=y+(htk-sh("hscroll.left")+1)/2, hty=y+(htk-sh("hscroll.thumb"))/2;  // arrows: round to track centre
    spr("hscroll.left",hx,hay);
    d9("hscroll.track",hx+sw("hscroll.left"),y,hw-sw("hscroll.left")-sw("hscroll.right"),htk);
    spr("hscroll.right",hx+hw-sw("hscroll.right"),hay);
    d9("hscroll.thumb",hx+44,hty,60,sh("hscroll.thumb"));
    y+=vbh+10;
    hdr(c3,y,"TITLEBAR  active / inactive"); y+=14;
    d9("titlebar",c3,y,180,th);  lab(c3+8,y+th/2-7,"active");
    d9("titlebar.inactive",c3,y+th+4,180,th); lab(c3+8,y+th+4+th/2-7,"inactive");
}

int main(int argc, char **argv) {
    gfx_surface *desk=gfx_surface_alloc(WIN_W,WIN_H);
    vdi_init(desk); H=v_opnvwk(desk);
    FF=font_face_open("fonts/AovelSansRounded.ttf"); if(FF)font_face_set_tracking(FF,1); vdi_set_face(FF);
    if (theme_load(&TH,"themes/Aristo2/1x")!=0){fprintf(stderr,"theme load failed (make themepack)\n");return 1;}

    if (argc>1 && !strcmp(argv[1],"--ppm")) {
        draw(desk);
        FILE *f=fopen("/tmp/theme_window.ppm","wb"); fprintf(f,"P6\n%d %d\n255\n",WIN_W,WIN_H);
        for(int i=0;i<WIN_W*WIN_H;i++){uint32_t v=desk->px[i];unsigned char c[3]={v>>24,v>>16,v>>8};fwrite(c,1,3,f);}
        fclose(f); return 0;
    }
    if (SDL_Init(SDL_INIT_VIDEO)!=0){fprintf(stderr,"SDL: %s\n",SDL_GetError());return 1;}
    SDL_Window *win=SDL_CreateWindow("GEM theme — Aristo2 showcase",
        SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,WIN_W,WIN_H,SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren=SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    SDL_Texture *tex=SDL_CreateTexture(ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    int run=1,dirty=1;
    while(run){ SDL_Event e;
        while(SDL_PollEvent(&e)) if(e.type==SDL_QUIT||(e.type==SDL_KEYDOWN&&e.key.keysym.sym==SDLK_ESCAPE))run=0;
        if(dirty){draw(desk);dirty=0;}
        SDL_UpdateTexture(tex,NULL,desk->px,desk->stride*(int)sizeof(uint32_t));
        int ow=WIN_W,oh=WIN_H; SDL_GetRendererOutputSize(ren,&ow,&oh);
        SDL_Rect ds={(ow-WIN_W)/2,(oh-WIN_H)/2,WIN_W,WIN_H};
        SDL_SetRenderDrawColor(ren,0,0,0,255); SDL_RenderClear(ren);
        SDL_RenderCopy(ren,tex,NULL,&ds); SDL_RenderPresent(ren); SDL_Delay(16);
    }
    theme_free(&TH); if(FF)font_face_close(FF); gfx_surface_free(desk);
    SDL_DestroyTexture(tex); SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
