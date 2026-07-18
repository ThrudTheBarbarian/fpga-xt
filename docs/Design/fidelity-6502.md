# The fidelity 6502 — a time-native, fully-observable cycle-exact core

*(the "single-speed Sally"; companion to [[dual-cpu-resident-mux]] and [[6502-debug]])*

## 0. Thesis

At 1× the fabric runs **~56 `clk_sally` cycles per emulated 6502 machine cycle**
(100 MHz ÷ 1.7898 MHz NTSC phi2 = 55.87). That is not "slack we tolerate" — it is
**the design substrate**. This core is architected *around* those 56 clocks: the real
6502 does a handful of things per machine cycle, so we spread that handful thin across
the window, register between steps, and spend the remaining clocks on **observability
and exactness**. Every path is multicycle → timing closes trivially → the entire debug
facility and every accuracy quirk are **free**, live in `main`, in silicon, always on.

This is deliberately **not** `xt6502` with a slow clock-enable. `xt6502` *compresses*
work per fabric-clock to win fmax (registered MAR, prefetch, flattened states, in-clock
memory round-trip, xtc embellishments in the datapath). Those are the right choices for
a turbo core and the wrong shape for accuracy + observability — its bus phases and
micro-state are squeezed out exactly where a fidelity core needs them exposed. So
`xt6502` stays as-is (the turbo core, and a differential co-sim reference); the fidelity
core is a fresh, time-native design.

Goal: **as compliant to NMOS 6502 silicon as is worthwhile**, and **completely
observable** — the machine the bugs actually run on is the machine we debug on, in the
clock domain where timing bugs actually live.

## 1. The two cores, resident (delivery)

Both cores live in the fabric at once behind a 2:1 bus mux, per [[dual-cpu-resident-mux]].
Turbo = `xt6502`; fidelity = this core. A quasi-static select owns `sally_mem`; the idle
core is frozen (its cycle engine holds). State hand-off at an instruction boundary uses
the debug snapshot/inject slots (§6). The fidelity core's **native** bus/debug/handoff
contract is defined here so the integration is right once, not retrofitted.

Crucially, the fidelity core is **fully clocked** on `clk_sally` — it does NOT idle on a
clock-enable. Every `clk_sally` edge advances one micro-step; it paces itself to 1× by
consuming exactly one machine-cycle window (§2) per `phi2_tick`. The "spare" clocks are
spent, not skipped.

## 2. The machine-cycle window and the micro-schedule

The 6502 does **exactly one bus access per machine cycle** (a read or a write, always —
even "internal" cycles drive the bus). An instruction is 2–7 such cycles (8 for a few
illegals; 7 for reset/IRQ/NMI). So the atom is the **machine cycle**, and the window is
its ~56 `clk_sally` clocks. A `sub` counter (0..N-1, reset on `phi2_tick` from
`sally_clock`) is the micro-step index.

**Two timing authorities, cleanly split:**

- **The core follows the MOS 6502 datasheet** — `refs/mos_6501-6505_mpu_preliminary_aug_1975.pdf`
  (the AC-characteristics table + the Read/Write timing figures). The chip's own pin
  timing governs the cycle: address set up during **phi1**; R/W and write data driven
  during **phi2**; **read data latched on the phi2 falling edge** (cycle end).
  1 MHz figures (typ / max): TADS address setup **200 / 300 ns**, TRWS R/W setup
  **100 / 300 ns**, TMDS write-data delay **150 / 200 ns**, TDSU read-data setup
  **100 ns min** before Φ2 fall, TH hold **10 ns min**, TACC memory access **575 ns max**;
  Φ1 high ≥430 ns, Φ2 high ≥470 ns, **non-overlapping**. Scaled to the 559 ns cycle the
  *typical* address-valid is ~112 ns — so the XL gif (177 ns) is near **worst-case**, and
  since our address is register-driven (no analog propagation) we may drive it EARLIER
  still: the datasheet ns are a **ceiling on lateness**, not a delay to reproduce.
- **The XL gif governs the PBI/expansion boundary.** `refs/XL-bus-timing.gif` (ANTIC
  magazine, an Atari engineer on the parallel bus), *Fig 2, CPU↔External Device Timing*,
  is that same cycle seen **downstream** — after ANTIC's clock gen and the XL's bus
  buffers, at the PBI connector: cycle **558 ns** (≈ 56 × 10 ns), **address valid
  @177 ns**, **EXTENB @195 ns**, **MPD @225 ns**, **write data valid @422 ns**, **read
  sampled @486 ns**. These are the numbers our PBI/expansion emulation must *present* at
  EXTENB/MPD — buffer-shifted from the internal CPU pins, so they anchor the external
  boundary, not the core's internal bus.

