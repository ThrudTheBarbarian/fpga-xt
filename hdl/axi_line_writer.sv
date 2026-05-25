// axi_line_writer.sv — AXI4 write master that streams one pixel row to DDR3.
//
// docs/video-architecture.md section 5 (ANTIC -> DDR3 writeback).  The mirror
// of plane_fetch: a producer fills an internal row buffer one RGBA pixel at a
// time; a `flush` pulse then DMAs `flush_w` pixels to a DDR3 byte address via
// AXI4 write bursts (16-beat × 8-byte beats = 2 RGBA px/beat).  One flush per
// Atari scanline; the integration layer sequences rows + double-buffering.
//
// The row buffer is filled, THEN flushed (not concurrently), so a
// combinational read on the write channel is safe.

`default_nettype none

module axi_line_writer #(
    parameter int MAX_W = 1024         // max pixels per row (row buffer depth)
) (
    input  wire        clk_sys,
    input  wire        rst_sys,

    // ---- Producer fill port (RGBA8888 per pixel) -------------------------
    input  wire        wr_en,
    input  wire [11:0] wr_col,
    input  wire [31:0] wr_pixel,

    // ---- Flush command ---------------------------------------------------
    input  wire        flush,          // 1-cycle pulse: DMA the row
    input  wire [31:0] flush_base,     // DDR3 byte address of the row start
    input  wire [11:0] flush_w,        // pixels to write
    output reg         busy,

    // ---- AXI4 write master ----------------------------------------------
    output reg  [31:0] m_axi_awaddr,
    output reg  [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [7:0]  m_axi_wstrb,
    output reg         m_axi_wlast,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready
);

    localparam int AW = $clog2(MAX_W);

    // ---- Row buffer (combinational read on the write path) ---------------
    (* ram_style = "distributed" *)
    logic [31:0] row_buf [0:MAX_W-1];
    always_ff @(posedge clk_sys) begin
        if (wr_en) row_buf[wr_col[AW-1:0]] <= wr_pixel;
    end

    // ---- Beat / burst bookkeeping ----------------------------------------
    logic [11:0] total_beats;          // ceil(flush_w / 2)
    logic [11:0] beat_global;          // beat index across the whole row
    logic [4:0]  burst_cnt;            // beat within the current burst
    logic [4:0]  burst_n;              // beats in the current burst (1..16)
    logic [31:0] base_q;

    // Two pixels per beat: cols 2*beat and 2*beat+1.
    wire [AW-1:0] col_lo = AW'({beat_global, 1'b0});
    wire [AW-1:0] col_hi = AW'({beat_global, 1'b1});
    assign m_axi_wdata  = {row_buf[col_hi], row_buf[col_lo]};
    assign m_axi_wstrb  = 8'hFF;
    assign m_axi_awsize  = 3'b011;     // 8 bytes/beat
    assign m_axi_awburst = 2'b01;      // INCR

    typedef enum logic [1:0] { S_IDLE, S_AW, S_W, S_B } state_t;
    state_t state;

    wire [11:0] beats_left = total_beats - beat_global;
    wire [4:0]  next_burst = (beats_left > 12'd16) ? 5'd16 : beats_left[4:0];

    assign m_axi_bready = (state == S_B);

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            total_beats   <= 12'd0;
            beat_global   <= 12'd0;
            burst_cnt     <= 5'd0;
            burst_n       <= 5'd0;
            base_q        <= 32'd0;
            m_axi_awaddr  <= 32'd0;
            m_axi_awlen   <= 8'd0;
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_wlast   <= 1'b0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (flush) begin
                        base_q      <= flush_base;
                        total_beats <= (flush_w + 12'd1) >> 1;
                        beat_global <= 12'd0;
                        busy        <= 1'b1;
                        state       <= S_AW;
                    end
                end
                S_AW: begin
                    m_axi_awaddr  <= base_q + ({20'd0, beat_global} << 3); // *8 bytes
                    m_axi_awlen   <= 8'(next_burst - 5'd1);
                    m_axi_awvalid <= 1'b1;
                    burst_n       <= next_burst;
                    burst_cnt     <= 5'd0;
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b1;
                        m_axi_wlast   <= (next_burst == 5'd1);
                        state         <= S_W;
                    end
                end
                S_W: begin
                    if (m_axi_wready) begin
                        if (burst_cnt == burst_n - 5'd1) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_wlast  <= 1'b0;
                            beat_global  <= beat_global + 12'd1;
                            state        <= S_B;
                        end else begin
                            burst_cnt    <= burst_cnt + 5'd1;
                            beat_global  <= beat_global + 12'd1;
                            m_axi_wlast  <= (burst_cnt == burst_n - 5'd2);
                        end
                    end
                end
                S_B: begin
                    if (m_axi_bvalid) begin
                        if (beat_global == total_beats) begin
                            busy  <= 1'b0;
                            state <= S_IDLE;
                        end else begin
                            state <= S_AW;     // next burst of the same row
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
