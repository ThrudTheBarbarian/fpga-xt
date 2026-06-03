# create_platform.py — Vitis Unified 2025.x platform + FSBL + xtos.
#
# Driven by `vitis -s create_platform.py` on the remote build machine
# after Vivado has written `vivado/build/fpga_xt_top.xsa`.
#
# Produces three components inside vitis/workspace/:
#   * fpga_xt_platform — standalone (bare-metal) Zynq-7000 platform
#                        with one domain on ps7_cortexa9_0.
#   * fsbl             — Zynq FSBL component (boot/BSP launcher).
#   * xtos        — bare-metal hello-world app that prints to
#                        UART and toggles a PS GPIO.  Sources in
#                        ../xtos/src/.
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
APP_SRC    = os.path.join(VITIS_DIR, "xtos", "src")

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
    # Windows leaves some files read-only after Vitis exits — rmtree fails
    # with PermissionError unless we chmod first.
    def _on_rmtree_error(func, path, exc_info):
        os.chmod(path, 0o700)
        func(path)
    shutil.rmtree(WORKSPACE, onerror=_on_rmtree_error)

# ---- Vitis client ----------------------------------------------------
client = vitis.create_client()
client.set_workspace(path=WORKSPACE)
print(f">> workspace: {WORKSPACE}")
print(f">> XSA:       {XSA}")

# ---- Platform --------------------------------------------------------
# Standalone OS on the first Cortex-A9 core.  No FreeRTOS yet — that
# comes once the UART-hello path is proven.
print(">> creating platform component fpga_xt_platform ...")
# Always skip the auto FSBL BSP creation — Vitis 2025.2.1's auto path
# creates the zynq_fsbl domain but never populates the source files,
# leaving CMake with "No SOURCES given to target: fsbl.elf".  We build
# the FSBL as a separate app component below, which DOES pull in the
# template sources from $XILINX_VITIS/data/embeddedsw.
platform = client.create_platform_component(
    name="fpga_xt_platform",
    hw_design=XSA,
    os="standalone",
    cpu="ps7_cortexa9_0",
    no_boot_bsp=True,
)

# FSBL needs xilffs (FAT file system to read BOOT.BIN from SD/QSPI) and
# xilrsa (image signature/decryption).  Add them to the standalone BSP
# BEFORE the first platform.build() so the libraries are present when
# create_app_component validates the zynq_fsbl template.
if not os.environ.get("VITIS_NO_FSBL"):
    print(">> adding xilffs + xilrsa to BSP for FSBL ...")
    domain = platform.get_domain("standalone_ps7_cortexa9_0")
    domain.set_lib(lib_name="xilffs")
    domain.set_lib(lib_name="xilrsa")

# Map the standalone console to UART1 (the Z-Turn's on-SOM serial, MIO48/49).
# WITHOUT this the BSP leaves STDOUT_BASEADDRESS undefined, which makes BOTH
# xil_printf() AND the FSBL's fsbl_printf() silent no-ops — i.e. the board can
# boot fine and emit nothing.  This was the reason every SD boot was mute.
_dom = platform.get_domain("standalone_ps7_cortexa9_0")
_dom.set_config("os", "standalone_stdout", "ps7_uart_1")
_dom.set_config("os", "standalone_stdin",  "ps7_uart_1")
print(">> set standalone stdout/stdin -> ps7_uart_1")

status = platform.build()
print(f">> platform build status: {status}")

PFM_FILE = os.path.join(WORKSPACE, "fpga_xt_platform", "export",
                       "fpga_xt_platform", "fpga_xt_platform.xpfm")
DOMAIN   = "standalone_ps7_cortexa9_0"

