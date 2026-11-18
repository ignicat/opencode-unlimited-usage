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

ouc_pick_subnet() {
  python3 - <<'PY'
import ipaddress, subprocess
used = []
out = subprocess.check_output(["ip", "-4", "route", "show"], text=True, stderr=subprocess.DEVNULL)
for line in out.splitlines():
    tok = line.split()[0] if line.split() else ""
    try:
        used.append(ipaddress.ip_network(tok, strict=False))
    except Exception:
        pass
cands = [
    ipaddress.ip_network("10.219.247.0/30"),
    ipaddress.ip_network("10.243.199.0/30"),
    ipaddress.ip_network("10.251.173.0/30"),
    ipaddress.ip_network("172.31.253.0/30"),
    ipaddress.ip_network("100.127.253.0/30"),
]
for i in range(200, 255):
    cands.append(ipaddress.ip_network(f"10.{i}.253.0/30"))
for c in cands:
    if not any(c.overlaps(u) for u in used):
        hosts = list(c.hosts())
        print(f"{hosts[0]} {hosts[1]}")
        raise SystemExit(0)
print("10.219.247.1 10.219.247.2")
PY
}

ouc_lock_alive() {
  local lf="$1"
  [ -f "$lf" ] || return 1
  if flock -n "$lf" true 2>/dev/null; then
    return 1
  fi
  return 0
}

ouc_netns_up() {
  if ip netns list 2>/dev/null | grep -qw "^$OUC_NS" && ip link show "$OUC_VETH_H" >/dev/null 2>&1 && [ -f "$OUC_RUN_DIR/net.env" ]; then
    . "$OUC_RUN_DIR/net.env"
    ouc_fw_host_up "$OUC_NS_IP" "$OUC_VETH_H"
    ouc_fw_ns_guard "$OUC_NS" "$OUC_VETH_N"
    return 0
  fi

  ip link del "$OUC_VETH_H" 2>/dev/null || true
  if ip netns list 2>/dev/null | grep -qw "^$OUC_NS"; then
    for p in $(ip netns pids "$OUC_NS" 2>/dev/null); do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    ip netns del "$OUC_NS" 2>/dev/null || true
  fi

  read -r OUC_HOST_IP OUC_NS_IP <<EOF
$(ouc_pick_subnet)
EOF
  printf 'OUC_HOST_IP=%s\nOUC_NS_IP=%s\n' "$OUC_HOST_IP" "$OUC_NS_IP" > "$OUC_RUN_DIR/net.env"

  ip netns add "$OUC_NS"
  ip -n "$OUC_NS" link set lo up
  ip link add "$OUC_VETH_H" type veth peer name "$OUC_VETH_N"
  ip link set "$OUC_VETH_N" netns "$OUC_NS"
  ip addr add "${OUC_HOST_IP}/30" dev "$OUC_VETH_H"
  ip link set "$OUC_VETH_H" up
  ip netns exec "$OUC_NS" sysctl -q -w "net.ipv6.conf.${OUC_VETH_N}.disable_ipv6=1" net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
  ip -n "$OUC_NS" addr add "${OUC_NS_IP}/30" dev "$OUC_VETH_N"
  ip -n "$OUC_NS" link set "$OUC_VETH_N" up
  ip -n "$OUC_NS" route add default via "$OUC_HOST_IP"

  [ -f "$OUC_RUN_DIR/prev_ip_forward" ] || cat /proc/sys/net/ipv4/ip_forward > "$OUC_RUN_DIR/prev_ip_forward" 2>/dev/null || true
  sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true

  ouc_fw_host_up "$OUC_NS_IP" "$OUC_VETH_H"
  ouc_fw_ns_guard "$OUC_NS" "$OUC_VETH_N"
}

