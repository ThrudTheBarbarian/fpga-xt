// joy_link.sv — FPGA-side SPI master for the PCAL9722 GPIO expander
// (joystick / fire-button I/O on rp-XT, M25-2c-rev).
//
// The PCAL9722 lives on its own SPI bus directly off FPGA HSIO — no
// LVC8T245 between, because the chip's split-supply design lets us
// run VDDI = 1.8 V (matches FPGA HSIO) and VDDP = 5 V (matches Atari
// joystick TTL) on the same package. See docs/hardware-notes.md
// "PCAL9722 — joystick GPIO expander".
//
// Frame format
// ------------
// One register access = one /CS pulse, 24 bits MSB-first, SPI MODE 0
// (CPOL=0, CPHA=0 — sample on rising edge, change on falling edge):
//
//     bits 23..17 : 7-bit device address (parameter SLAVE_ADDR_W,
//                   default 7'h40 = 0100_000 with A1 = A0 = 0)
//     bit  16     : R/W (1 = read, 0 = write)
//     bits 15..8  : 8-bit register address inside the PCAL9722
//     bits  7..0  : data byte — write payload (R/W=0) or read result
//                   on MISO (R/W=1). The chip drives MISO during
//                   bits 7..0 once it has the register address.
//
// Unlike peri_link, there's no mid-frame gap: the PCAL9722 is
// hardware (no firmware decode latency), so its MISO drive is valid
// within propagation-delay of bit 16's edge. /CS stays low for the
// whole 24-bit transaction.
//
// PCAL9722 register map (selected, see NXP datasheet for full list):
//
//     0x00  Input port 0 (P0[7:0])     ← live joystick PORTA
//     0x01  Input port 1 (P1[7:0])     ← live joystick PORTB
//     0x02  Input port 2 (P2[5:0])     ← lower 4 bits = TRIG[3:0]
//     0x04  Output port 0              → drive PORTA when DDR bit=1
//     0x05  Output port 1              → drive PORTB
//     0x06  Output port 2              → (unused, fire pins are
//                                         input-only)
//     0x0C  Configuration port 0       → DDR for P0 (1 = INPUT,
//     0x0D  Configuration port 1                   0 = output —
//     0x0E  Configuration port 2                   note INVERTED
//                                                  vs PIA's DDR)
//     0x4C  Interrupt status 0/1/2     → reading clears INT_N
//
// PIA's DDR convention is **1 = output**; PCAL9722's Configuration
// register is **1 = input**. joy_bridge above this module inverts
// the OE before writing.