# ---- FSBL app -------------------------------------------------------
# Vitis 2025.2.1's `template="zynq_fsbl"` runs CMake during component
# create and fails before we get a chance to import ps7_init.c (which
# the template's CMakeLists.txt expects alongside the FSBL sources).
# Workaround: create the component as empty_application and import
# both the FSBL template tree from $XILINX_VITIS/data/embeddedsw AND
# ps7_init.* from the BD's gen tree, then build.  Skip via
# VITIS_NO_FSBL=1.
if not os.environ.get("VITIS_NO_FSBL"):
    print(">> creating fsbl app component (empty + manual import) ...")
    fsbl = client.create_app_component(
        name="fsbl",
        platform=PFM_FILE,
        domain=DOMAIN,
        template="empty_application",
    )

    # FSBL template sources (CMakeLists, fsbl_main.c, image_mover.c, ...)
    fsbl_tpl = os.path.join(os.environ["XILINX_VITIS"], "data", "embeddedsw",
                            "lib", "sw_apps", "zynq_fsbl", "src")
    for fn in os.listdir(fsbl_tpl):
        src = os.path.join(fsbl_tpl, fn)
        if os.path.isfile(src):
            fsbl.import_files(from_loc=fsbl_tpl, files=[fn])

    # ps7_init.c / ps7_init.h from the PS BD's gen tree (the same files
    # vivado/build.tcl injects into the XSA root).
    ps_ip_dir = os.path.join(REPO_ROOT, "bd", "zynq_ps_bd", "zynq_ps_bd.gen",
                             "sources_1", "bd", "ps_bd", "ip",
                             "ps_bd_zynq_ps_0")
    if not os.path.isdir(ps_ip_dir):
        ps_ip_dir = os.path.join(REPO_ROOT, "vivado", "bd", "zynq_ps_bd",
                                 "zynq_ps_bd.gen", "sources_1", "bd",
                                 "ps_bd", "ip", "ps_bd_zynq_ps_0")
    for fn in ("ps7_init.c", "ps7_init.h"):
        fsbl.import_files(from_loc=ps_ip_dir, files=[fn])

    # --- Force the FSBL to link into OCM, not DDR -------------------------
    # create_app_component(empty_application) auto-generates a DDR-mapped
    # lscript.ld (all sections -> ps7_ddr_0_memory_0 @ 0x100000) and
    # import_files does NOT overwrite an existing file — so our FSBL was
    # linked into DDR.  An FSBL MUST run from OCM: the BootROM loads it
    # BEFORE DDR is initialised (the FSBL's own ps7_init brings DDR up).
    # Linked to DDR, the BootROM silently can't place it -> ps7_init never
    # runs -> PL never configures (no heartbeat) -> no UART -> dead board.
    # Overwrite the component linker script with the zynq_fsbl template's
    # OCM one (sections -> ps7_ram_0 @ 0x0 / ps7_ram_1 @ 0xFFFF0000).
    # The build uses <component>/src/lscript.ld (the same path xtos links
    # against).  Vitis marks it read-only, so chmod before overwriting.  (Don't
    # touch the component-root lscript.ld — it's read-only and unused here.)
    fsbl_lds_src = os.path.join(fsbl_tpl, "lscript.ld")
    fsbl_lds_dst = os.path.join(WORKSPACE, "fsbl", "src", "lscript.ld")
    try:
        os.chmod(fsbl_lds_dst, 0o644)
    except OSError:
        pass
    shutil.copy(fsbl_lds_src, fsbl_lds_dst)
    print(f">> forced OCM FSBL linker script -> {fsbl_lds_dst}")

    # --- Enable FSBL debug output ----------------------------------------
    # fsbl_debug.h gates fsbl_printf() on `#if defined(FSBL_DEBUG_INFO)` (and
    # on STDOUT_BASEADDRESS, which the domain stdout=ps7_uart_1 setting above
    # now defines).  Force-define it at the top of the imported header so the
    # FSBL prints its progress over UART1 — banner, DDR init, each partition
    # load, and the handoff address.  That trace tells us exactly how far the
    # boot gets (vs. the blind LED-only feedback we had over SD).
    # import_files lands the FSBL sources at the component ROOT (not src/),
    # so check both.
    fsbl_dbg_h = next((p for p in (
        os.path.join(WORKSPACE, "fsbl", "fsbl_debug.h"),
        os.path.join(WORKSPACE, "fsbl", "src", "fsbl_debug.h"),
    ) if os.path.exists(p)), None)
    try:
        if fsbl_dbg_h is None:
            raise OSError("fsbl_debug.h not found in component")
        with open(fsbl_dbg_h, "r") as f:
            _dbg = f.read()
        if "FSBL_DEBUG_INFO" not in _dbg.split("\n")[0]:
            try:
                os.chmod(fsbl_dbg_h, 0o644)
            except OSError:
                pass
            with open(fsbl_dbg_h, "w") as f:
                f.write("#define FSBL_DEBUG_INFO 1\n" + _dbg)
            print(f">> enabled FSBL_DEBUG_INFO in {fsbl_dbg_h}")
    except OSError as e:
        print(f">> WARNING: could not enable FSBL debug: {e}")

    status = fsbl.build()
    print(f">> fsbl build status: {status}")

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

# ---- xtos -------------------------------------------------------
# Bare-metal hello world that prints to UART1 (the on-board USB-UART
# bridge) and toggles a PS GPIO LED.  Source lives in
# ../xtos/src/; we import it into the component so editing
# remains in-tree and not in the gitignored workspace.
print(">> creating xtos component ...")
app = client.create_app_component(
    name="xtos",
    platform=PFM_FILE,
    domain=DOMAIN,
    template="empty_application",
)
for fn in os.listdir(APP_SRC):
    src = os.path.join(APP_SRC, fn)
    if os.path.isfile(src):
        app.import_files(from_loc=APP_SRC, files=[fn])
        print(f"   imported {fn}")

