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
ARMCFLAGS ?= -marm -fpic -Os -ffreestanding -fno-builtin

QEMU      := qemu-system-arm
QEMUFLAGS := -M virt -cpu cortex-a15 -nographic -no-reboot \
             -semihosting-config enable=on,target=native
# real FreeRTOS runs on the actual Zynq PS model
QEMUZYNQ  := qemu-system-arm -M xilinx-zynq-a9 -nographic -no-reboot -m 256M \
             -semihosting-config enable=on,target=native
BUILD := build
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

$(BUILD)/bare.elf: test/qemu/startup.S test/qemu/bare_main.c test/qemu/bare_rt.c xtld.c test/qemu/bare.ld $(BUILD)/testlib_so.h | $(BUILD)
	$(ARMCC) $(BARECFLAGS) -T test/qemu/bare.ld \
	    test/qemu/startup.S test/qemu/bare_main.c test/qemu/bare_rt.c xtld.c -o $@

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

KSRC := test/qemu/kmain.c test/qemu/bare_rt.c kernel/ksys.c xtld.c
KASM := test/qemu/startup.S kernel/arch_arm.S

$(BUILD)/kernel.elf: $(KASM) $(KSRC) test/qemu/bare.ld $(BUILD)/app_so.h kernel/ksys.h kernel/xtsys.h | $(BUILD)
	$(ARMCC) $(BARECFLAGS) -T test/qemu/bare.ld $(KASM) $(KSRC) -o $@

# --- the REAL Xilinx FreeRTOS kernel + CA9 port, on qemu's Zynq PS model -
FR     := ../third_party/freertos10_xilinx/src/Source
FRPORT := $(FR)/portable/GCC/ARM_CA9
FRINC  := -I. -I$(FR)/include -I$(FRPORT) -Itest/freertos -Itest/freertos/shim \
          -Itest/qemu -Ikernel -I$(BUILD)
FRCFLAGS := -marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -ffreestanding -nostdlib -O2 -g $(FRINC)
FRSRC := $(FR)/tasks.c $(FR)/queue.c $(FR)/list.c $(FR)/timers.c $(FR)/event_groups.c \
         $(FR)/croutine.c $(FR)/stream_buffer.c $(FR)/portable/MemMang/heap_4.c \
         $(FRPORT)/port.c \
         test/freertos/zynq.c test/freertos/bsp_shim.c test/freertos/frtos_os.c \
         test/freertos/romfs.c test/freertos/main.c test/qemu/bare_rt.c xtld.c
FRASM := test/freertos/xt_boot.S test/freertos/xt_vectors.S $(FRPORT)/portASM.S

# Stage 2 + M2: loader + svc gateway + spawn-by-path + file syscalls, on real FreeRTOS.
freertos: $(BUILD)/freertos.elf
	@echo "=== xtos: programs from a filesystem on real FreeRTOS (qemu xilinx-zynq-a9) ==="
	@$(QEMUZYNQ) -kernel $< ; echo "(qemu exited $$?)"

$(BUILD)/freertos.elf: $(FRSRC) $(FRASM) test/freertos/freertos.ld test/freertos/FreeRTOSConfig.h $(BUILD)/romfs_blob.h | $(BUILD)
	$(ARMCC) $(FRCFLAGS) -T test/freertos/freertos.ld $(FRASM) $(FRSRC) -lgcc -o $@

# --- romfs: build the programs as .so, pack them into a blob, embed it ---
PROGCFLAGS := $(ARMCFLAGS) -Itest/qemu

$(BUILD)/%.so: test/freertos/progs/%.c | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -c $< -o $(BUILD)/$*.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/$*.o

# a shared library carries a soname (the registry/dedup key)
$(BUILD)/libutil.so: test/freertos/libs/libutil.c | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -c $< -o $(BUILD)/libutil.o
	$(LLD) -shared --hash-style=sysv -soname libutil.so -o $@ $(BUILD)/libutil.o

# a program that links against the .so gets a DT_NEEDED + an unresolved import
$(BUILD)/usestr.so: test/freertos/progs/usestr.c $(BUILD)/libutil.so | $(BUILD)
	$(ARMCC) $(PROGCFLAGS) -c $< -o $(BUILD)/usestr.o
	$(LLD) -shared --hash-style=sysv -o $@ $(BUILD)/usestr.o $(BUILD)/libutil.so

$(BUILD)/mkromfs: tools/mkromfs.c | $(BUILD)
	$(HOSTCC) -O2 -o $@ $<

$(BUILD)/romfs.bin: $(BUILD)/mkromfs $(BUILD)/hello.so $(BUILD)/showmotd.so $(BUILD)/usestr.so $(BUILD)/libutil.so test/freertos/motd.txt
	$(BUILD)/mkromfs $@ \
	    /bin/hello=$(BUILD)/hello.so \
	    /bin/showmotd=$(BUILD)/showmotd.so \
	    /bin/usestr=$(BUILD)/usestr.so \
	    /OS/Library/libutil.so=$(BUILD)/libutil.so \
	    /etc/motd=test/freertos/motd.txt

$(BUILD)/romfs_blob.h: $(BUILD)/romfs.bin
	@{ printf 'unsigned char romfs_blob[] = {\n'; \
	   od -An -v -tx1 $< | sed -e 's/[0-9a-fA-F][0-9a-fA-F]/0x&,/g'; \
	   printf '};\nunsigned int romfs_blob_len = sizeof(romfs_blob);\n'; } > $@

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
