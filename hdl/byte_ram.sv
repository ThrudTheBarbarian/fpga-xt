// byte_ram.sv — single-port write, single-port read byte RAM. Used
// for all five snoop shadows (cpu_shadow, charset_shadow, pm_shadow,
// dl_shadow, textram_shadow). Sizes are parameterised so each
// instance can pick its actual depth — Efinity's BlockRAM inference
// keys off the array dimensions, so passing the right DEPTH lets the
// synth use the smallest BRAM tile.
//
// Read latency: 1 clk_bus cycle (registered output). The compositor
// pipeline accounts for this in M5+.

`default_nettype none

module byte_ram #(
    parameter int ADDR_W = 16,
    parameter int DEPTH  = 65536
) (
    input  wire              clk,
    input  wire              we,
    input  wire [ADDR_W-1:0] waddr,
    input  wire [7:0]        wdata,
    input  wire [ADDR_W-1:0] raddr,
    output logic [7:0]       rdata
);

    localparam int IDX_W = $clog2(DEPTH);
    logic [7:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (we) mem[waddr[IDX_W-1:0]] <= wdata;
        rdata <= mem[raddr[IDX_W-1:0]];
    end

`ifdef VERIFY_RAM_INIT
    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = 8'h00;
    end
`endif

endmodule

`default_nettype wire
