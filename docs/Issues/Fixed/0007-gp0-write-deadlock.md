# Issue #0007 — GP0 AXI writes deadlock the CPU (AW/W handshake coupling)

- **Component:** PS↔PL AXI — `axi_blitter_bridge` write FSM
- **Severity:** High (every PS GP0 *write* freezes the issuing A9)
- **Status:** Fixed (2026-05-31 — confirmed on hardware: `mw`/`bars` over the
  serial REPL return `ok`; the bridge control register and live test-pattern
  toggle work)
- **Found:** 2026-05-31 (first-ever GP0 write on hardware — see Summary)
- **Files:** `hdl/axi_blitter_bridge.sv` (write FSM rewrite)

---

## Summary

GP0 *reads* worked (issue [[0003]] fixed the read-ID reflection), but the first
GP0 *write* ever issued on hardware — `Xil_Out32(0x43C0001C, …)` to the new
test-pattern control register — hung the A9 forever. Reads were fine; writes
froze. Deterministic, every write.

## Root cause — AW/W handshake coupling

The bridge's write FSM only accepted a write when `AWVALID && WVALID` were
asserted **together**:

```systemverilog
if (s_axi_awvalid && s_axi_wvalid && in_window) begin
    s_axi_awready <= 1'b1;  s_axi_wready <= 1'b1; ...   // old: coupled
```

The Zynq PS `M_AXI_GP0` master may assert `AWVALID` and wait for `AWREADY`
*before* it drives `WVALID`. A slave that couples the two then deadlocks: it
waits for `WVALID` that the master won't send until it sees `AWREADY`. **Reads
are immune — single AR channel** — which is exactly why reads worked and the
first write hung.

## Resolution

Rewrote the write FSM to accept **AW and W independently** (`hdl/axi_blitter_bridge.sv`):
capture `AW` when it arrives (if it addresses our `0x00–0x1F` window), capture
`W` only once we own that `AW` (the `W` channel is shared with
`sally_rom_loader`, so the address-matching slave must claim its `W`), then
respond once both halves are in. Offset `0x1C` writes land in a new
software-control register (`gp0_ctrl`, e.g. bit0 = HDMI test-pattern enable),
not the blitter. `sally_rom_loader` has the same coupled pattern but is not yet
exercised — fix it the same way before its first PS write.

## Notes — the half-width-display red herring (NOT an FPGA bug)

Most of this session was spent chasing a "left half = colour bars, right half =
black" HDMI display that turned out to be a **monitor-side stale lock**, not an
FPGA fault. The SiI9022 + PL emitted a correct full-width 1080p60 signal
throughout (confirmed: H_RES=2200/V_RES=1125, clk_pix timing clean +0.425 ns,
chip DE-generator test, and the picture was unchanged by every test-pattern /
DE / compositor edit). The monitor had latched a half-width sub-lock during an
early marginal power-on and **persisted it across source power-cycles**; a full
link re-acquire (switching the monitor's input away and back, or power-cycling
the monitor) cleared it, and it has come up full-width reliably ever since.
Lesson for next time: if "exactly half" or a fixed-fraction display appears,
**re-acquire the monitor link (input-switch / monitor power-cycle) before
touching RTL** — and a stuck monitor lock can survive source power-cycles.
