#!/usr/bin/env bash
# watchdog.sh - installed as /usr/local/sbin/vps-firewall-watch.
#
# The watcher calls the installed firewall module in a loop. The module
# regenerates the managed nftables chain from the live Docker bridge inventory
# and only writes when something actually changed.

set -u

TOOLKIT_HOME="${VPS_SETUP_HOME:-/usr/local/lib/vps-setup-toolkit}"
FIREWALL="${TOOLKIT_HOME}/scripts/firewall.sh"
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
    "$FIREWALL" nft-reconcile >>"$WATCH_LOG" 2>&1 || true
  fi
  sleep "$WATCH_INTERVAL"
done
