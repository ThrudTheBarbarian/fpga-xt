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
#ifdef GEM_XTOS
static int g_gemfd = -1;                // client mode: the channel to gemd (there is no gemd on the
#endif                                  // SDL host — a different PLATFORM, not a fallback)
int aes_mode(void){ return g_mode; }
void aes_server_mode(void){ g_mode = AES_SERVER; }
static void client_paint(int hd,int x,int y,int w,int h);   // draw OUR content -> OUR surface -> damage

// MAXW was 16 PER APP. It is now the SYSTEM-WIDE window count, because the list lives in gemd.
#define MAXW 64
typedef struct {
    int used, kind, x, y, w, h, px,py,pw,ph;   // full rect (+ previous)
    int hidden;                                // lifted into the HW drag-overlay: skip in redraw
    // ---- the declarative chrome MODEL (§11) ---------------------------------
    // The AES owns these, not the client.  A pointer handed to wind_set is COPIED,
    // which is what lets gemd repaint a wedged app's title bar from its own model.
    char name[64];       // WF_NAME
    char info_text[80];  // WF_INFO      — the footer TEXT (supersedes the info callback)
    char subtitle[64];   // WF_SUBTITLE  — a path / second line
    char icon[32];       // WF_ICON      — a theme slice name; "" = none
    int  titleflags;     // WF_TITLEFLAGS — WT_MODIFIED
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
    int ntb, tbglyph[WIND_MAXTB];              // right-side title buttons: count + glyph per button
    int tbx[WIND_MAXTB], tby[WIND_MAXTB], tbw[WIND_MAXTB], tbh[WIND_MAXTB];   // their last rects — OURS.
                                               // The AES draws them and the AES hit-tests them; a press
                                               // is a WM_TBUTTON message. No client ever sees a rect (§11).
    // WT_PATH: the drawn breadcrumb spans. segn[i] is the segment's index in the ORIGINAL path,
    // which is NOT its drawn position — the middle elides — and it is the index the app gets back.
    int nseg, segx[WIND_MAXSEG], segw[WIND_MAXSEG], segn[WIND_MAXSEG];
    int content_w, content_h;                  // app-reported full content size (work coords)
    int scroll_x, scroll_y;                    // current scroll offset (vertical bar drawn)
    int pin_bottom;                            // px at the work-area BOTTOM that do not scroll
                                               // (a status bar): the scroll blit stops above it
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

// A window with NO chrome bits has NO CHROME — no frame, no title bar, and its work area IS its
// full rect. §4: "No chrome, because it passed none of the chrome bits. wind_create's kind mask
// already expresses this." That is what lets the desktop be an ordinary client: a full-screen
// W_BOTTOM window whose drawable is the whole screen, with nothing drawn around it.
int wind_has_chrome(int kind){
    return (kind & (W_NAME|W_CLOSER|W_FULLER|W_MOVER|W_INFO|W_SIZER)) != 0;
}

void wind_calc(int dir,int kind,int x,int y,int w,int h,int*ox,int*oy,int*ow,int*oh){
    if(!wind_has_chrome(kind)){ *ox=x; *oy=y; *ow=w; *oh=h; return; }   // chromeless: work == full
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

// ---- WT_PATH: the breadcrumb, which is CHROME (§11) -------------------------
// The app hands us a path STRING. We split it, lay it out, draw it, hit-test it, and hand back an
// INDEX. Nothing else crosses — no rects, no pixels, no callback — so a wedged app's breadcrumb
// still repaints, and a drag does not cost a client round-trip per frame.
//
// It used to be an app-drawn "interactive title" callback, and this is the whole argument of §11
// in one widget: a breadcrumb LOOKS like something only the app can draw, and it is not. It is a
// list of strings and a click that resolves to one of them.
//
// The middle elides at COMPONENT granularity when the path will not fit ("/a/.../y/z"), so segn[]
// (the index in the ORIGINAL path) is NOT the drawn position — and segn[] is what the app gets.
static int str_w(const char *s){ int16_t e[8]; vqt_extent(H(), s, e); return e[2]-e[0]; }
static int sep_w(void){ return str_w("/"); }        // MEASURED, not guessed: a fixed advance left a
                                                   // visible gap after every separator
static int ell_w(void){ return str_w("...") + 2*sep_w(); }

static int path_split(const awin *W, int *off, int *len, int max){
    int n = 0;
    for(int i = 0; W->subtitle[i] && n < max; ){
        while(W->subtitle[i] == '/') i++;          // skip separators (incl. a leading '/')
        if(!W->subtitle[i]) break;
        int j = i; while(W->subtitle[j] && W->subtitle[j] != '/') j++;
        off[n] = i; len[n] = j - i; n++; i = j;
    }
    return n;
}
static int seg_width(const awin *W,int off,int len){
    char b[64]; if(len > (int)sizeof b - 1) len = (int)sizeof b - 1;
    memcpy(b, W->subtitle+off, (size_t)len); b[len] = 0;
    int16_t e[8]; vqt_extent(H(), b, e); return e[2]-e[0];
}
// Lay the crumbs out into W->seg* to fit `avail` px, and return the width used. Caller has already
// selected the subtitle's text size. Keeps the FIRST component and as much of the TAIL as fits.
static int path_measure(awin *W,int avail){
    int off[WIND_MAXSEG], len[WIND_MAXSEG];
    int n = path_split(W, off, len, WIND_MAXSEG);
    W->nseg = 0;
    if(n <= 0 || avail <= 0) return 0;

    int sep = sep_w(), ellw = ell_w();
    int wid[WIND_MAXSEG], need = 0;
    for(int k=0;k<n;k++){ wid[k] = seg_width(W,off[k],len[k]); need += wid[k] + sep; }

    int first = 0;                                  // elide the MIDDLE: keep [0] + the tail that fits
    if(need > avail && n > 2){
        int tail = n - 1;
        for(; tail > 1; tail--){                    // grow the tail while it still fits
            int w = wid[0] + sep + ellw;
            for(int k=tail;k<n;k++) w += wid[k] + sep;
            if(w <= avail) break;
        }
        first = tail;                               // draw [0], "...", then [first..n)
    }

    int used = 0;
    for(int k=0;k<n;k++){
        if(first && k > 0 && k < first) continue;   // elided
        if(W->nseg >= WIND_MAXSEG) break;
        W->segn[W->nseg] = k; W->segw[W->nseg] = wid[k]; W->nseg++;
        used += wid[k] + sep;
    }
    if(first) used += ellw;
    return used;
}
// Draw the crumbs laid out by path_measure, recording each one's screen x (segx) for the hit test.
static void path_draw(awin *W,int x,int cy,int pen){
    int off[WIND_MAXSEG], len[WIND_MAXSEG];
    int n = path_split(W, off, len, WIND_MAXSEG);
    vst_color(H(),pen);
    vst_alignment(H(),VDI_TA_LEFT,VDI_TA_HALF,0,0);
    int sep = sep_w(), prev = -1;
    for(int i=0;i<W->nseg;i++){
        int k = W->segn[i]; if(k >= n) break;
        v_gtext(H(), x, cy, "/"); x += sep;
        if(prev >= 0 && k > prev + 1){              // the elided middle
            v_gtext(H(), x, cy, "..."); x += str_w("...") + sep;
            v_gtext(H(), x, cy, "/");  x += sep;
        }
        char b[64]; int l = len[k]; if(l > (int)sizeof b - 1) l = (int)sizeof b - 1;
        memcpy(b, W->subtitle+off[k], (size_t)l); b[l] = 0;
        W->segx[i] = x;                             // its span, for wind_handle_click
        v_gtext(H(), x, cy, b);
        x += W->segw[i];
        prev = k;
    }
}

// Keep the window reachable: the title bar stays below the menu bar, above the
// work-area bottom, and at least MINVIS px stays on-screen horizontally — so a
// window can never be dragged completely out of reach.
#define MINVIS 72
static void clamp_win(awin *W){
    int wx,wy,ww,wh; work_area(&wx,&wy,&ww,&wh); int th=tbh();
    // A W_BOTTOM window may span the reserved top strip: the desktop is WALLPAPER, and the
    // menu bar draws OVER it (always-on-top chrome). Clamping it below the reserve would
    // leave a band of bare fallback colour where the wallpaper should run under the bar.
    if (W->kind & W_BOTTOM) return;
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

static void draw_content(int hd);                // content only (surface blit / callback)
static void raise_repaint(int hd,int old);       // a z-order change makes TWO windows stale

// The rect the current repaint is allowed to touch — x0,y0,x1,y1, half-open at the far edge.
// The VDI clip carries this for everything drawn THROUGH the VDI; draw_content's backend blit
// bypasses the VDI, so it has to read the bound itself (see draw_content).
static int g_dmg[4], g_dmg_on;

static void draw_one(int hd, int active){
    awin*W=&g_w[hd]; int th=tbh();
    if(W->hidden) return;                        // lifted into the HW drag-overlay
    if(!wind_has_chrome(W->kind)){ draw_content(hd); return; }   // no chrome bits -> no chrome (§4)
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

        // THE MODEL, AND ONLY THE MODEL (§11).  Everything the deleted wind_title callback
        // was FOR, as data:  proxy icon (WF_ICON) . name (WF_NAME) . modified dot
        // (WF_TITLEFLAGS) . subtitle (WF_SUBTITLE), centred as one group and fitted to the
        // span WE own.  No client is involved, so a WEDGED app's title bar still repaints.
        int pen = active ? 0 : 1;            // the active bar is dark: light text on it
        vst_height(H(),15,0,0,0,0);

        const theme_slice *ic = W->icon[0] ? theme_find(aes_theme(), W->icon) : 0;
        int iw = ic ? ic->sw : 0, ih = ic ? ic->sh : 0;
        int dotw = (W->titleflags & WT_MODIFIED) ? 12 : 0;

        int16_t e[8];
        int sw2 = 0;                         // subtitle, measured at ITS size
        char sfit[64]; sfit[0]=0;
        int crumbs = (W->titleflags & WT_PATH) && W->subtitle[0];
        // With no WF_NAME the breadcrumb IS the title, so it is drawn at TITLE size; beside a name
        // it is a subtitle, and drops to subtitle size. The app sets a string either way.
        int crumbh = W->name[0] ? 12 : 15;
        W->nseg = 0;
        if(crumbs){                          // WT_PATH: measure the breadcrumb we are about to lay out
            vst_height(H(),crumbh,0,0,0,0);
            int savail = dlw - (iw?iw+6:0) - dotw - (W->name[0] ? 10 : 0);
            if(W->name[0] && savail > (dlw*2)/3) savail = (dlw*2)/3;   // beside a name: two thirds
            sw2 = path_measure(W, savail) + (W->name[0] ? 10 : 0);
            vst_height(H(),15,0,0,0,0);
        } else if(W->subtitle[0]){
            vst_height(H(),12,0,0,0,0);
            int savail = dlw - (iw?iw+6:0) - dotw - 10;    // whatever the name does not need...
            if(savail > dlw/2) savail = dlw/2;             // ...but never more than half the bar
            aes_label_fit(H(), W->subtitle, savail, sfit, sizeof sfit);   // MIDDLE-ELLIPSIS: ours (§11)
            if(sfit[0]){ vqt_extent(H(), sfit, e); sw2 = (e[2]-e[0]) + 10; }
            vst_height(H(),15,0,0,0,0);
        }
        char nfit[64];
        aes_label_fit(H(), W->name, dlw - (iw?iw+6:0) - dotw - sw2, nfit, sizeof nfit);
        vqt_extent(H(), nfit, e); int nw = e[2]-e[0];

        int total = (iw ? iw+6 : 0) + nw + dotw + sw2;
        int gx = W->x + (W->w - total)/2;    // centre the whole group, not just the name
        if(gx < tlx) gx = tlx;               // ...but never under the left buttons
        int cy = W->y + th/2;

        if(ic) { theme_blit(H(),aes_theme(),ic, gx, cy - ih/2, iw, ih); gx += iw + 6; }

        vst_color(H(),pen);
        vst_alignment(H(),VDI_TA_LEFT,VDI_TA_HALF,0,0);
        v_gtext(H(), gx, cy, nfit);
        gx += nw;

        if(dotw){                            // the unsaved-changes dot
            vsf_color(H(),pen); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
            int16_t dr[4]={(int16_t)(gx+3),(int16_t)(cy-3),(int16_t)(gx+8),(int16_t)(cy+2)};
            vr_recfl(H(),dr);
            gx += dotw;
        }
        if(crumbs){                          // THE BREADCRUMB, drawn and hit-tested by US (§11)
            vst_height(H(),crumbh,0,0,0,0);
            path_draw(W, gx + (W->name[0] ? 10 : 0), cy, pen);
            vst_height(H(),15,0,0,0,0);
        } else if(sfit[0]){                  // a plain second line, smaller
            vst_height(H(),12,0,0,0,0);
            v_gtext(H(), gx+10, cy, sfit);
            vst_height(H(),15,0,0,0,0);
        }
        vst_alignment(H(),VDI_TA_LEFT,VDI_TA_TOP,0,0);

        for(int i=0;i<nb;i++) draw_titlebtn(W->tbx[i], W->tby[i], W->tbglyph[i], active);   // over the title, right-aligned
    }
    if(W->kind & W_INFO){          // W_INFO chrome line as a FOOTER at the window bottom; tuck 2px
        int ix=W->x+2, iy=W->y+W->h-AES_INFO_H-2, iw=W->w-4;   // inside the rounded frame corners
        vsf_color(H(),248); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);   // PEN_DLG (object.c): light chrome
        int16_t ir[4]={(int16_t)ix,(int16_t)iy,(int16_t)(ix+iw-1),(int16_t)(iy+AES_INFO_H-1)}; vr_recfl(H(),ir);
        vsl_color(H(),249); vsl_width(H(),1);                                        // PEN_BORDER: TOP divider (work | footer)
        int16_t il[4]={(int16_t)ix,(int16_t)iy,(int16_t)(ix+iw-1),(int16_t)iy}; v_pline(H(),2,il);
        // A STRING (§11).  There is no info callback: a client cannot draw in gemd's chrome,
        // and a toolbar is not chrome — it is CONTENT, and it belongs in a view at the bottom
        // of the work area, drawing into the client's own backing store.
        if(W->info_text[0]){
            vst_color(H(),1); vst_height(H(),13,0,0,0,0);
            char ifit[80];
            int iavail = iw - 16 - ((W->kind&W_SIZER) ? 2*SIZER_SZ : 0);   // clear of the grips
            aes_label_fit(H(), W->info_text, iavail, ifit, sizeof ifit);
            v_gtext(H(), ix+8+((W->kind&W_SIZER)?SIZER_SZ:0), iy+AES_INFO_H/2-7, ifit);
        }
    }
    if(W->kind & W_SIZER){         // resize grips at BOTH ends of the footer band
        int gy=W->y+W->h-SIZER_SZ-2;                    // bottom-aligned in the footer
        draw_grip_l(W->x+2,               gy, SIZER_SZ);  // bottom-left, inside the frame border
        draw_grip  (W->x+W->w-SIZER_SZ-2, gy, SIZER_SZ);  // bottom-right, inside the frame border
    }
    draw_content(hd);
    draw_vscroll(hd);                            // over the reserved right column
}

// The work area + its content (clipped).  The rect is shrunk by the scrollbar column when the
// bar shows, so the app reflows into the narrower span.
static void draw_content(int hd){
    awin*W=&g_w[hd];
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
        //
        // ⚠ AND IT MUST BE CLIPPED TO THE DAMAGE RECT, BY HAND.  gfx_blit is a BACKEND blit: it
        // does not go through the VDI, so it does not honour the VDI clip that wind_redraw_area
        // set for this repaint.  Everything else drawn here does.  That asymmetry ate the chrome:
        //
        //   the desktop is a FULL-SCREEN window (§4).  A client — any client — posts a damage
        //   rect; wind_redraw_area clips to it and redraws the windows under it.  The desktop's
        //   draw_content then blitted its whole 1920x1080 surface over the ENTIRE PLANE, ignoring
        //   the clip, wiping every other window's title bar and frame — while the chrome redraw
        //   in the very same pass WAS clipped to the damage rect, so it could not put them back.
        //
        // Which looked exactly like "chrome draws, then something repaints over it": one frame
        // with chrome, then a repaint, then content-only forever.  It is not a chrome bug at all
        // — the compositor's inner blit was simply unclipped.
        int sw = ww > W->surf.w ? W->surf.w : ww;
        int sh = wh > W->surf.h ? W->surf.h : wh;
        gfx_surface *d = vdi_screen_target();
        int dx0=wx, dy0=wy, dx1=wx+sw, dy1=wy+sh;
        if(g_dmg_on){                                  // ∩ the rect this repaint is allowed to touch
            if(dx0<g_dmg[0]) dx0=g_dmg[0];  if(dy0<g_dmg[1]) dy0=g_dmg[1];
            if(dx1>g_dmg[2]) dx1=g_dmg[2];  if(dy1>g_dmg[3]) dy1=g_dmg[3];
        }
        if(d && dx1>dx0 && dy1>dy0)                    // source origin shifts with the clipped corner
            gfx_blit(d, dx0,dy0, &W->surf, dx0-wx, dy0-wy, dx1-dx0, dy1-dy0);
    } else if(W->draw){
        // LOCAL: the app's content callback, in this same process. In CLIENT mode the same
        // callback runs — but against our own surface, and gemd never sees it (client_paint).
        int16_t clip[4]={(int16_t)wx,(int16_t)wy,(int16_t)(wx+ww-1),(int16_t)(wy+wh-1)};
        vs_clip(H(),1,clip); W->draw(hd,wx,wy,ww,wh,W->ud); vs_clip(H(),0,clip);
    }
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
// SERVER seam (M5): the scrollbar column + thumb, so gemd can repaint JUST the bar when only
// the bar changed (a thumb move, a content-size tick) instead of recompositing the window.
// Returns 0 when no bar is showing (outputs untouched).
int wind_vsb_col(int hd,int*x,int*y,int*w,int*h,int*thy,int*thh){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return 0;
    return vsb_geom(&g_w[hd], x,y,w,h, 0,0,0, 0,0, thy,thh);
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
    //
    // AND IT MEANS *THIS RECT*, NOT EVERYTHING.  This used to ignore the rect and repaint every
    // window's whole surface, posting whole-surface damage — so the desktop (a FULL-SCREEN window)
    // redrew all 1920x1080 and made gemd recomposite the entire plane every time an icon was
    // clicked.  Two consequences, and the second one is not a performance complaint:
    //
    //   - you could WATCH the screen fill, on every click;
    //   - the repaint outran DCLICK_MS, so the second click of a double-click landed after the
    //     window had closed.  Double-click simply stopped working once there was enough on screen
    //     to make the composite slow.  A latency bug wearing a logic bug's clothes.
    //
    // client_paint clamps the rect to each surface and damages only what it drew.
    if(g_mode==AES_CLIENT){
        for(int i=1;i<MAXW;i++) if(g_w[i].used && g_w[i].surf.px)
            client_paint(i, rx,ry, rw,rh);
        return;
    }
    gfx_surface *d = vdi_screen_target(); if(!d) return;
    if(rx<0){ rw+=rx; rx=0; } if(ry<0){ rh+=ry; ry=0; }
    if(rx+rw>d->w) rw=d->w-rx; if(ry+rh>d->h) rh=d->h-ry;
    if(rw<=0||rh<=0) return;
    int16_t clip[4]={(int16_t)rx,(int16_t)ry,(int16_t)(rx+rw-1),(int16_t)(ry+rh-1)};
    vs_clip(H(),2,NULL);                                  // fresh clip stack for the frame
    vs_clip(H(),1,clip);
    g_dmg[0]=rx; g_dmg[1]=ry; g_dmg[2]=rx+rw; g_dmg[3]=ry+rh; g_dmg_on=1;   // ...and for the BLIT
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
    g_dmg_on=0;
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
// THE DIRTY-RECT TOOL (aes.h). One rect, one window, in the space the content callback draws
// in — which is exactly what makes it mode-agnostic: a client's callback space IS its surface,
// a local app's IS the screen, and in both cases the rect goes straight through untranslated.
void wind_redraw_rect(int hd,int x,int y,int w,int h){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    if(g_mode==AES_CLIENT){ client_paint(hd, x,y, w,h); return; }
    wind_redraw_area(x,y,w,h);
}

// THE DAMAGE RECT, for callbacks that want to CULL (aes.h). The VDI clip already guarantees
// correctness — nothing outside the rect changes — but clipped-away work is still WORK: a
// FreeType label renders its glyphs before the clip discards them, and a 50-tile browser
// re-rendered every label to repaint a 4-pixel scroll strip. Most of a 9-second full-track
// drag, measured on the board, was exactly this. Set around a client content callback;
// everywhere else it answers "everything" and culling against it is a no-op.
static int g_dmg_cb[4] = { 0, 0, 32767, 32767 };
void aes_damage(int *x,int *y,int *w,int *h){
    if(x)*x=g_dmg_cb[0]; if(y)*y=g_dmg_cb[1]; if(w)*w=g_dmg_cb[2]; if(h)*h=g_dmg_cb[3];
}

// ---- CLIENT MODE -----------------------------------------------------------
// wind_* keep their EXACT signatures and become messages. The app never learns (§5).
//
// The app's local entry keeps only what the app genuinely owns: its content callback, and its
// own surface. Geometry, z-order and chrome are gemd's, and a client is not told where its
// window is, what is above it, or whether it is visible at all.
#ifdef GEM_XTOS
#include "usys.h"

static int client_events(aes_event *ev,int timeout_ms);   // fwd: our events come from gemd (M4)

// ON XTOS THERE IS NO SINGLE-PROCESS FALLBACK. Everything goes through gemd, and an app that
// cannot reach it FAILS — it does not quietly paint the framebuffer instead.
//
// The fallback used to be the "if there is no gem service, stay LOCAL" line here, and it had to
// go for two reasons:
//   1. it defeats the M7 gate. "No app draws direct any more" is the completion criterion, and a
//      path whose whole purpose is *draw direct when gemd is missing* is a permanent exception;
//   2. it is a SILENT failure mode. With gemd dead or slow, an app did not error — it painted the
//      plane and looked fine. That is the works-by-accident class of bug.
// Not a contradiction with the SDL host: there GEM_XTOS is undefined and single-process is the
// only mode there is — a different PLATFORM, not a fallback (see the #else below).
void wind_client_attach(void){
    if(g_mode==AES_SERVER) return;                  // gemd is nobody's client
    int fd = gem_connect();                         // waits (gem_connect_set_wait) then gives up
    if(fd < 0){
        static const char msg[] =
            "gem: no window server — is gemd running? (there is no single-process mode on XTOS)\n";
        sys_write(2, msg, sizeof msg - 1);
        sys_exit(1);                                // HARD. No local path, no plane access.
    }
    g_gemfd = fd; g_mode = AES_CLIENT;
    aes_set_events(client_events);                  // every event we ever see is gemd's (§3)
}
void wind_client_detach(void){
    if(g_mode!=AES_CLIENT) return;
    if(g_gemfd>=0) sys_close(g_gemfd);              // gemd sees EOF and reaps our windows (§9/§11)
    g_gemfd=-1; g_mode=AES_LOCAL;
}

// RENDER a rect of our content into our OWN surface — no wire traffic. The scroll path uses
// this directly: it draws only the exposed strip but tells gemd about the WHOLE moved band in
// one damage rect, so a scroll costs gemd exactly one recomposite.
static void client_render(int hd,int x,int y,int w,int h){
    awin*W=&g_w[hd];
    if(!W->surf.px || !W->draw) return;
    // Point the AES *and* the VDI's physical target at THIS window's surface. Both matter: the
    // AES handle is what vdi primitives draw through, and vdi_screen_target() is what a callback
    // that blits (the desktop's wallpaper) asks for. A client with two windows would otherwise
    // paint the second one's content into the first one's buffer.
    int save = aes_handle();
    vdi_set_target(&W->surf);
    aes_init(W->vh, aes_theme());
    int16_t clip[4]={(int16_t)x,(int16_t)y,(int16_t)(x+w-1),(int16_t)(y+h-1)};
    vs_clip(W->vh,1,clip);
    g_dmg_cb[0]=x; g_dmg_cb[1]=y; g_dmg_cb[2]=w; g_dmg_cb[3]=h;   // aes_damage: cull to this
    W->draw(hd, 0,0, W->surf.w, W->surf.h, W->ud);  // SURFACE coords: the work area starts at 0,0
    g_dmg_cb[0]=0; g_dmg_cb[1]=0; g_dmg_cb[2]=32767; g_dmg_cb[3]=32767;
    vs_clip(W->vh,0,clip);
    aes_init(save, aes_theme());
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
    client_render(hd,x,y,w,h);
    gem_damage_rect(g_gemfd, hd, W->surf_id, W->surf_gen, x,y,w,h);
}

// ---- CLIENT MODE: events (M4) ----------------------------------------------
// A client has no input device. It has a CHANNEL, and gemd — which owns the pointer, the z-order
// and the chrome — sends it the events it is entitled to: the ones for the window it focused,
// in WINDOW-LOCAL coordinates (the same space its content callback draws in). It is never told
// where it is on screen, what is above it, or that a click landed on somebody else.
//
// Chrome events never arrive: gemd handles the closer, the mover and the sizer itself and the
// client hears only the consequence (WM_CLOSED / WM_MOVED / WM_SIZED), which is exactly the set
// of AES messages a single-process app already handles. §5 again: the app does not change.

static int g_pmx, g_pmy, g_pbtn;             // pointer state, as last reported by gemd
static int g_evwin;                          // WHICH of our windows the last input event was for.
// A client cannot work this out for itself: coordinates are window-LOCAL, so two windows both
// see a click at (10,10). gemd knows — it hit-tested the z-order — so it says, and this is where
// the app reads the answer (wind_find() cannot help: a client has no z-order and no geometry).
int aes_event_win(void){ return g_evwin; }

// gem_await() (used inside wind_open/wind_create) has to skip messages it is not waiting for.
// It must not DROP input while it does — a swallowed button-up is a stuck drag. So strays are
// dispatched here instead: AES messages go into the app's message pipe, input events into this
// small ring, and client_events() drains the ring before it reads the channel again.
#define CPQ 16
static aes_event g_evq[CPQ]; static int g_evh, g_evt;
static void evq_push(const aes_event *e){ int n=(g_evt+1)%CPQ; if(n==g_evh) return; g_evq[g_evt]=*e; g_evt=n; }
static int  evq_pop(aes_event *e){ if(g_evh==g_evt) return 0; *e=g_evq[g_evh]; g_evh=(g_evh+1)%CPQ; return 1; }

static void post_msg(int type,int hd,int a,int b,int c,int d){
    int16_t m[8]={(int16_t)type,1,0,(int16_t)hd,(int16_t)a,(int16_t)b,(int16_t)c,(int16_t)d};
    appl_write(0,16,m);
}

// gemd resized us. SAME surf_id means the new work area fitted inside the surface's CAPACITY —
// nothing to remap, the extent just grew inside the buffer we already hold (§12). A NEW id means
// capacity was exceeded and gemd made us a bigger one: drop the old mapping and take it.
static void client_sized(const gem_msg *m){
    int hd=m->w[1]; if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    awin*W=&g_w[hd];
    int nid=(int)m->u[0];
    if(nid!=W->surf_id){
        if(W->surf_id>=0) gem_surf_unmap(g_gemfd,W->surf_id);
        uint32_t*px=gem_surf_map(nid);
        if(!px){ W->surf_id=-1; W->surf.px=0; return; }        // gemd will reap us; nothing to draw
        W->surf_id=nid; W->surf.px=px;
    }
    W->surf_gen=m->u[1];
    W->surf.w=m->w[2]; W->surf.h=m->w[3]; W->surf.stride=m->w[4];   // stride = CAPACITY width (§12)
    // The resize CLAMPED the scroll server-side. Take the truth BEFORE painting: a stale copy
    // here means the next scroll blits by a wrong delta — stale bands through the content.
    W->scroll_x=(int)m->u[2]; W->scroll_y=(int)m->u[3];
    client_paint(hd, 0,0, W->surf.w, W->surf.h);
    post_msg(WM_SIZED,hd,0,0,W->surf.w,W->surf.h);   // the app reflows; work coords, as it draws in
}

// THE SCROLL CONSEQUENCE (M5). gemd owns the bar and ran the interaction; we own the pixels.
// The rows that survive the scroll are ALREADY DRAWN — in our own backing store — so they move
// with an internal blit, only the exposed strip is rendered, and BOTH rects go out as damage.
// A full render per thumb notch is exactly the heavyweight repaint this message exists to kill.
//
// The blit shifts the WHOLE surface: the AES was told the view scrolls, and it cannot know what
// an app pinned over it. Pinned content (a status bar) is the app's, and the app repaints it on
// the WM_VSLID posted below — a small rect through wind_redraw_rect, not a surface render.
static int client_scrolled(const gem_msg *m){
    int hd=m->w[1]; if(hd<1||hd>=MAXW||!g_w[hd].used) return 0;
    awin*W=&g_w[hd];
    int dx=(int)m->u[0]-W->scroll_x, dy=(int)m->u[1]-W->scroll_y;
    W->scroll_x=(int)m->u[0]; W->scroll_y=(int)m->u[1];
    if(!dx && !dy) return 0;                        // the echo of our own request: nothing moved
    if(!W->surf.px || !W->draw) return 0;
    // The blit covers the SCROLLING BAND only: [0, vh). Anything the app pinned over the scroll
    // (wind_pin_bottom — a status bar) stays where it is; blitting the whole surface dragged a
    // stale copy of the bar up through the list, observed on the board.
    //
    // (If stale partial-width rows EVER reappear here: this memcpy is newlib's NEON one, and it
    // was the messenger for a KERNEL bug once — tasks preempted mid-copy resumed with clobbered
    // NEON registers until configUSE_TASK_FPU_SUPPORT became 2. `make scrollsim` proves the
    // blit math; suspect the context switch, not this code.)
    int w=W->surf.w, h=W->surf.h, ady=dy<0?-dy:dy;
    int pin=W->pin_bottom; if(pin<0) pin=0; if(pin>h) pin=h;
    int vh=h-pin;
    if(dx || ady>=vh){                              // sideways / a whole view: nothing survives
        client_paint(hd, 0,0, w,h);
    } else {
        uint32_t *px=W->surf.px; int st=W->surf.stride, keep=vh-ady;
        if(dy>0) for(int yy=0;     yy<keep; yy++) memcpy(px+(size_t)yy*st,      px+(size_t)(yy+dy)*st, (size_t)w*4);
        else     for(int yy=keep-1;yy>=0;  yy--) memcpy(px+(size_t)(yy+ady)*st, px+(size_t)yy*st,      (size_t)w*4);
        client_render(hd, 0, dy>0?keep:0, w, ady);  // DRAW only the exposed strip...
        gem_damage_rect(g_gemfd, hd, W->surf_id, W->surf_gen, 0, 0, w, vh);
                                                    // ...but ONE damage for the whole moved
                                                    // band: gemd recomposites exactly once
    }
    post_msg(WM_VSLID,hd,0,0,0,0);                  // pinned content is yours: repaint it now
    return AES_MESAG;
}

// One message from gemd -> either an aes_event (returned) or a queued AES message (0).
static int client_dispatch(const gem_msg *m, aes_event *ev){
    memset(ev,0,sizeof *ev);
    ev->mx=g_pmx; ev->my=g_pmy; ev->button=g_pbtn;
    switch(m->w[0]){
    case GEM_EV_KEY:
        g_evwin=m->w[1];
        ev->type=AES_KEY; ev->key=m->w[2]; ev->shift=m->w[3]; return AES_KEY;
    case GEM_EV_BUTTON:
        g_evwin=m->w[1];
        g_pmx=m->w[2]; g_pmy=m->w[3]; g_pbtn=m->w[4];
        ev->mx=g_pmx; ev->my=g_pmy; ev->button=g_pbtn; ev->shift=m->w[5];
        ev->type = m->w[4] ? AES_BTN_DOWN : AES_BTN_UP; return ev->type;
    case GEM_EV_MOTION:
        g_evwin=m->w[1];
        g_pmx=m->w[2]; g_pmy=m->w[3]; g_pbtn=m->w[4];
        ev->mx=g_pmx; ev->my=g_pmy; ev->button=g_pbtn;
        ev->type=AES_MOTION; return AES_MOTION;
    case GEM_MSG_REDRAW:                                   // first paint + resize ONLY (§3)
        client_paint(m->w[1], m->w[2],m->w[3],m->w[4],m->w[5]); return 0;
    case GEM_MSG_SIZED:   client_sized(m); return AES_MESAG;
    case GEM_MSG_VSLID:   return client_scrolled(m);       // blit + strip, never a full render
    case GEM_MSG_MOVED:                                    // no redraw implied: gemd moved the pixels
        if(m->w[1]>=1 && m->w[1]<MAXW && g_w[m->w[1]].used){
            awin*W=&g_w[m->w[1]]; W->x=m->w[2]; W->y=m->w[3]; W->w=m->w[4]; W->h=m->w[5]; }
        post_msg(WM_MOVED,m->w[1],m->w[2],m->w[3],m->w[4],m->w[5]); return AES_MESAG;
    case GEM_MSG_CLOSED:                                   // the CLOSER was clicked. Closing is OURS.
        post_msg(WM_CLOSED,m->w[1],0,0,0,0); return AES_MESAG;
    case GEM_MSG_TBUTTON:                                  // a title button was pressed (§11): the
        post_msg(WM_TBUTTON,m->w[1],m->w[2],0,0,0);        // app learns WHICH, never WHERE
        return AES_MESAG;
    case GEM_MSG_PATHSEG:                                  // a breadcrumb component was clicked: we
        post_msg(WM_PATHSEG,m->w[1],m->w[2],0,0,0);        // set the string, we get back an INDEX
        return AES_MESAG;
    case GEM_MSG_ACTIVATE:
        post_msg(m->w[2]?WM_TOPPED:WM_UNTOPPED,m->w[1],0,0,0,0); return AES_MESAG;
    default: return 0;                                     // not ours to understand
    }
}

// ---- CLIENT MODE: the chrome MODEL goes on the wire (§11) -------------------
// A pointer means nothing across a process boundary; a buffer of characters means the same
// thing everywhere. So a client's wind_set reassembles the hi/lo pointer, reads the BYTES, and
// sends them — and from that moment the model is GEMD'S. It redraws the title bar from its own
// copy, on a drag, on a theme change, on a reveal, and with a wedged owner (§11.1).
//
// A string longer than one record is sent as several: the record stays a FIXED 32 bytes (no
// framing to desynchronise — gemproto.h), and w[3] carries the byte offset of the chunk.
static void client_send_str(int hd,int field,const char*s){
    int n = s ? (int)strlen(s) : 0;
    if(n > GEM_STR_MAX) n = GEM_STR_MAX;
    for(int off=0; off<=n; off+=GEM_STR_CHUNK){        // <= n: an empty string still sends one record
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_SET; m.w[1]=(int16_t)hd; m.w[2]=(int16_t)field; m.w[3]=(int16_t)off;
        int len=n-off; if(len>GEM_STR_CHUNK) len=GEM_STR_CHUNK;
        if(len>0) memcpy((char*)&m.w[4], s+off, (size_t)len);   // the rest of the record is already 0
        gem_send(g_gemfd,&m);
    }
}
// 1 = sent (the model is gemd's); 0 = not gemd's field, handle it locally.
static int client_wind_set(int hd,int field,int a,int b,int c,int d){
    switch(field){
    case WF_NAME: case WF_INFO: case WF_SUBTITLE: case WF_ICON:
        client_send_str(hd, field, (const char*)WIND_PTR(a,b));
        return 1;
    case WF_CURRXYWH: {
        // GEOMETRY IS GEMD'S TOO (M5). The rect goes out as a REQUEST and nothing changes
        // here: the clamped truth comes back as MSG_MOVED (and MSG_SIZED when the work area
        // changed), through the same door a sizer drag uses. A client that trusted its own
        // request would disagree with the screen every time gemd said no.
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_SET; m.w[1]=(int16_t)hd; m.w[2]=(int16_t)field;
        m.w[3]=(int16_t)a; m.w[4]=(int16_t)b; m.w[5]=(int16_t)c; m.w[6]=(int16_t)d;
        gem_send(g_gemfd,&m);
        return 1;
    }
    case WF_TITLEFLAGS: {
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_SET; m.w[1]=(int16_t)hd; m.w[2]=(int16_t)field; m.w[3]=(int16_t)a;
        gem_send(g_gemfd,&m);
        return 1;
    }
    case WF_TITLEBTNS: {
        const int *g=(const int*)WIND_PTR(a,b);
        int n=c; if(n<0) n=0; if(n>WIND_MAXTB) n=WIND_MAXTB;
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_SET; m.w[1]=(int16_t)hd; m.w[2]=(int16_t)field; m.w[3]=(int16_t)n;
        for(int i=0;i<n;i++) m.u[i] = (uint32_t)(g ? g[i] : WTG_NONE);   // the glyph LIST, not a pointer
        gem_send(g_gemfd,&m);
        return 1;
    }
    default: return 0;
    }
}

// Called from gem_await's skip path (via wind_client_stray): NEVER drop an event on the floor.
void wind_client_stray(const gem_msg *m){
    aes_event e;
    int t = client_dispatch(m,&e);
    if(t && t!=AES_MESAG) evq_push(&e);                    // AES messages are already in the pipe
}

// THE CLIENT'S EVENT SOURCE. One poll on one fd — the channel — so a timeout is a timeout and an
// event is an event, and there is no second place an app could get input from.
static int client_events(aes_event *ev,int timeout_ms){
    if(evq_pop(ev)) return ev->type;                       // strays picked up during a gem_await
    for(;;){
        struct xt_pollfd pf; pf.fd=g_gemfd; pf.events=XT_POLLIN; pf.revents=0;
        int r=sys_poll(&pf,1,timeout_ms);
        if(r<0){ if(r==-4) continue;                       // -EINTR: a signal, not a failure
                 memset(ev,0,sizeof *ev); ev->type=AES_QUIT; return AES_QUIT; }
        if(r==0){ memset(ev,0,sizeof *ev); ev->mx=g_pmx; ev->my=g_pmy; ev->button=g_pbtn;
                  ev->type=AES_TIMER; return AES_TIMER; }
        gem_msg m;
        if(gem_recv(g_gemfd,&m)!=0){                       // EOF: gemd is gone. Nothing works now.
            memset(ev,0,sizeof *ev); ev->type=AES_QUIT; return AES_QUIT; }
        int t=client_dispatch(&m,ev);
        if(t) return t;                                    // AES_MESAG -> evnt_multi reads the pipe
    }
}
#else
void wind_client_attach(void){}                     // SDL host: there is no gemd, and no usys.h
void wind_client_detach(void){}
int  aes_event_win(void){ return 0; }               // single process: nobody routed anything to us
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
        // Already open: the classic "wind_open again resizes in place" idiom. It must NOT
        // re-run the open handshake — that would open a second workstation on this side and
        // orphan a surface on gemd's. It is a geometry request, so it goes out as one.
        if(W->surf.px){ client_wind_set(hd,WF_CURRXYWH,x,y,w,h); return; }
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
        // vdi_init MEMSETS the workstation table, so it must run exactly ONCE per client: a
        // second window would otherwise wipe the first window's workstation (§10: opened once,
        // never re-opened). After that, retarget — a workstation holds a POINTER to the surface.
        static int g_vdi_up;
        if(!g_vdi_up){ vdi_init(&W->surf); g_vdi_up=1; } else vdi_set_target(&W->surf);
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
    if(g_w[hd].kind & W_BOTTOM){
        // §4(1): insert AT THE BOTTOM, not on top. A desktop restarted while apps are running
        // is created LAST — without this it would land on top and swallow the whole session.
        for(int i=g_nz;i>0;i--) g_z[i]=g_z[i-1];
        g_z[0]=hd; g_nz++;
        wind_redraw_win(hd);                             // its OWN rect: it is underneath, so the
        return;                                          // windows above it redraw over it anyway
    }
    { int old = g_nz ? g_z[g_nz-1] : 0;               // whoever was on top is now stale: draw_one
      g_z[g_nz++]=hd; raise_repaint(hd,old); }        // picks its titlebar art from `active` (§11)
}
// Repaint old ∪ new — the ONLY correct shape for a geometry change, and the reason there is a
// helper for it: every one of these sites used to reach for wind_redraw() (the whole plane).
// On the A9 gemd composites in SOFTWARE, so a full-plane repaint is ~8 MB of pixel work you can
// WATCH fill down the screen — and it is not merely slow. One of them outran the double-click
// timeout and made double-click "stop working". A full-screen repaint needs a documented reason.
static void redraw_union(int ox,int oy,int ow,int oh,int nx,int ny,int nw,int nh){
    int x0 = ox<nx?ox:nx, y0 = oy<ny?oy:ny;
    int x1 = (ox+ow)>(nx+nw)?(ox+ow):(nx+nw), y1 = (oy+oh)>(ny+nh)?(oy+oh):(ny+nh);
    wind_redraw_area(x0,y0,x1-x0,y1-y0);
}
static void zremove(int hd);
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
    awin*W=&g_w[hd]; int x=W->x,y=W->y,w=W->w,h=W->h;
    zremove(hd);
    wind_redraw_area(x,y,w,h);                        // the rect it vacated...
    if(g_nz) wind_redraw_win(g_z[g_nz-1]);            // ...and whoever INHERITED the top: it is
                                                      // active now, and nothing else would say so
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
/* DEPRECATED: sugar over wind_set(WF_NAME).  It is now implemented THROUGH the
 * standard call rather than beside it — which is the only reason it is safe to keep.
 * (It had its OWN wire message once. That was the bug in miniature: a second path to
 * the same model, so the standard one could stay broken and nobody would notice.) */
void wind_set_name(int hd,const char*n){
    wind_set(hd, WF_NAME, WIND_PTR_HI(n), WIND_PTR_LO(n), 0, 0);
}
void wind_content(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].draw=fn; g_w[hd].ud=ud; } }
void wind_content_size(int hd,int w,int h){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    awin*W=&g_w[hd];
    if(w<0)w=0; if(h<0)h=0;
#ifdef GEM_XTOS
    // THE SCROLL MODEL IS GEMD'S (M5): the scrollbar is chrome, and gemd cannot draw a thumb
    // for a content height it was never told. Sent ONLY ON CHANGE — apps report content size
    // from inside their draw callback, so an unconditional send is a wire message per paint.
    if(g_mode==AES_CLIENT){
        if(W->content_w==w && W->content_h==h) return;
        W->content_w=w; W->content_h=h;                    // our copy: local scroll clamp below
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_SET; m.w[1]=(int16_t)hd; m.w[2]=WF_CONTENTSIZE;
        m.u[0]=(uint32_t)w; m.u[1]=(uint32_t)h;            // u32s: a listing outgrows 32767px
        gem_send(g_gemfd,&m);
        return;
    }
#endif
    W->content_w=w; W->content_h=h; clamp_scroll(W);
}
// Declare a non-scrolling strip at the work-area BOTTOM (a status bar). Client-side model
// only: it bounds the scroll BLIT in client_scrolled — no wire message, gemd never needs it.
void wind_pin_bottom(int hd,int px){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    g_w[hd].pin_bottom = px<0?0:px;
}
int wind_scroll_y(int hd){ return (hd>=1&&hd<MAXW)?g_w[hd].scroll_y:0; }
int wind_scroll_x(int hd){ return (hd>=1&&hd<MAXW)?g_w[hd].scroll_x:0; }
void wind_set_scroll(int hd,int x,int y){
    if(hd<1||hd>=MAXW) return;
#ifdef GEM_XTOS
    // A REQUEST, like a rect (M5). Set locally too — OPTIMISTICALLY, clamped with the same
    // numbers gemd will use (our content copy vs our surface), so the next paint draws at the
    // offset we asked for without a round trip; gemd answers MSG_VSLID only when its clamp
    // DISAGREES, and that answer corrects us.
    if(g_mode==AES_CLIENT){
        awin*W=&g_w[hd];
        int maxx=W->content_w-W->surf.w; if(maxx<0)maxx=0;
        int maxy=W->content_h-W->surf.h; if(maxy<0)maxy=0;
        if(x<0)x=0; if(x>maxx)x=maxx;
        if(y<0)y=0; if(y>maxy)y=maxy;
        if(x==W->scroll_x && y==W->scroll_y) return;
        W->scroll_x=x; W->scroll_y=y;
        gem_msg m; memset(&m,0,sizeof m);
        m.w[0]=GEM_WIND_SET; m.w[1]=(int16_t)hd; m.w[2]=WF_SCROLL;
        m.u[0]=(uint32_t)x; m.u[1]=(uint32_t)y;
        gem_send(g_gemfd,&m);
        return;
    }
#endif
    g_w[hd].scroll_x=x; g_w[hd].scroll_y=y; clamp_scroll(&g_w[hd]);
}
int wind_handle_wheel(int mx,int my,int delta){
    int hd=wind_find(mx,my); if(!hd) return 0; awin*W=&g_w[hd];
    if(!vsb_on(W)) return 0;                       // nothing scrollable under the pointer
    int before=W->scroll_y;
    W->scroll_y -= delta*SB_LINE; clamp_scroll(W);  // wheel-up (delta>0) -> toward the top
    if(W->scroll_y!=before) wind_redraw_win(hd);
    return 1;
}
/* DEPRECATED: sugar over wind_set(WF_TITLEBTNS), implemented THROUGH it (like wind_set_name). */
void wind_titlebtns(int hd,const int*glyphs,int n){
    wind_set(hd, WF_TITLEBTNS, WIND_PTR_HI(glyphs), WIND_PTR_LO(glyphs), n, 0);
}

