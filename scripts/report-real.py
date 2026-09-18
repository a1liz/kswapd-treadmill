#!/usr/bin/env python3
# report-real.py <results-dir> [--win 60]
#
# 两张表：
#   1. fio 受害者每个窗口的 iops / clat p50 / p99（窗口1 无泵，窗口2 有备份在跑）
#   2. 内核侧：每个相位的空闲/各阶空闲块/kswapd 扫描与偷取/页缓存绝对值
# 外加判定行。
import csv, json, sys, statistics as st

R = sys.argv[1]
WIN = int(sys.argv[sys.argv.index("--win") + 1]) if "--win" in sys.argv else 60
CLK = 100

phases = []
with open(f"{R}/phases.txt") as f:
    for line in f:
        name, ts = line.split()
        phases.append((name, int(ts)))

samp = []
with open(f"{R}/sampler.csv") as f:
    for row in csv.DictReader(f, delimiter=" "):
        row = {k: (v if k == "phase" else int(v)) for k, v in row.items() if k}
        for k in [k for k in list(row) if k.endswith("0")]:
            row.setdefault(k[:-1], row[k])
        samp.append(row)
OCOLS = [k for k in ("o5", "o6", "o7", "o8", "o9", "o10") if k in samp[0]]


def phase_rows(name):
    return [r for r in samp if r.get("phase") == name]


def kernel_row(name):
    rows = phase_rows(name)
    if not rows:
        return None
    secs = max(1, rows[-1]["epoch"] - rows[0]["epoch"] + 1)
    tot = lambda k: sum(r.get(k, 0) for r in rows)
    jif = rows[-1]["kswapd0_jiffies"] - rows[0]["kswapd0_jiffies"]
    return dict(secs=secs, free=st.median(r["free0_mb"] for r in rows),
                o=[min(r.get(k, 0) for r in rows) for k in OCOLS],
                scan=tot("d_pgscan_kswapd") // secs,
                steal=tot("d_pgsteal_file") // secs,
                fp0=rows[0]["file_pages_mb"], fp1=rows[-1]["file_pages_mb"],
                cpu=round(100.0 * jif / CLK / secs, 1))


def fio_window(name):
    try:
        d = json.load(open(f"{R}/{name}.fio.json"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    j = d["jobs"][0]["read"]
    cl = j.get("clat_ns", {})
    pc = cl.get("percentile", {})
    us = lambda ns: round(ns / 1000.0, 1)
    return dict(iops=round(j.get("iops", 0)),
                p50=us(pc.get("50.000000", cl.get("mean", 0))),
                p99=us(pc.get("99.000000", 0)),
                ios=j.get("total_ios", 0))


print("== 受害者：fio randread 4KB x4 jobs（同一 8GB 工作集）==")
print(f"{'窗口':16s} {'iops':>8s} {'clat_p50':>9s} {'clat_p99':>9s} {'总IO':>10s}  说明")
desc = {"R1w1": "control, no frag, backup running", "R1w2": "control, backup stopped",
        "R2w1": "fragmented, backup running",        "R2w2": "fragmented, backup stopped"}
for name in ("R1w1", "R1w2", "R2w1", "R2w2"):
    w = fio_window(name)
    if not w:
        continue
    print(f"{name:16s} {w['iops']:8d} {w['p50']:8.1f}us {w['p99']:8.1f}us {w['ios']:10d}  {desc.get(name,'')}")

print("\n== 内核侧（1Hz 采样，按相位）==")
hdr = " ".join(f"{k:>6s}" for k in OCOLS)
print(f"{'相位':10s} {'秒':>4s} {'freeMB':>7s} {hdr} {'pgscanK/s':>10s} {'stealF/s':>9s} {'filepgMB':>14s} {'kswapdCPU%':>10s}")
for name, _ in phases:
    k = kernel_row(name)
    if not k:
        continue
    o = " ".join(f"{v:6d}" for v in k["o"])
    print(f"{name:10s} {k['secs']:4d} {k['free']:7.0f} {o} {k['scan']:10d} {k['steal']:9d} "
          f"{k['fp0']:6.0f}>{k['fp1']:<6.0f} {k['cpu']:10.1f}")

print("\n== 判定 ==")
kw = {n: kernel_row(n) for n in ("R1_warm", "R2_warm", "R1_w1", "R2_w1", "R1_w2", "R2_w2")}
v = {n: fio_window(n) for n in ("R1w1", "R1w2", "R2w1", "R2w2")}
if kw["R1_warm"] and kw["R2_warm"]:
    print(f"[泵] 服务预热期 kswapd 扫描：健康机 {kw['R1_warm']['scan']}/s"
          f" vs 碎片机 {kw['R2_warm']['scan']}/s（同时偷走文件页 {kw['R2_warm']['steal']}/s）")
if v["R1w1"] and v["R2w1"]:
    print(f"[核心] 备份在跑时，服务的 clat p50：健康机 {v['R1w1']['p50']}us"
          f"（{v['R1w1']['iops']} iops）vs 碎片机 {v['R2w1']['p50']}us（{v['R2w1']['iops']} iops）")
if v["R1w2"] and v["R2w2"] and v["R2w1"]:
    print(f"[恢复] 备份停掉 60 秒后：碎片机 p50 {v['R2w1']['p50']}us → {v['R2w2']['p50']}us"
          f"，iops {v['R2w1']['iops']} → {v['R2w2']['iops']}；健康机 {v['R1w2']['p50']}us")
if kw["R1_w1"] and kw["R2_w1"]:
    print(f"[备份窗口的 kswapd] 健康机 {kw['R1_w1']['scan']}/s vs 碎片机 {kw['R2_w1']['scan']}/s")
