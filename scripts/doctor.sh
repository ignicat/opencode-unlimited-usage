#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/ouc-common.sh"

ok()   { echo -e "  \e[32m✓\e[0m $*"; }
warn() { echo -e "  \e[33m!\e[0m $*"; }
bad()  { echo -e "  \e[31m✗\e[0m $*"; }

echo ""
echo "  ============================="
echo "  Opencode Unlimited - doctor"
echo "  ============================="
echo ""

ST_RAW=$(sudo "$OUC_ROOT_BIN" status 2>/dev/null || true)
get_kv() { printf '%s\n' "$ST_RAW" | awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1)}'; }

NS=$(get_kv netns)
WSVC=$(get_kv warp_svc)
KEEP=$(get_kv keeper)
LG=$(get_kv leakguard)
WST=$(get_kv warp_status)
OUC_V6=$(get_kv ouc_v6)

[ "$NS" = up ]   && ok "isolated netns ($OUC_NS)" || bad "isolated netns down - run opencode-unlimited-ctl start"
[ "$WSVC" = up ] && ok "warp-svc (isolated)"    || bad "warp-svc down - run opencode-unlimited-ctl start"
[ "$KEEP" = up ] && ok "keeper daemon"          || bad "keeper down - run opencode-unlimited-ctl start"
[ "$LG" = up ]   && ok "kill-switch inside $OUC_NS" || bad "kill-switch missing inside $OUC_NS"

echo "$WST" | grep -q Connected \
  && ok "warp tunnel: connected" \
  || bad "warp tunnel: ${WST:-unknown}"

if [ -n "$OUC_V6" ]; then
  FIRST=$(echo "$OUC_V6" | cut -d: -f1-4)
  case "$OUC_V6" in
    2606:*|2a09:*) ok "opencode egress (warp): ${FIRST}::/64" ;;
    *) bad "opencode egress NOT warp ($OUC_V6)" ;;
  esac
else
  bad "no egress inside $OUC_NS (tunnel down or kill-switch blocking)"
fi

HOST_V4=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)
HOST_V6=$(curl -fsS -m 5 https://api64.ipify.org 2>/dev/null || true)
if [ -n "$HOST_V6" ] && [ "$HOST_V6" = "$OUC_V6" ]; then
  warn "host v6 matches ouc v6 (host may have another VPN/WARP active)"
else
  ok "host network untouched (v4=${HOST_V4:-n/a}, v6=${HOST_V6:-n/a})"
fi

if [ -f /etc/resolv.conf ] && grep -qi "cloudflare-warp" /etc/resolv.conf 2>/dev/null; then
  warn "host /etc/resolv.conf mentions cloudflare-warp"
else
  ok "host /etc/resolv.conf untouched"
fi

GUARD_LOCK="$OUC_USER_DATA/guard/guard.lock"
if [ -f "$GUARD_LOCK" ] && ! flock -n "$GUARD_LOCK" true 2>/dev/null; then
  ok "zen-guard watcher running"
else
  warn "zen-guard not running (auto-starts on opencode launch)"
fi

if [ -f "$OUC_USER_DATA/guard/state.json" ]; then
  python3 - "$OUC_USER_DATA/guard/state.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    bl = [x for x in d.get("blacklist", []) if x]
    print(f"    rotations: {d.get('hops', 0)} · blacklisted /64s: {len(bl)}")
except Exception as e:
    print(f"    guard state unreadable: {e}")
PY
fi

if [ -f "$HOME/.local/bin/opencode" ] && grep -q "zen-lane" "$HOME/.local/bin/opencode" 2>/dev/null; then
  ok "opencode entry -> zen-lane"
else
  warn "opencode entry does not point at zen-lane"
fi

echo ""
