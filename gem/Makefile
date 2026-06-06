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
# FreeType powers the scalable text (font.c); -lm for the GDP trig (gdp.c).
FT_CFLAGS := $(shell pkg-config --cflags freetype2)
FT_LIBS   := $(shell pkg-config --libs freetype2) -lm

# -I. so the per-call VDI files resolve "vdi/vdi.h", "vdi/internal.h", etc.
CFLAGS  := $(CSTD) $(WARN) -O2 -g -I. $(FT_CFLAGS) $(shell pkg-config --cflags sdl2 2>/dev/null || sdl2-config --cflags)
LDLIBS  := $(FT_LIBS) $(shell pkg-config --libs sdl2 2>/dev/null || sdl2-config --libs)

# Portable core + host backend.  The VDI is one file per call under vdi/.
# (GEM AES sources get added here as they land.)
VDI_SRC  := $(wildcard vdi/*.c)
AES_SRC  := $(wildcard aes/*.c)
CORE_SRC := gfx_soft.c font.c $(VDI_SRC) wm.c theme.c $(AES_SRC)
HOST_SRC := sdl_main.c
SRC      := $(CORE_SRC) $(HOST_SRC)
OBJ      := $(addprefix $(BUILD)/,$(SRC:.c=.o))

TARGET  := $(BUILD)/gem_sdl

.PHONY: all run test clean fills shapes output text lines theme themewin themepack aes aesmenu aeswin desktop
all: $(TARGET)

$(TARGET): $(OBJ)
	$(CC) $(OBJ) $(LDLIBS) -o $@

# Standalone examples: fill attributes, and the curved GDPs + line styles.
FILLS_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o fills_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_fills: $(FILLS_OBJ)
	$(CC) $(FILLS_OBJ) $(LDLIBS) -o $@
fills: $(BUILD)/gem_fills
	./$(BUILD)/gem_fills

SHAPES_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o shapes_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_shapes: $(SHAPES_OBJ)
	$(CC) $(SHAPES_OBJ) $(LDLIBS) -o $@
shapes: $(BUILD)/gem_shapes
	./$(BUILD)/gem_shapes

OUTPUT_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o output_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_output: $(OUTPUT_OBJ)
	$(CC) $(OUTPUT_OBJ) $(LDLIBS) -o $@
output: $(BUILD)/gem_output
	./$(BUILD)/gem_output

TEXT_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o text_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_textdemo: $(TEXT_OBJ)
	$(CC) $(TEXT_OBJ) $(LDLIBS) -o $@
text: $(BUILD)/gem_textdemo
	./$(BUILD)/gem_textdemo

LINES_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o lines_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_lines: $(LINES_OBJ)
	$(CC) $(LINES_OBJ) $(LDLIBS) -o $@
lines: $(BUILD)/gem_lines
	./$(BUILD)/gem_lines

THEME_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o theme_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_theme: $(THEME_OBJ)
	$(CC) $(THEME_OBJ) $(LDLIBS) -o $@
theme: $(BUILD)/gem_theme
	./$(BUILD)/gem_theme

TWIN_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o theme_window_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_themewin: $(TWIN_OBJ)
	$(CC) $(TWIN_OBJ) $(LDLIBS) -o $@
themewin: $(BUILD)/gem_themewin
	./$(BUILD)/gem_themewin

AES_DEMO_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o))
$(BUILD)/gem_aes: $(AES_DEMO_OBJ)
	$(CC) $(AES_DEMO_OBJ) $(LDLIBS) -o $@
aes: $(BUILD)/gem_aes
	./$(BUILD)/gem_aes

AESMENU_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_menu_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o))
$(BUILD)/gem_aesmenu: $(AESMENU_OBJ)
	$(CC) $(AESMENU_OBJ) $(LDLIBS) -o $@
aesmenu: $(BUILD)/gem_aesmenu
	./$(BUILD)/gem_aesmenu

AESWIN_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_window_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o))
$(BUILD)/gem_aeswin: $(AESWIN_OBJ)
	$(CC) $(AESWIN_OBJ) $(LDLIBS) -o $@
aeswin: $(BUILD)/gem_aeswin
	./$(BUILD)/gem_aeswin

# The combined interactive desktop: menu bar + draggable windows + a dialog.
DESK_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_desktop_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o))
$(BUILD)/gem_desktop: $(DESK_OBJ)
	$(CC) $(DESK_OBJ) $(LDLIBS) -o $@
desktop: $(BUILD)/gem_desktop
	./$(BUILD)/gem_desktop

# Bake the Aristo2 atlas (needs ImageMagick + the Cappuccino resources).
ARISTO2 ?= $(HOME)/src/cappuccino/cappuccino/AppKit/Themes/Aristo2/Resources
$(BUILD)/themepack: tools/themepack.c | $(BUILD)
	$(CC) $(CSTD) -O2 -o $@ $<
themepack: $(BUILD)/themepack
	mkdir -p themes/Aristo2/1x
	./$(BUILD)/themepack "$(ARISTO2)" themes/aristo2.recipe themes/Aristo2/1x

# Headless self-tests (no SDL): VDI primitives, then the WM interaction layer.
TEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o vdi_test.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_test: $(TEST_OBJ)
	$(CC) $(TEST_OBJ) $(FT_LIBS) -o $@

WMTEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o wm.o wm_test.o $(VDI_SRC:.c=.o))
$(BUILD)/wm_test: $(WMTEST_OBJ)
	$(CC) $(WMTEST_OBJ) $(FT_LIBS) -o $@

test: $(BUILD)/gem_test $(BUILD)/wm_test
	./$(BUILD)/gem_test
	./$(BUILD)/wm_test

$(BUILD)/%.o: %.c | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

# Header-dependency tracking (-MMD): a header edit (e.g. a struct in
# internal.h) rebuilds every TU that includes it, so incremental builds can't
# silently mix two layouts of the same struct.
-include $(shell find $(BUILD) -name '*.d' 2>/dev/null)

$(BUILD):
	mkdir -p $(BUILD)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -rf $(BUILD)
