// joy_bridge.sv — joystick / fire-button shadow above joy_link
// (M25-2c-rev). Sits between pia_regs / GTIA and the PCAL9722 GPIO
// expander.
//
// Two responsibilities:
//
// 1. **Write-through**: track joy_porta_out / joy_porta_oe /
//    joy_portb_out / joy_portb_oe (driven by pia_regs from PIA's
//    PORTA/PORTB output latches and DDR registers). When any of
//    these changes, issue an SPI write to push the new value to
//    the corresponding PCAL9722 register. Lazy: only the changed
//    bytes are pushed.
//
// 2. **Polling shadow**: every POLL_DIV clk_bus cycles (~30 kHz at
//    162 MHz default), issue back-to-back reads of Input port 0,
//    Input port 1, and Input port 2 to refresh joy_porta_in /
//    joy_portb_in / joy_fire.
//
// Key quirk: PCAL9722's Configuration register is **1 = input** /
// 0 = output, the OPPOSITE of PIA's DDR (1 = output). joy_*_oe
// writes go through `~` before hitting the wire.
//
// Priority: writes service first (snappy XEP80-style DDR flips),
// polls run between writes when nothing else is pending.

`default_nettype none

module joy_bridge #(
    // Cycles between successive poll-sequence kickoffs.
    parameter int unsigned POLL_DIV = 5346,

    // joy_link parameters — propagate down.
    parameter int unsigned LINK_CLK_DIV     = 16,
    parameter int unsigned LINK_IDLE_CYCLES = 32,
    parameter logic [6:0]  LINK_SLAVE_ADDR  = 7'h40
) (
    input  wire        clk,
    input  wire        rst,

    // ---- Write-through inputs (from pia_regs) ----------------------
    input  wire [7:0]  joy_porta_out,
    input  wire [7:0]  joy_porta_oe,
    input  wire [7:0]  joy_portb_out,
    input  wire [7:0]  joy_portb_oe,

    // ---- Polled shadow outputs (to pia_regs / GTIA) ----------------
    output logic [7:0] joy_porta_in,
    output logic [7:0] joy_portb_in,
    output logic [3:0] joy_fire,

    // ---- SPI pads (passes through joy_link) ------------------------
    output wire        spi_clk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n,
    input  wire        spi_int_n
);

    // ---- PCAL9722 register addresses --------------------------------
    // Reads:
    localparam logic [7:0] R_INPUT_0    = 8'h00;   // P0 → joy_porta_in
    localparam logic [7:0] R_INPUT_1    = 8'h01;   // P1 → joy_portb_in
    localparam logic [7:0] R_INPUT_2    = 8'h02;   // P2[3:0] → joy_fire
    // Writes:
    localparam logic [7:0] W_OUTPUT_0   = 8'h04;   // → PORTA pin level
    localparam logic [7:0] W_OUTPUT_1   = 8'h05;   // → PORTB pin level
    localparam logic [7:0] W_CONFIG_0   = 8'h0C;   // 1=INPUT, ~PORTA_OE
    localparam logic [7:0] W_CONFIG_1   = 8'h0D;   // 1=INPUT, ~PORTB_OE
    // Init-time only (M25-2c-rev follow-up — board bring-up may
    // tune these per the production datasheet revision):
    localparam logic [7:0] W_INT_MASK_0 = 8'h4A;   // 0 = enable INT on bit
    localparam logic [7:0] W_INT_MASK_1 = 8'h4B;
    localparam logic [7:0] W_INT_MASK_2 = 8'h4C;

    // ---- joy_link instance ------------------------------------------
    logic        xfer_start;
    logic [7:0]  xfer_addr;
    logic        xfer_we;
    logic [7:0]  xfer_wdata;
    wire  [7:0]  xfer_rdata;
    wire         xfer_done;
    wire         xfer_busy;
    wire         peri_int_pulse;       // unused for now; M25-3d wires this

    joy_link #(
        .CLK_DIV     (LINK_CLK_DIV),
        .IDLE_CYCLES (LINK_IDLE_CYCLES),
        .SLAVE_ADDR  (LINK_SLAVE_ADDR)
    ) u_link (
        .clk            (clk),
        .rst            (rst),
        .xfer_start     (xfer_start),
        .xfer_addr      (xfer_addr),
        .xfer_we        (xfer_we),
        .xfer_wdata     (xfer_wdata),
        .xfer_rdata     (xfer_rdata),
        .xfer_done      (xfer_done),
        .xfer_busy      (xfer_busy),
        .spi_int_n      (spi_int_n),
        .peri_int_pulse (peri_int_pulse),
        .spi_clk        (spi_clk),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .spi_cs_n       (spi_cs_n)
    );

    // ---- Boot-time init sequence -----------------------------------
    // PCAL9722 needs three writes at power-on to enable INT_N
    // signalling on input changes:
    //   INT_MASK_0 = $00 (enable INT on every PORTA bit)
    //   INT_MASK_1 = $00 (enable INT on every PORTB bit)
    //   INT_MASK_2 = $F0 (only enable INT on the 4 fire pins,
    //                     mask the upper 4 spare bits)
    // Without this the chip's INT_N stays high and joy_bridge falls
    // back to the 30 kHz poll loop. The polling-fallback path is
    // tested separately; this gives change-on-input the snappy
    // response real software (XEP80, mouse adapters) needs.
    typedef enum logic [2:0] {
        INIT_STEP_INT_MASK_0 = 3'd0,
        INIT_STEP_INT_MASK_1 = 3'd1,
        INIT_STEP_INT_MASK_2 = 3'd2,
        INIT_STEP_DONE       = 3'd3
    } init_step_t;
    init_step_t init_q;
    wire init_done = (init_q == INIT_STEP_DONE);

    // ---- Change detection -------------------------------------------
    // last_*_q tracks the value most recently *pushed* to PCAL9722.
    // Initialised to the inverse of the joy_* reset values so the
    // bring-up bring-up writes fire on the first cycle (forces the
    // PCAL9722 into a known state regardless of its prior contents).
    logic [7:0] last_porta_out_q, last_porta_oe_q;
    logic [7:0] last_portb_out_q, last_portb_oe_q;

    wire need_w_porta_out = (joy_porta_out != last_porta_out_q);
    wire need_w_porta_oe  = (joy_porta_oe  != last_porta_oe_q);
    wire need_w_portb_out = (joy_portb_out != last_portb_out_q);
    wire need_w_portb_oe  = (joy_portb_oe  != last_portb_oe_q);

    // ---- Poll tick --------------------------------------------------
    localparam int unsigned POLL_W = $clog2(POLL_DIV + 1);
    logic [POLL_W-1:0] poll_cnt_q;
    wire poll_tick = (poll_cnt_q == POLL_W'(POLL_DIV - 1));

    typedef enum logic [1:0] {
        POLL_DONE       = 2'd0,
        POLL_PORTA_NEXT = 2'd1,
        POLL_PORTB_NEXT = 2'd2,
        POLL_TRIG_NEXT  = 2'd3
    } poll_phase_t;
    poll_phase_t poll_q;

    typedef enum logic [3:0] {
        A_NONE      = 4'd0,
        A_W_PA_O    = 4'd1,
        A_W_PA_E    = 4'd2,
        A_W_PB_O    = 4'd3,
        A_W_PB_E    = 4'd4,
        A_R_PA_I    = 4'd5,
        A_R_PB_I    = 4'd6,
        A_R_TRIG    = 4'd7,
        A_INIT_STEP = 4'd8        // any of the boot-time INT_MASK writes
    } action_t;
    action_t in_flight_q;

    typedef enum logic [0:0] {
        S_IDLE = 1'b0,
        S_BUSY = 1'b1
    } state_t;
    state_t state_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            last_porta_out_q <= 8'h00;
            last_porta_oe_q  <= 8'hFF;
            last_portb_out_q <= 8'h00;
            last_portb_oe_q  <= 8'hFF;
            joy_porta_in     <= 8'hFF;
            joy_portb_in     <= 8'hFF;
            joy_fire         <= 4'hF;
            poll_cnt_q       <= '0;
            poll_q           <= POLL_DONE;
            in_flight_q      <= A_NONE;
            state_q          <= S_IDLE;
            init_q           <= INIT_STEP_INT_MASK_0;
            xfer_start       <= 1'b0;
            xfer_addr        <= 8'h00;
            xfer_we          <= 1'b0;
            xfer_wdata       <= 8'h00;
        end else begin
            xfer_start <= 1'b0;

            if (poll_cnt_q == POLL_W'(POLL_DIV - 1))
                poll_cnt_q <= '0;
            else
                poll_cnt_q <= poll_cnt_q + 1'b1;

            if (poll_tick && poll_q == POLL_DONE)
                poll_q <= POLL_PORTA_NEXT;

            unique case (state_q)
                S_IDLE: if (!xfer_busy) begin
                    if (!init_done) begin
                        // Boot-time INT_MASK writes (highest priority).
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b1;
                        unique case (init_q)
                            INIT_STEP_INT_MASK_0: begin
                                xfer_addr  <= W_INT_MASK_0;
                                xfer_wdata <= 8'h00;     // enable INT on all PORTA bits
                            end
                            INIT_STEP_INT_MASK_1: begin
                                xfer_addr  <= W_INT_MASK_1;
                                xfer_wdata <= 8'h00;
                            end
                            INIT_STEP_INT_MASK_2: begin
                                xfer_addr  <= W_INT_MASK_2;
                                xfer_wdata <= 8'hF0;     // mask spare bits 4..7,
                            end                           // enable bits 0..3 (fire buttons)
                            default: begin
                                xfer_addr  <= 8'h00;
                                xfer_wdata <= 8'h00;
                            end
                        endcase
                        in_flight_q <= A_INIT_STEP;
                        state_q     <= S_BUSY;
                    end else if (need_w_porta_out) begin
                        xfer_start       <= 1'b1;
                        xfer_we          <= 1'b1;
                        xfer_addr        <= W_OUTPUT_0;
                        xfer_wdata       <= joy_porta_out;
                        last_porta_out_q <= joy_porta_out;
                        in_flight_q      <= A_W_PA_O;
                        state_q          <= S_BUSY;
                    end else if (need_w_porta_oe) begin
                        xfer_start       <= 1'b1;
                        xfer_we          <= 1'b1;
                        xfer_addr        <= W_CONFIG_0;
                        xfer_wdata       <= ~joy_porta_oe;     // PCAL9722: 1 = INPUT
                        last_porta_oe_q  <= joy_porta_oe;
                        in_flight_q      <= A_W_PA_E;
                        state_q          <= S_BUSY;
                    end else if (need_w_portb_out) begin
                        xfer_start       <= 1'b1;
                        xfer_we          <= 1'b1;
                        xfer_addr        <= W_OUTPUT_1;
                        xfer_wdata       <= joy_portb_out;
                        last_portb_out_q <= joy_portb_out;
                        in_flight_q      <= A_W_PB_O;
                        state_q          <= S_BUSY;
                    end else if (need_w_portb_oe) begin
                        xfer_start       <= 1'b1;
                        xfer_we          <= 1'b1;
                        xfer_addr        <= W_CONFIG_1;
                        xfer_wdata       <= ~joy_portb_oe;
                        last_portb_oe_q  <= joy_portb_oe;
                        in_flight_q      <= A_W_PB_E;
                        state_q          <= S_BUSY;
                    end else if (poll_q == POLL_PORTA_NEXT) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_INPUT_0;
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= A_R_PA_I;
                        state_q     <= S_BUSY;
                    end else if (poll_q == POLL_PORTB_NEXT) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_INPUT_1;
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= A_R_PB_I;
                        state_q     <= S_BUSY;
                    end else if (poll_q == POLL_TRIG_NEXT) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_INPUT_2;
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= A_R_TRIG;
                        state_q     <= S_BUSY;
                    end
                end

                S_BUSY: if (xfer_done) begin
                    unique case (in_flight_q)
                        A_R_PA_I: begin
                            joy_porta_in <= xfer_rdata;
                            poll_q       <= POLL_PORTB_NEXT;
                        end
                        A_R_PB_I: begin
                            joy_portb_in <= xfer_rdata;
                            poll_q       <= POLL_TRIG_NEXT;
                        end
                        A_R_TRIG: begin
                            joy_fire <= xfer_rdata[3:0];
                            poll_q   <= POLL_DONE;
                        end
                        A_INIT_STEP: begin
                            // Advance through the boot-init sequence.
                            unique case (init_q)
                                INIT_STEP_INT_MASK_0: init_q <= INIT_STEP_INT_MASK_1;
                                INIT_STEP_INT_MASK_1: init_q <= INIT_STEP_INT_MASK_2;
                                INIT_STEP_INT_MASK_2: init_q <= INIT_STEP_DONE;
                                default:              init_q <= INIT_STEP_DONE;
                            endcase
                        end
                        default: ;     // writes — discard read result
                    endcase
                    in_flight_q <= A_NONE;
                    state_q     <= S_IDLE;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
