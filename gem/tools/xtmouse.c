/*
 * xtmouse — capture the Mac's mouse and stream it to the board over UDP.
 *
 * The interim real mouse AND keyboard, until the STM32 HID companion is manufactured: the
 * serial-terminal mouse is capped at ~12 motion reports/s by the emulator (board-measured);
 * this delivers raw deltas at device rate to the kernel's input_udp listener (:4242), which
 * feeds the same input queue as the serial decoder — the desktop just sees a fast mouse. It
 * also bypasses the console focus toggle entirely: the ` key stops mattering for pointing.
 *
 *   make xtmouse && ./build/xtmouse xtos.local
 *
 * Click the window to CAPTURE (relative mouse mode: the Mac cursor disappears, raw deltas
 * flow). Esc releases the capture (LOCAL — it is the escape hatch, so it is never forwarded;
 * a dialog's Cancel button is clickable). While captured, the keyboard is forwarded too, so
 * you can type into GEM dialogs without giving the serial terminal focus: printable keys go
 * over as SDL_TEXTINPUT (layout- and shift-correct), and Enter/Backspace/Tab/Delete plus
 * Ctrl+letter go over as their board key codes (matching the serial decoder in sprite.c).
 *
 * Loop shape — this matters on macOS. An app that never draws gets App Nap'd: the OS
 * coalesces its timers and event delivery, so motion arrives in clumps ("mouse freezes, then
 * jumps to where it should be"). caffeinate cannot fix that (it stops SLEEP, not NAP). So:
 *   1. NSProcessInfo beginActivityWithOptions:NSActivityLatencyCritical — the real opt-out;
 *   2. render a frame every vsync so WindowServer sees a live, unoccluded window;
 *   3. drain the WHOLE event queue each frame and coalesce motion into ONE packet
 *      (deltas integrate, so clumped delivery no longer changes what goes on the wire —
 *      and a steady ~60 pkt/s is kinder to the board's drop-oldest queue than 150 in bursts).
 *
 * Packet (8 bytes, LE — input_udp.c is the other end):
 *   u8 magic 'X' | u8 buttons(state) | s16 dx | s16 dy | s8 wheel | u8 pad
 */
#include <SDL.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>

#ifdef __APPLE__
#include <objc/message.h>
#include <objc/runtime.h>
/* [[NSProcessInfo processInfo] beginActivityWithOptions:reason:] from plain C. Foundation is
 * already in the process via SDL's Cocoa dependency. The token is retained for the app's
 * lifetime — letting it autorelease would END the activity and re-arm App Nap. */
static void app_nap_opt_out(void)
{
    typedef id (*msg_id)(id, SEL);
    typedef id (*msg_cls_id)(Class, SEL);
    typedef id (*msg_str)(Class, SEL, const char *);
    typedef id (*msg_begin)(id, SEL, unsigned long long, id);

    id proc = ((msg_cls_id)objc_msgSend)(objc_getClass("NSProcessInfo"),
                                         sel_registerName("processInfo"));
    id why  = ((msg_str)objc_msgSend)(objc_getClass("NSString"),
                                      sel_registerName("stringWithUTF8String:"),
                                      "xtmouse streams input in real time");
    /* NSActivityUserInitiated | NSActivityLatencyCritical: no nap, no timer coalescing */
    unsigned long long opts = (0x00FFFFFFULL | (1ULL << 20)) | 0xFF00000000ULL;
    id act = ((msg_begin)objc_msgSend)(proc,
                                       sel_registerName("beginActivityWithOptions:reason:"),
                                       opts, why);
    if (act) ((msg_id)objc_msgSend)(act, sel_registerName("retain"));
}
#else
static void app_nap_opt_out(void) {}
#endif

static int g_sock = -1;
static struct sockaddr_storage g_dst;
static socklen_t g_dstlen;