What is invariant across both — and what functional cycle-accuracy actually rides on —
is the **structure**: one access per cycle, address in phi1 then data in phi2, read
latched at phi2 fall, the RMW double-write, and the *ordering* of EXTENB/MPD within the
cycle. The absolute ns only pin the sub-cycle external-device interface. At ~10 ns per
`sub`, the (connector-view) reference lands as:

```
 sub    ns       phase / event        work                                   (N≈56)
 ----   -----    ------------------    -----------------------------------------------
 0      0        cycle start, O2 low   arbitrate /HALT (ANTIC DMA steal) + WSYNC;
                 (phi1)                DEBUG *early* sample (regs at cycle entry; the
                                       PREVIOUS cycle's read data has just latched)
 0-18   0-177    drive address         compute + drive the address (PC, ptr, stack, EA,
                                       vector...); VALID BY 177 ns (sub ~18)
 ~20    195      EXTENB                 external-device address-decode window opens
 ~23    225      MPD                    ext device may disable the internal ROM here
 ~28    ~280     O2 rises (phi2)        data phase begins
 5-41   -        internal               decode / ALU / flags / EA fix-up, PIPELINED thin
                                       (shallow logic/step -> trivial fmax; every
                                       intermediate a named, observable reg). Overlaps
                                       the address drive but must not gate valid@177
 ~42    422      WRITE data valid       write cycle: drive data_out + rw=0
 ~49    486      READ data sampled      read cycle: latch data_in
 49-55  486-558  commit / retire        write back A/X/Y/S/P/PC; advance the sequencer;
                                       DEBUG *late* sample (settled); interrupt
                                       recognition at the exact NMOS point; trace write;
                                       breakpoint / watchpoint compare (S6)
 56     558      O2 falls, cycle end    next phi2_tick
```

The two debug windows fall out of the silicon: **early** = cycle entry (before the new
address, sub 0–2), **late** = 486–558 ns where read data and the arch state are settled.
RMW does its 3 accesses across 3 whole cycles (§4), not within one. If a memory access
needs longer than its slot (a cache/DDR miss on a banked access) the data phase
*stretches* and the window extends past 558 ns — 1× real-time holds for the plain 64 KB
BRAM path (1–2 clock accesses, the only path a pure 6502 uses); banked/xtc accesses are
turbo-only concerns. **EXTENB/MPD are exposed as first-class sub-cycle strobes** so a
cycle-accurate PBI / expansion device ([[pbi-bridge-design]]) can decode and override
internal ROM at exactly the silicon-correct instants.

## 3. Microarchitecture

Two nested engines:

- **Cycle engine** — owns `sub`, the phi1/phi2 slotting, the bus handshake to
  `sally_mem`, and the /HALT gate. One iteration = one 6502 machine cycle.
- **Instruction sequencer** — a table-driven micro-sequencer. Decode the opcode into
  `{addressing-mode sequence, operation}`. The 6502 has ~13 addressing modes, each a
  fixed *cadence* of machine cycles (which address each cycle drives, read vs write,
  where the dummy reads fall); the operation (ALU/load/store/branch/stack/flag) is
  applied at the mode's defined cycle. This is compact and exact — the whole
  cycle-by-cycle behavior of all 256 opcodes falls out of `mode × op`, including the
  quirks in §5, rather than a per-opcode state explosion.

The micro-PC / `{opcode, cycle-in-instruction, sub}` tuple is itself part of the debug
state — the machine is transparent by construction.

Datapath is deliberately **pipelined across sub-steps** (register between decode → ALU →
flags → commit) so no single `clk_sally` edge sees deep logic. This is the inversion of
`xt6502`: there we minimize levels to raise fmax; here we *add* register stages to lower
per-step depth, because we have the clocks and want the observability + closure.

## 4. Bus-phase model (the fidelity that matters)

Per machine cycle: drive address (phi1), then one read or write (phi2). Committed
behaviors:

- **One access per cycle, always** — internal/"wasted" cycles still drive a (redundant)
  read, at the address the silicon would. These dummy reads hit hardware registers with
  side effects, so they are *correctness*, not cosmetics.
- **RMW double-write** — `INC/DEC/ASL/LSR/ROL/ROR` and the RMW illegals do, over three
  cycles: **read**, **write original value back**, **write modified value**. Two writes
  to the address. Visible on `$D0xx` strobe registers; a real fidelity requirement.
- **Indexed dummy reads** — indexed reads that cross a page read the *un-fixed* address
  first, then re-read fixed; indexed *writes* always do the dummy read. Branch taken/
  page-cross timing and their dummy reads modelled.
