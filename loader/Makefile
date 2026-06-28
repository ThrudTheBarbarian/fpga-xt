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
BUILD := build
BARECFLAGS := -marm -mcpu=cortex-a15 -ffreestanding -nostdlib -O0 -g \
              -I. -I$(BUILD) -Ikernel -Itest/qemu

.PHONY: test dump clean qemu kernel
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

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
