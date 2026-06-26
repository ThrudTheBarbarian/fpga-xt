# Auxiliary audio & expansion reservations

Reference record of completed and reserved hardware items in the auxiliary-audio /
expansion area: the PCM1808 audio-in ADC (HDL complete), expansion-trace pin
reservations, and the second-POKEY serial path.

> **Open / forward-looking work** (RS-232 via 2nd POKEY, COVOX DMA sample playback,
> analog-fidelity DSP, clock-domain-separated AXI, and the FPGA SCKI for the PCM1808)
> is tracked in [NextSteps.md](../NextSteps.md) — see "Audio (PCM1808 capture + HDMI audio)".

## Expansion-trace reservations

Two HDL items have landed:
- `phi2_o` in commit `2d07117` (M-PBI-adjacent)
- PCM1808 integration in commit `6de29c3` (M-aux-audio)

The remaining item is **second POKEY serial port** — peri-RP-side
PCB reservation only, no FPGA HDL change. See below.

### Cart/PBI AUDIO_IN — PCM1808 stereo ADC ✓ (HDL complete)

**HDL complete** (commit `6de29c3`): `hdl/pcm1808_rx.sv` drives
BCK/LRCK and samples SDATA; `hdl/pokey_i2s_tx.sv` extended with
`adc_l_in` / `adc_r_in` mix inputs + soft saturation. `antic_top`
exposes new top-level pads `adc_bclk_o`, `adc_lrck_o`,
`adc_sdata_i`. Synth: clk_bus 164.9 MHz / +0.105 ns slack;
47/47 sims pass.

**Design** (TI PCM1808, 24-bit stereo I²S ADC, ~$2 Q10): two
analog mono inputs, both summed into both L and R of the final
stereo output:

- **PCM1808 Lin**  ← SIO AUDIO_IN (from the SIO connector pin —
  same line POKEY's cassette FSK reads from; allows software-FFT
  or future cassette playback)
- **PCM1808 Rin**  ← PBI AUDIO_IN (cart-edge AUDIO_IN signal,
  fanned out to both PBI and cart-slot connectors)

Both inputs are mono signals from physically separate sources;
neither is panned. The audio-mix HDL sums each ADC channel into
**both** sides of the final stereo output:

    out_L = sum(POKEY_L_channels) + adc_l + adc_r
    out_R = sum(POKEY_R_channels) + adc_l + adc_r

#### Board

- 1× PCM1808 in slave mode (BCLK + LRCK driven by FPGA, DOUT to
  FPGA). +$2 BOM.
- DC-blocking caps on each input (typically 1 µF X7R).
- 3.3 V VCC for the PCM1808 digital side, +5 V analog if VCCA is
  separate (check datasheet — most pin-strap configurations run
  on a single 3.3 V supply).
- Trace from SIO connector AUDIO_IN pin to PCM1808 Lin.
- Trace from PBI connector AUDIO_IN pin (fanned to cart-edge
  AUDIO_IN too) to PCM1808 Rin.

#### FPGA pads (new external I²S RX bus)

3 new FPGA outputs/inputs (the existing pokey_i2s_tx is internal-
only — its I²S is just a naming convention for the protocol
shape, no external pins):

| FPGA pin | Dir | Connects to |
|----------|-----|-------------|
| `adc_bclk_o`  | out | PCM1808 BCK (3.072 MHz at 48 kHz sample rate × 64) |
| `adc_lrck_o`  | out | PCM1808 LRCK (48 kHz) |
| `adc_sdata_i` | in  | PCM1808 DOUT (serial PCM, 24-bit per channel L-first) |

Slow-rate pins; can go on any HSIO or HVIO bank.

#### HDL (M-aux-audio milestone, future)

- New `pcm1808_rx.sv` module: BCLK/LRCK generator (off the
  existing 48 kHz tick in pokey_i2s_tx), I²S RX state machine,
  registers L/R 24-bit samples into clk_bus domain.
- Extend `pokey_i2s_tx.sv`: add `adc_l_in[23:0]` and
  `adc_r_in[23:0]` ports; sum both into both `lpcm_l` and
  `lpcm_r` before driving hdmi_pkt_source.
- Probable resource cost: ~80 FF (24-bit L/R sample regs + small
  state machine + BCLK counter), ~80-120 LUTs (RX shift register
  + 2 × 25-bit summing adders), 0 BRAM. fMax impact negligible
  (audio-rate clocked logic, well below critical path).

#### Saturation strategy: soft clamp

`pokey_i2s_tx` maps the POKEY channel-sum (0..60) into 24-bit
LPCM by left-shifting. Adding two 24-bit signed ADC inputs can
overflow the sum at peak amplitude.

**Locked: soft saturation** (clamp to ±max on overflow), not
pre-attenuation of the ADC channels. Reasoning:

- The cart and PBI AUDIO_IN paths are **rarely active**. Most
  carts don't drive AUDIO_IN at all; PBI devices that emit audio
  are even rarer. The case "both active simultaneously and both
  loud" is essentially never in practice.
- Pre-attenuating the ADC channels (right-shift by 1-2 bits)
  would silently throw away dynamic range on the *common* case
  where only one of the ADC channels is active (or neither), to
  protect a corner case that doesn't happen.
- Soft saturation matches real-Atari analog-stage behaviour
  (POKEY's analog DAC saturates — see "Analog audio fidelity
  (Altirra Appendix E)" above). The "Atari sound" already
  includes mild saturation at high mix levels.

Implementation: after the 4-input sum (POKEY_L + adc_l + adc_r
on the L side, and the matching sum on the R side), clamp to
the 24-bit signed range. A 26-bit intermediate sum + a clamp on
the top bits is enough — synth costs +2 LUTs per output side over
straight-add behaviour.

### Second POKEY serial port — peri-RP path

The second POKEY (`u_pokey_r` at $D21x) is byte-level in HDL —
identical interface to the first POKEY. The first POKEY's SIO is
bit-serialised on the **peri-RP firmware side** via peri_link
byte transfers. The second POKEY's RS-232 should follow the same
pattern.

PCB reservations:
- **2 peri-RP pads** routed to a future RS-232 connector
  (TXD + RXD). Peri-RP has 9 spare GPIOs.
- **MAX232 / SP3232 footprint** for level translation between
  peri-RP's 3.3 V and DB9's ±12 V. Or a 3.3 V pin header
  (USB-serial-adapter-compatible).

HDL/firmware work (M-serial milestone, future):
- Extend `peri_bridge.sv` with a second serial channel (pokey_r
  bytes carried over peri_link).
- Peri-RP firmware: software UART (PIO or bit-banged) that
  serialises pokey_r byte payloads to RS-232 frames and reverse.

No FPGA-pad change today.


