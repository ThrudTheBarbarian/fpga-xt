# rp/video/sim/Makefile — host-side C model paired with sim/tb_rp_bus.sv.
#
# Compiles tb_bus_pio.c with the host toolchain (NOT arm-none-eabi)
# so it can run during regression tests without a Pico board.
#
# Usage:
#   make           build + run the C-side test
#   make verify    cross-check BUS_TAG_* values between bus_server.h
#                  and ../../../hdl/bus_opcodes.vh — fails loudly if they drift
#   make clean

CC      := cc
CFLAGS  := -O2 -Wall -Wextra -Wno-unused-parameter -std=c11

SRC_C   := tb_bus_pio.c ../src/draw.c
BUILD   := build
BIN     := $(BUILD)/tb_bus_pio

OPCODES_H  := ../src/bus_server.h
OPCODES_VH := ../../../hdl/bus_opcodes.vh

.PHONY: all run verify clean

all: run

run: $(BIN) verify
	@echo "=== M3 bus_pio (host C model) ==="
	@./$(BIN) || (echo "FAIL: tb_bus_pio non-zero exit"; exit 1)
	@echo "PASS: tb_bus_pio"

# Cross-check that the C and Verilog opcode tables agree on every
# BUS_TAG_* and BUS_DRAW_OP_* value. C side is plain decimal; SV side
# is plain decimal for tags and `8'dN` for draw ops. The awk strips
# any leading `<width>'d` width-prefix so both forms reduce to the
# same integer.
verify: $(OPCODES_H) $(OPCODES_VH) | $(BUILD)
	@echo "=== verifying opcode tables ==="
	@grep -E '^#define[[:space:]]+(BUS_TAG_|BUS_DRAW_OP_)[A-Z]+[[:space:]]+[0-9]+' $(OPCODES_H) \
	    | awk '{printf "%s=%d\n", $$2, $$3+0}' | sort > $(BUILD)/opcodes.h.txt
	@grep -E "^\`define[[:space:]]+(BUS_TAG_|BUS_DRAW_OP_)[A-Z]+[[:space:]]+([0-9]+|[0-9]+'d[0-9]+)" $(OPCODES_VH) \
	    | awk '{n=$$3; sub(/^[0-9]+.d/, "", n); printf "%s=%d\n", $$2, n+0}' | sort > $(BUILD)/opcodes.vh.txt
	@diff $(BUILD)/opcodes.h.txt $(BUILD)/opcodes.vh.txt > /dev/null || \
	    (echo "FAIL: opcode values differ between $(OPCODES_H) and $(OPCODES_VH)"; \
	     diff $(BUILD)/opcodes.h.txt $(BUILD)/opcodes.vh.txt; exit 1)
	@echo "verify: OK"

$(BIN): $(SRC_C) $(OPCODES_H) | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(SRC_C)

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
