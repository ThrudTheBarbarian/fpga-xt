// dump_ppm.svh — debug-image dumper for compositor framebuffer state.
//
// Walks `u_mock.fb` (hierarchical reference — every testbench instances
// the rp_bus_mock as `u_mock`) and writes a binary P6 PPM with each
// atari pixel stretched STRETCH × STRETCH for legibility.
//
// Usage from a testbench:
//   `include "dump_ppm.svh"
//   ...
//   dump_ppm("visual/pm_p1.ppm", 320, 4, 3);
//
// The vertical stretch parameter replicates each atari row vstretch
// times. Width is always emitted 1:1 (one image px per atari px) so a
// 320 atari-wide row produces a 320 px wide image.
//
// idx_buf encoding (low nibble = PF source, high nibble = P/M presence):
//   bit 0 = PF0      bit 4 = P0
//   bit 1 = PF1      bit 5 = P1
//   bit 2 = PF2      bit 6 = P2
//   bit 3 = PF3      bit 7 = P3
//
// The palette here is a debug palette — distinct, easy-to-spot hues for
// each source layer. Real Atari color resolution (PRIOR + COLPMx +
// COLPFx) lands in M10; until then this is just "where is each layer?"

function automatic logic [23:0] dump_ppm_palette(input logic [7:0] idx);
    // Highest-priority bit wins. Players over PFs over background.
    if (idx[7]) return 24'hC080FF;       // P3 — magenta
    if (idx[6]) return 24'hFF40FF;       // P2 — pink
    if (idx[5]) return 24'hFFFF00;       // P1 — yellow
    if (idx[4]) return 24'hFF4040;       // P0 — red
    if (idx[3]) return 24'hFFA040;       // PF3 — orange
    if (idx[2]) return 24'h40C040;       // PF2 — green
    if (idx[1]) return 24'h00C0FF;       // PF1 — cyan
    if (idx[0]) return 24'h4040FF;       // PF0 — blue
    return                24'h202020;    // background — dark gray
endfunction

task automatic dump_ppm(input string  path,
                        input integer width_at,    // atari px per row
                        input integer height_at,   // atari rows
                        input integer vstretch);   // vertical replication
    integer fd;
    integer r, c, sy, fb_off;
    logic [7:0]  idx;
    logic [23:0] rgb;

    fd = $fopen(path, "wb");
    if (fd == 0) begin
        $display("[dump_ppm] WARN cannot open %s", path);
        return;
    end
    $fwrite(fd, "P6\n%0d %0d\n255\n", width_at, height_at*vstretch);
    for (r = 0; r < height_at; r = r + 1) begin
        for (sy = 0; sy < vstretch; sy = sy + 1) begin
            for (c = 0; c < width_at; c = c + 1) begin
                fb_off = r * 1024 + c;       // FB_ROW_STRIDE = 1024
                idx    = u_mock.fb[fb_off];
                rgb    = dump_ppm_palette(idx);
                $fwrite(fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
            end
        end
    end
    $fclose(fd);
    $display("[dump_ppm] %s (%0d x %0d)",
             path, width_at, height_at*vstretch);
endtask
