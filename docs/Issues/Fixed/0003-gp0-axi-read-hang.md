# Issue #0003 — GP0 AXI read hangs the CPU (bridge does not reflect the AXI3 transaction ID)

- **Component:** PS↔PL AXI — `fpga_xt_top` GP0 master-port wiring (ID reflection)
- **Severity:** High (PS↔PL GP0 unusable; every read freezes the issuing A9)
- **Status:** Fixed (2026-05-30 — confirmed on hardware: the GP0 probe returns
  `STATUS = 0x00` and the tick loop continues past 5; see Resolution)
- **Found:** 2026-05-29 (on-hardware, after [[0002]] got the board booting)
- **Files:** `hdl/fpga_xt_top.sv` (GP0 ID reflection, ~line 1409; `m_axi_gp0_arid`
  / `m_axi_gp0_awid` connections)
- **Probe:** `vitis/xtos/src/main.c` tick-5 `xt_blitter_status()` read of
  `axi_blitter_bridge` @ `0x43C00000` over PS M_AXI_GP0

---

## Summary

`xtos` runs fully (tick loop + PS_USER_LED1 blink), but the first read of the
blitter bridge over PS M_AXI_GP0 hangs the CPU forever — no AXI RVALID, and PS GP0
reads have no timeout. The hang is **deterministic**: every read, every boot (cold
and warm), independent of clocking.

## Root cause — the bridge never reflects the AXI3 ID

The PS `M_AXI_GP0` is a full **AXI3** master: it tags every read with an `ARID` and
every write with an `AWID`, and it will not retire the transaction until it receives
a response carrying the **matching** `RID` / `BID`. The on-PL slaves (`axi_blitter_bridge`
and `sally_rom_loader`) are **AXI-Lite** (no ID ports), and there is **no AXI
interconnect / protocol converter** between them and the PS to store-and-reflect the
ID for us. The wrapper hard-tied the response IDs to zero:

```systemverilog
assign gp0_bid = 12'd0;   // fpga_xt_top.sv (old)
assign gp0_rid = 12'd0;
// ... and m_axi_gp0_arid(), m_axi_gp0_awid()  -- the inbound IDs were dropped
```

The A9 issues GP0 reads with a **non-zero** `ARID`. With `RID` stuck at 0 the ID
never matches, the PS's outstanding-read tracker never completes, and the load
instruction hangs the core. This is the textbook failure of bolting an AXI-Lite
slave straight onto a full-AXI master with no ID handling.

## Fix (under test)

Capture the inbound IDs in the wrapper and echo them on the response channels
(`hdl/fpga_xt_top.sv`):

```systemverilog
wire [11:0] gp0_arid, gp0_awid;          // now connected to the PS master
reg  [11:0] gp0_arid_q, gp0_awid_q;
always_ff @(posedge clk_sys) begin
    if (gp0_arvalid) gp0_arid_q <= gp0_arid;   // master holds AxID while AxVALID,
    if (gp0_awvalid) gp0_awid_q <= gp0_awid;   // so this lines up with R/B VALID
end
assign gp0_rid = gp0_arid_q;
assign gp0_bid = gp0_awid_q;
```

One transaction in flight per channel, so a one-deep capture suffices. The
`m_axi_gp0_arid` / `m_axi_gp0_awid` ports (previously `()`) are now wired to
`gp0_arid` / `gp0_awid`.

**Verification:** the tick-5 probe prints `>> GP0 OK: blitter STATUS = 0x00` and the
tick loop continues past 5.

## Ruled out — the earlier reset theory (was the title of this issue)

Originally diagnosed as MMCM2 (clk_pix, fractional) losing lock and, via the shared
`rst_release_n = mmcm1_locked & mmcm2_locked`, resetting the clk_sys GP0 bridge
mid-transaction. The per-domain reset split (`rst_sys`/`rst_sally` ← `mmcm1` only,
`rst_pix` ← `mmcm2` only) was built and flashed (2026-05-30) — **the hang was
completely unchanged**, disproving that theory. The deterministic, every-read nature
of the hang (not intermittent) also points at structure, not timing.

The reset split is **kept anyway**: it is independently correct (the HDMI pixel
clock's stability should not be able to reset the CPU/AXI domain) and harmless. It
is simply not what fixed this issue.

Also ruled out earlier: `rst_n`/R19 floating; `axi_blitter_bridge` read FSM + address
decode (correct); board power. `s_axi_gp0_aclk = clk_sys` is correctly driven, and
`0x43C00000` is inside the PS's fixed GP0 range so the transaction does reach the
fabric — it just never gets an ID-matched response.

## Note — the HP ports are NOT affected

The S_AXI_HP0/1/3 ports tie `m_axi_hpN_arid/awid/wid` to a constant and leave
`rid`/`bid` floating — that is **correct**, because there the PL is the *master*: a
master may use a fixed ID (AXI returns same-ID responses in order) and may ignore the
slave's response ID. ID reflection is only required on the side that is the *slave*
(GP0), which is exactly where it was missing.

## Resolution (2026-05-30)

The ARID→RID / AWID→BID reflection (`hdl/fpga_xt_top.sv`) fixed it on hardware.
Flashed the near-clean bitstream (overall WNS −0.005 ns; `clk_sys` and the PL→PS
AXI path both MET) and the serial console showed:

```
tick 4
>> GP0 probe: reading blitter STATUS @0x43c00000 ...
>> GP0 OK: blitter STATUS = 0x00
tick 5
tick 6 ...
```

The read returns and the loop continues — PS↔PL GP0 AXI is functional. This
confirms the root cause was the missing ID reflection (not the earlier reset or
R19 theories, both of which were built/flashed and changed nothing).

## Remaining cleanup (not blocking)

- Revert the dbg LEDs (`{clk_sys hb, pll_lock, clk_50 hb}`) back to the plain
  heartbeat in `fpga_xt_top.sv` once the rest of bring-up no longer needs the
  clk_sys/PLL health indicators (costs a bitstream rebuild — defer until other
  bring-up that needs a build).
- MMCM2/clk_pix still drops lock intermittently (the HDMI clock); now decoupled
  from the CPU/AXI domain so it is no longer fatal, but worth fixing before HDMI
  is exercised.
