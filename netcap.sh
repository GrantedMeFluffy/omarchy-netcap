#!/usr/bin/env bash
set -euo pipefail

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-netcap"
state_file="$state_dir/usage.json"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
exec 9>"$state_dir/usage.lock"
flock -x 9

iface="$(ip route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
if [[ ! "$iface" =~ ^[[:alnum:]_.-]{1,15}$ ]] || [[ "$iface" == "lo" ]]; then
  printf 'No supported default network interface is available\n' >&2
  exit 1
fi

stats_dir="/sys/class/net/$iface/statistics"
if [[ ! -r "$stats_dir/rx_bytes" || ! -r "$stats_dir/tx_bytes" ]]; then
  printf 'Cannot read network counters for %s\n' "$iface" >&2
  exit 1
fi

rx="$(<"$stats_dir/rx_bytes")"
tx="$(<"$stats_dir/tx_bytes")"
if [[ ! "$rx" =~ ^[0-9]+$ || ! "$tx" =~ ^[0-9]+$ ]]; then
  printf 'Invalid network counters for %s\n' "$iface" >&2
  exit 1
fi

month="$(date +%Y-%m)"
used=0
if [[ -e "$state_file" ]]; then
  if ! jq -e '
    .month | strings and test("^[0-9]{4}-[0-9]{2}$")
  ' "$state_file" >/dev/null ||
    ! jq -e '
      (.usedBytes | numbers and floor == .) and
      (.rxBytes | numbers and floor == .) and
      (.txBytes | numbers and floor == .) and
      (.interface | strings)
    ' "$state_file" >/dev/null; then
    printf 'Usage state is invalid: %s\n' "$state_file" >&2
    exit 1
  fi

  old_month="$(jq -r '.month' "$state_file")"
  if [[ "$old_month" == "$month" ]]; then
    used="$(jq -r '.usedBytes' "$state_file")"
    old_iface="$(jq -r '.interface' "$state_file")"
    old_rx="$(jq -r '.rxBytes' "$state_file")"
    old_tx="$(jq -r '.txBytes' "$state_file")"
    if [[ "$old_iface" == "$iface" && "$rx" -ge "$old_rx" && "$tx" -ge "$old_tx" ]]; then
      used=$((used + rx - old_rx + tx - old_tx))
    fi
  fi
fi

tmp="$(mktemp "$state_dir/.usage.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq -n \
  --arg month "$month" \
  --arg interface "$iface" \
  --argjson usedBytes "$used" \
  --argjson rxBytes "$rx" \
  --argjson txBytes "$tx" \
  '{month:$month, interface:$interface, usedBytes:$usedBytes, rxBytes:$rxBytes, txBytes:$txBytes}' >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$state_file"
trap - EXIT

active=false
down_kbit=0
up_kbit=0
if [[ -x "$(dirname "$0")/netcap-root.sh" ]] &&
  "$(dirname "$0")/netcap-root.sh" status "$iface" >/dev/null 2>&1; then
  active=true
  class_rate_kbit() {
    local line rate unit
    line="$(tc class show dev "$1" 2>/dev/null | awk '$3 == "1:10" { print; exit }')"
    read -r rate unit < <(sed -nE 's/.* rate ([0-9]+)(Kbit|Mbit|Gbit).*/\1 \2/p' <<<"$line")
    case "${unit:-}" in
      Kbit) printf '%s\n' "$rate" ;;
      Mbit) printf '%s\n' "$((rate * 1000))" ;;
      Gbit) printf '%s\n' "$((rate * 1000000))" ;;
      *) return 1 ;;
    esac
  }
  down_kbit="$(class_rate_kbit netcap0)"
  up_kbit="$(class_rate_kbit "$iface")"
fi

jq -n \
  --arg interface "$iface" \
  --arg month "$month" \
  --argjson rxBytes "$rx" \
  --argjson txBytes "$tx" \
  --argjson usedBytes "$used" \
  --argjson active "$active" \
  --argjson downKbit "$down_kbit" \
  --argjson upKbit "$up_kbit" \
  '{interface:$interface, month:$month, rxBytes:$rxBytes, txBytes:$txBytes,
    usedBytes:$usedBytes, active:$active, downKbit:$downKbit, upKbit:$upKbit}'