`default_nettype none

module joy_link #(
    // SPI clock divider. spi_clk runs at clk / (2 * CLK_DIV).
    parameter int unsigned CLK_DIV     = 16,
    // Cycles /CS held high after the data byte before the next
    // transaction can start.
    parameter int unsigned IDLE_CYCLES = 32,
    // 7-bit device address byte (top 7 bits of cmd byte). Strap
    // pins A1/A0 = 00 → 0x40, 01 → 0x41, etc.
    parameter logic [6:0]  SLAVE_ADDR  = 7'h40,

    // Derived widths.
    parameter int unsigned DIV_W       = $clog2(CLK_DIV + 1),
    parameter int unsigned BIT_CNT_W   = $clog2(25),     // 0..24
    parameter int unsigned IDLE_CNT_W  = $clog2(IDLE_CYCLES + 1)
) (
    input  wire        clk,
    input  wire        rst,

    // ---- Transfer interface (clk_bus domain) ----------------------
    // xfer_start: 1-cycle pulse to start a transaction. Ignored if
    // xfer_busy=1.
    input  wire        xfer_start,
    input  wire [7:0]  xfer_addr,    // PCAL9722 register address
    input  wire        xfer_we,      // 1 = write, 0 = read
    input  wire [7:0]  xfer_wdata,   // payload for writes
    output logic [7:0] xfer_rdata,   // result for reads
    output logic       xfer_done,    // 1-cycle pulse on completion
    output logic       xfer_busy,    // high during entire transaction

    // ---- INT_N from PCAL9722 --------------------------------------
    // 2-FF synchronised, edge-detected. peri_int_pulse fires for one
    // cycle on a falling edge of spi_int_n (active-low INT_N).
    input  wire        spi_int_n,
    output logic       peri_int_pulse,

    // ---- SPI pads -------------------------------------------------
    output logic       spi_clk,
    output logic       spi_mosi,
    input  wire        spi_miso,
    output logic       spi_cs_n
);

    // ---- INT synchroniser + edge detect ---------------------------
    logic [2:0] int_sync;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) int_sync <= 3'b111;
        else     int_sync <= {int_sync[1:0], spi_int_n};
    end
    assign peri_int_pulse = int_sync[2] & ~int_sync[1];

    // ---- FSM ------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE,
        S_SHIFT,    // /CS=0, shifting 24 bits
        S_GAP       // /CS=1, IDLE_CYCLES wait
    } state_t;

    state_t                  state_q;
    logic [DIV_W-1:0]        clk_div_q;
    logic [BIT_CNT_W-1:0]    bit_cnt_q;
    logic [IDLE_CNT_W-1:0]   idle_cnt_q;
    logic [23:0]             shift_out_q;
    logic [7:0]              shift_in_q;

    assign xfer_busy = (state_q != S_IDLE);
    assign spi_mosi  = shift_out_q[23];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q     <= S_IDLE;
            clk_div_q   <= '0;
            bit_cnt_q   <= '0;
            idle_cnt_q  <= '0;
            shift_out_q <= '0;
            shift_in_q  <= '0;
            spi_clk     <= 1'b0;
            spi_cs_n    <= 1'b1;
            xfer_rdata  <= 8'h00;
            xfer_done   <= 1'b0;
        end else begin
            xfer_done <= 1'b0;

            unique case (state_q)
                S_IDLE: begin
                    spi_clk   <= 1'b0;
                    spi_cs_n  <= 1'b1;
                    clk_div_q <= '0;
                    if (xfer_start) begin
                        // 24-bit frame: cmd byte (SLAVE_ADDR + R/W),
                        // reg address byte, data byte.
                        shift_out_q <= {SLAVE_ADDR, ~xfer_we,
                                        xfer_addr,
                                        xfer_wdata};
                        shift_in_q  <= '0;
                        bit_cnt_q   <= '0;
                        spi_cs_n    <= 1'b0;
                        state_q     <= S_SHIFT;
                    end
                end

                S_SHIFT: begin
                    if (clk_div_q == DIV_W'(CLK_DIV - 1)) begin
                        clk_div_q <= '0;
                        spi_clk   <= ~spi_clk;
                        if (!spi_clk) begin
                            // Rising edge — sample MISO. Only the
                            // last 8 bits matter (read response in
                            // the data byte position); earlier bits
                            // are PCAL9722 driving MISO with don't-
                            // care during cmd / reg-addr halves.
                            shift_in_q <= {shift_in_q[6:0], spi_miso};
                        end else begin
                            // Falling edge.
                            if (bit_cnt_q == BIT_CNT_W'(23)) begin
                                spi_clk    <= 1'b0;
                                spi_cs_n   <= 1'b1;
                                xfer_rdata <= shift_in_q;
                                xfer_done  <= 1'b1;
                                idle_cnt_q <= '0;
                                state_q    <= S_GAP;
                            end else begin
                                shift_out_q <= {shift_out_q[22:0], 1'b0};
                                bit_cnt_q   <= bit_cnt_q + 1'b1;
                            end
                        end
                    end else begin
                        clk_div_q <= clk_div_q + 1'b1;
                    end
                end

                S_GAP: begin
                    spi_clk  <= 1'b0;
                    spi_cs_n <= 1'b1;
                    if (idle_cnt_q == IDLE_CNT_W'(IDLE_CYCLES - 1)) begin
                        state_q <= S_IDLE;
                    end else begin
                        idle_cnt_q <= idle_cnt_q + 1'b1;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
