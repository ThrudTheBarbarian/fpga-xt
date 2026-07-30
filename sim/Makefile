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

# Scan-out palette init for sims that instantiate antic_writeback/legacy_upscale
# (their palette_lut INIT_FILE defaults to the synth-root "hdl/palette/..." path;
# from sim/ it's one level up).  Loads the real Atari palette so the sim's
# code->RGB resolve matches hardware instead of warning + reading an empty LUT.
ANTIC_PAL_DEF := -D 'ANTIC_PALETTE_HEX="../hdl/palette/atari_ntsc.hex"'

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
    $(HDL_DIR)/display_shadow.sv  \
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
    $(HDL_DIR)/sally_clock.sv     \
    $(HDL_DIR)/bank_xlat.sv       \
    $(HDL_DIR)/sally_mem.sv       \
    $(HDL_DIR)/pcm1808_rx.sv      \
    $(HDL_DIR)/antic_raster.sv    \
    $(HDL_DIR)/antic_seq.sv       \
    $(HDL_DIR)/antic_top.sv       \
    $(HDL_DIR)/gtia_pm_collide.sv \
    $(HDL_DIR)/antic_dma_steal.sv \
    $(HDL_DIR)/cdc_sync_bit.sv

BUILD_DIR := build

.PHONY: antic_timing all smoke snoop read vbeam dl_parse prior nmi wsync palette dma_master mem_read_mux draw_regs pokey pokey_i2s sally sally_mem sally_mem_page sally_arb bank_xlat cdc_flag_data hwreg_rd_cdc legacy_upscale plane_compositor plane_fetch axi_line_writer antic_writeback xl_buffer_ctrl antic_raster antic_seq antic_modes cmp_fetch hscrol hscrol_e2e antic_display pia_regs peri_link joy_link joy_bridge peri_bridge os_rom_load klaus lint clean xt_blitter sally_stack sally_isa sprite_regs sprite_fetcher sprite_compositor xt6502 boot boot_trace plane_vscale disp_modef_wrap antic_dma_steal antic_dli antic_dli_cdc

# Retired tests (2026-05-25): rp_bus, mode_f, char_modes, gfx_modes, pm, scroll,
# dma_int, visual all instantiated the v1 rp_bus injection harness
# (rp_tx/rp_bus_mock) deleted in 2f3f03e.  The mode tests
# (char_modes/gfx_modes/pm/scroll/visual) additionally relied on the
# never-defined MODE_F_HDL var (empty -> even byte_ram/dl_parser/compositor went
# missing); rp_bus/mode_f were already dangling no-op phonies (their tbs were
# deleted too).  They drove ANTIC through the old serial-link mocks, superseded
# by the compositor model.  Removed from the build rather than reviving
# intentionally-deleted RTL.
all: smoke snoop read vbeam dl_parse prior nmi wsync palette dma_master mem_read_mux draw_regs pokey pokey_i2s sally sally_mem sally_mem_page sally_arb bank_xlat pia_regs pia_irq peri_link joy_link joy_bridge peri_bridge os_rom_load pbi pcm1808_rx xt_blitter sprite_regs sprite_fetcher sprite_compositor antic_raster antic_seq antic_modes xt6502 cdc_flag_data hwreg_rd_cdc

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

# hp2_rd_mux — shared-HP2 read arbiter (self-contained: only its own RTL)
hp2_mux: $(BUILD_DIR)/tb_hp2_rd_mux.vvp
	@echo "=== hp2_rd_mux — shared HP2 read arbiter ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hp2_rd_mux.log
	@grep -q '\*\*\* HP2_RD_MUX OK \*\*\*' $(BUILD_DIR)/tb_hp2_rd_mux.log || \
	    (echo "FAIL: tb_hp2_rd_mux missing HP2_RD_MUX OK"; exit 1)
	@echo "PASS: tb_hp2_rd_mux"

$(BUILD_DIR)/tb_hp2_rd_mux.vvp: $(HDL_DIR)/hp2_rd_mux.sv tb_hp2_rd_mux.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hp2_rd_mux $(HDL_DIR)/hp2_rd_mux.sv tb_hp2_rd_mux.sv

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


# ---- M7/M8/M9 (char_modes / gfx_modes / pm) — RETIRED 2026-05-25 ----------
# Depended on the deleted v1 rp_bus harness + undefined MODE_F_HDL.  See the
# retirement note above the `all:` target.

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

# ---- M11 — HSCROL / VSCROL — RETIRED 2026-05-25 (see note above `all:`) ---

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

