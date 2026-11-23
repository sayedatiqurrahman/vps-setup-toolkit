#!/usr/bin/env bash
# nginx.sh - web server installation (configuration is never overwritten).

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

NGINX_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi

nginx_install(){
  require_supported_os || return 1
  pkg_install nginx || return 1
  if command_exists nginx; then
    nginx -t 2>/dev/null || warn "Existing nginx configuration does not pass 'nginx -t'."
  fi
  service_enable nginx || warn "Could not enable the nginx service automatically."
  success "Nginx installed/enabled. Existing site configurations were not modified."
}

nginx_cli(){
  case "${1:-install}" in
    install) nginx_install ;;
    *) error "Unknown nginx command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  nginx_cli "$@"
fi
