`default_nettype none
//
// gtia_reg_file — GTIA's registers, $D000-$D01F.
//
// docs/ANTIC-rewrite.md.  Thirty-two addresses, mirrored eight times across
// $D000-$D0FF: GTIA decodes five address bits and nothing above them, which is
// the whole of gtia_addrmirror.
//
// THE READ AND WRITE MAPS ARE DIFFERENT REGISTERS AT THE SAME ADDRESSES.  Almost
// nothing here reads back what was written — $D000-$D00F write the object
// positions and sizes but read the collision latches, and $D015-$D01E are
// write-only.  A read of a write-only GTIA address is not open bus: the chip
// leaves D4-D7 low and drives D0-D3 high, so it returns $0F.  That is what
// gtia_default measures.
//
// GRACTL GATES THE DMA STORE, DMACTL GATES THE FETCH, and both are needed.
// ANTIC fetching a shape is not the same as GTIA accepting it: DMACTL[3:2] make
// ANTIC read the bytes and GRACTL[1:0] make GTIA latch them.  Turning off either
// leaves the last shape standing, which is the ground gtia_phantomdma tests on.
//
// P/M DMA AND THE CPU WRITE THE SAME GRAFP/GRAFM REGISTERS, whoever wrote last
// winning.  A DMA store arrives as data plus pm_fetch, and VDELAY is resolved
// HERE rather than in ANTIC, because the delay is a one-fetch history of what
// this file already holds — see the note above the prev_* registers.
//
// THE CONSOLE LINES ARE OPEN DRAIN.  A 1 in the output latch pulls its line low
// so it reads 0; a 0 releases it and the read reflects the key input, which is
// active low.  The OS reads keys by writing 0 first, so a kernel holding OPTION
// still sees it.
//
// CLOCK BUDGET: a register file.  Writes are one decode, reads one mux, and
// neither is on a per-pixel path.
//
`timescale 1ns/1ps

