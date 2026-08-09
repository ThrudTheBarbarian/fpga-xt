// tb_xt6502f_harte.sv — cycle-exact validation of the fidelity 6502 against the
// Tom Harte "65x02" ProcessorTests (docs/Design/fidelity-6502.md §7). Reads a compact
// .vec (sim/harte/convert.py output), and for each case: loads RAM, injects the initial
// regs, runs the single instruction, and diffs BOTH the per-cycle bus trace AND the
// final regs+RAM against the ground-truth (visual6502-derived).
//   iverilog -g2012 -o /tmp/h.vvp -s tb_xt6502f_harte sim/tb_xt6502f_harte.sv hdl/xt6502f/xt6502f.sv
//   vvp /tmp/h.vvp +VEC=sim/harte/vec/ea.vec
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502f_harte;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    localparam int unsigned PHI2_HZ = 1_789_773;
    localparam int unsigned CLK_HZ  = 8 * PHI2_HZ;      // N = 8
    localparam int unsigned N       = CLK_HZ / PHI2_HZ;

    // tb drives phi2_tick + inject explicitly (a machine cycle = one N-clk window)
    reg phi2_tick = 0;
    reg dbg_load = 0; reg [15:0] dbg_pc_in; reg [7:0] dbg_a_in, dbg_x_in, dbg_y_in, dbg_s_in, dbg_p_in;

    wire [15:0] addr; wire [7:0] data_out; wire rw; wire sync;
    reg  [7:0]  data_in;
    wire [15:0] dbg_pc; wire [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p; wire [7:0] dbg_sub;
    wire [15:0] cyc_addr; wire [7:0] cyc_val; wire cyc_rw, cyc_valid;

    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(1'b1), .irq_n(1'b1), .nmi_n(1'b1),
        .sync(sync), .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p), .dbg_sub(dbg_sub),
        .dbg_load(dbg_load), .dbg_pc_in(dbg_pc_in), .dbg_a_in(dbg_a_in), .dbg_x_in(dbg_x_in),
        .dbg_y_in(dbg_y_in), .dbg_s_in(dbg_s_in), .dbg_p_in(dbg_p_in),
        .dbg_cyc_addr(cyc_addr), .dbg_cyc_val(cyc_val), .dbg_cyc_rw(cyc_rw), .dbg_cyc_valid(cyc_valid)
    );

    // memory: reads combinational; writes captured from the committed cycle
    reg [7:0] mem [0:65535];
    always @(*) data_in = mem[addr];
    always @(posedge clk) if (cyc_valid && !cyc_rw) mem[cyc_addr] <= cyc_val;

    // ---- one machine cycle = one N-clk window; optionally inject on the tick ----
    task mcycle(input do_load);
        integer j;
        begin
            @(negedge clk); phi2_tick = 1'b1; dbg_load = do_load;
            @(negedge clk); phi2_tick = 1'b0; dbg_load = 1'b0;
            for (j = 0; j < N-1; j = j + 1) @(negedge clk);   // rest of the window
        end
    endtask

    integer fd, r, ncase, c, k, nram, ncyc, nfram, fails, cyc_fail, st_fail;
    integer ipc, is, ia, ix, iy, ip, aa, vv, fpc, fs, fa, fx, fy, fp;
    // expected cycle + final-ram arrays (instructions touch few cells)
    integer ecaddr[0:15], ecval[0:15], ecrw[0:15];
    integer capa[0:15],  capv[0:15],  capr[0:15];
    integer frama[0:31], framv[0:31];
    reg [255:0] vecfile;

    initial begin
        if (!$value$plusargs("VEC=%s", vecfile)) begin $display("need +VEC=path"); $finish; end
        fd = $fopen(vecfile, "r");
        if (fd == 0) begin $display("cannot open %0s", vecfile); $finish; end
        r = $fscanf(fd, " %d", ncase);

        rst = 1; repeat (4) @(negedge clk); rst = 0; @(negedge clk);

        fails = 0;
        for (c = 0; c < ncase; c = c + 1) begin
            // ---- read one case ----
            r = $fscanf(fd, " %h %h %h %h %h %h", ipc, is, ia, ix, iy, ip);
            r = $fscanf(fd, " %d", nram);
            for (k = 0; k < nram; k = k + 1) begin r = $fscanf(fd, " %h %h", aa, vv); mem[aa] = vv[7:0]; end
            r = $fscanf(fd, " %d", ncyc);
            for (k = 0; k < ncyc; k = k + 1) r = $fscanf(fd, " %h %h %d", ecaddr[k], ecval[k], ecrw[k]);
            r = $fscanf(fd, " %h %h %h %h %h %h", fpc, fs, fa, fx, fy, fp);
            r = $fscanf(fd, " %d", nfram);
            for (k = 0; k < nfram; k = k + 1) r = $fscanf(fd, " %h %h", frama[k], framv[k]);

            // ---- inject + run the instruction, capturing each cycle ----
            dbg_pc_in = ipc[15:0]; dbg_a_in = ia[7:0]; dbg_x_in = ix[7:0];
            dbg_y_in = iy[7:0]; dbg_s_in = is[7:0]; dbg_p_in = ip[7:0];
            for (k = 0; k < ncyc; k = k + 1) begin
                mcycle(k == 0);                       // window 0 injects (the fetch)
                capa[k] = cyc_addr; capv[k] = cyc_val; capr[k] = cyc_rw;
            end

            // ---- compare cycles + final state ----
            cyc_fail = 0;
            for (k = 0; k < ncyc; k = k + 1)
                if (capa[k] !== ecaddr[k][15:0] || capv[k] !== ecval[k][7:0] || capr[k] !== ecrw[k][0])
                    cyc_fail = cyc_fail + 1;
            st_fail = 0;
            if (dbg_pc !== fpc[15:0]) st_fail = st_fail + 1;
            if (dbg_a  !== fa[7:0])   st_fail = st_fail + 1;
            if (dbg_x  !== fx[7:0])   st_fail = st_fail + 1;
            if (dbg_y  !== fy[7:0])   st_fail = st_fail + 1;
            if (dbg_s  !== fs[7:0])   st_fail = st_fail + 1;
            if (dbg_p  !== fp[7:0])   st_fail = st_fail + 1;
            for (k = 0; k < nfram; k = k + 1)
                if (mem[frama[k]] !== framv[k][7:0]) st_fail = st_fail + 1;

            if (cyc_fail || st_fail) begin
                fails = fails + 1;
                if (fails <= 6) begin
                    $display("FAIL case %0d (cyc_fail=%0d st_fail=%0d): init pc=$%04h op=$%02h",
                             c, cyc_fail, st_fail, ipc[15:0], mem[ipc]);
                    $display("   got  pc=$%04h a=$%02h x=$%02h y=$%02h s=$%02h p=$%02h",
                             dbg_pc, dbg_a, dbg_x, dbg_y, dbg_s, dbg_p);
                    $display("   want pc=$%04h a=$%02h x=$%02h y=$%02h s=$%02h p=$%02h",
                             fpc[15:0], fa[7:0], fx[7:0], fy[7:0], fs[7:0], fp[7:0]);
                    for (k = 0; k < ncyc; k = k + 1)
                        $display("   cyc%0d got[$%04h $%02h %0d] want[$%04h $%02h %0d]",
                                 k, capa[k], capv[k], capr[k], ecaddr[k][15:0], ecval[k][7:0], ecrw[k][0]);
                end
            end
        end
        $fclose(fd);
        if (fails == 0) $display("*** HARTE %0s OK — %0d/%0d cases pass ***", vecfile, ncase, ncase);
        else            $display("*** HARTE %0s: %0d/%0d FAIL ***", vecfile, fails, ncase);
        $finish;
    end

    initial begin #200000000; $display("*** HARTE TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
