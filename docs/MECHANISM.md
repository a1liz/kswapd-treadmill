# Why this happens - source references (Linux 7.2.3)

Everything below is the stock kernel. No patch, no tunable except the
ones named. Line numbers are from the tree this was developed on; the
functions are stable across recent kernels.

## 1. Page-cache readahead allocations can wake kswapd

Every inode's page cache - readahead included - allocates with
`GFP_HIGHUSER_MOVABLE`:

```c
fs/inode.c:278   mapping_set_gfp_mask(mapping, GFP_HIGHUSER_MOVABLE);
```

and that mask carries `__GFP_KSWAPD_RECLAIM` (via `__GFP_RECLAIM`):

```c
include/linux/gfp_types.h:259  #define __GFP_RECLAIM ((__force gfp_t)(___GFP_DIRECT_RECLAIM|___GFP_KSWAPD_RECLAIM))

include/linux/pagemap.h:670    static inline gfp_t readahead_gfp_mask(struct address_space *x)
                               { return mapping_gfp_mask(x) | __GFP_NORETRY | __GFP_NOWARN; }
```

`__GFP_NORETRY` makes the readahead give up quickly - it does not stop
the wake-up below.

## 2. Which order it asks for

```c
mm/readahead.c:481  page_cache_ra_order()
mm/readahead.c:493      unsigned int new_order = ra->order;
mm/readahead.c:510      new_order = min(mapping_max_folio_order(mapping), new_order);
mm/readahead.c:511      new_order = min_t(unsigned int, new_order, ilog2(ra->size));
```

`ra->order` ramps up as a sequential read proceeds:

```c
mm/readahead.c:712      ra->order += 2;        /* async readahead path */
```

and the window `ra->size` is capped by `ractl_max_pages()` =
`max(bdi->io_pages, ra->ra_pages)` (`mm/readahead.c:562`), where
`io_pages` comes from the device's `max_sectors`
(`block/blk-settings.c:85`) or defaults to `VM_READAHEAD_PAGES`
(`mm/backing-dev.c:1037`).

On the reference box (`max_sectors_kb=1024`, `read_ahead_kb=512`):
`io_pages = 2048 sectors >> 3 = 256 pages` -> `ilog2 = 8` -> **the
sequential read asks for order-8 (1MB) folios**. That is the number
that has to exist as a free contiguous block for the read to be quiet.

The sampler's `o5..o10` columns measure exactly that precondition, and in
the reference run they separate the two arms cleanly:

```
freeMB    o5    o6    o7    o8    o9   o10
A_warm   57049  7794  6378  5170     1     0 10424     <- kswapd idle (0 pages/s)
C_warm   15293 30971 28796    20     0     0     0     <- kswapd at 51k pages/s
```

15.3GB free and nothing above 256KB in one piece: every 1MB readahead
request must fail. There is no need to guess whether the box is "really"
fragmented - you can read it off the table.

Note that the order is reduced only for window/EOF alignment, never on
allocation failure:

```c
mm/readahead.c:533      while (order > min_order && index + (1UL << order) - 1 > limit)
mm/readahead.c:534              order--;
...
mm/readahead.c:554          err = ra_alloc_folio(ractl, index, mark, order, gfp);
mm/readahead.c:555          if (err)
mm/readahead.c:556                  break;
...
mm/readahead.c:597      do_page_cache_ra(ractl, ra->size - (index - start), ra->async_size);   /* fallback */
```

So a failed order-8 attempt degrades to an order-0 page-at-a-time read.
The read still completes at full bandwidth - the only visible cost is
the wake-up in step 3.

## 3. The failing allocation wakes kswapd before it retries

`__alloc_pages_slowpath()` is entered whenever the fast path cannot
satisfy the requested order:

```c
mm/page_alloc.c:4813  retry:
mm/page_alloc.c:4814          /* Ensure kswapd doesn't accidentally go to sleep as long as we loop */
mm/page_alloc.c:4815          if (alloc_flags & ALLOC_KSWAPD)
mm/page_alloc.c:4816                  wake_all_kswapds(order, gfp_mask, ac);
```

with the bit defined as exactly `__GFP_KSWAPD_RECLAIM`:

```c
mm/internal.h:1479     #define ALLOC_KSWAPD 0x800 /* allow waking of kswapd, __GFP_KSWAPD_RECLAIM set */
mm/page_alloc.c:4487   BUILD_BUG_ON(__GFP_KSWAPD_RECLAIM != (__force gfp_t) ALLOC_KSWAPD);
```

**One failed order-8 readahead folio = one kswapd wake-up**, even though
the allocation immediately falls back to order 0 and succeeds.

## 4. What kswapd does with each wake-up: one small bite

```c
mm/vmscan.c:7480  wakeup_kswapd(zone, gfp_flags, order, highest_zoneidx)   /* records order, wakes */
```

```c
mm/vmscan.c:7017  if (sc->order && sc->nr_reclaimed >= compact_gap(sc->order))
mm/vmscan.c:7018          sc->order = 0;                     /* kswapd_shrink_node() */
```

```c
include/linux/compaction.h:67  static inline unsigned long compact_gap(unsigned int order)
                               { ... return min(2UL << order, COMPACT_CLUSTER_MAX); }
```

