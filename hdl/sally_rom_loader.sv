// sally_rom_loader.sv — AXI-Lite slave bridging PS writes into
// sally_mem's `rom_we` / `rom_addr` / `rom_data` ports for boot-time
// ROM image loading.
//
// Bring-up Phase 7 prereq.  PS-side just does `memcpy(rom_window,
// rom_image, rom_image_size)` and SALLY's main BRAM ends up with the
// ROM image.  Write-only — no read-back path.
//
// Address layout (within the GP0 AXI-Lite window at $43C0_0000):
//   * Offsets $0000-$0FFF (4 KB) -> belong to xt_gp0_regs (the per-device
//     control-register file).  MUST match its aw_mine = (awaddr[15:12]==0)
//     predicate exactly — any overlap here means a register write ALSO lands in
//     SALLY memory as a stray rom_we and corrupts the 6502.
//   * Offsets $1000-$FFFF        -> ROM-init writes.  awaddr[15:0] maps 1:1 to
//     SALLY address (rom_addr = s_axi_awaddr[15:0]; a load to SALLY $C000 is a
//     write to GP0 offset $C000).
//
// SALLY $0000-$0FFF cannot be loaded this way; it's RAM in any real Atari image
// (zero page, stack, OS database — initialised by the OS coldstart, never ROM),
// so ceding it to the register file costs nothing.
//
// Clock crossing: AXI-Lite slave runs on clk_sys (matches the rest
// of the GP0 fabric).  rom_we / rom_addr / rom_data drive sally_mem
// on clk_sally.  cdc_fifo_1w1r carries each {addr,data} pair across
// the domain boundary; depth 4 is far above the PS-side write rate.
//
// The B response is held off until the FIFO has room — back-pressure
// is propagated all the way back to the PS so we never lose writes
// silently.  4-entry FIFO is plenty even for back-to-back AXI bursts
// (PS-side AXI-Lite throughput is well under clk_sally's drain rate).

