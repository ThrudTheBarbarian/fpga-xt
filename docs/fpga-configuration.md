# FPGA configuration

The Ti60F256-C4 (Titanium) boots from the **peri-RP2354B**. At
power-on the peri-RP pushes the FPGA bitstream over a 4-bit-wide
**passive ×4 (QSPI)** link, then idles the bus once `CDONE` goes
high. The config pins are *not* shared with any runtime traffic —
they're dedicated, used only during the ~30-50 ms boot window.

References:

- AN035 — *SPI Passive Programming with Raspberry Pi*
  ([pdf](https://www.efinixinc.com/docs/an035-spi-passive-programming-with-rpi-v1.2.pdf)) — general SPI passive flow
- AN042 — *Configuring Titanium FPGAs*
  ([pdf](https://www.efinixinc.com/docs/an042-configuring-titanium-fpgas.pdf)) — Titanium-specific modes + pinning (AN061 is the Topaz equivalent)

## Why pull config from peri-RP

The choice between **main-RP** (video framebuffer chip) and
**peri-RP** (POT/SIO/SD chip) for FPGA configuration came down to
pin geometry:

- The main RP runs the rp_tx (27) + rp_rx (17) source-synchronous
  busses at FPGA `clk_bus` rate; sharing those 44 pins with config
  data — the previous plan, using passive parallel ×16 + PIO swap
  — meant the boot-time pin map and runtime pin map had to occupy
  the same physical pins. The HVIO repurpose (rp_rx → HVIO 3.3 V
  direct) made the geometry of CDI[0..15] sharing across HVIO + HSIO
  awkward; the 4-bit config data would have to span both banks,
  which the Efinix Interface Designer rejects.
- The peri-RP has 19 spare GPIOs after POT + SIO + SD + FPGA SPI
  link (29 of 48 used), comfortable budget for 8 dedicated config
  pins (37 of 48 after). No PIO program-swap dance required because
  there's no runtime reuse of these pins.

Other properties unchanged from the previous plan:

- **Single UF2 distribution.** peri-RP firmware (~370 KB after M25
  scaffolding lands) + Ti60F256 bitstream (~1.7 MB) packs into one
  ~2 MB UF2. User flashes the peri-RP and the FPGA comes up with it.
- **No external SPI flash for the FPGA.** Saves a part + footprint.
- **Field-updatable.** Bitstream is just bytes the peri-RP firmware
  knows about — atomic swap with the firmware version that matches it.

## Pin map (peri-RP → FPGA)

8 pins total. 7 are peri-RP outputs (RP → FPGA); 1 is the open-drain
`CDONE` going back the other way:

| peri-RP pin (direction) | FPGA pin (function) | Purpose                                                    |
|-------------------------|--------------------|-------------------------------------------------------------|
| QSPI_D0 (out)           | CDI0               | Configuration data bit 0 (passive ×4)                       |
| QSPI_D1 (out)           | CDI1               | Configuration data bit 1                                    |
| QSPI_D2 (out)           | CDI2               | Configuration data bit 2                                    |
| QSPI_D3 (out)           | CDI3               | Configuration data bit 3                                    |
| QSPI_CLK (out)          | CCK                | Configuration clock                                         |
| QSPI_CS (out)           | SSL_N              | Active-low chip-select for the config block                 |
| RESET (out, open-drain) | CRESET_N           | Hold FPGA in reset                                          |
| CDONE_IN (in)           | CDONE              | Configuration complete — open-drain on FPGA side, pull-up on peri-RP |

## Level translation

The FPGA's config pins are on **HSIO at 1.8 V** (not HVIO). The
peri-RP runs **3.3 V**. So all 8 config wires need translation.

| Direction (count) | Pins | Translator |
|---|---|---|
| peri-RP → FPGA (7) | CDI[0..3] + CCK + SSL_N + CRESET_N | 1 × 74LVC8T245BQ, DIR=A→B (7 of 8 channels used, 1 spare) |
| FPGA → peri-RP (1) | CDONE | 1 × 74LVC8T245BQ, DIR=B→A (1 of 8 channels used, 7 spare) |

The two LVC8T245s can't share — same DIR-pin-in-lockstep
constraint as the peri-RP SPI link and the main-RP rp_tx/rp_rx
busses. Adds ~$1.40 to the translator BOM.

## Mode

**Titanium Passive ×4** (per AN042). The peri-RP drives all 4 CDI
lines simultaneously each clock; the FPGA latches 4 bits per CCK
edge.

- `CPOL` / `CPHA`: per AN042. Verify against the datasheet during
  bring-up (vendor mode-name conventions differ).
- Bitrate: at 25 MHz CCK × 4 bits = 100 Mbps payload. ~134 ms for
  the ~1.7 MB bitstream — comparable to the previous passive ×16
  scheme's 33 ms but with cleaner geometry. Faster CCK rates (up to
  the Titanium datasheet max — likely 50-100 MHz) cut this further
  if needed.

## Boot sequence

```
peri-RP power-on
  → peri-RP firmware sets up clocks, USB CDC
  → assert CRESET_N low for ≥ datasheet minimum (a few µs)
  → load passive-×4 PIO program; configure SM for 4-bit shift,
    CCK on appropriate edge, CS active
  → release CRESET_N
  → assert SSL_N
  → stream ~1.7 MB bitstream from flash through PIO FIFO
  → poll CDONE; on assertion, stop pushing data, de-assert SSL_N
  → CCK idles; config pins go quiet
  → peri-RP firmware switches focus to SPI-slave + POT/SIO/SD
    service (M25 scaffolding)
  → FPGA's first transactions (e.g. peri_link STATUS polls) can fly
```

Note: there is **no PIO program-swap** in this design (unlike the
prior main-RP scheme). The config PIO state machine can stay loaded
but disabled after boot — its GPIOs are unused at runtime, so
nothing competes for them.

## Engineering checks before PCB

Lock these down against the AN042 / datasheet text rather than
trusting the prose here:

1. **Mode-name confirmation.** "Passive ×4" is the Titanium name —
   AN042 may call it "Passive Parallel ×4" or similar. Don't
   conflate with Topaz's mode names from AN061.
2. **Max passive-config clock at 1.8 V HSIO.** Datasheet number.
   25 MHz is conservative; 50-100 MHz is likely available.
3. **CPOL / CPHA.** Cross-check the AN doc — conventions differ
   between vendors and "mode 3" can mean either edge depending on
   how the spec is written.
4. **`CRESET_N` minimum pulse-width.** Datasheet timing.
5. **`CDONE` pull-up value.** Standard 10 kΩ usually fine; AN042
   may spec tighter. Pull-up goes to peri-RP's 3.3 V rail (since
   that's the LVC8T245 B-side supply), not the FPGA's 1.8 V.
6. **Flash budget.** ~1.7 MB bitstream + ~370 KB peri-RP firmware
   ≈ 2 MB. peri-RP production board needs ≥ 4 MB QSPI flash to
   leave room for OTA + scratch + future features.
7. **Reset behaviour.** Hard-resetting the peri-RP (e.g. via USB
   replug) must not glitch CRESET_N in a way that triggers an
   unwanted FPGA re-config. Test that the LVC8T245 OE path holds
   CRESET_N safe during peri-RP boot.

## History

The original plan had the **main RP** handle FPGA config via
**passive parallel ×16**, with the 16 data pins shared with the
runtime rp_rx data bus and a PIO program-swap at CDONE. That plan
was workable in isolation but ran into pin-geometry friction once
the **HVIO repurpose** (commit `02ba8ff`, 2026-05-10) moved
rp_rx onto HVIO direct: the 16-bit CDI[0..15] config data would
have to span both HVIO and HSIO banks, which the Interface
Designer doesn't allow cleanly.

The peri-RP + Passive ×4 plan (this doc, 2026-05-11):
- Frees 4 pins on the main RP (no more boot SPI sharing)
- Uses 8 pins on the peri-RP (37 of 48, 11 spare)
- Adds 2 × LVC8T245 to the translator BOM (+$1.40 — the price of
  not sharing the main-RP's already-translated link)
- Eliminates the PIO program-swap dance
- Doesn't compete with the source-synchronous timing budget of
  rp_tx / rp_rx
