// tb_mode_f.sv — M6 mode-F compositor pipeline.
//
// Pipeline under test:
//   testbench backdoor -> cpu_shadow -> dl_parser  -> meta -> compositor
//                              ^                                    |
//                              \------------ (also reads) -----------/
//
//   compositor -> rp_tx -> rp_bus_mock.fb
//
// The DL points at a single mode-F line that spans 192 atari rows
// (the LMS auto-advances 40 bytes per row → 7680 bytes of mode-F
// source data). Source data: byte at offset b = b[7:0] (= b mod 256).
// Each byte unpacks to 8 atari pixels (1bpp); we expect the compositor
// to emit 4 SETs per byte, writing 8 atari-pixel indices into the FB
// at row_base + 8*b_idx ... row_base + 8*b_idx + 7.
//
// Verification: walk every (row, byte_idx, bit_idx) and assert
// rp_bus_mock.fb[row * 1024 + byte_idx * 8 + bit_idx] equals the
// expected unpacked value.
//
// Single sim clock at 100 MHz. We don't run vbeam at this milestone —
// compose triggers manually after parse completes.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_mode_f;

    logic clk = 1'b0;
    always #5 clk = ~clk;     // 100 MHz

    logic rst = 1'b1;

    // ---- cpu_shadow (one byte_ram per consumer for sim simplicity) -----
    // Both copies receive the same backdoor writes from the testbench.
    // dl_parser reads from u_cpu_shadow_dl; compositor reads from
    // u_cpu_shadow_compose.
    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;

    wire  [15:0] dl_raddr;
    wire  [7:0]  dl_rdata;
    wire  [15:0] cmp_raddr;
    wire  [7:0]  cmp_rdata;

    byte_ram #(
        .ADDR_W (16),
        .DEPTH  (65536)
    ) u_cpu_shadow_dl (
        .clk     (clk),
        .we      (bram_we),
        .waddr   (bram_waddr),
        .wdata   (bram_wdata),
        .raddr   (dl_raddr),
        .rdata   (dl_rdata)
    );

    byte_ram #(
        .ADDR_W (16),
        .DEPTH  (65536)
    ) u_cpu_shadow_compose (
        .clk     (clk),
        .we      (bram_we),
        .waddr   (bram_waddr),
        .wdata   (bram_wdata),
        .raddr   (cmp_raddr),
        .rdata   (cmp_rdata)
    );

    // ---- dl_parser ------------------------------------------------------
    logic        dl_start    = 1'b0;
    logic [7:0]  dlistl      = 8'h00;
    logic [7:0]  dlisth      = 8'hD0;
    // Compositor drives meta_row; dl_parser reads it (along with meta_*
    // outputs). dl_parser's `meta_row` is input-only, so it never
    // contests the wire.
    wire  [7:0]  meta_row_w;
    wire  [3:0]  dl_meta_mode;
    wire         dl_meta_dli;
    wire  [15:0] dl_meta_lms;
    wire  [3:0]  dl_meta_sub;
    wire         dl_meta_hscrol_en;
    wire         dl_meta_vscrol_en;
    wire         dl_done;
    wire  [31:0] dl_count;

    dl_parser u_dl (
        .clk            (clk),
        .rst            (rst),
        .start_parse    (dl_start),
        .dlistl         (dlistl),
        .dlisth         (dlisth),
        .mem_raddr      (dl_raddr),
        .mem_rdata      (dl_rdata),
        .mem_req        (),
        .mem_ready      (1'b1),
        .meta_row       (meta_row_w),
        .meta_mode      (dl_meta_mode),
        .meta_dli       (dl_meta_dli),
        .meta_lms_addr  (dl_meta_lms),
        .meta_sub_row   (dl_meta_sub),
        .meta_hscrol_en (dl_meta_hscrol_en),
        .meta_vscrol_en (dl_meta_vscrol_en),
        .dli_row        (8'h00),
        .dli_at         (),
        .parse_done     (dl_done),
        .parse_count    (dl_count)
    );

    // ---- compositor → rp_tx → rp_bus_mock ------------------------------
    logic        cmp_start = 1'b0;
    wire  [1:0]  cmp_cmd_tag;
    wire  [23:0] cmp_cmd_addr;
    wire  [23:0] cmp_cmd_data;
    wire         cmp_cmd_valid;
    wire         cmp_cmd_ready;
    wire         cmp_done;
    wire  [31:0] cmp_count;

    compositor u_cmp (
        .clk           (clk),
        .rst           (rst),
        .start_compose (cmp_start),
        .meta_row      (meta_row_w),
        .meta_mode     (dl_meta_mode),
        .meta_lms_addr (dl_meta_lms),
        .meta_sub_row  (dl_meta_sub),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .chbase        (8'h00),
        .chactl        (8'h00),
        .pmbase        (8'h00),
        .dmactl        (8'h00),
        .gractl        (8'h00),
        .hposp0        (8'h00), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0        (8'h00), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep0        (2'h0),  .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem         (8'h00),
        .vdelay        (8'h00),
        .hscrol        (4'h0),
        .vscrol        (4'h0),
        .prior         (8'h00),
        .mpf_q         (), .ppf_q(), .mpl_q(), .ppl_q(),
        .hitclr        (1'b0),
        .mem_raddr     (cmp_raddr),
        .mem_rdata     (cmp_rdata),
        .mem_req       (),
        .mem_ready     (1'b1),
        .cmd_tag       (cmp_cmd_tag),
        .cmd_addr      (cmp_cmd_addr),
        .cmd_data      (cmp_cmd_data),
        .cmd_valid     (cmp_cmd_valid),
        .cmd_ready     (cmp_cmd_ready),
        .compose_done  (cmp_done),
        .compose_count (cmp_count)
    );

    wire  [1:0]  bus_tag;
    wire  [23:0] bus_payload;
    wire  [31:0] tx_set_misalign_count;

    rp_tx u_tx (
        .clk                   (clk),
        .rst                   (rst),
        .cmd_tag               (cmp_cmd_tag),
        .cmd_addr              (cmp_cmd_addr),
        .cmd_data              (cmp_cmd_data),
        .cmd_valid             (cmp_cmd_valid),
        .cmd_ready             (cmp_cmd_ready),
        .bus_tag               (bus_tag),
        .bus_payload           (bus_payload),
        .tx_set_misalign_count (tx_set_misalign_count)
    );

    // Reduce test scope to keep iverilog elaboration time tractable.
    // The compositor's mode-F path is row-symmetric, so 32 rows is
    // enough evidence the unpack works; M19+ end-to-end tests will
    // exercise full 192-row scope.
    localparam int FB_ROWS  = 32;
    localparam int FB_BYTES = FB_ROWS * 1024;

    wire  [15:0] mock_rsp;
    wire         mock_rsp_valid;
    wire  [31:0] mock_fetch_count, mock_set_count, mock_draw_count;
    wire  [31:0] mock_bad_tag_count, mock_set_misalign_count;

    rp_bus_mock #(
        .FB_BYTES      (FB_BYTES),
        .FETCH_LATENCY (4)
    ) u_mock (
        .clk                     (clk),
        .rst                     (rst),
        .bus_tag                 (bus_tag),
        .bus_payload             (bus_payload),
        .rsp_payload             (mock_rsp),
        .rsp_valid               (mock_rsp_valid),
        .mock_fetch_count        (mock_fetch_count),
        .mock_set_count          (mock_set_count),
        .mock_draw_count         (mock_draw_count),
        .mock_bad_tag_count      (mock_bad_tag_count),
        .mock_set_misalign_count (mock_set_misalign_count)
    );

    `include "dump_ppm.svh"

    // ---- Backdoor write ------------------------------------------------
    task automatic load_byte(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk);
        bram_waddr <= addr;
        bram_wdata <= data;
        bram_we    <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        bram_we <= 1'b0;
    endtask

    // ---- Verification --------------------------------------------------
    int fail_count = 0;

    function automatic logic [7:0] expected_pixel(input logic [15:0] src_byte_addr,
                                                  input int          bit_idx);
        // Source byte at src_byte_addr; bit_idx 0..7 (0 = MSB / leftmost).
        // Mode F now emits 0x04 (= COLPF2 owner) for set bits, matching
        // rp-antic's expand.pio convention.
        logic [7:0] byte_val;
        byte_val = src_byte_addr[7:0];
        return byte_val[7 - bit_idx] ? 8'h04 : 8'h00;
    endfunction

    // ---- Main ----------------------------------------------------------
    initial begin
        $display("[mode_f] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Build the DL: FB_ROWS mode-F lines, first with LMS=$3000.
        // Each mode-F DL line emits 1 atari row.
        load_byte(16'hD000, 8'h4F);      // mode F + LMS
        load_byte(16'hD001, 8'h00);      // LMS lo
        load_byte(16'hD002, 8'h30);      // LMS hi
        for (int i = 0; i < FB_ROWS - 1; i++) begin
            load_byte(16'hD003 + 16'(i), 8'h0F);
        end
        // JVB at end
        load_byte(16'hD003 + 16'(FB_ROWS - 1) + 16'd0, 8'h41);
        load_byte(16'hD003 + 16'(FB_ROWS - 1) + 16'd1, 8'h00);
        load_byte(16'hD003 + 16'(FB_ROWS - 1) + 16'd2, 8'hD0);

        // Source bitmap: byte at $3000 + b = b[7:0].
        for (int b = 0; b < FB_ROWS * 40; b++) begin
            load_byte(16'h3000 + 16'(b), b[7:0]);
        end

        // Trigger DL parse.
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        $display("[mode_f] dl parse done; count=%0d", dl_count);

        // Trigger compose.
        @(posedge clk);
        cmp_start <= 1'b1;
        @(posedge clk);
        cmp_start <= 1'b0;
        wait (cmp_done);
        @(posedge clk);
        $display("[mode_f] compose done; sets=%0d", mock_set_count);

        // Diag: peek at cpu_shadow + first SET landing.
        $display("[mode_f] cpu_shadow_compose.mem[$3000]=$%02h (expected $00)",
                 u_cpu_shadow_compose.mem[16'h3000]);
        $display("[mode_f] cpu_shadow_compose.mem[$3046]=$%02h (expected $46)",
                 u_cpu_shadow_compose.mem[16'h3046]);
        $display("[mode_f] mock fb[0]=$%02h fb[1]=$%02h fb[2]=$%02h fb[3]=$%02h",
                 u_mock.fb[0], u_mock.fb[1], u_mock.fb[2], u_mock.fb[3]);
        // Row 1 byte 30: source $3046 = 8'b01000110. Expected fb writes:
        // fb[1264]=byte[7]=0, fb[1265]=byte[6]=1, fb[1266]=byte[5]=0,
        // fb[1267]=byte[4]=0, fb[1268]=byte[3]=0, fb[1269]=byte[2]=1,
        // fb[1270]=byte[1]=1, fb[1271]=byte[0]=0.
        $display("[mode_f] r1b30 fb[1264..1271] = %02h %02h %02h %02h %02h %02h %02h %02h",
                 u_mock.fb[1264], u_mock.fb[1265], u_mock.fb[1266], u_mock.fb[1267],
                 u_mock.fb[1268], u_mock.fb[1269], u_mock.fb[1270], u_mock.fb[1271]);
        // Row 0 byte 30: source $301E = 8'b00011110.
        $display("[mode_f] r0b30 fb[ 240.. 247] = %02h %02h %02h %02h %02h %02h %02h %02h",
                 u_mock.fb[240], u_mock.fb[241], u_mock.fb[242], u_mock.fb[243],
                 u_mock.fb[244], u_mock.fb[245], u_mock.fb[246], u_mock.fb[247]);
        $display("[mode_f] dl meta@row0: mode=$%01h lms=$%04h",
                 u_dl.line_mode[0], u_dl.line_lms_addr[0]);
        $display("[mode_f] dl meta@row1: mode=$%01h lms=$%04h",
                 u_dl.line_mode[1], u_dl.line_lms_addr[1]);

        // Drain.
        repeat (32) @(posedge clk);

        // Verify each FB byte against expected unpacked pattern. Note:
        // declarations need to be separated from assignments here because
        // iverilog gives static lifetime to in-block declarations and
        // evaluates `= u_mock.fb[...]` at sim time 0 (when fb is x).
        begin : verify
            logic [15:0] src_addr;
            int          fb_offset;
            logic [7:0]  got;
            logic [7:0]  exp;
            for (int row = 0; row < FB_ROWS; row++) begin
                for (int b = 0; b < 40; b++) begin
                    src_addr = 16'h3000 + 16'(row * 40 + b);
                    for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
                        fb_offset = row * 1024 + b * 8 + bit_idx;
                        got = u_mock.fb[fb_offset];
                        exp = expected_pixel(src_addr, bit_idx);
                        if (got !== exp) begin
                            if (fail_count < 16) begin
                                $display("FAIL fb[%0d:%0d:%0d] = $%02h, expected $%02h (src=$%04h)",
                                         row, b, bit_idx, got, exp, src_addr);
                            end
                            fail_count++;
                        end
                    end
                end
            end
        end

        if (mock_bad_tag_count != 32'h0) begin
            $display("FAIL: mock_bad_tag_count=%0d", mock_bad_tag_count); fail_count++;
        end
        if (mock_set_misalign_count != 32'h0) begin
            $display("FAIL: mock_set_misalign_count=%0d", mock_set_misalign_count); fail_count++;
        end

        dump_ppm("visual/mode_f.ppm", 320, FB_ROWS, 3);

        if (fail_count == 0) begin
            $display("*** MODE_F OK *** %0d FB bytes verified across %0d rows; sets=%0d",
                     FB_ROWS * 320, FB_ROWS, mock_set_count);
            $finish;
        end else begin
            $display("*** MODE_F FAIL *** %0d failures (sets=%0d, fetches=%0d)",
                     fail_count, mock_set_count, mock_fetch_count);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_mode_f watchdog expired (cmp_count=%0d, sets=%0d)",
                 cmp_count, mock_set_count);
        $fatal(1);
    end

endmodule

`default_nettype wire
