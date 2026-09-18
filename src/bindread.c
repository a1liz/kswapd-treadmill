/*
 * bindread.c - read files with N-byte preads while bound to one NUMA node.
 *
 * Purpose: isolate MPOL_BIND as the only difference from dd/fio.  On a
 * multi-node box an unbound reader that cannot satisfy an order-8 folio
 * from the fragmented node simply falls back to the other node's free
 * blocks - no failure, no slow path, no kswapd wakeup.  A node-bound
 * reader cannot, so it takes the slow path on every large folio.
 *
 * Usage: bindread [--node N] [--bs BYTES] file [file...]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/syscall.h>

#ifndef MPOL_BIND
#define MPOL_BIND 2
#endif

/* atol() silently turns "1M" into 1 - a device bug that cost a run */
static long parse_size(const char *s)
{
	char *end;
	long v = strtol(s, &end, 10);

	if (*end == 'k' || *end == 'K')
		v <<= 10;
	else if (*end == 'm' || *end == 'M')
		v <<= 20;
	return v;
}

int main(int argc, char **argv)
{
	int node = 0;
	long bs = 1 << 20;
	int i = 1;
	unsigned long mask;
	char *buf;
	volatile char touch = 0;

	for (; i < argc; i++) {
		if (!strcmp(argv[i], "--node") && i + 1 < argc)
			node = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--bs") && i + 1 < argc)
			bs = parse_size(argv[++i]);
		else
			break;
	}
	if (i >= argc || bs <= 0) {
		fprintf(stderr, "usage: bindread [--node N] [--bs BYTES] file...\n");
		return 2;
	}

	mask = 1UL << (unsigned)node;
	if (syscall(SYS_set_mempolicy, MPOL_BIND, &mask, sizeof(mask) * 8) < 0) {
		perror("set_mempolicy");
		return 1;
	}

	fprintf(stderr, "bindread: node=%d bs=%ld bytes\n", node, bs);
	buf = malloc((size_t)bs);
	if (!buf) {
		perror("malloc");
		return 1;
	}
	for (long p = 0; p < bs; p += 4096)	/* fault the buffer in first */
		buf[p] = touch;

	for (; i < argc; i++) {
		int fd = open(argv[i], O_RDONLY);
		off_t off = 0;

		if (fd < 0) {
			perror(argv[i]);
			return 1;
		}
		for (;;) {
			ssize_t r = pread(fd, buf, (size_t)bs, off);

			if (r < 0) {
				perror("pread");
				return 1;
			}
			if (r == 0)
				break;
			off += r;
		}
		close(fd);
	}
	return 0;
}
