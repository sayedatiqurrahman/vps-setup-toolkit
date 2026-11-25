#!/usr/bin/env bash
# Container Network Doctor tests. Docker, iptables and probe commands are
# stubbed, so diagnosis, repair planning and rollback never touch a real host.

set -Eeuo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/etc/default" "$TEST_TMP/etc/vps-setup" \
  "$TEST_TMP/var/log/vps-setup" "$TEST_TMP/var/backups/vps-setup" \
  "$TEST_TMP/logs" "$TEST_TMP/state"
export TMPDIR="$TEST_TMP"

# --- stubs ------------------------------------------------------------------

cat >"$TEST_TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$TEST_LOG_DIR/ip.log"
args="$*"
wan="${FAKE_WAN_IF:-ens3}"
if [[ "$args" == *"route show default"* ]]; then
  printf 'default via 10.0.0.1 dev %s\n' "$wan"
  exit 0
fi
if [[ "$args" == *"-o link show dev"* ]]; then
  name="${@: -1}"
  case "$name" in
    "$wan") printf '2: %s: <BROADCAST> mtu %s qdisc noqueue state UP\n' "$name" "${FAKE_WAN_MTU:-1380}" ;;
    docker0|docker_gwbridge|br-abc123) printf '9: %s: <BROADCAST> mtu %s qdisc noqueue state UP\n' "$name" "${FAKE_BRIDGE_MTU:-1500}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [[ "$args" == *"-o link show"* ]]; then
  cat <<LINKS
1: lo: <LOOPBACK> mtu 65536 qdisc noqueue state UNKNOWN
2: ${wan}: <BROADCAST> mtu ${FAKE_WAN_MTU:-1380} qdisc noqueue state UP
3: docker0: <BROADCAST> mtu ${FAKE_BRIDGE_MTU:-1500} qdisc noqueue state UP
4: docker_gwbridge: <BROADCAST> mtu ${FAKE_BRIDGE_MTU:-1500} qdisc noqueue state UP
5: br-abc123: <BROADCAST> mtu ${FAKE_BRIDGE_MTU:-1500} qdisc noqueue state UP
6: veth9a1@if5: <BROADCAST> mtu 1500 qdisc noqueue state UP
LINKS
  exit 0
fi
if [[ "$args" == *"addr show dev"* ]]; then
  name="${@: -1}"
  case "$name" in
    "$wan") printf '2: %s inet 203.0.113.5/24 scope global %s\n' "$wan" "$wan" ;;
    docker0) printf '3: docker0 inet 172.17.0.1/16 scope global docker0\n' ;;
    docker_gwbridge) printf '4: docker_gwbridge inet 10.0.2.1/24 scope global docker_gwbridge\n' ;;
    br-abc123) printf '5: br-abc123 inet 10.0.1.1/24 scope global br-abc123\n' ;;
    *) exit 1 ;;
  esac
fi
exit 0
EOF

