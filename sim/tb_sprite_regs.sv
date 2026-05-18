// tb_sprite_regs.sv — exercise the sprite_engine descriptor register file.
//
// Covers:
//   * $D4Ax per-sprite control byte round-trip (en + flag bits + format)
//   * Descriptor write sequence B0..B7 — verifies commit happens on B7
//     and that reads of B0..B7 reconstruct the latched fields exactly.
//   * SPRITE_SEL change re-targets read-back and the next commit.
//   * No-commit case: writing shadow bytes without B7 leaves the
//     destination sprite's descriptor untouched.
//   * Collision W1C path on $D4DA / $D4DB at the selected COL_SEL row
//     (read-back stays at 0 since no compositor sets are wired yet).
//   * Global enable bit at $D4DF.
//
// Drives reg_we / reg_addr / reg_wdata directly — no SALLY model needed.
// All reads use the combinational rdata path so we can sample one cycle
// after addressing the register.

`timescale 1ns/1ps

module tb_sprite_regs;

    logic clk_fetch = 1'b0;
    logic clk_pix   = 1'b0;
    logic rst       = 1'b1;

    // ~166 MHz fetch / ~147 MHz pix — exact freqs aren't load-bearing here;
    // we just need two independent clocks since the DUT names them
    // distinctly.  All register accesses are clk_fetch-domain.
    always #3 clk_fetch = ~clk_fetch;
    always #3 clk_pix   = ~clk_pix;

    logic        reg_we;
    logic [7:0]  reg_addr;
    logic [7:0]  reg_wdata;
    wire  [7:0]  reg_rdata;

    sprite_engine u_dut (
        .clk_fetch     (clk_fetch),
        .clk_pix       (clk_pix),
        .rst           (rst),
        .h_count       (12'd0),
        .v_count       (12'd0),
        .line_start    (1'b0),
        .frame_start   (1'b0),
        .reg_we        (reg_we),
        .reg_addr      (reg_addr),
        .reg_wdata     (reg_wdata),
        .reg_rdata     (reg_rdata),
        .fb_pixel      (16'h0000),
        .fb_de         (1'b0),
        .rgb_r         (),
        .rgb_g         (),
        .rgb_b         (),
        .rgb_de        (),
        .m_axi_araddr  (),
        .m_axi_arlen   (),
        .m_axi_arsize  (),
        .m_axi_arburst (),
        .m_axi_arvalid (),
        .m_axi_arready (1'b0),
        .m_axi_rdata   (64'd0),
        .m_axi_rvalid  (1'b0),
        .m_axi_rlast   (1'b0),
        .m_axi_rready  ()
    );

    int errors = 0;

    task automatic write_reg(input [7:0] addr, input [7:0] data);
        @(posedge clk_fetch);
        #1;
        reg_we    = 1'b1;
        reg_addr  = addr;
        reg_wdata = data;
        @(posedge clk_fetch);
        #1;
        reg_we    = 1'b0;
    endtask

    task automatic read_reg(input [7:0] addr, output logic [7:0] data);
        @(posedge clk_fetch);
        #1;
        reg_we   = 1'b0;
        reg_addr = addr;
        #1 data = reg_rdata;
    endtask

    task automatic expect_reg(input [7:0] addr, input [7:0] want, input string msg);
        logic [7:0] got;
        read_reg(addr, got);
        if (got !== want) begin
            $display("FAIL: %s  addr=$D4%02h got=%02h want=%02h",
                     msg, addr, got, want);
            errors = errors + 1;
        end
    endtask

    initial begin
        reg_we    = 1'b0;
        reg_addr  = 8'h00;
        reg_wdata = 8'h00;

        // Hold reset a few cycles
        repeat (5) @(posedge clk_fetch);
        rst <= 1'b0;
        repeat (3) @(posedge clk_fetch);

        // -----------------------------------------------------------------
        // 1) Per-sprite control byte round-trip
        // -----------------------------------------------------------------
        // Sprite 3: en=1, h_flip=1, format=1 → 8'b0010_0011 = 8'h23.
        write_reg(8'hA3, 8'h23);
        expect_reg(8'hA3, 8'h23, "sprite 3 control byte (en|h_flip|format)");

        // Sprite 7: en=1, 2x_w=1, 2x_h=1 → 8'b0001_1001 = 8'h19.
        write_reg(8'hA7, 8'h19);
        expect_reg(8'hA7, 8'h19, "sprite 7 control byte (en|2x_w|2x_h)");

        // Sprite 3 still intact?
        expect_reg(8'hA3, 8'h23, "sprite 3 control byte (after sprite 7 write)");

        // Clear sprite 3 by overwriting with 0 — and verify clear works.
        write_reg(8'hA3, 8'h00);
        expect_reg(8'hA3, 8'h00, "sprite 3 control byte cleared");

        // -----------------------------------------------------------------
        // 2) Descriptor commit-on-B7 — write all 8 bytes, verify read-back
        // -----------------------------------------------------------------
        write_reg(8'hD0, 8'h05);     // SPRITE_SEL = 5
        write_reg(8'hD1, 8'h12);     // B0: prio = 5'h12 = 5'b10010 → 18
        write_reg(8'hD2, 8'h08);     // B1: log2_size = 4'h8 (256×256)
        write_reg(8'hD3, 8'h34);     // B2: arena_y[7:0] = 0x34
        write_reg(8'hD4, 8'h56);     // B3: arena_x[11:8]=5, arena_y[11:8]=6
        write_reg(8'hD5, 8'h78);     // B4: arena_x[7:0] = 0x78
        write_reg(8'hD6, 8'h9A);     // B5: screen_y[7:0] = 0x9A
        write_reg(8'hD7, 8'h0B);     // B6: screen_x[11:8]=0, screen_y[11:8]=0xB
        write_reg(8'hD8, 8'hCD);     // B7: screen_x[7:0] = 0xCD, commits

        // arena_x = {0x5, 0x78} = 12'h578
        // arena_y = {0x6, 0x34} = 12'h634
        // screen_x = signed {0x0, 0xCD} = 12'h0CD = +205
        // screen_y = signed {0xB, 0x9A} = 12'hB9A → bit 11 set → negative
        expect_reg(8'hD1, 8'h12, "desc B0 read-back (prio)");
        expect_reg(8'hD2, 8'h08, "desc B1 read-back (log2_size)");
        expect_reg(8'hD3, 8'h34, "desc B2 read-back (arena_y lo)");
        expect_reg(8'hD4, 8'h56, "desc B3 read-back (arena_x hi | arena_y hi)");
        expect_reg(8'hD5, 8'h78, "desc B4 read-back (arena_x lo)");
        expect_reg(8'hD6, 8'h9A, "desc B5 read-back (screen_y lo)");
        expect_reg(8'hD7, 8'h0B, "desc B6 read-back (screen_x hi | screen_y hi)");
        expect_reg(8'hD8, 8'hCD, "desc B7 read-back (screen_x lo)");

        // -----------------------------------------------------------------
        // 3) Sprite 7: no commit — shadow updated, but descriptor stays 0.
        // -----------------------------------------------------------------
        write_reg(8'hD0, 8'h07);     // SPRITE_SEL = 7
        // Reads of B0..B7 should reflect sprite-7's still-zero descriptor.
        expect_reg(8'hD1, 8'h00, "sprite 7 B0 should be 0 (no commit)");
        expect_reg(8'hD3, 8'h00, "sprite 7 B2 should be 0 (no commit)");
        expect_reg(8'hD8, 8'h00, "sprite 7 B7 should be 0 (no commit)");

        // Write only B0 — shadow updates, but no commit to sprite 7.
        write_reg(8'hD1, 8'hAA);
        expect_reg(8'hD1, 8'h00, "sprite 7 B0 still 0 (shadow only, no B7)");

        // Now commit with B7 to actually latch the descriptor.
        write_reg(8'hD2, 8'h03);
        write_reg(8'hD3, 8'h11);
        write_reg(8'hD4, 8'h22);
        write_reg(8'hD5, 8'h33);
        write_reg(8'hD6, 8'h44);
        write_reg(8'hD7, 8'h55);
        write_reg(8'hD8, 8'h66);     // commit
        expect_reg(8'hD1, 8'b0000_1010, "sprite 7 B0 after commit (prio[4:0] from 0xAA)");
        expect_reg(8'hD2, 8'h03, "sprite 7 B1 after commit");
        expect_reg(8'hD3, 8'h11, "sprite 7 B2 after commit");
        expect_reg(8'hD8, 8'h66, "sprite 7 B7 after commit");

        // -----------------------------------------------------------------
        // 4) Sprite 5 descriptor still intact after sprite-7 commit
        // -----------------------------------------------------------------
        write_reg(8'hD0, 8'h05);
        expect_reg(8'hD1, 8'h12, "sprite 5 B0 still intact after sprite 7 commit");
        expect_reg(8'hD8, 8'hCD, "sprite 5 B7 still intact after sprite 7 commit");

        // -----------------------------------------------------------------
        // 5) Collision W1C — no sets wired yet, so values stay at 0.
        //    Confirms address decode and that writes don't corrupt other rows.
        // -----------------------------------------------------------------
        write_reg(8'hD9, 8'h00);     // COL_SEL = 0
        expect_reg(8'hDA, 8'h00, "collision row 0 lo after reset");
        expect_reg(8'hDB, 8'h00, "collision row 0 hi after reset");
        write_reg(8'hDA, 8'hFF);     // try to clear all
        write_reg(8'hDB, 8'hFF);
        expect_reg(8'hDA, 8'h00, "collision row 0 lo still 0 after W1C");
        expect_reg(8'hDB, 8'h00, "collision row 0 hi still 0 after W1C");

        // -----------------------------------------------------------------
        // 6) Global enable
        // -----------------------------------------------------------------
        expect_reg(8'hDF, 8'h00, "global_enable after reset");
        write_reg(8'hDF, 8'h01);
        expect_reg(8'hDF, 8'h01, "global_enable = 1");
        write_reg(8'hDF, 8'h00);
        expect_reg(8'hDF, 8'h00, "global_enable = 0");

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        if (errors == 0) $display("*** SPRITE_REGS OK ***");
        else             $display("FAIL: tb_sprite_regs reported %0d error(s)", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #200_000;
        $display("FAIL: tb_sprite_regs watchdog");
        $finish;
    end

endmodule
