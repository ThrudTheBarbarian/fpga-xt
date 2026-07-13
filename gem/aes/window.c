// aes/window.c — the AES window layer: themed frames (9-slice window +
// titlebar + traffic lights), a z-ordered window list, and frame interaction
// (raise / drag / resize / close) caught inside evnt_multi.  The app draws each
// work area through a content callback and reacts to WM_* messages.  On the host
// the whole desktop is redrawn on each change (wind_redraw); the A9 build will
// use the DDR3 backing-store blit instead.

#include "aes/aes_internal.h"
#include "font.h"
#include <string.h>
#include <stdio.h>

#ifdef GEM_XTOS
#include "gemclient.h"                  // client mode: wind_* become messages to gemd
#endif

gfx_surface *vdi_screen_target(void);   // the physical workstation's surface (VDI core)

// ---- one file, two modes (RESPONSIBILITIES.md §5) --------------------------
// LOCAL   single process: this list IS the window system (SDL host, gemd-less XTOS). Unchanged.
// SERVER  gemd: this list IS the window system, for EVERY app on the machine. Chrome is drawn
//         here, and a window's content is BLITTED from the client's backing store — gemd cannot
//         call an app's draw callback, because that pointer is in another address space (§3).
// CLIENT  an app under gemd: wind_* send messages. The local entry keeps only what the app owns
//         — its content callback and its own surface.
// (AES_LOCAL / AES_CLIENT / AES_SERVER are declared in aes.h)
static int g_mode = AES_LOCAL;
static int g_gemfd = -1;                // client mode: the channel to gemd
int aes_mode(void){ return g_mode; }
void aes_server_mode(void){ g_mode = AES_SERVER; }
static void client_paint(int hd,int x,int y,int w,int h);   // draw OUR content -> OUR surface -> damage

// MAXW was 16 PER APP. It is now the SYSTEM-WIDE window count, because the list lives in gemd.
#define MAXW 64
typedef struct {
    int used, kind, x, y, w, h, px,py,pw,ph;   // full rect (+ previous)
    int hidden;                                // lifted into the HW drag-overlay: skip in redraw
    char name[64];
    wind_draw_fn draw; void *ud;
    // ---- the backing store (§3) --------------------------------------------
    // SERVER: gemd's mapping of the client's surface — what it composites, and what lets it
    //   move/top/reveal a window WITHOUT ASKING THE CLIENT ANYTHING.
    // CLIENT: our own mapping — where our VDI draws, with zero IPC.
    // LOCAL:  px == NULL, and draw_one falls back to the content callback. Unchanged.
    gfx_surface surf;                          // stride == CAPACITY width, not extent (§12)
    int      surf_id;                          // a HANDLE. Never an address (§13.1).
    uint32_t surf_gen;                         // stale-damage discard (§11)
    int      client;                           // SERVER: which client slot owns this window
    int      vh;                               // CLIENT: our workstation, opened ONCE on surf (§10)
    wind_draw_fn info; void *infoud;           // W_INFO chrome line
    wind_draw_fn title; void *titleud;         // interactive title renderer (wind_title)
    int titlex, titley, titlew, titleh;        // last title work rect (app-drawable span)
    int ntb, tbglyph[WIND_MAXTB];              // right-side title buttons: count + glyph per button
    int tbx[WIND_MAXTB], tby[WIND_MAXTB], tbw[WIND_MAXTB], tbh[WIND_MAXTB];   // their last screen rects
    int content_w, content_h;                  // app-reported full content size (work coords)
    int scroll_x, scroll_y;                    // current scroll offset (vertical bar drawn)
    int maxed, sx,sy,sw,sh;                    // maximise toggle: flag + the pre-maximise rect
} awin;

#define SB_W      16     // reserved vertical-scrollbar column width
#define SB_ARROW  16     // up/down arrow box height at the track ends
#define SB_MINTH  24     // minimum thumb length so it stays grabbable
#define SB_LINE   40     // arrow-click step (px); wheel notch uses the same

#define WTB_W     20     // title-button box size (the 20x20 brushed-metal disc sprites)
#define WTB_PITCH 26     // horizontal pitch between title buttons (20 wide + 6 gap, like the left pair)

#define SIZER_SZ  18     // bottom-right resize sizer corner (square); reserved from the scrollbar column

static awin g_w[MAXW];          // slot 0 unused (handles are 1-based)
static int  g_z[MAXW], g_nz;    // z-order: g_z[0] bottom .. g_z[nz-1] top
static uint32_t g_deskbg = 0x46566EFF;
static int g_wa[4] = {-1,0,0,0};   // desktop work area (x,y,w,h); x<0 = auto
static int g_top_reserve = 0;       // top strip reserved by chrome (e.g. menu bar)
static int H(void){ return aes_handle(); }

// The desktop work area: what Desktop.app set, else the screen minus reserved
// top chrome.  Window 0 reports it (classic GEM).
static void work_area(int *x,int *y,int *w,int *h){
    if (g_wa[0] >= 0) { *x=g_wa[0]; *y=g_wa[1]; *w=g_wa[2]; *h=g_wa[3]; return; }
    gfx_surface *d = vdi_screen_target();
    *x = 0; *y = g_top_reserve; *w = d?d->w:0; *h = (d?d->h:0) - g_top_reserve;
}
void aes_set_workarea(int x,int y,int w,int h){ g_wa[0]=x; g_wa[1]=y; g_wa[2]=w; g_wa[3]=h; }
void aes_reserve_top(int h){ g_top_reserve = h; }
int  aes_top_reserve(void){ return g_top_reserve; }   // px reserved at the top (menu bar)

static int bw(void){ const theme_slice*s=theme_find(aes_theme(),"window"); return s?s->l:5; }
static int tbh(void){ const theme_slice*s=theme_find(aes_theme(),"titlebar"); return s?s->sh:22; }

void wind_calc(int dir,int kind,int x,int y,int w,int h,int*ox,int*oy,int*ow,int*oh){
    int b=bw(), th=tbh(), inf=(kind&W_INFO)?AES_INFO_H:0;
    // The work area sits BETWEEN the title (top) and the W_INFO footer (bottom):
    // its origin drops only by the title height, and inf is taken off the BOTTOM.
    if(dir==WC_BORDER){ *ox=x-b; *oy=y-th; *ow=w+2*b; *oh=h+th+inf+b; }   // work -> full (info footer)
    else              { *ox=x+b; *oy=y+th; *ow=w-2*b; *oh=h-th-inf-b; }   // full -> work
}

