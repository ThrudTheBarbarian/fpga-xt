// vdi/input.c — VDI input + cursor (the locator/valuator/choice/string devices,
// the mouse-pointer show/hide, and the input-vector exchange).  The VDI is
// device-output-centric, so "input" here is a thin shim over a host-fed state:
// the SDL backend (or, on hardware, the AES event pump) pushes the live pointer
// position, button mask, shift state and typed characters in through the
// vdi_input_* setters; the VDI calls below read that state.
//
// Two input modes per device (vsin_mode): REQUEST blocks until the device
// triggers (a button or a terminator key), SAMPLE returns the current state at
// once.  Blocking is cooperative — it drives the host pump callback until the
// trigger arrives; with no pump registered (headless tests) REQUEST degrades to
// a single non-blocking read so nothing ever hangs.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

#define KEYRING 64

static struct {
    int  mouse_x, mouse_y;
    int  buttons;                 // bit0 left, bit1 right, bit2 middle
    int  shift;                   // vq_key_s mask
    int  valuator;
    int  choice;
    int  hide_depth;              // >0 => pointer hidden (v_hide_c nests)
    int  kq[KEYRING], kqh, kqt;   // typed-character ring
    void (*pump)(void *);
    void *pump_ctx;
    vdi_vec vec_but, vec_mot, vec_cur, vec_tim;
    vdi_wheel_vec vec_wheel;
} in;

// ---- Host-facing setters (called by the SDL backend / AES pump) -----------
void vdi_input_mouse(int x, int y, int buttons) {
    in.mouse_x = x; in.mouse_y = y; in.buttons = buttons;
}
void vdi_input_key(int ch) {
    if (!ch) return;
    int nt = (in.kqt + 1) % KEYRING;
    if (nt == in.kqh) return;     // ring full: drop
    in.kq[in.kqt] = ch; in.kqt = nt;
}
void vdi_input_shift(int mask)    { in.shift = mask; }
void vdi_input_valuator(int v)    { in.valuator = v; }
void vdi_input_choice(int c)      { in.choice = c; }
// A wheel event: accumulate into the valuator and fire the vex_wheelv handler.
void vdi_input_wheel(int wheel, int amount) {
    in.valuator += amount;
    if (in.vec_wheel) in.vec_wheel(wheel, amount);
}
void vdi_input_set_pump(void (*pump)(void *), void *ctx) { in.pump = pump; in.pump_ctx = ctx; }
int  vdi_cursor_visible(void)     { return in.hide_depth == 0; }

static int key_deq(void) {
    if (in.kqh == in.kqt) return 0;
    int c = in.kq[in.kqh]; in.kqh = (in.kqh + 1) % KEYRING;
    return c;
}
static void pump_once(void) { if (in.pump) in.pump(in.pump_ctx); }

// ---- vsin_mode: choose REQUEST/SAMPLE for a device class ------------------
void op_sin_mode(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int dev = pb->intin[0], mode = pb->intin[1];
    if (dev >= 1 && dev <= 4) w->in_mode[dev] = mode;
    pb->intout[0] = (int16_t)mode;
}

// ---- Locator (op 28): pointer position + a terminator ---------------------
void op_locator(vdi_pb *pb) {
    int req = pb->contrl[5] == VDI_MODE_REQUEST;
    if (req && pb->contrl[1] >= 1) { in.mouse_x = pb->ptsin[0]; in.mouse_y = pb->ptsin[1]; } // seed
    int term = 0;
    if (req) {
        for (; in.pump; ) {       // block until a button or a key
            pump_once();
            if (in.buttons) { term = 0x20 | in.buttons; break; }   // pseudo button char
            int k = key_deq(); if (k) { term = k; break; }
        }
    }
    pb->ptsout[0] = (int16_t)in.mouse_x;
    pb->ptsout[1] = (int16_t)in.mouse_y;
    if (req) {
        pb->intout[0] = (int16_t)term;
        pb->contrl[4] = 1;
    } else {
        int k = key_deq();
        pb->intout[0] = (int16_t)(k ? k : in.buttons);
        pb->contrl[4] = 1;
    }
    pb->contrl[2] = 1;
}

