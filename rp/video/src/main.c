// rp_antic_video — main. Boots clocks, USB CDC, prints the banner,
// then hands off to the bus_server drain loop on core 0. Core 1 stays
// on the diagnostic / serial path.
//
// M0-RP ship criterion: UF2 flashes, USB CDC connects, banner prints,
// sys_clk reads back as the configured RP_VIDEO_SYS_HZ value.

#include <stdio.h>
#include <stdint.h>

#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "hardware/clocks.h"

#include "clock.h"
#include "bus_server.h"

static void print_banner(void) {
    const uint32_t sys_hz = clock_get_hz(clk_sys);
    printf("\n");
    printf("rp_antic_video — fpga-antic paired video memory\n");
    printf("clock: %s\n", clock_mode_label());
    printf("sys_clk read-back: %lu Hz\n", (unsigned long)sys_hz);
    printf("framebuffer: %u bytes (M3 stub)\n", (unsigned)FB_BYTES);
    printf("\n");
    fflush(stdout);
}

int main(void) {
    clock_init();
    stdio_init_all();

    // Generous USB-enumeration sleep — same value as rp-antic.
    sleep_ms(2000);

    print_banner();

    // Bring up the bus server. Currently a stub that idles core 0 and
    // returns; M3 wires up bus.pio + the FETCH/SET drain.
    bus_server_start();

    // Diagnostic loop on core 1's role (we're on core 0 here, but
    // bus_server_start kept its drain on core 1 once it lands).
    // Until M3 is in place, just print a heartbeat.
    uint32_t tick = 0;
    while (true) {
        sleep_ms(2000);
        printf("[heartbeat] tick=%lu fetch=%lu set=%lu draw=%lu bad_tag=%lu set_misalign=%lu\n",
               (unsigned long)tick++,
               (unsigned long)bus_server_stats.fetch_count,
               (unsigned long)bus_server_stats.set_count,
               (unsigned long)bus_server_stats.draw_count,
               (unsigned long)bus_server_stats.bad_tag_count,
               (unsigned long)bus_server_stats.set_misalign_count);
    }
}
