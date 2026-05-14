// tb_terc4.sv — verify terc4_encoder against the HDMI 1.4a Table 5-7
// reference values. Also check DC balance: each code has exactly 5
// ones and 5 zeros, since the mapping is fixed (no running disparity).

`default_nettype none
`timescale 1ns / 1ps

module tb_terc4;

    logic [3:0] data;
    wire  [9:0] q_out;

    terc4_encoder u_dut (.data(data), .q_out(q_out));

    function automatic int popcount10(input logic [9:0] x);
        int n;
        n = 0;
        for (int i = 0; i < 10; i++) if (x[i]) n++;
        return n;
    endfunction

    int fail_count = 0;

    initial begin
        logic [9:0] expected [0:15];
        expected[0]  = 10'b1010011100;
        expected[1]  = 10'b1001100011;
        expected[2]  = 10'b1011100100;
        expected[3]  = 10'b1011100010;
        expected[4]  = 10'b0101110001;
        expected[5]  = 10'b0100011110;
        expected[6]  = 10'b0110001110;
        expected[7]  = 10'b0100111100;
        expected[8]  = 10'b1011001100;
        expected[9]  = 10'b0100111001;
        expected[10] = 10'b0110011100;
        expected[11] = 10'b1011000110;
        expected[12] = 10'b1010001110;
        expected[13] = 10'b1001110001;
        expected[14] = 10'b0101100011;
        expected[15] = 10'b1011000011;

        $display("[terc4] start");
        for (int i = 0; i < 16; i = i + 1) begin
            data = i[3:0];
            #1;
            if (q_out !== expected[i]) begin
                $display("[lut] FAIL d=%01h q=%010b exp=%010b",
                         data, q_out, expected[i]);
                fail_count++;
            end
            if (popcount10(q_out) !== 5) begin
                $display("[dc] FAIL d=%01h q=%010b ones=%0d (expected 5)",
                         data, q_out, popcount10(q_out));
                fail_count++;
            end
        end

        if (fail_count == 0) begin
            $display("*** TERC4 OK *** 16 codes verified + DC balance");
            $finish;
        end else begin
            $display("*** TERC4 FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

endmodule

`default_nettype wire
