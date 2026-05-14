// peri_link.sv — FPGA-side bridge to the peripheral RP2354B (M25-2).
//
// 4-pin SPI master + 1-pin IRQ slave. The FPGA is the bus master;
// the peri-RP2354B is the only slave, driven directly by its on-chip
// PL022 SPI peripheral (no PIO required). /CS delimits frames so the
// PL022 slave is plain 8-bit Motorola SPI.
//
// Frame format
// ------------
// Each logical transaction is TWO 8-bit /CS pulses, MSB-first, SPI
// MODE 0 (CPOL=0, CPHA=0 — sample on rising edge, change on falling
// edge), with a master-controlled gap between the halves so the
// slave's polling loop can decode the cmd byte and load the read
// response into the PL022 TX FIFO before the data half starts.
//
//   +-------+------+-----+------+-------+
//   | /CS=0 | cmd  | gap | data | /CS=0 |
//   +-------+------+-----+------+-------+
//          8 SCK         8 SCK
//
//     cmd byte:  bit 7 = R/W (1 = read, 0 = write), bits 6..0 = addr
//     data byte: write payload (R/W=0); ignored on R/W=1 (master
//                receives the read result on MISO during this half)
//
// Splitting into two /CS pulses removes the ~200 ns timing race the
// previous single-frame format had between the cmd autopush and the
// data-half MISO drive. The slave now has the entire HALF_GAP_CYCLES
// to react. Cost: one extra /CS pin, one extra HALF_GAP per
// transaction (~32 cycles ≈ 200 ns at 162 MHz).
//
// Register map (peri-RP side, draft — extended as M25-3..M25-5 land):
//
//   Reads (R/W bit = 1)            Writes (R/W bit = 0)
//   --------------------           ----------------------
//     $00 PORTA_IN  *removed*        $00 PORTA_OUT *removed*
//     $01 PORTB_IN  *removed*        $01 PORTA_OE  *removed*
//     $02 TRIG      *removed*        $02 PORTB_OUT *removed*
//                                    $03 PORTB_OE  *removed*
//     $03 STATUS    flags
//     $04 ALLPOT    pot scan mask    $04 POT_OE    pot drive bits
//     $05..$0C POT0..POT7            $05 CMD       command pulse
//     $0D SIO_IN                     $06 SIO_OUT
//     $0E SIO_STAT
//     $0F..$1F (SD card window — M25-5)
//
// PORTA / PORTB / TRIG joystick traffic moved off the peri-RP onto a
// dedicated PCAL9722 GPIO expander (see joy_link.sv). The peri-RP
// keeps POT / SIO / SD because those have hard timing requirements
// the PCAL9722's 5 MHz SPI ceiling can't service.
//
// IRQ
// ---
// peri-RP asserts spi_irq (active low, open-drain) when STATUS has a
// flag set. Reading STATUS clears the IRQ source. Multiple sources
// coalesce on a single line.
//
// Clock
// -----
// SPI clock = clk_bus / (2 * CLK_DIV). At clk_bus = 162 MHz and
// CLK_DIV = 16, SPI clock ≈ 5.06 MHz — comfortable margin under
// PL022's max sustained slave rate.
//
// Timing
// ------
// One full transaction = 2 × (8 × 2 × CLK_DIV) shift cycles + 2 ×
// gap cycles ≈ 32×CLK_DIV + 2×HALF_GAP. At CLK_DIV=16 / HALF_GAP=32
// that's ~576 cycles ≈ 3.6 µs.

