#!/usr/bin/env bash
# network.sh - Sentinel Container Network Doctor and safe auto-repair.
#
# Diagnoses the VPS-host-versus-container connection path and manages only the
# toolkit-owned iptables mangle chain VPS-SENTINEL-MSS. It never disables UFW,
# flushes a full ruleset, changes physical MTUs, recreates Swarm networks, or
# disables TLS verification.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
fi

NETWORK_LOADED=1
if [[ -z "${COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"
fi
if [[ -z "${FIREWALL_LOADED:-}" ]]; then
  # shellcheck source=firewall.sh
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/firewall.sh"
fi

MSS_CHAIN="VPS-SENTINEL-MSS"
MSS_JUMP_COMMENT="VPS-SENTINEL-JUMP"
NETWORK_TIMEOUT="${VPS_SETUP_NETWORK_TIMEOUT:-5}"
NETWORK_HTTP_TIMEOUT="${VPS_SETUP_NETWORK_HTTP_TIMEOUT:-8}"

NETWORK_STATE_FILE="${VPS_SETUP_NETWORK_STATE:-${STATE_DIR}/network-mss.rules}"
NETWORK_CHANGE_LOG="${VPS_SETUP_NETWORK_CHANGES:-${STATE_DIR}/network-changes.log}"

NETWORK_CONTAINER=""
NETWORK_TARGET=""
NETWORK_TARGET_GIVEN=0
NETWORK_PROTOCOL="https"
NETWORK_SNI=""
NETWORK_FRESH=3
NETWORK_QUIET=0
NETWORK_ROOT_CAUSE=""
NETWORK_CAUSE_DETAIL=""
NETWORK_MTU_MISMATCH=0
NETWORK_WAN_IF=""
NETWORK_WAN_MTU=""
REPAIR_PLAN=()
PROBE_LAST_OUTPUT=""
PROBE_LAST_RC=1

# ---------------------------------------------------------------------------
# Target parsing and service profiles
# ---------------------------------------------------------------------------

protocol_default_port(){
  case "${1:-https}" in
    http|s3) printf '80\n' ;;
    https|smtps|imaps|pop3s|mqtts) printf '443\n' ;;
    smtp) printf '587\n' ;;
    imap) printf '143\n' ;;
    pop3) printf '110\n' ;;
    dns|ntp) printf '53\n' ;;
    ntp) printf '123\n' ;;
    ssh|git) printf '22\n' ;;
    mysql|mariadb) printf '3306\n' ;;
    postgres|postgresql) printf '5432\n' ;;
    mssql) printf '1433\n' ;;
    oracle) printf '1521\n' ;;
    redis) printf '6379\n' ;;
    mongodb) printf '27017\n' ;;
    elasticsearch) printf '9200\n' ;;
    rabbitmq) printf '5671\n' ;;
    mqtt) printf '1883\n' ;;
    *) printf '443\n' ;;
  esac
}

# Map an allowed firewall port to a diagnostic profile. This keeps the doctor
# on the service the administrator already approved instead of a fixed port.
protocol_for_port(){
  case "${1:-}" in
    80|8080|8000|3000) printf 'http\n' ;;
    443|8443) printf 'https\n' ;;
    25|587) printf 'smtp\n' ;;
    465) printf 'smtps\n' ;;
    143) printf 'imap\n' ;;
    993) printf 'imaps\n' ;;
    110) printf 'pop3\n' ;;
    995) printf 'pop3s\n' ;;
    22) printf 'ssh\n' ;;
    53) printf 'dns\n' ;;
    123) printf 'ntp\n' ;;
    3306|23306) printf 'mysql\n' ;;
    5432) printf 'postgres\n' ;;
    1433) printf 'mssql\n' ;;
    1521) printf 'oracle\n' ;;
    6379) printf 'redis\n' ;;
    27017) printf 'mongodb\n' ;;
    9000|24900) printf 's3\n' ;;
    9200|9300) printf 'elasticsearch\n' ;;
    5671|5672) printf 'rabbitmq\n' ;;
    1883) printf 'mqtt\n' ;;
    8883) printf 'mqtts\n' ;;
    *) printf 'custom\n' ;;
  esac
}

target_port_text(){
  local rest="${1#*://}"
  rest="${rest%%/*}"
  printf '%s\n' "${rest##*:}"
}

valid_target_host(){
  local host="${1:-}"
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$ ]] || return 1
  [[ "$host" != *..* && "$host" != .* && "$host" != *. ]]
}

# Ports already allowed by the firewall service manager. Custom TCP ports are
# included because they are part of the same managed outbound configuration.
network_allowed_tcp_ports(){
  local port
  for port in $TCP_EGRESS_PORTS $CUSTOM_TCP_PORTS; do
    valid_port "$port" && printf '%s\n' "$((10#$port))"
  done | sort -n -u
}

