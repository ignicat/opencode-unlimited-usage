#!/usr/bin/env bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

OUC_BRAND="opencode-unlimited"
OUC_NS="ouc"
OUC_VETH_H="veth-ouc-h"
OUC_VETH_N="veth-ouc-n"
OUC_RUN_DIR="/run/$OUC_BRAND"
OUC_WARP_RUN="$OUC_RUN_DIR/warp"
OUC_WARP_STATE="/var/lib/$OUC_BRAND/warp"
OUC_LOG_DIR="/var/log/$OUC_BRAND"
OUC_LIBEXEC="/usr/local/libexec/$OUC_BRAND"
OUC_ROOT_BIN="/usr/local/bin/ouc-root"
OUC_USER_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/$OUC_BRAND"

ouc_find_bin() {
  local name="$1" p
  shift
  for p in "$@"; do
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  command -v "$name" 2>/dev/null && return 0
  for p in "/opt/$OUC_BRAND/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name" "/usr/sbin/$name" "$HOME/.local/bin/$name"; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

ouc_warp_bin() {
  ouc_find_bin warp-cli "${OUC_WARP_BIN:-}"
}

ouc_warp_svc_bin() {
  ouc_find_bin warp-svc "${OUC_WARP_SVC:-}"
}

ouc_w() {
  local wb
  wb=$(ouc_warp_bin) || return 1
  STATE_DIRECTORY="$OUC_WARP_STATE" RUNTIME_DIRECTORY="$OUC_WARP_RUN" "$wb" --accept-tos "$@" >/dev/null 2>&1 && return 0
  STATE_DIRECTORY="$OUC_WARP_STATE" RUNTIME_DIRECTORY="$OUC_WARP_RUN" "$wb" "$@" >/dev/null 2>&1
}

ouc_wo() {
  local wb
  wb=$(ouc_warp_bin) || return 1
  STATE_DIRECTORY="$OUC_WARP_STATE" RUNTIME_DIRECTORY="$OUC_WARP_RUN" "$wb" --accept-tos "$@" 2>/dev/null && return 0
  STATE_DIRECTORY="$OUC_WARP_STATE" RUNTIME_DIRECTORY="$OUC_WARP_RUN" "$wb" "$@" 2>/dev/null
}

ouc_trim_log() {
  local f="$1" max="${2:-1048576}" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$max" ]; then
    tail -c 262144 "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null || true
  fi
}

ouc_blacklist_add() {
  local state_file="$1" addr="$2"
  [ -n "$addr" ] || return 0
  mkdir -p "$(dirname "$state_file")"
  python3 - "$state_file" "$addr" <<'PY' 2>/dev/null
import json, os, sys
def m64(a):
    return ":".join(a.split(":")[:4])
p, addr = sys.argv[1], sys.argv[2]
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {"blacklist": [], "offset": 0, "last_hop": 0, "hops": 0, "current": ""}
m = m64(addr)
if m:
    d["blacklist"] = [x for x in d.get("blacklist", []) if x and m64(x) != m] + [m]
    d["blacklist"] = d["blacklist"][-200:]
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, p)
PY
}
