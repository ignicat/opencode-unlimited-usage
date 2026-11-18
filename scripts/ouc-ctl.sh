#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/ouc-common.sh"

case "${1:-status}" in
  start)
    sudo "$OUC_ROOT_BIN" start
    if flock -n "$OUC_USER_DATA/guard/guard.lock" true 2>/dev/null; then
      mkdir -p "$OUC_USER_DATA/guard"
      setsid bash "$SCRIPT_DIR/zen-guard.sh" </dev/null >/dev/null 2>&1 &
    fi
    ;;
  stop)
    if [ -f "$OUC_USER_DATA/guard/guard.pid" ]; then
      kill -TERM "$(cat "$OUC_USER_DATA/guard/guard.pid" 2>/dev/null)" 2>/dev/null || true
    fi
    sudo "$OUC_ROOT_BIN" stop
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    sudo "$OUC_ROOT_BIN" status
    if [ -f "$OUC_USER_DATA/guard/guard.lock" ] && ! flock -n "$OUC_USER_DATA/guard/guard.lock" true 2>/dev/null; then
      echo "zen_guard=up"
    else
      echo "zen_guard=down"
    fi
    ;;
  *)
    echo "usage: opencode-unlimited-ctl {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
