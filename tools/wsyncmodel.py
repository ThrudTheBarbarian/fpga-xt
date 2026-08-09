#!/usr/bin/env python3
"""Cycle-exact model of ACID800 antic_wsync, solved for the ANTIC RDY model.

The test is fully deterministic: a 9-bit POKEY poly is released at a known
cycle and then sampled at four points whose spacing is decided entirely by
WSYNC's RDY behaviour. So instead of guessing an RDY delay and burning a
bitstream to find out, enumerate the model space here and see which one
reproduces all four expected bytes.

Free parameters:
  delay     machine cycles from the $D40A write until RDY actually falls
  release   line cycle at which ANTIC releases RDY
  rearm     does a RMW's SECOND write restart the delay countdown?
  ro_rdy    is RDY honoured only on read cycles (NMOS behaviour)?
"""

LINE = 114

# 9-bit poly, x^9+x^5+1, right-shifting, all-ones seed; RANDOM = bits [8:1].
def build_poly(n=6000):
    q, out = 0x1FF, []
    for _ in range(n):
        out.append((q >> 1) & 0xFF)
        q = ((q >> 1) | ((((q >> 0) & 1) ^ ((q >> 5) & 1)) << 8)) & 0x1FF
    return out
POLY = build_poly()

R, W = 'R', 'W'
# Machine-cycle read/write patterns for the instructions the test uses.
# 'wsync' marks the cycle that writes $D40A; 'rand' marks the cycle that
# reads $D20A. Branch is modelled taken (the dex loop) except the last.
I = {
    'lda_imm':  [R, R],
    'ldx_imm':  [R, R],
    'nop':      [R, R],
    'dex':      [R, R],
    'bne_t':    [R, R, R],
    'bne_nt':   [R, R],
    'sta_zp':   [R, R, W],
    'sty_zp':   [R, R, W],
    'bit_zp':   [R, R, R],
    'bit_abs':  [R, R, R, R],
    'sta_wsync':[R, R, R, 'WSYNC'],
    'lda_rand': [R, R, R, 'RAND'],
    'ldy_rand': [R, R, R, 'RAND'],
    'sta_skctl':[R, R, R, 'SKCTL'],
    # INC abs: op, lo, hi, read data, write old, write new
    'inc_wsync':[R, R, R, R, 'WSYNC', 'WSYNC'],
}

def program():
    p = []
    p += ['sta_wsync']                                    # 2017
    p += ['lda_imm']                                      # 201A lda #3
    p += ['sta_wsync']                                    # 201C
    p += ['sta_skctl']                                    # 201F
    p += ['sta_wsync']                                    # 2022
    p += ['ldy_rand', 'sty_zp']                           # 2025 d0
    p += ['nop']                                          # 202A
    p += ['sta_wsync']                                    # 202B
    p += ['lda_rand', 'sta_zp']                           # 202E d1
    p += ['inc_wsync']                                    # 2033
    p += ['lda_rand', 'sta_zp']                           # 2036 d2
    # --- early WSYNC block (d3) ---
    p += ['sta_wsync', 'ldx_imm']                         # 203B/203E
    for i in range(19):
        p += ['dex', 'bne_t' if i < 18 else 'bne_nt']     # 2040
    p += ['bit_zp', 'nop', 'sta_wsync']                   # 2043/2045/2046
    p += ['lda_rand', 'sta_zp']                           # 2049 d3
    # --- d4 block (not asserted) ---
    p += ['sta_wsync', 'ldx_imm']                         # 204E/2051
    for i in range(19):
        p += ['dex', 'bne_t' if i < 18 else 'bne_nt']
    p += ['bit_abs', 'nop', 'sta_wsync']                  # 2056/2059/205A
    p += ['lda_rand', 'sta_zp']                           # 205D d4
    # --- late INC WSYNC block (d5) ---
    p += ['sta_wsync', 'ldx_imm']                         # 2062/2065
    for i in range(19):
        p += ['dex', 'bne_t' if i < 18 else 'bne_nt']
    p += ['bit_abs', 'inc_wsync']                         # 206A/206D
    p += ['lda_rand', 'sta_zp']                           # 2070 d5
    return p

def run(delay, release, rearm, ro_rdy, phase):
    """Return the sampled RANDOM bytes d0..d5."""
    line = phase          # current line cycle
    poly = None           # poly step count, None until SKCTL release
    arm = 0               # countdown to RDY falling; 0 = idle
    rdy_low = False
    samples = []
    skctl_pending = False

    def tick():
        nonlocal line, poly, arm, rdy_low, skctl_pending
        line = (line + 1) % LINE
        if poly is not None:
            poly += 1
        elif skctl_pending:
            poly = 0            # mode change takes effect one cycle later
            skctl_pending = False
        if arm:
            arm -= 1
            if arm == 0:
                rdy_low = True
        if rdy_low and line == release:
            rdy_low = False

    for ins in program():
        for c in I[ins]:
            # RDY stalls the CPU before a cycle it is allowed to stall.
            while rdy_low and (c in (R, 'RAND') or not ro_rdy):
                tick()
            if c == 'RAND':
                samples.append(POLY[poly] if poly is not None else None)
            elif c == 'SKCTL':
                skctl_pending = True
            elif c == 'WSYNC':
                if arm == 0 and not rdy_low:
                    arm = delay
                elif rearm:
                    arm = delay
            tick()
    return samples

EXPECT = {0: 0x95, 2: 0x0D, 3: 0x44, 5: 0x34}