# Choose the port for network verification:
#  - an explicitly configured NETWORK_TARGET_PORT wins;
#  - one allowed port is selected automatically;
#  - several allowed ports are shown to the administrator in interactive mode;
#  - non-interactive runs deterministically use the first allowed port.
network_select_allowed_port(){
  local interactive="${1:-1}" answer
  local -a ports=()
  load_config || return 1
  mapfile -t ports < <(network_allowed_tcp_ports)
  if [[ -n "${NETWORK_TARGET_PORT:-}" ]] && valid_port "$NETWORK_TARGET_PORT"; then
    printf '%s\n' "$((10#$NETWORK_TARGET_PORT))"
    return 0
  fi
  if (( ${#ports[@]} == 0 )); then
    warn "No allowed outbound TCP ports are configured. Run menu 9 first, or pass --target explicitly."
    return 1
  fi
  if (( ${#ports[@]} == 1 )); then
    printf '%s\n' "${ports[0]}"
    return 0
  fi
  if (( interactive )); then
    section "Allowed outbound ports"
    local i
    for i in "${!ports[@]}"; do
      printf '  %2s) %-6s %s\n' "$((i + 1))" "${ports[$i]}" "$(protocol_for_port "${ports[$i]}")"
    done
    read -r -p "Choose the port for network doctor verification [1]: " answer || answer=""
    answer="${answer:-1}"
    [[ "$answer" =~ ^[0-9]+$ ]] || { warn "Invalid choice; no port selected."; return 1; }
    answer=$((10#$answer))
    (( answer >= 1 && answer <= ${#ports[@]} )) || { warn "Choice is outside the allowed port list."; return 1; }
    printf '%s\n' "${ports[$((answer - 1))]}"
    return 0
  fi
  printf '%s\n' "${ports[0]}"
}

network_configure_from_allowed_ports(){
  local interactive="${1:-1}" port host
  if ! port="$(network_select_allowed_port "$interactive")"; then
    return 0
  fi
  NETWORK_TARGET_PORT="$port"
  NETWORK_PROTOCOL="$(protocol_for_port "$port")"
  if [[ -z "${NETWORK_TARGET_HOST:-}" ]] && (( interactive )); then
    read -r -p "Target hostname for network checks [leave blank to set later]: " host || host=""
    host="${host//[[:space:]]/}"
    if valid_target_host "$host"; then
      NETWORK_TARGET_HOST="$host"
    elif [[ -n "$host" ]]; then
      warn "Invalid hostname '${host}'; it was not saved."
    fi
  fi
  save_config || return 1
  log "Network doctor target port ${NETWORK_TARGET_PORT} (${NETWORK_PROTOCOL}) saved from the allowed firewall ports."
  return 0
}

network_default_target(){
  local port host scheme
  load_config || return 1
  port="${NETWORK_TARGET_PORT:-}"
  if [[ -z "$port" ]]; then
    port="$(network_select_allowed_port 0)" || return 1
    NETWORK_TARGET_PORT="$port"
    NETWORK_PROTOCOL="$(protocol_for_port "$port")"
  fi
  host="${NETWORK_TARGET_HOST:-}"
  [[ -n "$host" ]] || return 1
  case "$(protocol_for_port "$port")" in
    http) scheme="http" ;;
    https) scheme="https" ;;
    *) scheme="" ;;
  esac
  if [[ -n "$scheme" ]]; then
    NETWORK_TARGET="${scheme}://${host}:${port}"
  else
    NETWORK_TARGET="${host}:${port}"
  fi
  return 0
}

# Only profiles that use certificate validation get an explicit TLS probe.
# STARTTLS and plain application profiles are verified at TCP level instead of
# being reported as false TLS failures.
tls_probe_enabled(){
  case "${1:-https}" in
    https|smtps|imaps|pop3s|mqtts) return 0 ;;
    *) return 1 ;;
  esac
}

# Choose the application-level probe supported by both the host tools and the
# built-in container runtimes (no packages are installed inside containers).
verification_probe_mode(){
  case "${1:-https}" in
    dns) printf 'dns\n' ;;
    http) printf 'http\n' ;;
    https) printf 'https\n' ;;
    smtps|imaps|pop3s|mqtts) printf 'tls\n' ;;
    *) printf 'tcp\n' ;;
  esac
}

parse_network_target(){
  local raw="${NETWORK_TARGET}" scheme rest
  TARGET_HOST=""
  TARGET_PORT=""
  TARGET_SCHEME=""
  TARGET_PATH="/"

  case "$raw" in
    http://*|https://*)
      scheme="${raw%%://*}"
      rest="${raw#*://}"
      ;;
    *)
      scheme=""
      rest="$raw"
      ;;
  esac
  if [[ "$rest" == */* ]]; then
    TARGET_PATH="/${rest#*/}"
    rest="${rest%%/*}"
  fi
  if [[ "$rest" == *:* && "$rest" != *\]* ]]; then
    TARGET_HOST="${rest%%:*}"
    TARGET_PORT="${rest##*:}"
  else
    TARGET_HOST="$rest"
  fi
  TARGET_SCHEME="$scheme"

  [[ -n "$TARGET_HOST" ]] || { error "No target host was supplied."; return 1; }
  if [[ -z "$TARGET_PORT" ]]; then
    TARGET_PORT="$(protocol_default_port "$NETWORK_PROTOCOL")"
    if [[ -n "$TARGET_SCHEME" ]]; then
      [[ "$TARGET_SCHEME" == "http" ]] && TARGET_PORT="80"
      [[ "$TARGET_SCHEME" == "https" ]] && TARGET_PORT="443"
    fi
  fi
  valid_port "$TARGET_PORT" || { error "Invalid target port: ${TARGET_PORT}."; return 1; }
  if [[ -z "$NETWORK_SNI" ]]; then
    NETWORK_SNI="$TARGET_HOST"
  fi
  return 0
}

parse_network_args(){
  NETWORK_CONTAINER=""
  NETWORK_TARGET=""
  NETWORK_TARGET_GIVEN=0
  NETWORK_PROTOCOL="https"
  NETWORK_SNI=""
  NETWORK_FRESH=3
  local dry=0 apply=0 once=0 protocol_given=0
  while (($#)); do
    case "$1" in
      --container|-c) NETWORK_CONTAINER="${2:-}"; shift 2 ;;
      --target|-t) NETWORK_TARGET="${2:-}"; NETWORK_TARGET_GIVEN=1; shift 2 ;;
      --protocol|-p) NETWORK_PROTOCOL="${2:-https}"; protocol_given=1; shift 2 ;;
      --sni) NETWORK_SNI="${2:-}"; shift 2 ;;
      --fresh-connections|-n) NETWORK_FRESH="${2:-3}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --apply) apply=1; shift ;;
      --once) once=1; shift ;;
      *)
        error "Unknown network option: $1"
        return 1
        ;;
    esac
  done
  [[ "$NETWORK_FRESH" =~ ^[0-9]+$ ]] || { error "--fresh-connections must be a number."; return 1; }
  (( NETWORK_FRESH >= 1 && NETWORK_FRESH <= 30 )) || { error "--fresh-connections must be 1-30."; return 1; }
  NETWORK_DRY_RUN="$dry"
  NETWORK_APPLY="$apply"
  NETWORK_ONCE="$once"
  if (( NETWORK_TARGET_GIVEN == 0 )); then
    network_default_target || true
  fi
  if (( protocol_given == 0 )); then
    local target_port
    target_port="$(target_port_text "$NETWORK_TARGET")"
    if [[ "$target_port" =~ ^[0-9]+$ ]]; then
      target_port=$((10#$target_port))
      NETWORK_PROTOCOL="$(protocol_for_port "$target_port")"
    fi
  fi
  parse_network_target
}

redact_secrets(){
  # URL userinfo is the only place credentials are expected in probe output.
  # sed keeps the redaction independent of Bash glob escaping rules.
  printf '%s\n' "$1" | sed -E 's#(://)[^:@/ ]+:[^@/ ]+@#\1***:***@#g'
}

# ---------------------------------------------------------------------------
# Docker, Swarm and container discovery
# ---------------------------------------------------------------------------

docker_available(){
  command_exists docker && docker info >/dev/null 2>&1
}

swarm_state(){
  if ! docker_available; then
    printf 'unavailable\n'
    return 0
  fi
  docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | head -1
}

wan_ip(){
  local iface="${WAN_IF:-}"
  [[ -n "$iface" ]] || iface="$(get_wan)"
  [[ -n "$iface" ]] || return 1
  ip -4 -o addr show dev "$iface" 2>/dev/null \
    | awk '{ sub(/\/.*/, "", $4); print $4; exit }'
}

# Called by every Docker-related install path. It never leaves or re-creates a
# Swarm: active nodes are accepted, error/locked states are reported only.
docker_swarm_ensure(){
  local state advertise=""
  if ! docker_available; then
    warn "Docker daemon is unavailable; Swarm initialization was skipped."
    return 0
  fi
  state="$(swarm_state)"
  case "$state" in
    active)
      log "Docker Swarm is already active on this node."
      return 0
      ;;
    inactive|"")
      advertise="${VPS_SETUP_SWARM_ADVERTISE_ADDR:-}"
      if [[ -z "$advertise" ]]; then
        load_config >/dev/null 2>&1 || true
        advertise="$(wan_ip || true)"
      fi
      if [[ -n "$advertise" ]] && valid_ipv4 "$advertise"; then
        log "Initializing Docker Swarm with advertise address ${advertise}."
        docker swarm init --advertise-addr "$advertise" >/dev/null 2>&1 \
          || { error "Docker Swarm initialization failed with --advertise-addr ${advertise}."; return 1; }
      else
        log "Initializing Docker Swarm with Docker's automatically selected address."
        docker swarm init >/dev/null 2>&1 \
          || { error "Docker Swarm initialization failed."; return 1; }
      fi
      state="$(swarm_state)"
      if [[ "$state" == "active" ]]; then
        success "Docker Swarm initialized on this node."
        return 0
      fi
      error "Docker Swarm did not become active after initialization (state: ${state:-unknown})."
      return 1
      ;;
    pending) warn "Docker Swarm state is pending; no reinitialization attempted." ;;
    locked) warn "Docker Swarm is locked; unlock it manually with 'docker swarm unlock'." ;;
    error) warn "Docker reports a Swarm error; refusing to reinitialize automatically." ;;
    *) warn "Unrecognized Swarm state '${state}'; no changes made." ;;
  esac
  return 0
}

