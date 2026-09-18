#!/usr/bin/env bash
# run-real.sh - the real-scenario variant: two independent processes
#
#   pump     = tar streaming a backup tree,  models `tar cf - /data | ssh backup`
#   victim   = fio randread 4KB x4 jobs over its own working set (disjoint from
#              the backup tree), models a cache-dependent service
#
# Arms (the backup runs from before the service warms up, and is stopped for
# the last window to see whether the cache heals):
#   R1  no fragmentation:   backup+warm -> backup+victim 60s -> victim 60s
#   R2  fragmented (arena): same
#
# The headline is window 1 of each arm: same backup, same service, same disk,
# only the fragmentation differs.  Read docs/REAL-SCENARIO.md first - the
# result depends on whether the readers' allocations are confined to the
# fragmented node, and on this rig they are NOT (no MPOL_BIND), which is
# itself part of the finding.
#
# Launch detached:  tmux new-session -d -s realscn "$PWD/scripts/run-real.sh"
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

DATA_DIR=${DATA_DIR:-$REPO/data}
BACKUP_DIR=${BACKUP_DIR:-$REPO/backup}
BACKUP_GB=${BACKUP_GB:-8}
TOTAL_GB=${TOTAL_GB:-12}
FILE_GB=${FILE_GB:-2}
REAL_GB=${REAL_GB:-8}
WIN=${WIN:-60}
NODE=${NODE:-0}
TASKSET=${TASKSET:-taskset -c 8-11}
FRAG_CTL=${FRAG_CTL:-$REPO/scripts/frag_ctl.sh}
PIN_LOG=${PIN_LOG:-$REPO/frag_pin.log}
SUDO=${SUDO:-sudo -n}
[ "$(id -u)" -eq 0 ] && SUDO=""

FILES=$((REAL_GB / FILE_GB))
VFILES=""
for i in $(seq 0 $((FILES - 1))); do
	VFILES="$VFILES$DATA_DIR/file$(printf %02d "$i").dat:"
done
VFILES=${VFILES%:}

TS=$(date +%Y%m%d_%H%M%S)
R=$REPO/results/real-$TS
mkdir -p "$R"
exec > >(tee -a "$R/run.log") 2>&1
mark() { echo "$1" > "$R/phase"; echo "$1 $(date +%s)" >> "$R/phases.txt"; }
fail() { echo; echo "FAILED: $*"; exit 1; }
H2_SAVED=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled)

cleanup() {
	[ -n "${SAMP:-}" ] && kill -KILL "$SAMP" 2>/dev/null	# sampler ignores TERM
	pkill -x tar 2>/dev/null
	$SUDO "$FRAG_CTL" pin down >/dev/null 2>&1
	[ "$H2_SAVED" = "never" ] && $SUDO "$FRAG_CTL" thp2048 "$H2_SAVED" >/dev/null 2>&1
}
trap cleanup EXIT

drop_tree() {
	python3 - "$BACKUP_DIR" <<'PY'
import os, sys
d = sys.argv[1]
if os.path.isdir(d):
    for f in sorted(os.listdir(d)):
        p = os.path.join(d, f)
        if os.path.isfile(p):
            fd = os.open(p, os.O_RDONLY)
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
            os.close(fd)
PY
}
wait_writeback() {
	for _ in $(seq 1 600); do
		dirty=$(awk '/^Dirty:/{print $2}' /proc/meminfo)
		[ "${dirty:-0}" -lt 102400 ] && return 0
		sleep 2
	done
}
warm() {	# sequential read of the victim's working set
	$TASKSET fio --name=warm --rw=read --bs=1M --numjobs=1 --filename="$VFILES" \
		--ioengine=psync --direct=0 --invalidate=0 --group_reporting \
		--output-format=json --output="$R/$1.warm.json" > /dev/null || fail "warm $1"
}
victim() {	# fio random reads for WIN seconds
	$TASKSET fio --name=victim --rw=randread --bs=4k --numjobs=4 \
		--filename="$VFILES" --ioengine=psync --direct=0 --invalidate=0 \
		--time_based --runtime="$WIN" --group_reporting --randrepeat=0 \
		--output-format=json --output="$R/$1.fio.json" > /dev/null || fail "victim $1"
}
pump() {	# the backup: stream the tree to a consumer, until killed
	# NOT `> /dev/null`: GNU tar sees /dev/null as the archive target and
	# skips reading the data entirely (0.057s, rc=0) - the backup silently
	# becomes a no-op.  Pipe it through cat instead.
	while :; do
		tar cf - -C "$BACKUP_DIR" . 2>/dev/null | cat > /dev/null
	done
}
arm() {		# arm R1|R2
	local n=$1
	drop_tree
	pump & local p=$!
	mark "${n}_warm"; warm "${n}w"    || { kill $p; return 1; }
	mark "${n}_w1";   victim "${n}w1" || { kill $p; return 1; }
	kill $p 2>/dev/null; pkill -x tar 2>/dev/null
	mark "${n}_w2";   victim "${n}w2" || return 1
	echo "$n done"
}

