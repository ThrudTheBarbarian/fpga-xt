// tb_hdmi_bch.sv — verify the hdmi_bch_24 and hdmi_bch_56 encoders
// against a software reference computing the same BCH polynomial.
//
// HDMI BCH generator: g(x) = x^8 + x^7 + x^6 + x^4 + 1.
// Verifies both modules produce the same output for a sweep of input
// patterns (zeros, ones, single-bit walks, alternating, randomish).

`default_nettype none
`timescale 1ns / 1ps

module tb_hdmi_bch;

    logic [23:0] data24;
    logic [55:0] data56;
    wire  [7:0]  ecc24, ecc56;

    hdmi_bch_24 u_b24 (.data(data24), .ecc(ecc24));
    hdmi_bch_56 u_b56 (.data(data56), .ecc(ecc56));

    // Reference BCH model — same polynomial, computed in a function.
    function automatic logic [7:0] bch_ref(input integer width,
                                            input logic [55:0] payload);
        logic [7:0] r;
        logic       fb;
        integer     i;
        r = 8'h00;
        for (i = 0; i < width; i = i + 1) begin
            fb = r[7] ^ payload[width - 1 - i];
            r = {r[6:0], 1'b0} ^ (fb ? 8'hD1 : 8'h00);
        end
        return r;
    endfunction

    int fail_count = 0;

    initial begin
        $display("[bch] start");

        // ---- 24-bit ECC sweep -----------------------------------------
        data24 = 24'h000000;
        #1;
        if (ecc24 !== 8'h00) begin
            $display("[24/0] FAIL all-zero data → ecc=$%02h, expected 0", ecc24);
            fail_count++;
        end

        for (integer i = 0; i < 24; i = i + 1) begin
            data24 = 24'h1 << i;
            #1;
            if (ecc24 !== bch_ref(24, {32'h0, data24})) begin
                $display("[24/walk] FAIL bit=%0d data=$%06h dut=$%02h ref=$%02h",
                         i, data24, ecc24, bch_ref(24, {32'h0, data24}));
                fail_count++;
            end
        end

        data24 = 24'hAA55A5;
        #1;
        if (ecc24 !== bch_ref(24, {32'h0, data24})) begin
            $display("[24/x] FAIL data=$%06h dut=$%02h ref=$%02h",
                     data24, ecc24, bch_ref(24, {32'h0, data24}));
            fail_count++;
        end

        data24 = 24'hFFFFFF;
        #1;
        if (ecc24 !== bch_ref(24, {32'h0, data24})) begin
            $display("[24/ff] FAIL data=$%06h dut=$%02h ref=$%02h",
                     data24, ecc24, bch_ref(24, {32'h0, data24}));
            fail_count++;
        end

        // ---- 56-bit ECC spot checks -----------------------------------
        data56 = 56'h0;
        #1;
        if (ecc56 !== 8'h00) begin
            $display("[56/0] FAIL all-zero data → ecc=$%02h, expected 0", ecc56);
            fail_count++;
        end

        for (integer i = 0; i < 56; i = i + 8) begin
            data56 = 56'h1 << i;
            #1;
            if (ecc56 !== bch_ref(56, data56)) begin
                $display("[56/walk] FAIL bit=%0d ecc=$%02h ref=$%02h",
                         i, ecc56, bch_ref(56, data56));
                fail_count++;
            end
        end

        data56 = 56'hDEADBEEFCAFE01;
        #1;
        if (ecc56 !== bch_ref(56, data56)) begin
            $display("[56/x] FAIL data=$%014h dut=$%02h ref=$%02h",
                     data56, ecc56, bch_ref(56, data56));
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** BCH OK *** 24-bit + 56-bit ECC verified vs. reference");
            $finish;
        end else begin
            $display("*** BCH FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

endmodule

`default_nettype wire
