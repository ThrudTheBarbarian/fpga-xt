`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_pf_geom — playfield width, start, stop and HSCROL.
//
// T1 is the cross-check that matters: for all 14 display modes at all three
// widths, bytes_per_line * (8/bpp) * px_width must equal the hi-res pixel count.
// It ties this module to antic_mode_tbl, and any mistake in either shows up as
// a line that is not 256/320/384 pixels wide.
//
// T3 pins the centring that antic_pfstarttiming and antic_pfstoptiming measure
// together: a narrow playfield is inset by 8 machine cycles at BOTH ends. Get
// only the start right and pfstoptiming still fails.
//
module tb_antic_pf_geom;

    logic [1:0] pf_width;
    logic       hscrol_en;
    logic [3:0] hscrol;
    logic       is_char;
    logic [1:0] bpp;
    logic [3:0] px_width;

    wire        pf_on;
    wire [7:0]  bytes_per_line, pf_step;
    wire [6:0]  dma_start, dma_stop, disp_start, disp_stop;
    wire [2:0]  hs_delay;
    wire        hs_fine;

    antic_pf_geom dut (
        .pf_width(pf_width), .hscrol_en(hscrol_en), .hscrol(hscrol),
        .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .pf_on(pf_on), .bytes_per_line(bytes_per_line), .pf_step(pf_step),
        .dma_start(dma_start), .dma_stop(dma_stop),
        .disp_start(disp_start), .disp_stop(disp_stop),
        .hs_delay(hs_delay), .hs_fine(hs_fine)
    );

    // The mode table drives the shape, so the invariant tests the pair.
    logic [3:0] m;
    wire        t_is_char, t_descender, t_is_display;
    wire [1:0]  t_bpp;
    wire [3:0]  t_px_width;
    wire [4:0]  t_rows;

    antic_mode_tbl u_tbl (
        .mode(m), .is_char(t_is_char), .bpp(t_bpp), .px_width(t_px_width),
        .rows(t_rows), .descender(t_descender), .is_display(t_is_display)
    );

    int fail = 0;
    int want_px, got_px;

    initial begin
        pf_width = 2'd2; hscrol_en = 0; hscrol = 4'd0;
        is_char = 0; bpp = 2'd1; px_width = 4'd1; m = 4'h2;

        // ================================================================
        // T1: the 320 invariant, every display mode at every width
        // ================================================================
        hscrol_en = 0;
        for (int w = 1; w <= 3; w++) begin
            pf_width = 2'(w);
            want_px  = (w == 1) ? 256 : (w == 2) ? 320 : 384;
            for (int mm = 2; mm <= 15; mm++) begin
                m = 4'(mm); #1;
                is_char = t_is_char; bpp = t_bpp; px_width = t_px_width; #1;
                got_px = int'(bytes_per_line) * (8 / int'(bpp)) * int'(px_width);
                if (got_px != want_px) begin
                    $display("FAIL T1: mode %0h width %0d -> %0d bytes = %0d px, expected %0d",
                             mm, w, bytes_per_line, got_px, want_px);
                    fail++;
                end
            end
        end

        // A few named values, so a wrong-but-self-consistent table is caught.
        m = 4'h2; #1; is_char = t_is_char; bpp = t_bpp; px_width = t_px_width;
        pf_width = 2'd2; #1;
        if (bytes_per_line !== 8'd40) begin
            $display("FAIL T1b: mode 2 normal = %0d bytes, expected 40", bytes_per_line);
            fail++;
        end
        m = 4'h8; #1; is_char = t_is_char; bpp = t_bpp; px_width = t_px_width; #1;
        if (bytes_per_line !== 8'd10) begin
            $display("FAIL T1c: mode 8 normal = %0d bytes, expected 10", bytes_per_line);
            fail++;
        end
        m = 4'hF; #1; is_char = t_is_char; bpp = t_bpp; px_width = t_px_width;
        pf_width = 2'd1; #1;
        if (bytes_per_line !== 8'd32) begin
            $display("FAIL T1d: mode F narrow = %0d bytes, expected 32", bytes_per_line);
            fail++;
        end

        // ================================================================
        // T2: width 0 turns the playfield off entirely
        // ================================================================
        pf_width = 2'd0; #1;
        if (pf_on) begin
            $display("FAIL T2: DMACTL width 0 still reports pf_on"); fail++;
        end
        if (bytes_per_line !== 8'd0) begin
            $display("FAIL T2b: width 0 asks for %0d bytes", bytes_per_line); fail++;
        end
        if (disp_start !== 7'd0 || disp_stop !== 7'd0) begin
            $display("FAIL T2c: width 0 left a display window %0d..%0d",
                     disp_start, disp_stop);
            fail++;
        end

        // ================================================================
        // T3: the display window, and its centring
        // ================================================================
        pf_width = 2'd1; #1;
        if (disp_start !== 7'd28 || disp_stop !== 7'd92) begin
            $display("FAIL T3: narrow window %0d..%0d, expected 28..92",
                     disp_start, disp_stop);
            fail++;
        end
        pf_width = 2'd2; #1;
        if (disp_start !== 7'd20 || disp_stop !== 7'd100) begin
            $display("FAIL T3b: normal window %0d..%0d, expected 20..100",
                     disp_start, disp_stop);
            fail++;
        end
        pf_width = 2'd3; #1;
        if (disp_start !== 7'd12 || disp_stop !== 7'd108) begin
            $display("FAIL T3c: wide window %0d..%0d, expected 12..108",
                     disp_start, disp_stop);
            fail++;
        end
        // All three centred on cycle 60: narrow is inset at BOTH ends, which is
        // what pfstoptiming checks and a start-only fix misses.
        for (int w = 1; w <= 3; w++) begin
            pf_width = 2'(w); #1;
            if ((int'(disp_start) + int'(disp_stop)) != 120) begin
                $display("FAIL T3d: width %0d window %0d..%0d is not centred on 60",
                         w, disp_start, disp_stop);
                fail++;
            end
        end
        // ...and the span matches the pixel count: 4 hi-res px per machine cycle.
        for (int w = 1; w <= 3; w++) begin
            pf_width = 2'(w); #1;
            want_px = (w == 1) ? 256 : (w == 2) ? 320 : 384;
            if ((int'(disp_stop) - int'(disp_start)) * 4 != want_px) begin
                $display("FAIL T3e: width %0d spans %0d cycles = %0d px, expected %0d",
                         w, disp_stop - disp_start,
                         (disp_stop - disp_start) * 4, want_px);
                fail++;
            end
        end

        // ================================================================
        // T4: character modes start their DMA two cycles early
        // ================================================================
        pf_width = 2'd2; is_char = 1'b1; #1;
        if (dma_start !== 7'd18) begin
            $display("FAIL T4: char normal DMA starts %0d, expected 18", dma_start);
            fail++;
        end
        is_char = 1'b0; #1;
        if (dma_start !== 7'd20) begin
            $display("FAIL T4b: bitmap normal DMA starts %0d, expected 20", dma_start);
            fail++;
        end
        pf_width = 2'd1; is_char = 1'b1; #1;
        if (dma_start !== 7'd26) begin
            $display("FAIL T4c: char narrow DMA starts %0d, expected 26", dma_start);
            fail++;
        end
        pf_width = 2'd3; #1;
        if (dma_start !== 7'd10) begin
            $display("FAIL T4d: char wide DMA starts %0d, expected 10", dma_start);
            fail++;
        end
        // The DISPLAY start does not move with is_char — only the fetch does.
        pf_width = 2'd2; is_char = 1'b1; #1;
        want_px = int'(disp_start);
        is_char = 1'b0; #1;
        if (int'(disp_start) != want_px) begin
            $display("FAIL T4e: display start moved with is_char (%0d -> %0d)",
                     want_px, disp_start);
            fail++;
        end

        // ================================================================
        // T5: HSCROL splits into whole cycles and one odd colour clock
        // ================================================================
        for (int h = 0; h < 16; h++) begin
            hscrol = 4'(h); #1;
            if (int'(hs_delay) != h / 2) begin
                $display("FAIL T5: HSCROL %0d gave delay %0d, expected %0d",
                         h, hs_delay, h / 2);
                fail++;
            end
            if (hs_fine !== 1'((h % 2))) begin
                $display("FAIL T5b: HSCROL %0d gave fine %0b, expected %0b",
                         h, hs_fine, h % 2);
                fail++;
            end
        end
        hscrol = 4'd0;

        // ================================================================
        // T6: scrolling fetches one width up but displays the same window
        // ================================================================
        m = 4'h2; #1; is_char = t_is_char; bpp = t_bpp; px_width = t_px_width;
        pf_width = 2'd1; hscrol_en = 0; #1;
        if (bytes_per_line !== 8'd32) begin
            $display("FAIL T6: narrow unscrolled = %0d bytes, expected 32",
                     bytes_per_line);
            fail++;
        end
        hscrol_en = 1; #1;
        if (bytes_per_line !== 8'd40) begin
            $display("FAIL T6b: narrow scrolled = %0d bytes, expected 40 (fetches normal)",
                     bytes_per_line);
            fail++;
        end
        if (disp_start !== 7'd28 || disp_stop !== 7'd92) begin
            $display("FAIL T6c: scrolling widened the DISPLAY window to %0d..%0d",
                     disp_start, disp_stop);
            fail++;
        end
        pf_width = 2'd2; #1;
        if (bytes_per_line !== 8'd48) begin
            $display("FAIL T6d: normal scrolled = %0d bytes, expected 48 (fetches wide)",
                     bytes_per_line);
            fail++;
        end
        // Wide has nowhere to grow to.
        pf_width = 2'd3; #1;
        if (bytes_per_line !== 8'd48) begin
            $display("FAIL T6e: wide scrolled = %0d bytes, expected 48 (stays wide)",
                     bytes_per_line);
            fail++;
        end

        // ================================================================
        // T7: the antic_hscrolbug oracle, verbatim
        // ================================================================
        // The test prints ANTIC's own DMA map for a scrolled NARROW mode E:
        // forty fetches at cycles 20, 22 ... 98.  That is the NORMAL window,
        // so widening the fetch moves the fetch WINDOW too — while the
        // display window stays narrow.
        m = 4'hE; #1; is_char = t_is_char; bpp = t_bpp; px_width = t_px_width;
        pf_width = 2'd1; hscrol_en = 1; hscrol = 4'd0; #1;
        if (bytes_per_line !== 8'd40) begin
            $display("FAIL T7: scrolled narrow mode E = %0d bytes, the oracle shows 40",
                     bytes_per_line);
            fail++;
        end
        if (dma_start !== 7'd20) begin
            $display("FAIL T7b: scrolled narrow mode E fetches from cycle %0d, the oracle shows 20",
                     dma_start);
            fail++;
        end
        if (dma_stop !== 7'd100) begin
            $display("FAIL T7c: scrolled narrow mode E fetch ends %0d, the oracle's last fetch is 98",
                     dma_stop);
            fail++;
        end
        // Mode E takes one fetch per two machine cycles, so the window has to
        // hold exactly bytes_per_line of them: 20,22...98.
        if ((int'(dma_stop) - int'(dma_start)) / 2 != int'(bytes_per_line)) begin
            $display("FAIL T7d: %0d-cycle fetch window holds %0d fetches, not %0d bytes",
                     dma_stop - dma_start, (dma_stop - dma_start) / 2, bytes_per_line);
            fail++;
        end
        // The DISPLAY window must still be the narrow one.
        if (disp_start !== 7'd28 || disp_stop !== 7'd92) begin
            $display("FAIL T7e: scrolling widened the display window to %0d..%0d",
                     disp_start, disp_stop);
            fail++;
        end
        hscrol_en = 0;

        // ================================================================
        // T7f: HSCROL DELAYS THE FETCH WINDOW, not just the display one
        // ================================================================
        // emu's spec_window does TWO things to a scrolled row: it steps the
        // fetch width up one (T7, above) AND it adds `off = (hscrol & 14) >> 1`
        // to BOTH edges -- `*start = st + off; *vend = st + span + off`.  T7
        // only ever runs at HSCROL 0, where the offset is zero and invisible,
        // so nothing above this line can tell the two apart.
        //
        // The odd bit is the FINE colour clock and belongs to the display, not
        // to the fetch grid, which is why the mask is 14 and not 15: HSCROL 4
        // and 5 delay the fetch by the same two machine cycles.
        m = 4'hE; #1; is_char = t_is_char; bpp = t_bpp; px_width = t_px_width;
        pf_width = 2'd1; hscrol_en = 1;
        for (int h = 0; h < 16; h++) begin
            hscrol = 4'(h); #1;
            if (int'(dma_start) != 20 + (h / 2)) begin
                $display("FAIL T7f: HSCROL %0d starts the fetch at %0d, expected %0d",
                         h, dma_start, 20 + (h / 2));
                fail++;
            end
            if (int'(dma_stop) != 100 + (h / 2)) begin
                $display("FAIL T7g: HSCROL %0d stops the fetch at %0d, expected %0d",
                         h, dma_stop, 100 + (h / 2));
                fail++;
            end
        end
        hscrol = 4'd0;
        hscrol_en = 0;

        // ================================================================
        // T8: the fetch step is span/bytes -- as a shift, not a division
        // ================================================================
        // Writing this as a divide cost 22 carry chains and a 17ns path off
        // the mode register: the whole of a -9.7ns clk_sys violation.
        hscrol_en = 0;
        for (int w = 1; w <= 3; w++) begin
            pf_width = 2'(w);
            want_px = (w == 1) ? 64 : (w == 2) ? 80 : 96;
            for (int mm = 2; mm <= 15; mm++) begin
                m = 4'(mm); #1;
                is_char = t_is_char; bpp = t_bpp; px_width = t_px_width; #1;
                if (int'(pf_step) * int'(bytes_per_line) != want_px) begin
                    $display("FAIL T8: mode %0h width %0d step %0d x %0d bytes = %0d, expected a %0d-cycle window",
                             mm, w, pf_step, bytes_per_line,
                             pf_step * bytes_per_line, want_px);
                    fail++;
                end
            end
        end
        // ...and it does not depend on the width at all, only on how many
        // hi-res pixels a byte carries.
        m = 4'h2; #1; is_char = t_is_char; bpp = t_bpp; px_width = t_px_width;
        pf_width = 2'd1; #1; want_px = int'(pf_step);
        pf_width = 2'd3; #1;
        if (int'(pf_step) != want_px) begin
            $display("FAIL T8b: mode 2 step changed with width (%0d -> %0d)",
                     want_px, pf_step);
            fail++;
        end

        if (fail == 0) $display("tb_antic_pf_geom: all checks PASS");
        else           $display("tb_antic_pf_geom: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