docker_container_lines(){
  docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || true
}

container_networks(){
  local id="$1"
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}|{{$v.IPAddress}}|{{$v.Gateway}}{{"\n"}}{{end}}' \
    "$id" 2>/dev/null || true
}

container_mtus(){
  local id="$1"
  docker exec "$id" sh -c 'for d in /sys/class/net/*; do n=${d##*/}; [ "$n" = lo ] && continue; printf "%s %s\n" "$n" "$(cat "$d/mtu" 2>/dev/null)"; done' 2>/dev/null || true
}

docker_network_inventory(){
  local id name driver scope mtu subnets
  while IFS='|' read -r id name driver scope; do
    [[ -n "$name" ]] || continue
    mtu="$(docker network inspect -f '{{index .Options "com.docker.network.driver.mtu"}}' "$id" 2>/dev/null || true)"
    subnets="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$id" 2>/dev/null || true)"
    [[ "$mtu" == "<no value>" ]] && mtu=""
    printf '%s|%s|%s|%s|%s|%s\n' "$id" "$name" "$driver" "$scope" "${mtu:-auto}" "${subnets:-none}"
  done < <(docker network ls --format '{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}' 2>/dev/null || true)
}

network_containers(){
  local id name image status
  section "Docker containers and network attachments"
  if ! docker_available; then
    warn "Docker daemon is unavailable."
    return 0
  fi
  printf '%-12s %-22s %-24s %s\n' 'ID' 'NAME' 'IMAGE' 'STATUS'
  while IFS='|' read -r id name image status; do
    [[ -n "$id" ]] || continue
    printf '%-12s %-22s %-24s %s\n' "${id:0:12}" "$name" "$image" "$status"
    while IFS='|' read -r net ip gw; do
      [[ -n "$net" ]] || continue
      printf '    %-16s ip=%-16s gw=%s\n' "$net" "${ip:-none}" "${gw:-none}"
    done < <(container_networks "$id")
    while read -r iface mtu; do
      [[ -n "$iface" ]] || continue
      printf '    mtu %-12s %s\n' "$iface" "$mtu"
    done < <(container_mtus "$id")
  done < <(docker_container_lines)
  return 0
}

# ---------------------------------------------------------------------------
# Probe helpers
# ---------------------------------------------------------------------------

run_probe(){
  local fn="$1" rc
  shift
  set +e
  PROBE_LAST_OUTPUT="$("$fn" "$@" 2>&1)"
  rc=$?
  set -e
  PROBE_LAST_RC="$rc"
}

probe_status(){
  case "$1" in
    0) printf 'SUCCESS' ;;
    2) printf 'UNAVAILABLE' ;;
    *) printf 'FAILED' ;;
  esac
}

probe_host(){
  local mode="$1" host="$2" port="$3" sni="$4" path="$5"
  local tmp code url rc
  case "$mode" in
    dns)
      if command_exists getent; then
        getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}' | grep -q . \
          || getent hosts "$host" 2>/dev/null | awk '{print $1; exit}' | grep -q .
      elif command_exists nslookup; then
        nslookup "$host" >/dev/null 2>&1
      else
        return 2
      fi
      ;;
    tcp)
      command_exists timeout || return 2
      timeout "$NETWORK_TIMEOUT" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port"
      ;;
    http)
      command_exists curl || return 2
      url="http://${host}:${port}${path}"
      local -a curl_args=(--silent --show-error --max-time "$NETWORK_HTTP_TIMEOUT" -o /dev/null -w '%{http_code}')
      set +e
      code="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"
      rc=$?
      set -e
      [[ "$code" =~ ^[0-9]{3}$ ]] || rc=1
      if (( rc == 0 )); then
        printf 'HTTP %s\n' "$code"
      else
        printf 'HTTP FAILED (code=%s)\n' "${code:-none}" >&2
        return 1
      fi
      ;;
    tls)
      command_exists openssl || return 2
      tmp="$(mktemp)" || return 1
      set +e
      printf '' | timeout "$NETWORK_TIMEOUT" openssl s_client \
        -connect "${host}:${port}" -servername "$sni" -tls1_3 >"$tmp" 2>&1
      local rc=$?
      if (( rc != 0 )) || ! grep -Eq 'Verify return code: 0|Verification: OK' "$tmp"; then
        printf '' | timeout "$NETWORK_TIMEOUT" openssl s_client \
          -connect "${host}:${port}" -servername "$sni" -tls1_2 >"$tmp" 2>&1
        rc=$?
      fi
      set -e
      if (( rc == 0 )) && grep -Eq 'Verify return code: 0|Verification: OK' "$tmp"; then
        grep -m1 -E 'Protocol *: TLSv' "$tmp" || printf 'TLS SUCCESS\n'
      else
        printf 'TLS FAILED (verify or handshake)\n' >&2
        rm -f -- "$tmp"
        return 1
      fi
      rm -f -- "$tmp"
      ;;
    https)
      command_exists curl || return 2
      url="https://${host}:${port}${path}"
      local -a curl_args=(--silent --show-error --max-time "$NETWORK_HTTP_TIMEOUT" --tlsv1.2 -o /dev/null -w '%{http_code}')
      if [[ -n "$sni" && "$sni" != "$host" ]]; then
        curl_args+=(--resolve "${sni}:${port}:${host}")
        url="https://${sni}:${port}${path}"
      fi
      set +e
      code="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"
      rc=$?
      set -e
      [[ "$code" =~ ^[0-9]{3}$ ]] || rc=1
      if (( rc == 0 )); then
        printf 'HTTP %s\n' "$code"
      else
        printf 'HTTPS FAILED (code=%s)\n' "${code:-none}" >&2
        return 1
      fi
      ;;
    smtp|smtps|imap|imaps|pop3|pop3s)
      command_exists openssl || return 2
      tmp="$(mktemp)" || return 1
      set +e
      case "$mode" in
        smtp) printf '' | timeout "$NETWORK_TIMEOUT" openssl s_client -connect "${host}:${port}" -servername "$sni" -starttls smtp >"$tmp" 2>&1 ;;
        imap) printf '' | timeout "$NETWORK_TIMEOUT" openssl s_client -connect "${host}:${port}" -servername "$sni" -starttls imap >"$tmp" 2>&1 ;;
        pop3) printf '' | timeout "$NETWORK_TIMEOUT" openssl s_client -connect "${host}:${port}" -servername "$sni" -starttls pop3 >"$tmp" 2>&1 ;;
        smtps|imaps|pop3s) printf '' | timeout "$NETWORK_TIMEOUT" openssl s_client -connect "${host}:${port}" -servername "$sni" >"$tmp" 2>&1 ;;
      esac
      rc=$?
      set -e
      if (( rc == 0 )) && grep -Eq 'Verify return code: 0|Verification: OK' "$tmp"; then
        printf '%s TLS SUCCESS\n' "$mode"
      else
        printf '%s FAILED\n' "$mode" >&2
        rm -f -- "$tmp"
        return 1
      fi
      rm -f -- "$tmp"
      ;;
    *)
      # Databases and custom protocols: a successful TCP session is reported,
      # but never treated as proof of application-level authentication.
      command_exists timeout || return 2
      timeout "$NETWORK_TIMEOUT" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port"
      printf 'TCP SUCCESS (application handshake not verified for %s)\n' "$mode"
      ;;
  esac
}

