# SIO bridge & STM32F411 I/O companion

> **Status: design note, pinned for board layout.** Sibling to
> [`expansion-options.md`](expansion-options.md); same philosophy (faithful 1× bus on the
> outside, byte-level over a fast internal link). This is the truth for the SIO
> port and the companion MCU.

## 1. Roles

The carrier has a **physical Atari SIO DIN port** (real peripherals plug in)
and an **STM32F411 I/O companion**. The STM32 is:

- the **USB-HID host** (keyboard/mouse) — it supersedes the earlier RP2354 plan
  because TinyUSB on RP2350-family is device-mode-first, whereas the F411's
  USB-OTG-FS host + ST USB Host stack is the better host-mode path;
- the **SIO host controller** for the physical port (drives real SIO signalling
  to plugged-in drives / FujiNet / etc.);
- the **virtual-peripheral** engine (disk/network services in firmware);
- the host for **joystick / paddle** reads and **MIDI** (§8).

It connects to the FPGA over **SPI (~5 MHz) + a few GPIO**, plus a **UART on PS
MIO** for firmware programming and runtime control.

```
 6502/POKEY (emulated in FPGA, register-level SIO)
        │  byte-level, NO serialization
        │  SPI (~5 MHz) + control GPIO
        ▼
   STM32F411  ──USART (8N1, 19200..hi-speed)──► physical SIO DIN port ──► real peripherals
        │   └─ virtual disk/net services (handled in firmware, no bus traffic)
        ├──USB-OTG-FS host──► keyboard / mouse
        └──USART (31250, opto)──► MIDI IN/OUT
```

## 2. The pivotal fact: our POKEY does not serialize

The emulated POKEY is **register-level only**. SEROUT/SERIN ($D20D) are byte
registers — there is **no bit shifter and no baud-rate generator**. The serial
IRQ semantics are correct though: IRQST bits 3 (out-complete), 4 (out-ready),
5 (in-ready) latch and fire properly (`hdl/pokey_regs.sv:240-251`).

Therefore we **short-circuit serialization** — we own both ends, so no UART
sits between the FPGA and the STM32:

```
6502 writes SEROUT ─► FPGA ships the byte over SPI ─► STM32
STM32 returns a byte ─► FPGA pokes SERIN + pulses ser_in_byte ─► POKEY raises IRQST bit-5 ─► 6502
```

Consequences:
- **No UART on the FPGA↔STM link.** A byte is a byte. The only real UART is the
  STM32's, facing the *physical* DIN port (§5).
- **Baud rate is whatever we want** — high-speed SIO for free; only pace the
  SERIN IRQ cadence if a timing-sensitive loader needs authentic gaps.
- **SPI bandwidth is a non-issue** — SIO is ≤16 KB/s even high-speed; 5 MHz SPI
  is ~200× over-provisioned. (25 MHz is the *expansion-port* SPI, not this.)

## 3. No external bus masters

A peripheral asks for service by pulling **/IRQ**; the CPU runs its handler,
polls the devices it knows, and runs the responsible device's CIO driver *on
the emulated CPU*. Nothing off-system DMAs into memory. So on the physical port
the **data line direction is purely R/W** and there is no arbitration.

## 4. FPGA ↔ STM32 link (internal)

The byte data path is SPI; sideband state is GPIO. Slow/rare SIO control lines
(COMMAND framing aside) ride a status byte in the SPI stream rather than burning
pins.

**The FPGA is the SPI master** (reusing the existing `hdl/peri_link.sv` master);
the STM is the **slave** on **SPI1 = PA5 (SCK) / PA6 (MISO) / PA7 (MOSI)** — just
3 wires. It is point-to-point with a single slave, so **NSS is not wired**: the
STM uses software slave-management (SSM=1, SSI=0 → permanently selected). That
frees **PA4**, which becomes the STM→FPGA doorbell (§4.2). Because the STM is a
slave it cannot self-initiate — that's why the doorbell points STM→FPGA.

> No NSS means no hardware byte-framing/resync, so the FPGA master must always
> clock clean multiples-of-8 from idle SCK (it does — deterministic RTL); add an
> idle/sync convention if mid-stream re-alignment is ever needed.

