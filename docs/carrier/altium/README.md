# Altium library — fpga-xt motherboard

I can't drive Altium remotely, so this folder delivers a **runnable
DelphiScript** that builds the symbols inside your Altium.

## Run
1. Altium → **File ▸ New ▸ Library ▸ Schematic Library** (blank `.SchLib`).
2. Keep that SchLib the active window.
3. **DXP/Tools ▸ Run Script…** → open `build_fpga_xt_lib.pas` → run **`GenLib`**.
4. Save the `.SchLib`.

Generates symbols: `CON80_ZTURN`, `ATARI_CART_30`, `ATARI_PBI_50`,
`ATARI_SIO_13`, `ATARI_JOY_DE9`, `SN74CB3T16210`, `SN74CB3T3245`,
`RP2354B`, `PCM1808`, `USB_HUB_1x4`.

## Accuracy
- **Connectors** — pin numbers are the real connector positions; pin names
  carry the 800XL-strict signals from `../03-schematic-sheets.md`. Ready to use.
- **ICs** — **functional** symbols; the placeholder pin **numbers** (1..N in
  listed order) must be reconciled with each datasheet/package before you
  attach footprints. Each such symbol says so in its description.

## Footprints (not in this script)
Footprint sources per part:
- **CN1/CN2** → Harwin **M55-7008042R** vendor footprint (SnapEDA/Harwin).
- **J_CART** → standard **2×15 0.1″ pin header** (B2B) — stock/IPC.
- **J_PBI** → **custom PCB edge fingers** (2×25, 0.1″, board edge) — the one
  genuinely custom land pattern; needs finger width/length + bevel + plating.
- **J_SIO** → SIO receptacle (13× **AT60-202-2031** contact pins); PCB side =
  13 THT pads, pad positions from the `atari-sio-breakout/` v2.2 Gerbers.
- DE-9, USB-A/C → stock Altium libs.
- ICs (RP2354B QFN-80, CB3T, PCM1808, CH334F) → IPC-7351 wizard / vendor.

Only the **PBI edge fingers** (and SIO if no vendor footprint) really need a
custom PcbLib. Say the word and I'll add `build_fpga_xt_pcblib.pas` for the
PBI 2×25 0.1″ edge-finger pattern.

## Notes
- DelphiScript API (`SchServer`, `ISch_*`) — tested pattern, but the
  `ISch_Pin.Electrical` enum/`MilsToCoord` exist across recent Altium; if your
  version rejects a token, it'll be a one-line type tweak.
- Re-running `GenLib` adds duplicates — start from a fresh SchLib or delete
  prior parts first.
