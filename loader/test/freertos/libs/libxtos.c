/*
 * libxtos.c — the XT syscall ABI as REAL, callable symbols.
 *
 * XTOS's XT-specific syscalls (sys_fb_info/present/wallpaper, sys_input,
 * sys_xtos_recv, sys_overlay, sys_kbd_6502, ...) exist only as `static inline`
 * wrappers in usys.h — a C-only, compile-time interface.  Any language that
 * can't inline the `svc #1` (Rust, Zig, xtc, a hand-linked .so) is therefore
 * locked out of the machine's own display/input/messaging: libc.so exposes the
 * POSIX half of the ABI as real symbols, but nothing exposes the XT half.
 *
 * This library closes that gap.  Rather than hand-copy ~55 one-line wrappers
 * (and let them drift from the frozen ABI), it *includes* usys.h with the
 * `static inline` storage-class stripped, so every wrapper becomes an exported
 * symbol.  Add a syscall to usys.h and it appears here for free — usys.h stays
 * the single source of truth.
 *
 * The stdint.h / xtsys.h prerequisites are pulled in normally first (with their
 * include guards intact), so the strip only ever touches usys.h's own wrappers.
 *
 * Exported names match usys.h verbatim (sys_fb_info, sys_input, ...) and do NOT
 * collide with libc.so, which exports the POSIX names (write, open, ...), not
 * the raw sys_* ones.  __syscall is exported too, as a raw svc primitive.
 */
#include <stdint.h>
#include "xtsys.h"   /* struct xt_stat/os_event/... + SYS_ numbers (guarded) */

#define static       /* strip the storage class: each wrapper becomes a symbol */
#define inline
#include "usys.h"    /* its <stdint.h>/xtsys.h includes are guarded no-ops here */
#undef static
#undef inline
