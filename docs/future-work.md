# PCB details

- VQPS should be tied to GND directly, we're not blowing any fuses

## Power supplies

- 5V should be the standard PSU input
- 3.3v should be derived directly from the 5v supply
- 0.95v gated by RP2354, which is powered by 3.3v
- For 0.95v: TI TPS62810 (4A, $2.43), TI TPS62160 (1A, $1.18), or MPS MP2161 (2A, $1.14)


## 0.95v
⏺ ASCII sketch of the standard 3.3 V → 0.95 V buck with EN + PG for the Ti60 VCC + VCCA rail: 
                                      
     3.3V (always-on)                                                                         
          │                                                                                   
          ├──[10µF X7R]──┐                                                                    
          │              │                                                                    
          │   ┌──────────┴──┐                                                                 
          │   │             │                                                                 
          ├───┤ VIN     SW  ├──[L1 1µH]──┬───── 0.95V → Ti60 VCC + VCCA                       
          │   │  TPS62810   │            │                                                    
          │   │   QFN-9     │           ─┴─ 22µF ─┬─ 10µF ─┬─ 0.1µF             
          │   │             │            │       │        │                                   
     GPIO_EN ─┤ EN          │            └───┬───┴────────┘                     
     (peri-RP)│             │                │                                                
              │             │              [GND]                                              
     GPIO_PG ←┤ PG (OD)     │                                                                 
     (peri-RP)│        VOS/FB├──┬──[R_top 57.6k]──┘                                           
              │             │  │                                                              
          ┌───┤ MODE        │  └──[R_bot 100k]──┐                               
          │   │             │                   │                                             
         VIN  │ GND     PGND│                  GND                              
         (forced└──┬────┬──┘                                                                  
         PWM)    [GND][GND]                                                     
                                                                                              
     +PG pull-up: 10k from PG → 3.3V (open-drain output needs pull-up)                        
     +EN: 1.2V threshold, drive direct from peri-RP 3.3V GPIO                                 
                                                                                              
### Critical values

| Component | Value | Notes |
|-----------|-------|-------|
| L1 | 1 µH, ≥2 A saturation | Typical for this family at ~1-2 MHz switching; ferrite shielded (TDK MLP2520, Murata DFE252012) |
| Cin | 10 µF X7R 0805/0603 ceramic | Place ≤5 mm from VIN pin |
| Cout | 22 µF + 10 µF + 0.1 µF | All X7R ceramic, place close to SW/output |
| R_top | 57.6 kΩ 1% (E96) | Gives V_out = 0.6 × (1 + 57.6/100) = **0.946 V** (within Ti60 ±5%) |
| R_bot | 100 kΩ 1% | |
| R_PG_pullup | 10 kΩ to 3.3 V | Open-drain output needs external pull-up |

### Pin connections

| Pin | Connect to | Notes |
|-----|------------|-------|
| VIN | 3.3 V always-on | With Cin to GND |
| EN | peri-RP GPIO | 3.3 V logic OK; high = enable. Pull low at reset via the GPIO's POR state |
| MODE | tied to VIN (3.3 V) | **Forced PWM** — lower noise, important for FPGA core. (Tied to GND = auto-PFM/PWM; saves power at light load but worse ripple) |
| VOS / FB | midpoint of R_top / R_bot | Sense the 0.95 V rail through the divider |
| SW | L1 → output node | Short, fat trace; place inductor ≤5 mm from SW pin |
| PG | peri-RP GPIO (input) + 10 kΩ pull-up to 3.3 V | Open-drain; goes high when V_out is within regulation (typically ~92% of nominal). Use this for the firmware-sequenced "wait for rail" handshake |
| PGND / GND | board GND | Wide copper pour; one star connection to the output cap GNDs |
| Thermal pad | bottom GND under chip | Via array down to GND plane (8-12 vias for thermal) |


  Layout watch-points

  1. Switching loop tight: VIN → Cin → VIN-pin → SW → L1 → Cout → GND → back to Cin. Keep this
   loop small (high di/dt path).
  2. FB trace short: from output node through R_top to FB pin, keep away from SW node
  (capacitive coupling causes regulation noise).
  3. GND plane under the chip: thermal pad needs solid via array.
  4. PG trace can be long/thin: it's a slow open-drain signal, no high-speed concerns.

  Optional addition: soft-start

  The TPS62810 has internal soft-start (~1 ms). If Efinix's Ti60 datasheet requires a slower
  ramp (some FPGA cores spec 0.5-5 ms max rise time), you can add an external soft-start cap
  on the SS pin (if the part variant exposes one — check the specific TPS6281x datasheet,
  since variants differ). For most FPGA cores, the built-in 1 ms is fine.

  Sequence with the rest of the board

  - Always-on 3.3 V is up first (USB-C → 3.3 V buck on board)
  - Peri-RP boots from 3.3 V (~10-50 ms)
  - Peri-RP asserts GPIO_EN_0.95V → this circuit ramps up over ~1 ms
  - TPS62810 asserts PG → peri-RP firmware reads GPIO_PG_0.95V, knows rail is good
  - Peri-RP then asserts EN for the 1.8 V rail's regulator
  - After both rails up + small settle, peri-RP releases CRESET_N to FPGA

