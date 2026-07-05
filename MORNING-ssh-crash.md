# Morning: the Ctrl-D session-teardown crash

**Status:** not yet fixed. I could not reproduce it in qemu (it needs the real
FatFs SD, which qemu doesn't have), so instead I built a **diagnostic HW image
that will name the faulting function on the next Ctrl-D**. One JTAG load + one
Ctrl-D + one `objdump` command tells us exactly where it dies.

## Do this first (5 minutes → exact location)

1. Power-cycle, then from the worktree:
   ```
   cd /Users/simon/src/fpga-xt-ssh && ./vivado/jtag-valhalla.sh testbed
   ```
2. `ssh xtos.local`, then press **Ctrl-D**. You'll get a crash dump, now with
   `[prog+0x…]` / `[libc+0x…]` after PC and CALLER, e.g.:
   ```
   PC=0x028e1904 [prog+0x0003bXXX]  CALLER=0x000f4240 [??+0x…]
   ```
3. Read me the two `[...]` tags. If CALLER (or PC) shows `[prog+0xNNNN]`, the
   function is:
   ```
   arm-none-eabi-objdump -d loader/build/dropbear.so | grep -B40 'NNNN:' | grep '>:' | tail -1
   ```
   (or just paste the offset — do NOT rebuild dropbear first, or the offsets
   shift. `build/dropbear.so` from 21:04 matches the loaded image.)

## Two quick A/B experiments (narrow it further)

- **Is it the logfile fd?** Start sshd WITHOUT a logfile: at the console run
  `sshd 22 /OS/etc/ssh/ed25519_host_key` (no 4th arg), then ssh in and Ctrl-D.
  No crash ⇒ it's the FatFs logfile-as-stderr. Crash ⇒ not the logfile.
- **Is it EOF-specific?** ssh in and type `exit` instead of Ctrl-D. Clean ⇒
  EOF/teardown-order specific; crash ⇒ any session exit.

## What I already know

- It's **return-address / function-pointer corruption in sshd-session's own
  context** (not the fs task): `IFSR=0x0f` is a *permission* fault — the CPU
  jumped into the execute-never **data** segment (a corrupted pointer pointing
  at data). `CALLER=0x000f4240` = exactly 1,000,000, a garbage value sitting
  where a code pointer belongs.
- **Not** a plain stack overflow (the guard page wasn't hit — no "STACK
  OVERFLOW" line), and **not a stack-buffer overflow** either: I rebuilt
  dropbear with `-fstack-protector-all` and ran Ctrl-D in qemu — the canary
  never fired. So it's a **wild-pointer write / use-after-free / type
  confusion**, which is exactly what the symbolized `CALLER` pinpoints (the
  function that made the bad call stays in `.text`).
- **HW-only.** qemu has no FatFs SD; I replicated the *logical* conditions
  (session cwd `/media/home`, `~/.ssh` authorized_keys, logfile on a real fs
  via a ramfs `/media`) and it did **not** crash. So the trigger is specific to
  the FatFs code path or HW memory/timing.
- **Prime suspect:** the fake-vfork `execchild` path (pty sessions only; the
  non-pty `ssh host cmd` path uses a *simple* vfork child and doesn't crash).
  On XTOS there's no real fork — `vfork()` is a register snapshot and exec does
  NOT replace the image, so everything `execchild`/`run_command` do before exec
  runs in **dropbear's own process** and persists: it wipes `environ`, rewrites
  it, calls `signal()` (now routed to the shim's g_sigact), closes fds 3..maxfd
  (my deferred-close protects those), chdirs. Any of that could plant a bad
  pointer that's dereferenced at teardown. The symbolized CALLER will tell us
  which function actually makes the bad call.

## What's safe and done (committed, on ssh-server)

- **Console log fix you asked for** (commit 877c058): `netup` and `sshd`'s
  "listening" line now go to **dmesg** (SYS_klog → /proc/kmsg + system.log),
  not the console. The console keeps only init's `[ OK ]/[FAIL]`. sshd's line
  still also lands in its own sshd.log.
- The diagnostic **fault symbolization** (same commit).

The HW image `loader/build/freertos-hw.elf` (21:30) has all of this. It is safe
to run — the crash is unchanged, but now it's diagnosable.
