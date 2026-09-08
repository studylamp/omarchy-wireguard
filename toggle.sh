#!/usr/bin/env bash
# Toggle the primary WireGuard tunnel and report the result, for the Hyprland
# keybinding. The bar widget owns the state; this only drives it over IPC and
# reads the summary back once nmcli has had a moment to settle.

if ! omarchy-shell -q io.github.studylamp.wireguard toggleTunnel "" ; then
  notify-send -a WireGuard -u critical "WireGuard" "Omarchy shell is not running"
  exit 1
fi

# nmcli returns before the link is fully up; give the next poll time to land.
sleep 2

status=$(omarchy-shell io.github.studylamp.wireguard status 2>/dev/null)
[ -z "$status" ] && status="State unknown"
notify-send -a WireGuard "WireGuard" "$status"
