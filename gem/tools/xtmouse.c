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
 * The numeric KEYPAD drives Atari STICK0 (there is no physical joystick): KP_8=up KP_2=down
 * KP_4=left KP_6=right KP_0=fire, and the console keys KP_+=START KP_-=SELECT KP_*=OPTION.
 * These go over as the 'J' packet (below) to the PL joystick-override and CONSOL registers;
 * they are handled instead of the text path so they never type a digit.
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

/* Joystick packet (8 bytes, LE — input_udp.c is the other end):
 *   u8 magic 'J' | u8 porta(active-low PORTA pins) | u8 trig(active-low fire)
 *   | u8 consol(ACTIVE-HIGH pressed mask: bit0=START bit1=SELECT bit2=OPTION) | u8 pad*4
 * There is no physical joystick (the PCAL9722 SPI expander has no software path), so the Mac's
 * numeric keypad drives Atari STICK0 via the PL keypad-override register: KP_8=up KP_2=down
 * KP_4=left KP_6=right (STICK0 bits[0..3], active-low) and KP_0=fire (TRIG0, active-low). The
 * board latches this state and forces PORTA + TRIG0 until a neutral packet (0xFF/1) releases.
 * consol carries KP_+=START KP_-=SELECT KP_*=OPTION for the CONSOL ($D01F) register; it is
 * active-HIGH on the wire (unlike the register) so a zero pad byte means nothing pressed. */
static void send_stick(unsigned porta, unsigned trig, unsigned consol)
{
    unsigned char p[8] = { 'J', (unsigned char)porta, (unsigned char)(trig & 1),
                           (unsigned char)(consol & 7), 0, 0, 0, 0 };
    sendto(g_sock, p, sizeof p, 0, (struct sockaddr *)&g_dst, g_dstlen);
}

/* Keypad->STICK0 state. porta is the active-low PORTA pin shadow (STICK0 in bits[3:0], STICK1
 * bits[7:4] left released); fire is the active-low TRIG0 pin. Both start released. */
static unsigned char g_stick_porta = 0xFF;   /* 1 = released on every pin */
static unsigned char g_stick_fire  = 1;      /* 1 = fire released */
static unsigned char g_consol      = 0;      /* ACTIVE-HIGH pressed mask; 0 = none pressed */

/* A numeric-KEYPAD key -> its STICK0 active-low bit (0..3), or -1 if not a keypad direction.
 * ONLY SDLK_KP_* is matched, so the main number row is untouched and stays available for text. */
static int kp_stick_bit(SDL_Keycode sym)
{
    switch (sym) {
    case SDLK_KP_8: return 0;   /* up    */
    case SDLK_KP_2: return 1;   /* down  */
    case SDLK_KP_4: return 2;   /* left  */
    case SDLK_KP_6: return 3;   /* right */
    default:        return -1;
    }
}

/* A numeric-KEYPAD key -> its CONSOL pressed-mask bit (0..2), or -1 if not a console key. */
static int kp_consol_bit(SDL_Keycode sym)
{
    switch (sym) {
    case SDLK_KP_PLUS:     return 0;   /* START  */
    case SDLK_KP_MINUS:    return 1;   /* SELECT */
    case SDLK_KP_MULTIPLY: return 2;   /* OPTION */
    default:               return -1;
    }
}

/* Pending TEXTINPUT chars to swallow: on macOS the numeric keypad still emits SDL_TEXTINPUT
 * ("8","2","4",...) alongside the KEYDOWN, which would type into a game. We consume the keypad
 * KEYDOWN for the joystick and record the digit here; the matching following TEXTINPUT is
 * dropped so a keypad press never leaks a character. Indexed by char; only digits are used. */
static int g_kp_swallow[128];

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
                /* Numeric-KEYPAD -> STICK0 (no physical joystick). Handled here, BEFORE the text
                 * path, and the matching SDL_TEXTINPUT digit is swallowed so it never types.
                 * Only SDLK_KP_* — the main number row falls through to text below untouched. */
                {
                    static const char kp_digit[4]  = { '8', '2', '4', '6' };  /* bit -> keypad digit */
                    static const char kp_conchr[3] = { '+', '-', '*' };       /* bit -> keypad char */
                    int bit = kp_stick_bit(sym);
                    if (bit >= 0) {                       /* direction: press = clear (active-low) */
                        g_stick_porta &= ~(1u << bit);
                        send_stick(g_stick_porta, g_stick_fire, g_consol);
                        g_kp_swallow[(int)kp_digit[bit]]++;
                        break;
                    }
                    if (sym == SDLK_KP_0) {               /* fire: press = 0 (active-low) */
                        g_stick_fire = 0;
                        send_stick(g_stick_porta, g_stick_fire, g_consol);
                        g_kp_swallow['0']++;
                        break;
                    }
                    bit = kp_consol_bit(sym);
                    if (bit >= 0) {                       /* console key: press = set (active-high) */
                        g_consol |= (1u << bit);
                        send_stick(g_stick_porta, g_stick_fire, g_consol);
                        g_kp_swallow[(int)kp_conchr[bit]]++;
                        break;
                    }
                }
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
            case SDL_KEYUP: {
                if (!captured) break;
                /* Numeric-KEYPAD release -> STICK0 (mirror of the KEYDOWN above). */
                SDL_Keycode sym = e.key.keysym.sym;
                int bit = kp_stick_bit(sym);
                if (bit >= 0) {                          /* direction: release = set (active-low) */
                    g_stick_porta |= (1u << bit);
                    send_stick(g_stick_porta, g_stick_fire, g_consol);
                    break;
                }
                if (sym == SDLK_KP_0) {                  /* fire: release = 1 (active-low) */
                    g_stick_fire = 1;
                    send_stick(g_stick_porta, g_stick_fire, g_consol);
                    break;
                }
                bit = kp_consol_bit(sym);
                if (bit >= 0) {                          /* console key: release = clear (active-high) */
                    g_consol &= (unsigned char)~(1u << bit);
                    send_stick(g_stick_porta, g_stick_fire, g_consol);
                    break;
                }
                break;
            }
            case SDL_TEXTINPUT:
                if (captured) {                          /* UTF-8; forward the ASCII bytes */
                    for (const char *t = e.text.text; *t; ++t) {
                        unsigned char ch = (unsigned char)*t;
                        /* drop a keypad digit's echo so a joystick press never types (see g_kp_swallow) */
                        if (ch < 128 && g_kp_swallow[ch] > 0) { g_kp_swallow[ch]--; continue; }
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
