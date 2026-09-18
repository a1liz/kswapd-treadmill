#!/usr/bin/env python3
# report-pump.py <results-dir> [reader ...]
#
# Per-window kswapd activity for the pump test: how much kswapd scanned and
# stole while each reader ran, and what happened to the page cache.
#
#   python3 scripts/report-pump.py docs/reference-run-real/pump
import csv, sys, statistics as st

R = sys.argv[1]
samp = [{k: (v if k == "phase" else int(v)) for k, v in row.items() if k}
        for row in csv.DictReader(open(f"{R}/sampler.csv"), delimiter=" ")]
# default: every phase that is not boilerplate, in order of appearance
readers = sys.argv[2:] or list(dict.fromkeys(
    r["phase"] for r in samp if r.get("phase") not in ("boot", "pinup", "done")))

print(f"{'window':8s} {'secs':>4s} {'freeMB':>7s} {'o7':>5s} {'o8':>4s} {'o9':>4s} {'o10':>5s} "
      f"{'pgscanK/s':>10s} {'stealF/s':>9s} {'filepgMB':>13s} {'kswapdCPU%':>10s}")
for name in readers:
    rows = [r for r in samp if r.get("phase") == name]
    if not rows:
        continue
    secs = max(1, rows[-1]["epoch"] - rows[0]["epoch"] + 1)
    tot = lambda k: sum(r.get(k, 0) for r in rows)
    jif = rows[-1]["kswapd0_jiffies"] - rows[0]["kswapd0_jiffies"]
    print(f"{name:8s} {secs:4d} {st.median(r['free0_mb'] for r in rows):7.0f} "
          f"{min(r.get('o7', 0) for r in rows):5d} {min(r.get('o8', 0) for r in rows):4d} "
          f"{min(r.get('o9', 0) for r in rows):4d} {min(r.get('o10', 0) for r in rows):5d} "
          f"{tot('d_pgscan_kswapd')//secs:10d} {tot('d_pgsteal_file')//secs:9d} "
          f"{rows[0]['file_pages_mb']:5.0f}>{rows[-1]['file_pages_mb']:<6.0f} "
          f"{round(100.0*jif/100/secs,1):10.1f}")
