#!/usr/bin/env bash
# run.sh - the whole repro: A (control) -> arena -> C (fragmented) -> C2 (no re-warm).
#
# Launch it DETACHED.  This script sleeps (waiting for the arena to build,
# and the sampler sleeps once a second); a terminal tool call must not:
#
#   tmux new-session -d -s treadmill '/path/to/repo/scripts/run.sh'
#   tail -f /path/to/repo/results/<ts>/run.log
#
# Arms:
#   A   warm the file set, then measure.  No fragmentation anywhere:
#       this is the control that proves the box can do this at memory speed.
#   C   drop the cache, build the fragmented arena, warm, measure.
#       The warm is the *pump*: readahead folios cannot be satisfied, the
#       allocation slow path wakes kswapd, kswapd reclaims file pages.
#   C2  measure again right away, no re-warm: does the cache heal on its own?
#
# Everything is configurable through the environment (see README):
#   SECS TOTAL_GB FILE_GB THREADS NODE DATA_DIR MEAS_CPUS FRAG_CTL SUDO
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

DATA_DIR=${DATA_DIR:-$REPO/data}
SECS=${SECS:-60}
TOTAL_GB=${TOTAL_GB:-12}
FILE_GB=${FILE_GB:-2}
THREADS=${THREADS:-4}
NODE=${NODE:-0}
RESERVE_MB=${RESERVE_MB:-64}
PIN_KB=${PIN_KB:-1536}
MEAS_CPUS=${MEAS_CPUS:-8-11}
FRAG_CTL=${FRAG_CTL:-$REPO/scripts/frag_ctl.sh}
PIN_LOG=${PIN_LOG:-$REPO/frag_pin.log}
SUDO=${SUDO:-sudo -n}
REPEAT_MEASURE=${REPEAT_MEASURE:-1}
[ "$(id -u)" -eq 0 ] && SUDO=""

TS=$(date +%Y%m%d_%H%M%S)
R=$REPO/results/$TS
mkdir -p "$R" "$DATA_DIR"
exec > >(tee -a "$R/run.log") 2>&1

fail() { echo; echo "FAILED: $*"; exit 1; }
mark() { echo "$1" > "$R/phase"; echo "$1 $(date +%s)" >> "$R/phases.txt"; }

FILES=$((TOTAL_GB / FILE_GB))
ARGS="--node $NODE --dir $DATA_DIR --total-gb $TOTAL_GB --file-gb $FILE_GB"

TASKSET=""
if [ -n "$MEAS_CPUS" ]; then
	if [ "$(nproc)" -gt "${MEAS_CPUS##*-}" ]; then
		TASKSET="taskset -c $MEAS_CPUS"
	else
		echo "note: only $(nproc) CPUs, disabling victim pinning"
		MEAS_CPUS=""
	fi
fi

# ---------------------------------------------------------------- preflight
echo "== preflight =="
echo "results   : $R"
echo "box       : $(nproc) CPUs, MemTotal $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))MB"
echo "node$NODE    : $(( $(awk -v n="Node $NODE" '$1==n && $3=="MemTotal:"{print $4}' /sys/devices/system/node/node$NODE/meminfo 2>/dev/null || echo 0) / 1024 ))MB"
echo "file set  : ${TOTAL_GB}GB in $DATA_DIR, victim ${THREADS} threads on ${MEAS_CPUS:-any CPUs}"

[ -x "$REPO/frag_pin" ] || fail "no ./frag_pin - run make first"
[ -x "$REPO/fileprober" ] || fail "no ./fileprober - run make first"

dev=$(df --output=source "$DATA_DIR" | tail -1)
ra=$(blockdev --getra "$dev" 2>/dev/null || echo "")
if [ -n "$ra" ]; then
	rak=$((ra / 2))
	echo "read_ahead: ${rak}KB on $dev"
	[ "$rak" -eq 0 ] && fail "readahead is off on $dev - then no large folio is ever requested, nothing fails, kswapd never wakes. This repro cannot work by construction."
	rot=$(cat "/sys/block/$(basename "$(readlink -f /sys/class/block/"$(basename "$dev")")")/queue/rotational" 2>/dev/null || echo "?")
	[ "$rot" = "0" ] && echo "note: $dev is non-rotational: the effect is real but much smaller, and the cache heals fast"
fi

memtotal=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
memavail=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
[ "$memtotal" -lt $(( TOTAL_GB * 2200 / 1000 )) ] && \
	fail "MemTotal ${memtotal}MB is too small for a ${TOTAL_GB}GB set plus the arena (want >= $(( TOTAL_GB * 2200 / 1000 ))MB). Lower TOTAL_GB."
[ "$memavail" -lt $(( TOTAL_GB * 1024 + 2048 )) ] && \
	fail "only ${memavail}MB available now; the warm-up plus the arena need roughly ${TOTAL_GB}GB + 2GB free"
