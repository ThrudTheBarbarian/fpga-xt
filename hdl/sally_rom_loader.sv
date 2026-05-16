// sally_rom_loader.sv — AXI-Lite slave bridging PS writes into
// sally_mem's `rom_we` / `rom_addr` / `rom_data` ports for boot-time
// ROM image loading.
//
// Bring-up Phase 7 prereq.  PS-side just does `memcpy(rom_window,
// rom_image, rom_image_size)` and SALLY's main BRAM ends up with the
// ROM image.  Write-only — no read-back path.
//
// Address layout (within the GP0 AXI-Lite window at $43C0_0000):
//   * Offsets $0000-$001F        -> belong to the blitter bridge.
//   * Offsets $0020-$FFFF (≈64 KB) -> ROM-init writes.  awaddr[15:0]
//     maps 1:1 to SALLY address (rom_addr = s_axi_awaddr[15:0]).
//
// SALLY ROM at $0000-$001F cannot be loaded this way; that's the
// zero-page scratch area and is RAM in any real Atari image anyway.
// If we ever need to write there, do it through a normal SALLY store
// at runtime, or extend this loader with a configurable blitter
// window.
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

    // Window predicate — anything OUTSIDE the blitter's 32-byte
    // sub-range belongs to us.
    wire write_in_window = (s_axi_awaddr[15:5] != 11'h000);
    wire read_in_window  = (s_axi_araddr[15:5] != 11'h000);

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
    localparam WST_IDLE = 0, WST_B = 1;
    reg wstate;

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            wstate        <= WST_IDLE;
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
                WST_IDLE: begin
                    if (s_axi_awvalid && s_axi_wvalid
                        && write_in_window && !fifo_full) begin
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;
                        push_addr     <= s_axi_awaddr[15:0];
                        push_data     <= s_axi_wstrb[0] ? s_axi_wdata[7:0]
                                       : s_axi_wstrb[1] ? s_axi_wdata[15:8]
                                       : s_axi_wstrb[2] ? s_axi_wdata[23:16]
                                                        : s_axi_wdata[31:24];
                        fifo_push     <= 1'b1;
                        wstate        <= WST_B;
                    end
                end
                WST_B: begin
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wstate       <= WST_IDLE;
                    end
                end
                default: wstate <= WST_IDLE;
            endcase
        end
    end

    // ---- AXI-Lite read FSM ----------------------------------------------
    // Write-only loader; reads in our window return 0 with OKAY so the
    // PS doesn't hang if it pokes at a ROM address.  Out-of-window
    // reads stay quiet so the blitter bridge can claim them.
    localparam RST_IDLE = 0, RST_R = 1;
    reg rstate;

    always_ff @(posedge clk_sys or posedge rst_sys) begin
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
