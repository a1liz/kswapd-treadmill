# Scenario 2: two real processes, and what actually triggers the treadmill

The minimal repro (`scripts/run.sh`) uses one synthetic victim whose own
warm-up is the pump.  This scenario asks the two questions that follow:

1. does the same thing happen when the *pump* and the *victim* are two
   separate real programs (a backup and a service), running at the same time?
2. **under what conditions does the pump exist at all?**

The answer to (2) turned out to be the most useful result here, and it is
not "large sequential reads" - see "The trigger" below.

## The trigger: the allocation must be confined to the fragmented node

Same fragmented state (15GB free, o8 = o9 = o10 = 0), same 1MB sequential
read, one variable - whether the reader's allocations are bound to that node:

| reader | 1MB reads | NUMA policy | kswapd scanning |
|---|---|---|---|
| `./fileprober --mode warm` | yes | `MPOL_BIND` node 0 | **~50,000 - 88,000 pages/s** |
| `./bindread --bs 1M` | yes | `MPOL_BIND` node 0 | **56,719 pages/s** |
| `./bindread --bs 4k` | no (4KB) | `MPOL_BIND` node 0 | **31,638 pages/s** |
| `dd bs=1M` | yes | none | **0** |
| `fio --rw=read --bs=1M` | yes | none | 583 /s |
| `fio --rw=read --bs=64k` | no | none | 0 |
| `tar` (default 10KB blocks) | no | none | 360 /s |

Mechanism: an unbound task that cannot satisfy a 1MB folio from the
fragmented node simply **falls back to the other node's zonelist entry**,
where the arena pinned nothing and order-9/10 blocks are plentiful.  The
allocation succeeds, `__alloc_pages_slowpath()` is never entered, and
`wake_all_kswapds()` is never called.  `MPOL_BIND` (or a machine with a
single node, where there is nothing to fall back to) is what forces the
failure.

Two corollaries that cost experiments to learn:

- **Read size is not the discriminator.**  A bound 4KB sequential reader
  pumps too (31k pages/s); an unbound 1MB reader does not pump at all.
- **This is why the effect is reported inconsistently in the wild.**
  Multi-node machines without binding cannot reproduce it; single-node
  machines (laptops, most cloud VMs) have no fallback and hit it.

Source: `mm/readahead.c:288` allocates cold readahead at
`mapping_min_folio_order` (= 0 for ordinary files); only the
`page_cache_ra_order` path (`mm/readahead.c:481`, async readahead or a
partially-cached sequential run) asks for large folios.  `mm/page_alloc.c:4814`
wakes kswapd from the allocation slow path, and `mm/vmscan.c:7017` +
`include/linux/compaction.h:67` bound each wake-up to 32 pages
(`compact_gap`) - so the harm is the *wake-up rate*, not any single reclaim.

## The two-process rig

```
pump    tar streaming a backup tree,  models `tar cf - /data | ssh backup`
victim  fio randread 4KB x4 jobs over its own working set,
        disjoint from the backup tree, models a cache-dependent service
```

Both are ordinary unbound processes - which, per the section above, means
neither of them can pump on this box, and that is the point: the rig
measures what actually happens in the common unbound configuration.

Arms (the backup runs from before the service warms up; it is stopped for
the last window to see whether the cache heals):

| arm | window 1 | window 2 | window 3 |
|---|---|---|---|
| R1 no fragmentation | backup + warm-up | backup + fio | fio alone |
| R2 fragmented (arena) | backup + warm-up | backup + fio | fio alone |

## Results, unbound (the default configuration)

Reference run (`python3 scripts/report-real.py docs/reference-run-real/two-process --win 60`):

```
window                iops   clat_p50   clat_p99
R1w1               2617214      1.1us      1.5us   control, backup running
R1w2               2616752      1.1us      1.5us   control, backup stopped
R2w1               2234475      1.4us      2.0us   fragmented, backup running
R2w2               2254890      1.4us      1.9us   fragmented, backup stopped
```

The service is unharmed on the fragmented box, and kswapd stays silent -
because nothing in the rig is bound to the fragmented node.  A 20GB backup
reading through a fragmented node in the default (unbound) configuration
simply does not walk into this bug.

