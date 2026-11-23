#!/usr/bin/env bash
# Firewall tests using stubbed ip/ufw/nft/systemctl. No real firewall changes.

set -Eeuo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/etc/default" "$TEST_TMP/etc/vps-setup" \
  "$TEST_TMP/var/log/vps-setup" "$TEST_TMP/var/backups/vps-setup" \
  "$TEST_TMP/sbin" "$TEST_TMP/systemd/system" "$TEST_TMP/logs" "$TEST_TMP/state"

# --- stubs ------------------------------------------------------------------
cat >"$TEST_TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$TEST_LOG_DIR/ip.log"
if [[ "$*" == *"-4"* && "$*" == *"route show default"* ]]; then
  echo "default via 10.0.0.1 dev eth0"
  exit 0
fi
if [[ "$*" == *"-o"* && "$*" == *"link show"* ]]; then
  if [[ "${FAKE_BRIDGE_RECREATED:-0}" == "1" ]]; then
    cat <<LINKS
1: lo: <LOOPBACK,UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default
2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default
3: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN mode DEFAULT group default
4: docker_gwbridge: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
5: br-deadbeef: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
6: veth9a1@if5: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
LINKS
  else
    cat <<LINKS
1: lo: <LOOPBACK,UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default
2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default
3: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN mode DEFAULT group default
4: docker_gwbridge: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
5: br-abc123: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
6: veth9a1@if5: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
LINKS
  fi
  exit 0
fi
if [[ "$*" == *"link show"* && "$*" != *"-o"* ]]; then
  target="${@: -1}"
  case "$target" in
    docker0|docker_gwbridge|br-abc123|br-deadbeef|eth0) exit 0 ;;
    *) exit 1 ;;
  esac
fi
if [[ "$*" == *"addr show dev"* ]]; then
  name="${@: -1}"
  if [[ "${FAKE_BRIDGE_RECREATED:-0}" == "1" && "$name" == "br-abc123" ]]; then exit 1; fi
  case "$name" in
    docker0) echo "3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0" ;;
    docker_gwbridge) echo "4: docker_gwbridge    inet 172.18.0.1/16 brd 172.18.255.255 scope global docker_gwbridge" ;;
    br-abc123) echo "5: br-abc123    inet 172.19.0.1/16 brd 172.19.255.255 scope global br-abc123" ;;
    br-deadbeef) echo "5: br-deadbeef    inet 172.20.0.1/16 brd 172.20.255.255 scope global br-deadbeef" ;;
    *) exit 1 ;;
  esac
fi
exit 0
EOF

cat >"$TEST_TMP/bin/nft" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$TEST_LOG_DIR/nft.log"
STATE="$TEST_STATE_DIR/nft"
mkdir -p "$STATE"
touch "$STATE/parent.rules" "$STATE/managed.rules"
with_handles=0
if [[ "${1:-}" == "-a" ]]; then with_handles=1; shift; fi
action="${1:-}"
case "$action" in
  -c) exit 0 ;;
  -f)
    file="${2:-}"
    while IFS= read -r line; do
      case "$line" in
        "add chain"*) : ;;
        "flush chain"*) : >"$STATE/managed.rules" ;;
        "insert rule"*) printf '%s # handle %s\n' "$line" "$RANDOM" >>"$STATE/parent.rules" ;;
        "add rule"*) printf '%s\n' "$line" >>"$STATE/managed.rules" ;;
      esac
    done <"$file"
    exit 0
    ;;
  list)
    chain="${4:-}"
    if [[ "$chain" == "vps_docker_forward" ]]; then
      [[ -f "$STATE/managed.exists" ]] || exit 1
      target="$STATE/managed.rules"
    else
      target="$STATE/parent.rules"
    fi
    if [[ $with_handles -eq 1 ]]; then
      cat "$target"
    else
      sed 's/ # handle [0-9]*$//' "$target"
    fi
    exit 0
    ;;
  add)
    if [[ "${2:-}" == "chain" && "${4:-}" == "vps_docker_forward" ]]; then touch "$STATE/managed.exists"; fi
    if [[ "${2:-}" == "rule" ]]; then printf '%s\n' "$*" >>"$STATE/managed.rules"; fi
    exit 0
    ;;
  flush) : >"$STATE/managed.rules"; exit 0 ;;
  insert) printf '%s # handle %s\n' "$*" "$RANDOM" >>"$STATE/parent.rules"; exit 0 ;;
  delete)
    handle="${@: -1}"
    grep -v "handle ${handle}$" "$STATE/parent.rules" >"$STATE/parent.tmp" || true
    mv "$STATE/parent.tmp" "$STATE/parent.rules"
    exit 0
    ;;
esac
exit 0
EOF

