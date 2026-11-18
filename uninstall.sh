#!/usr/bin/env bash
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
LIBEXEC="/usr/local/libexec/$BRAND"
ROOT_BIN="/usr/local/bin/ouc-root"

ok() { echo -e "  \e[32m✓\e[0m $*"; }

echo ""
echo "  removing Opencode Unlimited…"
echo ""

if [ -f "$DEST/guard/guard.pid" ]; then
  kill -TERM "$(cat "$DEST/guard/guard.pid" 2>/dev/null)" 2>/dev/null || true
  ok "zen-guard stopped"
fi

if [ -x "$ROOT_BIN" ]; then
  sudo "$ROOT_BIN" stop >/dev/null 2>&1 && ok "isolated netns & keeper stopped"
fi

sudo rm -f "/etc/sudoers.d/$BRAND" && ok "sudoers removed"
sudo rm -rf "$ROOT_BIN" "$LIBEXEC" "/opt/$BRAND" "/var/lib/$BRAND" "/var/log/$BRAND" "/run/$BRAND" && ok "root helpers and isolated state removed"

if [ -x "$DEST/real-opencode" ]; then
  rm -f "$HOME/.local/bin/opencode"
  mv -f "$DEST/real-opencode" "$HOME/.local/bin/opencode"
  chmod +x "$HOME/.local/bin/opencode"
  ok "opencode restored"
elif [ -x "$HOME/.opencode/bin/opencode" ]; then
  rm -f "$HOME/.local/bin/opencode"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$HOME/.opencode/bin/opencode" > "$HOME/.local/bin/opencode"
  chmod +x "$HOME/.local/bin/opencode"
  ok "opencode entry restored"
fi

rm -f "$HOME/.local/bin/${BRAND}-hop" "$HOME/.local/bin/${BRAND}-doctor" "$HOME/.local/bin/${BRAND}-ctl"
rm -rf "$DEST" && ok "user scripts and guard state removed"

echo ""
ok "done. opencode sessions and system network untouched."
echo ""
