# POKEY timing — session handoff

State at handoff: **HEAD `a295560`**, tree clean, ACID **49/58**.
(`sim/acid.mem` / `sim/acid_cfg.mem` show dirty — those belong to a sibling
session and must never be committed. Nor `rsrc/acid800/`, nor the `corners.png`
deletion. Always `git commit --only <paths> -F -`.)

## What landed

Six commits, **every one ACID-neutral**: the score did not move from 49, and no
verdict changed in either direction. They are correctness fixes — each supplies a
mechanism the references have and our RTL did not.

| commit | mechanism |
|---|---|
| `f830450` | IRQ delivery lag split out of the timer counter. `stimer_apply = stimer_pulse` (the old `stimer_lag` held the reload off 4 cycles, i.e. the delivery lag buried in the counter); `IRQST_LAG=4` in delivery, **fast tap only**; `IRQ_LINE_LAG=1` on the asserting edge only. Underflow +24 → **+20**. |
| `77d6705` | The **full** `IRQST_LAG`. The `-1` had been fitted to my own probe; `d1=00` proved the bit was visible a cycle early. Plus `STIMER_CANCELS_FRESH` and the `+STPROBE` probe. |
| `d051000` | The AUDF latch window — a late write re-lengthens the period **already running**: `cnt = period - age`, gated `!linked && ch_age < CH_LATCH_LAG(3)`. |
| `64d4138` | The linked pair's low-half divider (`lo_cnt`). Timer 1 had been firing on the cascade wrap — every 256 ticks instead of every `AUDF1+7`. |
| `a295560` | A linked pair is **one 16-bit counter** (`AUDF16+LINK_FAST`, not a cascade at `AUDF16+4`), plus the high-half rewrite window `HI_LATCH_LAG=3`. |

Test movement: `pokey_timertiming` `:187 → :390 → :494 → :583` of 1249 lines
(baseline stopped at `:449`). `pokey_inittiming` `:79 → :116`.

## The oracles — read them, don't grep them

Two working implementations plus the test source. Altirra is usually blunter and
often states the rule in one line.

- emu — `emu/pokey_timer.c` (note: `emu/*.c`, there is no `emu/src/`)
- Altirra — `/Users/simon/src/AltirraSDL/src/ATAudio/source/pokey.cpp`
- tests — `docs/Acid800/src/<test>.s`, which **embed their own cycle tables**

### Altirra's timer model (source-backed, do not re-derive)

- **STIMER defers its reload by 3 cycles** — `:2811`,
  `mpScheduler->SetEvent(3, this, kATPokeyEventResetTimers, ...)`. It does *not*
  reload on the write. Ours applies immediately.
- **"Borrow takes place three cycles after underflow"** — `ticks += 3` at `:2056`.
  General to every timer, not pair-specific.
- Unlinked fast period `AUDF+1`, `+3` when fast (`:1808-1812`).
- Linked **high** period `(AUDF_hi<<8) + AUDF_lo+1`, `+6` fast = `AUDF16+7`
  (`:1799-1802`) — confirms `a295560` independently of emu.
- Linked timer-2 borrow (`:2124-2147`):
  `ticks = mCounter[0]; ticks += 3; ticks += (mCounter[1]-1)<<8; ticks += 3;`
  — **two separate +3s**. Timer 1 linked = `mCounter[0]+3`. With
  `AUDF1=$0D, AUDF2=0`: T1 at 17, T2 at 20.
- Reloads: low → **253** (fast) on its *own* borrow (repeat 256, `:1638-1646`);
  low → **AUDF1+1** when the *high* borrows with it (`Timer2Borrow`, `:1665`);
  high → `AUDF2+1`.
- `mTimerFullPeriod=256` (`:1816-1828`) is the **deferred/passive** path only,
  and deferring is forbidden while a timer's IRQ is on (`:1842+`) — it does not
  apply to these tests. I misread this once and it cost an attempt.
- Init mode touches only the **serial subsystem** and the poly phase
  (`:2987-3023`) — it does **not** reset `mCounter[]` or the borrow events.
- The init-release phase is set **once, on the init→normal edge**, guarded by
  `initChanged` (`:2949-2977`): next 15 kHz tick at **+81**, next 64 kHz at
  **+22**. Our RTL cites these correctly — **the constant is not the bug.**
  emu's "26 / 112" is a different anchor (`BASE_LEAD`), not a contradiction.

