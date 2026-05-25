# task-0001 — bank 0 = BRAM for both banked windows

## Goal
Make bank index 0 of BOTH banked windows resolve to the flat 64 KB BRAM
instead of the DDR3 page cache. Only a non-zero bank index ($0082 for the
code window, $0083 for the data window) selects a DDR3-backed page.

## Why (boot-to-BASIC blocker #1)
- The legacy Atari uses $6000-$9FFF as ordinary writable RAM: the OS
  RAM-sizing walk hits $6000 almost immediately, and the GR.0 screen +
  display list land ~$9C00 on a 48K machine.
- ANTIC reads display data from the SAME flat BRAM via its DMA port
  (sally_mem.sv:480). Keeping bank 0 in BRAM means CPU writes (which also
  shadow into BRAM) stay coherent with what ANTIC displays.
- Today bank_xlat routes $6000-$CFFF to the page cache for ALL bank
  indices including 0, and the page cache's AXI master is tied off in
  fpga_xt_top (fpga_xt_top.sv:240-246) — so any bank-0 access stalls
  SALLY forever. Also the code cache is read-only, so $6000-$9FFF could
  never be RAM via that path anyway.

## Change
`hdl/bank_xlat.sv`:
- `is_in_window` asserts only when the address is in a window AND the
  selected bank for that window is non-zero:
    code_banked = ($6000-$9FFF) & (cpu_code_bank != 0)
    data_banked = ($A000-$CFFF) & (cpu_data_bank != 0)
    is_in_window = code_banked | data_banked
- `is_code`, `offset_in_block`, `bank_id` unchanged (don't-care when
  is_in_window=0; consumers gate on is_in_window).

No change needed in sally_mem: it already gates axi_req_valid / was_bank_q
on is_in_window_w, and the BRAM read/write path handles bank-0 accesses
(cpu_w shadow-writes mem[], reads fall through to bram_dout_q).

## Tests
- `sim/tb_bank_xlat.sv`: add a section that drives bank 0 (code + data)
  and asserts is_in_window=0, plus a mixed case (one window banked, the
  other not). Keep the existing nonzero-bank cases.
- `sim/tb_sally_mem.sv`: A.4 / A.4b currently assume bank 0 -> AXI.
  Rewrite to test bank-0 -> BRAM round-trip AND a non-zero bank -> DDR3
  read. A.9 / A.11 ($A000 / $C000 with ROMs disabled, bank 0) now hit
  BRAM, not the page cache — adjust to write/read round-trips.

## Verify
    make -C sim bank_xlat sally_mem page_test
All three must print their *** ... OK *** banner.

## Synthesis
RTL/timing closure runs on the win10 Vivado host via vivado/run-win10.sh
(faster than the ubuntu box). Not required to land this task — sim is the
gate here.