# ---- XT register-unlock — mirror-conditional chiplet decode --------------
unlock: $(BUILD_DIR)/tb_unlock.vvp
	@echo "=== XT register-unlock ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_unlock.log
	@grep -q '\*\*\* UNLOCK OK \*\*\*' $(BUILD_DIR)/tb_unlock.log || \
	    (echo "FAIL: tb_unlock missing UNLOCK OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_unlock.log && \
	    (echo "FAIL: tb_unlock reported a trap"; exit 1) || true
	@echo "PASS: tb_unlock"

$(BUILD_DIR)/tb_unlock.vvp: $(HDL_DIR)/antic_regs.sv tb_unlock.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_unlock $(HDL_DIR)/antic_regs.sv tb_unlock.sv

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

# ---- M16-int-tb (dma_int) — RETIRED 2026-05-25 (see note above `all:`) ----

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

# ---- blitter_bridge -- GP0 AXI-Lite bridge -> blitter -> DDR (integration) ---
blitter_bridge: $(BUILD_DIR)/tb_blitter_bridge.vvp
	@echo "=== blitter_bridge ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_blitter_bridge.log

$(BUILD_DIR)/tb_blitter_bridge.vvp: $(HDL_DIR)/xt_blitter.sv $(HDL_DIR)/xt_gp0_pkg.sv $(HDL_DIR)/xt_gp0_regs.sv tb_blitter_bridge.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_blitter_bridge \
	    $(HDL_DIR)/xt_blitter.sv $(HDL_DIR)/xt_gp0_pkg.sv $(HDL_DIR)/xt_gp0_regs.sv tb_blitter_bridge.sv

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

# ---- M24-1 — xt6502 + REAL sally_mem integration -------------------------
# xt6502 paired with the production memory subsystem (banked DDR, hwreg,
# hidden stack, $0100-$01FF alias).  This is the CPU integration test
# (formerly the SALLY bring-up, now driving the only core).
SALLY_HDL := \
    $(HDL_DIR)/xt6502/xt6502.sv     \
    $(HDL_DIR)/bank_xlat.sv         \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv

sally: $(BUILD_DIR)/tb_sally.vvp
	@echo "=== M24-1 sally — xt6502 + sally_mem integration ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally.log
	@grep -q '\*\*\* SALLY OK \*\*\*' $(BUILD_DIR)/tb_sally.log || \
	    (echo "FAIL: tb_sally did not pass"; exit 1)
	@echo "PASS: tb_sally"

$(BUILD_DIR)/tb_sally.vvp: $(SALLY_HDL) tb_sally.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally $(SALLY_HDL) axi_slave_mem.sv tb_sally.sv

# ---- sally_stack — Stage A Increment 1 stack-BRAM alias test -------------
SALLY_STACK_HDL := \
    $(HDL_DIR)/bank_xlat.sv         \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv

# ---- xt6502 — clean-sheet Artix 6502 (task-0015), Phase 1 slice ----------
xt6502: $(BUILD_DIR)/tb_xt6502.vvp
	@echo "=== xt6502 — clean-sheet core (Phase 1 vertical slice) ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_xt6502.log
	@grep -q 'xt6502 PHASE1 OK' $(BUILD_DIR)/tb_xt6502.log || \
	    (echo "FAIL: tb_xt6502 phase-1 slice"; exit 1)
	@echo "PASS: tb_xt6502"

$(BUILD_DIR)/tb_xt6502.vvp: $(HDL_DIR)/xt6502/xt6502.sv tb_xt6502.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_xt6502 $(HDL_DIR)/xt6502/xt6502.sv tb_xt6502.sv

# ---- xt6502_debug — RETIRED with the turbo-core strip (2026-07-20) ----------
# The turbo core is now speed-only: its register-INJECT was removed, so this
# test (which drove dbg_wr/dbg_w* inject into the core) no longer applies.
# The in-fabric debugger lives on the fidelity core now — see the tb_xt6502f_*
# benches + the Harte harness for debug/interrupt coverage.

sally_stack: $(BUILD_DIR)/tb_sally_stack.vvp
	@echo "=== sally_stack — stack-BRAM alias test ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_stack.log
	@grep -q 'ALL TESTS PASSED' $(BUILD_DIR)/tb_sally_stack.log || \
	    (echo "FAIL: tb_sally_stack did not pass"; exit 1)
	@echo "PASS: tb_sally_stack"

$(BUILD_DIR)/tb_sally_stack.vvp: $(SALLY_STACK_HDL) tb_sally_stack.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_stack $(SALLY_STACK_HDL) tb_sally_stack.sv

# ---- sally_isa — 6502 ISA tests against xt6502 (small core+flat-mem harness)
# The 29-test embellishment suite (task-0016 step 5).  Self-contained: just the
# core + a flat-mem harness with the $0100-$01FF → $0F00-$0FFF stack alias.
sally_isa: $(BUILD_DIR)/tb_sally_isa.vvp
	@echo "=== sally_isa — xt6502 embellishment ISA tests ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_isa.log
	@grep -q 'ALL TESTS PASSED' $(BUILD_DIR)/tb_sally_isa.log || \
	    (echo "FAIL: tb_sally_isa did not pass"; exit 1)
	@echo "PASS: tb_sally_isa"

$(BUILD_DIR)/tb_sally_isa.vvp: $(HDL_DIR)/xt6502/xt6502.sv tb_sally_isa.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_isa $(HDL_DIR)/xt6502/xt6502.sv tb_sally_isa.sv

# ---- M24-klaus — Klaus Dormann 6502 functional test (xt6502) ------------
# Runs Klaus Dormann's full documented-opcode test against xt6502.  Drops
# Klaus test #$0E by design (the 12-bit SP is incompatible — see
# docs/6502/6502-embellishments.md §1).  Vendored binary at
# sim/test_data/6502_functional_test.bin (BSD, Klaus2m5/6502_65C02_functional_tests).
# The .hex file is generated from the .bin by `make test_data/6502_functional_test.hex`.
#
# Long-running — not in the default `all`. Exits early on stuck-PC.
klaus: $(BUILD_DIR)/tb_klaus.vvp test_data/6502_functional_test.hex
	@echo "=== M24-klaus Klaus Dormann functional test (xt6502) ==="
	# -i (interactive, unbuffered stdio) instead of -N: this run is many
	# minutes long, and with -N vvp's stdout is block-buffered when piped
	# to tee, so the [progress] pings + verdict don't appear until the end.
	# -i streams them live.  Safe here — the tb halts via $finish/$fatal
	# (never $stop), and </dev/null guarantees no interactive blocking.
	@$(VVP) -i $< </dev/null | tee $(BUILD_DIR)/tb_klaus.log
	@grep -q '\*\*\* KLAUS OK \*\*\*' $(BUILD_DIR)/tb_klaus.log || \
	    (echo "FAIL: tb_klaus did not reach success trap"; exit 1)
	@echo "PASS: tb_klaus"

KLAUS_HDL := $(HDL_DIR)/xt6502/xt6502.sv

$(BUILD_DIR)/tb_klaus.vvp: $(KLAUS_HDL) tb_klaus.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_klaus $(KLAUS_HDL) tb_klaus.sv

# .bin → .hex (one byte per line) for $readmemh.
test_data/6502_functional_test.hex: test_data/6502_functional_test.bin
	od -An -tx1 -v $< | tr -s ' ' '\n' | grep -v '^$$' > $@

# ---- boot — full-system Atari XL OS cold-start boot sim ------------------
# Instantiates the boot-relevant core of fpga_xt_top (CPU + sally_clock +
# sally_mem with the real OS ROM baked in via rsrc/sally-boot.hex + the hwreg
# CDC bridges + antic_top) and runs the OS cold-start, asserting boot
# milestones (PC→$C2xx, RAMTOP, RTCLOK advancing via VBLANK NMI, DMACTL/DLIST
# programmed).  Display/compositor/writeback/AXI are tied off or stubbed.
# Long-running (cold-start waits several VBLANK frames); not in `all`.
# Run with `make boot`.
#
# All antic_top sub-modules + the CPU/mem/CDC stack must be present so it
# elaborates.  axi_slave_mem.sv backs the sally_mem m_axi_* banked-window port.
BOOT_ANTIC_HDL := \
    $(HDL_DIR)/byte_ram.sv        \
    $(HDL_DIR)/byte_ram_dp.sv     \
    $(HDL_DIR)/bus_snoop.sv       \
    $(HDL_DIR)/antic_regs.sv      \
    $(HDL_DIR)/gtia_regs.sv       \
    $(HDL_DIR)/dl_parser.sv       \
    $(HDL_DIR)/compositor.sv      \
    $(HDL_DIR)/color_resolver.sv  \
    $(HDL_DIR)/nmi_gen.sv         \
    $(HDL_DIR)/wsync_gen.sv       \
    $(HDL_DIR)/dma_master.sv      \
    $(HDL_DIR)/dma_arbiter.sv     \
    $(HDL_DIR)/mem_read_mux.sv    \
    $(HDL_DIR)/bram_shim.sv       \
    $(HDL_DIR)/display_shadow.sv  \
    $(HDL_DIR)/draw_regs.sv       \
    $(HDL_DIR)/pia_regs.sv        \
    $(HDL_DIR)/peri_link.sv       \
    $(HDL_DIR)/peri_bridge.sv     \
    $(HDL_DIR)/joy_link.sv        \
    $(HDL_DIR)/joy_bridge.sv      \
    $(HDL_DIR)/pokey_regs.sv      \
    $(HDL_DIR)/pokey_audio.sv     \
    $(HDL_DIR)/pokey_pot.sv       \
    $(HDL_DIR)/pokey_i2s_tx.sv    \
    $(HDL_DIR)/pokey.sv           \
    $(HDL_DIR)/pcm1808_rx.sv      \
    $(HDL_DIR)/antic_raster.sv    \
    $(HDL_DIR)/antic_seq.sv       \
    $(HDL_DIR)/antic_top.sv       \
    $(HDL_DIR)/gtia_pm_collide.sv \
    $(HDL_DIR)/antic_dma_steal.sv

BOOT_SYS_HDL := \
    $(HDL_DIR)/sally_clock.sv     \
    $(HDL_DIR)/bank_xlat.sv       \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv       \
    $(HDL_DIR)/cdc_fifo_1w1r.sv   \
    $(HDL_DIR)/hwreg_rd_cdc.sv    \
    $(HDL_DIR)/cdc_sync_bit.sv

BOOT_CPU := \
    $(HDL_DIR)/xt6502/xt6502.sv

# sally_mem + banked_page_cache + banked_axi_reader carry verbose per-access
# $display tracing gated by `ifndef SYNTHESIS`.  In a multi-million-cycle boot
# run that spews ~2M lines and dominates wall time, so compile the boot sims
# with -D SYNTHESIS to suppress it.  (No positive `ifdef SYNTHESIS` exists in
# the boot HDL, and the OS-ROM $readmemh is ungated, so this only mutes the
# debug prints — behaviour is identical.)
BOOT_DEFINES := -D SYNTHESIS

boot: $(BUILD_DIR)/tb_boot.vvp rsrc_check
	@echo "=== boot — Atari XL OS cold-start (xt6502) ==="
	@$(VVP) -i $< </dev/null | tee $(BUILD_DIR)/tb_boot.log
	@grep -q '\*\*\* BOOT OK \*\*\*' $(BUILD_DIR)/tb_boot.log || \
	    (echo "FAIL: tb_boot did not reach all boot milestones"; exit 1)
	@echo "PASS: tb_boot"

$(BUILD_DIR)/tb_boot.vvp: $(BOOT_CPU) $(BOOT_SYS_HDL) $(BOOT_ANTIC_HDL) axi_slave_mem.sv peri_rp_idle.sv tb_boot.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) $(BOOT_DEFINES) -o $@ -s tb_boot \
	    $(BOOT_CPU) $(BOOT_SYS_HDL) $(BOOT_ANTIC_HDL) axi_slave_mem.sv peri_rp_idle.sv tb_boot.sv