`COMPACT_CLUSTER_MAX = SWAP_CLUSTER_MAX = 32` (`include/linux/swap.h:220`),
so for any order this high the budget is **32 pages**, after which
`sc->order` drops to 0 and `prepare_kswapd_sleep()`
(`mm/vmscan.c:6952`, check at `:6975`) evaluates the *order-0*
watermarks - which are satisfied on a machine with 10+GB free - and
kswapd goes back to sleep. The source comment says the quiet part out
loud: *"Assume that a process requested a high-order can direct
reclaim/compact."*

Arithmetic from the reference run: `46,390 pages scanned/s / ~32 pages
per wake-up ~= 1400 wake-ups/s`. The harm is the **frequency**, not the
size of any one reclaim. It also explains why "cap `sc->nr_to_reclaim`"
would change little in this scenario: each wake-up is already tiny.

## 5. Why it stops when the read stops

Random 4KB reads are not a sequential stream: `page_cache_sync_ra()`
takes the plain path and the requested order stays 0 (`mm/readahead.c:647`
resets `ra->order = 0`), and an order-0 allocation succeeds trivially
when gigabytes are free. No failed allocation -> no slow path -> no
wake-up -> kswapd silent, and the page cache stays exactly as the fill
left it.

In the data this shows up as: the measure window's first one or two rows
can still carry the tail of the fill (a readahead window issued just
before the warm returned), and every row after that is zero.

## 6. Why this is not the THP story

```c
include/linux/gfp_types.h:387  #define GFP_TRANSHUGE_LIGHT  (GFP_HIGHUSER_MOVABLE | __GFP_COMP | \
                                       __GFP_NOMEMALLOC | __GFP_NOWARN | __GFP_NORETRY)
                               /* __GFP_RECLAIM stripped entirely */
                               #define GFP_TRANSHUGE  (GFP_TRANSHUGE_LIGHT | __GFP_DIRECT_RECLAIM)
```

Neither THP mask carries `__GFP_KSWAPD_RECLAIM`. Consequences:

- `defrag=madvise` THP faults do direct reclaim/compaction **in the
  faulting process**; kswapd never runs for them.
- `MADV_COLLAPSE` and khugepaged use `GFP_TRANSHUGE` - same thing.
- Only the `defrag=defer` fault path adds `__GFP_KSWAPD_RECLAIM`, so it
  does wake kswapd at order 9 - but each wake-up is bounded by the same
  `compact_gap` rule, and the allocations that fail are only the faults
  that happen to fail. An allocator that allocates and frees in a loop
  recycles its own high-order blocks and stops failing; the readahead
  pump cannot, because it never stops wanting the next 1MB folio.

If you came here from "THP pressure under fragmentation hurts file
workloads": that framing sends you looking for a THP workload. The
control arm in this repro (`A`) and the arena-only arm (`C`) show the
victim is enough on its own.

## 7. What the three proposed fixes would do here

| proposed change | effect in this scenario |
|---|---|
| cap `sc->nr_to_reclaim` / the reclaim budget | nearly nothing: each wake-up already reclaims only ~32 pages; the bleed is the wake-up rate |
| wake `kcompactd` instead of / in addition to kswapd | treats the cause: if order-8 blocks existed, the allocation would succeed and nothing would be woken. The only one of the three that removes the failure stream |
| drop `__GFP_KSWAPD_RECLAIM` from readahead allocations | disables the pump. Readahead already degrades to order-0 on failure, and waking kswapd to reclaim the very page cache that the readahead is filling is hard to justify when free memory is not the problem |

## 8. Not measured here (honest gaps)

- The exact per-wake-up reclaim is inferred from `compact_gap`, not
  traced. `vmscan/mm_vmscan_kswapd_wake` is the tracepoint to use if you
  want the count directly.
- Only the fill phase is instrumented per buddy order (`o5..o10` in the
  sampler). The measure phase's allocation orders are inferred from the
  source, not sampled.
- The one experiment that would isolate the pump completely - warming
  with `POSIX_FADV_RANDOM` so that only order-0 allocations are made -
  is impractical on a slow disk: 12GB as single-page reads at ~380 IOPS
  is over two hours. The `A` vs `C` contrast (same workload, same disk,
  fragmentation the only difference) is what stands in for it.

## 9. Two artifacts this rig had to shake out

Both cost real time in developing this repro, so they are recorded here.

**The early-window hit burst.** A measure window could start at a hit
rate far above what the cache can support (87% in the first second of
the `C2` arm of the reference run, against a steady 18%), then drop to
normal in the next second. It looked like the cache "healing". It was
neither healing nor a measurement artifact of the buckets: the victim's
random offsets were seeded with a *constant*, so every measure arm
replayed the identical page sequence. The prefix of a window re-read
exactly the pages the previous window had just pulled into cache, and
they were still cached. Arithmetic from the run: `C` did ~27,600 reads
in its 60 seconds; `C2`'s first second did 28,200 reads, of which 27,591
were <20us. Fixed by seeding the generator per process
(`src/fileprober.c`).

**Refaults that are not reclaim.** `workingset_refault_file` counts a
read of any page that was in the cache earlier and got evicted - by
anything, at any time. Reading a file set that was evicted an hour ago
therefore shows refaults against zero kswapd activity. Inside a measure
window the column is useful (in the reference run: 380/s against 457
ops/s at 17% hit - i.e. exactly the victim's misses), but do not read it
as evidence of reclaim during a fill.
