// xt_trace_axi.sv — stream the 6502 instruction trace to DDR WITHOUT EVER
// HALTING THE CORE.
//
// WHY THIS EXISTS.  The original trace path (xt6502f_debug's STREAM ring) holds
// 4096 entries and, when full, folds `s_full` into `cpu_halt` so the A9 can drain
// it over GP0 registers.  That halt is real stop-the-world: everything OUTSIDE
// the core keeps running on wall-clock time, and the virtual SIO drive
// (docs/OS/sio-bridge.md §13) clocks bytes out while the guest is frozen.  The
// guest's POKEY then overruns and the disk load FAILS.  BallBlazer's intro plays
// *during* its load, so the one sequence we most need to observe is exactly the
// one the old tracer destroys — and a torn-load trace does not merely lose data,
// it tells a coherent and completely false story (it showed NMIs ceasing dead and
// the CPU stuck in a 4-instruction loop; the clean trace showed neither).
//
// So: no halt, no back-pressure onto the core.  Entries cross into clk_sys
// through a Gray-coded async FIFO and are burst to a DDR ring over an AXI4 write
// master.  If the FIFO ever fills, entries are DROPPED and COUNTED — a trace with
// a known gap is recoverable, a trace that silently changed the thing it measured
// is not.
//
// RATE.  The 6502 retires ~475k instructions/s (measured), = ~3.8 MB/s at 8 bytes
// per entry.  A 64-bit HP port at clk_sys moves that in well under 1% of its
// bandwidth, so `drops` should read zero in practice; a non-zero value means
// something is wrong with the DDR path, not with the trace.
//
// CDC NOTE.  cdc_fifo_1w1r is NOT reused here on purpose: it crosses BINARY
// pointers, which is safe for the infrequent register writes it was built for and
// unsafe for a sustained stream (a multi-bit counter sampled mid-increment is the
// recurring bug class in this project).  The pointers below are GRAY-coded, so
// exactly one bit changes per step and a mid-flight sample can only ever be the
// old or the new value.

