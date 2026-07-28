// aes/menu.c — GEM menu bar + pull-downs.  menu_build assembles the standard
// OBJECT tree (a bar of G_TITLEs, plus one dropdown G_BOX of G_STRING items per
// title); menu_bar draws it; a bar click (caught inside evnt_multi via
// menu_handle_click) runs the pull-down, then posts MN_SELECTED to the message
// pipe — so the app just receives the message from evnt_mesag.

#include "aes/aes_internal.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

gfx_surface *vdi_screen_target(void);   // the physical workstation surface (VDI core)
extern font_face *g_default_face;       // vdi/core.c — measured against in the panel layouts below
extern font_face *g_default_face;       // vdi/core.c — measured against in the panel layouts below

#define BARH   AES_MENUBAR_H   /* one height, shared with gemd's top reserve (aes.h) */
#define ITEMH  20
#define SEPH   10          // a separator row: a thin divider, shorter than a normal item
#define TPAD   14
#define DDPADX 22
#define DDPADY 4
#define PEN_BAR    246
#define PEN_HILITE 247
#define PEN_BARLINE 245
#define PEN_SEP    244     // pull-down separators — see set_sep_pen()

static OBJECT *g_menu;
static int g_n, T0, DD0, ACTIVE;        // title count + base object indices
static int H(void) { return aes_handle(); }
static void set_sep_pen(const theme *th);
static void draw_bar(void);

#ifdef GEM_XTOS
#include "gemclient.h"
#include "usys.h"
/* ---- §10 CLIENT MODE: the strip is OUR surface (gemd allocated it, once), the dropdown is
 * an ordinary chromeless WINDOW at the dropdown's screen rect, and the whole interaction
 * runs under a GRAB (every event, screen coords) so the classic modal loop below works
 * untouched — its hit math was always absolute, and the strip's origin is the screen's. */
static gfx_surface g_strip;  static int g_strip_vh = -1;
static int g_mrevoked;                   /* MSG_GRAB_REVOKED: dismiss on next lap */
static int g_pn_wh, g_pn_ord = -1, g_pn_hov = -1;
int  wind_gem_fd(void);                  /* window.c: the channel */
void menu_grab_revoked(void){ g_mrevoked = 1; }
static int is_client(void){ return aes_mode()==AES_CLIENT; }
static void menu_pens(void){
    const theme *th = aes_theme();
    v_setrgb(H(), PEN_BAR, 244,245,247);
    if (th) { v_setrgb(H(), PEN_HILITE,(th->highlight>>24)&0xFF,(th->highlight>>16)&0xFF,(th->highlight>>8)&0xFF);
              v_setrgb(H(), PEN_BARLINE,(th->border>>24)&0xFF,(th->border>>16)&0xFF,(th->border>>8)&0xFF);
              set_sep_pen(th); }
}
static int strip_begin(void){
    if(!g_strip.px) return -1;
    int save = aes_handle();
    vdi_set_target(&g_strip);
    aes_init(g_strip_vh, aes_theme());
    menu_pens();
    return save;
}
static void strip_end(int save, int x, int w){
    aes_init(save, aes_theme());
    gem_msg m; memset(&m,0,sizeof m);
    m.w[0]=GEM_MENU_DAMAGE; m.w[2]=(int16_t)x; m.w[4]=(int16_t)w;
    gem_send(wind_gem_fd(), &m);
}
static void menu_grab(int on){
    gem_msg m; memset(&m,0,sizeof m);
    m.w[0]=GEM_GRAB; m.w[2]=(int16_t)on;
    gem_send(wind_gem_fd(), &m);
}
static void panel_draw_cb(int hd,int x,int y,int w,int h,void *ud);
static int text_w(const char *s);       // defined below; needed by the re-measure in dd_panel_open
static int bar_is_sep(const char *s);
// Measure with the DEFAULT FACE at the draw size directly. text_w goes through the current VDI
// workstation, whose font state under-sizes it here (measures ~half); the dropdown draws with
// g_default_face at 14, so measure the same way — box, draw and hit-test then agree.
static int dd_text_w(const char *s){
    font *f = g_default_face ? font_at(g_default_face, BARH>=14?14:BARH) : 0;
    return f ? font_text_width(f, s) : text_w(s);
}
static void dd_panel_open(int ord){
    int ddi=DD0+ord, dx,dy; objc_offset(g_menu,ddi,&dx,&dy); (void)dy;
    // RE-MEASURE here, not in menu_build: menu_build runs at menu_show (startup) when the font
    // face's glyph advances are not yet warm, so it under-sizes the box (items overflow at draw
    // time). By open time the font is ready — measure the widest item and correct the box + its
    // item widths so the window, the draw, and objc hit-testing all agree.
    int mw=0;                                   // EACH_CHILD is #defined BELOW this fn — iterate by hand
    for(int c=g_menu[ddi].ob_head; c>=0; c=(c==g_menu[ddi].ob_tail?-1:g_menu[c].ob_next)){
        const char *l=(const char*)g_menu[c].ob_spec;
        if(!bar_is_sep(l)){ int tw=dd_text_w(l); if(tw>mw)mw=tw; } }
    int w=mw+DDPADX*2; if(w<g_menu[ddi].ob_w) w=g_menu[ddi].ob_w;   // never shrink below layout
    g_menu[ddi].ob_w=(int16_t)w;
    for(int c=g_menu[ddi].ob_head; c>=0; c=(c==g_menu[ddi].ob_tail?-1:g_menu[c].ob_next))
        g_menu[c].ob_w=(int16_t)(w-DDPADX-4);   // items span the corrected box
    int hh=g_menu[ddi].ob_h;
    g_pn_ord=ord; g_pn_hov=-1;
    g_pn_wh=wind_create(W_ALPHA, dx, BARH, w, hh);   // src-over: rounded corners over the desktop
    if(g_pn_wh){ wind_content(g_pn_wh, panel_draw_cb, 0); wind_open(g_pn_wh, dx, BARH, w, hh); }
}
static void dd_panel_close(void){
    if(g_pn_wh){ wind_close(g_pn_wh); wind_delete(g_pn_wh); g_pn_wh=0; }
    g_pn_ord=-1;
}
#endif

/* Separators get their OWN pen, not PEN_BARLINE.  The theme's border colour is a
 * hairline tint: fine as the bar's bottom edge (against the desktop), but inside a
 * pull-down — light panel, light border — it all but vanished.  Derive a distinctly
 * darker shade from the same theme colour so dividers actually read as dividers
 * while still tracking the theme.  PEN_BARLINE keeps the plain border colour for
 * the bar edge, which is why this can't just darken that pen. */
