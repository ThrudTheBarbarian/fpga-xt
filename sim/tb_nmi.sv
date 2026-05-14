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
        .serial_clock_mult_in(8'h00)
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
    logic [7:0]  atari_row_in = 8'h00;
    wire         nmi_n;

    nmi_gen u_nmi_gen (
        .clk(clk), .rst(rst),
        .nmien(nmien_q),
        .nmires_strobe(nmires_strobe),
        .vbi_start(vbi_start),
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
        line_start   <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        line_start   <= 1'b0;
    endtask

    task automatic pulse_vbi();
        @(negedge clk);
        vbi_start <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        vbi_start <= 1'b0;
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

        // DL: mode F line on row 0 (no DLI), mode F line + DLI on row 1.
        // After parse: line_dli[0]=0, line_dli[1]=0, ..., line_dli[?]=1
        // depending on where the DLI bit lands.
        //
        // Mode F = 1 atari row per DL line. The DLI bit on a DL line
        // fires NMI on the FIRST scan line of the NEXT DL line, so
        // setting DLI on DL byte 0 makes line_dli[1] = 1.
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

        // Verify dl_parser exposes the DLI bit on row 1 only.
        expect_eq("dl/row0_dli", {7'h0, u_dl.line_dli[0]}, 8'h00);
        expect_eq("dl/row1_dli", {7'h0, u_dl.line_dli[1]}, 8'h01);

        // ===== Phase 1: NMIEN[7] only — DLI fires =========================
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

        // CPU acks via NMIRES.
        write_reg(8'h0F, 8'h00);
        @(negedge clk);
        expect_eq("p1/ack/nmist", nmist_q, 8'h1F);
        expect_eq("p1/ack/nmi_n", {7'h0, nmi_n},  8'h01);

        // ===== Phase 2: NMIEN[6] only — VBI fires =========================
        write_reg(8'h0E, 8'h40);                    // NMIEN = $40
        pulse_vbi();
        @(negedge clk);
        expect_eq("p2/vbi/nmist", nmist_q, 8'h5F);
        expect_eq("p2/vbi/nmi_n", {7'h0, nmi_n},  8'h00);

        write_reg(8'h0F, 8'h00);
        @(negedge clk);
        expect_eq("p2/ack/nmist", nmist_q, 8'h1F);

        // DLI should NOT fire while NMIEN[7]=0.
        pulse_line(8'd1);
        @(negedge clk);
        expect_eq("p2/dli-masked", nmist_q, 8'h1F);

        // ===== Phase 3: NMIEN=$00 — neither fires =========================
        write_reg(8'h0E, 8'h00);
        pulse_line(8'd1);
        pulse_vbi();
        @(negedge clk);
        expect_eq("p3/no-fire/nmist", nmist_q, 8'h1F);
        expect_eq("p3/no-fire/nmi_n", {7'h0, nmi_n},  8'h01);

        // ===== Phase 4: both enabled, both fire ===========================
        write_reg(8'h0E, 8'hC0);
        pulse_line(8'd1);
        pulse_vbi();
        @(negedge clk);
        expect_eq("p4/both/nmist", nmist_q, 8'hDF);
        expect_eq("p4/both/nmi_n", {7'h0, nmi_n},  8'h00);

        // ===== Phase 5: NMIRES + new DLI in same cycle → set wins ========
        // Re-arm: ack first, then immediately fire DLI.
        write_reg(8'h0F, 8'h00);
        @(posedge clk);
        // Manually engineer "set + clear in same cycle":
        @(negedge clk);
        atari_row_in <= 8'd1;
        line_start   <= 1'b1;
        waddr <= 8'h0F; wdata <= 8'h00; we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        line_start <= 1'b0;
        we         <= 1'b0;
        @(posedge clk);
        // NMIRES cleared on this cycle, but DLI also fired → NMIST=$80
        expect_eq("p5/set-wins/nmist", nmist_q, 8'h9F);

        if (fail_count == 0) begin
            $display("*** NMI OK *** DLI + VBI + NMIRES set-wins verified");
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