`default_nettype none

module xt_trace_axi #(
    parameter int FIFO_AW = 9,          // 512 entries — ~1 ms of slack at 475k/s
    parameter int BURST   = 16          // beats per AXI burst (16 × 8B = 128B)
) (
    // ---- producer: the CPU's clock -------------------------------------
    input  wire        clk_cpu,
    input  wire        rst_cpu,
    input  wire        tr_valid,        // 1 cycle per retired instruction
    input  wire [63:0] tr_data,         // {Y,SP,P,IR} << 32 | {PC,A,X}

    // ---- consumer + AXI: clk_sys ---------------------------------------
    input  wire        clk_sys,
    input  wire        rst_sys,
    input  wire        en,              // level: 0 parks the engine and clears the ring
    input  wire [31:0] ring_base,       // DDR byte address, BURST*8 aligned
    input  wire [31:0] ring_mask,       // size-1, power-of-two ring in bytes
    output reg  [31:0] wr_bytes,        // total bytes written since enable
    output reg  [31:0] drops,           // entries lost to a full FIFO

    // ---- AXI4 write master ---------------------------------------------
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

    localparam int DEPTH = 1 << FIFO_AW;

    assign m_axi_awsize  = 3'b011;      // 8 bytes/beat
    assign m_axi_awburst = 2'b01;       // INCR
    assign m_axi_wstrb   = 8'hFF;
    assign m_axi_bready  = 1'b1;        // responses are not inspected: a dropped
                                        // write shows up as a gap, and `drops`
                                        // already reports the case we can act on

    function automatic [FIFO_AW:0] bin2gray(input [FIFO_AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // ---- storage: simple dual-port, write on clk_cpu, read on clk_sys ---
    (* ram_style = "block" *)
    logic [63:0] mem [0:DEPTH-1];

    // Read-side pointers are declared up here because the WRITE side samples
    // rptr_gray_x for its full test, and iverilog binds in declaration order.
    logic [FIFO_AW:0] rbin, rptr_gray_x;

    // ================= write side (clk_cpu) =============================
    logic [FIFO_AW:0] wbin, wgray;
    (* ASYNC_REG = "TRUE" *) logic [FIFO_AW:0] rgray_s1, rgray_s2;

    // "full" compares the NEXT write pointer against the synchronised read
    // pointer in Gray space: the classic MSB-and-next-MSB inversion test.
    wire [FIFO_AW:0] wbin_nxt  = wbin + 1'b1;
    wire [FIFO_AW:0] wgray_nxt = bin2gray(wbin_nxt);
    wire full = (wgray_nxt == {~rgray_s2[FIFO_AW:FIFO_AW-1],
                                rgray_s2[FIFO_AW-2:0]});

    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu) begin
            wbin <= '0; wgray <= '0; {rgray_s2, rgray_s1} <= '0;
        end else begin
            rgray_s1 <= rptr_gray_x;
            rgray_s2 <= rgray_s1;
            if (tr_valid && !full) begin
                mem[wbin[FIFO_AW-1:0]] <= tr_data;
                wbin  <= wbin_nxt;
                wgray <= wgray_nxt;
            end
        end
    end

    // drop counting lives in clk_cpu but is only ever READ by the A9 for
    // diagnosis, so it crosses without a handshake (a torn sample costs one
    // confusing read, never correctness).
    logic [31:0] drops_cpu;
    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu)                   drops_cpu <= 32'd0;
        else if (tr_valid && full)     drops_cpu <= drops_cpu + 32'd1;
    end
    (* ASYNC_REG = "TRUE" *) logic [31:0] drops_s1, drops_s2;
    always_ff @(posedge clk_sys) begin
        drops_s1 <= drops_cpu; drops_s2 <= drops_s1; drops <= drops_s2;
    end

    // ================= read side (clk_sys) ==============================
    (* ASYNC_REG = "TRUE" *) logic [FIFO_AW:0] wgray_s1, wgray_s2;

    // How many entries are readable, in binary, from the synchronised Gray
    // write pointer.  Converting Gray→binary on this side keeps the CROSSING
    // Gray while the arithmetic stays ordinary.
    function automatic [FIFO_AW:0] gray2bin(input [FIFO_AW:0] g);
        logic [FIFO_AW:0] b;
        b[FIFO_AW] = g[FIFO_AW];
        for (int i = FIFO_AW-1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        gray2bin = b;
    endfunction

    wire [FIFO_AW:0] wbin_sync = gray2bin(wgray_s2);
    wire [FIFO_AW:0] level     = wbin_sync - rbin;
    wire             have_burst = (level >= BURST[FIFO_AW:0]);

    // ---- burst engine ---------------------------------------------------
    typedef enum logic [1:0] { S_IDLE, S_ADDR, S_DATA } state_t;
    state_t     state;
    logic [4:0] beat;
    logic [31:0] ring_off;

    assign m_axi_wdata = mem[rbin[FIFO_AW-1:0]];

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            state <= S_IDLE; beat <= 5'd0; rbin <= '0; rptr_gray_x <= '0;
            ring_off <= 32'd0; wr_bytes <= 32'd0;
            m_axi_awvalid <= 1'b0; m_axi_wvalid <= 1'b0; m_axi_wlast <= 1'b0;
            m_axi_awaddr <= 32'd0; m_axi_awlen <= 8'd0;
            {wgray_s2, wgray_s1} <= '0;
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;

            if (!en) begin
                // parked: drop everything on the floor and re-arm at the base
                state <= S_IDLE; rbin <= wbin_sync; rptr_gray_x <= bin2gray(wbin_sync);
                ring_off <= 32'd0; wr_bytes <= 32'd0;
                m_axi_awvalid <= 1'b0; m_axi_wvalid <= 1'b0; m_axi_wlast <= 1'b0;
            end else case (state)
                S_IDLE: if (have_burst) begin
                    m_axi_awaddr  <= ring_base + ring_off;
                    m_axi_awlen   <= BURST[7:0] - 8'd1;
                    m_axi_awvalid <= 1'b1;
                    beat          <= 5'd0;
                    state         <= S_ADDR;
                end
                S_ADDR: if (m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_wlast   <= (BURST == 1);
                    state         <= S_DATA;
                end
                S_DATA: if (m_axi_wready) begin
                    // wdata is combinational on rbin, so advance the pointer as
                    // each beat is accepted; the NEXT entry is presented on the
                    // next cycle.
                    rbin        <= rbin + 1'b1;
                    rptr_gray_x <= bin2gray(rbin + 1'b1);
                    beat        <= beat + 5'd1;
                    m_axi_wlast <= (beat == BURST[4:0] - 5'd2);
                    if (beat == BURST[4:0] - 5'd1) begin
                        m_axi_wvalid <= 1'b0;
                        m_axi_wlast  <= 1'b0;
                        ring_off     <= (ring_off + BURST*8) & ring_mask;
                        wr_bytes     <= wr_bytes + BURST*8;
                        state        <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