ouc_start_warp_svc() {
  if ouc_lock_alive "$OUC_RUN_DIR/warp-svc.lock" && [ -S "$OUC_WARP_RUN/warp_service" ]; then
    return 0
  fi
  local svc
  svc=$(ouc_warp_svc_bin) || { echo "warp-svc not found" >&2; return 1; }
  if [ -f "$OUC_RUN_DIR/warp-svc.pid" ]; then
    kill -TERM "$(cat "$OUC_RUN_DIR/warp-svc.pid" 2>/dev/null)" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$OUC_WARP_RUN/warp_service"
  mkdir -p "$OUC_RUN_DIR/warp-ovl/u" "$OUC_RUN_DIR/warp-ovl/w"
  ouc_trim_log "$OUC_LOG_DIR/warp-svc.log"

  setsid ip netns exec "$OUC_NS" unshare -m bash -c '
    mount --make-rprivate /
    [ -d /run/dbus ] && mount -t tmpfs -o size=1M tmpfs /run/dbus 2>/dev/null || true
    if mount -t overlay overlay -o "lowerdir=/etc,upperdir=$1/u,workdir=$1/w" /etc 2>/dev/null; then
      rm -f /etc/resolv.conf
      printf "nameserver 1.1.1.1\n" > /etc/resolv.conf
    else
      printf "nameserver 1.1.1.1\n" > "$2"
      T=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)
      [ -e "$T" ] && mount --bind "$2" "$T" 2>/dev/null || true
    fi
    exec 8>"$3"
    flock -n 8 || exit 1
    echo $$ > "$4"
    export STATE_DIRECTORY="$5" RUNTIME_DIRECTORY="$6" LOGS_DIRECTORY="$7"
    exec "$8"
  ' _ "$OUC_RUN_DIR/warp-ovl" "$OUC_RUN_DIR/warp-resolv.conf" "$OUC_RUN_DIR/warp-svc.lock" "$OUC_RUN_DIR/warp-svc.pid" "$OUC_WARP_STATE" "$OUC_WARP_RUN" "$OUC_LOG_DIR/warp" "$svc" </dev/null >>"$OUC_LOG_DIR/warp-svc.log" 2>&1 &

  local i
  for i in $(seq 1 30); do
    [ -S "$OUC_WARP_RUN/warp_service" ] && return 0
    sleep 0.5
  done
  return 1
}

ouc_start_keeper() {
  if ouc_lock_alive "$OUC_RUN_DIR/keeper.run.lock"; then
    return 0
  fi
  ouc_trim_log "$OUC_LOG_DIR/keeper.log"
  setsid bash "$LIBEXEC/warp-keeper.sh" </dev/null >>"$OUC_LOG_DIR/keeper.log" 2>&1 &
  local i
  for i in $(seq 1 20); do
    ouc_lock_alive "$OUC_RUN_DIR/keeper.run.lock" && return 0
    sleep 0.2
  done
  return 0
}

ouc_ensure_warp_up() {
  ouc_wo status | head -n1 | grep -q Connected && return 0
  (
    flock -w 45 9 || exit 1
    ouc_wo status | head -n1 | grep -q Connected && exit 0
    ouc_w registration new || true
    ouc_w mode warp
    ouc_w connect
    local i
    for i in $(seq 1 8); do
      sleep 2
      ouc_wo status | head -n1 | grep -q Connected && exit 0
    done
    exit 0
  ) 9>"$OUC_RUN_DIR/warp.lock"
}

ouc_cmd_start() {
  mkdir -p "$OUC_RUN_DIR/mnt" "$OUC_WARP_RUN" "$OUC_WARP_STATE" "$OUC_LOG_DIR/warp"
  chmod 0755 "$OUC_RUN_DIR" "$OUC_RUN_DIR/mnt"
  exec 7>"$OUC_RUN_DIR/ctl.lock"
  flock 7

  if ip netns list 2>/dev/null | grep -qw "^$OUC_NS" \
    && ouc_lock_alive "$OUC_RUN_DIR/warp-svc.lock" \
    && ouc_lock_alive "$OUC_RUN_DIR/keeper.run.lock" \
    && [ -S "$OUC_WARP_RUN/warp_service" ] \
    && ouc_wo status | head -n1 | grep -q Connected; then
    return 0
  fi

  ouc_netns_up || return 1
  ouc_start_warp_svc || return 1
  ouc_start_keeper || return 1
  ouc_ensure_warp_up
}