# boot_trace — same as `boot` but with the xt6502 co-sim instruction-trace
# emitter enabled (-D COSIM_TRACE), writing /tmp/vvp_boot.trace for
# tools/cosim_diff.py to diff against /tmp/golden_*.trace.  Separate vvp so the
# plain `boot` stays fast (the trace adds a per-instruction $fwrite + a multi-MB
# output file).  Long-running; not in `all`.
boot_trace: $(BUILD_DIR)/tb_boot_trace.vvp rsrc_check
	@echo "=== boot_trace — Atari XL OS cold-start (xt6502) + co-sim trace ==="
	@$(VVP) -i $< </dev/null | tee $(BUILD_DIR)/tb_boot_trace.log
	@grep -q '\*\*\* BOOT OK \*\*\*' $(BUILD_DIR)/tb_boot_trace.log || \
	    (echo "FAIL: tb_boot_trace did not reach all boot milestones"; exit 1)
	@echo "PASS: tb_boot_trace -> /tmp/vvp_boot.trace"

$(BUILD_DIR)/tb_boot_trace.vvp: $(BOOT_CPU) $(BOOT_SYS_HDL) $(BOOT_ANTIC_HDL) axi_slave_mem.sv peri_rp_idle.sv tb_boot.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) $(BOOT_DEFINES) -D COSIM_TRACE -o $@ -s tb_boot \
	    $(BOOT_CPU) $(BOOT_SYS_HDL) $(BOOT_ANTIC_HDL) axi_slave_mem.sv peri_rp_idle.sv tb_boot.sv

.PHONY: rsrc_check
rsrc_check:
	@test -f ../rsrc/sally-boot.hex || \
	    (echo "FAIL: ../rsrc/sally-boot.hex missing (OS ROM image needed for boot sim)"; exit 1)

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

# Same testbench, PAGE backend (banked_page_cache) instead of the default LINE.
# Validates the page-cache fill path (the future backend; doesn't close timing yet).
sally_mem_page: $(BUILD_DIR)/tb_sally_mem_page.vvp
	@echo "=== sally_mem (PAGE backend) ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_mem_page.log
	@grep -q '\*\*\* SALLY_MEM OK \*\*\*' $(BUILD_DIR)/tb_sally_mem_page.log || \
	    (echo "FAIL: tb_sally_mem (PAGE) missing SALLY_MEM OK"; exit 1)
	@echo "PASS: tb_sally_mem (PAGE)"

$(BUILD_DIR)/tb_sally_mem_page.vvp: $(SALLY_MEM_HDL) tb_sally_mem.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -D SALLY_BANK_MODE='"PAGE"' -D PAGE_BACKEND -o $@ -s tb_sally_mem $(SALLY_MEM_HDL) axi_slave_mem.sv tb_sally_mem.sv

# ---- ROM-loader AXI-Lite write path (the OS-image upload window) --------
# Drives the Zynq PS ordering (AWVALID, wait AWREADY, THEN WVALID) that
# deadlocked the old FSM and hung the A9 on the window's first real use, plus
# the held-BREADY case that collapsed bvalid.  Both fixed 2026-07-17.
rom_loader: $(BUILD_DIR)/tb_sally_rom_loader.vvp
	@echo "=== sally_rom_loader (AXI write path) ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_rom_loader.log
	@grep -q '\*\*\* SALLY_ROM_LOADER OK \*\*\*' $(BUILD_DIR)/tb_sally_rom_loader.log || \
	    (echo "FAIL: tb_sally_rom_loader"; exit 1)
	@echo "PASS: tb_sally_rom_loader"

$(BUILD_DIR)/tb_sally_rom_loader.vvp: $(HDL_DIR)/sally_rom_loader.sv $(HDL_DIR)/cdc_fifo_1w1r.sv tb_sally_rom_loader.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_rom_loader $(HDL_DIR)/sally_rom_loader.sv $(HDL_DIR)/cdc_fifo_1w1r.sv tb_sally_rom_loader.sv

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
    $(HDL_DIR)/xt6502/xt6502.sv     \
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

# ---- cdc_flag_data — multi-bit data+toggle CDC primitive ----------------
cdc_flag_data: $(BUILD_DIR)/tb_cdc_flag_data.vvp
	@echo "=== cdc_flag_data — safe multi-bit CDC ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_cdc_flag_data.log
	@grep -q 'PASS: tb_cdc_flag_data' $(BUILD_DIR)/tb_cdc_flag_data.log || \
	    (echo "FAIL: tb_cdc_flag_data"; exit 1)
	@echo "PASS: tb_cdc_flag_data"