NODE_PROBE_JS='const net=require("net"),tls=require("tls"),dns=require("dns"),https=require("https");
const mode=process.argv[2],host=process.argv[3],port=Number(process.argv[4]||443),sni=process.argv[5]||host,path=process.argv[6]||"/";
const fail=(m)=>{console.log(m);process.exit(1)};
if(mode==="dns"){dns.lookup(host,(e,a,f)=>e?fail("DNS FAILED "+e.code):console.log("DNS SUCCESS "+a+(f===6?" AAAA":" A")));}
else if(mode==="tcp"){const s=net.connect(port,host);s.setTimeout(5000);s.on("connect",()=>{console.log("TCP SUCCESS");s.destroy();process.exit(0)});s.on("timeout",()=>fail("TCP TIMEOUT"));s.on("error",e=>fail("TCP FAILED "+e.code));}
else if(mode==="tls"){const s=tls.connect({host:host,port:port,servername:sni,rejectUnauthorized:true,minVersion:"TLSv1.2"},()=>{console.log("TLS SUCCESS "+s.getProtocol());s.destroy();process.exit(0)});s.setTimeout(8000);s.on("timeout",()=>fail("TLS TIMEOUT"));s.on("error",e=>fail("TLS FAILED "+e.code));}
else if(mode==="https"){const r=https.get({host:host,port:port,path:path,servername:sni,rejectUnauthorized:true,timeout:8000},res=>{console.log("HTTP "+res.statusCode);res.resume();res.on("end",()=>process.exit(res.statusCode>=500?1:0))});r.on("timeout",()=>{r.destroy();fail("HTTPS TIMEOUT")});r.on("error",e=>fail("HTTPS FAILED "+e.code));}
else if(mode==="http"){const http=require("http");const r=http.get({host:host,port:port,path:path,timeout:8000},res=>{console.log("HTTP "+res.statusCode);res.resume();res.on("end",()=>process.exit(res.statusCode>=500?1:0))});r.on("timeout",()=>{r.destroy();fail("HTTP TIMEOUT")});r.on("error",e=>fail("HTTP FAILED "+e.code));}
else fail("UNKNOWN MODE");'

PY_PROBE='import sys,socket,ssl,urllib.request
mode,host,port,sni,path=sys.argv[2],sys.argv[3],int(sys.argv[4] or 443),sys.argv[5] or sys.argv[3],sys.argv[6] or "/"
if mode=="dns":
    print("DNS SUCCESS "+socket.gethostbyname(host))
elif mode=="tcp":
    s=socket.create_connection((host,port),5); print("TCP SUCCESS"); s.close()
elif mode=="tls":
    ctx=ssl.create_default_context(); s=ctx.wrap_socket(socket.create_connection((host,port),8),server_hostname=sni); print("TLS SUCCESS "+s.version()); s.close()
elif mode=="https":
    ctx=ssl.create_default_context(); r=urllib.request.urlopen("https://"+host+":"+str(port)+path,context=ctx,timeout=8); print("HTTP "+str(r.status)); r.close()
elif mode=="http":
    r=urllib.request.urlopen("http://"+host+":"+str(port)+path,timeout=8); print("HTTP "+str(r.status)); r.close()
else:
    print("UNKNOWN MODE"); sys.exit(1)'

PHP_PROBE='<?php
$m=$argv[1];$h=$argv[2];$p=(int)($argv[3]?:443);$s=$argv[4]?:$h;$path=$argv[5]?:"/";
if($m==="dns"){$ip=gethostbyname($h);if($ip===$h){echo "DNS FAILED\n";exit(1);}echo "DNS SUCCESS $ip\n";exit(0);}
$addr=($m==="tls"||$m==="https"?"ssl":"tcp")."://$h:$p";
$c=stream_context_create(["ssl"=>["verify_peer"=>true,"verify_peer_name"=>true,"peer_name"=>$s,"SNI_enabled"=>true]]);
$s=@stream_socket_client($addr,$e,$err,8,STREAM_CLIENT_CONNECT,$c);
if(!$s){echo "$m FAILED\n";exit(1);}
if($m==="http"){fwrite($s,"GET $path HTTP/1.1\\r\\nHost: $h\\r\\nConnection: close\\r\\n\\r\\n");$line=fgets($s);preg_match("~HTTP/\\S+ (\\d{3})~",$line,$mm);$code=(int)($mm[1] ?? 0);echo "HTTP $code\\n";fclose($s);exit($code>=500?1:0);}
echo ($m==="tls"?"TLS SUCCESS":($m==="https"?"HTTP CHECK REQUIRED":"TCP SUCCESS"))."\n";fclose($s);'

container_runtime(){
  local id="$1" rt
  for rt in node python3 python php; do
    if docker exec "$id" sh -c "command -v $rt >/dev/null 2>&1" >/dev/null 2>&1; then
      printf '%s\n' "$rt"
      return 0
    fi
  done
  return 1
}

container_probe(){
  local mode="$1" id="$2" host="$3" port="$4" sni="$5" path="$6"
  local rt out rc
  if ! rt="$(container_runtime "$id")"; then
    printf 'No Node.js, Python or PHP runtime in container; no package was installed.\n' >&2
    return 2
  fi
  set +e
  case "$rt" in
    node) out="$(docker exec "$id" node -e "$NODE_PROBE_JS" "$mode" "$host" "$port" "$sni" "$path" 2>&1)" ;;
    python3|python) out="$(docker exec "$id" "$rt" -c "$PY_PROBE" "$mode" "$host" "$port" "$sni" "$path" 2>&1)" ;;
    php) out="$(docker exec "$id" php -r "$PHP_PROBE" "$mode" "$host" "$port" "$sni" "$path" 2>&1)" ;;
    *) out="UNKNOWN RUNTIME" ;;
  esac
  rc=$?
  set -e
  printf '%s\n' "$out"
  return "$rc"
}

probe_container(){
  if [[ -n "${VPS_SETUP_DIAG_SIDECAR:-}" ]]; then
    # Optional pinned sidecar: the operator supplies a full digest-pinned image.
    # It shares the application network namespace and is never installed by default.
    docker run --rm --network "container:${2}" "$VPS_SETUP_DIAG_SIDECAR" \
      sh -c "printf 'sidecar mode %s target %s:%s\\n' '$1' '$3' '$4'" 2>&1
    return $?
  fi
  container_probe "$@"
}