## 1.8v

Same TPS62810 IC as the 0.95 V rail — only the feedback divider differs.
Powers FPGA VCCAUX + VCCIO (HSIO), TMDS1204 VIO, PCAL9722 VDDI, and the
A-side of the LVC8T245 level translators.

```
   3.3V (always-on)
        │
        ├──[10µF X7R]──┐
        │              │
        │   ┌──────────┴──┐
        │   │             │
        ├───┤ VIN     SW  ├──[L1 1µH]──┬───── 1.8V → FPGA VCCAUX/VCCIO + TMDS1204 VIO
        │   │  TPS62810   │            │       + PCAL9722 VDDI + LVC8T245 A-side
        │   │   QFN-9     │           ─┴─ 22µF ─┬─ 10µF ─┬─ 0.1µF
        │   │             │            │       │        │
   GPIO_EN ─┤ EN          │            └───┬───┴────────┘
   (peri-RP)│             │                │
            │             │              [GND]
   GPIO_PG ←┤ PG (OD)     │
   (peri-RP)│        VOS/FB├──┬──[R_top 200k]──┘
            │             │  │
        ┌───┤ MODE        │  └──[R_bot 100k]──┐
        │   │             │                   │
       VIN  │ GND     PGND│                  GND
       (forced└──┬────┬──┘
       PWM)    [GND][GND]

   +PG pull-up: 10k from PG → 3.3V (open-drain output needs pull-up)
   +EN: 1.2V threshold, drive direct from peri-RP 3.3V GPIO
```

### Critical values

| Component | Value | Notes |
|-----------|-------|-------|
| L1 | 1 µH, ≥2 A saturation | Identical to 0.95 V rail; reuse the same part |
| Cin | 10 µF X7R 0805/0603 ceramic | Place ≤5 mm from VIN pin |
| Cout | 22 µF + 10 µF + 0.1 µF | All X7R ceramic, place close to SW/output |
| R_top | 200 kΩ 1% (E96) | Gives V_out = 0.6 × (1 + 200/100) = **1.800 V** (within Ti60 VCCAUX/VCCIO ±5%) |
| R_bot | 100 kΩ 1% | Same value as the 0.95 V rail — BOM unification |
| R_PG_pullup | 10 kΩ to 3.3 V | Open-drain output needs external pull-up |

### Pin connections

| Pin | Connect to | Notes |
|-----|------------|-------|
| VIN | 3.3 V always-on | With Cin to GND |
| EN | peri-RP GPIO (EN_1.8V) | 3.3 V logic OK; high = enable. Pulled low at reset via the GPIO's POR state; peri-RP asserts after EN_0.95V's rail comes up + PG asserts |
| MODE | tied to VIN (3.3 V) | Forced PWM — lower noise; matches the 0.95 V rail's setting for consistency |
| VOS / FB | midpoint of R_top / R_bot | Sense the 1.8 V rail through the divider |
| SW | L1 → output node | Short, fat trace; place inductor ≤5 mm from SW pin |
| PG | peri-RP GPIO (PG_1.8V input) + 10 kΩ pull-up to 3.3 V | Open-drain; goes high when V_out is within regulation. Use this for the firmware-sequenced "rail-ready" handshake before CRESET_N release |
| PGND / GND | board GND | Wide copper pour; one star connection to the output cap GNDs |
| Thermal pad | bottom GND under chip | Via array down to GND plane (8-12 vias for thermal) |

