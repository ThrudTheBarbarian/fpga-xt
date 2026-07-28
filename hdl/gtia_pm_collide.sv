`default_nettype none
//
// gtia_pm_collide — BEAM-TIME player/missile collision detection.
//
// Why this exists
// ---------------
// The compositor renders a scanline as a single burst, and derives collisions
// from a sweep inside that burst. That is fine for a program that reads the
// collision registers a whole scanline or more after the fact, but it cannot
// model the real chip for anything finer: on silicon GTIA compares its P/M
// registers against the beam position EVERY colour clock, so the collision
// latches accumulate progressively across the line and a read partway along
// sees only what the beam has already passed. A burst has no "partway" — the
// line's whole contribution is either absent or present.
//
// ACID800 gtia_pmretrigger is precisely this shape: it moves HPOSP0 mid-line,
// WSYNCs, and reads P0PL for the line it just drew. Chasing that with a
// burst means guessing a compose cycle that happens to sit between the write
// and the read, which is a timing coincidence rather than a model.
//
// This module does it the silicon way: it walks the beam and accumulates.
//
// Scope (stage 1)
// ---------------
// Player-to-player and missile-to-player collisions (P0PL..P3PL, M0PL..M3PL),
// which depend ONLY on the P/M registers and so need no playfield data and no
// P/M DMA. Playfield collisions (xxPF) still come from the compositor sweep;
// they need a per-x playfield-presence line buffer, which is stage 2.
//
// Shapes come from the CPU-written GRAFP/GRAFM registers. That covers the
// register-path tests (pmretrigger / pmoverlap / pmresize). DMA-fetched
// shapes are not visible here — antic_pmdma stays on the compositor path
// until the P/M DMA fetch is hoisted to the start of the line, as on real
// hardware, which is also stage 2.
//
// Cost
// ----
// Two evaluations per machine cycle (one per colour clock), each computing the
// 8-bit presence vector combinationally. The compositor's collision sweep does
// two evaluations per PIXEL, so this is substantially cheaper than the path it
// supersedes — which matters, as clk_sys and clk_sally are both at the edge.
//
`timescale 1ns/1ps

