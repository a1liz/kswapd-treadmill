#!/usr/bin/env bash
# pump-test.sh - which sequential readers actually act as a "pump"?
#
# On one fixed fragmented state, run several readers in turn, each preceded
# by dropping the page cache, and report what kswapd did during each window.
# A reader is a pump when its readahead folio allocations fail - which needs
# the allocation to be *confined* to the fragmented node (see docs/).
#
#   PUMP_READERS="fp dd bind1M" ./scripts/pump-test.sh
#
# Readers available:
#   fp      ./fileprober --mode warm        (MPOL_BIND node)   <- positive control
#   bind1M  ./bindread --bs 1M              (MPOL_BIND node)
#   bind4K  ./bindread --bs 4k              (MPOL_BIND node)
#   dd      dd bs=1M                        (unbound)
#   fio     fio --rw=read --bs=1M           (unbound)
#   tar     tar default 10KB blocks         (unbound)
#   tar1M   tar -b 2048 (1MB blocks)        (unbound)
#
# Launch detached - the script sleeps:
#   tmux new-session -d -s pump "$PWD/scripts/pump-test.sh"
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

DATA_DIR=${DATA_DIR:-$REPO/data}
BACKUP_DIR=${BACKUP_DIR:-$REPO/backup}
BACKUP_GB=${BACKUP_GB:-8}
TOTAL_GB=${TOTAL_GB:-12}
FILE_GB=${FILE_GB:-2}
REAL_GB=${REAL_GB:-8}		# victim set used by the readers
NODE=${NODE:-0}
WIN=${WIN:-40}
TASKSET=${TASKSET:-taskset -c 8-11}
FRAG_CTL=${FRAG_CTL:-$REPO/scripts/frag_ctl.sh}
PIN_LOG=${PIN_LOG:-$REPO/frag_pin.log}
SUDO=${SUDO:-sudo -n}
PUMP_READERS=${PUMP_READERS:-"fp tar dd bind1M"}
RESERVE_MB=${RESERVE_MB:-64}
PIN_KB=${PIN_KB:-1536}
[ "$(id -u)" -eq 0 ] && SUDO=""

FILES=$((REAL_GB / FILE_GB))
VFILES=""
for i in $(seq 0 $((FILES - 1))); do
	VFILES="$VFILES$DATA_DIR/file$(printf %02d "$i").dat:"
done
VFILES=${VFILES%:}
VSPACE=$(echo "$VFILES" | tr ':' ' ')	# bindread/dd take plain argv, not fio's colon list

TS=$(date +%Y%m%d_%H%M%S)
R=$REPO/results/pump-$TS
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

