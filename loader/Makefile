# xtld host testbed.
#
#   make test    build the arm32 test .so + host harness, run the loader on it
#   make dump     show the test .so's relocations / dynamic section (readelf)
#   make clean
#
# Host loader is built with the native compiler; the test .so is a REAL arm32
# ELF ET_DYN (arm-none-eabi-gcc + ld.lld). The host can't execute ARM, so the
# harness verifies relocated data rather than running code.

# Note: CC/LD are predefined by make/shell, so use distinct names and := to
# avoid inheriting Apple's `cc`/`ld` where we need the cross tools.
HOSTCC  := clang
ARMCC   := arm-none-eabi-gcc
LLD     := ld.lld
READELF := readelf

CFLAGS  ?= -Wall -Wextra -O0 -g -I.
ARMCFLAGS ?= -marm -fpic -Os -ffreestanding -fno-builtin -Ikernel   # -Ikernel: usys.h -> xtsys.h (frozen syscall numbers)

QEMU      := qemu-system-arm
QEMUFLAGS := -M virt -cpu cortex-a15 -nographic -no-reboot \
             -semihosting-config enable=on,target=native
# real FreeRTOS runs on the actual Zynq PS model. Semihosting I/O is bound to a
# stdio chardev so the shell's stdin (SYS_READC) reads the terminal/pipe.
QEMUZYNQ  := qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
             -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0
# Overridable so two people (or two agents) can build the same tree at once WITHOUT sharing a
# build directory. They otherwise race: one `make` relinking libc.so/dropbear.so while another
# is packing them into a romfs embeds a TORN FILE, and the result is a kernel whose sshd-session
# will not load — with every artefact on disk looking perfectly fine afterwards, because the
# loser of the race rebuilt it. That cost a long night (docs/bugs/dropbear-svr-opts-undefined.md).
#   make BUILD=build-<who>   -> private objects, libs, romfs, sdstage
BUILD ?= build
BARECFLAGS := -marm -mcpu=cortex-a15 -ffreestanding -nostdlib -O0 -g \
              -I. -I$(BUILD) -Ikernel -Itest/qemu

.PHONY: test dump clean qemu kernel freertos
test: $(BUILD)/host_test $(BUILD)/testlib.so
	@echo "=== running loader host test ==="
	@$(BUILD)/host_test $(BUILD)/testlib.so

$(BUILD)/host_test: test/host_test.c xtld.c xtld.h | $(BUILD)
	$(HOSTCC) $(CFLAGS) test/host_test.c xtld.c -o $@

$(BUILD)/testlib.o: test/testlib.c | $(BUILD)
	$(ARMCC) $(ARMCFLAGS) -c $< -o $@

$(BUILD)/testlib.so: $(BUILD)/testlib.o
	$(LLD) -shared --hash-style=sysv -o $@ $<

dump: $(BUILD)/testlib.so
	$(READELF) -h -d -r $<

# --- execute under qemu-system-arm (bare metal, semihosting) ------------
qemu: $(BUILD)/bare.elf
	@echo "=== running loader under qemu-system-arm (bare metal) ==="
	@$(QEMU) $(QEMUFLAGS) -kernel $< ; echo "(qemu exited $$?)"

# embed the test .so as a C array (no filesystem on bare metal)
$(BUILD)/testlib_so.h: $(BUILD)/testlib.so
	@{ printf 'unsigned char testlib_so[] = {\n'; \
	   od -An -v -tx1 $< | sed -e 's/[0-9a-fA-F][0-9a-fA-F]/0x&,/g'; \
	   printf '};\nunsigned int testlib_so_len = sizeof(testlib_so);\n'; } > $@

$(BUILD)/bare.elf: test/qemu/startup.S test/qemu/bare_main.c test/qemu/bare_rt.c test/qemu/bare_libc.c xtld.c test/qemu/bare.ld $(BUILD)/testlib_so.h | $(BUILD)
	$(ARMCC) $(BARECFLAGS) -T test/qemu/bare.ld \
	    test/qemu/startup.S test/qemu/bare_main.c test/qemu/bare_rt.c test/qemu/bare_libc.c xtld.c -o $@

# --- svc #1 gateway + spawn, executed under qemu ------------------------
kernel: $(BUILD)/kernel.elf
	@echo "=== running svc #1 gateway + spawn under qemu-system-arm ==="
	@$(QEMU) $(QEMUFLAGS) -kernel $< ; echo "(qemu exited $$?)"

$(BUILD)/app.so: test/qemu/app.c | $(BUILD)
	$(ARMCC) $(ARMCFLAGS) -c $< -o $(BUILD)/app.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/app.o

$(BUILD)/app_so.h: $(BUILD)/app.so
	@{ printf 'unsigned char app_so[] = {\n'; \
	   od -An -v -tx1 $< | sed -e 's/[0-9a-fA-F][0-9a-fA-F]/0x&,/g'; \
	   printf '};\nunsigned int app_so_len = sizeof(app_so);\n'; } > $@

KSRC := test/qemu/kmain.c test/qemu/bare_rt.c test/qemu/bare_libc.c kernel/ksys.c xtld.c
KASM := test/qemu/startup.S kernel/arch_arm.S

$(BUILD)/kernel.elf: $(KASM) $(KSRC) test/qemu/bare.ld $(BUILD)/app_so.h kernel/ksys.h kernel/xtsys.h | $(BUILD)
	$(ARMCC) $(BARECFLAGS) -T test/qemu/bare.ld $(KASM) $(KSRC) -o $@

# --- the REAL Xilinx FreeRTOS kernel + CA9 port, on qemu's Zynq PS model -
FR     := ../third_party/freertos10_xilinx/src/Source
FRPORT := $(FR)/portable/GCC/ARM_CA9
LWIP  := ../third_party/lwip
FRINC  := -I. -I$(FR)/include -I$(FRPORT) -Itest/freertos -Itest/freertos/shim \
          -Itest/qemu -Ikernel -I$(BUILD) \
          -Itest/freertos/storage -Itest/freertos/storage/shim \
          -Itest/freertos/net -I$(LWIP)/src/include -I$(LWIP)/contrib/ports/freertos/include
# lwIP core (BSD) + the FreeRTOS sys_arch + our GEM0 netif — the network stack
# (DHCP + the tftp file drop; TCP compiled in for the phase-2 console/sockets)
LWIPSRC := $(addprefix $(LWIP)/src/core/, init.c def.c dns.c inet_chksum.c ip.c mem.c memp.c \
             netif.c pbuf.c raw.c stats.c sys.c tcp.c tcp_in.c tcp_out.c timeouts.c udp.c \
             altcp.c altcp_alloc.c altcp_tcp.c) \
           $(addprefix $(LWIP)/src/core/ipv4/, acd.c dhcp.c etharp.c icmp.c ip4.c \
             ip4_addr.c ip4_frag.c igmp.c) \
           $(LWIP)/src/netif/ethernet.c $(LWIP)/src/api/tcpip.c \
           $(LWIP)/src/api/api_lib.c $(LWIP)/src/api/api_msg.c $(LWIP)/src/api/netbuf.c \
           $(LWIP)/src/apps/tftp/tftp.c \
           $(LWIP)/src/apps/mdns/mdns.c $(LWIP)/src/apps/mdns/mdns_out.c \
           $(LWIP)/src/apps/mdns/mdns_domain.c $(LWIP)/src/apps/sntp/sntp.c \
           $(LWIP)/contrib/ports/freertos/sys_arch.c
NETSRC  := test/freertos/net/xemacps.c test/freertos/net/xemacps_control.c \
           test/freertos/net/xemacps_bdring.c test/freertos/net/xemacps_pcs.c \
           test/freertos/net/xemacps_hw.c \
           test/freertos/net/xemacps_g.c test/freertos/net/net_libc.c \
           test/freertos/net/xemacpsif.c test/freertos/net/net.c test/freertos/net/tftpd.c \
           test/freertos/net/netcon.c test/freertos/net/wallclock.c test/freertos/net/sockets.c \
           test/freertos/net/input_udp.c \
           test/freertos/net/procnet.c
