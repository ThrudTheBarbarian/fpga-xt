// hdmi_config.sv — SiI9022A HDMI transmitter TPI I2C initialization.
//
// After reset release, initializes the SiI9022A over I2C (address 0x72)
// for 1080p60 RGB565 output.
//
// Uses the i2c_master byte-level primitives to sequence register writes.
// The init sequence runs once; done_o goes high on completion.

`default_nettype none

module hdmi_config (
    input  wire        clk_i,
    input  wire        rst_n_i,

    inout  wire        sda_io,
    inout  wire        scl_io,

    output reg         done_o
);
    // ------------------------------------------------------------------
    // I2C master instance
    // ------------------------------------------------------------------
    reg         i2c_cmd_valid;
    reg         i2c_cmd_valid_r;
    reg  [1:0]  i2c_cmd_op;
    reg  [7:0]  i2c_data_i;
    wire        i2c_cmd_ready;
    wire        i2c_cmd_busy;
    wire        i2c_ack_o;
    wire [7:0]  i2c_data_o;

    // Edge-detect on cmd_valid for start pulse
    wire i2c_start_pulse = i2c_cmd_valid && !i2c_cmd_valid_r;
    always_ff @(posedge clk_i) begin
        i2c_cmd_valid_r <= i2c_cmd_valid;
    end

    i2c_master #(
        .PRESCALE (750)   // clk_i=150 MHz → 100 kHz I2C
    ) u_i2c (
        .clk       (clk_i),
        .rst_n     (rst_n_i),
        .cmd_valid (i2c_start_pulse),
        .cmd_op    (i2c_cmd_op),
        .data_i    (i2c_data_i),
        .cmd_ready (i2c_cmd_ready),
        .cmd_busy  (i2c_cmd_busy),
        .ack_o     (i2c_ack_o),
        .data_o    (i2c_data_o),
        .scl       (scl_io),
        .sda       (sda_io)
    );

    // I2C master is ready when it's not busy (cmd_ready = 1 when idle)
    wire i2c_ready = i2c_cmd_ready;

    // ------------------------------------------------------------------
    // Sequence FSM
    // ------------------------------------------------------------------
    // Each TPI register access is a sub-sequence:
    //   write: ISSUE(START) → WAIT_DONE → ISSUE(WRITE addr|W) → WAIT_ACK →
    //          ISSUE(WRITE reg) → WAIT_ACK → ISSUE(WRITE data) → WAIT_ACK →
    //          ISSUE(STOP) → WAIT_DONE → advance to next step
    //
    // We use a two-layer FSM: an outer "seq" state machine that tracks
    // which step we're on, and an inner "phase" state that issues I2C
    // commands one at a time and waits for completion.

    localparam SEQ_IDLE   = 0,
               SEQ_INIT   = 1,    // initial power-on delay
               SEQ_RUN    = 2,    // running through seq_rom
               SEQ_DONE   = 3;

    reg [1:0]  seq_state;

    // Inner phase
    localparam PH_ISSUE   = 0,    // assert cmd_valid
               PH_WAIT    = 1,    // wait for cmd_ready (command done)
               PH_WAIT_ACK= 2;    // wait + check ACK

    reg [1:0]  phase;

    reg [4:0]  seq_ptr;       // sequence step index (0..N-1)
    reg [17:0] delay_cnt;
    reg        delay_run;
    localparam int N_SEQ_STEPS = 18;

    // Micro-operations issued by the current step
    reg [3:0]  sub_op;        // 0=START, 1=STOP, 2=WRITE_ADDR, 3=WRITE_REG,
                              // 4=WRITE_DATA, 5=READ_BYTE, 6=READ_ACK
    reg [7:0]  sub_data;      // data for WRITE operations

    // Arguments for the current sequence step
    reg [7:0]  seq_reg_addr;
    reg [7:0]  seq_write_val;
    reg        seq_is_read;

    always_ff @(posedge clk_i) begin  // sync reset: rst_n_i (clk_sys) held post-lock; avoids async removal-hold
        if (!rst_n_i) begin
            seq_state    <= SEQ_IDLE;
            phase        <= PH_ISSUE;
            done_o       <= 1'b0;
            i2c_cmd_valid<= 1'b0;
            i2c_cmd_op   <= 2'd0;
            i2c_data_i   <= 8'h00;
            seq_ptr      <= 5'd0;
            delay_cnt    <= 18'd0;
            delay_run    <= 1'b0;
            sub_op       <= 3'd0;
            sub_data     <= 8'h00;
            seq_reg_addr <= 8'h00;
            seq_write_val<= 8'h00;
            seq_is_read  <= 1'b0;
        end else begin
            // Default: de-assert cmd_valid after pulse
            if (i2c_cmd_valid && i2c_start_pulse)
                i2c_cmd_valid <= 1'b0;

            case (seq_state)
                // ==========================================================
                // SEQ_IDLE: wait, then start initialization
                // ==========================================================
                SEQ_IDLE: begin
                    seq_state <= SEQ_INIT;
                    delay_run <= 1'b1;
                    delay_cnt <= 10 * 150_000;  // ~10 ms at 150 MHz
                end

                // ==========================================================
                // SEQ_INIT: power-on delay
                // ==========================================================
                SEQ_INIT: begin
                    if (delay_cnt != 0) begin
                        delay_cnt <= delay_cnt - 1'b1;
                    end else begin
                        delay_run <= 1'b0;
                        seq_ptr   <= 5'd0;
                        seq_state <= SEQ_RUN;
                        phase     <= PH_ISSUE;
                    end
                end

                // ==========================================================
                // SEQ_RUN: execute sequence steps
                // ==========================================================
                SEQ_RUN: begin
                    // Load step arguments from ROM when starting a new step
                    if (i2c_ready && phase == PH_ISSUE && sub_op == 3'd0) begin
                        // First time entering this step — load from ROM
                        {seq_is_read, seq_reg_addr, seq_write_val} <=
                            seq_rom_read(seq_ptr);
                    end

                    // --- Phase: ISSUE a micro-operation to I2C master ----
                    if (phase == PH_ISSUE) begin
                        if (i2c_ready && sub_op == 3'd0) begin
                            // Just entered: issue START
                            i2c_cmd_valid <= 1'b1;
                            i2c_cmd_op    <= 2'd0;   // START
                            sub_op        <= 3'd1;   // next: wait for START done
                            phase <= PH_WAIT;
                        end
                        // Sub-ops 1-6 are set by the completion handlers below
                    end

                    // --- Phase: WAIT for I2C command to complete ----
                    if (phase == PH_WAIT) begin
                        if (i2c_ready) begin
                            // Command completed. Check result.
                            case (sub_op)
                                // START completed → issue device address
                                3'd1: begin
                                    i2c_cmd_valid <= 1'b1;
                                    i2c_cmd_op    <= 2'd2;   // WRITE
                                    i2c_data_i    <= 8'h3b << 1;  // 0x76 = addr|W (SiI9022 @ 7-bit 0x3b, CI2CA=1; matches MyIR proven init)
                                    sub_op        <= 3'd2;   // next: wait for ACK
                                end

                                // Device address WRITE completed → check ACK
                                3'd2: begin
                                    if (i2c_ack_o) begin
                                        // ACK received — send register address
                                        i2c_cmd_valid <= 1'b1;
                                        i2c_cmd_op    <= 2'd2;   // WRITE
                                        i2c_data_i    <= seq_reg_addr;
                                        sub_op        <= 3'd3;
                                    end else begin
                                        // NACK — retry from START
                                        i2c_cmd_valid <= 1'b1;
                                        i2c_cmd_op    <= 2'd0;   // START
                                        sub_op        <= 3'd1;
                                    end
                                end

                                // Register address WRITE completed → check ACK
                                3'd3: begin
                                    if (i2c_ack_o) begin
                                        if (seq_is_read) begin
                                            // Read: issue RESTART
                                            i2c_cmd_valid <= 1'b1;
                                            i2c_cmd_op    <= 2'd0;   // START
                                            sub_op        <= 3'd4;
                                        end else begin
                                            // Write: send data byte
                                            i2c_cmd_valid <= 1'b1;
                                            i2c_cmd_op    <= 2'd2;   // WRITE
                                            i2c_data_i    <= seq_write_val;
                                            sub_op        <= 3'd5;
                                        end
                                    end else begin
                                        // NACK on reg address — retry
                                        i2c_cmd_valid <= 1'b1;
                                        i2c_cmd_op    <= 2'd0;   // START
                                        sub_op        <= 3'd1;
                                    end
                                end

                                // RESTART completed → issue device address|R
                                3'd4: begin
                                    i2c_cmd_valid <= 1'b1;
                                    i2c_cmd_op    <= 2'd2;   // WRITE
                                    i2c_data_i    <= (8'h3b << 1) | 1'b1;  // 0x77 = addr|R (SiI9022 @ 7-bit 0x3b)
                                    sub_op        <= 3'd6;
                                end

                                // Data byte WRITE completed → check ACK, STOP
                                3'd5: begin
                                    // STOP to complete write transaction
                                    i2c_cmd_valid <= 1'b1;
                                    i2c_cmd_op    <= 2'd1;   // STOP
                                    sub_op        <= 3'd7;
                                end

                                // Read address WRITE completed → read byte
                                3'd6: begin
                                    if (i2c_ack_o) begin
                                        i2c_cmd_valid <= 1'b1;
                                        i2c_cmd_op    <= 2'd3;   // READ
                                        sub_op        <= 4'd8;
                                    end else begin
                                        // NACK on read address — retry
                                        i2c_cmd_valid <= 1'b1;
                                        i2c_cmd_op    <= 2'd0;   // START
                                        sub_op        <= 3'd1;
                                    end
                                end

                                // STOP completed → advance to next seq step
                                3'd7: begin
                                    if (seq_ptr == N_SEQ_STEPS - 1) begin
                                        seq_state <= SEQ_DONE;
                                        done_o    <= 1'b1;
                                    end else begin
                                        seq_ptr <= seq_ptr + 1'b1;
                                        sub_op  <= 3'd0;   // reset for next step
                                    end
                                end

                                // READ completed → STOP
                                4'd8: begin
                                    // data is in i2c_data_o (ignore for now)
                                    i2c_cmd_valid <= 1'b1;
                                    i2c_cmd_op    <= 2'd1;   // STOP
                                    sub_op        <= 3'd7;
                                end

                                default: begin
                                    // Shouldn't happen
                                    sub_op <= 3'd7;  // try STOP
                                end
                            endcase
                        end
                    end
                end

                // ==========================================================
                // SEQ_DONE: initialization complete
                // ==========================================================
                SEQ_DONE: begin
                    done_o <= 1'b1;
                end

                default: seq_state <= SEQ_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Sequence ROM — TPI register initialization table
    // ------------------------------------------------------------------
    // Format: {is_read, reg_addr, write_val}
    // For writes: reg is written with write_val
    // For reads:  reg is read, result ignored (just for verification)
    function automatic [16:0] seq_rom_read(input [4:0] index);
        case (index)
            // Sequence mirrors MyIR's proven sii9022_init (V2 board), except the
            // PixelClock regs which track OUR clk_pix (148.4375 MHz = 14844),
            // not MyIR's 148.50.  0xC7 enables TPI; final 0x1A=0x01 = TMDS active.
            5'd0:  return {1'b0, 8'hC7, 8'h00};  // Enable TPI mode / soft reset
            5'd1:  return {1'b0, 8'h1E, 8'h00};  // Power state D0
            5'd2:  return {1'b0, 8'h08, 8'h70};  // Input bus / pixel-repetition (MyIR)
            5'd3:  return {1'b0, 8'h09, 8'h00};  // Input format = RGB
            5'd4:  return {1'b0, 8'h0A, 8'h00};  // Output format = RGB
            5'd5:  return {1'b0, 8'h60, 8'h04};  // (MyIR)
            5'd6:  return {1'b0, 8'h3C, 8'h01};  // (MyIR)
            5'd7:  return {1'b0, 8'h1A, 8'h11};  // System ctrl: TMDS off during config
            5'd8:  return {1'b0, 8'h00, 8'hFC};  // PixelClock LSB (14844 = 148.4375 MHz)
            5'd9:  return {1'b0, 8'h01, 8'h39};  // PixelClock MSB
            5'd10: return {1'b0, 8'h02, 8'h70};  // VFreq LSB (6000 = 60.00 Hz)
            5'd11: return {1'b0, 8'h03, 8'h17};  // VFreq MSB
            5'd12: return {1'b0, 8'h04, 8'h98};  // H_Total LSB (2200)
            5'd13: return {1'b0, 8'h05, 8'h08};  // H_Total MSB
            5'd14: return {1'b0, 8'h06, 8'h65};  // V_Total LSB (1125)
            5'd15: return {1'b0, 8'h07, 8'h04};  // V_Total MSB
            5'd16: return {1'b0, 8'h08, 8'h70};  // Input bus fmt (MyIR re-write)
            5'd17: return {1'b0, 8'h1A, 8'h01};  // System ctrl: TMDS active, output enable
            default: return {1'b0, 8'h00, 8'h00};
        endcase
    endfunction

endmodule

`default_nettype wire
