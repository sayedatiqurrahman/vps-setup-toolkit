#!/usr/bin/env bash
# menu.sh - unified interactive entry point for the VPS Setup Toolkit.

set -Eeuo pipefail

# shellcheck source=scripts/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/scripts/common.sh"

# All module names are a fixed internal list; no user input is involved.
for _module in system firewall docker network nodejs pm2 php nginx wordpress dokploy coolify security recovery status uninstall; do
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/${_module}.sh"
done
unset _module

trap 'error "Unexpected error at line ${LINENO}: ${BASH_COMMAND}"' ERR

ACTION_NAMES=(
  ""
  "Base VPS Setup"
  "Node.js and PM2"
  "Docker Engine"
  "Dokploy"
  "Coolify"
  "PHP and Nginx"
  "WordPress Requirements"
  "SSH Security"
  "Firewall and Service Port Manager"
  "Custom Port Configuration"
  "Repair and Recovery"
  "System Status"
  "Uninstall Toolkit"
  "Container Network Doctor"
)

print_menu(){
  cat <<'MENU'

========== VPS SETUP MENU ==========
  1) Base VPS Setup
  2) Node.js and PM2
  3) Docker Engine
  4) Dokploy
  5) Coolify
  6) PHP and Nginx
  7) WordPress Requirements
  8) SSH Security
  9) Firewall and Service Port Manager
 10) Custom Port Configuration
 11) Repair and Recovery
 12) System Status
 13) Uninstall Toolkit
 14) Container Network Doctor
  0) Exit

Enter one number or several separated by commas (example: 2,3,4,9).
MENU
}

print_selection_summary(){
  local id
  section "Selected operations"
  for id in "$@"; do
    printf '  %2s) %s\n' "$id" "${ACTION_NAMES[$id]}"
  done
  printf '\nNo operation is performed without confirmation.\n'
  if list_contains 4 "$@" && list_contains 5 "$@"; then
    warn "Dokploy and Coolify are both selected. They are never installed together automatically."
    warn "Continue only if you intend to integrate both panels yourself."
    if ! confirm_typed "BOTH-PANELS-INTENTIONAL"; then
      log "Dual-panel selection cancelled."
      return 1
    fi
  fi
  if list_contains 13 "$@"; then
    warn "Uninstall is selected; the toolkit will be removed from this server."
  fi
  return 0
}

# Install/config operations that need working firewall rules before they run.
is_service_action(){
  case "$1" in 1|2|3|4|5|6|7|8) return 0 ;; *) return 1 ;; esac
}

selection_has_service_actions(){
  local id
  for id in "$@"; do
    is_service_action "$id" && return 0
  done
  return 1
}

run_action(){
  case "$1" in
    1) base_setup ;;
    2) nodejs_install; pm2_install ;;
    3) docker_install ;;
    4) dokploy_install ;;
    5) coolify_install ;;
    6) php_install; nginx_install ;;
    7) wordpress_prereqs ;;
    8) security_menu ;;
    9) service_selector ;;
    10) custom_host_inbound ;;
    11) recovery_menu ;;
    12) system_status ;;
    13) uninstall_toolkit ;;
    14) network_menu ;;
    *) error "Unknown action id: $1"; return 1 ;;
  esac
}

execute_selection(){
  local id failed=0
  for id in "$@"; do
    section "Running ${id}: ${ACTION_NAMES[$id]}"
    if run_action "$id"; then
      success "${ACTION_NAMES[$id]} completed."
    else
      error "${ACTION_NAMES[$id]} reported a failure."
      failed=$((failed + 1))
    fi
  done
  if (( failed > 0 )); then
    error "${failed} selected operation(s) reported failures. Review the log: ${LOG_FILE}"
    return 1
  fi
  success "All selected operations completed."
}