# fadvise(DONTNEED) over a directory - the readers must start cold, and the
# cache they just filled must not linger into the next window
drop_tree() {
	python3 - "$1" <<'PY'
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
drop_all() {
	./fileprober --mode drop --dir "$DATA_DIR" --total-gb "$REAL_GB" --file-gb "$FILE_GB" >/dev/null 2>&1
	drop_tree "$BACKUP_DIR"
}

# A freshly written backup tree leaves GBs of dirty pages; writeback then
# saturates the disk and poisons every timing that follows (we measured fio
# at 22 IOPS because of it).  Wait for it.
wait_writeback() {
	for _ in $(seq 1 600); do
		dirty=$(awk '/^Dirty:/{print $2}' /proc/meminfo)
		[ "${dirty:-0}" -lt 102400 ] && return 0
		sleep 2
	done
	echo "note: writeback still busy after 20 min, continuing"
}

echo "== preflight =="
echo "results   : $R"
[ -x ./frag_pin ] && [ -x ./fileprober ] && [ -x ./bindread ] || fail "run make first"
[ -f "$DATA_DIR/file$(printf %02d $((FILES - 1))).dat" ] || fail "victim set missing in $DATA_DIR (run scripts/run.sh once, or set DATA_DIR)"
$SUDO "$FRAG_CTL" status >/dev/null 2>&1 || fail "cannot run '$SUDO $FRAG_CTL' (see sudoers.example)"
[ "$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)" = "never" ] && \
	fail "global THP enabled=never: the arena cannot clear order-9/10 blocks"

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
	echo "creating a ${BACKUP_GB}GB backup tree in $BACKUP_DIR (once)..."
	mkdir -p "$BACKUP_DIR"
	n=$((BACKUP_GB * 2))
	for i in $(seq -w 1 "$n"); do
		dd if=/dev/zero of="$BACKUP_DIR/b$i.dat" bs=1M count=512 status=none
	done
	wait_writeback
fi

reader_cmd() {
	case "$1" in
	fp)		echo "$TASKSET ./fileprober --mode warm --dir $DATA_DIR --total-gb $REAL_GB --file-gb $FILE_GB --node $NODE" ;;
	bind1M)		echo "./bindread --node $NODE --bs 1M $VSPACE" ;;
	bind4K)		echo "./bindread --node $NODE --bs 4k $VSPACE" ;;
	dd)		echo "for f in $VSPACE; do dd if=\$f of=/dev/null bs=1M 2>/dev/null; done" ;;
	fio)		echo "$TASKSET fio --name=s --rw=read --bs=1M --numjobs=1 --filename=$VFILES --ioengine=psync --direct=0 --invalidate=0" ;;
	tar)		echo "tar cf - -C $BACKUP_DIR . | cat > /dev/null" ;;
	tar1M)		echo "tar -b 2048 cf - -C $BACKUP_DIR . | cat > /dev/null" ;;
	*)		echo "" ;;
	esac
}

echo; echo "== arena =="
[ "$H2_SAVED" = "never" ] && $SUDO "$FRAG_CTL" thp2048 inherit >/dev/null
echo boot > "$R/phase"
./scripts/sampler.sh "$R/sampler.csv" "$R/phase" "$NODE" &
SAMP=$!
drop_all	# BEFORE the arena: dropping a big cache afterwards frees large blocks and undoes the fragmentation
mark pinup
$SUDO "$FRAG_CTL" pin down >/dev/null 2>&1
before=$(wc -l < "$PIN_LOG" 2>/dev/null || echo 0)
$SUDO "$FRAG_CTL" pin up "$RESERVE_MB" "$PIN_KB" || fail "frag_pin launch failed"
ready=""
for _ in $(seq 1 1800); do
	ready=$(tail -n +$((before + 1)) "$PIN_LOG" 2>/dev/null | grep "^FRAG_READY" | tail -1)
	[ -n "$ready" ] && break
	tail -n +$((before + 1)) "$PIN_LOG" 2>/dev/null | grep -q "^FRAG_FAIL" && break
	sleep 1
done
[ -n "$ready" ] || fail "arena build failed, see $PIN_LOG"
echo "$ready"

echo; echo "== windows ($WIN s each): $PUMP_READERS =="
for name in $PUMP_READERS; do
	cmd=$(reader_cmd "$name")
	[ -n "$cmd" ] || { echo "unknown reader $name, skipped"; continue; }
	drop_all
	mark "$name"
	t0=$(date +%s)
	timeout "$WIN" bash -c "$cmd" > /dev/null 2>&1
	el=$(( $(date +%s) - t0 ))
	# a reader that dies immediately (bad argument, missing file, ...) is
	# silent here: its output goes to /dev/null.  Catch it by wall time.
	[ "$el" -lt $((WIN / 2)) ] && echo "  WARNING: $name returned after ${el}s (expected ~${WIN}s) - the reader probably failed; rerun its command without redirection"
	pkill -x tar 2>/dev/null
	echo "  $name done: $(awk '$1=="Node" && $2=="0," && $4=="Normal"{printf "o7=%s o8=%s o9=%s o10=%s",$12,$13,$14,$15}' /proc/buddyinfo)"
done
mark done

echo; echo "== kswapd activity per window =="
python3 ./scripts/report-pump.py "$R" $PUMP_READERS

echo; echo "PUMP-TEST-DONE $R"
