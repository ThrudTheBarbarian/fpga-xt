// tb_screen_bank.sv — exercise the dual CPU/ANTIC banked screen RAM engine.
//
//   1) fill  : switch CPU bank to 1 (clean) -> DDR[1] loads into CPU-BRAM.
//   2) flush : dirty a few CPU-BRAM bytes, switch to bank 2 -> the dirtied
//              bank-1 content is written back to DDR[1], DDR[2] loads in.
//   3) reload: write ANTIC bank 3 + VBI -> DDR[3] loads into ANTIC-BRAM.
// Each step checks BRAM contents (via the CPU/ANTIC ports) and DDR (the model).

`timescale 1ns/1ps
`default_nettype none

module tb_screen_bank;
    localparam logic [31:0] STACK_BASE = 32'h3400_0000;
    localparam int APE = 13, WORDS = 1024;

    logic clk = 0, clk_cpu = 0, clk_antic = 0, rst = 1;
    always #5    clk       = ~clk;       // 100 MHz engine
    always #5    clk_cpu   = ~clk_cpu;   // (same rate; CDC handshakes still exercised)
    always #3.4  clk_antic = ~clk_antic; // ~148 MHz

    // DUT signals
    logic [APE-1:0] cpu_addr=0;  logic cpu_we=0;  logic [7:0] cpu_wdata=0;  wire [7:0] cpu_rdata;
    logic [7:0] cpu_bank_wval=0; logic cpu_bank_we=0; wire ready;
    logic [APE-1:0] antic_addr=0; wire [7:0] antic_rdata;
    logic [7:0] antic_bank_wval=0; logic antic_bank_we=0; logic vbi=0;

    wire [31:0] araddr; wire [7:0] arlen; wire [2:0] arsize; wire [1:0] arburst;
    wire arvalid; logic arready; logic [63:0] rdata; logic rvalid; logic rlast; wire rready;
    wire [31:0] awaddr; wire [7:0] awlen; wire [2:0] awsize; wire [1:0] awburst;
    wire awvalid; logic awready; wire [63:0] wdata; wire [7:0] wstrb; wire wlast; wire wvalid;
    logic wready; logic bvalid; wire bready;

    screen_bank #(.STACK_BASE(STACK_BASE), .APERTURE_LOG2(APE)) dut (
        .clk(clk), .rst(rst),
        .clk_cpu(clk_cpu), .cpu_addr(cpu_addr), .cpu_we(cpu_we), .cpu_wdata(cpu_wdata),
        .cpu_rdata(cpu_rdata), .cpu_bank_wval(cpu_bank_wval), .cpu_bank_we(cpu_bank_we),
        .ready(ready),
        .clk_antic(clk_antic), .antic_addr(antic_addr), .antic_rdata(antic_rdata),
        .antic_bank_wval(antic_bank_wval), .antic_bank_we(antic_bank_we), .vbi(vbi),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready), .m_axi_rdata(rdata),
        .m_axi_rvalid(rvalid), .m_axi_rlast(rlast), .m_axi_rready(rready),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    // ---- DDR burst-slave model (4 chunks = 4096 words) ----
    localparam int MEMW = 4*WORDS;
    logic [63:0] mem [0:MEMW-1];
    function automatic int midx(input [31:0] a); midx = (a - STACK_BASE) >> 3; endfunction

    // read burst
    logic        rbusy=0; logic [31:0] rcur; logic [8:0] rcnt;
    always_ff @(posedge clk) begin
        if (rst) begin arready<=0; rvalid<=0; rlast<=0; rbusy<=0; end
        else begin
            arready <= !rbusy;
            if (arvalid && arready) begin rbusy<=1; rcur<=araddr; rcnt<=arlen+1; arready<=0; end
            if (rbusy && (!rvalid || rready)) begin
                rdata  <= mem[midx(rcur)];
                rvalid <= 1; rlast <= (rcnt==1);
                rcur   <= rcur+8; rcnt <= rcnt-1;
                if (rcnt==1) rbusy<=0;
            end else if (rvalid && rready) begin rvalid<=0; rlast<=0; end
        end
    end

    // write burst
    logic        wbusy=0; logic [31:0] wcur;
    always_ff @(posedge clk) begin
        if (rst) begin awready<=0; wready<=0; bvalid<=0; wbusy<=0; end
        else begin
            awready <= !wbusy;
            if (awvalid && awready) begin wbusy<=1; wcur<=awaddr; awready<=0; end
            wready <= wbusy;
            if (wbusy && wvalid && wready) begin
                for (int b=0;b<8;b++) if (wstrb[b]) mem[midx(wcur)][b*8+:8] <= wdata[b*8+:8];
                wcur <= wcur+8;
                if (wlast) begin wbusy<=0; wready<=0; bvalid<=1; end
            end
            if (bvalid && bready) bvalid<=0;
        end
    end

    int errors = 0;

    // ---- helpers ----
    task automatic cpu_set_bank(input [7:0] b);
        @(posedge clk_cpu); cpu_bank_wval<=b; cpu_bank_we<=1;
        @(posedge clk_cpu); cpu_bank_we<=0;
    endtask
    task automatic cpu_write(input [12:0] a, input [7:0] d);
        @(posedge clk_cpu); cpu_addr<=a; cpu_wdata<=d; cpu_we<=1;
        @(posedge clk_cpu); cpu_we<=0;
    endtask
    task automatic cpu_read(input [12:0] a, output [7:0] d);
        @(posedge clk_cpu); cpu_addr<=a; cpu_we<=0;
        @(posedge clk_cpu); @(posedge clk_cpu); d=cpu_rdata;
    endtask
    task automatic antic_read(input [12:0] a, output [7:0] d);
        @(posedge clk_antic); antic_addr<=a;
        @(posedge clk_antic); @(posedge clk_antic); d=antic_rdata;
    endtask
    task automatic wait_ready;
        int g; g=0;
        // ready drops a few cycles after the request crosses CDC — wait for that
        while (ready === 1'b1 && g < 100) begin @(posedge clk_cpu); g++; end
        g=0;
        while (ready !== 1'b1) begin @(posedge clk_cpu); g++; if (g>200000) begin
            $display("FAIL: ready timeout"); errors++; break; end end
    endtask

    // byte b of chunk c, word w (little-endian within the 64-bit word)
    function automatic [7:0] patt(input [7:0] c, input int w, input int b);
        patt = (mem[c*WORDS + w] >> (b*8));
    endfunction

    initial begin
        // preload chunks 1,2,3 with distinct patterns; chunk 0 = zero
        for (int c=0;c<4;c++) for (int w=0;w<WORDS;w++)
            mem[c*WORDS+w] = (c==0) ? 64'd0
                            : {32'(c)*32'h0101_0101, 16'hED00 | c[7:0], w[15:0]};
        repeat (8) @(posedge clk); rst<=0; repeat (4) @(posedge clk);

        // ---- 1) FILL: switch to bank 1 (clean) -> DDR[1] -> CPU-BRAM ----
        $display("[1] fill bank 1");
        cpu_set_bank(8'd1); wait_ready();
        begin logic [7:0] d; cpu_read(13'h0010, d);     // word 2, byte 0
            if (d !== patt(1,2,0)) begin $display("FAIL fill: got %02x want %02x", d, patt(1,2,0)); errors++; end
            else $display("  fill ok (byte=%02x)", d); end

        // ---- 2) FLUSH: dirty bytes, switch to bank 2 ----
        $display("[2] dirty + flush bank 1, fill bank 2");
        cpu_write(13'h0020, 8'hA5);          // dirty word 4 byte 0
        cpu_write(13'h0021, 8'h5A);          // dirty word 4 byte 1
        cpu_set_bank(8'd2); wait_ready();
        begin logic [7:0] d; cpu_read(13'h0030, d);     // CPU-BRAM now = bank 2
            if (d !== patt(2,6,0)) begin $display("FAIL fill2: got %02x want %02x", d, patt(2,6,0)); errors++; end
            else $display("  fill2 ok (byte=%02x)", d); end
        // DDR[1] word 4 must now hold the dirtied bytes
        if (mem[1*WORDS+4][7:0] !== 8'hA5 || mem[1*WORDS+4][15:8] !== 8'h5A) begin
            $display("FAIL flush: DDR[1].w4 = %016x (want low bytes 5AA5)", mem[1*WORDS+4]); errors++;
        end else $display("  flush ok (DDR[1].w4=%016x)", mem[1*WORDS+4]);

        // ---- 3) RELOAD: ANTIC bank 3 + VBI -> DDR[3] -> ANTIC-BRAM ----
        $display("[3] antic reload bank 3");
        @(posedge clk_cpu); antic_bank_wval<=8'd3; antic_bank_we<=1;
        @(posedge clk_cpu); antic_bank_we<=0;
        repeat (4) @(posedge clk_antic);
        @(posedge clk_antic); vbi<=1; @(posedge clk_antic); vbi<=0;
        repeat (4000) @(posedge clk);        // let the reload run
        begin logic [7:0] d; antic_read(13'h0018, d);   // word 3, byte 0
            if (d !== patt(3,3,0)) begin $display("FAIL reload: got %02x want %02x", d, patt(3,3,0)); errors++; end
            else $display("  reload ok (byte=%02x)", d); end

        if (errors==0) $display("*** SCREEN_BANK OK ***");
        else           $display("FAIL: tb_screen_bank %0d error(s)", errors);
        $finish;
    end

    initial begin #5_000_000; $display("FAIL: watchdog"); $finish; end
endmodule
`default_nettype wire