$(BUILD_DIR)/tb_cdc_flag_data.vvp: $(HDL_DIR)/cdc_flag_data.sv $(HDL_DIR)/cdc_sync_bit.sv tb_cdc_flag_data.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_cdc_flag_data $(HDL_DIR)/cdc_flag_data.sv $(HDL_DIR)/cdc_sync_bit.sv tb_cdc_flag_data.sv

# ---- legacy_upscale — 1080p pillarbox upscaler (boot gap 4b) ------------
legacy_upscale: $(BUILD_DIR)/tb_legacy_upscale.vvp
	@echo "=== legacy_upscale — 1080p pillarbox upscaler ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_legacy_upscale.log
	@grep -q '\*\*\* LEGACY_UPSCALE OK \*\*\*' $(BUILD_DIR)/tb_legacy_upscale.log || \
	    (echo "FAIL: tb_legacy_upscale missing LEGACY_UPSCALE OK"; exit 1)
	@echo "PASS: tb_legacy_upscale"

$(BUILD_DIR)/tb_legacy_upscale.vvp: $(HDL_DIR)/legacy_upscale.sv $(HDL_DIR)/palette_lut.sv tb_legacy_upscale.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) $(ANTIC_PAL_DEF) -o $@ -s tb_legacy_upscale $(HDL_DIR)/legacy_upscale.sv $(HDL_DIR)/palette_lut.sv tb_legacy_upscale.sv

# ---- plane_compositor — multi-plane compositor core (video arch phase 1) -
plane_compositor: $(BUILD_DIR)/tb_plane_compositor.vvp
	@echo "=== plane_compositor — multi-plane compositor core ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_plane_compositor.log
	@grep -q '\*\*\* PLANE_COMPOSITOR OK \*\*\*' $(BUILD_DIR)/tb_plane_compositor.log || \
	    (echo "FAIL: tb_plane_compositor missing PLANE_COMPOSITOR OK"; exit 1)
	@echo "PASS: tb_plane_compositor"

$(BUILD_DIR)/tb_plane_compositor.vvp: $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/vbeam.sv tb_plane_compositor.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_plane_compositor $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/vbeam.sv tb_plane_compositor.sv

alpha_hole: $(BUILD_DIR)/tb_alpha_hole.vvp
	@echo "=== alpha_hole — Route-A occlusion (alpha=0 hole reveals XL, opaque occluders hide it) ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_alpha_hole.log
	@grep -q '\*\*\* ALPHA_HOLE OK \*\*\*' $(BUILD_DIR)/tb_alpha_hole.log || \
	    (echo "FAIL: tb_alpha_hole missing ALPHA_HOLE OK"; exit 1)
	@echo "PASS: tb_alpha_hole"

$(BUILD_DIR)/tb_alpha_hole.vvp: $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/vbeam.sv tb_alpha_hole.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_alpha_hole $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/vbeam.sv tb_alpha_hole.sv

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
	$(IVERILOG) $(SV_FLAGS) $(ANTIC_PAL_DEF) -o $@ -s tb_antic_writeback $(HDL_DIR)/antic_writeback.sv $(HDL_DIR)/axi_line_writer.sv $(HDL_DIR)/palette_lut.sv axi_slave_mem.sv tb_antic_writeback.sv

# ---- plane_vscale — scan-out vertical row-addressing at scale 3 (integration) --
plane_vscale: $(BUILD_DIR)/tb_plane_vscale.vvp
	@echo "=== plane_vscale — scan-out vertical addressing (compositor+fetch) ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_plane_vscale.log
	@grep -q '\*\*\* PLANE_VSCALE OK \*\*\*' $(BUILD_DIR)/tb_plane_vscale.log || \
	    (echo "FAIL: tb_plane_vscale"; exit 1)
	@echo "PASS: tb_plane_vscale"

$(BUILD_DIR)/tb_plane_vscale.vvp: $(HDL_DIR)/vbeam.sv $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/plane_fetch.sv axi_slave_mem.sv tb_plane_vscale.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_plane_vscale $(HDL_DIR)/vbeam.sv $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/plane_fetch.sv axi_slave_mem.sv tb_plane_vscale.sv

# ---- disp_modef_wrap — GR.8 (mode F) right-edge horizontal-WRAP repro --------
# Drives plane_fetch+plane_compositor at the real XL config (scale 3) with
# src_w large enough that n_bursts > 1, exposing plane_fetch's stale-burst_idx
# AR address on burst 0 (right-edge source data lands at the left of the line
# buffer => the right bar ghosts onto the left).  FAILS on the buggy RTL.
disp_modef_wrap: $(BUILD_DIR)/tb_disp_modef_wrap.vvp
	@echo "=== disp_modef_wrap — GR.8 right-edge wrap (display path) ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_disp_modef_wrap.log
	@grep -q '\*\*\* DISP_MODEF_WRAP OK \*\*\*' $(BUILD_DIR)/tb_disp_modef_wrap.log || \
	    (echo "FAIL: tb_disp_modef_wrap"; exit 1)
	@echo "PASS: tb_disp_modef_wrap"

$(BUILD_DIR)/tb_disp_modef_wrap.vvp: $(HDL_DIR)/vbeam.sv $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/plane_fetch.sv axi_slave_mem.sv tb_disp_modef_wrap.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_disp_modef_wrap $(HDL_DIR)/vbeam.sv $(HDL_DIR)/plane_compositor.sv $(HDL_DIR)/plane_fetch.sv axi_slave_mem.sv tb_disp_modef_wrap.sv

# ---- antic_dma_steal — cycle-exact ANTIC DMA bus-steal model -----------------
antic_dma_steal: $(BUILD_DIR)/tb_antic_dma_steal.vvp
	@echo "=== antic_dma_steal — stolen cycles/scanline vs Altirra totals ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_dma_steal.log
	@grep -q '\*\*\* ANTIC_DMA_STEAL OK \*\*\*' $(BUILD_DIR)/tb_antic_dma_steal.log || \
	    (echo "FAIL: tb_antic_dma_steal"; exit 1)
	@echo "PASS: tb_antic_dma_steal"

$(BUILD_DIR)/tb_antic_dma_steal.vvp: $(HDL_DIR)/antic_dma_steal.sv tb_antic_dma_steal.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_dma_steal $(HDL_DIR)/antic_dma_steal.sv tb_antic_dma_steal.sv

# ---- xl_buffer_ctrl — ANTIC->DDR triple-buffer index controller (video-arch §5)
xl_buffer_ctrl: $(BUILD_DIR)/tb_xl_buffer_ctrl.vvp
	@echo "=== xl_buffer_ctrl — XL surface triple-buffer controller ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_xl_buffer_ctrl.log
	@grep -q '\*\*\* XL_BUFFER_CTRL OK \*\*\*' $(BUILD_DIR)/tb_xl_buffer_ctrl.log || \
	    (echo "FAIL: tb_xl_buffer_ctrl missing XL_BUFFER_CTRL OK"; exit 1)
	@echo "PASS: tb_xl_buffer_ctrl"

