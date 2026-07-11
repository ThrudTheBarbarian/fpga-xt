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
# -lz: the PDF printer device (vdi/printers/pdf_device.c) Flate-compresses streams.
FT_LIBS   := $(shell pkg-config --libs freetype2) -lm -lz

# -I. so the per-call VDI files resolve "vdi/vdi.h", "vdi/internal.h", etc.
# -I../third_party/Rocks/src: the ONE shared .rsc codec (rsc.h/rsc.c) lives in the Rocks
# submodule (third_party/Rocks, the GemRCS/"Rocks" editor).  The codec uses OUR aes.h
# enums instead of its own: -DRSC_NO_STATE_FLAGS skips its OF_/OS_/BOX_ROUND_
# copies, and -DG_BOX=G_BOX (a self-referential macro) satisfies rsc.h's
# `#ifndef G_BOX` type-enum guard so it uses aes.h's G_* (an enum, not a macro).
CFLAGS  := $(CSTD) $(WARN) -O2 -g -I. -I../third_party/Rocks/src -DRSC_NO_STATE_FLAGS -DG_BOX=G_BOX $(FT_CFLAGS) $(shell pkg-config --cflags sdl2 2>/dev/null || sdl2-config --cflags)
LDLIBS  := $(FT_LIBS) $(shell pkg-config --libs sdl2 2>/dev/null || sdl2-config --libs)

# The Rocks resource engine, REFERENCED (not copied) from the third_party/Rocks submodule.  It
# sits outside aes/ (so the aes/*.c wildcard misses it) and is compiled with
# aes.h force-included so its RSC_OBJECT/RSC_TEDINFO and flag/type enums coincide
# with ours (with -DRSC_NO_STATE_FLAGS, above, skipping the codec's own copies).
# aes/rscload.c (the AES bridge) rides in via $(AES_SRC); it needs this object,
# so every target that links $(AES_SRC) links $(RSC_ENGINE_OBJ) too.
RSC_ENGINE     := ../third_party/Rocks/src/rsc.c
RSC_ENGINE_OBJ := $(BUILD)/rsc_engine.o

