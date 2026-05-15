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
    $(HDL_DIR)/rp_tx.sv           \
    $(HDL_DIR)/nmi_gen.sv         \
    $(HDL_DIR)/wsync_gen.sv       \
    $(HDL_DIR)/palette_lut.sv     \
    $(HDL_DIR)/dma_master.sv      \
    $(HDL_DIR)/dma_arbiter.sv     \
    $(HDL_DIR)/mem_read_mux.sv    \
    $(HDL_DIR)/hyperram_mock.sv   \
    $(HDL_DIR)/hyperram_shim.sv   \
    $(HDL_DIR)/draw_regs.sv       \
    $(HDL_DIR)/pssi_tx.sv         \
    $(HDL_DIR)/pssi_bytes.sv      \
    $(HDL_DIR)/cache_regs.sv      \
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
    $(HDL_DIR)/bank_cache.sv      \
    $(HDL_DIR)/cache_line_ram.sv  \
    $(HDL_DIR)/sally_mem.sv       \
    $(HDL_DIR)/bank_translator.sv \
    $(HDL_DIR)/line_buffer.sv     \
    $(HDL_DIR)/scan_out.sv        \
    $(HDL_DIR)/prefetch.sv        \
    $(HDL_DIR)/tmds_encoder.sv    \
    $(HDL_DIR)/tmds_serializer.sv \
    $(HDL_DIR)/terc4_encoder.sv   \
    $(HDL_DIR)/hdmi_bch.sv        \
    $(HDL_DIR)/hdmi_packet.sv     \
    $(HDL_DIR)/hdmi_pkt_source.sv \
    $(HDL_DIR)/hdmi_out.sv        \
    $(HDL_DIR)/pcm1808_rx.sv      \
    $(HDL_DIR)/antic_top.sv

BUILD_DIR := build

.PHONY: all smoke snoop read vbeam rp_bus prefetch dl_parse mode_f char_modes gfx_modes pm prior scroll nmi wsync palette tmds tmds_out terc4 hdmi_bch hdmi_pkt hdmi_out dma_master mem_read_mux dma_int hyperram bank draw draw_regs pokey pokey_i2s sally sally_mem sally_arb bank_cache bank_xlat cache_regs cache_partition pia_regs peri_link joy_link joy_bridge peri_bridge os_rom_load klaus visual lint clean pssi_tx pssi_int xt_blitter

all: smoke snoop read vbeam rp_bus prefetch dl_parse mode_f char_modes gfx_modes pm prior scroll nmi wsync palette tmds tmds_out terc4 hdmi_bch hdmi_pkt hdmi_out dma_master mem_read_mux dma_int hyperram bank draw draw_regs pokey pokey_i2s sally sally_mem sally_arb bank_cache bank_xlat cache_regs cache_partition pia_regs peri_link joy_link joy_bridge peri_bridge os_rom_load pbi pcm1808_rx visual pssi_tx pssi_int xt_blitter

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
VERILATOR_TOPS := antic_top vbeam rp_tx rp_rx rp_bus_mock bus_snoop antic_regs gtia_regs cache_regs byte_ram byte_ram_dp

