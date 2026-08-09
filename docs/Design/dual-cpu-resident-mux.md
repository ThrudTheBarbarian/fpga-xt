# Dual-CPU, resident + bus-mux — the turbo↔fidelity swap without DFX

The turbo `xt6502` (100 MHz, ~56×) and a future cycle-exact fidelity 6502 both live
in the fabric **at the same time**, sharing one `sally_mem`. A quasi-static select
bit hands the memory bus (and the emulated-cycle clock-enable) from one to the other;
the idle core is frozen. This is NextSteps §6502 **option (A)** written up as a build,
and — on the LUT-rich 7020 — it is the pragmatic first cut, with the DFX partial-
reconfig flow ([[partial-reconfig]] / docs/Design/partial-reconfig.md) as the
fMax-purist fallback rather than the default.

Why (A) over (B) PR here: PR buys *one* thing — not paying for the idle core's area —
at the cost of the whole Vivado DFX flow (exclusive RP pblock, per-core RM builds,
PCAP decoupler, post-load reset) plus a hard partition-pin fence through the binding
`clk_sally` loop. On a 7020 that is **LUT-rich but timing-thin**, a second 6502 is a
rounding error in area (~1.9k LUT / **0 binding BRAM** — a fidelity core is logic, not
memory; the 22 BRAM are all in the *shared* `sally_mem`, counted once), while the DFX
fence costs flow complexity *and* margin. So (A) trades area we have for flow-risk we
don't want. The only thing (A) costs that (B) doesn't is **one 2:1 LUT on the binding
path** — see §5, and it is self-gated by our WNS-≥0 build abort.

## 0. What already exists (this is mostly wiring, not new machinery)

Three pieces the current design already ships do the heavy lifting:

- **The cycle-enable is `sally_clock`.** It already turns `clk_sally` into a
  per-emulated-cycle `sally_rdy` clock-enable at any rate (`CLOCK_MULT`/`BASE_DIV`,
  divisors of 56), with the cycle-exact `/HALT` DMA-steal + WSYNC chain at
  `CLOCK_MULT=1`. **We do NOT build a 1.79 MHz clock domain** — no CDC. The fidelity
  core runs on `clk_sally` (100 MHz) gated by a second `sally_clock` at
  `CLOCK_MULT=1`: ~56 fabric clocks per emulated cycle = eons of multicycle budget for
  per-cycle bus phases, RMW double-writes, exact page-cross penalties, decimal mode,
  interrupt-timing quirks — all in one clock domain. See `hdl/sally_clock.sv`.
- **The handoff is the debug snapshot/inject ports.** `xt6502_debug` already halts a
  core at an instruction boundary (`dbg_boundary` = `ST_DECODE`), reads back
  `{PC,A,X,Y,S,P}`, and *injects* architectural state via `dbg_wr` +
  `dbg_wpc/dbg_waxys/dbg_wpsh` (built and HW-proven — [[xl_coldstart_nmi_derail]]).
  Core-to-core state transfer is snapshot-A → inject-B through exactly those ports.
- **The register file is already shared.** ANTIC/GTIA/POKEY/PIA hang off `sally_mem`'s
  `hwreg_*` port *downstream* of the CPU bus — see `hdl/sally_mem.sv` (`hwreg_addr/we/
  din/dout`). Both cores reach them through the same `sally_mem`, so I/O is **never
  duplicated** and needs no mux. Same for the DDR/AXI-HP path, banking regs, math page.

## 0a. The real prize — specialization: the gloves come off SuperSally

The deeper win isn't just "swap cores without DFX" — it's that **two cores get to
specialize**, and neither has to be a compromise:

- **Turbo `xt6502` → pure speed, accuracy baggage dropped.** Today the single core
  tries to be *both* fast *and* faithful: it carries the `/HALT` DMA-steal model, the
  cycle-accurate bus, the NMOS illegal opcodes ([[pop_illegal_opcodes]]), decimal-mode
  nuance — all of which cost decode LUTs on the binding `clk_sally` loop that gates
  fmax. Once the fidelity core exists, **the turbo core no longer has to be accurate at
  all**. It can shed illegal-opcode decode, cycle-exact timing, and RMW bus nuance,
  keeping only the documented ISA + the xtc embellishments (banking/math). Fewer decode
  levels on the binding path = a real shot at reclaiming the fmax the 120 target lost
  ([[xt6502_clean_sheet]] — the chase is paused; this *unblocks* it) and at un-parking
  the ~150 ps opcode-relocation work ([[xt_embellishment_opcode_relocation]]). Any app
  that actually needs an illegal opcode or tight raster timing isn't *for* turbo anyway
  — it runs on the fidelity core, which is where it belongs.