`default_nettype none

module peri_link #(
    // SPI clock divider. spi_clk runs at clk / (2 * CLK_DIV).
    parameter int unsigned CLK_DIV    = 16,
    // Cycles /CS held high between the cmd-half and the data-half.
    // Sized so the slave's RX → decode → TX-FIFO-push polling loop
    // (~50 cycles at 252 MHz peri-RP sys_clk) finishes comfortably.
    parameter int unsigned HALF_GAP   = 32,
    // Cycles /CS held high after the data half before the next
    // transaction can start. Lets the slave write back any side-
    // effects (e.g. PORTA_OUT update, IRQ recheck).
    parameter int unsigned TAIL_GAP   = 32,
    // Half-frame width — fixed at 8 bits per /CS pulse.
    parameter int unsigned BIT_BITS   = 8,

    // Derived widths.
    parameter int unsigned DIV_W      = $clog2(CLK_DIV + 1),
    parameter int unsigned BIT_CNT_W  = $clog2(BIT_BITS + 1),
    parameter int unsigned GAP_MAX    = (HALF_GAP > TAIL_GAP) ? HALF_GAP : TAIL_GAP,
    parameter int unsigned GAP_CNT_W  = $clog2(GAP_MAX + 1)
) (
    input  wire        clk,
    input  wire        rst,

    // ---- Transfer interface (clk_bus domain) ----------------------
    // xfer_start: 1-cycle pulse to start a transaction. Ignored if
    // xfer_busy=1.
    input  wire        xfer_start,
    input  wire [6:0]  xfer_addr,    // register address
    input  wire        xfer_we,      // 1 = write, 0 = read
    input  wire [7:0]  xfer_wdata,   // payload for writes
    output logic [7:0] xfer_rdata,   // result for reads (valid when xfer_done=1)
    output logic       xfer_done,    // 1-cycle pulse on completion
    output logic       xfer_busy,    // high during entire transaction

    // ---- IRQ from peri-RP -----------------------------------------
    // 2-FF synchronised, edge-detected. peri_irq_pulse fires for one
    // cycle on a falling edge of spi_irq (active-low IRQ assertion).
    input  wire        spi_irq,
    output logic       peri_irq_pulse,

    // ---- SPI pads -------------------------------------------------
    output logic       spi_clk,
    output logic       spi_mosi,
    input  wire        spi_miso,
    output logic       spi_cs_n      // active-low slave select
);

    // ---- IRQ synchroniser + edge detect ---------------------------
    logic [2:0] irq_sync;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) irq_sync <= 3'b111;
        else     irq_sync <= {irq_sync[1:0], spi_irq};
    end
    assign peri_irq_pulse = irq_sync[2] & ~irq_sync[1];

    // ---- FSM ------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,
        S_CMD_SHIFT,    // /CS=0, shifting 8 cmd bits
        S_HALF_GAP,     // /CS=1, waiting HALF_GAP cycles
        S_DATA_SHIFT,   // /CS=0, shifting 8 data bits (MOSI/MISO)
        S_TAIL_GAP      // /CS=1, waiting TAIL_GAP cycles
    } state_t;

    state_t                  state_q;
    logic [DIV_W-1:0]        clk_div_q;
    logic [BIT_CNT_W-1:0]    bit_cnt_q;
    logic [GAP_CNT_W-1:0]    gap_cnt_q;
    logic [BIT_BITS-1:0]     shift_out_q;
    logic [BIT_BITS-1:0]     shift_in_q;
    logic                    we_pending_q;
    logic [7:0]              wdata_pending_q;

    assign xfer_busy = (state_q != S_IDLE);
    assign spi_mosi  = shift_out_q[BIT_BITS-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q          <= S_IDLE;
            clk_div_q        <= '0;
            bit_cnt_q        <= '0;
            gap_cnt_q        <= '0;
            shift_out_q      <= '0;
            shift_in_q       <= '0;
            we_pending_q     <= 1'b0;
            wdata_pending_q  <= 8'h00;
            spi_clk          <= 1'b0;
            spi_cs_n         <= 1'b1;
            xfer_rdata       <= 8'h00;
            xfer_done        <= 1'b0;
        end else begin
            xfer_done <= 1'b0;

            unique case (state_q)
                S_IDLE: begin
                    spi_clk   <= 1'b0;
                    spi_cs_n  <= 1'b1;
                    clk_div_q <= '0;
                    if (xfer_start) begin
                        // Latch the data byte for use in S_DATA_SHIFT
                        // — xfer_wdata may change while we're shifting
                        // the cmd byte.
                        we_pending_q    <= xfer_we;
                        wdata_pending_q <= xfer_wdata;
                        // Cmd byte: {R/W, addr[6:0]}.
                        shift_out_q     <= {~xfer_we, xfer_addr};
                        shift_in_q      <= '0;
                        bit_cnt_q       <= '0;
                        spi_cs_n        <= 1'b0;       // assert /CS
                        state_q         <= S_CMD_SHIFT;
                    end
                end

                S_CMD_SHIFT, S_DATA_SHIFT: begin
                    if (clk_div_q == DIV_W'(CLK_DIV - 1)) begin
                        clk_div_q <= '0;
                        spi_clk   <= ~spi_clk;
                        if (!spi_clk) begin
                            // Rising edge — sample MISO. Cmd-half MISO
                            // is ignored; data-half MISO is the read
                            // response.
                            shift_in_q <= {shift_in_q[BIT_BITS-2:0], spi_miso};
                        end else begin
                            // Falling edge.
                            if (bit_cnt_q == BIT_CNT_W'(BIT_BITS - 1)) begin
                                // Last falling edge — half complete.
                                spi_clk   <= 1'b0;
                                spi_cs_n  <= 1'b1;     // deassert /CS
                                gap_cnt_q <= '0;
                                if (state_q == S_CMD_SHIFT) begin
                                    state_q <= S_HALF_GAP;
                                end else begin
                                    xfer_rdata <= shift_in_q;
                                    xfer_done  <= 1'b1;
                                    state_q    <= S_TAIL_GAP;
                                end
                            end else begin
                                shift_out_q <= {shift_out_q[BIT_BITS-2:0], 1'b0};
                                bit_cnt_q   <= bit_cnt_q + 1'b1;
                            end
                        end
                    end else begin
                        clk_div_q <= clk_div_q + 1'b1;
                    end
                end

                S_HALF_GAP: begin
                    spi_clk  <= 1'b0;
                    spi_cs_n <= 1'b1;
                    if (gap_cnt_q == GAP_CNT_W'(HALF_GAP - 1)) begin
                        // Begin data half.
                        shift_out_q <= wdata_pending_q;
                        shift_in_q  <= '0;
                        bit_cnt_q   <= '0;
                        clk_div_q   <= '0;
                        spi_cs_n    <= 1'b0;     // assert /CS
                        state_q     <= S_DATA_SHIFT;
                    end else begin
                        gap_cnt_q <= gap_cnt_q + 1'b1;
                    end
                end

                S_TAIL_GAP: begin
                    spi_clk  <= 1'b0;
                    spi_cs_n <= 1'b1;
                    if (gap_cnt_q == GAP_CNT_W'(TAIL_GAP - 1)) begin
                        state_q <= S_IDLE;
                    end else begin
                        gap_cnt_q <= gap_cnt_q + 1'b1;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
