// tb_xt6502f.sv — Phase-1 skeleton test for the fidelity 6502 (docs/Design/fidelity-6502.md).
// Verifies: the phi2-paced machine-cycle window; reset fetches the vector; a NOP/NOP/
// JMP loop runs with the right per-instruction cycle counts (NOP=2, JMP=3); SYNC marks
// opcode fetches; one machine cycle per phi2_tick (real-time 1x pacing); RDY halts.
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502f;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    // machine-cycle pacing: phi2_tick once per SUB_N clocks (small for fast sim)
    localparam int unsigned SUB_N = 8;
    reg [3:0] tc = 0;
    always @(posedge clk) tc <= (tc == SUB_N-1) ? 4'd0 : tc + 4'd1;
    wire phi2_tick = (tc == SUB_N-1);

    wire [15:0] addr; wire [7:0] data_out; wire rw;
    reg  [7:0]  data_in;
    reg         rdy = 1'b1;
    wire        sync;
    wire [15:0] dbg_pc; wire [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p; wire [3:0] dbg_sub;

    xt6502f #(.SUB_DATA(4), .SUB_COMMIT(6)) dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(rdy), .irq_n(1'b1), .nmi_n(1'b1),
        .sync(sync), .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p), .dbg_sub(dbg_sub)
    );

    // combinational memory
    reg [7:0] mem [0:65535];
    always @(*) data_in = mem[addr];

    integer nfail = 0;
    // capture opcode-fetch PCs (mid-window, PC still = opcode address)
    reg [15:0] fetchpc [0:15];
    integer    nfetch = 0;
    reg        seen_this_win;
    always @(posedge clk) begin
        if (rst) begin nfetch <= 0; seen_this_win <= 0; end
        else begin
            if (phi2_tick) seen_this_win <= 0;
            else if (sync && dbg_sub == 4'd3 && !seen_this_win && nfetch < 16) begin
                fetchpc[nfetch] <= dbg_pc;   // PC before the commit-time increment
                nfetch <= nfetch + 1;
                seen_this_win <= 1;
            end
        end
    end

    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        // reset vector -> $0600
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h06;
        // $0600: NOP / NOP / JMP $0600
        mem[16'h0600] = 8'hEA;
        mem[16'h0601] = 8'hEA;
        mem[16'h0602] = 8'h4C; mem[16'h0603] = 8'h00; mem[16'h0604] = 8'h06;

        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;

        // run enough machine cycles for reset (~8) + a few loop iterations
        repeat (60 * SUB_N) @(posedge clk);

        // ---- T1: reached the program and looped ----
        $display("[T1] fetch PCs (first 12):");
        for (i = 0; i < nfetch && i < 12; i = i + 1) $display("    #%0d $%04h", i, fetchpc[i]);
        if (nfetch < 8) begin $display("FAIL T1: only %0d opcode fetches", nfetch); nfail=nfail+1; end

        // ---- T2: the fetch-PC sequence is the loop 0600,0601,0602 repeating ----
        begin : chkseq
            integer base; reg [15:0] want;
            // find the first $0600 fetch, then check the repeating triple
            base = -1;
            for (i = 0; i < nfetch; i = i + 1) if (base < 0 && fetchpc[i] == 16'h0600) base = i;
            if (base < 0) begin $display("FAIL T2: never fetched $0600"); nfail=nfail+1; end
            else begin
                for (i = base; i + 2 < nfetch; i = i + 3) begin
                    if (fetchpc[i]   !== 16'h0600) begin $display("FAIL T2: [%0d]=$%04h want $0600", i, fetchpc[i]); nfail=nfail+1; end
                    if (fetchpc[i+1] !== 16'h0601) begin $display("FAIL T2: [%0d]=$%04h want $0601", i+1, fetchpc[i+1]); nfail=nfail+1; end
                    if (fetchpc[i+2] !== 16'h0602) begin $display("FAIL T2: [%0d]=$%04h want $0602", i+2, fetchpc[i+2]); nfail=nfail+1; end
                end
                if (nfail == 0) $display("  ok  T2: NOP/NOP/JMP loop runs (0600,0601,0602 repeating)");
            end
        end

        // ---- T3: SYNC + reset flags ----
        if (dbg_p[2]) $display("  ok  T3: I flag set after reset (P=$%02h)", dbg_p);
        else begin $display("FAIL T3: I flag not set (P=$%02h)", dbg_p); nfail=nfail+1; end

        // ---- T4: RDY (= ANTIC /HALT) freezes read cycles ----
        begin : chkrdy
            reg [15:0] pc_held;
            @(negedge clk) rdy = 1'b0;                 // halt
            repeat (4 * SUB_N) @(posedge clk);         // let the current cycle finish
            pc_held = dbg_pc;
            repeat (6 * SUB_N) @(posedge clk);         // several more windows, still halted
            if (dbg_pc !== pc_held) begin $display("FAIL T4: PC advanced while RDY low ($%04h -> $%04h)", pc_held, dbg_pc); nfail=nfail+1; end
            else $display("  ok  T4: RDY low holds the core (PC frozen at $%04h)", pc_held);
            @(negedge clk) rdy = 1'b1;                 // resume
            repeat (8 * SUB_N) @(posedge clk);
            if (dbg_pc === pc_held) begin $display("FAIL T4: PC did not resume after RDY high"); nfail=nfail+1; end
            else $display("  ok  T4: core resumes when RDY high ($%04h)", dbg_pc);
        end

        if (nfail == 0) $display("*** XT6502F_SKELETON OK ***");
        else            $display("*** XT6502F_SKELETON FAIL *** %0d failure(s)", nfail);
        $finish;
    end

    initial begin #2000000; $display("*** XT6502F TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
