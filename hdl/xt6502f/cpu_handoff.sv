// cpu_handoff.sv — the resident turbo<->fidelity hand-off FSM (docs/Design/
// dual-cpu-resident-mux.md §3-4). Two 6502 cores live in the fabric at once, share one
// sally_mem; a quasi-static `owner` bit hands the bus + cycle-enable from one to the other.
// The idle core is frozen (run=0 holds all its state). A switch quiesces the active core at
// its next INSTRUCTION BOUNDARY, snapshots {PC,A,X,Y,S,P}, injects it into the target, and
// flips ownership — a handful of clk_sally cycles, invisible to software. Memory (ZP, stack,
// RAM/ROM, I/O) is shared, so only the 6-register context moves.
//
// Generic snapshot/inject interface (per register, not packed): maps directly onto the
// fidelity core's dbg_load + dbg_*_in, and repacks onto the turbo core's dbg_wr/wpc/waxys/
// wpsh at integration. `*_run` are the per-core rdy-enables the top ANDs into each rdy.
`default_nettype none

module cpu_handoff (
    input  wire        clk,
    input  wire        rst,
    input  wire        switch_req,     // level from a GP0/CTRL bit (PS-owned); edge = switch to the other core

    // ---- per-core snapshot taps (each core's dbg_* outputs) ----
    input  wire        a_boundary,     // core A at an instruction boundary (sync / ST_FETCH)
    input  wire [15:0] a_pc, input wire [7:0] a_a, a_x, a_y, a_s, a_p,
    input  wire        b_boundary,
    input  wire [15:0] b_pc, input wire [7:0] b_a, b_x, b_y, b_s, b_p,

    // ---- outputs ----
    output reg         owner,          // 0 = core A owns the bus, 1 = core B
    output wire        a_run, b_run,   // per-core cycle-enable (AND into each core's rdy)
    output reg         a_load, b_load, // 1-cycle inject pulse into the target core
    output reg  [15:0] load_pc, output reg [7:0] load_a, load_x, load_y, load_s, load_p,
    output wire        switching       // a hand-off is in progress
);
    localparam [1:0] S_STEADY=2'd0, S_QUIESCE=2'd1, S_INJECT=2'd2, S_RELEASE=2'd3;
    reg [1:0] hs;
    reg       req_d;

    // the active core's boundary + snapshot, selected by owner
    wire        act_boundary = owner ? b_boundary : a_boundary;

    assign switching = (hs != S_STEADY);
    // active core runs in STEADY, and in QUIESCE until it reaches a boundary; then it (and the
    // idle core) are frozen through INJECT/RELEASE. The idle core is always frozen.
    wire own_run = (hs == S_STEADY) ? 1'b1 : (hs == S_QUIESCE) ? ~act_boundary : 1'b0;
    assign a_run = (owner == 1'b0) & own_run;
    assign b_run = (owner == 1'b1) & own_run;

    always @(posedge clk) begin
        if (rst) begin
            hs <= S_STEADY; owner <= 1'b0; req_d <= 1'b0;
            a_load <= 1'b0; b_load <= 1'b0;
            load_pc <= 0; load_a <= 0; load_x <= 0; load_y <= 0; load_s <= 0; load_p <= 0;
        end else begin
            req_d  <= switch_req;
            a_load <= 1'b0; b_load <= 1'b0;
            case (hs)
                S_STEADY: if (switch_req && !req_d) hs <= S_QUIESCE;    // rising edge -> begin switch
                S_QUIESCE: if (act_boundary) begin                     // snapshot the frozen boundary state
                    load_pc <= owner ? b_pc : a_pc;
                    load_a  <= owner ? b_a  : a_a;
                    load_x  <= owner ? b_x  : a_x;
                    load_y  <= owner ? b_y  : a_y;
                    load_s  <= owner ? b_s  : a_s;
                    load_p  <= owner ? b_p  : a_p;
                    hs <= S_INJECT;
                end
                S_INJECT: begin                                        // inject into the TARGET (the other core)
                    if (owner) a_load <= 1'b1; else b_load <= 1'b1;
                    hs <= S_RELEASE;
                end
                S_RELEASE: begin
                    owner <= ~owner;                                   // flip ownership; old core freezes in place
                    hs <= S_STEADY;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
