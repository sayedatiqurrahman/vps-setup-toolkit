#!/usr/bin/env bash
# Pure validation tests. No real system commands are executed.

set -Eeuo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

export VPS_SETUP_CONF="${TEST_TMP}/etc/default/vps-setup"
export VPS_SETUP_STATE_DIR="${TEST_TMP}/etc/vps-setup"
export VPS_SETUP_LOG_DIR="${TEST_TMP}/var/log/vps-setup"
export VPS_SETUP_LOG_FILE="${VPS_SETUP_LOG_DIR}/setup.log"
export VPS_SETUP_BACKUP_DIR="${TEST_TMP}/var/backups/vps-setup"
VPS_SETUP_SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export VPS_SETUP_SOURCE_ROOT

ROOT_DIR="$VPS_SETUP_SOURCE_ROOT"
# shellcheck source=../scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"
# shellcheck source=../scripts/firewall.sh
source "${ROOT_DIR}/scripts/firewall.sh"
init_runtime

PASS=0
FAIL=0
check(){
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-42s expected=[%s] actual=[%s]\n' "$name" "$expected" "$actual" >&2
  fi
}
assert_true(){ if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*" >&2; fi; }
assert_false(){ if "$@"; then FAIL=$((FAIL+1)); printf 'FAIL (should fail) %s\n' "$*" >&2; else PASS=$((PASS+1)); fi; }

# --- port validation --------------------------------------------------------
assert_true valid_port 80
assert_true valid_port 65535
assert_true valid_port 080
assert_false valid_port 0
assert_false valid_port 65536
assert_false valid_port abc
assert_false valid_port ""
assert_false valid_port "123456"

check "normalize_ports dedupe/sort/zeroes" "53 80 443" "$(normalize_ports '443 80 443 080 53')"
check "normalize_ports empty" "" "$(normalize_ports '')"

# --- menu selection ---------------------------------------------------------
parse_menu_selection "2, 3,4,3" 14
check "parse_menu_selection dedupe" "2 3 4" "${MENU_IDS[*]}"
assert_false parse_menu_selection "2,x" 14
assert_true parse_menu_selection "14" 14
assert_false parse_menu_selection "15" 14
assert_false parse_menu_selection "0" 14
assert_false parse_menu_selection "" 14
assert_true parse_menu_selection "1,2,3,4,5,6,7,8,9,10,11,12,13,14" 14

# --- id list helpers --------------------------------------------------------
check "toggle_id_list add+remove" "1 5 7" "$(toggle_id_list '1 3 5' '3 7')"
check "toggle_id_list double toggle" "3" "$(toggle_id_list '3' '3 3')"
check "remove_id_list" "1 5" "$(remove_id_list '1 3 5' '3 9')"

# --- source validation ------------------------------------------------------
assert_true valid_ipv4 10.0.0.1
assert_true valid_ipv4 255.255.255.255
assert_false valid_ipv4 999.1.1.1
assert_true valid_ipv4_cidr 10.0.0.0/24
assert_true valid_ipv4_cidr 172.16.5.4
assert_false valid_ipv4_cidr 10.0.0.0/33
assert_false valid_ipv4_cidr 10.0.0.0/abc

# --- service catalog --------------------------------------------------------
line="$(service_line 18)"
check "service 18 id" "18" "$(cut -d'|' -f1 <<<"$line")"
check "service 18 name" "SQL Server" "$(cut -d'|' -f3 <<<"$line")"
check "service 18 ports" "1433" "$(cut -d'|' -f4 <<<"$line")"
assert_false service_line 9999

SELECTED_SERVICE_IDS="1 5 18"
CUSTOM_TCP_PORTS="8443 443"
CUSTOM_UDP_PORTS=""
recompute_effective_ports
check "recompute_effective_ports TCP" "22 80 443 1433 8443" "$TCP_EGRESS_PORTS"
check "recompute_effective_ports UDP" "" "$UDP_EGRESS_PORTS"
assert_true valid_ipv6 2001:db8::1
assert_false valid_ipv6 10.0.0.1

# --- config save/load round trip -------------------------------------------
SELECTED_SERVICE_IDS="1 5"
CUSTOM_TCP_PORTS="9001"
TCP_EGRESS_PORTS="80 443 587 9001"
UDP_EGRESS_PORTS="53"
MANAGED_UFW_TCP="80 443"
MANAGED_UFW_UDP=""
save_config
assert_true load_config
check "config round trip TCP" "80 443 587 9001" "$TCP_EGRESS_PORTS"
check "config round trip custom" "9001" "$CUSTOM_TCP_PORTS"
ENABLE_MSS_CLAMP=1
NETWORK_TARGET_HOST="sms.example.test"
NETWORK_TARGET_PORT="8443"
NETWORK_PROTOCOL="https"
save_config
load_config
check "MSS clamp config persisted" "1" "$ENABLE_MSS_CLAMP"
check "network target host persisted" "sms.example.test" "$NETWORK_TARGET_HOST"
check "network target port persisted" "8443" "$NETWORK_TARGET_PORT"
check "network protocol persisted" "https" "$NETWORK_PROTOCOL"

printf '\nValidation tests: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
