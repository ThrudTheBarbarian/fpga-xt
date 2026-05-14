// tmds_encoder.sv — DVI 1.0 §3.2.2 TMDS 8b/10b encoder.
//
// Per-pixel inputs:
//   data[7:0]   raw 8-bit channel value (R, G or B)
//   c[1:0]      control bits — used only when de == 0
//                  blue : c = {VSYNC, HSYNC}
//                  red/green: c = 2'b00
//   de          data enable. 1 = encode `data`. 0 = emit one of four
//                control codes selected by `c`.
//   clk, rst    pixel clock + sync reset
//
// Output:
//   q_out[9:0]  TMDS symbol. Serializer transmits LSB first.
//
// The encoder is a 1-clock pipeline:
//   stage A (combinational): produce the 9-bit q_m intermediate
//                            (transition-minimized).
//   stage B (registered):    apply DC balancing using the running
//                            disparity counter; emit q_out.
//
// Reference: DVI 1.0 specification, Figure 3-5 + §3.2.2.

`default_nettype none

module tmds_encoder (
    input  wire        clk,
    input  wire        rst,
    input  wire  [7:0] data,
    input  wire  [1:0] c,
    input  wire        de,
    output logic [9:0] q_out
);

    // ---- Stage A — transition-minimized 9-bit q_m ----------------------
    // Count of 1s in data; 4-bit (max 8 fits in 4).
    function automatic logic [3:0] popcount8(input logic [7:0] x);
        return {3'd0, x[0]} + {3'd0, x[1]} + {3'd0, x[2]} + {3'd0, x[3]}
             + {3'd0, x[4]} + {3'd0, x[5]} + {3'd0, x[6]} + {3'd0, x[7]};
    endfunction

    logic [3:0] n1d;        // # of 1s in data
    logic       use_xnor;   // XNOR encoding selected
    logic [8:0] q_m;        // q_m[8] = 0 → XNOR, 1 → XOR

    assign n1d      = popcount8(data);
    // DVI spec: use XNOR when N1(D) > 4, OR (N1(D) == 4 AND D[0] == 0).
    assign use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && data[0] == 1'b0);

    always_comb begin : sblk_qm
        logic [7:0] qm_data;
        qm_data[0] = data[0];
        if (use_xnor) begin
            qm_data[1] = qm_data[0] ~^ data[1];
            qm_data[2] = qm_data[1] ~^ data[2];
            qm_data[3] = qm_data[2] ~^ data[3];
            qm_data[4] = qm_data[3] ~^ data[4];
            qm_data[5] = qm_data[4] ~^ data[5];
            qm_data[6] = qm_data[5] ~^ data[6];
            qm_data[7] = qm_data[6] ~^ data[7];
            q_m = {1'b0, qm_data};
        end else begin
            qm_data[1] = qm_data[0]  ^ data[1];
            qm_data[2] = qm_data[1]  ^ data[2];
            qm_data[3] = qm_data[2]  ^ data[3];
            qm_data[4] = qm_data[3]  ^ data[4];
            qm_data[5] = qm_data[4]  ^ data[5];
            qm_data[6] = qm_data[5]  ^ data[6];
            qm_data[7] = qm_data[6]  ^ data[7];
            q_m = {1'b1, qm_data};
        end
    end

    // ---- Stage B — DC balance via running disparity counter ------------
    // cnt is signed 5-bit (range -16..+15). DVI keeps it in [-7,+7] but
    // 5 bits gives margin against the +/- 5 step per symbol.
    logic signed [4:0] cnt;

    // # of 1s and 0s in q_m[7:0] (excluding q_m[8]).
    logic [3:0] n1qm;
    logic [3:0] n0qm;
    logic signed [4:0] diff;          // n1qm - n0qm, signed

    always_comb begin
        n1qm = popcount8(q_m[7:0]);
        n0qm = 4'd8 - n1qm;
        diff = $signed({1'b0, n1qm}) - $signed({1'b0, n0qm});
    end

    // Control-code lookup. Per DVI spec Figure 3-3.
    function automatic logic [9:0] ctl_code(input logic [1:0] cc);
        case (cc)
            2'b00: return 10'b1101010100;
            2'b01: return 10'b0010101011;
            2'b10: return 10'b0101010100;
            2'b11: return 10'b1010101011;
        endcase
    endfunction

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt   <= 5'sd0;
            q_out <= 10'h0;
        end else if (!de) begin
            // Control period — emit fixed code, reset disparity.
            q_out <= ctl_code(c);
            cnt   <= 5'sd0;
        end else begin : sblk_balance
            logic [9:0]        sym;
            logic signed [4:0] new_cnt;
            // Three balancing cases per DVI spec:
            //   1) cnt == 0 OR n1==n0 — flip data + use bit 9 to mark choice
            //   2) cnt and (n1-n0) same sign — invert
            //   3) otherwise — pass through
            if (cnt == 5'sd0 || diff == 5'sd0) begin
                sym[9]   = ~q_m[8];
                sym[8]   =  q_m[8];
                sym[7:0] = q_m[8] ? q_m[7:0] : ~q_m[7:0];
                if (q_m[8] == 1'b0)
                    new_cnt = cnt - diff;        // inverted: contributes -diff
                else
                    new_cnt = cnt + diff;
            end else if ((cnt > 5'sd0 && diff > 5'sd0)
                      || (cnt < 5'sd0 && diff < 5'sd0)) begin
                // Same sign — invert to drag cnt back toward 0.
                sym[9]   = 1'b1;
                sym[8]   = q_m[8];
                sym[7:0] = ~q_m[7:0];
                // q_m[8] adds +2 to cnt when 1 (extra '1' transmitted in [8]).
                new_cnt  = cnt + (q_m[8] ? 5'sd2 : 5'sd0) - diff;
            end else begin
                sym[9]   = 1'b0;
                sym[8]   = q_m[8];
                sym[7:0] = q_m[7:0];
                // q_m[8]==0 subtracts 2 (extra '0' in [8]).
                new_cnt  = cnt - (q_m[8] ? 5'sd0 : 5'sd2) + diff;
            end
            q_out <= sym;
            cnt   <= new_cnt;
        end
    end

endmodule

`default_nettype wire
