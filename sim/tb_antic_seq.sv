// tb_antic_seq.sv — ANTIC native-raster render sequencer integration test.
//
// prompts/task-0014.  Wires the real RTL trio that implements the phi2-paced
// render trigger — antic_raster (raster timer) → antic_seq (sequencer) →
// compositor (option (b), one row per start_compose) — and asserts the §5.1
// "coupled scope" contract:
//
//   1. dl_start fires exactly once per frame, the cycle after vbi_start.
//   2. cmp_start fires exactly once per active scanline (the cycle after
//      line_start while ar_atari_row is in the active band), and never before
//      the first display-list parse has completed (the parse_pending gate, so
//      no garbage first frame).
//   3. The composed row advances 0,1,2,…,191 in lockstep with line_start,
//      wrapping to 0 at the next active frame.
//   4. The compositor composes exactly the commanded row: at compose_done its
//      meta_row lookup equals the row latched at the triggering cmp_start, and
//      there is exactly one compose_done per cmp_start (no overrun / no skip).
//
// dl_parser is modelled by a fixed-latency parse_done pulse after dl_start
// (the real parse completes well inside the ~22-line vertical blank).  The
// compositor is fed mode-0 (blank) meta so each row composes in a few cycles
// with no memory fetches — this test is about sequencing, not pixels.

`default_nettype none
`timescale 1ns / 1ps

