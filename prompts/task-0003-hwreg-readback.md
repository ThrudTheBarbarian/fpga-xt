# task-0003 — register read-back path across the SALLY<->ANTIC CDC

## Goal
Make SALLY reads of the hardware-register page ($D000-$D7FF) return the
real GTIA/POKEY/PIA/ANTIC values, instead of the hardcoded stub ($FF / a
couple of blitter regs).

## Why (boot-to-BASIC blocker #3)
The SALLY->ANTIC register bus was write-only (fire-and-forget async FIFO in
fpga_xt_top).  hwreg_dout was hardcoded; antic_bus_data_out was produced but
never consumed.  The OS reads hardware registers constantly (CONSOL, IRQST,
KBCODE, PORTA/PORTB, VCOUNT, NMIST, ...), so without real read data it can't
run.

## Design
The register state lives in clk_sys (inside antic_top) and antic_top's read
mux (bus_data_out) is combinational on bus_addr.  Reuse it via a CDC
round-trip with a SALLY stall:

1. antic_top PIA fix (hdl/antic_top.sv): the read mux covered GTIA/ANTIC/
   POKEY but omitted PIA ($D3xx).  Declare `pia_read_data`, connect
   pia_regs `.rdata`, add a `d3xx_read` term to bus_data_out_w / oe.

2. hwreg_rd_cdc (hdl/hwreg_rd_cdc.sv, NEW): toggle-handshake bridge.
   clk_sally captures the read address + stalls SALLY (rd_busy); clk_sys
   drives the address onto antic_top's bus (bus_rw=read), the combinational
   mux yields the byte, it crosses back, the stall releases.  Address/data
   buses are carried by simple 2-FF syncs (stable during transfer); a
   `bus_idle` input gates the read start so a draining write can't collide.

3. fpga_xt_top integration:
   - classify CDC-served reads: $D000-$D7FF read, minus blitter $D4B0-$D4CF.
   - instantiate hwreg_rd_cdc; bus_rdata = antic_bus_data_out.
   - mux cdc_bus_addr / bus_rw=read / d0xx_n / d4xx_n onto the ANTIC bus
     during cdc_bus_read; pause the write-FIFO drain meanwhile.
   - fold hwreg_rd_busy into sally_clock's busy (stall) — NO sally_mem
     interface change.
   - hwreg_dout: blitter regs local; everything else = cdc_rd_data.

## Verify
- `make -C sim read`         — tb_read extended with PIA $D3xx reads
  (PACTL default + PORTA/PORTB DDR write-readback).
- `make -C sim hwreg_rd_cdc` — new unit tb: round-trip + stall + re-issue
  across async clocks with a mock combinational responder.
- `make -C sim sally_mem bank_xlat page_test sally sally_arb sally_stack
  sally_isa os_rom_load snoop dl_parse nmi pokey pia_regs` — no regression.
- `verilator --lint-only --top-module antic_top hdl/*.sv` — clean.
- fpga_xt_top: verilator-parsed clean (only missing-primitive errors:
  MMCME2_BASE/BUFG/IOBUF/sally_core); no binding errors in the integration.

## Not yet validated
Top-level runtime behavior (no integration sim exists for fpga_xt_top).
Validate on the win10 Vivado build + hardware bring-up (bring-up.md Phase 8):
confirm the OS reads CONSOL/IRQST/KBCODE/VCOUNT correctly.

## Fidelity notes / future work
- Undecoded hwreg reads (no ANTIC decode) return $00 (ANTIC mux default)
  rather than open-bus $FF.  Boot-irrelevant; revisit if needed by piping
  antic bus_data_oe through the CDC.
- Served reads assumed side-effect free (status/port/counter).  True today;
  if a read-to-clear register is ever added, the FSM must present the read
  exactly once (it already issues once per rd_req episode).

## Synthesis
Closure on win10 (vivado/run-win10.sh).
