# tools/Makefile — code-generation + lint helpers.
#
#   make regmap        regenerate the GP0 register map artefacts from the spec
#                      (hdl/xt_gp0_pkg.sv, vitis/xtos/src/xt_gp0_map.h,
#                       docs/Design/gp0-register-map.md)
#   make regmap-check  fail if any generated artefact is stale (CI gate)
#   make cdc-lint      scan hdl/ for unsafe multi-bit 2-FF clock crossings
#   make check         regmap-check + cdc-lint (everything CI runs here)

PYTHON ?= python3

.PHONY: regmap regmap-check cdc-lint check

regmap:
	$(PYTHON) gen_regmap.py

regmap-check:
	$(PYTHON) gen_regmap.py --check

cdc-lint:
	$(PYTHON) cdc_lint.py

check: regmap-check cdc-lint
