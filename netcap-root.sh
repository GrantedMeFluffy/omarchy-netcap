#!/usr/bin/env bash
set -euo pipefail

readonly IFB=netcap0
readonly IFB_ALIAS=omarchy-netcap
readonly FILTER_PREF=49152

fail() {
  printf 'NetCap: %s\n' "$*" >&2
  exit 1
}

valid_iface() {
  [[ "$1" =~ ^[[:alnum:]_.-]{1,15}$ && "$1" != "lo" ]]
}

is_our_ifb() {
  ip -o link show dev "$IFB" 2>/dev/null | grep -Fq "alias $IFB_ALIAS"
}

root_qdisc() {
  tc qdisc show dev "$1" | awk '$4 == "root" { print; exit }'
}

is_our_tree() {
  [[ "$(root_qdisc "$1")" == "qdisc htb 1: root"* ]]
}

is_our_redirect() {
  local filters
  filters="$(tc filter show dev "$1" parent ffff: 2>/dev/null || true)"
  grep -Fq "pref $FILTER_PREF" <<<"$filters" &&
    grep -Fq "device $IFB" <<<"$filters"
}

rate_tree() {
  local iface="$1" rate_kbit="$2"
  tc qdisc replace dev "$iface" root handle 1: htb default 10
  tc class add dev "$iface" parent 1: classid 1:10 htb \
    rate "${rate_kbit}kbit" ceil "${rate_kbit}kbit"
  tc qdisc add dev "$iface" parent 1:10 handle 10: fq_codel
}

apply_limits() {
  local iface="$1" down_kbit="$2" up_kbit="$3"
  valid_iface "$iface" || fail "invalid network interface"
  [[ "$down_kbit" =~ ^[0-9]+$ && "$up_kbit" =~ ^[0-9]+$ ]] ||
    fail "speed limits must be positive integer kbit/s values"
  (( down_kbit >= 8 && down_kbit <= 100000000 &&
    up_kbit >= 8 && up_kbit <= 100000000 )) ||
    fail "speed limits must be between 8 and 100000000 kbit/s"
  ip link show dev "$iface" >/dev/null 2>&1 || fail "interface $iface is unavailable"

  local current_root qdiscs filters
  current_root="$(root_qdisc "$iface")"
  if [[ "$current_root" != "qdisc htb 1: root"* ]]; then
    [[ "$current_root" =~ ^qdisc\ (fq_codel|noqueue|pfifo_fast)\ 0:\ root ]] ||
      fail "unsupported root qdisc on $iface; refusing to replace existing traffic control"
  fi

  if ip link show dev "$IFB" >/dev/null 2>&1; then
    is_our_ifb || fail "$IFB already exists and is not managed by NetCap"
  fi

  qdiscs="$(tc qdisc show dev "$iface")"
  if grep -q 'qdisc clsact' <<<"$qdiscs"; then
    fail "clsact is already attached to $iface; refusing to replace existing traffic control"
  fi
  filters="$(tc filter show dev "$iface" parent ffff: 2>/dev/null || true)"
  if grep -q "pref $FILTER_PREF" <<<"$filters"; then
    is_our_redirect "$iface" || fail "filter priority $FILTER_PREF is already in use on $iface"
  elif grep -q 'qdisc ingress' <<<"$qdiscs"; then
    fail "an ingress qdisc already exists on $iface; refusing to replace existing traffic control"
  fi

  if ! is_our_ifb; then
    ip link add "$IFB" type ifb
    ip link set dev "$IFB" alias "$IFB_ALIAS"
    ip link set dev "$IFB" up
  fi

  if ! is_our_redirect "$iface"; then
    tc qdisc add dev "$iface" handle ffff: ingress
    tc filter add dev "$iface" parent ffff: protocol all pref "$FILTER_PREF" \
      u32 match u32 0 0 action mirred egress redirect dev "$IFB"
  fi

  rate_tree "$IFB" "$down_kbit"
  rate_tree "$iface" "$up_kbit"
}

clear_limits() {
  local iface="$1" filters
  valid_iface "$iface" || fail "invalid network interface"
  ip link show dev "$iface" >/dev/null 2>&1 || fail "interface $iface is unavailable"

  if is_our_ifb; then
    filters="$(tc filter show dev "$iface" parent ffff: 2>/dev/null || true)"
    local redirect_refs
    redirect_refs="$(grep -Fc "device $IFB" <<<"$filters" || true)"
    if (( redirect_refs > 0 )) && { ! is_our_redirect "$iface" || (( redirect_refs > 1 )); }; then
      fail "another ingress rule still redirects traffic to $IFB; refusing to remove the device"
    fi
  fi

  if is_our_tree "$iface"; then
    tc qdisc del dev "$iface" root
  fi

  if is_our_ifb; then
    if is_our_redirect "$iface"; then
      tc filter del dev "$iface" parent ffff: pref "$FILTER_PREF"
    fi
    filters="$(tc filter show dev "$iface" parent ffff: 2>/dev/null || true)"
    if [[ -z "$filters" ]] && tc qdisc show dev "$iface" | grep -q 'qdisc ingress'; then
      tc qdisc del dev "$iface" ingress
    fi
    if is_our_tree "$IFB"; then
      tc qdisc del dev "$IFB" root
    fi
    ip link del dev "$IFB"
  fi
}

case "${1:-}" in
  status)
    iface="${2:-}"
    valid_iface "$iface" || fail "invalid network interface"
    is_our_ifb && is_our_tree "$iface" && is_our_redirect "$iface"
    ;;
  apply)
    [[ "$#" -eq 4 ]] || fail "usage: netcap-root.sh apply <interface> <down-kbit> <up-kbit>"
    apply_limits "$2" "$3" "$4"
    ;;
  clear)
    [[ "$#" -eq 2 ]] || fail "usage: netcap-root.sh clear <interface>"
    clear_limits "$2"
    ;;
  *)
    fail "usage: netcap-root.sh status <interface> | apply <interface> <down-kbit> <up-kbit> | clear <interface>"
    ;;
esac