- **Fidelity core → pure accuracy, no fmax pressure.** At 1× it has ~56 fabric clocks
  per emulated cycle, so it can be a literal microcoded machine — every illegal opcode,
  exact cycle counts, decimal mode, interrupt-timing quirks, `/HALT` bus-steal — with a
  giant multicycle budget and *trivial* timing closure. It never chases fmax; it chases
  Altirra-equivalence.

This is why (A) beats (B) on more than flow-simplicity: **PR gives the same
specialization, but so does the mux — and the mux gets there without the RP fence.**
Splitting the concerns is the point; the delivery mechanism should be the cheap one.
It also flips a long-standing tension: the [[architecture_review_tock]] fmax work and
the Altirra-fidelity audit stop fighting over one core.

## 1. The bus contract being muxed (the entire CPU↔memory interface)

From `hdl/sally_mem.sv` — ten signals, stable per emulated cycle:

```
clk_sally, rst_sally,
addr[15:0], data_in[7:0], rw,     // core → sally_mem
data_out[7:0], busy,              // sally_mem → core
rdy,                              // clock-enable (from sally_clock)
stack_op, s_high[3:0]             // hidden-stack hints
```

`addr/data_in/rw/stack_op/s_high` are 2:1-muxed by the select bit; `data_out/busy`
fan out to **both** cores (fanout only — no added logic on the read path); `rdy` is
gated per-core so only the active one advances.

## 2. RTL sketch — bus mux

```systemverilog
// cpu_sel_acc: quasi-static select from the handoff FSM (§4).
//   0 = turbo xt6502 owns the bus, 1 = fidelity core owns it.
// Changes at most once per core-switch (held for millions of cycles).

// ---- core → sally_mem : 2:1 mux ------------------------------------------
assign mem_addr    = cpu_sel_acc ? acc_addr    : turbo_addr;    // <-- the one binding-path LUT (§5)
assign mem_data_in = cpu_sel_acc ? acc_data_o  : turbo_data_o;
assign mem_rw      = cpu_sel_acc ? acc_rw      : turbo_rw;
assign mem_stackop = cpu_sel_acc ? acc_stackop : turbo_stackop;
assign mem_shigh   = cpu_sel_acc ? acc_shigh   : turbo_shigh;

// ---- sally_mem → cores : fanout (no logic) -------------------------------
//   both cores see data_out/busy; only the enabled one's rdy is live, so the
//   frozen core simply never latches. Costs load, not a level.
assign turbo_data_i = mem_data_out;
assign acc_data_i   = mem_data_out;
```

## 3. RTL sketch — per-core cycle-enable (freeze the idle core)

Two `sally_clock` instances (or one, muxed): the turbo core keeps the runtime
`CLOCK_MULT` (`speed` command, $D4CA); the fidelity core is pinned to `CLOCK_MULT=1`
so it gets the full `/HALT` + WSYNC cycle-exact chain. The select ANDs into each
core's `rdy` so the deselected core is frozen and drives no bus transitions:

```systemverilog
// Turbo core: runs only when selected, honouring the debugger halt.
assign turbo_rdy = sally_rdy_turbo & ~cpu_sel_acc & dbg_core_run;

// Fidelity core: runs only when selected, always at 1× lockstep.
assign acc_rdy   = sally_rdy_acc   &  cpu_sel_acc & dbg_core_run;

//   sally_rdy_turbo <- u_sally_clock      (CLOCK_MULT = clock_mult_sally)
//   sally_rdy_acc   <- u_sally_clock_fid  (CLOCK_MULT = 1, halt_n live)
```

A frozen core (`rdy=0`) holds all state — its registered MAR and outputs are stable
garbage that the mux ignores. No reset needed between switches; the core resumes
exactly where the inject left it.

## 4. RTL sketch — handoff FSM (reuses the debug snapshot/inject ports)

Runs on `clk_sally`. `switch_req` is a level from a GP0/CTRL bit (PS-owned —
[[feedback_ps_does_config]]); target core = `~cpu_sel_acc`. Quiesce the active core
at its next instruction boundary, snapshot `{PC,A,X,Y,S,P}`, inject into the target,
flip the select. The whole exchange is a handful of `clk_sally` cycles — invisible.

```systemverilog
localparam S_STEADY=0, S_QUIESCE=1, S_INJECT=2, S_RELEASE=3;
reg [1:0] hs;
reg [15:0] sav_pc;  reg [31:0] sav_axys;  reg [11:0] sav_psh;   // {S,P,Y,X,A}, {shigh,P,...}

always @(posedge clk_sally) begin
  if (rst_sally) begin hs<=S_STEADY; cpu_sel_acc<=1'b0; end
  else case (hs)
    S_STEADY:  if (switch_req_edge) hs <= S_QUIESCE;            // halt-req to ACTIVE core via dbg
    S_QUIESCE: if (active_boundary) begin                       // ST_DECODE of active core
                 sav_pc   <= active_pc;                         // snapshot (debug read ports)
                 sav_axys <= active_axys;
                 sav_psh  <= active_psh;
                 hs <= S_INJECT;
               end
    S_INJECT:  begin                                            // drive TARGET core's inject ports
                 tgt_wr   <= 1'b1;                              // dbg_wr on the target
                 tgt_wpc  <= sav_pc;
                 tgt_waxys<= sav_axys;
                 tgt_wpsh <= sav_psh;
                 hs <= S_RELEASE;
               end
    S_RELEASE: begin
                 tgt_wr      <= 1'b0;
                 cpu_sel_acc <= ~cpu_sel_acc;                   // flip ownership; old core freezes
                 hs <= S_STEADY;
               end
  endcase
end
```

