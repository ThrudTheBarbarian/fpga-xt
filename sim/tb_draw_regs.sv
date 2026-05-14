// tb_draw_regs.sv — verify the chiplet-ext DRAW register port (M17-2).
//
// Phase A — write op + 5 args + DRAW_GO; observe draw_cmd_valid pulse,
//   matching op/args presented on the dispatch port, and pending flag
//   sequencing (1 → 0 after dispatch).
// Phase B — write a 2nd DRAW_GO while pending=1; second commit lost
//   per the spec (software-must-poll). Verify only 1 dispatch occurs.
// Phase C — back-pressure: hold draw_cmd_ready=0 across a DRAW_GO,
//   verify pending stays high; release ready, verify dispatch fires.
// Phase D — read-back of the staged op + args returns the latched
//   values byte-for-byte.

`default_nettype none
`timescale 1ns / 1ps
`include "bus_opcodes.vh"

module tb_draw_regs;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // Bus-snoop write port.
    logic        we    = 1'b0;
    logic [7:0]  waddr = 8'h00;
    logic [7:0]  wdata = 8'h00;

    // Bus read port.
    logic [7:0]  raddr = 8'h00;
    wire  [7:0]  rdata;

    // Dispatch handshake.
    wire         draw_cmd_valid;
    logic        draw_cmd_ready = 1'b1;
    wire  [7:0]  draw_op;
    wire  [15:0] draw_arg0, draw_arg1, draw_arg2, draw_arg3;
    wire  [15:0] draw_arg4, draw_arg5, draw_arg6, draw_arg7, draw_arg8;

    draw_regs u_dut (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata),
        .draw_cmd_valid(draw_cmd_valid),
        .draw_cmd_ready(draw_cmd_ready),
        .draw_op(draw_op),
        .draw_arg0(draw_arg0), .draw_arg1(draw_arg1),
        .draw_arg2(draw_arg2), .draw_arg3(draw_arg3),
        .draw_arg4(draw_arg4), .draw_arg5(draw_arg5),
        .draw_arg6(draw_arg6), .draw_arg7(draw_arg7),
        .draw_arg8(draw_arg8));

    int fail_count = 0;

    // ---- Helpers --------------------------------------------------------
    task automatic do_write(input [7:0] a, input [7:0] d);
        @(negedge clk);
        we    = 1'b1;
        waddr = a;
        wdata = d;
        @(posedge clk);
        @(negedge clk);
        we    = 1'b0;
    endtask

    // Stage a full DRAW command (op + 5 16-bit args). Caller strobes
    // DRAW_GO separately so we can test pending semantics.
    task automatic stage_cmd(input [7:0] op,
                             input [15:0] a0, input [15:0] a1,
                             input [15:0] a2, input [15:0] a3,
                             input [15:0] a4);
        do_write(8'h88, op);
        do_write(8'h89, a0[7:0]);   do_write(8'h8A, a0[15:8]);
        do_write(8'h8B, a1[7:0]);   do_write(8'h8C, a1[15:8]);
        do_write(8'h8D, a2[7:0]);   do_write(8'h8E, a2[15:8]);
        do_write(8'h8F, a3[7:0]);   do_write(8'h90, a3[15:8]);
        do_write(8'h91, a4[7:0]);   do_write(8'h92, a4[15:8]);
    endtask

    task automatic strobe_go();
        do_write(8'h93, 8'h01);     // any value commits
    endtask

    task automatic expect_eq(input string label, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Wait up to N cycles for draw_cmd_valid to pulse; capture context.
    task automatic await_dispatch(input int max_cycles, output logic fired);
        int i;
        fired = 1'b0;
        for (i = 0; i < max_cycles && !fired; i++) begin
            @(negedge clk);
            if (draw_cmd_valid) fired = 1'b1;
        end
    endtask

    initial begin
        $display("[draw_regs] start");
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ===== Phase A — basic stage + dispatch ==========================
        begin : phase_a
            logic fired;
            $display("[A] stage + DRAW_GO + observe dispatch");
            stage_cmd(`BUS_DRAW_OP_FILL,
                      16'h0010, 16'h0020, 16'h0030, 16'h0040, 16'h0050);

            // Pending should still be 0 — we haven't strobed GO.
            @(negedge clk);
            raddr = 8'h93;
            @(negedge clk);
            expect_eq("A.pre.go.pending", rdata, 8'h00);

            strobe_go();

            // After GO, pending=1 and dispatch should fire on next ready cycle.
            await_dispatch(8, fired);
            if (!fired) begin
                $display("FAIL A: draw_cmd_valid never pulsed");
                fail_count++;
            end

            expect_eq("A.op",    {24'h0, draw_op},   {24'h0, `BUS_DRAW_OP_FILL});
            expect_eq("A.arg0",  {16'h0, draw_arg0}, {16'h0, 16'h0010});
            expect_eq("A.arg1",  {16'h0, draw_arg1}, {16'h0, 16'h0020});
            expect_eq("A.arg2",  {16'h0, draw_arg2}, {16'h0, 16'h0030});
            expect_eq("A.arg3",  {16'h0, draw_arg3}, {16'h0, 16'h0040});
            expect_eq("A.arg4",  {16'h0, draw_arg4}, {16'h0, 16'h0050});

            // After dispatch fired, pending should now be 0.
            @(negedge clk);
            raddr = 8'h93;
            @(negedge clk);
            expect_eq("A.post.dispatch.pending", rdata, 8'h00);
        end

        // ===== Phase B — second GO while pending lost ====================
        // Hold ready=0 so the first GO's dispatch can't drain. Strobe GO
        // again. When ready goes high, only ONE dispatch should fire (the
        // second GO's strobe was effectively a no-op while pending was
        // already 1 — we still see only 1 valid pulse).
        begin : phase_b
            logic fired;
            int  pulse_count;
            pulse_count = 0;

            $display("[B] back-to-back GO with stuck ready=0");
            draw_cmd_ready = 1'b0;
            stage_cmd(`BUS_DRAW_OP_LINE,
                      16'h00AA, 16'h00BB, 16'h00CC, 16'h00DD, 16'h00EE);
            strobe_go();
            // Pending should be 1.
            @(negedge clk);
            raddr = 8'h93;
            @(negedge clk);
            expect_eq("B.after.go1.pending", rdata, 8'h01);

            strobe_go();    // second GO while pending=1 (lost)
            @(negedge clk);
            raddr = 8'h93;
            @(negedge clk);
            expect_eq("B.after.go2.pending", rdata, 8'h01);

            // Release ready; observe dispatch happens exactly once over
            // the next several cycles.
            draw_cmd_ready = 1'b1;
            for (int i = 0; i < 8; i++) begin
                @(negedge clk);
                if (draw_cmd_valid) pulse_count++;
            end
            expect_eq("B.dispatch.count", pulse_count, 1);
        end

        // ===== Phase C — back-pressure path =============================
        begin : phase_c
            logic fired;
            $display("[C] back-pressure release path");
            draw_cmd_ready = 1'b0;
            stage_cmd(`BUS_DRAW_OP_RECT,
                      16'h0001, 16'h0002, 16'h0003, 16'h0004, 16'h0005);
            strobe_go();

            // Pending should hold across multiple ready=0 cycles.
            repeat (10) @(negedge clk);
            raddr = 8'h93;
            @(negedge clk);
            expect_eq("C.stalled.pending", rdata, 8'h01);
            if (draw_cmd_valid) begin
                $display("FAIL C: draw_cmd_valid pulsed while ready=0");
                fail_count++;
            end

            // Release ready; dispatch fires.
            draw_cmd_ready = 1'b1;
            await_dispatch(8, fired);
            if (!fired) begin
                $display("FAIL C: dispatch did not fire after ready release");
                fail_count++;
            end
            expect_eq("C.op",   {24'h0, draw_op},   {24'h0, `BUS_DRAW_OP_RECT});
            expect_eq("C.arg2", {16'h0, draw_arg2}, {16'h0, 16'h0003});
        end

        // ===== Phase D — read-back of staged registers ==================
        begin : phase_d
            $display("[D] read-back of staged op + args");
            stage_cmd(8'hA5,
                      16'h1234, 16'h5678, 16'hCAFE, 16'hBABE, 16'hDEAD);
            // Don't strobe GO — we're just checking the read-back.
            @(negedge clk);
            raddr = 8'h88;  @(negedge clk);  expect_eq("D.op",    rdata, 8'hA5);
            raddr = 8'h89;  @(negedge clk);  expect_eq("D.a0.lo", rdata, 8'h34);
            raddr = 8'h8A;  @(negedge clk);  expect_eq("D.a0.hi", rdata, 8'h12);
            raddr = 8'h8B;  @(negedge clk);  expect_eq("D.a1.lo", rdata, 8'h78);
            raddr = 8'h8C;  @(negedge clk);  expect_eq("D.a1.hi", rdata, 8'h56);
            raddr = 8'h8D;  @(negedge clk);  expect_eq("D.a2.lo", rdata, 8'hFE);
            raddr = 8'h8E;  @(negedge clk);  expect_eq("D.a2.hi", rdata, 8'hCA);
            raddr = 8'h8F;  @(negedge clk);  expect_eq("D.a3.lo", rdata, 8'hBE);
            raddr = 8'h90;  @(negedge clk);  expect_eq("D.a3.hi", rdata, 8'hBA);
            raddr = 8'h91;  @(negedge clk);  expect_eq("D.a4.lo", rdata, 8'hAD);
            raddr = 8'h92;  @(negedge clk);  expect_eq("D.a4.hi", rdata, 8'hDE);
        end

        if (fail_count == 0) begin
            $display("*** DRAW_REGS OK *** stage + dispatch + back-pressure + readback");
            $finish;
        end else begin
            $display("*** DRAW_REGS FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_draw_regs watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
