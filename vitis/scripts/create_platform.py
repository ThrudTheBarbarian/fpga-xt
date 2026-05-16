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
import sys
import vitis

# ---- Paths -----------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VITIS_DIR  = os.path.dirname(SCRIPT_DIR)
REPO_ROOT  = os.path.dirname(VITIS_DIR)

WORKSPACE  = os.path.join(VITIS_DIR, "workspace")
XSA        = os.path.join(REPO_ROOT, "vivado", "build", "fpga_xt_top.xsa")
APP_SRC    = os.path.join(VITIS_DIR, "app_blink", "src")

if not os.path.exists(XSA):
    print(f"ERROR: XSA not found at {XSA}")
    print("Run `cd vivado && ./run.sh bit fpga_xt_top xc7z020-2clg400` first.")
    sys.exit(1)

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
    no_boot_bsp=False,
)
status = platform.build()
print(f">> platform build status: {status}")

PFM_FILE = os.path.join(WORKSPACE, "fpga_xt_platform", "export",
                       "fpga_xt_platform", "fpga_xt_platform.xpfm")
DOMAIN   = "standalone_ps7_cortexa9_0"

# ---- FSBL ------------------------------------------------------------
# The Zynq FSBL initialises the PS (DDR3 calibration, clocks, MIO) and
# then loads the user .elf + bitstream from the boot image.  Required
# for SD / QSPI boot; not strictly needed for JTAG-only iteration
# (xsct can do the FSBL's job directly), but generating it now keeps
# both paths open.
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
