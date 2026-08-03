`timescale 1ns/1ps
`default_nettype none
//
// NOT VALID YET — DO NOT TRUST RESULTS FROM THIS HARNESS.
//
// It runs the test image with NO OS ROM.  The ACID framework installs handlers
// in the OS vectors (VDSLST, VVBLKI) and relies on the OS ROM's NMI dispatcher
// at $FFFA to read NMIST and jump through them.  The XEX does not cover $FFFA —
// antic_vcount's segments are $1A20-$1F30, $2000-$21F2, $02E0-$02E1 — so with
// no ROM that vector is RAM, reads as zero, and the first DLI or VBI kills the
// machine.  There is also no VBI, no SIO and no E: handler.
//
// A result out of this harness therefore means nothing, and it will still print
// a confident PASS or FAIL, which is worse than printing nothing.
//
// What it needs to be real: RAM + the XL OS ROM at $C000 (rsrc/atari-xl.rom) +
// PIA for PORTB banking (pia_regs.sv) + POKEY (pokey.sv) + the display chips,
// cold-booted, with the XEX injected afterwards the way loader/test/freertos/
// progs/xexload.c does it on the board.  Every piece is already in the repo.
//
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

    reg [15:0] tune_v;

    // VCOUNT-read probe.  The open question after the WSYNC sweep is whether
    // the CPU reaches `lda $D40B` on the cycle the test's comments name, so
    // report the beam position at each such read.  Off unless +PROBE=1, so
    // ordinary runs are byte-identical.
    reg probe_on;
    always_ff @(posedge clk) begin
        if (probe_on && tick && !rst && dut.c_rw && (dut.c_addr == 16'hD40B))
            $display("PROBE vcount-read pc=%04h line=%0d hcount=%0d value=%02h",
                     dbg_pc, line, hcount, dut.reg_rdata);
    end

    // The SAME read, sampled where the CPU actually samples it: SUB_DATA,
    // N-7 fabric clocks into the machine cycle.  If this disagrees with the
    // boundary probe above on a given cycle, the register is changing MID
    // machine cycle and the CPU sees the far side of that change.
    always_ff @(posedge clk) begin
        if (probe_on && !rst && dut.c_rw && (dut.c_addr == 16'hD40B)
            && (dut.c_sub == 8'(dut.SUB_DATA)))
            $display("PROBE-SUB    pc=%04h line=%0d hcount=%0d value=%02h",
                     dbg_pc, line, hcount, dut.reg_rdata);
    end

    a8_core dut (
        .clk(clk), .rst(rst), .cold(cold),
        .tick(tick), .px_tick(px_tick), .tune(tune_v),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_we(cpu_we),
        .cpu_rdata(cpu_rdata),
        .antic_addr(antic_addr), .antic_rdata(antic_rdata),
        .irq_n(1'b1),
        .trig0(8'h01), .trig1(8'h01), .trig2(8'h01), .trig3(8'h01),
        .pal_sense(8'h0F), .consol_keys(8'hFF),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .dma_steal(dma_steal), .rdy_n(rdy_n), .nmi_n(nmi_n), .sync(sync),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p),
        .hcount(hcount), .line(line)
    );

    logic [7:0] mem [0:65535];
    logic [15:0] cfg [0:2];

    // $D000-$D0FF and $D400-$D4FF are answered inside a8_core; anything else in
    // the hardware page reads as an unpopulated bus.
    wire in_hw   = (cpu_addr[15:8] >= 8'hD0) && (cpu_addr[15:8] <= 8'hD7);
    wire is_chip = (cpu_addr[15:8] == 8'hD0) || (cpu_addr[15:8] == 8'hD4);

    always_ff @(posedge clk) begin
        if (cpu_we && !in_hw) mem[cpu_addr] <= cpu_wdata;
        cpu_rdata   <= (in_hw && !is_chip) ? 8'hFF : mem[cpu_addr];
        antic_rdata <= mem[antic_addr];
    end

    logic [15:0] test_end, t_pass, t_fail;
    logic        verdict_fail;
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
            // $FF00-$FFFF is the harness's own stub page (NMI/IRQ dispatcher,
            // RTCLOK ticker, the _vputchar RTS sink). Jumping there is CORRECT
            // and reporting it drowns the real derail -- the sink alone fires on
            // every character the suite prints.
            if (traps < 12 &&
                (dbg_pc < 16'h0700 || dbg_pc > 16'h3FFF) &&
                (dbg_pc < 16'hFF00) &&
                (pc_d  >= 16'h0700 && pc_d  <= 16'h3FFF)) begin
                $display("  [left the image] $%04h -> $%04h  a=$%02h x=$%02h y=$%02h s=$%02h",
                         pc_d, dbg_pc, dbg_a, dbg_x, dbg_y, dbg_s);
                traps <= traps + 1;
            end
        end
    end

    // ---- PC ring, dumped at the first FATAL derail ------------------------
    //
    // "It ended up at $00CA" says nothing; the TRAIL that got it there says
    // everything -- the software harness (emu/test/acid.c, PC_RING 64) was built
    // for exactly this and it is what turned three ACID mysteries into one-line
    // fixes. A PC below $0200 is the fatal signature: zero page and the stack
    // are full of zeros, every $00 is a BRK, and the CPU walks upward until it
    // hits a $02 and jams. Print once, then stop.
    localparam int PC_RING = 64;
    logic [15:0] ring [0:PC_RING-1];
    int          rn;
    int          derail_shown;
    always_ff @(posedge clk) begin
        if (rst) begin
            rn <= 0; derail_shown <= 0;
        end else if (sync && tick) begin
            ring[rn % PC_RING] <= dbg_pc;
            rn <= rn + 1;
            if (!derail_shown && dbg_pc < 16'h0200 && rn > PC_RING) begin
                derail_shown <= 1;
                $display("  *** DERAIL into $%04h after %0d instructions.  a=$%02h x=$%02h y=$%02h s=$%02h  trail (oldest first):", dbg_pc, rn, dbg_a, dbg_x, dbg_y, dbg_s);
                for (int k = 0; k < PC_RING; k++)
                    $write(" %04h", ring[(rn + k) % PC_RING]);
                $write("\n");
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

    // TESTNAME as a RUNTIME plusarg, not a compile-time -D: as a define, `make`
    // does not rebuild when it changes, so a sweep silently re-runs the previous
    // test -- and every test paid a full iverilog rebuild of ~25 RTL files.
    // One compile now serves all 63, which is what makes a full sweep practical.
    reg [8*40-1:0] tname;
    initial begin
        if (!$value$plusargs("TEST=%s", tname)) tname = "acid";
        // TUNE likewise a RUNTIME plusarg, and read HERE so it is stable before
        // reset is released a few lines below.
        if (!$value$plusargs("TUNE=%d", tune_v)) tune_v = 16'd0;
        if (!$value$plusargs("PROBE=%d", probe_on)) probe_on = 1'b0;
        $readmemh("acid.mem", mem);
        $readmemh("acid_cfg.mem", cfg);
        test_end  = cfg[0];
        t_pass    = cfg[1];
        t_fail    = cfg[2];
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
            // Score as the model does: the ADDRESS is the verdict.  Reaching
            // _testPassed or _testFailed is unambiguous and lands earlier than
            // _testEnd, which programs a POKEY timer and spins on IRQST.
            if (sync && tick && (dbg_pc == t_pass)) begin
                done = 1'b1; verdict_fail = 1'b0;
            end else if (sync && tick && (dbg_pc == t_fail)) begin
                done = 1'b1; verdict_fail = 1'b1;
            end
        end

        if (!done) begin
            $display("ACID %0s: TIMEOUT (pc $%04h, never reached _testEnd $%04h)",
                     tname, dbg_pc, test_end);
            $display("tb_acid: 1 FAIL");
        end else if (!verdict_fail) begin
            $display("ACID %0s: PASS", tname);
            $display("tb_acid: all checks PASS");
        end else begin
            $display("ACID %0s: FAIL (reached _testFailed $%04h)", tname, t_fail);
            $display("tb_acid: 1 FAIL");
        end
        // The result bytes, on EVERY path.  Without these a tune sweep prints
        // 16 identical verdict lines and a flat-looking result is indis-
        // tinguishable from an instrument that never reported anything.
        // NB d1 is CLOBBERED when assert #1 fails: _ASSERT1 does `sta d1`
        // before `jsr _testFailed`, so it holds a copy of the bad d0.
        $display("ACID %0s: d0=%02h d1=%02h d2=%02h d3=%02h",
                 tname, mem[16'h00C8], mem[16'h00C9], mem[16'h00CA], mem[16'h00CB]);
        $finish;
    end

endmodule

`default_nettype wire
