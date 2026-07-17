# In-fabric 6502 debugger (halt / step / breakpoint / register access)

Status: **design**, on branch `debug` (off tag `pre-6502-debug`, the fast RTL
baseline). The debug hardware taps the xt6502 core's critical path (breakpoint
comparator on fetch, register-readback muxes, clock-enable gating) and is
expected to lower the core fmax — hence the branch. Recover the fast timing from
`pre-6502-debug` when the debugger is not wanted in a build.

## Why

Getting Atari 8-bit software byte-exact on the fabric (ACID800 and friends) is a
long haul of *run → observe divergence → patch → repeat*. Doing that by poking
memory and squinting at the screen (which is how we found the app-launch stall
sits in coldstart with a bad DLIST) is guesswork. A real debugger lets us step
the core through its paces and read exactly where it goes wrong.

## User interface — the `6502` command

A userland tool `/bin/6502` that pokes/peeks a GP0 DEBUG register block (same
mechanism as `/bin/mem`, `/bin/speed`, `/bin/scale`). Grammar:

```
6502 halt                 # freeze the core on the next instruction boundary (state preserved)
6502 go                   # release; run at the configured speed
6502 reset                # cold reset pulse (SALLYRST), then halted at the reset vector
6502 step [N]             # run exactly N instructions (default 1), then halt; prints status
6502 status               # dump PC A X Y SP P (flags decoded), halted?, retired-instr count
6502 break $DE34          # arm a PC breakpoint at $DE34 (halts on fetch of that address)
6502 break off            # disarm the breakpoint
6502 PC=$200 SP=$FF       # write registers (only while halted). REG in {PC,A,X,Y,SP,P}
6502 PC=$4000 SP=$FF go   # write registers, then run
```

Separators are flexible: `6502 PC=$200; SP=$FF` (semicolons) and
`6502 PC=$200 SP=$FF` (spaces) both parse. A trailing `go` on an assignment line
runs after the writes land. Values are hex (`$` or `0x` prefix optional).

`status` output (monitor style):

```
6502 HALTED  PC=$C2AA  A=$00 X=$FF Y=$00 SP=$FD  P=$34 [nv-BdIzc]  icnt=12
```

## GP0 DEBUG register block

New block in `hdl/regmap/xt_gp0.json` (generated → `xt_gp0_pkg.sv` /
`xt_gp0_map.h`; `make -C tools regmap`). Base `0x800` (MATH=0x600, TRNG=0x700).
All A9-only; the halt/step/regs live in the `clk_sys` (GP0) domain and cross to
`clk_sally` (core) — safe because a *halted* core presents static values.

| off  | name        | acc | meaning                                                                 |
|------|-------------|-----|-------------------------------------------------------------------------|
| 0x00 | DBG_CTRL    | RW  | [0]=halt_req  [1]=bkpt_en. Write-1-pulse: [8]=step [9]=reg_commit [10]=reset |
| 0x04 | DBG_STEP    | RW  | instruction count consumed by the next `step` pulse (default 1)          |
| 0x08 | DBG_BKPT    | RW  | [15:0]=breakpoint PC                                                     |
| 0x0C | DBG_STAT    | R   | [0]=halted [1]=bkpt_hit [2]=running                                      |
| 0x10 | DBG_PC      | R   | [15:0]=PC (coherent when halted)                                        |
| 0x14 | DBG_AXYS    | R   | [7:0]=A [15:8]=X [23:16]=Y [31:24]=SP                                    |
| 0x18 | DBG_P       | R   | [7:0]=P (status flags)                                                   |
| 0x1C | DBG_ICNT    | R   | retired-instruction count since reset                                   |
| 0x20 | DBG_WPC     | W   | PC to inject on reg_commit                                               |
| 0x24 | DBG_WAXYS   | W   | A/X/Y/SP to inject on reg_commit                                         |
| 0x28 | DBG_WP      | W   | P to inject on reg_commit                                                |

## Hardware architecture

The core recon (`hdl/xt6502/xt6502.sv`, one 1033-line file) makes this far less
invasive than feared. Two facts drive the whole design:

- **`rdy` is already a non-destructive freeze.** The core advances exactly one
  microstate per `clk`, gated entirely by the `.rdy` input (`xt6502.sv:851`,
  `if (rdy) begin … end`). Holding `rdy=0` freezes *every* flop — state, PC,
  A/X/Y/S/P — with nothing cleared (unlike `rst`, which zeros them). So **HALT =
  gate `rdy` low.** No new logic inside the core.
