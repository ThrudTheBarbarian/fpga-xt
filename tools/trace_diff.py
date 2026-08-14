#!/usr/bin/env python3
"""trace_diff.py — find where fpga-xt and Altirra stop agreeing.

Two traces of the same program, from two machines, and the question is always
"where did they first REALLY diverge".  The hard part is not the comparison, it
is not crying wolf: the machines take interrupts at different instruction
boundaries, so a naive first-mismatch report fires on the first NMI that lands a
cycle apart and tells you nothing.

RECORD SEMANTICS — the two sides do NOT mean the same thing, and this is exactly
the sort of detail that produces a confident wrong answer:

  fpga-xt (hdl/xt_trace_axi.sv, 8-byte LE):
      lo = PC | A<<16 | X<<24 ,  hi = Y | SP<<8 | P<<16 | IR<<24
      and the pair means (IR JUST EXECUTED, PC of the NEXT instruction).
      So the address of record N's instruction is record N-1's PC.

  Altirra (bridge history()):
      {'pc','op','a','x','y','s','p','irq','nmi'} where pc IS the address of the
      instruction whose opcode is op.

Both are normalised to (addr, op, a, x, y, sp, p) before anything is compared.

RESYNC.  On a mismatch we do not give up and we do not report immediately: we
look ahead on both sides for a run of MATCH_RUN consecutive identical (addr, op)
pairs.  If one is found, the intervening entries were an interrupt or a timing
skew, and they are reported as SKIPPED rather than as a divergence.  Only when no
resync exists within the window is it called a real divergence.

Usage:
    trace_diff.py hw <trace.bin> [--limit N]        # decode/inspect ours
    trace_diff.py alt <history.json> [--limit N]    # decode/inspect Altirra's
    trace_diff.py diff <trace.bin> <history.json> [--start-pc $XXXX]
"""
import json, struct, sys, array

MATCH_RUN   = 8      # consecutive identical instructions to call it resynced
LOOKAHEAD   = 4096   # how far to hunt for a resync before declaring divergence


def load_hw(path, limit=None):
    """fpga-xt binary -> [(addr, op, a, x, y, sp, p, is_irq)]"""
    a = array.array('I')
    with open(path, 'rb') as f:
        a.frombytes(f.read())
    n = len(a) // 2
    if limit:
        n = min(n, limit + 1)
    out = []
    prev_pc = None
    for i in range(n):
        lo, hi = a[2 * i], a[2 * i + 1]
        pc = lo & 0xFFFF
        rec = dict(next_pc=pc, A=(lo >> 16) & 0xFF, X=(lo >> 24) & 0xFF,
                   Y=hi & 0xFF, SP=(hi >> 8) & 0xFF, P=(hi >> 16) & 0xFF,
                   IR=(hi >> 24) & 0xFF)
        # IR==0 with SP dropping by 3 is the INTERRUPT-ENTRY marker, not a BRK.
        # Getting this wrong once already produced a confident false diagnosis.
        if prev_pc is not None:
            out.append((prev_pc, rec['IR'], rec['A'], rec['X'], rec['Y'],
                        rec['SP'], rec['P'], rec['IR'] == 0))
        prev_pc = pc
    return out


def load_alt(path, limit=None):
    """Altirra history JSON -> the same tuple shape."""
    with open(path) as f:
        h = json.load(f)
    if limit:
        h = h[:limit]
    def hx(v):
        return int(str(v).lstrip('$'), 16) if isinstance(v, str) else int(v)
    return [(hx(e['pc']), hx(e['op']), hx(e['a']), hx(e['x']), hx(e['y']),
             hx(e['s']), hx(e['p']), bool(e.get('irq') or e.get('nmi')))
            for e in h]


def key(rec):
    return (rec[0], rec[1])          # (addr, opcode) — control flow, not values


def find_resync(A, i, B, j):
    """Look for a run of MATCH_RUN identical (addr,op) pairs after a mismatch.
    Returns (di, dj) offsets to skip, or None."""
    for dj in range(0, min(LOOKAHEAD, len(B) - j)):
        for di in range(0, min(LOOKAHEAD, len(A) - i)):
            if di == 0 and dj == 0:
                continue
            ok = True
            for k in range(MATCH_RUN):
                if i + di + k >= len(A) or j + dj + k >= len(B):
                    ok = False
                    break
                if key(A[i + di + k]) != key(B[j + dj + k]):
                    ok = False
                    break
            if ok:
                return di, dj
        # widen dj first: interrupt skew usually shows as extra entries on ONE side
    return None


def show(tag, rec):
    return ("%s $%04X op=%02X A=%02X X=%02X Y=%02X SP=%02X P=%02X%s"
            % (tag, rec[0], rec[1], rec[2], rec[3], rec[4], rec[5], rec[6],
               "  <interrupt>" if rec[7] else ""))


def do_diff(hw_path, alt_path, start_pc=None):
    A = load_hw(hw_path)
    B = load_alt(alt_path)
    print("fpga-xt: %d instructions   Altirra: %d instructions" % (len(A), len(B)))

    # Align the starting point: find the first place a MATCH_RUN window agrees.
    i = j = 0
    if start_pc is not None:
        while i < len(A) and A[i][0] != start_pc:
            i += 1
        while j < len(B) and B[j][0] != start_pc:
            j += 1
        print("anchored both at $%04X (hw idx %d, alt idx %d)" % (start_pc, i, j))

    skipped_hw = skipped_alt = 0
    while i < len(A) and j < len(B):
        if key(A[i]) == key(B[j]):
            i += 1
            j += 1
            continue
        r = find_resync(A, i, B, j)
        if r is None:
            print("\n=== FIRST REAL DIVERGENCE (no resync within %d) ===" % LOOKAHEAD)
            print("  after %d matched instructions" % i)
            print("  (skipped so far: hw %d, altirra %d — interrupt/timing skew)"
                  % (skipped_hw, skipped_alt))
            print("\n  last 8 agreed:")
            for k in range(max(0, i - 8), i):
                print("   ", show("both", A[k]))
            print("\n  fpga-xt then:")
            for k in range(i, min(len(A), i + 8)):
                print("   ", show("hw  ", A[k]))
            print("\n  Altirra then:")
            for k in range(j, min(len(B), j + 8)):
                print("   ", show("alt ", B[k]))
            return 1
        di, dj = r
        skipped_hw += di
        skipped_alt += dj
        i += di
        j += dj
    print("no divergence found within the shorter trace "
          "(hw skipped %d, altirra skipped %d)" % (skipped_hw, skipped_alt))
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    if mode == 'hw':
        for k, r in enumerate(load_hw(sys.argv[2], 40)):
            print("%6d %s" % (k, show("hw  ", r)))
    elif mode == 'alt':
        for k, r in enumerate(load_alt(sys.argv[2], 40)):
            print("%6d %s" % (k, show("alt ", r)))
    elif mode == 'diff':
        pc = None
        if '--start-pc' in sys.argv:
            pc = int(sys.argv[sys.argv.index('--start-pc') + 1].lstrip('$'), 16)
        return do_diff(sys.argv[2], sys.argv[3], pc)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
