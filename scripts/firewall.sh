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
ENABLE_MSS_CLAMP=0
ENABLE_IPV6_EGRESS=1
TRAEFIK_IP="10.0.2.2"
TRAEFIK_BRIDGE="docker_gwbridge"
NETWORK_TARGET_HOST=""
NETWORK_TARGET_PORT=""
NETWORK_PROTOCOL="https"

# Outbound presets. "Standard" means the well-known services a typical server
# needs for updates, DNS, time, git and mail. Database/S3 categories are kept
# out of this preset on purpose; they are available in the full catalog.
STANDARD_SERVICE_IDS="1 2 3 4 5 6 7 8 9 10 11 12 20 56 57 58"
ALL_SERVICE_IDS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58"

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
  ENABLE_MSS_CLAMP=0
  ENABLE_IPV6_EGRESS=1
  TRAEFIK_IP="10.0.2.2"
  TRAEFIK_BRIDGE="docker_gwbridge"
  NETWORK_TARGET_HOST=""
  NETWORK_TARGET_PORT=""
  NETWORK_PROTOCOL="https"
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
  if config_bool "$ENABLE_MSS_CLAMP"; then
    ENABLE_MSS_CLAMP=1
  else
    ENABLE_MSS_CLAMP=0
  fi
  if config_bool "$ENABLE_IPV6_EGRESS"; then
    ENABLE_IPV6_EGRESS=1
  else
    ENABLE_IPV6_EGRESS=0
  fi
  NETWORK_TARGET_HOST="${NETWORK_TARGET_HOST//[[:space:]]/}"
  if [[ -n "$NETWORK_TARGET_HOST" && ! "$NETWORK_TARGET_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$ ]]; then
    warn "Invalid NETWORK_TARGET_HOST in config; ignoring it."
    NETWORK_TARGET_HOST=""
  fi
  if [[ -n "$NETWORK_TARGET_PORT" ]]; then
    if valid_port "$NETWORK_TARGET_PORT"; then
      NETWORK_TARGET_PORT="$((10#$NETWORK_TARGET_PORT))"
    else
      warn "Invalid NETWORK_TARGET_PORT in config; ignoring it."
      NETWORK_TARGET_PORT=""
    fi
  fi
  if [[ ! "$NETWORK_PROTOCOL" =~ ^[a-z0-9-]{2,20}$ ]]; then
    warn "Invalid NETWORK_PROTOCOL in config; using https."
    NETWORK_PROTOCOL="https"
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
ENABLE_MSS_CLAMP="${ENABLE_MSS_CLAMP:-0}"
ENABLE_IPV6_EGRESS="${ENABLE_IPV6_EGRESS:-1}"
TRAEFIK_IP="${TRAEFIK_IP:-10.0.2.2}"
TRAEFIK_BRIDGE="${TRAEFIK_BRIDGE:-docker_gwbridge}"
NETWORK_TARGET_HOST="${NETWORK_TARGET_HOST:-}"
NETWORK_TARGET_PORT="${NETWORK_TARGET_PORT:-}"
NETWORK_PROTOCOL="${NETWORK_PROTOCOL:-https}"
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

# Catalog files are read in order: shipped services first, then operator
# definitions from persistent state. Custom IDs always start at 1000.
service_catalog_files(){
  local file
  file="$(services_catalog_file)"
  [[ -f "$file" ]] && printf '%s\n' "$file"
  [[ -f "$CUSTOM_SERVICES_FILE" ]] && printf '%s\n' "$CUSTOM_SERVICES_FILE"
  return 0
}

service_line(){
  local wanted="$1" file sid
  while IFS= read -r file; do
    while IFS='|' read -r sid category name tcp udp note ipv6 probe_host probe_mode; do
      sid="${sid//$'\r'/}"
      [[ -z "$sid" || "$sid" == \#* ]] && continue
      [[ "$sid" =~ ^[0-9]+$ ]] || continue
      if [[ "$sid" == "$wanted" ]]; then
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
          "$((10#$sid))" "${category//$'\r'/}" "${name//$'\r'/}" "${tcp//$'\r'/}" \
          "${udp//$'\r'/}" "${note//$'\r'/}" "${ipv6//$'\r'/}" \
          "${probe_host//$'\r'/}" "${probe_mode//$'\r'/}"
        return 0
      fi
    done <"$file"
  done < <(service_catalog_files)
  return 1
}

service_field(){
  local line
  line="$(service_line "$1")" || return 1
  cut -d'|' -f"$2" <<<"$line"
}

service_name(){
  local line
  line="$(service_line "$1")" || { printf 'unknown'; return 0; }
  cut -d'|' -f3 <<<"$line"
}

service_category(){
  local line
  line="$(service_line "$1")" || { printf 'unknown'; return 0; }
  cut -d'|' -f2 <<<"$line"
}

normalize_service_ids(){
  local input="$1" id out=""
  for id in $input; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    id=$((10#$id))
    if [[ " ${out:-} " != *" ${id} "* ]]; then
      out+="${id} "
    fi
  done
  printf '%s' "${out% }"
}

all_service_ids(){
  local file sid out=""
  file="$(services_catalog_file)"
  while IFS='|' read -r sid _; do
    sid="${sid//$'\r'/}"
    [[ -z "$sid" || "$sid" == \#* ]] && continue
    [[ "$sid" =~ ^[0-9]+$ ]] || continue
    out+="$((10#$sid)) "
  done <"$file"
  printf '%s' "${out% }"
}

service_max_id(){
  local id max=0
  for id in $(all_service_ids); do (( id > max )) && max="$id"; done
  [[ -f "$CUSTOM_SERVICES_FILE" ]] || { printf '%s\n' "$max"; return 0; }
  while IFS='|' read -r id _; do
    id="${id//$'\r'/}"
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    id=$((10#$id))
    (( id > max )) && max="$id"
  done <"$CUSTOM_SERVICES_FILE"
  printf '%s\n' "$max"
}

service_categories(){
  local file category
  file="$(services_catalog_file)"
  {
    while IFS='|' read -r _ category _; do
      category="${category//$'\r'/}"
      [[ -n "$category" ]] && printf '%s\n' "$category"
    done <"$file"
    [[ -f "$CUSTOM_SERVICES_FILE" ]] || return 0
    while IFS='|' read -r _ category _; do
      category="${category//$'\r'/}"
      [[ -n "$category" ]] && printf '%s\n' "$category"
    done <"$CUSTOM_SERVICES_FILE"
  } | awk '!seen[$0]++' | sort
}

service_ids_in_category(){
  local wanted="$1" file sid category out=""
  while IFS= read -r file; do
    while IFS='|' read -r sid category _; do
      sid="${sid//$'\r'/}"
      category="${category//$'\r'/}"
      [[ -z "$sid" || "$sid" == \#* ]] && continue
      [[ "$category" == "$wanted" ]] || continue
      out+="$((10#$sid)) "
    done <"$file"
  done < <(service_catalog_files)
  printf '%s' "${out% }"
}

preset_service_ids(){
  local preset="${1:-standard}" ids=""
  case "$preset" in
    standard)
      printf '%s\n' "$STANDARD_SERVICE_IDS" ;;
    all|all-common|common-all)
      all_service_ids ;;
    development)
      ids="$(service_ids_in_category 'Common') $(service_ids_in_category 'DNS and Time') $(service_ids_in_category 'Web') $(service_ids_in_category 'Development') $(service_ids_in_category 'API and Messaging') $(service_ids_in_category 'Database')"
      normalize_service_ids "$ids" ;;
    hosting)
      ids="$(service_ids_in_category 'Common') $(service_ids_in_category 'DNS and Time') $(service_ids_in_category 'Web') $(service_ids_in_category 'Email') $(service_ids_in_category 'Storage') $(service_ids_in_category 'Remote Access') $(service_ids_in_category 'Monitoring')"
      normalize_service_ids "$ids" ;;
    database)
      ids="$(service_ids_in_category 'Common') $(service_ids_in_category 'Database')"
      normalize_service_ids "$ids" ;;
    email)
      ids="$(service_ids_in_category 'Common') $(service_ids_in_category 'Email')"
      normalize_service_ids "$ids" ;;
    storage)
      ids="$(service_ids_in_category 'Common') $(service_ids_in_category 'Storage')"
      normalize_service_ids "$ids" ;;
    *)
      return 1 ;;
  esac
}

print_service_menu(){
  local file sid category name tcp udp ipv6
  file="$(services_catalog_file)"
  [[ -f "$file" ]] || { error "Service catalog not found: ${file}"; return 1; }
  printf '\n%-4s %-20s %-28s %-18s %-18s %s\n' 'ID' 'CATEGORY' 'SERVICE' 'TCP' 'UDP' 'IPv6'
  while IFS= read -r file; do
    while IFS='|' read -r sid category name tcp udp _ ipv6 _ _; do
      sid="${sid//$'\r'/}"
      [[ -z "$sid" || "$sid" == \#* ]] && continue
      printf '%3s) %-20s %-28s %-18s %-18s %s\n' \
        "$((10#$sid))" "${category//$'\r'/}" "${name//$'\r'/}" \
        "${tcp:--}" "${udp:--}" "${ipv6:-1}"
    done <"$file"
  done < <(service_catalog_files)
  printf '\nThese are OUTBOUND destinations only. No inbound port is opened here.\n'
}

recompute_effective_ports(){
  local id line _name _tcp _udp all_tcp="" all_udp=""
  for id in $SELECTED_SERVICE_IDS; do
    line="$(service_line "$id")" || { warn "Unknown service id '${id}' ignored."; continue; }
    IFS='|' read -r id _ _category _tcp _udp _ _ _ _ <<<"$line"
    all_tcp+=" ${_tcp:-}"
    all_udp+=" ${_udp:-}"
  done
  all_tcp+=" ${CUSTOM_TCP_PORTS:-}"
  all_udp+=" ${CUSTOM_UDP_PORTS:-}"
  TCP_EGRESS_PORTS="$(filter_ports "$all_tcp")"
  UDP_EGRESS_PORTS="$(filter_ports "$all_udp")"
}

count_items(){
  local count=0 _item
  for _item in $1; do count=$((count + 1)); done
  printf '%s\n' "$count"
}

unified_print_summary(){
  local ids="$1" tcp="$2" udp="$3"
  recompute_effective_ports_for "$ids" "$tcp" "$udp"
  printf '\nSelected services: %s\n' "$(count_items "$ids")"
  printf 'TCP ports: %s\n' "$(count_items "${UNIFIED_PREVIEW_TCP:-}")"
  printf 'UDP ports: %s\n' "$(count_items "${UNIFIED_PREVIEW_UDP:-}")"
  printf '\nApply to:\n'
  printf '  VPS Host:             YES\n'
  printf '  Docker Containers:    YES\n'
  printf '\nPersistent after reboot: YES\n'
}

# Compute effective ports for a proposed selection without changing globals.
recompute_effective_ports_for(){
  local saved_ids="${SELECTED_SERVICE_IDS:-}" saved_tcp="${CUSTOM_TCP_PORTS:-}" saved_udp="${CUSTOM_UDP_PORTS:-}"
  local saved_out_tcp="${TCP_EGRESS_PORTS:-}" saved_out_udp="${UDP_EGRESS_PORTS:-}"
  SELECTED_SERVICE_IDS="$1"
  CUSTOM_TCP_PORTS="$2"
  CUSTOM_UDP_PORTS="$3"
  recompute_effective_ports
  printf -v UNIFIED_PREVIEW_TCP '%s' "${TCP_EGRESS_PORTS:-}"
  printf -v UNIFIED_PREVIEW_UDP '%s' "${UDP_EGRESS_PORTS:-}"
  SELECTED_SERVICE_IDS="$saved_ids"
  CUSTOM_TCP_PORTS="$saved_tcp"
  CUSTOM_UDP_PORTS="$saved_udp"
  TCP_EGRESS_PORTS="$saved_out_tcp"
  UDP_EGRESS_PORTS="$saved_out_udp"
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
  printf 'Custom services   : %s\n' "$([[ -f "$CUSTOM_SERVICES_FILE" ]] && wc -l <"$CUSTOM_SERVICES_FILE" || printf '0')"
  printf 'Effective TCP out : %s\n' "${TCP_EGRESS_PORTS:-none}"
  printf 'Effective UDP out : %s\n' "${UDP_EGRESS_PORTS:-none}"
  printf 'IPv6 outbound     : %s\n' "$([[ "$ENABLE_IPV6_EGRESS" == 1 ]] && printf 'YES' || printf 'NO')"
}

# ---------------------------------------------------------------------------
# Unified Service Access - host + Docker containers, outbound by default
# ---------------------------------------------------------------------------

UNIFIED_PREVIEW_TCP=""
UNIFIED_PREVIEW_UDP=""
SERVICE_BACKUP_LAST_DIR=""

unified_backup_service_state(){
  local stamp dir file
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dir="${SERVICE_BACKUP_DIR}/${stamp}"
  mkdir -p -- "$dir" || return 1
  for file in "$CONF_FILE" "$CUSTOM_SERVICES_FILE" "$NFT_STATE_FILE" "$SERVICE_TEST_RESULTS_FILE"; do
    [[ -f "$file" ]] && cp -a -- "$file" "${dir}/$(basename -- "$file")" 2>/dev/null || true
  done
  if command_exists ufw; then
    ufw status verbose >"${dir}/ufw.status" 2>/dev/null || true
  fi
  if command_exists nft; then
    nft list ruleset >"${dir}/nft.ruleset" 2>/dev/null || true
  fi
  SERVICE_BACKUP_LAST_DIR="$dir"
  log "Unified service configuration backed up to ${dir}."
  return 0
}

unified_validate_rules(){
  local tmp=""
  tmp="$(mktemp)" || return 1
  if ! build_nft_ruleset; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "${NFT_RULES[@]}" >"$tmp"
  if ! nft_validate_rules_file "$tmp"; then
    error "Generated nftables rules failed validation; the last working configuration was preserved."
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
  return 0
}

unified_rollback(){
  local file
  if [[ -n "${SERVICE_BACKUP_LAST_DIR:-}" && -d "${SERVICE_BACKUP_LAST_DIR}" ]]; then
    file="${SERVICE_BACKUP_LAST_DIR}/$(basename -- "$CONF_FILE")"
    [[ -f "$file" ]] && cp -a -- "$file" "$CONF_FILE" 2>/dev/null || true
    file="${SERVICE_BACKUP_LAST_DIR}/$(basename -- "$NFT_STATE_FILE")"
    [[ -f "$file" ]] && cp -a -- "$file" "$NFT_STATE_FILE" 2>/dev/null || true
  fi
  load_config || true
  if command_exists nft && [[ -f "$NFT_STATE_FILE" ]]; then
    nft_reconcile 1 >/dev/null 2>&1 || true
  fi
  warn "Rolled back to the last working unified service configuration."
}

unified_apply_selection(){
  # $1 = service IDs, $2 = custom TCP, $3 = custom UDP, $4 = label, $5 = non-interactive
  local ids new_tcp new_udp label nonint old_interactive
  local saved_ids saved_tcp saved_udp saved_tcp_out saved_udp_out
  ids="$(normalize_service_ids "${1:-}")"
  new_tcp="${2:-}"
  new_udp="${3:-}"
  label="${4:-selection}"
  nonint="${5:-0}"

  load_config || return 1
  saved_ids="${SELECTED_SERVICE_IDS:-}"
  saved_tcp="${CUSTOM_TCP_PORTS:-}"
  saved_udp="${CUSTOM_UDP_PORTS:-}"
  saved_tcp_out="${TCP_EGRESS_PORTS:-}"
  saved_udp_out="${UDP_EGRESS_PORTS:-}"

  section "Unified service access: ${label}"
  unified_print_summary "$ids" "$new_tcp" "$new_udp"
  old_interactive="${VPS_SETUP_INTERACTIVE:-1}"
  (( nonint )) && VPS_SETUP_INTERACTIVE=0
  local confirmed=1
  confirm_yes "Apply these changes?" || confirmed=0
  VPS_SETUP_INTERACTIVE="$old_interactive"
  if (( confirmed == 0 )); then
    log "Cancelled; no changes made."
    return 0
  fi

  unified_backup_service_state || return 1
  SELECTED_SERVICE_IDS="$ids"
  CUSTOM_TCP_PORTS="$new_tcp"
  CUSTOM_UDP_PORTS="$new_udp"
  recompute_effective_ports

  if ! unified_validate_rules; then
    SELECTED_SERVICE_IDS="$saved_ids"
    CUSTOM_TCP_PORTS="$saved_tcp"
    CUSTOM_UDP_PORTS="$saved_udp"
    TCP_EGRESS_PORTS="$saved_tcp_out"
    UDP_EGRESS_PORTS="$saved_udp_out"
    unified_rollback
    return 1
  fi

  if ! ufw_apply_managed_egress; then
    warn "UFW egress rules could not be updated; the watcher will retry."
  fi
  if ! save_config; then
    SELECTED_SERVICE_IDS="$saved_ids"
    CUSTOM_TCP_PORTS="$saved_tcp"
    CUSTOM_UDP_PORTS="$saved_udp"
    TCP_EGRESS_PORTS="$saved_tcp_out"
    UDP_EGRESS_PORTS="$saved_udp_out"
    unified_rollback
    return 1
  fi
  if ! nft_apply; then
    SELECTED_SERVICE_IDS="$saved_ids"
    CUSTOM_TCP_PORTS="$saved_tcp"
    CUSTOM_UDP_PORTS="$saved_udp"
    TCP_EGRESS_PORTS="$saved_tcp_out"
    UDP_EGRESS_PORTS="$saved_udp_out"
    unified_rollback
    return 1
  fi
  start_watcher || warn "Watcher installation failed; use Repair Firewall Rules to retry."
  mkdir -p -- "$(dirname -- "$SERVICE_LAST_WORKING_FILE")" 2>/dev/null || true
  cp -a -- "$CONF_FILE" "$SERVICE_LAST_WORKING_FILE" 2>/dev/null || true
  success "Outbound access saved for VPS host and Docker containers."
  return 0
}

# Compatibility wrapper used by the legacy selector and older callers.
preview_and_apply(){
  unified_apply_selection "$1" "${2:-}" "${3:-}" "outbound selection" "${4:-0}"
}

apply_named_preset(){
  local preset="${1:-standard}" nonint="${2:-0}" ids
  load_config || return 1
  ids="$(preset_service_ids "$preset")" || { error "Unknown preset: ${preset}"; return 1; }
  unified_apply_selection "$ids" "${CUSTOM_TCP_PORTS:-}" "${CUSTOM_UDP_PORTS:-}" \
    "preset: ${preset}" "$nonint"
}

unified_smart_configure(){
  local preset="${1:-hosting}" nonint="${2:-1}" ids merged
  load_config || return 1
  ids="$(preset_service_ids "$preset")" || { error "Unknown preset: ${preset}"; return 1; }
  merged="$(normalize_service_ids "${SELECTED_SERVICE_IDS:-} $ids")"
  log "Smart service configuration: merging '${preset}' preset with existing selections."
  unified_apply_selection "$merged" "${CUSTOM_TCP_PORTS:-}" "${CUSTOM_UDP_PORTS:-}" \
    "smart ${preset} preset" "$nonint"
}

apply_service_preset(){
  local ids="$1" label="$2" nonint="${3:-0}"
  unified_apply_selection "$ids" "${CUSTOM_TCP_PORTS:-}" "${CUSTOM_UDP_PORTS:-}" "$label" "$nonint"
}

unified_select_individually(){
  local ids="" answer id name tcp udp
  load_config || return 1
  print_service_menu
  printf '\nAnswer y to enable OUTBOUND access for each service. No inbound port is opened.\n'
  for id in $(all_service_ids); do
    name="$(service_field "$id" 3)"
    tcp="$(service_field "$id" 4)"
    udp="$(service_field "$id" 5)"
    read -r -p "Allow ${name} (TCP: ${tcp:--}, UDP: ${udp:--})? [y/N]: " answer || return 0
    [[ "$answer" =~ ^[Yy]$ ]] && ids+="$id "
  done
  unified_apply_selection "${ids% }" "${CUSTOM_TCP_PORTS:-}" "${CUSTOM_UDP_PORTS:-}" \
    "individual services"
}

unified_select_categories(){
  local answer c ids="" id
  local -a categories=()
  load_config || return 1
  while IFS= read -r c; do categories+=("$c"); done < <(service_categories)
  section "Service categories"
  local i=1
  for c in "${categories[@]}"; do
    printf '%3s) %s\n' "$i" "$c"
    i=$((i + 1))
  done
  read -r -p "Choose categories (comma-separated numbers): " answer || return 0
  answer="${answer//[[:space:]]/}"
  if ! parse_menu_selection "$answer" "${#categories[@]}"; then
    warn "Invalid selection (${MENU_PARSE_ERROR})."
    return 0
  fi
  for id in "${MENU_IDS[@]}"; do
    ids+="$(service_ids_in_category "${categories[$((id - 1))]}") "
  done
  ids="$(normalize_service_ids "$ids")"
  unified_apply_selection "$ids" "${CUSTOM_TCP_PORTS:-}" "${CUSTOM_UDP_PORTS:-}" \
    "selected categories"
}

unified_add_custom_service(){
  local name port proto category note tcp="" udp="" id max
  name="${VPS_SETUP_CUSTOM_SERVICE_NAME:-}"
  port="${VPS_SETUP_CUSTOM_SERVICE_PORT:-}"
  proto="${VPS_SETUP_CUSTOM_SERVICE_PROTOCOL:-}"
  category="${VPS_SETUP_CUSTOM_SERVICE_CATEGORY:-Custom}"
  note="${VPS_SETUP_CUSTOM_SERVICE_NOTE:-Operator-defined outbound service}"
  load_config || return 1
  if [[ -z "$name" ]]; then
    read -r -p "Service name: " name || return 0
  fi
  if [[ -z "$port" ]]; then
    read -r -p "Port (1-65535): " port || return 0
  fi
  if [[ -z "$proto" ]]; then
    read -r -p "Protocol (tcp/udp/both): " proto || return 0
  fi
  name="${name//|/}"
  name="${name//$'\n'/ }"
  category="${category//|/}"
  note="${note//|/}"
  proto="${proto,,}"
  valid_port "$port" || { error "Invalid port '${port}'."; return 1; }
  port=$((10#$port))
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._/-]{0,39}$ ]] || { error "Invalid service name."; return 1; }
  [[ "$category" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,29}$ ]] || { error "Invalid category name."; return 1; }
  case "$proto" in
    tcp) tcp="$port" ;;
    udp) udp="$port" ;;
    both) tcp="$port"; udp="$port" ;;
    *) error "Protocol must be tcp, udp or both."; return 1 ;;
  esac
  max="$(service_max_id)"
  (( max < 999 )) && max=999
  id=$((max + 1))
  mkdir -p -- "$(dirname -- "$CUSTOM_SERVICES_FILE")" || return 1
  [[ -f "$CUSTOM_SERVICES_FILE" ]] && backup_file "$CUSTOM_SERVICES_FILE" || true
  printf '%s|%s|%s|%s|%s|%s|1||\n' "$id" "$category" "$name" "$tcp" "$udp" "$note" \
    >>"$CUSTOM_SERVICES_FILE" || return 1
  chmod 0600 -- "$CUSTOM_SERVICES_FILE" 2>/dev/null || true
  local ids
  ids="$(normalize_service_ids "${SELECTED_SERVICE_IDS:-} $id")"
  unified_apply_selection "$ids" "${CUSTOM_TCP_PORTS:-}" "${CUSTOM_UDP_PORTS:-}" \
    "custom service: ${name}"
}

