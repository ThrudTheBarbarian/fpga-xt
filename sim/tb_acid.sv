`timescale 1ns/1ps
`default_nettype none
//
// tb_acid — run one ACID800 standalone test against the ANTIC rewrite.
//
// The board runs these through xexload with a hardware breakpoint at the ACID
// framework's _testEnd, then classifies the Y register: _testPassed leaves Y at
// $00 and _testFailed at $80. This is the same arrangement in simulation, so a
// test can be run against the rewrite before the new path exists in a
// bitstream.
//
// tools/acid2mem.py produces acid.mem (the 64K image, with a stack-setting stub
// at $0700 and the reset vector aimed at it) and acid_cfg.mem (the _testEnd
// address out of the test's own .lab, because it moves between builds).
//
// A standalone ANTIC test needs nothing but RAM and the display chips — the
// framework's _waitVBL polls VCOUNT and touches no OS, no POKEY and no PIA.
// Reads of other hardware pages return $FF, which is what an unpopulated bus
// gives.
//
module tb_acid;

    logic clk = 0, rst = 1, cold = 0;
    always #5 clk = ~clk;

    // The real ratio: 56 fabric clocks per machine cycle.
    logic [5:0] phase = 6'd0;
    logic       tick, px_tick;
    always_ff @(posedge clk) begin
        phase   <= (phase == 6'd55) ? 6'd0 : phase + 6'd1;
        tick    <= (phase == 6'd55);
        px_tick <= (phase == 6'd13) || (phase == 6'd27) ||
                   (phase == 6'd41) || (phase == 6'd55);
    end

    wire [15:0] cpu_addr, antic_addr;
    wire [7:0]  cpu_wdata;
    wire        cpu_we;
    logic [7:0] cpu_rdata, antic_rdata;

    wire        lb_wr, lb_line_start, dma_steal, rdy_n, nmi_n, sync;
    wire [7:0]  lb_color;
    wire [15:0] dbg_pc;
    wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p;
    wire [6:0]  hcount;
    wire [8:0]  line;

    a8_core dut (
        .clk(clk), .rst(rst), .cold(cold),
        .tick(tick), .px_tick(px_tick),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_we(cpu_we),
        .cpu_rdata(cpu_rdata),
        .antic_addr(antic_addr), .antic_rdata(antic_rdata),
        .irq_n(1'b1),
        .trig0(8'h01), .trig1(8'h01), .trig2(8'h01), .trig3(8'h01),
        .pal_sense(8'h0E), .consol_keys(8'hFF),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .dma_steal(dma_steal), .rdy_n(rdy_n), .nmi_n(nmi_n), .sync(sync),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p),
        .hcount(hcount), .line(line)
    );

    logic [7:0] mem [0:65535];
    logic [15:0] cfg [0:0];

    // $D000-$D0FF and $D400-$D4FF are answered inside a8_core; anything else in
    // the hardware page reads as an unpopulated bus.
    wire in_hw   = (cpu_addr[15:8] >= 8'hD0) && (cpu_addr[15:8] <= 8'hD7);
    wire is_chip = (cpu_addr[15:8] == 8'hD0) || (cpu_addr[15:8] == 8'hD4);

    always_ff @(posedge clk) begin
        if (cpu_we && !in_hw) mem[cpu_addr] <= cpu_wdata;
        cpu_rdata   <= (in_hw && !is_chip) ? 8'hFF : mem[cpu_addr];
        antic_rdata <= mem[antic_addr];
    end

    logic [15:0] test_end;
    int          guard;
    logic        done;

    // Progress, so a hang is distinguishable from a slow test.  Without this a
    // stuck run and a long one look identical from outside.
    wire frame_top = tick && (hcount == 7'd0) && (line == 9'd0);

    // Trap the moment the CPU leaves the loaded image: that tells a framework
    // dependency (a jump into OS ROM) apart from a bug in the design under test
    // (a jump into nowhere).
    logic [15:0] pc_d;
    int          traps;
    always_ff @(posedge clk) begin
        if (rst) begin
            pc_d <= 16'h0700; traps <= 0;
        end else if (sync && tick) begin
            pc_d <= dbg_pc;
            if (traps < 12 &&
                (dbg_pc < 16'h0700 || dbg_pc > 16'h3FFF) &&
                (pc_d  >= 16'h0700 && pc_d  <= 16'h3FFF)) begin
                $display("  [left the image] $%04h -> $%04h  a=$%02h x=$%02h y=$%02h s=$%02h",
                         pc_d, dbg_pc, dbg_a, dbg_x, dbg_y, dbg_s);
                traps <= traps + 1;
            end
        end
    end

    int frames;
    always_ff @(posedge clk) begin
        if (rst) frames <= 0;
        else if (frame_top) begin
            frames <= frames + 1;
            if (frames % 20 == 0)
                $display("  [frame %0d] pc=$%04h a=$%02h x=$%02h y=$%02h",
                         frames, dbg_pc, dbg_a, dbg_x, dbg_y);
        end
    end

    initial begin
        $readmemh("acid.mem", mem);
        $readmemh("acid_cfg.mem", cfg);
        test_end = cfg[0];
        done = 1'b0;

        repeat (4) @(posedge clk);
        rst = 0;

        // The framework waits several frames; give it plenty and fail loudly
        // rather than hanging if it never reaches the end.
        // ~30 frames is generous: the framework waits a handful.
        guard = 0;
        while (!done && guard < 60_000_000) begin
            @(posedge clk);
            guard++;
            if (sync && tick && (dbg_pc == test_end)) done = 1'b1;
        end

        if (!done) begin
            $display("ACID %s: TIMEOUT (pc $%04h, never reached _testEnd $%04h)",
                     `TESTNAME, dbg_pc, test_end);
            $display("tb_acid: 1 FAIL");
        end else if (dbg_y == 8'h00) begin
            $display("ACID %s: PASS", `TESTNAME);
            $display("tb_acid: all checks PASS");
        end else begin
            $display("ACID %s: FAIL (Y=$%02h)", `TESTNAME, dbg_y);
            $display("tb_acid: 1 FAIL");
        end
        $finish;
    end

endmodule

`default_nettype wire
