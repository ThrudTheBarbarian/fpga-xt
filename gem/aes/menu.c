// aes/menu.c — GEM menu bar + pull-downs.  menu_build assembles the standard
// OBJECT tree (a bar of G_TITLEs, plus one dropdown G_BOX of G_STRING items per
// title); menu_bar draws it; a bar click (caught inside evnt_multi via
// menu_handle_click) runs the pull-down, then posts MN_SELECTED to the message
// pipe — so the app just receives the message from evnt_mesag.

#include "aes/aes_internal.h"
#include <stdlib.h>
#include <string.h>

#define BARH   22
#define ITEMH  20
#define TPAD   14
#define DDPADX 22
#define DDPADY 4
#define PEN_BAR    246
#define PEN_HILITE 247
#define PEN_BARLINE 245

static OBJECT *g_menu;
static int g_n, T0, DD0, ACTIVE;        // title count + base object indices
static int H(void) { return aes_handle(); }

#define EACH_CHILD(t,p,c) for(int c=(t)[p].ob_head;c>=0;c=(c==(t)[p].ob_tail?-1:(t)[c].ob_next))

static int text_w(const char *s) { int16_t e[8]; vst_height(H(),14,0,0,0,0); vqt_extent(H(),s,e); return e[2]-e[0]; }

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
        int mw=0; for(int j=0;j<m[i].nitems;j++){int w=text_w(m[i].items[j]); if(w>mw)mw=w;}
        int ddw=mw+DDPADX+12, ddh=m[i].nitems*ITEMH+DDPADY*2, ddi=dd0+i, first=it;
        int titlew=text_w(m[i].title)+TPAD*2;
        t[ddi]=(OBJECT){(int16_t)(i<n-1?ddi+1:active),(int16_t)first,(int16_t)(first+m[i].nitems-1),
                        G_BOX,OF_HIDETREE,OS_NORMAL,0,(int16_t)tx,0,(int16_t)ddw,(int16_t)ddh};
        for (int j=0;j<m[i].nitems;j++){
            int oi=it++;
            t[oi]=(OBJECT){(int16_t)(j<m[i].nitems-1?oi+1:ddi),NIL,NIL,G_STRING,
                           OF_SELECTABLE,OS_NORMAL,(void*)m[i].items[j],
                           (int16_t)DDPADX,(int16_t)(DDPADY+j*ITEMH),(int16_t)(ddw-DDPADX-4),ITEMH};
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

void menu_bar(OBJECT *tree, int show) {
    if (show) {
        g_menu = tree;
        T0 = 2; ACTIVE = g_menu[1].ob_next; DD0 = g_menu[ACTIVE].ob_head;
        g_n = 0; EACH_CHILD(g_menu,1,c) g_n++;
        const theme *th = aes_theme();
        v_setrgb(H(), PEN_BAR, 244,245,247);
        if (th) { v_setrgb(H(), PEN_HILITE,(th->highlight>>24)&0xFF,(th->highlight>>16)&0xFF,(th->highlight>>8)&0xFF);
                  v_setrgb(H(), PEN_BARLINE,(th->border>>24)&0xFF,(th->border>>16)&0xFF,(th->border>>8)&0xFF); }
        draw_bar();
    } else {
        g_menu = NULL;
    }
}

void menu_tnormal(OBJECT *t, int title, int normal) {
    if (normal) t[title].ob_state &= ~OS_SELECTED; else t[title].ob_state |= OS_SELECTED;
}
void menu_icheck(OBJECT *t, int item, int check) {
    if (check) t[item].ob_state |= OS_CHECKED; else t[item].ob_state &= ~OS_CHECKED;
}
void menu_ienable(OBJECT *t, int item, int enable) {
    if (enable) t[item].ob_state &= ~OS_DISABLED; else t[item].ob_state |= OS_DISABLED;
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
    gfx_surface_free(g_sav); g_sav=NULL;
}

static void hilite_title(int ord,int on){
    int ti=T0+ord, x=g_menu[ti].ob_x, w=g_menu[ti].ob_w;
    if(on){ vsf_color(H(),PEN_HILITE); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
            int16_t r[4]={(int16_t)x,0,(int16_t)(x+w-1),BARH-2}; vr_recfl(H(),r); vst_color(H(),0); }
    else  { vsf_color(H(),PEN_BAR); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
            int16_t r[4]={(int16_t)x,0,(int16_t)(x+w-1),BARH-2}; vr_recfl(H(),r); vst_color(H(),1); }
    vst_height(H(),14,0,0,0,0);
    v_gtext(H(), x+TPAD, BARH/2-7, (const char*)g_menu[ti].ob_spec);
}

static void draw_items(int ord,int hov){
    int ddi=DD0+ord, dx,dy; objc_offset(g_menu,ddi,&dx,&dy);
    int w=g_menu[ddi].ob_w, h=g_menu[ddi].ob_h;
    theme_draw(H(),aes_theme(),"menu",dx,dy,w,h);
    vst_height(H(),14,0,0,0,0);
    EACH_CHILD(g_menu,ddi,c){
        int iy=dy+g_menu[c].ob_y, ih=g_menu[c].ob_h;
        if(c==hov){ vsf_color(H(),PEN_HILITE); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);
                    int16_t r[4]={(int16_t)(dx+4),(int16_t)iy,(int16_t)(dx+w-5),(int16_t)(iy+ih-1)}; vr_recfl(H(),r);
                    vst_color(H(),0); }
        else vst_color(H(), (g_menu[c].ob_state&OS_DISABLED)?9:1);
        if(g_menu[c].ob_state&OS_CHECKED) v_gtext(H(), dx+6, iy+ih/2-7, "\xE2\x9C\x93");   // check mark
        v_gtext(H(), dx+g_menu[c].ob_x, iy+ih/2-7, (const char*)g_menu[c].ob_spec);
    }
}

