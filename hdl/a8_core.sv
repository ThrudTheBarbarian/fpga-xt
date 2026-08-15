`default_nettype none
//
// a8_core — the CPU and the display chips, joined.
//
// docs/ANTIC-rewrite.md.  xt6502f plus antic_gtia, with the two things that
// actually connect them: the register decode and the cycle stealing.
//
// TWO MEMORY PORTS, NOT AN ARBITER — AND THAT IS WRONG.  The reasoning below is
// kept because it is nearly right, and because knowing WHY it fails is the
// point:
//
//   "ANTIC and the CPU each get their own read path, because on the FPGA the
//    memory is dual-ported and there is no bus to contend for.  The CPU still
//    loses the cycles — `dma_steal` gates its clock enable — so the TIMING is
//    the real machine's even though the physical conflict the real machine has
//    does not exist here.  That is the right trade: the timing is what software
//    can observe, and the contention is not."
//
// The last clause is false, and the software model names the counter-example.
// GTIA's phantom P/M latch captures WHATEVER VALUE IS ON THE DATA BUS at fixed
// scanline slots, whether or not ANTIC fetched anything there.  gtia_phantomdma
// sets DMACTL=$21 so ANTIC does no P/M DMA at all, and the byte it requires in
// GRAFP0 is $AD — the opcode fetch of the test's own `lda $0100`.  Nothing ANTIC
// touches on that line ends in $D.
//
// So the bus VALUE is a third-party observable, not an internal detail, and two
// independent read ports cannot reproduce it: ANTIC never sees the CPU's fetch.
// The bus must be SINGLE and ARBITRATED with ANTIC as master, and the value on
// it exported to GTIA.  See emu/system.c bus_note()/phantom_latch(), which is
// the model that passes gtia_phantomdma.
//
// RDY AND HALT ARE DIFFERENT SIGNALS AND ARE COMPOSED DIFFERENTLY.  This is the
// whole reason Atari built SALLY instead of using a stock 6502:
//
//   WSYNC -> RDY    standard 6502 behaviour, and a WRITE CANNOT BE STALLED.
//                   The CPU is driving the bus during a write and cannot let
//                   go, so the write completes and the stall begins after it.
//
//   DMA   -> HALT   Atari's addition, and it is UNCONDITIONAL.  A stock 6502's
//                   RDY cannot stop a write, so ANTIC could never be sure of
//                   getting the cycle it needs; SALLY's HALT can, which is what
//                   makes a fixed DMA schedule possible at all.
//
// Getting these the same way round is a silent-corruption bug: make HALT
// write-immune and ANTIC misses fetches only when the CPU happens to be
// storing, which is data-dependent and would look like random display glitches.
//
// THE DELAY SLOTS DIFFER TOO, and for the same reason.  /RDY trails the WSYNC
// latch by a machine cycle because the latch is inside ANTIC (see
// antic_reg_file); `dma_steal` applies in the cycle it names, because that is
// ANTIC taking the bus now rather than a request propagating.
//
// rdy IS A LEVEL HERE, NOT A PULSE, and that distinction is per-core.  The turbo
// core takes rdy as its clock enable and needs a pulse; the fid core paces
// itself from phi2_tick and samples rdy as a level at its commit slot, so
// ANDing phi2_tick into it stalls the machine permanently — it never reaches a
// commit with rdy high and sits on the reset vector for ever.
//
// The memory write is strobed at SUB_DATA (N-7 subcycles into the window),
// which is where the fid core presents write data.  Strobing on the level
// instead would write every fabric clock of the cycle.
//
`timescale 1ns/1ps