ouc_cmd_stop() {
  mkdir -p "$OUC_RUN_DIR"
  exec 7>"$OUC_RUN_DIR/ctl.lock"
  flock 7
  local p
  for pf in "$OUC_RUN_DIR/keeper.pid" "$OUC_RUN_DIR/warp-svc.pid"; do
    if [ -f "$pf" ]; then
      p=$(cat "$pf" 2>/dev/null || true)
      [ -n "$p" ] && kill -TERM "$p" 2>/dev/null || true
    fi
  done
  if ip netns list 2>/dev/null | grep -qw "^$OUC_NS"; then
    for p in $(ip netns pids "$OUC_NS" 2>/dev/null); do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in $(ip netns pids "$OUC_NS" 2>/dev/null); do kill -KILL "$p" 2>/dev/null || true; done
    ip netns del "$OUC_NS" 2>/dev/null || true
  fi
  ip link del "$OUC_VETH_H" 2>/dev/null || true
  ouc_fw_host_down "$OUC_VETH_H"
  if [ -f "$OUC_RUN_DIR/prev_ip_forward" ]; then
    sysctl -q -w "net.ipv4.ip_forward=$(cat "$OUC_RUN_DIR/prev_ip_forward" 2>/dev/null || echo 0)" 2>/dev/null || true
  fi
  flock -u 7 2>/dev/null || true
  rm -rf "$OUC_RUN_DIR"
}

ouc_cmd_v6() {
  ip netns list 2>/dev/null | grep -qw "^$OUC_NS" || return 1
  local uid="${SUDO_UID:-}" gid="${SUDO_GID:-}" uname="${SUDO_USER:-nobody}"
  if [ -z "$uid" ] || [ -z "$gid" ]; then
    uid=$(id -u nobody 2>/dev/null || echo 65534)
    gid=$(id -g nobody 2>/dev/null || echo 65534)
  fi
  mkdir -p "$OUC_RUN_DIR/mnt"
  nsenter --net="/var/run/netns/$OUC_NS" unshare -m python3 - "$uid" "$gid" "$uname" "$OUC_RUN_DIR/mnt" <<'PY'
import os, pwd, subprocess, sys
os.umask(0o022)
uid, gid, uname, mnt = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
subprocess.run(["mount", "--make-rprivate", "/"], check=True)
subprocess.run(["mount", "-t", "tmpfs", "-o", "size=1M,mode=0755", "tmpfs", mnt], check=True)
ovl_u, ovl_w = os.path.join(mnt, "u"), os.path.join(mnt, "w")
os.makedirs(ovl_u, exist_ok=True)
os.makedirs(ovl_w, exist_ok=True)
if subprocess.run(["mount", "-t", "overlay", "overlay", "-o", f"lowerdir=/etc,upperdir={ovl_u},workdir={ovl_w}", "/etc"], stderr=subprocess.DEVNULL).returncode == 0:
    try:
        os.unlink("/etc/resolv.conf")
    except FileNotFoundError:
        pass
    with open("/etc/resolv.conf", "w") as f:
        f.write("nameserver 2606:4700:4700::1111\nnameserver 1.1.1.1\n")
else:
    rp = os.path.join(mnt, "resolv.conf")
    with open(rp, "w") as f:
        f.write("nameserver 2606:4700:4700::1111\nnameserver 1.1.1.1\n")
    t = os.path.realpath("/etc/resolv.conf")
    if os.path.exists(t):
        subprocess.run(["mount", "--bind", rp, t], stderr=subprocess.DEVNULL)
try:
    os.initgroups(uname, gid)
except Exception:
    pass
os.setgid(gid)
os.setuid(uid)
os.execvp("curl", ["curl", "-6", "-fsS", "-m", "8", "https://api64.ipify.org"])
PY
}

