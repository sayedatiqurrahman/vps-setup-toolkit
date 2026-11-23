#!/usr/bin/env bash
# pm2.sh - global PM2 process manager installation.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

PM2_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi

pm2_install(){
  if ! command_exists npm; then
    error "npm is required for PM2. Install Node.js and PM2 first."
    return 1
  fi
  if command_exists pm2; then
    log "PM2 already installed: $(pm2 --version 2>/dev/null)."
    return 0
  fi
  log "Installing PM2 globally with npm."
  npm install -g pm2 || return 1
  pm2 --version || return 1
  log "To enable PM2 at boot, review and run: pm2 startup"
  success "PM2 installed."
}

pm2_cli(){
  case "${1:-install}" in
    install) pm2_install ;;
    *) error "Unknown pm2 command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  pm2_cli "$@"
fi
