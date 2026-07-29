`default_nettype none
//
// gtia_stream — BEAM-TIME GTIA pixel stage.
//
// docs/video/gtia-streaming.md. This is the pixel half of the streaming GTIA;
// gtia_pm_collide is the collision half, and this module consumes the
// per-colour-clock presence that walk already produces rather than deriving it
// a second time.
//
// What it replaces
// ----------------
// Today the burst compositor decides a whole row's playfield pixels, P/M
// overlay AND colour at one instant, so a register written partway along a line
// cannot affect that line at all. Every ACID800 render failure is that shape:
// pfstarttiming, pfstoptiming, hscrolbug, charcontrol, linebuffering, and the
// GTIA group. Each was previously chased with a per-register bolt-on
// (early/chg_x for SIZEP, again for HPOSP), which is a reconstruction of beam
// time rather than beam time.
//
// Here the question never arises: every colour clock resolves against whatever
// the registers hold at that colour clock.
//
// Cost
// ----
// A colour clock is 3.579545 MHz against clk_sys at 133.3 MHz — 37 clk_sys per
// colour clock. This is nowhere near a hot path, while the burst it replaces
// IS the measured clk_sys limiter (display_shadow BRAM -> pack_pair -> overlay
// -> cmd_data, 8 logic levels, 8.354ns against a 7.5ns budget). Moving the
// pixel path to beam time REMOVES a critical path.
//
// Scope
// -----
// Takes the playfield nibble for the colour clock as an input. The mode decode
// that produces it (pack_pair's sixteen modes, HSCROL windowing, char modes)
// migrates into the ANTIC streaming stage, which now emits the playfield byte
// stream (antic_timing pf_valid/pf_byte/pf_code). Keeping that boundary means
// this module is independently testable and the decode moves in one piece.
//
`timescale 1ns/1ps

module gtia_stream (
    input  wire        clk,           // clk_bus
    input  wire        rst,

    // ---- beam ------------------------------------------------------------
    input  wire        cc_valid,      // 1-clk: a colour clock is being resolved
    input  wire [8:0]  cc_index,      // colour clock within the line (0..227)

    // ---- playfield source (from the ANTIC streaming stage) ---------------
    // One-hot PF0..PF3 for this colour clock; 0 = background.
    input  wire [3:0]  pf_nibble,

    // ---- P/M presence (from gtia_pm_collide's shift-register walk) -------
    input  wire [7:0]  pm_presence,   // {P3,P2,P1,P0,M3,M2,M1,M0}

    // ---- live GTIA registers (sampled AT this colour clock) --------------
    input  wire [7:0]  prior,
    input  wire [7:0]  colpm0, colpm1, colpm2, colpm3,
    input  wire [7:0]  colpf0, colpf1, colpf2, colpf3,
    input  wire [7:0]  colbk,
    input  wire        colpf1_luma_only,

    // ---- pixel out -------------------------------------------------------
    output logic [7:0] color_out,     // Atari hue:luma
    output logic       color_valid,
    output logic [8:0] color_cc       // which colour clock it belongs to
);

    // idx_buf contract (color_resolver, rp-antic convention):
    //   [3:0]  PF0..PF3, at most one set
    //   [7:4]  P|M shared — the player slot with its missile OR'd in
    //   [11:8] M0..M3 only, so PM5 can strip the missile back out
    wire [3:0] m_only  = pm_presence[3:0];
    wire [3:0] p_share = pm_presence[7:4] | m_only;
    wire [11:0] idx_buf = {m_only, p_share, pf_nibble};

    wire [7:0] resolved;
    color_resolver u_res (
        .idx_buf (idx_buf),
        .prior   (prior),
        .colpm0  (colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .colpf0  (colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colbk   (colbk),
        .colpf1_luma_only (colpf1_luma_only),
        .color_out (resolved)
    );

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            color_out   <= 8'h00;
            color_valid <= 1'b0;
            color_cc    <= 9'd0;
        end else begin
            color_valid <= cc_valid;
            if (cc_valid) begin
                color_out <= resolved;
                color_cc  <= cc_index;
            end
        end
    end

endmodule

`default_nettype wire