static void spr(const char*n,int x,int y){ const theme_slice*s=theme_find(aes_theme(),n); if(s) theme_blit(H(),aes_theme(),s,x,y,s->sw,s->sh); }
// Titlebar buttons come in an active and an ".inactive" (lighter disc) variant;
// pick the right sprite name for a window's focus state.
static const char* tbvariant(char*buf,size_t n,const char*base,int active){
    if(active) return base;
    snprintf(buf,n,"%s.inactive",base); return buf;
}
// Focus state of the window whose interactive title is being drawn right now, so
// the app's wind_title callback can pick a legible pen: the active title bar is
// dark (see the darkened `titlebar` slice) -> light text; inactive is pale -> dark.
static int g_title_active = 1;
int wind_title_active(void){ return g_title_active; }

// A small diagonal-hatch resize grip glyph (a few 45° lines in PEN_BORDER),
// drawn hugging a bottom corner of the SIZER_SZ box at (gx,gy).  `left`=1 mirrors
// it into the bottom-LEFT corner; else the bottom-RIGHT corner.
static void draw_grip(int gx,int gy,int sz){
    vsl_color(H(),249); vsl_width(H(),1);                 // PEN_BORDER
    for(int i=0;i<3;i++){ int o=5+i*4;                    // three parallel 45° lines
        int16_t p[4]={(int16_t)(gx+sz-1-o),(int16_t)(gy+sz-1),(int16_t)(gx+sz-1),(int16_t)(gy+sz-1-o)};
        v_pline(H(),2,p);
    }
}
static void draw_grip_l(int gx,int gy,int sz){
    vsl_color(H(),249); vsl_width(H(),1);                 // PEN_BORDER, mirrored to bottom-LEFT
    for(int i=0;i<3;i++){ int o=5+i*4;
        int16_t p[4]={(int16_t)gx,(int16_t)(gy+sz-1-o),(int16_t)(gx+o),(int16_t)(gy+sz-1)};
        v_pline(H(),2,p);
    }
}

// A right-side title button, drawn to read as chrome PAIRED with the left
// close/maximize controls (16x16 gradient-circle theme sprites).  If the theme
// carries a sprite for the action ("view" for WTG_CHEVRON, "fit" for WTG_EXPAND)
// we blit it at native size, centred like the left pair — so the theme can add
// `view`/`fit` 16x16 sprites and they upgrade automatically.  Until then we draw
// a steel disc (a ring edge + a mid-steel fill, so it reads as a round button on
// the titlebar, NOT the old square "button" box) topped with a WHITE vector
// glyph: a downward chevron (WTG_CHEVRON, a "view" popup) or a diagonal
// double-headed arrow (WTG_EXPAND, a "fit"/expand action).
static void draw_titlebtn(int bx,int by,int glyph,int active){
    const char *base = glyph==WTG_CHEVRON ? "view" : glyph==WTG_EXPAND ? "fit" : NULL;
    char nb[32]; const char *name = base ? tbvariant(nb,sizeof nb,base,active) : NULL;
    const theme_slice *s = name ? theme_find(aes_theme(),name) : NULL;
    if(s){ theme_blit(H(),aes_theme(),s, bx+(WTB_W-s->sw)/2, by+(WTB_W-s->sh)/2, s->sw, s->sh); return; }
    int cx=bx+WTB_W/2, cy=by+WTB_W/2, r=WTB_W/2-1;
    v_setrgb(H(),251, 108,118,134);                      // steel disc fill
    v_setrgb(H(),252,  70, 78, 92);                      // subtle darker edge ring
    vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
    vsf_color(H(),252); v_circle(H(),cx,cy,r);           // edge ring
    vsf_color(H(),251); v_circle(H(),cx,cy,r-1);         // steel fill inside it
    vsl_color(H(),0); vsl_width(H(),2);                  // WHITE glyph (pen 0)
    if(glyph==WTG_CHEVRON){                               // ⌄ downward chevron
        int16_t p[6]={(int16_t)(cx-4),(int16_t)(cy-2),(int16_t)cx,(int16_t)(cy+2),(int16_t)(cx+4),(int16_t)(cy-2)};
        v_pline(H(),3,p);
    } else if(glyph==WTG_EXPAND){                         // ⤢ diagonal double-headed arrow
        int16_t d[4]={(int16_t)(cx-4),(int16_t)(cy+4),(int16_t)(cx+4),(int16_t)(cy-4)}; v_pline(H(),2,d);
        int16_t h1[6]={(int16_t)(cx+4),(int16_t)cy,(int16_t)(cx+4),(int16_t)(cy-4),(int16_t)cx,(int16_t)(cy-4)}; v_pline(H(),3,h1);
        int16_t h2[6]={(int16_t)(cx-4),(int16_t)cy,(int16_t)(cx-4),(int16_t)(cy+4),(int16_t)cx,(int16_t)(cy+4)}; v_pline(H(),3,h2);
    }
}

// Keep the window reachable: the title bar stays below the menu bar, above the
// work-area bottom, and at least MINVIS px stays on-screen horizontally — so a
// window can never be dragged completely out of reach.
#define MINVIS 72
static void clamp_win(awin *W){
    int wx,wy,ww,wh; work_area(&wx,&wy,&ww,&wh); int th=tbh();
    if (W->y < wy)            W->y = wy;
    if (W->y > wy+wh - th)    W->y = wy+wh - th;
    if (W->x > wx+ww - MINVIS)        W->x = wx+ww - MINVIS;
    if (W->x < wx - (W->w - MINVIS))  W->x = wx - (W->w - MINVIS);
}

