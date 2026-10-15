#!/usr/bin/env bash
# CI: network-mode.tfvars and primary_firewall_enabled of the accelerator configuration must agree.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="$(sed -nE 's|^network_mode = "(.*)"|\1|p' "$root/network-mode.tfvars")"
enabled="$(sed -nE 's|^    primary_firewall_enabled +=[ ]*(true\|false).*|\1|p' "$root/accelerator/config/platform-landing-zone.tfvars")"
case "$mode/$enabled" in
  firewall/true | sandbox/false | labfw/false) echo "network mode $mode, primary_firewall_enabled = $enabled" ;;
  *) echo "network-mode.tfvars says '$mode' but primary_firewall_enabled = '$enabled': run scripts/set-network-mode.sh $mode" >&2; exit 1 ;;
esac
