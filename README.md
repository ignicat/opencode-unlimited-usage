# opencode-unlimited-usage

Linux wrapper that routes `opencode` through an isolated Cloudflare WARP network and mount namespace, rotating IPv6 `/64` allocations and Cloudflare edge addresses per session across any glibc Linux distribution without modifying host networking, DNS, or firewall output rules.

## Requirements

- Linux (`x86_64` or `aarch64`) with `/dev/net/tun` and `glibc`
- `sudo` access for namespace, `veth`, and `warp-svc` management
- `bash`, `python3`, `curl`, `iproute2`, `util-linux` (`unshare`, `nsenter`, `flock`), `iptables` or `nftables`

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ignicat/opencode-unlimited-usage/main/install.sh | bash
```

Or from a local clone:

```bash
git clone https://github.com/ignicat/opencode-unlimited-usage.git
cd opencode-unlimited-usage
./install.sh
```

`install.sh` installs missing base dependencies via the system package manager (`apt-get`, `dnf`, `yum`, `pacman`, `xbps-install`, `apk`, `zypper`, `emerge`), fetches `cloudflare-warp` binaries if absent, configures `/etc/sudoers.d/opencode-unlimited`, and wraps `~/.local/bin/opencode`.

## Usage

| Command | Description |
| :--- | :--- |
| `opencode` | Starts the isolated `ouc` namespace and `zen-guard` if inactive, then launches `opencode` with a random IPv6 edge and `/etc/machine-id` |
| `opencode-unlimited-doctor` | Verifies `ouc`, `warp-svc`, `OUC_LEAKGUARD`, WARP IPv6 egress, `zen-guard`, and confirms host network and `/etc/resolv.conf` are untouched |
| `opencode-unlimited-hop` | Blacklists the current `/64` prefix and forces WARP re-registration inside `ouc` to obtain a fresh `/64` |
| `opencode-unlimited-ctl <cmd>` | Manually `start`, `stop` (tears down `ouc`, `veth`, host NAT, restores `ip_forward`), `restart`, or print `status` |

## Architecture

- **Namespace isolation**: `ouc-root` creates network namespace `ouc`, attaches a `veth` pair using a non-conflicting `/30` subnet, enables scoped host NAT/forwarding (`iptables` or `nft`), and runs `warp-svc` inside `ouc` with isolated `STATE_DIRECTORY`, `RUNTIME_DIRECTORY`, `LOGS_DIRECTORY`, blocked `/run/dbus`, and a private `/etc` mount (`overlay` with `mount --bind` fallback). Host routes, IP addresses, `/etc/resolv.conf`, and `OUTPUT` firewall rules remain unchanged.
- **Kill-switch**: `OUC_LEAKGUARD` runs strictly inside `ouc`, allowing non-root processes to exit only via `CloudflareWARP` or `lo`. Tunnel drops fail closed without leaking host traffic.
- **Launch lane**: `zen-lane.sh` invokes `ouc-root enter`, which binds `1.1.1.1`/`2606:4700:4700::1111` in `/etc/resolv.conf`, pins `opencode.ai`, `www.opencode.ai`, and `api.opencode.ai` to a random IPv6 `AAAA` record, generates a random `/etc/machine-id`, drops privileges back to the calling user with full environment preservation, and executes `opencode`.
- **Quota rotation**: `zen-guard.sh` runs under a `flock` singleton lock, tails `~/.local/share/opencode/log/opencode.log`, blacklists burned `/64` prefixes in `~/.local/share/opencode-unlimited/guard/state.json` on `QuotaExceeded`, and triggers `ouc-root hop` (synchronized against `warp-keeper.sh` via `flock`).

## Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `OUC_DIRECT` | Set to `1` to bypass `ouc` and run `opencode` directly on the host | `0` |
| `OUC_REAL_BIN` | Path to the target `opencode` binary | `~/.opencode/bin/opencode` |
| `OUC_WARP_BIN` | Path to `warp-cli` | Auto-detected |
| `OUC_WARP_SVC` | Path to `warp-svc` | Auto-detected |

## Installed Paths

- `/usr/local/bin/ouc-root`, `/usr/local/libexec/opencode-unlimited/` — privileged namespace, `warp-svc`, keeper, and firewall scripts
- `/opt/opencode-unlimited/bin/` — extracted `warp-cli` / `warp-svc` binaries (when installed from `.deb`)
- `~/.local/share/opencode-unlimited/` — user scripts and `/64` blacklist state
- `~/.local/bin/opencode`, `opencode-unlimited-{hop,doctor,ctl}` — CLI wrapper and control links
- `/etc/sudoers.d/opencode-unlimited` — passwordless `sudo` rule for `ouc-root`

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ignicat/opencode-unlimited-usage/main/uninstall.sh | bash
```

Or locally:

```bash
./uninstall.sh
```

## License

MIT License. See [LICENSE](LICENSE).
