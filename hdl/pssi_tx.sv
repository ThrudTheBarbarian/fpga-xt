// pssi_tx.sv — PSSI master TX (FPGA → N6 forward bulk stream).
//
// Byte-stream input from any source (typically a DRAW serialiser),
// BRAM-backed ring buffer, 16-bit output with PIXCLK + DE driven
// at the PSSI sample rate (nominally 80 MHz on the N6, derived from
// the N6's HBA bus / 2.5). See docs/n6-migration.md "Channels" table
// and docs/n6-hdl-migration.md "Phase 1".
//
// This replaces rp_tx as the FPGA → off-chip forward bulk path.
// The wire format flowing through the byte FIFO is the VDI DRAW
// stream defined in docs/VDI-opcodes.md.
//
// Dual clock domain:
//   clk_wr   — writer side; typically clk_bus (~165 MHz). Bytes
//              enter through wr_byte/wr_we; wr_ready back-pressures
//              the source when the ring is full.
//   clk_pssi — read / output side; 80 MHz nominal. Pairs of bytes
//              are presented on pssi_data[15:0] each PIXCLK cycle,
//              qualified by pssi_de.
//
// Async FIFO uses the textbook gray-code-synchronised dual pointer
// scheme (Cummings, "Simulation and Synthesis Techniques for Async
// FIFO Design"). Pointer width is $clog2(RING_BYTES) + 1; the extra
// MSB distinguishes empty (pointers equal) from full (pointers
// differ only in MSB).
//
// Byte order on the wire:
//   Even-indexed bytes (ring offset 0, 2, 4, …) → pssi_data[7:0]
//   Odd-indexed bytes  (ring offset 1, 3, 5, …) → pssi_data[15:8]
//
// Pair-only emission: pssi_de asserts only when ≥2 bytes are available
// to drain. If a packet ends on an odd boundary, software is responsible
// for emitting a NOP (0x00) byte so the total stream is even-aligned.
// The FPGA never synthesises NOP padding on its own — doing so would
// race with the writer / reader CDC sync latency and inject spurious
// NOPs mid-stream when the writer is momentarily ahead of the reader's
// view of the fill level.
//
// Overflow: a write while wr_ready=0 sets wr_overflow_q (sticky;
// cleared by rst_wr). The write itself is dropped. Software polls
// wr_overflow_q via status register and treats it as a fatal
// protocol error.

`default_nettype none

module pssi_tx #(
    // Ring size in bytes. Must be a power of two. 16 KB = 16384 fits in
    // ~26 EBRs on Ti60 (5 Kb each). Default chosen per the Phase 1 budget
    // in docs/n6-hdl-migration.md.
    parameter int unsigned RING_BYTES = 16384
) (
    // ---------------- Writer side (clk_wr) ----------------
    input  wire                          clk_wr,
    input  wire                          rst_wr,
    input  wire [7:0]                    wr_byte,
    input  wire                          wr_we,
    output wire                          wr_ready,        // 1 = ring has space for >=1 byte
    output wire [$clog2(RING_BYTES):0]   wr_fill_level,   // best-effort fill (may lag by sync latency)
    output wire                          wr_overflow_q,   // sticky overflow flag
    input  wire                          wr_overflow_clear, // 1-cycle pulse to clear wr_overflow_q

    // ---------------- Reader / PSSI side (clk_pssi) ----------------
    input  wire        clk_pssi,
    input  wire        rst_pssi,
    output wire        pssi_pixclk,     // = clk_pssi (synth wrapper drives via ODDR/clock-out primitive)
    output logic       pssi_de,         // 1 = pssi_data carries a valid word this cycle
    output logic [15:0] pssi_data
);

    // ---- Constants -----------------------------------------------------
    localparam int IDX_W = $clog2(RING_BYTES);     // byte index width
    localparam int PTR_W = IDX_W + 1;              // pointer width with extra MSB

    // ---- BRAM ring storage --------------------------------------------
    // Inferred dual-port, dual-clock BRAM. Each port has its own clock.
    // Writes are 1 byte/cycle; reads are 2 bytes/cycle (so the read side
    // burns 2 read addresses per clk_pssi).
    logic [7:0] mem [0:RING_BYTES-1];

`ifdef VERIFY_RAM_INIT
    initial begin
        for (int i = 0; i < RING_BYTES; i++) mem[i] = 8'h00;
    end