static void send_pkt(unsigned buttons, int dx, int dy, int wheel)
{
    if (dx < -32768) dx = -32768; if (dx > 32767) dx = 32767;
    if (dy < -32768) dy = -32768; if (dy > 32767) dy = 32767;
    if (wheel < -128) wheel = -128; if (wheel > 127) wheel = 127;
    unsigned char p[8] = { 'X', (unsigned char)buttons,
                           (unsigned char)(dx & 0xFF), (unsigned char)((dx >> 8) & 0xFF),
                           (unsigned char)(dy & 0xFF), (unsigned char)((dy >> 8) & 0xFF),
                           (unsigned char)(signed char)wheel, 0 };
    sendto(g_sock, p, sizeof p, 0, (struct sockaddr *)&g_dst, g_dstlen);
    /* per-second send counter: compare with the board's receive counter to place a gap */
    { static Uint32 t0; static int n;
      n++;
      Uint32 now = SDL_GetTicks();
      if (t0 == 0) t0 = now;
      if (now - t0 >= 1000) { fprintf(stderr, "xtmouse: %d pkt/s\n", n); n = 0; t0 = now; } }
}

/* Keyboard packet (8 bytes, LE — input_udp.c is the other end):
 *   u8 magic 'K' | u8 shift(K_ bitmask) | u16 key | u8 down | u8 pad*3
 * `key`/`shift` use the board's encoding (gem/aes/aes.h K_*, sprite.c serial decoder):
 * printable ASCII carries shift 0 (the character is already the shifted result), the
 * special keys carry their control code (Enter 0x0d, BS 0x08, Tab 0x09, Del 0x7f), and
 * Ctrl+letter arrives as the plain letter + K_CTRL — exactly what form_keybd expects. */
static void send_key(unsigned key, unsigned shift, int down)
{
    unsigned char p[8] = { 'K', (unsigned char)shift,
                           (unsigned char)(key & 0xFF), (unsigned char)((key >> 8) & 0xFF),
                           (unsigned char)(down ? 1 : 0), 0, 0, 0 };
    sendto(g_sock, p, sizeof p, 0, (struct sockaddr *)&g_dst, g_dstlen);
}

/* SDL modifier state -> board K_ bitmask (aes.h: RSHIFT=1 LSHIFT=2 CTRL=4 ALT=8 CAPS=0x10) */
static unsigned kmods(unsigned mod)
{
    unsigned s = 0;
    if (mod & KMOD_RSHIFT) s |= 0x01;
    if (mod & KMOD_LSHIFT) s |= 0x02;
    if (mod & KMOD_CTRL)   s |= 0x04;
    if (mod & KMOD_ALT)    s |= 0x08;
    if (mod & KMOD_CAPS)   s |= 0x10;
    return s;
}

