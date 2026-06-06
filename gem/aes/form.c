// aes/form.c — form_do, the modal dialog interaction loop.  Drives the host
// event source: present the dialog (objc_draw), wait for a click/key, update
// object state, repeat — until an EXIT button is clicked or Return fires the
// default button.

#include "aes/aes_internal.h"
#include <string.h>

#define DEPTH 8
#define BIG   4096

#define EACH_CHILD(t, parent, c) \
    for (int c = (t)[parent].ob_head; c >= 0; c = (c == (t)[parent].ob_tail ? -1 : (t)[c].ob_next))

static int find_parent(OBJECT *t, int root, int target) {
    EACH_CHILD(t, root, c) {
        if (c == target) return root;
        int p = find_parent(t, c, target);
        if (p >= 0) return p;
    }
    return -1;
}
static int find_default(OBJECT *t, int root) {
    if (t[root].ob_flags & OF_DEFAULT) return root;
    EACH_CHILD(t, root, c) { int d = find_default(t, c); if (d >= 0) return d; }
    return -1;
}
// Select a radio button, deselecting its RBUTTON siblings.
static void do_radio(OBJECT *t, int o) {
    int p = find_parent(t, 0, o);
    if (p >= 0) EACH_CHILD(t, p, c) if (t[c].ob_flags & OF_RBUTTON) t[c].ob_state &= ~OS_SELECTED;
    t[o].ob_state |= OS_SELECTED;
}
static void draw(OBJECT *t) { objc_draw(t, 0, DEPTH, 0, 0, BIG, BIG); }

int form_do(OBJECT *t, int start) {
    (void)start;
    draw(t);
    int pressed = -1;
    for (;;) {
        aes_event ev;
        int ty = aes_wait(&ev, -1);
        if (ty == AES_QUIT) return -1;

        if (ty == AES_KEY) {
            if (ev.key == '\r' || ev.key == '\n') {
                int d = find_default(t, 0);
                if (d >= 0 && !(t[d].ob_state & OS_DISABLED)) {
                    t[d].ob_state |= OS_SELECTED; draw(t);
                    return d;
                }
            }
            continue;
        }
        if (ty == AES_BTN_DOWN) {
            int o = objc_find(t, 0, DEPTH, ev.mx, ev.my);
            if (o >= 0 && (t[o].ob_flags & OF_SELECTABLE) && !(t[o].ob_state & OS_DISABLED)) {
                if (t[o].ob_flags & (OF_EXIT | OF_TOUCHEXIT)) { t[o].ob_state |= OS_SELECTED; pressed = o; }
                else if (t[o].ob_flags & OF_RBUTTON)         { do_radio(t, o); }
                else                                          { t[o].ob_state ^= OS_SELECTED; }
                draw(t);
                if (t[o].ob_flags & OF_TOUCHEXIT) return o;
            }
            continue;
        }
        if (ty == AES_BTN_UP && pressed >= 0) {
            int o = objc_find(t, 0, DEPTH, ev.mx, ev.my);
            int hit = (o == pressed);
            t[pressed].ob_state &= ~OS_SELECTED; draw(t);
            int p = pressed; pressed = -1;
            if (hit) return p;                          // released inside -> trigger
        }
    }
}

// ---- form_alert ---------------------------------------------------------
static int atext_w(const char *s){ int16_t e[8]; vst_height(aes_handle(),14,0,0,0,0); vqt_extent(aes_handle(),s,e); return e[2]-e[0]; }