# ---------------------------------------------------------------------------
# MTU / MSS evidence and managed iptables chain
# ---------------------------------------------------------------------------

interface_mtu(){
  local iface="$1"
  [[ -n "$iface" ]] || return 1
  ip -o link show dev "$iface" 2>/dev/null | sed -nE 's/.* mtu ([0-9]+).*/\1/p' | head -1
}

mtu_evidence(){
  local bridge mtu wan_mtu mismatch=0 seen=0
  NETWORK_WAN_IF="$(get_wan || true)"
  NETWORK_WAN_MTU="$(interface_mtu "${NETWORK_WAN_IF:-}" || true)"
  [[ -n "$NETWORK_WAN_MTU" ]] || NETWORK_WAN_MTU="unknown"
  while read -r bridge _; do
    [[ -n "$bridge" ]] || continue
    seen=1
    mtu="$(interface_mtu "$bridge" || true)"
    [[ -n "$mtu" ]] || mtu="unknown"
    (( NETWORK_QUIET == 1 )) || printf '  bridge %-16s mtu=%s\n' "$bridge" "$mtu"
    if [[ "$mtu" != "unknown" && "$NETWORK_WAN_MTU" != "unknown" ]] && (( mtu > NETWORK_WAN_MTU )); then
      mismatch=1
    fi
  done < <(bridge_inventory)
  if [[ -n "$NETWORK_CONTAINER" ]] && docker_available; then
    while read -r iface mtu; do
      [[ -n "$iface" ]] || continue
      (( NETWORK_QUIET == 1 )) || printf '  container %-13s mtu=%s\n' "$iface" "$mtu"
      if [[ "$mtu" != "unknown" && "$NETWORK_WAN_MTU" != "unknown" ]] && (( mtu > NETWORK_WAN_MTU )); then
        mismatch=1
      fi
    done < <(container_mtus "$NETWORK_CONTAINER")
  fi
  (( NETWORK_QUIET == 1 )) || (( seen == 1 )) || printf '  no Docker bridge interfaces detected\n'
  NETWORK_MTU_MISMATCH="$mismatch"
}

mss_chain_exists(){
  command_exists iptables || return 1
  iptables -w -t mangle -S "$MSS_CHAIN" >/dev/null 2>&1
}

mss_jump_lines(){
  command_exists iptables || return 0
  iptables -w -t mangle -S FORWARD 2>/dev/null | grep -F -- "-j ${MSS_CHAIN}" || true
}

mss_build_state(){
  local wan bridge cidr tmp
  tmp="$(mktemp)" || return 1
  wan="$(get_wan || true)"
  [[ -n "$wan" ]] || { rm -f -- "$tmp"; warn "No default-route interface detected; MSS rules not generated."; return 1; }
  while read -r bridge cidr; do
    [[ -n "$bridge" && -n "$cidr" ]] || continue
    printf '%s|%s|%s\n' "$bridge" "$cidr" "$wan"
  done < <(bridge_inventory) >"$tmp"
  MSS_STATE_TMP="$tmp"
  return 0
}

mss_backup(){
  local dir
  command_exists iptables || return 0
  dir="${BACKUP_DIR}/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p -- "$dir" 2>/dev/null || return 1
  iptables -w -t mangle -S >"${dir}/iptables-mangle.rules" 2>/dev/null || true
  printf '%s\n' "$dir"
}

mss_ensure_jump(){
  local count line
  count="$(mss_jump_lines | wc -l)"
  if (( count == 0 )); then
    iptables -w -t mangle -I FORWARD 1 -j "$MSS_CHAIN" -m comment --comment "$MSS_JUMP_COMMENT" || return 1
    log "Installed managed mangle jump ${MSS_JUMP_COMMENT}."
    return 0
  fi
  if (( count > 1 )); then
    warn "Removing duplicate ${MSS_CHAIN} jumps (${count} found)."
    while IFS= read -r line; do
      [[ "$line" == *"$MSS_JUMP_COMMENT"* ]] || continue
      set -- $line
      case "${1:-}" in
        -A|-I)
          shift
          [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
          iptables -w -t mangle -D "$@" >/dev/null 2>&1 || true
          ;;
      esac
    done < <(mss_jump_lines | tail -n +2)
  fi
  return 0
}

mss_apply_state(){
  local state_file="$1" bridge cidr wan comment added=0
  command_exists iptables || { warn "iptables is unavailable; MSS repair skipped."; return 1; }
  mkdir -p -- "$STATE_DIR" 2>/dev/null || true
  mss_backup >/dev/null || true
  mss_chain_exists || iptables -w -t mangle -N "$MSS_CHAIN" || return 1
  iptables -w -t mangle -F "$MSS_CHAIN" || return 1
  while IFS='|' read -r bridge cidr wan; do
    [[ -n "$bridge" && -n "$cidr" && -n "$wan" ]] || continue
    comment="VPS-SENTINEL-MSS ${bridge}-${wan}"
    iptables -w -t mangle -A "$MSS_CHAIN" \
      -i "$bridge" -o "$wan" -s "$cidr" -p tcp \
      --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu \
      -m comment --comment "$comment" || return 1
    added=$((added + 1))
  done <"$state_file"
  mss_ensure_jump || return 1
  log "Managed iptables chain ${MSS_CHAIN} reconciled (${added} scoped clamp rule(s))."
  return 0
}

network_change_record(){
  local change_id="$1" reason="$2" original="$3" status="$4"
  mkdir -p -- "$(dirname -- "$NETWORK_CHANGE_LOG")" 2>/dev/null || true
  printf '%s|%s|%s|%s|%s\n' \
    "$change_id" "$(date '+%F %T')" "$reason" "$original" "$status" >>"$NETWORK_CHANGE_LOG"
}

network_reconcile(){
  local force="${1:-0}"
  load_config || return 1
  if ! config_bool "$ENABLE_MSS_CLAMP"; then
    return 0
  fi
  MSS_STATE_TMP=""
  mss_build_state || return 1
  if [[ "$force" != "1" && -f "$NETWORK_STATE_FILE" ]] \
     && cmp -s -- "$MSS_STATE_TMP" "$NETWORK_STATE_FILE" \
     && mss_chain_exists && [[ -n "$(mss_jump_lines)" ]]; then
    rm -f -- "$MSS_STATE_TMP"
    return 0
  fi
  mss_apply_state "$MSS_STATE_TMP" || { rm -f -- "$MSS_STATE_TMP"; return 1; }
  install -m 0600 -- "$MSS_STATE_TMP" "$NETWORK_STATE_FILE" 2>/dev/null || true
  rm -f -- "$MSS_STATE_TMP"
  return 0
}

network_enable_for_docker(){
  local interactive="${1:-1}"
  if [[ "${VPS_SETUP_NO_NETWORK_AUTO_REPAIR:-0}" == "1" ]]; then
    log "Container network auto-repair disabled by VPS_SETUP_NO_NETWORK_AUTO_REPAIR=1."
    return 0
  fi
  load_config || return 1
  ENABLE_MSS_CLAMP=1
  network_configure_from_allowed_ports "$interactive" || warn "Dynamic target selection was deferred; pass --target to the doctor later."
  save_config || return 1
  log "Container network doctor and evidence-based MSS repair enabled for this Docker node."
  network_reconcile 0 || warn "Initial MSS reconciliation was deferred; the watcher will retry."
  return 0
}

