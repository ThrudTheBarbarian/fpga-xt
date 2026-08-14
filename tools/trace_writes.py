#!/usr/bin/env python3
"""trace_writes.py — "which stores hit register X?", answered from a trace.

The hardware trace records (PC, A, X, Y, SP, P, IR) and NOT the effective
address, so a store's target is not in the file.  It is recoverable anyway: the
game's code is static, so the operand bytes for any PC can be read out of
Altirra's memory (same image, same addresses) and used to decode our PC stream.
Altirra is already the reference for this bug, so it costs nothing extra.

    ./tools/trace_writes.py <trace.bin> --reg D404          # who writes HSCROL
    ./tools/trace_writes.py <trace.bin> --range D000 D01F   # all of GTIA
    ./tools/trace_writes.py <trace.bin> --summary           # every hw register hit

Values: for a store the register holding the datum is untouched by the
instruction, so A/X/Y in the record IS the value written, on both sides
(fpga-xt samples at retire, Altirra before — identical for a store).

Needs AltirraSDL running with the same image and --bridge=tcp:127.0.0.1:6502.
"""
import argparse, array, glob, os, sys

# opcode -> (mnemonic, operand length, which register supplies the datum,
#            whether the effective address is indexed)
STORES = {
    0x8D: ('STA abs',   2, 'A', None),
    0x8E: ('STX abs',   2, 'X', None),
    0x8C: ('STY abs',   2, 'Y', None),
    0x9D: ('STA abs,X', 2, 'A', 'X'),
    0x99: ('STA abs,Y', 2, 'A', 'Y'),
    0x85: ('STA zp',    1, 'A', None),
    0x86: ('STX zp',    1, 'X', None),
    0x84: ('STY zp',    1, 'Y', None),
    0x95: ('STA zp,X',  1, 'A', 'X'),
}
REGIDX = {'A': 2, 'X': 3, 'Y': 4}


def bridge():
    sys.path.insert(0, os.path.expanduser(
        '~/src/AltirraSDL/src/AltirraSDL/AltirraBridge/sdk/python'))
    from altirra_bridge import AltirraBridge
    tmp = os.environ.get('TMPDIR', '/tmp').rstrip('/')
    toks = sorted(glob.glob(tmp + '/altirra-bridge-*.token'), key=os.path.getmtime)
    if not toks:
        sys.exit('no altirra-bridge token — is AltirraSDL running with --bridge?')
    return AltirraBridge.from_token_file(toks[-1])


def load(path):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from trace_diff import load_hw
    return load_hw(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace')
    ap.add_argument('--reg', help='single hex address, e.g. D404')
    ap.add_argument('--range', nargs=2, metavar=('LO', 'HI'))
    ap.add_argument('--summary', action='store_true')
    ap.add_argument('--limit', type=int, default=40)
    a = ap.parse_args()

    T = load(a.trace)
    # Distinct PCs that execute a store — that is all we need operands for.
    sites = {}
    for r in T:
        if r[1] in STORES:
            sites.setdefault(r[0], r[1])
    print('%d instructions, %d distinct store sites' % (len(T), len(sites)),
          file=sys.stderr)

    # Fetch the operand bytes for those PCs from Altirra (the code is static).
    operands = {}
    with bridge() as alt:
        for pc, op in sites.items():
            n = STORES[op][1]
            try:
                b = alt.peek(pc + 1, n)
            except Exception:
                continue
            operands[pc] = b[0] if n == 1 else (b[0] | (b[1] << 8))

    def target(pc, op, rec):
        base = operands.get(pc)
        if base is None:
            return None
        idx = STORES[op][3]
        return base + (rec[REGIDX[idx]] if idx else 0)

    if a.summary:
        from collections import Counter
        hits = Counter()
        for r in T:
            if r[1] not in STORES:
                continue
            t = target(r[0], r[1], r)
            if t is not None and 0xD000 <= t <= 0xD5FF:
                hits[t] += 1
        print('hardware-register writes seen in this trace:')
        for addr, n in sorted(hits.items()):
            print('   $%04X  %6d writes' % (addr, n))
        return 0

    if a.reg:
        lo = hi = int(a.reg, 16)
    elif a.range:
        lo, hi = int(a.range[0], 16), int(a.range[1], 16)
    else:
        print(__doc__)
        return 2

    print('writes to $%04X..$%04X:' % (lo, hi))
    shown = 0
    for i, r in enumerate(T):
        if r[1] not in STORES:
            continue
        t = target(r[0], r[1], r)
        if t is None or not (lo <= t <= hi):
            continue
        mn, _, src, _ = STORES[r[1]]
        print('   idx %8d  $%04X  %-10s -> $%04X  value=%02X  (A=%02X X=%02X Y=%02X)'
              % (i, r[0], mn, t, r[REGIDX[src]], r[2], r[3], r[4]))
        shown += 1
        if shown >= a.limit:
            print('   ... (--limit to see more)')
            break
    if not shown:
        print('   none')
    return 0


if __name__ == '__main__':
    sys.exit(main())
