# rp/peri/sim/Makefile — host-side sim for the peri-RP register file.
#
# `peri_regs.c` is the C side of the SPI slave loop, decoupled from
# the PIO program. Test the decode behaviour on the host so we don't
# need an RP2354 to validate read/write round-trip and address space
# coverage. The PIO program itself is only exercised on hardware (or
# via the FPGA-side tb_peri_link, which has its own slave mock — see
# ../../../sim/tb_peri_link.sv).

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -std=c11
INCLUDE := -I../src

BUILD   := build

.PHONY: all clean
all: $(BUILD)/tb_peri_regs $(BUILD)/tb_peri_pot $(BUILD)/tb_peri_sio $(BUILD)/tb_peri_sd

$(BUILD):
	@mkdir -p $(BUILD)

PERI_LIB := ../src/peri_regs.c ../src/peri_pot.c ../src/peri_irq.c ../src/peri_sio.c ../src/peri_sd.c

$(BUILD)/tb_peri_regs: tb_peri_regs.c $(PERI_LIB) | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDE) -DPERI_POT_HOST_SIM -o $@ $^
	@echo "=== M25-3a peri_regs ==="
	@$(BUILD)/tb_peri_regs

$(BUILD)/tb_peri_pot: tb_peri_pot.c $(PERI_LIB) | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDE) -DPERI_POT_HOST_SIM -o $@ $^
	@echo "=== M25-3c peri_pot ==="
	@$(BUILD)/tb_peri_pot

$(BUILD)/tb_peri_sio: tb_peri_sio.c $(PERI_LIB) | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDE) -DPERI_POT_HOST_SIM -o $@ $^
	@echo "=== M25-4 peri_sio ==="
	@$(BUILD)/tb_peri_sio

$(BUILD)/tb_peri_sd: tb_peri_sd.c $(PERI_LIB) | $(BUILD)
	$(CC) $(CFLAGS) $(INCLUDE) -DPERI_POT_HOST_SIM -o $@ $^
	@echo "=== M25-5 peri_sd ==="
	@$(BUILD)/tb_peri_sd

clean:
	rm -rf $(BUILD)
