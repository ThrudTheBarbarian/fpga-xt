`default_nettype none
//
// antic_pm_dma — the player/missile fetch, from emu/antic.c:608 (`pm_dma`).
//
// emu does all five reads AT ONCE from line_start, because in a C model the
// slot a byte arrives in is unobservable.  It is observable here: the schedule
// already reserves the missile cycle (hcount 0) and the four player cycles
// (hcount 2..5) and charges the CPU for them, so this module fetches IN those
// cycles rather than bursting.  Same five bytes, same addresses, same line.
//
// THESE ARE NOT emu's PM_SLOT NUMBERS AND THAT IS DELIBERATE.  emu's
// `PM_SLOT_M = 2` / `PM_SLOT_P = 3` are where GTIA SAMPLES THE BUS for the
// phantom latch, not where ANTIC spends a cycle -- emu charges nothing for P/M
// at all.  antic2's slots come from ACID's own DMA maps.  The two never
// disagree in practice because the phantom only fires when player DMA is OFF,
// which is exactly when this module is not fetching.
//
// THE MISSILE FETCH FOLLOWS PLAYER DMA.  `missile = (dmactl & 0x04) || player`
// -- antic_pmdma sets DMACTL=$39 with bit 2 CLEAR, comments "enable only player
// DMA on ANTIC, and check that missiles still DMA", and then asserts on
// M0PL|M1PL.  Gating the missile on bit 2 alone fails that assertion.
//
// VDELAY IS NOT APPLIED HERE.  It belongs to GTIA, it is a one-fetch delay
// rather than a freeze, and gtia_reg_file owns both the register and the
// previous-fetch copy -- this module only says "this byte is a FETCH", via
// pm_fetch, so the store side knows to apply it.
//
`timescale 1ns/1ps

module antic_pm_dma (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,             // end of a machine cycle
    input  wire  [6:0] hcount,
    input  wire  [8:0] scanline,

    input  wire  [7:0] dmactl,
    input  wire  [7:0] pmbase,

    // ---- memory (mem_valid is mem_req delayed one FABRIC clock) -----------
    output logic [15:0] mem_addr,
    output logic        mem_req,
    input  wire  [7:0]  mem_data,
    input  wire         mem_valid,

    // ---- the shape store --------------------------------------------------
    output logic        pm_we,
    output logic [2:0]  pm_obj,          // 0 = missiles, 1..4 = players 0..3
    output logic [7:0]  pm_data
);

    // ---- who fetches this line --------------------------------------------
    wire player_en  = dmactl[3];
    wire missile_en = dmactl[2] || dmactl[3];
    wire one_line   = dmactl[4];

    // PMBASE BIT 2 IS DORMANT IN ONE-LINE RESOLUTION and antic_pmdma has an
    // assertion for exactly that: the one-line base masks $F8, the two-line
    // base masks $FC.  Carrying bit 2 into the one-line base moves every
    // player 256 bytes and the test names it.
    wire [15:0] base = one_line ? {pmbase[7:3], 11'd0}
                                : {pmbase[7:2], 10'd0};

    // One-line resolution indexes by the scanline; two-line by half of it,
    // which is why the same byte serves both scanlines of a pair -- and why
    // VDELAY's one-fetch delay shifts an object down a whole scanline without
    // breaking its two-line extent.
    wire [15:0] idx = one_line ? {8'd0, scanline[7:0]}
                               : {9'd0, scanline[7:1]};

    // ---- the slots ---------------------------------------------------------
    wire       slot_m = (hcount == 7'd0) && missile_en;
    wire       slot_p = (hcount >= 7'd2) && (hcount <= 7'd5) && player_en;
    wire [1:0] p_idx  = 2'(hcount - 7'd2);

    wire [15:0] m_addr = base + (one_line ? 16'h0300 : 16'h0180) + idx;
    wire [15:0] p_addr = base + (one_line ? 16'h0400 : 16'h0200) + idx +
                         (one_line ? {6'd0, p_idx, 8'd0}    // i * $100
                                   : {7'd0, p_idx, 7'd0});  // i * $80

    // ---- issue and collect -------------------------------------------------
    logic       inflight;
    logic [2:0] inflight_obj;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_req      <= 1'b0;
            mem_addr     <= 16'h0000;
            pm_we        <= 1'b0;
            pm_obj       <= 3'd0;
            pm_data      <= 8'h00;
            inflight     <= 1'b0;
            inflight_obj <= 3'd0;
        end else begin
            mem_req <= 1'b0;
            pm_we   <= 1'b0;

            if (tick && (slot_m || slot_p)) begin
                mem_req      <= 1'b1;
                mem_addr     <= slot_m ? m_addr : p_addr;
                inflight     <= 1'b1;
                inflight_obj <= slot_m ? 3'd0 : (3'd1 + {1'b0, p_idx});
            end

            // mem_req is registered and mem_valid is that delayed one more, so
            // the byte lands TWO clocks after the tick.  `inflight` therefore
            // cannot be cleared on the clock after the request -- that was bug
            // (d) the first time round.
            if (inflight && mem_valid) begin
                inflight <= 1'b0;
                pm_we    <= 1'b1;
                pm_obj   <= inflight_obj;
                pm_data  <= mem_data;
            end
        end
    end

endmodule

`default_nettype wire