void wind_get(int hd,int field,int*a,int*b,int*c,int*d){
    if(hd==0){ int x,y,w,h; work_area(&x,&y,&w,&h); if(a)*a=x; if(b)*b=y; if(c)*c=w; if(d)*d=h; return; }  // desktop
    if(hd<1||hd>=MAXW){ if(a)*a=0; return; }
    awin*W=&g_w[hd]; int x=W->x,y=W->y,w=W->w,h=W->h;
    // A CLIENT'S WORK AREA IS ITS SURFACE, and it starts at 0,0. It must not compute the chrome
    // inset itself (it does not know the theme's border width, and §5 says it may not care): the
    // drawable gemd gave it IS the answer, and it is the same space its content callback draws in
    // and its input events arrive in. One coordinate system, no chrome model on the client side.
    if(g_mode==AES_CLIENT && field==WF_WORKXYWH){
        if(a)*a=0; if(b)*b=0; if(c)*c=W->surf.w; if(d)*d=W->surf.h; return;
    }
    if(field==WF_WORKXYWH) app_work(W,&x,&y,&w,&h);   // already minus the scrollbar column
    else if(field==WF_PREVXYWH){ x=W->px;y=W->py;w=W->pw;h=W->ph; }
    if(a)*a=x; if(b)*b=y; if(c)*c=w; if(d)*d=h;
}

