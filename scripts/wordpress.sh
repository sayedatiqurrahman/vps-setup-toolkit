#!/usr/bin/env bash
# wordpress.sh - WordPress prerequisites only. WordPress itself is deployed
# separately, as stated in the original setup guide.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

WORDPRESS_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${NGINX_LOADED:-}" ]]; then
  # shellcheck source=nginx.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/nginx.sh"
fi
if [[ -z "${PHP_LOADED:-}" ]]; then
  # shellcheck source=php.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/php.sh"
fi

WORDPRESS_PHP_MODULES=(mysqli curl gd mbstring xml zip intl bcmath)

wordpress_prereqs(){
  local module missing=""
  nginx_install || return 1
  php_install || return 1

  if command_exists php; then
    for module in "${WORDPRESS_PHP_MODULES[@]}"; do
      php -m 2>/dev/null | grep -qi "^${module}$" || missing+="${module} "
    done
    if [[ -n "$missing" ]]; then
      warn "These PHP extensions were not detected: ${missing}"
      warn "Install them (for example php-mysql/php-mysqli) before running WordPress."
    fi
  fi

  cat <<'NOTES'

WordPress is intentionally NOT downloaded or configured by this toolkit.
Next steps (manual or via your deployment tooling):
  1. Create a database and user in MySQL/MariaDB.
  2. Add an nginx server block pointing at the WordPress document root.
  3. Configure PHP-FPM in that server block.
  4. Download WordPress and complete the web installer.
  5. Keep the database private; never open 3306 publicly on this VPS.
NOTES
  success "WordPress prerequisites are ready."
}

wordpress_cli(){
  case "${1:-install}" in
    install) wordpress_prereqs ;;
    *) error "Unknown wordpress command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  wordpress_cli "$@"
fi
