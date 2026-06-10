// axi_blitter_bridge.sv — AXI4-Lite slave bridge from PS GP0 to xt_blitter.
//
// Translates AXI4-Lite writes from the ARM cores (via PS GP0 port) into
// the blitter's hwreg-style register bus (bus_addr, bus_data, bus_we).
//
// Runs on clk_sys (150 MHz) — same domain as the blitter, so no CDC
// needed.  The PS GP0 port's M_AXI_GP0_ACLK is driven by clk_sys via
// the s_axi_gp0_aclk input on the PS BD.
//
// Register map (32-bit AXI4-Lite byte addresses):
//   Offset 0x00..0x0F -> blitter regs $D4B0..$D4BF (DST/PAT/CMD page)
//   Offset 0x10..0x1F -> blitter regs $D4C0..$D4CF (SRC/FLAGS page)
//
// Internal bl_addr[5] encoding (derived from AXI byte offset bit 4):
//   Offset 0x00..0x0F (awaddr[4]=0) -> bl_addr[5]=1 ($D4Bx page)
//   Offset 0x10..0x1F (awaddr[4]=1) -> bl_addr[5]=0 ($D4Cx page)
//
// Writes are converted to byte-wide bl_we pulses matching the SALLY CPU's
// access pattern.  Reads at offset 0x0D return STATUS:
//   bit 0 = bl_busy (queue non-empty OR FSM active)
//   bit 1 = bl_queue_full (next CMD write would be dropped)
//   bit 2 = bl_pat_blocked (sticky: pat/font load was dropped while busy)
// Reads at offset 0x19 return SEQ_LO (low byte of SYNC counter).
// Reads at offset 0x1A return SEQ_HI (high byte of SYNC counter).
// All other addresses return zero.

