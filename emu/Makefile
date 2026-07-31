# emu/Makefile — host build of the software 6502/ANTIC.
#
# Part of the software-emulation investigation
# (docs/Design/software-emulation-investigation.md).  Builds natively for the
# dev machine; the same sources are meant to cross-compile for the A9 later,
# so nothing here may depend on the host being 64-bit or little-endian.
#
#   make            build the gates
#   make harte      Tom Harte, all 256 opcodes, exact bus traces
#   make klaus      Klaus Dormann functional test
#   make test       both — THE gate before ANTIC work counts as progress
#   make clean

BUILD := build
CC    := cc
WARN  := -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion
CFLAGS := -std=c11 $(WARN) -O2 -g

CORE := xt6502.c

.PHONY: all test harte klaus clean
all: $(BUILD)/harte $(BUILD)/klaus

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/harte: test/harte.c $(CORE) xt6502.h | $(BUILD)
	$(CC) $(CFLAGS) test/harte.c $(CORE) -o $@

$(BUILD)/klaus: test/klaus.c $(CORE) xt6502.h | $(BUILD)
	$(CC) $(CFLAGS) test/klaus.c $(CORE) -o $@

harte: $(BUILD)/harte
	@./$(BUILD)/harte

klaus: $(BUILD)/klaus
	@./$(BUILD)/klaus

test: harte klaus

clean:
	rm -rf $(BUILD)
