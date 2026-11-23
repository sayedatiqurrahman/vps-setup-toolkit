#!/usr/bin/env bash
# firewall.sh - outbound service selection, UFW management, and the
# toolkit-owned nftables chain for Docker bridge forwarding.
#
# Design rules inherited from complete-vps-setup-security-guide.md:
#   * never flush the whole nftables ruleset;
#   * never replace a user's table, chain or FORWARD policy;
#   * only the dedicated managed chain is flushed;
#   * no full jump-ruleset duplication; one guarded jump from an existing chain;
#   * inbound and outbound configuration stay completely separate.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

FIREWALL_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi

# Defaults from the original guide. They may be overridden in the config file.
NFT_FAMILY="inet"
NFT_TABLE="cloud_dev"
NFT_PARENT="forward"
NFT_MANAGED="vps_docker_forward"
WAN_IF=""
WATCH_INTERVAL=15

TCP_EGRESS_PORTS=""
UDP_EGRESS_PORTS=""
SELECTED_SERVICE_IDS=""
CUSTOM_TCP_PORTS=""
CUSTOM_UDP_PORTS=""
MANAGED_UFW_TCP=""
MANAGED_UFW_UDP=""
ENABLE_DOKPLOY_INGRESS=0
TRAEFIK_IP="10.0.2.2"
TRAEFIK_BRIDGE="docker_gwbridge"

NFT_RULES=()

# ---------------------------------------------------------------------------
# Persistent configuration
# ---------------------------------------------------------------------------

filter_ports(){
  local input="$1" item out=""
  for item in $input; do
    if valid_port "$item"; then
      out+="$((10#$item)) "
    else
      warn "Ignoring invalid port '${item}' from saved configuration."
    fi
  done
  normalize_ports "$out"
}