// ---- Scrollbar geometry / state -----------------------------------------
// The FULL work rect (before the scrollbar column is reserved).
static void full_work(awin *W,int*x,int*y,int*w,int*h){
    wind_calc(WC_WORK,W->kind,W->x,W->y,W->w,W->h,x,y,w,h);
}
// Is a vertical scrollbar currently needed (content taller than the work area)?
static int vsb_on(awin *W){
    int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
    return W->content_h > wh && wh > 0;
}
// Clamp scroll_y to [0, content_h - work_h] (0 when it all fits).
static void clamp_scroll(awin *W){
    int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
    int maxs = W->content_h - wh; if(maxs<0) maxs=0;
    if(W->scroll_y>maxs) W->scroll_y=maxs;
    if(W->scroll_y<0)    W->scroll_y=0;
    int maxx = W->content_w - ww; if(maxx<0) maxx=0;
    if(W->scroll_x>maxx) W->scroll_x=maxx;
    if(W->scroll_x<0)    W->scroll_x=0;
}
// The work rect handed to the app (WF_WORKXYWH + the content callback): the full
// rect, shrunk by the scrollbar column when the bar is showing.
static void app_work(awin *W,int*x,int*y,int*w,int*h){
    full_work(W,x,y,w,h);
    if(vsb_on(W)){ *w -= SB_W; if(*w<0) *w=0; }
}
// Vertical-scrollbar sub-geometry (all outputs optional): the reserved column,
// the up/down arrow boxes, the track between them, and the proportional thumb.
// Returns 1 when a bar is shown.  Coordinates are absolute (screen) px.
static int vsb_geom(awin *W,int*colx,int*coly,int*colw,int*colh,
                    int*upy,int*dny,int*arrh,
                    int*trky,int*trkh,int*thy,int*thh){
    if(!vsb_on(W)) return 0;
    int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh);
    // The scrollbar column spans the FULL work-area height: the resize sizer now
    // lives in the W_INFO footer BELOW the work area, so there is no longer a
    // bottom-right corner to carve out — the down arrow sits at the work bottom.
    int cx=wx+ww-SB_W, cy=wy, ch=wh;
    int ah=SB_ARROW; if(ah*2 > ch-SB_MINTH) ah=(ch-SB_MINTH)/2; if(ah<0) ah=0;
    int ty=cy+ah, th=ch-2*ah; if(th<1) th=1;
    int total=W->content_h, vis=wh;
    int len = (int)((long)th*vis/total); if(len<SB_MINTH) len=SB_MINTH; if(len>th) len=th;
    int maxs = total-vis; if(maxs<1) maxs=1;
    int off = (int)((long)(th-len)*W->scroll_y/maxs);
    if(colx)*colx=cx; if(coly)*coly=cy; if(colw)*colw=SB_W; if(colh)*colh=ch;
    if(upy)*upy=cy; if(dny)*dny=cy+ch-ah; if(arrh)*arrh=ah;
    if(trky)*trky=ty; if(trkh)*trkh=th;
    if(thy)*thy=ty+off; if(thh)*thh=len;
    return 1;
}
// Draw the vertical scrollbar from the theme's real scrollbar art: a light
// chrome column (with a left divider to separate it from the content), the
// vscroll.up / vscroll.down arrow sprites blitted at native size centred in
// their arrow boxes, and the vscroll.thumb 9-slice stretched down its length
// (fixed 4px caps + a stretched middle, so it never distorts like a squashed
// pill).  The column spans the full work height; the down arrow sits at the
// work-area bottom (the resize sizer moved to the W_INFO footer below it).
static void draw_vscroll(int hd){
    awin*W=&g_w[hd];
    int cx,cy,cw,ch,upy,dny,arrh,trky,trkh,thy,thh;
    if(!vsb_geom(W,&cx,&cy,&cw,&ch,&upy,&dny,&arrh,&trky,&trkh,&thy,&thh)) return;
    vsf_color(H(),248); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);   // PEN_DLG column
    int16_t cr[4]={(int16_t)cx,(int16_t)cy,(int16_t)(cx+cw-1),(int16_t)(cy+ch-1)}; vr_recfl(H(),cr);
    vsl_color(H(),249); vsl_width(H(),1);                                        // PEN_BORDER left divider
    int16_t dl[4]={(int16_t)cx,(int16_t)cy,(int16_t)cx,(int16_t)(cy+ch-1)}; v_pline(H(),2,dl);
    { int thw=cw-6; if(thw<7) thw=7; int thx=cx+(cw-thw)/2;                      // themed thumb, centred
      theme_draw(H(),aes_theme(),"vscroll.thumb", thx,thy,thw,thh); }
    if(arrh>0){                                                                 // theme up/down arrow art
        const theme_slice*su=theme_find(aes_theme(),"vscroll.up");
        const theme_slice*sd=theme_find(aes_theme(),"vscroll.down");
        if(su) theme_blit(H(),aes_theme(),su, cx+(cw-su->sw)/2, upy+(arrh-su->sh)/2, su->sw, su->sh);
        if(sd) theme_blit(H(),aes_theme(),sd, cx+(cw-sd->sw)/2, dny+(arrh-sd->sh)/2, sd->sw, sd->sh);
    }
}

