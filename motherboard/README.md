# motherboard — STM32F411 I/O companion

Firmware for **IC3**, the STM32F411VET6 on the Atari-XT carrier. It owns
everything the FPGA should not have to: USB-HID host, the physical Atari SIO
port, joysticks and paddles, MIDI, and fan control. It talks to the FPGA over
SPI plus a handful of GPIO, and to the Zynq over a UART that doubles as the
firmware-update channel.

Design rationale lives in [`docs/OS/sio-bridge.md`](../docs/OS/sio-bridge.md).
This README is the practical half: how to build it, how to talk to it, and what
the hardware actually does.

```
motherboard/
  firmware/          the STM32 firmware
    src/             sources — one file per subsystem
    ld/              linker script
    Makefile         build, flash, console
  tools/             host-side probe scripts
```

## Quick start

```sh
cd motherboard/firmware
make                    # build
make flash              # program over SWD via the Black Magic Probe
make scan               # what can the probe see?
../tools/rtt-gdb.sh id  # run one REPL command and print the reply
```

The probe is autodetected; override with `make flash BMP=/dev/cu.usbmodemXXXX1`.

## Toolchain

`arm-none-eabi-gcc` with newlib (Homebrew's `arm-none-eabi-gcc` is fine — 10.3
is known good). The firmware links `-nostdlib`: it has no heap, no syscall
layer, and provides its own `memcpy`/`strlen`/`printf` family in `mini.c` and
`console.c`. That is deliberate — a device with no way to report an allocation
failure should not be making allocations.

## Talking to the board

There are two transports and one REPL behind them, so the same commands work
from either and there is no mode to switch.

| Transport | Wires | Notes |
|-----------|-------|-------|
| **RTT over SWD** | none — rides the debug port | The developer console. Needs a probe whose firmware has RTT (see below). |
| **USART2, 115200 8N1** | PA2/PA3 | The Zynq's channel (its UART0 on MIO14/15). Also works with a USB-serial adapter. |

### RTT and the Black Magic Probe

The board has no spare debug UART. J17 brings out SWDIO, SWCLK and NRST but
leaves SWO unconnected, and PB3 — the TRACESWO pin — is spent on USART1_RX for
SIO. So the console rides **RTT**: ring buffers in target RAM that the probe
reads and writes over SWD while the CPU keeps running. Zero pins, bidirectional,
and non-intrusive.

`rtt.c` is a clean-room implementation of the control-block layout debuggers
scan for. Nothing is linked in from SEGGER; only the in-memory structure is
shared, which is what interoperating requires.

**RTT must be compiled into the probe firmware** (`ENABLE_RTT=1`, or
`rtt_support=true` under meson). Stock Black Magic firmware v2.0.0 does *not*
include it — `monitor rtt` answers "Target does not support this command".
Check with:

```sh
arm-none-eabi-gdb -batch -ex 'target extended-remote /dev/cu.usbmodem*1' \
                  -ex 'monitor help' | grep rtt
```

With RTT in the probe, `../tools/bmp-console.sh` gives an interactive terminal.
Without it, `../tools/rtt-gdb.sh "<command>"` drives the same REPL one command
at a time through plain gdb memory access — slower, but it needs no reflash and
is enough to bring a board up.

### REPL commands

```
help                   this list
id                     chip, clocks, reset cause
uptime                 time since boot
mr <addr> [n]          read memory words
mw <addr> <val>        write a memory word
gpio <pin> [state]     inspect or drive a pin      e.g. gpio c8, gpio a9 1
hub [cycle|hold|run]   USB hub reset on PA9
js                     joystick and button state
pot [cal lo hi]        paddle values
fan [duty|rpm n]       fan duty, tach and PID
ring                   pulse the FPGA doorbell
fault [clear]          saved fault record
crash                  force a fault (test)
reset                  reboot the STM32
```

Numbers accept `0x` or `$` for hex.

## Clocking

8 MHz crystal (Y1) → PLL → **96 MHz** core, **48 MHz** USB. 96 rather than the
100 MHz maximum because 100 has no divisor that also yields a legal 48 MHz USB
clock, and USB host is the point of this part. If the crystal fails to start the
firmware falls back to the HSI so the console still comes up and can say so —
`id` reports which source is live.

## Pin map

The authority is [`src/board.h`](firmware/src/board.h), which carries the
schematic net name against every pin. Summary:

| Port | Use |
|------|-----|
| **A** | USART2 (PA2/PA3), SPI1 slave (PA5/6/7), doorbell (PA4), hub reset (PA9), USB OTG-FS (PA11/12), SWD (PA13/14), USART1 TX for SIO (PA15) |
| **B** | 8 paddle pots (PB0/1, PB4-9), USART1 RX for SIO (PB3), FPGA control (PB13/14/15) |
| **C** | USART6 MIDI (PC6/7), fan PWM (PC8), fan tach (PC9) |
| **D** | all 16 joystick direction lines, in port order |
| **E** | SIO control lines (PE0-5), 4 fire buttons (PE12-15) |

Two consequences of the layout worth knowing:

