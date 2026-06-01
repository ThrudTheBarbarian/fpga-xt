// xl_buffer_ctrl.sv — triple-buffer index controller for the ANTIC→DDR XL surface.
//
// docs/video/video-architecture.md §5.  Decouples the ANTIC writeback (clk_sys, paced by
// the phi2 raster — NTSC ~59.92 Hz / PAL ~49.86 Hz) from the 1080p60 scan-out
// (clk_pix) so the compositor always reads a COMPLETE, stable frame.  Removes both
// display artifacts the single-front_sel double-buffer produced:
//   * the ~1 Hz tear  — front_sel flipped mid-scan-out (async to clk_pix), so the
//                        per-line plane_fetch jumped buffers mid-frame.
//   * the moving ghost — the consumer read a buffer the writeback was mid-write on.
//
// This is a MAILBOX (always-newest) triple buffer, NOT a render-ahead FIFO: the
// producer publishes its latest finished frame and the consumer adopts the
// newest-ready at its vblank.  There is no queue, so it adds AT MOST one display
// frame of latency (avg ~½ frame) — not the 1–2 frames a pre-rendered FIFO costs.
//
// Three buffer slots {0,1,2}:
//   write_idx    — the slot the writeback is filling now
//   ready_idx    — the most recently completed (published) slot
//   display_idx  — the slot the compositor reads (adopted at the scan-out vblank)
//
// On each producer frame_done the just-filled slot is published (ready_idx) and the
// next write target is chosen as a slot that is NEITHER the just-published one NOR
// the one currently being displayed.  Because display_idx is a clk_sys register
// here, that choice reads it natively — the producer never writes the displayed
// buffer, so write_idx ≠ display_idx holds at all times (the no-tear / no-corrupt
// invariant) regardless of the relative clock rates.
//
// CDC: a single 1-bit "adopt" toggle crosses clk_pix→clk_sys (cdc_sync_bit + edge
// detect).  display_idx then samples ready_idx natively in clk_sys, so no multi-bit
// value ever crosses a clock domain.

`default_nettype none

module xl_buffer_ctrl (
    // ---- Producer / display select (clk_sys) ---------------------------
    input  wire        clk_sys,
    input  wire        rst_sys,
    input  wire        frame_done,    // writeback finished a frame: publish + advance
    output reg  [1:0]  write_idx,     // slot the writeback should fill
    output reg  [1:0]  display_idx,   // slot the compositor should read

    // ---- Consumer adopt point (clk_pix) --------------------------------
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire        disp_vbi       // pulse: scan-out entered vblank → adopt newest
);

    reg [1:0] ready_idx;

    // ---- Consumer: toggle once per scan-out vblank (clk_pix) -----------
    reg adopt_tgl_pix;
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix)       adopt_tgl_pix <= 1'b0;
        else if (disp_vbi) adopt_tgl_pix <= ~adopt_tgl_pix;
    end

    // ---- CDC the toggle into clk_sys and edge-detect it ----------------
    wire adopt_tgl_sys;
    cdc_sync_bit u_adopt_sync (
        .dst_clk (clk_sys), .src_sig (adopt_tgl_pix), .dst_sig (adopt_tgl_sys)
    );
    reg  adopt_tgl_sys_q;
    wire adopt_sys = adopt_tgl_sys ^ adopt_tgl_sys_q;   // 1-cyc pulse per vblank

    // Lowest slot of {0,1,2} that is neither `a` nor `b`.  The two args are
    // always distinct (write_idx ≠ display_idx is invariant), so the result is
    // the unique free slot.
    function automatic logic [1:0] free_slot(input logic [1:0] a, input logic [1:0] b);
        if      (2'd0 != a && 2'd0 != b) free_slot = 2'd0;
        else if (2'd1 != a && 2'd1 != b) free_slot = 2'd1;
        else                             free_slot = 2'd2;
    endfunction

    // If we publish on the same cycle the consumer adopts, the buffer it is about
    // to display is the new ready_idx (= current write_idx), so exclude that.
    wire [1:0] eff_display = adopt_sys ? ready_idx : display_idx;

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            write_idx       <= 2'd0;
            ready_idx       <= 2'd1;
            display_idx     <= 2'd1;     // != write_idx at reset
            adopt_tgl_sys_q <= 1'b0;
        end else begin
            adopt_tgl_sys_q <= adopt_tgl_sys;

            // Publish the just-filled slot and pick the next write target.
            if (frame_done) begin
                ready_idx <= write_idx;
                write_idx <= free_slot(write_idx, eff_display);
            end

            // Adopt the newest published frame at the scan-out vblank.
            if (adopt_sys)
                display_idx <= ready_idx;
        end
    end

endmodule

`default_nettype wire