FRCFLAGS := -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -ffreestanding -nostdlib -O2 -g -DSDT $(FRINC)
FRSRC := $(FR)/tasks.c $(FR)/queue.c $(FR)/list.c $(FR)/timers.c $(FR)/event_groups.c \
         $(FR)/croutine.c $(FR)/stream_buffer.c $(FR)/portable/MemMang/heap_4.c \
         $(FRPORT)/port.c \
         test/freertos/zynq.c test/freertos/bsp_shim.c test/freertos/mmu.c test/freertos/vm.c test/freertos/stackguard.c test/freertos/gfxplane.c test/freertos/hdmi.c test/freertos/frtos_os.c test/freertos/uart1_rx.c test/freertos/sprite.c test/freertos/input_dev.c \
         test/freertos/mathcop.c test/freertos/xl_boot.c \
         test/freertos/romfs.c test/freertos/syscalls.c test/freertos/main.c test/freertos/blitter.c \
         newlib-pic/libm.a \
         test/freertos/blkdev.c test/freertos/vfs.c test/freertos/vfs_romfs.c test/freertos/vfs_ramfs.c test/freertos/vfs_lockfs.c test/freertos/vfs_devfs.c test/freertos/vfs_procfs.c \
         test/qemu/bare_rt.c test/qemu/bare_libc.c xtld.c \
         test/freertos/storage/ff.c test/freertos/storage/ffsystem.c \
         test/freertos/storage/ffunicode.c test/freertos/storage/diskio.c \
         test/freertos/storage/xsdps.c test/freertos/storage/xsdps_card.c \
         test/freertos/storage/xsdps_host.c test/freertos/storage/xsdps_options.c \
         test/freertos/storage/xsdps_sinit.c test/freertos/storage/xsdps_g.c \
         test/freertos/storage/xil_shim.c test/freertos/storage/sd.c \
         test/freertos/storage/vfs_fatfs.c \
         $(NETSRC) $(LWIPSRC)
FRASM := test/freertos/xt_boot.S test/freertos/xt_vectors.S $(FRPORT)/portASM.S

# Build the kernel ELF(s) WITHOUT launching qemu — for rebuilding to pick up a new
# romfs (e.g. after dropping a lib into romfs-overlay/) then flashing or running it
# yourself.  `freertos-build` = qemu ELF; add `hw` for the JTAG-load HW ELF.
.PHONY: freertos-build hw hosttest
freertos-build: $(BUILD)/freertos.elf
	@echo "built $< (no qemu) — run: make freertos | flash: vivado/jtag-valhalla.sh dow"
hw: $(BUILD)/freertos-hw.elf
	@echo "built $< — JTAG-load: vivado/jtag-valhalla.sh load"
# Toolchain testbed: boots straight into the kernel menu (skips the PL0 login sh), which
# owns `runhost` — load + run a host-filesystem .so over semihosting. The compiler drives
# it non-interactively:  printf 'runhost <hostpath>\nexit\n' | make hosttest-run
hosttest: $(BUILD)/freertos-hosttest.elf
	@echo "built $< — testbed: printf 'runhost <hostpath>\\nexit\\n' | $(QEMUZYNQ) -kernel $<"

# build fingerprint: git SHA (+ -dirty) baked into the kernel so the boot banner /
# dmesg can confirm which build is actually running (JTAG testbed vs a stale SD
# BOOT.BIN). Regenerated every make, but rewritten (mtime bumped) only when the
# value changes, so it doesn't force a needless full recompile.
BUILD_SHA   := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DIRTY := $(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)
BUILD_ID    := $(BUILD_SHA)$(BUILD_DIRTY)
BUILD_DATE  := $(shell date +%Y-%m-%d.%H:%M)
.PHONY: force_build_id
force_build_id: ;
$(BUILD)/build_id.h: force_build_id | $(BUILD)
	@echo '#define XT_BUILD_ID "$(BUILD_ID)"' > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm -f $@.tmp; else mv $@.tmp $@; echo "build id: $(BUILD_ID)"; fi

# Stage 2 + M2: loader + svc gateway + spawn-by-path + file syscalls, on real FreeRTOS.
freertos: $(BUILD)/freertos.elf
	@echo "=== xtos: programs from a filesystem on real FreeRTOS (qemu xilinx-zynq-a9) ==="
	@$(QEMUZYNQ) -kernel $< ; echo "(qemu exited $$?)"

$(BUILD)/freertos.elf: $(FRSRC) $(FRASM) test/freertos/freertos.ld test/freertos/FreeRTOSConfig.h test/freertos/net/lwipopts.h $(BUILD)/build_id.h $(BUILD)/romfs_blob.h | $(BUILD)
	$(ARMCC) $(FRCFLAGS) $(XTRACFLAGS) -T test/freertos/freertos.ld $(FRASM) $(FRSRC) -lgcc -o $@

# HW variant: same kernel (incl. the full tier-2 MMU/VM), but real Zynq UART1 I/O
# instead of semihosting (the testbed owns its SVC vector, so semihosting — which
# qemu intercepts above the guest — isn't available on metal). JTAG-load with
# ps7_init; run vmtest/demandtest/faulttest to exercise tier-2 on real silicon.
$(BUILD)/freertos-hw.elf: $(FRSRC) $(FRASM) test/freertos/freertos.ld test/freertos/FreeRTOSConfig.h test/freertos/net/lwipopts.h $(BUILD)/build_id.h $(BUILD)/hwromfs/romfs_blob.h | $(BUILD)
	$(ARMCC) -I$(BUILD)/hwromfs $(FRCFLAGS) -DXT_HW_UART -DXT_HW -T test/freertos/freertos.ld $(FRASM) $(FRSRC) -lgcc -o $@

# Kernel-menu (runhost) testbed ELF for the toolchain — same sources, -DXT_KERNEL_SHELL.
$(BUILD)/freertos-hosttest.elf: $(FRSRC) $(FRASM) test/freertos/freertos.ld test/freertos/FreeRTOSConfig.h test/freertos/net/lwipopts.h $(BUILD)/build_id.h $(BUILD)/romfs_blob.h | $(BUILD)
	$(ARMCC) $(FRCFLAGS) $(XTRACFLAGS) -DXT_KERNEL_SHELL -T test/freertos/freertos.ld $(FRASM) $(FRSRC) -lgcc -o $@

# Load + run an externally-built PIC .so (e.g. xtc output) on the real loader:
#   make xtcrun XTC_SO=/path/to/foo.so
# Embeds it in the romfs as /bin/xtcprog, builds the kernel, auto-spawns it under
# qemu. Self-contained (semihosting) or libc.so-importing programs both work.
.PHONY: xtcrun
xtcrun:
	@test -n "$(XTC_SO)" || { echo "usage: make xtcrun XTC_SO=path/to.so"; exit 1; }
	@test -f "$(XTC_SO)" || { echo "no such file: $(XTC_SO)"; exit 1; }
	rm -f $(BUILD)/romfs.bin $(BUILD)/romfs_blob.h $(BUILD)/freertos.elf
	$(MAKE) $(BUILD)/freertos.elf XTC_SO=$(abspath $(XTC_SO))
	@echo "=== running /bin/xtcprog on the XTOS loader (qemu) ==="
	@printf 'xtcprog\nexit\n' | $(QEMUZYNQ) -kernel $(BUILD)/freertos.elf; echo "(qemu exited $$?)"

# newlib-check — confirm the local newlib-pic/{libc.a,libm.a} are the VALIDATED
# artifacts recorded in newlib-pic.stamp (the golden). Not a build prereq: a
# from-source rebuild on another host produces bit-different .a (DWARF comp_dir,
# ar mtimes) and that's fine — this just tells you whether you're on the pinned,
# HW-validated libc or a local rebuild. Nonzero exit on mismatch so CI can gate.
# newlib — (re)build the PIC newlib into newlib-pic/ (~10 min; needs arm-none-eabi-gcc
# + curl). Upgrade to a new release without editing sources:  VER=4.5.0.YYYYMMDD make newlib
# Then `make newlib-check` (will MISMATCH), validate on HW, and promote the stamp.
.PHONY: newlib
newlib:
	VER=$(VER) tools/build-newlib-pic.sh