### Load budget

| Consumer | Estimated current | Notes |
|----------|------------------:|-------|
| FPGA VCCAUX | ~50 mA | Auxiliary supply |
| FPGA VCCIO (HSIO banks) | 100-250 mA | Dynamic; depends on IO toggle rate (rp_tx, HyperRAM, HDMI TMDS, 6502 bus all contribute) |
| TMDS1204 VIO | ~1 mA | Just for the control / DDC / HPD I/O pins |
| PCAL9722 VDDI | ~1 mA | GPIO-expander I/O side |
| LVC8T245 A-sides (×6-7) | ~10-20 mA | Quiescent + small dynamic per translator |
| **Total** | **~150-300 mA** | TPS62810's 4 A rating gives >10× headroom |


# Future work

Ideas that aren't in the current milestone scope but are worth recording so
they don't get lost. Anything here is a deliberate "later, not now" — not
a TODO that should be picked up speculatively.

## RS-232 serial port via the second POKEY

Once the second POKEY (M23-stereo, $D21x) lands, its serial port (SEROUT /
SERIN / SKCTL) is unused — the first POKEY's serial port handles SIO.

If we have our own OS, we could repurpose the second POKEY's serial port
as a **standard RS-232 connector** on the rear of the rp-XT board. RS-232
swings ±12 V, so we'd need an external level translator (MAX232-class or
equivalent) between the FPGA's 3.3 V/1.8 V output and the DB9 connector.

Details:
- POKEY's serial port can run at internal-clocked baud rates from
  ~600 baud up to 128 kilobaud (Altirra Manual §5.6).
- DB9 standard pinout: TXD (out), RXD (in), GND, plus optional handshake
  lines (RTS / CTS / DTR / DSR / DCD / RI). For minimum useful, just
  TXD / RXD / GND (3 wires).
- Level translator: MAX232 (charge-pump-based, generates ±10 V from a
  single 5 V supply) or modern equivalent (SP3232, ICL3232) at 3.3 V.
  Sits between the FPGA's 1.8 V → 3.3 V translator stage and the DB9
  pins.
- Pin budget: 2 FPGA pins (TX + RX) + 1 connector. No new HVIO required
  if it shares the SIO bank.
- Software: a custom serial driver in our OS uses the second POKEY's
  POTGO / SEROUT / SERIN / IRQEN bits exactly the same way the first
  POKEY's are used for SIO; the OS routes baud-rate generation through
  AUDF1+AUDF2 (or AUDF3+AUDF4) on the second POKEY.

Why not now: original Atari OS would not understand a second POKEY's
serial port, and routing this through the SIO subsystem requires kernel
changes. Park until "our own OS" milestone.

## COVOX-style DMA-fed sample playback

