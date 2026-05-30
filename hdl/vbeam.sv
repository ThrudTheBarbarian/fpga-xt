// vbeam.sv — pix_clk-domain horizontal/vertical counters and sync
// generation. Fully parameterised raster timing (active size, porches,
// sync widths, polarity), so it serves any CEA-861/VESA mode.
//
// The top-level instantiates it at 1920×1080@60 CEA-861 (see
// fpga_xt_top.sv); HDMI scan-out is always 1080p60. ($D482 OUTPUT_MODE
// selects the compositing mode, not the raster size.)
//
// Atari-row mapping (ANTIC-compat): the active ANTIC band of
// ANTIC_LINES_NATIVE native lines starts after a top letterbox of
// (V_ACTIVE - ANTIC_LINES_NATIVE)/2 lines and runs line-doubled; the
// atari_row output gives the ANTIC line for the current native scan
// line, or 0xFFFF during letterbox / blanking.

`default_nettype none

module vbeam #(
    // Default parameters: 640×480@60 VESA timing.
    parameter int H_ACTIVE      = 640,
    parameter int H_FRONT_PORCH = 16,
    parameter int H_SYNC_WIDTH  = 96,
    parameter int H_BACK_PORCH  = 48,
    parameter int V_ACTIVE      = 480,
    parameter int V_FRONT_PORCH = 10,
    parameter int V_SYNC_WIDTH  = 2,
    parameter int V_BACK_PORCH  = 33,

    // ANTIC active region (after line-doubling).
    parameter int ANTIC_LINES_NATIVE = 384,   // 192 atari rows × 2

    // Polarity (1 = active low, VESA standard).
    parameter bit HSYNC_ACTIVE_LOW = 1'b1,
    parameter bit VSYNC_ACTIVE_LOW = 1'b1
) (
    input  wire        clk_pix,
    input  wire        rst,

    output logic [11:0] h_count,        // 0..H_TOTAL-1
    output logic [11:0] v_count,        // 0..V_TOTAL-1
    output logic        in_active,      // h_count < H_ACTIVE && v_count < V_ACTIVE
    output logic        h_active,
    output logic        v_active,
    output logic        hsync,
    output logic        vsync,
    output logic        de,             // = in_active

    // Per-frame events for downstream consumers.
    output logic        line_start,     // pulses on the cycle h_count rolls to 0
    output logic        frame_start,    // pulses on the cycle v_count rolls to 0
    output logic        vbi_start,      // pulses on entry to vertical blank

    // Atari mapping: 0..191 inside the active band, 16'hFFFF outside.
    output logic [15:0] atari_row,
    // VCOUNT register exposure (rp-XT spec: 8-bit, granularity = 2 scan
    // lines, so atari_row[8:1] in the active band).
    output logic [7:0]  vcount
);

    localparam int H_TOTAL = H_ACTIVE + H_FRONT_PORCH + H_SYNC_WIDTH + H_BACK_PORCH;
    localparam int V_TOTAL = V_ACTIVE + V_FRONT_PORCH + V_SYNC_WIDTH + V_BACK_PORCH;
    localparam int LETTERBOX_TOP = (V_ACTIVE - ANTIC_LINES_NATIVE) / 2;
    localparam int ANTIC_BAND_END = LETTERBOX_TOP + ANTIC_LINES_NATIVE;

    // ---- Counters -------------------------------------------------------
    always_ff @(posedge clk_pix or posedge rst) begin
        if (rst) begin
            h_count <= 12'd0;
            v_count <= 12'd0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= 12'd0;
                if (v_count == V_TOTAL - 1) v_count <= 12'd0;
                else                         v_count <= v_count + 12'd1;
            end else begin
                h_count <= h_count + 12'd1;
            end
        end
    end

    // ---- Active / sync ---------------------------------------------------
    logic h_in_sync, v_in_sync;
    always_comb begin
        h_active = (h_count < H_ACTIVE);
        v_active = (v_count < V_ACTIVE);
        in_active = h_active & v_active;
        de = in_active;

        // HSYNC pulse runs from H_ACTIVE+H_FRONT_PORCH for H_SYNC_WIDTH cycles.
        h_in_sync = (h_count >= H_ACTIVE + H_FRONT_PORCH) &
                    (h_count <  H_ACTIVE + H_FRONT_PORCH + H_SYNC_WIDTH);
        hsync = HSYNC_ACTIVE_LOW ? ~h_in_sync : h_in_sync;

        // VSYNC pulse runs from V_ACTIVE+V_FRONT_PORCH for V_SYNC_WIDTH lines.
        v_in_sync = (v_count >= V_ACTIVE + V_FRONT_PORCH) &
                    (v_count <  V_ACTIVE + V_FRONT_PORCH + V_SYNC_WIDTH);
        vsync = VSYNC_ACTIVE_LOW ? ~v_in_sync : v_in_sync;
    end

    // ---- Edge events -----------------------------------------------------
    always_ff @(posedge clk_pix or posedge rst) begin
        if (rst) begin
            line_start  <= 1'b0;
            frame_start <= 1'b0;
            vbi_start   <= 1'b0;
        end else begin
            line_start  <= (h_count == H_TOTAL - 1);
            frame_start <= (h_count == H_TOTAL - 1) && (v_count == V_TOTAL - 1);
            vbi_start   <= (h_count == H_TOTAL - 1) && (v_count == V_ACTIVE - 1);
        end
    end

    // ---- Atari mapping ---------------------------------------------------
    localparam logic [11:0] LETTERBOX_TOP_W  = 12'(LETTERBOX_TOP);
    localparam logic [11:0] ANTIC_BAND_END_W = 12'(ANTIC_BAND_END);
    always_comb begin
        if (v_count >= LETTERBOX_TOP_W && v_count < ANTIC_BAND_END_W) begin
            atari_row = {4'h0, v_count - LETTERBOX_TOP_W} >> 1;   // line-doubled
        end else begin
            atari_row = 16'hFFFF;
        end
        // VCOUNT: granularity 2 scan lines per real ANTIC. Use bits [8:1]
        // of atari_row when in the active band, else 0xFF (blanking).
        vcount = (atari_row == 16'hFFFF) ? 8'hFF : atari_row[8:1];
    end

endmodule

`default_nettype wire
