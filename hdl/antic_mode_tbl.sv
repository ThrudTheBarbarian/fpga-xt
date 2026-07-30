`default_nettype none
//
// antic_mode_tbl — the ANTIC mode nibble, decoded into datapath parameters.
//
// docs/ANTIC-rewrite.md.  ANTIC had ~120-560 gates for ALL its logic, so it
// cannot contain sixteen mode decoders — and it doesn't.  The mode nibble
// selects a handful of parameters that drive ONE datapath:
//
//   is_char   fetch a character NAME, then look its glyph up via CHBASE
//   bpp       bits consumed from the source byte per output pixel (1 or 2)
//   px_width  how wide each output pixel is, in HI-RES pixels (1, 2, 4, 8)
//   rows      scanlines per display row
//
// Everything else follows.  Pixels per byte is 8/bpp; bytes per line is
// 320/(px_per_byte * px_width).  There is no per-mode special case beyond the
// mode-3 descender quirk, which really is a quirk.
//
// THE INVARIANT.  A normal-width playfield is 160 colour clocks = 320 hi-res
// pixels, and EVERY display mode spans exactly that:
//
//     bytes_per_line * (8/bpp) * px_width == 320
//
// That is a physical fact about the machine, not a property of this table, so
// the testbench checks it for all fourteen modes.  If a future edit breaks it,
// the table is wrong — it is a much stronger check than comparing against
// hand-copied numbers, which can be wrong in the same way twice.
//
// Modes 0 and 1 are not display modes (blank lines and jumps); they are handled
// by the display-list machine and never reach here.
//
// CLOCK BUDGET: combinational, zero clocks.  This is a lookup, and the whole
// point is that it stays one.
//
`timescale 1ns/1ps

module antic_mode_tbl (
    input  wire [3:0]  mode,

    output logic       is_char,     // character mode: name fetch + glyph lookup
    output logic [1:0] bpp,         // source bits per output pixel (1 or 2)
    output logic [3:0] px_width,    // pixel width in hi-res pixels (1/2/4/8)
    output logic [4:0] rows,        // scanlines per display row
    output logic       descender,   // mode 3's 10-line cell with row wrap
    output logic       is_display   // 0 for modes 0/1, which never render here
);

    always_comb begin
        // Safe defaults: a mode that reaches here undecoded renders nothing
        // rather than something arbitrary.
        is_char    = 1'b0;
        bpp        = 2'd1;
        px_width   = 4'd1;
        rows       = 5'd1;
        descender  = 1'b0;
        is_display = 1'b1;

        unique case (mode)
            4'h2: begin is_char=1; bpp=1; px_width=1; rows=8;  end
            4'h3: begin is_char=1; bpp=1; px_width=1; rows=10; descender=1; end
            4'h4: begin is_char=1; bpp=2; px_width=2; rows=8;  end
            4'h5: begin is_char=1; bpp=2; px_width=2; rows=16; end
            4'h6: begin is_char=1; bpp=1; px_width=2; rows=8;  end
            4'h7: begin is_char=1; bpp=1; px_width=2; rows=16; end
            4'h8: begin is_char=0; bpp=2; px_width=8; rows=8;  end
            4'h9: begin is_char=0; bpp=1; px_width=4; rows=4;  end
            4'hA: begin is_char=0; bpp=2; px_width=4; rows=4;  end
            4'hB: begin is_char=0; bpp=1; px_width=2; rows=2;  end
            4'hC: begin is_char=0; bpp=1; px_width=2; rows=1;  end
            4'hD: begin is_char=0; bpp=2; px_width=2; rows=2;  end
            4'hE: begin is_char=0; bpp=2; px_width=2; rows=1;  end
            4'hF: begin is_char=0; bpp=1; px_width=1; rows=1;  end
            default: is_display = 1'b0;          // modes 0 and 1
        endcase
    end

endmodule

`default_nettype wire
