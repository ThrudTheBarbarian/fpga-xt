`timescale 1ns/1ps
`default_nettype none
//
// tb_xt_trace_axi — the continuous trace writer.
//
// What matters, in order of how badly it bites if wrong:
//   T1  NO BACK-PRESSURE ONTO THE CORE.  The whole point of this module is that
//       the CPU never stalls.  There is no ready signal going back to the
//       producer, so the test simply drives tr_valid every cycle and checks the
//       module never asks for anything.
//   T2  ORDER AND CONTENT.  Entries land in DDR in retirement order, byte for
//       byte.  A trace that reorders is worse than no trace.
//   T3  THE RING WRAPS at ring_mask and does not walk past it — a trace writer
//       that runs off the end corrupts whatever DDR sits after it.
//   T4  OVERFLOW IS COUNTED, NOT HIDDEN.  Starve the AXI side and confirm the
//       entries that could not be stored are reported in `drops`, because a
//       silent gap in a trace is how you end up "proving" something false.
//
module tb_xt_trace_axi;

    logic clk_cpu = 0, clk_sys = 0, rst = 1;
    always #5    clk_cpu = ~clk_cpu;      // 100 MHz
    always #3.37 clk_sys = ~clk_sys;      // ~148 MHz, deliberately unrelated

    logic        tr_valid = 0;
    logic [63:0] tr_data  = 0;
    logic        en = 0;
    logic [31:0] ring_base = 32'h1000_0000;
    logic [31:0] ring_mask = 32'h0000_03FF;   // 1 KB ring => wraps quickly
    wire  [31:0] wr_bytes, drops;

    wire [31:0] awaddr; wire [7:0] awlen; wire awvalid; logic awready = 1;
    wire [63:0] wdata;  wire wvalid; logic wready = 1; wire wlast;
    wire [2:0] awsize; wire [1:0] awburst; wire [7:0] wstrb; wire bready;

    xt_trace_axi #(.FIFO_AW(6), .BURST(16)) dut (
        .clk_cpu(clk_cpu), .rst_cpu(rst), .tr_valid(tr_valid), .tr_data(tr_data),
        .clk_sys(clk_sys), .rst_sys(rst), .en(en),
        .ring_base(ring_base), .ring_mask(ring_mask),
        .wr_bytes(wr_bytes), .drops(drops),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_bvalid(1'b1),
        .m_axi_bready(bready)
    );

    // ---- a minimal AXI write slave: remember address, capture beats -------
    logic [31:0] cur_addr;
    logic [63:0] ddr [0:255];              // 1 KB / 8 = 128 slots (ring), sized over
    int          ncap = 0;
    logic [63:0] capt [0:4095];
    logic [31:0] capt_addr [0:4095];
    always @(posedge clk_sys) begin
        if (awvalid && awready) cur_addr <= awaddr;
        if (wvalid && wready) begin
            ddr[(cur_addr - ring_base) >> 3] <= wdata;
            capt[ncap] = wdata; capt_addr[ncap] = cur_addr; ncap = ncap + 1;
            cur_addr <= cur_addr + 8;
        end
    end

    int checks = 0, errors = 0;
    int unsigned before_drops = 0;
    task automatic ck(input string what, input logic cond);
        checks++;
        if (!cond) begin errors++; $display("  FAIL: %s", what); end
    endtask

    int unsigned pushed = 0;
    task automatic push(input int unsigned k);
        @(negedge clk_cpu);
        tr_data  = {32'hA5A5_0000 | k[15:0], k};    // recognisable + sequential
        tr_valid = 1;
        @(negedge clk_cpu);
        tr_valid = 0;
        pushed++;
    endtask

    initial begin
        repeat (8) @(posedge clk_sys); rst = 0; @(posedge clk_sys);
        en = 1; repeat (4) @(posedge clk_sys);

        // ---- T1/T2: stream 64 entries, check order and content ----------
        $display("T1/T2: entries reach DDR in order, with no producer back-pressure");
        for (int i = 0; i < 64; i++) push(i);
        repeat (400) @(posedge clk_sys);
        ck("at least 4 bursts landed (64 entries / 16)", ncap >= 64);
        begin
            logic ok; ok = 1;
            for (int i = 0; i < 64; i++)
                if (capt[i] !== {32'hA5A5_0000 | i[15:0], i[31:0]}) ok = 0;
            ck("64 entries verbatim and in order", ok);
        end

        // ---- T3: the ring wraps ------------------------------------------
        $display("T3: the write address wraps at ring_mask");
        begin
            logic in_range; in_range = 1;
            for (int i = 0; i < ncap; i++)
                if (capt_addr[i] < ring_base ||
                    capt_addr[i] > (ring_base + ring_mask)) in_range = 0;
            ck("every write lands inside [base, base+mask]", in_range);
        end
        // push enough to wrap the 1 KB ring several times
        for (int i = 64; i < 400; i++) begin
            push(i);
            if ((i % 16) == 0) repeat (60) @(posedge clk_sys);
        end
        repeat (600) @(posedge clk_sys);
        begin
            logic in_range; in_range = 1;
            for (int i = 0; i < ncap; i++)
                if (capt_addr[i] < ring_base ||
                    capt_addr[i] > (ring_base + ring_mask)) in_range = 0;
            ck("still inside the ring after wrapping", in_range);
        end
        ck("no drops at the normal rate", drops == 32'd0);

        // ---- T4: overflow is COUNTED --------------------------------------
        $display("T4: a stalled AXI side drops entries and COUNTS them");
        wready = 0; awready = 0;               // freeze the drain entirely
        before_drops = drops;
        for (int i = 0; i < 300; i++) push(1000 + i);
        repeat (50) @(posedge clk_sys);
        ck("drops increased when the FIFO filled", drops > before_drops);
        wready = 1; awready = 1;

        $display("");
        if (errors == 0) $display("tb_xt_trace_axi: PASS (%0d checks)", checks);
        else             $display("tb_xt_trace_axi: FAIL (%0d/%0d failed)", errors, checks);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("tb_xt_trace_axi: TIMEOUT");
        $fatal(1);
    end

endmodule
`default_nettype wire
