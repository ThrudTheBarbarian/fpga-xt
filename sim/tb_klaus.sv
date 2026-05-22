// tb_klaus.sv — Klaus Dormann 6502 functional test against sally_core.
//
// This is the M24 ship-criterion smoke test. We load Klaus Dormann's
// `6502_functional_test.bin` (vendored at `sim/test_data/`) into a flat
// 64 KB memory, point reset at start ($0400), let the CPU run, and
// detect:
//
//   • SUCCESS — PC stuck at the success-trap address $3469 (a `JMP *`
//     loop the assembler placed at the end of the test program).
//   • FAILURE — PC stuck at any other address (Klaus's failure-trap
//     macros all expand to `JMP *`, so we can detect a stuck PC and
//     report the address; cross-reference the .lst to find the failing
//     subtest).
//
// The vendored binary's reset vector at $FFFC points to `res_trap`
// ($37A3) so a stray reset is caught — we PATCH the reset vector to
// $0400 in the testbench so SALLY actually starts the test.
//
// Memory model: a flat 64 KB BRAM driven directly by sally_core. We
// bypass `sally_mem`'s hwreg / bank-window / cache logic for this test
// because Klaus's program writes across the whole address space and
// we want a vanilla "everything is RAM" environment to validate the
// CPU itself. The test does not touch hardware registers; sally_mem's
// behaviour is covered by tb_sally_mem.