// ---- Valuator (op 29): a single scalar (e.g. a dial / wheel) --------------
void op_valuator(vdi_pb *pb) {
    int req = pb->contrl[5] == VDI_MODE_REQUEST;
    if (pb->contrl[3] >= 1) in.valuator = pb->intin[0];   // initial value
    int term = 0;
    if (req) for (; in.pump; ) {
        pump_once();
        if (in.buttons) { term = 0x20 | in.buttons; break; }
        int k = key_deq(); if (k) { term = k; break; }
    }
    pb->intout[0] = (int16_t)in.valuator;
    pb->intout[1] = (int16_t)term;
    pb->contrl[4] = 2;
}

// ---- Choice (op 30): a numbered selection (function keys) -----------------
void op_choice(vdi_pb *pb) {
    int req = pb->contrl[5] == VDI_MODE_REQUEST;
    if (req) for (; in.pump; ) {
        pump_once();
        if (in.choice) break;
        if (key_deq()) break;
    }
    pb->intout[0] = (int16_t)in.choice;
    pb->contrl[4] = 1;
}

// ---- String (op 31): a typed line -----------------------------------------
void op_string(vdi_pb *pb) {
    int req = pb->contrl[5] == VDI_MODE_REQUEST;
    int maxlen = pb->intin[0]; if (maxlen < 0) maxlen = 0; if (maxlen > 126) maxlen = 126;
    // echo = pb->intin[1] — the host owns the echo; we just collect.
    int n = 0;
    for (;;) {
        int k = key_deq();
        if (!k) {
            if (req && in.pump && n < maxlen) { pump_once(); continue; }
            break;                                  // sample, or nothing pending
        }
        if (k == '\r' || k == '\n') break;          // Enter ends the line
        if (k == '\b') { if (n > 0) n--; continue; } // backspace
        if (n < maxlen) pb->intout[n++] = (int16_t)k;
    }
    pb->intout[n] = 0;
    pb->contrl[4] = (int16_t)n;
}

// ---- Cursor (mouse pointer) ----------------------------------------------
void op_show_c(vdi_pb *pb) {
    int reset = pb->contrl[3] >= 1 ? pb->intin[0] : 0;
    if (reset) in.hide_depth = 0;                   // force visible
    else if (in.hide_depth > 0) in.hide_depth--;    // undo one v_hide_c
}
void op_hide_c(vdi_pb *pb) { (void)pb; in.hide_depth++; }

// ---- vq_mouse: current position + buttons ---------------------------------
void op_q_mouse(vdi_pb *pb) {
    pb->intout[0] = (int16_t)in.buttons;
    pb->ptsout[0] = (int16_t)in.mouse_x;
    pb->ptsout[1] = (int16_t)in.mouse_y;
    pb->contrl[2] = 1;
}
// ---- vq_key_s: shift/ctrl/alt state ---------------------------------------
void op_q_key_s(vdi_pb *pb) { pb->intout[0] = (int16_t)in.shift; }

// ---- vex_*: exchange an input-interrupt vector ----------------------------
vdi_vec g_vex_in, g_vex_out;
void op_vex(vdi_pb *pb) {
    switch (pb->contrl[0]) {
        case VDI_VEX_BUTV: g_vex_out = in.vec_but; in.vec_but = g_vex_in; break;
        case VDI_VEX_MOTV: g_vex_out = in.vec_mot; in.vec_mot = g_vex_in; break;
        case VDI_VEX_CURV: g_vex_out = in.vec_cur; in.vec_cur = g_vex_in; break;
        case VDI_VEX_TIMV: g_vex_out = in.vec_tim; in.vec_tim = g_vex_in; break;
    }
}
// vex_wheelv: exchange the wheel handler (its own type — takes wheel + amount).
vdi_wheel_vec g_vex_wheel_in, g_vex_wheel_out;
void op_vex_wheel(vdi_pb *pb) { (void)pb; g_vex_wheel_out = in.vec_wheel; in.vec_wheel = g_vex_wheel_in; }

// ===========================================================================
// C bindings
// ===========================================================================
void vsin_mode(int handle, int dev, int mode) {
    g_intin[0] = (int16_t)dev; g_intin[1] = (int16_t)mode;
    vdi_emit(VDI_SIN_MODE, 0, handle, 0, 2);
}