unified_remove_services(){
  local answer item ids_to_remove="" new_ids new_tcp="${CUSTOM_TCP_PORTS:-}" new_udp="${CUSTOM_UDP_PORTS:-}"
  local -a categories=()
  load_config || return 1
  while IFS= read -r item; do categories+=("$item"); done < <(service_categories)
  show_current_selection
  printf '\ncat:N removes a whole category (see View Enabled Services for IDs).\n'
  read -r -p "IDs to remove, cat:N, all, c=custom TCP, u=custom UDP: " answer || return 0
  answer="${answer//,/ }"
  for item in $answer; do
    case "$item" in
      c|C) new_tcp="" ;;
      u|U) new_udp="" ;;
      all|ALL) ids_to_remove="$(normalize_service_ids "${SELECTED_SERVICE_IDS:-}")" ;;
      cat:*)
        local cidx="${item#cat:}"
        if [[ "$cidx" =~ ^[0-9]+$ ]] && (( cidx >= 1 && cidx <= ${#categories[@]} )); then
          ids_to_remove+="$(service_ids_in_category "${categories[$((cidx - 1))]}") "
        else
          warn "Unknown category number '${cidx}'."
        fi
        ;;
      *)
        [[ "$item" =~ ^[0-9]+$ ]] && ids_to_remove+="$((10#$item)) "
        ;;
    esac
  done
  new_ids="$(remove_id_list "${SELECTED_SERVICE_IDS:-}" "$(normalize_service_ids "$ids_to_remove")")"
  unified_apply_selection "$new_ids" "$new_tcp" "$new_udp" "remove services"
}

unified_service_status_for(){
  local id="$1" result="${SERVICE_TEST_RESULTS_FILE:-}"
  [[ -f "$result" ]] || { printf 'NOT TESTED'; return 0; }
  awk -F'|' -v id="$id" '$1 == id { printf "%s/%s", $2, $3; found=1; exit } END { if (!found) printf "NOT TESTED" }' "$result"
}

unified_view_enabled(){
  local id name category tcp udp ipv6 status
  load_config || return 1
  recompute_effective_ports
  section "Enabled services"
  printf '%-5s %-26s %-20s %-16s %-16s %-8s %s\n' \
    'ID' 'SERVICE' 'CATEGORY' 'TCP' 'UDP' 'IPv4/IPv6' 'STATUS'
  for id in $SELECTED_SERVICE_IDS; do
    name="$(service_field "$id" 3 || printf 'unknown')"
    category="$(service_field "$id" 2 || printf 'unknown')"
    tcp="$(service_field "$id" 4 || true)"
    udp="$(service_field "$id" 5 || true)"
    ipv6="$(service_field "$id" 7 || printf '0')"
    status="$(unified_service_status_for "$id")"
    printf '%-5s %-26s %-20s %-16s %-16s %-8s %s\n' \
      "$id" "$name" "$category" "${tcp:--}" "${udp:--}" \
      "$([[ "$ipv6" == 1 && "$ENABLE_IPV6_EGRESS" == 1 ]] && printf 'v4+v6' || printf 'v4')" \
      "$status"
  done
  [[ -n "${SELECTED_SERVICE_IDS:-}" ]] || printf 'No services selected.\n'
  printf '\nSelected services: %s\n' "$(count_items "$SELECTED_SERVICE_IDS")"
  printf 'TCP ports: %s (%s)\n' "$(count_items "${TCP_EGRESS_PORTS:-}")" "${TCP_EGRESS_PORTS:-none}"
  printf 'UDP ports: %s (%s)\n' "$(count_items "${UDP_EGRESS_PORTS:-}")" "${UDP_EGRESS_PORTS:-none}"
  printf 'IPv6 outbound: %s\n' "$([[ "$ENABLE_IPV6_EGRESS" == 1 ]] && printf 'YES' || printf 'NO')"
  printf 'VPS Host: YES | Docker Containers: YES | Persistent after reboot: YES\n'
  if [[ -f "$SERVICE_TEST_RESULTS_FILE" ]]; then
    printf 'Last connectivity test: %s\n' "$(stat -c '%y' "$SERVICE_TEST_RESULTS_FILE" 2>/dev/null || printf 'recorded')"
  fi
}

unified_connectivity_test(){
  local id mode host port tcp_list udp_list container_id="" h_status c_status detail
  local tmp
  load_config || return 1
  if [[ -z "${NETWORK_LOADED:-}" ]]; then
    # shellcheck source=network.sh
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/network.sh" || return 1
  fi
  if command_exists docker; then
    container_id="$(docker ps --format '{{.ID}}' 2>/dev/null | head -1 || true)"
  fi
  tmp="$(mktemp)" || return 1
  section "Host + container connectivity test"
  if [[ -z "${SELECTED_SERVICE_IDS:-}" ]]; then
    warn "No services are selected; run Enable All Common Services first."
    rm -f -- "$tmp"
    return 0
  fi
  printf '%-5s %-26s %-12s %-14s %s\n' 'ID' 'SERVICE' 'HOST' 'CONTAINER' 'DETAIL'
  for id in $SELECTED_SERVICE_IDS; do
    mode="$(service_field "$id" 9 || true)"
    host="$(service_field "$id" 8 || true)"
    port=""
    tcp_list="$(service_field "$id" 4 || true)"
    udp_list="$(service_field "$id" 5 || true)"
    detail="no default endpoint"
    if [[ -z "$host" ]]; then
      printf '%-5s %-26s %-12s %-14s %s\n' "$id" "$(service_field "$id" 3)" \
        'MANUAL' 'MANUAL' "provide a destination to test ${id}"
      printf '%s|MANUAL|MANUAL|no default endpoint\n' "$id" >>"$tmp"
      continue
    fi
    case "$mode" in
      dns|tcp|http|https|tls|smtp|smtps|imap|imaps|pop3|pop3s) : ;;
      *) mode="tcp" ;;
    esac
    if [[ "$mode" == "dns" ]]; then
      port=53
    elif [[ -n "${tcp_list%% *}" && "${tcp_list%% *}" != "$tcp_list" ]]; then
      port="${tcp_list%% *}"
    elif [[ -n "$tcp_list" ]]; then
      port="$tcp_list"
    elif [[ -n "$udp_list" ]]; then
      port="${udp_list%% *}"
      mode="MANUAL"
    fi
    h_status="UNAVAILABLE"
    c_status="UNAVAILABLE"
    if [[ "$mode" != "MANUAL" && -n "$port" ]]; then
      run_probe probe_host "$mode" "$host" "$port" "$host" "/"
      h_status="$(probe_status "$PROBE_LAST_RC")"
      detail="${PROBE_LAST_OUTPUT//$'\n'/ }"
      detail="${detail:0:80}"
      if [[ -n "$container_id" ]]; then
        run_probe probe_container "$mode" "$container_id" "$host" "$port" "$host" "/"
        c_status="$(probe_status "$PROBE_LAST_RC")"
        [[ "$PROBE_LAST_RC" == 2 ]] && c_status="UNAVAILABLE"
      fi
    fi
    printf '%-5s %-26s %-12s %-14s %s\n' "$id" "$(service_field "$id" 3)" \
      "$h_status" "$c_status" "$detail"
    printf '%s|%s|%s|%s\n' "$id" "$h_status" "$c_status" "$detail" >>"$tmp"
  done
  mkdir -p -- "$(dirname -- "$SERVICE_TEST_RESULTS_FILE")" 2>/dev/null || true
  install -m 0600 -- "$tmp" "$SERVICE_TEST_RESULTS_FILE" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
  success "Connectivity results saved: ${SERVICE_TEST_RESULTS_FILE}"
  printf 'UNAVAILABLE means the probe tool or a suitable running container was not present; it is not a firewall failure.\n'
}

