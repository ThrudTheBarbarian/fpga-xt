# fpga-xt — website packaging & deploy.
#
# The xtc toolchain binaries are built in the sibling fpga-xtc repo; its
# `make dist` writes the version-labelled archives into
# web/site/public/downloads/ (this repo).  These targets package and
# deploy the rendered site, which lives here.
#
# Typical flow (run from this folder):
#   make dist      # build the toolchain binaries into web/site/public/downloads/
#   make web       # build the site → tar.bz2, ready to untar at the web-root
#   make distrib   # = make web, then scp the tarball to $(DISTRIB_HOST)
#   make docs      # like distrib, but excludes downloads/ (faster docs-only push)

XTC_DIR      ?= ../fpga-xtc
VERSION      := $(shell cat $(XTC_DIR)/VERSION 2>/dev/null || echo 0.0)
SITE_DIR     := web/site
SITE_BUILD   := $(SITE_DIR)/dist
SITE_TARBALL := $(SITE_DIR)/xtc-site-$(VERSION).tar.bz2
DOCS_TARBALL := $(SITE_DIR)/xtc-site-docs-$(VERSION).tar.bz2
DISTRIB_HOST ?= azoth.info

# SD-card boot payload (gitignored).  `make boot.bin` drops a ready-to-flash
# BOOT.BIN + README here; copy the folder's contents to a FAT32 microSD root.
BOOTBIN_DIR  := boot.bin

.DEFAULT_GOAL := help
.PHONY: help dist web distrib docs clean bitstream platform boot.bin

# Self-documenting help — bare `make` lists every target.
help:
	@echo 'fpga-xt — make targets:'
	@echo ''
	@echo '  Hardware / SD boot:'
	@echo '    boot.bin   Repackage FSBL + bitstream + app into a flashable'
	@echo '               BOOT.BIN and assemble the SD payload under ./$(BOOTBIN_DIR)/.'
	@echo '               Fast (~10s): runs bootgen on win10 against the'
	@echo '               artefacts already there.  Run bitstream/platform first'
	@echo '               if you changed the RTL or PS app.'
	@echo '    bitstream  Build the PL bitstream + XSA on win10 (~6 min;'
	@echo '               vivado/run-win10.sh bit).  Needed before platform.'
	@echo '    platform   Build the Vitis platform, FSBL and app_blink on win10'
	@echo '               and pull the ELFs back (vitis/run-win10.sh).  Needs a'
	@echo '               current XSA on win10 (run bitstream first).'
	@echo ''
	@echo '  Website / docs:'
	@echo '    dist       Build the xtc toolchain archives into the site downloads/.'
	@echo '    web        Build the static site and bundle it to a tar.bz2.'
	@echo '    distrib    web, then scp the tarball to $$(DISTRIB_HOST).'
	@echo '    docs       Build + ship the site EXCLUDING downloads/ (fast docs push).'
	@echo '    clean      Remove the generated site tarballs.'

# --- Hardware / SD boot -------------------------------------------------

# Build the PL bitstream (+ XSA) on the win10 Vivado host.
bitstream:
	./vivado/run-win10.sh bit

# Build the Vitis platform + FSBL + app_blink on win10 and pull the ELFs back.
# Requires a current XSA on win10 (run `make bitstream` first).
platform:
	PULL=1 ./vitis/run-win10.sh

# Assemble the SD-card boot payload: package BOOT.BIN (bootgen on win10) and
# drop it + a flashing README into ./$(BOOTBIN_DIR)/.  .PHONY so it always runs
# even though the directory shares the target's name.
boot.bin:
	@mkdir -p $(BOOTBIN_DIR)
	./vitis/scripts/build_boot_bin.sh $(BOOTBIN_DIR)/BOOT.BIN
	@printf '%s\n' \
	  'fpga-xt — SD-card boot payload' \
	  '' \
	  'Bare-metal Zynq-7000 SD boot needs only BOOT.BIN (FSBL + PL bitstream' \
	  '+ app_blink, packaged by bootgen).' \
	  '' \
	  'To flash:' \
	  '  1. Format a microSD (>=1 GB) as FAT32.' \
	  '  2. Copy BOOT.BIN to the root of the card.' \
	  '  3. Set the Z-Turn boot-mode jumpers to SD.' \
	  '  4. Power-cycle.  FSBL brings up the PS, loads the bitstream, runs' \
	  '     app_blink (UART banner @115200 8N1; HDMI from the PL plane' \
	  '     compositor).' \
	  '' \
	  'Regenerate with: make boot.bin  (rebuild upstream first with' \
	  'make bitstream && make platform if the RTL or PS app changed).' \
	  > $(BOOTBIN_DIR)/README.txt
	@echo ">> SD payload ready in ./$(BOOTBIN_DIR)/ — copy its contents to a FAT32 microSD root."

# Convenience passthrough — build the binaries in fpga-xtc, which drops the
# version-labelled archives into web/site/public/downloads/.
dist:
	$(MAKE) -C $(XTC_DIR) dist

# Build the static site (astro build copies public/downloads/ into the
# rendered tree) and bundle web/site/dist/ into one tar.bz2 whose contents
# extract directly at the web-root on the server.
web:
	cd $(SITE_DIR) && npx astro build
	@rm -f $(SITE_TARBALL)
	tar -cjf $(SITE_TARBALL) -C $(SITE_BUILD) .
	@echo "site -> $(SITE_TARBALL) (extract at web-root)"

# Build + bundle the site, then scp it to the web server.
#   make distrib DISTRIB_HOST=user@host
distrib: web
	scp $(SITE_TARBALL) $(DISTRIB_HOST):
	@echo "uploaded -> $(DISTRIB_HOST):$$(basename $(SITE_TARBALL))"

# Docs-only update: build the site and ship everything EXCEPT downloads/.
# Untarring at the web-root leaves the server's existing downloads/ in place,
# so this is the fast path when only the docs/site content has changed.
#   make docs DISTRIB_HOST=user@host
docs:
	cd $(SITE_DIR) && npx astro build
	@rm -f $(DOCS_TARBALL)
	tar --exclude='./downloads' -cjf $(DOCS_TARBALL) -C $(SITE_BUILD) .
	@echo "site (no downloads) -> $(DOCS_TARBALL) (extract at web-root)"
	scp $(DOCS_TARBALL) $(DISTRIB_HOST):
	@echo "uploaded -> $(DISTRIB_HOST):$$(basename $(DOCS_TARBALL))"

clean:
	rm -f $(SITE_DIR)/xtc-site-*.tar.bz2