static void set_sep_pen(const theme *th) {
    if (!th) return;
    int r = (th->border>>24)&0xFF, g = (th->border>>16)&0xFF, b = (th->border>>8)&0xFF;
    v_setrgb(H(), PEN_SEP, r*42/100, g*42/100, b*42/100);
}

#define EACH_CHILD(t,p,c) for(int c=(t)[p].ob_head;c>=0;c=(c==(t)[p].ob_tail?-1:(t)[c].ob_next))

static int text_w(const char *s) { int16_t e[8]; vst_height(H(),14,0,0,0,0); vqt_extent(H(),s,e); return e[2]-e[0]; }

// Bar-dropdown item encoding (see aes.h MENU_SEP / MENU_CHECK / MENU_DISABLE):
// a leading "-" marks a separator (a non-selectable divider); a leading \x01
// pre-checks the row; a leading \x02 pre-disables it.  bar_is_sep spots the
// divider; bar_disp strips the \x01/\x02 marker so only the label is measured/drawn.
static int bar_is_sep(const char *s) { return s && s[0]=='-'; }
static const char *bar_disp(const char *s) {
    return (s && ((unsigned char)s[0]==1 || (unsigned char)s[0]==2)) ? s+1 : s;
}

OBJECT *menu_build(const menu_def *m, int n, int sw) {
    int nit = 0; for (int i=0;i<n;i++) nit += m[i].nitems;
    OBJECT *t = calloc((size_t)(2 + n + 1 + n + nit), sizeof(OBJECT));
    int bar=1, t0=2, active=2+n, dd0=active+1, it=dd0+n;
    int tx=0;
    t[0]=(OBJECT){NIL,bar,active,G_IBOX,OF_NONE,OS_NORMAL,0,0,0,(int16_t)sw,400};
    t[bar]=(OBJECT){active,t0,t0+n-1,G_BOX,OF_NONE,OS_NORMAL,0,0,0,(int16_t)sw,BARH};
    for (int i=0;i<n;i++){
        int w=text_w(m[i].title)+TPAD*2, ti=t0+i;
        t[ti]=(OBJECT){(int16_t)(i<n-1?ti+1:bar),NIL,NIL,G_TITLE,OF_NONE,OS_NORMAL,
                       (void*)m[i].title,(int16_t)tx,0,(int16_t)w,BARH};
        tx+=w;
    }
    t[active]=(OBJECT){0,dd0,dd0+n-1,G_IBOX,OF_NONE,OS_NORMAL,0,0,BARH,(int16_t)sw,(int16_t)(400-BARH)};
    tx=0;
    for (int i=0;i<n;i++){
        int mw=0, ddh=DDPADY*2;
        for(int j=0;j<m[i].nitems;j++){
            int w=text_w(bar_disp(m[i].items[j])); if(w>mw)mw=w;
            ddh += bar_is_sep(m[i].items[j]) ? SEPH : ITEMH;
        }
        int ddw=mw+DDPADX*2, ddi=dd0+i, first=it;   // symmetric pad: the right margin now
        int titlew=text_w(m[i].title)+TPAD*2;
        t[ddi]=(OBJECT){(int16_t)(i<n-1?ddi+1:active),(int16_t)first,(int16_t)(first+m[i].nitems-1),
                        G_BOX,OF_HIDETREE,OS_NORMAL,0,(int16_t)tx,0,(int16_t)ddw,(int16_t)ddh};
        int iy=DDPADY;
        for (int j=0;j<m[i].nitems;j++){
            const char *raw=m[i].items[j];
            uint16_t fl=OF_SELECTABLE, stt=OS_NORMAL; const char *spec=raw;
            int ih=ITEMH;
            if (bar_is_sep(raw))                    { fl=OF_NONE; ih=SEPH; }         // divider
            else if ((unsigned char)raw[0]==1)      { stt|=OS_CHECKED;  spec=raw+1; } // pre-checked
            else if ((unsigned char)raw[0]==2)      { stt|=OS_DISABLED; fl=OF_NONE; spec=raw+1; } // pre-disabled
            int oi=it++;
            t[oi]=(OBJECT){(int16_t)(j<m[i].nitems-1?oi+1:ddi),NIL,NIL,G_STRING,
                           fl,stt,(void*)spec,
                           (int16_t)DDPADX,(int16_t)iy,(int16_t)(ddw-DDPADX-4),(int16_t)ih};
            iy+=ih;
        }
        tx+=titlew;
    }
    return t;
}

static void draw_bar(void) {
    int sw = g_menu[1].ob_w;
    vsf_color(H(),PEN_BAR); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
    int16_t r[4]={0,0,(int16_t)(sw-1),BARH-1}; vr_recfl(H(),r);
    vsl_color(H(),PEN_BARLINE); vsl_width(H(),1);
    int16_t ln[4]={0,BARH-1,(int16_t)(sw-1),BARH-1}; v_pline(H(),2,ln);
    vst_height(H(),14,0,0,0,0); vst_color(H(),1);
    EACH_CHILD(g_menu,1,c) v_gtext(H(), g_menu[c].ob_x+TPAD, BARH/2-7, (const char*)g_menu[c].ob_spec);
}

void menu_redraw(void) { if (g_menu) draw_bar(); }   // bar is always-on-top chrome

#ifdef GEM_XTOS
static void strip_redraw_all(void){                  /* the whole bar into the strip + damage */
    int sv=strip_begin(); if(sv<0) return;
    draw_bar();
    strip_end(sv, 0, g_strip.w);
}
#endif

void menu_bar(OBJECT *tree, int show) {
#ifdef GEM_XTOS
    if (is_client()) {
        if (!show) { g_menu = NULL; return; }
        g_menu = tree;
        T0 = 2; ACTIVE = g_menu[1].ob_next; DD0 = g_menu[ACTIVE].ob_head;
        g_n = 0; EACH_CHILD(g_menu,1,c) g_n++;
        if (!g_strip.px) {                       /* ONCE (§10): ask, map, open a vh, forever */
            gem_msg m; memset(&m,0,sizeof m);
            m.w[0]=GEM_MENU_BAR;
            gem_send(wind_gem_fd(), &m);
            if (gem_await(wind_gem_fd(), GEM_MSG_MENU_SURF, &m)!=0) { g_menu=NULL; return; }
            uint32_t *px = gem_surf_map((int)m.u[0]);
            if (!px) { g_menu=NULL; return; }
            g_strip.px=px; g_strip.w=m.w[2]; g_strip.h=m.w[3]; g_strip.stride=m.w[4];
            g_strip_vh = v_opnvwk(&g_strip);
        }
        strip_redraw_all();                      /* the server reserves the band; we just draw */
        return;
    }
#endif
    if (show) {
        g_menu = tree;
        T0 = 2; ACTIVE = g_menu[1].ob_next; DD0 = g_menu[ACTIVE].ob_head;
        g_n = 0; EACH_CHILD(g_menu,1,c) g_n++;
        const theme *th = aes_theme();
        v_setrgb(H(), PEN_BAR, 244,245,247);
        if (th) { v_setrgb(H(), PEN_HILITE,(th->highlight>>24)&0xFF,(th->highlight>>16)&0xFF,(th->highlight>>8)&0xFF);
                  v_setrgb(H(), PEN_BARLINE,(th->border>>24)&0xFF,(th->border>>16)&0xFF,(th->border>>8)&0xFF);
                  set_sep_pen(th); }
        aes_reserve_top(BARH);          // keep windows below the bar
        draw_bar();
    } else {
        g_menu = NULL; aes_reserve_top(0);
    }
}

