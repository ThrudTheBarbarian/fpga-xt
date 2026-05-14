# POKEY accuracy audit vs. Altirra reference manual

Source: *Altirra Hardware Reference Manual* by Avery Lee, Chapter 5 (POKEY) and
Appendix E (Analog Audio Model), in `docs/altirra-reference-manual.pdf`.

This audit cross-checks our POKEY implementation (`hdl/pokey_audio.sv`,
`hdl/pokey_regs.sv`, `hdl/pokey_pot.sv`, `hdl/pokey_i2s_tx.sv`) against the
Altirra description, which is the most authoritative POKEY model in the
emulator world.

The findings are split into **must-fix** (audibly or programmatically wrong)
and **cosmetic** (analog-quality issues that affect waveform shape but not
pitch, notes, or registers).

## Must-fix correctness bugs

### 1. Linked-pair (16-bit) timer math is wrong

**Altirra §5.3 "Linked timers"**: when AUDCTL[4]=1 (or AUDCTL[3]=1), the high
timer (ch2 / ch4) is clocked by the *output* of the low timer, **and the
automatic reload on the low timer is suppressed** so the low timer counts
through the full 16-bit cycle. The combined period is `(N1 + 256·N2 + 1)`
clock units, where N1 = AUDF1 + 256·AUDF2.

**Our implementation** (`pokey_audio.sv` §"per-channel tick sources"):
`ch2_tick = audctl[4] ? ch1_wrap : ref_tick`. This makes ch2 advance only on
ch1 wraps — but our ch1 still auto-reloads from AUDF1 every (AUDF1+1) ticks.
The combined period is therefore `(AUDF1+1) × (AUDF2+1)` ticks, not
`(AUDF1 + 256·AUDF2 + 1)`.

Example with AUDF1 = $01, AUDF2 = $01:
- Spec: 257·1 + 1 + 1 = 259 ticks
- Ours: 2·2 = 4 ticks
- **Pitch is ~64× too high** in linked mode at this setting.

**Fix shape**: in linked mode, suppress the low-channel auto-reload. The low
counter underflows from AUDF, then continues `$FF, $FE, …, $00, $FF, …`
until the high counter reaches 0; both reload simultaneously when the high
counter underflows.

### 2. High-frequency channel mode runs at the fabric rate, not the 6502 rate

**Altirra §5.4 "Clock generation"**: AUDCTL[6] / AUDCTL[5] route the
**1.79 MHz machine clock** (i.e., 6502 phi2) to ch1 / ch3 respectively.
That's the slow Atari machine clock — not the fast FPGA fabric clock.

**Our implementation**: `ch1_tick = audctl[6] ? 1'b1 : ref_tick`. The
channel counter decrements every fabric clock when high-freq mode is
on — fabric runs at some integer (or fractional) multiple of phi2, so
the channel runs at that same multiple of the spec rate.

Example: AUDF1=0 in high-freq mode should give an audio rate of
roughly `phi2_hz / 4` (timer period = 4 cycles → toggle at half =
phi2/8). With clk_bus = N · phi2 we currently produce N× that rate —
audibly broken at any N > 1.