The classic [COVOX Speech Thing](https://en.wikipedia.org/wiki/Covox_Speech_Thing)
add-on lets a memory buffer be streamed to the audio output without CPU
intervention. The CPU fills a buffer with sample data, points the DMA
engine at it, and the audio plays back continuously — either looped or
play-to-end-then-stop.

Implementation sketch:
- A new `pokey_sample_dma` block (or just an extension of `pokey_audio`)
  with these registers, in some chiplet-extension address range:
  - SAMPLE_BASE (24-bit start address into HyperRAM)
  - SAMPLE_LEN  (24-bit length in bytes)
  - SAMPLE_RATE (16-bit divider, gives playback rate)
  - SAMPLE_CTL  (loop / play-once / stop / paused)
  - SAMPLE_STATUS (currently-playing pointer, end-of-stream flag)
- The block uses the existing HyperRAM shim's read port to fetch one byte
  per sample tick (rate-divided). Each fetched byte feeds an extra
  channel into the digital mixer in `pokey_i2s_tx.sv`.
- ANTIC's existing DMA arbitration handles the bus-time accounting.
- An end-of-stream IRQ source could be added to the second POKEY's IRQ
  table (since we're not using its IRQs for anything else).

Two flavours worth supporting:
1. **8-bit mono** — the original COVOX format. Cheap and small.
2. **16-bit stereo** — useful for sample-quality music. Uses 4 bytes per
   sample, doubles the bandwidth.

Why not now: requires HyperRAM read-port time-sharing with the existing
mem_read_mux, which interacts with ANTIC's DMA timing in non-trivial
ways. Worth doing once the M16b HyperRAM stack is fully exercised under
production loads (M22+) and the bandwidth budget is well understood.

## Analog audio fidelity (Altirra Appendix E)

The `docs/altirra-pokey-audit.md` audit identifies four cosmetic
deviations from POKEY's analog output behaviour:

- **Channel-DAC bit weights** aren't perfect powers of 2 (real POKEY
  shows ~{0.12, 0.26, 0.56, 1.12} V).
- **Non-linear saturation** of the channel sum at total volume > 12.
- **Two-stage analog AC coupling** (τ ≈ 2.6 ms first stage, τ ≈ 24.7 ms
  second stage) — gives POKEY its characteristic exponential-decay
  envelope on long pulses.
- **Polarity / DC bias** — real POKEY output is positive at silence.

These could be implemented as a fixed-point post-mixer DSP block in
`pokey_i2s_tx.sv` that applies the saturation curve and the high-pass
filter at the chosen sample rate. The Altirra appendix gives explicit
discrete-time recurrences (e.g., `y_{n+1} = y_n + (x_n - y_n)·(1 -
e^(-1/(τ·fs)))` for the high-pass).

Why not now: not audible to most users; HDMI sinks already AC-couple
their analog stage. Worth doing for completeness if a "purist" mode is
ever requested, but skip until then.

## Recover ~3 MHz fmax lost to the JMPI page-wrap fix

The `sally-jmp-indirect-bug` resolution (commit `2c41a81`, 2026-05-10)
patched Arlet's `cpu.v` to model the NMOS 6502's `JMP ($xxFF)`
page-wrap quirk correctly. This was a **correctness fix** — period
demos and copy-protection schemes that hit `JMP ($xxFF)` now run
exactly as they would on real Atari hardware instead of taking the
65C02-style cross-page path Arlet originally implemented.

Cost: clk_bus dropped 169.66 MHz → 166.69 MHz at 162 MHz target
(+0.276 ns slack → +0.171 ns slack). BASE_DIV=90 margin shrank from
8.6 MHz to 5.6 MHz. Resource-wise: −1 FF / +58 LUT, with **+237
cells inside `u_sally_core`** (940.5 → 1177.5).

Why the cost: the patch split JMPI1 out of the shared
JMP1/JSR3/RTS3/RTI4 PC_temp case so JMPI1 alone uses
`{ DIMUX, ADD + 8'd1 }` (8-bit wrap on the low byte) while the
others stay at `{ DIMUX, ADD }` followed by 16-bit `PC_inc=1`.
That branch on `state == JMPI1` prevents Synplify from sharing the
new 8-bit adder with the existing 16-bit `PC_temp + PC_inc` adder
on the rest of the PC update path. Two parallel adders → wider
critical path → −3 MHz.

The natural-looking fix — keep a single 16-bit PC adder and gate
the carry propagation between PCL and PCH on JMPI1 — was tried
**empirically** on 2026-05-12 in two variants:

1. **Split-adder with state-gated carry** (8-bit + AND + 8-bit):
   clk_bus 165.0 MHz (−4.7 MHz vs baseline), **+331 LUT**. The
   state-gated AND between PCL and PCH carry breaks Synplify's
   carry-chain optimisation, so the resulting structure is worse
   than a single 16-bit adder.
2. **Single 16-bit adder + output-side mux on JMPI1** (preserves
   carry chain, suppresses high byte via post-add mux): clk_bus
   168.0 MHz (−1.7 MHz vs baseline), **+471 LUT**. Better than
   split-adder but still worse than the original.

Both variants showed that the future-work.md sketch's "+2-3 MHz
recovery" estimate was wrong. The original cost (−3 MHz at the
JMPI fix) is apparently structural — there's no obvious way to
recover it without a deeper restructure of the PC update path or
the SALLY FSM. Either Synplify was already sharing more than the
synth-results.md commentary assumed, or the critical path isn't
actually through the PC adder at all (likely candidates: cache-
read-data mux, hwreg_dout decode).

