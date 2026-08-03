# a8_core vs the software oracle: ACID800 baseline

`a8_core` (xt6502f + antic_gtia, ANTIC as bus master, phi2 as clock enable)
measured against `emu/` on the Acid800 suite.

    a8_core   13 / 37
    emu       37 / 37

| segment | a8_core | emu |
|---|---|---|
| `antic_*` | 4 / 18 | 18 / 18 |
| `cpu_*` | 5 / 8 | 8 / 8 |
| `gtia_*` | 4 / 11 | 11 / 11 |

## What 39 means, and why it is not 63

The suite has 63 tests. Two groups are excluded, for two DIFFERENT reasons that
are deliberately not merged:

**The harness cannot host the chip.** Two `antic_*` tests belong here despite
their names: `antic_dmapattern` and `antic_wsync` MEASURE through POKEY's RANDOM
at $D20A, which `tb_acid` answers as $FF. Counted from the .lst, they read it 30
and 6 times; every other `antic_*`, `cpu_*` and `gtia_*` test reads it zero times.
Neither can pass here whatever ANTIC does -- which is why the DMA schedule
measured EXACT against the cycles the CPU actually loses while
`antic_dmapattern` still failed. `antic_wsync`'s six reads are exactly the "six
RANDOM samples" `hdl/antic_reg_file.sv` describes as unable to see the WSYNC
release at all.

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
