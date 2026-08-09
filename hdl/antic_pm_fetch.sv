`default_nettype none
//
// antic_pm_fetch — player/missile DMA.
//
// docs/ANTIC-rewrite.md step 5.  Five bytes per scanline: one missile byte
// holding all four missiles two bits each, then the four player shape bytes.
// They are fetched at the start of the line, before anything needs them, which
// is what "hoist the P/M fetch to line start" means — the old design fetched
// them where the compositor happened to want them and could not then satisfy
// antic_pmdma or gtia_phantomdma.
//
// P/M DMA WRITES THE SAME REGISTERS THE CPU DOES.  GRAFM and GRAFP0-3 have one
// copy each; DMA stores into them and a CPU write stores into them, and whoever
// wrote last wins.  That is why disabling P/M DMA leaves the last shape on
// screen and why gtia_phantomdma has anything to test.  So this module does not
// hold the shapes — it emits a store strobe and the register file takes it.
//
// ONE ADDRESS FORMULA, not two.  The resolution bit only changes a shift:
//
//     region = 3 + object     (3 = missiles, 4..7 = players 0..3)
//     one-line:  addr = base + (region << 8) + scanline
//     two-line:  addr = base + (region << 7) + (scanline >> 1)
//
// which lands missiles at +$300 and players at +$400/$500/$600/$700 in one-line
// resolution, and at +$180 and +$200/$280/$300/$380 in two-line — the documented
// layout, from one adder and a mux.  Writing it as two tables would be the
// smell.  The base is 2K-aligned in one-line resolution and 1K-aligned in
// two-line, which is exactly which bits of PMBASE are significant.
//
// In two-line resolution the index is the scanline halved and each region is 128
// bytes, so a 262-line frame runs slightly past the end of a region.  Real
// hardware does the same; it is not special-cased away.
//
// VDELAY IS A WRITE MASK, and that is the whole of it.  In two-line resolution
// both scanlines of a pair fetch the same byte, so an object whose store is
// inhibited on EVEN scanlines only changes on the odd one — which is the object
// appearing one scanline lower.  One gate.
//
// It has to be a mask rather than a store enable because the single missile byte
// carries four missiles with four independent delay bits: missile 0 may be
// delayed while missile 1 is not, and they share a register.  So the fetcher
// emits a per-bit mask alongside the data and the register file merges,
// which also keeps GRAFM one register as the CPU sees it.  For a player the mask
// is all or nothing.
//
// In ONE-line resolution consecutive scanlines fetch DIFFERENT bytes, so the
// same gate drops half the updates instead of delaying by a line.  That is not a
// special case being tolerated — it is what the hardware does with the same
// circuit, and why VDELAY is documented as a two-line-resolution feature.
//
// CLOCK BUDGET: 2 clocks per fetch, 5 fetches — 10 fabric clocks at the very
// start of a scanline, out of ~6,300.
//
`timescale 1ns/1ps

module antic_pm_fetch (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,          // 1-clk: line_start
    input  wire [8:0]  line,           // scanline within the frame

    // ---- live registers --------------------------------------------------
    input  wire [7:0]  pmbase,         // $D407
    input  wire        player_dma_en,  // DMACTL[3]
    input  wire        missile_dma_en, // DMACTL[2]
    input  wire        res_1line,      // DMACTL[4]
    input  wire [7:0]  vdelay,         // $D01C: [3:0] missiles, [7:4] players

    // ---- memory ----------------------------------------------------------
    output logic [15:0] mem_addr,
    input  wire  [7:0]  mem_data,

    // ---- stores into GRAFM / GRAFP0-3 ------------------------------------
    output logic        pm_we,         // 1-clk
    output logic [2:0]  pm_obj,        // 0 = missiles, 1..4 = players 0..3
    output logic [7:0]  pm_data,
    output logic [7:0]  pm_mask,       // which bits VDELAY lets through

    output logic        busy,
    output logic        done            // 1-clk when the line's fetches are in
);

    // ---- the address -----------------------------------------------------
    logic [2:0] obj;                    // 0 = missiles, 1..4 = players

    wire [2:0]  region = 3'd3 + obj;

    wire [15:0] pm_base = res_1line ? {pmbase[7:3], 11'h000}
                                    : {pmbase[7:2], 10'h000};
    wire [7:0]  idx     = res_1line ? line[7:0] : line[8:1];
    wire [15:0] obj_off = res_1line ? {5'd0, region, 8'd0}
                                    : {6'd0, region, 7'd0};

    assign mem_addr = pm_base + obj_off + {8'd0, idx};

    // Missiles and players are enabled separately, and a disabled object is
    // simply not fetched — its register keeps whatever the CPU last wrote.
    wire obj_enabled = (obj == 3'd0) ? missile_dma_en : player_dma_en;

    // VDELAY inhibits the store on even scanlines.  A player is all or nothing;
    // the missile byte is masked two bits at a time, because its four missiles
    // have four independent delay bits and share one register.
    wire odd_line = line[0];

    logic [7:0] vd_mask;
    always_comb begin
        if (obj == 3'd0) begin
            for (int k = 0; k < 4; k++)
                vd_mask[k*2 +: 2] = (!vdelay[k] || odd_line) ? 2'b11 : 2'b00;
        end else begin
            vd_mask = (!vdelay[3 + obj] || odd_line) ? 8'hFF : 8'h00;
        end
    end

    // ---- the walk --------------------------------------------------------
    typedef enum logic [1:0] { S_IDLE, S_ADDR, S_DATA, S_DONE } state_t;
    state_t state;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= S_IDLE;
            obj     <= 3'd0;
            pm_we   <= 1'b0;
            pm_obj  <= 3'd0;
            pm_data <= 8'h00;
            pm_mask <= 8'h00;
            busy    <= 1'b0;
            done    <= 1'b0;
        end else begin
            pm_we <= 1'b0;
            done  <= 1'b0;

            if (start) begin
                obj   <= 3'd0;
                busy  <= 1'b1;
                state <= S_ADDR;
            end else
            case (state)
                S_IDLE: busy <= 1'b0;

                S_ADDR: state <= S_DATA;

                S_DATA: begin
                    if (obj_enabled) begin
                        pm_we   <= 1'b1;
                        pm_obj  <= obj;
                        pm_data <= mem_data;
                        pm_mask <= vd_mask;
                    end
                    if (obj == 3'd4) begin
                        state <= S_DONE;
                    end else begin
                        obj   <= obj + 3'd1;
                        state <= S_ADDR;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
