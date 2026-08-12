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

# TinyUSB — host only, so none of the device stack is listed.
TUSB        := ../third_party/tinyusb/src
TUSB_SRCS   := $(TUSB)/tusb.c \
               $(TUSB)/common/tusb_fifo.c \
               $(TUSB)/host/usbh.c \
               $(TUSB)/host/hub.c \
               $(TUSB)/class/hid/hid_host.c \
               $(TUSB)/portable/synopsys/dwc2/dwc2_common.c \
               $(TUSB)/portable/synopsys/dwc2/hcd_dwc2.c
TUSB_OBJS   := $(patsubst $(TUSB)/%.c,$(BUILD)/tusb/%.o,$(TUSB_SRCS))

OBJS        += $(TUSB_OBJS)
DEPS        := $(OBJS:.o=.d)

LDSCRIPT    := ld/stm32f411ve.ld

ARCH        := -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16

# TinyUSB log verbosity: 0 silent, 1 errors, 2 enumeration detail.
USB_DEBUG   ?= 2

CFLAGS      := $(ARCH) -std=c11 -Os -g3 -DCFG_TUSB_DEBUG=$(USB_DEBUG) \
               -ffunction-sections -fdata-sections \
               -fno-common -fno-builtin \
               -Wall -Wextra -Wshadow -Wundef -Wdouble-promotion \
               -Wno-unused-parameter \
               -MMD -MP -Isrc -Isrc/compat -I$(TUSB)

LDFLAGS     := $(ARCH) -T$(LDSCRIPT) -nostdlib -static \
               -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map \
               -Wl,--print-memory-usage
# -lc is here for exactly one symbol: TinyUSB's log dump calls isprint(), which
# needs newlib's _ctype_ table.  The linker pulls only that object, and it has no
# syscall dependencies, so the build stays freestanding.
LDLIBS      := -lc -lgcc

# ---------------------------------------------------------------- build ----

all: $(BUILD)/$(TARGET).elf $(BUILD)/$(TARGET).bin $(BUILD)/$(TARGET).hex size

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.c | $(BUILD)
	@echo "  CC    $<"
	@$(CC) $(CFLAGS) -c $< -o $@

# Vendored code, built with our flags minus the pedantic warnings we impose on
# our own sources — churn in a submodule should not break our build.
$(BUILD)/tusb/%.o: $(TUSB)/%.c
	@mkdir -p $(dir $@)
	@echo "  CC    tinyusb/$*.c"
	@$(CC) $(CFLAGS) -Wno-extra -Wno-shadow -Wno-undef -Wno-unused-parameter \
	    -Wno-sign-compare -Wno-cast-qual -c $< -o $@

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
