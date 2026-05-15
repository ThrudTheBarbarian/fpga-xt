// i2c_master.sv — I2C master (byte-level primitives) for device config.
//
// Commands (pulse cmd_valid):
//   cmd_op=0 (START) — generate START condition (SDA↓ while SCL↑)
//   cmd_op=1 (STOP)  — generate STOP condition  (SDA↑ while SCL↑)
//   cmd_op=2 (WRITE) — transmit data_i[7:0] + receive ACK
//   cmd_op=3 (READ)  — receive 8 bits + send NACK (single-byte read)
//
// cmd_ready high when idle.  cmd_busy high during execution.
// After WRITE: ack_o valid for one cycle (1=ACK, 0=NACK).
// After READ:  data_o valid for one cycle.
//
// SCL = f_clk / (2 * PRESCALE).  PRESCALE=500 → ~100 kHz @ 100 MHz.

`default_nettype none

module i2c_master #(
    parameter int PRESCALE = 750
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cmd_valid,
    input  wire [1:0]  cmd_op,
    input  wire [7:0]  data_i,
    output reg         cmd_ready,
    output reg         cmd_busy,
    output reg         ack_o,
    output reg [7:0]   data_o,

    inout  wire        scl,
    inout  wire        sda
);
    // ------------------------------------------------------------------
    // IOBUF primitives for bidirectional I2C pins
    // ------------------------------------------------------------------
    // Explicit IOBUF instantiation ensures correct pad-level buffering
    // for the open-drain I2C bus (driven low when active, high-Z otherwise).
    reg  scl_drv = 1'b0;   // 1 = drive low (active), 0 = high-Z (released)
    reg  sda_drv = 1'b0;
    wire scl_i, sda_i;      // loopback from pad (reflects bus state)

    IOBUF #(.DRIVE(12), .IBUF_LOW_PWR(0), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW"))
        u_iobuf_scl (.O(scl_i), .IO(scl), .I(1'b0), .T(~scl_drv));
    IOBUF #(.DRIVE(12), .IBUF_LOW_PWR(0), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW"))
        u_iobuf_sda (.O(sda_i), .IO(sda), .I(1'b0), .T(~sda_drv));

    // ------------------------------------------------------------------
    // Free-running half-bit timer (wraps at PRESCALE)
    // ------------------------------------------------------------------
    reg [$clog2(PRESCALE)-1:0] timer;
    reg                         timer_run;
    wire                        timeout;   // end of half-period

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= 0;
            timer_run <= 1'b0;
        end else if (timer_run) begin
            if (timer == PRESCALE-1)
                timer <= 0;
            else
                timer <= timer + 1'b1;
        end else begin
            timer <= 0;
        end
    end
    assign timeout = timer_run && (timer == PRESCALE-1);

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam S_IDLE     = 0,
               S_START_P0 = 1,   // SCL=1, SDA=1→0
               S_START_P1 = 2,   // SCL=0
               S_BIT_P0   = 3,   // SCL=0, set SDA
               S_BIT_P1   = 4,   // SCL=1, sample SDA
               S_ACK_P0   = 5,   // SCL=0, prep ACK
               S_ACK_P1   = 6,   // SCL=1, sample ACK
               S_ACK_END  = 7,   // SCL=0, return to idle
               S_STOP_P0  = 8,   // SCL=0, SDA=0
               S_STOP_P1  = 9,   // SCL=1, SDA=0
               S_STOP_P2  = 10;  // SDA=1 (release = STOP)

    reg [3:0] state;
    reg [3:0] bit_cnt;
    reg [7:0] shift_reg;
    reg       is_read;        // 1 during READ command

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            cmd_ready   <= 1'b1;
            cmd_busy    <= 1'b0;
            ack_o       <= 1'b0;
            data_o      <= 8'h00;
            scl_drv     <= 1'b0;
            sda_drv     <= 1'b0;
            timer_run   <= 1'b0;
            bit_cnt     <= 4'd0;
            shift_reg   <= 8'h00;
            is_read     <= 1'b0;
        end else begin
            ack_o  <= 1'b0;    // default: one-cycle pulse
            data_o <= 8'h00;

            case (state)
                // ==========================================================
                // IDLE
                // ==========================================================
                S_IDLE: begin
                    scl_drv   <= 1'b0;      // release SCL
                    sda_drv   <= 1'b0;      // release SDA
                    cmd_ready <= 1'b1;
                    cmd_busy  <= 1'b0;
                    if (cmd_valid) begin
                        cmd_ready <= 1'b0;
                        cmd_busy  <= 1'b1;
                        timer_run <= 1'b1;
                        is_read   <= (cmd_op == 2'b11);
                        case (cmd_op)
                            2'b00: state <= S_START_P0;
                            2'b01: state <= S_STOP_P0;
                            2'b10: begin  // WRITE
                                shift_reg <= data_i;
                                bit_cnt   <= 4'd7;
                                state     <= S_BIT_P0;
                            end
                            2'b11: begin  // READ
                                bit_cnt <= 4'd7;
                                state   <= S_BIT_P0;
                            end
                        endcase
                    end
                end

                // ==========================================================
                // START
                // ==========================================================
                S_START_P0: begin
                    // Phase 0: SCL high, SDA high → SDA↓ at half-timer
                    scl_drv <= 1'b0;         // SCL released → high
                    sda_drv <= 1'b0;         // SDA released → high
                    if (timer == (PRESCALE >> 1))
                        sda_drv <= 1'b1;     // SDA ↓ (START condition)
                    if (timeout)
                        state <= S_START_P1;
                end

                S_START_P1: begin
                    // Phase 1: SCL low (lock bus)
                    sda_drv <= 1'b1;         // SDA low
                    if (timeout) begin
                        scl_drv <= 1'b1;     // SCL low
                        state   <= S_IDLE;
                        cmd_busy <= 1'b0;
                        cmd_ready <= 1'b1;
                        timer_run <= 1'b0;
                    end else if (timer == (PRESCALE >> 1)) begin
                        scl_drv <= 1'b1;     // SCL low after hold time
                    end
                end

                // ==========================================================
                // BIT — transmit or receive one bit
                // ==========================================================
                S_BIT_P0: begin
                    // SCL low: set up SDA
                    scl_drv <= 1'b1;         // SCL low
                    if (!is_read) begin
                        sda_drv <= ~shift_reg[7];   // drive MSB
                        shift_reg <= {shift_reg[6:0], 1'b0};
                    end else begin
                        sda_drv <= 1'b0;              // release SDA (slave drives)
                    end
                    if (timeout)
                        state <= S_BIT_P1;
                end

                S_BIT_P1: begin
                    // SCL high: release SCL, sample SDA (if read)
                    scl_drv <= 1'b0;         // SCL released → high
                    if (timeout) begin
                        if (is_read) begin
                            // Sample SDA at end of SCL high
                            shift_reg <= {shift_reg[6:0], sda_i};
                        end
                        // Check if more bits or ACK phase
                        if (bit_cnt == 0) begin
                            state <= S_ACK_P0;
                        end else begin
                            bit_cnt <= bit_cnt - 1;
                            state   <= S_BIT_P0;
                        end
                    end else if (timer == (PRESCALE >> 1) && is_read) begin
                        // Mid-point sample for reads
                    end
                end

                // ==========================================================
                // ACK — 9th SCL pulse
                // For WRITE: slave drives SDA low = ACK
                // For READ:  master drives SDA low = ACK, release = NACK
                // ==========================================================
                S_ACK_P0: begin
                    scl_drv <= 1'b1;         // SCL low
                    if (is_read) begin
                        // Master sends NACK after single-byte read
                        sda_drv <= 1'b0;     // release SDA → NACK (pull-up high)
                    end else begin
                        sda_drv <= 1'b0;     // release SDA (slave drives ACK)
                    end
                    if (timeout)
                        state <= S_ACK_P1;
                end

                S_ACK_P1: begin
                    scl_drv <= 1'b0;         // SCL released → high
                    if (timeout) begin
                        if (!is_read) begin
                            // Sample SDA from slave: 0=ACK (SDA low), 1=NACK
                            ack_o       <= ~sda_i;
                        end else begin
                            // Read complete — capture data
                            data_o <= shift_reg;
                        end
                        state    <= S_ACK_END;
                        timer_run <= 1'b0;
                    end else if (timer == (PRESCALE >> 1) && !is_read) begin
                        // Sample SDA at mid-point for ACK
                    end
                end

                S_ACK_END: begin
                    // One-cycle hold: SCL low, SDA in known state
                    scl_drv <= 1'b1;         // SCL low
                    sda_drv <= 1'b0;         // release SDA
                    cmd_busy  <= 1'b0;
                    cmd_ready <= 1'b1;
                    state     <= S_IDLE;
                end

                // ==========================================================
                // STOP — SDA ↑ while SCL ↑
                // ==========================================================
                S_STOP_P0: begin
                    scl_drv <= 1'b1;         // SCL low
                    sda_drv <= 1'b1;         // SDA low
                    if (timeout)
                        state <= S_STOP_P1;
                end

                S_STOP_P1: begin
                    sda_drv <= 1'b1;         // SDA low
                    if (timeout) begin
                        scl_drv <= 1'b0;     // release SCL → high
                        state   <= S_STOP_P2;
                    end else if (timer == (PRESCALE >> 1)) begin
                        scl_drv <= 1'b0;     // release SCL early
                    end
                end

                S_STOP_P2: begin
                    scl_drv <= 1'b0;         // SCL high
                    if (timeout) begin
                        sda_drv <= 1'b0;     // release SDA → high (STOP)
                        state   <= S_IDLE;
                        cmd_busy  <= 1'b0;
                        cmd_ready <= 1'b1;
                        timer_run <= 1'b0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
