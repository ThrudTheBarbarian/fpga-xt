// tb_nmi.sv — M12 NMI generator verification.
//
// Stack: dl_parser (with DLI bits set on chosen rows) + a vbeam-style
// pulse generator (this testbench drives line_start / vbi_start
// directly) + nmi_gen + antic_regs (for NMIEN write + NMIRES strobe).
//
// Phase 1: NMIEN[7] only — DLI fires, /NMI low, NMIST=$80, NMIRES clears
// Phase 2: NMIEN[6] only — VBI fires, /NMI low, NMIST=$40, NMIRES clears
// Phase 3: NMIEN=$00 — neither fires
// Phase 4: simultaneous DLI + VBI: NMIST=$C0 after both pulses
// Phase 5: one register write NMIEN=$C0 must gate BOTH the DLI /NMI and the
//          VBI /NMI (bit7 survives the store AND reaches nmi_gen's DLI gate) —
//          regression guard for the HW "DLIs never fire under $C0" class.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_nmi;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    // ---- antic_regs (for NMIEN + NMIRES) -----------------------------
    logic        we    = 1'b0;
    logic [7:0]  waddr = 8'h0;
    logic [7:0]  wdata = 8'h0;
    wire  [7:0]  rdata;
    wire         wsync_pending;
    wire         nmires_strobe;
    wire  [7:0]  nmien_q;
    wire  [7:0]  dmactl_q, chactl_q, dlistl_q, dlisth_q;
    wire  [7:0]  hscrol_q, vscrol_q, pmbase_q, chbase_q;
    wire         mode_snoop_q;
    wire  [7:0]  clock_mult_q, output_mode_q;
    logic [7:0]  nmist_q;

    antic_regs u_antic_regs (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(8'h00), .rdata(rdata),
        .wsync_pending(wsync_pending),
        .nmires_strobe(nmires_strobe),
        .dmactl_q(dmactl_q), .chactl_q(chactl_q),
        .dlistl_q(dlistl_q), .dlisth_q(dlisth_q),
        .hscrol_q(hscrol_q), .vscrol_q(vscrol_q),
        .pmbase_q(pmbase_q), .chbase_q(chbase_q),
        .nmien_q(nmien_q),
        .mode_snoop_q(mode_snoop_q),
        .clock_mult_q(clock_mult_q),
        .output_mode_q(output_mode_q),
        .vcount_in(8'h00),
        .nmist_in(nmist_q),
        .serial_clock_mult_in(8'h00),
        .unlock_antic(1'b1), .unlock_sprite(1'b1), .unlock_blit(1'b1)
    );

    // ---- byte_ram (DL bytes) + dl_parser ------------------------------
    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;
    wire  [15:0] dl_raddr;
    wire  [7:0]  dl_rdata;

    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_dl_mem (
        .clk(clk), .we(bram_we), .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(dl_raddr), .rdata(dl_rdata)
    );

    logic        dl_start = 1'b0;
    wire  [7:0]  meta_row_w;
    wire  [3:0]  dl_meta_mode;
    wire         dl_meta_dli;
    wire  [15:0] dl_meta_lms;
    wire  [3:0]  dl_meta_sub;
    wire         dl_meta_hscrol_en;
    wire         dl_meta_vscrol_en;
    wire         dl_done;
    wire  [31:0] dl_count;
    wire  [7:0]  nmi_dli_row;
    wire         nmi_dli_at;

    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(dl_start),
        .dlistl(8'h00), .dlisth(8'hD0),
        .vscrol(4'h0),
        .mem_raddr(dl_raddr), .mem_rdata(dl_rdata), .mem_req(), .mem_ready(1'b1),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_dli(dl_meta_dli),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .meta_lms_addr(dl_meta_lms), .meta_sub_row(dl_meta_sub),
        .dli_row(nmi_dli_row), .dli_at(nmi_dli_at),
        .parse_done(dl_done), .parse_count(dl_count)
    );
    assign meta_row_w = 8'h00;     // unused here; dl_parser still drives the lookup ports

    // ---- nmi_gen ------------------------------------------------------
    logic        vbi_start    = 1'b0;
    logic        line_start   = 1'b0;
    logic        vbi_status   = 1'b0;
    logic        line_status  = 1'b0;
    logic [7:0]  atari_row_in = 8'h00;
    wire         nmi_n;

    nmi_gen u_nmi_gen (
        .clk(clk), .rst(rst),
        .nmien(nmien_q),
        .nmires_strobe(nmires_strobe),
        .status_tick(1'b1),
        .vbi_status(vbi_status),
        .vbi_start(vbi_start),
        .line_status(line_status),
        .line_start(line_start),
        .cur_row(nmi_dli_row),
        .cur_row_dli(nmi_dli_at),
        .atari_row_in(atari_row_in),
        .nmist_q(nmist_q),
        .nmi_n(nmi_n)
    );

    task automatic load_byte(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk);
        bram_waddr <= addr; bram_wdata <= data; bram_we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        bram_we <= 1'b0;
    endtask

    task automatic write_reg(input logic [7:0] a, input logic [7:0] d);
        @(negedge clk);
        waddr <= a; wdata <= d; we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        we <= 1'b0;
    endtask

    task automatic pulse_line(input logic [7:0] row);
        @(negedge clk);
        atari_row_in <= row;
        line_status  <= 1'b1;      // status tick (cycle 7 on HW)...
        @(posedge clk);
        @(negedge clk);
        line_status  <= 1'b0;
        line_start   <= 1'b1;      // ...then the /NMI tick (cycle 8)
        @(posedge clk);
        @(negedge clk);
        line_start   <= 1'b0;
    endtask

    task automatic pulse_vbi();
        @(negedge clk);
        vbi_status <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        vbi_status <= 1'b0;
        vbi_start  <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        vbi_start  <= 1'b0;
    endtask

    int fail_count = 0;

    task automatic expect_eq(input string tag,
                              input logic [7:0] got,
                              input logic [7:0] expected);
        if (got !== expected) begin
            $display("[%s] FAIL got $%02h expected $%02h", tag, got, expected);
            fail_count++;
        end
    endtask

    initial begin
        $display("[nmi] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // DL: mode-F line + DLI on DL byte 0, plain mode-F line, JVB.
        //
        // Mode F = 1 atari row per DL line.  A DLI on a VISIBLE mode line keeps
        // the compositor-aligned convention (fires on the FIRST scan line of the
        // NEXT DL line), so a DLI bit on DL byte 0 makes the NMI fire on row 1.
        // nmi_gen reads the PHYSICAL DLI map (dli_at / line_dli_p) with the live
        // raster row — that is the space that must agree on real hardware — so
        // this checks line_dli_p, not the compressed compositor table line_dli.
        //
        // Build: $8F (mode F + DLI bit), $0F (mode F), JVB.
        load_byte(16'hD000, 8'h8F);     // DLI bit set on first DL line
        load_byte(16'hD001, 8'h0F);     // plain mode F
        load_byte(16'hD002, 8'h41);     // JVB
        load_byte(16'hD003, 8'h00);
        load_byte(16'hD004, 8'hD0);

        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);

        // Verify the physical DLI map (what nmi_gen reads) fires on row 1 only.
        expect_eq("dl/row0_dli_p", {7'h0, u_dl.line_dli_p[0]}, 8'h00);
        expect_eq("dl/row1_dli_p", {7'h0, u_dl.line_dli_p[1]}, 8'h01);

        // ===== Phase 1: NMIEN[7] only — DLI fires, /NMI auto-releases =====
        // The real OS DLI dispatch (JMP (VDSLST)) RTIs WITHOUT writing
        // NMIRES, so /NMI MUST self-release as a pulse — otherwise the line
        // pins low forever and no further NMI is ever taken.
        write_reg(8'h0E, 8'h80);                    // NMIEN = $80
        // Pulse line_start at row 0 — no DLI here.
        pulse_line(8'd0);
        @(negedge clk);
        expect_eq("p1/row0/nmist", nmist_q, 8'h1F);
        expect_eq("p1/row0/nmi_n", {7'h0, nmi_n},  8'h01);     // /NMI high

        // Pulse line_start at row 1 — DLI here, NMI fires.
        pulse_line(8'd1);
        @(negedge clk);
        expect_eq("p1/row1/nmist", nmist_q, 8'h9F);
        expect_eq("p1/row1/nmi_n", {7'h0, nmi_n},  8'h00);     // /NMI low

        // Still low well into the pulse (must span >=1 fidelity-core
        // machine cycle so a coarse sampler cannot miss it).
        repeat (100) @(posedge clk);
        expect_eq("p1/pulse/mid-low", {7'h0, nmi_n}, 8'h00);   // still low

        // WITHOUT any NMIRES, /NMI returns high once the pulse window
        // (256 cycles) expires. This is the fix — DLI never acks.
        repeat (200) @(posedge clk);
        @(negedge clk);
        expect_eq("p1/pulse/auto-release", {7'h0, nmi_n}, 8'h01);  // high again
        expect_eq("p1/pulse/nmist-sticky", nmist_q, 8'h9F);        // flag still set

        // A second DLI produces a FRESH falling edge (line re-armed).
        pulse_line(8'd1);
        @(negedge clk);
        expect_eq("p1b/edge2/nmi_n", {7'h0, nmi_n}, 8'h00);    // low again

        // CPU acks via NMIRES → flags clear (nmi_n independent of ack now).
        repeat (300) @(posedge clk);                // let pulse expire
        write_reg(8'h0F, 8'h00);
        repeat (2) @(posedge clk);   // NMIRES applies at the status_tick boundary
        @(negedge clk);
        expect_eq("p1/ack/nmist", nmist_q, 8'h1F);

        // ===== Phase 2: NMIEN[6] only — VBI fires =========================
        write_reg(8'h0E, 8'h40);                    // NMIEN = $40
        pulse_vbi();
        @(negedge clk);
        expect_eq("p2/vbi/nmist", nmist_q, 8'h5F);
        expect_eq("p2/vbi/nmi_n", {7'h0, nmi_n},  8'h00);
        repeat (300) @(posedge clk);
        write_reg(8'h0F, 8'h00);
        repeat (2) @(posedge clk);   // NMIRES applies at the status_tick boundary
        @(negedge clk);
        expect_eq("p2/ack/nmist", nmist_q, 8'h1F);

        // A DLI must NOT assert /NMI while NMIEN[7]=0 — but real ANTIC still
        // latches the NMIST status bit on the event REGARDLESS of NMIEN (the
        // status latch is decoupled from the enable; only /NMI is gated).
        // ACID800 antic_nmist: "DLI bit set in NMIST with DLIs disabled."
        pulse_line(8'd1);
        @(negedge clk);
        expect_eq("p2/dli-masked/nmist", nmist_q,          8'h9F);  // status set...
        expect_eq("p2/dli-masked/nmi_n", {7'h0, nmi_n},    8'h01);  // ...but /NMI idle
        repeat (300) @(posedge clk);
        write_reg(8'h0F, 8'h00);                    // clear status for next phase
        repeat (2) @(posedge clk);   // NMIRES applies at the status_tick boundary
        @(negedge clk);
        expect_eq("p2/dli-masked/ack", nmist_q, 8'h1F);

        // ===== Phase 3: NMIEN=$00 — neither ASSERTS /NMI ==================
        // Status still latches (decoupled from NMIEN); last cause wins and VBI
        // takes the tie, so after a DLI then a VBI event NMIST reads $5F. The
        // KEY property under test is that /NMI never asserts while NMIEN=$00.
        write_reg(8'h0E, 8'h00);
        pulse_line(8'd1);
        pulse_vbi();
        @(negedge clk);
        expect_eq("p3/no-fire/nmist", nmist_q, 8'h5F);
        repeat (300) @(posedge clk);
        expect_eq("p3/no-fire/nmi_n", {7'h0, nmi_n},  8'h01);
        write_reg(8'h0F, 8'h00);                    // clear status for next phase

        // ===== Phase 4: last-cause — a VBI clears a pending DLI bit ========
        // REQUIRED by the OS: a VBI NMI must read bit7=0 (else BPL
        // mis-dispatches it as a DLI and the VBI/NMIRES body never runs).
        write_reg(8'h0E, 8'hC0);
        pulse_line(8'd1);                           // DLI: flags -> $80
        @(negedge clk);
        expect_eq("p4/dli-first/nmist", nmist_q, 8'h9F);
        pulse_vbi();                                // VBI: flags -> $40 (DLI cleared)
        @(negedge clk);
        expect_eq("p4/vbi-clears-dli/nmist", nmist_q, 8'h5F);   // bit7 == 0
        expect_eq("p4/vbi/nmi_n", {7'h0, nmi_n},  8'h00);

        // And the reverse: a DLI after a pending VBI presents bit7=1.
        pulse_line(8'd1);                           // DLI: flags -> $80
        @(negedge clk);
        expect_eq("p4/dli-clears-vbi/nmist", nmist_q, 8'h9F);   // bit6 == 0
        repeat (300) @(posedge clk);
        write_reg(8'h0F, 8'h00);

        // ===== Phase 5: one $C0 REGISTER write gates BOTH /NMIs ============
        // Regression guard for the HW "DLIs never fire" bug (ACID800
        // antic_nmist / antic_dlitiming / antic_pfst*timing).  The app enables
        // DLI+VBI with a SINGLE write NMIEN=$C0.  Phases 1/2 proved $80 and $40
        // in ISOLATION, and phase 4 wrote $C0 but only ever asserted NMIST (and
        // the *VBI* /NMI).  Because the NMIST status latch is DECOUPLED from
        // NMIEN, every phase-4 assertion passes even if NMIEN[7] were dropped on
        // the way into nmi_gen — so nothing checked that $C0 actually asserts the
        // *DLI* /NMI.  That is exactly the HW failure mode (dli_event fires,
        // dli_nmi never, because nmien[7] reads 0 at the gate).  This phase
        // drives $C0 through the REGISTER PATH (antic_regs, not a forced nmien),
        // confirms the store keeps bit7, and asserts the DLI /NMI asserts
        // alongside a VBI /NMI from that one write.
        write_reg(8'h0F, 8'h00);                    // clear any stale flags
        repeat (300) @(posedge clk);                // let any pulse expire
        write_reg(8'h0E, 8'hC0);                    // NMIEN = $C0 (DLI + VBI), ONE write
        @(negedge clk);
        expect_eq("p5/store/nmien", nmien_q, 8'hC0);           // bit7 survives the store

        // DLI event -> /NMI MUST assert.  nmi_n low here == dli_nmi ==
        // dli_event && nmien[7], i.e. bit7 reached nmi_gen's DLI gate.
        pulse_line(8'd1);
        @(negedge clk);
        expect_eq("p5/dli/nmist", nmist_q,        8'h9F);
        expect_eq("p5/dli/nmi_n", {7'h0, nmi_n},  8'h00);      // DLI /NMI low (bit7 gated in)
        repeat (300) @(posedge clk);                           // DLI pulse expires
        write_reg(8'h0F, 8'h00);                               // ack
        @(negedge clk);

        // VBI event under the SAME $C0 -> /NMI MUST also assert (bit6 intact).
        pulse_vbi();
        @(negedge clk);
        expect_eq("p5/vbi/nmist", nmist_q,        8'h5F);
        expect_eq("p5/vbi/nmi_n", {7'h0, nmi_n},  8'h00);      // VBI /NMI low (bit6 gated in)
        repeat (300) @(posedge clk);
        write_reg(8'h0F, 8'h00);

        if (fail_count == 0) begin
            $display("*** NMI OK *** pulse auto-release + last-cause NMIST verified");
            $finish;
        end else begin
            $display("*** NMI FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_nmi watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