## The six remaining failures

1. **`pokey_timertiming` `:583`** — the linked pair's high half.
   `audctl=$50, audf1=$0D, audf2=$00`, STIMER, `sty audf2` (=1) at +22,
   read at +299 must be **set**. emu: first period 20, write at age 2 re-seeds to
   `per-age` with `per=(1<<8|13)+7=276`, bit at `4+20+276=300`.
   **Parked pending measurement — see "next step".**
2. **`pokey_sertiming`** — "Serial output register was loaded too early." Rides
   the serial edge; unchanged by all of tonight's work.
3. **`pokey_inittiming` `:116`** — `'15KHz IRQ fired too early after exiting
   init mode.'` Base-clocked (15 kHz), where emu is explicit that neither
   `IRQST_LAG` nor `IRQ_LINE_LAG` applies. **Unresolved contradiction:** the test
   allows ~96 cycles, and both Altirra's 81 and our 83 fall inside it, so on my
   reading Altirra would fire early too — and it passes. **There is a gate I have
   not found. Do not tune `REL_SKEW` to hide it.**
   Our RTL (`hdl/pokey_audio.sv:141-175`) differs from Altirra two ways: it
   presets `ref_div_lo_q <= REF_REL_LO-1+REL_SKEW` = 82 (`REL_SKEW=2` comes from
   `pokey.sv`, not pokey_audio's own default of 5), and it **reasserts that preset
   continuously** while `poly_init_w`, where Altirra sets it once on the edge.
4. **`mmu_xlbanking`** — needs ROM + PORTB banking. `a8_core.sv` has **no ROM
   decode at all**. ROMs exist: `rsrc/atari-xl.rom` (16K), `rsrc/atari-basic.rom`
   (8K). `mmu_xlbanking.s:39-58` drives `portb` = `$c2`/`$f3`/`$f0`/`$72`
   expecting `$0f`/`$03`/`$0d`/`$0f` — kernel, BASIC **and** self-test.
   `pia_regs.sv:43-48` already exposes `portb_out_q`. Worth exactly **one** test.
   Risk: ROM at `$A000`/`$C000` changes what every test sees — sweep early.
5/6. **`antic_wsync`** and **`antic_dlitiming`** — both on the shared CPU
   IRQ/NMI latency lever (`xt6502f.sv:120-123`), also relied on by
   `pokey_irqtiming` and `antic_blockednmi`. One-test upside on a shared lever.

## Failed configurations — do not repeat

Eleven RTL attempts in the pair/STIMER area, all reverted.
`irqtiming` / `serclock` / `twotone` / `timerirq` stayed green throughout.

| attempt | result |
|---|---|
| pair one-shot ADD=5 | `:302` |
| ADD=6 | `:302` |
| arm@`stimer_apply` ADD=5 | `:314` |
| ADD=8 | `:449` |
| (on corrected counter) ADD=5 | `:327` |
| ADD=5 **+ `PAIR_LATCH_LAG` rewrite routing** | still `:327` — **the routing is not the missing feed; real elimination** |
| `STIMER_PAIR_RAW` (`{ch2_cnt,ch1_cnt} <= audf16-1`) | `:302` |
| lo rearm = 256 | `:290` |
| lo two-reload (256 own / AUDF1+4 on pair borrow) | `:277` |
| partial STIMER defer (ch1 only) | `:264` |

The saved patch `oneshot_p0.patch` lived in the session scratchpad and is gone on
restart; it is reconstructible from the table above and emu `:1040-1085`.

## Next step, concretely

**Extend `+STPROBE` in `sim/tb_acid.sv` to print IRQST bit 1** — the existing
bit-0 print is at `tb_acid.sv:520-540` (`st_irq_q`, rising edge, `+N` from the
STIMER write). Add the same for `dut.u_pokey.u_regs.irq_latch_q[1]`, gate on
`audctl == 8'h50` to catch the 16-bit section, then measure the actual arrival
against emu's stated 23 for the `AUDF16=16` case. **Do not start a twelfth
substitution before this exists.** When I did exactly this for bit 0 it ended
three turns of bisection in a single run.

If the pair stalls again, `mmu_xlbanking` is untouched and independent.

## Instruments — use these, don't rebuild them

- `+PROBE=1` — PC trail into `_testFailed` plus the `d0..d7` dump. `_ASSERT` does
  `sta d1` before `jsr _testFailed`, so **`d1` is the actual accumulator**. That
  one byte beat five turns of probing.
- The `said:` string is reconstructed from the **return address on the stack**
  (`tb_acid.sv:1245-1265`) — it is control-flow-derived and reliable. Always
  `grep -n` it in the `.s`: **the line number is the distance measure.**
- `.lst` files at `rsrc/acid800/Acid800/standalone/<test>.lst` map PC → source
  line **and show the macro bodies** (`_ASSERTA` = `cmp/beq pass/sta d1/jsr`).
- `+STPROBE=<n>` — STIMER cycle, T1 underflow delta, IRQST-bit-0-readable delta,
  every IRQST read. **Its `din` is the address-cycle value, one cycle ahead of
  what the CPU latches** — never tune RTL to make it print a nice number.

## Harness facts that cost real time

- `make acid2v TEST=<t> PLUSARGS="..."` must run from `sim/` (~5s; regenerates
  `acid.mem`).
- Sweep: `cp sim/build/vobj2/tb_acid2v $S/<bin>` from the repo root, then
  `nohup bash $S/sweep_vl.sh $S/<bin> <TAG> >/dev/null 2>&1 &`, then **read
  `$S/sweep_<TAG>.txt`** — the script writes results there and only the header to
  stderr, so a redirect always looks like "header only". 64 lines +
  `SWEEP COMPLETE` when done, 2–6 min. Header-only **with** processes = slow;
  **without** = dead. I lost two turns to this.
- The shell CWD both persists from the previous call and gets reset — use
  absolute `cd /Users/simon/src/fpga-xt &&` for every edit.
- After a failed edit script, `git status` before believing the next measurement:
  an aborted `assert` leaves the file untouched and the run is a phantom baseline.
- Publish: `python3 docs/a800/from-sim.py <sweep> --core antic2 --note "..."`,
  then `git add docs/a800/runs/*.json` and commit that with `index.html`.

## Method lessons worth carrying

- **Read both oracles and the test `.s`.** Altirra states in one line what took
  paragraphs to infer from emu.
- **Port the structure, not the number** — and **port a decomposition
  atomically**. `stimer_apply` feeds three counters (`ch1_cnt`, `lo_cnt`, the
  paired 16-bit load); converting one of them guarantees a regression.
- **The same total by a different decomposition is a trap.** Ours
  `AUDF+4 + IRQST_LAG(4)` and Altirra's `3 + (AUDF+1) + 3` agree until a test
  measures one term alone — and `timertiming` measures the underflow and the
  status bit separately.
- **A value correct for one register setting is coincidence if the test later
  changes that register.** `AUDF1+7` worked only because `AUDF2=0` made the high
  half borrow on every low tick.
- **Two oracles disagreeing on a number usually means two conventions**, not a
  bug — find where each anchors its zero before "fixing" either.
- **When a reference would fail the test on your reading, your reading is
  incomplete.** Find the gate; don't tune a constant.
- **A null result from a correct mechanism names the branch that is really
  deciding** — emu predicted one of tonight's null results in advance.
- **Re-run every known-failing test periodically.** `inittiming` moved
  `:79 → :116` unnoticed and I was planning against a dead diagnosis.
- **After three substitutions that all regress, the model is wrong, not the
  constant** — go and measure the event's absolute cycle.
- Returning to baseline is **neutral, not a win**. Say so plainly.

## One decision for Simon

Three `mod_*` tests are scored `error` and counted in the 58, but **none of the
five `mod_*` files contains a single `_ASSERT` or `_testPassed`** — they are demos
with no verdict. Two of them (`mod_options`, `mod_vbxe80`) hang waiting on a
keypress via `CH` (`$02FC`), which our harness can never deliver; on real hardware
they would wait forever too. `mod_scroll40`'s hang at pc `$5422` is undiagnosed
and has no `waitkey`.

`from-sim.py` already maps `RAN → na` ("ended without asserting anything — no
verdict") and two other demos are excluded that way. Whether these three should
also be `na`, or whether the harness should poke a key into `CH`, is a scoring
decision — **your call, not mine.** Reclassifying them would lift the number by
three without improving the design, so I left them alone.