/* Read a chrome field back.  Pointer fields return the AES's OWN copy, hi/lo split —
 * so a caller gets a stable string it did not have to keep alive. */
int wind_get_str(int hd,int field,int *a,int *b){
    if(hd<1||hd>=MAXW) return 0; awin*W=&g_w[hd];
    const char *s = 0;
    switch(field){
    case WF_NAME:     s = W->name;     break;
    case WF_INFO:     s = W->info_text; break;
    case WF_SUBTITLE: s = W->subtitle; break;
    case WF_ICON:     s = W->icon;     break;
    default: return 0;
    }
    if(a)*a = WIND_PTR_HI(s);
    if(b)*b = WIND_PTR_LO(s);
    return 1;
}
/* Copy a hi/lo-split string field.  The AES takes a COPY, always: the client's pointer
 * is meaningless to gemd, and a copy is what lets gemd redraw chrome with no client. */
static void set_str(char *dst, size_t cap, int a, int b) {
    const char *s = (const char *)WIND_PTR(a, b);
    snprintf(dst, cap, "%s", s ? s : "");
}

void wind_set(int hd,int field,int a,int b,int c,int d){
    if(hd<1||hd>=MAXW) return; awin*W=&g_w[hd];
#ifdef GEM_XTOS
    // CHROME IS GEMD'S. A client does not keep a chrome model, does not draw one, and does not
    // repaint one: it says what the window IS, and gemd renders it (§11).
    if(g_mode==AES_CLIENT && client_wind_set(hd,field,a,b,c,d)){
        // ...but it may still READ BACK what it set. wind_get(WF_NAME) is a classic call and an
        // app is entitled to it, so cache the strings — and ONLY the strings. gemd never rewrites
        // a title, so for these the request IS the truth. Geometry is the exact opposite: gemd
        // CLAMPS, and the truth arrives later as MSG_MOVED, so a client that cached WF_CURRXYWH
        // would disagree with the screen every time gemd said no. Cache what cannot be refused.
        switch(field){
        case WF_NAME:     set_str(W->name,     sizeof W->name,     a,b); break;
        case WF_INFO:     set_str(W->info_text,sizeof W->info_text,a,b); break;
        case WF_SUBTITLE: set_str(W->subtitle, sizeof W->subtitle, a,b); break;
        case WF_ICON:     set_str(W->icon,     sizeof W->icon,     a,b); break;
        }
        return;
    }
#endif
    switch(field){
    /* ---- classic ---------------------------------------------------------- */
    case WF_NAME:     set_str(W->name,     sizeof W->name,     a,b); wind_redraw_win(hd); break;
    case WF_INFO:     set_str(W->info_text,sizeof W->info_text,a,b); wind_redraw_win(hd); break;
    case WF_TOP:      wind_raise(hd); break;
    case WF_CURRXYWH: {
        W->px=W->x;W->py=W->y;W->pw=W->w;W->ph=W->h;
        int ox=W->x,oy=W->y,ow=W->w,oh=W->h;
        W->x=a;W->y=b;W->w=c;W->h=d; clamp_win(W); clamp_scroll(W);
        redraw_union(ox,oy,ow,oh, W->x,W->y,W->w,W->h);   // NOT the plane: the rect it left ∪ took
        break;
    }
    /* ---- our extensions --------------------------------------------------- */
    case WF_SUBTITLE: set_str(W->subtitle, sizeof W->subtitle, a,b); wind_redraw_win(hd); break;
    case WF_ICON:     set_str(W->icon,     sizeof W->icon,     a,b); wind_redraw_win(hd); break;
    case WF_TITLEFLAGS: W->titleflags = a;                           wind_redraw_win(hd); break;
    case WF_TITLEBTNS: {
        const int *g = (const int *)WIND_PTR(a,b);
        int n = c; if(n<0) n=0; if(n>WIND_MAXTB) n=WIND_MAXTB;
        W->ntb = n;
        for(int i=0;i<n;i++) W->tbglyph[i] = g ? g[i] : WTG_NONE;
        wind_redraw_win(hd);
        break;
    }
    default: break;
    }
}

