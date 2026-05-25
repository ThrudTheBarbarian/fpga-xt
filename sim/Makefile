# sim/Makefile — iverilog harness for fpga-antic.
#
# Usage:
#   make smoke    M0 — top boots, reset releases cleanly.
#   make snoop    M1 — bus snoop dispatches register writes.
#   make all      Run every target sequentially. Non-zero exit on any failure.
#   make clean

IVERILOG := iverilog
VVP      := vvp

HDL_DIR  := ../hdl
SIM_DIR  := .

SV_FLAGS := -g2012 -Wall -Wno-timescale -I$(HDL_DIR)

HDL_SRCS := \
    $(HDL_DIR)/byte_ram.sv        \
    $(HDL_DIR)/byte_ram_dp.sv     \
    $(HDL_DIR)/bus_snoop.sv       \
    $(HDL_DIR)/antic_regs.sv      \
    $(HDL_DIR)/gtia_regs.sv       \
    $(HDL_DIR)/vbeam.sv           \
    $(HDL_DIR)/dl_parser.sv       \
    $(HDL_DIR)/compositor.sv      \
    $(HDL_DIR)/color_resolver.sv  \
    $(HDL_DIR)/nmi_gen.sv         \
    $(HDL_DIR)/wsync_gen.sv       \
    $(HDL_DIR)/palette_lut.sv     \
    $(HDL_DIR)/dma_master.sv     \
    $(HDL_DIR)/dma_arbiter.sv     \
    $(HDL_DIR)/mem_read_mux.sv    \
    $(HDL_DIR)/bram_shim.sv       \
    $(HDL_DIR)/draw_regs.sv       \
    $(HDL_DIR)/pia_regs.sv        \
    $(HDL_DIR)/peri_link.sv       \
    $(HDL_DIR)/peri_bridge.sv \
    $(HDL_DIR)/joy_link.sv        \
    $(HDL_DIR)/joy_bridge.sv      \
    $(HDL_DIR)/pokey_regs.sv      \
    $(HDL_DIR)/pokey_audio.sv     \
    $(HDL_DIR)/pokey_pot.sv       \
    $(HDL_DIR)/pokey_i2s_tx.sv    \
    $(HDL_DIR)/pokey.sv           \
    $(HDL_DIR)/sally/cpu.v        \
    $(HDL_DIR)/sally/ALU.v        \
    $(HDL_DIR)/sally/sally_core.sv \
    $(HDL_DIR)/sally_clock.sv     \
    $(HDL_DIR)/bank_xlat.sv       \
    $(HDL_DIR)/sally_mem.sv       \
    $(HDL_DIR)/line_buffer.sv     \
    $(HDL_DIR)/scan_out.sv        \
    $(HDL_DIR)/hdmi_out_zynq.sv   \
    $(HDL_DIR)/pcm1808_rx.sv      \
    $(HDL_DIR)/antic_top.sv

BUILD_DIR := build

.PHONY: all smoke snoop read vbeam rp_bus dl_parse mode_f char_modes gfx_modes pm prior scroll nmi wsync palette dma_master mem_read_mux dma_int draw_regs pokey pokey_i2s sally sally_mem sally_arb bank_xlat hwreg_rd_cdc legacy_upscale plane_compositor plane_fetch axi_line_writer antic_writeback antic_raster pia_regs peri_link joy_link joy_bridge peri_bridge os_rom_load klaus visual lint clean xt_blitter sally_stack sally_isa sprite_regs sprite_fetcher sprite_compositor

all: smoke snoop read vbeam rp_bus dl_parse mode_f char_modes gfx_modes pm prior scroll nmi wsync palette dma_master mem_read_mux dma_int draw_regs pokey pokey_i2s sally sally_mem sally_arb bank_xlat pia_regs peri_link joy_link joy_bridge peri_bridge os_rom_load pbi pcm1808_rx visual xt_blitter sprite_regs sprite_fetcher sprite_compositor

# `klaus` is NOT in `all` — Klaus Dormann's full test takes ~96 M
# cycles (≥10 minutes of iverilog wall-clock). Run it manually with
# `make klaus`. Exits early on stuck-PC / failure.

# ---- Verilator lint ------------------------------------------------------
# Free static checking that's stricter than iverilog. No simulation, no
# C++ harness needed — just `verilator --lint-only`. Catches typos,
# width-mismatch issues, dangling pins, latch inferences, etc. Run before
# committing if you can.
VERILATOR := verilator
VERILATOR_FLAGS := --lint-only --Wall -Wno-fatal -I$(HDL_DIR)
VERILATOR_TOPS := antic_top vbeam bus_snoop antic_regs gtia_regs byte_ram byte_ram_dp

