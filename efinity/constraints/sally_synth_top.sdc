# SDC for the standalone SALLY-stack synth wrapper (M24-7).
#
# Single clock domain — `clk` drives sally_core, sally_clock, sally_mem
# (incl. bank_cache + bank_xlat). Target 120 MHz, matching the
# integrated antic_top.sdc post-2026-05-09 update — pushes the
# optimiser harder on the SALLY-stack critical path before the
# M-cache-rework pillars land.
#
# `rst` is async; exclude from STA.
#
# All other inputs (pad_*) are registered at the entry stage of
# sally_synth_top so STA only measures internal logic; declare a
# generous input delay so PnR doesn't waste effort optimising
# pad → first-flop paths.

create_clock -name clk -period 6.40 [get_ports clk]    ;# 156 MHz target

set_false_path -from [get_ports rst]

# I/O delays — pads are registered both ends. Half-period budgets.
set_input_delay  -clock clk 1.0 [get_ports {pad_data_in pad_irq_n pad_nmi_n
                                            pad_halt_n pad_wsync_rdy_n
                                            pad_phi2_tick pad_clock_mult
                                            pad_hr_rdata pad_hr_done
                                            pad_rom_addr pad_rom_data pad_rom_we}]
set_output_delay -clock clk 1.0 [get_ports {pad_addr pad_data_out pad_rw
                                            pad_busy pad_hr_addr pad_hr_we
                                            pad_hr_wdata pad_hr_req}]