# Portable core + host backend.  The VDI is one file per call under vdi/, plus
# the output-device drivers under vdi/printers/ (the PDF printer device, etc.).
# (GEM AES sources get added here as they land.)
VDI_SRC  := $(wildcard vdi/*.c) $(wildcard vdi/printers/*.c)
AES_SRC  := $(wildcard aes/*.c)
CORE_SRC := gfx_soft.c font.c $(VDI_SRC) wm.c theme.c $(AES_SRC)
HOST_SRC := sdl_main.c
SRC      := $(CORE_SRC) $(HOST_SRC)
OBJ      := $(addprefix $(BUILD)/,$(SRC:.c=.o))

TARGET  := $(BUILD)/gem_sdl

.PHONY: all run test clean fills shapes output text lines theme themewin themepack aes aesmenu aeswin desktop pdf fontscan catalogtest menu_test mkrsc rsc_test
all: $(TARGET)

$(RSC_ENGINE_OBJ): $(RSC_ENGINE) aes/aes.h | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -include aes/aes.h -MMD -MP -c $< -o $@

$(TARGET): $(OBJ) $(RSC_ENGINE_OBJ)
	$(CC) $(OBJ) $(RSC_ENGINE_OBJ) $(LDLIBS) -o $@

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

AES_DEMO_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o)) $(RSC_ENGINE_OBJ)
$(BUILD)/gem_aes: $(AES_DEMO_OBJ)
	$(CC) $(AES_DEMO_OBJ) $(LDLIBS) -o $@
aes: $(BUILD)/gem_aes
	./$(BUILD)/gem_aes

AESMENU_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_menu_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o)) $(RSC_ENGINE_OBJ)
$(BUILD)/gem_aesmenu: $(AESMENU_OBJ)
	$(CC) $(AESMENU_OBJ) $(LDLIBS) -o $@
aesmenu: $(BUILD)/gem_aesmenu
	./$(BUILD)/gem_aesmenu

AESWIN_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_window_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o)) $(RSC_ENGINE_OBJ)
$(BUILD)/gem_aeswin: $(AESWIN_OBJ)
	$(CC) $(AESWIN_OBJ) $(LDLIBS) -o $@
aeswin: $(BUILD)/gem_aeswin
	./$(BUILD)/gem_aeswin

# The combined interactive desktop: menu bar + draggable windows + a dialog.
DESK_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o aes_desktop_demo.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o)) $(RSC_ENGINE_OBJ)
$(BUILD)/gem_desktop: $(DESK_OBJ)
	$(CC) $(DESK_OBJ) $(LDLIBS) -o $@
desktop: $(BUILD)/gem_desktop
	./$(BUILD)/gem_desktop

# xtdesk — the XTOS desktop: themed AES desktop + wallpaper + the two drive icons
# (G_CICON, click to select, double-click to open).  Loads assets from an OS dir
# (arg, default the mounted SD /Volumes/XTOS/OS).  `make xtdesk-ppm` = one headless
# frame to /tmp/xtdesk.ppm.
SQLITE_CFLAGS := $(shell pkg-config --cflags sqlite3 2>/dev/null)
SQLITE_LIBS   := $(shell pkg-config --libs sqlite3 2>/dev/null || echo -lsqlite3)
XTDESK_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o img.o registry.o fujiclient.o xtdesk.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o)) $(RSC_ENGINE_OBJ)
$(BUILD)/registry.o: registry.c | $(BUILD)
	$(CC) $(CFLAGS) $(SQLITE_CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/gem_xtdesk: $(XTDESK_OBJ)
	$(CC) $(XTDESK_OBJ) $(LDLIBS) $(SQLITE_LIBS) -o $@
xtdesk: $(BUILD)/gem_xtdesk
	./$(BUILD)/gem_xtdesk
xtdesk-ppm: $(BUILD)/gem_xtdesk
	./$(BUILD)/gem_xtdesk --ppm && echo "wrote /tmp/xtdesk.ppm"

# Bake the Aristo2 atlas (needs ImageMagick + the Cappuccino resources).
ARISTO2 ?= $(HOME)/src/cappuccino/cappuccino/AppKit/Themes/Aristo2/Resources
$(BUILD)/themepack: tools/themepack.c | $(BUILD)
	$(CC) $(CSTD) -O2 -o $@ $<
themepack: $(BUILD)/themepack
	mkdir -p themes/Aristo2/1x
	./$(BUILD)/themepack "$(ARISTO2)" themes/aristo2.recipe themes/Aristo2/1x icons/titlebar

# Variable-font catalog prototype: enumerate axes + named instances via FreeType.
$(BUILD)/fontscan: tools/fontscan.c | $(BUILD)
	$(CC) $(CSTD) $(WARN) -O2 -I. $(FT_CFLAGS) -o $@ $< $(FT_LIBS)
fontscan: $(BUILD)/fontscan
	@echo "run: ./$(BUILD)/fontscan <font.ttf> ..."

# OS/Fonts catalog + index exercise (host: POSIX dir scan).
CATALOG_OBJ := $(addprefix $(BUILD)/,font_catalog.o tools/catalogtest.o)
$(BUILD)/catalogtest: $(CATALOG_OBJ)
	$(CC) $(CATALOG_OBJ) $(FT_LIBS) -o $@
catalogtest: $(BUILD)/catalogtest
	@echo "run: ./$(BUILD)/catalogtest <fontdir>"

# Headless PDF printer-device smoke test (no SDL): draws vector lines/fills/bars
# through v_opnwk(21) and writes out.pdf.
PDF_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o pdf_demo.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_pdf: $(PDF_OBJ)
	$(CC) $(PDF_OBJ) $(FT_LIBS) -o $@
pdf: $(BUILD)/gem_pdf
	./$(BUILD)/gem_pdf && echo "-> $(CURDIR)/out.pdf"

# Headless self-tests (no SDL): VDI primitives, then the WM interaction layer.
TEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o vdi_test.o $(VDI_SRC:.c=.o))
$(BUILD)/gem_test: $(TEST_OBJ)
	$(CC) $(TEST_OBJ) $(FT_LIBS) -o $@

WMTEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o wm.o wm_test.o $(VDI_SRC:.c=.o))
$(BUILD)/wm_test: $(WMTEST_OBJ)
	$(CC) $(WMTEST_OBJ) $(FT_LIBS) -o $@

# menu_test — headless AES popup-menu self-test (no SDL): unit-tests the
# menu_popup geometry / hit-test / keyboard-nav helpers and renders one open
# popup + its cascade to /tmp/xtdesk-menu.ppm.
MENUTEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o menu_test.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o)) $(RSC_ENGINE_OBJ)
$(BUILD)/menu_test: $(MENUTEST_OBJ)
	$(CC) $(MENUTEST_OBJ) $(FT_LIBS) -o $@
menu_test: $(BUILD)/menu_test
	./$(BUILD)/menu_test

# ---- Shared GEM .rsc engine (../third_party/Rocks/src/rsc.c): authoring tool + test ----
# mkrsc — authors gem/resources/desktop.rsc through the engine's builder API.
# Only the engine + libc are needed (no VDI/theme/SDL), so it links tiny.
MKRSC_OBJ := $(addprefix $(BUILD)/,tools/mkrsc.o) $(RSC_ENGINE_OBJ)
$(BUILD)/mkrsc: $(MKRSC_OBJ)
	$(CC) $(MKRSC_OBJ) -o $@
mkrsc: $(BUILD)/mkrsc resources/desktop.rsc

# The authored resource — regenerated whenever mkrsc changes.
resources/desktop.rsc: $(BUILD)/mkrsc
	mkdir -p resources
	./$(BUILD)/mkrsc resources/desktop.rsc

# rsc_test — headless codec self-test: structure asserts on the New dialog, a
# centred render (through the aes/rscload.c bridge) to /tmp/xtdesk-rsc.ppm, and a
# rsc_read->rsc_write->rsc_read round-trip (structural + byte-identity).  The
# bridge (aes/rscload.o) rides in via $(AES_SRC); the engine via $(RSC_ENGINE_OBJ).
RSCTEST_OBJ := $(addprefix $(BUILD)/,gfx_soft.o font.o theme.o rsc_test.o $(VDI_SRC:.c=.o) $(AES_SRC:.c=.o)) $(RSC_ENGINE_OBJ)
$(BUILD)/rsc_test: $(RSCTEST_OBJ)
	$(CC) $(RSCTEST_OBJ) $(FT_LIBS) -o $@
rsc_test: $(BUILD)/rsc_test resources/desktop.rsc
	./$(BUILD)/rsc_test

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
