#pragma once

#include <stdint.h>

// FPGA<->RP bus server. Drains FETCH / SET / DRAW opcodes from the
// bus PIO and services them out of the framebuffer.
//
// Wire format: see ../../docs/wire-protocol.md § "FPGA<->RP bus".
//
// Bus opcode tag values (2 bits, packed into payload[25:24] on the
// 27-wire FPGA->RP bus). MUST match hdl/bus_opcodes.vh — the
// rp/sim/Makefile `verify` target greps both files and diffs the
// decimal values.
#define BUS_TAG_FETCH 0
#define BUS_TAG_SET   1
#define BUS_TAG_DRAW  2
#define BUS_TAG_NOP   3

// DRAW opcodes (the value carried in DRAW-beat-0's payload[7:0]).
// MUST match hdl/bus_opcodes.vh — the verify target also cross-checks
// these.
//
// op[7] is the fill flag. 0 = outline, 1 = filled. Applies to paired
// closed-shape primitives (RECT today; OVAL / ARC at M18). For
// unpaired ops (NOP, LINE, FILL, BEZIER) op[7] is reserved.
//
// FILL is the flood-fill primitive (paint-bucket: seed point + new
// colour); it is NOT "RECT with op[7]=1".
#define BUS_DRAW_FILL_FLAG 0x80   /* OR-in to a paired base op */
#define BUS_DRAW_OP_NOP       0   /* 1 beat                                 */
#define BUS_DRAW_OP_LINE      1   /* 5 beats                                */
#define BUS_DRAW_OP_RECT      2   /* 5 beats — outline / | 0x80 = filled    */
#define BUS_DRAW_OP_FILL      3   /* 3 beats — flood-fill                   */
#define BUS_DRAW_OP_OVAL      4   /* M18  — 5 beats / | 0x80 = filled       */
#define BUS_DRAW_OP_ARC       5   /* M18  — 7 beats / | 0x80 = PIE          */
#define BUS_DRAW_OP_BEZIER    6   /* M18.1 — 9 beats, cubic, 4 ctl points   */
#define BUS_DRAW_OP_BEZIER_TO 7   /* M18.1 — 7 beats, chains onto previous  */

// Provisional framebuffer size for the bring-up milestone. M3
// allocates a 256 KB stub in PSRAM/SRAM (enough for 640×240 indexed
// at 1 bpp + slack); production sizes follow at M21.
#define FB_BYTES (256u * 1024u)

// Diagnostic counters published over USB CDC at startup.
typedef struct {
    uint32_t fetch_count;        // FETCH opcodes serviced
    uint32_t set_count;          // SET opcodes serviced
    uint32_t draw_count;         // DRAW opcodes executed (per-op breakdown in draw_ctx)
    uint32_t bad_tag_count;      // unrecognised tag value
    uint32_t set_misalign_count; // SET addr[0] != 0
} bus_server_stats_t;

extern volatile bus_server_stats_t bus_server_stats;

// Returns once core 0 has been launched into the drain loop.
// (Caller stays on core 1 for the diagnostic / serial path.)
void bus_server_start(void);
