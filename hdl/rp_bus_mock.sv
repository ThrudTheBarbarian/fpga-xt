// rp_bus_mock.sv — behavioural model of the RP-side bus PIO + servicer.
//
// Sits at the far end of the FPGA->RP bus during sim. Decodes tags,
// services FETCH (replying after a fixed latency), latches SET writes
// into a mock framebuffer, ignores NOP, traps DRAW until M17.
//
// Wire format: docs/wire-protocol.md § "FPGA<->RP bus".
//
// Latency model: FETCH responses come out of the rsp_* port FETCH_LATENCY
// cycles after the FETCH beat lands, simulating PIO ingest + ARM/PIO
// memory access + PIO emit. The shift register is a behavioural
// approximation; the production RP-side path will have variable
// latency depending on PSRAM/SRAM contention.

`default_nettype none
`include "bus_opcodes.vh"

module rp_bus_mock #(
    parameter int FB_BYTES      = 256 * 1024,
    parameter int FETCH_LATENCY = 4
) (
    input  wire        clk,
    input  wire        rst,

    // FPGA->RP bus input (one beat per clk).
    input  wire [1:0]  bus_tag,
    input  wire [23:0] bus_payload,

    // RP->FPGA bus output (response side; one beat per clk when valid).
    output logic [15:0] rsp_payload,
    output logic        rsp_valid,

    // Diagnostic counters.
    output logic [31:0] mock_fetch_count,
    output logic [31:0] mock_set_count,
    output logic [31:0] mock_draw_count,
    output logic [31:0] mock_bad_tag_count,
    output logic [31:0] mock_set_misalign_count
);

    // Mock framebuffer. Zero-initialised at sim time 0 so unwritten
    // addresses fetch as 0 (matching the testbench's software model).
    logic [11:0] fb [0:FB_BYTES-1];        // M10c: 12-bit cells (PF + P|M shared + M-only)
    initial begin
        for (int k = 0; k < FB_BYTES; k++) fb[k] = 12'h0;
    end

    // SET state machine: SET arrives as two consecutive beats with
    // tag == BUS_TAG_SET. The first beat carries the address; the
    // second beat carries the data.
    logic        set_addr_pending;
    logic [23:0] set_addr;

    // FETCH response delay pipeline. Stage 0 = newest, stage
    // FETCH_LATENCY-1 = output (drives rsp_*).
    logic [15:0] pend_data  [0:FETCH_LATENCY-1];
    logic        pend_valid [0:FETCH_LATENCY-1];

    // Capture current cycle's lookup result for FETCH. Index width is
    // exactly $clog2(FB_BYTES) so Verilator's WIDTHTRUNC stays quiet.
    localparam int FB_AW = $clog2(FB_BYTES);
    logic [15:0] fetch_response_now;
    always_comb begin
        logic [FB_AW-1:0] a;
        a = bus_payload[FB_AW-1:0];
        // FETCH protocol stays 16-bit (2× 8-bit) — preserves the legacy
        // tb_prefetch byte-pattern test path. The bottom 8 bits of each
        // 12-bit fb cell are returned; the M-only top nibble (M10c)
        // doesn't escape via FETCH.
        if (bus_payload >= FB_BYTES - 24'd1) fetch_response_now = 16'h0000;
        else fetch_response_now = {fb[a + 1'b1][7:0], fb[a][7:0]};
    end

    integer i;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            mock_fetch_count        <= 32'h0;
            mock_set_count          <= 32'h0;
            mock_draw_count         <= 32'h0;
            mock_bad_tag_count      <= 32'h0;
            mock_set_misalign_count <= 32'h0;
            set_addr_pending        <= 1'b0;
            set_addr                <= 24'h0;
            for (i = 0; i < FETCH_LATENCY; i++) begin
                pend_data[i]  <= 16'h0;
                pend_valid[i] <= 1'b0;
            end
            rsp_payload <= 16'h0;
            rsp_valid   <= 1'b0;
        end else begin
            // Default: shift the response pipeline by one stage.
            for (i = FETCH_LATENCY - 1; i > 0; i--) begin
                pend_data[i]  <= pend_data[i-1];
                pend_valid[i] <= pend_valid[i-1];
            end
            pend_data[0]  <= 16'h0;
            pend_valid[0] <= 1'b0;

            unique case (bus_tag)
                `BUS_TAG_NOP: begin
                    // Nothing.
                    set_addr_pending <= 1'b0;   // any non-SET cycle drops the SET sequence
                end
                `BUS_TAG_FETCH: begin
                    mock_fetch_count <= mock_fetch_count + 32'd1;
                    pend_data[0]     <= fetch_response_now;
                    pend_valid[0]    <= 1'b1;
                    set_addr_pending <= 1'b0;
                end
                `BUS_TAG_SET: begin
                    if (!set_addr_pending) begin
                        // First SET beat — capture the address.
                        set_addr_pending <= 1'b1;
                        set_addr         <= bus_payload;
                        if (bus_payload[0]) begin
                            mock_set_misalign_count <= mock_set_misalign_count + 32'd1;
                        end
                    end else begin
                        // Second SET beat — commit the data. Each 24-bit
                        // payload carries 2× 12-bit idx_buf cells:
                        //   bus_payload[7:0]   = lo legacy byte
                        //   bus_payload[15:8]  = hi legacy byte
                        //   bus_payload[19:16] = lo M-only nibble (M10c)
                        //   bus_payload[23:20] = hi M-only nibble (M10c)
                        //
                        // Each fb cell is 12-bit:
                        //   bits[7:0]  = legacy byte
                        //   bits[11:8] = M-only nibble
                        //
                        // Legacy 16-bit cmd_data senders zero-extend to
                        // 24-bit → top byte of payload is 0 → both M-only
                        // nibbles default to 0, fb's bottom byte
                        // matches the original 8-bit encoding.
                        if (set_addr < FB_BYTES - 24'd1) begin
                            fb[set_addr[FB_AW-1:0]]        <=
                                {bus_payload[19:16], bus_payload[7:0]};
                            fb[set_addr[FB_AW-1:0] + 1'b1] <=
                                {bus_payload[23:20], bus_payload[15:8]};
                        end
                        mock_set_count   <= mock_set_count + 32'd1;
                        set_addr_pending <= 1'b0;
                    end
                end
                `BUS_TAG_DRAW: begin
                    mock_draw_count  <= mock_draw_count + 32'd1;
                    set_addr_pending <= 1'b0;
                end
                default: begin
                    mock_bad_tag_count <= mock_bad_tag_count + 32'd1;
                    set_addr_pending   <= 1'b0;
                end
            endcase

            // Drive the response port from the pipeline tail.
            rsp_payload <= pend_data[FETCH_LATENCY-1];
            rsp_valid   <= pend_valid[FETCH_LATENCY-1];
        end
    end

endmodule

`default_nettype wire