// ---- state by (title,item) ordinal --------------------------------------
// The bar dropdown is drawn only while open (draw_items reads ob_state live), so
// these just flip the stored state — the change shows the next time that dropdown
// opens.  All address a row by its title/item ordinal (not the flat object index),
// so an app can reflect live state without knowing the tree layout.  menu_dd_obj
// walks to a title's dropdown box; menu_item_obj to one of its item objects.
static int menu_dd_obj(OBJECT *t, int to) {
    int bar=t[0].ob_head, active=t[bar].ob_next, dd=t[active].ob_head;
    for(int i=0;i<to && dd>=0;i++) dd=(dd==t[active].ob_tail?-1:t[dd].ob_next);
    return dd;
}
static int menu_item_obj(OBJECT *t, int to, int io) {
    int dd=menu_dd_obj(t,to); if(dd<0) return -1;
    int c=t[dd].ob_head;
    for(int i=0;i<io && c>=0;i++) c=(c==t[dd].ob_tail?-1:t[c].ob_next);
    return c;
}
// Ordinal (0-based) of item object `item_obj` in title `to`'s dropdown; -1 if not
// found.  Decodes an MN_SELECTED message: msg[3]-2 = title ordinal, msg[4] = the
// item object index -> menu_item_ord -> the item ordinal an app dispatches on.
int menu_item_ord(OBJECT *t, int to, int item_obj) {
    int dd=menu_dd_obj(t,to); if(dd<0) return -1;
    int ord=0; EACH_CHILD(t,dd,c){ if(c==item_obj) return ord; ord++; }
    return -1;
}
void menu_tnormal(OBJECT *t, int title_ord, int normal) {
    int ti=t[t[0].ob_head].ob_head + title_ord;
    if (normal) t[ti].ob_state &= ~OS_SELECTED; else t[ti].ob_state |= OS_SELECTED;
}
void menu_icheck(OBJECT *t, int title_ord, int item_ord, int on) {
    int o=menu_item_obj(t,title_ord,item_ord); if(o<0) return;
    if (on) t[o].ob_state |= OS_CHECKED; else t[o].ob_state &= ~OS_CHECKED;
}
void menu_ienable(OBJECT *t, int title_ord, int item_ord, int on) {
    int o=menu_item_obj(t,title_ord,item_ord); if(o<0) return;
    if (on) { t[o].ob_state &= ~OS_DISABLED; t[o].ob_flags |= OF_SELECTABLE; }
    else    { t[o].ob_state |=  OS_DISABLED; t[o].ob_flags &= ~OF_SELECTABLE; }
}

// ---- pull-down interaction ----------------------------------------------
static gfx_surface *g_sav; static int g_sx,g_sy,g_sw,g_sh;
static void save_area(int x,int y,int w,int h){
    g_sav=gfx_surface_alloc(w,h); g_sx=x;g_sy=y;g_sw=w;g_sh=h;
    MFDB scr={0}, dst; mfdb_from_surface(&dst,g_sav);
    int16_t p[8]={(int16_t)x,(int16_t)y,(int16_t)(x+w-1),(int16_t)(y+h-1),0,0,(int16_t)(w-1),(int16_t)(h-1)};
    vro_cpyfm(H(),VRO_COPY,p,&scr,&dst);
}
static void restore_area(void){
    if(!g_sav)return;
    MFDB scr={0}, src; mfdb_from_surface(&src,g_sav);
    int16_t p[8]={0,0,(int16_t)(g_sw-1),(int16_t)(g_sh-1),(int16_t)g_sx,(int16_t)g_sy,(int16_t)(g_sx+g_sw-1),(int16_t)(g_sy+g_sh-1)};
    vro_cpyfm(H(),VRO_COPY,p,&src,&scr);
    aes_flush_rect(g_sx,g_sy,g_sw,g_sh);     // push the restored pixels to the plane
    gfx_surface_free(g_sav); g_sav=NULL;
}

static void hilite_title(int ord,int on){
    int ti=T0+ord, x=g_menu[ti].ob_x, w=g_menu[ti].ob_w;
#ifdef GEM_XTOS
    if(is_client()){
        int sv=strip_begin(); if(sv<0) return;
        if(on){ vsf_color(H(),PEN_HILITE); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
                int16_t r[4]={(int16_t)x,0,(int16_t)(x+w-1),BARH-2}; vr_recfl(H(),r); vst_color(H(),0); }
        else  { vsf_color(H(),PEN_BAR); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
                int16_t r[4]={(int16_t)x,0,(int16_t)(x+w-1),BARH-2}; vr_recfl(H(),r); vst_color(H(),1); }
        vst_height(H(),14,0,0,0,0);
        v_gtext(H(), x+TPAD, BARH/2-7, (const char*)g_menu[ti].ob_spec);
        strip_end(sv, x, w);
        return;
    }
#endif
    if(on){ vsf_color(H(),PEN_HILITE); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
            int16_t r[4]={(int16_t)x,0,(int16_t)(x+w-1),BARH-2}; vr_recfl(H(),r); vst_color(H(),0); }
    else  { vsf_color(H(),PEN_BAR); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
            int16_t r[4]={(int16_t)x,0,(int16_t)(x+w-1),BARH-2}; vr_recfl(H(),r); vst_color(H(),1); }
    vst_height(H(),14,0,0,0,0);
    v_gtext(H(), x+TPAD, BARH/2-7, (const char*)g_menu[ti].ob_spec);
    aes_flush_rect(x,0,w,BARH);              // push the title cell to the plane
}

