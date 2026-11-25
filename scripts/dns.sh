#!/usr/bin/env bash
# dns.sh - DNS/domain routing integrated with the existing VPS Setup Toolkit.
#
# Scope: Cloudflare first, provider-agnostic state for everything else. Every
# change is outbound API access plus explicit inbound origin allow rules for
# Cloudflare IP ranges. Nothing here creates a second firewall manager or a
# competing watcher.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

DNS_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi

DNS_STATE_FILE="${VPS_SETUP_DNS_STATE:-${STATE_DIR}/dns-domains.rules}"
CF_TOKEN_FILE="${VPS_SETUP_CF_TOKEN_FILE:-${STATE_DIR}/cloudflare.token}"
CF_IPS_FILE="${VPS_SETUP_CF_IPS_FILE:-${STATE_DIR}/cloudflare-ips.json}"
CF_ORIGIN_RULES_FILE="${VPS_SETUP_CF_ORIGIN_RULES:-${STATE_DIR}/cloudflare-origin.rules}"
DNS_BACKUP_DIR="${VPS_SETUP_DNS_BACKUP_DIR:-${BACKUP_DIR}/dns}"
DNS_API="${VPS_SETUP_DNS_API:-https://api.cloudflare.com/client/v4}"
DNS_IPS_URL="${VPS_SETUP_DNS_IPS_URL:-${DNS_API}/ips}"

# Some systems expose a broken python3 launcher. Prefer a working interpreter
# so Cloudflare JSON parsing never silently fails.
DNS_PYTHON="${VPS_SETUP_PYTHON_BIN:-}"
if [[ -z "$DNS_PYTHON" ]]; then
  for _dns_python_candidate in python3 python; do
    if command_exists "$_dns_python_candidate" \
      && "$_dns_python_candidate" -c 'import sys' >/dev/null 2>&1; then
      DNS_PYTHON="$_dns_python_candidate"
      break
    fi
  done
fi
unset _dns_python_candidate

dns_backup(){
  local stamp dir file
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dir="${DNS_BACKUP_DIR}/${stamp}"
  mkdir -p -- "$dir" 2>/dev/null || return 1
  for file in "$DNS_STATE_FILE" "$CF_IPS_FILE" "$CF_ORIGIN_RULES_FILE"; do
    [[ -f "$file" ]] && cp -a -- "$file" "${dir}/$(basename -- "$file")" 2>/dev/null || true
  done
  return 0
}

dns_valid_domain(){
  local domain="${1:-}"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] \
    && [[ "$domain" != *..* ]]
}

dns_json_build(){
  [[ -n "$DNS_PYTHON" ]] || { error 'A working python3/python interpreter is required.'; return 1; }
  "$DNS_PYTHON" - "$@" <<'PY'
import json, sys
a = sys.argv[1:]
d = {}
for i in range(0, len(a), 2):
    v = a[i + 1]
    if v == "true":
        v = True
    elif v == "false":
        v = False
    d[a[i]] = v
print(json.dumps(d))
PY
}

dns_json_query(){
  local file="$1" path="${2:-}" value
  [[ -n "$DNS_PYTHON" ]] || { error 'A working python3/python interpreter is required.'; return 1; }
  value="$("$DNS_PYTHON" - "$file" "$path" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)
for key in [p for p in sys.argv[2].split(".") if p]:
    if isinstance(data, dict):
        data = data.get(key)
    elif isinstance(data, list) and key.isdigit():
        idx = int(key)
        data = data[idx] if idx < len(data) else None
    else:
        data = None
    if data is None:
        break
if isinstance(data, list):
    print(data[0] if data else "")
elif isinstance(data, bool):
    print("true" if data else "false")
elif data is not None:
    print(data)
PY
)"
  printf '%s\n' "$value"
}

dns_json_lines(){
  local file="$1" path="$2"
  [[ -n "$DNS_PYTHON" ]] || { error 'A working python3/python interpreter is required.'; return 1; }
  "$DNS_PYTHON" - "$file" "$path" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
except Exception:
    sys.exit(1)
for key in [p for p in sys.argv[2].split(".") if p]:
    data = data.get(key) if isinstance(data, dict) else None
if isinstance(data, list):
    for item in data:
        print(item)
PY
}