cat >"$TEST_TMP/bin/ufw" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$TEST_LOG_DIR/ufw.log"
STATE="$TEST_STATE_DIR/ufw.rules"
touch "$STATE"
case "${1:-}" in
  status)
    echo "Status: active"
    cat "$STATE"
    exit 0
    ;;
  default|--force) exit 0 ;;
  allow|delete)
    action="$1"; shift
    src="Anywhere"; dir="IN"; port=""
    if [[ "${1:-}" == "out" ]]; then
      dir="OUT"; shift; port="${1:-}"
    elif [[ "${1:-}" == "from" ]]; then
      shift; src="${1:-}"; shift
      while (( $# > 0 )); do
        if [[ "$1" == "port" ]]; then
          port="${2:-}"; shift 2
        elif [[ "$1" == "proto" ]]; then
          port="${port}/${2:-}"; shift 2
        else
          shift
        fi
      done
    else
      port="${1:-}"
    fi
    rule="${port} ALLOW ${dir} ${src}"
    if [[ "$action" == "allow" ]]; then
      grep -Fxq -- "$rule" "$STATE" || printf '%s\n' "$rule" >>"$STATE"
    else
      grep -Fxv -- "$rule" "$STATE" >"$STATE.tmp" || true
      mv "$STATE.tmp" "$STATE"
    fi
    exit 0
    ;;
esac
exit 0
EOF

cat >"$TEST_TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$TEST_LOG_DIR/systemctl.log"
case "${1:-}" in
  is-active|is-enabled) echo active ;;
esac
exit 0
EOF
chmod 0755 "$TEST_TMP/bin"/*

# --- environment ------------------------------------------------------------
export PATH="${TEST_TMP}/bin:${PATH}"
export TEST_LOG_DIR="${TEST_TMP}/logs" TEST_STATE_DIR="${TEST_TMP}/state"
export VPS_SETUP_CONF="${TEST_TMP}/etc/default/vps-setup"
export VPS_SETUP_STATE_DIR="${TEST_TMP}/etc/vps-setup"
export VPS_SETUP_LOG_DIR="${TEST_TMP}/var/log/vps-setup"
export VPS_SETUP_LOG_FILE="${VPS_SETUP_LOG_DIR}/setup.log"
export VPS_SETUP_BACKUP_DIR="${TEST_TMP}/var/backups/vps-setup"
export VPS_SETUP_INBOUND_RULES="${TEST_TMP}/etc/vps-setup/host-inbound.rules"
export VPS_SETUP_NFT_STATE="${TEST_TMP}/etc/vps-setup/nft-applied.rules"
export VPS_SETUP_SOURCE_ROOT="$ROOT_DIR"
export VPS_SETUP_WATCHER="${TEST_TMP}/sbin/vps-firewall-watch"
export VPS_SETUP_UNIT="${TEST_TMP}/systemd/system/vps-firewall-watch.service"

# shellcheck source=../scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"
# shellcheck source=../scripts/firewall.sh
source "$ROOT_DIR/scripts/firewall.sh"
init_runtime

PASS=0
FAIL=0
check(){
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL %-45s expected=[%s] actual=[%s]\n' "$name" "$expected" "$actual" >&2
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

# Seed an unrelated parent-chain rule that must survive every apply.
mkdir -p "$TEST_STATE_DIR/nft"
printf '%s\n' 'add rule inet cloud_dev forward iifname "eth0" oifname "docker0" accept # handle 99' \
  >"$TEST_STATE_DIR/nft/parent.rules"

# --- UFW idempotency --------------------------------------------------------
TCP_EGRESS_PORTS="443 587"
UDP_EGRESS_PORTS="123"
MANAGED_UFW_TCP=""
MANAGED_UFW_UDP=""
save_config
load_config
ufw_apply_managed_egress
ufw_apply_managed_egress
check "UFW TCP 443 added exactly once" "1" "$(grep -c 'allow out 443/tcp' "$TEST_LOG_DIR/ufw.log")"
check "UFW UDP 123 added exactly once" "1" "$(grep -c 'allow out 123/udp' "$TEST_LOG_DIR/ufw.log")"
check_true "UFW managed state tracked" grep -q 'allow out 587/tcp' "$TEST_LOG_DIR/ufw.log"

# --- dynamic bridge detection ----------------------------------------------
bridges="$(bridge_inventory)"
check_true "bridge_inventory has docker0" grep -q '^docker0 ' <<<"$bridges"
check_true "bridge_inventory has docker_gwbridge" grep -q '^docker_gwbridge ' <<<"$bridges"
check_true "bridge_inventory has br-*" grep -q '^br-abc123 ' <<<"$bridges"
check_false "bridge_inventory ignores eth0" grep -q '^eth0 ' <<<"$bridges"
check_false "bridge_inventory ignores veth" grep -q '^veth' <<<"$bridges"

# --- nftables generation and idempotency -----------------------------------
nft_apply
rules="$(cat "$NFT_STATE_FILE")"
check_true "nft has managed jump" grep -q 'jump vps_docker_forward' <<<"$rules"
check_true "nft has jump comment" grep -q 'VPS-MANAGED-DOCKER-JUMP' <<<"$rules"
check_true "nft flushes only managed chain" grep -q 'flush chain inet cloud_dev vps_docker_forward' <<<"$rules"
check_true "nft has docker0 rule" grep -q 'iifname "docker0"' <<<"$rules"
check_true "nft has br-* rule" grep -q 'iifname "br-abc123"' <<<"$rules"
check_true "nft has TCP set" grep -q 'tcp dport { 443,587 }' <<<"$rules"
check_true "nft has UDP set" grep -q 'udp dport { 123 }' <<<"$rules"
check_false "nft never flushes full ruleset" grep -q 'flush ruleset' <<<"$rules"
check "one jump after first apply" "1" "$(grep -c 'jump vps_docker_forward' "$TEST_STATE_DIR/nft/parent.rules")"
check_true "unrelated parent rule preserved" grep -q 'iifname "eth0"' "$TEST_STATE_DIR/nft/parent.rules"

first_check="$(grep -n -- '-c -f' "$TEST_LOG_DIR/nft.log" | head -1 | cut -d: -f1)"
first_apply="$(grep -n -- '^-f' "$TEST_LOG_DIR/nft.log" | head -1 | cut -d: -f1)"
validation_ok=0
if [[ -n "$first_check" && -n "$first_apply" && "$first_check" -lt "$first_apply" ]]; then validation_ok=1; fi
check "nft validation happens before apply" "1" "$validation_ok"

nft_apply
check "one jump after repeated apply" "1" "$(grep -c 'jump vps_docker_forward' "$TEST_STATE_DIR/nft/parent.rules")"

# --- simulated bridge recreation -------------------------------------------
FAKE_BRIDGE_RECREATED=1 nft_apply
rules="$(cat "$NFT_STATE_FILE")"
check_true "recreated bridge detected" grep -q 'iifname "br-deadbeef"' <<<"$rules"
check_false "old bridge removed" grep -q 'iifname "br-abc123"' <<<"$rules"
check "still one jump after bridge change" "1" "$(grep -c 'jump vps_docker_forward' "$TEST_STATE_DIR/nft/parent.rules")"

# --- inbound rules ----------------------------------------------------------
check_false "public 3306 blocked by default" add_host_inbound_rule 3306 tcp "" 0
check_true "public 3306 allowed with explicit flag" add_host_inbound_rule 3306 tcp "" 1
check_false "invalid CIDR rejected" add_host_inbound_rule 8080 tcp "999.0.0.0/8"
check_true "trusted CIDR accepted" add_host_inbound_rule 8080 tcp "10.0.0.0/24"
check_true "inbound state recorded" grep -qx '8080|tcp|10.0.0.0/24' "$INBOUND_RULES_FILE"

# --- watcher artifacts ------------------------------------------------------
start_watcher
watcher_ok=0
if [[ -x "$VPS_SETUP_WATCHER" ]]; then watcher_ok=1; fi
check "watcher installed" "1" "$watcher_ok"
check_true "watcher calls reconcile" grep -q 'nft-reconcile' "$VPS_SETUP_WATCHER"
unit_ok=0
if [[ -f "$VPS_SETUP_UNIT" ]]; then unit_ok=1; fi
check "systemd unit installed" "1" "$unit_ok"
unit_src="$(toolkit_file systemd/vps-firewall-watch.service)"
check_true "systemd unit has ExecStart" grep -q 'ExecStart=/usr/local/sbin/vps-firewall-watch' "$unit_src"

# --- automatic docker_gwbridge / Traefik ingress rules -----------------------
load_config
ENABLE_DOKPLOY_INGRESS=1
TRAEFIK_IP="10.0.2.2"
TRAEFIK_BRIDGE="docker_gwbridge"
save_config
nft_apply
rules="$(cat "$NFT_STATE_FILE")"
check_true "ingress has DOKPLOY-INGRESS comment" grep -q 'DOKPLOY-INGRESS' <<<"$rules"
check_true "return has DOKPLOY-RETURN comment" grep -q 'DOKPLOY-RETURN' <<<"$rules"
check_true "ingress targets docker_gwbridge" grep -q 'oifname "docker_gwbridge"' <<<"$rules"
check_true "return rule uses established state" grep -q "ct state '{ established, related }'" <<<"$rules"

# --- guided post-install service presets ------------------------------------
load_config
printf '2\ny\n' | firewall_service_menu >/dev/null 2>&1 || true
load_config
check "standard preset applied" "$STANDARD_SERVICE_IDS" "$SELECTED_SERVICE_IDS"

# --- preflight enables ingress for Docker-related selections ----------------
firewall_preflight 0 3 >/dev/null 2>&1 || true
load_config
check "docker selection enables ingress" "1" "$ENABLE_DOKPLOY_INGRESS"

printf '\nFirewall tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
