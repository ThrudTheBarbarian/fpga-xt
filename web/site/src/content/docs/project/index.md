---
title: Project & status
description: Where the Atari-XT build stands — implementation status, the roadmap and future work, and design notes for in-flight subsystems.
---

This section tracks where the project actually is, as opposed to how the finished system is meant
to behave (that's documented under [Hardware](/hardware/) and [Operating system](/os/)).

- **[Current state](/project/current-state/)** — the latest implementation snapshot: timing
  closure, clock domains, and per-subsystem progress.
- **[Future work / roadmap](/project/future-work/)** — deferred hardware and software ideas, plus
  a log of completed expansion items.

## Design notes

Design write-ups for individual subsystems. These started as design briefs; the status note at the
top of each says how much is built today:

- **[Resident page cache](/project/page-cache/)** — replaces the single-line demand cache on the
  SALLY banked windows. **Built — now the default** (`BANKED_CACHE = "PAGE"`).
- **[Sprite engine](/project/sprite-engine/)** — a hardware sprite compositor overlaying sprites
  during 1080p scan-out. **Mostly built**; the DDR3 image-fetch path is still to be wired in.

## Issues

- **[Issue #0001 — PSH guard byte](/project/issues/psh-guard-byte/)** — a resolved off-by-one in
  the xt6502 stack-frame layout, kept as a case study.