- **`JMP ($xxFF)` indirect bug** — the high byte of the vector is fetched from `$xx00`,
  not the next page.
- **Interrupt sampling + hijacking** — per the datasheet: IRQ/NMI are **sampled during
  Φ2** and the sequence begins on the **Φ1 after the current instruction completes**;
  NMI is negative-**edge** latched, IRQ is **level**. BRK/IRQ/NMI share the 7-cycle
  sequence, the vector can be hijacked by an NMI arriving mid-sequence, and the `B` flag
  distinguishes BRK/PHP (set) from IRQ/NMI (clear) in the pushed status.
- **RDY / /HALT (ANTIC DMA steal)** consumed per-cycle from the existing cycle-exact
  scheduler ([[sally-halt-not-modeled]]). Datasheet rule: RDY halts on **all cycles
  except writes** — the negative transition is recognized during Φ1 with the address
  lines holding the fetch address, and the CPU resumes on a Φ2 with RDY high. Raster/DLI
  effects need this exact, and it's the domain the fidelity core lives in.
- **SYNC** = high during Φ1 of an **opcode fetch** (datasheet): a free, exact
  instruction-boundary marker — surfaced to the debug facility (instruction-granular
  breaks/step) rather than re-derived.

## 5. Accuracy target (what we commit to)

**In:** all 256 opcodes; exact cycle counts + bus patterns; page-cross penalties + dummy
reads; RMW double-write; branch timing; `JMP ($xxFF)`; decimal-mode ADC/SBC result **and**
the NMOS N/V/Z-on-binary-intermediate flag quirk; interrupt timing/hijacking + CLI/SEI/
PLP interrupt-enable delay; the reset sequence; stable illegals (SLO RLA SRE RRA SAX LAX
DCP ISC ANC ALR ARR SBX + the NOP family). `KIL`/`JAM` opcodes halt the core — and the
debugger *observes* the halt (a diagnosable state, not a mystery lock-up).

**Documented convention (not analog-exact):** the unstable illegals (`ANE`/`XAA`,
`LXA`, `SHA`/`SHX`/`SHY`/`TAS`) depend on analog effects / a chip-specific "magic
constant" and RDY-corruption; we pick and **document** a convention (constant value; the
`AND (H+1)` behavior for the SH\* group) rather than chase analog. Flagged so a title
that relies on one is a known quantity, not a silent divergence.

**Out (for now):** analog video artifacts belong to GTIA/ANTIC, not the CPU; PAL timing
is a `BASE_DIV`/scheduler parameter, not a core change.

## 6. The debug slot contract (first-class, not bolted-on)

The debug facility is a **scheduled participant in the micro-sequence**, same clock
domain, reading settled state at defined slots. This *dissolves* the entire class of
pain we just fought on the turbo core (marginal PC-compare, CDC-synced arming,
incoherent run-state reads):

- **Two coherent sample windows per cycle** (your `2,3,4` / `53,54,55` idea): an
  *early* latch at phi1 (address + regs at cycle entry) and a *late* latch at retire
  (settled arch state + the bus access that just happened). No metastability — the
  state is stable at those `sub` values by construction.
- **Breakpoint / watchpoint compare in the retire slot**, off registered state, same
  domain — always fires, exactly, first time. No "sometimes breaks."
- **Trace** written in the retire slot: per-cycle or per-instruction, {PC, regs, bus
  addr/data/rw, cycle-in-instr, micro-PC} — cycle-level visibility, not just PC.
- **Inject slot** — load PC/regs at a defined `sub`, re-anchoring the sequencer at an
  instruction boundary; this is also the turbo↔fidelity hand-off mechanism.
- **Everything is free** (multicycle) → the facility is permanent (`main`, silicon), and
  richer than today's: single-cycle stepping, bus watch, cycle-in-instruction breaks,
  interrupt-boundary breaks, DMA-steal-aware trace.

The GP0 DEBUG block ([[6502-debug]]) and `/bin/6502` front-end carry straight over; new
capabilities (cycle step, micro-PC, bus trace) are additive registers.

## 7. Validation

- **Differential co-sim vs `xt6502`** on the documented ISA (both run the same program;
  compare architectural state at instruction boundaries) — catches decode/ALU divergence
  cheaply, reusing the turbo core as an oracle.
- **Altirra as the gold standard** for cycle-level bus + timing (Altirra's cycle traces
  are the reference the community trusts).
