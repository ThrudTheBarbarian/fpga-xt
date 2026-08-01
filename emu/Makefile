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
#   make irq        directed interrupt-timing tests (ACID800 cpu_clisei, as C)
#   make pokey      POKEY RANDOM LFSR — the ANTIC timing tests' cycle clock
#   make dma        the ANTIC DMA schedule vs ACID800's own table (50/50)
#   make antic      ANTIC timing core: VCOUNT, WSYNC, NMIST landmarks
#   make gtia       GTIA collisions + registers
#   make test       all of them — THE gate before ANTIC work counts as progress
#   make clean

BUILD := build
CC    := cc
WARN  := -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion
CFLAGS := -std=c11 $(WARN) -O2 -g

CORE := xt6502.c

.PHONY: all test harte klaus irq pokey dma antic gtia clean
all: $(BUILD)/harte $(BUILD)/klaus $(BUILD)/irq $(BUILD)/pokey $(BUILD)/dma $(BUILD)/antic $(BUILD)/gtia

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/harte: test/harte.c $(CORE) xt6502.h | $(BUILD)
	$(CC) $(CFLAGS) test/harte.c $(CORE) -o $@

$(BUILD)/klaus: test/klaus.c $(CORE) xt6502.h | $(BUILD)
	$(CC) $(CFLAGS) test/klaus.c $(CORE) -o $@

$(BUILD)/irq: test/irq.c $(CORE) xt6502.h | $(BUILD)
	$(CC) $(CFLAGS) test/irq.c $(CORE) -o $@

$(BUILD)/pokey: test/pokey.c pokey_rand.c pokey_rand.h | $(BUILD)
	$(CC) $(CFLAGS) test/pokey.c pokey_rand.c -o $@

$(BUILD)/dma: test/dma.c antic_dma.c antic_dma.h acid_dmatable.h | $(BUILD)
	$(CC) $(CFLAGS) test/dma.c antic_dma.c -o $@

$(BUILD)/antic: test/antic.c antic.c antic_dma.c antic.h antic_dma.h | $(BUILD)
	$(CC) $(CFLAGS) test/antic.c antic.c antic_dma.c -o $@

$(BUILD)/gtia: test/gtia.c gtia.c gtia.h | $(BUILD)
	$(CC) $(CFLAGS) test/gtia.c gtia.c -o $@

harte: $(BUILD)/harte
	@./$(BUILD)/harte

klaus: $(BUILD)/klaus
	@./$(BUILD)/klaus

irq: $(BUILD)/irq
	@./$(BUILD)/irq

pokey: $(BUILD)/pokey
	@./$(BUILD)/pokey

dma: $(BUILD)/dma
	@./$(BUILD)/dma

antic: $(BUILD)/antic
	@./$(BUILD)/antic

gtia: $(BUILD)/gtia
	@./$(BUILD)/gtia

test: harte klaus irq pokey dma antic gtia

clean:
	rm -rf $(BUILD)
