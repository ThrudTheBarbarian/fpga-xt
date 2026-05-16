# ANTIC accuracy audit vs. Altirra reference manual

Source: *Altirra Hardware Reference Manual* by Avery Lee, Chapter 4 (ANTIC)
and §14.6 (ANTIC register reference), in `docs/altirra-reference-manual.pdf`.

This audit cross-checks our ANTIC implementation against Altirra's
description of the chip. Affected files: `hdl/antic_regs.sv`,
`hdl/nmi_gen.sv`, `hdl/wsync_gen.sv`, `hdl/dl_parser.sv`, `hdl/vbeam.sv`.

## Must-fix register-behaviour bugs

### 1. Write-only register readbacks return $FF, not stored value or $00

**Altirra §4.1**: "Unassigned addresses within the ANTIC address range
read as $FF. This is true even on hardware models that have a floating
data bus for unassigned addresses, as ANTIC actually drives $FF onto
the bus for addresses in its range that don't have registers assigned."

**§14.6** marks every ANTIC control register as **write-only** except
VCOUNT ($D40B) and NMIST ($D40F).

**Our implementation** (`antic_regs.sv` read mux): currently returns
the stored value for DMACTL, CHACTL, DLISTL/H, HSCROL, VSCROL, PMBASE,
CHBASE, NMIEN; returns $00 for the reserved $D406 / $D408 / WSYNC /
PENH / PENV slots. None of those match real ANTIC.

**Software impact**: most code never reads back these registers, but
some OS code and self-detection routines do. Reading $00 vs $FF is the
most visible — code like `LDA $D40A` (which expects $FF for a
write-only address) gets a wrong answer.

**Fix shape**: read mux returns `8'hFF` for $D400, $D401, $D402, $D403,
$D404, $D405, $D406, $D407, $D408, $D409, $D40A, $D40C (PENH), $D40D
(PENV), $D40E. Plus VCOUNT and NMIST keep their existing read-side
behaviour.

PENH/PENV are technically "lightpen" registers and have specific
power-on values (PENH=$00, PENV=$FF per §4.1) — but since the rp-XT
board has no lightpen, returning $FF for both is acceptable and
matches real hardware's behaviour for an unconnected lightpen.

### 2. NMIST low bits 0..4 should read as 1s, not 0s

**Altirra §14.6 NMIST register layout**:

```
 7   6   5   4  3  2  1  0
DLI VBI RES  1  1  1  1  1
```

So bits 0..4 are always 1 — only bits 5..7 carry meaningful state.

**Our implementation** (`nmi_gen.sv`): assembles NMIST as
`(nmires_strobe ? 0 : nmist_q) | (dli_set ? $80 : 0) | (vbi_set ? $40
: 0)`. Bits 0..4 are 0.

**Software impact**: code using `BIT $D40F` to test bit 7 (DLI) or bit
6 (VBI) works regardless. Code that ANDs NMIST with a mask and
compares (e.g., `LDA NMIST; AND #$F0; CMP #$80`) breaks because the low
bits don't match the expected pattern.

**Fix shape**: OR `8'h1F` into the NMIST output. Either at the
nmist_q assignment in nmi_gen.sv, or at the read-mux site in
antic_regs.sv.

### 3. Reset behaviour over-clears registers

**Altirra §4.1** "Reset behavior":
- **Cleared on reset**: NMIEN, DMACTL, playfield DMA clock.
- **NOT cleared on reset**: HSCROL, VSCROL, PMBASE, CHBASE, CHACTL,
  DLISTL/H, NMIST, refresh-row-counter, V/H counters, WSYNC,
  memory-scan counter, pending RNMI, PENH, PENV.

**Our implementation** (`antic_regs.sv`): on `rst`, zeros all of
dmactl, chactl, dlistl, dlisth, hscrol, vscrol, pmbase, chbase,
nmien.

**Software impact**: in real Atari, a soft reset preserves these so
the OS can restore state without re-initialising. Most software
re-initialises them anyway, but some accelerated cold-start code
relies on the persistence. Also affects the "reset doesn't clear my
display list" assumption used in some demos.

**Fix shape**: only zero NMIEN and DMACTL on rst. Leave the other
registers untouched (their power-on values are undefined per
§4.1, but for reset they retain whatever was last written).

## Lower-priority findings

### 4. End-of-frame VCOUNT anomaly

**Altirra §4.10**: VCOUNT reads `$83` (NTSC) or `$9C` (PAL) for
exactly one cycle (cycle 111 of the very last scan line) before
the counter resets to $00.

**Our implementation** (`vbeam.sv`): vcount is `atari_row[8:1]` or
$FF in blanking. The end-of-frame "off by one" anomaly isn't
modelled — the highest visible value is whatever atari_row[8:1]
reaches on the last visible scan line, then it jumps directly to
0 without showing the +1 transient.

