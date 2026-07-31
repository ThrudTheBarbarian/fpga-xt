# ACID800 — what each test actually checks

Avery Lee's Acid800 suite is the conformance gate for this project's 6502,
ANTIC, GTIA and banking work. The problem it poses is that the shipped `.lst`
listings inline the whole of `library.s` plus every macro expansion, so the ~50
lines that say what a test *checks* are buried under ~2000 lines of boilerplate.
This directory is that dug out once, so nobody has to dig again.

* **`src/`** — each test's own source, extracted from its `.lst`. This is the
  literal test, nothing added or paraphrased.
* **`<test>.md`** — what the test pins down, its assertions with expected
  values, and the hardware behaviour you have to implement to pass it.
* **`../../tools/acid800_extract.py`** — the extractor, if the suite is ever
  updated.

Acid800 is **MIT**-licensed (the notice is at the head of every extracted file),
so quoting it here is fine — unlike atari800 and Altirra, which are GPL and are
never vendored into this repo.

## A trap in the listings, worth knowing

`mads` emits a `Source: X` marker when it **enters** an include but **not** when
it returns from one. After `icl 'library.s'` the listing silently resumes in the
test's own file, so a naive reader attributes the entire test body to
`library.s` and is left with only the assertions. For `antic_wsync` that is the
difference between five bare expected values and the whole measurement. The
extractor detects the return by line numbers decreasing.

## How a test works

Every test is a standalone `.xex` that runs at `$2000`:

```
main:   ldy #>testname / lda #<testname / jsr _testInit
        jsr _screenOff          ; DMA off, so the CPU has every cycle
        jsr _interruptsOff
        ... the measurement, results into d0..d5 ...
        _ASSERT1 d0, $95, c"Initial RANDOM incorrect: $%x != $95.",0
        ... more assertions ...
        jmp _testPassed
```

* **`d0`–`d5`** are zero-page scratch at **`$C8`–`$CD`**.
* **`_ASSERT1 var, expected, msg`** expands to
  `lda var / cmp #expected / beq pass / sta d1 / jsr _testFailed / <msg> / pass:`
  — so a failure reports the value it got, and **the failure string states the
  expected value**. That is why these tests are self-documenting: every
  assertion carries its own specification.
* Result convention: **Y = `$00` pass / `$80` fail** at `_testEnd`.
* Other macros seen: **`_ASSERTA expected, msg`** (asserts the accumulator),
  **`_INITTEST name`**, **`_SKIP msg`** (bail out — used to skip NMOS-only tests
  on a CMOS CPU), and **`_FAIL msg`**. Several tests assert by **control flow**
  rather than by value: they place `_FAIL` in handlers that must never run, so
  "which handler was entered" is the answer.

## The one idiom you must implement first: POKEY RANDOM as a cycle clock

Most of the ANTIC timing tests measure *when the CPU resumed* by reading POKEY's
`RANDOM` register:

```
mva #$80 audctl         ; long (17-bit) noise mode
mva #0   skctl
sta wsync
lda #3
sta wsync
sta skctl               ; take the LFSR out of reset at a known scanline cycle
sta wsync
ldy random              ; the value now IS the cycle number, encoded
```

`RANDOM` is a free-running LFSR clocked at the machine clock, so once it has
been started at a known cycle its value is a **deterministic function of the
cycle count since reset**. The tests exploit that to read the exact cycle at
which the CPU got the bus back — with a resolution of one cycle and no timer
involved.

**Consequences for the software emulator**, both of which are load-bearing:

1. **A cycle-exact POKEY LFSR is a prerequisite for the ANTIC timing tests**,
   even though the plan keeps POKEY in hardware. The host/qemu test harness
   therefore needs a software POKEY `RANDOM` (17-bit and 9-bit modes, plus the
   `SKCTL` reset behaviour) before `antic_wsync`, `antic_vcount`,
   `antic_dlitiming` or `cpu_timing` can be run at all. It does not need the
   sound path — just the LFSR.
2. It is also the reason these tests are such a sharp instrument: they do not
   check "did the right thing happen", they check "did it happen on exactly this
   cycle".

## Scanline cycle numbering

ANTIC scanline cycles are numbered **0–113** (114 colour clocks per line). The
comments in the tests use this numbering directly, e.g. `sta wsync ;100-103`
means the four cycles of that store landed on 100, 101, 102 and 103.

