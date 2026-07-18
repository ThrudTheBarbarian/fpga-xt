#!/usr/bin/env python3
# Harte 65x02 JSON -> compact .vec for the iverilog harness (sim/tb_xt6502f_harte.sv).
# Run once per opcode (cached); the tb reads .vec, never the JSON. Hex fields, decimal
# counts, whitespace-separated. Usage: convert.py in.json out.vec [limit]
import json, sys
d = json.load(open(sys.argv[1]))
if len(sys.argv) > 3: d = d[:int(sys.argv[3])]
def rw(s): return 1 if s == 'read' else 0
with open(sys.argv[2], 'w') as f:
    f.write(f"{len(d)}\n")
    for c in d:
        i, fin, cy = c['initial'], c['final'], c['cycles']
        f.write(f"{i['pc']:04x} {i['s']:02x} {i['a']:02x} {i['x']:02x} {i['y']:02x} {i['p']:02x}\n")
        f.write(f"{len(i['ram'])}\n")
        for a, v in i['ram']: f.write(f"{a:04x} {v:02x}\n")
        f.write(f"{len(cy)}\n")
        for a, v, r in cy: f.write(f"{a:04x} {v:02x} {rw(r)}\n")
        f.write(f"{fin['pc']:04x} {fin['s']:02x} {fin['a']:02x} {fin['x']:02x} {fin['y']:02x} {fin['p']:02x}\n")
        f.write(f"{len(fin['ram'])}\n")
        for a, v in fin['ram']: f.write(f"{a:04x} {v:02x}\n")
