// sally_mem.sv — SALLY memory subsystem (v2a: DDR3 era).
//
// CPU's view of memory in tiered form:
//
//   $0000-$3FFF  Direct BRAM (zero page + stack + main RAM lo)
//   $4000-$7FFF  Banked-window port (DDR3 via AXI).
//                bank_xlat translates (cpu_addr, bank-select state,
//                view) into a 16-bit bank_id + 12-bit offset_in_block.
//                The composed AXI address is read via banked_axi_reader.
//                CPU bank-select state is snooped from zero-page
//                $0082-$0085. ANTIC's view comes from chiplet-ext
//                registers $D488-$D48B.
//   $8000-$BFFF  Direct BRAM (main RAM hi)
//   $C000-$CFFF  OS ROM lo (loadable, M24-6)
//   $D000-$D7FF  Hardware-register page — combinational override of
//                BRAM. Receiver (GTIA / ANTIC / POKEY) supplies
//                hwreg_dout combinationally; sally_mem registers it
//                alongside the BRAM read so both share the N → N+1
//                pipeline.
//   $D800-$FFFF  OS ROM hi (loadable, M24-6)
//
// Pipeline summary:
//   Cycle N: cpu_addr = X presented (combinational from CPU state).
//   Cycle N posedge: bram_dout_q ← mem[X];
//                    hwreg_dout_q ← hwreg_dout (current cycle's);
//                    banked_axi_reader.req_valid fires if X ∈ $4000-$7FFF;
//                    was_hwreg_q / was_bank_q latched.
//   Cycle N+M: data_out = was_hwreg_q ? hwreg_dout_q :
//                         was_bank_q  ? axi_rdata_q   :
//                                        bram_dout_q;
//              For the BRAM/hwreg paths M=1 (single-cycle). For the
//              banked path M is the AXI round-trip in clk cycles
//              (~25-40 at SALLY=AXI clock); SALLY stalls via `busy`.
//
// v2a notes (sally-mem-v2.md):
//   - The HyperRAM-era N-way set-associative bank_cache (four
//     instances: code/data × partition/stream) is gone. The Phase 0
//     fmax probe identified that cache as the structural fmax limiter
//     on Zynq -2; the HyperRAM latency it was hiding no longer exists.
//   - v2a stalls SALLY for the full AXI round-trip on every banked
//     access. v2b will add a 1-line prefetch buffer; v2c adds the
//     write path. Most legacy Atari code never enters $4000-$7FFF
//     banked windows, so v2a is a usable bring-up state.
//   - bank_xlat is unchanged. The AXI address composition is a
//     placeholder shape representative of the real DDR3 layout
//     (DDR3_BANKED_BASE + bank_id*BANK_SIZE + offset) for fmax-probe
//     purposes; the modern-half cart-load contract will set the base
//     and stride in a chiplet-ext register before SALLY is brought
//     out of reset.
//   - The attr_lookup ports (Step 4 streaming-bypass classifier) are
//     gone: the classifier existed only to route to the streaming-
//     cache quadrants, which no longer exist.

