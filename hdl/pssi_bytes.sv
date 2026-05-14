// pssi_bytes.sv — chiplet-extension byte-push register for pssi_tx.
//
// Exposes a raw byte-stream interface to 6502 software via two chiplet-
// extension registers:
//
//   $D49C  PSSI_BYTE     W: any write pushes the data byte into the
//                            pssi_tx FIFO (subject to pssi_tx's own
//                            back-pressure / overflow handling).
//                          R: returns the most recently written byte
//                             (debug / readback).
//   $D49D  PSSI_STATUS   R: bit 0 = overflow_q (sticky; set by pssi_tx
//                                   when a write was dropped because the
//                                   ring was full)
//                          W: writing bit 0 = 1 clears overflow_q.
//
// Software contract for emitting a DRAW command (new VDI wire format,
// see docs/VDI-opcodes.md):
//
//   for each byte b in opcode + parameter bytes:
//       STA #b, $D49C
//   if total byte count is odd:
//       STA #$00, $D49C    ; software-emitted NOP padding
//   LDA $D49D
//   AND #$01               ; bit 0 = overflow flag
//   BNE handle_overflow
//
// Address decode: chiplet-ext is waddr[7]=1; the byte offset 0x1C/0x1D
// lives just past draw_regs's 0x08–0x1B span.

`default_nettype none

module pssi_bytes (
    input  wire        clk,
    input  wire        rst,

    // Write port from bus_snoop (same shape as draw_regs).
    input  wire        we,             // snoop_we_antic
    input  wire [7:0]  waddr,          // snoop_addr[7:0]
    input  wire [7:0]  wdata,

    // Read port (combinational against the live bus address).
    input  wire [7:0]  raddr,
    output logic [7:0] rdata,

    // pssi_tx writer port (single-cycle WE pulses).
    output logic [7:0] pssi_wr_byte,
    output logic       pssi_wr_we,

    // Status reflection from pssi_tx (in the same clk domain).
    input  wire        pssi_overflow_q,    // sticky, latched in pssi_tx
    output logic       pssi_overflow_clear // 1-cycle pulse on software W bit 0
);

    // ---- Address decode -----------------------------------------------
    localparam logic [6:0] OFF_BYTE   = 7'h1C;
    localparam logic [6:0] OFF_STATUS = 7'h1D;

    wire       is_chiplet_w = waddr[7];
    wire [6:0] off_w        = waddr[6:0];

    wire       is_chiplet_r = raddr[7];
    wire [6:0] off_r        = raddr[6:0];

    // ---- Last-byte readback storage -----------------------------------
    logic [7:0] last_byte_q;

    // ---- Write FSM ----------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            last_byte_q          <= 8'h00;
            pssi_wr_byte         <= 8'h00;
            pssi_wr_we           <= 1'b0;
            pssi_overflow_clear  <= 1'b0;
        end else begin
            // Default each cycle: deassert single-cycle pulses.
            pssi_wr_we          <= 1'b0;
            pssi_overflow_clear <= 1'b0;

            if (we && is_chiplet_w) begin
                case (off_w)
                    OFF_BYTE: begin
                        pssi_wr_byte <= wdata;
                        pssi_wr_we   <= 1'b1;
                        last_byte_q  <= wdata;
                    end
                    OFF_STATUS: begin
                        if (wdata[0])
                            pssi_overflow_clear <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // ---- Read side ----------------------------------------------------
    always_comb begin
        rdata = 8'h00;
        if (is_chiplet_r) begin
            case (off_r)
                OFF_BYTE:   rdata = last_byte_q;
                OFF_STATUS: rdata = {7'h00, pssi_overflow_q};
                default:    rdata = 8'h00;
            endcase
        end
    end

endmodule

`default_nettype wire