module a8_core #(
    // Stage-1 switch for the from-scratch ANTIC.  0 = the existing antic_gtia
    // path, byte-identical to before; 1 = antic2 drives the ANTIC side (regs,
    // NMI, WSYNC, refresh steal, beam) while antic_gtia continues to answer
    // $D0xx.  A SWITCH rather than a replacement because the baseline is the
    // regression floor and must stay runnable on demand.
    parameter bit USE_ANTIC2 = 1'b0,
    parameter int unsigned CLK_HZ  = 100_000_000,
    parameter int unsigned PHI2_HZ = 1_785_714
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cold,

    input  wire        tick,            // phi2, one machine cycle
    input  wire        px_tick,         // one hi-res pixel

    // Timing tune, straight through to antic_gtia (GP0 CTRL_RWTUNE on HW).
    // tune = 0 is exactly the parameter defaults.  Exposed as a PORT because
    // antic_wsync cannot see the absolute WSYNC release cycle (see 124e88e) --
    // antic_vcount can, and sweeping tune[11:8] against it is the only way to
    // measure that axis.  SystemVerilog has no default values on module input
    // ports, so every instantiation must drive this.
    input  wire [15:0] tune,

    // ---- CPU memory port -------------------------------------------------
    output wire [15:0] cpu_addr,
    output wire [7:0]  cpu_wdata,
    output wire        cpu_we,
    input  wire [7:0]  cpu_rdata,       // memory only; registers are muxed here

    // ---- XL ROM banking --------------------------------------------------
    // The decode lives here (PORTB is ours); the ROM bytes live with the
    // RAM owner.  rom_hit means the CURRENT cpu_addr falls in an enabled
    // ROM window: serve rom_addr from the 24K combined image (OS 16K at 0,
    // BASIC 8K at 16K) instead of RAM, and BLOCK the write -- the RAM
    // underneath keeps its contents.
    output wire        rom_hit,
    output wire [14:0] rom_addr,

    // ---- ANTIC's own read port -------------------------------------------
    output wire [15:0] antic_addr,
    input  wire [7:0]  antic_rdata,

    // ---- interrupts ------------------------------------------------------
    input  wire        irq_n,

    // ---- console and controllers -----------------------------------------
    input  wire [7:0]  trig0, trig1, trig2, trig3,
    input  wire [7:0]  pal_sense,
    input  wire [7:0]  consol_keys,

    // ---- the scanline out ------------------------------------------------
    output wire        lb_wr,
    output wire [7:0]  lb_color,
    output wire        lb_line_start,

    // ---- observability ---------------------------------------------------
    output wire        dma_steal,
    output wire        rdy_n,
    output wire        nmi_n,
    output wire        sync,
    output wire [15:0] dbg_pc,
    output wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p,
    output wire [6:0]  hcount,
    output wire [8:0]  line
);

    // ---- the CPU ----------------------------------------------------------
    wire [6:0]  gt_hcount;      // antic_gtia's beam, used when USE_ANTIC2=0
    wire [8:0]  gt_line;
    wire [15:0] gt_antic_addr;
    wire [7:0]  a2_rdata;
    wire        a2_nmi;          // POSITIVE one-cycle PULSE
    wire        a2_wsync_take;
    wire        a2_dma_steal;
    wire [15:0] a2_mem_addr;
    wire        a2_mem_req;
    wire [6:0]  a2_hcount;
    wire [8:0]  a2_line;
    // antic2's pixel stream and the gap filler's answer to it.
    wire        a2_px_wr, a2_px_hires, a2_px_in_window;
    wire [2:0]  a2_px_pf_src;
    wire [1:0]  a2_px_val;
    wire [8:0]  a2_px_pos;
    wire        a2_px_line_start, a2_px_active, a2_px_collide;
    wire        a2_pm_we;
    wire [2:0]  a2_pm_obj;
    wire [7:0]  a2_pm_data;
    wire        a2_pm_fetch;
    wire [7:0]  a2_gtia_rdata;
    wire [6:0]  a2_px_hcount;
    wire [3:0]  a2_px_mode;
    wire        a2_lb_wr, a2_lb_line_start;
    wire [7:0]  a2_lb_color;
    wire        gt_lb_wr, gt_lb_line_start;
    wire [7:0]  gt_lb_color;
    wire        nmi_n_eff;
    wire [15:0] c_addr;
    wire [7:0]  c_dout;
    wire        c_rw;                    // 1 = read, 0 = write
    logic [7:0] c_din;
    wire        c_rdy;
    wire [7:0]  c_sub;                   // the core's subcycle position

    localparam int unsigned N        = CLK_HZ / PHI2_HZ;
    localparam int unsigned SUB_DATA = N - 7;

    assign cpu_addr  = c_addr;
    assign cpu_wdata = c_dout;
    assign cpu_we    = !c_rw && c_rdy && (c_sub == 8'(SUB_DATA));

    // $D000-$D0FF is GTIA, $D200-$D2FF is POKEY, $D300-$D3FF is the PIA,
    // $D400-$D4FF is ANTIC.
    wire cs_gtia  = (c_addr[15:8] == 8'hD0);
    wire cs_pokey = (c_addr[15:8] == 8'hD2);
    wire cs_pia   = (c_addr[15:8] == 8'hD3);
    wire cs_antic = (c_addr[15:8] == 8'hD4);

    // ---- XL ROM banking (PIA PORTB, mmu_xlbanking) -------------------------
    // PORTB bit 0 enables the OS ROM at $C000-$FFFF (the $D000-$D7FF I/O
    // window always wins), bit 1 LOW banks BASIC in at $A000-$BFFF, and bit 7
    // LOW maps the self-test window $5000-$57FF -- which is the OS image's
    // own $D000-$D7FF slice, and only exists while the OS is enabled too.
    // Plain 64K XL: bits 2-6 do nothing (no extended banking), which is a
    // configuration mmu_xlbanking's extbank section detects and accepts.
    // The banking source is the PORTB OUTPUT LATCH (portb_out_q), the same
    // convention bank_translator uses; the test drives DDR to $FF first.
    // The harness boots OS-LESS: its vector/stub page lives at $FF00-$FFFF in
    // RAM, and the PIA latch resets to $FF -- which on a real XL means "OS
    // in".  Serving ROM from reset would shadow the stub (including the reset
    // vector itself).  On real hardware the OS owns PORTB from the first
    // instruction; here the first latch CHANGE since reset stands in for that
    // ownership, and banking stays quiet until a test (or future OS) takes it.
    wire [7:0] portb_bank;
    logic [7:0] portb_bank_d;
    logic       bank_armed_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bank_armed_q <= 1'b0;
            portb_bank_d <= 8'hFF;
        end else begin
            portb_bank_d <= portb_bank;
            if (portb_bank != portb_bank_d) bank_armed_q <= 1'b1;
        end
    end
    wire os_en    = portb_bank[0];
    wire basic_en = ~portb_bank[1];
    wire st_en    = ~portb_bank[7] & portb_bank[0];
    wire io_page  = (c_addr[15:11] == 5'b1101_0);            // $D000-$D7FF
    wire os_hit    = os_en    && (c_addr[15:14] == 2'b11) && !io_page;
    wire basic_hit = basic_en && (c_addr[15:13] == 3'b101);  // $A000-$BFFF
    wire st_hit    = st_en    && (c_addr[15:11] == 5'b0101_0); // $5000-$57FF
    assign rom_hit  = bank_armed_q & (os_hit | basic_hit | st_hit);
    assign rom_addr = os_hit    ? {1'b0,    c_addr[13:0]}      // OS at 0
                    : basic_hit ? {2'b10,   c_addr[12:0]}      // BASIC at 16K
                    :             {4'b0001, c_addr[10:0]};     // OS $1000 slice
    wire [7:0] reg_rdata;
    wire [7:0] pokey_rdata;
    wire       pokey_irq_n;
    wire [7:0] pia_rdata;
    wire       pia_irq_n;

    always_comb begin
        if      (USE_ANTIC2 && cs_antic) c_din = a2_rdata;
        // $D0xx is the gap filler's under USE_ANTIC2, not the legacy monolith's.
        // The collision latches the ACID tests read live in whichever register
        // file the live raster path feeds, and with antic2 driving the pixels
        // that is this one.
        else if (USE_ANTIC2 && cs_gtia)  c_din = a2_gtia_rdata;
        else if (cs_gtia || cs_antic)    c_din = reg_rdata;
        else if (cs_pokey)               c_din = pokey_rdata;
        else if (cs_pia)                 c_din = pia_rdata;
        else                             c_din = cpu_rdata;
    end

    xt6502f u_cpu (
        .clk(clk), .rst(rst), .phi2_tick(tick),
        .addr(c_addr), .data_in(c_din), .data_out(c_dout), .rw(c_rw),
        .rdy(c_rdy),
        .irq_n(irq_n && pokey_irq_n && pia_irq_n), .nmi_n(nmi_n_eff),
        .sync(sync), .dbg_pc(dbg_pc),
        .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p),
        .dbg_sub(c_sub), .dbg_ir(),
        .dbg_load(1'b0), .dbg_pc_in(16'h0000)
    );

    // ---- the display chips -------------------------------------------------
    antic_gtia u_video (
        .tune(tune),
        .clk(clk), .rst(rst), .cold(cold),
        .tick(tick), .px_tick(px_tick),
        .cs_antic(cs_antic), .cs_gtia(cs_gtia),
        .addr(c_addr[7:0]), .we(cpu_we), .wdata(c_dout), .rdata(reg_rdata),
        .rdy_n(rdy_n), .nmi_n(nmi_n), .dma_steal(dma_steal),
        .mem_addr(gt_antic_addr), .mem_data(antic_rdata),
        .trig0(trig0), .trig1(trig1), .trig2(trig2), .trig3(trig3),
        .pal_sense(pal_sense), .consol_keys(consol_keys),
        .lb_wr(gt_lb_wr), .lb_color(gt_lb_color),
        .lb_line_start(gt_lb_line_start),
        .hcount(gt_hcount), .line(gt_line), .vcount(), .line_start(), .dlpc()
    );


    // ---- antic2 (stage 1) ---------------------------------------------------

    // The ANTIC memory port answers one clock after the address is presented
    // (tb_acid and the fabric both register it), so `valid` is the request
    // delayed by one.  Modelling it as combinational would let the DL executor
    // latch the PREVIOUS byte.
    logic a2_mem_valid;
    always_ff @(posedge clk or posedge rst)
        if (rst) a2_mem_valid <= 1'b0;
        else     a2_mem_valid <= a2_mem_req;

    // WHAT WAS LAST ON THE DATA BUS, whoever drove it.  emu keeps the same
    // thing in system.c's bus_note and calls it last_bus; ANTIC's virtual
    // playfield slot latches it instead of fetching, and the phantom P/M latch
    // will want it too.
    //
    // Sampled at the CPU's DATA PHASE, which is SUB_DATA -- earlier in the
    // machine cycle than the tick ANTIC's fetches ride on.  That ordering is
    // the point: emu runs its latch after the access, because at tick time the
    // bus would still be holding the PREVIOUS cycle's byte.
    //
    // ANTIC's own reads count as bus traffic too, so they are folded in on the
    // cycle their data lands.
    logic [7:0] last_bus;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                                     last_bus <= 8'h00;
        else if (a2_mem_valid)                       last_bus <= antic_rdata;
        else if (c_rdy && c_sub == 8'(SUB_DATA))     last_bus <= c_rw ? c_din
                                                                      : c_dout;
    end

    antic2 #(
        .LINE_CYCLES(114), .LINES(262), .DISPLAY_TOP(8), .DISPLAY_BOTTOM(248)
    ) u_antic2 (
        .tune(16'h0000),
        .clk(clk), .rst(rst), .tick(tick), .px_tick(px_tick),
        .cs(cs_antic), .we(cpu_we), .addr(c_addr[3:0]), .wdata(c_dout),
        .rdata(a2_rdata), .cpu_writing(!c_rw),
        .mem_addr(a2_mem_addr), .mem_data(antic_rdata),
        .bus_byte(last_bus),
        .pm_we(a2_pm_we), .pm_obj(a2_pm_obj), .pm_data(a2_pm_data),
        .pm_fetch(a2_pm_fetch),
        .mem_valid(a2_mem_valid), .mem_req(a2_mem_req),
        .nmi(a2_nmi), .wsync_take(a2_wsync_take), .dma_steal(a2_dma_steal),
        .hcount(a2_hcount), .line(a2_line),
        .px_wr(a2_px_wr), .px_pf_src(a2_px_pf_src), .px_val(a2_px_val),
        .px_hires(a2_px_hires), .px_in_window(a2_px_in_window),
        .px_hcount(a2_px_hcount), .px_mode(a2_px_mode),
        .px_pos(a2_px_pos), .px_line_start(a2_px_line_start),
        .px_active(a2_px_active), .px_collide(a2_px_collide)
    );

    // ---- the ANTIC->framebuffer gap ----------------------------------------
    //
    // antic2 emits playfield SOURCES; the framebuffer wants colours; the CPU
    // wants to read collisions out of $D0xx.  a2_video is all three, and it
    // holds the $D0xx registers, so under USE_ANTIC2 the legacy monolith's
    // register file is not the one answering.
    //
    // P/M DMA has not landed yet, so no object bytes are stored.  The players
    // are still POSITIONED and still collide -- GRAFP0-3 are CPU-writable and
    // the ACID collision tests write them directly -- so this is a missing
    // fetch path, not a missing object path.
    a2_video u_a2_video (
        .consol_spk (),          // sim-only path: no audio mix here
        .clk(clk), .rst(rst), .px_tick(px_tick),
        .cs(cs_gtia), .we(cpu_we), .addr(c_addr[7:0]), .wdata(c_dout),
        .rdata(a2_gtia_rdata),
        .px_wr(a2_px_wr), .px_pf_src(a2_px_pf_src), .px_val(a2_px_val),
        .px_hires(a2_px_hires), .px_in_window(a2_px_in_window),
        .px_hcount(a2_px_hcount), .px_mode(a2_px_mode),
        .px_pos(a2_px_pos), .px_line_start(a2_px_line_start),
        .px_active(a2_px_active), .px_collide(a2_px_collide),
        .pm_we(a2_pm_we), .pm_obj(a2_pm_obj), .pm_data(a2_pm_data),
        .pm_fetch(a2_pm_fetch),
        .trig0(trig0), .trig1(trig1), .trig2(trig2), .trig3(trig3),
        .pal_sense(pal_sense), .consol_keys(consol_keys),
        .lb_wr(a2_lb_wr), .lb_color(a2_lb_color),
        .lb_line_start(a2_lb_line_start)
    );

    assign lb_wr         = USE_ANTIC2 ? a2_lb_wr         : gt_lb_wr;
    assign lb_color      = USE_ANTIC2 ? a2_lb_color      : gt_lb_color;
    assign lb_line_start = USE_ANTIC2 ? a2_lb_line_start : gt_lb_line_start;

    assign hcount     = USE_ANTIC2 ? a2_hcount   : gt_hcount;
    assign line       = USE_ANTIC2 ? a2_line     : gt_line;
    assign antic_addr = USE_ANTIC2 ? a2_mem_addr : gt_antic_addr;

    // ---- POKEY --------------------------------------------------------------
    //
    // The design HAS a POKEY; leaving it out of a8_core was a limitation of this
    // assembly, not of the hardware, and it cost the suite the whole pokey_*
    // family plus antic_dmapattern and antic_wsync -- both of which MEASURE
    // through RANDOM at $D20A and so could never pass without it.
    //
    // Snoop-shaped like the ANTIC/GTIA register files: a write port qualified
    // the same way as theirs (cpu_we is already SUB_DATA-strobed), a
    // combinational read port, and a read STROBE so KBCODE's read-clears-latch
    // and RANDOM's advance see the access.
    //
    // Everything POKEY needs from outside this core -- keyboard, pots, serial --
    // is tied off. The ACID tests exercise the timers, IRQs, RANDOM and SKSTAT,
    // none of which depend on those.
    wire pokey_re = c_rw && cs_pokey && (c_sub == 8'(SUB_DATA));

    // THE PIA ($D300-$D37F, mirrored to $D3FF).  It was written but never
    // wired: a8_core had no $D3xx decode at all, so every PIA read returned
    // open bus $FF -- which is exactly what pia_basic (wants $00) and pia_irq
    // (wants $3F) were reporting.  The joystick pins are unwired here and read
    // as all-released, per the module's own default.
    pia_regs u_pia (
        .clk(clk), .rst(rst),
        .we(cpu_we && cs_pia), .waddr(c_addr), .wdata(c_dout),
        .raddr(c_addr), .rdata(pia_rdata),
        .joy_porta_in(8'hFF), .joy_portb_in(8'hFF),
        .joy_porta_oe(), .joy_portb_oe(),
        .portb_out_q(portb_bank),
        .pia_irq_n(pia_irq_n)
    );

    pokey #(.CLK_BUS_HZ(CLK_HZ)) u_pokey (
        .clk(clk), .rst(rst), .cold_boot(cold),
        .phi2_tick(tick),
        .we(cpu_we && cs_pokey), .waddr(c_addr[7:0]), .wdata(c_dout),
        .re(pokey_re), .re_addr(c_addr[7:0]),
        .raddr(c_addr[7:0]), .rdata(pokey_rdata),
        .kbd_event_valid(1'b0), .kbd_event_code(8'h00), .kbd_release(1'b0),
        .shadow_pot0(8'd228), .shadow_pot1(8'd228),
        .shadow_pot2(8'd228), .shadow_pot3(8'd228),
        .shadow_pot4(8'd228), .shadow_pot5(8'd228),
        .shadow_pot6(8'd228), .shadow_pot7(8'd228),
        .shadow_allpot(8'h00),
        .bridge_potgo_pulse(), .bridge_fast_scan(),
        .ch1_out(), .ch2_out(), .ch3_out(), .ch4_out(),
        .ser_out_complete(1'b1), .ser_out_ready_pulse(1'b0),
        .ser_in_byte_pulse(1'b0), .ser_in_byte(8'h00),
        .break_key_pulse(1'b0), .ser_framing_err(1'b0),
        .ser_input_overrun(1'b0), .ser_input_busy(1'b0),
        .irq_n(pokey_irq_n),
        .serout_byte(), .serout_strobe(), .skctl_out()
    );

    // ---- the halt composition -----------------------------------------------
    // HALT is unconditional; WSYNC's RDY cannot stall a write.  A LEVEL, not a
    // pulse: the fid core is paced by phi2_tick and samples this at its commit
    // slot.
    // With antic2 the two terms come from ONE module and keep SALLY's asymmetry
    // explicitly: HALT is unconditional, and the WSYNC stall cannot stop a
    // WRITE.  antic2_seq already expresses the stall the software's way round --
    // every cycle EXCEPT the release is taken, and a write is never taken -- so
    // `a2_wsync_take` is already write-aware and does not need `|| !c_rw` here.
    wire halt_n   = USE_ANTIC2 ? !a2_dma_steal  : !dma_steal;
    wire wsync_ok = USE_ANTIC2 ? !a2_wsync_take : (!rdy_n || !c_rw);

    assign c_rdy = halt_n && wsync_ok;

    // antic2 emits a POSITIVE ONE-CYCLE PULSE; antic_gtia drives an active-low
    // LEVEL.  Mixing the two conventions silently is exactly the class of bug
    // this rewrite exists to avoid, so the conversion is explicit and named.
    assign nmi_n_eff = USE_ANTIC2 ? ~a2_nmi : nmi_n;

endmodule

`default_nettype wire
