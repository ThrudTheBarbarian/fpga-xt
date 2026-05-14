// tb_prior.sv — M10 PRIOR / colour-resolver verification.
//
// Drives every PRIOR[3:0] ordering and the OR-mode bit through the
// color_resolver module with hand-built idx_buf vectors and asserts the
// output matches a software oracle. No DL / compositor in the path —
// this is a pure-combinational module under test.

`default_nettype none
`timescale 1ns / 1ps

module tb_prior;

    logic [11:0] idx_buf;     // M10c: 12-bit (PF + P|M shared + M-only nibble)
    logic [7:0] prior;
    logic [7:0] colpm0 = 8'h11;       // distinct sentinels per channel
    logic [7:0] colpm1 = 8'h22;
    logic [7:0] colpm2 = 8'h33;
    logic [7:0] colpm3 = 8'h44;
    logic [7:0] colpf0 = 8'h55;
    logic [7:0] colpf1 = 8'h66;
    logic [7:0] colpf2 = 8'h77;
    logic [7:0] colpf3 = 8'h88;
    logic [7:0] colbk  = 8'h99;
    wire  [7:0] color_out;

    color_resolver dut (
        .idx_buf  (idx_buf),
        .prior    (prior),
        .colpm0   (colpm0),
        .colpm1   (colpm1),
        .colpm2   (colpm2),
        .colpm3   (colpm3),
        .colpf0   (colpf0),
        .colpf1   (colpf1),
        .colpf2   (colpf2),
        .colpf3   (colpf3),
        .colbk    (colbk),
        .color_out(color_out)
    );

    int fail_count = 0;

    // GTIA-mode PF colour decode — matches color_resolver's pf_color_gtia.
    function automatic logic [7:0] gtia_oracle(input logic [3:0] nib,
                                                input logic [1:0] mode);
        case (mode)
            2'b01: return {colbk[7:4], nib};
            2'b10: case (nib)
                4'd0:    return colpm0;
                4'd1:    return colpm1;
                4'd2:    return colpm2;
                4'd3:    return colpm3;
                4'd4:    return colpf0;
                4'd5:    return colpf1;
                4'd6:    return colpf2;
                4'd7:    return colpf3;
                default: return colbk;
            endcase
            2'b11:   return {nib, colbk[3:0]};
            default: return 8'h0;
        endcase
    endfunction

    // Software oracle. Mirrors color_resolver's semantics in plain
    // imperative code — keeping the two implementations independent
    // catches typos in either.
    function automatic logic [7:0] oracle(input logic [7:0] idx,
                                           input logic [7:0] pr);
        logic pf0, pf1, pf2, pf3, p0v, p1v, p2v, p3v;
        logic pm_pres, pf_pres;
        logic [7:0] pm_c, pf_c;
        logic       or_mode, gtia_active;
        logic [1:0] gtia_mode;
        logic [3:0] nibble;
        pf0 = idx[0]; pf1 = idx[1]; pf2 = idx[2]; pf3 = idx[3];
        p0v = idx[4]; p1v = idx[5]; p2v = idx[6]; p3v = idx[7];
        or_mode     = pr[5];
        gtia_mode   = pr[7:6];
        gtia_active = (gtia_mode != 2'b00);
        nibble      = idx[3:0];

        pm_pres = p0v | p1v | p2v | p3v;
        if (or_mode)
            pm_c = (p0v ? colpm0 : 8'h0)
                 | (p1v ? colpm1 : 8'h0)
                 | (p2v ? colpm2 : 8'h0)
                 | (p3v ? colpm3 : 8'h0);
        else if (p0v) pm_c = colpm0;
        else if (p1v) pm_c = colpm1;
        else if (p2v) pm_c = colpm2;
        else if (p3v) pm_c = colpm3;
        else          pm_c = 8'h0;

        if (gtia_active) begin
            pf_pres = 1'b1;
            pf_c    = gtia_oracle(nibble, gtia_mode);
        end else begin
            pf_pres = pf0 | pf1 | pf2 | pf3;
            if      (pf0) pf_c = colpf0;
            else if (pf1) pf_c = colpf1;
            else if (pf2) pf_c = colpf2;
            else if (pf3) pf_c = colpf3;
            else          pf_c = 8'h0;
        end

        case (pr[3:0])
            4'b0010: begin
                if      (p0v | p1v) begin
                    if (or_mode) return (p0v ? colpm0 : 8'h0) | (p1v ? colpm1 : 8'h0);
                    else         return p0v ? colpm0 : colpm1;
                end
                else if (pf_pres)   return pf_c;
                else if (p2v | p3v) begin
                    if (or_mode) return (p2v ? colpm2 : 8'h0) | (p3v ? colpm3 : 8'h0);
                    else         return p2v ? colpm2 : colpm3;
                end
                else                return colbk;
            end
            4'b0100: begin
                if      (pf_pres) return pf_c;
                else if (pm_pres) return pm_c;
                else              return colbk;
            end
            4'b1000: begin
                // PRIOR[3]: PF-hi > PM > PF-lo > BG
                // GTIA mode collapses PF-hi/lo into a single layer
                // ("PF on top" semantic).
                if (gtia_active) begin
                    if      (pf_pres) return pf_c;
                    else if (pm_pres) return pm_c;
                    else              return colbk;
                end
                if      (pf0 | pf1) return pf0 ? colpf0 : colpf1;
                else if (pm_pres)   return pm_c;
                else if (pf2 | pf3) return pf2 ? colpf2 : colpf3;
                else                return colbk;
            end
            default: begin   // PRIOR[0] and undefined
                if      (pm_pres) return pm_c;
                else if (pf_pres) return pf_c;
                else              return colbk;
            end
        endcase
    endfunction

    task automatic check(input logic [7:0] idx, input logic [7:0] pr,
                          input string tag);
        logic [7:0] exp_v;
        idx_buf = idx;
        prior   = pr;
        #1;     // settle combinational
        exp_v = oracle(idx, pr);
        if (color_out !== exp_v) begin
            $display("[%s] FAIL idx=$%02h pr=$%02h got=$%02h exp=$%02h",
                     tag, idx, pr, color_out, exp_v);
            fail_count++;
        end
    endtask

    initial begin
        $display("[prior] start");

        // For each priority encoding, sweep all 256 idx_buf values.
        for (int pr_bit = 0; pr_bit < 4; pr_bit = pr_bit + 1) begin
            for (int i = 0; i < 256; i = i + 1) begin
                check(i[7:0], 8'h01 << pr_bit,
                      $sformatf("p%0d", pr_bit));
            end
        end

        // OR-mode: re-sweep with PRIOR[5] also set.
        for (int pr_bit = 0; pr_bit < 4; pr_bit = pr_bit + 1) begin
            for (int i = 0; i < 256; i = i + 1) begin
                check(i[7:0], (8'h01 << pr_bit) | 8'h20,
                      $sformatf("p%0d-or", pr_bit));
            end
        end

        // GTIA modes 9/10/11 — sweep priority orderings × all 256 idx
        // values × each GTIA encoding. PRIOR[7:6] = 01/10/11.
        for (int gm = 1; gm <= 3; gm = gm + 1) begin
            for (int pr_bit = 0; pr_bit < 4; pr_bit = pr_bit + 1) begin
                for (int i = 0; i < 256; i = i + 1) begin
                    check(i[7:0],
                          (8'h01 << pr_bit) | (gm[7:0] << 6),
                          $sformatf("g%0d-p%0d", gm, pr_bit));
                end
            end
        end

        // Spot checks (independent of oracle, just to flag obvious mistakes
        // if oracle and DUT happen to be wrong the same way).
        // PRIOR[0] + just P0 covering PF2 → colpm0
        check(8'h14, 8'h01, "spot/p0-over-pf2");
        if (color_out !== colpm0) begin
            $display("[spot] FAIL P0 over PF2 should be colpm0 ($%02h) got $%02h",
                     colpm0, color_out);
            fail_count++;
        end
        // PRIOR[2] + same → colpf2 (PF wins)
        check(8'h14, 8'h04, "spot/pf2-over-p0");
        if (color_out !== colpf2) begin
            $display("[spot] FAIL PF2 over P0 should be colpf2 ($%02h) got $%02h",
                     colpf2, color_out);
            fail_count++;
        end
        // PRIOR[1] + P0 + PF0 + P2: P-hi > PF > P-lo → P0 wins
        check(8'h55, 8'h02, "spot/p1-mode-p0wins");
        if (color_out !== colpm0) begin
            $display("[spot] FAIL PRIOR[1] P0 should win, got $%02h", color_out);
            fail_count++;
        end
        // PRIOR[1] + just P2 + PF2: P-hi none, PF wins over P-lo → colpf2
        check(8'h44, 8'h02, "spot/p1-mode-pf2wins");
        if (color_out !== colpf2) begin
            $display("[spot] FAIL PRIOR[1] PF2 should beat P2, got $%02h", color_out);
            fail_count++;
        end
        // OR-mode: P0 + P2 → colpm0 | colpm2 = $11 | $33 = $33
        check(8'h50, 8'h21, "spot/or-mode");
        if (color_out !== (colpm0 | colpm2)) begin
            $display("[spot] FAIL OR-mode P0|P2 should be $%02h, got $%02h",
                     colpm0 | colpm2, color_out);
            fail_count++;
        end

        // GTIA-mode spot checks.
        // GTIA 9 (PRIOR=$40): nibble 4 with COLBK=$99 → {colbk[7:4], 4} = $94
        check(8'h04, 8'h41, "spot/gtia9-nibble4");
        if (color_out !== {colbk[7:4], 4'd4}) begin
            $display("[spot] FAIL GTIA9 nibble 4 should be $%02h, got $%02h",
                     {colbk[7:4], 4'd4}, color_out);
            fail_count++;
        end
        // GTIA 10 (PRIOR=$80): nibble 5 → colpf1 = $66
        check(8'h05, 8'h81, "spot/gtia10-nibble5");
        if (color_out !== colpf1) begin
            $display("[spot] FAIL GTIA10 nibble 5 should be colpf1 ($%02h), got $%02h",
                     colpf1, color_out);
            fail_count++;
        end
        // GTIA 11 (PRIOR=$C0): nibble 7 with COLBK=$99 → {7, colbk[3:0]} = $79
        check(8'h07, 8'hC1, "spot/gtia11-nibble7");
        if (color_out !== {4'd7, colbk[3:0]}) begin
            $display("[spot] FAIL GTIA11 nibble 7 should be $%02h, got $%02h",
                     {4'd7, colbk[3:0]}, color_out);
            fail_count++;
        end
        // GTIA + player: PRIOR[0] + GTIA9 + P0 → P0 wins (PM > PF)
        check(8'h17, 8'h41, "spot/gtia9-pm-on-top");
        if (color_out !== colpm0) begin
            $display("[spot] FAIL GTIA9+P0 PRIOR[0] should show colpm0, got $%02h",
                     color_out);
            fail_count++;
        end
        // GTIA + PRIOR[2]: PF (GTIA) > PM, players hidden
        check(8'h17, 8'h44, "spot/gtia9-pf-over-pm");
        if (color_out !== {colbk[7:4], 4'd7}) begin
            $display("[spot] FAIL GTIA9 PRIOR[2] should hide P0, got $%02h",
                     color_out);
            fail_count++;
        end

        // ===== PM5 (PRIOR[4]) — missiles colour as COLPF3 ===================
        // Helper: drive 12-bit idx_buf directly and assert color_out.
        begin : pm5_phase
            // PM5 + PRIOR[0] (PM>PF) + just M2 present (no player) → COLPF3.
            //   idx_buf[3:0]   PF source = 0 (no PF)
            //   idx_buf[7:4]   P|M shared = $40 (M2-or-P2 slot lit)
            //   idx_buf[11:8]  M-only     = $4 (M2 only)
            //   PRIOR = $11 → bit[4]=PM5, bit[0]=ordering 0 (PM>PF)
            idx_buf = 12'h440;
            prior   = 8'h11;
            #1;
            if (color_out !== colpf3) begin
                $display("[pm5/m-only] FAIL got $%02h, expected colpf3 ($%02h)",
                         color_out, colpf3);
                fail_count++;
            end

            // PM5 + just P2 (no missile) → still COLPM2 (player not affected).
            //   idx_buf[7:4] = $40 (P2 lit, both via P0+M0 slot here = P2 slot)
            //   idx_buf[11:8] = 0 (no missile)
            idx_buf = 12'h040;
            prior   = 8'h11;
            #1;
            if (color_out !== colpm2) begin
                $display("[pm5/p-only] FAIL got $%02h, expected colpm2 ($%02h)",
                         color_out, colpm2);
                fail_count++;
            end

            // PM5 + both M2 and P2 lit (overlap). Missile bit set in both
            // legacy slot AND M-only nibble → player slot is masked, only
            // missile shows → COLPF3.
            idx_buf = 12'h440;
            prior   = 8'h11;
            #1;
            if (color_out !== colpf3) begin
                $display("[pm5/m+p-overlap] FAIL got $%02h, expected colpf3",
                         color_out);
                fail_count++;
            end

            // PM5 + P0 + M2 (different channels) → P0 wins by priority,
            // M2 hidden. /(PRIOR[0] = PM>PF, but M2 routes through PF3
            // which is below PM in this ordering.)
            //   idx_buf[7:4] = $50 (P0 lit + M2 lit in shared slot)
            //   idx_buf[11:8] = $4 (M2 only)
            //   With PM5 mask: P slot bit[4]=P0 stays (m0=0), bit[6]=P2
            //   would be cleared but we only set bit[4] and bit[6] in the
            //   shared layout for P0 + M2 case is bit[4]=1, bit[6]=1
            //   (M2 setting bit[6] in shared). After PM5 mask:
            //     P[0]=1 (m0=0), P[2]=1 & ~m2=0 → P2 cleared.
            //   Missile is at PF3 level; PRIOR[0] = PM>PF so P0 wins.
            idx_buf = 12'h450;
            prior   = 8'h11;
            #1;
            if (color_out !== colpm0) begin
                $display("[pm5/p0-over-m2] FAIL got $%02h, expected colpm0 ($%02h)",
                         color_out, colpm0);
                fail_count++;
            end

            // PM5 + PRIOR[2] (PF>PM) + M2: missile (= PF3) wins over any PM.
            idx_buf = 12'h440;
            prior   = 8'h14;
            #1;
            if (color_out !== colpf3) begin
                $display("[pm5/p2-mode] FAIL got $%02h, expected colpf3",
                         color_out);
                fail_count++;
            end

            // No PM5 + just M2 in shared slot → COLPM2 (legacy behaviour).
            idx_buf = 12'h040;
            prior   = 8'h01;
            #1;
            if (color_out !== colpm2) begin
                $display("[no-pm5] FAIL got $%02h, expected colpm2", color_out);
                fail_count++;
            end
        end

        if (fail_count == 0) begin
            $display("*** PRIOR OK *** 4 priority × (normal + OR + 3 GTIA) × 256 idx + spot + PM5");
            $finish;
        end else begin
            $display("*** PRIOR FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_prior watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
