#!/usr/bin/env python3
"""cosim_diff.py — find the first divergence between two 6502 instruction traces.

Diffs a "golden" reference trace (from the instrumented Atari800,
/tmp/golden_boot.trace) against our RTL sim trace (tb_boot,
/tmp/vvp_boot.trace).  Both are one line per RETIRED INSTRUCTION:

    <PC> <A> <X> <Y> <S>        (hex; PC = opcode address)

Alignment is per-instruction (line N vs line N), which is robust to internal
dummy-read / cycle differences between the two cores.  The first line whose PC
differs is a CONTROL-FLOW divergence — the OS branched differently because a
register read returned a value a real Atari wouldn't.  A line where the PC
matches but a register differs is a DATA divergence (a wrong value that hasn't
yet changed control flow).  Either pinpoints the next hardware-model bug.

The divergent PC is annotated from the OS disassembly listing if available, so
the report reads e.g. "diverged at $C48C  PMI1+5  STA PORTB".

Usage:
    tools/cosim_diff.py [--golden F] [--vvp F] [--lst F] [--context N]
"""
import argparse
import re
import sys

DEF_GOLDEN = "/tmp/golden_boot.trace"
DEF_VVP = "/tmp/vvp_boot.trace"
DEF_LST = ("/Users/user/src/atari/XLOS/a8-os-rom-2025-02-07/"
           "asm-lst/xl-rev-2.lst")


def load_trace(path):
    """Return list of (pc, [a,x,y,s], raw_line), lowercased/normalized."""
    out = []
    with open(path) as f:
        for ln in f:
            toks = ln.lower().split()
            if not toks:
                continue
            # PC is the first token; tolerate a leading "[time]"/seq column.
            if not re.fullmatch(r"[0-9a-f]{1,4}", toks[0]) and len(toks) > 1:
                toks = toks[1:]
            if not re.fullmatch(r"[0-9a-f]{1,4}", toks[0]):
                continue
            pc = int(toks[0], 16)
            regs = toks[1:5]
            out.append((pc, regs, ln.rstrip("\n")))
    return out


def build_lst_index(path):
    """Map address -> source listing line (best effort; mads/atasm format)."""
    idx = {}
    try:
        with open(path, encoding="latin-1") as f:
            for ln in f:
                # Listing format: "<ADDR>  <bytes>  <label> <mnemonic> ..."
                # — the 4-hex location counter is the first token on the line.
                m = re.match(r"([0-9A-Fa-f]{4})\s", ln)
                if m:
                    addr = int(m.group(1), 16)
                    idx.setdefault(addr, ln.rstrip("\n").strip())
    except OSError:
        pass
    return idx


def annotate(pc, lst):
    """Return a short symbolic note for an address, or ''."""
    if pc in lst:
        return lst[pc]
    # nearest preceding labelled line within 8 bytes -> "LABEL+n"
    for back in range(1, 9):
        if pc - back in lst:
            return f"(+{back}) {lst[pc - back]}"
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--golden", default=DEF_GOLDEN)
    ap.add_argument("--vvp", default=DEF_VVP)
    ap.add_argument("--lst", default=DEF_LST)
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--regs", action="store_true",
                    help="also flag register-only divergences (NOTE: the RTL "
                         "core writes back at DECODE, so its A/X/Y/S lag the "
                         "golden by one instruction, and reset S is "
                         "implementation-defined — expect benign noise)")
    args = ap.parse_args()

    try:
        g = load_trace(args.golden)
        v = load_trace(args.vvp)
    except OSError as e:
        sys.exit(f"error: {e}")

    lst = build_lst_index(args.lst)
    print(f"golden: {len(g):>8} instructions  ({args.golden})")
    print(f"vvp   : {len(v):>8} instructions  ({args.vvp})")
    if g and v:
        print(f"start : golden=${g[0][0]:04x}  vvp=${v[0][0]:04x}"
              f"  {'OK (both cold-start)' if g[0][0]==v[0][0] else 'MISMATCH AT RESET!'}")

    n = min(len(g), len(v))
    for i in range(n):
        gpc, greg, graw = g[i]
        vpc, vreg, vraw = v[i]
        if gpc != vpc:
            kind = "CONTROL-FLOW DIVERGENCE (PC differs)"
        elif args.regs and greg != vreg:
            kind = "DATA DIVERGENCE (PC matches, register differs)"
        else:
            continue
        print(f"\n===== {kind} at instruction #{i} =====")
        lo = max(0, i - args.context)
        print("  --- last matching instructions (golden) ---")
        for j in range(lo, i):
            note = annotate(g[j][0], lst)
            print(f"  #{j:<7} {g[j][2]:<20} {note}")
        print("  --- divergence ---")
        gnote = annotate(gpc, lst)
        vnote = annotate(vpc, lst)
        print(f"  golden #{i:<6} {graw:<20} {gnote}")
        print(f"  vvp    #{i:<6} {vraw:<20} {vnote}")
        print("  --- where each goes next ---")
        for j in range(i + 1, min(i + 5, len(g))):
            print(f"  golden #{j:<6} {g[j][2]:<20} {annotate(g[j][0], lst)}")
        for j in range(i + 1, min(i + 5, len(v))):
            print(f"  vvp    #{j:<6} {v[j][2]:<20} {annotate(v[j][0], lst)}")
        sys.exit(1)

    # No PC divergence within the overlap.
    if len(g) == len(v):
        print(f"\nMATCH: both traces identical (PC) for all {n} instructions.")
        return
    shorter, longer = ("vvp", "golden") if len(v) < len(g) else ("golden", "vvp")
    short_t, long_t = (v, g) if len(v) < len(g) else (g, v)
    print(f"\nPC MATCHES for all {n} instructions, then {shorter} HALTS while "
          f"{longer} continues.\nThe {shorter} run stopped at the divergence "
          f"point (e.g. tb_boot's self-test $finish fires the instant the bug "
          f"bites).")
    print(f"  --- last instructions before {shorter} halted ---")
    for j in range(max(0, n - args.context), n):
        print(f"  #{j:<7} {short_t[j][2]:<22} {annotate(short_t[j][0], lst)}")
    print(f"  --- {longer} continues correctly from there ---")
    for j in range(n, min(n + args.context, len(long_t))):
        print(f"  #{j:<7} {long_t[j][2]:<22} {annotate(long_t[j][0], lst)}")


if __name__ == "__main__":
    main()