LINT_SRCS := $(wildcard $(HDL_DIR)/*.sv)

lint:
	@for top in $(VERILATOR_TOPS); do \
	    echo "=== verilator lint: $$top ==="; \
	    $(VERILATOR) $(VERILATOR_FLAGS) --top-module $$top \
	        $(LINT_SRCS) || exit 1; \
	done
	@echo "PASS: verilator lint"

# ---- M0 — smoke ------------------------------------------------------------
smoke: $(BUILD_DIR)/tb_smoke.vvp
	@echo "=== M0 smoke ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_smoke.log
	@grep -q '\*\*\* SMOKE OK \*\*\*' $(BUILD_DIR)/tb_smoke.log || \
	    (echo "FAIL: tb_smoke missing SMOKE OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_smoke.log && \
	    (echo "FAIL: tb_smoke reported a trap"; exit 1) || true
	@echo "PASS: tb_smoke"

$(BUILD_DIR)/tb_smoke.vvp: $(HDL_SRCS) tb_smoke.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_smoke $(HDL_SRCS) tb_smoke.sv

# ---- M1 — bus snoop dispatch ----------------------------------------------
snoop: $(BUILD_DIR)/tb_snoop.vvp
	@echo "=== M1 snoop ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_snoop.log
	@grep -q '\*\*\* SNOOP OK \*\*\*' $(BUILD_DIR)/tb_snoop.log || \
	    (echo "FAIL: tb_snoop missing SNOOP OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_snoop.log && \
	    (echo "FAIL: tb_snoop reported a trap"; exit 1) || true
	@echo "PASS: tb_snoop"

$(BUILD_DIR)/tb_snoop.vvp: $(HDL_SRCS) tb_snoop.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_snoop $(HDL_SRCS) tb_snoop.sv

# ---- M2b — bus-side register-read mux verification ------------------------
read: $(BUILD_DIR)/tb_read.vvp
	@echo "=== M2b read ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_read.log
	@grep -q '\*\*\* READ OK \*\*\*' $(BUILD_DIR)/tb_read.log || \
	    (echo "FAIL: tb_read missing READ OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_read.log && \
	    (echo "FAIL: tb_read reported a trap"; exit 1) || true
	@echo "PASS: tb_read"

$(BUILD_DIR)/tb_read.vvp: $(HDL_SRCS) tb_read.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_read $(HDL_SRCS) tb_read.sv

# ---- M3 — vbeam timing ----------------------------------------------------
vbeam: $(BUILD_DIR)/tb_vbeam.vvp
	@echo "=== M3 vbeam ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_vbeam.log
	@grep -q '\*\*\* VBEAM OK \*\*\*' $(BUILD_DIR)/tb_vbeam.log || \
	    (echo "FAIL: tb_vbeam missing VBEAM OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_vbeam.log && \
	    (echo "FAIL: tb_vbeam reported a trap"; exit 1) || true
	@echo "PASS: tb_vbeam"

$(BUILD_DIR)/tb_vbeam.vvp: $(HDL_DIR)/vbeam.sv tb_vbeam.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_vbeam $(HDL_DIR)/vbeam.sv tb_vbeam.sv

# ---- M5 — display-list parser ---------------------------------------------
DL_PARSE_HDL := \
    $(HDL_DIR)/byte_ram.sv       \
    $(HDL_DIR)/dl_parser.sv

dl_parse: $(BUILD_DIR)/tb_dl_parse.vvp
	@echo "=== M5 dl_parse ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_dl_parse.log
	@grep -q '\*\*\* DL_PARSE OK \*\*\*' $(BUILD_DIR)/tb_dl_parse.log || \
	    (echo "FAIL: tb_dl_parse missing DL_PARSE OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_dl_parse.log && \
	    (echo "FAIL: tb_dl_parse reported a trap"; exit 1) || true
	@echo "PASS: tb_dl_parse"

$(BUILD_DIR)/tb_dl_parse.vvp: $(DL_PARSE_HDL) tb_dl_parse.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_dl_parse $(DL_PARSE_HDL) tb_dl_parse.sv


# ---- M7 — char-mode compositor pipeline ---------------------------------
# Same HDL set as mode_f — compositor handles all char modes too.
char_modes: $(BUILD_DIR)/tb_char_modes.vvp
	@echo "=== M7 char_modes ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_char_modes.log
	@grep -q '\*\*\* CHAR_MODES OK \*\*\*' $(BUILD_DIR)/tb_char_modes.log || \
	    (echo "FAIL: tb_char_modes missing CHAR_MODES OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_char_modes.log && \
	    (echo "FAIL: tb_char_modes reported a trap"; exit 1) || true
	@echo "PASS: tb_char_modes"

$(BUILD_DIR)/tb_char_modes.vvp: $(MODE_F_HDL) tb_char_modes.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_char_modes $(MODE_F_HDL) tb_char_modes.sv

# ---- M8 — graphics modes 8-E ---------------------------------------------
gfx_modes: $(BUILD_DIR)/tb_gfx_modes.vvp
	@echo "=== M8 gfx_modes ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_gfx_modes.log
	@grep -q '\*\*\* GFX_MODES OK \*\*\*' $(BUILD_DIR)/tb_gfx_modes.log || \
	    (echo "FAIL: tb_gfx_modes missing GFX_MODES OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_gfx_modes.log && \
	    (echo "FAIL: tb_gfx_modes reported a trap"; exit 1) || true
	@echo "PASS: tb_gfx_modes"

$(BUILD_DIR)/tb_gfx_modes.vvp: $(MODE_F_HDL) tb_gfx_modes.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_gfx_modes $(MODE_F_HDL) tb_gfx_modes.sv

# ---- M9 — P/M overlay -----------------------------------------------------
pm: $(BUILD_DIR)/tb_pm.vvp
	@echo "=== M9 pm ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pm.log
	@grep -q '\*\*\* PM OK \*\*\*' $(BUILD_DIR)/tb_pm.log || \
	    (echo "FAIL: tb_pm missing PM OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_pm.log && \
	    (echo "FAIL: tb_pm reported a trap"; exit 1) || true
	@echo "PASS: tb_pm"

$(BUILD_DIR)/tb_pm.vvp: $(MODE_F_HDL) tb_pm.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pm $(MODE_F_HDL) tb_pm.sv

# ---- M10 — PRIOR / colour resolver ---------------------------------------
prior: $(BUILD_DIR)/tb_prior.vvp
	@echo "=== M10 prior ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_prior.log
	@grep -q '\*\*\* PRIOR OK \*\*\*' $(BUILD_DIR)/tb_prior.log || \
	    (echo "FAIL: tb_prior missing PRIOR OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_prior.log && \
	    (echo "FAIL: tb_prior reported a trap"; exit 1) || true
	@echo "PASS: tb_prior"

$(BUILD_DIR)/tb_prior.vvp: $(HDL_DIR)/color_resolver.sv tb_prior.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_prior $(HDL_DIR)/color_resolver.sv tb_prior.sv

# ---- M11 — HSCROL / VSCROL --------------------------------------------------
scroll: $(BUILD_DIR)/tb_scroll.vvp
	@echo "=== M11 scroll ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_scroll.log
	@grep -q '\*\*\* SCROLL OK \*\*\*' $(BUILD_DIR)/tb_scroll.log || \
	    (echo "FAIL: tb_scroll missing SCROLL OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_scroll.log && \
	    (echo "FAIL: tb_scroll reported a trap"; exit 1) || true
	@echo "PASS: tb_scroll"

$(BUILD_DIR)/tb_scroll.vvp: $(MODE_F_HDL) tb_scroll.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_scroll $(MODE_F_HDL) tb_scroll.sv

# ---- M12 — NMI generator -------------------------------------------------
nmi: $(BUILD_DIR)/tb_nmi.vvp
	@echo "=== M12 nmi ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_nmi.log
	@grep -q '\*\*\* NMI OK \*\*\*' $(BUILD_DIR)/tb_nmi.log || \
	    (echo "FAIL: tb_nmi missing NMI OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_nmi.log && \
	    (echo "FAIL: tb_nmi reported a trap"; exit 1) || true
	@echo "PASS: tb_nmi"

NMI_HDL := \
    $(HDL_DIR)/byte_ram.sv     \
    $(HDL_DIR)/antic_regs.sv   \
    $(HDL_DIR)/dl_parser.sv    \
    $(HDL_DIR)/nmi_gen.sv

$(BUILD_DIR)/tb_nmi.vvp: $(NMI_HDL) tb_nmi.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_nmi $(NMI_HDL) tb_nmi.sv

# ---- M13 — WSYNC / RDY ---------------------------------------------------
wsync: $(BUILD_DIR)/tb_wsync.vvp
	@echo "=== M13 wsync ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_wsync.log
	@grep -q '\*\*\* WSYNC OK \*\*\*' $(BUILD_DIR)/tb_wsync.log || \
	    (echo "FAIL: tb_wsync missing WSYNC OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_wsync.log && \
	    (echo "FAIL: tb_wsync reported a trap"; exit 1) || true
	@echo "PASS: tb_wsync"

WSYNC_HDL := \
    $(HDL_DIR)/antic_regs.sv   \
    $(HDL_DIR)/wsync_gen.sv

$(BUILD_DIR)/tb_wsync.vvp: $(WSYNC_HDL) tb_wsync.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_wsync $(WSYNC_HDL) tb_wsync.sv

# ---- M14 — palette LUT ---------------------------------------------------
palette: $(BUILD_DIR)/tb_palette.vvp
	@echo "=== M14 palette ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_palette.log
	@grep -q '\*\*\* PALETTE OK \*\*\*' $(BUILD_DIR)/tb_palette.log || \
	    (echo "FAIL: tb_palette missing PALETTE OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_palette.log && \
	    (echo "FAIL: tb_palette reported a trap"; exit 1) || true
	@echo "PASS: tb_palette"

PALETTE_HDL := \
    $(HDL_DIR)/antic_regs.sv   \
    $(HDL_DIR)/palette_lut.sv

$(BUILD_DIR)/tb_palette.vvp: $(PALETTE_HDL) tb_palette.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_palette $(PALETTE_HDL) tb_palette.sv

# ---- M16 — DMA bus master ------------------------------------------------
dma_master: $(BUILD_DIR)/tb_dma_master.vvp
	@echo "=== M16 dma_master ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_dma_master.log
	@grep -q '\*\*\* DMA OK \*\*\*' $(BUILD_DIR)/tb_dma_master.log || \
	    (echo "FAIL: tb_dma_master missing DMA OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_dma_master.log && \
	    (echo "FAIL: tb_dma_master reported a trap"; exit 1) || true
	@echo "PASS: tb_dma_master"

$(BUILD_DIR)/tb_dma_master.vvp: $(HDL_DIR)/dma_master.sv tb_dma_master.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_dma_master $(HDL_DIR)/dma_master.sv tb_dma_master.sv

# ---- M16-int (1/3) — mem_read_mux adapter --------------------------------
mem_read_mux: $(BUILD_DIR)/tb_mem_read_mux.vvp
	@echo "=== M16-int mem_read_mux ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_mem_read_mux.log
	@grep -q '\*\*\* MEM_MUX OK \*\*\*' $(BUILD_DIR)/tb_mem_read_mux.log || \
	    (echo "FAIL: tb_mem_read_mux missing MEM_MUX OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_mem_read_mux.log && \
	    (echo "FAIL: tb_mem_read_mux reported a trap"; exit 1) || true
	@echo "PASS: tb_mem_read_mux"

MEM_MUX_HDL := \
    $(HDL_DIR)/byte_ram.sv         \
    $(HDL_DIR)/dma_master.sv       \
    $(HDL_DIR)/mem_read_mux.sv

$(BUILD_DIR)/tb_mem_read_mux.vvp: $(MEM_MUX_HDL) tb_mem_read_mux.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_mem_read_mux $(MEM_MUX_HDL) tb_mem_read_mux.sv

# ---- M16-int-tb — DL through both modes integration test -----------------
dma_int: $(BUILD_DIR)/tb_dma_int.vvp
	@echo "=== M16-int-tb dma_int ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_dma_int.log
	@grep -q '\*\*\* DMA_INT OK \*\*\*' $(BUILD_DIR)/tb_dma_int.log || \
	    (echo "FAIL: tb_dma_int missing DMA_INT OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_dma_int.log && \
	    (echo "FAIL: tb_dma_int reported a trap"; exit 1) || true
	@echo "PASS: tb_dma_int"

DMA_INT_HDL := \
    $(HDL_DIR)/byte_ram.sv         \
    $(HDL_DIR)/byte_ram_dp.sv      \
    $(HDL_DIR)/dl_parser.sv        \
    $(HDL_DIR)/compositor.sv       \
    $(HDL_DIR)/dma_master.sv       \
    $(HDL_DIR)/dma_arbiter.sv      \
    $(HDL_DIR)/mem_read_mux.sv

$(BUILD_DIR)/tb_dma_int.vvp: $(DMA_INT_HDL) tb_dma_int.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_dma_int $(DMA_INT_HDL) tb_dma_int.sv

# ---- xt_blitter -- 2D GPU testbench --------------------------------------
xt_blitter: $(BUILD_DIR)/tb_xt_blitter.vvp
	@echo "=== xt_blitter ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_xt_blitter.log
	@grep -q 'ALL TESTS PASSED' $(BUILD_DIR)/tb_xt_blitter.log || \
	    (echo "FAIL: tb_xt_blitter did not pass all tests"; exit 1)
	@grep -q 'FATAL\|FAIL' $(BUILD_DIR)/tb_xt_blitter.log && \
	    (echo "FAIL: tb_xt_blitter reported a failure"; exit 1) || true
	@echo "PASS: tb_xt_blitter"

$(BUILD_DIR)/tb_xt_blitter.vvp: $(HDL_DIR)/xt_blitter.sv tb_xt_blitter.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_xt_blitter $(HDL_DIR)/xt_blitter.sv tb_xt_blitter.sv

# ---- M17-2 — chiplet-ext DRAW register port ------------------------------
draw_regs: $(BUILD_DIR)/tb_draw_regs.vvp
	@echo "=== M17-2 draw_regs ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_draw_regs.log
	@grep -q '\*\*\* DRAW_REGS OK \*\*\*' $(BUILD_DIR)/tb_draw_regs.log || \
	    (echo "FAIL: tb_draw_regs missing DRAW_REGS OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_draw_regs.log && \
	    (echo "FAIL: tb_draw_regs reported a trap"; exit 1) || true
	@echo "PASS: tb_draw_regs"

$(BUILD_DIR)/tb_draw_regs.vvp: $(HDL_DIR)/draw_regs.sv tb_draw_regs.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_draw_regs $(HDL_DIR)/draw_regs.sv tb_draw_regs.sv

# ---- M23-1 — POKEY register file + 4× square-wave channels --------------
pokey: $(BUILD_DIR)/tb_pokey.vvp
	@echo "=== M23-1 pokey ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pokey.log
	@grep -q '\*\*\* POKEY OK \*\*\*' $(BUILD_DIR)/tb_pokey.log || \
	    (echo "FAIL: tb_pokey missing POKEY OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_pokey.log && \
	    (echo "FAIL: tb_pokey reported a trap"; exit 1) || true
	@echo "PASS: tb_pokey"

POKEY_HDL := \
    $(HDL_DIR)/pokey_regs.sv     \
    $(HDL_DIR)/pokey_audio.sv    \
    $(HDL_DIR)/pokey_pot.sv      \
    $(HDL_DIR)/pokey_i2s_tx.sv   \
    $(HDL_DIR)/pokey.sv

$(BUILD_DIR)/tb_pokey.vvp: $(POKEY_HDL) tb_pokey.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pokey $(POKEY_HDL) tb_pokey.sv

# ---- M23-7 — POKEY → HDMI audio packet feed ------------------------------
pokey_i2s: $(BUILD_DIR)/tb_pokey_i2s.vvp
	@echo "=== M23-7 pokey_i2s_tx ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pokey_i2s.log
	@grep -q '\*\*\* POKEY_I2S OK \*\*\*' $(BUILD_DIR)/tb_pokey_i2s.log || \
	    (echo "FAIL: tb_pokey_i2s missing POKEY_I2S OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_pokey_i2s.log && \
	    (echo "FAIL: tb_pokey_i2s reported a trap"; exit 1) || true
	@echo "PASS: tb_pokey_i2s"

$(BUILD_DIR)/tb_pokey_i2s.vvp: $(HDL_DIR)/pokey_i2s_tx.sv tb_pokey_i2s.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pokey_i2s $(HDL_DIR)/pokey_i2s_tx.sv tb_pokey_i2s.sv

# ---- M24-1 — SALLY (Arlet 6502) bring-up --------------------------------
sally: $(BUILD_DIR)/tb_sally.vvp
	@echo "=== M24-1 sally ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally.log
	@grep -q '\*\*\* SALLY OK \*\*\*' $(BUILD_DIR)/tb_sally.log || \
	    (echo "FAIL: tb_sally missing SALLY OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_sally.log && \
	    (echo "FAIL: tb_sally reported a trap"; exit 1) || true
	@echo "PASS: tb_sally"

SALLY_HDL := \
    $(HDL_DIR)/sally/cpu.v        \
    $(HDL_DIR)/sally/ALU.v        \
    $(HDL_DIR)/sally/sally_core.sv \
    $(HDL_DIR)/bank_xlat.sv        \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv

$(BUILD_DIR)/tb_sally.vvp: $(SALLY_HDL) tb_sally.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally $(SALLY_HDL) axi_slave_mem.sv tb_sally.sv

# ---- sally_stack — Stage A Increment 1 stack-BRAM alias test -------------
SALLY_STACK_HDL := \
    $(HDL_DIR)/bank_xlat.sv         \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv

sally_stack: $(BUILD_DIR)/tb_sally_stack.vvp
	@echo "=== sally_stack — stack-BRAM alias test ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_stack.log
	@grep -q 'ALL TESTS PASSED' $(BUILD_DIR)/tb_sally_stack.log || \
	    (echo "FAIL: tb_sally_stack did not pass"; exit 1)
	@echo "PASS: tb_sally_stack"

$(BUILD_DIR)/tb_sally_stack.vvp: $(SALLY_STACK_HDL) tb_sally_stack.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_stack $(SALLY_STACK_HDL) tb_sally_stack.sv

# ---- sally_isa — Stage A/B 6502 ISA tests (small CPU+flat-mem harness) ----
SALLY_ISA_HDL := \
    $(HDL_DIR)/sally/cpu.v        \
    $(HDL_DIR)/sally/ALU.v        \
    $(HDL_DIR)/sally/sally_core.sv

sally_isa: $(BUILD_DIR)/tb_sally_isa.vvp
	@echo "=== sally_isa — Stage A/B ISA tests ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_isa.log
	@grep -q 'ALL TESTS PASSED' $(BUILD_DIR)/tb_sally_isa.log || \
	    (echo "FAIL: tb_sally_isa did not pass"; exit 1)
	@echo "PASS: tb_sally_isa"

$(BUILD_DIR)/tb_sally_isa.vvp: $(SALLY_ISA_HDL) tb_sally_isa.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_isa $(SALLY_ISA_HDL) tb_sally_isa.sv

# ---- M24-klaus — Klaus Dormann 6502 functional test --------------------
# Runs Klaus Dormann's full documented-opcode test against sally_core.
# Vendored binary at sim/test_data/6502_functional_test.bin (BSD,
# Klaus2m5/6502_65C02_functional_tests). The .hex file is generated
# from the .bin by `make test_data/6502_functional_test.hex`.
#
# Long-running — not in the default `all`. Exits early on stuck-PC.
klaus: $(BUILD_DIR)/tb_klaus.vvp test_data/6502_functional_test.hex
	@echo "=== M24-klaus Klaus Dormann functional test ==="
	# -i (interactive, unbuffered stdio) instead of -N: this run is many
	# minutes long, and with -N vvp's stdout is block-buffered when piped
	# to tee, so the [progress] pings + verdict don't appear until the end.
	# -i streams them live.  Safe here — the tb halts via $finish/$fatal
	# (never $stop), and </dev/null guarantees no interactive blocking.
	@$(VVP) -i $< </dev/null | tee $(BUILD_DIR)/tb_klaus.log
	@grep -q '\*\*\* KLAUS OK \*\*\*' $(BUILD_DIR)/tb_klaus.log || \
	    (echo "FAIL: tb_klaus did not reach success trap"; exit 1)
	@echo "PASS: tb_klaus"

KLAUS_HDL := \
    $(HDL_DIR)/sally/cpu.v        \
    $(HDL_DIR)/sally/ALU.v        \
    $(HDL_DIR)/sally/sally_core.sv

$(BUILD_DIR)/tb_klaus.vvp: $(KLAUS_HDL) tb_klaus.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_klaus $(KLAUS_HDL) tb_klaus.sv

# .bin → .hex (one byte per line) for $readmemh.
test_data/6502_functional_test.hex: test_data/6502_functional_test.bin
	od -An -tx1 -v $< | tr -s ' ' '\n' | grep -v '^$$' > $@

# ---- tb_page_test — PAGE cache unit test ---------------------------------
PAGE_TEST_HDL := \
    $(HDL_DIR)/bank_xlat.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv

page_test: $(BUILD_DIR)/tb_page_test.vvp
	@echo "=== tb_page_test — PAGE cache ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_page_test.log
	@grep -q '\*\*\* PAGE CACHE OK \*\*\*' $(BUILD_DIR)/tb_page_test.log || \
	    (echo "FAIL: tb_page_test missing PAGE CACHE OK"; exit 1)
	@echo "PASS: tb_page_test"

$(BUILD_DIR)/tb_page_test.vvp: $(PAGE_TEST_HDL) tb_page_test.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_page_test $(PAGE_TEST_HDL) axi_slave_mem.sv tb_page_test.sv

# ---- M24-2 — SALLY memory subsystem -------------------------------------
sally_mem: $(BUILD_DIR)/tb_sally_mem.vvp
	@echo "=== M24-2 sally_mem ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_mem.log
	@grep -q '\*\*\* SALLY_MEM OK \*\*\*' $(BUILD_DIR)/tb_sally_mem.log || \
	    (echo "FAIL: tb_sally_mem missing SALLY_MEM OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_sally_mem.log && \
	    (echo "FAIL: tb_sally_mem reported a trap"; exit 1) || true
	@echo "PASS: tb_sally_mem"

SALLY_MEM_HDL := \
    $(HDL_DIR)/bank_xlat.sv \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv

$(BUILD_DIR)/tb_sally_mem.vvp: $(SALLY_MEM_HDL) tb_sally_mem.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_mem $(SALLY_MEM_HDL) axi_slave_mem.sv tb_sally_mem.sv

# ---- M24-5 — SALLY bus arbitration -------------------------------------
sally_arb: $(BUILD_DIR)/tb_sally_arbitration.vvp
	@echo "=== M24-5 sally_arb ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_arbitration.log
	@grep -q '\*\*\* SALLY_ARB OK \*\*\*' $(BUILD_DIR)/tb_sally_arbitration.log || \
	    (echo "FAIL: tb_sally_arbitration missing SALLY_ARB OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_sally_arbitration.log && \
	    (echo "FAIL: tb_sally_arbitration reported a trap"; exit 1) || true
	@echo "PASS: tb_sally_arbitration"

SALLY_ARB_HDL := \
    $(HDL_DIR)/sally/cpu.v        \
    $(HDL_DIR)/sally/ALU.v        \
    $(HDL_DIR)/sally/sally_core.sv \
    $(HDL_DIR)/bank_xlat.sv        \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv        \
    $(HDL_DIR)/sally_clock.sv

$(BUILD_DIR)/tb_sally_arbitration.vvp: $(SALLY_ARB_HDL) tb_sally_arbitration.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_arbitration $(SALLY_ARB_HDL) axi_slave_mem.sv tb_sally_arbitration.sv

# ---- M24-4 — bank translator (CPU vs ANTIC view) -----------------------
bank_xlat: $(BUILD_DIR)/tb_bank_xlat.vvp
	@echo "=== M24-4 bank_xlat ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_bank_xlat.log
	@grep -q '\*\*\* BANK_XLAT OK \*\*\*' $(BUILD_DIR)/tb_bank_xlat.log || \
	    (echo "FAIL: tb_bank_xlat missing BANK_XLAT OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_bank_xlat.log && \
	    (echo "FAIL: tb_bank_xlat reported a trap"; exit 1) || true
	@echo "PASS: tb_bank_xlat"

$(BUILD_DIR)/tb_bank_xlat.vvp: $(HDL_DIR)/bank_xlat.sv tb_bank_xlat.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_bank_xlat $(HDL_DIR)/bank_xlat.sv tb_bank_xlat.sv

# ---- hwreg_rd_cdc — register-read CDC bridge (boot blocker #3) ----------
hwreg_rd_cdc: $(BUILD_DIR)/tb_hwreg_rd_cdc.vvp
	@echo "=== hwreg_rd_cdc — register-read CDC bridge ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hwreg_rd_cdc.log
	@grep -q '\*\*\* HWREG_RD_CDC OK \*\*\*' $(BUILD_DIR)/tb_hwreg_rd_cdc.log || \
	    (echo "FAIL: tb_hwreg_rd_cdc missing HWREG_RD_CDC OK"; exit 1)
	@echo "PASS: tb_hwreg_rd_cdc"

$(BUILD_DIR)/tb_hwreg_rd_cdc.vvp: $(HDL_DIR)/hwreg_rd_cdc.sv $(HDL_DIR)/cdc_sync_bit.sv tb_hwreg_rd_cdc.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hwreg_rd_cdc $(HDL_DIR)/hwreg_rd_cdc.sv $(HDL_DIR)/cdc_sync_bit.sv tb_hwreg_rd_cdc.sv

# ---- legacy_upscale — 1080p pillarbox upscaler (boot gap 4b) ------------
legacy_upscale: $(BUILD_DIR)/tb_legacy_upscale.vvp
	@echo "=== legacy_upscale — 1080p pillarbox upscaler ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_legacy_upscale.log
	@grep -q '\*\*\* LEGACY_UPSCALE OK \*\*\*' $(BUILD_DIR)/tb_legacy_upscale.log || \
	    (echo "FAIL: tb_legacy_upscale missing LEGACY_UPSCALE OK"; exit 1)
	@echo "PASS: tb_legacy_upscale"

$(BUILD_DIR)/tb_legacy_upscale.vvp: $(HDL_DIR)/legacy_upscale.sv $(HDL_DIR)/palette_lut.sv tb_legacy_upscale.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_legacy_upscale $(HDL_DIR)/legacy_upscale.sv $(HDL_DIR)/palette_lut.sv tb_legacy_upscale.sv

# ---- plane_compositor — multi-plane compositor core (video arch phase 1) -
plane_compositor: $(BUILD_DIR)/tb_plane_compositor.vvp
	@echo "=== plane_compositor — multi-plane compositor core ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_plane_compositor.log
	@grep -q '\*\*\* PLANE_COMPOSITOR OK \*\*\*' $(BUILD_DIR)/tb_plane_compositor.log || \
	    (echo "FAIL: tb_plane_compositor missing PLANE_COMPOSITOR OK"; exit 1)
	@echo "PASS: tb_plane_compositor"

$(BUILD_DIR)/tb_plane_compositor.vvp: $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/vbeam.sv tb_plane_compositor.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_plane_compositor $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/vbeam.sv tb_plane_compositor.sv

# ---- plane_fetch — per-plane DDR3 line fetch unit (video arch phase 1b) ---
plane_fetch: $(BUILD_DIR)/tb_plane_fetch.vvp
	@echo "=== plane_fetch — per-plane DDR3 line fetch ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_plane_fetch.log
	@grep -q '\*\*\* PLANE_FETCH OK \*\*\*' $(BUILD_DIR)/tb_plane_fetch.log || \
	    (echo "FAIL: tb_plane_fetch missing PLANE_FETCH OK"; exit 1)
	@echo "PASS: tb_plane_fetch"

$(BUILD_DIR)/tb_plane_fetch.vvp: $(HDL_DIR)/plane_fetch.sv axi_slave_mem.sv tb_plane_fetch.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_plane_fetch $(HDL_DIR)/plane_fetch.sv axi_slave_mem.sv tb_plane_fetch.sv

# ---- axi_line_writer — ANTIC->DDR3 row writeback DMA (video arch phase 2) -
axi_line_writer: $(BUILD_DIR)/tb_axi_line_writer.vvp
	@echo "=== axi_line_writer — ANTIC->DDR3 row writeback ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_axi_line_writer.log
	@grep -q '\*\*\* AXI_LINE_WRITER OK \*\*\*' $(BUILD_DIR)/tb_axi_line_writer.log || \
	    (echo "FAIL: tb_axi_line_writer missing AXI_LINE_WRITER OK"; exit 1)
	@echo "PASS: tb_axi_line_writer"

$(BUILD_DIR)/tb_axi_line_writer.vvp: $(HDL_DIR)/axi_line_writer.sv axi_slave_mem.sv tb_axi_line_writer.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_axi_line_writer $(HDL_DIR)/axi_line_writer.sv axi_slave_mem.sv tb_axi_line_writer.sv

# ---- antic_writeback — ANTIC->DDR3 writeback orchestrator (phase 2) -------
antic_writeback: $(BUILD_DIR)/tb_antic_writeback.vvp
	@echo "=== antic_writeback — ANTIC->DDR3 writeback orchestrator ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_writeback.log
	@grep -q '\*\*\* ANTIC_WRITEBACK OK \*\*\*' $(BUILD_DIR)/tb_antic_writeback.log || \
	    (echo "FAIL: tb_antic_writeback missing ANTIC_WRITEBACK OK"; exit 1)
	@echo "PASS: tb_antic_writeback"

$(BUILD_DIR)/tb_antic_writeback.vvp: $(HDL_DIR)/antic_writeback.sv $(HDL_DIR)/axi_line_writer.sv $(HDL_DIR)/palette_lut.sv axi_slave_mem.sv tb_antic_writeback.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_writeback $(HDL_DIR)/antic_writeback.sv $(HDL_DIR)/axi_line_writer.sv $(HDL_DIR)/palette_lut.sv axi_slave_mem.sv tb_antic_writeback.sv

# ---- antic_raster — phi2-paced native raster timer (video-arch §5.1) ------
antic_raster: $(BUILD_DIR)/tb_antic_raster.vvp
	@echo "=== antic_raster — phi2-paced native raster timer ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_raster.log
	@grep -q '\*\*\* ANTIC_RASTER OK \*\*\*' $(BUILD_DIR)/tb_antic_raster.log || \
	    (echo "FAIL: tb_antic_raster missing ANTIC_RASTER OK"; exit 1)
	@echo "PASS: tb_antic_raster"

$(BUILD_DIR)/tb_antic_raster.vvp: $(HDL_DIR)/antic_raster.sv tb_antic_raster.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_raster $(HDL_DIR)/antic_raster.sv tb_antic_raster.sv

# ---- M25-2 — peri_link FPGA-side SPI master ------------------------------
peri_link: $(BUILD_DIR)/tb_peri_link.vvp
	@echo "=== M25-2 peri_link ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_peri_link.log
	@grep -q '\*\*\* PERI_LINK OK \*\*\*' $(BUILD_DIR)/tb_peri_link.log || \
	    (echo "FAIL: tb_peri_link missing PERI_LINK OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_peri_link.log && \
	    (echo "FAIL: tb_peri_link reported a trap"; exit 1) || true
	@echo "PASS: tb_peri_link"

$(BUILD_DIR)/tb_peri_link.vvp: $(HDL_DIR)/peri_link.sv tb_peri_link.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_peri_link $(HDL_DIR)/peri_link.sv tb_peri_link.sv

# ---- M25-2c-rev — joy_link PCAL9722 SPI master ----------------------------
joy_link: $(BUILD_DIR)/tb_joy_link.vvp
	@echo "=== M25-2c-rev joy_link ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_joy_link.log
	@grep -q '\*\*\* JOY_LINK OK \*\*\*' $(BUILD_DIR)/tb_joy_link.log || \
	    (echo "FAIL: tb_joy_link missing JOY_LINK OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_joy_link.log && \
	    (echo "FAIL: tb_joy_link reported a trap"; exit 1) || true
	@echo "PASS: tb_joy_link"

$(BUILD_DIR)/tb_joy_link.vvp: $(HDL_DIR)/joy_link.sv tb_joy_link.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_joy_link $(HDL_DIR)/joy_link.sv tb_joy_link.sv

# ---- M25-2c-rev — joy_bridge joy/fire shadow over PCAL9722 ----------------
joy_bridge: $(BUILD_DIR)/tb_joy_bridge.vvp
	@echo "=== M25-2c-rev joy_bridge ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_joy_bridge.log
	@grep -q '\*\*\* JOY_BRIDGE OK \*\*\*' $(BUILD_DIR)/tb_joy_bridge.log || \
	    (echo "FAIL: tb_joy_bridge missing JOY_BRIDGE OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_joy_bridge.log && \
	    (echo "FAIL: tb_joy_bridge reported a trap"; exit 1) || true
	@echo "PASS: tb_joy_bridge"

JOY_BRIDGE_HDL := $(HDL_DIR)/joy_link.sv $(HDL_DIR)/joy_bridge.sv

$(BUILD_DIR)/tb_joy_bridge.vvp: $(JOY_BRIDGE_HDL) tb_joy_bridge.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_joy_bridge $(JOY_BRIDGE_HDL) tb_joy_bridge.sv

# ---- M25-3c — peri_bridge POT scan via peri_link ----------------------
peri_bridge: $(BUILD_DIR)/tb_peri_bridge.vvp
	@echo "=== M25-3c peri_bridge ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_peri_bridge.log
	@grep -q '\*\*\* PERI_BRIDGE OK \*\*\*' $(BUILD_DIR)/tb_peri_bridge.log || \
	    (echo "FAIL: tb_peri_bridge missing PERI_BRIDGE OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_peri_bridge.log && \
	    (echo "FAIL: tb_peri_bridge reported a trap"; exit 1) || true
	@echo "PASS: tb_peri_bridge"

PERI_BRIDGE_HDL := $(HDL_DIR)/peri_link.sv $(HDL_DIR)/peri_bridge.sv

$(BUILD_DIR)/tb_peri_bridge.vvp: $(PERI_BRIDGE_HDL) tb_peri_bridge.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_peri_bridge $(PERI_BRIDGE_HDL) tb_peri_bridge.sv

# ---- M25-1 — PIA shadow at $D300-$D37F -----------------------------------
pia_regs: $(BUILD_DIR)/tb_pia_regs.vvp
	@echo "=== M25-1 pia_regs ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pia_regs.log
	@grep -q '\*\*\* PIA_REGS OK \*\*\*' $(BUILD_DIR)/tb_pia_regs.log || \
	    (echo "FAIL: tb_pia_regs missing PIA_REGS OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_pia_regs.log && \
	    (echo "FAIL: tb_pia_regs reported a trap"; exit 1) || true
	@echo "PASS: tb_pia_regs"

$(BUILD_DIR)/tb_pia_regs.vvp: $(HDL_DIR)/pia_regs.sv tb_pia_regs.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pia_regs $(HDL_DIR)/pia_regs.sv tb_pia_regs.sv

# ---- M24-6 — OS ROM load path -----------------------------------------
os_rom_load: $(BUILD_DIR)/tb_os_rom_load.vvp
	@echo "=== M24-6 os_rom_load ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_os_rom_load.log
	@grep -q '\*\*\* OS_ROM_LOAD OK \*\*\*' $(BUILD_DIR)/tb_os_rom_load.log || \
	    (echo "FAIL: tb_os_rom_load missing OS_ROM_LOAD OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_os_rom_load.log && \
	    (echo "FAIL: tb_os_rom_load reported a trap"; exit 1) || true
	@echo "PASS: tb_os_rom_load"

OS_ROM_HDL := \
    $(HDL_DIR)/antic_regs.sv \
    $(HDL_DIR)/bank_xlat.sv  \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv

$(BUILD_DIR)/tb_os_rom_load.vvp: $(OS_ROM_HDL) tb_os_rom_load.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_os_rom_load $(OS_ROM_HDL) axi_slave_mem.sv tb_os_rom_load.sv

# ---- M-aux-audio PCM1808 I²S RX ------------------------------------------
pcm1808_rx: $(BUILD_DIR)/tb_pcm1808_rx.vvp
	@echo "=== M-aux-audio tb_pcm1808_rx ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pcm1808_rx.log
	@grep -q '\*\*\* PCM1808_RX OK \*\*\*' $(BUILD_DIR)/tb_pcm1808_rx.log || \
	    (echo "FAIL: tb_pcm1808_rx missing PCM1808_RX OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_pcm1808_rx.log && \
	    (echo "FAIL: tb_pcm1808_rx reported a trap"; exit 1) || true
	@echo "PASS: tb_pcm1808_rx"

$(BUILD_DIR)/tb_pcm1808_rx.vvp: $(HDL_DIR)/pcm1808_rx.sv tb_pcm1808_rx.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pcm1808_rx $(HDL_DIR)/pcm1808_rx.sv tb_pcm1808_rx.sv

# ---- M-PBI behavioural integration ---------------------------------------
pbi: $(BUILD_DIR)/tb_pbi.vvp
	@echo "=== M-PBI tb_pbi ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pbi.log
	@grep -q '\*\*\* PBI OK \*\*\*' $(BUILD_DIR)/tb_pbi.log || \
	    (echo "FAIL: tb_pbi missing PBI OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_pbi.log && \
	    (echo "FAIL: tb_pbi reported a trap"; exit 1) || true
	@echo "PASS: tb_pbi"

$(BUILD_DIR)/tb_pbi.vvp: $(HDL_SRCS) tb_pbi.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pbi $(HDL_SRCS) tb_pbi.sv

# ---- sprite_regs — sprite_engine descriptor register file ----------------
SPRITE_ENG_HDL := \
    $(HDL_DIR)/cdc_sync_bit.sv     \
    $(HDL_DIR)/sprite_line_cache.sv \
    $(HDL_DIR)/sprite_engine.sv

sprite_regs: $(BUILD_DIR)/tb_sprite_regs.vvp
	@echo "=== sprite_regs ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sprite_regs.log
	@grep -q '\*\*\* SPRITE_REGS OK \*\*\*' $(BUILD_DIR)/tb_sprite_regs.log || \
	    (echo "FAIL: tb_sprite_regs missing SPRITE_REGS OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_sprite_regs.log && \
	    (echo "FAIL: tb_sprite_regs reported a trap"; exit 1) || true
	@echo "PASS: tb_sprite_regs"

$(BUILD_DIR)/tb_sprite_regs.vvp: $(SPRITE_ENG_HDL) tb_sprite_regs.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sprite_regs $(SPRITE_ENG_HDL) tb_sprite_regs.sv

# ---- sprite_fetcher — AXI HP2 line fetcher + line cache ------------------
sprite_fetcher: $(BUILD_DIR)/tb_sprite_fetcher.vvp
	@echo "=== sprite_fetcher ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sprite_fetcher.log
	@grep -q '\*\*\* SPRITE_FETCHER OK \*\*\*' $(BUILD_DIR)/tb_sprite_fetcher.log || \
	    (echo "FAIL: tb_sprite_fetcher missing SPRITE_FETCHER OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_sprite_fetcher.log && \
	    (echo "FAIL: tb_sprite_fetcher reported a trap"; exit 1) || true
	@echo "PASS: tb_sprite_fetcher"

$(BUILD_DIR)/tb_sprite_fetcher.vvp: $(SPRITE_ENG_HDL) tb_sprite_fetcher.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sprite_fetcher $(SPRITE_ENG_HDL) axi_slave_mem.sv tb_sprite_fetcher.sv

# ---- sprite_compositor — pixel pipeline (hit / priority / alpha blend) ---
sprite_compositor: $(BUILD_DIR)/tb_sprite_compositor.vvp
	@echo "=== sprite_compositor ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sprite_compositor.log
	@grep -q '\*\*\* SPRITE_COMP OK \*\*\*' $(BUILD_DIR)/tb_sprite_compositor.log || \
	    (echo "FAIL: tb_sprite_compositor missing SPRITE_COMP OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_sprite_compositor.log && \
	    (echo "FAIL: tb_sprite_compositor reported a trap"; exit 1) || true
	@echo "PASS: tb_sprite_compositor"

$(BUILD_DIR)/tb_sprite_compositor.vvp: $(SPRITE_ENG_HDL) tb_sprite_compositor.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sprite_compositor $(SPRITE_ENG_HDL) tb_sprite_compositor.sv

# ---- Visual smoke (no oracle, dumps PPMs only) ---------------------------
visual: $(BUILD_DIR)/tb_visual.vvp
	@echo "=== Visual ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_visual.log
	@grep -q '\*\*\* VISUAL OK \*\*\*' $(BUILD_DIR)/tb_visual.log || \
	    (echo "FAIL: tb_visual missing VISUAL OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_visual.log && \
	    (echo "FAIL: tb_visual reported a trap"; exit 1) || true
	@echo "PASS: tb_visual"

$(BUILD_DIR)/tb_visual.vvp: $(MODE_F_HDL) tb_visual.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_visual $(MODE_F_HDL) tb_visual.sv

$(BUILD_DIR):
	@mkdir -p $@

clean:
	rm -rf $(BUILD_DIR) visual/*.ppm
