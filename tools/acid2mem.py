#!/usr/bin/env python3
#
# VALIDATED 2026-08-03: this harness now produces BOTH verdicts, so a FAIL means
# the RTL rather than the setup.  antic_default, antic_addrmirror and
# antic_blockednmi PASS here and in the software model; antic_vcount, antic_wsync
# and antic_dlitiming FAIL here and PASS in the model, which makes them genuine
# fabric divergences and the first real output of this instrument.
#
# Scored the way the model scores: watch for the PC reaching _testPassed or
# _testFailed.  The address IS the verdict, so nothing has to be classified from
# a register, and it lands earlier than _testEnd (which programs a POKEY timer
# and spins on IRQST).
#
# Runs the test image with NO OS ROM, and does not need one.
#
# The ACID framework installs handlers in the OS vectors (VDSLST, VVBLKI) and
# relies on the OS ROM's NMI dispatcher at $FFFA to read NMIST and jump through
# them.  This harness plants the SAME fourteen-byte dispatcher the software model
# uses (emu/test/acid.c), so no ROM is required -- which matters, because the XL
# ROM is not ours to vendor.  That model scores 57/63 on this suite, so the stub
# is validated rather than guessed.
#
"""acid2mem.py — turn an ACID800 standalone XEX into simulator memory.

Emits a 64K byte-per-line hex image plus a tiny config file, so an ACID test can
be run against the ANTIC rewrite in simulation instead of only on hardware.

The board runs these through xexload with a hardware breakpoint at the ACID
framework's _testEnd, then classifies the Y register: _testPassed leaves Y at
$00, _testFailed at $80.  This reproduces that arrangement for a testbench —
the breakpoint address comes out of the test's own .lab file rather than being
hardcoded, because it moves between builds.

Breaking at the ENTRY to _testEnd matters: the routine itself programs a POKEY
timer and spins on IRQST, so a harness with no POKEY hangs there.  The board's
sweep breaks at the entry for the same reason.

A small stub is planted at $0700 and the reset vector aimed at it: a bare 6502
comes up with no stack pointer, and on a real machine the OS would have set one
before the loader ever ran the test.

The framework prints its progress through IOCB 0's put-byte vector, which it
copies out of the OS's IOCB table at $0346 and increments -- the OS stores those
as address-minus-one for its RTS dispatch.  With no OS underneath, that vector is
zero and the first character printed jumps to $0001.  A null sink is installed
at $0346 in the same minus-one form, which is exactly what the OS would have put
there.  That loses only the printed text, which the result does not depend on:
the board's own sweep reads the Y register at _testEnd and discards the printing
too.

    usage: acid2mem.py <name> [outdir]
"""
import sys, struct, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
STANDALONE = ROOT / "rsrc/acid800/Acid800/standalone"
SYMBOLS = ROOT / "rsrc/acid800/Acid800/symbols"
STUB = 0x0700
ICPTL = 0x0346                      # IOCB 0 put-byte vector, in the OS's table


def load_xex(path):
    """Return (memory dict, run address)."""
    d = path.read_bytes()
    mem, run = {}, None
    i = 2 if d[0:2] == b"\xff\xff" else 0
    while i + 4 <= len(d):
        if d[i:i + 2] == b"\xff\xff":
            i += 2
            continue
        lo, hi = struct.unpack("<HH", d[i:i + 4])
        i += 4
        if hi < lo:
            break
        n = hi - lo + 1
        seg = d[i:i + n]
        i += n
        for k, b in enumerate(seg):
            mem[lo + k] = b
        # $02E0/$02E1 is the RUN vector: a segment landing there names the entry.
        if lo <= 0x02E0 <= hi and lo <= 0x02E1 <= hi:
            run = mem[0x02E0] | (mem[0x02E1] << 8)
    return mem, run