**Status: tried, didn't work. Both attempts reverted.** Leave the
JMPI fix in its current state (two parallel adders). The 3 MHz
cost is locked in unless / until someone does a deeper SALLY-FSM
restructure (e.g., M24-und undocumented opcodes would touch this
area anyway).

**Why not now**: empirically demonstrated that the obvious PC-adder
restructure variants don't recover the lost fmax (see "tried,
didn't work" note above). A deeper restructure of the SALLY FSM
might, but it's a non-trivial engineering effort against vendor
RTL we don't otherwise touch. The current +0.277 ns slack at 162
MHz (post-phi2_o, commit `4679881`) is positive, the BASE_DIV=90
floor is cleared with 8.6 MHz to spare, and Klaus 6502 passes. No
real-software workload has flagged the JMPI fix as a fmax
bottleneck. Trigger to act:

1. If a future feature pushes clk_bus below the BASE_DIV=90 floor
   (161.08 MHz). Then a deeper restructure becomes the cheapest
   available recovery option.
2. If we ever do M24-und (undocumented opcodes) — already touching
   cpu.v with a Klaus rerun anyway, so bundling a deeper PC-update
   restructure adds little marginal risk.
3. If a synth-results regression-tracking pass (M-fmax-XXX style)
   makes the cost visible to xtc-targetted profiling.

## Cache wide-data path: CACHE_WORD_BYTES=4 (4× refill)

`M-cache-rework Step 7` landed `CACHE_WORD_BYTES=2` (2 bytes per HR
refill cycle, 1 KB miss = 515 cycles). The original spec headline was
~336 cycles per 1 KB miss, which corresponds to **CACHE_WORD_BYTES=4**
(4 bytes per cycle = ~256 cycles + setup overhead).

Probe results (`cache_line_ram_synth_top` at WORD_BYTES=4): 2 EFX_RAM10
per memory + 16 LUTs (4:1 byte-mux on read). Scaling from
WORD_BYTES=2's per-memory cost (1 RAM, 8 LUTs):

- BRAM: per-memory cost doubles (2 vs 1) → cache total grows by ~64
  EFX_RAM10. Step 7 baseline is 155 / 256, so projected total
  ~219 / 256 (86 %). Tight but fits.
- LUT: byte-mux is still **1 LUT level** (LUT4 implements 4:1 muxes
  natively), so the fMax penalty is similar to WORD_BYTES=2's — likely
  ~−2 MHz from extra muxing on the read path, possibly more if the
  wider 4-byte memories thrash placement.
- FF: small increase (~+30 from the wider data registers).

**Why not now**: at the M-cache-rework Step 7 finish line, BRAM headroom
is 101 RAM10 free (256 − 155). Other features in the rp-XT roadmap want
some of that — M25 peripherals (cart slot, SD card buffers), the
COVOX-style sample DMA above, etc. Going to WORD_BYTES=4 commits ~64
RAM10 *now* for a cache speedup that's already comfortable at 2× (515
cycles per miss is well below the SALLY's stall sensitivity).

The clean trigger to revisit:
1. After **M25** lands and we know the actual peripheral BRAM cost.
2. If profiling shows the cache is the bottleneck on representative xtc
   workloads (the streaming-bypass + 2× refill should keep most code
   off the critical path).
3. If RAM10 utilisation stays below ~80 % once everything else is in.

The implementation surface is small at that point — `cache_line_ram`
already supports any WORD_BYTES; it's a single-line change in sally_mem
to bump `CACHE_WORD_BYTES` from 2 to 4, plus widening the antic_top
stub and a few testbench mocks.

## RP2354 GPIO at 1.8 V (drop the FPGA-link translators)

Both RPs (main + peri) currently run their FPGA-link GPIO banks at
**3.3 V**, which forces 7 × 74LVC8T245 between the RPs and the FPGA's
1.8 V HSIO (6 chips for the main rp_tx/rp_rx link, 1 chip for the
peri-RP SPI). Total translator cost: ~$4.90 / board.

