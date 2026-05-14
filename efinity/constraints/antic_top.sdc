# SDC constraints for the fpga-antic Efinity flow.
#
# clk_bus is the bus-domain clock (Atari ~1.79 MHz × CLOCK_MULT). The
# compositor / dl_parser / register file all live in this domain. Target
# is comfortably above the Atari max sustained mult — we want fMax ≥
# 50 MHz so any reasonable CLOCK_MULT (12×–24×) closes timing easily.
# Set to 6 ns (~167 MHz) — tight enough that PnR optimises for it,
# loose enough that we close.
#
# clk_pix is the video-clock domain (25.175 MHz for 640×480, 40 MHz for
# 800×600 line-doubled). Currently all pix_* outputs are tied through
# combinational paths from clk_bus so there's no real CDC; we still
# constrain pix_clk so the synth tool plans for it.
#
# ram_clk is the HyperRAM PHY clock — 200 MHz target (5 ns) per the IP
# config (Memory Operating Frequency = 200 MHz). PnR currently reports
# 195.6 MHz max-possible without an explicit constraint; with the SDC
# applied PnR will work harder to hit the target.
#
# ram_clk_cal is the HyperRAM calibration clock — slow (~25 MHz). The
# IP runs initial calibration off this; period is forgiving.

create_clock -name clk_bus     -period  6.17  [get_ports clk_bus]   ;# 162 MHz target — clears BASE_DIV=90 floor (161.08 MHz)
create_clock -name clk_pix     -period 25.0   [get_ports clk_pix]   ;# 40 MHz (800x600); 25.175 MHz for 640x480 is also fine
create_clock -name clk_bit     -period  5.0   [get_ports clk_bit]   ;# 5 × clk_pix → TMDS bit-clock
create_clock -name ram_clk     -period  5.0   [get_ports ram_clk]
create_clock -name ram_clk_cal -period 40.0   [get_ports ram_clk_cal]
# clk_bus target progression (2026-05-08/09 → 2026-05-09 post-rework):
#   100 → 120 → 144 → 156 → 168 → 156 (M-cache-rework Steps 3-5) →
#   162 MHz (here, post Step 5 — 4-quadrant cache + burst HR).
#
# Achieved fmax history:
#   100 MHz target → 133.6 MHz   (slack +2.52)
#   120            → 149.7       (+1.65)
#   144            → 169.2       (+1.04)
#   156            → 175.6       (+0.71)  baseline (no cache rework)
#   168            → 179.4       (+0.375) baseline / pre-rework only
#   156 / Step 3   → 159.2       (+0.118) partition added critical path
#   156 / Step 4   → 163.9       (+0.297) bypass + registered selectors
#   156 / Step 5   → 165.8       (+0.369) burst HR / FSM simplified
#   162 / Step 5   → tbd                  this run — BASE_DIV=90 viability check
#
# BASE_DIV ladder (clock-mult-range issue):
#   84  needs 150.4 MHz floor — fits with 15.4 MHz margin at Step 5.
#   90  needs 161.1 MHz floor — fits with 4.7 MHz margin at Step 5
#                                (12 clean grades: 1,2,3,5,6,9,10,15,18,30,45,90).
#   96  needs 171.8 MHz floor — out of reach post-rework.
#   100 needs 178.98 MHz floor — out of reach post-rework.
# 162 MHz target locks BASE_DIV=90 in as the new ceiling.

# clk_bus and ram_clk are asynchronous (separate PLL outputs). Disable
# cross-domain timing analysis between them — internal CDCs in the IP
# (resetsync / async FIFOs) handle the safety; STA shouldn't try to
# close paths that don't exist.
set_clock_groups -asynchronous \
    -group {clk_bus} \
    -group {clk_pix clk_bit} \
    -group {ram_clk ram_clk_cal}

# Async reset — exclude from timing.
set_input_delay -clock clk_bus 0 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# ---- M25 peri-RP + PCAL9722 SPI pads ----------------------------------
# Both SPI buses run at ≈5 MHz max (clk_bus / 32 with CLK_DIV=16). The
# masters are fully synchronous to clk_bus; the input pads (MISO, IRQ,
# INT_N) are async from outside the chip and get 2-FF-synchronised
# inside peri_link / joy_link before any logic uses them. False-path
# the inputs so STA doesn't try to close paths that don't exist.
set_false_path -from [get_ports spi_miso]
set_false_path -from [get_ports spi_irq]
set_false_path -from [get_ports joy_spi_miso]
set_false_path -from [get_ports joy_spi_int_n]

# Output pads (CLK / MOSI / /CS) are clk_bus-synchronous launches at
# 5 MHz, with ~200 ns / bit period; even with 30 ns external trace +
# slave Tsu we have >100 ns slack. No explicit output-delay needed
# beyond the default clk_bus relationship. Leaving these as default
# also means a future slow synth pass on a degraded part still closes.
