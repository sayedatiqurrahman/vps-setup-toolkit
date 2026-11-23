#!/usr/bin/env bash
# recovery.sh - repair/recovery operations for the firewall watcher and config.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

RECOVERY_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi

repair_config(){
  if [[ ! -f "$CONF_FILE" ]]; then
    if confirm "Configuration file ${CONF_FILE} is missing. Create safe defaults?"; then
      load_config || return 1
      save_config || return 1
      success "Default configuration created."
    else
      log "Configuration repair skipped."
    fi
  else
    load_config && success "Configuration file loaded and validated: ${CONF_FILE}"
  fi
}

repair_all(){
  local bridges
  section "Repair and recovery"
  repair_config || return 1
  init_runtime || true
  if ! command_exists ufw || ! command_exists nft || ! command_exists ip; then
    # shellcheck source=system.sh
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/system.sh"
    install_base_packages || return 1
  fi

  ufw_init || warn "UFW repair failed."
  ufw_apply_managed_egress || warn "Managed UFW egress repair failed."
  nft_apply || warn "nftables repair failed. Check that the documented parent chain exists."
  start_watcher || warn "Watcher repair failed."

  bridges="$(bridge_inventory)"
  if [[ -n "$bridges" ]]; then
    log "Detected Docker bridges: ${bridges//$'\n'/, }"
  else
    warn "No Docker bridge interfaces detected yet. The watcher will retry after Docker starts."
  fi

  cat <<'HINTS'

If 'inet cloud_dev forward' does not exist, the toolkit intentionally does not
create a competing policy. Review 'nft list ruleset', then set NFT_TABLE and
NFT_PARENT in the config file to the existing table/chain before re-running.

Manual checks:
  ufw status verbose
  nft -a list chain inet cloud_dev vps_docker_forward
  ip -br -4 addr | grep -E 'docker|br-'
  systemctl status vps-firewall-watch.service
  journalctl -u vps-firewall-watch.service -n 100 --no-pager
HINTS
  success "Repair pass completed."
}

restore_nft_ruleset(){
  local file="$1" snapshot
  [[ -f "$file" ]] || { error "Ruleset file not found: ${file}"; return 1; }
  command_exists nft || { error "nft is not installed."; return 1; }
  if ! nft -c -f "$file"; then
    error "Ruleset failed validation; nothing was restored."
    return 1
  fi
  snapshot="$(snapshot_firewall)" || return 1
  warn "Current firewall rules were backed up to ${snapshot}."
  confirm_typed "RESTORE-FIREWALL" || { log "Restore cancelled."; return 0; }
  nft -f "$file" || return 1
  success "Ruleset restored from ${file}. Verify connectivity immediately."
}

recovery_menu(){
  local answer file
  while true; do
    section "Repair and Recovery"
    printf ' 1) Run full repair (config, UFW, nftables, watcher)\n'
    printf ' 2) Repair/initialize configuration only\n'
    printf ' 3) Reinstall persistent firewall watcher\n'
    printf ' 4) Restore a saved nftables ruleset from file\n'
    printf ' 0) Back\n'
    read -r -p "Choose: " answer || return 0
    case "$answer" in
      1) repair_all ;;
      2) repair_config ;;
      3) start_watcher ;;
      4)
        read -r -p "Path to validated .nft ruleset file: " file || continue
        restore_nft_ruleset "$file"
        ;;
      0|q|Q) return 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

recovery_cli(){
  case "${1:-menu}" in
    menu) recovery_menu ;;
    all) repair_all ;;
    config) repair_config ;;
    watcher) start_watcher ;;
    restore) restore_nft_ruleset "${2:-}" ;;
    *) error "Unknown recovery command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  recovery_cli "$@"
fi