If we could run those banks at 1.8 V instead — matching FPGA HSIO —
the translators disappear and we'd pocket the ~$4.90.

Two reasons we're at 3.3 V today:

1. **Main RP throughput**: rp_tx and rp_rx are source-synchronous at
   FPGA `clk_bus` rate (~162 MHz at BASE_DIV=90). RP2350 GPIO drive
   at 1.8 V has lower drive strength and slower edges than at 3.3 V;
   the typical ceiling at 1.8 V is ~50 MHz toggle. Likely too slow
   to sustain ~162 MHz source-synchronous edges across a board
   trace, but it's untested on real silicon.
2. **Peri RP partitioning**: the peri-RP's 48 GPIOs can't cleanly
   isolate the 4 FPGA-link pins from the 44 Atari-side pins on a
   separate IOVDD rail without splitting the chip's footprint
   across multiple supplies. The Atari side genuinely needs 3.3 V
   to interoperate with 5 V TTL noise margins, so the FPGA-link
   pins inherit 3.3 V too.

The clean trigger to revisit:
1. After the first rp-XT silicon comes back, **measure** the RP2350's
   actual 1.8 V GPIO toggle ceiling on real PCB traces. If it
   sustains the rp_tx/rp_rx rate, drop the 6 main-RP translators.
2. **Re-examine peri-RP IOVDD partitioning** if Raspberry Pi
   publishes detailed application notes — particular pin-banks may
   have separate IOVDD pins on the QFN-80 that we haven't fully
   inventoried.

If both routes pan out, total translator BOM drops from ~$11.10 to
~$6.20 per board.

## xtc indirect-jump policy: avoid JMP ($xxFF) (and a ROM-safe runtime helper)

The `sally-jmp-indirect-bug` fix (Issues.md, RESOLVED 2026-05-10)
made our `sally_core` model the NMOS page-wrap quirk correctly —
`JMP ($02FF)` now reads its target high byte from `$0200`, not
`$0300`. **xtc-compiled code running on our FPGA is therefore safe
by construction.** Where this still bites: code that runs on real
NMOS Atari hardware, or on a different emulator, or anywhere else
the bug isn't fixed. xtc binaries that target multiple hosts need
to sidestep the boundary case in their generated code.

### Policy A — compile-time check (adopted)

xtc's codegen MUST never emit `JMP ($xxFF)` — i.e., never an
indirect-jump opcode where the indirect-pointer's low byte is
`$FF`. This is a static property of the generated machine code:

- Linker / assembler guarantees the indirect-pointer slot it
  allocates for any `JMP ()` does not land at a `$xxFF` address.
- For computed targets, see Policy C below.

The check is mechanical (filter on linker symbol-placement) and
free at runtime. Documented here so the constraint is explicit
in xtc's coding rules; the actual implementation lands in xtc's
codegen / linker once those are written.

### Policy C — RTS-trick runtime helper for ROM-safe indirect jumps (adopt-when-needed)

Self-modifying code (the traditional indirect-jump workaround on
6502: write the target into a `JMP $abs` operand at runtime) does
**not** work in ROM cartridges. When xtc needs to emit a runtime
indirect jump from ROM-resident code — i.e., the target is computed
at runtime AND the calling code lives in cartridge ROM — codegen
emits the **RTS-trick** sequence inline:

    LDA target_hi      ; computed elsewhere
    PHA
    LDA target_lo - 1  ; computed elsewhere
    PHA
    RTS                ; pulls PC and increments → jumps to target

7 bytes / 13 cycles. No reserved RAM (works from ROM). No fixed
ABI vector to maintain. Stack-burdening (2 bytes), but fine for
non-recursive call patterns and trivially balanced inside a single
function.

Considered alternative — the C64-style fixed RAM vector pattern
(`STA $F0 / STY $F1 / JMP ($00F0)`) — was rejected for xtc:

- Reserves 2 bytes of RAM forever (zero page is precious on Atari).
- 11 bytes / 11 cycles vs RTS trick's 7 / 13 — slightly larger
  code, marginally faster runtime, but the RAM reservation is the
  real cost.
