# The program loader serves a cached image when the file on disk has changed

**Status:** OPEN. Found 2026-07-29 while hardware-testing the TRNG.
**Component:** XTOS program loader (`xtld` / `frtos_spawn`), not the filesystem.

## Symptom

Overwrite an already-executed program and run it again: you get the **old**
program. The file on disk is correct — `md5sum` on the board matches the host
byte for byte, and `strings` shows the new text — but the running image is the
one first loaded from that path.

It is silent. Nothing reports a stale load, so it presents as "my change did
nothing", or worse as a mysterious partial execution: new code appears to be
skipped while the surrounding old code still runs.

## How it was found, and why it wastes so much time

Iterating on `/tmp/rngtest.so` over ssh. Added a line, rebuilt, copied, ran —
the new line never printed. Verified in order:

- the source had the line;
- the built `.so` contained the string;
- the board's copy was byte-identical (`md5sum` matched the host exactly);
- so the code was there, on the board, and simply did not run.

That last combination is what makes it so confusing: every check says the binary
is correct, so the natural conclusion is a code-generation or loader-mapping
fault. One run even faulted (`*** UNDEF in task 'sshd-session'`), which sent the
investigation further the wrong way.

## The one-line repro

```sh
cp prog.so /tmp/a.so   && /tmp/a.so     # v1 runs
# edit, rebuild
cp prog.so /tmp/a.so   && /tmp/a.so     # v1 runs AGAIN — same bytes on disk as v2
cp prog.so /tmp/b.so   && /tmp/b.so     # v2 runs — identical file, new path
```

Same bytes, different path, different behaviour. That is the whole bug: the
cache key is the path, and nothing invalidates it when the file changes.

## Suggested fix

Invalidate on any of size, mtime, or a content hash when a load is requested for
a path already in the cache — or simply drop the cache for paths outside the
read-only romfs, where the file cannot change under you. Keeping romfs entries
cached is the case the cache was presumably for.

## Workaround until then

Copy to a fresh path per iteration (`/tmp/prog-$(date +%s).so`), or reboot. Do
not trust a re-run of the same path after an update — and note that `md5sum`
agreeing does **not** mean the running image is current.