ufw_managed_rule_count(){
  local port="$1" proto="$2"
  command_exists ufw || { printf '0\n'; return 0; }
  ufw status 2>/dev/null | awk -v rule="${port}/${proto}" \
    -v comment='VPS-MANAGED container egress' '
      $1 == rule && $2 == "ALLOW" && $3 == "OUT" && index($0, comment) { n++ }
      END { print n+0 }'
}

ufw_conflict_count(){
  local port="$1" proto="$2"
  command_exists ufw || { printf '0\n'; return 0; }
  ufw status 2>/dev/null | awk -v rule="${port}/${proto}" \
    '$1 == rule && $2 == "DENY" && $3 == "OUT" { n++ } END { print n+0 }'
}

ufw_cleanup_duplicate_managed_out(){
  command_exists ufw || return 0
  local rule port proto
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    port="${rule%%/*}"
    proto="${rule##*/}"
    ufw delete allow out "$rule" >/dev/null 2>&1 || true
    log "Removed duplicate managed UFW egress rule ${rule}."
  done < <(ufw status 2>/dev/null | awk -v comment='VPS-MANAGED container egress' '
      $2 == "ALLOW" && $3 == "OUT" && index($0, comment) {
        if (seen[$1]++) print $1
      }')
  return 0
}

unified_audit_rules(){
  local p missing=0 duplicates=0 conflicts=0 count actual=""
  load_config || return 1
  recompute_effective_ports
  section "Firewall rule audit"
  for p in ${TCP_EGRESS_PORTS:-}; do
    count="$(ufw_managed_rule_count "$p" tcp)"
    (( count == 0 )) && missing=$((missing + 1))
    (( count > 1 )) && duplicates=$((duplicates + count - 1))
    conflicts=$((conflicts + "$(ufw_conflict_count "$p" tcp)"))
  done
  for p in ${UDP_EGRESS_PORTS:-}; do
    count="$(ufw_managed_rule_count "$p" udp)"
    (( count == 0 )) && missing=$((missing + 1))
    (( count > 1 )) && duplicates=$((duplicates + count - 1))
    conflicts=$((conflicts + "$(ufw_conflict_count "$p" udp)"))
  done
  printf 'UFW managed outbound : missing=%s duplicate=%s conflicting=%s\n' \
    "$missing" "$duplicates" "$conflicts"
  if command_exists nft && nft_managed_exists; then
    actual="$(nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_MANAGED" 2>/dev/null || true)"
    local jump_count expected_tcp=0 expected_udp=0 actual_tcp=0 actual_udp=0 block_count=0
    jump_count="$(nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" 2>/dev/null \
      | grep -c 'VPS-MANAGED-DOCKER-JUMP' || true)"
    [[ -z "$jump_count" ]] && jump_count=0
    if [[ -f "$NFT_STATE_FILE" ]]; then
      expected_tcp="$(grep -c 'tcp dport' "$NFT_STATE_FILE" || true)"
      expected_udp="$(grep -c 'udp dport' "$NFT_STATE_FILE" || true)"
    fi
    actual_tcp="$(grep -c 'tcp dport' <<<"$actual" || true)"
    actual_udp="$(grep -c 'udp dport' <<<"$actual" || true)"
    block_count="$(grep -Ec 'drop|reject' <<<"$actual" || true)"
    (( actual_tcp < expected_tcp )) && missing=$((missing + expected_tcp - actual_tcp))
    (( actual_udp < expected_udp )) && missing=$((missing + expected_udp - actual_udp))
    conflicts=$((conflicts + block_count))
    (( jump_count > 1 )) && duplicates=$((duplicates + jump_count - 1))
    (( jump_count == 0 )) && missing=$((missing + 1))
    local jump_first="no"
    nft_jump_is_first && jump_first="yes"
    [[ "$jump_first" == "yes" ]] || conflicts=$((conflicts + 1))
    printf 'nftables managed chain: expected=%s missing=%s duplicate_jumps=%s jump_first=%s\n' \
      "$((expected_tcp + expected_udp))" "$missing" "$((jump_count > 1 ? jump_count - 1 : 0))" "$jump_first"
  else
    printf 'nftables managed chain: not present (watcher will retry)\n'
  fi
  printf 'Total: missing=%s duplicate=%s conflicting=%s\n' "$missing" "$duplicates" "$conflicts"
  UNIFIED_AUDIT_MISSING="$missing"
  UNIFIED_AUDIT_DUPLICATES="$duplicates"
  UNIFIED_AUDIT_CONFLICTS="$conflicts"
}

