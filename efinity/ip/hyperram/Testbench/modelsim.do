
set TB_NAME tb_hbram
set SWITCH_1 SIM
set SWITCH_2 EFX_IPM

#Define vlib
vlib work

#Compile user files
vlog +define+$SWITCH_1+$SWITCH_2 top*v
vlog +define+$SWITCH_1+$SWITCH_2 efx_crc32.v
vlog +define+$SWITCH_1+$SWITCH_2 efx_ed_hyper_ram_axi_tc.v
vlog +define+$SWITCH_1+$SWITCH_2 efx_ed_hyper_ram_native_tc.v
vlog +define+$SWITCH_1+$SWITCH_2 top.v
vlog +define+$SWITCH_1+$SWITCH_2 EFX_GPIO_model.v
vlog +define+$SWITCH_1+$SWITCH_2 efx_lut4.v
vlog +define+$SWITCH_1+$SWITCH_2 clock_gen.v
vlog +define+$SWITCH_1+$SWITCH_2 tb.v
vlog +define+$SWITCH_1+$SWITCH_2 modelsim/hyperram.sv

vlog -sv -sv09compat +define+$SWITCH_1 W958D6NKY.vp

#Load the design.
vsim -t ps +notimingchecks -gui -voptargs="+acc" work.$TB_NAME

#Run simulation
run -all