ouc_cmd_hop() {
  ouc_cmd_start || return 1
  local new_v6=""
  new_v6=$(
    flock 9
    ouc_w disconnect
    ouc_w registration delete
    local ok=0 i
    for i in 1 2 3 4; do
      ouc_w registration new && { ok=1; break; }
      sleep 6
    done
    ouc_w mode warp
    ouc_w connect
    [ "$ok" = 1 ] || exit 1
    local v=""
    for i in $(seq 1 12); do
      sleep 3
      if ouc_wo status | head -n1 | grep -q Connected; then
        v=$(ouc_cmd_v6 2>/dev/null || true)
        [ -n "$v" ] && { printf '%s\n' "$v"; exit 0; }
      fi
    done
    exit 1
  ) 9>"$OUC_RUN_DIR/warp.lock"
  [ -n "$new_v6" ] && { printf '%s\n' "$new_v6"; return 0; }
  return 1
}

ouc_cmd_status() {
  local ns=down wsvc=down keep=down guard=down wst=unknown v6=""
  ip netns list 2>/dev/null | grep -qw "^$OUC_NS" && ns=up
  ouc_lock_alive "$OUC_RUN_DIR/warp-svc.lock" && [ -S "$OUC_WARP_RUN/warp_service" ] && wsvc=up
  ouc_lock_alive "$OUC_RUN_DIR/keeper.run.lock" && keep=up
  [ "$ns" = up ] && ouc_fw_ns_check "$OUC_NS" && guard=up
  [ "$wsvc" = up ] && wst=$(ouc_wo status | head -n1 || echo unknown)
  [ "$ns" = up ] && v6=$(ouc_cmd_v6 2>/dev/null || true)
  printf 'netns=%s\nwarp_svc=%s\nkeeper=%s\nleakguard=%s\nwarp_status=%s\nouc_v6=%s\n' "$ns" "$wsvc" "$keep" "$guard" "$wst" "$v6"
}

ouc_cmd_enter() {
  [ "$#" -ge 2 ] || return 1
  local envfile="$1" real_bin="$2"
  shift 2
  ip netns list 2>/dev/null | grep -qw "^$OUC_NS" || ouc_cmd_start || return 1
  local uid="${SUDO_UID:-$(id -u)}" gid="${SUDO_GID:-$(id -g)}" uname="${SUDO_USER:-$(id -un)}"
  mkdir -p "$OUC_RUN_DIR/mnt"
  exec nsenter --net="/var/run/netns/$OUC_NS" unshare -m python3 - "$uid" "$gid" "$uname" "$OUC_RUN_DIR/mnt" "$envfile" "$real_bin" "$@" <<'PY'
import os, random, select, shutil, signal, socket, subprocess, sys

os.umask(0o022)
uid, gid, uname = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
mnt, envfile, real_bin = sys.argv[4], sys.argv[5], sys.argv[6]
args = sys.argv[7:]

subprocess.run(["mount", "--make-rprivate", "/"], check=True)
subprocess.run(["mount", "-t", "tmpfs", "-o", "size=2M,mode=0755", "tmpfs", mnt], check=True)

ovl_u, ovl_w = os.path.join(mnt, "u"), os.path.join(mnt, "w")
os.makedirs(ovl_u, exist_ok=True)
os.makedirs(ovl_w, exist_ok=True)
use_ovl = subprocess.run(
    ["mount", "-t", "overlay", "overlay", "-o", f"lowerdir=/etc,upperdir={ovl_u},workdir={ovl_w}", "/etc"],
    stderr=subprocess.DEVNULL,
).returncode == 0

mid = os.urandom(16).hex()
resolv_body = "nameserver 1.1.1.1\nnameserver 2606:4700:4700::1111\n"

if use_ovl:
    for p in ("/etc/resolv.conf", "/etc/hosts", "/etc/machine-id"):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    with open("/etc/resolv.conf", "w") as f:
        f.write(resolv_body)
    with open("/etc/machine-id", "w") as f:
        f.write(mid + "\n")
    if os.path.exists("/var/lib/dbus/machine-id"):
        subprocess.run(["mount", "--bind", "/etc/machine-id", "/var/lib/dbus/machine-id"], stderr=subprocess.DEVNULL)
else:
    rp = os.path.join(mnt, "resolv.conf")
    mp = os.path.join(mnt, "machine-id")
    with open(rp, "w") as f:
        f.write(resolv_body)
    with open(mp, "w") as f:
        f.write(mid + "\n")
    rt = os.path.realpath("/etc/resolv.conf")
    if os.path.exists(rt):
        subprocess.run(["mount", "--bind", rp, rt], stderr=subprocess.DEVNULL)
    if os.path.exists("/etc/machine-id"):
        subprocess.run(["mount", "--bind", mp, os.path.realpath("/etc/machine-id")], stderr=subprocess.DEVNULL)
    if os.path.exists("/var/lib/dbus/machine-id"):
        subprocess.run(["mount", "--bind", mp, "/var/lib/dbus/machine-id"], stderr=subprocess.DEVNULL)

def resolve_edge():
    r_fd, w_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r_fd)
        try:
            try:
                os.initgroups(uname, gid)
            except Exception:
                pass
            os.setgid(gid)
            os.setuid(uid)
            ips = []
            dig = shutil.which("dig")
            if dig:
                try:
                    out = subprocess.check_output([dig, "+short", "+time=2", "+tries=1", "AAAA", "opencode.ai", "@1.1.1.1"], text=True, stderr=subprocess.DEVNULL)
                    for ln in out.splitlines():
                        ln = ln.strip()
                        if ln and all(c in "0123456789abcdefABCDEF:" for c in ln) and ":" in ln:
                            ips.append(ln)
                except Exception:
                    pass
            if not ips:
                try:
                    infos = socket.getaddrinfo("opencode.ai", 443, socket.AF_INET6)
                    ips = sorted({i[4][0] for i in infos})
                except Exception:
                    pass
            os.write(w_fd, ("\n".join(ips)).encode())
        except Exception:
            pass
        finally:
            os.close(w_fd)
            os._exit(0)
    os.close(w_fd)
    data = b""
    rlist, _, _ = select.select([r_fd], [], [], 4.0)
    if rlist:
        while True:
            chunk = os.read(r_fd, 4096)
            if not chunk:
                break
            data += chunk
    else:
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    os.close(r_fd)
    try:
        os.waitpid(pid, 0)
    except Exception:
        pass
    pool = [x.strip() for x in data.decode(errors="ignore").splitlines() if x.strip()]
    if not pool:
        pool = ["2606:4700:10::ac42:ad95", "2606:4700:10::ac42:ad96", "2606:4700:10::6814:2011"]
    return random.choice(pool)

