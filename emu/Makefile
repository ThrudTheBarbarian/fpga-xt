# emu/Makefile — host build of the software 6502/ANTIC.
#
# Part of the software-emulation investigation
# (docs/Design/software-emulation-investigation.md).  Builds natively for the
# dev machine; the same sources must cross-compile for the A9, so nothing here
# may depend on the host being 64-bit or little-endian.  That is not a hope —
# `make arm` checks it, and the core builds warning-free for a Cortex-A9.
#
#   make            build the gates
#   make harte      Tom Harte, all 256 opcodes, exact bus traces
#   make klaus      Klaus Dormann functional test
#   make irq        directed interrupt-timing tests (ACID800 cpu_clisei, as C)
#   make pokey      POKEY RANDOM LFSR — the ANTIC timing tests' cycle clock
#   make dma        the ANTIC DMA schedule vs ACID800's own table (50/50)
#   make antic      ANTIC timing core: VCOUNT, WSYNC, NMIST landmarks
#   make gtia       GTIA collisions + registers
#   make sys       whole-machine wiring: who drives the bus, when a latch samples
#   make bench     what a frame COSTS, and what that projects to on one A9
#   make arm       cross-compile the core for the A9, warning-free (needs
#                  arm-none-eabi-gcc; skips itself with a note if absent)
#   make acid       run the real ACID800 .xex suite (work in progress)
#   make test       all of them — THE gate before ANTIC work counts as progress
#   make clean

BUILD := build
CC    := cc
WARN  := -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion
CFLAGS := -std=c11 $(WARN) -O2 -g

CORE := xt6502.c
# every header, listed against every target: a stale binary silently reports the
# PREVIOUS run's score, which reads exactly like a change that did nothing
HDRS := xt6502.h antic.h antic_dma.h gtia.h pokey_rand.h pokey_timer.h pia.h sio.h system.h acid_dmatable.h

.PHONY: all test harte klaus irq pokey ptimer dma antic gtia pia sys acid bench arm clean
all: $(BUILD)/harte $(BUILD)/klaus $(BUILD)/irq $(BUILD)/pokey $(BUILD)/ptimer $(BUILD)/dma $(BUILD)/antic $(BUILD)/gtia $(BUILD)/pia $(BUILD)/sys

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

$(BUILD)/antic: test/antic.c antic.c antic_dma.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) test/antic.c antic.c antic_dma.c -o $@

$(BUILD)/ptimer: test/ptimer.c pokey_timer.c pokey_timer.h | $(BUILD)
	$(CC) $(CFLAGS) test/ptimer.c pokey_timer.c -o $@

$(BUILD)/pia: test/pia.c pia.c pia.h | $(BUILD)
	$(CC) $(CFLAGS) test/pia.c pia.c -o $@

$(BUILD)/gtia: test/gtia.c gtia.c gtia.h | $(BUILD)
	$(CC) $(CFLAGS) test/gtia.c gtia.c -o $@

SYS := system.c xt6502.c antic.c antic_dma.c gtia.c pokey_rand.c pokey_timer.c pia.c sio.c
$(BUILD)/acid: test/acid.c $(SYS) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) test/acid.c $(SYS) -o $@

$(BUILD)/sys: test/sys.c $(SYS) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) test/sys.c $(SYS) -o $@

$(BUILD)/bench: test/bench.c $(SYS) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) test/bench.c $(SYS) -o $@

harte: $(BUILD)/harte
	@./$(BUILD)/harte

klaus: $(BUILD)/klaus
	@./$(BUILD)/klaus

irq: $(BUILD)/irq
	@./$(BUILD)/irq

pokey: $(BUILD)/pokey
	@./$(BUILD)/pokey

ptimer: $(BUILD)/ptimer
	@./$(BUILD)/ptimer

pia: $(BUILD)/pia
	@./$(BUILD)/pia

dma: $(BUILD)/dma
	@./$(BUILD)/dma

antic: $(BUILD)/antic
	@./$(BUILD)/antic

gtia: $(BUILD)/gtia
	@./$(BUILD)/gtia

sys: $(BUILD)/sys
	@./$(BUILD)/sys

bench: $(BUILD)/bench
	@./$(BUILD)/bench

# The A9 cross-build.  The claim in the header was carried a long time without
# anyone testing it; this is the test.  -Wconversion is the one that matters,
# because it catches the width assumptions a 64-bit host hides.
ARMCC    := arm-none-eabi-gcc
ARMFLAGS := -std=c11 -O2 -mcpu=cortex-a9 -Wall -Wextra -Wconversion \
            -Wno-sign-conversion -Werror
arm:
	@command -v $(ARMCC) >/dev/null 2>&1 || \
	  { echo "arm: $(ARMCC) not installed — skipping the A9 cross-build"; exit 0; }; \
	 $(ARMCC) $(ARMFLAGS) -I. -c $(SYS) && \
	 echo "arm: core cross-compiles for Cortex-A9, warning-free ($$($(ARMCC) -dumpversion))"; \
	 rm -f $(notdir $(SYS:.c=.o))

acid: $(BUILD)/acid
	@./$(BUILD)/acid

test: harte klaus irq pokey ptimer dma antic gtia pia sys arm

clean:
	rm -rf $(BUILD)