**Software impact**: a DLI handler that uses VCOUNT to index a
table and runs on the very last scan line could index off the end
of the table. This is a known footgun on real hardware; software
that hits it is exceptionally rare.

**Defer.**

### 5. WSYNC release timing — "cycle 105"  [BUG]

**Altirra §4.9 + §14.6**: a WSYNC write halts the CPU until cycle
105 of the current scan line (or the next, if written too late).
There's a one-cycle "first cycle of the next instruction"
overlap.

**Our implementation** (`wsync_gen.sv`): /RDY releases on
`line_start`, which fires at cycle 0 of the *next* scan line — 9
cycles later than real ANTIC.

**Software impact**: a DLI that does `STA WSYNC` followed by tight
register writes runs ~9 cycles later than on real ANTIC. The
horizontal blank window is ~14 cycles wide — most DLI routines
have enough margin that this slip doesn't break them, but
edge-case routines that crowd hblank could miss the window.

**Status**: tracked as `Issues.md#wsync-cycle-105`. We don't have a
cycle-accurate bus model yet — the proper fix needs a "cycle 105"
pulse from vbeam tied to the real hsync edge, plus a 1-cycle
CPU-resume overlap. Becomes addressable once SALLY lands and the
CPU is on the FPGA where bus cycles are observable.

### 6. Display-list 1K boundary wrap  [BUG]

**Altirra §4.6**: "DLISTL/DLISTH register is actually split into 6
bit and 10 bit portions, where the lower 10 bits increment and
the upper 6 bits do not. As a result, during normal execution the
display list will wrap from the top of a 1K block to the bottom
during fetching, e.g. $07FF to $0400. ... Jump instructions are
not limited and can cross 1K boundaries to any address."

**Our implementation** (`dl_parser.sv`): `dl_pos` is a 16-bit
pointer that increments without wrapping. A display list spanning
$07F0..$0810 would naturally wrap to $0810 in our model; on real
ANTIC it'd wrap to $0400.

**Software impact**: programs whose display lists straddle a 1K
boundary by accident would observe different behaviour. In
practice ANTIC's wrapping is rare and software that depends on
it is rare. (Demos that exploit this oddity do exist.)

**Status**: tracked as `Issues.md#dl-1k-wrap`. Fix shape: split
`dl_pos` into 6-bit + 10-bit halves and only increment the lower
10 on non-jump fetches.

### 7. PENV power-on default

**Altirra §4.1 Table 5**: PENH typical power-up = $00, PENV
typical power-up = $FF.

**Our implementation**: returns $00 for both.

**Software impact**: lightpen-aware code (rare) sees the wrong
PENV idle value.

**Folded into fix #1** — when we make write-only addresses read
$FF, $D40D (PENV) lands on $FF naturally.

## Summary

| ID | Issue                                          | Severity | Effort | Status |
|---:|------------------------------------------------|----------|-------:|:------:|
|  1 | Write-only registers read $FF (not 0/stored)   | Medium   | XS    | ✓ fixed |
|  2 | NMIST low bits 0..4 always 1                   | Medium   | XS    | ✓ fixed |
|  3 | Reset over-clears non-DMACTL/NMIEN registers   | Low      | XS    | ✓ fixed |
|  4 | End-of-frame VCOUNT anomaly                    | Cosmetic | M     | future |
|  5 | WSYNC release at cycle 105 (vs line_start)     | **Bug**  | M     | tracked in [Issues.md](Issues.md) |
|  6 | Display-list 1K boundary wrap                  | **Bug**  | S     | tracked in [Issues.md](Issues.md) |
|  7 | PENV default $FF                               | Cosmetic | XS    | ✓ folded-into-#1 |

Items 1, 2, 3, 7 landed as a single audit pass — all 31 sim
targets pass after the fixes (`tb_snoop` extended with $FF readback
checks for DMACTL / CHACTL / HSCROL / PMBASE / PENV; `tb_nmi`
expectations updated for the NMIST bits-0..4 = 1s pattern).

Items 5 and 6 are deferred until the architectural prerequisites
land (cycle-accurate bus model for #5; SALLY-on-FPGA for both),
but they ARE genuine bugs against real ANTIC behaviour and not
just cosmetic deviations — so they're now logged in
[`Issues.md`](Issues.md) so they don't fall off the radar.

Item 4 (end-of-frame VCOUNT) genuinely is a cosmetic edge case —
1-cycle visibility on the very last scan line of every frame —
that would only ever bite a DLI handler indexing a table by
VCOUNT during the wrap, which is exceptionally rare.