- **All 16 direction lines are on GPIOD in port order**, so one `IDR` read
  samples every controller at the same instant. No skew between the up and left
  of a diagonal — which is exactly the artefact that makes a scanned joystick
  feel wrong.
- **All 8 pot pins are on GPIOB**, so discharge (one `BSRR` write) and release
  (one `MODER` write) are simultaneous for every pot; they share a common t0.

## Subsystems

### Joysticks and buttons — working

Switches to ground with internal pull-ups; sampled at 1 kHz and debounced over
3 consecutive agreeing samples.

### Paddles — working, needs calibration against real hardware

An Atari paddle is not an ADC input: it is a 1 MΩ pot charging a capacitor, and
the machine counts scanlines until the voltage crosses a threshold. `pots.c`
does the same — drive the pin low to discharge, release it to a floating input,
and time the climb through the GPIO Schmitt threshold, mapping onto POKEY's
0..228.

**Not** timer input capture, which is what the design note originally assumed.
The obvious mapping (TIM3_CH1..4 on PB4/PB5/PB0/PB1 plus TIM4_CH1..4 on PB6..PB9)
collides with the fan: PC8 and PC9 are TIM3_CH3 and TIM3_CH4, and one compare
unit cannot serve two pins. Polling `GPIOB->IDR` against the DWT cycle counter
needs no timer channels at all, reads all eight pots simultaneously, and still
resolves far finer than 228 steps — a full-scale charge is ~33 ms, so one step
is ~145 µs and the main loop revisits far more often than that. The measurement
is a non-blocking state machine, so nothing stalls for the charge.

Calibrate the endpoints against a real paddle with `pot cal <min_us> <max_us>`.
Defaults are 0..33000 µs, computed for 1 MΩ × 47 nF.

### Fan — PWM and tach working, PID untested (no fan spinning yet)

25 kHz PWM on PC8 via TIM3_CH3; tachometer on PC9 counted with EXTI9 rather than
input capture, because TIM3 is busy generating a 40 µs PWM period and a capture
unit on the same timer would see hundreds of overflows per tach pulse. Edge
counting over a 250 ms window is ample for 500-3000 RPM.

Both control modes are available: `fan <duty>` for the planned arrangement where
the A9 reads XADC junction temperature and pushes a duty byte, and `fan rpm <n>`
for a self-contained PID on the STM32. The integrator only accumulates when the
output is off its rails, so a stalled or absent fan cannot wind it up into a
permanent 100 % demand.

### USB host, SPI link, SIO — not yet implemented

See the task list in [`../docs/NextSteps.md`](../docs/NextSteps.md).

## Hardware notes

Two things found while bringing this up that are worth a decision.

### PB2 (BOOT1) appears unconnected

The F411 samples **BOOT1 on PB2** four SYSCLK edges after reset. With BOOT0
high, BOOT1 low selects the system-memory ROM bootloader and BOOT1 high selects
embedded SRAM. PB2 has no pull in its reset state and the schematic shows no net
on it, so the level is undefined — which makes "FPGA drives BOOT0 high and
pulses NRST to reach the AN3155 bootloader" a coin flip rather than a
guarantee.

PB2 is otherwise unused, so the fix is a wire or a 10 kΩ resistor from PB2 to
GND. Until then, SWD is the reliable programming path.

### TIM3_CH3/CH4 are double-booked

PC8/PC9 (fan) and PB0/PB1 (the IRR paddle pots) are the same two TIM3 compare
units. The firmware resolves this without a board change — the fan keeps TIM3
and the paddles use no timer channels at all (above) — so this is recorded for
awareness, not as an open defect.

### PA9 is HUB_RST, not VBUS

USB OTG-FS therefore has **no VBUS sense pin** and the core must be configured
with VBUS sensing disabled. The 4-way hub is self-powered from the board rail
and owns VBUS and overcurrent itself.

### Hub reset polarity is assumed active-low

`HUB_RST_ACTIVE_LOW` in `board.c`. Confirm against the hub page of the schematic
before trusting a failed enumeration.

## Debugging gotchas

- **Never park a stopped CPU on `BKPT`.** With `C_DEBUGEN` clear it escalates to
  a HardFault — an infinite fault loop that overwrites the saved fault record
  with a report about the breakpoint. With a debugger enabled but detached it
  wedges the debug port badly enough that the probe can no longer scan the
  target. Both fault and default handlers spin instead; a spinning core stays
  scannable and haltable.
- **`WFI` gates the debug clocks.** `clock_init()` sets `DBGMCU_CR` SLEEP/STOP/
  STANDBY so a sleeping core stays visible to the probe.
- **If `swd_scan` fails**, recover by connecting under reset:
  `monitor connect_rst enable`, `monitor swd_scan`, `attach 1`, then
  `monitor connect_rst disable`. Leaving it enabled resets the target on every
  attach, which shows up as `reset nrst-pin` in `id`.
- **gdb refuses peripheral reads by default** — anything outside the probe's
  declared memory map fails with "Cannot access memory". `set mem
  inaccessible-by-default off` (the make targets already do).
