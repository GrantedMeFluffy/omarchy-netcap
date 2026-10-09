#!/usr/bin/env bash
set -euo pipefail

readonly IFB=netcap0
readonly IFB_ALIAS=omarchy-netcap
readonly FILTER_PREF=49152
readonly STATE_DIR=/run/omarchy-netcap
STATE_ORIGINAL_QDISC=""

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

state_path() {
  printf '%s/%s.state\n' "$STATE_DIR" "$1"
}

safe_state_dir() {
  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || return 1
  [[ "$(stat -c '%u:%a' "$STATE_DIR" 2>/dev/null)" == "0:755" ]]
}

ensure_state_dir() {
  if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
    mkdir -m 755 -- "$STATE_DIR"
  fi
  safe_state_dir || fail "unsafe NetCap state directory; refusing to manage traffic control"
}

read_state() {
  local iface="$1" path version saved_iface original extra
  safe_state_dir || return 1
  path="$(state_path "$iface")"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(stat -c '%u:%a' "$path" 2>/dev/null)" == "0:644" ]] || return 1
  IFS=' ' read -r version saved_iface original extra < "$path" || return 1
  [[ "$version" == "1" && "$saved_iface" == "$iface" &&
    ( "$original" == "fq_codel" || "$original" == "pfifo_fast" ) &&
    -z "${extra:-}" ]] || return 1
  STATE_ORIGINAL_QDISC="$original"
}

write_state() {
  local iface="$1" original="$2" tmp
  ensure_state_dir
  tmp="$(mktemp "$STATE_DIR/.${iface}.XXXXXX")"
  printf '1 %s %s\n' "$iface" "$original" >"$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$(state_path "$iface")"
}

remove_state() {
  rm -f -- "$(state_path "$1")"
}

has_netcap_tree() {
  local iface="$1" root classes qdiscs
  root="$(root_qdisc "$iface")"
  [[ "$root" =~ ^qdisc[[:space:]]+htb[[:space:]]+1:[[:space:]]+root([[:space:]]|$) ]] || return 1

  classes="$(tc class show dev "$iface" 2>/dev/null)"
  awk '
    $1 == "class" && $2 == "htb" && $3 == "1:10" && $4 == "root" { htb++; next }
    $1 == "class" && $2 == "fq_codel" && $3 ~ /^10:[[:xdigit:]]+$/ && $4 == "parent" && $5 == "10:" { next }
    { invalid = 1 }
    END { exit !(htb == 1 && !invalid) }
  ' <<<"$classes" || return 1

  qdiscs="$(tc qdisc show dev "$iface")"
  awk '
    $1 == "qdisc" && $2 == "htb" && $3 == "1:" && $4 == "root" { root++; next }
    $1 == "qdisc" && $2 == "fq_codel" && $3 == "10:" && $4 == "parent" && $5 == "1:10" { leaf++; next }
    $1 == "qdisc" && $2 == "ingress" && $3 == "ffff:" && $4 == "parent" && $5 == "ffff:fff1" { ingress++; next }
    { invalid = 1 }
    END { exit !(root == 1 && leaf == 1 && ingress <= 1 && !invalid) }
  ' <<<"$qdiscs" || return 1
  [[ -z "$(tc filter show dev "$iface" parent 1: 2>/dev/null)" &&
    -z "$(tc filter show dev "$iface" parent 1:10 2>/dev/null)" ]]
}

is_our_redirect() {
  local filters count
  filters="$(tc filter show dev "$1" parent ffff: 2>/dev/null || true)"
  count="$(grep -c 'pref ' <<<"$filters" || true)"
  [[ "$count" -eq 1 ]] &&
    grep -Fq "pref $FILTER_PREF" <<<"$filters" &&
    grep -Fq "device $IFB" <<<"$filters"
}

