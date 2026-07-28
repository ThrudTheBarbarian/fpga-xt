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

    // ---- coverage helpers (semantics identical to compositor.sv) ---------
    function automatic logic player_covers(input logic signed [11:0] ax,
                                           input logic [7:0] hposp,
                                           input logic [7:0] shape,
                                           input logic [1:0] sizep);
        logic signed [11:0] x_left, dx, width;
        logic [2:0]         bit_sel;
        begin
            if (shape == 8'h00) return 1'b0;
            x_left = ($signed({4'd0, hposp}) - 12'sd48) <<< 1;
            dx     = ax - x_left;
            case (sizep)
                2'b01:   begin width = 12'sd32; bit_sel = 3'd7 - dx[4:2]; end
                2'b11:   begin width = 12'sd64; bit_sel = 3'd7 - dx[5:3]; end
                default: begin width = 12'sd16; bit_sel = 3'd7 - dx[3:1]; end
            endcase
            if (dx < 0 || dx >= width) return 1'b0;
            return shape[bit_sel];
        end
    endfunction

    function automatic logic missile_covers(input logic signed [11:0] ax,
                                            input logic [7:0] hposm,
                                            input logic [1:0] m_shape,
                                            input logic [1:0] m_size);
        logic signed [11:0] x_left, dx, width;
        logic               bit_sel;
        begin
            if (m_shape == 2'h0) return 1'b0;
            x_left = ($signed({4'd0, hposm}) - 12'sd48) <<< 1;
            dx     = ax - x_left;
            case (m_size)
                2'b01:   begin width = 12'sd8;  bit_sel = ~dx[2]; end
                2'b11:   begin width = 12'sd16; bit_sel = ~dx[3]; end
                default: begin width = 12'sd4;  bit_sel = ~dx[1]; end
            endcase
            if (dx < 0 || dx >= width) return 1'b0;
            return m_shape[bit_sel];
        end
    endfunction

    // presence vector {P3,P2,P1,P0,M3,M2,M1,M0} at one atari_x
    function automatic logic [7:0] presence(input logic signed [11:0] ax);
        begin
            presence[4] = player_covers (ax, hposp0, grafp0, sizep0);
            presence[5] = player_covers (ax, hposp1, grafp1, sizep1);
            presence[6] = player_covers (ax, hposp2, grafp2, sizep2);
            presence[7] = player_covers (ax, hposp3, grafp3, sizep3);
            presence[0] = missile_covers(ax, hposm0, grafm[1:0], sizem[1:0]);
            presence[1] = missile_covers(ax, hposm1, grafm[3:2], sizem[3:2]);
            presence[2] = missile_covers(ax, hposm2, grafm[5:4], sizem[5:4]);
            presence[3] = missile_covers(ax, hposm3, grafm[7:6], sizem[7:6]);
        end
    endfunction

    // Both colour clocks of this machine cycle.
    wire [7:0] pres_a = presence(x_base);
    wire [7:0] pres_b = presence(x_base + 12'sd2);

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

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            mpl_q <= 16'd0;
            ppl_q <= 16'd0;
        end else if (hitclr) begin
            // HITCLR takes effect at the exact cycle it is written, so any
            // accumulation later in the same line starts from clear.
            mpl_q <= 16'd0;
            ppl_q <= 16'd0;
        end else if (phi2_tick) begin
            ppl_q <= ppl_q | (in_a ? ppl_of(pres_a) : 16'd0)
                           | (in_b ? ppl_of(pres_b) : 16'd0);
            mpl_q <= mpl_q | (in_a ? mpl_of(pres_a) : 16'd0)
                           | (in_b ? mpl_of(pres_b) : 16'd0);
        end
    end

endmodule

`default_nettype wire
