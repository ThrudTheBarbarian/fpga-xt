// tb_draw.sv — verify rp_tx's DRAW emission (M17-1).
//
// For each opcode we issue a single DRAW command and check the bus
// produces the right tag + payload sequence with the right length.
// Also exercises:
//   - cmd_ready drops while a DRAW is in flight,
//   - draw_full mid-sequence stalls (NOP emitted, beat counter held),
//   - invalid opcodes trap into tx_draw_op_invalid_count without
//     emitting any DRAW beats,
//   - FETCH/SET interleaving across DRAW boundaries (issue a DRAW,
//     wait for completion, issue a SET, both come out correctly).

`default_nettype none
`timescale 1ns / 1ps
`include "bus_opcodes.vh"

module tb_draw;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // FETCH/SET host port.
    logic        cmd_valid = 1'b0;
    logic [1:0]  cmd_tag   = 2'd0;
    logic [23:0] cmd_addr  = 24'h0;
    logic [23:0] cmd_data  = 24'h0;
    wire         cmd_ready;

    // DRAW host port.
    logic        draw_cmd_valid = 1'b0;
    wire         draw_cmd_ready;
    logic [7:0]  draw_op   = 8'h00;
    logic [15:0] draw_arg0 = 16'h0;
    logic [15:0] draw_arg1 = 16'h0;
    logic [15:0] draw_arg2 = 16'h0;
    logic [15:0] draw_arg3 = 16'h0;
    logic [15:0] draw_arg4 = 16'h0;
    logic [15:0] draw_arg5 = 16'h0;
    logic [15:0] draw_arg6 = 16'h0;
    logic [15:0] draw_arg7 = 16'h0;
    logic [15:0] draw_arg8 = 16'h0;
    logic        draw_full = 1'b0;

    wire [1:0]  bus_tag;
    wire [23:0] bus_payload;
    wire [31:0] tx_set_misalign_count;
    wire [31:0] tx_draw_op_invalid_count;

    rp_tx u_dut (
        .clk(clk), .rst(rst),
        .cmd_tag(cmd_tag), .cmd_addr(cmd_addr), .cmd_data(cmd_data),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .draw_cmd_valid(draw_cmd_valid), .draw_cmd_ready(draw_cmd_ready),
        .draw_op(draw_op),
        .draw_arg0(draw_arg0), .draw_arg1(draw_arg1),
        .draw_arg2(draw_arg2), .draw_arg3(draw_arg3),
        .draw_arg4(draw_arg4), .draw_arg5(draw_arg5),
        .draw_arg6(draw_arg6), .draw_arg7(draw_arg7),
        .draw_arg8(draw_arg8),
        .draw_full(draw_full),
        .bus_tag(bus_tag), .bus_payload(bus_payload),
        .tx_set_misalign_count(tx_set_misalign_count),
        .tx_draw_op_invalid_count(tx_draw_op_invalid_count));

    int fail_count = 0;

    // ---- Helpers --------------------------------------------------------
    // submit_draw — 5-arg form for ops up through OVAL (NOP/LINE/RECT/
    // FILL/OVAL). arg5/arg6 are zeroed on each call so leftover state
    // from a prior 7-arg submit doesn't leak in.
    task automatic submit_draw(input [7:0] op,
                               input [15:0] a0, input [15:0] a1,
                               input [15:0] a2, input [15:0] a3,
                               input [15:0] a4);
        @(negedge clk);
        wait (draw_cmd_ready);
        @(negedge clk);
        draw_op        = op;
        draw_arg0      = a0;
        draw_arg1      = a1;
        draw_arg2      = a2;
        draw_arg3      = a3;
        draw_arg4      = a4;
        draw_arg5      = 16'h0;
        draw_arg6      = 16'h0;
        draw_cmd_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        draw_cmd_valid = 1'b0;
    endtask

    // submit_draw7 — 7-arg form for ARC and BEZIER_TO. arg7/arg8
    // zeroed so leftover state doesn't leak from a prior 9-arg call.
    task automatic submit_draw7(input [7:0] op,
                                input [15:0] a0, input [15:0] a1,
                                input [15:0] a2, input [15:0] a3,
                                input [15:0] a4, input [15:0] a5,
                                input [15:0] a6);
        @(negedge clk);
        wait (draw_cmd_ready);
        @(negedge clk);
        draw_op        = op;
        draw_arg0      = a0;
        draw_arg1      = a1;
        draw_arg2      = a2;
        draw_arg3      = a3;
        draw_arg4      = a4;
        draw_arg5      = a5;
        draw_arg6      = a6;
        draw_arg7      = 16'h0;
        draw_arg8      = 16'h0;
        draw_cmd_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        draw_cmd_valid = 1'b0;
    endtask

    // submit_draw9 — 9-arg form for cubic BEZIER (4 control points + colour).
    task automatic submit_draw9(input [7:0] op,
                                input [15:0] a0, input [15:0] a1,
                                input [15:0] a2, input [15:0] a3,
                                input [15:0] a4, input [15:0] a5,
                                input [15:0] a6, input [15:0] a7,
                                input [15:0] a8);
        @(negedge clk);
        wait (draw_cmd_ready);
        @(negedge clk);
        draw_op        = op;
        draw_arg0      = a0;
        draw_arg1      = a1;
        draw_arg2      = a2;
        draw_arg3      = a3;
        draw_arg4      = a4;
        draw_arg5      = a5;
        draw_arg6      = a6;
        draw_arg7      = a7;
        draw_arg8      = a8;
        draw_cmd_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        draw_cmd_valid = 1'b0;
    endtask

    task automatic expect_beat(input [1:0] tag, input [23:0] payload, input string label);
        // Sample on the negedge so the always_ff's NBA from this cycle's
        // posedge has settled before we compare. Reading immediately after
        // @(posedge clk) returns values from the *previous* cycle's NBA.
        @(negedge clk);
        if (bus_tag !== tag) begin
            $display("FAIL %s: bus_tag=%b expected=%b", label, bus_tag, tag);
            fail_count++;
        end
        if (bus_payload !== payload) begin
            $display("FAIL %s: bus_payload=$%06h expected=$%06h",
                     label, bus_payload, payload);
            fail_count++;
        end
    endtask

    initial begin
        $display("[draw] start");
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ===== Phase A — NOP_DRAW (1 beat) ==============================
        begin : phase_a
            $display("[A] NOP_DRAW");
            submit_draw(`BUS_DRAW_OP_NOP, 16'hCAFE, 0, 0, 0, 0);
            // beat 0: payload = {arg0[15:0], op}
            expect_beat(`BUS_TAG_DRAW, {16'hCAFE, `BUS_DRAW_OP_NOP}, "A.beat0");
            // After 1-beat sequence, FSM returns to idle; next bus cycle is NOP.
            expect_beat(`BUS_TAG_NOP, 24'h000000, "A.idle");
        end

        // ===== Phase B — LINE (5 beats) =================================
        begin : phase_b
            $display("[B] LINE");
            submit_draw(`BUS_DRAW_OP_LINE,
                        16'h0010,   // x0
                        16'h0020,   // y0
                        16'h00C0,   // x1
                        16'h0080,   // y1
                        16'h00FE);  // colour
            expect_beat(`BUS_TAG_DRAW, {16'h0010, `BUS_DRAW_OP_LINE}, "B.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0020},             "B.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00C0},             "B.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0080},             "B.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00FE},             "B.b4");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "B.idle");
        end

        // ===== Phase C — RECT outline + RECT-fill (5 beats) + FILL (3) ===
        begin : phase_c
            $display("[C.1] RECT (outline)");
            submit_draw(`BUS_DRAW_OP_RECT,
                        16'h0000, 16'h0000,        // x, y
                        16'h0140, 16'h00F0,        // w (320), h (240)
                        16'h00C8);                 // colour low byte = $C8, mode = 0
            expect_beat(`BUS_TAG_DRAW, {16'h0000, `BUS_DRAW_OP_RECT}, "C.RECT.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0000},             "C.RECT.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0140},             "C.RECT.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00F0},             "C.RECT.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00C8},             "C.RECT.b4");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.RECT.idle");

            $display("[C.2] RECT-fill (op[7]=1)");
            // Same 5-beat layout as RECT outline; only op differs.
            // op = BUS_DRAW_OP_RECT | BUS_DRAW_FILL_FLAG = $82
            submit_draw(`BUS_DRAW_OP_RECT | `BUS_DRAW_FILL_FLAG,
                        16'h0030, 16'h0040, 16'h0010, 16'h0010, 16'h0042);
            expect_beat(`BUS_TAG_DRAW,
                        {16'h0030, (`BUS_DRAW_OP_RECT | `BUS_DRAW_FILL_FLAG)},
                                                                      "C.FILL.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0040},             "C.FILL.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},             "C.FILL.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},             "C.FILL.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0042},             "C.FILL.b4");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.FILL.idle");

            $display("[C.3] FILL (flood, 3 beats)");
            // FILL is its own primitive — 3 beats: x, y, colour.
            submit_draw(`BUS_DRAW_OP_FILL,
                        16'h00A0, 16'h00B0, 16'h0099, 16'h0, 16'h0);
            expect_beat(`BUS_TAG_DRAW, {16'h00A0, `BUS_DRAW_OP_FILL}, "C.FLOOD.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00B0},             "C.FLOOD.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0099},             "C.FLOOD.b2");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.FLOOD.idle");

            $display("[C.4] OVAL outline (M18-1)");
            // 5 beats: cx, cy, rx, ry, colour
            submit_draw(`BUS_DRAW_OP_OVAL,
                        16'h0080, 16'h0060, 16'h0030, 16'h0020, 16'h0011);
            expect_beat(`BUS_TAG_DRAW, {16'h0080, `BUS_DRAW_OP_OVAL}, "C.OVAL.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0060},             "C.OVAL.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0030},             "C.OVAL.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0020},             "C.OVAL.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0011},             "C.OVAL.b4");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.OVAL.idle");

            $display("[C.5] OVAL filled (op[7]=1)");
            submit_draw(`BUS_DRAW_OP_OVAL | `BUS_DRAW_FILL_FLAG,
                        16'h0040, 16'h0030, 16'h0010, 16'h0010, 16'h0022);
            expect_beat(`BUS_TAG_DRAW,
                        {16'h0040, (`BUS_DRAW_OP_OVAL | `BUS_DRAW_FILL_FLAG)},
                                                                      "C.OVALF.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0030},             "C.OVALF.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},             "C.OVALF.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},             "C.OVALF.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0022},             "C.OVALF.b4");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.OVALF.idle");

            $display("[C.6] ARC outline (M18-2, 7 beats)");
            // Beats: cx, cy, rx, ry, start_angle, end_angle, colour
            submit_draw7(`BUS_DRAW_OP_ARC,
                         16'h0050, 16'h0040, 16'h0020, 16'h0018,
                         16'h0000, 16'h4000, 16'h0044);
            expect_beat(`BUS_TAG_DRAW, {16'h0050, `BUS_DRAW_OP_ARC},  "C.ARC.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0040},             "C.ARC.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0020},             "C.ARC.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0018},             "C.ARC.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0000},             "C.ARC.b4");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h4000},             "C.ARC.b5");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0044},             "C.ARC.b6");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.ARC.idle");

            $display("[C.7] PIE (ARC | fill_flag) — 7 beats");
            submit_draw7(`BUS_DRAW_OP_ARC | `BUS_DRAW_FILL_FLAG,
                         16'h0030, 16'h0030, 16'h0010, 16'h0010,
                         16'h2000, 16'hA000, 16'h0055);
            expect_beat(`BUS_TAG_DRAW,
                        {16'h0030, (`BUS_DRAW_OP_ARC | `BUS_DRAW_FILL_FLAG)},
                                                                      "C.PIE.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0030},             "C.PIE.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},             "C.PIE.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},             "C.PIE.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h2000},             "C.PIE.b4");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'hA000},             "C.PIE.b5");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0055},             "C.PIE.b6");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.PIE.idle");

            $display("[C.8] BEZIER (M18.1, 9 beats — 4 ctl pts + colour)");
            submit_draw9(`BUS_DRAW_OP_BEZIER,
                         16'h0010, 16'h0010,    // P0
                         16'h0020, 16'h0030,    // P1
                         16'h0040, 16'h0030,    // P2
                         16'h0050, 16'h0010,    // P3
                         16'h0066);             // colour
            expect_beat(`BUS_TAG_DRAW, {16'h0010, `BUS_DRAW_OP_BEZIER}, "C.BEZ.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},               "C.BEZ.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0020},               "C.BEZ.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0030},               "C.BEZ.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0040},               "C.BEZ.b4");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0030},               "C.BEZ.b5");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0050},               "C.BEZ.b6");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0010},               "C.BEZ.b7");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0066},               "C.BEZ.b8");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                       "C.BEZ.idle");

            $display("[C.9] BEZIER_TO (M18.1, 7 beats — chain to prev endpoint)");
            submit_draw7(`BUS_DRAW_OP_BEZIER_TO,
                         16'h0060, 16'h0008,    // P1 (P0 = chain endpoint)
                         16'h0080, 16'h0028,    // P2
                         16'h0090, 16'h0040,    // P3
                         16'h0077);             // colour
            expect_beat(`BUS_TAG_DRAW,
                        {16'h0060, `BUS_DRAW_OP_BEZIER_TO},          "C.BTO.b0");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0008},             "C.BTO.b1");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0080},             "C.BTO.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0028},             "C.BTO.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0090},             "C.BTO.b4");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0040},             "C.BTO.b5");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h0077},             "C.BTO.b6");
            expect_beat(`BUS_TAG_NOP,  24'h000000,                     "C.BTO.idle");
        end

        // ===== Phase D — draw_full mid-sequence stall ====================
        // Uses RECT-fill (5 beats) so we have enough beats to stall in
        // the middle of the sequence. (FILL is 3 beats — too short to
        // demonstrate a useful stall pattern.)
        begin : phase_d
            int saw_nop_during_stall;
            saw_nop_during_stall = 0;
            $display("[D] draw_full mid-sequence stall (RECT-fill)");
            submit_draw(`BUS_DRAW_OP_RECT | `BUS_DRAW_FILL_FLAG,
                        16'h00AA, 16'h00BB, 16'h00CC, 16'h00DD, 16'h00EE);
            // Beat 0 emits as normal.
            expect_beat(`BUS_TAG_DRAW,
                        {16'h00AA, (`BUS_DRAW_OP_RECT | `BUS_DRAW_FILL_FLAG)},
                                                                      "D.b0");
            // Beat 1 emits as normal.
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00BB},             "D.b1");
            // Assert draw_full immediately — we're already at a negedge
            // (just returned from expect_beat b1), so this is set well
            // before the next posedge where beat 2 would otherwise emit.
            draw_full = 1'b1;
            // For the next 3 cycles we expect NOPs (sequence stalled).
            // Sample on negedge to catch the post-NBA bus state.
            repeat (3) begin
                @(negedge clk);
                if (bus_tag === `BUS_TAG_NOP) saw_nop_during_stall++;
                else $display("FAIL D.stall: bus_tag=%b expected NOP", bus_tag);
            end
            if (saw_nop_during_stall != 3) begin
                $display("FAIL D: expected 3 NOPs during stall, saw %0d", saw_nop_during_stall);
                fail_count++;
            end
            // Release back-pressure; we're at a negedge (3rd repeat
            // landed there), so the next posedge sees draw_full=0 and
            // emits beat 2.
            draw_full = 1'b0;
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00CC}, "D.b2");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00DD}, "D.b3");
            expect_beat(`BUS_TAG_DRAW, {8'h00, 16'h00EE}, "D.b4");
            expect_beat(`BUS_TAG_NOP,  24'h000000,        "D.idle");
        end

        // ===== Phase E — invalid opcode trap =============================
        begin : phase_e
            int trap0, trap1;
            $display("[E] invalid opcode trap");
            trap0 = tx_draw_op_invalid_count;
            // $7F isn't in the opcode table.
            submit_draw(8'h7F, 16'h1111, 0, 0, 0, 0);
            // Bus should NOT carry a DRAW beat for this — it stays NOP-ish.
            // (rp_tx accepted the cmd but trapped it; FSM stays in S_IDLE.)
            @(negedge clk);
            if (bus_tag === `BUS_TAG_DRAW) begin
                $display("FAIL E: invalid opcode emitted DRAW beat");
                fail_count++;
            end
            trap1 = tx_draw_op_invalid_count;
            if (trap1 != trap0 + 1) begin
                $display("FAIL E: invalid trap counter %0d → %0d (expected +1)", trap0, trap1);
                fail_count++;
            end
        end

        // ===== Phase F — FETCH/SET works after DRAW ======================
        begin : phase_f
            $display("[F] FETCH/SET after DRAW");
            // Fire a DRAW first.
            submit_draw(`BUS_DRAW_OP_NOP, 16'h1234, 0, 0, 0, 0);
            expect_beat(`BUS_TAG_DRAW, {16'h1234, `BUS_DRAW_OP_NOP}, "F.draw");
            // Now a SET.
            @(negedge clk);
            cmd_tag   = `BUS_TAG_SET;
            cmd_addr  = 24'h001000;     // even addr
            cmd_data  = 24'hABCDEF;
            cmd_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
            expect_beat(`BUS_TAG_SET, 24'h001000, "F.set.addr");
            expect_beat(`BUS_TAG_SET, 24'hABCDEF, "F.set.data");
            expect_beat(`BUS_TAG_NOP, 24'h000000, "F.idle");
        end

        if (fail_count == 0) begin
            $display("*** DRAW OK *** NOP/LINE/RECT/RECT-fill/FILL/OVAL/OVAL-fill/ARC/PIE/BEZIER/BEZIER_TO + draw_full stall + invalid trap + FETCH/SET interop");
            $finish;
        end else begin
            $display("*** DRAW FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_draw watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