`default_nettype none

module axi_blitter_bridge (
    input  wire        clk,                  // clk_sys (150 MHz)
    input  wire        rst,                  // active-high, clk domain

    // ---- AXI4-Lite slave (GP0 from PS) -------------------------------------
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- Blitter register bus output (clk_sys domain) -----------------------
    output reg  [5:0]  bl_addr,
    output reg  [7:0]  bl_data,
    output reg         bl_we,              // 1-cycle write strobe

    // ---- Blitter status (clk_sys domain) ------------------------------------
    input  wire        bl_busy,            // returned on STATUS read ($D4BD bit 0)
    input  wire        bl_queue_full,      // returned on STATUS read ($D4BD bit 1)
    input  wire        bl_pat_blocked,     // returned on STATUS read ($D4BD bit 2)
    input  wire [15:0] bl_seq_counter,     // returned at SEQ_LO/HI ($D4C9/CA, offsets 0x19/0x1A)

    // ---- PL debug word (clk_sys domain) — read at offset 0x1C --------------
    // General-purpose diagnostic read (clock-lock state, heartbeats, etc.);
    // built in fpga_xt_top, surfaced over GP0 so the PS app can print it.
    input  wire [31:0] diag_word,

    // ---- 2nd PL debug word (clk_sys) — read at offset 0x18 -----------------
    // Production-chain activity counters (ANTIC frames / HP3 writeback beats);
    // built in fpga_xt_top.  Word-aligned offset so a plain Xil_In32 reads it.
    input  wire [31:0] diag2_word,

    // ---- 3rd PL debug word (clk_sys) — read at offset 0x14 -----------------
    // Read-path activity counters: {hp0_ar, hp0_rbeat, hp3_ar, hp3_rbeat}
    // (plane_fetch DDR reads → compositor).  Word-aligned for a plain Xil_In32.
    input  wire [31:0] diag3_word,

    // ---- First-AR address latches (clk_sys) — read at 0x10 / 0x0C ----------
    // diag4 = HP3(XL) first read address, diag5 = HP0(desktop) first read
    // address.  Confirms plane_fetch drives a sane araddr on silicon.
    input  wire [31:0] diag4_word,
    input  wire [31:0] diag5_word,

    // ---- HP read-test probe results (clk_sys) — read at 0x04 / 0x08 --------
    // diag6 = {success_cnt[15:0], timeout_cnt[12:0], to_in_r, rresp[1:0]},
    // diag7 = last rdata.  Auto-running isolated PL->DDR read test (HP2).
    input  wire [31:0] diag6_word,
    input  wire [31:0] diag7_word,

    // SALLY speed/clock_mult ($D4CA), read back at offset 0x1E so the PS can
    // verify a `speed <n>` write actually latched (the write goes out at 0x1A).
    input  wire [7:0]  clock_mult,

    // ---- PL control register (clk_sys domain) — WRITTEN at offset 0x1C ------
    // Software-writable control bits (the read at 0x1C returns diag_word; the
    // write at 0x1C lands here — read/write share the offset).  bit0 = HDMI
    // test-pattern (colour-bar) enable.  Resets to 0x01 so the board still
    // boots showing bars; the PS can clear it to show the live compositor.
    output reg  [7:0]  gp0_ctrl,

    // ---- XT register-unlock control (clk_sys domain) — WRITTEN at offset 0x20 -
    // The A9 sets the machine's stock-vs-XT personality (see docs/Zynq/
    // register-unlock.md).  A 1-cycle strobe + the byte on bl_data (latched the
    // same cycle as any other write); fpga_xt_top holds the effective unlock
    // register (this strobe is one of its two write ports — the other is the
    // 6502 at $D1DF).  xt_unlock_state is the effective value fed back so the A9
    // can read it (incl. any 6502 self-unlock) at offset 0x20.
    output reg         xt_unlock_we,       // 1-cycle write strobe (byte on bl_data)
    input  wire [7:0]  xt_unlock_state,    // effective unlock, for read-back

    // ---- Drag-overlay config (clk_sys) — WRITTEN at offsets 0x21..0x2F ------
    // A movable DDR-backed surface composited above the GEM desktop (below the
    // XL/ST windows) to show a window while it is being dragged: the PS moves
    // the window by updating x/y here instead of re-blitting it into the
    // desktop plane every frame (tear-free — see docs/video).  These offsets
    // are page 2 ($D4Dx), the NATIVE-only sprite page — a no-op on the GP0
    // bridge — so stealing them is safe and never strobes bl_we.  A write to
    // 0x21 (enable) also toggles overlay_commit so clk_pix can atomically adopt
    // the whole {x,y,w,h,en} set (stable-data + sync-flag CDC), avoiding a
    // multi-bit 2-FF bus-sync glitch.
    output reg  [31:0] overlay_base,   // DDR byte address of the drag surface
    output reg  [11:0] overlay_x,      // on-screen origin X
    output reg  [11:0] overlay_y,      // on-screen origin Y
    output reg  [11:0] overlay_w,      // surface width  (px); stride = w<<2
    output reg  [11:0] overlay_h,      // surface height (px)
    output reg         overlay_en,     // 1 = composite the overlay
    output reg         overlay_commit  // toggles on each 0x21 write (commit flag)
);

    // ====================================================================
    // AXI4-Lite write transaction FSM
    //
    // AW and W are accepted INDEPENDENTLY — they are NOT coupled.  The PS GP0
    // master may assert AWVALID and wait for AWREADY *before* it drives WVALID;
    // a slave that only accepts when both are valid together then deadlocks
    // (it waits for WVALID that the master won't send until it sees AWREADY) ->
    // every GP0 write hangs the issuing core.  Reads are immune (single AR
    // channel), which is exactly why reads worked while the first write hung.
    //
    // So: capture AW when it arrives (only if it addresses our 0x00-0x1F
    // window), capture W only once we own that AW (the W channel is shared with
    // sally_rom_loader, so the slave that matched the address must claim the W),
    // then drive the response once both halves are in.
    //
    //   bl_addr maps the AXI byte offset to the blitter reg page:
    //     0x00..0x0F -> bl_addr[5]=0 ($D4Bx),  0x10..0x1F -> bl_addr[5]=1 ($D4Cx)
    //   offset 0x1C is the SW control register (gp0_ctrl), NOT a blitter reg:
    //     it latches gp0_ctrl and does NOT strobe bl_we.
    // ====================================================================
    localparam WST_IDLE = 1'b0,
               WST_RESP = 1'b1;

    reg        wstate;
    reg        aw_have, w_have;       // AW / W captured for the in-flight write
    reg [5:0]  aw_off;                // latched AXI byte offset awaddr[5:0]
    reg [7:0]  w_byte;                // latched first active write byte
    // 64-byte register window (0x00..0x3F): 4 pages of 16 byte-offsets.
    //   0x00-0x0F -> $D4Bx,  0x10-0x1F -> $D4Cx,  0x20-0x2F -> $D4Dx,
    //   0x30-0x3F -> $D4Ex (SRC/DST descriptors).  $D4Dx (0x20-0x2F) is the
    //   sprite page on the native bus; the blitter ignores it and sprites are
    //   native-only, so a bridge write there is a no-op — which is why 0x20 is
    //   safe to steal as the XT-unlock control intercept (read + write).
    wire       aw_mine = s_axi_awvalid && (s_axi_awaddr[15:6] == 10'h000);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wstate        <= WST_IDLE;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            s_axi_bvalid  <= 1'b0;
            bl_addr       <= 6'd0;
            bl_data       <= 8'd0;
            bl_we         <= 1'b0;
            aw_have       <= 1'b0;
            w_have        <= 1'b0;
            aw_off        <= 6'd0;
            w_byte        <= 8'd0;
            gp0_ctrl      <= 8'h00;    // boot to the COMPOSITOR (desktop); bars
                                       // (bit0=1) is now a debug option only,
                                       // never the default — incl. after a PS
                                       // `reset` / cold boot.  bits[3:1]=0 =
                                       // default XL scale.
            xt_unlock_we  <= 1'b0;
            overlay_base   <= 32'd0;
            overlay_x      <= 12'd0;
            overlay_y      <= 12'd0;
            overlay_w      <= 12'd0;
            overlay_h      <= 12'd0;
            overlay_en     <= 1'b0;
            overlay_commit <= 1'b0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            bl_we         <= 1'b0;
            xt_unlock_we  <= 1'b0;

            unique case (wstate)
                WST_IDLE: begin
                    // Accept AW (once) if it addresses our window; decode the
                    // blitter reg address now so it is stable before bl_we.
                    if (aw_mine && !aw_have) begin
                        s_axi_awready <= 1'b1;
                        aw_have       <= 1'b1;
                        aw_off        <= s_axi_awaddr[5:0];
                        // bl_addr = {page[1:0], offset[3:0]}: page = awaddr[5:4]
                        // (00=$D4Bx, 01=$D4Cx, 10=$D4Dx, 11=$D4Ex), offset =
                        // awaddr[3:0].  fpga_xt_top reconstructs the 16-bit bus
                        // address from bl_addr[5:4] (see bridge_bus_addr).  The
                        // historical page bug: the old 5-bit form put the page
                        // bit in bl_addr[4] not [5], forcing every write onto
                        // $D4Cx (CMD lost, PAT/RASTER hit the kbd-inject regs).
                        bl_addr       <= {s_axi_awaddr[5:4], s_axi_awaddr[3:0]};
                    end

                    // Accept W only once we own the AW (this cycle or earlier),
                    // so the shared W beat is claimed by the right slave.
                    if (s_axi_wvalid && !w_have && (aw_have || aw_mine)) begin
                        s_axi_wready <= 1'b1;
                        w_have       <= 1'b1;
                        if (s_axi_wstrb[0])      w_byte <= s_axi_wdata[7:0];
                        else if (s_axi_wstrb[1]) w_byte <= s_axi_wdata[15:8];
                        else if (s_axi_wstrb[2]) w_byte <= s_axi_wdata[23:16];
                        else                     w_byte <= s_axi_wdata[31:24];
                    end

                    // Both halves captured (in prior cycles) -> commit + respond.
                    if (aw_have && w_have) begin
                        bl_data      <= w_byte;
                        // Page 2 (0x20-0x2F = $D4Dx) is native-sprite-only — a
                        // no-op on the bridge — so 0x20 is the unlock intercept
                        // and 0x21-0x2F are the drag-overlay config; neither
                        // strobes bl_we.  0x1C is the control reg.  Everything
                        // else is a blitter register write.
                        if (aw_off == 6'h1C) begin
                            gp0_ctrl <= w_byte;                            // control reg
                        end else if (aw_off[5:4] == 2'b10) begin           // page 2: $D4Dx
                            case (aw_off[3:0])
                                4'h0: xt_unlock_we        <= 1'b1;         // 0x20 unlock ctrl
                                4'h1: begin                                // 0x21 enable + commit
                                          overlay_en     <= w_byte[0];
                                          overlay_commit <= ~overlay_commit;
                                      end
                                4'h4: overlay_base[7:0]   <= w_byte;       // 0x24
                                4'h5: overlay_base[15:8]  <= w_byte;       // 0x25
                                4'h6: overlay_base[23:16] <= w_byte;       // 0x26
                                4'h7: overlay_base[31:24] <= w_byte;       // 0x27
                                4'h8: overlay_x[7:0]      <= w_byte;       // 0x28
                                4'h9: overlay_x[11:8]     <= w_byte[3:0];  // 0x29
                                4'hA: overlay_y[7:0]      <= w_byte;       // 0x2A
                                4'hB: overlay_y[11:8]     <= w_byte[3:0];  // 0x2B
                                4'hC: overlay_w[7:0]      <= w_byte;       // 0x2C
                                4'hD: overlay_w[11:8]     <= w_byte[3:0];  // 0x2D
                                4'hE: overlay_h[7:0]      <= w_byte;       // 0x2E
                                4'hF: overlay_h[11:8]     <= w_byte[3:0];  // 0x2F
                                default: ;                                 // 0x22,0x23 unused
                            endcase
                        end else begin
                            bl_we <= 1'b1;                                 // blitter strobe
                        end
                        s_axi_bresp  <= 2'b00;
                        s_axi_bvalid <= 1'b1;
                        aw_have      <= 1'b0;
                        w_have       <= 1'b0;
                        wstate       <= WST_RESP;
                    end
                end

                WST_RESP: begin
                    s_axi_bvalid <= 1'b1;            // hold until the PS accepts
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wstate       <= WST_IDLE;
                    end
                end
            endcase
        end
    end

    // ====================================================================
    // AXI4-Lite read transaction FSM
    // ====================================================================
    localparam RST_IDLE = 0,
               RST_READ = 1;

    reg [1:0]  rstate;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rstate       <= RST_IDLE;
            s_axi_arready<= 1'b0;
            s_axi_rdata  <= 32'd0;
            s_axi_rresp  <= 2'b00;
            s_axi_rvalid <= 1'b0;
        end else begin
            s_axi_arready <= 1'b0;

            unique case (rstate)
                RST_IDLE: begin
                    // Same window gating as the write side — ignore
                    // reads outside the blitter sub-range so the
                    // ROM-init loader can OR-mux on the same bus.
                    if (s_axi_arvalid
                        && (s_axi_araddr[15:6] == 10'h000)) begin
                        s_axi_arready <= 1'b1;
                        // Return STATUS bits on read at offset 0x0D:
                        //   bit 0 = bl_busy (queue non-empty OR FSM active)
                        //   bit 1 = bl_queue_full (next CMD write dropped)
                        //   bit 2 = bl_pat_blocked (sticky: pat/font load
                        //           dropped while busy; clears on busy=0)
                        // SEQ counter at offsets 0x19 (lo byte) / 0x1A (hi).
                        // Byte-wide read-backs (STATUS/SEQ) are REPLICATED
                        // across all 4 byte lanes: these regs sit at odd byte
                        // offsets (0x0D/0x19/0x1A -> lanes 1/1/2), so an Xil_In8
                        // at the real lane must find the value there — returning
                        // it only in [7:0] made every byte read come back 0.
                        if (s_axi_araddr[7:0] == 8'h0D)
                            s_axi_rdata <= {4{5'b0, bl_pat_blocked,
                                                  bl_queue_full, bl_busy}};
                        else if (s_axi_araddr[7:0] == 8'h19)
                            s_axi_rdata <= {4{bl_seq_counter[7:0]}};
                        else if (s_axi_araddr[7:0] == 8'h1A)
                            s_axi_rdata <= {4{bl_seq_counter[15:8]}};
                        else if (s_axi_araddr[7:0] == 8'h18)
                            s_axi_rdata <= diag2_word;       // production-chain counters
                        else if (s_axi_araddr[7:0] == 8'h14)
                            s_axi_rdata <= diag3_word;       // read-path activity counters
                        else if (s_axi_araddr[7:0] == 8'h10)
                            s_axi_rdata <= diag4_word;       // HP3(XL) first-AR address
                        else if (s_axi_araddr[7:0] == 8'h0C)
                            s_axi_rdata <= diag5_word;       // HP0(desktop) first-AR address
                        else if (s_axi_araddr[7:0] == 8'h04)
                            s_axi_rdata <= diag6_word;       // HP2 read-probe status
                        else if (s_axi_araddr[7:0] == 8'h08)
                            s_axi_rdata <= diag7_word;       // HP2 read-probe last rdata
                        else if (s_axi_araddr[7:0] == 8'h1C)
                            s_axi_rdata <= diag_word;        // PL debug word (word read)
                        else if (s_axi_araddr[7:0] == 8'h1E)
                            s_axi_rdata <= {4{clock_mult}};  // SALLY speed read-back ($D4CA)
                        else if (s_axi_araddr[7:0] == 8'h20)
                            s_axi_rdata <= {4{xt_unlock_state}}; // effective XT unlock
                        else
                            s_axi_rdata <= 32'd0;
                        s_axi_rresp  <= 2'b00;
                        s_axi_rvalid <= 1'b1;
                        rstate <= RST_READ;
                    end
                end

                RST_READ: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rstate <= RST_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