cat >"$TEST_TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$TEST_LOG_DIR/docker.log"
state_file="$TEST_STATE_DIR/swarm-state"
cmd="${1:-}"
case "$cmd" in
  info)
    [[ "${FAKE_DOCKER_UNAVAILABLE:-0}" == "1" ]] && exit 1
    if [[ "$*" == *"--format"* ]]; then
      if [[ -f "$state_file" ]]; then cat "$state_file"; else printf '%s\n' "${FAKE_SWARM_STATE:-active}"; fi
    fi
    exit 0
    ;;
  swarm)
    [[ "${2:-}" == "init" ]] || exit 0
    [[ "${FAKE_SWARM_INIT_FAIL:-0}" == "1" ]] && exit 1
    printf 'active\n' >"$state_file"
    exit 0
    ;;
  ps)
    if [[ "$*" == *'{{.ID}}'* && "$*" != *'{{.Names}}'* ]]; then
      printf 'abc123def456\n'
    else
      printf 'abc123def456|app-web|node:22|Up 2 hours\n'
    fi
    exit 0
    ;;
  inspect)
    if [[ "$*" == *"NetworkSettings.Networks"* ]]; then
      printf 'dokploy-network|10.0.1.15|10.0.1.1\ndocker_gwbridge|10.0.2.7|10.0.2.1\n'
    elif [[ "$*" == *"com.docker.network.driver.mtu"* ]]; then
      net="${@: -1}"
      case "$net" in
        n2) printf '1450\n' ;;
        *) printf '1500\n' ;;
      esac
    elif [[ "$*" == *"IPAM.Config"* ]]; then
      net="${@: -1}"
      case "$net" in
        n2) printf '10.0.1.0/24 ' ;;
        *) printf '10.0.2.0/24 ' ;;
      esac
    fi
    exit 0
    ;;
  network)
    if [[ "${2:-}" == "ls" ]]; then
      printf 'n1|bridge|bridge|local\nn2|dokploy-network|overlay|swarm\nn3|docker_gwbridge|bridge|local\n'
    elif [[ "${2:-}" == "inspect" ]]; then
      net="${@: -1}"
      if [[ "$*" == *"com.docker.network.driver.mtu"* ]]; then
        [[ "$net" == "n2" ]] && printf '1450\n' || printf '1500\n'
      elif [[ "$*" == *"IPAM.Config"* ]]; then
        [[ "$net" == "n2" ]] && printf '10.0.1.0/24 ' || printf '10.0.2.0/24 '
      fi
    fi
    exit 0
    ;;
  exec)
    if [[ "${3:-}" == "sh" && "${4:-}" == "-c" ]]; then
      printf 'eth0 %s\neth1 %s\n' "${FAKE_CONTAINER_ETH0_MTU:-1450}" "${FAKE_CONTAINER_ETH1_MTU:-1500}"
      exit 0
    fi
    mode="${6:-}"
    if [[ -n "${FAKE_CONTAINER_FAIL_MODE:-}" && "$mode" == "$FAKE_CONTAINER_FAIL_MODE" ]]; then
      printf 'FAKE %s failure\n' "$mode"
      exit 1
    fi
    case "$mode" in
      dns) printf 'DNS SUCCESS 5.135.172.42\n' ;;
      tcp) printf 'TCP SUCCESS\n' ;;
      tls) printf 'TLS SUCCESS TLSv1.3\n' ;;
      http|https) printf 'HTTP %s\n' "${FAKE_CONTAINER_HTTP_CODE:-200}" ;;
      *) printf 'UNKNOWN MODE\n'; exit 1 ;;
    esac
    exit 0
    ;;
esac
exit 0
EOF

cat >"$TEST_TMP/bin/iptables" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$TEST_LOG_DIR/iptables.log"
if [[ "${1:-}" == "--version" ]]; then
  printf 'iptables v1.8.11 (nf_tables)\n'
  exit 0
fi
[[ "${1:-}" == "-w" ]] && shift
[[ "${1:-}" == "-t" && "${2:-}" == "mangle" ]] && shift 2
action="${1:-}"
chain_file="$TEST_STATE_DIR/mangle-chain.rules"
jump_file="$TEST_STATE_DIR/mangle-jump.rules"
case "$action" in
  -S)
    target="${2:-}"
    if [[ -z "$target" || "$target" == "FORWARD" ]]; then
      cat "$jump_file" 2>/dev/null || true
    else
      [[ -f "$TEST_STATE_DIR/mangle-chain.exists" ]] || exit 1
      printf -- '-N %s\n' "$target"
      cat "$chain_file" 2>/dev/null || true
    fi
    ;;
  -N) : >"$chain_file"; touch "$TEST_STATE_DIR/mangle-chain.exists" ;;
  -F) : >"$chain_file" ;;
  -X) rm -f -- "$TEST_STATE_DIR/mangle-chain.exists" "$chain_file" ;;
  -A|-I)
    op="$action"; chain="${2:-}"; shift 2
    if [[ "$op" == "-I" ]]; then
      pos="${1:-}"; shift
      printf -- '-I %s %s %s\n' "$chain" "$pos" "$*" >>"$jump_file"
    else
      printf -- '-A %s %s\n' "$chain" "$*" >>"$chain_file"
    fi
    ;;
  -D)
    shift
    if [[ "$*" == "FORWARD -j VPS-SENTINEL-MSS"* ]]; then
      : >"$jump_file"
    else
      grep -Fv -- "$*" "$jump_file" >"$jump_file.tmp" || true
      mv "$jump_file.tmp" "$jump_file"
    fi
    ;;
