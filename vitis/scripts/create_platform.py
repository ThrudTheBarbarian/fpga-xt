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

# ---- FreeRTOS domain -------------------------------------------------
# A SECOND domain on the same core running the freertos OS (the Xilinx
# Cortex-A9 FreeRTOS port — GIC + SCU private-timer tick already wired by
# the BSP).  The standalone domain stays for the FSBL + the bare-metal
# xtos app; this one is what the FreeRTOS bring-up (freertos_hello) and,
# later, XTOS link against.  Skip with VITIS_NO_RTOS=1.
RTOS_DOMAIN = "freertos_ps7_cortexa9_0"
if not os.environ.get("VITIS_NO_RTOS"):
    # freertos10_xilinx's HW validator (baremetal_validate_comp_xlnx.py, driven
    # by the freertos depends list) requires a TTC (ttcps) or AXI timer (tmrctr)
    # — NOT the A9 scutimer.  The validator's node_list only includes DT nodes
    # carrying status="okay", and matches them against the ttcps driver schema
    # (which mandates reg + interrupts + interrupt-parent + xlnx,clock-freq).
    # This PS config has pcw-ttc0-peripheral-enable=0, so the generated
    # Zynq-7000 SDT leaves ttc0 with no status and no xlnx,clock-freq — it's
    # excluded entirely, and the domain aborts with "no timer hardware
    # instance".  The TTC0 hard IP exists regardless and counts off CPU_1X, so
    # force-enable the node: status="okay" puts it in node_list, xlnx,clock-freq
    # (CPU_1X ~111.111 MHz) satisfies the schema + sets the tick base, and
    # xlnx,ip-name/xlnx,name let the BSP emit an XTtcPs config.  FreeRTOS then
    # ticks off TTC0.  The SDT is regenerated every run, so this re-applies.
    # With PCW_TTC0_PERIPHERAL_ENABLE=1 (gen_ps_bd.tcl) the XSA's SDT should
    # already describe ttc0 fully (status okay, in the A9 address-map, with
    # xlnx,clock-freq).  This stays only as an idempotent safety net: it fills
    # any property the generator happens to omit (notably xlnx,clock-freq, which
    # the ttcps driver mandates) and otherwise no-ops.  Matched by address so a
    # label change can't break it; each property added only if absent.
    _sdt = os.path.join(WORKSPACE, "fpga_xt_platform", "hw", "sdt",
                        "zynq-7000.dtsi")
    _ttc = "timer@f8001000 {"   # ttc0 (address is stable; label may vary)
    _ttc_clk = 111111115        # CPU_1X, Hz (pcw act-ttc0-clk0-peripheral-freqmhz)
    _ttc_needed = [
        ("status",          'status = "okay";'),
        ("xlnx,clock-freq", "xlnx,clock-freq = <%d>;" % _ttc_clk),
        ("xlnx,ip-name",    'xlnx,ip-name = "ps7_ttc";'),
        ("xlnx,name",       'xlnx,name = "ps7_ttc_0";'),
    ]
    try:
        with open(_sdt, "r") as _f:
            _sdt_txt = _f.read()
        if _ttc in _sdt_txt:
            _blk = _sdt_txt.split(_ttc, 1)[1].split("};", 1)[0]
            _ins = "".join("\n\t\t\t" + _v for _k, _v in _ttc_needed if _k not in _blk)
            if _ins:
                _sdt_txt = _sdt_txt.replace(_ttc, _ttc + _ins, 1)
                try:
                    os.chmod(_sdt, 0o644)    # Vitis leaves the SDT read-only
                except OSError:
                    pass
                with open(_sdt, "w") as _f:
                    _f.write(_sdt_txt)
                print(f">> ttc0 safety-net: added missing props [{', '.join(k for k,_ in _ttc_needed if k not in _blk)}]")
            else:
                print(">> ttc0 already fully described in SDT — no patch needed")
        else:
            print(">> WARNING: ttc0 node (timer@f8001000) not found in SDT")
    except OSError as e:
        print(f">> WARNING: could not inspect/patch ttc0: {e}")

    print(">> adding freertos domain ...")
    rtos_dom = platform.add_domain(
        cpu="ps7_cortexa9_0",
        os="freertos",
        name=RTOS_DOMAIN,
        display_name="freertos",
    )
    # Map this domain's console to UART1 too.  The freertos OS exposes its own
    # freertos_stdout/freertos_stdin params (NOT the standalone_* ones).  Wrap
    # defensively: a key-name change across Vitis builds must not abort the
    # whole platform create (the bring-up app also writes UART1 raw).
    # tick_rate=1000 Hz so a 1 ms vTaskDelay (the xtos REPL pace) is one tick;
    # generous heap for task stacks (xtos repl task + future GEM/FAT/Lua tasks).
    for _k, _v in (("freertos_stdout", "ps7_uart_1"),
                   ("freertos_stdin",  "ps7_uart_1"),
                   ("freertos_tick_rate", "1000"),
                   ("freertos_total_heap_size", "262144"),
                   ("freertos_minimal_stack_size", "1024")):
        try:
            rtos_dom.set_config("os", _k, _v)
            print(f">> freertos domain: set {_k} -> {_v}")
        except Exception as e:  # noqa: BLE001 - tolerate API key drift
            print(f">> WARNING: freertos domain set_config({_k}) failed: {e}")

    # ---- FAT filesystem (xilffs / FatFs) on the SD card ------------------
    # xtos mounts a FAT SD card for boot scripts + apps.  xsdps (the SD driver)
    # is pulled in automatically because SD0 is enabled in the PS.  Config is
    # XILFFS_use_lfn=3 = long filenames via a HEAP work-buffer (reentrant-safe
    # under FreeRTOS; the static =1 buffer is not).  xilffs has NO code-page
    # parameter — FF_CODE_PAGE is hardcoded to 932 in the generated ffconf.h —
    # so the 850 (Latin-1 / UK £) override is a post-generate patch + rebuild
    # (see after platform.build()).
    print(">> adding xilffs (FatFs) to the freertos domain ...")
    rtos_dom.set_lib(lib_name="xilffs")
    try:
        rtos_dom.set_config("lib", "XILFFS_use_lfn", "3", lib_name="xilffs")
        print(">> xilffs: set XILFFS_use_lfn -> 3 (LFN, heap work-buffer)")
    except Exception as e:  # noqa: BLE001 - tolerate param-name drift
        print(f">> WARNING: xilffs set_config(XILFFS_use_lfn) failed: {e}")

status = platform.build()
print(f">> platform build status: {status}")

# NOTE: FAT code page is fixed at 932 (Shift-JIS) — xilffs exposes no code-page
# parameter and the generated ffconf.h hardcodes `#define FF_CODE_PAGE 932`.
# Patching the *generated* ffconf.h doesn't help: platform.build() regenerates
# it from the xilffs template on the next build.  Pure-ASCII filenames are
# identical under 932/850, so this only matters for 0x80-0xFF (£, accented
# Latin).  Forcing 850 (Latin-1/UK) means patching the xilffs *template*
# ffconf.h in the Vitis install (modifies the toolchain) — not done by default.

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
# The OS console: HDMI/SiI9022 + blitter init in main(), then the FreeRTOS
# scheduler with the serial REPL running as a task.  Built against the freertos
# domain.  Source lives in ../xtos/src/; imported so editing stays in-tree.
print(">> creating xtos component (freertos domain) ...")
app = client.create_app_component(
    name="xtos",
    platform=PFM_FILE,
    domain=RTOS_DOMAIN,
    template="empty_application",
)
for fn in os.listdir(APP_SRC):
    src = os.path.join(APP_SRC, fn)
    if os.path.isfile(src):
        app.import_files(from_loc=APP_SRC, files=[fn])
        print(f"   imported {fn}")

# Compile the app sources explicitly via USER_COMPILE_SOURCES: import_files lands
# them at the component ROOT, but the generated CMakeLists only builds
# aux_source_directory(src) (no .c there) + USER_COMPILE_SOURCES.  USB HID is now
# off-board on the RP2354 companion, so usb_hid.c and the vendored TinyUSB host
# are NOT compiled (main.c no longer references them).  Append to (don't clobber)
# the Vitis-generated UserConfig.cmake; set() is last-wins so the empty defaults
# are overridden while its link/linker-script plumbing is preserved.
_comp_root = os.path.join(WORKSPACE, "xtos").replace("\\", "/")
_app_srcs = [os.path.join(_comp_root, f).replace("\\", "/")
             for f in sorted(os.listdir(APP_SRC))
             if f.endswith(".c") and f != "usb_hid.c"]
