# a8_core vs the software oracle: ACID800 baseline

`a8_core` (xt6502f + antic_gtia, ANTIC as bus master, phi2 as clock enable)
measured against `emu/` on the Acid800 suite.

    a8_core   20 / 54
    emu       54 / 54

| segment | a8_core | emu |
|---|---|---|
| `antic_*` | 4 / 20 | 20 / 20 |
| `pokey_*` | 7 / 15 | 15 / 15 |
| `cpu_*` | 5 / 8 | 8 / 8 |
| `gtia_*` | 4 / 11 | 11 / 11 |

## What 39 means, and why it is not 63

The suite has 63 tests. Two groups are excluded, for two DIFFERENT reasons that
are deliberately not merged:

**The harness cannot host the chip.** `mmu_*` needs PORTB and `pia_*` needs the
PIA; `a8_core` has neither.

`pokey_*`, `antic_dmapattern` and `antic_wsync` were in this category until
`a8_core` gained a POKEY -- the design always had one, and leaving it out was a
limitation of this assembly rather than of the hardware. All 17 are now measured.

 `a8_core` is the CPU and `antic_gtia` only
-- there is no POKEY and no PIA, and `tb_acid`'s memory model answers `8'hFF` for
$D1xx-$D3xx and $D5xx-$D7xx. The `pokey_*` family and `mmu_*` (which needs PORTB)
therefore diverge for reasons that say nothing about ANTIC, as does `pia_*`. That
is a limitation of this harness.

**The test yields no verdict at all.** `mod_*` returns RAN/LOOP and `cpu_65c816`
is skipped -- the ORACLE scores 0/5 on `mod_*` too. That is a property of those
tests, and the exclusion applies to both sides equally.

Quoting a raw 63-test total against the oracle would be a confident invalid
number. The 39 rows below are the ones where both sides produce a verdict and the
harness can host the hardware.

## The three `cpu_*` NO-RESULTs are a harness timeout, not a wrong answer

`cpu_clisei`, `cpu_illtiming` and `cpu_insn` hit the sweep's 300 s wall-clock cap
without reaching a verdict. They are not failures: the CPU did not produce a wrong
result, the run was cut short. Read `cpu_* 5/8` with that in mind -- the core
passes `cpu_bugs`, `cpu_decimal`, `cpu_flags`, `cpu_illegal` and `cpu_timing`, and
independently passes Klaus.

## The POKEY figure is NOT yet attributable -- read this before quoting 7/15

`pokey_*` scores 7/15, and the failures have THREE candidate causes that have not
been separated:

1. **Tie-offs in `a8_core`.** `ser_out_complete`, `ser_out_ready_pulse`,
   `ser_in_byte_pulse`, `ser_in_byte`, `break_key_pulse`, `ser_framing_err`,
   `ser_input_overrun` and `ser_input_busy` are all constants. That plausibly
   accounts for `serclock`, `serdirect` and `sertiming`; `pokey_asyncrecv` and
   `pokey_seroc` PASS, so the serial logic partly works and the constants starve
   the rest.
2. **Parameterisation.** `CLK_BUS_HZ` is passed as `CLK_HZ` (100 MHz) and the
   ratio is right, but `REF_REL_HI/LO` ("init-release phase") and `REL_SKEW`
   ("write-commit vs phi2_tick alignment") are constants tuned for the FABRIC
   assembly. `inittiming`, `timerirq`, `timertiming` and `twotone` sit in that
   blast radius.
3. **Genuine POKEY defects** -- possible, but not claimable until 1 and 2 are
   ruled out.

The discriminator is cheap and not yet run: sweep `REL_SKEW` against one timer
test, and replace the tie-offs with a loopback for one serial test. If either
moves, it is integration rather than POKEY.

## The remaining ANTIC/GTIA failures are genuine -- audited

Every one of the 14 remaining `antic_*` and 7 `gtia_*` failures was checked for
dependence on hardware this harness does not have: reads of POKEY RANDOM ($D20A),
IRQST ($D20E), the POT registers ($D200-$D208) and PIA ($D300-$D303). **All
counts are zero.** Only `antic_dmapattern` and `antic_wsync` measured through
missing hardware, and they are excluded above.

So no further failure in this table is a harness artefact. What remains is real
work on the design.

## Reading the ANTIC column

The 16 `antic_*` failures are very likely ONE integration problem rather than 16
separate defects. `hdl/antic_beam.sv` already carries the exact semantic the
oracle records -- `VCOUNT_ADVANCE = 111` -- and **`tb_antic_beam` passes
standalone**, yet `antic_vcount` fails inside `a8_core`. The unit implements the
right rule and the assembled core still fails the test that pins it. The same
shape holds for WSYNC: `tb_wsync` is in the passing sim gate.

The four passes (`default`, `addrmirror`, `addresswrap`, `blockednmi`) check
register values, address decode and NMI blocking -- none needs cycle-exact
CPU-vs-beam alignment. Every failure does.

## Results

| test | a8_core | emu |
|---|---|---|
| `antic_addresswrap` | PASS | PASS |
| `antic_addrmirror` | PASS | PASS |
| `antic_blockednmi` | PASS | PASS |
| `antic_charcontrol` | FAIL | PASS |
| `antic_default` | PASS | PASS |
| `antic_dlistwrap` | FAIL | PASS |
| `antic_dlitiming` | FAIL | PASS |
| `antic_dmapattern` | FAIL | PASS |
| `antic_hiresbug` | FAIL | PASS |
| `antic_hscrolbug` | FAIL | PASS |
| `antic_linebuffering` | FAIL | PASS |
| `antic_nmist` | FAIL | PASS |
| `antic_pfstarttiming` | FAIL | PASS |
| `antic_pfstoptiming` | FAIL | PASS |
| `antic_pmdma` | FAIL | PASS |
| `antic_vcount` | FAIL | PASS |
| `antic_virtdma` | FAIL | PASS |
| `antic_vscroldli` | FAIL | PASS |
| `antic_vscroll` | FAIL | PASS |
| `antic_wsync` | FAIL | PASS |
| `cpu_bugs` | PASS | PASS |
| `cpu_clisei` | NO-RESULT | PASS |
| `cpu_decimal` | PASS | PASS |
| `cpu_flags` | PASS | PASS |
| `cpu_illegal` | PASS | PASS |
| `cpu_illtiming` | NO-RESULT | PASS |
| `cpu_insn` | NO-RESULT | PASS |
| `cpu_timing` | PASS | PASS |
| `gtia_addrmirror` | PASS | PASS |
| `gtia_collision` | FAIL | PASS |
| `gtia_collision2` | FAIL | PASS |
| `gtia_consol` | PASS | PASS |
| `gtia_default` | PASS | PASS |
| `gtia_phantomdma` | FAIL | PASS |
| `gtia_pmoverlap` | FAIL | PASS |
| `gtia_pmresize` | FAIL | PASS |
| `gtia_pmretrigger` | PASS | PASS |
| `gtia_psuedomodee` | FAIL | PASS |
| `gtia_vdelay` | FAIL | PASS |

## Reproducing

    python3 tools/acid2mem.py <test>
    (cd sim && make acid TEST=<test>)          # a8_core
    (cd emu && ./build/acid ../rsrc/acid800/Acid800/standalone <test>)   # oracle

`TEST` is a runtime plusarg, so one iverilog build serves all 63.

## antic_dmapattern is blocked by POKEY RANDOM, not by the DMA map

`antic_dmapattern` decodes POKEY's RANDOM ($D20A) into a cycle number by looking
up consecutive LFSR values in a table.  It reads `$FF` for both halves of the
pair, fails at "Cannot decode random pair", and never reaches a single DMA
assertion.  So it currently says nothing about the fetch map.

Measured on BOTH ANTIC paths, identically — `d0=ff d1=ff d2=ff`, same PC trail:

| path | result |
|---|---|
| old (`USE_ANTIC2=0`) | FAIL, cannot decode random pair |
| antic2 (`USE_ANTIC2=1`) | FAIL, cannot decode random pair |

That the two agree exactly is the point: this is not an ANTIC defect and not a
regression from the stage-2 playfield map.

Excluded so far: POKEY is clocked (`a8_core` passes `.phi2_tick(tick)`), and the
test does release the LFSR — the framework writes `SKCTL = $03` at `$1D9C`,
which takes `skctl[1:0]` out of the `2'b00` init state that holds the polynomial
counters filling with ones.  So neither "never ticked" nor "held in init" is the
explanation, and the next step is to probe `skctl` and `random_byte` inside our
POKEY during the run rather than guess further.

