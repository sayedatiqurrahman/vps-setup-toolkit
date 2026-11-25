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
if [[ "$*" == *"-6"* && "$*" == *"addr show dev"* ]]; then
  name="${@: -1}"
  case "$name" in
    docker0) echo "3: docker0    inet6 2001:db8:1::1/64 scope global" ;;
    docker_gwbridge) echo "4: docker_gwbridge    inet6 2001:db8:2::1/64 scope global" ;;
    br-abc123) echo "5: br-abc123    inet6 2001:db8:3::1/64 scope global" ;;
    br-deadbeef) echo "5: br-deadbeef    inet6 2001:db8:4::1/64 scope global" ;;
    *) exit 1 ;;
  esac
  exit 0
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
  -c)
    if [[ "${FAKE_NFT_VALIDATION_FAIL:-0}" == "1" ]]; then
      printf '%s\n' 'test-file.nft:7:1-9: Error: syntax error, unexpected identifier' >&2
      exit 1
    fi
    exit 0
    ;;
  -f)
    [[ "${FAKE_NFT_APPLY_FAIL:-0}" == "1" ]] && exit 1
    file="${2:-}"
    while IFS= read -r line; do
      case "$line" in
        "add chain"*)
          [[ "$line" == *" vps_docker_forward" ]] && touch "$STATE/managed.exists"
          ;;
        "flush chain"*) : >"$STATE/managed.rules" ;;
        "delete rule"*)
          rule_handle="${line##* }"
          grep -v "handle ${rule_handle}$" "$STATE/parent.rules" >"$STATE/parent.tmp" || true
          mv "$STATE/parent.tmp" "$STATE/parent.rules"
          ;;
        "insert rule"*)
          { printf '%s # handle %s\n' "$line" "$RANDOM"; cat "$STATE/parent.rules"; } \
            >"$STATE/parent.tmp"
          mv "$STATE/parent.tmp" "$STATE/parent.rules"
          ;;
        "add rule"*) printf '%s\n' "$line" >>"$STATE/managed.rules" ;;
      esac
    done <"$file"
    exit 0
    ;;
  list)
    chain="${5:-}"
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
  insert)
    { printf '%s # handle %s\n' "$*" "$RANDOM"; cat "$STATE/parent.rules"; } \
      >"$STATE/parent.tmp"
    mv "$STATE/parent.tmp" "$STATE/parent.rules"
    exit 0
    ;;
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
    verb="ALLOW"
    if [[ "$action" == "delete" && ( "${1:-}" == "allow" || "${1:-}" == "deny" ) ]]; then
      [[ "${1:-}" == "deny" ]] && verb="DENY"
      shift
    fi
    src="Anywhere"; dir="IN"; port=""; comment=""
    if [[ "${1:-}" == "out" ]]; then
      dir="OUT"; comment="VPS-MANAGED container egress"; shift; port="${1:-}"
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
    rule="${port} ${verb} ${dir} ${src}"
    [[ -n "$comment" ]] && rule+=" # ${comment}"
    if [[ "$action" == "allow" ]]; then
      grep -Fxq -- "$rule" "$STATE" || printf '%s\n' "$rule" >>"$STATE"
    else
      awk -v rule="$rule" '$0 == rule && !removed { removed=1; next } { print }' \
        "$STATE" >"$STATE.tmp"
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
# shellcheck source=../scripts/network.sh
source "$ROOT_DIR/scripts/network.sh"
run_probe(){ PROBE_LAST_OUTPUT="STUB PROBE"; PROBE_LAST_RC=0; }
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

# Root-cause regression: outbound established packets must be allowed too.
check_true "new outbound TCP state allowed" grep -q "ct state '{ new, established, related }'" <<<"$rules"
check_true "outbound TCP rule is labelled" grep -q 'DOCKER-EGRESS-TCP' <<<"$rules"
check_true "outbound UDP rule is labelled" grep -q 'DOCKER-EGRESS-UDP' <<<"$rules"
check_true "established return traffic allowed" grep -q 'DOCKER-EGRESS-RETURN' <<<"$rules"

# A jump appended after a drop is unreachable. Reconciliation must move only
# the toolkit-owned jump to the first parent-chain position.
printf '%s\n' \
  'add rule inet cloud_dev forward drop # handle 900' \
  'insert rule inet cloud_dev forward jump vps_docker_forward comment "VPS-MANAGED-DOCKER-JUMP" # handle 901' \
  'add rule inet cloud_dev forward iifname "eth0" oifname "docker0" accept # handle 99' \
  >"$TEST_STATE_DIR/nft/parent.rules"
nft_apply >/dev/null
first_rule="$(head -1 "$TEST_STATE_DIR/nft/parent.rules" | sed 's/ # handle [0-9]*$//')"
check_true "managed jump moved ahead of drop" grep -q 'jump vps_docker_forward' <<<"$first_rule"
check "one jump after reorder" "1" "$(grep -c 'jump vps_docker_forward' "$TEST_STATE_DIR/nft/parent.rules")"
check_true "unrelated drop preserved after reorder" grep -q 'drop # handle 900' "$TEST_STATE_DIR/nft/parent.rules"
unified_audit_rules >/dev/null
check_true "audit confirms jump is first" grep -q 'jump_first=yes' <<<"$(unified_audit_rules)"