[ -f "$DATA_DIR/file$(printf %02d $((FILES - 1))).dat" ] || \
	[ "$(df -m --output=avail "$DATA_DIR" | tail -1)" -ge $(( TOTAL_GB * 1024 + 1024 )) ] || \
	fail "no file set yet and less than ${TOTAL_GB}GB free in $DATA_DIR"

gen=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)
[ "$gen" = "never" ] && fail "global THP enabled=never: the arena's final sweep cannot consume leftover order-9/10 blocks, so the state under test is not reached. Set it to madvise (or always)."
H2_SAVED=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled)
echo "THP       : global=$gen hugepages-2048kB=$H2_SAVED"
[ "$H2_SAVED" = "never" ] && { $SUDO "$FRAG_CTL" thp2048 inherit >/dev/null || fail "cannot set hugepages-2048kB=inherit (needed by the sweep)"; }

$SUDO "$FRAG_CTL" status >/dev/null 2>&1 || fail "cannot run '$SUDO $FRAG_CTL' - run this script as root, or whitelist it (see sudoers.example), or give frag_pin cap_ipc_lock+ep"

SAMP=""
cleanup() {
	[ -n "$SAMP" ] && kill "$SAMP" 2>/dev/null
	$SUDO "$FRAG_CTL" pin down >/dev/null 2>&1
	[ "$H2_SAVED" = "never" ] && $SUDO "$FRAG_CTL" thp2048 "$H2_SAVED" >/dev/null 2>&1
	pkill -TERM -f "$REPO/frag_pin" 2>/dev/null
}
trap cleanup EXIT

oom0=$(awk '$1=="oom_kill"{print $2}' /proc/vmstat)
echo "oom_kill  : $oom0 (must not move: nothing here should push the box into OOM)"

if [ ! -f "$DATA_DIR/file$(printf %02d $((FILES - 1))).dat" ]; then
	echo "prepping ${TOTAL_GB}GB file set (once)..."
	./fileprober --mode prep $ARGS 2>> "$R/prep.log" || fail "prep failed, see $R/prep.log"
fi

# ---------------------------------------------------------------- run
echo boot > "$R/phase"
./scripts/sampler.sh "$R/sampler.csv" "$R/phase" "$NODE" &
SAMP=$!

echo
echo "--- arm A: control, no fragmentation ---"
mark A_warm
./fileprober --mode warm $ARGS 2>> "$R/warm.log" || fail "A warm failed"
mark A
$TASKSET ./fileprober --mode measure $ARGS --threads "$THREADS" --secs "$SECS" > "$R/A.csv" || fail "A measure failed"
echo "A done"

echo
echo "--- building the arena (this is the slow part: it walks all free memory) ---"
./fileprober --mode drop $ARGS 2>> "$R/warm.log"
$SUDO "$FRAG_CTL" pin down >/dev/null 2>&1
: > "$PIN_LOG" 2>/dev/null || true
$SUDO "$FRAG_CTL" pin up "$RESERVE_MB" "$PIN_KB" || fail "cannot launch frag_pin"
for _ in $(seq 1 1800); do
	grep -q FRAG_READY "$PIN_LOG" 2>/dev/null && break
	grep -q FRAG_FAIL "$PIN_LOG" 2>/dev/null && fail "arena build failed, see $PIN_LOG"
	sleep 1
done
grep -q FRAG_READY "$PIN_LOG" 2>/dev/null || fail "arena build timed out (1800s), see $PIN_LOG"
ready=$(grep FRAG_READY "$PIN_LOG" | tail -1)
echo "$ready"
o9=$(sed -n 's/.*o9=\([0-9]*\).*/\1/p' <<<"$ready")
o10=$(sed -n 's/.*o10=\([0-9]*\).*/\1/p' <<<"$ready")
[ "${o9:-1}" -eq 0 ] && [ "${o10:-1}" -eq 0 ] || \
	fail "arena left o9=$o9 o10=$o10 free - the state under test is 'plenty free, no big blocks'; check hugepages-2048kB and $PIN_LOG"

echo
echo "--- arm C: fragmented, cache cold, warm under fragmentation ---"
mark C_warm
./fileprober --mode warm $ARGS 2>> "$R/warm.log" || fail "C warm failed"
mark C
$TASKSET ./fileprober --mode measure $ARGS --threads "$THREADS" --secs "$SECS" > "$R/C.csv" || fail "C measure failed"
echo "C done"

if [ "$REPEAT_MEASURE" = "1" ]; then
	echo
	echo "--- arm C2: measure again, no re-warm (self-healing check) ---"
	mark C2
	$TASKSET ./fileprober --mode measure $ARGS --threads "$THREADS" --secs "$SECS" > "$R/C2.csv" || fail "C2 measure failed"
	echo "C2 done"
fi

mark done
oom1=$(awk '$1=="oom_kill"{print $2}' /proc/vmstat)
echo "oom_kill: $oom0 -> $oom1"
echo
python3 ./scripts/analyze.py "$R" --secs "$SECS"
echo
echo "ALL-ARMS-DONE $R"
