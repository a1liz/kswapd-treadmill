/* common.h - shared helpers for the kswapd page-cache treadmill repro.
 *
 * Deliberately small: NUMA mempolicy binding, one zone's stats, buddyinfo,
 * and stop handling.  No THP knobs, no thread machinery.
 */
#ifndef COMMON_H
#define COMMON_H

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <pthread.h>

/* x86_64, 4KB base page */
#define EXP_PAGE_SIZE 4096

/* ------------------------------------------------------------------ */
/* small file helpers                                                  */
/* ------------------------------------------------------------------ */

static int read_text(const char *path, char *buf, size_t sz)
{
	int fd = open(path, O_RDONLY);
	ssize_t n;

	if (fd < 0)
		return -1;
	n = read(fd, buf, sz - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = '\0';
	return 0;
}

/* ------------------------------------------------------------------ */
/* NUMA mempolicy via raw syscall (no libnuma dependency)              */
/* ------------------------------------------------------------------ */

#ifndef MPOL_BIND
#define MPOL_BIND 2
#endif

static int mem_bind_node(int nid)
{
	unsigned long mask = 1UL << (unsigned)nid;

	/* maxnode must cover at least one full unsigned long, else EINVAL */
	return (int)syscall(SYS_set_mempolicy, MPOL_BIND, &mask,
			    sizeof(unsigned long) * 8);
}

/* ------------------------------------------------------------------ */
/* zoneinfo / buddyinfo                                                */
/* ------------------------------------------------------------------ */

struct zone_stat {
	long free, min, low, high, managed;
	long pgscan_kswapd, pgsteal_kswapd;
	long pgscan_direct, pgsteal_direct;
};

/* parse one node/zone section of /proc/zoneinfo */
static int zone_info(int nid, const char *zone, struct zone_stat *zs)
{
	FILE *f;
	char line[512], header[64];
	int in = 0;

	memset(zs, 0, sizeof(*zs));
	snprintf(header, sizeof(header), "Node %d, zone", nid);
	f = fopen("/proc/zoneinfo", "r");
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		char zname[32];
		int znode;
		char key[64];
		long val;

		if (!strncmp(line, header, strlen(header))) {
			if (sscanf(line + strlen(header), "%31s", zname) == 1 &&
			    sscanf(line, "Node %d, zone", &znode) == 1)
				in = (znode == nid && !strcmp(zname, zone));
			continue;
		}
		if (!in)
			continue;
		if (sscanf(line, " pages free %ld", &val) == 1) {
			zs->free = val;
			continue;
		}
		if (sscanf(line, " %63s %ld", key, &val) == 2) {
			if (!strcmp(key, "min"))		zs->min = val;
			else if (!strcmp(key, "low"))		zs->low = val;
			else if (!strcmp(key, "high"))		zs->high = val;
			else if (!strcmp(key, "managed"))	zs->managed = val;
			else if (!strcmp(key, "pgscan_kswapd"))	zs->pgscan_kswapd = val;
			else if (!strcmp(key, "pgsteal_kswapd"))zs->pgsteal_kswapd = val;
			else if (!strcmp(key, "pgscan_direct"))	zs->pgscan_direct = val;
			else if (!strcmp(key, "pgsteal_direct"))zs->pgsteal_direct = val;
		}
	}
	fclose(f);
	return 0;
}

/* /proc/buddyinfo: "Node 0, zone   Normal    562 1114 ..." */
static int buddyinfo(int nid, const char *zone, long *orders, int max_orders)
{
	FILE *f;
	char line[1024], header[64];
	int found = 0;

	snprintf(header, sizeof(header), "Node %d, zone", nid);
	f = fopen("/proc/buddyinfo", "r");
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		char zname[32];
		int znode;
		char *p;

		if (strncmp(line, header, strlen(header)))
			continue;
		if (sscanf(line, "Node %d, zone %31s", &znode, zname) != 2)
			continue;
		if (znode != nid || strcmp(zname, zone))
			continue;
		p = strstr(line, zone) + strlen(zone);
		for (int i = 0; i < max_orders; i++) {
			char *end;
			long v = strtol(p, &end, 10);

			if (end == p)
				break;
			orders[i] = v;
			p = end;
			found = i + 1;
		}
		break;
	}
	fclose(f);
	return found > 0 ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* misc                                                                */
/* ------------------------------------------------------------------ */

static volatile sig_atomic_t g_stop;

static void on_stop_sig(int sig)
{
	(void)sig;
	g_stop = 1;
}

static void install_stop_handlers(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_stop_sig;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
}

static void die(const char *msg)
{
	fprintf(stderr, "FATAL: %s (errno=%d %s)\n", msg, errno,
		strerror(errno));
	exit(1);
}

#endif /* COMMON_H */
