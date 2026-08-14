#!/usr/bin/env python3
"""altirra_trace.py — dump Altirra's instruction history to JSON for trace_diff.py.

Altirra is the golden reference (it passes ACID800), so it is the answer key when
fpga-xt and it disagree.  This pulls its cycle-accurate instruction history out
through the AltirraBridge and writes the record shape trace_diff.py expects.

  ./tools/altirra_trace.py out.json --frames 1200 [--chunk 4000]

Run Altirra first with the disk mounted and the bridge listening:

  cd ~/src/AltirraSDL && ./build/macos-release/src/AltirraSDL/AltirraSDL.app/\\
      Contents/MacOS/AltirraSDL --disk <img> --bridge=tcp:127.0.0.1:6502 &

NOTES THAT COST TIME TO LEARN:
  * The SDK lives at src/AltirraSDL/AltirraBridge/sdk/python (one level deeper
    than the repo root suggests).
  * history() enables recording LAZILY — the first call can return an error and
    turn it on; call it again.  That is patched behaviour, not a fault.
  * The ring is finite, so history has to be drained as we go rather than once
    at the end; we interleave frame() and history() and stitch on 'cycle', which
    is monotonic and gives an unambiguous ordering to dedupe on.
  * Altirra's 'pc' IS the address of the instruction whose opcode is 'op'.
    fpga-xt's records mean something different — see trace_diff.py.
"""
import argparse, glob, json, os, sys


def bridge():
    sys.path.insert(0, os.path.expanduser(
        '~/src/AltirraSDL/src/AltirraSDL/AltirraBridge/sdk/python'))
    from altirra_bridge import AltirraBridge
    tmp = os.environ.get('TMPDIR', '/tmp').rstrip('/')
    toks = sorted(glob.glob(tmp + '/altirra-bridge-*.token'),
                  key=os.path.getmtime)
    if not toks:
        sys.exit("no altirra-bridge token in %s — is AltirraSDL running "
                 "with --bridge=tcp:127.0.0.1:6502 ?" % tmp)
    return AltirraBridge.from_token_file(toks[-1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--frames', type=int, default=1200,
                    help='frames to run after cold reset (60/s)')
    ap.add_argument('--chunk', type=int, default=4000,
                    help='history entries to pull per drain')
    ap.add_argument('--step', type=int, default=2,
                    help='frames between drains — smaller means less chance '
                         'the ring overwrites entries we have not read')
    ap.add_argument('--no-reset', action='store_true')
    a = ap.parse_args()

    recs, seen = [], set()
    with bridge() as alt:
        if not a.no_reset:
            alt.cold_reset()
        # history() may need a call to switch recording on before it yields
        # anything; the first result is allowed to be an error.
        for _ in range(2):
            try:
                alt.history(4)
                break
            except Exception:
                pass

        done = 0
        while done < a.frames:
            alt.frame(min(a.step, a.frames - done))
            done += a.step
            try:
                h = alt.history(a.chunk)
            except Exception as e:
                print("history failed at frame %d: %s" % (done, e),
                      file=sys.stderr)
                break
            for e in h:
                # 'cycle' is monotonic, so it identifies a retirement uniquely
                # even when consecutive drains overlap.
                c = e.get('cycle')
                if c in seen:
                    continue
                seen.add(c)
                recs.append(e)
            if done % 120 == 0:
                print("  frame %5d  %8d records" % (done, len(recs)),
                      file=sys.stderr)

    recs.sort(key=lambda e: e['cycle'])
    with open(a.out, 'w') as f:
        json.dump(recs, f)
    print("wrote %d records to %s (frames=%d)" % (len(recs), a.out, a.frames))


if __name__ == '__main__':
    main()
