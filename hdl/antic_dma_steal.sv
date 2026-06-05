// antic_dma_steal.sv — cycle-exact ANTIC DMA cycle-stealing model.
//
// Models which machine cycles within a scanline a real NTSC ANTIC takes from
// the 6502 bus (refresh + display-list + playfield + player/missile DMA), so
// that at CLOCK_MULT=1 the emulated CPU loses cycles exactly as on real
// hardware.  Output `steal` is combinational on the current machine cycle
// (`cyc` = phi2_in_line, 0..113) and the row metadata; the consumer (sally_clock
// via CDC) halts the CPU on stolen cycles.  Bypassed at CLOCK_MULT>=2.
//
// Timing per the Altirra Hardware Reference Manual (Avery Lee), §4.11-4.14:
//   - 114 machine cycles/line, cycle 0 = missile DMA / ~start of HBLANK.
//   - Missile  : cycle 0       (DMACTL[2], forced on by player DMA)
//   - Display  : cycle 1       (DMACTL[5], first scanline of a mode line)
//   - Players  : cycles 2..5   (DMACTL[3])
//   - Playfield: fast /2 (modes 2,3,4,5,D,E,F), medium /4 (6,7,A,B,C),
//                slow /8 (8,9).  Window 64/80/96 cy for narrow/normal/wide.
//                char NAME start 26/18/10 (first line only); char DATA = name+3
//                (every line); map DATA start 28/20/12 (first line only).
//                Hard stop: no playfield fetch at cycle >= 106.
//   - Refresh  : 9 cycles, nominal slots 25,29,...,57, deferred by +1 onto the
//                next free cycle when playfield holds the slot (preempted to ~0
//                when playfield is solid, e.g. a hi-res char first line).
//
// LMS +2 (cycles 6,7) and HSCROL window shift are NOT modelled yet (small,
// rare effects — see notes).  Validation totals (stolen cycles/line, normal
// width, P/M on) are asserted in sim/tb_antic_dma_steal.sv.

`default_nettype none

module antic_dma_steal (
    input  wire [7:0] cyc,        // phi2_in_line, machine cycle within scanline (0..113)
    input  wire [3:0] mode,      // ANTIC mode for this scanline (0=blank,1=JMP,2..F)
    input  wire       is_first,  // 1 = first scanline of this mode line (sub_row==0)
    input  wire       active,    // 1 = scanline is in the active display band
    input  wire [7:0] dmactl,    // DMACTL: [1:0]=width(0=off,1=nar,2=norm,3=wide),
                                 //         [2]=missile, [3]=player, [5]=DL
    output wire       steal      // 1 = ANTIC steals this machine cycle from the CPU
);

    wire [1:0] width  = dmactl[1:0];
    wire       is_char = (mode >= 4'd2) && (mode <= 4'd7);   // else (mode>=8) = map
    wire       pf_on   = active && (width != 2'd0) && (mode >= 4'd2);

    // ---- Playfield fetch test (evaluated at cyc and cyc-1 for refresh defer) -
    // rate: machine cycles between fetches.  win: fetch-window width (cycles).
    function automatic [7:0] pf_rate (input [3:0] m);
        case (m)
            4'd6, 4'd7, 4'hA, 4'hB, 4'hC: pf_rate = 8'd4;   // medium
            4'd8, 4'd9:                   pf_rate = 8'd8;   // slow
            default:                      pf_rate = 8'd2;   // fast: 2,3,4,5,D,E,F
        endcase
    endfunction
    function automatic [7:0] pf_win (input [1:0] w);
        case (w) 2'd1: pf_win = 8'd64; 2'd3: pf_win = 8'd96; default: pf_win = 8'd80; endcase
    endfunction
    function automatic [7:0] name_start (input [1:0] w);
        case (w) 2'd1: name_start = 8'd26; 2'd3: name_start = 8'd10; default: name_start = 8'd18; endcase
    endfunction
    function automatic [7:0] map_start (input [1:0] w);
        case (w) 2'd1: map_start = 8'd28; 2'd3: map_start = 8'd12; default: map_start = 8'd20; endcase
    endfunction
    // phase_ok: is `off` an integer multiple of `rate` (rate is 2/4/8)
    function automatic phase_ok (input [7:0] off, input [7:0] rate);
        case (rate)
            8'd2:    phase_ok = (off[0]   == 1'b0);
            8'd4:    phase_ok = (off[1:0] == 2'b0);
            default: phase_ok = (off[2:0] == 3'b0);   // 8
        endcase
    endfunction

    // Returns 1 if machine cycle c is a playfield fetch for the current row.
    function automatic pf_fetch (input [7:0] c);
        reg [7:0] rate, win, ns, ms;
        reg       name_hit, data_hit, map_hit;
        begin
            pf_fetch = 1'b0;
            if (pf_on && (c < 8'd106)) begin
                rate = pf_rate(mode);
                win  = pf_win(width);
                if (is_char) begin
                    ns = name_start(width);
                    name_hit = is_first && (c >= ns) && (c < ns + win)
                             && phase_ok(c - ns, rate);
                    data_hit = (c >= ns + 8'd3) && (c < ns + 8'd3 + win)
                             && phase_ok(c - ns - 8'd3, rate);
                    pf_fetch = name_hit || data_hit;
                end else begin   // map modes 8..F
                    ms = map_start(width);
                    map_hit = is_first && (c >= ms) && (c < ms + win)
                            && phase_ok(c - ms, rate);
                    pf_fetch = map_hit;
                end
            end
        end
    endfunction

    wire pf_now  = pf_fetch(cyc);
    wire pf_prev = pf_fetch(cyc - 8'd1);

    // ---- Memory refresh: 9 slots 25,29,...,57; defer +1 onto next free cycle --
    wire is_slot  = (cyc >= 8'd25) && (cyc <= 8'd57) && (((cyc - 8'd25) & 8'd3) == 8'd0);
    wire is_defer = (cyc >= 8'd26) && (cyc <= 8'd58) && (((cyc - 8'd26) & 8'd3) == 8'd0);
    wire refresh  = (is_slot  && !pf_now)
                 || (is_defer && pf_prev && !pf_now);

    // ---- Player / missile / display-list DMA (early HBLANK, active lines) -----
    wire pm_missile = active && (dmactl[2] || dmactl[3]) && (cyc == 8'd0);
    wire pm_player  = active &&  dmactl[3]               && (cyc >= 8'd2) && (cyc <= 8'd5);
    wire dl_dma     = active &&  dmactl[5] && is_first   && (cyc == 8'd1);

    assign steal = pm_missile | pm_player | dl_dma | pf_now | refresh;

endmodule

`default_nettype wire