### 4.1 Wire budget (~11 wires)

| Group | Wires | Notes |
|-------|-------|-------|
| **SPI1** | 3 | PA5 SCK, PA7 MOSI, PA6 MISO (no NSS — software-managed, point-to-point) |
| **Control GPIO** | 4 | see §4.2 (incl. PA4 doorbell) |
| **Programming/control UART** | 2 | PS **MIO**, not PL pins; TX/RX |
| **Reset/boot control** | 2 | PS **MIO**: NRST, BOOT0 |

The SPI(3) + GPIO(4) land in the FPGA PL pin budget (7 PL pins); the UART(2) +
NRST/BOOT0(2) live on the 9 spare **MIO** pins — separate from the PL count.

### 4.2 Control GPIO (4)

FPGA is SPI master, so the **FPGA→STM** wake needs no GPIO — the STM's SPI-slave
RX interrupt fires when the master clocks a byte in. Only the **STM→FPGA**
direction needs a doorbell, because the slave can't self-initiate.

| Line | Dir | Faithful PIA pin | Meaning |
|------|-----|------------------|---------|
| **ATN_S2F** (doorbell, **PA4**) | STM→FPGA | — | "I have data — come read." STM **loads MISO, *then* raises** PA4 → FPGA (master) reads. PA4 is the freed SPI1_NSS pin (no hardware NSS in point-to-point). EXTI on the **FPGA** side; preload-then-ring kills the slave-stale-data race. |
| **COMMAND** | FPGA→STM | PIA **CB2** | SIO command-frame strobe. Driven by the 6502 writing **PBCTL ($D303)** — that's how the real OS SIO routine asserts COMMAND, so it MUST originate in the PIA. The STM mirrors it onto the DIN port. Dedicated line for framing certainty. |
| **PROCEED** | STM→FPGA | PIA **CA1** | Peripheral PROCEED → sets PACTL bit 7 + CPU IRQ. STM merges the physical port's real PROCEED with its own virtual one. |
| **INTERRUPT** | STM→FPGA | PIA **CB1** | Peripheral INTERRUPT → sets PBCTL bit 7 + CPU IRQ. Same merge as PROCEED. |

**MOTOR_CONTROL** = PIA **CA2** (6502 writing **PACTL $D302** bit 3). Slow/rare →
rides the SPI status byte, not a dedicated GPIO. If pins ever get tight, **COMMAND**
can also be demoted into the SPI status byte (a 5 MHz status read is single-µs vs
a 520 µs SIO byte → ~100× margin); it's a dedicated line purely for framing
certainty.

> **These four lines are the PIA's CA1/CA2/CB1/CB2 — not POKEY's.** POKEY only
> does the serial *data* (SEROUT/SERIN) + serial IRQs + keyboard/break. The PIA
> control lines are currently **stubbed** in `hdl/pia_regs.sv` — implementing
> them is the main remaining SIO RTL (§11).

### 4.3 STM interrupt map

Most async events are **peripheral** interrupts (own NVIC vector, no EXTI):
SPI1 RX (FPGA→STM data), USART1 RX (SIO data in), USART2 RX (control), USART6 RX
(MIDI in), OTG_FS (USB), TIM3/TIM4 CC (paddles).

The only **EXTI** (GPIO-edge) inputs are the three SIO control lines coming *in*:

| EXTI | Pin | Signal | Edge | Action |
|------|-----|--------|------|--------|
| **0** | PE0 | SIO_IRQ = INTERRUPT (SIO pin 13) | falling/both (active-low) | drive FPGA-side INTERRUPT → PIA **CB1** |
| **1** | PE1 | SIO_PROCEED (SIO pin 9) | falling/both (active-low) | drive FPGA-side PROCEED → PIA **CA1** |
| **15** | PB15 | FPGA_COMMAND (PIA CB2) | **both** (brackets the 5-byte frame) | begin/end command-frame handling |

