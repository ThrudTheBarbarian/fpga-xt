// dma_master.sv — 6502-style bus master for ANTIC display DMA.
//
// Used when the FPGA is operating as a real-Atari ANTIC replacement
// (selected via $D481 bit 0 = 0). Instead of pulling display data
// from the local cpu_shadow BRAM, the FPGA halts the 6502 and drives
// its address bus directly, sampling the result off the system D bus.
//
// Bus protocol (matches what real ANTIC does on the Atari mainboard):
//
//   phi2:    ──┐    ┌────┐    ┌────┐    ┌────┐    ┌──
//             N│   N+1   │   N+2   │   N+3   │   N+4
//   /HALT:    ─┐_____________________________┌──────
//              │                             │
//              │ ←── halt asserted one ────→ │
//              │     phi2 cycle ahead        │
//   addr:    ── XXXXX <ANTIC drives>  XXXXXXXXX
//   rw:      ── XXXXX  <high (read)>  XXXXXXXXX
//   data:    ──XXXX <memory drives> XXXXXXXXXXX
//                          ↑
//              FPGA samples on phi2 fall
//
// State machine is FPGA-clk driven; phi2 is sampled into the FPGA
// domain (the caller is expected to feed a synchronised version).
//
// Each fetch is 2 phi2 cycles end-to-end:
//   cycle N:   /HALT asserted; 6502 finishes its current op
//   cycle N+1: FPGA drives addr + rw, samples data on phi2 fall,
//              releases /HALT
//
// Back-to-back fetches do NOT pipeline (yet) — each fetch returns to
// IDLE between requests. That keeps the protocol simple; if we ever
// need ANTIC-grade DMA bandwidth we'll layer a "hold /HALT for a
// burst" path on top.

`default_nettype none

module dma_master (
    input  wire        clk,           // FPGA fabric clock
    input  wire        rst,
    input  wire        phi2,          // Atari bus clock, sampled

    // Display-generator side.
    input  wire        req,           // assert to request a fetch
    input  wire [15:0] req_addr,
    output logic       ack,           // 1-cycle pulse: req accepted
    output logic       data_valid,    // 1-cycle pulse: req_data is valid
    output logic [7:0] req_data,
    output logic       busy,          // 1 while a fetch is in flight

    // Atari bus pins (driven by the FPGA when bus_oe=1; tri-state
    // upstream when bus_oe=0).
    output logic        halt_n,       // /HALT to 6502 (active low)
    output logic [15:0] addr_o,
    output logic        rw_o,         // 1 = read
    output logic        bus_oe,       // tri-state enable for addr/rw
    input  wire  [7:0]  data_i        // D bus from Atari memory
);

    typedef enum logic [2:0] {
        S_IDLE     = 3'd0,
        S_HALT_WAIT = 3'd1,    // /HALT asserted, waiting for phi2 fall
        S_DRIVE    = 3'd2,    // driving addr + rw, waiting for phi2 fall
        S_RELEASE  = 3'd3     // sample done, /HALT released, return to idle
    } state_t;

    state_t state;
    logic   phi2_q;
    wire    phi2_fall = phi2_q & ~phi2;
    logic [15:0] addr_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            phi2_q     <= 1'b0;
            halt_n     <= 1'b1;
            addr_o     <= 16'h0;
            rw_o       <= 1'b1;
            bus_oe     <= 1'b0;
            ack        <= 1'b0;
            data_valid <= 1'b0;
            req_data   <= 8'h00;
            busy       <= 1'b0;
            addr_q     <= 16'h0;
        end else begin
            phi2_q     <= phi2;
            ack        <= 1'b0;
            data_valid <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    halt_n <= 1'b1;
                    bus_oe <= 1'b0;
                    busy   <= 1'b0;
                    if (req) begin
                        addr_q <= req_addr;
                        ack    <= 1'b1;
                        halt_n <= 1'b0;       // assert /HALT immediately
                        busy   <= 1'b1;
                        state  <= S_HALT_WAIT;
                    end
                end

                S_HALT_WAIT: begin
                    // /HALT held low through this phi2 cycle so 6502
                    // sees it before its phi2-fall sample. On the
                    // observed phi2 fall we're now in the cycle where
                    // the 6502 has halted — start driving the bus.
                    if (phi2_fall) begin
                        addr_o <= addr_q;
                        rw_o   <= 1'b1;
                        bus_oe <= 1'b1;
                        state  <= S_DRIVE;
                    end
                end

                S_DRIVE: begin
                    // We're driving addr + rw across phi2 high. Sample
                    // data on phi2 fall.
                    if (phi2_fall) begin
                        req_data   <= data_i;
                        data_valid <= 1'b1;
                        bus_oe     <= 1'b0;
                        halt_n     <= 1'b1;     // release /HALT
                        state      <= S_RELEASE;
                    end
                end

                S_RELEASE: begin
                    // One-cycle settle so the 6502 sees /HALT high
                    // before any subsequent fetch re-asserts it.
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
