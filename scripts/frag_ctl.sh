#!/usr/bin/env bash
# frag_ctl.sh - the two privileged operations of this repro.
#
#   frag_ctl.sh pin up [reserve_mb] [pin_kb]   launch frag_pin (detached)
#   frag_ctl.sh pin down                       stop it
#   frag_ctl.sh thp2048 <always|inherit|madvise|never>
#   frag_ctl.sh status                         knobs + node0 Normal buddy
#
# Needs root: frag_pin mlocks tens of GB (CAP_IPC_LOCK).  Either run this
# script as root, whitelist it in sudoers (see sudoers.example), or give
# the frag_pin binary the capability instead:
#   sudo setcap cap_ipc_lock+ep /path/to/frag_pin
set -u

DIR=$(cd "$(dirname "$0")/.." && pwd)
THP2048=/sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled

case "${1:-X}" in
"thp2048")
	echo "$2" > "$THP2048" || exit 1
	cat "$THP2048"
	;;
"pin")
	case "${2:-X}" in
	"up")
		pkill -TERM -f "$DIR/frag_pin" 2>/dev/null
		sleep 1
		setsid nohup "$DIR/frag_pin" --node "${NODE:-0}" \
			--reserve-mb "${3:-64}" --pin-kb "${4:-1536}" \
			>> "$DIR/frag_pin.log" 2>&1 &
		echo "pin launching pid=$! log=$DIR/frag_pin.log"
		;;
	"down")
		if pkill -TERM -f "$DIR/frag_pin"; then
			echo "pin stopping"
		else
			echo "pin not running"
		fi
		;;
	*) echo "usage: frag_ctl.sh pin up [reserve_mb] [pin_kb] | pin down" >&2; exit 2;;
	esac
	;;
"status")
	echo "hugepages-2048kB: $(cat "$THP2048")"
	echo "global thp enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
	grep "Node 0, zone   Normal" /proc/buddyinfo || true
	;;
*)
	echo "usage: frag_ctl.sh pin up [reserve_mb] [pin_kb] | pin down | thp2048 <mode> | status" >&2
	exit 2
	;;
esac
