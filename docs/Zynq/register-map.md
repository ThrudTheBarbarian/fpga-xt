# Register map

Canonical Atari registers + the rp-XT chiplet-extension allocation
owned by `fpga-antic`. The chiplet-extension layout follows the
README's "Proposed map of register-space over and above ANTIC and
C|GTIA" — all addresses cross-checked against AtariAge's canonical
hardware-register list
([forums.atariage.com/topic/157241](https://forums.atariage.com/topic/157241-list-of-hardware-registers/))
to ensure no canonical register is shadowed.

## $D0xx — GTIA / CTIA

`fpga-antic` owns the entire page. Real-silicon mirror behaviour is
preserved on $D000-$D07F; the upper half ($D080-$D0FF) is the
chiplet-extension window with mirroring broken.

### Write side ($D000-$D01F)

| Addr  | Name      | Purpose |
|-------|-----------|---------|
| $D000 | HPOSP0    | Player 0 horizontal position (color clocks). |
| $D001 | HPOSP1    | Player 1 horizontal position. |
| $D002 | HPOSP2    | Player 2 horizontal position. |
| $D003 | HPOSP3    | Player 3 horizontal position. |
| $D004 | HPOSM0    | Missile 0 horizontal position. |
| $D005 | HPOSM1    | Missile 1 horizontal position. |
| $D006 | HPOSM2    | Missile 2 horizontal position. |
| $D007 | HPOSM3    | Missile 3 horizontal position. |
| $D008 | SIZEP0    | Player 0 size: 00=1× / 01=2× / 10=1× / 11=4×. |
| $D009 | SIZEP1    | Player 1 size. |
| $D00A | SIZEP2    | Player 2 size. |
| $D00B | SIZEP3    | Player 3 size. |
| $D00C | SIZEM     | All four missile sizes (2 bits each). |
| $D00D | GRAFP0    | Player 0 shape pattern (DMA-disabled writes). |
| $D00E | GRAFP1    | Player 1 shape pattern. |
| $D00F | GRAFP2    | Player 2 shape pattern. |
| $D010 | GRAFP3    | Player 3 shape pattern. |
| $D011 | GRAFM     | Missile shape pattern. |
| $D012 | COLPM0    | Player/missile 0 colour. |
| $D013 | COLPM1    | Player/missile 1 colour. |
| $D014 | COLPM2    | Player/missile 2 colour. |
| $D015 | COLPM3    | Player/missile 3 colour. |
| $D016 | COLPF0    | Playfield 0 colour. |
| $D017 | COLPF1    | Playfield 1 colour. |
| $D018 | COLPF2    | Playfield 2 colour. |
| $D019 | COLPF3    | Playfield 3 colour. |
| $D01A | COLBK     | Background / border colour. |
| $D01B | PRIOR     | Priority + GTIA mode select (bits 6-7). |
| $D01C | VDELAY    | Per-channel vertical delay (P/M). |
| $D01D | GRACTL    | Player/missile DMA enable + latch control. |
| $D01E | HITCLR    | Write strobe — clears collision latches. |
| $D01F | CONSOL_W  | Console-key output side / speaker bit. |

### Read side ($D000-$D01F)

| Addr  | Name     | Purpose |
|-------|----------|---------|
| $D000 | M0PF     | Missile 0 → playfield collision latch. |
| $D001 | M1PF     | Missile 1 → playfield. |
| $D002 | M2PF     | Missile 2 → playfield. |
| $D003 | M3PF     | Missile 3 → playfield. |
| $D004 | P0PF     | Player 0 → playfield. |
| $D005 | P1PF     | Player 1 → playfield. |
| $D006 | P2PF     | Player 2 → playfield. |
| $D007 | P3PF     | Player 3 → playfield. |
| $D008 | M0PL     | Missile 0 → player. |
| $D009 | M1PL     | Missile 1 → player. |
| $D00A | M2PL     | Missile 2 → player. |
| $D00B | M3PL     | Missile 3 → player. |
| $D00C | P0PL     | Player 0 → player. |
| $D00D | P1PL     | Player 1 → player. |
| $D00E | P2PL     | Player 2 → player. |
| $D00F | P3PL     | Player 3 → player. |
| $D010 | TRIG0    | Joystick trigger 0 (serial-pushed by rp-POKEY/PIA). |
| $D011 | TRIG1    | Joystick trigger 1. |
| $D012 | TRIG2    | Joystick trigger 2. |
| $D013 | TRIG3    | Joystick trigger 3. |
| $D014 | PAL      | bit 0 = PAL, bit 1 = NTSC sense (serial-pushed). |
| $D015 | reserved | Read 0. |
| $D016 | reserved | Read 0. |
| $D017 | reserved | Read 0. |
| $D018 | reserved | Read 0. |
| $D019 | reserved | Read 0. |
| $D01A | reserved | Read 0. |
| $D01B | reserved | Read 0. |
| $D01C | reserved | Read 0. |
| $D01D | reserved | Read 0. |
| $D01E | reserved | Read 0. |
| $D01F | CONSOL_R | Console-key state (serial-pushed by rp-syscontroller). |

### $D020-$D07F — mirrors

Real silicon mirrors $D000-$D01F on every 32-byte boundary up to
$D07F. fpga-antic preserves this mirror.

### $D080-$D0FF — GTIA chiplet extension

Reserved. No assignments yet — mirror behaviour does NOT apply here.
Reads return 0; writes are ignored. Future GTIA-side extensions
(player palette indexing, full-colour P/M) will land here; see the
README's "Future work" section.

## $D4xx — ANTIC

### Canonical ANTIC ($D400-$D40F)

| Addr  | Name    | Purpose |
|-------|---------|---------|
| $D400 | DMACTL  | DMA control. Bits: 0-1 playfield width, 2 missile DMA, 3 player DMA, 4 PM resolution (1=line, 0=2line), 5 DL DMA enable. |
| $D401 | CHACTL  | Charset control. Bits: 0 vertical reflect, 1 inverse video, 2 inverse blank. |
| $D402 | DLISTL  | Display-list pointer low byte. |
| $D403 | DLISTH  | Display-list pointer high byte. |
| $D404 | HSCROL  | Horizontal scroll, 0..15 colour clocks. |
| $D405 | VSCROL  | Vertical scroll, 0..15 scan lines. |
| $D406 | reserved | (Real ANTIC: PMBASE high byte mirror — not used in rp-XT, snoop tag handles PM region.) |
| $D407 | PMBASE  | Player/missile data page base (×256). |
| $D408 | reserved | Reads 0; writes ignored. |
| $D409 | CHBASE  | Charset RAM page base (×256). |
| $D40A | WSYNC   | Wait for horizontal sync (write strobe). |
| $D40B | VCOUNT  | Vertical line counter (read-only; bit 0 ignored, granularity = 2 scan lines). |
| $D40C | PENH    | Light pen horizontal. (rp-XT stub: returns 0.) |
| $D40D | PENV    | Light pen vertical. (rp-XT stub: returns 0.) |
| $D40E | NMIEN   | NMI enable: bit 6 VBI, bit 7 DLI, bit 5 RNMI. |
| $D40F | NMIST / NMIRES | Read = NMI status. Write = clear status. |

### $D410-$D41F — second-ANTIC reserved

Placeholder for a future second ANTIC instance on the same slot. Do
not reuse for any other purpose.

### $D420-$D47F — mirrors

Mirror of $D400-$D40F on every 16-byte boundary up to $D47F.

### $D480-$D4FF — ANTIC chiplet extension

Layout per the README's "Proposed map of register-space over and above
ANTIC and C|GTIA". Mirror behaviour does NOT apply here.

| Addr  | Name        | R/W | Purpose |
|-------|-------------|-----|---------|
| $D480 | CLOCK_MULT  | R   | Bus clock multiplier vs the NTSC 1.79 MHz baseline. Pushed in by rp-syscontroller over the inter-chip serial link during boot configuration; readable once $D7FF has fired. |
| $D481 | MODE        | R/W | bit 0 `MODE_SNOOP` — 1 = snoop (default at /G_RST), 0 = legacy DMA. bits 1-7 reserved (read 0, writes ignored). |
| $D482 | OUTPUT_MODE | R/W | bit 0 `OUT_800x600` — 0 = 640×480@60 (default), 1 = 800×600@60. bit 1 `OUT_FULLRES` — 0 = ANTIC-compat half-V framebuffer with line-double / line-triple, 1 = native fullres extended mode (640×480 = 307 KB or 800×600 = 480 KB) with per-line independent control. bits 2-7 reserved. |
| $D483 | PAL_R       | R/W | Red value (0..255) for the palette entry at PAL_IDX. |
| $D484 | PAL_G       | R/W | Green value. |
| $D485 | PAL_B       | R/W | Blue value. |
| $D486 | PAL_IDX     | R/W | Palette index (0..255) the next R/G/B trio targets. |
| $D487 | reserved    | -   | Reserved for extension to palette index (e.g. second palette page). Reads 0; writes ignored. |
| $D488 | DRAW_OP     | R/W | DRAW opcode (BUS_DRAW_OP_*). M17-2. Software stages this + up to 5 args at $D489-$D492 then strobes DRAW_GO. `op[7]` is the fill flag for paired closed-shape primitives (RECT, OVAL, ARC) — set high to render filled instead of outline. FILL ($03) is a separate flood-fill primitive, not "RECT with op[7]=1". |
| $D489 | DRAW_ARG0_LO| R/W | Arg 0, low byte. (Args are little-endian 16-bit; semantics depend on DRAW_OP — for LINE: x0/y0/x1/y1/colour; for RECT (outline or fill): x/y/w/h/(colour+mode); for FILL (flood): x/y/colour, args 3-4 unused. See [wire-protocol.md](wire-protocol.md) DRAW table.) |
| $D48A | DRAW_ARG0_HI| R/W | Arg 0, high byte. |
| $D48B | DRAW_ARG1_LO| R/W | Arg 1, low byte. |
| $D48C | DRAW_ARG1_HI| R/W | Arg 1, high byte. |
| $D48D | DRAW_ARG2_LO| R/W | Arg 2, low byte. |
| $D48E | DRAW_ARG2_HI| R/W | Arg 2, high byte. |
| $D48F | DRAW_ARG3_LO| R/W | Arg 3, low byte. |
| $D490 | DRAW_ARG3_HI| R/W | Arg 3, high byte. |
| $D491 | DRAW_ARG4_LO| R/W | Arg 4, low byte. |
| $D492 | DRAW_ARG4_HI| R/W | Arg 4, high byte. |
| $D493 | DRAW_GO     | R/W | Write any value to commit the staged DRAW for dispatch to rp_tx. Read returns `{7'h00, pending}` — software MUST poll DRAW_GO[0]==0 before staging the next command (back-to-back GO writes while pending=1 are lost). |
| $D494 | DRAW_ARG5_LO| R/W | Arg 5, low byte. Used by 7-beat opcodes — ARC's `start_angle` (M18-2) and BEZIER_TO's mid control point (M18.1). |
| $D495 | DRAW_ARG5_HI| R/W | Arg 5, high byte. |
| $D496 | DRAW_ARG6_LO| R/W | Arg 6, low byte. ARC's `end_angle` / BEZIER_TO's colour. |
| $D497 | DRAW_ARG6_HI| R/W | Arg 6, high byte. |
| $D498 | DRAW_ARG7_LO| R/W | Arg 7, low byte. Used by BEZIER (9-beat opcode) for the y-coord of the 4th control point. |
| $D499 | DRAW_ARG7_HI| R/W | Arg 7, high byte. |
| $D49A | DRAW_ARG8_LO| R/W | Arg 8, low byte. BEZIER's colour. |
| $D49B | DRAW_ARG8_HI| R/W | Arg 8, high byte. |
| $D49C | OS_ROM_ADDR_LO | R/W | Chiplet OS-ROM loader (SALLY-driven; distinct from the PS/AXI sally_rom_loader). Target write-address low byte. |
| $D49D | OS_ROM_ADDR_HI | R/W | Target write-address high byte. |
| $D49E | OS_ROM_DATA | R/W | Write a byte → committed to memory at OS_ROM_ADDR, then OS_ROM_ADDR auto-increments (unless WRITE_LOCK set). Read returns the last byte written. |
| $D49F | OS_ROM_CTL | R/W | bit 0 = WRITE_LOCK: once set, further OS_ROM_DATA writes are ignored (ROM-load disabled). |
| $D4A0-$D4FF | reserved | - | Future chiplet-extension registers. Reads 0; writes ignored. |

### Palette write semantics

The 256-entry full-RGB extended palette is exposed as the four-byte
record at `$D483-$D486` (R / G / B / IDX). A write to **any** of these
four ports updates palette entry `PAL_IDX` with the latest R/G/B
latched in the chip — order-independent. Per the README:

> any change will update the palette index for all 4 parameters. This
> is not write-order dependent.

So programs can stream `R G B IDX++` quartets in any internal order
and the palette will be coherent after every write. The most common
sequences are likely to be:

- `IDX, R, G, B` (clear pattern; each colour fully written before
  IDX increments).
- `R, G, B, IDX` (write the colour, then commit-by-IDX).

Both work identically.

The legacy hardware palette (COLBK / COLPF0-3 / COLPM0-3) is stored
separately and indexes into the full 256-entry palette via its own
small lookup; software written for canonical Atari hardware is
unaffected.