.PHONY: newlib-check
newlib-check:
	@tools/newlib-stamp.sh > $(BUILD)/newlib.stamp.now
	@if cmp -s $(BUILD)/newlib.stamp.now newlib-pic.stamp; then \
	    echo "newlib-check: OK — newlib-pic matches validated golden (newlib-pic.stamp)"; \
	else \
	    echo "newlib-check: MISMATCH — local newlib-pic differs from validated golden:"; \
	    diff newlib-pic.stamp $(BUILD)/newlib.stamp.now || true; \
	    echo "  This is a local rebuild, not the pinned/validated libc. If intentional,"; \
	    echo "  re-validate on HW then promote:  cp newlib-pic/STAMP newlib-pic.stamp && git add newlib-pic.stamp"; \
	    exit 1; \
	fi

# libc.so — PIC newlib (loader/newlib-pic/, built by tools/build-newlib-pic.sh)
# linked into a loadable shared object; goes in the romfs at /OS/Library/libc.so
$(BUILD)/libc.so: newlib-pic/libc.a libc-hide.map | $(BUILD)
	$(ARMCC) -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -shared -nostdlib \
	    -Wl,-z,max-page-size=0x100000 \
	    -Wl,--version-script=libc-hide.map \
	    -Wl,--whole-archive newlib-pic/libc.a -Wl,--no-whole-archive \
	    -Wl,-soname,libc.so -o $@

# --- romfs: build the programs as .so, pack them into a blob, embed it ---
PROGCFLAGS := $(ARMCFLAGS) -Itest/qemu -Ikernel   # -Ikernel: usys.h pulls syscall numbers from xtsys.h (one source of truth)

$(BUILD)/%.so: test/freertos/progs/%.c | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -c $< -o $(BUILD)/$*.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/$*.o

# sigtest links the posix shim (real signal/kill/vfork over the kernel) like a
# real program (toybox/dropbear do); the generic rule above would bind it to
# newlib's non-kernel stubs. Own rule so `make` picks it up.
$(BUILD)/sigtest.so: test/freertos/progs/sigtest.c $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -c $< -o $(BUILD)/sigtest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/sigtest.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so

# a shared library carries a soname (the registry/dedup key)
$(BUILD)/libutil.so: test/freertos/libs/libutil.c | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -c $< -o $(BUILD)/libutil.o
	$(LLD) -shared --hash-style=sysv -soname libutil.so -o $@ $(BUILD)/libutil.o

# libxtos.so — the XT-specific syscalls (framebuffer/input/xtos-messaging) as
# real, callable symbols, so non-C languages reach the machine the way libc.so
# gives them POSIX.  Derived wholesale from usys.h (see the source) — no
# hand-maintained wrapper list to drift from the frozen ABI.
# -g: embed DWARF so the .so is self-describing for xtc's #import — .dynsym gives
# the names, DWARF the signatures + struct layouts (os_fbinfo/os_event/xt_stat…).
# The .so IS the interface (docs/OS/library-imports.md §5); ship unstripped.
$(BUILD)/libxtos.so: test/freertos/libs/libxtos.c test/qemu/usys.h kernel/xtsys.h | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -g -c $< -o $(BUILD)/libxtos.o
	$(LLD) -shared --hash-style=sysv -soname libxtos.so -o $@ $(BUILD)/libxtos.o

# a program that links against the .so gets a DT_NEEDED + an unresolved import
$(BUILD)/usestr.so: test/freertos/progs/usestr.c $(BUILD)/libutil.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -c $< -o $(BUILD)/usestr.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/usestr.o $(BUILD)/libutil.so

# libm.so — PIC newlib libm (FreeType/VDI need sin/cos/sqrt/atan2); needs libc.so
$(BUILD)/libm.so: newlib-pic/libm.a $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -shared -nostdlib \
	    -Wl,--whole-archive newlib-pic/libm.a -Wl,--no-whole-archive \
	    -Wl,-soname,libm.so $(BUILD)/libc.so -o $@