cf_token(){
  [[ -n "${VPS_SETUP_CLOUDFLARE_TOKEN:-}" ]] && { printf '%s\n' "$VPS_SETUP_CLOUDFLARE_TOKEN"; return 0; }
  if [[ -f "$CF_TOKEN_FILE" ]]; then
    cat -- "$CF_TOKEN_FILE"
    return 0
  fi
  local token=""
  if [[ -t 0 ]]; then
    read -rs -p 'Cloudflare API token: ' token || return 1
    printf '\n' >&2
    [[ -n "$token" ]] || return 1
    if confirm 'Save this token in a root-only file?'; then
      mkdir -p -- "$(dirname -- "$CF_TOKEN_FILE")" || return 1
      printf '%s\n' "$token" >"$CF_TOKEN_FILE"
      chmod 0600 -- "$CF_TOKEN_FILE"
    fi
    printf '%s\n' "$token"
    return 0
  fi
  error "Set VPS_SETUP_CLOUDFLARE_TOKEN or create ${CF_TOKEN_FILE} (mode 0600)."
  return 1
}

cf_api(){
  local method="$1" path="$2" data="${3:-}" token response status tmp
  token="$(cf_token)" || return 1
  tmp="$(mktemp)" || return 1
  local -a args=(curl -sS --max-time 20 -o "$tmp" -w '%{http_code}' -X "$method" "${DNS_API}${path}"
    -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json')
  [[ -n "$data" ]] && args+=(-d "$data")
  status="$("${args[@]}")" || { rm -f -- "$tmp"; error "Cloudflare API request failed."; return 1; }
  if [[ ! "$status" =~ ^2 ]]; then
    error "Cloudflare API returned HTTP ${status}: $(head -c 400 "$tmp" 2>/dev/null)"
    rm -f -- "$tmp"
    return 1
  fi
  if [[ "$(dns_json_query "$tmp" success)" != "true" ]]; then
    error "Cloudflare API error: $(head -c 400 "$tmp" 2>/dev/null)"
    rm -f -- "$tmp"
    return 1
  fi
  cat -- "$tmp"
  rm -f -- "$tmp"
  return 0
}

cf_zone_id(){
  local host="${1#.}" response tmp id
  tmp="$(mktemp)" || return 1
  while [[ -n "$host" && "$host" == *.* ]]; do
    response="$(cf_api GET "/zones?name=${host}&per_page=1" 2>/dev/null)" || { host="${host#*.}"; continue; }
    printf '%s\n' "$response" >"$tmp"
    id="$(dns_json_query "$tmp" result.0.id)"
    if [[ -n "$id" ]]; then
      rm -f -- "$tmp"
      printf '%s\n' "$id"
      return 0
    fi
    host="${host#*.}"
  done
  rm -f -- "$tmp"
  return 1
}

cf_record_id(){
  local zone="$1" name="$2" type="$3" response tmp
  tmp="$(mktemp)" || return 1
  response="$(cf_api GET "/zones/${zone}/dns_records?name=${name}&type=${type}&per_page=1")" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$response" >"$tmp"
  dns_json_query "$tmp" result.0.id
  rm -f -- "$tmp"
  return 0
}

cf_upsert_record(){
  local zone="$1" name="$2" type="$3" content="$4" proxied="$5" record_id data ttl=1
  data="$(dns_json_build type "$type" name "$name" content "$content" ttl "$ttl" proxied "$proxied")" || return 1
  record_id="$(cf_record_id "$zone" "$name" "$type")" || return 1
  if [[ -n "$record_id" ]]; then
    cf_api PUT "/zones/${zone}/dns_records/${record_id}" "$data" >/dev/null || return 1
    log "Updated Cloudflare ${type} record ${name} -> ${content}."
  else
    cf_api POST "/zones/${zone}/dns_records" "$data" >/dev/null || return 1
    log "Created Cloudflare ${type} record ${name} -> ${content}."
  fi
}

dns_public_ipv4(){
  local ip="${VPS_SETUP_PUBLIC_IPV4:-}"
  if [[ -z "$ip" ]] && command_exists curl; then
    ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi
  valid_ipv4 "$ip" || { error "Could not detect a public IPv4 address; set VPS_SETUP_PUBLIC_IPV4."; return 1; }
  printf '%s\n' "$ip"
}

dns_public_ipv6(){
  local ip="${VPS_SETUP_PUBLIC_IPV6:-}"
  if [[ -z "$ip" ]] && command_exists curl; then
    ip="$(curl -6 -fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
  fi
  valid_ipv6 "$ip" || return 1
  printf '%s\n' "$ip"
}

dns_cf_refresh_ips(){
  local tmp success
  tmp="$(mktemp)" || return 1
  if ! curl -fsS --max-time 20 "$DNS_IPS_URL" -o "$tmp"; then
    warn "Could not refresh Cloudflare IP ranges."
    rm -f -- "$tmp"
    return 1
  fi
  success="$(dns_json_query "$tmp" success)"
  if [[ "$success" != "true" ]]; then
    error "Cloudflare IP endpoint returned an invalid response."
    rm -f -- "$tmp"
    return 1
  fi
  dns_backup || true
  {
    dns_json_lines "$tmp" result.ipv4_cidrs
    dns_json_lines "$tmp" result.ipv6_cidrs
  } | grep -E '^[0-9A-Fa-f:.]+/[0-9]+$' | sort -u >"$tmp.cidrs"
  mkdir -p -- "$(dirname -- "$CF_IPS_FILE")" || { rm -f -- "$tmp"; return 1; }
  install -m 0600 -- "$tmp.cidrs" "$CF_IPS_FILE" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp" "$tmp.cidrs"
  success "Cloudflare IP ranges saved: ${CF_IPS_FILE}"
}

dns_ufw_origin_rule_exists(){
  local cidr="$1" port="$2"
  command_exists ufw || return 1
  ufw status 2>/dev/null | awk -v cidr="$cidr" -v rule="${port}/tcp" \
    '$1 == rule && $2 == "ALLOW" && $3 == "IN" && index($0, cidr) { found=1 } END { exit !found }'
}

dns_cf_origin_apply(){
  local cidr port desired="" tracked
  command_exists ufw || { warn "UFW is not installed; origin allow rules were skipped."; return 1; }
  [[ -f "$CF_IPS_FILE" ]] || dns_cf_refresh_ips || return 1
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] || continue
    for port in 80 443; do
      desired+="${cidr}|${port}"$'\n'
      if ! dns_ufw_origin_rule_exists "$cidr" "$port"; then
        ufw allow from "$cidr" to any port "$port" proto tcp comment 'Cloudflare origin (vps-setup managed)' >/dev/null || continue
        log "Allowed Cloudflare ${cidr} -> ${port}/tcp."
      fi
    done
  done <"$CF_IPS_FILE"
  if [[ -f "$CF_ORIGIN_RULES_FILE" ]]; then
    while IFS='|' read -r cidr port; do
      [[ -n "$cidr" ]] || continue
      grep -Fxq -- "${cidr}|${port}" <<<"$desired" && continue
      ufw delete allow from "$cidr" to any port "$port" proto tcp >/dev/null 2>&1 || true
      log "Removed stale Cloudflare origin rule ${cidr} -> ${port}/tcp."
    done <"$CF_ORIGIN_RULES_FILE"
  fi
  printf '%s' "$desired" | grep -E '^.+\|[0-9]+$' | sort -u >"$CF_ORIGIN_RULES_FILE" || true
  chmod 0600 -- "$CF_ORIGIN_RULES_FILE" 2>/dev/null || true
  success "Cloudflare origin allow rules are active for HTTP/HTTPS."
}

dns_configure_domain(){
  local domain app dns_type target proxied zone name line
  domain="${VPS_SETUP_DOMAIN:-${1:-}}"
  app="${VPS_SETUP_DNS_APP:-${2:-app}}"
  dns_type="${VPS_SETUP_DNS_TYPE:-${3:-A}}"
  target="${VPS_SETUP_DNS_TARGET:-${4:-}}"
  proxied="${VPS_SETUP_DNS_PROXIED:-${5:-true}}"
  [[ -n "$domain" ]] || read -r -p 'Domain (for example app.example.com): ' domain || return 0
  [[ -n "$app" ]] || read -r -p 'Application name (Traefik router label): ' app || return 0
  dns_valid_domain "$domain" || { error "Invalid domain '${domain}'."; return 1; }
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { error "Invalid app name '${app}'."; return 1; }
  case "${dns_type,,}" in
    a) dns_type="A"; [[ -n "$target" ]] || target="$(dns_public_ipv4)" || return 1; valid_ipv4 "$target" || { error "Invalid IPv4 target."; return 1; } ;;
    aaaa) dns_type="AAAA"; [[ -n "$target" ]] || target="$(dns_public_ipv6)" || return 1; valid_ipv6 "$target" || { error "Invalid IPv6 target."; return 1; } ;;
    cname) dns_type="CNAME"; [[ -n "$target" ]] || { error "CNAME requires a target hostname."; return 1; } ;;
    *) error "DNS type must be A, AAAA or CNAME."; return 1 ;;
  esac
  case "${proxied,,}" in true|1|yes) proxied="true" ;; *) proxied="false" ;; esac
  zone="$(cf_zone_id "$domain")" || { error "No Cloudflare zone found for ${domain}."; return 1; }
  name="$domain"
  cf_upsert_record "$zone" "$name" "$dns_type" "$target" "$proxied" || return 1

  dns_backup || true
  touch "$DNS_STATE_FILE"
  line="${domain}|cloudflare|${dns_type}|${name}|${target}|${proxied}|${zone}|${app}"
  grep -Fv "|${domain}|" "$DNS_STATE_FILE" >"${DNS_STATE_FILE}.tmp" || true
  printf '%s\n' "$line" >>"${DNS_STATE_FILE}.tmp"
  install -m 0600 -- "${DNS_STATE_FILE}.tmp" "$DNS_STATE_FILE"
  rm -f -- "${DNS_STATE_FILE}.tmp"

  [[ "$proxied" == "true" ]] && dns_cf_origin_apply || true
  success "Domain ${domain} configured (${dns_type} -> ${target}, proxied=${proxied})."
  dns_labels "$domain" "$app"
}