`default_nettype none

module sally_rom_loader (
    // ---- AXI-Lite slave (clk_sys domain) -------------------------------
    input  wire        clk_sys,
    input  wire        rst_sys,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire  [3:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg [31:0]  s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- ROM-init port (clk_sally domain) -------------------------------
    input  wire        clk_sally,
    input  wire        rst_sally,
    output reg [15:0]  rom_addr,
    output reg  [7:0]  rom_data,
    output reg         rom_we
);

    // Window predicate — anything OUTSIDE the xt_gp0_regs control-register
    // window ($0000-$0FFF, 4 KB) belongs to us ($1000-$FFFF).  This MUST mirror
    // xt_gp0_regs' aw_mine = (awaddr[15:12]==0): if the loader claimed any byte
    // the register file also claims, that register write would land in SALLY
    // memory too as a stray rom_we and corrupt the 6502.  Only ROM regions
    // ($5000+) are ever loaded, so ceding SALLY $0000-$0FFF (RAM) costs nothing;
    // rom_addr = awaddr[15:0] still maps 1:1 (a load to SALLY $C000 = offset $C000).
    wire write_in_window = (s_axi_awaddr[15:12] != 4'h0);
    wire read_in_window  = (s_axi_araddr[15:12] != 4'h0);

    // ---- FIFO (clk_sys → clk_sally) -------------------------------------
    wire        fifo_full;
    wire        fifo_empty;
    reg         fifo_push;
    reg [15:0]  push_addr;
    reg  [7:0]  push_data;
    wire [23:0] pop_word;

    cdc_fifo_1w1r #(.DATA_W(24), .ADDR_W(2)) u_fifo (
        .src_clk   (clk_sys),
        .src_rst   (rst_sys),
        .wr_en     (fifo_push),
        .wr_data   ({push_addr, push_data}),
        .wr_full   (fifo_full),
        .dst_clk   (clk_sally),
        .dst_rst   (rst_sally),
        .rd_en     (~fifo_empty),
        .rd_data   (pop_word),
        .rd_empty  (fifo_empty)
    );

    // ---- AXI-Lite write FSM ---------------------------------------------
    // Accept AW and W INDEPENDENTLY.  The old FSM asserted awready only when
    // awvalid AND wvalid were high in the SAME cycle — which DEADLOCKS the Zynq
    // PS M_AXI_GP0 master, whose single stores assert AWVALID and wait for
    // AWREADY *before* driving WVALID.  The window's first ever real write (the
    // OS-image upload, 2026-07-17) hung the A9 hard on exactly this.  Now:
    // capture the address the cycle AW arrives (in-window only, so a foreign
    // $0xxx write is left entirely to xt_gp0_regs and its W is never stolen),
    // then take W, push, and respond.
    localparam WST_AW = 0, WST_W = 1, WST_B = 2;
    reg [1:0] wstate;

    always_ff @(posedge clk_sys) begin  // sync reset: rst_sys held post-lock; avoids async removal-hold
        if (rst_sys) begin
            wstate        <= WST_AW;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            fifo_push     <= 1'b0;
            push_addr     <= 16'd0;
            push_data     <= 8'd0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            fifo_push     <= 1'b0;

            case (wstate)
                // Wait for OUR address.  Assert awready on AW alone (no wait for
                // W) — that is the deadlock fix.  Out-of-window AW is ignored so
                // xt_gp0_regs owns the $0xxx transaction, W included.
                WST_AW: begin
                    if (s_axi_awvalid && write_in_window && !fifo_full) begin
                        s_axi_awready <= 1'b1;
                        push_addr     <= s_axi_awaddr[15:0];
                        wstate        <= WST_W;
                    end
                end
                // Now take the data (already valid, or arriving after AW), push
                // one byte to the CDC FIFO, and raise the B response.
                WST_W: begin
                    if (s_axi_wvalid) begin
                        s_axi_wready <= 1'b1;
                        push_data    <= s_axi_wstrb[0] ? s_axi_wdata[7:0]
                                      : s_axi_wstrb[1] ? s_axi_wdata[15:8]
                                      : s_axi_wstrb[2] ? s_axi_wdata[23:16]
                                                       : s_axi_wdata[31:24];
                        fifo_push    <= 1'b1;
                        wstate       <= WST_B;
                    end
                end
                WST_B: begin
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    // Clear ONLY once bvalid is actually asserted (registered
                    // high) AND accepted — never in the same cycle it first
                    // rises.  The Zynq PS holds BREADY high, so `if (bready)`
                    // alone would collapse bvalid to a zero-width pulse and the
                    // master would wait forever for a B response.
                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wstate       <= WST_AW;
                    end
                end
                default: wstate <= WST_AW;
            endcase
        end
    end

    // ---- AXI-Lite read FSM ----------------------------------------------
    // Write-only loader; reads in our window return 0 with OKAY so the
    // PS doesn't hang if it pokes at a ROM address.  Out-of-window
    // reads stay quiet so the blitter bridge can claim them.
    localparam RST_IDLE = 0, RST_R = 1;
    reg rstate;

    always_ff @(posedge clk_sys) begin  // sync reset: rst_sys held post-lock; avoids async removal-hold
        if (rst_sys) begin
            rstate        <= RST_IDLE;
            s_axi_arready <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
            s_axi_rvalid  <= 1'b0;
        end else begin
            s_axi_arready <= 1'b0;
            case (rstate)
                RST_IDLE: begin
                    if (s_axi_arvalid && read_in_window) begin
                        s_axi_arready <= 1'b1;
                        s_axi_rdata   <= 32'd0;
                        s_axi_rresp   <= 2'b00;
                        s_axi_rvalid  <= 1'b1;
                        rstate        <= RST_R;
                    end
                end
                RST_R: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rstate       <= RST_IDLE;
                    end
                end
                default: rstate <= RST_IDLE;
            endcase
        end
    end

    // ---- FIFO pop → rom_we pulse (clk_sally) ----------------------------
    // The FIFO's rd_data is combinational from mem[rd_ptr], so it's
    // valid on the same cycle as rd_empty=0.  Asserting rd_en this
    // cycle advances the pointer at the next posedge.  We latch the
    // current rd_data into rom_addr / rom_data and pulse rom_we for
    // one clk_sally cycle.
    always_ff @(posedge clk_sally or posedge rst_sally) begin
        if (rst_sally) begin
            rom_addr <= 16'd0;
            rom_data <= 8'd0;
            rom_we   <= 1'b0;
        end else begin
            rom_we <= 1'b0;
            if (!fifo_empty) begin
                rom_addr <= pop_word[23:8];
                rom_data <= pop_word[7:0];
                rom_we   <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