main_menu(){
  local answer
  while true; do
    print_menu
    read -r -p "Choose an option: " answer || exit 0
    answer="${answer//[[:space:]]/}"
    case "$answer" in
      0|q|Q) log "Exiting."; exit 0 ;;
    esac
    if ! parse_menu_selection "$answer" 14; then
      warn "Invalid selection (${MENU_PARSE_ERROR}). Use numbers 0-14, comma-separated."
      continue
    fi
    if print_selection_summary "${MENU_IDS[@]}"; then
      if confirm "Proceed with the selected operations?"; then
        if selection_has_service_actions "${MENU_IDS[@]}"; then
          firewall_preflight 1 "${MENU_IDS[@]}" || warn "Firewall preflight reported a problem."
        fi
        execute_selection "${MENU_IDS[@]}" || warn "Some operations failed; returning to menu."
        if selection_has_service_actions "${MENU_IDS[@]}"; then
          firewall_postflight 1 || warn "Firewall post-configuration reported a problem."
        fi
      else
        log "Selection cancelled; no changes made."
      fi
    fi
  done
}

usage(){
  cat <<USAGE
VPS Setup Toolkit v${APP_VERSION}

Usage:
  vps-setup                    Interactive main menu
  vps-setup menu               Interactive main menu
  vps-setup run 2,3,9 --yes    Run selected categories without prompts
  vps-setup status             Read-only system/firewall status
  vps-setup firewall STATUS    Firewall subcommand (select|apply|status|...)
  vps-setup network STATUS     Container Network Doctor (status|diagnose|test|...)
  vps-setup uninstall MODE     Uninstall (keep-config|all; no arg = prompt)
  vps-setup --version          Print version
  vps-setup --help             Show this help

Non-interactive runs require --yes, which is the explicit confirmation.
Service runs configure UFW/nftables first and apply the standard outbound
service preset afterwards. Set VPS_SETUP_SKIP_FIREWALL=1 to opt out.
USAGE
}

# Show the brand banner first for every normal invocation. Keep --version
# clean so scripts can parse it.
case "${1:-menu}" in
  --version|-V|version) printf '%s\n' "$APP_VERSION"; exit 0 ;;
esac
print_banner

case "${1:-menu}" in
  --help|-h|help) usage; exit 0 ;;
  --version|-V|version) printf '%s\n' "$APP_VERSION"; exit 0 ;;
  menu)
    need_root
    init_runtime
    main_menu
    ;;
  run)
    need_root
    init_runtime
    selection="${2:-}"
    shift $(( $# >= 2 ? 2 : 1 ))
    auto_confirm=0
    if [[ "${1:-}" == "--yes" ]]; then auto_confirm=1; shift; fi
    if (( auto_confirm != 1 )); then
      error "Non-interactive runs require explicit confirmation: vps-setup run <ids> --yes"
      exit 1
    fi
    parse_menu_selection "$selection" 14 || die "Invalid selection (${MENU_PARSE_ERROR})."
    print_selection_summary "${MENU_IDS[@]}" || die "Selection rejected."
    VPS_SETUP_INTERACTIVE=0
    if selection_has_service_actions "${MENU_IDS[@]}" && [[ "${VPS_SETUP_SKIP_FIREWALL:-0}" != "1" ]]; then
      firewall_preflight 0 "${MENU_IDS[@]}" || warn "Firewall preflight reported a problem."
    fi
    execute_selection "${MENU_IDS[@]}"
    if selection_has_service_actions "${MENU_IDS[@]}" && [[ "${VPS_SETUP_SKIP_FIREWALL:-0}" != "1" ]]; then
      firewall_postflight 0 || warn "Firewall post-configuration reported a problem."
    fi
    ;;
  status)
    need_root
    init_runtime
    system_status
    ;;
  firewall)
    need_root
    init_runtime
    shift
    firewall_cli "$@"
    ;;
  network)
    need_root
    init_runtime
    shift
    network_cli "$@"
    ;;
  uninstall)
    need_root
    init_runtime
    shift
    uninstall_cli "$@"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
