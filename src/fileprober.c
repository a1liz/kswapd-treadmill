/*
 * fileprober.c - the victim: a page-cache-dependent file-access workload.
 *
 * Buffered 4KB random pread over a pre-populated file set.  A cache hit
 * is ~1-3us, a spinning-disk miss ~10ms, so per-second latency buckets
 * make eviction visible without any tracing.
 *
 * Modes:
 *   prep    - create the file set (zero-filled, fsynced), then drop its
 *             pages from cache with posix_fadvise(DONTNEED).
 *   drop    - just drop the set from cache (no root, unlike drop_caches).
 *   warm    - sequential read of the whole set: populates page cache.
 *             THIS is the pump: on a fragmented node each readahead
 *             folio allocation can fail and wake kswapd.
 *   measure - T threads of random 4KB pread; per-second CSV on stdout:
 *             sec ops lt20us lt100us lt1ms lt10ms ge10ms max_us
 *
 * Usage: fileprober --mode M [--dir data] [--total-gb 12] [--file-gb 2]
 *                   [--threads 4] [--secs 60] [--node 0]
 */
#include "common.h"
#include <pthread.h>
#include <fcntl.h>
#include <stdarg.h>
#include <time.h>

#define MAX_FILES 64

static void dief(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static char g_dir[256] = "data";
static long g_total_gb = 12;
static long g_file_gb = 2;
static int g_threads = 4;
static int g_secs = 60;
static int g_node = 0;

static int g_fds[MAX_FILES];
static off_t g_filesz[MAX_FILES];
static int g_nfiles;

/* per-second buckets: <20us (cache hit), <100us, <1ms, <10ms, >=10ms */
static unsigned long g_ops[64], g_b[64][5], g_max[64];

static unsigned long now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000000ul + ts.tv_nsec / 1000;
}

static void open_set(void)
{
	char path[320];
	struct stat st;

	g_nfiles = (int)(g_total_gb / g_file_gb);
	if (g_nfiles < 1 || g_nfiles > MAX_FILES)
		die("bad file count");
	for (int i = 0; i < g_nfiles; i++) {
		snprintf(path, sizeof(path), "%s/file%02d.dat", g_dir, i);
		g_fds[i] = open(path, O_RDONLY);
		if (g_fds[i] < 0)
			dief("open %s (run --mode prep first)", path);
		if (fstat(g_fds[i], &st) < 0)
			die("fstat");
		g_filesz[i] = st.st_size;
	}
}

static void do_prep(void)
{
	char path[320];
	static char buf[1 << 20];
	long per = g_file_gb << 30;

	g_nfiles = (int)(g_total_gb / g_file_gb);
	for (int i = 0; i < g_nfiles; i++) {
		snprintf(path, sizeof(path), "%s/file%02d.dat", g_dir, i);
		int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);

		if (fd < 0)
			dief("create %s", path);
		for (long off = 0; off < per; off += sizeof(buf))
			if (write(fd, buf, sizeof(buf)) != (ssize_t)sizeof(buf))
				dief("write %s", path);
		if (fsync(fd) < 0)
			die("fsync");
		close(fd);
		fprintf(stderr, "prep: %s done\n", path);
	}
	/* drop the write-back pages we just created: cold start without
	 * needing root for drop_caches */
	g_nfiles = 0;
	open_set();
	for (int i = 0; i < g_nfiles; i++)
		if (posix_fadvise(g_fds[i], 0, 0, POSIX_FADV_DONTNEED))
			fprintf(stderr, "prep: fadvise DONTNEED failed on %d\n", i);
	fprintf(stderr, "prep: set dropped from cache\n");
}

static void do_drop(void)
{
	open_set();
	for (int i = 0; i < g_nfiles; i++)
		if (posix_fadvise(g_fds[i], 0, 0, POSIX_FADV_DONTNEED))
			fprintf(stderr, "drop: fadvise failed on %d\n", i);
	fprintf(stderr, "drop: set dropped from cache\n");
}

