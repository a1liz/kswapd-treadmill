#!/usr/bin/env python3
# analyze.py <results-dir> [--secs 60]
#
# Two tables and a set of verdict lines:
#   1. the victim's throughput/hit-rate per measure arm
#   2. what the kernel was doing in each phase (warm vs measure)
#   3. explicit verdicts: did kswapd run during the fill, and did the
#      page cache actually shrink during the measure window
import csv, sys, statistics as st

R = sys.argv[1]
SECS = int(sys.argv[sys.argv.index("--secs") + 1]) if "--secs" in sys.argv else 60
CLK = 100  # getconf CLK_TCK

phases = []
with open(f"{R}/phases.txt") as f:
    for line in f:
        name, ts = line.split()
        phases.append((name, int(ts)))

samp = []
with open(f"{R}/sampler.csv") as f:
    for row in csv.DictReader(f, delimiter=" "):
        row = {k: (v if k == "phase" else int(v)) for k, v in row.items() if k}
        # tolerate the older column spelling (d_pgscan_kswapd0 vs d_pgscan_kswapd)
        for k in [k for k in list(row) if k.endswith("0")]:
            row.setdefault(k[:-1], row[k])
        samp.append(row)
OCOLS = [k for k in ("o5", "o6", "o7", "o8", "o9", "o10") if k in samp[0]]
end_all = samp[-1]["epoch"] + 1


def window(name, clamp_secs=None):
    for i, (n, t0) in enumerate(phases):
        if n != name:
            continue
        t1 = phases[i + 1][1] if i + 1 < len(phases) else end_all
        if clamp_secs:
            t1 = min(t1, t0 + clamp_secs)
        return t0, t1
    return None


def arm_stats(name, t0, t1):
    try:
        fh = open(f"{R}/{name}.csv")
    except FileNotFoundError:
        return None
    rows = []
    for line in fh:
        if line.startswith("#"):
            continue
        s, o, b0, b1, b2, b3, b4, m = map(int, line.split())
        if s == 0:          # the counter rows are 1-based, but be safe
            continue
        rows.append((o, b0, b3 + b4, m))
    if not rows:
        return None
    hit = [100.0 * r[1] / r[0] for r in rows if r[0]]
    slow = [100.0 * r[2] / r[0] for r in rows if r[0]]
    h = lambda rs: round(100.0 * sum(r[1] for r in rs) / max(1, sum(r[0] for r in rs)), 2)
    return dict(ops=int(st.median(r[0] for r in rows)),
                hit=round(st.median(hit), 2),
                h10=h(rows[:10]), hl10=h(rows[-10:]),
                slow=round(st.median(slow), 4),
                max_us=max(r[3] for r in rows))


def samp_stats(t0, t1):
    rows = [r for r in samp if t0 <= r["epoch"] < t1]
    if not rows:
        return {}
    secs = max(1, rows[-1]["epoch"] - rows[0]["epoch"] + 1)
    tot = lambda k: sum(r.get(k, 0) for r in rows)
    jif = rows[-1]["kswapd0_jiffies"] - rows[0]["kswapd0_jiffies"]
    return dict(secs=secs,
                free=st.median(r["free0_mb"] for r in rows),
                o5=min(r.get("o5", 0) for r in rows),
                o6=min(r.get("o6", 0) for r in rows),
                o7=min(r.get("o7", 0) for r in rows),
                o8=min(r.get("o8", 0) for r in rows),
                o9=min(r["o9"] for r in rows), o10=min(r["o10"] for r in rows),
                scan=tot("d_pgscan_kswapd") // secs,
                sk=tot("d_pgsteal_kswapd") // secs,
                steal=tot("d_pgsteal_file") // secs,
                ref=tot("d_refault_file") // secs,
                cs=tot("d_compact_stall") // secs,
                direct=tot("d_pgsteal_direct") // secs,
                pswp=tot("d_pswpout"),
                fp0=rows[0]["file_pages_mb"], fp1=rows[-1]["file_pages_mb"],
                cpu=round(100.0 * jif / CLK / secs, 1))


