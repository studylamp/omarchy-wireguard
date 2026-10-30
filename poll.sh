#!/usr/bin/env bash
set -o pipefail
# Emits one blob describing every NetworkManager WireGuard tunnel, so a refresh
# costs a single process instead of several per tunnel. Section markers are
# `#TAG argument`; Model.js parses them.
#
# Everything here is readable without privileges. `wg show` deliberately is not
# used: it needs root, and NetworkManager already exposes the address, routes
# and endpoint we display.

all_connections=$(nmcli -t -f UUID,NAME,TYPE,ACTIVE,DEVICE,STATE connection show 2>/dev/null) || exit 1
conns=$(printf '%s\n' "$all_connections" | grep ':wireguard:' || true)

printf '#CONNS\n'
[ -n "$conns" ] && printf '%s\n' "$conns"

[ -z "$conns" ] && exit 0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  uuid=${line%%:*}
  # Count fields from the end; NAME may contain escaped colons, but the
  # trailing TYPE:ACTIVE:DEVICE:STATE columns never do.
  active=$(printf '%s' "$line" | awk -F: '{print $(NF-2)}')
  dev=$(printf '%s' "$line" | awk -F: '{print $(NF-1)}')

  printf '#PEER %s\n' "$uuid"
  nmcli -t -f wireguard.peers connection show uuid "$uuid" 2>/dev/null

  if [ "$active" = "yes" ] && [ -n "$dev" ]; then
    printf '#DEV %s\n' "$dev"
    nmcli -t -f IP4.ADDRESS,IP4.ROUTE,IP6.ADDRESS,IP6.ROUTE device show "$dev" 2>/dev/null
    if [ -r "/sys/class/net/$dev/statistics/rx_bytes" ]; then
      printf '#STAT %s\n' "$dev"
      cat "/sys/class/net/$dev/statistics/rx_bytes" "/sys/class/net/$dev/statistics/tx_bytes" 2>/dev/null
    fi
  fi
done <<< "$conns"