aaaa = resolve_edge()
hosts_body = f"127.0.0.1 localhost\n::1 localhost\n{aaaa} opencode.ai\n{aaaa} www.opencode.ai\n{aaaa} api.opencode.ai\n"
if use_ovl:
    with open("/etc/hosts", "w") as f:
        f.write(hosts_body)
else:
    hp = os.path.join(mnt, "hosts")
    with open(hp, "w") as f:
        f.write(hosts_body)
    ht = os.path.realpath("/etc/hosts")
    if os.path.exists(ht):
        subprocess.run(["mount", "--bind", hp, ht], stderr=subprocess.DEVNULL)

try:
    os.initgroups(uname, gid)
except Exception:
    pass
os.setgid(gid)
os.setuid(uid)

env = {}
try:
    with open(envfile, "rb") as f:
        raw = f.read()
    for item in raw.split(b"\x00"):
        if b"=" in item:
            k, v = item.split(b"=", 1)
            env[k.decode(errors="surrogateescape")] = v.decode(errors="surrogateescape")
finally:
    try:
        os.unlink(envfile)
    except Exception:
        pass

if not env:
    env = dict(os.environ)

os.execvpe(real_bin, [real_bin] + args, env)
PY
}

case "${1:-}" in
  start)  ouc_cmd_start ;;
  stop)   ouc_cmd_stop ;;
  status) ouc_cmd_status ;;
  hop)    ouc_cmd_hop ;;
  v6)     ouc_cmd_v6 ;;
  enter)  shift; ouc_cmd_enter "$@" ;;
  *)      echo "usage: ouc-root {start|stop|status|hop|v6|enter}" >&2; exit 2 ;;
esac