def has_csv(name):
    try:
        open(f"{R}/{name}.csv").close()
        return True
    except FileNotFoundError:
        return False


measure, warm = [], []
for name, _ in phases:
    w = window(name)
    if not w:
        continue
    if name.endswith("_warm"):
        warm.append((name, w[0], w[1]))
    elif has_csv(name):
        # clamp to the measure window: the phase after it (drop, arena
        # build) must not leak into this arm's cache numbers
        measure.append((name, w[0], min(w[1], w[0] + SECS)))

OCOLS_HDR = " ".join(f"{k:>5s}" for k in OCOLS)
OCOLS_ROW = lambda s: " ".join(f"{s.get(k, 0):5d}" for k in OCOLS)

print("== victim (random 4KB reads) ==")
print(f"{'arm':8s} {'ops/s':>9s} {'hit%':>7s} {'hit1st10':>9s} {'hitLst10':>9s} "
      f"{'slow%':>7s} {'max_us':>8s} | {'freeMB':>7s} {OCOLS_HDR} "
      f"{'pgscanK/s':>10s} {'stealF/s':>9s} {'reflt/s':>8s} {'cstall':>6s} "
      f"{'kswapdCPU%':>10s} {'filepgMB':>14s}")
for name, t0, t1 in measure:
    a, s = arm_stats(name, t0, t1), samp_stats(t0, t1)
    if not a:
        continue
    print(f"{name:8s} {a['ops']:9d} {a['hit']:7.2f} {a['h10']:9.2f} {a['hl10']:9.2f} "
          f"{a['slow']:7.4f} {a['max_us']:8d} | {s.get('free',0):7.0f} {OCOLS_ROW(s)} "
          f"{s.get('scan',0):10d} {s.get('steal',0):9d} "
          f"{s.get('ref',0):8d} {s.get('cs',0):6d} {s.get('cpu',0):10.1f} "
          f"{s.get('fp0',0):6.0f}>{s.get('fp1',0):<6.0f}")

print("\n== fill (warm) phases ==")
print(f"{'phase':10s} {'secs':>5s} {'freeMB':>7s} {OCOLS_HDR} "
      f"{'pgscanK/s':>10s} {'stealF/s':>9s} {'reflt/s':>8s} {'cstall':>6s} "
      f"{'kswapdCPU%':>10s} {'filepgMB':>14s}")
for name, t0, t1 in warm:
    s = samp_stats(t0, t1)
    if not s:
        continue
    print(f"{name:10s} {s['secs']:5d} {s['free']:7.0f} {OCOLS_ROW(s)} "
          f"{s['scan']:10d} {s['steal']:9d} {s['ref']:8d} {s['cs']:6d} "
          f"{s['cpu']:10.1f} {s['fp0']:6.0f}>{s['fp1']:<6.0f}")

print("\n== verdicts ==")
for name, t0, t1 in warm:
    s = samp_stats(t0, t1)
    if not s:
        continue
    if s["scan"] > 0:
        print(f"[pump] {name}: kswapd scanned {s['scan']}/s and stole {s['steal']} file pages/s "
              f"while {s['free']:.0f}MB stayed free; page cache {s['fp0']}->{s['fp1']}MB")
    else:
        print(f"[quiet] {name}: kswapd idle (0 pages scanned/s); page cache {s['fp0']}->{s['fp1']}MB")
for name, t0, t1 in measure:
    s = samp_stats(t0, t1)
    a = arm_stats(name, t0, t1)
    if not s or not a:
        continue
    delta = s["fp1"] - s["fp0"]
    if abs(delta) <= max(64, s["fp0"] // 20):
        print(f"[flat] {name}: page cache barely moved inside the window "
              f"({s['fp0']}->{s['fp1']}MB) while hit rate read {a['h10']}% then {a['hl10']}% "
              f"-> the window is not where the cache was lost")
    else:
        print(f"[shrink] {name}: page cache {s['fp0']}->{s['fp1']}MB inside the window "
              f"({delta:+d}MB), hit {a['h10']}% -> {a['hl10']}%")
