/*
 * xtmouse — capture the Mac's mouse and stream it to the board over UDP.
 *
 * The interim real mouse, until the STM32 HID companion is manufactured: the serial-terminal
 * mouse is capped at ~12 motion reports/s by the emulator (board-measured); this delivers
 * raw deltas at device rate to the kernel's input_udp listener (:4242), which feeds the same
 * input queue as the serial decoder — the desktop just sees a fast mouse. It also bypasses
 * the console focus toggle entirely: the ` key stops mattering for pointing.
 *
 *   make xtmouse && ./build/xtmouse xtos.local
 *
 * Click the window to CAPTURE (relative mouse mode: the Mac cursor disappears, raw deltas
 * flow). Esc releases the capture. Wheel and left button are forwarded; keys are NOT (the
 * terminal keeps the keyboard until the STM32).
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

static int g_sock = -1;
static struct sockaddr_storage g_dst;
static socklen_t g_dstlen;

static void send_pkt(unsigned buttons, int dx, int dy, int wheel)
{
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

    SDL_Init(SDL_INIT_VIDEO);
    SDL_Window *win = SDL_CreateWindow("XT mouse — click to capture, Esc to release",
                                       SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                       420, 120, 0);
    if (!win) { fprintf(stderr, "xtmouse: %s\n", SDL_GetError()); return 1; }
    printf("xtmouse: streaming to %s:%s — click the window to capture\n", host, port);

    unsigned buttons = 0;
    int running = 1, captured = 0;
    while (running) {
        SDL_Event e;
        if (!SDL_WaitEvent(&e)) break;
        switch (e.type) {
        case SDL_QUIT: running = 0; break;
        case SDL_KEYDOWN:
            if (e.key.keysym.sym == SDLK_ESCAPE && captured) {
                SDL_SetRelativeMouseMode(SDL_FALSE);
                captured = 0;
                SDL_SetWindowTitle(win, "XT mouse — click to capture, Esc to release");
            }
            break;
        case SDL_MOUSEBUTTONDOWN:
            if (!captured) {
                SDL_SetRelativeMouseMode(SDL_TRUE);      /* raw deltas, no edge clamp */
                captured = 1;
                SDL_SetWindowTitle(win, "XT mouse — CAPTURED (Esc to release)");
                break;                                    /* the capture click stays local */
            }
            if (e.button.button == SDL_BUTTON_LEFT)   buttons |= 1;
            if (e.button.button == SDL_BUTTON_RIGHT)  buttons |= 2;
            if (e.button.button == SDL_BUTTON_MIDDLE) buttons |= 4;
            send_pkt(buttons, 0, 0, 0);
            break;
        case SDL_MOUSEBUTTONUP:
            if (!captured) break;
            if (e.button.button == SDL_BUTTON_LEFT)   buttons &= ~1u;
            if (e.button.button == SDL_BUTTON_RIGHT)  buttons &= ~2u;
            if (e.button.button == SDL_BUTTON_MIDDLE) buttons &= ~4u;
            send_pkt(buttons, 0, 0, 0);
            break;
        case SDL_MOUSEMOTION:
            if (captured && (e.motion.xrel || e.motion.yrel))
                send_pkt(buttons, e.motion.xrel, e.motion.yrel, 0);
            break;
        case SDL_MOUSEWHEEL:
            if (captured && e.wheel.y)
                send_pkt(buttons, 0, 0, e.wheel.y > 0 ? 1 : -1);
            break;
        }
    }
    close(g_sock);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