module gtia_reg_file (
    input  wire       clk,
    input  wire       rst,

    // ---- CPU bus ---------------------------------------------------------
    input  wire [7:0] addr,            // low byte of $D0xx
    input  wire       we,
    input  wire [7:0] wdata,
    output logic [7:0] rdata,

    // ---- P/M DMA store ---------------------------------------------------
    input  wire       pm_we,
    input  wire [2:0] pm_obj,          // 0 = missiles, 1..4 = players 0..3
    input  wire [7:0] pm_data,
    // 1 = this byte came from a P/M DMA FETCH, so VDELAY applies and the
    // previous-fetch copy moves on.  0 = the PHANTOM, which captures the bus
    // and writes straight through -- emu's phantom_latch pokes gt.grafp
    // directly and never goes near pm_latch.
    input  wire       pm_fetch,

    // ---- status in -------------------------------------------------------
    input  wire [15:0] m_pf, p_pf, m_pl, p_pl,   // four nibbles each
    input  wire [7:0]  trig0, trig1, trig2, trig3,
    input  wire [7:0]  pal_sense,
    input  wire [7:0]  consol_keys,    // active low, 1 = released
    output wire        consol_spk,     // CONSOL bit3 = console speaker (key click)

    // ---- register outputs -------------------------------------------------
    output logic [7:0] hposp0, hposp1, hposp2, hposp3,
    output logic [7:0] hposm0, hposm1, hposm2, hposm3,
    output logic [1:0] sizep0, sizep1, sizep2, sizep3,
    // 1-clk per player on a SIZEP WRITE.  A resize is an EVENT, not a change:
    // the object walk applies a different roll rule on the clock a SIZEP write
    // lands, and it does so whether or not the value written differs from the
    // one already there.  A value-change detector would miss a rewrite of the
    // same size, so the strobe is the write itself.
    output logic [3:0] sizep_we,
    output logic [7:0] sizem,
    output logic [7:0] grafp0, grafp1, grafp2, grafp3,
    output logic [7:0] grafm,
    output logic [7:0] colpm0, colpm1, colpm2, colpm3,
    output logic [7:0] colpf0, colpf1, colpf2, colpf3,
    output logic [7:0] colbk,
    output logic [7:0] prior,
    output logic [7:0] vdelay,
    output logic [7:0] gractl,
    output wire        hitclr           // 1-clk strobe
);

    // Five bits decoded, everything above ignored.
    wire [4:0] a = addr[4:0];

    assign hitclr = we && (a == 5'h1E);

    // GRACTL decides whether a fetched shape is latched at all.
    wire pm_take = pm_we &&
                   ((pm_obj == 3'd0) ? gractl[0] : gractl[1]);

    // VDELAY IS A ONE-FETCH DELAY, NOT A FREEZE, AND THE DIFFERENCE IS WHAT
    // gtia_vdelay MEASURES.  emu (system.c:126-148) selects between the byte
    // just fetched and the one fetched a line earlier, and then advances the
    // previous-fetch copy EVERY latch:
    //
    //     grafp[i] = (vdelay & (0x10<<i)) ? pm_prev_p[i] : pm_p[i];
    //     ...
    //     for i: pm_prev_p[i] = pm_p[i];
    //
    // so with VDELAY held set the object shows fetch(N-1) on line N, fetch(N)
    // on line N+1 -- it keeps moving, one line behind.  Masking "which bits may
    // change" instead pins the byte at whatever it held when VDELAY went on and
    // it never advances again.  emu's own note says why the delay is applied to
    // the LATCH rather than by skipping a line: in two-line resolution the same
    // byte serves both scanlines of a pair, so delaying the latch shifts the
    // object down one scanline while PRESERVING its two-line extent -- vdelay
    // wants on,on,off,off becoming off,on,on,off, and skipping the first line
    // would give on,off,on,off and fail half the assertions.
    //
    // Missiles share GRAFM two bits each and are delayed INDEPENDENTLY, so the
    // missile byte is assembled per pair rather than selected whole.
    logic [7:0] prev_p0, prev_p1, prev_p2, prev_p3, prev_m;

    function automatic logic [7:0] mix_m(input logic [7:0] cur,
                                         input logic [7:0] prv,
                                         input logic [7:0] vd);
        for (int i = 0; i < 4; i++)
            mix_m[2*i +: 2] = vd[i] ? prv[2*i +: 2] : cur[2*i +: 2];
    endfunction

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            hposp0 <= 8'h00; hposp1 <= 8'h00; hposp2 <= 8'h00; hposp3 <= 8'h00;
            hposm0 <= 8'h00; hposm1 <= 8'h00; hposm2 <= 8'h00; hposm3 <= 8'h00;
            sizep0 <= 2'd0;  sizep1 <= 2'd0;  sizep2 <= 2'd0;  sizep3 <= 2'd0;
            sizep_we <= 4'd0;
            sizem  <= 8'h00;
            grafp0 <= 8'h00; grafp1 <= 8'h00; grafp2 <= 8'h00; grafp3 <= 8'h00;
            grafm  <= 8'h00;
            prev_p0 <= 8'h00; prev_p1 <= 8'h00;
            prev_p2 <= 8'h00; prev_p3 <= 8'h00; prev_m <= 8'h00;
            colpm0 <= 8'h00; colpm1 <= 8'h00; colpm2 <= 8'h00; colpm3 <= 8'h00;
            colpf0 <= 8'h00; colpf1 <= 8'h00; colpf2 <= 8'h00; colpf3 <= 8'h00;
            colbk  <= 8'h00;
            prior  <= 8'h00;
            vdelay <= 8'h00;
            gractl <= 8'h00;
        end else begin
            sizep_we <= 4'd0;   // one clock only
            // The CPU write is decoded first; the DMA store below can land on
            // the same register in the same cycle and takes precedence, which
            // is the same "whoever wrote last wins" the hardware has.
            if (we) begin
                case (a)
                    5'h00: hposp0 <= wdata;
                    5'h01: hposp1 <= wdata;
                    5'h02: hposp2 <= wdata;
                    5'h03: hposp3 <= wdata;
                    5'h04: hposm0 <= wdata;
                    5'h05: hposm1 <= wdata;
                    5'h06: hposm2 <= wdata;
                    5'h07: hposm3 <= wdata;
                    5'h08: begin sizep0 <= wdata[1:0]; sizep_we[0] <= 1'b1; end
                    5'h09: begin sizep1 <= wdata[1:0]; sizep_we[1] <= 1'b1; end
                    5'h0A: begin sizep2 <= wdata[1:0]; sizep_we[2] <= 1'b1; end
                    5'h0B: begin sizep3 <= wdata[1:0]; sizep_we[3] <= 1'b1; end
                    5'h0C: sizem  <= wdata;
                    5'h0D: grafp0 <= wdata;
                    5'h0E: grafp1 <= wdata;
                    5'h0F: grafp2 <= wdata;
                    5'h10: grafp3 <= wdata;
                    5'h11: grafm  <= wdata;
                    5'h12: colpm0 <= wdata;
                    5'h13: colpm1 <= wdata;
                    5'h14: colpm2 <= wdata;
                    5'h15: colpm3 <= wdata;
                    5'h16: colpf0 <= wdata;
                    5'h17: colpf1 <= wdata;
                    5'h18: colpf2 <= wdata;
                    5'h19: colpf3 <= wdata;
                    5'h1A: colbk  <= wdata;
                    5'h1B: prior  <= wdata;
                    5'h1C: vdelay <= wdata;
                    5'h1D: gractl <= wdata;
                    default: ;              // $D01E HITCLR, $D01F CONSOL below
                endcase
            end

            if (pm_take) begin
                case (pm_obj)
                3'd0: begin
                    grafm <= pm_fetch ? mix_m(pm_data, prev_m, vdelay) : pm_data;
                    if (pm_fetch) prev_m <= pm_data;
                end
                3'd1: begin
                    grafp0 <= (pm_fetch && vdelay[4]) ? prev_p0 : pm_data;
                    if (pm_fetch) prev_p0 <= pm_data;
                end
                3'd2: begin
                    grafp1 <= (pm_fetch && vdelay[5]) ? prev_p1 : pm_data;
                    if (pm_fetch) prev_p1 <= pm_data;
                end
                3'd3: begin
                    grafp2 <= (pm_fetch && vdelay[6]) ? prev_p2 : pm_data;
                    if (pm_fetch) prev_p2 <= pm_data;
                end
                default: begin
                    grafp3 <= (pm_fetch && vdelay[7]) ? prev_p3 : pm_data;
                    if (pm_fetch) prev_p3 <= pm_data;
                end
                endcase
            end
        end
    end

    // ---- CONSOL ----------------------------------------------------------
    // CONSOL ($D01F) write latch.  Bits [2:0] pull the console-key lines low for
    // the OS's key scan; bit 3 is the CONSOLE SPEAKER, which is what produces the
    // XL key click.  Bit 3 used to be carried by the legacy gtia_regs (an 8-bit
    // latch) and was dropped when antic2's gtia_reg_file became the live GTIA,
    // which is why the click went away.  Keep consol_rd on [2:0] so the ACID
    // console-key vectors are unaffected.
    logic [3:0] consol_w;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                          consol_w <= 4'b0000;
        else if (we && (a == 5'h1F))      consol_w <= wdata[3:0];
    end

    wire [7:0] consol_rd = {consol_keys[7:3], consol_keys[2:0] & ~consol_w[2:0]};
    assign consol_spk = consol_w[3];        // console speaker -> audio mix

    // ---- reads -----------------------------------------------------------
    function automatic logic [7:0] nib(input logic [15:0] v, input int n);
        nib = {4'h0, v[n*4 +: 4]};
    endfunction

    always_comb begin
        case (a)
            5'h00: rdata = nib(m_pf, 0);
            5'h01: rdata = nib(m_pf, 1);
            5'h02: rdata = nib(m_pf, 2);
            5'h03: rdata = nib(m_pf, 3);
            5'h04: rdata = nib(p_pf, 0);
            5'h05: rdata = nib(p_pf, 1);
            5'h06: rdata = nib(p_pf, 2);
            5'h07: rdata = nib(p_pf, 3);
            5'h08: rdata = nib(m_pl, 0);
            5'h09: rdata = nib(m_pl, 1);
            5'h0A: rdata = nib(m_pl, 2);
            5'h0B: rdata = nib(m_pl, 3);
            5'h0C: rdata = nib(p_pl, 0);
            5'h0D: rdata = nib(p_pl, 1);
            5'h0E: rdata = nib(p_pl, 2);
            5'h0F: rdata = nib(p_pl, 3);
            5'h10: rdata = trig0;
            5'h11: rdata = trig1;
            5'h12: rdata = trig2;
            5'h13: rdata = trig3;
            5'h14: rdata = pal_sense;
            5'h1F: rdata = consol_rd;
            // $D015-$D01E are write-only.  GTIA does not decode them for read,
            // leaving D4-D7 low and driving D0-D3 high.
            default: rdata = 8'h0F;
        endcase
    end

endmodule

`default_nettype wire