ufw_cleanup_conflicting_managed_out(){
  command_exists ufw || return 0
  local rule port proto
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    port="${rule%%/*}"
    proto="${rule##*/}"
    ufw delete deny out "$rule" >/dev/null 2>&1 || true
    log "Removed conflicting managed UFW DENY rule ${rule}."
  done < <(ufw status 2>/dev/null | awk -v comment='VPS-MANAGED container egress' '
      $2 == "DENY" && $3 == "OUT" && index($0, comment) { print $1 }')
  return 0
}

unified_repair_rules(){
  unified_audit_rules || return 1
  if (( ${UNIFIED_AUDIT_DUPLICATES:-0} > 0 )); then
    ufw_cleanup_duplicate_managed_out
    nft_cleanup_duplicate_jumps
  fi
  ufw_cleanup_conflicting_managed_out
  ufw_apply_managed_egress || warn "UFW rules could not be reconciled."
  nft_apply || warn "nftables rules could not be reconciled; the watcher will retry."
  start_watcher || warn "Watcher installation failed."
  success "Managed firewall rules repaired; unrelated rules were left untouched."
  unified_audit_rules || true
}

unified_restore_service_state(){
  local dir="${1:-}" file
  if [[ -z "$dir" ]]; then
    mapfile -t dirs < <(find "$SERVICE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
    if (( ${#dirs[@]} == 0 )); then
      error "No unified service backups found."; return 1
    fi
    dir="${dirs[0]}"
  fi
  [[ -d "$dir" ]] || { error "Backup directory not found: ${dir}"; return 1; }
  unified_backup_service_state || return 1
  file="${dir}/$(basename -- "$CONF_FILE")"
  [[ -f "$file" ]] || { error "Backup has no configuration file: ${file}"; return 1; }
  cp -a -- "$file" "$CONF_FILE" || return 1
  for file in "$CUSTOM_SERVICES_FILE" "$NFT_STATE_FILE" "$SERVICE_TEST_RESULTS_FILE"; do
    local backup_file_path="${dir}/$(basename -- "$file")"
    if [[ -f "$backup_file_path" ]]; then
      mkdir -p -- "$(dirname -- "$file")" || return 1
      cp -a -- "$backup_file_path" "$file" || return 1
    elif [[ "$file" == "$CUSTOM_SERVICES_FILE" ]]; then
      rm -f -- "$file" 2>/dev/null || true
    fi
  done
  load_config || return 1
  recompute_effective_ports
  ufw_apply_managed_egress || warn "UFW rules could not be restored."
  nft_apply || warn "nftables rules could not be restored; the watcher will retry."
  start_watcher || warn "Watcher installation failed."
  success "Unified service configuration restored from ${dir}."
}

unified_backup_menu(){
  local answer
  section "Backup / Restore Configuration"
  printf '[1] Create backup now\n[2] Restore latest backup\n[0] Back\n'
  read -r -p "Choose an option: " answer || return 0
  case "$answer" in
    1) unified_backup_service_state ;;
    2) unified_restore_service_state ;;
    0) return 0 ;;
    *) warn "Invalid choice." ;;
  esac
}

unified_reconcile(){
  local force="${1:-0}"
  load_config || return 1
  recompute_effective_ports
  if command_exists ufw; then
    ufw_apply_managed_egress >/dev/null 2>&1 || true
  fi
  nft_reconcile "$force"
}

unified_service_menu(){
  local answer
  cat <<'MENU'
========== UNIFIED SERVICE ACCESS ==========

Configure outbound access for VPS Host + Docker Containers

[1] Select Services Individually
[2] Enable All Common Services
[3] Select Service Categories
[4] Add Custom TCP/UDP Ports
[5] Remove Selected Services
[6] View Enabled Services
[7] Test Host + Container Connectivity
[8] Repair Firewall Rules
[9] Backup / Restore Configuration
[0] Back to Main Menu

Choose an option:
MENU
  IFS= read -r answer || return 0
  case "$answer" in
    1) unified_select_individually ;;
    2) apply_named_preset all ;;
    3) unified_select_categories ;;
    4) unified_add_custom_service ;;
    5) unified_remove_services ;;
    6) unified_view_enabled ;;
    7) unified_connectivity_test ;;
    8) unified_repair_rules ;;
    9) unified_backup_menu ;;
    0|q|Q) log "Returning to the main menu." ;;
    *) warn "Invalid choice." ;;
  esac
}

