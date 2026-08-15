# zturn_board.xdc — Z-Turn Z7-Lite board pin constraints for fpga_xt_top.
#
# PACKAGE_PIN and IOSTANDARD assignments extracted from the MYiR system.xdc
# board-support package (MYiR Z-Turn Z7-Lite, xc7z020clg400-2).
#
# LCD_DATA[15:0] → SiI9022A RGB565 on the baseboard HDMI connector.
# IO_B34_LP11    → 50 MHz on-board oscillator.
# LEDS[2:0]      → user LEDs (debug outputs).
# SW[0]          → user push-button (active-low reset).
#
# UART (uart_tx/rx) is MIO-based on Z-Turn (USB-UART bridge via PS).
# Left unassigned in the PL-only build; the PS block will provide them.
#
# Reference:
#   MYiR Z-Turn Z7-Lite schematic — Sheet 3 (LCD/HDMI), Sheet 4 (GPIO).

# ---- 50 MHz reference oscillator (on-board, Bank 34) -----------------------
set_property PACKAGE_PIN U14      [get_ports clk_50]
set_property IOSTANDARD  LVCMOS33 [get_ports clk_50]

# ---- RGB565 to SiI9022A (16-bit parallel, Bank 35 / dedicated GPIO) --------
# LCD_DATA[15:11] -> rgb_r[4:0]  (5 bits red)
# LCD_DATA[10:5]  -> rgb_g[5:0]  (6 bits green)
# LCD_DATA[4:0]   -> rgb_b[4:0]  (5 bits blue)
set_property PACKAGE_PIN Y19 [get_ports {rgb_r[4]}]
set_property PACKAGE_PIN Y18 [get_ports {rgb_r[3]}]
set_property PACKAGE_PIN W20 [get_ports {rgb_r[2]}]
set_property PACKAGE_PIN V20 [get_ports {rgb_r[1]}]
set_property PACKAGE_PIN U20 [get_ports {rgb_r[0]}]

set_property PACKAGE_PIN T20 [get_ports {rgb_g[5]}]
set_property PACKAGE_PIN P20 [get_ports {rgb_g[4]}]
set_property PACKAGE_PIN N20 [get_ports {rgb_g[3]}]
set_property PACKAGE_PIN P19 [get_ports {rgb_g[2]}]
set_property PACKAGE_PIN N18 [get_ports {rgb_g[1]}]
set_property PACKAGE_PIN U19 [get_ports {rgb_g[0]}]

set_property PACKAGE_PIN U18 [get_ports {rgb_b[4]}]
set_property PACKAGE_PIN W15 [get_ports {rgb_b[3]}]
set_property PACKAGE_PIN V15 [get_ports {rgb_b[2]}]
set_property PACKAGE_PIN U17 [get_ports {rgb_b[1]}]
set_property PACKAGE_PIN T16 [get_ports {rgb_b[0]}]

# HDMI control (LCD_HSYNC, LCD_VSYNC, LCD_DE, LCD_PCLK)
set_property PACKAGE_PIN W16 [get_ports rgb_hsync]
set_property PACKAGE_PIN V16 [get_ports rgb_vsync]
set_property PACKAGE_PIN R16 [get_ports rgb_de]
set_property PACKAGE_PIN R17 [get_ports rgb_pixclk]

set_property IOSTANDARD LVCMOS33 [get_ports {rgb_r[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgb_g[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgb_b[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports rgb_hsync]
set_property IOSTANDARD LVCMOS33 [get_ports rgb_vsync]
set_property IOSTANDARD LVCMOS33 [get_ports rgb_de]
set_property IOSTANDARD LVCMOS33 [get_ports rgb_pixclk]

# Pack the final RGB/sync/DE output FFs into the IOBs so they launch cleanly
# and aligned with the ODDR-forwarded pixel clock (clean setup/hold at the
# SiI9022 input).  (rgb_pixclk is driven by an ODDR already in the IOB.)
set_property IOB TRUE [get_ports {rgb_r[*]}]
set_property IOB TRUE [get_ports {rgb_g[*]}]
set_property IOB TRUE [get_ports {rgb_b[*]}]
set_property IOB TRUE [get_ports rgb_hsync]
set_property IOB TRUE [get_ports rgb_vsync]
set_property IOB TRUE [get_ports rgb_de]

# ---- I2S audio to the SiI9022A (Bank 34) -----------------------------------
# Schematic sheet 3 (SOM bank 34) -> sheet 10 (SiI9022A), each through a 0R link:
#   I2S_SCLK      R107 -> SiI9022A pin 45 SCK
#   I2S_FSYNC_OUT R109 -> SiI9022A pin 44 WS
#   I2S_Dout      R108 -> SiI9022A pin 41 SD0
# The net names are the PS's convention; on this board they land on PL pins, so
# the fabric drives them.  MCLK is not driven (the part runs MCLK-less) and
# SD1..SD3 / SPDIF are unused.
set_property PACKAGE_PIN T17 [get_ports hdmi_i2s_sck]
set_property PACKAGE_PIN R18 [get_ports hdmi_i2s_ws]
set_property PACKAGE_PIN V17 [get_ports hdmi_i2s_sd]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_i2s_sck]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_i2s_ws]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_i2s_sd]
# 3.072 MHz on a 3.3 V CMOS input a few centimetres away — slow slew keeps the
# edges clean and stays inside the bank's shared supply budget.
set_property SLEW SLOW [get_ports hdmi_i2s_sck]
set_property SLEW SLOW [get_ports hdmi_i2s_ws]
set_property SLEW SLOW [get_ports hdmi_i2s_sd]

# ---- User push-button as reset (SW[0] on baseboard, active-low) ------------
set_property PACKAGE_PIN R19     [get_ports rst_n]
set_property IOSTANDARD  LVCMOS33 [get_ports rst_n]

# ---- SiI9022A control I2C — driven by PS I2C0 (EMIO) via IOBUFs ------------
# DCC_SCL → P16, DCC_SDA → P15 (the exact pins MyIR routes EMIO I2C0 to).
# External 4.7 kΩ pull-ups on the baseboard; PULLUP true adds the internal
# weak pull-up too (MyIR does this — belt and braces for open-drain I2C).
set_property PACKAGE_PIN P16 [get_ports hdmi_scl]
set_property PACKAGE_PIN P15 [get_ports hdmi_sda]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_scl]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_sda]
set_property PULLUP true [get_ports hdmi_scl]
set_property PULLUP true [get_ports hdmi_sda]

# ---- Debug LEDs (LEDS[2:0] on baseboard) -----------------------------------
set_property PACKAGE_PIN Y16 [get_ports {dbg[0]}]
set_property PACKAGE_PIN Y17 [get_ports {dbg[1]}]
set_property PACKAGE_PIN R14 [get_ports {dbg[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {dbg[*]}]