# Vendored Lua 5.4 (REPO_ROOT/xtos/lua) compiled into the app for boot scripts —
# every .c except the standalone interpreter (lua.c) and compiler (luac.c) mains.
_lua_dir  = os.path.join(REPO_ROOT, "xtos", "lua")
_lua_inc  = _lua_dir.replace("\\", "/")
_lua_srcs = [os.path.join(_lua_dir, f).replace("\\", "/")
             for f in sorted(os.listdir(_lua_dir))
             if f.endswith(".c") and f not in ("lua.c", "luac.c")]
# Portable GEM VDI (+ FreeType text) compiled into the app: the VDI core
# (gem/vdi/*.c, excluding the printers/ subdir — the PDF device needs zlib and
# is stubbed by src/gem_pdf_stub.c), the FreeType-backed font engine + catalog,
# and the software gfx backend (renders into the desktop plane).  See
# src/gem_lua.c for the bring-up + `vdi` Lua table.
_gem_dir  = os.path.join(REPO_ROOT, "gem")
_gem_inc  = _gem_dir.replace("\\", "/")
_vdi_dir  = os.path.join(_gem_dir, "vdi")
_gem_srcs = [os.path.join(_vdi_dir, f).replace("\\", "/")
             for f in sorted(os.listdir(_vdi_dir)) if f.endswith(".c")]
_gem_srcs += [os.path.join(_gem_dir, f).replace("\\", "/")
              for f in ("font.c", "font_catalog.c", "gfx_soft.c")]
# Vendored FreeType 2.13.3 (REPO_ROOT/xtos/freetype): each tu/ft_*.c wrapper
# scopes FT2_BUILD_LIBRARY and #includes one upstream module .c.  Trimmed module
# set (truetype/cff + sfnt/smooth/autofit/...) per include/.../config/ftmodule.h.
_ft_dir   = os.path.join(REPO_ROOT, "xtos", "freetype")
_ft_inc   = os.path.join(_ft_dir, "include").replace("\\", "/")
_ft_tu    = os.path.join(_ft_dir, "tu")
_ft_srcs  = [os.path.join(_ft_tu, f).replace("\\", "/")
             for f in sorted(os.listdir(_ft_tu)) if f.endswith(".c")]
# POSIX <dirent.h> shim (xtos/compat) for the GEM font loader's opendir/readdir.
_compat_inc = os.path.join(REPO_ROOT, "xtos", "compat").replace("\\", "/")
_all_srcs = _app_srcs + _lua_srcs + _gem_srcs + _ft_srcs
_user_cmake = os.path.join(WORKSPACE, "xtos", "src", "UserConfig.cmake")
with open(_user_cmake, "a") as _f:
    _f.write("\n# --- fpga-xt: app sources (root) + vendored Lua + GEM VDI/FreeType; no USB ---\n")
    _f.write('set(USER_INCLUDE_DIRECTORIES "%s" "${CMAKE_CURRENT_SOURCE_DIR}" "%s" "%s" "%s" "%s")\n'
             % (_comp_root, _lua_inc, _gem_inc, _ft_inc, _compat_inc))
    _f.write("set(USER_COMPILE_SOURCES\n")
    for _s in _all_srcs:
        _f.write('  "%s"\n' % _s)
    _f.write(")\n")
    # libm for Lua's math (sin/pow/floor/fmod/…) — appended into the link's
    # --start-group, so it resolves the Lua math refs (the BSP group has no -lm).
    _f.write("set(USER_LINK_LIBRARIES m)\n")
    # lodepng.c (in src/, auto-compiled) — decode-only: no encoder, no disk I/O
    # (we read PNGs via FatFs), no ancillary chunks.  Keeps it lean + off newlib
    # file stdio.  Append so we don't drop any generated defs.
    _f.write("set(USER_COMPILE_DEFINITIONS ${USER_COMPILE_DEFINITIONS} "
             "LODEPNG_NO_COMPILE_ENCODER LODEPNG_NO_COMPILE_DISK "
             "LODEPNG_NO_COMPILE_ANCILLARY_CHUNKS)\n")
print(f">> UserConfig.cmake: {len(_app_srcs)} app + {len(_lua_srcs)} Lua + "
      f"{len(_gem_srcs)} GEM + {len(_ft_srcs)} FreeType sources (+libm) -> {_user_cmake}")