unified_cli(){
  case "${1:-menu}" in
    menu) unified_service_menu ;;
    individual|one-by-one) unified_select_individually ;;
    preset) shift; apply_named_preset "${1:-standard}" "${2:-0}" ;;
    smart) shift; unified_smart_configure "${1:-hosting}" "${2:-1}" ;;
    custom) unified_add_custom_service ;;
    remove) unified_remove_services ;;
    view|status) unified_view_enabled ;;
    test) unified_connectivity_test ;;
    audit) unified_audit_rules ;;
    repair) unified_repair_rules ;;
    backup) unified_backup_service_state ;;
    restore) shift; unified_restore_service_state "${1:-}" ;;
    reconcile) unified_reconcile "${2:-0}" ;;
    *) error "Unknown service command: $1"; return 1 ;;
  esac
}

# Compatibility entry points used by the legacy menu and CLI.
service_selector(){ unified_service_menu; }
remove_selection_interactive(){ unified_remove_services; }

# ---------------------------------------------------------------------------
# Guided firewall setup (before and after service installation)
# ---------------------------------------------------------------------------

service_prompt_one_by_one(){ unified_select_individually; }

firewall_service_menu(){
  local answer
  section "Outbound service access"
  cat <<'SVC'
 1) Choose services one by one (SMTP, IMAP, databases, ...)
 2) Allow the standard outbound preset
 3) Allow all predefined outbound services
 0) Skip
