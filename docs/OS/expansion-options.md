# Expansion options — slots, card interfaces & bridges

> **Status: design note, not yet built.** Pins the architecture of the expansion
> slots so the RTL and the carrier PCB agree before either is committed. The
> signal treatment, the 1× window model, the dynamic clock slowdown, and the
> FPGA-direct link are the load-bearing decisions; pin assignments and register
> addresses will move.

## Overview — two card interfaces per slot

Every expansion slot carries **two independent card interfaces**, and a card uses
whichever it is built for:

- **Interface A — 1090-style parallel bus (PBI).** The faithful Atari 6502/PBI bus
  (address / data / control), presented so a PBI-shaped card sees the OS-supported
  plug-in contract. Detailed in §1–§10.
- **Interface B — FPGA-direct (1 Mbit UART + 8-bit/25 MHz synchronous bus).** A
  modern link to "smart" cards that carry their own MCU (e.g. RP2354) — no parallel
  bus, all single-ended 3.3 V. Detailed in §11.

Both interfaces' pin sets sit on **every** slot connector (all five slots are
identical for Interface B). **Everything is 3.3 V** — so Interface A is *1090-style*,
not drop-in 1090/PBI compatible: a genuine PBI/1090 card plugs in only through a
**riser** that does the 3.3 V↔5 V (and connector) conversion. The riser is a separate
piece of work.

## 1. What this is

The FPGA *is* the computer on this bus: it drives the address/control lines and
arbitrates data exactly as a stock XL would, presenting the OS-supported PBI
plug-in contract to any PBI-shaped card. The bus is at **3.3 V** (the whole carrier
is 3.3 V), so this is *1090-style*, not electrically 1090 — a genuine PBI/1090 card
plugs in only through a **riser** that does the 3.3 V↔5 V level translation
(SN74CB3T16210-class FET bus switches, FPGA owns data-bus direction) and connector
adaptation. That riser is a separate design.

The whole point of the PBI is that it is already a complete, OS-supported
plug-in contract: the XL OS scans the bus at boot, finds a card, and can pull a
CIO handler straight out of the card's ROM. We add no new protocol — we just
present the bus faithfully.

### 1.1 The decisive constraint: PBI runs only at 1×

The PBI never runs faster than real phi2 (~1.79 MHz, ~559 ns/cycle). At
`clk_sally` = 100 MHz that is **~56 internal clocks per bus cycle** (~67 at
120). Every "hard" part of bridging a real bus — responding in time, inserting
wait-states, sampling card data — happens with that much slack. There is no
tight race; for an external access the FPGA mostly *idles* waiting for the slow
world. This is what makes a faithful bridge tractable rather than marginal.

### 1.2 No external bus masters

PBI devices signal for service by pulling **/IRQ** low. The CPU runs its IRQ
handler, polls the cards it knows about to find the source, and runs that
card's driver/CIO code *on the (emulated) CPU*. Nothing off-system ever DMAs
into memory. Consequences:

- **D[7:0] direction is purely R/W** during a bus window — FPGA drives on
  write, floats and samples on read. No arbitration, no third party.
- **/HALT is vestigial** for this model (it was the 1090's lever and the
  unreliable /REF-halt trick). We keep the input wired because it folds into the
  existing DMA `halt_effective` term for free, but nothing depends on it.

## 2. Slots are all the same bus

On the PBI side there is **no logical difference between an internal slot and
the external connector** — it is one electrical bus fanned out to several
physical places. Every card straps a unique device ID and self-decodes, exactly
as on a stock machine. "Don't double-assign IDs" is the user's responsibility,
same as it always was.

- **Device select is software, via $D1FF** — a one-hot write, one bit per
  device, **8 devices maximum**. That 8-ID pool is shared across internal slots
  and the external connector; an ID used internally is simply gone externally.
- Target is **5 internal slots** (~15 × 5 cm each) plus the external 1090
  connector — comfortably under the 8-ID ceiling.
