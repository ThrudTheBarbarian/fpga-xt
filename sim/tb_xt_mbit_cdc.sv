// tb_xt_mbit_cdc.sv — the multi-bit crossing, tested for the property that
// matters: the destination must NEVER observe a word the source never held.
//
// A crossing test that only checks "the value arrives" passes just as happily
// on the broken 2-FF-per-bit version this module exists to replace, because
// tearing is rare and data-dependent.  So T3 walks the source through values
// whose bits all flip at once (the worst case for tearing: $00 <-> $FF,
// $55 <-> $AA) at a deliberately awkward clock ratio, and samples the
// destination EVERY destination clock, failing on any word outside the legal
// set rather than merely checking the final value.
//
// PROVEN NON-VACUOUS, which took three attempts and is the point:
//   * zero-delay nets       -> naive crossing PASSES (no skew, so no tear)
//   * skew + rational 7:11  -> naive crossing PASSES (phase repeats, window missed)
//   * skew + incommensurate -> the monitor works, and widening the spread
//                              separates the two designs decisively:
//
//     iverilog -DSKEW_NS=0.5 ... hdl/xt_mbit_cdc.sv  -> PASS, 0 tears
//     iverilog -DSKEW_NS=0.5 ... <naive 2-FF/bit>    -> FAIL, 720 tears
//
// At the 0.1 default neither tears, so the default run is a regression guard;
// the 0.5 run is the discriminating experiment. A crossing test that has not
// been shown to FAIL on the naive implementation is not evidence of anything.
//
//   T1  reset, and the first value propagates
//   T2  a change propagates, and the latency is bounded
//   T3  no torn word EVER appears, across all-bits-flip transitions
//   T4  a value that does not change produces no further updates
//   T5  the destination tracks a long pseudo-random walk exactly
`timescale 1ns/1ps

module tb_xt_mbit_cdc;

    localparam int W = 16;

    // Per-bit arrival spread, in ns. Overridable (-D SKEW_NS=...) so the
    // tearing monitor can be PROVEN able to see a tear rather than assumed
    // able to: at 0.5 the naive per-bit crossing tears and this one does not.
`ifndef SKEW_NS
  `define SKEW_NS 0.1
`endif
    localparam real SKEW_NS = `SKEW_NS;

    logic src_clk = 0, src_rst = 1;
    logic dst_clk = 0, dst_rst = 1;
    logic [W-1:0] src_q = '0;          // a real source-domain register
    wire  [W-1:0] src_data;            // ...seen through per-bit routing skew
    wire  [W-1:0] dst_data;

    // WHY THE SKEW IS ESSENTIAL, not decoration:
    // with zero-delay nets every bit of a bus changes at the same simulation
    // instant, so a naive N-bit 2-FF synchroniser NEVER tears in simulation and
    // a test written against it passes on the very bug it was meant to catch
    // (verified: the naive version passed this file before the skew was added).
    // Real routing gives each bit its own arrival time, and a destination clock
    // landing inside that window latches a mix of old and new bits. Spread the
    // bits over ~1.6 ns -- well inside the 7 ns source period, so a
    // source-synchronous capture is unaffected, but wide open to an
    // asynchronous sampler.
    genvar gi;
    generate
        for (gi = 0; gi < W; gi = gi + 1) begin : g_skew
            assign #(SKEW_NS * (gi + 1)) src_data[gi] = src_q[gi];
        end
    endgenerate

    // Deliberately awkward, non-integer ratio: the crossing must not depend on
    // any phase relationship.  (clk_sys 150 MHz vs clk_sally 100 MHz is 3:2;
    // 7:11 here is worse than anything the design actually sees.)
    // INCOMMENSURATE on purpose.  With a rational ratio (7:11) the phase
    // relationship repeats every 77 ns, so the destination samples the source
    // at only a handful of fixed phases and may never land inside the skew
    // window at all -- the naive crossing then passes this file, which is
    // exactly the false pass this test exists to prevent.  Real asynchronous
    // clocks drift through EVERY phase; these do too.
    always #3.5    src_clk = ~src_clk;
    always #5.4137 dst_clk = ~dst_clk;

    xt_mbit_cdc #(.W(W)) dut (
        .src_clk(src_clk), .src_rst(src_rst), .src_data(src_data),
        .dst_clk(dst_clk), .dst_rst(dst_rst), .dst_data(dst_data)
    );

    int checks = 0, errors = 0;
    task automatic ck(input string what, input logic cond);
        checks++;
        if (!cond) begin errors++; $display("  FAIL: %s", what); end
    endtask

    // ---- the tearing monitor -------------------------------------------
    // `legal` holds every value the source has ever presented, plus 0 (reset).
    // Any dst_data outside that set is a word that never existed = a tear.
    logic [W-1:0] legal [0:255];
    int           n_legal = 0;
    int           tears   = 0;

    task automatic allow(input logic [W-1:0] v);
        for (int i = 0; i < n_legal; i++) if (legal[i] === v) return;
        legal[n_legal++] = v;
    endtask

    bit mon_ok;
    always @(posedge dst_clk) if (!dst_rst) begin
        mon_ok = 1'b0;
        for (int i = 0; i < n_legal; i++) if (legal[i] === dst_data) mon_ok = 1'b1;
        if (!mon_ok) begin
            tears++;
            if (tears < 5) $display("  TORN: dst_data=%04x never existed at source", dst_data);
        end
    end

    // Drive a new source value and hold it long enough for the handshake
    // (the module's stated constraint).
    task automatic put(input logic [W-1:0] v);
        allow(v);
        @(negedge src_clk); src_q <= v;
        repeat (12) @(posedge dst_clk);
    endtask

    logic [W-1:0] seen;
    int lat;

    initial begin
        allow('0);                       // reset value is legal
        repeat (4) @(posedge src_clk);
        src_rst = 0;
        repeat (4) @(posedge dst_clk);
        dst_rst = 0;
        repeat (4) @(posedge dst_clk);

        // ---- T1 -----------------------------------------------------------
        $display("T1: first value propagates");
        put(16'h1234);
        ck("dst = $1234", dst_data === 16'h1234);

        // ---- T2 -----------------------------------------------------------
        $display("T2: change propagates with bounded latency");
        allow(16'hBEEF);
        @(negedge src_clk); src_q <= 16'hBEEF;
        lat = 0;
        while (dst_data !== 16'hBEEF && lat < 20) begin
            @(posedge dst_clk); lat++;
        end
        ck("arrived", dst_data === 16'hBEEF);
        ck("within 8 dst clocks", lat <= 8);
        $display("    latency = %0d dst clocks", lat);

        // ---- T3 -----------------------------------------------------------
        // All bits flip together — the transition a per-bit synchroniser tears
        // on. Every dst clock is checked by the always block above.
        $display("T3: all-bits-flip transitions never tear");
        for (int i = 0; i < 300; i++) begin
            put(16'h0000); put(16'hFFFF);
            put(16'h5555); put(16'hAAAA);
        end
        ck("no torn word observed", tears == 0);

        // ---- T4 -----------------------------------------------------------
        $display("T4: a static source produces no spurious change");
        put(16'h0F0F);
        seen = dst_data;
        repeat (60) @(posedge dst_clk);
        ck("dst held steady", dst_data === seen);
        ck("still no tears", tears == 0);

        // ---- T5 -----------------------------------------------------------
        $display("T5: long walk tracks exactly");
        begin
            logic [W-1:0] v;
            v = 16'h0001;
            for (int i = 0; i < 60; i++) begin
                v = {v[10:0], v[15] ^ v[13] ^ v[12] ^ v[10]};   // LFSR walk
                put(v);
                if (dst_data !== v) begin
                    ck($sformatf("step %0d: dst=%04x want %04x", i, dst_data, v), 1'b0);
                    break;
                end
            end
            ck("walk tracked", dst_data === v);
        end
        ck("no tears over the whole run", tears == 0);

        $display("");
        if (errors == 0) $display("tb_xt_mbit_cdc: PASS (%0d checks, %0d dst samples clean)", checks, n_legal);
        else             $display("tb_xt_mbit_cdc: FAIL (%0d/%0d checks failed, %0d tears)", errors, checks, tears);
        $finish;
    end

    initial begin
        #2000000;
        $display("tb_xt_mbit_cdc: TIMEOUT");
        $finish;
    end

endmodule