**Fix shape**: pokey_audio should consume a 1-fabric-cycle `phi2_tick`
strobe from outside (gated by the system's phi2-divider) rather than
deriving anything from a fixed multiplier. The existing CLK_BUS_HZ
parameter is enough to compute the 64 kHz / 15 kHz reference dividers,
but the phi2 strobe is bus-side knowledge — pass it in as a port. This
keeps the design generic across CLOCK_MULT choices and across
SALLY-on-FPGA variants where phi2 may not be a clean integer fraction
of the fabric clock.

### 3. POT scan counter ticks on the wrong reference

**Altirra §5.9 "Polling mechanism"**: "the polling counter is driven by the
same clock that is used by the keyboard scan" — i.e., **always 15 kHz**
(unless SKCTL[2]=1 fast-scan, then 1.79 MHz machine clock). The 64 kHz
clock is **not** used for POT scan.

**Our implementation** (`pokey_pot.sv`): increments on `ref_tick`, which is
selected by AUDCTL[0]. So when software writes AUDCTL[0]=0 (default 64 kHz
audio), the pot scan ticks at 64 kHz — ~4× faster than real POKEY, giving
counts ~4× lower than expected.

**Fix shape**: feed `ref_tick_lo` (the 15 kHz strobe) directly to
`pokey_pot`, ignoring AUDCTL[0]. SKCTL[2]=1 selects machine clock instead.

### 4. 9-bit LFSR tap is wrong

**Altirra §5.5 "9/17-bit noise generator"**: the 9-bit polynomial is
`1 + x⁴ + x⁹` (Fibonacci form: tap at indices 3 and 8).

**Our implementation**: `lfsr9_q[8] ^ lfsr9_q[4]` — uses index 4, which
implements `1 + x⁵ + x⁹`. This is the *reciprocal* polynomial — also
primitive, so still maximal-length 511, but the bit pattern is **mirrored**.

Period and noise distribution unchanged; the actual byte sequence visible
through `RANDOM` differs.

**Fix shape**: change tap to `lfsr9_q[8] ^ lfsr9_q[3]`.

### 5. 17-bit LFSR tap is wrong

**Altirra §5.5**: 17-bit polynomial is `1 + x¹² + x¹⁷` (taps 11 and 16).

**Our implementation**: `lfsr17_q[16] ^ lfsr17_q[13]` — implements
`1 + x¹⁴ + x¹⁷`, which is the reciprocal of `1 + x³ + x¹⁷` (also primitive).
Same situation as above — period and statistics correct, byte sequence
different.

**Fix shape**: change to `lfsr17_q[16] ^ lfsr17_q[11]`.

### 6. Serial IRQ bits 3 and 4 are swapped vs. POKEY

**Altirra §5.7 + §5.6**:
- bit 3 = **Serial output complete** (output shift register idle).
  Special: not latched, simply active whenever the shifter is idle.
- bit 4 = **Serial output ready / needed** (SEROUT just loaded into shift
  register, ready for the next byte).

**Our implementation** (`pokey_regs.sv`):
- bit 3 = `ser_out_needed_pulse`  ← should be bit 4
- bit 4 = `ser_out_done_pulse`     ← should be bit 3

**Fix shape**: swap the two source pulses in the IRQ-latch case statement,
and document bit 3's no-latch semantics (drive directly from a "shifter
idle" wire instead of a 1-cycle pulse latched into a flop).

### 7. Timer period off by +3 cycles in machine-clock mode

**Altirra §5.3 "Timer period"**: at 1.79 MHz with AUDFx = N, the timer
period is **N+4 cycles** (3 cycles of pipeline delay added to the N+1 of
the basic countdown).

**Our implementation**: period is N+1 ticks regardless of mode.

For 64 kHz / 15 kHz modes the spec is `(N+1) × 28` and `(N+1) × 114`, with
the 3-cycle delay absorbed by waiting for the next reference tick — so our
N+1-ref-ticks math matches there. The 3-cycle delay matters only at machine
clock and for serial-bit timing.

**Fix shape**: when running at the (future, see fix #2) 1.79 MHz strobe,
add a 3-cycle delay to the underflow→reload path.

### 8. STIMER ($D209 write) is unwired

**Altirra §5.3 "Resetting the timers"**: STIMER write reloads all four
timer counters and forces all output flip-flops to 1 (which is audible
in the high-pass-disabled case since channels 1+2 invert relative to
3+4). It does **not** fire the timers — no IRQs or audio pulses emitted.

**Our implementation**: writes to $D209 land in the `default` arm of the
write decoder and are ignored.

**Fix shape**: add a `stimer_pulse = we && waddr[3:0]==4'h9` and feed it
to `pokey_audio` to reload `ch{1..4}_cnt` from `audf{1..4}` on the next
cycle. Output flip-flops to 1.

## Cosmetic deferrable findings (Appendix E)

These describe analog post-POKEY behavior that we'll never reproduce
bit-exact in HDMI digital audio. Worth documenting but not fixing.

### A. DAC bit weights aren't equal

**Appendix E.2 "Channel DAC"**: voltage drops per volume bit are
approximately {0.12 V, 0.26 V, 0.56 V, 1.12 V} — close to powers of 2 but
not exact. This is what gives the "gaps" between volume levels 3↔4, 7↔8,
11↔12.

**Our implementation**: linear vol = audc[3:0] (perfect 4-bit DAC).

Defer — barely audible.

### B. Non-linear saturation at high total volume

**Appendix E.2**: the summed channel output is roughly linear up to total
volume 12, then saturates exponentially. Hand-fitted approximation:
```
y = 2.171·x          for x ≤ 0.14
y = 2.171·(0.14 + (1 - e^(-2.85·(x-0.14))) / 2.85)   for x ≥ 0.14
```

**Our implementation**: linear sum, scaled to 24-bit LPCM (`sum << 18`).
We'll never push hard into saturation territory anyway since HDMI sinks
AC-couple. Defer.

### C. High-pass coupling (analog stages 1 & 2)

**Appendix E.3, E.5**: first amplifier τ ≈ 2.6 ms, second amplifier
τ ≈ 24.7 ms. These give POKEY its characteristic decay tail and the
inability to play sustained DC offsets.

**Our implementation**: no high-pass on the digital output. HDMI sinks
have their own AC coupling at the analog DAC stage. Defer.

### D. Polarity convention

**Appendix E.2**: real POKEY output is *positive at silence* and drops
toward 0 V as channels become active. This is unbalanced.

**Our implementation**: positive-going LPCM (silence at 0, max output
positive). After AC coupling at the sink this is sign-equivalent.

Acceptable. Document only.

## Summary

| ID | Issue                                                       | Severity | Effort | Status |
|---:|-------------------------------------------------------------|----------|-------:|:------:|
|  1 | Linked-pair (16-bit) timer math wrong                       | High     | M     | ✓ fixed |
|  2 | High-freq channel mode rate-tied-to-fabric                  | High     | S     | ✓ fixed |
|  3 | POT scan ticks on wrong reference clock                     | Medium   | XS    | ✓ fixed |
|  4 | 9-bit LFSR tap (x⁵ instead of x⁴)                           | Low      | XS    | ✓ fixed |
|  5 | 17-bit LFSR tap (x¹⁴ instead of x¹²)                        | Low      | XS    | ✓ fixed |
|  6 | Serial IRQ bits 3/4 swapped + bit 3 unlatched               | Medium   | XS    | ✓ fixed |
|  7 | Timer period N+4 / N+7 in machine-clock mode                | Low      | S     | ✓ fixed |
|  8 | STIMER ($D209) unwired                                      | Medium   | S     | ✓ fixed |
|  A | DAC bit weights not power-of-2                              | Cosmetic | M     | future |
|  B | Non-linear saturation                                       | Cosmetic | S     | future |
|  C | Analog high-pass coupling                                   | Cosmetic | M     | future |
|  D | Polarity / DC offset                                        | Cosmetic | XS    | future |

**All 8 must-fix items landed**. Verified via dedicated tb_pokey phases:
- Phase F (linked-pair 16-bit period = AUDF1 + 256·AUDF2 + 1)
- Phase L (STIMER reloads all four counters)
- Phase M (unlinked machine-clock period N+4 in pure-tone mode)
- Phase N (linked machine-clock period N+7 in pure-tone mode)

Plus Phase K updated for the new IRQ bit-3/4 semantics, Phase D / E for
the corrected LFSR taps, Phase J retimed to the 15 kHz POT clock.

Implementation note for fix #7: applied as a +3 fudge on the AUDF
reload value in unlinked machine-clock mode, +6 fudge in linked
machine-clock mode (the cascade reset adds 3 extra cycles per
Altirra). Inner FF-wraps in linked mode are not fudged — they wrap to
$FF without alteration. Ref-clock modes are unaffected (the 3-cycle
delay is absorbed in the wait for the next reference tick).

**Cosmetic items A-D** are recorded in `docs/future-work.md` under
"Analog audio fidelity" — these are HDMI-irrelevant in our digital path
and only matter if a "purist" mode is ever pursued.
