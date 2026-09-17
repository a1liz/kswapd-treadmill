#!/usr/bin/env bash
# sampler.sh <out.csv> <phasefile> [node] - 1Hz system sampler.
#
# Every column exists to answer one question:
#   free0_mb / o5..o10    is memory actually tight, or just fragmented?
#                         (free blocks per buddy order in the target zone)
#   d_pgscan_kswapd       is kswapd scanning?  (the treadmill)
#   d_pgsteal_kswapd      how much did kswapd take, per second
#   d_pgsteal_file        of which file pages (the victim's data)
#   d_refault_file        the victim re-faulting what was evicted
#   d_compact_stall       high-order allocations that hit the slow path
#   d_pgsteal_direct      direct reclaim, i.e. NOT kswapd doing it
#   file_pages_mb         absolute page cache size - the ground truth for
#                         "is the cache actually shrinking right now?"
#   kswapd0_jiffies       kswapd CPU time (delta / CLK_TCK = CPU seconds)
#   oom_kill / pswpout    must stay flat: no memory pressure, no swap
set -u
# Ignore TERM/INT/HUP: the sampler kept getting killed at window boundaries
# by a stray signal from the orchestrator's `timeout` windows, silently losing
# the kernel side of whole runs.  Cleanup must use SIGKILL (kill -KILL).
trap '' TERM INT HUP
OUT=$1
PHASE=$2
NODE=${3:-0}
NVM=/sys/devices/system/node/node$NODE/vmstat

nv() { awk -v k="$1" '$1==k{print $2}' "$NVM"; }
gv() { awk -v k="$1" '$1==k{print $2}' /proc/vmstat; }

# prime the counters so row 1 is a real delta, not a boot-lifetime total
p_scan=$(nv pgscan_kswapd); p_sk=$(nv pgsteal_kswapd); p_steal=$(nv pgsteal_file)
p_ref=$(nv workingset_refault_file); p_sd=$(nv pgsteal_direct); p_scd=$(nv pgscan_direct)
p_cs=$(gv compact_stall); p_so=$(gv pswpout)

echo "epoch phase free0_mb o5 o6 o7 o8 o9 o10 d_pgscan_kswapd d_pgsteal_kswapd d_pgsteal_file d_refault_file d_compact_stall kswapd0_jiffies oom_kill d_pswpout d_pgsteal_direct d_pgscan_direct file_pages_mb" > "$OUT"
while :; do
	ts=$(date +%s)
	phase=$(cat "$PHASE" 2>/dev/null || echo NA)
	free0=$(( $(nv nr_free_pages) * 4 / 1024 ))
	read o5 o6 o7 o8 o9 o10 <<<"$(awk -v n="$NODE," '$1=="Node" && $2==n && $4=="Normal" {print $10, $11, $12, $13, $14, $15}' /proc/buddyinfo)"
	scan=$(nv pgscan_kswapd); sk=$(nv pgsteal_kswapd); steal=$(nv pgsteal_file)
	ref=$(nv workingset_refault_file); cs=$(gv compact_stall)
	sd=$(nv pgsteal_direct); scd=$(nv pgscan_direct)
	so=$(gv pswpout); oom=$(gv oom_kill)
	for v in scan sk steal ref cs sd scd so oom; do
		eval "[ -n \"\$$v\" ] || $v=0"
	done
	famb=$(( $(gv nr_file_pages) * 4 / 1024 ))
	pid=$(pgrep -x "kswapd$NODE" | head -1)
	jif=0
	[ -n "$pid" ] && jif=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0)
	echo "$ts $phase $free0 ${o5:-0} ${o6:-0} ${o7:-0} ${o8:-0} ${o9:-0} ${o10:-0} $((scan-p_scan)) $((sk-p_sk)) $((steal-p_steal)) $((ref-p_ref)) $((cs-p_cs)) $jif $oom $((so-p_so)) $((sd-p_sd)) $((scd-p_scd)) $famb" >> "$OUT"
	p_scan=$scan; p_sk=$sk; p_steal=$steal; p_ref=$ref; p_cs=$cs
	p_sd=$sd; p_scd=$scd; p_so=$so
	sleep 1
done