static void draw_one(int hd, int active){
    awin*W=&g_w[hd]; int th=tbh();
    if(W->hidden) return;                        // lifted into the HW drag-overlay
    theme_draw(H(),aes_theme(),"window", W->x,W->y,W->w,W->h);
    theme_draw(H(),aes_theme(), active?"titlebar":"titlebar.inactive", W->x, W->y, W->w, th);  // flush top
    int cy = W->y+(th-WTB_W)/2;
    char nbl[32], nbm[32];
    if(W->kind & W_CLOSER) spr(tbvariant(nbl,sizeof nbl,"close",   active), W->x+8,           cy);
    if(W->kind & W_FULLER) spr(tbvariant(nbm,sizeof nbm,"maximize",active), W->x+8+WTB_PITCH, cy);
    if(W->kind & W_NAME){
        // Title work span: right of the close/full boxes, up to the right edge.
        // +8 extra left inset so the title text breathes past the left buttons
        // (was flush against the maximize circle).
        int tlx=W->x+8; if(W->kind&W_CLOSER) tlx+=WTB_PITCH; if(W->kind&W_FULLER) tlx+=WTB_PITCH; tlx+=8;
        int trx=W->x+W->w-8; int tlw=trx-tlx; if(tlw<0) tlw=0;
        // Right-side title buttons occupy the far right; reserve their width (plus
        // an 8px gap) so the title renderer's DRAW span (dlw) stops short of them
        // and text never touches a button.  The app-CLICK span (titlew) stays the
        // full width, so a press on a button is still delivered as a title click.
        int nb=W->ntb, bspan = nb>0 ? nb*WTB_PITCH+8 : 0;
        int dlw=tlw-bspan; if(dlw<0) dlw=0;
        int cyb=W->y+(th-WTB_W)/2;
        for(int i=0;i<nb;i++){ int bx=trx-WTB_W-(nb-1-i)*WTB_PITCH;   // right-aligned, index 0 leftmost
            W->tbx[i]=bx; W->tby[i]=cyb; W->tbw[i]=WTB_W; W->tbh[i]=WTB_W; }
        W->titlex=tlx; W->titley=W->y; W->titlew=tlw; W->titleh=th;
        if(W->title){                          // app-drawn interactive title (clipped to the shortened span)
            int16_t tc[4]={(int16_t)tlx,(int16_t)W->y,(int16_t)(tlx+dlw-1),(int16_t)(W->y+th-1)};
            g_title_active=active;             // let the callback pick a legible pen
            vs_clip(H(),1,tc); W->title(hd, tlx, W->y, dlw, th, W->titleud); vs_clip(H(),0,tc);
        } else {                               // plain centred name
            vst_color(H(),active?0:1); vst_height(H(),15,0,0,0,0);   // white on the dark active bar
            vst_alignment(H(),VDI_TA_CENTER,VDI_TA_HALF,0,0);
            v_gtext(H(), W->x+W->w/2, W->y+th/2, W->name);
            vst_alignment(H(),VDI_TA_LEFT,VDI_TA_TOP,0,0);
        }
        for(int i=0;i<nb;i++) draw_titlebtn(W->tbx[i], W->tby[i], W->tbglyph[i], active);   // over the title, right-aligned
    }
    if(W->kind & W_INFO){          // W_INFO chrome line as a FOOTER at the window bottom; tuck 2px
        int ix=W->x+2, iy=W->y+W->h-AES_INFO_H-2, iw=W->w-4;   // inside the rounded frame corners
        vsf_color(H(),248); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);   // PEN_DLG (object.c): light chrome
        int16_t ir[4]={(int16_t)ix,(int16_t)iy,(int16_t)(ix+iw-1),(int16_t)(iy+AES_INFO_H-1)}; vr_recfl(H(),ir);
        vsl_color(H(),249); vsl_width(H(),1);                                        // PEN_BORDER: TOP divider (work | footer)
        int16_t il[4]={(int16_t)ix,(int16_t)iy,(int16_t)(ix+iw-1),(int16_t)iy}; v_pline(H(),2,il);
        if(W->info){ int16_t ic[4]={(int16_t)ix,(int16_t)iy,(int16_t)(ix+iw-1),(int16_t)(iy+AES_INFO_H-1)};
            vs_clip(H(),1,ic); W->info(hd,ix,iy,iw,AES_INFO_H,W->infoud); vs_clip(H(),0,ic); }
    }
    if(W->kind & W_SIZER){         // resize grips at BOTH ends of the footer band
        int gy=W->y+W->h-SIZER_SZ-2;                    // bottom-aligned in the footer
        draw_grip_l(W->x+2,               gy, SIZER_SZ);  // bottom-left, inside the frame border
        draw_grip  (W->x+W->w-SIZER_SZ-2, gy, SIZER_SZ);  // bottom-right, inside the frame border
    }
    // work area + content (clipped).  The rect is shrunk by the scrollbar column
    // when the bar shows, so the app reflows into the narrower span.
    int wx,wy,ww,wh; app_work(W,&wx,&wy,&ww,&wh);
    if(W->surf.px){
        // SERVER: the content is the client's BACKING STORE, and we blit it. gemd holds the
        // pixels, so it can re-composite this window on a move, a top or a reveal without the
        // client being involved at all (§3) — that promise is the whole reason the backing
        // store exists, and every other promise leans on it.
        //
        // Through gfx_blit, which is the VDI's BACKEND SEAM (gfx.h: software in gfx_soft.c, the
        // blitter on A9). §14 requires the compositor's inner blit to go through a backend or
        // phase 2 is a rewrite — and the VDI's backend is the one phase 2 has to swap anyway,
        // so this is the seam, not a second one beside it.
        //
        // The source is the top-left ww x wh sub-rect of a surface whose stride is its CAPACITY
        // width (§12), which gfx_blit honours via src->stride.
        int sw = ww > W->surf.w ? W->surf.w : ww;
        int sh = wh > W->surf.h ? W->surf.h : wh;
        gfx_surface *d = vdi_screen_target();
        if(d && sw>0 && sh>0) gfx_blit(d, wx,wy, &W->surf, 0,0, sw,sh);
    } else if(W->draw){
        // LOCAL: the app's content callback, in this same process. In CLIENT mode the same
        // callback runs — but against our own surface, and gemd never sees it (client_paint).
        int16_t clip[4]={(int16_t)wx,(int16_t)wy,(int16_t)(wx+ww-1),(int16_t)(wy+wh-1)};
        vs_clip(H(),1,clip); W->draw(hd,wx,wy,ww,wh,W->ud); vs_clip(H(),0,clip);
    }
    draw_vscroll(hd);                            // over the reserved right column
}

// ---- SERVER MODE: the narrow seam gemd uses ---------------------------------
// gemd owns the list, but it reaches it through THESE and not by poking awin, so the window
// layer keeps one owner. It needs exactly four things: attach a client's surface to a window,
// ask how big the work area is (only the AES knows — chrome is its business), drop a window,
// and find a client's windows when that client dies.
void wind_attach_surface(int hd,int surf_id,uint32_t gen,uint32_t*px,int w,int h,int stride,int client){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    awin*W=&g_w[hd];
    W->surf_id=surf_id; W->surf_gen=gen; W->client=client;
    W->surf.w=w; W->surf.h=h; W->surf.stride=stride; W->surf.px=px;   // stride = CAPACITY (§12)
}
void wind_work_size(int hd,int*w,int*h){          // the work area = what the CLIENT draws into
    if(hd<1||hd>=MAXW||!g_w[hd].used){ if(w)*w=0; if(h)*h=0; return; }
    int x,y,ww,wh; app_work(&g_w[hd],&x,&y,&ww,&wh);
    if(w)*w=ww; if(h)*h=wh;
}
int  wind_surface_of(int hd){ return (hd>=1&&hd<MAXW&&g_w[hd].used)?g_w[hd].surf_id:-1; }
uint32_t wind_gen_of(int hd){ return (hd>=1&&hd<MAXW&&g_w[hd].used)?g_w[hd].surf_gen:0; }
int  wind_client_of(int hd){ return (hd>=1&&hd<MAXW&&g_w[hd].used)?g_w[hd].client:-1; }
int  wind_next_of_client(int client,int from){    // iterate a dead client's windows (§9 reaping)
    for(int i=(from<1?1:from);i<MAXW;i++)
        if(g_w[i].used && g_w[i].client==client) return i;
    return 0;
}
void wind_rect_of(int hd,int*x,int*y,int*w,int*h){
    if(hd<1||hd>=MAXW){ if(x)*x=0; if(y)*y=0; if(w)*w=0; if(h)*h=0; return; }
    awin*W=&g_w[hd];
    if(x)*x=W->x; if(y)*y=W->y; if(w)*w=W->w; if(h)*h=W->h;
}
// Work-area origin ON SCREEN: gemd maps a client's surface-coordinate damage rect through this.
void wind_work_origin(int hd,int*x,int*y){
    int wx,wy,ww,wh;
    if(hd<1||hd>=MAXW||!g_w[hd].used){ if(x)*x=0; if(y)*y=0; return; }
    app_work(&g_w[hd],&wx,&wy,&ww,&wh);
    if(x)*x=wx; if(y)*y=wy;
}

