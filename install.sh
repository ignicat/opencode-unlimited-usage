#!/usr/bin/env bash
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

BRAND="opencode-unlimited"
DEST="$HOME/.local/share/$BRAND"
LIBEXEC="/usr/local/libexec/$BRAND"
ROOT_BIN="/usr/local/bin/ouc-root"
OPT_BIN="/opt/$BRAND/bin"
SHIM="$HOME/.local/bin/opencode"
SUDOERS_FILE="/etc/sudoers.d/$BRAND"
RAW="https://raw.githubusercontent.com/ignicat/opencode-unlimited-usage/main"

say() { echo -e "  $*"; }
ok()  { echo -e "  \e[32m✓\e[0m $*"; }
bad() { echo -e "  \e[31m✗\e[0m $*"; }
die() { bad "$*"; exit 1; }

SRC=""
[ -n "${BASH_SOURCE[0]:-}" ] && SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
TMP_SRC=""

echo ""
echo "  ============================="
echo "  Opencode Unlimited (Isolated)"
echo "  ============================="
echo ""

[ "$(id -u)" = 0 ] && die "run me as your normal user, not root"
[ -e /dev/net/tun ] || die "/dev/net/tun missing"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) DEB_ARCH=amd64 ;;
  aarch64|arm64) DEB_ARCH=arm64 ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

if ! sudo -n true 2>/dev/null; then
  if bash -c 'sudo -v </dev/tty' 2>/dev/null; then
    ok "sudo authenticated"
  elif [ ! -t 0 ]; then
    sudo -S -v >/dev/null 2>&1 || die "sudo failed"
    ok "sudo authenticated"
  else
    die "sudo failed"
  fi
fi

PKR=""
for pm in apt-get dnf yum pacman xbps-install apk zypper emerge; do
  if command -v "$pm" >/dev/null 2>&1; then
    PKR="$pm"
    break
  fi
done

pkg_install() {
  [ -n "$PKR" ] || return 1
  case "$PKR" in
    apt-get)
      sudo apt-get update -qq >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq "$@" >/dev/null 2>&1
      ;;
    dnf) sudo dnf -y install "$@" >/dev/null 2>&1 ;;
    yum) sudo yum -y install "$@" >/dev/null 2>&1 ;;
    pacman) sudo pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    xbps-install) sudo xbps-install -Sy "$@" >/dev/null 2>&1 ;;
    apk) sudo apk add --no-cache "$@" >/dev/null 2>&1 ;;
    zypper) sudo zypper -n install "$@" >/dev/null 2>&1 ;;
    emerge) sudo emerge -q "$@" >/dev/null 2>&1 ;;
  esac
}

ensure_deps() {
  local need=()
  command -v curl    >/dev/null 2>&1 || need+=(curl)
  command -v python3 >/dev/null 2>&1 || need+=(python3)
  command -v ip      >/dev/null 2>&1 || need+=(ip)
  command -v unshare >/dev/null 2>&1 || need+=(util)
  command -v nsenter >/dev/null 2>&1 || need+=(util)
  command -v flock   >/dev/null 2>&1 || need+=(util)
  if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
    need+=(fw)
  fi
  [ "${#need[@]}" -eq 0 ] && return 0

  say "installing missing base tools"
  local pkgs=() item
  for item in "${need[@]}"; do
    case "$PKR:$item" in
      *:curl) pkgs+=(curl) ;;
      *:python3) pkgs+=(python3) ;;
      pacman:python3) pkgs+=(python) ;;
      emerge:curl) pkgs+=(net-misc/curl) ;;
      emerge:python3) pkgs+=(dev-lang/python) ;;
      apt-get:ip|pacman:ip|xbps-install:ip|apk:ip|zypper:ip) pkgs+=(iproute2) ;;
      dnf:ip|yum:ip) pkgs+=(iproute) ;;
      emerge:ip) pkgs+=(sys-apps/iproute2) ;;
      emerge:util) pkgs+=(sys-apps/util-linux) ;;
      *:util) pkgs+=(util-linux) ;;
      emerge:fw) pkgs+=(net-firewall/iptables) ;;
      *:fw) pkgs+=(iptables) ;;
    esac
  done
  if [ "${#pkgs[@]}" -gt 0 ]; then
    pkg_install "${pkgs[@]}" || true
  fi

  for cmd in curl python3 ip unshare nsenter flock; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
  if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
    die "missing iptables or nft"
  fi
}

ensure_deps
ok "base dependencies ready"

if [ -z "$SRC" ] || [ ! -f "$SRC/scripts/ouc-root.sh" ]; then
  say "fetching scripts from github"
  TMP_SRC=$(mktemp -d)
  trap 'rm -rf "$TMP_SRC"' EXIT
  mkdir -p "$TMP_SRC/scripts"
  for f in ouc-common.sh ouc-firewall.sh ouc-root.sh warp-keeper.sh zen-lane.sh zen-guard.sh zen-hop.sh doctor.sh ouc-ctl.sh; do
    curl -fsSL "$RAW/scripts/$f" -o "$TMP_SRC/scripts/$f" || die "failed to fetch $f"
  done
  SRC="$TMP_SRC"
fi

OC_REAL=""
if [ -x "$HOME/.opencode/bin/opencode" ]; then
  OC_REAL="$HOME/.opencode/bin/opencode"
elif [ -x "$DEST/real-opencode" ]; then
  OC_REAL="$DEST/real-opencode"
elif command -v opencode >/dev/null 2>&1; then
  C=$(command -v opencode)
  grep -q "zen-lane" "$C" 2>/dev/null || OC_REAL="$C"
fi

if [ -z "$OC_REAL" ]; then
  say "opencode CLI not found - installing"
  if curl -fsSL https://opencode.ai/install 2>/dev/null | bash >/dev/null 2>&1; then
    [ -x "$HOME/.opencode/bin/opencode" ] && OC_REAL="$HOME/.opencode/bin/opencode"
  fi
  [ -n "$OC_REAL" ] || die "opencode install failed"
  ok "opencode installed"
else
  ok "opencode found: $OC_REAL"
fi

find_warp_pair() {
  WARP_CLI=""
  WARP_SVC=""
  for p in "$OPT_BIN/warp-cli" "$(command -v warp-cli 2>/dev/null || true)" /usr/bin/warp-cli /usr/sbin/warp-cli /usr/local/bin/warp-cli "$HOME/.local/bin/warp-cli"; do
    [ -n "$p" ] && [ -x "$p" ] && { WARP_CLI="$p"; break; }
  done
  for p in "$OPT_BIN/warp-svc" "$(command -v warp-svc 2>/dev/null || true)" /usr/bin/warp-svc /usr/sbin/warp-svc /usr/local/bin/warp-svc; do
    [ -n "$p" ] && [ -x "$p" ] && { WARP_SVC="$p"; break; }
  done
}

