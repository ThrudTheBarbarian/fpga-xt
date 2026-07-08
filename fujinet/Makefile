# libfujinet — TNFS client library + tnfsh shell (host build)
#
# macOS:  build/libfujinet.dylib + build/tnfsh
# Linux:  build/libfujinet.so   + build/tnfsh
#
# The XTOS board build reuses src/tnfs.c unchanged behind a net_shim
# transport, compiled as a PIC .so by the loader/ toolchain.

UNAME    := $(shell uname -s)
BUILD    := build
CC       ?= cc
CFLAGS   ?= -O2 -g -Wall -Wextra -std=c99
CPPFLAGS += -Iinclude
CFLAGS   += -fPIC

ifeq ($(UNAME),Darwin)
SHLIB   := $(BUILD)/libfujinet.dylib
SHFLAGS := -dynamiclib -install_name @rpath/libfujinet.dylib
RPATH   := -Wl,-rpath,@executable_path
else
SHLIB   := $(BUILD)/libfujinet.so
SHFLAGS := -shared -Wl,-soname,libfujinet.so
RPATH   := -Wl,-rpath,'$$ORIGIN'
endif

LIBSRC := src/tnfs.c src/tnfs_udp_posix.c src/tnfs_tcp_posix.c
HDRS   := include/fujinet/tnfs.h

all: $(SHLIB) $(BUILD)/tnfsh

$(SHLIB): $(LIBSRC) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(CPPFLAGS) $(SHFLAGS) -o $@ $(LIBSRC)

$(BUILD)/tnfsh: shell/tnfsh.c $(SHLIB) $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ shell/tnfsh.c -L$(BUILD) -lfujinet $(RPATH)

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean
