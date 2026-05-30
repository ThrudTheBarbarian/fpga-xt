# Issue #0002 — Z-Turn V2 board silent at boot (no UART, no HDMI)

- **Component:** Zynq-7000 boot chain — PS block design, FSBL link, BSP STDOUT
- **Severity:** High (board completely dead on first on-hardware bring-up)
- **Status:** Fixed (2026-05-29 — board boots; FSBL + app + UART confirmed on real silicon)
- **Found:** 2026-05-28 (first SD-card BOOT.BIN on the MyIR Z-Turn V2)
- **Files:** `vivado/bd/zturn_ps_preset.tcl` (new), `vivado/bd/gen_ps_bd.tcl`,
  `vitis/scripts/create_platform.py`
- **Bench reference:** MyIR's own `hdmi-1080p` `BOOT.bin`
  (`~/Downloads/z-turn/zturn-7z020/`) boots cleanly on the V2 board (HDMI + UART
  + SD), so the hardware/bench was proven good throughout.

---

## Summary

Our SD-card `BOOT.BIN` produced a completely silent board — no serial, no video,
only the blue power LED. Three independent root causes stacked up; each had to be
fixed before the next symptom became visible.

## Root cause 1 — generic Zynq PS, not the Z-Turn

`gen_ps_bd.tcl` built a generic PS7 (default MIO/DDR/clock config). On real
hardware that means the wrong UART pins, wrong DDR part/timing, wrong bank
voltages → `ps7_init` brings up nothing usable → dead board.

**Fix:** extracted MyIR's full board-physical PS config verbatim from their proven
`hdmi_out_bd.tcl` into `vivado/bd/zturn_ps_preset.tcl` (343 PCW keys), with the
PL-interface / EMIO / FCLK / I2C0 / TTC0 keys stripped (those are owned by
`gen_ps_bd`). `gen_ps_bd.tcl` now `source`s the preset, then applies our overrides
(HP0/1/3, GP0@150 MHz, EMIO/CLK1/I2C0/TTC0 forced off, FABRIC_INTERRUPT,
IRQ_F2P_MODE DIRECT). UART1 = MIO48/49, bank1 = 1.8 V, DDR per MyIR.

## Root cause 2 — FSBL linked into DDR instead of OCM

The FSBL must run from OCM (it's what brings DDR *up* via `ps7_init`). The
`create_platform.py` `empty_application` hack auto-generated a DDR `lscript.ld`
(entry `0x00100000`), and `import_files` didn't overwrite it → BootROM couldn't
load the FSBL → `ps7_init` never ran → dead board.

**Fix:** `create_platform.py` force-copies the `zynq_fsbl` template's OCM
`lscript.ld` over `workspace/fsbl/src/lscript.ld` before build (and `chmod`s it
writable). FSBL now links to OCM (entry `0x0`) and runs + loads the PL.

## Root cause 3 — BSP STDOUT unmapped

Even once the FSBL ran, `xil_printf` / `fsbl_printf` were silent no-ops: the
standalone BSP had no STDOUT peripheral assigned, so `STDOUT_BASEADDRESS` was
undefined and every print compiled to nothing.

**Fix:** `create_platform.py` calls `domain.set_config("os",
"standalone_stdout", "ps7_uart_1")` (+ stdin) before `platform.build()`. The def
lands in `xparameters_ps.h` as `STDOUT_BASEADDRESS 0xe0001000`; prints reach the
serial console.

## Resolution (2026-05-29)

With all three fixed, the full chain works on hardware, observed over serial
(115200 8N1): FSBL banner → `ps7_init` OK → SD boot → bitstream loaded
(`FPGA Done`) → `SUCCESSFUL_HANDOFF` to the app → `[app] RAW UART1 alive` +
`fpga-xt boot OK` + tick loop + PS_USER_LED1 blink. Cold-boot reliable.

## Notes / red herrings ruled out

- **Always POWER-CYCLE, never the reset button** — on this board the reset button
  does not cleanly re-run the BootROM/SD load. Several "still silent" tests of an
  already-correct build were just reset-not-power-cycle.
- **DDR config diff vs MyIR was benign.** On-board DDR3 is actually Nanya
  NT5CC256M16ER-EK (schematic also lists Micron MT41K256M16); MyIR configures
  both as JEDEC-alternate MT41J. The app loads and runs from DDR fine.
- **Board power was never the issue** — an external 3 A PSU made no difference.
- This was a V1-era reference design (≈10 years old); the V2 board needed the
  current MyIR PS config, which the preset now captures.
