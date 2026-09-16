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

Two notes on reading the numbers:

- `reflt/s` inside a measure window lands on the victim's miss rate (in
  the reference run: 380/s against 457 ops/s at 17% hit). Those are the
  pages the fill-time reclaim threw away and the victim is asking for
  again. During a *fill* the column is mostly noise: reading a file that
  was evicted earlier counts as a refault even when kswapd never ran, so
  a fill can show tens of thousands of refaults against zero kswapd
  activity if the set was read on this machine before.
- The victim picks random offsets with a seed mixed per process. It has
  to: with a fixed seed every arm replays the identical page sequence and
  the first second of a window re-reads exactly what the previous window
  pulled into cache. We hit that - a fresh arm showed an 87% "hit burst"
  in its first second that was pure test-harness determinism, not cache
  healing.

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
up to order 8 = 1MB).  The raw data is in `docs/reference-run/`; you can
re-analyze it without running anything:

```
python3 scripts/analyze.py docs/reference-run --secs 60
```

```
arm          ops/s    hit%  hit1st10  hitLst10   slow%   max_us |  freeMB    o5    o6    o7    o8    o9   o10  pgscanK/s  stealF/s  reflt/s  kswapdCPU%    filepgMB
A          3036306  100.00    100.00    100.00  0.0000     1257 |   50292  7183  5813  4686    19     1 10302          0         0        0        0.0  13894>13878
C              457   17.52     16.49     17.82 82.0765   104150 |   15172 30994 28798    39     0     0     0         44         0      380        0.0   3886>3977
C2             465   18.78     18.46     19.49 80.6961   117952 |   15047 30980 28798    39     0     0     0          0         0      386        0.0   3980>4067

phase       secs  freeMB    o5    o6    o7    o8    o9   o10  pgscanK/s  stealF/s  reflt/s  kswapdCPU%    filepgMB
A_warm        50   57049  7794  6378  5170     1     0 10424          0         0        0        0.0   1627>13068
C_warm        50   15293 30971 28796    20     0     0     0      51135     51203        0        1.6   1780>3885
```

Four things to read out of that:

1. `C_warm` scanned and stole **51k file pages per second for 50 seconds**
   while 15.3GB sat free, and the 12GB warm-up ended with only 3.9GB in
   the cache. `A_warm` - same read, same disk, no fragmentation - reached
   13.1GB with kswapd at literally zero.
2. The `o8 = o9 = o10 = 0` columns are the precondition, measured rather
   than assumed: in the fragmented arm the machine has 15.3GB free and
   **nothing above 256KB** in a single block (o5/o6 hold it all), while
   the control arm has thousands of order-7/8/9/10 blocks. 1MB folios
   cannot be allocated in the first case and always can in the second.
3. In both measure windows `filepgMB` is flat (`3886>3977`,
   `3980>4067`) - no cache is being taken *while* the victim runs. The
   damage was done during the fill. And kswapd drops from 51,135 pages/s
   during the fill to 44/s during the measurement: the pump is the
   sequential read.
4. `C2` measures an unchanged cache 60 seconds later: 18.8% hit, 465
   ops/s. It does not heal.

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
