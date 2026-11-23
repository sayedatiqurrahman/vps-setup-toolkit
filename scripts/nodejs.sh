#!/usr/bin/env bash
# nodejs.sh - install Node.js from NodeSource, npm and optionally pnpm.
#
# The original guide installs Node.js 22.x. This module keeps 22.x as the
# default but also supports 18.x and 20.x for applications that need them.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

NODEJS_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi

NODEJS_SUPPORTED_VERSIONS=(18 20 22)

nodejs_installed(){ command_exists node && command_exists npm; }

nodejs_install(){
  local version="${NODEJS_VERSION:-22}" answer setup_tmp
  require_supported_os || return 1
  if [[ "$OS_FAMILY" != "debian" && "$OS_FAMILY" != "rhel" && "${ALLOW_UNSUPPORTED_OS:-0}" != "1" ]]; then
    error "NodeSource setup is only attempted for Debian/RPM families here. Set ALLOW_UNSUPPORTED_OS=1 to try it anyway."
    return 1
  fi

  if nodejs_installed; then
    log "Node.js/npm already present: $(node --version 2>/dev/null) / $(npm --version 2>/dev/null)."
  else
    if [[ -t 0 && -z "${NODEJS_VERSION:-}" ]]; then
      printf '\nAvailable Node.js versions: 18, 20, 22 (default: 22)\n'
      read -r -p "Node.js major version [22]: " answer || answer=""
      answer="${answer//[[:space:]]/}"
      [[ -n "$answer" ]] && version="$answer"
    fi
    if ! list_contains "$version" "${NODEJS_SUPPORTED_VERSIONS[@]}"; then
      error "Unsupported Node.js version '${version}'. Choose 18, 20 or 22."
      return 1
    fi
    ensure_command curl || return 1
    setup_tmp="$(mktemp)" || return 1
    if ! curl -fsSL "https://deb.nodesource.com/setup_${version}.x" -o "$setup_tmp"; then
      error "Failed to download the NodeSource setup script."
      rm -f -- "$setup_tmp"
      return 1
    fi
    log "Running NodeSource setup script for Node.js ${version}.x (downloaded to a temp file, not piped)."
    if ! bash "$setup_tmp"; then
      error "NodeSource setup failed."
      rm -f -- "$setup_tmp"
      return 1
    fi
    rm -f -- "$setup_tmp"
    pkg_install nodejs || return 1
  fi

  if command_exists npm && ! command_exists pnpm; then
    if confirm "Install pnpm globally?"; then
      npm install -g pnpm || warn "pnpm installation failed."
    fi
  fi

  if command_exists node && command_exists npm; then
    printf 'node: %s\nnpm:  %s\n' "$(node --version)" "$(npm --version)"
  fi
  success "Node.js setup complete."
}

nodejs_cli(){
  case "${1:-install}" in
    install) nodejs_install ;;
    *) error "Unknown nodejs command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  nodejs_cli "$@"
fi