LINT_SRCS := $(filter-out $(HDL_DIR)/hyperram_phy.sv,$(wildcard $(HDL_DIR)/*.sv))

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

# ---- M3 — FPGA<->RP paired sim --------------------------------------------
RP_BUS_HDL := \
    $(HDL_DIR)/rp_tx.sv        \
    $(HDL_DIR)/rp_rx.sv        \
    $(HDL_DIR)/rp_bus_mock.sv

rp_bus: $(BUILD_DIR)/tb_rp_bus.vvp
	@echo "=== M3 rp_bus ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_rp_bus.log
	@grep -q '\*\*\* RP_BUS OK \*\*\*' $(BUILD_DIR)/tb_rp_bus.log || \
	    (echo "FAIL: tb_rp_bus missing RP_BUS OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_rp_bus.log && \
	    (echo "FAIL: tb_rp_bus reported a trap"; exit 1) || true
	@echo "PASS: tb_rp_bus"

$(BUILD_DIR)/tb_rp_bus.vvp: $(RP_BUS_HDL) tb_rp_bus.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_rp_bus $(RP_BUS_HDL) tb_rp_bus.sv

# ---- M4 — line-buffer prefetch loop --------------------------------------
PREFETCH_HDL := \
    $(HDL_DIR)/vbeam.sv          \
    $(HDL_DIR)/line_buffer.sv    \
    $(HDL_DIR)/prefetch.sv       \
    $(HDL_DIR)/scan_out.sv       \
    $(HDL_DIR)/rp_tx.sv          \
    $(HDL_DIR)/rp_rx.sv          \
    $(HDL_DIR)/rp_bus_mock.sv

prefetch: $(BUILD_DIR)/tb_prefetch.vvp
	@echo "=== M4 prefetch ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_prefetch.log
	@grep -q '\*\*\* PREFETCH OK \*\*\*' $(BUILD_DIR)/tb_prefetch.log || \
	    (echo "FAIL: tb_prefetch missing PREFETCH OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_prefetch.log && \
	    (echo "FAIL: tb_prefetch reported a trap"; exit 1) || true
	@echo "PASS: tb_prefetch"

$(BUILD_DIR)/tb_prefetch.vvp: $(PREFETCH_HDL) tb_prefetch.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_prefetch $(PREFETCH_HDL) tb_prefetch.sv

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

# ---- M6 — mode-F compositor pipeline -------------------------------------
MODE_F_HDL := \
    $(HDL_DIR)/byte_ram.sv       \
    $(HDL_DIR)/dl_parser.sv      \
    $(HDL_DIR)/compositor.sv     \
    $(HDL_DIR)/rp_tx.sv          \
    $(HDL_DIR)/rp_bus_mock.sv

mode_f: $(BUILD_DIR)/tb_mode_f.vvp
	@echo "=== M6 mode_f ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_mode_f.log
	@grep -q '\*\*\* MODE_F OK \*\*\*' $(BUILD_DIR)/tb_mode_f.log || \
	    (echo "FAIL: tb_mode_f missing MODE_F OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_mode_f.log && \
	    (echo "FAIL: tb_mode_f reported a trap"; exit 1) || true
	@echo "PASS: tb_mode_f"

$(BUILD_DIR)/tb_mode_f.vvp: $(MODE_F_HDL) tb_mode_f.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_mode_f $(MODE_F_HDL) tb_mode_f.sv

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

# ---- M14b — TMDS encoder -------------------------------------------------
tmds: $(BUILD_DIR)/tb_tmds.vvp
	@echo "=== M14b tmds ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_tmds.log
	@grep -q '\*\*\* TMDS OK \*\*\*' $(BUILD_DIR)/tb_tmds.log || \
	    (echo "FAIL: tb_tmds missing TMDS OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_tmds.log && \
	    (echo "FAIL: tb_tmds reported a trap"; exit 1) || true
	@echo "PASS: tb_tmds"

TMDS_HDL := \
    $(HDL_DIR)/tmds_encoder.sv     \
    $(HDL_DIR)/tmds_serializer.sv

$(BUILD_DIR)/tb_tmds.vvp: $(TMDS_HDL) tb_tmds.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_tmds $(TMDS_HDL) tb_tmds.sv

# ---- M15 — TMDS-output integration (vbeam + 3 encoders + 4 serializers) ----
tmds_out: $(BUILD_DIR)/tb_tmds_out.vvp
	@echo "=== M15 tmds_out ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_tmds_out.log
	@grep -q '\*\*\* TMDS_OUT OK \*\*\*' $(BUILD_DIR)/tb_tmds_out.log || \
	    (echo "FAIL: tb_tmds_out missing TMDS_OUT OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_tmds_out.log && \
	    (echo "FAIL: tb_tmds_out reported a trap"; exit 1) || true
	@echo "PASS: tb_tmds_out"

TMDS_OUT_HDL := \
    $(HDL_DIR)/vbeam.sv            \
    $(HDL_DIR)/tmds_encoder.sv     \
    $(HDL_DIR)/tmds_serializer.sv  \
    $(HDL_DIR)/tmds_out.sv

$(BUILD_DIR)/tb_tmds_out.vvp: $(TMDS_OUT_HDL) tb_tmds_out.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_tmds_out $(TMDS_OUT_HDL) tb_tmds_out.sv

# (M15b — external I2S receiver removed; POKEY → HDMI audio is an internal
# fabric feed. See pokey_i2s_tx.sv / tb_pokey_i2s.sv.)

# ---- M15b — TERC4 4b/10b encoder (HDMI data island) ----------------------
terc4: $(BUILD_DIR)/tb_terc4.vvp
	@echo "=== M15b terc4 ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_terc4.log
	@grep -q '\*\*\* TERC4 OK \*\*\*' $(BUILD_DIR)/tb_terc4.log || \
	    (echo "FAIL: tb_terc4 missing TERC4 OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_terc4.log && \
	    (echo "FAIL: tb_terc4 reported a trap"; exit 1) || true
	@echo "PASS: tb_terc4"

$(BUILD_DIR)/tb_terc4.vvp: $(HDL_DIR)/terc4_encoder.sv tb_terc4.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_terc4 $(HDL_DIR)/terc4_encoder.sv tb_terc4.sv

# ---- M15b — HDMI BCH ECC encoders ----------------------------------------
hdmi_bch: $(BUILD_DIR)/tb_hdmi_bch.vvp
	@echo "=== M15b hdmi_bch ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hdmi_bch.log
	@grep -q '\*\*\* BCH OK \*\*\*' $(BUILD_DIR)/tb_hdmi_bch.log || \
	    (echo "FAIL: tb_hdmi_bch missing BCH OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_hdmi_bch.log && \
	    (echo "FAIL: tb_hdmi_bch reported a trap"; exit 1) || true
	@echo "PASS: tb_hdmi_bch"

$(BUILD_DIR)/tb_hdmi_bch.vvp: $(HDL_DIR)/hdmi_bch.sv tb_hdmi_bch.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hdmi_bch $(HDL_DIR)/hdmi_bch.sv tb_hdmi_bch.sv

# ---- M15b — HDMI packet content (audio sample + InfoFrames + clk regen) ----
hdmi_pkt: $(BUILD_DIR)/tb_hdmi_pkt.vvp
	@echo "=== M15b hdmi_pkt ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hdmi_pkt.log
	@grep -q '\*\*\* HDMI_PKT OK \*\*\*' $(BUILD_DIR)/tb_hdmi_pkt.log || \
	    (echo "FAIL: tb_hdmi_pkt missing HDMI_PKT OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_hdmi_pkt.log && \
	    (echo "FAIL: tb_hdmi_pkt reported a trap"; exit 1) || true
	@echo "PASS: tb_hdmi_pkt"

HDMI_PKT_HDL := \
    $(HDL_DIR)/hdmi_bch.sv         \
    $(HDL_DIR)/hdmi_packet.sv      \
    $(HDL_DIR)/hdmi_pkt_source.sv

$(BUILD_DIR)/tb_hdmi_pkt.vvp: $(HDMI_PKT_HDL) tb_hdmi_pkt.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hdmi_pkt $(HDMI_PKT_HDL) tb_hdmi_pkt.sv

# ---- M15b — full HDMI output integration (FSM + audio data island) -------
hdmi_out: $(BUILD_DIR)/tb_hdmi_out.vvp
	@echo "=== M15b hdmi_out ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hdmi_out.log
	@grep -q '\*\*\* HDMI_OUT OK \*\*\*' $(BUILD_DIR)/tb_hdmi_out.log || \
	    (echo "FAIL: tb_hdmi_out missing HDMI_OUT OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_hdmi_out.log && \
	    (echo "FAIL: tb_hdmi_out reported a trap"; exit 1) || true
	@echo "PASS: tb_hdmi_out"

HDMI_OUT_HDL := \
    $(HDL_DIR)/vbeam.sv            \
    $(HDL_DIR)/tmds_encoder.sv     \
    $(HDL_DIR)/tmds_serializer.sv  \
    $(HDL_DIR)/terc4_encoder.sv    \
    $(HDL_DIR)/hdmi_bch.sv         \
    $(HDL_DIR)/hdmi_packet.sv      \
    $(HDL_DIR)/hdmi_pkt_source.sv  \
    $(HDL_DIR)/hdmi_out.sv

$(BUILD_DIR)/tb_hdmi_out.vvp: $(HDMI_OUT_HDL) tb_hdmi_out.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hdmi_out $(HDMI_OUT_HDL) tb_hdmi_out.sv

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
    $(HDL_DIR)/rp_tx.sv            \
    $(HDL_DIR)/rp_bus_mock.sv      \
    $(HDL_DIR)/dma_master.sv       \
    $(HDL_DIR)/dma_arbiter.sv      \
    $(HDL_DIR)/mem_read_mux.sv

$(BUILD_DIR)/tb_dma_int.vvp: $(DMA_INT_HDL) tb_dma_int.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_dma_int $(DMA_INT_HDL) tb_dma_int.sv

# ---- M16b — HyperRAM shim foundation -------------------------------------
hyperram: $(BUILD_DIR)/tb_hyperram.vvp
	@echo "=== M16b hyperram ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_hyperram.log
	@grep -q '\*\*\* HYPERRAM OK \*\*\*' $(BUILD_DIR)/tb_hyperram.log || \
	    (echo "FAIL: tb_hyperram missing HYPERRAM OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_hyperram.log && \
	    (echo "FAIL: tb_hyperram reported a trap"; exit 1) || true
	@echo "PASS: tb_hyperram"

HYPERRAM_HDL := \
    $(HDL_DIR)/hyperram_mock.sv    \
    $(HDL_DIR)/hyperram_shim.sv

$(BUILD_DIR)/tb_hyperram.vvp: $(HYPERRAM_HDL) tb_hyperram.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_hyperram $(HYPERRAM_HDL) tb_hyperram.sv

# ---- M16b-2 — bank_translator + 130XE PORTB banking ----------------------
bank: $(BUILD_DIR)/tb_bank.vvp
	@echo "=== M16b-2 bank ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_bank.log
	@grep -q '\*\*\* BANK OK \*\*\*' $(BUILD_DIR)/tb_bank.log || \
	    (echo "FAIL: tb_bank missing BANK OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_bank.log && \
	    (echo "FAIL: tb_bank reported a trap"; exit 1) || true
	@echo "PASS: tb_bank"

BANK_HDL := \
    $(HDL_DIR)/hyperram_mock.sv    \
    $(HDL_DIR)/hyperram_shim.sv    \
    $(HDL_DIR)/bank_translator.sv

$(BUILD_DIR)/tb_bank.vvp: $(BANK_HDL) tb_bank.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_bank $(BANK_HDL) tb_bank.sv

# ---- M17-1 — DRAW emission via rp_tx -------------------------------------
draw: $(BUILD_DIR)/tb_draw.vvp
	@echo "=== M17-1 draw ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_draw.log
	@grep -q '\*\*\* DRAW OK \*\*\*' $(BUILD_DIR)/tb_draw.log || \
	    (echo "FAIL: tb_draw missing DRAW OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_draw.log && \
	    (echo "FAIL: tb_draw reported a trap"; exit 1) || true
	@echo "PASS: tb_draw"

$(BUILD_DIR)/tb_draw.vvp: $(HDL_DIR)/rp_tx.sv tb_draw.sv $(HDL_DIR)/bus_opcodes.vh | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_draw $(HDL_DIR)/rp_tx.sv tb_draw.sv

# ---- N6-HDL Phase 1 — PSSI TX standalone unit test -----------------------
pssi_tx: $(BUILD_DIR)/tb_pssi_tx.vvp
	@echo "=== N6 Phase 1 pssi_tx ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pssi_tx.log
	@grep -q '\*\*\* PSSI_TX OK \*\*\*' $(BUILD_DIR)/tb_pssi_tx.log || \
	    (echo "FAIL: tb_pssi_tx missing PSSI_TX OK"; exit 1)
	@grep -q 'PSSI_TX FAILED\|TRAP\|FATAL' $(BUILD_DIR)/tb_pssi_tx.log && \
	    (echo "FAIL: tb_pssi_tx reported a failure"; exit 1) || true
	@echo "PASS: tb_pssi_tx"

$(BUILD_DIR)/tb_pssi_tx.vvp: $(HDL_DIR)/pssi_tx.sv tb_pssi_tx.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pssi_tx $(HDL_DIR)/pssi_tx.sv tb_pssi_tx.sv

# ---- N6-HDL Phase 1 — PSSI integration test (pssi_bytes + pssi_tx) -------
pssi_int: $(BUILD_DIR)/tb_pssi_int.vvp
	@echo "=== N6 Phase 1 pssi_int ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_pssi_int.log
	@grep -q '\*\*\* PSSI_INT OK \*\*\*' $(BUILD_DIR)/tb_pssi_int.log || \
	    (echo "FAIL: tb_pssi_int missing PSSI_INT OK"; exit 1)
	@grep -q 'PSSI_INT FAILED\|TRAP\|FATAL' $(BUILD_DIR)/tb_pssi_int.log && \
	    (echo "FAIL: tb_pssi_int reported a failure"; exit 1) || true
	@echo "PASS: tb_pssi_int"

$(BUILD_DIR)/tb_pssi_int.vvp: $(HDL_DIR)/pssi_tx.sv $(HDL_DIR)/pssi_bytes.sv tb_pssi_int.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_pssi_int $(HDL_DIR)/pssi_tx.sv $(HDL_DIR)/pssi_bytes.sv tb_pssi_int.sv

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
    $(HDL_DIR)/bank_cache.sv       \
    $(HDL_DIR)/cache_line_ram.sv   \
    $(HDL_DIR)/sally_mem.sv

$(BUILD_DIR)/tb_sally.vvp: $(SALLY_HDL) tb_sally.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally $(SALLY_HDL) tb_sally.sv

# ---- M24-klaus — Klaus Dormann 6502 functional test --------------------
# Runs Klaus Dormann's full documented-opcode test against sally_core.
# Vendored binary at sim/test_data/6502_functional_test.bin (BSD,
# Klaus2m5/6502_65C02_functional_tests). The .hex file is generated
# from the .bin by `make test_data/6502_functional_test.hex`.
#
# Long-running — not in the default `all`. Exits early on stuck-PC.
klaus: $(BUILD_DIR)/tb_klaus.vvp test_data/6502_functional_test.hex
	@echo "=== M24-klaus Klaus Dormann functional test ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_klaus.log
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
    $(HDL_DIR)/bank_cache.sv \
    $(HDL_DIR)/cache_line_ram.sv \
    $(HDL_DIR)/sally_mem.sv

$(BUILD_DIR)/tb_sally_mem.vvp: $(SALLY_MEM_HDL) tb_sally_mem.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_mem $(SALLY_MEM_HDL) tb_sally_mem.sv

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
    $(HDL_DIR)/bank_cache.sv       \
    $(HDL_DIR)/cache_line_ram.sv   \
    $(HDL_DIR)/sally_mem.sv        \
    $(HDL_DIR)/sally_clock.sv

$(BUILD_DIR)/tb_sally_arbitration.vvp: $(SALLY_ARB_HDL) tb_sally_arbitration.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_sally_arbitration $(SALLY_ARB_HDL) tb_sally_arbitration.sv

# ---- M24-3 — bank cache ($4000-$7FFF) ---------------------------------
bank_cache: $(BUILD_DIR)/tb_bank_cache.vvp
	@echo "=== M24-3 bank_cache ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_bank_cache.log
	@grep -q '\*\*\* BANK_CACHE OK \*\*\*' $(BUILD_DIR)/tb_bank_cache.log || \
	    (echo "FAIL: tb_bank_cache missing BANK_CACHE OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_bank_cache.log && \
	    (echo "FAIL: tb_bank_cache reported a trap"; exit 1) || true
	@echo "PASS: tb_bank_cache"

$(BUILD_DIR)/tb_bank_cache.vvp: $(HDL_DIR)/bank_cache.sv $(HDL_DIR)/cache_line_ram.sv tb_bank_cache.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_bank_cache $(HDL_DIR)/bank_cache.sv $(HDL_DIR)/cache_line_ram.sv tb_bank_cache.sv

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

# ---- M-cache-rework Step 1 — cache_regs unit test --------------------------
cache_regs: $(BUILD_DIR)/tb_cache_regs.vvp
	@echo "=== M-cache-rework cache_regs ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_cache_regs.log
	@grep -q '\*\*\* CACHE_REGS OK \*\*\*' $(BUILD_DIR)/tb_cache_regs.log || \
	    (echo "FAIL: tb_cache_regs missing CACHE_REGS OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_cache_regs.log && \
	    (echo "FAIL: tb_cache_regs reported a trap"; exit 1) || true
	@echo "PASS: tb_cache_regs"

$(BUILD_DIR)/tb_cache_regs.vvp: $(HDL_DIR)/cache_regs.sv tb_cache_regs.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_cache_regs $(HDL_DIR)/cache_regs.sv tb_cache_regs.sv

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

# ---- M-cache-rework Step 3 — code/data partition routing ------------------
cache_partition: $(BUILD_DIR)/tb_cache_partition.vvp
	@echo "=== M-cache-rework cache_partition ==="
	@$(VVP) -N $< | tee $(BUILD_DIR)/tb_cache_partition.log
	@grep -q '\*\*\* CACHE_PARTITION OK \*\*\*' $(BUILD_DIR)/tb_cache_partition.log || \
	    (echo "FAIL: tb_cache_partition missing CACHE_PARTITION OK"; exit 1)
	@grep -q 'TRAP\|FATAL\|FAIL' $(BUILD_DIR)/tb_cache_partition.log && \
	    (echo "FAIL: tb_cache_partition reported a trap"; exit 1) || true
	@echo "PASS: tb_cache_partition"

$(BUILD_DIR)/tb_cache_partition.vvp: $(HDL_SRCS) tb_cache_partition.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_cache_partition $(HDL_SRCS) tb_cache_partition.sv

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
    $(HDL_DIR)/bank_cache.sv \
    $(HDL_DIR)/cache_line_ram.sv \
    $(HDL_DIR)/sally_mem.sv

$(BUILD_DIR)/tb_os_rom_load.vvp: $(OS_ROM_HDL) tb_os_rom_load.sv | $(BUILD_DIR)
	$(IVERILOG) $(SV_FLAGS) -o $@ -s tb_os_rom_load $(OS_ROM_HDL) tb_os_rom_load.sv

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