# nft -c -f errors must be visible and the rejected ruleset must be preserved.
diagnostics="$(FAKE_NFT_VALIDATION_FAIL=1 nft_apply 2>&1 || true)"
check_true "nft validation failure is reported" grep -q 'nftables validation failed' <<<"$diagnostics"
check_true "nft parser error is displayed" grep -q 'unexpected identifier' <<<"$diagnostics"
check_true "failed ruleset is preserved" test -f "$NFT_FAILED_RULES_FILE"
check_true "preserved ruleset has connection states" grep -q 'new, established, related' "$NFT_FAILED_RULES_FILE"

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
check_true "watcher calls unified service reconcile" grep -q 'service-reconcile' "$VPS_SETUP_WATCHER"
check_true "watcher calls network reconcile" grep -q '"\$NETWORK" reconcile' "$VPS_SETUP_WATCHER"
unit_src="$(toolkit_file systemd/vps-firewall-watch.service)"
check_true "unit allows backup writes" grep -q '/var/backups/vps-setup' "$unit_src"
unit_ok=0
if [[ -f "$VPS_SETUP_UNIT" ]]; then unit_ok=1; fi
check "systemd unit installed" "1" "$unit_ok"
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
check "docker selection enables MSS repair" "1" "$ENABLE_MSS_CLAMP"
check_true "config stores network doctor target port" grep -Eq '^NETWORK_TARGET_PORT="[0-9]+"' "$CONF_FILE"

# --- Unified Service Access catalog and presets -----------------------------
check_true "catalog has HTTP/3" service_line 2 >/dev/null
check_true "catalog has WireGuard" service_line 48 >/dev/null
check_true "catalog has Grafana" service_line 52 >/dev/null
check_true "catalog has custom schema" grep -q '^1|Web|HTTP and HTTPS|80 443||Common web/API destinations|1|cloudflare.com|https$' "$(services_catalog_file)"
check_true "standard preset is non-empty" test -n "$(preset_service_ids standard)"
check "development preset has services" "yes" "$([[ -n "$(preset_service_ids development)" ]] && printf yes || printf no)"
check "all preset has 58 services" "58" "$(count_items "$(preset_service_ids all)")"

# Exact confirmation summary required by the specification.
summary="$(unified_print_summary '1 2 3' '' '')"
check_true "summary service count" grep -qx 'Selected services: 3' <<<"$summary"
check_true "summary TCP count" grep -qx 'TCP ports: 3' <<<"$summary"
check_true "summary UDP count" grep -qx 'UDP ports: 2' <<<"$summary"
check_true "summary host target" grep -qx '  VPS Host:             YES' <<<"$summary"
check_true "summary container target" grep -qx '  Docker Containers:    YES' <<<"$summary"
check_true "summary persistence" grep -qx 'Persistent after reboot: YES' <<<"$summary"

# Non-interactive apply saves host + container outbound state.
VPS_SETUP_INTERACTIVE=0
unified_apply_selection "1 3 4 5" "" "" "unit test selection" 1 >/dev/null
load_config
check "unified selection persisted" "1 3 4 5" "$SELECTED_SERVICE_IDS"
check_true "unified selection has TCP 443" grep -q '443' <<<"$TCP_EGRESS_PORTS"
check_true "unified selection has UDP 123" grep -q '123' <<<"$UDP_EGRESS_PORTS"
check_true "last working config saved" test -f "$SERVICE_LAST_WORKING_FILE"

# Validation failure must preserve the previous configuration.
before_ids="$SELECTED_SERVICE_IDS"
FAKE_NFT_VALIDATION_FAIL=1 unified_apply_selection "13 14 15" "" "" "failed validation" 1 >/dev/null 2>&1 || true
load_config
check "validation failure preserves selection" "$before_ids" "$SELECTED_SERVICE_IDS"

# Custom service definitions are persisted and selected with a stable ID.
VPS_SETUP_CUSTOM_SERVICE_NAME="Acme API"
VPS_SETUP_CUSTOM_SERVICE_PORT="7443"
VPS_SETUP_CUSTOM_SERVICE_PROTOCOL="tcp"
VPS_SETUP_CUSTOM_SERVICE_NOTE="Test custom endpoint"
unified_add_custom_service >/dev/null
load_config
check_true "custom service file created" test -f "$CUSTOM_SERVICES_FILE"
check_true "custom service definition stored" grep -q '|Acme API|7443|' "$CUSTOM_SERVICES_FILE"
check_true "custom service selected" grep -q '1000' <<<"$SELECTED_SERVICE_IDS"
check_true "custom port effective" grep -q '7443' <<<"$TCP_EGRESS_PORTS"
unset VPS_SETUP_CUSTOM_SERVICE_NAME VPS_SETUP_CUSTOM_SERVICE_PORT VPS_SETUP_CUSTOM_SERVICE_PROTOCOL VPS_SETUP_CUSTOM_SERVICE_NOTE

