#!/usr/bin/env bash
# uninstall.sh - remove the toolkit without touching unrelated firewall rules.
#
# Two modes: keep-config removes only the toolkit files/watcher/launcher and
# preserves configuration, state, logs and firewall rules; all additionally
# removes toolkit-managed firewall rules, configuration, state and logs.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

UNINSTALL_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi

remove_managed_nft(){
  local -a handles=()
  local handle parent_chain_existed=0
  if ! command_exists nft; then
    warn "nft is unavailable; skipping managed chain removal."
    return 0
  fi
  load_config || return 1
  if nft_parent_exists; then
    parent_chain_existed=1
    mapfile -t handles < <(nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" 2>/dev/null \
      | awk -v managed="$NFT_MANAGED" '
          index($0, "jump " managed) && index($0, "VPS-MANAGED-DOCKER-JUMP") {
            for (i = NF; i > 0; i--) if ($i == "#") { print $(i+1); break }
          }')
    for handle in "${handles[@]}"; do
      nft delete rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" handle "$handle" 2>/dev/null || true
    done
  fi
  if nft_managed_exists; then
    nft flush chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" 2>/dev/null || true
    nft delete chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" 2>/dev/null || true
  fi
  if (( parent_chain_existed == 0 )); then
    warn "Parent chain ${NFT_FAMILY} ${NFT_TABLE} ${NFT_PARENT} was not present; no jump to remove."
  fi
  log "Toolkit-owned nftables chain and jump removed (if present)."
}

remove_managed_ufw_egress(){
  local p
  load_config || return 1
  for p in $MANAGED_UFW_TCP; do ufw_delete_out "$p" tcp; done
  for p in $MANAGED_UFW_UDP; do ufw_delete_out "$p" udp; done
  log "Toolkit-managed UFW outbound rules removed (if present)."
}

uninstall_toolkit(){
  local mode="${1:-interactive}" remove_nft=0 remove_ufw=0 remove_data=0 answer
  section "Uninstall VPS Setup Toolkit"
  warn "Installed packages (Docker, Nginx, PHP, Node.js, etc.) are NOT removed."

  if [[ "$mode" == "interactive" ]]; then
    cat <<'UNINST'
 1) Delete only the toolkit (keep configuration, state and logs)
 2) Delete the toolkit with all configuration (config, state, logs and managed firewall rules)
 0) Cancel
UNINST
    read -r -p "Choose an option: " answer || { log "Uninstall cancelled."; return 0; }
    case "$answer" in
      1) mode="keep-config" ;;
      2) mode="all" ;;
      0|q|Q) log "Uninstall cancelled."; return 0 ;;
      *) warn "Invalid choice; nothing was removed."; return 1 ;;
    esac
  fi

  case "$mode" in
    keep-config)
      warn "The toolkit, watcher and launcher will be removed."
      warn "Configuration and existing firewall rules are kept; the watcher will no longer maintain them until you reinstall."
      confirm_typed "UNINSTALL" || { log "Uninstall cancelled."; return 0; }
      ;;
    all)
      warn "This also removes toolkit-managed firewall rules, configuration, state and logs."
      confirm_typed "UNINSTALL" || { log "Uninstall cancelled."; return 0; }
      remove_nft=1
      remove_ufw=1
      remove_data=1
      ;;
    *)
      error "Unknown uninstall mode: ${mode}. Use keep-config or all."
      return 1
      ;;
  esac

  snapshot_firewall >/dev/null || true

  if is_systemd; then
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  remove_cron_watcher
  rm -f -- "$WATCHER_PATH" "$UNIT_PATH" "$WRAPPER_PATH"
  if is_systemd; then systemctl daemon-reload >/dev/null 2>&1 || true; fi

  if (( remove_nft == 1 )); then remove_managed_nft; fi
  if (( remove_ufw == 1 )); then remove_managed_ufw_egress; fi

  if [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" && -d "$INSTALL_DIR" ]]; then
    rm -rf -- "$INSTALL_DIR"
  fi

  if (( remove_data == 1 )); then
    rm -f -- "$CONF_FILE" "$INBOUND_RULES_FILE" "$NFT_STATE_FILE"
    rm -rf -- "$STATE_DIR" "$LOG_DIR"
  fi

  if (( remove_data == 1 )); then
    success "Toolkit and all of its configuration were removed. Remove the installer script separately if desired."
  else
    success "Toolkit removed; configuration, state and logs were kept. Remove the installer script separately if desired."
    log "Existing firewall rules were left in place by design."
  fi
}

uninstall_cli(){
  case "${1:-uninstall}" in
    uninstall) uninstall_toolkit ;;
    keep-config|only|files) uninstall_toolkit keep-config ;;
    all|purge|config) uninstall_toolkit all ;;
    *) error "Unknown uninstall command: $1. Use uninstall, keep-config or all."; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  uninstall_cli "$@"
fi
