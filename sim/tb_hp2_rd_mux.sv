// tb_hp2_rd_mux.sv — exercises the shared-HP2 read arbiter.
//
// Models an in-order HP read slave (accepts up to SLAVE_DEPTH outstanding ARs,
// returns R bursts in AR-accept order after a latency).  Drives both masters
// pipelined (multiple ARs in flight) and concurrently (contention), then checks
// every master receives exactly its own bursts, in its own issue order, with the
// correct data (R data low word = the burst's araddr) — i.e. no mis-routing and
// pipelining is preserved.
`default_nettype none
`timescale 1ns / 1ps

module tb_hp2_rd_mux;
    localparam int OUTSTANDING = 8;
    localparam int SLAVE_DEPTH = 8;

    logic clk = 0; always #5 clk = ~clk;
    logic rst = 1;

    // master 0 (overlay)
    logic [31:0] s0_araddr; logic [7:0] s0_arlen; logic s0_arvalid; wire s0_arready;
    wire  [63:0] s0_rdata;  wire s0_rvalid, s0_rlast; logic s0_rready;
    // master 1 (sprite)
    logic [31:0] s1_araddr; logic [7:0] s1_arlen; logic s1_arvalid; wire s1_arready;
    wire  [63:0] s1_rdata;  wire s1_rvalid, s1_rlast; logic s1_rready;
    // shared m -> slave
    wire  [31:0] m_araddr; wire [7:0] m_arlen; wire [2:0] m_arsize; wire [1:0] m_arburst;
    wire         m_arvalid; logic m_arready;
    logic [63:0] m_rdata;  logic m_rvalid, m_rlast; wire m_rready;

    hp2_rd_mux #(.OUTSTANDING(OUTSTANDING)) dut (
        .clk(clk), .rst(rst),
        .s0_araddr(s0_araddr), .s0_arlen(s0_arlen), .s0_arsize(3'b011), .s0_arburst(2'b01),
        .s0_arvalid(s0_arvalid), .s0_arready(s0_arready),
        .s0_rdata(s0_rdata), .s0_rvalid(s0_rvalid), .s0_rlast(s0_rlast), .s0_rready(s0_rready),
        .s1_araddr(s1_araddr), .s1_arlen(s1_arlen), .s1_arsize(3'b011), .s1_arburst(2'b01),
        .s1_arvalid(s1_arvalid), .s1_arready(s1_arready),
        .s1_rdata(s1_rdata), .s1_rvalid(s1_rvalid), .s1_rlast(s1_rlast), .s1_rready(s1_rready),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rvalid(m_rvalid), .m_rlast(m_rlast), .m_rready(m_rready)
    );

    // ---- in-order HP read slave model -----------------------------------
    localparam int QD = 16;
    logic [31:0] q_addr [0:QD-1];
    logic [7:0]  q_len  [0:QD-1];
    int qhead = 0, qtail = 0, qcount = 0;
    int max_outstanding_seen = 0;

    assign m_arready = (qcount < SLAVE_DEPTH);

    // AR accept: enqueue
    always_ff @(posedge clk) begin
        if (rst) begin qhead<=0; qtail<=0; qcount<=0; end
        else begin
            // pop handled in the R process via qcount-- ; coordinate via flags
        end
    end

    // Single process drives AR-enqueue + R-burst return (keeps qcount coherent).
    int beat;        // beats emitted for the current head burst
    int lat;         // latency countdown before the head burst starts returning
    always_ff @(posedge clk) begin
        if (rst) begin
            qhead<=0; qtail<=0; qcount<=0; beat<=0; lat<=3;
            m_rvalid<=0; m_rlast<=0; m_rdata<=0;
        end else begin
            // enqueue an accepted AR
            if (m_arvalid && m_arready) begin
                q_addr[qtail] <= m_araddr;
                q_len [qtail] <= m_arlen;
                qtail <= (qtail+1) % QD;
                if (qcount+1 > max_outstanding_seen) max_outstanding_seen <= qcount+1;
            end
            // return R for the head burst
            if (qcount > 0 || (m_arvalid && m_arready)) begin
                if (!m_rvalid) begin
                    if (lat > 0) lat <= lat - 1;
                    else begin
                        m_rvalid <= 1'b1;
                        m_rdata  <= {32'(beat), q_addr[qhead]};
                        m_rlast  <= (beat == q_len[qhead]);
                    end
                end else if (m_rready) begin
                    if (m_rlast) begin
                        m_rvalid <= 1'b0; m_rlast <= 1'b0; beat <= 0; lat <= 2;
                        qhead <= (qhead+1) % QD;
                    end else begin
                        beat <= beat + 1;
                        m_rdata <= {32'(beat+1), q_addr[qhead]};
                        m_rlast <= (beat+1 == q_len[qhead]);
                    end
                end
            end
            // net qcount: +accept -burst_done
            qcount <= qcount + ((m_arvalid&&m_arready)?1:0) - ((m_rvalid&&m_rready&&m_rlast)?1:0);
        end
    end

    // ---- master driver + scoreboard -------------------------------------
    int fail = 0;
    localparam int NBURST = 12;

    // expected next-addr each master should receive (in issue order)
    int s0_exp = 0, s1_exp = 0;
    logic [31:0] s0_addr_base = 32'h1000_0000;
    logic [31:0] s1_addr_base = 32'h2000_0000;

    // master 0: issue NBURST pipelined ARs (addr = base + i*64)
    initial begin
        s0_araddr=0; s0_arlen=8'd7; s0_arvalid=0; s0_rready=1;
        @(negedge rst);
        for (int i=0;i<NBURST;i++) begin
            s0_araddr <= s0_addr_base + (i*64);
            s0_arlen  <= 8'd7;
            s0_arvalid<= 1'b1;
            @(posedge clk);
            while (!s0_arready) @(posedge clk);   // hold until accepted
        end
        s0_arvalid <= 1'b0;
    end
    // master 0 R check: first beat of each burst must carry its expected addr
    always_ff @(posedge clk) begin
        if (!rst && s0_rvalid && s0_rready && (s0_rdata[63:32]==0)) begin
            if (s0_rdata[31:0] !== (s0_addr_base + s0_exp*64)) begin
                $display("FAIL s0: burst %0d got addr %08h exp %08h", s0_exp, s0_rdata[31:0], s0_addr_base+s0_exp*64);
                fail++;
            end
            if (s0_rvalid && s0_rlast) s0_exp <= s0_exp + 1;
        end else if (!rst && s0_rvalid && s0_rready && s0_rlast) s0_exp <= s0_exp + 1;
    end

    // master 1: same, staggered start so the two interleave
    initial begin
        s1_araddr=0; s1_arlen=8'd7; s1_arvalid=0; s1_rready=1;
        @(negedge rst);
        repeat (3) @(posedge clk);
        for (int i=0;i<NBURST;i++) begin
            s1_araddr <= s1_addr_base + (i*64);
            s1_arlen  <= 8'd7;
            s1_arvalid<= 1'b1;
            @(posedge clk);
            while (!s1_arready) @(posedge clk);
        end
        s1_arvalid <= 1'b0;
    end
    always_ff @(posedge clk) begin
        if (!rst && s1_rvalid && s1_rready && (s1_rdata[63:32]==0)) begin
            if (s1_rdata[31:0] !== (s1_addr_base + s1_exp*64)) begin
                $display("FAIL s1: burst %0d got addr %08h exp %08h", s1_exp, s1_rdata[31:0], s1_addr_base+s1_exp*64);
                fail++;
            end
            if (s1_rvalid && s1_rlast) s1_exp <= s1_exp + 1;
        end else if (!rst && s1_rvalid && s1_rready && s1_rlast) s1_exp <= s1_exp + 1;
    end

    initial begin
        repeat (5) @(posedge clk); rst <= 0;
        // wait for both masters to receive all bursts
        wait (s0_exp == NBURST && s1_exp == NBURST);
        repeat (5) @(posedge clk);
        if (fail==0 && max_outstanding_seen >= 2)
            $display("*** HP2_RD_MUX OK *** s0=%0d s1=%0d bursts, max_outstanding=%0d", s0_exp, s1_exp, max_outstanding_seen);
        else
            $display("*** HP2_RD_MUX FAIL *** fails=%0d s0=%0d s1=%0d max_outstanding=%0d (need >=2)", fail, s0_exp, s1_exp, max_outstanding_seen);
        $finish;
    end

    initial begin #500000; $display("FAIL: tb_hp2_rd_mux watchdog"); $finish; end
endmodule

`default_nettype wire