module gtia_pm_collide (
    input  wire        clk,          // clk_bus
    input  wire        rst,
    input  wire        phi2_tick,    // 1-clk pulse per machine cycle
    input  wire [7:0]  cyc,          // ANTIC cycle within the line, 0..113

    // ---- live P/M registers (CPU-written, same domain) -------------------
    input  wire [7:0]  hposp0, hposp1, hposp2, hposp3,
    input  wire [7:0]  hposm0, hposm1, hposm2, hposm3,
    input  wire [1:0]  sizep0, sizep1, sizep2, sizep3,
    input  wire [7:0]  sizem,
    input  wire [7:0]  grafp0, grafp1, grafp2, grafp3,
    input  wire [7:0]  grafm,

    // 1 while the beam is on an ACTIVE display line.  GTIA does not compare
    // during vertical blank, so without this the latches accumulate all the way
    // down the frame and ACID800 gtia_collision reports "P/M collisions were
    // detected in VBLANK".  Horizontal windowing alone is not enough.
    input  wire        active_line,

    input  wire        hitclr,       // 1-clk strobe: clear all latches

    output logic [15:0] mpl_q,       // {M3PL,M2PL,M1PL,M0PL}, 4 bits each
    output logic [15:0] ppl_q        // {P3PL,P2PL,P1PL,P0PL}, 4 bits each
);

    // atari_x maps from the ANTIC cycle as x = 4*cyc - 96: two colour clocks
    // per machine cycle, two atari pixels per colour clock, HPOS 48 = x 0.
    // Signed, because the beam legitimately probes negative x in the border.
    wire signed [11:0] x_base = $signed({4'd0, cyc} << 2) - 12'sd96;

    // GTIA only compares within the visible window; horizontal blank does not
    // collide.  These bounds are the same ones the compositor's border sweep
    // uses, and they are load-bearing: with GRAFP=$80 (leftmost two pixels lit)
    // an object at HPOS $22 sits exactly ON the low bound and MUST register,
    // while the same object at $21 falls just outside and must NOT.  ACID800
    // pins both halves of that edge.
    localparam signed [11:0] X_LO = -12'sd28;
    localparam signed [11:0] X_HI =  12'sd346;
    wire in_a = active_line && (x_base          >= X_LO) && (x_base            <= X_HI);
    wire in_b = active_line && ((x_base + 12'sd2) >= X_LO) && ((x_base + 12'sd2) <= X_HI);
    // cc = 2*cyc; the two colour clocks covered by this machine cycle
    wire [7:0] cc_a = {cyc[6:0], 1'b0};
    wire [7:0] cc_b = {cyc[6:0], 1'b1};

    // ---- per-object shift registers (the silicon model) ------------------
    // GTIA does not compute player pixels from a position formula.  Each
    // object has a shift register that LOADS when the horizontal counter
    // matches its HPOS, and then clocks out one bit every 1/2/4 colour clocks
    // according to SIZE.  Two consequences that a positional formula cannot
    // express, and which ACID800 tests directly:
    //
    //   * changing SIZE mid-draw changes the ADVANCE RATE only.  Pixels
    //     already emitted stand and the register continues from where it is.
    //     A formula recomputes the bit index from dx and so RE-INDEXES the
    //     whole shape — which is why 4x->1x gave $E0 where hardware gives $80
    //     (gtia_pmresize "4x-to-1x failed at index 0").
    //   * if HPOS matches AGAIN later in the line the register RELOADS and the
    //     player is drawn a SECOND time.  That is the whole of
    //     gtia_pmretrigger; a formula yields at most one draw per line.
    //
    // Colour-clock index: atari_x = 2*(cc - 48) and atari_x = 4*cyc - 96, so
    // cc = 2*cyc, and HPOS compares directly against cc.
    logic [7:0] p_sr    [0:3];   // player shift registers
    logic [2:0] p_bit   [0:3];   // bits emitted so far
    logic [1:0] p_sub   [0:3];   // sub-count within the current bit
    logic       p_act   [0:3];
    logic [1:0] m_sr    [0:3];   // missile shift registers (2 bits)
    logic [0:0] m_bit   [0:3];
    logic [1:0] m_sub   [0:3];
    logic       m_act   [0:3];

    function automatic logic [1:0] size_max(input logic [1:0] sz);
        // colour clocks per bit, minus 1: 1x -> 1cc, 2x -> 2cc, 4x -> 4cc
        case (sz)
            2'b01:   size_max = 2'd1;
            2'b11:   size_max = 2'd3;
            default: size_max = 2'd0;
        endcase
    endfunction

    wire [7:0] hposp_v [0:3];
    wire [1:0] sizep_v [0:3];
    wire [7:0] grafp_v [0:3];
    wire [7:0] hposm_v [0:3];
    assign hposp_v[0] = hposp0; assign hposp_v[1] = hposp1;
    assign hposp_v[2] = hposp2; assign hposp_v[3] = hposp3;
    assign sizep_v[0] = sizep0; assign sizep_v[1] = sizep1;
    assign sizep_v[2] = sizep2; assign sizep_v[3] = sizep3;
    assign grafp_v[0] = grafp0; assign grafp_v[1] = grafp1;
    assign grafp_v[2] = grafp2; assign grafp_v[3] = grafp3;
    assign hposm_v[0] = hposm0; assign hposm_v[1] = hposm1;
    assign hposm_v[2] = hposm2; assign hposm_v[3] = hposm3;

    // Presence of every object at the colour clock currently being stepped.
    logic [7:0] pres_now;

    // A player never registers a collision with itself, so P<i>PL bit i is
    // always 0; the diagonal is masked below.
    function automatic logic [15:0] ppl_of(input logic [7:0] pr);
        int i, j;
        begin
            ppl_of = 16'd0;
            for (i = 0; i < 4; i++)
                for (j = 0; j < 4; j++)
                    if (i != j)
                        ppl_of[4*i + j] = pr[4 + i] & pr[4 + j];
        end
    endfunction

    function automatic logic [15:0] mpl_of(input logic [7:0] pr);
        int i, j;
        begin
            mpl_of = 16'd0;
            for (i = 0; i < 4; i++)
                for (j = 0; j < 4; j++)
                    mpl_of[4*i + j] = pr[i] & pr[4 + j];
        end
    endfunction

    // Stepping is written as a pure combinational next-state block feeding a
    // registered one.  An earlier version stepped the registers with blocking
    // assignments inside the always_ff and wrote them back non-blocking; that
    // simulates correctly but mixes assignment styles on the same signal, which
    // is a synthesis hazard.  Keep this split.
    logic [7:0] n_p_sr  [0:3];
    logic [2:0] n_p_bit [0:3];
    logic [1:0] n_p_sub [0:3];
    logic       n_p_act [0:3];
    logic [1:0] n_m_sr  [0:3];
    logic [0:0] n_m_bit [0:3];
    logic [1:0] n_m_sub [0:3];
    logic       n_m_act [0:3];
    logic [15:0] n_ppl, n_mpl;

    always_comb begin
        int i, pass;
        logic [7:0] cc;
        logic [7:0] pres;
        logic       win;
        logic [7:0] tsr;    // temporaries: avoid part-selecting an array
        logic [1:0] tmsr;   // element in place, which iverilog cannot narrow

        for (i = 0; i < 4; i++) begin
            n_p_sr[i]  = p_sr[i];  n_p_bit[i] = p_bit[i];
            n_p_sub[i] = p_sub[i]; n_p_act[i] = p_act[i];
            n_m_sr[i]  = m_sr[i];  n_m_bit[i] = m_bit[i];
            n_m_sub[i] = m_sub[i]; n_m_act[i] = m_act[i];
        end
        n_ppl = ppl_q;
        n_mpl = mpl_q;

        // both colour clocks of this machine cycle, in order
        for (pass = 0; pass < 2; pass++) begin
            cc   = (pass == 0) ? cc_a : cc_b;
            win  = (pass == 0) ? in_a : in_b;
            pres = 8'd0;

            for (i = 0; i < 4; i++) begin
                // ---- players: reload on HPOS match, else clock at SIZE rate
                if (cc == hposp_v[i]) begin
                    n_p_sr[i]  = grafp_v[i];
                    n_p_bit[i] = 3'd0;
                    n_p_sub[i] = 2'd0;
                    n_p_act[i] = 1'b1;
                end else if (n_p_act[i]) begin
                    if (n_p_sub[i] == size_max(sizep_v[i])) begin
                        n_p_sub[i] = 2'd0;
                        if (n_p_bit[i] == 3'd7) n_p_act[i] = 1'b0;
                        else begin
                            n_p_bit[i] = n_p_bit[i] + 3'd1;
                            tsr        = n_p_sr[i];
                            n_p_sr[i]  = {tsr[6:0], 1'b0};
                        end
                    end else n_p_sub[i] = n_p_sub[i] + 2'd1;
                end
                tsr = n_p_sr[i];
                pres[4 + i] = n_p_act[i] & tsr[7];

                // ---- missiles: 2-bit shape, per-missile size field
                if (cc == hposm_v[i]) begin
                    n_m_sr[i]  = grafm[2*i +: 2];
                    n_m_bit[i] = 1'd0;
                    n_m_sub[i] = 2'd0;
                    n_m_act[i] = 1'b1;
                end else if (n_m_act[i]) begin
                    if (n_m_sub[i] == size_max(sizem[2*i +: 2])) begin
                        n_m_sub[i] = 2'd0;
                        if (n_m_bit[i] == 1'd1) n_m_act[i] = 1'b0;
                        else begin
                            n_m_bit[i] = n_m_bit[i] + 1'd1;
                            tmsr       = n_m_sr[i];
                            n_m_sr[i]  = {tmsr[0], 1'b0};
                        end
                    end else n_m_sub[i] = n_m_sub[i] + 2'd1;
                end
                tmsr = n_m_sr[i];
                pres[i] = n_m_act[i] & tmsr[1];
            end

            if (win) begin
                n_ppl = n_ppl | ppl_of(pres);
                n_mpl = n_mpl | mpl_of(pres);
            end
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        int i;
        if (rst) begin
            mpl_q <= 16'd0;
            ppl_q <= 16'd0;
            for (i = 0; i < 4; i++) begin
                p_sr[i] <= 8'd0; p_bit[i] <= 3'd0; p_sub[i] <= 2'd0; p_act[i] <= 1'b0;
                m_sr[i] <= 2'd0; m_bit[i] <= 1'd0; m_sub[i] <= 2'd0; m_act[i] <= 1'b0;
            end
        end else begin
            // HITCLR takes effect at the exact cycle it is written, so any
            // accumulation later in the same line starts from clear.  The shift
            // registers are display state and are NOT disturbed by it.
            if (hitclr) begin
                mpl_q <= 16'd0;
                ppl_q <= 16'd0;
            end else if (phi2_tick) begin
                ppl_q <= n_ppl;
                mpl_q <= n_mpl;
            end
            if (phi2_tick) begin
                for (i = 0; i < 4; i++) begin
                    p_sr[i]  <= n_p_sr[i];  p_bit[i] <= n_p_bit[i];
                    p_sub[i] <= n_p_sub[i]; p_act[i] <= n_p_act[i];
                    m_sr[i]  <= n_m_sr[i];  m_bit[i] <= n_m_bit[i];
                    m_sub[i] <= n_m_sub[i]; m_act[i] <= n_m_act[i];
                end
            end
        end
    end

endmodule

`default_nettype wire
