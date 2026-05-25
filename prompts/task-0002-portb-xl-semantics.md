# task-0002 — PORTB semantics match stock Atari XL OS

## Goal
Decode PORTB ($D301) in sally_mem with the real Atari XL/XE bit meanings so
the stock OS ROM's own PORTB writes keep the ROMs mapped.

## Why (boot-to-BASIC blocker #2)
sally_mem used a non-standard map (bit0=BASIC active-low, bit6=OS
active-low). The stock XL OS never drives bit6 and uses bit0/bit1 with the
opposite polarity, so after the OS writes PORTB the OS ROM would map out
and $C000 access would fall through to the (dead/banked) data window.

## Stock XL/XE PORTB bits
- bit 0: OS ROM enable, ACTIVE HIGH. 1 = OS ROM at $C000-$CFFF + $D800-$FFFF
  visible; 0 = RAM.
- bit 1: BASIC ROM enable, ACTIVE LOW. 0 = BASIC ROM at $A000-$BFFF visible;
  1 = RAM.
- Reset value $FF => OS ROM on, BASIC off — correct power-on. The OS
  coldstart clears bit1 to map BASIC in when OPTION isn't held.
- bits 2,3,4 are 130XE bank-select (untouched here); bit7 self-test (n/a).

## Change
`hdl/sally_mem.sv`:
- `basic_rom_en = basic_rom_range && !portb[1];`  (was `!portb[0]`)
- `os_rom_en    = (os ranges) && portb[0];`        (was `&& !portb[6]`)
- header + inline + port comments updated to XL semantics.

PIA already resets PORTB to $FF (pia_regs.sv:120), which under the new map
is the correct OS-on/BASIC-off power-on state — no PIA change needed.

## Tests
- `sim/tb_sally_mem.sv` A.8/A.9/A.10/A.11 + default/reset: remap the portb
  constants to XL semantics ($00 = BASIC on; $03 = OS on; $02 = both off).
- Other tbs tie portb to $FF (all-RAM under the OLD map). Under the new map
  $FF = OS-on. Re-run the SALLY regression and fix any tb that needs the
  all-RAM state (use a bit0=0/bit1=1 value).

## Verify
    make -C sim sally_mem sally sally_arb sally_isa sally_stack os_rom_load page_test
All must print their OK banner.

## Synthesis
Closure runs on win10 (vivado/run-win10.sh) — not required to land; sim is
the gate.