int wind_find(int x,int y){
    for(int i=g_nz-1;i>=0;i--){ awin*W=&g_w[g_z[i]]; if(x>=W->x&&x<W->x+W->w&&y>=W->y&&y<W->y+W->h) return g_z[i]; }
    return 0;
}

int wind_top(void){ return g_nz ? g_z[g_nz-1] : 0; }

// THE WINDOW THAT LOSES THE TOP MUST BE REPAINTED TOO.
//
// draw_one picks the titlebar art from `active` (= is this the topmost window), so a z-order
// change makes TWO windows stale, not one — and repainting only the raised one left the old top
// wearing the ACTIVE title bar for as long as it stayed on screen. Every window looked focused,
// which is worse than none of them looking focused: focus is what the chrome is FOR.
static void raise_repaint(int hd,int old){
    if(old && old!=hd) wind_redraw_win(old);   // it is no longer active: redraw its bar
    wind_redraw_win(hd);                       // ...and it now is
}
void wind_raise(int hd){
    if(hd<1||hd>=MAXW) return;
    if(g_w[hd].kind & W_BOTTOM) return;   // §4(2): NEVER topped by a click. A desktop that came
                                          // to the front on a click would hide every app.
    for(int i=0;i<g_nz;i++) if(g_z[i]==hd){
        int old = g_z[g_nz-1];
        if(old==hd) return;                                    // already top: nothing to restyle
        zremove(hd); g_z[g_nz++]=hd; raise_repaint(hd,old); return;
    }
}