SVC
  read -r -p "Choose an option: " answer || return 0
  case "$answer" in
    1) service_prompt_one_by_one ;;
    2) apply_named_preset standard ;;
    3) apply_named_preset all ;;
    0|q|Q) log "Outbound service selection skipped." ;;
    *) warn "Invalid choice; no changes made." ;;
  esac
}

# Run BEFORE service installation. interactive=0 applies safe defaults without
# prompting (used by `vps-setup run ... --yes`).
firewall_preflight(){
  local interactive="${1:-1}" id docker_selected=0
  shift || true
  section "Firewall setup before services"
  if (( interactive )); then
    if ! confirm "Configure UFW/nftables basics now (recommended before installing services)?"; then
      warn "Firewall basics skipped. Missing outbound rules can break databases, mail and Docker apps."
      return 0
    fi
  fi
  load_config || return 1
  if ! command_exists ufw || ! command_exists nft; then
    log "Installing firewall tools before services (ufw, nftables, iproute2)."
    pkg_install ufw nftables iproute2 || warn "Some firewall tools could not be installed."
  fi
  if command_exists ufw; then
    ufw_init || warn "UFW initialization failed; review the log."
  else
    warn "UFW is unavailable; configure your host firewall manually."
  fi
  for id in "$@"; do
    case "$id" in 3|4|5) docker_selected=1 ;; esac
  done
  if (( docker_selected )); then
    ENABLE_DOKPLOY_INGRESS=1
    ENABLE_MSS_CLAMP=1
    log "Automatic docker_gwbridge/Traefik ingress and evidence-based MSS repair enabled."
    if declare -F network_configure_from_allowed_ports >/dev/null 2>&1; then
      network_configure_from_allowed_ports "$interactive" \
        || warn "Dynamic target selection was deferred; pass --target to the network doctor later."
    fi
  fi
  save_config || return 1
  nft_apply || warn "nftables chain could not be applied now; the watcher will retry."
  start_watcher || warn "Watcher installation failed; use Repair and Recovery to retry."
  success "Firewall basics configured."
}