install_warp_deb() {
  say "fetching cloudflare-warp binary package ($DEB_ARCH)"
  local tmpd deb_url
  tmpd=$(mktemp -d)
  deb_url=$(curl -fsSL "https://pkg.cloudflareclient.com/dists/bookworm/main/binary-${DEB_ARCH}/Packages.gz" 2>/dev/null | python3 -c '
import gzip, sys
data = gzip.decompress(sys.stdin.buffer.read()).decode("utf-8", "ignore")
cur_pkg = ""
for line in data.splitlines():
    if line.startswith("Package:"):
        cur_pkg = line.split(":", 1)[1].strip()
    elif cur_pkg == "cloudflare-warp" and line.startswith("Filename:"):
        print("https://pkg.cloudflareclient.com/" + line.split(":", 1)[1].strip())
        break
' 2>/dev/null)
  [ -n "$deb_url" ] || { rm -rf "$tmpd"; return 1; }
  curl -fsSL "$deb_url" -o "$tmpd/warp.deb" || { rm -rf "$tmpd"; return 1; }
  python3 - "$tmpd/warp.deb" "$tmpd" <<'PY' || { rm -rf "$tmpd"; return 1; }
import os, sys
deb, out = sys.argv[1], sys.argv[2]
with open(deb, "rb") as f:
    if f.read(8) != b"!<arch>\n":
        raise SystemExit(1)
    while True:
        hdr = f.read(60)
        if len(hdr) < 60:
            break
        name = hdr[:16].decode("ascii", "ignore").strip().rstrip("/")
        size = int(hdr[48:58].decode("ascii", "ignore").strip())
        body = f.read(size)
        if size % 2 == 1:
            f.read(1)
        if name.startswith("data.tar"):
            with open(os.path.join(out, name), "wb") as df:
                df.write(body)
PY
  local archive=""
  for f in "$tmpd"/data.tar.*; do
    [ -f "$f" ] && archive="$f" && break
  done
  [ -n "$archive" ] || { rm -rf "$tmpd"; return 1; }
  mkdir -p "$tmpd/root"
  tar -xf "$archive" -C "$tmpd/root" 2>/dev/null || python3 - "$archive" "$tmpd/root" <<'PY' || { rm -rf "$tmpd"; return 1; }
import sys, tarfile
with tarfile.open(sys.argv[1], "r:*") as tf:
    tf.extractall(sys.argv[2])
PY
  local b_cli b_svc
  b_cli=$(find "$tmpd/root" -type f -name warp-cli | head -n1)
  b_svc=$(find "$tmpd/root" -type f -name warp-svc | head -n1)
  [ -n "$b_cli" ] && [ -n "$b_svc" ] || { rm -rf "$tmpd"; return 1; }
  sudo mkdir -p "$OPT_BIN"
  sudo install -m 755 "$b_cli" "$OPT_BIN/warp-cli"
  sudo install -m 755 "$b_svc" "$OPT_BIN/warp-svc"
  rm -rf "$tmpd"
}

ensure_warp_libs() {
  [ -n "$WARP_SVC" ] || return 0
  local miss
  miss=$(ldd "$WARP_SVC" 2>/dev/null | grep "not found" || true)
  [ -z "$miss" ] && return 0
  say "installing runtime libraries for warp-svc"
  local libs=()
  echo "$miss" | grep -q "libnss3"    && libs+=(nss)
  echo "$miss" | grep -q "libnspr4"   && libs+=(nspr)
  echo "$miss" | grep -q "libdbus-1"  && libs+=(dbus)
  echo "$miss" | grep -q "libtss2"    && libs+=(tss2)
  local pkgs=() l
  for l in "${libs[@]}"; do
    case "$PKR:$l" in
      apt-get:nss)  pkgs+=(libnss3) ;;
      apt-get:nspr) pkgs+=(libnspr4) ;;
      apt-get:dbus) pkgs+=(libdbus-1-3) ;;
      apt-get:tss2) pkgs+=(libtss2-esys-3.0.2-0t64 libtss2-mu-4.0.1-0 libtss2-sys1 libtss2-tctildr0) ;;
      xbps-install:dbus) pkgs+=(dbus-libs) ;;
      xbps-install:tss2) pkgs+=(tpm2-tss) ;;
      dnf:tss2|yum:tss2|pacman:tss2|zypper:tss2) pkgs+=(tpm2-tss) ;;
      dnf:dbus|yum:dbus|pacman:dbus|zypper:dbus) pkgs+=(dbus-libs) ;;
      *:nss)  pkgs+=(nss) ;;
      *:nspr) pkgs+=(nspr) ;;
    esac
  done
  [ "${#pkgs[@]}" -gt 0 ] && pkg_install "${pkgs[@]}" || true
}

find_warp_pair
if [ -z "$WARP_CLI" ] || [ -z "$WARP_SVC" ]; then
  if ldd --version 2>&1 | grep -qi musl; then
    die "musl libc detected and warp-cli/warp-svc not provided (official warp-svc binaries require glibc)"
  fi
  if [ "$PKR" = "apt-get" ]; then
    pkg_install curl gnupg lsb-release || true
    if command -v lsb_release >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1; then
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg 2>/dev/null \
        | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >/dev/null 2>&1 || true
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null 2>&1 || true
      pkg_install cloudflare-warp || true
    fi
  fi
  find_warp_pair
  if [ -z "$WARP_CLI" ] || [ -z "$WARP_SVC" ]; then
    install_warp_deb || die "cloudflare-warp installation failed"
    find_warp_pair
  fi