An earlier run on the same rig (with a broken pump - see gotchas) showed
the victim collapsing to 777 iops / p50 11.2us / p99 35ms on the fragmented
side.  That number is **not** attributable to the backup: the damage came
from the victim's own warm-up through the fragmented node plus a device
ordering bug, and the backup process was not reading anything at all.
It is kept as a cautionary example, not as evidence.

## Results, BOUND=1: the backup takes the service down

`BOUND=1 scripts/run-real.sh` puts *both* processes under `MPOL_BIND` on the
fragmented node (fio via `--numa_mem_policy=bind:0`, the backup via
`./bindread`).  Everything else - arms, windows, disk, file sets - is
identical to the run above.  `python3 scripts/report-real.py
docs/reference-run-real/two-process-bound --win 60`:

```
window                iops   clat_p50   clat_p99
R1w1               2517591      1.1us      1.7us   control, backup running
R1w2               2532179      1.1us      1.7us   control, backup stopped
R2w1                   224  16056.3us  58982.4us   fragmented, backup running
R2w2                   390   7962.6us  40632.3us   fragmented, backup stopped
```

and on the kernel side, in the same run:

| phase | kswapd scanning | file pages stolen | kswapd CPU |
|---|---|---|---|
| R1 (both windows) | 0 /s | 0 /s | 0.0% |
| R2_warm (service warming, backup running) | 38,064 /s | 38,600 /s | 2.6% |
| R2_w1 (service serving, backup running) | **20,909 /s** | 21,858 /s | 4.6% |
| R2_w2 (backup stopped) | 371 /s | 371 /s | 0.0% |

So with one variable changed - NUMA confinement - the same backup against the
same service on the same fragmented node:

- takes the service from **2,517,591 iops / p50 1.1us** to **224 iops /
  p50 16ms / p99 59ms** (11,000x), with kswapd grinding the whole time;
- and it does not recover when the backup stops (p50 8.0ms after 60s) - the
  disk cannot refill the cache inside the workload's lifetime.

Note the ordering: w1 (16ms) is *worse* than w2 (8ms), because while the
backup runs the service loses its cache **and** competes for disk bandwidth;
once the backup stops only the cold cache is left, and 8ms is exactly this
disk's 4KB random-read latency.

| | unbound | BOUND=1 |
|---|---|---|
| service, fragmented node, backup running | 2,234,475 iops / p50 1.4us | **224 iops / p50 16ms** |
| kswapd in that window | 45 /s | **20,909 /s** |
| service, after the backup stops | p50 1.4us | p50 8.0ms (no healing) |
| control arm (no fragmentation) | p50 1.1us, kswapd 0 | p50 1.1us, kswapd 0 |

## Pump test

`PUMP_READERS="fp tar dd bind1M" scripts/pump-test.sh` runs readers one per
window on the same fragmented state, dropping the cache before each, and
prints what kswapd did:

```
python3 scripts/report-pump.py docs/reference-run-real/pump
window       secs  freeMB    o7   o8   o9   o10  pgscanK/s  stealF/s      filepgMB kswapdCPU%
W_fp           37   14810   398    0    0     0      65161     65543 12076>10488       5.7
W_dd_unbind    35   16312  1207    0    0     0          0         0  9480>17225        0.0
W_br_1M        36   17160  1208    0    0     0      56719     57342   9269>9221        4.5
W_br_4K        41   17652     0    0    0     0      31638     31706   7785>9277        2.4
```

