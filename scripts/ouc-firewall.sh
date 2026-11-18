#!/usr/bin/env bash

ouc_fw_backend() {
  if command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
    echo "iptables"
  elif command -v nft >/dev/null 2>&1; then
    echo "nft"
  else
    return 1
  fi
}

ouc_ipt_ct_args() {
  if iptables -m conntrack -h >/dev/null 2>&1; then
    echo "-m conntrack --ctstate"
  else
    echo "-m state --state"
  fi
}

ouc_fw_host_down() {
  local veth_h="$1"
  if command -v iptables >/dev/null 2>&1; then
    while iptables -t nat -D POSTROUTING -j OUC_NAT 2>/dev/null; do :; done
    iptables -t nat -F OUC_NAT 2>/dev/null || true
    iptables -t nat -X OUC_NAT 2>/dev/null || true
    while iptables -D FORWARD -j OUC_FWD 2>/dev/null; do :; done
    iptables -F OUC_FWD 2>/dev/null || true
    iptables -X OUC_FWD 2>/dev/null || true
  fi
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet ouc_host 2>/dev/null || true
  fi
}

ouc_fw_host_up() {
  local ns_ip="$1" veth_h="$2" be ct
  be=$(ouc_fw_backend) || return 1
  ouc_fw_host_down "$veth_h"
  if [ "$be" = "iptables" ]; then
    ct=$(ouc_ipt_ct_args)
    iptables -t nat -N OUC_NAT 2>/dev/null || iptables -t nat -F OUC_NAT
    iptables -t nat -A OUC_NAT -s "${ns_ip}/32" ! -o "$veth_h" -j MASQUERADE
    iptables -t nat -C POSTROUTING -j OUC_NAT 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j OUC_NAT
    iptables -N OUC_FWD 2>/dev/null || iptables -F OUC_FWD
    iptables -A OUC_FWD -i "$veth_h" -j ACCEPT
    iptables -A OUC_FWD -o "$veth_h" $ct ESTABLISHED,RELATED -j ACCEPT
    iptables -C FORWARD -j OUC_FWD 2>/dev/null || iptables -I FORWARD 1 -j OUC_FWD
  else
    nft -f - <<EOF
table inet ouc_host {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "$veth_h" accept
    oifname "$veth_h" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $ns_ip oifname != "$veth_h" masquerade
  }
}
EOF
  fi
}

ouc_fw_ns_guard() {
  local ns="$1" veth_n="$2" be ct has_owner=0
  be=$(ouc_fw_backend) || return 1
  if [ "$be" = "iptables" ]; then
    ct=$(ouc_ipt_ct_args)
    ip netns exec "$ns" iptables -m owner -h >/dev/null 2>&1 && has_owner=1
    ip netns exec "$ns" iptables -N OUC_LEAKGUARD 2>/dev/null || true
    ip netns exec "$ns" iptables -F OUC_LEAKGUARD
    ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o lo -j ACCEPT
    ip netns exec "$ns" iptables -A OUC_LEAKGUARD $ct ESTABLISHED,RELATED -j ACCEPT
    ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o CloudflareWARP -j ACCEPT
    if [ "$has_owner" = 1 ]; then
      ip netns exec "$ns" iptables -A OUC_LEAKGUARD -m owner --uid-owner 0 -o "$veth_n" -j ACCEPT
    else
      ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o "$veth_n" -d 162.159.0.0/16 -j ACCEPT
      ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o "$veth_n" -d 188.114.0.0/16 -j ACCEPT
      ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o "$veth_n" -d 104.16.0.0/12 -j ACCEPT
      ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o "$veth_n" -d 172.64.0.0/13 -j ACCEPT
      ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o "$veth_n" -d 1.1.1.1/32 -j ACCEPT
      ip netns exec "$ns" iptables -A OUC_LEAKGUARD -o "$veth_n" -d 1.0.0.1/32 -j ACCEPT
    fi
    ip netns exec "$ns" iptables -A OUC_LEAKGUARD -j DROP
    ip netns exec "$ns" iptables -C OUTPUT -j OUC_LEAKGUARD 2>/dev/null || ip netns exec "$ns" iptables -I OUTPUT 1 -j OUC_LEAKGUARD

    ip netns exec "$ns" ip6tables -N OUC_LEAKGUARD 2>/dev/null || true
    ip netns exec "$ns" ip6tables -F OUC_LEAKGUARD
    ip netns exec "$ns" ip6tables -A OUC_LEAKGUARD -o lo -j ACCEPT
    ip netns exec "$ns" ip6tables -A OUC_LEAKGUARD $ct ESTABLISHED,RELATED -j ACCEPT
    ip netns exec "$ns" ip6tables -A OUC_LEAKGUARD -o CloudflareWARP -j ACCEPT
    ip netns exec "$ns" ip6tables -A OUC_LEAKGUARD -j DROP
    ip netns exec "$ns" ip6tables -C OUTPUT -j OUC_LEAKGUARD 2>/dev/null || ip netns exec "$ns" ip6tables -I OUTPUT 1 -j OUC_LEAKGUARD
  else
    ip netns exec "$ns" nft -f - <<EOF
table inet ouc_guard
delete table inet ouc_guard
table inet ouc_guard {
  chain output {
    type filter hook output priority -5; policy drop;
    oifname "lo" accept
    ct state established,related accept
    oifname "CloudflareWARP" accept
    meta skuid 0 oifname "$veth_n" accept
  }
}
EOF
  fi
}

ouc_fw_ns_check() {
  local ns="$1" be
  be=$(ouc_fw_backend) || return 1
  if [ "$be" = "iptables" ]; then
    ip netns exec "$ns" iptables -nL OUC_LEAKGUARD >/dev/null 2>&1 && ip netns exec "$ns" ip6tables -nL OUC_LEAKGUARD >/dev/null 2>&1
  else
    ip netns exec "$ns" nft list table inet ouc_guard >/dev/null 2>&1
  fi
}
