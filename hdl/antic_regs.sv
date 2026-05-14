// antic_regs.sv — ANTIC register file ($D400-$D40F canonical,
// mirrored at every 16-byte boundary up to $D47F, plus the chiplet-
// extension window at $D480-$D4FF). See docs/register-map.md.
//
// Write port is registered through bus_snoop (waddr / wdata / we are
// 1 cycle delayed from the live bus). Read port is combinational off
// the live bus address — the master expects D valid during CLK high
// of the same cycle.

`default_nettype none

module antic_regs (
    input  wire        clk,
    input  wire        rst,

    // Write port (registered from bus_snoop).
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [7:0]  wdata,

    // Read port (combinational from live bus signals).
    input  wire [7:0]  raddr,
    output logic [7:0] rdata,

    // Side-channel outputs to other modules in later milestones.
    output logic       wsync_pending,   // pulsed high when CPU writes $D40A
    output logic       nmires_strobe,   // pulsed high when CPU writes $D40F (clear NMIST)
    output logic       pal_write_strobe,// pulsed high when CPU writes $D486 (commit palette entry)
    output logic [7:0] pal_r_q,         // latched at $D483 write
    output logic [7:0] pal_g_q,         // latched at $D484 write
    output logic [7:0] pal_b_q,         // latched at $D485 write
    output logic [7:0] pal_idx_q,       // latched at $D486 write (also the commit address)
    output logic [7:0] dmactl_q,
    output logic [7:0] chactl_q,
    output logic [7:0] dlistl_q,
    output logic [7:0] dlisth_q,
    output logic [7:0] hscrol_q,
    output logic [7:0] vscrol_q,
    output logic [7:0] pmbase_q,
    output logic [7:0] chbase_q,
    output logic [7:0] nmien_q,

    // Chiplet-extension state.
    output logic       mode_snoop_q,    // $D481 bit 0
    output logic       cpu_internal_q,  // $D481 bit 1 (M24-int-2): 0=external CPU, 1=internal SALLY
    output logic [7:0] clock_mult_q,    // $D480 (driven by serial-link)
    output logic [7:0] output_mode_q,   // $D482

    // M24-4: ANTIC's view of the bank-select state, mirrored into
    // the bank_xlat alongside the CPU's $0082-$0085 zp values.
    // CPU and ANTIC can see different banks at the same address
    // when these differ from the CPU values — period-correct
    // technique for "CPU runs from one bank while ANTIC composites
    // a different bank's screen RAM".
    output logic [7:0] antic_code_bank_q,    // $D488
    output logic [7:0] antic_data_bank_q,    // $D489
    output logic [7:0] antic_regc_bank_lo_q, // $D48A
    output logic [7:0] antic_regc_bank_hi_q, // $D48B

    // M24-6: OS ROM load path. Software stages a load by writing
    // OS_ROM_ADDR_{LO,HI} once, then streaming bytes through
    // OS_ROM_DATA. Each $D48E write pulses os_rom_we for 1 cycle and
    // auto-increments OS_ROM_ADDR. WRITE_LOCK ($D48F bit 0) gates
    // os_rom_we — once locked, further $D48E writes are ignored.
    output logic [15:0] os_rom_addr_q,       // current target address
    output logic [7:0]  os_rom_data_q,       // last $D48E write data
    output logic        os_rom_we,           // 1-cycle pulse per accepted load
    output logic        os_rom_locked_q,     // 1 = ROM-load disabled

    // Inputs from live status sources.
    input  wire [7:0]  vcount_in,       // current vbeam V/2
    input  wire [7:0]  nmist_in,        // VBI/DLI/RNMI status
    input  wire [7:0]  serial_clock_mult_in,

    // M-PBI step 2: PBI / cart-detect status (2-FF synchronised in antic_top).
    // Surfaced via $D481 read bits [7:4]. All active-low (1 = no event,
    // 0 = signal asserted).
    input  wire        bus_rd4_in,      // $D481[4] — cart-present, $8000-$9FFF
    input  wire        bus_rd5_in,      // $D481[5] — cart-present, $A000-$BFFF
    input  wire        bus_mpd_n_in,    // $D481[6] — PBI Math-Pack Disable
    input  wire        bus_extirq_n_in  // $D481[7] — PBI IRQ
);

    // ---- Canonical register storage -------------------------------------
    // dmactl and nmien clear on reset (Altirra §4.1). The others have
    // undefined power-on values on real hardware but we initialise
    // them to 0 for sim determinism — they don't get cleared by the
    // rst path.
    logic [7:0] dmactl, nmien;
    logic [7:0] chactl = 8'h00, dlistl = 8'h00, dlisth = 8'h00;
    logic [7:0] hscrol = 8'h00, vscrol = 8'h00;
    logic [7:0] pmbase = 8'h00, chbase = 8'h00;
    // $D40C/$D40D PENH/PENV are stubs returning 0 in rp-XT.
    // $D40F NMIST is read-only (status); writes act as NMIRES (clear).

    // ---- Chiplet-ext storage --------------------------------------------
    // Layout per the README (and docs/register-map.md):
    //   $D480 CLOCK_MULT (R-only, driven by serial-link push)
    //   $D481 MODE       (bit 0 MODE_SNOOP; defaults 1 at /G_RST)
    //   $D482 OUTPUT_MODE
    //   $D483 PAL_R
    //   $D484 PAL_G
    //   $D485 PAL_B
    //   $D486 PAL_IDX
    //   $D487 reserved (palette extension; future)
    logic       mode_snoop;
    logic       cpu_internal;
    logic       auto_phi2_on_extirq;      // M-PBI #3: $D481[3]
    logic       extirq_fallback_active_q; // M-PBI #3: internal — forces clock_mult to 1
    logic       bus_extirq_n_prev_q;      // M-PBI #3: edge detection on /EXTIRQ
    logic [7:0] output_mode;
    logic [7:0] pal_r;
    logic [7:0] pal_g;
    logic [7:0] pal_b;
    logic [7:0] pal_idx;
    logic [7:0] antic_code_bank, antic_data_bank;
    logic [7:0] antic_regc_bank_lo, antic_regc_bank_hi;
    logic [15:0] os_rom_addr;
    logic [15:0] os_rom_pending_addr;     // address paired with current strobe
    logic [7:0]  os_rom_data;
    logic        os_rom_locked;

    // ---- Address decode helpers -----------------------------------------
    // Below $80: legacy mirror, only low 4 bits of addr matter.
    // $80 and above: chiplet extension, full address.
    wire is_canonical = (waddr[7] == 1'b0);
    wire is_chiplet   = (waddr[7] == 1'b1);
    wire [3:0] canon_w = waddr[3:0];

    wire is_canon_r = (raddr[7] == 1'b0);
    wire [3:0] canon_r = raddr[3:0];

    // ---- Write side -----------------------------------------------------
    // Per Altirra §4.1 "Reset behavior": only NMIEN, DMACTL, and the
    // playfield DMA clock are cleared on reset. CHACTL, DLISTL/H,
    // HSCROL, VSCROL, PMBASE, CHBASE all retain whatever was last
    // written (their power-on value is undefined; we initialise via
    // SystemVerilog's default to keep sim deterministic, but DON'T
    // clear them on the rst pulse).
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dmactl       <= 8'h00;
            nmien        <= 8'h00;
            wsync_pending    <= 1'b0;
            nmires_strobe    <= 1'b0;
            pal_write_strobe <= 1'b0;
            // Chiplet-extension registers are our own contract; they
            // get the rp-XT defaults on /G_RST.
            mode_snoop   <= 1'b1;       // snoop is the default at /G_RST
            cpu_internal <= 1'b0;       // external CPU at boot; SW flips this once OS-B is loaded + locked
            auto_phi2_on_extirq      <= 1'b0;  // M-PBI #3: software opts in
            extirq_fallback_active_q <= 1'b0;
            bus_extirq_n_prev_q      <= 1'b1;  // /EXTIRQ idle = high
            output_mode  <= 8'h00;      // 640x480, ANTIC-compat half-V
            pal_r        <= 8'h00;
            pal_g        <= 8'h00;
            pal_b        <= 8'h00;
            pal_idx      <= 8'h00;
            antic_code_bank    <= 8'h00;
            antic_data_bank    <= 8'h00;
            antic_regc_bank_lo <= 8'h00;
            antic_regc_bank_hi <= 8'h00;
            os_rom_addr         <= 16'h0000;
            os_rom_pending_addr <= 16'h0000;
            os_rom_data         <= 8'h00;
            os_rom_locked       <= 1'b0;
            os_rom_we           <= 1'b0;
            // chactl, dlistl, dlisth, hscrol, vscrol, pmbase, chbase
            // intentionally NOT reset — Altirra §4.1.
        end else begin
            // WSYNC pending, NMIRES strobe, palette commit, and
            // os_rom_we are 1-cycle pulses; clear every cycle unless
            // re-asserted by another write.
            wsync_pending    <= 1'b0;
            nmires_strobe    <= 1'b0;
            pal_write_strobe <= 1'b0;
            os_rom_we        <= 1'b0;

            if (we && is_canonical) begin
                unique case (canon_w)
                    4'h0: dmactl <= wdata;       // $D400 DMACTL
                    4'h1: chactl <= wdata;       // $D401 CHACTL
                    4'h2: dlistl <= wdata;       // $D402 DLISTL
                    4'h3: dlisth <= wdata;       // $D403 DLISTH
                    4'h4: hscrol <= wdata;       // $D404 HSCROL
                    4'h5: vscrol <= wdata;       // $D405 VSCROL
                    4'h6: ;                       // $D406 reserved
                    4'h7: pmbase <= wdata;       // $D407 PMBASE
                    4'h8: ;                       // $D408 reserved (was MODE in draft)
                    4'h9: chbase <= wdata;       // $D409 CHBASE
                    4'hA: wsync_pending <= 1'b1; // $D40A WSYNC strobe
                    4'hB: ;                       // $D40B VCOUNT — read-only
                    4'hC: ;                       // $D40C PENH stub
                    4'hD: ;                       // $D40D PENV stub
                    4'hE: nmien <= wdata;        // $D40E NMIEN
                    4'hF: nmires_strobe <= 1'b1;  // $D40F NMIRES — clears NMIST in nmi_gen
                endcase
            end else if (we && is_chiplet) begin
                unique case (waddr[6:0])
                    7'h00: ;                            // $D480 CLOCK_MULT — serial-driven, ignore bus writes
                    7'h01: begin                       // $D481 MODE
                        mode_snoop          <= wdata[0];
                        cpu_internal        <= wdata[1];  // M24-int-2: 1 = internal SALLY drives the bus
                        // wdata[2] reserved
                        auto_phi2_on_extirq <= wdata[3];  // M-PBI #3
                        // wdata[7:4] status bits — write-ignored
                    end
                    7'h02: output_mode <= wdata;      // $D482 OUTPUT_MODE
                    7'h03: pal_r       <= wdata;      // $D483 PAL_R
                    7'h04: pal_g       <= wdata;      // $D484 PAL_G
                    7'h05: pal_b       <= wdata;      // $D485 PAL_B
                    7'h06: begin
                        pal_idx          <= wdata;       // $D486 PAL_IDX
                        pal_write_strobe <= 1'b1;        // commits {R,G,B} into palette_lut[wdata]
                    end
                    7'h07: ;                            // $D487 reserved
                    7'h08: antic_code_bank    <= wdata;  // $D488 ANTIC_CODE_BANK
                    7'h09: antic_data_bank    <= wdata;  // $D489 ANTIC_DATA_BANK
                    7'h0A: antic_regc_bank_lo <= wdata;  // $D48A ANTIC_REGC_BANK_LO
                    7'h0B: antic_regc_bank_hi <= wdata;  // $D48B ANTIC_REGC_BANK_HI
                    7'h0C: os_rom_addr[7:0]   <= wdata;  // $D48C OS_ROM_ADDR_LO
                    7'h0D: os_rom_addr[15:8]  <= wdata;  // $D48D OS_ROM_ADDR_HI
                    7'h0E: begin                          // $D48E OS_ROM_DATA
                        // Commit byte → fire os_rom_we strobe and
                        // auto-increment the target address. The
                        // strobe is paired with the PRE-increment
                        // address (so sally_mem writes at X then we
                        // bump to X+1 for the next byte). WRITE_LOCK
                        // gates the strobe; locked writes still update
                        // os_rom_data (so software can read back what
                        // it tried to write) but DON'T pulse os_rom_we
                        // and don't increment.
                        os_rom_data <= wdata;
                        if (!os_rom_locked) begin
                            os_rom_we           <= 1'b1;
                            os_rom_pending_addr <= os_rom_addr;
                            os_rom_addr         <= os_rom_addr + 16'd1;
                        end
                    end
                    7'h0F: os_rom_locked      <= wdata[0]; // $D48F OS_ROM_CTL bit 0
                    default: ;
                endcase
            end

            // M-PBI #3: /EXTIRQ-driven fall-back to phi2.
            // bus_extirq_n_in is already 2-FF synced upstream (antic_top).
            // Edge-detect against bus_extirq_n_prev_q:
            //   falling edge (1->0) + auto_phi2_on_extirq → enter fall-back
            //   rising edge (0->1)                       → exit fall-back
            // The PBI device deasserts /EXTIRQ once the handler clears its
            // own status; that natural deassertion edge releases SALLY back
            // to whatever the serial link last pushed for CLOCK_MULT. No
            // software action required at end of handler.
            bus_extirq_n_prev_q <= bus_extirq_n_in;
            if (auto_phi2_on_extirq
                && bus_extirq_n_prev_q && !bus_extirq_n_in) begin
                extirq_fallback_active_q <= 1'b1;
            end else if (!bus_extirq_n_prev_q && bus_extirq_n_in) begin
                extirq_fallback_active_q <= 1'b0;
            end
        end
    end

    // ---- Read side (combinational) --------------------------------------
    // Per Altirra §4.1: "Unassigned addresses within the ANTIC address
    // range read as $FF. ... ANTIC actually drives $FF onto the bus
    // for addresses in its range that don't have registers assigned."
    // §14.6 marks every ANTIC control register as write-only except
    // VCOUNT ($D40B) and NMIST ($D40F). PENH / PENV are read-only but
    // unconnected on the rp-XT board (no lightpen) — return $FF, which
    // matches real-hardware behaviour for an unconnected lightpen.
    always_comb begin
        rdata = 8'hFF;
        if (is_canon_r) begin
            unique case (canon_r)
                4'h0: rdata = 8'hFF;             // DMACTL — write-only
                4'h1: rdata = 8'hFF;             // CHACTL — write-only
                4'h2: rdata = 8'hFF;             // DLISTL — write-only
                4'h3: rdata = 8'hFF;             // DLISTH — write-only
                4'h4: rdata = 8'hFF;             // HSCROL — write-only
                4'h5: rdata = 8'hFF;             // VSCROL — write-only
                4'h6: rdata = 8'hFF;             // unassigned
                4'h7: rdata = 8'hFF;             // PMBASE — write-only
                4'h8: rdata = 8'hFF;             // unassigned
                4'h9: rdata = 8'hFF;             // CHBASE — write-only
                4'hA: rdata = 8'hFF;             // WSYNC — write-only
                4'hB: rdata = vcount_in;         // VCOUNT
                4'hC: rdata = 8'hFF;             // PENH stub
                4'hD: rdata = 8'hFF;             // PENV stub
                4'hE: rdata = 8'hFF;             // NMIEN — write-only
                4'hF: rdata = nmist_in;          // NMIST
            endcase
        end else begin
            unique case (raddr[6:0])
                7'h00: rdata = serial_clock_mult_in;        // $D480 CLOCK_MULT
                7'h01: rdata = {bus_extirq_n_in, bus_mpd_n_in,
                                bus_rd5_in,      bus_rd4_in,
                                auto_phi2_on_extirq, 1'b0,
                                cpu_internal,    mode_snoop};      // $D481 MODE + PBI status
                7'h02: rdata = output_mode;                  // $D482 OUTPUT_MODE
                7'h03: rdata = pal_r;                        // $D483 PAL_R
                7'h04: rdata = pal_g;                        // $D484 PAL_G
                7'h05: rdata = pal_b;                        // $D485 PAL_B
                7'h06: rdata = pal_idx;                      // $D486 PAL_IDX
                7'h07: rdata = 8'h00;                        // $D487 reserved
                7'h08: rdata = antic_code_bank;              // $D488
                7'h09: rdata = antic_data_bank;              // $D489
                7'h0A: rdata = antic_regc_bank_lo;           // $D48A
                7'h0B: rdata = antic_regc_bank_hi;           // $D48B
                7'h0C: rdata = os_rom_addr[7:0];             // $D48C
                7'h0D: rdata = os_rom_addr[15:8];            // $D48D
                7'h0E: rdata = os_rom_data;                  // $D48E
                7'h0F: rdata = {7'h00, os_rom_locked};       // $D48F
                default: rdata = 8'h00;
            endcase
        end
    end

    // ---- Side-channel outputs -------------------------------------------
    assign dmactl_q       = dmactl;
    assign chactl_q       = chactl;
    assign dlistl_q       = dlistl;
    assign dlisth_q       = dlisth;
    assign hscrol_q       = hscrol;
    assign vscrol_q       = vscrol;
    assign pmbase_q       = pmbase;
    assign chbase_q       = chbase;
    assign nmien_q        = nmien;
    assign mode_snoop_q   = mode_snoop;
    assign cpu_internal_q = cpu_internal;
    // M-PBI #3: while /EXTIRQ-fall-back is active, force CLOCK_MULT to 1 so
    // the IRQ handler can reach the PBI device at $D1xx (external bus is
    // only active at CLOCK_MULT=1). Cleared automatically on /EXTIRQ rising
    // edge — see the always_ff block above.
    assign clock_mult_q   = extirq_fallback_active_q ? 8'h01 : serial_clock_mult_in;
    assign output_mode_q  = output_mode;
    assign pal_r_q        = pal_r;
    assign pal_g_q        = pal_g;
    assign pal_b_q        = pal_b;
    assign pal_idx_q      = pal_idx;
    assign antic_code_bank_q    = antic_code_bank;
    assign antic_data_bank_q    = antic_data_bank;
    assign antic_regc_bank_lo_q = antic_regc_bank_lo;
    assign antic_regc_bank_hi_q = antic_regc_bank_hi;
    // os_rom_addr_q exposes the *next* target address (= the value
    // software reads back at $D48C/$D48D after a stream of writes).
    // The strobe pairs with os_rom_pending_addr — that's what
    // sally_mem latches as rom_addr.
    assign os_rom_addr_q        = os_rom_we ? os_rom_pending_addr : os_rom_addr;
    assign os_rom_data_q        = os_rom_data;
    assign os_rom_locked_q      = os_rom_locked;

endmodule

`default_nettype wire