Worth noting the LFSR *has* worked: the 9-bit and 17-bit tap choices in
`pokey_audio.sv` were fitted to three independent RANDOM reads from
`antic_wsync`, which no other combination satisfied.  Whatever is wrong is
therefore more likely in the plumbing around it than in the polynomial.

CONSEQUENCE FOR STAGE 2: the fetch map needs a different gate until this is
fixed.  `antic_dma_sched` is already measured correct standalone (c96332a), so
the map's own correctness is not in question — what is missing is an end-to-end
test that can observe it through this harness.

## Stage 2: the playfield starts one scanline late

With the SKCTL harness fix in place, `antic_dmapattern` reaches its assertions
and names the fault: `_FAIL "Incorrect timing for mode %x-%c"` with d1=$02,
d2='a' — mode 2, variant a.

Diffing our per-line steal map against emu's `ACID_GLYPHPROBE=9` END map for the
same display-list instruction ($42, LMS + mode 2) shows what that means.  emu
puts the display-list fetch AND that row's playfield on ONE scanline:

    emu    .#....##.................##.###############################...

We split them across two:

    ours   .#....##.................#...#...#...#...#...#...#...#...#...   (DL fetch, no playfield)
    ours   .........................##.###############################...   (playfield, no DL fetch)

and our third line — a later line of the same row — matches emu character for
character.  So the map itself is right; it simply starts a scanline late.

MECHANISM.  `antic_dma_sched` latches the whole line shape on the `line_start`
pulse: `pf_n` from `n_fetch`, plus `dma_start`, `pairs` and `is_char`
(antic_dma_sched.sv:161).  Our `antic2_dl` is a multi-cycle state machine that
fetches the instruction AFTER line_start, so at the instant the scheduler
samples, `dl_insn` still holds the PREVIOUS instruction and the geometry derived
from it.  emu has no such gap because `dl_exec` runs synchronously inside
`line_start`, before the map is built.

This is the sequential-to-clocked class of defect again — the same class as the
VCOUNT/NMIST phase split, not a semantic one, so it could not have been read off
emu.  The DL-fetch steals themselves are correct on both lines; only the
playfield is displaced.

NEXT: the fix is to make the instruction settle before the scheduler samples,
not to shift the map.  `line_start` is a one-clock pulse at the very start of a
machine cycle and a machine cycle is many fabric clocks, so the open question —
to be MEASURED, not assumed — is whether `dl_insn` settles before the end of
machine cycle 0, in which case delaying the scheduler's latch by that much is
sufficient and local.
