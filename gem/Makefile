# gem/Makefile — host build of the GEM SDL testbed.
#
# Portable GEM core + the software gfx backend + the SDL harness, compiled for
# the dev machine.  The same core sources will later link against the A9
# hardware-blitter backend instead of gfx_soft.c.
#
#   make            build build/gem_sdl
#   make run        build + run
#   make clean
#
# Needs SDL2:  macOS  -> brew install sdl2
#              Debian -> apt install libsdl2-dev

BUILD   := build
CC      := cc
CSTD    := -std=c11
WARN    := -Wall -Wextra
# -I. so the per-call VDI files resolve "vdi/vdi.h", "vdi/internal.h", etc.
CFLAGS  := $(CSTD) $(WARN) -O2 -g -I. $(shell pkg-config --cflags sdl2 2>/dev/null || sdl2-config --cflags)
LDLIBS  := $(shell pkg-config --libs sdl2 2>/dev/null || sdl2-config --libs)

# Portable core + host backend.  The VDI is one file per call under vdi/.
# (GEM AES sources get added here as they land.)
VDI_SRC  := $(wildcard vdi/*.c)
CORE_SRC := gfx_soft.c $(VDI_SRC) wm.c
HOST_SRC := sdl_main.c
SRC      := $(CORE_SRC) $(HOST_SRC)
OBJ      := $(addprefix $(BUILD)/,$(SRC:.c=.o))

TARGET  := $(BUILD)/gem_sdl

.PHONY: all run test clean
all: $(TARGET)

$(TARGET): $(OBJ)
	$(CC) $(OBJ) $(LDLIBS) -o $@

# Headless self-tests (no SDL): VDI primitives, then the WM interaction layer.
TEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o vdi_test.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_test: $(TEST_OBJ)
	$(CC) $(TEST_OBJ) -o $@

WMTEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o wm.o wm_test.o $(VDI_SRC:.c=.o))
$(BUILD)/wm_test: $(WMTEST_OBJ)
	$(CC) $(WMTEST_OBJ) -o $@

test: $(BUILD)/gem_test $(BUILD)/wm_test
	./$(BUILD)/gem_test
	./$(BUILD)/wm_test

$(BUILD)/%.o: %.c | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -rf $(BUILD)
