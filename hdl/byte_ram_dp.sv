// byte_ram_dp.sv — single-write, dual-read byte RAM.
//
// One write port (snoop), two independent read ports (e.g. dl_parser +
// compositor). Both reads have a 1-cycle BRAM latency, identical to
// the single-port byte_ram. Inferred as dual-port BRAM by Efinity
// (and most other vendors) when synthesised.
//
// Compared to instantiating two single-port byte_rams that mirror the
// same data, this halves the BRAM block count for the same depth — the
// motivating use case is mirroring the full 64 KB Atari address space
// inside Trion T20F256, which has 204 BRAM blocks (= one 64 KB
// dual-port instance fits, two single-port instances don't).
//
// `IDX_W = $clog2(DEPTH)` gives byte_ram-compatible "wrap if smaller
// than ADDR_W" semantics so callers can keep 16-bit addresses.

`default_nettype none

module byte_ram_dp #(
    parameter int ADDR_W = 16,
    parameter int DEPTH  = 65536
) (
    input  wire              clk,
    input  wire              we,
    input  wire [ADDR_W-1:0] waddr,
    input  wire [7:0]        wdata,
    input  wire [ADDR_W-1:0] raddr_a,
    output logic [7:0]       rdata_a,
    input  wire [ADDR_W-1:0] raddr_b,
    output logic [7:0]       rdata_b
);

    localparam int IDX_W = $clog2(DEPTH);
    logic [7:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (we) mem[waddr[IDX_W-1:0]] <= wdata;
        rdata_a <= mem[raddr_a[IDX_W-1:0]];
        rdata_b <= mem[raddr_b[IDX_W-1:0]];
    end

`ifdef VERIFY_RAM_INIT
    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = 8'h00;
    end
`endif

endmodule

`default_nettype wire
