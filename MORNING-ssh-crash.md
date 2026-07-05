# Morning: the ssh session-teardown hang/crash

**Status: root cause localized, NOT fixed.** Big update from last night — I
reproduced the hang in qemu (it needs no HW), and the "crash" and the "hang" are
the same bug seen two ways.

## What it actually is

An interactive `ssh -tt` session **hangs when the shell exits** — on `exit`
*or* Ctrl-D (my earlier "exit works" belief was wrong; those tests piped stdin,
which closed the connection and masked it). On the board, after hanging, dropbear
eventually crashes; the crash PC symbolized to **`nanosleep`** — dropbear spinning
in its `select`→`poll`→`usleep` loop, i.e. the hang, not a separate fault.

**Two distinct defects feed the hang:**

1. **dropbear never reaps the exited shell.** dropbear closes a pty session only
   after it reaps the child (sets `chansess->exit.exitpid`) via
   `waitpid(-1, WNOHANG)` in its select-loop handler. On XTOS that `waitpid`
   returns nothing: `sys_waitpid_nb(pid)` returns **-11 (still running)** for the
   shell's pid — the one the shim's `g_kids` holds and `kadd` logged — even
   though `ps` (from a 2nd connection) shows the shell **gone**. So there's a
   **pid / `p->exited` tracking discrepancy** for a child spawned through the
   fake-vfork → `execve` → `SYS_spawn_fd` path. That's the thing to chase:
   - `frtos_waitpid_poll(pid)` returns -11 because `proc_by_pid(pid)->exited==0`.
   - But the shell process ended. So either the shell exits via a path that never
     sets `p->exited` (blocked in its own teardown?), or `g_kids`'s pid ≠ the
     shell's actual kernel pid.
   - Next step: trace, in the shell's own exit path, whether `p->exited` gets set
     for that pid; and log the pid `SYS_spawn_fd` returns vs the pid `ps` shows.

2. **Ctrl-D specifically doesn't exit the shell** (independent of #1). linenoise
   correctly reads 0x04 at an empty line and returns EOF (`errno=ENOENT`), and
   `xt_line_input` returns 0 (EOF) — verified by tracing. But **toysh doesn't act
   on that EOF** (doesn't exit, doesn't re-prompt). A toysh line-input
   integration gap, almost certainly pre-existing (Ctrl-D was never tested before).

## What I fixed (committed, correct, but incomplete — 897e5bf)

Verified in qemu; they're right regardless of the remaining bug:
- `pipes_release` releases pty-slave (char-device) fds immediately on exit →
  slave open-count drops 3→0 when the shell exits (was leaked until reap).
- `xt_pty_nread` reports readable at EOF so a poll wakes the master reader.
- `poll()` caps its wait at 200 ms when the caller has children, so dropbear's
  reap runs promptly instead of after its ~1 h `select` timeout (no async
  SIGCHLD on XTOS to wake `select`).

These get `sopen→0`, the master poll-readable, and dropbear's select returning
every 200 ms — all confirmed — but the session still hangs because of defect #1
(the reap sees the child as not-exited).

## Reproduce in qemu (no HW needed)

```
cd /Users/simon/src/fpga-xt-ssh/loader && make build/freertos.elf
( printf 'netup\nmkdir /media/home\nmkdir /media/home/.ssh\ncp /System/etc/ssh/authorized_keys /media/home/.ssh/authorized_keys\nssh-keygen -t ed25519 -f /tmp/hk >/dev/null 2>&1\nsshd 22 /tmp/hk\n'; sleep 600 ) | \
  qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
  -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
  -kernel build/freertos.elf -nic user,hostfwd=tcp::2222-:22
```
Then from the Mac, an interactive `ssh -tt -p 2222 … root@127.0.0.1`, type
`exit` → the client hangs. (A ramfs `/media` is mounted only in the qemu build so
`/media/home` exists — HW has it from the SD.) A Python `pty.fork` harness that
sends `exit\r` then `waitpid(WNOHANG)` on the ssh client is the cleanest
pass/fail; I left `/tmp/h4.py` shaped like that.

## The board build is fine to run

`loader/build/freertos-hw.elf` is a clean rebuild with the partial fixes + the
fault symbolization. Interactive login still works; only session *exit* hangs
(power-cycle out of it). Everything is committed on `ssh-server`.
