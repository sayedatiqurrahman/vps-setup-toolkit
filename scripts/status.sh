#!/usr/bin/env bash
# status.sh - read-only system and toolkit status report.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

STATUS_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi

component_status(){
  local component
  section "Installed components"
  for component in docker node npm pnpm pm2 nginx php ufw nft ip fail2ban curl git; do
    if command_exists "$component"; then
      printf '%-10s %s\n' "$component" 'installed'
    else
      printf '%-10s %s\n' "$component" 'not found'
    fi
  done
  if is_systemd; then
    section "Services"
    local service
    for service in docker nginx fail2ban "$UNIT_NAME"; do
      printf '%-28s %s\n' "$service" "$(systemctl is-active "$service" 2>/dev/null || printf 'unknown')"
    done
  fi
}

system_status(){
  detect_os
  section "System"
  printf 'Hostname    : %s\n' "$(hostname 2>/dev/null || printf 'unknown')"
  printf 'OS          : %s\n' "$OS_PRETTY"
  printf 'ID/version  : %s %s (%s)\n' "$OS_ID" "$OS_VERSION" "$OS_CODENAME"
  printf 'Architecture: %s\n' "$ARCH"
  printf 'OS family   : %s\n' "$OS_FAMILY"
  printf 'Package mgr : %s\n' "$PKG_MANAGER"
  printf 'Init system : %s\n' "$INIT_SYSTEM"
  printf 'Kernel      : %s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
  printf 'Uptime      : %s\n' "$(uptime -p 2>/dev/null || uptime 2>/dev/null || printf 'unknown')"
  printf 'Toolkit     : v%s at %s\n' "$APP_VERSION" "$INSTALL_DIR"
  component_status
  show_configured_rules
}

status_cli(){
  case "${1:-status}" in
    status) system_status ;;
    components) component_status ;;
    firewall) show_configured_rules ;;
    *) error "Unknown status command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  status_cli "$@"
fi
