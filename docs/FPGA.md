# FPGA implementation

The original plan was to have several RP2354's co-operating to create the system, but with a capable FPGA there, it seems we ought to consider integration, especially since the FPGA plan includes system memory management of the HyperRAM 

There are really only three other main components outside of 'memory' and 'video', and that's 'audio', 'peripherals' and 'cpu'.

## Audio
This is basically POKEY, but integrating it on-chip, and sending the I2S data across to the TMDS output internally instead of pulling it in via pins.

possible inspiration: https://github.com/MiSTer-devel/Arcade-Centipede_MiSTer/tree/master/rtl/pokey

## Peripherals

We need:
- joysticks (4 of them, 20 pins), 
- SIO (8 control pins), 
- the parallel port (which is mainly a buffered version of the actual bus
- the cartridge slot (ditto). 
- USB host for keyboard/mouse

Probably all possible with an RP2354 and maybe a little help from the FPGA and some level-translator chips. Communication to the FPGA (where the registers are held) would be possible with just SPI. None of these are high-speed peripherals.

## CPU

The Arlet Ottens core at https://github.com/Arlet/verilog-6502 is the
right starting point — small (~700 LUTs), fast (≥80 MHz on Spartan-6,
comfortably 100+ on Topaz), free with attribution, and cycle-accurate
for our purposes:

- Every official opcode takes the same number of cycles as the real
  chip, and the address bus is driven on the matching cycle during
  each FSM step. RDY-style halt works for ANTIC bus stealing and
  `STA $D40A` (WSYNC) — the rainbow-demo workload runs.
- BCD via parameter; Atari OS uses it for the system clock, leave on.
- "Stable" undocumented opcodes (LAX, SAX, DCP, ISC, …) are in; the
  "unstable" ones (XAA, AHX, etc.) come out deterministic where real
  silicon is voltage-dependent — Atari software basically never uses
  those.

Other niceties might be to enable Sweet 16 as actual hardware
instructions (https://en.wikipedia.org/wiki/SWEET16)