# rp/video/sim — paired sim for the FPGA<->RP bus

Empty for now. **M3 milestone** populates this directory with:

- `tb_bus_pio.c` — RP-side paired sim that mirrors the FPGA's
  `sim/tb_rp_bus.sv` mock. Uses pico-sdk's PIO emulator (or a
  hand-rolled tick-level model) to validate that the production
  `bus.pio` ingest matches the FPGA TX/RX modules' wire format.
- `Makefile` — host-side build of the C model so it can run in CI.
- A shared opcode-table header (in `rp/video/src/`) imported by both sides
  so wire-format constants can't drift.

See `../../docs/roadmap.md § M3` for the ship criterion.