static void draw_items(int ord,int hov){
#ifdef GEM_XTOS
    if(is_client()){ g_pn_ord=ord; g_pn_hov=hov;      /* the panel window redraws itself */
                     if(g_pn_wh) wind_redraw_win(g_pn_wh); return; }
#endif
    int ddi=DD0+ord, dx,dy; objc_offset(g_menu,ddi,&dx,&dy);
    int w=g_menu[ddi].ob_w, h=g_menu[ddi].ob_h;
    theme_draw(H(),aes_theme(),"menu",dx,dy,w,h);
    vst_height(H(),14,0,0,0,0);
    EACH_CHILD(g_menu,ddi,c){
        int iy=dy+g_menu[c].ob_y, ih=g_menu[c].ob_h;
        const char *lbl=(const char*)g_menu[c].ob_spec;
        if(bar_is_sep(lbl)){                                       // a thin divider line
            vsl_color(H(),PEN_SEP); vsl_width(H(),1);
            int16_t ln[4]={(int16_t)(dx+6),(int16_t)(iy+ih/2),(int16_t)(dx+w-7),(int16_t)(iy+ih/2)};
            v_pline(H(),2,ln); continue;
        }
        int sel=(c==hov), dis=(g_menu[c].ob_state&OS_DISABLED);
        if(sel){ vsf_color(H(),PEN_HILITE); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
                 int16_t r[4]={(int16_t)(dx+4),(int16_t)iy,(int16_t)(dx+w-5),(int16_t)(iy+ih-1)}; vr_recfl(H(),r); }
        if(g_menu[c].ob_state&OS_CHECKED){                         // drawn check tick (mirrors the popup)
            int cx=dx+7, cym=iy+ih/2;
            vsl_color(H(), sel?0:1); vsl_width(H(),2);
            int16_t tk[6]={(int16_t)cx,(int16_t)cym,(int16_t)(cx+3),(int16_t)(cym+3),(int16_t)(cx+8),(int16_t)(cym-4)};
            v_pline(H(),3,tk);
        }
        vst_color(H(), sel?0:(dis?9:1));
        v_gtext(H(), dx+g_menu[c].ob_x, iy+ih/2-7, lbl);
    }
    aes_flush_rect(dx,dy,w,h);               // push the pull-down to the plane
}

static int title_at(int mx){
    for(int i=0;i<g_n;i++){ int ti=T0+i; if(mx>=g_menu[ti].ob_x && mx<g_menu[ti].ob_x+g_menu[ti].ob_w) return i; }
    return -1;
}
static int item_at(int ord,int mx,int my){
    int ddi=DD0+ord, dx,dy; objc_offset(g_menu,ddi,&dx,&dy);
    if(mx<dx || mx>=dx+g_menu[ddi].ob_w) return -1;
    EACH_CHILD(g_menu,ddi,c){ int iy=dy+g_menu[c].ob_y;
        if(my>=iy && my<iy+g_menu[c].ob_h){                        // within this row
            const char *lbl=(const char*)g_menu[c].ob_spec;
            if(bar_is_sep(lbl) || (g_menu[c].ob_state&OS_DISABLED)) return -1;  // non-selectable
            return c;
        } }
    return -1;
}
static void open_menu(int ord){
    hilite_title(ord,1);
#ifdef GEM_XTOS
    if(is_client()){ dd_panel_open(ord); return; }   /* the dropdown is a WINDOW (§10) */
#endif
    int ddi=DD0+ord, dx,dy; objc_offset(g_menu,ddi,&dx,&dy);
    save_area(dx,dy,g_menu[ddi].ob_w,g_menu[ddi].ob_h);
    draw_items(ord,-1);
}
static void close_menu(int ord){
#ifdef GEM_XTOS
    if(is_client()){ dd_panel_close(); hilite_title(ord,0); return; }
#endif
    restore_area(); hilite_title(ord,0);
}

void menu_render_open(int to, int io){
    if(!g_menu) return;
    hilite_title(to,1);
    int ddi=DD0+to, hov=-1, j=0;
    if(io>=0) EACH_CHILD(g_menu,ddi,c){ if(j==io){hov=c;break;} j++; }
    draw_items(to,hov);
}

// A bar click drives the pull-down.  BOTH interaction styles work:
//   - press-drag-release: hold on the title, drag onto an item, release -> pick.
//   - click-to-latch:     CLICK the title (down+up, no travel) -> the menu stays
//     open; then click an item to pick, or click away to dismiss.
// The latch is load-bearing.  This used to select on the FIRST button-up
// unconditionally, so a plain click opened the menu on the down and closed it on
// the up with hov still -1 — no selection, yet the click was consumed.  Symptom:
// clicking the menubar swallowed the click and actioned nothing, and menus were
// unusable with any input that clicks rather than holds (keyboard/touch mouse).
int menu_handle_click(int mx, int my){
    if(!g_menu || my>=BARH) return 0;
    int cur=title_at(mx); if(cur<0) return 1;        // bar click, no title -> consumed
    open_menu(cur);
    int hov=-1, sel=-1, latched=0;
    for(;;){
        aes_event ev; int t=aes_wait(&ev,-1);
        if(t==AES_QUIT){ close_menu(cur); return 1; }
#ifdef GEM_XTOS
        if(g_mrevoked){ close_menu(cur); return 1; }     /* §9: the clock took our grab */
#endif
        int nx=ev.mx, ny=ev.my;
        if(ny<BARH){ int nt=title_at(nx);
            if(nt>=0 && nt!=cur){ close_menu(cur); cur=nt; open_menu(cur); hov=-1; }
            else if(hov!=-1){ hov=-1; draw_items(cur,hov); } }
        else { int hi=item_at(cur,nx,ny); if(hi!=hov){ hov=hi; draw_items(cur,hov); } }
        if(t==AES_BTN_UP){
            if(hov>=0){ sel=hov; break; }            // released on an item -> pick it
            if(!latched){ latched=1; continue; }     // plain click on the title -> latch open
            if(ny<BARH) continue;                    // latched, released on the bar -> stay open
            break;                                   // latched, released off the menu -> dismiss
        }
    }
    close_menu(cur);
    if(sel>=0){ int16_t msg[8]={MN_SELECTED,1,0,(int16_t)(T0+cur),(int16_t)sel,0,0,0}; appl_write(0,16,msg); }
    return 1;
}

// ==== Popup / context menus (menu_popup) =================================
// A generic run-a-popup over a flat menu_item[] array: a themed "menu" box with
// one row per item (label left, accel/tick/submenu-triangle right), tracked
// modally with hover highlight + cascading submenus.  Layout + hit-test + nav
// are factored into pure helpers (menu_popup_layout / _hit / _nav / _mnemonic)
// so they unit-test without the modal loop.  Drawing reuses the same "menu"
// theme element + PEN_HILITE as the bar pull-down (draw_items above); this path
// adds the accel column, separators, disabled greying, and submenu triangles.