`active_boundary/active_pc/...` and `tgt_wr/tgt_wpc/...` are the two cores' debug
ports, cross-selected by `cpu_sel_acc`. Because inject already re-anchors the core
(`state<=ST_FETCH`, `MAR<=wpc`), the target resumes mid-program with full architectural
state — the same mechanism that HW-proved the coldstart PC-injection.

State that is *memory* (zero page, stack, all of RAM/ROM, I/O regs) is in the shared
`sally_mem` and needs no transfer — both cores were always looking at the same 64K.
Only the 6-register CPU context moves.

## 5. The one real cost — and why it self-gates

The `mem_addr` mux (§2) sits on the `clk_sally` **binding** loop (`…→ sally_mem BRAM
address`). It is a single 2:1 (3-input → 1× LUT6), ~0.3 ns of logic + routing. The
binding family runs at 100 MHz (10 ns) with measured WNS **+0.166…+0.309** (arch-
review §1.5). So the mux *probably* closes, but it is genuinely on the tight family —
this is the whole ballgame for (A), and it is decided empirically:

- **Our build aborts on negative WNS** ([[architecture_review_tock]]). So (A) cannot
  silently ship a broken clock: the mux either closes or the build fails and tells us.
- **If it doesn't close, mitigations before falling back to PR:**
  1. *Retime the mux into the shared MAR flop* — mux the two cores' MAR **D**-inputs
     and feed `sally_mem` from the shared **Q**, so the LUT lands on the address-*update*
     path (which has slack) instead of the BRAM-read path.
  2. *Asymmetric legs* — keep `turbo_addr` on the mux's fast LUT input; the fidelity
     leg has eons of slack so it tolerates an extra registered stage.
  3. *Only then* fall back to (B) DFX, which removes the mux at the price of the
     partition-pin fence (docs/Design/partial-reconfig.md §2).

Net: area is free (LUT-rich), CDC is avoided (single clk_sally + cycle-enable), state
handoff is already built (debug ports), I/O is already shared (`hwreg_*`). The lone
risk is one LUT-level on the binding path, and the WNS gate makes that risk
self-announcing rather than latent.

## 6. Policy — how the switch is exposed

The select is a CTRL/GP0 bit; **PS decides** ([[feedback_ps_does_config]]). Natural
policy: turbo for GEM/native + fast-loading Atari software; auto-drop to the fidelity
core for titles that trip on turbo (tight raster/DLI timing, illegal-opcode timing).
This composes with the existing `speed` command ([[output_resolution_decision]] speed
grades) — `speed 1` can select the fidelity core (true 1×) while `speed ≥2` selects
turbo. Per-app, decided in software, no rebuild.

## 7. Verification plan

1. **Both cores pass Klaus + `make boot`** standalone (fidelity core to the same bar
   as turbo — [[klaus_conformance]], [[os_boot_validation]]).
2. **Bus-mux sim** — `tb` toggling `cpu_sel_acc` mid-stream; assert the deselected
   core issues no bus transitions and memory contents are identical across the switch.
3. **Handoff sim** — run turbo N instrs, switch, confirm the fidelity core continues
   from the exact `{PC,A,X,Y,S,P}` (golden trace compare); switch back; round-trip.
4. **Timing gate** — build with the mux; **require `clk_sally` WNS ≥ 0** (§5). If
   negative, apply §5 mitigations before merge.
5. **HW** — cold-load, `speed 1`/`speed 28` toggling live under a running program;
   the debugger (`/bin/6502 status`) reads coherent state from whichever core is live.

## 8. Cross-references

- **Alternative:** docs/Design/partial-reconfig.md — the DFX/PR flow (option B). This
  doc is option (A); PR is the fallback if §5 doesn't close, not the default.
- NextSteps §6502 (options A/B/C) — this formalizes (A) and flips the recommendation
  toward it on LUT-richness grounds.
- architecture-review §1.4 — the RP fence discussion; (A) needs **no** fence.
- The fidelity core itself is the real work (illegal-opcode + cycle-exact bus model —
  [[pop_illegal_opcodes]]); identical effort under (A) or (B). This doc is only about
  the delivery mechanism, where (A) wins on the 7020.