- The FPGA carries **zero per-slot logic** on the PBI side. It drives the bus +
  the broadcast strobes onto every slot in parallel; the cards do all their own
  ID decode and latching. The FPGA does not even need to store $D1FF — it only
  generates the strobe (§4).

> A separate 1450XL-style select register was considered (to copy a non-released
> internal-1090 variant) but could not be substantiated, so it is dropped. If it
> ever resurfaces it costs nothing: alias the extra address to the same select
> strobe in the FPGA and both register conventions work at once.

### 2.1 The second interface: the FPGA-direct sideband

Each slot also carries a second, completely separate interface — the **FPGA-direct
byte-wide synchronous bus** (+ a control UART) — alongside the parallel bus. The parallel bus carries
the *OS-visible* contract (driver download, CIO, register page, IRQ handshake) at
authentic 1× speed; the FPGA-direct link gives a card a fast private channel to the
PS for bulk data. A card can present a tiny register/ROM face to the Atari OS over
the parallel bus and do its real work over the FPGA-direct link. Full spec in §11
(Interface B).

### 2.2 Connector

Mechanically the slots use a **PCIe ×4 edge connector** — cheap, robust,
staggered-length contacts (free ground-first / presence-detect / power
sequencing), and pins to spare for the full bus + sideband. It is *not* PCIe
electrically; the form factor is borrowed, not the protocol. (The risk of
someone inserting a real PCIe card into an Atari is considered self-correcting.)

## 3. Signal treatment

Naming follows the project's existing `antic_top` M-PBI convention. "Exists"
means the logic is already generated internally and gated to `CLOCK_MULT==1`;
the work is plumbing it to pads (top-level ports + XDC + IOB-packed flops).

| Pin | Dir | Treatment |
|-----|-----|-----------|
| `A[15:0]`, `R/W`, `phi2` | out | Projected, phi2-paced, only during a bus window. Exists internally. |
| `/EXTSEL` (`bus_d1xx_n_o`) | out | Low on $D1xx page access — the selected card's register window. Exists. |
| `/EXTENB` (`bus_extenb_n_o`) | out | PBI master-enable strobe for the window. Exists. |
| `/CARDSEL` | out | The **$D1FF select-register write** strobe (§4). New decode. |
| `D[7:0]` | **bidir** | New IOBUF. Drive on write (un-hardcode `prod_write_drive`), float + sample on read. OE gated by `ext_bus_active` so it stays quiet at turbo. |
| `/MPD` | in | Card pulls low → suppress internal OS ROM in the math-pack/OS-ROM region, take read data from external D (device ROM shadows OS). New read-mux. Input port exists, tied off. |
| `/IRQ` | in | 2-FF sync → wired-OR into CPU `irq_n`. Input port exists, tied off. |
| `/RDY` | in | 2-FF sync → AND into `sally_rdy`. Meaningful now that the access is at 1×. |
| `/HALT` | in | 2-FF sync → AND into the existing `halt_effective` term. Low priority (§1.2). |
| `/RST` | bidir | Sync in; drive low on internal reset. |
| `/REF`, `/CAS`, `/RAS` | — | **Not implemented.** DRAM-refresh signals; the PBI /REF-halt trick was never reliable and is not needed. |

## 4. /CARDSEL — the select-register strobe

Device selection on the PBI is the $D1FF one-hot, and it splits cleanly into two
questions a card must answer:

- **"is it me?"** — answered by the card's strapped device-ID bit.
- **"is it now?"** — answered by **/CARDSEL**: *this cycle is a write to the
  $D1FF select register, sample the data bus against your strap.*

On real cards /CARDSEL exists to offload the decode: rather than every card
carrying a full A0–A15 comparator qualified by R/W and phi2, the host
pre-decodes "$D1FF + write + phi2-valid" and broadcasts it. Each card collapses
to one gate + flip-flop:

```
on /CARDSEL falling:  selected <= (D[7:0] & my_strap_bit) != 0
```

