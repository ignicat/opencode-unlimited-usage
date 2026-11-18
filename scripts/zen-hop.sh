#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/ouc-common.sh"

STATE="$OUC_USER_DATA/guard/state.json"

sudo "$OUC_ROOT_BIN" start >/dev/null 2>&1 || { echo "failed to start isolated tunnel" >&2; exit 1; }

OLD_V6=$(sudo "$OUC_ROOT_BIN" v6 2>/dev/null || true)
echo "old /64: ${OLD_V6:-?}"
echo "-- rotating inside isolated ouc netns --"

if [ -n "$OLD_V6" ]; then
  ouc_blacklist_add "$STATE" "$OLD_V6"
fi

NEW_V6=$(sudo "$OUC_ROOT_BIN" hop 2>/dev/null || true)
echo "new /64: ${NEW_V6:-?}"

if [ -n "$NEW_V6" ] && [ "$NEW_V6" != "$OLD_V6" ]; then
  echo "== FRESH /64 - re-send your message =="
  exit 0
fi

echo "== rotation failed or same block returned - try again =="
exit 1
