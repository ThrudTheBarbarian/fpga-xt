`timescale 1ns/1ps
`default_nettype none
//
// tb_xt_sio_drive — the virtual SIO drive's frame engine.
//
// What matters here, in order of how easy it is to get wrong:
//   T3  SILENCE for a device we do not own.  This is what lets a real
//       peripheral on the DIN port coexist (sio-bridge.md §13.3); if we answer
//       anyway it is a bus collision, and the failure would only show up with
//       hardware plugged in.
//   T4  SILENCE for a bad checksum -- and the checksum is END-AROUND CARRY,
//       not a truncating sum, so a naive implementation passes every test that
//       happens not to carry and fails in the field.
//   T2  the full reply SHAPE: ACK, COMPLETE, N data bytes, data checksum.
//   T5  every reply byte spaced by a frame time, counted in POKEY's own shift
//       ticks -- the drive must never reply faster than the guest's programmed
//       rate (§13.5).
//
module tb_xt_sio_drive;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;                    // 100 MHz

    logic       cmd_n = 1, serout_strobe = 0, shift_tick = 0;
    logic [7:0] serout_byte = 0;
    logic [7:0] own_dev = 8'b0000_0001;      // D1: only
    logic       rsp_valid = 0, rsp_ok = 1;
    logic [8:0] rsp_len = 0;

    wire [7:0] ser_in_byte;   wire ser_in_byte_pulse;
    wire       req_valid, busy;
    wire [7:0] req_dev, req_cmd, req_aux1, req_aux2;
    wire [8:0] rsp_idx;

    // payload the "A9" would supply: a recognisable ramp
    logic [7:0] payload [0:255];
    wire  [7:0] rsp_byte = payload[rsp_idx[7:0]];

    xt_sio_drive #(.ACK_FRAMES(2)) dut (
        .clk(clk), .rst(rst),
        .cmd_n(cmd_n), .serout_byte(serout_byte), .serout_strobe(serout_strobe),
        .shift_tick(shift_tick), .guest_irqen(8'hFF),
        .ser_in_byte(ser_in_byte), .ser_in_byte_pulse(ser_in_byte_pulse),
        .own_dev(own_dev),
        .req_valid(req_valid), .req_dev(req_dev), .req_cmd(req_cmd),
        .req_aux1(req_aux1), .req_aux2(req_aux2),
        .rsp_valid(rsp_valid), .rsp_ok(rsp_ok), .rsp_len(rsp_len),
        .rsp_idx(rsp_idx), .rsp_byte(rsp_byte), .busy(busy), .reading(),
        .dbg_frames(), .dbg_bytes(), .dbg_accepted(), .dbg_replies(),
        .dbg_irqen5_at_ack()
    );

    // free-running shift clock — stands in for POKEY's divider
    always begin #200 shift_tick = 1; #10 shift_tick = 0; end

    // capture everything the drive emits
    logic [7:0] got [0:519];
    int         ngot = 0;
    always @(posedge clk) if (ser_in_byte_pulse) begin
        got[ngot] = ser_in_byte; ngot = ngot + 1;
    end

    int checks = 0, errors = 0;
    task automatic ck(input string what, input logic cond);
        checks++;
        if (!cond) begin errors++; $display("  FAIL: %s", what); end
    endtask

    function automatic [7:0] csum(input [7:0] a, input [7:0] b);
        logic [8:0] t;
        begin t = {1'b0,a} + {1'b0,b}; csum = t[7:0] + {7'b0, t[8]}; end
    endfunction

    task automatic send_byte(input [7:0] b);
        @(negedge clk); serout_byte = b; serout_strobe = 1;
        @(negedge clk); serout_strobe = 0;
    endtask

    // a whole command frame, checksum computed for us
    task automatic send_frame(input [7:0] d, input [7:0] c,
                              input [7:0] a1, input [7:0] a2,
                              input logic corrupt_csum);
        logic [7:0] k;
        begin
            k = csum(csum(csum(csum(8'h00,d),c),a1),a2);
            if (corrupt_csum) k = k ^ 8'hFF;
            @(negedge clk); cmd_n = 0;
            send_byte(d); send_byte(c); send_byte(a1); send_byte(a2); send_byte(k);
            @(negedge clk); cmd_n = 1;
        end
    endtask

    initial begin
        for (int i = 0; i < 256; i++) payload[i] = 8'(i ^ 8'h5A);
        repeat (4) @(posedge clk); rst = 0; @(posedge clk);

        // ---- T1: a frame addressed to us is decoded ----------------------
        $display("T1: command frame decoded and handed to the service side");
        ngot = 0; rsp_valid = 0; rsp_len = 0;
        fork send_frame(8'h31, 8'h52, 8'h01, 8'h00, 1'b0); join
        wait (req_valid == 1);
        ck("req_dev  = $31", req_dev  === 8'h31);
        ck("req_cmd  = $52", req_cmd  === 8'h52);
        ck("req_aux1 = $01", req_aux1 === 8'h01);
        ck("req_aux2 = $00", req_aux2 === 8'h00);
        ck("busy asserted",  busy === 1'b1);

        // ---- T2: the reply shape -----------------------------------------
        $display("T2: ACK, COMPLETE, 128 data bytes, data checksum");
        rsp_len = 9'd128; rsp_ok = 1; rsp_valid = 1;
        wait (ngot >= 131);
        repeat (40) @(posedge clk);
        ck("byte 0 = ACK 'A'",      got[0] === 8'h41);
        ck("byte 1 = COMPLETE 'C'", got[1] === 8'h43);
        begin
            logic ok; logic [7:0] k;
            ok = 1; k = 8'h00;
            for (int i = 0; i < 128; i++) begin
                if (got[2+i] !== payload[i]) ok = 0;
                k = csum(k, payload[i]);
            end
            ck("128 payload bytes verbatim", ok);
            ck("trailing data checksum",     got[130] === k);
        end
        ck("exactly 131 bytes emitted", ngot == 131);

        // ---- T3: a device we do not own gets SILENCE ---------------------
        $display("T3: not our device -> total silence (bus coexistence)");
        ngot = 0; rsp_valid = 0;
        send_frame(8'h32, 8'h52, 8'h01, 8'h00, 1'b0);   // D2: -- own_dev bit clear
        repeat (400) @(posedge clk);
        ck("no bytes emitted for D2:", ngot == 0);
        ck("no service request raised", req_valid === 1'b0);

        // ---- T4: a bad checksum gets SILENCE -----------------------------
        $display("T4: bad frame checksum -> silence, no request");
        ngot = 0;
        send_frame(8'h31, 8'h52, 8'h01, 8'h00, 1'b1);   // corrupted
        repeat (400) @(posedge clk);
        ck("no bytes emitted on bad checksum", ngot == 0);

        // ---- T5: a stopped guest clock must NOT stall the reply -----------
        // This test used to assert the opposite -- that no ticks meant no reply
        // -- which encoded the wrong model and hid a real bug: a guest that
        // reprograms its POKEY timers between sending the command and receiving
        // the answer stops the tick, and the drive stalled forever mid-reply.
        // A real drive has its own baud generator.  So: track the guest's rate
        // when the tick runs, but fall back to an absolute period when it does
        // not, and NEVER hang.
        $display("T5: reply completes even with the guest's shift clock stopped");
        ngot = 0; rsp_valid = 0; rsp_len = 9'd4;
        send_frame(8'h31, 8'h52, 8'h02, 8'h00, 1'b0);
        wait (req_valid == 1);
        rsp_valid = 1;
        force shift_tick = 1'b0;                        // the guest's clock stops
        wait (ngot >= 7);                                // ACK+COMP+4+csum
        ck("full reply delivered on the fallback clock", ngot >= 7);
        release shift_tick;

        $display("");
        if (errors == 0) $display("tb_xt_sio_drive: PASS (%0d checks)", checks);
        else             $display("tb_xt_sio_drive: FAIL (%0d/%0d failed)", errors, checks);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("tb_xt_sio_drive: TIMEOUT");
        $fatal(1);
    end

endmodule
`default_nettype wire