Scope: **/CARDSEL is only the select-register strobe.** Once a card is latched
selected, accesses to its register window ($D100–$D1FE) are qualified by
**/EXTSEL** + the card's own latched state; /CARDSEL is not involved there. The
FPGA, being the decode logic the original cards were trying to avoid
replicating, generates this strobe for free.

## 5. The 1× bus-window FSM

Any CPU access that lands in PBI space runs as a real phi2-paced cycle on the
pins. With ~56 internal clocks of slack this is unhurried:

1. Decode that the cycle targets PBI space ($D1xx, or the /MPD ROM region while
   a card asserts /MPD).
2. Assert `rdy = 0` to the emulated CPU (it stalls — the registered-MAR core
   simply holds).
3. Drive `A`, `R/W`, raise `phi2`, assert `/EXTSEL` (and `/CARDSEL` if it is a
   $D1FF write).
4. **Write:** drive `D[7:0]`. **Read:** tristate `D`, let the card drive, sample
   near the falling phi2 edge.
5. Lower phi2, deassert; for a read, mux the sampled byte into the CPU read path
   (§6). Release `rdy`.

At turbo (`CLOCK_MULT ≥ 2`) the pads are frozen exactly as today — no SSO, no
EMI, no switching. The window only opens at 1×.

## 6. /MPD shadow — device ROM/RAM replaces the $D800–$DFFF window

On a stock Atari $D800–$DFFF is the OS **floating-point math-pack ROM** (/MPD =
**M**ath **P**ack **D**isable). **In the XT that window is shadow-RAM by default**
— RAM-under-ROM is enabled, so $D800–$DFFF is general-purpose RAM for the
compiler; the FP ROM only maps in on the rare path where an interrupt uses floats
(≈never). So /MPD here overrides **live RAM**, not a read-only ROM.

When a selected card pulls **/MPD** low, the internal window must be suppressed
and the access routed to the card — this is how a card's ROM (signature, init
vectors, CIO handler) becomes visible to the OS PBI scan. The shadow is
**transient**: active only while the card is selected/servicing.

New logic — a mux point in `sally_mem` keyed on synced `/MPD` + addr ∈ $D800–$DFFF
that **fully bypasses the window both directions** while asserted:
- **Read:** select external `D[7:0]` over the internal dout.
- **Write:** gate the internal write-enable **off** and drive the write out to the
  card (RAM/registered device); a pure-ROM card ignores writes.

**State-preservation (the XT wrinkle vs. a stock Atari).** Because the window is
*live compiler RAM*, not read-only ROM, the override must **not** write-through to
internal RAM during the shadow — that's what the WE-gate above guarantees. The
compiler's contents then survive the transient PBI excursion and reappear intact
when the card deselects; the program is suspended inside the handler anyway, so no
live conflict.

`sally_mem` already has a read-mux (from the fmax work) — the natural insertion
point; you add one source, not a new read path.

**Priority / interaction.** /MPD is an **orthogonal external override**,
independent of the bank registers ($D5C0/$D5C1) and of the shadow-RAM-enable. Add
it as the **highest-priority** input to the $D800–$DFFF decode (above default
shadow-RAM, above the rare FP-ROM mapping); while asserted the internal copy goes
dormant. No bank-logic rework.

> **To confirm against the OS PBI handler / ROM source:** that /MPD shadows
> exactly $D800–$DFFF (vs. adjacent OS ROM), and the precise $D1FF select/IRQ-
> status semantics. Verify before freezing the decode.

## 7. Dynamic clock slowdown — the heart of it

The machine normally runs at a PS-configured turbo baseline. The bridge gets to
**override that baseline downward** while the external bus is in use, and restore
it when the conversation is over:

```
effective_clock_mult = pbi_active ? 8'd1 : sw_clock_mult
```

`pbi_active` is a **retriggerable one-shot**:

- **Set by** external `/IRQ` assertion *or* any PBI-space address decode.
- **Held** by a retriggerable timeout — each PBI access refreshes it.
- **Cleared** when `/IRQ` is deasserted *and* no PBI access for the timeout
  window → ramp back to `sw_clock_mult`.

This gives exactly "slow down when there's an external IRQ, speed back up when
we're done talking over the bus," while leaving PS in control of the baseline.
The /IRQ trigger fires *before* the handler's first bus touch, so we are already
at 1× when servicing starts.

There is a useful self-consistency: a card's handler ROM is shadowed into the
$D800 region via /MPD, so **every instruction fetch of the handler is itself a
PBI-space access** and would wait-state to 1× anyway. The explicit `pbi_active`
slowdown only adds value for the cases that *don't* hit the bus every cycle — a
device delay loop, an SIO-style bit-timing routine, or a CIO transfer that
touches internal RAM mid-service — where it guarantees authentic timing.

So two mechanisms collapse into one latch:

1. **Per-access wait-state FSM (§5)** → *correctness* (valid phi2 cycle + data).
2. **`pbi_active` slowdown** → *timing fidelity* for device code.

### Where it lives — clk_sally, not the `$D4CA` software path

`pbi_active` and the `effective_clock_mult` override **must be generated in the
`clk_sally` domain** (the CPU's and `sally_clock`'s domain), driven by the PBI-space
address decode — which is already a `clk_sally` signal, since the CPU's address bus
is. It must **not** be driven through the software `$D4CA` / `scale` speed register:

- That path has **CDC latency** (`clk_sys` register → 2-FF sync → `clk_sally`), so a
  "set 1× just before the access" lands several cycles late — the CPU may already
  have run the PBI access **at turbo**, and the device sees a too-fast cycle. That is
  a real correctness failure, not just a timing wobble. A multi-cycle condition (an
  `/IRQ`) tolerates the latency; a **single bus cycle does not**.
- Generated in `clk_sally` it is **zero-latency, deterministic, and crosses no clock
  domain**, so it is inherently glitch-free (no runt phi2 / double-step) — the
  divider-transition concern only arises for a value that crossed a CDC, which this
  one does not.

Software `clock_mult` (`$D4CA`) stays the turbo **ceiling**; `pbi_active` is a
transient hardware force-to-1× layered on top — `max(force_1x ? 1 : sw_clock_mult)`,
decoded in `clk_sally`. (Open: should `$D4CA` read-back reflect the ceiling or the
momentary force-1×? — lean: the ceiling.)

The existing `auto_phi2_on_extirq` / `extirq_fallback` force-1× is the same idea but
lives in `clk_sys` — fine for a sustained IRQ, **too slow for a single-cycle
access** — so the per-access slowdown needs its own `clk_sally` decode.

> **Open work / next steps** are tracked in [NextSteps.md](../NextSteps.md) — see "SIO / PBI / cartridge / companion MCU".

## 10. Cartridge port (shares the system bus)

The cartridge port is a separate physical connector but taps the **same system
address/data/control bus** as the PBI (A0–A12 / D0–D7 / R-W / φ2 are shared
nets). So only **5 cart-unique signals** need their own Zynq pins:

| Pin | Dir (FPGA) | Role | `antic_top` signal |
|-----|-----------|------|--------------------|
| **/S4** | out | select $8000–$9FFF (left-cart 8K) | `bus_s4_n_o` |
| **/S5** | out | select $A000–$BFFF (right-cart 8K) | `bus_s5_n_o` |
| **/CCTL** | out | select $D500–$D5FF (cart control / bank-switch) | `bus_cctl_n_o` |
| **RD4** | in | cart-present sense, $8000 window | `bus_rd4_in` |
| **RD5** | in | cart-present sense, $A000 window (main "inserted" line) | `bus_rd5_in` |

