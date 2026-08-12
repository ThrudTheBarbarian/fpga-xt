# motherboard/firmware — STM32F411VET6 I/O companion
#
#   make            build build/xtio.elf (+ .bin, .hex, size report)
#   make flash      erase + program over SWD via the Black Magic Probe
#   make console    attach RTT and drop into a terminal
#   make gdb        interactive gdb, already attached
#   make scan       list what the probe can see
#   make clean
#
# BMP=/dev/cu.usbmodemXXXXXXX1 overrides probe autodetection.

TARGET      := xtio
BUILD       := build

CROSS       := arm-none-eabi-
CC          := $(CROSS)gcc
OBJCOPY     := $(CROSS)objcopy
SIZE        := $(CROSS)size
GDB         := $(CROSS)gdb

SRCS        := $(wildcard src/*.c)
OBJS        := $(patsubst src/%.c,$(BUILD)/%.o,$(SRCS))
DEPS        := $(OBJS:.o=.d)

LDSCRIPT    := ld/stm32f411ve.ld

ARCH        := -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16

CFLAGS      := $(ARCH) -std=c11 -Os -g3 \
               -ffunction-sections -fdata-sections \
               -fno-common -fno-builtin \
               -Wall -Wextra -Wshadow -Wundef -Wdouble-promotion \
               -Wno-unused-parameter \
               -MMD -MP -Isrc

LDFLAGS     := $(ARCH) -T$(LDSCRIPT) -nostdlib -static \
               -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map \
               -Wl,--print-memory-usage
LDLIBS      := -lgcc

# ---------------------------------------------------------------- build ----

all: $(BUILD)/$(TARGET).elf $(BUILD)/$(TARGET).bin $(BUILD)/$(TARGET).hex size

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.c | $(BUILD)
	@echo "  CC    $<"
	@$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/$(TARGET).elf: $(OBJS) $(LDSCRIPT)
	@echo "  LD    $@"
	@$(CC) $(OBJS) $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/%.bin: $(BUILD)/%.elf
	@$(OBJCOPY) -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.elf
	@$(OBJCOPY) -O ihex $< $@

size: $(BUILD)/$(TARGET).elf
	@$(SIZE) $<

clean:
	rm -rf $(BUILD)

# ----------------------------------------------------------- probe glue ----
# The BMP exposes two CDC-ACM ports; the lower-numbered one is the GDB server.

BMP ?= $(shell ls /dev/cu.usbmodem*1 2>/dev/null | head -1)

check-probe:
	@test -n "$(BMP)" || { \
	    echo "no Black Magic Probe found — plug it in, or set BMP=/dev/cu.usbmodemXXXX1"; \
	    exit 1; }

GDBFLAGS := -nx --batch \
            -ex 'set confirm off' \
            -ex 'set pagination off' \
            -ex 'set mem inaccessible-by-default off' \
            -ex 'target extended-remote $(BMP)'

scan: check-probe
	@$(GDB) $(GDBFLAGS) -ex 'monitor version' -ex 'monitor swd_scan'

flash: all check-probe
	@echo "  FLASH $(BUILD)/$(TARGET).elf -> $(BMP)"
	@$(GDB) $(GDBFLAGS) \
	    -ex 'monitor swd_scan' \
	    -ex 'attach 1' \
	    -ex 'load' \
	    -ex 'compare-sections' \
	    -ex 'set $$sp = *(unsigned int *)0x08000000' \
	    -ex 'set $$pc = *(unsigned int *)0x08000004' \
	    -ex 'detach' \
	    $(BUILD)/$(TARGET).elf

# Enable RTT and hand the second CDC port to a terminal.  gdb has to stay
# alive for RTT to be serviced, so this runs it interactively.
console: check-probe
	@../tools/bmp-console.sh $(BMP) $(BUILD)/$(TARGET).elf

gdb: all check-probe
	@$(GDB) -nx \
	    -ex 'set confirm off' \
	    -ex 'set mem inaccessible-by-default off' \
	    -ex 'target extended-remote $(BMP)' \
	    -ex 'monitor swd_scan' \
	    -ex 'attach 1' \
	    $(BUILD)/$(TARGET).elf

.PHONY: all clean size scan flash console gdb check-probe

-include $(DEPS)