int form_alert(int defbtn, const char *s) {
    char line[5][80], btn[3][24]; int icon=0, nl=0, nb=0;
    const char *p=s;
    while(*p && *p!='[') p++; if(*p)p++;                 // [icon]
    if(*p>='0'&&*p<='9') icon=*p-'0';
    while(*p && *p!=']') p++; if(*p)p++;
    while(*p && *p!='[') p++; if(*p)p++;                 // [message]
    { int li=0,ci=0; while(*p&&*p!=']'){ if(*p=='|'){ line[li][ci]=0; if(++li>=5){li=4;break;} ci=0; }
        else if(ci<79) line[li][ci++]=*p; p++; } line[li][ci]=0; nl=li+1; }
    while(*p && *p!=']') p++; if(*p)p++;
    while(*p && *p!='[') p++; if(*p)p++;                 // [buttons]
    { int bi=0,ci=0; while(*p&&*p!=']'){ if(*p=='|'){ btn[bi][ci]=0; if(++bi>=3){bi=2;break;} ci=0; }
        else if(ci<23) btn[bi][ci++]=*p; p++; } btn[bi][ci]=0; nb=bi+1; }
    if(defbtn<1||defbtn>nb) defbtn=nb;

    const char *icn = icon==1?"alert.note":icon==2?"alert.wait":icon==3?"alert.stop":0;
    const theme_slice *is = icn? theme_find(aes_theme(),icn):0;
    int iw = is?is->sw:0, ih = is?is->sh:0;

    int PAD=18, LINEH=18, BTNH=28, GAP=10;
    int msgw=0; for(int i=0;i<nl;i++){ int w=atext_w(line[i]); if(w>msgw)msgw=w; }
    int bw[3], tbw=0; for(int i=0;i<nb;i++){ bw[i]=atext_w(btn[i])+28; tbw+=bw[i]+(i?GAP:0); }
    int ix = PAD, mx = PAD + (iw?iw+PAD:0);
    int body_w = mx + msgw + PAD, box_w = body_w>PAD+tbw+PAD?body_w:PAD+tbw+PAD;
    int content_h = (ih>nl*LINEH?ih:nl*LINEH);
    int box_h = PAD + content_h + PAD + BTNH + PAD;

    OBJECT o[12]; memset(o,0,sizeof o); int n=1;
    o[0]=(OBJECT){NIL,1,0,G_BOX,OF_NONE,OS_NORMAL,0,0,0,(int16_t)box_w,(int16_t)box_h};
    if(icn){ o[n]=(OBJECT){0,NIL,NIL,G_IMAGE,OF_NONE,OS_NORMAL,(void*)icn,(int16_t)ix,(int16_t)PAD,(int16_t)iw,(int16_t)ih}; n++; }
    for(int i=0;i<nl;i++){ o[n]=(OBJECT){0,NIL,NIL,G_STRING,OF_NONE,OS_NORMAL,(void*)line[i],(int16_t)mx,(int16_t)(PAD+i*LINEH),(int16_t)msgw,LINEH}; n++; }
    int firstbtn=n, bx=(box_w-tbw)/2, by=box_h-PAD-BTNH;
    for(int i=0;i<nb;i++){ o[n]=(OBJECT){0,NIL,NIL,G_BUTTON,
        (uint16_t)(OF_SELECTABLE|OF_EXIT|((i+1==defbtn)?OF_DEFAULT:0)),OS_NORMAL,
        (void*)btn[i],(int16_t)bx,(int16_t)by,(int16_t)bw[i],BTNH}; bx+=bw[i]+GAP; n++; }
    o[0].ob_tail=n-1;
    for(int i=1;i<n;i++) o[i].ob_next=(i<n-1)?(i+1):0;
    o[n-1].ob_flags|=OF_LASTOB;

    int wx,wy,ww,wh; wind_get(0,WF_WORKXYWH,&wx,&wy,&ww,&wh);
    o[0].ob_x=wx+(ww-box_w)/2; o[0].ob_y=wy+(wh-box_h)/2;

    // save what's underneath, run modal, restore
    int H=aes_handle();
    gfx_surface *sav=gfx_surface_alloc(box_w,box_h);
    MFDB scr={0}, m; mfdb_from_surface(&m,sav);
    int16_t sp[8]={(int16_t)o[0].ob_x,(int16_t)o[0].ob_y,(int16_t)(o[0].ob_x+box_w-1),(int16_t)(o[0].ob_y+box_h-1),0,0,(int16_t)(box_w-1),(int16_t)(box_h-1)};
    vro_cpyfm(H,VRO_COPY,sp,&scr,&m);
    int r=form_do(o,0);
    int16_t rp[8]={0,0,(int16_t)(box_w-1),(int16_t)(box_h-1),(int16_t)o[0].ob_x,(int16_t)o[0].ob_y,(int16_t)(o[0].ob_x+box_w-1),(int16_t)(o[0].ob_y+box_h-1)};
    vro_cpyfm(H,VRO_COPY,rp,&m,&scr); gfx_surface_free(sav);

    return (r>=firstbtn && r<firstbtn+nb) ? (r-firstbtn+1) : defbtn;
}
