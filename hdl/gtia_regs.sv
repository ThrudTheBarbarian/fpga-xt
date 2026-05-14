// gtia_regs.sv — CTIA/GTIA register file ($D000-$D01F canonical,
// mirrored at every 32-byte boundary up to $D07F, plus the chiplet-
// extension window at $D080-$D0FF). See docs/register-map.md.
//
// Read and write sides are asymmetric: the same address has different
// semantics depending on R/W direction. E.g. $D000 writes to HPOSP0
// (player position) but reads M0PF (collision latch).
//
// Write port is registered through bus_snoop. Read port is
// combinational off the live bus address.

`default_nettype none

module gtia_regs (
    input  wire        clk,
    input  wire        rst,

    // Write port (registered from bus_snoop).
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [7:0]  wdata,

    // Read port (combinational from live bus signals).
    input  wire [7:0]  raddr,
    output logic [7:0] rdata,

    // Side-channel outputs to the compositor + collision logic.
    output logic [7:0] hposp_q [0:3],
    output logic [7:0] hposm_q [0:3],
    output logic [7:0] sizep_q [0:3],
    output logic [7:0] sizem_q,
    output logic [7:0] grafp_q [0:3],
    output logic [7:0] grafm_q,
    output logic [7:0] colpm_q [0:3],
    output logic [7:0] colpf_q [0:3],
    output logic [7:0] colbk_q,
    output logic [7:0] prior_q,
    output logic [7:0] vdelay_q,
    output logic [7:0] gractl_q,
    output logic [7:0] consol_w_q,

    // Read-side inputs (latches accumulated by the compositor).
    input  wire [7:0]  m_pf_in [0:3],   // M0PF..M3PF
    input  wire [7:0]  p_pf_in [0:3],   // P0PF..P3PF
    input  wire [7:0]  m_pl_in [0:3],   // M0PL..M3PL
    input  wire [7:0]  p_pl_in [0:3],   // P0PL..P3PL
    input  wire [7:0]  trig_in  [0:3],  // TRIG0..TRIG3 (serial-pushed by POKEY/PIA)
    input  wire [7:0]  pal_sense_in,    // PAL/NTSC sense (serial-pushed)
    input  wire [7:0]  consol_r_in,     // CONSOL read (serial-pushed by syscontroller)

    // Write strobe to the collision-clear logic.
    output logic       hitclr_strobe
);

    // ---- Storage --------------------------------------------------------
    logic [7:0] hposp [0:3];
    logic [7:0] hposm [0:3];
    logic [7:0] sizep [0:3];
    logic [7:0] sizem;
    logic [7:0] grafp [0:3];
    logic [7:0] grafm;
    logic [7:0] colpm [0:3];
    logic [7:0] colpf [0:3];
    logic [7:0] colbk;
    logic [7:0] prior;
    logic [7:0] vdelay;
    logic [7:0] gractl;
    logic [7:0] consol_w;

    // ---- Address decode helpers -----------------------------------------
    // Mirror $D000-$D01F every 32 bytes up to $D07F. Above $D080 is
    // chiplet extension (no GTIA-side ext registers allocated yet).
    // Bits [6:5] are the mirror selector — every 32-byte block in
    // $D000-$D07F is identical, so we don't decode them. Tie them off
    // for Verilator's UNUSEDSIGNAL check.
    wire is_canonical_w = (waddr[7] == 1'b0);  // $D000-$D07F
    wire [4:0] canon_w  = waddr[4:0];           // mod-32 index

    wire is_canonical_r = (raddr[7] == 1'b0);
    wire [4:0] canon_r  = raddr[4:0];

    wire _unused_w = |waddr[6:5];               // mirror bits, intentionally ignored
    wire _unused_r = |raddr[6:5];

    // ---- Write side -----------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < 4; i++) begin
                hposp[i] <= 8'h00;
                hposm[i] <= 8'h00;
                sizep[i] <= 8'h00;
                grafp[i] <= 8'h00;
                colpm[i] <= 8'h00;
                colpf[i] <= 8'h00;
            end
            sizem    <= 8'h00;
            grafm    <= 8'h00;
            colbk    <= 8'h00;
            prior    <= 8'h00;
            vdelay   <= 8'h00;
            gractl   <= 8'h00;
            consol_w <= 8'h00;
            hitclr_strobe <= 1'b0;
        end else begin
            hitclr_strobe <= 1'b0;          // pulse default

            if (we && is_canonical_w) begin
                unique case (canon_w)
                    5'h00: hposp[0] <= wdata;
                    5'h01: hposp[1] <= wdata;
                    5'h02: hposp[2] <= wdata;
                    5'h03: hposp[3] <= wdata;
                    5'h04: hposm[0] <= wdata;
                    5'h05: hposm[1] <= wdata;
                    5'h06: hposm[2] <= wdata;
                    5'h07: hposm[3] <= wdata;
                    5'h08: sizep[0] <= wdata;
                    5'h09: sizep[1] <= wdata;
                    5'h0A: sizep[2] <= wdata;
                    5'h0B: sizep[3] <= wdata;
                    5'h0C: sizem    <= wdata;
                    5'h0D: grafp[0] <= wdata;
                    5'h0E: grafp[1] <= wdata;
                    5'h0F: grafp[2] <= wdata;
                    5'h10: grafp[3] <= wdata;
                    5'h11: grafm    <= wdata;
                    5'h12: colpm[0] <= wdata;
                    5'h13: colpm[1] <= wdata;
                    5'h14: colpm[2] <= wdata;
                    5'h15: colpm[3] <= wdata;
                    5'h16: colpf[0] <= wdata;
                    5'h17: colpf[1] <= wdata;
                    5'h18: colpf[2] <= wdata;
                    5'h19: colpf[3] <= wdata;
                    5'h1A: colbk    <= wdata;
                    5'h1B: prior    <= wdata;
                    5'h1C: vdelay   <= wdata;
                    5'h1D: gractl   <= wdata;
                    5'h1E: hitclr_strobe <= 1'b1;   // $D01E HITCLR — strobe only
                    5'h1F: consol_w <= wdata;
                endcase
            end
            // Chiplet extension ($D080-$D0FF): no GTIA-side ext yet.
        end
    end

    // ---- Read side (combinational) --------------------------------------
    always_comb begin
        rdata = 8'h00;
        if (is_canonical_r) begin
            unique case (canon_r)
                5'h00: rdata = m_pf_in[0];          // $D000 M0PF
                5'h01: rdata = m_pf_in[1];          // $D001 M1PF
                5'h02: rdata = m_pf_in[2];          // $D002 M2PF
                5'h03: rdata = m_pf_in[3];          // $D003 M3PF
                5'h04: rdata = p_pf_in[0];          // $D004 P0PF
                5'h05: rdata = p_pf_in[1];          // $D005 P1PF
                5'h06: rdata = p_pf_in[2];          // $D006 P2PF
                5'h07: rdata = p_pf_in[3];          // $D007 P3PF
                5'h08: rdata = m_pl_in[0];          // $D008 M0PL
                5'h09: rdata = m_pl_in[1];          // $D009 M1PL
                5'h0A: rdata = m_pl_in[2];          // $D00A M2PL
                5'h0B: rdata = m_pl_in[3];          // $D00B M3PL
                5'h0C: rdata = p_pl_in[0];          // $D00C P0PL
                5'h0D: rdata = p_pl_in[1];          // $D00D P1PL
                5'h0E: rdata = p_pl_in[2];          // $D00E P2PL
                5'h0F: rdata = p_pl_in[3];          // $D00F P3PL
                5'h10: rdata = trig_in[0];          // $D010 TRIG0
                5'h11: rdata = trig_in[1];          // $D011 TRIG1
                5'h12: rdata = trig_in[2];          // $D012 TRIG2
                5'h13: rdata = trig_in[3];          // $D013 TRIG3
                5'h14: rdata = pal_sense_in;        // $D014 PAL
                5'h15: rdata = 8'h00;
                5'h16: rdata = 8'h00;
                5'h17: rdata = 8'h00;
                5'h18: rdata = 8'h00;
                5'h19: rdata = 8'h00;
                5'h1A: rdata = 8'h00;
                5'h1B: rdata = 8'h00;
                5'h1C: rdata = 8'h00;
                5'h1D: rdata = 8'h00;
                5'h1E: rdata = 8'h00;
                5'h1F: rdata = consol_r_in;         // $D01F CONSOL
            endcase
        end
        // Chiplet ext reads return 0 — no GTIA-side ext yet.
    end

    // ---- Side-channel outputs -------------------------------------------
    assign hposp_q[0]  = hposp[0];
    assign hposp_q[1]  = hposp[1];
    assign hposp_q[2]  = hposp[2];
    assign hposp_q[3]  = hposp[3];
    assign hposm_q[0]  = hposm[0];
    assign hposm_q[1]  = hposm[1];
    assign hposm_q[2]  = hposm[2];
    assign hposm_q[3]  = hposm[3];
    assign sizep_q[0]  = sizep[0];
    assign sizep_q[1]  = sizep[1];
    assign sizep_q[2]  = sizep[2];
    assign sizep_q[3]  = sizep[3];
    assign sizem_q     = sizem;
    assign grafp_q[0]  = grafp[0];
    assign grafp_q[1]  = grafp[1];
    assign grafp_q[2]  = grafp[2];
    assign grafp_q[3]  = grafp[3];
    assign grafm_q     = grafm;
    assign colpm_q[0]  = colpm[0];
    assign colpm_q[1]  = colpm[1];
    assign colpm_q[2]  = colpm[2];
    assign colpm_q[3]  = colpm[3];
    assign colpf_q[0]  = colpf[0];
    assign colpf_q[1]  = colpf[1];
    assign colpf_q[2]  = colpf[2];
    assign colpf_q[3]  = colpf[3];
    assign colbk_q     = colbk;
    assign prior_q     = prior;
    assign vdelay_q    = vdelay;
    assign gractl_q    = gractl;
    assign consol_w_q  = consol_w;

endmodule

`default_nettype wire