int main(int argc, char **argv)
{
    const char *host = argc > 1 ? argv[1] : "xtos.local";
    const char *port = argc > 2 ? argv[2] : "4242";

    struct addrinfo hints, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host, port, &hints, &ai) != 0 || !ai) {
        fprintf(stderr, "xtmouse: cannot resolve %s (mDNS may be cold — retry)\n", host);
        return 1;
    }
    g_sock = socket(ai->ai_family, ai->ai_socktype, 0);
    memcpy(&g_dst, ai->ai_addr, ai->ai_addrlen); g_dstlen = ai->ai_addrlen;
    freeaddrinfo(ai);
    if (g_sock < 0) { perror("socket"); return 1; }

    app_nap_opt_out();

    SDL_Init(SDL_INIT_VIDEO);
    SDL_Window *win = SDL_CreateWindow("XT mouse — click to capture, Esc to release",
                                       SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                       420, 120, 0);
    if (!win) { fprintf(stderr, "xtmouse: %s\n", SDL_GetError()); return 1; }
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1,
                                           SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) ren = SDL_CreateRenderer(win, -1, 0);
    if (!ren) { fprintf(stderr, "xtmouse: %s\n", SDL_GetError()); return 1; }
    SDL_StartTextInput();      /* enable SDL_TEXTINPUT for keyboard forwarding while captured */
    printf("xtmouse: streaming to %s:%s — click the window to capture\n", host, port);

    unsigned buttons = 0;
    int running = 1, captured = 0;
    Uint32 frame = 0;
    while (running) {
        int dx = 0, dy = 0, wheel = 0, moved = 0;

        /* drain everything queued since the last frame; motion/wheel coalesce, button
         * edges flush immediately (with the deltas so far) so click ordering is exact */
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
            case SDL_QUIT: running = 0; break;
            case SDL_KEYDOWN: {
                SDL_Keycode sym = e.key.keysym.sym;
                if (sym == SDLK_ESCAPE && captured) {     /* LOCAL escape hatch, never forwarded */
                    SDL_SetRelativeMouseMode(SDL_FALSE);
                    captured = 0;
                    SDL_SetWindowTitle(win, "XT mouse — click to capture, Esc to release");
                    break;
                }
                if (!captured) break;
                /* Special keys that produce no SDL_TEXTINPUT — forward with the board's codes.
                 * Printable characters come through SDL_TEXTINPUT below (layout/shift correct),
                 * so we deliberately do NOT handle them here (that would double-send). */
                unsigned sh = kmods(e.key.keysym.mod), key = 0; int have = 0;
                switch (sym) {
                case SDLK_RETURN: case SDLK_KP_ENTER: key = 0x0d; have = 1; break;
                case SDLK_BACKSPACE:                  key = 0x08; have = 1; break;
                case SDLK_TAB:                        key = 0x09; have = 1; break;
                case SDLK_DELETE:                     key = 0x7f; have = 1; break;
                default: break;
                }
                /* Ctrl+letter (e.g. Ctrl-U clears a field): TEXTINPUT is suppressed while Ctrl
                 * is held, so route it here as plain letter + K_CTRL, matching sprite.c. */
                if (!have && (e.key.keysym.mod & KMOD_CTRL) && sym >= SDLK_a && sym <= SDLK_z) {
                    key = (unsigned)sym; sh |= 0x04; have = 1;
                }
                if (have) send_key(key, sh, 1);
                break;
            }
            case SDL_TEXTINPUT:
                if (captured) {                          /* UTF-8; forward the ASCII bytes */
                    for (const char *t = e.text.text; *t; ++t) {
                        unsigned char ch = (unsigned char)*t;
                        if (ch >= 0x20 && ch < 0x7f) send_key(ch, 0, 1);
                    }
                }
                break;
            case SDL_MOUSEBUTTONDOWN:
                if (!captured) {
                    SDL_SetRelativeMouseMode(SDL_TRUE);   /* raw deltas, no edge clamp */
                    captured = 1;
                    SDL_SetWindowTitle(win, "XT mouse — CAPTURED (Esc to release)");
                    break;                                /* the capture click stays local */
                }
                if (moved) { send_pkt(buttons, dx, dy, 0); dx = dy = 0; moved = 0; }
                if (e.button.button == SDL_BUTTON_LEFT)   buttons |= 1;
                if (e.button.button == SDL_BUTTON_RIGHT)  buttons |= 2;
                if (e.button.button == SDL_BUTTON_MIDDLE) buttons |= 4;
                send_pkt(buttons, 0, 0, 0);
                break;
            case SDL_MOUSEBUTTONUP:
                if (!captured) break;
                if (moved) { send_pkt(buttons, dx, dy, 0); dx = dy = 0; moved = 0; }
                if (e.button.button == SDL_BUTTON_LEFT)   buttons &= ~1u;
                if (e.button.button == SDL_BUTTON_RIGHT)  buttons &= ~2u;
                if (e.button.button == SDL_BUTTON_MIDDLE) buttons &= ~4u;
                send_pkt(buttons, 0, 0, 0);
                break;
            case SDL_MOUSEMOTION:
                if (captured) { dx += e.motion.xrel; dy += e.motion.yrel; moved = 1; }
                break;
            case SDL_MOUSEWHEEL:
                if (captured && e.wheel.y) { wheel += e.wheel.y > 0 ? 1 : -1; moved = 1; }
                break;
            }
        }
        if (moved && (dx || dy || wheel))
            send_pkt(buttons, dx, dy, wheel);

        /* heartbeat frame: a live, presenting window is what keeps WindowServer treating
         * the app as active (belt to the beginActivity braces). Green pulse = captured. */
        frame++;
        Uint8 base = (Uint8)(28 + ((frame >> 4) & 1) * 6);
        if (captured) SDL_SetRenderDrawColor(ren, 20, base + 40, 24, 255);
        else          SDL_SetRenderDrawColor(ren, base, base, base + 8, 255);
        SDL_RenderClear(ren);
        Uint32 before = SDL_GetTicks();
        SDL_RenderPresent(ren);                 /* vsync paces the loop at ~60 Hz */
        if (SDL_GetTicks() - before < 4)
            SDL_Delay(4);                       /* present may not block when occluded */
    }
    close(g_sock);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