echo "== preflight =="
echo "results : $R"
[ -x ./frag_pin ] && [ -x ./fileprober ] || fail "run make first"
command -v fio >/dev/null || fail "fio not installed (apt-get install fio)"
[ -f "$DATA_DIR/file$(printf %02d $((FILES - 1))).dat" ] || fail "victim set missing in $DATA_DIR"
$SUDO "$FRAG_CTL" status >/dev/null 2>&1 || fail "cannot run '$SUDO $FRAG_CTL'"
[ "$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)" = "never" ] && \
	fail "global THP enabled=never: the arena cannot clear order-9/10 blocks"
[ "$(pgrep -c -f 'tar cf - -C' || true)" != "0" ] && echo "note: a tar pump is already running"

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
	echo "creating a ${BACKUP_GB}GB backup tree (once)..."
	mkdir -p "$BACKUP_DIR"
	for i in $(seq -w 1 $((BACKUP_GB * 2))); do
		dd if=/dev/zero of="$BACKUP_DIR/b$i.dat" bs=1M count=512 status=none
	done
fi
wait_writeback	# a freshly created tree leaves GBs of dirty pages that saturate the disk

echo boot > "$R/phase"
./scripts/sampler.sh "$R/sampler.csv" "$R/phase" "$NODE" &
SAMP=$!

echo; echo "--- R1 control: no fragmentation ---"
arm R1

echo; echo "--- arena ---"
mark pinup
./fileprober --mode drop --dir "$DATA_DIR" --total-gb "$REAL_GB" --file-gb "$FILE_GB" >/dev/null 2>&1
drop_tree	# also before the arena: a big drop afterwards frees large blocks and heals the fragmentation
$SUDO "$FRAG_CTL" pin down >/dev/null 2>&1
before=$(wc -l < "$PIN_LOG" 2>/dev/null || echo 0)
$SUDO "$FRAG_CTL" pin up 64 1536 || fail "frag_pin launch failed"
ready=""
for _ in $(seq 1 1800); do
	ready=$(tail -n +$((before + 1)) "$PIN_LOG" 2>/dev/null | grep "^FRAG_READY" | tail -1)
	[ -n "$ready" ] && break
	tail -n +$((before + 1)) "$PIN_LOG" 2>/dev/null | grep -q "^FRAG_FAIL" && break
	sleep 1
done
[ -n "$ready" ] || fail "arena build failed"
echo "$ready"
o9=$(sed -n 's/.*o9=\([0-9]*\).*/\1/p' <<<"$ready")
o10=$(sed -n 's/.*o10=\([0-9]*\).*/\1/p' <<<"$ready")
[ "${o9:-1}" -eq 0 ] && [ "${o10:-1}" -eq 0 ] || fail "arena residue o9=$o9 o10=$o10"

echo; echo "--- R2 treatment: fragmented ---"
arm R2

mark done
echo; python3 ./scripts/report-real.py "$R" --win "$WIN"
echo; echo "ALL-ARMS-DONE $R"
