// sally_core.sv — thin SystemVerilog wrapper around Arlet Ottens'
// verilog-6502 (`cpu.v` + `ALU.v`, in this directory). Renames the
// vendor signals to our conventions and inverts the active-low IRQ /
// NMI senses to match real-6502 / Atari pin polarity.
//
// Vendor core: github.com/Arlet/verilog-6502 (permissive license, see
// hdl/sally/cpu.v header). NMOS 6502, BCD enabled, single clock,
// fully static, synchronous-memory model — output address on cycle N,
// accept data on cycle N+1, fits BRAM dual-port shape directly.
//
// Undocumented opcodes (LAX, SAX, DCP, ISC, …) are NOT implemented by
// the vendor core — see M24-1d audit. M24-und adds them on top if
// needed.

`default_nettype none

module sally_core (
    input  wire        clk,
    input  wire        rst,         // active-high (sync'd by caller)

    // Bus interface — Arlet's core uses synchronous memory: AB
    // appears on cycle N, the bus master returns DI on cycle N+1.
    output wire [15:0] addr,
    input  wire [7:0]  data_in,     // value at addr from previous cycle
    output wire [7:0]  data_out,    // value to write when rw==0
    output wire        rw,          // 1 = read, 0 = write (matches 6502 R/W)

    // Stall input — held LOW to halt the CPU between memory cycles.
    // ANTIC's /HALT, WSYNC, and (future) bank-cache miss handler all
    // OR into this. Active-high here for consistency with our other
    // modules' `_n` convention; the wrapper inverts to feed the
    // vendor RDY input.
    input  wire        rdy,         // 1 = run, 0 = stall

    // Active-low interrupt inputs (real-6502 / Atari pin polarity).
    // The wrapper inverts to feed the vendor's active-high IRQ / NMI.
    input  wire        irq_n,
    input  wire        nmi_n,

    // SALLY Stage A — 12-bit hidden stack pointer.  stack_op asserts on
    // every push/pull cycle; s_high is the high 4 bits of SP.  Combined
    // with the 8-bit S in AXYS, this gives a 12-bit SP reaching the full
    // 4 KB hidden stack RAM in sally_mem.  See docs/6502-embellishments.md.
    output wire        stack_op,
    output wire [3:0]  s_high
);

    // ---- Polarity adapters ---------------------------------------------
    // Arlet: IRQ / NMI active-high, RDY active-high (same as ours).
    wire vendor_irq = ~irq_n;
    wire vendor_nmi = ~nmi_n;
    wire vendor_we;     // 1 = write — matches our rw=0 (write)

    // ---- Vendor core ---------------------------------------------------
    cpu u_cpu (
        .clk      (clk),
        .reset    (rst),
        .AB       (addr),
        .DI       (data_in),
        .DO       (data_out),
        .WE       (vendor_we),
        .IRQ      (vendor_irq),
        .NMI      (vendor_nmi),
        .RDY      (rdy),
        .stack_op (stack_op),
        .s_high   (s_high)
    );

    // ---- R/W convention -------------------------------------------------
    // Real 6502: R/W=1 read, R/W=0 write. Arlet's WE: 1 write, 0 read.
    assign rw = ~vendor_we;

endmodule

`default_nettype wire
