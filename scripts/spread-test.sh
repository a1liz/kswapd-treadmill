#!/usr/bin/env bash
# spread-test.sh - does the fragmentation spread to the healthy node?
#
# Scenario 2 showed that an *unbound* reader never pumps: when the local node
# cannot satisfy a 1MB readahead folio it falls back to another node, the
# allocation succeeds, and kswapd is never woken.  That looks like immunity -
# but the fallback deposits the reader's page cache on the healthy node.
#
# This script tests what happens next: fragment node 0, then have an unbound
# reader (CPU pinned to node 0, memory policy default - the common real
# configuration) read enough data to fill the *far* node.  If the far node
# then loses its large free blocks, the failure condition moves there and the
# pump should start - without anything being bound.
#
# Two samplers run, one per node, so the transition is visible per second.
#
# Launch detached:
#   tmux new-session -d -s spread "$PWD/scripts/spread-test.sh"
#
# Read at least as much data as the far node has free memory, or the state
# under test never arrives: REAL_GB + BACKUP_GB should exceed it.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

DATA_DIR=${DATA_DIR:-$REPO/data}
BACKUP_DIR=${BACKUP_DIR:-$REPO/backup}
BACKUP_GB=${BACKUP_GB:-20}	# + REAL_GB must exceed the far node's free memory
TOTAL_GB=${TOTAL_GB:-12}
FILE_GB=${FILE_GB:-2}
REAL_GB=${REAL_GB:-8}
WIN=${WIN:-240}
NODE=${NODE:-0}			# the node that gets fragmented
FAR_NODE=${FAR_NODE:-1}		# the node the reader should fall back to
TASKSET=${TASKSET:-taskset -c 8-11}	# reader pinned to NODE's CPUs, policy default
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
VSPACE=$(echo "$VFILES" | tr ':' ' ')
READ_LIST="$VFILES:$(ls "$BACKUP_DIR"/*.dat 2>/dev/null | sort | tr '\n' ':')"
READ_LIST=${READ_LIST%:}

TS=$(date +%Y%m%d_%H%M%S)
R=$REPO/results/spread-$TS
mkdir -p "$R"
exec > >(tee -a "$R/run.log") 2>&1
mark() { echo "$1" > "$R/phase"; echo "$1 $(date +%s)" >> "$R/phases.txt"; }
fail() { echo; echo "FAILED: $*"; exit 1; }
H2_SAVED=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled)
cleanup() {
	[ -n "${S0:-}" ] && kill -KILL "$S0" 2>/dev/null
	[ -n "${S1:-}" ] && kill -KILL "$S1" 2>/dev/null
	$SUDO "$FRAG_CTL" pin down >/dev/null 2>&1
	[ "$H2_SAVED" = "never" ] && $SUDO "$FRAG_CTL" thp2048 "$H2_SAVED" >/dev/null 2>&1
}
trap cleanup EXIT

drop_all() {
	./fileprober --mode drop --dir "$DATA_DIR" --total-gb "$REAL_GB" --file-gb "$FILE_GB" >/dev/null 2>&1
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
nline() {	# nline <node> : free + o7..o10 of one node
	awk -v n="$1" '$1=="Node" && $2==n && $3=="MemFree:"{printf "free=%dMB", $4/1024}' \
		/sys/devices/system/node/node$1/meminfo
	awk -v n="$1," '$1=="Node" && $2==n && $4=="Normal"{printf "  o7=%s o8=%s o9=%s o10=%s", $12,$13,$14,$15}' /proc/buddyinfo
}

echo "== preflight =="
echo "results     : $R"
echo "frag node   : $NODE    fallback node: $FAR_NODE"
[ -x ./frag_pin ] && [ -x ./fileprober ] || fail "run make first"
command -v fio >/dev/null || fail "fio not installed"
[ -f "$DATA_DIR/file$(printf %02d $((FILES - 1))).dat" ] || fail "victim set missing in $DATA_DIR"
$SUDO "$FRAG_CTL" status >/dev/null 2>&1 || fail "cannot run '$SUDO $FRAG_CTL'"
[ "$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)" = "never" ] && \
	fail "global THP enabled=never: the arena cannot clear order-9/10 blocks"
if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
	echo "creating a ${BACKUP_GB}GB backup tree (once)..."
	mkdir -p "$BACKUP_DIR"
	for i in $(seq -w 1 $((BACKUP_GB * 2))); do
		dd if=/dev/zero of="$BACKUP_DIR/b$i.dat" bs=1M count=512 status=none
	done
	wait_writeback
fi

echo; echo "== arena on node $NODE =="
[ "$H2_SAVED" = "never" ] && $SUDO "$FRAG_CTL" thp2048 inherit >/dev/null
drop_all	# before the arena: dropping a big cache afterwards heals the fragmentation
echo boot > "$R/phase"
./scripts/sampler.sh "$R/sampler$NODE.csv" "$R/phase" "$NODE" &
S0=$!
./scripts/sampler.sh "$R/sampler$FAR_NODE.csv" "$R/phase" "$FAR_NODE" &
S1=$!
mark pinup
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
echo "node$NODE     : $(nline "$NODE")"
echo "node$FAR_NODE     : $(nline "$FAR_NODE")"

echo; echo "== unbound reader (CPU pinned to node $NODE, memory policy default) =="
mark spread
t0=$(date +%s)
timeout "$WIN" $TASKSET fio --name=spread --rw=read --bs=1M --numjobs=1 \
	--filename="$READ_LIST" --ioengine=psync --direct=0 --invalidate=0 \
	--output-format=json --output="$R/spread.fio.json" > /dev/null 2>&1
el=$(( $(date +%s) - t0 ))
[ "$el" -lt $((WIN / 2)) ] && echo "  WARNING: reader returned after ${el}s (expected ~${WIN}s)"
mark done
echo "node$NODE     : $(nline "$NODE")"
echo "node$FAR_NODE     : $(nline "$FAR_NODE")"

echo; echo "== per-node, per-phase =="
python3 ./scripts/report-spread.py "$R" "$NODE" "$FAR_NODE"
echo; echo "SPREAD-TEST-DONE $R"