All five **already exist in `antic_top`** (the inputs tied to `1'b1` = no cart),
so mapping them is pure plumbing — top-level ports + XDC + the cart-side **CB3T
(5 V)** — with the same **CLOCK_MULT==1 gating** as the PBI bus (selects assert
only at real speed, frozen at turbo). No new RTL just to bring the pins out.

Making a real cartridge actually **run** is the same Tier-B work as the PBI
/MPD shadow (§6): when RD4/RD5 say a cart claims $8000/$A000, the FPGA must
suppress internal memory in that window, drive /S4//S5, take read data from the
cart on the shared data bus, and route $D5xx writes out /CCTL for bank-switching.
Do it alongside the PBI /MPD read-mux.

## 11. Interface B — FPGA-direct (byte-wide synchronous bus)

Interface B is the modern path: instead of a parallel PBI bus, each card is a **smart
endpoint** with its own MCU, reached over two shared, CS-selected transports — a
1 Mbit control UART and an **8-bit / 25 MHz synchronous bus**. Everything is
single-ended 3.3 V, so a card needs no FPGA: an **RP2354 + PIO** drives the bus
directly (§11.6). All five slots are identical.

### 11.1 Pin budget (21 of the 28 spare FPGA pins)

| Group | Pins | Notes |
|-------|------|-------|
| **D0–D7** | 8 | byte-wide data, **bidirectional** (tristate IOBUF); shared bus, CS-selected |
| **SCK** | 1 | bus clock, always FPGA-driven (master) |
| **CS** | 3 | 5 slot-selects via an external 3:8 decoder (74xx138) |
| **IRQ** | 5 | one per slot — a card raises it to request service |
| **UART** | 2 | TX/RX, 1 Mbit, shared; the guaranteed fallback + negotiation channel |
| **MODE** | 1 | card-driven (while it holds CS): which transport — UART vs byte-bus |
| **READY** | 1 | card-driven: "selected, mode set, ready to talk" |
| **Total** | **21** | 7 pins spare of the 28 |

The byte bus and UART are **shared across all 5 slots** (multi-drop), with CS picking
the one active card. There are no longer any "special high-bandwidth" slots — every
slot is identical and gets the full bus when selected.

### 11.2 Two transports

- **UART — fixed 1 Mbit/s, the guaranteed-works fallback + negotiation channel.**
  Everything can do 1 Mbit UART, so there is always a path that works with no
  negotiation; capabilities (and any byte-bus clock change) are agreed over it.
- **8-bit synchronous bus — the workhorse.** FPGA is master (drives SCK + CS); D0–7
  are bidirectional. **8 bits × 25 MHz = 25 MB/s ≈ 2× HDDRIVER's 12.5 MB/s ceiling**
  (and a real period SCSI/ACSI disk is far slower) — so the use case fits with room to
  spare. Not a hard ceiling either: the same bus does **DDR (→50 MB/s)** or a higher
  clock if ever needed; the practical limit is the capacitive loading of 5 slot taps,
  not 25 MHz itself.

MODE selects the transport for a transaction; READY is the per-selection ready latch
(not per-byte flow control).

### 11.3 The shared-bus handshake

Only one slot owns the bus at a time (the 3:8 decoder is one-hot). A transaction
**runs to completion** — the FPGA never drops CS mid-transfer; once a card has the bus
it keeps it until it releases, which imposes a "**don't hog the bus**" discipline.

**FPGA → card**
1. assert the slot's CS (drive the decoder address)
2. wait for READY
3. run the transfer on the chosen transport (clock the byte bus, or talk UART)
4. data flows; deassert CS when done

**Card → FPGA**
1. card raises its IRQ
2. waits for the FPGA to grant CS
3. sets MODE (UART or byte-bus), then READY
4. waits for the FPGA's "what do you want" inquiry, then data flows
5. lowers IRQ when done → the FPGA drops CS → another card can take the bus

### 11.4 Reversibility — trivial here