void wind_set_desktop(uint32_t bg){ g_deskbg = bg; }

static wind_draw_fn g_deskcontent; static void *g_deskcontent_ud;
void wind_set_desktop_content(wind_draw_fn fn, void *ud){ g_deskcontent=fn; g_deskcontent_ud=ud; }

/* HW drag-overlay hooks (A9 only): begin() lifts the window rect into the overlay
 * plane, move() repositions it with NO redraw, end() drops it; present() pushes a
 * plane rect. All NULL on the SDL host -> classic redraw-per-motion drag. */
static int  (*g_ovl_begin)(int x,int y,int w,int h);
static void (*g_ovl_move)(int x,int y);
static void (*g_ovl_end)(void);
static void (*g_ovl_present)(int x,int y,int w,int h);
void wind_set_overlay(int(*begin)(int,int,int,int), void(*move)(int,int),
                      void(*end)(void), void(*present)(int,int,int,int)){
    g_ovl_begin=begin; g_ovl_move=move; g_ovl_end=end; g_ovl_present=present;
}
/* Push a just-drawn screen rect through the registered present hook, so code
 * that draws outside wind_redraw (modal dialogs, progress boxes) is visible on
 * targets that composite into a back-buffer (A9).  No-op when no hook is set
 * (the SDL host presents inside its event source). */
void aes_flush_rect(int x,int y,int w,int h){ if(g_ovl_present) g_ovl_present(x,y,w,h); }

/* The drag-overlay ops, for other modal movers (dialog drag in form.c): lift
 * returns 0 when no hook is registered / the lift was refused, and the caller
 * falls back to the classic redraw-per-motion move. */
int  aes_ovl_lift(int x,int y,int w,int h){ return g_ovl_begin ? g_ovl_begin(x,y,w,h) : 0; }
void aes_ovl_move(int x,int y){ if(g_ovl_move) g_ovl_move(x,y); }
void aes_ovl_drop(void){ if(g_ovl_end) g_ovl_end(); }

static int g_redraw_gen;           // bumped per wind_redraw: modal loops watch it
int aes_redraw_gen(void){ return g_redraw_gen; }

// Repaint only the damage rectangle: background + wallpaper/icons + every window
// that intersects it (in z-order) + the menu bar if the rect reaches it, all
// clipped to the rect, then present it.  wind_redraw() is the whole-screen case.
// Everything is drawn through the (nesting) clip so draw_one's own content clips
// intersect with the damage bound instead of escaping it.
void wind_redraw_area(int rx,int ry,int rw,int rh){
    g_redraw_gen++;
    // A CLIENT has no screen to repaint (§5: it must never assume it owns one). "Repaint" for a
    // client means its own content, into its own surface -> damage.
    if(g_mode==AES_CLIENT){
        for(int i=1;i<MAXW;i++) if(g_w[i].used && g_w[i].surf.px)
            client_paint(i, 0,0, g_w[i].surf.w, g_w[i].surf.h);
        return;
    }
    gfx_surface *d = vdi_screen_target(); if(!d) return;
    if(rx<0){ rw+=rx; rx=0; } if(ry<0){ rh+=ry; ry=0; }
    if(rx+rw>d->w) rw=d->w-rx; if(ry+rh>d->h) rh=d->h-ry;
    if(rw<=0||rh<=0) return;
    int16_t clip[4]={(int16_t)rx,(int16_t)ry,(int16_t)(rx+rw-1),(int16_t)(ry+rh-1)};
    vs_clip(H(),2,NULL);                                  // fresh clip stack for the frame
    vs_clip(H(),1,clip);
    uint32_t bg=g_deskbg;                                 // background (wallpaper overdraws it)
    // STRIDE, not width: a surface's row pitch is its CAPACITY width (Rocks §12), and the
    // drawable is the top-left w x h sub-rect.  d->w happened to equal d->stride for every
    // surface this had ever been handed, so it was harmless -- and it becomes a silent
    // wrong-address bug (rows walking diagonally) the moment capacity != extent, which is
    // exactly what gemd's surfaces are.
    for(int yy=ry; yy<ry+rh; yy++){ uint32_t*row=d->px+(size_t)yy*d->stride; for(int xx=rx; xx<rx+rw; xx++) row[xx]=bg; }
    if(g_deskcontent) g_deskcontent(0, 0,0, d->w,d->h, g_deskcontent_ud);   // full extent, clipped to the rect
    for(int i=0;i<g_nz;i++){ awin*W=&g_w[g_z[i]];         // windows intersecting the damage, z-order
        if(W->hidden) continue;
        if(W->x < rx+rw && W->x+W->w > rx && W->y < ry+rh && W->y+W->h > ry)
            draw_one(g_z[i], i==g_nz-1);
    }
    if(ry < g_top_reserve) menu_redraw();                 // the bar only if the rect reaches it
    vs_clip(H(),0,NULL);
    aes_flush_rect(rx,ry,rw,rh);                          // present (A9 back-buffer; no-op on SDL)
}
void wind_redraw(void){
    gfx_surface *d = vdi_screen_target();
    if(d) wind_redraw_area(0,0,d->w,d->h);
}
// Repaint just one window's rect (the common "only this window changed" case).
//
// In CLIENT mode this is what an app calls when ITS OWN CONTENT went stale — a line of text
// changed, a list scrolled. It does NOT repaint the screen (the app has no screen): it redraws
// the content into the app's own surface and posts one damage rect. gemd blits it and never
// learns why. That is §3's asymmetry, and it is the same call on both sides of the wire.
void wind_redraw_win(int hd){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    awin*W=&g_w[hd];
    if(g_mode==AES_CLIENT){ client_paint(hd, 0,0, W->surf.w, W->surf.h); return; }
    wind_redraw_area(W->x,W->y,W->w,W->h);
}

// ---- CLIENT MODE -----------------------------------------------------------
// wind_* keep their EXACT signatures and become messages. The app never learns (§5).
//
// The app's local entry keeps only what the app genuinely owns: its content callback, and its
// own surface. Geometry, z-order and chrome are gemd's, and a client is not told where its
// window is, what is above it, or whether it is visible at all.
#ifdef GEM_XTOS
#include "usys.h"

void wind_client_attach(void){
    if(g_mode==AES_SERVER) return;                  // gemd is nobody's client
    int fd = gem_connect();
    if(fd < 0) return;                              // gemd is not running -> stay LOCAL, unchanged
    g_gemfd = fd; g_mode = AES_CLIENT;
}
void wind_client_detach(void){
    if(g_mode!=AES_CLIENT) return;
    if(g_gemfd>=0) sys_close(g_gemfd);              // gemd sees EOF and reaps our windows (§9/§11)
    g_gemfd=-1; g_mode=AES_LOCAL;
}

