// tb_hdmi_pkt.sv — verify hdmi_pkt_source for all five packet types.
//
// Phase A — Null Packet: HB0/HB1/HB2 + all subpackets are 0.
//
// Phase B — Audio Clock Regen Packet: each subpacket carries N=6144,
//           CTS=40000 in the bit layout from HDMI Table 5-12.
//
// Phase C — Audio Sample Packet: walks several stereo sample tuples
//           through the source and verifies the per-subpacket payload
//           matches the IEC 60958 sub-frame layout, including the
//           computed parity bit for both L and R sub-frames.
//
// Phase D — AVI InfoFrame: HB + checksum + payload bytes match the
//           pre-computed values for 800×600 RGB full-range.
//
// Phase E — Audio InfoFrame: HB + checksum + payload bytes match the
//           pre-computed values for 2-ch LPCM 48 kHz 24-bit.
//
// Phases D & E independently recompute the InfoFrame checksums in the
// testbench so a mistake in the spec interpretation can't be hidden by
// matching the same wrong constant in both DUT and oracle.

`default_nettype none
`timescale 1ns / 1ps

module tb_hdmi_pkt;

    logic [2:0]  pkt_select = 3'd0;
    logic [23:0] audio_l0 = 24'h0, audio_l1 = 24'h0, audio_l2 = 24'h0, audio_l3 = 24'h0;
    logic [23:0] audio_r0 = 24'h0, audio_r1 = 24'h0, audio_r2 = 24'h0, audio_r3 = 24'h0;
    logic [3:0]  audio_present     = 4'h0;
    logic [3:0]  audio_flat        = 4'h0;
    logic [3:0]  audio_block_start = 4'h0;

    wire [7:0]  pkt_type, pkt_hb1, pkt_hb2;
    wire [55:0] pkt_sp0, pkt_sp1, pkt_sp2, pkt_sp3;

    hdmi_pkt_source u_dut (
        .pkt_select        (pkt_select),
        .audio_l0(audio_l0), .audio_l1(audio_l1), .audio_l2(audio_l2), .audio_l3(audio_l3),
        .audio_r0(audio_r0), .audio_r1(audio_r1), .audio_r2(audio_r2), .audio_r3(audio_r3),
        .audio_present     (audio_present),
        .audio_flat        (audio_flat),
        .audio_block_start (audio_block_start),
        .pkt_type(pkt_type), .pkt_hb1(pkt_hb1), .pkt_hb2(pkt_hb2),
        .pkt_sp0(pkt_sp0), .pkt_sp1(pkt_sp1),
        .pkt_sp2(pkt_sp2), .pkt_sp3(pkt_sp3));

    // Phase F drives hdmi_packet through this instance to round-trip
    // a packet's header bit out lane 0 / bit 3.
    logic [4:0] cycle_idx_w  = 5'd0;
    logic       hsync_w      = 1'b0;
    logic       vsync_w      = 1'b0;
    wire  [3:0] lane0_nib, lane1_nib, lane2_nib;

    hdmi_packet u_pkt (
        .pkt_type(pkt_type), .pkt_hb1(pkt_hb1), .pkt_hb2(pkt_hb2),
        .pkt_sp0(pkt_sp0), .pkt_sp1(pkt_sp1),
        .pkt_sp2(pkt_sp2), .pkt_sp3(pkt_sp3),
        .cycle_idx(cycle_idx_w),
        .hsync(hsync_w), .vsync(vsync_w),
        .lane0_nibble(lane0_nib),
        .lane1_nibble(lane1_nib),
        .lane2_nibble(lane2_nib));

    int fail_count = 0;

    // Reference parity helper (XOR of 27 bits).
    function automatic logic ref_parity(input logic [23:0] sample,
                                          input logic v, u, c);
        return ^{v, u, c, sample};
    endfunction

    // Reference InfoFrame checksum: payload[i] sums into a single byte.
    // 256 - (sum & 0xFF).
    function automatic logic [7:0] ref_checksum(input integer width,
                                                 input logic [127:0] payload);
        integer i;
        logic [7:0] s;
        s = 8'h0;
        for (i = 0; i < width; i = i + 1)
            s = s + payload[i*8 +: 8];
        return 8'h00 - s;
    endfunction

    initial begin
        $display("[hdmi_pkt] start");

        // ===== Phase A — Null Packet ===================================
        pkt_select = 3'd0;
        #1;
        if (pkt_type !== 8'h00 || pkt_hb1 !== 8'h00 || pkt_hb2 !== 8'h00) begin
            $display("[A/hdr] FAIL type=$%02h hb1=$%02h hb2=$%02h",
                     pkt_type, pkt_hb1, pkt_hb2);
            fail_count++;
        end
        if (pkt_sp0 !== 56'h0 || pkt_sp1 !== 56'h0
            || pkt_sp2 !== 56'h0 || pkt_sp3 !== 56'h0) begin
            $display("[A/body] FAIL nonzero subpackets");
            fail_count++;
        end
        $display("[hdmi_pkt/A] null packet OK");

        // ===== Phase B — Audio Clock Regen =============================
        pkt_select = 3'd1;
        #1;
        if (pkt_type !== 8'h01 || pkt_hb1 !== 8'h00 || pkt_hb2 !== 8'h00) begin
            $display("[B/hdr] FAIL type=$%02h hb1=$%02h hb2=$%02h",
                     pkt_type, pkt_hb1, pkt_hb2);
            fail_count++;
        end
        // Expected: N=6144=0x1800, CTS=40000=0x9C40.
        // Subpacket bit layout: N[7:0] @ [7:0], N[15:8] @ [15:8],
        //                       N[19:16] @ [19:16], 0 @ [23:20],
        //                       CTS[7:0] @ [31:24], CTS[15:8] @ [39:32],
        //                       CTS[19:16] @ [43:40], 0 @ [55:44].
        begin : phase_b
            logic [55:0] expected;
            expected = 56'h00_00_9C_40_00_18_00;
            if (pkt_sp0 !== expected || pkt_sp1 !== expected
                || pkt_sp2 !== expected || pkt_sp3 !== expected) begin
                $display("[B/body] FAIL sp0=$%014h expected=$%014h",
                         pkt_sp0, expected);
                fail_count++;
            end
        end
        $display("[hdmi_pkt/B] audio clk regen OK");

        // ===== Phase C — Audio Sample Packet ===========================
        pkt_select        = 3'd2;
        audio_l0          = 24'h123456;
        audio_r0          = 24'hABCDEF;
        audio_l1          = 24'h000001;
        audio_r1          = 24'h800000;
        audio_l2          = 24'h7FFFFF;
        audio_r2          = 24'h000000;
        audio_l3          = 24'hAA55A5;
        audio_r3          = 24'h5AA55A;
        audio_present     = 4'hF;
        audio_flat        = 4'h0;
        audio_block_start = 4'h0;
        #1;
        if (pkt_type !== 8'h02) begin
            $display("[C/type] FAIL type=$%02h expected $02", pkt_type);
            fail_count++;
        end
        if (pkt_hb1 !== 8'h0F) begin
            $display("[C/hb1] FAIL hb1=$%02h expected $0F (layout=0, present=F)",
                     pkt_hb1);
            fail_count++;
        end
        if (pkt_hb2 !== 8'h00) begin
            $display("[C/hb2] FAIL hb2=$%02h expected $00", pkt_hb2);
            fail_count++;
        end
        // Subpacket 0 sub-frame: build expected and compare.
        begin : phase_c_sp0
            logic [23:0] l, r;
            logic        p_l, p_r;
            logic [55:0] expected;
            l = audio_l0; r = audio_r0;
            p_l = ref_parity(l, 1'b0, 1'b0, 1'b0);
            p_r = ref_parity(r, 1'b0, 1'b0, 1'b0);
            expected = {1'b0, 1'b0, 1'b0, p_r, r, 1'b0, 1'b0, 1'b0, p_l, l};
            if (pkt_sp0 !== expected) begin
                $display("[C/sp0] FAIL sp0=$%014h expected=$%014h L=$%06h R=$%06h pL=%0b pR=%0b",
                         pkt_sp0, expected, l, r, p_l, p_r);
                fail_count++;
            end
        end
        // Subpacket 1.
        begin : phase_c_sp1
            logic [23:0] l, r;
            logic        p_l, p_r;
            logic [55:0] expected;
            l = audio_l1; r = audio_r1;
            p_l = ref_parity(l, 1'b0, 1'b0, 1'b0);
            p_r = ref_parity(r, 1'b0, 1'b0, 1'b0);
            expected = {1'b0, 1'b0, 1'b0, p_r, r, 1'b0, 1'b0, 1'b0, p_l, l};
            if (pkt_sp1 !== expected) begin
                $display("[C/sp1] FAIL sp1=$%014h expected=$%014h",
                         pkt_sp1, expected);
                fail_count++;
            end
        end
        // Subpacket 2.
        begin : phase_c_sp2
            logic [23:0] l, r;
            logic        p_l, p_r;
            logic [55:0] expected;
            l = audio_l2; r = audio_r2;
            p_l = ref_parity(l, 1'b0, 1'b0, 1'b0);
            p_r = ref_parity(r, 1'b0, 1'b0, 1'b0);
            expected = {1'b0, 1'b0, 1'b0, p_r, r, 1'b0, 1'b0, 1'b0, p_l, l};
            if (pkt_sp2 !== expected) begin
                $display("[C/sp2] FAIL sp2=$%014h expected=$%014h",
                         pkt_sp2, expected);
                fail_count++;
            end
        end
        // Subpacket 3.
        begin : phase_c_sp3
            logic [23:0] l, r;
            logic        p_l, p_r;
            logic [55:0] expected;
            l = audio_l3; r = audio_r3;
            p_l = ref_parity(l, 1'b0, 1'b0, 1'b0);
            p_r = ref_parity(r, 1'b0, 1'b0, 1'b0);
            expected = {1'b0, 1'b0, 1'b0, p_r, r, 1'b0, 1'b0, 1'b0, p_l, l};
            if (pkt_sp3 !== expected) begin
                $display("[C/sp3] FAIL sp3=$%014h expected=$%014h",
                         pkt_sp3, expected);
                fail_count++;
            end
        end
        // HB2 with non-zero block_start + flat.
        audio_present     = 4'hF;
        audio_flat        = 4'h5;
        audio_block_start = 4'hA;
        #1;
        if (pkt_hb2 !== {4'hA, 4'h5}) begin
            $display("[C/hb2x] FAIL hb2=$%02h expected $A5", pkt_hb2);
            fail_count++;
        end
        $display("[hdmi_pkt/C] audio sample OK (4 subpackets w/ parity)");

        // ===== Phase D — AVI InfoFrame =================================
        pkt_select = 3'd3;
        #1;
        if (pkt_type !== 8'h82 || pkt_hb1 !== 8'h02 || pkt_hb2 !== 8'h0D) begin
            $display("[D/hdr] FAIL type=$%02h hb1=$%02h hb2=$%02h",
                     pkt_type, pkt_hb1, pkt_hb2);
            fail_count++;
        end
        // PB1..PB13 = {00,10,08,00,00,00,00,00,00,00,00,00,00}, PB0 = checksum.
        begin : phase_d
            logic [127:0] payload;
            logic [7:0]   exp_pb0;
            logic [7:0]   pb0, pb1, pb2, pb3, pb4, pb5, pb6;
            // Recompute checksum.
            payload = 128'h0;
            payload[7:0]   = 8'h82;     // HB0
            payload[15:8]  = 8'h02;     // HB1
            payload[23:16] = 8'h0D;     // HB2
            payload[31:24] = 8'h00;     // PB1
            payload[39:32] = 8'h10;     // PB2
            payload[47:40] = 8'h08;     // PB3
            // PB4..PB13 = 0 (already zero).
            exp_pb0 = 8'h00 - (payload[7:0] + payload[15:8] + payload[23:16]
                                + payload[31:24] + payload[39:32] + payload[47:40]);
            // Pull the bytes from the subpacket.
            pb0 = pkt_sp0[7:0];
            pb1 = pkt_sp0[15:8];
            pb2 = pkt_sp0[23:16];
            pb3 = pkt_sp0[31:24];
            pb4 = pkt_sp0[39:32];
            pb5 = pkt_sp0[47:40];
            pb6 = pkt_sp0[55:48];
            if (pb0 !== exp_pb0) begin
                $display("[D/PB0] FAIL pb0=$%02h expected=$%02h",
                         pb0, exp_pb0);
                fail_count++;
            end
            if (pb1 !== 8'h00 || pb2 !== 8'h10 || pb3 !== 8'h08
                || pb4 !== 8'h00 || pb5 !== 8'h00 || pb6 !== 8'h00) begin
                $display("[D/body] FAIL pb1..pb6 = $%02h $%02h $%02h $%02h $%02h $%02h",
                         pb1, pb2, pb3, pb4, pb5, pb6);
                fail_count++;
            end
        end
        if (pkt_sp1 !== 56'h0 || pkt_sp2 !== 56'h0 || pkt_sp3 !== 56'h0) begin
            $display("[D/sp1-3] FAIL nonzero pad subpackets");
            fail_count++;
        end
        $display("[hdmi_pkt/D] AVI InfoFrame OK (PB0 = $%02h)", pkt_sp0[7:0]);

        // ===== Phase E — Audio InfoFrame ===============================
        pkt_select = 3'd4;
        #1;
        if (pkt_type !== 8'h84 || pkt_hb1 !== 8'h01 || pkt_hb2 !== 8'h0A) begin
            $display("[E/hdr] FAIL type=$%02h hb1=$%02h hb2=$%02h",
                     pkt_type, pkt_hb1, pkt_hb2);
            fail_count++;
        end
        begin : phase_e
            logic [127:0] payload;
            logic [7:0]   exp_pb0;
            logic [7:0]   pb0, pb1, pb2;
            payload = 128'h0;
            payload[7:0]   = 8'h84;     // HB0
            payload[15:8]  = 8'h01;     // HB1
            payload[23:16] = 8'h0A;     // HB2
            payload[31:24] = 8'h11;     // PB1 (CT=1, CC=1)
            payload[39:32] = 8'h6C;     // PB2 (SF=3 48k, SS=3 24-bit)
            // PB3..PB10 = 0.
            exp_pb0 = 8'h00 - (payload[7:0] + payload[15:8] + payload[23:16]
                                + payload[31:24] + payload[39:32]);
            pb0 = pkt_sp0[7:0];
            pb1 = pkt_sp0[15:8];
            pb2 = pkt_sp0[23:16];
            if (pb0 !== exp_pb0) begin
                $display("[E/PB0] FAIL pb0=$%02h expected=$%02h",
                         pb0, exp_pb0);
                fail_count++;
            end
            if (pb1 !== 8'h11 || pb2 !== 8'h6C) begin
                $display("[E/body] FAIL pb1=$%02h pb2=$%02h",
                         pb1, pb2);
                fail_count++;
            end
        end
        $display("[hdmi_pkt/E] Audio InfoFrame OK (PB0 = $%02h)", pkt_sp0[7:0]);

        // ===== Phase F — round-trip through hdmi_packet =================
        // Drive an Audio Sample Packet through hdmi_packet and verify
        // the header bit on lane 0 over 32 cycles reconstructs HB0 ||
        // HB1 || HB2 || header_ECC (MSB at cycle 0).
        pkt_select        = 3'd2;
        audio_l0          = 24'h001122;
        audio_r0          = 24'h334455;
        audio_l1          = 24'h667788;
        audio_r1          = 24'h99AABB;
        audio_l2          = 24'hCCDDEE;
        audio_r2          = 24'hFF0011;
        audio_l3          = 24'h223344;
        audio_r3          = 24'h556677;
        audio_present     = 4'hF;
        audio_flat        = 4'h0;
        audio_block_start = 4'h0;
        #1;
        begin : phase_f
            logic [7:0]  expected_ecc;
            logic [31:0] hdr_word;
            logic [31:0] reconstructed;
            integer       k;
            // Compute expected ECC against the same algorithm BCH uses.
            expected_ecc = 8'h0;
            begin : ecc_calc
                logic [23:0] hdr_data;
                logic        fb;
                hdr_data = {pkt_type, pkt_hb1, pkt_hb2};
                for (k = 0; k < 24; k = k + 1) begin
                    fb = expected_ecc[7] ^ hdr_data[23 - k];
                    expected_ecc = {expected_ecc[6:0], 1'b0}
                                    ^ (fb ? 8'hD1 : 8'h00);
                end
            end
            hdr_word = {pkt_type, pkt_hb1, pkt_hb2, expected_ecc};

            // Walk hdmi_packet for cycle 0..31 and grab the header bit
            // (lane 0 bit 3) into reconstructed[31..0].
            reconstructed = 32'h0;
            for (k = 0; k < 32; k = k + 1) begin
                cycle_idx_w = k[4:0];
                #1;
                reconstructed[31 - k] = lane0_nib[3];
            end
            if (reconstructed !== hdr_word) begin
                $display("[F/hdr] FAIL reconstructed=$%08h expected=$%08h",
                         reconstructed, hdr_word);
                fail_count++;
            end
            // Cycle-0 marker bit (lane 0 bit 2) must be 0; cycles 1..31 = 1.
            for (k = 0; k < 32; k = k + 1) begin
                cycle_idx_w = k[4:0];
                #1;
                if (lane0_nib[2] !== ((k == 0) ? 1'b0 : 1'b1)) begin
                    $display("[F/marker] FAIL cycle=%0d bit2=%0b",
                             k, lane0_nib[2]);
                    fail_count++;
                end
            end
        end
        $display("[hdmi_pkt/F] hdmi_packet round-trip OK (header + marker bit)");

        if (fail_count == 0) begin
            $display("*** HDMI_PKT OK *** 5 packet types + hdmi_packet round-trip");
            $finish;
        end else begin
            $display("*** HDMI_PKT FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

endmodule

`default_nettype wire