def symbols(name):
    """_testEnd and friends, from the test's own .lab."""
    out = {}
    # The standalone build's own .lab first: symbols/ is a different build and
    # its _testEnd is at a different address, which silently breakpoints on
    # nothing.
    for cand in (STANDALONE / f"{name}.lab", SYMBOLS / f"{name}.lab"):
        if not cand.exists():
            continue
        if out:
            break
        for line in cand.read_text(errors="ignore").splitlines():
            parts = line.split()
            if len(parts) >= 3 and len(parts[1]) == 4:
                try:
                    out.setdefault(parts[2], int(parts[1], 16))
                except ValueError:
                    pass
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    name = sys.argv[1]
    outdir = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "sim"

    xex = STANDALONE / f"{name}.xex"
    if not xex.exists():
        sys.exit(f"no such test: {xex}")

    mem, run = load_xex(xex)
    if run is None:
        sys.exit(f"{name}: no RUN address in the XEX")

    syms = symbols(name)
    end = syms.get("_testEnd")
    if end is None:
        sys.exit(f"{name}: no _testEnd in the .lab")

    # A bare 6502 has no stack pointer; on hardware the OS set one long before
    # the loader ran.  Plant the equivalent and aim the reset vector at it.
    # ...and POKEY out of init.  SKCTL[1:0] == 0 holds the polynomial counters
    # filling with ones, so RANDOM ($D20A) reads $FF forever.  The library sets
    # SKCTL = 3 at init but later restores it from the SSKCTL shadow, which a
    # booted OS holds at 3 and a bare image does not -- and antic_dmapattern
    # never writes SKCTL itself.  Setting the shadow at $0232 (below) is not
    # enough: with no OS, nothing ever copies it to the hardware register.
    # emu's harness pokes its model directly for the same reason
    # (emu/test/acid.c: `pokey_rand_skctl(&s.pk, 0x03)`); the equivalent here is
    # a real write, because our POKEY is real RTL.
    #
    # MEASURED: without this, antic_dmapattern reads $FF for both halves of its
    # LFSR pair, fails at "Cannot decode random pair" and never reaches a single
    # DMA assertion -- on BOTH ANTIC paths.
    stub = [0xA2, 0xFF,             # LDX #$FF
            0x9A,                   # TXS
            0xD8,                   # CLD
            0x78,                   # SEI
            0xA9, 0x03,             # LDA #$03
            0x8D, 0x0F, 0xD2,       # STA SKCTL ($D20F)
            0x4C, run & 0xFF, run >> 8]
    for k, b in enumerate(stub):
        mem[STUB + k] = b
    mem[0xFFFC] = STUB & 0xFF
    mem[0xFFFD] = STUB >> 8

    # ---- the OS's NMI dispatcher, transcribed from emu/test/acid.c ---------
    #
    # Without it $FFFA is RAM, reads as zero, and the first DLI or VBI kills the
    # machine -- which is why this harness was marked NOT VALID.  The two NMI
    # paths push DIFFERENT amounts and the handlers read their own return address
    # off the stack, so the asymmetry is load-bearing: a DLI pushes NOTHING
    # (antic_dlitiming reads PCL at $0104,X after two pushes of its own) while a
    # VBI pushes A, X and Y (cpu_bugs reads PCL at $0105,X with no pushes of its
    # own and pulls exactly three registers on its bail-out path).
    nmi_stub = [
        0x48,                       # $FF00  PHA
        0xAD, 0x0F, 0xD4,           # $FF01  LDA NMIST
        0x10, 0x04,                 # $FF04  BPL vbi
        0x68,                       # $FF06  PLA
        0x6C, 0x00, 0x02,           # $FF07  JMP (VDSLST)
        0x8A,                       # $FF0A  TXA        vbi:
        0x48,                       # $FF0B  PHA
        0x98,                       # $FF0C  TYA
        0x48,                       # $FF0D  PHA
        0x6C, 0x22, 0x02,           # $FF0E  JMP (VVBLKI)
    ]
    # IRQ/BRK goes through VIMIRQ.  Without it a BRK returns from a bare RTI, the
    # test's handler never runs, and the CPU ends up executing the STACK PAGE.
    irq_stub = [0x6C, 0x16, 0x02]   # $FF20  JMP (VIMIRQ)
    # default handlers: tick RTCLOK (what _waitVBL polls), then unwind and RTI
    dflt = [
        0xE6, 0x14,                 # $FF30  INC RTCLOK+2
        0xD0, 0x06,                 # $FF32  BNE done
        0xE6, 0x13,                 # $FF34  INC RTCLOK+1
        0xD0, 0x02,                 # $FF36  BNE done
        0xE6, 0x12,                 # $FF38  INC RTCLOK
        0x68,                       # $FF3A  PLA        done:
        0xA8,                       # $FF3B  TAY
        0x68,                       # $FF3C  PLA
        0xAA,                       # $FF3D  TAX
        0x68,                       # $FF3E  PLA
        0x40,                       # $FF3F  RTI
        0x40,                       # $FF40  RTI  -- bare, for DLI and IRQ
    ]
    for base, blob in ((0xFF00, nmi_stub), (0xFF20, irq_stub), (0xFF30, dflt)):
        for k, b in enumerate(blob):
            mem[base + k] = b
    mem[0xFFFA], mem[0xFFFB] = 0x00, 0xFF        # NMI     -> dispatcher
    mem[0xFFFE], mem[0xFFFF] = 0x20, 0xFF        # IRQ/BRK -> dispatcher

    # OS variables the tests read but no OS is here to set, all from the model.
    mem[0x006A] = 0xC0                           # RAMTOP -- mmu_xlbanking's
                                                 # first action is `lda ramtop
                                                 # / cmp #$41` and it skips
                                                 # below that
    mem[0x0232] = 0x03                           # SSKCTL: POKEY out of init
    if not mem.get(0x0217):
        mem[0x0216], mem[0x0217] = 0x40, 0xFF    # VIMIRQ -> bare RTI

    # Defaults for the vectors the test does not set, matching the model.
    if not mem.get(0x0201):
        mem[0x0200], mem[0x0201] = 0x40, 0xFF    # VDSLST -> bare RTI
    if not mem.get(0x0223):
        mem[0x0222], mem[0x0223] = 0x30, 0xFF    # VVBLKI -> RTCLOK ticker

    # _testInit opens IOCB0 through an OS that is not here; the MEASUREMENT does
    # not need it, so stub it to RTS exactly as the model does.
    init = syms.get("_testInit")
    if init is not None:
        mem[init] = 0x60

    # ...and because _testInit is what would have FILLED _vputchar, point that
    # vector at an RTS directly.  The suite prints through `jmp (_vputchar)`, so
    # a zero vector sends the CPU to $0000 on the first character -- which is
    # exactly the derail this harness showed ($1D15 JMP ($1A29) -> $0000).
    # Printing becomes a no-op; the measurement does not depend on it.
    # _exitTest / _exitTestS are set by _testInit too, so the same stub that
    # silences the OS dependency leaves them zero -- and _testFailed does
    # `LDX _exitTestS / TXS / LDY #$80 / JMP (_exitTest)`, i.e. jumps through
    # zero.  Park it on a spin instead so a missed detection is visible as a
    # halt rather than a BRK-walk through zero page.
    mem[0xFF60], mem[0xFF61], mem[0xFF62] = 0x4C, 0x60, 0xFF   # JMP $FF60
    ex = syms.get("_exitTest")
    if ex is not None:
        mem[ex], mem[ex + 1] = 0x60, 0xFF
    exs = syms.get("_exitTestS")
    if exs is not None:
        mem[exs] = 0xFF

    vput = syms.get("_vputchar")
    if vput is not None:
        mem[0xFF50] = 0x60                       # RTS
        mem[vput], mem[vput + 1] = 0x50, 0xFF

    # A null character sink, installed where the OS would have left it.  The
    # framework does `mwa icptl _vputchar` then `inw _vputchar`, so the table
    # entry is the target minus one.
    sink = STUB + len(stub)
    mem[sink] = 0x60                # RTS
    mem[ICPTL]     = (sink - 1) & 0xFF
    mem[ICPTL + 1] = (sink - 1) >> 8

    outdir.mkdir(parents=True, exist_ok=True)
    with open(outdir / "acid.mem", "w") as f:
        for a in range(0x10000):
            f.write(f"{mem.get(a, 0):02x}\n")
    # SCORE THE WAY THE MODEL DOES: watch for the PC reaching _testPassed or
    # _testFailed.  The address itself is the verdict, so no register has to be
    # classified, and it lands EARLIER than _testEnd -- which matters because
    # _testEnd programs a POKEY timer and spins on IRQST.
    t_pass = syms.get("_testPassed", 0)
    t_fail = syms.get("_testFailed", 0)
    # PASS AND FAIL ARE NOT THE ONLY OUTCOMES, and treating them as such costs
    # real time.  A test that finds the hardware it is written for is absent
    # signals _testSkipped and parks -- cpu_65c816 does it 35 cycles in, after
    # checking for a 65C816 -- and a harness watching only pass and fail then
    # runs it to the guard limit and calls a deliberate skip a TIMEOUT.  Others
    # reach _testEnd having asserted nothing at all, which the model reports as
    # "ran": a real outcome, and distinct from both a verdict and a hang.
    t_skip = syms.get("_testSkipped", 0)
    with open(outdir / "acid_cfg.mem", "w") as f:
        f.write(f"{end:04x}\n{t_pass:04x}\n{t_fail:04x}\n{t_skip:04x}\n")

    print(f"{name}: run=${run:04X} _testEnd=${end:04X} bytes={len(mem)}")


if __name__ == "__main__":
    main()