dns_labels(){
  local domain="${1:-}" app="${2:-app}"
  section "Traefik / Docker labels for ${domain:-domain}"
  cat <<EOF
services:
  ${app}:
    labels:
      traefik.enable=true
      traefik.http.routers.${app}.rule=Host(\`${domain}\`)
      traefik.http.routers.${app}.entrypoints=websecure
      traefik.http.routers.${app}.tls=true
      traefik.http.routers.${app}.tls.certresolver=letsencrypt
      traefik.http.services.${app}.loadbalancer.server.port=3000
EOF
  printf '\nAttach the app to the same external network as Traefik (for example dokploy-network).\n'
}

dns_list(){
  section "Configured domains"
  if [[ ! -s "$DNS_STATE_FILE" ]]; then
    printf 'No domains configured.\n'
    return 0
  fi
  printf '%-30s %-10s %-8s %-40s %-8s %s\n' DOMAIN PROVIDER TYPE TARGET PROXIED APP
  while IFS='|' read -r domain provider type name target proxied zone app; do
    [[ -n "$domain" ]] || continue
    printf '%-30s %-10s %-8s %-40s %-8s %s\n' "$domain" "$provider" "$type" "$target" "$proxied" "$app"
  done <"$DNS_STATE_FILE"
}

dns_remove_domain(){
  local domain="${VPS_SETUP_DOMAIN:-${1:-}}" zone type name tmp
  [[ -n "$domain" ]] || read -r -p 'Domain to remove: ' domain || return 0
  dns_valid_domain "$domain" || { error "Invalid domain."; return 1; }
  tmp="$(mktemp)" || return 1
  grep -F "|${domain}|" "$DNS_STATE_FILE" >"$tmp" 2>/dev/null || true
  IFS='|' read -r _ _ type name _ _ zone _ <"$tmp" || true
  rm -f -- "$tmp"
  if [[ -n "${zone:-}" ]]; then
    type="${type:-A}"
    name="${name:-$domain}"
    local record_id
    record_id="$(cf_record_id "$zone" "$name" "$type")" || true
    [[ -n "$record_id" ]] && cf_api DELETE "/zones/${zone}/dns_records/${record_id}" >/dev/null \
      && log "Removed Cloudflare record ${name}."
  fi
  dns_backup || true
  grep -Fv "|${domain}|" "$DNS_STATE_FILE" >"${DNS_STATE_FILE}.tmp" || true
  install -m 0600 -- "${DNS_STATE_FILE}.tmp" "$DNS_STATE_FILE" || { rm -f -- "${DNS_STATE_FILE}.tmp"; return 1; }
  rm -f -- "${DNS_STATE_FILE}.tmp"
  success "Domain ${domain} removed from toolkit state."
}

dns_test_domain(){
  local domain="${VPS_SETUP_DOMAIN:-${1:-}}" container_id="" h_status c_status
  [[ -n "$domain" ]] || read -r -p 'Domain to test: ' domain || return 0
  dns_valid_domain "$domain" || { error "Invalid domain."; return 1; }
  if [[ -z "${NETWORK_LOADED:-}" ]]; then
    # shellcheck source=network.sh
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/network.sh" || return 1
  fi
  if command_exists docker; then
    container_id="$(docker ps --format '{{.ID}}' 2>/dev/null | head -1 || true)"
  fi
  run_probe probe_host dns "$domain" "" "" ""
  h_status="$(probe_status "$PROBE_LAST_RC")"
  c_status="UNAVAILABLE"
  if [[ -n "$container_id" ]]; then
    run_probe probe_container dns "$container_id" "$domain" "" "" ""
    c_status="$(probe_status "$PROBE_LAST_RC")"
  fi
  printf 'Domain: %s | Host: %s | Container: %s\n' "$domain" "$h_status" "$c_status"
}

dns_menu(){
  cat <<'MENU'
========== DNS & DOMAIN ROUTING ==========

Connect a domain to a VPS app and allow Cloudflare origin traffic

[1] Configure a domain (Cloudflare)
[2] List configured domains
[3] Remove a domain
[4] Refresh Cloudflare IP ranges
[5] Apply Cloudflare origin firewall rules
[6] Show Traefik label guidance
[7] Test domain resolution (host + container)
[0] Back to Main Menu

Choose an option:
MENU
  local answer
  IFS= read -r answer || return 0
  case "$answer" in
    1) dns_configure_domain ;;
    2) dns_list ;;
    3) dns_remove_domain ;;
    4) dns_cf_refresh_ips ;;
    5) dns_cf_origin_apply ;;
    6) dns_labels "${VPS_SETUP_DOMAIN:-}" "${VPS_SETUP_DNS_APP:-app}" ;;
    7) dns_test_domain ;;
    0|q|Q) log 'Returning to the main menu.' ;;
    *) warn 'Invalid choice.' ;;
  esac
}

dns_cli(){
  case "${1:-menu}" in
    menu) dns_menu ;;
    configure|set) shift; dns_configure_domain "$@" ;;
    list|status) dns_list ;;
    remove|delete) shift; dns_remove_domain "$@" ;;
    refresh|ips) dns_cf_refresh_ips ;;
    origin|allow) dns_cf_origin_apply ;;
    labels|traefik) shift; dns_labels "${1:-}" "${2:-app}" ;;
    test) shift; dns_test_domain "$@" ;;
    *) error "Unknown DNS command: $1"; return 1 ;;
  esac
}
