# POKEY timing — session handoff

State: ACID **51/58**, tree carrying a sibling session's dirt
(`sim/acid.mem` / `sim/acid_cfg.mem` / `rsrc/acid800/` / the `corners.png`
deletion must never be committed — always `git commit --only <paths> -F -`).

**`pokey_timertiming` and `pokey_inittiming` both PASS.** The mechanisms that
did it are documented in their commits (`7864a3c`, `9e31c42`); the durable
lessons: the pair's rewrite window anchors at the *lagged* underflow event;
STIMER cancels a fresh raise at `st_lag == IRQST_LAG` (not LAG−1); an IRQEN
enable arms a bit in flight; ch1's fast counter is nine bits; two-tone
lengthens every period but the first and resyncs timer 1 off timer 2 two
cycles behind; force break + two-tone runs ch1's first period three longer;
and a base-clocked underflow takes one cycle to the status bit (the analogue
of Altirra's universal +3 borrow) while the release-phase ticks stay at
Altirra's 22/81.

## The four remaining failures

1. **`pokey_sertiming`** — "Serial output register was loaded too early."
   Rides the serial edge; untouched by all timer work.
2. **`mmu_xlbanking`** — needs ROM + PORTB banking. `a8_core.sv` has **no ROM
   decode at all**. ROMs exist: `rsrc/atari-xl.rom` (16K), `rsrc/atari-basic.rom`
   (8K). `mmu_xlbanking.s:39-58` drives `portb` = `$c2`/`$f3`/`$f0`/`$72`
   expecting `$0f`/`$03`/`$0d`/`$0f` — kernel, BASIC **and** self-test.
   `pia_regs.sv:43-48` already exposes `portb_out_q`. Worth exactly **one**
   test. Risk: ROM at `$A000`/`$C000` changes what every test sees — sweep
   early.
3/4. **`antic_wsync`** and **`antic_dlitiming`** — both on the shared CPU
   IRQ/NMI latency lever (`xt6502f.sv:120-123`), also relied on by
   `pokey_irqtiming` and `antic_blockednmi`. One-test upside on a shared lever.

## The oracles — read them, don't grep them

- emu — `emu/pokey_timer.c` (note: `emu/*.c`, there is no `emu/src/`)
- Altirra — `/Users/simon/src/AltirraSDL/src/ATAudio/source/pokey.cpp`
- tests — `docs/Acid800/src/<test>.s`, which **embed their own cycle tables**

Altirra states in one line what takes paragraphs to infer from emu; the test
sources embed the numbers the assertions actually use. When a reference would
fail the test on your reading, your reading is incomplete — measure the
event's absolute cycle before touching a constant.

## Instruments — use these, don't rebuild them

- `+PROBE=1` — PC trail into `_testFailed` plus the `d0..d7` dump. `_ASSERT`
  does `sta d1` before `jsr _testFailed`, so **`d1` is the actual
  accumulator**.
- `+STPROBE=<n>` — STIMER cycle, T1/T2 underflow deltas, IRQST bit 0/1
  readable deltas, SKCTL writes, AUDF2 writes, the regs-level STIMER strobe
  with `st_lag0`, two-tone suppress/resync events, every IRQST read. **Its
  `din` is the address-cycle value, one cycle ahead of what the CPU
  latches** — never tune RTL to make it print a nice number. The CPU latches
  read data at the END of the read cycle: a bit that becomes visible on the
  cycle the test samples reads as ALREADY PENDING.
- The `said:` string is reconstructed from the return address on the stack
  (`tb_acid.sv` ~line 1290) — reliable; `grep -n` it in the `.s`: **the line
  number is the distance measure.**
- `.lst` files at `rsrc/acid800/Acid800/standalone/<test>.lst` map PC → source
  line and show macro bodies.

## Harness facts that cost real time

- `make acid2v TEST=<t> PLUSARGS="..."` must run from `sim/` (~5s; regenerates
  `acid.mem`).
- Sweep: `sweep_vl.sh` (copy in session scratchpad; hardcodes `S=` — patch it
  when the scratchpad moves). `cp sim/build/vobj2/tb_acid2v $S/<bin>`, then
  `nohup bash $S/sweep_vl.sh $S/<bin> <TAG>`, then **read
  `$S/sweep_<TAG>.txt`** — 64 lines + `SWEEP COMPLETE`, 2–6 min. Header-only
  **with** processes = slow; **without** = dead.
- The shell CWD both persists and gets reset — use absolute
  `cd /Users/simon/src/fpga-xt/sim &&` for every make.
- After a failed edit script, `git status` before believing the next
  measurement.
- Publish: `python3 docs/a800/from-sim.py <sweep> --core antic2 --note "..."`,
  then commit the new `docs/a800/runs/*.json` with `index.html`.

## Method lessons worth carrying

- **Measure the event's absolute cycle before any substitution** — every fix
  this session started as a probe line, and the "unfound gate" in inittiming
  was a mis-computed window.
- **Port the structure, not the number; port a decomposition atomically.**
- **Two tests sharing a constant can over-constrain it** — timertiming pins
  the release-phase *ticks*, inittiming the *status* cycle after them; the
  resolution was a new pipeline stage, not a retuned constant.
- **The same total by a different decomposition is a trap** — tests measure
  the terms separately.
- **Re-run every known-failing test periodically.**
- Returning to baseline is neutral, not a win.

## One decision for Simon

Three `mod_*` tests are scored `error` and counted in the 58, but **none of
the five `mod_*` files contains a single `_ASSERT` or `_testPassed`** — they
are demos with no verdict. Two (`mod_options`, `mod_vbxe80`) hang waiting on
a keypress via `CH` (`$02FC`), which the harness can never deliver;
`mod_scroll40`'s hang at pc `$5422` is undiagnosed and has no `waitkey`.
`from-sim.py` already maps `RAN → na`; whether these three should also be
`na`, or the harness should poke a key into `CH`, is a scoring decision —
reclassifying would lift the number by three without improving the design.
