#!/usr/bin/env bash
# watchdog.sh - installed as /usr/local/sbin/vps-firewall-watch.
#
# The watcher calls the installed firewall and network modules in a loop. They
# regenerate the managed nftables chain and the scoped MSS chain from the live
# Docker bridge inventory and only write when something actually changed.

set -u

TOOLKIT_HOME="${VPS_SETUP_HOME:-/usr/local/lib/vps-setup-toolkit}"
FIREWALL="${TOOLKIT_HOME}/scripts/firewall.sh"
NETWORK="${TOOLKIT_HOME}/scripts/network.sh"
CONF_FILE="${VPS_SETUP_CONF:-/etc/default/vps-setup}"
WATCH_LOG="${VPS_SETUP_WATCH_LOG:-/var/log/vps-setup/firewall-watch.log}"
WATCH_INTERVAL=15

if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CONF_FILE" 2>/dev/null || true
fi
if [[ ! "$WATCH_INTERVAL" =~ ^[0-9]+$ ]] || (( WATCH_INTERVAL < 5 || WATCH_INTERVAL > 3600 )); then
  WATCH_INTERVAL=15
fi

mkdir -p -- "$(dirname -- "$WATCH_LOG")" 2>/dev/null || true

while true; do
  if [[ -x "$FIREWALL" ]]; then
    "$FIREWALL" service-reconcile 0 >>"$WATCH_LOG" 2>&1 || true
  fi
  if [[ -x "$NETWORK" ]]; then
    "$NETWORK" reconcile 0 >>"$WATCH_LOG" 2>&1 || true
  fi
  sleep "$WATCH_INTERVAL"
done
