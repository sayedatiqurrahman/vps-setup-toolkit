#!/usr/bin/env bash
# php.sh - PHP-FPM and common extensions for generic PHP apps and WordPress.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

PHP_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi

PHP_MODULES=(mysql curl gd mbstring xml zip intl bcmath)

available_php_versions(){
  command_exists apt-cache || return 0
  apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null \
    | sed -nE 's/^(php[0-9]+\.[0-9]+)-fpm.*/\1/p' \
    | sed 's/^php//' \
    | sort -Vu
}

php_install(){
  local version="${PHP_VERSION:-}" answer prefix service packages=() module detected=""
  local -a versions=()
  require_supported_os || return 1

  if [[ "$OS_FAMILY" == "debian" && -z "$version" ]]; then
    if command_exists apt-cache; then
      mapfile -t versions < <(available_php_versions)
      if (( ${#versions[@]} > 1 )) && [[ -t 0 && -z "${PHP_VERSION:-}" ]]; then
        printf '\nAvailable PHP versions: %s\n' "${versions[*]}"
        read -r -p "PHP version (blank = distribution default): " answer || answer=""
        answer="${answer//[[:space:]]/}"
        [[ -n "$answer" ]] && version="$answer"
      fi
    fi
  fi

  if [[ -n "$version" ]]; then
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
      error "Invalid PHP version '${version}' (expected X.Y)."
      return 1
    fi
    prefix="php${version}"
  else
    prefix="php"
  fi

  if [[ "$OS_FAMILY" == "debian" ]]; then
    for module in "${PHP_MODULES[@]}"; do
      packages+=("${prefix}-${module}")
    done
    packages+=("${prefix}-fpm" "${prefix}-cli")
  else
    # RPM/Alpine/Arch packages use different PHP extension names. pkg_install
    # checks each package and warns about names that do not exist.
    packages=(php-fpm php-cli php-mysqlnd php-mysql php-mysqli php-curl php-gd
      php-mbstring php-xml php-zip php-intl php-bcmath)
  fi

  log "Installing PHP-FPM packages: ${packages[*]}"
  pkg_install "${packages[@]}" || return 1

  if [[ -n "$version" ]]; then
    service="php${version}-fpm"
  else
    service="php-fpm"
    if command_exists systemctl; then
      detected="$(systemctl list-unit-files 'php*-fpm.service' 2>/dev/null | awk '/php.*-fpm\.service/ { print $1; exit }')"
      [[ -n "$detected" ]] && service="$detected"
    fi
  fi
  service_enable "$service" || warn "Could not enable '${service}'; check the installed PHP service name."

  if command_exists php; then php --version; fi
  success "PHP-FPM setup complete."
}

php_cli(){
  case "${1:-install}" in
    install) php_install ;;
    *) error "Unknown php command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  php_cli "$@"
fi