esac
exit 0
EOF

cat >"$TEST_TMP/bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_HOST_DNS_FAIL:-0}" == "1" ]] && exit 2
printf '5.135.172.42\n'
EOF

cat >"$TEST_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_LOG_DIR/curl.log"
[[ "${FAKE_HOST_HTTP_FAIL:-0}" == "1" ]] && exit 7
printf '200\n'
EOF

cat >"$TEST_TMP/bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_LOG_DIR/openssl.log"
[[ "${FAKE_HOST_TLS_FAIL:-0}" == "1" ]] && exit 1
printf 'Protocol  : TLSv1.3\nVerify return code: 0 (ok)\n'
EOF

cat >"$TEST_TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -u
shift || true
if [[ "${1:-}" == "bash" ]]; then
  [[ "${FAKE_HOST_TCP_FAIL:-0}" == "1" ]] && exit 1
  exit 0
fi
"$@"
EOF

cat >"$TEST_TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  is-active|is-enabled) printf 'active\n' ;;
esac
exit 0
EOF

cat >"$TEST_TMP/bin/ufw" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" ]]; then printf 'Status: active\n'; fi
exit 0
EOF

chmod 0755 "$TEST_TMP/bin"/*

# --- environment ------------------------------------------------------------
export PATH="$TEST_TMP/bin:$PATH"
export TEST_LOG_DIR="$TEST_TMP/logs" TEST_STATE_DIR="$TEST_TMP/state"
export VPS_SETUP_CONF="$TEST_TMP/etc/default/vps-setup"
export VPS_SETUP_STATE_DIR="$TEST_TMP/etc/vps-setup"
export VPS_SETUP_LOG_DIR="$TEST_TMP/var/log/vps-setup"
export VPS_SETUP_LOG_FILE="$VPS_SETUP_LOG_DIR/setup.log"
export VPS_SETUP_BACKUP_DIR="$TEST_TMP/var/backups/vps-setup"
export VPS_SETUP_SOURCE_ROOT="$ROOT_DIR"
export VPS_SETUP_NETWORK_VERIFY_MODE=""

# shellcheck source=../scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"
# shellcheck source=../scripts/firewall.sh
source "$ROOT_DIR/scripts/firewall.sh"
# shellcheck source=../scripts/network.sh
source "$ROOT_DIR/scripts/network.sh"
init_runtime

PASS=0
FAIL=0
check(){
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL %-46s expected=[%s] actual=[%s]\n' "$name" "$expected" "$actual" >&2
  fi
}
check_true(){
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$name" >&2; fi
}
check_false(){
  local name="$1"; shift
  if "$@"; then FAIL=$((FAIL+1)); printf 'FAIL (should fail) %s\n' "$name" >&2; else PASS=$((PASS+1)); fi
}
seed_config(){
  TCP_EGRESS_PORTS="${1-}"
  UDP_EGRESS_PORTS="123"
  SELECTED_SERVICE_IDS=""
  CUSTOM_TCP_PORTS="${2:-}"
  CUSTOM_UDP_PORTS=""
  MANAGED_UFW_TCP="80 443"
  MANAGED_UFW_UDP=""
  ENABLE_DOKPLOY_INGRESS=1
  ENABLE_MSS_CLAMP=1
  TRAEFIK_IP="10.0.2.2"
  TRAEFIK_BRIDGE="docker_gwbridge"
  NETWORK_TARGET_HOST="${3:-sms.example.test}"
  NETWORK_TARGET_PORT="${4:-}"
  NETWORK_PROTOCOL="https"
  WAN_IF="ens3"
  save_config
  load_config
}
reset_rules(){
  rm -f -- "$TEST_STATE_DIR/mangle-chain.exists" "$TEST_STATE_DIR/mangle-chain.rules" \
    "$TEST_STATE_DIR/mangle-jump.rules" "$NETWORK_STATE_FILE" "$NETWORK_CHANGE_LOG" \
    "$TEST_STATE_DIR/swarm-state"
  : >"$TEST_LOG_DIR/iptables.log"
}
unset FAKE_CONTAINER_FAIL_MODE FAKE_CONTAINER_HTTP_CODE FAKE_HOST_DNS_FAIL \
  FAKE_HOST_TCP_FAIL FAKE_HOST_TLS_FAIL FAKE_HOST_HTTP_FAIL
export FAKE_CONTAINER_FAIL_MODE="" FAKE_CONTAINER_HTTP_CODE="200" \
  FAKE_HOST_DNS_FAIL=0 FAKE_HOST_TCP_FAIL=0 FAKE_HOST_TLS_FAIL=0 FAKE_HOST_HTTP_FAIL=0
export FAKE_WAN_IF=ens3 FAKE_WAN_MTU=1380 FAKE_BRIDGE_MTU=1500 \
  FAKE_CONTAINER_ETH0_MTU=1450 FAKE_CONTAINER_ETH1_MTU=1500

# --- dynamic allowed-port targeting -----------------------------------------
seed_config "80 443 587" "" "sms.example.test" ""
check "interactive allowed-port choice" "443" \
  "$(printf '2\n' | network_select_allowed_port 1 2>/dev/null | tail -1)"
check "non-interactive uses first allowed port" "80" "$(network_select_allowed_port 0)"
seed_config "80 443 587" "" "sms.example.test" "587"
check "configured port wins" "587" "$(network_select_allowed_port 0)"
seed_config "" "993" "mail.example.test" ""
check "single custom port auto-selected" "993" "$(network_select_allowed_port 1)"
seed_config "80 443 587" "" "sms.example.test" ""
network_configure_from_allowed_ports 0 >/dev/null 2>&1 || true
load_config
check "dynamic port persisted" "80" "$NETWORK_TARGET_PORT"
check "port maps to protocol profile" "http" "$NETWORK_PROTOCOL"
check_true "config contains dynamic target port" grep -q '^NETWORK_TARGET_PORT="80"$' "$CONF_FILE"

seed_config "" "8443" "sms.example.test" ""
network_default_target >/dev/null 2>&1 || true
check "default target uses allowed custom port" "https://sms.example.test:8443" "$NETWORK_TARGET"
parse_network_args >/dev/null 2>&1 || true
check "parsed target port is dynamic" "8443" "$TARGET_PORT"

# --- Swarm handling ----------------------------------------------------------
reset_rules
printf 'inactive\n' >"$TEST_STATE_DIR/swarm-state"
VPS_SETUP_SWARM_ADVERTISE_ADDR="203.0.113.5" docker_swarm_ensure >/dev/null 2>&1 || true
check_true "inactive Swarm initialized with advertised address" \
  grep -q 'swarm init --advertise-addr 203.0.113.5' "$TEST_LOG_DIR/docker.log"
init_count="$(grep -c 'swarm init' "$TEST_LOG_DIR/docker.log")"
printf 'active\n' >"$TEST_STATE_DIR/swarm-state"
docker_swarm_ensure >/dev/null 2>&1 || true
check "active Swarm never reinitialized" "$init_count" "$(grep -c 'swarm init' "$TEST_LOG_DIR/docker.log")"
printf 'locked\n' >"$TEST_STATE_DIR/swarm-state"
docker_swarm_ensure >/dev/null 2>&1 || true
check "locked Swarm never reinitialized" "$init_count" "$(grep -c 'swarm init' "$TEST_LOG_DIR/docker.log")"

# --- discovery ---------------------------------------------------------------
containers_out="$(network_containers 2>/dev/null)"
check_true "container list includes selected container" grep -q 'app-web' <<<"$containers_out"
check_true "container list includes network attachment" grep -q 'docker_gwbridge' <<<"$containers_out"
check_true "container list includes container MTU" grep -q 'mtu eth0' <<<"$containers_out"
networks_out="$(docker_network_inventory)"
check_true "network inventory includes overlay" grep -q 'dokploy-network|overlay' <<<"$networks_out"
check_true "network inventory includes MTU" grep -q '1450' <<<"$networks_out"

# --- host vs container classification ---------------------------------------
seed_config "" "443" "sms.example.test" "443"
diagnosis="$(network_diagnose --container abc123def456 --target sms.example.test:443 --protocol https 2>/dev/null)"
check_true "diagnosis reports dynamic target port" grep -q 'Host/Port   : sms.example.test:443' <<<"$diagnosis"
check_true "healthy path reports no root cause" grep -q 'Root cause  : NONE' <<<"$diagnosis"
check_true "MTU evidence collected in diagnose" grep -q 'WAN 1380' <<<"$diagnosis"

FAKE_CONTAINER_FAIL_MODE=tls
diagnosis="$(network_diagnose --container abc123def456 --target sms.example.test:443 --protocol https 2>/dev/null)"
check_true "TLS stall with MTU mismatch classified as MTU_MSS" \
  grep -q 'Root cause  : MTU_MSS' <<<"$diagnosis"
FAKE_BRIDGE_MTU=1380 FAKE_CONTAINER_ETH0_MTU=1380 FAKE_CONTAINER_ETH1_MTU=1380
diagnosis="$(network_diagnose --container abc123def456 --target sms.example.test:443 --protocol https 2>/dev/null)"
check_true "TLS failure without MTU mismatch is not an MSS repair" \
  grep -q 'Root cause  : TLS_OR_PROXY' <<<"$diagnosis"
FAKE_BRIDGE_MTU=1500 FAKE_CONTAINER_ETH0_MTU=1450 FAKE_CONTAINER_ETH1_MTU=1500
FAKE_CONTAINER_FAIL_MODE=dns
diagnosis="$(network_diagnose --container abc123def456 --target sms.example.test:443 2>/dev/null)"
check_true "container-only DNS failure classified as DNS" grep -q 'Root cause  : DNS' <<<"$diagnosis"
FAKE_CONTAINER_FAIL_MODE=tcp
diagnosis="$(network_diagnose --container abc123def456 --target sms.example.test:443 2>/dev/null)"
check_true "container TCP failure classified as routing/firewall" \
  grep -q 'Root cause  : ROUTING_OR_FIREWALL' <<<"$diagnosis"
FAKE_CONTAINER_FAIL_MODE=""
FAKE_CONTAINER_HTTP_CODE=401
diagnosis="$(network_diagnose --container abc123def456 --target sms.example.test:443 2>/dev/null)"
check_true "HTTP 401 never classified as firewall failure" \
  grep -q 'Root cause  : APPLICATION_AUTH' <<<"$diagnosis"
FAKE_CONTAINER_HTTP_CODE=200

HTTPS_PROXY='http://user:secret@proxy.example.test:8080'
diagnosis="$(network_diagnose --container abc123def456 --target sms.example.test:443 2>/dev/null)"
check_true "proxy credentials redacted" grep -q 'http://\*\*\*:\*\*\*@proxy.example.test' <<<"$diagnosis"
check_false "proxy password never printed" grep -q 'secret' <<<"$diagnosis"
unset HTTPS_PROXY

# --- non-web service profile -------------------------------------------------
seed_config "" "993" "mail.example.test" "993"
diagnosis="$(network_diagnose --container abc123def456 --target mail.example.test:993 2>/dev/null)"
check_true "IMAPS uses TLS profile from allowed port" grep -q '(protocol imaps)' <<<"$diagnosis"
check_true "IMAPS does not demand an HTTP response" grep -q 'TLS SUCCESS' <<<"$diagnosis"

# --- repair plan, apply, idempotency, verification, rollback -----------------
seed_config "" "443" "sms.example.test" "443"
reset_rules
FAKE_CONTAINER_FAIL_MODE=tls
dry_out="$(network_repair --container abc123def456 --target sms.example.test:443 --protocol https --dry-run 2>/dev/null || true)"
check_true "dry run lists scoped MSS plan" grep -q 'mss-clamp' <<<"$dry_out"
check "dry run makes no chain changes" "0" "$(grep -c -- '-N VPS-SENTINEL-MSS' "$TEST_LOG_DIR/iptables.log" || true)"

VPS_SETUP_NO_NETWORK_AUTO_REPAIR=1
cancelled_out="$(printf 'NO\n' | network_repair --container abc123def456 \
  --target sms.example.test:443 --protocol https --apply 2>&1 || true)"
VPS_SETUP_NO_NETWORK_AUTO_REPAIR=0
check_true "manual repair approval cannot be bypassed" grep -q 'Repair cancelled' <<<"$cancelled_out"
check "denied repair makes no chain changes" "0" \
  "$(grep -c -- '-N VPS-SENTINEL-MSS' "$TEST_LOG_DIR/iptables.log" || true)"

VPS_SETUP_NETWORK_VERIFY_MODE=success
apply_out="$(printf 'APPLY-NETWORK-REPAIR\n' | network_repair --container abc123def456 \
  --target sms.example.test:443 --protocol https --apply 2>&1 || true)"
VPS_SETUP_NETWORK_VERIFY_MODE=""
check_true "approved repair reports success" grep -q 'Repair applied and verified' <<<"$apply_out"
check "managed chain created once" "1" "$(grep -c -- '-N VPS-SENTINEL-MSS' "$TEST_LOG_DIR/iptables.log" || true)"
check "one scoped bridge-to-WAN clamp rule per bridge" "3" \
  "$(grep -c -- '-A VPS-SENTINEL-MSS -i .* -o ens3 -s .* -p tcp' "$TEST_STATE_DIR/mangle-chain.rules" || true)"
check_true "clamp uses managed chain and comment" \
  grep -q 'TCPMSS --clamp-mss-to-pmtu -m comment --comment VPS-SENTINEL-MSS ' "$TEST_STATE_DIR/mangle-chain.rules"
check_true "commented FORWARD jump installed" \
  grep -q -- '-I FORWARD 1 -j VPS-SENTINEL-MSS -m comment --comment VPS-SENTINEL-JUMP' "$TEST_STATE_DIR/mangle-jump.rules"
check_true "desired state persisted" test -s "$NETWORK_STATE_FILE"
check_true "change log records verification" grep -q '|verified$' "$NETWORK_CHANGE_LOG"

jump_count="$(grep -c -- '-I FORWARD 1 -j VPS-SENTINEL-MSS' "$TEST_LOG_DIR/iptables.log" || true)"
network_reconcile 1 >/dev/null 2>&1 || true
check "reconcile is idempotent" "$jump_count" \
  "$(grep -c -- '-I FORWARD 1 -j VPS-SENTINEL-MSS' "$TEST_LOG_DIR/iptables.log" || true)"

rollback_out="$(network_rollback 2>&1 || true)"
check_true "rollback reports success" grep -q 'Managed MSS repair rolled back' <<<"$rollback_out"
check_false "rollback removes chain" test -f "$TEST_STATE_DIR/mangle-chain.exists"
check_false "rollback removes desired state" test -f "$NETWORK_STATE_FILE"
check_true "rollback logged" grep -q '|rolled-back$' "$NETWORK_CHANGE_LOG"
unset FAKE_CONTAINER_FAIL_MODE

# --- safety invariants -------------------------------------------------------
check_false "no unmanaged FORWARD flush" grep -Eq '^-F (FORWARD|INPUT|OUTPUT)$' "$TEST_LOG_DIR/iptables.log"
check_false "no permissive policy change" grep -q -- '-P FORWARD ACCEPT' "$TEST_LOG_DIR/iptables.log"
check_false "no TLS verification bypass in source" \
  grep -q 'NODE_TLS_REJECT_UNAUTHORIZED=0' "$ROOT_DIR/scripts/network.sh"
check_true "CLI exposes all required subcommands" bash -c '
  out="$(sed -n "/network_cli(){/,/^}/p" '"$ROOT_DIR"'/scripts/network.sh)"
  for cmd in status containers diagnose test repair verify rollback watch; do
    grep -q "$cmd)" <<<"$out" || exit 1
  done
'

printf '\nNetwork tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
