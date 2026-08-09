// xt_trng.sv — ring-oscillator true-random-number generator.
//
// Zynq-7000 has no PS TRNG (unlike UltraScale+), so entropy comes from the
// fabric: N free-running ring oscillators (odd LUT-inverter loops).  Each RO's
// frequency jitters independently (thermal/shot noise on the LUT+route delays);
// sampling the asynchronous RO bus with clk_sys captures that jitter, and
// XOR-reducing the N samples yields one raw entropy bit per clk_sys cycle.  A
// von-Neumann debias removes first-order bias and a 32-bit LFSR pool whitens /
// accumulates the result into a word software reads (and further mixes) to back
// /dev/urandom.  This is an entropy SOURCE, not a certified CSPRNG — the OS
// stirs it into its own pool rather than emitting it raw as crypto output.
//
// A combinational loop oscillates forever in an event simulator and hangs it, so
// `TRNG_SYNTH` (defined ONLY in the Vivado build, see vivado/build.tcl) selects
// the real ring oscillators.  Without it (every sim: tb_boot etc. elaborate the
// whole top) an LFSR stand-in drives the identical downstream datapath, so the
// integration TBs run and can still exercise the GP0 read path.
`default_nettype none
module xt_trng #(
    parameter int N_RO   = 24,    // ring oscillators (more = more entropy headroom)
    parameter int STAGES = 3      // inverter stages per RO (must be odd)
) (
    input  wire        clk,       // sample + pool clock (clk_sys — always-on, NOT clk_pix)
    input  wire        rst_n,
    output reg  [31:0] rnd,       // whitened pool snapshot (free-running)

    // ---- entropy accounting ---------------------------------------------
    // `rnd` is a free-running snapshot with no notion of freshness, and the
    // pool only absorbs ~32 debiased bits per microsecond (133 MHz raw, ~25%
    // von-Neumann yield, so ~128 clk per 32 bits).  A back-to-back AXI read is
    // 100-300 ns, so software can drain the pool 3-10x faster than it fills and
    // gets an LFSR-stretched value instead of fresh entropy — silently, because
    // everything after the von-Neumann stage is linear.  These outputs let the
    // consumer gate on real freshness instead of guessing.
    input  wire        rd_stb,    // 1-clk: TRNG_RND was read — consume, restart the count
    output reg  [5:0]  bits_avail,// debiased bits stirred since that read (saturates at 32)
    output wire        fresh      // bits_avail >= 32: a fully re-seeded word
);
    // ---- raw entropy bus -------------------------------------------------
    // ALLOW_COMBINATORIAL_LOOPS on the loop nets tells Vivado the feedback is
    // intentional (also downgraded in vivado/constraints/trng_comb_loops.xdc).
    (* allow_combinatorial_loops = "true" *) wire [N_RO-1:0] ro;
`ifdef TRNG_SYNTH
    // Real ring oscillators: odd inverter loops, protected from optimisation and
    // merging (dont_touch); the combinational feedback is explicitly permitted.
    genvar g, s;
    generate
        for (g = 0; g < N_RO; g++) begin : g_ro
            (* dont_touch = "true", allow_combinatorial_loops = "true" *) wire [STAGES:0] chain;
            assign chain[0] = ro[g];                       // close the loop
            for (s = 0; s < STAGES; s++) begin : g_inv
                (* dont_touch = "true" *)
                LUT1 #(.INIT(2'b01)) u_inv (.O(chain[s+1]), .I0(chain[s]));  // O = ~I0
            end
            assign ro[g] = chain[STAGES];                  // 3 inversions -> oscillates
        end
    endgenerate
`else
    // Simulation stand-in: N independent Fibonacci LFSRs clocked by `clk` stand in
    // for the async RO bus — no combinational loop, so the simulator doesn't hang.
    reg [N_RO-1:0] ro_sim;
    reg [15:0]     lfsr_sim [0:N_RO-1];
    integer k;
    initial begin
        ro_sim = {N_RO{1'b0}};
        for (k = 0; k < N_RO; k = k + 1) lfsr_sim[k] = 16'h1234 + k[15:0] * 16'h2971;
    end
    always @(posedge clk) begin
        for (k = 0; k < N_RO; k = k + 1) begin
            lfsr_sim[k] <= {lfsr_sim[k][14:0],
                            lfsr_sim[k][15]^lfsr_sim[k][13]^lfsr_sim[k][12]^lfsr_sim[k][10]};
            ro_sim[k]   <= lfsr_sim[k][15];
        end
    end
    assign ro = ro_sim;
`endif

    // ---- sample the async RO bus (the metastable capture IS the entropy) ---
    (* async_reg = "true" *) reg [N_RO-1:0] s1, s2;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin s1 <= {N_RO{1'b0}}; s2 <= {N_RO{1'b0}}; end
        else        begin s1 <= ro;           s2 <= s1;           end
    wire raw = ^s2;                                       // one raw entropy bit / clk

    // ---- von-Neumann debias: look at raw bits in pairs, emit only on 01/10 --
    reg have_first, first_bit, vn_bit, vn_valid;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin have_first <= 1'b0; vn_valid <= 1'b0; end
        else begin
            vn_valid <= 1'b0;
            if (!have_first) begin have_first <= 1'b1; first_bit <= raw; end
            else begin
                have_first <= 1'b0;
                if (first_bit != raw) begin vn_bit <= first_bit; vn_valid <= 1'b1; end
            end
        end

    // ---- whitening pool: 32-bit Galois LFSR (CRC-32 poly), stir per debiased bit
    reg [31:0] pool;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) pool <= 32'hDEADBEEF;
        else if (vn_valid)
            pool <= (pool[0] ? (pool >> 1) ^ 32'hEDB88320 : (pool >> 1)) ^ {31'b0, vn_bit};

    always @(posedge clk or negedge rst_n)
        if (!rst_n) rnd <= 32'h0;
        else        rnd <= pool;

    // Count debiased bits since the last consume.  Saturates at 32 — beyond a
    // full word there is nothing more to promise.  A read in the same cycle as
    // a stir counts the stir (the read samples `rnd`, registered from the pool
    // BEFORE this bit landed), so the reload starts from that bit.
    always @(posedge clk or negedge rst_n)
        if (!rst_n)          bits_avail <= 6'd0;
        else if (rd_stb)     bits_avail <= vn_valid ? 6'd1 : 6'd0;
        else if (vn_valid && bits_avail != 6'd32)
                             bits_avail <= bits_avail + 6'd1;

    assign fresh = (bits_avail == 6'd32);
endmodule
`default_nettype wire
