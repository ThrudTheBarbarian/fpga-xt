// tb_xt_sio_mbox.sv — the paravirtual SIO mailbox, driven the way the real two
// sides drive it: the ROM stub's exact access sequence on the 6502 port and the
// worker task's exact sequence on the A9 port.
//
// The bug this module exists to fix was invisible to every module-level test in
// the repo, because it was a coupling between two things that each worked: the
// stub polled $D5C7.0 and math_cop -- which owned that bit -- was no longer
// built.  So the checks here are about the CONTRACT, not the storage:
//
//   T1  reset: idle reads done=1, and the aperture above the mailbox reads $00
//   T2  the 6502 can write and read back the page (DCB + magic offsets)
//   T3  the doorbell drops `done` and raises the A9 event + IRQ
//   T4  reading MATH_EVT consumes the event but does NOT complete the request
//   T5  the A9 reads what the 6502 wrote, through the indirect window
//   T6  MATH_DONE raises `done` -- the loop the stub spins in actually exits
//   T7  the 6502 reads what the A9 wrote (status, flags, payload)
//   T8  a second request works (toggles, not levels -- no stuck state)
//   T9  cpu_rden low FREEZES the read register (the stall-alignment rule)
//
// Clocks are the real ratio: clk_sys 100 MHz, clk_sally 100 MHz but the CPU
// port only moves on rdy, so the mesochronous crossing is exercised rather
// than a compressed toy version.
`timescale 1ns/1ps

module tb_xt_sio_mbox;

    // ---- mathcop.h offsets the stub and the service agree on ----
    localparam int OFF_STATUS = 'h003;
    localparam int OFF_FLAGS  = 'h004;
    localparam int OFF_MAGIC  = 'h005;
    localparam int OFF_DCB    = 'h040;
    localparam int OFF_DATA   = 'h0C0;
    localparam byte SIO_MAGIC = 8'h5A;

    logic clk = 0, rst = 1;
    logic clk_cpu = 0, rst_cpu = 1;

    always #5    clk     = ~clk;        // 100 MHz clk_sys
    always #5.13 clk_cpu = ~clk_cpu;    // 100 MHz clk_sally, deliberately not phase-locked

    // A9 side
    logic [8:0]  evt_data;
    logic        evt_pop = 0, evt_irq, done_we = 0;
    logic [31:0] stat_word;
    logic [8:0]  a9_ptr = 0;
    logic        a9_ptr_we = 0, a9_we = 0, a9_rd = 0;
    logic [31:0] a9_wdata = 0, a9_rdata;

    // 6502 side
    logic        cpu_idx_we = 0, cpu_dat_we = 0, cpu_dat_re = 0, exec_we = 0;
    logic        drv_sel = 0;  logic [8:0] drv_addr = 0;  wire [7:0] drv_rdata;
    logic [7:0]  cpu_reg_wdata = 0, cpu_idx_rdata, cpu_dat_rdata;
    logic        done, busy, chunk_ready;

    xt_sio_mbox dut (
        .clk(clk), .rst(rst),
        .evt_data(evt_data), .evt_pop(evt_pop), .evt_irq(evt_irq),
        .done_we(done_we), .stat_word(stat_word),
        .a9_ptr(a9_ptr), .a9_ptr_we(a9_ptr_we),
        .a9_wdata(a9_wdata), .a9_we(a9_we), .a9_rd(a9_rd), .a9_rdata(a9_rdata),
        .clk_cpu(clk_cpu), .rst_cpu(rst_cpu),
        .cpu_idx_we(cpu_idx_we), .cpu_dat_we(cpu_dat_we), .cpu_dat_re(cpu_dat_re),
        .cpu_reg_wdata(cpu_reg_wdata),
        .cpu_idx_rdata(cpu_idx_rdata), .cpu_dat_rdata(cpu_dat_rdata),
        .drv_sel(drv_sel), .drv_addr(drv_addr), .drv_rdata(drv_rdata),
        .exec_we(exec_we), .done(done), .busy(busy), .chunk_ready(chunk_ready)
    );

    int checks = 0, errors = 0;

    task automatic ck(input string what, input logic cond);
        checks++;
        if (!cond) begin
            errors++;
            $display("  FAIL: %s", what);
        end
    endtask

    // ---- the 6502 port, driven on the negedge (stimulus must never race the
    // DUT's posedge -- that lesson cost a day twice; docs/ANTIC-rewrite.md) ----
    // $D5CD -- set the byte index (8 bits; auto-increment carries above it)
    task automatic cpu_setidx(input int idx);
        @(negedge clk_cpu);
        cpu_reg_wdata <= idx[7:0]; cpu_idx_we <= 1'b1;
        @(negedge clk_cpu);
        cpu_idx_we <= 1'b0;
    endtask

    // $D5CE write -- store at the index, then post-increment
    task automatic cpu_put(input byte val);
        @(negedge clk_cpu);
        cpu_reg_wdata <= val; cpu_dat_we <= 1'b1;
        @(negedge clk_cpu);
        cpu_dat_we <= 1'b0;
    endtask

    // $D5CE read -- the byte at the index, then post-increment
    task automatic cpu_get(output byte val);
        @(negedge clk_cpu);
        val = cpu_dat_rdata;         // sally_mem samples BEFORE the strobe
        cpu_dat_re <= 1'b1;
        @(negedge clk_cpu);
        cpu_dat_re <= 1'b0;
        @(negedge clk_cpu);          // let the read register track the new index
    endtask

    // The old aperture-shaped helpers, kept so the existing tests read the same
    task automatic cpu_write(input int addr, input byte val);
        cpu_setidx(addr);
        cpu_put(val);
    endtask

    task automatic cpu_read(input int addr, output byte val);
        cpu_setidx(addr);
        @(negedge clk_cpu);          // registered read lands here
        val = cpu_dat_rdata;
    endtask

    task automatic cpu_doorbell();  // the $D5C7 write
        @(negedge clk_cpu);
        exec_we <= 1'b1;
        @(negedge clk_cpu);
        exec_we <= 1'b0;
    endtask

    // ---- the A9 port ----
    task automatic a9_seek(input int byte_addr);
        @(negedge clk);
        a9_ptr <= byte_addr[8:0]; a9_ptr_we <= 1'b1;
        @(negedge clk);
        a9_ptr_we <= 1'b0;
        @(negedge clk);              // let the read register track the new pointer
    endtask

    task automatic a9_read_word(output logic [31:0] val);
        @(negedge clk);
        val = a9_rdata;              // sampled as the GP0 read FSM does
        a9_rd <= 1'b1;
        @(negedge clk);
        a9_rd <= 1'b0;
        @(negedge clk);
    endtask

    task automatic a9_write_word(input logic [31:0] val);
        @(negedge clk);
        a9_wdata <= val; a9_we <= 1'b1;
        @(negedge clk);
        a9_we <= 1'b0;
        @(negedge clk);
    endtask

    task automatic a9_pop_event();
        @(negedge clk);
        evt_pop <= 1'b1;
        @(negedge clk);
        evt_pop <= 1'b0;
    endtask

    task automatic a9_signal_done();
        @(negedge clk);
        done_we <= 1'b1;
        @(negedge clk);
        done_we <= 1'b0;
    endtask

    // Wait for `done`, bounded — an unbounded wait is how the real bug looked
    // (the 6502 spinning for ever), so the testbench must never do that either.
    task automatic wait_done(input int max_cycles, output logic ok);
        int n = 0;
        ok = 0;
        while (n < max_cycles) begin
            @(negedge clk_cpu);
            if (done) begin ok = 1; return; end
            n++;
        end
    endtask

    byte         b;
    logic [31:0] w;
    logic        ok;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0; rst_cpu = 0;
        repeat (4) @(posedge clk_cpu);

        // ---- T1: idle state -------------------------------------------------
        $display("T1: reset state");
        ck("idle done=1", done === 1'b1);
        ck("idle busy=0", busy === 1'b0);
        ck("chunk_ready=1", chunk_ready === 1'b1);
        ck("no event pending", evt_irq === 1'b0);
        ck("evt not valid", evt_data[8] === 1'b0);
        cpu_read('h1FF, b);                 // above the 512 B mailbox
        ck("aperture above the mailbox reads $00", b === 8'h00);

        // ---- T2: the 6502 writes its request --------------------------------
        $display("T2: 6502 writes the DCB and the magic");
        // DDEVIC $31, DUNIT 1, READ sector 1 into $0400, 128 bytes
        cpu_write(OFF_DCB + 0, 8'h31);
        cpu_write(OFF_DCB + 1, 8'h01);
        cpu_write(OFF_DCB + 2, 8'h52);      // 'R'
        cpu_write(OFF_DCB + 3, 8'h40);      // DSTATS: read
        cpu_write(OFF_DCB + 4, 8'h00);      // DBUF = $0400
        cpu_write(OFF_DCB + 5, 8'h04);
        cpu_write(OFF_DCB + 8, 8'h80);      // DBYT = 128
        cpu_write(OFF_DCB + 9, 8'h00);
        cpu_write(OFF_MAGIC,   SIO_MAGIC);

        cpu_read(OFF_DCB + 2, b);
        ck("DCB command reads back", b === 8'h52);
        cpu_read(OFF_MAGIC, b);
        ck("magic reads back", b === SIO_MAGIC);

        // ---- T3: the doorbell -----------------------------------------------
        $display("T3: doorbell drops done, raises the A9 event");
        cpu_doorbell();
        repeat (6) @(posedge clk_cpu);
        ck("done drops on the doorbell", done === 1'b0);
        ck("busy raised", busy === 1'b1);
        repeat (6) @(posedge clk);
        ck("A9 sees the event", evt_data[8] === 1'b1);
        ck("event carries the SIO chunk", evt_data[7:0] === 8'hFF);
        ck("IRQ raised", evt_irq === 1'b1);
        ck("stat pending", stat_word[0] === 1'b1);

        // ---- T4: consuming the event is not the same as answering -----------
        $display("T4: MATH_EVT read consumes the event only");
        a9_pop_event();
        repeat (2) @(posedge clk);
        ck("event consumed", evt_data[8] === 1'b0);
        ck("IRQ dropped", evt_irq === 1'b0);
        ck("but the 6502 is still waiting", done === 1'b0);

        // ---- T5: the A9 reads the request through the window -----------------
        $display("T5: A9 reads the DCB the 6502 wrote");
        a9_seek(OFF_DCB);
        a9_read_word(w);
        ck("DCB[0..3] = 40 52 01 31", w === 32'h40_52_01_31);
        a9_read_word(w);                    // auto-incremented to OFF_DCB+4
        ck("DCB[4..7] DBUF=$0400", w[15:0] === 16'h0400);
        a9_seek(OFF_MAGIC & ~32'h3);        // magic is byte 1 of word $004
        a9_read_word(w);
        ck("A9 sees the magic byte", w[15:8] === SIO_MAGIC);

        // ---- T6: the A9 answers ---------------------------------------------
        $display("T6: A9 writes the answer, then MATH_DONE");
        a9_seek(OFF_DATA);
        a9_write_word(32'hDEADBEEF);
        a9_write_word(32'h01020304);        // auto-incremented
        // status is byte 3 of word $000; flags byte 0 (and magic byte 1) of word $004
        a9_seek(OFF_STATUS & ~32'h3);
        a9_write_word(32'h01_00_00_00);     // page[$003] = $01  (st = OK)
        a9_seek(OFF_FLAGS & ~32'h3);
        a9_write_word(32'h00_00_00_01);     // page[$004] = $01 (DELIVERED), magic consumed
        a9_signal_done();
        wait_done(200, ok);
        ck("the stub's spin loop exits", ok === 1'b1);
        ck("busy cleared", busy === 1'b0);

        // ---- T7: the 6502 collects the answer -------------------------------
        $display("T7: 6502 reads back what the A9 wrote");
        cpu_read(OFF_DATA + 0, b); ck("payload[0]", b === 8'hEF);
        cpu_read(OFF_DATA + 3, b); ck("payload[3]", b === 8'hDE);
        cpu_read(OFF_DATA + 4, b); ck("payload[4]", b === 8'h04);
        cpu_read(OFF_STATUS,  b);  ck("status byte", b === 8'h01);
        cpu_read(OFF_FLAGS,   b);  ck("flags byte (DELIVERED)", b === 8'h01);
        cpu_read(OFF_MAGIC,   b);  ck("magic consumed by the A9", b === 8'h00);

        // ---- T8: a second transaction ---------------------------------------
        // Toggle-based handshakes fail closed if anyone treated them as levels:
        // the SECOND request is where a stuck ack shows up.
        $display("T8: second request completes too");
        cpu_write(OFF_MAGIC, SIO_MAGIC);
        cpu_doorbell();
        repeat (6) @(posedge clk_cpu);
        ck("done drops again", done === 1'b0);
        repeat (6) @(posedge clk);
        ck("event raised again", evt_data[8] === 1'b1);
        a9_pop_event();
        a9_signal_done();
        wait_done(200, ok);
        ck("second request completes", ok === 1'b1);

        // ---- T9: the port walks, and only on a strobe -----------------------
        // The aperture port needed an rden gate because its address came from
        // the CPU's address bus and kept moving while the CPU was stalled.  The
        // index register cannot do that: it moves ONLY on an explicit $D5CD
        // write or a $D5CE access, so a stall is simply invisible to it.  That
        // is the property the gate used to buy, for free.
        $display("T9: index walks on access, and holds when nothing strobes");
        cpu_setidx(OFF_DATA);
        cpu_get(b); ck("auto-inc byte 0", b === 8'hEF);
        cpu_get(b); ck("auto-inc byte 1", b === 8'hBE);
        cpu_get(b); ck("auto-inc byte 2", b === 8'hAD);
        ck("index advanced to +3", cpu_idx_rdata === 8'(OFF_DATA + 3));
        repeat (8) @(negedge clk_cpu);        // CPU stalled: no strobes at all
        ck("index held through the stall", cpu_idx_rdata === 8'(OFF_DATA + 3));
        cpu_get(b); ck("resumes at +3", b === 8'hDE);

        // ---- T10: the index carries past $FF --------------------------------
        // The counter is MBOX_LOG2 bits but is SET 8 at a time, so a payload
        // placed at $C0 walks across $FF -> $100 without the stub touching
        // $D5CD again.  That is what lets the mailbox keep mathcop.h's layout.
        $display("T10: auto-increment carries past $FF into the 9th bit");
        a9_seek('h0FC); a9_write_word(32'hDDCCBBAA);   // bytes $FC..$FF
        a9_seek('h100); a9_write_word(32'h44332211);   // bytes $100..$103
        cpu_setidx('hFC);
        cpu_get(b); ck("byte $FC", b === 8'hAA);
        cpu_get(b); ck("byte $FD", b === 8'hBB);
        cpu_get(b); ck("byte $FE", b === 8'hCC);
        cpu_get(b); ck("byte $FF", b === 8'hDD);
        cpu_get(b); ck("byte $100 (carried)", b === 8'h11);
        cpu_get(b); ck("byte $101", b === 8'h22);

        // ---- T11: the drive's read port shares port A without disturbing it --
        // The virtual drive reads the reply payload while it paces bytes onto
        // the serial bus.  It shares port A with the $D5CD/$D5CE register port,
        // so two things must hold: it reads the byte it ASKED for, and it does
        // not move the register index underneath the 6502.
        $display("T11: drive read port — correct byte, register index untouched");
        cpu_setidx('h040);                    // park it on DCB[0], written in T2
        @(negedge clk_cpu);
        drv_sel = 1'b1; drv_addr = 9'h0C0;    // payload base
        repeat (4) @(negedge clk_cpu);
        ck("drive reads payload[0]", drv_rdata === 8'hEF);
        drv_addr = 9'h0C3;
        repeat (4) @(negedge clk_cpu);
        ck("drive reads payload[3]", drv_rdata === 8'hDE);
        drv_addr = 9'h100;                    // above $FF — the 9th bit works here too
        repeat (4) @(negedge clk_cpu);
        ck("drive reads across $FF", drv_rdata === 8'h11);
        @(negedge clk_cpu); drv_sel = 1'b0;
        repeat (4) @(negedge clk_cpu);
        ck("register index survived the drive's reads", cpu_idx_rdata === 8'h40);
        cpu_get(b);
        ck("register port still reads its own byte", b === 8'h31);

        // ---- result ---------------------------------------------------------
        $display("");
        if (errors == 0) $display("tb_xt_sio_mbox: PASS (%0d checks)", checks);
        else             $display("tb_xt_sio_mbox: FAIL (%0d/%0d checks failed)", errors, checks);
        $finish;
    end

    initial begin
        #500000;
        $display("tb_xt_sio_mbox: TIMEOUT");
        $finish;
    end

endmodule