// Draw our own content into our OWN surface, then post ONE damage rect. Zero IPC in the draw
// itself: the VDI writes to ordinary cached memory at full speed, and gemd is told only "these
// pixels changed" — never why (§3).
static void client_paint(int hd,int x,int y,int w,int h){
    awin*W=&g_w[hd];
    if(!W->surf.px || !W->draw) return;
    if(x<0){ w+=x; x=0; } if(y<0){ h+=y; y=0; }
    if(x+w>W->surf.w) w=W->surf.w-x;
    if(y+h>W->surf.h) h=W->surf.h-y;
    if(w<=0||h<=0) return;

    int save = aes_handle();                        // point the AES at OUR workstation (opened once
    aes_init(W->vh, aes_theme());                   // on this surface — §10: a retarget, not a re-open)
    int16_t clip[4]={(int16_t)x,(int16_t)y,(int16_t)(x+w-1),(int16_t)(y+h-1)};
    vs_clip(W->vh,1,clip);
    W->draw(hd, 0,0, W->surf.w, W->surf.h, W->ud);  // SURFACE coords: the work area starts at 0,0
    vs_clip(W->vh,0,clip);
    aes_init(save, aes_theme());

    gem_damage_rect(g_gemfd, hd, W->surf_id, W->surf_gen, x,y,w,h);
}
#else
void wind_client_attach(void){}                     // SDL host: there is no gemd, and no usys.h
void wind_client_detach(void){}
static void client_paint(int hd,int x,int y,int w,int h){ (void)hd;(void)x;(void)y;(void)w;(void)h; }
#endif

int wind_create(int kind,int x,int y,int w,int h){
#ifdef GEM_XTOS
    if(g_mode==AES_CLIENT){
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_CREATE; m.w[1]=(int16_t)kind;
        m.w[2]=(int16_t)x; m.w[3]=(int16_t)y; m.w[4]=(int16_t)w; m.w[5]=(int16_t)h;
        if(gem_send(g_gemfd,&m)!=0) return 0;
        if(gem_await(g_gemfd,GEM_WIND_CREATED,&m)!=0) return 0;
        int hd=m.w[1];
        if(hd<1||hd>=MAXW) return 0;                // gemd's handle indexes OUR table too: the
        memset(&g_w[hd],0,sizeof g_w[hd]);          // list is system-wide now, so it fits
        g_w[hd].used=1; g_w[hd].kind=kind;
        g_w[hd].x=x; g_w[hd].y=y; g_w[hd].w=w; g_w[hd].h=h;
        g_w[hd].surf_id=-1;
        return hd;
    }
#endif
    for(int i=1;i<MAXW;i++) if(!g_w[i].used){
        memset(&g_w[i],0,sizeof g_w[i]); g_w[i].used=1; g_w[i].kind=kind;
        g_w[i].x=x; g_w[i].y=y; g_w[i].w=w; g_w[i].h=h; g_w[i].surf_id=-1;
        return i;
    }
    return 0;
}
void wind_open(int hd,int x,int y,int w,int h){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
#ifdef GEM_XTOS
    if(g_mode==AES_CLIENT){
        awin*W=&g_w[hd];
        W->x=x; W->y=y; W->w=w; W->h=h;
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_OPEN; m.w[1]=(int16_t)hd;
        m.w[2]=(int16_t)x; m.w[3]=(int16_t)y; m.w[4]=(int16_t)w; m.w[5]=(int16_t)h;
        if(gem_send(g_gemfd,&m)!=0) return;
        if(gem_await(g_gemfd,GEM_WIND_SURF,&m)!=0) return;   // gemd sizes the surface: it owns the
                                                             // chrome, so only IT knows the work area
        int ww=m.w[2], wh2=m.w[3], cw=m.w[4];
        W->surf_id=(int)m.u[0]; W->surf_gen=m.u[1];
        uint32_t *px = gem_surf_map(W->surf_id);
        if(!px){ W->surf_id=-1; return; }
        W->surf.w=ww; W->surf.h=wh2; W->surf.stride=cw; W->surf.px=px;   // STRIDE = CAPACITY (§12)
        vdi_init(&W->surf);                          // this surface is all the "screen" we have
        W->vh = v_opnvwk(&W->surf);                  // ONCE, for this window's life (§10)

        // FIRST PAINT. §3: WM_REDRAW survives only for the first paint and resize — every other
        // repaint is the app deciding its own content is stale. gemd sent one; drain it and draw.
        if(gem_await(g_gemfd,GEM_MSG_REDRAW,&m)==0)
            client_paint(hd, m.w[2],m.w[3],m.w[4],m.w[5]);
        return;
    }
#endif
    g_w[hd].x=x; g_w[hd].y=y; g_w[hd].w=w; g_w[hd].h=h; clamp_win(&g_w[hd]); clamp_scroll(&g_w[hd]);
    for(int i=0;i<g_nz;i++) if(g_z[i]==hd) return;       // already open
    g_z[g_nz++]=hd; wind_redraw_win(hd);
}
static void zremove(int hd){ for(int i=0;i<g_nz;i++) if(g_z[i]==hd){ for(int j=i;j<g_nz-1;j++) g_z[j]=g_z[j+1]; g_nz--; return; } }
void wind_close(int hd){
    if(hd<1||hd>=MAXW) return;
#ifdef GEM_XTOS
    if(g_mode==AES_CLIENT){
        awin*W=&g_w[hd];
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_CLOSE; m.w[1]=(int16_t)hd; gem_send(g_gemfd,&m);
        if(W->surf_id>=0){ gem_surf_unmap(g_gemfd,W->surf_id); W->surf_id=-1; W->surf.px=0; }
        return;                                     // gemd drops ITS ref when the window goes (§11)
    }
#endif
    awin*W=&g_w[hd]; int x=W->x,y=W->y,w=W->w,h=W->h; zremove(hd); wind_redraw_area(x,y,w,h);
}
void wind_delete(int hd){
    if(hd<1||hd>=MAXW) return;
#ifdef GEM_XTOS
    if(g_mode==AES_CLIENT){
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_DELETE; m.w[1]=(int16_t)hd; gem_send(g_gemfd,&m);
        g_w[hd].used=0; return;
    }
#endif
    zremove(hd); g_w[hd].used=0;
}
void wind_set_name(int hd,const char*n){
    if(hd<1||hd>=MAXW) return;
    snprintf(g_w[hd].name,sizeof g_w[hd].name,"%s",n?n:"");
#ifdef GEM_XTOS
    if(g_mode==AES_CLIENT){
        gem_msg m; memset(&m,0,sizeof m);          // the name rides in the fixed 32-byte record,
        m.w[0]=GEM_WIND_NAME; m.w[1]=(int16_t)hd;  // truncated at GEM_NAME_MAX (titles are short)
        char *dst=(char*)&m.w[2];
        snprintf(dst,GEM_NAME_MAX+1,"%s",n?n:"");
        gem_send(g_gemfd,&m);
    }
#endif
}
void wind_content(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].draw=fn; g_w[hd].ud=ud; } }
void wind_content_size(int hd,int w,int h){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    g_w[hd].content_w=w<0?0:w; g_w[hd].content_h=h<0?0:h; clamp_scroll(&g_w[hd]);
}
int wind_scroll_y(int hd){ return (hd>=1&&hd<MAXW)?g_w[hd].scroll_y:0; }
int wind_scroll_x(int hd){ return (hd>=1&&hd<MAXW)?g_w[hd].scroll_x:0; }
void wind_set_scroll(int hd,int x,int y){
    if(hd<1||hd>=MAXW) return; g_w[hd].scroll_x=x; g_w[hd].scroll_y=y; clamp_scroll(&g_w[hd]);
}
int wind_handle_wheel(int mx,int my,int delta){
    int hd=wind_find(mx,my); if(!hd) return 0; awin*W=&g_w[hd];
    if(!vsb_on(W)) return 0;                       // nothing scrollable under the pointer
    int before=W->scroll_y;
    W->scroll_y -= delta*SB_LINE; clamp_scroll(W);  // wheel-up (delta>0) -> toward the top
    if(W->scroll_y!=before) wind_redraw_win(hd);
    return 1;
}
void wind_info(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].info=fn; g_w[hd].infoud=ud; } }
void wind_title(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].title=fn; g_w[hd].titleud=ud; } }
void wind_titlebtns(int hd,const int*glyphs,int n){
    if(hd<1||hd>=MAXW) return; awin*W=&g_w[hd];
    if(n<0) n=0; if(n>WIND_MAXTB) n=WIND_MAXTB;
    W->ntb=n;
    for(int i=0;i<n;i++) W->tbglyph[i]=glyphs?glyphs[i]:WTG_NONE;
    for(int i=n;i<WIND_MAXTB;i++){ W->tbglyph[i]=WTG_NONE; W->tbw[i]=0; }   // clear stale rects
}
int wind_titlebtn_rect(int hd,int idx,int*x,int*y,int*w,int*h){
    if(hd<1||hd>=MAXW) return 0; awin*W=&g_w[hd];
    if(idx<0||idx>=W->ntb||W->tbw[idx]<=0) return 0;               // not registered / not yet laid out
    if(x)*x=W->tbx[idx]; if(y)*y=W->tby[idx]; if(w)*w=W->tbw[idx]; if(h)*h=W->tbh[idx];
    return 1;
}

