// sally_mem.sv — SALLY memory subsystem (v2a: DDR3 era).
//
// CPU's view of memory in tiered form:
//
//   $0000-$3FFF  Direct BRAM (zero page + stack + main RAM lo)
//   $4000-$5FFF  Screen RAM in BRAM (fixed, unbanked)
//   $6000-$9FFF  Code window (DDR3 banked via $D5C0, 16 KB pages)
//   $A000-$BFFF  BASIC window: BASIC ROM from BRAM (if PORTB[1]=0)
//                or RAM / DDR3 data window (if PORTB[1]=1)
//   $C000-$CFFF  OS ROM low:  OS ROM from BRAM (if PORTB[0]=1)
//                or RAM / DDR3 data window (if PORTB[0]=0)
//   $D000-$D7FF  Hardware-register page — combinational override of
//                BRAM.
//   $D800-$FFFF  OS ROM high: OS ROM from BRAM (if PORTB[0]=1)
//                or unbanked RAM (if PORTB[0]=0)
//
// PORTB ($D301) control — stock Atari XL/XE semantics (boot blocker #2).
// The stock OS drives these bits; matching them lets
// the OS's own PORTB writes keep the ROMs mapped:
//   bit 0: OS ROM enable, ACTIVE HIGH.  1 = OS ROM at $C000-$CFFF +
//          $D800-$FFFF visible; 0 = RAM there.
//   bit 1: BASIC ROM enable, ACTIVE LOW. 0 = BASIC ROM at $A000-$BFFF
//          visible; 1 = RAM there.
//   Reset value $FF => OS ROM on, BASIC off — the correct power-on state.
//   The OS coldstart clears bit 1 to map BASIC in when OPTION isn't held.
//
// Banking (bank_xlat):
//   - Code window $6000-$9FFF (16 KB pages selected by $D5C0)
//   - Data window $A000-$CFFF (12 KB pages selected by $D5C1)
//   - PORTB overrides the data window for ROM ranges
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
//   - There is no bank_cache on the banked-window AXI port; banked
//     accesses go straight to DDR3 over AXI.
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
    // by RAM accesses). The runtime rom-load chiplet path ($D49C-$F)
    // remains usable on top of this for live OS swaps.
    parameter string         OS_ROM_HEX_PATH    = "",
    parameter string         SELFTEST_HEX_PATH  = "",   // XL self-test ROM (2 KB)
    // Base byte-addresses in DDR3 for the banked windows.  Code and data
    // pages live in separate sub-regions so their page indices can't
    // collide.  Both use a 16 KB stride (data uses the low 12 KB of each
    // page); code is 256 pages (4 MB), data is up to 65536 pages.
    // Production builds set these from chiplet-ext registers; for synth
    // the constants give Vivado a real address to time against.
    parameter logic [31:0]   DDR3_BANKED_BASE   = 32'h2000_0000,  // code base
    parameter logic [31:0]   DDR3_DATA_BASE     = 32'h2040_0000,  // code base + 4 MB
    // Cache architecture for the banked-window AXI port.
    //   "LINE" = banked_axi_reader (single 64 B line, write-through).
    //   "PAGE" = banked_page_cache (full-page resident, write-back).
    // A/B comparison via this parameter before committing to the page cache.
    parameter string         BANKED_CACHE       = "PAGE",
    // xtc bank-select control registers, relocated OUT of zero page.  The
    // original $0082/$0083 collide with Atari BASIC's VNTP/VNTD, and $1C-$1F
    // are VBI/PBI scratch — any zero-page home conflicts with some software.
    // The CCTL I/O gap $D5C0-$D5DF is touched by no cart/OS and is NOT zeroed
    // at warm/coldstart (only $D0/$D2/$D3/$D4 are — see the ecosystem appendix
    // in docs/Zynq/register-map.md),
    // so the regs sit at reset until xtc software writes them.  Must be even
    // (two consecutive regs: BASE+0 = code bank, BASE+1 = data bank).  Both
    // are readable.  (The old $0084 atomic both-window switch is dropped until
    // the multitasking API stabilises; re-add at BASE+2 then.)
    parameter logic [15:0]   XTC_CTL_BASE       = 16'hD5C0
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

    // SALLY Stage A — 12-bit hidden-stack interface.
    //   stack_op asserts on push/pull cycles; the 12-bit stack-mem
    //   address is addr[11:0] (xt6502 outputs AB = {4'h0, s_high, S[7:0]}
    //   on those cycles).  Non-stack accesses to $0100-$01FF still go
    //   through the alias window in stack_mem's top 256 bytes.
    input  wire        stack_op,
    input  wire [3:0]  s_high,         // currently unused — addr[11:0] already
                                       // carries the full stack address from
                                       // the CPU.  Kept as a port for clarity
                                       // and future use (e.g., debug taps).

    // Hardware-register passthrough.
    output wire [15:0] hwreg_addr,
    output wire        hwreg_we,
    output wire [7:0]  hwreg_din,
    input  wire [7:0]  hwreg_dout,

    // CPU bank-select state — latched from $D5C0/$D5C1 writes (XTC_CTL_BASE).
    // Exposed for debug/observability (only used internally by bank_xlat).
    // ANTIC has no banking — it reads the flat 64 KB BRAM directly via the
    // dma port — so there is no ANTIC-view input here any more.
    output wire [7:0]  cpu_code_bank_q,    // $D5C0 (XTC_CTL_BASE+0)
    output wire [7:0]  cpu_data_bank_q,    // $D5C1 (XTC_CTL_BASE+1)

    // Banked screen RAM ($4000-$5FFF aperture) — screen_bank engine lives at the
    // top (clk_sys/AXI).  sally_mem decodes the regs: $D5C3 = CPU screen bank,
    // $D5C4 = ANTIC screen bank, $D5C5.0 = ready (read).  Strobes drive the
    // engine; scrn_ready is read back.  scrn_*_bank_q are the latched values
    // (for readback + the bank-0-vs-banked routing mux).
    output wire [7:0]  scrn_cpu_bank_q,    // $D5C3 (XTC_CTL_BASE+3)
    output wire [7:0]  scrn_antic_bank_q,  // $D5C4 (XTC_CTL_BASE+4)
    output wire        scrn_cpu_bank_we,   // 1-cycle strobe on a $D5C3 write
    output wire        scrn_antic_bank_we, // 1-cycle strobe on a $D5C4 write
    output wire [7:0]  scrn_bank_wval,     // data being written (shared)
    input  wire        scrn_ready,         // $D5C5.0 — CPU-BRAM holds the requested bank
    // CPU port to the screen_bank CPU-BRAM (clk_sally; only used when the CPU
    // screen bank is non-zero — bank 0 stays the flat 64 KB shadow).
    output wire [12:0] scrn_cpu_addr,      // byte address within the 8 KB aperture
    output wire        scrn_cpu_we,        // write enable (banked aperture write)
    output wire [7:0]  scrn_cpu_wdata,
    input  wire [7:0]  scrn_cpu_rdata,     // registered read (aligned with bram_dout_q)

    // Math-coprocessor page (math_cop engine at the top) — $D5C6/$D5C7/$D5C8.
    // $D5C6.0 (MAP) overlays the resident math page onto the CPU's view of the
    // $4000-$5FFF aperture: a register flip, no copy, and it wins over the
    // screen bank ($D5C3) without disturbing it.  ANTIC never sees the math
    // page.  The math page shares scrn_cpu_addr/scrn_cpu_wdata; only the write
    // enable and read-data legs are its own.
    output wire        math_map_q,         // $D5C6.0 latched (aperture overlay on)
    output wire [7:0]  math_chunk_q,       // $D5C8 latched (backing chunk index)
    output wire        math_exec_we,       // 1-cycle strobe on a $D5C7 write (doorbell)
    output wire        math_chunk_we,      // 1-cycle strobe on a $D5C8 write
    input  wire        math_done,          // $D5C7.0 — results reloaded into the page
    input  wire        math_busy,          // $D5C7.1 — engine flushing/filling
    input  wire        math_chunk_ready,   // $D5C7.2 — page holds the requested chunk
    output wire        math_cpu_we,        // aperture write -> math page
    input  wire [7:0]  math_cpu_rdata,     // registered read (aligned with bram_dout_q)

    // XT register-unlock: when 0 (locked / stock) the $D5C0/$D5C1 bank-select
    // writes are ignored, so a stock cart's own $D5xx CCTL bank-switching is
    // undisturbed.  See docs/Zynq/register-unlock.md (BANK group).
    input  wire        unlock_bank,

    // PORTB ($D301) from PIA — controls ROM vs banked/BRAM visibility.
    // Stock XL/XE: bit0 = OS ROM enable (active HIGH), bit1 = BASIC enable
    // (active LOW).  See the memory-map header.
    input  wire [7:0]  portb,

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
    output wire [7:0]   dma_rdata,
    // TEMP diag: A9-driven 6502-RAM peek. Registered read of the flat 64K image.
    input  wire [15:0]  peek_addr,
    output reg  [7:0]   peek_data
);

    // ---- Backing BRAM ($0000-$3FFF, $8000-$FFFF less hwreg page) ---
    // cascade_height=1: forbid Vivado from CASCADING the 64 KB (2-deep RAMB36)
    // read — the CASCADEOUTA hop is ~2.5 ns and sits on the clk_sally critical
    // path (BRAM read → SP-relative address → next BRAM read address, a single
    // CPU cycle).  Decomposing into parallel 32 KB banks + a high-address mux
    // keeps it ONE cycle (no added latency, no emulated-rate change) but trades
    // the 2.5 ns cascade prop for a ~0.1 ns mux.  Also sidesteps the cascade
    // ADDR15 / REQP-1962 quirk noted in the write-path comment below.
    (* ram_style = "block", cascade_height = 1 *)
    logic [7:0] mem [0:65535];

    // BRAM init from a baked-in OS image when OS_ROM_HEX_PATH is set.
    initial if (OS_ROM_HEX_PATH != "") $readmemh(OS_ROM_HEX_PATH, mem);

    // XL self-test ROM: 2 KB that the OS banks into $5000-$57FF by clearing
    // PORTB[7] (active-low select).  It lives at offset $1000-$17FF in the 16 KB
    // physical OS ROM — i.e. the address-map hole behind the $D000-$D7FF I/O
    // page — so the flat 64 K OS image never contains it; load it separately.
    // The no-cart/no-disk XL boot path JMPs here (the Memo Pad / self-test),
    // so without it the CPU runs screen-RAM garbage -> BRK -> stack-underflow
    // runaway.  (See tb_boot co-sim: golden runs real code at $50xx.)
    (* ram_style = "block" *)
    logic [7:0] selftest_rom [0:2047];
    initial if (SELFTEST_HEX_PATH != "") $readmemh(SELFTEST_HEX_PATH, selftest_rom);

    // ---- Hidden stack BRAM (4 KB, SALLY 6502 embellishment Stage A) ----
    // 4096 bytes of dedicated stack RAM that is NOT visible at any normal
    // 16-bit address.  Accesses to $0100-$01FF (the legacy 6502 stack
    // page) are redirected here to the TOP 256 bytes ($F00-$FFF), giving
    // a backward-compatible alias window for existing code that uses
    // TSX + LDA $0100,X style addressing.
    //
    // Stage A Increment 1 (this file): only the top 256 bytes are reachable
    // via the alias.  The CPU still uses an 8-bit SP, so the lower 3840
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
    wire is_mpd_window   = (addr[15:11] == 5'b11011);    // $D800-$DFFF
    wire is_cart_s4_window = (addr[15:13] == 3'b100);    // $8000-$9FFF
    wire is_cart_s5_window = (addr[15:13] == 3'b101);    // $A000-$BFFF
    wire is_stack_page     = (addr[15:8] == 8'h01);      // $0100-$01FF (legacy alias)
    wire is_selftest_range = (addr[15:11] == 5'b01010);  // $5000-$57FF
    wire selftest_en       = is_selftest_range && !portb[7];  // self-test ROM mapped (PORTB[7]=0)
    wire cart_external_read = rw                                // reads only
                            & ((is_cart_s4_window & ~bus_rd4_n_in)
                            |  (is_cart_s5_window & ~bus_rd5_n_in));

    // xtc bank-control register decode (XTC_CTL_BASE, $D5C0-$D5C1).  Aligned
    // 2-byte block: addr[0]=0 -> code bank, addr[0]=1 -> data bank.  Handled
    // entirely in sally_mem — a write snoops into the bank latch, a read
    // returns the latch — so it never goes through the ANTIC hwreg CDC.
    wire is_ctlreg = (addr[15:1] == XTC_CTL_BASE[15:1]);

    // ---- PORTB-based ROM override (stock Atari XL/XE semantics) ----
    // PORTB ($D301) bit 0: OS ROM enable, ACTIVE HIGH (1 = OS ROM visible)
    // PORTB ($D301) bit 1: BASIC ROM enable, ACTIVE LOW (0 = BASIC visible)
    wire basic_rom_range = is_cart_s5_window;                    // $A000-$BFFF
    wire os_rom_lo_range = (addr[15:12] == 4'b1100);             // $C000-$CFFF
    wire os_rom_hi_range = is_mpd_window;                        // $D800-$DFFF
    wire os_rom_top_range = (addr[15:12] == 4'b1110)            // $E000-$EFFF
                          | (addr[15:12] == 4'b1111);            // $F000-$FFFF

    wire basic_rom_en   = basic_rom_range && !portb[1];
    wire os_rom_en      = (os_rom_lo_range || os_rom_hi_range || os_rom_top_range) && portb[0];
    wire rom_override   = basic_rom_en || os_rom_en;

    // Stack BRAM addressing.
    //   - When `stack_op` is asserted (the CPU is in a push/pull cycle),
    //     the full 12-bit stack address is in addr[11:0] (the CPU outputs
    //     AB = { 4'h0, s_high, S[7:0] }).
    //   - When not a stack op but the address is in the legacy stack
    //     page $0100-$01FF, alias to the top 256 bytes of stack_mem.
    //   - Otherwise stack_mem is not addressed and the access goes to
    //     main mem.
    wire        is_stack_access = stack_op || is_stack_page;
    wire [11:0] stack_addr_rd   = stack_op ? addr[11:0]
                                           : {4'hF, addr[7:0]};

    // ---- CPU bank-select snoop -----------------------------------
    // Mirror CPU writes to the xtc control regs (XTC_CTL_BASE) into latched
    // registers so bank_xlat sees the live values:
    //   $D5C0 (BASE+0) = code-window page select ($6000-$9FFF).
    //   $D5C1 (BASE+1) = data-window page select ($A000-$CFFF — see bank_xlat).
    // Relocated out of zero page ($0082/$0083 = BASIC VNTP/VNTD).  These live
    // in the CCTL I/O gap, so a stray RAM write can never bank the windows.
    logic [7:0] cpu_code_bank, cpu_data_bank;

    // fmax + CDC: unlock_bank is a quasi-static clk_sys signal used here in the
    // clk_sally domain.  2-FF synchronise it (also gives a clean local register
    // instead of a long cross-die combinational route into the timing-marginal
    // SALLY pblock).  unlock_bank changes only on an unlock poke, so the sync
    // latency is irrelevant.
    (* ASYNC_REG = "TRUE" *) logic unlock_bank_s1;
    (* ASYNC_REG = "TRUE", keep = "true" *) logic unlock_bank_q;
    always_ff @(posedge clk) begin
        unlock_bank_s1 <= unlock_bank;
        unlock_bank_q  <= unlock_bank_s1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cpu_code_bank <= 8'h00;
            cpu_data_bank <= 8'h00;
        end else if (rdy && !rw && is_ctlreg && unlock_bank_q) begin
            if (!addr[0]) cpu_code_bank <= data_in;   // $D5C0 code bank
            else          cpu_data_bank <= data_in;   // $D5C1 data bank
        end
    end

    assign cpu_code_bank_q = cpu_code_bank;
    assign cpu_data_bank_q = cpu_data_bank;

    // ---- Banked screen RAM register decode ($D5C3/$D5C4/$D5C5) ----
    // Separate from is_ctlreg so a $D5C3/$D5C4 write never lands in the
    // code/data bank latch (which keys only on addr[0]).  Gated by the same
    // BANK unlock group.
    wire is_scrn_cpu   = (addr[15:0] == (XTC_CTL_BASE + 16'd3));   // $D5C3
    wire is_scrn_antic = (addr[15:0] == (XTC_CTL_BASE + 16'd4));   // $D5C4
    wire is_scrn_stat  = (addr[15:0] == (XTC_CTL_BASE + 16'd5));   // $D5C5
    wire is_scrn_reg   = is_scrn_cpu | is_scrn_antic | is_scrn_stat;

    assign scrn_cpu_bank_we   = rdy && !rw && is_scrn_cpu   && unlock_bank_q;
    assign scrn_antic_bank_we = rdy && !rw && is_scrn_antic && unlock_bank_q;
    assign scrn_bank_wval     = data_in;

    // ---- Math-coprocessor register decode ($D5C6/$D5C7/$D5C8) ----
    // Same CCTL-gap family and BANK unlock group as the screen-bank regs.
    wire is_math_ctl   = (addr[15:0] == (XTC_CTL_BASE + 16'd6));   // $D5C6
    wire is_math_exec  = (addr[15:0] == (XTC_CTL_BASE + 16'd7));   // $D5C7
    wire is_math_chunk = (addr[15:0] == (XTC_CTL_BASE + 16'd8));   // $D5C8
    wire is_math_lat   = (addr[15:4] == XTC_CTL_BASE[15:4])        // $D5C9-$D5CC: op-latency counter
                       && (addr[3:0] >= 4'd9) && (addr[3:0] <= 4'd12);
    wire is_math_reg   = is_math_ctl | is_math_exec | is_math_chunk | is_math_lat;

    assign math_exec_we  = rdy && !rw && is_math_exec  && unlock_bank_q;
    assign math_chunk_we = rdy && !rw && is_math_chunk && unlock_bank_q;

    logic       math_map;
    logic [7:0] math_chunk;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            math_map   <= 1'b0;
            math_chunk <= 8'h00;
        end else if (rdy && !rw && unlock_bank_q) begin
            if (is_math_ctl)   math_map   <= data_in[0];
            if (is_math_chunk) math_chunk <= data_in;
        end
    end
    assign math_map_q   = math_map;
    assign math_chunk_q = math_chunk;

    // ---- math-op latency counter (clk_sally = the 6502's own clock) ---------
    // Times the intrinsic round-trip the 6502 experiences: START on the $D5C7
    // EXEC write ("ring the doorbell"), STOP on the rising edge of math_done
    // ("answer ready").  math_done is masked low by the engine on EXEC, so we
    // wait to SEE it low (sawlow) before accepting the completion edge — never
    // latch a stale done left over from the previous op.  The 32-bit count is
    // readable at $D5C9-$D5CC (LE); at 100 MHz clk_sally, count/100 = microsec.
    // Static between ops, so the 4-byte 6502 read is coherent without a latch.
    logic [31:0] math_lat_run, math_lat_q;
    logic        math_lat_active, math_lat_sawlow, math_done_d;
    // The strobe is REGISTERED before it reaches this counter, on purpose: math_exec_we is
    // an address decode at the tail of the CPU read/EA cone (page-BRAM data -> cpu_rdata ->
    // effective address -> decode), and feeding it straight into math_lat_run's D made a
    // DIAGNOSTIC counter the worst path of the whole clk_sally domain (-0.091 gated a build,
    // 2026-07-15). One cycle late on a counter that measures thousands is noise; the doorbell
    // itself (math_exec_we out of this module) keeps its same-cycle timing.
    logic        math_exec_we_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            math_lat_run <= 32'd0; math_lat_q <= 32'd0;
            math_lat_active <= 1'b0; math_lat_sawlow <= 1'b0; math_done_d <= 1'b0;
            math_exec_we_q <= 1'b0;
        end else begin
            math_done_d <= math_done;
            math_exec_we_q <= math_exec_we;
            if (math_exec_we_q) begin               // doorbell (1 cycle late) -> start
                math_lat_run    <= 32'd0;
                math_lat_active <= 1'b1;
                math_lat_sawlow <= 1'b0;
            end else if (math_lat_active) begin
                math_lat_run <= math_lat_run + 32'd1;
                if (!math_done) math_lat_sawlow <= 1'b1;
                if (math_lat_sawlow && math_done && !math_done_d) begin
                    math_lat_q      <= math_lat_run; // answer ready -> latch cycles
                    math_lat_active <= 1'b0;
                end
            end
        end
    end

    logic [7:0] scrn_cpu_bank, scrn_antic_bank;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            scrn_cpu_bank   <= 8'h00;
            scrn_antic_bank <= 8'h00;
        end else begin
            if (scrn_cpu_bank_we)   scrn_cpu_bank   <= data_in;
            if (scrn_antic_bank_we) scrn_antic_bank <= data_in;
        end
    end
    assign scrn_cpu_bank_q   = scrn_cpu_bank;
    assign scrn_antic_bank_q = scrn_antic_bank;

    // ---- Screen aperture ($4000-$5FFF) CPU routing ----
    // Bank 0 = the flat 64 KB shadow (today's behaviour, boot unchanged).
    // Non-zero bank = the screen_bank CPU-BRAM: writes go to its CPU port (the
    // harmless shadow write also lands, like hwreg/bank — see mem_we), and reads
    // prefer scrn_cpu_rdata over bram_dout_q via the rare_dout path below.
    // math_map ($D5C6.0) overlays the math page on the CPU view and wins over
    // the screen bank; the screen CPU-BRAM keeps its chunk untouched underneath.
    wire is_scrn_aperture = (addr[15:13] == 3'b010);            // $4000-$5FFF
    wire math_mapped      = is_scrn_aperture && math_map;
    wire scrn_banked      = is_scrn_aperture && (scrn_cpu_bank != 8'h00) && !math_map;
    assign scrn_cpu_addr  = addr[12:0];
    assign scrn_cpu_we    = rdy && !rw && scrn_banked;
    assign scrn_cpu_wdata = data_in;
    assign math_cpu_we    = rdy && !rw && math_mapped;

    // ---- Bank translator -----------------------------------------
    wire [15:0] bank_id_w;
    wire [13:0] offset_in_block_w;
    wire        is_in_window_w;        // 1 if addr ∈ $6000-$CFFF
    wire        is_code_w;             // 1 = code window, 0 = data window

    bank_xlat u_xlat (
        .cpu_code_bank      (cpu_code_bank),
        .cpu_data_bank      (cpu_data_bank),
        .cpu_addr           (addr),
        .is_in_window       (is_in_window_w),
        .is_code            (is_code_w),
        .offset_in_block    (offset_in_block_w),
        .bank_id            (bank_id_w)
    );

    // ---- Banked-window AXI port ----------------------------------
    // Address composition (placeholder): code and data pages sit in
    // separate DDR3 sub-regions with a 16 KB stride, so the byte address
    // is  base + page*16K + offset  =  base + {bank_id, offset[13:0]}.
    // is_code_w selects the base (code vs data) so their page indices
    // never collide.  Production builds replace the constant bases with
    // chiplet-ext register reads.
    //
    // v2c: banked_axi_reader handles both reads (with 1-line prefetch)
    // and writes (single-beat write-through, line invalidated on
    // matching write). req_valid is level-sensitive (held high while
    // SALLY presents any banked-window access); req_we selects the
    // direction. req_ready is combinational on read-hit / pulses on
    // read-burst-complete / pulses on write-B-response.
    wire [31:0] axi_req_addr = (is_code_w ? DDR3_BANKED_BASE : DDR3_DATA_BASE)
                             + {2'b00, bank_id_w[15:0], offset_in_block_w[13:0]};
    wire        bank_access_w = is_in_window_w && !rom_override;
    wire        bank_req_live = bank_access_w && rdy;
    // PERSIST the banked request + busy across the fill.  The xt6502 core advances
    // off the address one cycle after presenting it (busy_n is registered in
    // sally_clock), so bank_req_live drops — and busy with it — before the
    // multi-cycle fill completes; the CPU would then consume a half-filled line.
    // bank_inflight_q holds req_valid/busy asserted until axi_ready_w (the page
    // cache already latches the address internally, and axi_rdata_q is
    // ready-latched).  Same hazard + fix shape as hwreg_rd_cdc's armed-persist.
    logic       bank_inflight_q;
    wire        axi_req_valid = bank_req_live | bank_inflight_q;
    wire        axi_req_we    = !rw;     // SALLY rw: 1=read, 0=write
    wire [7:0]  axi_rdata_w;
    wire        axi_ready_w;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                bank_inflight_q <= 1'b0;
        else if (axi_ready_w)   bank_inflight_q <= 1'b0;   // served
        else if (bank_req_live) bank_inflight_q <= 1'b1;   // in flight, hold across stall
    end

    generate
        if (BANKED_CACHE == "LINE") begin : g_line_cache
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
        end else begin : g_page_cache
            banked_page_cache #(
                .AXI_ADDR_W (32)
            ) u_page_cache (
                .clk           (clk),
                .rst           (rst),
                .req_addr      (axi_req_addr),
                .req_valid     (axi_req_valid),
                .req_we        (axi_req_we),
                .req_wdata     (data_in),
                .req_rdata     (axi_rdata_w),
                .req_ready     (axi_ready_w),
                .bank_id       (bank_id_w),
                .is_code       (is_code_w),
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
        end
    endgenerate

    // ---- Overlay read wait-state (clk_sally timing study, 2026-07-17) ------
    // The $4000-$5FFF overlays (math page / screen bank) used to feed cpu_rdata
    // from their BRAM output registers LIVE — a late arrival whose decode-gated
    // tail family (EA cone, diag counters, reader CEs) kept ambushing clk_sally
    // closure (+0.000 last build).  Now their data is served from ovl_dout_qq —
    // one more FF — and the CPU is stalled EXACTLY one cycle per overlay read at
    // turbo through the existing busy line (registered in sally_clock, the
    // hwreg-CDC idiom).  `rdy &&` makes the stall self-limiting: only the cycle
    // the CPU actually presents the address asserts it, so back-to-back overlay
    // reads pace correctly, and at CLOCK_MULT < BASE_DIV the inter-step gap
    // absorbs the latency and busy_n_q has recovered by the next step — the
    // wait-state costs NOTHING below full turbo.
    wire ovl_rd_stall = rdy && rw && (math_mapped || scrn_banked);

    // SALLY stalls while the reader can't serve the current request, and for
    // the one-cycle overlay-read wait-state.
    assign busy = (axi_req_valid && !axi_ready_w) || ovl_rd_stall;

    // Latch the AXI-returned byte for the output mux. Latched on the
    // cycle ready fires (hit or burst-complete), aligned with the
    // bram_dout_q / was_bank_q latches for N+1 mux consumption.
    logic [7:0] axi_rdata_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)              axi_rdata_q <= 8'h00;
        else if (axi_ready_w) begin
            axi_rdata_q <= axi_rdata_w;
`ifndef SYNTHESIS
            $display("[sally_mem] latch axi_rdata_q=%02h (from ready=%d we=%d)",
                axi_rdata_w, axi_ready_w, axi_req_we);
`endif
        end
    end

    // ---- Read pipeline + path-tracking flops ----------------------
    logic [7:0] bram_dout_q;
    logic [7:0] selftest_dout_q;   // $5000-$57FF self-test ROM read (PORTB[7]=0)
    logic       was_selftest_q;
    logic [7:0] stack_dout_q;         // from stack_mem read port
    logic [7:0] hwreg_dout_q;
    logic       was_hwreg_q;
    logic       was_bank_q;
    logic       was_rom_override_q;   // prev addr was ROM-overridden (PORTB)
    logic       was_stack_q;          // prev addr was stack-page ($0100-$01FF)
    logic       was_mpd_window_q;     // M-PBI step 2: was the prev addr in $D800-$DFFF
    logic       was_cart_external_q;  // M-PBI #2: prev addr was cart-window AND RD asserted
    logic [7:0] ctlreg_dout_q;        // xtc bank-control read-back ($D5C0/$D5C1)
    logic       was_ctlreg_q;         // prev addr was an xtc control reg
    logic       was_scrn_q;           // prev addr was a banked screen-aperture read
    logic       was_math_q;           // prev addr was a math-page aperture read

    // Main BRAM write port: clk-only (no reset), single write-enable +
    // address + data mux. Vivado BRAM inference requires this shape.
    // ROM-load wins on the rare same-cycle collision with a CPU write —
    // matches the original Verilog last-assignment-wins ordering.
    //
    // Only one exclusion from cpu_w: !stack_op.  When the CPU is doing a
    // stack push (stack_op=1), the 12-bit address could land anywhere
    // in $0000-$0FFF.  Shadowing those writes into main mem would
    // corrupt zero page or low RAM, so gate them out and let stack_mem
    // hold the data.
    //
    // is_hwreg_page / is_in_window_w deliberately are NOT gated — they
    // are address-derived and cause DRC REQP-1962 on the 64 KB BRAM
    // cascade (Vivado optimises the ADDR15 pin inconsistently between
    // cascaded BRAM pairs once enough address-bit logic sits in the
    // WE path).  The Stage C v0.28 RTL pushed the synthesiser past
    // the threshold that v0.27 sat under.  Removing the addr-derived
    // gates puts the cascade back together; shadow writes into hwreg
    // / bank-window addresses are harmless because the read path
    // already prefers was_hwreg_q / was_bank_q over bram_dout_q.
    wire        cpu_w      = rdy && !rw && !stack_op && !rom_override;
    wire        mem_we     = cpu_w || rom_we;
    wire [15:0] mem_addr_w = rom_we ? rom_addr : addr;
    wire  [7:0] mem_din_w  = rom_we ? rom_data : data_in;

    // Single CPU read/write port (defrag, 2026-05-22).  The CPU does at
    // most one bus op per cycle (read OR write), so the write and the
    // registered read share ONE BRAM port, both addressed by mem_addr_w
    // (= rom_we ? rom_addr : addr).  Combined with the ANTIC DMA read on
    // port B, `mem` infers as a clean true-dual-port array → ~16 RAMB36
    // instead of the ~48 the previous structure forced (CPU write @
    // cpu_addr_q, CPU read @ addr, DMA read @ dma_addr = 3 address
    // streams → Vivado replicated the whole 64 KB array ~3×).
    //
    // The write is no longer pipelined.  The earlier 1-cycle write delay
    // existed only to register the BRAM-read → CPU → BRAM-write-address
    // critical path off the CPU output, but it was exactly what forced
    // read-addr ≠ write-addr in the same cycle (the replication trigger).
    // Un-pipelining writes at the current addr also removes the
    // clock_mult=1 read-after-write hazard the pipeline introduced.
    always_ff @(posedge clk) begin
        if (mem_we) mem[mem_addr_w] <= mem_din_w;
    end

    // TEMP diag: A9 peek — a separate registered read port into the flat 64K image.
    always_ff @(posedge clk) peek_data <= mem[peek_addr];

    // ---- Stack BRAM write port (separate array; reads prefer this) ----
    // Three write paths land in stack_mem:
    //   - CPU stack op (stack_op=1):  full 12-bit addr → stack_mem[addr[11:0]]
    //   - CPU legacy $0100-$01FF write: alias to top 256 bytes
    //   - ROM-load write into $0100-$01FF: same alias
    // The first path is the new Stage A Increment 2 feature; the latter
    // two are the legacy alias from Increment 1.
    wire        stack_cpu_w  = rdy && !rw && (stack_op || is_stack_page);
    wire        rom_is_stack = (rom_addr[15:8] == 8'h01);
    wire        stack_we     = stack_cpu_w || (rom_we && rom_is_stack);
    wire [11:0] stack_addr_w = rom_we    ? {4'hF, rom_addr[7:0]} :
                               stack_op  ? addr[11:0]            :
                                           {4'hF, addr[7:0]};
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

    // hwreg read result, registered LOCALLY and FREE-RUNNING (not rdy-gated).
    // `hwreg_dout` is a combinational signal sourced FAR from sally_mem (the
    // ANTIC read-CDC and, on the full build, the blitter STATUS via the right
    // clock-region) — feeding it straight into the cpu_rdata mux dragged the
    // CPU's read cone across the die and blew the clk_sally di->P path from
    // 9 to 46 LUT levels.  Every CDC-served hwreg read STALLS the CPU (rd_busy),
    // and busy_n is registered one cycle in sally_clock, so the CPU samples
    // cpu_rdata exactly one cycle after rd_data goes valid — which is precisely
    // what this 1-cycle local register presents.  Free-running (every cycle),
    // NOT the old rdy-gated latch that skipped the stall cycles and read stale
    // (XL OS saw PORTB=$00 -> wrote $02 -> OS ROM off).  Blitter STATUS reads
    // (XL-OS-irrelevant, XT-only, poll-tolerant) take a harmless 1-cycle lag.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) hwreg_dout_q <= 8'h00;
        else     hwreg_dout_q <= hwreg_dout;
    end

    // Read pipeline + path-tracking flops. Async reset kept here, but
    // away from the mem array so Vivado can still infer BRAM above.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bram_dout_q          <= 8'h00;
            stack_dout_q         <= 8'h00;
            was_hwreg_q          <= 1'b0;
            was_bank_q           <= 1'b0;
            was_stack_q          <= 1'b0;
            was_mpd_window_q     <= 1'b0;
            was_cart_external_q  <= 1'b0;
            was_rom_override_q   <= 1'b0;
            selftest_dout_q      <= 8'h00;
            was_selftest_q       <= 1'b0;
            ctlreg_dout_q        <= 8'h00;
            was_ctlreg_q         <= 1'b0;
            was_scrn_q           <= 1'b0;
            was_math_q           <= 1'b0;
        end else if (rdy) begin
            bram_dout_q          <= mem[mem_addr_w];
            stack_dout_q         <= stack_mem[stack_addr_rd];
            selftest_dout_q      <= selftest_rom[addr[10:0]];
            // xtc control-reg read-back (served through the one ctlreg slot):
            //   $D5C0/$D5C1 = code/data bank; $D5C3/$D5C4 = screen banks;
            //   $D5C5 = {7'b0, ready}; $D5C6 = {7'b0, map};
            //   $D5C7 = {5'b0, chunk_ready, busy, done}; $D5C8 = math chunk.
            //   addr[3:0] selects within $D5C0-$D5CF.
            case (addr[3:0])
                4'd0:    ctlreg_dout_q <= cpu_code_bank;
                4'd1:    ctlreg_dout_q <= cpu_data_bank;
                4'd3:    ctlreg_dout_q <= scrn_cpu_bank;
                4'd4:    ctlreg_dout_q <= scrn_antic_bank;
                4'd5:    ctlreg_dout_q <= {7'b0, scrn_ready};
                4'd6:    ctlreg_dout_q <= {7'b0, math_map};
                4'd7:    ctlreg_dout_q <= {5'b0, math_chunk_ready, math_busy, math_done};
                4'd8:    ctlreg_dout_q <= math_chunk;
                4'd9:    ctlreg_dout_q <= math_lat_q[7:0];    // op-latency cycles, LE ($D5C9-$D5CC)
                4'hA:    ctlreg_dout_q <= math_lat_q[15:8];
                4'hB:    ctlreg_dout_q <= math_lat_q[23:16];
                4'hC:    ctlreg_dout_q <= math_lat_q[31:24];
                default: ctlreg_dout_q <= 8'h00;
            endcase
            // Locked (BANK group off) → don't shadow these; the read falls
            // through to the CCTL/cart path (open bus) like stock silicon.
            was_ctlreg_q         <= (is_ctlreg | is_scrn_reg | is_math_reg) && unlock_bank_q;
            was_scrn_q           <= scrn_banked;
            was_math_q           <= math_mapped;
            was_hwreg_q          <= is_hwreg_page;
            was_bank_q           <= is_in_window_w;
            was_stack_q          <= is_stack_access;
            was_mpd_window_q     <= is_mpd_window;
            was_cart_external_q  <= cart_external_read;
            was_rom_override_q   <= rom_override;
            was_selftest_q       <= selftest_en;
`ifndef SYNTHESIS
            if (is_in_window_w) begin
                $display("[sally_mem] rdy: was_bank_q <= 1 (addr=%04h)", addr);
            end
`endif
        end
    end

    // ---- Output mux ------------------------------------------------
    // Priorities, top to bottom:
    //   1. was_selftest_q           -> selftest_dout_q (XL self-test ROM)
    //   2. was_ctlreg_q             -> ctlreg_dout_q   ($D5C0/$D5C1 bank regs)
    //   3. was_hwreg_q              -> hwreg_dout_q    (ANTIC-side regs via CDC,
    //                                                   locally registered)
    //   4. was_cart_external_q      -> bus_pbi_rdata   (physical cart wins)
    //   5. was_mpd_window_q & /MPD  -> bus_pbi_rdata   (PBI replaces FP ROM)
    //   6. was_rom_override_q       -> bram_dout_q     (PORTB-based ROM override)
    //   7. was_bank_q               -> axi_rdata_q     (DDR3-backed bank)
    //   8. was_stack_q              -> stack_dout_q    (hidden stack alias)
    //   9. default                  -> bram_dout_q
    wire mpd_active = ~bus_mpd_n_in;
    // Common-case-fast factoring, with the LATE BRAM-class sources split out from
    // the rare cascade (clk_sally timing study, docs/Design/clk-sally-timing-study.md).
    // Three sources arrive LATE (~2.1 ns BRAM clk-to-out): bram_dout_q (default
    // RAM), and the two $4000-$5FFF overlays math_cpu_rdata / scrn_cpu_rdata
    // ("registered read, aligned with bram_dout_q").  The overlays USED to sit
    // mid-way down the deep rare_dout priority cascade — so a screen-bank read =
    // latest arrival + deepest logic, the binding 10.066 ns clk_sally path.
    //
    // Fix: resolve the three late sources in one 3-way TAIL instead.  The overlays
    // are ADDRESS-DISJOINT ($4000-$5FFF) from every early source EXCEPT the
    // self-test ROM ($5000-$57FF, which OUTRANKS them and stays in rare_dout via
    // use_early), so `use_early ? rare_dout : overlay_active ? overlay_dout :
    // bram_dout_q` is priority-EQUIVALENT to the old cascade (selftest > ctlreg >
    // math > scrn > hwreg > cart > mpd > rom_override > bank > stack > default).
    // The 3:1 (2 selects, ≤5 inputs/bit) fits one LUT6/bit: bram_dout_q KEEPS its
    // single-level depth (common path untouched) while the overlays drop from ~4
    // mux levels to 2 (their own 2:1 + the tail).  rom_override/default both land
    // on bram_dout_q; the (~was_rom_override_q & (bank|stack)) term preserves
    // rom_override outranking bank/stack.  hwreg uses the LOCAL hwreg_dout_q flop
    // (far ANTIC-CDC source decoupled), valid exactly when the CPU samples it.
    wire use_early = was_selftest_q | was_ctlreg_q | was_hwreg_q
                   | was_cart_external_q
                   | (was_mpd_window_q & mpd_active)
                   | (~was_rom_override_q & (was_bank_q | was_stack_q));
    wire [7:0] rare_dout = was_selftest_q             ? selftest_dout_q
                         : was_ctlreg_q               ? ctlreg_dout_q
                         : was_hwreg_q                ? hwreg_dout_q
                         : was_cart_external_q        ? bus_pbi_rdata
                         : (was_mpd_window_q & mpd_active) ? bus_pbi_rdata
                         : was_bank_q                 ? axi_rdata_q
                         :                              stack_dout_q;  // was_stack_q
    // Late overlay group ($4000-$5FFF): math and scrn are mutually exclusive
    // (scrn_banked carries !math_map), so a plain 2:1 with the early-latched select.
    wire       overlay_active = was_math_q | was_scrn_q;
    wire [7:0] overlay_dout   = was_math_q ? math_cpu_rdata : scrn_cpu_rdata;
    // The wait-state's serving register (see ovl_rd_stall above): free-running,
    // so it captures the (rdy-held) overlay data during the stall cycle and the
    // CPU consumes a pure FF on the rdy cycle after — the late BRAM arrivals
    // leave the cpu_rdata cone entirely.  Free-running is safe for the same
    // reason hwreg_dout_q is: the stall guarantees the consume cycle samples
    // one cycle after the data went valid.
    logic [7:0] ovl_dout_qq;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) ovl_dout_qq <= 8'h00;
        else     ovl_dout_qq <= overlay_dout;
    end
    // Cap fanout so the read-data driver replicates near the ~140 CPU loads
    // (the cpu_din net was ~0.9 ns of route at fo=141 on the critical path).
    (* max_fanout = 24 *) wire [7:0] cpu_rdata = use_early      ? rare_dout
                                               : overlay_active ? ovl_dout_qq
                                               : bram_dout_q;
    assign data_out = cpu_rdata;

    // ---- Hardware-register write passthrough ----------------------
    // rdy-gated so each write commits exactly once per CPU step (mirrors the
    // BRAM write cpu_w above).  Without the rdy gate, hwreg_we is a LEVEL held
    // for every cycle the CPU presents the write — so while the CPU is stalled
    // (e.g. on a WSYNC write that ANTIC is holding via rdy_n), the same write is
    // re-pushed into the CDC FIFO every clk_sally cycle.  That both floods the
    // FIFO and, for WSYNC ($D40A), perpetually re-arms ANTIC's wait flag so it
    // never releases the CPU → deadlock.  One write = one push.
    // Exclude the xtc control regs ($D5C0/$D5C1) when the BANK group is unlocked:
    // the snoop above latches them locally, so don't burn a CDC slot.  When
    // LOCKED, fall through to the normal hwreg forward so the write reaches the
    // CCTL/cart path exactly like a stock $D5xx bank-switch write.
    assign hwreg_we   = rdy && !rw && is_hwreg_page && !(is_ctlreg && unlock_bank_q);
    assign hwreg_din  = data_in;
    assign hwreg_addr = addr;

endmodule

`default_nettype wire