$(BUILD_DIR)/tb_xl_buffer_ctrl.vvp: $(HDL_DIR)/xl_buffer_ctrl.sv $(HDL_DIR)/cdc_sync_bit.sv tb_xl_buffer_ctrl.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_xl_buffer_ctrl $(HDL_DIR)/xl_buffer_ctrl.sv $(HDL_DIR)/cdc_sync_bit.sv tb_xl_buffer_ctrl.sv

# ---- antic_raster — phi2-paced native raster timer (video-arch §5.1) ------
antic_raster: $(BUILD_DIR)/tb_antic_raster.vvp
	@echo "=== antic_raster — phi2-paced native raster timer ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_raster.log
	@grep -q '\*\*\* ANTIC_RASTER OK \*\*\*' $(BUILD_DIR)/tb_antic_raster.log || \
	    (echo "FAIL: tb_antic_raster missing ANTIC_RASTER OK"; exit 1)
	@echo "PASS: tb_antic_raster"

$(BUILD_DIR)/tb_antic_raster.vvp: $(HDL_DIR)/antic_raster.sv tb_antic_raster.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_raster $(HDL_DIR)/antic_raster.sv tb_antic_raster.sv

# ---- antic_seq — phi2-raster render sequencer (video-arch §5.1, task-0014) -
# Integration of antic_raster -> antic_seq -> compositor (option (b)): asserts
# dl_start once/frame at vbi, cmp_start once per active scanline (gated on the
# parse), and the composed row advancing 0..191 in lockstep with line_start.
ANTIC_SEQ_HDL := \
    $(HDL_DIR)/antic_raster.sv  \
    $(HDL_DIR)/antic_seq.sv     \
    $(HDL_DIR)/compositor.sv

antic_seq: $(BUILD_DIR)/tb_antic_seq.vvp
	@echo "=== antic_seq — phi2-raster render sequencer ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_seq.log
	@grep -q '\*\*\* ANTIC_SEQ OK \*\*\*' $(BUILD_DIR)/tb_antic_seq.log || \
	    (echo "FAIL: tb_antic_seq missing ANTIC_SEQ OK"; exit 1)
	@echo "PASS: tb_antic_seq"

$(BUILD_DIR)/tb_antic_seq.vvp: $(ANTIC_SEQ_HDL) tb_antic_seq.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_seq $(ANTIC_SEQ_HDL) tb_antic_seq.sv

# ---- antic_modes — compositor per-mode pixel rendering (regression) -------
# Drives the compositor directly with a fake screen/char RAM and checks the
# per-pair SET stream against a software oracle for modes F / 2 / E.  Restores
# the playfield-mode coverage retired with the rp_bus-era mode tests.
antic_modes: $(BUILD_DIR)/tb_antic_modes.vvp
	@echo "=== antic_modes — compositor per-mode pixel rendering ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_modes.log
	@grep -q '\*\*\* ANTIC_MODES OK \*\*\*' $(BUILD_DIR)/tb_antic_modes.log || \
	    (echo "FAIL: tb_antic_modes missing ANTIC_MODES OK"; exit 1)
	@echo "PASS: tb_antic_modes"

$(BUILD_DIR)/tb_antic_modes.vvp: $(HDL_DIR)/compositor.sv tb_antic_modes.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_modes $(HDL_DIR)/compositor.sv tb_antic_modes.sv

# ---- cmp_fetch — INTEGRATION: compositor fetch through the REAL mem chain -
# Wires compositor + mem_read_mux + bram_shim + dma_arbiter + dma_master
# exactly as antic_top does, with a sally_mem-style registered dual-port RAM,
# and drives the acid800 antic_pmdma / antic_addresswrap scenarios through the
# real handshake.  Reproduces the HW $00/wrong-fetch that the mock (mem_ready=1,
# combinational RAM) and tb_mem_read_mux (sh_ready=1, no bram_shim) cannot.
CMP_FETCH_HDL := $(HDL_DIR)/compositor.sv $(HDL_DIR)/mem_read_mux.sv \
                 $(HDL_DIR)/bram_shim.sv $(HDL_DIR)/dma_arbiter.sv \
                 $(HDL_DIR)/dma_master.sv
cmp_fetch: $(BUILD_DIR)/tb_cmp_fetch.vvp
	@echo "=== cmp_fetch — compositor fetch through the real mem chain ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_cmp_fetch.log
	@grep -q '\*\*\* CMP_FETCH OK \*\*\*' $(BUILD_DIR)/tb_cmp_fetch.log || \
	    (echo "FAIL: tb_cmp_fetch missing CMP_FETCH OK"; exit 1)
	@echo "PASS: tb_cmp_fetch"

$(BUILD_DIR)/tb_cmp_fetch.vvp: $(CMP_FETCH_HDL) tb_cmp_fetch.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_cmp_fetch $(CMP_FETCH_HDL) tb_cmp_fetch.sv

# ---- hscrol — HSCROL fine sub-pixel scroll (compositor, exhaustive) --------
# Drives the compositor directly with meta_hscrol_en=1 and hscrol=0..15 for
# modes 2 & 4 over pseudo-random content, checking every displayed atari px
# against source[x + 2*hscrol].  Proves the fine shift is applied smoothly (2
# atari px / hscrol step) and never byte-granular.  Not in `all`.
hscrol: $(BUILD_DIR)/tb_hscrol.vvp
	@echo "=== hscrol — compositor fine sub-pixel scroll ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hscrol.log
	@grep -q '\*\*\* HSCROL OK \*\*\*' $(BUILD_DIR)/tb_hscrol.log || \
	    (echo "FAIL: tb_hscrol missing HSCROL OK"; exit 1)
	@echo "PASS: tb_hscrol"

$(BUILD_DIR)/tb_hscrol.vvp: $(HDL_DIR)/compositor.sv tb_hscrol.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hscrol $(HDL_DIR)/compositor.sv tb_hscrol.sv

# ---- hscrol_e2e — HSCROL enable path (dl_parser -> compositor) -------------
# Parses a real DL with a mode-4 + HSCROL line, then composes it for several
# live hscrol values, proving DL bit-4 -> meta_hscrol_en turns on the fine
# window and the value shifts smoothly end-to-end.  Not in `all`.
hscrol_e2e: $(BUILD_DIR)/tb_hscrol_e2e.vvp
	@echo "=== hscrol_e2e — dl_parser -> compositor HSCROL enable path ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hscrol_e2e.log
	@grep -q '\*\*\* HSCROL_E2E OK \*\*\*' $(BUILD_DIR)/tb_hscrol_e2e.log || \
	    (echo "FAIL: tb_hscrol_e2e missing HSCROL_E2E OK"; exit 1)
	@echo "PASS: tb_hscrol_e2e"

$(BUILD_DIR)/tb_hscrol_e2e.vvp: $(HDL_DIR)/compositor.sv $(HDL_DIR)/dl_parser.sv tb_hscrol_e2e.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hscrol_e2e $(HDL_DIR)/compositor.sv $(HDL_DIR)/dl_parser.sv tb_hscrol_e2e.sv