# Run AFTER service installation. interactive=0 applies the standard preset
# without prompting.
firewall_postflight(){
  local interactive="${1:-1}"
  section "Firewall configuration after services"
  if (( interactive )); then
    if ! confirm "Configure UFW/nftables and allow outbound services now?"; then
      log "Firewall service selection skipped."
      return 0
    fi
  fi
  load_config || return 1
  if command_exists ufw; then
    ufw_init || warn "UFW initialization failed; review the log."
  else
    warn "UFW is unavailable; host firewall configuration was skipped."
  fi
  nft_apply || warn "nftables chain could not be applied now; the watcher will retry."
  start_watcher || warn "Watcher installation failed; use Repair and Recovery to retry."
  if (( interactive )); then
    firewall_service_menu
  else
    log "Non-interactive run: applying the standard/reputed outbound service preset."
    apply_service_preset "$STANDARD_SERVICE_IDS" "standard/reputed services (non-interactive default)" 1
  fi
  # The allowed port list is only final after the service menu/preset above.
  # Persist the doctor's dynamic target here; interactive runs are asked to
  # choose when more than one TCP port is allowed, non-interactive runs use the
  # first allowed port deterministically.
  load_config || return 1
  if config_bool "$ENABLE_MSS_CLAMP" \
     && declare -F network_configure_from_allowed_ports >/dev/null 2>&1; then
    network_configure_from_allowed_ports "$interactive" \
      || warn "Dynamic network target was deferred; pass --target to the doctor later."
  fi
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
  local p added_tcp="" added_udp="" kept_tcp="" kept_udp=""
  for p in $MANAGED_UFW_TCP; do
    if [[ " ${TCP_EGRESS_PORTS:-} " == *" ${p} "* ]]; then
      kept_tcp+="$p "
    else
      ufw_delete_out "$p" tcp
      log "Removed managed UFW egress rule ${p}/tcp."
    fi
  done
  for p in $MANAGED_UFW_UDP; do
    if [[ " ${UDP_EGRESS_PORTS:-} " == *" ${p} "* ]]; then
      kept_udp+="$p "
    else
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
  # Keep ownership of rules we added earlier that are still wanted, otherwise
  # a later run would forget them and never be able to remove them.
  MANAGED_UFW_TCP="$(filter_ports "${kept_tcp}${added_tcp}")"
  MANAGED_UFW_UDP="$(filter_ports "${kept_udp}${added_udp}")"
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
            if confirm_typed "I-UNDERSTAND-PUBLIC-${port}"; then
              allow=1
            else
              log "Cancelled."
              continue
            fi
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
    ip -4 -o addr show dev "$name" 2>/dev/null \
      | awk -v n="$name" '$4 ~ /\// { print n, $4, "ipv4" }'
    if config_bool "$ENABLE_IPV6_EGRESS"; then
      while IFS= read -r addr_cidr; do
        addr="${addr_cidr%/*}"
        valid_ipv6 "$addr" && printf '%s %s ipv6\n' "$name" "$addr_cidr"
      done < <(ip -6 -o addr show dev "$name" 2>/dev/null \
        | awk '$3 == "inet6" && $4 ~ /\// && $4 !~ /^fe80/ { print $4 }')
    fi
  done
}

selected_ipv6_enabled(){
  local id flag any=0
  [[ -n "${SELECTED_SERVICE_IDS:-}" ]] || return 0
  for id in ${SELECTED_SERVICE_IDS:-}; do
    flag="$(service_field "$id" 7 2>/dev/null || true)"
    [[ "$flag" == "1" ]] && any=1
  done
  [[ -n "${CUSTOM_TCP_PORTS:-}${CUSTOM_UDP_PORTS:-}" ]] && any=1
  (( any == 1 ))
}

# Prefer the live Traefik container address on the selected bridge. Falls back
# to TRAEFIK_IP from config when Docker is unavailable or the address is not
# readable, so the watcher can still install a stable rule set.
traefik_ip_for_bridge(){
  local detected="" fmt
  if command_exists docker; then
    detected="$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null \
      | awk 'tolower($0) ~ /traefik/ { print $1; exit }')"
    if [[ -n "$detected" ]]; then
      fmt="{{index .NetworkSettings.Networks \"${TRAEFIK_BRIDGE}\" \"IPAddress\"}}"
      detected="$(docker inspect -f "$fmt" "$detected" 2>/dev/null)"
    fi
  fi
  if valid_ipv4 "$detected" && [[ "$detected" != "<no value>" ]]; then
    printf '%s\n' "$detected"
  else
    printf '%s\n' "$TRAEFIK_IP"
  fi
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

# Only jumps carrying the toolkit comment are owned by us. This keeps unrelated
# jumps (for example Dokploy's dokploy_auto chain) out of cleanup operations.
nft_managed_jump_handles(){
  command_exists nft || return 0
  nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" 2>/dev/null \
    | awk -v managed="$NFT_MANAGED" '
        index($0, "jump " managed) && index($0, "VPS-MANAGED-DOCKER-JUMP") {
          for (i = NF; i > 0; i--) if ($i == "handle") { print $(i+1); break }
        }'
}

nft_jump_exists(){
  local handle
  while IFS= read -r handle; do
    [[ -n "$handle" ]] && return 0
  done < <(nft_managed_jump_handles)
  return 1
}

# A guarded jump must be the first rule in the parent chain. If it is appended
# after an unrelated drop or a verdict-returning chain, our egress rules are
# never evaluated. This is the exact failure mode reported on Dokploy hosts.
nft_jump_is_first(){
  local first
  first="$(nft -a list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" 2>/dev/null \
    | awk '/# handle/ { print; exit }')"
  [[ -n "$first" ]] \
    && [[ "$first" == *"jump ${NFT_MANAGED}"* ]] \
    && [[ "$first" == *"VPS-MANAGED-DOCKER-JUMP"* ]]
}

