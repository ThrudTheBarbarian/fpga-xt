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
    # Skip the auto FSBL BSP creation.  Setting no_boot_bsp=False
    # makes Vitis 2025.x try to build a zynq_fsbl BSP at platform-
    # create time; its CMakeLists references ps7_init.c at the
    # component root, but Vitis doesn't extract the XSA-bundled
    # copy into that location even though vivado/build.tcl injects
    # ps7_init.* into the XSA root.  FSBL is only needed for
    # SD/QSPI boot; JTAG iteration works without it.  See bring-up
    # phase 3 + the deferred-work block at the bottom of this file.
    no_boot_bsp=True,
)
status = platform.build()
print(f">> platform build status: {status}")

PFM_FILE = os.path.join(WORKSPACE, "fpga_xt_platform", "export",
                       "fpga_xt_platform", "fpga_xt_platform.xpfm")
DOMAIN   = "standalone_ps7_cortexa9_0"

# ---- FSBL (deferred) -------------------------------------------------
# The Zynq FSBL initialises the PS (DDR3 calibration, clocks, MIO) and
# is required for SD / QSPI boot — NOT for JTAG iteration, where xsct
# does the equivalent via ps7_init.tcl.
#
# Current state (2026-05-16): Vitis 2025.x's auto FSBL BSP creation
# (when no_boot_bsp=False) needs ps7_init.c at component-create time.
# Even though vivado/build.tcl injects ps7_init.* into the XSA root,
# Vitis 2025.x doesn't extract them into the FSBL BSP working dir at
# create time, and CMake fails with "Cannot find source file:
# ps7_init.c".  Things tried so far:
#
#   * Injecting ps7_init.* at the XSA root via `zip -j`
#     -> XSA now contains them, but the BSP build still can't find
#        them.  Vitis likely needs sysdef.xml to list ps7_init.c
#        explicitly OR a specific subdir layout we haven't matched.
#   * Creating FSBL as a separate component (post-platform) and
#     using import_files() to bring in ps7_init.*
#     -> doesn't run, because the failure is during platform create's
#        auto BSP step, before our code gets a turn.
#   * Targeting FSBL at the standalone_ps7_cortexa9_0 domain
#     -> "BSP is missing ['xilffs', 'xilrsa']" — that domain lacks
#        the FSBL-required libs.  Would need a platform-level
#        add-library API call we haven't found yet.
#
# Path forward when SD/QSPI boot is on the critical path:
#   1. Open the workspace in the Vitis IDE.
#   2. Add xilffs + xilrsa to the standalone_ps7_cortexa9_0 BSP.
#   3. Create the FSBL component manually targeting that domain.
#   4. Capture the IDE actions as a Python script and fold back here.
#
# JTAG-only bring-up (Phase 0-7 in docs/bring-up.md) doesn't need any
# of the above to work.

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