mss_status(){
  section "Managed MSS rules"
  printf 'Chain       : %s\n' "$MSS_CHAIN"
  printf 'Backend     : %s\n' "$(firewall_backend)"
  if mss_chain_exists; then
    iptables -w -t mangle -S "$MSS_CHAIN" 2>/dev/null || true
  else
    printf 'Chain is not present.\n'
  fi
  printf 'Jump rules  :\n'
  mss_jump_lines || true
  printf 'Desired state: %s\n' "${NETWORK_STATE_FILE}"
}

mss_rollback(){
  local line
  command_exists iptables || return 0
  while IFS= read -r line; do
    [[ "$line" == *"$MSS_JUMP_COMMENT"* ]] || continue
    set -- $line
    case "${1:-}" in
      -A|-I)
        shift
        [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
        iptables -w -t mangle -D "$@" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(mss_jump_lines)
  iptables -w -t mangle -F "$MSS_CHAIN" >/dev/null 2>&1 || true
  iptables -w -t mangle -X "$MSS_CHAIN" >/dev/null 2>&1 || true
  rm -f -- "$NETWORK_STATE_FILE"
  log "Managed MSS chain and jump removed (if present)."
  return 0
}

network_cleanup(){
  mss_rollback >/dev/null 2>&1 || true
}

network_rollback(){
  local change_id="${1:-latest}" line
  section "Network repair rollback"
  if [[ "$change_id" == "latest" ]]; then
    if [[ -f "$NETWORK_CHANGE_LOG" ]]; then
      line="$(tail -1 "$NETWORK_CHANGE_LOG")"
      change_id="${line%%|*}"
    else
      warn "No repair history found."
    fi
  fi
  mss_rollback || return 1
  network_change_record "${change_id:-unknown}" "manual rollback" "managed chain removed" "rolled-back"
  success "Managed MSS repair rolled back. Change: ${change_id:-unknown}"
}

firewall_backend(){
  local version
  if ! command_exists iptables; then
    printf 'none\n'
    return 0
  fi
  version="$(iptables --version 2>/dev/null || true)"
  case "$version" in
    *nf_tables*) printf 'iptables-nft\n' ;;
    *legacy*) printf 'iptables-legacy\n' ;;
    *) printf 'iptables\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# Host-versus-container diagnostics
# ---------------------------------------------------------------------------

network_diagnose(){
  local h_dns h_tcp h_tls h_app c_dns c_tcp c_tls c_app
  local dns_s tcp_s tls_s app_s dns_c tcp_c tls_c app_c app_mode
  parse_network_args "$@" || return 1
  [[ -n "$NETWORK_CONTAINER" ]] || NETWORK_CONTAINER="$(docker ps --format '{{.ID}}' 2>/dev/null | head -1 || true)"
  app_mode="$(verification_probe_mode "$NETWORK_PROTOCOL")"

  # MTU/MSS evidence is collected on every diagnosis path, including the quiet
  # diagnosis inside `network repair`, so a CLI repair can classify TLS stalls
  # correctly without double-printing the report.
  mtu_evidence

  run_probe probe_host dns "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; h_dns="$PROBE_LAST_OUTPUT"
  dns_s="$(probe_status "$PROBE_LAST_RC")"
  run_probe probe_host tcp "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; h_tcp="$PROBE_LAST_OUTPUT"
  tcp_s="$(probe_status "$PROBE_LAST_RC")"
  if tls_probe_enabled "$NETWORK_PROTOCOL"; then
    run_probe probe_host tls "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; h_tls="$PROBE_LAST_OUTPUT"
    tls_s="$(probe_status "$PROBE_LAST_RC")"
  else
    h_tls="not required for ${NETWORK_PROTOCOL}"; tls_s="SKIPPED"
  fi
  run_probe probe_host "$app_mode" "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; h_app="$PROBE_LAST_OUTPUT"
  app_s="$(probe_status "$PROBE_LAST_RC")"

  if [[ -n "$NETWORK_CONTAINER" ]] && docker_available; then
    run_probe probe_container dns "$NETWORK_CONTAINER" "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; c_dns="$PROBE_LAST_OUTPUT"
    dns_c="$(probe_status "$PROBE_LAST_RC")"
    run_probe probe_container tcp "$NETWORK_CONTAINER" "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; c_tcp="$PROBE_LAST_OUTPUT"
    tcp_c="$(probe_status "$PROBE_LAST_RC")"
    if tls_probe_enabled "$NETWORK_PROTOCOL"; then
      run_probe probe_container tls "$NETWORK_CONTAINER" "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; c_tls="$PROBE_LAST_OUTPUT"
      tls_c="$(probe_status "$PROBE_LAST_RC")"
    else
      c_tls="not required for ${NETWORK_PROTOCOL}"; tls_c="SKIPPED"
    fi
    run_probe probe_container "$app_mode" "$NETWORK_CONTAINER" "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"; c_app="$PROBE_LAST_OUTPUT"
    app_c="$(probe_status "$PROBE_LAST_RC")"
  else
    c_dns="no container selected"; c_tcp="$c_dns"; c_tls="$c_dns"; c_app="$c_dns"
    dns_c="SKIPPED"; tcp_c="SKIPPED"; tls_c="SKIPPED"; app_c="SKIPPED"
  fi

  NETWORK_ROOT_CAUSE="NONE"
  NETWORK_CAUSE_DETAIL="No container-specific failure detected."
  if [[ "$dns_s" == "SUCCESS" && "$tcp_s" == "SUCCESS" ]]; then
    if [[ "$dns_c" == "FAILED" || "$dns_c" == "UNAVAILABLE" ]]; then
      NETWORK_ROOT_CAUSE="DNS"
      NETWORK_CAUSE_DETAIL="The VPS resolves the name but the container does not. Check Docker DNS and upstream resolvers; do not edit Docker-generated resolv.conf."
    elif [[ "$tcp_c" == "FAILED" ]]; then
      NETWORK_ROOT_CAUSE="ROUTING_OR_FIREWALL"
      NETWORK_CAUSE_DETAIL="DNS succeeds but the container cannot open a TCP session. Inspect Docker forwarding, DOCKER-USER, nftables base chains and MASQUERADE."
    elif [[ "$c_app" == *"HTTP 401"* || "$c_app" == *"HTTP 403"* ]]; then
      NETWORK_ROOT_CAUSE="APPLICATION_AUTH"
      NETWORK_CAUSE_DETAIL="TCP/TLS succeeded and the application returned an authorization response. This is not a firewall failure."
    elif [[ "$app_c" == "FAILED" || "$tls_c" == "FAILED" ]]; then
      if (( NETWORK_MTU_MISMATCH == 1 )) || [[ "${VPS_SETUP_FORCE_MSS_EVIDENCE:-0}" == "1" ]]; then
        NETWORK_ROOT_CAUSE="MTU_MSS"
        NETWORK_CAUSE_DETAIL="TCP connects but the TLS/application exchange stalls and interface MTUs differ along the Docker forwarding path. Evidence supports scoped TCP MSS clamping."
      elif [[ "$tls_c" == "FAILED" || "$app_mode" == "tls" || "$app_mode" == "https" ]]; then
        NETWORK_ROOT_CAUSE="TLS_OR_PROXY"
        NETWORK_CAUSE_DETAIL="TCP succeeds but TLS/HTTPS fails without MTU evidence. Check CA certificates, system time, SNI and proxy settings; never disable certificate validation."
      else
        NETWORK_ROOT_CAUSE="APPLICATION_PROTOCOL"
        NETWORK_CAUSE_DETAIL="TCP succeeds but the ${NETWORK_PROTOCOL} application check fails. Inspect the service protocol, credentials and application logs; this is not a firewall failure."
      fi
    fi
  elif [[ "$dns_s" != "SUCCESS" || "$tcp_s" != "SUCCESS" ]]; then
    NETWORK_ROOT_CAUSE="DESTINATION_OR_HOST"
    NETWORK_CAUSE_DETAIL="The VPS itself could not complete the test. Fix host connectivity before attributing the problem to Docker."
  fi

  if (( NETWORK_QUIET == 0 )); then
    section "Container Network Doctor"
    printf 'Target      : %s (protocol %s)\n' "$NETWORK_TARGET" "$NETWORK_PROTOCOL"
    printf 'Host/Port   : %s:%s  SNI=%s\n' "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI"
    printf 'Container   : %s\n' "${NETWORK_CONTAINER:-none}"
    printf '\n%-10s %-12s %-12s %s\n' 'CHECK' 'VPS HOST' 'CONTAINER' 'DETAIL'
    printf '%-10s %-12s %-12s %s\n' 'DNS' "$dns_s" "$dns_c" "$(redact_secrets "$h_dns")"
    printf '%-10s %-12s %-12s %s\n' 'TCP' "$tcp_s" "$tcp_c" "$(redact_secrets "$h_tcp")"
    printf '%-10s %-12s %-12s %s\n' 'TLS' "$tls_s" "$tls_c" "$(redact_secrets "$h_tls")"
    printf '%-10s %-12s %-12s %s\n' "${app_mode^^}" "$app_s" "$app_c" "$(redact_secrets "$h_app")"
    printf '\nMTU path    : WAN %s; container failures may hide large-packet loss.\n' "$NETWORK_WAN_MTU"
    printf 'Root cause  : %s\n' "$NETWORK_ROOT_CAUSE"
    printf 'Explanation : %s\n' "$NETWORK_CAUSE_DETAIL"
    printf 'Container TCP detail: %s\n' "$(redact_secrets "$c_tcp")"
    printf 'Container TLS detail: %s\n' "$(redact_secrets "$c_tls")"
    printf 'Container app detail: %s\n' "$(redact_secrets "$c_app")"
    section "Proxy environment"
    local var
    for var in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
      [[ -n "${!var:-}" ]] && printf '%-12s %s\n' "$var" "$(redact_secrets "${!var}")"
    done
  fi
  return 0
}