void wind_get(int hd,int field,int*a,int*b,int*c,int*d){
    if(hd==0){ int x,y,w,h; work_area(&x,&y,&w,&h); if(a)*a=x; if(b)*b=y; if(c)*c=w; if(d)*d=h; return; }  // desktop
    if(hd<1||hd>=MAXW){ if(a)*a=0; return; }
    awin*W=&g_w[hd]; int x=W->x,y=W->y,w=W->w,h=W->h;
    if(field==WF_WORKXYWH) app_work(W,&x,&y,&w,&h);   // already minus the scrollbar column
    else if(field==WF_PREVXYWH){ x=W->px;y=W->py;w=W->pw;h=W->ph; }
    if(a)*a=x; if(b)*b=y; if(c)*c=w; if(d)*d=h;
}
void wind_set(int hd,int field,int a,int b,int c,int d){
    if(hd<1||hd>=MAXW) return; awin*W=&g_w[hd];
    if(field==WF_CURRXYWH){ W->px=W->x;W->py=W->y;W->pw=W->w;W->ph=W->h; W->x=a;W->y=b;W->w=c;W->h=d; clamp_win(W); clamp_scroll(W); wind_redraw(); }
}

int wind_find(int x,int y){
    for(int i=g_nz-1;i>=0;i--){ awin*W=&g_w[g_z[i]]; if(x>=W->x&&x<W->x+W->w&&y>=W->y&&y<W->y+W->h) return g_z[i]; }
    return 0;
}

int wind_top(void){ return g_nz ? g_z[g_nz-1] : 0; }

void wind_raise(int hd){
    if(hd<1||hd>=MAXW) return;
    for(int i=0;i<g_nz;i++) if(g_z[i]==hd){ zremove(hd); g_z[g_nz++]=hd; wind_redraw_win(hd); return; }
}

static void post(int type,int hd,int a,int b,int c,int d){
    int16_t m[8]={(int16_t)type,1,0,(int16_t)hd,(int16_t)a,(int16_t)b,(int16_t)c,(int16_t)d}; appl_write(0,16,m);
}
static void raise(int hd){ zremove(hd); g_z[g_nz++]=hd; }

