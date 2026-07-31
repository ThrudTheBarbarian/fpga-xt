#!/usr/bin/env python3
"""acid800_extract.py — pull each ACID800 test's OWN source out of its .lst.

The .lst files inline the whole of library.s plus every macro expansion, which
buries the ~50 lines that actually say what the test checks under ~2000 lines of
boilerplate.  This tracks the assembler's `Source:` / `Macro:` markers and keeps
only the lines belonging to <test>.s, then strips the listing columns (line
number, address, object bytes) back to readable source.

The `_ASSERT*` invocations that survive are the gold: each carries a failure
string naming the expected value, e.g.

    _ASSERT1 d1, $02, c"VCOUNT #2 wrong: $%x != $02"

so the expected hardware behaviour is stated in the test itself.

Usage:
    tools/acid800_extract.py <lst-dir> <out-dir> [test ...]
"""
import os
import re
import sys

SRC_RE   = re.compile(r'^Source: (.+?)\s*$')
MACRO_RE = re.compile(r'^Macro: (\S+) \[Source: (.+?)\]\s*$')


LINE_RE = re.compile(r'^\s*(\d+)\s')


def extract(lst_path, test):
    """Return (title, [source lines]) for the test's own .s file.

    mads emits a `Source: X` marker when it ENTERS an include but NOT when it
    returns from one — so after `icl 'library.s'` the listing silently resumes
    in the test's own file, and a naive reader attributes the entire test body
    to library.s.  (That is not a small loss: for antic_wsync it is the whole
    measurement, leaving only the assertions.)

    The return is detectable because each file's line numbers only ever
    increase, so a number LOWER than the last one seen for the current file
    means we have popped back to the parent.  Macro expansions do get a return
    marker, but they restart at 1 and so pop by the same rule anyway.
    """
    want = test + '.s'
    stack = [want]
    last = {}
    out, title = [], None

    with open(lst_path, encoding='latin-1') as f:
        for raw in f:
            line = raw.rstrip('\r\n')

            m = SRC_RE.match(line)
            if m:
                name = m.group(1)
                if name in stack:                 # returning to an ancestor
                    while stack[-1] != name:
                        last.pop(stack.pop(), None)
                else:
                    stack.append(name)
                continue

            m = MACRO_RE.match(line)
            if m:
                stack.append('<macro:%s>' % m.group(1))
                continue

            n = LINE_RE.match(line)
            if n:
                num = int(n.group(1))
                # pop any frames we have silently returned from
                while len(stack) > 1 and num < last.get(stack[-1], 0):
                    last.pop(stack.pop(), None)
                last[stack[-1]] = num

            if stack[-1] != want or '\t' not in line:
                continue
            src = line.split('\t', 1)[1].rstrip()
            if not src:
                continue
            if title is None:
                t = re.search(r'_SAP_HEADER\s+"([^"]+)"', src)
                if t:
                    title = t.group(1)
            out.append(src)
    return title, out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    lstdir, outdir = sys.argv[1], sys.argv[2]
    tests = sys.argv[3:]
    if not tests:
        tests = sorted(f[:-4] for f in os.listdir(lstdir) if f.endswith('.lst'))
    os.makedirs(outdir, exist_ok=True)
    for t in tests:
        p = os.path.join(lstdir, t + '.lst')
        if not os.path.exists(p):
            print('skip %s (no .lst)' % t)
            continue
        title, lines = extract(p, t)
        with open(os.path.join(outdir, t + '.s'), 'w') as f:
            f.write('\n'.join(lines) + '\n')
        asserts = sum(1 for l in lines if '_ASSERT' in l)
        print('%-24s %4d lines, %3d asserts  %s'
              % (t, len(lines), asserts, title or ''))


if __name__ == '__main__':
    main()