# libGEM.so — the REAL portable GEM/VDI core + vendored FreeType (software
# backend), as a shared lib that DT_NEEDEDs libc.so + libm.so. __aeabi_* stay
# dynamic imports resolved by the kernel export table at load (libgcc isn't PIC).
GEM := ../gem
FT  := ../xtos/freetype
# The ONE shared GEM .rsc codec lives in the third_party/Rocks submodule (the
# "Rocks" resource editor); referenced, not copied.  The AES bridge $(GEM)/aes/
# rscload.c rides in via the aes/*.c wildcard below and links against this
# engine object, built separately (it sits outside aes/) with aes.h force-
# included so its RSC_OBJECT/RSC_TEDINFO + flag/type enums coincide with ours.
FPGAGEM := ../third_party/Rocks/src
RSC_ENGINE_OBJ := $(BUILD)/gem_rsc.o
# Desktop artwork (theme, icons, wallpaper) is user content on the SD — /OS/Themes,
# /OS/Icons, /OS/Wallpaper, each selected by a `Default` file — not baked in.
# $(GEM)/gemd/ is the SERVER half and $(GEM)/gemclient.c the CLIENT half of the same
# library: gemd links libGEM.so and so does every app — one library, two modes (§5).
GEMSRC := $(GEM)/gfx_soft.c $(GEM)/font.c $(GEM)/wm.c $(GEM)/theme.c $(GEM)/img.c \
          $(wildcard $(GEM)/vdi/*.c) $(wildcard $(GEM)/aes/*.c) \
          $(GEM)/gemclient.c $(wildcard $(GEM)/gemd/*.c) \
          ../gem/gem_pdf_stub.c test/freertos/libs/gem_stubs.c
FTSRC  := $(wildcard $(FT)/tu/*.c)
GEMINC := -Itest/freertos/libs/shim -I$(GEM) -I$(GEM)/vdi -I$(FT)/include -Inewlib-pic/include -Ikernel -Itest/qemu
# -g: embed DWARF so libGEM.so is self-describing for xtc's #import (the .so IS
# the interface — see docs/OS/library-imports.md). Ship unstripped.
# -DGEM_XTOS: compile the XTOS syscall paths (usys.h) into the AES core — e.g. the
# evnt_multi drain of kernel XTOS system messages. The SDL testbed leaves it off.
# -I$(FPGAGEM): the shared rsc.h; -DRSC_NO_STATE_FLAGS + -DG_BOX=G_BOX: rsc.h uses
# OUR aes.h flag/type enums (rscload.c includes aes.h before rsc.h).
# -fno-eliminate-unused-debug-types: gcc drops DWARF for any type nothing USES, and
# aes.h declares every constant as an anonymous enum and its structs (SCROLLBAR, ...)
# without ever naming them in an exported signature.  Without this flag xtc's
# `#import <GEM>` sees NONE of them and every binding hand-mirrors 49 constants that
# silently drift.  Costs ~10KB/TU of .debug_* — the ALLOC sections are byte-identical.
# INSTRUMENT=1: gem draw profiler + gemd membench + drag-lag profiler. OFF by default —
# the per-second [gemprof]/[gemd] klog lines are development data and must not pollute
# dmesg in normal use. `make INSTRUMENT=1 ...` compiles it all back in.
GEMCFLAGS := -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -O2 -g -DGEM_XTOS $(if $(INSTRUMENT),-DINSTRUMENTATION) \
             -fno-eliminate-unused-debug-types \
             -I$(FPGAGEM) -DRSC_NO_STATE_FLAGS -DG_BOX=G_BOX $(GEMINC)

# Vendored SQLite (amalgamation) for the A9 registry — built with our own VFS
# (SQLITE_OS_OTHER, sqlite_vfs.c over the loader file API), single-threaded,
# memory temp store, no WAL/dlopen used.
SQLITE      := ../third_party/sqlite
SQLITE_DEFS := -DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_TEMP_STORE=3 -DNDEBUG
$(BUILD)/sqlite3.o: $(SQLITE)/sqlite3.c | $(BUILD)
	$(ARMCC) -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -ffreestanding \
	    -Inewlib-pic/include -I$(SQLITE) $(SQLITE_DEFS) -c $< -o $@
$(BUILD)/sqlite_vfs.o: test/freertos/libs/sqlite_vfs.c | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -I$(SQLITE) -Itest/qemu -c $< -o $@
$(BUILD)/registry.o: $(GEM)/registry.c | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -I$(SQLITE) -c $< -o $@
$(BUILD)/regtest.so: test/freertos/progs/regtest.c $(BUILD)/registry.o $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o $(BUILD)/libc.so $(BUILD)/libm.so | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -I$(SQLITE) -Itest/qemu -c $< -o $(BUILD)/regtest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/regtest.o $(BUILD)/registry.o $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o $(BUILD)/libc.so $(BUILD)/libm.so

# sqlite3 — the interactive SQL shell (compact REPL, not the upstream shell.c),
# same SQLite + xt VFS as the registry: its locks are lockfs files, visible in
# /OS/var/locks while held. Lives on the SD (/OS/bin) on HW; in the qemu romfs
# for the test suite.
$(BUILD)/sqlite3.so: test/freertos/progs/sqlite3.c $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o $(BUILD)/libc.so $(BUILD)/libm.so | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -I$(SQLITE) -Itest/qemu -c $< -o $(BUILD)/sqlite3sh.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/sqlite3sh.o $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o $(BUILD)/libc.so $(BUILD)/libm.so

# The shared .rsc engine, compiled once (outside aes/) with aes.h force-included
# so -DRSC_NO_STATE_FLAGS/-DG_BOX=G_BOX make its enums coincide with the AES's.
$(RSC_ENGINE_OBJ): $(FPGAGEM)/rsc.c $(GEM)/aes/aes.h | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -include aes/aes.h -c $< -o $@

$(BUILD)/libGEM.so: $(GEMSRC) $(FTSRC) $(RSC_ENGINE_OBJ) $(BUILD)/libc.so $(BUILD)/libm.so | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -shared -nostdlib -Wl,-soname,libGEM.so \
	    $(GEMSRC) $(FTSRC) $(RSC_ENGINE_OBJ) $(BUILD)/libc.so $(BUILD)/libm.so -o $@

# gemd — THE WINDOW SERVER (M1). Thin: the loop lives in libGEM.so's gem/gemd/ half.
$(BUILD)/gemd.so: test/freertos/progs/gemd.c $(BUILD)/libGEM.so $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -Itest/qemu -c $< -o $(BUILD)/gemd.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/gemd.o $(BUILD)/libGEM.so $(BUILD)/libc.so

# gemtext — the first GEM CLIENT: connect to "gem", create a window, map the surface it is
# handed, draw into it with the real VDI, post one damage rect. Touches no framebuffer.
$(BUILD)/gemtext.so: test/freertos/progs/gemtext.c $(BUILD)/libGEM.so $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -Itest/qemu -c $< -o $(BUILD)/gemtext.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/gemtext.o $(BUILD)/libGEM.so $(BUILD)/libc.so

$(BUILD)/fujiclient.o: $(GEM)/fujiclient.c $(GEM)/fujiclient.h | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -DXT_TARGET -Ilibc-compat -Itest/qemu -c $< -o $@
# desktop — THE desktop (AES-based). Was `desktop`; it took the name when the old
# gem_wm demo `desktop` was retired. Keep this full link line -- the retired rule had a
# much shorter one, and reusing that is the easy way to break this.
$(BUILD)/desktop.so: test/freertos/progs/desktop.c $(BUILD)/registry.o $(BUILD)/fujiclient.o $(BUILD)/net_shim.o $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o $(BUILD)/libGEM.so $(BUILD)/libc.so $(BUILD)/libm.so | $(BUILD)
	$(ARMCC) $(GEMCFLAGS) -I$(SQLITE) -Itest/qemu -DDESKTOP_BUILD='"$(BUILD_ID) $(BUILD_DATE)"' -c $< -o $(BUILD)/desktop.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/desktop.o $(BUILD)/registry.o $(BUILD)/fujiclient.o $(BUILD)/net_shim.o $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o $(BUILD)/libGEM.so $(BUILD)/libc.so $(BUILD)/libm.so

# lua.so — /System/bin/lua: the Lua interpreter/REPL (real Lua 5.4 core from
# xtos/lua + lua.c, linked against libc.so/libm.so). Boot scripts that are Lua
# use `#!/bin/lua`; /bin/sh is toysh (toybox). One gcc call, like libGEM.so.
LUA     := ../xtos/lua
LUACORE := $(filter-out $(LUA)/lua.c $(LUA)/luac.c $(LUA)/onelua.c,$(wildcard $(LUA)/*.c))
$(BUILD)/lua.so: test/freertos/progs/lua.c $(LUACORE) $(BUILD)/libc.so $(BUILD)/libm.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -I$(LUA) -Inewlib-pic/include -fpic -shared -nostdlib \
	    -Wl,--hash-style=sysv -Wl,-soname,lua.so \
	    test/freertos/progs/lua.c $(LUACORE) $(BUILD)/libc.so $(BUILD)/libm.so -o $@

# a program that uses libc (DT_NEEDED libc.so), compiled against the PIC newlib headers
$(BUILD)/libc_test.so: test/freertos/progs/libc_test.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/libc_test.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/libc_test.o $(BUILD)/libc.so

# toybox.so — /System/bin/toybox: the unix userland + shell (vendored
# third_party/toybox, 0BSD; tools/build-toybox.sh cross-compiles it and
# collects the objects) linked with the posix shim (POSIX surface over the
# XTOS syscalls) against libc.so. Refresh after toybox/config changes with:
#   tools/build-toybox.sh && make freertos-build
#
# Every applet gets a /bin name (hardlink-style: mkromfs aliases them all to
# the ONE toybox blob). Keep this list in step with tools/toybox-xtos.miniconfig.
TOYBOX_APPLETS := toybox [ arch ascii base32 base64 basename bunzip2 bzcat \
    cal cat cksum clear cmp count cp crc32 cut date df dirname dos2unix du \
    echo egrep env expand false fgrep file find fold getopt grep gunzip head \
    help hexedit i2cdetect i2cdump i2cget i2cset \
    free hostname dnsdomainname ftpget ftpput install kill killall ln ls  md5sum mkdir mktemp mv nice nl od patch printenv printf ps pwd \
    readlink realpath rm rmdir sed sha1sum sha224sum sha256sum sha384sum \
    ifconfig nc netcat netstat ping ping6 sntp sha512sum sleep sort split stat strings tac tail tar tee test time wget \
    reboot top touch true ts uname uniq uptime reset xxd unix2dos unlink uudecode uuencode uuidgen vi wc which zcat
TOYBOX_ALIASES := $(foreach a,$(TOYBOX_APPLETS),/bin/$(a)=$(BUILD)/toybox.so)
$(BUILD)/toybox/objects.list:
	BUILDDIR=$(BUILD) tools/build-toybox.sh
$(BUILD)/posix_shim.o: test/freertos/libs/posix_shim.c kernel/xtsys.h test/qemu/usys.h | $(BUILD)
	$(ARMCC) -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -fno-builtin \
	    -D_GNU_SOURCE -Ilibc-compat -Inewlib-pic/include -Itest/qemu -Ikernel -c $< -o $@
# the Spencer regex (libs/regex, from the newlib source tree; engine.c is
# #included by regexec.c) — sed/grep need a real regcomp
REGEX_NAMES := regcomp regexec regfree regerror collcmp
REGEX_OBJS  := $(foreach r,$(REGEX_NAMES),$(BUILD)/regex_$(r).o)
$(BUILD)/regex_%.o: test/freertos/libs/regex/%.c | $(BUILD)
	$(ARMCC) -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -fno-builtin \
	    -D_GNU_SOURCE -Itest/freertos/libs/regex -Inewlib-pic/include -c $< -o $@
# linenoise (vendored, BSD-2) + the toysh glue: interactive line editing
# (history + TAB completion) over the kernel raw-mode tty
LINEEDIT_OBJS := $(BUILD)/linenoise.o $(BUILD)/sh_lineedit.o
$(BUILD)/linenoise.o: test/freertos/libs/linenoise/linenoise.c test/freertos/libs/linenoise/linenoise.h | $(BUILD)
	$(ARMCC) -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -fno-builtin \
	    -D_GNU_SOURCE -Ilibc-compat -Inewlib-pic/include -c $< -o $@
$(BUILD)/net_shim.o: test/freertos/libs/net_shim.c kernel/xtsys.h test/qemu/usys.h | $(BUILD)
	$(ARMCC) -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -fno-builtin \
	    -D_GNU_SOURCE -Ilibc-compat -Inewlib-pic/include -Itest/qemu -Ikernel -c $< -o $@
$(BUILD)/sh_lineedit.o: test/freertos/libs/sh_lineedit.c test/freertos/libs/linenoise/linenoise.h | $(BUILD)
	$(ARMCC) -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -fno-builtin \
	    -D_GNU_SOURCE -Ilibc-compat -Inewlib-pic/include -Itest/freertos/libs/linenoise -c $< -o $@
$(BUILD)/toybox.so: $(BUILD)/toybox/objects.list $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(REGEX_OBJS) $(LINEEDIT_OBJS) $(BUILD)/libc.so
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(REGEX_OBJS) $(LINEEDIT_OBJS) \
	    $$(cat $(BUILD)/toybox/objects.list) $(BUILD)/libc.so
	@# guard: an enabled applet whose .o failed to compile is dropped silently by
	@# the --shared link, leaving a dangling <applet>_main that only bites at load.
	@u=$$(arm-none-eabi-nm -u $@ | awk '/ U .*_main$$/{print $$2}'); \
	  if [ -n "$$u" ]; then echo "toybox.so: dropped applet object(s), undefined:" $$u >&2; exit 1; fi

# dropbear.so — the SSH server (third_party/dropbear submodule, MIT). build-dropbear.sh
# compiles the server object set + libtomcrypt/libtommath archives out-of-tree (submodule
# stays pristine); the link mirrors toybox.so (posix/net shim + dropbear_glue over libc.so).
# __aeabi_*/libc stay undefined = kernel-resolved dynamic imports. dropbearkey.o is excluded
# (its own main; the key generator is packaged separately).
# Rebuild the dropbear objects whenever the submodule sources, the port config, or
# the build script change — build-dropbear.sh recompiles the whole set. Without these
# deps the objects only rebuilt when objects.list was MISSING, so a submodule bump or
# config edit left stale .o's linked in (this exact staleness masked a fixed ssh-exec
# bug: dropbear ran an old exec dispatch until a forced recompile). See docs/Design.
$(BUILD)/dropbear/objects.list: tools/build-dropbear.sh \
    $(wildcard ../third_party/dropbear/src/*.c) $(wildcard ../third_party/dropbear/src/*.h) \
    $(wildcard dropbear-config/*.h)
	BUILDDIR=$(BUILD) tools/build-dropbear.sh
$(BUILD)/dropbear_glue.o: test/freertos/libs/dropbear_glue.c | $(BUILD)
	$(ARMCC) -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -fno-builtin \
	    -D_GNU_SOURCE -Ilibc-compat -Inewlib-pic/include -Itest/qemu -Ikernel -c $< -o $@
$(BUILD)/dropbear.so: $(BUILD)/dropbear/objects.list $(BUILD)/dropbear_glue.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/dropbear_glue.o \
	    $$(grep -v dropbearkey.o $(BUILD)/dropbear/objects.list) \
	    $(BUILD)/dropbear/libtomcrypt.a $(BUILD)/dropbear/libtommath.a $(BUILD)/libc.so
# dropbearkey.so — the SSH host-key generator (/bin/dropbearkey). Its own neutral object
# set (keyobjects.list); RUNS on XTOS: generates a valid ed25519 key + writes it.
$(BUILD)/dropbearkey.so: $(BUILD)/dropbear/objects.list $(BUILD)/dropbear_glue.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/dropbear_glue.o \
	    $$(cat $(BUILD)/dropbear/keyobjects.list) \
	    $(BUILD)/dropbear/libtomcrypt.a $(BUILD)/dropbear/libtommath.a $(BUILD)/libc.so

# ssh.so — the SSH CLIENT (dbclient) as /bin/ssh: outbound ssh from XTOS, and the
# program scp's do_cmd vfork+execs. Its own client-compiled object set (cliobjects.list).
$(BUILD)/ssh.so: $(BUILD)/dropbear/objects.list $(BUILD)/dropbear_glue.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/dropbear_glue.o \
	    $$(cat $(BUILD)/dropbear/cliobjects.list) \
	    $(BUILD)/dropbear/libtomcrypt.a $(BUILD)/dropbear/libtommath.a $(BUILD)/libc.so
# scp.so — /bin/scp: server mode (-t/-f, spawned by sshd-session for pushes/pulls) and
# client mode (execs /bin/ssh via the shim's fake-vfork).
$(BUILD)/scp.so: $(BUILD)/dropbear/objects.list $(BUILD)/dropbear_glue.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/dropbear_glue.o \
	    $$(cat $(BUILD)/dropbear/scpobjects.list) \
	    $(BUILD)/libc.so

# tnfs.so — /bin/tnfs: the TNFS client shell (libfujinet, ../fujinet — the
# SAME portable sources as the Mac tnfsh build) over the posix/net shims +
# libc.so. Step 1 of docs/OS/fujinet-network.md layer 2: proves TNFS over
# the XTOS socket surface before vfs_tnfs consumes the core in-kernel.
FUJINET  := ../fujinet
FUJILIB  := $(BUILD)/fuji_core.o $(BUILD)/fuji_udp.o $(BUILD)/fuji_tcp.o $(BUILD)/fuji_connect.o
FUJICFLAGS := -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -Os -fno-builtin \
    -D_GNU_SOURCE -Ilibc-compat -Inewlib-pic/include -Itest/qemu -Ikernel -I$(FUJINET)/include
$(BUILD)/fuji_core.o: $(FUJINET)/src/tnfs.c $(FUJINET)/include/fujinet/tnfs.h | $(BUILD)
	$(ARMCC) $(FUJICFLAGS) -c $< -o $@
$(BUILD)/fuji_udp.o: $(FUJINET)/src/tnfs_udp_posix.c $(FUJINET)/include/fujinet/tnfs.h | $(BUILD)
	$(ARMCC) $(FUJICFLAGS) -c $< -o $@
$(BUILD)/fuji_tcp.o: $(FUJINET)/src/tnfs_tcp_posix.c $(FUJINET)/include/fujinet/tnfs.h | $(BUILD)
	$(ARMCC) $(FUJICFLAGS) -c $< -o $@
$(BUILD)/fuji_connect.o: $(FUJINET)/src/tnfs_connect.c $(FUJINET)/include/fujinet/tnfs.h | $(BUILD)
	$(ARMCC) $(FUJICFLAGS) -c $< -o $@
$(BUILD)/fuji_shell.o: $(FUJINET)/shell/tnfsh.c $(FUJINET)/include/fujinet/tnfs.h | $(BUILD)
	$(ARMCC) $(FUJICFLAGS) -c $< -o $@
$(BUILD)/fuji_daemon.o: $(FUJINET)/daemon/fujinetd.c $(FUJINET)/include/fujinet/tnfs.h | $(BUILD)
	$(ARMCC) $(FUJICFLAGS) -I$(SQLITE) -c $< -o $@
$(BUILD)/fuji_cli.o: $(FUJINET)/cli/fuji.c | $(BUILD)
	$(ARMCC) $(FUJICFLAGS) -c $< -o $@
# fuji — the CLI client of fujinetd (ping/servers/ls/stat/df/fetch)
$(BUILD)/fuji.so: $(BUILD)/fuji_cli.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/fuji_cli.o \
	    $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
$(BUILD)/tnfs.so: $(FUJILIB) $(BUILD)/fuji_shell.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
	$(LLD) -shared --hash-style=sysv -o $@ $(FUJILIB) $(BUILD)/fuji_shell.o \
	    $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so
# fujinetd — the FujiNet daemon (loopback control port; started by the SD
# boot script sd/boot/40-FujiNet; kill/restart-safe)
$(BUILD)/fujinetd.so: $(FUJILIB) $(BUILD)/fuji_daemon.o $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so $(BUILD)/libm.so
	$(LLD) -shared --hash-style=sysv -o $@ $(FUJILIB) $(BUILD)/fuji_daemon.o \
	    $(BUILD)/sqlite3.o $(BUILD)/sqlite_vfs.o \
	    $(BUILD)/posix_shim.o $(BUILD)/net_shim.o $(BUILD)/libc.so $(BUILD)/libm.so

# vmtest — DT_NEEDED libc.so; touches the per-process private window (T2-b)
$(BUILD)/vmtest.so: test/freertos/progs/vmtest.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/vmtest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/vmtest.o $(BUILD)/libc.so

# shmtest — shared memory across two processes (fs-pagecache shm primitive)
$(BUILD)/shmtest.so: test/freertos/progs/shmtest.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/shmtest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/shmtest.o $(BUILD)/libc.so

$(BUILD)/demandtest.so: test/freertos/progs/demandtest.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/demandtest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/demandtest.o $(BUILD)/libc.so

$(BUILD)/stacktest.so: test/freertos/progs/stacktest.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/stacktest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/stacktest.o $(BUILD)/libc.so

$(BUILD)/wxtest.so: test/freertos/progs/wxtest.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/wxtest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/wxtest.o $(BUILD)/libc.so

$(BUILD)/cowtest.so: test/freertos/progs/cowtest.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/cowtest.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/cowtest.o $(BUILD)/libc.so

$(BUILD)/sharetext.so: test/freertos/progs/sharetext.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/sharetext.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/sharetext.o $(BUILD)/libc.so

$(BUILD)/finictor.so: test/freertos/progs/finictor.c $(BUILD)/libc.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -Inewlib-pic/include -c $< -o $(BUILD)/finictor.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/finictor.o $(BUILD)/libc.so

$(BUILD)/mkromfs: tools/mkromfs.c | $(BUILD)
	$(HOSTCC) -O2 -o $@ $<

# ---- drop-in romfs overlay -------------------------------------------------
# Anything under $(ROMFS_OVERLAY)/ is packed into the romfs (mounted at /System),
# mirroring the subtree: $(ROMFS_OVERLAY)/Library/libfoo.so -> /System/Library/libfoo.so. Just
# drop a file in and rebuild (make freertos) — no Makefile edit needed. `make
# overlay` creates the dirs + lists current contents.
ROMFS_OVERLAY ?= romfs-overlay
ROMFS_OVERLAY_FILES := $(shell find $(ROMFS_OVERLAY) -type f 2>/dev/null)
ROMFS_OVERLAY_ARGS  := $(foreach f,$(ROMFS_OVERLAY_FILES),/$(patsubst $(ROMFS_OVERLAY)/%,%,$(f))=$(f))

# Bundled GEM assets (tracked in ../gem, unlike the gitignored overlay): a fallback
# font + theme packed under romfs /System, so the desktop runs without SD assets (qemu /
# fresh card). Runtime paths become /System/fonts/... and /System/themes/... .
ROMFS_ASSET_FILES := ../gem/fonts/AovelSansRounded.ttf \
                     ../gem/themes/Aristo2/1x/artwork.tex \
                     ../gem/themes/Aristo2/1x/locations.txt \
                     ../gem/themes/Aristo2/1x/theme.ini
ROMFS_ASSET_ARGS := /fonts/AovelSansRounded.ttf=../gem/fonts/AovelSansRounded.ttf \
                    /themes/Aristo2/1x/artwork.tex=../gem/themes/Aristo2/1x/artwork.tex \
                    /themes/Aristo2/1x/locations.txt=../gem/themes/Aristo2/1x/locations.txt \
                    /themes/Aristo2/1x/theme.ini=../gem/themes/Aristo2/1x/theme.ini

# The authored desktop dialog resource (New…, Confirm, Add-Server): shipped to the
# SD at /OS/Apps/Desktop (sdstage), and packed into the romfs so the desktop finds a
# copy at /System/OS/Apps/Desktop when there is no SD (qemu / a bare card).
DESKTOP_RSC := ../gem/resources/desktop.rsc

$(BUILD)/romfs.bin: $(BUILD)/mkromfs $(BUILD)/tnfs.so $(BUILD)/fujinetd.so $(BUILD)/fuji.so $(BUILD)/toybox.so $(BUILD)/sqlite3.so $(BUILD)/pipetest.so $(BUILD)/svctest.so $(BUILD)/hello.so $(BUILD)/motd.so $(BUILD)/usestr.so $(BUILD)/echo.so $(BUILD)/libc_test.so $(BUILD)/gemtext.so $(BUILD)/gemd.so $(BUILD)/desktop.so $(BUILD)/regtest.so $(BUILD)/locktest.so $(BUILD)/lntest.so $(BUILD)/fstest.so $(BUILD)/lua.so $(BUILD)/init.so $(BUILD)/faultprog.so $(BUILD)/vmtest.so $(BUILD)/demandtest.so $(BUILD)/stacktest.so $(BUILD)/wxtest.so $(BUILD)/cowtest.so $(BUILD)/sharetext.so $(BUILD)/shmtest.so $(BUILD)/finictor.so $(BUILD)/mmaptest.so $(BUILD)/modetest.so $(BUILD)/ttytest.so $(BUILD)/jobctl.so $(BUILD)/socktest.so $(BUILD)/httpd.so $(BUILD)/nstress.so $(BUILD)/dmesg.so $(BUILD)/mem.so $(BUILD)/speed.so $(BUILD)/scale.so $(BUILD)/badpoke.so $(BUILD)/stackpoke.so $(BUILD)/dropbearkey.so $(BUILD)/dropbear.so $(BUILD)/sshd.so $(BUILD)/netup.so $(BUILD)/ssh.so $(BUILD)/scp.so $(BUILD)/strace.so $(BUILD)/sigtest.so $(BUILD)/libutil.so $(BUILD)/libGEM.so $(BUILD)/libm.so $(BUILD)/libxtos.so $(BUILD)/libc.so test/freertos/Registry.db $(DESKTOP_RSC) $(ROMFS_OVERLAY_FILES) $(ROMFS_ASSET_FILES) $(BUILD)/blittest.so
	$(BUILD)/mkromfs $@ \
	    /OS/Apps/Desktop/desktop.rsc=$(DESKTOP_RSC) \
	    /bin/faultprog=$(BUILD)/faultprog.so \
	    /bin/vmtest=$(BUILD)/vmtest.so \
	    /bin/demandtest=$(BUILD)/demandtest.so \
	    /bin/stacktest=$(BUILD)/stacktest.so \
	    /bin/wxtest=$(BUILD)/wxtest.so \
	    /bin/cowtest=$(BUILD)/cowtest.so \
	    /bin/sharetext=$(BUILD)/sharetext.so \
	    /bin/shmtest=$(BUILD)/shmtest.so \
	    /bin/blittest=$(BUILD)/blittest.so \
	    /bin/finictor=$(BUILD)/finictor.so \
	    /bin/modetest=$(BUILD)/modetest.so \
	    /bin/badpoke=$(BUILD)/badpoke.so \
	    /bin/stackpoke=$(BUILD)/stackpoke.so \
	    /bin/mmaptest=$(BUILD)/mmaptest.so \
	    /bin/ssh-keygen=$(BUILD)/dropbearkey.so \
	    /bin/sshd-session=$(BUILD)/dropbear.so \
	    /bin/sshd=$(BUILD)/sshd.so \
	    /bin/netup=$(BUILD)/netup.so \
	    /bin/ssh=$(BUILD)/ssh.so \
	    /bin/scp=$(BUILD)/scp.so \
	    /bin/strace=$(BUILD)/strace.so \
	    /bin/sigtest=$(BUILD)/sigtest.so \
	    $(if $(XTC_SO),/bin/xtcprog=$(XTC_SO)) \
	    /Library/libc.so=$(BUILD)/libc.so \
	    /Library/libm.so=$(BUILD)/libm.so \
	    /Library/libxtos.so=$(BUILD)/libxtos.so \
	    /Library/libGEM.so=$(BUILD)/libGEM.so \
	    $(if $(SD_TEST),,/Library/libutil.so=$(BUILD)/libutil.so) \
	    /bin/libc_test=$(BUILD)/libc_test.so \
	    /bin/gemtext=$(BUILD)/gemtext.so \
	    /bin/gemd=$(BUILD)/gemd.so \
	    /bin/desktop=$(BUILD)/desktop.so \
	    /bin/regtest=$(BUILD)/regtest.so \
	    /bin/locktest=$(BUILD)/locktest.so \
	    /bin/lntest=$(BUILD)/lntest.so \
	    /bin/fstest=$(BUILD)/fstest.so \
	    /bin/pipetest=$(BUILD)/pipetest.so \
	    /bin/svctest=$(BUILD)/svctest.so \
	    /bin/ttytest=$(BUILD)/ttytest.so \
	    /bin/fg=$(BUILD)/jobctl.so \
	    /bin/bg=$(BUILD)/jobctl.so \
	    /bin/jobs=$(BUILD)/jobctl.so \
	    /bin/socktest=$(BUILD)/socktest.so \
	    /bin/httpd=$(BUILD)/httpd.so \
	    /bin/nstress=$(BUILD)/nstress.so \
	    /bin/dmesg=$(BUILD)/dmesg.so \
	    /bin/mem=$(BUILD)/mem.so \
	    /bin/speed=$(BUILD)/speed.so \
	    /bin/scale=$(BUILD)/scale.so \
	    /bin/tnfs=$(BUILD)/tnfs.so \
	    /bin/fujinetd=$(BUILD)/fujinetd.so \
	    /bin/fuji=$(BUILD)/fuji.so \
	    /test/Registry.db=test/freertos/Registry.db \
	    /bin/lua=$(BUILD)/lua.so \
	    /bin/sqlite3=$(BUILD)/sqlite3.so \
	    $(TOYBOX_ALIASES) \
	    /bin/init=$(BUILD)/init.so \
	    /bin/hello=$(BUILD)/hello.so \
	    /bin/motd=$(BUILD)/motd.so \
	    /bin/usestr=$(BUILD)/usestr.so \
	    $(ROMFS_ASSET_ARGS) \
	    $(ROMFS_OVERLAY_ARGS)

$(BUILD)/romfs_blob.h: $(BUILD)/romfs.bin
	@{ printf '__attribute__((aligned(4096))) unsigned char romfs_blob[] = {\n'; \
	   od -An -v -tx1 $< | sed -e 's/[0-9a-fA-F][0-9a-fA-F]/0x&,/g'; \
	   printf '};\nunsigned int romfs_blob_len = sizeof(romfs_blob);\n'; } > $@

# ---- HW romfs: slim ----------------------------------------------------------
# The SD carries toybox + sqlite3 + the GEM stack (`make sdstage` -> copy onto
# the card); the romfs keeps only what must exist without/before the SD: the
# base libraries every spawn needs (libc/libm), init + lua (the boot runner and
# its #!/bin/lua scripts), motd, and the tier-2 test battery. ~6 MB of RAM back
# vs the full image. qemu keeps the full romfs (no SD there).
$(BUILD)/romfs-hw.bin: $(BUILD)/mkromfs $(BUILD)/pipetest.so $(BUILD)/svctest.so $(BUILD)/hello.so $(BUILD)/motd.so $(BUILD)/usestr.so $(BUILD)/libc_test.so $(BUILD)/locktest.so $(BUILD)/lntest.so $(BUILD)/fstest.so $(BUILD)/lua.so $(BUILD)/init.so $(BUILD)/faultprog.so $(BUILD)/vmtest.so $(BUILD)/demandtest.so $(BUILD)/stacktest.so $(BUILD)/wxtest.so $(BUILD)/cowtest.so $(BUILD)/sharetext.so $(BUILD)/shmtest.so $(BUILD)/finictor.so $(BUILD)/mmaptest.so $(BUILD)/modetest.so $(BUILD)/ttytest.so $(BUILD)/jobctl.so $(BUILD)/socktest.so $(BUILD)/httpd.so $(BUILD)/nstress.so $(BUILD)/dmesg.so $(BUILD)/mem.so $(BUILD)/speed.so $(BUILD)/scale.so $(BUILD)/badpoke.so $(BUILD)/stackpoke.so $(BUILD)/dropbearkey.so $(BUILD)/dropbear.so $(BUILD)/sshd.so $(BUILD)/netup.so $(BUILD)/ssh.so $(BUILD)/scp.so $(BUILD)/strace.so $(BUILD)/sigtest.so $(BUILD)/libc.so $(BUILD)/blittest.so
	$(BUILD)/mkromfs $@ \
	    /bin/faultprog=$(BUILD)/faultprog.so \
	    /bin/vmtest=$(BUILD)/vmtest.so \
	    /bin/demandtest=$(BUILD)/demandtest.so \
	    /bin/stacktest=$(BUILD)/stacktest.so \
	    /bin/wxtest=$(BUILD)/wxtest.so \
	    /bin/cowtest=$(BUILD)/cowtest.so \
	    /bin/sharetext=$(BUILD)/sharetext.so \
	    /bin/shmtest=$(BUILD)/shmtest.so \
	    /bin/blittest=$(BUILD)/blittest.so \
	    /bin/finictor=$(BUILD)/finictor.so \
	    /bin/modetest=$(BUILD)/modetest.so \
	    /bin/badpoke=$(BUILD)/badpoke.so \
	    /bin/stackpoke=$(BUILD)/stackpoke.so \
	    /bin/mmaptest=$(BUILD)/mmaptest.so \
	    /bin/ssh-keygen=$(BUILD)/dropbearkey.so \
	    /bin/sshd-session=$(BUILD)/dropbear.so \
	    /bin/sshd=$(BUILD)/sshd.so \
	    /bin/netup=$(BUILD)/netup.so \
	    /bin/ssh=$(BUILD)/ssh.so \
	    /bin/scp=$(BUILD)/scp.so \
	    /bin/strace=$(BUILD)/strace.so \
	    /bin/sigtest=$(BUILD)/sigtest.so \
	    $(if $(XTC_SO),/bin/xtcprog=$(XTC_SO)) \
	    /Library/libc.so=$(BUILD)/libc.so \
	    /bin/libc_test=$(BUILD)/libc_test.so \
	    /bin/locktest=$(BUILD)/locktest.so \
	    /bin/lntest=$(BUILD)/lntest.so \
	    /bin/fstest=$(BUILD)/fstest.so \
	    /bin/pipetest=$(BUILD)/pipetest.so \
	    /bin/svctest=$(BUILD)/svctest.so \
	    /bin/ttytest=$(BUILD)/ttytest.so \
	    /bin/fg=$(BUILD)/jobctl.so \
	    /bin/bg=$(BUILD)/jobctl.so \
	    /bin/jobs=$(BUILD)/jobctl.so \
	    /bin/socktest=$(BUILD)/socktest.so \
	    /bin/httpd=$(BUILD)/httpd.so \
	    /bin/nstress=$(BUILD)/nstress.so \
	    /bin/dmesg=$(BUILD)/dmesg.so \
	    /bin/mem=$(BUILD)/mem.so \
	    /bin/speed=$(BUILD)/speed.so \
	    /bin/scale=$(BUILD)/scale.so \
	    /bin/lua=$(BUILD)/lua.so \
	    /bin/init=$(BUILD)/init.so \
	    /bin/hello=$(BUILD)/hello.so \
	    /bin/motd=$(BUILD)/motd.so \
	    /bin/usestr=$(BUILD)/usestr.so
	# NB: the HW romfs is deliberately SLIM.  A library is EITHER romfs-base (never
	# on the SD) OR SD-updateable (never in romfs) — never both, or the romfs copy
	# silently shadows the card (loader searches romfs /Library first, dedups by
	# soname, never unloads).  Only libc.so is irreducibly romfs-base: the kernel
	# bootstrap-loads it (main.c: frtos_activate_libc) before the scheduler/SD
	# exist and routes its own malloc through it, so it can't come from the card
	# and must never be duplicated there.  Everything else user-modifiable —
	# libm/libutil, fonts, themes, overlay libs — is SD-only (see `sdstage`).
	# /bin stays in romfs on purpose (trusted, un-swappable).  QEMU keeps the full
	# set (romfs.bin) — it has no SD.

$(BUILD)/hwromfs/romfs_blob.h: $(BUILD)/romfs-hw.bin
	@mkdir -p $(BUILD)/hwromfs
	@{ printf '__attribute__((aligned(4096))) unsigned char romfs_blob[] = {\n'; \
	   od -An -v -tx1 $< | sed -e 's/[0-9a-fA-F][0-9a-fA-F]/0x&,/g'; \
	   printf '};\nunsigned int romfs_blob_len = sizeof(romfs_blob);\n'; } > $@

# ---- SD staging: the card's /OS additions for the slim HW image --------------
# Copy build/sdstage/OS/* onto the card, then run ONCE on XTOS:
#   sh /OS/bin/install-links.sh
# (creates the toybox applet symlinks; sh ships as a full copy of toybox so the
# login shell exists before the links do)
SDSTAGE := $(BUILD)/sdstage
.PHONY: sdstage
sdstage: $(BUILD)/toybox.so $(BUILD)/sqlite3.so $(BUILD)/fbgrab.so $(BUILD)/blitbench.so $(BUILD)/libGEM.so $(BUILD)/libxtos.so $(BUILD)/libm.so $(BUILD)/libutil.so $(BUILD)/desktop.so $(BUILD)/gemtext.so $(BUILD)/gemd.so $(BUILD)/regtest.so $(BUILD)/tnfs.so $(BUILD)/fujinetd.so $(BUILD)/fuji.so $(DESKTOP_RSC) $(ROMFS_OVERLAY_FILES) $(ROMFS_ASSET_FILES)
	@rm -rf $(SDSTAGE)
	@mkdir -p $(SDSTAGE)/OS/bin $(SDSTAGE)/OS/library $(SDSTAGE)/OS/etc $(SDSTAGE)/OS/boot $(SDSTAGE)/OS/fonts $(SDSTAGE)/OS/themes/Aristo2/1x $(SDSTAGE)/OS/Apps/Desktop/Spaces/1
	cp sd/boot/* $(SDSTAGE)/OS/boot/
	cp $(DESKTOP_RSC) $(SDSTAGE)/OS/Apps/Desktop/desktop.rsc
	cp $(BUILD)/toybox.so  $(SDSTAGE)/OS/bin/toybox
	cp $(BUILD)/toybox.so  $(SDSTAGE)/OS/bin/sh
	cp $(BUILD)/sqlite3.so $(SDSTAGE)/OS/bin/sqlite3
	cp $(BUILD)/desktop.so $(SDSTAGE)/OS/bin/desktop
	cp $(BUILD)/gemtext.so $(SDSTAGE)/OS/bin/gemtext
	cp $(BUILD)/gemd.so    $(SDSTAGE)/OS/bin/gemd
	cp $(BUILD)/fbgrab.so  $(SDSTAGE)/OS/bin/fbgrab
	cp $(BUILD)/blitbench.so $(SDSTAGE)/OS/bin/blitbench
	cp $(BUILD)/regtest.so $(SDSTAGE)/OS/bin/regtest
	cp $(BUILD)/httpd.so   $(SDSTAGE)/OS/bin/httpd
	cp $(BUILD)/tnfs.so    $(SDSTAGE)/OS/bin/tnfs
	cp $(BUILD)/fujinetd.so $(SDSTAGE)/OS/bin/fujinetd
	cp $(BUILD)/fuji.so    $(SDSTAGE)/OS/bin/fuji
	cp $(BUILD)/libGEM.so  $(SDSTAGE)/OS/library/libGEM.so
	mkdir -p $(SDSTAGE)/OS/roms
	cp ../rsrc/atari-xl.rom ../rsrc/atari-basic.rom $(SDSTAGE)/OS/roms/
	cp $(BUILD)/libxtos.so $(SDSTAGE)/OS/library/libxtos.so
	# libm/libutil — off the HW romfs, card is authoritative.  NOT libc: it's
	# bootstrap-loaded from romfs before the SD exists, so an SD copy would be a
	# dead, soname-shadowed duplicate (the "two libc's" trap) — libc is romfs-only.
	cp $(BUILD)/libm.so    $(SDSTAGE)/OS/library/libm.so
	cp $(BUILD)/libutil.so $(SDSTAGE)/OS/library/libutil.so
	# overlay libs (libXTGem / libSpike*) — were romfs-only; ship on the card too
	cp romfs-overlay/Library/*.so $(SDSTAGE)/OS/library/
	# overlay apps (romfs-overlay/bin/*) — same deal: an app dropped in the overlay was
	# reachable in qemu but NOT on the card, so it could never be run on the real display.
	# `-` because the directory is legitimately empty in a clean tree.
	-cp romfs-overlay/bin/* $(SDSTAGE)/OS/bin/ 2>/dev/null || true
	# font + theme atlas — user-modifiable content, off the read-only romfs
	cp ../gem/fonts/AovelSansRounded.ttf $(SDSTAGE)/OS/fonts/AovelSansRounded.ttf
	cp ../gem/themes/Aristo2/1x/artwork.tex ../gem/themes/Aristo2/1x/locations.txt \
	   ../gem/themes/Aristo2/1x/theme.ini $(SDSTAGE)/OS/themes/Aristo2/1x/
	@printf 'Aristo2\n' > $(SDSTAGE)/OS/themes/Default   # read_default() -> theme name
	@printf '# XTOS /OS/etc/hosts — static name -> address (checked before DNS)\n127.0.0.1\tlocalhost xtos\n' > $(SDSTAGE)/OS/etc/hosts
	cp tools/tz.tab $(SDSTAGE)/OS/etc/tz.tab
	@printf 'Europe/London\n' > $(SDSTAGE)/OS/etc/timezone
	@printf '# XTOS /OS/etc/resolv.conf — static DNS (supplements DHCP option 6).\n# Uncomment to force a resolver.\n#nameserver 1.1.1.1\n' > $(SDSTAGE)/OS/etc/resolv.conf
	@printf 'for i in %s; do /OS/bin/toybox ln -sf toybox /OS/bin/$$i; done\necho "applet links installed"\n' \
	    "$(filter-out toybox,$(TOYBOX_APPLETS))" > $(SDSTAGE)/OS/bin/install-links.sh
	@echo "staged -> $(SDSTAGE)/OS; copy onto the card, then run: sh /OS/bin/install-links.sh"

# Push the staged /OS tree to a RUNNING board over TFTP (no card eject) — only
# files that changed since the last push. Then cold-load the kernel to pick up
# the changes.  Board defaults to xtos.local (mDNS); override with BOARD=<ip>.
#   make sdpush                 # -> xtos.local
#   make sdpush BOARD=192.168.1.9
.PHONY: sdpush
BOARD ?= xtos.local
sdpush: sdstage
	tools/sdpush.sh $(SDSTAGE) $(BOARD)

$(BUILD):
	@mkdir -p $(BUILD)

# Drop-in romfs overlay helper: create the dirs + show what will be packed.
# Drop a pre-built .so into $(ROMFS_OVERLAY)/Library/ then `make freertos`.
.PHONY: overlay
overlay:
	@mkdir -p $(ROMFS_OVERLAY)/Library $(ROMFS_OVERLAY)/Fonts $(ROMFS_OVERLAY)/etc
	@echo "romfs overlay '$(ROMFS_OVERLAY)/' -> packed into the romfs under /OS:"
	@echo "  e.g. $(ROMFS_OVERLAY)/Library/libfoo.so  ->  /OS/Library/libfoo.so"
	@echo "then: make freertos   (qemu)   or   make build/freertos-hw.elf   (HW)"
	@echo "current overlay files:"; \
	  find $(ROMFS_OVERLAY) -type f 2>/dev/null | sed 's#^$(ROMFS_OVERLAY)/#  /OS/#' | sort; \
	  [ -n "$(ROMFS_OVERLAY_FILES)" ] || echo "  (none)"

clean:
	rm -rf $(BUILD)