The byte bus is naturally bidirectional with no turnaround-clock problem, because
**SCK never reverses** — the FPGA always masters it. The D0–7 lines are tristate
IOBUFs:
- **write** (FPGA→card): the FPGA drives D0–7 on SCK edges, the card samples;
- **read** (card→FPGA): the card drives D0–7 on SCK edges, the FPGA samples.

It is exactly "byte-wide SPI," and SPI reads already work this way. Direction is set
by the protocol after CS / MODE / READY — no per-byte token, no both-ends-drive
contention. (This is what made reversibility — essential for a SCSI disk you can both
read *and* write — fall out for free, after LVDS made it hard.)

### 11.5 Signal integrity (single-ended, multi-drop, 25 MHz)

Treat it as a slow backplane bus:

- **Slow-slew the FPGA outputs.** ~2–4 ns edges are fine in a 40 ns bit period and —
  crucially — they make the **unavoidable SoM stub** (FPGA die → module trace →
  board-to-board connector → the closest you can place a resistor) **electrically
  short** (a lumped C, not a transmission line), so it stops ringing. This is the trick
  LVDS couldn't use (it needs fast edges); at 25 MHz slow edges are free, which is what
  dissolves the stub problem.
- **Series source-termination (~22–33 Ω)** on SCK + D0–7 at the **module-carrier
  interface** (FPGA-side terminators — closest reachable to the on-module driver). Per
  driver: the card source-terminates its *own* outputs (read direction) with series R
  **at the card's pins** (no stub on that side).
- **Tristate discipline + idle pulls** so an unselected/empty slot doesn't float; keep
  each slot's tap **stub short**; rough-match D0–7 + SCK lengths (trivial — a 40 ns
  period gives nanoseconds of skew budget).

### 11.6 Cards are MCUs, not FPGAs

Because it's a slow single-ended bus, a "fast" card needs **no FPGA** — an **RP2354**
handles it:
- **PIO** drives/samples D0–7 on each SCK edge deterministically (≈6 PIO cycles per bit
  at a 150 MHz core / 25 MHz bus), with autopush/autopull → **DMA → SRAM** at 25 MB/s;
  the two cores run the card's actual device firmware (the SCSI/ACSI stack, etc.).
- In-package **2 MB flash** (no external flash), **3.3 V I/O** matching the bus, ~30–48
  GPIO — plenty for the ~19 Interface-B signals. Configurable drive/slew, so the
  card-side slow-slew + series-R story works at its own pins.
- All five slots being identical means **one card recipe everywhere**, and the bar to
  building a card drops from "design an FPGA + bitstream" to "write a PIO program" —
  i.e. an actual third-party / hobbyist card ecosystem.

### 11.7 Refinements / to confirm

- **Shared card-driven lines need tristate + pulls.** D0–7, MODE, READY (and the
  card's UART TX) are wired to all slots but only the CS-held card may drive — so
  non-selected cards must release, with pull-ups/downs (MODE/READY pulled to 3V3)
  defining the idle level. MODE/READY are latched by the FPGA at selection.
- **Timeouts on every wait** (READY, inquiry) so an absent/faulty card cannot hang the
  bus — and a READY timeout gives **presence-detect for free** (no extra pin).
- **IRQ arbitration = round-robin among pending** (a higher-numbered IRQ can take CS,
  so plain priority would starve low slots) + an anti-hog **max-transaction watchdog**.
- **3:8 decoder needs a "none-selected" idle state** (drive the '138 enable off, or
  reserve a code) for the arbitration gap.
- **Reset:** no dedicated line — do card reset as a UART command, or spend 1 of the 7
  spare pins on a shared `/RST`.
- **Pin lever:** the 5 dedicated IRQ pins are the biggest single cost; if pins ever get
  tight, collapse them to 1 wired-OR IRQ + poll-the-source over UART (the classic PBI
  $D1FF model) to reclaim 4.
- **Bus clock vs loading:** 25 MHz is set by the 5-tap multi-drop loading, not silicon
  limits; fewer/shorter stubs or DDR buy headroom if a future card ever needs it.