(PE0/PE1 chosen over PC0/PC1 — Port C is congested near the LSE crystal; the EXTI
line follows the pin *number*, so EXTI0/1 are unchanged, just `SYSCFG_EXTICR` →
port E.) EXTI0/EXTI1 have dedicated NVIC vectors; EXTI15 shares `EXTI15_10` (alone
there). Source is port-selected per line, so PB0/PB1 (paddle timers) and PA15
(USART1) keep their AF roles even though those indices' EXTI lines are routed to
PE0/PE1/PB15. **No EXTI** for the PA4 doorbell (it's an STM *output*) or USB
faults (the hub owns VBUS/overcurrent). Pull-ups: SIO pins 9/13 are open-collector
active-low → need them; FPGA_COMMAND is push-pull but a weak pull keeps it defined
during the FPGA-config float.

## 5. Physical SIO port (STM32-driven)

The STM32 is the host controller on the DIN connector. Its **USART** carries the
async byte data; the rest are GPIOs.

**All control lines are STM-mediated** — FPGA-side GPIO → STM → DIN-side GPIO,
*not* wired straight through the CB3T to the connector. Deliberate choice (STM
pins are plentiful on the VET): the STM merges real + virtual peripherals,
re-times, and translates in firmware, at the cost of a little processing/latency
— nothing on these slow async lines. COMMAND has to be STM-mediated regardless
(coupled to the STM-generated serial frame, §2); routing PROCEED/INTERRUPT the
same way keeps the whole control group uniform instead of splitting some lines
direct and some not.

| SIO signal | Dir (computer-relative) | Owner / treatment |
|------------|-------------------------|-------------------|
| DATA_OUT | computer→peripheral | STM USART TX |
| DATA_IN | peripheral→computer | STM USART RX |
| COMMAND | computer→peripheral | STM GPIO ← FPGA COMMAND (PIA CB2) |
| MOTOR_CONTROL | computer→peripheral | STM GPIO ← FPGA (PIA CA2); logic-level, **no flyback needed** — the motor/relay live inside the tape deck, not on our board |
| CLK_OUT / CLK_IN | both | STM GPIO, **wired but idle** — SIO is async in practice (see note below) |
| PROCEED | peripheral→computer | STM GPIO in → merged → FPGA (PIA CA1) |
| INTERRUPT | peripheral→computer | STM GPIO in → merged → FPGA (PIA CB1) |
| AUDIO_IN | peripheral→computer | **analog** — see §7 |

USART rate: **19200** baud standard, high-speed divisors (38.4–127 k) for fast
accessories. COMMAND framing + the control lines are GPIOs; only DATA is USART.

**CLK_IN/CLK_OUT are vestigial.** Despite the pins, SIO is **asynchronous** —
timing is recovered from the start bit + known baud, like any UART — so they
carry no data; every real peripheral uses async. They exist only because POKEY's
serial port *can* run synchronous/externally-clocked (SKCTL), which nothing uses.
Wire them through the CB3T for completeness but leave them idle (CLK_OUT at its
idle level, CLK_IN ignored). Note the STM USART couldn't be slaved to CLK_IN
anyway — its synchronous mode is **master-only** (emits a clock on CK); external-
clock-in would need SPI-slave/bit-bang, not worth it for a feature with no users.

## 6. Firmware programming

The FPGA owns the STM32's **NRST + BOOT0** and a UART to it (both on PS MIO).
To flash: drive BOOT0 high, pulse NRST, and the on-chip ROM bootloader speaks
the **AN3155 USART protocol** — auto-baud, **8E1 (even parity)**. PS software
drives the protocol through the FPGA UART passthrough. No USB-device port is
needed for firmware update. The same UART doubles as the runtime control/debug
channel (it is the time-offset twin of the bootloader role).

The F411 ROM bootloader watches **fixed** pins — **USART1 (PA9/PA10)** or
**USART2 (PA2/PA3)**. PA9–PA12 are consumed by **USB OTG-FS** (DM/DP/ID/VBUS),
so the bootloader/control role sits on **USART2 (PA2/PA3)**; SIO then takes
USART1 remapped to **PA15/PB3** (per the F411 AF table). See §8.1.

**Zynq MIO side.** The expansion-socket MIO on this board are all **Bank 500
(MIO[15:0]) @ 3.3 V** → they wire straight to the STM, no level-shifting. Bank 500
only reaches the low UART pairs (convention: **even = TxD out, odd = RxD in**):
- **UART1**: MIO8/9 (8 TX / 9 RX) or MIO12/13
- **UART0**: MIO10/11 or MIO14/15

UART1 is the REPL console, so the bootloader link uses **UART0 on MIO14/15**
(assigned):
- **MIO14** (even = TX, net `UART2_TO_STM`) → STM **PA3** (USART2_RX)
- **MIO15** (odd = RX, net `UART2_FROM_STM`) ← STM **PA2** (USART2_TX)
- **NRST** + **BOOT0** = plain MIO GPIO outputs on any free Bank-500 pins.

(Net names reference the *STM's* USART2; on the Zynq side MIO14/15 is controller
**UART0** — Zynq-7000 has no UART2 — so configure "UART 0" in the Vivado MIO map.)

Low MIO is crowded (QSPI / SD / boot straps), so confirm both pins of the chosen
pair are free *and* brought out to the connector — Vivado's MIO config greys out
taken pins. Fallback if no clean pair survives: EMIO a UART to PL pins (spends PL
pins).

## 7. Audio — real analog AUDIO_IN (SIO + PBI)

Both the SIO AUDIO_IN and the PBI/cart AUDIO_IN are **real analog** inputs,
captured by a **PCM1808 stereo I²S ADC** and summed digitally into the POKEY
mix:

- `hdl/pokey_i2s_tx.sv` sums `adc_l_in` (**SIO AUDIO_IN**) and `adc_r_in`
  (**PBI/cart AUDIO_IN**) into both L and R, then to the HDMI audio packetiser.
- PCM1808 driven at BCLK 3.072 MHz / LRCK 48 kHz, 24-bit signed I²S
  (`hdl/antic_top.sv:746-763`).

The I²S pins split by direction and are **already fully allocated** — do not go
hunting for other pins:

| I²S pin | Direction | Use |
|---------|-----------|-----|
| DIN, FSYNC_IN | in | PCM1808 capture (SIO + PBI analog audio) |
| DOUT, FSYNC_OUT | out | audio to the HDMI side |
| SCLK | shared | common bit clock |

Carrier-side per analog input: AC-couple, bias to mid-rail, light anti-alias RC
into the PCM1808. The digital path is done.

## 8. MIDI (STM32-driven)

ST/TT-style MIDI is async serial at **31250 baud** — trivial for an STM32
USART, but **not** "just a serial port":

- **MIDI IN needs an opto-isolator** (6N138 / H11L1) → USART RX. The galvanic
  isolation is the whole point (no ground loops / hum between gear).
- **MIDI OUT** = USART TX → current-loop drive (two ~220 Ω resistors).
- **MIDI THRU** (optional) = a buffered copy of the opto output; no USART.
- Connector: **TRS Type-A** (3.5 mm; 2018 MMA standard — Tip→DIN-5, Ring→DIN-4,
  Sleeve→DIN-2/shield) is far smaller than DIN-5 and adapter-compatible. Match
  gear to **Type-A** (Type-B swapped Tip/Ring).

Byte path to the emulated ST (m68k on the A9) is the same bridge pattern as SIO:
STM USART ↔ SPI ↔ FPGA ↔ A9 MFP-USART. 320 µs/byte swamps bridge latency, so
timing (incl. MIDI-Maze-style networking) stays faithful.

### 8.1 STM32F411 USART allocation (exactly 3, no muxing)

| USART | Pins | Role | Notes |
|-------|------|------|-------|
| USART2 | PA2/PA3 | Bootloader + FPGA control | ROM-bootloader interface; chosen because PA9/PA10 are USB; time-offset twin |
| USART1 | **PA15/PB3** | SIO (physical port) | default PA9/PA10 are USB → remapped to PA15/PB3. These are **JTAG JTDI/JTDO-SWO**, so this forfeits 4-wire JTAG + SWO trace (disable JTAG-DP, SWD on PA13/PA14 still works). Always-on real-time |
| USART6 | PC6/PC7 | MIDI | default PA11/PA12 are USB → PC6/PC7; always-on real-time |

USB OTG-FS owns **PA9 (VBUS) / PA10 (ID) / PA11 (DM) / PA12 (DP)** — that
collision is what forces all three USARTs off their defaults above.

SIO and MIDI must **not** share a USART (independent simultaneous streams). The
only legitimate share is bootloader↔runtime-control (same endpoints, never
concurrent). That uses all three silicon USARTs 1:1 — the time-offset trick is
the escape hatch for a *4th* serial role, not a way down to two.

## 9. Electrical / level shifting

- The DIN port (and the cart/PBI ports) are **5 V**; the FPGA/STM are 3.3 V.
  Route the SIO lines through the spare **CB3T (SN74CB3T16210)** bus switch near
  the cartridge port. The STM is 5 V-tolerant on inputs and 3.3 V out clears the
  SIO TTL high threshold (~2.0 V), but the CB3T gives clean clamping and a
  uniform interface.
- SIO data lines are **unidirectional** (DATA_IN and DATA_OUT are separate
  pins) — unlike the 6502 bus — so no direction-control logic, just per-line
  conditioning.

> **Open work / next steps** are tracked in [NextSteps.md](../NextSteps.md) — see "SIO / PBI / cartridge / companion MCU".

## 11. Current RTL state (what exists vs what's to build)

| Piece | State | Where |
|-------|-------|-------|
| POKEY serial data (SEROUT/SERIN) + serial IRQs (IRQST 3/4/5) | **Built** | `hdl/pokey_regs.sv` (register-level; no bit-shifter — by design, §2) |
| Byte-level FPGA↔companion link (the SIO data path) | **Built, byte-level** | `hdl/peri_bridge.sv` + `hdl/peri_link.sv` (SPI). Validates the "no UART, byte-level" bet — currently targets the **RP2354**; re-point at the STM32F411. |
| PIA registers + XL PORTB banking ($D300–$D303) | **Built** | `hdl/pia_regs.sv` |
| PIA **CA1/CA2/CB1/CB2** = PROCEED/MOTOR/INTERRUPT/COMMAND | **Stubbed** — PACTL/PBCTL bits stored but inert | `hdl/pia_regs.sv` — the work in §10 |
| COMMAND / MOTOR / PROCEED / INTERRUPT pads + GPIO path | **Absent** | to add (§4.2, §5) |
| break_key (BREAK → IRQST bit 7) | **Built**, via the peri link | `hdl/peri_bridge.sv` |

So the **data plane is done and already byte-level** (the key architectural bet);
the remaining SIO RTL is the **PIA control lines** plus plumbing the GPIO to pads.
Nothing here is POKEY's job beyond the serial data it already handles.

## 12. Companion firmware

The firmware lives in [`motherboard/`](../../motherboard/README.md); that README
is the authority on the pin map, the build and the console. Three decisions made
there change what this note assumed:

**Paddles use no timer channels.** The natural mapping — TIM3_CH1..4 on
PB4/PB5/PB0/PB1 and TIM4_CH1..4 on PB6..PB9 — collides with fan control, because
PC8 and PC9 are TIM3_CH3 and TIM3_CH4 and a compare unit cannot serve two pins.
The fan keeps TIM3; the eight pots are timed by polling `GPIOB->IDR` against the
DWT cycle counter instead. All eight pins are on one port, so discharge and
release stay simultaneous, and a full-scale ~33 ms charge resolves to ~145 µs per
POKEY step — far finer than the 228 levels need. No board change, nothing lost.

**The fan tachometer is edge-counted on EXTI9**, not input-captured: TIM3 is
generating a 40 µs PWM period, so a capture unit on the same timer would see
hundreds of overflows per tach pulse. A 250 ms edge-count window is ample for
500-3000 RPM.

**The console is RTT over SWD**, not SWO. J17 leaves SWO unconnected and PB3
(TRACESWO) is spent on USART1_RX, so the developer console rides ring buffers in
target RAM that the debug probe reads and writes while the CPU runs. The same
REPL is also served on USART2, which is the Zynq's channel.

### Open hardware item: BOOT1

§6 assumes the FPGA can drive BOOT0 high, pulse NRST, and land in the AN3155
ROM bootloader. That needs **BOOT1 (PB2) low**, and PB2 is unconnected on the
schematic with no pull in its reset state — so the boot mode is undefined
between system memory and embedded SRAM. PB2 is otherwise unused; a wire or a
10 kΩ resistor to GND settles it. Until then SWD is the reliable programming
path.