`endif

    // ---- Domain-crossed pointer declarations (defined up front so the
    //      writer-domain block can read the rd-domain gray pointer
    //      without a forward reference) --------------------------------
    logic [PTR_W-1:0] wr_ptr_bin_q;       // writer-side binary pointer
    logic [PTR_W-1:0] wr_ptr_gray_q;      // writer-side gray pointer
    logic [PTR_W-1:0] rd_ptr_bin_q;       // reader-side binary pointer
    logic [PTR_W-1:0] rd_ptr_gray_rd_q;   // reader-side gray pointer

    // ---- Write side (clk_wr domain) -----------------------------------
    logic [PTR_W-1:0] rd_ptr_gray_sync;   // rd_ptr_gray, synced into wr domain

    // 2-FF synchroniser bringing rd_ptr_gray (in clk_pssi domain) into
    // clk_wr. We hold the gray-coded form; conversion to binary happens
    // combinationally for the fill/full comparisons below.
    logic [PTR_W-1:0] rd_ptr_gray_meta_q, rd_ptr_gray_sync_q;
    always_ff @(posedge clk_wr or posedge rst_wr) begin
        if (rst_wr) begin
            rd_ptr_gray_meta_q <= '0;
            rd_ptr_gray_sync_q <= '0;
        end else begin
            rd_ptr_gray_meta_q <= rd_ptr_gray_rd_q;
            rd_ptr_gray_sync_q <= rd_ptr_gray_meta_q;
        end
    end
    assign rd_ptr_gray_sync = rd_ptr_gray_sync_q;

    // Convert gray back to binary for fill computation. For a small pointer
    // width this is a cheap XOR cascade.
    function automatic [PTR_W-1:0] gray_to_bin(input [PTR_W-1:0] g);
        logic [PTR_W-1:0] b;
        b[PTR_W-1] = g[PTR_W-1];
        for (int i = PTR_W - 2; i >= 0; i--)
            b[i] = g[i] ^ b[i+1];
        return b;
    endfunction

    function automatic [PTR_W-1:0] bin_to_gray(input [PTR_W-1:0] b);
        return b ^ (b >> 1);
    endfunction

    wire [PTR_W-1:0] rd_ptr_bin_in_wr = gray_to_bin(rd_ptr_gray_sync);

    // Full when wr_ptr and rd_ptr differ only in the MSB (and the lower
    // bits match — i.e., the writer has wrapped exactly once relative to
    // the reader). Empty (writer view) is not needed in this domain.
    wire wr_full_w =  (wr_ptr_bin_q[PTR_W-1]     != rd_ptr_bin_in_wr[PTR_W-1])
                   && (wr_ptr_bin_q[PTR_W-2:0]   == rd_ptr_bin_in_wr[PTR_W-2:0]);

    assign wr_ready      = ~wr_full_w;
    assign wr_fill_level = wr_ptr_bin_q - rd_ptr_bin_in_wr;  // signed-modulo at PTR_W bits

    // Sticky overflow flag (per-write attempt while full).
    logic wr_overflow_qr;
    assign wr_overflow_q = wr_overflow_qr;

    // BRAM write — separate always_ff without async reset so Vivado can
    // infer a block/distributed RAM. The control registers below keep
    // their reset for proper startup behaviour.
    always_ff @(posedge clk_wr) begin
        if (wr_we && !wr_full_w)
            mem[wr_ptr_bin_q[IDX_W-1:0]] <= wr_byte;
    end

    always_ff @(posedge clk_wr or posedge rst_wr) begin
        if (rst_wr) begin
            wr_ptr_bin_q   <= '0;
            wr_ptr_gray_q  <= '0;
            wr_overflow_qr <= 1'b0;
        end else begin
            if (wr_we) begin
                if (wr_full_w) begin
                    // Drop write, set sticky overflow.
                    wr_overflow_qr <= 1'b1;
                end else begin
                    wr_ptr_bin_q  <= wr_ptr_bin_q + 1'b1;
                    wr_ptr_gray_q <= bin_to_gray(wr_ptr_bin_q + 1'b1);
                end
            end
            // Software-driven clear of the sticky overflow flag. If a
            // simultaneous WE attempt also fails, the new overflow takes
            // priority (the write is the dominant event this cycle).
            if (wr_overflow_clear && !(wr_we && wr_full_w))
                wr_overflow_qr <= 1'b0;
        end
    end

    // ---- Read side (clk_pssi domain) ----------------------------------
    logic [PTR_W-1:0] wr_ptr_gray_sync_q, wr_ptr_gray_meta_q;

    always_ff @(posedge clk_pssi or posedge rst_pssi) begin
        if (rst_pssi) begin
            wr_ptr_gray_meta_q <= '0;
            wr_ptr_gray_sync_q <= '0;
        end else begin
            wr_ptr_gray_meta_q <= wr_ptr_gray_q;
            wr_ptr_gray_sync_q <= wr_ptr_gray_meta_q;
        end
    end

    wire [PTR_W-1:0] wr_ptr_bin_in_rd = gray_to_bin(wr_ptr_gray_sync_q);

    // Bytes available (reader view). When difference is zero, ring is empty.
    wire [PTR_W-1:0] rd_avail_w = wr_ptr_bin_in_rd - rd_ptr_bin_q;
    wire             rd_have_pair = (rd_avail_w >= 2);

    // Pre-fetch the next pair when one is available. BRAM has 1-cycle
    // latency, so address+valid pipeline by one stage before driving
    // the output word.
    logic [IDX_W-1:0] rd_addr_lo_q, rd_addr_hi_q;
    logic [7:0]       rd_data_lo_q, rd_data_hi_q;
    logic             rd_word_valid_q;     // word issued this cycle (BRAM read in flight)
    logic             rd_word_valid_q_d;   // word arriving at output stage (BRAM data valid)

    always_ff @(posedge clk_pssi or posedge rst_pssi) begin
        if (rst_pssi) begin
            rd_ptr_bin_q       <= '0;
            rd_ptr_gray_rd_q   <= '0;
            rd_addr_lo_q       <= '0;
            rd_addr_hi_q       <= '0;
            rd_word_valid_q    <= 1'b0;
            rd_word_valid_q_d  <= 1'b0;
        end else begin
            if (rd_have_pair) begin
                rd_addr_lo_q     <= rd_ptr_bin_q[IDX_W-1:0];
                rd_addr_hi_q     <= rd_ptr_bin_q[IDX_W-1:0] + 1'b1;
                rd_word_valid_q  <= 1'b1;
                rd_ptr_bin_q     <= rd_ptr_bin_q + 2;
                rd_ptr_gray_rd_q <= bin_to_gray(rd_ptr_bin_q + 2);
            end else begin
                rd_word_valid_q  <= 1'b0;
            end
            rd_word_valid_q_d <= rd_word_valid_q;
        end
    end

    // BRAM dual-read on the read clock. (We treat the BRAM as having two
    // read ports clocked by clk_pssi; the write port is on clk_wr.
    // Efinity infers a true dual-port BRAM with mixed clocks from this
    // pattern.)
    always_ff @(posedge clk_pssi) begin
        rd_data_lo_q <= mem[rd_addr_lo_q];
        rd_data_hi_q <= mem[rd_addr_hi_q];
    end

    // Output stage: present the word.
    always_ff @(posedge clk_pssi or posedge rst_pssi) begin
        if (rst_pssi) begin
            pssi_de   <= 1'b0;
            pssi_data <= 16'h0000;
        end else begin
            pssi_de   <= rd_word_valid_q_d;
            pssi_data <= {rd_data_hi_q, rd_data_lo_q};
        end
    end

    // PIXCLK is just the read clock — the synth wrapper drives it onto a
    // pad via ODDR / clock-out primitive. In sim we expose it directly.
    assign pssi_pixclk = clk_pssi;

endmodule

`default_nettype wire
