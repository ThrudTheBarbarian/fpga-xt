# Register map

Canonical Atari registers + the rp-XT chiplet-extension allocation
owned by `fpga-antic`. The chiplet-extension layout follows the
README's "Proposed map of register-space over and above ANTIC and
C|GTIA" — all addresses cross-checked against AtariAge's canonical
hardware-register list
([forums.atariage.com/topic/157241](https://forums.atariage.com/topic/157241-list-of-hardware-registers/))
to ensure no canonical register is shadowed.

For the wider `$D0xx-$D7xx` I/O space — including the **third-party /
expansion** usage (PBI devices, U1MB, SIDE, MyIDE, VBXE, R-Time 8, …) that
constrains where new XT registers can safely live — see the **Appendix:
ecosystem usage** at the end of this file. New XT allocations are placed in
ranges that table shows free; e.g. the `$D5xx` block below sits in the
`$D5C0-$D5DF` gap between R-Time 8 (`$D5B8-$D5BF`) and SIDE/SDX (`$D5E0-$D5FF`).

## XT register-unlock (the native decode is opt-in)

Every XT register group below is gated by an 8-bit **unlock register**: the
NATIVE (6502/ANTIC-side) decode only fires when the group's bit is set, so a
machine boots and behaves bone-stock until something deliberately unlocks it.
**PL reset → `0x00` (fully locked / stock);** a 6502-only reset does NOT clear
it. The A9/GP0-bridge path is **never** gated. Two write ports: the A9 (GP0
bridge offset `0x20`, the authority) and the 6502 (`$D1DF`, self-unlock). Bits:
`0` ANTIC_CHIPLET, `1` SPRITE, `2` BLITTER (+`$D4CA` turbo), `3` BANK, `4` GEM
(reserved), `5` KBD (reserved — kbd-inject is bridge-only). When a group is
locked the address falls through to the stock decode (ANTIC mirror in `$D4xx`,
open bus / cart in `$D5xx`). Full spec + worked launcher examples:
[register-unlock.md](register-unlock.md). The per-group notes below mark where
the gate applies.

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

### $D4A0-$D4FF — sprite engine + 2D blitter (XT hardware)

**This range is fully allocated** — sprite engine, the SuperSally/A9 2D
blitter, keyboard injection, and the SALLY turbo control all live here, and
they share the same `$D4xx` decode space. New allocations MUST avoid the pages
below. (History: putting the blitter's DDR surface descriptors on `$D4Dx`
silently collided with the sprite engine and corrupted the running 6502 —
hence this section, and why the descriptors now live on `$D4Ex`.)

| Page | Owner | Use |
|------|-------|-----|
| `$D4A0-$D4AF` | sprite engine | Per-sprite control registers (`fpga_xt_top` `sprite_reg_we` snoops `$D4Ax`). |
| `$D4B0-$D4BF` | 2D blitter — page B | DST geometry, pattern, CMD, STATUS, raster op (table below). |
| `$D4C0-$D4CF` | 2D blitter — page C | SRC geometry, FLAGS, SEQ; **overlaid** with `$D4CA` SEQ_HI-read / turbo-write, and keyboard-inject `$D4CB`/`$D4CD`/`$D4CF` (table below). |
| `$D4D0-$D4DF` | sprite engine | Indexed sprite descriptor + collision + control (`sprite_reg_we` snoops `$D4Dx`). **Blitter does NOT decode this page.** |
| `$D4E0-$D4EF` | 2D blitter — page E | SRC/DST DDR surface descriptors for `SRC_BLIT` (table below). `$D4EC-$D4EF` free. |
| `$D4F0-$D4FF` | reserved | Free. Reads 0; writes ignored. |

#### 2D blitter registers ($D4Bx / $D4Cx / $D4Ex)

The blitter shares its register bus between the native SALLY/ANTIC path and the
A9 (via the GP0 AXI-Lite bridge — see below). Byte-wide registers.

| Addr | Name | R/W | Purpose |
|------|------|-----|---------|
| $D4B0-$D4B7 | DST_{X,Y,W,H}_{LO,HI} | W | Destination geometry. For LINE: W/H = signed DX/DY. |
| $D4B8 / $D4B9 | PAT_PHASE_{X,Y} | W | Pattern phase (low 5 bits). |
| $D4BA | PAT_LOG_W | W | log2(pattern width); writing resets the PAT_DATA load pointer. |
| $D4BB | PAT_DATA | W | Pattern byte stream (R,G,B,A; auto-advances). For SRC_BLIT coverage, the 1×1 pattern = the text colour. |
| $D4BC | CMD | W | Fire: 01=RECT_FILL, 02=LINE_DRAW, 03=BLOCK_BLIT, 04=SCALED_BLIT, 05=FONT_RASTER (legacy coverage-BRAM, unused), 06=bilinear scaled, 07=SYNC, **08=SRC_BLIT** (DDR→DDR coverage/RGBA blend). |
| $D4BD | STATUS | R | bit0 busy, bit1 queue-full, bit2 pat/font-load-blocked. |
| $D4BE | PAT_LOG_H | W | log2(pattern height). |
| $D4BF | RASTER_OP | W | GEM raster op [3:0] for BLOCK_BLIT. |
| $D4C0-$D4C7 | SRC_{X,Y,W,H}_{LO,HI} | W | Source geometry (blit / scaled / SRC_BLIT src rect). |
| $D4C8 | FLAGS | W | bit0 BLEND, bit1 BILINEAR, **bit2 SRC_DDR, bit3 SRC_COV, bit4 SRC_AOVER, bit5 DST_DDR** (SRC_BLIT mode). |
| $D4C9 | SEQ_LO | R | SYNC sequence counter, low byte. |
| $D4CA | SEQ_HI / CLOCK_MULT | R / W | **Read** = SYNC counter high byte. **Write** = SALLY turbo multiplier (`clock_mult`, decoded in `fpga_xt_top`). |
| $D4CB | (kbd_break) | W | **Keyboard injection** — pulses the 6502 BREAK (decoded in `fpga_xt_top`, not a blitter reg). |
| $D4CD | (kbd_release) | W | **Keyboard injection** — key release. |
| $D4CE | FONT_DATA | W | Legacy coverage-BRAM byte stream (the FONT_RASTER path; superseded by SRC_BLIT). |
| $D4CF | (kbd_inject) | W | **Keyboard injection** — pushes a KBCODE + IRQ to POKEY. |
| $D4E0-$D4E3 | SRC_BASE | W | SRC_BLIT source surface base address (32-bit, byte-stream LSB→MSB). Latched while `!busy`. |
| $D4E4-$D4E5 | SRC_STRIDE | W | Source surface row stride in bytes. |
| $D4E6-$D4E9 | DST_BASE | W | SRC_BLIT dest surface base address. |
| $D4EA-$D4EB | DST_STRIDE | W | Dest surface row stride in bytes. |

#### GP0 AXI-Lite bridge (PS view, `XT_BLITTER_BASE = 0x43C00000`)

The A9 reaches the blitter's `$D4xx` registers through `axi_blitter_bridge`
over the Zynq GP0 port. A 64-byte byte-offset window maps to four `$D4` pages
via a 2-bit page select (`awaddr[5:4]`):

| AXI byte offset | → register page |
|-----------------|-----------------|
| `0x00-0x0F` | `$D4Bx` |
| `0x10-0x1F` | `$D4Cx` |
| `0x20-0x2F` | `$D4Dx` *(sprite engine — do NOT drive from the A9)* |
| `0x30-0x3F` | `$D4Ex` *(SRC_BLIT descriptors)* |

The bridge intercepts a few offsets itself rather than forwarding them:

| Offset | Direction | Meaning |
|--------|-----------|---------|
| `0x1C` | **write** | `gp0_ctrl` (NOT a blitter reg): bit0 = HDMI test-pattern/bars enable, bits[3:1] = XL scale. |
| `0x1C` | read | `diag_word` (PL debug; read/write share the offset). |
| `0x20` | **write** | `xt_unlock` (NOT a blitter reg): the XT register-unlock mask (A9 = authority). Maps to `$D4D0` on the native bus, which the blitter ignores and sprites don't see over the bridge, so the offset is free. See the unlock section above. |
| `0x20` | read | `xt_unlock` effective value (incl. any 6502 self-unlock at `$D1DF`). |
| `0x0D` | read | STATUS (replicated across all 4 byte lanes). |
| `0x19` / `0x1A` | read | SEQ_LO / SEQ_HI. |
| `0x1E` | read | `clock_mult` read-back (verify a `speed` write latched). |
| `0x14` / `0x18` | read | `diag3` (read-path counters) / `diag2` (production-chain counters). |
| `0x0C` / `0x10` | read | `diag5` (HP0 first-AR addr) / `diag4` (HP3/XL first-AR addr). |
| `0x04` / `0x08` | read | `diag6` (HP2 read-probe status) / `diag7` (last rdata). |

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

## $D5xx — XT extension (bank select + GEM service)

Registers added by the XT extended architecture in the CCTL I/O gap.
Mirror behaviour does NOT apply here. The XT owns only `$D5C0-$D5DF` — the
free gap between R-Time 8 (`$D5B8-$D5BF`) and SIDE1/2 / SDX / U1MB
(`$D5E0-$D5FF`); see the ecosystem Appendix at the end of this file.
Do NOT extend XT registers into `$D5E0+`.

**Allocating a new XT register — check these first, in order:**

1. **Take it from `$D5CF` or `$D5D5-$D5DF`.** Those are the only free bytes the
   XT owns.  `$D5CF` is the last one inside the decoded `$D5C0-$D5CF` slot, so
   it costs no new decode — spend it last.
2. **Never `$D0xx`/`$D2xx`/`$D3xx`/`$D4xx`.** Those pages are zeroed at warm-
   and cold-start (except `$D301`), so anything with a **write side effect**
   there — a doorbell, a FIFO port — gets strobed 256 times by the OS's clear
   loop on every boot. They also owe mirror fidelity to the stock chips.
3. **Never `$D6xx`/`$D7xx`.** It is PBI space, and both the PBI bridge
   ([../OS/expansion-options.md](../OS/expansion-options.md) — slots, `/CARDSEL`,
   the `$D1FF` device select, the `/MPD` `$D800-$DFFF` shadow) and VBXE
   compatibility (`$D640-$D65F` / `$D740-$D75F` install windows) need it clear.
4. **Prefer a port over a window.** A byte-wide auto-incrementing data port
   moves an arbitrary payload through one address; an aperture over
   `$4000-$5FFF` costs 8 KB of the guest's RAM and everything that follows from
   that. If the port has a read or write side effect it MUST fire exactly once
   per machine cycle — gate it like `pk_re` (`fid_sub == 49 && fid_rdy`), or a
   stalled/replayed fidelity-core cycle re-fires it.
5. **Cross-check the ecosystem Appendix** at the end of this file before
   claiming anything outside `$D5C0-$D5DF`.

### $D5C0-$D5C1 — bank selectors

| Addr  | Name      | R/W | Purpose |
|-------|-----------|-----|---------|
| $D5C0 | CODE_BANK | R/W | Code bank selector — selects the page mapped into the `$6000-$9FFF` code window (16 KB). 8-bit (256 banks); bank 0 = flat BRAM. Readable (the scheduler saves/restores it). Relocated off zero page (was BASIC VNTP) into the CCTL gap. |
| $D5C1 | DATA_BANK | R/W | Data bank selector — selects the page mapped into the `$A000-$CFFF` data window (12 KB). 8-bit (256 banks); bank 0 = flat BRAM; **bank `$FF` = the shared GEM arena** (see doorbell below). Readable. |
| $D5C2 | reserved | - | Reserved. Reads 0; writes ignored. |

### $D5C3-$D5C8 — screen banking + math/mailbox aperture

Decoded in `hdl/sally_mem.sv` (`is_scrn_*` / `is_math_*`); read-back is served
through the shared CCTL slot, so `addr[3:0]` selects within `$D5C0-$D5CF`.
Details: [../video/screen-banking.md](../video/screen-banking.md),
[../Design/math-coprocessor.md](../Design/math-coprocessor.md).

| Addr  | Name | R/W | Purpose |
|-------|------|-----|---------|
| $D5C3 | SCRN_CPU_BANK | R/W | Screen bank for the **CPU's** view of `$4000-$5FFF`. 0 = the flat 64 KB shadow. |
| $D5C4 | SCRN_ANTIC_BANK | R/W | Screen bank for **ANTIC's** view of `$4000-$5FFF` (independent of the CPU's). |
| $D5C5 | SCRN_STAT | R | `{7'b0, ready}`. |
| $D5C6 | MATH_CTL | R/W | bit 0 = **MAP**: overlay the math page / SIO mailbox on `$4000-$5FFF` (CPU view only — ANTIC never sees it). Wins over `$D5C3`. **Hazard:** while MAP is set, `$4000-$5FFF` is *not* the guest's RAM, so an interrupt taken in that window runs with the aperture in place — see NextSteps "App launch". |
| $D5C7 | MATH_EXEC / MATH_STAT | R/W | **Write** = doorbell to the A9 (any value). **Read** = `{5'b0, chunk_ready, busy, done}`. |
| $D5C8 | MATH_CHUNK | R/W | Backing chunk index; the SIO stub writes `$FF` (the mailbox is always resident). |

### $D5C9-$D5CC — math op-latency counter

Read-only LE u32: `clk_sally` cycles from the `$D5C7` EXEC write to `done`
rising. Raw 100 MHz fabric cycles (not step-gated), so it is turbo-independent —
`count/100` = µs. Latched, static between ops.

| Addr  | Name | R/W | Purpose |
|-------|------|-----|---------|
| $D5C9-$D5CC | MATH_LAT | R | Op-latency counter, little-endian u32. |
| $D5CD | SIO_IDX | R/W | **SIO mailbox byte index.** Write sets it (8 bits; the internal counter is 9, and auto-increment carries into the top bit); read returns the current low 8. |
| $D5CE | SIO_DAT | R/W | **The mailbox byte at SIO_IDX.** Every access — read OR write — post-increments the index, so one `$D5CD` write walks a whole payload. The read is side-effecting, so its strobe is generated at the top level gated like `pk_re` (exactly once per advancing cycle); a stalled fidelity-core presentation must not advance the index. |
| $D5CF | free | - | **Free** — the last unallocated byte in the decoded `$D5C0-$D5CF` slot. |

### $D5D0-$D5D4 — GEM service doorbell

The XL issues VDI/AES calls to the ARM-A9 GEM service through this block:
stage the parameter block + arrays in bank `$FF` (the `$A000-$CFFF` data
window), then drive these registers. Synchronous / blocking. Full protocol in
[../GEM/gem-service-abi.md](../GEM/gem-service-abi.md).

| Addr  | Name         | R/W | Purpose |
|-------|--------------|-----|---------|
| $D5D0 | GEM_DISPATCH | W   | Namespace select: `115` ($73) = VDI, `200` ($C8) = AES (ST `TRAP #2` d0 convention). |
| $D5D1 | GEM_PBLK_LO  | W   | Parameter-block address within the `$A000-$CFFF` window, low byte. Bank is implicitly `$FF`. |
| $D5D2 | GEM_PBLK_HI  | W   | Parameter-block address, high byte. |
| $D5D3 | GEM_GO / GEM_STATUS | R/W | **Write** (any value) rings the doorbell to the A9. **Read** returns status: bit 7 `BUSY` (1 while the A9 is servicing), bit 0 `ERR`, bits 6-1 result code. Poll `BUSY`=0 for completion. |
| $D5D4 | GEM_ABIVER   | R   | GEM service ABI version / magic for capability probe. `$00` = no service present. |
| $D5D5-$D5DF | reserved | - | Reserved for future GEM / service registers (XT window ends at `$D5DF` — `$D5E0+` is SIDE/SDX). Reads 0; writes ignored. |

## Appendix — Atari I/O-space ecosystem usage ($D0xx-$D7xx)

A reference catalogue of how the `$D0xx-$D7xx` hardware-register space is used
across the Atari 8-bit ecosystem: stock chips plus third-party expansions
(U1MB, SIDE, MyIDE, VBXE, PBI devices, the 1090 XL, …). Collected from
community sources (AtariAge and similar) — treat as a best-effort guide, not an
exhaustive spec. It exists to keep new XT allocations clear of established
usage: e.g. the XT `$D5xx` block above sits in the `$D5C0-$D5DF` slot this table
shows is free.

### $D0xx — GTIA

| Range | Use |
|-------|-----|
| `$D000-$D01F` | CTIA / GTIA (stock) |
| `$D020-$D03F` | reserved — second GTIA |
| `$D040-$D05F` | reserved — third GTIA |
| `$D080-$D0FF` | VBXE soft-reset area |

### $D1xx — PBI

| Range | Use |
|-------|-----|
| `$D100-$D1FF` | PBI (general) |
| `$D100-$D107` | MyIDE Internal |
| `$D100-$D1BE` | U1MB RAM |
| `$D1BF` | U1MB PBI bankswitching |
| `$D100, $D104, $D108, $D110, $D114` | 1400XL / 1450XLD modem, voice & disk interface |
| `$D170-$D171, $D17C, $D1BC, $D1BE, $D1C0` | BlackBox |
| `$D1C0-$D1C1` | SmartIDE LCD |
| `$D1B0-$D1C7` | Atari speech / modem / disc registers |
| `$D1B0, $D1B8` | unreleased 800XLD floppy controller |
| `$D1C8-$D1CE` | Atari reserved |
| `$D1CF` | read alternate interrupt register (1450 XLD only) |
| `$D1D1-$D1DD` | 1090 XL Amy boards 1-4 |
| `$D1DF` | **XT register-unlock — claimed here** (6502 self-unlock write port; R/W). In the documented-free gap between the Amy block (`$D1D1-$D1DD`) and the MIO ACIA (`$D1E0+`); nothing stock writes PBI space, so the location is the protection. See the unlock section near the top. |
| `$D1E0-$D1E3` | MIO / 1090 XL serial-parallel ACIA0 |
| `$D1E4-$D1E7` | 1090 XL serial-parallel ACIA1 |
| `$D1E8-$D1EF` | 1090 XL serial-parallel registers |
| `$D1F0-$D1F7` | 1090 XL Z80 / alternate-CPU registers |
| `$D1F8-$D1FD` | 1090 XL 80-column video card |
| `$D1FE` | 1090 XL RAM bank-select |
| `$D1FF` | PBI device enable (W) / IRQ mask (R) |

### $D2xx — POKEY

| Range | Use |
|-------|-----|
| `$D200-$D20F` | POKEY (stock) |
| `$D210-$D21F` | second POKEY (GUMBY) |
| `$D280-$D283` | Covox (new location) |

### $D3xx — PIA

| Range | Use |
|-------|-----|
| `$D300-$D303` | PIA 6520 (stock) |
| `$D310-$D313` | second PIA 6520 |
| `$D320-$D323` | VIA 6522 |
| `$D380-$D381` | U1MB configuration registers |
| `$D383-$D384` | U1MB status registers |
| `$D3E2` | U1MB SDX real-time clock (SPI) |

### $D4xx — ANTIC

| Range | Use |
|-------|-----|
| `$D400-$D40F` | ANTIC (stock; `$D406`, `$D408` unused) |
| `$D410-$D41F` | reserved — second ANTIC |

### $D5xx — cartridge control (CCTL)

| Range | Use |
|-------|-----|
| `$D500` | 4-bit audio samplers (e.g. ADC0804) |
| `$D500-$D507` | MyIDE External |
| `$D5B8-$D5BF` | R-Time 8 |
| `$D5C0-$D5DF` | **XT extension — claimed here** (bank select + GEM doorbell; see the `$D5xx` section above) |
| `$D5E0` | SDX bankswitching |
| `$D5E0-$D5E1` | U1MB SDX bankswitching enable / disable |
| `$D5E0-$D5FF` | SIDE 1/2 registers (banking, DS1305 RTC, IDE, ID) |

### $D6xx-$D7xx — PBI

| Range | Use |
|-------|-----|
| `$D600-$D7FF` | PBI / 1400XL-1450XLD parallel-device RAM (Atari official) |
| `$D600-$D603` | Covox |
| `$D600-$D6FF` | MIO RAM / BlackBox RAM |
| `$D640-$D65F` | VBXE D6 install |
| `$D740-$D75F` | VBXE D7 install |

### Notes

- Pages `$D0`, `$D2`, `$D3`, `$D4` are zeroed at warm- and cold-start —
  **except `$D301`**. `$D5` is *not* zeroed, which is why the XT bank-select and
  GEM registers there persist.
- Free ranges should mirror the stock chips as much as possible.
- Games that rely on specific mirror locations: *Bounty Bob Strikes Back*
  (`$D47B`).