// The row text is drawn at the SAME size as ordinary UI text (labels, buttons) — a popup that reads
// smaller than the dialog it belongs to looks like a different widget set.  The row height and the
// baseline follow from it, so changing P_FONT alone re-proportions the panel.
#define P_FONT   16     // row text size (the VDI default the toolkit draws labels at)
#define P_ITEMH  22     // selectable row height: P_FONT + breathing room
#define P_SEPH   9      // separator row height (a thin divider)
#define P_PADX   22     // left pad (leaves room for the check tick)
#define P_RPAD   14     // right pad
#define P_GAP    22     // gap between the label and the accel / triangle column
#define P_TRIW   12     // submenu-triangle column width
#define P_PADY   4      // top/bottom pad inside the box
#define PEN_GREY 9      // disabled text (matches object.c's disabled pen)

static int mi_is_sep(const menu_item *it){ return it->label && it->label[0]=='-' && it->label[1]==0; }
// A row that cascades: a static submenu (sub != NULL) or a lazy one (MI_LAZY).
static int mi_has_sub(const menu_item *it){ return it->sub || (it->flags & MI_LAZY); }
static int mi_selectable(const menu_item *items, int i){
    const menu_item *it=&items[i];
    return it->label && !mi_is_sep(it) && !(it->flags & MI_DISABLED);
}
static int mi_row_h(const menu_item *items, int i){ return mi_is_sep(&items[i]) ? P_SEPH : P_ITEMH; }

// The auto-assigned mnemonic: the first still-unclaimed alpha letter of each
// selectable label, in row order.  Returns the label-char index for `row`
// (-1 = none).  Recomputed on the fly (deterministic) so no per-panel storage.
static int mi_mnemonic_idx(const menu_item *items, int n, int row){
    if(row<0 || row>=n || !mi_selectable(items,row)) return -1;
    unsigned claimed=0;
    for(int i=0;i<=row;i++){
        if(!mi_selectable(items,i)) continue;
        const char *s=items[i].label; int pick=-1;
        for(int j=0;s[j];j++){ int c=tolower((unsigned char)s[j]);
            if(c<'a'||c>'z'||(claimed&(1u<<(c-'a')))) continue;
            pick=j; claimed|=1u<<(c-'a'); break; }
        if(i==row) return pick;
    }
    return -1;
}

// ---- geometry ----------------------------------------------------------
// Measure with the default face AT THE DRAW SIZE.  text_w() goes through the current workstation,
// whose font state under-measures here (the same trap dd_text_w documents for the bar dropdown), so
// the box came out too narrow for its own text.
static int pop_text_w(const char *s){
    font *f = g_default_face ? font_at(g_default_face, P_FONT) : 0;
    return f ? font_text_width(f, s) : text_w(s);
}

void menu_popup_layout(const menu_item *items, int n, int x, int y, popup_geom *g){
    vst_height(H(),P_FONT,0,0,0,0);
    int lw=0, aw=0, has_sub=0, h=P_PADY*2;
    for(int i=0;i<n;i++){
        h += mi_row_h(items,i);
        if(mi_is_sep(&items[i])) continue;
        int w=pop_text_w(items[i].label); if(w>lw) lw=w;
        if(items[i].accel){ int a=pop_text_w(items[i].accel); if(a>aw) aw=a; }
        if(mi_has_sub(&items[i])) has_sub=1;
    }
    int rightw = aw;                                  // accel column width
    if(has_sub && P_TRIW>rightw) rightw = P_TRIW;     // ...or the triangle column
    int w = P_PADX + lw + (rightw ? P_GAP+rightw : 0) + P_RPAD;

    gfx_surface *scr = vdi_screen_target();
    int sw = scr?scr->w:640, sh = scr?scr->h:480;
    if(x+w > sw) x = sw-w;   if(x<0) x=0;             // clamp fully on-screen
    if(y+h > sh) y = sh-h;   if(y<0) y=0;

    g->x=x; g->y=y; g->w=w; g->h=h;
    g->rowh=P_ITEMH; g->seph=P_SEPH; g->pady=P_PADY; g->labelx=P_PADX; g->n=n;
}

// y of row `row`'s top, given the (laid-out) box.
static int mi_row_top(const menu_item *items, const popup_geom *g, int row){
    int ty=g->y+g->pady;
    for(int i=0;i<row;i++) ty += mi_row_h(items,i);
    return ty;
}

int menu_popup_hit(const popup_geom *g, const menu_item *items, int mx, int my){
    if(mx<g->x || mx>=g->x+g->w) return -1;
    int ty=g->y+g->pady;
    for(int i=0;i<g->n;i++){
        int rh=mi_row_h(items,i);
        if(my>=ty && my<ty+rh) return mi_selectable(items,i) ? i : -1;
        ty+=rh;
    }
    return -1;
}

int menu_popup_nav(const menu_item *items, int n, int cur, int dir){
    if(n<=0) return -1;
    if(dir==0) dir=1;
    for(int step=0; step<n; step++){
        cur += dir;
        if(cur<0) cur=n-1; else if(cur>=n) cur=0;
        if(mi_selectable(items,cur)) return cur;
    }
    return -1;
}

int menu_popup_mnemonic(const menu_item *items, int n, int ch){
    ch=tolower((unsigned char)ch);
    for(int i=0;i<n;i++){
        int mi=mi_mnemonic_idx(items,n,i);
        if(mi>=0 && tolower((unsigned char)items[i].label[mi])==ch) return i;
    }
    return -1;
}

// ---- drawing -----------------------------------------------------------
static void popup_pens(void){
    const theme *th=aes_theme();
    if(th){ v_setrgb(H(),PEN_HILITE,(th->highlight>>24)&0xFF,(th->highlight>>16)&0xFF,(th->highlight>>8)&0xFF);
            v_setrgb(H(),PEN_BARLINE,(th->border>>24)&0xFF,(th->border>>16)&0xFF,(th->border>>8)&0xFF);
            set_sep_pen(th); }
}

// A 1px underline under label char `idx` at text origin (tx,uy), current face.
static void popup_underline(const char *s, int idx, int tx, int uy, int pen){
    if(idx<0 || idx>=(int)strlen(s)) return;
    char pre[96]; int16_t e[8]; int x0=0;
    int k = idx<(int)sizeof pre-1 ? idx : (int)sizeof pre-1;
    if(k){ memcpy(pre,s,k); pre[k]=0; vqt_extent(H(),pre,e); x0=e[2]-e[0]; }
    char ch[2]={s[idx],0}; vqt_extent(H(),ch,e); int cw=e[2]-e[0]; if(cw<2)cw=2;
    vsl_color(H(),pen); vsl_width(H(),1);
    int16_t l[4]={(int16_t)(tx+x0),(int16_t)uy,(int16_t)(tx+x0+cw-1),(int16_t)uy};
    v_pline(H(),2,l);
}