`default_nettype none

module sally_mem #(
    // OS ROM image baked into the BRAM at synth/sim init via $readmemh.
    // Empty string = leave BRAM uninitialised (current sim behaviour).
    // Production builds override with a path to a 64 KB hex image
    // (one byte per line, addresses $0000..$FFFF — only $C000-$CFFF
    // and $D800-$FFFF need to be populated; the rest is overwritten
    // by RAM accesses). The runtime rom-load chiplet path ($D48C-$F)
    // remains usable on top of this for live OS swaps.
    parameter string         OS_ROM_HEX_PATH    = "",
    // Base byte-address in DDR3 for the banked-window backing store.
    // Production builds set this from a chiplet-ext register; for
    // synth the constant gives Vivado a real address to time against.
    parameter logic [31:0]   DDR3_BANKED_BASE   = 32'h2000_0000
) (
    input  wire        clk,
    input  wire        rst,

    // SALLY-side memory port.
    input  wire [15:0] addr,
    input  wire [7:0]  data_in,
    input  wire        rw,
    output logic [7:0] data_out,
    input  wire        rdy,
    output wire        busy,           // 1 when banked_axi_reader in flight

    // Hardware-register passthrough.
    output wire [15:0] hwreg_addr,
    output wire        hwreg_we,
    output wire [7:0]  hwreg_din,
    input  wire [7:0]  hwreg_dout,

    // CPU bank-select state — latched from zero-page writes.
    // Exposed as outputs so antic_top can mirror to ANTIC's read path
    // if needed (currently only used internally by bank_xlat).
    output wire [7:0]  cpu_code_bank_q,
    output wire [7:0]  cpu_data_bank_q,
    output wire [7:0]  cpu_regc_bank_lo_q,
    output wire [7:0]  cpu_regc_bank_hi_q,

    // ANTIC-view bank-select state (from antic_regs $D488..$D48B).
    // Tie low for CPU-only configurations.
    input  wire [7:0]  antic_code_bank,
    input  wire [7:0]  antic_data_bank,
    input  wire [7:0]  antic_regc_bank_lo,
    input  wire [7:0]  antic_regc_bank_hi,

    // View selector — 0 = CPU view, 1 = ANTIC view.
    input  wire        view_is_antic,

    // M-PBI step 2/3: /MPD Math-Pack Disable from the PBI device.
    input  wire        bus_mpd_n_in,

    // M-PBI step 3: external bus D[7:0] sample.
    input  wire [7:0]  bus_pbi_rdata,

    // M-PBI deferred #2: cart-detect inputs (active-low).
    input  wire        bus_rd4_n_in,   // $8000-$9FFF cart present
    input  wire        bus_rd5_n_in,   // $A000-$BFFF cart present

    // AXI4 burst read + single-beat write master to PS DDR3
    // (via Zynq AXI HP port).
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    input  wire        m_axi_rlast,
    output wire        m_axi_rready,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [7:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    // M24-6 OS ROM load port. Pulse rom_we high for one cycle with
    // a valid rom_addr / rom_data to commit a byte directly into
    // the BRAM, bypassing the normal CPU write pipeline.
    input  wire [15:0] rom_addr,
    input  wire [7:0]  rom_data,
    input  wire        rom_we,

    // ANTIC DMA read port — independent clock domain (clk_sys).
    // Provides a second read port into the main BRAM so ANTIC can
    // fetch display data without halting SALLY (at CLOCK_MULT>=2).
    // dma_addr is sampled on posedge dma_clk; dma_rdata is registered
    // and available 1 cycle later.
    input  wire         dma_clk,
    input  wire [15:0]  dma_addr,
    output wire [7:0]   dma_rdata
);

    // ---- Backing BRAM ($0000-$3FFF, $8000-$FFFF less hwreg page) ---
    logic [7:0] mem [0:65535];

    // BRAM init from a baked-in OS image when OS_ROM_HEX_PATH is set.
    initial if (OS_ROM_HEX_PATH != "") $readmemh(OS_ROM_HEX_PATH, mem);

    // ---- Hidden stack BRAM (4 KB, SALLY 6502 embellishment Stage A) ----
    // 4096 bytes of dedicated stack RAM that is NOT visible at any normal
    // 16-bit address.  Accesses to $0100-$01FF (the legacy 6502 stack
    // page) are redirected here to the TOP 256 bytes ($F00-$FFF), giving
    // a backward-compatible alias window for existing code that uses
    // TSX + LDA $0100,X style addressing.
    //
    // Stage A Increment 1 (this file): only the top 256 bytes are reachable
    // via the alias.  cpu.v still uses an 8-bit SP, so the lower 3840
    // bytes are unused for now.
    //
    // Stage A Increment 2 will widen the CPU SP to 12 bits and add a
    // `stack_op` signal that lets the CPU reach the full 4 KB via PHA /
    // PLA / JSR / RTS / RTI / BRK and the new SP-relative addressing
    // mode.  See docs/6502-embellishments.md.
    (* ram_style = "block" *)
    logic [7:0] stack_mem [0:4095];

    // ---- Address-decode helpers -----------------------------------
    wire is_hwreg_page   = (addr[15:11] == 5'b1101_0);   // $D000-$D7FF
    wire is_bank_window  = (addr[15:14] == 2'b01);       // $4000-$7FFF
    wire is_mpd_window   = (addr[15:11] == 5'b11011);    // $D800-$DFFF
    wire is_cart_s4_window = (addr[15:13] == 3'b100);    // $8000-$9FFF
    wire is_cart_s5_window = (addr[15:13] == 3'b101);    // $A000-$BFFF
    wire is_stack_page     = (addr[15:8] == 8'h01);      // $0100-$01FF
    wire cart_external_read = rw                                // reads only
                            & ((is_cart_s4_window & ~bus_rd4_n_in)
                            |  (is_cart_s5_window & ~bus_rd5_n_in));

    // Alias addressing into stack_mem: $0100-$01FF maps to the top 256
    // bytes ($F00-$FFF), i.e., stack_mem[{4'hF, addr[7:0]}].
    wire [11:0] stack_alias_addr = {4'hF, addr[7:0]};

    // ---- CPU bank-select snoop -----------------------------------
    // Mirror writes to $0082-$0085 into latched registers so bank_xlat
    // sees the live values without needing a BRAM read port.
    logic [7:0] cpu_code_bank, cpu_data_bank;
    logic [7:0] cpu_regc_bank_lo, cpu_regc_bank_hi;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cpu_code_bank    <= 8'h00;
            cpu_data_bank    <= 8'h00;
            cpu_regc_bank_lo <= 8'h00;
            cpu_regc_bank_hi <= 8'h00;
        end else if (rdy && !rw) begin
            case (addr)
                16'h0082: cpu_code_bank    <= data_in;
                16'h0083: cpu_data_bank    <= data_in;
                16'h0084: cpu_regc_bank_lo <= data_in;
                16'h0085: cpu_regc_bank_hi <= data_in;
                default: ;
            endcase
        end
    end

    assign cpu_code_bank_q    = cpu_code_bank;
    assign cpu_data_bank_q    = cpu_data_bank;
    assign cpu_regc_bank_lo_q = cpu_regc_bank_lo;
    assign cpu_regc_bank_hi_q = cpu_regc_bank_hi;

    // ---- Bank translator -----------------------------------------
    wire [15:0] bank_id_w;
    wire [11:0] offset_in_block_w;
    wire        is_in_window_w;        // identical to is_bank_window when CPU view

    bank_xlat u_xlat (
        .cpu_code_bank      (cpu_code_bank),
        .cpu_data_bank      (cpu_data_bank),
        .cpu_regc_bank_lo   (cpu_regc_bank_lo),
        .cpu_regc_bank_hi   (cpu_regc_bank_hi),
        .antic_code_bank    (antic_code_bank),
        .antic_data_bank    (antic_data_bank),
        .antic_regc_bank_lo (antic_regc_bank_lo),
        .antic_regc_bank_hi (antic_regc_bank_hi),
        .cpu_addr           (addr),
        .view_is_antic      (view_is_antic),
        .is_in_window       (is_in_window_w),
        .offset_in_block    (offset_in_block_w),
        .bank_id            (bank_id_w)
    );

    // ---- Banked-window AXI port ----------------------------------
    // Address composition (placeholder): byte address into DDR3 is
    //    DDR3_BANKED_BASE | {bank_id_w[15:0], offset_in_block_w[11:0]}.
    // The OR-form keeps the synth path short and the base register
    // visible for retiming. Production builds will replace the
    // hardcoded base with a chiplet-ext register read.
    //
    // v2c: banked_axi_reader handles both reads (with 1-line prefetch)
    // and writes (single-beat write-through, line invalidated on
    // matching write). req_valid is level-sensitive (held high while
    // SALLY presents any banked-window access); req_we selects the
    // direction. req_ready is combinational on read-hit / pulses on
    // read-burst-complete / pulses on write-B-response.
    wire [31:0] axi_req_addr = DDR3_BANKED_BASE
                             | {4'b0000, bank_id_w[15:0], offset_in_block_w[11:0]};
    wire        axi_req_valid = rdy && is_in_window_w;
    wire        axi_req_we    = !rw;     // SALLY rw: 1=read, 0=write
    wire [7:0]  axi_rdata_w;
    wire        axi_ready_w;

    banked_axi_reader #(
        .AXI_ADDR_W (32)
    ) u_axi_reader (
        .clk           (clk),
        .rst           (rst),
        .req_addr      (axi_req_addr),
        .req_valid     (axi_req_valid),
        .req_we        (axi_req_we),
        .req_wdata     (data_in),
        .req_rdata     (axi_rdata_w),
        .req_ready     (axi_ready_w),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rready  (m_axi_rready),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready)
    );

    // SALLY stalls while the reader can't serve the current request.
    assign busy = axi_req_valid && !axi_ready_w;

    // Latch the AXI-returned byte for the output mux. Latched on the
    // cycle ready fires (hit or burst-complete), aligned with the
    // bram_dout_q / was_bank_q latches for N+1 mux consumption.
    logic [7:0] axi_rdata_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)              axi_rdata_q <= 8'h00;
        else if (axi_ready_w) axi_rdata_q <= axi_rdata_w;
    end

    // ---- Read pipeline + path-tracking flops ----------------------
    logic [7:0] bram_dout_q;
    logic [7:0] stack_dout_q;         // from stack_mem read port
    logic [7:0] hwreg_dout_q;
    logic       was_hwreg_q;
    logic       was_bank_q;
    logic       was_stack_q;          // prev addr was stack-page ($0100-$01FF)
    logic       was_mpd_window_q;     // M-PBI step 2: was the prev addr in $D800-$DFFF
    logic       was_cart_external_q;  // M-PBI #2: prev addr was cart-window AND RD asserted

    // Main BRAM write port: clk-only (no reset), single write-enable +
    // address + data mux. Vivado BRAM inference requires this shape.
    // ROM-load wins on the rare same-cycle collision with a CPU write —
    // matches the original Verilog last-assignment-wins ordering.
    //
    // Stack-page writes ($0100-$01FF) are NOT gated out of mem_we here —
    // they land in both main mem AND stack_mem (below).  Reads from the
    // stack page prefer stack_mem via was_stack_q, so the alias is the
    // single source of truth.  Keeping mem_we's expression simple is
    // critical: any extra terms in the condition were observed (May 16)
    // to break Vivado's 64K cascade BRAM inference on a couple of bit
    // columns (DRC REQP-1962 ADDR15 cascade mismatch).  The few wasted
    // main-mem writes to $0100-$01FF cost nothing in steady state.
    wire        cpu_w      = rdy && !rw && !is_hwreg_page && !is_in_window_w;
    wire        mem_we     = cpu_w || rom_we;
    wire [15:0] mem_addr_w = rom_we ? rom_addr : addr;
    wire  [7:0] mem_din_w  = rom_we ? rom_data : data_in;

    always_ff @(posedge clk) begin
        if (mem_we) mem[mem_addr_w] <= mem_din_w;
    end

    // ---- Stack BRAM write port (separate array; reads prefer this) ----
    // Stack page writes always land here in parallel with main mem so
    // the alias window reads back the correct value.  Same applies to
    // rom_we writes targeting $0100-$01FF.
    wire        stack_cpu_w  = rdy && !rw && is_stack_page;
    wire        rom_is_stack = (rom_addr[15:8] == 8'h01);
    wire        stack_we     = stack_cpu_w || (rom_we && rom_is_stack);
    wire [11:0] stack_addr_w = rom_we ? {4'hF, rom_addr[7:0]} : stack_alias_addr;
    wire  [7:0] stack_din_w  = rom_we ? rom_data : data_in;

    always_ff @(posedge clk) begin
        if (stack_we) stack_mem[stack_addr_w] <= stack_din_w;
    end

    // ANTIC DMA read port — independent clock.  Vivado infers a true
    // dual-port BRAM (RAMB36E1 has two independent ports, each with
    // its own clock).  The array declaration above (`mem[0:65535]`)
    // is shared between both ports.
    logic [7:0] dma_rdata_q;
    always_ff @(posedge dma_clk) begin
        dma_rdata_q <= mem[dma_addr];
    end
    assign dma_rdata = dma_rdata_q;

    // Read pipeline + path-tracking flops. Async reset kept here, but
    // away from the mem array so Vivado can still infer BRAM above.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bram_dout_q          <= 8'h00;
            stack_dout_q         <= 8'h00;
            hwreg_dout_q         <= 8'h00;
            was_hwreg_q          <= 1'b0;
            was_bank_q           <= 1'b0;
            was_stack_q          <= 1'b0;
            was_mpd_window_q     <= 1'b0;
            was_cart_external_q  <= 1'b0;
        end else if (rdy) begin
            bram_dout_q          <= mem[addr];
            stack_dout_q         <= stack_mem[stack_alias_addr];
            hwreg_dout_q         <= hwreg_dout;
            was_hwreg_q          <= is_hwreg_page;
            was_bank_q           <= is_in_window_w;
            was_stack_q          <= is_stack_page;
            was_mpd_window_q     <= is_mpd_window;
            was_cart_external_q  <= cart_external_read;
        end
    end

    // ---- Output mux ------------------------------------------------
    // Priorities, top to bottom:
    //   1. was_hwreg_q              -> hwreg_dout_q (internal regs)
    //   2. was_cart_external_q      -> bus_pbi_rdata (physical cart wins)
    //   3. was_mpd_window_q & /MPD  -> bus_pbi_rdata (PBI replaces FP ROM)
    //   4. was_bank_q               -> axi_rdata_q  (DDR3-backed bank)
    //   5. was_stack_q              -> stack_dout_q (hidden stack alias)
    //   6. default                  -> bram_dout_q
    wire mpd_active = ~bus_mpd_n_in;
    assign data_out = was_hwreg_q                       ? hwreg_dout_q
                    : was_cart_external_q               ? bus_pbi_rdata
                    : (was_mpd_window_q & mpd_active)   ? bus_pbi_rdata
                    : was_bank_q                        ? axi_rdata_q
                    : was_stack_q                       ? stack_dout_q
                                                        : bram_dout_q;

    // ---- Hardware-register write passthrough ----------------------
    assign hwreg_we   = !rw && is_hwreg_page;
    assign hwreg_din  = data_in;
    assign hwreg_addr = addr;

endmodule

`default_nettype wire