network_status(){
  local iface mtu backend
  section "Container network status"
  if docker_available; then
    printf 'Docker       : reachable\n'
    printf 'Swarm        : %s\n' "$(swarm_state)"
  else
    printf 'Docker       : unavailable\n'
    printf 'Swarm        : unavailable\n'
  fi
  printf 'Firewall     : %s\n' "$(firewall_backend)"
  printf 'UFW          : %s\n' "$(command_exists ufw && ufw status 2>/dev/null | head -1 || printf 'not installed')"
  printf 'IPv4 forward : %s\n' "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf 'unknown')"
  while read -r iface; do
    [[ -n "$iface" ]] || continue
    mtu="$(interface_mtu "$iface" || true)"
    printf 'WAN          : %s (mtu %s)\n' "$iface" "${mtu:-unknown}"
  done < <(get_wan || true)
  backend="$(firewall_backend)"
  if [[ "$backend" == iptables* ]]; then
    printf 'Docker MASQUERADE rules: %s\n' "$(iptables -w -t nat -S 2>/dev/null | grep -c MASQUERADE || true)"
  fi
  section "Docker networks"
  if docker_available; then
    printf '%-12s %-24s %-12s %-10s %-8s %s\n' 'ID' 'NAME' 'DRIVER' 'SCOPE' 'MTU' 'SUBNETS'
    docker_network_inventory | while IFS='|' read -r id name driver scope mtu subnets; do
      printf '%-12s %-24s %-12s %-10s %-8s %s\n' "${id:0:12}" "$name" "$driver" "$scope" "$mtu" "$subnets"
    done
  else
    printf 'Docker daemon unavailable.\n'
  fi
  mtu_evidence
  mss_status
  if is_systemd; then
    section "Persistence"
    printf '%-28s %s\n' "$UNIT_NAME" "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || printf 'unknown')"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Repair plan / apply / verify
# ---------------------------------------------------------------------------

network_plan_repair(){
  REPAIR_PLAN=()
  load_config || return 1
  if [[ "$NETWORK_ROOT_CAUSE" == "MTU_MSS" ]]; then
    if config_bool "$ENABLE_MSS_CLAMP"; then
      REPAIR_PLAN+=("mss-clamp|Evidence: ${NETWORK_CAUSE_DETAIL} | Create ${MSS_CHAIN} in iptables mangle, add one clamped-MSS rule per discovered Docker bridge to the WAN interface, and install a commented FORWARD jump. Reversible and idempotent.")
    else
      REPAIR_PLAN+=("enable-mss-clamp|Evidence supports MSS clamping, but ENABLE_MSS_CLAMP is off. Enable it with menu 3/4/5 or set ENABLE_MSS_CLAMP=1 and re-run the plan.")
    fi
  else
    REPAIR_PLAN+=("manual-review|Root cause '${NETWORK_ROOT_CAUSE}' has no automatic network repair. ${NETWORK_CAUSE_DETAIL}")
  fi
  return 0
}

network_verify(){
  local i ok=0 rc out mode
  case "${VPS_SETUP_NETWORK_VERIFY_MODE:-}" in
    success|ok) return 0 ;;
    fail|failure) return 1 ;;
  esac
  parse_network_args "$@" || return 1
  mode="$(verification_probe_mode "$NETWORK_PROTOCOL")"
  section "Fresh connection verification"
  printf 'Target: %s  Connections: %s  Probe: %s\n' "$NETWORK_TARGET" "$NETWORK_FRESH" "$mode"
  for ((i=1; i<=NETWORK_FRESH; i++)); do
    run_probe probe_container "$mode" "$NETWORK_CONTAINER" "$TARGET_HOST" "$TARGET_PORT" "$NETWORK_SNI" "$TARGET_PATH"
    out="$PROBE_LAST_OUTPUT"
    rc="$PROBE_LAST_RC"
    if (( rc == 0 )); then
      ok=$((ok + 1))
      printf 'TEST %s: SUCCESS %s\n' "$i" "$(redact_secrets "$out")"
    else
      printf 'TEST %s: FAILED %s\n' "$i" "$(redact_secrets "$out")"
    fi
  done
  printf 'Result: %s/%s successful fresh connections.\n' "$ok" "$NETWORK_FRESH"
  (( ok == NETWORK_FRESH )) || return 1
  return 0
}

