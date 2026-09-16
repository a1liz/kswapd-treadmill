# kswapd page-cache treadmill

Minimal reproduction of one failure mode of page-cache readahead on a
**fragmented** node:

> Free memory is plentiful (10+ GB), but it is all in small fragments.
> A process reads a large file sequentially. Its readahead folio
> allocations cannot be satisfied, the allocation slow path wakes
> kswapd, and kswapd reclaims file pages - the very page cache the read
> is filling. As long as the sequential read lasts, kswapd keeps being
> woken and keeps grinding the cache down. A cache-dependent workload
> on the same machine then runs at disk speed, while `free` reports
> gigabytes available.

This is the mechanism behind the LKML complaint "under fragmentation
kswapd reclaims too many file folios even though free memory is
sufficient". It needs no THP, no compaction workload, and no memory
pressure - the pump is the victim's own readahead.

An earlier attempt at this repro assumed the high-order pressure had to
come from a THP-allocating workload. It does not: THP faults with the
default `defrag=madvise` do direct reclaim in the faulting process and
never wake kswapd (`GFP_TRANSHUGE_LIGHT` has no `__GFP_KSWAPD_RECLAIM`),
and even the `defrag=defer` path only produces short bounded kswapd
bursts. See `docs/MECHANISM.md` for the source-level chain.

## What it runs

two arms, ~12 minutes on a spinning disk:

| arm | what happens | what it shows |
|-----|--------------|---------------|
| **A** | warm a 12GB file set, then measure random 4KB reads | control: no fragmentation, kswapd stays idle, cache stays whole |
| **C** | drop the cache, build a fragmented arena, warm the same set again, measure | treatment: kswapd grinds the cache during the warm |
| **C2** | measure once more, no re-warm | the cache does not heal by itself |

`A` and `C` differ in exactly one thing: whether the free memory is
fragmented when the warm-up runs.

## Requirements

- Linux with large-folio page-cache readahead (6.8+; developed on 7.2.3)
- RAM >= ~2.2x the file set size, on one NUMA node (the arena needs
  most of a node's free memory)
- `read_ahead_kb > 0` on the file set's device (preflight checks this)
- a slow disk makes the effect dramatic; on NVMe it is small and heals fast
- root or `CAP_IPC_LOCK` for `frag_pin` (it mlocks tens of GB) - see
  `sudoers.example`

## Quickstart

```sh
make

# once: let the runner launch frag_pin without a password
sudo install -m 0440 sudoers.example /etc/sudoers.d/kswapd-treadmill

# the runner sleeps (arena build) - launch it detached
tmux new-session -d -s treadmill "$PWD/scripts/run.sh"
tail -f results/*/run.log
```

Everything is configurable through the environment:

```sh
SECS=120 TOTAL_GB=12 NODE=0 MEAS_CPUS=8-11 DATA_DIR=/data/treadmill \
  tmux new-session -d -s treadmill "$PWD/scripts/run.sh"
```

| var | default | meaning |
|-----|---------|---------|
| `TOTAL_GB` / `FILE_GB` | 12 / 2 | size of the file set |
| `SECS` | 60 | measure window per arm |
| `THREADS` | 4 | victim threads |
| `NODE` | 0 | NUMA node the arena and the victim use |
| `DATA_DIR` | `./data` | where the file set lives |
| `MEAS_CPUS` | `8-11` | pin the victim (empty = unpinned) |
| `FRAG_CTL` | `scripts/frag_ctl.sh` | privileged helper (replace it if you already have a whitelisted one) |
| `REPEAT_MEASURE` | 1 | run the C2 arm |

## How to read the results

`scripts/analyze.py` (run automatically at the end) prints two tables and
a set of verdicts. The columns that matter:

| column | meaning |
|--------|---------|
| `freeMB` | free memory in the zone under test |
| `o5..o10` | free blocks per buddy order - is memory tight, or just fragmented? |
| `pgscanK/s` | pages kswapd scanned per second (the treadmill) |
| `stealF/s` | file pages kswapd reclaimed per second (what it took) |
| `reflt/s` | the victim re-faulting pages that were evicted |
| `cstall` | allocations that reached the slow path (compaction stalls) |
| `kswapdCPU%` | kswapd's CPU time in the window |
| `filepgMB` | absolute page-cache size, first -> last row of the window |

The signature to look for, all in one run:

1. **A**: `pgscanK/s = 0`, hit rate 100%, millions of ops/s.
2. **C warm**: `pgscanK/s` in the tens of thousands, `stealF/s` the same
   order of magnitude, `freeMB` still in the tens of thousands, and
   `filepgMB` ending far below the file set size.
3. **C measure**: hit rate at a fraction of A's, hundreds of ops/s, and
   `filepgMB` **flat inside the window** - the cache was not stolen
   during the measurement, it was already gone before the measurement
   started. That distinction is the whole point: the damage happens in
   the fill phase.
4. `oom_kill` and `pswpout` never move. Nothing here is memory pressure.

### Reference run

94GB box, 2 NUMA nodes, LVM on two spinning disks (~380 random-4KB IOPS),
`read_ahead_kb=512`, `max_sectors_kb=1024` (=> readahead asks for folios
up to order 8 = 1MB):

```
arm          ops/s    hit%   ...  freeMB  pgscanK/s  stealF/s  kswapdCPU%    filepgMB
A          2853463  100.00   ...   50462          0         0        0.0   13720>13721
C              459   16.74   ...   15220       4757      4757        0.1    3702>3793

phase       secs  freeMB       pgscanK/s  stealF/s  kswapdCPU%    filepgMB
A_warm        --   50456               0         0        0.0   13720>13720
C_warm        49   15350           46390     46471        1.6    1451>3704
```

Read that last line again: the warm-up read 12GB and ended with 3.7GB in
the cache, 15.3GB still reported free, and kswapd having reclaimed 46k
file pages per second for 49 seconds to do it.

## What this is not

- Not a statement that kswapd is doing something illegal. It is following
  its own rules: it is woken by a failing high-order allocation, reclaims
  a bounded amount (`compact_gap(order)`, 32 pages at these orders,
  `vmscan.c`), and then goes back to sleep because the node's *order-0*
  watermarks are fine. The problem is the wake-up rate: one failed
  readahead folio per readahead window, hundreds per second during a
  sequential fill.
- Not the THP high-order reclaim problem, though they share the victim.
  See `docs/MECHANISM.md` for what is different.
- The arena is deliberately adversarial (a worst-case checkerboard: pin
  1.5MB of every 2MB frame, leave 512KB). Real machines reach "no free
  block of order 8" less cleanly - but the requirement is only that, and
  long uptimes with unmovable pages (mlock, hugepages, slab, driver
  buffers) get there.

## Files

```
src/frag_pin.c        builds the fragmented-but-sufficient state
src/fileprober.c      the victim: warm (sequential) + measure (random 4KB)
scripts/run.sh        orchestrator: A -> arena -> C -> C2
scripts/sampler.sh    1Hz vmstat/buddyinfo sampler
scripts/analyze.py    tables + verdicts
scripts/frag_ctl.sh   privileged helper (launch frag_pin, THP knob)
docs/MECHANISM.md     why this happens, with kernel source references
```

Cleanup is automatic: the arena is stopped and the THP knob restored when
`run.sh` exits.