static void do_warm(void)
{
	static char buf[1 << 20];
	unsigned long t0 = now_us();
	long total = 0;

	open_set();
	for (int i = 0; i < g_nfiles; i++)
		for (off_t off = 0; off < g_filesz[i]; off += sizeof(buf)) {
			ssize_t r = pread(g_fds[i], buf, sizeof(buf), off);

			if (r <= 0)
				die("warm read");
			total += r;
		}
	fprintf(stderr, "warm: %ldMB in %.1fs (%ldMB/s)\n", total >> 20,
		(now_us() - t0) / 1e6,
		(long)(total / 1e6 / ((now_us() - t0) / 1e6)));
}

static void *worker(void *arg)
{
	int tid = (int)(long)arg;
	/* Seed per process: with a fixed seed every measure arm replays the
	 * exact same page sequence, so the first second of a window re-reads
	 * what the previous window just pulled into cache - it looks like a
	 * hit burst (or worse, like the cache healing) when it is only the
	 * toy workload's determinism. */
	unsigned long long rng = ((unsigned long long)time(NULL) << 32) ^
				 ((unsigned long long)getpid() << 12) ^
				 (unsigned long long)now_us() ^
				 0x9e3779b97f4a7c15ull * (tid + 1);
	char buf[4096];
	char *p = buf;

	rng |= 1;	/* xorshift64 must not be seeded with 0 */

	while (!g_stop) {
		int f = (int)((rng >> 33) % g_nfiles);
		off_t off = (off_t)((rng >> 17) % (g_filesz[f] >> 12)) << 12;
		unsigned long t0, us;
		int b;

		rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
		t0 = now_us();
		if (pread(g_fds[f], p, 4096, off) != 4096)
			die("pread");
		us = now_us() - t0;
		b = us < 20 ? 0 : us < 100 ? 1 : us < 1000 ? 2 :
		    us < 10000 ? 3 : 4;
		__sync_fetch_and_add(&g_ops[tid], 1);
		__sync_fetch_and_add(&g_b[tid][b], 1);
		if (us > g_max[tid])
			g_max[tid] = us;
	}
	return NULL;
}

static void do_measure(void)
{
	pthread_t th[64];
	unsigned long po[64], pb[64][5];

	open_set();
	for (int i = 0; i < g_threads; i++)
		if (pthread_create(&th[i], NULL, worker, (void *)(long)i))
			die("pthread_create");
	memset(po, 0, sizeof(po));
	memset(pb, 0, sizeof(pb));
	printf("# sec ops lt20us lt100us lt1ms lt10ms ge10ms max_us\n");
	for (int s = 0; s < g_secs; s++) {
		sleep(1);
		unsigned long o = 0, b[5] = {0}, m = 0;

		for (int i = 0; i < g_threads; i++) {
			o += g_ops[i] - po[i]; po[i] = g_ops[i];
			for (int k = 0; k < 5; k++) {
				b[k] += g_b[i][k] - pb[i][k];
				pb[i][k] = g_b[i][k];
			}
			if (g_max[i] > m) { m = g_max[i]; }
			g_max[i] = 0;
		}
		printf("%d %lu %lu %lu %lu %lu %lu %lu\n",
		       s + 1, o, b[0], b[1], b[2], b[3], b[4], m);
		fflush(stdout);
	}
	g_stop = 1;
	for (int i = 0; i < g_threads; i++)
		pthread_join(th[i], NULL);
}

int main(int argc, char **argv)
{
	const char *mode = NULL;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--mode"))		mode = argv[++i];
		else if (!strcmp(argv[i], "--dir"))	strncpy(g_dir, argv[++i], sizeof(g_dir) - 1);
		else if (!strcmp(argv[i], "--total-gb"))g_total_gb = atol(argv[++i]);
		else if (!strcmp(argv[i], "--file-gb"))	g_file_gb = atol(argv[++i]);
		else if (!strcmp(argv[i], "--threads"))	g_threads = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--secs"))	g_secs = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--node"))	g_node = atoi(argv[++i]);
		else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
	}
	if (!mode)
		die("--mode prep|drop|warm|measure required");
	install_stop_handlers();
	if (mem_bind_node(g_node) < 0)
		die("set_mempolicy(MPOL_BIND) failed");
	if (!strcmp(mode, "prep"))
		do_prep();
	else if (!strcmp(mode, "drop"))
		do_drop();
	else if (!strcmp(mode, "warm"))
		do_warm();
	else if (!strcmp(mode, "measure"))
		do_measure();
	else
		die("bad mode");
	return 0;
}
