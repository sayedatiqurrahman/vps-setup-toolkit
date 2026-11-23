#!/usr/bin/env bash
# docker.sh - Docker Engine, Compose plugin and firewall watcher integration.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

DOCKER_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi

docker_installed(){ command_exists docker && docker info >/dev/null 2>&1; }
docker_compose_installed(){ command_exists docker && docker compose version >/dev/null 2>&1; }

docker_install_debian_repo(){
  local keyring="/etc/apt/keyrings/docker.asc"
  local sources="/etc/apt/sources.list.d/docker.list"
  local key_tmp repo_tmp repo_line repo_arch

  case "$ARCH" in
    amd64|arm64|armhf|i386|riscv64|s390x) repo_arch="$ARCH" ;;
    *) error "Unsupported Docker architecture: ${ARCH}"; return 1 ;;
  esac
  [[ -n "$OS_CODENAME" ]] || { error "Cannot determine distribution codename."; return 1; }
  ensure_command curl || return 1

  pkg_install ca-certificates curl gnupg || return 1
  install -d -m 0755 /etc/apt/keyrings || return 1

  key_tmp="$(mktemp)" || return 1
  if ! curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o "$key_tmp"; then
    error "Failed to download Docker GPG key."
    rm -f -- "$key_tmp"
    return 1
  fi
  backup_file "$keyring" || { rm -f -- "$key_tmp"; return 1; }
  install -m 0644 -- "$key_tmp" "$keyring" || { rm -f -- "$key_tmp"; return 1; }
  rm -f -- "$key_tmp"

  repo_line="deb [arch=${repo_arch} signed-by=${keyring}] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable"
  repo_tmp="$(mktemp)" || return 1
  printf '%s\n' "$repo_line" >"$repo_tmp"
  install_file "$repo_tmp" "$sources" 0644 || { rm -f -- "$repo_tmp"; return 1; }
  rm -f -- "$repo_tmp"

  pkg_update_once || return 1
  log "Installing Docker Engine packages from the signed ${OS_ID} repository."
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin || return 1
}

docker_install_other_os(){
  warn "Signed Docker apt repository setup only applies to Debian/Ubuntu family systems."
  warn "Detected family '${OS_FAMILY}' with package manager '${PKG_MANAGER}'."
  if [[ "${ALLOW_UNSUPPORTED_OS:-0}" != "1" ]]; then
    error "Set ALLOW_UNSUPPORTED_OS=1 to attempt a distribution-package install, or install Docker manually."
    return 1
  fi
  case "$PKG_MANAGER" in
    dnf|yum|microdnf) pkg_install docker docker-cli docker-compose-plugin docker-compose ;;
    apk) pkg_install docker docker-cli docker-compose ;;
    pacman) pkg_install docker docker-compose ;;
    zypper) pkg_install docker docker-compose ;;
    *) error "No package manager strategy for ${PKG_MANAGER}."; return 1 ;;
  esac || return 1
  warn "Distribution Docker packages may be older; verify 'docker compose version' after installation."
}

docker_install(){
  require_supported_os || return 1

  if docker_installed && docker_compose_installed; then
    log "Docker Engine and Compose plugin are already installed; skipping repository setup."
  else
    if [[ "$OS_FAMILY" == "debian" ]]; then
      docker_install_debian_repo || return 1
    else
      docker_install_other_os || return 1
    fi
  fi

  service_enable docker || warn "Could not start the docker service automatically."

  # Docker bridge creation changes the interfaces this toolkit must reconcile.
  start_watcher || warn "Firewall watcher installation failed."
  if command_exists docker; then
    docker version 2>/dev/null || true
    docker compose version 2>/dev/null || true
  fi
  success "Docker Engine setup complete."
}

docker_status(){
  section "Docker"
  if command_exists docker; then
    docker version 2>/dev/null || warn "Docker daemon is not reachable."
    docker compose version 2>/dev/null || true
  else
    printf 'Docker is not installed.\n'
  fi
  bridge_inventory || true
}

docker_cli(){
  case "${1:-install}" in
    install) docker_install ;;
    status) docker_status ;;
    *) error "Unknown docker command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  docker_cli "$@"
fi
