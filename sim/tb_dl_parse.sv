// tb_dl_parse.sv — M5 display-list parser.
//
// Builds a small DL in cpu_shadow via the byte_ram write port, points
// dlisth/dlistl at it, pulses start_parse, then verifies the per-row
// metadata (mode, dli, lms_addr, sub_row) for each atari row the DL
// covers.
//
// DL under test:
//   $D000:  $42 $00 $30  ; mode 2 + LMS → 8 rows mode 2 from $3000
//   $D003:  $02          ; mode 2       → 8 rows mode 2 (LMS auto-advanced)
//   $D004:  $82          ; mode 2 + DLI → 8 rows; pending_dli for next line
//   $D005:  $0F          ; mode F       → 1 row mode F (sees DLI)
//   $D006:  $00          ; blank        → 1 row mode 0
//   $D007:  $41 $00 $D0  ; JVB          → end of frame

`default_nettype none
`timescale 1ns / 1ps

module tb_dl_parse;

    logic clk = 1'b0;
    always #10 clk = ~clk;       // 50 MHz

    logic rst = 1'b1;

    // ---- byte_ram (cpu_shadow) ------------------------------------------
    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;
    wire  [15:0] bram_raddr;
    wire  [7:0]  bram_rdata;

    byte_ram #(
        .ADDR_W (16),
        .DEPTH  (65536)
    ) u_cpu_shadow (
        .clk     (clk),
        .we      (bram_we),
        .waddr   (bram_waddr),
        .wdata   (bram_wdata),
        .raddr   (bram_raddr),
        .rdata   (bram_rdata)
    );

    // ---- dl_parser ------------------------------------------------------
    logic        start_parse = 1'b0;
    logic        dl_we_pulse = 1'b0;   // reload dl_pos from dlisth/dlistl (as the OS's
                                       // DLIST rewrite would) before each phase's parse
    logic [7:0]  dlistl      = 8'h00;
    logic [7:0]  dlisth      = 8'hD0;
    logic [7:0]  meta_row    = 8'h00;
    logic [3:0]  vscrol_r    = 4'h0;
    logic        frame_start_r = 1'b0;
    logic        line_start_r  = 1'b0;
    logic        prep_tick_r   = 1'b0;
    logic [7:0]  dli_row_r     = 8'h00;
    wire  [3:0]  meta_mode;
    wire         meta_dli;
    wire  [15:0] meta_lms_addr;
    wire  [3:0]  meta_sub_row;
    wire         meta_vscrol_en;
    wire         parse_done;
    wire  [31:0] parse_count;
    wire         dli_at_w;

    dl_parser u_dl (
        .clk           (clk),
        .rst           (rst),
        .start_parse   (start_parse),
        .cold_abort    (1'b0),
        .frame_start   (frame_start_r),
        .line_start    (line_start_r),
        .prep_tick     (prep_tick_r),
        .dlistl        (dlistl),
        .dlisth        (dlisth), .dlistl_we(dl_we_pulse), .dlisth_we(dl_we_pulse),
        .vscrol        (vscrol_r),
        .mem_raddr     (bram_raddr),
        .mem_rdata     (bram_rdata),
        .mem_req       (),
        .mem_ready     (1'b1),
        .meta_row      (meta_row),
        .meta_mode     (meta_mode),
        .meta_dli      (meta_dli),
        .meta_lms_addr (meta_lms_addr),
        .meta_sub_row  (meta_sub_row),
        .meta_hscrol_en(),
        .meta_vscrol_en(meta_vscrol_en),
        .dli_row       (dli_row_r),
        .dli_at        (dli_at_w),
        .parse_done    (parse_done),
        .parse_count   (parse_count)
    );

    // ---- Backdoor write into cpu_shadow ---------------------------------
    task automatic load_byte(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk);
        bram_waddr <= addr;
        bram_wdata <= data;
        bram_we    <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        bram_we <= 1'b0;
    endtask

    // ---- Walker stepping -------------------------------------------------
    // The metadata port presents the walker's CURRENT row; rows are reached
    // by stepping the walker in raster order (prep_tick prefetches the next
    // entry, line_start flips into the row).
    int cur_walk_row = -1;

    task automatic step_row;
        if (cur_walk_row < 0) begin
            @(negedge clk); frame_start_r <= 1'b1;
            @(negedge clk); frame_start_r <= 1'b0;
            repeat (2) @(negedge clk);
            line_start_r <= 1'b1;
            @(negedge clk); line_start_r <= 1'b0;
            @(negedge clk);
        end else begin
            @(negedge clk); prep_tick_r <= 1'b1;
            @(negedge clk); prep_tick_r <= 1'b0;
            repeat (2) @(negedge clk);
            line_start_r <= 1'b1;
            @(negedge clk); line_start_r <= 1'b0;
            @(negedge clk);
        end
        cur_walk_row++;
    endtask

    task automatic walk_to(input int row);
        while (cur_walk_row < row) step_row();
    endtask

    // ---- Verify ---------------------------------------------------------
    int fail_count = 0;
    task automatic check_row(input logic [7:0] row,
                             input logic [3:0] exp_mode,
                             input logic       exp_dli,
                             input logic [15:0] exp_lms,
                             input logic [3:0]  exp_sub);
        walk_to(int'(row));
        meta_row = row;
        @(posedge clk);   // settle
        #1;
        if (meta_mode !== exp_mode) begin
            $display("FAIL row %0d: mode got $%01h, expected $%01h",
                     row, meta_mode, exp_mode);
            fail_count++;
        end
        if (meta_dli !== exp_dli) begin
            $display("FAIL row %0d: dli got %0d, expected %0d",
                     row, meta_dli, exp_dli);
            fail_count++;
        end
        if (meta_lms_addr !== exp_lms) begin
            $display("FAIL row %0d: lms got $%04h, expected $%04h",
                     row, meta_lms_addr, exp_lms);
            fail_count++;
        end
        if (meta_sub_row !== exp_sub) begin
            $display("FAIL row %0d: sub got %0d, expected %0d",
                     row, meta_sub_row, exp_sub);
            fail_count++;
        end
    endtask

    // Lightweight check: mode, sub_row (DCTR) and vscrol_en of one row.
    task automatic check_ms(input logic [7:0] row,
                            input logic [3:0] exp_mode,
                            input logic [3:0] exp_sub,
                            input logic       exp_vs);
        walk_to(int'(row));
        meta_row = row;
        @(posedge clk);
        #1;
        if (meta_mode !== exp_mode) begin
            $display("FAIL row %0d: mode got $%01h, expected $%01h",
                     row, meta_mode, exp_mode);
            fail_count++;
        end
        if (meta_sub_row !== exp_sub) begin
            $display("FAIL row %0d: sub got %0d, expected %0d",
                     row, meta_sub_row, exp_sub);
            fail_count++;
        end
        if (meta_vscrol_en !== exp_vs) begin
            $display("FAIL row %0d: vscrol_en got %0d, expected %0d",
                     row, meta_vscrol_en, exp_vs);
            fail_count++;
        end
    endtask

    task automatic do_parse;
        // reload the DL PC (persistent across parses since the dlistwrap fix)
        @(negedge clk); dl_we_pulse <= 1'b1;
        @(negedge clk); dl_we_pulse <= 1'b0;
        @(negedge clk);
        @(posedge clk);
        start_parse <= 1'b1;
        @(posedge clk);
        start_parse <= 1'b0;
        wait (parse_done);
        @(posedge clk);
        cur_walk_row = -1;   // new frame: walker re-primes
    endtask

    // ---- Main -----------------------------------------------------------
    initial begin
        $display("[dl_parse] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Load DL.
        load_byte(16'hD000, 8'h42);   // mode 2 + LMS
        load_byte(16'hD001, 8'h00);   // LMS lo
        load_byte(16'hD002, 8'h30);   // LMS hi
        load_byte(16'hD003, 8'h02);   // mode 2 (auto-LMS)
        load_byte(16'hD004, 8'h82);   // mode 2 + DLI
        load_byte(16'hD005, 8'h0F);   // mode F (sees DLI)
        load_byte(16'hD006, 8'h00);   // blank, 1 scan line
        load_byte(16'hD007, 8'h41);   // JVB
        load_byte(16'hD008, 8'h00);   // JVB target lo
        load_byte(16'hD009, 8'hD0);   // JVB target hi

        // Trigger parse.
        @(posedge clk);
        start_parse <= 1'b1;
        @(posedge clk);
        start_parse <= 1'b0;

        // Wait for parse_done.
        wait (parse_done);
        @(posedge clk);

        // ---- Verify per-row metadata --------------------------------
        // Rows 0..7: mode 2, lms = $3000, dli=0, sub=0..7
        for (int r = 0; r < 8; r++) begin
            logic [7:0] row;
            row = r[7:0];
            check_row(row, 4'h2, 1'b0, 16'h3000, r[3:0]);
        end

        // Rows 8..15: mode 2, lms = $3000+40 = $3028, dli=0, sub=0..7
        for (int r = 0; r < 8; r++) begin
            logic [7:0] row;
            row = 8'd8 + r[7:0];
            check_row(row, 4'h2, 1'b0, 16'h3028, r[3:0]);
        end

        // Rows 16..23: mode 2 + DLI line, lms = $3050, sub=0..7.  meta_dli
        // marks every row of the flagged line; dli_at asserts only on the
        // LAST scan line (real ANTIC raises the DLI at end of the line).
        for (int r = 0; r < 8; r++) begin
            logic [7:0] row;
            row = 8'd16 + r[7:0];
            check_row(row, 4'h2, 1'b1, 16'h3050, r[3:0]);
            if (r < 7 && dli_at_w !== 1'b0) begin
                $display("FAIL row %0d: dli_at asserted before last sub-row", 16+r);
                fail_count++;
            end
            if (r == 7 && dli_at_w !== 1'b1) begin
                $display("FAIL row 23: dli_at not asserted on last sub-row");
                fail_count++;
            end
        end

        // Row 24: mode F, lms = $3078, dli=0 (the DLI belonged to the mode-2
        // line and fired on row 23), sub=0
        check_row(8'd24, 4'hF, 1'b0, 16'h3078, 4'd0);

        // Row 25: mode 0 (blank), lms = whatever (we don't care), dli=0, sub=0
        // Blank lines don't auto-advance LMS, so lms is still $3078+40=$30A0.
        check_row(8'd25, 4'h0, 1'b0, 16'h30A0, 4'd0);

        // Row 26+: not emitted (JVB ended frame). Should still be 0
        // from reset.
        check_row(8'd26, 4'h0, 1'b0, 16'h0000, 4'd0);

        // =============================================================
        // Directed VSCROL region test (ACID800 antic_vscroll region 1).
        //
        // DL:  $22  mode 2 + VSCROL  (first-of-block, prev = frame top = 0)
        //      $02  mode 2, no VSCROL (last-of-block: NON-vscrol line that
        //                              follows the region → VSCROL+1 rows)
        //      $41 $00 $D0  JVB
        // With VSCROL = 3:
        //   first-of-block: DCTR starts at 3 → sub 3,4,5,6,7  (8-3 = 5 rows)
        //   last-of-block : DCTR ends at 3   → sub 0,1,2,3    (3+1 = 4 rows)
        // =============================================================
        load_byte(16'hD000, 8'h22);   // mode 2 + VSCROL
        load_byte(16'hD001, 8'h02);   // mode 2, no VSCROL
        load_byte(16'hD002, 8'h41);   // JVB
        load_byte(16'hD003, 8'h00);
        load_byte(16'hD004, 8'hD0);
        vscrol_r = 4'd3;
        do_parse();

        // first-of-block: 5 rows, sub 3..7, vscrol_en=1
        check_ms(8'd0, 4'h2, 4'd3, 1'b1);
        check_ms(8'd1, 4'h2, 4'd4, 1'b1);
        check_ms(8'd2, 4'h2, 4'd5, 1'b1);
        check_ms(8'd3, 4'h2, 4'd6, 1'b1);
        check_ms(8'd4, 4'h2, 4'd7, 1'b1);
        // last-of-block: 4 rows, sub 0..3, vscrol_en=0
        check_ms(8'd5, 4'h2, 4'd0, 1'b0);
        check_ms(8'd6, 4'h2, 4'd1, 1'b0);
        check_ms(8'd7, 4'h2, 4'd2, 1'b0);
        check_ms(8'd8, 4'h2, 4'd3, 1'b0);

        // =============================================================
        // Directed VSCROL over-scroll quirk: VSCROL >= mode height.
        //
        // DL:  $22  mode 2 + VSCROL  (first-of-block)
        //      $41 $00 $D0  JVB (flush the single vscrol line)
        // With VSCROL = 10, mode 2 (height 8): DCTR starts at 10 and runs
        //   10,11,..,15,0,1,..,7  → 14 scan lines (wraps past 15).
        // =============================================================
        load_byte(16'hD000, 8'h22);   // mode 2 + VSCROL
        load_byte(16'hD001, 8'h41);   // JVB
        load_byte(16'hD002, 8'h00);
        load_byte(16'hD003, 8'hD0);
        vscrol_r = 4'd10;
        do_parse();

        begin
            logic [3:0] exp [0:13];
            exp = '{4'd10,4'd11,4'd12,4'd13,4'd14,4'd15,
                    4'd0,4'd1,4'd2,4'd3,4'd4,4'd5,4'd6,4'd7};
            for (int r = 0; r < 14; r++)
                check_ms(r[7:0], 4'h2, exp[r], 1'b1);
        end

        // =============================================================
        // Two-stage DLIST handoff (the HW nmist sequence): parse a
        // "loader" list (mode line + JVB self-loop), then write DLISTL/H
        // once to the nmist probe list (3x $70 + 2x $F0 + JVB) and check
        // the NEXT parse publishes the emitted-blank phantoms {31,39}.
        // =============================================================
        // loader-ish list at $D100: LMS mode 2 + JVB self-loop
        load_byte(16'hD100, 8'h42);
        load_byte(16'hD101, 8'h00);
        load_byte(16'hD102, 8'h30);
        load_byte(16'hD103, 8'h41);
        load_byte(16'hD104, 8'h00);
        load_byte(16'hD105, 8'hD1);
        dlistl = 8'h00; dlisth = 8'hD1;
        do_parse();                       // parse 1: loader list (dirty write)
        // free-running parse (NO dlist write): JVB self-loop re-parses loader
        @(negedge clk); start_parse <= 1'b1;
        @(negedge clk); start_parse <= 1'b0;
        wait (parse_done); @(posedge clk); cur_walk_row = -1;
        // nmist probe list at $D200
        load_byte(16'hD200, 8'h70);
        load_byte(16'hD201, 8'h70);
        load_byte(16'hD202, 8'h70);
        load_byte(16'hD203, 8'hF0);
        load_byte(16'hD204, 8'hF0);
        load_byte(16'hD205, 8'h41);
        load_byte(16'hD206, 8'h00);
        load_byte(16'hD207, 8'hD2);
        dlistl = 8'h00; dlisth = 8'hD2;
        do_parse();                       // parse 3: after the one-time rewrite
        if (u_dl.ph_act_cnt !== 5'd2
            || u_dl.ph_act[0] !== 8'd31 || u_dl.ph_act[1] !== 8'd39) begin
            $display("FAIL handoff: ph_cnt=%0d ph0=%0d ph1=%0d (expect 2/31/39)",
                     u_dl.ph_act_cnt, u_dl.ph_act[0], u_dl.ph_act[1]);
            fail_count++;
        end
        // dli_at must level at rows 31/39 and be clear at 30
        dli_row_r = 8'd30; @(posedge clk); #1;
        if (dli_at_w !== 1'b0) begin $display("FAIL handoff: dli_at@30"); fail_count++; end
        dli_row_r = 8'd31; @(posedge clk); #1;
        if (dli_at_w !== 1'b1) begin $display("FAIL handoff: no dli_at@31"); fail_count++; end
        dli_row_r = 8'd39; @(posedge clk); #1;
        if (dli_at_w !== 1'b1) begin $display("FAIL handoff: no dli_at@39"); fail_count++; end

        if (fail_count == 0) begin
            $display("*** DL_PARSE OK *** parse_count=%0d", parse_count);
            $finish;
        end else begin
            $display("*** DL_PARSE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_dl_parse watchdog expired"); $fatal(1);
    end

endmodule

`default_nettype wire
