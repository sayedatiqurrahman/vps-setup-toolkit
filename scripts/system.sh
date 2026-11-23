#!/usr/bin/env bash
# system.sh - base utilities, dependency checks and UFW defaults.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

SYSTEM_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi

BASE_PACKAGES=()

base_packages_for_os(){
  case "${PKG_MANAGER:-apt}" in
    apt)
      BASE_PACKAGES=(ca-certificates curl wget gnupg lsb-release jq git ufw nftables iproute2 procps systemd)
      ;;
    dnf|yum|microdnf)
      BASE_PACKAGES=(ca-certificates curl wget gnupg2 jq git firewalld nftables iproute procps-ng systemd)
      ;;
    apk)
      BASE_PACKAGES=(ca-certificates curl wget gnupg jq git ufw nftables iproute2 procps)
      ;;
    pacman)
      BASE_PACKAGES=(ca-certificates curl wget gnupg jq git ufw nftables iproute2 procps systemd)
      ;;
    zypper)
      BASE_PACKAGES=(ca-certificates curl wget gnupg2 jq git firewalld nftables iproute2 procps systemd)
      ;;
    *)
      BASE_PACKAGES=(curl wget git)
      ;;
  esac
}

install_base_packages(){
  require_supported_os || return 1
  base_packages_for_os
  log "Installing base utilities on ${OS_PRETTY} (${ARCH}, ${PKG_MANAGER})."
  pkg_install "${BASE_PACKAGES[@]}" || return 1
  success "Base utilities installed."
}

# Option 1 of the main menu: base utilities plus the documented inbound policy.
base_setup(){
  install_base_packages || return 1
  if command_exists ufw; then
    ufw_init || warn "UFW initialization failed; review the log."
  else
    warn "UFW is not available for ${OS_ID}; host firewall setup was skipped."
    warn "Use your distribution firewall (for example firewalld) before exposing services."
  fi
  init_runtime || true
  success "Base VPS setup complete."
}

ensure_command(){
  local cmd="$1"
  if command_exists "$cmd"; then
    return 0
  fi
  case "$cmd" in
    curl|wget|gpg|gnupg|jq|git|ufw|nft|ip) install_base_packages ;;
    *) pkg_install "$cmd" ;;
  esac
}

system_cli(){
  case "${1:-base}" in
    base) base_setup ;;
    packages) install_base_packages ;;
    ufw) ufw_init ;;
    *) error "Unknown system command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  system_cli "$@"
fi