static void draw_popup(const menu_item *items, const popup_geom *g, int hov){
    theme_draw(H(),aes_theme(),"menu",g->x,g->y,g->w,g->h);
    vst_height(H(),P_FONT,0,0,0,0);
    for(int i=0;i<g->n;i++){
        int ty=mi_row_top(items,g,i), rh=mi_row_h(items,i);
        if(mi_is_sep(&items[i])){                                  // thin divider line
            vsl_color(H(),PEN_SEP); vsl_width(H(),1);
            int16_t ln[4]={(int16_t)(g->x+6),(int16_t)(ty+rh/2),(int16_t)(g->x+g->w-7),(int16_t)(ty+rh/2)};
            v_pline(H(),2,ln); continue;
        }
        int disabled = items[i].flags & MI_DISABLED;
        int sel = (i==hov);
        if(sel){ vsf_color(H(),PEN_HILITE); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
                 int16_t r[4]={(int16_t)(g->x+4),(int16_t)ty,(int16_t)(g->x+g->w-5),(int16_t)(ty+rh-1)};
                 vr_recfl(H(),r); }
        int lpen = sel ? 0 : disabled ? PEN_GREY : 1;
        int apen = lpen;                              // accel matches the label pen: black when
                                                      // enabled (grey would read as disabled),
                                                      // grey only on a genuinely disabled row
        int cy = ty+rh/2-P_FONT/2;              // vertically centred for the row's own font size
        if(items[i].flags & MI_CHECKED){                                  // a drawn check tick
            int cx=g->x+7, cym=ty+rh/2;
            vsl_color(H(), sel?0:1); vsl_width(H(),2);
            int16_t tk[6]={(int16_t)cx,(int16_t)cym,(int16_t)(cx+3),(int16_t)(cym+3),(int16_t)(cx+8),(int16_t)(cym-4)};
            v_pline(H(),3,tk); }
        vst_color(H(),lpen);
        vst_alignment(H(),VDI_TA_LEFT,VDI_TA_TOP,0,0);
        v_gtext(H(), g->x+g->labelx, cy, items[i].label);
        if(!disabled && !sel){                                      // mnemonic underline
            int mi=mi_mnemonic_idx(items,g->n,i);
            if(mi>=0) popup_underline(items[i].label, mi, g->x+g->labelx, cy+P_FONT+2, lpen);
        }
        if(mi_has_sub(&items[i])){                                  // right-pointing triangle
            int tx=g->x+g->w-P_RPAD-P_TRIW+3, tym=ty+rh/2;
            vsf_color(H(),sel?0:1); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
            int16_t tri[6]={(int16_t)tx,(int16_t)(tym-4),(int16_t)(tx+5),(int16_t)tym,(int16_t)tx,(int16_t)(tym+4)};
            v_fillarea(H(),3,tri);
        } else if(items[i].accel){                                  // accel, right-aligned
            vst_color(H(),apen);
            vst_alignment(H(),VDI_TA_RIGHT,VDI_TA_TOP,0,0);
            v_gtext(H(), g->x+g->w-P_RPAD, cy, items[i].accel);
            vst_alignment(H(),VDI_TA_LEFT,VDI_TA_TOP,0,0);
        }
    }
    aes_flush_rect(g->x,g->y,g->w,g->h);
}

// Draw a popup open with row `hov` highlighted, at the already-laid-out geom —
// for demos / screenshots / headless tests (the live popup is driven by
// menu_popup below).  Sets up its pens so it works without an active menu bar.
void menu_popup_render_demo(const menu_item *items, int n, int hov, const popup_geom *g){
    (void)n; popup_pens(); draw_popup(items, g, hov);
}

// ---- save-under stack (nested popup + cascades) ------------------------
#define PSAV 6
static struct { gfx_surface *s; int x,y,w,h; } g_psav[PSAV];
static int g_npsav;
static void psav_push(int x,int y,int w,int h){
    if(g_npsav>=PSAV){ g_npsav++; return; }
    gfx_surface *s=gfx_surface_alloc(w,h);
    g_psav[g_npsav].s=s; g_psav[g_npsav].x=x; g_psav[g_npsav].y=y;
    g_psav[g_npsav].w=w; g_psav[g_npsav].h=h;
    if(s){ MFDB scr={0},dst; mfdb_from_surface(&dst,s);
        int16_t p[8]={(int16_t)x,(int16_t)y,(int16_t)(x+w-1),(int16_t)(y+h-1),0,0,(int16_t)(w-1),(int16_t)(h-1)};
        vro_cpyfm(H(),VRO_COPY,p,&scr,&dst); }
    g_npsav++;
}
static void psav_pop(void){
    if(g_npsav<=0) return;
    g_npsav--;
    if(g_npsav>=PSAV || !g_psav[g_npsav].s) return;
    int x=g_psav[g_npsav].x,y=g_psav[g_npsav].y,w=g_psav[g_npsav].w,h=g_psav[g_npsav].h;
    MFDB scr={0},src; mfdb_from_surface(&src,g_psav[g_npsav].s);
    int16_t p[8]={0,0,(int16_t)(w-1),(int16_t)(h-1),(int16_t)x,(int16_t)y,(int16_t)(x+w-1),(int16_t)(y+h-1)};
    vro_cpyfm(H(),VRO_COPY,p,&src,&scr);
    aes_flush_rect(x,y,w,h);
    gfx_surface_free(g_psav[g_npsav].s); g_psav[g_npsav].s=NULL;
}

// ---- modal loop --------------------------------------------------------
#define POPMAX_INTERNAL 6
// The lazy-submenu provider for the current run (menu_popup_dyn sets these; the
// static menu_popup leaves them NULL).  The modal loop is non-reentrant, so a
// pair of file statics is enough — matching the save-under stack's style.
static menu_provider g_expand;
static void         *g_expandctx;
// subrow = the row of this panel whose cascade is currently open (-1 = none),
// so hovering that same row again doesn't flicker the submenu closed/open.
// owned = this panel's items were malloc'd by the lazy provider (free on close).
typedef struct { const menu_item *items; int n; popup_geom g; int hov, subrow, owned; int wh; } popup_panel;

#ifdef GEM_XTOS
/* A client cannot save-under and cannot draw on the screen: its drawable is its own surface.  So a
 * panel is a WINDOW there, exactly as the bar's pull-down is (dd_panel_open, §10) — W_ALPHA so the
 * rounded corners blend to whatever is behind.  The content callback draws the SAME rows through the
 * same helper, with the geometry rebased to the window's own 0,0. */
static void pop_panel_draw_cb(int hd,int x,int y,int w,int h,void *ud){
    (void)hd;(void)x;(void)y;
    popup_panel *p=(popup_panel*)ud;
    if(!p || !p->items) return;
    { gfx_surface *ts=vdi_screen_target();          // clear to transparent so the corners the themed
      if(ts){ for(int yy=0;yy<h && yy<ts->h;yy++){  // slice does not cover stay alpha-0 (gemd blends
          uint32_t *r=ts->px+(size_t)yy*ts->stride; // them to the desktop rather than to stale pixels)
          for(int xx=0;xx<w && xx<ts->w;xx++) r[xx]=0; } } }
    popup_pens();
    popup_geom local=p->g; local.x=0; local.y=0;    // same box, drawn at the window's origin
    draw_popup(p->items,&local,p->hov);
    (void)w;
}
#endif

