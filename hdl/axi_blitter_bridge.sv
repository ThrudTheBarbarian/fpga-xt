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
    input  wire [15:0] bl_seq_counter      // returned at SEQ_LO/HI ($D4C9/CA, offsets 0x19/0x1A)
);

    // ====================================================================
    // AXI4-Lite write transaction FSM
    // ====================================================================
    localparam WST_IDLE  = 0,
               WST_WRITE = 1;

    reg [1:0]  wstate;

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
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            bl_we         <= 1'b0;

            unique case (wstate)
                WST_IDLE: begin
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;

                        // Map AXI byte offset to blitter reg_addr:
                        //   0x00..0x0F -> bl_addr[5]=0 ($D4Bx page)
                        //   0x10..0x1F -> bl_addr[5]=1 ($D4Cx page)
                        bl_addr <= {~s_axi_awaddr[4], s_axi_awaddr[3:0]};

                        // Extract first byte from whichever lane is active
                        if (s_axi_wstrb[0])
                            bl_data <= s_axi_wdata[7:0];
                        else if (s_axi_wstrb[1])
                            bl_data <= s_axi_wdata[15:8];
                        else if (s_axi_wstrb[2])
                            bl_data <= s_axi_wdata[23:16];
                        else
                            bl_data <= s_axi_wdata[31:24];

                        wstate <= WST_WRITE;
                    end
                end

                WST_WRITE: begin
                    bl_we <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    s_axi_bvalid <= 1'b1;
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wstate <= WST_IDLE;
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
                    if (s_axi_arvalid) begin
                        s_axi_arready <= 1'b1;
                        // Return STATUS bits on read at offset 0x0D:
                        //   bit 0 = bl_busy (queue non-empty OR FSM active)
                        //   bit 1 = bl_queue_full (next CMD write dropped)
                        //   bit 2 = bl_pat_blocked (sticky: pat/font load
                        //           dropped while busy; clears on busy=0)
                        // SEQ counter at offsets 0x19 (lo byte) / 0x1A (hi).
                        if (s_axi_araddr[7:0] == 8'h0D)
                            s_axi_rdata <= {29'b0, bl_pat_blocked,
                                                  bl_queue_full,
                                                  bl_busy};
                        else if (s_axi_araddr[7:0] == 8'h19)
                            s_axi_rdata <= {24'b0, bl_seq_counter[7:0]};
                        else if (s_axi_araddr[7:0] == 8'h1A)
                            s_axi_rdata <= {24'b0, bl_seq_counter[15:8]};
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
