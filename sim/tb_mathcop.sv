// tb_mathcop.sv — exercise the math-coprocessor mailbox page (math_cop).
//
//   0) exec with no chunk resident  -> ignored, sticky stat[3]
//   1) chunk fill                   -> DDR[1] loads into the page
//   2) dirty + EXEC                 -> ONLY dirty lines flushed, doorbell event
//   2b) back-to-back EXEC           -> pending exec serviced (empty flush) = 2nd event
//   3) MATH_DONE span reload        -> A9 result lands in the page, done rises
//   4) MATH_DONE for a non-resident chunk -> ignored (no done, no reload)
//   5) chunk switch                 -> dirty spill to old, full fill from new
//   6) switch back                  -> step-3 results persist via DDR
// The A9 is modeled by poking the DDR array + driving done_we/evt_pop directly
// (same clk domain as xt_gp0_regs would).

`timescale 1ns/1ps
`default_nettype none

module tb_mathcop;
    localparam logic [31:0] STACK_BASE = 32'h2080_0000;
    localparam int APE = 13, WORDS = 1024;

    logic clk = 0, clk_cpu = 0, rst = 1;
    always #5 clk     = ~clk;       // 100 MHz engine
    always #5 clk_cpu = ~clk_cpu;   // (same rate; CDC handshakes still exercised)

    // DUT signals
    logic [APE-1:0] cpu_addr=0;  logic cpu_we=0;  logic [7:0] cpu_wdata=0;  wire [7:0] cpu_rdata;
    logic exec_we=0;  logic [7:0] chunk_wval=0;  logic chunk_we=0;
    wire  math_done, math_busy, chunk_ready;
    wire  [8:0] evt_data;  logic evt_pop=0;  wire evt_irq;
    logic [23:0] done_word=0;  logic done_we=0;
    wire  [31:0] stat_word;

    // 32-bit AXI3 (e_axi_*)
    wire [31:0] araddr; wire [3:0] arlen; wire [2:0] arsize; wire [1:0] arburst;
    wire arvalid; logic arready; logic [31:0] rdata; logic rvalid; logic rlast; wire rready;
    wire [31:0] awaddr; wire [3:0] awlen; wire [2:0] awsize; wire [1:0] awburst;
    wire awvalid; logic awready; wire [31:0] wdata; wire [3:0] wstrb; wire wlast; wire wvalid;
    logic wready; logic bvalid; wire bready;

    math_cop #(.STACK_BASE(STACK_BASE), .APERTURE_LOG2(APE)) dut (
        .clk(clk), .rst(rst),
        .clk_cpu(clk_cpu), .cpu_addr(cpu_addr), .cpu_we(cpu_we), .cpu_wdata(cpu_wdata),
        .cpu_rden(1'b1), .cpu_rdata(cpu_rdata),
        .exec_we(exec_we), .chunk_wval(chunk_wval), .chunk_we(chunk_we),
        .math_done(math_done), .math_busy(math_busy), .chunk_ready(chunk_ready),
        .evt_data(evt_data), .evt_pop(evt_pop), .evt_irq(evt_irq),
        .done_word(done_word), .done_we(done_we), .stat_word(stat_word),
        .e_axi_araddr(araddr), .e_axi_arlen(arlen), .e_axi_arsize(arsize), .e_axi_arburst(arburst),
        .e_axi_arvalid(arvalid), .e_axi_arready(arready), .e_axi_rdata(rdata),
        .e_axi_rvalid(rvalid), .e_axi_rlast(rlast), .e_axi_rready(rready),
        .e_axi_awaddr(awaddr), .e_axi_awlen(awlen), .e_axi_awsize(awsize), .e_axi_awburst(awburst),
        .e_axi_awvalid(awvalid), .e_axi_awready(awready), .e_axi_wdata(wdata), .e_axi_wstrb(wstrb),
        .e_axi_wlast(wlast), .e_axi_wvalid(wvalid), .e_axi_wready(wready),
        .e_axi_bvalid(bvalid), .e_axi_bready(bready)
    );

    // ---- DDR burst-slave model (as tb_screen_bank) --------------------------
    localparam int MEMW = 4*WORDS;   // chunks 0..3
    logic [63:0] mem [0:MEMW-1];
    function automatic int midx(input [31:0] a); midx = (a - STACK_BASE) >> 3; endfunction

    logic        rbusy=0; logic [31:0] rcur; logic [8:0] rcnt;
    always_ff @(posedge clk) begin
        if (rst) begin arready<=0; rvalid<=0; rlast<=0; rbusy<=0; end
        else begin
            arready <= !rbusy;
            if (arvalid && arready) begin rbusy<=1; rcur<=araddr; rcnt<=arlen+1; arready<=0; end
            if (rbusy && (!rvalid || rready)) begin
                rdata  <= rcur[2] ? mem[midx(rcur)][63:32] : mem[midx(rcur)][31:0];
                rvalid <= 1; rlast <= (rcnt==1);
                rcur   <= rcur+4; rcnt <= rcnt-1;
                if (rcnt==1) rbusy<=0;
            end else if (rvalid && rready) begin rvalid<=0; rlast<=0; end
        end
    end

    logic        wbusy=0; logic [31:0] wcur;
    always_ff @(posedge clk) begin
        if (rst) begin awready<=0; wready<=0; bvalid<=0; wbusy<=0; end
        else begin
            awready <= !wbusy;
            if (awvalid && awready) begin wbusy<=1; wcur<=awaddr; awready<=0; end
            wready <= wbusy;
            if (wbusy && wvalid && wready) begin
                for (int b=0;b<4;b++) if (wstrb[b])
                    mem[midx(wcur)][(wcur[2]*32)+b*8 +: 8] <= wdata[b*8+:8];
                wcur <= wcur+4;
                if (wlast) begin wbusy<=0; wready<=0; bvalid<=1; end
            end
            if (bvalid && bready) bvalid<=0;
        end
    end

    int errors = 0;

    // ---- helpers ----
    task automatic cpu_write(input [12:0] a, input [7:0] d);
        @(posedge clk_cpu); cpu_addr<=a; cpu_wdata<=d; cpu_we<=1;
        @(posedge clk_cpu); cpu_we<=0;
    endtask
    task automatic cpu_read(input [12:0] a, output [7:0] d);
        @(posedge clk_cpu); cpu_addr<=a; cpu_we<=0;
        @(posedge clk_cpu); @(posedge clk_cpu); d=cpu_rdata;
    endtask
    task automatic do_exec;
        @(posedge clk_cpu); exec_we<=1;
        @(posedge clk_cpu); exec_we<=0;
    endtask
    task automatic set_chunk(input [7:0] c);
        @(posedge clk_cpu); chunk_wval<=c; chunk_we<=1;
        @(posedge clk_cpu); chunk_we<=0;
    endtask
    task automatic a9_done(input [7:0] chunk, input [7:0] first, input [7:0] cnt);
        @(posedge clk); done_word<={cnt, first, chunk}; done_we<=1;
        @(posedge clk); done_we<=0;
    endtask
    task automatic pop_event;
        @(posedge clk); evt_pop<=1;
        @(posedge clk); evt_pop<=0;
    endtask
    task automatic wait_chunk_ready;
        int g; g=0;
        // give the ready-mask its clk_cpu edge before polling (a real 6502's
        // next read is always >=1 cycle after the write anyway)
        repeat (2) @(posedge clk_cpu);
        while (chunk_ready !== 1'b1) begin @(posedge clk_cpu); g++; if (g>500000) begin
            $display("FAIL: chunk_ready timeout"); errors++; break; end end
    endtask
    task automatic wait_done;
        int g; g=0;
        repeat (2) @(posedge clk_cpu);
        while (math_done !== 1'b1) begin @(posedge clk_cpu); g++; if (g>500000) begin
            $display("FAIL: done timeout"); errors++; break; end end
    endtask
    task automatic wait_event;
        int g; g=0;
        while (evt_irq !== 1'b1) begin @(posedge clk); g++; if (g>500000) begin
            $display("FAIL: event timeout"); errors++; break; end end
    endtask

    // byte b of chunk c, word w
    function automatic [7:0] patt(input [7:0] c, input int w, input int b);
        patt = (mem[c*WORDS + w] >> (b*8));
    endfunction

    initial begin
        logic [7:0] d;

        // preload chunks 1,2,3 with distinct patterns; chunk 0 = zero
        for (int c=0;c<4;c++) for (int w=0;w<WORDS;w++)
            mem[c*WORDS+w] = (c==0) ? 64'd0
                            : {32'(c)*32'h0101_0101, 16'hED00 | c[7:0], w[15:0]};
        repeat (8) @(posedge clk); rst<=0; repeat (4) @(posedge clk);

        // ---- 0) EXEC with no chunk resident -> ignored + sticky stat[3] ----
        $display("[0] exec with no chunk");
        do_exec(); repeat (20) @(posedge clk);
        if (evt_irq !== 1'b0) begin $display("FAIL: doorbell fired with no chunk"); errors++; end
        else if (stat_word[3] !== 1'b1) begin $display("FAIL: exec_nochunk sticky not set"); errors++; end
        else $display("  no-chunk exec ignored ok");

        // ---- 1) chunk fill ----
        $display("[1] fill chunk 1");
        set_chunk(8'd1); wait_chunk_ready();
        cpu_read(13'h0010, d);                          // word 2, byte 0
        if (d !== patt(1,2,0)) begin $display("FAIL fill: got %02x want %02x", d, patt(1,2,0)); errors++; end
        else $display("  fill ok (byte=%02x)", d);

        // ---- 2) dirty two lines + EXEC -> dirty-only flush + doorbell ----
        $display("[2] dirty + exec (flush only dirty lines)");
        // sentinel in DDR[1] line 12 (words 96-103): the CPU never touches line
        // 12, so a whole-page (or wrong-line) flush would overwrite it.
        mem[1*WORDS+100] = 64'hDEAD_BEEF_CAFE_F00D;
        cpu_write(13'h0010, 8'hA5);                     // line 0, word 2
        cpu_write(13'h0451, 8'h5A);                     // line 17 (0x440-0x47F), word 138
        do_exec();
        wait_event();
        if (evt_data !== {1'b1, 8'd1}) begin $display("FAIL: evt=%03x want 101", evt_data); errors++; end
        else $display("  doorbell ok (chunk 1)");
        if (mem[1*WORDS+2][7:0] !== 8'hA5) begin $display("FAIL: DDR missed line-0 dirty byte"); errors++; end
        if (mem[1*WORDS+138][15:8] !== 8'h5A) begin $display("FAIL: DDR missed line-17 dirty byte"); errors++; end
        if (mem[1*WORDS+100] !== 64'hDEAD_BEEF_CAFE_F00D) begin
            $display("FAIL: clean line 12 was flushed (sentinel lost)"); errors++;
        end else $display("  dirty-only flush ok (sentinel intact)");
        pop_event();
        repeat (4) @(posedge clk);
        if (evt_irq !== 1'b0) begin $display("FAIL: evt_irq stuck after pop"); errors++; end

        // ---- 2b) back-to-back EXEC (second queues; empty flush) ----
        $display("[2b] exec while idle-dirty-empty (pending path)");
        do_exec(); do_exec();       // second lands while the first may still flush
        wait_event(); pop_event();
        wait_event(); pop_event();  // both doorbells arrive
        repeat (4) @(posedge clk);
        if (evt_irq !== 1'b0) begin $display("FAIL: >2 events queued"); errors++; end
        else $display("  double exec ok (2 events)");

        // ---- 3) MATH_DONE -> span reload + done ----
        $display("[3] done: reload result span (line 5)");
        mem[1*WORDS+40] = 64'h1122_3344_5566_7788;      // A9 writes result: line 5, word 40
        a9_done(8'd1, 8'd5, 8'd1);
        wait_done();
        cpu_read(13'h0140, d);                          // 0x140 = word 40, byte 0
        if (d !== 8'h88) begin $display("FAIL reload: got %02x want 88", d); errors++; end
        else $display("  span reload ok (done high, byte=%02x)", d);

        // ---- 4) MATH_DONE for non-resident chunk -> ignored ----
        $display("[4] done for wrong chunk ignored");
        do_exec(); wait_event(); pop_event();           // clears done, rings again
        repeat (4) @(posedge clk_cpu);
        if (math_done !== 1'b0) begin $display("FAIL: done not cleared by exec"); errors++; end
        a9_done(8'd3, 8'd0, 8'd1);
        repeat (100) @(posedge clk);
        if (math_done !== 1'b0) begin $display("FAIL: done rose for wrong chunk"); errors++; end
        else $display("  wrong-chunk done ignored ok");
        a9_done(8'd1, 8'd0, 8'd0);                      // real completion, no span
        wait_done();

        // ---- 5) chunk switch: spill dirty to 1, fill all from 2 ----
        $display("[5] switch to chunk 2 (spill + fill)");
        cpu_write(13'h0020, 8'hEE);                     // dirty line 0, word 4
        set_chunk(8'd2); wait_chunk_ready();
        cpu_read(13'h0030, d);                          // page now = chunk 2
        if (d !== patt(2,6,0)) begin $display("FAIL fill2: got %02x want %02x", d, patt(2,6,0)); errors++; end
        else $display("  fill2 ok (byte=%02x)", d);
        if (mem[1*WORDS+4][7:0] !== 8'hEE) begin $display("FAIL: spill missed dirty byte"); errors++; end
        else $display("  spill ok (DDR[1].w4=%02x)", mem[1*WORDS+4][7:0]);

        // ---- 6) switch back: step-3 results persist via DDR ----
        $display("[6] switch back to chunk 1 (results persist)");
        set_chunk(8'd1); wait_chunk_ready();
        cpu_read(13'h0140, d);
        if (d !== 8'h88) begin $display("FAIL persist: got %02x want 88", d); errors++; end
        else $display("  persist ok");

        if (errors==0) $display("*** MATHCOP OK ***");
        else           $display("FAIL: tb_mathcop %0d error(s)", errors);
        $finish;
    end

    initial begin #20_000_000; $display("FAIL: watchdog"); $finish; end
endmodule
`default_nettype wire