static void panel_open(popup_panel *p, const menu_item *items, int n, int x, int y){
    p->items=items; p->n=n; p->hov=-1; p->subrow=-1; p->owned=0; p->wh=0;
    menu_popup_layout(items,n,x,y,&p->g);
#ifdef GEM_XTOS
    if(is_client()){
        p->wh=wind_create(W_ALPHA, p->g.x, p->g.y, p->g.w, p->g.h);
        if(p->wh){ wind_content(p->wh, pop_panel_draw_cb, p);
                   wind_open(p->wh, p->g.x, p->g.y, p->g.w, p->g.h); }
        return;
    }
#endif
    psav_push(p->g.x,p->g.y,p->g.w,p->g.h);
    draw_popup(items,&p->g,-1);
}
static void panel_close(popup_panel *p){
    if(p->owned && p->items){ free((void*)p->items); p->items=NULL; p->owned=0; }
#ifdef GEM_XTOS
    if(is_client()){ if(p->wh){ wind_close(p->wh); wind_delete(p->wh); p->wh=0; } return; }
#endif
    psav_pop();
}
static void panel_redraw(popup_panel *p){
#ifdef GEM_XTOS
    if(is_client()){ if(p->wh) wind_redraw_win(p->wh); return; }
#endif
    draw_popup(p->items,&p->g,p->hov);
}

// Topmost open panel whose box contains (mx,my); -1 if over none.
static int panel_at(popup_panel *st, int depth, int mx, int my){
    for(int i=depth-1;i>=0;i--){ popup_geom *g=&st[i].g;
        if(mx>=g->x && mx<g->x+g->w && my>=g->y && my<g->y+g->h) return i; }
    return -1;
}
// Close every panel above index `keep`, restoring their save-unders, and clear
// the record of `keep`'s open cascade.
static void close_above(popup_panel *st, int *depth, int keep){
    while(*depth-1>keep){ panel_close(&st[*depth-1]); (*depth)--; }
    if(keep>=0 && keep<*depth) st[keep].subrow=-1;
}
// Open item `row` of panel `pi` as a cascade to its right (flip left if needed).
// A static submenu uses the item's own sub[]/nsub; a lazy (MI_LAZY) row asks the
// provider to produce its children first (a malloc'd block the panel then owns).
static void open_cascade(popup_panel *st, int *depth, int pi, int row){
    if(*depth>=POPMAX_INTERNAL) return;
    const menu_item *it=&st[pi].items[row];
    const menu_item *sub=it->sub; int nsub=it->nsub, owned=0;
    if(!sub && (it->flags&MI_LAZY)){                            // produce children on demand
        if(!g_expand) return;
        menu_item *kids=NULL; int nk=0;
        if(!g_expand(g_expandctx, it->id, &kids, &nk) || !kids || nk<=0){ free(kids); return; }
        sub=kids; nsub=nk; owned=1;
    }
    if(!sub || nsub<=0) return;                                 // nothing to cascade
    int rtop=mi_row_top(st[pi].items,&st[pi].g,row);
    popup_geom tg; menu_popup_layout(sub,nsub,
                    st[pi].g.x+st[pi].g.w-2, rtop-P_PADY, &tg);   // provisional size
    int nx=st[pi].g.x+st[pi].g.w-2;
    gfx_surface *scr=vdi_screen_target(); int sw=scr?scr->w:640;
    if(nx+tg.w>sw) nx=st[pi].g.x-tg.w+2;                         // flip to the left
    panel_open(&st[*depth], sub, nsub, nx, rtop-P_PADY);
    st[*depth].owned=owned;                                     // own the provider's block
    st[*depth].hov = menu_popup_nav(sub,nsub,-1,1);
    panel_redraw(&st[*depth]);
    st[pi].subrow=row;                                          // remember the spawning row
    (*depth)++;
}

// A submenu row whose click should SELECT (return its id) rather than open the
// cascade: a lazy row (e.g. a directory) that carries a real id.  A static
// submenu parent (id==0, like "Show") opens instead.
static int mi_click_selects(const menu_item *it){ return mi_has_sub(it) && it->id!=0; }

static int menu_popup_run(const menu_item *items, int n, int x, int y,
                          menu_provider expand, void *ctx){
    if(n<=0) return -1;
    g_expand=expand; g_expandctx=ctx;
    popup_pens();
    popup_panel st[POPMAX_INTERNAL]; int depth=0;
    panel_open(&st[0], items, n, x, y); depth=1;
    int result=-1;
    // A popup opened by a click must ignore the button-RELEASE of that same click:
    // when popups chain (context menu -> Browse cascade) the opener returns on the
    // BTN_DOWN and the trailing BTN_UP would otherwise leak in and auto-select the
    // item under the cursor.  Arm on the first in-popup BTN_DOWN; only then may a
    // BTN_UP select.
    int armed=0;

    for(;;){
        aes_event ev; int gen=aes_redraw_gen();
        int t=aes_wait_idle(&ev,-1);
        if(aes_redraw_gen()!=gen){                       // idle work repainted under us
            for(int i=0;i<depth;i++) panel_redraw(&st[i]);
        }
        if(t==AES_QUIT){ result=-1; break; }
#ifdef GEM_XTOS
        // The panels are laid out in SCREEN space, but a client's input is localised to the window it
        // was delivered to.  Lift a panel's own event back to screen space; anything belonging to some
        // OTHER window is genuinely outside every panel, so push it far away rather than let its
        // window-local coordinates alias into a panel's box and read as a hit.
        if(is_client() && (t==AES_MOTION || t==AES_BTN_DOWN || t==AES_BTN_UP)){
            int ew=aes_event_win(), lifted=0;
            for(int i=0;i<depth;i++)
                if(st[i].wh && st[i].wh==ew){ ev.mx+=st[i].g.x; ev.my+=st[i].g.y; lifted=1; break; }
            if(!lifted && ew!=0){ ev.mx=-30000; ev.my=-30000; }
        }
#endif

        if(t==AES_KEY){
            int ascii=ev.key&0xFF, scan=(ev.key>>8)&0xFF;
            popup_panel *top=&st[depth-1];
            if(ascii==0x1b){ result=-1; break; }                       // Esc -> cancel
            if(scan==XK_DOWN || scan==XK_UP){
                int dir = scan==XK_DOWN ? 1 : -1;
                int nx=menu_popup_nav(top->items,top->n,top->hov,dir);
                if(nx!=top->hov){ top->hov=nx; panel_redraw(top); }
                continue;
            }
            if(scan==XK_RIGHT){                                        // always cascade (explicit)
                if(top->hov>=0 && mi_has_sub(&top->items[top->hov])) open_cascade(st,&depth,depth-1,top->hov);
                continue;
            }
            if(scan==XK_LEFT){
                if(depth>1) close_above(st,&depth,depth-2);       // back to the parent panel
                continue;
            }
            if(ascii=='\r' || ascii=='\n' || ascii==' '){
                if(top->hov>=0){
                    const menu_item *it=&top->items[top->hov];
                    if(mi_click_selects(it)){ result=it->id; break; }          // e.g. open a folder
                    else if(mi_has_sub(it)) open_cascade(st,&depth,depth-1,top->hov);
                    else { result=it->id; break; }
                }
                continue;
            }
            if(isalnum(ascii)){                                        // mnemonic jump/select
                int m=menu_popup_mnemonic(top->items,top->n,ascii);
                if(m>=0){ top->hov=m; panel_redraw(top);
                    const menu_item *it=&top->items[m];
                    if(mi_click_selects(it)){ result=it->id; break; }
                    else if(mi_has_sub(it)) open_cascade(st,&depth,depth-1,m);
                    else { result=it->id; break; } }
                continue;
            }
            continue;
        }

        if(t==AES_MOTION){
            int pi=panel_at(st,depth,ev.mx,ev.my);
            if(pi<0) continue;                                         // outside: leave panels as-is
            popup_panel *p=&st[pi];
            int row=menu_popup_hit(&p->g,p->items,ev.mx,ev.my);
            if(depth>pi+1 && row==p->subrow){                          // still over the open cascade's row
                if(p->hov!=row){ p->hov=row; panel_redraw(p); }
                continue;                                              // keep it open (no flicker)
            }
            close_above(st,&depth,pi);                                 // a different row: drop cascades
            if(row!=p->hov){ p->hov=row; panel_redraw(p); }
            if(row>=0 && mi_has_sub(&p->items[row]))                   // hover a sub item -> cascade
                open_cascade(st,&depth,pi,row);
            continue;
        }

        if(t==AES_BTN_DOWN || t==AES_BTN_UP){
            if(t==AES_BTN_UP && !armed) continue;            // swallow the opener click's release
            if(t==AES_BTN_DOWN) armed=1;                     // a genuine in-popup press: releases now count
            int pi=panel_at(st,depth,ev.mx,ev.my);
            if(pi<0){ if(t==AES_BTN_DOWN){ result=-1; break; } continue; }  // click-out cancels
            popup_panel *p=&st[pi];
            int row=menu_popup_hit(&p->g,p->items,ev.mx,ev.my);
            if(row<0) continue;
            const menu_item *it=&p->items[row];
            if(mi_click_selects(it)){ result=it->id; break; }         // clickable sub (folder) -> select
            else if(mi_has_sub(it)){                                  // click a sub parent -> open
                if(!(depth>pi+1 && row==p->subrow)){                  // (unless already open)
                    close_above(st,&depth,pi);
                    open_cascade(st,&depth,pi,row);
                }
            } else { result=it->id; break; }                          // leaf -> select
        }
    }
    while(depth>0){ panel_close(&st[depth-1]); depth--; }             // restore all save-unders
    g_expand=NULL; g_expandctx=NULL;
    return result;
}

int menu_popup(const menu_item *items, int n, int x, int y){
    return menu_popup_run(items, n, x, y, NULL, NULL);
}
int menu_popup_dyn(const menu_item *root, int n, int x, int y, menu_provider expand, void *ctx){
    return menu_popup_run(root, n, x, y, expand, ctx);
}

#ifdef GEM_XTOS
/* The dropdown panel's content: draw_items at the panel's origin. Children's ob_x/ob_y are
 * dropdown-relative already, so this is the same loop with dx=dy=0 and no flush (the damage
 * is client_paint's, like any window content). */
static void panel_draw_cb(int hd,int x,int y,int w,int h,void *ud){
    (void)hd;(void)x;(void)y;(void)ud;
    if(g_pn_ord<0 || !g_menu) return;
    { gfx_surface *ts=vdi_screen_target();         // clear to TRANSPARENT: the corners the
      if(ts){ for(int yy=0;yy<h && yy<ts->h;yy++){ // rounded slice does not cover stay alpha-0,
          uint32_t *r=ts->px+(size_t)yy*ts->stride; // so gemd blends them to the desktop, not
          for(int xx=0;xx<w && xx<ts->w;xx++) r[xx]=0; } } }   // to stale/black
    menu_pens();
    int ddi=DD0+g_pn_ord;
    theme_draw(H(),aes_theme(),"menu",0,0,w,h);
    vst_height(H(),14,0,0,0,0);
    EACH_CHILD(g_menu,ddi,c){
        int iy=g_menu[c].ob_y, ih=g_menu[c].ob_h;
        const char *lbl=(const char*)g_menu[c].ob_spec;
        if(bar_is_sep(lbl)){
            vsl_color(H(),PEN_SEP); vsl_width(H(),1);
            int16_t ln[4]={6,(int16_t)(iy+ih/2),(int16_t)(w-7),(int16_t)(iy+ih/2)};
            v_pline(H(),2,ln); continue;
        }
        int sel=(c==g_pn_hov), dis=(g_menu[c].ob_state&OS_DISABLED);
        if(sel){ vsf_color(H(),PEN_HILITE); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
                 int16_t r[4]={4,(int16_t)iy,(int16_t)(w-5),(int16_t)(iy+ih-1)}; vr_recfl(H(),r); }
        if(g_menu[c].ob_state&OS_CHECKED){
            int cx=7, cym=iy+ih/2;
            vsl_color(H(), sel?0:1); vsl_width(H(),2);
            int16_t tk[6]={(int16_t)cx,(int16_t)cym,(int16_t)(cx+3),(int16_t)(cym+3),(int16_t)(cx+8),(int16_t)(cym-4)};
            v_pline(H(),3,tk);
        }
        vst_color(H(), sel?0:(dis?9:1));
        v_gtext(H(), g_menu[c].ob_x, iy+ih/2-7, lbl);
    }
    (void)h;
}

/* gemd said a press landed in OUR strip (MSG_MENUCLK): grab, run the classic loop (its hit
 * math is absolute and the strip origin IS the screen origin), release. */
void menu_client_click(int x){
    if(!g_menu || !g_strip.px) return;
    g_mrevoked = 0;
    menu_grab(1);
    menu_handle_click(x, 0);
    if(!g_mrevoked) menu_grab(0);
}
#endif