static int locator(int handle, int mode, int x, int y, int *ox, int *oy) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y;
    vdi_emit(VDI_LOCATOR, mode, handle, 1, 0);
    if (ox) *ox = g_ptsout[0];
    if (oy) *oy = g_ptsout[1];
    return g_intout[0];
}
int vrq_locator(int handle, int x, int y, int *ox, int *oy) {
    return locator(handle, VDI_MODE_REQUEST, x, y, ox, oy);
}
int vsm_locator(int handle, int x, int y, int *ox, int *oy) {
    return locator(handle, VDI_MODE_SAMPLE, x, y, ox, oy);
}

int vrq_valuator(int handle, int valin) {
    g_intin[0] = (int16_t)valin;
    vdi_emit(VDI_VALUATOR, VDI_MODE_REQUEST, handle, 0, 1);
    return g_intout[0];
}
int vsm_valuator(int handle, int *val) {
    vdi_emit(VDI_VALUATOR, VDI_MODE_SAMPLE, handle, 0, 0);
    if (val) *val = g_intout[0];
    return g_intout[1];
}

int vrq_choice(int handle, int chin) {
    g_intin[0] = (int16_t)chin;
    vdi_emit(VDI_CHOICE, VDI_MODE_REQUEST, handle, 0, 1);
    return g_intout[0];
}
int vsm_choice(int handle, int *choice) {
    vdi_emit(VDI_CHOICE, VDI_MODE_SAMPLE, handle, 0, 0);
    if (choice) *choice = g_intout[0];
    return g_intout[0] != 0;
}

static int vdi_string(int handle, int mode, int maxlen, int echo, char *out) {
    g_intin[0] = (int16_t)maxlen; g_intin[1] = (int16_t)echo;
    vdi_emit(VDI_STRING, mode, handle, 0, 2);
    int n = g_contrl[4];
    if (out) { for (int i = 0; i < n; i++) out[i] = (char)g_intout[i]; out[n] = '\0'; }
    return n;
}
int vrq_string(int handle, int maxlen, int echo, char *out) {
    return vdi_string(handle, VDI_MODE_REQUEST, maxlen, echo, out);
}
int vsm_string(int handle, int maxlen, int echo, char *out) {
    return vdi_string(handle, VDI_MODE_SAMPLE, maxlen, echo, out);
}

void v_show_c(int handle, int reset) {
    g_intin[0] = (int16_t)reset;
    vdi_emit(VDI_SHOW_C, 0, handle, 0, 1);
}
void v_hide_c(int handle) { vdi_emit(VDI_HIDE_C, 0, handle, 0, 0); }

int vq_mouse(int handle, int *buttons, int *x, int *y) {
    vdi_emit(VDI_Q_MOUSE, 0, handle, 0, 0);
    if (buttons) *buttons = g_intout[0];
    if (x) *x = g_ptsout[0];
    if (y) *y = g_ptsout[1];
    return g_intout[0];
}
int vq_key_s(int handle, int *shift) {
    vdi_emit(VDI_Q_KEY_S, 0, handle, 0, 0);
    if (shift) *shift = g_intout[0];
    return g_intout[0];
}

static vdi_vec vex(int handle, int op, vdi_vec f) {
    g_vex_in = f; g_vex_out = 0;
    vdi_emit(op, 0, handle, 0, 0);
    return g_vex_out;
}
vdi_vec vex_butv(int handle, vdi_vec f) { return vex(handle, VDI_VEX_BUTV, f); }
vdi_vec vex_motv(int handle, vdi_vec f) { return vex(handle, VDI_VEX_MOTV, f); }
vdi_vec vex_curv(int handle, vdi_vec f) { return vex(handle, VDI_VEX_CURV, f); }
vdi_vec vex_timv(int handle, vdi_vec f) { return vex(handle, VDI_VEX_TIMV, f); }
vdi_wheel_vec vex_wheelv(int handle, vdi_wheel_vec f) {
    g_vex_wheel_in = f; g_vex_wheel_out = 0;
    vdi_emit(VDI_VEX_WHEELV, 0, handle, 0, 0);
    return g_vex_wheel_out;
}
