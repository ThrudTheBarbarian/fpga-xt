// antic_raster.sv — ANTIC native raster timer (phi2-paced).
//
// docs/video/video-architecture.md §5.1.  Replaces the legacy
// 800×600 hdmi_out `vbeam` that antic_top used as a raster *heartbeat*.  That
// vbeam was clocked by the 148 MHz pixel clock carrying VESA 800×600 timing,
// so ANTIC's frame/line/NMI cadence ran at ~224 Hz and was NOT locked to phi2
// — wrong for the emulation (the OS times off VBI/RTCLOK, VCOUNT, WSYNC).
//
// This timer is paced by `phi2_tick` (one pulse per ANTIC machine cycle), so
// the raster is locked to the CPU exactly like real ANTIC:
//
//   scanline = CYC_PER_LINE machine cycles      (NTSC/PAL: 114)
//   frame    = LINES_PER_FRAME scanlines        (NTSC: 262, PAL: 312)
//   VCOUNT   = scanline >> 1                     (Atari $D40B granularity)
//   VBI NMI  = at scanline VBI_LINE              (NTSC: 248)
//   playfield rows = scanlines [DISPLAY_TOP, DISPLAY_TOP+ACTIVE_LINES)
//
// It produces the same nets antic_top previously sourced from the vbeam CDC
// (atari_row / line_start / vbi_start / vcount) plus `phi2_in_line` for the
// WSYNC cycle-105 release (which the old 140 kHz line_start broke — the
// counter never reached 105 between resets; this fixes it).
//
// All clk_bus domain — no CDC, unlike the old clk_pix→clk_bus vbeam path.

`default_nettype none

module antic_raster #(
    parameter int CYC_PER_LINE    = 114,   // machine cycles per scanline
    parameter int LINES_PER_FRAME = 262,   // NTSC 262 / PAL 312
    parameter int DISPLAY_TOP     = 8,     // first playfield scanline
    parameter int ACTIVE_LINES    = 192,   // playfield rows (atari_row 0..N-1)
    parameter int VBI_LINE        = 248    // scanline where the VBI NMI fires
) (
    input  wire        clk,            // clk_bus
    input  wire        rst,
    input  wire        phi2_tick,      // 1-cycle pulse per ANTIC machine cycle

    output reg  [8:0]  scanline,       // 0..LINES_PER_FRAME-1
    output reg  [7:0]  phi2_in_line,   // machine cycle within the line (0..CYC_PER_LINE-1)
    output wire        line_start,     // 1-cycle pulse at the start of each scanline
    output wire        vbi_start,      // 1-cycle pulse at the start of vertical blank
    output wire [7:0]  atari_row,      // playfield row, or 0xFF outside the active band
    output wire [7:0]  vcount          // Atari VCOUNT = scanline >> 1
);

    // ---- Machine-cycle / scanline counters ------------------------------
    // phi2_in_line counts 0..CYC_PER_LINE-1; at the last cycle the line
    // completes (line_tick) and scanline advances, wrapping per frame.
    wire line_tick = phi2_tick && (phi2_in_line == 8'(CYC_PER_LINE - 1));

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            phi2_in_line <= 8'd0;
            scanline     <= 9'd0;
        end else if (phi2_tick) begin
            if (phi2_in_line == 8'(CYC_PER_LINE - 1)) begin
                phi2_in_line <= 8'd0;
                scanline     <= (scanline == 9'(LINES_PER_FRAME - 1)) ? 9'd0
                                                                      : scanline + 9'd1;
            end else begin
                phi2_in_line <= phi2_in_line + 8'd1;
            end
        end
    end

    // ---- Line/frame boundary pulses -------------------------------------
    // Registered one cycle after line_tick so `scanline` has settled to the
    // NEW line when the pulse is observed (keeps atari_row/vbi aligned with
    // line_start for the consumers).
    reg new_line;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) new_line <= 1'b0;
        else     new_line <= line_tick;
    end

    assign line_start = new_line;
    assign vbi_start  = new_line && (scanline == 9'(VBI_LINE));

    // ---- Derived row / VCOUNT (combinational from scanline) -------------
    wire in_active = (scanline >= 9'(DISPLAY_TOP))
                  && (scanline <  9'(DISPLAY_TOP + ACTIVE_LINES));
    assign atari_row = in_active ? 8'(scanline - 9'(DISPLAY_TOP)) : 8'hFF;

    // VCOUNT LEADS the physical scanline: on real ANTIC the vertical counter
    // ($D40B = scanline>>1) advances to the NEXT value at machine cycle
    // VCOUNT_INC_CYC, a few cycles before the scanline itself advances at
    // line_tick (cycle 113).  A CPU read of $D40B late in the line therefore
    // sees the next value (ACID800 antic_vcount).  Only correct once the CPU is
    // phi2-locked to ANTIC (single-phi2) — the read has to land on ANTIC's grid.
    //
    // The lead must NOT wrap on the final scanline.  On the last line the leading
    // counter reaches LINES_PER_FRAME>>1 — NTSC (262): 131, PAL (312): 156 — and
    // only drops to 0 when the frame itself wraps at line_tick.  ACID800
    // antic_vcount asserts exactly those two values ("VCOUNT rollover #1"), so
    // special-casing the last line to 0 here made the test spin forever waiting
    // for a 131 that never arrived.  scanline+1 is 262/312 max, which still fits
    // the 9-bit width, so the plain increment is safe.
    //
    // Pinned EMPIRICALLY, and uniquely determined — do not "correct" this against
    // the Altirra manual's absolute cycle numbers.  Our phi2_in_line origin is
    // offset from ANTIC's documented cycle numbering, so matching 109-110 by name
    // is wrong; what matters is where OUR reads land.  Measured on HW with the
    // DBG_TB read probe (mode 2, $D40B) during ACID800 antic_vcount, whose four
    // reads expect $01,$02,$03,$03:
    //   read #1  scanline 3 @ phi2 111  expects $01 = OLD  ->  INC_CYC >  111
    //   read #3  scanline 5 @ phi2 112  expects $03 = NEW  ->  INC_CYC <= 112
    // (#2 and #4 land on scanlines where old and new agree, so they add nothing.)
    // The two bounds intersect at exactly one value.
    localparam int unsigned VCOUNT_INC_CYC = 112;
    // Frame wrap is ONE CYCLE WIDE, at the very last cycle of the last line.
    // Measured (DBG_TB mode 2, antic_vcount rollover): on scanline 261 the
    // leading counter reads 131 at phi2 112 (rollover #1 expects 131) and must
    // read 0 at phi2 113 (rollover #2 expects 0).  So the lead runs normally at
    // 112 even on the final line, and only the last cycle wraps.  Wrapping the
    // whole lead window (or never wrapping) each satisfies one assertion and
    // breaks the other.
    wire last_line = (scanline == 9'(LINES_PER_FRAME - 1));
    wire [8:0] vcount_scan =
          (last_line && (phi2_in_line >= 8'(CYC_PER_LINE - 1))) ? 9'd0
        : (phi2_in_line >= 8'(VCOUNT_INC_CYC))                  ? (scanline + 9'd1)
        :                                                         scanline;
    assign vcount    = vcount_scan[8:1];

endmodule

`default_nettype wire