# Connectivity results are recorded for both perspectives.
unified_connectivity_test >/dev/null
check_true "connectivity results written" test -f "$SERVICE_TEST_RESULTS_FILE"
check_true "connectivity has host status" grep -q 'SUCCESS' "$SERVICE_TEST_RESULTS_FILE"
check_true "view includes connectivity status" unified_view_enabled >/dev/null

# Audit/repair detects and removes duplicate managed rules only.
check "unique UFW duplicate port starts empty" "0" "$(grep -c '65500/tcp ALLOW OUT' "$TEST_STATE_DIR/ufw.rules" || true)"
printf '%s\n' '65500/tcp ALLOW OUT Anywhere # VPS-MANAGED container egress' >>"$TEST_STATE_DIR/ufw.rules"
printf '%s\n' '65500/tcp ALLOW OUT Anywhere # VPS-MANAGED container egress' >>"$TEST_STATE_DIR/ufw.rules"
ufw_cleanup_duplicate_managed_out >/dev/null
check "duplicate managed UFW rule removed" "1" "$(grep -c '65500/tcp ALLOW OUT' "$TEST_STATE_DIR/ufw.rules" || true)"
printf '%s\n' '443/tcp DENY OUT Anywhere # VPS-MANAGED container egress' >>"$TEST_STATE_DIR/ufw.rules"
unified_audit_rules >/dev/null
check_true "managed conflicting rule detected" test "$UNIFIED_AUDIT_CONFLICTS" -ge 1
ufw_cleanup_conflicting_managed_out >/dev/null
check "conflicting managed rule removed" "0" "$(grep -c '443/tcp DENY OUT' "$TEST_STATE_DIR/ufw.rules" || true)"
printf '%s\n' 'insert rule inet cloud_dev forward jump vps_docker_forward comment "VPS-MANAGED-DOCKER-JUMP" # handle 123' >>"$TEST_STATE_DIR/nft/parent.rules"
before_jumps="$(grep -c 'VPS-MANAGED-DOCKER-JUMP' "$TEST_STATE_DIR/nft/parent.rules" || true)"
nft_cleanup_duplicate_jumps >/dev/null
check "duplicate managed nft jump removed" "$((before_jumps - 1))" "$(grep -c 'VPS-MANAGED-DOCKER-JUMP' "$TEST_STATE_DIR/nft/parent.rules" || true)"
unified_audit_rules >/dev/null
check "audit reports no conflicts" "0" "$UNIFIED_AUDIT_CONFLICTS"

# Backup and restore return the exact prior selection and custom services.
unified_backup_service_state >/dev/null
check_true "service backup dir recorded" test -n "$SERVICE_BACKUP_LAST_DIR"
check_true "service backup created" test -d "$SERVICE_BACKUP_LAST_DIR"
backup_dir="$SERVICE_BACKUP_LAST_DIR"
unified_apply_selection "1" "" "" "pre-restore change" 1 >/dev/null
unified_restore_service_state "$backup_dir" >/dev/null
load_config
check_true "restore returns custom service" grep -q '1000' <<<"$SELECTED_SERVICE_IDS"

# Smart configuration is additive and never replaces an existing selection.
pre_smart="$SELECTED_SERVICE_IDS"
unified_smart_configure standard 1 >/dev/null
load_config
check_true "smart configure keeps prior services" grep -q '1000' <<<"$SELECTED_SERVICE_IDS"
check_true "smart configure adds standard services" grep -q '1' <<<"$SELECTED_SERVICE_IDS"

# All-common preset enables every predefined service and generates IPv6 rules.
apply_named_preset all 1 >/dev/null
load_config
check "all-common preset selected ID count" "58" "$(count_items "$SELECTED_SERVICE_IDS")"
check "custom services excluded from preset" "false" "$([[ "$SELECTED_SERVICE_IDS" == *1000* ]] && printf true || printf false)"
nft_apply >/dev/null
check_true "IPv6 bridge egress rule generated" grep -q 'ip6 saddr 2001:db8:1::1/64' "$NFT_STATE_FILE"
check_true "IPv6 return rule generated" grep -q 'ip6 daddr 2001:db8:1::1/64' "$NFT_STATE_FILE"

# Exact submenu text is stable for operators and documentation.
menu_output="$(printf '0\n' | unified_service_menu)"
check_true "unified menu heading" grep -qx '========== UNIFIED SERVICE ACCESS ==========' <<<"$menu_output"
check_true "unified menu subtitle" grep -qx 'Configure outbound access for VPS Host + Docker Containers' <<<"$menu_output"
check_true "unified menu option 1" grep -qx '\[1\] Select Services Individually' <<<"$menu_output"
check_true "unified menu option 9" grep -qx '\[9\] Backup / Restore Configuration' <<<"$menu_output"
check_true "unified menu prompt" grep -qx 'Choose an option:' <<<"$menu_output"

printf '\nFirewall tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