# ---- TinyUSB host (USB0) build wiring --------------------------------
# The generated src/CMakeLists.txt does include(UserConfig.cmake) and consumes
# USER_COMPILE_SOURCES (extra sources) + aux_source_directory(src) + the src
# include dir.  So compile the vendored TinyUSB host subset IN PLACE (no copy)
# and add its include dir by writing UserConfig.cmake.  TinyUSB lives at
# <repo>/vitis/xtos/tinyusb (submodule), separate from the imported component
# src/, so reference it by absolute path (forward slashes for CMake).
TINYUSB_SRC = os.path.join(REPO_ROOT, "vitis", "xtos", "tinyusb", "src")
_tu_inc  = TINYUSB_SRC.replace("\\", "/")
_tu_srcs = [os.path.join(TINYUSB_SRC, p).replace("\\", "/") for p in (
    "tusb.c",
    "common/tusb_fifo.c",
    "host/usbh.c",
    "host/hub.c",
    "class/hid/hid_host.c",
    "portable/chipidea/ci_hs/hcd_ci_hs.c",
    "portable/ehci/ehci.c",
)]
# APPEND to the Vitis-generated UserConfig.cmake (do NOT clobber it — it carries
# enable_language, USER_UNDEFINED_SYMBOLS, link vars, and the linker-script
# plumbing).  Use the intended hook variables (USER_INCLUDE_DIRECTORIES /
# USER_COMPILE_SOURCES); CMake set() is last-wins, so these override the empty
# defaults while everything else is preserved.
# import_files lands the app sources (incl. tusb_config.h) at the component ROOT,
# not src/, so add the root to the include path (the TinyUSB USER_COMPILE_SOURCES
# only get USER_INCLUDE_DIRECTORIES, not the component's default include).
_comp_root = os.path.join(WORKSPACE, "xtos").replace("\\", "/")
# import_files lands the app sources at the component ROOT, but the component's
# CMakeLists only compiles aux_source_directory(src) + USER_COMPILE_SOURCES — and
# src/ has no .c — so the root app sources (main.c, usb_hid.c, xt_blitter.c) are
# never compiled.  Compile them explicitly via USER_COMPILE_SOURCES (the imported
# copies at the root), alongside the TinyUSB subset.
_app_srcs = [os.path.join(_comp_root, f).replace("\\", "/")
             for f in sorted(os.listdir(APP_SRC)) if f.endswith(".c")]
_all_srcs = _app_srcs + _tu_srcs
_user_cmake = os.path.join(WORKSPACE, "xtos", "src", "UserConfig.cmake")
with open(_user_cmake, "a") as _f:
    _f.write("\n# --- fpga-xt: app sources (root) + vendored TinyUSB host (ci_hs/EHCI) ---\n")
    _f.write('set(USER_INCLUDE_DIRECTORIES "%s" "${CMAKE_CURRENT_SOURCE_DIR}" "%s")\n'
             % (_comp_root, _tu_inc))
    _f.write("set(USER_COMPILE_SOURCES\n")
    for _s in _all_srcs:
        _f.write('  "%s"\n' % _s)
    _f.write(")\n")
print(f">> UserConfig.cmake: {len(_app_srcs)} app + {len(_tu_srcs)} TinyUSB sources -> {_user_cmake}")

# --- bump stack sizes for the USB stack + interrupt handler --------------
# Defaults are tiny: main stack 8KB, IRQ stack only 1KB.  The USB ISR runs on
# the IRQ stack and does a lot (EHCI async/periodic schedule walks,
# hcd_event_xfer_complete, usb_logf's 256-byte vsnprintf buffer), and the deep
# enumeration call chain in tuh_task uses the main stack — both overflow and
# corrupt adjacent memory (deterministic crashes / data aborts).  Bump both.
_lds = os.path.join(WORKSPACE, "xtos", "src", "lscript.ld")
with open(_lds, "r") as _f:
    _lds_txt = _f.read()
_lds_new = (_lds_txt
    .replace("_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;",
             "_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x10000;")
    .replace("_IRQ_STACK_SIZE = DEFINED(_IRQ_STACK_SIZE) ? _IRQ_STACK_SIZE : 1024;",
             "_IRQ_STACK_SIZE = DEFINED(_IRQ_STACK_SIZE) ? _IRQ_STACK_SIZE : 0x8000;"))
if _lds_new != _lds_txt:
    try:
        os.chmod(_lds, 0o644)
    except OSError:
        pass
    with open(_lds, "w") as _f:
        _f.write(_lds_new)
    print(">> bumped _STACK_SIZE=0x10000 _IRQ_STACK_SIZE=0x8000 in lscript.ld")

status = app.build()
print(f">> xtos build status: {status}")

print(">> done.  Artefacts in:")
print(f"     {WORKSPACE}/fpga_xt_platform/export/")
print(f"     {WORKSPACE}/fsbl/build/")
print(f"     {WORKSPACE}/xtos/build/")