- **Test suites (ranked for a cycle-exact NMOS-with-decimal core):**
  1. **Tom Harte "ProcessorTests / 65x02"** — the cycle-exact spine. Per-opcode JSON
     (~10k cases/opcode): initial `{PC,S,A,X,Y,P,RAM}` → final state **+ a per-cycle
     `[addr,value,r/w]` list**; ground-truth from perfect6502/visual6502, covers **all
     256 opcodes incl. illegals + unstable**. A JSON→tb harness injects each case, runs
     the opcode, and diffs BOTH final regs AND our cycle-by-cycle bus trace — validates
     the sub-slotted phi1/phi2 model directly, not just end-state.
  2. **Klaus Dörmann** — functional ([[klaus-conformance]], already passing on xt6502),
     the decimal test (all ADC/SBC combos + NMOS N/V/Z quirk), and the interrupt test.
  3. **Lorenz (C64) suite** — breadth on illegals + timing + flags (C64 load-and-trap
     harness; more plumbing than Harte JSON).
  4. **Blargg** — cross-check only: `cpu_dummy_reads`/`cpu_dummy_writes` + illegal
     *results* are useful, but he targets the NES 2A03 (**decimal disabled**), so his BCD
     expectations do NOT apply and the harness is NES-specific. Superseded for us by (1).
  PoP's illegal-op needs ([[pop-illegal-opcodes]]) are a subset of (1)/(3).
- **On HW**, the debug facility validates itself: single-step + cycle trace + bus watch
  reproduce Altirra's per-cycle log for a captured sequence.

## 8. Implementation phasing

1. **Cycle engine + sequencer skeleton** ✅ — the window, `sub` slotting, /HALT (RDY) gate;
   `NOP`/`JMP` loops + reset run real-time 1× (`sim/tb_xt6502f`).
2. **Documented ISA** ✅ — every legal opcode across all addressing modes, cycle-exact.
3. **Quirks + illegals** ✅ — RMW double-write, dummy reads, page-cross, branch timing,
   NMOS decimal ADC/SBC flags, JMP($xxFF) wrap, and **all 256 opcodes incl. illegals**
   (stable exact; unstable = most-common result; KIL/JAM = lock-up). Validated cycle-exact
   against Tom Harte's tests via `sim/tb_xt6502f_harte` + `sim/harte/` (per-opcode `.vec`).
   **HW interrupts** ✅ — IRQ (level, I-gated), NMI (edge-latched), the 7-cycle push+vector
   sequence, B-clear on the pushed status, NMI-vector hijack of BRK/IRQ, RTI. Directed bench
   `sim/tb_xt6502f_irq` (Harte ties the lines inactive). *Remaining refinements: the exact
   Φ2 sample slot for the CLI/SEI/PLP one-instruction delay + RESET-as-interrupt sequencing.*
4. **Debug slots** ✅ (RTL + sim) — `hdl/xt6502f/xt6502f_debug.sv`: coherent early/late
   snapshots, break-before-execute PC bkpt + data wp (halt via the rdy-gate), single-step,
   per-cycle trace ring. Bench `sim/tb_xt6502f_dbg`. *Left: wire to the GP0 DEBUG block +
   `/bin/6502` cycle-level additions — lands with the SoC integration (Phase 5).*
5. **Resident mux + hand-off** — FSM ✅ (RTL + sim): `hdl/xt6502f/cpu_handoff.sv` +
   `sim/tb_cpu_handoff.sv` (bus-mux/freeze/snapshot→inject, seamless A↔B proven with two
   fidelity cores). *Left: `fpga_xt_top` integration (2:1 addr mux, 2nd `sally_clock`@MULT=1,
   `busy`→`rdy`, GP0 wiring) + a WNS ≥ 0 bitstream — the one mux LUT on the binding path.*
6. **HW bring-up + validation** — cold-load, run the OS/games on the fidelity core, chase
   the fidelity backlog (the magenta palette, garbled tiles, input) *on the right core*.

## 9. Decisions (settled 2026-07-18)

1. **Window size N** — **derive from the clk_sally operating point** (`N = CLK_SALLY_HZ /
   PHI2_HZ`), and derive every phase-constant symbolically from N. One knob: a 120 MHz+
   point just widens the window (more slack), no hand-tuning. *(Implemented in xt6502f.)*
2. **Unstable illegals** — model the **most-common documented result, fixed** (ANE/LXA/
   SHA/SHX/SHY/TAS). No per-run/analog variability — not worth the cleverness.
3. **Sequencer encoding** — **structured addressing-mode FSMs + a small op-ALU** (most
   readable/observable); revisit only if it sprawls.
4. **Handoff** — turbo↔fidelity switch **at instruction boundaries only**; a
   mid-instruction micro-PC is never handed over.
5. **Trace granularity** — **per-instruction** default (a per-cycle mode remains available
   given the budget).
6. **KIL/JAM** — **halt and surface to the debugger** (a diagnosable state), not a silent
   bus lock-up.
