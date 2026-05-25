# task-0005 — keyboard injection into POKEY

## Goal
Give SALLY/POKEY a source of keystrokes so BASIC is usable (type after the
READY prompt).  Not on the path to the prompt itself, but the listed blocker.

## Why
antic_top has a `kbd_event_valid` / `kbd_event_code` input that loads POKEY's
KBCODE and raises the keyboard IRQ, but in fpga_xt_top it was tied to 0/0 —
no keys ever arrive.

## Design (RTL hook — this task)
The real debug UART is on the PS MIO, not the PL.  So the PS receives a char
from the host terminal, translates ASCII -> Atari KBCODE in software, and
writes the byte to the FPGA via the GP0 AXI-Lite blitter-register bridge at
address $D4CF.  fpga_xt_top decodes that PS-originated write and pulses
kbd_event for one clk_sys cycle (code = the written byte).

- Bridge and antic_top are both clk_sys, so no CDC is needed.
- $D4CF is free: the blitter decodes only $D4Bx, the sprite engine $D4Ax/
  $D4Dx.
- Gated on bl_bridge_we so a stray SALLY write to $D4CF can't fake a key.
- OOC build: bl_bridge_we is tied 0, so the hook is inert (PS builds only).

Implementation (hdl/fpga_xt_top.sv):
- declared kbd_event_valid_q / kbd_event_code_q;
- wired them to antic_top.kbd_event_valid / .kbd_event_code (were 1'b0/8'h00);
- kbd_inject_we = bl_bridge_we && bridge_bus_addr==$D4CF; 1-cycle pulse +
  latch the data byte.

## Verify (this task)
- `verilator --lint-only --top-module fpga_xt_top hdl/*.sv` — no new errors.

## Follow-on (PS software + hardware)
- PS driver: read UART1, map ASCII -> Atari KBCODE (incl. shift/ctrl in the
  KBCODE high bits), Xil_Out32 to the $D4CF GP0 offset.  Handle key-up vs
  key-down if needed (KBCODE is press-driven; SKSTAT bit for held keys is a
  later refinement).
- Validate on hardware (bring-up.md Phase 8): type at the BASIC prompt.

## Synthesis
Closure on win10 (vivado/run-win10.sh).