Landmarks established by the tests (and matching this project's fabric work):

| cycle | what |
|---|---|
| 104 | WSYNC releases `/RDY` — the first CPU cycle after a WSYNC halt is **105** |
| 111 | VCOUNT advances |
| 8   | DLI fires (on the mapped physical scanline) |

## Index

Scored against the fabric baseline: **32 of 63 at sallyrst `$06`**, 27 at `$0A`,
ceiling 57 (five `mod_*` never halt by design, `cpu_65c816` is a probe).

| test | title | asserts |
|---|---|---|
| [antic_addresswrap](antic_addresswrap.md) | ANTIC: Address wrapping | 2 |
| [antic_addrmirror](antic_addrmirror.md) | ANTIC: Address mirroring | 0 |
| [antic_blockednmi](antic_blockednmi.md) | ANTIC: Blocked NMIs | 0 |
| [antic_charcontrol](antic_charcontrol.md) | ANTIC: Character control | 0 |
| [antic_default](antic_default.md) | ANTIC: Default value | 1 |
| [antic_dlistwrap](antic_dlistwrap.md) | ANTIC: Display list wrapping | 3 |
| [antic_dlitiming](antic_dlitiming.md) | ANTIC: DLI timing | 8 |
| [antic_dmapattern](antic_dmapattern.md) | ANTIC: DMA pattern | 0 |
| [antic_hiresbug](antic_hiresbug.md) | ANTIC: Hires bug | 2 |
| [antic_hscrolbug](antic_hscrolbug.md) | ANTIC: HSCROL bug | 8 |
| [antic_linebuffering](antic_linebuffering.md) | ANTIC: Line buffering | 0 |
| [antic_nmist](antic_nmist.md) | ANTIC: NMIST/NMIRES | 24 |
| [antic_pfstarttiming](antic_pfstarttiming.md) | ANTIC: Playfield start timing | 8 |
| [antic_pfstoptiming](antic_pfstoptiming.md) | ANTIC: Playfield stop timing | 8 |
| [antic_pmdma](antic_pmdma.md) | ANTIC: P/M graphics DMA | 0 |
| [antic_vcount](antic_vcount.md) | ANTIC: VCOUNT timing | 8 |
| [antic_virtdma](antic_virtdma.md) | ANTIC: Virtual DMA | 4 |
| [antic_vscroldli](antic_vscroldli.md) | ANTIC: VSCROL+NMI timing | 2 |
| [antic_vscroll](antic_vscroll.md) | ANTIC: Vertical scrolling | 0 |
| [antic_wsync](antic_wsync.md) | ANTIC: WSYNC timing | 6 |
| [cpu_bugs](cpu_bugs.md) | CPU: Bugs | 2 |
| [cpu_clisei](cpu_clisei.md) | CPU: CLI/SEI timing | 5 |
| [cpu_decimal](cpu_decimal.md) | CPU: Decimal mode | 4 |
| [cpu_flags](cpu_flags.md) | CPU: Flags | 0 |
| [cpu_illegal](cpu_illegal.md) | CPU: Illegal instructions | 0 |
| [cpu_illtiming](cpu_illtiming.md) | CPU: Illegal instruction timing | 0 |
| [cpu_insn](cpu_insn.md) | CPU: Basic instructions | 0 |
| [cpu_timing](cpu_timing.md) | CPU: Timing | 16 |
| [gtia_addrmirror](gtia_addrmirror.md) | GTIA: Address mirroring | 4 |
| [gtia_collision](gtia_collision.md) | GTIA: Collision | 13 |
| [gtia_collision2](gtia_collision2.md) | GTIA: Special modes collision | 58 |
| [gtia_consol](gtia_consol.md) | GTIA: CONSOL | 3 |
| [gtia_default](gtia_default.md) | GTIA: Default value | 1 |
| [gtia_phantomdma](gtia_phantomdma.md) | GTIA: Phantom PMG DMA | 1 |
| [gtia_pmoverlap](gtia_pmoverlap.md) | GTIA: Player overlap | 0 |
| [gtia_pmresize](gtia_pmresize.md) | GTIA: Player resizing | 0 |
| [gtia_pmretrigger](gtia_pmretrigger.md) | GTIA: P/M retriggering | 7 |
| [gtia_psuedomodee](gtia_psuedomodee.md) | GTIA: Pseudo mode E | 2 |
| [gtia_vdelay](gtia_vdelay.md) | GTIA: Vertical delay | 8 |
| [mmu_xlbanking](mmu_xlbanking.md) | MMU: XL banking | 10 |

`cpu_65c816` is a probe (detects a 65C816 and is expected to be skipped on a
6502); the five `mod_*` modules never halt by design; `pia_*` and `pokey_*` are
out of scope for the software 6502/ANTIC work but their sources are extracted
too.
