#!/usr/bin/env bash
# Usage: scripts/set-network-mode.sh firewall|sandbox|labfw
# Switches the network mode of the build tenant in one place (network-mode.tfvars, passed to every stack by the
# workflows) and in the accelerator configuration (primary_firewall_enabled), then regenerates ./platform.
set -euo pipefail
mode="${1:-}"
case "$mode" in
  firewall) enabled=true ;;
  sandbox | labfw) enabled=false ;; # labfw replaces the Azure Firewall
  *) echo "usage: $0 firewall|sandbox|labfw" >&2; exit 2 ;;
esac
root="$(cd "$(dirname "$0")/.." && pwd)"
sed -i -E "s|^network_mode = \".*\"|network_mode = \"$mode\"|" "$root/network-mode.tfvars"
sed -i -E "s|^(    primary_firewall_enabled +)= (true\|false)|\1= $enabled|" "$root/accelerator/config/platform-landing-zone.tfvars"
"$root/scripts/check-network-mode.sh"
"$root/scripts/sync-platform.sh"
echo "network mode: $mode – commit network-mode.tfvars, accelerator/config and platform/"
