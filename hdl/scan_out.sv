// scan_out.sv — pix_clk-domain scan-out from the line buffer to the
// pix_r/g/b output. Pixel-doubles atari px → native px (320 atari →
// 640 native) and applies the line's HSCROL value as a read-address
// offset.
//
// At M4 there is no palette LUT; the line-buffer index byte drives
// pix_r=pix_g=pix_b directly so pixels show as 8-bit grayscale. M14
// adds the palette resolve.

`default_nettype none

module scan_out #(
    parameter int LB_RD_AW = 9        // 9 bits → addresses 0..511 atari px
) (
    input  wire        clk_pix,
    input  wire        rst,

    // Vbeam state.
    input  wire        in_active,
    input  wire        h_active,
    input  wire        hsync,
    input  wire        vsync,
    input  wire [11:0] h_count,

    // Per-row HSCROL (in atari pixels = colour clocks). For M4 always
    // 0 — the M5+ DL parser populates this.
    input  wire [3:0]  line_hscrol,

    // Line buffer read interface (we drive the address; data comes
    // back 1 cycle later).
    output logic [LB_RD_AW-1:0] lb_rd_addr,
    input  wire  [7:0]          lb_rd_data,

    // Pix output to TMDS encoder (or M3 stub: directly to pix_r/g/b).
    output logic [7:0] pix_r,
    output logic [7:0] pix_g,
    output logic [7:0] pix_b,
    output logic       pix_de,
    output logic       pix_hsync,
    output logic       pix_vsync
);

    // Pixel-double: atari_x = h_count >> 1. Add HSCROL offset.
    wire [LB_RD_AW-1:0] atari_x = h_count[LB_RD_AW:1] + {{(LB_RD_AW-4){1'b0}}, line_hscrol};

    // Drive the read address one cycle ahead so registered rd_data
    // lines up with the active pixel.
    assign lb_rd_addr = atari_x;

    // Register the timing signals to match the line-buffer's 1-cycle
    // read latency.
    logic in_active_q, hsync_q, vsync_q;
    always_ff @(posedge clk_pix or posedge rst) begin
        if (rst) begin
            in_active_q <= 1'b0;
            hsync_q     <= 1'b1;
            vsync_q     <= 1'b1;
        end else begin
            in_active_q <= in_active;
            hsync_q     <= hsync;
            vsync_q     <= vsync;
        end
    end

    // Output: index byte → grayscale (M4). Latched output for clean edges.
    always_ff @(posedge clk_pix or posedge rst) begin
        if (rst) begin
            pix_r <= 8'h00;
            pix_g <= 8'h00;
            pix_b <= 8'h00;
        end else begin
            if (in_active_q) begin
                pix_r <= lb_rd_data;
                pix_g <= lb_rd_data;
                pix_b <= lb_rd_data;
            end else begin
                pix_r <= 8'h00;
                pix_g <= 8'h00;
                pix_b <= 8'h00;
            end
        end
    end

    assign pix_de    = in_active_q;
    assign pix_hsync = hsync_q;
    assign pix_vsync = vsync_q;

endmodule

`default_nettype wire