nft_cleanup_duplicate_jumps(){
  local -a handles=()
  local i
  if ! command_exists nft; then
    return 0
  fi
  mapfile -t handles < <(nft_managed_jump_handles)
  if (( ${#handles[@]} > 1 )); then
    warn "Removing duplicate toolkit jump rules (${#handles[@]} found)."
    for ((i=1; i<${#handles[@]}; i++)); do
      nft delete rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_PARENT" handle "${handles[$i]}" 2>/dev/null || true
    done
  fi
}

# Validate without hiding parser output. Failed rules are preserved at a stable
# path so an operator can inspect and replay them with: nft -c -f <file>
nft_validate_rules_file(){
  local file="$1" line status=0
  command_exists nft || return 0
  mkdir -p -- "$(dirname -- "$NFT_VALIDATION_LOG")" 2>/dev/null || true
  if ! nft -c -f "$file" >"$NFT_VALIDATION_LOG" 2>&1; then
    status=1
    error "nftables validation failed; generated rules were NOT applied."
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  %s\n' "$line" >&2
    done <"$NFT_VALIDATION_LOG"
    mkdir -p -- "$(dirname -- "$NFT_FAILED_RULES_FILE")" 2>/dev/null || true
    cp -a -- "$file" "$NFT_FAILED_RULES_FILE" 2>/dev/null || true
    chmod 0600 -- "$NFT_FAILED_RULES_FILE" 2>/dev/null || true
    warn "Parser output: ${NFT_VALIDATION_LOG}"
    warn "Failed rules preserved: ${NFT_FAILED_RULES_FILE}"
  else
    rm -f -- "$NFT_VALIDATION_LOG" 2>/dev/null || true
  fi
  return "$status"
}

build_nft_ruleset(){
  local wan tcp_set="" udp_set="" bridge subnet tip="" saddr_key daddr_key
  NFT_RULES=()
  wan="$(get_wan)"
  [[ -n "$wan" ]] || { warn "No default-route interface detected."; return 1; }

  NFT_RULES+=("add chain ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED}")
  NFT_RULES+=("flush chain ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED}")
  # Keep exactly one toolkit jump and keep it first, before any unrelated drop
  # or verdict-returning chain. All changes stay inside one atomic nft -f.
  local jump_handle
  local -a jump_handles=()
  mapfile -t jump_handles < <(nft_managed_jump_handles)
  if (( ${#jump_handles[@]} == 0 )); then
    NFT_RULES+=("insert rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_PARENT} jump ${NFT_MANAGED} comment \"VPS-MANAGED-DOCKER-JUMP\"")
  elif (( ${#jump_handles[@]} > 1 )) || ! nft_jump_is_first; then
    for jump_handle in "${jump_handles[@]}"; do
      NFT_RULES+=("delete rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_PARENT} handle ${jump_handle}")
    done
    NFT_RULES+=("insert rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_PARENT} jump ${NFT_MANAGED} comment \"VPS-MANAGED-DOCKER-JUMP\"")
  fi

  [[ -n "${TCP_EGRESS_PORTS:-}" ]] && tcp_set="{ ${TCP_EGRESS_PORTS// /,} }"
  [[ -n "${UDP_EGRESS_PORTS:-}" ]] && udp_set="{ ${UDP_EGRESS_PORTS// /,} }"

  while read -r bridge subnet address_family; do
    [[ -n "${bridge:-}" && -n "${subnet:-}" ]] || continue
    address_family="${address_family:-ipv4}"
    if [[ "$address_family" == "ipv6" ]]; then
      config_bool "$ENABLE_IPV6_EGRESS" || continue
      selected_ipv6_enabled || continue
      saddr_key="ip6 saddr"
      daddr_key="ip6 daddr"
    else
      saddr_key="ip saddr"
      daddr_key="ip daddr"
    fi
    if [[ -n "$tcp_set" ]]; then
      NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${bridge}\" oifname \"${wan}\" ${saddr_key} ${subnet} tcp dport ${tcp_set} ct state '{ new, established, related }' counter accept comment \"DOCKER-EGRESS-TCP\"")
    fi
    if [[ -n "$udp_set" ]]; then
      NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${bridge}\" oifname \"${wan}\" ${saddr_key} ${subnet} udp dport ${udp_set} ct state '{ new, established, related }' counter accept comment \"DOCKER-EGRESS-UDP\"")
    fi
    NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${wan}\" oifname \"${bridge}\" ${daddr_key} ${subnet} ct state '{ established, related }' counter accept comment \"DOCKER-EGRESS-RETURN\"")
  done < <(bridge_inventory)

  # Automatic Traefik ingress for Docker-based panels. These rules live in the
  # toolkit-managed chain, which is jumped from the existing forward chain, and
  # carry stable comments so the watcher can restore them after any reboot or
  # docker_gwbridge recreation without manual nft commands.
  if config_bool "$ENABLE_DOKPLOY_INGRESS"; then
    if ip link show "$TRAEFIK_BRIDGE" >/dev/null 2>&1; then
      tip="$(traefik_ip_for_bridge)"
      NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${wan}\" oifname \"${TRAEFIK_BRIDGE}\" ip daddr ${tip} tcp dport '{ 80, 443 }' ct status dnat counter accept comment \"DOKPLOY-INGRESS\"")
      NFT_RULES+=("add rule ${NFT_FAMILY} ${NFT_TABLE} ${NFT_MANAGED} iifname \"${TRAEFIK_BRIDGE}\" oifname \"${wan}\" ip saddr ${tip} ct state '{ established, related }' counter accept comment \"DOKPLOY-RETURN\"")
    else
      warn "Dokploy ingress enabled but bridge ${TRAEFIK_BRIDGE} is not present; the watcher will retry."
    fi
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

  if ! nft_validate_rules_file "$tmp"; then
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
    printf '* * * * * %s/scripts/firewall.sh service-reconcile >>%s/firewall-watch.log 2>&1\n' \
      "$INSTALL_DIR" "$LOG_DIR"
    printf '%s\n' "$marker"
    printf '* * * * * %s/scripts/network.sh reconcile 0 >>%s/firewall-watch.log 2>&1\n' \
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
    if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
      systemctl restart "$UNIT_NAME" || return 1
    else
      systemctl enable --now "$UNIT_NAME" || return 1
    fi
    success "Persistent firewall and network watcher enabled (${UNIT_NAME})."
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
  ufw_apply_managed_egress || warn "UFW egress rules were not updated."
  save_config || return 1
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
    service|unified) shift; unified_cli "$@" ;;
    service-reconcile) unified_reconcile "${2:-0}" ;;
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
