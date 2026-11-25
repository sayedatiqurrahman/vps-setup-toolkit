#!/usr/bin/env bash
# dokploy.sh - launch the official Dokploy installer after explicit review.
#
# Dokploy changes Docker/Traefik networking. It is never installed together
# with Coolify automatically; the main menu warns when both are selected.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

DOKPLOY_LOADED=1
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

DOKPLOY_INSTALLER_URL="https://dokploy.com/install.sh"

dokploy_install(){
  local answer ingress ip bridge installer_tmp checksum
  require_supported_os || return 1

  if ! docker info >/dev/null 2>&1; then
    warn "Docker is required before Dokploy."
    if confirm "Install Docker Engine first?"; then
      # shellcheck source=docker.sh
      source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/docker.sh"
      docker_install || return 1
    else
      return 1
    fi
  fi

  warn "Dokploy's upstream installer changes Docker, Traefik and possibly firewall rules."
  warn "Review it at ${DOKPLOY_INSTALLER_URL} before continuing."
  confirm_typed "INSTALL-DOKPLOY" || { log "Dokploy launch cancelled."; return 0; }

  ensure_command curl || return 1
  installer_tmp="$(mktemp)" || return 1
  if ! curl -fsSL "$DOKPLOY_INSTALLER_URL" -o "$installer_tmp"; then
    error "Failed to download the Dokploy installer."
    rm -f -- "$installer_tmp"
    return 1
  fi
  checksum="$(sha256sum "$installer_tmp" 2>/dev/null | awk '{print $1}')"
  log "Dokploy installer downloaded (SHA-256: ${checksum:-unavailable}). Run: sh <downloaded file>"
  if ! confirm "Execute the downloaded Dokploy installer now?"; then
    rm -f -- "$installer_tmp"
    log "Dokploy launch cancelled before execution."
    return 0
  fi
  if ! sh "$installer_tmp"; then
    error "The Dokploy installer reported a failure."
    rm -f -- "$installer_tmp"
    return 1
  fi
  rm -f -- "$installer_tmp"

  docker_swarm_ensure || warn "Docker Swarm could not be initialized; Dokploy overlay networking may be limited."
  network_enable_for_docker "${VPS_SETUP_INTERACTIVE:-1}" || warn "Container network auto-repair could not be enabled."

  read -r -p "Enable managed HTTP/HTTPS forwarding to Traefik? [y/N]: " ingress || ingress=""
  if [[ "$ingress" =~ ^[Yy]$ ]]; then
    load_config || return 1
    read -r -p "Traefik bridge [${TRAEFIK_BRIDGE}]: " bridge || bridge=""
    bridge="${bridge//[[:space:]]/}"
    [[ -n "$bridge" ]] && TRAEFIK_BRIDGE="$bridge"
    read -r -p "Traefik IPv4 [${TRAEFIK_IP}]: " ip || ip=""
    ip="${ip//[[:space:]]/}"
    [[ -n "$ip" ]] && TRAEFIK_IP="$ip"
    if [[ ! "$TRAEFIK_BRIDGE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]] || ! valid_ipv4 "$TRAEFIK_IP"; then
      error "Invalid Traefik bridge/IP; ingress was not enabled."
      return 1
    fi
    ENABLE_DOKPLOY_INGRESS=1
    save_config || return 1
    nft_apply || warn "Ingress rules could not be applied now; the watcher will retry."
  fi
  start_watcher || warn "Watcher installation failed; use Repair and Recovery."
  success "Dokploy launch finished."
}

dokploy_cli(){
  case "${1:-install}" in
    install) dokploy_install ;;
    *) error "Unknown dokploy command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  dokploy_cli "$@"
fi