is_owned_install() {
  local iface="$1" ingress_filters
  read_state "$iface" &&
    is_our_ifb &&
    has_netcap_tree "$iface" &&
    has_netcap_tree "$IFB" &&
    is_our_redirect "$iface" || return 1
  tc qdisc show dev "$iface" | grep -q 'qdisc ingress' || return 1
  ingress_filters="$(tc filter show dev "$iface" parent ffff: 2>/dev/null || true)"
  [[ "$(grep -c 'pref ' <<<"$ingress_filters" || true)" -eq 1 ]]
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

  local current_root qdiscs filters original_qdisc already_managed=0
  if read_state "$iface"; then
    is_owned_install "$iface" ||
      fail "NetCap state does not match the active traffic-control rules; refusing to modify them"
    original_qdisc="$STATE_ORIGINAL_QDISC"
    already_managed=1
  else
    current_root="$(root_qdisc "$iface")"
    if [[ "$current_root" =~ ^qdisc\ (fq_codel|pfifo_fast)\ 0:\ root ]]; then
      original_qdisc="$(awk '{print $2}' <<<"$current_root")"
    else
      fail "unsupported or unmanaged root qdisc on $iface; refusing to replace existing traffic control"
    fi

    if ip link show dev "$IFB" >/dev/null 2>&1; then
      fail "$IFB already exists and is not managed by NetCap"
    fi

    qdiscs="$(tc qdisc show dev "$iface")"
    if grep -qE 'qdisc (clsact|ingress)' <<<"$qdiscs"; then
      fail "an ingress or clsact qdisc already exists on $iface; refusing to replace existing traffic control"
    fi
    filters="$(tc filter show dev "$iface" parent ffff: 2>/dev/null || true)"
    [[ -z "$filters" ]] || fail "ingress filters already exist on $iface; refusing to replace existing traffic control"
  fi

  if (( ! already_managed )); then
    ip link add "$IFB" type ifb
    ip link set dev "$IFB" alias "$IFB_ALIAS"
    ip link set dev "$IFB" up
  fi

  if (( ! already_managed )); then
    tc qdisc add dev "$iface" handle ffff: ingress
    tc filter add dev "$iface" parent ffff: protocol all pref "$FILTER_PREF" \
      u32 match u32 0 0 action mirred egress redirect dev "$IFB"
  fi

  rate_tree "$IFB" "$down_kbit"
  rate_tree "$iface" "$up_kbit"
  if (( ! already_managed )); then
    write_state "$iface" "$original_qdisc"
  fi
}

clear_limits() {
  local iface="$1"
  valid_iface "$iface" || fail "invalid network interface"
  ip link show dev "$iface" >/dev/null 2>&1 || fail "interface $iface is unavailable"
  is_owned_install "$iface" ||
    fail "NetCap state does not match the active traffic-control rules; refusing to remove them"

  local original_qdisc="$STATE_ORIGINAL_QDISC"
  tc qdisc replace dev "$iface" root "$original_qdisc"
  tc filter del dev "$iface" parent ffff: pref "$FILTER_PREF"
  tc qdisc del dev "$iface" ingress
  tc qdisc del dev "$IFB" root
  ip link del dev "$IFB"
  remove_state "$iface"
}

case "${1:-}" in
  status)
    iface="${2:-}"
    valid_iface "$iface" || fail "invalid network interface"
    is_owned_install "$iface"
    ;;
  apply)
    [[ "$#" -eq 4 ]] || fail "usage: netcap-root.sh apply <interface> <down-kbit> <up-kbit>"
    ensure_state_dir
    exec 9>"$STATE_DIR/lock"
    flock -x 9
    apply_limits "$2" "$3" "$4"
    ;;
  clear)
    [[ "$#" -eq 2 ]] || fail "usage: netcap-root.sh clear <interface>"
    ensure_state_dir
    exec 9>"$STATE_DIR/lock"
    flock -x 9
    clear_limits "$2"
    ;;
  *)
    fail "usage: netcap-root.sh status <interface> | apply <interface> <down-kbit> <up-kbit> | clear <interface>"
    ;;
esac
