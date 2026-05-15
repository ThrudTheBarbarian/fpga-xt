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

# ---- User push-button as reset (SW[0] on baseboard, active-low) ------------
set_property PACKAGE_PIN R19     [get_ports rst_n]
set_property IOSTANDARD  LVCMOS33 [get_ports rst_n]

# ---- SiI9022A I2C configuration bus (HDMI DDC channel) --------------------
# I2C0_SCL → IO_L24N_T3_34 → P16
# I2C0_SDA → IO_L24P_T3_34 → P15
# External 4.7 kΩ pull-ups to 3.3 V on baseboard (Bank 35).
set_property PACKAGE_PIN P16 [get_ports hdmi_scl]
set_property PACKAGE_PIN P15 [get_ports hdmi_sda]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_scl]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_sda]

# ---- Debug LEDs (LEDS[2:0] on baseboard) -----------------------------------
set_property PACKAGE_PIN Y16 [get_ports {dbg[0]}]
set_property PACKAGE_PIN Y17 [get_ports {dbg[1]}]
set_property PACKAGE_PIN R14 [get_ports {dbg[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {dbg[*]}]
