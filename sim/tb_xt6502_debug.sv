// tb_xt6502_debug.sv — xt6502 + xt6502_debug wired together (as in fpga_xt_top).
// Verifies the in-fabric debugger: boundary-aligned HALT (non-destructive rdy
// gate), single-STEP N, PC BREAKPOINT, register SNAPSHOT read-back, and register
// INJECTION + resume.  One clock domain (the CDC synchronisers still function —
// they just add a couple of cycles of latency).
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502_debug;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    // ---- core <-> debug taps / injection ----
    wire [15:0] addr; wire [7:0] data_out; wire rw;
    reg  [7:0]  data_in;
    wire        cdbg_boundary; wire [15:0] cdbg_pc;
    wire [7:0]  cdbg_a, cdbg_x, cdbg_y, cdbg_s, cdbg_p; wire [3:0] cdbg_shigh;
    wire        idbg_wr; wire [15:0] idbg_wpc;
    wire [7:0]  idbg_wa, idbg_wx, idbg_wy, idbg_ws, idbg_wp; wire [3:0] idbg_wshigh;
    wire        core_run;

    // ---- GP0-domain control (driven by this TB) ----
    reg         halt_tog=0, go_tog=0, step_tog=0, commit_tog=0;
    reg  [1:0]  cfg=0;
    reg  [15:0] bkpt=0, stepc=1, wpc=0;
    reg  [31:0] waxys=0; reg [11:0] wpsh=0;
    // ---- status ----
    wire [3:0]  stat; wire [15:0] snap_pc; wire [31:0] snap_axys; wire [11:0] snap_psh;
    wire [31:0] icnt;
    // trace ring
    reg  [1:0]  trc_ctrl=0; reg [11:0] trc_idx=0;
    wire [31:0] trc_wptr; wire [15:0] trc_pc; wire [31:0] trc_axys; wire [11:0] trc_p;
    wire eff_rdy = core_run;                 // base rdy = 1 (full speed); gated by the debugger

    xt6502 u_dut (
        .clk(clk), .rst(rst), .addr(addr), .data_in(data_in), .data_out(data_out),
        .rw(rw), .rdy(eff_rdy), .irq_n(1'b1), .nmi_n(1'b1), .stack_op(), .s_high(),
        .dbg_boundary(cdbg_boundary), .dbg_pc(cdbg_pc),
        .dbg_a(cdbg_a), .dbg_x(cdbg_x), .dbg_y(cdbg_y), .dbg_s(cdbg_s), .dbg_p(cdbg_p),
        .dbg_shigh(cdbg_shigh),
        .dbg_wr(idbg_wr), .dbg_wpc(idbg_wpc),
        .dbg_wa(idbg_wa), .dbg_wx(idbg_wx), .dbg_wy(idbg_wy), .dbg_ws(idbg_ws),
        .dbg_wp(idbg_wp), .dbg_wshigh(idbg_wshigh)
    );

    xt6502_debug u_dbg (
        .clk(clk), .rst(rst), .core_rst(rst),
        .dbg_boundary(cdbg_boundary), .dbg_pc(cdbg_pc),
        .dbg_a(cdbg_a), .dbg_x(cdbg_x), .dbg_y(cdbg_y), .dbg_s(cdbg_s), .dbg_p(cdbg_p),
        .dbg_shigh(cdbg_shigh),
        .halt_tog(halt_tog), .go_tog(go_tog), .step_tog(step_tog), .commit_tog(commit_tog),
        .cfg(cfg), .bkpt_addr(bkpt), .step_count(stepc), .wpc(wpc), .waxys(waxys), .wpsh(wpsh),
        .dbg_wr(idbg_wr), .dbg_wpc(idbg_wpc),
        .dbg_wa(idbg_wa), .dbg_wx(idbg_wx), .dbg_wy(idbg_wy), .dbg_ws(idbg_ws),
        .dbg_wp(idbg_wp), .dbg_wshigh(idbg_wshigh),
        .core_run(core_run),
        .stat(stat), .snap_pc(snap_pc), .snap_axys(snap_axys), .snap_psh(snap_psh), .icnt(icnt),
        .trc_ctrl(trc_ctrl), .trc_idx(trc_idx), .trc_wptr_stat(trc_wptr),
        .trc_pc(trc_pc), .trc_axys(trc_axys), .trc_p(trc_p)
    );

    // ---- synchronous memory (addr N -> data_in N+1), gated on the effective rdy ----
    reg [7:0] mem [0:65535];
    always @(posedge clk) begin
        if (eff_rdy) begin
            if (!rw) mem[addr] <= data_out;
            data_in <= mem[addr];
        end
    end

    integer nfail = 0;
    task chk16(input [127:0] name, input [15:0] got, input [15:0] want);
        if (got !== want) begin $display("FAIL %0s: got=$%04h want=$%04h", name, got, want); nfail=nfail+1; end
        else $display("  ok  %0s = $%04h", name, got);
    endtask
    task chk8(input [127:0] name, input [7:0] got, input [7:0] want);
        if (got !== want) begin $display("FAIL %0s: got=$%02h want=$%02h", name, got, want); nfail=nfail+1; end
        else $display("  ok  %0s = $%02h", name, got);
    endtask

    // flip a command toggle (one GP0 write)
    task pulse_halt;   begin @(negedge clk) halt_tog   = ~halt_tog;   end endtask
    task pulse_go;     begin @(negedge clk) go_tog     = ~go_tog;     end endtask
    task pulse_step;   begin @(negedge clk) step_tog   = ~step_tog;   end endtask
    task pulse_commit; begin @(negedge clk) commit_tog = ~commit_tog; end endtask

    // First halt from a running core: just wait for halted.
    task wait_halt(input [127:0] tag);
        integer c; begin
            c = 0;
            while (!stat[0] && c < 400) begin @(posedge clk); c = c + 1; end
            if (!stat[0]) begin $display("FAIL %0s: never halted", tag); nfail=nfail+1; end
        end
    endtask
    // Command issued while ALREADY halted (step/go): wait for the core to un-halt
    // (command crossed the CDC and took effect) then re-halt.
    task run_until_halt(input [127:0] tag);
        integer c; begin
            c = 0; while (stat[0] && c < 60)  begin @(posedge clk); c = c + 1; end
            if (stat[0]) begin $display("FAIL %0s: never un-halted (command lost)", tag); nfail=nfail+1; end
            c = 0; while (!stat[0] && c < 400) begin @(posedge clk); c = c + 1; end
            if (!stat[0]) begin $display("FAIL %0s: never re-halted", tag); nfail=nfail+1; end
        end
    endtask

    initial begin
        integer i;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        // reset vector -> $0200
        mem[16'hFFFC]=8'h00; mem[16'hFFFD]=8'h02;
        // loop:  LDA #$11 / LDX #$22 / LDY #$33 / NOP / JMP $0200
        mem[16'h0200]=8'hA9; mem[16'h0201]=8'h11;
        mem[16'h0202]=8'hA2; mem[16'h0203]=8'h22;
        mem[16'h0204]=8'hA0; mem[16'h0205]=8'h33;
        mem[16'h0206]=8'hEA;
        mem[16'h0207]=8'h4C; mem[16'h0208]=8'h00; mem[16'h0209]=8'h02;
        // alt routine for injection: $0300 LDA #$AA / JMP $0300
        mem[16'h0300]=8'hA9; mem[16'h0301]=8'hAA;
        mem[16'h0302]=8'h4C; mem[16'h0303]=8'h00; mem[16'h0304]=8'h03;

        data_in = 8'h00;
        repeat (4) @(posedge clk); rst = 0;

        // ---- T1: free-run, icnt advances ----
        $display("[T1] free-run");
        repeat (120) @(posedge clk);
        if (icnt < 4) begin $display("FAIL T1: icnt=%0d (core not running)", icnt); nfail=nfail+1; end
        else $display("  ok  T1: running, icnt=%0d", icnt);

        // ---- T2: HALT at a boundary ----
        $display("[T2] halt");
        pulse_halt; wait_halt("T2");
        if (!stat[0]) ; else $display("  ok  T2: halted, snap_pc=$%04h", snap_pc);

        // ---- T3: register INJECTION (PC=$0200, A=01 X=02 Y=03 SP=$1FF P=$24) ----
        $display("[T3] inject regs");
        @(negedge clk); wpc=16'h0200; waxys={8'hFF,8'h03,8'h02,8'h01}; wpsh={4'h1,8'h24};
        pulse_commit;
        repeat (6) @(posedge clk);
        chk16("T3 snap_pc",  snap_pc, 16'h0200);
        chk8 ("T3 A", snap_axys[7:0],   8'h01);
        chk8 ("T3 X", snap_axys[15:8],  8'h02);
        chk8 ("T3 Y", snap_axys[23:16], 8'h03);
        chk8 ("T3 SPlo", snap_axys[31:24], 8'hFF);
        chk8 ("T3 P", snap_psh[7:0], 8'h24);

        // ---- T4: STEP one instruction at a time through the loop ----
        $display("[T4] single-step");
        stepc=1;
        pulse_step; run_until_halt("T4a");            // LDA #$11
        chk16("T4a snap_pc", snap_pc, 16'h0202); chk8("T4a A", snap_axys[7:0], 8'h11);
        pulse_step; run_until_halt("T4b");            // LDX #$22
        chk16("T4b snap_pc", snap_pc, 16'h0204); chk8("T4b X", snap_axys[15:8], 8'h22);
        pulse_step; run_until_halt("T4c");            // LDY #$33
        chk16("T4c snap_pc", snap_pc, 16'h0206); chk8("T4c Y", snap_axys[23:16], 8'h33);

        // ---- T5: STEP N ( NOP + JMP -> back to $0200 ) ----
        $display("[T5] step 2");
        @(negedge clk) stepc=2;
        pulse_step; run_until_halt("T5");
        chk16("T5 snap_pc", snap_pc, 16'h0200);

        // ---- T6: BREAKPOINT at $0206 ----
        $display("[T6] breakpoint $0206");
        @(negedge clk) bkpt=16'h0206; cfg=2'b01;      // bkpt_en
        pulse_go; run_until_halt("T6");
        chk16("T6 snap_pc", snap_pc, 16'h0206);
        if (stat[1]) $display("  ok  T6: bkpt_hit"); else begin $display("FAIL T6: bkpt_hit not set"); nfail=nfail+1; end

        // ---- T7: GO free (clear bkpt), confirm running ----
        $display("[T7] go");
        @(negedge clk) cfg=2'b00;
        pulse_go;
        repeat (40) @(posedge clk);
        if (stat[3]) $display("  ok  T7: running (stat=%b)", stat);
        else begin $display("FAIL T7: not running, stat=%b", stat); nfail=nfail+1; end

        // ---- T8: instruction-trace ring ----
        $display("[T8] trace ring");
        @(negedge clk) wpc=16'h0200; waxys=0; wpsh=0; pulse_commit; repeat (6) @(posedge clk);
        @(negedge clk) trc_ctrl = 2'b01;              // enable trace (clears ring)
        pulse_go;
        repeat (80) @(posedge clk);                    // run several loop iterations
        pulse_halt; wait_halt("T8");
        repeat (4) @(posedge clk);
        if (trc_wptr[11:0] == 0) begin $display("FAIL T8: ring empty"); nfail=nfail+1; end
        else $display("  ok  T8: captured %0d entries", trc_wptr[11:0]);
        @(negedge clk) trc_idx = trc_wptr[11:0] - 12'd1; // newest entry
        repeat (6) @(posedge clk);
        begin reg [15:0] p; p = trc_pc;
            if (p==16'h0200||p==16'h0202||p==16'h0204||p==16'h0206||p==16'h0207)
                $display("  ok  T8: newest trace PC=$%04h", p);
            else begin $display("FAIL T8: trace PC=$%04h not a loop addr", p); nfail=nfail+1; end
        end

        if (nfail==0) $display("*** XT6502_DEBUG OK ***");
        else          $display("*** XT6502_DEBUG FAIL *** %0d failure(s)", nfail);
        $finish;
    end
    initial begin #500000; $display("*** XT6502_DEBUG TIMEOUT ***"); $finish; end
endmodule
`default_nettype wire