int wind_handle_click(int mx,int my){
    int hd = wind_find(mx,my);
    if(!hd) return 0;
    awin*W=&g_w[hd];
    if(g_z[g_nz-1]!=hd){ raise(hd); wind_redraw_win(hd); post(WM_TOPPED,hd,0,0,0,0); return 1; }
    int th=tbh();
    int tx=W->x, ty=W->y, tw=W->w;               // flush title bar
    // close box
    if((W->kind&W_CLOSER) && mx>=tx+8 && mx<tx+8+WTB_W && my>=ty && my<ty+th){ post(WM_CLOSED,hd,0,0,0,0); return 1; }
    // maximise box (W_FULLER): toggle between the full desktop work area and the
    // saved pre-maximise rect, then WM_SIZED so the app reflows to the new size.
    if((W->kind&W_FULLER) && mx>=tx+8+WTB_PITCH && mx<tx+8+WTB_PITCH+WTB_W && my>=ty && my<ty+th){
        if(!W->maxed){ W->sx=W->x; W->sy=W->y; W->sw=W->w; W->sh=W->h;
                       int ax,ay,aw,ah; work_area(&ax,&ay,&aw,&ah);
                       W->x=ax; W->y=ay; W->w=aw; W->h=ah; W->maxed=1; }
        else         { W->x=W->sx; W->y=W->sy; W->w=W->sw; W->h=W->sh; W->maxed=0; }
        clamp_win(W); clamp_scroll(W); wind_redraw();
        post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
    }
    // title bar -> drag (live move)
    if((W->kind&W_MOVER) && my>=ty && my<ty+th && mx>=tx && mx<tx+tw){
        // Interactive title: a press on the app's title span that does NOT move is
        // a click for the app (return 0 -> evnt_multi delivers MU_BUTTON at the
        // press point, the app hit-tests its own title hot-rects).  A press that
        // moves past the slop still drags, so the whole title stays grab-to-move.
        if(W->title && mx>=W->titlex && mx<W->titlex+W->titlew){
            int dnx=mx, dny=my, moved=0;
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1);
                if(t==AES_QUIT) break;
                if(t==AES_MOTION){ int ex=e.mx-dnx, ey=e.my-dny; if(ex<0)ex=-ex; if(ey<0)ey=-ey;
                    if(ex>3||ey>3){ moved=1; break; } }
                if(t==AES_BTN_UP) break; }
            if(!moved) return 0;               // click (no drag) -> app handles it
            // moved: fall through into the drag loop (anchored to the press point)
        }
        int gx=mx-W->x, gy=my-W->y;
        if(g_ovl_begin && g_ovl_begin(W->x,W->y,W->w,W->h)){    // A9: lift window into the HW overlay
            int ox=W->x, oy=W->y, ow=W->w, oh=W->h;            // vacated rect
            W->hidden=1; wind_redraw();                        // erase from the plane (overlay still covers it)...
            if(g_ovl_present) g_ovl_present(ox,oy,ow,oh);      // ...push the now-behind pixels
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ W->x=e.mx-gx; W->y=e.my-gy; clamp_win(W); g_ovl_move(W->x,W->y); } // register write, no redraw
                if(t==AES_BTN_UP) break; }
            W->hidden=0; wind_redraw();                        // paint the window at its new home (under the overlay)...
            if(g_ovl_present){ g_ovl_present(ox,oy,ow,oh); g_ovl_present(W->x,W->y,W->w,W->h); }
            g_ovl_end();                                       // ...then drop the overlay -> seamless
        } else {                                               // SDL host: classic redraw-per-motion
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ int ox=W->x,oy=W->y; W->x=e.mx-gx; W->y=e.my-gy; clamp_win(W);
                    int ux=ox<W->x?ox:W->x, uy=oy<W->y?oy:W->y;   // repaint old ∪ new
                    wind_redraw_area(ux, uy, (ox>W->x?ox:W->x)+W->w-ux, (oy>W->y?oy:W->y)+W->h-uy); }
                if(t==AES_BTN_UP) break; }
        }
        post(WM_MOVED,hd,W->x,W->y,W->w,W->h); return 1;
    }
    // resize grips: one at EACH end of the W_INFO footer (bottom-left / bottom-right
    // corners) — checked before the scrollbar.  The right grip drags the bottom+right
    // edges (classic sizer); the left grip drags the bottom+LEFT edges (right edge
    // pinned).  The rest of the footer falls through to the app (info-bar Retry etc.).
    if(W->kind & W_SIZER){
        int fy=W->y+W->h-AES_INFO_H;                             // footer band top
        int infr = my>=fy && my<W->y+W->h;
        int lgrip = infr && mx>=W->x && mx<W->x+SIZER_SZ;
        int rgrip = infr && mx>=W->x+W->w-SIZER_SZ && mx<W->x+W->w;
        if(rgrip){
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ int ow=W->w,oh=W->h; int nw=e.mx-W->x, nh=e.my-W->y; if(nw<120)nw=120; if(nh<80)nh=80; W->w=nw; W->h=nh; clamp_scroll(W);
                    wind_redraw_area(W->x, W->y, ow>nw?ow:nw, oh>nh?oh:nh); }   // old ∪ new (same top-left)
                if(t==AES_BTN_UP) break; }
            post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
        }
        if(lgrip){
            int right=W->x+W->w;                                 // pin the right edge
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ int ox=W->x,oh=W->h; int nx=e.mx, nh=e.my-W->y; int nw=right-nx;
                    if(nw<120){ nw=120; nx=right-nw; } if(nh<80)nh=80;
                    W->x=nx; W->w=nw; W->h=nh; clamp_scroll(W);
                    int ux=ox<nx?ox:nx; wind_redraw_area(ux, W->y, right-ux, oh>nh?oh:nh); }   // old ∪ new (right pinned)
                if(t==AES_BTN_UP) break; }
            post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
        }
    }
    // vertical scrollbar in the reserved right column (arrows / thumb drag / track page)
    { int cx,cy,cw,ch,upy,dny,arrh,trky,trkh,thy,thh;
      if(vsb_geom(W,&cx,&cy,&cw,&ch,&upy,&dny,&arrh,&trky,&trkh,&thy,&thh) &&
         mx>=cx && mx<cx+cw && my>=cy && my<cy+ch){
        if(arrh>0 && my<upy+arrh){                              // up arrow: one line
            W->scroll_y-=SB_LINE; clamp_scroll(W); wind_redraw_win(hd); post(WM_VSLID,hd,0,0,0,0); return 1; }
        if(arrh>0 && my>=dny){                                  // down arrow: one line
            W->scroll_y+=SB_LINE; clamp_scroll(W); wind_redraw_win(hd); post(WM_VSLID,hd,0,0,0,0); return 1; }
        if(my<thy){                                             // track above thumb: page up
            int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
            W->scroll_y-=(wh>SB_LINE?wh-SB_LINE:wh); clamp_scroll(W); wind_redraw_win(hd); post(WM_VSLID,hd,0,0,0,0); return 1; }
        if(my>=thy+thh){                                        // track below thumb: page down
            int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
            W->scroll_y+=(wh>SB_LINE?wh-SB_LINE:wh); clamp_scroll(W); wind_redraw_win(hd); post(WM_VSLID,hd,0,0,0,0); return 1; }
        // on the thumb: drag it, mapping travel back to scroll_y proportionally
        int grab=my-thy;
        for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
            if(t==AES_MOTION){
                int t2y,t2h,tk2y,tk2h; vsb_geom(W,0,0,0,0,0,0,0,&tk2y,&tk2h,&t2y,&t2h);
                int span=tk2h-t2h; int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
                int maxs=W->content_h-wh; if(maxs<0)maxs=0;
                int rel=e.my-grab-tk2y; if(span>0){ W->scroll_y=(int)((long)rel*maxs/span); }
                clamp_scroll(W); wind_redraw_win(hd); }
            if(t==AES_BTN_UP) break; }
        post(WM_VSLID,hd,0,0,0,0); return 1;
      } }
    return 0;     // click in the work area -> the app gets it
}
