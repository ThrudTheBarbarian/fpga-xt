# create_platform.py — Vitis Unified 2025.x platform + FSBL + app_blink.
#
# Driven by `vitis -s create_platform.py` on the remote build machine
# after Vivado has written `vivado/build/fpga_xt_top.xsa`.
#
# Produces three components inside vitis/workspace/:
#   * fpga_xt_platform — standalone (bare-metal) Zynq-7000 platform
#                        with one domain on ps7_cortexa9_0.
#   * fsbl             — Zynq FSBL component (boot/BSP launcher).
#   * app_blink        — bare-metal hello-world app that prints to
#                        UART and toggles a PS GPIO.  Sources in
#                        ../app_blink/src/.
#
# All paths are resolved relative to the script's location so the
# same script works in-tree and after rsync'ing to the build host.
#
# Outputs are gitignored — re-running this script is the canonical
# way to regenerate the workspace from the XSA.

import os
import shutil
import sys
import vitis

# ---- Paths -----------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VITIS_DIR  = os.path.dirname(SCRIPT_DIR)
REPO_ROOT  = os.path.dirname(VITIS_DIR)

WORKSPACE  = os.path.join(VITIS_DIR, "workspace")
APP_SRC    = os.path.join(VITIS_DIR, "app_blink", "src")

# The XSA lives in different places depending on where this is being
# run from:
#   * Local Mac:   <repo>/vivado/build/fpga_xt_top.xsa
#   * Remote box:  ~/fpga-xt-build/build/fpga_xt_top.xsa  (run.sh only
#                  rsyncs hdl/, build.tcl, constraints/ — no vivado/
#                  prefix on the remote)
# Try both; whichever exists wins.
XSA_CANDIDATES = [
    os.path.join(REPO_ROOT, "vivado", "build", "fpga_xt_top.xsa"),
    os.path.join(REPO_ROOT, "build",  "fpga_xt_top.xsa"),
]
XSA = next((p for p in XSA_CANDIDATES if os.path.exists(p)), None)

if XSA is None:
    print("ERROR: XSA not found in any of:")
    for p in XSA_CANDIDATES:
        print(f"   {p}")
    print("Run `cd vivado && ./run.sh bit fpga_xt_top xc7z020-2clg400` first.")
    sys.exit(1)

# Clean workspace before each run.  The Vitis Python API doesn't have
# a clean "re-open or create" idiom — create_platform_component fails
# with ALREADY_EXISTS if there's anything at the workspace path.  The
# workspace is gitignored and regenerable, so wiping it is fine.  Set
# VITIS_KEEP_WORKSPACE=1 to skip this (e.g., when you've manually
# edited the BSP and want to rebuild the app against it).
if os.path.exists(WORKSPACE) and not os.environ.get("VITIS_KEEP_WORKSPACE"):
    print(f">> wiping existing workspace: {WORKSPACE}")
    shutil.rmtree(WORKSPACE)

# ---- Vitis client ----------------------------------------------------
client = vitis.create_client()
client.set_workspace(path=WORKSPACE)
print(f">> workspace: {WORKSPACE}")
print(f">> XSA:       {XSA}")

# ---- Platform --------------------------------------------------------
# Standalone OS on the first Cortex-A9 core.  No FreeRTOS yet — that
# comes once the UART-hello path is proven.
print(">> creating platform component fpga_xt_platform ...")
platform = client.create_platform_component(
    name="fpga_xt_platform",
    hw_design=XSA,
    os="standalone",
    cpu="ps7_cortexa9_0",
    # Skip the auto-generated FSBL boot BSP — its CMake step fails
    # because the XSA doesn't currently include ps7_init.c (see notes
    # in the FSBL block below).  Boot BSP is only needed for SD/QSPI
    # boot; JTAG iteration runs without it.
    no_boot_bsp=True,
)
status = platform.build()
print(f">> platform build status: {status}")

PFM_FILE = os.path.join(WORKSPACE, "fpga_xt_platform", "export",
                       "fpga_xt_platform", "fpga_xt_platform.xpfm")
DOMAIN   = "standalone_ps7_cortexa9_0"

# ---- FSBL (deferred) -------------------------------------------------
# The Zynq FSBL initialises the PS (DDR3 calibration, clocks, MIO) and
# is required for SD / QSPI boot.  Vitis 2025.x's zynq_fsbl template
# wants a ps7_init.c sourced from the XSA, which our `write_hw_platform
# -fixed -include_bit` output doesn't currently package — even though
# the file exists in the BD's .gen tree.  Investigating in a separate
# pass; for now JTAG boot via xsct doesn't need an FSBL (it does the
# DDR3 calibration directly via ps7_init.tcl).
#
# Re-enable once the XSA-export step is fixed; see docs/bring-up.md
# "Phase 3 — PS boots".
if False:
    print(">> creating FSBL component ...")
    fsbl = client.create_app_component(
        name="fsbl",
        platform=PFM_FILE,
        domain=DOMAIN,
        template="zynq_fsbl",
    )
    status = fsbl.build()
    print(f">> fsbl build status: {status}")

# ---- app_blink -------------------------------------------------------
# Bare-metal hello world that prints to UART1 (the on-board USB-UART
# bridge) and toggles a PS GPIO LED.  Source lives in
# ../app_blink/src/; we import it into the component so editing
# remains in-tree and not in the gitignored workspace.
print(">> creating app_blink component ...")
app = client.create_app_component(
    name="app_blink",
    platform=PFM_FILE,
    domain=DOMAIN,
    template="empty_application",
)
for fn in os.listdir(APP_SRC):
    src = os.path.join(APP_SRC, fn)
    if os.path.isfile(src):
        app.import_files(from_loc=APP_SRC, files=[fn])
        print(f"   imported {fn}")
status = app.build()
print(f">> app_blink build status: {status}")

print(">> done.  Artefacts in:")
print(f"     {WORKSPACE}/fpga_xt_platform/export/")
print(f"     {WORKSPACE}/fsbl/build/")
print(f"     {WORKSPACE}/app_blink/build/")
