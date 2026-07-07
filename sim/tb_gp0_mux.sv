// tb_gp0_mux.sv — exercise the INTEGRATED GP0 master path that the isolated
// tb_mathcop never covers: math_cop (m1) + screen_bank (m0) sharing one
// S_AXI_GP0 slave through gp0_axi_mux.  tb_mathcop drives math_cop's e_axi
// straight at a DDR model, bypassing the mux; on hardware the math page reads
// back a uniform 0x82, so the suspect is the mux read routing / arbitration.
//
//   A) math fill + dirty/EXEC flush + MATH_DONE span reload, THROUGH the mux,
//      screen idle.  If the mux mangles math's read burst this reproduces the
//      constant-read bug off-hardware.
//   B) same math reload but with screen_bank issuing a concurrent chunk fill,
//      so the arbiter has to interleave two masters' bursts.  Verifies BOTH
//      masters get their own data back.
//
// DDR is a single burst-slave model on the mux s_* port (as tb_mathcop's).

`timescale 1ns/1ps
`default_nettype none

module tb_gp0_mux;
    localparam logic [31:0] MATH_BASE   = 32'h2080_0000;
    localparam logic [31:0] SCREEN_BASE = 32'h2081_0000;   // +64 KB, clear of math chunks 0..3
    localparam int APE = 13, WORDS = 1024;
    localparam int MEMW = 16*WORDS;                        // covers both regions

    logic clk = 0, clk_cpu = 0, rst = 1;
    always #5 clk     = ~clk;       // 100 MHz engine / AXI
    always #5 clk_cpu = ~clk_cpu;

    // ---- math_cop (m1) CPU + doorbell ----
    logic [APE-1:0] mc_cpu_addr=0; logic mc_cpu_we=0; logic [7:0] mc_cpu_wdata=0; wire [7:0] mc_cpu_rdata;
    logic mc_exec_we=0; logic [7:0] mc_chunk_wval=0; logic mc_chunk_we=0;
    wire  mc_done, mc_busy, mc_ready;
    wire  [8:0] mc_evt_data; logic mc_evt_pop=0; wire mc_evt_irq;
    logic [23:0] mc_done_word=0; logic mc_done_we=0; wire [31:0] mc_stat_word;

    // ---- screen_bank (m0) CPU/ANTIC ----
    logic [APE-1:0] sb_cpu_addr=0; logic sb_cpu_we=0; logic [7:0] sb_cpu_wdata=0; wire [7:0] sb_cpu_rdata;
    logic [7:0] sb_bank_wval=0; logic sb_bank_we=0; wire sb_ready;
    logic [APE-1:0] sb_antic_addr=0; wire [7:0] sb_antic_rdata;
    logic [7:0] sb_antic_bank_wval=0; logic sb_antic_bank_we=0; logic sb_vbi=0; wire sb_antic_banked;

    // ---- master<->mux AXI wires ----
    wire [31:0] mc_araddr, mc_awaddr, mc_wdata, mc_rdata;
    wire [3:0]  mc_arlen, mc_awlen, mc_wstrb;
    wire [2:0]  mc_arsize, mc_awsize; wire [1:0] mc_arburst, mc_awburst;
    wire mc_arvalid, mc_arready, mc_rvalid, mc_rlast, mc_rready;
    wire mc_awvalid, mc_awready, mc_wlast, mc_wvalid, mc_wready, mc_bvalid, mc_bready;

    wire [31:0] sb_araddr, sb_awaddr, sb_wdata, sb_rdata;
    wire [3:0]  sb_arlen, sb_awlen, sb_wstrb;
    wire [2:0]  sb_arsize, sb_awsize; wire [1:0] sb_arburst, sb_awburst;
    wire sb_arvalid, sb_arready, sb_rvalid, sb_rlast, sb_rready;
    wire sb_awvalid, sb_awready, sb_wlast, sb_wvalid, sb_wready, sb_bvalid, sb_bready;

    // ---- mux<->DDR AXI wires (the shared S_AXI_GP0) ----
    wire [31:0] s_araddr, s_awaddr, s_wdata;
    wire [3:0]  s_arlen, s_awlen, s_wstrb;
    wire [2:0]  s_arsize, s_awsize; wire [1:0] s_arburst, s_awburst;
    wire s_arvalid, s_rready, s_awvalid, s_wlast, s_wvalid, s_bready;
    logic s_arready, s_rvalid, s_rlast, s_awready, s_wready, s_bvalid;
    logic [31:0] s_rdata;

    // ===================================================================
    math_cop #(.STACK_BASE(MATH_BASE), .APERTURE_LOG2(APE)) u_math (
        .clk(clk), .rst(rst), .clk_cpu(clk_cpu),
        .cpu_addr(mc_cpu_addr), .cpu_we(mc_cpu_we), .cpu_wdata(mc_cpu_wdata),
        .cpu_rden(1'b1), .cpu_rdata(mc_cpu_rdata),
        .exec_we(mc_exec_we), .chunk_wval(mc_chunk_wval), .chunk_we(mc_chunk_we),
        .math_done(mc_done), .math_busy(mc_busy), .chunk_ready(mc_ready),
        .evt_data(mc_evt_data), .evt_pop(mc_evt_pop), .evt_irq(mc_evt_irq),
        .done_word(mc_done_word), .done_we(mc_done_we), .stat_word(mc_stat_word),
        .e_axi_araddr(mc_araddr), .e_axi_arlen(mc_arlen), .e_axi_arsize(mc_arsize), .e_axi_arburst(mc_arburst),
        .e_axi_arvalid(mc_arvalid), .e_axi_arready(mc_arready), .e_axi_rdata(mc_rdata),
        .e_axi_rvalid(mc_rvalid), .e_axi_rlast(mc_rlast), .e_axi_rready(mc_rready),
        .e_axi_awaddr(mc_awaddr), .e_axi_awlen(mc_awlen), .e_axi_awsize(mc_awsize), .e_axi_awburst(mc_awburst),
        .e_axi_awvalid(mc_awvalid), .e_axi_awready(mc_awready), .e_axi_wdata(mc_wdata), .e_axi_wstrb(mc_wstrb),
        .e_axi_wlast(mc_wlast), .e_axi_wvalid(mc_wvalid), .e_axi_wready(mc_wready),
        .e_axi_bvalid(mc_bvalid), .e_axi_bready(mc_bready)
    );

    screen_bank #(.STACK_BASE(SCREEN_BASE), .APERTURE_LOG2(APE)) u_scrn (
        .clk(clk), .rst(rst), .clk_cpu(clk_cpu),
        .cpu_addr(sb_cpu_addr), .cpu_we(sb_cpu_we), .cpu_wdata(sb_cpu_wdata),
        .cpu_rden(1'b1), .cpu_rdata(sb_cpu_rdata),
        .cpu_bank_wval(sb_bank_wval), .cpu_bank_we(sb_bank_we), .ready(sb_ready),
        .clk_antic(clk), .antic_addr(sb_antic_addr), .antic_rdata(sb_antic_rdata),
        .antic_bank_wval(sb_antic_bank_wval), .antic_bank_we(sb_antic_bank_we), .vbi(sb_vbi),
        .antic_banked(sb_antic_banked),
        .e_axi_araddr(sb_araddr), .e_axi_arlen(sb_arlen), .e_axi_arsize(sb_arsize), .e_axi_arburst(sb_arburst),
        .e_axi_arvalid(sb_arvalid), .e_axi_arready(sb_arready), .e_axi_rdata(sb_rdata),
        .e_axi_rvalid(sb_rvalid), .e_axi_rlast(sb_rlast), .e_axi_rready(sb_rready),
        .e_axi_awaddr(sb_awaddr), .e_axi_awlen(sb_awlen), .e_axi_awsize(sb_awsize), .e_axi_awburst(sb_awburst),
        .e_axi_awvalid(sb_awvalid), .e_axi_awready(sb_awready), .e_axi_wdata(sb_wdata), .e_axi_wstrb(sb_wstrb),
        .e_axi_wlast(sb_wlast), .e_axi_wvalid(sb_wvalid), .e_axi_wready(sb_wready),
        .e_axi_bvalid(sb_bvalid), .e_axi_bready(sb_bready)
    );

    gp0_axi_mux u_mux (
        .clk(clk), .rst(rst),
        .m0_araddr(sb_araddr), .m0_arlen(sb_arlen), .m0_arsize(sb_arsize), .m0_arburst(sb_arburst),
        .m0_arvalid(sb_arvalid), .m0_arready(sb_arready), .m0_rdata(sb_rdata), .m0_rvalid(sb_rvalid),
        .m0_rlast(sb_rlast), .m0_rready(sb_rready),
        .m0_awaddr(sb_awaddr), .m0_awlen(sb_awlen), .m0_awsize(sb_awsize), .m0_awburst(sb_awburst),
        .m0_awvalid(sb_awvalid), .m0_awready(sb_awready), .m0_wdata(sb_wdata), .m0_wstrb(sb_wstrb),
        .m0_wlast(sb_wlast), .m0_wvalid(sb_wvalid), .m0_wready(sb_wready),
        .m0_bvalid(sb_bvalid), .m0_bready(sb_bready),
        .m1_araddr(mc_araddr), .m1_arlen(mc_arlen), .m1_arsize(mc_arsize), .m1_arburst(mc_arburst),
        .m1_arvalid(mc_arvalid), .m1_arready(mc_arready), .m1_rdata(mc_rdata), .m1_rvalid(mc_rvalid),
        .m1_rlast(mc_rlast), .m1_rready(mc_rready),
        .m1_awaddr(mc_awaddr), .m1_awlen(mc_awlen), .m1_awsize(mc_awsize), .m1_awburst(mc_awburst),
        .m1_awvalid(mc_awvalid), .m1_awready(mc_awready), .m1_wdata(mc_wdata), .m1_wstrb(mc_wstrb),
        .m1_wlast(mc_wlast), .m1_wvalid(mc_wvalid), .m1_wready(mc_wready),
        .m1_bvalid(mc_bvalid), .m1_bready(mc_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata), .s_rvalid(s_rvalid),
        .s_rlast(s_rlast), .s_rready(s_rready),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awvalid(s_awvalid), .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bvalid(s_bvalid), .s_bready(s_bready)
    );

    // ---- DDR burst-slave model on the shared s_* port (as tb_mathcop) --------
    logic [63:0] mem [0:MEMW-1];
    function automatic int midx(input [31:0] a); midx = (a - MATH_BASE) >> 3; endfunction

    logic rbusy=0; logic [31:0] rcur; logic [8:0] rcnt;
    always_ff @(posedge clk) begin
        if (rst) begin s_arready<=0; s_rvalid<=0; s_rlast<=0; rbusy<=0; end
        else begin
            s_arready <= !rbusy;
            if (s_arvalid && s_arready) begin rbusy<=1; rcur<=s_araddr; rcnt<=s_arlen+1; s_arready<=0; end
            if (rbusy && (!s_rvalid || s_rready)) begin
                s_rdata  <= rcur[2] ? mem[midx(rcur)][63:32] : mem[midx(rcur)][31:0];
                s_rvalid <= 1; s_rlast <= (rcnt==1);
                rcur     <= rcur+4; rcnt <= rcnt-1;
                if (rcnt==1) rbusy<=0;
            end else if (s_rvalid && s_rready) begin s_rvalid<=0; s_rlast<=0; end
        end
    end

    logic wbusy=0; logic [31:0] wcur;
    always_ff @(posedge clk) begin
        if (rst) begin s_awready<=0; s_wready<=0; s_bvalid<=0; wbusy<=0; end
        else begin
            s_awready <= !wbusy;
            if (s_awvalid && s_awready) begin wbusy<=1; wcur<=s_awaddr; s_awready<=0; end
            s_wready <= wbusy;
            if (wbusy && s_wvalid && s_wready) begin
                for (int b=0;b<4;b++) if (s_wstrb[b])
                    mem[midx(wcur)][(wcur[2]*32)+b*8 +: 8] <= s_wdata[b*8+:8];
                wcur <= wcur+4;
                if (s_wlast) begin wbusy<=0; s_wready<=0; s_bvalid<=1; end
            end
            if (s_bvalid && s_bready) s_bvalid<=0;
        end
    end

    int errors = 0;

    // ---- helpers (math side, as tb_mathcop) ----
    task automatic mc_write(input [12:0] a, input [7:0] d);
        @(posedge clk_cpu); mc_cpu_addr<=a; mc_cpu_wdata<=d; mc_cpu_we<=1;
        @(posedge clk_cpu); mc_cpu_we<=0;
    endtask
    task automatic mc_read(input [12:0] a, output [7:0] d);
        @(posedge clk_cpu); mc_cpu_addr<=a; mc_cpu_we<=0;
        @(posedge clk_cpu); @(posedge clk_cpu); d=mc_cpu_rdata;
    endtask
    task automatic mc_do_exec; @(posedge clk_cpu); mc_exec_we<=1; @(posedge clk_cpu); mc_exec_we<=0; endtask
    task automatic mc_set_chunk(input [7:0] c);
        @(posedge clk_cpu); mc_chunk_wval<=c; mc_chunk_we<=1; @(posedge clk_cpu); mc_chunk_we<=0;
    endtask
    task automatic mc_a9_done(input [7:0] chunk, input [7:0] first, input [7:0] cnt);
        @(posedge clk); mc_done_word<={cnt, first, chunk}; mc_done_we<=1; @(posedge clk); mc_done_we<=0;
    endtask
    task automatic mc_pop; @(posedge clk); mc_evt_pop<=1; @(posedge clk); mc_evt_pop<=0; endtask
    task automatic mc_wait_ready; int g; g=0; repeat (2) @(posedge clk_cpu);
        while (mc_ready!==1'b1) begin @(posedge clk_cpu); g++; if(g>500000) begin $display("FAIL: mc ready timeout"); errors++; break; end end
    endtask
    task automatic mc_wait_done; int g; g=0; repeat (2) @(posedge clk_cpu);
        while (mc_done!==1'b1) begin @(posedge clk_cpu); g++; if(g>500000) begin $display("FAIL: mc done timeout"); errors++; break; end end
    endtask
    task automatic mc_wait_event; int g; g=0;
        while (mc_evt_irq!==1'b1) begin @(posedge clk); g++; if(g>500000) begin $display("FAIL: mc event timeout"); errors++; break; end end
    endtask

    // screen: read one CPU-BRAM byte
    task automatic sb_read(input [12:0] a, output [7:0] d);
        @(posedge clk_cpu); sb_cpu_addr<=a; sb_cpu_we<=0;
        @(posedge clk_cpu); @(posedge clk_cpu); d=sb_cpu_rdata;
    endtask
    task automatic sb_set_bank(input [7:0] c);
        @(posedge clk_cpu); sb_bank_wval<=c; sb_bank_we<=1; @(posedge clk_cpu); sb_bank_we<=0;
    endtask
    task automatic sb_wait_ready; int g; g=0; repeat (2) @(posedge clk_cpu);
        while (sb_ready!==1'b1) begin @(posedge clk_cpu); g++; if(g>500000) begin $display("FAIL: sb ready timeout"); errors++; break; end end
    endtask

    function automatic [7:0] mpatt(input [7:0] c, input int w, input int b); mpatt = (mem[c*WORDS + w] >> (b*8)); endfunction
    // screen chunk c lives at SCREEN_BASE + c*8KB = math-word offset (0x10000>>3)+c*WORDS
    localparam int SB_WOFF = (SCREEN_BASE - MATH_BASE) >> 3;
    function automatic [7:0] spatt(input [7:0] c, input int w, input int b); spatt = (mem[SB_WOFF + c*WORDS + w] >> (b*8)); endfunction

    initial begin
        logic [7:0] d, e;

        // preload: math chunks 1..3, screen chunks 1..3 — distinct patterns
        for (int w=0; w<MEMW; w++) mem[w] = 64'd0;
        for (int c=1;c<4;c++) for (int w=0;w<WORDS;w++)
            mem[c*WORDS+w]         = {32'(c)*32'h0101_0101, 16'hED00 | c[7:0], w[15:0]};
        for (int c=1;c<4;c++) for (int w=0;w<WORDS;w++)
            mem[SB_WOFF+c*WORDS+w] = {32'(c)*32'h1010_1010, 16'h5B00 | c[7:0], w[15:0]};
        repeat (8) @(posedge clk); rst<=0; repeat (4) @(posedge clk);

        // ================= A) math THROUGH the mux, screen idle =================
        $display("[A] math via mux, screen idle");

        // A1 fill chunk 1 -> read a byte back through the mux
        mc_set_chunk(8'd1); mc_wait_ready();
        mc_read(13'h0010, d);                              // word 2, byte 0
        if (d !== mpatt(1,2,0)) begin $display("FAIL A-fill: got %02x want %02x", d, mpatt(1,2,0)); errors++; end
        else $display("  A fill ok (byte=%02x)", d);

        // A2 dirty + EXEC -> flush -> A9 result -> span reload -> read result back
        mc_write(13'h0010, 8'hA5);
        mc_do_exec(); mc_wait_event(); mc_pop();
        if (mem[1*WORDS+2][7:0] !== 8'hA5) begin $display("FAIL A: flush lost dirty byte"); errors++; end
        mem[1*WORDS+40] = 64'h1122_3344_5566_7788;         // A9 result: line 5, word 40
        mem[1*WORDS+0]  = 64'h0000_0000_0100_0000;         // A9 status = 0x01 at page byte 3 (MC_OFF_STATUS)
        mc_a9_done(8'd1, 8'd0, 8'd6);                       // reload lines 0..5
        mc_wait_done();
        mc_read(13'h0003, d);                              // STATUS byte
        if (d !== 8'h01) begin $display("FAIL A-status: got %02x want 01 (0x82 = the HW bug)", d); errors++; end
        else $display("  A status ok (%02x)", d);
        mc_read(13'h0140, d);                              // result low byte (word 40, byte 0)
        if (d !== 8'h88) begin $display("FAIL A-reload: got %02x want 88", d); errors++; end
        else $display("  A reload ok (byte=%02x)", d);

        // ============== B) math reload WITH concurrent screen fill ==============
        $display("[B] math reload + concurrent screen_bank fill (arbitration)");
        // kick a screen chunk fill (long: 128 bursts) so it is mid-burst on the
        // shared port while math issues its own bursts.
        sb_set_bank(8'd2);
        // immediately drive math: dirty + exec + done reload, overlapping screen.
        mc_write(13'h0020, 8'h5A);                         // dirty line 0, word 4
        mem[1*WORDS+4]  = 64'h0000_0000_0000_005A;
        mc_do_exec(); mc_wait_event(); mc_pop();
        mem[1*WORDS+48] = 64'hAABB_CCDD_EEFF_0099;         // result line 6, word 48
        mem[1*WORDS+0]  = 64'h0000_0000_0000_0001;
        mc_a9_done(8'd1, 8'd0, 8'd7);
        mc_wait_done();
        mc_read(13'h0180, d);                              // word 48, byte 0
        if (d !== 8'h99) begin $display("FAIL B-math: got %02x want 99", d); errors++; end
        else $display("  B math reload ok (byte=%02x)", d);
        // screen must have filled chunk 2 correctly despite losing arbitration
        sb_wait_ready();
        sb_read(13'h0030, e);                              // screen word 6, byte 0
        if (e !== spatt(2,6,0)) begin $display("FAIL B-scrn: got %02x want %02x", e, spatt(2,6,0)); errors++; end
        else $display("  B screen fill ok (byte=%02x)", e);

        if (errors==0) $display("*** GP0MUX OK ***");
        else           $display("FAIL: tb_gp0_mux %0d error(s)", errors);
        $finish;
    end

    initial begin #40_000_000; $display("FAIL: watchdog"); $finish; end
endmodule
`default_nettype wire
