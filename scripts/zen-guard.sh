#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/ouc-common.sh"

LOGF="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/log/opencode.log"
STATE_DIR="$OUC_USER_DATA/guard"
STATE="$STATE_DIR/state.json"
GUARD_LOG="$STATE_DIR/guard.log"
COOLDOWN=75
MAX_HOP_TRIES=8

mkdir -p "$STATE_DIR"
exec 7>"$STATE_DIR/guard.lock"
flock -n 7 || exit 0
echo $$ > "$STATE_DIR/guard.pid"

glog() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$GUARD_LOG"
  ouc_trim_log "$GUARD_LOG"
}

state_get() {
  python3 - "$STATE" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    d = {"blacklist": [], "offset": 0, "last_hop": 0, "hops": 0, "current": ""}
print(d.get(sys.argv[2], ""))
PY
}

state_set() {
  python3 - "$STATE" "$1" "$2" <<'PY' 2>/dev/null
import json, os, sys
p, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {"blacklist": [], "offset": 0, "last_hop": 0, "hops": 0, "current": ""}
if k in ("offset", "last_hop", "hops"):
    try:
        v = int(v)
    except Exception:
        pass
d[k] = v
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, p)
PY
}

is_burnt() {
  python3 - "$STATE" "$1" <<'PY' 2>/dev/null
import json, sys
def m64(a):
    return ":".join(a.split(":")[:4])
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    raise SystemExit(1)
m = m64(sys.argv[2])
raise SystemExit(0 if m and any(x and m64(x) == m for x in d.get("blacklist", [])) else 1)
PY
}

if [ ! -f "$STATE" ]; then
  OFF=0
  [ -f "$LOGF" ] && OFF=$(wc -c < "$LOGF" 2>/dev/null || echo 0)
  printf '{"blacklist":[],"offset":%s,"last_hop":0,"hops":0,"current":""}\n' "$OFF" > "$STATE"
fi

glog "zen-guard up (cooldown ${COOLDOWN}s, isolated netns mode)"

while true; do
  sleep 20
  [ -f "$OUC_RUN_DIR/net.env" ] || continue
  [ -f "$LOGF" ] || continue

  SIZE=$(wc -c < "$LOGF" 2>/dev/null || echo 0)
  OFF=$(state_get offset)
  OFF=${OFF:-0}
  [ "$SIZE" -lt "$OFF" ] && OFF=0
  NEWBYTES=$((SIZE - OFF))
  WALL=0
  if [ "$NEWBYTES" -gt 0 ] && [ "$NEWBYTES" -lt 50000000 ]; then
    if tail -c +"$((OFF + 1))" "$LOGF" 2>/dev/null | grep -aq "QuotaExceeded"; then
      WALL=1
    fi
  fi
  state_set offset "$SIZE"

  NOW=$(date +%s)
  LASTHOP=$(state_get last_hop)
  LASTHOP=${LASTHOP:-0}
  AGE=$((NOW - LASTHOP))

  if [ "$WALL" = 1 ] && [ "$AGE" -ge "$COOLDOWN" ]; then
    OLD=$(sudo -n "$OUC_ROOT_BIN" v6 2>/dev/null || true)
    glog "wall detected - rotating (was: ${OLD:-unknown})"
    [ -n "$OLD" ] && ouc_blacklist_add "$STATE" "$OLD"
    NEW=""
    TRY=0
    while [ "$TRY" -lt "$MAX_HOP_TRIES" ]; do
      TRY=$((TRY + 1))
      V=$(sudo -n "$OUC_ROOT_BIN" hop 2>/dev/null || true)
      if [ -z "$V" ]; then
        glog "try $TRY: tunnel repair failed"
        continue
      fi
      if is_burnt "$V"; then
        glog "try $TRY: cloudflare returned a blacklisted /64 ($V) - retrying"
        continue
      fi
      NEW="$V"
      break
    done
    if [ -z "$NEW" ]; then
      glog "everything blacklisted - recycling oldest block"
      V=$(sudo -n "$OUC_ROOT_BIN" hop 2>/dev/null || true)
      [ -n "$V" ] && NEW="$V"
    fi
    if [ -n "$NEW" ]; then
      state_set last_hop "$NOW"
      state_set current "$NEW"
      H=$(state_get hops)
      H=${H:-0}
      H=$((H + 1))
      state_set hops "$H"
      glog "rotated #$H: ${OLD:-?} -> $NEW"
    else
      state_set last_hop "$NOW"
      glog "rotation failed - keeper will keep tunnel alive, retrying next tick"
    fi
  elif [ "$WALL" = 1 ]; then
    glog "wall seen but in cooldown (${AGE}s < ${COOLDOWN}s)"
  fi
done