load_config(){
  TCP_EGRESS_PORTS=""
  UDP_EGRESS_PORTS=""
  SELECTED_SERVICE_IDS=""
  CUSTOM_TCP_PORTS=""
  CUSTOM_UDP_PORTS=""
  MANAGED_UFW_TCP=""
  MANAGED_UFW_UDP=""
  ENABLE_DOKPLOY_INGRESS=0
  TRAEFIK_IP="10.0.2.2"
  TRAEFIK_BRIDGE="docker_gwbridge"
  NFT_FAMILY="inet"
  NFT_TABLE="cloud_dev"
  NFT_PARENT="forward"
  NFT_MANAGED="vps_docker_forward"
  WAN_IF=""
  WATCH_INTERVAL=15

  if [[ -f "$CONF_FILE" ]]; then
    # The config file is root-owned and mode 0600; values are still validated.
    # shellcheck disable=SC1090
    . "$CONF_FILE" || { error "Cannot read configuration file: ${CONF_FILE}"; return 1; }
  fi

  if config_bool "$ENABLE_DOKPLOY_INGRESS"; then
    ENABLE_DOKPLOY_INGRESS=1
  else
    ENABLE_DOKPLOY_INGRESS=0
  fi
  if ! valid_ipv4 "$TRAEFIK_IP"; then
    warn "Invalid TRAEFIK_IP in config; falling back to 10.0.2.2."
    TRAEFIK_IP="10.0.2.2"
  fi
  if [[ ! "$TRAEFIK_BRIDGE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]]; then
    warn "Invalid TRAEFIK_BRIDGE in config; falling back to docker_gwbridge."
    TRAEFIK_BRIDGE="docker_gwbridge"
  fi
  local nft_name
  for nft_name in "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" "$NFT_MANAGED"; do
    if [[ ! "$nft_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      error "Invalid nftables identifier in config: '${nft_name}'."
      return 1
    fi
  done
  if [[ -n "$WAN_IF" && ! "$WAN_IF" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]]; then
    warn "Invalid WAN_IF in config; ignoring it and using the default route."
    WAN_IF=""
  fi
  if [[ ! "$WATCH_INTERVAL" =~ ^[0-9]+$ ]] || (( WATCH_INTERVAL < 5 || WATCH_INTERVAL > 3600 )); then
    warn "Invalid WATCH_INTERVAL in config; using 15 seconds."
    WATCH_INTERVAL=15
  fi

  TCP_EGRESS_PORTS="$(filter_ports "$TCP_EGRESS_PORTS")"
  UDP_EGRESS_PORTS="$(filter_ports "$UDP_EGRESS_PORTS")"
  CUSTOM_TCP_PORTS="$(filter_ports "$CUSTOM_TCP_PORTS")"
  CUSTOM_UDP_PORTS="$(filter_ports "$CUSTOM_UDP_PORTS")"
  MANAGED_UFW_TCP="$(filter_ports "$MANAGED_UFW_TCP")"
  MANAGED_UFW_UDP="$(filter_ports "$MANAGED_UFW_UDP")"
  return 0
}

save_config(){
  local tmp
  mkdir -p -- "$(dirname -- "$CONF_FILE")" || return 1
  backup_file "$CONF_FILE" || return 1
  tmp="$(mktemp)" || return 1
  cat >"$tmp" <<EOFCONF
# Managed by ${APP_NAME} v${APP_VERSION}. Do not edit by hand while the toolkit is running.
# Space-separated port lists. Outbound rules never publish inbound services.
TCP_EGRESS_PORTS="${TCP_EGRESS_PORTS:-}"
UDP_EGRESS_PORTS="${UDP_EGRESS_PORTS:-}"
SELECTED_SERVICE_IDS="${SELECTED_SERVICE_IDS:-}"
CUSTOM_TCP_PORTS="${CUSTOM_TCP_PORTS:-}"
CUSTOM_UDP_PORTS="${CUSTOM_UDP_PORTS:-}"
MANAGED_UFW_TCP="${MANAGED_UFW_TCP:-}"
MANAGED_UFW_UDP="${MANAGED_UFW_UDP:-}"
ENABLE_DOKPLOY_INGRESS="${ENABLE_DOKPLOY_INGRESS:-0}"
TRAEFIK_IP="${TRAEFIK_IP:-10.0.2.2}"
TRAEFIK_BRIDGE="${TRAEFIK_BRIDGE:-docker_gwbridge}"
NFT_FAMILY="${NFT_FAMILY:-inet}"
NFT_TABLE="${NFT_TABLE:-cloud_dev}"
NFT_PARENT="${NFT_PARENT:-forward}"
NFT_MANAGED="${NFT_MANAGED:-vps_docker_forward}"
WAN_IF="${WAN_IF:-}"
WATCH_INTERVAL="${WATCH_INTERVAL:-15}"
EOFCONF
  chmod 0600 -- "$tmp"
  install -m 0600 -- "$tmp" "$CONF_FILE" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# Service catalog
# ---------------------------------------------------------------------------

services_catalog_file(){
  toolkit_file config/services.conf
}

service_line(){
  local wanted="$1" file sid name tcp udp note
  file="$(services_catalog_file)"
  [[ -f "$file" ]] || { error "Service catalog not found: ${file}"; return 1; }
  while IFS='|' read -r sid name tcp udp note; do
    sid="${sid//$'\r'/}"
    [[ -z "$sid" || "$sid" == \#* ]] && continue
    if [[ "$sid" == "$wanted" ]]; then
      printf '%s|%s|%s|%s|%s\n' "$sid" "$name" "$tcp" "$udp" "${note//$'\r'/}"
      return 0
    fi
  done <"$file"
  return 1
}

service_name(){
  local line
  line="$(service_line "$1")" || { printf 'unknown'; return 0; }
  cut -d'|' -f2 <<<"$line"
}

print_service_menu(){
  local file sid name tcp udp note
  file="$(services_catalog_file)"
  [[ -f "$file" ]] || { error "Service catalog not found: ${file}"; return 1; }
  printf '\n%-4s %-28s %-16s %s\n' 'ID' 'CATEGORY' 'TCP' 'UDP'
  while IFS='|' read -r sid name tcp udp note; do
    sid="${sid//$'\r'/}"
    [[ -z "$sid" || "$sid" == \#* ]] && continue
    printf '%3s) %-28s %-16s %s\n' "$sid" "${name//$'\r'/}" "${tcp:--}" "${udp:--}"
  done <"$file"
  printf '%3s) %-28s\n' 21 'Custom TCP ports'
  printf '%3s) %-28s\n' 22 'Custom UDP ports'
  printf '\nThese are OUTBOUND destinations only. No inbound port is opened here.\n'
}

recompute_effective_ports(){
  local id line name tcp udp note all_tcp="" all_udp=""
  for id in $SELECTED_SERVICE_IDS; do
    line="$(service_line "$id")" || { warn "Unknown service id '${id}' ignored."; continue; }
    IFS='|' read -r id name tcp udp note <<<"$line"
    all_tcp+=" ${tcp:-}"
    all_udp+=" ${udp:-}"
  done
  all_tcp+=" ${CUSTOM_TCP_PORTS:-}"
  all_udp+=" ${CUSTOM_UDP_PORTS:-}"
  TCP_EGRESS_PORTS="$(filter_ports "$all_tcp")"
  UDP_EGRESS_PORTS="$(filter_ports "$all_udp")"
}

show_current_selection(){
  local id names=""
  load_config || return 1
  for id in $SELECTED_SERVICE_IDS; do
    names+="$(service_name "$id"), "
  done
  names="${names%, }"
  section "Outbound firewall selection"
  printf 'Config file       : %s\n' "$CONF_FILE"
  printf 'Selected services : %s\n' "${names:-none}"
  printf 'Selected IDs      : %s\n' "${SELECTED_SERVICE_IDS:-none}"
  printf 'Custom TCP        : %s\n' "${CUSTOM_TCP_PORTS:-none}"
  printf 'Custom UDP        : %s\n' "${CUSTOM_UDP_PORTS:-none}"
  printf 'Effective TCP out : %s\n' "${TCP_EGRESS_PORTS:-none}"
  printf 'Effective UDP out : %s\n' "${UDP_EGRESS_PORTS:-none}"
}

preview_and_apply(){
  # $1 = new service id list, $2 = new custom TCP, $3 = new custom UDP
  local old_tcp="${TCP_EGRESS_PORTS:-}" old_udp="${UDP_EGRESS_PORTS:-}"
  local new_ids="$1" new_tcp_custom="$2" new_udp_custom="$3"
  local saved_ids="${SELECTED_SERVICE_IDS:-}" saved_tcp_custom="${CUSTOM_TCP_PORTS:-}" saved_udp_custom="${CUSTOM_UDP_PORTS:-}"
  local new_tcp new_udp

  SELECTED_SERVICE_IDS="$new_ids"
  CUSTOM_TCP_PORTS="$new_tcp_custom"
  CUSTOM_UDP_PORTS="$new_udp_custom"
  recompute_effective_ports
  new_tcp="${TCP_EGRESS_PORTS:-}"
  new_udp="${UDP_EGRESS_PORTS:-}"

  # Restore until the administrator confirms.
  SELECTED_SERVICE_IDS="$saved_ids"
  CUSTOM_TCP_PORTS="$saved_tcp_custom"
  CUSTOM_UDP_PORTS="$saved_udp_custom"
  TCP_EGRESS_PORTS="$old_tcp"
  UDP_EGRESS_PORTS="$old_udp"

  printf '\nProposed outbound changes:\n'
  printf '  TCP before: %s\n' "${old_tcp:-none}"
  printf '  TCP after : %s\n' "${new_tcp:-none}"
  printf '  UDP before: %s\n' "${old_udp:-none}"
  printf '  UDP after : %s\n' "${new_udp:-none}"
  if [[ "$old_tcp" == "$new_tcp" && "$old_udp" == "$new_udp" ]]; then
    log "Selection produces no port changes."
    return 0
  fi
  confirm "Save and apply these outbound rules?" || { log "Cancelled; no changes made."; return 0; }

  SELECTED_SERVICE_IDS="$new_ids"
  CUSTOM_TCP_PORTS="$new_tcp_custom"
  CUSTOM_UDP_PORTS="$new_udp_custom"
  recompute_effective_ports
  save_config || return 1
  ufw_apply_managed_egress || warn "UFW rules could not be updated."
  nft_apply || warn "nftables rules could not be updated now; the watcher will retry."
  start_watcher || warn "Watcher installation failed; run repair to retry."
  success "Outbound service selection saved and applied."
}

remove_selection_interactive(){
  local answer ids="" item new_ids new_tcp="${CUSTOM_TCP_PORTS:-}" new_udp="${CUSTOM_UDP_PORTS:-}"
  read -r -p "Service IDs to remove (space/comma separated; c=custom TCP, u=custom UDP): " answer || return 0
  answer="${answer//,/ }"
  for item in $answer; do
    case "$item" in
      c|C) new_tcp="" ;;
      u|U) new_udp="" ;;
      *) [[ "$item" =~ ^[0-9]+$ ]] && ids+="$((10#$item)) " ;;
    esac
  done
  new_ids="$(remove_id_list "${SELECTED_SERVICE_IDS:-}" "$ids")"
  preview_and_apply "$new_ids" "$new_tcp" "$new_udp"
}

service_selector(){
  load_config || return 1
  local answer id item extra_ids="" new_ids new_tcp="${CUSTOM_TCP_PORTS:-}" new_udp="${CUSTOM_UDP_PORTS:-}"
  while true; do
    show_current_selection || return 1
    printf '\nCommands: numbers=toggle categories, r=remove, l=list rules, a=apply current, 0=back\n'
    read -r -p "Select outbound categories (e.g. 5,6,18,19) or command: " answer || return 0
    answer="${answer//[[:space:]]/}"
    case "$answer" in
      0|q|Q) return 0 ;;
      l|L) show_configured_rules ;;
      a|A) apply_firewall ;;
      r|R) remove_selection_interactive ;;
      *)
        if ! parse_menu_selection "$answer" 22; then
          warn "Invalid selection (${MENU_PARSE_ERROR})."
          continue
        fi
        extra_ids=""
        for id in "${MENU_IDS[@]}"; do
          case "$id" in
            21)
              read -r -p "Additional custom TCP ports (space-separated): " item || continue
              new_tcp+=" ${item//,/ }"
              ;;
            22)
              read -r -p "Additional custom UDP ports (space-separated): " item || continue
              new_udp+=" ${item//,/ }"
              ;;
            *) extra_ids+="$id " ;;
          esac
        done
        new_ids="$(toggle_id_list "${SELECTED_SERVICE_IDS:-}" "$extra_ids")"
        preview_and_apply "$new_ids" "$new_tcp" "$new_udp"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# UFW helpers
# ---------------------------------------------------------------------------

ufw_rule_exists(){
  local port="$1" proto="$2"
  command_exists ufw || return 1
  ufw status 2>/dev/null | awk -v rule="${port}/${proto}" \
    '$1 == rule && $2 == "ALLOW" && $3 == "OUT" { found=1 } END { exit !found }'
}

ufw_in_rule_exists(){
  local port="$1" proto="$2" source="${3:-}"
  command_exists ufw || return 1
  if [[ -n "$source" ]]; then
    ufw status 2>/dev/null | awk -v rule="${port}/${proto}" -v src="$source" \
      '$1 == rule && $2 == "ALLOW" && $3 == "IN" && index($0, src) { found=1 } END { exit !found }'
  else
    ufw status 2>/dev/null | awk -v rule="${port}/${proto}" \
      '$1 == rule && $2 == "ALLOW" && $3 == "IN" && $4 == "Anywhere" { found=1 } END { exit !found }'
  fi
}

ufw_init(){
  local p ssh_port
  command_exists ufw || { error "ufw is not installed. Install base utilities first."; return 1; }
  snapshot_firewall >/dev/null || true

  # Allow essential access before enabling/retightening defaults.
  for p in 22 80 443; do
    ufw_in_rule_exists "$p" tcp || ufw allow "${p}/tcp" comment 'Baseline SSH/HTTP/HTTPS' >/dev/null || return 1
  done
  if command_exists sshd; then
    ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
    if [[ -n "$ssh_port" ]] && valid_port "$ssh_port"; then
      ssh_port=$((10#$ssh_port))
      if (( ssh_port != 22 )); then
        ufw_in_rule_exists "$ssh_port" tcp || ufw allow "${ssh_port}/tcp" comment 'Detected SSH port' >/dev/null || return 1
        log "Preserved detected SSH port ${ssh_port}/tcp."
      fi
    fi
  fi

  ufw default deny incoming >/dev/null || return 1
  ufw default allow outgoing >/dev/null || return 1
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "UFW is already active; baseline rules verified."
  else
    ufw --force enable >/dev/null || return 1
    success "UFW enabled with default-deny inbound / default-allow outbound."
  fi
  log "Existing unrelated UFW rules were not deleted."
}

ufw_delete_out(){
  local port="$1" proto="$2" i
  for ((i=0; i<5; i++)); do
    ufw_rule_exists "$port" "$proto" || return 0
    ufw delete allow out "${port}/${proto}" >/dev/null 2>&1 || return 0
  done
  return 0
}

ufw_apply_managed_egress(){
  command_exists ufw || { warn "ufw is not installed; skipping UFW egress rules."; return 1; }
  local p added_tcp="" added_udp=""
  for p in $MANAGED_UFW_TCP; do
    if [[ " ${TCP_EGRESS_PORTS:-} " != *" ${p} "* ]]; then
      ufw_delete_out "$p" tcp
      log "Removed managed UFW egress rule ${p}/tcp."
    fi
  done
  for p in $MANAGED_UFW_UDP; do
    if [[ " ${UDP_EGRESS_PORTS:-} " != *" ${p} "* ]]; then
      ufw_delete_out "$p" udp
      log "Removed managed UFW egress rule ${p}/udp."
    fi
  done
  for p in ${TCP_EGRESS_PORTS:-}; do
    if ! ufw_rule_exists "$p" tcp; then
      ufw allow out "${p}/tcp" comment 'VPS-MANAGED container egress' >/dev/null || { error "Failed to add UFW egress ${p}/tcp"; continue; }
      added_tcp+="$p "
    fi
  done
  for p in ${UDP_EGRESS_PORTS:-}; do
    if ! ufw_rule_exists "$p" udp; then
      ufw allow out "${p}/udp" comment 'VPS-MANAGED container egress' >/dev/null || { error "Failed to add UFW egress ${p}/udp"; continue; }
      added_udp+="$p "
    fi
  done
  MANAGED_UFW_TCP="${added_tcp% }"
  MANAGED_UFW_UDP="${added_udp% }"
  log "Managed UFW outbound rules reconciled."
}

sensitive_inbound_port(){
  case "$1" in
    2375|2376|3306|5432|1433|1521|6379|27017|9200|9300|9000|24900|23306|11211|27018)
      return 0 ;;
    *) return 1 ;;
  esac
}