`timescale 1ns / 1ps

module tb_klaus;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- 64 KB main memory + separate 4 KB hidden stack ----------------
    // The hidden stack is modelled as its own array (as sally_mem does in
    // the production design), NOT as part of main memory.  Klaus's program
    // code occupies $0F00-$0FFF, which is exactly SALLY's top stack page
    // ({S_high=$F, SP}); if the stack lived in `mem` (a flat model), every
    // PHA/PHP/JSR would overwrite that code.  Routing stack ops to
    // stack_mem keeps the two disjoint, matching real hardware.
    logic [7:0] mem       [0:65535];
    logic [7:0] stack_mem [0:4095];

    // ---- sally_core wires ----------------------------------------------
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_dout;
    wire        cpu_rw;
    logic [7:0] cpu_din_q;

    wire        cpu_stack_op;
    wire [3:0]  cpu_s_high;

    sally_core u_cpu (
        .clk      (clk),
        .rst      (rst),
        .addr     (cpu_addr),
        .data_in  (cpu_din_q),
        .data_out (cpu_dout),
        .rw       (cpu_rw),
        .rdy      (1'b1),
        .irq_n    (1'b1),
        .nmi_n    (1'b1),
        .stack_op (cpu_stack_op),
        .s_high   (cpu_s_high)
    );

    // Synchronous-memory contract: addr cycle N, data cycle N+1; writes
    // commit at the same posedge.  Address routing (mirrors sally_mem):
    //   • Stack ops (cpu_stack_op): SALLY drives AB = {4'h0, S_high, SP},
    //     so the low 12 bits index the hidden stack directly.
    //   • Legacy $0100-$01FF (non-stack-op, e.g. Klaus's LDA $0101 to
    //     inspect the stack): aliased to the TOP stack page $F00-$FFF.
    //   • Everything else: main memory (code/data).
    wire        use_stack = cpu_stack_op || (cpu_addr[15:8] == 8'h01);
    wire [11:0] stk_idx   = cpu_stack_op ? cpu_addr[11:0]
                                         : {4'hF, cpu_addr[7:0]};

    always_ff @(posedge clk) begin
        if (!cpu_rw) begin
            if (use_stack) stack_mem[stk_idx] <= cpu_dout;
            else           mem[cpu_addr]      <= cpu_dout;
        end
        cpu_din_q <= use_stack ? stack_mem[stk_idx] : mem[cpu_addr];
    end

    // ---- Stuck-PC watchdog --------------------------------------------
    // Klaus's success / failure markers are all `JMP *` (a 3-byte JMP
    // to itself: $4C, lo, hi). The 3 byte addresses repeat forever.
    // Detect by sampling cpu_addr every cycle; if the SAME instruction
    // address (the lowest of the three) repeats consistently in a long
    // window, we're stuck. We track a sliding-window low watermark
    // instead of a histogram (full histogram[65536] is too expensive).
    int          cycle_count;
    int          stuck_count;
    logic [15:0] stuck_window_min;       // smallest addr seen in the current window
    logic [15:0] stuck_window_max;       // largest addr seen in the current window
    int          stuck_window_cycles;

    initial begin
        cycle_count          = 0;
        stuck_count          = 0;
        stuck_window_min     = 16'hFFFF;
        stuck_window_max     = 16'h0000;
        stuck_window_cycles  = 0;
    end

    // ---- Run -----------------------------------------------------------
    initial begin
        $display("=== M24-klaus Klaus Dormann 6502 functional test ===");
        $display("[load] reading sim/test_data/6502_functional_test.hex …");
        $readmemh("test_data/6502_functional_test.hex", mem);

        // Initialise the hidden stack.  Its top page (stack_mem[$F00-$FFF],
        // i.e. the legacy $0100-$01FF alias window) takes the binary's
        // $0100-$01FF stack sentinels; the deeper 3.75 KB starts at $00.
        // CRUCIALLY, mem[$0F00-$0FFF] is left holding the LOADED CODE — the
        // old flat model mirrored the $01xx sentinels over it (and stack
        // pushes then clobbered it too), destroying Klaus's program there.
        for (int i = 0; i < 4096; i++) stack_mem[i]              = 8'h00;
        for (int i = 0; i < 256;  i++) stack_mem[16'h0F00 + i]   = mem[16'h0100 + i];

        // Patch reset vector so PC starts at $0400 (Klaus's `start`
        // label = code_segment).
        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;

        // Drop Klaus test #$0E ("TSX sets NZ / proper stack wrap around",
        // $0D89-$0E45).  That subtest assumes a strict single 256-byte
        // stack page — pushing past SP_low=$00 must wrap back to $01FF in
        // the SAME page.  SALLY deliberately has a 12-bit SP / 4 KB stack
        // (deep pushes cross into hidden pages; see
        // docs/6502/6502-embellishments.md §1), so it is incompatible BY
        // DESIGN, not a CPU defect.  Overwrite the test body at $0D89 with
        // `LDX #$FF : TXS : JMP $0E46`: re-establish SP=$FFF and jump to
        // this test's next_test (which advances test_case $0E->$0F).
        // Every other Klaus subtest still runs and is a valid gate.
        mem[16'h0D89] = 8'hA2; mem[16'h0D8A] = 8'hFF;  // LDX #$FF
        mem[16'h0D8B] = 8'h9A;                         // TXS  (SP = $FFF)
        mem[16'h0D8C] = 8'h4C;                         // JMP $0E46
        mem[16'h0D8D] = 8'h46; mem[16'h0D8E] = 8'h0E;

        // Some basic sanity checks.
        if (mem[16'h0400] !== 8'hD8) begin
            $display("FAIL: $0400 = $%02h, expected $D8 (CLD) — bad image", mem[16'h0400]);
            $fatal(1);
        end
        $display("[load] image looks valid; starting CPU");

        repeat (4) @(posedge clk);
        rst = 1'b0;
    end

    // ---- Main monitoring loop -----------------------------------------
    // Klaus's test takes ~96 million 6502 cycles. Arlet's core uses
    // multiple sim clocks per 6502 cycle, and the decimal ADC/SBC
    // section iterates over all 100×100 BCD pairs — empirically the
    // test reaches the success trap around 80-150 M sim cycles. We
    // cap at 250 M for a comfortable margin.
    localparam int MAX_CYCLES = 250_000_000;
    localparam int STUCK_BUDGET = 200;          // consecutive same-addr cycles → stuck
    localparam logic [15:0] SUCCESS_TRAP = 16'h3469;

    logic [15:0] last_addr_q = 16'hFFFF;

    // Track the address-window over a STUCK_BUDGET-cycle slice. If the
    // PC remains within a 3-byte window for the entire slice, it's
    // looping on a `JMP *` and we're done.
    always_ff @(posedge clk) begin
        if (!rst) begin
            cycle_count <= cycle_count + 1;
            last_addr_q <= cpu_addr;
            if (cpu_addr < stuck_window_min) stuck_window_min <= cpu_addr;
            if (cpu_addr > stuck_window_max) stuck_window_max <= cpu_addr;
            stuck_window_cycles <= stuck_window_cycles + 1;
        end
    end

    initial begin
        @(negedge rst);
        forever begin
            // Sample window every STUCK_BUDGET cycles. If the address
            // range inside the window is ≤ 3 bytes, the PC is in a
            // `JMP *` loop. Reset the window between samples.
            repeat (STUCK_BUDGET) @(posedge clk);

            // Window range ≤ 2 alone isn't enough — a tight INX/BNE data
            // loop also stays in 3 bytes. Confirm the PC is inside a real
            // self-trap, which in Klaus is one of:
            //   • JMP self  ($4C lo hi, target == window_min) — the success
            //     trap ($3469) and some failure traps.
            //   • Bxx self  (a conditional-branch opcode + offset $FE) —
            //     Klaus's trap_xx failure macros (`bne *`, `beq *`, …).
            //     Branch opcodes are $10/$30/$50/$70/$90/$B0/$D0/$F0, i.e.
            //     (op & $1F) == $10.  Without this the watchdog ran the
            //     full 250M cycles on a branch-self failure instead of
            //     failing fast.
            if ((stuck_window_max - stuck_window_min) <= 16'd2
                && ( (mem[stuck_window_min]         == 8'h4C
                      && mem[stuck_window_min + 16'd1] == stuck_window_min[7:0]
                      && mem[stuck_window_min + 16'd2] == stuck_window_min[15:8])
                  || ((mem[stuck_window_min] & 8'h1F) == 8'h10
                      && mem[stuck_window_min + 16'd1] == 8'hFE) )) begin
                if (mem[stuck_window_min] == 8'h4C
                    && stuck_window_min == SUCCESS_TRAP) begin
                    $display("*** KLAUS OK *** PC reached success trap $%04h after %0d cycles",
                             stuck_window_min, cycle_count);
                    $finish;
                end else begin
                    $display("*** KLAUS FAIL *** PC stuck in `%s $%04h` after %0d cycles",
                             (mem[stuck_window_min] == 8'h4C) ? "JMP" : "Bxx",
                             stuck_window_min, cycle_count);
                    $display("Cross-reference $%04h in sim/test_data/6502_functional_test.lst",
                             stuck_window_min);
                    $fatal(1);
                end
            end

            // Reset window for next sample.
            stuck_window_min    <= 16'hFFFF;
            stuck_window_max    <= 16'h0000;
            stuck_window_cycles <= 0;

            // Progress ping every ~1M cycles.
            if (cycle_count % 1_000_000 < STUCK_BUDGET)
                $display("[progress] cycle %0d, PC ~$%04h",
                         cycle_count, last_addr_q);

            if (cycle_count > MAX_CYCLES) begin
                $display("*** KLAUS TIMEOUT *** %0d cycles, last PC ~$%04h",
                         cycle_count, last_addr_q);
                $fatal(1);
            end
        end
    end

    // Wallclock backup — if the cycle-count loop above somehow misses,
    // bail at 60 minutes of wall time. Klaus completes well inside this
    // on any modern host.
    initial begin
        #3_600_000_000_000;
        $display("FAIL: tb_klaus wallclock watchdog (60 min)");
        $fatal(1);
    end

endmodule
