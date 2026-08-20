---
title: System
description: Process-control helpers — currently exit() to return to DOS.
---

`System` is the process-control class. At present it offers a single helper, `exit`, which terminates the program and returns control to DOS.

```c
#import <System.xc>
```

## Methods

```c
static void exit(i16 value);
```

Terminates the program by jumping through the Atari `DOSVEC` at `$0A`/`$0B`. The 16-bit exit value is stored at `$02FD`/`$02FE` (otherwise-unused OS page-2 bytes) for any caller that cares. **DOS itself ignores the exit value** — it's there for cooperating callers, not as a process-status mechanism the OS understands.

```c
void main(void)
{
    if (load("data") == 0) {
        Stdio.print("missing data file\n");
        System.exit(1);
    }
    // …normal path…
    System.exit(0);
}
```

If you don't call `exit`, `main` returning to its caller has the same effect as `exit(0)` on default-`xcc` builds: the runtime emits an `RTS` back into DOS. The difference is that `exit` works from anywhere in the program — you don't have to unwind back to `main`.

The `-Q loop` command-line switch changes the post-`main` behaviour to an infinite loop instead of an `RTS`; in that mode, `System.exit(...)` is the only way to actually return to DOS.

## Platform notes

`System` ships **only** under `support/xt6502/lib/`. There is no native-backend implementation, so `#import <System.xc>` fails to resolve under `-A arm64` and friends:

```
Cannot find include file 'System.xc'
```

On the native backends, return from `main` instead.