fi

ensure_warp_libs
[ -n "$WARP_CLI" ] && [ -n "$WARP_SVC" ] || die "warp-cli/warp-svc missing"
ok "warp ready: $WARP_CLI"

mkdir -p "$DEST/scripts" "$HOME/.local/bin"
cp "$SRC/scripts/"*.sh "$DEST/scripts/"
chmod +x "$DEST/scripts/"*.sh

sudo mkdir -p "$LIBEXEC"
sudo install -m 644 "$SRC/scripts/ouc-common.sh" "$LIBEXEC/ouc-common.sh"
sudo install -m 644 "$SRC/scripts/ouc-firewall.sh" "$LIBEXEC/ouc-firewall.sh"
sudo install -m 755 "$SRC/scripts/warp-keeper.sh" "$LIBEXEC/warp-keeper.sh"
sudo install -m 755 "$SRC/scripts/ouc-root.sh" "$ROOT_BIN"
sudo chown -R root:root "$LIBEXEC" "$ROOT_BIN"

ln -sf "$DEST/scripts/zen-hop.sh" "$HOME/.local/bin/${BRAND}-hop"
ln -sf "$DEST/scripts/doctor.sh"  "$HOME/.local/bin/${BRAND}-doctor"
ln -sf "$DEST/scripts/ouc-ctl.sh" "$HOME/.local/bin/${BRAND}-ctl"
ok "scripts installed"

SUDOERS_NEED="$USER ALL=(root) NOPASSWD: $ROOT_BIN *"
SUDOERS_NOW=$(sudo -n cat "$SUDOERS_FILE" 2>/dev/null || echo "")
if [ "$SUDOERS_NOW" != "$SUDOERS_NEED" ]; then
  printf '%s\n' "$SUDOERS_NEED" | sudo tee "$SUDOERS_FILE" >/dev/null
  sudo chmod 440 "$SUDOERS_FILE"
  sudo visudo -c >/dev/null 2>&1 || { sudo rm -f "$SUDOERS_FILE"; die "visudo validation failed"; }
fi
ok "sudoers configured ($ROOT_BIN)"

if [ "$OC_REAL" = "$SHIM" ]; then
  cp -L "$SHIM" "$DEST/real-opencode"
  chmod +x "$DEST/real-opencode"
  OC_REAL="$DEST/real-opencode"
fi
rm -f "$SHIM"
printf '#!/usr/bin/env bash\nexport OUC_REAL_BIN="%s"\nexec bash "%s/scripts/zen-lane.sh" "$@"\n' "$OC_REAL" "$DEST" > "$SHIM"
chmod +x "$SHIM"
ok "opencode shim installed"

say "starting isolated warp netns"
sudo "$ROOT_BIN" start || die "failed to start isolated warp netns"

mkdir -p "$DEST/guard"
if flock -n "$DEST/guard/guard.lock" true 2>/dev/null; then
  setsid bash "$DEST/scripts/zen-guard.sh" </dev/null >/dev/null 2>&1 &
fi

V6=$(sudo "$ROOT_BIN" v6 2>/dev/null || true)
case "$V6" in
  2606:*|2a09:*) ok "isolated opencode egress: $(echo "$V6" | cut -d: -f1-4)::/64" ;;
  *) bad "isolated egress not up yet - run ${BRAND}-doctor" ;;
esac

HOST_V4=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)
ok "host egress untouched (${HOST_V4:-offline})"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "PATH includes ~/.local/bin" ;;
  *) say "add to shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo ""
ok "DONE. run: opencode"
say "controls: ${BRAND}-doctor · ${BRAND}-hop · ${BRAND}-ctl {start|stop|restart|status}"
echo ""