# ---- antic_display — end-to-end ANTIC display path (integration) ----------
# Drives the real antic_top (DL + screen in a memory model on its bram port,
# registers over the snoop bus) and checks the §5 render-tap output: frame
# cadence, per-scanline row walk, and row-0 mode-F pixels vs COLPF2/COLBK.
# De-risks the memory->parse->sequence->compose->colour->tap chain.  Heavy
# (runs ~1.1 emulated frames); not in `all` — run with `make antic_display`.
antic_display: $(BUILD_DIR)/tb_antic_display.vvp
	@echo "=== antic_display — end-to-end ANTIC display path ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_display.log
	@grep -q '\*\*\* ANTIC_DISPLAY OK \*\*\*' $(BUILD_DIR)/tb_antic_display.log || \
	    (echo "FAIL: tb_antic_display missing ANTIC_DISPLAY OK"; exit 1)
	@echo "PASS: tb_antic_display"

$(BUILD_DIR)/tb_antic_display.vvp: $(HDL_SRCS) tb_antic_display.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_display $(HDL_SRCS) tb_antic_display.sv

# ---- antic_dli — DLI fires on correct PHYSICAL scanline (integrated) -----
antic_dli: $(BUILD_DIR)/tb_antic_dli.vvp
	@echo "=== antic_dli — physical-scanline DLI integration ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_dli.log
	@grep -q '\*\*\* ANTIC_DLI OK \*\*\*' $(BUILD_DIR)/tb_antic_dli.log || \
	    (echo "FAIL: tb_antic_dli missing ANTIC_DLI OK"; exit 1)
	@echo "PASS: tb_antic_dli"

$(BUILD_DIR)/tb_antic_dli.vvp: $(HDL_SRCS) tb_antic_dli.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_dli $(HDL_SRCS) tb_antic_dli.sv

# ---- antic_dli_cdc — DLI coincidence via the REAL clk_sally->CDC->clk_sys --
# register-write path (reproduces / refutes the HW-proven ACID800 antic_nmist
# DLI failure).  Drives NMIEN through cdc_fifo_1w1r + the fpga_xt_top write-
# strobe regen pipeline instead of the snoop bus.  Passes on EITHER verdict
# (BUG-REPRODUCED or NOT-REPRODUCED) — it's a diagnostic bench; it only fails
# on INCONCLUSIVE (write lost) or watchdog.
# ---- antic_timing — the cycle-serial ANTIC timing machine (directed) ------
$(BUILD_DIR)/tb_antic_timing.vvp: ../hdl/antic_timing.sv tb_antic_timing.sv | $(BUILD_DIR)
	iverilog -g2012 -Wall -Wno-timescale -I../hdl -o $@ -s tb_antic_timing $^

antic_timing: $(BUILD_DIR)/tb_antic_timing.vvp
	@vvp -N $< | tee /dev/stderr | grep -q "ANTIC_TIMING OK" && echo "PASS: tb_antic_timing" || (echo "FAIL: tb_antic_timing" ; exit 1)

antic_dli_cdc: $(BUILD_DIR)/tb_antic_dli_cdc.vvp
	@echo "=== antic_dli_cdc — DLI coincidence through the register-write CDC ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_antic_dli_cdc.log
	@grep -Eq 'ANTIC_DLI_CDC: (BUG-REPRODUCED|NOT-REPRODUCED)' $(BUILD_DIR)/tb_antic_dli_cdc.log || \
	    (echo "FAIL: tb_antic_dli_cdc inconclusive / did not finish"; exit 1)
	@echo "PASS: tb_antic_dli_cdc (see verdict above)"

$(BUILD_DIR)/tb_antic_dli_cdc.vvp: $(HDL_SRCS) $(HDL_DIR)/cdc_fifo_1w1r.sv tb_antic_dli_cdc.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_antic_dli_cdc $(HDL_SRCS) $(HDL_DIR)/cdc_fifo_1w1r.sv tb_antic_dli_cdc.sv

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

