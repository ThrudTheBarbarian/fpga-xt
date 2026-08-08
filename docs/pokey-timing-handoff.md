# POKEY timing — session handoff

State: ACID **55/58 — zero failing tests**. Tree carries a sibling session's
dirt (`sim/acid.mem` / `sim/acid_cfg.mem` / `rsrc/acid800/` / the
`corners.png` deletion must never be committed — always
`git commit --only <paths> -F -`).

**All six live failures are cleared**: `pokey_timertiming`,
`pokey_inittiming`, `mmu_xlbanking`, `antic_wsync`, `antic_dlitiming`,
`pokey_sertiming`. Mechanisms are in their commits (`7864a3c`, `9e31c42`,
`35c8faa`, `4bb8ad0`, `e927949`, `005b84f`). The remaining non-passes are
three legitimate SKIPs (`cpu_65c816`, `pokey_serdirect`, `pokey_skstat`)
and the five verdict-less `mod_*` demos — see "One decision for Simon".

Durable mechanisms now in the RTL:

- The pair's AUDF rewrite window anchors at the *lagged* underflow event;
  its seed runs `1 + PAIR_IRQ_LAG` short of `per − age`.
- STIMER cancels a fresh raise at `st_lag == IRQST_LAG` (not LAG−1); an
  IRQEN enable arms a bit in flight, a disable never disarms one.
- ch1's fast counter is nine bits (AUDF ≥ `$FD` overflowed eight).
- Two-tone lengthens every period but the first (unlinked reload, linked
  16-bit reload, and the rewrite window with it); timer 2's underflow
  resyncs timer 1 two cycles behind; force break + two-tone runs ch1's
  first period three longer.
- A base-clocked underflow takes one cycle to the status bit; the
  release-phase ticks stay at Altirra's 22/81.
- XL ROM banking decodes in `a8_core` (PORTB latch; armed by the first
  latch change since reset — the harness boots OS-less).
- A WSYNC write landing ON the release cycle misses this line; an RMW's
  second write there arms a FRESH halt.
- NMI takes the same two-stage poll as IRQ (the third stage compensated
  for the old WSYNC release error and is gone).
- A fast-linked pair's SERIAL clock is its own divider: 3-cycle STIMER
  defer + full `AUDF16+7` first period + 3-cycle borrow, free-running
  through init release. The interrupt edge keeps its short `AUDF16+4`
  first period. Known gap: mid-flight AUDF rewrites are not yet routed to
  the serial divider (no test currently exercises it).

Bitstreams: build 2 (through the NMI fix) is timing-closed in
`vivado/build/`; build 3 (adds the serial divider) was kicked — check the
scratchpad `bitstream_build3.log`, gate WNS ≥ 0.

## The oracles — read them, don't grep them

- emu — `emu/pokey_timer.c`, `emu/antic.c` (note: `emu/*.c`)
- Altirra — `/Users/simon/src/AltirraSDL/src/ATAudio/source/pokey.cpp`
- tests — `docs/Acid800/src/<test>.s`, which embed their own cycle tables

Altirra states in one line what takes paragraphs to infer from emu; the
test sources embed the numbers the assertions actually use. When a
reference would fail the test on your reading, your reading is
incomplete — measure the event's absolute cycle before touching anything.

## Instruments — use these, don't rebuild them

- `+PROBE=1` — PC trail into `_testFailed` plus the `d0..d7` dump.
  **`d1` is the assert's actual accumulator** (`_ASSERT` does `sta d1`).
- `+STPROBE=<n>` — STIMER anchor; T1/T2 underflow, IRQST bit 0/1
  readable, SKCTL/SEROUT/AUDF2 writes, raw pair wraps, shifter
  load/done edges, the regs-level STIMER strobe with `st_lag0`, two-tone
  suppress/resync, every IRQST read (200-print budget). **`din` prints
  the address-cycle value, one ahead of what the CPU latches**; the CPU
  latches at the END of the read cycle. One-clk pulses registered ON the
  tick edge are invisible to tick-gated probes — follow a state edge
  instead.
- The `said:` string is stack-derived and reliable; `grep -n` it in the
  `.s` — the line number is the distance measure.
- `.lst` files at `rsrc/acid800/Acid800/standalone/<test>.lst` map PC →
  source line.

## Harness facts that cost real time

- `make acid2v TEST=<t> PLUSARGS="..."` must run from `sim/` (~5s).
- Sweep: `sweep_vl.sh` (session scratchpad; patch its `S=` path, and it
  copies `sim/atari_*.mem` ROM images into worker dirs). Binary from
  `sim/build/vobj2/tb_acid2v`. Read `$S/sweep_<TAG>.txt`: 64 lines +
  `SWEEP COMPLETE`, 2–6 min.
- The shell CWD both persists and resets — absolute
  `cd /Users/simon/src/fpga-xt/sim &&` every time.
- Publish: `python3 docs/a800/from-sim.py <sweep> --core antic2 --note
  "..."`, commit the new `docs/a800/runs/*.json` with `index.html`.
- Bitstream: `nohup bash vivado/run-valhalla.sh bit` from repo root,
  ~8 min, gate on the per-clock WNS lines in the log.

## Method lessons worth carrying

- **Measure the event's absolute cycle before any substitution.** Every
  fix this session started as a probe line; two "contradictions" in the
  handoff dissolved under measurement.
- **Port the structure, not the number; port a decomposition atomically.**
- **Two tests sharing a constant can over-constrain it** — the resolution
  is usually a missing pipeline stage or a second divider, not a retuned
  constant (base-clock status lag; the pair's serial divider).
- **A calibration can be compensating for a bug elsewhere** — the third
  NMI stage existed only because the WSYNC release was a cycle late.
- **Re-run every known-failing test periodically.**

## One decision for Simon

Three `mod_*` tests are scored `error` and counted in the 58, but none of
the five `mod_*` files contains a single `_ASSERT` or `_testPassed` — they
are demos with no verdict. Two (`mod_options`, `mod_vbxe80`) hang waiting
on a keypress via `CH` (`$02FC`), which the harness can never deliver;
`mod_scroll40`'s hang at pc `$5422` is undiagnosed and has no `waitkey`.
`from-sim.py` already maps `RAN → na`; whether these three should also be
`na`, or the harness should poke a key into `CH`, is a scoring decision —
reclassifying would lift 55/58 to 55/55 without improving the design.