- **`state == ST_DECODE` (7'd4) is the once-per-instruction boundary.** The core
  PREFETCHES the next opcode during execution, so `ST_FETCH` is *skipped* except
  after control-flow changes — it is NOT once per instruction (a sim trace proved
  this: DECODE fired once per instruction, FETCH did not). At ST_DECODE the opcode
  has been consumed and PC already incremented past it, so the instruction address
  is `PC - 1` — the debug block subtracts one for the snapshot and the breakpoint
  compare. The core halts one microstate after the DECODE boundary (mid-instruction,
  not yet retired); `step` then runs to the next DECODE, executing exactly one
  instruction.

### Core taps (the only change to xt6502.sv)

Add pure **output** taps — combinational fan-out of existing regs, no added path
inside the core:

```
output [15:0] dbg_pc      // = PC
output [7:0]  dbg_a,dbg_x,dbg_y,dbg_s,dbg_p
output [3:0]  dbg_shigh   // 12-bit SP = {dbg_shigh, dbg_s}
output        dbg_boundary // = (state == ST_FETCH)
```

Phase 3 (register write) later adds `input` write ports + a commit strobe into
PC/A/X/Y/S/P — the only invasive change, deferred.

### The external debug block (`xt6502_debug.sv`, clk_sally)

Halt/step/breakpoint/readback all live *outside* the core, fed by the taps:

- **Halt / run**: `halt_req` (from GP0), a breakpoint hit, or step-exhausted
  latches `halted` on a `dbg_boundary` pulse (so it stops at ST_FETCH, not
  mid-instruction). `halted` becomes a new AND term into `sally_rdy`
  (`sally_clock.sv:150`, `sally_rdy = step & halt_effective & wsync_rdy_n &
  busy_n_q`) or is gated at the `.rdy` pin of `u_sally_core`
  (`fpga_xt_top.sv:741`). `go` clears it.
- **Single-step**: load `DBG_STEP`=N, pulse `step`; clear `halted`, decrement a
  counter on each `dbg_boundary`, re-latch `halted` at zero. N=1 = one
  instruction.
- **Breakpoint**: `bkpt_en` + `dbg_pc == DBG_BKPT`, qualified by `dbg_boundary`
  → set `bkpt_hit`, latch `halted`. The comparator is downstream of the `dbg_pc`
  tap and feeds the halt FF (PC→cmp→FF, then FF→rdy) — the one real fmax cost,
  and it is off the core's own critical path.
- **Register readback**: `dbg_pc/a/x/y/s/p` sample into GP0-readable regs. Only
  *meaningful* when halted, and a halted core is static, so there is no
  capture-while-moving CDC hazard — plain registers suffice. `DBG_ICNT` counts
  `dbg_boundary` pulses.

CDC: control (DBG_CTRL/STEP/BKPT) crosses clk_sys→clk_sally (2-FF for levels,
pulse-sync for the step/commit/reset strobes); status (`halted`, PC, regs, icnt)
crosses clk_sally→clk_sys — safe to sample directly because it is only read when
halted (static). `reset` reuses SALLYRST (`rst_sally_core` / `sallyrst_sync`,
`fpga_xt_top.sv:227-230`); HALT is the separate, non-destructive `rdy` gate that
lives right beside it.

**Timing upshot:** Phase 1 (halt via `rdy` gate + output taps + readback) adds
essentially nothing to the core's critical path — the fmax risk is concentrated
in Phase 2's breakpoint comparator and Phase 3's register-write ports. Phase 1
may even close at the current operating point; measure before assuming otherwise.

## Phasing

1. **MVP — enough to diagnose app-launch**: halt/go, single-step N, register
   readback (PC/A/X/Y/SP/P) + retired-instr count. Lets us step from the reset
   vector and watch exactly where coldstart diverges (the bad-DLIST stall).
2. **Breakpoint**: `break $addr` (PC-compare → halt). Run-to-a-point.
3. **Register write**: `PC=/SP=/…` injection — start the core anywhere with a
   chosen state and `go`, to test hypotheses directly.

The `/bin/6502` command is built incrementally alongside each phase.

## Timing

Adding this to the ~120 MHz core will cost fmax (breakpoint comparator on fetch,
readback muxes, clock-enable gating). That is the whole reason for the branch and
the `pre-6502-debug` tag. When a fast production build is needed, the debug block
compiles out (or the bitstream is built from `pre-6502-debug`); the `/bin/6502`,
`speed`, `scale`, `mem` PS tools are all clock-neutral and stay on main.
