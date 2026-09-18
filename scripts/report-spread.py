#!/usr/bin/env python3
# report-spread.py <results-dir> [frag-node] [far-node]
#
# Per-node, per-phase view for the spread test: how much free memory each node
# kept, how its large free blocks drained, and whether kswapd started scanning.
# The interesting part is the *transition* - re-run with the per-second data
# from sampler<N>.csv when a phase average is not enough.
#
#   python3 scripts/report-spread.py docs/reference-run-real/spread 0 1
import csv, sys, statistics as st

R = sys.argv[1]
NODES = [int(x) for x in sys.argv[2:]] or [0, 1]


def load(path):
    return [{k: (v if k == "phase" else int(v)) for k, v in row.items() if k}
            for row in csv.DictReader(open(path), delimiter=" ")]


samp = {}
for n in NODES:
    try:
        samp[n] = load(f"{R}/sampler{n}.csv")
    except FileNotFoundError:
        pass

print(f"{'phase':8s} {'node':>4s} {'secs':>4s} {'freeMB(min)':>11s} {'o7(min)':>7s} "
      f"{'o8(min)':>7s} {'o9(min)':>7s} {'o10(min)':>8s} {'pgscanK/s':>10s} {'kswapdCPU%':>10s}")
phases = []
for rows in samp.values():
    for r in rows:
        if r.get("phase") not in phases:
            phases.append(r["phase"])
for name in phases:
    for n in NODES:
        rows = [r for r in samp.get(n, []) if r.get("phase") == name]
        if not rows:
            continue
        secs = max(1, rows[-1]["epoch"] - rows[0]["epoch"] + 1)
        tot = lambda k: sum(r.get(k, 0) for r in rows)
        jif = rows[-1]["kswapd0_jiffies"] - rows[0]["kswapd0_jiffies"]
        print(f"{name:8s} {n:4d} {secs:4d} {min(r['free0_mb'] for r in rows):11d} "
              f"{min(r.get('o7',0) for r in rows):7d} {min(r.get('o8',0) for r in rows):7d} "
              f"{min(r.get('o9',0) for r in rows):7d} {min(r.get('o10',0) for r in rows):8d} "
              f"{tot('d_pgscan_kswapd')//secs:10d} {round(100.0*jif/100/secs,1):10.1f}")