- Adds an OS-level ABI surface (the published vector address) that
  has to stay stable across xtc releases. The RTS trick is purely
  internal to the calling function.

The fixed-vector pattern would be the right choice if xtc wanted
**other** programs (Atari OS, hand-written assembly, third-party
xtc binaries) to call *into* xtc-compiled routines via a known
hook. That's a separate question — probably moot since xtc
binaries are linked statically — but if it ever becomes relevant,
revisit then.

### Why both, not one

- **A alone** is sufficient for indirect jumps where the target is
  known at compile time (xtc's compiler picks safe vector slots).
- **C alone** would work but adds 13 cycles + 7 bytes to *every*
  indirect jump, including the ones A would catch for free.
- Together: A covers the static case at zero cost; C handles
  computed-target cases that A can't catch. Codegen picks per call
  site based on whether the target is a link-time-known address
  or a runtime expression.

### What lands in fpga-antic

Nothing — this is xtc's policy, recorded here only because the
JMPI fix that motivates it lives in fpga-antic's `cpu.v`. When xtc
codegen exists, this policy moves to `xtc/doc/codegen-policy.md` (or
similar) and the fpga-antic note becomes a back-reference.

## Expansion-trace reservations

Two HDL items have landed:
- `phi2_o` in commit `2d07117` (M-PBI-adjacent)
- PCM1808 integration in commit `6de29c3` (M-aux-audio)

The remaining item is **second POKEY serial port** — peri-RP-side
PCB reservation only, no FPGA HDL change. See below.

### Cart/PBI AUDIO_IN — PCM1808 stereo ADC ✓ (HDL complete)

**HDL complete** (commit `6de29c3`): `hdl/pcm1808_rx.sv` drives
BCK/LRCK and samples SDATA; `hdl/pokey_i2s_tx.sv` extended with
`adc_l_in` / `adc_r_in` mix inputs + soft saturation. `antic_top`
exposes new top-level pads `adc_bclk_o`, `adc_lrck_o`,
`adc_sdata_i`. Synth: clk_bus 164.9 MHz / +0.105 ns slack;
47/47 sims pass.

**Design** (TI PCM1808, 24-bit stereo I²S ADC, ~$2 Q10): two
analog mono inputs, both summed into both L and R of the final
stereo output:

- **PCM1808 Lin**  ← SIO AUDIO_IN (from the SIO connector pin —
  same line POKEY's cassette FSK reads from; allows software-FFT
  or future cassette playback)
- **PCM1808 Rin**  ← PBI AUDIO_IN (cart-edge AUDIO_IN signal,
  fanned out to both PBI and cart-slot connectors)

Both inputs are mono signals from physically separate sources;
neither is panned. The audio-mix HDL sums each ADC channel into
**both** sides of the final stereo output:

    out_L = sum(POKEY_L_channels) + adc_l + adc_r
    out_R = sum(POKEY_R_channels) + adc_l + adc_r

#### Board

- 1× PCM1808 in slave mode (BCLK + LRCK driven by FPGA, DOUT to
  FPGA). +$2 BOM.
- DC-blocking caps on each input (typically 1 µF X7R).
- 3.3 V VCC for the PCM1808 digital side, +5 V analog if VCCA is
  separate (check datasheet — most pin-strap configurations run
  on a single 3.3 V supply).
- Trace from SIO connector AUDIO_IN pin to PCM1808 Lin.
- Trace from PBI connector AUDIO_IN pin (fanned to cart-edge
  AUDIO_IN too) to PCM1808 Rin.

#### FPGA pads (new external I²S RX bus)

3 new FPGA outputs/inputs (the existing pokey_i2s_tx is internal-
only — its I²S is just a naming convention for the protocol
shape, no external pins):

| FPGA pin | Dir | Connects to |
|----------|-----|-------------|
| `adc_bclk_o`  | out | PCM1808 BCK (3.072 MHz at 48 kHz sample rate × 64) |
| `adc_lrck_o`  | out | PCM1808 LRCK (48 kHz) |
| `adc_sdata_i` | in  | PCM1808 DOUT (serial PCM, 24-bit per channel L-first) |

Slow-rate pins; can go on any HSIO or HVIO bank.

#### HDL (M-aux-audio milestone, future)

- New `pcm1808_rx.sv` module: BCLK/LRCK generator (off the
  existing 48 kHz tick in pokey_i2s_tx), I²S RX state machine,
  registers L/R 24-bit samples into clk_bus domain.
- Extend `pokey_i2s_tx.sv`: add `adc_l_in[23:0]` and
  `adc_r_in[23:0]` ports; sum both into both `lpcm_l` and
  `lpcm_r` before driving hdmi_pkt_source.
- Probable resource cost: ~80 FF (24-bit L/R sample regs + small
  state machine + BCLK counter), ~80-120 LUTs (RX shift register
  + 2 × 25-bit summing adders), 0 BRAM. fMax impact negligible
  (audio-rate clocked logic, well below critical path).

#### Saturation strategy: soft clamp

`pokey_i2s_tx` maps the POKEY channel-sum (0..60) into 24-bit
LPCM by left-shifting. Adding two 24-bit signed ADC inputs can
overflow the sum at peak amplitude.

**Locked: soft saturation** (clamp to ±max on overflow), not
pre-attenuation of the ADC channels. Reasoning:

- The cart and PBI AUDIO_IN paths are **rarely active**. Most
  carts don't drive AUDIO_IN at all; PBI devices that emit audio
  are even rarer. The case "both active simultaneously and both
  loud" is essentially never in practice.
- Pre-attenuating the ADC channels (right-shift by 1-2 bits)
  would silently throw away dynamic range on the *common* case
  where only one of the ADC channels is active (or neither), to
  protect a corner case that doesn't happen.
- Soft saturation matches real-Atari analog-stage behaviour
  (POKEY's analog DAC saturates — see "Analog audio fidelity
  (Altirra Appendix E)" above). The "Atari sound" already
  includes mild saturation at high mix levels.

Implementation: after the 4-input sum (POKEY_L + adc_l + adc_r
on the L side, and the matching sum on the R side), clamp to
the 24-bit signed range. A 26-bit intermediate sum + a clamp on
the top bits is enough — synth costs +2 LUTs per output side over
straight-add behaviour.

### Second POKEY serial port — peri-RP path

The second POKEY (`u_pokey_r` at $D21x) is byte-level in HDL —
identical interface to the first POKEY. The first POKEY's SIO is
bit-serialised on the **peri-RP firmware side** via peri_link
byte transfers. The second POKEY's RS-232 should follow the same
pattern.

PCB reservations:
- **2 peri-RP pads** routed to a future RS-232 connector
  (TXD + RXD). Peri-RP has 9 spare GPIOs.
- **MAX232 / SP3232 footprint** for level translation between
  peri-RP's 3.3 V and DB9's ±12 V. Or a 3.3 V pin header
  (USB-serial-adapter-compatible).

HDL/firmware work (M-serial milestone, future):
- Extend `peri_bridge.sv` with a second serial channel (pokey_r
  bytes carried over peri_link).
- Peri-RP firmware: software UART (PIO or bit-banged) that
  serialises pokey_r byte payloads to RS-232 frames and reverse.

No FPGA-pad change today.

## M-PBI — fully complete (no deferred items)

All M-PBI deferred items have landed. See
[roadmap.md § M-PBI](roadmap.md#m-pbi) for the full history.
Last commit: `7f547c9`. clk_bus closes at 167.11 MHz / +0.186 ns
slack, 46/46 sims pass.

## Other ideas (one-liners, in case we revisit)

- **Sweet 16** as native hardware ops (referenced in M24 — Apple II's
  microcode-style 16-bit pseudo-machine).
- **Variant board: full 3.3 V Atari** (drops the 5 V translation stack;
  loses period-cart compatibility) — see hardware-notes.md.
- **NTSC composite video output** as a third video path (alongside HDMI)
  for CRT enthusiasts. ANTIC already produces the right timing; adding
  a tiny DAC + sync mixer reaches RCA jack output.
- **Cassette tape interface**: POKEY's two-tone FSK mode is already
  designed for it. Adding a 3.5 mm jack + audio amplifier is mechanical
  more than logical.
