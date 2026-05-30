# FPGA implementation

There are really only three other main components outside of 'memory'
and 'video', and that's 'audio', 'peripherals' and 'cpu'.

## Audio
This is basically POKEY, integrated on-chip and sending the I2S data
across to the TMDS output internally instead of pulling it in via
pins.

## Peripherals

We need:
- joysticks (4 of them, 20 pins),
- SIO (8 control pins),
- the parallel port (which is mainly a buffered version of the actual bus
- the cartridge slot (ditto).
- USB host for keyboard/mouse

None of these are high-speed peripherals.

## CPU

The Arlet Ottens core at https://github.com/Arlet/verilog-6502 is the
right starting point — small (~700 LUTs), expect 100+ MHz on the
Zynq-7020, free with attribution, and cycle-accurate for our purposes:

- Every official opcode takes the same number of cycles as the real
  chip, and the address bus is driven on the matching cycle during
  each FSM step. RDY-style halt works for ANTIC bus stealing and
  `STA $D40A` (WSYNC) — the rainbow-demo workload runs.
- BCD via parameter; Atari OS uses it for the system clock, leave on.
- "Stable" undocumented opcodes (LAX, SAX, DCP, ISC, …) are in; the
  "unstable" ones (XAA, AHX, etc.) come out deterministic where real
  silicon is voltage-dependent — Atari software basically never uses
  those.

The core has been extended in-tree with stage A/B/C embellishments
(4 KB hidden stack, 12-bit SP, SP-relative addressing, PSH/PLL bulk
save/restore — see `docs/6502/6502-embellishments.md`) to support a
practical C-style calling convention from XTC.

Other niceties might be to enable Sweet 16 as actual hardware
instructions (https://en.wikipedia.org/wiki/SWEET16) or possibly
evolve into the 65816