`W_fp` (the synthetic victim's warm-up, bound) is the positive control and
is kept in every run: its per-second waveform is `0 -> 7.7k -> 43k -> 78k
-> 95k -> steady 90-110k pages/s` with the page cache *shrinking while it
fills* (12076 -> 10488 MB above).  If that control is ever flat, the rig is
broken and no conclusion should be drawn from the other windows.

## Gotchas (all of them look normal)

| # | trap | symptom | fix |
|---|---|---|---|
| 1 | fio defaults to `--invalidate=1` | victim reads from disk for the whole run (p50 8ms), looks like "the cache is gone" | pass `--invalidate=0` |
| 2 | `tar ... > /dev/null` | **GNU tar treats /dev/null as the archive target and skips reading entirely** (0.057s, rc=0) - the backup silently becomes a no-op | `tar ... \| cat > /dev/null` |
| 3 | dropping a large cache *after* building the arena | frees GBs as large blocks and **heals the fragmentation** (o8: 0 -> 12016) | drop before the arena |
| 4 | accepting a stale `FRAG_READY` | the log is appended by root, so truncating it as the user can silently fail; a stale line makes the run start while `frag_pin` is still walking memory | only accept lines appended after launch (`tail -n +N`) |
| 5 | `pkill -f "<pattern>"` | the pattern is in your own command line - it kills the shell running it (exit 144) | use `pkill -x` / `pgrep -x` |
| 6 | sampler killed by a stray signal | it dies at a window boundary, silently losing the kernel side of the whole run | ignore TERM/INT/HUP, clean up with `kill -KILL` |
| 7 | `atol("1M") == 1` | a reader silently does 1-byte reads and measures nothing | parse suffixes explicitly and echo the parsed value |
| 8 | a freshly written backup tree | GBs of dirty pages saturate the disk and poison every timing after it (fio at 22 IOPS) | wait for `Dirty:` in `/proc/meminfo` to drain |

Traps 1-3 each produced a full run of plausible-looking numbers that meant
nothing.  This is why every run keeps a positive control and why the doc
records which runs were invalidated and why.

## Running it

```sh
make
export DATA_DIR=/path/to/a/file/set      # victim set; scripts/run.sh can create one
tmux new-session -d -s realscn "$PWD/scripts/run-real.sh"
tmux new-session -d -s pump    "$PWD/scripts/pump-test.sh"
```

Needs `fio` (apt-get install fio), `tar`, root via `frag_ctl.sh`
(`sudoers.example`), and a slow disk to make the effect visible.

## Spreading: an unbound reader drags the healthy node in

Scenario 2's null result ("unbound readers never pump") turns out to be a stay
of execution, not immunity: the fallback deposits the reader's page cache on
the healthy node, and once that node has no large free block either, the
failure condition follows it there.

`scripts/spread-test.sh` (run 2026-09-18; data in
`docs/reference-run-real/spread/`, re-analyzable with
`python3 scripts/report-spread.py docs/reference-run-real/spread 0 1`):

- node 0 fragmented (14.6GB free, o8 = o9 = o10 = 0), node 1 healthy
  (23.8GB free, 5826 order-10 blocks)
- an unbound reader - CPU pinned to node 0, memory policy default, the common
  real configuration - reads 29GB

Per second on node 1 (node 0 the whole time: free never left 14.6GB, o8/o9/o10
stayed 0, kswapd scanned 81 pages/s ~= nothing):

```
+115s  free=1565MB  o8=23  o9=18  o10=289   pgscanK=0
+120s  free=663MB   o8=23  o9=18  o10=64    pgscanK=0
+125s  free=385MB   o8=1   o9=0   o10=3     pgscanK=35943   <- pump starts
+140s  free=433MB   o8=0   o9=0   o10=4     pgscanK=36717   cache stops growing
```

Three things scenario 2 could only infer, now measured:

1. **The fallback is real.** Node 0 had 14.6GB free and the reader, pinned to
   node 0's CPUs, got none of it: every large folio was refused by the
   fragmented node and served from node 1.
2. **The far node's blocks drain from the largest down** (o10 5826 -> 0,
   o9 67 -> 0, o8 128 -> 0): each order-8 request splits the biggest block
   available.
3. **The trigger is the smallest available order, not the amount of free
   memory.** kswapd was silent with 289 order-10 and 18 order-9 blocks left,
   and jumped to 35,943 pages/s the second order-8 hit 1.  385MB of free
   memory made no difference - the same "plenty free, still broken" shape as
   the synthetic repro, approached from the other side.

Complete condition: **no node in the allocation's zonelist may have a free
block of the required order.**  Reached by (a) confining the allocation
(MPOL_BIND, cgroup cpuset, numactl); (b) filling the other nodes until they
lose their large blocks - which an unbound reader does to itself, as here; or
(c) fragmenting them too.  A single-node machine satisfies it by construction.

## Open questions

- Bound 4KB readers start pumping several seconds later than 1MB readers;
  the ramp is not understood in detail.
- The fallback's cost is only partly measured: we know the cache lands on the
  far node and the far node's large blocks are consumed by it.  The latency
  penalty (remote access) is not measured.
- The two-process experiment has not been run with *both* processes bound to
  the fragmented node - that is the configuration where a backup should be
  able to hurt a co-located service, and it is the obvious next run.
