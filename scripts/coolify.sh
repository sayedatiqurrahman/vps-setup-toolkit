#!/usr/bin/env bash
# coolify.sh - launch the official Coolify installer after explicit review.
#
# Coolify is never installed together with Dokploy automatically.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

COOLIFY_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi
if [[ -z "${NETWORK_LOADED:-}" ]]; then
  # shellcheck source=network.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/network.sh"
fi

COOLIFY_INSTALLER_URL="https://cdn.coollabs.io/coolify/install.sh"

coolify_install(){
  local installer_tmp checksum
  require_supported_os || return 1

  if ! docker info >/dev/null 2>&1; then
    warn "Docker is required before Coolify."
    if confirm "Install Docker Engine first?"; then
      # shellcheck source=docker.sh
      source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/docker.sh"
      docker_install || return 1
    else
      return 1
    fi
  fi

  warn "Coolify's upstream installer changes Docker and firewall configuration."
  warn "Review it at ${COOLIFY_INSTALLER_URL} before continuing."
  warn "Do not run Dokploy and Coolify on the same VPS unless you know how to integrate them."
  confirm_typed "INSTALL-COOLIFY" || { log "Coolify launch cancelled."; return 0; }

  ensure_command curl || return 1
  installer_tmp="$(mktemp)" || return 1
  if ! curl -fsSL "$COOLIFY_INSTALLER_URL" -o "$installer_tmp"; then
    error "Failed to download the Coolify installer."
    rm -f -- "$installer_tmp"
    return 1
  fi
  checksum="$(sha256sum "$installer_tmp" 2>/dev/null | awk '{print $1}')"
  log "Coolify installer downloaded (SHA-256: ${checksum:-unavailable}). Run: bash <downloaded file>"
  if ! confirm "Execute the downloaded Coolify installer now?"; then
    rm -f -- "$installer_tmp"
    log "Coolify launch cancelled before execution."
    return 0
  fi
  if ! bash "$installer_tmp"; then
    error "The Coolify installer reported a failure."
    rm -f -- "$installer_tmp"
    return 1
  fi
  rm -f -- "$installer_tmp"

  docker_swarm_ensure || warn "Docker Swarm could not be initialized; overlay networking may be unavailable."
  network_enable_for_docker "${VPS_SETUP_INTERACTIVE:-1}" || warn "Container network auto-repair could not be enabled."
  start_watcher || warn "Watcher installation failed; use Repair and Recovery."
  # Smart default for panels: web, DNS, mail, object storage, SSH and monitoring
  # egress for both the VPS host and Docker containers. No inbound port opens.
  unified_smart_configure hosting 1 || warn "Smart outbound service configuration was deferred."
  success "Coolify launch finished."
}

coolify_cli(){
  case "${1:-install}" in
    install) coolify_install ;;
    *) error "Unknown coolify command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  coolify_cli "$@"
fi
