/*
 * frag_pin.c - "fragmented but sufficient" memory state builder.
 *
 * Goal: the machine has plenty of free memory, but no free contiguous
 * block of an order the kernel's readahead wants (order-5..9).  That is
 * the state in which a *failing* high-order page-cache allocation wakes
 * kswapd while 10+GB sits free.
 *
 * v1 died: free space merges into the largest blocks, so "leave 16GB
 * free" = "16GB of order-10 blocks" - grinding them spends the free.
 * v2 died: it mlocked 1.5MB per VIRTUAL 2MB frame but never faulted the
 * 512KB tails - untouched virtual space allocates NOTHING, so the buddy
 * kept its big blocks (o10=1665 left).
 *
 * v3 (this one): fault EVERY page of the span first (splits all blocks;
 * pages come out of the buddy in ~4MB drain chunks, so they are
 * physically contiguous and 2MB-aligned), THEN per virtual 2MB frame
 * mlock the first 1.5MB and MADV_DONTNEED the 512KB tail.  The tails
 * return to the buddy as free fragments, so:
 *   - every physical 2MB frame holds unevictable pins (seams between
 *     4MB drain chunks can at worst join two 512KB tails = order-8):
 *     no order-9 block can exist or be re-assembled by compaction;
 *   - free memory = tails + reserve: ~14GB genuinely free for order-0
 *     (page cache) - "free memory is sufficient";
 *   - the pinned ~75% is unevictable: kswapd's ONLY prey is file cache.
 *
 * The page cache must be COLD at construction (run.sh drops it), then
 * warmed AFTER: cache pages land in the tails, so evicting them cannot
 * merge an order-9 block back.
 *
 * Needs CAP_IPC_LOCK (root, or `setcap cap_ipc_lock+ep frag_pin`).
 * The final THP sweep needs 2MB THP enabled for MADV_HUGEPAGE areas
 * (hugepages-2048kB != never, global enabled = always|madvise).
 *
 * Usage: frag_pin [--node 0] [--reserve-mb 64] [--pin-kb 1536]
 */
#include "common.h"
#include <stdarg.h>

static int g_node = 0;
static long g_reserve_mb = 64;
static long g_pin_kb = 1536;	/* pinned KB per 2MB frame */

#define FRAME (2ul << 20)
#define THP_SWEEP_MAX 512

static void *g_span;
static size_t g_span_len;

static void dief(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static long normal_free_mb(void)
{
	struct zone_stat zs;

	if (zone_info(g_node, "Normal", &zs) < 0)
		die("zone_info failed");
	return zs.free / 256;	/* pages -> MB */
}

static void hi_blocks(long *o9, long *o10)
{
	long orders[11];

	memset(orders, 0, sizeof(orders));
	if (buddyinfo(g_node, "Normal", orders, 11) < 0)
		die("buddyinfo failed");
	*o9 = orders[9];
	*o10 = orders[10];
}

int main(int argc, char **argv)
{
	long free_mb, o9, o10;
	size_t nframes;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--node"))		g_node = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--reserve-mb")) g_reserve_mb = atol(argv[++i]);
		else if (!strcmp(argv[i], "--pin-kb"))	g_pin_kb = atol(argv[++i]);
		else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
	}
	if (geteuid() != 0)
		die("frag_pin needs root (CAP_IPC_LOCK for mlock)");
	if (g_pin_kb <= 0 || g_pin_kb >= 2048)
		die("--pin-kb must be in (0, 2048)");
	install_stop_handlers();
	if (mem_bind_node(g_node) < 0)
		die("set_mempolicy(MPOL_BIND) failed");

	free_mb = normal_free_mb();
	g_span_len = (size_t)(free_mb - g_reserve_mb) << 20;
	g_span_len &= ~(FRAME - 1);
	if ((long)(g_span_len >> 20) < 4096)
		dief("Normal free %ldMB too small", free_mb);
	fprintf(stderr,
		"frag_pin: Normal free %ldMB, span %ldMB, pin %ldKB/2MB frame\n",
		free_mb, (long)(g_span_len >> 20), g_pin_kb);

	g_span = mmap(NULL, g_span_len, PROT_READ | PROT_WRITE,
		      MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	if (g_span == MAP_FAILED)
		die("mmap span");
	madvise(g_span, g_span_len, MADV_NOHUGEPAGE);

	/* pass 1: fault EVERY page - splits all buddy blocks */
	for (size_t off = 0; off < g_span_len && !g_stop;
	     off += EXP_PAGE_SIZE) {
		*(volatile char *)(g_span + off) = 1;
		if (off && off % (4ul << 30) == 0)
			fprintf(stderr, "frag_pin: faulted %zuGB, free %ldMB\n",
				off >> 30, normal_free_mb());
	}
	if (g_stop)
		return 1;
	fprintf(stderr, "frag_pin: span faulted, free %ldMB\n",
		normal_free_mb());

	/* pass 2: per 2MB frame, lock the pin part, free the tail */
	nframes = g_span_len / FRAME;
	for (size_t i = 0; i < nframes && !g_stop; i++) {
		char *f = g_span + i * FRAME;

		if (mlock(f, (size_t)g_pin_kb << 10) < 0)
			dief("mlock frame %zu failed (free=%ldMB)",
			     i, normal_free_mb());
		madvise(f + (g_pin_kb << 10), FRAME - (g_pin_kb << 10),
			MADV_DONTNEED);
		if (i % 4096 == 4095)
			fprintf(stderr, "frag_pin: framed %zu/%zu, free %ldMB\n",
				i + 1, nframes, normal_free_mb());
	}
	if (g_stop)
		return 1;
	fprintf(stderr, "frag_pin: checkerboard done (%zu frames), free %ldMB\n",
		nframes, normal_free_mb());

	/* THP sweep: consume leftover order-9/10 blocks as locked folios.
	 * Needs 2MB THP (MADV_HUGEPAGE + one fault = one order-9 folio);
	 * with hugepages-2048kB=never the block is split instead of eaten
	 * and FRAG_READY will report a nonzero o9/o10 residue. */
	hi_blocks(&o9, &o10);
	for (int it = 0; (o9 > 0 || o10 > 0) && it < THP_SWEEP_MAX && !g_stop;
	     it++) {
		char *p = mmap(NULL, FRAME, PROT_READ | PROT_WRITE,
			       MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);

		if (p == MAP_FAILED)
			die("mmap thp sweep");
		madvise(p, FRAME, MADV_HUGEPAGE);
		*(volatile char *)p = 1;	/* one fault: THP eats a block */
		if (mlock(p, FRAME) < 0)
			dief("mlock thp sweep failed");
		/* mapping intentionally leaked: exit releases it */
		if (it % 256 == 255)
			fprintf(stderr, "frag_pin: thp sweep %d, o9=%ld o10=%ld\n",
				it + 1, o9, o10);
		hi_blocks(&o9, &o10);
	}

	printf("FRAG_READY span_mb=%ld pin_kb=%ld free_mb=%ld o9=%ld o10=%ld\n",
	       (long)(g_span_len >> 20), g_pin_kb, normal_free_mb(), o9, o10);
	fflush(stdout);
	if (o9 > 0 || o10 > 0)
		fprintf(stderr, "frag_pin: WARN residue o9=%ld o10=%ld\n", o9, o10);

	while (!g_stop)
		pause();

	munlockall();
	munmap(g_span, g_span_len);
	printf("FRAG_DONE\n");
	fflush(stdout);
	return 0;
}
