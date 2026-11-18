#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)
if [ -d /usr/local/libexec/opencode-unlimited ] && [ -O /usr/local/libexec/opencode-unlimited ]; then
  LIBEXEC="/usr/local/libexec/opencode-unlimited"
else
  LIBEXEC="$SCRIPT_DIR"
fi

. "$LIBEXEC/ouc-common.sh"
. "$LIBEXEC/ouc-firewall.sh"

mkdir -p "$OUC_RUN_DIR" "$OUC_LOG_DIR"
exec 8>"$OUC_RUN_DIR/keeper.run.lock"
flock -n 8 || exit 0
echo $$ > "$OUC_RUN_DIR/keeper.pid"

ensure_connected() {
  ouc_wo status | head -n1 | grep -q Connected && return 0
  ouc_w connect
  sleep 4
  ouc_wo status | head -n1 | grep -q Connected && return 0
  ouc_w disconnect
  ouc_w registration delete
  ouc_w registration new || return 1
  ouc_w mode warp
  ouc_w connect
  sleep 5
  ouc_wo status | head -n1 | grep -q Connected
}

for _ in 1 2 3 4 5 6; do
  ouc_w status && break
  sleep 5
done

while true; do
  if (
    flock -n 9 || exit 2
    ouc_w mode warp
    ensure_connected || true
    ouc_fw_ns_guard "$OUC_NS" "$OUC_VETH_N" || true
  ) 9>"$OUC_RUN_DIR/warp.lock"; then
    :
  fi
  ouc_trim_log "$OUC_LOG_DIR/keeper.log"
  ouc_trim_log "$OUC_LOG_DIR/warp-svc.log"
  sleep 45
done