static void post(int type,int hd,int a,int b,int c,int d){
    int16_t m[8]={(int16_t)type,1,0,(int16_t)hd,(int16_t)a,(int16_t)b,(int16_t)c,(int16_t)d}; appl_write(0,16,m);
}
static void raise(int hd){ zremove(hd); g_z[g_nz++]=hd; }

// Frame interaction. In gemd this is the SERVER's hit test — the closer, the mover and the sizer
// are chrome, chrome is gemd's, and a client never sees these clicks (it hears the consequence:
// WM_CLOSED / WM_MOVED / WM_SIZED). Returns 1 when the frame consumed the click; 0 means the
// click was in the work area, and under gemd that is what gets forwarded to the owning client.
//
// A CLIENT never runs this: its local list has no z-order, no geometry it may trust, and no
// chrome. Its clicks are already routed and already window-local.
int wind_handle_click(int mx,int my){
    if(g_mode==AES_CLIENT) return 0;               // gemd hit-tested it; this one is ours to use
    int hd = wind_find(mx,my);
    if(!hd) return 0;
    awin*W=&g_w[hd];
    // Click-to-raise — but NEVER for W_BOTTOM (§4(2)). wind_raise() honours it and this path did
    // not: a click on the desktop (a screen-sized W_BOTTOM window) would have topped it and
    // swallowed every app on the machine. It falls through instead, so a bottom window still gets
    // its click; it just does not come to the front.
    if(g_z[g_nz-1]!=hd && !(W->kind & W_BOTTOM)){
        int old = g_z[g_nz-1];                      // it loses the ACTIVE title bar: repaint it too
        raise(hd); raise_repaint(hd,old); post(WM_TOPPED,hd,0,0,0,0); return 1; }
    int th=tbh();
    int tx=W->x, ty=W->y, tw=W->w;               // flush title bar
    // close box
    if((W->kind&W_CLOSER) && mx>=tx+8 && mx<tx+8+WTB_W && my>=ty && my<ty+th){ post(WM_CLOSED,hd,0,0,0,0); return 1; }
    // maximise box (W_FULLER): toggle between the full desktop work area and the
    // saved pre-maximise rect, then WM_SIZED so the app reflows to the new size.
    if((W->kind&W_FULLER) && mx>=tx+8+WTB_PITCH && mx<tx+8+WTB_PITCH+WTB_W && my>=ty && my<ty+th){
        int ox=W->x,oy=W->y,ow=W->w,oh=W->h;              // the rect it is leaving
        if(!W->maxed){ W->sx=W->x; W->sy=W->y; W->sw=W->w; W->sh=W->h;
                       int ax,ay,aw,ah; work_area(&ax,&ay,&aw,&ah);
                       W->x=ax; W->y=ay; W->w=aw; W->h=ah; W->maxed=1; }
        else         { W->x=W->sx; W->y=W->sy; W->w=W->sw; W->h=W->sh; W->maxed=0; }
        clamp_win(W); clamp_scroll(W);
        redraw_union(ox,oy,ow,oh, W->x,W->y,W->w,W->h);   // maximise/restore: old ∪ new, not the plane
        post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
    }
    // right-side title buttons: OUR chrome, OUR hit test. The app is told WHICH button was
    // pressed (WM_TBUTTON, msg[4] = index) and never where it is — §11: gemd routes input, so a
    // press is a message, the same shape as WM_CLOSED. Checked before the mover, so a button
    // press is a press and not the start of a drag.
    if((W->kind&W_NAME) && my>=ty && my<ty+th)
        for(int i=0;i<W->ntb;i++)
            if(W->tbw[i]>0 && mx>=W->tbx[i] && mx<W->tbx[i]+W->tbw[i]){
                post(WM_TBUTTON,hd,i,0,0,0); return 1; }
    // BREADCRUMB SPANS (WT_PATH): our chrome, our hit test. The app gets the INDEX of the path
    // component it set — never a rect, never a pixel (§11).  Before the mover, so a crumb click is
    // a click; the rest of the bar still drags.
    if((W->kind&W_NAME) && (W->titleflags & WT_PATH) && my>=ty && my<ty+th)
        for(int i=0;i<W->nseg;i++)
            if(W->segw[i]>0 && mx>=W->segx[i] && mx<W->segx[i]+W->segw[i]){
                post(WM_PATHSEG,hd,W->segn[i],0,0,0); return 1; }
    // title bar -> drag (live move). The WHOLE bar drags: there is no app-drawn span in it
    // to click any more, so there is no press-vs-drag ambiguity to resolve.
    if((W->kind&W_MOVER) && my>=ty && my<ty+th && mx>=tx && mx<tx+tw){
        int gx=mx-W->x, gy=my-W->y;
        if(g_ovl_begin && g_ovl_begin(W->x,W->y,W->w,W->h)){    // A9: lift window into the HW overlay
            int ox=W->x, oy=W->y, ow=W->w, oh=W->h;            // vacated rect
            W->hidden=1; wind_redraw_area(ox,oy,ow,oh);         // erase JUST the rect it vacated
                                                               // (it is in the overlay; the plane
                                                               // below it is all that changed)...
            if(g_ovl_present) g_ovl_present(ox,oy,ow,oh);      // ...push the now-behind pixels
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ W->x=e.mx-gx; W->y=e.my-gy; clamp_win(W); g_ovl_move(W->x,W->y); } // register write, no redraw
                if(t==AES_BTN_UP) break; }
            W->hidden=0;                                       // paint it at its new home, under the
            redraw_union(ox,oy,ow,oh, W->x,W->y,W->w,W->h);     // overlay: old ∪ new, never the plane
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
                if(t==AES_MOTION){ int ow=W->w,oh=W->h; int nw=e.mx-W->x, nh=e.my-W->y; if(nw<WIND_MIN_W)nw=WIND_MIN_W; if(nh<WIND_MIN_H)nh=WIND_MIN_H; W->w=nw; W->h=nh; clamp_scroll(W);
                    wind_redraw_area(W->x, W->y, ow>nw?ow:nw, oh>nh?oh:nh); }   // old ∪ new (same top-left)
                if(t==AES_BTN_UP) break; }
            post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
        }
        if(lgrip){
            int right=W->x+W->w;                                 // pin the right edge
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ int ox=W->x,oh=W->h; int nx=e.mx, nh=e.my-W->y; int nw=right-nx;
                    if(nw<WIND_MIN_W){ nw=WIND_MIN_W; nx=right-nw; } if(nh<WIND_MIN_H)nh=WIND_MIN_H;
                    W->x=nx; W->w=nw; W->h=nh; clamp_scroll(W);
                    int ux=ox<nx?ox:nx; wind_redraw_area(ux, W->y, right-ux, oh>nh?oh:nh); }   // old ∪ new (right pinned)
                if(t==AES_BTN_UP) break; }
            post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
        }
    }
    // vertical scrollbar in the reserved right column (arrows / thumb drag / track page)
    //
    // A scroll step repaints ONLY THE BAR in server mode. Server-side the content is a
    // backing-store blit that does not change until the client's damage arrives — the only
    // pixels a scroll step moves HERE are the thumb's. Recompositing the whole window per
    // thumb notch was most of a 9-SECOND full-track drag, measured on the board. Local mode
    // keeps the window repaint: there the content callback draws live with the new offset.
    #define VSB_STEP_REDRAW(hd, W) do { int bx_,by_,bw_,bh_; \
        if (g_mode==AES_SERVER && vsb_geom((W),&bx_,&by_,&bw_,&bh_,0,0,0,0,0,0,0)) \
             wind_redraw_area(bx_,by_,bw_,bh_); \
        else wind_redraw_win(hd); } while (0)
    { int cx,cy,cw,ch,upy,dny,arrh,trky,trkh,thy,thh;
      if(vsb_geom(W,&cx,&cy,&cw,&ch,&upy,&dny,&arrh,&trky,&trkh,&thy,&thh) &&
         mx>=cx && mx<cx+cw && my>=cy && my<cy+ch){
        if(arrh>0 && my<upy+arrh){                              // up arrow: one line
            W->scroll_y-=SB_LINE; clamp_scroll(W); VSB_STEP_REDRAW(hd,W); post(WM_VSLID,hd,0,0,0,0); return 1; }
        if(arrh>0 && my>=dny){                                  // down arrow: one line
            W->scroll_y+=SB_LINE; clamp_scroll(W); VSB_STEP_REDRAW(hd,W); post(WM_VSLID,hd,0,0,0,0); return 1; }
        if(my<thy){                                             // track above thumb: page up
            int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
            W->scroll_y-=(wh>SB_LINE?wh-SB_LINE:wh); clamp_scroll(W); VSB_STEP_REDRAW(hd,W); post(WM_VSLID,hd,0,0,0,0); return 1; }
        if(my>=thy+thh){                                        // track below thumb: page down
            int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
            W->scroll_y+=(wh>SB_LINE?wh-SB_LINE:wh); clamp_scroll(W); VSB_STEP_REDRAW(hd,W); post(WM_VSLID,hd,0,0,0,0); return 1; }
        // on the thumb: drag it, mapping travel back to scroll_y proportionally. The scroll is
        // LIVE: every motion that moves it posts WM_VSLID, and in gemd the event wait flushes
        // the pipe each lap — so the owning client scrolls its store WHILE the thumb moves,
        // not at release. (Release-only was the classic behaviour; it read as "dragging does
        // not work" the moment the machine was fast enough to expect better.)
        int grab=my-thy;
        for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
            if(t==AES_MOTION){
                int t2y,t2h,tk2y,tk2h; vsb_geom(W,0,0,0,0,0,0,0,&tk2y,&tk2h,&t2y,&t2h);
                int span=tk2h-t2h; int wx,wy,ww,wh; full_work(W,&wx,&wy,&ww,&wh); (void)wx;(void)wy;(void)ww;
                int maxs=W->content_h-wh; if(maxs<0)maxs=0;
                int rel=e.my-grab-tk2y; int before=W->scroll_y;
                if(span>0){ W->scroll_y=(int)((long)rel*maxs/span); }
                clamp_scroll(W); VSB_STEP_REDRAW(hd,W);
                if(W->scroll_y!=before) post(WM_VSLID,hd,0,0,0,0); }
            if(t==AES_BTN_UP) break; }
        post(WM_VSLID,hd,0,0,0,0); return 1;
      } }
    return 0;     // click in the work area -> the app gets it
}