# ---- ACID800 pia_irq — 6821 CA2/CB2 interrupt-flag vectors --------------
pia_irq: $(BUILD_DIR)/tb_pia_irq.vvp
	@echo "=== ACID800 pia_irq vectors ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pia_irq.log
	@grep -q '\*\*\* PIA IRQ OK \*\*\*' $(BUILD_DIR)/tb_pia_irq.log || \
	    (echo "FAIL: tb_pia_irq missing PIA IRQ OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_pia_irq.log && \
	    (echo "FAIL: tb_pia_irq reported a trap"; exit 1) || true
	@echo "PASS: tb_pia_irq"

$(BUILD_DIR)/tb_pia_irq.vvp: $(HDL_DIR)/pia_regs.sv tb_pia_irq.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pia_irq $(HDL_DIR)/pia_regs.sv tb_pia_irq.sv

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

# ---- screen_bank — dual CPU/ANTIC banked screen RAM -----------------------
SCREEN_BANK_HDL := \
    $(HDL_DIR)/cdc_sync_bit.sv \
    $(HDL_DIR)/screen_bank.sv

screen_bank: $(BUILD_DIR)/tb_screen_bank.vvp
	@echo "=== screen_bank ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_screen_bank.log
	@grep -q '\*\*\* SCREEN_BANK OK \*\*\*' $(BUILD_DIR)/tb_screen_bank.log || \
	    (echo "FAIL: tb_screen_bank missing SCREEN_BANK OK"; exit 1)
	@grep -q 'FATAL\|FAIL' $(BUILD_DIR)/tb_screen_bank.log && \
	    (echo "FAIL: tb_screen_bank reported a failure"; exit 1) || true
	@echo "PASS: tb_screen_bank"

$(BUILD_DIR)/tb_screen_bank.vvp: $(SCREEN_BANK_HDL) tb_screen_bank.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_screen_bank $(SCREEN_BANK_HDL) tb_screen_bank.sv

# ---- math_cop — math-coprocessor mailbox page ------------------------------
MATHCOP_HDL := \
    $(HDL_DIR)/cdc_sync_bit.sv \
    $(HDL_DIR)/math_cop.sv

mathcop: $(BUILD_DIR)/tb_mathcop.vvp
	@echo "=== mathcop ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_mathcop.log
	@grep -q '\*\*\* MATHCOP OK \*\*\*' $(BUILD_DIR)/tb_mathcop.log || \
	    (echo "FAIL: tb_mathcop missing MATHCOP OK"; exit 1)
	@grep -q 'FATAL\|FAIL' $(BUILD_DIR)/tb_mathcop.log && \
	    (echo "FAIL: tb_mathcop reported a failure"; exit 1) || true
	@echo "PASS: tb_mathcop"

$(BUILD_DIR)/tb_mathcop.vvp: $(MATHCOP_HDL) tb_mathcop.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_mathcop $(MATHCOP_HDL) tb_mathcop.sv

# ---- gp0_mux — math_cop + screen_bank sharing S_AXI_GP0 (integration) -------
GP0MUX_HDL := \
    $(HDL_DIR)/cdc_sync_bit.sv \
    $(HDL_DIR)/math_cop.sv \
    $(HDL_DIR)/screen_bank.sv \
    $(HDL_DIR)/gp0_axi_mux.sv

gp0_mux: $(BUILD_DIR)/tb_gp0_mux.vvp
	@echo "=== gp0_mux ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_gp0_mux.log
	@grep -q '\*\*\* GP0MUX OK \*\*\*' $(BUILD_DIR)/tb_gp0_mux.log || \
	    (echo "FAIL: tb_gp0_mux missing GP0MUX OK"; exit 1)
	@grep -q 'FATAL\|FAIL' $(BUILD_DIR)/tb_gp0_mux.log && \
	    (echo "FAIL: tb_gp0_mux reported a failure"; exit 1) || true
	@echo "PASS: tb_gp0_mux"

$(BUILD_DIR)/tb_gp0_mux.vvp: $(GP0MUX_HDL) tb_gp0_mux.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_gp0_mux $(GP0MUX_HDL) tb_gp0_mux.sv

# ---- sally_math_overlay — sally_mem + real math_cop overlay READ round-trip -
# Integration TB for the math-page overlay on $4000-$5FFF: exercises the
# rdy-gated read-after-write pipeline WITH stall cycles (the case tb_mathcop and
# tb_gp0_mux never hit).  `make sally_math_overlay_bug` builds the repro variant
# (cpu_rden tied high = the old free-running read) to demonstrate the HW failure.
SALLY_MATH_OVL_HDL := \
    $(HDL_DIR)/bank_xlat.sv \
    $(HDL_DIR)/banked_axi_reader.sv \
    $(HDL_DIR)/banked_page_cache.sv \
    $(HDL_DIR)/sally_mem.sv \
    $(HDL_DIR)/cdc_sync_bit.sv \
    $(HDL_DIR)/math_cop.sv

sally_math_overlay: $(BUILD_DIR)/tb_sally_math_overlay.vvp
	@echo "=== sally_math_overlay ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_sally_math_overlay.log
	@grep -q '\*\*\* SALLY_MATH_OVERLAY OK \*\*\*' $(BUILD_DIR)/tb_sally_math_overlay.log || \
	    (echo "FAIL: tb_sally_math_overlay missing SALLY_MATH_OVERLAY OK"; exit 1)
	@grep -q 'FATAL\|FAIL' $(BUILD_DIR)/tb_sally_math_overlay.log && \
	    (echo "FAIL: tb_sally_math_overlay reported a failure"; exit 1) || true
	@echo "PASS: tb_sally_math_overlay"

$(BUILD_DIR)/tb_sally_math_overlay.vvp: $(SALLY_MATH_OVL_HDL) tb_sally_math_overlay.sv axi_slave_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_math_overlay $(SALLY_MATH_OVL_HDL) axi_slave_mem.sv tb_sally_math_overlay.sv

# Repro build: cpu_rden hard-tied high (== the pre-fix free-running read).  The
# stalled read returns the stale neighbour word, so the repro assertion fires.
sally_math_overlay_bug: $(SALLY_MATH_OVL_HDL) tb_sally_math_overlay.sv axi_slave_mem.sv | $(BUILD_DIR)
	@echo "=== sally_math_overlay (BUG REPRO) ==="
	$(IVERILOG) $(SV_FLAGS) -D MATH_RDEN_FREE -o $(BUILD_DIR)/tb_sally_math_overlay_bug.vvp \
	    -s tb_sally_math_overlay $(SALLY_MATH_OVL_HDL) axi_slave_mem.sv tb_sally_math_overlay.sv
	@$(VVP) -N $(BUILD_DIR)/tb_sally_math_overlay_bug.vvp | tee $(BUILD_DIR)/tb_sally_math_overlay_bug.log

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

# ---- Visual smoke — RETIRED 2026-05-25 (see note above `all:`) -----------

$(BUILD_DIR):
	@mkdir -p $@

clean:
	rm -rf $(BUILD_DIR) visual/*.ppm

# ---- FID-core vs raster co-sim (WSYNC/NMIST cycle calibration) ----------
fid_raster: $(BUILD_DIR)/tb_fid_raster.vvp
	@echo "=== fid_raster (cycle calibration) ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_fid_raster.log
	@grep -q 'FID_RASTER done' $(BUILD_DIR)/tb_fid_raster.log || \
	    (echo "FAIL: tb_fid_raster did not complete"; exit 1)
	@echo "PASS: tb_fid_raster"

$(BUILD_DIR)/tb_fid_raster.vvp: $(BOOT_CPU) $(BOOT_SYS_HDL) $(BOOT_ANTIC_HDL) $(HDL_DIR)/xt6502f/xt6502f.sv $(HDL_DIR)/antic_timing.sv axi_slave_mem.sv peri_rp_idle.sv tb_fid_raster.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) $(BOOT_DEFINES) -o $@ -s tb_fid_raster \
	    $(BOOT_CPU) $(BOOT_SYS_HDL) $(BOOT_ANTIC_HDL) $(HDL_DIR)/xt6502f/xt6502f.sv $(HDL_DIR)/antic_timing.sv axi_slave_mem.sv peri_rp_idle.sv tb_fid_raster.sv

pm_collide: build/tb_pm_collide.vvp
	@vvp -N $<

build/tb_pm_collide.vvp: tb_pm_collide.sv $(HDL_DIR)/gtia_pm_collide.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_pm_collide \
	    $(HDL_DIR)/gtia_pm_collide.sv tb_pm_collide.sv

gtia_stream: build/tb_gtia_stream.vvp
	@vvp -N $<

build/tb_gtia_stream.vvp: tb_gtia_stream.sv $(HDL_DIR)/gtia_stream.sv $(HDL_DIR)/color_resolver.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_gtia_stream \
	    $(HDL_DIR)/gtia_stream.sv $(HDL_DIR)/color_resolver.sv tb_gtia_stream.sv

pokey_serial: build/tb_pokey_serial.vvp
	@vvp -N $<

build/tb_pokey_serial.vvp: tb_pokey_serial.sv $(HDL_DIR)/pokey_serial.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_pokey_serial \
	    $(HDL_DIR)/pokey_serial.sv tb_pokey_serial.sv

pf_serial: build/tb_pf_serial.vvp
	@vvp -N $<

build/tb_pf_serial.vvp: tb_pf_serial.sv $(HDL_DIR)/antic_pf_serial.sv $(HDL_DIR)/gtia_stream.sv $(HDL_DIR)/color_resolver.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_pf_serial \
	    $(HDL_DIR)/antic_pf_serial.sv $(HDL_DIR)/gtia_stream.sv \
	    $(HDL_DIR)/color_resolver.sv tb_pf_serial.sv

antic_line_buf: build/tb_antic_line_buf.vvp
	@vvp -N $<

build/tb_antic_line_buf.vvp: tb_antic_line_buf.sv $(HDL_DIR)/antic_line_buf.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_line_buf \
	    $(HDL_DIR)/antic_line_buf.sv tb_antic_line_buf.sv

antic_expander: build/tb_antic_expander.vvp
	@vvp -N $<

build/tb_antic_expander.vvp: tb_antic_expander.sv $(HDL_DIR)/antic_expander.sv $(HDL_DIR)/antic_line_buf.sv $(HDL_DIR)/palette_lut.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_expander \
	    $(HDL_DIR)/antic_expander.sv $(HDL_DIR)/antic_line_buf.sv \
	    $(HDL_DIR)/palette_lut.sv tb_antic_expander.sv

antic_mode_tbl: build/tb_antic_mode_tbl.vvp
	@vvp -N $<

build/tb_antic_mode_tbl.vvp: tb_antic_mode_tbl.sv $(HDL_DIR)/antic_mode_tbl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_mode_tbl \
	    $(HDL_DIR)/antic_mode_tbl.sv tb_antic_mode_tbl.sv

antic_pixel_shift: build/tb_antic_pixel_shift.vvp
	@vvp -N $<

build/tb_antic_pixel_shift.vvp: tb_antic_pixel_shift.sv $(HDL_DIR)/antic_pixel_shift.sv $(HDL_DIR)/antic_mode_tbl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_pixel_shift \
	    $(HDL_DIR)/antic_pixel_shift.sv $(HDL_DIR)/antic_mode_tbl.sv tb_antic_pixel_shift.sv

antic_pf_source: build/tb_antic_pf_source.vvp
	@vvp -N $<

build/tb_antic_pf_source.vvp: tb_antic_pf_source.sv $(HDL_DIR)/antic_pf_source.sv $(HDL_DIR)/antic_mode_tbl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_pf_source \
	    $(HDL_DIR)/antic_pf_source.sv $(HDL_DIR)/antic_mode_tbl.sv tb_antic_pf_source.sv

antic_color_sel: build/tb_antic_color_sel.vvp
	@vvp -N $<

build/tb_antic_color_sel.vvp: tb_antic_color_sel.sv $(HDL_DIR)/antic_color_sel.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_color_sel \
	    $(HDL_DIR)/antic_color_sel.sv tb_antic_color_sel.sv

antic_line_render: build/tb_antic_line_render.vvp
	@vvp -N $<

build/tb_antic_line_render.vvp: tb_antic_line_render.sv $(HDL_DIR)/antic_line_render.sv $(HDL_DIR)/antic_mode_tbl.sv $(HDL_DIR)/antic_pixel_shift.sv $(HDL_DIR)/antic_pf_source.sv $(HDL_DIR)/antic_color_sel.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_line_render \
	    $(HDL_DIR)/antic_line_render.sv $(HDL_DIR)/antic_pf_fetch.sv \
	    $(HDL_DIR)/antic_mode_tbl.sv \
	    $(HDL_DIR)/antic_pixel_shift.sv $(HDL_DIR)/antic_pf_source.sv \
	    $(HDL_DIR)/antic_color_sel.sv $(HDL_DIR)/antic_char_ctl.sv \
	    tb_antic_line_render.sv

antic_beam: build/tb_antic_beam.vvp
	@vvp -N $<

build/tb_antic_beam.vvp: tb_antic_beam.sv $(HDL_DIR)/antic_beam.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_beam \
	    $(HDL_DIR)/antic_beam.sv tb_antic_beam.sv

antic_dl: build/tb_antic_dl.vvp
	@vvp -N $<

build/tb_antic_dl.vvp: tb_antic_dl.sv $(HDL_DIR)/antic_dl.sv \
	    $(HDL_DIR)/antic_mode_tbl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_dl \
	    $(HDL_DIR)/antic_dl.sv $(HDL_DIR)/antic_mode_tbl.sv tb_antic_dl.sv

antic_pf_geom: build/tb_antic_pf_geom.vvp
	@vvp -N $<

build/tb_antic_pf_geom.vvp: tb_antic_pf_geom.sv $(HDL_DIR)/antic_pf_geom.sv \
	    $(HDL_DIR)/antic_mode_tbl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_pf_geom \
	    $(HDL_DIR)/antic_pf_geom.sv $(HDL_DIR)/antic_mode_tbl.sv tb_antic_pf_geom.sv

antic_char_ctl: build/tb_antic_char_ctl.vvp
	@vvp -N $<

build/tb_antic_char_ctl.vvp: tb_antic_char_ctl.sv $(HDL_DIR)/antic_char_ctl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_char_ctl \
	    $(HDL_DIR)/antic_char_ctl.sv tb_antic_char_ctl.sv

antic_pf_fetch: build/tb_antic_pf_fetch.vvp
	@vvp -N $<

build/tb_antic_pf_fetch.vvp: tb_antic_pf_fetch.sv $(HDL_DIR)/antic_pf_fetch.sv \
	    $(HDL_DIR)/antic_mode_tbl.sv $(HDL_DIR)/antic_char_ctl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_pf_fetch \
	    $(HDL_DIR)/antic_pf_fetch.sv $(HDL_DIR)/antic_mode_tbl.sv \
	    $(HDL_DIR)/antic_char_ctl.sv tb_antic_pf_fetch.sv

antic_scanline: build/tb_antic_scanline.vvp
	@vvp -N $<

build/tb_antic_scanline.vvp: tb_antic_scanline.sv $(HDL_DIR)/antic_scanline.sv \
	    $(HDL_DIR)/antic_beam.sv $(HDL_DIR)/antic_dl.sv \
	    $(HDL_DIR)/antic_pf_geom.sv $(HDL_DIR)/antic_pf_fetch.sv \
	    $(HDL_DIR)/antic_line_render.sv $(HDL_DIR)/antic_line_buf.sv \
	    $(HDL_DIR)/antic_mode_tbl.sv $(HDL_DIR)/antic_pixel_shift.sv \
	    $(HDL_DIR)/antic_pf_source.sv $(HDL_DIR)/antic_color_sel.sv \
	    $(HDL_DIR)/antic_char_ctl.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_scanline \
	    $(HDL_DIR)/antic_scanline.sv $(HDL_DIR)/antic_beam.sv \
	    $(HDL_DIR)/antic_dl.sv $(HDL_DIR)/antic_pf_geom.sv \
	    $(HDL_DIR)/antic_pf_fetch.sv $(HDL_DIR)/antic_line_render.sv \
	    $(HDL_DIR)/antic_line_buf.sv $(HDL_DIR)/antic_mode_tbl.sv \
	    $(HDL_DIR)/antic_pixel_shift.sv $(HDL_DIR)/antic_pf_source.sv \
	    $(HDL_DIR)/antic_color_sel.sv $(HDL_DIR)/antic_char_ctl.sv \
	    tb_antic_scanline.sv

antic_pm_fetch: build/tb_antic_pm_fetch.vvp
	@vvp -N $<

build/tb_antic_pm_fetch.vvp: tb_antic_pm_fetch.sv $(HDL_DIR)/antic_pm_fetch.sv | build
	iverilog -g2012 -Wall -Wno-timescale -I$(HDL_DIR) -o $@ -s tb_antic_pm_fetch \
	    $(HDL_DIR)/antic_pm_fetch.sv tb_antic_pm_fetch.sv
