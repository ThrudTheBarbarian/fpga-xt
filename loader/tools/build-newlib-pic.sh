#!/bin/sh
# Build a position-independent newlib for the Cortex-A9 (softfp) and assemble
# loader/newlib-pic/{libc.a,libm.a,include/} — the basis for /OS/Library/libc.so.
# Output is gitignored; run once (~10 min). Needs arm-none-eabi-gcc + curl on PATH.
#
# Why: the toolchain ships newlib as a STATIC, non-PIC libc.a (MOVW/MOVT ABS
# relocs) that ld refuses to put in a shared object. We rebuild newlib with
# -fPIC so libc.a links cleanly into a loadable libc.so (only R_ARM_RELATIVE/
# GLOB_DAT/ABS32/JUMP_SLOT). Inject ONLY -fPIC (not arch flags) so every
# multilib keeps its own arch flags; we then pick the cortex-a9 variant.
set -e
VER=4.4.0.20231231
DST=$(cd "$(dirname "$0")/.." && pwd)/newlib-pic
WORK=${TMPDIR:-/tmp}/newlib-pic-build
mkdir -p "$WORK"; cd "$WORK"
[ -f newlib.tar.gz ] || curl -fsSL -o newlib.tar.gz "https://sourceware.org/pub/newlib/newlib-$VER.tar.gz"
[ -d "newlib-$VER" ] || tar xzf newlib.tar.gz
rm -rf b && mkdir b && cd b
"../newlib-$VER/configure" --target=arm-none-eabi --disable-newlib-supplied-syscalls --disable-nls \
  CFLAGS_FOR_TARGET="-g -O2 -fPIC -ffunction-sections -fdata-sections"
make all-target-newlib -j4
ML=arm-none-eabi/thumb/v7-a+simd/softfp/newlib            # cortex-a9 softfp multilib
mkdir -p "$DST/include/machine"
cp "$ML/libc.a" "$ML/libm.a" "$DST/"
cp -R "../newlib-$VER/newlib/libc/include/." "$DST/include/"
cp "$ML/targ-include/newlib.h" "$ML/targ-include/_newlib_version.h" "$DST/include/" 2>/dev/null || true
[ -d "$ML/targ-include/machine" ] && cp -R "$ML/targ-include/machine/." "$DST/include/machine/" || true
echo "newlib-pic ready: $DST"