static int title_at(int mx){
    for(int i=0;i<g_n;i++){ int ti=T0+i; if(mx>=g_menu[ti].ob_x && mx<g_menu[ti].ob_x+g_menu[ti].ob_w) return i; }
    return -1;
}
static int item_at(int ord,int mx,int my){
    int ddi=DD0+ord, dx,dy; objc_offset(g_menu,ddi,&dx,&dy);
    if(mx<dx || mx>=dx+g_menu[ddi].ob_w) return -1;
    EACH_CHILD(g_menu,ddi,c){ int iy=dy+g_menu[c].ob_y;
        if(my>=iy && my<iy+g_menu[c].ob_h && !(g_menu[c].ob_state&OS_DISABLED)) return c; }
    return -1;
}
static void open_menu(int ord){
    hilite_title(ord,1);
    int ddi=DD0+ord, dx,dy; objc_offset(g_menu,ddi,&dx,&dy);
    save_area(dx,dy,g_menu[ddi].ob_w,g_menu[ddi].ob_h);
    draw_items(ord,-1);
}
static void close_menu(int ord){ restore_area(); hilite_title(ord,0); }

void menu_render_open(int to, int io){
    if(!g_menu) return;
    hilite_title(to,1);
    int ddi=DD0+to, hov=-1, j=0;
    if(io>=0) EACH_CHILD(g_menu,ddi,c){ if(j==io){hov=c;break;} j++; }
    draw_items(to,hov);
}

int menu_handle_click(int mx, int my){
    if(!g_menu || my>=BARH) return 0;
    int cur=title_at(mx); if(cur<0) return 1;        // bar click, no title -> consumed
    open_menu(cur);
    int hov=-1, sel=-1;
    for(;;){
        aes_event ev; int t=aes_wait(&ev,-1);
        if(t==AES_QUIT){ close_menu(cur); return 1; }
        int nx=ev.mx, ny=ev.my;
        if(ny<BARH){ int nt=title_at(nx);
            if(nt>=0 && nt!=cur){ close_menu(cur); cur=nt; open_menu(cur); hov=-1; }
            else if(hov!=-1){ hov=-1; draw_items(cur,hov); } }
        else { int hi=item_at(cur,nx,ny); if(hi!=hov){ hov=hi; draw_items(cur,hov); } }
        if(t==AES_BTN_UP){ sel=hov; break; }
    }
    close_menu(cur);
    if(sel>=0){ int16_t msg[8]={MN_SELECTED,1,0,(int16_t)(T0+cur),(int16_t)sel,0,0,0}; appl_write(0,16,msg); }
    return 1;
}