module tb_antic_seq;

    localparam int CYC = 114, LINES = 262, TOP = 8, ACTIVE = 192, VBI = 248;
    localparam int PARSE_LAT = 200;          // clk_bus from dl_start to parse_done

    logic clk = 1'b0;  always #5 clk = ~clk;
    logic rst = 1'b1;

    // phi2_tick: 1-cycle pulse every 4 clks (as in tb_antic_raster).
    logic [1:0] div = 2'd0;
    logic       phi2_tick;
    always_ff @(posedge clk) div <= div + 2'd1;
    assign phi2_tick = (div == 2'd0);

    // ---- DUT 1: phi2 raster timer ---------------------------------------
    wire [8:0] scanline;
    wire [7:0] phi2_in_line, atari_row, vcount;
    wire       line_start, vbi_start;

    antic_raster #(
        .CYC_PER_LINE(CYC), .LINES_PER_FRAME(LINES),
        .DISPLAY_TOP(TOP), .ACTIVE_LINES(ACTIVE), .VBI_LINE(VBI)
    ) u_raster (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .scanline(scanline), .phi2_in_line(phi2_in_line),
        .line_start(line_start), .vbi_start(vbi_start),
        .atari_row(atari_row), .vcount(vcount)
    );

    // ---- Modelled dl_parser parse_done (fixed latency after dl_start) ---
    wire dl_start, cmp_start;
    int  parse_timer = 0;
    logic parse_done = 1'b0;
    always_ff @(posedge clk) begin
        if (rst) begin
            parse_timer <= 0;
            parse_done  <= 1'b0;
        end else begin
            parse_done <= 1'b0;
            if (dl_start)              parse_timer <= PARSE_LAT;
            else if (parse_timer > 1)  parse_timer <= parse_timer - 1;
            else if (parse_timer == 1) begin
                parse_timer <= 0;
                parse_done  <= 1'b1;
            end
        end
    end

    // ---- DUT 2: render sequencer ----------------------------------------
    antic_seq u_seq (
        .clk(clk), .rst(rst),
        .vbi_start (vbi_start),
        .line_start(line_start),
        .active_row(atari_row != 8'hFF),
        .parse_done(parse_done),
        .dl_start  (dl_start),
        .cmp_start (cmp_start)
    );

    // ---- DUT 3: compositor (option (b), blank-mode meta) ----------------
    wire [7:0]  meta_row;
    wire [15:0] cmp_mem_raddr;
    wire        cmp_mem_req;
    wire [1:0]  cmp_cmd_tag;
    wire [23:0] cmp_cmd_addr, cmp_cmd_data;
    wire        cmp_cmd_valid;
    wire [15:0] mpf_q, ppf_q, mpl_q, ppl_q;
    wire        compose_done;
    wire [31:0] compose_count;

    compositor u_compositor (
        .clk(clk), .rst(rst),
        .start_compose(cmp_start),
        .row_in(atari_row),
        .meta_row(meta_row),
        .meta_mode(4'h0),                 // blank — straight to S_NEXT_ROW
        .meta_lms_addr(16'h0), .meta_sub_row(4'h0),
        .meta_hscrol_en(1'b0), .meta_vscrol_en(1'b0),
        .chbase(8'h0), .chactl(8'h0), .pmbase(8'h0), .dmactl(8'h0), .gractl(8'h0),
        .hposp0(8'h0), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep_early_flat(8'h00), .sizep_chg_x_flat({4{12'h7FF}}),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0), .vdelay(8'h0), .hscrol(4'h0), .vscrol(4'h0), .prior(8'h0),
        .mem_raddr(cmp_mem_raddr), .mem_rdata(8'h0),
        .mem_req(cmp_mem_req), .mem_ready(1'b1),
        .cmd_tag(cmp_cmd_tag), .cmd_addr(cmp_cmd_addr),
        .cmd_data(cmp_cmd_data), .cmd_valid(cmp_cmd_valid), .cmd_ready(1'b1),
        .mpf_q(mpf_q), .ppf_q(ppf_q), .mpl_q(mpl_q), .ppl_q(ppl_q),
        .hitclr(1'b0),
        .compose_done(compose_done), .compose_count(compose_count)
    );

    // ---- Scoreboard ------------------------------------------------------
    int fail = 0;
    int dl_count = 0, vbi_count = 0, cmp_count = 0, done_count = 0;
    int full_frames = 0;              // active regions fully walked (cmp row 191)

    // dl_start must coincide with the cycle after a vbi_start.
    logic vbi_q;
    always_ff @(posedge clk) vbi_q <= (rst ? 1'b0 : vbi_start);

    // cmp_start must coincide with the cycle after a line_start in the
    // active band; track the row sequence + pending compose.
    logic       line_q;
    logic [7:0] row_q;
    always_ff @(posedge clk) begin
        line_q <= (rst ? 1'b0 : line_start);
        row_q  <= atari_row;
    end

    bit         seen_parse = 0;       // has the first parse_done been observed?
    bit         first_cmp  = 1;
    int         prev_row   = -1;
    bit         pend_valid = 0;       // a compose is in flight
    logic [7:0] pend_row;
    int         exp_row;

    always_ff @(posedge clk) begin
        if (!rst) begin
            if (parse_done) seen_parse <= 1'b1;

            // ---- dl_start checks ----
            if (vbi_start) vbi_count <= vbi_count + 1;
            if (dl_start) begin
                dl_count <= dl_count + 1;
                if (!vbi_q) begin
                    $display("FAIL dl_start not aligned to vbi_start (scanline %0d)", scanline);
                    fail++;
                end
            end

            // ---- cmp_start checks ----
            if (cmp_start) begin
                cmp_count <= cmp_count + 1;

                // gate: never before the first parse completed
                if (!seen_parse) begin
                    $display("FAIL cmp_start before first parse_done (scanline %0d row %0d)",
                             scanline, atari_row);
                    fail++;
                end
                // alignment: the cycle after an active line_start
                if (!(line_q && row_q != 8'hFF)) begin
                    $display("FAIL cmp_start not aligned to active line_start (scanline %0d)", scanline);
                    fail++;
                end
                // row sequence 0,1,..,191 wrapping to 0
                exp_row = (first_cmp || prev_row == ACTIVE-1) ? 0 : prev_row + 1;
                if (atari_row != exp_row[7:0]) begin
                    $display("FAIL cmp row sequence: got %0d expected %0d", atari_row, exp_row);
                    fail++;
                end
                first_cmp <= 1'b0;
                prev_row  <= atari_row;
                if (atari_row == ACTIVE-1) full_frames <= full_frames + 1;

                // overrun: previous compose must have finished
                if (pend_valid) begin
                    $display("FAIL overrun: cmp_start row %0d while row %0d still composing",
                             atari_row, pend_row);
                    fail++;
                end
                pend_valid <= 1'b1;
                pend_row   <= atari_row;
            end

            // ---- compose_done checks ----
            if (compose_done) begin
                done_count <= done_count + 1;
                if (!pend_valid) begin
                    $display("FAIL spurious compose_done (no pending row)");
                    fail++;
                end else if (meta_row != pend_row) begin
                    $display("FAIL compose_done meta_row %0d != commanded row %0d",
                             meta_row, pend_row);
                    fail++;
                end
                // clear unless a new cmp_start fires this same cycle (can't —
                // compose takes several cycles, far less than a line)
                pend_valid <= 1'b0;
            end
        end
    end

    initial begin
        $display("=== ANTIC_SEQ SEQUENCER TEST ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Frame 0's active region is gated (no parse yet); frames 1 and 2 each
        // compose a full 0..191 walk.  Stop once 2 full active frames are done,
        // then a short way into the following vertical blank — a deterministic
        // boundary where no compose is in flight and counts are exact.
        while (full_frames < 2) @(posedge clk);
        repeat (2000) @(posedge clk);

        // Two gated-then-composed frames: 2 vbi/dl pulses so far, exactly two
        // full active regions composed (2×192), one compose_done per cmp_start.
        if (vbi_count < 2)         begin $display("FAIL vbi_count=%0d (<2)", vbi_count);                       fail++; end
        if (dl_count != vbi_count) begin $display("FAIL dl_count=%0d != vbi_count=%0d", dl_count, vbi_count);  fail++; end
        if (cmp_count != 2*ACTIVE) begin $display("FAIL cmp_count=%0d (expected %0d)", cmp_count, 2*ACTIVE);   fail++; end
        if (done_count != cmp_count) begin $display("FAIL done_count=%0d != cmp_count=%0d", done_count, cmp_count); fail++; end

        if (fail == 0) begin
            $display("*** ANTIC_SEQ OK *** %0d frames, %0d dl_start, %0d cmp_start, %0d compose_done",
                     vbi_count, dl_count, cmp_count, done_count);
            $finish;
        end else begin
            $display("*** ANTIC_SEQ FAIL *** %0d failures", fail);
            $fatal(1);
        end
    end

    initial begin
        #60_000_000;
        $display("FAIL: tb_antic_seq watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
