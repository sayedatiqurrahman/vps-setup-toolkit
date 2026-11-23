#!/usr/bin/env bash
# security.sh - SSH audit/optional hardening and Fail2ban.
#
# SSH settings are never changed automatically. The original guide gives
# hardening suggestions only and explicitly forbids automatic port changes.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

SECURITY_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi

SSHD_CONFIG="/etc/ssh/sshd_config"

ssh_security_notes(){
  cat <<'NOTES'

SSH security checklist (manual review recommended):
- Keep a second SSH session open before changing sshd settings.
- Use SSH keys and test key login before disabling password authentication.
- Validate configuration with: sshd -t
- Reload with: systemctl reload ssh
- Do not change the SSH port unless the matching firewall rule is added first.
- Keep root login policy intentional; do not lock yourself out.
- Never expose Docker API ports 2375/2376 to the public Internet.
NOTES
}

ssh_audit(){
  section "SSH audit (read-only)"
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    printf 'sshd_config not found at %s\n' "$SSHD_CONFIG"
    return 0
  fi
  if command_exists sshd; then
    if sshd -t >/dev/null 2>&1; then
      printf 'sshd configuration syntax: OK\n'
    else
      warn "sshd -t reported a configuration problem."
    fi
    local setting
    for setting in port permitrootlogin passwordauthentication pubkeyauthentication; do
      sshd -T 2>/dev/null | awk -v key="$setting" '$1 == key { print key ": " $2; exit }'
    done
  else
    printf 'sshd binary not available; showing raw directives:\n'
    grep -Ei '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)[[:space:]]' "$SSHD_CONFIG" || true
  fi
  if [[ -s /root/.ssh/authorized_keys ]]; then
    printf 'Root authorized_keys: present\n'
  else
    printf 'Root authorized_keys: absent\n'
  fi
  ssh_security_notes
}

# Replace one sshd directive in a copied config file. Uses awk, not eval.
set_sshd_directive(){
  local src="$1" dest="$2" key="$3" value="$4"
  awk -v key="$key" -v value="$value" '
    {
      line = $0
      sub(/^[[:space:]]*#[[:space:]]*/, "", line)
      split(line, fields, /[[:space:]]+/)
      if (tolower(fields[1]) == tolower(key)) next
      print $0
    }
    END { print key " " value }
  ' "$src" >"$dest"
}

ssh_harden_optional(){
  local answer tmp candidate directive value service has_key=0
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    error "sshd_config not found; nothing to change."
    return 1
  fi
  if [[ -s /root/.ssh/authorized_keys || -s "${HOME:-/root}/.ssh/authorized_keys" ]]; then
    has_key=1
  fi
  if (( has_key == 0 )); then
    warn "No authorized_keys found for root or ${USER:-current user}; password authentication must stay enabled."
    warn "Refusing automated hardening that could lock you out of SSH."
    ssh_security_notes
    return 0
  fi

  section "Optional SSH hardening"
  printf ' a) Set PermitRootLogin prohibit-password\n'
  printf ' b) Set PasswordAuthentication no (requires working key login)\n'
  printf ' 0) Back / no changes\n'
  read -r -p "Choose: " answer || return 0
  case "$answer" in
    a|A) directive="PermitRootLogin"; value="prohibit-password" ;;
    b|B)
      if (( has_key == 0 )); then error "Key login is required."; return 1; fi
      confirm_typed "DISABLE-PASSWORD-AUTH" || { log "SSH hardening cancelled."; return 0; }
      directive="PasswordAuthentication"; value="no"
      ;;
    0|q|Q) return 0 ;;
    *) warn "Invalid choice."; return 1 ;;
  esac

  tmp="$(mktemp)" || return 1
  candidate="$(mktemp)" || return 1
  if ! cp -p -- "$SSHD_CONFIG" "$tmp"; then rm -f "$tmp" "$candidate"; return 1; fi
  set_sshd_directive "$tmp" "$candidate" "$directive" "$value" || { rm -f "$tmp" "$candidate"; return 1; }
  if ! sshd -t -f "$candidate"; then
    error "Proposed sshd configuration failed validation; original file was not modified."
    rm -f "$tmp" "$candidate"
    return 1
  fi
  backup_file "$SSHD_CONFIG" || { rm -f "$tmp" "$candidate"; return 1; }
  install -m 0600 -- "$candidate" "$SSHD_CONFIG" || { rm -f "$tmp" "$candidate"; return 1; }
  rm -f "$tmp" "$candidate"
  service="$(ssh_service_name)"
  service_reload "$service" 2>/dev/null || warn "Could not reload ${service}; reload SSH manually."
  success "SSH setting applied: ${directive} ${value}. The SSH port was not changed."
}

fail2ban_install(){
  local jail_tmp jail_file="/etc/fail2ban/jail.d/vps-setup.conf" backend logpath=""
  require_supported_os || return 1
  pkg_install fail2ban || return 1
  jail_tmp="$(mktemp)" || return 1
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    backend="systemd"
  else
    backend="auto"
    logpath="logpath = %(sshd_log)s"
  fi
  {
    printf '%s\n' '# Managed by VPS Setup Toolkit. Existing jail files are not modified.'
    printf '%s\n' '[sshd]' 'enabled = true' 'port = ssh' "backend = ${backend}"
    if [[ -n "$logpath" ]]; then printf '%s\n' "$logpath"; fi
    printf '%s\n' 'maxretry = 5' 'bantime = 1h' 'findtime = 10m'
  } >"$jail_tmp"
  if ! install_file "$jail_tmp" "$jail_file" 0644; then rm -f "$jail_tmp"; return 1; fi
  rm -f "$jail_tmp"
  service_enable fail2ban || warn "Could not enable fail2ban automatically; start it manually."
  success "Fail2ban installed with an SSH jail."
}

security_menu(){
  local answer
  while true; do
    section "SSH security and server hardening"
    printf ' 1) SSH security checklist and read-only audit\n'
    printf ' 2) Optional SSH hardening (explicit confirmation, no port change)\n'
    printf ' 3) Install/configure Fail2ban\n'
    printf ' 0) Back\n'
    read -r -p "Choose: " answer || return 0
    case "$answer" in
      1) ssh_audit ;;
      2) ssh_harden_optional ;;
      3) fail2ban_install ;;
      0|q|Q) return 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

security_cli(){
  case "${1:-menu}" in
    menu) security_menu ;;
    notes) ssh_security_notes ;;
    audit) ssh_audit ;;
    harden) ssh_harden_optional ;;
    fail2ban) fail2ban_install ;;
    *) error "Unknown security command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  security_cli "$@"
fi