add_host_inbound_rule(){
  # add_host_inbound_rule PORT PROTO [SOURCE] [ALLOW_SENSITIVE]
  local port="$1" proto="$2" source="${3:-}" allow_sensitive="${4:-0}"
  local line
  valid_port "$port" || { error "Invalid port '${port}'."; return 1; }
  port=$((10#$port))
  [[ "$proto" == tcp || "$proto" == udp ]] || { error "Protocol must be tcp or udp."; return 1; }
  [[ -z "$source" ]] || valid_ipv4_cidr "$source" || { error "Invalid source '${source}'; use IPv4 or CIDR."; return 1; }
  if [[ -z "$source" ]] && sensitive_inbound_port "$port" && [[ "$allow_sensitive" != "1" ]]; then
    error "Refusing public inbound access to sensitive port ${port}/${proto} without explicit authorization."
    return 1
  fi
  line="${port}|${proto}|${source}"
  mkdir -p -- "$STATE_DIR" || return 1
  chmod 0750 -- "$STATE_DIR" 2>/dev/null || true
  if [[ -f "$INBOUND_RULES_FILE" ]] && grep -Fxq -- "$line" "$INBOUND_RULES_FILE"; then
    log "Host inbound rule ${line} already managed."
    return 0
  fi
  if ! ufw_in_rule_exists "$port" "$proto" "$source"; then
    if [[ -n "$source" ]]; then
      ufw allow from "$source" to any port "$port" proto "$proto" comment 'VPS-MANAGED host inbound' >/dev/null || return 1
    else
      ufw allow "${port}/${proto}" comment 'VPS-MANAGED host inbound public' >/dev/null || return 1
    fi
  fi
  printf '%s\n' "$line" >>"$INBOUND_RULES_FILE"
  chmod 0600 -- "$INBOUND_RULES_FILE" 2>/dev/null || true
  success "Host inbound rule added: ${port}/${proto} from ${source:-any}. This does not publish a container port."
}

remove_host_inbound_rule(){
  local port="$1" proto="$2" source="${3:-}" tmp
  valid_port "$port" || { error "Invalid port '${port}'."; return 1; }
  port=$((10#$port))
  [[ "$proto" == tcp || "$proto" == udp ]] || { error "Invalid protocol."; return 1; }
  if [[ -z "$source" ]]; then
    ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
  else
    ufw delete allow from "$source" to any port "$port" proto "$proto" >/dev/null 2>&1 || true
  fi
  if [[ -f "$INBOUND_RULES_FILE" ]]; then
    tmp="$(mktemp)" || return 1
    grep -Fxv -- "${port}|${proto}|${source}" "$INBOUND_RULES_FILE" >"$tmp" || true
    install -m 0600 -- "$tmp" "$INBOUND_RULES_FILE" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
  fi
  log "Host inbound rule removed: ${port}/${proto} from ${source:-any}."
}

custom_host_inbound(){
  local answer port proto source allow=0
  while true; do
    section "Custom host inbound ports (UFW)"
    if [[ -f "$INBOUND_RULES_FILE" ]]; then
      cat -- "$INBOUND_RULES_FILE"
    else
      printf 'No toolkit-managed host inbound rules.\n'
    fi
    printf '\nCommands: a=add, r=remove, 0=back\n'
    read -r -p "Choose: " answer || return 0
    case "$answer" in
      0|q|Q) return 0 ;;
      a|A)
        read -r -p "Host port (1-65535): " port || continue
        valid_port "$port" || { warn "Invalid port."; continue; }
        port=$((10#$port))
        read -r -p "Protocol (tcp/udp): " proto || continue
        proto="${proto,,}"
        read -r -p "Trusted source IPv4/CIDR (blank = ANY public source): " source || continue
        allow=0
        if [[ -z "$source" ]]; then
          warn "Blank source permits public access from any IPv4 address."
          if sensitive_inbound_port "$port"; then
            warn "This is a database/cache/administration port and is blocked by default."
            confirm_typed "I-UNDERSTAND-PUBLIC-${port}" && allow=1 || { log "Cancelled."; continue; }
          else
            confirm "Confirm public inbound access?" || { log "Cancelled."; continue; }
          fi
        fi
        add_host_inbound_rule "$port" "$proto" "$source" "$allow" || warn "Could not add inbound rule."
        ;;
      r|R)
        read -r -p "Port to remove: " port || continue
        valid_port "$port" || { warn "Invalid port."; continue; }
        port=$((10#$port))
        read -r -p "Protocol (tcp/udp): " proto || continue
        proto="${proto,,}"
        read -r -p "Source to remove (blank = ANY): " source || continue
        remove_host_inbound_rule "$port" "$proto" "$source" || warn "Could not remove inbound rule."
        ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Dynamic Docker bridge discovery
# ---------------------------------------------------------------------------

get_wan(){
  if [[ -n "${WAN_IF:-}" ]]; then
    printf '%s\n' "$WAN_IF"
    return 0
  fi
  ip -4 route show default 2>/dev/null | awk 'NR==1 { for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }'
}

bridge_inventory(){
  local name links
  links="$(ip -o link show 2>/dev/null \
    | sed -nE 's/^[0-9]+: ([^:@]+)(@[^:]+)?:.*/\1/p' \
    | grep -E '^(docker0|docker_gwbridge|br-[[:xdigit:]]+)$' || true)"
  for name in $links; do
    ip -4 -o addr show dev "$name" 2>/dev/null | awk -v n="$name" '$4 ~ /\// { print n, $4 }'
  done
}

# ---------------------------------------------------------------------------
# Toolkit-owned nftables chain
# ---------------------------------------------------------------------------

nft_parent_exists(){
  command_exists nft || return 1
  nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" >/dev/null 2>&1
}

nft_managed_exists(){
  command_exists nft || return 1
  nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" >/dev/null 2>&1
}

nft_jump_exists(){
  command_exists nft || return 1
  nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" 2>/dev/null \
    | grep -F "jump ${NFT_MANAGED}" >/dev/null
}

nft_cleanup_duplicate_jumps(){
  local -a handles=()
  local i
  if ! command_exists nft; then
    return 0
  fi
  mapfile -t handles < <(nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" 2>/dev/null \
    | awk -v managed="$NFT_MANAGED" '
        index($0, "jump " managed) && index($0, "VPS-MANAGED-DOCKER-JUMP") {
          for (i = NF; i > 0; i--) if ($i == "#") { print $(i+1); break }
        }')
  if (( ${#handles[@]} > 1 )); then
    warn "Removing duplicate toolkit jump rules (${#handles[@]} found)."
    for ((i=1; i<${#handles[@]}; i++)); do
      nft delete rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" handle "${handles[$i]}" 2>/dev/null || true
    done
  fi
}

build_nft_ruleset(){
  local wan tcp_set="" udp_set="" bridge subnet
  NFT_RULES=()
  wan="$(get_wan)"
  [[ -n "$wan" ]] || { warn "No default-route interface detected."; return 1; }

  NFT_RULES+=("add chain ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED}")
  NFT_RULES+=("flush chain ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED}")
  if ! nft_jump_exists; then
    NFT_RULES+=("insert rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_PARENT} jump ${NFT_MANAGED} comment \"VPS-MANAGED-DOCKER-JUMP\"")
  fi

  [[ -n "${TCP_EGRESS_PORTS:-}" ]] && tcp_set="{ ${TCP_EGRESS_PORTS// /,} }"
  [[ -n "${UDP_EGRESS_PORTS:-}" ]] && udp_set="{ ${UDP_EGRESS_PORTS// /,} }"

  while read -r bridge subnet; do
    [[ -n "${bridge:-}" && -n "${subnet:-}" ]] || continue
    if [[ -n "$tcp_set" ]]; then
      NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${bridge}\" oifname \"${wan}\" ip saddr ${subnet} tcp dport ${tcp_set} ct state '{ new, established, related }' counter accept")
    fi
    if [[ -n "$udp_set" ]]; then
      NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${bridge}\" oifname \"${wan}\" ip saddr ${subnet} udp dport ${udp_set} ct state '{ new, established, related }' counter accept")
    fi
    NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${wan}\" oifname \"${bridge}\" ip daddr ${subnet} ct state '{ established, related }' counter accept")
  done < <(bridge_inventory)

  if config_bool "$ENABLE_DOKPLOY_INGRESS" && ip link show "$TRAEFIK_BRIDGE" >/dev/null 2>&1; then
    NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${wan}\" oifname \"${TRAEFIK_BRIDGE}\" ip daddr ${TRAEFIK_IP} tcp dport '{ 80, 443 }' ct status dnat counter accept")
  elif config_bool "$ENABLE_DOKPLOY_INGRESS"; then
    warn "Dokploy ingress enabled but bridge ${TRAEFIK_BRIDGE} is not present; the watcher will retry."
  fi
  return 0
}

# nft_reconcile [FORCE]
# FORCE=1 always reapplies; FORCE=0 skips when the generated ruleset is
# unchanged (used by the watcher to avoid log noise and needless flushes).
nft_reconcile(){
  local force="${1:-0}" tmp=""
  load_config || return 1
  command_exists nft || { warn "nft command not installed; install nftables first."; return 1; }
  if ! nft_parent_exists; then
    warn "Required chain ${NFT_FAMILY} ${NFT_TABLE} ${NFT_PARENT} was not found. Refusing to create or replace your firewall policy."
    return 1
  fi
  nft_cleanup_duplicate_jumps
  build_nft_ruleset || return 1

  tmp="$(mktemp)" || return 1
  printf '%s\n' "${NFT_RULES[@]}" >"$tmp"

  if [[ "$force" != "1" && -f "$NFT_STATE_FILE" ]] \
     && cmp -s -- "$tmp" "$NFT_STATE_FILE" \
     && nft_managed_exists && nft_jump_exists; then
    rm -f -- "$tmp"
    return 0
  fi

  if ! nft -c -f "$tmp" >/dev/null 2>&1; then
    warn "nftables validation failed; generated rules were NOT applied. Check 'nft -c -f ${tmp}'."
    rm -f -- "$tmp"
    return 1
  fi
  if ! nft -f "$tmp"; then
    error "Failed to apply managed nftables rules."
    rm -f -- "$tmp"
    return 1
  fi
  mkdir -p -- "$STATE_DIR" 2>/dev/null || true
  install -m 0600 -- "$tmp" "$NFT_STATE_FILE" 2>/dev/null || true
  rm -f -- "$tmp"
  log "Managed nftables chain ${NFT_MANAGED} reconciled (${#NFT_RULES[@]} directives)."
  return 0
}

nft_apply(){ nft_reconcile 1; }

install_cron_watcher(){
  local cron_tmp marker="# vps-setup firewall watch (managed)"
  command_exists crontab || { warn "Neither systemd nor cron is available; install a supervisor for the watcher."; return 1; }
  cron_tmp="$(mktemp)" || return 1
  crontab -l 2>/dev/null | grep -Fv "$marker" >"$cron_tmp" || true
  {
    printf '%s\n' "$marker"
    printf '* * * * * %s/scripts/firewall.sh nft-reconcile >>%s/firewall-watch.log 2>&1\n' \
      "$INSTALL_DIR" "$LOG_DIR"
  } >>"$cron_tmp"
  if crontab "$cron_tmp"; then
    rm -f -- "$cron_tmp"
    success "Cron fallback watcher installed (runs every minute)."
    return 0
  fi
  rm -f -- "$cron_tmp"
  return 1
}

remove_cron_watcher(){
  local cron_tmp marker="# vps-setup firewall watch (managed)"
  command_exists crontab || return 0
  cron_tmp="$(mktemp)" || return 0
  crontab -l 2>/dev/null | grep -Fv "$marker" >"$cron_tmp" || true
  crontab "$cron_tmp" 2>/dev/null || true
  rm -f -- "$cron_tmp"
}

start_watcher(){
  local watcher_src unit_src
  watcher_src="$(toolkit_file scripts/watchdog.sh)"
  unit_src="$(toolkit_file systemd/vps-firewall-watch.service)"
  if [[ -f "$watcher_src" ]]; then
    install_file "$watcher_src" "$WATCHER_PATH" 0750 || return 1
  fi
  if [[ -f "$unit_src" ]]; then
    install_file "$unit_src" "$UNIT_PATH" 0644 || return 1
  fi
  if is_systemd && [[ -f "$unit_src" ]]; then
    systemctl daemon-reload || return 1
    systemctl enable --now "$UNIT_NAME" || return 1
    success "Persistent firewall watcher enabled (${UNIT_NAME})."
  else
    warn "systemd is not running here; using the portable cron fallback."
    install_cron_watcher || warn "No persistent watcher could be installed."
  fi
}

apply_firewall(){
  load_config || return 1
  if [[ -n "${SELECTED_SERVICE_IDS:-}" || -n "${CUSTOM_TCP_PORTS:-}" || -n "${CUSTOM_UDP_PORTS:-}" ]]; then
    recompute_effective_ports
  fi
  TCP_EGRESS_PORTS="$(filter_ports "${TCP_EGRESS_PORTS:-}")"
  UDP_EGRESS_PORTS="$(filter_ports "${UDP_EGRESS_PORTS:-}")"
  save_config || return 1
  ufw_apply_managed_egress || warn "UFW egress rules were not updated."
  nft_apply || warn "nftables policy was not applied; the watcher will retry when the required chain exists."
  start_watcher || warn "Watcher installation failed; use Repair and Recovery to retry."
  success "Firewall configuration applied."
}

show_configured_rules(){
  load_config || return 1
  section "Managed configuration"
  printf 'Config: %s\n' "$CONF_FILE"
  printf 'TCP outbound : %s\n' "${TCP_EGRESS_PORTS:-none}"
  printf 'UDP outbound : %s\n' "${UDP_EGRESS_PORTS:-none}"
  printf 'nft target   : %s %s %s -> %s\n' "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" "$NFT_MANAGED"
  section "UFW status"
  command_exists ufw && ufw status verbose 2>/dev/null || printf 'ufw unavailable\n'
  section "Toolkit-managed host inbound rules"
  [[ -f "$INBOUND_RULES_FILE" ]] && cat -- "$INBOUND_RULES_FILE" || printf 'none\n'
  section "Docker bridges"
  bridge_inventory || true
  section "Managed nftables chain"
  if command_exists nft; then
    nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" 2>/dev/null || printf 'chain not present yet\n'
  else
    printf 'nft unavailable\n'
  fi
  section "Watcher"
  if is_systemd; then
    systemctl --no-pager --full status "$UNIT_NAME" 2>/dev/null || printf 'watcher not running\n'
  else
    printf 'systemd unavailable\n'
  fi
}

firewall_cli(){
  case "${1:-status}" in
    select) service_selector ;;
    apply) apply_firewall ;;
    nft-reconcile) nft_reconcile 0 ;;
    nft-apply) nft_apply ;;
    ufw-init) ufw_init ;;
    inbound) custom_host_inbound ;;
    status) show_configured_rules ;;
    watcher) start_watcher ;;
    *) error "Unknown firewall command: $1"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  firewall_cli "$@"
fi
