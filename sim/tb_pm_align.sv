`timescale 1ns/1ps
`default_nettype none
//
// tb_pm_align — WHERE DOES A PLAYER LAND, RELATIVE TO THE PLAYFIELD?
//
// Simon sees BallBlazer's man overlapping the vehicle on one side and standing
// clear of it on the other, and the captured frames agree: our P/M sits LEFT of
// the reference relative to the playfield.  Comparing game frames cannot pin the
// SIZE of that -- the character is walking, so its position confounds any
// measurement.  This does it with a ruler instead.
//
// The suspect is one line, hdl/a2_video.sv:216:
//
//     wire [7:0] cc_pos = px_pos[8:1] - 8'd1;
//
// The base counter is NOT in doubt: tb_antic2_pxpos proves px_pos == hcount*4+k
// over 1820 pixels.  What is in doubt is that deliberate -1, which compensates
// for the playfield pair being captured a clock late.  It reads as
// self-consistent either way, so only a measurement decides it.
//
// THE RULER IS ANTIC MODE F.  A hi-res byte is 8 pixels, so a screen of
// $00 bytes followed by $FF bytes puts a playfield edge on a KNOWN HI-RES
// PIXEL -- half a colour clock, the finest ruler the chip has.  Park a player
// so that it should start exactly ON that edge; then the emitted scanline
// answers directly, and a one-colour-clock error shows up as 2 pixels.
//
// Nothing here is synthesised from the testbench's own idea of the beam: the
// pixel stream, px_pos and cc_pos all come from the REAL antic2/a2_video pair
// (antic2_fabric, the live synthesised module), which is exactly why this can
// see a misalignment that tb_gtia_stage cannot -- that bench sets
// cc_pos = 8'(cc) from the same counter it indexes the playfield with, so it
// DEFINES them as aligned.
//
module tb_pm_align;

    localparam int PHASES = 56;                  // tb_acid's generator
    localparam int PXSTEP = PHASES / 4;

    // ---- the scene --------------------------------------------------------
    localparam [15:0] DLIST  = 16'h3000;
    localparam [15:0] SCREEN = 16'h4000;
    localparam int    EDGEB  = 10;               // first $FF byte -> edge at px 80
    localparam int    EDGEPX = EDGEB * 8;
    // A player parked so its left edge SHOULD fall exactly on the playfield
    // edge: playfield px 0 is HPOS 48, and a player at HPOS h starts at
    // hi-res px (h-48)*2, so h = 48 + EDGEPX/2.
    localparam [7:0]  HPOS_P0 = 8'(48 + EDGEPX/2);

    // mode F lit = COLPF2's HUE with COLPF1's LUMA, so the lit colour is $6A.
    localparam [7:0] C_BK = 8'h00, C_PF1 = 8'h0A, C_PF2 = 8'h60,
                     C_LIT = 8'h6A, C_PM0 = 8'h3A;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [5:0] phase = 6'd0;
    logic       tick, px_tick;
    always_ff @(posedge clk) begin
        phase   <= (phase == 6'(PHASES-1)) ? 6'd0 : phase + 6'd1;
        tick    <= (phase == 6'(PHASES-1));
        px_tick <= (phase == 6'(PXSTEP-1))   || (phase == 6'(2*PXSTEP-1)) ||
                   (phase == 6'(3*PXSTEP-1)) || (phase == 6'(4*PXSTEP-1));
    end

    // ---- memory: display list + screen ------------------------------------
    logic [7:0] mem [0:65535];
    wire [15:0] mem_addr;
    logic [7:0] mem_data;
    always_ff @(posedge clk) mem_data <= mem[mem_addr];

    // ---- CPU bus ----------------------------------------------------------
    logic       cs_antic = 0, cs_gtia = 0, we = 0;
    logic [7:0] addr = 8'h00, wdata = 8'h00;

    wire        lb_wr, lb_line_start;
    wire [7:0]  lb_color;
    wire [8:0]  line;

    antic2_fabric dut (
        .clk(clk), .rst(rst), .cold(1'b0), .tick(tick), .px_tick(px_tick),
        .cs_antic(cs_antic), .cs_gtia(cs_gtia), .addr(addr), .we(we),
        .cpu_writing(we), .wdata(wdata), .rdata(),
        .rdy_n(), .nmi_n(), .dma_steal(),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .bus_byte(8'h00), .bus_byte_stb(1'b0),
        .trig0(8'hFF), .trig1(8'hFF), .trig2(8'hFF), .trig3(8'hFF),
        .pal_sense(8'h0F), .consol_keys(8'h07), .tune(16'h0000),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .hcount(), .line(line), .vcount(), .nmist_o()
    );

    task automatic wr_antic(input [7:0] a, input [7:0] d);
        @(posedge clk); cs_antic <= 1; we <= 1; addr <= a; wdata <= d;
        @(posedge clk); cs_antic <= 0; we <= 0;
    endtask
    task automatic wr_gtia(input [7:0] a, input [7:0] d);
        @(posedge clk); cs_gtia <= 1; we <= 1; addr <= a; wdata <= d;
        @(posedge clk); cs_gtia <= 0; we <= 0;
    endtask

    // ---- capture one display scanline -------------------------------------
    logic [7:0] pix [0:511];
    int         npix = 0;
    logic       capture = 0;
    always_ff @(posedge clk) begin
        if (lb_line_start && capture) npix <= 0;
        else if (lb_wr && capture && npix < 512) begin
            pix[npix] <= lb_color;
            npix      <= npix + 1;
        end
    end

    int i, edge_px, pm_px, first_pf;
    logic [7:0] prior_val;
    int pass;
    initial begin
        // ---- scene ---------------------------------------------------------
        for (i = 0; i < 65536; i++) mem[i] = 8'h00;
        // 3 blank-line instructions, LMS mode F, then plain mode F, then JVB
        mem[DLIST+0] = 8'h70; mem[DLIST+1] = 8'h70; mem[DLIST+2] = 8'h70;
        mem[DLIST+3] = 8'h4F;
        mem[DLIST+4] = SCREEN[7:0]; mem[DLIST+5] = SCREEN[15:8];
        for (i = 0; i < 40; i++) mem[DLIST+6+i] = 8'h0F;
        mem[DLIST+46] = 8'h41;
        mem[DLIST+47] = DLIST[7:0]; mem[DLIST+48] = DLIST[15:8];
        // screen: $00 up to EDGEB, then $FF -- a playfield edge at EDGEPX
        for (i = 0; i < 40*30; i++)
            mem[SCREEN+i] = ((i % 40) >= EDGEB) ? 8'hFF : 8'h00;

        repeat (5) @(posedge clk);
        rst = 0;
        repeat (20) @(posedge clk);

      for (pass = 0; pass < 4; pass++) begin
        // pass 0: ordinary playfield (PRIOR $01).  pass 1: GTIA MODE 9
        // ($41) -- BallBlazer's mode, where the nibble takes two colour
        // clocks to assemble and priority reads `gtia_nib`, a pair later.
        prior_val = (pass < 2) ? 8'h01 : 8'h41;
        $display("");
        $display("=== pass %0d: PRIOR $%02h %s, player %s ===", pass, prior_val,
                 (pass < 2) ? "ordinary" : "GTIA MODE 9",
                 (pass % 2 == 0) ? "OFF (locate the edge)" : "ON");

        wr_gtia(8'h1B, prior_val);      // PRIOR (set per pass)
        wr_gtia(8'h1A, (pass < 2) ? C_BK : 8'h60);  // COLBK (mode 9: the HUE)
        wr_gtia(8'h17, C_PF1);          // COLPF1 luma
        wr_gtia(8'h18, C_PF2);          // COLPF2 hue
        wr_gtia(8'h12, C_PM0);          // COLPM0
        wr_gtia(8'h08, 8'h00);          // SIZEP0 normal
        wr_gtia(8'h0D, (pass % 2 == 0) ? 8'h00 : 8'hFF);  // GRAFP0
        wr_gtia(8'h1D, 8'h00);          // GRACTL: no P/M DMA, GRAFP stands
        wr_gtia(8'h00, HPOS_P0);        // HPOSP0
        wr_antic(8'h02, DLIST[7:0]);    // DLISTL
        wr_antic(8'h03, DLIST[15:8]);   // DLISTH
        wr_antic(8'h00, 8'h22);         // DMACTL: normal width + DL DMA

        // let the beam reach a settled display line, then capture one
        wait (line == 9'd40);
        @(posedge clk); capture <= 1;
        wait (line == 9'd42);
        @(posedge clk); capture <= 0;

        // ---- read the ruler ------------------------------------------------
        edge_px  = -1; pm_px = -1; first_pf = -1;
        for (i = 0; i < npix; i++) begin
            if (pix[i] != C_BK && pix[i] != C_PM0 && edge_px < 0) edge_px = i;
            if (pix[i] == C_PM0 && pm_px   < 0) pm_px   = i;
        end
        $display("tb_pm_align: captured %0d pixels of line", npix);
        $display("  playfield edge (first non-background) at emitted px %0d", edge_px);
        begin : dump
            int r; logic [7:0] c;
            r = 0; c = pix[0];
            for (i = 1; i <= npix; i++) begin
                if (i == npix || pix[i] !== c) begin
                    if (c !== C_BK)
                        $display("    run: px %0d..%0d colour $%02h (len %0d)", r, i-1, c, i-r);
                    if (i < npix) begin r = i; c = pix[i]; end
                end
            end
        end
        $display("  player left    (first COLPM0) at emitted px %0d", pm_px);
        if (edge_px >= 0 && pm_px >= 0) begin
            $display("  player - edge = %0d   (0 = aligned, +/-2 = ONE COLOUR CLOCK)", pm_px - edge_px);
            if (pm_px - edge_px == 0)
                $display("tb_pm_align: ALIGNED -- no P/M-vs-playfield offset");
            else
                $display("tb_pm_align: OFFSET of %0d hi-res px = %0d colour clocks",
                         pm_px - edge_px, (pm_px - edge_px) / 2);
        end else begin
            $display("tb_pm_align: INCONCLUSIVE -- edge=%0d pm=%0d", edge_px, pm_px);
        end
      end
        $finish;
    end

endmodule

`default_nettype wire