network_repair(){
  local change_id original entry action detail
  NETWORK_QUIET=1
  network_diagnose "$@" || { NETWORK_QUIET=0; return 1; }
  NETWORK_QUIET=0
  network_plan_repair || return 1

  section "Repair plan"
  for entry in "${REPAIR_PLAN[@]}"; do
    action="${entry%%|*}"
    detail="${entry#*|}"
    printf '  %s: %s\n' "$action" "$detail"
  done

  if [[ "$NETWORK_DRY_RUN" == "1" ]]; then
    log "Dry run only; no system changes were made."
    return 0
  fi
  if [[ "$NETWORK_APPLY" != "1" ]]; then
    warn "Use --dry-run to review or --apply to approve and apply this plan."
    return 1
  fi
  if [[ "$NETWORK_ROOT_CAUSE" != "MTU_MSS" ]]; then
    error "No safe automatic repair is available for '${NETWORK_ROOT_CAUSE}'."
    return 1
  fi
  if ! config_bool "$ENABLE_MSS_CLAMP"; then
    error "ENABLE_MSS_CLAMP is disabled. Re-run one of menu 3/4/5 or enable it in ${CONF_FILE}."
    return 1
  fi
  # Explicit approval is always required for an applied repair. The
  # VPS_SETUP_NO_NETWORK_AUTO_REPAIR flag only disables automatic enablement on
  # Docker install paths; it must never bypass this confirmation.
  confirm_typed "APPLY-NETWORK-REPAIR" || { log "Repair cancelled."; return 0; }

  change_id="$(date '+%Y%m%d%H%M%S')-$$"
  original="chain=$(mss_chain_exists && printf present || printf absent);jump=$(mss_jump_lines | wc -l)"
  network_change_record "$change_id" "$NETWORK_CAUSE_DETAIL" "$original" "applying"
  if ! network_reconcile 1; then
    network_change_record "$change_id" "$NETWORK_CAUSE_DETAIL" "$original" "apply-failed"
    error "MSS repair could not be applied."
    return 1
  fi
  if network_verify "$@"; then
    network_change_record "$change_id" "$NETWORK_CAUSE_DETAIL" "$original" "verified"
    success "Repair applied and verified. Change ID: ${change_id}"
    return 0
  fi
  warn "Verification failed after repair; rolling back automatically."
  mss_rollback || true
  network_change_record "$change_id" "$NETWORK_CAUSE_DETAIL" "$original" "rolled-back"
  error "Repair rolled back because fresh-connection verification failed."
  return 1
}

network_watch(){
  local once="${1:-0}"
  load_config || return 1
  section "Container network reconciliation"
  while true; do
    network_reconcile 0 || warn "Network reconciliation reported a problem; it will be retried."
    [[ "$once" == "1" ]] && { log "One-shot network reconciliation complete."; return 0; }
    sleep "$WATCH_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Interactive menu and CLI
# ---------------------------------------------------------------------------

prompt_network_target(){
  local answer
  if [[ -z "${NETWORK_TARGET_PORT:-}" || -z "${NETWORK_TARGET_HOST:-}" ]]; then
    network_configure_from_allowed_ports 1 || true
  fi
  network_default_target || true
  read -r -p "Target [${NETWORK_TARGET:-host:port}]: " answer || answer=""
  if [[ -n "$answer" ]]; then
    NETWORK_TARGET="$answer"
    NETWORK_TARGET_GIVEN=1
  fi
  [[ -n "$NETWORK_TARGET" ]] || { warn "No target configured. Run menu 9 first or enter host:port."; return 1; }
  read -r -p "Protocol [$(protocol_for_port "$(target_port_text "$NETWORK_TARGET")")]: " answer || answer=""
  NETWORK_PROTOCOL="${answer:-$(protocol_for_port "$(target_port_text "$NETWORK_TARGET")")}"
  return 0
}

network_menu(){
  local answer
  local -a net_args=()
  while true; do
    cat <<'NETMENU'

 ===== CONTAINER NETWORK DOCTOR =====
   1) Network status
   2) Containers and network attachments
   3) Full host/container diagnosis
   4) Test host vs container target
   5) Generate repair plan (dry run)
   6) Apply approved repair
   7) Verify fresh connections
   8) Roll back a repair
   9) Reconcile managed rules now
   0) Back
NETMENU
    read -r -p "Choose an option: " answer || return 0
    case "$answer" in
      1) network_status ;;
      2) network_containers ;;
      3)
        read -r -p "Container ID/name [auto]: " NETWORK_CONTAINER
        prompt_network_target || continue
        net_args=(--target "$NETWORK_TARGET" --protocol "$NETWORK_PROTOCOL")
        [[ -n "$NETWORK_CONTAINER" ]] && net_args=(--container "$NETWORK_CONTAINER" "${net_args[@]}")
        network_diagnose "${net_args[@]}"
        ;;
      4|5|6|7)
        read -r -p "Container ID/name: " NETWORK_CONTAINER
        prompt_network_target || continue
        read -r -p "Expected SNI [target host]: " NETWORK_SNI
        read -r -p "Fresh connections [3]: " NETWORK_FRESH
        NETWORK_FRESH="${NETWORK_FRESH:-3}"
        net_args=(--target "$NETWORK_TARGET" --protocol "$NETWORK_PROTOCOL" \
          --fresh-connections "$NETWORK_FRESH")
        [[ -n "$NETWORK_CONTAINER" ]] && net_args=(--container "$NETWORK_CONTAINER" "${net_args[@]}")
        [[ -n "$NETWORK_SNI" ]] && net_args+=(--sni "$NETWORK_SNI")
        case "$answer" in
          4) NETWORK_DRY_RUN=0; NETWORK_APPLY=0; network_diagnose "${net_args[@]}" ;;
          5) NETWORK_DRY_RUN=1; NETWORK_APPLY=0; network_repair "${net_args[@]}" --dry-run ;;
          6) NETWORK_DRY_RUN=0; NETWORK_APPLY=1; network_repair "${net_args[@]}" --apply ;;
          7) network_verify "${net_args[@]}" ;;
        esac
        ;;
      8)
        read -r -p "Change ID [latest]: " answer
        network_rollback "${answer:-latest}"
        ;;
      9) network_reconcile 1 && success "Managed rules reconciled." ;;
      0|q|Q) return 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

network_cli(){
  case "${1:-status}" in
    status) shift; network_status "$@" ;;
    containers) network_containers ;;
    diagnose) shift; network_diagnose "$@" ;;
    test) shift; network_diagnose "$@" ;;
    repair) shift; network_repair "$@" ;;
    verify) shift; network_verify "$@" ;;
    rollback) shift; network_rollback "${1:-latest}" ;;
    watch) shift; network_watch "${1:-0}" ;;
    reconcile) shift; network_reconcile "${1:-0}" ;;
    mss-status) mss_status ;;
    mss-rollback) shift; network_rollback "${1:-latest}" ;;
    menu) network_menu ;;
    *)
      error "Unknown network command: $1"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  need_root
  init_runtime
  network_cli "$@"
fi
