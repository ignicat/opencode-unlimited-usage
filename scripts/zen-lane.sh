#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/ouc-common.sh"

REAL="${OUC_REAL_BIN:-$HOME/.opencode/bin/opencode}"
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
SHIM_PATH=$(readlink -f "$HOME/.local/bin/opencode" 2>/dev/null || true)

if [ ! -x "$REAL" ] || [ "$(readlink -f "$REAL" 2>/dev/null || true)" = "$SELF" ] || [ "$(readlink -f "$REAL" 2>/dev/null || true)" = "$SHIM_PATH" ]; then
  REAL=""
  for c in "$HOME/.opencode/bin/opencode" "$OUC_USER_DATA/real-opencode" "$HOME/.local/bin/opencode" /usr/local/bin/opencode /usr/bin/opencode /usr/sbin/opencode; do
    RC=$(readlink -f "$c" 2>/dev/null || echo "$c")
    if [ -x "$c" ] && [ "$RC" != "$SELF" ] && [ "$RC" != "$SHIM_PATH" ]; then
      REAL="$c"
      break
    fi
  done
fi
[ -x "$REAL" ] || { echo "opencode binary not found" >&2; exit 1; }

[ "${OUC_DIRECT:-0}" = 1 ] && exec "$REAL" "$@"

sudo "$OUC_ROOT_BIN" start >/dev/null 2>&1 || {
  echo "failed to start isolated warp lane" >&2
  exit 1
}

GUARD_DIR="$OUC_USER_DATA/guard"
mkdir -p "$GUARD_DIR"
if flock -n "$GUARD_DIR/guard.lock" true 2>/dev/null; then
  setsid bash "$SCRIPT_DIR/zen-guard.sh" </dev/null >/dev/null 2>&1 &
fi

ENVF=$(mktemp "${TMPDIR:-/tmp}/ouc-env.XXXXXX")
chmod 0600 "$ENVF"
env -0 > "$ENVF"

exec sudo "$OUC_ROOT_BIN" enter "$ENVF" "$REAL" "$@"