# --- bump stack + heap sizes --------------------------------------------
# Defaults are tiny: main 8KB, IRQ 1KB, newlib heap 8KB.  Bump the IRQ stack
# (ISRs) and the main stack (init runs there pre-scheduler), and grow the
# newlib heap to 2 MB — Lua's allocator (luaL_newstate -> realloc) lives there,
# and 8 KB can't hold the interpreter.  (Task stacks come from the FreeRTOS
# heap, not _STACK_SIZE; FreeRTOS_total_heap_size is set on the domain.)
_lds = os.path.join(WORKSPACE, "xtos", "src", "lscript.ld")
with open(_lds, "r") as _f:
    _lds_txt = _f.read()
_lds_new = (_lds_txt
    .replace("_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;",
             "_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x10000;")
    .replace("_IRQ_STACK_SIZE = DEFINED(_IRQ_STACK_SIZE) ? _IRQ_STACK_SIZE : 1024;",
             "_IRQ_STACK_SIZE = DEFINED(_IRQ_STACK_SIZE) ? _IRQ_STACK_SIZE : 0x8000;")
    .replace("_HEAP_SIZE = DEFINED(_HEAP_SIZE) ? _HEAP_SIZE : 0x2000;",
             "_HEAP_SIZE = DEFINED(_HEAP_SIZE) ? _HEAP_SIZE : 0x2000000;"))
if _lds_new != _lds_txt:
    try:
        os.chmod(_lds, 0o644)
    except OSError:
        pass
    with open(_lds, "w") as _f:
        _f.write(_lds_new)
    print(">> bumped _STACK_SIZE=0x10000 _IRQ_STACK_SIZE=0x8000 _HEAP_SIZE=0x2000000 in lscript.ld")

status = app.build()
print(f">> xtos build status: {status}")

# ---- freertos_hello -------------------------------------------------
# Minimal FreeRTOS bring-up proof against the freertos domain: heartbeat +
# counter task + vTaskStartScheduler.  Sources in ../freertos_hello/src/.
# JTAG-loaded on its own to prove the scheduler/tick before XTOS proper.
# Skipped together with the domain via VITIS_NO_RTOS=1.
if not os.environ.get("VITIS_NO_RTOS"):
    print(">> creating freertos_hello component ...")
    RTOS_SRC = os.path.join(VITIS_DIR, "freertos_hello", "src")
    rapp = client.create_app_component(
        name="freertos_hello",
        platform=PFM_FILE,
        domain=RTOS_DOMAIN,
        template="empty_application",
    )
    for fn in os.listdir(RTOS_SRC):
        src = os.path.join(RTOS_SRC, fn)
        if os.path.isfile(src):
            rapp.import_files(from_loc=RTOS_SRC, files=[fn])
            print(f"   imported {fn}")

    # import_files lands sources at the component ROOT, but the generated
    # CMakeLists only compiles aux_source_directory(src) + USER_COMPILE_SOURCES
    # — so wire the root .c files (and the root include dir) the same way the
    # xtos component does above.
    _rroot = os.path.join(WORKSPACE, "freertos_hello").replace("\\", "/")
    _rsrcs = [os.path.join(_rroot, f).replace("\\", "/")
              for f in sorted(os.listdir(RTOS_SRC)) if f.endswith(".c")]
    _ruser = os.path.join(WORKSPACE, "freertos_hello", "src", "UserConfig.cmake")
    with open(_ruser, "a") as _f:
        _f.write("\n# --- fpga-xt: freertos_hello app sources (root) ---\n")
        _f.write('set(USER_INCLUDE_DIRECTORIES "%s" "${CMAKE_CURRENT_SOURCE_DIR}")\n'
                 % _rroot)
        _f.write("set(USER_COMPILE_SOURCES\n")
        for _s in _rsrcs:
            _f.write('  "%s"\n' % _s)
        _f.write(")\n")
    print(f">> freertos_hello UserConfig.cmake: {len(_rsrcs)} sources -> {_ruser}")

    status = rapp.build()
    print(f">> freertos_hello build status: {status}")

print(">> done.  Artefacts in:")
print(f"     {WORKSPACE}/fpga_xt_platform/export/")
print(f"     {WORKSPACE}/fsbl/build/")
print(f"     {WORKSPACE}/xtos/build/")
if not os.environ.get("VITIS_NO_RTOS"):
    print(f"     {WORKSPACE}/freertos_hello/build/")
